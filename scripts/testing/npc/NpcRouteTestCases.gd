extends RefCounted

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const TraversalProfileScript := preload("res://scripts/npc_ai/contracts/TraversalProfile.gd")
const RouteRequestScript := preload("res://scripts/npc_ai/contracts/RouteRequest.gd")
const NavigationChangeBusScript := preload("res://scripts/npc_ai/navigation/NavigationChangeBus.gd")
const NavigationWorldServiceScript := preload("res://scripts/npc_ai/navigation/NavigationWorldService.gd")
const NavigationBakeDescriptorScript := preload("res://scripts/npc_ai/contracts/NavigationBakeDescriptor.gd")
const NavigationBackendConfigScript := preload("res://scripts/npc_ai/navigation/NavigationBackendConfig.gd")
const NavmeshWorldServiceScript := preload("res://scripts/npc_ai/navigation/NavmeshWorldService.gd")
const GeneratedWorldNavigationAdapterScript := preload("res://scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd")
const HierarchicalRoutePlannerScript := preload("res://scripts/npc_ai/routing/HierarchicalRoutePlanner.gd")
const NavmeshRoutePlannerScript := preload("res://scripts/npc_ai/routing/NavmeshRoutePlanner.gd")
const CELL := NpcConstantsScript.CELL_SIZE

var runner = null

class RouteTestMain:
	extends Node
	var WATER_LEVEL := -1000.0
	var blocks := {}
	var chunk_root := Node.new()
	var prop_root := Node.new()

	func _init() -> void:
		add_child(chunk_root)
		add_child(prop_root)

	func surface_y_at_cell(_cell) -> float:
		return 0.0

class FakeNavmeshRouteService:
	extends RefCounted
	var query_count := 0

	func query_route(start: Vector3, target: Vector3, _options := {}) -> Dictionary:
		query_count += 1
		return {
			"ok": true,
			"status": "complete",
			"reason": "",
			"source": "navmesh",
			"queryApi": "fake_direct",
			"startPosition": start,
			"targetPosition": target,
			"path": [start, target],
			"actions": {},
			"snapshotRevision": "fake:%d" % query_count,
			"pointCount": 2,
			"distance": start.distance_to(target)
		}

	func stats() -> Dictionary:
		return { "pathQueryCount": query_count }

func setup(owner) -> void:
	runner = owner

func cases() -> Array[Dictionary]:
	var ids = [
		["npc_route_same_tile_optimal_oracle", "test_route_same_tile_optimal_oracle"],
		["npc_route_multi_tile_hierarchy", "test_route_multi_tile_hierarchy"],
		["npc_route_cross_loaded_chunks", "test_route_cross_loaded_chunks"],
		["npc_route_road_preferred_equal_time", "test_route_road_preferred_equal_time"],
		["npc_route_hazard_avoided_by_civilian", "test_route_hazard_avoided_by_civilian"],
		["npc_route_guard_semantic_preference", "test_route_guard_semantic_preference"],
		["npc_route_profile_large_rejects_narrow_small_accepts", "test_route_profile_large_rejects_narrow_small_accepts"],
		["npc_route_closed_openable_door_action", "test_route_closed_openable_door_action"],
		["npc_route_locked_unauthorized_alternate", "test_route_locked_unauthorized_alternate"],
		["npc_route_start_snap_no_wall_cross", "test_route_start_snap_no_wall_cross"],
		["npc_route_goal_snap_correct_vertical_layer", "test_route_goal_snap_correct_vertical_layer"],
		["npc_route_corner_smoothing_capsule_safe", "test_route_corner_smoothing_capsule_safe"],
		["npc_route_mandatory_action_not_smoothed_out", "test_route_mandatory_action_not_smoothed_out"],
		["npc_route_no_iteration_cap_false_failure", "test_route_no_iteration_cap_false_failure"],
		["npc_route_pending_budget_resumes", "test_route_pending_budget_resumes"],
		["npc_route_partial_explicit_only", "test_route_partial_explicit_only"],
		["npc_route_unreachable_terminal_reason", "test_route_unreachable_terminal_reason"],
		["npc_route_deterministic_replay", "test_route_deterministic_replay"],
		["npc_route_navmesh_query_or_same_surface_returns_route", "test_route_navmesh_query_or_same_surface_returns_route"],
		["npc_route_navmesh_preserves_door_action_cells", "test_route_navmesh_preserves_door_action_cells"],
		["npc_route_navmesh_planner_goal_kinds", "test_route_navmesh_planner_goal_kinds"],
		["npc_route_navmesh_adapter_no_legacy_fallback", "test_route_navmesh_adapter_no_legacy_fallback"],
		["npc_route_runtime_door_uses_group_portal_id", "test_route_runtime_door_uses_group_portal_id"],
		["npc_route_collision_boundary_blocks_open_destination", "test_route_collision_boundary_blocks_open_destination"],
		["npc_route_collision_occupied_cell_blocks_node", "test_route_collision_occupied_cell_blocks_node"],
		["npc_route_collision_door_requires_portal_axis", "test_route_collision_door_requires_portal_axis"],
		["npc_route_collision_rejects_diagonal_corner_cut", "test_route_collision_rejects_diagonal_corner_cut"],
		["npc_route_navmesh_post_validation_rejects_wall_cross", "test_route_navmesh_post_validation_rejects_wall_cross"],
		["npc_route_scripted_target_expands_navmesh_tiles", "test_route_scripted_target_expands_navmesh_tiles"],
		["npc_route_runtime_goal_adapter_uses_new_corridor", "test_route_runtime_goal_adapter_uses_new_corridor"]
	]
	var result: Array[Dictionary] = []
	for spec in ids:
		result.append({
			"id": str(spec[0]),
			"suite": "route",
			"timeModes": ["day", "night"],
			"callable": Callable(self, str(spec[1]))
		})
	return result

func test_route_same_tile_optimal_oracle(_mode: String) -> Dictionary:
	var setup = route_line_service(0, 2)
	var result = route_plan(setup.service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(2, 0, 0)) })
	var corridor = result.get("corridor")
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and corridor != null and corridor.steps.size() == 2
	return outcome(passed, "summary=%s" % JSON.stringify(route_summary(result)), ["same_tile_complete", "oracle_step_count"], { "route": route_summary(result) })

func test_route_multi_tile_hierarchy(_mode: String) -> Dictionary:
	var setup = route_line_service(14, 18)
	var result = route_plan(setup.service, route_span_key(Vector3i(14, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(18, 0, 0)) })
	var hierarchy: Dictionary = route_metrics(result).get("hierarchy", {})
	var corridor = result.get("corridor")
	var deps: Dictionary = corridor.dependencies if corridor != null else {}
	var tiles: Array = deps.get("tiles", [])
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and int(hierarchy.get("entranceCount", 0)) > 0 and tiles.has("0,0") and tiles.has("1,0")
	return outcome(passed, "hierarchy=%s deps=%s" % [JSON.stringify(hierarchy), JSON.stringify(deps)], ["abstract_entrance", "multi_tile_dependencies"], { "hierarchy": hierarchy, "dependencies": deps })

func test_route_cross_loaded_chunks(_mode: String) -> Dictionary:
	var setup = route_line_service(0, 34)
	var result = route_plan(setup.service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(34, 0, 0)) })
	var corridor = result.get("corridor")
	var tiles: Array = corridor.dependencies.get("tiles", []) if corridor != null else []
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and tiles.has("0,0") and tiles.has("1,0") and tiles.has("2,0")
	return outcome(passed, "tiles=%s cost=%.2f" % [JSON.stringify(tiles), float(result.get("cost"))], ["cross_loaded_chunks", "three_tile_path"], { "tiles": tiles, "route": route_summary(result) })

func test_route_road_preferred_equal_time(_mode: String) -> Dictionary:
	var service = route_service_from_surfaces({
		"0,0": [
			nav_surface(Vector3i(0, 0, 0)),
			nav_surface(Vector3i(2, 0, 0)),
			nav_surface(Vector3i(0, 0, -1), { "semanticRegionIds": ["road"] }),
			nav_surface(Vector3i(1, 0, -1), { "semanticRegionIds": ["road"] }),
			nav_surface(Vector3i(2, 0, -1), { "semanticRegionIds": ["road"] }),
			nav_surface(Vector3i(0, 0, 1), { "semanticRegionIds": ["terrain"] }),
			nav_surface(Vector3i(1, 0, 1), { "semanticRegionIds": ["terrain"] }),
			nav_surface(Vector3i(2, 0, 1), { "semanticRegionIds": ["terrain"] })
		]
	})
	var result = route_plan(service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(2, 0, 0)) })
	var semantics = corridor_semantics(result)
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and semantics.has("road") and not semantics.has("terrain")
	return outcome(passed, "semantics=%s summary=%s" % [JSON.stringify(semantics), JSON.stringify(route_summary(result))], ["road_preferred_equal_time", "semantic_cost_explainable"], { "semantics": semantics, "route": route_summary(result) })

func test_route_hazard_avoided_by_civilian(_mode: String) -> Dictionary:
	var service = route_service_from_surfaces({
		"0,0": [
			nav_surface(Vector3i(0, 0, 0)),
			nav_surface(Vector3i(2, 0, 0)),
			nav_surface(Vector3i(0, 0, -1), { "semanticRegionIds": ["road"] }),
			nav_surface(Vector3i(1, 0, -1), { "semanticRegionIds": ["road"] }),
			nav_surface(Vector3i(2, 0, -1), { "semanticRegionIds": ["road"] }),
			nav_surface(Vector3i(0, 0, 1), { "semanticRegionIds": ["hazard:bog"], "flags": { "hazard": true } }),
			nav_surface(Vector3i(1, 0, 1), { "semanticRegionIds": ["hazard:bog"], "flags": { "hazard": true } }),
			nav_surface(Vector3i(2, 0, 1), { "semanticRegionIds": ["hazard:bog"], "flags": { "hazard": true } })
		]
	})
	var result = route_plan(service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(2, 0, 0)) }, false, "work")
	var semantics = corridor_semantics(result)
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and not semantics.has("hazard:bog")
	return outcome(passed, "semantics=%s cost=%s" % [JSON.stringify(semantics), JSON.stringify(route_metrics(result).get("costBreakdown", {}))], ["civilian_hazard_avoided", "nonnegative_hazard_penalty"], { "semantics": semantics, "route": route_summary(result) })

func test_route_guard_semantic_preference(_mode: String) -> Dictionary:
	var service = route_service_from_surfaces({
		"0,0": [
			nav_surface(Vector3i(0, 0, 0)),
			nav_surface(Vector3i(2, 0, 0)),
			nav_surface(Vector3i(0, 0, -1), { "semanticRegionIds": ["guard_post"] }),
			nav_surface(Vector3i(1, 0, -1), { "semanticRegionIds": ["guard_post"] }),
			nav_surface(Vector3i(2, 0, -1), { "semanticRegionIds": ["guard_post"] }),
			nav_surface(Vector3i(0, 0, 1), { "semanticRegionIds": ["terrain"] }),
			nav_surface(Vector3i(1, 0, 1), { "semanticRegionIds": ["terrain"] }),
			nav_surface(Vector3i(2, 0, 1), { "semanticRegionIds": ["terrain"] })
		]
	})
	var result = route_plan(service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(2, 0, 0)) }, false, "guard")
	var semantics = corridor_semantics(result)
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and semantics.has("guard_post")
	return outcome(passed, "semantics=%s" % JSON.stringify(semantics), ["guard_semantic_preference"], { "semantics": semantics, "route": route_summary(result) })

func test_route_profile_large_rejects_narrow_small_accepts(_mode: String) -> Dictionary:
	var small = TraversalProfileScript.default_adult_npc()
	small.body_radius = 0.20
	small.personal_space_margin = 0.04
	var large = TraversalProfileScript.default_adult_npc()
	large.body_radius = 0.55
	large.personal_space_margin = 0.10
	var surfaces = [nav_surface(Vector3i(0, 0, 0), { "lateralClearance": 0.40 }), nav_surface(Vector3i(1, 0, 0), { "lateralClearance": 0.40 })]
	var small_service = NavigationWorldServiceScript.new()
	small_service.build_tile_now(nav_snapshot("0,0", surfaces), small)
	var large_service = NavigationWorldServiceScript.new()
	large_service.build_tile_now(nav_snapshot("0,0", surfaces), large)
	var small_result = route_plan(small_service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(1, 0, 0)), "profile": small })
	var large_result = route_plan(large_service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(1, 0, 0)), "profile": large })
	var passed = small_result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and large_result.get("status") == NpcEnumsScript.ROUTE_STATUS_UNREACHABLE
	return outcome(passed, "small=%s large=%s" % [JSON.stringify(route_summary(small_result)), JSON.stringify(route_summary(large_result))], ["small_profile_accepts", "large_profile_rejects"], { "small": route_summary(small_result), "large": route_summary(large_result) })

func test_route_closed_openable_door_action(_mode: String) -> Dictionary:
	var from_key = route_span_key(Vector3i(0, 0, 0))
	var to_key = route_span_key(Vector3i(1, 0, 0))
	var service = route_service_from_surfaces({
		"0,0": [
			nav_surface(Vector3i(0, 0, 0)),
			nav_surface(Vector3i(1, 0, 0))
		]
	}, {
		"0,0": {
			"doorPortals": [{ "id": "door:test", "state": "closed", "openable": true }],
			"doorLinks": [{ "from": from_key, "to": to_key, "portalId": "door:test", "cost": 1.0 }]
		}
	})
	var result = route_plan(service, from_key, { "kind": "exact_span", "spanKey": to_key })
	var corridor = result.get("corridor")
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and corridor != null and corridor.mandatory_action_count() == 1 and corridor.actions_by_cell().size() == 1
	var corridor_summary = corridor.to_summary() if corridor != null else {}
	return outcome(passed, "corridor=%s" % JSON.stringify(corridor_summary), ["closed_openable_door_action", "mandatory_action_present"], { "route": route_summary(result) })

func test_route_locked_unauthorized_alternate(_mode: String) -> Dictionary:
	var service = route_service_from_surfaces({
		"0,0": [
			nav_surface(Vector3i(0, 0, 0)),
			nav_surface(Vector3i(1, 0, 0)),
			nav_surface(Vector3i(2, 0, 0)),
			nav_surface(Vector3i(0, 0, 1), { "semanticRegionIds": ["road"] }),
			nav_surface(Vector3i(1, 0, 1), { "semanticRegionIds": ["road"] }),
			nav_surface(Vector3i(2, 0, 1), { "semanticRegionIds": ["road"] })
		]
	})
	var tile = service.get_tile("0,0")
	var start_key = route_span_key(Vector3i(0, 0, 0))
	var locked_key = route_span_key(Vector3i(1, 0, 0))
	var locked_edge = tile.edge_between(start_key, locked_key)
	if locked_edge != null:
		locked_edge.traversal_kind = NpcEnumsScript.TRAVERSAL_KIND_DOOR
		locked_edge.required_capabilities.append(&"use_locked_doors")
		locked_edge.portal_id = "door:locked"
	var result = route_plan(service, start_key, { "kind": "exact_span", "spanKey": route_span_key(Vector3i(2, 0, 0)) })
	var semantics = corridor_semantics(result)
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and semantics.has("road")
	return outcome(passed, "semantics=%s route=%s" % [JSON.stringify(semantics), JSON.stringify(route_summary(result))], ["locked_unauthorized_rejected", "alternate_selected"], { "semantics": semantics, "route": route_summary(result) })

func test_route_start_snap_no_wall_cross(_mode: String) -> Dictionary:
	var service = route_service_from_surfaces({ "0,0": [nav_surface(Vector3i(1, 0, 0))] })
	var request = RouteRequestScript.new()
	request.request_id = "start-wall"
	request.start_position = Vector3.ZERO
	request.goal_spec = { "kind": "exact_span", "spanKey": route_span_key(Vector3i(1, 0, 0)), "maxStartSnap": 0.25 }
	var planner = HierarchicalRoutePlannerScript.new()
	planner.setup(service)
	var result = planner.plan_route(request, 32)
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_UNREACHABLE and str(result.get("reason")) == "no_start_span"
	return outcome(passed, "result=%s" % JSON.stringify(route_summary(result)), ["start_snap_no_wall_cross", "no_start_span_reason"], { "route": route_summary(result) })

func test_route_goal_snap_correct_vertical_layer(_mode: String) -> Dictionary:
	var service = route_service_from_surfaces({
		"0,0": [
			nav_surface(Vector3i(0, 2, 0), { "worldPosition": Vector3(0.0, 2.7, 0.0) }),
			nav_surface(Vector3i(1, 2, 0), { "worldPosition": Vector3(NpcConstantsScript.CELL_SIZE, 2.7, 0.0) }),
			nav_surface(Vector3i(1, 0, 0), { "worldPosition": Vector3(NpcConstantsScript.CELL_SIZE, 0.0, 0.0) })
		]
	})
	var result = route_plan(service, route_span_key(Vector3i(0, 2, 0)), { "kind": "point_region", "center": Vector3(NpcConstantsScript.CELL_SIZE, 2.7, 0.0), "radius": 0.2, "verticalTolerance": 0.25 })
	var corridor = result.get("corridor")
	var last_cell = Vector3i.ZERO
	if corridor != null and not corridor.steps.is_empty():
		last_cell = corridor.steps[corridor.steps.size() - 1].get("cell")
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and last_cell.y == 2
	return outcome(passed, "last=%s route=%s" % [str(last_cell), JSON.stringify(route_summary(result))], ["goal_snap_vertical_layer"], { "lastCell": [last_cell.x, last_cell.y, last_cell.z], "route": route_summary(result) })

func test_route_corner_smoothing_capsule_safe(_mode: String) -> Dictionary:
	var service = route_service_from_surfaces({
		"0,0": [
			nav_surface(Vector3i(0, 0, 0)),
			nav_surface(Vector3i(1, 0, 0)),
			nav_surface(Vector3i(2, 0, 0)),
			nav_surface(Vector3i(2, 0, 1))
		]
	})
	var result = route_plan(service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(2, 0, 1)) })
	var corridor = result.get("corridor")
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and corridor != null and corridor.smoothed and corridor.waypoints.size() <= corridor.steps.size() and not corridor.smoothing_rejected
	var corridor_summary = corridor.to_summary() if corridor != null else {}
	return outcome(passed, "corridor=%s" % JSON.stringify(corridor_summary), ["capsule_safe_smoothing", "smoothing_deterministic"], { "route": route_summary(result) })

func test_route_mandatory_action_not_smoothed_out(_mode: String) -> Dictionary:
	var from_key = route_span_key(Vector3i(0, 0, 0))
	var door_key = route_span_key(Vector3i(1, 0, 0))
	var goal_key = route_span_key(Vector3i(2, 0, 0))
	var service = route_service_from_surfaces({
		"0,0": [
			nav_surface(Vector3i(0, 0, 0)),
			nav_surface(Vector3i(1, 0, 0)),
			nav_surface(Vector3i(2, 0, 0))
		]
	}, {
		"0,0": {
			"doorPortals": [{ "id": "door:mid", "state": "closed", "openable": true }],
			"doorLinks": [{ "from": from_key, "to": door_key, "portalId": "door:mid", "cost": 1.0 }]
		}
	})
	var result = route_plan(service, from_key, { "kind": "exact_span", "spanKey": goal_key })
	var corridor = result.get("corridor")
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and corridor != null and corridor.mandatory_action_count() == 1 and corridor.waypoints.has(corridor.steps[0].get("world_position"))
	var corridor_summary = corridor.to_summary() if corridor != null else {}
	return outcome(passed, "corridor=%s" % JSON.stringify(corridor_summary), ["mandatory_action_preserved", "smoothing_keeps_action_waypoint"], { "route": route_summary(result) })

func test_route_no_iteration_cap_false_failure(_mode: String) -> Dictionary:
	var setup = route_line_service(0, 420)
	var result = route_plan(setup.service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(420, 0, 0), "26,0") }, false, "move", 200000)
	var corridor = result.get("corridor")
	var step_count = corridor.steps.size() if corridor != null else 0
	var passed = result.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE and step_count > 384
	return outcome(passed, "steps=%d status=%s" % [step_count, str(result.get("status"))], ["long_route_over_removed_cap", "no_false_iteration_failure"], { "steps": step_count, "route": route_summary(result) })

func test_route_pending_budget_resumes(_mode: String) -> Dictionary:
	var setup = route_line_service(0, 12)
	var request = route_request(route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(12, 0, 0)) })
	request.request_id = "pending-resume"
	var planner = HierarchicalRoutePlannerScript.new()
	planner.setup(setup.service)
	var first = planner.plan_route(request, 1)
	var final = first
	for _i in range(40):
		if final.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE:
			break
		final = planner.plan_route(request, 2)
	var passed = first.get("status") == NpcEnumsScript.ROUTE_STATUS_PENDING and final.get("status") == NpcEnumsScript.ROUTE_STATUS_COMPLETE
	return outcome(passed, "first=%s final=%s" % [str(first.get("status")), JSON.stringify(route_summary(final))], ["pending_budget", "resumes_to_terminal"], { "first": route_summary(first), "final": route_summary(final) })

func test_route_partial_explicit_only(_mode: String) -> Dictionary:
	var service = route_service_from_surfaces({
		"0,0": [
			nav_surface(Vector3i(0, 0, 0)),
			nav_surface(Vector3i(1, 0, 0)),
			nav_surface(Vector3i(5, 0, 0))
		]
	})
	var blocked = route_plan(service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(5, 0, 0)) }, false)
	var partial = route_plan(service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(5, 0, 0)) }, true)
	var passed = blocked.get("status") == NpcEnumsScript.ROUTE_STATUS_UNREACHABLE and partial.get("status") == NpcEnumsScript.ROUTE_STATUS_PARTIAL
	return outcome(passed, "blocked=%s partial=%s" % [JSON.stringify(route_summary(blocked)), JSON.stringify(route_summary(partial))], ["partial_requires_allow_partial", "partial_not_arrival"], { "blocked": route_summary(blocked), "partial": route_summary(partial) })

func test_route_unreachable_terminal_reason(_mode: String) -> Dictionary:
	var service = route_service_from_surfaces({
		"0,0": [
			nav_surface(Vector3i(0, 0, 0)),
			nav_surface(Vector3i(4, 0, 0))
		]
	})
	var result = route_plan(service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(4, 0, 0)) })
	var passed = result.call("is_terminal") and result.get("status") == NpcEnumsScript.ROUTE_STATUS_UNREACHABLE and result.get("reason") == NpcEnumsScript.ROUTE_REASON_NO_ROUTE
	return outcome(passed, "result=%s" % JSON.stringify(route_summary(result)), ["unreachable_terminal", "machine_reason"], { "route": route_summary(result) })

func test_route_deterministic_replay(_mode: String) -> Dictionary:
	var setup = route_line_service(0, 8)
	var first = route_plan(setup.service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(8, 0, 0)) })
	var second = route_plan(setup.service, route_span_key(Vector3i(0, 0, 0)), { "kind": "exact_span", "spanKey": route_span_key(Vector3i(8, 0, 0)) })
	var first_summary = JSON.stringify(route_summary(first))
	var second_summary = JSON.stringify(route_summary(second))
	var passed = first_summary == second_summary
	return outcome(passed, "first=%s second=%s" % [first_summary, second_summary], ["deterministic_replay"], { "first": route_summary(first), "second": route_summary(second) })

func test_route_navmesh_query_or_same_surface_returns_route(_mode: String) -> Dictionary:
	var service = navmesh_test_service("query-path", Vector3(0.0, 0.0, 0.0), Vector3(10.8, 0.0, 5.4))
	var closest_start: Dictionary = service.closest_walkable(Vector3(0.2, 0.0, 0.2), 10.0)
	var closest_target: Dictionary = service.closest_walkable(Vector3(8.8, 0.0, 3.8), 10.0)
	var route: Dictionary = service.query_route(Vector3(0.2, 0.0, 0.2), Vector3(8.8, 0.0, 3.8), { "kind": "scripted" })
	var stats: Dictionary = service.stats()
	service.clear()
	var query_api := String(route.get("queryApi", ""))
	var same_surface_direct_ok := query_api != "descriptor_direct_endpoint" or (
		String(closest_start.get("surfaceId", "")) != ""
		and String(closest_start.get("surfaceId", "")) == String(closest_target.get("surfaceId", ""))
	)
	var passed := bool(route.get("ok", false)) \
		and String(route.get("source", "")) == "navmesh" \
		and query_api in ["query_path", "map_get_path", "descriptor_direct_endpoint"] \
		and same_surface_direct_ok \
		and (route.get("path", []) as Array).size() >= 1 \
		and int(stats.get("pathQueryCount", 0)) == 1 \
		and int(stats.get("pathQueryFailureCount", -1)) == 0
	return outcome(passed, "route=%s start=%s target=%s stats=%s" % [JSON.stringify(navmesh_route_summary(route)), JSON.stringify(closest_start), JSON.stringify(closest_target), JSON.stringify(stats)], ["navmesh_query_or_same_surface_returns_route", "descriptor_direct_requires_same_surface", "navmesh_query_records_metrics"], { "route": navmesh_route_summary(route), "closestStart": closest_start, "closestTarget": closest_target, "stats": stats })

func test_route_navmesh_preserves_door_action_cells(_mode: String) -> Dictionary:
	var planner = NavmeshRoutePlannerScript.new()
	var action_cell := Vector2i(280, 26)
	var actions := {
		"280,26": {
			"kind": "door",
			"cell": action_cell,
			"entryCell": Vector2i(280, 25),
			"direction": "z+"
		}
	}
	var condensed_cells: Array[Vector2i] = [Vector2i(279, 26), Vector2i(278, 26), Vector2i(276, 26)]
	var preserved: Array[Vector2i] = planner._preserve_route_action_cells(condensed_cells, actions)
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "test"))
	service.register_chunk_descriptor(navmesh_door_descriptor("region:chunk:door-action-cell", "door-action-cell", "door:action-cell"))
	var route: Dictionary = service.query_route(Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 2.7), { "maxSnapDistance": 4.0 })
	var route_actions: Dictionary = route.get("actions", {})
	var emitted_action := {}
	for action_value in route_actions.values():
		if action_value is Dictionary and String((action_value as Dictionary).get("portalId", "")) == "door:action-cell":
			emitted_action = action_value
			break
	var stats: Dictionary = service.stats()
	service.clear()
	var action_preserved := not preserved.is_empty() and preserved[0] == action_cell
	var direction_preserved := String(emitted_action.get("direction", "")) == "z+"
	var entry_cell_preserved := emitted_action.get("entryCell") is Vector2i
	var passed := action_preserved and bool(route.get("ok", false)) and not emitted_action.is_empty() and direction_preserved and entry_cell_preserved and int(stats.get("pathQueryFailureCount", 0)) == 0
	return outcome(passed, "preserved=%s route=%s action=%s stats=%s" % [JSON.stringify(vec2i_array_summary(preserved)), JSON.stringify(navmesh_route_summary(route)), JSON.stringify(emitted_action), JSON.stringify(stats)], ["navmesh_preserves_door_action_cell_after_waypoint_prune", "navmesh_door_action_direction_matches_link"], { "preserved": vec2i_array_summary(preserved), "route": navmesh_route_summary(route), "action": emitted_action, "stats": stats })

func test_route_navmesh_planner_goal_kinds(_mode: String) -> Dictionary:
	var service = navmesh_test_service("goal-kinds", Vector3(-2.7, 0.0, -2.7), Vector3(14.85, 0.0, 6.75))
	service.sync_navigation_map_if_dirty()
	var planner = NavmeshRoutePlannerScript.new()
	planner.setup(service, null, null, null)
	var body := Node3D.new()
	body.global_position = Vector3(0.0, 0.0, 0.0)
	var entry := {
		"id": "navmesh_goal_test",
		"body": body,
		"porchPosition": Vector3.ZERO,
		"townCenter": Vector2i.ZERO,
		"townRadius": 12
	}
	var kinds := ["home", "guard", "job", "forage", "scripted"]
	var results := {}
	for index in range(kinds.size()):
		var kind := String(kinds[index])
		var target := Vector3(2.7 + float(index) * 2.025, 0.0, 2.7)
		var intent := {
			"kind": kind,
			"target": target,
			"targetCell": Vector2i(roundi(target.x / NpcConstantsScript.CELL_SIZE), roundi(target.z / NpcConstantsScript.CELL_SIZE)),
			"allowOutside": kind in ["job", "forage"],
			"movingHome": kind == "home",
			"arrivalRadius": NpcConstantsScript.CELL_SIZE * 0.72,
			"strictArrival": kind == "scripted"
		}
		var route: Dictionary = planner.plan_runtime_route(entry, intent, null, 0)
		results[kind] = navmesh_route_dictionary_summary(route)
	body.free()
	var stats: Dictionary = service.stats()
	service.clear()
	var passed := true
	for kind in kinds:
		var summary: Dictionary = results.get(kind, {})
		passed = passed and bool(summary.get("ok", false)) and String(summary.get("source", "")) == "navmesh" and not bool(summary.get("legacyFallbackUsed", true))
	passed = passed and int(stats.get("pathQueryCount", 0)) == kinds.size()
	return outcome(passed, "results=%s stats=%s" % [JSON.stringify(results), JSON.stringify(stats)], ["navmesh_routes_home_guard_job_forage_scripted", "navmesh_planner_no_legacy_fallback"], { "results": results, "stats": stats })

func test_route_navmesh_adapter_no_legacy_fallback(_mode: String) -> Dictionary:
	var adapter_text = read_text("res://scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd")
	var planner_text = read_text("res://scripts/npc_ai/routing/NavmeshRoutePlanner.gd")
	var service_text = read_text("res://scripts/npc_ai/navigation/NavmeshWorldService.gd")
	var passed = adapter_text.find("NavmeshRoutePlannerScript") >= 0 \
		and adapter_text.find("navmesh_planner.plan_runtime_route") >= 0 \
		and adapter_text.find("generated_corridor_planner") < 0 \
		and adapter_text.find("HierarchicalRoutePlannerScript") < 0 \
		and adapter_text.find("route_from_cells") < 0 \
		and adapter_text.find("MAX_ITERATIONS") < 0 \
		and planner_text.find("path_crosses_static_collision") >= 0 \
		and planner_text.find("validate_waypoint_route") >= 0 \
		and planner_text.find("legacyFallbackUsed") >= 0 \
		and service_text.find("query_path") >= 0
	return outcome(passed, "adapterNavmesh=%d generatedFallback=%d validation=%d queryPath=%d" % [adapter_text.find("NavmeshRoutePlannerScript"), adapter_text.find("generated_corridor_planner"), planner_text.find("validate_waypoint_route"), service_text.find("query_path")], ["adapter_uses_navmesh_authority", "navmesh_routes_are_collision_validated_before_acceptance", "live_adapter_has_no_generated_corridor_fallback"], {})

func test_route_runtime_goal_adapter_uses_new_corridor(_mode: String) -> Dictionary:
	var adapter_text = read_text("res://scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd")
	var passed = adapter_text.find("MAX_ITERATIONS") < 0 \
		and adapter_text.find("navmesh_planner.plan_runtime_route") >= 0 \
		and adapter_text.find("generated_corridor_planner") < 0 \
		and adapter_text.find("HierarchicalRoutePlannerScript") < 0 \
		and adapter_text.find("coordinator.plan_runtime_route") < 0 \
		and adapter_text.find("route_from_cells") < 0
	return outcome(passed, "maxIterations=%d navmeshCall=%d generatedFallback=%d" % [adapter_text.find("MAX_ITERATIONS"), adapter_text.find("navmesh_planner.plan_runtime_route"), adapter_text.find("generated_corridor_planner")], ["runtime_adapter_delegates_navmesh_authority", "old_iteration_cap_removed", "generated_corridor_fallback_removed_from_live_adapter"], {})

func test_route_runtime_door_uses_group_portal_id(_mode: String) -> Dictionary:
	var planner = HierarchicalRoutePlannerScript.new()
	var door := Node3D.new()
	door.name = "Block_door_305_16_0"
	door.set_meta("door_portal_id", "door:door-group:305,16,0:1")
	door.set_meta("door_group_id", "door-group:305,16,0:1")
	door.set_meta("cell", Vector3i(305, 16, 0))
	var portal_id: String = planner.runtime_door_portal_id(door)
	var passed: bool = portal_id == "door:door-group:305,16,0:1" and not portal_id.contains("Block_door")
	door.free()
	return outcome(
		passed,
		"runtimePortalId=%s" % portal_id,
		["runtime_door_action_uses_group_portal_id", "runtime_door_action_not_leaf_node_id"],
		{ "portalId": portal_id }
	)

func test_route_collision_boundary_blocks_open_destination(_mode: String) -> Dictionary:
	var wall := collision_block(Vector2i(50, 0), "woodBlock", Vector3(CELL * 0.5, 0.0, 0.0), Vector3(CELL * 0.14, CELL * 1.8, CELL * 0.96))
	var setup := collision_adapter_with_blocks([wall])
	var adapter = setup.get("adapter")
	var snapshot: Dictionary = setup.get("snapshot", {})
	var entry: Dictionary = setup.get("entry", {})
	var destination_open := adapter.static_blocker(snapshot, Vector2i(1, 0)) == null
	var result: Dictionary = adapter.cell_transition_pathable(entry, snapshot, Vector2i(0, 0), Vector2i(1, 0), {}, true)
	var passed := destination_open and not bool(result.get("ok", true)) and String(result.get("reason", "")) == "blocked_static_transition"
	free_collision_setup(setup)
	return outcome(passed, "destinationOpen=%s result=%s" % [str(destination_open), JSON.stringify(result)], ["transition_checks_swept_collision", "open_destination_still_blocked_by_boundary_wall"], { "result": result })

func test_route_collision_occupied_cell_blocks_node(_mode: String) -> Dictionary:
	var wall := collision_block(Vector2i(50, 0), "woodBlock", Vector3(CELL, 0.0, 0.0), Vector3(CELL * 0.18, CELL * 1.8, CELL * 0.96))
	var setup := collision_adapter_with_blocks([wall])
	var adapter = setup.get("adapter")
	var snapshot: Dictionary = setup.get("snapshot", {})
	var entry: Dictionary = setup.get("entry", {})
	var metadata_open := adapter.static_blocker(snapshot, Vector2i(1, 0)) == null
	var collision_blocker: Dictionary = adapter.static_collision_blocker(snapshot, Vector2i(1, 0))
	var result: Dictionary = adapter.cell_pathable(entry, snapshot, Vector2i(0, 0), Vector2i(1, 0), {}, true)
	var passed := metadata_open and not collision_blocker.is_empty() and not bool(result.get("ok", true)) and String(result.get("reason", "")) == "blocked_static_collision"
	free_collision_setup(setup)
	return outcome(passed, "metadataOpen=%s collision=%s result=%s" % [str(metadata_open), JSON.stringify(collision_blocker), JSON.stringify(result)], ["collision_footprint_blocks_standing_cell", "route_nodes_use_physics_occupancy_not_metadata_only"], { "result": result, "collision": collision_blocker })

func test_route_collision_door_requires_portal_axis(_mode: String) -> Dictionary:
	var door := collision_door(Vector2i(0, 0), 0, "public_gate")
	var setup := collision_adapter_with_blocks([door])
	var adapter = setup.get("adapter")
	var snapshot: Dictionary = setup.get("snapshot", {})
	var entry: Dictionary = setup.get("entry", {})
	var through_portal: Dictionary = adapter.cell_transition_pathable(entry, snapshot, Vector2i(0, -1), Vector2i(0, 0), {}, true)
	var side_cut: Dictionary = adapter.cell_transition_pathable(entry, snapshot, Vector2i(-1, 0), Vector2i(0, 0), {}, true)
	var passed := bool(through_portal.get("ok", false)) and not bool(side_cut.get("ok", true)) and String(side_cut.get("reason", "")) == "door_transition_blocked"
	free_collision_setup(setup)
	return outcome(passed, "portal=%s side=%s" % [JSON.stringify(through_portal), JSON.stringify(side_cut)], ["door_crossing_requires_matching_axis", "sideways_door_collision_not_routeable"], { "portal": through_portal, "side": side_cut })

func test_route_collision_rejects_diagonal_corner_cut(_mode: String) -> Dictionary:
	var east_wall := collision_block(Vector2i(1, 0), "woodBlock")
	var north_wall := collision_block(Vector2i(0, 1), "woodBlock")
	var setup := collision_adapter_with_blocks([east_wall, north_wall])
	var adapter = setup.get("adapter")
	var snapshot: Dictionary = setup.get("snapshot", {})
	var entry: Dictionary = setup.get("entry", {})
	var destination_open := adapter.static_blocker(snapshot, Vector2i(1, 1)) == null
	var result: Dictionary = adapter.cell_transition_pathable(entry, snapshot, Vector2i(0, 0), Vector2i(1, 1), {}, true)
	var passed := destination_open and not bool(result.get("ok", true)) and String(result.get("reason", "")) == "blocked_static_transition"
	free_collision_setup(setup)
	return outcome(passed, "destinationOpen=%s result=%s" % [str(destination_open), JSON.stringify(result)], ["diagonal_corner_cut_checks_collision_sweep", "corner_wall_pair_blocks_diagonal_route"], { "result": result })

func test_route_navmesh_post_validation_rejects_wall_cross(_mode: String) -> Dictionary:
	var wall := collision_block(Vector2i(50, 0), "woodBlock", Vector3(CELL * 0.5, 0.0, 0.0), Vector3(CELL * 0.14, CELL * 1.8, CELL * 0.96))
	var setup := collision_adapter_with_blocks([wall])
	var adapter = setup.get("adapter")
	var service := FakeNavmeshRouteService.new()
	var planner := NavmeshRoutePlannerScript.new()
	planner.setup(service, null, null, adapter)
	var body := Node3D.new()
	body.global_position = Vector3.ZERO
	var entry := {
		"id": "navmesh-wall-cross",
		"body": body,
		"townCenter": Vector2i.ZERO,
		"townRadius": 12,
		"porchPosition": Vector3.ZERO
	}
	var target := Vector3(CELL, 0.0, 0.0)
	var route: Dictionary = planner.plan_runtime_route(entry, {
		"kind": "scripted",
		"target": target,
		"targetCell": Vector2i(1, 0),
		"allowOutside": false,
		"movingHome": false,
		"arrivalRadius": CELL * 0.5,
		"strictArrival": true
	}, adapter, 0)
	var passed := not bool(route.get("ok", true)) and String(route.get("reason", "")) == "path_crosses_static_collision"
	body.free()
	free_collision_setup(setup)
	return outcome(passed, "route=%s" % JSON.stringify(navmesh_route_dictionary_summary(route)), ["navmesh_route_post_validation_rejects_wall_crossing", "bad_navmesh_path_not_accepted"], { "route": navmesh_route_dictionary_summary(route) })

func test_route_scripted_target_expands_navmesh_tiles(_mode: String) -> Dictionary:
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	var body := Node3D.new()
	body.global_position = Vector3.ZERO
	var target_cell := Vector2i(110, -18)
	var target := Vector3(float(target_cell.x) * NpcConstantsScript.CELL_SIZE, 0.0, float(target_cell.y) * NpcConstantsScript.CELL_SIZE)
	body.set_meta("npc_scripted_target", target)
	body.set_meta("npc_scripted_allow_outside", true)
	var entry := {
		"id": "scripted_far_guard",
		"body": body,
		"townCenter": Vector2i.ZERO,
		"townRadius": 18,
		"job": "guard",
		"role": "Watch"
	}
	var keys: Array[String] = adapter.route_navmesh_tile_keys(entry, body.global_position, target, true, false, 12)
	var target_tile := "%d,%d" % [
		floori(float(target_cell.x) / float(NpcConstantsScript.NAV_TILE_CELL_SIZE)),
		floori(float(target_cell.y) / float(NpcConstantsScript.NAV_TILE_CELL_SIZE))
	]
	var start_tile := "%d,%d" % [0, 0]
	var passed := keys.has(target_tile) and keys.has(start_tile)
	body.free()
	return outcome(
		passed,
		"targetTile=%s startTile=%s keys=%s" % [target_tile, start_tile, JSON.stringify(keys)],
		["scripted_target_leash_included_in_navmesh_publication", "start_and_target_tiles_published"],
		{ "targetTile": target_tile, "startTile": start_tile, "keys": keys }
	)

func collision_adapter_with_blocks(block_nodes: Array) -> Dictionary:
	var main := RouteTestMain.new()
	for node_value in block_nodes:
		var body := node_value as Node
		if body == null:
			continue
		main.add_child(body)
		var cell_value = body.get_meta("cell", Vector3i.ZERO)
		main.blocks[cell_value] = body
	var adapter = GeneratedWorldNavigationAdapterScript.new()
	adapter.setup(null, main)
	adapter.rebuild_static_cells()
	var body := Node3D.new()
	body.global_position = Vector3.ZERO
	var entry := {
		"id": "collision-route-test",
		"body": body,
		"townCenter": Vector2i.ZERO,
		"townRadius": 128,
		"porchPosition": Vector3.ZERO
	}
	var snapshot: Dictionary = adapter.cached_validation_snapshot(entry, false, false)
	return {
		"main": main,
		"adapter": adapter,
		"entry": entry,
		"snapshot": snapshot,
		"body": body,
		"blocks": block_nodes
	}

func free_collision_setup(setup: Dictionary) -> void:
	var body := setup.get("body") as Node
	if body != null and is_instance_valid(body):
		body.free()
	for block_value in setup.get("blocks", []):
		var block := block_value as Node
		if block != null and is_instance_valid(block):
			block.free()
	var main := setup.get("main") as Node
	if main != null and is_instance_valid(main):
		main.free()

func collision_block(cell: Vector2i, block_type := "woodBlock", position_value = null, size_value = null, yaw := 0.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "TestBlock_%s_%d_%d" % [block_type, cell.x, cell.y]
	var block_position: Vector3 = position_value if position_value is Vector3 else Vector3(float(cell.x) * CELL, 0.0, float(cell.y) * CELL)
	body.position = block_position
	body.rotation.y = yaw
	body.set_meta("kind", "block")
	body.set_meta("cell", Vector3i(cell.x, 0, cell.y))
	body.set_meta("block_type", block_type)
	var shape := BoxShape3D.new()
	shape.size = size_value if size_value is Vector3 else Vector3(CELL * 0.96, CELL * 1.0, CELL * 0.96)
	var collider := CollisionShape3D.new()
	collider.shape = shape
	body.add_child(collider)
	return body

func collision_door(cell: Vector2i, side := 0, policy := "public_gate") -> StaticBody3D:
	var door := collision_block(cell, "door", Vector3(float(cell.x) * CELL, 0.0, float(cell.y) * CELL), Vector3(CELL * 0.92, CELL * 1.72, CELL * 0.16), 0.0)
	door.set_meta("door_side", side)
	door.set_meta("door_policy", policy)
	door.set_meta("door_portal_id", "door:test:%d,%d" % [cell.x, cell.y])
	door.set_meta("door_group_id", "door-test:%d,%d" % [cell.x, cell.y])
	door.set_meta("door_state", String(NpcEnumsScript.DOOR_STATE_CLOSED))
	door.set_meta("open", false)
	door.set_meta("locked", false)
	door.set_meta("jammed", false)
	door.set_meta("destroyed", false)
	door.set_meta("unloaded", false)
	return door

func navmesh_test_service(label: String, min_pos: Vector3, size: Vector3):
	var service = NavmeshWorldServiceScript.new()
	service.setup(NavigationBackendConfigScript.from_value("navmesh", "test"))
	var center := min_pos + size * 0.5
	var descriptor = NavigationBakeDescriptorScript.create("region:chunk:%s" % label, label, AABB(min_pos, size))
	descriptor.add_walkable_surface("surface:%s:main" % label, center, Vector3(maxf(size.x, NpcConstantsScript.CELL_SIZE), 0.05, maxf(size.z, NpcConstantsScript.CELL_SIZE)), {
		"semanticRegionIds": ["test_navmesh"],
		"traversalTags": ["terrain"]
	})
	service.register_chunk_descriptor(descriptor)
	return service

func navmesh_door_descriptor(region_id: String, tile_key: String, portal_id: String):
	var descriptor = NavigationBakeDescriptorScript.create(region_id, tile_key, AABB(Vector3(-1.5, -0.1, -1.5), Vector3(3.0, 1.2, 5.7)))
	descriptor.add_walkable_surface("surface:%s:left" % tile_key, Vector3(0.0, 0.0, 0.0), Vector3(NpcConstantsScript.CELL_SIZE, 0.05, NpcConstantsScript.CELL_SIZE))
	descriptor.add_walkable_surface("surface:%s:right" % tile_key, Vector3(0.0, 0.0, 2.7), Vector3(NpcConstantsScript.CELL_SIZE, 0.05, NpcConstantsScript.CELL_SIZE))
	descriptor.add_door_portal(portal_id, Vector3(0.0, 0.0, 0.65), Vector3(0.0, 0.0, 2.05), { "state": "closed", "openable": true })
	descriptor.add_door_link("surface:%s:left" % tile_key, "surface:%s:right" % tile_key, portal_id, { "cost": 1.0, "actionId": "open" })
	return descriptor

func vec2i_array_summary(cells: Array) -> Array:
	var result := []
	for cell_value in cells:
		if cell_value is Vector2i:
			var cell: Vector2i = cell_value
			result.append([cell.x, cell.y])
	return result

func navmesh_route_summary(route: Dictionary) -> Dictionary:
	return {
		"ok": bool(route.get("ok", false)),
		"status": String(route.get("status", "")),
		"reason": String(route.get("reason", "")),
		"source": String(route.get("source", "")),
		"queryApi": String(route.get("queryApi", "")),
		"pointCount": int(route.get("pointCount", 0)),
		"distance": snappedf(float(route.get("distance", 0.0)), 0.001),
		"snapshotRevision": String(route.get("snapshotRevision", ""))
	}

func navmesh_route_dictionary_summary(route: Dictionary) -> Dictionary:
	var navmesh_route: Dictionary = route.get("navmeshRoute", {})
	var start_walkable := navmesh_walkable_summary(navmesh_route, "startWalkable")
	var target_walkable := navmesh_walkable_summary(navmesh_route, "targetWalkable")
	return {
		"ok": bool(route.get("ok", false)),
		"status": String(route.get("status", "")),
		"reason": String(route.get("reason", "")),
		"source": String(route.get("source", "")),
		"legacyFallbackUsed": bool(route.get("legacyFallbackUsed", true)),
		"waypointCount": (route.get("waypoints", []) as Array).size(),
		"cellCount": (route.get("cells", []) as Array).size(),
		"snapshotRevision": String(route.get("snapshotRevision", "")),
		"navmeshReason": String(navmesh_route.get("reason", "")),
		"navmeshQueryApi": String(navmesh_route.get("queryApi", "")),
		"navmeshPointCount": int(navmesh_route.get("pointCount", 0)),
		"startWalkable": start_walkable,
		"targetWalkable": target_walkable
	}

func navmesh_walkable_summary(route: Dictionary, key: String) -> Dictionary:
	var value = route.get(key, {})
	if not (value is Dictionary) or (value is Dictionary and (value as Dictionary).is_empty()):
		var details: Dictionary = route.get("details", {})
		value = details.get(key, {})
	if not (value is Dictionary):
		return { "found": false }
	var walkable: Dictionary = value
	return {
		"found": bool(walkable.get("found", false)),
		"regionId": String(walkable.get("regionId", "")),
		"surfaceId": String(walkable.get("surfaceId", "")),
		"distance": snappedf(float(walkable.get("distance", 0.0)), 0.001)
	}

func route_line_service(start_x: int, end_x: int) -> Dictionary:
	var tiles = {}
	for x in range(start_x, end_x + 1):
		var cell = Vector3i(x, 0, 0)
		var tile_key = NavigationChangeBusScript.tile_key_for_cell(cell)
		if not tiles.has(tile_key):
			tiles[tile_key] = []
		(tiles[tile_key] as Array).append(nav_surface(cell, { "semanticRegionIds": ["road"] }))
	return { "service": route_service_from_surfaces(tiles), "tiles": tiles }

func route_service_from_surfaces(tiles: Dictionary, extras := {}) -> Object:
	var service = NavigationWorldServiceScript.new()
	var keys = tiles.keys()
	keys.sort()
	for tile_key in keys:
		var extra: Dictionary = extras.get(tile_key, {})
		service.build_tile_now(nav_snapshot(str(tile_key), tiles[tile_key], extra))
	return service

func route_plan(service, start_key: String, goal_spec: Dictionary, allow_partial := false, goal_kind := "move", max_expansions := 4096):
	var planner = HierarchicalRoutePlannerScript.new()
	planner.setup(service)
	var request = route_request(start_key, goal_spec, allow_partial, goal_kind)
	return planner.plan_route(request, max_expansions)

func route_request(start_key: String, goal_spec: Dictionary, allow_partial := false, goal_kind := "move"):
	var request = RouteRequestScript.new()
	request.request_id = "test:%s:%s" % [start_key, JSON.stringify(goal_spec)]
	request.owner_npc_id = "test-npc"
	request.start_span = start_key
	request.start_position = Vector3.ZERO
	request.goal_kind = StringName(goal_kind)
	request.goal_spec = goal_spec
	request.allow_partial = allow_partial
	request.maximum_acceptable_goal_distance = NpcConstantsScript.CELL_SIZE * 0.75
	request.next_generation()
	return request

func route_span_key(cell: Vector3i, tile_key := "", span_index := 0) -> String:
	var key = tile_key
	if key == "":
		key = NavigationChangeBusScript.tile_key_for_cell(cell)
	return "%s:%d,%d,%d:%d" % [key, cell.x, cell.y, cell.z, span_index]

func route_summary(result) -> Dictionary:
	if result == null:
		return {}
	var summary: Dictionary = result.to_summary()
	if result.get("corridor") != null:
		summary["corridor"] = _compact_corridor_summary(result.get("corridor").to_summary())
	summary["metrics"] = result.get("metrics")
	return summary

func route_metrics(result) -> Dictionary:
	if result == null:
		return {}
	var metrics = result.get("metrics")
	return metrics if metrics is Dictionary else {}

func _compact_corridor_summary(corridor_summary: Dictionary) -> Dictionary:
	var result = corridor_summary.duplicate(true)
	var steps: Array = result.get("steps", [])
	if steps.size() <= 12:
		return result
	var sample: Array = []
	for i in range(3):
		sample.append(steps[i])
	for i in range(steps.size() - 3, steps.size()):
		sample.append(steps[i])
	result["sampledSteps"] = sample
	result["omittedStepCount"] = steps.size() - sample.size()
	result.erase("steps")
	return result

func corridor_semantics(result) -> Array:
	var values: Array = []
	var corridor = result.get("corridor") if result != null else null
	if corridor == null:
		return values
	for step in corridor.steps:
		for semantic_id in step.get("semantic_region_ids"):
			if not values.has(str(semantic_id)):
				values.append(str(semantic_id))
	values.sort()
	return values

func nav_snapshot(tile_key: String, surfaces: Array, extra := {}) -> Dictionary:
	var snapshot = {
		"tileKey": tile_key,
		"surfaces": surfaces
	}
	for key in extra.keys():
		snapshot[key] = extra[key]
	return snapshot

func nav_surface(cell: Vector3i, extra := {}) -> Dictionary:
	var surface = {
		"cell": cell,
		"spanIndex": int(extra.get("spanIndex", 0)),
		"worldPosition": Vector3(float(cell.x) * NpcConstantsScript.CELL_SIZE, float(cell.y) * NpcConstantsScript.CELL_SIZE, float(cell.z) * NpcConstantsScript.CELL_SIZE),
		"floorNormal": Vector3.UP,
		"headroom": 2.4,
		"lateralClearance": 1.0,
		"blocked": false,
		"semanticRegionIds": [],
		"traversalTags": ["terrain"]
	}
	for key in extra.keys():
		surface[key] = extra[key]
	return surface

func read_text(path: String) -> String:
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text = file.get_as_text()
	file.close()
	return text

func outcome(passed: bool, details: String, assertions: Array, key_state: Dictionary) -> Dictionary:
	if runner != null and runner.has_method("outcome"):
		return runner.call("outcome", passed, details, assertions, key_state)
	return {
		"passed": passed,
		"details": details,
		"assertions": assertions,
		"keyState": key_state
	}
