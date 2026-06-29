extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const TEST_ID := "npc_tutorial_real_knock_repair_sleep_morning_foragers"
const CELL := 1.35
const STARTUP_FRAMES := 80
const POST_ACTION_FRAMES := 24
const SAMPLE_EVERY_FRAMES := 6
const MIRA_HOME_TIMEOUT_SECONDS := 36.0
const MIRA_HOME_SETTLED_FRAMES := 30
const MORNING_FORAGE_TIMEOUT_SECONDS := 70.0
const CAPTURE_WIDTH := 1280
const CAPTURE_HEIGHT := 720

var main: Node3D
var player: CharacterBody3D
var camera: Camera3D
var observer_camera: Camera3D
var observer_torch: OmniLight3D
var elapsed := 0.0
var finished := false
var failed := false
var report_data := {}
var results: Array[Dictionary] = []
var failure_reasons: Array[Dictionary] = []
var player_timeline: Array[Dictionary] = []
var door_timeline: Array[Dictionary] = []
var mira_timeline: Array[Dictionary] = []
var mira_speed_samples: Array[Dictionary] = []
var route_order_timeline: Array[Dictionary] = []
var schedule_matrix: Array[Dictionary] = []
var night_matrix: Dictionary = {}
var repair_placement_events: Array[Dictionary] = []
var sleep_timeline: Array[Dictionary] = []
var inventory_timeline: Array[Dictionary] = []
var interaction_timeline: Array[Dictionary] = []
var morning_departure_matrix: Array[Dictionary] = []
var niko_timeline: Array[Dictionary] = []
var visual_captures: Array[Dictionary] = []
var niko_proof := {}
var max_mira_flat_speed := 0.0
var mira_total_flat_distance := 0.0
var previous_mira_position := Vector3.ZERO
var previous_mira_valid := false
var previous_mira_elapsed := 0.0
var physics_dt := 1.0 / 60.0
var gameplay_started := false
var screenshot_dir := ""
var visual_required := false
var mira_home_only := false
var captured_mira_start := false
var captured_mira_at_door := false
var captured_mira_door_open := false
var captured_mira_inside_closed := false

func _ready() -> void:
    physics_dt = 1.0 / float(Engine.physics_ticks_per_second)
    configure_visual_capture()
    call_deferred("run")

func _process(delta: float) -> void:
    if finished:
        return
    elapsed += delta
    var limit := watchdog_seconds()
    if elapsed > limit:
        add_failure("runner_watchdog", "runner exceeded %.1f seconds" % limit)
        finish()

func configure_visual_capture() -> void:
    visual_required = OS.get_environment("VOXEL_REAL_TUTORIAL_VISUAL_REQUIRED").strip_edges() == "1"
    mira_home_only = OS.get_environment("VOXEL_REAL_TUTORIAL_MIRA_HOME_ONLY").strip_edges() == "1"
    screenshot_dir = OS.get_environment("VOXEL_REAL_TUTORIAL_SCREENSHOT_DIR")
    if screenshot_dir == "":
        screenshot_dir = ProjectSettings.globalize_path("res://artifacts/npc/screenshots/real-tutorial-playthrough")
    ensure_dir(screenshot_dir)

func run() -> void:
    mark_progress("start")
    report_data = {
        "schemaVersion": 1,
        "testId": TEST_ID,
        "seed": OS.get_environment("VOXEL_TEST_SEED").strip_edges(),
        "runToken": OS.get_environment("VOXEL_REAL_TUTORIAL_RUN_TOKEN"),
        "gitBranch": OS.get_environment("VOXEL_GIT_BRANCH"),
        "gitCommit": OS.get_environment("VOXEL_GIT_COMMIT"),
        "nonHeadlessVisualRequired": visual_required,
        "miraHomeOnly": mira_home_only,
        "screenshotDir": screenshot_dir,
        "visualCaptures": visual_captures,
        "deterministicSetup": {},
        "scriptErrorScan": { "status": "pending-wrapper-scan", "matches": [] },
        "forbiddenCallSelfScan": { "status": "passed-by-wrapper-before-launch" }
    }

    main = MAIN_SCENE.instantiate()
    add_child(main)
    mark_progress("main_instantiated")
    await wait_physics_frames(30)
    bind_scene_nodes()
    await prepare_tutorial_world()
    await wait_physics_frames(STARTUP_FRAMES)
    bind_scene_nodes()

    if main == null or player == null or camera == null:
        add_failure("scene_bootstrap_failed", "main/player/camera missing")
        finish()
        return

    player.set("automated_input", true)
    player.set("automated_move", Vector3.ZERO)
    player.set("automated_sprint", false)
    Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
    setup_observer_camera()
    gameplay_started = true
    mark_progress("gameplay_started")

    await run_real_knock_to_morning_foragers()
    finish()

func prepare_tutorial_world() -> void:
    var tutorial = main.get("tutorial_system") if main != null else null
    if tutorial != null and tutorial.has_method("start_new_world"):
        var started := bool(tutorial.call("start_new_world"))
        report_data["deterministicSetup"] = {
            "usedTutorialWorldResetBeforeInput": true,
            "started": started
        }
    else:
        report_data["deterministicSetup"] = {
            "usedTutorialWorldResetBeforeInput": false,
            "started": false
        }
    if main != null and main.has_method("update_chunks"):
        main.call("update_chunks", true)
    if main != null and main.has_method("refresh_intro_knock_audio"):
        main.call("refresh_intro_knock_audio")
    await wait_physics_frames(20)

func run_real_knock_to_morning_foragers() -> void:
    var tutorial = main.get("tutorial_system")
    var before_state := tutorial_state_summary(tutorial)
    report_data["initialTutorialState"] = before_state
    sample_player("initial")
    var starter_door := nearest_block("door", player.global_position)
    if starter_door == null:
        add_failure("starter_door_missing", "no door block found near tutorial start")
        return
    sample_door("initial", starter_door)

    var door_position := starter_door.global_position
    mark_progress("walking_to_door")
    await walk_near(door_position, CELL * 1.55, 9.0)
    sample_player("near_door")
    aim_at(door_position + Vector3(0.0, CELL * 0.75, 0.0))
    await wait_physics_frames(POST_ACTION_FRAMES)
    sample_door("before_click", starter_door)
    mark_progress("dispatching_door_action")
    dispatch_mouse_button(MOUSE_BUTTON_RIGHT, true)
    dispatch_mouse_button(MOUSE_BUTTON_RIGHT, false)
    await wait_physics_frames(POST_ACTION_FRAMES)
    sample_door("after_click", starter_door)
    sample_player("after_door_action")

    var after_state := tutorial_state_summary(tutorial)
    report_data["afterDoorTutorialState"] = after_state
    var opened := bool(after_state.get("doorOpened", false))
    var dialogue_open := hud_dialogue_open()
    results.append({
        "name": "real_door_input_opened_tutorial_dialogue",
        "passed": opened and dialogue_open,
        "details": "doorOpened=%s dialogueOpen=%s" % [str(opened), str(dialogue_open)]
    })
    if not opened or not dialogue_open:
        add_failure("real_input_path_failed_before_mira_observation", "doorOpened=%s dialogueOpen=%s" % [str(opened), str(dialogue_open)])
        return

    mark_progress("closing_dialogue")
    dispatch_key(KEY_ESCAPE, true)
    dispatch_key(KEY_ESCAPE, false)
    await wait_physics_frames(POST_ACTION_FRAMES)
    report_data["afterDialogueTutorialState"] = tutorial_state_summary(tutorial)
    sample_player("after_dialogue_ack")
    if hud_dialogue_open():
        add_failure("dialogue_still_open_after_real_ack", "HUD dialogue remained open after Escape close input")
        return
    if not bool(report_data["afterDialogueTutorialState"].get("elderAcknowledged", false)):
        add_failure("mira_dialogue_ack_not_recorded", "tutorial state did not record elder acknowledgement after HUD close")
        return

    mark_progress("observing_mira_return_home")
    await observe_mira_until_home(MIRA_HOME_TIMEOUT_SECONDS)
    if visual_required and not captured_mira_inside_closed:
        await capture_mira_stage("mira_timeout_final_state", "front")
    var mira := npc_entry("mira")
    var speed_limit := profile_speed_limit(mira)
    report_data["miraSpeedLimit"] = rounded(speed_limit)
    report_data["miraMaxFlatSpeed"] = rounded(max_mira_flat_speed)
    report_data["miraTotalFlatDistance"] = rounded(mira_total_flat_distance)
    report_data["miraFinalHomeInteriorStatus"] = strict_home_status(mira)
    if max_mira_flat_speed > speed_limit:
        add_failure(
            "mira_non_profile_speed",
            "max flat speed %.3f exceeded profile limit %.3f" % [max_mira_flat_speed, speed_limit]
        )
    elif mira_total_flat_distance < CELL * 0.4:
        add_failure(
            "mira_stalls_due_to_update_budget",
            "Mira moved only %.3f meters during observation" % mira_total_flat_distance
        )
    else:
        results.append({
            "name": "mira_timeline_speed_within_profile",
            "passed": true,
            "details": "max flat speed %.3f <= %.3f" % [max_mira_flat_speed, speed_limit]
        })
    if not bool(report_data["miraFinalHomeInteriorStatus"].get("strictInside", false)):
        add_failure("mira_did_not_reach_strict_home_interior", JSON.stringify(report_data["miraFinalHomeInteriorStatus"]))
    elif visual_required and not required_mira_captures_saved():
        add_failure("mira_visual_captures_missing", JSON.stringify(capture_names()))
    elif mira_home_only:
        results.append({
            "name": "mira_real_tutorial_go_home_visual",
            "passed": true,
            "details": "Mira reached strict home interior and the home door closed; captures=%s" % JSON.stringify(capture_names())
        })
    if mira_home_only:
        return
    await observe_night_matrix_until_ready(120.0)
    night_matrix = validate_night_matrix()
    report_data["nightGuardNonGuardMatrix"] = night_matrix

    mark_progress("checking_bed_locked_before_repair")
    await attempt_sleep_before_repair(tutorial)

    mark_progress("running_repair_flow")
    await run_repair_flow(tutorial)

    mark_progress("sleeping_after_repair")
    await attempt_sleep_after_repair(tutorial)

    mark_progress("observing_morning_foragers")
    await observe_morning_npcs_and_foragers(MORNING_FORAGE_TIMEOUT_SECONDS)

    report_data["nikoForagerState"] = forager_state_summary()
    report_data["repairTargetPlacementProof"] = repair_target_proof(tutorial)
    report_data["sleepTransitionProof"] = sleep_transition_proof(tutorial)
    report_data["morningNpcDepartureMatrix"] = morning_departure_matrix
    report_data["nikoForageProof"] = niko_proof

func observe_npcs_for_seconds(seconds: float) -> void:
    var frame_count := ceili(seconds * float(Engine.physics_ticks_per_second))
    for frame in range(frame_count):
        await get_tree().physics_frame
        track_mira_speed()
        if frame % SAMPLE_EVERY_FRAMES == 0:
            sample_player("observe_%03d" % frame)
            sample_mira("observe_%03d" % frame)
            route_order_timeline.append(route_order_sample("observe_%03d" % frame))
            schedule_matrix = npc_schedule_matrix()
            mark_progress("observing_%03d" % frame)

func observe_mira_until_home(seconds: float) -> void:
    var frame_count := ceili(seconds * float(Engine.physics_ticks_per_second))
    var settled_frames := 0
    for frame in range(frame_count):
        await get_tree().physics_frame
        track_mira_speed()
        var mira := npc_entry("mira")
        var home_status := strict_home_status(mira)
        if visual_required:
            await maybe_capture_mira_return_home(frame, mira, home_status)
        var strict_inside := bool(home_status.get("strictInside", false))
        var visual_settled := true
        if visual_required:
            visual_settled = captured_mira_inside_closed and not any_mira_home_door_open(mira)
        if strict_inside and visual_settled:
            settled_frames += 1
        else:
            settled_frames = 0
        if frame % SAMPLE_EVERY_FRAMES == 0:
            sample_player("mira_home_%03d" % frame)
            sample_mira("mira_home_%03d" % frame)
            route_order_timeline.append(route_order_sample("mira_home_%03d" % frame))
            schedule_matrix = npc_schedule_matrix()
            mark_progress("mira_home_%03d" % frame)
        if settled_frames >= MIRA_HOME_SETTLED_FRAMES:
            break

func maybe_capture_mira_return_home(frame: int, mira: Dictionary, home_status: Dictionary) -> void:
    if mira.is_empty():
        return
    if not captured_mira_start:
        await capture_mira_stage("mira_go_home_start", "wide")
        captured_mira_start = true
    var door := mira_home_door(mira)
    if door == null:
        return
    var body := mira.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return
    var distance_to_door := flat_distance(body.global_position, door.global_position)
    var door_open := bool(door.get_meta("open", false))
    if not captured_mira_at_door and distance_to_door <= CELL * 1.9:
        await capture_mira_stage("mira_at_home_door", "front")
        captured_mira_at_door = true
    if not captured_mira_door_open and door_open:
        await capture_mira_stage("mira_home_door_open", "front")
        captured_mira_door_open = true
    if not captured_mira_inside_closed and bool(home_status.get("strictInside", false)) and not any_mira_home_door_open(mira):
        await capture_mira_stage("mira_inside_home_closed_door", "inside")
        captured_mira_inside_closed = true

func setup_observer_camera() -> void:
    if observer_camera != null and is_instance_valid(observer_camera):
        return
    observer_camera = Camera3D.new()
    observer_camera.name = "RealTutorialMiraObserverCamera"
    observer_camera.fov = 62.0
    observer_camera.near = 0.04
    add_child(observer_camera)
    observer_torch = OmniLight3D.new()
    observer_torch.name = "RealTutorialObserverTorch"
    observer_torch.light_color = Color(1.0, 0.72, 0.42)
    observer_torch.light_energy = 3.8
    observer_torch.omni_range = CELL * 9.0
    observer_torch.shadow_enabled = false
    observer_torch.set_meta("visual_test_torch", true)
    observer_camera.add_child(observer_torch)

func capture_mira_stage(stage: String, camera_mode: String) -> void:
    setup_observer_camera()
    position_mira_observer_camera(camera_mode)
    configure_observer_torch(camera_mode)
    await wait_process_frames(3)
    var image := get_viewport().get_texture().get_image()
    var path := screenshot_dir.path_join("%s.png" % stage)
    var err := image.save_png(path)
    var mira := npc_entry("mira")
    var capture := {
        "stage": stage,
        "path": path,
        "saved": err == OK,
        "cameraMode": camera_mode,
        "time": rounded(elapsed),
        "sample": mira_visual_sample(mira)
    }
    visual_captures.append(capture)
    report_data["visualCaptures"] = visual_captures

func position_mira_observer_camera(mode: String) -> void:
    if observer_camera == null:
        return
    var mira := npc_entry("mira")
    var body := mira.get("body") as Node3D
    var body_position := body.global_position if body != null and is_instance_valid(body) else player.global_position
    var door := mira_home_door(mira)
    var door_position := door.global_position if door != null else body_position
    var home_position := entry_position(mira, "homePosition", door_position)
    var porch_position := entry_position(mira, "porchPosition", door_position)
    var level := maxf(home_position.y, body_position.y)
    var outside_direction := Vector3(porch_position.x - home_position.x, 0.0, porch_position.z - home_position.z)
    if outside_direction.length() < 0.05:
        outside_direction = Vector3(0.0, 0.0, -1.0)
    outside_direction = outside_direction.normalized()
    var side_direction := Vector3(-outside_direction.z, 0.0, outside_direction.x)
    var target := door_position + Vector3(0.0, CELL * 0.85, 0.0)
    var camera_position := door_position + outside_direction * CELL * 8.5 + Vector3(0.0, CELL * 3.2, 0.0)
    var camera_height := CELL * 3.2
    if mode == "wide":
        target = (body_position + home_position) * 0.5 + Vector3(0.0, CELL * 1.0, 0.0)
        camera_position = body_position + outside_direction * CELL * 7.0 + side_direction * CELL * 5.5 + Vector3(0.0, CELL * 5.0, 0.0)
        camera_height = CELL * 5.0
    elif mode == "inside":
        target = (body_position + door_position) * 0.5 + Vector3(0.0, CELL * 0.85, 0.0)
        camera_position = body_position - outside_direction * CELL * 2.15 + side_direction * CELL * 1.15 + Vector3(0.0, CELL * 1.05, 0.0)
        camera_height = CELL * 1.05
    if mode == "inside":
        camera_position.y = level + camera_height
    else:
        camera_position.y = maxf(camera_position.y, level + camera_height)
    observer_camera.global_position = camera_position
    observer_camera.look_at(target, Vector3.UP)
    observer_camera.make_current()

func configure_observer_torch(mode: String) -> void:
    if observer_torch == null or not is_instance_valid(observer_torch):
        return
    observer_torch.position = Vector3.ZERO
    observer_torch.visible = true
    if mode == "inside":
        observer_torch.light_energy = 5.5
        observer_torch.omni_range = CELL * 6.0
    elif mode == "wide":
        observer_torch.light_energy = 4.5
        observer_torch.omni_range = CELL * 12.0
    else:
        observer_torch.light_energy = 4.8
        observer_torch.omni_range = CELL * 10.0

func mira_visual_sample(mira: Dictionary) -> Dictionary:
    var body := mira.get("body") as Node3D
    var door := mira_home_door(mira)
    var position := body.global_position if body != null and is_instance_valid(body) else Vector3.ZERO
    return {
        "mira": npc_summary(mira) if not mira.is_empty() else {},
        "strictHome": strict_home_status(mira),
        "door": block_summary(door),
        "doorPortal": door_portal_summary(door),
        "doorOpen": bool(door.get_meta("open", false)) if door != null else false,
        "distanceToDoor": rounded(flat_distance(position, door.global_position)) if door != null else -1.0,
        "observerTorch": observer_torch_summary(),
        "position": vec3(position)
    }

func observer_torch_summary() -> Dictionary:
    if observer_torch == null or not is_instance_valid(observer_torch):
        return {}
    return {
        "enabled": observer_torch.visible,
        "energy": rounded(observer_torch.light_energy),
        "range": rounded(observer_torch.omni_range)
    }

func door_portal_summary(door: Node) -> Dictionary:
    if door == null or main == null:
        return {}
    var npc_system = main.get("npc_system")
    if npc_system == null:
        return {}
    var autonomy = npc_system.get("autonomy_system")
    if autonomy == null:
        return {}
    var door_portals = autonomy.get("door_portals")
    if door_portals == null or not door_portals.has_method("portal_for_door"):
        return {}
    var portal = door_portals.call("portal_for_door", door)
    if portal == null or not portal.has_method("to_summary"):
        return {}
    return portal.call("to_summary")

func mira_home_door(mira: Dictionary) -> Node3D:
    if mira.is_empty() or main == null:
        return null
    var blocks_value = main.get("blocks")
    if not (blocks_value is Dictionary):
        return null
    var porch_position := entry_position(mira, "porchPosition", entry_position(mira, "homePosition", Vector3.ZERO))
    var home_position := entry_position(mira, "homePosition", porch_position)
    var best: Node3D = null
    var best_distance := INF
    for block_value in (blocks_value as Dictionary).values():
        var block := block_value as Node3D
        if block == null or not is_instance_valid(block):
            continue
        if String(block.get_meta("block_type", "")) != "door":
            continue
        var distance := minf(flat_distance(block.global_position, porch_position), flat_distance(block.global_position, home_position))
        if distance < best_distance:
            best_distance = distance
            best = block
    return best

func any_mira_home_door_open(mira: Dictionary) -> bool:
    var door := mira_home_door(mira)
    if door == null:
        return false
    var group_id := String(door.get_meta("door_group_id", ""))
    var portal_id := String(door.get_meta("door_portal_id", ""))
    var blocks_value = main.get("blocks") if main != null else {}
    if not (blocks_value is Dictionary):
        return bool(door.get_meta("open", false))
    for block_value in (blocks_value as Dictionary).values():
        var block := block_value as Node
        if block == null or not is_instance_valid(block):
            continue
        if String(block.get_meta("block_type", "")) != "door":
            continue
        var same_group := group_id != "" and String(block.get_meta("door_group_id", "")) == group_id
        var same_portal := portal_id != "" and String(block.get_meta("door_portal_id", "")) == portal_id
        if (same_group or same_portal or block == door) and bool(block.get_meta("open", false)):
            return true
    return false

func required_mira_captures_saved() -> bool:
    if not visual_required:
        return true
    var required := ["mira_go_home_start", "mira_at_home_door", "mira_home_door_open", "mira_inside_home_closed_door"]
    var saved := {}
    for capture in visual_captures:
        if bool(capture.get("saved", false)):
            saved[String(capture.get("stage", ""))] = true
    for stage in required:
        if not bool(saved.get(stage, false)):
            return false
    return true

func capture_names() -> Array[String]:
    var names: Array[String] = []
    for capture in visual_captures:
        names.append(String(capture.get("stage", "")))
    return names

func observe_night_matrix_until_ready(seconds: float) -> void:
    var frame_count := ceili(seconds * float(Engine.physics_ticks_per_second))
    var settled_frames := 0
    for frame in range(frame_count):
        await get_tree().physics_frame
        track_mira_speed()
        if night_matrix_rows_ready(npc_schedule_matrix()):
            settled_frames += 1
        else:
            settled_frames = 0
        if frame % SAMPLE_EVERY_FRAMES == 0:
            sample_player("night_matrix_%03d" % frame)
            sample_mira("night_matrix_%03d" % frame)
            route_order_timeline.append(route_order_sample("night_matrix_%03d" % frame))
            schedule_matrix = npc_schedule_matrix()
            mark_progress("night_matrix_%03d" % frame)
        if settled_frames >= 30:
            break

func night_matrix_rows_ready(rows: Array) -> bool:
    if rows.is_empty():
        return false
    for row_value in rows:
        if not (row_value is Dictionary):
            return false
        var row: Dictionary = row_value
        var strict_inside := bool(row.get("strictInsideHome", false))
        var is_guard := bool(row.get("nightGuard", false))
        if is_guard:
            if strict_inside:
                return false
        elif not strict_inside:
            return false
    return true

func validate_night_matrix() -> Dictionary:
    var rows := npc_schedule_matrix()
    var failures: Array[Dictionary] = []
    for index in range(rows.size()):
        var row: Dictionary = rows[index]
        var npc_id := String(row.get("id", ""))
        var strict_inside := bool(row.get("strictInsideHome", false))
        var is_guard := bool(row.get("nightGuard", false))
        var goal: Dictionary = row.get("activeMotionGoal", {}) if row.get("activeMotionGoal", {}) is Dictionary else {}
        var goal_kind := String(goal.get("goalKind", ""))
        var route_status := String(row.get("routeStatus", ""))
        var passed := false
        var reason := ""
        if is_guard:
            passed = not strict_inside and (goal_kind == "guard" or route_status in ["moving", "arrived", "pending", "waiting"])
            reason = "guard_on_duty_or_en_route" if passed else "guard_not_on_duty"
        else:
            passed = strict_inside
            reason = "non_guard_inside" if passed else "non_guard_not_strictly_inside"
        row["nightMatrixPassed"] = passed
        row["nightMatrixReason"] = reason
        rows[index] = row
        if not passed:
            failures.append({
                "id": npc_id,
                "reason": reason,
                "nightGuard": is_guard,
                "canFight": bool(row.get("canFight", false)),
                "cell": row.get("cell", []),
                "homeCell": row.get("homeCell", []),
                "porchCell": row.get("porchCell", []),
                "homeRouteIndex": int(row.get("homeRouteIndex", 0)),
                "homeRouteCount": int(row.get("homeRouteCount", 0)),
                "homeActiveTargetCell": row.get("homeActiveTargetCell", []),
                "routeStatus": route_status,
                "routeReason": String(row.get("routeReason", "")),
                "goalKind": goal_kind
            })
    var matrix := {
        "passed": failures.is_empty(),
        "failures": failures,
        "rows": rows
    }
    report_data["nightGuardNonGuardMatrix"] = matrix
    if not failures.is_empty():
        add_failure("night_matrix_invalid", JSON.stringify(failures))
    else:
        results.append({ "name": "night_guard_non_guard_matrix", "passed": true, "details": "rows=%d" % rows.size() })
    return matrix

func attempt_sleep_before_repair(tutorial) -> void:
    var bed := find_tutorial_bed()
    if bed == null:
        add_failure("starter_bed_missing", "could not find tutorial starter bed")
        return
    var before := tutorial_state_summary(tutorial)
    var route_reached := await walk_intro_path_to_starter_bed(tutorial, "bed_before_repair_route")
    if not route_reached:
        return
    var bed_used := await use_bed_with_real_action(bed, "bed_before_repair", 10.0)
    if not bed_used:
        return
    await wait_physics_frames(POST_ACTION_FRAMES)
    var after := tutorial_state_summary(tutorial)
    var blocked := not bool(before.get("repairComplete", false)) and not bool(after.get("bedUsed", false)) and not bool(main.get("sleep_transition_active"))
    sleep_timeline.append({
        "label": "before_repair",
        "blocked": blocked,
        "before": before,
        "after": after,
        "sleepTransitionActive": bool(main.get("sleep_transition_active"))
    })
    if not blocked:
        add_failure("sleep_not_blocked_before_repair", JSON.stringify(sleep_timeline[sleep_timeline.size() - 1]))
    else:
        results.append({ "name": "sleep_blocked_before_repair", "passed": true, "details": "bed input did not sleep before repair" })

func run_repair_flow(tutorial) -> void:
    var chest := find_intro_repair_chest()
    if chest == null:
        add_failure("intro_repair_chest_missing", "could not find repair chest")
        return
    var chest_route_reached := await walk_intro_path_to_town_center(tutorial, "repair_chest_route")
    if not chest_route_reached:
        return
    var chest_used := await use_block_with_real_action(chest, "repair_chest", CELL * 1.75, 14.0)
    if not chest_used:
        return
    await wait_physics_frames(POST_ACTION_FRAMES)
    var utility_open := main.get("utility_system") != null and bool(main.get("utility_system").call("is_open"))
    var hud_open := main.get("hud") != null and bool(main.get("hud").call("is_utility_open"))
    var chest_state := tutorial_state_summary(tutorial)
    inventory_timeline.append({ "label": "repair_chest_open", "utilityOpen": utility_open, "hudOpen": hud_open, "tutorialState": chest_state, "inventory": inventory_totals() })
    if not utility_open or not hud_open or not bool(chest_state.get("repairChestOpened", false)):
        add_failure("repair_chest_real_open_failed", JSON.stringify(inventory_timeline[inventory_timeline.size() - 1]))
        return
    await press_utility_slot(0, "take_logs")
    await press_utility_slot(1, "take_stones")
    await press_utility_slot(2, "take_berries")
    inventory_timeline.append({ "label": "repair_chest_withdrawn", "inventory": inventory_totals(), "chest": chest_storage_summary(chest) })
    dispatch_key(KEY_ESCAPE, true)
    dispatch_key(KEY_ESCAPE, false)
    await wait_physics_frames(POST_ACTION_FRAMES)

    var workbench := nearest_block("workbench", player.global_position)
    if workbench == null:
        add_failure("workbench_missing_for_repair_crafting", "could not find generated tutorial town workbench")
        return
    await walk_near(workbench.global_position, CELL * 1.65, 14.0, "walking_to_workbench")
    aim_at(workbench.global_position + Vector3(0.0, CELL * 0.6, 0.0))
    dispatch_key(KEY_I, true)
    dispatch_key(KEY_I, false)
    await wait_physics_frames(POST_ACTION_FRAMES)
    var hud = main.get("hud")
    if hud == null or not bool(hud.call("is_inventory_open")):
        add_failure("inventory_not_open_for_repair_crafting", "inventory HUD did not open near workbench")
        return
    await press_craft_button("woodBlock", "craft_wood_block_1")
    await press_craft_button("woodBlock", "craft_wood_block_2")
    await press_craft_button("torch", "craft_torches")
    inventory_timeline.append({ "label": "repair_items_crafted", "inventory": inventory_totals() })
    dispatch_key(KEY_ESCAPE, true)
    dispatch_key(KEY_ESCAPE, false)
    await wait_physics_frames(POST_ACTION_FRAMES)

    var raw_state: Dictionary = tutorial.call("state") if tutorial != null and tutorial.has_method("state") else {}
    var targets: Dictionary = raw_state.get("introRepairTargets", {}) if raw_state.get("introRepairTargets", {}) is Dictionary else {}
    var fence_targets: Array = targets.get("fence", [])
    var lamp_targets: Array = targets.get("lamps", [])
    var town_center := intro_state_cell(tutorial, "townCenter", flat_cell(player.global_position))
    for north_side in [true, false]:
        if not north_side:
            var bypass_reached := await walk_to_south_repair_bypass(town_center)
            if not bypass_reached:
                return
        for index in repair_target_indices(fence_targets.size(), north_side):
            if fence_targets[index] is Vector2i:
                var fence_cell: Vector2i = fence_targets[index]
                if (fence_cell.y <= town_center.y) == north_side:
                    await place_repair_item("woodBlock", fence_cell, "repair_fence_%02d" % index, tutorial)
        for index in repair_target_indices(lamp_targets.size(), north_side):
            if lamp_targets[index] is Vector2i:
                var lamp_cell: Vector2i = lamp_targets[index]
                if (lamp_cell.y <= town_center.y) == north_side:
                    await place_repair_item("torch", lamp_cell, "repair_lamp_%02d" % index, tutorial)
    var final_state := tutorial_state_summary(tutorial)
    if not bool(final_state.get("repairComplete", false)):
        add_failure("repair_not_completed_by_real_placements", JSON.stringify({
            "state": final_state,
            "placements": repair_placement_events,
            "inventory": inventory_totals()
        }))
    else:
        results.append({ "name": "repair_completed_by_real_placements", "passed": true, "details": "placements=%d" % repair_placement_events.size() })

func attempt_sleep_after_repair(tutorial) -> void:
    var bed := find_tutorial_bed()
    if bed == null:
        add_failure("starter_bed_missing_after_repair", "could not find tutorial starter bed")
        return
    var before := tutorial_state_summary(tutorial)
    var bed_route_reached := await walk_intro_path_to_starter_bed(tutorial, "bed_after_repair_route")
    if not bed_route_reached:
        return
    var bed_used := await use_bed_with_real_action(bed, "bed_after_repair", 12.0)
    if not bed_used:
        return
    await wait_physics_frames(150)
    var after := tutorial_state_summary(tutorial)
    var slept := bool(after.get("bedUsed", false)) and float(main.get("time_of_day")) < 0.35
    sleep_timeline.append({
        "label": "after_repair",
        "slept": slept,
        "before": before,
        "after": after,
        "sleepTransitionActive": bool(main.get("sleep_transition_active")),
        "timeOfDay": rounded(float(main.get("time_of_day")))
    })
    if not slept:
        add_failure("sleep_after_repair_failed", JSON.stringify(sleep_timeline[sleep_timeline.size() - 1]))
    else:
        results.append({ "name": "sleep_after_repair_reached_morning", "passed": true, "details": "timeOfDay=%.3f" % float(main.get("time_of_day")) })

func observe_morning_npcs_and_foragers(seconds: float) -> void:
    var before_niko := npc_entry("niko")
    var before_runs := int(before_niko.get("jobRuns", 0))
    var before_hunger := float(before_niko.get("hunger", 0.0))
    var selected_object_id := ""
    var reservation_id := ""
    var approach_slot_id := ""
    var observed_departures := {}
    var frame_count := ceili(seconds * float(Engine.physics_ticks_per_second))
    for frame in range(frame_count):
        await get_tree().physics_frame
        if frame % SAMPLE_EVERY_FRAMES == 0:
            var rows := npc_schedule_matrix()
            morning_departure_matrix = rows
            for row in rows:
                var npc_id := String(row.get("id", ""))
                if npc_id == "":
                    continue
                if not observed_departures.has(npc_id):
                    observed_departures[npc_id] = { "id": npc_id, "leftHome": false, "samples": 0 }
                var departure: Dictionary = observed_departures[npc_id]
                departure["samples"] = int(departure.get("samples", 0)) + 1
                if not bool(row.get("strictInsideHome", false)):
                    departure["leftHome"] = true
                observed_departures[npc_id] = departure
            var niko := npc_entry("niko")
            if not niko.is_empty():
                var niko_row := niko_forage_row(niko, "morning_%03d" % frame)
                niko_timeline.append(niko_row)
                if selected_object_id == "" and String(niko.get("jobObjectId", "")) != "":
                    selected_object_id = String(niko.get("jobObjectId", ""))
                if reservation_id == "" and String(niko.get("jobReservationId", "")) != "":
                    reservation_id = String(niko.get("jobReservationId", ""))
                if approach_slot_id == "" and String(niko.get("jobApproachSlotId", "")) != "":
                    approach_slot_id = String(niko.get("jobApproachSlotId", ""))
                if int(niko.get("jobRuns", 0)) > before_runs:
                    break
            mark_progress("morning_%03d" % frame)
    var final_niko := npc_entry("niko")
    var final_runs := int(final_niko.get("jobRuns", 0))
    var final_hunger := float(final_niko.get("hunger", 0.0))
    var personal_inventory: Dictionary = final_niko.get("personalInventory", {}) if final_niko.get("personalInventory", {}) is Dictionary else {}
    niko_proof = {
        "selectedObjectId": selected_object_id,
        "reservationId": reservation_id,
        "approachSlot": approach_slot_id,
        "routeStatus": String(final_niko.get("routeStatus", "")),
        "routeReason": String(final_niko.get("routeReason", "")),
        "jobPhase": String(final_niko.get("jobPhase", "")),
        "jobRunsBefore": before_runs,
        "jobRunsAfter": final_runs,
        "hungerBefore": rounded(before_hunger),
        "hungerAfter": rounded(final_hunger),
        "personalInventory": personal_inventory.duplicate(true),
        "timeline": niko_timeline,
        "departureObservations": observed_departures
    }
    var forage_complete := final_runs > before_runs
    var route_proof := selected_object_id != "" and reservation_id != "" and approach_slot_id != ""
    if not route_proof:
        add_failure("niko_forager_route_proof_missing", JSON.stringify(niko_proof))
    elif not forage_complete:
        add_failure("niko_forager_cycle_not_completed", JSON.stringify(niko_proof))
    else:
        results.append({ "name": "niko_real_forage_cycle_completed", "passed": true, "details": "object=%s reservation=%s slot=%s runs=%d->%d" % [selected_object_id, reservation_id, approach_slot_id, before_runs, final_runs] })

func track_mira_speed() -> void:
    var mira := npc_entry("mira")
    if mira.is_empty():
        previous_mira_valid = false
        previous_mira_elapsed = elapsed
        return
    var body := mira.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        previous_mira_valid = false
        previous_mira_elapsed = elapsed
        return
    var current := body.global_position
    if previous_mira_valid:
        var flat_delta := Vector2(current.x - previous_mira_position.x, current.z - previous_mira_position.z).length()
        mira_total_flat_distance += flat_delta
        var sample_dt := maxf(elapsed - previous_mira_elapsed, physics_dt)
        var speed := flat_delta / maxf(sample_dt, 0.0001)
        max_mira_flat_speed = maxf(max_mira_flat_speed, speed)
        mira_speed_samples.append({
            "time": rounded(elapsed),
            "sampleDt": rounded(sample_dt),
            "flatSpeed": rounded(speed),
            "flatDelta": rounded(flat_delta),
            "position": vec3(current),
            "lastMoveDistance": rounded(float(mira.get("lastMoveDistance", 0.0))),
            "routeStatus": String(mira.get("routeStatus", "")),
            "routeReason": String(mira.get("routeReason", ""))
        })
    previous_mira_position = current
    previous_mira_elapsed = elapsed
    previous_mira_valid = true

func walk_near(target: Vector3, stop_distance: float, timeout_seconds: float, label := "walking") -> bool:
    var started_at := elapsed
    var reached := false
    while elapsed - started_at < timeout_seconds:
        var offset := Vector3(target.x - player.global_position.x, 0.0, target.z - player.global_position.z)
        if offset.length() <= stop_distance:
            reached = true
            break
        player.set("automated_move", offset.normalized())
        player.set("automated_sprint", false)
        await get_tree().physics_frame
        if int(Engine.get_physics_frames()) % SAMPLE_EVERY_FRAMES == 0:
            sample_player(label)
            mark_progress(label)
    player.set("automated_move", Vector3.ZERO)
    if not reached:
        var final_offset := Vector3(target.x - player.global_position.x, 0.0, target.z - player.global_position.z)
        reached = final_offset.length() <= stop_distance
    return reached

func walk_intro_path_to_town_center(tutorial, label: String) -> bool:
    var start_cell := intro_state_cell(tutorial, "startCell", flat_cell(player.global_position))
    var town_center := intro_state_cell(tutorial, "townCenter", start_cell)
    var inside_door_cell := Vector2i(start_cell.x, start_cell.y - 1)
    var starter_door_cell := Vector2i(start_cell.x, start_cell.y - 3)
    var exit_cell := Vector2i(start_cell.x, start_cell.y - 5)
    var center_north := Vector2i(town_center.x, exit_cell.y)
    return await walk_intro_waypoints([inside_door_cell, starter_door_cell, exit_cell, center_north], label, CELL * 1.25, 12.0)

func walk_intro_path_to_starter_bed(tutorial, label: String) -> bool:
    var start_cell := intro_state_cell(tutorial, "startCell", flat_cell(player.global_position))
    var town_center := intro_state_cell(tutorial, "townCenter", start_cell)
    var bed_cell := Vector2i(town_center.x - 14, town_center.y - 8)
    var starter_door_cell := Vector2i(start_cell.x, start_cell.y - 3)
    var inside_door_cell := Vector2i(start_cell.x, start_cell.y - 1)
    var current_cell := flat_cell(player.global_position)
    if abs(current_cell.x - start_cell.x) <= 6 and abs(current_cell.y - start_cell.y) <= 8:
        return await walk_intro_waypoints([inside_door_cell, bed_cell], label, CELL * 1.25, 8.0)
    var inner_lane := Vector2i(town_center.x, town_center.y - 8)
    var north_lane := Vector2i(town_center.x - 6, town_center.y - 16)
    return await walk_intro_waypoints([inner_lane, north_lane, starter_door_cell, inside_door_cell, bed_cell], label, CELL * 2.1, 12.0)

func walk_intro_waypoints(cells: Array, label: String, stop_distance: float, timeout_seconds: float) -> bool:
    for index in range(cells.size()):
        var cell_value = cells[index]
        if not (cell_value is Vector2i):
            continue
        var cell: Vector2i = cell_value
        var reached := await walk_near(world_position_for_flat_cell(cell), stop_distance, timeout_seconds, "%s_%02d_%d_%d" % [label, index, cell.x, cell.y])
        if reached:
            continue
        add_failure("intro_route_waypoint_not_reached", JSON.stringify({
            "label": label,
            "index": index,
            "cell": vec2i(cell),
            "player": vec3(player.global_position),
            "target": vec3(world_position_for_flat_cell(cell)),
            "stopDistance": rounded(stop_distance)
        }))
        return false
    return true

func intro_state_cell(tutorial, key: String, fallback: Vector2i) -> Vector2i:
    if tutorial == null or not tutorial.has_method("state"):
        return fallback
    var state: Dictionary = tutorial.call("state")
    var value = state.get(key, fallback)
    if value is Vector2i:
        return value
    return fallback

func use_block_with_real_action(block: Node3D, label: String, stop_distance: float, timeout_seconds: float) -> bool:
    if block == null or not is_instance_valid(block):
        add_failure("%s_block_missing_for_real_action" % label, "block was null or invalid")
        return false
    mark_progress("walking_to_%s" % label)
    var reached := await walk_near(block.global_position, stop_distance, timeout_seconds, "walking_to_%s" % label)
    if not reached:
        add_failure("%s_not_reached_for_real_action" % label, JSON.stringify({
            "player": vec3(player.global_position),
            "block": vec3(block.global_position),
            "distance": rounded(Vector2(block.global_position.x - player.global_position.x, block.global_position.z - player.global_position.z).length()),
            "stopDistance": rounded(stop_distance)
        }))
        return false
    var flat_from_block := Vector3(player.global_position.x - block.global_position.x, 0.0, player.global_position.z - block.global_position.z)
    if flat_from_block.length() < CELL * 1.25:
        var away := flat_from_block.normalized() if flat_from_block.length() > 0.05 else Vector3(0.0, 0.0, -1.0)
        var stand_position := block.global_position + away * CELL * 1.65
        await walk_near(stand_position, CELL * 0.35, 4.0, "adjusting_%s_stand" % label)
    await wait_physics_frames(POST_ACTION_FRAMES)
    var before_hit := await aim_until_interaction_hit(block, label)
    interaction_timeline.append({
        "label": "before_%s_action" % label,
        "player": vec3(player.global_position),
        "block": block_summary(block),
        "hit": before_hit
    })
    sample_player("before_%s_action" % label)
    dispatch_mouse_button(MOUSE_BUTTON_RIGHT, true)
    dispatch_mouse_button(MOUSE_BUTTON_RIGHT, false)
    await wait_physics_frames(POST_ACTION_FRAMES)
    interaction_timeline.append({
        "label": "after_%s_action" % label,
        "player": vec3(player.global_position),
        "block": block_summary(block),
        "hit": interaction_hit_summary()
    })
    sample_player("after_%s_action" % label)
    return true

func use_bed_with_real_action(bed: Node3D, label: String, timeout_seconds: float) -> bool:
    if bed == null or not is_instance_valid(bed):
        add_failure("%s_block_missing_for_real_action" % label, "bed was null or invalid")
        return false
    var last_hit := {}
    var stand_positions := [
        bed.global_position + Vector3(0.0, 0.0, -CELL * 0.72),
        bed.global_position + Vector3(CELL * 0.42, 0.0, -CELL * 0.72),
        bed.global_position + Vector3(-CELL * 0.42, 0.0, -CELL * 0.72),
        bed.global_position + Vector3(0.0, 0.0, CELL * 0.72),
        bed.global_position + Vector3(CELL * 0.42, 0.0, CELL * 0.72),
        bed.global_position + Vector3(-CELL * 0.42, 0.0, CELL * 0.72)
    ]
    for index in range(stand_positions.size()):
        var stand_position: Vector3 = stand_positions[index]
        var flat_distance := Vector2(stand_position.x - player.global_position.x, stand_position.z - player.global_position.z).length()
        var stand_timeout := clampf(flat_distance / (CELL * 2.6) + 2.0, 3.0, timeout_seconds)
        var reached := await walk_near(stand_position, CELL * 0.22, stand_timeout, "walking_to_%s_stand_%02d" % [label, index])
        await wait_physics_frames(POST_ACTION_FRAMES)
        last_hit = await aim_until_interaction_hit(bed, "%s_stand_%02d" % [label, index])
        interaction_timeline.append({
            "label": "bed_stand_%s_%02d" % [label, index],
            "reached": reached,
            "stand": vec3(stand_position),
            "player": vec3(player.global_position),
            "block": block_summary(bed),
            "hit": last_hit
        })
        if interaction_hit_matches_block(last_hit, bed) and bool(last_hit.get("withinReach", false)):
            sample_player("before_%s_action" % label)
            dispatch_mouse_button(MOUSE_BUTTON_RIGHT, true)
            dispatch_mouse_button(MOUSE_BUTTON_RIGHT, false)
            await wait_physics_frames(POST_ACTION_FRAMES)
            interaction_timeline.append({
                "label": "after_%s_action" % label,
                "player": vec3(player.global_position),
                "block": block_summary(bed),
                "hit": interaction_hit_summary()
            })
            sample_player("after_%s_action" % label)
            return true
    add_failure("%s_no_reachable_bed_hit" % label, JSON.stringify({
        "player": vec3(player.global_position),
        "bed": block_summary(bed),
        "lastHit": last_hit
    }))
    return false

func press_utility_slot(index: int, label: String) -> void:
    var hud = main.get("hud") if main != null else null
    if hud == null or hud.get("utility_grid") == null:
        add_failure("utility_grid_missing", label)
        return
    var grid: GridContainer = hud.get("utility_grid")
    if index < 0 or index >= grid.get_child_count():
        add_failure("utility_slot_missing", "%s index=%d childCount=%d" % [label, index, grid.get_child_count()])
        return
    var button := grid.get_child(index) as Button
    if button == null:
        add_failure("utility_slot_not_button", "%s index=%d" % [label, index])
        return
    button.emit_signal("pressed")
    await wait_physics_frames(POST_ACTION_FRAMES)
    inventory_timeline.append({ "label": label, "inventory": inventory_totals(), "utilityState": utility_state_summary() })

func press_craft_button(recipe_id: String, label: String) -> void:
    var hud = main.get("hud") if main != null else null
    var crafting = main.get("crafting_system") if main != null else null
    if hud == null or crafting == null or hud.get("crafting_list") == null:
        add_failure("crafting_hud_missing", label)
        return
    var recipe: Dictionary = crafting.call("recipe_for", recipe_id)
    var expected_label := String(recipe.get("label", recipe_id))
    var expected_amount := int(recipe.get("amount", 1))
    var prefix := "%s x%d" % [expected_label, expected_amount]
    var list: VBoxContainer = hud.get("crafting_list")
    for child in list.get_children():
        var button := child as Button
        if button == null:
            continue
        if not String(button.text).begins_with(prefix):
            continue
        if button.disabled:
            add_failure("craft_button_disabled", "%s text=%s inventory=%s" % [label, button.text, JSON.stringify(inventory_totals())])
            return
        button.emit_signal("pressed")
        await wait_physics_frames(POST_ACTION_FRAMES)
        inventory_timeline.append({ "label": label, "recipeId": recipe_id, "inventory": inventory_totals() })
        return
    add_failure("craft_button_missing", "%s prefix=%s" % [label, prefix])

func place_repair_item(item_id: String, cell: Vector2i, label: String, tutorial) -> void:
    var selected_item := await select_hotbar_item(item_id)
    if not selected_item:
        add_failure("repair_item_not_in_hotbar", "%s item=%s inventory=%s" % [label, item_id, JSON.stringify(inventory_totals())])
        return
    var before := tutorial_state_summary(tutorial)
    var before_fence := int(before.get("fencePlaced", 0))
    var before_lamps := int(before.get("lampsPlaced", 0))
    var target_position := world_position_for_flat_cell(cell)
    var stand_position := placement_stand_position(cell, tutorial)
    var reached_stand := await walk_to_repair_stand(cell, stand_position, tutorial, label)
    if not reached_stand:
        var stand_event := {
            "label": label,
            "item": item_id,
            "targetCell": vec2i(cell),
            "standPosition": vec3(stand_position),
            "playerPosition": vec3(player.global_position),
            "inventory": inventory_totals()
        }
        repair_placement_events.append(stand_event)
        add_failure("repair_placement_stand_not_reached", JSON.stringify(stand_event))
        return
    var preview := await aim_until_placement_preview(item_id, cell, label)
    if not placement_preview_matches_target(preview, item_id, cell):
        var preview_event := {
            "label": label,
            "item": item_id,
            "targetCell": vec2i(cell),
            "standPosition": vec3(stand_position),
            "playerPosition": vec3(player.global_position),
            "preview": preview,
            "inventory": inventory_totals()
        }
        repair_placement_events.append(preview_event)
        add_failure("repair_placement_preview_miss", JSON.stringify(preview_event))
        return
    dispatch_mouse_button(MOUSE_BUTTON_RIGHT, true)
    dispatch_mouse_button(MOUSE_BUTTON_RIGHT, false)
    await wait_physics_frames(POST_ACTION_FRAMES)
    var after := tutorial_state_summary(tutorial)
    var after_fence := int(after.get("fencePlaced", 0))
    var after_lamps := int(after.get("lampsPlaced", 0))
    var counted := after_fence > before_fence or after_lamps > before_lamps
    var event := {
        "label": label,
        "item": item_id,
        "targetCell": vec2i(cell),
        "standPosition": vec3(stand_position),
        "playerPosition": vec3(player.global_position),
        "preview": preview,
        "counted": counted,
        "beforeFence": before_fence,
        "afterFence": after_fence,
        "beforeLamps": before_lamps,
        "afterLamps": after_lamps,
        "inventory": inventory_totals()
    }
    repair_placement_events.append(event)
    if not counted:
        add_failure("repair_placement_not_counted", JSON.stringify(event))

func select_hotbar_item(item_id: String) -> bool:
    var inventory_system = main.get("inventory_system") if main != null else null
    if inventory_system == null:
        return false
    var slots: Array = inventory_system.get("slots")
    var hotbar_size := int(inventory_system.get("hotbar_size"))
    for i in range(mini(hotbar_size, slots.size())):
        var slot: Dictionary = slots[i] if slots[i] is Dictionary else {}
        if String(slot.get("item", "")) != item_id:
            continue
        var keycode: int = int(KEY_1) + i
        dispatch_key(keycode, true)
        dispatch_key(keycode, false)
        await wait_physics_frames(6)
        var active: Dictionary = inventory_system.call("active_stack")
        return String(active.get("item", "")) == item_id
    return false

func placement_stand_position(cell: Vector2i, tutorial) -> Vector3:
    var town_center := Vector2i.ZERO
    if tutorial != null and tutorial.has_method("state"):
        var state: Dictionary = tutorial.call("state")
        town_center = state.get("townCenter", Vector2i.ZERO)
    var direction := Vector2(float(town_center.x - cell.x), float(town_center.y - cell.y))
    if direction.length_squared() < 0.001:
        direction = Vector2(1.0, 0.0)
    direction = direction.normalized()
    var stand_x := float(cell.x) + direction.x * 1.55
    var stand_z := float(cell.y) + direction.y * 1.55
    return world_position_for_flat_coords(stand_x, stand_z)

func repair_target_indices(count: int, north_side: bool) -> Array:
    var result := []
    if north_side:
        for index in range(count):
            result.append(index)
    else:
        for index in range(count - 1, -1, -1):
            result.append(index)
    return result

func walk_to_south_repair_bypass(town_center: Vector2i) -> bool:
    var waypoints := [
        Vector2i(town_center.x + 24, town_center.y - 24),
        Vector2i(town_center.x + 24, town_center.y + 24)
    ]
    for index in range(waypoints.size()):
        var waypoint: Vector2i = waypoints[index]
        var waypoint_position := world_position_for_flat_cell(waypoint)
        var distance := Vector2(waypoint_position.x - player.global_position.x, waypoint_position.z - player.global_position.z).length()
        var timeout := clampf(distance / (CELL * 3.0) + 5.0, 10.0, 34.0)
        var reached := await walk_near(waypoint_position, CELL * 1.65, timeout, "walking_to_south_repair_bypass_%02d_%d_%d" % [index, waypoint.x, waypoint.y])
        if not reached:
            add_failure("south_repair_bypass_not_reached", JSON.stringify({
                "index": index,
                "cell": vec2i(waypoint),
                "player": vec3(player.global_position),
                "target": vec3(waypoint_position),
                "stopDistance": rounded(CELL * 1.65)
            }))
            return false
    return true

func walk_to_repair_stand(cell: Vector2i, stand_position: Vector3, tutorial, label: String) -> bool:
    var stand_distance := Vector2(stand_position.x - player.global_position.x, stand_position.z - player.global_position.z).length()
    var stand_timeout := clampf(stand_distance / (CELL * 2.8) + 5.0, 12.0, 30.0)
    return await walk_near(stand_position, CELL * 0.38, stand_timeout, "walking_to_%s" % label)

func aim_until_placement_preview(item_id: String, cell: Vector2i, label: String) -> Dictionary:
    var target_position := world_position_for_flat_cell(cell)
    var offsets := [
        Vector3(0.0, -CELL * 0.16, 0.0),
        Vector3(0.0, CELL * 0.02, 0.0),
        Vector3(0.0, CELL * 0.16, 0.0),
        Vector3(CELL * 0.18, -CELL * 0.12, 0.0),
        Vector3(-CELL * 0.18, -CELL * 0.12, 0.0),
        Vector3(0.0, -CELL * 0.12, CELL * 0.18),
        Vector3(0.0, -CELL * 0.12, -CELL * 0.18)
    ]
    var summary := {}
    for offset in offsets:
        aim_at(target_position + offset)
        await wait_physics_frames(2)
        summary = placement_preview_summary(item_id)
        if placement_preview_matches_target(summary, item_id, cell):
            repair_placement_events.append({
                "label": "preview_%s" % label,
                "item": item_id,
                "targetCell": vec2i(cell),
                "playerPosition": vec3(player.global_position),
                "preview": summary
            })
            return summary
    repair_placement_events.append({
        "label": "preview_miss_%s" % label,
        "item": item_id,
        "targetCell": vec2i(cell),
        "playerPosition": vec3(player.global_position),
        "preview": summary
    })
    return summary

func placement_preview_summary(item_id: String) -> Dictionary:
    if player == null or main == null or not player.has_method("view_ray") or not main.has_method("placement_from_hit"):
        return { "hit": false, "reason": "missing_placement_preview_dependencies" }
    var max_distance := CELL * 2.65
    var hit: Dictionary = player.call("view_ray", max_distance)
    var hit_source := "view_ray"
    if hit.is_empty() and main.has_method("fallback_ground_placement_hit"):
        hit = main.call("fallback_ground_placement_hit", max_distance)
        hit_source = "fallback_ground"
    if hit.is_empty():
        return { "hit": false, "reason": "no_placement_hit", "source": hit_source }
    var placement: Dictionary = main.call("placement_from_hit", hit, item_id)
    if placement.is_empty() or not placement.has("cell"):
        return { "hit": true, "reason": "empty_placement", "source": hit_source, "hitSummary": placement_hit_summary(hit) }
    var cell: Vector3i = placement["cell"]
    var blocks_value = main.get("blocks")
    var blocked := blocks_value is Dictionary and (blocks_value as Dictionary).has(cell)
    return {
        "hit": true,
        "source": hit_source,
        "hitSummary": placement_hit_summary(hit),
        "placementCell": vec3i(cell),
        "flatCell": vec2i(Vector2i(cell.x, cell.z)),
        "worldY": rounded(float(placement.get("world_y", 0.0))),
        "withinReach": bool(main.call("placement_within_action_reach", placement)) if main.has_method("placement_within_action_reach") else false,
        "blocked": blocked
    }

func placement_hit_summary(hit: Dictionary) -> Dictionary:
    var collider := hit.get("collider") as Node
    var hit_position: Vector3 = hit.get("position", Vector3.ZERO)
    var normal: Vector3 = hit.get("normal", Vector3.ZERO)
    var block_node := (main.call("interaction_block_from_collider", collider) if main != null and main.has_method("interaction_block_from_collider") else collider) as Node
    return {
        "collider": collider.name if collider != null else "",
        "colliderKind": String(collider.get_meta("kind", "")) if collider != null and collider.has_meta("kind") else "",
        "colliderPath": String(collider.get_path()) if collider != null else "",
        "block": block_node.name if block_node != null else "",
        "blockPath": String(block_node.get_path()) if block_node != null else "",
        "blockType": String(block_node.get_meta("block_type", "")) if block_node != null and block_node.has_meta("block_type") else "",
        "position": vec3(hit_position),
        "normal": vec3(normal)
    }

func placement_preview_matches_target(summary: Dictionary, item_id: String, target_cell: Vector2i) -> bool:
    if not bool(summary.get("hit", false)) or not bool(summary.get("withinReach", false)) or bool(summary.get("blocked", false)):
        return false
    var flat_value = summary.get("flatCell", {})
    var flat := Vector2i(2147483647, 2147483647)
    if flat_value is Array and flat_value.size() >= 2:
        flat = Vector2i(int(flat_value[0]), int(flat_value[1]))
    elif flat_value is Dictionary:
        flat = Vector2i(int(flat_value.get("x", 2147483647)), int(flat_value.get("y", 2147483647)))
    else:
        return false
    var tolerance := 0 if item_id == "woodBlock" else 3
    return absi(flat.x - target_cell.x) + absi(flat.y - target_cell.y) <= tolerance

func world_position_for_flat_cell(cell: Vector2i) -> Vector3:
    return world_position_for_flat_coords(float(cell.x), float(cell.y))

func world_position_for_flat_coords(cell_x: float, cell_z: float) -> Vector3:
    var x := cell_x * CELL
    var z := cell_z * CELL
    var y := 0.0
    if main != null and main.has_method("height_at_world"):
        y = float(main.call("height_at_world", x, z)) + 0.08
    return Vector3(x, y, z)

func entry_position(entry: Dictionary, key: String, fallback: Vector3) -> Vector3:
    var value = entry.get(key, fallback)
    if value is Vector3:
        return value
    return fallback

func flat_distance(a: Vector3, b: Vector3) -> float:
    return Vector2(a.x - b.x, a.z - b.z).length()

func aim_at(target: Vector3) -> void:
    if player == null or camera == null:
        return
    var flat_target := Vector3(target.x, player.global_position.y, target.z)
    if flat_target.distance_to(player.global_position) > 0.05:
        player.look_at(flat_target, Vector3.UP)
    if target.distance_to(camera.global_position) > 0.05:
        camera.look_at(target, Vector3.UP)
    player.set("pitch", camera.rotation.x)

func aim_until_interaction_hit(block: Node3D, label: String) -> Dictionary:
    var summary := {}
    for height_scale in [0.28, 0.48, 0.12, 0.70]:
        aim_at(block.global_position + Vector3(0.0, CELL * float(height_scale), 0.0))
        await wait_physics_frames(6)
        summary = interaction_hit_summary()
        if interaction_hit_matches_block(summary, block):
            return summary
    interaction_timeline.append({
        "label": "aim_miss_%s" % label,
        "player": vec3(player.global_position),
        "block": block_summary(block),
        "hit": summary
    })
    return summary

func interaction_hit_summary() -> Dictionary:
    if player == null or not player.has_method("view_ray"):
        return { "hit": false, "reason": "missing_player_view_ray" }
    var hit: Dictionary = player.call("view_ray", 10.5, true)
    if hit.is_empty():
        return { "hit": false }
    var collider := hit.get("collider") as Node
    var block_node := (main.call("interaction_block_from_collider", collider) if main != null and main.has_method("interaction_block_from_collider") else collider) as Node
    var hit_position: Vector3 = hit.get("position", Vector3.ZERO)
    return {
        "hit": true,
        "collider": collider.name if collider != null else "",
        "colliderKind": String(collider.get_meta("kind", "")) if collider != null and collider.has_meta("kind") else "",
        "colliderPath": String(collider.get_path()) if collider != null else "",
        "block": block_node.name if block_node != null else "",
        "blockPath": String(block_node.get_path()) if block_node != null else "",
        "blockType": String(block_node.get_meta("block_type", "")) if block_node != null and block_node.has_meta("block_type") else "",
        "withinReach": bool(main.call("hit_within_action_reach", hit)) if main != null and main.has_method("hit_within_action_reach") else false,
        "distance": rounded(player.global_position.distance_to(hit_position)),
        "position": vec3(hit_position)
    }

func interaction_hit_matches_block(summary: Dictionary, block: Node) -> bool:
    if block == null or not bool(summary.get("hit", false)):
        return false
    return String(summary.get("blockPath", "")) == String(block.get_path())

func block_summary(block: Node3D) -> Dictionary:
    if block == null:
        return {}
    return {
        "name": block.name,
        "path": String(block.get_path()),
        "type": String(block.get_meta("block_type", "")) if block.has_meta("block_type") else "",
        "position": vec3(block.global_position)
    }

func dispatch_mouse_button(button_index: int, pressed: bool) -> void:
    var event := InputEventMouseButton.new()
    event.button_index = button_index
    event.pressed = pressed
    var center := get_viewport().get_visible_rect().size * 0.5
    event.position = center
    event.global_position = center
    var has_use_or_place := main != null and main.has_method("use_or_place")
    interaction_timeline.append({
        "label": "dispatch_mouse",
        "button": button_index,
        "pressed": pressed,
        "hasUseOrPlace": has_use_or_place,
        "usingUseOrPlace": pressed and has_use_or_place
    })
    if pressed and has_use_or_place:
        main.call("use_or_place")
        interaction_timeline.append({
            "label": "after_use_or_place_call",
            "state": runtime_action_state()
        })
    elif main != null and main.has_method("_unhandled_input"):
        main.call("_unhandled_input", event)
    else:
        get_viewport().push_input(event)

func dispatch_key(keycode: int, pressed: bool) -> void:
    var event := InputEventKey.new()
    event.keycode = keycode
    event.pressed = pressed
    get_viewport().push_input(event)

func runtime_action_state() -> Dictionary:
    var utility = main.get("utility_system") if main != null else null
    var hud_node = main.get("hud") if main != null else null
    return {
        "utilitySystemExists": utility != null,
        "utilityOpen": bool(utility.call("is_open")) if utility != null and utility.has_method("is_open") else false,
        "utilityActiveType": String(utility.call("active_type")) if utility != null and utility.has_method("active_type") else "",
        "hudExists": hud_node != null,
        "hudUtilityOpen": bool(hud_node.call("is_utility_open")) if hud_node != null and hud_node.has_method("is_utility_open") else false,
        "hudInventoryOpen": bool(hud_node.call("is_inventory_open")) if hud_node != null and hud_node.has_method("is_inventory_open") else false,
        "hudDialogueOpen": bool(hud_node.call("is_dialogue_open")) if hud_node != null and hud_node.has_method("is_dialogue_open") else false,
        "lastHudMessage": String(main.get("last_hud_refresh_message")) if main != null else "",
        "focusedHit": interaction_hit_summary()
    }

func wait_physics_frames(count: int) -> void:
    for i in range(count):
        await get_tree().physics_frame

func wait_process_frames(count: int) -> void:
    for i in range(count):
        await get_tree().process_frame

func ensure_dir(path: String) -> void:
    if path == "":
        return
    DirAccess.make_dir_recursive_absolute(path)

func bind_scene_nodes() -> void:
    if main == null:
        return
    player = main.get("player") as CharacterBody3D
    if player != null:
        camera = player.get("camera") as Camera3D

func nearest_block(block_type: String, origin: Vector3) -> Node3D:
    if main == null:
        return null
    var blocks_value = main.get("blocks")
    if not (blocks_value is Dictionary):
        return null
    var best: Node3D = null
    var best_distance := INF
    var blocks: Dictionary = blocks_value
    for block_value in blocks.values():
        var body := block_value as Node3D
        if body == null or not is_instance_valid(body):
            continue
        if String(body.get_meta("block_type", "")) != block_type:
            continue
        var distance := Vector2(body.global_position.x - origin.x, body.global_position.z - origin.z).length()
        if distance < best_distance:
            best_distance = distance
            best = body
    return best

func find_intro_repair_chest() -> Node3D:
    if main == null:
        return null
    var blocks_value = main.get("blocks")
    if not (blocks_value is Dictionary):
        return null
    for block_value in (blocks_value as Dictionary).values():
        var body := block_value as Node3D
        if body == null or not is_instance_valid(body):
            continue
        if String(body.get_meta("block_type", "")) == "chest" and bool(body.get_meta("intro_repair_chest", false)):
            return body
    return null

func find_tutorial_bed() -> Node3D:
    if main == null:
        return null
    var blocks_value = main.get("blocks")
    if not (blocks_value is Dictionary):
        return null
    var best: Node3D = null
    var best_distance := INF
    for block_value in (blocks_value as Dictionary).values():
        var body := block_value as Node3D
        if body == null or not is_instance_valid(body):
            continue
        if String(body.get_meta("block_type", "")) != "bed":
            continue
        var cache_key := String(body.get_meta("cacheKey", ""))
        var tutorial_bed := cache_key.find("tutorial-bed") >= 0
        var distance := body.global_position.distance_squared_to(player.global_position)
        if tutorial_bed:
            return body
        if distance < best_distance:
            best_distance = distance
            best = body
    return best

func inventory_totals() -> Dictionary:
    var inventory_system = main.get("inventory_system") if main != null else null
    if inventory_system == null or not inventory_system.has_method("totals"):
        return {}
    var totals: Dictionary = inventory_system.call("totals")
    return totals.duplicate(true)

func utility_state_summary() -> Dictionary:
    var utility = main.get("utility_system") if main != null else null
    if utility == null or not utility.has_method("active_state"):
        return {}
    var state: Dictionary = utility.call("active_state")
    return state.duplicate(true)

func chest_storage_summary(chest: Node) -> Array[Dictionary]:
    var rows: Array[Dictionary] = []
    if chest == null or not is_instance_valid(chest):
        return rows
    var slots: Array = chest.get_meta("storage_slots", [])
    for index in range(slots.size()):
        var slot: Dictionary = slots[index] if slots[index] is Dictionary else {}
        rows.append({
            "index": index,
            "item": String(slot.get("item", "")),
            "count": int(slot.get("count", 0))
        })
    return rows

func hud_dialogue_open() -> bool:
    var hud = main.get("hud") if main != null else null
    return hud != null and hud.has_method("is_dialogue_open") and bool(hud.call("is_dialogue_open"))

func tutorial_state_summary(tutorial) -> Dictionary:
    if tutorial == null or not tutorial.has_method("state"):
        return {}
    var state: Dictionary = tutorial.call("state")
    return {
        "started": bool(state.get("started", false)),
        "stage": String(state.get("tutorialStage", "")),
        "doorOpened": bool(state.get("introDoorOpened", false)),
        "elderAcknowledged": bool(state.get("introElderDialogueAcknowledged", false)),
        "repairActive": bool(state.get("introRepairActive", false)),
        "repairComplete": bool(state.get("introRepairComplete", false)),
        "repairChestOpened": bool(state.get("introRepairChestOpened", false)),
        "bedUsed": bool(state.get("introBedUsed", false)),
        "fencePlaced": int(state.get("introFencePlaced", 0)),
        "fenceRequired": int(state.get("introFenceRequired", 0)),
        "lampsPlaced": int(state.get("introLampsPlaced", 0)),
        "lampsRequired": int(state.get("introLampsRequired", 0)),
        "townCenter": vec2i(state.get("townCenter", Vector2i.ZERO)),
        "startCell": vec2i(state.get("startCell", Vector2i.ZERO)),
        "chestCell": vec2i(state.get("introRepairChestCell", Vector2i.ZERO))
    }

func repair_target_proof(tutorial) -> Dictionary:
    if tutorial == null or not tutorial.has_method("state"):
        return { "reached": false, "targets": {}, "placements": repair_placement_events }
    var state: Dictionary = tutorial.call("state")
    var targets: Dictionary = state.get("introRepairTargets", {})
    return {
        "reached": bool(state.get("introRepairComplete", false)),
        "fenceTargets": vec2i_array(targets.get("fence", [])),
        "lampTargets": vec2i_array(targets.get("lamps", [])),
        "placedFence": int(state.get("introFencePlaced", 0)),
        "placedLamps": int(state.get("introLampsPlaced", 0)),
        "placements": repair_placement_events,
        "inventory": inventory_totals()
    }

func sleep_transition_proof(tutorial) -> Dictionary:
    var state := tutorial_state_summary(tutorial)
    var blocked_before := false
    var slept_after := false
    for row in sleep_timeline:
        if String(row.get("label", "")) == "before_repair":
            blocked_before = bool(row.get("blocked", false))
        elif String(row.get("label", "")) == "after_repair":
            slept_after = bool(row.get("slept", false))
    return {
        "reached": slept_after,
        "blockedBeforeRepair": blocked_before,
        "sleptAfterRepair": slept_after,
        "timeline": sleep_timeline,
        "finalTutorialState": state,
        "timeOfDay": rounded(float(main.get("time_of_day"))) if main != null else 0.0
    }

func sample_player(label: String) -> void:
    if player == null:
        return
    player_timeline.append({
        "label": label,
        "time": rounded(elapsed),
        "position": vec3(player.global_position),
        "velocity": vec3(player.velocity),
        "automatedMove": vec3(player.get("automated_move")),
        "mouseMode": Input.get_mouse_mode()
    })

func sample_door(label: String, door: Node3D) -> void:
    if door == null or not is_instance_valid(door):
        return
    door_timeline.append({
        "label": label,
        "time": rounded(elapsed),
        "position": vec3(door.global_position),
        "open": bool(door.get_meta("open", false)),
        "cell": vec3i(door.get_meta("cell", Vector3i.ZERO)),
        "blockType": String(door.get_meta("block_type", ""))
    })

func sample_mira(label: String) -> void:
    var mira := npc_entry("mira")
    if mira.is_empty():
        mira_timeline.append({ "label": label, "time": rounded(elapsed), "missing": true })
        return
    var summary := npc_summary(mira)
    summary["label"] = label
    summary["time"] = rounded(elapsed)
    summary["strictHome"] = strict_home_status(mira)
    mira_timeline.append(summary)

func route_order_sample(label: String) -> Dictionary:
    var row := {
        "label": label,
        "time": rounded(elapsed),
        "mira": {}
    }
    var mira := npc_entry("mira")
    if not mira.is_empty():
        row["mira"] = {
            "homeRouteIndex": int(mira.get("homeRouteIndex", 0)),
            "homeActiveTargetCell": vec2i(mira.get("homeActiveTargetCell", Vector2i.ZERO)),
            "routePriority": int(mira.get("routePriority", 0)),
            "routeStatus": String(mira.get("routeStatus", "")),
            "routeReason": String(mira.get("routeReason", "")),
            "activeDoorPortalId": String(mira.get("activeDoorPortalId", "")),
            "activeDoorDirection": String(mira.get("activeDoorDirection", "")),
            "portalRecenterTicks": int(mira.get("portalRecenterTicks", 0)),
            "lastMoveDistance": rounded(float(mira.get("lastMoveDistance", 0.0)))
        }
    return row

func npc_entry(npc_id: String) -> Dictionary:
    var npc_system = main.get("npc_system") if main != null else null
    if npc_system == null:
        return {}
    var entries: Array = npc_system.get("npcs")
    for entry_value in entries:
        var entry: Dictionary = entry_value
        if String(entry.get("id", "")) == npc_id:
            return entry
    return {}

func npc_schedule_matrix() -> Array[Dictionary]:
    var rows: Array[Dictionary] = []
    var npc_system = main.get("npc_system") if main != null else null
    if npc_system == null:
        return rows
    var entries: Array = npc_system.get("npcs")
    for entry_value in entries:
        var entry: Dictionary = entry_value
        rows.append(npc_summary(entry))
    return rows

func npc_summary(entry: Dictionary) -> Dictionary:
    var body := entry.get("body") as Node3D
    var body_valid := body != null and is_instance_valid(body)
    var position := body.global_position if body_valid else Vector3.ZERO
    var body_home_meta := false
    var force_hold_meta := false
    var dialogue_focused_meta := false
    var scripted_target_meta := false
    var scripted_arrived_meta := false
    var requested_velocity_meta := Vector3.ZERO
    var applied_velocity_meta := Vector3.ZERO
    var last_displacement_meta := Vector3.ZERO
    var blocked_contact_meta := ""
    var blocked_contact_name_meta := ""
    var blocked_contact_kind_meta := ""
    var blocked_contact_type_meta := ""
    var slide_collision_count_meta := 0
    if body_valid:
        body_home_meta = bool(body.get_meta("npc_inside_home", false))
        force_hold_meta = bool(body.get_meta("npc_force_hold", false))
        dialogue_focused_meta = bool(body.get_meta("npc_dialogue_focused", false))
        scripted_target_meta = body.has_meta("npc_scripted_target")
        scripted_arrived_meta = bool(body.get_meta("npc_scripted_arrived", false))
        requested_velocity_meta = body.get_meta("npc_requested_velocity", Vector3.ZERO)
        applied_velocity_meta = body.get_meta("npc_applied_velocity", Vector3.ZERO)
        last_displacement_meta = body.get_meta("npc_last_displacement", Vector3.ZERO)
        blocked_contact_meta = String(body.get_meta("npc_blocked_contact", ""))
        blocked_contact_name_meta = String(body.get_meta("npc_blocked_contact_name", ""))
        blocked_contact_kind_meta = String(body.get_meta("npc_blocked_contact_kind", ""))
        blocked_contact_type_meta = String(body.get_meta("npc_blocked_contact_type", ""))
        slide_collision_count_meta = int(body.get_meta("npc_slide_collision_count", 0))
    var path_waypoints: Array = entry.get("pathWaypoints", [])
    var first_waypoint := Vector3.ZERO
    var first_waypoint_valid := false
    if not path_waypoints.is_empty() and path_waypoints[0] is Vector3:
        first_waypoint = path_waypoints[0]
        first_waypoint_valid = true
    return {
        "id": String(entry.get("id", "")),
        "name": String(entry.get("name", "")),
        "role": String(entry.get("role", "")),
        "job": String(entry.get("job", "")),
        "jobPhase": String(entry.get("jobPhase", "")),
        "jobObjectId": String(entry.get("jobObjectId", "")),
        "jobReservationId": String(entry.get("jobReservationId", "")),
        "jobApproachSlotId": String(entry.get("jobApproachSlotId", "")),
        "jobFailureReason": String(entry.get("jobFailureReason", "")),
        "jobRuns": int(entry.get("jobRuns", 0)),
        "jobTarget": vec3(entry.get("jobTarget", Vector3.ZERO)),
        "hunger": rounded(float(entry.get("hunger", 0.0))),
        "personalInventory": (entry.get("personalInventory", {}) as Dictionary).duplicate(true) if entry.get("personalInventory", {}) is Dictionary else {},
        "canFight": bool(entry.get("canFight", false)),
        "nightGuard": bool(entry.get("nightGuard", false)),
        "holdDoorOrder": bool(entry.get("holdIntroDoor", false)),
        "position": vec3(position),
        "cell": vec2i(flat_cell(position)),
        "homeCell": vec2i(entry.get("homeCell", Vector2i.ZERO)),
        "porchCell": vec2i(entry.get("porchCell", Vector2i.ZERO)),
        "interiorMinCell": vec2i(entry.get("interiorMinCell", Vector2i.ZERO)),
        "interiorMaxCell": vec2i(entry.get("interiorMaxCell", Vector2i.ZERO)),
        "insideHomeMeta": body_home_meta,
        "strictInsideHome": bool(strict_home_status(entry).get("strictInside", false)),
        "routeStatus": String(entry.get("routeStatus", "")),
        "routeReason": String(entry.get("routeReason", "")),
        "routePriority": int(entry.get("routePriority", 0)),
        "homeRouteIndex": int(entry.get("homeRouteIndex", 0)),
        "homeRouteCount": (entry.get("homeRoutePositions", []) as Array).size(),
        "homeActiveTargetCell": vec2i(entry.get("homeActiveTargetCell", Vector2i.ZERO)),
        "lastMoveDistance": rounded(float(entry.get("lastMoveDistance", 0.0))),
        "simulationLod": String(entry.get("simulationLod", "")),
        "movementHeldForTopology": bool(entry.get("movementHeldForTopology", false)),
        "npcMotionSkippedReason": String(entry.get("npc_motion_skipped_reason", "")),
        "npcMotionUpdates": int(entry.get("npc_motion_updates", 0)),
        "npcBrainUpdates": int(entry.get("npc_brain_updates", 0)),
        "forceHoldMeta": force_hold_meta,
        "dialogueFocusedMeta": dialogue_focused_meta,
        "scriptedTargetMeta": scripted_target_meta,
        "scriptedArrivedMeta": scripted_arrived_meta,
        "activeMotionGoal": entry.get("activeMotionGoal", {}),
        "activeDoorPortalId": String(entry.get("activeDoorPortalId", "")),
        "activeDoorDirection": String(entry.get("activeDoorDirection", "")),
        "portalRecenterTicks": int(entry.get("portalRecenterTicks", 0)),
        "activeTrafficStepGroup": String(entry.get("activeTrafficStepGroup", "")),
        "blockedMoveTime": rounded(float(entry.get("blockedMoveTime", 0.0))),
        "routeWaitTicks": int(entry.get("routeWaitTicks", 0)),
        "motorBlockedContact": blocked_contact_meta,
        "motorBlockedContactName": blocked_contact_name_meta,
        "motorBlockedContactKind": blocked_contact_kind_meta,
        "motorBlockedContactType": blocked_contact_type_meta,
        "motorSlideCollisionCount": slide_collision_count_meta,
        "motorRequestedVelocity": vec3(requested_velocity_meta),
        "motorAppliedVelocity": vec3(applied_velocity_meta),
        "motorLastDisplacement": vec3(last_displacement_meta),
        "routeFallbackCell": vec2i(entry.get("routeFallbackCell", Vector2i.ZERO)),
        "routeCells": vec2i_array_limited(entry.get("routeCells", []), 8),
        "pathWaypointCount": path_waypoints.size(),
        "firstPathWaypointValid": first_waypoint_valid,
        "firstPathWaypoint": vec3(first_waypoint),
        "lastRoutePlanDebug": entry.get("lastRoutePlanDebug", {}),
        "corridorFollow": entry.get("corridorFollow", {}),
        "corridorProgress": entry.get("corridorProgress", {})
    }

func strict_home_status(entry: Dictionary) -> Dictionary:
    if entry.is_empty():
        return { "strictInside": false, "reason": "entry_missing" }
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return { "strictInside": false, "reason": "body_missing" }
    var cell := flat_cell(body.global_position)
    var min_cell: Vector2i = entry.get("interiorMinCell", Vector2i.ZERO)
    var max_cell: Vector2i = entry.get("interiorMaxCell", Vector2i.ZERO)
    var porch: Vector2i = entry.get("porchCell", Vector2i.ZERO)
    var inside_bounds := (
        cell.x >= mini(min_cell.x, max_cell.x)
        and cell.x <= maxi(min_cell.x, max_cell.x)
        and cell.y >= mini(min_cell.y, max_cell.y)
        and cell.y <= maxi(min_cell.y, max_cell.y)
    )
    var strict_inside := inside_bounds and cell != porch
    return {
        "strictInside": strict_inside,
        "cell": vec2i(cell),
        "porchCell": vec2i(porch),
        "interiorMinCell": vec2i(min_cell),
        "interiorMaxCell": vec2i(max_cell),
        "insideBounds": inside_bounds,
        "reason": "interior_bounds" if strict_inside else "not_inside_interior"
    }

func forager_state_summary() -> Array[Dictionary]:
    var rows: Array[Dictionary] = []
    var npc_system = main.get("npc_system") if main != null else null
    if npc_system == null:
        return rows
    var entries: Array = npc_system.get("npcs")
    for entry_value in entries:
        var entry: Dictionary = entry_value
        var npc_id := String(entry.get("id", ""))
        if npc_id != "niko" and String(entry.get("job", "")) != "forage":
            continue
        var row := npc_summary(entry)
        row["target"] = vec3(entry.get("jobTarget", Vector3.ZERO))
        row["targetNode"] = target_node_summary(entry.get("jobTargetNode"))
        rows.append(row)
    return rows

func niko_forage_row(entry: Dictionary, label: String) -> Dictionary:
    var row := npc_summary(entry)
    row["label"] = label
    row["time"] = rounded(elapsed)
    row["targetNode"] = target_node_summary(entry.get("jobTargetNode"))
    row["target"] = vec3(entry.get("jobTarget", Vector3.ZERO))
    return row

func target_node_summary(node_value) -> Dictionary:
    if node_value == null:
        return { "state": "null" }
    if not is_instance_valid(node_value):
        return { "state": "freed" }
    var node := node_value as Node
    if node == null:
        return { "state": "valid_non_node" }
    var row := {
        "state": "valid",
        "name": node.name,
        "path": String(node.get_path())
    }
    var node_3d := node as Node3D
    if node_3d != null:
        row["position"] = vec3(node_3d.global_position)
    if node.has_meta("prop_id"):
        row["propId"] = String(node.get_meta("prop_id"))
    if node.has_meta("drop"):
        row["drop"] = String(node.get_meta("drop"))
    return row

func profile_speed_limit(entry: Dictionary) -> float:
    var limit := 6.4 * 1.15
    if entry.is_empty():
        return limit
    var profile = entry.get("motorProfile")
    if profile != null:
        var sprint_value = profile.get("sprint_speed")
        if sprint_value != null:
            limit = float(sprint_value) * 1.15
    return limit

func flat_cell(position: Vector3) -> Vector2i:
    if main != null and main.has_method("world_to_cell"):
        return Vector2i(int(main.call("world_to_cell", position.x)), int(main.call("world_to_cell", position.z)))
    return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

func add_failure(code: String, details: String) -> void:
    failure_reasons.append({ "code": code, "details": details, "time": rounded(elapsed) })
    results.append({ "name": TEST_ID, "passed": false, "details": "%s: %s" % [code, details] })
    failed = true
    report_data["finished"] = finished
    report_data["passed"] = false
    report_data["failureCount"] = failure_reasons.size()
    report_data["resultCount"] = results.size()
    report_data["results"] = results
    report_data["failureReasons"] = failure_reasons
    report_data["lastFailure"] = failure_reasons[failure_reasons.size() - 1]
    report_data["playerTimeline"] = player_timeline
    report_data["doorStateTimeline"] = door_timeline
    report_data["miraTimeline"] = mira_timeline
    report_data["miraRouteOrderTimeline"] = route_order_timeline
    report_data["miraSpeedSamples"] = mira_speed_samples
    report_data["visualCaptures"] = visual_captures
    report_data["npcScheduleMatrix"] = schedule_matrix
    var mira := npc_entry("mira")
    if not mira.is_empty():
        report_data["miraFailureSnapshot"] = npc_summary(mira)
    save_report()

func finish() -> void:
    if finished:
        return
    player_stop()
    finished = true
    report_data["finished"] = true
    report_data["passed"] = not failed
    report_data["failureCount"] = failure_reasons.size()
    report_data["resultCount"] = results.size()
    report_data["results"] = results
    report_data["failureReasons"] = failure_reasons
    report_data["playerTimeline"] = player_timeline
    report_data["doorStateTimeline"] = door_timeline
    report_data["miraTimeline"] = mira_timeline
    report_data["miraRouteOrderTimeline"] = route_order_timeline
    report_data["miraSpeedSamples"] = mira_speed_samples
    report_data["visualCaptures"] = visual_captures
    report_data["npcScheduleMatrix"] = schedule_matrix
    report_data["nightGuardNonGuardMatrix"] = night_matrix
    report_data["repairPlacementEvents"] = repair_placement_events
    report_data["sleepTimeline"] = sleep_timeline
    report_data["inventoryTimeline"] = inventory_timeline
    report_data["interactionTimeline"] = interaction_timeline
    report_data["morningNpcDepartureMatrix"] = morning_departure_matrix
    report_data["nikoTimeline"] = niko_timeline
    report_data["nikoForageProof"] = niko_proof
    report_data["nikoForagerState"] = forager_state_summary()
    save_report()
    mark_progress("finished")
    get_tree().quit(1 if failed else 0)

func player_stop() -> void:
    if player != null:
        player.set("automated_move", Vector3.ZERO)
        player.set("automated_sprint", false)

func save_report() -> void:
    var path := OS.get_environment("VOXEL_REAL_TUTORIAL_REPORT")
    if path == "":
        path = "user://real-tutorial-playthrough-report.json"
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        push_error("Could not write real tutorial report: %s" % path)
        return
    file.store_string(JSON.stringify(report_data, "  "))
    file.close()

func mark_progress(label: String) -> void:
    var path := OS.get_environment("VOXEL_REAL_TUTORIAL_PROGRESS")
    if path == "":
        return
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return
    var contents := "%s\nelapsed=%.3f\nfailures=%d\nmaxMiraSpeed=%.3f\n" % [
        label,
        elapsed,
        failure_reasons.size(),
        max_mira_flat_speed
    ]
    if not failure_reasons.is_empty():
        var last_failure: Dictionary = failure_reasons[failure_reasons.size() - 1]
        var failure_details := String(last_failure.get("details", ""))
        if failure_details.length() > 1200:
            failure_details = "%s..." % failure_details.substr(0, 1200)
        contents += "lastFailureCode=%s\nlastFailureDetails=%s\n" % [
            String(last_failure.get("code", "")),
            failure_details
        ]
    file.store_string(contents)
    file.close()

func watchdog_seconds() -> float:
    var raw := OS.get_environment("VOXEL_REAL_TUTORIAL_WATCHDOG_SECONDS").strip_edges()
    if raw == "":
        return 220.0
    return maxf(10.0, float(raw))

func vec3(value) -> Array:
    if value is Vector3:
        return [rounded(value.x), rounded(value.y), rounded(value.z)]
    return [0.0, 0.0, 0.0]

func vec2i(value) -> Array:
    if value is Vector2i:
        return [value.x, value.y]
    return [0, 0]

func vec3i(value) -> Array:
    if value is Vector3i:
        return [value.x, value.y, value.z]
    return [0, 0, 0]

func vec2i_array(values) -> Array:
    var result := []
    if not (values is Array):
        return result
    for value in values:
        result.append(vec2i(value))
    return result

func vec2i_array_limited(values, limit := 8) -> Array:
    var result := []
    if not (values is Array):
        return result
    for value in values:
        if result.size() >= limit:
            break
        result.append(vec2i(value))
    return result

func rounded(value: float) -> float:
    return roundf(value * 1000.0) / 1000.0
