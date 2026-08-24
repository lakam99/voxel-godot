extends RefCounted
class_name NpcRouteMovementController

const CELL := 1.35
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const HomeInteriorServiceScript := preload("res://scripts/npc_ai/behavior/HomeInteriorService.gd")
const NpcCorridorFollowerScript := preload("res://scripts/npc_ai/movement/NpcCorridorFollower.gd")
const NpcRouteStateStoreScript := preload("res://scripts/npc_ai/routing/NpcRouteStateStore.gd")
const CAPSULE_RADIUS := 0.34
const DOOR_ACTION_LOOKAHEAD_CELLS := 4
const DOOR_ACTION_DIRECT_MAX_CELL_STEPS := 2
const DOOR_ACTION_LOOKAHEAD_MAX_CELL_STEPS := 3
const DOOR_ACTION_COLLISION_MAX_CELL_STEPS := 2
const DOOR_ACTION_DIRECT_MAX_DISTANCE := CELL * 2.75
const DOOR_ACTION_LOOKAHEAD_MAX_DISTANCE := CELL * 3.15
const DOOR_ACTION_COLLISION_MAX_DISTANCE := CELL * 2.35
const YIELD_RETREAT_HOLD_TICKS := 10
const PORTAL_RECENTER_FORWARD_STEP_TICKS := 12
const PORTAL_RECENTER_REPLAN_TICKS := 30
const DYNAMIC_DETOUR_WAIT_TICKS := 24
const DYNAMIC_ROUTE_AVOID_WAIT_TICKS := 12
const DYNAMIC_ROUTE_AVOID_RECENT_YIELD_LIMIT := 6
const DYNAMIC_YIELD_STREAK_WINDOW_FRAMES := 90
const DYNAMIC_ROUTE_AVOID_TTL_FRAMES := 180
const DYNAMIC_ROUTE_AVOID_MAX_CELLS := 8
const STATIC_FOOTPRINT_VALIDATION_RADIUS := CAPSULE_RADIUS * 0.52
const MOTOR_LOCAL_ESCAPE_MIN_DISTANCE := CELL * 0.16
const MOTOR_LOCAL_ESCAPE_MAX_DISTANCE := CELL * 0.30
const PENDING_ROUTE_RETRY_DEFAULT_FRAMES := 4
const PENDING_ROUTE_RETRY_DOOR_FRAMES := 4
const PENDING_ROUTE_RETRY_ACTIVE_PORTAL_FRAMES := 4
const PENDING_ROUTE_RETRY_LOW_PRIORITY_FRAMES := 8
const FAILED_ROUTE_RETRY_DEFAULT_FRAMES := 8
const FAILED_ROUTE_RETRY_ACTIVE_PORTAL_FRAMES := 4
const FAILED_ROUTE_RETRY_LOW_PRIORITY_FRAMES := 12

var system
var main
var corridor_follower
var avoidance_adapter
var frame_claimed_cells := {}

func setup(system_node, main_node) -> void:
    system = system_node
    main = main_node
    corridor_follower = NpcCorridorFollowerScript.new()
    var autonomy = system.get("autonomy_system") if system != null else null
    avoidance_adapter = autonomy.get("crowd_velocity_service") if autonomy != null else null

func begin_frame() -> void:
    frame_claimed_cells.clear()
    if avoidance_adapter != null:
        avoidance_adapter.begin_frame()

func performance_monitor():
    return main.get("runtime_perf_monitor") if main != null else null

func move(entry: Dictionary, intent: Dictionary, max_distance: float, planner, world) -> Dictionary:
    var body := entry.get("body") as CharacterBody3D
    if body == null or main == null or planner == null or world == null or avoidance_adapter == null or max_distance <= 0.0:
        return { "moved": 0.0, "status": "blocked", "reason": "missing_context" }
    var previous: Vector3 = body.global_position
    var target: Vector3 = intent.get("target", previous)
    var arrival_radius: float = float(intent.get("arrivalRadius", CELL * 0.75))
    var moving_home := bool(intent.get("movingHome", false))
    var strict_arrival := bool(intent.get("strictArrival", false)) or moving_home
    var priority := int(intent.get("priority", 0))
    if String(entry.get("activeDoorPortalId", "")) == "":
        entry.erase("_activeDoorForwardStep")
    if flat_distance(previous, target) <= arrival_radius:
        clear_route(entry)
        set_route_status(entry, "arrived", "")
        return { "moved": 0.0, "status": "arrived", "reason": "" }

    var monitor = performance_monitor()
    var route_start: int = monitor.begin_section("npc_motion_ensure_route") if monitor != null else Time.get_ticks_usec()
    var route: Dictionary = ensure_route(entry, intent, planner, world)
    if monitor != null:
        monitor.end_section("npc_motion_ensure_route", route_start)
    if not bool(route.get("ok", false)):
        if String(entry.get("activeDoorPortalId", "")) != "" and (entry.get("pathWaypoints", []) as Array).is_empty() and seed_active_door_forward_step(entry, world):
            route = {
                "ok": true,
                "status": "routed",
                "reason": "active_door_forward_clearance",
                "cells": entry.get("routeCells", []),
                "waypoints": entry.get("pathWaypoints", []),
                "actions": entry.get("routeActions", {}),
                "targetCell": intent.get("targetCell", world.world_cell(target)),
                "fallbackCell": entry.get("routeFallbackCell", world.world_cell(target)),
                "snapshotRevision": route_reuse_revision(world)
            }
        else:
            var route_failure_reason := String(route.get("reason", "blocked"))
            var clearance_recovery := try_home_door_clearance_recovery(entry, previous, intent, max_distance, world, priority, route_failure_reason)
            if not clearance_recovery.is_empty():
                return clearance_recovery
            if skip_optional_home_waypoint_if_static_blocked(entry, route_failure_reason):
                set_route_status(entry, "waiting", "home_optional_waypoint_skip")
                return { "moved": 0.0, "status": "waiting", "reason": "home_optional_waypoint_skip", "classification": "home_route" }
            if skip_optional_home_waypoint_if_endpoint_unsnappable(entry, route_failure_reason):
                set_route_status(entry, "waiting", "home_optional_endpoint_skip")
                return { "moved": 0.0, "status": "waiting", "reason": "home_optional_endpoint_skip", "classification": "home_route" }
            if String(entry.get("activeDoorPortalId", "")) != "" and String(route.get("status", "")) != "pending":
                release_stale_active_door_route(entry)
                set_route_status(entry, "waiting", "active_door_replan")
                return { "moved": 0.0, "status": "waiting", "reason": "active_door_replan" }
            if String(route.get("status", "")) != "pending":
                record_blocked_endpoint_cell(entry, route)
            set_route_status(entry, String(route.get("status", "blocked")), route_failure_reason)
            if String(route.get("status", "")) != "pending":
                count_unreachable_once(entry, intent, route_failure_reason)
            return { "moved": 0.0, "status": String(route.get("status", "blocked")), "reason": route_failure_reason }
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
        route_start = monitor.begin_section("npc_motion_ensure_route") if monitor != null else Time.get_ticks_usec()
        route = ensure_route(entry, intent, planner, world)
        if monitor != null:
            monitor.end_section("npc_motion_ensure_route", route_start)
        if not bool(route.get("ok", false)):
            if String(route.get("status", "")) == "pending":
                set_route_status(entry, "pending", String(route.get("reason", "route_pending")))
                return { "moved": 0.0, "status": "pending", "reason": String(route.get("reason", "route_pending")) }
            set_route_status(entry, String(route.get("status", "blocked")), String(route.get("reason", "blocked")))
            count_unreachable_once(entry, intent, String(route.get("reason", "blocked")))
            return { "moved": 0.0, "status": String(route.get("status", "blocked")), "reason": String(route.get("reason", "blocked")) }
        trim_active_door_approach_cells(entry, world)

    trim_active_door_approach_cells(entry, world)
    trim_reached_route_cells(entry, world)
    if skip_optional_home_approach_if_oscillating(entry):
        set_route_status(entry, "waiting", "home_approach_replan")
        return { "moved": 0.0, "status": "waiting", "reason": "home_approach_replan" }
    if String(entry.get("activeDoorPortalId", "")) != "" and not bool(entry.get("_activeDoorForwardStep", false)):
        seed_active_door_forward_step(entry, world)
    elif active_door_needs_forward_clearance_step(entry, world):
        seed_active_door_forward_step(entry, world)
    var path_waypoints: Array = entry.get("pathWaypoints", [])
    while not path_waypoints.is_empty() and flat_distance(previous, path_waypoints[0]) <= CELL * 0.36:
        trim_route_prefix(entry, 1)
        path_waypoints = entry.get("pathWaypoints", [])
    if path_waypoints.is_empty():
        var final_arrival_radius := arrival_radius if strict_arrival else maxf(arrival_radius, CELL * 0.95)
        if flat_distance(previous, target) <= final_arrival_radius:
            clear_route(entry)
            set_route_status(entry, "arrived", "")
            return { "moved": 0.0, "status": "arrived", "reason": "" }
        entry["routeForceReplan"] = true
        route_start = monitor.begin_section("npc_motion_ensure_route") if monitor != null else Time.get_ticks_usec()
        route = ensure_route(entry, intent, planner, world)
        if monitor != null:
            monitor.end_section("npc_motion_ensure_route", route_start)
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
            if String(route.get("status", "")) == "pending":
                set_route_status(entry, "pending", String(route.get("reason", "route_pending")))
                return { "moved": 0.0, "status": "pending", "reason": String(route.get("reason", "route_pending")) }
            set_route_status(entry, "blocked", "empty_route")
            count_unreachable_once(entry, intent, "empty_route")
            return { "moved": 0.0, "status": "blocked", "reason": "empty_route" }

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
    var held_retreat_result := continue_dynamic_yield_retreat(entry, previous, intent, max_distance, world, actors, priority)
    if not held_retreat_result.is_empty():
        return held_retreat_result
    var follow_start: int = monitor.begin_section("npc_corridor_follow") if monitor != null else Time.get_ticks_usec()
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
    if monitor != null:
        monitor.end_section("npc_corridor_follow", follow_start)
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
        var static_escape_result := try_static_collision_escape(entry, previous, follow, intent, max_distance, world, priority)
        if not static_escape_result.is_empty():
            return static_escape_result
        var clearance_recovery := try_home_door_clearance_recovery(entry, previous, intent, max_distance, world, priority, String(follow.get("reason", "")))
        if not clearance_recovery.is_empty():
            return clearance_recovery
        if skip_optional_home_waypoint_if_static_blocked(entry, String(follow.get("reason", ""))):
            set_route_status(entry, "waiting", "home_optional_waypoint_skip")
            return { "moved": 0.0, "status": "waiting", "reason": "home_optional_waypoint_skip", "classification": "static_collision" }
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
        if follow_reason in ["yielding", "blocked_dynamic", "portal_reservation_authority"] and String(entry.get("activeDoorPortalId", "")) != "" and not bool(entry.get("holdDoorOrder", false)) and int(entry.get("routeWaitTicks", 0)) > 30:
            release_stale_active_door_route(entry)
            set_route_status(entry, "waiting", "active_door_replan")
            return { "moved": 0.0, "status": "waiting", "reason": "active_door_replan", "classification": "door_state" }
        set_route_status(entry, "waiting", follow_reason)
        return { "moved": 0.0, "status": "waiting", "reason": follow_reason, "classification": classification }

    var move_candidate: Vector3 = follow.get("candidate", previous)
    var traffic_start: int = monitor.begin_section("npc_traffic_step_request") if monitor != null else Time.get_ticks_usec()
    var traffic_result := request_traffic_step(entry, previous, move_candidate, world, intent, priority)
    if monitor != null:
        monitor.end_section("npc_traffic_step_request", traffic_start)
    if not bool(traffic_result.get("ok", false)):
        increment_reservation_wait(entry)
        var final_reason := String(traffic_result.get("reason", "traffic_wait"))
        if traffic_result.has("cycleResolution"):
            final_reason = "yielding"
        if final_reason == "yielding":
            var traffic_retreat_follow := follow.duplicate(true)
            traffic_retreat_follow["reason"] = "yielding"
            traffic_retreat_follow["candidate"] = move_candidate
            var traffic_retreat_result := try_dynamic_yield_retreat(entry, previous, traffic_retreat_follow, intent, max_distance, world, actors, priority)
            if not traffic_retreat_result.is_empty():
                return traffic_retreat_result
        if final_reason in ["yielding", "blocked_dynamic", "portal_reservation_authority"] and String(entry.get("activeDoorPortalId", "")) != "" and not bool(entry.get("holdDoorOrder", false)) and int(entry.get("routeWaitTicks", 0)) > 30:
            release_stale_active_door_route(entry)
            set_route_status(entry, "waiting", "active_door_replan")
            return { "moved": 0.0, "status": "waiting", "reason": "active_door_replan", "classification": "door_state" }
        if final_reason in ["no_safe_interval", "planner_guard"] and int(entry.get("routeWaitTicks", 0)) > 4:
            entry["routeForceReplan"] = true
        set_route_status(entry, "waiting", final_reason)
        return { "moved": 0.0, "status": "waiting", "reason": final_reason, "classification": "traffic_reservation", "traffic": traffic_result }

    var physics_delta := maxf(0.0001, float(intent.get("physicsDelta", 0.0166667)))
    var motor_result: Dictionary = {}
    if system != null and system.has_method("apply_npc_route_motion"):
        var motor_start: int = monitor.begin_section("npc_motion_motor_call") if monitor != null else Time.get_ticks_usec()
        motor_result = system.apply_npc_route_motion(entry, previous, move_candidate, physics_delta)
        if monitor != null:
            monitor.end_section("npc_motion_motor_call", motor_start)
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
        var motor_static_escape_result := try_static_collision_escape(entry, previous, follow, intent, max_distance, world, priority)
        if not motor_static_escape_result.is_empty():
            return motor_static_escape_result
        var motor_local_escape_result := try_motor_blocked_local_escape(entry, previous, follow, intent, max_distance, world, priority, motor_reason)
        if not motor_local_escape_result.is_empty():
            return motor_local_escape_result
        var clearance_recovery := try_home_door_clearance_recovery(entry, previous, intent, max_distance, world, priority, motor_reason)
        if not clearance_recovery.is_empty():
            return clearance_recovery
        if skip_optional_home_waypoint_if_static_blocked(entry, motor_reason):
            set_route_status(entry, "waiting", "home_optional_waypoint_skip")
            return { "moved": 0.0, "status": "waiting", "reason": "home_optional_waypoint_skip", "classification": "static_collision" }
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
    entry.erase("portalRecenterTicks")
    clear_dynamic_yield_retreat(entry)
    claim_frame_occupancy(entry, previous, actual_position, world)
    set_route_status(entry, "moving", "")
    trim_reached_route_cells(entry, world)
    increment_validated_move(entry)
    return { "moved": moved, "status": String(entry.get("routeStatus", "moving")), "reason": "" }

func continue_dynamic_yield_retreat(entry: Dictionary, previous: Vector3, intent: Dictionary, max_distance: float, world, actors: Array, priority: int) -> Dictionary:
    var ticks := int(entry.get("_yieldRetreatTicks", 0))
    if ticks <= 0:
        clear_dynamic_yield_retreat(entry)
        return {}
    var blocker := yield_retreat_blocker(entry, actors)
    if blocker == null or not is_instance_valid(blocker):
        clear_dynamic_yield_retreat(entry)
        return {}
    var offset := previous - blocker.global_position
    offset.y = 0.0
    var blocker_distance := offset.length()
    if blocker_distance >= NpcConstantsScript.TRAFFIC_RETREAT_CLEARANCE:
        clear_dynamic_yield_retreat(entry)
        return {}
    var direction: Vector3 = entry.get("_yieldRetreatDirection", Vector3.ZERO)
    direction.y = 0.0
    if direction.length_squared() <= 0.0001:
        direction = offset
    if direction.length_squared() <= 0.0001:
        clear_dynamic_yield_retreat(entry)
        return {}
    direction = direction.normalized()
    var deficit := maxf(0.0, NpcConstantsScript.TRAFFIC_RETREAT_CLEARANCE - blocker_distance)
    var retreat_distance := minf(max_distance * 0.85, maxf(max_distance * 0.35, deficit + 0.08))
    var candidate := previous + direction * retreat_distance
    candidate.y = previous.y
    var follow := {
        "reason": "yielding",
        "blocker": blocker,
        "candidate": candidate,
        "portalMode": String(entry.get("activeDoorPortalId", "")) != ""
    }
    var result := apply_dynamic_yield_retreat(entry, previous, follow, intent, max_distance, world, blocker, direction, priority)
    if result.is_empty():
        clear_dynamic_yield_retreat(entry)
        return {}
    entry["_yieldRetreatTicks"] = ticks - 1
    return result

func try_dynamic_yield_retreat(entry: Dictionary, previous: Vector3, follow: Dictionary, intent: Dictionary, max_distance: float, world, actors: Array, priority: int) -> Dictionary:
    var reason := String(follow.get("reason", ""))
    if not (reason in ["yielding", "cell_reserved", "yield_blocked"]):
        return {}
    var blocker := follow.get("blocker") as Node3D
    if blocker == null or not is_instance_valid(blocker):
        blocker = nearest_dynamic_blocker(previous, entry, actors)
    if blocker == null or not is_instance_valid(blocker):
        return {}
    var recent_yield_count := record_dynamic_yield_streak(entry)
    var should_replan_for_yield := int(entry.get("routeWaitTicks", 0)) >= DYNAMIC_ROUTE_AVOID_WAIT_TICKS
    should_replan_for_yield = should_replan_for_yield or recent_yield_count >= DYNAMIC_ROUTE_AVOID_RECENT_YIELD_LIMIT
    if should_replan_for_yield and mark_dynamic_route_avoidance_for_yield(entry, blocker, previous, follow, intent, world):
        clear_dynamic_yield_retreat(entry)
        entry.erase("_yieldRetreatRecentCount")
        entry.erase("_yieldRetreatLastFrame")
        set_route_status(entry, "waiting", "dynamic_avoid_replan")
        return { "moved": 0.0, "status": "waiting", "reason": "dynamic_avoid_replan", "classification": "traffic_reservation" }
    var detour_result := try_dynamic_detour_around_blocker(entry, previous, follow, intent, max_distance, world, blocker, priority)
    if not detour_result.is_empty():
        return detour_result
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
        retreat_direction = blocker_offset.normalized()
    follow["candidate"] = candidate
    return apply_dynamic_yield_retreat(entry, previous, follow, intent, max_distance, world, blocker, retreat_direction, priority)

func apply_dynamic_yield_retreat(entry: Dictionary, previous: Vector3, follow: Dictionary, intent: Dictionary, max_distance: float, world, blocker: Node3D, retreat_direction: Vector3, priority: int) -> Dictionary:
    if blocker == null or not is_instance_valid(blocker):
        return {}
    var candidate: Vector3 = follow.get("candidate", previous)
    var blocker_offset := previous - blocker.global_position
    blocker_offset.y = 0.0
    if candidate.distance_to(blocker.global_position) <= previous.distance_to(blocker.global_position) and blocker_offset.length_squared() > 0.0001:
        var fallback_distance := minf(max_distance * 0.85, maxf(max_distance * 0.35, NpcConstantsScript.TRAFFIC_RETREAT_CLEARANCE - blocker_offset.length() + 0.08))
        candidate = previous + blocker_offset.normalized() * fallback_distance
        candidate.y = previous.y
        retreat_direction = blocker_offset.normalized()
    retreat_direction.y = 0.0
    if retreat_direction.length_squared() <= 0.0001:
        return {}
    retreat_direction = retreat_direction.normalized()
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
    claim_frame_occupancy(entry, previous, actual_position, world)
    increment_reservation_wait(entry)
    entry["_yieldRetreatTicks"] = max(YIELD_RETREAT_HOLD_TICKS, int(entry.get("_yieldRetreatTicks", 0)))
    entry["_yieldRetreatDirection"] = retreat_direction
    entry["_yieldRetreatBlockerId"] = blocker.get_instance_id()
    entry["routeYieldTicks"] = int(entry.get("routeYieldTicks", 0)) + 1
    set_route_status(entry, "waiting", "yielding_retreat")
    return { "moved": moved, "status": "waiting", "reason": "yielding_retreat", "classification": "traffic_reservation" }

func try_dynamic_detour_around_blocker(entry: Dictionary, previous: Vector3, follow: Dictionary, intent: Dictionary, max_distance: float, world, blocker: Node3D, priority: int) -> Dictionary:
    if blocker == null or not is_instance_valid(blocker):
        return {}
    if int(entry.get("routeWaitTicks", 0)) < DYNAMIC_DETOUR_WAIT_TICKS and int(entry.get("corridorNoProgressTicks", 0)) < DYNAMIC_DETOUR_WAIT_TICKS:
        return {}
    var axis: Vector3 = follow.get("safeVelocity", Vector3.ZERO)
    axis.y = 0.0
    if axis.length_squared() <= 0.0001:
        axis = follow.get("desiredVelocity", Vector3.ZERO)
        axis.y = 0.0
    if axis.length_squared() <= 0.0001:
        var target: Vector3 = intent.get("target", previous)
        axis = target - previous
        axis.y = 0.0
    if axis.length_squared() <= 0.0001:
        return {}
    axis = axis.normalized()
    var side := Vector3(-axis.z, 0.0, axis.x)
    var candidates: Array[Vector3] = []
    var side_distance := max_distance * 0.85
    var forward_distance := max_distance * 0.28
    candidates.append(previous + side * side_distance + axis * forward_distance)
    candidates.append(previous - side * side_distance + axis * forward_distance)
    candidates.append(previous + side * side_distance)
    candidates.append(previous - side * side_distance)
    var target_position: Vector3 = intent.get("target", previous)
    candidates.sort_custom(func(a: Vector3, b: Vector3) -> bool:
        return flat_distance(a, target_position) < flat_distance(b, target_position)
    )
    var previous_blocker_distance := flat_distance(previous, blocker.global_position)
    for candidate in candidates:
        candidate.y = previous.y
        if flat_distance(candidate, blocker.global_position) <= previous_blocker_distance + 0.02:
            continue
        var validation: Dictionary = validate_candidate(entry, previous, candidate, bool(intent.get("movingHome", false)), bool(intent.get("allowOutside", false)), world, priority)
        if not bool(validation.get("ok", false)):
            continue
        var physics_delta := maxf(0.0001, float(intent.get("physicsDelta", 0.0166667)))
        var motor_result: Dictionary = {}
        if system != null and system.has_method("apply_npc_route_motion"):
            motor_result = system.apply_npc_route_motion(entry, previous, validation.get("candidate", candidate), physics_delta)
        else:
            return {}
        var actual_position: Vector3 = motor_result.get("position", previous)
        var moved := float(motor_result.get("moved", flat_distance(previous, actual_position)))
        if moved <= 0.001:
            continue
        if corridor_follower != null and corridor_follower.has_method("record_motion"):
            entry["corridorProgress"] = corridor_follower.record_motion(entry, previous, actual_position, entry.get("pathWaypoints", []), "dynamic_detour")
        claim_frame_occupancy(entry, previous, actual_position, world)
        entry["blockedMoveTime"] = 0.0
        entry["routeWaitTicks"] = 0
        entry["routeYieldTicks"] = 0
        entry["routeForceReplan"] = true
        clear_dynamic_yield_retreat(entry)
        set_route_status(entry, "moving", "dynamic_detour")
        return { "moved": moved, "status": "moving", "reason": "dynamic_detour", "classification": "dynamic_actor" }
    return {}

func try_static_collision_escape(entry: Dictionary, previous: Vector3, follow: Dictionary, intent: Dictionary, max_distance: float, world, priority: int) -> Dictionary:
    var reason := String(follow.get("reason", ""))
    if not (reason in ["blocked_static", "blocked_capsule", "static_or_dynamic_collision"]):
        return {}
    var blocked_time := float(entry.get("blockedMoveTime", 0.0)) + max_distance
    if blocked_time < CELL * 0.18 and int(entry.get("corridorNoProgressTicks", 0)) < 6:
        return {}
    if mark_static_route_avoidance_for_blocker(entry, follow, previous, intent, world):
        invalidate_active_route_for_replan(entry, "static_avoid_replan")
        set_route_status(entry, "waiting", "static_avoid_replan")
        return { "moved": 0.0, "status": "waiting", "reason": "static_avoid_replan", "classification": "static_collision" }
    var axis: Vector3 = follow.get("safeVelocity", Vector3.ZERO)
    axis.y = 0.0
    if axis.length_squared() <= 0.0001:
        axis = follow.get("desiredVelocity", Vector3.ZERO)
        axis.y = 0.0
    if axis.length_squared() <= 0.0001:
        var target: Vector3 = intent.get("target", previous)
        axis = target - previous
        axis.y = 0.0
    if axis.length_squared() <= 0.0001:
        return {}
    axis = axis.normalized()
    var side := Vector3(-axis.z, 0.0, axis.x)
    var side_distance := max_distance * 0.82
    var forward_distance := max_distance * 0.24
    var back_distance := max_distance * 0.18
    var candidates: Array[Vector3] = [
        previous + side * side_distance + axis * forward_distance,
        previous - side * side_distance + axis * forward_distance,
        previous + side * side_distance,
        previous - side * side_distance,
        previous + side * side_distance - axis * back_distance,
        previous - side * side_distance - axis * back_distance
    ]
    var target_position: Vector3 = intent.get("target", previous)
    candidates.sort_custom(func(a: Vector3, b: Vector3) -> bool:
        return flat_distance(a, target_position) < flat_distance(b, target_position)
    )
    for candidate in candidates:
        candidate.y = previous.y
        if flat_distance(candidate, previous) > max_distance:
            var offset := candidate - previous
            offset.y = 0.0
            if offset.length_squared() <= 0.0001:
                continue
            candidate = previous + offset.normalized() * max_distance
            candidate.y = previous.y
        var validation: Dictionary = validate_candidate(entry, previous, candidate, bool(intent.get("movingHome", false)), bool(intent.get("allowOutside", false)), world, priority)
        if not bool(validation.get("ok", false)):
            continue
        var physics_delta := maxf(0.0001, float(intent.get("physicsDelta", 0.0166667)))
        var motor_result: Dictionary = {}
        if system != null and system.has_method("apply_npc_route_motion"):
            motor_result = system.apply_npc_route_motion(entry, previous, validation.get("candidate", candidate), physics_delta)
        else:
            return {}
        var actual_position: Vector3 = motor_result.get("position", previous)
        var moved := float(motor_result.get("moved", flat_distance(previous, actual_position)))
        if moved <= 0.001:
            continue
        if corridor_follower != null and corridor_follower.has_method("record_motion"):
            entry["corridorProgress"] = corridor_follower.record_motion(entry, previous, actual_position, entry.get("pathWaypoints", []), "static_detour")
        claim_frame_occupancy(entry, previous, actual_position, world)
        entry["blockedMoveTime"] = 0.0
        entry["routeWaitTicks"] = 0
        entry["routeYieldTicks"] = 0
        entry["routeForceReplan"] = true
        clear_dynamic_yield_retreat(entry)
        set_route_status(entry, "moving", "static_detour")
        return { "moved": moved, "status": "moving", "reason": "static_detour", "classification": "static_collision" }
    return {}

func mark_static_route_avoidance_for_blocker(entry: Dictionary, follow: Dictionary, previous: Vector3, intent: Dictionary, world) -> bool:
    if world == null:
        return false
    var blocker_value = follow.get("blocker", {})
    if not (blocker_value is Dictionary):
        return false
    var blocker: Dictionary = blocker_value
    var blocker_cell := Vector2i(999999, 999999)
    for key in ["cell", "sampleCell", "candidateCell"]:
        var cell_value = blocker.get(key)
        if cell_value is Vector2i:
            blocker_cell = cell_value
            break
        if cell_value is Array and (cell_value as Array).size() >= 2:
            blocker_cell = Vector2i(int((cell_value as Array)[0]), int((cell_value as Array)[1]))
            break
    if blocker_cell == Vector2i(999999, 999999):
        return false
    var marked := mark_dynamic_route_avoidance_cell_value(entry, blocker_cell, previous, intent, world)
    if marked:
        entry["lastStaticRouteAvoidCell"] = blocker_cell
    return marked

func try_motor_blocked_local_escape(entry: Dictionary, previous: Vector3, follow: Dictionary, intent: Dictionary, max_distance: float, world, priority: int, motor_reason: String) -> Dictionary:
    if not (motor_reason in ["blocked_static", "blocked_capsule", "static_or_dynamic_collision", "terrain_step_rejected"]):
        return {}
    if int(entry.get("corridorNoProgressTicks", 0)) < NpcConstantsScript.CORRIDOR_NO_PROGRESS_TICKS and float(entry.get("blockedMoveTime", 0.0)) < CELL * 0.24:
        return {}
    var axis: Vector3 = follow.get("desiredVelocity", Vector3.ZERO)
    axis.y = 0.0
    if axis.length_squared() <= 0.0001:
        axis = follow.get("safeVelocity", Vector3.ZERO)
        axis.y = 0.0
    if axis.length_squared() <= 0.0001:
        var target_position: Vector3 = intent.get("target", previous)
        axis = target_position - previous
        axis.y = 0.0
    if axis.length_squared() <= 0.0001:
        return {}
    axis = axis.normalized()
    var side := Vector3(-axis.z, 0.0, axis.x)
    var escape_distance := clampf(maxf(max_distance * 2.5, MOTOR_LOCAL_ESCAPE_MIN_DISTANCE), MOTOR_LOCAL_ESCAPE_MIN_DISTANCE, MOTOR_LOCAL_ESCAPE_MAX_DISTANCE)
    var target: Vector3 = intent.get("target", previous)
    var centerline_candidates: Array[Vector3] = centerline_recovery_candidates(previous, target, escape_distance)
    var candidates: Array[Vector3] = []
    var directions: Array[Vector3] = [
        side,
        -side,
        (axis + side).normalized(),
        (axis - side).normalized(),
        (-axis + side).normalized(),
        (-axis - side).normalized(),
        axis,
        -axis
    ]
    for direction in directions:
        if direction.length_squared() <= 0.0001:
            continue
        candidates.append(previous + direction * escape_distance)
    candidates.sort_custom(func(a: Vector3, b: Vector3) -> bool:
        return flat_distance(a, target) < flat_distance(b, target)
    )
    candidates = centerline_candidates + candidates
    var rejected_candidates: Array = []
    for candidate in candidates:
        candidate.y = previous.y
        var validation: Dictionary = validate_candidate(entry, previous, candidate, bool(intent.get("movingHome", false)), bool(intent.get("allowOutside", false)), world, priority)
        if not bool(validation.get("ok", false)):
            if rejected_candidates.size() < 8:
                rejected_candidates.append({
                    "candidate": candidate,
                    "reason": String(validation.get("reason", "")),
                    "ownerId": String(validation.get("ownerId", "")),
                    "cell": validation.get("cell", Vector2i(999999, 999999))
                })
            continue
        var physics_delta := maxf(0.0001, float(intent.get("physicsDelta", 0.0166667)))
        var motor_result: Dictionary = {}
        if system != null and system.has_method("apply_npc_route_motion"):
            motor_result = system.apply_npc_route_motion(entry, previous, validation.get("candidate", candidate), physics_delta)
        else:
            return {}
        var actual_position: Vector3 = motor_result.get("position", previous)
        var moved := float(motor_result.get("moved", flat_distance(previous, actual_position)))
        if moved <= 0.001:
            if rejected_candidates.size() < 8:
                rejected_candidates.append({
                    "candidate": validation.get("candidate", candidate),
                    "reason": String(motor_result.get("reason", "motor_blocked")),
                    "moved": moved,
                    "contactName": String(motor_result.get("blockedContactName", "")),
                    "contactKind": String(motor_result.get("blockedContactKind", "")),
                    "contactType": String(motor_result.get("blockedContactType", "")),
                    "slideCollisionCount": int(motor_result.get("slideCollisionCount", 0))
                })
            continue
        if corridor_follower != null and corridor_follower.has_method("record_motion"):
            entry["corridorProgress"] = corridor_follower.record_motion(entry, previous, actual_position, entry.get("pathWaypoints", []), "motor_local_escape")
        claim_frame_occupancy(entry, previous, actual_position, world)
        entry["blockedMoveTime"] = 0.0
        entry["routeWaitTicks"] = 0
        entry["routeYieldTicks"] = 0
        entry["routeForceReplan"] = true
        entry["lastMotorLocalEscape"] = {
            "from": previous,
            "to": actual_position,
            "requested": validation.get("candidate", candidate),
            "motorReason": motor_reason,
            "contactName": String(motor_result.get("blockedContactName", "")),
            "contactKind": String(motor_result.get("blockedContactKind", "")),
            "contactType": String(motor_result.get("blockedContactType", "")),
            "slideCollisionCount": int(motor_result.get("slideCollisionCount", 0)),
            "rejected": rejected_candidates
        }
        clear_dynamic_yield_retreat(entry)
        set_route_status(entry, "moving", "motor_local_escape")
        return { "moved": moved, "status": "moving", "reason": "motor_local_escape", "classification": String(entry.get("corridorBlockerClass", "blocked")) }
    entry["lastMotorLocalEscapeFailed"] = {
        "position": previous,
        "motorReason": motor_reason,
        "candidateCount": candidates.size(),
        "rejected": rejected_candidates
    }
    return {}

func centerline_recovery_candidates(previous: Vector3, target: Vector3, escape_distance: float) -> Array[Vector3]:
    var candidates: Array[Vector3] = []
    var delta := target - previous
    delta.y = 0.0
    if delta.length_squared() <= 0.0001:
        return candidates
    var candidate := previous
    if absf(delta.x) >= absf(delta.z):
        var step := minf(absf(delta.z), escape_distance)
        if step > 0.035:
            candidate.z += (1.0 if delta.z > 0.0 else -1.0) * step
            candidates.append(candidate)
    else:
        var step := minf(absf(delta.x), escape_distance)
        if step > 0.035:
            candidate.x += (1.0 if delta.x > 0.0 else -1.0) * step
            candidates.append(candidate)
    return candidates

func yield_retreat_blocker(entry: Dictionary, actors: Array) -> Node3D:
    var blocker_id := int(entry.get("_yieldRetreatBlockerId", 0))
    if blocker_id != 0:
        for actor in actors:
            var other := actor as Node3D
            if other != null and is_instance_valid(other) and other.get_instance_id() == blocker_id:
                return other
    return null

func clear_dynamic_yield_retreat(entry: Dictionary) -> void:
    entry.erase("_yieldRetreatTicks")
    entry.erase("_yieldRetreatDirection")
    entry.erase("_yieldRetreatBlockerId")

func try_portal_clearance_recenter(entry: Dictionary, previous: Vector3, follow: Dictionary, intent: Dictionary, max_distance: float, world, priority: int, motor_reason: String) -> Dictionary:
    if not bool(follow.get("portalMode", false)) or not (motor_reason in ["static_or_dynamic_collision", "blocked_static", "blocked_capsule", "blocked_dynamic", "portal_reservation_authority"]):
        return {}
    var recenter_ticks := int(entry.get("portalRecenterTicks", 0)) + 1
    entry["portalRecenterTicks"] = recenter_ticks
    if recenter_ticks > PORTAL_RECENTER_FORWARD_STEP_TICKS:
        if not bool(entry.get("_activeDoorForwardStep", false)) and seed_active_door_forward_step(entry, world):
            entry["portalRecenterTicks"] = 0
            set_route_status(entry, "waiting", "active_door_forward_clearance")
            return { "moved": 0.0, "status": "waiting", "reason": "active_door_forward_clearance", "classification": "door_state" }
    if recenter_ticks > PORTAL_RECENTER_REPLAN_TICKS:
        release_stale_active_door_route(entry)
        set_route_status(entry, "waiting", "active_door_replan")
        return { "moved": 0.0, "status": "waiting", "reason": "active_door_replan", "classification": "door_state" }
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
    claim_frame_occupancy(entry, previous, actual_position, world)
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
    claim_frame_occupancy(entry, previous, actual_position, world)
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

func record_dynamic_yield_streak(entry: Dictionary) -> int:
    var current_frame := Engine.get_physics_frames()
    var last_frame := int(entry.get("_yieldRetreatLastFrame", -999999))
    var count := int(entry.get("_yieldRetreatRecentCount", 0))
    if current_frame - last_frame > DYNAMIC_YIELD_STREAK_WINDOW_FRAMES:
        count = 0
    count += 1
    entry["_yieldRetreatRecentCount"] = count
    entry["_yieldRetreatLastFrame"] = current_frame
    return count

func mark_dynamic_route_avoidance_cell(entry: Dictionary, blocker: Node3D, previous: Vector3, intent: Dictionary, world) -> bool:
    if blocker == null or world == null:
        return false
    return mark_dynamic_route_avoidance_cell_value(entry, world.world_cell(blocker.global_position), previous, intent, world)

func mark_dynamic_route_avoidance_for_yield(entry: Dictionary, blocker: Node3D, previous: Vector3, follow: Dictionary, intent: Dictionary, world) -> bool:
    if world == null:
        return false
    var marked := false
    if blocker != null and is_instance_valid(blocker):
        marked = mark_dynamic_route_avoidance_cell_value(entry, world.world_cell(blocker.global_position), previous, intent, world) or marked
    if String(entry.get("activeDoorPortalId", "")) == "":
        var candidate: Vector3 = follow.get("candidate", previous)
        marked = mark_dynamic_route_avoidance_cell_value(entry, world.world_cell(candidate), previous, intent, world) or marked
    return marked

func mark_dynamic_route_avoidance_cell_value(entry: Dictionary, blocker_cell: Vector2i, previous: Vector3, intent: Dictionary, world) -> bool:
    if world == null:
        return false
    var current_cell: Vector2i = world.world_cell(previous)
    if blocker_cell == current_cell:
        return false
    var target_cell: Vector2i = intent.get("targetCell", world.world_cell(intent.get("target", previous)))
    if blocker_cell == target_cell:
        return false
    prune_dynamic_route_avoidance(entry)
    var cells: Array = entry.get("routeDynamicAvoidCells", [])
    var added := false
    if not cells.has(blocker_cell):
        cells.append(blocker_cell)
        added = true
    while cells.size() > DYNAMIC_ROUTE_AVOID_MAX_CELLS:
        cells.remove_at(0)
        added = true
    if not added and int(entry.get("routeDynamicAvoidUntilFrame", -1)) >= Engine.get_physics_frames():
        return false
    entry["routeDynamicAvoidCells"] = cells
    entry["routeDynamicAvoidUntilFrame"] = Engine.get_physics_frames() + DYNAMIC_ROUTE_AVOID_TTL_FRAMES
    entry["routeForceReplan"] = true
    return true

func prune_dynamic_route_avoidance(entry: Dictionary) -> void:
    if not entry.has("routeDynamicAvoidCells"):
        return
    var until_frame := int(entry.get("routeDynamicAvoidUntilFrame", -1))
    if until_frame >= Engine.get_physics_frames():
        return
    entry.erase("routeDynamicAvoidCells")
    entry.erase("routeDynamicAvoidUntilFrame")

func route_reuse_revision(world) -> String:
    if world != null and world.has_method("revision"):
        return String(world.revision())
    if world != null and world.has_method("navmesh_tile_source_key"):
        return String(world.navmesh_tile_source_key())
    return ""

func active_route_drifted_from_position(entry: Dictionary, current_waypoints: Array, start_position: Vector3, world) -> bool:
    if current_waypoints.is_empty():
        return false
    if world == null or not world.has_method("world_cell"):
        return false

    var current_cell: Vector2i = world.world_cell(start_position)
    var stored_current_cell_value = entry.get("routeLastKnownCell", current_cell)
    var stored_current_cell: Vector2i = stored_current_cell_value if stored_current_cell_value is Vector2i else current_cell
    entry["routeLastKnownCell"] = current_cell

    # Normal movement changes cells. Drift means the actor is no longer near
    # the next remaining waypoint.
    var first_waypoint_value = current_waypoints[0]
    if not (first_waypoint_value is Vector3):
        return true

    var first_waypoint: Vector3 = first_waypoint_value
    var distance_to_first := start_position.distance_to(first_waypoint)
    if distance_to_first > CELL * 4.0:
        var last_cell_distance := absi(current_cell.x - stored_current_cell.x) + absi(current_cell.y - stored_current_cell.y)
        if last_cell_distance > 2:
            return true

    return false

func ensure_route(entry: Dictionary, intent: Dictionary, planner, world) -> Dictionary:
    prune_dynamic_route_avoidance(entry)
    var monitor = performance_monitor()
    var route_key_start: int = monitor.begin_section("npc_route_key_eval") if monitor != null else Time.get_ticks_usec()
    var target_cell: Vector2i = intent.get("targetCell", world.world_cell(intent.get("target", Vector3.ZERO)))
    var body := entry.get("body") as Node3D
    var start_position: Vector3 = body.global_position if body != null and is_instance_valid(body) else entry.get("position", entry.get("porchPosition", intent.get("target", Vector3.ZERO)))
    var start_cell: Vector2i = world.world_cell(start_position)
    var current_waypoints: Array = entry.get("pathWaypoints", []) if entry.get("pathWaypoints", []) is Array else []
    var has_active_route := not current_waypoints.is_empty()
    var route_key_start_cell: Vector2i = start_cell
    if has_active_route and entry.get("routeStartCell", null) is Vector2i:
        route_key_start_cell = entry.get("routeStartCell", start_cell)

    var goal_key: String = "%s:%d,%d:%s:%s:%s:%s:%.3f" % [
        String(intent.get("kind", "move")),
        target_cell.x,
        target_cell.y,
        str(bool(intent.get("allowOutside", false))),
        str(bool(intent.get("movingHome", false))),
        String(intent.get("action", "")),
        str(bool(intent.get("strictArrival", false))),
        float(intent.get("arrivalRadius", CELL * 0.75))
    ]
    var route_key: String = "%d,%d->%s" % [
        route_key_start_cell.x,
        route_key_start_cell.y,
        goal_key
    ]
    if monitor != null:
        monitor.end_section("npc_route_key_eval", route_key_start)
    var revision_start: int = monitor.begin_section("npc_route_reuse_revision") if monitor != null else Time.get_ticks_usec()
    var snapshot_revision: String = route_reuse_revision(world)
    if monitor != null:
        monitor.end_section("npc_route_reuse_revision", revision_start)
    var stored_route_key := String(entry.get("routeKey", ""))
    var pending_route_key := String(entry.get("routePendingKey", ""))
    var stored_goal_key := String(entry.get("routeGoalKey", ""))
    var pending_goal_key := String(entry.get("routePendingGoalKey", ""))
    var comparison_route_key := stored_route_key if stored_route_key != "" else pending_route_key
    var comparison_goal_key := stored_goal_key if stored_goal_key != "" else pending_goal_key
    if comparison_goal_key == "" and comparison_route_key != "":
        var route_goal_separator := comparison_route_key.find("->")
        comparison_goal_key = comparison_route_key.substr(route_goal_separator + 2) if route_goal_separator >= 0 else comparison_route_key
    var comparison_snapshot_revision := String(entry.get("routeSnapshotRevision", ""))
    if comparison_snapshot_revision == "" and pending_route_key != "":
        comparison_snapshot_revision = String(entry.get("routePendingSnapshotRevision", ""))
    var route_known := comparison_route_key != ""
    var cached_lease: Dictionary = entry.get("routeLease", {}) if entry.get("routeLease", {}) is Dictionary else {}
    var cached_route_missing_lease := not current_waypoints.is_empty() and cached_lease.is_empty()
    var cached_status := String(entry.get("routeStatus", "idle"))
    var empty_route_waiting_for_reason := current_waypoints.is_empty() and cached_status in ["blocked", "waiting"]
    var goal_key_changed := comparison_goal_key != goal_key
    var active_route_drifted := active_route_drifted_from_position(entry, current_waypoints, start_position, world)
    var route_key_changed := goal_key_changed or active_route_drifted or (current_waypoints.is_empty() and comparison_route_key != route_key)
    var snapshot_revision_changed := comparison_snapshot_revision != snapshot_revision
    var needs_route: bool = bool(entry.get("routeForceReplan", false))
    needs_route = needs_route or route_key_changed
    needs_route = needs_route or snapshot_revision_changed
    needs_route = needs_route or cached_route_missing_lease
    var cached_reason := String(entry.get("routeReason", ""))
    var transient_empty_route := cached_reason in [
        "empty_route",
        "static_or_dynamic_collision",
        "blocked_dynamic",
        "yielding",
        "local_blocked",
        "endpoint_not_server_walkable",
        "no_start_server_walkable",
        "no_target_server_walkable",
        "path_endpoint_mismatch"
    ]
    needs_route = needs_route or (current_waypoints.is_empty() and (not route_known or not empty_route_waiting_for_reason or transient_empty_route))
    var changed_route_should_stop := route_key_changed \
        and String(entry.get("activeDoorPortalId", "")) == "" \
        and (bool(intent.get("movingHome", false)) or String(intent.get("kind", "")) in ["home", "scripted"])
    if changed_route_should_stop:
        entry["pathWaypoints"] = []
        entry["routeCells"] = []
        entry["routeActions"] = {}
        current_waypoints = []
    if cached_route_missing_lease:
        entry["pathWaypoints"] = []
        entry["routeCells"] = []
        entry["routeActions"] = {}
        NpcRouteStateStoreScript.clear_route_lease(entry, "NpcRouteMovementController.cached_missing_lease")
        current_waypoints = []
    if needs_route and current_waypoints.is_empty() and cached_status == "pending" and not route_key_changed and not snapshot_revision_changed:
        var retry_frame := int(entry.get("routePendingRetryFrame", -1))
        var current_frame := Engine.get_physics_frames()
        var ticket_state := String(entry.get("routeTicketState", ""))
        var ticket_resolved := NpcConstantsScript.NPC_NAV_ENABLE_ROUTE_TICKET_PIPELINE and ticket_state in [
            "ready",
            "following",
            "failed_invalid_goal",
            "failed_unreachable",
            "cancelled",
            "invalidated",
            "failed_internal"
        ]
        if retry_frame > current_frame and not ticket_resolved:
            if monitor != null:
                monitor.increment_counter("route_pending_backoff")
            return {
                "ok": false,
                "status": "pending",
                "reason": cached_reason,
                "cells": [],
                "waypoints": [],
                "actions": {},
                "targetCell": target_cell,
                "fallbackCell": entry.get("routeFallbackCell", target_cell),
                "snapshotRevision": snapshot_revision
            }
    if needs_route and current_waypoints.is_empty() and transient_empty_route and not route_key_changed and not snapshot_revision_changed:
        var failure_retry_frame := int(entry.get("routeFailureRetryFrame", -1))
        var failure_current_frame := Engine.get_physics_frames()
        if failure_retry_frame > failure_current_frame:
            var failure_monitor = performance_monitor()
            if failure_monitor != null:
                failure_monitor.increment_counter("route_failure_backoff")
            return {
                "ok": false,
                "status": cached_status,
                "reason": cached_reason,
                "cells": [],
                "waypoints": [],
                "actions": {},
                "targetCell": target_cell,
                "fallbackCell": entry.get("routeFallbackCell", target_cell),
                "snapshotRevision": snapshot_revision
            }
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
    var planner_start: int = monitor.begin_section("npc_route_planner_call") if monitor != null else Time.get_ticks_usec()
    var route: Dictionary = planner.plan_route(entry, intent)
    if monitor != null:
        monitor.end_section("npc_route_planner_call", planner_start)
    entry["lastRoutePlanDebug"] = compact_route_plan_debug(route)
    var route_has_authority := route.has("routeAuthorityState")
    if route_has_authority and bool(route.get("routeAuthorityReady", false)):
        var route_lease: Dictionary = route.get("routeLease", {}) if route.get("routeLease", {}) is Dictionary else {}
        if route_lease.is_empty():
            NpcRouteStateStoreScript.mark_route_missing_lease(route)
    if route_has_authority and not bool(route.get("routeAuthorityReady", false)):
        var authority_state := String(route.get("routeAuthorityState", ""))
        if authority_state in ["pending_nav_data", "pending_budget", "pending_probe"]:
            route["status"] = "pending"
        elif String(route.get("status", "")) not in ["pending", "blocked"]:
            route["status"] = "blocked"
    if String(route.get("status", "")) == "pending":
        entry["routeForceReplan"] = true
        entry["routePendingKey"] = route_key
        entry["routePendingSnapshotRevision"] = snapshot_revision
        entry["routePendingGoalKey"] = goal_key
        entry["routePendingStartCell"] = start_cell
        entry["routePendingRetryFrame"] = Engine.get_physics_frames() + pending_route_retry_frames(entry, intent, String(route.get("reason", "route_pending")))
        var critical_pending_route := bool(intent.get("movingHome", false)) or String(intent.get("kind", "")) in ["home", "scripted"]
        var cached_fallback_cell: Vector2i = entry.get("routeFallbackCell", target_cell)
        var cached_partial_for_target := cached_fallback_cell != target_cell
        var can_keep_active_route_while_pending := not current_waypoints.is_empty() \
            and not cached_lease.is_empty() \
            and not goal_key_changed \
            and not active_route_drifted \
            and not changed_route_should_stop \
            and not (critical_pending_route and cached_partial_for_target)
        if can_keep_active_route_while_pending:
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
        entry["pathWaypoints"] = []
        entry["routeCells"] = []
        entry["routeActions"] = {}
        set_route_status(entry, "pending", String(route.get("reason", "route_pending")))
        return route
    if not snapshot_revision_changed and not route_key_changed and failed_replan_preserves_active_route(route, current_waypoints):
        entry["routeForceReplan"] = true
        var failed_reason := String(route.get("reason", "route_replan_failed"))
        set_route_status(entry, "moving", failed_reason)
        return {
            "ok": true,
            "status": "routed",
            "reason": failed_reason,
            "cells": entry.get("routeCells", []),
            "waypoints": current_waypoints,
            "actions": entry.get("routeActions", {}),
            "targetCell": target_cell,
            "fallbackCell": entry.get("routeFallbackCell", target_cell),
            "snapshotRevision": String(entry.get("routeSnapshotRevision", snapshot_revision))
        }
    entry["routeForceReplan"] = false
    entry.erase("routePendingRetryFrame")
    entry.erase("routePendingKey")
    entry.erase("routePendingSnapshotRevision")
    entry.erase("routePendingGoalKey")
    entry.erase("routePendingStartCell")
    entry["routeKey"] = route_key
    entry["routeGoalCell"] = target_cell
    entry["routeGoalKey"] = goal_key
    entry["routeStartCell"] = start_cell
    entry["routeLastKnownCell"] = start_cell
    entry["routeAllowOutside"] = bool(intent.get("allowOutside", false))
    entry["routeMovingHome"] = bool(intent.get("movingHome", false))
    entry["routeSnapshotRevision"] = snapshot_revision
    entry["routeCells"] = (route.get("cells", []) as Array).duplicate()
    entry["pathWaypoints"] = (route.get("waypoints", []) as Array).duplicate()
    entry["routeActions"] = (route.get("actions", {}) as Dictionary).duplicate()
    entry.erase("routeTrimmedPrefixCells")
    trim_installed_route_prefix_to_current_cell(entry, start_cell)
    if entry.has("routeTrimmedPrefixCells"):
        route["cells"] = (entry.get("routeCells", []) as Array).duplicate()
        route["waypoints"] = (entry.get("pathWaypoints", []) as Array).duplicate()
        route["actions"] = (entry.get("routeActions", {}) as Dictionary).duplicate()
        route["routeTrimmedPrefixCells"] = int(entry.get("routeTrimmedPrefixCells", 0))
    if route.get("routeLease", {}) is Dictionary and not (route.get("routeLease", {}) as Dictionary).is_empty():
        NpcRouteStateStoreScript.write_route_lease_from_route(entry, route, "NpcRouteMovementController.install_route")
    else:
        NpcRouteStateStoreScript.clear_route_lease(entry, "NpcRouteMovementController.install_route")
    entry["routeFallbackCell"] = route.get("fallbackCell", target_cell)
    if bool(route.get("ok", false)) and not (route.get("waypoints", []) as Array).is_empty():
        entry["routeRetryTicks"] = 0
        entry.erase("routeFailureRetryFrame")
    elif String(route.get("status", "")) != "arrived":
        entry["routeRetryTicks"] = 0
        if not bool(route.get("ok", false)):
            entry["routeFailureRetryFrame"] = Engine.get_physics_frames() + failed_route_retry_frames(entry, intent, String(route.get("reason", "")))
        else:
            entry.erase("routeFailureRetryFrame")
    if bool(route.get("ok", false)) and not (route.get("waypoints", []) as Array).is_empty():
        increment_route_replan(entry)
    record_blocked_endpoint_cell(entry, route)
    set_route_status(entry, String(route.get("status", "blocked")), String(route.get("reason", "")))
    if String(route.get("status", "")) == "partial":
        count_unreachable_once(entry, intent, String(route.get("reason", "partial_route")))
    return route

func pending_route_retry_frames(entry: Dictionary, intent: Dictionary, reason: String) -> int:
    if String(entry.get("activeDoorPortalId", "")) != "":
        return PENDING_ROUTE_RETRY_ACTIVE_PORTAL_FRAMES
    if bool(intent.get("movingHome", false)) or String(intent.get("kind", "")) == "scripted":
        return PENDING_ROUTE_RETRY_DOOR_FRAMES
    if int(entry.get("routePriority", int(intent.get("priority", 0)))) < 90:
        return PENDING_ROUTE_RETRY_LOW_PRIORITY_FRAMES
    if reason in ["navmesh_tile_budget", "route_budget"]:
        return PENDING_ROUTE_RETRY_DEFAULT_FRAMES
    return PENDING_ROUTE_RETRY_DEFAULT_FRAMES

func failed_route_retry_frames(entry: Dictionary, intent: Dictionary, reason: String) -> int:
    if String(entry.get("activeDoorPortalId", "")) != "":
        return FAILED_ROUTE_RETRY_ACTIVE_PORTAL_FRAMES
    if int(entry.get("routePriority", int(intent.get("priority", 0)))) < 90:
        return FAILED_ROUTE_RETRY_LOW_PRIORITY_FRAMES
    if reason in ["endpoint_not_server_walkable", "no_start_server_walkable", "no_target_server_walkable", "path_endpoint_mismatch", "no_route"]:
        return FAILED_ROUTE_RETRY_DEFAULT_FRAMES
    return FAILED_ROUTE_RETRY_DEFAULT_FRAMES

func failed_replan_preserves_active_route(route: Dictionary, current_waypoints: Array) -> bool:
    if current_waypoints.is_empty() or bool(route.get("ok", false)):
        return false
    var reason := String(route.get("reason", ""))
    return reason in ["endpoint_not_server_walkable", "no_start_server_walkable", "path_endpoint_mismatch"]

func compact_route_plan_debug(route: Dictionary) -> Dictionary:
    var navmesh_route: Dictionary = route.get("navmeshRoute", {}) if route.get("navmeshRoute", {}) is Dictionary else {}
    var navmesh_details: Dictionary = navmesh_route.get("details", {}) if navmesh_route.get("details", {}) is Dictionary else {}
    var actions: Dictionary = route.get("actions", {}) if route.get("actions", {}) is Dictionary else {}
    var generated_bridge_value = route.get("generatedCellBridge", false)
    var generated_bridge_used := false
    if generated_bridge_value is bool:
        generated_bridge_used = generated_bridge_value
    elif generated_bridge_value is Dictionary:
        generated_bridge_used = bool(generated_bridge_value.get("ok", false))
    var path_value = navmesh_route.get("path", [])
    var path_count := 0
    if path_value is PackedVector3Array or path_value is Array:
        path_count = path_value.size()
    return {
        "ok": bool(route.get("ok", false)),
        "source": String(route.get("source", "")),
        "navmeshFallbackReason": String(route.get("navmeshFallbackReason", "")),
		"status": String(route.get("status", "")),
		"reason": String(route.get("reason", "")),
        "intentKind": String(route.get("intentKind", "")),
		"intentPriority": int(route.get("intentPriority", 0)),
		"routeAuthorityState": String(route.get("routeAuthorityState", "")),
		"routeAuthorityReason": String(route.get("routeAuthorityReason", "")),
		"routeAuthorityReady": bool(route.get("routeAuthorityReady", false)),
		"routeLeaseId": String(route.get("routeLeaseId", "")),
		"probeCertificate": route.get("probeCertificate", {}),
		"probeRepair": route.get("probeRepair", navmesh_route.get("probeRepair", {})),
		"routeBudgetWaitFrames": int(route.get("routeBudgetWaitFrames", 0)),
		"targetCell": _compact_vector2i_debug(route.get("targetCell", Vector2i(999999, 999999))),
		"fallbackCell": _compact_vector2i_debug(route.get("fallbackCell", Vector2i(999999, 999999))),
		"cells": (route.get("cells", []) as Array).size(),
        "waypoints": (route.get("waypoints", []) as Array).size(),
        "actions": actions.size(),
        "doorLinks": navmesh_route.get("doorLinks", []),
        "pathPoints": path_count,
        "pathSample": _compact_path_debug(path_value, 6),
        "start": _compact_vector3_debug(navmesh_route.get("start", Vector3.ZERO)),
        "target": _compact_vector3_debug(navmesh_route.get("target", Vector3.ZERO)),
        "startPosition": _compact_vector3_debug(navmesh_route.get("startPosition", Vector3.ZERO)),
        "targetPosition": _compact_vector3_debug(navmesh_route.get("targetPosition", Vector3.ZERO)),
        "startWalkable": _compact_walkable_debug(navmesh_route.get("startWalkable", navmesh_details.get("startWalkable", {}))),
        "targetWalkable": _compact_walkable_debug(navmesh_route.get("targetWalkable", navmesh_details.get("targetWalkable", {}))),
        "descriptorStartWalkable": _compact_walkable_debug(navmesh_details.get("descriptorStartWalkable", {})),
        "descriptorTargetWalkable": _compact_walkable_debug(navmesh_details.get("descriptorTargetWalkable", {})),
        "endpoint": _compact_endpoint_debug(navmesh_details.get("endpoint", {})),
        "endpointRetry": _compact_endpoint_debug(navmesh_details.get("endpointRetry", {})),
        "pathPointCount": int(navmesh_details.get("pathPointCount", -1)),
        "validation": _compact_validation_debug(navmesh_route.get("validation", {})),
        "generatedCellBridgeUsed": generated_bridge_used,
        "generatedCellBridge": _compact_generated_cell_bridge_debug(navmesh_route.get("generatedCellBridge", route.get("generatedCellBridge", {}))),
        "exactCollisionLatticeRoute": _compact_exact_collision_lattice_debug(route.get("exactCollisionLatticeRoute", navmesh_route.get("exactCollisionLatticeRoute", {}))),
        "fallbackAttempts": navmesh_route.get("fallbackAttempts", route.get("fallbackAttempts", [])),
        "generatedFallback": compact_generated_fallback_debug(route.get("generatedFallbackRoute", {})),
        "typed": compact_typed_route_debug(route.get("typedResult")),
        "durationUsec": int(navmesh_route.get("durationUsec", 0))
    }

func _compact_validation_debug(validation_value) -> Dictionary:
    if not (validation_value is Dictionary):
        return {}
    var validation: Dictionary = validation_value
    return {
        "ok": bool(validation.get("ok", false)),
        "reason": String(validation.get("reason", "")),
        "transitionReason": String(validation.get("transitionReason", "")),
        "fromCell": _compact_vector2i_debug(validation.get("fromCell", Vector2i(999999, 999999))),
        "toCell": _compact_vector2i_debug(validation.get("toCell", Vector2i(999999, 999999))),
        "blockerCell": _compact_vector2i_debug(validation.get("blockerCell", Vector2i(999999, 999999))),
        "blockType": String(validation.get("blockType", "")),
        "segmentIndex": int(validation.get("segmentIndex", -1))
    }

func _compact_generated_cell_bridge_debug(bridge_value) -> Dictionary:
    if not (bridge_value is Dictionary):
        return {}
    var bridge: Dictionary = bridge_value
    return {
        "ok": bool(bridge.get("ok", false)),
        "reason": String(bridge.get("reason", "")),
        "goals": int(bridge.get("goals", 0)),
        "visited": int(bridge.get("visited", 0)),
        "blockedReasons": (bridge.get("blockedReasons", {}) as Dictionary).duplicate() if bridge.get("blockedReasons", {}) is Dictionary else {}
    }

func _compact_exact_collision_lattice_debug(lattice_value) -> Dictionary:
    if not (lattice_value is Dictionary):
        return {}
    var lattice: Dictionary = lattice_value
    var cells: Array = lattice.get("cells", []) if lattice.get("cells", []) is Array else []
    var cell_sample := []
    for index in range(mini(cells.size(), 12)):
        cell_sample.append(_compact_vector2i_debug(cells[index]))
    return {
        "ok": bool(lattice.get("ok", false)),
        "reason": String(lattice.get("reason", "")),
        "visited": int(lattice.get("visited", 0)),
        "cells": cells.size(),
        "cellSample": cell_sample,
        "blockedReasons": (lattice.get("blockedReasons", {}) as Dictionary).duplicate() if lattice.get("blockedReasons", {}) is Dictionary else {},
        "exactTarget": bool(lattice.get("exactTarget", false)),
        "validation": _compact_validation_debug(lattice.get("validation", {}))
    }

func _compact_endpoint_debug(endpoint_value) -> Dictionary:
    if not (endpoint_value is Dictionary):
        return {}
    var endpoint: Dictionary = endpoint_value
    return {
        "ok": bool(endpoint.get("ok", false)),
        "reason": String(endpoint.get("reason", "")),
        "flatDistance": snappedf(float(endpoint.get("flatDistance", -1.0)), 0.001),
        "flatLimit": snappedf(float(endpoint.get("flatLimit", -1.0)), 0.001),
        "verticalDistance": snappedf(float(endpoint.get("verticalDistance", -1.0)), 0.001),
        "verticalLimit": snappedf(float(endpoint.get("verticalLimit", -1.0)), 0.001),
        "endpoint": _compact_vector3_debug(endpoint.get("endpoint", Vector3.ZERO)),
        "target": _compact_vector3_debug(endpoint.get("target", Vector3.ZERO))
    }

func compact_generated_fallback_debug(fallback_value) -> Dictionary:
    if not (fallback_value is Dictionary):
        return {}
    var fallback: Dictionary = fallback_value
    var typed_result = fallback.get("typedResult")
    var typed_summary := compact_typed_route_debug(typed_result)
    return {
        "ok": bool(fallback.get("ok", false)),
        "status": String(fallback.get("status", "")),
        "reason": String(fallback.get("reason", "")),
        "source": String(fallback.get("source", "")),
        "cells": (fallback.get("cells", []) as Array).size(),
        "waypoints": (fallback.get("waypoints", []) as Array).size(),
        "typed": typed_summary
    }

func compact_typed_route_debug(typed_result) -> Dictionary:
    if typed_result == null:
        return {}
    var metrics_value = typed_result.get("metrics")
    var metrics: Dictionary = metrics_value if metrics_value is Dictionary else {}
    var graph: Dictionary = metrics.get("graph", {}) if metrics.get("graph", {}) is Dictionary else {}
    var hierarchy: Dictionary = metrics.get("hierarchy", {}) if metrics.get("hierarchy", {}) is Dictionary else {}
    var search: Dictionary = metrics.get("search", {}) if metrics.get("search", {}) is Dictionary else {}
    var goals: Array = graph.get("goalKeys", []) if graph.get("goalKeys", []) is Array else []
    return {
        "status": str(typed_result.get("status")),
        "reason": str(typed_result.get("reason")),
        "graphNodes": int(graph.get("nodeCount", -1)),
        "graphEdges": int(graph.get("edgeCount", -1)),
        "startKey": String(graph.get("startKey", "")),
        "startEdges": int(graph.get("startEdgeCount", -1)),
        "goalCount": goals.size(),
        "goalSample": goals.slice(0, mini(goals.size(), 6)),
        "runtimeDebug": (graph.get("runtimeDebug", {}) as Dictionary).duplicate(true) if graph.get("runtimeDebug", {}) is Dictionary else {},
        "allowedTiles": int(graph.get("allowedTileCount", -1)),
        "hierarchyTiles": int(hierarchy.get("tileCount", -1)),
        "hierarchyEntrances": int(hierarchy.get("entranceCount", -1)),
        "abstractReason": String(metrics.get("abstractReason", "")),
        "fallback": String(metrics.get("fallback", "")),
        "searchBestKey": String(search.get("bestKey", "")),
        "searchBestGoalDistance": snappedf(float(search.get("bestGoalDistance", -1.0)), 0.001),
        "searchClosedCount": int(search.get("closedCount", -1))
    }

func _compact_path_debug(path_value, limit := 6) -> Array:
    var result := []
    var count := 0
    if path_value is PackedVector3Array:
        for point in path_value:
            if count >= limit:
                break
            result.append(_compact_vector3_debug(point))
            count += 1
    elif path_value is Array:
        for point in path_value:
            if count >= limit:
                break
            if point is Vector3:
                result.append(_compact_vector3_debug(point))
                count += 1
    return result

func _compact_vector3_debug(value) -> Array:
    if not (value is Vector3):
        return []
    var point: Vector3 = value
    return [snappedf(point.x, 0.001), snappedf(point.y, 0.001), snappedf(point.z, 0.001)]

func _compact_walkable_debug(value) -> Dictionary:
    if not (value is Dictionary):
        return {}
    var walkable: Dictionary = value
    return {
        "found": bool(walkable.get("found", false)),
        "reason": String(walkable.get("reason", "")),
        "regionId": String(walkable.get("regionId", "")),
        "surfaceId": String(walkable.get("surfaceId", "")),
        "source": String(walkable.get("source", "")),
        "serverFallbackReason": String(walkable.get("serverFallbackReason", "")),
        "position": _compact_vector3_debug(walkable.get("position", Vector3.ZERO)),
        "distance": snappedf(float(walkable.get("distance", -1.0)), 0.001)
    }

func clear_route(entry: Dictionary) -> void:
    if system != null and system.has_method("release_npc_traffic_reservations"):
        system.release_npc_traffic_reservations(entry, "route_completed")
    entry["pathWaypoints"] = []
    entry["routeCells"] = []
    entry["routeActions"] = {}
    entry["routeForceReplan"] = false
    entry.erase("routeDynamicAvoidCells")
    entry.erase("routeDynamicAvoidUntilFrame")
    entry.erase("_activeDoorForwardStep")
    entry.erase("portalRecenterTicks")
    entry.erase("homeDoorClearanceRecoveryActive")

func invalidate_active_route_for_replan(entry: Dictionary, reason: String) -> void:
    if system != null and system.has_method("release_npc_traffic_reservations"):
        system.release_npc_traffic_reservations(entry, reason)
    entry["pathWaypoints"] = []
    entry["routeCells"] = []
    entry["routeActions"] = {}
    entry["routeForceReplan"] = true
    entry.erase("routePendingRetryFrame")
    entry.erase("routeFailureRetryFrame")
    entry.erase("homeDoorClearanceRecoveryActive")

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
            # Keep the active portal corridor stable; replanning can reinsert approach cells behind the crossing.
            entry["routeForceReplan"] = false
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
    if active_door_hold_must_continue(entry):
        entry["lastActiveDoorReleaseSuppressed"] = {
            "reason": "actor_still_in_portal",
            "portalId": String(entry.get("activeDoorPortalId", "")),
            "frame": Engine.get_physics_frames()
        }
        entry["pathWaypoints"] = []
        entry["routeCells"] = []
        entry["routeActions"] = {}
        entry["routeForceReplan"] = false
        entry.erase("portalRecenterTicks")
        return
    var actor_id := String(entry.get("activeDoorActorId", entry.get("id", "")))
    if system != null and system.has_method("release_npc_door_hold") and actor_id != "":
        var release_evidence := {}
        if system.has_method("active_private_home_departure_clearance_evidence"):
            release_evidence = system.call("active_private_home_departure_clearance_evidence", entry, String(entry.get("activeDoorPortalId", ""))) as Dictionary
        system.call("release_npc_door_hold", actor_id, true, release_evidence)
    if system != null and system.has_method("release_npc_traffic_reservations"):
        system.release_npc_traffic_reservations(entry, "active_door_route_replan")
    entry.erase("activeDoorPortalId")
    entry.erase("activeDoorActorId")
    entry.erase("activeDoorDirection")
    entry.erase("activeDoorTrafficGroupId")
    entry["routeActions"] = {}
    entry["routeForceReplan"] = true
    entry.erase("_activeDoorForwardStep")
    entry.erase("portalRecenterTicks")

func active_door_hold_must_continue(entry: Dictionary) -> bool:
    var portal_id := String(entry.get("activeDoorPortalId", ""))
    if portal_id == "":
        return false
    if system != null and system.has_method("route_still_needs_active_door"):
        return bool(system.call("route_still_needs_active_door", entry, portal_id))
    return false

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

func active_door_needs_forward_clearance_step(entry: Dictionary, world) -> bool:
    if String(entry.get("activeDoorPortalId", "")) == "":
        return false
    var direction := String(entry.get("activeDoorDirection", ""))
    if direction == "" or world == null:
        return false
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return false
    var current_cell: Vector2i = world.world_cell(body.global_position)
    var cells: Array = entry.get("routeCells", [])
    if cells.is_empty() or not (cells[0] is Vector2i):
        return true
    var next_cell: Vector2i = cells[0]
    var reference_cell := current_cell
    var door_cell := active_door_portal_cell(entry, world)
    if door_cell != Vector2i(999999, 999999):
        reference_cell = door_cell
    if direction == "x+":
        return next_cell.x <= reference_cell.x
    if direction == "x-":
        return next_cell.x >= reference_cell.x
    if direction == "z+":
        return next_cell.y <= reference_cell.y
    if direction == "z-":
        return next_cell.y >= reference_cell.y
    return false

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
    var reached_count := 0
    while not cells.is_empty() and cells[0] == current_cell:
        reached_count += 1
        cells.remove_at(0)
    if reached_count > 0:
        trim_route_prefix(entry, reached_count, true)

func trim_route_prefix(entry: Dictionary, count: int, cells_already_trimmed := false) -> void:
    if count <= 0:
        return
    var cells: Array = entry.get("routeCells", []) if entry.get("routeCells", []) is Array else []
    var waypoints: Array = entry.get("pathWaypoints", []) if entry.get("pathWaypoints", []) is Array else []
    var removed_cells: Array = []
    if cells_already_trimmed:
        var original_cells: Array = entry.get("routeCells", []) if entry.get("routeCells", []) is Array else []
        var remove_count := mini(count, original_cells.size())
        for index in range(remove_count):
            var cell_value = original_cells[index]
            if cell_value is Vector2i:
                removed_cells.append(cell_value)
        cells = original_cells.slice(remove_count)
    else:
        for _index in range(count):
            if cells.is_empty():
                break
            var cell_value = cells.pop_front()
            if cell_value is Vector2i:
                removed_cells.append(cell_value)
    for _index in range(count):
        if waypoints.is_empty():
            break
        waypoints.remove_at(0)
    var actions: Dictionary = entry.get("routeActions", {}) if entry.get("routeActions", {}) is Dictionary else {}
    for cell_value in removed_cells:
        if cell_value is Vector2i:
            var cell: Vector2i = cell_value
            actions.erase("%d,%d" % [cell.x, cell.y])
    entry["routeCells"] = cells
    entry["pathWaypoints"] = waypoints
    entry["routeActions"] = actions

func trim_installed_route_prefix_to_current_cell(entry: Dictionary, current_cell: Vector2i) -> void:
    var cells: Array = entry.get("routeCells", []) if entry.get("routeCells", []) is Array else []
    var waypoints: Array = entry.get("pathWaypoints", []) if entry.get("pathWaypoints", []) is Array else []
    var trim_count := 0
    for index in range(cells.size()):
        var cell_value = cells[index]
        if cell_value is Vector2i and cell_value == current_cell:
            trim_count = index + 1
            break
    if trim_count <= 0:
        return
    var removed_cells: Array = cells.slice(0, trim_count)
    for _index in range(trim_count):
        if not cells.is_empty():
            cells.remove_at(0)
        if not waypoints.is_empty():
            waypoints.remove_at(0)
    var actions: Dictionary = entry.get("routeActions", {}) if entry.get("routeActions", {}) is Dictionary else {}
    for removed_cell_value in removed_cells:
        if removed_cell_value is Vector2i:
            var removed_cell: Vector2i = removed_cell_value
            actions.erase("%d,%d" % [removed_cell.x, removed_cell.y])
    entry["routeCells"] = cells
    entry["pathWaypoints"] = waypoints
    entry["routeActions"] = actions
    entry["routeTrimmedPrefixCells"] = trim_count

func skip_optional_home_approach_if_oscillating(entry: Dictionary) -> bool:
    return false

func try_home_door_clearance_recovery(entry: Dictionary, previous: Vector3, intent: Dictionary, _max_distance: float, world, _priority: int, reason: String) -> Dictionary:
    if not home_door_clearance_recovery_allowed(entry, previous, intent, reason, world):
        return {}
    var clearance_route := plan_home_door_clearance_route(entry, previous, world)
    if clearance_route.is_empty():
        return {}
    entry["routeCells"] = (clearance_route.get("cells", []) as Array).duplicate()
    entry["pathWaypoints"] = (clearance_route.get("waypoints", []) as Array).duplicate()
    entry["routeActions"] = {}
    entry["routeFallbackCell"] = clearance_route.get("fallbackCell", entry.get("homeCell", Vector2i.ZERO))
    entry["routeForceReplan"] = false
    entry["homeDoorClearanceRecovery"] = {
        "reason": reason,
        "fromCell": clearance_route.get("fromCell", Vector2i.ZERO),
        "targetCell": clearance_route.get("fallbackCell", Vector2i.ZERO),
        "cellCount": (clearance_route.get("cells", []) as Array).size()
    }
    set_route_status(entry, "waiting", "home_door_clearance_recovery")
    return { "moved": 0.0, "status": "waiting", "reason": "home_door_clearance_recovery", "classification": "home_route" }

func home_door_clearance_recovery_allowed(entry: Dictionary, previous: Vector3, intent: Dictionary, reason: String, world) -> bool:
    if world == null:
        return false
    if not (bool(intent.get("movingHome", false)) or bool(entry.get("routeMovingHome", false)) or String(entry.get("activeGoalKind", "")) == "home"):
        return false
    if reason not in [
        "path_crosses_static_collision",
        "blocked_static_collision",
        "blocked_static_transition",
        "static_or_dynamic_collision",
        "blocked_capsule",
        "blocked_capsule_probe",
        "empty_route",
        "active_door_replan"
    ]:
        return false
    var portal = home_portal_for_entry(entry)
    var status := HomeInteriorServiceScript.status(entry, previous, portal)
    if bool(status.get("strictInside", false)):
        return false
    if not bool(status.get("insideBounds", false)):
        return false
    if not bool(status.get("pastDoorPlane", false)):
        return false
    return String(status.get("reason", "")) == "door_clearance_not_inside" or not bool(status.get("clearOfDoor", true))

func plan_home_door_clearance_route(entry: Dictionary, previous: Vector3, world) -> Dictionary:
    if world == null or not world.has_method("world_cell") or not world.has_method("cell_position"):
        return {}
    var current_cell: Vector2i = world.world_cell(previous)
    var portal = home_portal_for_entry(entry)
    var snapshot: Dictionary = {}
    if world.has_method("cached_validation_snapshot"):
        snapshot = world.cached_validation_snapshot(entry, false, true)
    elif world.has_method("build_snapshot"):
        snapshot = world.build_snapshot(entry, false, true)
    var queue: Array[Vector2i] = [current_cell]
    var visited := { home_clearance_cell_key(current_cell): true }
    var came_from := {}
    var target_cell := Vector2i(999999, 999999)
    var max_visits := 32
    var visits := 0
    while not queue.is_empty() and visits < max_visits:
        var cell: Vector2i = queue.pop_front()
        visits += 1
        if cell != current_cell and home_clearance_cell_is_strict_inside(entry, cell, world, portal):
            target_cell = cell
            break
        for next_cell in home_clearance_neighbors_toward_home(cell, entry):
            var key := home_clearance_cell_key(next_cell)
            if visited.has(key):
                continue
            if not home_clearance_cell_candidate(entry, next_cell, world, portal):
                continue
            if not home_clearance_transition_clear(entry, cell, next_cell, snapshot, world):
                continue
            visited[key] = true
            came_from[key] = cell
            queue.append(next_cell)
    if target_cell == Vector2i(999999, 999999):
        return {}
    var cells: Array[Vector2i] = []
    var cursor := target_cell
    while cursor != current_cell:
        cells.push_front(cursor)
        var cursor_key := home_clearance_cell_key(cursor)
        if not came_from.has(cursor_key):
            return {}
        cursor = came_from[cursor_key]
    var waypoints: Array[Vector3] = []
    for cell in cells:
        waypoints.append(world.cell_position(cell))
    return {
        "cells": cells,
        "waypoints": waypoints,
        "fallbackCell": target_cell,
        "fromCell": current_cell
    }

func home_clearance_cell_candidate(entry: Dictionary, cell: Vector2i, world, _portal) -> bool:
    if not HomeInteriorServiceScript.cell_inside_home_bounds(entry, cell, true):
        return false
    if world != null and world.has_method("cell_is_standable_goal") and not bool(world.cell_is_standable_goal(entry, cell, false, true)):
        return false
    return true

func home_clearance_cell_is_strict_inside(entry: Dictionary, cell: Vector2i, world, portal) -> bool:
    if not home_clearance_cell_candidate(entry, cell, world, portal):
        return false
    var position: Vector3 = world.cell_position(cell)
    var status := HomeInteriorServiceScript.status(entry, position, portal)
    return bool(status.get("strictInside", false))

func home_clearance_transition_clear(entry: Dictionary, from_cell: Vector2i, to_cell: Vector2i, snapshot: Dictionary, world) -> bool:
    if world == null or not world.has_method("cell_transition_pathable"):
        return true
    var target_lookup := { to_cell: true, "_strictTargetCollision": true }
    var transition: Dictionary = world.cell_transition_pathable(entry, snapshot, from_cell, to_cell, target_lookup, true)
    return bool(transition.get("ok", false))

func home_clearance_neighbors_toward_home(cell: Vector2i, entry: Dictionary) -> Array[Vector2i]:
    var home_cell: Vector2i = entry.get("homeCell", cell)
    var neighbors: Array[Vector2i] = [
        cell + Vector2i(1, 0),
        cell + Vector2i(-1, 0),
        cell + Vector2i(0, 1),
        cell + Vector2i(0, -1)
    ]
    neighbors.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
        var da := absi(a.x - home_cell.x) + absi(a.y - home_cell.y)
        var db := absi(b.x - home_cell.x) + absi(b.y - home_cell.y)
        if da != db:
            return da < db
        if a.x != b.x:
            return a.x < b.x
        return a.y < b.y
    )
    return neighbors

func home_clearance_cell_key(cell: Vector2i) -> String:
    return "%d,%d" % [cell.x, cell.y]

func home_portal_for_entry(entry: Dictionary):
    if system == null:
        return null
    var autonomy = system.get("autonomy_system")
    if autonomy == null:
        return null
    var door_portals = autonomy.get("door_portals")
    if door_portals == null:
        return null
    return HomeInteriorServiceScript.portal_for_entry(entry, door_portals)

func skip_optional_home_waypoint_if_static_blocked(entry: Dictionary, reason: String) -> bool:
    if reason not in ["path_crosses_static_collision", "blocked_static_collision", "blocked_static_transition", "static_or_dynamic_collision"]:
        return false
    return skip_optional_home_waypoint_to_interior(entry, "static_blocked")

func skip_optional_home_waypoint_if_endpoint_unsnappable(entry: Dictionary, reason: String) -> bool:
    if reason not in ["endpoint_not_server_walkable", "no_target_server_walkable", "path_endpoint_mismatch", "target_blocked"]:
        return false
    return skip_optional_home_waypoint_to_interior(entry, "endpoint_unsnappable")

func skip_optional_home_waypoint_to_interior(entry: Dictionary, reason: String) -> bool:
    if String(entry.get("activeGoalKind", "")) != "home" and not bool(entry.get("routeMovingHome", false)):
        return false
    var body := entry.get("body") as Node3D
    if body != null and is_instance_valid(body):
        var porch: Vector3 = entry.get("porchPosition", body.global_position)
        var porch_cell: Vector2i = entry.get("porchCell", Vector2i(roundi(porch.x / CELL), roundi(porch.z / CELL)))
        var current_cell := Vector2i(roundi(body.global_position.x / CELL), roundi(body.global_position.z / CELL))
        if current_cell != porch_cell and body.global_position.distance_to(porch) > CELL * 2.0:
            return false
    var route_positions: Array = entry.get("homeRoutePositions", []) if entry.get("homeRoutePositions", []) is Array else []
    if route_positions.size() < 2:
        return false
    var route_index := clampi(int(entry.get("homeRouteIndex", 0)), 0, route_positions.size() - 1)
    var home_cell: Vector2i = entry.get("homeCell", Vector2i.ZERO)
    var next_index := next_home_route_interior_index(entry, route_positions, route_index, home_cell)
    if next_index < 0:
        return false
    var next_position = route_positions[next_index]
    if not (next_position is Vector3):
        return false
    entry["homeRouteIndex"] = next_index
    entry["homeActiveTargetCell"] = Vector2i(roundi((next_position as Vector3).x / CELL), roundi((next_position as Vector3).z / CELL))
    entry["homeOptionalWaypointSkip"] = {
        "reason": reason,
        "fromIndex": route_index,
        "toIndex": next_index
    }
    clear_route(entry)
    entry["routeForceReplan"] = true
    return true

func next_home_route_interior_index(entry: Dictionary, route_positions: Array, route_index: int, home_cell: Vector2i) -> int:
    if route_index < 0 or route_index >= route_positions.size() - 1:
        return -1
    for index in range(route_index + 1, route_positions.size()):
        var next_position_value = route_positions[index]
        if not (next_position_value is Vector3):
            continue
        var next_position: Vector3 = next_position_value
        var next_cell := Vector2i(roundi(next_position.x / CELL), roundi(next_position.z / CELL))
        if HomeInteriorServiceScript.cell_inside_home_bounds(entry, next_cell, true):
            return index
    return -1

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
    if not door_action_request_is_local(entry, action, door, body, world, next_cell, "direct"):
        return ""
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
        if not door_action_request_is_local(entry, action, door, body, world, next_cell, "lookahead"):
            continue
        var traversal: Dictionary = system.request_npc_door_traversal(door, body, entry, action)
        if bool(traversal.get("ok", false)):
            clear_door_stage(entry)
            return ""
        if traversal.has("stagePosition"):
            var stage_position: Vector3 = traversal.get("stagePosition", body.global_position)
            if apply_door_stage(entry, body, stage_position, world, String(traversal.get("portalId", ""))):
                return ""
            if String(traversal.get("reason", "")) == "door_stage_required":
                continue
        return String(traversal.get("reason", "door_waiting"))
    return ""

func apply_door_stage(entry: Dictionary, body: Node3D, stage_position: Vector3, world, portal_id: String) -> bool:
    if body == null or world == null:
        return false
    if door_stage_position_occupied(entry, body, stage_position):
        return false
    if flat_distance(body.global_position, stage_position) <= CELL * 0.24:
        return false
    var current_cell: Vector2i = world.world_cell(body.global_position) if world.has_method("world_cell") else body_route_cell(body, world)
    var stage_cell: Vector2i = world.world_cell(stage_position) if world.has_method("world_cell") else Vector2i(roundi(stage_position.x / CELL), roundi(stage_position.z / CELL))
    if not door_stage_transition_is_clear(entry, current_cell, stage_cell, stage_cell, world):
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
        "remainingDistance": float(follow.get("remainingDistance", 0.0)),
        "blocker": _compact_blocker_debug(follow.get("blocker", {}))
    }

func _compact_blocker_debug(value) -> Dictionary:
    if not (value is Dictionary):
        return {}
    var blocker: Dictionary = value
    return {
        "name": String(blocker.get("name", "")),
        "kind": String(blocker.get("kind", "")),
        "blockType": String(blocker.get("blockType", "")),
        "class": String(blocker.get("class", "")),
        "position": _compact_vector3_debug(blocker.get("position", Vector3.ZERO)),
        "cell": _compact_vector2i_debug(blocker.get("cell", Vector2i.ZERO)),
        "sample": _compact_vector3_debug(blocker.get("sample", Vector3.ZERO)),
        "sampleCell": _compact_vector2i_debug(blocker.get("sampleCell", Vector2i.ZERO)),
        "candidate": _compact_vector3_debug(blocker.get("candidate", Vector3.ZERO)),
        "candidateCell": _compact_vector2i_debug(blocker.get("candidateCell", Vector2i.ZERO))
    }

func _compact_vector2i_debug(value) -> Array:
    if not (value is Vector2i):
        return []
    var cell: Vector2i = value
    return [cell.x, cell.y]

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

func claim_frame_occupancy(entry: Dictionary, previous: Vector3, actual_position: Vector3, world) -> void:
    if world == null or not world.has_method("world_cell"):
        return
    var actor_id := claim_actor_id(entry)
    if actor_id == "":
        return
    var body := entry.get("body") as Node3D
    _claim_frame_cell(world.world_cell(previous), actor_id, body)
    _claim_frame_cell(world.world_cell(actual_position), actor_id, body)

func _claim_frame_cell(cell: Vector2i, actor_id: String, body: Node3D) -> void:
    if actor_id == "":
        return
    var existing = frame_claimed_cells.get(cell, null)
    if existing is Dictionary:
        var existing_id := String((existing as Dictionary).get("ownerId", ""))
        if existing_id != "" and existing_id != actor_id:
            return
    frame_claimed_cells[cell] = {
        "ownerId": actor_id,
        "body": body
    }

func frame_cell_claim_conflict(entry: Dictionary, previous_cell: Vector2i, candidate_cell: Vector2i, previous: Vector3, candidate: Vector3, priority: int) -> Dictionary:
    var claim = frame_claimed_cells.get(candidate_cell, null)
    if not (claim is Dictionary):
        return {}
    var actor_id := claim_actor_id(entry)
    var claimed_id := String((claim as Dictionary).get("ownerId", ""))
    if claimed_id == "" or claimed_id == actor_id:
        return {}
    var blocker := (claim as Dictionary).get("body") as Node3D
    if previous_cell == candidate_cell and blocker != null and is_instance_valid(blocker) and dynamic_candidate_moves_away(previous, candidate, blocker):
        return {}
    return {
        "ok": false,
        "reason": "cell_reserved",
        "blocker": blocker,
        "ownerId": claimed_id,
        "cell": candidate_cell
    }

func center_dynamic_conflict(entry: Dictionary, snapshot: Dictionary, previous_cell: Vector2i, candidate_cell: Vector2i, previous: Vector3, candidate: Vector3, world, priority: int) -> Dictionary:
    if world == null or not world.has_method("dynamic_blocker"):
        return {}
    var dynamic = world.dynamic_blocker(snapshot, candidate_cell)
    if dynamic == null:
        return {}
    if previous_cell == candidate_cell and dynamic_candidate_moves_away(previous, candidate, dynamic):
        return {}
    if entry_loses_to_dynamic(entry, dynamic, priority):
        return { "ok": false, "reason": "yielding", "blocker": dynamic }
    return { "ok": false, "reason": "blocked_dynamic", "blocker": dynamic }

func claim_actor_id(entry: Dictionary) -> String:
    var actor_id := String(entry.get("id", ""))
    if actor_id != "":
        return actor_id
    var body := entry.get("body") as Node
    if body != null:
        if body.has_meta("npc_stable_id"):
            return String(body.get_meta("npc_stable_id"))
        if body.name != "":
            return String(body.name)
    return ""

func validate_candidate(entry: Dictionary, previous: Vector3, candidate: Vector3, moving_home := false, allow_outside := false, world = null, priority := 0) -> Dictionary:
    if world == null or main == null:
        return { "ok": false, "reason": "missing_world" }
    var monitor = performance_monitor()
    var section_start: int = monitor.begin_section("npc_validate_point_allowed") if monitor != null else Time.get_ticks_usec()
    if not world.point_allowed(entry, candidate, allow_outside, moving_home):
        if monitor != null:
            monitor.end_section("npc_validate_point_allowed", section_start)
        return { "ok": false, "reason": "outside_area" }
    if monitor != null:
        monitor.end_section("npc_validate_point_allowed", section_start)
    var previous_cell: Vector2i = world.world_cell(previous)
    var candidate_cell: Vector2i = world.world_cell(candidate)
    section_start = monitor.begin_section("npc_validate_terrain_step") if monitor != null else Time.get_ticks_usec()
    var terrain: Dictionary = world.terrain_allows_step(previous_cell, candidate_cell, moving_home)
    if not bool(terrain.get("ok", false)):
        if monitor != null:
            monitor.end_section("npc_validate_terrain_step", section_start)
        return terrain
    if monitor != null:
        monitor.end_section("npc_validate_terrain_step", section_start)
    candidate.y = float(terrain.get("height", main.call("surface_y_at_position", candidate) if main.has_method("surface_y_at_position") else candidate.y)) + 0.04
    section_start = monitor.begin_section("npc_validate_snapshot") if monitor != null else Time.get_ticks_usec()
    var snapshot: Dictionary = world.cached_validation_snapshot(entry, allow_outside, moving_home) if world.has_method("cached_validation_snapshot") else world.build_snapshot(entry, allow_outside, moving_home)
    if monitor != null:
        monitor.end_section("npc_validate_snapshot", section_start)
    var claim_conflict := frame_cell_claim_conflict(entry, previous_cell, candidate_cell, previous, candidate, priority)
    if not claim_conflict.is_empty():
        return claim_conflict
    var center_conflict := center_dynamic_conflict(entry, snapshot, previous_cell, candidate_cell, previous, candidate, world, priority)
    if not center_conflict.is_empty():
        return center_conflict
    section_start = monitor.begin_section("npc_validate_center_sweep") if monitor != null else Time.get_ticks_usec()
    var center_sweep: Dictionary = center_sweep_blocker(snapshot, previous, candidate, world, previous_cell)
    if not bool(center_sweep.get("ok", false)):
        if monitor != null:
            monitor.end_section("npc_validate_center_sweep", section_start)
        return center_sweep
    if monitor != null:
        monitor.end_section("npc_validate_center_sweep", section_start)
    section_start = monitor.begin_section("npc_validate_footprint") if monitor != null else Time.get_ticks_usec()
    var previous_footprint: Array[Vector2i] = capsule_footprint_cells(previous, world)
    for footprint_cell in capsule_footprint_cells(candidate, world):
        var blocker = world.static_blocker(snapshot, footprint_cell)
        if blocker != null:
            if previous_footprint.has(footprint_cell):
                continue
            var door := blocker as Node
            if door == null or String(door.get_meta("block_type", "")) != "door":
                if monitor != null:
                    monitor.end_section("npc_validate_footprint", section_start)
                return { "ok": false, "reason": "blocked_static" }
        var dynamic = world.dynamic_blocker(snapshot, footprint_cell)
        if dynamic != null and previous_footprint.has(footprint_cell) and dynamic_candidate_moves_away(previous, candidate, dynamic):
            continue
        if dynamic != null:
            if entry_loses_to_dynamic(entry, dynamic, priority):
                if monitor != null:
                    monitor.end_section("npc_validate_footprint", section_start)
                return { "ok": false, "reason": "yielding", "blocker": dynamic }
            if monitor != null:
                monitor.end_section("npc_validate_footprint", section_start)
            return { "ok": false, "reason": "blocked_dynamic" }
    if monitor != null:
        monitor.end_section("npc_validate_footprint", section_start)
    var body := entry.get("body") as CharacterBody3D
    section_start = monitor.begin_section("npc_validate_capsule_sweep") if monitor != null else Time.get_ticks_usec()
    if body != null and not bool(entry.get("_activeDoorForwardStep", false)) and capsule_hits_obstacle(entry, body, previous, candidate):
        if monitor != null:
            monitor.end_section("npc_validate_capsule_sweep", section_start)
        return { "ok": false, "reason": "blocked_capsule", "blocker": entry.get("capsuleBlocker", {}) }
    if monitor != null:
        monitor.end_section("npc_validate_capsule_sweep", section_start)
    return { "ok": true, "candidate": candidate }

func dynamic_candidate_moves_away(previous: Vector3, candidate: Vector3, dynamic) -> bool:
    var other := dynamic as Node3D
    if other == null or not is_instance_valid(other):
        return false
    return flat_distance(candidate, other.global_position) + 0.02 >= flat_distance(previous, other.global_position)

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
    var radius := STATIC_FOOTPRINT_VALIDATION_RADIUS
    for offset in [
        Vector3.ZERO,
        Vector3(radius, 0.0, 0.0),
        Vector3(-radius, 0.0, 0.0),
        Vector3(0.0, 0.0, radius),
        Vector3(0.0, 0.0, -radius)
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
    if system == null or body == null:
        return false
    entry.erase("capsuleBlocker")
    body.set_meta("npc_capsule_blocker", {})
    var delta: Vector3 = candidate - previous
    if delta.length_squared() <= 0.000001:
        return false
    # This is a collision-only dry run through the exact CharacterBody3D shape.
    # It cannot diverge from the body's configured capsule, mask, or exceptions.
    var collision: KinematicCollision3D = body.move_and_collide(delta, true, 0.001, false, 8)
    if collision == null:
        return false
    var sample := previous + collision.get_travel()
    for index in range(collision.get_collision_count()):
        var collider := collision.get_collider(index) as Node
        if collider == null or collider == body:
            continue
        if collider_allows_overlap_escape(collider, previous, candidate):
            continue
        if collider_blocks_capsule(entry, collider, body):
            record_capsule_blocker(entry, body, collider, sample, candidate)
            return true
    return false

func record_capsule_blocker(entry: Dictionary, body: CharacterBody3D, collider: Node, sample: Vector3, candidate: Vector3) -> void:
    var collider_body := collider as Node3D
    var collider_position := collider_body.global_position if collider_body != null else Vector3.ZERO
    var blocker := {
        "name": collider.name,
        "kind": String(collider.get_meta("kind", "")),
        "blockType": String(collider.get_meta("block_type", "")),
        "class": collider.get_class(),
        "position": collider_position,
        "cell": Vector2i(roundi(collider_position.x / CELL), roundi(collider_position.z / CELL)),
        "sample": sample,
        "sampleCell": Vector2i(roundi(sample.x / CELL), roundi(sample.z / CELL)),
        "candidate": candidate,
        "candidateCell": Vector2i(roundi(candidate.x / CELL), roundi(candidate.z / CELL))
    }
    entry["capsuleBlocker"] = blocker
    body.set_meta("npc_capsule_blocker", blocker)

func collider_allows_overlap_escape(collider: Node, previous: Vector3, candidate: Vector3) -> bool:
    if collider == null:
        return false
    var collider_body := collider as Node3D
    if collider_body == null:
        return false
    var kind := String(collider.get_meta("kind", ""))
    if kind == "block":
        var block_type := String(collider.get_meta("block_type", ""))
        if block_type in ["door", "cobblestonePath", "torch"]:
            return false
        return flat_distance(candidate, collider_body.global_position) + 0.02 >= flat_distance(previous, collider_body.global_position)
    if kind != "prop":
        return false
    var previous_cell := Vector2i(roundi(previous.x / CELL), roundi(previous.z / CELL))
    var collider_cell := Vector2i(roundi(collider_body.global_position.x / CELL), roundi(collider_body.global_position.z / CELL))
    if collider_cell != previous_cell:
        return false
    var previous_distance := flat_distance(previous, collider_body.global_position)
    var candidate_distance := flat_distance(candidate, collider_body.global_position)
    return candidate_distance + 0.02 >= previous_distance

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
            var action := route_door_action(entry, door, body, null, "collision")
            if not action.is_empty():
                if system != null and system.has_method("request_npc_door_traversal"):
                    system.request_npc_door_traversal(door, body, entry, action)
                return true
            return true
        return true
    return kind in ["prop", "npc", "hostile"]

func route_has_door_action(entry: Dictionary, door: Node) -> bool:
    return not route_door_action(entry, door).is_empty()

func route_door_action(entry: Dictionary, door: Node, body: Node3D = null, world = null, source := "identity") -> Dictionary:
    door = interaction_door_for_collider(door)
    if door == null:
        return {}
    var door_portal_id := door_match_portal_id(door)
    var door_group_id := door_match_group_id(door)
    var actions: Dictionary = entry.get("routeActions", {})
    for action_value in actions.values():
        if not (action_value is Dictionary):
            continue
        var action: Dictionary = action_value
        if String(action.get("kind", "")) != "door":
            continue
        if route_action_matches_door(action, door, door_portal_id, door_group_id):
            if body != null and not door_action_request_is_local(entry, action, door, body, world, Vector2i(999999, 999999), source):
                continue
            return action
    return {}

func route_action_matches_door(action: Dictionary, door: Node, door_portal_id: String, door_group_id: String) -> bool:
    var action_door_value = action.get("door")
    var action_door := interaction_door_for_collider(action_door_value as Node) if action_door_value is Node else null
    if action_door == door:
        return true
    var action_portal_id := String(action.get("portalId", ""))
    if action_portal_id != "" and door_portal_id != "" and action_portal_id == door_portal_id:
        return true
    if action_door != null:
        var action_door_portal_id := door_match_portal_id(action_door)
        if action_door_portal_id != "" and door_portal_id != "" and action_door_portal_id == door_portal_id:
            return true
        var action_group_id := door_match_group_id(action_door)
        if action_group_id != "" and door_group_id != "" and action_group_id == door_group_id:
            return true
    return false

func door_action_request_is_local(entry: Dictionary, action: Dictionary, door: Node, body: Node3D, world, next_cell := Vector2i(999999, 999999), source := "direct") -> bool:
    if body == null or not is_instance_valid(body):
        return false
    var action_cell := door_action_cell(action, door, body, world)
    var current_cell := body_route_cell(body, world)
    var door_distance := 999999.0
    var door_body := door as Node3D
    if door_body != null and is_instance_valid(door_body):
        door_distance = flat_distance(body.global_position, door_body.global_position)
    if action_cell == Vector2i(999999, 999999):
        if door_distance >= 999998.0:
            return true
        if door_distance <= door_action_max_distance(source):
            clear_door_action_reject(entry, body)
            return true
        record_door_action_reject(entry, body, source, "door_too_far", current_cell, action_cell, next_cell, -1, door_distance)
        return false
    var route_cells: Array = entry.get("routeCells", [])
    var action_index := route_cells.find(action_cell)
    var current_steps := cell_manhattan(current_cell, action_cell)
    var next_steps := 999999
    if next_cell != Vector2i(999999, 999999):
        next_steps = cell_manhattan(next_cell, action_cell)
    var max_steps := door_action_max_cell_steps(source)
    var max_distance := door_action_max_distance(source)
    var route_supports_action := action_index >= 0 and action_index <= DOOR_ACTION_LOOKAHEAD_CELLS
    if source == "collision":
        route_supports_action = action_index >= 0 and action_index <= DOOR_ACTION_COLLISION_MAX_CELL_STEPS
    var local_by_cell := current_steps <= max_steps
    var local_by_distance := door_distance <= max_distance
    var next_is_action := next_steps <= 1
    if (local_by_cell or local_by_distance) and (route_supports_action or next_is_action or source == "direct"):
        if source == "lookahead" and not door_stage_transition_is_clear(entry, current_cell, next_cell, action_cell, world):
            record_door_action_reject(entry, body, source, "door_stage_path_blocked", current_cell, action_cell, next_cell, action_index, door_distance)
            return false
        clear_door_action_reject(entry, body)
        return true
    var reason := "door_action_not_local"
    if not route_supports_action and not next_is_action and source != "direct":
        reason = "door_action_not_on_near_route"
    elif not local_by_cell and not local_by_distance:
        reason = "door_action_actor_too_far"
    record_door_action_reject(entry, body, source, reason, current_cell, action_cell, next_cell, action_index, door_distance)
    return false

func door_stage_transition_is_clear(entry: Dictionary, current_cell: Vector2i, next_cell: Vector2i, action_cell: Vector2i, world) -> bool:
    if world == null or next_cell == Vector2i(999999, 999999) or next_cell == current_cell:
        return true
    if not world.has_method("cell_transition_pathable"):
        return true
    var moving_home := String(entry.get("activeGoalKind", "")) == "home"
    var snapshot: Dictionary = {}
    if world.has_method("cached_static_tile_snapshot"):
        snapshot = world.cached_static_tile_snapshot(false, moving_home)
    elif world.has_method("build_snapshot"):
        snapshot = world.build_snapshot(entry, false, moving_home)
    var target_lookup: Dictionary = {}
    target_lookup[next_cell] = true
    if action_cell != Vector2i(999999, 999999):
        target_lookup[action_cell] = true
    var transition: Dictionary = world.cell_transition_pathable(entry, snapshot, current_cell, next_cell, target_lookup, true)
    return bool(transition.get("ok", false))

func door_action_cell(action: Dictionary, door: Node, body: Node3D, world) -> Vector2i:
    var cell_value = action.get("cell")
    if cell_value is Vector2i:
        return cell_value
    var door_body := door as Node3D
    if door_body != null and is_instance_valid(door_body):
        return body_route_cell(door_body, world)
    if body != null:
        return body_route_cell(body, world)
    return Vector2i(999999, 999999)

func body_route_cell(node: Node3D, world) -> Vector2i:
    if node == null:
        return Vector2i(999999, 999999)
    if world != null and world.has_method("world_cell"):
        return world.world_cell(node.global_position)
    return Vector2i(roundi(node.global_position.x / CELL), roundi(node.global_position.z / CELL))

func door_action_max_cell_steps(source: String) -> int:
    if source == "lookahead":
        return DOOR_ACTION_LOOKAHEAD_MAX_CELL_STEPS
    if source == "collision":
        return DOOR_ACTION_COLLISION_MAX_CELL_STEPS
    return DOOR_ACTION_DIRECT_MAX_CELL_STEPS

func door_action_max_distance(source: String) -> float:
    if source == "lookahead":
        return DOOR_ACTION_LOOKAHEAD_MAX_DISTANCE
    if source == "collision":
        return DOOR_ACTION_COLLISION_MAX_DISTANCE
    return DOOR_ACTION_DIRECT_MAX_DISTANCE

func record_door_action_reject(entry: Dictionary, body: Node3D, source: String, reason: String, current_cell: Vector2i, action_cell: Vector2i, next_cell: Vector2i, action_index: int, door_distance: float) -> void:
    var reject := {
        "source": source,
        "reason": reason,
        "currentCell": current_cell,
        "actionCell": action_cell,
        "nextCell": next_cell,
        "actionIndex": action_index,
        "doorDistance": snappedf(door_distance, 0.001)
    }
    entry["doorActionReject"] = reject
    if body != null and is_instance_valid(body):
        body.set_meta("npc_door_action_reject", reject)

func clear_door_action_reject(entry: Dictionary, body: Node3D) -> void:
    entry.erase("doorActionReject")
    if body != null and is_instance_valid(body) and body.has_meta("npc_door_action_reject"):
        body.remove_meta("npc_door_action_reject")

func cell_manhattan(a: Vector2i, b: Vector2i) -> int:
    return abs(a.x - b.x) + abs(a.y - b.y)

func door_match_portal_id(door: Node) -> String:
    door = interaction_door_for_collider(door)
    if door == null:
        return ""
    if system != null:
        var autonomy_system = system.get("autonomy_system")
        if autonomy_system != null:
            var door_portals = autonomy_system.get("door_portals")
            if door_portals != null and door_portals.has_method("resolve_portal_id"):
                var resolved := String(door_portals.resolve_portal_id(door, ""))
                if resolved != "":
                    return resolved
    if door.has_meta("door_portal_id"):
        return String(door.get_meta("door_portal_id"))
    return ""

func door_match_group_id(door: Node) -> String:
    door = interaction_door_for_collider(door)
    if door != null and door.has_meta("door_group_id"):
        return String(door.get_meta("door_group_id"))
    return ""

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
    NpcRouteStateStoreScript.write_status(entry, status, reason, "NpcRouteMovementController")

func increment_route_replan(entry: Dictionary) -> void:
    entry["routeReplans"] = int(entry.get("routeReplans", 0)) + 1
    if _object_has_property(system, "npc_route_replans"):
        system.set("npc_route_replans", int(system.get("npc_route_replans")) + 1)
    if _object_has_property(system, "npc_path_detours"):
        system.set("npc_path_detours", int(system.get("npc_path_detours")) + 1)

func increment_stuck_recovery(entry: Dictionary) -> void:
    entry["stuckRecoveries"] = int(entry.get("stuckRecoveries", 0)) + 1
    if _object_has_property(system, "npc_stuck_recoveries"):
        system.set("npc_stuck_recoveries", int(system.get("npc_stuck_recoveries")) + 1)

func _object_has_property(object, property_name: String) -> bool:
    if object == null:
        return false
    for property in object.get_property_list():
        if String((property as Dictionary).get("name", "")) == property_name:
            return true
    return false

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

func record_blocked_endpoint_cell(entry: Dictionary, route: Dictionary) -> void:
    var reason := String(route.get("reason", ""))
    var authority := String(route.get("routeAuthorityState", ""))
    var collision_failure := reason in ["blocked_capsule_probe", "path_crosses_static_collision", "blocked_static_collision", "blocked_static_transition"]
    var terminal_endpoint_failure := authority in ["unreachable_static", "invalid_goal"] and reason in [
        "blocked_capsule_probe",
        "path_endpoint_mismatch",
        "target_blocked",
        "endpoint_not_server_walkable",
        "no_target_server_walkable"
    ]
    if not (collision_failure or terminal_endpoint_failure):
        return
    var target_cell := route_cell_from_value(route.get("targetCell", Vector2i(999999, 999999)))
    if target_cell == Vector2i(999999, 999999):
        return
    var memory: Dictionary = entry.get("blockedEndpointCells", {}) if entry.get("blockedEndpointCells", {}) is Dictionary else {}
    memory["%d,%d" % [target_cell.x, target_cell.y]] = {
        "frame": Engine.get_process_frames(),
        "reason": reason
    }
    entry["blockedEndpointCells"] = memory

func route_cell_from_value(value) -> Vector2i:
    if value is Vector2i:
        return value
    if value is Dictionary:
        var dict: Dictionary = value
        return Vector2i(int(dict.get("x", 999999)), int(dict.get("z", dict.get("y", 999999))))
    if value is Array and (value as Array).size() >= 2:
        var array_value: Array = value
        return Vector2i(int(array_value[0]), int(array_value[1]))
    return Vector2i(999999, 999999)

func flat_distance(a: Vector3, b: Vector3) -> float:
    return Vector2(a.x - b.x, a.z - b.z).length()
