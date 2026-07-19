extends RefCounted
class_name NpcPathing

const NpcNavigationCoordinatorScript := preload("res://scripts/npc_ai/routing/NpcNavigationCoordinator.gd")

const CELL := 1.35
const NO_DETOUR := Vector3(9999999.0, 9999999.0, 9999999.0)

var system
var main
var coordinator
var navigation_world
var route_planner
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
    var coordinator_ready := coordinator != null \
        and coordinator.get("navigation_world") != null \
        and coordinator.get("route_planner") != null \
        and coordinator.get("locomotion") != null \
        and coordinator.get("goal_planner") != null
    if coordinator_ready:
        return
    coordinator = NpcNavigationCoordinatorScript.new()
    coordinator.setup(system, main)
    navigation_world = coordinator.get("navigation_world")
    route_planner = coordinator.get("route_planner")
    locomotion = coordinator.get("locomotion")
    goal_planner = coordinator.get("goal_planner")
    route_repair = coordinator.get("route_repair")

func prebake_town(center_cell: Vector2i, radius_cells: int) -> Dictionary:
    ensure_ready()
    if coordinator == null or not coordinator.has_method("prebake_town"):
        return { "ok": false, "reason": "missing_coordinator" }
    return coordinator.prebake_town(center_cell, radius_cells)

func begin_frame() -> void:
    ensure_ready()
    if coordinator != null:
        coordinator.begin_frame()

func stats() -> Dictionary:
    ensure_ready()
    if coordinator != null and coordinator.has_method("stats"):
        var stats_value = coordinator.stats()
        return stats_value if stats_value is Dictionary else {}
    return {}

func invalidate() -> void:
    ensure_ready()
    if coordinator != null:
        coordinator.invalidate()

func process_navigation_events(events: Array, max_expansions := 128) -> Array[Dictionary]:
    ensure_ready()
    if coordinator == null:
        return []
    return coordinator.process_navigation_events(events, max_expansions)

func cleanup_actor_state(actor_id: String) -> Dictionary:
    ensure_ready()
    if coordinator == null or not coordinator.has_method("cleanup_actor_state"):
        return { "avoidance": 0, "reason": "missing_coordinator" }
    return coordinator.cleanup_actor_state(actor_id)

func cleanup_all() -> Dictionary:
    ensure_ready()
    if coordinator == null or not coordinator.has_method("cleanup_all"):
        return { "avoidance": 0, "reason": "missing_coordinator" }
    return coordinator.cleanup_all()

func shutdown_for_process_exit() -> Dictionary:
    # Normal cleanup keeps this facade usable for a world reset.  Exit is a
    # terminal lifecycle: release the coordinator graph and its reciprocal
    # route-readiness services rather than letting RefCounted cycles survive
    # until engine resource cleanup.
    var result := { "avoidance": 0, "reason": "missing_coordinator" }
    if coordinator != null and coordinator.has_method("shutdown_for_process_exit"):
        result = coordinator.shutdown_for_process_exit()
    elif coordinator != null and coordinator.has_method("cleanup_all"):
        result = coordinator.cleanup_all()
    coordinator = null
    navigation_world = null
    route_planner = null
    locomotion = null
    goal_planner = null
    route_repair = null
    system = null
    main = null
    return result

func move_npc(entry: Dictionary, target: Vector3, max_distance: float, moving_home := false, allow_outside := false, physics_delta := 0.0166667) -> float:
    ensure_ready()
    if coordinator == null:
        return 0.0
    return coordinator.move_npc(entry, target, max_distance, moving_home, allow_outside, physics_delta)

func choose_day_target(entry: Dictionary) -> Vector3:
    ensure_ready()
    if coordinator == null:
        return entry.get("porchPosition", Vector3.ZERO)
    return coordinator.choose_day_target(entry)

func choose_job_target(entry: Dictionary) -> Vector3:
    ensure_ready()
    if coordinator == null:
        return entry.get("porchPosition", Vector3.ZERO)
    return coordinator.choose_job_target(entry)

func choose_guard_target(entry: Dictionary, target_hostile: Node3D = null, melee := false) -> Vector3:
    ensure_ready()
    if coordinator == null:
        return entry.get("guardPosition", entry.get("porchPosition", Vector3.ZERO))
    return coordinator.choose_guard_target(entry, target_hostile, melee)

func choose_forage_target(entry: Dictionary, candidates: Array[Node3D]) -> Node3D:
    ensure_ready()
    if coordinator == null:
        return candidates[0] if not candidates.is_empty() else null
    return coordinator.choose_forage_target(entry, candidates)

func forage_target_position(entry: Dictionary, target_node: Node3D) -> Vector3:
    ensure_ready()
    if coordinator == null or target_node == null:
        return target_node.global_position if target_node != null else Vector3.ZERO
    return coordinator.forage_target_position(entry, target_node)

func route_cost(entry: Dictionary, target: Vector3, allow_outside := false, moving_home := false, arrival_radius := CELL * 0.85, approach_cells: Array = [], require_ready := false) -> float:
    ensure_ready()
    if coordinator == null:
        return INF
    return coordinator.route_cost(entry, target, allow_outside, moving_home, arrival_radius, approach_cells, require_ready)

func point_inside_town(entry: Dictionary, position: Vector3) -> bool:
    ensure_ready()
    if coordinator == null:
        return false
    return coordinator.point_inside_town(entry, position)

func point_inside_work_area(entry: Dictionary, position: Vector3) -> bool:
    ensure_ready()
    if coordinator == null:
        return false
    return coordinator.point_inside_work_area(entry, position)

func world_cell(position: Vector3) -> Vector2i:
    ensure_ready()
    if coordinator == null:
        return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))
    return coordinator.world_cell(position)

func path_cell_position(cell: Vector2i) -> Vector3:
    ensure_ready()
    if coordinator == null:
        return Vector3(float(cell.x) * CELL, 0.0, float(cell.y) * CELL)
    return coordinator.path_cell_position(cell)
