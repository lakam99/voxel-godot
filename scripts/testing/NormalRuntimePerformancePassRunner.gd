extends Node

const MENU_SCENE := preload("res://scenes/MainMenu.tscn")
const RuntimePerformanceObservationRunnerScript := preload("res://scripts/testing/RuntimePerformanceObservationRunner.gd")
const PlaytestSurvivalPolicyScript := preload("res://scripts/testing/PlaytestSurvivalPolicy.gd")

const SAMPLE_EVERY_FRAMES := 6
const DEFAULT_DURATION_SECONDS := 75.0
const DEFAULT_WARMUP_FRAMES := 120
const SEGMENT_SECONDS := 8.0
const SEGMENT_PAUSE_SECONDS := 0.65
const SEGMENT_LANE_CHECK_CELLS := 48
const JUMP_INTERVAL_FRAMES := 150
const MIN_RUNTIME_TRAVEL_DISTANCE := 45.0
const MAX_ALLOWED_BELOW_COLLISION := 1.35
const SCENARIO_SPRINT_TRAVERSAL := "NormalSprintTraversal"
const SCENARIO_TUTORIAL_TOWN_GUARD_ACTIVATION := "NormalTutorialTownGuardActivation"
const SCENARIO_WORLD_EDIT_LATENCY := "NormalWorldEditLatency"

var report_path := ""
var progress_path := ""
var screenshot_path := ""
var run_token := ""
var duration_seconds := DEFAULT_DURATION_SECONDS
var watchdog_seconds := 240.0
var warmup_frames := DEFAULT_WARMUP_FRAMES
var scenario := SCENARIO_SPRINT_TRAVERSAL
var menu: Node = null
var main: Node = null
var finished := false
var watchdog_elapsed := 0.0
var menu_to_new_game_input_ms := 0.0
var new_game_input_to_first_loading_frame_ms := 0.0
var new_game_input_to_gameplay_ready_ms := 0.0
var first_gameplay_frames_ms := 0.0
var new_game_input_started_usec := 0
var first_loading_frame_usec := 0
var gameplay_ready_usec := 0
var startup_loading_completed := false
var startup_loading_failure := ""
var startup_loading_steps: Array[Dictionary] = []
var measurement_start := Vector3.INF
var measurement_end := Vector3.INF
var last_travel_position := Vector3.INF
var accumulated_travel_distance := 0.0
var direction_change_count := 0
var pause_frame_count := 0
var jump_request_count := 0
var jump_observed_count := 0
var minimum_surface_clearance := INF
var maximum_below_surface := 0.0
var minimum_collision_clearance := INF
var maximum_below_collision := 0.0
var collision_surface_samples := 0
var terrain_collision_hold_frames := 0
var terrain_collision_hold_reasons := {}
var last_segment_index := -1
var segment_visit_counts := {}
var samples := []
var metrics_helper = RuntimePerformanceObservationRunnerScript.new()
var measurement_start_physics_frame := -1
var playtest_survival_policy := {}

func _ready() -> void:
    configure_from_environment()
    write_progress("start")
    call_deferred("run")

func _process(delta: float) -> void:
    if finished:
        return
    watchdog_elapsed += delta
    if watchdog_elapsed > watchdog_seconds:
        write_report(make_failure_report("normal runtime performance watchdog exceeded %.1fs" % watchdog_seconds))
        finish(1)

func configure_from_environment() -> void:
    report_path = OS.get_environment("VOXEL_NORMAL_RUNTIME_PERF_REPORT").strip_edges()
    if report_path == "":
        report_path = ProjectSettings.globalize_path("res://artifacts/performance/normal-runtime-performance-pass.json")
    progress_path = OS.get_environment("VOXEL_NORMAL_RUNTIME_PERF_PROGRESS").strip_edges()
    screenshot_path = OS.get_environment("VOXEL_NORMAL_RUNTIME_PERF_SCREENSHOT").strip_edges()
    run_token = OS.get_environment("VOXEL_NORMAL_RUNTIME_PERF_RUN_TOKEN").strip_edges()
    var duration_value := OS.get_environment("VOXEL_NORMAL_RUNTIME_PERF_DURATION_SECONDS").strip_edges()
    if duration_value != "":
        duration_seconds = maxf(5.0, float(duration_value))
    var watchdog_value := OS.get_environment("VOXEL_NORMAL_RUNTIME_PERF_WATCHDOG_SECONDS").strip_edges()
    if watchdog_value != "":
        watchdog_seconds = maxf(duration_seconds + 60.0, float(watchdog_value))
    else:
        watchdog_seconds = maxf(240.0, duration_seconds + 120.0)
    var warmup_value := OS.get_environment("VOXEL_NORMAL_RUNTIME_PERF_WARMUP_FRAMES").strip_edges()
    if warmup_value != "":
        warmup_frames = max(0, int(warmup_value))
    var scenario_value := OS.get_environment("VOXEL_NORMAL_RUNTIME_PERF_SCENARIO").strip_edges()
    if scenario_value != "":
        scenario = scenario_value

func run() -> void:
    var started_utc := Time.get_datetime_string_from_system(true)
    var result := await run_normal_runtime_scenario()
    var failure_count := 0 if bool(result.get("passed", false)) else 1
    var report := {
        "schemaVersion": 1,
        "runnerId": "normal_runtime_performance_pass",
        "suite": "normal_runtime_performance",
        "evidenceLevel": "integration",
        "scenario": scenario,
        "requestedTestSeed": OS.get_environment("VOXEL_TEST_SEED").strip_edges(),
        "seed": String(main.get("seed_text")) if main != null else "",
        "runToken": run_token,
        "durationSeconds": duration_seconds,
        "warmupFrames": warmup_frames,
        "startedUtc": started_utc,
        "finishedUtc": Time.get_datetime_string_from_system(true),
        "resultCount": 1,
        "failureCount": failure_count,
        "results": [result],
        "metrics": result.get("metrics", {}),
        "normalRuntimeControls": normal_runtime_controls(),
        "artifacts": {
            "report": report_path,
            "progress": progress_path,
            "screenshot": screenshot_path
        }
    }
    write_report(report)
    finish(1 if failure_count > 0 else 0)

func run_normal_runtime_scenario() -> Dictionary:
    var environment_failure := normal_runtime_environment_failure()
    if environment_failure != "":
        return failed_result(environment_failure)
    if not await launch_main_via_menu_new_game_input():
        return failed_result(startup_loading_failure if startup_loading_failure != "" else "Main Menu New Game did not reach gameplay readiness")
    # New Game opens in the tutorial night. Protect only the observer/player so
    # long performance observations cannot terminate before their measured act.
    playtest_survival_policy = PlaytestSurvivalPolicyScript.enable_player_god_mode(main, "normal_runtime_night_safe_observer")
    if not bool(playtest_survival_policy.get("enabled", false)):
        return failed_result("normal runtime night-safe player godmode was not enabled")
    if scenario == SCENARIO_TUTORIAL_TOWN_GUARD_ACTIVATION:
        return await run_tutorial_town_guard_activation_scenario()
    if scenario == SCENARIO_WORLD_EDIT_LATENCY:
        return await run_world_edit_latency_scenario()
    if not configure_player_for_runtime_traversal():
        return failed_result("player could not be configured for normal runtime traversal")
    await warmup()
    reset_runtime_performance_monitor()
    measurement_start = player_position()
    last_travel_position = measurement_start
    accumulated_travel_distance = 0.0
    direction_change_count = 0
    pause_frame_count = 0
    jump_request_count = 0
    jump_observed_count = 0
    minimum_surface_clearance = INF
    maximum_below_surface = 0.0
    minimum_collision_clearance = INF
    maximum_below_collision = 0.0
    collision_surface_samples = 0
    terrain_collision_hold_frames = 0
    terrain_collision_hold_reasons.clear()
    last_segment_index = -1
    segment_visit_counts.clear()
    samples.clear()
    write_progress("measure_start")
    var started_msec := Time.get_ticks_msec()
    var frame := 0
    while float(Time.get_ticks_msec() - started_msec) / 1000.0 < duration_seconds:
        var elapsed_seconds := float(Time.get_ticks_msec() - started_msec) / 1000.0
        update_normal_runtime_automation(frame, elapsed_seconds)
        await get_tree().process_frame
        observe_player_travel()
        if frame % SAMPLE_EVERY_FRAMES == 0 and main != null and main.has_method("debug_performance_state"):
            samples.append(main.call("debug_performance_state"))
        if frame % 120 == 0:
            write_progress("measure_frame:%d" % frame)
        frame += 1
    measurement_end = player_position()
    stop_player_automation()
    if screenshot_path != "":
        write_progress("capture_screenshot")
        await capture_screenshot()
        write_progress("capture_screenshot_done")
    var metrics: Dictionary = metrics_helper.call("summarize_samples", samples)
    append_normal_metrics(metrics, frame)
    var failures: Array = metrics_helper.call("performance_failures", metrics)
    if samples.is_empty():
        failures.append("no performance samples captured")
    if float(metrics.get("playerTravelDistance", 0.0)) < MIN_RUNTIME_TRAVEL_DISTANCE:
        failures.append("normal runtime traversal did not move far enough to exercise streaming")
    if int(metrics.get("directionChanges", 0)) < 3:
        failures.append("normal runtime traversal did not change directions enough")
    if int(metrics.get("collisionSurfaceSamples", 0)) <= 0:
        failures.append("normal runtime traversal captured no voxel collision-surface samples")
    elif float(metrics.get("maximumBelowVoxelCollision", 0.0)) > MAX_ALLOWED_BELOW_COLLISION:
        failures.append("player moved %.3f below the VoxelTerrain collision surface" % float(metrics.get("maximumBelowVoxelCollision", 0.0)))
    var passed := failures.is_empty()
    flush_async_save()
    return {
        "id": "normal_runtime_mixed_traversal",
        "scenario": scenario,
        "passed": passed,
        "details": result_details(metrics, failures),
        "failures": failures,
        "sampleCount": samples.size(),
        "metrics": metrics
    }

func run_tutorial_town_guard_activation_scenario() -> Dictionary:
    # This observes the production tutorial's initial night guard routes. It leaves
    # player and NPC transforms, clock, orders, route state, and doors untouched.
    stop_player_automation()
    reset_runtime_performance_monitor()
    measurement_start_physics_frame = Engine.get_physics_frames()
    samples.clear()
    write_progress("guard_activation_measure_start")
    var started_msec := Time.get_ticks_msec()
    var frame := 0
    while float(Time.get_ticks_msec() - started_msec) / 1000.0 < duration_seconds:
        await get_tree().process_frame
        if frame % SAMPLE_EVERY_FRAMES == 0 and main != null and main.has_method("debug_performance_state"):
            samples.append(main.call("debug_performance_state"))
        if frame % 120 == 0:
            write_progress("guard_activation_measure_frame:%d" % frame)
        frame += 1
    if screenshot_path != "":
        write_progress("capture_screenshot")
        await capture_screenshot()
        write_progress("capture_screenshot_done")
    var metrics: Dictionary = metrics_helper.call("summarize_samples", samples)
    append_normal_metrics(metrics, frame)
    var failures: Array = metrics_helper.call("performance_failures", metrics)
    if samples.is_empty():
        failures.append("no performance samples captured")
    var guard_profiles := routine_guard_route_profiles()
    metrics["routineGuardRouteV2PlanningProfiles"] = guard_profiles
    metrics["routineGuardRouteV2PlanningProfileCount"] = guard_profiles.size()
    if guard_profiles.is_empty():
        failures.append("tutorial-town guard activation captured no routine V2 guard route profile")
    var passed := failures.is_empty()
    flush_async_save()
    return {
        "id": "normal_runtime_tutorial_town_guard_activation",
        "scenario": scenario,
        "passed": passed,
        "details": result_details(metrics, failures),
        "failures": failures,
        "sampleCount": samples.size(),
        "metrics": metrics
    }

func run_world_edit_latency_scenario() -> Dictionary:
    stop_player_automation()
    write_progress("world_edit_warmup:%d" % warmup_frames)
    for _frame in range(warmup_frames):
        await get_tree().process_frame
    reset_runtime_performance_monitor()
    samples.clear()
    write_progress("world_edit_measure_start")
    var operation_rows: Array[Dictionary] = []
    var placed_blocks: Array[Node] = []
    var player_body := main.get("player") as Node3D
    if player_body == null:
        return failed_result("world-edit latency scenario has no live player")
    var origin_cell := Vector2i(int(main.call("world_to_cell", player_body.global_position.x)), int(main.call("world_to_cell", player_body.global_position.z)))
    var block_types := ["woodBlock", "torch", "wardLantern"]
    for index in range(block_types.size()):
        var block_type := String(block_types[index])
        var flat_cell := origin_cell + Vector2i(5 + index * 2, 4)
        var world_y := float(main.call("surface_y_at_cell", Vector3i(flat_cell.x, 0, flat_cell.y))) + 0.04
        var cell := Vector3i(flat_cell.x, roundi(world_y / 1.35), flat_cell.y)
        var started_usec := Time.get_ticks_usec()
        var block = main.call("create_block", cell, block_type, {
            "player_placed": true,
            "world_y": world_y,
            "deferWorldEditFollowup": true
        })
        var create_ms := elapsed_ms(started_usec)
        var feedback_started_usec := Time.get_ticks_usec()
        if block is Node3D:
            var feedback_color: Color = main.call("feedback_color_for_material", block_type)
            main.call("play_feedback", "place", (block as Node3D).global_position, feedback_color, 5)
        var feedback_ms := elapsed_ms(feedback_started_usec)
        var award_started_usec := Time.get_ticks_usec()
        main.call("award_place_xp", block_type)
        var award_ms := elapsed_ms(award_started_usec)
        var message_started_usec := Time.get_ticks_usec()
        main.call("show_action_message", "Placed %s" % block_type)
        var message_ms := elapsed_ms(message_started_usec)
        var elapsed := elapsed_ms(started_usec)
        operation_rows.append({
            "operation": "place",
            "blockType": block_type,
            "elapsedMs": elapsed,
            "createMs": create_ms,
            "feedbackMs": feedback_ms,
            "awardMs": award_ms,
            "messageMs": message_ms
        })
        if block is Node:
            placed_blocks.append(block)
        await sample_world_edit_frame(operation_rows.size())
    var placement_drain: Dictionary = await drain_world_edit_followups("placement", 4800)
    for block_value in placed_blocks:
        var block := block_value as Node3D
        if block == null or not is_instance_valid(block):
            continue
        var block_type := String(block.get_meta("block_type", ""))
        var started_usec := Time.get_ticks_usec()
        main.call("complete_destroy_target", { "position": block.global_position }, block, "block", block_type)
        var break_row := { "operation": "break", "blockType": block_type, "elapsedMs": elapsed_ms(started_usec) }
        var destroy_metrics = main.get("last_destroy_target_metrics")
        if destroy_metrics is Dictionary:
            break_row.merge(destroy_metrics, true)
            break_row["elapsedMs"] = elapsed_ms(started_usec)
        operation_rows.append(break_row)
        await sample_world_edit_frame(operation_rows.size())
    var removal_drain: Dictionary = await drain_world_edit_followups("removal", 4800)
    if screenshot_path != "":
        write_progress("capture_screenshot")
        await capture_screenshot()
        write_progress("capture_screenshot_done")
    var metrics: Dictionary = metrics_helper.call("summarize_samples", samples)
    append_normal_metrics(metrics, int(placement_drain.get("frames", 0)) + int(removal_drain.get("frames", 0)))
    var queue_stats: Dictionary = main.call("world_edit_followup_stats") if main.has_method("world_edit_followup_stats") else {}
    metrics["worldEditOperations"] = operation_rows
    metrics["worldEditFollowupQueue"] = queue_stats
    metrics["placementDrain"] = placement_drain
    metrics["removalDrain"] = removal_drain
    metrics["worldEditLatencyThresholdsMs"] = { "immediateTransaction": 2.0, "enqueue": 0.5, "followupSlice": 3.0 }
    var contextual_failures: Array = metrics_helper.call("performance_failures", metrics)
    metrics["contextualRuntimeFailures"] = contextual_failures
    var failures: Array = contextual_failures.duplicate()
    if samples.is_empty():
        failures.append("no world-edit performance samples captured")
    for row in operation_rows:
        if float(row.get("elapsedMs", 0.0)) > 2.0:
            failures.append("%s %s immediate transaction took %.3fms" % [String(row.get("operation", "edit")), String(row.get("blockType", "block")), float(row.get("elapsedMs", 0.0))])
    if not bool(placement_drain.get("complete", false)):
        failures.append("placement follow-up queue did not drain")
    if not bool(removal_drain.get("complete", false)):
        failures.append("removal follow-up queue did not drain")
    if float(queue_stats.get("peakEnqueueMs", 0.0)) > 0.5:
        failures.append("world-edit enqueue peak %.3fms exceeded 0.5ms" % float(queue_stats.get("peakEnqueueMs", 0.0)))
    if float(queue_stats.get("peakProcessMs", 0.0)) > 3.0:
        failures.append("world-edit follow-up peak %.3fms exceeded 3ms" % float(queue_stats.get("peakProcessMs", 0.0)))
    var passed := failures.is_empty()
    flush_async_save()
    return {
        "id": "normal_runtime_world_edit_latency",
        "scenario": scenario,
        "passed": passed,
        "details": result_details(metrics, failures),
        "failures": failures,
        "sampleCount": samples.size(),
        "metrics": metrics
    }

func sample_world_edit_frame(frame: int) -> void:
    await get_tree().process_frame
    if frame % 1 == 0 and main != null and main.has_method("debug_performance_state"):
        samples.append(main.call("debug_performance_state"))

func drain_world_edit_followups(label: String, max_frames: int) -> Dictionary:
    var max_frame_gap_ms := 0.0
    var stable_empty_frames := 0
    for frame in range(max_frames):
        var frame_started_usec := Time.get_ticks_usec()
        await get_tree().process_frame
        max_frame_gap_ms = maxf(max_frame_gap_ms, elapsed_ms(frame_started_usec))
        if frame % 3 == 0 and main != null and main.has_method("debug_performance_state"):
            samples.append(main.call("debug_performance_state"))
        var queue_stats: Dictionary = main.call("world_edit_followup_stats") if main != null and main.has_method("world_edit_followup_stats") else {}
        var empty := int(queue_stats.get("pendingEdits", 0)) <= 0 and not bool(queue_stats.get("structurePending", false))
        stable_empty_frames = stable_empty_frames + 1 if empty else 0
        if stable_empty_frames >= 3:
            write_progress("world_edit_%s_drained:%d" % [label, frame + 1])
            return { "complete": true, "frames": frame + 1, "maxFrameGapMs": max_frame_gap_ms }
        if frame % 240 == 0:
            write_progress("world_edit_%s_wait:%d" % [label, frame])
    return { "complete": false, "frames": max_frames, "maxFrameGapMs": max_frame_gap_ms }

func launch_main_via_menu_new_game_input() -> bool:
    Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
    write_progress("instantiate_main_menu")
    var menu_started_usec := Time.get_ticks_usec()
    menu = MENU_SCENE.instantiate()
    if menu == null:
        startup_loading_failure = "MainMenu.tscn could not be instantiated"
        return false
    add_child(menu)
    await get_tree().process_frame
    await get_tree().process_frame
    await get_tree().process_frame
    await get_tree().process_frame
    var button := menu.get("new_game_button") as Button
    if button == null or not is_instance_valid(button) or button.disabled:
        startup_loading_failure = "Main Menu did not expose an enabled New Game button"
        return false
    menu_to_new_game_input_ms = elapsed_ms(menu_started_usec)
    new_game_input_started_usec = Time.get_ticks_usec()
    dispatch_menu_mouse_button(button.get_global_rect().get_center(), MOUSE_BUTTON_LEFT, true)
    dispatch_menu_mouse_button(button.get_global_rect().get_center(), MOUSE_BUTTON_LEFT, false)
    write_progress("main_menu_new_game_button_input")
    var max_frames := ceili(140.0 * float(Engine.physics_ticks_per_second))
    for frame in range(max_frames):
        await get_tree().process_frame
        if first_loading_frame_usec <= 0 and bool(menu.get("launching")):
            first_loading_frame_usec = Time.get_ticks_usec()
            new_game_input_to_first_loading_frame_ms = elapsed_ms(new_game_input_started_usec)
            write_progress("main_menu_loading_frame")
        var active_main = menu.get("active_main") if menu != null else null
        if active_main is Node:
            main = active_main
            connect_main_loading_signals()
        if startup_loading_failure != "":
            return false
        if startup_loading_completed:
            var readiness_domains = main.get("startup_readiness_domains") if main != null else {}
            var gameplay_readiness: Dictionary = readiness_domains.get("gameplay", {}) if readiness_domains is Dictionary else {}
            if String(gameplay_readiness.get("status", "")) != "ready":
                startup_loading_failure = "Main Menu New Game completed without gameplay readiness"
                return false
            new_game_input_to_gameplay_ready_ms = float(gameplay_ready_usec - new_game_input_started_usec) / 1000.0
            var first_gameplay_started_usec := Time.get_ticks_usec()
            await get_tree().process_frame
            if scenario != SCENARIO_TUTORIAL_TOWN_GUARD_ACTIVATION:
                await get_tree().physics_frame
            first_gameplay_frames_ms = elapsed_ms(first_gameplay_started_usec)
            write_progress("main_menu_new_game_gameplay_ready")
            return main != null and is_instance_valid(main)
        if frame % 120 == 0:
            write_progress("main_menu_waiting_for_gameplay_ready frame=%d" % frame)
    startup_loading_failure = "Main Menu New Game loading timed out"
    return false

func connect_main_loading_signals() -> void:
    if main == null:
        return
    var completed_callback := Callable(self, "_on_main_startup_loading_completed")
    if main.has_signal("startup_loading_completed") and not main.is_connected("startup_loading_completed", completed_callback):
        main.connect("startup_loading_completed", completed_callback)
    var failed_callback := Callable(self, "_on_main_startup_loading_failed")
    if main.has_signal("startup_loading_failed") and not main.is_connected("startup_loading_failed", failed_callback):
        main.connect("startup_loading_failed", failed_callback)
    var step_callback := Callable(self, "_on_main_startup_loading_step")
    if main.has_signal("startup_loading_step") and not main.is_connected("startup_loading_step", step_callback):
        main.connect("startup_loading_step", step_callback)

func _on_main_startup_loading_step(message: String) -> void:
    startup_loading_steps.append({
        "elapsedMs": elapsed_ms(new_game_input_started_usec),
        "message": message
    })

func _on_main_startup_loading_completed() -> void:
    gameplay_ready_usec = Time.get_ticks_usec()
    startup_loading_completed = true

func _on_main_startup_loading_failed(message: String) -> void:
    startup_loading_failure = message if message != "" else "Main Menu New Game loading failed"

func dispatch_menu_mouse_button(position: Vector2, button_index: int, pressed: bool) -> void:
    var event := InputEventMouseButton.new()
    event.button_index = button_index
    event.pressed = pressed
    event.position = position
    event.global_position = position
    get_viewport().push_input(event)

func normal_runtime_environment_failure() -> String:
    if not [SCENARIO_SPRINT_TRAVERSAL, SCENARIO_TUTORIAL_TOWN_GUARD_ACTIVATION, SCENARIO_WORLD_EDIT_LATENCY].has(scenario):
        return "unsupported normal runtime performance scenario: %s" % scenario
    if OS.get_environment("VOXEL_PLAYTEST").strip_edges() != "":
        return "VOXEL_PLAYTEST must be unset for normal runtime performance"
    if OS.get_environment("VOXEL_TEST_SEED").strip_edges() != "":
        return "VOXEL_TEST_SEED must be unset for Main Menu New Game performance"
    if OS.get_environment("VOXEL_RUNTIME_PERF_FAST_BOOT").strip_edges() != "":
        return "VOXEL_RUNTIME_PERF_FAST_BOOT must be unset for normal runtime performance"
    if OS.get_environment("VOXEL_UNDERGROUND_VISUAL_FAST_BOOT").strip_edges() != "" or OS.get_environment("VOXEL_DIGGING_VISUAL_FAST_BOOT").strip_edges() != "":
        return "visual fast boot flags must be unset for normal runtime performance"
    return ""

func configure_player_for_runtime_traversal() -> bool:
    if main == null:
        return false
    var player_body := main.get("player") as CharacterBody3D
    if player_body == null:
        return false
    var start_cell := find_runtime_start_cell()
    var start_y := float(main.call("surface_y_at_cell", Vector3i(start_cell.x, 0, start_cell.y))) + 0.10
    player_body.global_position = Vector3(float(start_cell.x) * 1.35, start_y, float(start_cell.y) * 1.35)
    player_body.velocity = Vector3.ZERO
    player_body.rotation.y = -PI * 0.5
    player_body.set("terrain_grounded", true)
    player_body.set("automated_input", true)
    player_body.set("automated_sprint", true)
    player_body.set("automated_move", runtime_movement_segments()[0].get("direction", Vector3.RIGHT))
    player_body.set("automated_jump", false)
    if main.has_method("update_chunks"):
        main.call("update_chunks", false)
    return true

func find_runtime_start_cell() -> Vector2i:
    var player_body := main.get("player") as Node3D
    var origin := player_body.global_position if player_body != null else Vector3.ZERO
    var origin_cell := Vector2i(int(main.call("world_to_cell", origin.x)), int(main.call("world_to_cell", origin.z)))
    var offsets: Array[Vector2i] = [
        Vector2i(32, 12),
        Vector2i(64, -18),
        Vector2i(96, 24),
        Vector2i(128, -32),
        Vector2i(160, 48),
        Vector2i(192, -64)
    ]
    for offset in offsets:
        var candidate := origin_cell + offset
        if runtime_route_pattern_ok(candidate):
            return candidate
    return origin_cell + offsets[0]

func runtime_route_pattern_ok(start_cell: Vector2i) -> bool:
    var cursor := start_cell
    for segment in runtime_movement_segments():
        var cell_direction: Vector2i = segment.get("cellDirection", Vector2i.ZERO)
        if cell_direction == Vector2i.ZERO:
            continue
        if not runtime_lane_ok(cursor, cell_direction):
            return false
        cursor += cell_direction * SEGMENT_LANE_CHECK_CELLS
    return true

func runtime_lane_ok(start_cell: Vector2i, cell_direction: Vector2i) -> bool:
    var previous_height := INF
    for step in range(SEGMENT_LANE_CHECK_CELLS):
        var cell := start_cell + cell_direction * step
        var height := float(main.call("surface_y_at_cell", Vector3i(cell.x, 0, cell.y)))
        if height < 1.35 * 3.0 or height > 96.0:
            return false
        var biome := String(main.call("surface_biome_at_cell", Vector3i(cell.x, 0, cell.y)))
        if biome in ["ocean", "beach", "town"]:
            return false
        if previous_height != INF and absf(height - previous_height) > 1.35 * 1.25:
            return false
        previous_height = height
    return true

func warmup() -> void:
    write_progress("warmup:%d" % warmup_frames)
    for _i in range(warmup_frames):
        update_normal_runtime_automation(_i, float(_i) / 60.0)
        await get_tree().process_frame

func update_normal_runtime_automation(frame: int, elapsed_seconds: float) -> void:
    var player_body := main.get("player") as CharacterBody3D if main != null else null
    if player_body == null:
        return
    var segment_state := runtime_segment_for_elapsed(elapsed_seconds)
    var segment_index := int(segment_state.get("index", 0))
    var move_direction: Vector3 = segment_state.get("direction", Vector3.ZERO)
    var paused := bool(segment_state.get("paused", false))
    if segment_index != last_segment_index:
        if last_segment_index >= 0:
            direction_change_count += 1
        last_segment_index = segment_index
    var segment_key := String(segment_state.get("label", "segment_%d" % segment_index))
    segment_visit_counts[segment_key] = int(segment_visit_counts.get(segment_key, 0)) + 1
    if paused:
        pause_frame_count += 1
    player_body.set("automated_input", true)
    player_body.set("automated_sprint", not paused)
    player_body.set("automated_move", Vector3.ZERO if paused else move_direction)
    if not paused and frame > 0 and frame % JUMP_INTERVAL_FRAMES == 0:
        player_body.set("automated_jump", true)
        jump_request_count += 1
    if not paused and move_direction.length_squared() > 0.001:
        player_body.rotation.y = atan2(-move_direction.x, -move_direction.z)

func runtime_segment_for_elapsed(elapsed_seconds: float) -> Dictionary:
    var segments := runtime_movement_segments()
    var segment_window := SEGMENT_SECONDS + SEGMENT_PAUSE_SECONDS
    var index := int(floor(elapsed_seconds / segment_window)) % segments.size()
    var phase := fmod(elapsed_seconds, segment_window)
    var segment: Dictionary = segments[index]
    return {
        "index": index,
        "label": String(segment.get("label", "segment_%d" % index)),
        "direction": segment.get("direction", Vector3.ZERO),
        "paused": phase >= SEGMENT_SECONDS
    }

func runtime_movement_segments() -> Array[Dictionary]:
    return [
        { "label": "east_sprint", "direction": Vector3(1.0, 0.0, 0.0), "cellDirection": Vector2i(1, 0) },
        { "label": "south_sprint", "direction": Vector3(0.0, 0.0, 1.0), "cellDirection": Vector2i(0, 1) },
        { "label": "west_sprint", "direction": Vector3(-1.0, 0.0, 0.0), "cellDirection": Vector2i(-1, 0) },
        { "label": "north_sprint", "direction": Vector3(0.0, 0.0, -1.0), "cellDirection": Vector2i(0, -1) },
        { "label": "southeast_sprint", "direction": Vector3(1.0, 0.0, 1.0).normalized(), "cellDirection": Vector2i(1, 1) },
        { "label": "northwest_sprint", "direction": Vector3(-1.0, 0.0, -1.0).normalized(), "cellDirection": Vector2i(-1, -1) }
    ]

func observe_player_travel() -> void:
    var current := player_position()
    if current == Vector3.INF:
        return
    if last_travel_position != Vector3.INF:
        var delta := current - last_travel_position
        delta.y = 0.0
        accumulated_travel_distance += delta.length()
    last_travel_position = current
    var player_body := main.get("player") as CharacterBody3D if main != null else null
    if player_body != null:
        if bool(player_body.get("jumped_this_frame")):
            jump_observed_count += 1
        if player_body.has_meta("terrain_collision_hold") and bool(player_body.get_meta("terrain_collision_hold")):
            terrain_collision_hold_frames += 1
            var hold_reason := String(player_body.get_meta("terrain_collision_hold_reason", "unknown"))
            terrain_collision_hold_reasons[hold_reason] = int(terrain_collision_hold_reasons.get(hold_reason, 0)) + 1
        observe_voxel_collision_clearance(player_body, current)
    if main != null and main.has_method("surface_y_at_position"):
        var surface_y := float(main.call("surface_y_at_position", current))
        var clearance := current.y - surface_y
        minimum_surface_clearance = minf(minimum_surface_clearance, clearance)
        maximum_below_surface = maxf(maximum_below_surface, -clearance)

func observe_voxel_collision_clearance(player_body: CharacterBody3D, current: Vector3) -> void:
    var motion_proof = player_body.get("last_terrain_collision_proof")
    if not (motion_proof is Dictionary) or not bool((motion_proof as Dictionary).get("passed", false)):
        return
    var position_proofs = (motion_proof as Dictionary).get("proofs", [])
    if not (position_proofs is Array) or position_proofs.is_empty():
        return
    var position_proof = position_proofs[0]
    if not (position_proof is Dictionary):
        return
    var collision_samples = (position_proof as Dictionary).get("samples", [])
    if not (collision_samples is Array) or collision_samples.is_empty():
        return
    var center_sample = collision_samples[0]
    if not (center_sample is Dictionary) or not bool((center_sample as Dictionary).get("hit", false)):
        return
    var hit_y := float((center_sample as Dictionary).get("hitY", current.y))
    var clearance := current.y - hit_y
    minimum_collision_clearance = minf(minimum_collision_clearance, clearance)
    maximum_below_collision = maxf(maximum_below_collision, -clearance)
    collision_surface_samples += 1

func stop_player_automation() -> void:
    var player_body := main.get("player") as CharacterBody3D if main != null else null
    if player_body == null:
        return
    player_body.set("automated_move", Vector3.ZERO)
    player_body.set("automated_sprint", false)
    player_body.set("automated_jump", false)
    player_body.velocity = Vector3.ZERO

func reset_runtime_performance_monitor() -> void:
    if main == null:
        return
    var monitor = main.get("runtime_perf_monitor")
    if monitor != null and monitor.has_method("reset"):
        monitor.call("reset")
    var npc_system = main.get("npc_system")
    var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
    var navmesh_world = autonomy.get("navmesh_world") if autonomy != null else null
    if navmesh_world != null and navmesh_world.has_method("reset_timing_stats"):
        navmesh_world.call("reset_timing_stats")
    var entries = npc_system.get("npcs") if npc_system != null else []
    if entries is Array:
        for entry_value in entries:
            if not (entry_value is Dictionary):
                continue
            var entry: Dictionary = entry_value
            entry.erase("routineRouteV2LastPlanningProfile")
            entry.erase("routineRouteV2MaxPlanningProfile")

func flush_async_save() -> void:
    if main == null:
        return
    var save_system = main.get("save_system")
    if save_system != null and save_system.has_method("poll_async_save"):
        save_system.call("poll_async_save", true)

func append_normal_metrics(metrics: Dictionary, frame_count: int) -> void:
    metrics["launchPath"] = "MainMenu.tscn -> visible New Game button viewport input -> startup_loading_completed"
    metrics["menuToNewGameInputMs"] = menu_to_new_game_input_ms
    metrics["newGameInputToFirstLoadingFrameMs"] = new_game_input_to_first_loading_frame_ms
    metrics["newGameInputToGameplayReadyMs"] = new_game_input_to_gameplay_ready_ms
    metrics["firstGameplayFramesMs"] = first_gameplay_frames_ms
    metrics["startupLoadingSteps"] = startup_loading_steps.duplicate(true)
    metrics["startupReadinessDomains"] = main.get("startup_readiness_domains").duplicate(true) if main != null and main.get("startup_readiness_domains") is Dictionary else {}
    metrics["measuredFrames"] = frame_count
    metrics["autosaveEnabled"] = bool(main.get("autosave_enabled")) if main != null else false
    metrics["savePathOverridden"] = OS.get_environment("VOXEL_SAVE_PATH_OVERRIDE").strip_edges() != ""
    metrics["voxelPlaytest"] = OS.get_environment("VOXEL_PLAYTEST").strip_edges()
    metrics["fastBoot"] = OS.get_environment("VOXEL_RUNTIME_PERF_FAST_BOOT").strip_edges()
    metrics["directionChanges"] = direction_change_count
    metrics["pauseFrames"] = pause_frame_count
    metrics["jumpRequests"] = jump_request_count
    metrics["jumpObserved"] = jump_observed_count
    metrics["minimumSurfaceClearance"] = minimum_surface_clearance if minimum_surface_clearance != INF else 0.0
    metrics["maximumBelowSurface"] = maximum_below_surface
    metrics["minimumVoxelCollisionClearance"] = minimum_collision_clearance if minimum_collision_clearance != INF else 0.0
    metrics["maximumBelowVoxelCollision"] = maximum_below_collision
    metrics["collisionSurfaceSamples"] = collision_surface_samples
    metrics["terrainCollisionHoldFrames"] = terrain_collision_hold_frames
    metrics["terrainCollisionHoldReasons"] = terrain_collision_hold_reasons.duplicate(true)
    metrics["segmentVisitCounts"] = segment_visit_counts.duplicate(true)
    metrics["routineRouteV2PlanningProfiles"] = routine_v2_planning_profiles(measurement_start_physics_frame)
    if measurement_start == Vector3.INF or measurement_end == Vector3.INF:
        metrics["playerTravelDistance"] = 0.0
        return
    var delta := measurement_end - measurement_start
    delta.y = 0.0
    metrics["playerTravelDistance"] = accumulated_travel_distance
    metrics["playerDisplacementDistance"] = delta.length()
    metrics["playerStart"] = vec3(measurement_start)
    metrics["playerEnd"] = vec3(measurement_end)

func routine_v2_planning_profiles(after_physics_frame := -1) -> Array:
    if main == null:
        return []
    var npc_system = main.get("npc_system")
    var entries = npc_system.get("npcs") if npc_system != null else []
    if not (entries is Array):
        return []
    var profiles: Array = []
    for entry_value in entries:
        if not (entry_value is Dictionary):
            continue
        var entry: Dictionary = entry_value
        var profile_value = entry.get("routineRouteV2MaxPlanningProfile", {})
        if profile_value is Dictionary and not (profile_value as Dictionary).is_empty():
            var profile: Dictionary = profile_value
            if after_physics_frame >= 0 and int(profile.get("physicsFrame", -1)) < after_physics_frame:
                continue
            profiles.append(profile.duplicate(true))
    profiles.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return float(a.get("totalMs", 0.0)) > float(b.get("totalMs", 0.0))
    )
    return profiles.slice(0, 12)

func routine_guard_route_profiles() -> Array:
    var profiles: Array = []
    for profile_value in routine_v2_planning_profiles(measurement_start_physics_frame):
        if not (profile_value is Dictionary):
            continue
        var profile: Dictionary = profile_value
        if String(profile.get("intentKind", "")) == "guard" and String(profile.get("semanticKind", "")) in ["guard_post", "home_departure_clearance"]:
            profiles.append(profile)
    return profiles

func result_details(metrics: Dictionary, failures: Array) -> String:
    return "samples=%d p99=%.2f max=%.2f chunkMax=%.2f npcMax=%.2f saveMax=%.2f travel=%.2f turns=%d jumps=%d/%d menuToReady=%.2f failures=%d" % [
        samples.size(),
        float(metrics.get("frameP99Ms", 0.0)),
        float(metrics.get("frameMaxMs", 0.0)),
        float(metrics.get("maxChunkMs", 0.0)),
        float(metrics.get("maxNpcMs", 0.0)),
        float(metrics.get("maxAutosaveMs", 0.0)),
        float(metrics.get("playerTravelDistance", 0.0)),
        int(metrics.get("directionChanges", 0)),
        int(metrics.get("jumpObserved", 0)),
        int(metrics.get("jumpRequests", 0)),
        float(metrics.get("newGameInputToGameplayReadyMs", 0.0)),
        failures.size()
    ]

func normal_runtime_controls() -> Dictionary:
    return {
        "launchPath": "MainMenu.tscn -> visible New Game button viewport input -> startup_loading_completed",
        "voxelPlaytest": OS.get_environment("VOXEL_PLAYTEST").strip_edges(),
        "runtimePerfFastBoot": OS.get_environment("VOXEL_RUNTIME_PERF_FAST_BOOT").strip_edges(),
        "fixedFps": false,
        "autosaveExpectedEnabled": true,
        "savePathOverride": OS.get_environment("VOXEL_SAVE_PATH_OVERRIDE").strip_edges(),
        "requestedTestSeed": OS.get_environment("VOXEL_TEST_SEED").strip_edges(),
        "deterministicSeedSequence": OS.get_environment("VOXEL_NORMAL_RUNTIME_PERF_RUN_TOKEN").strip_edges() != "",
        "scenario": scenario,
        "playerRelocatedForStreaming": scenario == SCENARIO_SPRINT_TRAVERSAL,
        "playerAutomation": scenario == SCENARIO_SPRINT_TRAVERSAL,
        "clockMutation": false,
        "playtestSurvivalPolicy": playtest_survival_policy,
        "npcMutation": false,
        "movementSegments": runtime_movement_segment_labels(),
        "segmentSeconds": SEGMENT_SECONDS,
        "segmentPauseSeconds": SEGMENT_PAUSE_SECONDS
    }

func runtime_movement_segment_labels() -> Array[String]:
    var labels: Array[String] = []
    for segment in runtime_movement_segments():
        labels.append(String(segment.get("label", "")))
    return labels

func capture_screenshot() -> void:
    if DisplayServer.get_name() == "headless":
        return
    await RenderingServer.frame_post_draw
    DirAccess.make_dir_recursive_absolute(screenshot_path.get_base_dir())
    var image := get_viewport().get_texture().get_image()
    image.save_png(screenshot_path)

func player_position() -> Vector3:
    var player_body := main.get("player") as Node3D if main != null else null
    return player_body.global_position if player_body != null else Vector3.INF

func failed_result(reason: String) -> Dictionary:
    return {
        "id": "normal_runtime_mixed_traversal",
        "scenario": scenario,
        "passed": false,
        "details": reason,
        "failures": [reason],
        "sampleCount": 0,
        "metrics": {
            "menuToNewGameInputMs": menu_to_new_game_input_ms,
            "newGameInputToFirstLoadingFrameMs": new_game_input_to_first_loading_frame_ms,
            "newGameInputToGameplayReadyMs": new_game_input_to_gameplay_ready_ms,
            "firstGameplayFramesMs": first_gameplay_frames_ms
        }
    }

func make_failure_report(reason: String) -> Dictionary:
    return {
        "schemaVersion": 1,
        "runnerId": "normal_runtime_performance_pass",
        "suite": "normal_runtime_performance",
        "evidenceLevel": "integration",
        "scenario": scenario,
        "runToken": run_token,
        "resultCount": 1,
        "failureCount": 1,
        "results": [failed_result(reason)],
        "normalRuntimeControls": normal_runtime_controls()
    }

func write_progress(label: String) -> void:
    if progress_path == "":
        return
    DirAccess.make_dir_recursive_absolute(progress_path.get_base_dir())
    var file := FileAccess.open(progress_path, FileAccess.WRITE)
    if file == null:
        return
    file.store_string("%s\n" % label)
    file.close()

func write_report(report: Dictionary) -> void:
    DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
    var file := FileAccess.open(report_path, FileAccess.WRITE)
    if file == null:
        push_error("Unable to write normal runtime performance report: %s" % report_path)
        return
    file.store_string(JSON.stringify(report, "  "))
    file.close()

func finish(code: int) -> void:
    finished = true
    call_deferred("_quit_deferred", code)

func _quit_deferred(code: int) -> void:
    if main != null and is_instance_valid(main):
        main.set_process(false)
        main.set_physics_process(false)
        if main.has_method("set_registered_npc_physics_enabled"):
            main.call("set_registered_npc_physics_enabled", false)
        if main.has_method("wait_for_terrain_workers_before_quit"):
            await main.call("wait_for_terrain_workers_before_quit")
        main.queue_free()
        await get_tree().process_frame
    get_tree().quit(code)

func elapsed_ms(start_usec: int) -> float:
    return float(Time.get_ticks_usec() - start_usec) / 1000.0

func vec3(value: Vector3) -> Array:
    return [value.x, value.y, value.z]
