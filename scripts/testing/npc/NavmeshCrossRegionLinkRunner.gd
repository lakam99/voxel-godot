extends Node

const NavigationBackendConfigScript := preload("res://scripts/npc_ai/navigation/NavigationBackendConfig.gd")
const NavigationBakeDescriptorScript := preload("res://scripts/npc_ai/contracts/NavigationBakeDescriptor.gd")
const GeneratedWorldNavigationAdapterScript := preload("res://scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd")
const NavmeshWorldServiceScript := preload("res://scripts/npc_ai/navigation/NavmeshWorldService.gd")

class SeamManifestSource extends RefCounted:
	var building_manifests: Array = []
	var collision_manifests: Array = []
	var npcs := {}

	func building_navigation_manifest_snapshot() -> Array:
		return building_manifests.duplicate(true)

	func navigation_collision_manifest_snapshot() -> Array:
		return collision_manifests.duplicate(true)

class SeamFixtureMain extends RefCounted:
	var blocks := {}
	var WATER_LEVEL := 0.0

var report_path := ""
var run_token := ""

func _ready() -> void:
	report_path = OS.get_environment("VOXEL_CROSS_REGION_LINK_REPORT")
	run_token = OS.get_environment("VOXEL_CROSS_REGION_LINK_RUN_TOKEN")
	call_deferred("run")

func run() -> void:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "cross_region_link_test"))
	var lower = NavigationBakeDescriptorScript.create("region:cross-link:lower", "cross-link-lower", AABB(Vector3(-1.0, -0.1, -1.0), Vector3(2.0, 0.2, 0.9)))
	lower.add_walkable_surface("surface:lower", Vector3(0.0, 0.0, -0.55), Vector3(2.0, 0.05, 0.9))
	lower.add_navigation_link("link:cross-region", Vector3(0.0, 0.0, -0.16), Vector3(0.0, 0.0, 0.16), {
		"bidirectional": true,
		"cost": 1.1,
		"startRegionId": "region:cross-link:lower",
		"endRegionId": "region:cross-link:upper"
	})
	var upper = NavigationBakeDescriptorScript.create("region:cross-link:upper", "cross-link-upper", AABB(Vector3(-1.0, -0.1, 0.1), Vector3(2.0, 0.2, 0.9)))
	upper.add_walkable_surface("surface:upper", Vector3(0.0, 0.0, 0.55), Vector3(2.0, 0.05, 0.9))
	var lower_registration: Dictionary = service.register_chunk_descriptor(lower)
	var pending_after_lower: Dictionary = service.stats()
	var upper_registration: Dictionary = service.register_chunk_descriptor(upper)
	var deferred_publication: Array = service.process_dirty_regions(1, 100000)
	await get_tree().physics_frame
	var owner_rebuilds: Array = service.process_dirty_regions(1, 100000)
	for _frame in range(5):
		await get_tree().physics_frame
	service.sync_navigation_map_if_dirty()
	var route_forward: Dictionary = service.query_route(Vector3(0.0, 0.0, -0.55), Vector3(0.0, 0.0, 0.55), {"maxSnapDistance": 1.0})
	var route_reverse: Dictionary = service.query_route(Vector3(0.0, 0.0, 0.55), Vector3(0.0, 0.0, -0.55), {"maxSnapDistance": 1.0})
	var links_before_unload: Array = service.debug_snapshot().get("navigationLinks", []) as Array
	var upper_unregistration: Dictionary = service.unregister_chunk("region:cross-link:upper")
	var pending_after_unload: Dictionary = service.stats()
	var route_while_unavailable: Dictionary = service.query_route(Vector3(0.0, 0.0, -0.55), Vector3(0.0, 0.0, 0.55), {"maxSnapDistance": 1.0})
	var upper_recovery: Dictionary = service.register_chunk_descriptor(upper)
	var recovery_deferred: Array = service.process_dirty_regions(1, 100000)
	await get_tree().physics_frame
	var recovery_rebuilds: Array = service.process_dirty_regions(1, 100000)
	for _frame in range(5):
		await get_tree().physics_frame
	service.sync_navigation_map_if_dirty()
	var recovered_forward: Dictionary = service.query_route(Vector3(0.0, 0.0, -0.55), Vector3(0.0, 0.0, 0.55), {"maxSnapDistance": 1.0})
	var recovered_reverse: Dictionary = service.query_route(Vector3(0.0, 0.0, 0.55), Vector3(0.0, 0.0, -0.55), {"maxSnapDistance": 1.0})
	var fixture_scale_routes: Dictionary = await run_fixture_scale_link_probe()
	var same_region_routes: Dictionary = await run_same_region_link_probe()
	var chained_same_region_routes: Dictionary = await run_chained_same_region_link_probe()
	var region_edge_then_link_routes: Dictionary = await run_region_edge_then_link_probe()
	var inset_endpoint_link_routes: Dictionary = await run_inset_endpoint_link_probe()
	var cross_region_then_interior_link_routes: Dictionary = await run_cross_region_then_interior_link_probe()
	var conforming_passage_mesh_routes: Dictionary = await run_conforming_passage_mesh_probe()
	var citadel_doorway_mesh_routes: Dictionary = await run_citadel_doorway_mesh_probe()
	var collision_safe_support_seams: Dictionary = run_collision_safe_support_seam_probe()
	var stats: Dictionary = service.stats()
	var readiness: Dictionary = stats.get("navigationMapReadiness", {}) as Dictionary
	var owner_rebuilds_lower := owner_rebuilds.size() == 1 and owner_rebuilds[0] is Dictionary and String((owner_rebuilds[0] as Dictionary).get("regionId", "")) == "region:cross-link:lower"
	var recovery_rebuilds_lower := recovery_rebuilds.size() == 1 and recovery_rebuilds[0] is Dictionary and String((recovery_rebuilds[0] as Dictionary).get("regionId", "")) == "region:cross-link:lower"
	var passed := bool(lower_registration.get("installed", false)) and bool(upper_registration.get("installed", false)) and deferred_publication.is_empty() and owner_rebuilds_lower and int(pending_after_lower.get("pendingNavigationLinkCount", 0)) == 1 and bool(upper_unregistration.get("status", "") == "unregistered") and int(pending_after_unload.get("pendingNavigationLinkCount", 0)) == 1 and int(pending_after_unload.get("installedNavigationLinkCount", 0)) == 0 and String(route_while_unavailable.get("status", "")) == "pending" and String(route_while_unavailable.get("reason", "")) == "pending_navigation_links" and bool(upper_recovery.get("installed", false)) and recovery_deferred.is_empty() and recovery_rebuilds_lower and int(stats.get("pendingNavigationLinkCount", 0)) == 0 and int(stats.get("installedNavigationLinkCount", 0)) == 1 and bool(readiness.get("ready", false)) and bool(route_forward.get("ok", false)) and bool(route_reverse.get("ok", false)) and bool(recovered_forward.get("ok", false)) and bool(recovered_reverse.get("ok", false)) and bool(same_region_routes.get("forward", {}).get("ok", false)) and bool(same_region_routes.get("reverse", {}).get("ok", false)) and bool(chained_same_region_routes.get("forward", {}).get("ok", false)) and bool(chained_same_region_routes.get("reverse", {}).get("ok", false)) and bool(region_edge_then_link_routes.get("forward", {}).get("ok", false)) and bool(region_edge_then_link_routes.get("reverse", {}).get("ok", false)) and bool(citadel_doorway_mesh_routes.get("passageToDoor", {}).get("ok", false)) and bool(citadel_doorway_mesh_routes.get("sleepingToDoor", {}).get("ok", false)) and bool(collision_safe_support_seams.get("passed", false))
	write_report({
		"runnerId": "navmesh_cross_region_link",
		"evidenceLevel": "server_functional",
		"passed": passed,
		"runToken": run_token,
		"lowerRegistration": lower_registration,
		"pendingAfterLower": pending_after_lower,
		"upperRegistration": upper_registration,
		"deferredPublication": deferred_publication,
		"ownerRebuilds": owner_rebuilds,
		"linksBeforeUnload": links_before_unload,
		"upperUnregistration": upper_unregistration,
		"pendingAfterUnload": pending_after_unload,
		"routeWhileUnavailable": route_while_unavailable,
		"upperRecovery": upper_recovery,
		"recoveryDeferred": recovery_deferred,
		"recoveryRebuilds": recovery_rebuilds,
		"recoveredForward": recovered_forward,
		"recoveredReverse": recovered_reverse,
		"readiness": readiness,
		"routeForward": route_forward,
		"routeReverse": route_reverse,
		"overlappingFixtureScaleRoutes": fixture_scale_routes,
		"sameRegionRoutes": same_region_routes,
		"chainedSameRegionRoutes": chained_same_region_routes,
		"regionEdgeThenLinkRoutes": region_edge_then_link_routes,
		"insetEndpointLinkRoutes": inset_endpoint_link_routes,
		"crossRegionThenInteriorLinkRoutes": cross_region_then_interior_link_routes,
		"conformingPassageMeshRoutes": conforming_passage_mesh_routes,
		"citadelDoorwayMeshRoutes": citadel_doorway_mesh_routes,
		"collisionSafeSupportSeams": collision_safe_support_seams,
		"stats": stats
	})
	service.clear()
	get_tree().quit(0 if passed else 1)


func run_fixture_scale_link_probe() -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "cross_region_fixture_scale_test"))
	var lower = NavigationBakeDescriptorScript.create("region:fixture-scale:lower", "fixture-scale-lower", AABB(Vector3(-2281.55, 22.20, 165.56), Vector3(7.18, 0.52, 6.60)))
	lower.add_walkable_surface("surface:fixture-scale:lower", Vector3(-2277.96, 22.46, 168.86), Vector3(7.18, 0.05, 6.60))
	lower.add_navigation_link("link:fixture-scale-cross-region", Vector3(-2277.96, 22.46, 171.801), Vector3(-2277.96, 22.46, 172.449), {
		"bidirectional": true,
		"cost": 0.648,
		"startRegionId": "region:fixture-scale:lower",
		"endRegionId": "region:fixture-scale:upper"
	})
	var upper = NavigationBakeDescriptorScript.create("region:fixture-scale:upper", "fixture-scale-upper", AABB(Vector3(-2281.55, 22.20, 172.12), Vector3(7.18, 0.52, 3.02)))
	upper.add_walkable_surface("surface:fixture-scale:upper", Vector3(-2277.96, 22.46, 173.63), Vector3(7.18, 0.05, 3.02))
	service.register_chunk_descriptor(lower)
	service.register_chunk_descriptor(upper)
	for _frame in range(5):
		await get_tree().physics_frame
	service.sync_navigation_map_if_dirty()
	var forward := service.query_route(Vector3(-2275.088, 22.46, 168.89), Vector3(-2278.8, 22.46, 172.8), {"maxSnapDistance": 1.0})
	var reverse := service.query_route(Vector3(-2278.8, 22.46, 172.8), Vector3(-2275.088, 22.46, 168.89), {"maxSnapDistance": 1.0})
	service.clear()
	return {"forward": forward, "reverse": reverse}


func run_same_region_link_probe() -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "same_region_link_test"))
	var descriptor = NavigationBakeDescriptorScript.create("region:same-link", "same-link", AABB(Vector3(-1.0, -0.1, -1.0), Vector3(2.0, 0.2, 2.0)))
	descriptor.add_walkable_surface("surface:same-link:left", Vector3(0.0, 0.0, -0.55), Vector3(2.0, 0.05, 0.9))
	descriptor.add_walkable_surface("surface:same-link:right", Vector3(0.0, 0.0, 0.55), Vector3(2.0, 0.05, 0.9))
	descriptor.add_navigation_link("link:same-region", Vector3(0.0, 0.0, -0.55), Vector3(0.0, 0.0, 0.55), {"bidirectional": true, "cost": 1.1})
	var registration: Dictionary = service.register_chunk_descriptor(descriptor)
	for _frame in range(5):
		await get_tree().physics_frame
	service.sync_navigation_map_if_dirty()
	var forward := service.query_route(Vector3(0.0, 0.0, -0.55), Vector3(0.0, 0.0, 0.55), {"maxSnapDistance": 1.0})
	var reverse := service.query_route(Vector3(0.0, 0.0, 0.55), Vector3(0.0, 0.0, -0.55), {"maxSnapDistance": 1.0})
	var stats: Dictionary = service.stats()
	service.clear()
	return {"registration": registration, "forward": forward, "reverse": reverse, "stats": stats}


func run_chained_same_region_link_probe() -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "chained_same_region_link_test"))
	var descriptor = NavigationBakeDescriptorScript.create("region:chained-link", "chained-link", AABB(Vector3(-1.0, -0.1, -3.0), Vector3(2.0, 0.2, 6.0)))
	descriptor.add_walkable_surface("surface:chained-link:south", Vector3(0.0, 0.0, -2.2), Vector3(2.0, 0.05, 1.2))
	descriptor.add_walkable_surface("surface:chained-link:middle", Vector3(0.0, 0.0, 0.0), Vector3(2.0, 0.05, 1.2))
	descriptor.add_walkable_surface("surface:chained-link:north", Vector3(0.0, 0.0, 2.2), Vector3(2.0, 0.05, 1.2))
	descriptor.add_navigation_link("link:chained-link:south-middle", Vector3(0.0, 0.0, -1.6), Vector3(0.0, 0.0, -0.6), {"bidirectional": true, "cost": 1.0})
	descriptor.add_navigation_link("link:chained-link:middle-north", Vector3(0.0, 0.0, 0.6), Vector3(0.0, 0.0, 1.6), {"bidirectional": true, "cost": 1.0})
	var registration: Dictionary = service.register_chunk_descriptor(descriptor)
	for _frame in range(5):
		await get_tree().physics_frame
	service.sync_navigation_map_if_dirty()
	var forward := service.query_route(Vector3(0.0, 0.0, -2.6), Vector3(0.0, 0.0, 2.6), {"maxSnapDistance": 1.0})
	var reverse := service.query_route(Vector3(0.0, 0.0, 2.6), Vector3(0.0, 0.0, -2.6), {"maxSnapDistance": 1.0})
	var stats: Dictionary = service.stats()
	service.clear()
	return {"registration": registration, "forward": forward, "reverse": reverse, "stats": stats}


func run_region_edge_then_link_probe() -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "region_edge_then_link_test"))
	var lower = NavigationBakeDescriptorScript.create("region:edge-link:lower", "edge-link-lower", AABB(Vector3(-1.0, -0.1, -3.0), Vector3(2.0, 0.2, 4.4)))
	lower.add_walkable_surface("surface:edge-link:lower:sleeping", Vector3(0.0, 0.0, 0.4), Vector3(2.0, 0.05, 1.6))
	lower.add_walkable_surface("surface:edge-link:lower:hearth", Vector3(0.0, 0.0, -2.0), Vector3(2.0, 0.05, 1.4))
	lower.add_navigation_link("link:edge-link:interior-passage", Vector3(0.0, 0.0, -1.3), Vector3(0.0, 0.0, -0.4), {"bidirectional": true, "cost": 0.9})
	var upper = NavigationBakeDescriptorScript.create("region:edge-link:upper", "edge-link-upper", AABB(Vector3(-1.0, -0.1, 1.0), Vector3(2.0, 0.2, 2.0)))
	upper.add_walkable_surface("surface:edge-link:upper", Vector3(0.0, 0.0, 2.0), Vector3(2.0, 0.05, 2.0))
	var lower_registration: Dictionary = service.register_chunk_descriptor(lower)
	var upper_registration: Dictionary = service.register_chunk_descriptor(upper)
	for _frame in range(5):
		await get_tree().physics_frame
	service.sync_navigation_map_if_dirty()
	var forward := service.query_route(Vector3(0.0, 0.0, 2.6), Vector3(0.0, 0.0, -2.6), {"maxSnapDistance": 1.0})
	var reverse := service.query_route(Vector3(0.0, 0.0, -2.6), Vector3(0.0, 0.0, 2.6), {"maxSnapDistance": 1.0})
	var stats: Dictionary = service.stats()
	service.clear()
	return {"lowerRegistration": lower_registration, "upperRegistration": upper_registration, "forward": forward, "reverse": reverse, "stats": stats}


func run_inset_endpoint_link_probe() -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "inset_endpoint_link_test"))
	var descriptor = NavigationBakeDescriptorScript.create("region:inset-endpoint-link", "inset-endpoint-link", AABB(Vector3(-1.0, -0.1, -3.0), Vector3(2.0, 0.2, 6.0)))
	descriptor.add_walkable_surface("surface:inset-endpoint-link:south", Vector3(0.0, 0.0, -2.2), Vector3(2.0, 0.05, 1.6))
	descriptor.add_walkable_surface("surface:inset-endpoint-link:north", Vector3(0.0, 0.0, 2.2), Vector3(2.0, 0.05, 1.6))
	descriptor.add_navigation_link("link:inset-endpoint-link", Vector3(0.0, 0.0, -1.6), Vector3(0.0, 0.0, 1.6), {"bidirectional": true, "cost": 3.2})
	var registration: Dictionary = service.register_chunk_descriptor(descriptor)
	for _frame in range(5):
		await get_tree().physics_frame
	service.sync_navigation_map_if_dirty()
	var forward := service.query_route(Vector3(0.0, 0.0, -2.8), Vector3(0.0, 0.0, 2.8), {"maxSnapDistance": 1.0})
	var reverse := service.query_route(Vector3(0.0, 0.0, 2.8), Vector3(0.0, 0.0, -2.8), {"maxSnapDistance": 1.0})
	var stats: Dictionary = service.stats()
	service.clear()
	return {"registration": registration, "forward": forward, "reverse": reverse, "stats": stats}


func run_cross_region_then_interior_link_probe() -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "cross_region_then_interior_link_test"))
	var upper = NavigationBakeDescriptorScript.create("region:cross-chain:upper", "cross-chain-upper", AABB(Vector3(-1.0, -0.1, 1.8), Vector3(2.0, 0.2, 1.4)))
	upper.add_walkable_surface("surface:cross-chain:upper", Vector3(0.0, 0.0, 2.5), Vector3(2.0, 0.05, 1.4))
	var lower = NavigationBakeDescriptorScript.create("region:cross-chain:lower", "cross-chain-lower", AABB(Vector3(-1.0, -0.1, -3.0), Vector3(2.0, 0.2, 4.0)))
	lower.add_walkable_surface("surface:cross-chain:lower:sleeping", Vector3(0.0, 0.0, 0.3), Vector3(2.0, 0.05, 1.4))
	lower.add_walkable_surface("surface:cross-chain:lower:hearth", Vector3(0.0, 0.0, -2.1), Vector3(2.0, 0.05, 1.4))
	lower.add_navigation_link("link:cross-chain:seam", Vector3(0.0, 0.0, 1.0), Vector3(0.0, 0.0, 1.8), {
		"bidirectional": true,
		"cost": 0.8,
		"startRegionId": "region:cross-chain:lower",
		"endRegionId": "region:cross-chain:upper"
	})
	lower.add_navigation_link("link:cross-chain:interior", Vector3(0.0, 0.0, -0.4), Vector3(0.0, 0.0, -1.4), {"bidirectional": true, "cost": 1.0})
	var upper_registration: Dictionary = service.register_chunk_descriptor(upper)
	var lower_registration: Dictionary = service.register_chunk_descriptor(lower)
	for _frame in range(5):
		await get_tree().physics_frame
	service.sync_navigation_map_if_dirty()
	var forward := service.query_route(Vector3(0.0, 0.0, 2.8), Vector3(0.0, 0.0, -2.7), {"maxSnapDistance": 1.0})
	var reverse := service.query_route(Vector3(0.0, 0.0, -2.7), Vector3(0.0, 0.0, 2.8), {"maxSnapDistance": 1.0})
	var stats: Dictionary = service.stats()
	service.clear()
	return {"upperRegistration": upper_registration, "lowerRegistration": lower_registration, "forward": forward, "reverse": reverse, "stats": stats}


func run_conforming_passage_mesh_probe() -> Dictionary:
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	var support := {
		"id": "support:conforming-passage",
		"cell": Vector3i.ZERO,
		"worldPosition": Vector3(1.12, 0.0, 0.48),
		"floorNormal": Vector3.UP,
		"headroom": 3.0,
		"lateralClearance": 1.0,
		"traversalTags": ["building", "support"],
		"sourcePartId": "floor:conforming-passage",
		"sourceCollisionPartId": "floor:conforming-passage"
	}
	var cells := {}
	for column in range(7):
		cells[Vector2i(column, 0)] = Vector3((float(column) + 0.5) * 0.32, 0.04, 0.16)
		cells[Vector2i(column, 2)] = Vector3((float(column) + 0.5) * 0.32, 0.04, 0.80)
	cells[Vector2i(3, 1)] = Vector3(1.12, 0.04, 0.48)
	var surface_value = adapter.call("_merged_building_support_navmesh_surfaces", support, cells, 1)
	var surfaces: Array = surface_value if surface_value is Array else []
	var descriptor = NavigationBakeDescriptorScript.create("region:conforming-passage", "conforming-passage", AABB(Vector3(0.0, -0.1, 0.0), Vector3(2.24, 0.2, 0.96)))
	for surface_value_item in surfaces:
		if not (surface_value_item is Dictionary):
			continue
		var surface: Dictionary = surface_value_item
		descriptor.add_walkable_surface(String(surface.get("id", "surface:conforming-passage")), surface.get("worldPosition", Vector3.ZERO), Vector3(0.32, 0.05, 0.32), {"polygon": surface.get("polygon", [])})
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "conforming_passage_mesh_test"))
	var registration: Dictionary = service.register_chunk_descriptor(descriptor)
	for _frame in range(5):
		await get_tree().physics_frame
	service.sync_navigation_map_if_dirty()
	var forward := service.query_route(Vector3(1.12, 0.04, 0.16), Vector3(1.12, 0.04, 0.80), {"maxSnapDistance": 0.5})
	var reverse := service.query_route(Vector3(1.12, 0.04, 0.80), Vector3(1.12, 0.04, 0.16), {"maxSnapDistance": 0.5})
	var stats: Dictionary = service.stats()
	service.clear()
	return {"registration": registration, "surfaceCount": surfaces.size(), "forward": forward, "reverse": reverse, "stats": stats}


func run_collision_safe_support_seam_probe() -> Dictionary:
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	var source := SeamManifestSource.new()
	var main := SeamFixtureMain.new()
	var support := {
		"id": "support:collision-safe-seam",
		"cell": Vector3i.ZERO,
		"worldPosition": Vector3(0.0, 0.0, 20.25),
		"floorNormal": Vector3.UP,
		"headroom": 3.0,
		"lateralClearance": 4.0,
		"traversalTags": ["building", "support"],
		"sourcePartId": "floor:collision-safe-seam",
		"sourceCollisionPartId": "floor:collision-safe-seam",
		"tileKeys": ["0,0", "0,1"],
		"polygon": [
			Vector3(-4.0, 0.0, 18.0),
			Vector3(-4.0, 0.0, 22.5),
			Vector3(4.0, 0.0, 22.5),
			Vector3(4.0, 0.0, 18.0)
		]
	}
	var table := {
		"id": "furnishing:seam-table",
		"sourcePartId": "furnishing:seam-table",
		"minX": -1.0,
		"maxX": 1.0,
		"minY": 0.0,
		"maxY": 1.8,
		"minZ": 18.6,
		"maxZ": 21.9
	}
	var snapshot := {
		"staticCollisionByCell": {},
		"staticCollisionBroad": [table]
	}
	source.building_manifests = [{
		"supports": [support],
		"verticalLinks": [],
		"supportSeamLinks": [],
		"interiorPassageLinks": [],
		"doors": [],
		"staticCollision": []
	}]
	source.collision_manifests = [{"sourceKind": "furnishing", "staticCollision": [{
		"id": "furnishing:seam-table",
		"sourcePartId": "furnishing:seam-table",
		"bounds": AABB(Vector3(-1.0, 0.0, 18.6), Vector3(2.0, 1.8, 3.3))
	}]}]
	adapter.setup(source, main)
	adapter.build_navmesh_tile_snapshot("0,0")
	var link := {
		"id": "link:collision-safe-seam",
		"kind": "support_seam",
		"axis": "z",
		"seamCoordinate": 20.25,
		"supportId": "support:collision-safe-seam",
		"start": Vector3(0.0, 0.04, 19.8),
		"end": Vector3(0.0, 0.04, 20.7),
		"startTileKey": "0,0",
		"endTileKey": "0,1",
		"ownerTileKey": "0,0",
		"bidirectional": true
	}
	var links: Array[Dictionary] = [link]
	var resolved_value = adapter.call("_resolve_building_navigation_link_endpoints", snapshot, links)
	var resolved: Array = resolved_value if resolved_value is Array else []
	var no_table_tunnel := not resolved.is_empty()
	for resolved_value_item in resolved:
		if not (resolved_value_item is Dictionary):
			no_table_tunnel = false
			continue
		var resolved_link: Dictionary = resolved_value_item
		var start: Vector3 = resolved_link.get("start", Vector3.INF) as Vector3
		var end: Vector3 = resolved_link.get("end", Vector3.INF) as Vector3
		var crossing_table_x := minf(start.x, end.x) <= 1.52 and maxf(start.x, end.x) >= -1.52
		var crossing_table_z := minf(start.z, end.z) <= 22.42 and maxf(start.z, end.z) >= 18.08
		if not start.is_finite() or not end.is_finite() or start.distance_to(end) > 1.20 or (crossing_table_x and crossing_table_z):
			no_table_tunnel = false
	var passed := not resolved.is_empty() and no_table_tunnel
	return {
		"passed": passed,
		"resolvedLinks": resolved,
		"startSamples": adapter.building_support_navigation_sample_diagnostics("support:collision-safe-seam", "0,0"),
		"endSamples": adapter.building_support_navigation_sample_diagnostics("support:collision-safe-seam", "0,1")
	}


func run_citadel_doorway_mesh_probe() -> Dictionary:
	var descriptor = NavigationBakeDescriptorScript.create("region:citadel-doorway", "citadel-doorway", AABB(Vector3(-2281.2, 22.3, 168.0), Vector3(6.8, 0.4, 5.2)))
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	var support := {
		"id": "support:citadel-doorway",
		"cell": Vector3i.ZERO,
		"worldPosition": Vector3(0.0, 22.42, 0.0),
		"floorNormal": Vector3.UP,
		"headroom": 3.0,
		"lateralClearance": 1.0,
		"traversalTags": ["building", "support"],
		"sourcePartId": "floor:citadel-doorway",
		"sourceCollisionPartId": "floor:citadel-doorway"
	}
	var rows := [
		[168.64, 168.96, [[-2280.64, -2278.4], [-2277.12, -2274.88]]],
		[168.96, 169.28, [[-2280.64, -2278.4], [-2277.12, -2274.88]]],
		[169.28, 169.60, [[-2280.64, -2278.4], [-2278.4, -2277.12], [-2277.12, -2274.88]]],
		[169.60, 169.92, [[-2280.96, -2278.4], [-2278.4, -2277.44], [-2277.44, -2274.88]]],
		[169.92, 170.24, [[-2278.4, -2277.44]]],
		[170.24, 170.56, [[-2278.4, -2277.44]]],
		[170.56, 170.88, [[-2278.4, -2277.44]]],
		[170.88, 171.20, [[-2279.68, -2278.4], [-2278.4, -2277.44], [-2277.44, -2274.88]]],
		[171.20, 171.52, [[-2279.68, -2274.88]]],
		[171.52, 171.84, [[-2279.68, -2274.88]]],
		[171.84, 172.16, [[-2279.68, -2274.88]]],
		[172.16, 172.48, [[-2279.68, -2274.88]]],
		[172.48, 172.80, [[-2279.68, -2274.88]]],
		[172.80, 173.12, [[-2279.68, -2274.88]]]
	]
	var cells := {}
	for row_value in rows:
		if not (row_value is Array):
			continue
		var row: Array = row_value
		var min_z := float(row[0])
		var max_z := float(row[1])
		var first_z := roundi(min_z / 0.32)
		var last_z := roundi(max_z / 0.32)
		var runs: Array = row[2] as Array
		for run_value in runs:
			if not (run_value is Array):
				continue
			var run: Array = run_value
			var min_x := float(run[0])
			var max_x := float(run[1])
			var first_x := roundi(min_x / 0.32)
			var last_x := roundi(max_x / 0.32)
			for z in range(first_z, last_z):
				for x in range(first_x, last_x):
					cells[Vector2i(x, z)] = Vector3((float(x) + 0.5) * 0.32, 22.46, (float(z) + 0.5) * 0.32)
	var surface_value = adapter.call("_merged_building_support_navmesh_surfaces", support, cells, 1)
	var surfaces: Array = surface_value if surface_value is Array else []
	for surface_value_item in surfaces:
		if not (surface_value_item is Dictionary):
			continue
		var surface: Dictionary = surface_value_item
		descriptor.add_walkable_surface(String(surface.get("id", "surface:citadel-doorway")), surface.get("worldPosition", Vector3.ZERO), Vector3(0.32, 0.05, 0.32), {"polygon": surface.get("polygon", [])})
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "citadel_doorway_mesh_test"))
	var registration: Dictionary = service.register_chunk_descriptor(descriptor)
	for _frame in range(5):
		await get_tree().physics_frame
	service.sync_navigation_map_if_dirty()
	var passage_to_door := service.query_route(Vector3(-2277.92, 22.46, 169.76), Vector3(-2275.088, 22.46, 168.89), {"maxSnapDistance": 0.8})
	var sleeping_to_door := service.query_route(Vector3(-2278.8, 22.46, 172.8), Vector3(-2275.088, 22.46, 168.89), {"maxSnapDistance": 0.8})
	var stats: Dictionary = service.stats()
	service.clear()
	return {"registration": registration, "surfaceCount": surfaces.size(), "passageToDoor": passage_to_door, "sleepingToDoor": sleeping_to_door, "stats": stats}

func write_report(report: Dictionary) -> void:
	if report_path.is_empty():
		return
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(report, "\t"))
