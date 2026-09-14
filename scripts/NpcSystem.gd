extends Node3D
class_name NpcSystem

const NpcVisualFactoryScript := preload("res://scripts/NpcVisualFactory.gd")
const NpcPathingScript := preload("res://scripts/NpcPathing.gd")
const NpcCombatScript := preload("res://scripts/NpcCombat.gd")
const NpcProfileRulesScript := preload("res://scripts/NpcProfileRules.gd")
const NpcStatsScript := preload("res://scripts/NpcStats.gd")
const ItemCatalogScript := preload("res://scripts/ItemCatalog.gd")
const NpcAutonomySystemScript := preload("res://scripts/npc_ai/NpcAutonomySystem.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NpcAgentScene := preload("res://scenes/npc/NpcAgent.tscn")
const NpcAgentScript := preload("res://scripts/npc_ai/NpcAgent.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcMotionControllerScript := preload("res://scripts/npc_ai/NpcMotionController.gd")
const NpcSafePlacementServiceScript := preload("res://scripts/npc_ai/NpcSafePlacementService.gd")
const HomeInteriorServiceScript := preload("res://scripts/npc_ai/behavior/HomeInteriorService.gd")
const CharacterMotorProfileScript := preload("res://scripts/npc_ai/contracts/CharacterMotorProfile.gd")
const NpcRouteStateStoreScript := preload("res://scripts/npc_ai/routing/NpcRouteStateStore.gd")

const CELL := 1.35
const DOOR_TRAFFIC_RELEASE_RADIUS := CELL * 0.72
const FORAGE_SCAN_NODE_LIMIT := 1200
const FORAGE_SCAN_CANDIDATE_LIMIT := 8
const RESOURCE_TARGET_CACHE_FRAMES := 240
const NO_DETOUR := Vector3(9999999.0, 9999999.0, 9999999.0)
const NPC_SPEED_MODE_WALKING := "walking"
const NPC_SPEED_MODE_SPRINTING := "sprinting"
const NPC_MOTION_BUDGET_ACTIVE_THRESHOLD := 16
const NPC_MOTION_BUDGET_CROWDED_THRESHOLD := 24
const NPC_MOTION_BUDGET_VERY_CROWDED_THRESHOLD := 30
const NPC_MOTION_BUDGET_ACTIVE := 10
const NPC_MOTION_BUDGET_CROWDED := 4
const NPC_MOTION_BUDGET_VERY_CROWDED := 3
const NPC_MOTION_ACCUMULATED_DELTA_CAP := 4.0
const NPC_MOTION_SKIPPED_STREAK_URGENT := 12
const NPC_BRAIN_FRAME_BUDGET_MS := 4.0
const NPC_BRAIN_BUDGET_SKIP_STREAK_URGENT := 12
const NPC_MOTION_FRAME_BUDGET_MS := 8.0
const NPC_CLOCK_DISPLAY_OFFSET := 0.25
const NPC_DUSK_START_CLOCK := 18.25 / 24.0
const NPC_DAWN_START_CLOCK := 5.25 / 24.0
const NAVIGATION_PROP_CHANGE_EVENTS_PER_FRAME := 1
const NAVIGATION_PROP_CHANGE_OBJECT_IDS_PER_FRAME := 2

var main
var hostile_system
var npc_root: Node3D
var npcs: Array = []
var npc_by_id := {}
var pending_saved_npc_facts := {}
var spawned_town_keys := {}
var town_population_claims := {}
var guard_shots := 0
var guard_melee_strikes := 0
var door_opens := 0
var door_closes := 0
var job_runs_completed := 0
var last_message := ""
var focused_dialogue_body: Node = null
var npc_use_animations := 0
var npc_path_detours := 0
var npc_blocked_moves := 0
var npc_forage_runs := 0
var npc_food_eaten := 0
var npc_route_replans := 0
var npc_stuck_recoveries := 0
var npc_reservation_waits := 0
var npc_unreachable_goals := 0
var npc_validated_moves := 0
var npc_avoidance_active_frames := 0
var npc_avoidance_callback_frames := 0
var npc_avoidance_fallback_frames := 0
var npc_avoidance_active_registrations := 0
var visual_factory
var pathing
var combat
var autonomy_system
var motion_controller
var safe_placement_service
var components_initialized := false
var component_init_attempted := false
var component_init_in_progress := false
var last_spawn_scan_frame := -1
var last_spawn_scan_revision := -1
var npc_update_cursor := 0
var npc_motion_cursor := 0
var npc_prefetch_cursor := 0
var npc_update_active := false
var external_move_budget_physics_frame := -1
var published_navigation_semantics := {}
var metadata_key_sanitizer: RegEx = null
var navigation_change_flush_pending := false
var navigation_change_process_frame := -1

func performance_monitor():
    return main.get("runtime_perf_monitor") if main != null else null

func setup(main_node, hostile_system_node) -> void:
    main = main_node
    hostile_system = hostile_system_node
    npc_root = Node3D.new()
    npc_root.name = "TownNPCs"
    add_child(npc_root)
    ensure_autonomy_system()
    ensure_components()

func ensure_autonomy_system() -> void:
    if autonomy_system != null and is_instance_valid(autonomy_system):
        return
    autonomy_system = NpcAutonomySystemScript.new()
    autonomy_system.name = "NpcAutonomySystem"
    add_child(autonomy_system)
    autonomy_system.setup(self, main)

func ensure_components() -> void:
    if components_initialized or component_init_in_progress:
        return

    component_init_in_progress = true
    component_init_attempted = true

    if visual_factory == null:
        visual_factory = NpcVisualFactoryScript.new()
        visual_factory.setup(main)

    if pathing == null:
        pathing = NpcPathingScript.new()
        pathing.setup(self, main)

    if combat == null and visual_factory != null:
        combat = NpcCombatScript.new()
        combat.setup(self, hostile_system, visual_factory.arrow_material)

    if motion_controller == null:
        motion_controller = NpcMotionControllerScript.new()
        motion_controller.setup(self, main)

    if safe_placement_service == null:
        safe_placement_service = NpcSafePlacementServiceScript.new()
        safe_placement_service.setup(self, main)

    components_initialized = visual_factory != null \
        and pathing != null \
        and combat != null \
        and motion_controller != null \
        and safe_placement_service != null

    component_init_in_progress = false

func _exit_tree() -> void:
    cleanup_pathing_agents()

func cleanup_pathing_agents() -> Dictionary:
    if pathing != null and pathing.has_method("cleanup_all"):
        return pathing.cleanup_all()
    return { "avoidance": 0, "reason": "missing_pathing" }

func shutdown_for_process_exit() -> Dictionary:
    # NavigationServer3D resources must be released while the scene tree and
    # server are still alive.  Waiting for Node predelete leaves this ordering
    # up to engine teardown, which is unsafe after a populated world has used
    # the navmesh backend.
    var pathing_result := { "avoidance": 0, "reason": "missing_pathing" }
    if pathing != null and pathing.has_method("shutdown_for_process_exit"):
        pathing_result = pathing.shutdown_for_process_exit()
    elif pathing != null and pathing.has_method("cleanup_all"):
        pathing_result = pathing.cleanup_all()
    pathing = null
    var navmesh_before := {}
    var navmesh_after := {}
    if autonomy_system != null and is_instance_valid(autonomy_system):
        var navmesh_world = autonomy_system.get("navmesh_world")
        if navmesh_world != null and navmesh_world.has_method("stats"):
            var before_value = navmesh_world.call("stats")
            navmesh_before = before_value.duplicate(true) if before_value is Dictionary else {}
        if autonomy_system.has_method("shutdown_for_process_exit"):
            autonomy_system.call("shutdown_for_process_exit")
        navmesh_world = autonomy_system.get("navmesh_world")
        if navmesh_world != null and navmesh_world.has_method("stats"):
            var after_value = navmesh_world.call("stats")
            navmesh_after = after_value.duplicate(true) if after_value is Dictionary else {}
        autonomy_system.queue_free()
        autonomy_system = null
    return {
        "pathing": pathing_result,
        "navmeshBefore": navmesh_before,
        "navmeshAfter": navmesh_after
    }

func clear() -> void:
    cleanup_pathing_agents()
    for entry in npcs:
        var body := entry.get("body") as Node
        if body and is_instance_valid(body) and bool(body.get_meta("npc_owned_by_system", false)):
            body.queue_free()
    npcs.clear()
    npc_by_id.clear()
    spawned_town_keys.clear()
    last_spawn_scan_frame = -1
    last_spawn_scan_revision = -1
    npc_prefetch_cursor = 0
    navigation_change_process_frame = -1
    town_population_claims.clear()
    published_navigation_semantics.clear()
    pending_saved_npc_facts.clear()
    focused_dialogue_body = null
    if autonomy_system:
        autonomy_system.clear()
    if combat:
        combat.clear()

func clear_combat_transients() -> void:
    if combat:
        combat.clear()

func unregister_npc(body: Node) -> void:
    if body == null:
        return
    var matched_entry := {}
    for entry in npcs:
        if entry.get("body") == body:
            matched_entry = entry
            break
    if autonomy_system:
        var release_id := ""
        if body.has_meta("npc_stable_id"):
            release_id = String(body.get_meta("npc_stable_id"))
        if release_id != "":
            if matched_entry.is_empty():
                autonomy_system.cleanup_actor_ownership(release_id, "actor_unregistered")
            else:
                autonomy_system.cleanup_actor_ownership(matched_entry, "actor_unregistered")
    if autonomy_system:
        autonomy_system.unregister_npc(body)
    npc_by_id.erase(body.get_instance_id())
    if focused_dialogue_body == body:
        focused_dialogue_body = null
    for entry in npcs.duplicate():
        if entry.get("body") == body:
            npcs.erase(entry)

func focus_dialogue_npc(body: Node, player_position: Vector3) -> void:
    clear_dialogue_focus()
    if body == null or not is_instance_valid(body):
        return
    focused_dialogue_body = body
    body.set_meta("npc_dialogue_focused", true)
    body.set_meta("npc_dialogue_face_position", player_position)

func clear_dialogue_focus() -> void:
    if focused_dialogue_body != null and is_instance_valid(focused_dialogue_body):
        focused_dialogue_body.set_meta("npc_dialogue_focused", false)
    focused_dialogue_body = null

func order_wait(actor_id, reason := "scripted_wait") -> Dictionary:
    var entry := npc_entry_for_actor(actor_id)
    if entry.is_empty():
        return scripted_order_result(null, "FAILED_TARGET_GONE", reason, "missing_actor")
    return apply_scripted_order(entry, "wait", reason, Vector3.INF, -1.0, true, true, NPC_SPEED_MODE_WALKING)

func order_go_to(actor_id, target: Vector3, reason := "scripted_go_to", arrival_radius := -1.0, speed_mode := NPC_SPEED_MODE_WALKING, combat_overlay := false) -> Dictionary:
    var entry := npc_entry_for_actor(actor_id)
    if entry.is_empty():
        return scripted_order_result(null, "FAILED_TARGET_GONE", reason, "missing_actor")
    return apply_scripted_order(entry, "go_to", reason, target, arrival_radius, true, true, speed_mode, combat_overlay)

func order_go_home(actor_id, reason := "scripted_go_home", speed_mode := NPC_SPEED_MODE_WALKING) -> Dictionary:
    var entry := npc_entry_for_actor(actor_id)
    if entry.is_empty():
        return scripted_order_result(null, "FAILED_TARGET_GONE", reason, "missing_actor")
    return apply_scripted_order(entry, "go_home", reason, entry.get("homePosition", Vector3.INF), CELL * 0.82, false, true, speed_mode)

func order_face_player(actor_id, reason := "scripted_face_player") -> Dictionary:
    var entry := npc_entry_for_actor(actor_id)
    if entry.is_empty():
        return scripted_order_result(null, "FAILED_TARGET_GONE", reason, "missing_actor")
    return apply_scripted_order(entry, "face_player", reason, Vector3.INF, -1.0, true, true, NPC_SPEED_MODE_WALKING)

func order_resume_schedule(actor_id) -> Dictionary:
    return cancel_order(actor_id, "resume_schedule")

func cancel_order(actor_id, reason := "scripted_cancelled") -> Dictionary:
    var entry := npc_entry_for_actor(actor_id)
    if entry.is_empty():
        return scripted_order_result(null, "FAILED_TARGET_GONE", reason, "missing_actor")
    var body := entry.get("body") as Node
    var cleanup := release_replaced_order_state(entry, reason)
    var result := scripted_order_result(entry, "CANCELLED", reason, "")
    result["replacementCleanup"] = cleanup
    entry["scriptedOrder"] = result
    clear_scripted_order_metadata(body)
    entry["activeGoalKind"] = "idle"
    entry.erase("activeMotionGoal")
    entry.erase("activeMotionPlan")
    set_npc_speed_mode(entry, NPC_SPEED_MODE_WALKING, reason)
    if body != null and is_instance_valid(body):
        body.set_meta("npc_scripted_order_state", "CANCELLED")
        body.set_meta("npc_scripted_order_reason", reason)
    return result

func scripted_order_status(actor_id) -> Dictionary:
    var entry := npc_entry_for_actor(actor_id)
    if entry.is_empty():
        return { "state": "FAILED_TARGET_GONE", "reason": "missing_actor" }
    return entry.get("scriptedOrder", {}) if entry.get("scriptedOrder", {}) is Dictionary else {}

func set_scripted_target(body: Node, target: Vector3, allow_outside := true, hold_on_arrival := true, speed_mode := NPC_SPEED_MODE_WALKING) -> void:
    if body == null or not is_instance_valid(body):
        return
    var normalized_speed_mode := normalize_npc_speed_mode(speed_mode)
    var entry := npc_entry_for_actor(body)
    if entry.is_empty():
        body.set_meta("npc_scripted_target", target)
        body.set_meta("npc_scripted_allow_outside", allow_outside)
        body.set_meta("npc_scripted_hold_on_arrival", hold_on_arrival)
        body.set_meta("npc_scripted_arrived", false)
        body.set_meta("npc_scripted_order_kind", "go_to")
        body.set_meta("npc_scripted_order_state", "PENDING")
        body.set_meta("npc_scripted_order_reason", "legacy_set_scripted_target")
        body.set_meta("npc_scripted_speed_mode", normalized_speed_mode)
        body.set_meta("npc_speed_mode", normalized_speed_mode)
        body.set_meta("npc_rushing", normalized_speed_mode == NPC_SPEED_MODE_SPRINTING)
        return
    apply_scripted_order(entry, "go_to", "legacy_set_scripted_target", target, -1.0, allow_outside, hold_on_arrival, normalized_speed_mode)

func clear_scripted_target(body: Node) -> void:
    if body == null or not is_instance_valid(body):
        return
    var entry := npc_entry_for_actor(body)
    if not entry.is_empty():
        cancel_order(body, "clear_scripted_target")
        return
    clear_scripted_order_metadata(body)

func npc_entry_for_actor(actor_id) -> Dictionary:
    if actor_id == null:
        return {}
    if actor_id is Dictionary:
        return actor_id
    if actor_id is Node:
        for entry in npcs:
            if entry.get("body") == actor_id:
                return entry
        return {}
    var actor_key := String(actor_id)
    if actor_key == "":
        return {}
    for entry in npcs:
        var body := entry.get("body") as Node
        if String(entry.get("id", "")) == actor_key:
            return entry
        if body == null or not is_instance_valid(body):
            continue
        if body.name == actor_key:
            return entry
        if body.has_meta("npc_stable_id") and String(body.get_meta("npc_stable_id")) == actor_key:
            return entry
        if body.has_meta("npc_id") and String(body.get_meta("npc_id")) == actor_key:
            return entry
    return {}

func apply_scripted_order(entry: Dictionary, kind: String, reason: String, target: Vector3, arrival_radius: float, allow_outside: bool, hold_on_arrival: bool, speed_mode := NPC_SPEED_MODE_WALKING, combat_overlay := false) -> Dictionary:
    var body := entry.get("body") as Node
    if body == null or not is_instance_valid(body):
        return scripted_order_result(entry, "FAILED_TARGET_GONE", reason, "missing_body")
    var replacement_cleanup := release_replaced_order_state(entry, "scripted_order_replaced:%s" % kind)
    var order_serial := int(entry.get("scriptedOrderSerial", 0)) + 1
    entry["scriptedOrderSerial"] = order_serial
    var order_id := "%s:%s:%d" % [String(entry.get("id", body.name)), kind, order_serial]
    var normalized_radius := arrival_radius if arrival_radius > 0.0 else CELL * 0.45
    if kind == "go_home":
        normalized_radius = arrival_radius if arrival_radius > 0.0 else CELL * 0.82
    var normalized_speed_mode := set_npc_speed_mode(entry, speed_mode, reason)
    var movement_speed := npc_speed_for_mode(entry, normalized_speed_mode)
    var result := {
        "id": order_id,
        "kind": kind,
        "state": "PENDING",
        "submittedPhysicsFrame": Engine.get_physics_frames(),
        "submittedWallMsec": Time.get_ticks_msec(),
        "reason": reason,
        "submissionReason": reason,
        "statusReason": reason,
        "failureReason": "",
        "target": target,
        "arrivalRadius": normalized_radius,
        "allowOutside": allow_outside,
        "holdOnArrival": hold_on_arrival,
        "speedMode": normalized_speed_mode,
        "speed": movement_speed,
        "combatOverlay": combat_overlay,
        "usesRouteStack": kind in ["go_to", "go_home"],
        "replacementCleanup": replacement_cleanup
    }
    entry["scriptedOrder"] = result
    entry["activeGoalKind"] = "home" if kind == "go_home" else "scripted"
    entry["routePriority"] = 210 if normalized_speed_mode == NPC_SPEED_MODE_SPRINTING else (190 if kind == "go_home" else 180)
    if kind in ["go_to", "go_home"]:
        entry["pathWaypoints"] = []
        entry["routeCells"] = []
        entry["routeActions"] = {}
        entry["routeForceReplan"] = true
        entry.erase("routeKey")
        entry.erase("routePendingKey")
        entry.erase("routePendingRetryFrame")
        entry.erase("routePendingSnapshotRevision")
        entry.erase("routeFailureRetryFrame")
        entry.erase("routeDynamicAvoidCells")
        entry.erase("routeDynamicAvoidUntilFrame")
    if kind == "go_home":
        entry["homeRouteIndex"] = 0
        entry.erase("homeActiveTargetCell")
    body.set_meta("npc_scripted_order_id", order_id)
    body.set_meta("npc_scripted_order_kind", kind)
    body.set_meta("npc_scripted_order_state", "PENDING")
    body.set_meta("npc_scripted_order_reason", reason)
    body.set_meta("npc_scripted_order_failure_reason", "")
    body.set_meta("npc_scripted_arrived", false)
    body.set_meta("npc_scripted_arrival_radius", normalized_radius)
    body.set_meta("npc_scripted_allow_outside", allow_outside)
    body.set_meta("npc_scripted_hold_on_arrival", hold_on_arrival)
    body.set_meta("npc_scripted_speed_mode", normalized_speed_mode)
    body.set_meta("npc_scripted_speed", movement_speed)
    body.set_meta("npc_scripted_combat_overlay_enabled", combat_overlay)
    if kind == "go_to":
        body.set_meta("npc_scripted_target", target)
    elif body.has_meta("npc_scripted_target"):
        body.remove_meta("npc_scripted_target")
    entry["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_HOME if kind == "go_home" else NpcEnumsScript.GOAL_KIND_SCRIPTED, "reason": reason }
    return result

func release_replaced_order_state(entry: Dictionary, reason: String) -> Dictionary:
    ensure_autonomy_system()
    var route_cancellation := {"ok": true, "cancelled": false, "reason": "missing_autonomy"}
    if autonomy_system != null:
        if autonomy_system.has_method("cancel_active_route_request"):
            route_cancellation = autonomy_system.cancel_active_route_request(entry, reason)
        if autonomy_system.has_method("release_action_owned_state"):
            autonomy_system.release_action_owned_state(entry, reason)
    release_job_reservation(entry, reason)
    for key in [
        "pathWaypoints",
        "routeCells",
        "routeActions",
        "routeForceReplan",
        "routeKey",
        "routePendingKey",
        "routePendingRetryFrame",
        "routePendingSnapshotRevision",
        "routeFailureRetryFrame",
        "routeDynamicAvoidCells",
        "routeDynamicAvoidUntilFrame",
        "homeRouteV2RequestId",
        "homeRouteV2Key",
        "routineRouteV2RequestId",
        "routineRouteV2Key",
        "_routineRouteV2Intent",
        "routineRouteV2IntentKind",
        "routineRouteV2SemanticKind",
        "activeDoorPortalId",
        "activeDoorActorId",
        "activeDoorDirection",
        "activeDoorTrafficGroupId",
        "activeTrafficStepGroup"
    ]:
        entry.erase(key)
    NpcRouteStateStoreScript.clear_route_lease(entry, "NpcSystem.release_replaced_order_state")
    NpcRouteStateStoreScript.write_status(entry, "idle", reason, "NpcSystem.release_replaced_order_state")
    return {
        "routeCancellation": route_cancellation,
        "doorAndTrafficReleased": autonomy_system != null,
        "jobReservationReleased": true
    }

func scripted_order_result(entry, state: String, reason: String, failure_reason := "") -> Dictionary:
    var result := {}
    if entry is Dictionary:
        result = (entry as Dictionary).get("scriptedOrder", {}) if (entry as Dictionary).get("scriptedOrder", {}) is Dictionary else {}
    result = result.duplicate(true)
    if not result.has("submissionReason"):
        result["submissionReason"] = String(result.get("reason", reason))
    result["state"] = state
    result["reason"] = reason
    result["statusReason"] = reason
    result["failureReason"] = failure_reason
    if entry is Dictionary:
        (entry as Dictionary)["scriptedOrder"] = result
        var body := (entry as Dictionary).get("body") as Node
        if body != null and is_instance_valid(body):
            body.set_meta("npc_scripted_order_state", state)
            body.set_meta("npc_scripted_order_reason", reason)
            body.set_meta("npc_scripted_order_failure_reason", failure_reason)
    return result

func clear_scripted_order_metadata(body: Node) -> void:
    if body == null or not is_instance_valid(body):
        return
    for meta_key in [
        "npc_scripted_target",
        "npc_scripted_order_id",
        "npc_scripted_order_kind",
        "npc_scripted_order_state",
        "npc_scripted_order_reason",
        "npc_scripted_order_failure_reason",
        "npc_scripted_arrival_radius",
        "npc_scripted_speed_mode",
        "npc_scripted_speed",
        "npc_scripted_combat_overlay_enabled"
    ]:
        if body.has_meta(meta_key):
            body.remove_meta(meta_key)
    body.set_meta("npc_scripted_arrived", false)
    body.set_meta("npc_speed_mode", NPC_SPEED_MODE_WALKING)
    body.set_meta("npc_rushing", false)

func normalize_npc_speed_mode(speed_mode) -> String:
    var mode := String(speed_mode).strip_edges().to_lower()
    if mode in ["sprint", "sprinting", "rush", "rushing", "run", "running"]:
        return NPC_SPEED_MODE_SPRINTING
    return NPC_SPEED_MODE_WALKING

func npc_speed_for_mode(entry: Dictionary, speed_mode := NPC_SPEED_MODE_WALKING) -> float:
    var profile = entry.get("motorProfile") if entry is Dictionary else null
    if profile == null:
        profile = CharacterMotorProfileScript.npc_default()
    var mode := normalize_npc_speed_mode(speed_mode)
    if mode == NPC_SPEED_MODE_SPRINTING:
        return maxf(0.1, float(profile.get("sprint_speed")))
    return maxf(0.1, float(profile.get("walk_speed")))

func set_npc_speed_mode(entry: Dictionary, speed_mode := NPC_SPEED_MODE_WALKING, reason := "") -> String:
    if entry.is_empty():
        return normalize_npc_speed_mode(speed_mode)
    var mode := normalize_npc_speed_mode(speed_mode)
    var movement_speed := npc_speed_for_mode(entry, mode)
    entry["npcSpeedMode"] = mode
    entry["npcSpeed"] = movement_speed
    entry["npcSpeedReason"] = reason
    entry["npcRushing"] = mode == NPC_SPEED_MODE_SPRINTING
    var body := entry.get("body") as Node
    if body != null and is_instance_valid(body):
        body.set_meta("npc_speed_mode", mode)
        body.set_meta("npc_speed", movement_speed)
        body.set_meta("npc_speed_reason", reason)
        body.set_meta("npc_rushing", mode == NPC_SPEED_MODE_SPRINTING)
    return mode

func deterministic_profile_float(profile: Dictionary, body: Node, domain: String, minimum: float, maximum: float) -> float:
    var stable_id := String(profile.get("id", body.name if body != null else "npc"))
    var role := String(profile.get("role", ""))
    var town_key := String(profile.get("townKey", ""))
    var key := "%s:%s:%s:%s" % [stable_id, role, town_key, domain]
    var unit := float(abs(hash(key)) % 100000) / 99999.0
    return lerpf(minimum, maximum, unit)

func register_npc(body: Node3D, profile: Dictionary) -> Dictionary:
    if body == null:
        return {}
    ensure_components()
    unregister_npc(body)
    var character_body := body as CharacterBody3D
    if character_body != null:
        character_body.collision_layer = NpcConstantsScript.COLLISION_NPC_BODY
        character_body.collision_mask = NpcConstantsScript.COLLISION_NPC_BODY_MASK
    var body_position: Vector3 = body.global_position if body.is_inside_tree() else body.position
    var home_cell: Vector2i = profile.get("homeCell", profile.get("cell", Vector2i.ZERO))
    var porch_cell: Vector2i = profile.get("porchCell", home_cell)
    var door_cell: Vector2i = profile.get("doorCell", porch_cell)
    var interior_landing_cell: Vector2i = profile.get("interiorLandingCell", home_cell)
    var guard_cell: Vector2i = profile.get("guardCell", porch_cell)
    var level := float(profile.get("level", body_position.y))
    var home_position := cell_to_position(home_cell, level)
    var porch_position := cell_to_position(porch_cell, level)
    var profile_home_route_cells: Array = profile.get("homeRouteCells", []) if profile.get("homeRouteCells", []) is Array else []
    var profile_home_route_positions: Array = profile.get("homeRoutePositions", []) if profile.get("homeRoutePositions", []) is Array else []
    var home_route_positions: Array = profile_home_route_positions.duplicate()
    if home_route_positions.is_empty() and not profile_home_route_cells.is_empty():
        for route_cell_variant in profile_home_route_cells:
            if not (route_cell_variant is Vector2i):
                continue
            var route_cell: Vector2i = route_cell_variant
            var route_position := cell_to_position(route_cell, level)
            if home_route_positions.is_empty() or flat_cell_for_position(home_route_positions[home_route_positions.size() - 1]) != route_cell:
                home_route_positions.append(route_position)
    if home_route_positions.is_empty():
        if porch_cell != home_cell:
            home_route_positions.append(porch_position)
        home_route_positions.append(home_position)
    else:
        var route_ends_at_home := false
        for route_target in home_route_positions:
            if route_target is Vector3 and flat_cell_for_position(route_target) == home_cell:
                route_ends_at_home = true
                break
        if not route_ends_at_home:
            home_route_positions.append(home_position)
    var role := String(profile.get("role", "Villager"))
    var can_fight := bool(profile.get("canFight", false))
    var job := String(profile.get("job", ""))
    if job == "":
        job = job_for_role(role, can_fight)
    var entry := {
        "body": body,
        "id": String(profile.get("id", body.name)),
        "name": String(profile.get("name", body.name)),
        "role": role,
        "displayRole": String(profile.get("displayRole", role)),
        "townKey": String(profile.get("townKey", "")),
        "townCenter": profile.get("townCenter", Vector2i(roundi(body_position.x / CELL), roundi(body_position.z / CELL))),
        "townRadius": int(profile.get("townRadius", 18)),
        "level": level,
        "homeCell": home_cell,
        "homeKey": int(profile.get("homeKey", -1)),
        "homeStableId": String(profile.get("homeStableId", "")),
        "porchCell": porch_cell,
        "doorCell": door_cell,
        "doorPortalId": String(profile.get("doorPortalId", "")),
        "interiorLandingCell": interior_landing_cell,
        "guardCell": guard_cell,
        "homePosition": home_position,
        "porchPosition": porch_position,
        "homeRouteCells": profile_home_route_cells,
        "homeRoutePositions": home_route_positions,
        "interiorMinCell": profile.get("interiorMinCell", home_cell),
        "interiorMaxCell": profile.get("interiorMaxCell", home_cell),
        "guardPosition": cell_to_position(guard_cell, level),
        "homeRouteIndex": 0,
        "canFight": can_fight,
        "nightGuard": bool(profile.get("nightGuard", false)),
        "weaponId": weapon_for_profile(profile, role, can_fight),
        "heldAnchor": null,
        "heldVisual": null,
        "useAnim": 0.0,
        "useAction": "",
        "useDuration": 0.0,
        "job": job,
        "jobResource": resource_for_job(job),
        "jobPhase": "idle",
        "jobTimer": deterministic_profile_float(profile, body, "job_timer", 2.0, 6.0),
        "jobTarget": body_position,
        "jobTargetNode": null,
        "jobObjectId": "",
        "jobReservationId": "",
        "jobApproachSlotId": "",
        "jobFailureReason": "",
        "carriedResource": "",
        "goal": "idle",
        "personalInventory": {},
        "hunger": deterministic_profile_float(profile, body, "hunger", 72.0, 96.0),
        "maxHunger": 100.0,
        "jobRuns": 0,
        "requiredVisibleScripted": bool(profile.get("requiredVisibleScripted", false)),
        "cooldown": deterministic_profile_float(profile, body, "cooldown", 0.2, 1.2),
        "homeReturnTime": 0.0,
        "dayTarget": body_position,
        "insideHome": false,
        "simulationLod": "active",
        "abstractSimulated": false,
        "abstractRegionId": "",
        "abstractTransit": null,
        "interiorRegionId": "",
        "restoredScheduleIntent": "",
        "npc_lod_brain_due": true,
        "lastMoveDistance": 0.0,
        "detourTarget": NO_DETOUR,
        "detourTimer": 0.0,
        "blockedMoveTime": 0.0,
        "pathWaypoints": [],
        "pathRefreshTimer": 0.0,
        "routeGoalCell": Vector2i(999999, 999999),
        "routeAllowOutside": false,
        "routeMovingHome": false,
        "routeStatus": "idle",
        "routeReason": "",
        "routeReplans": 0,
        "stuckRecoveries": 0,
        "reservationWaits": 0,
        "unreachableGoals": 0,
        "validatedMoves": 0,
        "routeCells": [],
        "routeActions": {},
        "routeSnapshotRevision": "",
        "routeForceReplan": false,
        "routeWaitTicks": 0,
        "routeYieldTicks": 0,
        "routePriority": 0,
        "jumpIntentTime": 0.0,
        "motorProfile": CharacterMotorProfileScript.npc_default()
    }
    apply_saved_npc_facts(entry)
    apply_npc_metadata(body, entry, home_cell, porch_cell, guard_cell, String(entry.get("job", job)))
    if bool(profile.get("startInsideHome", false)):
        var spawn_cell := flat_cell_for_position(body_position)
        var interior_min: Vector2i = entry.get("interiorMinCell", home_cell)
        var interior_max: Vector2i = entry.get("interiorMaxCell", home_cell)
        var spawn_inside := spawn_cell.x >= interior_min.x and spawn_cell.x <= interior_max.x and spawn_cell.y >= interior_min.y and spawn_cell.y <= interior_max.y
        if spawn_inside:
            mark_npc_inside_home(entry)
            NpcRouteStateStoreScript.write_status(entry, "arrived", "", "NpcSystem.spawn_inside_home")
    ensure_autonomy_system()
    var context = autonomy_system.register_npc(body, profile, entry)
    if context != null:
        entry["motorProfile"] = CharacterMotorProfileScript.from_traversal_profile(context.get("traversal_profile"))
    if body.get_script() == NpcAgentScript and body.has_method("configure_agent"):
        body.call("configure_agent", entry.get("motorProfile"))
    set_npc_speed_mode(entry, NPC_SPEED_MODE_WALKING, "spawn")
    publish_navigation_profile_semantics(entry)
    ensure_npc_held_item(entry)
    npcs.append(entry)
    npc_by_id[body.get_instance_id()] = entry
    return entry

func snapshot_job_facts() -> Array:
    var facts := []
    for entry in npcs:
        var body := entry.get("body") as Node
        if body == null or not is_instance_valid(body):
            continue
        var fact := {}
        if autonomy_system != null and autonomy_system.has_method("snapshot_lifecycle_fact"):
            fact = autonomy_system.snapshot_lifecycle_fact(entry)
        if fact.is_empty():
            fact = {
                "id": String(entry.get("id", "")),
                "role": String(entry.get("role", "")),
                "job": String(entry.get("job", "")),
                "jobResource": String(entry.get("jobResource", "")),
                "personalInventory": (entry.get("personalInventory", {}) as Dictionary).duplicate(true),
                "hunger": float(entry.get("hunger", 100.0)),
                "nightGuard": bool(entry.get("nightGuard", false)),
                "guardDuty": String(body.get_meta("npc_guard_duty", "")),
                "jobRuns": int(entry.get("jobRuns", 0))
            }
        facts.append(fact)
    facts.sort_custom(func(a, b): return String((a as Dictionary).get("id", "")) < String((b as Dictionary).get("id", "")))
    return facts

func restore_job_facts(facts) -> void:
    pending_saved_npc_facts.clear()
    if not (facts is Array):
        return
    for fact_value in facts:
        if not (fact_value is Dictionary):
            continue
        var fact: Dictionary = fact_value
        var npc_id := String(fact.get("id", ""))
        if npc_id != "":
            pending_saved_npc_facts[npc_id] = fact.duplicate(true)

func saved_npc_fact(actor_id) -> Dictionary:
    var npc_id := String(actor_id)
    if npc_id == "" or not pending_saved_npc_facts.has(npc_id):
        return {}
    var fact_value = pending_saved_npc_facts.get(npc_id, {})
    return fact_value.duplicate(true) if fact_value is Dictionary else {}

func apply_saved_npc_facts(entry: Dictionary) -> void:
    var npc_id := String(entry.get("id", ""))
    if npc_id == "" or not pending_saved_npc_facts.has(npc_id):
        return
    var fact: Dictionary = pending_saved_npc_facts[npc_id]
    ensure_autonomy_system()
    if autonomy_system != null and autonomy_system.has_method("apply_lifecycle_fact"):
        var time_of_day := float(main.get("time_of_day")) if main != null else -1.0
        autonomy_system.apply_lifecycle_fact(entry, fact, { "timeOfDay": time_of_day })
    else:
        entry["job"] = String(fact.get("job", entry.get("job", "")))
        entry["jobResource"] = String(fact.get("jobResource", entry.get("jobResource", "")))
        entry["personalInventory"] = (fact.get("personalInventory", {}) as Dictionary).duplicate(true)
        entry["hunger"] = clampf(float(fact.get("hunger", entry.get("hunger", 100.0))), 0.0, float(entry.get("maxHunger", 100.0)))
        entry["nightGuard"] = bool(fact.get("nightGuard", entry.get("nightGuard", false)))
        entry["jobRuns"] = max(0, int(fact.get("jobRuns", entry.get("jobRuns", 0))))

func apply_npc_metadata(body: Node, entry: Dictionary, home_cell: Vector2i, porch_cell: Vector2i, guard_cell: Vector2i, job: String) -> void:
    body.set_meta("npc_home_cell", home_cell)
    body.set_meta("npc_home_key", int(entry.get("homeKey", -1)))
    body.set_meta("npc_home_stable_id", String(entry.get("homeStableId", "")))
    body.set_meta("npc_porch_cell", porch_cell)
    body.set_meta("npc_door_portal_id", String(entry.get("doorPortalId", "")))
    body.set_meta("npc_guard_cell", guard_cell)
    body.set_meta("npc_town_key", String(entry["townKey"]))
    body.set_meta("npc_can_fight", bool(entry["canFight"]))
    body.set_meta("npc_job", job)
    body.set_meta("npc_job_phase", "idle")
    body.set_meta("npc_goal", String(entry.get("goal", "idle")))
    body.set_meta("npc_hunger", float(entry.get("hunger", 100.0)))
    body.set_meta("npc_inventory", entry.get("personalInventory", {}))
    body.set_meta("npc_job_runs", int(entry.get("jobRuns", 0)))
    body.set_meta("npc_has_home", true)
    body.set_meta("npc_inside_home", false)
    body.set_meta("npc_weapon", String(entry["weaponId"]))
    NpcRouteStateStoreScript.publish_to_body(entry)
    body.set_meta("npc_simulation_lod", String(entry.get("simulationLod", "active")))
    body.set_meta("npc_required_visible_sequence", bool(entry.get("requiredVisibleScripted", false)))
    body.set_meta("npc_speed_mode", normalize_npc_speed_mode(entry.get("npcSpeedMode", NPC_SPEED_MODE_WALKING)))
    body.set_meta("npc_rushing", false)

func publish_navigation_profile_semantics(entry: Dictionary) -> void:
    if autonomy_system == null or not autonomy_system.has_method("register_semantic_region"):
        return
    var stable_id := String(entry.get("id", "npc"))
    var town_key := String(entry.get("townKey", ""))
    var semantic_scope := town_key if town_key != "" else stable_id
    var level := float(entry.get("level", 0.0))
    var home_cell: Vector2i = entry.get("homeCell", Vector2i.ZERO)
    var porch_cell: Vector2i = entry.get("porchCell", home_cell)
    var guard_cell: Vector2i = entry.get("guardCell", porch_cell)
    var town_center: Vector2i = entry.get("townCenter", home_cell)
    var town_radius := int(entry.get("townRadius", 0))
    var home_id := "home:%s:%s" % [semantic_scope, stable_id]
    var interior_min: Vector2i = entry.get("interiorMinCell", home_cell)
    var interior_max: Vector2i = entry.get("interiorMaxCell", home_cell)
    register_navigation_semantic_once(&"home_interior", home_id, navigation_rect_bounds(interior_min, interior_max, level, CELL * 2.4), {
        "npcId": stable_id,
        "buildingId": home_id,
        "inside": true,
        "anchors": {
            "home": cell_key(home_cell),
            "bed": cell_key(home_cell)
        },
        "entrance": {
            "porchCell": cell_key(porch_cell),
            "portalHint": "door:%s" % cell_key(porch_cell)
        }
    })
    register_navigation_semantic_once(&"guard_post", "guard:%s:%s" % [semantic_scope, cell_key(guard_cell)], navigation_cell_bounds(guard_cell, level, 1, CELL * 2.2), {
        "npcId": stable_id,
        "homeId": home_id,
        "anchor": cell_key(guard_cell)
    })
    register_navigation_semantic_once(&"staging_area", "staging:%s:%s" % [semantic_scope, cell_key(porch_cell)], navigation_cell_bounds(porch_cell, level, 1, CELL * 2.0), {
        "homeId": home_id,
        "anchor": cell_key(porch_cell),
        "purpose": "door_approach"
    })
    if town_key == "":
        return
    var settlement_id := "settlement:%s" % town_key
    register_navigation_semantic_once(&"settlement_bounds", settlement_id, navigation_town_bounds(town_center, town_radius, level), {
        "townKey": town_key,
        "center": cell_key(town_center),
        "radius": town_radius
    })
    var path_span: int = maxi(10, town_radius - 2)
    register_navigation_semantic_once(&"road", "road:%s:x" % town_key, navigation_road_bounds(town_center, level, path_span, true), {
        "townKey": town_key,
        "axis": "x",
        "surface": "cobblestonePath"
    })
    register_navigation_semantic_once(&"road", "road:%s:z" % town_key, navigation_road_bounds(town_center, level, path_span, false), {
        "townKey": town_key,
        "axis": "z",
        "surface": "cobblestonePath"
    })
    var central_work := Vector2i(town_center.x, town_center.y - 3)
    register_navigation_semantic_once(&"work_anchor", "work:%s:central" % town_key, navigation_cell_bounds(central_work, level, 2, CELL * 2.4), {
        "townKey": town_key,
        "anchor": cell_key(central_work),
        "jobs": ["crafting", "storage", "forage_staging"]
    })

func register_navigation_semantic_once(kind: StringName, region_id: String, bounds: AABB, metadata := {}) -> void:
    if region_id == "" or published_navigation_semantics.has(region_id):
        return
    published_navigation_semantics[region_id] = true
    var nav_metadata: Dictionary = metadata.duplicate(true) if metadata is Dictionary else {}
    if not nav_metadata.has("routeable"):
        nav_metadata["routeable"] = false
    autonomy_system.register_semantic_region(kind, region_id, bounds, nav_metadata)

func navigation_cell_bounds(cell: Vector2i, level: float, radius_cells := 1, height := CELL * 2.0) -> AABB:
    var footprint_cells: int = radius_cells * 2 + 1
    var origin := Vector3(float(cell.x - radius_cells) * CELL - CELL * 0.5, level - CELL * 0.1, float(cell.y - radius_cells) * CELL - CELL * 0.5)
    return AABB(origin, Vector3(float(footprint_cells) * CELL, height, float(footprint_cells) * CELL))

func navigation_rect_bounds(min_cell: Vector2i, max_cell: Vector2i, level: float, height := CELL * 2.0) -> AABB:
    var min_x := mini(min_cell.x, max_cell.x)
    var max_x := maxi(min_cell.x, max_cell.x)
    var min_z := mini(min_cell.y, max_cell.y)
    var max_z := maxi(min_cell.y, max_cell.y)
    var origin := Vector3(float(min_x) * CELL - CELL * 0.5, level - CELL * 0.1, float(min_z) * CELL - CELL * 0.5)
    return AABB(origin, Vector3(float(max_x - min_x + 1) * CELL, height, float(max_z - min_z + 1) * CELL))

func navigation_town_bounds(center: Vector2i, radius_cells: int, level: float) -> AABB:
    var radius: int = maxi(1, radius_cells)
    var size_cells: int = radius * 2 + 1
    var origin := Vector3(float(center.x - radius) * CELL - CELL * 0.5, level - CELL, float(center.y - radius) * CELL - CELL * 0.5)
    return AABB(origin, Vector3(float(size_cells) * CELL, CELL * 8.0, float(size_cells) * CELL))

func navigation_road_bounds(center: Vector2i, level: float, span_cells: int, horizontal: bool) -> AABB:
    var span: int = maxi(1, span_cells)
    if horizontal:
        var x_origin := float(center.x - span) * CELL - CELL * 0.5
        var z_origin := float(center.y) * CELL - CELL * 1.5
        return AABB(Vector3(x_origin, level - CELL * 0.1, z_origin), Vector3(float(span * 2 + 1) * CELL, CELL * 1.2, CELL * 3.0))
    var origin_x := float(center.x) * CELL - CELL * 1.5
    var origin_z := float(center.y - span) * CELL - CELL * 0.5
    return AABB(Vector3(origin_x, level - CELL * 0.1, origin_z), Vector3(CELL * 3.0, CELL * 1.2, float(span * 2 + 1) * CELL))

func cell_key(cell: Vector2i) -> String:
    return "%d,%d" % [cell.x, cell.y]

func create_npc_body(npc_name: String, kind := "npc") -> CharacterBody3D:
    ensure_components()
    var body := NpcAgentScene.instantiate() as CharacterBody3D
    if body == null:
        body = NpcAgentScript.new() as CharacterBody3D
    body.name = npc_name
    body.collision_layer = NpcConstantsScript.COLLISION_NPC_BODY
    body.collision_mask = NpcConstantsScript.COLLISION_NPC_BODY_MASK
    body.set_meta("kind", kind)
    body.set_meta("npc_owned_by_system", true)
    body.set_meta("npc_agent_body", true)
    return body

func safe_place_npc(body: Node3D, position: Vector3, profile = null, reason := "spawn") -> Dictionary:
    ensure_components()
    var character_body := body as CharacterBody3D
    if character_body == null or safe_placement_service == null:
        return { "ok": false, "position": position, "reason": "missing_character_body" }
    var result: Dictionary = safe_placement_service.place_spawn(character_body, position, profile, reason)
    if autonomy_system != null:
        var telemetry = autonomy_system.get("telemetry")
        if telemetry != null:
            telemetry.increment(&"safe_placement_attempts")
            if bool(result.get("ok", false)):
                telemetry.increment(&"safe_placement_success")
            else:
                telemetry.increment(&"safe_placement_rejected")
    return result

func weapon_for_profile(profile: Dictionary, role: String, can_fight: bool) -> String:
    return NpcProfileRulesScript.weapon_for_profile(profile, role, can_fight)

func job_for_role(role: String, can_fight: bool) -> String:
    return NpcProfileRulesScript.job_for_role(role, can_fight)

func resource_for_job(job: String) -> String:
    return NpcProfileRulesScript.resource_for_job(job)

func spawn_generic_town_npcs() -> void:
    if main == null or main.structure_system == null or not main.structure_system.has_method("town_home_records_snapshot"):
        return
    var current_frame := Engine.get_process_frames()
    if main.structure_system.has_method("town_home_records_source_revision"):
        var source_revision := int(main.structure_system.town_home_records_source_revision())
        if source_revision == last_spawn_scan_revision: return
        last_spawn_scan_revision = source_revision
    elif last_spawn_scan_frame >= 0 and current_frame-last_spawn_scan_frame<30:
        return
    last_spawn_scan_frame = current_frame
    var records_by_town: Dictionary = main.structure_system.town_home_records_snapshot()
    for town_key_variant in records_by_town.keys():
        var town_key := String(town_key_variant)
        if town_key == "" or spawned_town_keys.has(town_key):
            continue
        var records_value = records_by_town[town_key]
        if not (records_value is Array):
            continue
        var records: Array = records_value
        if records.is_empty():
            continue
        if town_population_is_claimed(town_key):
            spawned_town_keys[town_key] = true
            continue
        for i in range(records.size()):
            spawn_town_npc(records[i], i)
        prebake_town_navmesh(records)
        spawned_town_keys[town_key] = true

func prebake_town_navmesh(records: Array) -> void:
    # Bake the static town (footprint + forager roam envelope) before the NPCs
    # start scheduling so route planning finds ready nav data instead of
    # spending the day window queued behind the per-frame tile publish budget.
    if pathing == null or not pathing.has_method("prebake_town") or records.is_empty():
        return
    var first: Dictionary = records[0] if records[0] is Dictionary else {}
    var center: Vector2i = first.get("townCenter", Vector2i.ZERO)
    var town_radius := int(first.get("townRadius", 18))
    # Forager roam envelope extends ~24 cells past the town; add margin so
    # perimeter routes and departures are pre-baked too.
    var prebake_radius := town_radius + 30
    var summary: Dictionary = pathing.prebake_town(center, prebake_radius)
    var monitor = main.get("runtime_perf_monitor") if main != null else null
    if monitor != null and monitor.has_method("increment_counter"):
        monitor.increment_counter("navmesh_town_prebake_published", int(summary.get("published", 0)))
        monitor.increment_counter("navmesh_town_prebake_tiles", int(summary.get("tiles", 0)))

func claim_town_population(town_key: String, owner_id: String) -> Dictionary:
    var normalized_town_key := town_key.strip_edges()
    var normalized_owner_id := owner_id.strip_edges()
    if normalized_town_key == "" or normalized_owner_id == "":
        return {"ok": false, "reason": "invalid_town_population_claim"}
    var existing_owner := String(town_population_claims.get(normalized_town_key, ""))
    if existing_owner != "" and existing_owner != normalized_owner_id:
        return {
            "ok": false,
            "reason": "town_population_already_claimed",
            "townKey": normalized_town_key,
            "ownerId": existing_owner
        }
    town_population_claims[normalized_town_key] = normalized_owner_id
    return {"ok": true, "townKey": normalized_town_key, "ownerId": normalized_owner_id}

func town_population_is_claimed(town_key: String) -> bool:
    return town_population_claims.has(town_key.strip_edges())

func spawn_town_npc(record: Dictionary, index: int) -> CharacterBody3D:
    ensure_components()
    var roles := ["Guard", "Farmer", "Forager", "Carpenter", "Mason", "Trader"]
    var names := ["Iven", "Mara", "Pell", "Ona", "Brin", "Tess", "Cal"]
    var role: String = String(roles[index % roles.size()])
    var can_fight: bool = role.to_lower().find("guard") >= 0
    var name: String = String(names[index % names.size()])
    var body := create_npc_body("TownNPC_%s_%d" % [String(record.get("townKey", "town")).replace(",", "_"), index], "npc")
    body.set_meta("npc_name", name)
    body.set_meta("npc_role", role)
    var level := float(record.get("level", 16.0))
    var porch_cell: Vector2i = record.get("porchCell", record.get("homeCell", Vector2i.ZERO))
    var guard_cell: Vector2i = record.get("guardCell", porch_cell)
    if can_fight:
        var guard_slot := int(floori(float(index) / float(maxi(1, roles.size()))))
        guard_cell = generated_town_guard_cell(record, guard_slot, guard_cell)
    add_npc_visual(body, visual_factory.body_material(index), visual_factory.accent_material(index), name, role, can_fight)
    add_npc_collider(body)
    npc_root.add_child(body)
    safe_place_npc(body, cell_to_position(porch_cell, level), CharacterMotorProfileScript.npc_default(), "spawn")
    register_npc(body, {
        "id": String(record.get("id", body.name)),
        "name": name,
        "role": role,
        "townKey": String(record.get("townKey", "")),
        "townCenter": record.get("townCenter", Vector2i.ZERO),
        "townRadius": int(record.get("townRadius", 18)),
        "level": level,
        "homeKey": int(record.get("homeKey", record.get("buildingIndex", -1))),
        "homeStableId": String(record.get("stableId", "")),
        "homeCell": record.get("homeCell", Vector2i.ZERO),
        "porchCell": porch_cell,
        "doorCell": record.get("doorCell", porch_cell),
        "doorPortalId": String(record.get("doorPortalId", "")),
        "interiorLandingCell": record.get("interiorLandingCell", record.get("homeCell", Vector2i.ZERO)),
        "homeRouteCells": record.get("homeRouteCells", []),
        "interiorMinCell": record.get("interiorMinCell", record.get("homeCell", Vector2i.ZERO)),
        "interiorMaxCell": record.get("interiorMaxCell", record.get("homeCell", Vector2i.ZERO)),
        "guardCell": guard_cell,
        "canFight": can_fight,
        "nightGuard": role.to_lower().find("guard") >= 0
    })
    return body

func update_npc_home_record(actor_id, record: Dictionary) -> bool:
    if record.is_empty():
        return false
    var entry := npc_entry_for_actor(actor_id)
    if entry.is_empty():
        return false
    var body := entry.get("body") as Node3D
    var level := float(record.get("level", entry.get("level", body.global_position.y if body != null else 16.0)))
    var home_cell: Vector2i = record.get("homeCell", entry.get("homeCell", Vector2i.ZERO))
    var porch_cell: Vector2i = record.get("porchCell", entry.get("porchCell", home_cell))
    var door_cell: Vector2i = record.get("doorCell", entry.get("doorCell", porch_cell))
    var interior_landing_cell: Vector2i = record.get("interiorLandingCell", record.get("homeCell", home_cell))
    var route_cells: Array = record.get("homeRouteCells", []) if record.get("homeRouteCells", []) is Array else []
    var route_positions: Array = []
    if route_cells.is_empty():
        route_cells = [porch_cell, door_cell, interior_landing_cell, home_cell]
    for route_cell_value in route_cells:
        if not (route_cell_value is Vector2i):
            continue
        var route_cell: Vector2i = route_cell_value
        if not route_positions.is_empty() and flat_cell_for_position(route_positions[route_positions.size() - 1]) == route_cell:
            continue
        route_positions.append(cell_to_position(route_cell, level))
    if route_positions.is_empty():
        route_positions = [cell_to_position(porch_cell, level), cell_to_position(home_cell, level)]
    entry["level"] = level
    entry["homeCell"] = home_cell
    entry["porchCell"] = porch_cell
    entry["doorCell"] = door_cell
    entry["interiorLandingCell"] = interior_landing_cell
    entry["homePosition"] = cell_to_position(home_cell, level)
    entry["porchPosition"] = cell_to_position(porch_cell, level)
    entry["homeRouteCells"] = route_cells
    entry["homeRoutePositions"] = route_positions
    entry["interiorMinCell"] = record.get("interiorMinCell", entry.get("interiorMinCell", home_cell))
    entry["interiorMaxCell"] = record.get("interiorMaxCell", entry.get("interiorMaxCell", home_cell))
    if record.has("guardCell") and not bool(entry.get("nightGuard", false)):
        entry["guardCell"] = record.get("guardCell", entry.get("guardCell", porch_cell))
        entry["guardPosition"] = cell_to_position(entry.get("guardCell", porch_cell), level)
    if body != null and is_instance_valid(body):
        apply_npc_metadata(body, entry, home_cell, porch_cell, entry.get("guardCell", porch_cell), String(entry.get("job", "")))
    entry["homeRouteIndex"] = 0
    entry.erase("homeActiveTargetCell")
    entry["pathWaypoints"] = []
    entry["routeCells"] = []
    entry["routeActions"] = {}
    entry["routeForceReplan"] = true
    entry.erase("routeKey")
    entry.erase("routePendingKey")
    entry.erase("routePendingRetryFrame")
    entry.erase("routePendingSnapshotRevision")
    return true

func generated_town_guard_cell(record: Dictionary, guard_slot: int, fallback: Vector2i) -> Vector2i:
    var center: Vector2i = record.get("townCenter", fallback)
    var radius := int(record.get("townRadius", 0))
    if radius < 12:
        return fallback
    var perimeter := maxi(1, radius - 3)
    var offset := fallback - center
    if offset == Vector2i.ZERO:
        var side := posmod(guard_slot, 4)
        if side == 0:
            offset = Vector2i(0, -1)
        elif side == 1:
            offset = Vector2i(1, 0)
        elif side == 2:
            offset = Vector2i(0, 1)
        else:
            offset = Vector2i(-1, 0)
    if absi(offset.x) >= absi(offset.y):
        var sx := 1 if offset.x >= 0 else -1
        return Vector2i(center.x + sx * perimeter, clampi(center.y + offset.y, center.y - perimeter, center.y + perimeter))
    var sz := 1 if offset.y >= 0 else -1
    return Vector2i(clampi(center.x + offset.x, center.x - perimeter, center.x + perimeter), center.y + sz * perimeter)

func update_npcs(delta: float, day_factor: float) -> void:
    if main == null:
        return
    var monitor = performance_monitor()
    var setup_start: int = monitor.begin_section("npc_update_setup") if monitor != null else 0
    ensure_components()
    spawn_generic_town_npcs()
    if combat != null:
        combat.update_tracers(delta)
    if monitor != null:
        monitor.end_section("npc_update_setup", setup_start)
    var door_start: int = monitor.begin_section("door_policy_update") if monitor != null else Time.get_ticks_usec()
    update_door_policies(delta)
    if monitor != null:
        monitor.end_section("door_policy_update", door_start)
    if pathing != null and pathing.has_method("begin_frame"):
        var pathing_frame_start: int = monitor.begin_section("npc_pathing_begin_frame") if monitor != null else 0
        var allow_publication := bool(main.get("npc_navigation_publication_permitted")) \
            if main != null else true
        pathing.begin_frame(allow_publication)
        if monitor != null:
            monitor.end_section("npc_pathing_begin_frame", pathing_frame_start)
    if autonomy_system != null and autonomy_system.has_method("begin_update_frame"):
        autonomy_system.begin_update_frame()
    var night_factor := clampf((1.0 - day_factor - 0.30) / 0.55, 0.0, 1.0)
    var update_entries := npcs.duplicate()
    var active_entries: Array[Dictionary] = []
    var lod_start: int = monitor.begin_section("npc_lod_sweep") if monitor != null else 0
    for entry_value in update_entries:
        var entry: Dictionary = entry_value
        var body := entry.get("body") as Node3D
        if body == null or not is_instance_valid(body):
            npcs.erase(entry)
            continue
        var lod_state := "active"
        if autonomy_system != null and autonomy_system.has_method("update_simulation_lod"):
            var observer_position := Vector3.INF
            if main != null and main.get("player") is Node3D:
                observer_position = (main.get("player") as Node3D).global_position
            var lod_result: Dictionary = autonomy_system.update_simulation_lod(entry, delta, observer_position, {
                "allowStationaryAbstract": true
            })
            lod_state = String(lod_result.get("state", "active"))
        if lod_state == "abstract":
            continue
        active_entries.append(entry)
    if monitor != null:
        monitor.end_section("npc_lod_sweep", lod_start)
    var update_count := active_entries.size()
    # Prefetch is retained demand, not per-actor movement. Service one actor per
    # frame so a shared route change cannot make every NPC rescan and requeue its
    # boundary tiles in the same gameplay frame.
    if update_count>0 and autonomy_system != null and autonomy_system.has_method("prefetch_for_entry"):
        var prefetch_start: int = monitor.begin_section("npc_navigation_prefetch") if monitor != null else 0
        npc_prefetch_cursor = posmod(npc_prefetch_cursor,update_count)
        autonomy_system.prefetch_for_entry(active_entries[npc_prefetch_cursor])
        npc_prefetch_cursor = (npc_prefetch_cursor+1)%update_count
        if monitor != null:
            monitor.end_section("npc_navigation_prefetch", prefetch_start)
    var budget := update_count
    if update_count > 24:
        budget = 4
    elif update_count > 16:
        budget = 6
    if update_count <= 0:
        return
    var npc_frame_start := Time.get_ticks_usec()
    var brain_start: int = monitor.begin_section("npc_brain_updates") if monitor != null else 0
    npc_update_cursor = npc_update_cursor % update_count
    npc_update_active = true
    var scanned := 0
    var processed := 0
    var brain_processed_entries: Array = []
    var immediate_brain_candidates: Array = []
    for entry in active_entries:
        if npc_brain_requires_immediate_update(entry, night_factor):
            immediate_brain_candidates.append(entry)
    if not immediate_brain_candidates.is_empty():
        budget = maxi(budget, mini(immediate_brain_candidates.size(), 12))
    var immediate_brain_entries: Array = immediate_brain_candidates
    if autonomy_system != null and autonomy_system.has_method("select_urgent_brain_entries"):
        immediate_brain_entries = autonomy_system.select_urgent_brain_entries(immediate_brain_candidates, budget)
    for entry in immediate_brain_entries:
        if processed >= budget:
            break
        var body := entry.get("body") as Node3D
        if body == null or not is_instance_valid(body):
            npcs.erase(entry)
            continue
        entry["npc_lod_brain_due"] = true
        entry["_lodGateApplied"] = true
        update_npc(entry, delta, night_factor)
        entry.erase("_lodGateApplied")
        brain_processed_entries.append(entry)
        processed += 1
    while scanned < update_count and processed < budget:
        if processed > 0 and npc_elapsed_ms(npc_frame_start) >= NPC_BRAIN_FRAME_BUDGET_MS:
            break
        var entry: Dictionary = active_entries[(npc_update_cursor + scanned) % update_count]
        scanned += 1
        if brain_processed_entries.has(entry):
            continue
        var body := entry.get("body") as Node3D
        if body == null or not is_instance_valid(body):
            npcs.erase(entry)
            continue
        entry["_lodGateApplied"] = true
        update_npc(entry, delta, night_factor)
        entry.erase("_lodGateApplied")
        brain_processed_entries.append(entry)
        processed += 1
    npc_update_cursor = (npc_update_cursor + max(1, scanned)) % max(1, npcs.size())
    if autonomy_system != null and autonomy_system.has_method("record_brain_budget_skipped"):
        for entry in active_entries:
            if not brain_processed_entries.has(entry):
                autonomy_system.record_brain_budget_skipped(entry, "budget_cursor")
    if monitor != null:
        monitor.end_section("npc_brain_updates", brain_start)
    var motion_start: int = monitor.begin_section("npc_motion_and_visuals") if monitor != null else 0
    var motion_entries := select_motion_entries(active_entries, delta)
    var motion_frame_start := Time.get_ticks_usec()
    var motion_processed := 0
    for entry in active_entries:
        if autonomy_system != null and autonomy_system.has_method("physics_route_service_owns_motion") and bool(autonomy_system.physics_route_service_owns_motion(entry)):
            if autonomy_system.has_method("record_motion_skipped"):
                autonomy_system.record_motion_skipped(entry, "physics_route_service")
            update_npc_visual_state(entry, delta)
            continue
        if not motion_entries.has(entry):
            if autonomy_system != null and autonomy_system.has_method("record_motion_skipped"):
                autonomy_system.record_motion_skipped(entry, "motion_budget")
            update_npc_visual_state(entry, delta)
            continue
        if motion_processed > 0 and not npc_motion_requires_immediate_update(entry) and npc_elapsed_ms(motion_frame_start) >= NPC_MOTION_FRAME_BUDGET_MS:
            if autonomy_system != null and autonomy_system.has_method("record_motion_skipped"):
                autonomy_system.record_motion_skipped(entry, "frame_time_budget")
            update_npc_visual_state(entry, delta)
            continue
        if autonomy_system != null and autonomy_system.has_method("advance_npc_motion"):
            var accumulated_delta := float(entry.get("npcMotionAccumulatedDelta", delta))
            var motion_delta := minf(accumulated_delta, delta * NPC_MOTION_ACCUMULATED_DELTA_CAP)
            entry["npcMotionAccumulatedDelta"] = maxf(0.0, accumulated_delta - motion_delta)
            autonomy_system.advance_npc_motion(entry, motion_delta, night_factor)
        motion_processed += 1
        update_npc_visual_state(entry, delta)
    if monitor != null:
        monitor.end_section("npc_motion_and_visuals", motion_start)
    npc_update_active = false

func npc_elapsed_ms(start_usec: int) -> float:
    return float(Time.get_ticks_usec() - start_usec) / 1000.0

func select_motion_entries(active_entries: Array, delta: float) -> Array:
    var selected: Array = []
    var budgeted: Array = []
    var motion_budget: int = npc_motion_budget(active_entries.size())
    for entry in active_entries:
        entry["npcMotionAccumulatedDelta"] = minf(
            float(entry.get("npcMotionAccumulatedDelta", 0.0)) + delta,
            delta * NPC_MOTION_ACCUMULATED_DELTA_CAP
        )
        if npc_motion_requires_immediate_update(entry):
            selected.append(entry)
        else:
            budgeted.append(entry)
    var remaining_budget: int = maxi(0, motion_budget - selected.size())
    if remaining_budget > 0 and not budgeted.is_empty():
        npc_motion_cursor = npc_motion_cursor % budgeted.size()
        var scanned: int = 0
        var processed: int = 0
        while scanned < budgeted.size() and processed < remaining_budget:
            selected.append(budgeted[(npc_motion_cursor + scanned) % budgeted.size()])
            scanned += 1
            processed += 1
        npc_motion_cursor = (npc_motion_cursor + max(1, scanned)) % max(1, budgeted.size())
    var monitor = performance_monitor()
    if monitor != null:
        monitor.increment_counter("npc_motion_budget_selected", selected.size())
        monitor.increment_counter("npc_motion_budget_skipped", max(0, active_entries.size() - selected.size()))
    return selected

func npc_motion_budget(active_count: int) -> int:
    if active_count > NPC_MOTION_BUDGET_VERY_CROWDED_THRESHOLD:
        return NPC_MOTION_BUDGET_VERY_CROWDED
    if active_count > NPC_MOTION_BUDGET_CROWDED_THRESHOLD:
        return NPC_MOTION_BUDGET_CROWDED
    if active_count > NPC_MOTION_BUDGET_ACTIVE_THRESHOLD:
        return NPC_MOTION_BUDGET_ACTIVE
    return active_count

func npc_brain_requires_immediate_update(entry: Dictionary, night_factor: float) -> bool:
    var scripted_order_value = entry.get("scriptedOrder", {})
    if scripted_order_value is Dictionary:
        var scripted_order: Dictionary = scripted_order_value
        var order_state := String(scripted_order.get("state", ""))
        if bool(scripted_order.get("usesRouteStack", false)) and order_state in ["PENDING", "ACTIVE"]:
            return true
    if npc_brain_starvation_recovery_required(entry):
        return true
    if npc_day_worker_departure_required(entry, night_factor):
        return true
    if not npc_home_return_window_active(night_factor):
        return false
    if bool(entry.get("nightGuard", false)):
        return false
    if bool(entry.get("insideHome", false)):
        return false
    return true

func npc_brain_starvation_recovery_required(entry: Dictionary) -> bool:
    if int(entry.get("npc_brain_budget_skip_streak", 0)) < NPC_BRAIN_BUDGET_SKIP_STREAK_URGENT:
        return false
    var job := String(entry.get("job", ""))
    if not (job in ["guard", "forage", "wood", "stone", "trade"]):
        return false
    if String(entry.get("simulationLod", "active")) == "abstract":
        return false
    return true

func npc_day_worker_departure_required(entry: Dictionary, night_factor := 0.0) -> bool:
    if npc_home_return_window_active(night_factor):
        return false
    if bool(entry.get("nightGuard", false)):
        return false
    if not bool(entry.get("insideHome", false)):
        return false
    var job := String(entry.get("job", ""))
    if not (job in ["wood", "stone", "trade", "forage"]):
        return false
    var phase := String(entry.get("jobPhase", "idle"))
    return phase in ["idle", "searching", "outbound", "returning"]

func npc_home_return_window_active(night_factor: float) -> bool:
    if night_factor > 0.05:
        return true
    if main == null:
        return false
    var time_value = main.get("time_of_day")
    if not (typeof(time_value) == TYPE_FLOAT or typeof(time_value) == TYPE_INT):
        return false
    var clock_phase := fposmod(float(time_value) + NPC_CLOCK_DISPLAY_OFFSET, 1.0)
    return clock_phase >= NPC_DUSK_START_CLOCK or clock_phase < NPC_DAWN_START_CLOCK

func npc_motion_requires_immediate_update(entry: Dictionary) -> bool:
    # A follower holding a ready collision-backed route lease with waypoints left
    # should advance every physics frame. Integrating along a validated corridor
    # is cheap; starving it behind the motion budget is what makes routing look
    # like a pathfinding failure even when a valid route exists.
    if npc_has_active_route_lease(entry):
        return true
    if int(entry.get("npc_motion_budget_skipped", 0)) >= NPC_MOTION_SKIPPED_STREAK_URGENT \
        and String(entry.get("routeStatus", "")) in ["moving", "pending", "waiting"]:
        return true
    if npc_day_worker_departure_required(entry):
        return true
    if npc_job_route_motion_required(entry):
        return true
    if npc_guard_motion_required(entry):
        return true
    var scripted_order_value = entry.get("scriptedOrder", {})
    if scripted_order_value is Dictionary:
        var scripted_order: Dictionary = scripted_order_value
        var order_state := String(scripted_order.get("state", ""))
        if bool(scripted_order.get("usesRouteStack", false)) and order_state in ["PENDING", "ACTIVE"]:
            return true
    if not bool(entry.get("insideHome", false)):
        if String(entry.get("activeGoalKind", "")) == String(NpcEnumsScript.GOAL_KIND_HOME):
            return true
        var active_goal_value = entry.get("activeMotionGoal", {})
        if active_goal_value is Dictionary and String((active_goal_value as Dictionary).get("goalKind", "")) == String(NpcEnumsScript.GOAL_KIND_HOME):
            return true
        if bool(entry.get("routeMovingHome", false)) and String(entry.get("routeStatus", "")) in ["moving", "pending", "waiting"]:
            return true
    if String(entry.get("activeDoorPortalId", "")) != "":
        return true
    if bool(entry.get("holdDoorOrder", false)):
        return true
    if String(entry.get("routeReason", "")) in ["active_door_forward_clearance", "portal_retreat", "yielding_retreat"]:
        return true
    return false

func npc_has_active_route_lease(entry: Dictionary) -> bool:
    var lease_value = entry.get("routeLease", {})
    if not (lease_value is Dictionary) or (lease_value as Dictionary).is_empty():
        return false
    if String((lease_value as Dictionary).get("state", "ready")) != String(NpcEnumsScript.ROUTE_AUTHORITY_READY):
        return false
    var waypoints = entry.get("pathWaypoints", [])
    return waypoints is Array and not (waypoints as Array).is_empty()

func npc_job_route_motion_required(entry: Dictionary) -> bool:
    var phase := String(entry.get("jobPhase", ""))
    if phase in ["outbound", "searching", "gathering", "returning", "stall"]:
        return true
    var job := String(entry.get("job", ""))
    if phase == "idle" and job in ["forage", "wood", "stone", "trade"]:
        var expected_goal := String(NpcEnumsScript.GOAL_KIND_FORAGE) if job == "forage" else String(NpcEnumsScript.GOAL_KIND_WORK)
        if String(entry.get("activeGoalKind", entry.get("goal", ""))) == expected_goal:
            return true
        var active_goal_value = entry.get("activeMotionGoal", {})
        if active_goal_value is Dictionary and String((active_goal_value as Dictionary).get("goalKind", "")) == expected_goal:
            return true
    var route_status := String(entry.get("routeStatus", ""))
    if not (route_status in ["moving", "pending", "waiting"]):
        return false
    var active_goal := String(entry.get("activeGoalKind", entry.get("goal", "")))
    if active_goal in [String(NpcEnumsScript.GOAL_KIND_FORAGE), String(NpcEnumsScript.GOAL_KIND_WORK)]:
        return true
    var active_goal_value = entry.get("activeMotionGoal", {})
    if active_goal_value is Dictionary:
        var motion_goal := String((active_goal_value as Dictionary).get("goalKind", ""))
        if motion_goal in [String(NpcEnumsScript.GOAL_KIND_FORAGE), String(NpcEnumsScript.GOAL_KIND_WORK)]:
            return true
    return false

func npc_guard_motion_required(entry: Dictionary) -> bool:
    var active_goal := String(entry.get("activeGoalKind", entry.get("goal", "")))
    var motion_goal := ""
    var active_goal_value = entry.get("activeMotionGoal", {})
    if active_goal_value is Dictionary:
        motion_goal = String((active_goal_value as Dictionary).get("goalKind", ""))
    if not (bool(entry.get("nightGuard", false)) or active_goal == String(NpcEnumsScript.GOAL_KIND_GUARD) or motion_goal == String(NpcEnumsScript.GOAL_KIND_GUARD)):
        return false
    if String(entry.get("routeStatus", "")) in ["moving", "pending", "waiting"]:
        return true
    if not (active_goal == String(NpcEnumsScript.GOAL_KIND_GUARD) or motion_goal == String(NpcEnumsScript.GOAL_KIND_GUARD)):
        return false
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return true
    var target_value = entry.get("guardTargetCache", entry.get("guardPosition", body.global_position))
    if target_value is Vector3:
        return body.global_position.distance_to(target_value) > CELL * 1.15
    return true

func update_npc(entry: Dictionary, delta: float, night_factor: float) -> void:
    var standalone_update := not npc_update_active
    if standalone_update and pathing != null and pathing.has_method("begin_frame"):
        pathing.begin_frame()
    if not npc_update_active and autonomy_system != null and autonomy_system.has_method("begin_update_frame"):
        autonomy_system.begin_update_frame()
    if standalone_update:
        entry["npc_lod_brain_due"] = true
    elif not bool(entry.get("_lodGateApplied", false)):
        entry["npc_lod_brain_due"] = true
    if autonomy_system != null:
        var monitor = performance_monitor()
        var autonomy_start: int = monitor.begin_section("NpcAutonomySystem") if monitor != null else Time.get_ticks_usec()
        if standalone_update:
            npc_update_active = true
            entry["_standaloneNpcUpdateFrame"] = Engine.get_process_frames()
        autonomy_system.update_npc(entry, delta, night_factor)
        if standalone_update and autonomy_system.has_method("advance_npc_motion"):
            autonomy_system.advance_npc_motion(entry, delta, night_factor)
        if standalone_update:
            entry.erase("_standaloneNpcUpdateFrame")
            npc_update_active = false
        if monitor != null:
            monitor.end_section("NpcAutonomySystem", autonomy_start)

func npc_movement_is_paused(entry: Dictionary, body: Node3D) -> bool:
    if bool(body.get_meta("npc_dialogue_focused", false)):
        face_position(body, body.get_meta("npc_dialogue_face_position", body.global_position))
        entry["lastMoveDistance"] = 0.0
        return true
    return false

func update_scripted_npc(entry: Dictionary, body: Node3D, delta: float) -> void:
    var scripted_target: Vector3 = body.get_meta("npc_scripted_target", body.global_position)
    var allow_outside := bool(body.get_meta("npc_scripted_allow_outside", true))
    var arrival_radius := float(body.get_meta("npc_scripted_arrival_radius", CELL * 0.45))
    var speed_mode := set_npc_speed_mode(entry, body.get_meta("npc_scripted_speed_mode", entry.get("npcSpeedMode", NPC_SPEED_MODE_WALKING)), "scripted_go_to")
    var movement_speed := npc_speed_for_mode(entry, speed_mode)
    var scripted_kind := String(body.get_meta("npc_scripted_order_kind", ""))
    var moving_home := scripted_kind == "go_home" or String(entry.get("activeGoalKind", "")) == "home"
    scripted_order_result(entry, "ACTIVE", scripted_kind if scripted_kind != "" else "go_to", "")
    entry["lastMoveDistance"] = move_npc(entry, scripted_target, movement_speed * delta, moving_home, allow_outside, delta)
    if float(entry.get("lastMoveDistance", 0.0)) > 0.001:
        entry.erase("scriptedRouteBlockedTime")
    if body.global_position.distance_to(scripted_target) <= arrival_radius:
        body.set_meta("npc_scripted_arrived", true)
        entry.erase("scriptedRouteBlockedTime")
        scripted_order_result(entry, "ARRIVED", "target_reached", "")
        if not bool(body.get_meta("npc_scripted_hold_on_arrival", true)):
            body.remove_meta("npc_scripted_target")
            entry.erase("activeMotionGoal")
            entry.erase("activeMotionPlan")
    elif String(entry.get("routeStatus", "")) in ["blocked", "unreachable"]:
        var route_reason := String(entry.get("routeReason", ""))
        if scripted_route_failure_retryable(route_reason):
            entry["scriptedRouteBlockedTime"] = float(entry.get("scriptedRouteBlockedTime", 0.0)) + delta
            entry["routeForceReplan"] = true
            scripted_order_result(entry, "ACTIVE", "route_retry", route_reason)
        else:
            scripted_order_result(entry, "FAILED_BLOCKED", "route_blocked", route_reason)

func scripted_route_failure_retryable(reason: String) -> bool:
    return reason in [
        "route_budget",
        "navmesh_tile_budget",
        "endpoint_not_server_walkable",
        "no_start_server_walkable",
        "no_target_server_walkable",
        "path_endpoint_mismatch",
        "path_crosses_static_collision",
        "target_blocked",
        "no_route",
        "empty_route",
        "blocked_dynamic",
        "yielding",
        "local_blocked",
        "static_or_dynamic_collision"
    ]

func update_fighter_target(entry: Dictionary, body: Node3D, target_hostile, weapon_id: String) -> Vector3:
    entry["insideHome"] = false
    body.set_meta("npc_inside_home", false)
    var melee := npc_weapon_is_melee(weapon_id)
    var hostile := valid_hostile_node(target_hostile)
    if hostile == null:
        return choose_guard_target(entry, null, melee)
    var target: Vector3 = choose_guard_target(entry, hostile, melee)
    if melee:
        var flat_distance := Vector2(hostile.global_position.x - body.global_position.x, hostile.global_position.z - body.global_position.z).length()
        if flat_distance <= CELL * 1.72:
            strike_hostile(entry, hostile)
    else:
        fire_at_hostile(entry, hostile)
    return target

func face_hostile_if_needed(body: Node3D, target_hostile) -> void:
    var hostile := valid_hostile_node(target_hostile)
    if hostile == null or body.global_position.distance_to(hostile.global_position) <= 0.1:
        return
    var to_target := hostile.global_position - body.global_position
    to_target.y = 0.0
    if to_target.length_squared() > 0.001:
        body.rotation.y = atan2(to_target.x, to_target.z)

func valid_hostile_node(value) -> Node3D:
    if value == null or not is_instance_valid(value):
        return null
    return value as Node3D

func update_npc_visual_state(entry: Dictionary, delta: float) -> void:
    entry["detourTimer"] = maxf(0.0, float(entry.get("detourTimer", 0.0)) - delta)
    if float(entry.get("detourTimer", 0.0)) <= 0.0:
        entry["detourTarget"] = NO_DETOUR
    entry["pathRefreshTimer"] = maxf(0.0, float(entry.get("pathRefreshTimer", 0.0)) - delta)
    entry["jumpIntentTime"] = maxf(0.0, float(entry.get("jumpIntentTime", 0.0)) - delta)
    var body := entry.get("body") as Node
    if body and float(entry.get("jumpIntentTime", 0.0)) <= 0.0:
        body.set_meta("npc_jump_intent", false)
    update_name_label_visibility(entry)
    visual_factory.update_held_animation(entry, delta)

func update_npc_needs(entry: Dictionary, delta: float, night_factor: float) -> void:
    var max_hunger := float(entry.get("maxHunger", 100.0))
    var drain := 0.020 if night_factor <= 0.45 else 0.010
    if String(entry.get("job", "")) == "forage":
        drain *= 1.35
    var hunger := clampf(float(entry.get("hunger", max_hunger)) - delta * drain, 0.0, max_hunger)
    entry["hunger"] = hunger
    var body := entry.get("body") as Node
    if body:
        body.set_meta("npc_hunger", hunger)
    if hunger < max_hunger * 0.55:
        var consumed_food := consume_forage_food(entry)
        if bool(consumed_food.get("ok", false)):
            var item_id := String(consumed_food.get("itemId", ""))
            hunger = minf(max_hunger, hunger + float(consumed_food.get("food", 0)))
            entry["hunger"] = hunger
            npc_food_eaten += 1
            if body:
                body.set_meta("npc_hunger", hunger)
            last_message = "%s ate %s" % [String(entry.get("name", "NPC")), ItemCatalogScript.label(item_id)]

func update_name_label_visibility(entry: Dictionary) -> void:
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return
    var label := body.get_node_or_null("NpcNameLabel") as Label3D
    if label == null:
        return
    var show := bool(body.get_meta("npc_dialogue_focused", false))
    var player_body := main.get("player") as Node3D if main != null else null
    if player_body != null:
        var distance := body.global_position.distance_to(player_body.global_position)
        if distance <= CELL * 5.25:
            show = true
        elif npc_is_targeted_by_camera(body, player_body, distance):
            show = true
    label.visible = show
    label.no_depth_test = false

func npc_is_targeted_by_camera(body: Node3D, player_body: Node, distance: float) -> bool:
    if distance > CELL * 10.0 or player_body == null:
        return false
    var camera := player_body.get("camera") as Camera3D
    if camera == null:
        return false
    var to_label := (body.global_position + Vector3(0.0, 1.20, 0.0)) - camera.global_position
    if to_label.length_squared() <= 0.001:
        return true
    var forward := -camera.global_transform.basis.z.normalized()
    return forward.dot(to_label.normalized()) > 0.982

func play_npc_use(entry: Dictionary, action: String) -> void:
    entry["useAction"] = action
    entry["useDuration"] = 0.34 if action == "shoot" else 0.28
    entry["useAnim"] = float(entry["useDuration"])
    npc_use_animations += 1

func face_position(body: Node3D, target: Vector3) -> void:
    if body == null:
        return
    var to_target := target - body.global_position
    to_target.y = 0.0
    if to_target.length_squared() > 0.001:
        body.rotation.y = atan2(to_target.x, to_target.z)

func set_npc_goal(entry: Dictionary, goal: String) -> void:
    entry["goal"] = goal
    var body := entry.get("body") as Node
    if body:
        body.set_meta("npc_goal", goal)

func clear_home_route_terminal(entry: Dictionary) -> void:
    if not (String(entry.get("routeReason", "")) in ["home_route_terminal_outside", "porch_not_inside", "threshold_not_inside"]):
        return
    NpcRouteStateStoreScript.write_status(entry, "idle", "", "NpcSystem.clear_home_route_terminal")
    entry["homeBlocked"] = false
    entry["routeFallbackCell"] = Vector2i(999999, 999999)
    entry["routeForceReplan"] = true
    var body := entry.get("body") as Node
    if body:
        body.set_meta("npc_home_blocked", false)

func npc_inventory_count(entry: Dictionary, item_id: String) -> int:
    var personal_inventory: Dictionary = entry.get("personalInventory", {})
    return int(personal_inventory.get(item_id, 0))

func npc_inventory_add(entry: Dictionary, item_id: String, amount: int) -> void:
    if item_id == "" or amount == 0:
        return
    var personal_inventory: Dictionary = entry.get("personalInventory", {})
    var new_count := maxi(0, int(personal_inventory.get(item_id, 0)) + amount)
    if new_count <= 0:
        personal_inventory.erase(item_id)
    else:
        personal_inventory[item_id] = new_count
    entry["personalInventory"] = personal_inventory
    var body := entry.get("body") as Node
    if body:
        body.set_meta("npc_inventory", personal_inventory.duplicate())

func forage_food_item_ids() -> Array[String]:
    return ItemCatalogScript.forage_food_ids()

func is_forage_food_item(item_id: String) -> bool:
    return ItemCatalogScript.is_forage_food(item_id)

func forage_food_value(item_id: String) -> int:
    return ItemCatalogScript.food_value(item_id) if is_forage_food_item(item_id) else 0

func consume_forage_food(entry: Dictionary, preferred_item_id := "") -> Dictionary:
    var inventory: Dictionary = entry.get("personalInventory", {})
    if preferred_item_id != "" and is_forage_food_item(preferred_item_id) and int(inventory.get(preferred_item_id, 0)) > 0:
        npc_inventory_add(entry, preferred_item_id, -1)
        return { "ok": true, "itemId": preferred_item_id, "food": forage_food_value(preferred_item_id) }
    var candidates: Array[String] = []
    for item_id in forage_food_item_ids():
        if int(inventory.get(item_id, 0)) > 0:
            candidates.append(item_id)
    if candidates.is_empty():
        return { "ok": false, "reason": "no_forage_food" }
    candidates.sort_custom(func(a: String, b: String) -> bool:
        var a_food := forage_food_value(a)
        var b_food := forage_food_value(b)
        if a_food != b_food:
            return a_food > b_food
        return a < b
    )
    var item_id := candidates[0]
    npc_inventory_add(entry, item_id, -1)
    return { "ok": true, "itemId": item_id, "food": forage_food_value(item_id) }

func find_forage_target(entry: Dictionary) -> Node3D:
    var body := entry.get("body") as Node3D
    if body == null:
        return null
    var cached_target := cached_resource_target_for_entry(entry, "forage")
    if cached_target != null:
        return cached_target
    var monitor = performance_monitor()
    var scan_start: int = monitor.begin_section("job_forage_scan") if monitor != null else Time.get_ticks_usec()
    var candidates: Array[Node3D] = indexed_resource_candidates(entry, ["forage_source"], {
        "limit": FORAGE_SCAN_CANDIDATE_LIMIT,
        "unreachableMetaKey": forager_unreachable_meta_key(entry),
        "drops": forage_food_item_ids(),
        "outsideTown": true,
        "workAreaOnly": true,
        "chunkRadius": 2,
        "cacheFrames": 30
    })
    candidates = filter_forage_candidates(entry, candidates)
    var scanned_nodes := 0
    if candidates.is_empty() and allow_resource_scan_fallback():
        var remaining_scan_nodes := FORAGE_SCAN_NODE_LIMIT
        for root in [main.get("prop_root"), main.get("chunk_root")]:
            remaining_scan_nodes = collect_forage_targets_in_tree(root as Node, entry, body.global_position, candidates, remaining_scan_nodes, FORAGE_SCAN_CANDIDATE_LIMIT)
            if remaining_scan_nodes <= 0 or candidates.size() >= FORAGE_SCAN_CANDIDATE_LIMIT:
                break
        scanned_nodes = FORAGE_SCAN_NODE_LIMIT - remaining_scan_nodes
    if monitor != null:
        monitor.increment_counter("forage_scan_nodes", scanned_nodes)
        monitor.end_section("job_forage_scan", scan_start)
    var chosen: Node3D = null
    if pathing != null and pathing.has_method("choose_forage_target"):
        chosen = pathing.choose_forage_target(entry, candidates)
    else:
        chosen = candidates[0] if not candidates.is_empty() else null
    remember_cached_resource_target(entry, "forage", chosen)
    return chosen

func filter_forage_candidates(entry: Dictionary, candidates: Array[Node3D]) -> Array[Node3D]:
    var filtered: Array[Node3D] = []
    for candidate in candidates:
        if is_valid_forage_node(candidate, entry):
            filtered.append(candidate)
    return filtered

func collect_forage_targets_in_tree(root: Node, entry: Dictionary, origin: Vector3, candidates: Array[Node3D], max_nodes: int, max_candidates: int) -> int:
    if root == null or max_nodes <= 0 or candidates.size() >= max_candidates:
        return max_nodes
    var stack: Array[Node] = [root]
    var scanned := 0
    while not stack.is_empty() and scanned < max_nodes and candidates.size() < max_candidates:
        var node := stack.pop_back() as Node
        scanned += 1
        if node == null:
            continue
        if node is Node3D and is_valid_forage_node(node as Node3D, entry):
            candidates.append(node as Node3D)
        for child in node.get_children():
            stack.append(child)
    return max_nodes - scanned

func is_valid_forage_node(node: Node3D, entry: Dictionary) -> bool:
    if not is_instance_valid(node) or bool(node.get_meta("npc_harvested", false)) or bool(node.get_meta("smart_object_depleted", false)):
        return false
    if bool(node.get_meta(forager_unreachable_meta_key(entry), false)):
        return false
    if forager_target_cooldown_active(entry, node):
        return false
    if String(node.get_meta("kind", "")) != "prop":
        return false
    if not is_forage_food_item(String(node.get_meta("drop", ""))):
        return false
    if not point_inside_work_area(entry, node.global_position):
        return false
    if point_inside_town_footprint(entry, node.global_position, 3):
        return false
    if not smart_object_available(smart_object_id_for_node(node), String(entry.get("id", ""))):
        return false
    var h: float = main.surface_y_at_position(node.global_position)
    return h >= main.WATER_LEVEL + 0.45

func current_route_failure_blocks_forager(entry: Dictionary) -> bool:
    if String(entry.get("activeDoorPortalId", "")) != "":
        return false
    if String(entry.get("routineRouteV2IntentKind", "")) != "forage" or String(entry.get("routineRouteV2SemanticKind", "")) != "forage_target":
        return false
    var authority: Dictionary = entry.get("routeAuthorityV2", {}) if entry.get("routeAuthorityV2", {}) is Dictionary else {}
    if String(authority.get("requestId", "")) == "" or String(authority.get("requestId", "")) != String(entry.get("routineRouteV2RequestId", "")):
        return false
    var state := String(authority.get("state", ""))
    if state in ["unreachable_static", "invalid_goal"]:
        return true
    return state == "blocked_dynamic" and int(entry.get("forageRouteRepairAttempts", 0)) >= 1

func _route_still_waiting_for_navmesh_tiles(entry: Dictionary) -> bool:
    if int(entry.get("navmeshTileBudgetWaitFrames", 0)) > 0:
        return true
    var debug_value = entry.get("lastNavmeshTilePublishDebug", [])
    if not (debug_value is Array):
        return false
    for item in debug_value:
        if not (item is Dictionary):
            continue
        var status := String((item as Dictionary).get("status", ""))
        if status in ["pending_budget", "queued_priority", "queued_budgeted", "queued_after_inline_publish", "skipped_until_endpoint_tiles"]:
            return true
    return false

func mark_forager_target_unreachable(entry: Dictionary, node: Node3D) -> void:
    if node == null or not is_instance_valid(node):
        return
    node.set_meta(forager_unreachable_meta_key(entry), true)

func defer_forager_target(entry: Dictionary, node: Node3D, seconds := NpcConstantsScript.FORAGE_TARGET_RETRY_COOLDOWN_SECONDS) -> void:
    if node == null or not is_instance_valid(node):
        return
    var object_id := smart_object_id_for_node(node)
    if object_id == "":
        return
    var cooldowns: Dictionary = entry.get("forageTargetCooldowns", {}) if entry.get("forageTargetCooldowns", {}) is Dictionary else {}
    var duration_frames := ceili(maxf(0.0, float(seconds)) * maxf(float(Engine.physics_ticks_per_second), 1.0))
    cooldowns[object_id] = Engine.get_physics_frames() + duration_frames
    entry["forageTargetCooldowns"] = cooldowns
    clear_cached_resource_target(entry, node)

func forager_target_cooldown_active(entry: Dictionary, node: Node3D) -> bool:
    var cooldowns: Dictionary = entry.get("forageTargetCooldowns", {}) if entry.get("forageTargetCooldowns", {}) is Dictionary else {}
    if cooldowns.is_empty():
        return false
    var current_frame := Engine.get_physics_frames()
    for object_id_value in cooldowns.keys().duplicate():
        if int(cooldowns.get(object_id_value, 0)) <= current_frame:
            cooldowns.erase(object_id_value)
    if cooldowns.is_empty():
        entry.erase("forageTargetCooldowns")
        return false
    entry["forageTargetCooldowns"] = cooldowns
    return cooldowns.has(smart_object_id_for_node(node))

func mark_job_resource_target_unreachable(entry: Dictionary, node: Node3D, job: String) -> void:
    if node == null or not is_instance_valid(node):
        return
    node.set_meta(job_resource_unreachable_meta_key(entry, job), true)

func job_resource_unreachable_meta_key(entry: Dictionary, job: String) -> String:
    if job == "forage":
        return forager_unreachable_meta_key(entry)
    var cache_key := "jobResourceUnreachableMetaKeys"
    var cached_keys: Dictionary = entry.get(cache_key, {}) if entry.get(cache_key, {}) is Dictionary else {}
    if cached_keys.has(job):
        return String(cached_keys.get(job, ""))
    var raw_id := String(entry.get("id", "npc"))
    var safe_id := metadata_identifier_suffix(raw_id)
    var raw_hash := int(("%s:%s" % [raw_id, job]).hash())
    if raw_hash < 0:
        raw_hash = -raw_hash
    var key := "npc_unreachable_resource_%s_%s_%d" % [job, safe_id, raw_hash]
    cached_keys[job] = key
    entry[cache_key] = cached_keys
    return key

func forager_unreachable_meta_key(entry: Dictionary) -> String:
    var cached := String(entry.get("foragerUnreachableMetaKey", ""))
    if cached != "":
        return cached
    var raw_id := String(entry.get("id", "npc"))
    var safe_id := metadata_identifier_suffix(raw_id)
    var raw_hash := int(raw_id.hash())
    if raw_hash < 0:
        raw_hash = -raw_hash
    var key := "npc_unreachable_forager_%s_%d" % [safe_id, raw_hash]
    entry["foragerUnreachableMetaKey"] = key
    return key

func metadata_identifier_suffix(value: String) -> String:
    if metadata_key_sanitizer == null:
        metadata_key_sanitizer = RegEx.new()
        if metadata_key_sanitizer.compile("[^A-Za-z0-9_]") != OK:
            return "npc"
    var safe := metadata_key_sanitizer.sub(value, "_", true)
    return safe if safe != "" else "npc"

func harvest_forager_target(entry: Dictionary) -> bool:
    return complete_worker_resource_target(entry)

func find_job_resource_target(entry: Dictionary, job: String) -> Node3D:
    var body := entry.get("body") as Node3D
    if body == null:
        return null
    var cached_target := cached_resource_target_for_entry(entry, job)
    if cached_target != null:
        return cached_target
    var monitor = performance_monitor()
    var scan_start: int = monitor.begin_section("job_forage_scan") if monitor != null else Time.get_ticks_usec()
    var query_options := resource_query_options_for_job(entry, job)
    var candidates: Array[Node3D] = indexed_resource_candidates(entry, resource_kinds_for_job(job), query_options)
    var indexed_candidates := not candidates.is_empty()
    var scanned_nodes := 0
    if candidates.is_empty() and allow_resource_scan_fallback():
        var remaining_scan_nodes := FORAGE_SCAN_NODE_LIMIT
        for root in [main.get("prop_root"), main.get("chunk_root")]:
            remaining_scan_nodes = collect_job_resource_targets_in_tree(root as Node, entry, job, body.global_position, candidates, remaining_scan_nodes, FORAGE_SCAN_CANDIDATE_LIMIT)
            if remaining_scan_nodes <= 0 or candidates.size() >= FORAGE_SCAN_CANDIDATE_LIMIT:
                break
        scanned_nodes = FORAGE_SCAN_NODE_LIMIT - remaining_scan_nodes
    if monitor != null:
        monitor.increment_counter("job_scan_nodes", scanned_nodes)
        monitor.end_section("job_forage_scan", scan_start)
    if candidates.is_empty():
        return null
    if autonomy_system != null and autonomy_system.get("smart_objects") != null:
        var candidate_lookup := {}
        for candidate in candidates:
            candidate_lookup[smart_object_id_for_node(candidate)] = candidate
        var scored: Array = autonomy_system.get("smart_objects").score_candidates(entry, "harvest_resource", candidates)
        for score in scored:
            var object_id: String = String(score.get("objectId", ""))
            var candidate := candidate_lookup.get(object_id, null) as Node3D
            if candidate != null and (indexed_candidates or smart_object_available(object_id, String(entry.get("id", "")))):
                remember_cached_resource_target(entry, job, candidate)
                return candidate
    candidates.sort_custom(func(a: Node3D, b: Node3D) -> bool:
        return a.global_position.distance_squared_to(body.global_position) < b.global_position.distance_squared_to(body.global_position)
    )
    for candidate in candidates:
        var object_id: String = smart_object_id_for_node(candidate)
        if indexed_candidates or smart_object_available(object_id, String(entry.get("id", ""))):
            remember_cached_resource_target(entry, job, candidate)
            return candidate
    return null

func resource_query_options_for_job(entry: Dictionary, job: String) -> Dictionary:
    var options := {
        "limit": FORAGE_SCAN_CANDIDATE_LIMIT,
        "outsideTown": resource_job_uses_outside_work_area(job),
        "workAreaOnly": true,
        "chunkRadius": 2,
        "cacheFrames": 30,
        "unreachableMetaKey": job_resource_unreachable_meta_key(entry, job)
    }
    if job == "forage":
        options["drops"] = forage_food_item_ids()
    return options

func cached_resource_target_for_entry(entry: Dictionary, job: String) -> Node3D:
    if String(entry.get("cachedResourceJob", "")) != job:
        return null
    var object_id := String(entry.get("cachedResourceObjectId", ""))
    if object_id == "":
        clear_cached_resource_target(entry)
        return null
    var cached_frame := int(entry.get("cachedResourceFrame", -1000000))
    if cached_frame + RESOURCE_TARGET_CACHE_FRAMES < Engine.get_process_frames():
        clear_cached_resource_target(entry)
        return null
    var node := smart_object_node_for_id(object_id)
    if node == null:
        clear_cached_resource_target(entry)
        return null
    if smart_object_id_for_node(node) != object_id:
        clear_cached_resource_target(entry)
        return null
    var valid := is_valid_forage_node(node, entry) if job == "forage" else is_valid_job_resource_node(node, entry, job)
    if not valid:
        clear_cached_resource_target(entry)
        return null
    if job != "forage" and not smart_object_available(object_id, String(entry.get("id", ""))):
        clear_cached_resource_target(entry)
        return null
    return node

func remember_cached_resource_target(entry: Dictionary, job: String, node: Node3D) -> void:
    if node == null or not is_instance_valid(node):
        return
    var object_id := smart_object_id_for_node(node)
    if object_id == "":
        return
    entry["cachedResourceJob"] = job
    entry["cachedResourceObjectId"] = object_id
    entry["cachedResourceFrame"] = Engine.get_process_frames()

func clear_cached_resource_target(entry: Dictionary, node: Node = null) -> void:
    if node != null:
        var cached_object_id := String(entry.get("cachedResourceObjectId", ""))
        if cached_object_id != "" and smart_object_id_for_node(node) != cached_object_id:
            return
    entry.erase("cachedResourceJob")
    entry.erase("cachedResourceObjectId")
    entry.erase("cachedResourceFrame")

func filter_job_resource_candidates(entry: Dictionary, job: String, candidates: Array[Node3D]) -> Array[Node3D]:
    var filtered: Array[Node3D] = []
    for candidate in candidates:
        if is_valid_job_resource_node(candidate, entry, job):
            filtered.append(candidate)
    return filtered

func indexed_resource_candidates(entry: Dictionary, kinds: Array, options: Dictionary) -> Array[Node3D]:
    var service = smart_object_service()
    if service == null or not service.has_method("query_resource_nodes") or kinds.is_empty():
        return []
    return service.query_resource_nodes(entry, kinds, options)

func smart_object_service():
    if autonomy_system == null:
        return null
    return autonomy_system.get("smart_objects")

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

func collect_job_resource_targets_in_tree(root: Node, entry: Dictionary, job: String, _origin: Vector3, candidates: Array[Node3D], max_nodes: int, max_candidates: int) -> int:
    if root == null or max_nodes <= 0 or candidates.size() >= max_candidates:
        return max_nodes
    var stack: Array[Node] = [root]
    var scanned := 0
    while not stack.is_empty() and scanned < max_nodes and candidates.size() < max_candidates:
        var node := stack.pop_back() as Node
        scanned += 1
        if node == null:
            continue
        if node is Node3D and is_valid_job_resource_node(node as Node3D, entry, job):
            candidates.append(node as Node3D)
        for child in node.get_children():
            stack.append(child)
    return max_nodes - scanned

func is_valid_job_resource_node(node: Node3D, entry: Dictionary, job: String) -> bool:
    if not is_instance_valid(node) or bool(node.get_meta("npc_harvested", false)) or bool(node.get_meta("smart_object_depleted", false)):
        return false
    if bool(node.get_meta(job_resource_unreachable_meta_key(entry, job), false)):
        return false
    if String(node.get_meta("kind", "")) != "prop":
        return false
    if not point_inside_work_area(entry, node.global_position):
        return false
    if resource_job_uses_outside_work_area(job):
        if point_inside_town_footprint(entry, node.global_position):
            return false
    elif not point_inside_town_footprint(entry, node.global_position):
        return false
    var h: float = main.surface_y_at_position(node.global_position)
    if h < main.WATER_LEVEL + 0.45:
        return false
    var material := String(node.get_meta("material", ""))
    var drop := String(node.get_meta("drop", ""))
    if job == "wood":
        return material == "tree" or drop == "logs"
    if job == "stone":
        return material in ["rock", "copperOre", "ironOre"] or drop in ["stones", "copperOre", "ironOre"]
    if job == "forage":
        if bool(node.get_meta(forager_unreachable_meta_key(entry), false)):
            return false
        return is_forage_food_item(drop)
    return false

func resource_job_uses_outside_work_area(job: String) -> bool:
    return job == "forage"

func candidate_by_object_id(candidates: Array[Node3D], object_id: String) -> Node3D:
    for candidate in candidates:
        if smart_object_id_for_node(candidate) == object_id:
            return candidate
    return null

func smart_object_id_for_node(node: Node) -> String:
    if node == null:
        return ""
    if node.has_meta("prop_id"):
        return "prop:%s" % String(node.get_meta("prop_id"))
    if node.has_meta("cell"):
        var cell = node.get_meta("cell")
        var block_type := String(node.get_meta("block_type", node.name))
        if cell is Vector3i:
            return "block:%d,%d,%d:%s" % [cell.x, cell.y, cell.z, block_type]
    return ""

func smart_object_node_for_id(object_id: String) -> Node3D:
    var service = smart_object_service()
    if service == null or object_id == "":
        return null
    var registrations = service.get("registrations")
    if not (registrations is Dictionary):
        return null
    var registration = (registrations as Dictionary).get(object_id)
    if registration == null:
        return null
    var node = registration.node
    if node == null or not is_instance_valid(node) or not (node is Node3D):
        return null
    return node as Node3D

func smart_object_available(object_id: String, actor_id: String) -> bool:
    if autonomy_system == null or autonomy_system.get("smart_objects") == null:
        return true
    var service = autonomy_system.get("smart_objects")
    var available: Dictionary = service.object_available(object_id, actor_id)
    return bool(available.get("ok", false))

func smart_object_has_live_registration(object_id: String) -> bool:
    if object_id == "" or autonomy_system == null or autonomy_system.get("smart_objects") == null:
        return false
    var service = autonomy_system.get("smart_objects")
    if service.has_method("has_live_registration"):
        return bool(service.call("has_live_registration", object_id))
    var registrations = service.get("registrations")
    return registrations is Dictionary and (registrations as Dictionary).has(object_id)

func smart_object_action_reach(object_id: String, fallback: float) -> float:
    var service = smart_object_service()
    if service == null or object_id == "":
        return fallback
    var registrations = service.get("registrations")
    if not (registrations is Dictionary):
        return fallback
    var registration = (registrations as Dictionary).get(object_id)
    if registration == null:
        return fallback
    var metadata = registration.get("metadata") if registration is Object else {}
    if metadata is Dictionary and (metadata as Dictionary).has("actionReach"):
        return float((metadata as Dictionary).get("actionReach", fallback))
    return fallback

func smart_object_reservation_debug(object_id: String, owner_id := "") -> Dictionary:
    var service = smart_object_service()
    if service == null or not service.has_method("reservation_debug"):
        return { "ok": false, "reason": "missing_smart_object_debug", "objectId": object_id }
    return service.call("reservation_debug", object_id, owner_id)

func smart_object_reservation_debug_for_entry(entry: Dictionary) -> Dictionary:
    return smart_object_reservation_debug(String(entry.get("jobObjectId", "")), String(entry.get("id", "")))

func resource_approach_slots_for_entry(entry: Dictionary, target_node: Node3D) -> Dictionary:
    if target_node == null or not is_instance_valid(target_node) or pathing == null:
        return {}
    var navigation_world = pathing.get("navigation_world")
    if navigation_world == null or not navigation_world.has_method("approach_cells_for_target") or not navigation_world.has_method("cell_position"):
        return {}
    var cells: Array = navigation_world.call("approach_cells_for_target", entry, target_node.global_position, true)
    var positions: Array[Vector3] = []
    var prefer_near_object_slot := String(entry.get("job", "")) == "forage"
    for cell_value in cells:
        if not (cell_value is Vector2i):
            continue
        var position: Vector3 = navigation_world.call("cell_position", cell_value)
        if not point_inside_work_area(entry, position):
            continue
        if prefer_near_object_slot and point_inside_town_footprint(entry, position):
            continue
        if not prefer_near_object_slot and not point_inside_town_footprint(entry, position):
            continue
        positions.append(position)
    if positions.is_empty():
        return {}
    var body := entry.get("body") as Node3D
    var origin: Vector3 = body.global_position if body != null else entry.get("porchPosition", target_node.global_position)
    var town_center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
    var town_position := Vector3(float(town_center.x) * CELL, origin.y, float(town_center.y) * CELL)
    positions.sort_custom(func(a: Vector3, b: Vector3) -> bool:
        var a_key := "%0.3f,%0.3f" % [a.x, a.z]
        var b_key := "%0.3f,%0.3f" % [b.x, b.z]
        if prefer_near_object_slot:
            var a_object_distance := Vector2(a.x - target_node.global_position.x, a.z - target_node.global_position.z).length_squared()
            var b_object_distance := Vector2(b.x - target_node.global_position.x, b.z - target_node.global_position.z).length_squared()
            if not is_equal_approx(a_object_distance, b_object_distance):
                return a_object_distance < b_object_distance
            var a_town_distance := Vector2(a.x - town_position.x, a.z - town_position.z).length_squared()
            var b_town_distance := Vector2(b.x - town_position.x, b.z - town_position.z).length_squared()
            if not is_equal_approx(a_town_distance, b_town_distance):
                return a_town_distance < b_town_distance
        var a_distance := Vector2(a.x - origin.x, a.z - origin.z).length_squared()
        var b_distance := Vector2(b.x - origin.x, b.z - origin.z).length_squared()
        if is_equal_approx(a_distance, b_distance):
            return a_key < b_key
        return a_distance < b_distance
    )
    var slots := {}
    var slot_count := mini(4, positions.size())
    for i in range(slot_count):
        var position: Vector3 = positions[i]
        slots["slot:%d" % i] = {
            "slotId": "slot:%d" % i,
            "position": position,
            "facing": target_node.global_position - position,
            "capacity": 1,
            "occupants": []
        }
    return slots

func reserve_job_target(entry: Dictionary, target_node: Node3D, action: String, preferred_slot_id := "") -> bool:
    if target_node == null or not is_instance_valid(target_node) or autonomy_system == null:
        return false
    var body := entry.get("body") as Node
    var resource_metadata := { "action": action }
    var object_id := smart_object_id_for_node(target_node)
    var approach_slots := resource_approach_slots_for_entry(entry, target_node)
    if not approach_slots.is_empty():
        resource_metadata["slots"] = approach_slots
    if object_id == "" or not smart_object_has_live_registration(object_id):
        object_id = autonomy_system.register_smart_resource(target_node, resource_metadata)
    elif not approach_slots.is_empty():
        object_id = autonomy_system.register_smart_resource(target_node, resource_metadata)
    else:
        var monitor = performance_monitor()
        if monitor != null:
            monitor.increment_counter("npc_smart_resource_registration_reused")
    var approach_candidates := forage_approach_candidates(approach_slots)
    if String(entry.get("job", "")) == "forage" and not approach_candidates.is_empty():
        if String(entry.get("jobApproachTargetObjectId", "")) != object_id:
            entry["jobApproachCandidateIndex"] = 0
        entry["jobApproachCandidates"] = approach_candidates
        entry["jobApproachTargetObjectId"] = object_id
        if preferred_slot_id == "":
            var preferred_index := clampi(int(entry.get("jobApproachCandidateIndex", 0)), 0, approach_candidates.size() - 1)
            preferred_slot_id = String((approach_candidates[preferred_index] as Dictionary).get("slotId", ""))
    var result = autonomy_system.reserve_smart_object(object_id, target_node, body, String(entry.get("id", "")), action, {
        "actorKind": "npc",
        "requiresApproach": true,
        "preferredSlotId": preferred_slot_id,
        "routeRequestId": "",
        "routeGeneration": 0,
        "goalKey": "%s|%s|%s" % [String(entry.get("job", "")), String(entry.get("jobPhase", "")), object_id],
        "maxReservationAgeSeconds": NpcConstantsScript.FORAGE_RESERVATION_DEADLINE_SECONDS if String(entry.get("job", "")) == "forage" else 0.0
    })
    if result == null or String(result.get("status")) != "succeeded":
        entry["jobFailureReason"] = String(result.get("reason")) if result != null else "missing_smart_object"
        entry["jobObjectId"] = ""
        entry["jobReservationId"] = ""
        entry["jobApproachSlotId"] = ""
        entry.erase("jobApproachSlotPosition")
        entry.erase("jobApproachSlotCell")
        clear_cached_resource_target(entry, target_node)
        return false
    var metrics: Dictionary = result.get("metrics")
    entry["jobTargetNode"] = target_node
    entry["jobObjectId"] = object_id
    entry["jobReservationId"] = String(metrics.get("reservationId", ""))
    entry["jobApproachSlotId"] = String(metrics.get("slotId", ""))
    entry["jobTarget"] = vector_from_summary(metrics.get("approachPosition", []), target_node.global_position)
    entry["jobApproachSlotPosition"] = entry["jobTarget"]
    entry["jobApproachSlotCell"] = flat_cell_for_position(entry["jobTarget"])
    for candidate_index in range(approach_candidates.size()):
        var candidate: Dictionary = approach_candidates[candidate_index]
        if String(candidate.get("slotId", "")) == String(entry.get("jobApproachSlotId", "")):
            entry["jobApproachCandidateIndex"] = candidate_index
            break
    entry["jobFailureReason"] = ""
    entry["forageRouteRepairAttempts"] = 0
    if String(entry.get("job", "")) == "forage":
        entry["forageReservationStartedPhysicsFrame"] = Engine.get_physics_frames()
        entry["forageReservationElapsedSeconds"] = 0.0
    entry.erase("forageReservationRouteBinding")
    entry.erase("jobReservationRouteRequestId")
    entry.erase("jobReservationRouteGeneration")
    return true

func forage_approach_candidates(slots: Dictionary) -> Array:
    var result: Array = []
    var slot_ids: Array = slots.keys()
    slot_ids.sort()
    for slot_id_value in slot_ids:
        var slot: Dictionary = slots.get(slot_id_value, {})
        var position = slot.get("position")
        if not (position is Vector3):
            continue
        result.append({
            "slotId": String(slot.get("slotId", slot_id_value)),
            "position": position,
            "cell": flat_cell_for_position(position)
        })
    return result

func advance_forage_approach_slot(entry: Dictionary, target_node: Node3D) -> bool:
    if target_node == null or not is_instance_valid(target_node):
        return false
    var candidates: Array = entry.get("jobApproachCandidates", []) if entry.get("jobApproachCandidates", []) is Array else []
    var next_index := int(entry.get("jobApproachCandidateIndex", -1)) + 1
    if next_index >= candidates.size():
        return false
    release_job_reservation(entry, "forage_slot_route_rejected")
    while next_index < candidates.size():
        var candidate: Dictionary = candidates[next_index] if candidates[next_index] is Dictionary else {}
        entry["jobApproachCandidateIndex"] = next_index
        var slot_id := String(candidate.get("slotId", ""))
        if slot_id != "" and reserve_job_target(entry, target_node, "harvest_resource", slot_id):
            return true
        next_index += 1
    return false

func bind_job_reservation_to_route(entry: Dictionary, authority: Dictionary, semantic_kind: String) -> Dictionary:
    var object_id := String(entry.get("jobObjectId", ""))
    var reservation_id := String(entry.get("jobReservationId", ""))
    var actor_id := String(entry.get("id", ""))
    if object_id == "" or reservation_id == "" or actor_id == "":
        return { "ok": false, "status": "failed", "reason": "missing_reservation_identity" }
    if semantic_kind != "forage_target":
        return { "ok": false, "status": "failed", "reason": "route_not_for_reserved_forage_target" }
    if autonomy_system == null or not autonomy_system.has_method("heartbeat_smart_object_reservation"):
        return { "ok": false, "status": "failed", "reason": "missing_reservation_heartbeat" }
    var request_id := String(authority.get("requestId", ""))
    var generation := int(authority.get("generation", 0))
    var result: Dictionary = autonomy_system.heartbeat_smart_object_reservation(object_id, reservation_id, actor_id, {
        "slotId": String(entry.get("jobApproachSlotId", "")),
        "routeRequestId": request_id,
        "routeGeneration": generation,
        "goalKey": "%s|%s|%s" % [String(entry.get("job", "")), String(entry.get("jobPhase", "")), object_id]
    })
    if bool(result.get("ok", false)):
        entry["jobReservationRouteRequestId"] = request_id
        entry["jobReservationRouteGeneration"] = generation
        entry["jobReservationLastHeartbeatPhysicsFrame"] = Engine.get_physics_frames()
        entry["jobFailureReason"] = ""
    else:
        entry["jobFailureReason"] = String(result.get("reason", "reservation_route_bind_failed"))
    return result

func reserve_station_target(entry: Dictionary, station: Node3D, action: String) -> bool:
    if station == null or not is_instance_valid(station) or autonomy_system == null:
        return false
    var body := entry.get("body") as Node
    var object_id: String = autonomy_system.register_smart_workstation(station, { "action": action, "capacity": 1 })
    var result = autonomy_system.reserve_smart_object(object_id, station, body, String(entry.get("id", "")), action, {
        "actorKind": "npc",
        "requiresApproach": true
    })
    if result == null or String(result.get("status")) != "succeeded":
        entry["jobFailureReason"] = String(result.get("reason")) if result != null else "missing_station"
        entry["jobObjectId"] = ""
        entry["jobReservationId"] = ""
        entry["jobApproachSlotId"] = ""
        return false
    var metrics: Dictionary = result.get("metrics")
    entry["jobTargetNode"] = station
    entry["jobObjectId"] = object_id
    entry["jobReservationId"] = String(metrics.get("reservationId", ""))
    entry["jobApproachSlotId"] = String(metrics.get("slotId", ""))
    entry["jobTarget"] = vector_from_summary(metrics.get("approachPosition", []), station.global_position)
    entry["jobFailureReason"] = ""
    return true

func complete_station_use(entry: Dictionary, action: String) -> bool:
    if autonomy_system == null:
        return false
    var station := job_target_node(entry)
    var object_id: String = String(entry.get("jobObjectId", ""))
    if object_id == "":
        return false
    var body := entry.get("body") as Node
    var result = autonomy_system.complete_smart_object(object_id, station, body, String(entry.get("id", "")), action, {
        "actorKind": "npc",
        "reservationId": String(entry.get("jobReservationId", "")),
        "requireReservation": true,
        "requiresApproach": true,
        "holdReservation": action == "use_trader_stall",
        "request_id": "%s:%s:%s:%d" % [object_id, String(entry.get("id", "")), action, int(entry.get("jobRuns", 0))]
    })
    if result == null or String(result.get("status")) != "succeeded":
        entry["jobFailureReason"] = String(result.get("reason")) if result != null else "station_use_failed"
        return false
    entry["jobFailureReason"] = ""
    return true

func find_trader_stall(entry: Dictionary) -> Node3D:
    if main == null:
        return null
    var body := entry.get("body") as Node3D
    var origin: Vector3 = body.global_position if body != null else entry.get("porchPosition", Vector3.ZERO)
    var best: Node3D = null
    var best_score := INF
    var stalls: Array[Node3D] = indexed_resource_candidates(entry, ["trader_stall"], {
        "limit": 16,
        "outsideTown": false,
        "workAreaOnly": true
    })
    if stalls.is_empty() and allow_resource_scan_fallback():
        var blocks: Dictionary = main.get("blocks")
        for value in blocks.values():
            var block := value as Node3D
            if block == null or not is_instance_valid(block):
                continue
            if String(block.get_meta("block_type", "")) != "traderStall":
                continue
            stalls.append(block)
    for block in stalls:
        if block == null or not is_instance_valid(block):
            continue
        if String(block.get_meta("block_type", "")) != "traderStall":
            continue
        if not point_inside_town(entry, block.global_position):
            continue
        var object_id: String = smart_object_id_for_node(block)
        if object_id != "" and not smart_object_available(object_id, String(entry.get("id", ""))):
            continue
        var score := block.global_position.distance_squared_to(origin)
        if score < best_score:
            best = block
            best_score = score
    return best

func release_job_reservation(entry: Dictionary, reason := "released") -> void:
    var object_id: String = String(entry.get("jobObjectId", ""))
    if autonomy_system != null and object_id != "":
        var target_node := job_target_node(entry)
        var body := entry.get("body") as Node
        autonomy_system.release_smart_object(object_id, target_node, body, String(entry.get("id", "")), reason, {
            "actorKind": "npc",
            "reservationId": String(entry.get("jobReservationId", ""))
        })
    entry["jobObjectId"] = ""
    entry["jobReservationId"] = ""
    entry["jobApproachSlotId"] = ""
    entry["jobTargetNode"] = null
    entry.erase("jobApproachSlotPosition")
    entry.erase("jobApproachSlotCell")
    entry.erase("jobReservationRouteRequestId")
    entry.erase("jobReservationRouteGeneration")
    entry.erase("jobReservationLastHeartbeatPhysicsFrame")
    entry.erase("forageReservationRouteBinding")
    entry.erase("forageReservationStartedPhysicsFrame")
    entry.erase("forageReservationElapsedSeconds")

func job_target_node(entry: Dictionary) -> Node3D:
    var target_value = entry.get("jobTargetNode")
    if target_value == null or not is_instance_valid(target_value):
        return null
    return target_value as Node3D if target_value is Node3D else null

func smart_object_approach_position(entry: Dictionary, target_node: Node3D) -> Vector3:
    var target: Vector3 = target_node.global_position if target_node != null else entry.get("jobTarget", Vector3.ZERO)
    if String(entry.get("jobObjectId", "")) == "" and target_node != null:
        reserve_job_target(entry, target_node, "harvest_resource")
    return entry.get("jobTarget", target)

func complete_worker_resource_target(entry: Dictionary) -> bool:
    var target_node := job_target_node(entry)
    if target_node == null or autonomy_system == null:
        entry["jobFailureReason"] = "target_gone"
        return false
    var object_id: String = String(entry.get("jobObjectId", ""))
    if object_id == "":
        if not reserve_job_target(entry, target_node, "harvest_resource"):
            entry["jobFailureReason"] = "reservation_failed"
            return false
        object_id = String(entry.get("jobObjectId", ""))
        entry["jobObjectId"] = object_id
    var body := entry.get("body") as Node
    var request_id := "%s:%s:%s:%d" % [object_id, String(entry.get("id", "")), "harvest", int(entry.get("jobRuns", 0))]
    var result = autonomy_system.complete_smart_object(object_id, target_node, body, String(entry.get("id", "")), "harvest_resource", {
        "actorKind": "npc",
        "reservationId": String(entry.get("jobReservationId", "")),
        "requireReservation": true,
        "requiresApproach": true,
        "request_id": request_id
    })
    if result == null or String(result.get("status")) != "succeeded":
        entry["jobFailureReason"] = String(result.get("reason")) if result != null else "missing_smart_object"
        return false
    var metrics: Dictionary = result.get("metrics")
    if not bool(metrics.get("effectApplied", false)):
        entry["jobFailureReason"] = "idempotent_replay"
        return false
    var drop := String(metrics.get("drop", entry.get("jobResource", "")))
    var amount: int = max(1, int(metrics.get("amount", 1)))
    npc_inventory_add(entry, drop, amount)
    entry["carriedResource"] = drop
    entry["jobResource"] = drop
    mark_prop_removed_after_smart_effect(target_node, metrics)
    entry["jobTargetNode"] = null
    entry["jobReservationId"] = ""
    entry["jobApproachSlotId"] = ""
    entry.erase("forageReservationStartedPhysicsFrame")
    entry.erase("forageReservationElapsedSeconds")
    entry["jobFailureReason"] = ""
    last_message = "%s gathered %s" % [String(entry.get("name", "NPC")), drop]
    return true

func mark_prop_removed_after_smart_effect(target_node: Node3D, metrics: Dictionary) -> void:
    if target_node == null or not is_instance_valid(target_node):
        return
    var prop_id := String(metrics.get("propId", target_node.get_meta("prop_id", "")))
    if prop_id != "" and main != null:
        var removed: Dictionary = main.get("removed_props")
        removed[prop_id] = true
        if autonomy_system:
            autonomy_system.notify_prop_removed(prop_id, target_node)
    target_node.queue_free()

func complete_deposit_interaction(entry: Dictionary) -> bool:
    var item_id := String(entry.get("carriedResource", entry.get("jobResource", "")))
    if item_id == "":
        return false
    var amount: int = npc_inventory_count(entry, item_id)
    if amount <= 0:
        entry["carriedResource"] = ""
        return false
    if autonomy_system != null:
        var object_id: String = "deposit:%s" % String(entry.get("id", "npc"))
        var home: Vector3 = entry.get("homePosition", entry.get("porchPosition", Vector3.ZERO))
        autonomy_system.register_smart_anchor(object_id, "storage", home, { "capacity": 1, "action": "deposit_inventory" })
        var body := entry.get("body") as Node
        var result = autonomy_system.complete_smart_object(object_id, null, body, String(entry.get("id", "")), "deposit_inventory", {
            "actorKind": "npc",
            "requireReservation": false,
            "requiresApproach": true,
            "request_id": "%s:%s:%d" % [object_id, item_id, int(entry.get("jobRuns", 0))]
        })
        if result == null or String(result.get("status")) != "succeeded":
            entry["jobFailureReason"] = String(result.get("reason")) if result != null else "deposit_failed"
            return false
    npc_inventory_add(entry, item_id, -amount)
    entry["carriedResource"] = ""
    last_message = "%s delivered %s" % [String(entry.get("name", "NPC")), item_id]
    return true

func vector_from_summary(value, fallback: Vector3) -> Vector3:
    if value is Array and value.size() >= 3:
        return Vector3(float(value[0]), float(value[1]), float(value[2]))
    if value is Vector3:
        return value
    return fallback

func home_route_target(entry: Dictionary) -> Vector3:
    var body := entry.get("body") as Node3D
    if body == null:
        return entry.get("homePosition", Vector3.ZERO)
    var route_positions: Array = entry.get("homeRoutePositions", []) if entry.get("homeRoutePositions", []) is Array else []
    if not route_positions.is_empty():
        var route_index := clampi(int(entry.get("homeRouteIndex", 0)), 0, route_positions.size())
        if route_index > 0 and not home_route_actor_inside(entry, body) and route_positions[0] is Vector3:
            var porch_target: Vector3 = route_positions[0]
            if home_route_should_restart_from_porch(entry, body, porch_target):
                route_index = 0
                entry["homeRouteIndex"] = route_index
        if route_index < route_positions.size():
            var current_target = route_positions[route_index]
            if current_target is Vector3:
                var current_target_position: Vector3 = current_target
                var current_target_cell := flat_cell_for_position(current_target_position)
                if entry.has("homeActiveTargetCell") \
                    and entry.get("homeActiveTargetCell") == current_target_cell \
                    and home_route_step_reached(entry, current_target_position):
                    route_index += 1
                    entry["homeRouteIndex"] = route_index
                    if route_index < route_positions.size() and route_positions[route_index] is Vector3:
                        var next_target_position: Vector3 = route_positions[route_index]
                        entry["homeActiveTargetCell"] = flat_cell_for_position(next_target_position)
                        return next_target_position
                    entry["homeActiveTargetCell"] = entry.get("homeCell", flat_cell_for_position(entry.get("homePosition", body.global_position)))
                    return entry.get("homePosition", body.global_position)
                entry["homeActiveTargetCell"] = current_target_cell
                return current_target_position
        entry["homeRouteIndex"] = route_positions.size()
        if not home_route_actor_inside(entry, body):
            var restart_index := 0
            if route_positions.size() > 1 and route_positions[0] is Vector3:
                var porch_target: Vector3 = route_positions[0]
                if body.global_position.distance_to(porch_target) <= CELL * 1.35:
                    restart_index = 1
            restart_index = clampi(restart_index, 0, route_positions.size() - 1)
            entry["homeRouteIndex"] = restart_index
            var restart_target = route_positions[restart_index]
            if restart_target is Vector3:
                var restart_position: Vector3 = restart_target
                entry["homeActiveTargetCell"] = flat_cell_for_position(restart_position)
                return restart_position
    if not home_route_actor_inside(entry, body):
        var home_cell: Vector2i = entry.get("homeCell", flat_cell_for_position(entry.get("homePosition", body.global_position)))
        var porch_cell: Vector2i = entry.get("porchCell", home_cell)
        if home_route_arrived_at_active_cell(entry, porch_cell):
            entry["homeActiveTargetCell"] = home_cell
            return entry.get("homePosition", body.global_position)
        var porch: Vector3 = entry.get("porchPosition", entry.get("homePosition", body.global_position))
        if body.global_position.distance_to(porch) > CELL * 1.35:
            return porch
    return entry.get("homePosition", body.global_position)

func home_route_actor_inside(entry: Dictionary, body: Node3D) -> bool:
    if body == null:
        return false
    if autonomy_system != null and autonomy_system.has_method("is_inside_home_interior"):
        return bool(autonomy_system.call("is_inside_home_interior", entry, body.global_position))
    return bool(entry.get("insideHome", false))

func home_route_should_restart_from_porch(entry: Dictionary, body: Node3D, porch_target: Vector3) -> bool:
    if body == null:
        return false
    if body.global_position.distance_to(porch_target) <= CELL * 2.0:
        return false
    if String(entry.get("activeDoorPortalId", "")) != "":
        return false
    var current_cell := flat_cell_for_position(body.global_position)
    if HomeInteriorServiceScript.cell_inside_home_bounds(entry, current_cell, true):
        return false
    var door_cell: Vector2i = entry.get("doorCell", Vector2i(999999, 999999))
    if door_cell != Vector2i(999999, 999999) and current_cell == door_cell:
        return false
    return true

func home_route_step_reached(entry: Dictionary, route_target: Vector3) -> bool:
    var body := entry.get("body") as Node3D
    if body == null:
        return true
    var target_cell := flat_cell_for_position(route_target)
    var current_cell := flat_cell_for_position(body.global_position)
    var porch_cell: Vector2i = entry.get("porchCell", target_cell)
    var home_cell: Vector2i = entry.get("homeCell", target_cell)
    var route_status := String(entry.get("routeStatus", ""))
    var route_arrived_at_target := false
    if route_status == "arrived" and entry.has("homeActiveTargetCell"):
        var active_cell: Vector2i = entry.get("homeActiveTargetCell", target_cell)
        route_arrived_at_target = active_cell == target_cell
    if route_arrived_at_target and target_cell != home_cell and home_route_arrival_is_complete_step(entry, target_cell):
        return true
    var exact_ordered_home_step: bool = route_requires_exact_porch_arrival(entry) and target_cell != home_cell
    var distance_from_porch: int = abs(target_cell.x - porch_cell.x) + abs(target_cell.y - porch_cell.y)
    var exact_door_threshold_step: bool = exact_ordered_home_step and distance_from_porch <= 1
    var distance_to_target := body.global_position.distance_to(route_target)
    if route_arrived_at_target and target_cell != home_cell:
        if exact_door_threshold_step:
            return current_cell == target_cell or distance_to_target <= CELL * 0.35
        if exact_ordered_home_step:
            return current_cell == target_cell or distance_to_target <= CELL * 0.35
        if target_cell == porch_cell and route_requires_exact_porch_arrival(entry):
            return current_cell == target_cell or distance_to_target <= CELL * 0.35
        if target_cell != porch_cell and abs(target_cell.x - porch_cell.x) + abs(target_cell.y - porch_cell.y) == 1:
            return current_cell == target_cell or distance_to_target <= CELL * 0.35
        return current_cell == target_cell or distance_to_target <= CELL * 0.82
    if exact_door_threshold_step:
        return current_cell == target_cell or distance_to_target <= CELL * 0.35
    if exact_ordered_home_step:
        return current_cell == target_cell or distance_to_target <= CELL * 0.35
    if target_cell != porch_cell and abs(target_cell.x - porch_cell.x) + abs(target_cell.y - porch_cell.y) == 1:
        if current_cell == target_cell or distance_to_target <= CELL * 0.35:
            return true
        return false
    if target_cell == porch_cell and route_requires_exact_porch_arrival(entry):
        return current_cell == target_cell or distance_to_target <= CELL * 0.35
    if distance_to_target <= CELL * 0.82:
        return true
    if target_cell == porch_cell and abs(current_cell.x - target_cell.x) <= 1 and abs(current_cell.y - target_cell.y) <= 1:
        return true
    if not route_arrived_at_target:
        return false
    if target_cell != home_cell:
        return current_cell == target_cell or distance_to_target <= CELL * 0.35
    return current_cell == target_cell or (HomeInteriorServiceScript.cell_inside_home_bounds(entry, current_cell, true) and distance_to_target <= CELL * 0.72)

func home_route_arrived_at_active_cell(entry: Dictionary, target_cell: Vector2i) -> bool:
    if String(entry.get("routeStatus", "")) != "arrived":
        return false
    if not entry.has("homeActiveTargetCell"):
        return false
    var active_target_cell = entry.get("homeActiveTargetCell", Vector2i(999999, 999999))
    return active_target_cell is Vector2i and active_target_cell == target_cell

func home_route_arrival_is_complete_step(entry: Dictionary, target_cell: Vector2i) -> bool:
    var debug_value = entry.get("lastRoutePlanDebug", {})
    if not (debug_value is Dictionary):
        return true
    var debug: Dictionary = debug_value
    if String(debug.get("status", "")) == "partial":
        return false
    if bool(debug.get("generatedCellBridgeUsed", false)):
        return false
    var fallback_cell := debug_cell_value(debug.get("fallbackCell", Vector2i(999999, 999999)), Vector2i(999999, 999999))
    if fallback_cell != Vector2i(999999, 999999) and fallback_cell != target_cell:
        return false
    return true

func debug_cell_value(value, fallback: Vector2i) -> Vector2i:
    if value is Vector2i:
        return value
    if value is Array and (value as Array).size() >= 2:
        var array_value: Array = value
        return Vector2i(int(array_value[0]), int(array_value[1]))
    if value is Dictionary:
        var dict: Dictionary = value
        return Vector2i(int(dict.get("x", fallback.x)), int(dict.get("z", dict.get("y", fallback.y))))
    return fallback

func route_requires_exact_porch_arrival(entry: Dictionary) -> bool:
    return bool(entry.get("holdDoorOrder", false))

func settle_home_if_reached(entry: Dictionary) -> void:
    var body := entry.get("body") as Node3D
    if body == null:
        return
    var inside_semantic: bool = false
    if autonomy_system != null and autonomy_system.has_method("is_inside_home_interior"):
        inside_semantic = bool(autonomy_system.is_inside_home_interior(entry, body.global_position))
    else:
        var fallback_status := HomeInteriorServiceScript.status(entry, body.global_position, null)
        inside_semantic = bool(fallback_status.get("strictInside", false))
    if inside_semantic:
        if body_occupies_open_door_clearance(entry):
            entry["insideHome"] = false
            body.set_meta("npc_inside_home", false)
            entry["homeSettleDebug"] = {
                "insideSemantic": true,
                "doorClearanceOccupied": true,
                "routeStatus": String(entry.get("routeStatus", "")),
                "currentCell": flat_cell_for_position(body.global_position),
                "activeDoorPortalId": String(entry.get("activeDoorPortalId", ""))
            }
            return
        mark_npc_inside_home(entry)
        return
    if bool(entry.get("insideHome", false)):
        entry["insideHome"] = false
        body.set_meta("npc_inside_home", false)
    var home_cell: Vector2i = entry.get("homeCell", Vector2i.ZERO)
    var route_status := String(entry.get("routeStatus", ""))
    var current_cell := flat_cell_for_position(body.global_position)
    var active_target_cell: Vector2i = entry.get("homeActiveTargetCell", home_cell)
    var target_is_home := active_target_cell == home_cell
    var route_terminal := route_status in ["arrived", "partial", "blocked"]
    entry["homeSettleDebug"] = {
        "insideSemantic": inside_semantic,
        "routeStatus": route_status,
        "currentCell": current_cell,
        "homeCell": home_cell,
        "activeTargetCell": active_target_cell,
        "targetIsHome": target_is_home,
        "routeTerminal": route_terminal
    }
    if target_is_home and route_terminal and String(entry.get("routeReason", "")) != "home_route_terminal_outside":
        mark_npc_home_blocked(entry, "home_route_terminal_outside")

func body_occupies_open_door_clearance(entry: Dictionary) -> bool:
    if autonomy_system == null or autonomy_system.door_portals == null:
        return false
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return false
    var portals: Dictionary = autonomy_system.door_portals.portals
    for portal_value in portals.values():
        if portal_value == null:
            continue
        if not portal_value.occupied_actors([body], "clearance").is_empty():
            return true
    return false

func mark_npc_home_blocked(entry: Dictionary, reason := "home_blocked") -> void:
    var body := entry.get("body") as Node3D
    if body == null:
        return
    entry["insideHome"] = false
    entry["homeBlocked"] = true
    NpcRouteStateStoreScript.write_status(entry, "blocked", reason, "NpcSystem.mark_npc_home_blocked")
    entry["unreachableGoals"] = int(entry.get("unreachableGoals", 0)) + 1
    body.set_meta("npc_inside_home", false)
    body.set_meta("npc_home_blocked", true)

func mark_npc_inside_home(entry: Dictionary) -> void:
    var body := entry.get("body") as Node3D
    if body == null:
        return
    entry["insideHome"] = true
    entry["homeBlocked"] = false
    entry["homeRouteIndex"] = int((entry.get("homeRoutePositions", []) as Array).size())
    body.set_meta("npc_inside_home", true)
    body.set_meta("npc_home_blocked", false)

func request_npc_door_traversal(collider: Node, npc_body: Node3D = null, entry: Dictionary = {}, action: Dictionary = {}) -> Dictionary:
    ensure_autonomy_system()
    var door := interaction_door_for_npc(collider)
    if door == null or not is_instance_valid(door):
        return { "ok": false, "status": "failed", "reason": "missing_door" }
    var was_open := bool(door.get_meta("open", false))
    var result: Dictionary = autonomy_system.request_npc_door_traversal(door, npc_body, entry, action) if autonomy_system else { "ok": false, "status": "failed", "reason": "missing_autonomy" }
    if bool(result.get("ok", false)) and not was_open and bool(door.get_meta("open", false)):
        door_opens += 1
        last_message = "NPC opened a door"
    return result

func request_shared_prop_harvest(prop: Node, actor: Node = null, actor_kind := "player", metadata := {}) -> Dictionary:
    ensure_autonomy_system()
    if prop == null or not is_instance_valid(prop) or String(prop.get_meta("kind", "")) != "prop":
        return { "ok": false, "status": "failed", "reason": "missing_prop" }
    if autonomy_system == null:
        return { "ok": true, "status": "succeeded", "reason": "missing_autonomy_optional", "metrics": {} }
    var object_id: String = autonomy_system.register_smart_resource(prop, metadata)
    if object_id == "":
        return { "ok": true, "status": "succeeded", "reason": "not_shared_resource", "metrics": {} }
    var request_metadata := metadata.duplicate(true) if metadata is Dictionary else {}
    request_metadata["actorKind"] = actor_kind
    request_metadata["command"] = &"harvest"
    request_metadata["requireReservation"] = false
    request_metadata["requiresApproach"] = bool(request_metadata.get("requiresApproach", actor != null))
    if not request_metadata.has("request_id"):
        request_metadata["request_id"] = "%s:%s:%s" % [actor_kind, object_id, String(prop.get_meta("prop_id", prop.name))]
    var result = autonomy_system.complete_smart_object(object_id, prop, actor, actor_identifier(actor, actor_kind), "harvest_resource", request_metadata)
    if result == null:
        return { "ok": false, "status": "failed", "reason": "missing_smart_object", "metrics": {} }
    return {
        "ok": String(result.get("status")) == "succeeded",
        "status": String(result.get("status")),
        "reason": String(result.get("reason")),
        "metrics": result.get("metrics")
    }

func actor_identifier(actor: Node, fallback := "actor") -> String:
    if actor != null:
        if actor.has_meta("npc_stable_id"):
            return String(actor.get_meta("npc_stable_id"))
        if actor.name != "":
            return String(actor.name)
    return fallback

func request_npc_traffic_step(entry: Dictionary, previous: Vector3, candidate: Vector3, world, intent := {}) -> Dictionary:
    ensure_autonomy_system()
    if autonomy_system == null:
        return { "ok": true, "status": "granted", "reason": "missing_autonomy_optional" }
    return autonomy_system.request_npc_traffic_step(entry, previous, candidate, world, intent)

func release_npc_traffic_reservations(entry_or_id, reason := "released") -> int:
    ensure_autonomy_system()
    if autonomy_system == null:
        return 0
    return autonomy_system.release_npc_traffic_reservations(entry_or_id, reason)

func release_npc_door_hold(actor_or_id, schedule_close := true) -> void:
    ensure_autonomy_system()
    if autonomy_system != null and autonomy_system.has_method("release_npc_door_hold"):
        autonomy_system.release_npc_door_hold(actor_or_id, schedule_close)

func release_npc_traffic_generation(entry: Dictionary, reason := "generation_replaced") -> int:
    ensure_autonomy_system()
    if autonomy_system == null:
        return 0
    return autonomy_system.release_npc_traffic_generation(entry, reason)

func cleanup_npc_route_state(actor_id: String, entry := {}, reason := "cleanup") -> Dictionary:
    var route_state_released := 0
    var entry_dict: Dictionary = entry if entry is Dictionary else {}
    if not entry_dict.is_empty():
        for key in [
            "pathWaypoints",
            "routeCells",
            "routeActions",
            "routeSnapshotRevision",
            "routeForceReplan",
            "activeTrafficStepGroup",
            "activeDoorPortalId",
            "activeDoorActorId",
            "activeDoorDirection",
            "activeDoorTrafficGroupId",
            "jobReservationId",
            "jobApproachSlotId",
            "trafficWaitReason",
            "_yieldRetreatTicks",
            "_yieldRetreatDirection",
            "_yieldRetreatBlockerId"
        ]:
            if entry_dict.has(key):
                entry_dict.erase(key)
                route_state_released += 1
        NpcRouteStateStoreScript.write_status(entry_dict, "idle", reason, "NpcSystem.cleanup_npc_route_state")
    var avoidance := {}
    if pathing != null and pathing.has_method("cleanup_actor_state"):
        avoidance = pathing.cleanup_actor_state(actor_id)
    return {
        "routeState": route_state_released,
        "avoidance": int(avoidance.get("avoidance", 0)) if avoidance is Dictionary else 0,
        "avoidanceState": avoidance if avoidance is Dictionary else {}
    }

func npc_avoidance_registration_count() -> int:
    if pathing == null:
        return 0
    var locomotion = pathing.get("locomotion")
    if locomotion != null and locomotion.has_method("avoidance_stats"):
        return int(locomotion.avoidance_stats().get("registeredAgents", 0))
    return 0

func request_door_state(collider: Node, desired_open: bool, actor: Node = null, actor_kind := "system", metadata := {}):
    ensure_autonomy_system()
    var door := interaction_door_for_npc(collider)
    if door == null or not is_instance_valid(door):
        return null
    var was_open := bool(door.get_meta("open", false))
    var result = autonomy_system.request_door_state(door, desired_open, actor, actor_kind, metadata) if autonomy_system else null
    if result != null and String(result.get("status")) == "succeeded":
        var is_open := bool(door.get_meta("open", false))
        if is_open != was_open:
            if is_open:
                door_opens += 1
            else:
                door_closes += 1
    return result

func request_player_door_use(collider: Node, actor: Node = null, actor_kind := "player", metadata := {}):
    ensure_autonomy_system()
    var door := interaction_door_for_npc(collider)
    if door == null or not is_instance_valid(door):
        return null
    var was_open := bool(door.get_meta("open", false))
    var result = autonomy_system.request_player_door_use(door, actor, actor_kind, metadata) if autonomy_system else null
    if result != null and String(result.get("status")) == "succeeded":
        var is_open := bool(door.get_meta("open", false))
        if is_open != was_open:
            if is_open:
                door_opens += 1
            else:
                door_closes += 1
    return result

func update_door_policies(delta: float) -> void:
    var monitor = performance_monitor()
    if autonomy_system != null and autonomy_system.has_method("advance_traffic"):
        var traffic_already_advanced: bool = false
        if autonomy_system.has_method("consume_external_traffic_advance"):
            traffic_already_advanced = bool(autonomy_system.consume_external_traffic_advance())
        if not traffic_already_advanced:
            var traffic_start: int = monitor.begin_section("traffic_update") if monitor != null else Time.get_ticks_usec()
            autonomy_system.advance_traffic(delta, false)
            if monitor != null:
                monitor.end_section("traffic_update", traffic_start)
    process_pending_navigation_changes()
    var release_start: int = monitor.begin_section("door_hold_release") if monitor != null else Time.get_ticks_usec()
    release_completed_door_holds()
    if monitor != null:
        monitor.end_section("door_hold_release", release_start)
    if autonomy_system == null:
        return
    var actors_start: int = monitor.begin_section("door_actor_collect") if monitor != null else Time.get_ticks_usec()
    var actors := current_door_actors()
    if monitor != null:
        monitor.end_section("door_actor_collect", actors_start)
    var policy_start: int = monitor.begin_section("door_policy_process") if monitor != null else Time.get_ticks_usec()
    var result: Dictionary = autonomy_system.process_door_policies(delta, actors)
    if monitor != null:
        monitor.end_section("door_policy_process", policy_start)
    var closed := int(result.get("closed", 0))
    if closed > 0:
        door_closes += closed
        last_message = "NPC closed a door"

func current_door_actors() -> Array:
    var actors: Array = []
    if main != null and main.player != null and is_instance_valid(main.player):
        actors.append(main.player)
    for entry in npcs:
        var body := entry.get("body") as Node3D
        if body != null and is_instance_valid(body) and not actors.has(body):
            actors.append(body)
    return actors

func release_completed_door_holds() -> void:
    if autonomy_system == null:
        return
    for entry in npcs:
        var portal_id := String(entry.get("activeDoorPortalId", ""))
        if portal_id == "":
            continue
        if route_still_needs_active_door(entry, portal_id):
            continue
        var actor_id := String(entry.get("activeDoorActorId", entry.get("id", "")))
        autonomy_system.release_npc_door_hold(actor_id, true)
        clear_completed_door_action(entry, portal_id)
        entry.erase("activeDoorPortalId")
        entry.erase("activeDoorActorId")
        entry.erase("activeDoorDirection")
        entry.erase("activeDoorTrafficGroupId")
        entry.erase("_activeDoorForwardStep")
        entry.erase("portalRecenterTicks")

func route_still_needs_active_door(entry: Dictionary, portal_id: String) -> bool:
    if portal_id == "":
        return false
    if active_door_crossing_still_needs_hold(entry, portal_id):
        return true
    if active_door_crossing_has_cleared(entry, portal_id):
        return false
    if String(entry.get("routeStatus", "")) in ["arrived", "partial"] and (entry.get("pathWaypoints", []) as Array).is_empty():
        return false
    if active_private_home_door_can_release(entry, portal_id):
        return false
    var actions: Dictionary = entry.get("routeActions", {})
    for action_value in actions.values():
        if not (action_value is Dictionary):
            continue
        var action: Dictionary = action_value
        var action_door := interaction_door_for_npc(action.get("door") as Node)
        if action_door == null:
            continue
        var action_portal_id := ""
        if autonomy_system != null and autonomy_system.door_portals != null:
            action_portal_id = autonomy_system.door_portals.resolve_portal_id(action_door, "")
        if action_portal_id == portal_id and route_still_needs_door(entry, action):
            return true
    return false

func active_private_home_door_can_release(entry: Dictionary, portal_id: String) -> bool:
    if autonomy_system == null or autonomy_system.door_portals == null:
        return false
    var portal = autonomy_system.door_portals.portals.get(portal_id)
    if portal == null or String(portal.get("policy_id")) != "private_home":
        return false
    if route_has_active_door_action(entry, portal_id):
        return false
    var active_goal = entry.get("activeMotionGoal", {})
    if active_goal is Dictionary and String((active_goal as Dictionary).get("goalKind", "")) == String(NpcEnumsScript.GOAL_KIND_HOME):
        return false
    if bool(entry.get("routeMovingHome", false)):
        return false
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return true
    if autonomy_system.has_method("is_inside_home_interior") and bool(autonomy_system.is_inside_home_interior(entry, body.global_position)):
        return false
    return true

func route_has_active_door_action(entry: Dictionary, portal_id: String) -> bool:
    var actions: Dictionary = entry.get("routeActions", {})
    for action_value in actions.values():
        if not (action_value is Dictionary):
            continue
        var action: Dictionary = action_value
        if String(action.get("kind", "")) != "door":
            continue
        if String(action.get("portalId", "")) == portal_id:
            return true
        var action_door := interaction_door_for_npc(action.get("door") as Node)
        if action_door == null:
            continue
        if autonomy_system != null and autonomy_system.door_portals != null and autonomy_system.door_portals.resolve_portal_id(action_door, "") == portal_id:
            return true
    return false

func active_door_crossing_still_needs_hold(entry: Dictionary, portal_id: String) -> bool:
    if autonomy_system == null or autonomy_system.door_portals == null:
        return false
    var portal = autonomy_system.door_portals.portals.get(portal_id)
    if portal == null:
        return false
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return false
    if not portal.occupied_actors([body], "threshold").is_empty() \
            or not portal.occupied_actors([body], "sweep").is_empty():
        return true
    var direction := String(entry.get("activeDoorDirection", ""))
    if direction == "":
        return false
    var center: Vector3 = portal.threshold_bounds.position + portal.threshold_bounds.size * 0.5
    if direction == "x+":
        return body.global_position.x <= center.x + DOOR_TRAFFIC_RELEASE_RADIUS
    if direction == "x-":
        return body.global_position.x >= center.x - DOOR_TRAFFIC_RELEASE_RADIUS
    if direction == "z+":
        return body.global_position.z <= center.z + DOOR_TRAFFIC_RELEASE_RADIUS
    if direction == "z-":
        return body.global_position.z >= center.z - DOOR_TRAFFIC_RELEASE_RADIUS
    return false

func active_door_crossing_has_cleared(entry: Dictionary, portal_id: String) -> bool:
    if autonomy_system == null or autonomy_system.door_portals == null:
        return false
    var portal = autonomy_system.door_portals.portals.get(portal_id)
    if portal == null:
        return false
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return false
    var direction := String(entry.get("activeDoorDirection", ""))
    if direction == "":
        return false
    var center: Vector3 = portal.threshold_bounds.position + portal.threshold_bounds.size * 0.5
    if direction == "x+":
        return body.global_position.x > center.x + DOOR_TRAFFIC_RELEASE_RADIUS
    if direction == "x-":
        return body.global_position.x < center.x - DOOR_TRAFFIC_RELEASE_RADIUS
    if direction == "z+":
        return body.global_position.z > center.z + DOOR_TRAFFIC_RELEASE_RADIUS
    if direction == "z-":
        return body.global_position.z < center.z - DOOR_TRAFFIC_RELEASE_RADIUS
    return false

func clear_completed_door_action(entry: Dictionary, portal_id: String) -> void:
    if portal_id == "":
        return
    var actions: Dictionary = entry.get("routeActions", {})
    if actions.is_empty():
        return
    for key in actions.keys().duplicate():
        var action_value = actions.get(key)
        if not (action_value is Dictionary):
            continue
        var action: Dictionary = action_value
        var action_door := interaction_door_for_npc(action.get("door") as Node)
        if action_door == null:
            continue
        var action_portal_id := ""
        if autonomy_system != null and autonomy_system.door_portals != null:
            action_portal_id = autonomy_system.door_portals.resolve_portal_id(action_door, "")
        if action_portal_id == portal_id:
            actions.erase(key)
    entry["routeActions"] = actions
    prune_completed_door_route_prefix(entry)

func prune_completed_door_route_prefix(entry: Dictionary) -> void:
    var direction := String(entry.get("activeDoorDirection", ""))
    if direction == "":
        return
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return
    var current_cell := flat_cell_for_position(body.global_position)
    var cells: Array = entry.get("routeCells", [])
    var waypoints: Array = entry.get("pathWaypoints", [])
    var removed := 0
    while not cells.is_empty() and cells[0] is Vector2i and route_cell_is_behind_active_door_clearance(cells[0], current_cell, direction):
        cells.remove_at(0)
        removed += 1
    while removed > 0 and not waypoints.is_empty():
        waypoints.remove_at(0)
        removed -= 1
    entry["routeCells"] = cells
    entry["pathWaypoints"] = waypoints

func route_cell_is_behind_active_door_clearance(cell: Vector2i, current_cell: Vector2i, direction: String) -> bool:
    if direction == "x+":
        return cell.x <= current_cell.x
    if direction == "x-":
        return cell.x >= current_cell.x
    if direction == "z+":
        return cell.y <= current_cell.y
    if direction == "z-":
        return cell.y >= current_cell.y
    return false

func npc_route_holds_door_open(door: Node) -> bool:
    if door == null or not is_instance_valid(door):
        return false
    var normalized_door := interaction_door_for_npc(door)
    for entry in npcs:
        var body := entry.get("body") as Node3D
        if body == null or not is_instance_valid(body):
            continue
        if String(entry.get("routeStatus", "")) in ["arrived", "partial"] and (entry.get("pathWaypoints", []) as Array).is_empty():
            continue
        var actions: Dictionary = entry.get("routeActions", {})
        for action_value in actions.values():
            if not (action_value is Dictionary):
                continue
            var action: Dictionary = action_value
            var action_door := interaction_door_for_npc(action.get("door") as Node)
            if action_door == normalized_door and route_still_needs_door(entry, action):
                return true
    return false

func route_still_needs_door(entry: Dictionary, action: Dictionary) -> bool:
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return false
    var action_door := action.get("door") as Node3D
    var cell_value = action.get("cell")
    if not (cell_value is Vector2i):
        if action_door == null or not is_instance_valid(action_door):
            return false
        return body.global_position.distance_to(action_door.global_position) <= DOOR_TRAFFIC_RELEASE_RADIUS
    var door_cell: Vector2i = cell_value
    var goal_cell: Vector2i = entry.get("routeGoalCell", door_cell)
    var goal_delta := goal_cell - door_cell
    var door_position := Vector3(float(door_cell.x) * CELL, body.global_position.y, float(door_cell.y) * CELL)
    if action_door != null and is_instance_valid(action_door):
        door_position = action_door.global_position
    if abs(goal_delta.x) >= abs(goal_delta.y) and goal_delta.x != 0:
        if goal_delta.x > 0:
            return body.global_position.x <= door_position.x + DOOR_TRAFFIC_RELEASE_RADIUS
        return body.global_position.x >= door_position.x - DOOR_TRAFFIC_RELEASE_RADIUS
    if goal_delta.y != 0:
        if goal_delta.y > 0:
            return body.global_position.z <= door_position.z + DOOR_TRAFFIC_RELEASE_RADIUS
        return body.global_position.z >= door_position.z - DOOR_TRAFFIC_RELEASE_RADIUS
    return body.global_position.distance_to(door_position) <= DOOR_TRAFFIC_RELEASE_RADIUS

func interaction_door_for_npc(collider: Node) -> Node:
    if collider == null:
        return null
    if main != null and main.has_method("interaction_block_from_collider"):
        var interaction_block = main.interaction_block_from_collider(collider)
        if interaction_block != null and interaction_block is Node:
            return interaction_block
    return collider

func move_npc(entry: Dictionary, target: Vector3, max_distance: float, moving_home := false, allow_outside := false, physics_delta := 0.0166667) -> float:
    if pathing == null:
        return 0.0
    if not moving_home:
        clear_home_route_terminal(entry)
    var external_direct_move := false
    if not npc_update_active and pathing.has_method("begin_frame"):
        var physics_frame := Engine.get_physics_frames()
        if external_move_budget_physics_frame != physics_frame:
            pathing.begin_frame()
            external_move_budget_physics_frame = physics_frame
        entry["_externalDirectMoveFrame"] = physics_frame
        external_direct_move = true
    var moved: float = float(pathing.move_npc(entry, target, max_distance, moving_home, allow_outside, physics_delta))
    if external_direct_move:
        entry.erase("_externalDirectMoveFrame")
    return moved

func apply_npc_route_motion(entry: Dictionary, previous: Vector3, candidate: Vector3, physics_delta: float) -> Dictionary:
    if motion_controller == null:
        return { "moved": 0.0, "blocked": true, "reason": "missing_motion_controller", "position": previous }
    return motion_controller.apply_route_motion(entry, previous, candidate, physics_delta)

func choose_day_target(entry: Dictionary) -> Vector3:
    if pathing == null:
        return entry.get("porchPosition", Vector3.ZERO)
    return pathing.choose_day_target(entry)

func choose_job_target(entry: Dictionary) -> Vector3:
    if pathing == null:
        return entry.get("porchPosition", Vector3.ZERO)
    return pathing.choose_job_target(entry)

func choose_guard_target(entry: Dictionary, target_hostile = null, melee := false) -> Vector3:
    if pathing == null:
        return entry.get("guardPosition", entry.get("porchPosition", Vector3.ZERO))
    return pathing.choose_guard_target(entry, valid_hostile_node(target_hostile), melee)

func point_inside_town(entry: Dictionary, position: Vector3) -> bool:
    if pathing == null:
        var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
        var radius := float(entry.get("townRadius", 18)) * CELL
        var flat := Vector2(position.x - float(center.x) * CELL, position.z - float(center.y) * CELL)
        return flat.length() <= radius
    return pathing.point_inside_town(entry, position)

func point_inside_town_footprint(entry: Dictionary, position: Vector3, margin_cells := 0) -> bool:
    var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
    var radius := maxi(0, int(entry.get("townRadius", 18)) + margin_cells)
    var cell := flat_cell_for_position(position)
    return absi(cell.x - center.x) <= radius and absi(cell.y - center.y) <= radius

func point_inside_work_area(entry: Dictionary, position: Vector3) -> bool:
    if pathing == null:
        var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
        var radius := (float(entry.get("townRadius", 18)) + 24.0) * CELL
        var flat := Vector2(position.x - float(center.x) * CELL, position.z - float(center.y) * CELL)
        return flat.length() <= radius
    return pathing.point_inside_work_area(entry, position)

func nearest_hostile(origin: Vector3, radius: float, owner: Node = null, prefer_clear_shot := false) -> Node3D:
    if combat == null:
        return null
    return combat.nearest_hostile(origin, radius, owner, prefer_clear_shot)

func scripted_combat_target(entry: Dictionary, body: Node3D, radius := 42.0) -> Node3D:
    if hostile_system == null or body == null or not is_instance_valid(body):
        return null
    if hostile_system.has_method("nearest_scripted_encounter_hostile_for_npc"):
        var target = hostile_system.nearest_scripted_encounter_hostile_for_npc(body, body.global_position, radius)
        if target is Node3D:
            return target
    return null

func fire_at_hostile(entry: Dictionary, target: Node3D) -> void:
    if combat == null:
        return
    combat.fire_at_hostile(entry, target)

func strike_hostile(entry: Dictionary, target: Node3D) -> void:
    if combat == null:
        return
    combat.strike_hostile(entry, target)

func npc_weapon_is_ranged(weapon_id: String) -> bool:
    return visual_factory.npc_weapon_is_ranged(weapon_id)

func npc_weapon_is_melee(weapon_id: String) -> bool:
    return visual_factory.npc_weapon_is_melee(weapon_id)

func ensure_npc_held_item(entry: Dictionary) -> void:
    visual_factory.ensure_held_item(entry)

func add_npc_collider(parent: Node3D) -> void:
    visual_factory.add_collider(parent)

func add_npc_visual(parent: Node3D, body_material: StandardMaterial3D, accent_material: StandardMaterial3D, npc_name: String, role: String, can_fight := false) -> void:
    visual_factory.add_visual(parent, body_material, accent_material, npc_name, role)

func notify_navigation_block_created(cell: Vector3i, block_type: String, block: Node = null) -> void:
    if autonomy_system:
        autonomy_system.notify_block_created(cell, block_type, block)
        navigation_change_flush_pending = true

func notify_navigation_block_removed(cell: Vector3i, block_type: String, block: Node = null) -> void:
    if autonomy_system:
        autonomy_system.notify_block_removed(cell, block_type, block)
        navigation_change_flush_pending = true

func notify_navigation_terrain_edited(cell: Vector2i, old_height: float, new_height: float) -> void:
    if autonomy_system:
        autonomy_system.notify_terrain_edited(cell, old_height, new_height)
        flush_navigation_change_bus()

func notify_navigation_terrain_cells_edited(cells: Array) -> void:
    if autonomy_system == null:
        return
    if autonomy_system.has_method("notify_terrain_cells_edited"):
        var emitted_tiles := int(autonomy_system.notify_terrain_cells_edited(cells))
        if emitted_tiles > 0:
            navigation_change_flush_pending = true
        return
    var emitted := 0
    for value in cells:
        if not (value is Vector2i):
            continue
        var cell: Vector2i = value
        var height := navigation_height_for_cell(cell)
        autonomy_system.notify_terrain_edited(cell, height, height)
        emitted += 1
    if emitted > 0:
        navigation_change_flush_pending = true

func navigation_height_for_cell(cell: Vector2i) -> float:
    if main == null:
        return 0.0
    var fallback := 0.0
    if main.has_method("surface_y_at_cell"):
        fallback = float(main.call("surface_y_at_cell", Vector3i(cell.x, 0, cell.y)))
    var world_generation = main.get("world_generation_system")
    if world_generation != null and world_generation.has_method("surface_projection_for_cell"):
        var start_cell := Vector3i(cell.x, floori(fallback / main.CELL), cell.y)
        var projection: Dictionary = world_generation.call("surface_projection_for_cell", start_cell, 24, 96)
        if not projection.is_empty() and bool(projection.get("found", false)):
            var air_cell: Vector3i = projection.get("airCell", start_cell + Vector3i(0, 1, 0))
            return float(air_cell.y) * main.CELL
    return fallback

func notify_navigation_prop_created(prop_id: String, prop: Node = null) -> void:
    if autonomy_system:
        autonomy_system.notify_prop_created(prop_id, prop)
        navigation_change_flush_pending = true

func notify_navigation_prop_removed(prop_id: String, prop: Node = null) -> void:
    if autonomy_system:
        autonomy_system.notify_prop_removed(prop_id, prop)
        navigation_change_flush_pending = true

func notify_navigation_chunk_loaded(chunk_key: Vector2i) -> void:
    if autonomy_system:
        autonomy_system.notify_chunk_loaded(chunk_key)
        # Chunk streaming runs before the NPC phase. Retain the invalidation and
        # let update_door_policies consume it through the existing bounded event
        # budget later in this frame instead of rebuilding route state inside the
        # terrain publication call.
        navigation_change_flush_pending = true

func notify_navigation_prop_unloaded(prop_id: String, prop: Node) -> Dictionary:
    if autonomy_system == null:
        return {"status":"failed", "reason":"missing_autonomy_owner"}
    var result: Dictionary = autonomy_system.notify_prop_unloaded(prop_id, prop)
    if result.get("status") in ["unregistered", "absent"]:
        navigation_change_flush_pending = true
    return result

func notify_navigation_chunk_unloaded(chunk_key: Vector2i) -> void:
    if autonomy_system:
        autonomy_system.notify_chunk_unloaded(chunk_key)
        navigation_change_flush_pending = true

func notify_navigation_door_state_changed(door: Node, open: bool) -> void:
    if autonomy_system:
        autonomy_system.notify_door_state_changed(door, open)
        flush_navigation_change_bus()

func process_navigation_route_changes(events: Array) -> Array[Dictionary]:
    if pathing == null:
        return []
    return pathing.process_navigation_events(events)

func notify_navigation_door_registered(door: Node) -> void:
    if autonomy_system:
        autonomy_system.notify_door_registered(door)
        navigation_change_flush_pending = true

func notify_navigation_structure_metadata_changed(structure_id: String, bounds: AABB, metadata := {}) -> void:
    if autonomy_system:
        autonomy_system.notify_structure_metadata_changed(structure_id, bounds, metadata)
        flush_navigation_change_bus()

func notify_navigation_door_unregistered(door: Node) -> Dictionary:
    if autonomy_system == null:
        return {"status":"failed", "reason":"missing_autonomy_owner"}
    var result: Dictionary = autonomy_system.notify_door_unregistered(door)
    if result.get("status") == "unregistered":
        navigation_change_flush_pending = true
    return result

func notify_navigation_semantic_changed(semantic_id: String, bounds: AABB, metadata := {}) -> void:
    if autonomy_system:
        autonomy_system.notify_semantic_changed(semantic_id, bounds, metadata)
        flush_navigation_change_bus()

func flush_navigation_change_bus() -> void:
    if autonomy_system != null and autonomy_system.has_method("process_navigation_changes"):
        autonomy_system.process_navigation_changes()
        navigation_change_flush_pending = false

## Startup disables the gameplay/NPC process loop while streamed terrain is
## published. Keep chunk invalidation out of the terrain callback, but expose
## the same bounded consumer so the loading owner can advance it once per frame.
func process_pending_navigation_changes() -> int:
    if autonomy_system == null or not autonomy_system.has_method("process_navigation_changes"):
        return 0
    var frame := Engine.get_process_frames()
    if navigation_change_process_frame == frame:
        return 0
    var pending_count := int(autonomy_system.pending_navigation_change_count()) if autonomy_system.has_method("pending_navigation_change_count") else 0
    if not navigation_change_flush_pending and pending_count <= 0:
        return 0
    navigation_change_process_frame = frame
    var monitor = performance_monitor()
    var nav_change_start: int = monitor.begin_section("navigation_change_process") if monitor != null else Time.get_ticks_usec()
    var events: Array = autonomy_system.process_navigation_changes(
        NAVIGATION_PROP_CHANGE_EVENTS_PER_FRAME,
        NAVIGATION_PROP_CHANGE_OBJECT_IDS_PER_FRAME
    )
    if monitor != null:
        monitor.end_section("navigation_change_process", nav_change_start)
    pending_count = int(autonomy_system.pending_navigation_change_count()) if autonomy_system.has_method("pending_navigation_change_count") else 0
    navigation_change_flush_pending = pending_count > 0
    return events.size()

func cell_to_position(cell: Vector2i, level: float) -> Vector3:
    return Vector3(float(cell.x) * CELL, level + 0.04, float(cell.y) * CELL)

func flat_cell_for_position(position: Vector3) -> Vector2i:
    return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

func stats() -> Dictionary:
    return NpcStatsScript.build(self)
