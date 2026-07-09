extends RefCounted
class_name NpcNavigationCoordinator

const GeneratedWorldNavigationAdapterScript := preload("res://scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd")
const NpcRouteCoordinatorAdapterScript := preload("res://scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd")
const NpcRouteAuthorityScript := preload("res://scripts/npc_ai/routing/NpcRouteAuthority.gd")
const NpcRouteTicketBrokerScript := preload("res://scripts/npc_ai/routing/NpcRouteTicketBroker.gd")
const NpcRouteMovementControllerScript := preload("res://scripts/npc_ai/movement/NpcRouteMovementController.gd")
const NpcSemanticGoalPlannerScript := preload("res://scripts/npc_ai/behavior/NpcSemanticGoalPlanner.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

const CELL := 1.35
const ROUTE_MOTION_MAX_SUBSTEP_DISTANCE := CELL * 0.55
const ROUTE_MOTION_MAX_SUBSTEPS := 48

var system
var main
var navigation_world
var route_delegate
var route_planner
var route_ticket_broker
var locomotion
var goal_planner
var route_repair

func setup(system_node, main_node) -> void:
    system = system_node
    main = main_node
    ensure_ready()

func ensure_ready() -> void:
    if system == null or main == null:
        return
    if navigation_world == null:
        navigation_world = GeneratedWorldNavigationAdapterScript.new()
        navigation_world.setup(system, main)
    if route_planner == null:
        route_delegate = NpcRouteCoordinatorAdapterScript.new()
        route_delegate.setup(system, main, navigation_world)
        route_planner = NpcRouteAuthorityScript.new()
        route_planner.setup(system, main, navigation_world, route_delegate)
        route_repair = route_planner.get("repair_service")
        if route_ticket_broker == null:
            route_ticket_broker = NpcRouteTicketBrokerScript.new()
            route_ticket_broker.setup(system, main, navigation_world, route_planner)
    elif route_repair == null:
        route_repair = route_planner.get("repair_service")
    if route_ticket_broker == null:
        route_ticket_broker = NpcRouteTicketBrokerScript.new()
        route_ticket_broker.setup(system, main, navigation_world, route_planner)
    if locomotion == null:
        locomotion = NpcRouteMovementControllerScript.new()
        locomotion.setup(system, main)
    if goal_planner == null:
        goal_planner = NpcSemanticGoalPlannerScript.new()
        goal_planner.setup(system, main, navigation_world, route_planner)

func rebuild() -> void:
    navigation_world = GeneratedWorldNavigationAdapterScript.new()
    navigation_world.setup(system, main)
    route_delegate = NpcRouteCoordinatorAdapterScript.new()
    route_delegate.setup(system, main, navigation_world)
    route_planner = NpcRouteAuthorityScript.new()
    route_planner.setup(system, main, navigation_world, route_delegate)
    route_repair = route_planner.get("repair_service")
    route_ticket_broker = NpcRouteTicketBrokerScript.new()
    route_ticket_broker.setup(system, main, navigation_world, route_planner)
    locomotion = NpcRouteMovementControllerScript.new()
    locomotion.setup(system, main)
    goal_planner = NpcSemanticGoalPlannerScript.new()
    goal_planner.setup(system, main, navigation_world, route_planner)

func prebake_town(center_cell: Vector2i, radius_cells: int) -> Dictionary:
    ensure_ready()
    if route_planner != null and route_planner.has_method("prebake_area_tiles"):
        return route_planner.prebake_area_tiles(center_cell, radius_cells)
    return { "ok": false, "reason": "missing_route_planner" }

func begin_frame() -> void:
    ensure_ready()
    if route_planner != null and route_planner.has_method("begin_frame"):
        route_planner.begin_frame()
    if route_ticket_broker != null and route_ticket_broker.has_method("begin_frame"):
        route_ticket_broker.begin_frame()
    if locomotion != null:
        locomotion.begin_frame()

func stats() -> Dictionary:
    ensure_ready()
    var result := {}
    if route_planner != null and route_planner.has_method("stats"):
        var route_stats = route_planner.stats()
        result["routePlanner"] = route_stats if route_stats is Dictionary else {}
    if route_ticket_broker != null and route_ticket_broker.has_method("stats"):
        var ticket_stats = route_ticket_broker.stats()
        result["routeTickets"] = ticket_stats if ticket_stats is Dictionary else {}
    if navigation_world != null and navigation_world.has_method("stats"):
        var world_stats = navigation_world.stats()
        result["navigationWorld"] = world_stats if world_stats is Dictionary else {}
    return result

func invalidate() -> void:
    ensure_ready()
    if navigation_world != null:
        navigation_world.invalidate()
    if route_planner != null and route_planner.has_method("invalidate"):
        route_planner.invalidate()
    if route_ticket_broker != null and route_ticket_broker.has_method("invalidate"):
        route_ticket_broker.invalidate()

func process_navigation_events(events: Array, max_expansions := 128) -> Array[Dictionary]:
    ensure_ready()
    if navigation_world != null and navigation_world.has_method("apply_navigation_events"):
        navigation_world.apply_navigation_events(events)
    if route_planner == null or not route_planner.has_method("process_navigation_events"):
        return []
    return route_planner.process_navigation_events(events, max_expansions)

func cleanup_actor_state(actor_id: String) -> Dictionary:
    ensure_ready()
    if locomotion == null or not locomotion.has_method("cleanup_actor_state"):
        return { "avoidance": 0, "reason": "missing_locomotion" }
    return locomotion.cleanup_actor_state(actor_id)

func cleanup_all() -> Dictionary:
    ensure_ready()
    if locomotion == null or not locomotion.has_method("cleanup_all"):
        return { "avoidance": 0, "reason": "missing_locomotion" }
    return locomotion.cleanup_all()

func classify_navigation_event(event: Dictionary) -> Dictionary:
    ensure_ready()
    var result := {}
    if route_repair == null:
        return result
    for route_id in route_repair.routes_for_event(event):
        result[String(route_id)] = route_repair.classify_event(String(route_id), event)
    return result

func move_npc(entry: Dictionary, target: Vector3, max_distance: float, moving_home := false, allow_outside := false, physics_delta := 0.0166667) -> float:
    ensure_ready()
    var body := entry.get("body") as CharacterBody3D
    if body == null or max_distance <= 0.0 or goal_planner == null or locomotion == null:
        return 0.0
    var substeps := clampi(ceili(max_distance / ROUTE_MOTION_MAX_SUBSTEP_DISTANCE), 1, ROUTE_MOTION_MAX_SUBSTEPS)
    if substeps <= 1:
        return _move_npc_step(entry, target, max_distance, moving_home, allow_outside, physics_delta)
    var total_moved := 0.0
    var remaining_distance := max_distance
    var remaining_delta := maxf(0.0001, physics_delta)
    for step_index in range(substeps):
        if remaining_distance <= 0.001:
            break
        var steps_left := maxi(1, substeps - step_index)
        var step_distance := minf(ROUTE_MOTION_MAX_SUBSTEP_DISTANCE, remaining_distance)
        var step_delta := remaining_delta / float(steps_left)
        var moved := _move_npc_step(entry, target, step_distance, moving_home, allow_outside, step_delta)
        total_moved += moved
        remaining_distance -= step_distance
        remaining_delta = maxf(0.0001, remaining_delta - step_delta)
        var status := String(entry.get("routeStatus", ""))
        if status in ["arrived", "blocked", "unreachable", "pending", "waiting"] and moved <= 0.001:
            break
    return total_moved

func _move_npc_step(entry: Dictionary, target: Vector3, max_distance: float, moving_home := false, allow_outside := false, physics_delta := 0.0166667) -> float:
    if max_distance <= 0.0:
        return 0.0
    var intent: Dictionary = goal_planner.make_intent(entry, target, max_distance, moving_home, allow_outside)
    intent["physicsDelta"] = physics_delta
    var planner_for_movement = route_ticket_broker if NpcConstantsScript.NPC_NAV_ENABLE_ROUTE_TICKET_PIPELINE and route_ticket_broker != null else route_planner
    var result: Dictionary = locomotion.move(entry, intent, max_distance, planner_for_movement, navigation_world)
    return float(result.get("moved", 0.0))

func choose_day_target(entry: Dictionary) -> Vector3:
    if goal_planner == null:
        return entry.get("porchPosition", Vector3.ZERO)
    return goal_planner.choose_day_target(entry)

func choose_job_target(entry: Dictionary) -> Vector3:
    if goal_planner == null:
        return entry.get("porchPosition", Vector3.ZERO)
    return goal_planner.choose_job_target(entry)

func choose_guard_target(entry: Dictionary, target_hostile: Node3D = null, melee := false) -> Vector3:
    if goal_planner == null:
        return entry.get("guardPosition", entry.get("porchPosition", Vector3.ZERO))
    return goal_planner.choose_guard_target(entry, target_hostile, melee)

func choose_forage_target(entry: Dictionary, candidates: Array[Node3D]) -> Node3D:
    if goal_planner == null:
        return candidates[0] if not candidates.is_empty() else null
    return goal_planner.choose_best_forage(entry, candidates)

func forage_target_position(entry: Dictionary, target_node: Node3D) -> Vector3:
    if goal_planner == null or target_node == null:
        return target_node.global_position if target_node != null else Vector3.ZERO
    return goal_planner.forage_target_position(entry, target_node)

func route_cost(entry: Dictionary, target: Vector3, allow_outside := false, moving_home := false, arrival_radius := CELL * 0.85, approach_cells: Array = [], require_ready := false) -> float:
    if route_planner == null:
        return INF
    return route_planner.route_cost(entry, target, allow_outside, moving_home, arrival_radius, approach_cells, require_ready)

func point_inside_town(entry: Dictionary, position: Vector3) -> bool:
    if navigation_world == null:
        var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
        var radius := float(entry.get("townRadius", 18)) * CELL
        var flat := Vector2(position.x - float(center.x) * CELL, position.z - float(center.y) * CELL)
        return flat.length() <= radius
    return navigation_world.point_inside_town(entry, position)

func point_inside_work_area(entry: Dictionary, position: Vector3) -> bool:
    if navigation_world == null:
        var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
        var radius := (float(entry.get("townRadius", 18)) + 24.0) * CELL
        var flat := Vector2(position.x - float(center.x) * CELL, position.z - float(center.y) * CELL)
        return flat.length() <= radius
    return navigation_world.point_inside_work_area(entry, position)

func world_cell(position: Vector3) -> Vector2i:
    if navigation_world == null:
        return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))
    return navigation_world.world_cell(position)

func path_cell_position(cell: Vector2i) -> Vector3:
    if navigation_world == null:
        return Vector3(float(cell.x) * CELL, 0.0, float(cell.y) * CELL)
    return navigation_world.cell_position(cell)
