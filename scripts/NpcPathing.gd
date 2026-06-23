extends RefCounted
class_name NpcPathing

const CELL := 1.35
const NO_DETOUR := Vector3(9999999.0, 9999999.0, 9999999.0)

var system
var main

func setup(system_node, main_node) -> void:
    system = system_node
    main = main_node

func move_npc(entry: Dictionary, target: Vector3, max_distance: float, moving_home := false, allow_outside := false) -> float:
    var body := entry.get("body") as StaticBody3D
    if body == null or max_distance <= 0.0:
        return 0.0
    var previous := body.global_position
    var path_waypoints: Array = entry.get("pathWaypoints", [])
    if not path_waypoints.is_empty():
        var waypoint: Vector3 = path_waypoints[0]
        if previous.distance_to(waypoint) <= CELL * 0.52:
            path_waypoints.remove_at(0)
            entry["pathWaypoints"] = path_waypoints
            if not path_waypoints.is_empty():
                waypoint = path_waypoints[0]
        if not path_waypoints.is_empty():
            var path_step := npc_attempt_step(entry, previous, waypoint, max_distance, moving_home, allow_outside)
            if bool(path_step.get("ok", false)):
                return commit_npc_step(body, previous, path_step)
            entry["pathWaypoints"] = []

    var detour: Vector3 = entry.get("detourTarget", NO_DETOUR)
    if has_detour(detour) and float(entry.get("detourTimer", 0.0)) > 0.0:
        if previous.distance_to(detour) <= CELL * 0.65:
            entry["detourTarget"] = NO_DETOUR
            entry["detourTimer"] = 0.0
        else:
            var detour_step := npc_attempt_step(entry, previous, detour, max_distance, moving_home, allow_outside)
            if bool(detour_step.get("ok", false)):
                return commit_npc_step(body, previous, detour_step)
            entry["detourTarget"] = NO_DETOUR
            entry["detourTimer"] = 0.0

    if not npc_straight_route_crosses_blocked(previous, target):
        var direct_step := npc_attempt_step(entry, previous, target, max_distance, moving_home, allow_outside)
        if bool(direct_step.get("ok", false)):
            entry["blockedMoveTime"] = 0.0
            entry["pathWaypoints"] = []
            return commit_npc_step(body, previous, direct_step)

    entry["blockedMoveTime"] = float(entry.get("blockedMoveTime", 0.0)) + max_distance
    system.npc_blocked_moves += 1
    if float(entry.get("pathRefreshTimer", 0.0)) <= 0.0:
        var path := compute_npc_path(entry, target, moving_home, allow_outside)
        entry["pathRefreshTimer"] = 1.15
        if not path.is_empty():
            entry["pathWaypoints"] = path
            system.npc_path_detours += 1
            var path_target: Vector3 = path[0]
            var first_path_step := npc_attempt_step(entry, previous, path_target, max_distance, moving_home, allow_outside)
            if bool(first_path_step.get("ok", false)):
                return commit_npc_step(body, previous, first_path_step)

    var new_detour := choose_detour_target(entry, target, moving_home, allow_outside)
    if has_detour(new_detour):
        entry["detourTarget"] = new_detour
        entry["detourTimer"] = 2.8
        system.npc_path_detours += 1
        var sidestep := npc_attempt_step(entry, previous, new_detour, max_distance, moving_home, allow_outside)
        if bool(sidestep.get("ok", false)):
            return commit_npc_step(body, previous, sidestep)
    return 0.0

func has_detour(detour: Vector3) -> bool:
    return absf(detour.x) < 1000000.0 and absf(detour.y) < 1000000.0 and absf(detour.z) < 1000000.0

func npc_attempt_step(entry: Dictionary, previous: Vector3, target: Vector3, max_distance: float, moving_home: bool, allow_outside: bool) -> Dictionary:
    var body := entry.get("body") as StaticBody3D
    var delta := target - previous
    delta.y = 0.0
    var distance := delta.length()
    if body == null or distance < 0.04:
        return { "ok": false }
    var step := delta.normalized() * minf(max_distance, distance)
    var candidate := previous + step
    var validated := validate_npc_candidate(entry, body, previous, candidate, moving_home, allow_outside)
    if not bool(validated.get("ok", false)):
        return validated
    validated["step"] = step
    return validated

func validate_npc_candidate(entry: Dictionary, body: StaticBody3D, previous: Vector3, candidate: Vector3, moving_home: bool, allow_outside: bool) -> Dictionary:
    if main == null:
        return { "ok": false }
    if allow_outside:
        if not point_inside_work_area(entry, candidate):
            return { "ok": false, "reason": "outside_work_area" }
    elif not point_inside_town(entry, candidate):
        return { "ok": false, "reason": "outside_town" }
    var previous_ground: float = main.height_at_world(previous.x, previous.z)
    var next_ground: float = main.height_at_world(candidate.x, candidate.z)
    if next_ground < main.WATER_LEVEL + 0.45:
        return { "ok": false, "reason": "water" }
    if absf(next_ground - previous_ground) > CELL * 0.82 and not moving_home:
        return { "ok": false, "reason": "slope" }
    candidate.y = next_ground + 0.04
    if npc_obstacle_between(body, previous, candidate, moving_home):
        return { "ok": false, "reason": "obstacle" }
    return { "ok": true, "candidate": candidate }

func commit_npc_step(body: StaticBody3D, previous: Vector3, step_state: Dictionary) -> float:
    var candidate: Vector3 = step_state.get("candidate", previous)
    var step: Vector3 = step_state.get("step", candidate - previous)
    body.global_position = candidate
    if step.length_squared() > 0.001:
        body.rotation.y = atan2(step.x, step.z)
    return Vector2(candidate.x - previous.x, candidate.z - previous.z).length()

func compute_npc_path(entry: Dictionary, target: Vector3, moving_home: bool, allow_outside: bool) -> Array:
    var body := entry.get("body") as StaticBody3D
    if body == null or main == null:
        return []
    var start_cell := world_cell(body.global_position)
    var goal_cell := world_cell(target)
    if start_cell == goal_cell:
        return []
    var blocked_cells := npc_blocked_cells()
    var open: Array[Vector2i] = [start_cell]
    var came_from := {}
    var cost_so_far := { start_cell: 0.0 }
    var best_cell := start_cell
    var best_score := cell_distance(start_cell, goal_cell)
    var neighbor_offsets: Array[Vector2i] = [
        Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
        Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)
    ]
    for iteration in range(520):
        if open.is_empty():
            break
        var best_index := 0
        var best_open_score := INF
        for i in range(open.size()):
            var cell: Vector2i = open[i]
            var score := float(cost_so_far.get(cell, 999999.0)) + cell_distance(cell, goal_cell) * 1.15
            if score < best_open_score:
                best_open_score = score
                best_index = i
        var current: Vector2i = open[best_index]
        open.remove_at(best_index)
        var current_goal_distance := cell_distance(current, goal_cell)
        if current_goal_distance < best_score:
            best_score = current_goal_distance
            best_cell = current
        if current == goal_cell or current_goal_distance <= 1.0:
            best_cell = current
            break
        for offset in neighbor_offsets:
            var neighbor: Vector2i = current + offset
            if blocked_cells.has(neighbor) and neighbor != goal_cell:
                continue
            if offset.x != 0 and offset.y != 0:
                if blocked_cells.has(current + Vector2i(offset.x, 0)) or blocked_cells.has(current + Vector2i(0, offset.y)):
                    continue
            var neighbor_position := path_cell_position(neighbor)
            if not npc_path_position_allowed(entry, current, neighbor, neighbor_position, moving_home, allow_outside):
                continue
            var step_cost := 1.42 if offset.x != 0 and offset.y != 0 else 1.0
            var new_cost := float(cost_so_far.get(current, 0.0)) + step_cost
            if not cost_so_far.has(neighbor) or new_cost < float(cost_so_far.get(neighbor, 999999.0)):
                cost_so_far[neighbor] = new_cost
                came_from[neighbor] = current
                if not open.has(neighbor):
                    open.append(neighbor)
    return path_cells_to_waypoints(start_cell, best_cell, came_from)

func path_cells_to_waypoints(start_cell: Vector2i, best_cell: Vector2i, came_from: Dictionary) -> Array:
    if best_cell == start_cell or not came_from.has(best_cell):
        return []
    var cells: Array[Vector2i] = []
    var cursor := best_cell
    while cursor != start_cell and came_from.has(cursor):
        cells.push_front(cursor)
        cursor = came_from[cursor]
    var waypoints: Array[Vector3] = []
    var last_direction := Vector2i.ZERO
    for i in range(cells.size()):
        var cell: Vector2i = cells[i]
        var previous: Vector2i = start_cell if i == 0 else cells[i - 1]
        var next_direction := Vector2i(signi(cell.x - previous.x), signi(cell.y - previous.y))
        var is_turn := i == 0 or next_direction != last_direction or i == cells.size() - 1
        if is_turn:
            waypoints.append(path_cell_position(cell))
            last_direction = next_direction
        if waypoints.size() >= 8:
            break
    return waypoints

func world_cell(position: Vector3) -> Vector2i:
    return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

func path_cell_position(cell: Vector2i) -> Vector3:
    var y: float = main.height_at_world(float(cell.x) * CELL, float(cell.y) * CELL)
    return Vector3(float(cell.x) * CELL, y + 0.04, float(cell.y) * CELL)

func cell_distance(a: Vector2i, b: Vector2i) -> float:
    return Vector2(float(a.x - b.x), float(a.y - b.y)).length()

func npc_straight_route_crosses_blocked(previous: Vector3, target: Vector3) -> bool:
    var delta := target - previous
    delta.y = 0.0
    var distance := delta.length()
    if distance <= CELL * 2.25:
        return false
    var blocked_cells := npc_blocked_cells()
    if blocked_cells.is_empty():
        return false
    var start_cell := world_cell(previous)
    var goal_cell := world_cell(target)
    var samples := clampi(ceili(distance / (CELL * 0.48)), 3, 96)
    for i in range(2, samples):
        var t := float(i) / float(samples)
        var cell := world_cell(previous.lerp(target, t))
        if cell == start_cell or cell == goal_cell:
            continue
        if blocked_cells.has(cell):
            return true
    return false

func npc_path_position_allowed(entry: Dictionary, from_cell: Vector2i, to_cell: Vector2i, position: Vector3, moving_home: bool, allow_outside: bool) -> bool:
    if allow_outside:
        if not point_inside_work_area(entry, position):
            return false
    elif not point_inside_town(entry, position):
        return false
    var from_height: float = main.height_at_world(float(from_cell.x) * CELL, float(from_cell.y) * CELL)
    var to_height: float = main.height_at_world(float(to_cell.x) * CELL, float(to_cell.y) * CELL)
    if to_height < main.WATER_LEVEL + 0.45:
        return false
    if absf(to_height - from_height) > CELL * 0.90 and not moving_home:
        return false
    return true

func npc_blocked_cells() -> Dictionary:
    var blocked := {}
    if main == null:
        return blocked
    var blocks: Dictionary = main.get("blocks")
    for block in blocks.values():
        var body := block as Node
        if body == null or not is_instance_valid(body):
            continue
        var block_type := String(body.get_meta("block_type", ""))
        if block_type in ["cobblestonePath", "torch", "door"]:
            continue
        var cell: Vector3i = body.get_meta("cell", Vector3i.ZERO)
        blocked[Vector2i(cell.x, cell.z)] = true
    return blocked

func choose_detour_target(entry: Dictionary, target: Vector3, moving_home: bool, allow_outside: bool) -> Vector3:
    var body := entry.get("body") as StaticBody3D
    if body == null or main == null:
        return NO_DETOUR
    var origin := body.global_position
    var forward := target - origin
    forward.y = 0.0
    if forward.length_squared() < 0.0001:
        return NO_DETOUR
    forward = forward.normalized()
    var side := Vector3(-forward.z, 0.0, forward.x)
    for distance in [CELL * 2.0, CELL * 3.6, CELL * 5.0]:
        for option in [Vector2(0.04, 1.0), Vector2(0.04, -1.0), Vector2(-0.34, 1.12), Vector2(-0.34, -1.12), Vector2(0.52, 1.0), Vector2(0.52, -1.0), Vector2(0.42, 1.55), Vector2(0.42, -1.55)]:
            var direction: Vector3 = (forward * option.x + side * option.y).normalized()
            var probe: Vector3 = origin + direction * minf(CELL * 0.92, distance)
            var probe_step := validate_npc_candidate(entry, body, origin, probe, moving_home, allow_outside)
            if not bool(probe_step.get("ok", false)):
                continue
            var detour: Vector3 = origin + direction * float(distance)
            detour.y = main.height_at_world(detour.x, detour.z) + 0.04
            if allow_outside:
                if not point_inside_work_area(entry, detour):
                    continue
            elif not point_inside_town(entry, detour):
                continue
            return detour
    return NO_DETOUR

func npc_obstacle_between(body: Node3D, previous: Vector3, candidate: Vector3, moving_home := false) -> bool:
    var delta := candidate - previous
    delta.y = 0.0
    if delta.length_squared() < 0.0001:
        return false
    var direction := delta.normalized()
    var side := Vector3(-direction.z, 0.0, direction.x)
    for height in [0.62, 1.24]:
        for lateral in [0.0, 0.28, -0.28]:
            var offset := side * float(lateral)
            var start := previous + offset + Vector3(0.0, float(height), 0.0)
            var end := candidate + offset + Vector3(0.0, float(height), 0.0)
            if npc_ray_obstacle(body, start, end, moving_home):
                return true
    return false

func npc_ray_obstacle(body: Node3D, start: Vector3, end: Vector3, moving_home := false) -> bool:
    var query := PhysicsRayQueryParameters3D.create(start, end)
    query.exclude = [body]
    query.collision_mask = 1 | 4
    query.collide_with_bodies = true
    query.collide_with_areas = false
    var hit: Dictionary = system.get_world_3d().direct_space_state.intersect_ray(query)
    if hit.is_empty():
        return false
    var collider := hit.get("collider") as Node
    if collider == null:
        return false
    var kind := String(collider.get_meta("kind", ""))
    if kind == "block":
        var block_type := String(collider.get_meta("block_type", ""))
        if block_type in ["cobblestonePath", "torch"]:
            return false
        if block_type == "door":
            system.open_door_for_npc(collider)
            return false
        return true
    return kind in ["prop", "npc", "tutorial_npc", "hostile"]

func choose_day_target(entry: Dictionary) -> Vector3:
    var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
    var radius := maxf(6.0, float(entry.get("townRadius", 18)) - 4.0)
    for attempt in range(16):
        var angle := randf() * TAU
        var distance := randf_range(CELL * 2.0, radius * CELL)
        var position := Vector3(float(center.x) * CELL + cos(angle) * distance, 0.0, float(center.y) * CELL + sin(angle) * distance)
        var ground_y: float = main.height_at_world(position.x, position.z)
        if ground_y < main.WATER_LEVEL + 0.5:
            continue
        position.y = ground_y + 0.04
        if point_inside_town(entry, position):
            return position
    return entry.get("porchPosition", Vector3.ZERO)

func choose_job_target(entry: Dictionary) -> Vector3:
    var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
    var town_radius := float(entry.get("townRadius", 18))
    var job := String(entry.get("job", ""))
    var angle_seed := float(abs(hash(String(entry.get("id", "")) + job)) % 1000) / 1000.0
    for attempt in range(20):
        var angle := angle_seed * TAU + randf_range(-0.48, 0.48) + float(attempt) * 0.37
        var distance := (town_radius + randf_range(5.0, 14.0)) * CELL
        if job == "stone":
            distance = (town_radius + randf_range(10.0, 21.0)) * CELL
        var position := Vector3(float(center.x) * CELL + cos(angle) * distance, 0.0, float(center.y) * CELL + sin(angle) * distance)
        var ground_y: float = main.height_at_world(position.x, position.z)
        if ground_y < main.WATER_LEVEL + 0.55:
            continue
        var previous_ground: float = main.height_at_world(float(center.x) * CELL, float(center.y) * CELL)
        if absf(ground_y - previous_ground) > CELL * 7.0:
            continue
        position.y = ground_y + 0.04
        if point_inside_work_area(entry, position) and not point_inside_town(entry, position):
            return position
    return entry.get("porchPosition", Vector3.ZERO)

func point_inside_town(entry: Dictionary, position: Vector3) -> bool:
    var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
    var radius := float(entry.get("townRadius", 18)) * CELL
    var flat := Vector2(position.x - float(center.x) * CELL, position.z - float(center.y) * CELL)
    return flat.length() <= radius

func point_inside_work_area(entry: Dictionary, position: Vector3) -> bool:
    var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
    var radius := (float(entry.get("townRadius", 18)) + 24.0) * CELL
    var flat := Vector2(position.x - float(center.x) * CELL, position.z - float(center.y) * CELL)
    return flat.length() <= radius
