extends Node

const NavigationBackendConfigScript := preload("res://scripts/npc_ai/navigation/NavigationBackendConfig.gd")
const NavigationBakeDescriptorScript := preload("res://scripts/npc_ai/contracts/NavigationBakeDescriptor.gd")
const GeneratedWorldNavigationAdapterScript := preload("res://scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd")
const NavmeshWorldServiceScript := preload("res://scripts/npc_ai/navigation/NavmeshWorldService.gd")
const NpcAutonomySystemScript := preload("res://scripts/npc_ai/NpcAutonomySystem.gd")
const NpcRouteLeaseExecutorScript := preload("res://scripts/npc_ai/movement/NpcRouteLeaseExecutor.gd")
const NpcPlanExecutorScript := preload("res://scripts/npc_ai/behavior/NpcPlanExecutor.gd")
const ReciprocalAvoidanceAdapterScript := preload("res://scripts/npc_ai/movement/ReciprocalAvoidanceAdapter.gd")
const CharacterMotor3DScript := preload("res://scripts/npc_ai/motor/CharacterMotor3D.gd")
const CharacterMotorCommandScript := preload("res://scripts/npc_ai/contracts/CharacterMotorCommand.gd")
const CharacterMotorProfileScript := preload("res://scripts/npc_ai/contracts/CharacterMotorProfile.gd")
const NavmeshRoutePlannerScript := preload("res://scripts/npc_ai/routing/NavmeshRoutePlanner.gd")
const NpcRouteCoordinatorAdapterScript := preload("res://scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd")
const NpcNavigationCoordinatorScript := preload("res://scripts/npc_ai/routing/NpcNavigationCoordinator.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const StructureSystemScript := preload("res://scripts/StructureSystem.gd")

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
	var WATER_LEVEL := -10.0
	var world_generation_system = null

	func surface_y_at_cell(_cell: Vector3i) -> float:
		return 0.0

class SurfaceTransitionCrowdAuthority extends RefCounted:
	var adapter = ReciprocalAvoidanceAdapterScript.new()

	func _init() -> void:
		adapter.setup(null, null)

	func resolve_safe_velocity(entry: Dictionary, body: CharacterBody3D, desired_velocity: Vector3, context := {}) -> Dictionary:
		return adapter.compute_safe_velocity(entry, body, desired_velocity, context)

	func disable_actor(actor_id: String) -> void:
		adapter.disable_actor(actor_id)

	func stats() -> Dictionary:
		return adapter.stats()

class TransitionFixturePathing extends RefCounted:
	var navigation_world

	func ensure_ready() -> void:
		pass

class TransitionFixtureNpcSystem extends Node:
	var pathing
	var npcs: Array = []

	func _init(navigation_adapter) -> void:
		pathing = TransitionFixturePathing.new()
		pathing.navigation_world = navigation_adapter

class RaisedFloorTerrainProvider extends Node:
	var lower_ground_y := 0.59

	func ground_y_near_position(_position: Vector3) -> float:
		return lower_ground_y

	func surface_y_at_position(_position: Vector3) -> float:
		return lower_ground_y

class CoalescingNavigationWorld extends RefCounted:
	var source_revision := 1
	var build_count := 0
	var build_order: Array[String] = []

	func navmesh_tile_source_key_for_tile(tile_key: String) -> String:
		return "%d:%s" % [source_revision, tile_key]

	func navmesh_affected_tile_keys_for_change(tile_key: String) -> Array[String]:
		return [tile_key]

	func route_navmesh_tile_keys(_entry: Dictionary, _start: Vector3, _target: Vector3, _allow_outside := false, _moving_home := false, _margin_cells := 0) -> Array[String]:
		return ["0,0"]

	func tile_key_for_cell(_cell: Vector2i) -> String:
		return "0,0"

	func world_cell(position: Vector3) -> Vector2i:
		return Vector2i(roundi(position.x / NpcConstantsScript.CELL_SIZE), roundi(position.z / NpcConstantsScript.CELL_SIZE))

	func build_navmesh_tile_snapshot(tile_key: String) -> Dictionary:
		build_count += 1
		build_order.append(tile_key)
		return {
			"tileKey": tile_key,
			"regionId": "region:chunk:%s" % tile_key,
			"sourceKey": navmesh_tile_source_key_for_tile(tile_key),
			"sourceRevision": source_revision,
			"authoritativeSourceReady": true,
			"surfaces": [{
				"cell": Vector3i.ZERO,
				"worldPosition": Vector3.ZERO,
				"size": Vector3(4.0, 0.05, 4.0),
				"floorNormal": Vector3.UP,
				"headroom": 3.0,
				"lateralClearance": 1.0
			}],
			"doorLinks": [],
			"navigationLinks": []
		}

class RetryRotationNavigationWorld extends RefCounted:
	var build_order: Array[String] = []
	var blocked_tile := "20,0"

	func navmesh_tile_source_key_for_tile(tile_key: String) -> String:
		return "1:%s" % tile_key

	func build_navmesh_tile_snapshot(tile_key: String) -> Dictionary:
		build_order.append(tile_key)
		return {
			"tileKey": tile_key,
			"regionId": "region:chunk:%s" % tile_key,
			"sourceKey": navmesh_tile_source_key_for_tile(tile_key),
			"sourceRevision": 1,
			"authoritativeSourceReady": true,
			"surfaces": [{
				"cell": Vector3i.ZERO,
				"worldPosition": Vector3.ZERO,
				"size": Vector3(4.0, 0.05, 4.0),
				"floorNormal": Vector3.UP,
				"headroom": 3.0,
				"lateralClearance": 1.0
			}],
			"doorLinks": [
				{"id": "door-link:shared", "portalId": "door:shared"},
				{"id": "door-link:shared", "portalId": "door:shared"}
			] if tile_key == "21,0" else [],
			"navigationLinks": [{"id": "pending:%s" % tile_key}] if tile_key == blocked_tile else []
		}

class LinkValidationNavigationWorld extends RefCounted:
	var mode := "identical"

	func navmesh_tile_source_key_for_tile(tile_key: String) -> String:
		return "1:%s:%s" % [mode, tile_key]

	func build_navmesh_tile_snapshot(tile_key: String) -> Dictionary:
		var door_links: Array = []
		var navigation_links: Array = []
		if mode == "identical":
			door_links = [
				{"id": "door-link:identical", "portalId": "door:identical", "start": Vector3.ZERO, "end": Vector3.RIGHT},
				{"id": "door-link:identical", "portalId": "door:identical", "start": Vector3.ZERO, "end": Vector3.RIGHT}
			]
		elif mode == "empty_id":
			navigation_links = [{"start": Vector3.ZERO, "end": Vector3.RIGHT}]
		elif mode == "conflict":
			door_links = [
				{"id": "door-link:conflict", "portalId": "door:conflict", "start": Vector3.ZERO, "end": Vector3.RIGHT},
				{"id": "door-link:conflict", "portalId": "door:conflict", "start": Vector3.ZERO, "end": Vector3.FORWARD}
			]
		return {
			"tileKey": tile_key,
			"regionId": "region:chunk:%s" % tile_key,
			"sourceKey": navmesh_tile_source_key_for_tile(tile_key),
			"sourceRevision": 1,
			"authoritativeSourceReady": true,
			"surfaces": [{"cell": Vector3i.ZERO, "worldPosition": Vector3.ZERO, "size": Vector3(4.0, 0.05, 4.0), "floorNormal": Vector3.UP, "headroom": 3.0, "lateralClearance": 1.0}],
			"doorLinks": door_links,
			"navigationLinks": navigation_links
		}

class MultiPendingNavigationWorld extends RefCounted:
	var build_order: Array[String] = []
	var build_attempts := {}
	var pending_tile := "30,0"
	var invalid_tile := "31,0"
	var empty_tile := "32,0"

	func navmesh_tile_source_key_for_tile(tile_key: String) -> String:
		return "1:%s" % tile_key

	func build_navmesh_tile_snapshot(tile_key: String) -> Dictionary:
		build_order.append(tile_key)
		build_attempts[tile_key] = int(build_attempts.get(tile_key, 0)) + 1
		var attempt := int(build_attempts.get(tile_key, 0))
		if tile_key == empty_tile and attempt <= 2:
			return {}
		var navigation_links: Array = []
		if tile_key == pending_tile:
			navigation_links = [{"id": "pending:%s" % tile_key}]
		elif tile_key == invalid_tile and attempt <= 2:
			navigation_links = [
				{"id": "invalid:%s" % tile_key, "start": Vector3.ZERO, "end": Vector3.RIGHT},
				{"id": "invalid:%s" % tile_key, "start": Vector3.ZERO, "end": Vector3.FORWARD}
			]
		return {
			"tileKey": tile_key,
			"regionId": "region:chunk:%s" % tile_key,
			"sourceKey": navmesh_tile_source_key_for_tile(tile_key),
			"sourceRevision": 1,
			"authoritativeSourceReady": true,
			"surfaces": [{"cell": Vector3i.ZERO, "worldPosition": Vector3.ZERO, "size": Vector3(4.0, 0.05, 4.0), "floorNormal": Vector3.UP, "headroom": 3.0, "lateralClearance": 1.0}],
			"doorLinks": [],
			"navigationLinks": navigation_links
		}

class MultiPendingNavmeshService extends SelectivePendingNavmeshService:
	var pending_attempt_limit := 2

	func register_tile_snapshot(snapshot: Dictionary) -> Dictionary:
		var tile_key := String(snapshot.get("tileKey", ""))
		if tile_key == blocked_tile and int(attempts.get(tile_key, 0)) + 1 > pending_attempt_limit:
			var previous_blocked_tile := blocked_tile
			blocked_tile = ""
			var result := super.register_tile_snapshot(snapshot)
			blocked_tile = previous_blocked_tile
			return result
		return super.register_tile_snapshot(snapshot)

class SelectivePendingNavmeshService extends RefCounted:
	var blocked_tile := "20,0"
	var statuses := {}
	var attempts := {}
	var registration_count := 0

	func register_tile_snapshot(snapshot: Dictionary) -> Dictionary:
		registration_count += 1
		var tile_key := String(snapshot.get("tileKey", ""))
		attempts[tile_key] = int(attempts.get(tile_key, 0)) + 1
		var blocked := tile_key == blocked_tile
		var installed_door_links := _unique_link_count(snapshot.get("doorLinks", []) as Array, true)
		var installed_navigation_links := 0 if blocked else _unique_link_count(snapshot.get("navigationLinks", []) as Array, false)
		var install := {
			"status": "installed",
			"doorLinks": {"installed": installed_door_links, "failed": 0, "pending": 0},
			"navigationLinks": {"installed": installed_navigation_links, "failed": 0, "pending": 1 if blocked else 0}
		}
		statuses[tile_key] = {
			"tileKey": tile_key,
			"regionId": String(snapshot.get("regionId", "")),
			"registered": true,
			"state": "installed",
			"surfaceCount": (snapshot.get("surfaces", []) as Array).size(),
			"sourceRevision": int(snapshot.get("sourceRevision", 0)),
			"sourceKey": String(snapshot.get("sourceKey", "")),
			"installed": true,
			"dirty": false,
			"installStatus": "installed",
			"install": install.duplicate(true)
		}
		return {"status": "installed", "installed": true, "install": install}

	func tile_region_status(tile_key: String) -> Dictionary:
		return (statuses.get(tile_key, {}) as Dictionary).duplicate(true)

	func sync_navigation_map_if_dirty() -> bool:
		return true

	func clear() -> void:
		statuses.clear()
		attempts.clear()

	func _unique_link_count(links: Array, door_links := false) -> int:
		var ids := {}
		for link_value in links:
			if not (link_value is Dictionary):
				continue
			var link: Dictionary = link_value
			var link_id := String(link.get("id", ""))
			if link_id.is_empty() and door_links:
				link_id = String(link.get("portalId", link.get("portal_id", "")))
			if not link_id.is_empty():
				ids[link_id] = true
		return ids.size()

class TopologyClassificationNpcSystem extends RefCounted:
	var replacements_ready := true
	var door_result := {"ready": true}

	func request_navigation_snapshot_replacement_priority(tile_keys: Array) -> Dictionary:
		return {"ok": true, "requestedTiles": tile_keys.duplicate()}

	func navigation_snapshot_replacements_ready(tile_keys: Array) -> Dictionary:
		return {"ready": replacements_ready, "reason": "" if replacements_ready else "tile_installation_proof_pending", "pendingTiles": [] if replacements_ready else tile_keys.duplicate(), "tileProofs": []}

	func prove_building_door_topology(_building_manifest: Dictionary, _residence_manifest: Dictionary) -> Dictionary:
		return door_result.duplicate(true)

class TopologyClassificationMain extends RefCounted:
	var npc_system

class BackgroundPressureMain extends RefCounted:
	var perf_chunk_ms := 40.0
	var perf_hostiles_ms := 0.0
	var runtime_perf_monitor = null

class PublicationIsolationRoutePlanner extends RefCounted:
	var publication_ticks := 0
	var route_begin_ticks := 0

	func advance_navmesh_publication_frame() -> void:
		publication_ticks += 1

	func begin_frame() -> void:
		route_begin_ticks += 1

class PublicationIsolationFrameParticipant extends RefCounted:
	var begin_ticks := 0

	func begin_frame() -> void:
		begin_ticks += 1

var report_path := ""
var run_token := ""

func _ready() -> void:
	report_path = OS.get_environment("VOXEL_CROSS_REGION_LINK_REPORT")
	run_token = OS.get_environment("VOXEL_CROSS_REGION_LINK_RUN_TOKEN")
	call_deferred("run")

func run() -> void:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "cross_region_link_test"))
	var lower = NavigationBakeDescriptorScript.create("region:cross-link:lower", "cross-link-lower", AABB(Vector3(-1.0, -0.1, -1.5), Vector3(2.0, 0.2, 1.0)))
	lower.add_walkable_surface("surface:lower", Vector3(0.0, 0.0, -1.0), Vector3(2.0, 0.05, 1.0))
	lower.add_navigation_link("link:cross-region", Vector3(0.0, 0.0, -0.45), Vector3(0.0, 0.0, 0.45), {
		"kind": "surface_transition",
		"bidirectional": true,
		"cost": 1.1,
		"requiresScriptedTraversal": true,
		"startSupportId": "manual:lower",
		"endSupportId": "manual:upper",
		"forwardTraversal": _manual_transition_bundle("forward", Vector3(0.0, 0.0, -1.40), Vector3(0.0, 0.0, -0.90), Vector3(0.0, 0.0, -0.45), Vector3(0.0, 0.0, 0.45), Vector3(0.0, 0.0, 0.90), "manual:lower", "manual:upper"),
		"reverseTraversal": _manual_transition_bundle("reverse", Vector3(0.0, 0.0, 1.40), Vector3(0.0, 0.0, 0.90), Vector3(0.0, 0.0, 0.45), Vector3(0.0, 0.0, -0.45), Vector3(0.0, 0.0, -0.90), "manual:upper", "manual:lower"),
		"certifiedCorridorWidth": 1.04,
		"capacity": 1,
		"sourceRevision": 1,
		"topologyRevision": 1,
		"startRegionId": "region:cross-link:lower",
		"endRegionId": "region:cross-link:upper"
	})
	var upper = NavigationBakeDescriptorScript.create("region:cross-link:upper", "cross-link-upper", AABB(Vector3(-1.0, -0.1, 0.5), Vector3(2.0, 0.2, 1.0)))
	upper.add_walkable_surface("surface:upper", Vector3(0.0, 0.0, 1.0), Vector3(2.0, 0.05, 1.0))
	var lower_registration: Dictionary = service.register_chunk_descriptor(lower)
	var pending_after_lower: Dictionary = service.stats()
	var upper_registration: Dictionary = service.register_chunk_descriptor(upper)
	var deferred_publication: Array = service.process_dirty_regions(1, 100000)
	await get_tree().physics_frame
	var owner_rebuilds: Array = service.process_dirty_regions(1, 100000)
	for _frame in range(5):
		await get_tree().physics_frame
	service.sync_navigation_map_if_dirty()
	var route_forward: Dictionary = service.query_route(Vector3(0.0, 0.0, -1.0), Vector3(0.0, 0.0, 1.0), {"maxSnapDistance": 0.30})
	var route_reverse: Dictionary = service.query_route(Vector3(0.0, 0.0, 1.0), Vector3(0.0, 0.0, -1.0), {"maxSnapDistance": 0.30})
	for _attempt in range(20):
		if not (route_forward.get("actions", {}) as Dictionary).is_empty() and not (route_reverse.get("actions", {}) as Dictionary).is_empty():
			break
		await get_tree().physics_frame
		service.sync_navigation_map_if_dirty()
		route_forward = service.query_route(Vector3(0.0, 0.0, -1.0), Vector3(0.0, 0.0, 1.0), {"maxSnapDistance": 0.30})
		route_reverse = service.query_route(Vector3(0.0, 0.0, 1.0), Vector3(0.0, 0.0, -1.0), {"maxSnapDistance": 0.30})
	var initial_action: Dictionary = (route_forward.get("actions", {}) as Dictionary).values()[0] as Dictionary if not (route_forward.get("actions", {}) as Dictionary).is_empty() else {}
	var initial_action_current := service.navigation_link_action_is_current(initial_action)
	var links_before_unload: Array = service.debug_snapshot().get("navigationLinks", []) as Array
	var upper_unregistration: Dictionary = service.unregister_chunk("region:cross-link:upper")
	var unloaded_action_current := service.navigation_link_action_is_current(initial_action)
	var pending_after_unload: Dictionary = service.stats()
	var route_while_unavailable: Dictionary = service.query_route(Vector3(0.0, 0.0, -1.0), Vector3(0.0, 0.0, 1.0), {"maxSnapDistance": 3.0})
	var upper_recovery: Dictionary = service.register_chunk_descriptor(upper)
	var recovery_deferred: Array = service.process_dirty_regions(1, 100000)
	await get_tree().physics_frame
	var recovery_rebuilds: Array = service.process_dirty_regions(1, 100000)
	for _frame in range(5):
		await get_tree().physics_frame
	service.sync_navigation_map_if_dirty()
	var recovered_forward: Dictionary = service.query_route(Vector3(0.0, 0.0, -1.0), Vector3(0.0, 0.0, 1.0), {"maxSnapDistance": 0.30})
	var recovered_reverse: Dictionary = service.query_route(Vector3(0.0, 0.0, 1.0), Vector3(0.0, 0.0, -1.0), {"maxSnapDistance": 0.30})
	for _attempt in range(20):
		if not (recovered_forward.get("actions", {}) as Dictionary).is_empty() and not (recovered_reverse.get("actions", {}) as Dictionary).is_empty():
			break
		await get_tree().physics_frame
		service.sync_navigation_map_if_dirty()
		recovered_forward = service.query_route(Vector3(0.0, 0.0, -1.0), Vector3(0.0, 0.0, 1.0), {"maxSnapDistance": 0.30})
		recovered_reverse = service.query_route(Vector3(0.0, 0.0, 1.0), Vector3(0.0, 0.0, -1.0), {"maxSnapDistance": 0.30})
	var recovered_action: Dictionary = (recovered_forward.get("actions", {}) as Dictionary).values()[0] as Dictionary if not (recovered_forward.get("actions", {}) as Dictionary).is_empty() else {}
	var recovered_action_current := service.navigation_link_action_is_current(recovered_action)
	var fixture_scale_routes: Dictionary = await run_fixture_scale_link_probe()
	var same_region_routes: Dictionary = await run_same_region_link_probe()
	var chained_same_region_routes: Dictionary = await run_chained_same_region_link_probe()
	var region_edge_then_link_routes: Dictionary = await run_region_edge_then_link_probe()
	var inset_endpoint_link_routes: Dictionary = await run_inset_endpoint_link_probe()
	var cross_region_then_interior_link_routes: Dictionary = await run_cross_region_then_interior_link_probe()
	var conforming_passage_mesh_routes: Dictionary = await run_conforming_passage_mesh_probe()
	var citadel_doorway_mesh_routes: Dictionary = await run_citadel_doorway_mesh_probe()
	var door_link_proof: Dictionary = await run_door_link_proof()
	var collision_safe_support_seams: Dictionary = run_collision_safe_support_seam_probe()
	var adjacent_support_transitions: Dictionary = await run_adjacent_support_transition_probe()
	var support_prop_detour: Dictionary = await run_support_prop_detour_probe()
	var surface_transition_traffic: Dictionary = await run_surface_transition_traffic_probe()
	var surface_transition_negatives: Dictionary = await run_surface_transition_negative_probes()
	var raised_floor_motor: Dictionary = await run_raised_floor_motor_grounding_probe()
	var support_seam_motor: Dictionary = await run_support_seam_motor_grounding_probe()
	var shared_publication_coalescing: Dictionary = await run_shared_publication_coalescing_probe()
	var deferred_publication_isolation: Dictionary = run_deferred_publication_isolation_probe()
	var structure_topology_classification: Dictionary = run_structure_topology_classification_probe()
	var stats: Dictionary = service.stats()
	var readiness: Dictionary = stats.get("navigationMapReadiness", {}) as Dictionary
	var owner_rebuilds_lower := owner_rebuilds.size() == 1 and owner_rebuilds[0] is Dictionary and String((owner_rebuilds[0] as Dictionary).get("regionId", "")) == "region:cross-link:lower"
	var recovery_rebuilds_lower := recovery_rebuilds.size() == 1 and recovery_rebuilds[0] is Dictionary and String((recovery_rebuilds[0] as Dictionary).get("regionId", "")) == "region:cross-link:lower"
	var passed := bool(lower_registration.get("installed", false)) and bool(upper_registration.get("installed", false)) and deferred_publication.is_empty() and owner_rebuilds_lower and int(pending_after_lower.get("pendingNavigationLinkCount", 0)) == 1 and initial_action_current and not unloaded_action_current and bool(upper_unregistration.get("status", "") == "unregistered") and int(pending_after_unload.get("pendingNavigationLinkCount", 0)) == 1 and int(pending_after_unload.get("installedNavigationLinkCount", 0)) == 0 and String(route_while_unavailable.get("status", "")) == "pending" and String(route_while_unavailable.get("reason", "")) == "pending_navigation_links" and bool(upper_recovery.get("installed", false)) and recovery_deferred.is_empty() and recovery_rebuilds_lower and recovered_action_current and int(stats.get("pendingNavigationLinkCount", 0)) == 0 and int(stats.get("installedNavigationLinkCount", 0)) == 1 and bool(readiness.get("ready", false)) and bool(route_forward.get("ok", false)) and bool(route_reverse.get("ok", false)) and bool(recovered_forward.get("ok", false)) and bool(recovered_reverse.get("ok", false)) and bool(same_region_routes.get("forward", {}).get("ok", false)) and bool(same_region_routes.get("reverse", {}).get("ok", false)) and bool(chained_same_region_routes.get("forward", {}).get("ok", false)) and bool(chained_same_region_routes.get("reverse", {}).get("ok", false)) and bool(region_edge_then_link_routes.get("forward", {}).get("ok", false)) and bool(region_edge_then_link_routes.get("reverse", {}).get("ok", false)) and bool(citadel_doorway_mesh_routes.get("passageToDoor", {}).get("ok", false)) and bool(citadel_doorway_mesh_routes.get("sleepingToDoor", {}).get("ok", false)) and bool(collision_safe_support_seams.get("passed", false)) and bool(adjacent_support_transitions.get("passed", false)) and bool(support_prop_detour.get("passed", false)) and bool(surface_transition_traffic.get("passed", false)) and bool(surface_transition_negatives.get("passed", false)) and bool(raised_floor_motor.get("passed", false)) and bool(support_seam_motor.get("passed", false)) and bool(shared_publication_coalescing.get("passed", false)) and bool(deferred_publication_isolation.get("passed", false)) and bool(structure_topology_classification.get("passed", false)) and bool(door_link_proof.get("passed", false))
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
		"initialActionCurrent": initial_action_current,
		"unloadedActionCurrent": unloaded_action_current,
		"recoveredActionCurrent": recovered_action_current,
		"routeReverse": route_reverse,
		"overlappingFixtureScaleRoutes": fixture_scale_routes,
		"sameRegionRoutes": same_region_routes,
		"chainedSameRegionRoutes": chained_same_region_routes,
		"regionEdgeThenLinkRoutes": region_edge_then_link_routes,
		"insetEndpointLinkRoutes": inset_endpoint_link_routes,
		"crossRegionThenInteriorLinkRoutes": cross_region_then_interior_link_routes,
		"conformingPassageMeshRoutes": conforming_passage_mesh_routes,
		"citadelDoorwayMeshRoutes": citadel_doorway_mesh_routes,
		"doorLinkProof": door_link_proof,
		"collisionSafeSupportSeams": collision_safe_support_seams,
		"adjacentSupportTransitions": adjacent_support_transitions,
		"supportPropDetour": support_prop_detour,
		"surfaceTransitionTraffic": surface_transition_traffic,
		"surfaceTransitionNegatives": surface_transition_negatives,
		"raisedFloorMotor": raised_floor_motor,
		"supportSeamMotor": support_seam_motor,
		"sharedPublicationCoalescing": shared_publication_coalescing,
		"deferredPublicationIsolation": deferred_publication_isolation,
		"structureTopologyClassification": structure_topology_classification,
		"stats": stats
	})
	service.clear()
	get_tree().quit(0 if passed else 1)

func run_deferred_publication_isolation_probe() -> Dictionary:
	var coordinator = NpcNavigationCoordinatorScript.new()
	var route_planner = PublicationIsolationRoutePlanner.new()
	var ticket_broker = PublicationIsolationFrameParticipant.new()
	var locomotion = PublicationIsolationFrameParticipant.new()
	coordinator.route_planner = route_planner
	coordinator.route_ticket_broker = ticket_broker
	coordinator.locomotion = locomotion
	coordinator.advance_navmesh_publication_frame()
	var publication_only_passed: bool = route_planner.publication_ticks == 1 and route_planner.route_begin_ticks == 0 and ticket_broker.begin_ticks == 0 and locomotion.begin_ticks == 0
	coordinator.begin_frame()
	var normal_frame_passed: bool = route_planner.route_begin_ticks == 1 and ticket_broker.begin_ticks == 1 and locomotion.begin_ticks == 1
	return {
		"passed": publication_only_passed and normal_frame_passed,
		"publicationOnlyPassed": publication_only_passed,
		"normalFramePassed": normal_frame_passed,
		"publicationTicks": route_planner.publication_ticks,
		"routeBeginTicks": route_planner.route_begin_ticks,
		"ticketBeginTicks": ticket_broker.begin_ticks,
		"locomotionBeginTicks": locomotion.begin_ticks
	}

func run_shared_publication_coalescing_probe() -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "shared_publication_coalescing_test"))
	var world := CoalescingNavigationWorld.new()
	var adapter = NpcRouteCoordinatorAdapterScript.new()
	adapter.world = world
	adapter.navmesh_world = service
	adapter.backend_config = NavigationBackendConfigScript.from_value("navmesh", "shared_publication_coalescing_test")
	var entry := {
		"id": "coalesced-critical-endpoint",
		"position": Vector3(-0.5, 0.0, 0.0),
		"routePriority": 220,
		"pathWaypoints": []
	}
	var intent := {
		"kind": "home",
		"target": Vector3(0.5, 0.0, 0.0),
		"targetCell": Vector2i.ZERO,
		"movingHome": true,
		"priority": 220
	}
	var route_ready_before := bool(adapter.call("_ensure_navmesh_route_tiles", entry, intent))
	var structure_request: Dictionary = adapter.request_navmesh_snapshot_replacements(["0,0"], true, "structure_topology_readiness")
	world.source_revision = 2
	var event_responses: Array[Dictionary] = adapter.process_navigation_events([{
		"id": "stale-source-event",
		"tileKey": "0,0",
		"changeKinds": [NpcEnumsScript.CHANGE_KIND_STRUCTURE_METADATA],
		"revision": 2
	}])
	var queued_before_drain := adapter.pending_navmesh_snapshot_replacement_count()
	var builds_before_drain := world.build_count
	adapter.begin_frame()
	await get_tree().physics_frame
	service.sync_navigation_map_if_dirty()
	var readiness: Dictionary = adapter.navmesh_snapshot_replacements_ready(["0,0"])
	var route_ready_after := bool(adapter.call("_ensure_navmesh_route_tiles", entry, intent))
	var status: Dictionary = service.tile_region_status("0,0")
	var bounded_priority_fairness: Dictionary = await run_bounded_priority_fairness_probe()
	var background_blocked_priority_fairness: Dictionary = await run_background_blocked_priority_fairness_probe()
	var pending_priority_rotation: Dictionary = await run_pending_priority_rotation_probe()
	var multi_pending_priority_fairness: Dictionary = await run_multi_pending_priority_fairness_probe()
	var fail_closed_link_validation: Dictionary = run_fail_closed_link_validation_probe()
	var passed := not route_ready_before \
		and bool(structure_request.get("ok", false)) \
		and event_responses.size() == 1 \
		and queued_before_drain == 1 \
		and builds_before_drain == 0 \
		and world.build_count == 1 \
		and adapter.pending_navmesh_snapshot_replacement_count() == 0 \
		and bool(readiness.get("ready", false)) \
		and String(status.get("sourceKey", "")) == world.navmesh_tile_source_key_for_tile("0,0") \
		and int(status.get("sourceRevision", 0)) == 2 \
		and route_ready_after \
		and bool(bounded_priority_fairness.get("passed", false)) \
		and bool(background_blocked_priority_fairness.get("passed", false)) \
		and bool(pending_priority_rotation.get("passed", false)) \
		and bool(multi_pending_priority_fairness.get("passed", false)) \
		and bool(fail_closed_link_validation.get("passed", false))
	var result := {
		"passed": passed,
		"routeReadyBefore": route_ready_before,
		"structureRequest": structure_request,
		"eventResponses": event_responses,
		"queuedBeforeDrain": queued_before_drain,
		"buildsBeforeDrain": builds_before_drain,
		"buildsAfterDrain": world.build_count,
		"pendingAfterDrain": adapter.pending_navmesh_snapshot_replacement_count(),
		"readiness": readiness,
		"routeReadyAfter": route_ready_after,
		"status": status,
		"boundedPriorityFairness": bounded_priority_fairness,
		"backgroundBlockedPriorityFairness": background_blocked_priority_fairness,
		"pendingPriorityRotation": pending_priority_rotation,
		"multiPendingPriorityFairness": multi_pending_priority_fairness,
		"failClosedLinkValidation": fail_closed_link_validation
	}
	service.clear()
	return result

func run_background_blocked_priority_fairness_probe() -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "background_blocked_priority_fairness_test"))
	var world := CoalescingNavigationWorld.new()
	var pressure := BackgroundPressureMain.new()
	var adapter = NpcRouteCoordinatorAdapterScript.new()
	adapter.main = pressure
	adapter.world = world
	adapter.navmesh_world = service
	adapter.backend_config = NavigationBackendConfigScript.from_value("navmesh", "background_blocked_priority_fairness_test")
	var regular_tile := "39,0"
	var priority_tiles: Array[String] = ["40,0", "41,0", "42,0", "43,0", "44,0", "45,0"]
	adapter.request_navmesh_snapshot_replacements([regular_tile], false, "stale_event_regular")
	adapter.request_navmesh_snapshot_replacements(priority_tiles, true, "structure_topology_readiness")
	var pressure_frame_build_deltas: Array[int] = []
	for _frame in range(priority_tiles.size()):
		var before_count := world.build_order.size()
		await get_tree().process_frame
		adapter.begin_frame()
		pressure_frame_build_deltas.append(world.build_order.size() - before_count)
	var priority_order_preserved := world.build_order == priority_tiles
	var one_priority_per_pressure_frame := pressure_frame_build_deltas == [1, 1, 1, 1, 1, 1]
	var saturated_burst := int(adapter.navmesh_priority_publish_burst) >= 3
	var before_regular_only_pressure := world.build_order.size()
	await get_tree().process_frame
	adapter.begin_frame()
	var regular_only_deferred := world.build_order.size() == before_regular_only_pressure
	var regular_retained_under_pressure := adapter.pending_navmesh_snapshot_replacement_count() == 1 and not world.build_order.has(regular_tile)
	pressure.perf_chunk_ms = 0.0
	await get_tree().process_frame
	adapter.begin_frame()
	var regular_released := world.build_order == priority_tiles + [regular_tile]
	var burst_reset := int(adapter.navmesh_priority_publish_burst) == 0
	var readiness: Dictionary = adapter.navmesh_snapshot_replacements_ready(priority_tiles + [regular_tile])
	var result := {
		"passed": priority_order_preserved and one_priority_per_pressure_frame and regular_only_deferred and regular_retained_under_pressure and saturated_burst and regular_released and burst_reset and bool(readiness.get("ready", false)),
		"priorityOrderPreserved": priority_order_preserved,
		"onePriorityPerPressureFrame": one_priority_per_pressure_frame,
		"pressureFrameBuildDeltas": pressure_frame_build_deltas,
		"regularOnlyDeferred": regular_only_deferred,
		"regularRetainedUnderPressure": regular_retained_under_pressure,
		"saturatedBurst": saturated_burst,
		"regularReleased": regular_released,
		"burstReset": burst_reset,
		"buildOrder": world.build_order.duplicate(),
		"readiness": readiness
	}
	service.clear()
	return result

func run_bounded_priority_fairness_probe() -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "bounded_priority_fairness_test"))
	var world := CoalescingNavigationWorld.new()
	var adapter = NpcRouteCoordinatorAdapterScript.new()
	adapter.world = world
	adapter.navmesh_world = service
	adapter.backend_config = NavigationBackendConfigScript.from_value("navmesh", "bounded_priority_fairness_test")
	var regular_tile := "9,0"
	var regular_request: Dictionary = adapter.request_navmesh_snapshot_replacements([regular_tile], false, "stale_event_regular")
	var priority_tiles: Array[String] = ["10,0", "11,0", "12,0", "13,0"]
	var frame_snapshots: Array[Dictionary] = []
	for frame_index in range(priority_tiles.size()):
		var priority_tile := priority_tiles[frame_index]
		adapter.request_navmesh_snapshot_replacements([priority_tile], true, "continuous_priority_%d" % frame_index)
		adapter.begin_frame()
		await get_tree().physics_frame
		service.sync_navigation_map_if_dirty()
		frame_snapshots.append({
			"frame": frame_index + 1,
			"priorityTile": priority_tile,
			"buildOrder": world.build_order.duplicate(),
			"pendingCount": adapter.pending_navmesh_snapshot_replacement_count()
		})
	var regular_readiness: Dictionary = adapter.navmesh_snapshot_replacements_ready([regular_tile])
	var expected_prefix: Array[String] = ["10,0", "11,0", "12,0", regular_tile]
	var bounded_install := world.build_order.size() >= expected_prefix.size() and world.build_order.slice(0, expected_prefix.size()) == expected_prefix
	var result := {
		"passed": bool(regular_request.get("ok", false)) and bounded_install and bool(regular_readiness.get("ready", false)),
		"priorityBurstLimit": 3,
		"regularTile": regular_tile,
		"priorityTiles": priority_tiles,
		"expectedBuildPrefix": expected_prefix,
		"buildOrder": world.build_order.duplicate(),
		"boundedInstallObserved": bounded_install,
		"regularReadiness": regular_readiness,
		"pendingAfterBound": adapter.pending_navmesh_snapshot_replacement_count(),
		"frames": frame_snapshots
	}
	service.clear()
	return result

func run_multi_pending_priority_fairness_probe() -> Dictionary:
	var world := MultiPendingNavigationWorld.new()
	var service := MultiPendingNavmeshService.new()
	service.blocked_tile = world.pending_tile
	var adapter = NpcRouteCoordinatorAdapterScript.new()
	adapter.world = world
	adapter.navmesh_world = service
	adapter.backend_config = NavigationBackendConfigScript.from_value("navmesh", "multi_pending_priority_fairness_test")
	var required_tiles: Array[String] = [world.pending_tile, world.invalid_tile, world.empty_tile, "33,0", "34,0", "35,0"]
	adapter.request_navmesh_snapshot_replacements(required_tiles, true, "structure_topology_readiness")
	var first_attempt_frame_by_tile := {}
	var frame_snapshots: Array[Dictionary] = []
	for frame_index in range(30):
		await get_tree().process_frame
		adapter.begin_frame()
		for tile_key in required_tiles:
			if not first_attempt_frame_by_tile.has(tile_key) and int(world.build_attempts.get(tile_key, 0)) > 0:
				first_attempt_frame_by_tile[tile_key] = frame_index + 1
		frame_snapshots.append({
			"frame": frame_index + 1,
			"buildOrder": world.build_order.duplicate(),
			"pendingCount": adapter.pending_navmesh_snapshot_replacement_count()
		})
		if adapter.pending_navmesh_snapshot_replacement_count() == 0:
			break
	var readiness: Dictionary = adapter.navmesh_snapshot_replacements_ready(required_tiles)
	var first_pass_bounded := world.build_order.size() >= required_tiles.size() and world.build_order.slice(0, required_tiles.size()) == required_tiles
	var every_tile_attempted := first_attempt_frame_by_tile.size() == required_tiles.size()
	var valid_registration_once := int(service.attempts.get("33,0", 0)) == 1 and int(service.attempts.get("34,0", 0)) == 1 and int(service.attempts.get("35,0", 0)) == 1
	var retry_rotation_observed := int(world.build_attempts.get(world.pending_tile, 0)) >= 3 and int(world.build_attempts.get(world.invalid_tile, 0)) >= 3 and int(world.build_attempts.get(world.empty_tile, 0)) >= 3
	return {
		"passed": first_pass_bounded and every_tile_attempted and retry_rotation_observed and valid_registration_once and bool(readiness.get("ready", false)) and adapter.pending_navmesh_snapshot_replacement_count() == 0,
		"requiredTiles": required_tiles,
		"firstPassBounded": first_pass_bounded,
		"everyTileAttempted": every_tile_attempted,
		"retryRotationObserved": retry_rotation_observed,
		"validRegistrationOnce": valid_registration_once,
		"firstAttemptFrameByTile": first_attempt_frame_by_tile,
		"buildAttempts": world.build_attempts.duplicate(true),
		"registrationAttempts": service.attempts.duplicate(true),
		"buildOrder": world.build_order.duplicate(),
		"readiness": readiness,
		"pendingCount": adapter.pending_navmesh_snapshot_replacement_count(),
		"frames": frame_snapshots
	}

func run_pending_priority_rotation_probe() -> Dictionary:
	var world := RetryRotationNavigationWorld.new()
	var service := SelectivePendingNavmeshService.new()
	var adapter = NpcRouteCoordinatorAdapterScript.new()
	adapter.world = world
	adapter.navmesh_world = service
	adapter.backend_config = NavigationBackendConfigScript.from_value("navmesh", "pending_priority_rotation_test")
	var blocked_tile := world.blocked_tile
	var required_tile := "21,0"
	var regular_tile := "22,0"
	adapter.request_navmesh_snapshot_replacements([blocked_tile, required_tile], true, "citadel_required_tiles")
	adapter.request_navmesh_snapshot_replacements([regular_tile], false, "stale_event_regular")
	var frames: Array[Dictionary] = []
	for frame_index in range(7):
		await get_tree().process_frame
		adapter.begin_frame()
		frames.append({
			"frame": frame_index + 1,
			"buildOrder": world.build_order.duplicate(),
			"pendingCount": adapter.pending_navmesh_snapshot_replacement_count()
		})
	var required_readiness: Dictionary = adapter.navmesh_snapshot_replacements_ready([required_tile])
	var regular_readiness: Dictionary = adapter.navmesh_snapshot_replacements_ready([regular_tile])
	var identical_duplicate_validation: Dictionary = adapter.call("_snapshot_link_cardinality", [
		{"id": "door-link:shared", "portalId": "door:shared", "start": Vector3.ZERO, "end": Vector3.RIGHT},
		{"id": "door-link:shared", "portalId": "door:shared", "start": Vector3.ZERO, "end": Vector3.RIGHT}
	], true)
	var empty_id_validation: Dictionary = adapter.call("_snapshot_link_cardinality", [{"start": Vector3.ZERO, "end": Vector3.RIGHT}], false)
	var conflicting_duplicate_validation: Dictionary = adapter.call("_snapshot_link_cardinality", [
		{"id": "door-link:conflict", "portalId": "door:conflict", "start": Vector3.ZERO, "end": Vector3.RIGHT},
		{"id": "door-link:conflict", "portalId": "door:conflict", "start": Vector3.ZERO, "end": Vector3.FORWARD}
	], true)
	var expected_order: Array[String] = [blocked_tile, required_tile, regular_tile, blocked_tile, blocked_tile]
	var retained_pending := adapter.pending_navmesh_snapshot_replacement_count() == 1
	var blocked_retry_count := int(service.attempts.get(blocked_tile, 0))
	return {
		"passed": world.build_order == expected_order \
			and bool(required_readiness.get("ready", false)) \
			and bool(regular_readiness.get("ready", false)) \
			and retained_pending \
			and blocked_retry_count == 3 \
			and bool(identical_duplicate_validation.get("valid", false)) \
			and int(identical_duplicate_validation.get("count", 0)) == 1 \
			and not bool(empty_id_validation.get("valid", true)) \
			and String(empty_id_validation.get("reason", "")) == "link_id_missing" \
			and not bool(conflicting_duplicate_validation.get("valid", true)) \
			and String(conflicting_duplicate_validation.get("reason", "")) == "conflicting_duplicate_link_id",
		"blockedTile": blocked_tile,
		"requiredTile": required_tile,
		"regularTile": regular_tile,
		"expectedBuildOrder": expected_order,
		"buildOrder": world.build_order.duplicate(),
		"blockedRetryCount": blocked_retry_count,
		"blockedRetained": retained_pending,
		"requiredReadiness": required_readiness,
		"regularReadiness": regular_readiness,
		"identicalDuplicateValidation": identical_duplicate_validation,
		"emptyIdValidation": empty_id_validation,
		"conflictingDuplicateValidation": conflicting_duplicate_validation,
		"frames": frames
	}

func run_fail_closed_link_validation_probe() -> Dictionary:
	var cases := {}
	for mode in ["empty_id", "conflict", "identical"]:
		var world := LinkValidationNavigationWorld.new()
		world.mode = mode
		var service := SelectivePendingNavmeshService.new()
		service.blocked_tile = ""
		var adapter = NpcRouteCoordinatorAdapterScript.new()
		adapter.world = world
		adapter.navmesh_world = service
		adapter.backend_config = NavigationBackendConfigScript.from_value("navmesh", "fail_closed_link_%s" % mode)
		var tile_key := "validation:%s" % mode
		adapter.request_navmesh_snapshot_replacements([tile_key], true, "fail_closed_link_validation")
		adapter.begin_frame()
		var readiness: Dictionary = adapter.navmesh_snapshot_replacements_ready([tile_key])
		cases[mode] = {
			"registrationCount": service.registration_count,
			"ready": bool(readiness.get("ready", false)),
			"pendingCount": adapter.pending_navmesh_snapshot_replacement_count(),
			"readiness": readiness,
			"queueDebug": adapter.last_navmesh_tile_queue_debug.duplicate(true)
		}
	var empty_case: Dictionary = cases.get("empty_id", {}) as Dictionary
	var conflict_case: Dictionary = cases.get("conflict", {}) as Dictionary
	var identical_case: Dictionary = cases.get("identical", {}) as Dictionary
	return {
		"passed": int(empty_case.get("registrationCount", -1)) == 0 \
			and not bool(empty_case.get("ready", true)) \
			and int(empty_case.get("pendingCount", 0)) == 1 \
			and int(conflict_case.get("registrationCount", -1)) == 0 \
			and not bool(conflict_case.get("ready", true)) \
			and int(conflict_case.get("pendingCount", 0)) == 1 \
			and int(identical_case.get("registrationCount", -1)) == 1 \
			and bool(identical_case.get("ready", false)) \
			and int(identical_case.get("pendingCount", -1)) == 0,
		"cases": cases
	}

func run_structure_topology_classification_probe() -> Dictionary:
	var pending_npc := TopologyClassificationNpcSystem.new()
	pending_npc.replacements_ready = false
	var pending_main := TopologyClassificationMain.new()
	pending_main.npc_system = pending_npc
	var pending_system = StructureSystemScript.new()
	pending_system.setup(pending_main)
	pending_system.citadel_publication_states["pending-site"] = {"manifest": {"id": "pending-site"}}
	pending_system.citadel_registration_jobs["pending-site"] = {"phase": "topology", "tileKeys": ["0,0"], "buildingNavigationManifest": {}, "residenceManifest": {}, "generation": 0, "attempts": 0, "prebakeRequested": false}
	pending_system.poll_citadel_registration_jobs()
	var pending_job: Dictionary = pending_system.citadel_registration_jobs.get("pending-site", {}) as Dictionary
	var pending_state: Dictionary = pending_system.citadel_publication_states.get("pending-site", {}) as Dictionary

	var invalid_npc := TopologyClassificationNpcSystem.new()
	invalid_npc.door_result = {"ready": false, "retryable": false, "classification": "invalid_topology", "reason": "building_door_topology_invalid", "proofs": [{"staticFailureReasons": ["descriptor_link_missing"]}]}
	var invalid_main := TopologyClassificationMain.new()
	invalid_main.npc_system = invalid_npc
	var invalid_system = StructureSystemScript.new()
	invalid_system.setup(invalid_main)
	invalid_system.citadel_publication_states["invalid-site"] = {"manifest": {"id": "invalid-site"}}
	invalid_system.citadel_registration_jobs["invalid-site"] = {"phase": "topology", "tileKeys": ["0,0"], "buildingNavigationManifest": {}, "residenceManifest": {}, "generation": 0, "attempts": 3599, "prebakeRequested": false}
	invalid_system.poll_citadel_registration_jobs()
	var invalid_job: Dictionary = invalid_system.citadel_registration_jobs.get("invalid-site", {}) as Dictionary
	var invalid_state: Dictionary = invalid_system.citadel_publication_states.get("invalid-site", {}) as Dictionary
	return {
		"passed": int(pending_job.get("attempts", -1)) == 0 \
			and int(pending_job.get("pendingPolls", 0)) == 1 \
			and int(pending_state.get("topologyPendingPolls", 0)) == 1 \
			and invalid_job.is_empty() \
			and int(invalid_state.get("registrationAttempts", 0)) == 3600 \
			and String(invalid_state.get("status", "")) == "failed" \
			and String(invalid_state.get("failureReason", "")) == "navigation_registration_retry_exhausted" \
			and String((invalid_state.get("lastRegistrationFailure", {}) as Dictionary).get("reason", "")) == "door_topology_proof_invalid",
		"pending": {"job": pending_job, "state": pending_state},
		"invalid": {"job": invalid_job, "state": invalid_state}
	}

func _manual_transition_bundle(direction: String, queue: Vector3, staging: Vector3, entry: Vector3, exit: Vector3, clearance: Vector3, entry_support_id: String, exit_support_id: String) -> Dictionary:
	var positions := {
		"queue": _manual_transition_position(queue, entry_support_id),
		"staging": _manual_transition_position(staging, entry_support_id),
		"entry": _manual_transition_position(entry, entry_support_id),
		"exit": _manual_transition_position(exit, exit_support_id),
		"clearance": _manual_transition_position(clearance, exit_support_id)
	}
	return {
		"ok": true,
		"linkId": "link:cross-region",
		"direction": direction,
		"queuePosition": queue,
		"stagingPosition": staging,
		"entryPosition": entry,
		"exitPosition": exit,
		"clearancePosition": clearance,
		"entrySupportId": entry_support_id,
		"exitSupportId": exit_support_id,
		"staticSnapshotRevision": 1,
		"doorStateRevision": 0,
		"corridorCertificate": {
			"ok": true,
			"collisionBacked": true,
			"standable": true,
			"linkId": "link:cross-region",
			"direction": direction,
			"staticSnapshotRevision": 1,
			"doorStateRevision": 0,
			"positions": positions
		}
	}

func _manual_transition_position(position: Vector3, support_id: String) -> Dictionary:
	return {"ok": true, "collisionBacked": true, "standable": true, "position": position, "expectedSupportId": support_id, "supportId": support_id}


func run_surface_transition_traffic_probe() -> Dictionary:
	var follower := await _run_surface_transition_traffic_case(false)
	var opposing := await _run_surface_transition_traffic_case(true)
	return {"passed": bool(follower.get("passed", false)) and bool(opposing.get("passed", false)), "follower": follower, "opposing": opposing}


func run_surface_transition_negative_probes() -> Dictionary:
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	var narrow_groups := {"narrow": [{"start": Vector3.ZERO, "end": Vector3(0.32, 0.14, 0.0), "startSupportId": "a", "endSupportId": "b", "startTileKey": "0,0", "endTileKey": "0,0", "axis": "x", "laneIndex": 0, "heightDelta": 0.14}]}
	var narrow_links: Array = adapter.call("_surface_transition_links_from_candidate_groups", narrow_groups, "0,0") as Array
	var generated_fixture := _generated_surface_transition_fixture()
	adapter = generated_fixture.get("adapter")
	var wall := {"id": "wall:staging-negative", "sourcePartId": "wall:staging-negative", "minX": 1.38, "maxX": 1.50, "minY": 0.0, "maxY": 2.0, "minZ": 1.75, "maxZ": 2.35, "inflation": 0.0}
	var wall_snapshot := {"staticSnapshotRevision": 1, "staticCollisionByCell": {}, "staticCollisionBroad": [wall], "doorCollisionByCell": {}, "doorCollisionBroad": []}
	var certification_action := {"linkId": "staged-wall-negative", "entryPosition": Vector3(2.04, 0.04, 2.08), "entrySupportId": "terrain:2,2", "stagingPosition": Vector3(1.44, 0.04, 2.08), "queuePosition": Vector3(0.50, 0.04, 2.08), "exitPosition": Vector3(3.08, 0.18, 2.08), "exitSupportId": "support:generated-transition", "clearancePosition": Vector3(3.68, 0.18, 2.08)}
	var wall_certificate: Dictionary = adapter.validate_surface_transition_action(wall_snapshot, certification_action)
	var midpoint_wall := {"id": "wall:queue-staging-midpoint-negative", "sourcePartId": "wall:queue-staging-midpoint-negative", "minX": 0.94, "maxX": 1.00, "minY": 0.0, "maxY": 2.0, "minZ": 1.76, "maxZ": 2.40, "inflation": 0.0}
	var midpoint_wall_certificate: Dictionary = adapter.validate_surface_transition_action({"staticSnapshotRevision": 1, "staticCollisionByCell": {}, "staticCollisionBroad": [midpoint_wall], "doorCollisionByCell": {}, "doorCollisionBroad": []}, certification_action)
	var publication_groups := {"owner-overlap": [
		{"start": Vector3(2.72, 0.18, 1.60), "end": Vector3(2.40, 0.04, 1.60), "startSupportId": "support:generated-transition", "endSupportId": "terrain:2,1", "startTileKey": "0,0", "endTileKey": "0,0", "axis": "x", "laneIndex": 0, "heightDelta": 0.14},
		{"start": Vector3(2.72, 0.18, 1.92), "end": Vector3(2.40, 0.04, 1.92), "startSupportId": "support:generated-transition", "endSupportId": "terrain:2,1", "startTileKey": "0,0", "endTileKey": "0,0", "axis": "x", "laneIndex": 1, "heightDelta": 0.14},
		{"start": Vector3(2.72, 0.18, 2.24), "end": Vector3(2.40, 0.04, 2.24), "startSupportId": "support:generated-transition", "endSupportId": "terrain:2,2", "startTileKey": "0,0", "endTileKey": "0,0", "axis": "x", "laneIndex": 2, "heightDelta": 0.14},
		{"start": Vector3(2.72, 0.18, 2.56), "end": Vector3(2.40, 0.04, 2.56), "startSupportId": "support:generated-transition", "endSupportId": "terrain:2,2", "startTileKey": "0,0", "endTileKey": "0,0", "axis": "x", "laneIndex": 3, "heightDelta": 0.14}
	]}
	var publication_snapshot := {"staticSnapshotRevision": 1, "staticCollisionByCell": {}, "staticCollisionBroad": [], "doorCollisionByCell": {}, "doorCollisionBroad": []}
	var owner_clean_links: Array = adapter.call("_surface_transition_links_from_candidate_groups", publication_groups, "0,0", publication_snapshot) as Array
	var wrong_support := _adjacent_support_fixture("support:wrong-overlap", "floor:wrong-overlap", 1.20, 1.70, 0.0)
	wrong_support["polygon"] = [Vector3(1.20, 0.0, 1.50), Vector3(1.20, 0.0, 2.70), Vector3(2.30, 0.0, 2.70), Vector3(2.30, 0.0, 1.50)]
	adapter.cached_building_supports.append(wrong_support)
	var wrong_owner_certificate: Dictionary = adapter.validate_surface_transition_action({"staticSnapshotRevision": 1, "staticCollisionByCell": {}, "staticCollisionBroad": [], "doorCollisionByCell": {}, "doorCollisionBroad": []}, certification_action)
	var owner_overlap_links: Array = adapter.call("_surface_transition_links_from_candidate_groups", publication_groups, "0,0", publication_snapshot) as Array
	adapter.cached_building_supports.erase(wrong_support)
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "surface_transition_negative_test"))
	var descriptor = NavigationBakeDescriptorScript.from_tile_snapshot(generated_fixture.get("tileSnapshot", {}) as Dictionary)
	var registration: Dictionary = service.register_chunk_descriptor(descriptor)
	var phase_tile_registration: Dictionary = service.register_chunk_descriptor(_transition_phase_tile_descriptor("0,-1"))
	for _frame in range(5):
		await get_tree().physics_frame
	service.sync_navigation_map_if_dirty()
	var metadata_less_route := service.query_route(Vector3(1.50, 0.04, 2.88), Vector3(4.60, 0.18, 2.88), {"maxSnapDistance": 0.8, "queryApi": "map_get_path"})
	var exact_route := service.query_route(Vector3(1.50, 0.04, 2.88), Vector3(4.60, 0.18, 2.88), {"maxSnapDistance": 0.8, "queryApi": "query_path"})
	var exact_action: Dictionary = (exact_route.get("actions", {}) as Dictionary).values()[0] as Dictionary if not (exact_route.get("actions", {}) as Dictionary).is_empty() else {}
	var degenerate_action := exact_action.duplicate(true)
	degenerate_action["pathPointIndex"] = 0
	degenerate_action["exitPathPointIndex"] = 0
	var degenerate_path: Array[Vector3] = [Vector3(2.04, 0.04, 2.08)]
	var degenerate_materialization: Dictionary = service.call("_scripted_navigation_waypoint_result", degenerate_path, {"navigation_link:degenerate": degenerate_action}) if not degenerate_action.is_empty() else {}
	var degenerate_path_rejected := not bool(degenerate_materialization.get("ok", false)) \
		and String(degenerate_materialization.get("reason", "")) == "scripted_navigation_waypoint_materialization_failed" \
		and String(degenerate_materialization.get("detailReason", "")) == "path_too_short"
	var start_on_link_route := service.query_route(exact_action.get("entryPosition", Vector3.ZERO) as Vector3, exact_action.get("clearancePosition", Vector3.ZERO) as Vector3, {"maxSnapDistance": 0.8, "queryApi": "query_path", "preferDescriptorEndpoint": true}) if not exact_action.is_empty() else {}
	var start_on_link_action: Dictionary = (start_on_link_route.get("actions", {}) as Dictionary).values()[0] as Dictionary if not (start_on_link_route.get("actions", {}) as Dictionary).is_empty() else {}
	var start_on_link_materialized := bool(start_on_link_route.get("ok", false)) \
		and int(start_on_link_action.get("pathPointIndex", -1)) >= 0 \
		and int(start_on_link_action.get("exitPathPointIndex", -1)) > int(start_on_link_action.get("pathPointIndex", -1))
	var malformed_snapshot: Dictionary = (generated_fixture.get("tileSnapshot", {}) as Dictionary).duplicate(true)
	var malformed_links: Array = malformed_snapshot.get("navigationLinks", []) as Array
	for malformed_link_index in range(malformed_links.size()):
		var malformed_link_value = malformed_links[malformed_link_index]
		if not (malformed_link_value is Dictionary) or String((malformed_link_value as Dictionary).get("kind", "")) != "surface_transition":
			continue
		var malformed_link: Dictionary = (malformed_link_value as Dictionary).duplicate(true)
		for traversal_key in ["forwardTraversal", "reverseTraversal"]:
			var malformed_traversal: Dictionary = (malformed_link.get(traversal_key, {}) as Dictionary).duplicate(true)
			malformed_traversal["exitPosition"] = Vector3.INF
			malformed_link[traversal_key] = malformed_traversal
		malformed_links[malformed_link_index] = malformed_link
	malformed_snapshot["navigationLinks"] = malformed_links
	var malformed_service = NavmeshWorldServiceScript.new()
	malformed_service.setup(NavigationBackendConfigScript.from_value("navmesh", "surface_transition_malformed_exit_test"))
	var malformed_descriptor = NavigationBakeDescriptorScript.from_tile_snapshot(malformed_snapshot)
	var malformed_registration: Dictionary = malformed_service.register_chunk_descriptor(malformed_descriptor)
	malformed_service.register_chunk_descriptor(_transition_phase_tile_descriptor("0,-1"))
	for _frame in range(5):
		await get_tree().physics_frame
	malformed_service.sync_navigation_map_if_dirty()
	var malformed_exit_route := malformed_service.query_route(Vector3(1.50, 0.04, 2.88), Vector3(4.60, 0.18, 2.88), {"maxSnapDistance": 0.8, "queryApi": "query_path"})
	var malformed_exit_rejected := bool(malformed_registration.get("installed", false)) \
		and not bool(malformed_exit_route.get("ok", false)) \
		and String(malformed_exit_route.get("reason", "")) == "navigation_transition_phase_bundle_invalid"
	var published_link: Dictionary = {}
	for link_value in (generated_fixture.get("tileSnapshot", {}) as Dictionary).get("navigationLinks", []) as Array:
		if link_value is Dictionary and String((link_value as Dictionary).get("id", "")) == String(exact_action.get("linkId", "")):
			published_link = link_value as Dictionary
			break
	var published_bundle_key := "forwardTraversal" if String(exact_action.get("direction", "")) == "forward" else "reverseTraversal"
	var published_bundle: Dictionary = published_link.get(published_bundle_key, {}) if published_link.get(published_bundle_key, {}) is Dictionary else {}
	var phase_bundle_consumed := not published_bundle.is_empty() and bool((exact_action.get("corridorCertificate", {}) as Dictionary).get("ok", false))
	for phase_key in ["queuePosition", "stagingPosition", "entryPosition", "exitPosition", "clearancePosition", "entrySupportId", "exitSupportId"]:
		phase_bundle_consumed = phase_bundle_consumed and exact_action.get(phase_key) == published_bundle.get(phase_key)
	var corrupted_green_bundle := published_bundle.duplicate(true)
	corrupted_green_bundle["queuePosition"] = (corrupted_green_bundle.get("queuePosition", Vector3.ZERO) as Vector3) + Vector3(0.32, 0.0, 0.0)
	var corrupted_green_bundle_rejected := not bool(service.call("_navigation_transition_phase_bundle_is_valid", corrupted_green_bundle, String(published_link.get("id", "")), String(corrupted_green_bundle.get("direction", ""))))
	var lifecycle_fixture := Node3D.new()
	add_child(lifecycle_fixture)
	lifecycle_fixture.add_child(_transition_floor("TransitionLifecycleFloor", Vector3(1.28, -0.10, 2.08), Vector3(2.56, 0.20, 2.56)))
	var lifecycle_body := _transition_body("TransitionLifecycleNpc", Vector3(1.80, 0.03, 2.08))
	lifecycle_fixture.add_child(lifecycle_body)
	await get_tree().physics_frame
	var lifecycle_autonomy = NpcAutonomySystemScript.new()
	lifecycle_autonomy.navmesh_world.clear()
	lifecycle_autonomy.navmesh_world = service
	var lifecycle_npc_system := TransitionFixtureNpcSystem.new(adapter)
	lifecycle_fixture.add_child(lifecycle_npc_system)
	lifecycle_autonomy.npc_system = lifecycle_npc_system
	var lifecycle_executor = NpcRouteLeaseExecutorScript.new()
	lifecycle_executor.setup(null, null, lifecycle_autonomy, SurfaceTransitionCrowdAuthority.new())
	lifecycle_body.global_position = exact_action.get("stagingPosition", lifecycle_body.global_position) as Vector3
	var corrupted_action_route := exact_route.duplicate(true)
	var corrupted_action_key := String((corrupted_action_route.get("actions", {}) as Dictionary).keys()[0])
	var corrupted_action: Dictionary = (corrupted_action_route.get("actions", {}) as Dictionary).get(corrupted_action_key, {}) as Dictionary
	corrupted_action["queuePosition"] = (corrupted_action.get("queuePosition", Vector3.ZERO) as Vector3) + Vector3(0.32, 0.0, 0.0)
	(corrupted_action_route.get("actions", {}) as Dictionary)[corrupted_action_key] = corrupted_action
	var corrupted_action_entry := {"id": "transition-corrupted-action", "body": lifecycle_body, "routePriority": 120, "motorProfile": CharacterMotorProfileScript.npc_default()}
	var corrupted_action_result: Dictionary = _execute_until_transition_state(lifecycle_executor, corrupted_action_entry, "transition-corrupted-action-request", _transition_lease("transition-corrupted-action", corrupted_action_route))
	var corrupted_action_rejected := String(corrupted_action_result.get("reason", "")) == "navigation_transition_corridor_changed" \
		and String(corrupted_action_result.get("classification", "")) == "navigation_transition_certificate_action_mismatch"
	var recovery_plan_executor = NpcPlanExecutorScript.new()
	recovery_plan_executor.setup(lifecycle_autonomy, null, null, {})
	var recovery_authority = lifecycle_autonomy.route_authority_v2
	var recovery_request: Dictionary = recovery_authority.submit_request(corrupted_action_entry, {"kind": "move", "target": Vector3(4.60, 0.18, 2.08)}, {})
	var recovery_request_id := String(recovery_request.get("requestId", ""))
	var mismatch_pending: Dictionary = recovery_plan_executor.call("_handle_v2_transition_execution_failure", corrupted_action_entry, recovery_authority, lifecycle_executor, recovery_request_id, corrupted_action_result)
	var mismatch_active: Dictionary = recovery_authority.runtime_for_entry(corrupted_action_entry)
	var mismatch_refresh_released := bool(recovery_plan_executor.call("_v2_navigation_retry_released", mismatch_active, adapter))
	var differently_corrupted_route := exact_route.duplicate(true)
	var differently_corrupted_action: Dictionary = (differently_corrupted_route.get("actions", {}) as Dictionary).get(corrupted_action_key, {}) as Dictionary
	differently_corrupted_action["stagingPosition"] = (differently_corrupted_action.get("stagingPosition", Vector3.ZERO) as Vector3) + Vector3(0.0, 0.0, 0.32)
	(differently_corrupted_route.get("actions", {}) as Dictionary)[corrupted_action_key] = differently_corrupted_action
	var differently_corrupted_result: Dictionary = _execute_until_transition_state(lifecycle_executor, corrupted_action_entry, recovery_request_id, _transition_lease("transition-corrupted-action", differently_corrupted_route))
	var differently_corrupted_pending: Dictionary = recovery_plan_executor.call("_handle_v2_transition_execution_failure", corrupted_action_entry, recovery_authority, lifecycle_executor, recovery_request_id, differently_corrupted_result)
	var differently_corrupted_active: Dictionary = recovery_authority.runtime_for_entry(corrupted_action_entry)
	var distinct_mismatch_refresh_released := bool(recovery_plan_executor.call("_v2_navigation_retry_released", differently_corrupted_active, adapter))
	var identical_repeat_pending: Dictionary = recovery_plan_executor.call("_handle_v2_transition_execution_failure", corrupted_action_entry, recovery_authority, lifecycle_executor, recovery_request_id, differently_corrupted_result)
	var identical_repeat_active: Dictionary = recovery_authority.runtime_for_entry(corrupted_action_entry)
	var identical_repeat_refresh_released := bool(recovery_plan_executor.call("_v2_navigation_retry_released", identical_repeat_active, adapter))
	var refreshed_action_result: Dictionary = _execute_until_transition_state(lifecycle_executor, corrupted_action_entry, recovery_request_id, _transition_lease("transition-corrupted-action", exact_route))
	var refreshed_action_handled: Dictionary = recovery_plan_executor.call("_handle_v2_transition_execution_failure", corrupted_action_entry, recovery_authority, lifecycle_executor, recovery_request_id, refreshed_action_result)
	var mismatch_recovered := String(mismatch_pending.get("state", "")) == "pending_nav_data" \
		and mismatch_refresh_released \
		and String(differently_corrupted_pending.get("state", "")) == "pending_nav_data" \
		and distinct_mismatch_refresh_released \
		and String(identical_repeat_pending.get("state", "")) == "pending_nav_data" \
		and not identical_repeat_refresh_released \
		and bool(refreshed_action_result.get("ok", false)) \
		and refreshed_action_handled.is_empty() \
		and not corrupted_action_entry.has("v2LastTransitionActionMismatchSignature")
	lifecycle_executor.cancel_entry(corrupted_action_entry)
	recovery_authority.cancel_request(recovery_request_id, "fixture_complete")
	var lifecycle_entry := {"id": "transition-lifecycle", "body": lifecycle_body, "routePriority": 120, "motorProfile": CharacterMotorProfileScript.npc_default()}
	var lifecycle_lease := _transition_lease("transition-lifecycle", exact_route)
	lifecycle_body.global_position = exact_action.get("stagingPosition", lifecycle_body.global_position) as Vector3
	var lifecycle_started: Dictionary = _execute_until_transition_state(lifecycle_executor, lifecycle_entry, "transition-lifecycle-request", lifecycle_lease)
	var lifecycle_active_before_unload := not (lifecycle_entry.get("activeNavigationTransition", {}) as Dictionary).is_empty() and int(lifecycle_autonomy.traffic_reservations.stats().get("activeReservations", 0)) == 1
	var mutation_center: Vector3 = ((exact_action.get("stagingPosition", Vector3.ZERO) as Vector3) + (exact_action.get("entryPosition", Vector3.ZERO) as Vector3)) * 0.5
	var mutation_wall := {"id": "wall:post-plan-transition-mutation", "sourcePartId": "wall:post-plan-transition-mutation", "minX": mutation_center.x - 0.08, "maxX": mutation_center.x + 0.08, "minY": 0.0, "maxY": 2.0, "minZ": mutation_center.z - 0.08, "maxZ": mutation_center.z + 0.08, "inflation": 0.0}
	adapter.cached_static_collision_records.append(mutation_wall)
	adapter.cached_static_collision_broad.append(mutation_wall)
	adapter.static_snapshot_revision += 1
	adapter.cached_revision = str(adapter.static_snapshot_revision)
	var lifecycle_mutation_cancelled: Dictionary = lifecycle_executor.execute(lifecycle_entry, "transition-lifecycle-request", lifecycle_lease, 1.0 / 60.0, {"speed": 2.6, "waypointRadius": 0.18})
	var lifecycle_mutation_released := String(lifecycle_mutation_cancelled.get("reason", "")) == "navigation_transition_corridor_changed" and int(lifecycle_autonomy.traffic_reservations.stats().get("activeReservations", -1)) == 0
	adapter.cached_static_collision_records.erase(mutation_wall)
	adapter.cached_static_collision_broad.erase(mutation_wall)
	adapter.static_snapshot_revision += 1
	adapter.cached_revision = str(adapter.static_snapshot_revision)
	var lifecycle_recovered_after_mutation: Dictionary = _execute_until_transition_state(lifecycle_executor, lifecycle_entry, "transition-lifecycle-request", lifecycle_lease)
	var lifecycle_active_after_mutation_recovery := not (lifecycle_entry.get("activeNavigationTransition", {}) as Dictionary).is_empty() and int(lifecycle_autonomy.traffic_reservations.stats().get("activeReservations", 0)) == 1
	var mutation_door := {"id": "door:post-plan-transition-mutation", "sourcePartId": "door:post-plan-transition-mutation", "minX": mutation_center.x - 0.08, "maxX": mutation_center.x + 0.08, "minY": 0.0, "maxY": 2.0, "minZ": mutation_center.z - 0.08, "maxZ": mutation_center.z + 0.08, "inflation": 0.0}
	adapter.cached_door_collision_records.append(mutation_door)
	adapter.call("_index_collision_record", adapter.cached_door_collision_by_cell, mutation_door)
	adapter.door_state_revision += 1
	var lifecycle_door_mutation_cancelled: Dictionary = lifecycle_executor.execute(lifecycle_entry, "transition-lifecycle-request", lifecycle_lease, 1.0 / 60.0, {"speed": 2.6, "waypointRadius": 0.18})
	var lifecycle_door_mutation_released := String(lifecycle_door_mutation_cancelled.get("reason", "")) == "navigation_transition_corridor_changed" and int(lifecycle_autonomy.traffic_reservations.stats().get("activeReservations", -1)) == 0
	adapter.cached_door_collision_records.erase(mutation_door)
	adapter.call("_unindex_collision_record", adapter.cached_door_collision_by_cell, mutation_door)
	adapter.door_state_revision += 1
	var lifecycle_recovered_after_door_mutation: Dictionary = _execute_until_transition_state(lifecycle_executor, lifecycle_entry, "transition-lifecycle-request", lifecycle_lease)
	var lifecycle_active_after_door_mutation_recovery := not (lifecycle_entry.get("activeNavigationTransition", {}) as Dictionary).is_empty() and int(lifecycle_autonomy.traffic_reservations.stats().get("activeReservations", 0)) == 1
	var lifecycle_unregistration: Dictionary = service.unregister_chunk(String(descriptor.get("region_id")))
	var lifecycle_cancelled: Dictionary = lifecycle_executor.execute(lifecycle_entry, "transition-lifecycle-request", lifecycle_lease, 1.0 / 60.0, {"speed": 2.6, "waypointRadius": 0.18})
	var lifecycle_released_after_unload := String(lifecycle_cancelled.get("reason", "")) == "navigation_transition_topology_changed" and int(lifecycle_autonomy.traffic_reservations.stats().get("activeReservations", -1)) == 0 and (lifecycle_entry.get("activeNavigationTransition", {}) as Dictionary).is_empty()
	var cross_tile_fixture := _generated_cross_tile_transition_fixture()
	var cross_tile_service = NavmeshWorldServiceScript.new()
	cross_tile_service.setup(NavigationBackendConfigScript.from_value("navmesh", "generated_cross_tile_transition_negative_test"))
	var cross_owner_descriptor = NavigationBakeDescriptorScript.from_tile_snapshot(cross_tile_fixture.get("ownerSnapshot", {}) as Dictionary)
	var cross_endpoint_descriptor = NavigationBakeDescriptorScript.from_tile_snapshot(cross_tile_fixture.get("endpointSnapshot", {}) as Dictionary)
	var cross_owner_registration: Dictionary = cross_tile_service.register_chunk_descriptor(cross_owner_descriptor)
	var cross_phase_registration: Dictionary = cross_tile_service.register_chunk_descriptor(_transition_phase_tile_descriptor("0,-1"))
	var cross_pending_before_endpoint := cross_tile_service.stats()
	var cross_endpoint_registration: Dictionary = cross_tile_service.register_chunk_descriptor(cross_endpoint_descriptor)
	for _publication_pass in range(3):
		cross_tile_service.process_dirty_regions(4, 100000)
		await get_tree().physics_frame
	for _frame in range(5):
		await get_tree().physics_frame
	cross_tile_service.sync_navigation_map_if_dirty()
	var cross_route := cross_tile_service.query_route(Vector3(19.40, 0.18, 2.88), Vector3(22.40, 0.40, 2.88), {"maxSnapDistance": 1.0, "queryApi": "query_path"})
	var cross_action: Dictionary = (cross_route.get("actions", {}) as Dictionary).values()[0] as Dictionary if not (cross_route.get("actions", {}) as Dictionary).is_empty() else {}
	var cross_action_current := cross_tile_service.navigation_link_action_is_current(cross_action)
	var unrelated_descriptor = NavigationBakeDescriptorScript.from_tile_snapshot(cross_tile_fixture.get("unrelatedSnapshot", {}) as Dictionary)
	var unrelated_registration := cross_tile_service.register_chunk_descriptor(unrelated_descriptor)
	for _publication_pass in range(3):
		cross_tile_service.process_dirty_regions(4, 100000)
		await get_tree().physics_frame
	var cross_action_current_after_unrelated_publication := cross_tile_service.navigation_link_action_is_current(cross_action)
	var cross_endpoint_unregistration := cross_tile_service.unregister_chunk(String(cross_endpoint_descriptor.get("region_id")))
	var cross_action_current_after_unload := cross_tile_service.navigation_link_action_is_current(cross_action)
	var cross_endpoint_recovery := cross_tile_service.register_chunk_descriptor(cross_endpoint_descriptor)
	for _publication_pass in range(3):
		cross_tile_service.process_dirty_regions(4, 100000)
		await get_tree().physics_frame
	for _frame in range(5):
		await get_tree().physics_frame
	cross_tile_service.sync_navigation_map_if_dirty()
	var recovered_cross_route := cross_tile_service.query_route(Vector3(19.40, 0.18, 2.88), Vector3(22.40, 0.40, 2.88), {"maxSnapDistance": 1.0, "queryApi": "query_path"})
	var recovered_cross_action: Dictionary = (recovered_cross_route.get("actions", {}) as Dictionary).values()[0] as Dictionary if not (recovered_cross_route.get("actions", {}) as Dictionary).is_empty() else {}
	var recovered_cross_action_current := cross_tile_service.navigation_link_action_is_current(recovered_cross_action)
	var cross_tile_generated_passed := not (cross_tile_fixture.get("ownerCrossLinks", []) as Array).is_empty() \
		and (cross_tile_fixture.get("endpointCrossLinks", []) as Array).is_empty() \
		and bool(cross_owner_registration.get("installed", false)) \
		and bool(cross_phase_registration.get("installed", false)) \
		and int(cross_pending_before_endpoint.get("pendingNavigationLinkCount", 0)) > 0 \
		and bool(cross_endpoint_registration.get("installed", false)) \
		and bool(cross_route.get("ok", false)) \
		and cross_action_current \
		and bool(unrelated_registration.get("installed", false)) \
		and cross_action_current_after_unrelated_publication \
		and not String(cross_action.get("startTileSourceKey", "")).is_empty() \
		and not String(cross_action.get("endTileSourceKey", "")).is_empty() \
		and bool(cross_endpoint_unregistration.get("status", "") == "unregistered") \
		and not cross_action_current_after_unload \
		and bool(cross_endpoint_recovery.get("installed", false)) \
		and bool(recovered_cross_route.get("ok", false)) \
		and recovered_cross_action_current
	var excessive_gap_fixture := _generated_signed_cross_tile_transition_negative(0.06, false)
	var endpoint_blocker_fixture := _generated_signed_cross_tile_transition_negative(0.01, true)
	var excessive_gap_rejected := (excessive_gap_fixture.get("ownerLinks", []) as Array).is_empty() \
		and (excessive_gap_fixture.get("endpointLinks", []) as Array).is_empty() \
		and (excessive_gap_fixture.get("publicationFailures", []) as Array).any(func(failure) -> bool: return failure is Dictionary and String((failure as Dictionary).get("reason", "")) == "support_seam_gap_exceeds_policy")
	var endpoint_blocker_rejected := (endpoint_blocker_fixture.get("ownerLinks", []) as Array).is_empty() \
		and (endpoint_blocker_fixture.get("endpointLinks", []) as Array).is_empty() \
		and (endpoint_blocker_fixture.get("publicationFailures", []) as Array).any(func(failure) -> bool: return failure is Dictionary and String((((failure as Dictionary).get("certificate", {}) as Dictionary).get("collision", {}) as Dictionary).get("id", "")) == "wall:endpoint-tile-only")
	var signed_fixture := _generated_signed_cross_tile_transition_fixture()
	var signed_service = NavmeshWorldServiceScript.new()
	signed_service.setup(NavigationBackendConfigScript.from_value("navmesh", "generated_signed_cross_tile_transition_test"))
	var signed_owner_descriptor = NavigationBakeDescriptorScript.from_tile_snapshot(signed_fixture.get("ownerSnapshot", {}) as Dictionary)
	var signed_endpoint_descriptor = NavigationBakeDescriptorScript.from_tile_snapshot(signed_fixture.get("endpointSnapshot", {}) as Dictionary)
	var signed_owner_registration: Dictionary = signed_service.register_chunk_descriptor(signed_owner_descriptor)
	var signed_pending_before_endpoint: Dictionary = signed_service.stats()
	var signed_endpoint_registration: Dictionary = signed_service.register_chunk_descriptor(signed_endpoint_descriptor)
	for _publication_pass in range(3):
		signed_service.process_dirty_regions(4, 100000)
		await get_tree().physics_frame
	for _frame in range(5):
		await get_tree().physics_frame
	signed_service.sync_navigation_map_if_dirty()
	var signed_forward := signed_service.query_route(Vector3(-369.20, 0.18, 3176.80), Vector3(-366.60, 0.40, 3176.80), {"maxSnapDistance": 1.0, "queryApi": "query_path"})
	var signed_reverse := signed_service.query_route(Vector3(-366.60, 0.40, 3176.80), Vector3(-369.20, 0.18, 3176.80), {"maxSnapDistance": 1.0, "queryApi": "query_path"})
	var signed_stats: Dictionary = signed_service.stats()
	var signed_forward_action: Dictionary = (signed_forward.get("actions", {}) as Dictionary).values()[0] as Dictionary if not (signed_forward.get("actions", {}) as Dictionary).is_empty() else {}
	var signed_endpoint_unregistration := signed_service.unregister_chunk(String(signed_endpoint_descriptor.get("region_id")))
	var signed_action_current_after_endpoint_unload := signed_service.navigation_link_action_is_current(signed_forward_action)
	var signed_endpoint_recovery := signed_service.register_chunk_descriptor(signed_endpoint_descriptor)
	for _publication_pass in range(3):
		signed_service.process_dirty_regions(4, 100000)
		await get_tree().physics_frame
	for _frame in range(5):
		await get_tree().physics_frame
	signed_service.sync_navigation_map_if_dirty()
	var signed_recovered_forward := signed_service.query_route(Vector3(-369.20, 0.18, 3176.80), Vector3(-366.60, 0.40, 3176.80), {"maxSnapDistance": 1.0, "queryApi": "query_path"})
	var signed_recovered_action: Dictionary = (signed_recovered_forward.get("actions", {}) as Dictionary).values()[0] as Dictionary if not (signed_recovered_forward.get("actions", {}) as Dictionary).is_empty() else {}
	var signed_owner_unregistration := signed_service.unregister_chunk(String(signed_owner_descriptor.get("region_id")))
	var signed_action_current_after_owner_unload := signed_service.navigation_link_action_is_current(signed_recovered_action)
	signed_stats["fixtureEndpointUnregistration"] = signed_endpoint_unregistration
	signed_stats["fixtureActionCurrentAfterEndpointUnload"] = signed_action_current_after_endpoint_unload
	signed_stats["fixtureEndpointRecovery"] = signed_endpoint_recovery
	signed_stats["fixtureRecoveredForward"] = signed_recovered_forward
	signed_stats["fixtureOwnerUnregistration"] = signed_owner_unregistration
	signed_stats["fixtureActionCurrentAfterOwnerUnload"] = signed_action_current_after_owner_unload
	var signed_cross_tile_passed := (signed_fixture.get("ownerCrossLinks", []) as Array).size() == 1 \
		and (signed_fixture.get("endpointCrossLinks", []) as Array).is_empty() \
		and String(((signed_fixture.get("ownerCrossLinks", []) as Array)[0] as Dictionary).get("ownerTileKey", "")) == "-18,147" \
		and bool(signed_owner_registration.get("installed", false)) \
		and int(signed_pending_before_endpoint.get("pendingNavigationLinkCount", 0)) == 1 \
		and int(signed_pending_before_endpoint.get("installedNavigationLinkCount", 0)) == (signed_fixture.get("ownerSnapshot", {}).get("navigationLinks", []) as Array).size() - (signed_fixture.get("ownerCrossLinks", []) as Array).size() \
		and bool(signed_endpoint_registration.get("installed", false)) \
		and int(signed_stats.get("installedNavigationLinkCount", 0)) == (signed_fixture.get("ownerSnapshot", {}).get("navigationLinks", []) as Array).size() + (signed_fixture.get("endpointSnapshot", {}).get("navigationLinks", []) as Array).size() \
		and int(signed_stats.get("pendingNavigationLinkCount", -1)) == 0 \
		and bool(signed_forward.get("ok", false)) \
		and bool(signed_reverse.get("ok", false)) \
		and not signed_forward_action.is_empty() \
		and String(signed_endpoint_unregistration.get("status", "")) == "unregistered" \
		and not signed_action_current_after_endpoint_unload \
		and bool(signed_endpoint_recovery.get("installed", false)) \
		and bool(signed_recovered_forward.get("ok", false)) \
		and not signed_recovered_action.is_empty() \
		and String(signed_owner_unregistration.get("status", "")) == "unregistered" \
		and not signed_action_current_after_owner_unload
	var signed_support_terrain_fixture := _generated_signed_support_terrain_transition_fixture()
	var signed_support_terrain_service = NavmeshWorldServiceScript.new()
	signed_support_terrain_service.setup(NavigationBackendConfigScript.from_value("navmesh", "generated_signed_support_terrain_transition_test"))
	var signed_support_descriptor = NavigationBakeDescriptorScript.from_tile_snapshot(signed_support_terrain_fixture.get("supportSnapshot", {}) as Dictionary)
	var signed_seam_descriptor = NavigationBakeDescriptorScript.from_tile_snapshot(signed_support_terrain_fixture.get("seamSnapshot", {}) as Dictionary)
	var signed_support_registration: Dictionary = signed_support_terrain_service.register_chunk_descriptor(signed_support_descriptor)
	var signed_seam_registration: Dictionary = signed_support_terrain_service.register_chunk_descriptor(signed_seam_descriptor)
	for _publication_pass in range(3):
		signed_support_terrain_service.process_dirty_regions(4, 100000)
		await get_tree().physics_frame
	for _frame in range(5):
		await get_tree().physics_frame
	signed_support_terrain_service.sync_navigation_map_if_dirty()
	var signed_support_terrain_forward := signed_support_terrain_service.query_route(Vector3(-369.20, 0.18, 3176.80), Vector3(-365.60, 0.04, 3176.80), {"maxSnapDistance": 1.0, "queryApi": "query_path"})
	var signed_support_terrain_reverse := signed_support_terrain_service.query_route(Vector3(-365.60, 0.04, 3176.80), Vector3(-369.20, 0.18, 3176.80), {"maxSnapDistance": 1.0, "queryApi": "query_path"})
	var signed_support_terrain_stats: Dictionary = signed_support_terrain_service.stats()
	var signed_support_terrain_debug: Dictionary = signed_support_terrain_service.debug_snapshot()
	var signed_seam_terrain_links: Array = signed_support_terrain_fixture.get("seamTerrainLinks", []) as Array
	var signed_seam_link_id := String((signed_seam_terrain_links[0] as Dictionary).get("id", "")) if signed_seam_terrain_links.size() == 1 else ""
	var signed_installed_seam_link_count := 0
	for installed_link_value in signed_support_terrain_debug.get("navigationLinks", []) as Array:
		if installed_link_value is Dictionary and String((installed_link_value as Dictionary).get("id", "")) == signed_seam_link_id:
			signed_installed_seam_link_count += 1
	var signed_support_terrain_unregistration := signed_support_terrain_service.unregister_chunk(String(signed_support_descriptor.get("region_id")))
	var signed_support_terrain_after_unload := signed_support_terrain_service.query_route(Vector3(-365.60, 0.04, 3176.80), Vector3(-369.20, 0.18, 3176.80), {"maxSnapDistance": 1.0, "queryApi": "query_path"})
	var signed_support_terrain_passed := (signed_support_terrain_fixture.get("supportTerrainLinks", []) as Array).is_empty() \
		and signed_seam_terrain_links.size() == 1 \
		and signed_seam_terrain_links.all(func(link_value) -> bool: return link_value is Dictionary and String((link_value as Dictionary).get("ownerTileKey", "")) == "-17,147") \
		and bool(signed_support_registration.get("installed", false)) \
		and bool(signed_seam_registration.get("installed", false)) \
		and bool(signed_support_terrain_forward.get("ok", false)) \
		and bool(signed_support_terrain_reverse.get("ok", false)) \
		and signed_installed_seam_link_count == 1 \
		and String(signed_support_terrain_unregistration.get("status", "")) == "unregistered" \
		and not bool(signed_support_terrain_after_unload.get("ok", false))
	var production_fixture := _production_citadel_segment_02_forecourt_03_fixture()
	var production_service = NavmeshWorldServiceScript.new()
	production_service.setup(NavigationBackendConfigScript.from_value("navmesh", "production_citadel_segment_02_forecourt_03_test"))
	var production_owner_descriptor = NavigationBakeDescriptorScript.from_tile_snapshot(production_fixture.get("ownerSnapshot", {}) as Dictionary)
	var production_endpoint_descriptor = NavigationBakeDescriptorScript.from_tile_snapshot(production_fixture.get("endpointSnapshot", {}) as Dictionary)
	var production_owner_registration: Dictionary = production_service.register_chunk_descriptor(production_owner_descriptor)
	var production_endpoint_registration: Dictionary = production_service.register_chunk_descriptor(production_endpoint_descriptor)
	for _publication_pass in range(3):
		production_service.process_dirty_regions(4, 100000)
		await get_tree().physics_frame
	for _frame in range(12):
		await get_tree().physics_frame
	production_service.sync_navigation_map_if_dirty()
	var production_forward := production_service.query_route(Vector3(-360.45, 23.75, 3160.852), Vector3(-360.45, 23.75, 3175.061), {"maxSnapDistance": 1.0, "queryApi": "query_path"})
	var production_reverse := production_service.query_route(Vector3(-360.45, 23.75, 3175.061), Vector3(-360.45, 23.75, 3160.852), {"maxSnapDistance": 1.0, "queryApi": "query_path"})
	var production_action: Dictionary = (production_forward.get("actions", {}) as Dictionary).values()[0] as Dictionary if not (production_forward.get("actions", {}) as Dictionary).is_empty() else {}
	var production_parallel_lane_traffic := await _run_production_parallel_lane_traffic_probe(production_fixture, production_service)
	var production_endpoint_unregistration := production_service.unregister_chunk(String(production_endpoint_descriptor.get("region_id")))
	var production_action_current_after_unload := production_service.navigation_link_action_is_current(production_action)
	var production_endpoint_recovery := production_service.register_chunk_descriptor(production_endpoint_descriptor)
	for _publication_pass in range(3):
		production_service.process_dirty_regions(4, 100000)
		await get_tree().physics_frame
	for _frame in range(5):
		await get_tree().physics_frame
	production_service.sync_navigation_map_if_dirty()
	var production_recovered := production_service.query_route(Vector3(-360.45, 23.75, 3160.852), Vector3(-360.45, 23.75, 3175.061), {"maxSnapDistance": 1.0, "queryApi": "query_path"})
	var production_cross_links: Array = production_fixture.get("ownerCrossLinks", []) as Array
	var production_seam_corridor_ids: Array[String] = []
	for production_link_value in production_cross_links:
		if production_link_value is Dictionary:
			var production_seam_corridor_id := String((production_link_value as Dictionary).get("seamCorridorId", ""))
			if not production_seam_corridor_ids.has(production_seam_corridor_id):
				production_seam_corridor_ids.append(production_seam_corridor_id)
	var production_replay_passed := not production_cross_links.is_empty() \
		and (production_fixture.get("endpointCrossLinks", []) as Array).is_empty() \
		and production_cross_links.all(func(link_value) -> bool: return link_value is Dictionary and String((link_value as Dictionary).get("startSupportId", "")) == "support:castle_keep_palace_entry_forecourt" and String((link_value as Dictionary).get("endSupportId", "")) == "support:castle_compound_paving_segment_03" and String((link_value as Dictionary).get("ownerTileKey", "")) == "-17,146") \
		and production_seam_corridor_ids.size() == 1 \
		and not production_seam_corridor_ids[0].is_empty() \
		and bool(production_parallel_lane_traffic.get("passed", false)) \
		and bool(production_owner_registration.get("installed", false)) \
		and bool(production_endpoint_registration.get("installed", false)) \
		and bool(production_forward.get("ok", false)) \
		and bool(production_reverse.get("ok", false)) \
		and not production_action.is_empty() \
		and String(production_endpoint_unregistration.get("status", "")) == "unregistered" \
		and not production_action_current_after_unload \
		and bool(production_endpoint_recovery.get("installed", false)) \
		and bool(production_recovered.get("ok", false))
	var passed := bool(registration.get("installed", false)) \
		and narrow_links.is_empty() \
		and not bool(wall_certificate.get("ok", true)) \
		and String(wall_certificate.get("reason", "")).begins_with("surface_transition_staging_") \
		and not bool(midpoint_wall_certificate.get("ok", true)) \
		and String(midpoint_wall_certificate.get("reason", "")) == "surface_transition_queue_to_staging_capsule_sweep_collision" \
		and not bool(wrong_owner_certificate.get("ok", true)) \
		and String(wrong_owner_certificate.get("reason", "")) == "surface_transition_entry_wrong_overlapping_support_owner" \
		and not owner_clean_links.is_empty() \
		and owner_overlap_links.is_empty() \
		and String(metadata_less_route.get("status", "")) == "pending" \
		and String(metadata_less_route.get("reason", "")) == "navigation_path_metadata_unavailable" \
		and bool(exact_route.get("ok", false)) \
		and degenerate_path_rejected \
		and start_on_link_materialized \
		and malformed_exit_rejected \
		and phase_bundle_consumed \
		and corrupted_green_bundle_rejected \
		and corrupted_action_rejected \
		and mismatch_recovered \
		and lifecycle_active_before_unload \
		and lifecycle_mutation_released \
		and lifecycle_active_after_mutation_recovery \
		and lifecycle_door_mutation_released \
		and lifecycle_active_after_door_mutation_recovery \
		and lifecycle_released_after_unload \
		and cross_tile_generated_passed \
		and excessive_gap_rejected \
		and endpoint_blocker_rejected \
		and signed_cross_tile_passed \
		and signed_support_terrain_passed \
		and production_replay_passed
	lifecycle_executor.cancel_entry(lifecycle_entry)
	lifecycle_fixture.queue_free()
	await get_tree().physics_frame
	service.clear()
	malformed_service.clear()
	lifecycle_autonomy.shutdown_for_process_exit()
	cross_tile_service.clear()
	signed_service.clear()
	signed_support_terrain_service.clear()
	production_service.clear()
	return {"passed": passed, "narrowLinks": narrow_links, "wallCertificate": wall_certificate, "midpointWallCertificate": midpoint_wall_certificate, "wrongOwnerCertificate": wrong_owner_certificate, "ownerCleanLinks": owner_clean_links, "ownerOverlapLinks": owner_overlap_links, "publicationFailures": adapter.surface_transition_publication_failures.duplicate(true), "phaseTileRegistration": phase_tile_registration, "metadataLessRoute": metadata_less_route, "exactRoute": exact_route, "degenerateMaterialization": degenerate_materialization, "degeneratePathRejected": degenerate_path_rejected, "startOnLinkRoute": start_on_link_route, "startOnLinkMaterialized": start_on_link_materialized, "malformedExitRoute": malformed_exit_route, "malformedExitRejected": malformed_exit_rejected, "phaseBundleConsumed": phase_bundle_consumed, "corruptedGreenBundleRejected": corrupted_green_bundle_rejected, "corruptedActionRejected": corrupted_action_rejected, "corruptedActionResult": corrupted_action_result, "mismatchPending": mismatch_pending, "mismatchRefreshReleased": mismatch_refresh_released, "differentlyCorruptedPending": differently_corrupted_pending, "distinctMismatchRefreshReleased": distinct_mismatch_refresh_released, "identicalRepeatPending": identical_repeat_pending, "identicalRepeatRefreshReleased": identical_repeat_refresh_released, "refreshedActionResult": refreshed_action_result, "mismatchRecovered": mismatch_recovered, "publishedBundle": published_bundle, "lifecycleStarted": lifecycle_started, "lifecycleActiveBeforeUnload": lifecycle_active_before_unload, "lifecycleMutationCancelled": lifecycle_mutation_cancelled, "lifecycleMutationReleased": lifecycle_mutation_released, "lifecycleRecoveredAfterMutation": lifecycle_recovered_after_mutation, "lifecycleActiveAfterMutationRecovery": lifecycle_active_after_mutation_recovery, "lifecycleDoorMutationCancelled": lifecycle_door_mutation_cancelled, "lifecycleDoorMutationReleased": lifecycle_door_mutation_released, "lifecycleRecoveredAfterDoorMutation": lifecycle_recovered_after_door_mutation, "lifecycleActiveAfterDoorMutationRecovery": lifecycle_active_after_door_mutation_recovery, "lifecycleUnregistration": lifecycle_unregistration, "lifecycleCancelled": lifecycle_cancelled, "lifecycleReleasedAfterUnload": lifecycle_released_after_unload, "crossTileGeneratedPassed": cross_tile_generated_passed, "crossTileFixture": cross_tile_fixture, "crossPendingBeforeEndpoint": cross_pending_before_endpoint, "crossRoute": cross_route, "crossActionCurrent": cross_action_current, "unrelatedRegistration": unrelated_registration, "crossActionCurrentAfterUnrelatedPublication": cross_action_current_after_unrelated_publication, "crossEndpointUnregistration": cross_endpoint_unregistration, "crossActionCurrentAfterUnload": cross_action_current_after_unload, "crossEndpointRecovery": cross_endpoint_recovery, "recoveredCrossRoute": recovered_cross_route, "recoveredCrossActionCurrent": recovered_cross_action_current, "excessiveGapRejected": excessive_gap_rejected, "excessiveGapFixture": excessive_gap_fixture, "endpointBlockerRejected": endpoint_blocker_rejected, "endpointBlockerFixture": endpoint_blocker_fixture, "productionReplayPassed": production_replay_passed, "productionFixture": production_fixture, "productionSeamCorridorIds": production_seam_corridor_ids, "productionParallelLaneTraffic": production_parallel_lane_traffic, "productionForward": production_forward, "productionReverse": production_reverse, "productionActionCurrentAfterUnload": production_action_current_after_unload, "productionRecovered": production_recovered, "signedCrossTilePassed": signed_cross_tile_passed, "signedFixture": signed_fixture, "signedPendingBeforeEndpoint": signed_pending_before_endpoint, "signedForward": signed_forward, "signedReverse": signed_reverse, "signedStats": signed_stats, "signedSupportTerrainPassed": signed_support_terrain_passed, "signedSupportTerrainFixture": signed_support_terrain_fixture, "signedSupportTerrainForward": signed_support_terrain_forward, "signedSupportTerrainReverse": signed_support_terrain_reverse, "signedSupportTerrainStats": signed_support_terrain_stats, "signedSupportTerrainAfterUnload": signed_support_terrain_after_unload}


func _run_surface_transition_traffic_case(opposing: bool) -> Dictionary:
	var generated_fixture := _generated_surface_transition_fixture()
	var adapter = generated_fixture.get("adapter")
	var tile_snapshot: Dictionary = generated_fixture.get("tileSnapshot", {}) as Dictionary
	var generated_links: Array = generated_fixture.get("links", []) as Array
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "surface_transition_traffic"))
	var descriptor = NavigationBakeDescriptorScript.from_tile_snapshot(tile_snapshot)
	var registration: Dictionary = service.register_chunk_descriptor(descriptor)
	for _frame in range(5):
		await get_tree().physics_frame
	service.sync_navigation_map_if_dirty()
	var fixture := Node3D.new()
	fixture.name = "SurfaceTransitionTrafficFixture"
	add_child(fixture)
	fixture.add_child(_transition_floor("TransitionLowerFloor", Vector3(1.28, -0.10, 2.88), Vector3(2.56, 0.20, 3.20)))
	fixture.add_child(_transition_floor("TransitionUpperFloor", Vector3(3.84, 0.04, 2.88), Vector3(2.56, 0.20, 3.20)))
	var forward_body := _transition_body("TransitionForwardNpc", Vector3(1.50, 0.03, 2.88))
	var reverse_start := Vector3(3.70, 0.17, 2.88) if opposing else Vector3(0.60, 0.03, 2.88)
	var reverse_body := _transition_body("TransitionReverseNpc", reverse_start)
	fixture.add_child(forward_body)
	fixture.add_child(reverse_body)
	await get_tree().physics_frame
	var autonomy = NpcAutonomySystemScript.new()
	autonomy.navmesh_world.clear()
	autonomy.navmesh_world = service
	var transition_npc_system := TransitionFixtureNpcSystem.new(adapter)
	fixture.add_child(transition_npc_system)
	autonomy.npc_system = transition_npc_system
	var crowd = autonomy.crowd_velocity_service
	var planner = NavmeshRoutePlannerScript.new()
	planner.setup(service, autonomy, generated_fixture.get("main"), adapter)
	var forward_executor = NpcRouteLeaseExecutorScript.new()
	var reverse_executor = NpcRouteLeaseExecutorScript.new()
	forward_executor.setup(null, null, autonomy, crowd)
	reverse_executor.setup(null, null, autonomy, crowd)
	var forward_entry := {"id": "transition-forward", "body": forward_body, "routePriority": 120, "motorProfile": CharacterMotorProfileScript.npc_default()}
	var reverse_entry := {"id": "transition-reverse", "body": reverse_body, "routePriority": 110, "motorProfile": CharacterMotorProfileScript.npc_default()}
	forward_body.set_meta("npc_stable_id", "transition-forward")
	reverse_body.set_meta("npc_stable_id", "transition-reverse")
	var forward_query_metadata: Dictionary = service.call("_query_path_points", forward_body.global_position, Vector3(4.70, 0.18, 2.88), {"maxSnapDistance": 0.8, "queryApi": "query_path"})
	var forward_route := planner.plan_runtime_route(forward_entry, {"target": Vector3(4.70, 0.18, 2.88), "kind": "move", "allowOutside": true, "arrivalRadius": 0.18}, adapter)
	var reverse_target := Vector3(1.50, 0.04, 2.88) if opposing else Vector3(3.65, 0.18, 2.88)
	var reverse_route := planner.plan_runtime_route(reverse_entry, {"target": reverse_target, "kind": "move", "allowOutside": true, "arrivalRadius": 0.18}, adapter)
	var forward_lease := _transition_lease("transition-forward", forward_route)
	var reverse_lease := _transition_lease("transition-reverse", reverse_route)
	forward_entry["routeLease"] = forward_lease
	forward_entry["routeStatus"] = "moving"
	reverse_entry["routeLease"] = reverse_lease
	reverse_entry["routeStatus"] = "moving"
	var forward_binding: Dictionary = forward_executor.call("_surface_transition_action_for_waypoint", forward_lease, 1)
	var reverse_binding: Dictionary = reverse_executor.call("_surface_transition_action_for_waypoint", reverse_lease, 1)
	var queue_observed := false
	var waiter_outside_corridor_observed := false
	var exclusive_crossing := true
	var clearance_release_observed := false
	var handoff_after_release_observed := false
	var first_holder_id := ""
	var first_holder_action: Dictionary = {}
	var first_holder_was_active := false
	var first_holder_released := false
	var constrained_observed := false
	var forward_cross_frame := -1
	var reverse_cross_frame := -1
	var unexpected_collision := false
	var last_forward_result := {}
	var last_reverse_result := {}
	var forward_done := false
	var reverse_done := false
	var timeline: Array[Dictionary] = []
	var last_timeline_key := ""
	for frame in range(360):
		crowd.begin_physics_frame([forward_entry, reverse_entry])
		autonomy.advance_traffic(1.0 / 60.0, false)
		var forward_result := {"ok": true, "status": "arrived", "reason": ""} if forward_done else forward_executor.execute(forward_entry, "transition-forward-request", forward_lease, 1.0 / 60.0, {"speed": 2.6, "waypointRadius": 0.18})
		var reverse_result := {"ok": true, "status": "arrived", "reason": ""} if reverse_done else reverse_executor.execute(reverse_entry, "transition-reverse-request", reverse_lease, 1.0 / 60.0, {"speed": 2.6, "waypointRadius": 0.18})
		crowd.end_physics_frame()
		last_forward_result = forward_result.duplicate(true)
		last_reverse_result = reverse_result.duplicate(true)
		forward_done = forward_done or String(forward_result.get("status", "")) == "arrived"
		reverse_done = reverse_done or String(reverse_result.get("status", "")) == "arrived"
		queue_observed = queue_observed or int(autonomy.traffic_reservations.stats().get("queueLength", 0)) > 0
		var forward_active: Dictionary = forward_entry.get("activeNavigationTransition", {}) as Dictionary
		var reverse_active: Dictionary = reverse_entry.get("activeNavigationTransition", {}) as Dictionary
		var forward_pending: Dictionary = forward_entry.get("pendingNavigationTransition", {}) as Dictionary
		var reverse_pending: Dictionary = reverse_entry.get("pendingNavigationTransition", {}) as Dictionary
		var active_count := int(not forward_active.is_empty()) + int(not reverse_active.is_empty())
		exclusive_crossing = exclusive_crossing and active_count <= 1
		if first_holder_id.is_empty() and active_count == 1:
			first_holder_id = "transition-forward" if not forward_active.is_empty() else "transition-reverse"
			var first_holder_transition: Dictionary = forward_active if first_holder_id == "transition-forward" else reverse_active
			first_holder_action = (first_holder_transition.get("action", {}) as Dictionary).duplicate(true)
			first_holder_was_active = true
		if first_holder_was_active and not first_holder_released:
			var holder_active: Dictionary = forward_active if first_holder_id == "transition-forward" else reverse_active
			if holder_active.is_empty():
				first_holder_released = true
				var holder_body := forward_body if first_holder_id == "transition-forward" else reverse_body
				var holder_clearance: Vector3 = first_holder_action.get("clearancePosition", Vector3.INF) as Vector3
				clearance_release_observed = holder_clearance.is_finite() and Vector2(holder_body.global_position.x - holder_clearance.x, holder_body.global_position.z - holder_clearance.z).length() <= 0.24
		if first_holder_released:
			var waiter_active: Dictionary = reverse_active if first_holder_id == "transition-forward" else forward_active
			handoff_after_release_observed = handoff_after_release_observed or not waiter_active.is_empty()
		if not forward_pending.is_empty() and not reverse_active.is_empty():
			waiter_outside_corridor_observed = waiter_outside_corridor_observed or _waiter_is_outside_transition_corridor(forward_body.global_position, forward_pending)
		if not reverse_pending.is_empty() and not forward_active.is_empty():
			waiter_outside_corridor_observed = waiter_outside_corridor_observed or _waiter_is_outside_transition_corridor(reverse_body.global_position, reverse_pending)
		constrained_observed = constrained_observed or bool((forward_entry.get("routeLeaseAvoidance", {}) as Dictionary).get("corridorConstrained", false)) or bool((reverse_entry.get("routeLeaseAvoidance", {}) as Dictionary).get("corridorConstrained", false))
		unexpected_collision = unexpected_collision or String(forward_result.get("reason", "")) == "unexpected_collision" or String(reverse_result.get("reason", "")) == "unexpected_collision"
		var timeline_key := "%s|%s|%s|%s|%s|%s" % [String(forward_result.get("status", "")), String(forward_result.get("reason", "")), String((forward_entry.get("activeNavigationTransition", {}) as Dictionary).get("phase", "")), String(reverse_result.get("status", "")), String(reverse_result.get("reason", "")), String((reverse_entry.get("activeNavigationTransition", {}) as Dictionary).get("phase", ""))]
		if timeline_key != last_timeline_key or String(forward_result.get("reason", "")) == "unexpected_collision" or String(reverse_result.get("reason", "")) == "unexpected_collision":
			timeline.append({"frame": frame, "forwardPosition": forward_body.global_position, "followerPosition": reverse_body.global_position, "forward": forward_result, "follower": reverse_result, "forwardActive": (forward_entry.get("activeNavigationTransition", {}) as Dictionary).duplicate(true), "forwardPending": (forward_entry.get("pendingNavigationTransition", {}) as Dictionary).duplicate(true), "followerActive": (reverse_entry.get("activeNavigationTransition", {}) as Dictionary).duplicate(true), "followerPending": (reverse_entry.get("pendingNavigationTransition", {}) as Dictionary).duplicate(true), "traffic": autonomy.traffic_reservations.to_summary()})
			last_timeline_key = timeline_key
		if forward_cross_frame < 0 and forward_body.global_position.x > 3.20:
			forward_cross_frame = frame
		if reverse_cross_frame < 0 and ((opposing and reverse_body.global_position.x < 2.10) or (not opposing and reverse_body.global_position.x > 3.20)):
			reverse_cross_frame = frame
		if forward_done and reverse_done:
			break
		await get_tree().physics_frame
	var traffic_stats: Dictionary = autonomy.traffic_reservations.stats()
	forward_executor.cancel_entry(forward_entry)
	reverse_executor.cancel_entry(reverse_entry)
	var action_count := (forward_route.get("actions", {}) as Dictionary).size()
	var reverse_action_count := (reverse_route.get("actions", {}) as Dictionary).size()
	var passed := bool(registration.get("installed", false)) and not generated_links.is_empty() and action_count >= 1 and reverse_action_count >= 1 and queue_observed and waiter_outside_corridor_observed and exclusive_crossing and clearance_release_observed and handoff_after_release_observed and constrained_observed and forward_cross_frame >= 0 and reverse_cross_frame >= 0 and forward_cross_frame != reverse_cross_frame and forward_done and reverse_done and not unexpected_collision and int(traffic_stats.get("activeReservations", -1)) == 0
	var result := {
		"passed": passed,
		"opposing": opposing,
		"registration": registration,
		"generatedLinks": generated_links,
		"forwardQueryMetadata": _path_query_metadata_summary(forward_query_metadata),
		"forwardRoute": forward_route,
		"reverseRoute": reverse_route,
		"forwardBinding": forward_binding,
		"reverseBinding": reverse_binding,
		"lastForwardResult": last_forward_result,
		"lastReverseResult": last_reverse_result,
		"forwardWaypointIndex": int(forward_entry.get("_v2LeaseExecutorWaypointIndex", -1)),
		"reverseWaypointIndex": int(reverse_entry.get("_v2LeaseExecutorWaypointIndex", -1)),
		"queueObserved": queue_observed,
		"waiterOutsideCorridorObserved": waiter_outside_corridor_observed,
		"exclusiveCrossing": exclusive_crossing,
		"clearanceReleaseObserved": clearance_release_observed,
		"handoffAfterReleaseObserved": handoff_after_release_observed,
		"firstHolderId": first_holder_id,
		"corridorConstrainedObserved": constrained_observed,
		"forwardCrossFrame": forward_cross_frame,
		"reverseCrossFrame": reverse_cross_frame,
		"unexpectedCollision": unexpected_collision,
		"forwardPosition": forward_body.global_position,
		"reversePosition": reverse_body.global_position,
		"traffic": traffic_stats,
		"timeline": timeline
	}
	fixture.queue_free()
	await get_tree().physics_frame
	service.clear()
	autonomy.shutdown_for_process_exit()
	return result


func _run_production_parallel_lane_traffic_probe(production_fixture: Dictionary, service) -> Dictionary:
	var adapter = production_fixture.get("adapter")
	var fixture := Node3D.new()
	fixture.name = "ProductionParallelLaneTrafficFixture"
	add_child(fixture)
	fixture.add_child(_transition_floor("ProductionSegment02Collision", Vector3(-360.45, 23.66, 3158.579), Vector3(8.10, 0.18, 25.838)))
	fixture.add_child(_transition_floor("ProductionForecourtCollision", Vector3(-360.45, 23.66, 3173.049), Vector3(8.10, 0.18, 3.062)))
	fixture.add_child(_transition_floor("ProductionSegment03Collision", Vector3(-360.45, 23.66, 3188.309), Vector3(8.10, 0.18, 27.462)))
	var actor_specs: Array[Dictionary] = [
		{"id": "lane-a-leader", "x": -362.72, "z": 3169.80, "priority": 130},
		{"id": "lane-b-leader", "x": -361.44, "z": 3169.80, "priority": 130},
		{"id": "lane-a-follower", "x": -362.72, "z": 3168.80, "priority": 110},
		{"id": "lane-b-follower", "x": -361.44, "z": 3168.80, "priority": 110}
	]
	var autonomy = NpcAutonomySystemScript.new()
	autonomy.navmesh_world.clear()
	autonomy.navmesh_world = service
	var transition_npc_system := TransitionFixtureNpcSystem.new(adapter)
	fixture.add_child(transition_npc_system)
	autonomy.npc_system = transition_npc_system
	var entries: Array[Dictionary] = []
	var executors: Array = []
	var selected_links := {}
	for spec in actor_specs:
		var actor_id := String(spec.get("id", ""))
		var body := _transition_body(actor_id, Vector3(float(spec.get("x", 0.0)), 23.75, float(spec.get("z", 0.0))))
		body.set_meta("npc_stable_id", actor_id)
		fixture.add_child(body)
		var entry := {"id": actor_id, "body": body, "routePriority": int(spec.get("priority", 100)), "motorProfile": CharacterMotorProfileScript.npc_default()}
		var route_target_z := 3177.50 if actor_id.contains("follower") else 3180.00
		var route_target_x := float(spec.get("x", 0.0)) if actor_id.contains("follower") else float(spec.get("x", 0.0)) - 0.45
		var route: Dictionary = service.query_route(body.global_position, Vector3(route_target_x, 23.75, route_target_z), {"maxSnapDistance": 1.0, "queryApi": "query_path", "pathPostprocessing": NavigationPathQueryParameters3D.PATH_POSTPROCESSING_CORRIDORFUNNEL, "simplifyPath": true, "simplifyEpsilon": NpcConstantsScript.NAVMESH_PATH_SIMPLIFY_EPSILON})
		var lease := _transition_lease(actor_id, route)
		entry["routeLease"] = lease
		entry["routeStatus"] = "moving"
		var action: Dictionary = (route.get("actions", {}) as Dictionary).values()[0] as Dictionary if not (route.get("actions", {}) as Dictionary).is_empty() else {}
		if not action.is_empty():
			if actor_id.contains("follower"):
				var queue_position: Vector3 = action.get("queuePosition", body.global_position) as Vector3
				body.global_position = queue_position
			else:
				body.global_position = action.get("stagingPosition", body.global_position) as Vector3
		var route_path: Array = route.get("path", []) if route.get("path", []) is Array else []
		selected_links[actor_id] = {"linkId": String(action.get("linkId", "")), "seamCorridorId": String(action.get("seamCorridorId", "")), "routeOk": bool(route.get("ok", false)), "target": route.get("target", Vector3.INF), "waypointCount": route_path.size(), "actionEntryIndex": int(action.get("pathPointIndex", -1)), "actionExitIndex": int(action.get("exitPathPointIndex", -1)), "routeTail": route_path.slice(maxi(0, route_path.size() - 5))}
		var executor = NpcRouteLeaseExecutorScript.new()
		executor.setup(null, null, autonomy, autonomy.crowd_velocity_service)
		entries.append(entry)
		executors.append(executor)
	transition_npc_system.npcs = entries
	await get_tree().physics_frame
	var adjacent_lanes_active_together := false
	var same_lane_followers_queued := false
	var cross_lane_overlap := false
	var unexpected_collision := false
	var completed := {}
	var timeline: Array[Dictionary] = []
	for frame in range(600):
		autonomy.crowd_velocity_service.begin_physics_frame(entries)
		autonomy.advance_traffic(1.0 / 60.0, false)
		var statuses := {}
		var execution_results := {}
		for actor_index in range(entries.size()):
			var entry: Dictionary = entries[actor_index]
			var actor_id := String(entry.get("id", ""))
			var actor_speed := 1.8 if actor_id.contains("follower") else 2.6
			var result: Dictionary = {"ok": true, "status": "arrived", "reason": ""} if bool(completed.get(actor_id, false)) else executors[actor_index].execute(entry, "%s-request" % actor_id, entry.get("routeLease", {}) as Dictionary, 1.0 / 60.0, {"speed": actor_speed, "waypointRadius": 0.18})
			statuses[actor_id] = {"status": String(result.get("status", "")), "reason": String(result.get("reason", ""))}
			execution_results[actor_id] = result.duplicate(true)
			completed[actor_id] = bool(completed.get(actor_id, false)) or String(result.get("status", "")) == "arrived"
			unexpected_collision = unexpected_collision or String(result.get("reason", "")) == "unexpected_collision"
		autonomy.crowd_velocity_service.end_physics_frame()
		var lane_a_active := not (entries[0].get("activeNavigationTransition", {}) as Dictionary).is_empty()
		var lane_b_active := not (entries[1].get("activeNavigationTransition", {}) as Dictionary).is_empty()
		adjacent_lanes_active_together = adjacent_lanes_active_together or (lane_a_active and lane_b_active)
		var follower_a_pending := not (entries[2].get("pendingNavigationTransition", {}) as Dictionary).is_empty()
		var follower_b_pending := not (entries[3].get("pendingNavigationTransition", {}) as Dictionary).is_empty()
		same_lane_followers_queued = same_lane_followers_queued or (follower_a_pending and follower_b_pending and lane_a_active and lane_b_active)
		var active_positions: Array[Vector3] = []
		for entry in entries:
			if not (entry.get("activeNavigationTransition", {}) as Dictionary).is_empty():
				active_positions.append((entry.get("body") as CharacterBody3D).global_position)
		for first_index in range(active_positions.size()):
			for second_index in range(first_index + 1, active_positions.size()):
				cross_lane_overlap = cross_lane_overlap or Vector2(active_positions[first_index].x - active_positions[second_index].x, active_positions[first_index].z - active_positions[second_index].z).length() < 0.68
		if frame % 30 == 0 or frame in range(80, 131) or (lane_a_active and lane_b_active) or (follower_a_pending and follower_b_pending):
			timeline.append({"frame": frame, "statuses": statuses, "executionResults": execution_results, "activeReservations": autonomy.traffic_reservations.to_summary(), "crowd": autonomy.crowd_velocity_service.stats(), "positions": entries.map(func(entry: Dictionary): return {"id": entry.get("id", ""), "position": (entry.get("body") as CharacterBody3D).global_position, "avoidance": (entry.get("routeLeaseAvoidance", {}) as Dictionary).duplicate(true), "pendingAvoidance": (entry.get("_v2LeaseExecutorPendingAvoidance", {}) as Dictionary).duplicate(true), "deferredCallback": (entry.get("routeLeaseDeferredCallback", {}) as Dictionary).duplicate(true), "deferredExecution": (entry.get("routeLeaseDeferredExecution", {}) as Dictionary).duplicate(true)})})
		if completed.size() == actor_specs.size() and completed.values().all(func(value) -> bool: return bool(value)):
			break
		await get_tree().physics_frame
	var lane_a_link := String((selected_links.get("lane-a-leader", {}) as Dictionary).get("linkId", ""))
	var lane_b_link := String((selected_links.get("lane-b-leader", {}) as Dictionary).get("linkId", ""))
	var link_assignment_valid := not lane_a_link.is_empty() \
		and not lane_b_link.is_empty() \
		and lane_a_link != lane_b_link \
		and lane_a_link == String((selected_links.get("lane-a-follower", {}) as Dictionary).get("linkId", "")) \
		and lane_b_link == String((selected_links.get("lane-b-follower", {}) as Dictionary).get("linkId", "")) \
		and String((selected_links.get("lane-a-leader", {}) as Dictionary).get("seamCorridorId", "")) == String((selected_links.get("lane-b-leader", {}) as Dictionary).get("seamCorridorId", ""))
	for actor_index in range(entries.size()):
		executors[actor_index].cancel_entry(entries[actor_index])
	transition_npc_system.npcs = []
	var cancellation_handoff := await _run_production_transition_cancel_handoff(fixture, autonomy, transition_npc_system, service)
	var traffic_stats: Dictionary = autonomy.traffic_reservations.stats()
	var all_completed := completed.size() == actor_specs.size() and completed.values().all(func(value) -> bool: return bool(value))
	var passed := link_assignment_valid and adjacent_lanes_active_together and same_lane_followers_queued and all_completed and not cross_lane_overlap and not unexpected_collision and bool(cancellation_handoff.get("passed", false)) and int(traffic_stats.get("activeReservations", -1)) == 0
	var result := {"passed": passed, "movementAuthority": "NpcRouteLeaseExecutor+CharacterBody3D+NpcCrowdVelocityService", "selectedLinks": selected_links, "linkAssignmentValid": link_assignment_valid, "adjacentLanesActiveTogether": adjacent_lanes_active_together, "sameLaneFollowersQueued": same_lane_followers_queued, "allCompleted": all_completed, "crossLaneOverlap": cross_lane_overlap, "unexpectedCollision": unexpected_collision, "cancellationHandoff": cancellation_handoff, "traffic": traffic_stats, "crowd": autonomy.crowd_velocity_service.stats(), "timeline": timeline}
	fixture.queue_free()
	await get_tree().physics_frame
	return result


func _run_production_transition_cancel_handoff(fixture: Node3D, autonomy, transition_npc_system: Node, service) -> Dictionary:
	var expired_before := int(autonomy.traffic_reservations.stats().get("expired", 0))
	var released_before := int(autonomy.traffic_reservations.stats().get("released", 0))
	var specs: Array[Dictionary] = [
		{"id": "cancel-lane-leader", "z": 3169.80, "priority": 130, "targetZ": 3180.00},
		{"id": "cancel-lane-follower", "z": 3168.80, "priority": 110, "targetZ": 3178.20}
	]
	var entries: Array[Dictionary] = []
	var executors: Array = []
	for spec in specs:
		var actor_id := String(spec.get("id", ""))
		var body := _transition_body(actor_id, Vector3(-358.88, 23.75, float(spec.get("z", 0.0))))
		body.set_meta("npc_stable_id", actor_id)
		fixture.add_child(body)
		var entry := {"id": actor_id, "body": body, "routePriority": int(spec.get("priority", 100)), "motorProfile": CharacterMotorProfileScript.npc_default()}
		var route: Dictionary = service.query_route(body.global_position, Vector3(-358.88, 23.75, float(spec.get("targetZ", 0.0))), {"maxSnapDistance": 1.0, "queryApi": "query_path", "pathPostprocessing": NavigationPathQueryParameters3D.PATH_POSTPROCESSING_CORRIDORFUNNEL, "simplifyPath": true, "simplifyEpsilon": NpcConstantsScript.NAVMESH_PATH_SIMPLIFY_EPSILON})
		entry["routeLease"] = _transition_lease(actor_id, route)
		entry["routeStatus"] = "moving"
		var action: Dictionary = (route.get("actions", {}) as Dictionary).values()[0] as Dictionary if not (route.get("actions", {}) as Dictionary).is_empty() else {}
		if not action.is_empty():
			body.global_position = action.get("queuePosition", body.global_position) as Vector3 if actor_id.contains("follower") else action.get("stagingPosition", body.global_position) as Vector3
		var executor = NpcRouteLeaseExecutorScript.new()
		executor.setup(null, null, autonomy, autonomy.crowd_velocity_service)
		entries.append(entry)
		executors.append(executor)
	transition_npc_system.set("npcs", entries)
	await get_tree().physics_frame
	var leader_crossing_observed := false
	var follower_queued_observed := false
	var leader_cancelled := false
	var follower_handoff_observed := false
	var follower_completed := false
	var unexpected_collision := false
	var cancellation_frame := -1
	var timeline: Array[Dictionary] = []
	for frame in range(480):
		autonomy.crowd_velocity_service.begin_physics_frame(entries)
		autonomy.advance_traffic(1.0 / 60.0, false)
		var statuses := {}
		for actor_index in range(entries.size()):
			var entry: Dictionary = entries[actor_index]
			var actor_id := String(entry.get("id", ""))
			var result: Dictionary = executors[actor_index].execute(entry, "%s-request" % actor_id, entry.get("routeLease", {}) as Dictionary, 1.0 / 60.0, {"speed": 2.0, "waypointRadius": 0.18})
			statuses[actor_id] = {"status": String(result.get("status", "")), "reason": String(result.get("reason", "")), "moved": float(result.get("moved", 0.0))}
			unexpected_collision = unexpected_collision or String(result.get("reason", "")) == "unexpected_collision"
			if actor_id == "cancel-lane-follower":
				follower_completed = follower_completed or String(result.get("status", "")) == "arrived"
		autonomy.crowd_velocity_service.end_physics_frame()
		if not leader_cancelled:
			var leader_active: Dictionary = entries[0].get("activeNavigationTransition", {}) if entries[0].get("activeNavigationTransition", {}) is Dictionary else {}
			var follower_pending: Dictionary = entries[1].get("pendingNavigationTransition", {}) if entries[1].get("pendingNavigationTransition", {}) is Dictionary else {}
			leader_crossing_observed = leader_crossing_observed or String(leader_active.get("phase", "")) == "crossing"
			follower_queued_observed = follower_queued_observed or not follower_pending.is_empty()
			if leader_crossing_observed and follower_queued_observed:
				cancellation_frame = frame
				executors[0].cancel_entry(entries[0])
				var leader_body := entries[0].get("body") as CharacterBody3D
				if leader_body != null:
					leader_body.queue_free()
				entries.remove_at(0)
				executors.remove_at(0)
				transition_npc_system.set("npcs", entries)
				leader_cancelled = true
		else:
			var follower_active: Dictionary = entries[0].get("activeNavigationTransition", {}) if entries[0].get("activeNavigationTransition", {}) is Dictionary else {}
			follower_handoff_observed = follower_handoff_observed or not follower_active.is_empty() or follower_completed
		if frame % 20 == 0 or frame == cancellation_frame or follower_completed:
			timeline.append({"frame": frame, "statuses": statuses, "leaderCancelled": leader_cancelled, "traffic": autonomy.traffic_reservations.to_summary(), "positions": entries.map(func(entry: Dictionary): return {"id": entry.get("id", ""), "position": (entry.get("body") as CharacterBody3D).global_position})})
		if follower_completed:
			break
		await get_tree().physics_frame
	for actor_index in range(entries.size()):
		executors[actor_index].cancel_entry(entries[actor_index])
	transition_npc_system.set("npcs", [])
	var traffic_stats: Dictionary = autonomy.traffic_reservations.stats()
	var release_delta := int(traffic_stats.get("released", 0)) - released_before
	var expiry_delta := int(traffic_stats.get("expired", 0)) - expired_before
	var passed := leader_crossing_observed and follower_queued_observed and leader_cancelled and follower_handoff_observed and follower_completed and release_delta >= 2 and expiry_delta == 0 and not unexpected_collision and int(traffic_stats.get("activeReservations", -1)) == 0
	return {"passed": passed, "leaderCrossingObserved": leader_crossing_observed, "followerQueuedObserved": follower_queued_observed, "leaderCancelled": leader_cancelled, "followerHandoffObserved": follower_handoff_observed, "followerCompleted": follower_completed, "releaseDelta": release_delta, "expiryDelta": expiry_delta, "unexpectedCollision": unexpected_collision, "traffic": traffic_stats, "timeline": timeline}


func _waiter_is_outside_transition_corridor(position: Vector3, pending: Dictionary) -> bool:
	var action: Dictionary = pending.get("action", {}) if pending.get("action", {}) is Dictionary else {}
	var entry_position: Vector3 = action.get("entryPosition", Vector3.INF) as Vector3
	var exit_position: Vector3 = action.get("exitPosition", Vector3.INF) as Vector3
	var queue_position: Vector3 = action.get("queuePosition", Vector3.INF) as Vector3
	if not entry_position.is_finite() or not exit_position.is_finite() or not queue_position.is_finite():
		return false
	var axis := exit_position - entry_position
	axis.y = 0.0
	if axis.length_squared() <= 0.000001:
		return false
	axis = axis.normalized()
	var waiter_offset := position - entry_position
	waiter_offset.y = 0.0
	var queue_distance := Vector2(position.x - queue_position.x, position.z - queue_position.z).length()
	return waiter_offset.dot(axis) <= -NpcConstantsScript.DEFAULT_NPC_RADIUS and queue_distance <= 0.24


func _path_query_metadata_summary(query: Dictionary) -> Dictionary:
	var rid_ids: Array[int] = []
	for rid_value in query.get("pathRids", []):
		if rid_value is RID:
			rid_ids.append((rid_value as RID).get_id())
	var path_types: Array[int] = []
	for type_value in query.get("pathTypes", PackedInt32Array()):
		path_types.append(int(type_value))
	return {
		"path": query.get("path", []),
		"pathRidIds": rid_ids,
		"pathTypes": path_types,
		"queryApi": String(query.get("queryApi", ""))
	}


func _generated_surface_transition_fixture() -> Dictionary:
	var source := SeamManifestSource.new()
	var main := SeamFixtureMain.new()
	var support := _adjacent_support_fixture("support:generated-transition", "floor:generated-transition", 2.24, 5.76, 0.14)
	support["polygon"] = [
		Vector3(2.24, 0.14, 1.28),
		Vector3(2.24, 0.14, 4.48),
		Vector3(5.76, 0.14, 4.48),
		Vector3(5.76, 0.14, 1.28)
	]
	source.building_manifests = [{
		"supports": [support],
		"verticalLinks": [],
		"supportSeamLinks": [],
		"interiorPassageLinks": [],
		"doors": [],
		"staticCollision": []
	}]
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	adapter.setup(source, main)
	adapter.call("cached_static_tile_snapshot", true, true)
	var tile_snapshot: Dictionary = adapter.build_navmesh_tile_snapshot("0,0")
	var links: Array = []
	for link_value in tile_snapshot.get("navigationLinks", []) as Array:
		if link_value is Dictionary and String((link_value as Dictionary).get("kind", "")) == "surface_transition":
			links.append(link_value)
	return {"adapter": adapter, "main": main, "source": source, "tileSnapshot": tile_snapshot, "links": links}


func _generated_cross_tile_transition_fixture() -> Dictionary:
	var source := SeamManifestSource.new()
	var main := SeamFixtureMain.new()
	var owner_support := _adjacent_support_fixture("support:generated-cross-tile-owner", "floor:generated-cross-tile-owner", 17.20, 20.88, 0.14)
	owner_support["tileKeys"] = ["0,0"]
	owner_support["producerTileKey"] = "0,0"
	owner_support["worldPosition"] = Vector3(19.04, 0.14, 2.88)
	owner_support["polygon"] = [Vector3(17.20, 0.14, 1.28), Vector3(17.20, 0.14, 4.48), Vector3(20.88, 0.14, 4.48), Vector3(20.88, 0.14, 1.28)]
	var endpoint_support := _adjacent_support_fixture("support:generated-cross-tile-endpoint", "floor:generated-cross-tile-endpoint", 20.89, 24.40, 0.36)
	endpoint_support["tileKeys"] = ["1,0"]
	endpoint_support["producerTileKey"] = "1,0"
	endpoint_support["worldPosition"] = Vector3(22.645, 0.36, 2.88)
	endpoint_support["polygon"] = [Vector3(20.89, 0.36, 1.28), Vector3(20.89, 0.36, 4.48), Vector3(24.40, 0.36, 4.48), Vector3(24.40, 0.36, 1.28)]
	source.building_manifests = [{"supports": [owner_support, endpoint_support], "verticalLinks": [], "supportSeamLinks": [], "interiorPassageLinks": [], "doors": [], "staticCollision": []}]
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	adapter.setup(source, main)
	adapter.call("cached_static_tile_snapshot", true, true)
	var owner_snapshot: Dictionary = adapter.build_navmesh_tile_snapshot("0,0")
	var endpoint_snapshot: Dictionary = adapter.build_navmesh_tile_snapshot("1,0")
	var unrelated_snapshot: Dictionary = adapter.build_navmesh_tile_snapshot("3,0")
	var owner_cross_links: Array = []
	var endpoint_cross_links: Array = []
	for link_value in owner_snapshot.get("navigationLinks", []) as Array:
		if link_value is Dictionary and String((link_value as Dictionary).get("startTileKey", "")) != String((link_value as Dictionary).get("endTileKey", "")):
			owner_cross_links.append(link_value)
	for link_value in endpoint_snapshot.get("navigationLinks", []) as Array:
		if link_value is Dictionary and String((link_value as Dictionary).get("startTileKey", "")) != String((link_value as Dictionary).get("endTileKey", "")):
			endpoint_cross_links.append(link_value)
	return {"adapter": adapter, "main": main, "source": source, "ownerSnapshot": owner_snapshot, "endpointSnapshot": endpoint_snapshot, "unrelatedSnapshot": unrelated_snapshot, "ownerCrossLinks": owner_cross_links, "endpointCrossLinks": endpoint_cross_links, "publicationFailures": adapter.surface_transition_publication_failures.duplicate(true)}


func _generated_signed_cross_tile_transition_fixture() -> Dictionary:
	var source := SeamManifestSource.new()
	var main := SeamFixtureMain.new()
	var owner_support := _adjacent_support_fixture("support:generated-signed-owner", "floor:generated-signed-owner", -371.20, -367.92, 0.14)
	owner_support["tileKeys"] = ["-18,147"]
	owner_support["producerTileKey"] = "-18,147"
	owner_support["worldPosition"] = Vector3(-369.56, 0.14, 3176.8)
	owner_support["polygon"] = [Vector3(-371.20, 0.14, 3176.0), Vector3(-371.20, 0.14, 3177.6), Vector3(-367.92, 0.14, 3177.6), Vector3(-367.92, 0.14, 3176.0)]
	var endpoint_support := _adjacent_support_fixture("support:generated-signed-endpoint", "floor:generated-signed-endpoint", -367.91, -364.20, 0.36)
	endpoint_support["tileKeys"] = ["-17,147"]
	endpoint_support["producerTileKey"] = "-17,147"
	endpoint_support["worldPosition"] = Vector3(-366.055, 0.36, 3176.8)
	endpoint_support["polygon"] = [Vector3(-367.91, 0.36, 3176.0), Vector3(-367.91, 0.36, 3177.6), Vector3(-364.20, 0.36, 3177.6), Vector3(-364.20, 0.36, 3176.0)]
	source.building_manifests = [{"supports": [owner_support, endpoint_support], "verticalLinks": [], "supportSeamLinks": [], "interiorPassageLinks": [], "doors": [], "staticCollision": []}]
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	adapter.setup(source, main)
	adapter.call("cached_static_tile_snapshot", true, true)
	var owner_snapshot: Dictionary = adapter.build_navmesh_tile_snapshot("-18,147")
	var endpoint_snapshot: Dictionary = adapter.build_navmesh_tile_snapshot("-17,147")
	var owner_samples: Dictionary = adapter.call("_building_support_navigation_sample_data", owner_support, owner_snapshot, "-18,147") as Dictionary
	var endpoint_samples: Dictionary = adapter.call("_building_support_navigation_sample_data", endpoint_support, endpoint_snapshot, "-17,147") as Dictionary
	var seam_start := Vector3(-368.16, 0.18, 3176.80)
	var seam_end := Vector3(-367.84, 0.40, 3176.80)
	var seam_certificate: Dictionary = adapter.call("_building_support_transition_seam_certificate", owner_support, endpoint_support, seam_start, seam_end) as Dictionary
	var seam_snapshot: Dictionary = adapter.call("_surface_transition_validation_snapshot", owner_snapshot, ["-18,147", "-17,147"]) as Dictionary
	var seam_blocker: Dictionary = adapter.call("_building_navigation_link_blocker", seam_snapshot, owner_support, seam_start, seam_end, 0.52, ["floor:generated-signed-endpoint"]) as Dictionary
	var seam_endpoints: Dictionary = adapter.call("_certified_surface_transition_endpoints", owner_snapshot, {"start": seam_start, "end": seam_end, "startSupportId": "support:generated-signed-owner", "endSupportId": "support:generated-signed-endpoint", "startTileKey": "-18,147", "endTileKey": "-17,147"}, "diagnostic:signed-seam") as Dictionary
	var seam_endpoint_failure: Dictionary = adapter.surface_transition_publication_failures.back() as Dictionary if seam_endpoints.is_empty() and not adapter.surface_transition_publication_failures.is_empty() else {}
	var manual_cross_links: Array = adapter.call("_derived_surface_transition_links", owner_snapshot, "-18,147", {"support:generated-signed-owner": owner_samples}, []) as Array
	var owner_cross_links: Array = []
	var endpoint_cross_links: Array = []
	for link_value in owner_snapshot.get("navigationLinks", []) as Array:
		if link_value is Dictionary and String((link_value as Dictionary).get("startTileKey", "")) != String((link_value as Dictionary).get("endTileKey", "")):
			owner_cross_links.append(link_value)
	for link_value in endpoint_snapshot.get("navigationLinks", []) as Array:
		if link_value is Dictionary and String((link_value as Dictionary).get("startTileKey", "")) != String((link_value as Dictionary).get("endTileKey", "")):
			endpoint_cross_links.append(link_value)
	return {"adapter": adapter, "ownerSnapshot": owner_snapshot, "endpointSnapshot": endpoint_snapshot, "ownerSamples": owner_samples, "endpointSamples": endpoint_samples, "seamCertificate": seam_certificate, "seamBlocker": seam_blocker, "seamEndpoints": seam_endpoints, "seamEndpointFailure": seam_endpoint_failure, "manualCrossLinks": manual_cross_links, "ownerCrossLinks": owner_cross_links, "endpointCrossLinks": endpoint_cross_links, "publicationFailures": adapter.surface_transition_publication_failures.duplicate(true)}


func _generated_signed_cross_tile_transition_negative(physical_gap: float, endpoint_blocked: bool) -> Dictionary:
	var source := SeamManifestSource.new()
	var main := SeamFixtureMain.new()
	var owner_support := _adjacent_support_fixture("support:negative-owner", "floor:negative-owner", -371.20, -367.92, 0.14)
	owner_support["tileKeys"] = ["-18,147"]
	owner_support["producerTileKey"] = "-18,147"
	owner_support["worldPosition"] = Vector3(-369.56, 0.14, 3176.8)
	owner_support["polygon"] = [Vector3(-371.20, 0.14, 3176.0), Vector3(-371.20, 0.14, 3177.6), Vector3(-367.92, 0.14, 3177.6), Vector3(-367.92, 0.14, 3176.0)]
	var endpoint_min_x := -367.92 + physical_gap
	var endpoint_support := _adjacent_support_fixture("support:negative-endpoint", "floor:negative-endpoint", endpoint_min_x, -364.20, 0.36)
	endpoint_support["tileKeys"] = ["-17,147"]
	endpoint_support["producerTileKey"] = "-17,147"
	endpoint_support["worldPosition"] = Vector3((endpoint_min_x - 364.20) * 0.5, 0.36, 3176.8)
	endpoint_support["polygon"] = [Vector3(endpoint_min_x, 0.36, 3176.0), Vector3(endpoint_min_x, 0.36, 3177.6), Vector3(-364.20, 0.36, 3177.6), Vector3(-364.20, 0.36, 3176.0)]
	source.building_manifests = [{"supports": [owner_support, endpoint_support], "verticalLinks": [], "supportSeamLinks": [], "interiorPassageLinks": [], "doors": [], "staticCollision": []}]
	if endpoint_blocked:
		source.collision_manifests = [{"sourceKind": "building", "staticCollision": [{
			"id": "wall:endpoint-tile-only",
			"sourcePartId": "wall:endpoint-tile-only",
			"bounds": AABB(Vector3(-367.02, 0.20, 3176.0), Vector3(0.16, 2.0, 1.6))
		}]}]
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	adapter.setup(source, main)
	adapter.call("cached_static_tile_snapshot", true, true)
	var owner_snapshot: Dictionary = adapter.build_navmesh_tile_snapshot("-18,147")
	var endpoint_snapshot: Dictionary = adapter.build_navmesh_tile_snapshot("-17,147")
	var owner_links: Array = []
	var endpoint_links: Array = []
	for link_value in owner_snapshot.get("navigationLinks", []) as Array:
		if link_value is Dictionary and String((link_value as Dictionary).get("startTileKey", "")) != String((link_value as Dictionary).get("endTileKey", "")):
			owner_links.append(link_value)
	for link_value in endpoint_snapshot.get("navigationLinks", []) as Array:
		if link_value is Dictionary and String((link_value as Dictionary).get("startTileKey", "")) != String((link_value as Dictionary).get("endTileKey", "")):
			endpoint_links.append(link_value)
	return {"physicalGap": physical_gap, "endpointBlocked": endpoint_blocked, "ownerLinks": owner_links, "endpointLinks": endpoint_links, "publicationFailures": adapter.surface_transition_publication_failures.duplicate(true)}


func _production_citadel_segment_02_forecourt_03_fixture() -> Dictionary:
	var source := SeamManifestSource.new()
	var main := SeamFixtureMain.new()
	var segment_02 := _production_citadel_support("support:castle_compound_paving_segment_02", "castle_compound_paving_segment_02", -364.54, -356.36, 3145.660, 3171.498, 23.71, ["-17,146"])
	var forecourt := _production_citadel_support("support:castle_keep_palace_entry_forecourt", "castle_keep_palace_entry_forecourt", -364.50, -356.40, 3171.518, 3174.580, 23.71, ["-17,146"])
	var segment_03 := _production_citadel_support("support:castle_compound_paving_segment_03", "castle_compound_paving_segment_03", -364.54, -356.36, 3174.578, 3202.040, 23.85, ["-17,147"])
	source.building_manifests = [{"supports": [segment_02, forecourt, segment_03], "verticalLinks": [], "supportSeamLinks": [], "interiorPassageLinks": [], "doors": [], "staticCollision": []}]
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	adapter.setup(source, main)
	adapter.call("cached_static_tile_snapshot", true, true)
	var owner_snapshot: Dictionary = adapter.build_navmesh_tile_snapshot("-17,146")
	var endpoint_snapshot: Dictionary = adapter.build_navmesh_tile_snapshot("-17,147")
	var forecourt_samples: Dictionary = adapter.call("_building_support_navigation_sample_data", forecourt, owner_snapshot, "-17,146") as Dictionary
	var segment_03_samples: Dictionary = adapter.call("_building_support_navigation_sample_data", segment_03, endpoint_snapshot, "-17,147") as Dictionary
	var owner_cross_links: Array = []
	var endpoint_cross_links: Array = []
	for link_value in owner_snapshot.get("navigationLinks", []) as Array:
		if link_value is Dictionary and String((link_value as Dictionary).get("startTileKey", "")) != String((link_value as Dictionary).get("endTileKey", "")):
			owner_cross_links.append(link_value)
	for link_value in endpoint_snapshot.get("navigationLinks", []) as Array:
		if link_value is Dictionary and String((link_value as Dictionary).get("startTileKey", "")) != String((link_value as Dictionary).get("endTileKey", "")):
			endpoint_cross_links.append(link_value)
	return {"adapter": adapter, "ownerSnapshot": owner_snapshot, "endpointSnapshot": endpoint_snapshot, "forecourtSamples": forecourt_samples, "segment03Samples": segment_03_samples, "ownerCrossLinks": owner_cross_links, "endpointCrossLinks": endpoint_cross_links, "publicationFailures": adapter.surface_transition_publication_failures.duplicate(true)}


func _production_citadel_support(id: String, source_part_id: String, min_x: float, max_x: float, min_z: float, max_z: float, height: float, tile_keys: Array) -> Dictionary:
	return {
		"id": id,
		"cell": Vector3i.ZERO,
		"worldPosition": Vector3((min_x + max_x) * 0.5, height, (min_z + max_z) * 0.5),
		"floorNormal": Vector3.UP,
		"headroom": 3.0,
		"lateralClearance": 4.0,
		"traversalTags": ["building", "support", "castle_courtyard_paving"],
		"sourcePartId": source_part_id,
		"sourceCollisionPartId": source_part_id,
		"tileKeys": tile_keys.duplicate(),
		"producerTileKey": String(tile_keys[0]) if not tile_keys.is_empty() else "",
		"polygon": [Vector3(min_x, height, min_z), Vector3(min_x, height, max_z), Vector3(max_x, height, max_z), Vector3(max_x, height, min_z)]
	}


func _generated_signed_support_terrain_transition_fixture() -> Dictionary:
	var source := SeamManifestSource.new()
	var main := SeamFixtureMain.new()
	var support := _adjacent_support_fixture("support:signed-support-terrain", "floor:signed-support-terrain", -371.20, -366.08, 0.14)
	support["tileKeys"] = ["-18,147", "-17,147"]
	support["producerTileKey"] = "-18,147"
	support["worldPosition"] = Vector3(-369.92, 0.14, 3176.8)
	support["polygon"] = [Vector3(-371.20, 0.14, 3176.0), Vector3(-371.20, 0.14, 3177.6), Vector3(-366.08, 0.14, 3177.6), Vector3(-366.08, 0.14, 3176.0)]
	source.building_manifests = [{"supports": [support], "verticalLinks": [], "supportSeamLinks": [], "interiorPassageLinks": [], "doors": [], "staticCollision": []}]
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	adapter.setup(source, main)
	adapter.call("cached_static_tile_snapshot", true, true)
	var support_snapshot: Dictionary = adapter.build_navmesh_tile_snapshot("-18,147")
	var seam_snapshot: Dictionary = adapter.build_navmesh_tile_snapshot("-17,147")
	var support_terrain_links := _support_terrain_links(support_snapshot, "terrain:-271,2353")
	var seam_terrain_links := _support_terrain_links(seam_snapshot, "terrain:-271,2353")
	return {"adapter": adapter, "supportSnapshot": support_snapshot, "seamSnapshot": seam_snapshot, "supportTerrainLinks": support_terrain_links, "seamTerrainLinks": seam_terrain_links, "publicationFailures": adapter.surface_transition_publication_failures.duplicate(true)}


func _support_terrain_links(snapshot: Dictionary, terrain_owner_filter := "") -> Array:
	var result: Array = []
	for link_value in snapshot.get("navigationLinks", []) as Array:
		if not (link_value is Dictionary):
			continue
		var link: Dictionary = link_value
		if String(link.get("kind", "")) != "surface_transition":
			continue
		var source_owners: Array = link.get("sourceOwners", []) if link.get("sourceOwners", []) is Array else []
		if source_owners.any(func(owner) -> bool: return String(owner) == terrain_owner_filter if terrain_owner_filter != "" else String(owner).begins_with("terrain:")):
			result.append(link)
	return result


func _transition_lease(owner_id: String, route: Dictionary) -> Dictionary:
	var route_waypoints: Array = []
	if route.get("waypoints", []) is Array and not (route.get("waypoints", []) as Array).is_empty():
		route_waypoints = route.get("waypoints", []) as Array
	elif route.get("path", []) is Array:
		route_waypoints = route.get("path", []) as Array
	return {
		"leaseId": "lease:%s" % owner_id,
		"ownerNpcId": owner_id,
		"generation": 1,
		"state": "ready",
		"reason": "none",
		"source": "navmesh",
		"snapshotRevision": String(route.get("snapshotRevision", "")),
		"cells": [],
		"waypoints": route_waypoints.duplicate(),
		"actions": (route.get("actions", {}) as Dictionary).duplicate(true),
		"probeCertificate": {"ok": true, "authoritative": true, "status": "passed"}
	}


func _transition_body(node_name: String, position: Vector3) -> CharacterBody3D:
	var body := CharacterBody3D.new()
	body.name = node_name
	body.position = position
	body.collision_layer = 1
	body.collision_mask = 1
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.34
	capsule.height = 1.62
	var collider := CollisionShape3D.new()
	collider.shape = capsule
	collider.position.y = 0.84
	body.add_child(collider)
	return body


func _transition_phase_tile_descriptor(tile_key: String):
	var tile := Vector2i(int(tile_key.get_slice(",", 0)), int(tile_key.get_slice(",", 1)))
	var tile_world_size := float(NpcConstantsScript.NAV_TILE_CELL_SIZE) * NpcConstantsScript.CELL_SIZE
	var tile_world_min := Vector3(float(tile.x) * tile_world_size, -0.10, float(tile.y) * tile_world_size)
	var descriptor = NavigationBakeDescriptorScript.create(NavigationBakeDescriptorScript.chunk_region_id(tile_key), tile_key, AABB(tile_world_min, Vector3(tile_world_size, 0.20, tile_world_size)))
	descriptor.metadata = {"source": "phase_freshness_fixture", "sourceKey": "1:0:0", "semanticRevision": 0}
	descriptor.add_walkable_surface("surface:%s:phase-freshness" % tile_key, tile_world_min + Vector3(0.32, 0.10, 0.32), Vector3(0.32, 0.05, 0.32))
	return descriptor


func _execute_until_transition_state(executor, entry: Dictionary, request_id: String, lease: Dictionary, maximum_frames := 180) -> Dictionary:
	var result: Dictionary = {}
	for _frame in range(maximum_frames):
		result = executor.execute(entry, request_id, lease, 1.0 / 60.0, {"speed": 2.6, "waypointRadius": 0.18})
		if not bool(result.get("ok", false)) or not (entry.get("activeNavigationTransition", {}) as Dictionary).is_empty():
			break
	return result


func _transition_floor(node_name: String, position: Vector3, size: Vector3) -> StaticBody3D:
	var floor := StaticBody3D.new()
	floor.name = node_name
	floor.position = position
	floor.collision_layer = 1
	floor.collision_mask = 1
	var shape := BoxShape3D.new()
	shape.size = size
	var collider := CollisionShape3D.new()
	collider.shape = shape
	floor.add_child(collider)
	return floor


func run_raised_floor_motor_grounding_probe() -> Dictionary:
	var fixture := Node3D.new()
	fixture.name = "RaisedFloorMotorFixture"
	add_child(fixture)
	var lower_floor := _transition_floor("LowerTerrainCollision", Vector3(0.0, 0.49, 0.0), Vector3(8.0, 0.20, 4.0))
	var raised_floor := _transition_floor("ConstructionStaticCollisionBatch", Vector3(0.0, 0.69, 0.0), Vector3(5.0, 0.14, 3.0))
	var raised_shape := raised_floor.get_child(0) as CollisionShape3D
	raised_shape.set_meta("building_part_id", "castle_compound_paving_segment_probe")
	raised_shape.set_meta("building_part_kind", "foundation")
	raised_shape.set_meta("building_semantic", "castle_courtyard_paving")
	var blocker := _transition_floor("ConstructionStaticCollisionBatch", Vector3(1.55, 1.35, 0.0), Vector3(0.30, 1.50, 2.0))
	var blocker_shape := blocker.get_child(0) as CollisionShape3D
	blocker_shape.set_meta("building_part_id", "castle_forecourt_blocker_probe")
	blocker_shape.set_meta("building_part_kind", "wall")
	blocker_shape.set_meta("building_semantic", "castle_forecourt_blocker")
	var body := _transition_body("RaisedFloorNpc", Vector3(-1.25, 0.78, 0.0))
	var terrain_provider := RaisedFloorTerrainProvider.new()
	fixture.add_child(lower_floor)
	fixture.add_child(raised_floor)
	fixture.add_child(blocker)
	fixture.add_child(body)
	fixture.add_child(terrain_provider)
	await get_tree().physics_frame
	var motor = CharacterMotor3DScript.new()
	var profile = CharacterMotorProfileScript.npc_default()
	var command = CharacterMotorCommandScript.from_velocity(Vector3(2.6, 0.0, 0.0))
	command.grounded_hint = true
	command.terrain_grounded = true
	var minimum_raised_y := body.global_position.y
	var maximum_x := body.global_position.x
	var blocker_state = null
	for _frame in range(90):
		var state = motor.apply(body, command, profile, 1.0 / 60.0, terrain_provider)
		minimum_raised_y = minf(minimum_raised_y, body.global_position.y)
		maximum_x = maxf(maximum_x, body.global_position.x)
		if bool(state.get("blocked")) and String(state.get("blocked_contact_part_id")) == "castle_forecourt_blocker_probe":
			blocker_state = state
			break
		await get_tree().physics_frame
	var raised_floor_preserved := minimum_raised_y >= terrain_provider.lower_ground_y + 0.12 and maximum_x > -0.5
	var blocker_attributed := blocker_state != null \
		and String(blocker_state.get("blocked_contact_semantic")) == "castle_forecourt_blocker" \
		and (blocker_state.get("blocked_contacts") as Array).any(func(contact) -> bool: return contact is Dictionary and String((contact as Dictionary).get("partId", "")) == "castle_forecourt_blocker_probe")
	blocker.queue_free()
	raised_floor.queue_free()
	lower_floor.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var settle_command = CharacterMotorCommandScript.from_velocity(Vector3.ZERO)
	settle_command.grounded_hint = true
	settle_command.terrain_grounded = true
	var maximum_downward_terrain_correction := 0.0
	for _frame in range(90):
		var settle_state = motor.apply(body, settle_command, profile, 1.0 / 60.0, terrain_provider)
		maximum_downward_terrain_correction = maxf(maximum_downward_terrain_correction, float(settle_state.get("downward_terrain_correction")))
		await get_tree().physics_frame
	var resumed_lower_ground := absf(body.global_position.y - terrain_provider.lower_ground_y) <= 0.04 \
		and maximum_downward_terrain_correction > 0.0 \
		and not body.is_on_floor()
	var result := {
		"passed": raised_floor_preserved and blocker_attributed and resumed_lower_ground,
		"raisedFloorPreserved": raised_floor_preserved,
		"minimumRaisedY": minimum_raised_y,
		"maximumX": maximum_x,
		"blockerAttributed": blocker_attributed,
		"blockerState": blocker_state.to_summary() if blocker_state != null and blocker_state.has_method("to_summary") else {},
		"resumedLowerGround": resumed_lower_ground,
		"maximumDownwardTerrainCorrection": maximum_downward_terrain_correction,
		"physicalFloorContactAfterRemoval": body.is_on_floor(),
		"finalY": body.global_position.y,
		"lowerGroundY": terrain_provider.lower_ground_y
	}
	fixture.queue_free()
	await get_tree().physics_frame
	return result


func run_support_seam_motor_grounding_probe() -> Dictionary:
	var fixture := Node3D.new()
	fixture.name = "SupportSeamMotorFixture"
	add_child(fixture)
	var owner_floor := _transition_floor("OwnerSupportCollision", Vector3(-1.60, 0.07, 0.0), Vector3(3.20, 0.14, 2.0))
	var endpoint_floor := _transition_floor("EndpointSupportCollision", Vector3(1.605, 0.07, 0.0), Vector3(3.20, 0.14, 2.0))
	var body := _transition_body("SupportSeamNpc", Vector3(-1.35, 0.11, 0.0))
	body.floor_snap_length = 0.30
	fixture.add_child(owner_floor)
	fixture.add_child(endpoint_floor)
	fixture.add_child(body)
	await get_tree().physics_frame
	for _frame in range(5):
		body.velocity = Vector3(0.0, -2.0, 0.0)
		body.move_and_slide()
		await get_tree().physics_frame
	var crossed := false
	var airborne_frames := 0
	var minimum_y := body.global_position.y
	var maximum_y := body.global_position.y
	for _frame in range(150):
		body.velocity = Vector3(1.8, -2.0, 0.0)
		body.move_and_slide()
		minimum_y = minf(minimum_y, body.global_position.y)
		maximum_y = maxf(maximum_y, body.global_position.y)
		if not body.is_on_floor():
			airborne_frames += 1
		if body.global_position.x >= 1.0:
			crossed = true
			break
		await get_tree().physics_frame
	var result := {
		"passed": crossed and airborne_frames == 0,
		"crossed": crossed,
		"airborneFrames": airborne_frames,
		"minimumY": minimum_y,
		"maximumY": maximum_y,
		"finalPosition": body.global_position,
		"physicalFloorContact": body.is_on_floor(),
		"movementAuthority": "CharacterBody3D.move_and_slide",
		"physicalGap": 0.01,
		"stepHeight": 0.0
	}
	fixture.queue_free()
	await get_tree().physics_frame
	return result


func run_door_link_proof() -> Dictionary:
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "door_link_proof"))
	var descriptor = NavigationBakeDescriptorScript.create("region:door-link-proof", "door-link-proof", AABB(Vector3(-1.5, -0.1, -1.5), Vector3(3.0, 1.2, 5.7)))
	descriptor.add_walkable_surface("surface:door-link-proof:interior", Vector3(0.0, 0.0, 0.0), Vector3(1.35, 0.05, 1.35))
	descriptor.add_walkable_surface("surface:door-link-proof:exterior", Vector3(0.0, 0.0, 2.7), Vector3(1.35, 0.05, 1.35))
	descriptor.add_door_portal("door:link-proof", Vector3(0.0, 0.0, 0.65), Vector3(0.0, 0.0, 2.05), {"state": "closed", "openable": true, "sourceDoor": true})
	descriptor.add_door_link("surface:door-link-proof:interior", "surface:door-link-proof:exterior", "door:link-proof", {"id": "door-link:proof", "sourceDoor": true, "startSupportId": "support:interior", "endSupportId": "support:exterior"})
	var registration: Dictionary = service.register_chunk_descriptor(descriptor)
	for _frame in range(5):
		await get_tree().physics_frame
	service.sync_navigation_map_if_dirty()
	var enabled_query: Dictionary = service.call("_query_path_points", Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 2.7), {"queryApi": "query_path"})
	var enabled_path: Array = enabled_query.get("path", []) as Array
	var actions: Dictionary = service.diagnostic_door_actions_for_path(enabled_path, {})
	var disabled_path: Array = service.diagnostic_query_path_without_door_links(Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 2.7), ["door:link-proof"], {"queryApi": "query_path"})
	var snapshot: Dictionary = service.debug_snapshot()
	var links: Array = (snapshot.get("doorLinks", {}) as Dictionary).get("door:link-proof", []) as Array
	var link: Dictionary = links[0] as Dictionary if links.size() == 1 and links[0] is Dictionary else {}
	var readiness: Dictionary = snapshot.get("navigationMapReadiness", {}) as Dictionary
	var enabled_endpoint: Vector3 = enabled_path.back() as Vector3 if not enabled_path.is_empty() and enabled_path.back() is Vector3 else Vector3.INF
	var disabled_endpoint: Vector3 = disabled_path.back() as Vector3 if not disabled_path.is_empty() and disabled_path.back() is Vector3 else Vector3.INF
	var exact_action := false
	for action_value in actions.values():
		if action_value is Dictionary and String((action_value as Dictionary).get("portalId", "")) == "door:link-proof":
			exact_action = true
	var published_after_install := int(readiness.get("syncedSerial", -1)) >= int(link.get("installedDirtySerial", 2147483647)) and (not bool(readiness.get("hasIterationApi", false)) or int(readiness.get("iterationId", -1)) > int(link.get("installedIterationId", -1)))
	var passed := bool(registration.get("installed", false)) and links.size() == 1 and enabled_endpoint.is_finite() and enabled_endpoint.distance_to(Vector3(0.0, 0.0, 2.7)) <= 0.001 and exact_action and (not disabled_endpoint.is_finite() or disabled_endpoint.distance_to(Vector3(0.0, 0.0, 2.7)) > 0.001) and published_after_install
	service.clear()
	return {"passed": passed, "registration": registration, "enabledPath": enabled_path, "actions": actions, "disabledPath": disabled_path, "link": link, "readiness": readiness, "publishedAfterInstall": published_after_install}


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


func run_adjacent_support_transition_probe() -> Dictionary:
	var open_fixture := await _run_adjacent_support_transition_case(false)
	var blocked_fixture := await _run_adjacent_support_transition_case(true)
	return {
		"passed": bool(open_fixture.get("routeReachedTarget", false)) \
			and int(open_fixture.get("targetTransitionLinkCount", 0)) > 0 \
			and not bool(open_fixture.get("routeWithoutLinks", {}).get("ok", false)) \
			and int(blocked_fixture.get("targetTransitionLinkCount", -1)) == 0 \
			and not bool(blocked_fixture.get("routeReachedTarget", true)),
		"open": open_fixture,
		"blocked": blocked_fixture
	}


func run_support_prop_detour_probe() -> Dictionary:
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	var support := _adjacent_support_fixture("support:prop-detour", "floor:prop-detour", 2.0, 14.0, 0.04)
	support["polygon"] = [Vector3(2.0, 0.04, 2.0), Vector3(2.0, 0.04, 10.0), Vector3(14.0, 0.04, 10.0), Vector3(14.0, 0.04, 2.0)]
	var supports: Array[Dictionary] = [support]
	adapter.cached_building_supports = supports
	adapter.cached_building_supports_by_tile = {"0,0": supports}
	var prop_collision := {
		"id": "prop:detour",
		"blockType": "prop",
		"minX": 6.90,
		"maxX": 9.10,
		"minY": -0.10,
		"maxY": 1.80,
		"minZ": 4.90,
		"maxZ": 7.10,
		"inflation": 0.52
	}
	var snapshot := {"staticCollision": [prop_collision], "staticCollisionByCell": {}, "staticCollisionBroad": [prop_collision]}
	var sample_data: Dictionary = adapter.call("_building_support_navigation_sample_data_by_id", snapshot, "0,0")
	var surfaces: Array = adapter.call("_navmesh_surfaces_from_building_tile", snapshot, "0,0", 1, sample_data) as Array
	var descriptor = NavigationBakeDescriptorScript.from_tile_snapshot({
		"tileKey": "0,0",
		"regionId": "region:chunk:0,0",
		"sourceRevision": 1,
		"topologyRevision": 1,
		"semanticRevision": 0,
		"surfaces": surfaces,
		"navigationLinks": [],
		"doorPortals": [],
		"doorLinks": [],
		"semanticRegions": []
	})
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "support_prop_detour_test"))
	var registration: Dictionary = service.register_chunk_descriptor(descriptor)
	for _frame in range(5):
		await get_tree().physics_frame
	service.sync_navigation_map_if_dirty()
	var start := Vector3(3.0, 0.08, 6.0)
	var target := Vector3(13.0, 0.08, 6.0)
	var route := service.query_route(start, target, {"maxSnapDistance": 0.6})
	var path: Array = route.get("path", []) as Array
	var validation: Dictionary = adapter.call("_validate_layered_building_route", snapshot, path, {}) as Dictionary if path.size() >= 2 else {"ok": false, "reason": "missing_path"}
	var detoured := false
	for point_value in path:
		if point_value is Vector3 and absf((point_value as Vector3).z - 6.0) > 1.62:
			detoured = true
	var endpoint: Vector3 = path.back() as Vector3 if not path.is_empty() and path.back() is Vector3 else Vector3.INF
	var passed := bool(registration.get("installed", false)) and endpoint.is_finite() and endpoint.distance_to(target) <= 0.05 and detoured and bool(validation.get("ok", false))
	service.clear()
	return {"passed": passed, "registration": registration, "surfaceCount": surfaces.size(), "route": route, "detoured": detoured, "validation": validation}


func _run_adjacent_support_transition_case(blocked: bool) -> Dictionary:
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	adapter.main = SeamFixtureMain.new()
	adapter.cached_revision = "adjacent-support-fixture"
	var upper_support := _adjacent_support_fixture("support:adjacent:upper", "floor:adjacent:upper", 0.0, 4.0, 0.14)
	upper_support["polygon"] = [
		Vector3(0.0, 0.14, -4.0),
		Vector3(0.0, 0.14, 4.0),
		Vector3(4.0, 0.14, 4.0),
		Vector3(4.0, 0.14, -4.0)
	]
	var supports: Array[Dictionary] = [upper_support]
	adapter.cached_building_supports = supports
	adapter.cached_building_supports_by_tile = {"0,0": supports}
	var terrain_surface := {
		"id": "terrain:adjacent:lower",
		"cell": Vector3i.ZERO,
		"spanIndex": 0,
		"worldPosition": Vector3(-2.0, 0.04, 0.0),
		"floorNormal": Vector3.UP,
		"headroom": 3.0,
		"lateralClearance": 1.0,
		"traversalTags": ["terrain"],
		"polygon": [
			Vector3(-4.0, 0.04, -4.0),
			Vector3(-4.0, 0.04, 4.0),
			Vector3(-0.08, 0.04, 4.0),
			Vector3(-0.08, 0.04, -4.0)
		]
	}
	var wall := {
		"id": "wall:adjacent:blocked",
		"sourcePartId": "wall:adjacent:blocked",
		"minX": -0.10,
		"maxX": 0.10,
		"minY": 0.0,
		"maxY": 2.2,
		"minZ": -4.0,
		"maxZ": 4.0,
		"inflation": 0.0
	}
	var broad_collision: Array = [wall] if blocked else []
	var snapshot := {
		"staticCollision": broad_collision,
		"staticCollisionByCell": {},
		"staticCollisionBroad": broad_collision
	}
	var sample_data: Dictionary = adapter.call("_building_support_navigation_sample_data_by_id", snapshot, "0,0")
	var surfaces: Array = [terrain_surface, upper_support.duplicate(true)]
	var links_value = adapter.call("_derived_surface_transition_links", snapshot, "0,0", sample_data, [terrain_surface])
	var links: Array = links_value if links_value is Array else []
	var target_transition_link_count := 0
	for link_value in links:
		if not (link_value is Dictionary):
			continue
		var link: Dictionary = link_value
		var link_start: Vector3 = link.get("start", Vector3.INF) as Vector3
		var link_end: Vector3 = link.get("end", Vector3.INF) as Vector3
		if link_start.is_finite() and link_end.is_finite() and minf(link_start.x, link_end.x) < 0.0 and maxf(link_start.x, link_end.x) > 0.0:
			target_transition_link_count += 1
	var tile_snapshot := {
		"tileKey": "0,0",
		"regionId": "region:chunk:0,0",
		"sourceRevision": 1,
		"topologyRevision": 1,
		"semanticRevision": 0,
		"surfaces": surfaces,
		"navigationLinks": links,
		"doorPortals": [],
		"doorLinks": [],
		"semanticRegions": []
	}
	var descriptor = NavigationBakeDescriptorScript.from_tile_snapshot(tile_snapshot)
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "adjacent_support_transition_test"))
	var registration: Dictionary = service.register_chunk_descriptor(descriptor)
	for _frame in range(5):
		await get_tree().physics_frame
	service.sync_navigation_map_if_dirty()
	var start := Vector3(-3.0, 0.04, 0.16)
	var target := Vector3(3.0, 0.18, 0.16)
	var route := service.query_route(start, target, {"maxSnapDistance": 0.5})
	var route_path: Array = route.get("path", []) as Array
	var route_endpoint: Vector3 = route_path.back() as Vector3 if not route_path.is_empty() and route_path.back() is Vector3 else Vector3.INF
	var route_reached_target := route_endpoint.is_finite() and route_endpoint.distance_to(target) <= 0.05
	var route_without_links := service.query_route(start, target, {"maxSnapDistance": 0.5})
	if not links.is_empty():
		var link_ids: Array[String] = []
		for link_value in links:
			if link_value is Dictionary:
				link_ids.append(String((link_value as Dictionary).get("id", "")))
		var path_without_links: Array = service.diagnostic_query_path_without_navigation_links(start, target, link_ids, {"maxSnapDistance": 0.5})
		route_without_links = {"ok": not path_without_links.is_empty() and (path_without_links.back() as Vector3).distance_to(target) <= 0.05, "path": path_without_links}
	var stats: Dictionary = service.stats()
	service.clear()
	return {
		"registration": registration,
		"surfaceCount": surfaces.size(),
		"derivedLinkCount": links.size(),
		"targetTransitionLinkCount": target_transition_link_count,
		"links": links,
		"route": route,
		"routeReachedTarget": route_reached_target,
		"routeWithoutLinks": route_without_links,
		"publicationFailures": adapter.surface_transition_publication_failures.duplicate(true),
		"stats": stats
	}


func _adjacent_support_fixture(id: String, source_part_id: String, min_x: float, max_x: float, height: float) -> Dictionary:
	return {
		"id": id,
		"cell": Vector3i.ZERO,
		"worldPosition": Vector3((min_x + max_x) * 0.5, height, 0.0),
		"floorNormal": Vector3.UP,
		"headroom": 3.0,
		"lateralClearance": 1.0,
		"traversalTags": ["building", "support"],
		"sourcePartId": source_part_id,
		"sourceCollisionPartId": source_part_id,
		"tileKeys": ["0,0"],
		"polygon": [
			Vector3(min_x, height, -1.28),
			Vector3(min_x, height, 1.28),
			Vector3(max_x, height, 1.28),
			Vector3(max_x, height, -1.28)
		]
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
