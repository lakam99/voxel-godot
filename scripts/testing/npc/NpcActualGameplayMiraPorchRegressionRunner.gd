extends Node

const MENU_SCENE: PackedScene = preload("res://scenes/MainMenu.tscn")
const TEST_ID := "npc_actual_gameplay_mira_porch_regression"
const CELL := 1.35
const CAPTURE_WIDTH := 1280
const CAPTURE_HEIGHT := 720
const STARTUP_FRAMES := 80
const POST_ACTION_FRAMES := 24
const SAMPLE_EVERY_FRAMES := 6
const OBSERVE_SECONDS := 72.0
const PORCH_LEAVE_DISTANCE := CELL * 3.0
const PORCH_SETTLED_FRAMES := 30
const DOOR_CLOSE_APPROACH_DISTANCE := CELL * 0.75

var menu: Node = null
var main: Node3D = null
var player: CharacterBody3D = null
var camera: Camera3D = null
var elapsed := 0.0
var finished := false
var failed := false
var report_data: Dictionary = {}
var results: Array[Dictionary] = []
var failure_reasons: Array[Dictionary] = []
var visual_captures: Array[Dictionary] = []
var player_timeline: Array[Dictionary] = []
var door_timeline: Array[Dictionary] = []
var mira_timeline: Array[Dictionary] = []
var input_timeline: Array[Dictionary] = []
var startup_loading_steps: Array[Dictionary] = []
var screenshot_dir := ""
var progress_path := ""
var report_path := ""
var starter_door: Node3D = null
var starter_door_position := Vector3.ZERO
var mira_first_position := Vector3.ZERO
var mira_first_valid := false
var mira_previous_position := Vector3.ZERO
var mira_previous_time := 0.0
var mira_previous_valid := false
var mira_total_flat_distance := 0.0
var mira_max_flat_speed := 0.0
var mira_max_player_porch_distance := 0.0
var mira_left_player_porch := false
var mira_reached_strict_home := false

func _ready() -> void:
    configure_paths()
    get_viewport().size = Vector2i(CAPTURE_WIDTH, CAPTURE_HEIGHT)
    call_deferred("run")

func _process(delta: float) -> void:
    if finished:
        return
    elapsed += maxf(delta, 0.0)
    var limit := watchdog_seconds()
    if elapsed > limit:
        add_failure("runner_watchdog", "runner exceeded %.1f seconds" % limit)
        finish()

func configure_paths() -> void:
    report_path = OS.get_environment("VOXEL_ACTUAL_GAMEPLAY_MIRA_REPORT").strip_edges()
    if report_path == "":
        report_path = ProjectSettings.globalize_path("res://artifacts/npc/reports/actual-gameplay-mira-porch-regression.json")
    progress_path = OS.get_environment("VOXEL_ACTUAL_GAMEPLAY_MIRA_PROGRESS").strip_edges()
    if progress_path == "":
        progress_path = ProjectSettings.globalize_path("res://artifacts/npc/progress/actual-gameplay-mira-porch-regression.txt")
    screenshot_dir = OS.get_environment("VOXEL_ACTUAL_GAMEPLAY_MIRA_SCREENSHOT_DIR").strip_edges()
    if screenshot_dir == "":
        screenshot_dir = ProjectSettings.globalize_path("res://artifacts/npc/screenshots/actual-gameplay-mira-porch-regression")
    ensure_dir(report_path.get_base_dir())
    ensure_dir(progress_path.get_base_dir())
    ensure_dir(screenshot_dir)

func run() -> void:
    mark_progress("start")
    report_data = {
        "schemaVersion": 1,
        "testId": TEST_ID,
        "runToken": OS.get_environment("VOXEL_ACTUAL_GAMEPLAY_MIRA_RUN_TOKEN"),
        "gitBranch": OS.get_environment("VOXEL_GIT_BRANCH"),
        "gitCommit": OS.get_environment("VOXEL_GIT_COMMIT"),
        "finished": false,
        "passed": false,
        "failureCount": 0,
        "resultCount": 0,
        "actualGameplayDerived": true,
        "launchPath": "project main scene MainMenu.tscn New Game button input" if real_boot_attached_to_menu() else "testing scene instantiates MainMenu.tscn New Game button input",
        "realBootAttachedToMainMenu": real_boot_attached_to_menu(),
        "usesVoxelPlaytest": OS.get_environment("VOXEL_PLAYTEST").strip_edges() != "",
        "voxelPlaytestEnv": OS.get_environment("VOXEL_PLAYTEST").strip_edges(),
        "voxelTestSeedEnv": OS.get_environment("VOXEL_TEST_SEED").strip_edges(),
        "savePathOverride": OS.get_environment("VOXEL_SAVE_PATH_OVERRIDE").strip_edges(),
        "savePathOverridePurpose": "isolate acceptance run save data without enabling playtest-only behavior",
        "prohibitedGameplayShortcuts": {
            "tutorialStateStaging": false,
            "directActionCalls": false,
            "actorTeleporting": false,
            "playerControllerAutomation": false,
            "syntheticViewportInput": true,
            "directNpcMovement": false
        },
        "screenshotDir": screenshot_dir,
        "visualCaptures": visual_captures,
        "playerTimeline": player_timeline,
        "doorTimeline": door_timeline,
        "miraTimeline": mira_timeline,
        "inputTimeline": input_timeline,
        "startupLoadingSteps": startup_loading_steps,
        "scriptErrorScan": { "status": "pending-wrapper-scan", "matches": [] },
        "forbiddenCallSelfScan": { "status": "passed-by-wrapper-before-launch" }
    }
    if bool(report_data.get("usesVoxelPlaytest", false)):
        add_failure("actual_gameplay_env_invalid", "VOXEL_PLAYTEST must be unset for this acceptance gate")
        finish()
        return
    if OS.get_environment("VOXEL_TEST_SEED").strip_edges() != "":
        add_failure("actual_gameplay_seed_invalid", "VOXEL_TEST_SEED must be unset because production New Game ignores it outside playtest mode")
        finish()
        return
    if not await launch_main_via_menu_input():
        finish()
        return
    bind_scene_nodes()
    await wait_physics_frames(STARTUP_FRAMES)
    bind_scene_nodes()
    if main == null or player == null or camera == null:
        add_failure("scene_bootstrap_failed", "main/player/camera missing after New Game boot")
        finish()
        return
    report_data["bootedSeed"] = String(main.get("seed_text"))
    report_data["initialMouseMode"] = Input.get_mouse_mode()
    report_data["initialPlayerAutomation"] = player_automation_state()
    if bool(player.get("automated_input")):
        add_failure("actual_gameplay_player_automation_enabled", "player automated_input was enabled in a real-gameplay gate")
        finish()
        return
    if not await wait_for_tutorial_town_ready(180.0):
        finish()
        return
    await run_knock_and_mira_observation()
    finish()

func launch_main_via_menu_input() -> bool:
    Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
    var existing_menu := existing_main_menu_parent()
    if existing_menu != null:
        menu = existing_menu
        mark_progress("main_menu_real_boot_attached")
    else:
        menu = MENU_SCENE.instantiate()
        if menu == null:
            add_failure("main_menu_bootstrap_failed", "MainMenu.tscn could not be instantiated")
            return false
        add_child(menu)
        mark_progress("main_menu_instantiated")
    await wait_process_frames(4)
    var button := menu.get("new_game_button") as Button
    if button == null or not is_instance_valid(button):
        add_failure("main_menu_new_game_button_missing", "Title menu did not expose a visible New Game button")
        return false
    await capture_stage("menu_before_new_game", { "button": control_summary(button) })
    dispatch_mouse_button(button_center(button), MOUSE_BUTTON_LEFT, true, "menu_new_game_press")
    dispatch_mouse_button(button_center(button), MOUSE_BUTTON_LEFT, false, "menu_new_game_release")
    mark_progress("main_menu_new_game_button_input")
    var max_frames := ceili(140.0 * float(Engine.physics_ticks_per_second))
    var observed_main := false
    for frame in range(max_frames):
        await get_tree().process_frame
        var active_value = menu.get("active_main") if menu != null else null
        if active_value is Node3D:
            main = active_value
            if not observed_main:
                observed_main = true
                connect_main_loading_diagnostics()
                mark_progress("main_menu_active_main_observed")
        if main != null and is_instance_valid(main):
            var loading_active := bool(main.get("startup_loading_active"))
            if frame % 60 == 0:
                mark_progress("main_menu_waiting_for_main_load active=%s loading=%s" % [str(main != null), str(loading_active)])
            if not loading_active:
                report_data["mainMenuLaunch"] = {
                    "clickedViaInput": true,
                    "frames": frame,
                    "loadingActive": loading_active
                }
                mark_progress("main_menu_new_game_loaded")
                return true
    add_failure("main_menu_launch_timeout", "New Game button input did not produce a loaded Main scene")
    return false

func real_boot_attached_to_menu() -> bool:
    return existing_main_menu_parent() != null

func existing_main_menu_parent() -> Node:
    var parent := get_parent()
    if parent == null:
        return null
    var button = parent.get("new_game_button")
    if button is Button:
        return parent
    return null

func connect_main_loading_diagnostics() -> void:
    if main == null or not main.has_signal("startup_loading_step"):
        return
    var callback := Callable(self, "_on_main_startup_loading_step")
    if not main.is_connected("startup_loading_step", callback):
        main.connect("startup_loading_step", callback)

func _on_main_startup_loading_step(message: String) -> void:
    startup_loading_steps.append({
        "time": rounded(elapsed),
        "message": message
    })
    report_data["startupLoadingSteps"] = startup_loading_steps
    mark_progress("main_loading_step:%s" % message)

func wait_for_tutorial_town_ready(max_seconds: float) -> bool:
    var max_frames := ceili(max_seconds * float(Engine.physics_ticks_per_second))
    for frame in range(max_frames):
        bind_scene_nodes()
        if main != null and player != null and camera != null:
            var tutorial = main.get("tutorial_system")
            var state := tutorial_state_summary(tutorial)
            var start_cell := state_start_cell(tutorial, flat_cell(player.global_position))
            var player_cell := flat_cell(player.global_position)
            var starter_door_cell := Vector2i(start_cell.x, start_cell.y - 3)
            var expected_position := world_position_for_flat_cell(starter_door_cell)
            starter_door = nearest_block("door", expected_position)
            var tutorial_ready := bool(state.get("started", false)) and bool(state.get("repairActive", false))
            var start_ready := start_cell != Vector2i.ZERO and absi(player_cell.x - start_cell.x) <= 4 and absi(player_cell.y - start_cell.y) <= 4
            var door_ready := starter_door != null and flat_distance(starter_door.global_position, expected_position) <= CELL * 2.0
            if tutorial_ready and start_ready and door_ready:
                starter_door_position = starter_door.global_position
                report_data["tutorialTownReady"] = {
                    "frame": frame,
                    "door": block_summary(starter_door),
                    "doorCell": vec2i(starter_door_cell),
                    "expectedDoorPosition": vec3(expected_position),
                    "player": vec3(player.global_position),
                    "playerCell": vec2i(player_cell),
                    "startCell": vec2i(start_cell),
                    "tutorialState": state,
                    "blocks": block_count()
                }
                sample_player("tutorial_town_ready")
                sample_door("tutorial_town_ready", starter_door)
                mark_progress("tutorial_town_ready")
                return true
        if frame % 60 == 0:
            mark_progress("waiting_tutorial_town_ready frame=%d blocks=%d" % [frame, block_count()])
        await get_tree().physics_frame
    add_failure("starter_door_missing", "no generated starter door became available near tutorial start after %.1fs" % max_seconds)
    return false

func run_knock_and_mira_observation() -> void:
    var tutorial = main.get("tutorial_system")
    report_data["initialTutorialState"] = tutorial_state_summary(tutorial)
    await capture_stage("gameplay_start_before_door_walk", {
        "tutorialState": report_data["initialTutorialState"],
        "player": player_summary()
    })
    mark_progress("walking_to_player_house_door")
    var reached := await walk_to_target_with_key_input(starter_door_position, DOOR_CLOSE_APPROACH_DISTANCE, 12.0, "walking_to_player_house_door")
    sample_player("near_player_house_door")
    sample_door("before_knock_click", starter_door)
    if not reached:
        add_failure("player_could_not_reach_starter_door_by_input", JSON.stringify({
            "player": player_summary(),
            "door": block_summary(starter_door),
            "distance": rounded(flat_distance(player.global_position, starter_door_position))
        }))
        return
    report_data["playerDoorApproach"] = {
        "target": vec3(starter_door_position),
        "distance": rounded(flat_distance(player.global_position, starter_door_position)),
        "requiredDistance": rounded(DOOR_CLOSE_APPROACH_DISTANCE),
        "player": player_summary()
    }
    var hit := await aim_until_block_hit(starter_door, "starter_door")
    await capture_stage("player_pov_intro_door_before_click", {
        "door": block_summary(starter_door),
        "hit": hit,
        "player": player_summary()
    })
    if not block_hit_matches(hit, starter_door):
        add_failure("starter_door_aim_miss_before_knock", JSON.stringify({
            "door": block_summary(starter_door),
            "hit": hit,
            "player": player_summary()
        }))
        return
    mark_progress("right_clicking_player_house_door")
    dispatch_mouse_button(viewport_center(), MOUSE_BUTTON_RIGHT, true, "starter_door_right_click_press")
    dispatch_mouse_button(viewport_center(), MOUSE_BUTTON_RIGHT, false, "starter_door_right_click_release")
    await wait_physics_frames(POST_ACTION_FRAMES)
    sample_door("after_knock_click", starter_door)
    sample_player("after_knock_click")
    await capture_stage("player_pov_intro_dialogue_open", {
        "door": block_summary(starter_door),
        "tutorialState": tutorial_state_summary(tutorial),
        "dialogueOpen": hud_dialogue_open()
    })
    var after_door_state := tutorial_state_summary(tutorial)
    report_data["afterDoorTutorialState"] = after_door_state
    var opened := bool(after_door_state.get("doorOpened", false))
    var dialogue_open := hud_dialogue_open()
    results.append({
        "name": "actual_input_opened_player_house_door_and_dialogue",
        "passed": opened and dialogue_open,
        "details": "doorOpened=%s dialogueOpen=%s" % [str(opened), str(dialogue_open)]
    })
    if not opened or not dialogue_open:
        add_failure("actual_input_path_failed_before_mira_observation", "doorOpened=%s dialogueOpen=%s" % [str(opened), str(dialogue_open)])
        return
    mark_progress("closing_intro_dialogue_with_visible_button")
    var close_button := dialogue_close_button()
    report_data["dialogueCloseButton"] = control_summary(close_button)
    if close_button == null:
        add_failure("dialogue_close_button_missing", "HUD dialogue was open but no visible Close button was found")
        return
    dispatch_mouse_button(button_center(close_button), MOUSE_BUTTON_LEFT, true, "dialogue_close_button_press")
    dispatch_mouse_button(button_center(close_button), MOUSE_BUTTON_LEFT, false, "dialogue_close_button_release")
    await wait_physics_frames(POST_ACTION_FRAMES)
    var after_dialogue_state := tutorial_state_summary(tutorial)
    report_data["afterDialogueTutorialState"] = after_dialogue_state
    await capture_stage("player_pov_dialogue_acknowledged", {
        "tutorialState": after_dialogue_state,
        "dialogueOpen": hud_dialogue_open(),
        "closeButton": report_data["dialogueCloseButton"]
    })
    if hud_dialogue_open():
        add_failure("dialogue_still_open_after_close_button_input", "HUD dialogue remained open after visible Close button input")
        return
    if not bool(after_dialogue_state.get("elderAcknowledged", false)):
        add_failure("mira_dialogue_ack_not_recorded", "tutorial state did not record elder acknowledgement after HUD close")
        return
    mark_progress("observing_mira_after_knock")
    await observe_mira_after_knock(OBSERVE_SECONDS)
    var mira := npc_entry("mira")
    report_data["miraFinal"] = npc_summary(mira) if not mira.is_empty() else {}
    report_data["miraFinalHomeInteriorStatus"] = strict_home_status(mira)
    report_data["miraTotalFlatDistance"] = rounded(mira_total_flat_distance)
    report_data["miraMaxFlatSpeed"] = rounded(mira_max_flat_speed)
    report_data["miraMaxPlayerPorchDistance"] = rounded(mira_max_player_porch_distance)
    report_data["miraLeftPlayerPorch"] = mira_left_player_porch
    report_data["miraReachedStrictHome"] = mira_reached_strict_home
    var target = mira_visual_target(mira)
    await capture_stage("player_pov_mira_post_knock_final_state", {
        "mira": report_data["miraFinal"],
        "homeStatus": report_data["miraFinalHomeInteriorStatus"],
        "leftPlayerPorch": mira_left_player_porch,
        "maxPlayerPorchDistance": rounded(mira_max_player_porch_distance)
    }, target)
    var observer_view := mira_observer_view(mira)
    if not observer_view.is_empty():
        await capture_observer_stage("observer_mira_post_knock_final_state", observer_view.get("eye", Vector3.ZERO), observer_view.get("target", Vector3.ZERO), {
            "mira": report_data["miraFinal"],
            "homeStatus": report_data["miraFinalHomeInteriorStatus"],
            "leftPlayerPorch": mira_left_player_porch,
            "maxPlayerPorchDistance": rounded(mira_max_player_porch_distance),
            "camera": {
                "eye": vec3(observer_view.get("eye", Vector3.ZERO)),
                "target": vec3(observer_view.get("target", Vector3.ZERO))
            }
        })
    if not mira_left_player_porch:
        add_failure("mira_did_not_leave_player_porch_after_knock", JSON.stringify({
            "maxPlayerPorchDistance": rounded(mira_max_player_porch_distance),
            "leaveDistance": rounded(PORCH_LEAVE_DISTANCE),
            "totalFlatDistance": rounded(mira_total_flat_distance),
            "mira": report_data["miraFinal"],
            "starterDoor": block_summary(starter_door),
            "captures": capture_names()
        }))
        return
    if not mira_reached_strict_home:
        add_failure("mira_left_player_porch_but_did_not_reach_strict_home", JSON.stringify(report_data["miraFinalHomeInteriorStatus"]))
        return
    results.append({
        "name": "mira_returned_home_after_knock_from_actual_gameplay",
        "passed": true,
        "details": "Mira left the player porch and reached strict home interior through live gameplay; captures=%s" % JSON.stringify(capture_names())
    })

func observe_mira_after_knock(seconds: float) -> void:
    var frame_count := ceili(seconds * float(Engine.physics_ticks_per_second))
    var left_settled_frames := 0
    var home_settled_frames := 0
    for frame in range(frame_count):
        await get_tree().physics_frame
        var mira := npc_entry("mira")
        track_mira(mira)
        var home_status := strict_home_status(mira)
        if not mira.is_empty():
            var body := mira.get("body") as Node3D
            if body != null and is_instance_valid(body):
                var distance_to_player_porch := flat_distance(body.global_position, starter_door_position)
                if distance_to_player_porch > PORCH_LEAVE_DISTANCE:
                    left_settled_frames += 1
                else:
                    left_settled_frames = 0
                if bool(home_status.get("strictInside", false)):
                    home_settled_frames += 1
                else:
                    home_settled_frames = 0
                if left_settled_frames >= PORCH_SETTLED_FRAMES:
                    mira_left_player_porch = true
                if home_settled_frames >= PORCH_SETTLED_FRAMES:
                    mira_reached_strict_home = true
        if frame % SAMPLE_EVERY_FRAMES == 0:
            sample_mira("observe_mira_%04d" % frame, home_status)
            sample_player("observe_mira_%04d" % frame)
            mark_progress("observing_mira_after_knock_%04d" % frame)
        if mira_left_player_porch and mira_reached_strict_home:
            return

func track_mira(entry: Dictionary) -> void:
    if entry.is_empty():
        mira_previous_valid = false
        mira_previous_time = elapsed
        return
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        mira_previous_valid = false
        mira_previous_time = elapsed
        return
    var current := body.global_position
    if not mira_first_valid:
        mira_first_position = current
        mira_first_valid = true
    var distance_to_player_porch := flat_distance(current, starter_door_position)
    mira_max_player_porch_distance = maxf(mira_max_player_porch_distance, distance_to_player_porch)
    if mira_previous_valid:
        var flat_delta := flat_distance(current, mira_previous_position)
        mira_total_flat_distance += flat_delta
        var sample_dt := maxf(elapsed - mira_previous_time, 1.0 / float(Engine.physics_ticks_per_second))
        mira_max_flat_speed = maxf(mira_max_flat_speed, flat_delta / maxf(sample_dt, 0.0001))
    mira_previous_position = current
    mira_previous_time = elapsed
    mira_previous_valid = true

func walk_to_target_with_key_input(target: Vector3, stop_distance: float, timeout_seconds: float, label: String) -> bool:
    var started := elapsed
    var reached := false
    var key_down := false
    while elapsed - started < timeout_seconds:
        var offset := Vector3(target.x - player.global_position.x, 0.0, target.z - player.global_position.z)
        if offset.length() <= stop_distance:
            reached = true
            break
        aim_at(target + Vector3(0.0, CELL * 0.5, 0.0))
        if not key_down:
            dispatch_key(KEY_W, true, "%s_forward_press" % label)
            key_down = true
        await get_tree().physics_frame
        if int(Engine.get_physics_frames()) % SAMPLE_EVERY_FRAMES == 0:
            sample_player(label)
            mark_progress(label)
    if key_down:
        dispatch_key(KEY_W, false, "%s_forward_release" % label)
    await wait_physics_frames(4)
    if not reached:
        reached = flat_distance(player.global_position, target) <= stop_distance
    return reached

func aim_until_block_hit(block: Node3D, label: String) -> Dictionary:
    var summary := {}
    if block == null or not is_instance_valid(block):
        return { "hit": false, "reason": "missing_block" }
    for height_scale in [0.25, 0.50, 0.75, 0.12]:
        aim_at(block.global_position + Vector3(0.0, CELL * float(height_scale), 0.0))
        await wait_physics_frames(4)
        summary = interaction_hit_summary()
        input_timeline.append({
            "label": "aim_%s_%s" % [label, str(height_scale)],
            "target": vec3(block.global_position),
            "hit": summary
        })
        if block_hit_matches(summary, block):
            return summary
    return summary

func aim_at(target: Vector3) -> void:
    if player == null or camera == null:
        return
    var flat_target := Vector3(target.x, player.global_position.y, target.z)
    if flat_target.distance_to(player.global_position) > 0.05:
        player.look_at(flat_target, Vector3.UP)
    if target.distance_to(camera.global_position) > 0.05:
        camera.look_at(target, Vector3.UP)
    player.set("pitch", camera.rotation.x)

func dispatch_key(keycode: int, pressed: bool, label: String) -> void:
    var event := InputEventKey.new()
    event.keycode = keycode
    event.physical_keycode = keycode
    event.pressed = pressed
    event.echo = false
    input_timeline.append({
        "label": label,
        "kind": "key",
        "keycode": keycode,
        "pressed": pressed,
        "time": rounded(elapsed)
    })
    report_data["inputTimeline"] = input_timeline
    Input.parse_input_event(event)

func dispatch_mouse_button(position: Vector2, button_index: int, pressed: bool, label: String) -> void:
    var event := InputEventMouseButton.new()
    event.button_index = button_index
    event.pressed = pressed
    event.position = position
    event.global_position = position
    input_timeline.append({
        "label": label,
        "kind": "mouse_button",
        "button": button_index,
        "pressed": pressed,
        "position": vec2(position),
        "time": rounded(elapsed),
        "routedThroughViewportInput": true
    })
    report_data["inputTimeline"] = input_timeline
    get_viewport().push_input(event)

func capture_stage(stage: String, extra_sample: Dictionary = {}, look_target = null) -> void:
    if look_target is Vector3:
        aim_at(look_target)
    await wait_process_frames(3)
    save_capture(stage, extra_sample)

func capture_observer_stage(stage: String, eye: Vector3, target: Vector3, extra_sample: Dictionary = {}) -> void:
    if main == null:
        return
    var previous_camera := get_viewport().get_camera_3d()
    var observer := Camera3D.new()
    observer.name = "MiraObserverCaptureCamera"
    observer.fov = 58.0
    main.add_child(observer)
    observer.global_position = eye
    observer.look_at(target, Vector3.UP)
    var light := OmniLight3D.new()
    light.name = "MiraObserverCaptureLight"
    light.light_energy = 5.0
    light.omni_range = CELL * 7.0
    main.add_child(light)
    light.global_position = target + Vector3(0.0, CELL * 1.5, 0.0)
    observer.current = true
    await wait_process_frames(3)
    save_capture(stage, extra_sample)
    if previous_camera != null and is_instance_valid(previous_camera):
        previous_camera.make_current()
    light.queue_free()
    observer.queue_free()

func save_capture(stage: String, extra_sample: Dictionary = {}) -> void:
    var image := get_viewport().get_texture().get_image()
    var path := screenshot_dir.path_join("%s.png" % stage)
    var err := image.save_png(path)
    var byte_count := 0
    if FileAccess.file_exists(path):
        byte_count = FileAccess.get_file_as_bytes(path).size()
    var capture := {
        "stage": stage,
        "path": path,
        "saved": err == OK and byte_count > 0,
        "bytes": byte_count,
        "time": rounded(elapsed),
        "cameraMode": "player_pov" if camera != null and get_viewport().get_camera_3d() == camera else "current_viewport",
        "sample": extra_sample
    }
    visual_captures.append(capture)
    report_data["visualCaptures"] = visual_captures
    if not bool(capture.get("saved", false)):
        add_failure("visual_capture_failed", JSON.stringify(capture))

func bind_scene_nodes() -> void:
    if main == null:
        return
    player = main.get("player") as CharacterBody3D
    if player != null:
        camera = player.get("camera") as Camera3D
        if camera != null:
            camera.make_current()

func interaction_hit_summary() -> Dictionary:
    if player == null or not player.has_method("view_ray"):
        return { "hit": false, "reason": "missing_player_view_ray" }
    var hit: Dictionary = player.call("view_ray", 10.5, true)
    if hit.is_empty():
        return { "hit": false }
    var collider := hit.get("collider") as Node
    var block_node := collider
    if main != null and main.has_method("interaction_block_from_collider"):
        block_node = main.call("interaction_block_from_collider", collider) as Node
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

func block_hit_matches(summary: Dictionary, block: Node) -> bool:
    if block == null or not bool(summary.get("hit", false)):
        return false
    return String(summary.get("blockPath", "")) == String(block.get_path()) and bool(summary.get("withinReach", false))

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
        "townCenter": vec2i(state.get("townCenter", Vector2i.ZERO)),
        "startCell": vec2i(state.get("startCell", Vector2i.ZERO)),
        "homeRefresh": state.get("homeRefresh", {})
    }

func state_start_cell(tutorial, fallback: Vector2i) -> Vector2i:
    if tutorial == null or not tutorial.has_method("state"):
        return fallback
    var state: Dictionary = tutorial.call("state")
    var value = state.get("startCell", fallback)
    return value if value is Vector2i else fallback

func hud_dialogue_open() -> bool:
    var hud = main.get("hud") if main != null else null
    return hud != null and hud.has_method("is_dialogue_open") and bool(hud.call("is_dialogue_open"))

func dialogue_close_button() -> Button:
    var hud = main.get("hud") if main != null else null
    if hud == null:
        return null
    var panel = hud.get("dialogue_panel")
    if not (panel is Control):
        return null
    return find_visible_button_by_text(panel, "Close")

func find_visible_button_by_text(root: Node, text: String) -> Button:
    if root is Button:
        var button := root as Button
        if button.visible and not button.disabled and button.text == text:
            return button
    for child in root.get_children():
        var found := find_visible_button_by_text(child, text)
        if found != null:
            return found
    return null

func strict_home_status(entry: Dictionary) -> Dictionary:
    if entry.is_empty():
        return { "strictInside": false, "reason": "missing_entry" }
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return { "strictInside": false, "reason": "missing_body" }
    var npc_system = main.get("npc_system") if main != null else null
    var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
    var strict_inside := false
    if autonomy != null and autonomy.has_method("is_inside_home_interior"):
        strict_inside = bool(autonomy.call("is_inside_home_interior", entry, body.global_position))
    var home_position := entry_position(entry, "homePosition", body.global_position)
    var porch_position := entry_position(entry, "porchPosition", home_position)
    return {
        "strictInside": strict_inside,
        "position": vec3(body.global_position),
        "homePosition": vec3(home_position),
        "porchPosition": vec3(porch_position),
        "distanceToHome": rounded(flat_distance(body.global_position, home_position)),
        "distanceToPorch": rounded(flat_distance(body.global_position, porch_position)),
        "distanceToPlayerPorch": rounded(flat_distance(body.global_position, starter_door_position)),
        "insideHomeMeta": bool(body.get_meta("npc_inside_home", false))
    }

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

func npc_summary(entry: Dictionary) -> Dictionary:
    if entry.is_empty():
        return {}
    var body := entry.get("body") as Node3D
    var body_valid := body != null and is_instance_valid(body)
    var position := body.global_position if body_valid else Vector3.ZERO
    return {
        "id": String(entry.get("id", "")),
        "name": String(entry.get("name", "")),
        "role": String(entry.get("role", "")),
        "position": vec3(position),
        "flatCell": vec2i(flat_cell(position)),
        "homeCell": vec2i(entry.get("homeCell", Vector2i.ZERO)),
        "porchCell": vec2i(entry.get("porchCell", Vector2i.ZERO)),
        "homePosition": vec3(entry_position(entry, "homePosition", position)),
        "porchPosition": vec3(entry_position(entry, "porchPosition", position)),
        "distanceToPlayerPorch": rounded(flat_distance(position, starter_door_position)),
        "distanceFromFirstObserved": rounded(flat_distance(position, mira_first_position)) if mira_first_valid else 0.0,
        "routeStatus": String(entry.get("routeStatus", "")),
        "routeReason": String(entry.get("routeReason", "")),
        "routeGoalCell": vec2i(entry.get("routeGoalCell", Vector2i.ZERO)),
        "routeTarget": vec3(entry_position(entry, "routeTarget", position)),
        "behaviorGoal": String(entry.get("behaviorGoal", "")),
        "scheduleState": String(entry.get("scheduleState", "")),
        "homeBlocked": bool(entry.get("homeBlocked", false)),
        "insideHomeMeta": bool(body.get_meta("npc_inside_home", false)) if body_valid else false,
        "blockedContact": String(body.get_meta("npc_blocked_contact", "")) if body_valid else "",
        "blockedContactName": String(body.get_meta("npc_blocked_contact_name", "")) if body_valid else "",
        "lastMoveDistance": rounded(float(entry.get("lastMoveDistance", 0.0))),
        "activeDoorPortalId": String(entry.get("activeDoorPortalId", "")),
        "activeDoorDirection": String(entry.get("activeDoorDirection", ""))
    }

func sample_mira(label: String, home_status: Dictionary = {}) -> void:
    var mira := npc_entry("mira")
    var summary := npc_summary(mira) if not mira.is_empty() else { "missing": true }
    summary["label"] = label
    summary["time"] = rounded(elapsed)
    summary["homeStatus"] = home_status if not home_status.is_empty() else strict_home_status(mira)
    summary["leftPlayerPorch"] = mira_left_player_porch
    mira_timeline.append(summary)
    report_data["miraTimeline"] = mira_timeline

func sample_player(label: String) -> void:
    if player == null:
        return
    player_timeline.append({
        "label": label,
        "time": rounded(elapsed),
        "position": vec3(player.global_position),
        "velocity": vec3(player.velocity),
        "flatCell": vec2i(flat_cell(player.global_position)),
        "mouseMode": Input.get_mouse_mode(),
        "automation": player_automation_state()
    })
    report_data["playerTimeline"] = player_timeline

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
    report_data["doorTimeline"] = door_timeline

func player_summary() -> Dictionary:
    if player == null:
        return {}
    return {
        "position": vec3(player.global_position),
        "velocity": vec3(player.velocity),
        "flatCell": vec2i(flat_cell(player.global_position)),
        "mouseMode": Input.get_mouse_mode(),
        "automation": player_automation_state()
    }

func player_automation_state() -> Dictionary:
    if player == null:
        return {}
    return {
        "automatedInput": bool(player.get("automated_input")),
        "automatedMove": vec3(player.get("automated_move")),
        "automatedSprint": bool(player.get("automated_sprint")),
        "automatedJump": bool(player.get("automated_jump"))
    }

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
        var block_body := block_value as Node3D
        if block_body == null or not is_instance_valid(block_body):
            continue
        if String(block_body.get_meta("block_type", "")) != block_type:
            continue
        var distance := flat_distance(block_body.global_position, origin)
        if distance < best_distance:
            best_distance = distance
            best = block_body
    return best

func block_count() -> int:
    if main == null:
        return 0
    var blocks_value = main.get("blocks")
    if not (blocks_value is Dictionary):
        return 0
    return (blocks_value as Dictionary).size()

func block_summary(block: Node3D) -> Dictionary:
    if block == null:
        return {}
    return {
        "name": block.name,
        "path": String(block.get_path()),
        "type": String(block.get_meta("block_type", "")) if block.has_meta("block_type") else "",
        "position": vec3(block.global_position),
        "open": bool(block.get_meta("open", false)),
        "cell": vec3i(block.get_meta("cell", Vector3i.ZERO))
    }

func control_summary(control: Control) -> Dictionary:
    if control == null:
        return {}
    var rect := control.get_global_rect()
    return {
        "name": control.name,
        "path": String(control.get_path()),
        "visible": control.visible,
        "disabled": bool(control.get("disabled")) if control is Button else false,
        "rectPosition": vec2(rect.position),
        "rectSize": vec2(rect.size),
        "center": vec2(rect.get_center())
    }

func entry_position(entry: Dictionary, key: String, fallback: Vector3) -> Vector3:
    var value = entry.get(key, fallback)
    if value is Vector3:
        return value
    return fallback

func mira_visual_target(entry: Dictionary):
    if entry.is_empty():
        return null
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return null
    return body.global_position + Vector3(0.0, CELL * 0.8, 0.0)

func mira_observer_view(entry: Dictionary) -> Dictionary:
    if entry.is_empty():
        return {}
    var body := entry.get("body") as Node3D
    if body == null or not is_instance_valid(body):
        return {}
    var target := body.global_position + Vector3(0.0, CELL * 0.82, 0.0)
    var home := entry_position(entry, "homePosition", body.global_position)
    var porch := entry_position(entry, "porchPosition", home + Vector3(0.0, 0.0, CELL))
    var axis := porch - home
    axis.y = 0.0
    if axis.length_squared() <= 0.0001:
        axis = Vector3(0.0, 0.0, 1.0)
    axis = axis.normalized()
    var interior_direction := -axis
    var side := Vector3(-axis.z, 0.0, axis.x)
    if side.length_squared() <= 0.0001:
        side = Vector3(1.0, 0.0, 0.0)
    side = side.normalized()
    var eye := target + interior_direction * CELL * 3.0 + side * CELL * 1.4 + Vector3(0.0, CELL * 1.05, 0.0)
    return {
        "eye": eye,
        "target": target
    }

func world_position_for_flat_cell(cell: Vector2i) -> Vector3:
    var x := float(cell.x) * CELL
    var z := float(cell.y) * CELL
    var y := 0.0
    if main != null and main.has_method("surface_y_at_position"):
        y = float(main.call("surface_y_at_position", Vector3(x, 0.0, z))) + 0.08
    return Vector3(x, y, z)

func flat_cell(position: Vector3) -> Vector2i:
    return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

func flat_distance(a: Vector3, b: Vector3) -> float:
    return Vector2(a.x - b.x, a.z - b.z).length()

func viewport_center() -> Vector2:
    return get_viewport().get_visible_rect().size * 0.5

func button_center(button: Button) -> Vector2:
    return button.get_global_rect().get_center() if button != null else viewport_center()

func wait_physics_frames(count: int) -> void:
    for i in range(count):
        await get_tree().physics_frame

func wait_process_frames(count: int) -> void:
    for i in range(count):
        await get_tree().process_frame

func add_failure(code: String, details: String) -> void:
    failed = true
    var failure := {
        "code": code,
        "details": details,
        "time": rounded(elapsed)
    }
    failure_reasons.append(failure)
    report_data["lastFailure"] = failure
    report_data["failureReasons"] = failure_reasons
    print("[FAIL] %s %s" % [code, details])
    save_report(false)

func finish() -> void:
    if finished:
        return
    finished = true
    release_pressed_inputs()
    var passed := not failed and failure_reasons.is_empty()
    report_data["finished"] = true
    report_data["passed"] = passed
    report_data["failureCount"] = failure_reasons.size()
    report_data["resultCount"] = results.size()
    report_data["results"] = results
    report_data["failureReasons"] = failure_reasons
    report_data["visualCaptures"] = visual_captures
    report_data["playerTimeline"] = player_timeline
    report_data["doorTimeline"] = door_timeline
    report_data["miraTimeline"] = mira_timeline
    report_data["inputTimeline"] = input_timeline
    report_data["completedAtUnix"] = Time.get_unix_time_from_system()
    save_report(true)
    mark_progress("finished passed=%s failures=%d" % [str(passed), failure_reasons.size()])
    await wait_process_frames(2)
    get_tree().quit(0 if passed else 1)

func save_report(done: bool) -> void:
    report_data["finished"] = done
    report_data["passed"] = not failed and failure_reasons.is_empty()
    report_data["failureCount"] = failure_reasons.size()
    report_data["resultCount"] = results.size()
    report_data["results"] = results
    report_data["failureReasons"] = failure_reasons
    var file := FileAccess.open(report_path, FileAccess.WRITE)
    if file == null:
        return
    file.store_string(JSON.stringify(report_data, "  "))
    file.close()

func mark_progress(label: String) -> void:
    if progress_path == "":
        return
    var file := FileAccess.open(progress_path, FileAccess.WRITE)
    if file == null:
        return
    file.store_string("%s\nelapsed=%.3f\nfailures=%d\n" % [label, elapsed, failure_reasons.size()])
    file.close()

func release_pressed_inputs() -> void:
    for key in [KEY_W, KEY_A, KEY_S, KEY_D, KEY_SHIFT, KEY_ESCAPE]:
        var event := InputEventKey.new()
        event.keycode = key
        event.physical_keycode = key
        event.pressed = false
        Input.parse_input_event(event)

func ensure_dir(path: String) -> void:
    if path == "":
        return
    DirAccess.make_dir_recursive_absolute(path)

func watchdog_seconds() -> float:
    var text := OS.get_environment("VOXEL_ACTUAL_GAMEPLAY_MIRA_WATCHDOG_SECONDS").strip_edges()
    if text == "":
        return 260.0
    return maxf(float(text), 30.0)

func capture_names() -> Array[String]:
    var names: Array[String] = []
    for capture in visual_captures:
        names.append(String(capture.get("stage", "")))
    return names

func rounded(value: float) -> float:
    return snappedf(value, 0.001)

func vec2(value: Vector2) -> Array:
    return [rounded(value.x), rounded(value.y)]

func vec3(value: Vector3) -> Array:
    return [rounded(value.x), rounded(value.y), rounded(value.z)]

func vec2i(value: Vector2i) -> Array:
    return [value.x, value.y]

func vec3i(value: Vector3i) -> Array:
    return [value.x, value.y, value.z]
