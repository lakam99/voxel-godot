extends "res://scripts/testing/NormalRuntimePerformancePassRunner.gd"

const RUN_SECONDS := 4.5
const TURN_RADIANS := PI * 0.85
const MIN_NEW_AREA_DISTANCE := 45.0

var capture_dir := ""
var checkpoints: Array[Dictionary] = []
var trace: Array[Dictionary] = []


func configure_from_environment() -> void:
    super.configure_from_environment()
    report_path = OS.get_environment("VOXEL_VISIBLE_WORLD_FAST_TURN_REPORT").strip_edges()
    if report_path.is_empty():
        report_path = ProjectSettings.globalize_path("res://artifacts/visible-world/fast-turn-sprint/report.json")
    progress_path = OS.get_environment("VOXEL_VISIBLE_WORLD_FAST_TURN_PROGRESS").strip_edges()
    capture_dir = OS.get_environment("VOXEL_VISIBLE_WORLD_FAST_TURN_SCREENSHOT_DIR").strip_edges()
    if capture_dir.is_empty():
        capture_dir = ProjectSettings.globalize_path("res://artifacts/visible-world/fast-turn-sprint/screenshots")
    run_token = OS.get_environment("VOXEL_VISIBLE_WORLD_FAST_TURN_RUN_TOKEN").strip_edges()
    var watchdog_value := OS.get_environment("VOXEL_VISIBLE_WORLD_FAST_TURN_WATCHDOG_SECONDS").strip_edges()
    watchdog_seconds = maxf(90.0, float(watchdog_value)) if not watchdog_value.is_empty() else 300.0
    scenario = "VisibleWorldFastTurnSprint"


func normal_runtime_environment_failure() -> String:
    var requested_scenario := scenario
    scenario = SCENARIO_SPRINT_TRAVERSAL
    var failure := super.normal_runtime_environment_failure()
    scenario = requested_scenario
    return failure


func run() -> void:
    write_progress("menu_new_game")
    var failures: Array[String] = []
    if normal_runtime_environment_failure() != "":
        failures.append(normal_runtime_environment_failure())
    elif not await launch_main_via_menu_new_game_input():
        failures.append(startup_loading_failure if not startup_loading_failure.is_empty() else "New Game did not reach gameplay readiness")
    else:
        playtest_survival_policy = PlaytestSurvivalPolicyScript.enable_player_god_mode(main, "fast_turn_sprint_observer")
        if not bool(playtest_survival_policy.get("enabled", false)):
            failures.append("night-safe player observer could not be enabled")
        elif not configure_player_for_runtime_traversal():
            failures.append("production player motor unavailable")
        elif not await leave_starter_house():
            failures.append("player could not leave the generated starter house through its real door")
        else:
            await _run_visual_act(failures)
    stop_player_automation()
    var cadence := _measured_cadence()
    var performance: Dictionary = metrics_helper.call("summarize_samples", samples) if not samples.is_empty() else {}
    var monitor = main.get("runtime_perf_monitor") if main != null and is_instance_valid(main) else null
    var report := {
        "schemaVersion": 1,
        "runnerId": "visible_world_fast_turn_sprint",
        "evidenceLevel": "live_headed_acceptance",
        "runToken": run_token,
        "seed": String(main.get("seed_text")) if main != null and is_instance_valid(main) else "",
        "launchPath": "MainMenu.tscn -> visible New Game button viewport input -> startup_loading_completed -> real door -> player motor",
        "controls": {"voxelPlaytest": OS.get_environment("VOXEL_PLAYTEST"),
            "testSeedOverride": OS.get_environment("VOXEL_TEST_SEED"), "fixedFps": false,
            "playerRelocated": false, "npcMutation": false},
        "startup": {"menuToNewGameInputMs": menu_to_new_game_input_ms,
            "newGameInputToFirstLoadingFrameMs": new_game_input_to_first_loading_frame_ms,
            "newGameInputToGameplayReadyMs": new_game_input_to_gameplay_ready_ms,
            "readinessDomains": main.get("startup_readiness_domains").duplicate(true)
                if main != null and is_instance_valid(main) and main.get("startup_readiness_domains") is Dictionary else {}},
        "checkpoints": checkpoints,
        "trace": trace,
        "performance": performance,
        "performanceMonitor": monitor.call("summary") if is_instance_valid(monitor) else {},
        "sectionPercentiles": monitor.call("section_percentiles") if is_instance_valid(monitor) else {},
        "gameplayPresentationCadence": cadence,
        "failures": failures,
        "resultCount": 1,
        "failureCount": 0 if failures.is_empty() else 1,
        "passed": failures.is_empty(),
        "results": [{"id": "fast_turn_and_continuous_sprint", "passed": failures.is_empty(), "failures": failures}]
    }
    write_report(report)
    finish(0 if failures.is_empty() else 1)


func _run_visual_act(failures: Array[String]) -> void:
    var player_body := main.get("player") as CharacterBody3D
    main.call("set_game_mouse_mode", Input.MOUSE_MODE_CAPTURED)
    await _checkpoint("first_outdoor_control")
    var first_position := player_body.global_position
    var initial_yaw := player_body.global_rotation.y
    reset_runtime_performance_monitor()
    samples.clear()
    render_observation.phase = scenario
    write_progress("rapid_turn_outdoors")
    await _turn_by_mouse_input(TURN_RADIANS)
    await _checkpoint("after_rapid_turn")
    var actual_turn := absf(wrapf(player_body.global_rotation.y - initial_yaw, -PI, PI))
    if actual_turn < deg_to_rad(110.0):
        failures.append("viewport mouse input turned the player less than 110 degrees")
    player_body.set("automated_input", true)
    player_body.set("automated_move", Vector3(1.0, 0.0, 0.0))
    player_body.set("automated_sprint", true)
    var sprint_started := Time.get_ticks_msec()
    var turned_during_sprint := false
    var observed_sprint_ticks := 0
    var frame := 0
    write_progress("continuous_sprint")
    while float(Time.get_ticks_msec() - sprint_started) / 1000.0 < RUN_SECONDS:
        await get_tree().process_frame
        if bool(player_body.get("is_sprinting")):
            observed_sprint_ticks += 1
        if frame % 30 == 0:
            if main.has_method("debug_performance_state"):
                capture_performance_sample()
            trace.append(_trace_sample("sprint"))
        if not turned_during_sprint and float(Time.get_ticks_msec() - sprint_started) / 1000.0 >= 1.7:
            turned_during_sprint = true
            write_progress("rapid_turn_while_sprinting")
            await _turn_by_mouse_input(-TURN_RADIANS)
            await _checkpoint("after_sprint_turn")
        frame += 1
    player_body.set("automated_move", Vector3.ZERO)
    player_body.set("automated_sprint", false)
    await _checkpoint("new_streamed_area")
    var distance := Vector2(player_body.global_position.x - first_position.x,
        player_body.global_position.z - first_position.z).length()
    var sprint_fraction := float(observed_sprint_ticks) / float(maxi(1, frame))
    trace.append({"event": "act_complete", "distanceFromFirstOutdoorMeters": distance,
        "observedSprintFrames": observed_sprint_ticks, "observedProcessFrames": frame,
        "sprintFrameFraction": sprint_fraction, "elapsedSeconds": RUN_SECONDS})
    if distance < MIN_NEW_AREA_DISTANCE:
        failures.append("continuous sprint did not reach a new streamed area 45m away")
    if sprint_fraction < 0.8:
        failures.append("player motor did not report sustained sprinting")
    for checkpoint in checkpoints:
        if not bool(checkpoint.get("screenshotSaved", false)):
            failures.append("screenshot missing at %s" % String(checkpoint.get("name", "")))
        if String(checkpoint.get("fullViewStatus", "")) != "ready":
            failures.append("full visible view was not ready at %s" % String(checkpoint.get("name", "")))
    var cadence := _measured_cadence()
    if int(cadence.get("samples", 0)) == 0:
        failures.append("no drawn-frame cadence samples were captured")
    elif int(cadence.get("over100ms", 0)) > 0:
        failures.append("measured gameplay contained a drawn-frame interval over 100ms")


func _turn_by_mouse_input(radians: float) -> void:
    var player_body := main.get("player") as CharacterBody3D
    var sensitivity := maxf(0.0001, float(player_body.get("mouse_sensitivity")))
    for _step in range(4):
        var motion := InputEventMouseMotion.new()
        motion.relative = Vector2(-radians / (4.0 * sensitivity), 0.0)
        get_viewport().push_input(motion)
        await get_tree().physics_frame


func _checkpoint(name: String) -> void:
    var destination := capture_dir.path_join("%s.png" % name)
    await capture_screenshot(destination)
    var row := _trace_sample(name)
    row["name"] = name
    row["screenshot"] = destination
    row["screenshotSaved"] = FileAccess.file_exists(destination)
    var full: Dictionary = row.get("fullView", {})
    row["fullViewStatus"] = String(full.get("status", "pending"))
    checkpoints.append(row)
    trace.append({"event": "checkpoint", "name": name,
        "position": row.get("position", []), "yawRadians": row.get("yawRadians", 0.0),
        "fullViewStatus": row["fullViewStatus"], "queue": row.get("queue", {}),
        "coverageLag": row.get("coverageLag", 0.0)})


func _trace_sample(label: String) -> Dictionary:
    var player_body := main.get("player") as CharacterBody3D
    var runtime = main.get("voxel_terrain_runtime")
    var controller = main.get("visible_world_demand_controller")
    var requests: Dictionary = main.get("streaming_requests")
    var full: Dictionary = controller.call("full_view_readiness", "player",
        int(requests.get("player", 0)), String(main.get("seed_text")),
        String(runtime.call("visible_mesh_world_revision"))) \
        if is_instance_valid(controller) and is_instance_valid(runtime) else {}
    var advance: Dictionary = main.get("visible_world_demand_last_advance")
    var view_center: Vector2 = main.get("visible_world_view_center_cells")
    var observer_cell := Vector2(player_body.global_position.x / 1.35,
        player_body.global_position.z / 1.35)
    var center_lag := observer_cell.distance_to(view_center)
    return {"label": label, "processFrame": Engine.get_process_frames(),
        "position": vec3(player_body.global_position), "yawRadians": player_body.global_rotation.y,
        "sprinting": bool(player_body.get("is_sprinting")),
        "collisionHold": bool(player_body.get_meta("terrain_collision_hold", false)),
        "modalLoading": modal_loading_visible(),
        "fullView": {"status": full.get("status", "pending"),
            "reason": full.get("reason", ""), "candidateCount": full.get("candidateCount", 0),
            "representedCount": full.get("representedCount", 0),
            "pendingCount": full.get("pendingCount", 0),
            "byKind": full.get("byKind", {}), "coverageGaps": (full.get("coverageGaps", []) as Array).slice(0, 8),
            "viewRevision": full.get("viewRevision", 0),
            "visualDemandRevision": full.get("visualDemandRevision", 0)},
        "queue": full.get("queue", {}), "coverageLag": full.get("coverageLag", 0.0),
        "observerCell": [observer_cell.x, observer_cell.y],
        "viewCenterCells": [view_center.x, view_center.y],
        "liveCenterLagCells": center_lag,
        "demandAdvance": {"status": advance.get("status", ""),
            "reason": advance.get("reason", ""), "queueDepth": advance.get("queueDepth", 0)}}


func _measured_cadence() -> Dictionary:
    if not is_instance_valid(render_observation):
        return {}
    var phases: Dictionary = render_observation.summary().get("phases", {})
    var measured: Dictionary = phases.get(scenario, {})
    var cadence: Dictionary = measured.get("cadence", {})
    return {"samples": cadence.get("samples", 0), "p50Ms": cadence.get("p50Ms"),
        "p95Ms": cadence.get("p95Ms"), "p99Ms": cadence.get("p99Ms"),
        "maxMs": cadence.get("maxMs"), "over33ms": cadence.get("over33ms", 0),
        "over100ms": cadence.get("over100ms", 0),
        "streamingStallsOver33ms": measured.get("streamingStallsOver33ms", 0),
        "scope": "frame_post_draw during rapid turns and sprint; screenshot readback is a separate phase"}
