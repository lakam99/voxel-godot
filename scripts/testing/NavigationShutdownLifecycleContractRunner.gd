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
	await physics_frame
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
	await physics_frame
	service.clear()
	await physics_frame
	await process_frame
	await physics_frame
	add_result(
		"clear_flushes_navigation_removals_before_map_release",
		navigation_map_ids() == baseline_maps,
		{"baselineMaps": baseline_maps, "finalMaps": navigation_map_ids(), "stats": service.stats()}
	)

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
