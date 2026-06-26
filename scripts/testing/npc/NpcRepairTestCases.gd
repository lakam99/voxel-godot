extends RefCounted

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NavigationChangeBusScript := preload("res://scripts/npc_ai/navigation/NavigationChangeBus.gd")
const HierarchicalRoutePlannerScript := preload("res://scripts/npc_ai/routing/HierarchicalRoutePlanner.gd")
const IncrementalRouteRepairScript := preload("res://scripts/npc_ai/routing/IncrementalRouteRepair.gd")
const RouteCasesScript := preload("res://scripts/testing/npc/NpcRouteTestCases.gd")

const ROUTE_ID := "repair:test"

var runner = null
var route_helper = null

func setup(owner) -> void:
	runner = owner
	route_helper = RouteCasesScript.new()
	route_helper.setup(owner)

func cases() -> Array[Dictionary]:
	var ids = [
		["npc_repair_unrelated_change_no_replan", "test_repair_unrelated_change_no_replan"],
		["npc_repair_block_added_on_corridor", "test_repair_block_added_on_corridor"],
		["npc_repair_block_removed_shortens_route", "test_repair_block_removed_shortens_route"],
		["npc_repair_terrain_edit_on_corridor", "test_repair_terrain_edit_on_corridor"],
		["npc_repair_door_locked_alternate", "test_repair_door_locked_alternate"],
		["npc_repair_door_unlocked_resumes", "test_repair_door_unlocked_resumes"],
		["npc_repair_resource_removed_replan_action", "test_repair_resource_removed_replan_action"],
		["npc_repair_chunk_unload_suspends_or_alternates", "test_repair_chunk_unload_suspends_or_alternates"],
		["npc_repair_stale_generation_rejected", "test_repair_stale_generation_rejected"],
		["npc_repair_matches_fresh_astar_cost", "test_repair_matches_fresh_astar_cost"],
		["npc_repair_reuses_search_state", "test_repair_reuses_search_state"],
		["npc_repair_bounded_no_loop", "test_repair_bounded_no_loop"],
		["npc_repair_physical_stop_before_new_blocker", "test_repair_physical_stop_before_new_blocker"],
		["npc_repair_day_worker_dynamic_block", "test_repair_day_worker_dynamic_block"],
		["npc_repair_night_guard_dynamic_block", "test_repair_night_guard_dynamic_block"],
		["npc_repair_night_civilian_home_dynamic_block", "test_repair_night_civilian_home_dynamic_block"]
	]
	var result: Array[Dictionary] = []
	for spec in ids:
		result.append({
			"id": String(spec[0]),
			"suite": "repair",
			"timeModes": ["day", "night"],
			"callable": Callable(self, String(spec[1]))
		})
	return result

func test_repair_unrelated_change_no_replan(_mode: String) -> Dictionary:
	var setup := repair_setup()
	var event := event_for(Vector3i(40, 0, 40), [NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED], ["block:40,0,40:stone"])
	var response: Dictionary = setup.repair.repair_after_event(ROUTE_ID, event)
	var routes: Array[String] = setup.repair.routes_for_event(event)
	var passed: bool = response.get("status") == NpcEnumsScript.REPAIR_STATUS_UNCHANGED and routes.is_empty() and int(response.get("metrics", {}).get("fullReplans", -1)) == 0
	return outcome(passed, "response=%s routes=%s" % [JSON.stringify(response_summary(response)), JSON.stringify(routes)], ["unrelated_no_route_hit", "unchanged_status", "no_full_replan"], { "response": response_summary(response), "routes": routes })

func test_repair_block_added_on_corridor(_mode: String) -> Dictionary:
	var setup := repair_setup()
	var response: Dictionary = block_mid(setup, true)
	var path: Array = repaired_path(response)
	var passed: bool = response.get("status") == NpcEnumsScript.REPAIR_STATUS_REPAIRED and not path.has(setup.midKey) and bool(response.get("metrics", {}).get("safeStopRequired", false))
	return outcome(passed, "path=%s response=%s" % [JSON.stringify(path), JSON.stringify(response_summary(response))], ["block_on_corridor_repairs", "blocked_mid_avoided", "safe_stop_required"], { "path": path, "response": response_summary(response) })

func test_repair_block_removed_shortens_route(_mode: String) -> Dictionary:
	var setup := repair_setup()
	var blocked: Dictionary = block_mid(setup, true)
	var unblocked: Dictionary = block_mid(setup, false)
	var blocked_cost := route_cost(blocked)
	var unblocked_cost := route_cost(unblocked)
	var passed: bool = blocked.get("status") == NpcEnumsScript.REPAIR_STATUS_REPAIRED and unblocked.get("status") == NpcEnumsScript.REPAIR_STATUS_REPAIRED and unblocked_cost < blocked_cost - 0.001 and repaired_path(unblocked).has(setup.midKey)
	return outcome(passed, "blocked=%.3f unblocked=%.3f path=%s" % [blocked_cost, unblocked_cost, JSON.stringify(repaired_path(unblocked))], ["block_remove_shortens", "direct_segment_restored"], { "blocked": response_summary(blocked), "unblocked": response_summary(unblocked) })

func test_repair_terrain_edit_on_corridor(_mode: String) -> Dictionary:
	var setup := repair_setup()
	var event := event_for(Vector3i(1, 0, 0), [NpcEnumsScript.CHANGE_KIND_TERRAIN_EDIT], ["terrain:1,0"])
	var changes := cost_changes([
		[setup.startKey, setup.midKey, 20.0],
		[setup.midKey, setup.startKey, 20.0],
		[setup.midKey, setup.goalKey, 20.0],
		[setup.goalKey, setup.midKey, 20.0]
	], int(setup.request.get("cancellation_generation")))
	var response: Dictionary = setup.repair.repair_after_event(ROUTE_ID, event, changes)
	var passed: bool = response.get("status") == NpcEnumsScript.REPAIR_STATUS_REPAIRED and not repaired_path(response).has(setup.midKey)
	return outcome(passed, "path=%s response=%s" % [JSON.stringify(repaired_path(response)), JSON.stringify(response_summary(response))], ["terrain_cost_repaired", "expensive_corridor_avoided"], { "response": response_summary(response), "path": repaired_path(response) })

func test_repair_door_locked_alternate(_mode: String) -> Dictionary:
	var setup := repair_setup({ "door": true })
	var event := event_for(Vector3i(1, 0, 0), ["door_locked"], ["door:mid"])
	var response: Dictionary = setup.repair.repair_after_event(ROUTE_ID, event)
	var path: Array = repaired_path(response)
	var passed: bool = response.get("classification") == NpcEnumsScript.REPAIR_CLASS_ABSTRACT_PORTAL and response.get("status") == NpcEnumsScript.REPAIR_STATUS_REPAIRED and not path.has(setup.midKey)
	return outcome(passed, "path=%s response=%s" % [JSON.stringify(path), JSON.stringify(response_summary(response))], ["door_lock_portal_classified", "alternate_selected"], { "response": response_summary(response), "path": path })

func test_repair_door_unlocked_resumes(_mode: String) -> Dictionary:
	var setup := repair_setup({ "door": true, "detour": false })
	var lock_event := event_for(Vector3i(1, 0, 0), ["door_locked"], ["door:mid"])
	var locked: Dictionary = setup.repair.repair_after_event(ROUTE_ID, lock_event)
	var unlock_event := event_for(Vector3i(1, 0, 0), ["door_unlocked"], ["door:mid"], 2)
	var unlocked: Dictionary = setup.repair.repair_after_event(ROUTE_ID, unlock_event)
	var passed: bool = locked.get("status") == NpcEnumsScript.REPAIR_STATUS_WAITING and unlocked.get("status") == NpcEnumsScript.REPAIR_STATUS_REPAIRED and repaired_path(unlocked).has(setup.midKey)
	return outcome(passed, "locked=%s unlocked=%s" % [JSON.stringify(response_summary(locked)), JSON.stringify(response_summary(unlocked))], ["locked_waits_without_alternate", "unlock_resumes_direct"], { "locked": response_summary(locked), "unlocked": response_summary(unlocked), "path": repaired_path(unlocked) })

func test_repair_resource_removed_replan_action(_mode: String) -> Dictionary:
	var setup := repair_setup({ "targetObjectId": "prop:berry:1" })
	var event := event_for(Vector3i(2, 0, 0), [NpcEnumsScript.CHANGE_KIND_PROP_REMOVED], ["prop:berry:1"])
	var routes: Array[String] = setup.repair.routes_for_event(event)
	var response: Dictionary = setup.repair.repair_after_event(ROUTE_ID, event)
	var passed: bool = routes.has(ROUTE_ID) and response.get("status") == NpcEnumsScript.REPAIR_STATUS_ACTION_REVISION and response.get("classification") == NpcEnumsScript.REPAIR_CLASS_ACTION_PREMISE and response.get("reason") == NpcEnumsScript.ROUTE_REASON_TARGET_GONE
	return outcome(passed, "routes=%s response=%s" % [JSON.stringify(routes), JSON.stringify(response_summary(response))], ["object_dependency_indexed", "resource_removal_action_revision", "target_gone_reason"], { "routes": routes, "response": response_summary(response) })

func test_repair_chunk_unload_suspends_or_alternates(_mode: String) -> Dictionary:
	var setup := repair_setup()
	var event := event_for(Vector3i(1, 0, 0), [NpcEnumsScript.CHANGE_KIND_CHUNK_UNLOADED], ["chunk:0,0"])
	var response: Dictionary = setup.repair.repair_after_event(ROUTE_ID, event)
	var passed: bool = response.get("status") == NpcEnumsScript.REPAIR_STATUS_WAITING and response.get("classification") == NpcEnumsScript.REPAIR_CLASS_TOPOLOGY_UNAVAILABLE and bool(response.get("metrics", {}).get("safeStopRequired", false))
	return outcome(passed, "response=%s" % JSON.stringify(response_summary(response)), ["chunk_unload_waits", "topology_unavailable", "safe_stop_required"], { "response": response_summary(response) })

func test_repair_stale_generation_rejected(_mode: String) -> Dictionary:
	var setup := repair_setup()
	var event := event_for(Vector3i(1, 0, 0), [NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED], ["block:1,0,0:stone"])
	var response: Dictionary = setup.repair.repair_after_event(ROUTE_ID, event, { "generation": int(setup.request.get("cancellation_generation")) + 1 })
	var passed: bool = response.get("status") == NpcEnumsScript.REPAIR_STATUS_FAILED and response.get("reason") == NpcEnumsScript.ROUTE_REASON_STALE_GENERATION and bool(response.get("metrics", {}).get("staleGenerationRejected", false))
	return outcome(passed, "response=%s" % JSON.stringify(response_summary(response)), ["stale_generation_rejected", "no_stale_route_apply"], { "response": response_summary(response) })

func test_repair_matches_fresh_astar_cost(_mode: String) -> Dictionary:
	var setup := repair_setup()
	var response: Dictionary = block_mid(setup, true)
	var oracle: Dictionary = setup.repair.fresh_oracle(ROUTE_ID)
	var passed: bool = response.get("status") == NpcEnumsScript.REPAIR_STATUS_REPAIRED and approx(route_cost(response), float(oracle.get("cost", 999999.0)))
	return outcome(passed, "repair=%.3f oracle=%.3f" % [route_cost(response), float(oracle.get("cost", -1.0))], ["repair_matches_fresh_astar_cost", "oracle_test_only"], { "response": response_summary(response), "oracle": oracle })

func test_repair_reuses_search_state(_mode: String) -> Dictionary:
	var setup := repair_setup()
	var before: Dictionary = setup.repair.state_summary(ROUTE_ID)
	var response: Dictionary = block_mid(setup, true)
	var metrics: Dictionary = response.get("metrics", {})
	var passed: bool = response.get("status") == NpcEnumsScript.REPAIR_STATUS_REPAIRED and bool(metrics.get("reusedState", false)) and int(metrics.get("fullReplans", -1)) == 0 and int(metrics.get("gCount", 0)) >= int(before.get("gCount", 0)) and int(metrics.get("rhsCount", 0)) >= int(before.get("rhsCount", 0))
	return outcome(passed, "before=%s metrics=%s" % [JSON.stringify(before), JSON.stringify(metrics)], ["g_rhs_state_reused", "no_full_replan_counter", "repair_metrics_visible"], { "before": before, "response": response_summary(response) })

func test_repair_bounded_no_loop(_mode: String) -> Dictionary:
	var setup := repair_setup({ "detour": false })
	var event := event_for(Vector3i(1, 0, 0), [NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED], ["block:1,0,0:stone"])
	var changes := { "edgeChanges": setup.repair.edge_changes_for_node(ROUTE_ID, setup.midKey, true), "generation": int(setup.request.get("cancellation_generation")) }
	var final_response := {}
	for _i in range(3):
		final_response = setup.repair.repair_after_event(ROUTE_ID, event, changes)
	var passed: bool = final_response.get("status") == NpcEnumsScript.REPAIR_STATUS_FAILED and final_response.get("reason") == NpcEnumsScript.ROUTE_REASON_REPAIR_LOOP_BOUND and int(final_response.get("metrics", {}).get("failureCount", 0)) == 3
	return outcome(passed, "response=%s" % JSON.stringify(response_summary(final_response)), ["bounded_repair_failures", "terminal_loop_reason"], { "response": response_summary(final_response) })

func test_repair_physical_stop_before_new_blocker(_mode: String) -> Dictionary:
	var setup := repair_setup()
	var response: Dictionary = block_mid(setup, true)
	var passed: bool = bool(response.get("metrics", {}).get("safeStopRequired", false)) and response.get("status") == NpcEnumsScript.REPAIR_STATUS_REPAIRED
	return outcome(passed, "response=%s" % JSON.stringify(response_summary(response)), ["stop_before_blocker", "safe_stop_metric"], { "response": response_summary(response) })

func test_repair_day_worker_dynamic_block(_mode: String) -> Dictionary:
	return dynamic_goal_block_case("work")

func test_repair_night_guard_dynamic_block(_mode: String) -> Dictionary:
	return dynamic_goal_block_case("guard")

func test_repair_night_civilian_home_dynamic_block(_mode: String) -> Dictionary:
	return dynamic_goal_block_case("home")

func dynamic_goal_block_case(goal_kind: String) -> Dictionary:
	var setup := repair_setup({ "goalKind": goal_kind })
	var response: Dictionary = block_mid(setup, true)
	var route_result = response.get("routeResult")
	var contract := String(route_result.get("arrival_contract")) if route_result != null else ""
	var passed: bool = response.get("status") == NpcEnumsScript.REPAIR_STATUS_REPAIRED and contract == goal_kind and not repaired_path(response).has(setup.midKey)
	return outcome(passed, "kind=%s path=%s response=%s" % [goal_kind, JSON.stringify(repaired_path(response)), JSON.stringify(response_summary(response))], ["dynamic_block_repairs", "arrival_contract_preserved"], { "goalKind": goal_kind, "response": response_summary(response), "path": repaired_path(response) })

func repair_setup(options := {}) -> Dictionary:
	var detour := bool(options.get("detour", true))
	var goal_kind := String(options.get("goalKind", "move"))
	var start_key: String = route_helper.route_span_key(Vector3i(0, 0, 0))
	var mid_key: String = route_helper.route_span_key(Vector3i(1, 0, 0))
	var goal_key: String = route_helper.route_span_key(Vector3i(2, 0, 0))
	var surfaces: Array = [
		route_helper.nav_surface(Vector3i(0, 0, 0), { "semanticRegionIds": ["road"] }),
		route_helper.nav_surface(Vector3i(1, 0, 0), { "semanticRegionIds": ["road"] }),
		route_helper.nav_surface(Vector3i(2, 0, 0), { "semanticRegionIds": ["road"] })
	]
	if detour:
		surfaces.append(route_helper.nav_surface(Vector3i(0, 0, 1), { "semanticRegionIds": ["terrain"] }))
		surfaces.append(route_helper.nav_surface(Vector3i(1, 0, 1), { "semanticRegionIds": ["terrain"] }))
		surfaces.append(route_helper.nav_surface(Vector3i(2, 0, 1), { "semanticRegionIds": ["terrain"] }))
	var service = route_helper.route_service_from_surfaces({ "0,0": surfaces })
	if bool(options.get("door", false)):
		mark_door(service, start_key, mid_key, "door:mid", 0.5)
		mark_door(service, mid_key, start_key, "door:mid", 0.5)
	var planner = HierarchicalRoutePlannerScript.new()
	planner.setup(service)
	var goal_spec := { "kind": "exact_span", "spanKey": goal_key }
	if String(options.get("targetObjectId", "")) != "":
		goal_spec["objectId"] = String(options.get("targetObjectId", ""))
	var request = route_helper.route_request(start_key, goal_spec, false, goal_kind)
	var initial = planner.plan_route(request, 4096)
	var repair = IncrementalRouteRepairScript.new()
	repair.setup(planner)
	repair.register_route(ROUTE_ID, initial.get("repair_graph"), String(initial.get("repair_start_key")), initial.get("repair_goal_keys"), request, initial.get("corridor"))
	return {
		"service": service,
		"planner": planner,
		"repair": repair,
		"request": request,
		"initial": initial,
		"startKey": start_key,
		"midKey": mid_key,
		"goalKey": goal_key
	}

func block_mid(setup: Dictionary, blocked: bool) -> Dictionary:
	var kind: StringName = NpcEnumsScript.CHANGE_KIND_BLOCK_CREATED if blocked else NpcEnumsScript.CHANGE_KIND_BLOCK_REMOVED
	var event := event_for(Vector3i(1, 0, 0), [kind], ["block:1,0,0:stone"], 1 if blocked else 2)
	var changes := {
		"edgeChanges": setup.repair.edge_changes_for_node(ROUTE_ID, setup.midKey, blocked),
		"generation": int(setup.request.get("cancellation_generation"))
	}
	return setup.repair.repair_after_event(ROUTE_ID, event, changes)

func mark_door(service, from_key: String, to_key: String, portal_id: String, cost: float) -> void:
	var tile = service.get_tile("0,0")
	if tile == null:
		return
	var edge = tile.edge_between(from_key, to_key)
	if edge == null:
		return
	edge.traversal_kind = NpcEnumsScript.TRAVERSAL_KIND_DOOR
	edge.portal_id = portal_id
	edge.action_id = "open"
	edge.cost = cost

func event_for(cell: Vector3i, kinds: Array, object_ids: Array, revision := 1) -> Dictionary:
	var normalized_kinds: Array = []
	for kind in kinds:
		normalized_kinds.append(String(kind))
	var normalized_objects: Array = []
	for object_id in object_ids:
		normalized_objects.append(String(object_id))
	return {
		"tileKey": NavigationChangeBusScript.tile_key_for_cell(cell),
		"revision": revision,
		"changeKinds": normalized_kinds,
		"objectIds": normalized_objects,
		"bounds": AABB(Vector3(float(cell.x), float(cell.y), float(cell.z)), Vector3.ONE)
	}

func cost_changes(specs: Array, generation: int) -> Dictionary:
	var changes: Array = []
	for spec in specs:
		changes.append({ "from": String(spec[0]), "to": String(spec[1]), "cost": float(spec[2]) })
	return { "edgeChanges": changes, "generation": generation }

func repaired_path(response: Dictionary) -> Array:
	var route_result = response.get("routeResult")
	if route_result == null:
		return []
	var metrics = route_result.get("metrics")
	if metrics is Dictionary:
		return (metrics as Dictionary).get("path", [])
	return []

func route_cost(response: Dictionary) -> float:
	var route_result = response.get("routeResult")
	return float(route_result.get("cost")) if route_result != null else 999999.0

func response_summary(response: Dictionary) -> Dictionary:
	var result := response.duplicate(true)
	var route_result = result.get("routeResult")
	if route_result != null:
		result["routeResult"] = route_result.to_summary()
		result["path"] = repaired_path(response)
	return result

func approx(a: float, b: float) -> bool:
	return absf(a - b) <= 0.001

func outcome(passed: bool, details: String, assertions: Array, key_state: Dictionary) -> Dictionary:
	if runner != null and runner.has_method("outcome"):
		return runner.call("outcome", passed, details, assertions, key_state)
	return {
		"passed": passed,
		"details": details,
		"assertions": assertions,
		"keyState": key_state
	}
