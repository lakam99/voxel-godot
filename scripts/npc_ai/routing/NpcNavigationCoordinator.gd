extends RefCounted
class_name NpcNavigationCoordinator

const GeneratedWorldNavigationAdapterScript := preload("res://scripts/npc_ai/navigation/GeneratedWorldNavigationAdapter.gd")
const NpcRouteCoordinatorAdapterScript := preload("res://scripts/npc_ai/routing/NpcRouteCoordinatorAdapter.gd")
const NpcRouteMovementControllerScript := preload("res://scripts/npc_ai/movement/NpcRouteMovementController.gd")
const NpcSemanticGoalPlannerScript := preload("res://scripts/npc_ai/behavior/NpcSemanticGoalPlanner.gd")

const CELL := 1.35

var system
var main
var navigation_world
var route_planner
var locomotion
var goal_planner
var route_repair

func setup(system_node, main_node) -> void:
    system = system_node
    main = main_node
    navigation_world = GeneratedWorldNavigationAdapterScript.new()
    navigation_world.setup(system, main)
    route_planner = NpcRouteCoordinatorAdapterScript.new()
    route_planner.setup(system, main, navigation_world)
    route_repair = route_planner.get("repair_service")
    locomotion = NpcRouteMovementControllerScript.new()
    locomotion.setup(system, main)
    goal_planner = NpcSemanticGoalPlannerScript.new()
    goal_planner.setup(system, main, navigation_world, route_planner)

func begin_frame() -> void:
    if route_planner != null and route_planner.has_method("begin_frame"):
        route_planner.begin_frame()
    if locomotion != null:
        locomotion.begin_frame()

func invalidate() -> void:
    if navigation_world != null:
        navigation_world.invalidate()
    if route_planner != null and route_planner.has_method("invalidate"):
        route_planner.invalidate()

func process_navigation_events(events: Array, max_expansions := 128) -> Array[Dictionary]:
    if navigation_world != null and navigation_world.has_method("apply_navigation_events"):
        navigation_world.apply_navigation_events(events)
    if route_planner == null or not route_planner.has_method("process_navigation_events"):
        return []
    return route_planner.process_navigation_events(events, max_expansions)

func cleanup_actor_state(actor_id: String) -> Dictionary:
    if locomotion == null or not locomotion.has_method("cleanup_actor_state"):
        return { "avoidance": 0, "reason": "missing_locomotion" }
    return locomotion.cleanup_actor_state(actor_id)

func classify_navigation_event(event: Dictionary) -> Dictionary:
    var result := {}
    if route_repair == null:
        return result
    for route_id in route_repair.routes_for_event(event):
        result[String(route_id)] = route_repair.classify_event(String(route_id), event)
    return result

func move_npc(entry: Dictionary, target: Vector3, max_distance: float, moving_home := false, allow_outside := false, physics_delta := 0.0166667) -> float:
    var body := entry.get("body") as CharacterBody3D
    if body == null or max_distance <= 0.0 or goal_planner == null or locomotion == null:
        return 0.0
    var intent: Dictionary = goal_planner.make_intent(entry, target, max_distance, moving_home, allow_outside)
    intent["physicsDelta"] = physics_delta
    var result: Dictionary = locomotion.move(entry, intent, max_distance, route_planner, navigation_world)
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

func route_cost(entry: Dictionary, target: Vector3, allow_outside := false, moving_home := false, arrival_radius := CELL * 0.85, approach_cells: Array = []) -> float:
    if route_planner == null:
        return INF
    return route_planner.route_cost(entry, target, allow_outside, moving_home, arrival_radius, approach_cells)

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
