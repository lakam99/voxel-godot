extends RefCounted
class_name NpcRouteMovementController

const CELL := 1.35
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcCorridorFollowerScript := preload("res://scripts/npc_ai/movement/NpcCorridorFollower.gd")
const ReciprocalAvoidanceAdapterScript := preload("res://scripts/npc_ai/movement/ReciprocalAvoidanceAdapter.gd")
const CAPSULE_RADIUS := 0.34
const CAPSULE_HEIGHT := 1.64
const DOOR_ACTION_LOOKAHEAD_CELLS := 4

var system
var main
var capsule_shape: CapsuleShape3D
var corridor_follower
var avoidance_adapter

func setup(system_node, main_node) -> void:
    system = system_node
    main = main_node
    capsule_shape = CapsuleShape3D.new()
    capsule_shape.radius = CAPSULE_RADIUS
    capsule_shape.height = CAPSULE_HEIGHT
    corridor_follower = NpcCorridorFollowerScript.new()
    avoidance_adapter = ReciprocalAvoidanceAdapterScript.new()
    avoidance_adapter.setup(system, main)

func begin_frame() -> void:
    if avoidance_adapter != null:
        avoidance_adapter.begin_frame()

func move(entry: Dictionary, intent: Dictionary, max_distance: float, planner, world) -> Dictionary:
    var body := entry.get("body") as CharacterBody3D
    if body == null or main == null or planner == null or world == null or max_distance <= 0.0:
        return { "moved": 0.0, "status": "blocked", "reason": "missing_context" }
    var previous: Vector3 = body.global_position
    var target: Vector3 = intent.get("target", previous)
    var arrival_radius: float = float(intent.get("arrivalRadius", CELL * 0.75))
    var moving_home := bool(intent.get("movingHome", false))
    var strict_arrival := bool(intent.get("strictArrival", false)) or String(intent.get("kind", "")) == "scripted" or moving_home
    if String(entry.get("activeDoorPortalId", "")) == "":
        entry.erase("_activeDoorForwardStep")
    if flat_distance(previous, target) <= arrival_radius:
        clear_route(entry)
        set_route_status(entry, "arrived", "")
        return { "moved": 0.0, "status": "arrived", "reason": "" }

    var route: Dictionary = ensure_route(entry, intent, planner, world)
    if not bool(route.get("ok", false)):
        set_route_status(entry, String(route.get("status", "blocked")), String(route.get("reason", "blocked")))
        if String(route.get("status", "")) != "pending":
            count_unreachable_once(entry, intent, String(route.get("reason", "blocked")))
        return { "moved": 0.0, "status": String(route.get("status", "blocked")), "reason": String(route.get("reason", "blocked")) }
    if String(route.get("status", "")) == "arrived":
        if strict_arrival and flat_distance(previous, target) > arrival_radius:
            seed_strict_final_waypoint(entry, target, world)
        else:
            clear_route(entry)
            set_route_status(entry, "arrived", "")
            return { "moved": 0.0, "status": "arrived", "reason": "" }

    if should_restore_from_door_stage(entry, previous):
        clear_door_stage(entry)
        entry["routeForceReplan"] = true
        route = ensure_route(entry, intent, planner, world)
        if not bool(route.get("ok", false)):
            set_route_status(entry, String(route.get("status", "blocked")), String(route.get("reason", "blocked")))
            count_unreachable_once(entry, intent, String(route.get("reason", "blocked")))
            return { "moved": 0.0, "status": String(route.get("status", "blocked")), "reason": String(route.get("reason", "blocked")) }
        trim_active_door_approach_cells(entry, world)

    trim_active_door_approach_cells(entry, world)
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
        trim_active_door_approach_cells(entry, world)
        path_waypoints = entry.get("pathWaypoints", [])
        if path_waypoints.is_empty():
            if String(entry.get("activeDoorPortalId", "")) != "":
                if seed_active_door_forward_step(entry, world):
                    path_waypoints = entry.get("pathWaypoints", [])
                else:
                    release_stale_active_door_route(entry)
                    set_route_status(entry, "waiting", "active_door_replan")
                    return { "moved": 0.0, "status": "waiting", "reason": "active_door_replan" }
        if path_waypoints.is_empty():
            set_route_status(entry, "blocked", "empty_route")
            count_unreachable_once(entry, intent, "empty_route")
            return { "moved": 0.0, "status": "blocked", "reason": "empty_route" }

    var priority := int(intent.get("priority", 0))
    entry["routePriority"] = priority
    var next_cell: Vector2i = next_route_cell(entry, world)
    var door_wait: String = handle_door_action(entry, next_cell, world, priority)
    if door_wait == "":
        door_wait = handle_upcoming_door_action(entry, next_cell, world, priority)
    path_waypoints = entry.get("pathWaypoints", [])
    if door_wait != "":
        set_route_status(entry, "waiting", door_wait)
        increment_reservation_wait(entry)
        return { "moved": 0.0, "status": "waiting", "reason": door_wait }

    var allow_outside := bool(intent.get("allowOutside", false))
    var actors := []
    if system != null and system.has_method("current_door_actors"):
        actors = system.call("current_door_actors")
    var follow: Dictionary = corridor_follower.compute_step(
        entry,
        body,
        previous,
        target,
        path_waypoints,
        intent,
        max_distance,
        world,
        self,
        avoidance_adapter,
        actors
    )
    entry["corridorFollow"] = compact_follow_result(follow)
    record_follow_metrics(follow)
    if bool(follow.get("arrived", false)):
        clear_route(entry)
        set_route_status(entry, "arrived", "")
        return { "moved": 0.0, "status": "arrived", "reason": "" }
    if not bool(follow.get("ok", false)):
        var portal_recenter_result := try_portal_clearance_recenter(entry, previous, follow, intent, max_distance, world, priority, String(follow.get("reason", "")))
        if not portal_recenter_result.is_empty():
            return portal_recenter_result
        var retreat_result := try_dynamic_yield_retreat(entry, previous, follow, intent, max_distance, world, actors, priority)
        if not retreat_result.is_empty():
            return retreat_result
        entry["blockedMoveTime"] = float(entry.get("blockedMoveTime", 0.0)) + max_distance
        if system != null:
            system.npc_blocked_moves += 1
        if float(entry.get("blockedMoveTime", 0.0)) > CELL * 0.90:
            entry["routeForceReplan"] = true
            entry["blockedMoveTime"] = 0.0
            increment_stuck_recovery(entry)
        var follow_reason := String(follow.get("reason", "blocked"))
        var classification := String(follow.get("classification", "blocked"))
        if classification == "traffic_reservation":
            increment_reservation_wait(entry)
        set_route_status(entry, "waiting", follow_reason)
        return { "moved": 0.0, "status": "waiting", "reason": follow_reason, "classification": classification }

    var move_candidate: Vector3 = follow.get("candidate", previous)
    var traffic_result := request_traffic_step(entry, previous, move_candidate, world, intent, priority)
    if not bool(traffic_result.get("ok", false)):
        increment_reservation_wait(entry)
        var final_reason := String(traffic_result.get("reason", "traffic_wait"))
        if traffic_result.has("cycleResolution"):
            final_reason = "yielding"
        if final_reason in ["no_safe_interval", "planner_guard"] and int(entry.get("routeWaitTicks", 0)) > 4:
            entry["routeForceReplan"] = true
        set_route_status(entry, "waiting", final_reason)
        return { "moved": 0.0, "status": "waiting", "reason": final_reason, "classification": "traffic_reservation", "traffic": traffic_result }

    var physics_delta := maxf(0.0001, float(intent.get("physicsDelta", 0.0166667)))
    var motor_result: Dictionary = {}
    if system != null and system.has_method("apply_npc_route_motion"):
        motor_result = system.apply_npc_route_motion(entry, previous, move_candidate, physics_delta)
    else:
        return { "moved": 0.0, "status": "blocked", "reason": "missing_motion_adapter" }
    var actual_position: Vector3 = motor_result.get("position", body.global_position)
    var moved := float(motor_result.get("moved", flat_distance(previous, actual_position)))
    var motor_reason := String(motor_result.get("reason", "motor_blocked"))
    var progress_result: Dictionary = corridor_follower.record_motion(entry, previous, actual_position, entry.get("pathWaypoints", []), motor_reason)
    entry["corridorProgress"] = progress_result
    if bool(motor_result.get("blocked", false)) and moved <= 0.001:
        var portal_recenter_result := try_portal_clearance_recenter(entry, previous, follow, intent, max_distance, world, priority, motor_reason)
        if not portal_recenter_result.is_empty():
            return portal_recenter_result
        if motor_reason == "static_or_dynamic_collision":
            var motor_retreat_follow := follow.duplicate(true)
            motor_retreat_follow["reason"] = "yielding"
            var motor_retreat_result := try_dynamic_yield_retreat(entry, previous, motor_retreat_follow, intent, max_distance, world, actors, priority)
            if not motor_retreat_result.is_empty():
                return motor_retreat_result
        entry["blockedMoveTime"] = float(entry.get("blockedMoveTime", 0.0)) + max_distance
        if system != null:
            system.npc_blocked_moves += 1
        if float(entry.get("blockedMoveTime", 0.0)) > CELL * 0.90:
            entry["routeForceReplan"] = true
            entry["blockedMoveTime"] = 0.0
            increment_stuck_recovery(entry)
        set_route_status(entry, "waiting", motor_reason)
        return { "moved": moved, "status": "waiting", "reason": motor_reason }
    entry["blockedMoveTime"] = 0.0
    entry["routeWaitTicks"] = 0
    entry["routeYieldTicks"] = 0
    set_route_status(entry, "moving", "")
    trim_reached_route_cells(entry, world)
    increment_validated_move(entry)
    return { "moved": moved, "status": String(entry.get("routeStatus", "moving")), "reason": "" }

func try_dynamic_yield_retreat(entry: Dictionary, previous: Vector3, follow: Dictionary, intent: Dictionary, max_distance: float, world, actors: Array, priority: int) -> Dictionary:
    var reason := String(follow.get("reason", ""))
    if not (reason in ["yielding", "cell_reserved", "yield_blocked"]):
        return {}
    var blocker := follow.get("blocker") as Node3D
    if blocker == null or not is_instance_valid(blocker):
        blocker = nearest_dynamic_blocker(previous, entry, actors)
    if blocker == null or not is_instance_valid(blocker):
        return {}
    var blocker_offset := previous - blocker.global_position
    blocker_offset.y = 0.0
    var blocker_distance := blocker_offset.length()
    if blocker_distance >= NpcConstantsScript.TRAFFIC_RETREAT_CLEARANCE:
        return {}
    var attempted: Vector3 = follow.get("candidate", previous)
    var retreat_direction := previous - attempted
    retreat_direction.y = 0.0
    if retreat_direction.length_squared() <= 0.0001:
        retreat_direction = blocker_offset
    if retreat_direction.length_squared() <= 0.0001:
        return {}
    retreat_direction = retreat_direction.normalized()
    var retreat_distance := minf(
        max_distance * NpcConstantsScript.TRAFFIC_RETREAT_DISTANCE_SCALE,
        maxf(0.0, NpcConstantsScript.TRAFFIC_RETREAT_CLEARANCE - blocker_distance + 0.04)
    )
    if retreat_distance <= 0.001:
        return {}
    var candidate := previous + retreat_direction * retreat_distance
    candidate.y = previous.y
    if candidate.distance_to(blocker.global_position) <= previous.distance_to(blocker.global_position):
        candidate = previous + blocker_offset.normalized() * retreat_distance
        candidate.y = previous.y
    var moving_home := bool(intent.get("movingHome", false))
    var allow_outside := bool(intent.get("allowOutside", false))
    var validation: Dictionary = validate_candidate(entry, previous, candidate, moving_home, allow_outside, world, priority)
    var validation_reason := String(validation.get("reason", ""))
    if not bool(validation.get("ok", false)) and not (validation_reason in ["yielding", "blocked_dynamic", "cell_reserved", "yield_blocked"]):
        return {}
    var physics_delta := maxf(0.0001, float(intent.get("physicsDelta", 0.0166667)))
    var motor_result: Dictionary = {}
    if system != null and system.has_method("apply_npc_route_motion"):
        motor_result = system.apply_npc_route_motion(entry, previous, candidate, physics_delta)
    else:
        return {}
    var actual_position: Vector3 = motor_result.get("position", previous)
    var moved := float(motor_result.get("moved", flat_distance(previous, actual_position)))
    if moved <= 0.001:
        return {}
    if corridor_follower != null and corridor_follower.has_method("record_motion"):
        entry["corridorProgress"] = corridor_follower.record_motion(entry, previous, actual_position, entry.get("pathWaypoints", []), "yielding_retreat")
    increment_reservation_wait(entry)
    set_route_status(entry, "waiting", "yielding_retreat")
    return { "moved": moved, "status": "waiting", "reason": "yielding_retreat", "classification": "traffic_reservation" }

func try_portal_clearance_recenter(entry: Dictionary, previous: Vector3, follow: Dictionary, intent: Dictionary, max_distance: float, world, priority: int, motor_reason: String) -> Dictionary:
    if not bool(follow.get("portalMode", false)) or not (motor_reason in ["static_or_dynamic_collision", "blocked_static", "blocked_capsule"]):
        return {}
    var direction := String(entry.get("activeDoorDirection", ""))
    var axis := axis_for_door_direction(direction)
    if axis.length_squared() <= 0.0001:
        return {}
    var lateral := portal_centerline_lateral(entry, previous, direction)
    if lateral.length_squared() <= 0.0001:
        var velocity: Vector3 = follow.get("safeVelocity", Vector3.ZERO)
        if velocity.length_squared() <= 0.0001:
            velocity = follow.get("desiredVelocity", Vector3.ZERO)
        velocity.y = 0.0
        lateral = velocity - axis * velocity.dot(axis)
    if lateral.length_squared() <= 0.0001:
        var target: Vector3 = intent.get("target", previous)
        var target_delta := target - previous
        target_delta.y = 0.0
        lateral = target_delta - axis * target_delta.dot(axis)
    if lateral.length_squared() <= 0.0001:
        return {}
    var recenter_distance := minf(max_distance * NpcConstantsScript.PORTAL_RECENTER_DISTANCE_SCALE, NpcConstantsScript.CELL_SIZE * 0.12)
    if recenter_distance <= 0.001:
        return try_portal_axis_retreat(entry, previous, intent, max_distance, world, priority, axis)
    var candidate := previous + lateral.normalized() * recenter_distance
    candidate.y = previous.y
    var moving_home := bool(intent.get("movingHome", false))
    var allow_outside := bool(intent.get("allowOutside", false))
    var validation: Dictionary = validate_candidate(entry, previous, candidate, moving_home, allow_outside, world, priority)
    if not bool(validation.get("ok", false)):
        return try_portal_axis_retreat(entry, previous, intent, max_distance, world, priority, axis)
    var physics_delta := maxf(0.0001, float(intent.get("physicsDelta", 0.0166667)))
    var motor_result: Dictionary = {}
    if system != null and system.has_method("apply_npc_route_motion"):
        motor_result = system.apply_npc_route_motion(entry, previous, validation.get("candidate", candidate), physics_delta)
    else:
        return try_portal_axis_retreat(entry, previous, intent, max_distance, world, priority, axis)
    var actual_position: Vector3 = motor_result.get("position", previous)
    var moved := float(motor_result.get("moved", flat_distance(previous, actual_position)))
    if moved <= 0.001:
        return try_portal_axis_retreat(entry, previous, intent, max_distance, world, priority, axis)
    if corridor_follower != null and corridor_follower.has_method("record_motion"):
        entry["corridorProgress"] = corridor_follower.record_motion(entry, previous, actual_position, entry.get("pathWaypoints", []), "portal_recentering")
    increment_validated_move(entry)
    set_route_status(entry, "waiting", "portal_recentering")
    return { "moved": moved, "status": "waiting", "reason": "portal_recentering", "classification": "door_state" }

func try_portal_axis_retreat(entry: Dictionary, previous: Vector3, intent: Dictionary, max_distance: float, world, priority: int, axis: Vector3) -> Dictionary:
    if axis.length_squared() <= 0.0001:
        return {}
    var retreat_distance := minf(max_distance * NpcConstantsScript.PORTAL_RETREAT_DISTANCE_SCALE, NpcConstantsScript.CELL_SIZE * 0.18)
    if retreat_distance <= 0.001:
        return {}
    var candidate := previous - axis.normalized() * retreat_distance
    candidate.y = previous.y
    var moving_home := bool(intent.get("movingHome", false))
    var allow_outside := bool(intent.get("allowOutside", false))
    var validation: Dictionary = validate_candidate(entry, previous, candidate, moving_home, allow_outside, world, priority)
    if not bool(validation.get("ok", false)):
        return {}
    var physics_delta := maxf(0.0001, float(intent.get("physicsDelta", 0.0166667)))
    var motor_result: Dictionary = {}
    if system != null and system.has_method("apply_npc_route_motion"):
        motor_result = system.apply_npc_route_motion(entry, previous, validation.get("candidate", candidate), physics_delta)
    else:
        return {}
    var actual_position: Vector3 = motor_result.get("position", previous)
    var moved := float(motor_result.get("moved", flat_distance(previous, actual_position)))
    if moved <= 0.001:
        return {}
    if corridor_follower != null and corridor_follower.has_method("record_motion"):
        entry["corridorProgress"] = corridor_follower.record_motion(entry, previous, actual_position, entry.get("pathWaypoints", []), "portal_retreat")
    increment_reservation_wait(entry)
    set_route_status(entry, "waiting", "portal_retreat")
    return { "moved": moved, "status": "waiting", "reason": "portal_retreat", "classification": "door_state" }

func portal_centerline_lateral(entry: Dictionary, previous: Vector3, direction: String) -> Vector3:
    if system == null or system.get("autonomy_system") == null:
        return Vector3.ZERO
    var autonomy = system.get("autonomy_system")
    if autonomy == null or autonomy.get("door_portals") == null:
        return Vector3.ZERO
    var portal_id := String(entry.get("activeDoorPortalId", ""))
    if portal_id == "":
        return Vector3.ZERO
    var portals: Dictionary = autonomy.get("door_portals").get("portals")
    var portal = portals.get(portal_id)
    if portal == null:
        return Vector3.ZERO
    var center: Vector3 = portal.threshold_bounds.position + portal.threshold_bounds.size * 0.5
    if direction in ["x+", "x-"]:
        return Vector3(0.0, 0.0, center.z - previous.z)
    if direction in ["z+", "z-"]:
        return Vector3(center.x - previous.x, 0.0, 0.0)
    return Vector3.ZERO

func axis_for_door_direction(direction: String) -> Vector3:
    if direction == "x+":
        return Vector3.RIGHT
    if direction == "x-":
        return Vector3.LEFT
    if direction == "z+":
        return Vector3.BACK
    if direction == "z-":
        return Vector3.FORWARD
    return Vector3.ZERO

func nearest_dynamic_blocker(position: Vector3, entry: Dictionary, actors: Array) -> Node3D:
    var body := entry.get("body") as Node3D
    var best: Node3D = null
    var best_distance := INF
    for actor in actors:
        var other := actor as Node3D
        if other == null or other == body or not is_instance_valid(other):
            continue
        var distance := Vector2(position.x - other.global_position.x, position.z - other.global_position.z).length()
        if distance < best_distance:
            best_distance = distance
            best = other
    return best

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
    var cached_reason := String(entry.get("routeReason", ""))
    var transient_empty_route := cached_reason in ["empty_route", "static_or_dynamic_collision", "blocked_dynamic", "yielding", "local_blocked"]
    needs_route = needs_route or (current_waypoints.is_empty() and (not route_known or not empty_route_waiting_for_reason or transient_empty_route))
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

    bump_traffic_generation(entry, "route_replacement")
    var route: Dictionary = planner.plan_route(entry, intent)
    if String(route.get("status", "")) == "pending":
        entry["routeForceReplan"] = true
        if not current_waypoints.is_empty():
            set_route_status(entry, "moving", "route_pending")
            return {
                "ok": true,
                "status": "routed",
                "reason": "route_pending",
                "cells": entry.get("routeCells", []),
                "waypoints": current_waypoints,
                "actions": entry.get("routeActions", {}),
                "targetCell": target_cell,
                "fallbackCell": entry.get("routeFallbackCell", target_cell),
                "snapshotRevision": String(entry.get("routeSnapshotRevision", snapshot_revision))
            }
        set_route_status(entry, "pending", String(route.get("reason", "route_pending")))
        return route
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
    if system != null and system.has_method("release_npc_traffic_reservations"):
        system.release_npc_traffic_reservations(entry, "route_completed")
    entry["pathWaypoints"] = []
    entry["routeCells"] = []
    entry["routeActions"] = {}
    entry["routeForceReplan"] = false
    entry.erase("_activeDoorForwardStep")

func seed_strict_final_waypoint(entry: Dictionary, target: Vector3, world) -> void:
    var target_cell: Vector2i = world.world_cell(target)
    entry["routeCells"] = [target_cell]
    entry["pathWaypoints"] = [target]
    entry["routeActions"] = {}
    entry["routeFallbackCell"] = target_cell
    set_route_status(entry, "moving", "")

func trim_active_door_approach_cells(entry: Dictionary, world = null) -> void:
    var active_portal_id := String(entry.get("activeDoorPortalId", ""))
    if active_portal_id == "":
        return
    var cells: Array = entry.get("routeCells", [])
    var waypoints: Array = entry.get("pathWaypoints", [])
    var direction := String(entry.get("activeDoorDirection", ""))
    var body := entry.get("body") as Node3D
    if world != null and direction != "" and body != null and is_instance_valid(body):
        var current_cell: Vector2i = world.world_cell(body.global_position)
        var pruned := 0
        while not cells.is_empty() and cells[0] is Vector2i and route_cell_behind_active_door(cells[0], current_cell, direction):
            cells.remove_at(0)
            pruned += 1
            if not waypoints.is_empty():
                waypoints.remove_at(0)
        if pruned > 0:
            entry["routeForceReplan"] = true
        entry["routeCells"] = cells
        entry["pathWaypoints"] = waypoints
    if cells.size() <= 2 or waypoints.is_empty():
        return
    var actions: Dictionary = entry.get("routeActions", {})
    var action_cell := Vector2i(999999, 999999)
    for action_value in actions.values():
        if not (action_value is Dictionary):
            continue
        var action: Dictionary = action_value
        if String(action.get("kind", "")) != "door":
            continue
        if String(action.get("portalId", "")) != active_portal_id:
            continue
        var cell_value = action.get("cell")
        if cell_value is Vector2i:
            action_cell = cell_value
            break
    if action_cell == Vector2i(999999, 999999):
        return
    var action_index: int = cells.find(action_cell)
    while action_index > 1 and not cells.is_empty() and not waypoints.is_empty():
        cells.remove_at(0)
        waypoints.remove_at(0)
        action_index -= 1
    entry["routeCells"] = cells
    entry["pathWaypoints"] = waypoints

func route_cell_behind_active_door(cell: Vector2i, current_cell: Vector2i, direction: String) -> bool:
    if direction == "x+":
        return cell.x <= current_cell.x
    if direction == "x-":
        return cell.x >= current_cell.x
    if direction == "z+":
        return cell.y <= current_cell.y
    if direction == "z-":
        return cell.y >= current_cell.y
    return false

func release_stale_active_door_route(entry: Dictionary) -> void:
    var actor_id := String(entry.get("activeDoorActorId", entry.get("id", "")))
    if system != null and system.has_method("release_npc_door_hold") and actor_id != "":
        system.release_npc_door_hold(actor_id, true)
    if system != null and system.has_method("release_npc_traffic_reservations"):
        system.release_npc_traffic_reservations(entry, "active_door_route_replan")
    entry.erase("activeDoorPortalId")
    entry.erase("activeDoorActorId")
    entry.erase("activeDoorDirection")
    entry.erase("activeDoorTrafficGroupId")
    entry["routeActions"] = {}
    entry["routeForceReplan"] = true
    entry.erase("_activeDoorForwardStep")

func seed_active_door_forward_step(entry: Dictionary, world) -> bool:
    var direction := String(entry.get("activeDoorDirection", ""))
    var body := entry.get("body") as Node3D
    if direction == "" or body == null or not is_instance_valid(body) or world == null:
        return false
    var current_cell: Vector2i = world.world_cell(body.global_position)
    var step := Vector2i.ZERO
    if direction == "x+":
        step = Vector2i(1, 0)
    elif direction == "x-":
        step = Vector2i(-1, 0)
    elif direction == "z+":
        step = Vector2i(0, 1)
    elif direction == "z-":
        step = Vector2i(0, -1)
    if step == Vector2i.ZERO:
        return false
    var next_cell := current_cell + step
    var door_cell := active_door_portal_cell(entry, world)
    if door_cell != Vector2i(999999, 999999):
        if direction == "x+" and next_cell.x <= door_cell.x:
            next_cell = door_cell + step
        elif direction == "x-" and next_cell.x >= door_cell.x:
            next_cell = door_cell + step
        elif direction == "z+" and next_cell.y <= door_cell.y:
            next_cell = door_cell + step
        elif direction == "z-" and next_cell.y >= door_cell.y:
            next_cell = door_cell + step
    entry["routeCells"] = [next_cell]
    entry["pathWaypoints"] = [world.cell_position(next_cell)]
    entry["routeForceReplan"] = false
    entry["_activeDoorForwardStep"] = true
    return true

func active_door_portal_cell(entry: Dictionary, world) -> Vector2i:
    if system == null or world == null:
        return Vector2i(999999, 999999)
    var portal_id := String(entry.get("activeDoorPortalId", ""))
    if portal_id == "":
        return Vector2i(999999, 999999)
    var autonomy = system.get("autonomy_system") if system.has_method("get") else null
    if autonomy == null:
        return Vector2i(999999, 999999)
    var door_portals = autonomy.get("door_portals") if autonomy.has_method("get") else null
    if door_portals == null:
        return Vector2i(999999, 999999)
    var portals: Dictionary = door_portals.get("portals")
    var portal = portals.get(portal_id)
    if portal == null:
        return Vector2i(999999, 999999)
    var bounds: AABB = portal.get("threshold_bounds")
    return world.world_cell(bounds.position + bounds.size * 0.5)

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
    if system != null:
        var traversal: Dictionary = system.request_npc_door_traversal(door, body, entry, action) if system.has_method("request_npc_door_traversal") else {}
        if not bool(traversal.get("ok", false)):
            if traversal.has("stagePosition") and body != null:
                var stage_position: Vector3 = traversal.get("stagePosition", body.global_position)
                if apply_door_stage(entry, body, stage_position, world, String(traversal.get("portalId", ""))):
                    return ""
            return String(traversal.get("reason", "door_waiting"))
        clear_door_stage(entry)
    if not bool(door.get_meta("open", false)):
        return "door_opening"
    return ""

func handle_upcoming_door_action(entry: Dictionary, next_cell: Vector2i, world, priority := 0) -> String:
    if String(entry.get("activeDoorPortalId", "")) != "":
        return ""
    var actions: Dictionary = entry.get("routeActions", {})
    if actions.is_empty():
        return ""
    var route_cells: Array = entry.get("routeCells", [])
    var body := entry.get("body") as Node3D
    if body == null:
        return ""
    var sorted_keys := actions.keys()
    sorted_keys.sort()
    for action_key in sorted_keys:
        var action_value = actions[action_key]
        if not (action_value is Dictionary):
            continue
        var action: Dictionary = action_value
        if String(action.get("kind", "")) != "door":
            continue
        var cell_value = action.get("cell")
        if not (cell_value is Vector2i):
            continue
        var action_cell: Vector2i = cell_value
        if action_cell == next_cell:
            continue
        var action_index: int = route_cells.find(action_cell)
        if action_index < 0 or action_index > DOOR_ACTION_LOOKAHEAD_CELLS:
            continue
        var door_value = action.get("door")
        if door_value == null or not is_instance_valid(door_value) or not (door_value is Node):
            continue
        if system == null or not system.has_method("request_npc_door_traversal"):
            continue
        var door: Node = door_value as Node
        var traversal: Dictionary = system.request_npc_door_traversal(door, body, entry, action)
        if bool(traversal.get("ok", false)):
            clear_door_stage(entry)
            return ""
        if traversal.has("stagePosition"):
            var stage_position: Vector3 = traversal.get("stagePosition", body.global_position)
            if apply_door_stage(entry, body, stage_position, world, String(traversal.get("portalId", ""))):
                return ""
        return String(traversal.get("reason", "door_waiting"))
    return ""

func apply_door_stage(entry: Dictionary, body: Node3D, stage_position: Vector3, world, portal_id: String) -> bool:
    if body == null or world == null:
        return false
    if door_stage_position_occupied(entry, body, stage_position):
        return false
    if flat_distance(body.global_position, stage_position) <= CELL * 0.24:
        return false
    entry["doorStageActive"] = true
    entry["doorStagePortalId"] = portal_id
    entry["doorStagePosition"] = stage_position
    entry["pathWaypoints"] = [stage_position]
    entry["routeCells"] = [world.world_cell(stage_position)]
    return true

func door_stage_position_occupied(entry: Dictionary, body: Node3D, stage_position: Vector3) -> bool:
    if system == null or not system.has_method("current_door_actors"):
        return false
    var actors: Array = system.call("current_door_actors")
    for actor_value in actors:
        var actor := actor_value as Node3D
        if actor == null or not is_instance_valid(actor) or actor == body:
            continue
        if flat_distance(actor.global_position, stage_position) <= CELL * 0.72:
            return true
    return false

func should_restore_from_door_stage(entry: Dictionary, position: Vector3) -> bool:
    if not bool(entry.get("doorStageActive", false)):
        return false
    if String(entry.get("activeDoorPortalId", "")) != "":
        return true
    var stage_position: Vector3 = entry.get("doorStagePosition", position)
    return flat_distance(position, stage_position) <= CELL * 0.42

func clear_door_stage(entry: Dictionary) -> void:
    entry.erase("doorStageActive")
    entry.erase("doorStagePortalId")
    entry.erase("doorStagePosition")

func compact_follow_result(follow: Dictionary) -> Dictionary:
    var avoidance: Dictionary = follow.get("avoidance", {}) if follow.has("avoidance") else {}
    return {
        "ok": bool(follow.get("ok", false)),
        "arrived": bool(follow.get("arrived", false)),
        "reason": String(follow.get("reason", "")),
        "classification": String(follow.get("classification", "")),
        "portalMode": bool(follow.get("portalMode", false)),
        "avoidanceActive": bool(avoidance.get("active", false)),
        "avoidanceReason": String(avoidance.get("reason", "")),
        "callbackFresh": bool(avoidance.get("callbackFresh", false)),
        "fallbackUsed": bool(avoidance.get("fallbackUsed", false)),
        "activeAvoidanceCount": int(avoidance.get("activeRegistrationCount", 0)),
        "remainingDistance": float(follow.get("remainingDistance", 0.0))
    }

func record_follow_metrics(follow: Dictionary) -> void:
    if system == null:
        return
    var avoidance: Dictionary = follow.get("avoidance", {}) if follow.has("avoidance") else {}
    if bool(avoidance.get("active", false)):
        system.set("npc_avoidance_active_frames", int(system.get("npc_avoidance_active_frames")) + 1)
    if bool(avoidance.get("callbackFresh", false)):
        system.set("npc_avoidance_callback_frames", int(system.get("npc_avoidance_callback_frames")) + 1)
    if bool(avoidance.get("fallbackUsed", false)):
        system.set("npc_avoidance_fallback_frames", int(system.get("npc_avoidance_fallback_frames")) + 1)
    if int(avoidance.get("activeRegistrationCount", 0)) > 0:
        system.set("npc_avoidance_active_registrations", max(int(system.get("npc_avoidance_active_registrations")), int(avoidance.get("activeRegistrationCount", 0))))

func corridor_stats() -> Dictionary:
    return corridor_follower.stats() if corridor_follower != null and corridor_follower.has_method("stats") else {}

func avoidance_stats() -> Dictionary:
    return avoidance_adapter.stats() if avoidance_adapter != null and avoidance_adapter.has_method("stats") else {}

func cleanup_actor_state(actor_id: String) -> Dictionary:
    var before: Dictionary = avoidance_adapter.stats() if avoidance_adapter != null and avoidance_adapter.has_method("stats") else {}
    if avoidance_adapter != null and avoidance_adapter.has_method("disable_actor"):
        avoidance_adapter.disable_actor(actor_id, true)
    var after: Dictionary = avoidance_adapter.stats() if avoidance_adapter != null and avoidance_adapter.has_method("stats") else {}
    return {
        "avoidance": max(0, int(before.get("registeredAgents", 0)) - int(after.get("registeredAgents", 0))),
        "before": before,
        "after": after
    }

func cleanup_all() -> Dictionary:
    var before: Dictionary = avoidance_adapter.stats() if avoidance_adapter != null and avoidance_adapter.has_method("stats") else {}
    var released := 0
    if avoidance_adapter != null and avoidance_adapter.has_method("cleanup_all"):
        released = int(avoidance_adapter.cleanup_all())
    var after: Dictionary = avoidance_adapter.stats() if avoidance_adapter != null and avoidance_adapter.has_method("stats") else {}
    return {
        "avoidance": max(released, max(0, int(before.get("registeredAgents", 0)) - int(after.get("registeredAgents", 0)))),
        "before": before,
        "after": after
    }

func request_traffic_step(entry: Dictionary, previous: Vector3, candidate: Vector3, world, intent: Dictionary, priority: int) -> Dictionary:
    if system == null or not system.has_method("request_npc_traffic_step"):
        return { "ok": true, "status": "granted", "reason": "traffic_unavailable" }
    var traffic_intent := intent.duplicate(true)
    traffic_intent["priority"] = priority
    return system.request_npc_traffic_step(entry, previous, candidate, world, traffic_intent)

func bump_traffic_generation(entry: Dictionary, reason: String) -> void:
    if system != null and system.has_method("release_npc_traffic_generation"):
        system.release_npc_traffic_generation(entry, reason)
    entry["trafficOwnerGeneration"] = int(entry.get("trafficOwnerGeneration", 0)) + 1
    entry.erase("activeTrafficStepGroup")
    entry.erase("trafficWaitReason")

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
    var body := entry.get("body") as CharacterBody3D
    if body != null and not bool(entry.get("_activeDoorForwardStep", false)) and capsule_hits_obstacle(entry, body, previous, candidate):
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
            var action := route_door_action(entry, door)
            if not action.is_empty():
                if system != null and system.has_method("request_npc_door_traversal"):
                    system.request_npc_door_traversal(door, body, entry, action)
                return true
            return true
        return true
    return kind in ["prop", "npc", "tutorial_npc", "hostile"]

func route_has_door_action(entry: Dictionary, door: Node) -> bool:
    return not route_door_action(entry, door).is_empty()

func route_door_action(entry: Dictionary, door: Node) -> Dictionary:
    door = interaction_door_for_collider(door)
    var actions: Dictionary = entry.get("routeActions", {})
    for action_value in actions.values():
        if not (action_value is Dictionary):
            continue
        var action: Dictionary = action_value
        if interaction_door_for_collider(action.get("door") as Node) == door:
            return action
    return {}

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
