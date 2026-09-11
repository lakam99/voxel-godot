extends SceneTree

const NavigationBackendConfigScript := preload("res://scripts/npc_ai/navigation/NavigationBackendConfig.gd")
const NavigationBakeDescriptorScript := preload("res://scripts/npc_ai/contracts/NavigationBakeDescriptor.gd")
const NavmeshWorldServiceScript := preload("res://scripts/npc_ai/navigation/NavmeshWorldService.gd")
const NpcAutonomySystemScript := preload("res://scripts/npc_ai/NpcAutonomySystem.gd")
const BuildingClearanceScript := preload("res://scripts/buildings/layout/BuildingLayoutClearance.gd")
const RoutePublicationAdapter := preload("res://scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd")
const NavigationPublicationWorkerScript := preload("res://scripts/npc_ai/navigation/NavigationPublicationWorker.gd")

class PendingSourceFixture extends RefCounted:
	var ready := false
	func navmesh_tile_source_key_for_tile(_key: String) -> String: return "pending-source-contract:1"
	func build_navmesh_tile_snapshot(key: String) -> Dictionary:
		if key=="0,0" and not ready:
			return {"tileKey":key,"publicationStatus":"pending","reason":"fixture_source_pending"}
		var x := int(key.get_slice(",",0))*16
		return {"tileKey":key,"publicationStatus":"ready","sourceKey":navmesh_tile_source_key_for_tile(key),
			"surfaces":[{"cell":Vector3i(x,0,0),"spanIndex":0,"worldPosition":Vector3(x*1.35,0,0)}]}

class RejectingInstallFixture extends NavmeshWorldServiceScript:
	var reject_install := true
	func register_tile_snapshot(snapshot: Dictionary) -> Dictionary:
		if reject_install: return {"status":"rejected","reason":"synthetic_install_rejection","installed":false}
		return super.register_tile_snapshot(snapshot)

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
	verify_source_rectangle_coverage()
	verify_publication_rectangle_clearance()
	await verify_pending_source_retention()
	await verify_navigation_worker_parity_and_ownership()
	write_report()
	quit(0 if failures() == 0 else 1)

func verify_source_rectangle_coverage() -> void:
	# Synthetic geometry/ownership contract, not a live traversal claim.
	var service = NavmeshWorldServiceScript.new()
	var surfaces: Array = []
	for spec in [[0,0,0,"a"],[1,0,0,"a"],[0,1,0,"a"],[0,0,2,"a"],[2,0,0,"b"]]:
		var x: float=spec[0]; var z: float=spec[1]; var y: float=spec[2]
		surfaces.append({"id":"cell-%d" % surfaces.size(),"supportId":spec[3],"walkable":true,
			"polygon":[Vector3(x,y,z),Vector3(x,y,z+1),Vector3(x+1,y,z+1),Vector3(x+1,y,z)]})
	var before := var_to_bytes(surfaces)
	var ownership := {}
	var polygons: Array = service._navigation_mesh_polygons_for_surfaces(surfaces,ownership)
	add_result("source_rectangle_merge_retains_every_identity",ownership.size()==5 and polygons.size()==4,{"owners":ownership,"polygonCount":polygons.size()})
	add_result("source_rectangle_merge_preserves_input",before==var_to_bytes(surfaces),{})
	var area := 0.0
	var covers_hole := false
	for polygon: Array in polygons:
		var bounds := AABB(polygon[0],Vector3.ZERO)
		for point: Vector3 in polygon: bounds=bounds.expand(point)
		area+=bounds.size.x*bounds.size.z
		if polygon[0].y==0 and Rect2(Vector2(bounds.position.x,bounds.position.z),Vector2(bounds.size.x,bounds.size.z)).has_point(Vector2(1.5,1.5)): covers_hole=true
	add_result("source_rectangle_union_preserves_area_and_holes",area==5.0 and not covers_hole,{"area":area,"coversHole":covers_hole})
	add_result("source_rectangle_height_and_owner_separation",ownership["cell-0"]!=ownership["cell-3"] and ownership["cell-1"]!=ownership["cell-4"],{})
	var bowtie: Array = surfaces[0].polygon.duplicate()
	var point: Vector3 = bowtie[1]; bowtie[1]=bowtie[2]; bowtie[2]=point
	add_result("source_rectangle_invalid_order_not_reinterpreted",service._source_rectangle(surfaces[0],bowtie).is_empty(),{})
	var slope: Array = surfaces[0].polygon.duplicate()
	slope[1].y=1.0
	add_result("source_rectangle_nonplanar_not_reinterpreted",service._source_rectangle(surfaces[0],slope).is_empty(),{})
	var grade: Array = []
	for x: float in [0.0,1.0]:
		grade.append({"id":"grade-%d" % int(x),"supportId":"grade","polygon":[Vector3(x,0,0),Vector3(x,1,1),Vector3(x+1,1,1),Vector3(x+1,0,0)]})
	var grade_owners := {}
	var merged: Array = service._navigation_mesh_polygons_for_surfaces(grade,grade_owners)
	add_result("source_rectangle_grade_cross_sections_preserved",merged.size()==1 and merged[0]==[Vector3(0,0,0),Vector3(0,1,1),Vector3(2,1,1),Vector3(2,0,0)] and grade_owners.size()==2,{})
	var adjacent: Array = [surfaces[0].duplicate(true),surfaces[1].duplicate(true)]
	adjacent[0].supportId="part-left"; adjacent[1].supportId="part-right"
	for item: Dictionary in adjacent: item.geometryGroupId="same-revision-bound-building"
	var adjacent_owners := {}
	var combined: Array = service._navigation_mesh_polygons_for_surfaces(adjacent,adjacent_owners)
	add_result("source_rectangle_declared_group_keeps_part_identities",combined.size()==1 and adjacent_owners.size()==2 and adjacent[0].supportId=="part-left" and adjacent[1].supportId=="part-right",{})

func verify_publication_rectangle_clearance() -> void:
	# Synthetic shape contract. A corner blocker misses the diagonal but not
	# the full published area; a contained blocker need not touch its perimeter.
	var clearance = BuildingClearanceScript.new()
	var corner := [Vector3(0.9,0,-0.1),Vector3(0.9,0,0.1),Vector3(1.1,0,0.1),Vector3(1.1,0,-0.1)]
	add_result("publication_rectangle_rejects_off_diagonal_corner",clearance._footprint_intersects_rectangle(Vector2.ZERO,Vector2.ONE,corner,0.0),{})
	add_result("publication_rectangle_preserves_segment_predicate",not clearance._footprint_intersects_segment(Vector2.ZERO,Vector2.ONE,corner,0.0),{})
	var enclosed := [Vector3(0.1,0,0.6),Vector3(0.1,0,0.8),Vector3(0.3,0,0.8),Vector3(0.3,0,0.6)]
	add_result("publication_rectangle_rejects_contained_blocker",clearance._footprint_intersects_rectangle(Vector2.ZERO,Vector2.ONE,enclosed,0.0),{})
	add_result("publication_rectangle_preserves_clear_separation",not clearance._footprint_intersects_rectangle(Vector2(3,3),Vector2(4,4),corner,0.52),{})

func verify_pending_source_retention() -> void:
	# Synthetic source producer with the real publication queue and service.
	# No actor movement or route acceptance is inferred.
	var producer := PendingSourceFixture.new()
	var service = NavmeshWorldServiceScript.new()
	service.setup()
	var adapter := RoutePublicationAdapter.new()
	adapter.world = producer
	adapter.navmesh_world = service
	for key: String in ["0,0","1,0"]:
		adapter._enqueue_navmesh_tile_publish(key,producer.navmesh_tile_source_key_for_tile(key),true)
	var processed := adapter._process_queued_navmesh_tile_publishes(2)
	add_result("pending_source_retains_demand_without_empty_cache",adapter.queued_navmesh_tile_keys.has("0,0") and not adapter.empty_navmesh_tile_keys.has("0,0") and not adapter.published_navmesh_tile_keys.has("0,0"),{})
	add_result("pending_source_does_not_starve_ready_tile",processed==1 and adapter.published_navmesh_tile_keys.has("1,0"),{})
	var rejected: Dictionary = service.register_tile_snapshot(producer.build_navmesh_tile_snapshot("0,0"))
	add_result("pending_source_cannot_create_empty_installation",rejected.status=="pending" and not service.descriptors_by_region.has("region:chunk:0,0"),{})
	producer.ready = true
	await process_frame
	processed = adapter._process_queued_navmesh_tile_publishes(2)
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var receipt := service.tile_publication_readiness("0,0",producer.navmesh_tile_source_key_for_tile("0,0"))
	add_result("pending_source_retry_installs_when_owner_ready",processed==1 and not adapter.queued_navmesh_tile_keys.has("0,0") and receipt.status=="ready",{"status":receipt.status,"reason":receipt.reason})
	service.clear()
	var rejecting_service := RejectingInstallFixture.new()
	rejecting_service.setup()
	adapter.navmesh_world = rejecting_service
	adapter._enqueue_navmesh_tile_publish("2,0",producer.navmesh_tile_source_key_for_tile("2,0"),true)
	await process_frame
	processed = adapter._process_queued_navmesh_tile_publishes(2)
	add_result("rejected_install_retains_demand_without_success_cache",processed==0 and adapter.queued_navmesh_tile_keys.has("2,0") and not adapter.empty_navmesh_tile_keys.has("2,0") and not adapter.published_navmesh_tile_keys.has("2,0"),{"processed":processed,"queued":adapter.queued_navmesh_tile_keys.has("2,0"),"published":adapter.published_navmesh_tile_keys.has("2,0")})
	rejecting_service.reject_install = false
	await process_frame
	processed = adapter._process_queued_navmesh_tile_publishes(2)
	rejecting_service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(rejecting_service)
	receipt = rejecting_service.tile_publication_readiness("2,0",producer.navmesh_tile_source_key_for_tile("2,0"))
	add_result("rejected_install_retries_through_real_service",processed==1 and receipt.status=="ready" and not adapter.queued_navmesh_tile_keys.has("2,0"),{"processed":processed,"status":receipt.status,"reason":receipt.reason})
	rejecting_service.clear()

func navigation_worker_fixture() -> Dictionary:
	# Bounded synthetic input, deliberately not a generated-world or movement
	# fixture. The separated parts exercise owner, height, hole and grade rules.
	var snapshot := {"tileKey":"worker-contract", "sourceRevision":7, "semanticRevision":2,
		"surfaces":[{"cell":Vector3i.ZERO,"spanIndex":0},{"cell":Vector3i(1,0,0),"spanIndex":0},
			{"cell":Vector3i(4,0,0),"spanIndex":0,"blocked":true}],
		"buildingSurfaces":[], "semanticRegions":[{"id":"worker-room","kind":"interior","position":Vector3(10.5,0,0.5)}],
		"doorPortals":[{"id":"worker-door","entrance":Vector3(-0.4,0,0),"exit":Vector3(0.4,0,0)}],
		"doorLinks":[{"id":"worker-door-link","portalId":"worker-door","from":"terrain-a","to":"terrain-b"}],
		"crossingLinks":[{"id":"worker-crossing","ownerTileKey":"worker-contract","kind":"stair_ramp",
			"start":Vector3(18.5,0,0),"end":Vector3(18.5,1,1)}]}
	for spec in [[10,0,0,"room"],[11,0,0,"room"],[10,1,0,"room"],[10,0,3,"upper"],[14,0,0,"separate"]]:
		var x: float = spec[0]; var z: float = spec[1]; var y: float = spec[2]
		snapshot.buildingSurfaces.append({"id":"worker-part-%d" % snapshot.buildingSurfaces.size(),
			"supportId":spec[3],"walkable":true,
			"polygon":[Vector3(x,y,z),Vector3(x,y,z+1),Vector3(x+1,y,z+1),Vector3(x+1,y,z)]})
	for x: float in [18.0,19.0]:
		snapshot.buildingSurfaces.append({"id":"worker-grade-%d" % int(x),"supportId":"grade","walkable":true,
			"polygon":[Vector3(x,0,0),Vector3(x,1,1),Vector3(x+1,1,1),Vector3(x+1,0,0)]})
	return snapshot

func freeze_worker_fixture(value) -> void:
	# Fixture setup only: never pass scene owners or mutable source aliases to
	# the real worker. Do not use the production freezer to validate itself.
	if value is Dictionary:
		for key in value: freeze_worker_fixture(value[key])
		value.make_read_only()
	elif value is Array:
		for item in value: freeze_worker_fixture(item)
		value.make_read_only()

func wait_for_navigation_worker(worker, shutting_down := false) -> Dictionary:
	var deadline := Time.get_ticks_msec() + 5000
	var state: Dictionary = worker.poll()
	while Time.get_ticks_msec() < deadline:
		if state.get("shutdownComplete",false) if shutting_down else not String(state.get("completedStatus","")).is_empty():
			return state
		await process_frame
		state = worker.poll()
	return state

func verify_navigation_worker_parity_and_ownership() -> void:
	# Actual worker and NavigationServer installation; synthetic source only.
	# No physics-backed crossing, live gameplay or performance claim follows.
	# Finish preceding fixtures' queued map removals before taking our baseline.
	await physics_frame
	await process_frame
	await physics_frame
	var baseline_maps := navigation_map_ids()
	var main_thread := OS.get_thread_caller_id()
	var snapshot := navigation_worker_fixture()
	var descriptor = NavigationBakeDescriptorScript.from_tile_snapshot(snapshot)
	var expected_signature: String = descriptor.stable_signature()
	var service = NavmeshWorldServiceScript.new()
	var expected_owners := {}
	var expected_mesh = service._build_navigation_mesh(descriptor,expected_owners)
	var expected_vertices: PackedVector3Array = expected_mesh.get_vertices()
	var expected_polygons: Array[PackedInt32Array] = []
	for index in expected_mesh.get_polygon_count(): expected_polygons.append(expected_mesh.get_polygon(index))
	var source := {"status":"prepared","snapshot":snapshot,"profile":{"evidenceLevel":"synthetic_contract"}}
	freeze_worker_fixture(source)
	var source_bytes := var_to_bytes(source)
	var worker := NavigationPublicationWorkerScript.new()
	var binding := {"siteId":"worker-contract","sourceKey":"worker-source:7","generation":7}
	var wrong_binding := binding.duplicate()
	wrong_binding.generation = 8
	var invalid: Dictionary = worker.dispatch(source.duplicate(),binding)
	add_result("navigation_worker_rejects_mutable_envelope",invalid.status=="failed",invalid)
	var dispatched: Dictionary = worker.dispatch(source,binding)
	var token := int(dispatched.get("token",0))
	add_result("navigation_worker_dispatch_is_deferred",dispatched.status=="queued" and worker.take_result(token,binding).status=="pending" and worker._thread==null,{"status":dispatched.status})
	var duplicate: Dictionary = worker.dispatch(source,binding)
	add_result("navigation_worker_duplicate_binding_reuses_token",duplicate.get("duplicate",false) and duplicate.token==token,duplicate)
	add_result("navigation_worker_retains_other_demand_as_busy",worker.dispatch(source,wrong_binding).status=="busy",{})
	var state := await wait_for_navigation_worker(worker)
	add_result("navigation_worker_finishes_bounded_preparation",state.completedStatus=="ready",state)
	add_result("navigation_worker_wrong_binding_cannot_consume",worker.take_result(token,wrong_binding).status=="stale_token" and worker.take_result(token+1,binding).status=="stale_token",{})
	var taken: Dictionary = worker.take_result(token,binding)
	var result: Dictionary = taken.get("result",{})
	var holder = result.get("prepared")
	if holder == null:
		add_result("navigation_worker_produces_prepared_holder",false,{"status":taken.get("status"),"reason":result.get("reason")})
		worker.request_shutdown()
		state = await wait_for_navigation_worker(worker,true)
		add_result("navigation_worker_failed_preparation_drains",state.shutdownComplete,state)
		return
	add_result("navigation_worker_result_is_one_shot",taken.status=="consumed" and worker.take_result(token,binding).status=="stale_token",{})
	add_result("navigation_holder_rejects_wrong_binding",holder.take(wrong_binding)==null,{})
	var prepared = holder.take(binding)
	add_result("navigation_holder_exact_binding_is_one_shot",prepared!=null and holder.take(binding)==null,{})
	if prepared == null:
		worker.retire_external_payload(result)
		taken={}; result={}; holder=null
		worker.request_shutdown()
		state = await wait_for_navigation_worker(worker,true)
		add_result("navigation_worker_failed_holder_drains",state.shutdownComplete,state)
		return
	var geometry: Dictionary = prepared.prepared_geometry()
	add_result("navigation_worker_compiles_and_releases_input_off_main",int(geometry.get("threadId",-1))>0 and int(geometry.get("threadId",-1))!=main_thread and int(state.lastInputReleaseThreadId)>0 and int(state.lastInputReleaseThreadId)!=main_thread,{"mainThread":main_thread,"compileThread":geometry.get("threadId"),"inputReleaseThread":state.lastInputReleaseThreadId})
	add_result("navigation_worker_canonical_signature_parity",prepared.preparation_valid() and prepared.stable_signature()==expected_signature,{"expectedHash":expected_signature.sha256_text(),"actualHash":prepared.stable_signature().sha256_text()})
	add_result("navigation_worker_geometry_and_ownership_parity",geometry.get("vertices")==expected_vertices and geometry.get("polygons")==expected_polygons and geometry.get("surfacePolygons")==expected_owners,{"surfaceCount":expected_owners.size(),"polygonCount":expected_polygons.size()})
	add_result("navigation_worker_fixture_keeps_all_source_parts",expected_owners.size()==9 and expected_polygons.size()==6 and prepared.blockers.size()==1 and prepared.semantic_anchors.size()==1,{})
	add_result("navigation_worker_source_unchanged_and_output_sealed",source_bytes==var_to_bytes(source) and prepared.walkable_surfaces.is_read_only() and prepared.walkable_surfaces[0].is_read_only() and geometry.is_read_only() and geometry.surfacePolygons.is_read_only() and geometry.polygons.is_read_only(),{})
	service.setup(NavigationBackendConfigScript.default_config())
	var installed: Dictionary = service.register_chunk_descriptor(prepared,binding.sourceKey)
	var pending: Dictionary = service.tile_publication_readiness(prepared.tile_key,binding.sourceKey)
	add_result("navigation_worker_install_waits_for_real_ack",installed.get("installed",false) and pending.status=="pending" and pending.reason=="installation_sync_pending",{"installStatus":installed.get("status"),"reason":pending.reason})
	service.sync_navigation_map_if_dirty()
	await wait_for_installed_navigation(service)
	var receipt: Dictionary = service.tile_publication_readiness(prepared.tile_key,binding.sourceKey,expected_owners.keys(),["worker-door-link","worker-crossing"])
	add_result("navigation_worker_actual_revision_and_ownership_receipt",receipt.status=="ready" and receipt.sourceRevision==7 and receipt.signature==expected_signature and receipt.completeSurfaceCoverage,{"status":receipt.status,"reason":receipt.reason,"sourceRevision":receipt.get("sourceRevision"),"missingSurfaces":receipt.get("missingSurfaceIds"),"missingLinks":receipt.get("missingLinkIds")})
	var region: String = prepared.region_id
	var installed_rid: RID = service.region_rids_by_region.get(region,RID())
	var metadata_only: Dictionary = service.register_tile_snapshot({"tileKey":prepared.tile_key,"centerCell":Vector3i.ZERO,"sourceKey":"demand-only"})
	var retained: Dictionary = service.tile_publication_readiness(prepared.tile_key,binding.sourceKey)
	add_result("navigation_metadata_demand_cannot_replace_real_region",metadata_only.get("status")=="rejected" and metadata_only.get("reason")=="missing_tile_surface_source" and service.region_rids_by_region.get(region,RID())==installed_rid and retained.status=="ready" and retained.installationSerial==receipt.installationSerial,{"status":metadata_only.get("status"),"reason":metadata_only.get("reason"),"retainedStatus":retained.status})
	prepared.revision = 8
	var rejected: Dictionary = service.register_chunk_descriptor(prepared,"changed-source")
	add_result("navigation_worker_mutated_header_cannot_replace_install",not prepared.preparation_valid() and prepared.stable_signature().is_empty() and rejected.get("reason")=="prepared_navigation_source_changed" and service.region_rids_by_region.get(region,RID())==installed_rid and service._tile_publication_receipts[region].sourceKey==binding.sourceKey,{"status":rejected.get("status"),"reason":rejected.get("reason")})
	prepared.revision = 7
	var prepared_weak: WeakRef = weakref(prepared)
	service.clear()
	await physics_frame
	add_result("navigation_worker_service_clear_releases_all_rids",navigation_map_ids()==baseline_maps and service.descriptors_by_region.is_empty() and service._tile_publication_receipts.is_empty(),{"baselineMaps":baseline_maps,"finalMaps":navigation_map_ids(),"descriptors":service.descriptors_by_region.size(),"receipts":service._tile_publication_receipts.size()})
	var retirement := {"descriptor":prepared,"workerResult":result}
	var accepted := worker.retire_external_payload(retirement)
	add_result("navigation_worker_accepts_detached_descriptor_retirement",accepted,{})
	# Relinquish every strong prepared-output alias before retirement starts.
	prepared=null; geometry={}; retirement={}; holder=null; result={}; taken={}
	descriptor=null; expected_mesh=null; source={}; snapshot={}
	worker.request_shutdown()
	state = await wait_for_navigation_worker(worker,true)
	add_result("navigation_worker_shutdown_joins_and_retires_off_main",accepted and state.shutdownComplete and not state.busy and not state.workerRunning and not state.retirementPending and int(state.lastRetirementThreadId)>0 and int(state.lastRetirementThreadId)!=main_thread and prepared_weak.get_ref()==null,state)

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
