extends RefCounted
class_name NpcSemanticGoalPlanner

const HomeInteriorServiceScript := preload("res://scripts/npc_ai/behavior/HomeInteriorService.gd")
const NpcRouteStateStoreScript := preload("res://scripts/npc_ai/routing/NpcRouteStateStore.gd")
const ItemCatalogScript := preload("res://scripts/ItemCatalog.gd")

const CELL := 1.35
const MAX_ROUTE_SCORED_CANDIDATES := 16
const MAX_HOME_INTERIOR_GOAL_CELLS := 64
const RESOURCE_SCAN_NODE_LIMIT := 1200
const RESOURCE_SCAN_CANDIDATE_LIMIT := 16
const UTILITY_ANCHOR_QUERY_LIMIT := 64
const UTILITY_ANCHOR_LIMIT := 8
const TRADER_FALLBACK_SELECTION_KEY := "_traderFallbackSelection"
const UTILITY_ANCHOR_KINDS := ["trader_stall", "workstation", "storage", "bed"]
const UTILITY_ANCHOR_BLOCK_TYPES := ["traderStall", "workbench", "furnace", "chest", "bed", "campfire", "anvil"]
const BLOCKED_ENDPOINT_MEMORY_FRAMES := 360
const INVALID_CELL := Vector2i(999999, 999999)
const GUARD_INTERCEPT_DIRECTIONS := [
    Vector2i(-1, 0), Vector2i(0, -1), Vector2i(0, 1), Vector2i(1, 0),
    Vector2i(-1, -1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(1, 1)
]
const GUARD_INTERCEPT_CANDIDATES_PER_CALL := 2

var system
var main
var world
var planner

func setup(system_node, main_node, navigation_world, route_planner) -> void:
    system = system_node
    main = main_node
    world = navigation_world
    planner = route_planner

func surface_y_at_position(position: Vector3) -> float:
    if main != null and main.has_method("surface_y_at_position"):
        return float(main.call("surface_y_at_position", position))
    return position.y

func make_intent(entry: Dictionary, target: Vector3, max_distance: float, moving_home := false, allow_outside := false) -> Dictionary:
    var body := entry.get("body") as Node3D
    var kind: String = String(entry.get("routeIntentKind", entry.get("activeGoalKind", entry.get("goal", "move"))))
    if moving_home:
        kind = "home"
    elif body != null and body.has_meta("npc_scripted_target"):
        kind = "scripted"
    elif not (kind in ["work", "forage", "guard", "job"]):
        var job_phase := String(entry.get("jobPhase", "idle"))
        var job := String(entry.get("job", ""))
        if job_phase in ["outbound", "searching", "gathering", "returning", "stall"] and job != "":
            kind = "forage" if job == "forage" else "work"
        elif allow_outside and job != "":
            kind = "job"
    var target_cell: Vector2i = world.world_cell(target) if world != null else Vector2i(roundi(target.x / CELL), roundi(target.z / CELL))
    var fallback_cells: Array[Vector2i] = []
    var arrival_radius := CELL * 0.72
    var strict_home_route := moving_home
    var strict_scripted_route := false
    var allow_home_partial := false
    if moving_home:
        arrival_radius = CELL * 0.35 if strict_home_route else CELL * 0.82
        if body != null and actor_inside_home(entry, body.global_position):
            fallback_cells = home_interior_goal_cells(entry)
        if body != null:
            var home_cell: Vector2i = entry.get("homeCell", target_cell)
            var porch_cell: Vector2i = entry.get("porchCell", home_cell)
            var current_cell: Vector2i = world.world_cell(body.global_position) if world != null else Vector2i(roundi(body.global_position.x / CELL), roundi(body.global_position.z / CELL))
            var near_home_edge: bool = current_cell == porch_cell \
                or current_cell == home_cell \
                or actor_inside_home(entry, body.global_position) \
                or body.global_position.distance_to(entry.get("porchPosition", target)) <= CELL * 2.0
            allow_home_partial = not near_home_edge and body.global_position.distance_to(target) > CELL * 4.0
    elif kind == "scripted":
        arrival_radius = float(body.get_meta("npc_scripted_arrival_radius", CELL * 0.45)) if body != null else CELL * 0.45
        strict_scripted_route = arrival_radius < CELL * 0.95
    elif kind in ["work", "forage", "guard", "job", "idle", "move"]:
        fallback_cells = routine_goal_fallback_cells(entry, target, allow_outside, moving_home)
    var priority := int(entry.get("routePriority", 0))
    if moving_home:
        priority = maxi(priority, 100)
    elif kind == "scripted":
        priority = maxi(priority, 180)
    elif kind == "guard":
        priority = maxi(priority, 130)
    elif priority <= 0:
        priority = 50
    return {
        "kind": kind,
        "target": target,
        "targetCell": target_cell,
        "allowOutside": allow_outside,
        "movingHome": moving_home,
        "arrivalRadius": arrival_radius,
        "priority": priority,
        "action": "",
        "interruptible": not moving_home,
        "allowPartial": allow_home_partial or kind == "guard",
        "generatedBridgeCritical": kind == "guard" and bool(entry.get("guardRouteCritical", false)),
        "strictArrival": strict_home_route or strict_scripted_route or kind in ["job", "work", "forage"],
        "fallbackCells": fallback_cells
    }

func routine_goal_fallback_cells(entry: Dictionary, target: Vector3, allow_outside := false, moving_home := false) -> Array[Vector2i]:
    var result: Array[Vector2i] = []
    if world == null or not world.has_method("approach_cells_for_target"):
        return result
    var target_cell: Vector2i = world.world_cell(target) if world.has_method("world_cell") else Vector2i(roundi(target.x / CELL), roundi(target.z / CELL))
    for cell in world.approach_cells_for_target(entry, target, allow_outside):
        if not (cell is Vector2i):
            continue
        if cell == target_cell or result.has(cell):
            continue
        if world.has_method("cell_is_standable_goal") and not bool(world.cell_is_standable_goal(entry, cell, allow_outside, moving_home)):
            continue
        result.append(cell)
        if result.size() >= 12:
            break
    return result

func home_interior_goal_cells(entry: Dictionary) -> Array[Vector2i]:
    var result: Array[Vector2i] = []
    var home_cell: Vector2i = entry.get("homeCell", Vector2i.ZERO)
    var interior_min: Vector2i = entry.get("interiorMinCell", home_cell)
    var interior_max: Vector2i = entry.get("interiorMaxCell", home_cell)
    var min_x := mini(interior_min.x, interior_max.x)
    var max_x := maxi(interior_min.x, interior_max.x)
    var min_z := mini(interior_min.y, interior_max.y)
    var max_z := maxi(interior_min.y, interior_max.y)
    for z in range(min_z, max_z + 1):
        for x in range(min_x, max_x + 1):
            var cell := Vector2i(x, z)
            if world != null and world.has_method("cell_is_standable_goal") and not bool(world.cell_is_standable_goal(entry, cell, false, true)):
                continue
            result.append(cell)
    result.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
        var a_home := Vector2(float(a.x - home_cell.x), float(a.y - home_cell.y)).length_squared()
        var b_home := Vector2(float(b.x - home_cell.x), float(b.y - home_cell.y)).length_squared()
        if not is_equal_approx(a_home, b_home):
            return a_home < b_home
        if a.x != b.x:
            return a.x < b.x
        return a.y < b.y
    )
    if result.size() > MAX_HOME_INTERIOR_GOAL_CELLS:
        result.resize(MAX_HOME_INTERIOR_GOAL_CELLS)
    return result

func actor_inside_home(entry: Dictionary, position: Vector3) -> bool:
    var portal = null
    if system != null and system.get("autonomy_system") != null:
        var autonomy = system.get("autonomy_system")
        if autonomy.get("door_portals") != null:
            portal = HomeInteriorServiceScript.portal_for_entry(entry, autonomy.get("door_portals"))
    return bool(HomeInteriorServiceScript.status(entry, position, portal).get("strictInside", false))

func choose_day_target(entry: Dictionary) -> Vector3:
    var monitor = performance_monitor()
    var measure_trader_fallback := monitor != null and String(entry.get("job", "")) == "trade"
    var trader_fallback_start: int = monitor.begin_section("npc_trader_fallback_choose_day_target") if measure_trader_fallback else 0
    if world == null or planner == null:
        if measure_trader_fallback:
            monitor.end_section("npc_trader_fallback_choose_day_target", trader_fallback_start)
        return entry.get("porchPosition", Vector3.ZERO)
    var candidates: Array[Vector3] = town_anchor_candidates(entry)
    var reachable := choose_best_reachable_position(entry, candidates, false, false, CELL * 0.85, MAX_ROUTE_SCORED_CANDIDATES)
    if reachable != Vector3.INF:
        clear_goal_fallback(entry)
        if measure_trader_fallback:
            monitor.end_section("npc_trader_fallback_choose_day_target", trader_fallback_start)
        return reachable
    set_goal_fallback(entry, "blocked", "no_reachable_wander_anchor")
    if measure_trader_fallback:
        monitor.end_section("npc_trader_fallback_choose_day_target", trader_fallback_start)
    return entry.get("porchPosition", Vector3.ZERO)

## Advances the trader-only fallback selector by at most one expensive world
## check. Pending and invalidated results intentionally never contain a target.
func advance_trader_fallback_target(entry: Dictionary, request_id: String) -> Dictionary:
    var monitor = performance_monitor()
    var selection_start: int = monitor.begin_section("npc_trader_fallback_choose_day_target") if monitor != null else 0
    var result := _advance_trader_fallback_target(entry, request_id, monitor)
    if monitor != null:
        monitor.end_section("npc_trader_fallback_choose_day_target", selection_start)
        monitor.increment_counter("npc_trader_fallback_selector_calls")
        monitor.increment_counter("npc_trader_fallback_selector_%s" % String(result.get("status", "unknown")))
    return result

func _advance_trader_fallback_target(entry: Dictionary, request_id: String, monitor) -> Dictionary:
    if request_id == "" or world == null or main == null:
        clear_trader_fallback_target_selection(entry, "invalid_context")
        return {"status":"exhausted", "reason":"invalid_context"}
    var service = smart_object_service()
    if service == null or not service.has_method("query_resource_nodes") or not service.has_method("query_scope_revision"):
        clear_trader_fallback_target_selection(entry, "missing_smart_object_service")
        return {"status":"exhausted", "reason":"missing_smart_object_service"}
    var body_value = entry.get("body")
    var body: Node3D = body_value as Node3D if body_value != null and is_instance_valid(body_value) and body_value is Node3D else null
    var origin: Vector3 = body.global_position if body != null else entry.get("porchPosition", Vector3.ZERO)
    var options := utility_anchor_query_options()
    var current_scope: Dictionary = service.query_scope_revision(entry, UTILITY_ANCHOR_KINDS, options, origin)
    var current_identity := trader_fallback_selection_identity(entry, request_id, body, origin, current_scope)
    var state_value = entry.get(TRADER_FALLBACK_SELECTION_KEY, {})
    var state: Dictionary = state_value if state_value is Dictionary else {}
    if not state.is_empty() and state.get("identity", {}) != current_identity:
        var prior_identity: Dictionary = state.get("identity", {}) if state.get("identity", {}) is Dictionary else {}
        var reason := trader_fallback_invalidation_reason(prior_identity, current_identity)
        clear_trader_fallback_target_selection(entry, reason)
        entry["lastTraderFallbackSelectionDebug"] = {
            "status":"invalidated", "reason":reason, "requestId":request_id
        }
        return {"status":"invalidated", "reason":reason}
    if state.is_empty():
        state = begin_trader_fallback_selection(entry, request_id, body, origin, service, options)
        entry[TRADER_FALLBACK_SELECTION_KEY] = state
        entry["traderFallbackSelectionPending"] = true
    var expensive_check_used := false
    if String(state.get("phase", "approach")) == "approach":
        var descriptors: Array = state.get("utilityDescriptors", []) if state.get("utilityDescriptors", []) is Array else []
        var cursor := int(state.get("approachCursor", 0))
        var added := int(state.get("utilityApproachesAdded", 0))
        if cursor < descriptors.size() and added < UTILITY_ANCHOR_LIMIT:
            var descriptor: Dictionary = descriptors[cursor] if descriptors[cursor] is Dictionary else {}
            state["approachChecks"] = int(state.get("approachChecks", 0)) + 1
            var approach_start: int = monitor.begin_section("npc_utility_anchor_approach") if monitor != null else 0
            var approach_result := {}
            if world.has_method("advance_first_approach_cell"):
                var descriptor_request_id := "%s|%s" % [request_id, String(descriptor.get("objectId", cursor))]
                approach_result = world.advance_first_approach_cell(entry, descriptor.get("position", Vector3.ZERO), false, descriptor_request_id)
            else:
                var approach_cells: Array = world.approach_cells_for_target(entry, descriptor.get("position", Vector3.ZERO), false) if world.has_method("approach_cells_for_target") else []
                approach_result = {
                    "status":"ready" if not approach_cells.is_empty() else "exhausted",
                    "cell":approach_cells[0] if not approach_cells.is_empty() else Vector2i(999999, 999999)
                }
            if monitor != null:
                monitor.end_section("npc_utility_anchor_approach", approach_start)
            expensive_check_used = true
            var approach_status := String(approach_result.get("status", "exhausted"))
            if approach_status == "pending":
                entry[TRADER_FALLBACK_SELECTION_KEY] = state
                return trader_fallback_pending_result(entry, state, "utility_approach_pending")
            if approach_status == "invalidated":
                entry[TRADER_FALLBACK_SELECTION_KEY] = state
                return trader_fallback_pending_result(entry, state, "utility_approach_invalidated")
            state["approachCursor"] = cursor + 1
            var cell_value = approach_result.get("cell", Vector2i(999999, 999999))
            if approach_status == "ready" and cell_value is Vector2i:
                var position: Vector3 = world.cell_position(cell_value as Vector2i)
                if world.point_inside_town(entry, position):
                    var candidates: Array = state.get("candidates", []) if state.get("candidates", []) is Array else []
                    candidates.append(position)
                    state["candidates"] = candidates
                    state["utilityApproachesAdded"] = added + 1
        if int(state.get("approachCursor", 0)) >= descriptors.size() or int(state.get("utilityApproachesAdded", 0)) >= UTILITY_ANCHOR_LIMIT:
            prepare_trader_fallback_validation(entry, state, origin)
        entry[TRADER_FALLBACK_SELECTION_KEY] = state
        if expensive_check_used:
            return trader_fallback_pending_result(entry, state, "utility_approach_pending")
    if String(state.get("phase", "")) == "validate":
        var validation_candidates: Array = state.get("validationCandidates", []) if state.get("validationCandidates", []) is Array else []
        var validation_cursor := int(state.get("validationCursor", 0))
        while validation_cursor < validation_candidates.size() and endpoint_temporarily_blocked(entry, validation_candidates[validation_cursor]):
            validation_cursor += 1
            state["validationCursor"] = validation_cursor
        if validation_cursor >= validation_candidates.size():
            return finish_trader_fallback_exhausted(entry, state)
        var candidate: Vector3 = validation_candidates[validation_cursor]
        state["validationCursor"] = validation_cursor + 1
        state["standabilityChecks"] = int(state.get("standabilityChecks", 0)) + 1
        if position_can_be_goal(entry, candidate, false, false):
            store_resolved_endpoint_debug(entry, candidate, candidate, false, false, CELL * 0.85, "standable_without_route_cost", 0.0)
            clear_goal_fallback(entry)
            var debug := trader_fallback_debug(state, "ready", "nearest_valid_candidate")
            debug["target"] = candidate
            entry["lastTraderFallbackSelectionDebug"] = debug
            publish_incremental_utility_anchor_debug(entry, state, "ready")
            clear_trader_fallback_target_selection(entry, "ready")
            return {"status":"ready", "reason":"nearest_valid_candidate", "target":candidate}
        entry[TRADER_FALLBACK_SELECTION_KEY] = state
        if int(state.get("validationCursor", 0)) >= validation_candidates.size():
            return finish_trader_fallback_exhausted(entry, state)
        return trader_fallback_pending_result(entry, state, "standability_pending")
    return finish_trader_fallback_exhausted(entry, state)

func utility_anchor_query_options() -> Dictionary:
    return {
        "limit": UTILITY_ANCHOR_QUERY_LIMIT,
        "outsideTown": false,
        "insideTownOnly": true,
        "workAreaOnly": true,
        "collectAllSpatialMatches": true,
        "distanceMode": "3d",
        "blockTypes": UTILITY_ANCHOR_BLOCK_TYPES,
        "bypassCache": true
    }

func begin_trader_fallback_selection(entry: Dictionary, request_id: String, body: Node3D, origin: Vector3, service, options: Dictionary) -> Dictionary:
    var candidates: Array[Vector3] = []
    candidates.append(entry.get("porchPosition", Vector3.ZERO))
    candidates.append(entry.get("guardPosition", entry.get("porchPosition", Vector3.ZERO)))
    add_path_candidates(candidates, entry, false)
    var query_start: int = performance_monitor().begin_section("npc_utility_anchor_index_query") if performance_monitor() != null else 0
    var indexed_nodes: Array[Node3D] = service.query_resource_nodes(entry, UTILITY_ANCHOR_KINDS, options)
    if performance_monitor() != null:
        performance_monitor().end_section("npc_utility_anchor_index_query", query_start)
    var descriptors: Array[Dictionary] = []
    for node in indexed_nodes:
        if node == null or not is_instance_valid(node):
            continue
        if not (String(node.get_meta("block_type", "")) in UTILITY_ANCHOR_BLOCK_TYPES):
            continue
        if not world.point_inside_town(entry, node.global_position):
            continue
        descriptors.append({"objectId":stable_node_id(node), "position":node.global_position})
    descriptors.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        var a_distance: float = (a.get("position", Vector3.ZERO) as Vector3).distance_squared_to(origin)
        var b_distance: float = (b.get("position", Vector3.ZERO) as Vector3).distance_squared_to(origin)
        if is_equal_approx(a_distance, b_distance):
            return String(a.get("objectId", "")) < String(b.get("objectId", ""))
        return a_distance < b_distance
    )
    if descriptors.size() > UTILITY_ANCHOR_QUERY_LIMIT:
        descriptors.resize(UTILITY_ANCHOR_QUERY_LIMIT)
    var scope: Dictionary = service.query_scope_revision(entry, UTILITY_ANCHOR_KINDS, options, origin)
    return {
        "identity":trader_fallback_selection_identity(entry, request_id, body, origin, scope),
        "requestId":request_id,
        "phase":"approach",
        "candidates":candidates,
        "utilityDescriptors":descriptors,
        "approachCursor":0,
        "utilityApproachesAdded":0,
        "approachChecks":0,
        "standabilityChecks":0,
        "validationCursor":0,
        "indexedReturned":indexed_nodes.size(),
        "acceptedUtilityNodes":descriptors.size()
    }

func prepare_trader_fallback_validation(entry: Dictionary, state: Dictionary, origin: Vector3) -> void:
    refresh_blocked_endpoint_memory(entry)
    var raw_candidates: Array[Vector3] = []
    for candidate_value in state.get("candidates", []):
        if candidate_value is Vector3:
            raw_candidates.append(candidate_value)
    var ordered := unique_positions(raw_candidates)
    ordered.sort_custom(func(a: Vector3, b: Vector3) -> bool:
        var a_distance := a.distance_squared_to(origin)
        var b_distance := b.distance_squared_to(origin)
        if is_equal_approx(a_distance, b_distance):
            return position_key(a) < position_key(b)
        return a_distance < b_distance
    )
    if ordered.size() > MAX_ROUTE_SCORED_CANDIDATES:
        ordered.resize(MAX_ROUTE_SCORED_CANDIDATES)
    state["phase"] = "validate"
    state["validationCandidates"] = ordered
    state["validationCursor"] = 0
    state.erase("candidates")
    state.erase("utilityDescriptors")

func trader_fallback_selection_identity(entry: Dictionary, request_id: String, body: Node3D, origin: Vector3, scope: Dictionary) -> Dictionary:
    return {
        "requestId":request_id,
        "actorId":String(entry.get("id", "")),
        "bodyInstanceId":body.get_instance_id() if body != null else 0,
        "origin":[snappedf(origin.x, 0.001), snappedf(origin.y, 0.001), snappedf(origin.z, 0.001)],
        "townCenter":entry.get("townCenter", Vector2i.ZERO),
        "townRadius":int(entry.get("townRadius", 18)),
        "porchPosition":trader_fallback_identity_position(entry.get("porchPosition", Vector3.ZERO)),
        "guardPosition":trader_fallback_identity_position(entry.get("guardPosition", entry.get("porchPosition", Vector3.ZERO))),
        "townKey":String(entry.get("townKey", "")),
        "homeStableId":String(entry.get("homeStableId", "")),
        "homeKey":str(entry.get("homeKey", "")),
        "homeCell":entry.get("homeCell", Vector2i.ZERO),
        "porchCell":entry.get("porchCell", Vector2i.ZERO),
        "sourceScope":scope.duplicate(true)
    }

func trader_fallback_identity_position(value) -> Array:
    var position: Vector3 = value if value is Vector3 else Vector3.ZERO
    return [snappedf(position.x, 0.001), snappedf(position.y, 0.001), snappedf(position.z, 0.001)]

func trader_fallback_invalidation_reason(previous: Dictionary, current: Dictionary) -> String:
    if String(previous.get("requestId", "")) != String(current.get("requestId", "")):
        return "request_changed"
    if String(previous.get("actorId", "")) != String(current.get("actorId", "")) or int(previous.get("bodyInstanceId", 0)) != int(current.get("bodyInstanceId", 0)) or previous.get("origin", []) != current.get("origin", []):
        return "actor_changed"
    if previous.get("townCenter", Vector2i.ZERO) != current.get("townCenter", Vector2i.ZERO) or int(previous.get("townRadius", 18)) != int(current.get("townRadius", 18)):
        return "town_changed"
    if previous.get("porchPosition", []) != current.get("porchPosition", []) or previous.get("guardPosition", []) != current.get("guardPosition", []):
        return "anchor_changed"
    for key in ["townKey", "homeStableId", "homeKey", "homeCell", "porchCell"]:
        if previous.get(key) != current.get(key):
            return "assignment_changed"
    return "source_changed"

func trader_fallback_pending_result(entry: Dictionary, state: Dictionary, reason: String) -> Dictionary:
    entry["traderFallbackSelectionPending"] = true
    entry["lastTraderFallbackSelectionDebug"] = trader_fallback_debug(state, "pending", reason)
    publish_incremental_utility_anchor_debug(entry, state, "pending")
    return {"status":"pending", "reason":reason}

func finish_trader_fallback_exhausted(entry: Dictionary, state: Dictionary) -> Dictionary:
    var debug := trader_fallback_debug(state, "exhausted", "no_reachable_wander_anchor")
    entry["lastTraderFallbackSelectionDebug"] = debug
    publish_incremental_utility_anchor_debug(entry, state, "exhausted")
    set_goal_fallback(entry, "blocked", "no_reachable_wander_anchor")
    clear_trader_fallback_target_selection(entry, "exhausted")
    return {"status":"exhausted", "reason":"no_reachable_wander_anchor"}

func trader_fallback_debug(state: Dictionary, status: String, reason: String) -> Dictionary:
    return {
        "status":status,
        "reason":reason,
        "requestId":String(state.get("requestId", "")),
        "phase":String(state.get("phase", "")),
        "indexedReturned":int(state.get("indexedReturned", 0)),
        "acceptedUtilityNodes":int(state.get("acceptedUtilityNodes", 0)),
        "approachChecks":int(state.get("approachChecks", 0)),
        "appendedApproachCandidates":int(state.get("utilityApproachesAdded", 0)),
        "standabilityChecks":int(state.get("standabilityChecks", 0)),
        "validationCandidates":int((state.get("validationCandidates", []) as Array).size()) if state.get("validationCandidates", []) is Array else 0
    }

func publish_incremental_utility_anchor_debug(entry: Dictionary, state: Dictionary, status: String) -> void:
    entry["lastUtilityAnchorDebug"] = {
        "selectionMode":"incremental_trader_fallback",
        "selectionStatus":status,
        "selectionPhase":String(state.get("phase", "")),
        "indexedReturned":int(state.get("indexedReturned", 0)),
        "acceptedUtilityNodes":int(state.get("acceptedUtilityNodes", 0)),
        "approachChecks":int(state.get("approachChecks", 0)),
        "appendedApproachCandidates":int(state.get("utilityApproachesAdded", 0)),
        "standabilityChecks":int(state.get("standabilityChecks", 0))
    }

func clear_trader_fallback_target_selection(entry: Dictionary, _reason := "cancelled") -> void:
    if world != null and world.has_method("cancel_approach_cell_certification"):
        # The selector owns exactly one adapter certification per actor. Cancel
        # actor-scoped so the object-qualified request identity retained by the
        # adapter cannot survive selection reset.
        world.cancel_approach_cell_certification(entry)
    entry.erase(TRADER_FALLBACK_SELECTION_KEY)
    entry.erase("traderFallbackSelectionPending")

func choose_job_target(entry: Dictionary) -> Vector3:
    if world == null or planner == null:
        return entry.get("porchPosition", Vector3.ZERO)
    var job := String(entry.get("job", ""))
    var outside_town_job := resource_job_uses_outside_work_area(job)
    if job == "forage" and forager_prefers_search_anchor(entry):
        var search_target := choose_forage_search_target(entry)
        if search_target != Vector3.INF:
            clear_goal_fallback(entry)
            return search_target
        set_goal_fallback(entry, "waiting", "forage_no_new_search_anchor")
        return Vector3.INF
    var resource_candidates: Array[Vector3] = []
    add_resource_prop_candidates(resource_candidates, entry, job)
    # Work selection chooses a legal, standable endpoint. The retained V2 route
    # request performs the authoritative collision-backed route proof before
    # movement, so synchronously scoring up to hundreds of equivalent endpoint
    # variants here only duplicates that acceptance work in the gameplay frame.
    var resource_reachable := choose_best_reachable_position(entry, resource_candidates, outside_town_job, false, CELL * 0.85, MAX_ROUTE_SCORED_CANDIDATES, false)
    if resource_reachable != Vector3.INF and job_position_allowed(entry, resource_reachable, outside_town_job):
        clear_goal_fallback(entry)
        return resource_reachable
    if job == "forage":
        var forage_search := choose_forage_search_target(entry)
        if forage_search != Vector3.INF:
            clear_goal_fallback(entry)
            return forage_search
    var candidates: Array[Vector3] = job_anchor_candidates(entry, outside_town_job)
    var reachable := choose_best_reachable_position(entry, candidates, outside_town_job, false, CELL * 0.85, MAX_ROUTE_SCORED_CANDIDATES, false)
    if reachable != Vector3.INF and job_position_allowed(entry, reachable, outside_town_job):
        clear_goal_fallback(entry)
        return reachable
    set_goal_fallback(entry, "blocked", "no_reachable_job_anchor")
    var fallback_candidates: Array[Vector3] = [
        entry.get("porchPosition", Vector3.ZERO),
        entry.get("guardPosition", entry.get("porchPosition", Vector3.ZERO))
    ]
    var fallback := choose_best_reachable_position(entry, fallback_candidates, false, false, CELL * 0.85, 4, true)
    return fallback if fallback != Vector3.INF else entry.get("porchPosition", Vector3.ZERO)

func forager_prefers_search_anchor(entry: Dictionary) -> bool:
    if String(entry.get("job", "")) != "forage":
        return false
    if String(entry.get("jobObjectId", "")) != "":
        return false
    var phase := String(entry.get("jobPhase", ""))
    if phase == "searching":
        return true
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body) or world == null:
        return false
    return world.point_inside_town(entry, body.global_position)

func choose_guard_target(entry: Dictionary, target_hostile: Node3D = null, melee := false) -> Vector3:
    if world == null:
        return entry.get("guardPosition", entry.get("porchPosition", Vector3.ZERO))
    if target_hostile != null and is_instance_valid(target_hostile):
        var intercept_selection := advance_hostile_intercept_selection(entry, target_hostile, melee)
        if String(intercept_selection.get("status", "")) == "pending":
            return entry.get("guardTargetCache", entry.get("guardPosition", entry.get("porchPosition", Vector3.ZERO)))
        var intercept: Vector3 = intercept_selection.get("target", Vector3.INF)
        if intercept != Vector3.INF:
            clear_goal_fallback(entry)
            return intercept
    else:
        clear_hostile_intercept_selection(entry)
    var assigned_guard_post: Vector3 = entry.get("guardPosition", entry.get("porchPosition", Vector3.ZERO))
    if position_is_semantic_guard_anchor(entry, assigned_guard_post, false):
        clear_goal_fallback(entry)
        return assigned_guard_post
    var candidates: Array[Vector3] = guard_post_candidates(entry)
    var guard_target := choose_nearest_guard_anchor(entry, candidates, false)
    if guard_target != Vector3.INF:
        clear_goal_fallback(entry)
        return guard_target
    set_goal_fallback(entry, "blocked", "no_reachable_guard_anchor")
    return assigned_guard_post

func choose_nearest_guard_anchor(entry: Dictionary, candidates: Array[Vector3], allow_outside := false) -> Vector3:
    var body := entry.get("body") as Node3D
    var origin: Vector3 = body.global_position if body != null else entry.get("guardPosition", Vector3.ZERO)
    var ordered := unique_positions(candidates)
    ordered.sort_custom(func(a: Vector3, b: Vector3) -> bool:
        var a_distance := a.distance_squared_to(origin)
        var b_distance := b.distance_squared_to(origin)
        if is_equal_approx(a_distance, b_distance):
            return position_key(a) < position_key(b)
        return a_distance < b_distance
    )
    for candidate in ordered:
        if position_is_semantic_guard_anchor(entry, candidate, allow_outside):
            return candidate
    return Vector3.INF

func position_is_semantic_guard_anchor(entry: Dictionary, position: Vector3, allow_outside := false) -> bool:
    if position == Vector3.INF:
        return false
    if not world.point_allowed(entry, position, allow_outside, false):
        return false
    # Guard posts and intercept candidates already carry their generated-world
    # elevation. Goal selection only needs a cheap semantic screen; the V2 route
    # authority performs the fresh terrain/collision proof before committing
    # movement. Re-querying generation here duplicated that physical validation
    # in the gameplay frame and could stall every guard refresh.
    return position.y >= main.WATER_LEVEL + 0.45

func choose_best_forage(entry: Dictionary, candidates: Array[Node3D]) -> Node3D:
    if world == null:
        return candidates[0] if not candidates.is_empty() else null
    var body := entry.get("body") as Node3D
    var origin: Vector3 = body.global_position if body != null else entry.get("porchPosition", Vector3.ZERO)
    candidates.sort_custom(func(a: Node3D, b: Node3D) -> bool:
        if a == null or b == null:
            return a != null
        var a_distance := a.global_position.distance_squared_to(origin)
        var b_distance := b.global_position.distance_squared_to(origin)
        if is_equal_approx(a_distance, b_distance):
            return stable_node_id(a) < stable_node_id(b)
        return a_distance < b_distance
    )
    var pending_candidate: Node3D = null
    for node in candidates:
        if node == null or not is_instance_valid(node):
            continue
        var approach_cells: Array[Vector2i] = world.approach_cells_for_target(entry, node.global_position, true)
        var approach_positions: Array[Vector3] = []
        for cell in approach_cells:
            approach_positions.append(world.cell_position(cell))
        var reachable := choose_best_reachable_position(entry, approach_positions, true, false, CELL * 0.85, mini(approach_positions.size(), 6), true)
        if reachable != Vector3.INF:
            return node
        if pending_candidate == null:
            var standable := choose_best_reachable_position(entry, approach_positions, true, false, CELL * 0.85, mini(approach_positions.size(), 6), false)
            if standable != Vector3.INF:
                pending_candidate = node
    if pending_candidate != null:
        return pending_candidate
    return null

func forage_target_position(entry: Dictionary, node: Node3D) -> Vector3:
    if node == null or world == null:
        return node.global_position if node != null else Vector3.ZERO
    var approach_cells: Array[Vector2i] = world.approach_cells_for_target(entry, node.global_position, true)
    var approach_positions: Array[Vector3] = []
    for cell in approach_cells:
        approach_positions.append(world.cell_position(cell))
    var reachable := choose_best_reachable_position(entry, approach_positions, true, false, CELL * 0.85, approach_positions.size(), true)
    if reachable != Vector3.INF:
        return reachable
    var standable := choose_best_reachable_position(entry, approach_positions, true, false, CELL * 0.85, approach_positions.size(), false)
    return standable if standable != Vector3.INF else node.global_position

func choose_forage_search_target(entry: Dictionary) -> Vector3:
    if world == null:
        return Vector3.INF
    var candidates: Array[Vector3] = []
    add_nearest_forage_exit_candidates(candidates, entry)
    add_path_candidates(candidates, entry, true)
    var outward := outward_work_anchor(entry)
    if outward != Vector3.INF:
        candidates.append(outward)
    add_forage_search_sweep_candidates(candidates, entry)
    add_deterministic_ring_candidates(candidates, entry, true)
    candidates = forage_search_candidates_away_from_current_cell(entry, candidates)
    var reachable := choose_best_reachable_position(entry, candidates, true, false, CELL * 0.85, MAX_ROUTE_SCORED_CANDIDATES, false)
    if reachable != Vector3.INF and forage_search_target_requires_travel(entry, reachable) and job_position_allowed(entry, reachable, true):
        return reachable
    # Route cost is an advisory scorer only. V2 owns the collision-backed decision
    # to execute, defer, or reject this legal outside-work-area search intent.
    for candidate in unique_positions(candidates):
        if not forage_search_target_requires_travel(entry, candidate):
            continue
        if not job_position_allowed(entry, candidate, true):
            continue
        if position_can_be_static_goal(entry, candidate, true, false):
            return candidate
    return Vector3.INF

func forage_search_candidates_away_from_current_cell(entry: Dictionary, candidates: Array[Vector3]) -> Array[Vector3]:
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return candidates
    var current_key := position_key(body.global_position)
    var filtered: Array[Vector3] = []
    for candidate in candidates:
        if position_key(candidate) != current_key:
            filtered.append(candidate)
    return filtered

func forage_search_target_requires_travel(entry: Dictionary, target: Vector3) -> bool:
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return true
    return position_key(target) != position_key(body.global_position)

func add_nearest_forage_exit_candidates(candidates: Array[Vector3], entry: Dictionary) -> void:
    if world == null or main == null:
        return
    var center_cell: Vector2i = entry.get("townCenter", Vector2i.ZERO)
    var center := Vector3(float(center_cell.x) * CELL, 0.0, float(center_cell.y) * CELL)
    var origins: Array[Vector3] = []
    var body := entry.get("body") as Node3D
    if body != null and is_instance_valid(body):
        origins.append(body.global_position)
    origins.append(entry.get("porchPosition", entry.get("homePosition", center)))
    origins.append(entry.get("homePosition", entry.get("porchPosition", center)))
    var base_radius := maxf(float(entry.get("townRadius", 18)) + 4.0, 22.0)
    var seen := {}
    for origin in origins:
        var direction := origin - center
        direction.y = 0.0
        if direction.length_squared() < 0.001:
            continue
        direction = direction.normalized()
        for extra in [0.0, 4.0, 8.0]:
            var position := center + direction * (base_radius + float(extra)) * CELL
            var key := position_key(position)
            if seen.has(key):
                continue
            seen[key] = true
            var ground_y := surface_y_at_position(position)
            if ground_y < main.WATER_LEVEL + 0.5:
                continue
            position.y = ground_y + 0.04
            if world.point_inside_work_area(entry, position) and not world.point_inside_town(entry, position):
                candidates.append(position)

func stable_node_id(node: Node) -> String:
    if node == null:
        return ""
    if node.has_meta("prop_id"):
        return String(node.get_meta("prop_id"))
    if node.has_meta("cell"):
        var cell = node.get_meta("cell")
        if cell is Vector3i:
            var block_type := String(node.get_meta("block_type", node.name))
            return "block:%d,%d,%d:%s" % [cell.x, cell.y, cell.z, block_type]
    if node.has_meta("smart_object_id"):
        return String(node.get_meta("smart_object_id"))
    return String(node.name)

func choose_best_reachable_position(entry: Dictionary, candidates: Array[Vector3], allow_outside := false, moving_home := false, _arrival_radius := CELL * 0.85, max_checked := 8, force_route_cost := false) -> Vector3:
    var body := entry.get("body") as Node3D
    var origin: Vector3 = body.global_position if body != null else entry.get("porchPosition", Vector3.ZERO)
    refresh_blocked_endpoint_memory(entry)
    var unique_candidates := unique_positions(candidates)
    unique_candidates.sort_custom(func(a: Vector3, b: Vector3) -> bool:
        var a_distance := a.distance_squared_to(origin)
        var b_distance := b.distance_squared_to(origin)
        if is_equal_approx(a_distance, b_distance):
            return position_key(a) < position_key(b)
        return a_distance < b_distance
    )
    var score_with_route_cost := force_route_cost or moving_home or OS.get_environment("VOXEL_NPC_ROUTE_SCORE_TARGETS") == "1"
    var checked: int = 0
    for candidate in unique_candidates:
        checked += 1
        if checked > max_checked:
            break
        if endpoint_temporarily_blocked(entry, candidate):
            continue
        if score_with_route_cost:
            var resolved := resolve_reachable_endpoint(entry, candidate, allow_outside, moving_home, _arrival_radius, force_route_cost)
            if resolved != Vector3.INF:
                return resolved
            continue
        if not position_can_be_goal(entry, candidate, allow_outside, moving_home):
            continue
        if not score_with_route_cost:
            store_resolved_endpoint_debug(entry, candidate, candidate, allow_outside, moving_home, _arrival_radius, "standable_without_route_cost", 0.0)
            return candidate
    return Vector3.INF

func resolve_reachable_endpoint(entry: Dictionary, requested: Vector3, allow_outside := false, moving_home := false, arrival_radius := CELL * 0.85, require_ready := true) -> Vector3:
    if requested == Vector3.INF or world == null:
        return Vector3.INF
    var cache_key := resolved_endpoint_cache_key(entry, requested, allow_outside, moving_home, arrival_radius, require_ready)
    var cache: Dictionary = entry.get("resolvedEndpointCache", {}) if entry.get("resolvedEndpointCache", {}) is Dictionary else {}
    var cached_value = cache.get(cache_key, {})
    if cached_value is Dictionary:
        var cached: Dictionary = cached_value
        var age := Engine.get_process_frames() - int(cached.get("frame", -999999))
        if age >= 0 and age <= 30:
            var cached_resolved = cached.get("resolved", Vector3.INF)
            store_resolved_endpoint_debug(entry, requested, cached_resolved if cached_resolved is Vector3 else Vector3.INF, allow_outside, moving_home, arrival_radius, String(cached.get("reason", "cached")), float(cached.get("cost", -1.0)))
            return cached_resolved if cached_resolved is Vector3 else Vector3.INF
    var candidates: Array[Vector3] = [requested]
    var requested_cell: Vector2i = world.world_cell(requested) if world.has_method("world_cell") else Vector2i(roundi(requested.x / CELL), roundi(requested.z / CELL))
    if world.has_method("approach_cells_for_target"):
        for cell in world.approach_cells_for_target(entry, requested, allow_outside):
            if not (cell is Vector2i):
                continue
            var pos: Vector3 = world.cell_position(cell)
            if not candidates.has(pos):
                candidates.append(pos)
    for radius in range(1, 3):
        for dz in range(-radius, radius + 1):
            for dx in range(-radius, radius + 1):
                if max(absi(dx), absi(dz)) != radius:
                    continue
                var cell := requested_cell + Vector2i(dx, dz)
                var pos: Vector3 = world.cell_position(cell)
                if not candidates.has(pos):
                    candidates.append(pos)
    var best := Vector3.INF
    var best_cost := INF
    var pending_nav_candidate := Vector3.INF
    for candidate in unique_positions(candidates):
        if endpoint_temporarily_blocked(entry, candidate):
            continue
        if not position_can_be_goal(entry, candidate, allow_outside, moving_home):
            continue
        var cost := INF
        if planner != null and planner.has_method("route_cost"):
            cost = float(planner.route_cost(entry, candidate, allow_outside, moving_home, arrival_radius, [], require_ready))
        if cost < best_cost:
            best = candidate
            best_cost = cost
        elif cost >= INF and pending_nav_candidate == Vector3.INF and endpoint_resolution_waiting_on_nav_data(entry):
            pending_nav_candidate = candidate
    if best != Vector3.INF:
        store_resolved_endpoint_debug(entry, requested, best, allow_outside, moving_home, arrival_radius, "route_cost", best_cost)
    elif pending_nav_candidate != Vector3.INF:
        best = pending_nav_candidate
        store_resolved_endpoint_debug(entry, requested, best, allow_outside, moving_home, arrival_radius, "pending_nav_data_endpoint", -1.0)
    else:
        store_resolved_endpoint_debug(entry, requested, Vector3.INF, allow_outside, moving_home, arrival_radius, "no_route_cost_endpoint", -1.0)
    cache[cache_key] = {
        "frame": Engine.get_process_frames(),
        "resolved": best,
        "reason": String((entry.get("lastResolvedEndpointDebug", {}) as Dictionary).get("reason", "")) if entry.get("lastResolvedEndpointDebug", {}) is Dictionary else "",
        "cost": best_cost if best != Vector3.INF else -1.0
    }
    entry["resolvedEndpointCache"] = cache
    return best

func endpoint_resolution_waiting_on_nav_data(entry: Dictionary) -> bool:
    if bool(entry.get("navmeshEndpointTilesStillLoading", false)):
        return true
    var missing_tiles = entry.get("navmeshMissingEndpointTiles", [])
    if missing_tiles is Array and not (missing_tiles as Array).is_empty():
        return true
    var publish_debug = entry.get("lastNavmeshTilePublishDebug", [])
    if not (publish_debug is Array):
        return false
    for record_value in publish_debug:
        if not (record_value is Dictionary):
            continue
        var status := String((record_value as Dictionary).get("status", ""))
        if status in ["probe_missing_ready_tile", "pending_budget", "queued_priority", "queued_budgeted", "skipped_until_endpoint_tiles"]:
            return true
    return false

func refresh_blocked_endpoint_memory(entry: Dictionary) -> void:
    var debug_value = entry.get("lastRoutePlanDebug", {})
    if not (debug_value is Dictionary):
        prune_blocked_endpoint_memory(entry)
        return
    var debug: Dictionary = debug_value
    var reason := String(debug.get("reason", ""))
    var authority := String(debug.get("routeAuthorityState", ""))
    var collision_endpoint_failure := reason in ["blocked_capsule_probe", "path_crosses_static_collision", "blocked_static_collision", "blocked_static_transition"]
    var terminal_endpoint_failure := authority == "unreachable_static" and reason in ["blocked_capsule_probe", "path_endpoint_mismatch", "target_blocked", "endpoint_not_server_walkable", "no_target_server_walkable"]
    if not (collision_endpoint_failure or terminal_endpoint_failure):
        prune_blocked_endpoint_memory(entry)
        return
    if terminal_endpoint_failure and endpoint_resolution_waiting_on_nav_data(entry):
        prune_blocked_endpoint_memory(entry)
        return
    var target_cell := cell_from_value(debug.get("targetCell", INVALID_CELL))
    if target_cell == INVALID_CELL:
        prune_blocked_endpoint_memory(entry)
        return
    var memory: Dictionary = entry.get("blockedEndpointCells", {}) if entry.get("blockedEndpointCells", {}) is Dictionary else {}
    memory[cell_key(target_cell)] = {
        "frame": Engine.get_process_frames(),
        "reason": reason
    }
    entry["blockedEndpointCells"] = memory
    prune_blocked_endpoint_memory(entry)

func prune_blocked_endpoint_memory(entry: Dictionary) -> void:
    var memory: Dictionary = entry.get("blockedEndpointCells", {}) if entry.get("blockedEndpointCells", {}) is Dictionary else {}
    if memory.is_empty():
        return
    var now := Engine.get_process_frames()
    for key in memory.keys():
        var record: Dictionary = memory.get(key, {}) if memory.get(key, {}) is Dictionary else {}
        if now - int(record.get("frame", now)) > BLOCKED_ENDPOINT_MEMORY_FRAMES:
            memory.erase(key)
    entry["blockedEndpointCells"] = memory

func endpoint_temporarily_blocked(entry: Dictionary, position: Vector3) -> bool:
    if position == Vector3.INF or world == null or not world.has_method("world_cell"):
        return false
    var memory: Dictionary = entry.get("blockedEndpointCells", {}) if entry.get("blockedEndpointCells", {}) is Dictionary else {}
    if memory.is_empty():
        return false
    return memory.has(cell_key(world.world_cell(position)))

func cell_from_value(value) -> Vector2i:
    if value is Vector2i:
        return value
    if value is Dictionary:
        var dict: Dictionary = value
        return Vector2i(int(dict.get("x", 999999)), int(dict.get("z", dict.get("y", 999999))))
    if value is Array and (value as Array).size() >= 2:
        var array_value: Array = value
        return Vector2i(int(array_value[0]), int(array_value[1]))
    return INVALID_CELL

func cell_key(cell: Vector2i) -> String:
    return "%d,%d" % [cell.x, cell.y]

func resolved_endpoint_cache_key(entry: Dictionary, requested: Vector3, allow_outside: bool, moving_home: bool, arrival_radius: float, require_ready: bool) -> String:
    var cell: Vector2i = world.world_cell(requested) if world != null and world.has_method("world_cell") else Vector2i(roundi(requested.x / CELL), roundi(requested.z / CELL))
    return "%s|%s|%s|%s|%s|%d,%d|%d|%d" % [
        String(entry.get("id", "")),
        String(entry.get("job", "")),
        String(entry.get("jobPhase", "")),
        str(allow_outside),
        str(moving_home),
        cell.x,
        cell.y,
        roundi(arrival_radius * 100.0),
        1 if require_ready else 0
    ]

func resolved_endpoint_position(entry: Dictionary) -> Vector3:
    var debug_value = entry.get("lastResolvedEndpointDebug", {})
    if debug_value is Dictionary:
        var resolved = (debug_value as Dictionary).get("resolved", Vector3.INF)
        if resolved is Vector3:
            return resolved
    return Vector3.INF

func store_resolved_endpoint_debug(entry: Dictionary, requested: Vector3, resolved: Vector3, allow_outside: bool, moving_home: bool, arrival_radius: float, reason: String, cost: float) -> void:
    entry["lastResolvedEndpointDebug"] = {
        "requested": requested,
        "resolved": resolved,
        "requestedCell": world.world_cell(requested) if world != null and world.has_method("world_cell") and requested != Vector3.INF else Vector2i(999999, 999999),
        "resolvedCell": world.world_cell(resolved) if world != null and world.has_method("world_cell") and resolved != Vector3.INF else Vector2i(999999, 999999),
        "allowOutside": allow_outside,
        "movingHome": moving_home,
        "arrivalRadius": arrival_radius,
        "reason": reason,
        "cost": cost
    }

func town_anchor_candidates(entry: Dictionary) -> Array[Vector3]:
    var candidates: Array[Vector3] = []
    candidates.append(entry.get("porchPosition", Vector3.ZERO))
    candidates.append(entry.get("guardPosition", entry.get("porchPosition", Vector3.ZERO)))
    add_path_candidates(candidates, entry, false)
    add_utility_anchor_candidates(candidates, entry)
    return candidates

func job_anchor_candidates(entry: Dictionary, outside_town := true) -> Array[Vector3]:
    var candidates: Array[Vector3] = []
    if outside_town:
        add_resource_prop_candidates(candidates, entry, String(entry.get("job", "")))
        add_path_candidates(candidates, entry, true)
        var outward := outward_work_anchor(entry)
        if outward != Vector3.INF:
            candidates.append(outward)
        add_deterministic_ring_candidates(candidates, entry, true)
    else:
        add_path_candidates(candidates, entry, false)
        add_utility_anchor_candidates(candidates, entry)
        add_deterministic_ring_candidates(candidates, entry, false)
    candidates.append(entry.get("porchPosition", Vector3.ZERO))
    return candidates

func outward_work_anchor(entry: Dictionary) -> Vector3:
    if world == null or main == null:
        return Vector3.INF
    var center_cell: Vector2i = entry.get("townCenter", Vector2i.ZERO)
    var center := Vector3(float(center_cell.x) * CELL, 0.0, float(center_cell.y) * CELL)
    var porch: Vector3 = entry.get("porchPosition", center)
    var direction := porch - center
    direction.y = 0.0
    if direction.length_squared() < 0.001:
        var rng := deterministic_rng(entry, "work_anchor")
        var angle := rng.randf() * TAU
        direction = Vector3(cos(angle), 0.0, sin(angle))
    direction = direction.normalized()
    var radius := (maxf(32.0, float(entry.get("townRadius", 18))) + 4.0) * CELL
    var position := center + direction * radius
    var ground_y: float = surface_y_at_position(position)
    if ground_y < main.WATER_LEVEL + 0.55:
        return Vector3.INF
    position.y = ground_y + 0.04
    if world.point_inside_work_area(entry, position) and not world.point_inside_town(entry, position):
        return position
    return Vector3.INF

func add_path_candidates(candidates: Array[Vector3], entry: Dictionary, outside_only := false) -> void:
    if world == null:
        return
    var center: Vector2i = entry.get("townCenter", entry.get("homeCell", Vector2i.ZERO))
    var radius := maxi(6, int(entry.get("townRadius", 18)))
    var offsets: Array[int] = []
    if outside_only:
        offsets = [radius + 3, -(radius + 3)]
    else:
        var near_step := maxi(3, radius / 4)
        var far_step := maxi(near_step + 2, radius / 2)
        offsets = [0, near_step, -near_step, far_step, -far_step]
    var seen := {}
    for offset in offsets:
        for cell in [center + Vector2i(offset, 0), center + Vector2i(0, offset)]:
            var key := "%d,%d" % [cell.x, cell.y]
            if seen.has(key):
                continue
            seen[key] = true
            var pos: Vector3 = world.cell_position(cell)
            if outside_only and world.point_inside_town(entry, pos):
                continue
            if not outside_only and not world.point_inside_town(entry, pos):
                continue
            if not world.point_inside_work_area(entry, pos):
                continue
            candidates.append(pos)

func add_utility_anchor_candidates(candidates: Array[Vector3], entry: Dictionary) -> void:
    if world == null:
        return
    var service = smart_object_service()
    if service == null or not service.has_method("query_resource_nodes"):
        return
    var body := entry.get("body") as Node3D
    var origin: Vector3 = body.global_position if body != null else entry.get("porchPosition", Vector3.ZERO)
    var monitor = performance_monitor()
    var query_start: int = monitor.begin_section("npc_utility_anchor_index_query") if monitor != null else 0
    var indexed_nodes: Array[Node3D] = service.query_resource_nodes(entry, UTILITY_ANCHOR_KINDS, {
        "limit": UTILITY_ANCHOR_QUERY_LIMIT,
        "outsideTown": false,
        "insideTownOnly": true,
        "workAreaOnly": true,
        "collectAllSpatialMatches": true,
        "distanceMode": "3d",
        "blockTypes": UTILITY_ANCHOR_BLOCK_TYPES,
        "bypassCache": true
    })
    if monitor != null:
        monitor.end_section("npc_utility_anchor_index_query", query_start)
    var utility_nodes: Array[Node3D] = []
    for node in indexed_nodes:
        if node == null or not is_instance_valid(node):
            continue
        if not (String(node.get_meta("block_type", "")) in UTILITY_ANCHOR_BLOCK_TYPES):
            continue
        if not world.point_inside_town(entry, node.global_position):
            continue
        utility_nodes.append(node)
    utility_nodes.sort_custom(func(a: Node3D, b: Node3D) -> bool:
        var a_distance := a.global_position.distance_squared_to(origin)
        var b_distance := b.global_position.distance_squared_to(origin)
        if is_equal_approx(a_distance, b_distance):
            return stable_node_id(a) < stable_node_id(b)
        return a_distance < b_distance
    )
    var approach_start: int = monitor.begin_section("npc_utility_anchor_approach") if monitor != null else 0
    var added := 0
    for node in utility_nodes:
        for cell in world.approach_cells_for_target(entry, node.global_position, false):
            var pos: Vector3 = world.cell_position(cell)
            if world.point_inside_town(entry, pos):
                candidates.append(pos)
                added += 1
                break
        if added >= UTILITY_ANCHOR_LIMIT:
            break
    if monitor != null:
        monitor.end_section("npc_utility_anchor_approach", approach_start)
    entry["lastUtilityAnchorDebug"] = {
        "indexedReturned": indexed_nodes.size(),
        "acceptedUtilityNodes": utility_nodes.size(),
        "appendedApproachCandidates": added,
        "totalCandidatesAfter": candidates.size()
    }

func add_resource_prop_candidates(candidates: Array[Vector3], entry: Dictionary, job: String) -> void:
    if main == null or world == null or not (job in ["wood", "stone", "forage"]):
        return
    var body := entry.get("body") as Node3D
    var origin: Vector3 = body.global_position if body != null else entry.get("porchPosition", Vector3.ZERO)
    var outside_town_job := resource_job_uses_outside_work_area(job)
    var props: Array[Node3D] = indexed_resource_props(entry, job)
    var indexed_count := props.size()
    props = filter_job_props(entry, job, props)
    var filtered_indexed_count := props.size()
    var scanned_nodes := 0
    var scanned_props_before := props.size()
    if props.is_empty() and allow_resource_scan_fallback():
        var remaining_scan_nodes := RESOURCE_SCAN_NODE_LIMIT
        for root_value in [main.get("prop_root"), main.get("chunk_root")]:
            remaining_scan_nodes = collect_job_props(root_value as Node, entry, job, props, remaining_scan_nodes, RESOURCE_SCAN_CANDIDATE_LIMIT)
            if remaining_scan_nodes <= 0 or props.size() >= RESOURCE_SCAN_CANDIDATE_LIMIT:
                break
        scanned_nodes = RESOURCE_SCAN_NODE_LIMIT - remaining_scan_nodes
    props.sort_custom(func(a: Node3D, b: Node3D) -> bool:
        return a.global_position.distance_squared_to(origin) < b.global_position.distance_squared_to(origin)
    )
    var checked := 0
    var approach_hits := 0
    for prop in props:
        checked += 1
        if checked > 10:
            break
        var approach_cells: Array[Vector2i] = world.approach_cells_for_target(entry, prop.global_position, true)
        var added_for_prop := false
        for cell in approach_cells:
            var pos: Vector3 = world.cell_position(cell)
            if job_position_allowed(entry, pos, outside_town_job):
                candidates.append(pos)
                added_for_prop = true
                approach_hits += 1
                break
        if not added_for_prop:
            continue
    entry["lastResourceCandidateDebug"] = {
        "job": job,
        "outsideTown": outside_town_job,
        "indexed": indexed_count,
        "filteredIndexed": filtered_indexed_count,
        "scannedNodes": scanned_nodes,
        "scanAdded": props.size() - scanned_props_before,
        "checked": checked,
        "approachHits": approach_hits,
        "positions": candidates.size()
    }

func indexed_resource_props(entry: Dictionary, job: String) -> Array[Node3D]:
    var service = smart_object_service()
    if service == null or not service.has_method("query_resource_nodes"):
        return []
    var options := {
        "limit": RESOURCE_SCAN_CANDIDATE_LIMIT,
        "outsideTown": resource_job_uses_outside_work_area(job),
        "workAreaOnly": true,
        "chunkRadius": 2,
        "cacheFrames": 30
    }
    if job == "forage":
        options["drops"] = ItemCatalogScript.forage_food_ids()
    return service.query_resource_nodes(entry, resource_kinds_for_job(job), options)

func resource_job_uses_outside_work_area(job: String) -> bool:
    return job == "forage"

func filter_job_props(entry: Dictionary, job: String, props: Array[Node3D]) -> Array[Node3D]:
    var filtered: Array[Node3D] = []
    for prop in props:
        if prop_matches_job(prop, entry, job):
            filtered.append(prop)
    return filtered

func smart_object_service():
    if system == null or not system.has_method("smart_object_service"):
        return null
    return system.smart_object_service()

func performance_monitor():
    if system == null or not system.has_method("performance_monitor"):
        return null
    return system.performance_monitor()

func resource_kinds_for_job(job: String) -> Array:
    if job == "wood":
        return ["tree_source"]
    if job == "stone":
        return ["stone_source"]
    if job == "forage":
        return ["forage_source"]
    return []

func allow_resource_scan_fallback() -> bool:
    return OS.get_environment("VOXEL_NPC_ALLOW_RESOURCE_SCAN") == "1"

func collect_job_props(root: Node, entry: Dictionary, job: String, props: Array[Node3D], max_nodes: int, max_props: int) -> int:
    if root == null or max_nodes <= 0 or props.size() >= max_props:
        return max_nodes
    var stack: Array[Node] = [root]
    var scanned := 0
    while not stack.is_empty() and scanned < max_nodes and props.size() < max_props:
        var node := stack.pop_back() as Node
        scanned += 1
        if node == null:
            continue
        if node is Node3D and prop_matches_job(node as Node3D, entry, job):
            props.append(node as Node3D)
        for child in node.get_children():
            stack.append(child)
    return max_nodes - scanned

func prop_matches_job(prop: Node3D, entry: Dictionary, job: String) -> bool:
    if not is_instance_valid(prop) or bool(prop.get_meta("npc_harvested", false)):
        return false
    if String(prop.get_meta("kind", "")) != "prop":
        return false
    if not world.point_inside_work_area(entry, prop.global_position):
        return false
    if surface_y_at_position(prop.global_position) < main.WATER_LEVEL + 0.45:
        return false
    var material := String(prop.get_meta("material", ""))
    var drop := String(prop.get_meta("drop", ""))
    if job == "wood":
        return material == "tree" or drop == "logs"
    if job == "stone":
        return material in ["rock", "copperOre", "ironOre"] or drop in ["stones", "copperOre", "ironOre"]
    if job == "forage":
        return ItemCatalogScript.is_forage_food(drop)
    return false

func job_position_allowed(entry: Dictionary, position: Vector3, outside_town_job: bool) -> bool:
    if not world.point_inside_work_area(entry, position):
        return false
    if outside_town_job:
        return not world.point_inside_town(entry, position)
    return world.point_inside_town(entry, position)

func guard_post_candidates(entry: Dictionary) -> Array[Vector3]:
    var assigned_guard_post: Vector3 = entry.get("guardPosition", entry.get("porchPosition", Vector3.ZERO))
    var candidates: Array[Vector3] = [assigned_guard_post]
    if assigned_guard_post == Vector3.INF:
        return [entry.get("porchPosition", Vector3.ZERO)]
    if world != null and assigned_guard_post != Vector3.INF:
        var guard_cell: Vector2i = world.world_cell(assigned_guard_post)
        for radius in range(1, 3):
            for dx in range(-radius, radius + 1):
                for dz in range(-radius, radius + 1):
                    if max(absi(dx), absi(dz)) != radius:
                        continue
                    candidates.append(world.cell_position(guard_cell + Vector2i(dx, dz)))
    return candidates

func advance_hostile_intercept_selection(entry: Dictionary, hostile: Node3D, melee := false) -> Dictionary:
    var hostile_cell: Vector2i = world.world_cell(hostile.global_position)
    var hostile_key := str(hostile.get_instance_id())
    var selection: Dictionary = entry.get("_guardInterceptSelection", {}) if entry.get("_guardInterceptSelection", {}) is Dictionary else {}
    var selection_matches: bool = String(selection.get("hostileKey", "")) == hostile_key \
        and selection.get("hostileCell", INVALID_CELL) == hostile_cell \
        and bool(selection.get("melee", false)) == melee
    if not selection_matches:
        selection = {
            "hostileKey": hostile_key,
            "hostileCell": hostile_cell,
            "melee": melee,
            "cells": hostile_intercept_candidate_cells(hostile_cell, melee),
            "nextIndex": 0,
            "candidates": []
        }
    var cells: Array = selection.get("cells", []) if selection.get("cells", []) is Array else []
    var candidates: Array = selection.get("candidates", []) if selection.get("candidates", []) is Array else []
    var next_index := int(selection.get("nextIndex", 0))
    var evaluated := 0
    while next_index < cells.size() and evaluated < GUARD_INTERCEPT_CANDIDATES_PER_CALL:
        var cell_value = cells[next_index]
        next_index += 1
        evaluated += 1
        if not (cell_value is Vector2i):
            continue
        var cell: Vector2i = cell_value
        var position: Vector3 = world.cell_position(cell)
        if not world.point_inside_work_area(entry, position):
            continue
        var surface_y := surface_y_at_position(position)
        if surface_y < main.WATER_LEVEL + 0.45:
            continue
        candidates.append({ "position": position, "surfaceY": surface_y })
    selection["nextIndex"] = next_index
    selection["candidates"] = candidates
    if next_index < cells.size():
        entry["_guardInterceptSelection"] = selection
        entry["guardInterceptSelectionPending"] = true
        return {
            "status": "pending",
            "evaluated": evaluated,
            "remaining": cells.size() - next_index
        }
    clear_hostile_intercept_selection(entry)
    return {
        "status": "ready",
        "target": choose_nearest_hostile_intercept_anchor(entry, candidates),
        "evaluated": evaluated,
        "candidateCount": candidates.size()
    }

func hostile_intercept_candidate_cells(hostile_cell: Vector2i, melee := false) -> Array[Vector2i]:
    var cells: Array[Vector2i] = []
    var min_radius := 1 if melee else 3
    var max_radius := 2 if melee else 6
    var radii := [min_radius, max_radius]
    for radius_value in radii:
        var radius: int = int(radius_value)
        for direction in GUARD_INTERCEPT_DIRECTIONS:
            cells.append(hostile_cell + direction * radius)
    return cells

func choose_nearest_hostile_intercept_anchor(entry: Dictionary, candidates: Array) -> Vector3:
    var body := entry.get("body") as Node3D
    var origin: Vector3 = body.global_position if body != null else entry.get("guardPosition", Vector3.ZERO)
    var ordered: Array = []
    var seen := {}
    for candidate in candidates:
        if not (candidate is Dictionary):
            continue
        var position: Vector3 = candidate.get("position", Vector3.INF)
        if position == Vector3.INF:
            continue
        var key := position_key(position)
        if seen.has(key):
            continue
        seen[key] = true
        ordered.append(candidate)
    ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        var a_position: Vector3 = a.get("position", Vector3.INF)
        var b_position: Vector3 = b.get("position", Vector3.INF)
        var a_distance := a_position.distance_squared_to(origin)
        var b_distance := b_position.distance_squared_to(origin)
        if is_equal_approx(a_distance, b_distance):
            return position_key(a_position) < position_key(b_position)
        return a_distance < b_distance
    )
    for candidate in ordered:
        var position: Vector3 = candidate.get("position", Vector3.INF)
        if not world.point_allowed(entry, position, true, false):
            continue
        if float(candidate.get("surfaceY", -INF)) < main.WATER_LEVEL + 0.45:
            continue
        return position
    return Vector3.INF

func clear_hostile_intercept_selection(entry: Dictionary) -> void:
    entry.erase("_guardInterceptSelection")
    entry.erase("guardInterceptSelectionPending")

func position_can_be_goal(entry: Dictionary, position: Vector3, allow_outside := false, moving_home := false) -> bool:
    if position == Vector3.INF:
        return false
    if not world.point_allowed(entry, position, allow_outside, moving_home):
        return false
    if world.has_method("cell_is_standable_goal"):
        var cell: Vector2i = world.world_cell(position) if world.has_method("world_cell") else Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))
        if not bool(world.cell_is_standable_goal(entry, cell, allow_outside, moving_home)):
            return false
    return surface_y_at_position(position) >= main.WATER_LEVEL + 0.45

func position_can_be_static_goal(entry: Dictionary, position: Vector3, allow_outside := false, moving_home := false) -> bool:
    if position == Vector3.INF:
        return false
    if not world.point_allowed(entry, position, allow_outside, moving_home):
        return false
    var cell: Vector2i = world.world_cell(position) if world.has_method("world_cell") else Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))
    if world.has_method("cell_is_static_standable_goal"):
        if not bool(world.cell_is_static_standable_goal(entry, cell, allow_outside, moving_home)):
            return false
    elif world.has_method("cell_is_standable_goal"):
        if not bool(world.cell_is_standable_goal(entry, cell, allow_outside, moving_home)):
            return false
    return surface_y_at_position(position) >= main.WATER_LEVEL + 0.45

func unique_positions(candidates: Array[Vector3]) -> Array[Vector3]:
    var result: Array[Vector3] = []
    var seen := {}
    for pos in candidates:
        if pos == Vector3.INF:
            continue
        var key := position_key(pos)
        if seen.has(key):
            continue
        seen[key] = true
        result.append(pos)
    return result

func position_key(pos: Vector3) -> String:
    return "%d,%d" % [roundi(pos.x / CELL), roundi(pos.z / CELL)]

func set_goal_fallback(entry: Dictionary, status: String, reason: String) -> void:
    NpcRouteStateStoreScript.write_status(entry, status, reason, "NpcSemanticGoalPlanner.goal_fallback")

func clear_goal_fallback(entry: Dictionary) -> void:
    if String(entry.get("routeReason", "")).begins_with("no_reachable_"):
        NpcRouteStateStoreScript.write_reason(entry, "", "NpcSemanticGoalPlanner.clear_goal_fallback")

func add_deterministic_ring_candidates(candidates: Array[Vector3], entry: Dictionary, outside_town := false) -> void:
    var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
    var town_radius: float = maxf(32.0, float(entry.get("townRadius", 18))) if outside_town else float(entry.get("townRadius", 18))
    var job: String = String(entry.get("job", "wander"))
    var rng: RandomNumberGenerator = deterministic_rng(entry, "job" if outside_town else "wander")
    for attempt in range(10):
        var base_radius: float = town_radius + rng.randf_range(5.0, 16.0) if outside_town else rng.randf_range(2.5, maxf(4.5, town_radius - 4.0))
        if outside_town and job == "stone":
            base_radius += rng.randf_range(4.0, 9.0)
        var angle: float = rng.randf() * TAU + float(attempt) * 0.29
        var position: Vector3 = Vector3(float(center.x) * CELL + cos(angle) * base_radius * CELL, 0.0, float(center.y) * CELL + sin(angle) * base_radius * CELL)
        var ground_y: float = surface_y_at_position(position)
        if ground_y < main.WATER_LEVEL + 0.5:
            continue
        position.y = ground_y + 0.04
        if outside_town:
            if world.point_inside_work_area(entry, position) and not world.point_inside_town(entry, position):
                candidates.append(position)
        elif world.point_inside_town(entry, position):
            candidates.append(position)

func add_forage_search_sweep_candidates(candidates: Array[Vector3], entry: Dictionary) -> void:
    if world == null or main == null:
        return
    var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
    var center_position := Vector3(float(center.x) * CELL, 0.0, float(center.y) * CELL)
    var home: Vector3 = entry.get("homePosition", entry.get("porchPosition", center_position))
    var search_serial := int(entry.get("forageSearchSerial", 0))
    var direction := home - center_position
    direction.y = 0.0
    if direction.length_squared() < 0.001:
        var fallback_rng := deterministic_rng(entry, "forage_search_direction")
        var fallback_angle := fallback_rng.randf() * TAU
        direction = Vector3(cos(fallback_angle), 0.0, sin(fallback_angle))
    direction = direction.normalized()
    var base_radius := maxf(float(entry.get("townRadius", 18)) + 7.0, 24.0)
    var angles := [
        0.0,
        0.58,
        -0.58,
        1.15,
        -1.15,
        PI
    ]
    for index in range(angles.size()):
        var serial_turn := float((search_serial + index) % angles.size()) * 0.41
        var angle := atan2(direction.z, direction.x) + float(angles[index]) + serial_turn
        var radius_cells := base_radius + float((search_serial + index * 3) % 10)
        var position := Vector3(float(center.x) * CELL + cos(angle) * radius_cells * CELL, 0.0, float(center.y) * CELL + sin(angle) * radius_cells * CELL)
        var ground_y := surface_y_at_position(position)
        if ground_y < main.WATER_LEVEL + 0.5:
            continue
        position.y = ground_y + 0.04
        if world.point_inside_work_area(entry, position) and not world.point_inside_town(entry, position):
            candidates.append(position)

func deterministic_rng(entry: Dictionary, goal_kind: String) -> RandomNumberGenerator:
    var rng := RandomNumberGenerator.new()
    var seed_text: String = ""
    if main != null:
        var seed_value = main.get("seed_text")
        if seed_value != null:
            seed_text = String(seed_value)
        if seed_text == "":
            seed_value = main.get("world_seed")
            if seed_value != null:
                seed_text = String(seed_value)
    var search_serial := int(entry.get("forageSearchSerial", 0)) if String(entry.get("job", "")) == "forage" else 0
    var key: String = "%s:%s:%s:%s:%d" % [
        seed_text,
        String(entry.get("id", "npc")),
        goal_kind,
        String(entry.get("jobPhase", "")),
        int(entry.get("jobRuns", 0)) + search_serial
    ]
    rng.seed = hash(key)
    return rng
