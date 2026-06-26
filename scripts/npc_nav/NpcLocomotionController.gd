extends RefCounted
class_name NpcLocomotionController

const CELL := 1.35
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const CAPSULE_RADIUS := 0.34
const CAPSULE_HEIGHT := 1.64
const CELL_RESERVATION_TTL := 5
const DOOR_RESERVATION_TTL := 18

var system
var main
var reservations := {}
var door_reservations := {}
var capsule_shape: CapsuleShape3D
var reservation_frame := 0

func setup(system_node, main_node) -> void:
    system = system_node
    main = main_node
    capsule_shape = CapsuleShape3D.new()
    capsule_shape.radius = CAPSULE_RADIUS
    capsule_shape.height = CAPSULE_HEIGHT

func begin_frame() -> void:
    reservation_frame += 1
    expire_reservations(reservations)
    expire_reservations(door_reservations)

func move(entry: Dictionary, intent: Dictionary, max_distance: float, planner, world) -> Dictionary:
    var body := entry.get("body") as CharacterBody3D
    if body == null or main == null or planner == null or world == null or max_distance <= 0.0:
        return { "moved": 0.0, "status": "blocked", "reason": "missing_context" }
    var previous: Vector3 = body.global_position
    var target: Vector3 = intent.get("target", previous)
    var arrival_radius: float = float(intent.get("arrivalRadius", CELL * 0.75))
    var strict_arrival := bool(intent.get("strictArrival", false)) or String(intent.get("kind", "")) == "scripted"
    if flat_distance(previous, target) <= arrival_radius:
        clear_route(entry)
        set_route_status(entry, "arrived", "")
        return { "moved": 0.0, "status": "arrived", "reason": "" }

    var route: Dictionary = ensure_route(entry, intent, planner, world)
    if not bool(route.get("ok", false)):
        set_route_status(entry, String(route.get("status", "blocked")), String(route.get("reason", "blocked")))
        count_unreachable_once(entry, intent, String(route.get("reason", "blocked")))
        return { "moved": 0.0, "status": String(route.get("status", "blocked")), "reason": String(route.get("reason", "blocked")) }
    if String(route.get("status", "")) == "arrived":
        clear_route(entry)
        set_route_status(entry, "arrived", "")
        return { "moved": 0.0, "status": "arrived", "reason": "" }

    trim_reached_route_cells(entry, world)
    var path_waypoints: Array = entry.get("pathWaypoints", [])
    while not path_waypoints.is_empty() and flat_distance(previous, path_waypoints[0]) <= CELL * 0.36:
        path_waypoints.remove_at(0)
        entry["pathWaypoints"] = path_waypoints
    if path_waypoints.is_empty():
        var final_arrival_radius := arrival_radius if strict_arrival else maxf(arrival_radius, CELL * 0.95)
        if flat_distance(previous, target) <= final_arrival_radius:
            clear_route(entry)
            set_route_status(entry, "arrived", "")
            return { "moved": 0.0, "status": "arrived", "reason": "" }
        entry["routeForceReplan"] = true
        route = ensure_route(entry, intent, planner, world)
        path_waypoints = entry.get("pathWaypoints", [])
        if path_waypoints.is_empty():
            set_route_status(entry, "blocked", "empty_route")
            count_unreachable_once(entry, intent, "empty_route")
            return { "moved": 0.0, "status": "blocked", "reason": "empty_route" }

    var priority := int(intent.get("priority", 0))
    entry["routePriority"] = priority
    var next_cell: Vector2i = next_route_cell(entry, world)
    var door_wait: String = handle_door_action(entry, next_cell, world, priority)
    if door_wait != "":
        set_route_status(entry, "waiting", door_wait)
        increment_reservation_wait(entry)
        return { "moved": 0.0, "status": "waiting", "reason": door_wait }

    var waypoint: Vector3 = path_waypoints[0]
    var delta: Vector3 = waypoint - previous
    delta.y = 0.0
    if delta.length_squared() < 0.001:
        path_waypoints.remove_at(0)
        entry["pathWaypoints"] = path_waypoints
        return { "moved": 0.0, "status": "waiting", "reason": "waypoint_close" }
    var moving_home := bool(intent.get("movingHome", false))
    var allow_outside := bool(intent.get("allowOutside", false))
    var yielded_step := false
    var validation: Dictionary = {}
    var yield_ticks := int(entry.get("routeYieldTicks", 0))
    if yield_ticks > 0:
        validation = try_yield_backoff(entry, previous, waypoint, max_distance, moving_home, allow_outside, world, priority)
        if bool(validation.get("ok", false)):
            yielded_step = true
            entry["routeYieldTicks"] = max(0, yield_ticks - 1)
        else:
            entry["routeYieldTicks"] = 0
    if not bool(validation.get("ok", false)):
        var step: Vector3 = delta.normalized() * minf(max_distance, delta.length())
        var candidate: Vector3 = previous + step
        validation = validate_candidate(entry, previous, candidate, moving_home, allow_outside, world, priority)
        var direct_reason := String(validation.get("reason", ""))
        if direct_reason == "yielding":
            increment_reservation_wait(entry)
            entry["routeYieldTicks"] = maxi(int(entry.get("routeYieldTicks", 0)), 12)
            validation = try_yield_backoff(entry, previous, waypoint, max_distance, moving_home, allow_outside, world, priority)
            yielded_step = bool(validation.get("ok", false))
        if not bool(validation.get("ok", false)):
            validation = try_local_avoidance(entry, previous, waypoint, max_distance, moving_home, allow_outside, world, priority)
    if not bool(validation.get("ok", false)):
        entry["blockedMoveTime"] = float(entry.get("blockedMoveTime", 0.0)) + max_distance
        if system != null:
            system.npc_blocked_moves += 1
        if float(entry.get("blockedMoveTime", 0.0)) > CELL * 0.90:
            entry["routeForceReplan"] = true
            entry["blockedMoveTime"] = 0.0
            increment_stuck_recovery(entry)
        set_route_status(entry, "waiting", String(validation.get("reason", "blocked")))
        return { "moved": 0.0, "status": "waiting", "reason": String(validation.get("reason", "blocked")) }

    var move_candidate: Vector3 = validation.get("candidate", previous)
    var candidate_cell: Vector2i = world.world_cell(move_candidate)
    var reservation_key: String = world.cell_key(candidate_cell)
    if reservation_blocks_entry(reservations, reservation_key, entry, priority):
        increment_reservation_wait(entry)
        var final_reason := reservation_conflict_reason(reservations, reservation_key, entry, priority)
        if final_reason == "yielding" and int(entry.get("routeWaitTicks", 0)) > 4:
            entry["routeForceReplan"] = true
        set_route_status(entry, "waiting", final_reason)
        return { "moved": 0.0, "status": "waiting", "reason": final_reason }
    claim_reservation(reservations, reservation_key, entry, priority, CELL_RESERVATION_TTL)

    var physics_delta := maxf(0.0001, float(intent.get("physicsDelta", 0.0166667)))
    var motor_result: Dictionary = {}
    if system != null and system.has_method("apply_npc_route_motion"):
        motor_result = system.apply_npc_route_motion(entry, previous, move_candidate, physics_delta)
    else:
        return { "moved": 0.0, "status": "blocked", "reason": "missing_motion_adapter" }
    var actual_position: Vector3 = motor_result.get("position", body.global_position)
    var moved := float(motor_result.get("moved", flat_distance(previous, actual_position)))
    if bool(motor_result.get("blocked", false)) and moved <= 0.001:
        entry["blockedMoveTime"] = float(entry.get("blockedMoveTime", 0.0)) + max_distance
        if system != null:
            system.npc_blocked_moves += 1
        if float(entry.get("blockedMoveTime", 0.0)) > CELL * 0.90:
            entry["routeForceReplan"] = true
            entry["blockedMoveTime"] = 0.0
            increment_stuck_recovery(entry)
        var motor_reason := String(motor_result.get("reason", "motor_blocked"))
        set_route_status(entry, "waiting", motor_reason)
        return { "moved": moved, "status": "waiting", "reason": motor_reason }
    entry["blockedMoveTime"] = 0.0
    if yielded_step:
        set_route_status(entry, "yielding", "")
    else:
        entry["routeWaitTicks"] = 0
        entry["routeYieldTicks"] = 0
        set_route_status(entry, "moving", "")
    trim_reached_route_cells(entry, world)
    increment_validated_move(entry)
    return { "moved": moved, "status": String(entry.get("routeStatus", "moving")), "reason": "" }

func ensure_route(entry: Dictionary, intent: Dictionary, planner, world) -> Dictionary:
    var target_cell: Vector2i = intent.get("targetCell", world.world_cell(intent.get("target", Vector3.ZERO)))
    var route_key: String = "%s:%d,%d:%s:%s:%s" % [
        String(intent.get("kind", "move")),
        target_cell.x,
        target_cell.y,
        str(bool(intent.get("allowOutside", false))),
        str(bool(intent.get("movingHome", false))),
        String(intent.get("action", ""))
    ]
    var snapshot_revision: String = world.revision()
    var route_known := String(entry.get("routeKey", "")) != ""
    var current_waypoints: Array = entry.get("pathWaypoints", [])
    var cached_status := String(entry.get("routeStatus", "idle"))
    var empty_route_waiting_for_reason := current_waypoints.is_empty() and cached_status in ["blocked", "waiting"]
    var needs_route: bool = bool(entry.get("routeForceReplan", false))
    needs_route = needs_route or String(entry.get("routeKey", "")) != route_key
    needs_route = needs_route or String(entry.get("routeSnapshotRevision", "")) != snapshot_revision
    needs_route = needs_route or (current_waypoints.is_empty() and (not route_known or not empty_route_waiting_for_reason))
    if not needs_route:
        var has_cached_route := not current_waypoints.is_empty()
        return {
            "ok": has_cached_route,
            "status": "routed" if has_cached_route and cached_status in ["blocked", "waiting"] else cached_status,
            "reason": String(entry.get("routeReason", "")),
            "cells": entry.get("routeCells", []),
            "waypoints": current_waypoints,
            "actions": entry.get("routeActions", {}),
            "targetCell": target_cell,
            "fallbackCell": entry.get("routeFallbackCell", target_cell),
            "snapshotRevision": snapshot_revision
        }

    var route: Dictionary = planner.plan_route(entry, intent)
    entry["routeForceReplan"] = false
    entry["routeKey"] = route_key
    entry["routeGoalCell"] = target_cell
    entry["routeAllowOutside"] = bool(intent.get("allowOutside", false))
    entry["routeMovingHome"] = bool(intent.get("movingHome", false))
    entry["routeSnapshotRevision"] = snapshot_revision
    entry["routeCells"] = (route.get("cells", []) as Array).duplicate()
    entry["pathWaypoints"] = (route.get("waypoints", []) as Array).duplicate()
    entry["routeActions"] = (route.get("actions", {}) as Dictionary).duplicate()
    entry["routeFallbackCell"] = route.get("fallbackCell", target_cell)
    if bool(route.get("ok", false)) and not (route.get("waypoints", []) as Array).is_empty():
        entry["routeRetryTicks"] = 0
    elif String(route.get("status", "")) != "arrived":
        entry["routeRetryTicks"] = 0
    if bool(route.get("ok", false)) and not (route.get("waypoints", []) as Array).is_empty():
        increment_route_replan(entry)
    set_route_status(entry, String(route.get("status", "blocked")), String(route.get("reason", "")))
    if String(route.get("status", "")) == "partial":
        count_unreachable_once(entry, intent, String(route.get("reason", "partial_route")))
    return route

func clear_route(entry: Dictionary) -> void:
    entry["pathWaypoints"] = []
    entry["routeCells"] = []
    entry["routeActions"] = {}
    entry["routeForceReplan"] = false

func trim_reached_route_cells(entry: Dictionary, world) -> void:
    var body := entry.get("body") as Node3D
    if body == null:
        return
    var current_cell: Vector2i = world.world_cell(body.global_position)
    var cells: Array = entry.get("routeCells", [])
    while not cells.is_empty() and cells[0] == current_cell:
        cells.remove_at(0)
    entry["routeCells"] = cells

func next_route_cell(entry: Dictionary, world) -> Vector2i:
    trim_reached_route_cells(entry, world)
    var cells: Array = entry.get("routeCells", [])
    if not cells.is_empty() and cells[0] is Vector2i:
        return cells[0]
    var waypoints: Array = entry.get("pathWaypoints", [])
    if not waypoints.is_empty() and waypoints[0] is Vector3:
        return world.world_cell(waypoints[0])
    var body := entry.get("body") as Node3D
    return world.world_cell(body.global_position) if body != null else Vector2i.ZERO

func handle_door_action(entry: Dictionary, next_cell: Vector2i, world, priority := 0) -> String:
    var actions: Dictionary = entry.get("routeActions", {})
    var action: Dictionary = actions.get(world.cell_key(next_cell), {})
    if action.is_empty() or String(action.get("kind", "")) != "door":
        return ""
    var door_value = action.get("door")
    var body := entry.get("body") as Node3D
    if door_value == null or not is_instance_valid(door_value) or not (door_value is Node):
        return ""
    var door: Node = door_value
    var door_key: String = str(door.get_instance_id())
    if reservation_blocks_entry(door_reservations, door_key, entry, priority):
        return reservation_conflict_reason(door_reservations, door_key, entry, priority, "door_reserved")
    claim_reservation(door_reservations, door_key, entry, priority, DOOR_RESERVATION_TTL, true)
    if system != null:
        system.open_door_for_npc(door, body)
    if not bool(door.get_meta("open", false)):
        return "door_opening"
    return ""

func validate_candidate(entry: Dictionary, previous: Vector3, candidate: Vector3, moving_home := false, allow_outside := false, world = null, priority := 0) -> Dictionary:
    if world == null or main == null:
        return { "ok": false, "reason": "missing_world" }
    if not world.point_allowed(entry, candidate, allow_outside, moving_home):
        return { "ok": false, "reason": "outside_area" }
    var previous_cell: Vector2i = world.world_cell(previous)
    var candidate_cell: Vector2i = world.world_cell(candidate)
    var terrain: Dictionary = world.terrain_allows_step(previous_cell, candidate_cell, moving_home)
    if not bool(terrain.get("ok", false)):
        return terrain
    candidate.y = float(terrain.get("height", main.height_at_world(candidate.x, candidate.z))) + 0.04
    var snapshot: Dictionary = world.build_snapshot(entry, allow_outside, moving_home)
    var center_sweep: Dictionary = center_sweep_blocker(snapshot, previous, candidate, world, previous_cell)
    if not bool(center_sweep.get("ok", false)):
        return center_sweep
    var previous_footprint: Array[Vector2i] = capsule_footprint_cells(previous, world)
    for footprint_cell in capsule_footprint_cells(candidate, world):
        var blocker = world.static_blocker(snapshot, footprint_cell)
        if blocker != null:
            if previous_footprint.has(footprint_cell):
                continue
            var door := blocker as Node
            if door == null or String(door.get_meta("block_type", "")) != "door":
                return { "ok": false, "reason": "blocked_static" }
        var dynamic = world.dynamic_blocker(snapshot, footprint_cell)
        if dynamic != null and footprint_cell != previous_cell:
            if entry_loses_to_dynamic(entry, dynamic, priority):
                return { "ok": false, "reason": "yielding", "blocker": dynamic }
            return { "ok": false, "reason": "blocked_dynamic" }
        var reservation_key: String = world.cell_key(footprint_cell)
        if footprint_cell != previous_cell and reservation_blocks_entry(reservations, reservation_key, entry, priority):
            return { "ok": false, "reason": reservation_conflict_reason(reservations, reservation_key, entry, priority) }
    var body := entry.get("body") as CharacterBody3D
    if body != null and capsule_hits_obstacle(entry, body, previous, candidate):
        return { "ok": false, "reason": "blocked_capsule" }
    return { "ok": true, "candidate": candidate }

func center_sweep_blocker(snapshot: Dictionary, previous: Vector3, candidate: Vector3, world, previous_cell: Vector2i) -> Dictionary:
    var flat_delta := Vector2(candidate.x - previous.x, candidate.z - previous.z)
    var samples := clampi(ceili(flat_delta.length() / maxf(0.01, CELL * 0.20)), 1, 8)
    var checked := {}
    for i in range(1, samples + 1):
        var t := float(i) / float(samples)
        var sample := previous.lerp(candidate, t)
        var sample_cell: Vector2i = world.world_cell(sample)
        if sample_cell == previous_cell or checked.has(sample_cell):
            continue
        checked[sample_cell] = true
        var blocker = world.static_blocker(snapshot, sample_cell)
        if blocker == null:
            continue
        var door := blocker as Node
        if door == null or String(door.get_meta("block_type", "")) != "door":
            return { "ok": false, "reason": "blocked_static" }
    return { "ok": true }

func capsule_footprint_cells(position: Vector3, world) -> Array[Vector2i]:
    var cells: Array[Vector2i] = []
    for offset in [
        Vector3.ZERO,
        Vector3(CAPSULE_RADIUS, 0.0, 0.0),
        Vector3(-CAPSULE_RADIUS, 0.0, 0.0),
        Vector3(0.0, 0.0, CAPSULE_RADIUS),
        Vector3(0.0, 0.0, -CAPSULE_RADIUS)
    ]:
        var cell: Vector2i = world.world_cell(position + offset)
        if not cells.has(cell):
            cells.append(cell)
    return cells

func try_local_avoidance(entry: Dictionary, previous: Vector3, waypoint: Vector3, max_distance: float, moving_home := false, allow_outside := false, world = null, priority := 0) -> Dictionary:
    var forward: Vector3 = waypoint - previous
    forward.y = 0.0
    if forward.length_squared() < 0.001:
        return { "ok": false, "reason": "no_forward" }
    forward = forward.normalized()
    var side: Vector3 = Vector3(-forward.z, 0.0, forward.x)
    for option in [Vector2(0.80, 0.44), Vector2(0.80, -0.44), Vector2(0.45, 0.72), Vector2(0.45, -0.72), Vector2(1.0, 0.0), Vector2(-0.55, 0.0), Vector2(-0.45, 0.45), Vector2(-0.45, -0.45)]:
        var direction: Vector3 = (forward * option.x + side * option.y).normalized()
        var candidate: Vector3 = previous + direction * minf(max_distance, CELL * 0.42)
        var validation: Dictionary = validate_candidate(entry, previous, candidate, moving_home, allow_outside, world, priority)
        if bool(validation.get("ok", false)):
            return validation
    return { "ok": false, "reason": "local_blocked" }

func try_yield_backoff(entry: Dictionary, previous: Vector3, waypoint: Vector3, max_distance: float, moving_home := false, allow_outside := false, world = null, priority := 0) -> Dictionary:
    var forward: Vector3 = waypoint - previous
    forward.y = 0.0
    if forward.length_squared() < 0.001:
        return { "ok": false, "reason": "yield_no_forward" }
    forward = forward.normalized()
    var side: Vector3 = Vector3(-forward.z, 0.0, forward.x)
    var side_sign := 1.0 if (hash(String(entry.get("id", "npc"))) & 1) == 0 else -1.0
    var options := [
        Vector2(-1.0, 0.0),
        Vector2(-0.92, side_sign * 0.42),
        Vector2(-0.92, -side_sign * 0.42),
        Vector2(-0.58, side_sign * 0.82),
        Vector2(-0.58, -side_sign * 0.82)
    ]
    for option in options:
        var direction: Vector3 = (forward * option.x + side * option.y).normalized()
        var candidate: Vector3 = previous + direction * minf(max_distance, CELL * 0.48)
        var validation: Dictionary = validate_candidate(entry, previous, candidate, moving_home, allow_outside, world, priority)
        if bool(validation.get("ok", false)):
            return validation
    return { "ok": false, "reason": "yield_blocked" }

func expire_reservations(claims: Dictionary) -> void:
    for key in claims.keys():
        var value = claims.get(key)
        if not (value is Dictionary):
            claims.erase(key)
            continue
        var claim: Dictionary = value
        if int(claim.get("expires", 0)) <= reservation_frame:
            claims.erase(key)

func claim_reservation(claims: Dictionary, key: String, entry: Dictionary, priority := 0, ttl := 1, locked := false) -> void:
    var owner := String(entry.get("id", "npc"))
    claims[key] = {
        "owner": owner,
        "priority": priority,
        "wait": int(entry.get("routeWaitTicks", 0)),
        "expires": reservation_frame + maxi(1, ttl),
        "locked": locked
    }

func reservation_blocks_entry(claims: Dictionary, key: String, entry: Dictionary, priority := 0) -> bool:
    if not claims.has(key):
        return false
    var value = claims.get(key)
    if not (value is Dictionary):
        claims.erase(key)
        return false
    var claim: Dictionary = value
    if int(claim.get("expires", 0)) <= reservation_frame:
        claims.erase(key)
        return false
    var owner := String(claim.get("owner", ""))
    var npc_key := String(entry.get("id", "npc"))
    if owner == "" or owner == npc_key:
        return false
    return not entry_beats_claim(entry, priority, claim)

func entry_beats_claim(entry: Dictionary, priority := 0, claim: Dictionary = {}) -> bool:
    if bool(claim.get("locked", false)):
        return false
    var claim_priority := int(claim.get("priority", 0))
    if priority != claim_priority:
        return priority > claim_priority
    var wait_ticks := int(entry.get("routeWaitTicks", 0))
    var claim_wait := int(claim.get("wait", 0))
    if wait_ticks != claim_wait:
        return wait_ticks > claim_wait
    var npc_key := String(entry.get("id", "npc"))
    var owner := String(claim.get("owner", ""))
    return npc_key < owner

func reservation_conflict_reason(claims: Dictionary, key: String, entry: Dictionary, priority := 0, default_reason := "cell_reserved") -> String:
    var value = claims.get(key)
    if not (value is Dictionary):
        return default_reason
    var claim: Dictionary = value
    if bool(claim.get("locked", false)):
        return default_reason
    var claim_priority := int(claim.get("priority", 0))
    var claim_wait := int(claim.get("wait", 0))
    if priority < claim_priority or int(entry.get("routeWaitTicks", 0)) < claim_wait:
        return "yielding"
    return default_reason

func entry_loses_to_dynamic(entry: Dictionary, blocker, priority := 0) -> bool:
    var blocker_node := blocker as Node
    if blocker_node == null:
        return false
    var blocker_entry: Dictionary = {}
    if system != null:
        var by_id_value = system.get("npc_by_id")
        if by_id_value is Dictionary:
            blocker_entry = (by_id_value as Dictionary).get(blocker_node.get_instance_id(), {})
    var blocker_id := String(blocker_entry.get("id", blocker_node.name))
    var npc_id := String(entry.get("id", "npc"))
    if blocker_id == "" or blocker_id == npc_id:
        return false
    var blocker_priority := int(blocker_entry.get("routePriority", priority))
    if priority != blocker_priority:
        return priority < blocker_priority
    return npc_id > blocker_id

func capsule_hits_obstacle(entry: Dictionary, body: CharacterBody3D, previous: Vector3, candidate: Vector3) -> bool:
    if system == null or body == null or capsule_shape == null:
        return false
    var delta: Vector3 = candidate - previous
    delta.y = 0.0
    var samples: int = clampi(ceili(delta.length() / (CELL * 0.28)), 1, 5)
    for i in range(1, samples + 1):
        var sample: Vector3 = previous.lerp(candidate, float(i) / float(samples))
        sample.y = main.height_at_world(sample.x, sample.z) + 0.04
        var query := PhysicsShapeQueryParameters3D.new()
        query.shape = capsule_shape
        query.transform = Transform3D(Basis(), sample + Vector3(0.0, CAPSULE_HEIGHT * 0.5, 0.0))
        query.collision_mask = NpcConstantsScript.COLLISION_NPC_STATIC_QUERY_MASK
        query.collide_with_bodies = true
        query.collide_with_areas = false
        query.exclude = [body.get_rid()]
        var hits: Array = system.get_world_3d().direct_space_state.intersect_shape(query, 12)
        for hit in hits:
            var hit_dict: Dictionary = hit
            var collider := hit_dict.get("collider") as Node
            if collider == null or collider == body:
                continue
            if collider_blocks_capsule(entry, collider, body):
                return true
    return false

func collider_blocks_capsule(entry: Dictionary, collider: Node, body: CharacterBody3D) -> bool:
    var kind := String(collider.get_meta("kind", ""))
    if kind == "block":
        var block_type := String(collider.get_meta("block_type", ""))
        if block_type in ["cobblestonePath", "torch"]:
            return false
        if block_type == "door":
            if bool(collider.get_meta("open", false)):
                return false
            var door := interaction_door_for_collider(collider)
            if route_has_door_action(entry, door):
                if system != null:
                    system.open_door_for_npc(door, body)
                return true
            return true
        return true
    return kind in ["prop", "npc", "tutorial_npc", "hostile"]

func route_has_door_action(entry: Dictionary, door: Node) -> bool:
    door = interaction_door_for_collider(door)
    var actions: Dictionary = entry.get("routeActions", {})
    for action_value in actions.values():
        if not (action_value is Dictionary):
            continue
        var action: Dictionary = action_value
        if interaction_door_for_collider(action.get("door") as Node) == door:
            return true
    return false

func interaction_door_for_collider(collider: Node) -> Node:
    if collider == null:
        return null
    if system != null:
        var main_node = system.get("main")
        if main_node != null and main_node.has_method("interaction_block_from_collider"):
            var interaction_block = main_node.interaction_block_from_collider(collider)
            if interaction_block != null and interaction_block is Node:
                return interaction_block
    return collider

func set_route_status(entry: Dictionary, status: String, reason: String) -> void:
    entry["routeStatus"] = status
    entry["routeReason"] = reason
    var body := entry.get("body") as Node
    if body:
        body.set_meta("npc_route_status", status)
        body.set_meta("npc_route_reason", reason)

func increment_route_replan(entry: Dictionary) -> void:
    entry["routeReplans"] = int(entry.get("routeReplans", 0)) + 1
    if system != null:
        system.npc_route_replans += 1
        system.npc_path_detours += 1

func increment_stuck_recovery(entry: Dictionary) -> void:
    entry["stuckRecoveries"] = int(entry.get("stuckRecoveries", 0)) + 1
    if system != null:
        system.npc_stuck_recoveries += 1

func increment_reservation_wait(entry: Dictionary) -> void:
    entry["reservationWaits"] = int(entry.get("reservationWaits", 0)) + 1
    entry["routeWaitTicks"] = int(entry.get("routeWaitTicks", 0)) + 1
    if system != null:
        system.npc_reservation_waits += 1

func increment_validated_move(entry: Dictionary) -> void:
    entry["validatedMoves"] = int(entry.get("validatedMoves", 0)) + 1
    if system != null:
        system.npc_validated_moves += 1

func count_unreachable_once(entry: Dictionary, intent: Dictionary, reason: String) -> void:
    var target_cell: Vector2i = intent.get("targetCell", Vector2i.ZERO)
    var signature: String = "%s:%d,%d:%s" % [String(intent.get("kind", "move")), target_cell.x, target_cell.y, reason]
    if String(entry.get("lastUnreachableSignature", "")) == signature:
        return
    entry["lastUnreachableSignature"] = signature
    entry["unreachableGoals"] = int(entry.get("unreachableGoals", 0)) + 1
    if system != null:
        system.npc_unreachable_goals += 1

func flat_distance(a: Vector3, b: Vector3) -> float:
    return Vector2(a.x - b.x, a.z - b.z).length()
