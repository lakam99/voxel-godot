extends Node

const MENU_SCENE := preload("res://scenes/MainMenu.tscn")
const RuntimePerformanceObservationRunnerScript := preload("res://scripts/testing/RuntimePerformanceObservationRunner.gd")
const PlaytestSurvivalPolicyScript := preload("res://scripts/testing/PlaytestSurvivalPolicy.gd")
const RenderObservationScript := preload("res://scripts/perf/RuntimeRenderObservation.gd")

const SAMPLE_EVERY_FRAMES := 30
const DEFAULT_DURATION_SECONDS := 75.0
const DEFAULT_WARMUP_FRAMES := 120
const SEGMENT_SECONDS := 8.0
const SEGMENT_PAUSE_SECONDS := 0.65
const JUMP_INTERVAL_FRAMES := 150
const MIN_RUNTIME_TRAVEL_DISTANCE := 45.0
const MAX_ALLOWED_BELOW_COLLISION := 1.35
const GATE5_MEASURED_GAMEPLAY_SECONDS := 300.0
const GATE5_PRESENTATION_P99_MS := 33.0
const GATE5_PRESENTATION_MAX_MS := 100.0
const GATE5_STREAMING_MATERIAL_MS := 4.0
const GATE5_EVIDENCE_OBSERVER_MAX_MS := 2.0
const SCENARIO_SPRINT_TRAVERSAL := "NormalSprintTraversal"
const SCENARIO_TUTORIAL_TOWN_GUARD_ACTIVATION := "NormalTutorialTownGuardActivation"
const SCENARIO_WORLD_EDIT_LATENCY := "NormalWorldEditLatency"
const TOP_LEVEL_FRAME_DOMAIN_BY_SECTION := {
    "chunk": "world_streaming",
    "water_surface": "world_simulation",
    "world_edit_followup": "world_edit",
    "sky": "presentation",
    "sleep_transition": "gameplay",
    "utility": "gameplay",
    "pickups": "gameplay",
    "wildlife": "world_simulation",
    "survival": "gameplay",
    "hostiles": "world_simulation",
    "update_npcs": "npc",
    "aftermath_collapse": "world_simulation",
    "beacon": "gameplay",
    "autosave": "save",
    "break": "gameplay",
    "hud": "presentation",
    "performance_overlay": "presentation"
}
const AUTHORITATIVE_STREAMING_OVERRUN_COUNTERS := [
    "gameplay_publication_budget_overrun",
    "gameplay_publication_citadel_overrun"
]

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
var traversal_spawn := Vector3.INF
var traversal_entry := {}
var traversal_chunks := {}
var maximum_spawn_distance := 0.0
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
var terrain_hold_samples: Array[Dictionary] = []
var last_hold_sample_msec := -1000
var modal_loading_frames := 0
var modal_loading_samples: Array[Dictionary] = []
var player_collision_hold_baseline := 0
var player_collision_hold_delta := 0
var last_segment_index := -1
var segment_visit_counts := {}
var samples := []
var performance_sample_total_usec := 0
var performance_sample_max_usec := 0
var metrics_helper = RuntimePerformanceObservationRunnerScript.new()
var measurement_start_physics_frame := -1
var playtest_survival_policy := {}
var render_observation

func _ready() -> void:
    configure_from_environment()
    var resolution := OS.get_environment("VOXEL_NORMAL_RUNTIME_PERF_RESOLUTION")
    if not resolution.is_empty():
        if resolution not in ["1280x720", "1920x1080"]:
            get_tree().quit(2)
            return
        var dimensions := resolution.split("x")
        get_tree().root.size = Vector2i(int(dimensions[0]), int(dimensions[1]))
    render_observation = RenderObservationScript.new()
    add_child(render_observation)
    render_observation.set_provenance_provider(_runtime_cadence_provenance)
    render_observation.start(get_viewport())
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
    var evidence_classification := gate5_evidence_classification(scenario, duration_seconds)
    result["evidenceClassification"] = evidence_classification.get("classification", "diagnostic")
    result["gate5PresentationAcceptanceEligible"] = bool(evidence_classification.get("eligible", false))
    result["gate5PresentationAcceptancePassed"] = bool(evidence_classification.get("eligible", false)) \
        and bool(result.get("passed", false))
    result["gate5PresentationAcceptanceIneligibilityReasons"] = evidence_classification.get("reasons", []).duplicate()
    var failure_count := 0 if bool(result.get("passed", false)) else 1
    var report := {
        "schemaVersion": 1,
        "runnerId": "normal_runtime_performance_pass",
        "suite": "normal_runtime_performance",
        "evidenceLevel": "integration",
        "scenario": scenario,
        "evidenceClassification": evidence_classification.get("classification", "diagnostic"),
        "gate5PresentationAcceptanceEligible": bool(evidence_classification.get("eligible", false)),
        "gate5PresentationAcceptancePassed": bool(evidence_classification.get("eligible", false)) \
            and bool(result.get("passed", false)),
        "gate5PresentationAcceptanceIneligibilityReasons": evidence_classification.get("reasons", []).duplicate(),
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
    if screenshot_path != "":
        await capture_screenshot(screenshot_path.get_base_dir().path_join("startup_spawn.png"))
    if not await leave_starter_house():
        if screenshot_path != "":
            await capture_screenshot()
        var failure := failed_result("traversal setup could not leave the starter house through the real door")
        failure["traversalEntry"] = traversal_entry
        return failure
    await warmup()
    capture_player_collision_hold_baseline()
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
    terrain_hold_samples.clear()
    last_hold_sample_msec = -1000
    modal_loading_frames = 0
    modal_loading_samples.clear()
    last_segment_index = -1
    segment_visit_counts.clear()
    samples.clear()
    performance_sample_total_usec = 0
    performance_sample_max_usec = 0
    write_progress("measure_start")
    var started_msec := Time.get_ticks_msec()
    var frame := 0
    while float(Time.get_ticks_msec() - started_msec) / 1000.0 < duration_seconds:
        var elapsed_seconds := float(Time.get_ticks_msec() - started_msec) / 1000.0
        update_normal_runtime_automation(frame, elapsed_seconds)
        await get_tree().process_frame
        observe_player_travel()
        if frame % SAMPLE_EVERY_FRAMES == 0 and main != null and main.has_method("debug_performance_state"):
            capture_performance_sample()
        if frame % 120 == 0:
            write_progress("measure_frame:%d" % frame)
        frame += 1
    var measured_gameplay_seconds := float(Time.get_ticks_msec() - started_msec) / 1000.0
    refresh_player_collision_hold_delta()
    measurement_end = player_position()
    stop_player_automation()
    if is_instance_valid(render_observation):
        render_observation.phase = "post_measurement"
    if screenshot_path != "":
        write_progress("capture_screenshot")
        await capture_screenshot()
        write_progress("capture_screenshot_done")
    var metrics: Dictionary = metrics_helper.call("summarize_samples", samples)
    append_normal_metrics(metrics, frame)
    metrics["measuredGameplaySeconds"] = measured_gameplay_seconds
    append_presentation_cadence_metrics(metrics)
    var failures: Array = normal_runtime_work_budget_failures(metrics)
    failures.append_array(presentation_acceptance_failures(metrics))
    if samples.is_empty():
        failures.append("no performance samples captured")
    if float(metrics.get("playerTravelDistance", 0.0)) < MIN_RUNTIME_TRAVEL_DISTANCE:
        failures.append("normal runtime traversal did not move far enough to exercise streaming")
    if maximum_spawn_distance < 64.0 or traversal_chunks.size() < 4:
        failures.append("traversal did not leave the initial 64m area and visit at least four gameplay chunks")
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
    performance_sample_total_usec = 0
    performance_sample_max_usec = 0
    write_progress("guard_activation_measure_start")
    var started_msec := Time.get_ticks_msec()
    var frame := 0
    while float(Time.get_ticks_msec() - started_msec) / 1000.0 < duration_seconds:
        await get_tree().process_frame
        if frame % SAMPLE_EVERY_FRAMES == 0 and main != null and main.has_method("debug_performance_state"):
            capture_performance_sample()
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
    await get_tree().process_frame
    if not bool(menu.get("launching")) and menu.get("active_main") == null:
        startup_loading_failure = "Main Menu New Game input was not accepted"
        return false
    # Keep the observer outside the production readiness deadline. The game
    # owns the structured loading failure; the runner must not terminate first
    # and discard the domain that explains it.
    var startup_observation_seconds := minf(210.0, maxf(140.0, watchdog_seconds - duration_seconds - 30.0))
    var max_frames := ceili(startup_observation_seconds * float(Engine.physics_ticks_per_second))
    var loading_captured := false
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
            if not loading_captured and screenshot_path != "":
                loading_captured = true
                await capture_screenshot(screenshot_path.get_base_dir().path_join("loading_screen.png"))
        if startup_loading_failure != "":
            return false
        if startup_loading_completed:
            var readiness_domains = main.get("startup_readiness_domains") if main != null else {}
            var gameplay_readiness: Dictionary = readiness_domains.get("gameplay", {}) if readiness_domains is Dictionary else {}
            if String(gameplay_readiness.get("status", "")) != "ready":
                startup_loading_failure = "Main Menu New Game completed without gameplay readiness"
                return false
            if DisplayServer.get_name() != "headless" and not readiness_domains.get("terrain_presentation",{}).get("metrics",{}).get("presentationVerified",false):
                startup_loading_failure = "Main Menu released loading before terrain presentation"
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
    # Button rectangles are in logical viewport coordinates, including stretch.
    get_viewport().push_input(event, true)

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
    # Observe the area New Game actually loaded. Relocating to a preselected
    # lane can move hundreds of metres beyond that area and invalidate timing.
    traversal_spawn = player_body.global_position
    player_body.set("automated_input", true)
    player_body.set("automated_sprint", false)
    player_body.set("automated_move", Vector3.ZERO)
    player_body.set("automated_jump", false)
    if main.has_method("update_chunks"):
        main.call("update_chunks", false)
    return true

func leave_starter_house() -> bool:
    # The scenario provides the generated door location. Movement still uses
    # the player motor, and opening/acknowledgement use ordinary viewport input.
    var tutorial = main.get("tutorial_system")
    var player_body := main.get("player") as CharacterBody3D
    if tutorial == null or player_body == null:
        traversal_entry = {"reason": "missing_spawn_context"}
        return false
    var start_cell: Vector2i = tutorial.get("start_cell")
    var expected := Vector3(float(start_cell.x) * 1.35, traversal_spawn.y, float(start_cell.y - 3) * 1.35)
    var door: Node3D = null
    for value in main.get("blocks").values():
        if value is Node3D and is_instance_valid(value) and String(value.get_meta("block_type", "")) == "door":
            var offset: Vector3 = value.global_position - expected
            if Vector2(offset.x, offset.z).length() < 0.7:
                door = value
                break
    if door == null:
        traversal_entry = {"reason": "generated_starter_door_missing", "expected": vec3(expected)}
        return false
    traversal_entry = {"door": vec3(door.global_position), "spawn": vec3(traversal_spawn), "opened": false, "exited": false}
    write_progress("traversal_entry_approach")
    if not await walk_player_to(door.global_position + Vector3(0, 0, 2.0), 0.3):
        traversal_entry["reason"] = "door_approach_blocked"
        return false
    var camera := player_body.get("camera") as Camera3D
    main.call("set_game_mouse_mode", Input.MOUSE_MODE_CAPTURED)
    var hit := {}
    for _frame in range(120):
        var direction := (door.global_position + Vector3(0, 0.65, 0) - camera.global_position).normalized()
        var yaw_delta := wrapf(atan2(-direction.x, -direction.z) - player_body.global_rotation.y, -PI, PI)
        var pitch_delta := atan2(direction.y, Vector2(direction.x, direction.z).length()) - float(player_body.get("pitch"))
        var motion := InputEventMouseMotion.new()
        motion.relative = Vector2(-yaw_delta, -pitch_delta) * 0.12 / maxf(0.0001, float(player_body.get("mouse_sensitivity")))
        if bool(player_body.get("invert_y")):
            motion.relative.y = -motion.relative.y
        get_viewport().push_input(motion)
        await get_tree().physics_frame
        hit = main.call("focused_interaction_hit")
        if main.call("interaction_block_from_collider", hit.get("collider")) == door:
            break
    if main.call("interaction_block_from_collider", hit.get("collider")) != door:
        traversal_entry["reason"] = "door_not_in_real_interaction_ray"
        return false
    for pressed in [true, false]:
        var click := InputEventMouseButton.new()
        click.button_index = MOUSE_BUTTON_RIGHT
        click.pressed = pressed
        click.position = get_viewport().get_visible_rect().size * 0.5
        click.global_position = click.position
        get_viewport().push_input(click)
    for _frame in range(24):
        await get_tree().physics_frame
    traversal_entry["opened"] = bool(door.get_meta("open", false))
    if not bool(traversal_entry["opened"]):
        traversal_entry["reason"] = "door_did_not_open_after_input"
        return false
    var hud = main.get("hud")
    if hud != null and hud.call("is_dialogue_open"):
        for pressed in [true, false]:
            var key := InputEventKey.new()
            key.keycode = KEY_ESCAPE
            key.pressed = pressed
            get_viewport().push_input(key)
        await get_tree().physics_frame
    write_progress("traversal_entry_crossing")
    traversal_entry["exited"] = await walk_player_to(door.global_position - Vector3(0, 0, 3.0), 0.4)
    traversal_entry["outsidePosition"] = vec3(player_position())
    if screenshot_path != "":
        await capture_screenshot(screenshot_path.get_base_dir().path_join("starter_house_exit.png"))
    return bool(traversal_entry["exited"])

func walk_player_to(target: Vector3, stop_distance: float) -> bool:
    var player_body := main.get("player") as CharacterBody3D
    var started := Time.get_ticks_msec()
    while Time.get_ticks_msec() - started < 10000:
        var offset := target - player_body.global_position
        offset.y = 0.0
        if offset.length() <= stop_distance:
            player_body.set("automated_move", Vector3.ZERO)
            return true
        player_body.set("automated_move", offset.normalized())
        await get_tree().physics_frame
    player_body.set("automated_move", Vector3.ZERO)
    return false

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
    traversal_chunks[Vector2i(floori(current.x / (28.0 * 1.35)), floori(current.z / (28.0 * 1.35)))] = true
    maximum_spawn_distance = maxf(maximum_spawn_distance, Vector2(current.x-traversal_spawn.x, current.z-traversal_spawn.z).length())
    if last_travel_position != Vector3.INF:
        var delta := current - last_travel_position
        delta.y = 0.0
        accumulated_travel_distance += delta.length()
    last_travel_position = current
    var player_body := main.get("player") as CharacterBody3D if main != null else null
    if modal_loading_visible():
        modal_loading_frames += 1
        if modal_loading_samples.size() < 16:
            modal_loading_samples.append({
                "processMsec": Time.get_ticks_msec(),
                "position": vec3(current),
                "streamingActive": bool(main.get("streaming_loading_overlay_active")),
                "streamingHolds": main.get("streaming_loading_overlay_holds").duplicate(true) \
                    if main.get("streaming_loading_overlay_holds") is Dictionary else {}
            })
    if player_body != null:
        if bool(player_body.get("jumped_this_frame")):
            jump_observed_count += 1
        if player_body.has_meta("terrain_collision_hold") and bool(player_body.get_meta("terrain_collision_hold")):
            terrain_collision_hold_frames += 1
            var hold_reason := String(player_body.get_meta("terrain_collision_hold_reason", "unknown"))
            terrain_collision_hold_reasons[hold_reason] = int(terrain_collision_hold_reasons.get(hold_reason, 0)) + 1
            if terrain_hold_samples.size() < 32 and Time.get_ticks_msec()-last_hold_sample_msec >= 1000:
                last_hold_sample_msec = Time.get_ticks_msec()
                var runtime = main.get("voxel_terrain_runtime")
                terrain_hold_samples.append({"processMsec":last_hold_sample_msec,"position":vec3(current),
                    "proof":player_body.get("last_terrain_collision_proof").duplicate(true),
                    "nativeTasks":runtime.voxel_engine_task_stats() if runtime != null else {},
                    "terrain":runtime.stats() if runtime != null else {},
                    "demandError":main.get("streaming_demand_error")})
        observe_voxel_collision_clearance(player_body, current)
    if main != null and main.has_method("surface_y_at_position"):
        var surface_y := float(main.call("surface_y_at_position", current))
        var clearance := current.y - surface_y
        minimum_surface_clearance = minf(minimum_surface_clearance, clearance)
        maximum_below_surface = maxf(maximum_below_surface, -clearance)

func capture_player_collision_hold_baseline() -> void:
    var player_body := main.get("player") as CharacterBody3D if main != null else null
    player_collision_hold_baseline = int(player_body.get("terrain_collision_hold_frames")) \
        if player_body != null else 0
    player_collision_hold_delta = 0

func refresh_player_collision_hold_delta() -> void:
    var player_body := main.get("player") as CharacterBody3D if main != null else null
    var current := int(player_body.get("terrain_collision_hold_frames")) \
        if player_body != null else player_collision_hold_baseline
    player_collision_hold_delta = cumulative_collision_hold_delta(player_collision_hold_baseline, current)

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
    var hit_y := INF
    # Older motion receipts carried a direct ray sample. The bounded runtime
    # receipt now proves only local chunk/collider publication, deliberately
    # avoiding a per-motion surface ray. Keep this acceptance live by pairing
    # that current receipt with the CharacterBody's actual slide contact; do not
    # add a diagnostic physics query back to the production motion hot path.
    if collision_samples is Array and not collision_samples.is_empty():
        var center_sample = collision_samples[0]
        if center_sample is Dictionary and bool((center_sample as Dictionary).get("hit", false)):
            hit_y = float((center_sample as Dictionary).get("hitY", current.y))
    if not is_finite(hit_y):
        var mesh_proof: Variant = (position_proof as Dictionary).get("mesh", {})
        if not mesh_proof is Dictionary or String((mesh_proof as Dictionary).get("collisionAuthority", "")) != "VoxelTerrain":
            return
        var runtime = main.get("voxel_terrain_runtime") if main != null else null
        if runtime == null or not runtime.has_method("voxel_terrain_collider"):
            return
        for index in range(player_body.get_slide_collision_count()):
            var collision := player_body.get_slide_collision(index)
            if collision == null or collision.get_normal().y <= 0.25:
                continue
            if not bool(runtime.call("voxel_terrain_collider", collision.get_collider())):
                continue
            hit_y = collision.get_position().y
            break
    if not is_finite(hit_y):
        return
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
    if is_instance_valid(render_observation): render_observation.phase = scenario
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
    metrics["traversalSetupPosition"] = vec3(traversal_spawn) if traversal_spawn != Vector3.INF else []
    metrics["traversalSetupRelocations"] = 0
    metrics["traversalEntry"] = traversal_entry.duplicate(true)
    metrics["traversalChunkCount"] = traversal_chunks.size()
    metrics["maximumSpawnDistance"] = maximum_spawn_distance
    metrics["menuToNewGameInputMs"] = menu_to_new_game_input_ms
    metrics["newGameInputToFirstLoadingFrameMs"] = new_game_input_to_first_loading_frame_ms
    metrics["newGameInputToGameplayReadyMs"] = new_game_input_to_gameplay_ready_ms
    metrics["firstGameplayFramesMs"] = first_gameplay_frames_ms
    metrics["startupLoadingSteps"] = startup_loading_steps.duplicate(true)
    metrics["startupReadinessDomains"] = main.get("startup_readiness_domains").duplicate(true) if main != null and main.get("startup_readiness_domains") is Dictionary else {}
    var performance_monitor = main.get("runtime_perf_monitor") if main != null else null
    if performance_monitor != null and performance_monitor.has_method("section_percentiles"):
        metrics["sectionPercentiles"] = performance_monitor.call("section_percentiles")
    metrics["measuredFrames"] = frame_count
    metrics["performanceObserverSampleCount"] = samples.size()
    metrics["performanceObserverSampleTotalMs"] = float(performance_sample_total_usec) / 1000.0
    metrics["performanceObserverSampleMaxMs"] = float(performance_sample_max_usec) / 1000.0
    metrics["performanceObserverSampleIntervalFrames"] = SAMPLE_EVERY_FRAMES
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
    metrics["terrainCollisionHoldFrames"] = player_collision_hold_delta
    metrics["terrainCollisionHoldObservedProcessFrames"] = terrain_collision_hold_frames
    metrics["terrainCollisionHoldCounterBaseline"] = player_collision_hold_baseline
    metrics["terrainCollisionHoldReasons"] = terrain_collision_hold_reasons.duplicate(true)
    metrics["terrainCollisionHoldSamples"] = terrain_hold_samples.duplicate(true)
    metrics["modalLoadingVisibleFrames"] = modal_loading_frames
    metrics["modalLoadingSamples"] = modal_loading_samples.duplicate(true)
    # Keep the native secondary-viewer scheduler observable in the same real
    # menu/New Game sprint that measures player-visible cadence. A final sample
    # is not a peak substitute: the runtime owns and reports its own peak.
    var terrain_runtime = main.get("voxel_terrain_runtime") if main != null and is_instance_valid(main) else null
    metrics["terrainRuntime"] = terrain_runtime.call("stats") \
            if terrain_runtime != null and is_instance_valid(terrain_runtime) and terrain_runtime.has_method("stats") else {}
    metrics["terrainNativeTasks"] = terrain_runtime.call("voxel_engine_task_stats") \
            if terrain_runtime != null and is_instance_valid(terrain_runtime) and terrain_runtime.has_method("voxel_engine_task_stats") else {}
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

func capture_performance_sample() -> void:
    var started_usec := Time.get_ticks_usec()
    samples.append(main.call("debug_performance_state", false, false))
    var elapsed_usec := Time.get_ticks_usec() - started_usec
    performance_sample_total_usec += elapsed_usec
    performance_sample_max_usec = maxi(performance_sample_max_usec, elapsed_usec)

func append_presentation_cadence_metrics(metrics: Dictionary) -> void:
    var observation: Dictionary = render_observation.summary() if is_instance_valid(render_observation) else {}
    var phases: Dictionary = observation.get("phases", {}) if observation.get("phases", {}) is Dictionary else {}
    var measured_phase: Dictionary = phases.get(scenario, {}) if phases.get(scenario, {}) is Dictionary else {}
    var cadence: Dictionary = measured_phase.get("cadence", {}) if measured_phase.get("cadence", {}) is Dictionary else {}
    var observer_max_ms := float(measured_phase.get("observerMaxUsec", 0)) / 1000.0
    var provenance_max_ms := float(measured_phase.get("provenanceMaxUsec", 0)) / 1000.0
    var debug_sample_max_ms := float(metrics.get("performanceObserverSampleMaxMs", 0.0))
    var evidence_validity_reasons: Array[String] = []
    if observer_max_ms > GATE5_EVIDENCE_OBSERVER_MAX_MS:
        evidence_validity_reasons.append("render observer exceeded the 2ms evidence-overhead ceiling")
    if provenance_max_ms > GATE5_EVIDENCE_OBSERVER_MAX_MS:
        evidence_validity_reasons.append("cadence provenance observer exceeded the 2ms evidence-overhead ceiling")
    if debug_sample_max_ms > GATE5_EVIDENCE_OBSERVER_MAX_MS:
        evidence_validity_reasons.append("performance snapshot observer exceeded the 2ms evidence-overhead ceiling")
    metrics["gameplayPresentationCadence"] = {
        "phase": scenario,
        "samples": int(cadence.get("samples", 0)),
        "observedSpanMs": float(measured_phase.get("observedSpanMs", 0.0)),
        "p50Ms": cadence.get("p50Ms"),
        "p95Ms": cadence.get("p95Ms"),
        "p99Ms": cadence.get("p99Ms"),
        "maxMs": cadence.get("maxMs"),
        "over33ms": int(cadence.get("over33ms", 0)),
        "over100ms": int(cadence.get("over100ms", 0)),
        "streamingStallsOver33ms": int(measured_phase.get("streamingStallsOver33ms", 0)),
        "streamingStallOwnerCounts": measured_phase.get("streamingStallOwnerCounts", {}).duplicate(true) \
            if measured_phase.get("streamingStallOwnerCounts", {}) is Dictionary else {},
        "streamingOwnerOverflowCount": int(measured_phase.get("streamingOwnerOverflowCount", 0)),
        "recurringStreamingStallsOver33ms": int(measured_phase.get("recurringStreamingStallsOver33ms", 0)),
        "observerMaxMs": observer_max_ms,
        "provenanceMaxMs": provenance_max_ms,
        "performanceSnapshotObserverMaxMs": debug_sample_max_ms,
        "available": bool(observation.get("available", false)),
        "scope": "frame_post_draw cadence for the measured gameplay phase only; startup, phase boundaries, and screenshot capture are excluded"
    }
    metrics["gate5EvidenceValidity"] = {
        "valid": evidence_validity_reasons.is_empty(),
        "reasons": evidence_validity_reasons,
        "observerMaxMsMaximum": GATE5_EVIDENCE_OBSERVER_MAX_MS,
        "policy": "Observer overhead invalidates evidence; cadence time is never subtracted."
    }
    metrics["gate5PresentationAcceptanceCriteria"] = {
        "measuredGameplaySecondsMinimum": GATE5_MEASURED_GAMEPLAY_SECONDS,
        "p99MsMaximum": GATE5_PRESENTATION_P99_MS,
        "maxMsMaximum": GATE5_PRESENTATION_MAX_MS,
        "over100msMaximum": 0,
        "recurringStreamingStallsOver33msMaximum": 0,
        "modalLoadingVisibleFramesMaximum": 0,
        "terrainCollisionHoldFramesMaximum": 0,
        "observerMaxMsMaximum": GATE5_EVIDENCE_OBSERVER_MAX_MS
    }

func normal_runtime_work_budget_failures(metrics: Dictionary) -> Array:
    var failures: Array = metrics_helper.call("performance_failures", metrics)
    # This runner's release cadence is the presentation interval below. The
    # shared helper's Main-only 22/33ms checks remain appropriate to its older
    # 32-NPC suite, but are not total-frame latency and cannot substitute here.
    failures.erase("p99 frame time exceeds 22ms tolerated threshold")
    failures.erase("max frame time exceeds 33ms threshold")
    return failures

func presentation_acceptance_failures(metrics: Dictionary) -> Array[String]:
    var failures: Array[String] = []
    var cadence: Dictionary = metrics.get("gameplayPresentationCadence", {}) \
        if metrics.get("gameplayPresentationCadence", {}) is Dictionary else {}
    if float(metrics.get("measuredGameplaySeconds", 0.0)) < GATE5_MEASURED_GAMEPLAY_SECONDS:
        failures.append("measured gameplay duration is below the 300s Gate 5 acceptance minimum")
    if not bool(cadence.get("available", false)):
        failures.append("presentation cadence observation is unavailable")
    elif int(cadence.get("samples", 0)) <= 0:
        failures.append("measured gameplay phase captured no presentation cadence samples")
    else:
        if float(cadence.get("observedSpanMs", 0.0)) < (GATE5_MEASURED_GAMEPLAY_SECONDS - 1.0) * 1000.0:
            failures.append("presentation cadence observation does not span the 300s measured gameplay window")
        var p99_value = cadence.get("p99Ms")
        var max_value_ms = cadence.get("maxMs")
        if p99_value == null or float(p99_value) > GATE5_PRESENTATION_P99_MS:
            failures.append("measured gameplay presentation p99 exceeds 33ms")
        if max_value_ms == null or float(max_value_ms) > GATE5_PRESENTATION_MAX_MS:
            failures.append("measured gameplay presentation max exceeds 100ms")
        if int(cadence.get("over100ms", 0)) > 0:
            failures.append("measured gameplay contains presentation intervals over 100ms")
        if int(cadence.get("recurringStreamingStallsOver33ms", 0)) > 0:
            failures.append("measured gameplay contains recurring streaming-attributed presentation stalls over 33ms")
    var evidence_validity: Dictionary = metrics.get("gate5EvidenceValidity", {}) \
        if metrics.get("gate5EvidenceValidity", {}) is Dictionary else {}
    if not bool(evidence_validity.get("valid", false)):
        for reason_value in evidence_validity.get("reasons", []):
            failures.append("performance evidence invalid: %s" % String(reason_value))
    if player_collision_hold_delta > 0:
        failures.append("terrain streaming interrupted traversal for %d physics ticks" % player_collision_hold_delta)
    if modal_loading_frames > 0:
        failures.append("modal loading interrupted measured gameplay for %d observed frames" % modal_loading_frames)
    return failures

func _runtime_cadence_provenance() -> Dictionary:
    var monitor = main.get("runtime_perf_monitor") if main != null and is_instance_valid(main) else null
    if monitor == null:
        return {"processFrame": Engine.get_process_frames(), "streamingAttributed": false}
    var frame_ms := float(monitor.get("last_frame_ms"))
    var sections: Dictionary = monitor.get("last_frame_sections") if monitor.get("last_frame_sections") is Dictionary else {}
    var counters: Dictionary = monitor.get("last_frame_counters") if monitor.get("last_frame_counters") is Dictionary else {}
    var process_frame := Engine.get_process_frames()
    var provenance := classify_streaming_cadence_provenance(
        frame_ms, sections, counters, process_frame, process_frame
    )
    provenance["terrainCollisionHold"] = current_player_collision_hold_delta() > 0
    provenance["modalLoadingVisible"] = modal_loading_visible()
    return provenance

static func classify_streaming_cadence_provenance(
        frame_ms: float,
        sections: Dictionary,
        counters: Dictionary,
        provider_process_frame: int,
        expected_process_frame: int
    ) -> Dictionary:
    var domain_totals: Dictionary = {}
    var streaming_owner := ""
    var streaming_owner_ms := 0.0
    var top_sections: Array[Dictionary] = []
    for key_value in sections.keys():
        var key := String(key_value)
        var elapsed_ms := float(sections.get(key_value, 0.0))
        top_sections.append({"name": key, "ms": elapsed_ms})
        if not TOP_LEVEL_FRAME_DOMAIN_BY_SECTION.has(key):
            continue
        var domain := String(TOP_LEVEL_FRAME_DOMAIN_BY_SECTION[key])
        domain_totals[domain] = float(domain_totals.get(domain, 0.0)) + elapsed_ms
        if domain == "world_streaming" and elapsed_ms > streaming_owner_ms:
            streaming_owner = key
            streaming_owner_ms = elapsed_ms
    top_sections.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return float(a.get("ms", 0.0)) > float(b.get("ms", 0.0))
    )
    if top_sections.size() > 8:
        top_sections.resize(8)
    var domain_rows: Array[Dictionary] = []
    for domain_value in domain_totals.keys():
        domain_rows.append({
            "domain": String(domain_value),
            "ms": float(domain_totals.get(domain_value, 0.0))
        })
    domain_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return float(a.get("ms", 0.0)) > float(b.get("ms", 0.0))
    )
    var dominant_domain := String(domain_rows[0].get("domain", "")) if not domain_rows.is_empty() else ""
    var streaming_domain_ms := float(domain_totals.get("world_streaming", 0.0))
    var authoritative_overruns: Array[String] = []
    for counter_name in AUTHORITATIVE_STREAMING_OVERRUN_COUNTERS:
        if int(counters.get(counter_name, 0)) > 0:
            authoritative_overruns.append(counter_name)
    var frame_identity_matched := provider_process_frame == expected_process_frame
    var material_dominant_streaming := dominant_domain == "world_streaming" \
        and streaming_domain_ms >= GATE5_STREAMING_MATERIAL_MS
    var attributed := frame_identity_matched \
        and (material_dominant_streaming or not authoritative_overruns.is_empty())
    if not material_dominant_streaming and not authoritative_overruns.is_empty():
        streaming_owner = "overrun:%s" % authoritative_overruns[0]
    return {
        "processFrame": provider_process_frame,
        "expectedProcessFrame": expected_process_frame,
        "frameIdentityMatched": frame_identity_matched,
        "mainFrameMs": frame_ms,
        "mainTopSections": top_sections,
        "topLevelDomains": domain_rows,
        "dominantTopLevelDomain": dominant_domain,
        "streamingDomainMs": streaming_domain_ms,
        "streamingMaterialThresholdMs": GATE5_STREAMING_MATERIAL_MS,
        "authoritativeStreamingOverruns": authoritative_overruns,
        "streamingAttributed": attributed,
        "streamingOwner": streaming_owner if attributed else ""
    }

static func gate5_evidence_classification(scenario_value: String, configured_duration_seconds: float) -> Dictionary:
    var reasons: Array[String] = []
    if scenario_value != SCENARIO_SPRINT_TRAVERSAL:
        reasons.append("scenario is a focused diagnostic, not the Gate 5 sprint traversal")
    if configured_duration_seconds < GATE5_MEASURED_GAMEPLAY_SECONDS:
        reasons.append("configured duration is below the 300s Gate 5 minimum")
    return {
        "eligible": reasons.is_empty(),
        "classification": "gate5_presentation_acceptance" if reasons.is_empty() else "diagnostic",
        "reasons": reasons
    }

func current_player_collision_hold_delta() -> int:
    var player_body := main.get("player") as CharacterBody3D if main != null else null
    if player_body == null:
        return player_collision_hold_delta
    return cumulative_collision_hold_delta(
        player_collision_hold_baseline,
        int(player_body.get("terrain_collision_hold_frames"))
    )

static func cumulative_collision_hold_delta(baseline: int, current: int) -> int:
    return maxi(0, current - baseline)

func modal_loading_visible() -> bool:
    if main == null or not is_instance_valid(main):
        return false
    if bool(main.get("streaming_loading_overlay_active")):
        return true
    var hud_value = main.get("hud")
    if hud_value != null and is_instance_valid(hud_value):
        var overlay = hud_value.get("loading_overlay")
        if overlay is CanvasItem and (overlay as CanvasItem).visible:
            return true
    return false

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

func capture_screenshot(destination := "") -> void:
    if DisplayServer.get_name() == "headless":
        return
    var previous_phase := String(render_observation.phase)
    render_observation.phase = "screenshot_capture"
    await RenderingServer.frame_post_draw
    var target := destination if destination != "" else screenshot_path
    DirAccess.make_dir_recursive_absolute(target.get_base_dir())
    var image := get_viewport().get_texture().get_image()
    image.save_png(target)
    # Retain capture/readback cost in its own phase and overall cadence, without
    # calling this synchronous observer work a gameplay streaming stall.
    await RenderingServer.frame_post_draw
    render_observation.phase = previous_phase

func player_position() -> Vector3:
    var player_body := main.get("player") as Node3D if main != null else null
    return player_body.global_position if player_body != null else Vector3.INF

func failed_result(reason: String) -> Dictionary:
    var startup_failure: Dictionary = {}
    if main != null and is_instance_valid(main) and main.get("startup_loading_failure_result") is Dictionary:
        startup_failure = (main.get("startup_loading_failure_result") as Dictionary).duplicate(true)
    var readiness_domains: Dictionary = main.get("startup_readiness_domains").duplicate(true) \
        if main != null and is_instance_valid(main) and main.get("startup_readiness_domains") is Dictionary else {}
    var terrain_runtime = main.get("voxel_terrain_runtime") if main != null and is_instance_valid(main) else null
    var terrain_state: Dictionary = terrain_runtime.call("stats") \
        if terrain_runtime != null and is_instance_valid(terrain_runtime) and terrain_runtime.has_method("stats") else {}
    var recent_loading_steps: Array = startup_loading_steps.slice(maxi(0, startup_loading_steps.size() - 24))
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
            "firstGameplayFramesMs": first_gameplay_frames_ms,
            "startupFailure": startup_failure,
            "startupReadinessDomains": readiness_domains,
            "recentStartupLoadingSteps": recent_loading_steps,
            "terrainRuntime": terrain_state
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
    if is_instance_valid(render_observation): report["renderObservation"] = render_observation.summary()
    DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
    var file := FileAccess.open(report_path, FileAccess.WRITE)
    if file == null:
        push_error("Unable to write normal runtime performance report: %s" % report_path)
        return
    file.store_string(JSON.stringify(report, "  "))
    file.close()

func finish(code: int) -> void:
    finished = true
    if is_instance_valid(render_observation): render_observation.stop()
    call_deferred("_quit_deferred", code)

func _quit_deferred(code: int) -> void:
    # This service-style helper is an unparented Node, so tree teardown cannot
    # release it. The real game's existing quit path owns world/worker cleanup.
    if is_instance_valid(metrics_helper): metrics_helper.free()
    metrics_helper = null
    if main != null and is_instance_valid(main):
        main.request_graceful_quit(code)
        return
    get_tree().quit(code)

func elapsed_ms(start_usec: int) -> float:
    return float(Time.get_ticks_usec() - start_usec) / 1000.0

func vec3(value: Vector3) -> Array:
    return [value.x, value.y, value.z]
