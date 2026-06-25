extends RefCounted
class_name NpcRoutePlanner

const CELL := 1.35
const MAX_ITERATIONS := 384

var system
var main
var world

func setup(system_node, main_node, navigation_world) -> void:
    system = system_node
    main = main_node
    world = navigation_world

func plan_route(entry: Dictionary, intent: Dictionary) -> Dictionary:
    var body := entry.get("body") as Node3D
    if body == null or world == null:
        return route_failure("blocked", "missing_body")
    var allow_outside := bool(intent.get("allowOutside", false))
    var moving_home := bool(intent.get("movingHome", false))
    var snapshot: Dictionary = world.build_snapshot(entry, allow_outside, moving_home)
    var start_cell: Vector2i = world.world_cell(body.global_position)
    var target_cell: Vector2i = intent.get("targetCell", world.world_cell(intent.get("target", body.global_position)))
    var target_cells: Dictionary = route_target_cells(entry, intent, snapshot, target_cell, start_cell)
    if target_cells.is_empty():
        return route_failure("blocked", "no_candidate_goal", target_cell, snapshot)
    if target_cells.has(start_cell):
        return {
            "ok": true,
            "status": "arrived",
            "reason": "",
            "cells": [],
            "waypoints": [],
            "actions": {},
            "targetCell": target_cell,
            "fallbackCell": start_cell,
            "snapshotRevision": String(snapshot.get("revision", ""))
        }
    var direct_goal: Vector2i = nearest_target_cell(start_cell, target_cells)
    var direct_cells: Array[Vector2i] = direct_route_cells(entry, snapshot, start_cell, direct_goal, target_cells)
    if not direct_cells.is_empty():
        return route_from_cells(start_cell, direct_cells, snapshot, target_cell, direct_goal, "routed", "")

    var open: Array[Vector2i] = [start_cell]
    var came_from: Dictionary = {}
    var cost_so_far: Dictionary = { start_cell: 0.0 }
    var best_cell := start_cell
    var best_score: float = heuristic_to_targets(start_cell, target_cells)
    var best_reason := "no_route"
    var neighbor_offsets: Array[Vector2i] = [
        Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
        Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)
    ]

    for iteration in range(MAX_ITERATIONS):
        if open.is_empty():
            break
        var best_index := 0
        var best_open_score := INF
        for i in range(open.size()):
            var cell: Vector2i = open[i]
            var score: float = float(cost_so_far.get(cell, INF)) + heuristic_to_targets(cell, target_cells) * 1.12
            if score < best_open_score:
                best_open_score = score
                best_index = i
        var current: Vector2i = open[best_index]
        open.remove_at(best_index)
        var current_score: float = heuristic_to_targets(current, target_cells)
        if current_score < best_score:
            best_score = current_score
            best_cell = current
        if target_cells.has(current):
            return route_success(start_cell, current, came_from, snapshot, target_cell, current, "routed", "")
        for offset in neighbor_offsets:
            var neighbor: Vector2i = current + offset
            if offset.x != 0 and offset.y != 0 and diagonal_blocked(entry, snapshot, current, offset, target_cells):
                best_reason = "corner_blocked"
                continue
            var allowed: Dictionary = world.cell_pathable(entry, snapshot, current, neighbor, target_cells, true)
            if not bool(allowed.get("ok", false)):
                best_reason = String(allowed.get("reason", "blocked"))
                continue
            var step_cost: float = 1.42 if offset.x != 0 and offset.y != 0 else 1.0
            if world.is_path_cell(snapshot, neighbor):
                step_cost *= 0.68
            if world.door_at(snapshot, neighbor) != null:
                step_cost += 0.28
            var new_cost: float = float(cost_so_far.get(current, 0.0)) + step_cost
            if not cost_so_far.has(neighbor) or new_cost < float(cost_so_far.get(neighbor, INF)):
                cost_so_far[neighbor] = new_cost
                came_from[neighbor] = current
                if not open.has(neighbor):
                    open.append(neighbor)

    if best_cell != start_cell and came_from.has(best_cell):
        return route_success(start_cell, best_cell, came_from, snapshot, target_cell, best_cell, "partial", best_reason)
    return route_failure("blocked", best_reason, target_cell, snapshot)

func route_target_cells(entry: Dictionary, intent: Dictionary, snapshot: Dictionary, target_cell: Vector2i, start_cell: Vector2i) -> Dictionary:
    var target_cells: Dictionary = {}
    var allow_outside := bool(intent.get("allowOutside", false))
    var moving_home := bool(intent.get("movingHome", false))
    var arrival_radius := float(intent.get("arrivalRadius", CELL * 0.75))
    var strict_arrival := bool(intent.get("strictArrival", false)) or String(intent.get("kind", "")) == "scripted"
    var radius: int = 0 if strict_arrival else clampi(ceili(arrival_radius / CELL), 0, 3)
    var approach_cells: Array = intent.get("approachCells", [])
    if not approach_cells.is_empty():
        for cell_value in approach_cells:
            if cell_value is Vector2i and target_cell_candidate_allowed(entry, snapshot, cell_value, start_cell):
                target_cells[cell_value] = true
        return target_cells
    var search_radius := radius if strict_arrival else maxi(1, radius)
    for cell in world.candidate_cells_near(entry, target_cell, allow_outside, moving_home, search_radius):
        if target_cell_candidate_allowed(entry, snapshot, cell, start_cell):
            target_cells[cell] = true
    var fallback_cells: Array = intent.get("fallbackCells", [])
    for cell_value in fallback_cells:
        if cell_value is Vector2i and target_cell_candidate_allowed(entry, snapshot, cell_value, start_cell):
            target_cells[cell_value] = true
    return target_cells

func target_cell_candidate_allowed(entry: Dictionary, snapshot: Dictionary, cell: Vector2i, start_cell: Vector2i) -> bool:
    if cell == start_cell:
        return true
    if world.static_blocker(snapshot, cell) != null:
        return false
    if main == null:
        return false
    var height: float = world.height_for_cell(cell)
    return height >= main.WATER_LEVEL + 0.45

func diagonal_blocked(entry: Dictionary, snapshot: Dictionary, current: Vector2i, offset: Vector2i, target_cells: Dictionary) -> bool:
    var side_a: Vector2i = current + Vector2i(offset.x, 0)
    var side_b: Vector2i = current + Vector2i(0, offset.y)
    var check_a: Dictionary = world.cell_pathable(entry, snapshot, current, side_a, target_cells, true)
    var check_b: Dictionary = world.cell_pathable(entry, snapshot, current, side_b, target_cells, true)
    return not bool(check_a.get("ok", false)) or not bool(check_b.get("ok", false))

func heuristic_to_targets(cell: Vector2i, target_cells: Dictionary) -> float:
    var best: float = INF
    for target_cell in target_cells.keys():
        best = minf(best, world.cell_distance(cell, target_cell))
    return best

func nearest_target_cell(start_cell: Vector2i, target_cells: Dictionary) -> Vector2i:
    var best_cell := start_cell
    var best_distance: float = INF
    for target_cell in target_cells.keys():
        var distance: float = world.cell_distance(start_cell, target_cell)
        if distance < best_distance:
            best_distance = distance
            best_cell = target_cell
    return best_cell

func direct_route_cells(entry: Dictionary, snapshot: Dictionary, start_cell: Vector2i, end_cell: Vector2i, target_cells: Dictionary) -> Array[Vector2i]:
    var cells: Array[Vector2i] = []
    var dx := end_cell.x - start_cell.x
    var dz := end_cell.y - start_cell.y
    var steps := maxi(abs(dx), abs(dz))
    if steps <= 0:
        return cells
    var previous := start_cell
    for i in range(1, steps + 1):
        var t := float(i) / float(steps)
        var cell := Vector2i(roundi(lerpf(float(start_cell.x), float(end_cell.x), t)), roundi(lerpf(float(start_cell.y), float(end_cell.y), t)))
        if cell == previous:
            continue
        var offset := Vector2i(signi(cell.x - previous.x), signi(cell.y - previous.y))
        if offset.x != 0 and offset.y != 0 and diagonal_blocked(entry, snapshot, previous, offset, target_cells):
            return []
        var allowed: Dictionary = world.cell_pathable(entry, snapshot, previous, cell, target_cells, true)
        if not bool(allowed.get("ok", false)):
            return []
        cells.append(cell)
        previous = cell
    return cells

func route_from_cells(start_cell: Vector2i, cells: Array[Vector2i], snapshot: Dictionary, target_cell: Vector2i, fallback_cell: Vector2i, status: String, reason: String) -> Dictionary:
    return {
        "ok": not cells.is_empty() or status == "arrived",
        "status": status,
        "reason": reason,
        "cells": cells,
        "waypoints": cells_to_waypoints(start_cell, cells),
        "actions": route_actions(cells, snapshot),
        "targetCell": target_cell,
        "fallbackCell": fallback_cell,
        "snapshotRevision": String(snapshot.get("revision", ""))
    }

func route_success(start_cell: Vector2i, end_cell: Vector2i, came_from: Dictionary, snapshot: Dictionary, target_cell: Vector2i, fallback_cell: Vector2i, status: String, reason: String) -> Dictionary:
    var cells: Array[Vector2i] = reconstruct_cells(start_cell, end_cell, came_from)
    return route_from_cells(start_cell, cells, snapshot, target_cell, fallback_cell, status, reason)

func route_failure(status: String, reason: String, target_cell := Vector2i(999999, 999999), snapshot: Dictionary = {}) -> Dictionary:
    return {
        "ok": false,
        "status": status,
        "reason": reason,
        "cells": [],
        "waypoints": [],
        "actions": {},
        "targetCell": target_cell,
        "fallbackCell": Vector2i(999999, 999999),
        "snapshotRevision": String(snapshot.get("revision", ""))
    }

func reconstruct_cells(start_cell: Vector2i, end_cell: Vector2i, came_from: Dictionary) -> Array[Vector2i]:
    var cells: Array[Vector2i] = []
    if end_cell == start_cell:
        return cells
    if not came_from.has(end_cell):
        return cells
    var cursor: Vector2i = end_cell
    while cursor != start_cell and came_from.has(cursor):
        cells.push_front(cursor)
        cursor = came_from[cursor]
    return cells

func cells_to_waypoints(start_cell: Vector2i, cells: Array[Vector2i]) -> Array[Vector3]:
    var waypoints: Array[Vector3] = []
    var last_direction := Vector2i.ZERO
    for i in range(cells.size()):
        var cell: Vector2i = cells[i]
        var previous: Vector2i = start_cell if i == 0 else cells[i - 1]
        var direction: Vector2i = Vector2i(signi(cell.x - previous.x), signi(cell.y - previous.y))
        var is_turn: bool = i == 0 or direction != last_direction or i == cells.size() - 1
        if is_turn:
            waypoints.append(world.cell_position(cell))
            last_direction = direction
        if waypoints.size() >= 12:
            break
    return waypoints

func route_actions(cells: Array[Vector2i], snapshot: Dictionary) -> Dictionary:
    var actions: Dictionary = {}
    for cell in cells:
        var door: Node = world.door_at(snapshot, cell)
        if door != null:
            actions[world.cell_key(cell)] = { "kind": "door", "cell": cell, "door": door }
    return actions

func route_cost(entry: Dictionary, target: Vector3, allow_outside := false, moving_home := false, arrival_radius := CELL * 0.85, approach_cells: Array = []) -> float:
    var target_cell: Vector2i = world.world_cell(target)
    var intent: Dictionary = {
        "kind": "cost",
        "target": target,
        "targetCell": target_cell,
        "allowOutside": allow_outside,
        "movingHome": moving_home,
        "arrivalRadius": arrival_radius,
        "priority": 0,
        "action": "",
        "interruptible": true,
        "approachCells": approach_cells
    }
    var route: Dictionary = plan_route(entry, intent)
    if not bool(route.get("ok", false)):
        return INF
    var cells: Array = route.get("cells", [])
    var penalty: float = 0.0 if String(route.get("status", "")) == "routed" else 80.0
    return float(cells.size()) + penalty
