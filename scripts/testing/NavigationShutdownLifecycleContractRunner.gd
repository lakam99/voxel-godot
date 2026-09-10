extends SceneTree

const NavigationBackendConfigScript := preload("res://scripts/npc_ai/navigation/NavigationBackendConfig.gd")
const NavigationBakeDescriptorScript := preload("res://scripts/npc_ai/contracts/NavigationBakeDescriptor.gd")
const NavmeshWorldServiceScript := preload("res://scripts/npc_ai/navigation/NavmeshWorldService.gd")
const NpcAutonomySystemScript := preload("res://scripts/npc_ai/NpcAutonomySystem.gd")

const REGION_COUNT := 17
const LINK_COUNT := 16

var results: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var baseline_maps := navigation_map_ids()
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.default_config())
	for index in range(REGION_COUNT):
		var descriptor = NavigationBakeDescriptorScript.create(
			"shutdown-contract-region-%d" % index,
			"shutdown-contract-tile-%d" % index
		)
		var center := Vector3(float(index) * 2.0, 0.0, 0.0)
		descriptor.add_walkable_surface("surface-%d" % index, center, Vector3(1.35, 0.05, 1.35))
		if index < LINK_COUNT:
			var portal_id := "shutdown-contract-door-%d" % index
			descriptor.add_door_portal(portal_id, center + Vector3(-0.4, 0.0, 0.0), center + Vector3(0.4, 0.0, 0.0))
			descriptor.add_door_link("from-%d" % index, "to-%d" % index, portal_id)
		service.register_chunk_descriptor(descriptor)
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var before_release: Dictionary = service.stats()
	add_result(
		"fixture_owns_expected_navigation_resources",
		int(before_release.get("installedRegionCount", 0)) == REGION_COUNT and int(before_release.get("installedDoorLinkCount", 0)) == LINK_COUNT,
		before_release
	)
	service.clear()
	await physics_frame
	await process_frame
	await physics_frame
	var after_release: Dictionary = service.stats()
	var final_maps := navigation_map_ids()
	add_result(
		"clear_releases_owned_navigation_map",
		final_maps == baseline_maps,
		{"baselineMaps": baseline_maps, "finalMaps": final_maps, "stats": after_release}
	)
	add_result(
		"clear_releases_all_service_rid_records",
		not bool(after_release.get("hasNavigationMap", true)) and int(after_release.get("installedRegionCount", -1)) == 0 and int(after_release.get("installedDoorLinkCount", -1)) == 0,
		after_release
	)
	await verify_clear_flushes_before_map_release()
	await verify_autonomy_reset_keeps_navmesh_owner()
	await verify_tile_publication_receipts()
	write_report()
	quit(0 if failures() == 0 else 1)

func verify_autonomy_reset_keeps_navmesh_owner() -> void:
	var baseline_maps := navigation_map_ids()
	var autonomy = NpcAutonomySystemScript.new()
	root.add_child(autonomy)
	var shared_navmesh_world = autonomy.get("navmesh_world")
	autonomy.clear()
	var reset_navmesh_world = autonomy.get("navmesh_world")
	add_result(
		"autonomy_reset_preserves_navmesh_service_identity",
		shared_navmesh_world == reset_navmesh_world,
		{
			"initialServiceId": shared_navmesh_world.get_instance_id() if shared_navmesh_world != null else -1,
			"resetServiceId": reset_navmesh_world.get_instance_id() if reset_navmesh_world != null else -1
		}
	)
	if reset_navmesh_world != null:
		var descriptor = NavigationBakeDescriptorScript.create("autonomy-reset-region", "autonomy-reset-tile")
		descriptor.add_walkable_surface("autonomy-reset-surface", Vector3.ZERO, Vector3(1.35, 0.05, 1.35))
		reset_navmesh_world.register_chunk_descriptor(descriptor)
		reset_navmesh_world.sync_navigation_map_if_dirty()
	await physics_frame
	autonomy.queue_free()
	await process_frame
	await physics_frame
	add_result(
		"autonomy_reset_owner_releases_navigation_resources_on_delete",
		navigation_map_ids() == baseline_maps,
		{"baselineMaps": baseline_maps, "finalMaps": navigation_map_ids()}
	)

func verify_clear_flushes_before_map_release() -> void:
	var baseline_maps := navigation_map_ids()
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.default_config())
	var descriptor = NavigationBakeDescriptorScript.create("shutdown-flush-region", "shutdown-flush-tile")
	descriptor.add_walkable_surface("shutdown-flush-surface", Vector3.ZERO, Vector3(1.35, 0.05, 1.35))
	service.register_chunk_descriptor(descriptor)
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	service.clear()
	await physics_frame
	await process_frame
	await physics_frame
	add_result(
		"clear_flushes_navigation_removals_before_map_release",
		navigation_map_ids() == baseline_maps,
		{"baselineMaps": baseline_maps, "finalMaps": navigation_map_ids(), "stats": service.stats()}
	)


class ReceiptService extends NavmeshWorldServiceScript:
	var install_calls := 0
	# Existing virtual signature deliberately remains two arguments.
	func _install_region(region_id: String, descriptor) -> Dictionary:
		install_calls += 1
		return super._install_region(region_id, descriptor)

func receipt_descriptor(tile_key: String, revision := 3):
	var descriptor = NavigationBakeDescriptorScript.create(NavigationBakeDescriptorScript.chunk_region_id(tile_key), tile_key)
	descriptor.revision = revision
	var cell_size := float(NavmeshWorldServiceScript.CELL)
	descriptor.add_walkable_surface("owned-a", Vector3.ZERO, Vector3(cell_size, 0.05, cell_size), {"cell":Vector3i.ZERO})
	descriptor.add_walkable_surface("owned-b", Vector3(cell_size,0,0), Vector3(cell_size,0.05,cell_size), {"cell":Vector3i(1,0,0)})
	descriptor.add_walkable_surface("not-emitted", Vector3(8,0,0), Vector3.ONE, {"walkable":false})
	descriptor.add_door_portal("receipt-door", Vector3(-0.4,0,0), Vector3(0.4,0,0))
	descriptor.add_door_link("owned-a", "owned-b", "receipt-door", {"id":"receipt-link"})
	descriptor.add_door_portal("failed-door", Vector3.ZERO, Vector3.ZERO)
	descriptor.add_door_link("owned-a", "owned-b", "failed-door", {"id":"not-installed-link"})
	return descriptor

func verify_tile_publication_receipts() -> void:
	var baseline_maps := navigation_map_ids()
	var service := ReceiptService.new()
	service.setup(NavigationBackendConfigScript.default_config())
	var tile := "receipt-tile"
	var descriptor = receipt_descriptor(tile)
	var region_id: String = descriptor.region_id
	var install: Dictionary = service.register_chunk_descriptor(descriptor, "source-a")
	var first: Dictionary = service.tile_publication_readiness(tile, "source-a", ["owned-a","owned-b"], ["receipt-link"])
	add_result("receipt_pending_before_explicit_sync", first.status=="pending" and first.reason=="installation_sync_pending", first)
	add_result("receipt_legacy_virtual_installer_preserved", service.install_calls==1 and install.installed, install)
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var ready: Dictionary = service.tile_publication_readiness(tile, "source-a", ["owned-a","owned-b"], ["receipt-link"])
	add_result("receipt_exact_after_real_install_sync", ready.status=="ready" and ready.sourceKey=="source-a" and ready.sourceRevision==3 and ready.signature==descriptor.stable_signature() and ready.installationSerial>0 and ready.completeSurfaceCoverage and ready.missingDeclaredSurfaceIds.is_empty(), ready)
	var held: Dictionary = service._tile_publication_receipts[region_id]
	add_result("receipt_merged_surface_ownership", held.surfaces.get("owned-a",-1)==held.surfaces.get("owned-b",-2) and held.polygonCount==1, {"surfaces":held.surfaces,"polygonCount":held.polygonCount})
	add_result("receipt_deep_readonly_values", held.is_read_only() and held.surfaces.is_read_only() and held.links.is_read_only() and held.links["receipt-link"].is_read_only(), {})
	var missing_surface: Dictionary = service.tile_publication_readiness(tile, "source-a", ["not-emitted"])
	var missing_link: Dictionary = service.tile_publication_readiness(tile, "source-a", [], ["not-installed-link"])
	add_result("receipt_requires_emitted_surface_not_descriptor_count", missing_surface.status=="failed" and missing_surface.missingSurfaceIds==["not-emitted"], missing_surface)
	add_result("receipt_requires_installed_link_not_descriptor_count", missing_link.status=="failed" and missing_link.missingLinkIds==["not-installed-link"], missing_link)
	var invalid: Dictionary = service.tile_publication_readiness(tile, "")
	add_result("receipt_empty_expected_key_rejected", invalid.status=="failed", invalid)
	var cached: Dictionary = service.register_chunk_descriptor(receipt_descriptor(tile), "source-a")
	add_result("receipt_exact_cached_registration", cached.get("cached",false) and service.install_calls==1 and service._tile_publication_receipts[region_id]==held, cached)
	var original_center: Vector3 = descriptor.walkable_surfaces[0].center
	descriptor.walkable_surfaces[0].center = Vector3(0,0.1,0)
	var mutated: Dictionary = service.tile_publication_readiness(tile, "source-a")
	add_result("receipt_mutable_descriptor_change_rejected", mutated.status=="failed" and mutated.reason=="installed_descriptor_changed", mutated)
	descriptor.walkable_surfaces[0].center = original_center
	var changed_key: Dictionary = service.register_chunk_descriptor(receipt_descriptor(tile), "source-b")
	var pending_b: Dictionary = service.tile_publication_readiness(tile, "source-b")
	add_result("receipt_same_signature_new_key_fresh_install", not changed_key.get("cached",false) and service.install_calls==2 and pending_b.status=="pending" and pending_b.installationSerial>ready.installationSerial and pending_b.signature==ready.signature, pending_b)
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var ready_b: Dictionary = service.tile_publication_readiness(tile, "source-b")
	add_result("receipt_replacement_ack_and_old_key_stale", ready_b.status=="ready" and service.tile_publication_readiness(tile,"source-a").status!="ready" and held.sourceKey=="source-a", ready_b)
	# Empty versus nonempty source keys cannot inherit or relabel a receipt.
	service.register_chunk_descriptor(receipt_descriptor(tile), "")
	add_result("receipt_empty_key_does_not_inherit_bound_install", service.install_calls==3 and service._tile_publication_receipts[region_id].sourceKey=="" and service.tile_publication_readiness(tile,"source-b").status!="ready", {})
	service.register_chunk_descriptor(receipt_descriptor(tile,4), "source-c")
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var revision_c: Dictionary = service.tile_publication_readiness(tile,"source-c")
	add_result("receipt_new_revision_bound", revision_c.status=="ready" and revision_c.sourceRevision==4, revision_c)
	service._mark_dirty_region(region_id, {"tileKey":tile,"revision":5}, "contract_edit")
	add_result("receipt_dirty_not_ready", service.tile_publication_readiness(tile,"source-c").reason=="tile_dirty", {})
	service.process_dirty_regions(1,4000)
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	add_result("receipt_rebuild_does_not_reuse_old_source_binding", service.tile_publication_readiness(tile,"source-c").status!="ready" and service._tile_publication_receipts[region_id].sourceKey=="", {})
	service.register_chunk_descriptor(receipt_descriptor(tile,5), "source-d")
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var map_rid: RID = service.navigation_map
	service.navigation_map = RID()
	add_result("receipt_lost_map_rejected_without_invalid_rid_query", service.tile_publication_readiness(tile,"source-d").reason=="installed_map_lost", {})
	service.navigation_map = map_rid
	var region_rid: RID = service.region_rids_by_region[region_id]
	NavigationServer3D.region_set_map(region_rid, RID())
	service._mark_navigation_map_dirty()
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	add_result("receipt_actual_detached_region_rejected", service.tile_publication_readiness(tile,"source-d").reason=="installed_region_lost", {})
	NavigationServer3D.region_set_map(region_rid, map_rid)
	service._mark_navigation_map_dirty()
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var link_rid: RID = service._tile_publication_receipts[region_id].links["receipt-link"].rid
	NavigationServer3D.link_set_map(link_rid, RID())
	service._mark_navigation_map_dirty()
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	add_result("receipt_actual_detached_required_link_rejected", service.tile_publication_readiness(tile,"source-d",[],["receipt-link"]).reason=="required_links_missing", {})
	NavigationServer3D.link_set_map(link_rid, map_rid)
	service._mark_navigation_map_dirty()
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	service.unregister_chunk(region_id)
	add_result("receipt_unregister_erases_installation", not service._tile_publication_receipts.has(region_id) and service.tile_publication_readiness(tile,"source-d").status=="pending", {})
	var unloaded = receipt_descriptor(tile)
	unloaded.loaded=false
	service.register_chunk_descriptor(unloaded,"unloaded")
	add_result("receipt_unloaded_never_ready", service.tile_publication_readiness(tile,"unloaded").reason=="tile_unloaded" and not service._tile_publication_receipts.has(region_id), {})
	var empty = NavigationBakeDescriptorScript.create(region_id,tile)
	service.register_chunk_descriptor(empty,"empty")
	add_result("receipt_empty_never_ready", service.tile_publication_readiness(tile,"empty").status!="ready" and not service._tile_publication_receipts.has(region_id), {})
	# Duplicate source IDs in one merged cell are not complete ownership proof,
	# even though another source surface and a real merged polygon are present.
	var incomplete = receipt_descriptor(tile)
	incomplete.walkable_surfaces.append(incomplete.walkable_surfaces[0].duplicate())
	service.register_chunk_descriptor(incomplete,"incomplete")
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var incomplete_ready: Dictionary = service.tile_publication_readiness(tile,"incomplete")
	add_result("receipt_default_exposes_incomplete_declared_coverage", incomplete_ready.status=="ready" and not incomplete_ready.completeSurfaceCoverage and incomplete_ready.missingDeclaredSurfaceIds==["owned-a"] and service.tile_publication_readiness(tile,"incomplete",["owned-a"]).status=="failed", incomplete_ready)
	# Cancellation is the owner's existing unregister/clear path, including
	# cancellation before synchronization. No alternate cancellation protocol.
	service.register_chunk_descriptor(receipt_descriptor(tile),"cancel")
	service.unregister_chunk(region_id)
	add_result("receipt_cancel_before_sync_retains_no_install", service._tile_publication_receipts.is_empty(), {})
	var snapshot := {"tileKey":"snapshot-receipt","sourceKey":"snapshot-key","sourceRevision":7,
		"surfaces":[{"cell":Vector3i.ZERO,"spanIndex":0}]}
	service.register_tile_snapshot(snapshot)
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var snapshot_ready: Dictionary = service.tile_publication_readiness("snapshot-receipt","snapshot-key",["surface:snapshot-receipt:0,0,0:0"])
	for frame in 60:
		if snapshot_ready.status!="pending": break
		await physics_frame
		snapshot_ready=service.tile_publication_readiness("snapshot-receipt","snapshot-key",["surface:snapshot-receipt:0,0,0:0"])
	add_result("receipt_snapshot_source_key_forwarded", snapshot_ready.status=="ready" and snapshot_ready.sourceRevision==7, snapshot_ready)
	service.clear()
	await physics_frame
	add_result("receipt_clear_releases_all_owned_state", service._tile_publication_receipts.is_empty() and navigation_map_ids()==baseline_maps and held.is_read_only() and held.sourceKey=="source-a", {})
	service.setup(NavigationBackendConfigScript.default_config())
	service.register_chunk_descriptor(receipt_descriptor(tile),"restart")
	add_result("receipt_clear_resets_sync_acknowledgement", service.tile_publication_readiness(tile,"restart").reason=="installation_sync_pending", {})
	service.clear()
	await physics_frame

func wait_for_installed_navigation(service) -> void:
	# Registration synchronization may finish after more than one physics frame.
	# Wait for actual region acknowledgements; assertions still reject missing data.
	for frame in 60:
		var pending := false
		for rid in service.region_rids_by_region.values():
			if NavigationServer3D.region_get_iteration_id(rid)<=0: pending=true
		if not pending: return
		await physics_frame

func navigation_map_ids() -> Array[String]:
	var ids: Array[String] = []
	var maps_value = NavigationServer3D.get_maps()
	if maps_value is Array:
		for map_value in maps_value:
			if map_value is RID:
				ids.append(str(map_value))
	ids.sort()
	return ids

func add_result(name: String, passed: bool, details) -> void:
	results.append({"name": name, "passed": passed, "details": details})
	print("[%s] %s" % ["PASS" if passed else "FAIL", name])

func failures() -> int:
	var count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			count += 1
	return count

func write_report() -> void:
	var report := {
		"runnerId": "navigation_shutdown_lifecycle_contract",
		"evidenceLevel": "service_contract",
		"passed": failures() == 0,
		"resultCount": results.size(),
		"failureCount": failures(),
		"results": results
	}
	var path := OS.get_environment("VOXEL_NAVIGATION_SHUTDOWN_REPORT").strip_edges()
	if path != "":
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "  "))
	print(JSON.stringify(report))
