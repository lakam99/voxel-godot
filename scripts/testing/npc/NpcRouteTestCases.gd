extends RefCounted

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const TraversalProfileScript := preload("res://scripts/npc_ai/contracts/TraversalProfile.gd")
const RouteRequestScript := preload("res://scripts/npc_ai/contracts/RouteRequest.gd")
const NavigationChangeBusScript := preload("res://scripts/npc_ai/navigation/NavigationChangeBus.gd")
const NavigationWorldServiceScript := preload("res://scripts/npc_ai/navigation/NavigationWorldService.gd")
const HierarchicalRoutePlannerScript := preload("res://scripts/npc_ai/routing/HierarchicalRoutePlanner.gd")

var runner = null

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

func test_route_runtime_goal_adapter_uses_new_corridor(_mode: String) -> Dictionary:
	var adapter_text = read_text("res://scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd")
	var passed = adapter_text.find("HierarchicalRoutePlanner") >= 0 and adapter_text.find("MAX_ITERATIONS") < 0 and adapter_text.find("plan_runtime_route") >= 0 and adapter_text.find("route_from_cells") < 0
	return outcome(passed, "adapterPlanner=%d maxIterations=%d" % [adapter_text.find("HierarchicalRoutePlanner"), adapter_text.find("MAX_ITERATIONS")], ["runtime_adapter_delegates_new_corridor", "old_iteration_cap_removed"], {})

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
