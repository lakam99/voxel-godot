extends "res://scripts/testing/NormalRuntimePerformancePassRunner.gd"

const MAIN_SCENE := preload("res://scenes/Main.tscn")
const RUN_SECONDS := 4.5
const TURN_RADIANS := PI * 0.85
const MIN_NEW_AREA_DISTANCE := 45.0
const DATA_PREFETCH_DISTANCE := 112
const DATA_PREFETCH_WARMUP_SECONDS := 5.0
const DATA_PREFETCH_CHUNK_CELLS := 28
const DATA_PREFETCH_ID := "diagnostic-visible-world-data-prefetch"

var capture_dir := ""
var checkpoints: Array[Dictionary] = []
var trace: Array[Dictionary] = []
var diagnostic_replay_seed := ""
var data_prefetch_probe_mode := ""
var data_prefetch_viewer: VoxelViewer = null
var data_prefetch_attached := false
var data_prefetch_attach_ms := -1.0
var data_prefetch_move_attempts := 0
var data_prefetch_move_admitted := 0
var data_prefetch_last_cell := Vector2i(2147483000, 2147483000)
var data_prefetch_samples: Array[Dictionary] = []
var terrain_manifest_step_usec: Array[int] = []
var visual_advance_total_usec: Array[int] = []
var prop_manifest_step_usec: Array[int] = []
var structure_manifest_step_usec: Array[int] = []
var coverage_step_usec: Array[int] = []
var coverage_geometry_step_usec: Array[int] = []
var receipt_validation_step_usec: Array[int] = []
var receipt_validation_by_kind_timing: Dictionary = {}


class SeededMain extends "res://scripts/Main.gd":
    # The fixture selects one known failing seed without touching the game's
    # RNG, save selection, world publishers, or production New Game policy.
    var diagnostic_seed := ""
    func random_world_seed(_exclude_seed := "") -> String:
        return diagnostic_seed


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
    diagnostic_replay_seed = OS.get_environment("VOXEL_VISIBLE_WORLD_DIAGNOSTIC_REPLAY_SEED").strip_edges()
    data_prefetch_probe_mode = OS.get_environment("VOXEL_VISIBLE_WORLD_DATA_PREFETCH_PROBE").strip_edges()


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
    else:
        var launched := false
        if diagnostic_replay_seed.is_empty():
            launched = await launch_main_via_menu_new_game_input()
        else:
            launched = await _launch_seeded_main_diagnostic()
        if not launched:
            failures.append(startup_loading_failure if not startup_loading_failure.is_empty() else "New Game did not reach gameplay readiness")
        else:
            playtest_survival_policy = PlaytestSurvivalPolicyScript.enable_player_god_mode(main, "fast_turn_sprint_observer")
            if not bool(playtest_survival_policy.get("enabled", false)):
                failures.append("night-safe player observer could not be enabled")
            elif not configure_player_for_runtime_traversal():
                failures.append("production player motor unavailable")
            elif not bool(main.launch_options.get("skipTutorial", false)) and not await leave_starter_house():
                failures.append("player could not leave the generated starter house through its real door")
            else:
                await _run_visual_act(failures)
    stop_player_automation()
    var data_prefetch_probe := _data_prefetch_report()
    _retire_data_prefetch_viewer()
    var cadence := _measured_cadence()
    var performance: Dictionary = metrics_helper.call("summarize_samples", samples) if not samples.is_empty() else {}
    var monitor = main.get("runtime_perf_monitor") if main != null and is_instance_valid(main) else null
    var report := {
        "schemaVersion": 1,
        "runnerId": "visible_world_fast_turn_sprint",
        "evidenceLevel": "live_headed_diagnostic" if not diagnostic_replay_seed.is_empty() or not data_prefetch_probe_mode.is_empty()
            else "live_headed_acceptance",
        "runToken": run_token,
        "seed": String(main.get("seed_text")) if main != null and is_instance_valid(main) else "",
        "launchPath": "Main.tscn -> fixture-only seeded Main subclass -> production startup -> player motor"
            if not diagnostic_replay_seed.is_empty()
            else ("MainMenu.tscn -> visible New Game button viewport input -> startup_loading_completed -> player motor"
                if main != null and is_instance_valid(main) and bool(main.launch_options.get("skipTutorial", false))
                else "MainMenu.tscn -> visible New Game button viewport input -> startup_loading_completed -> real door -> player motor"),
        "controls": {"voxelPlaytest": OS.get_environment("VOXEL_PLAYTEST"),
            "testSeedOverride": OS.get_environment("VOXEL_TEST_SEED"), "fixedFps": false,
            "diagnosticReplaySeed": diagnostic_replay_seed,
            "dataPrefetchProbe": data_prefetch_probe_mode,
            "skipTutorial": bool(main.launch_options.get("skipTutorial", false)) if main != null and is_instance_valid(main) else false,
            "forceDaytime": bool(main.launch_options.get("forceDaytime", false)) if main != null and is_instance_valid(main) else false,
            "forceClearWeather": bool(main.launch_options.get("forceClearWeather", false)) if main != null and is_instance_valid(main) else false,
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
        "dataPrefetchProbe": data_prefetch_probe,
        "terrainManifestStepTiming": _terrain_manifest_step_timing(),
        "visualAdvanceTotalTiming": _timing_summary(visual_advance_total_usec),
        "propManifestStepTiming": _timing_summary(prop_manifest_step_usec),
        "structureManifestStepTiming": _timing_summary(structure_manifest_step_usec),
        "coverageStepTiming": _timing_summary(coverage_step_usec),
        "coverageGeometryStepTiming": _timing_summary(coverage_geometry_step_usec),
        "receiptValidationStepTiming": _timing_summary(receipt_validation_step_usec),
        "receiptValidationByKindTiming": receipt_validation_by_kind_timing,
        "failures": failures,
        "resultCount": 1,
        "failureCount": 0 if failures.is_empty() else 1,
        "passed": failures.is_empty(),
        "results": [{"id": "fast_turn_and_continuous_sprint", "passed": failures.is_empty(), "failures": failures}]
    }
    write_report(report)
    finish(0 if failures.is_empty() else 1)


func _launch_seeded_main_diagnostic() -> bool:
    if diagnostic_replay_seed.is_empty(): return false
    new_game_input_started_usec = Time.get_ticks_usec()
    main = MAIN_SCENE.instantiate()
    if main == null:
        startup_loading_failure = "Main.tscn could not be instantiated"
        return false
    main.set_script(SeededMain)
    main.set("diagnostic_seed", diagnostic_replay_seed)
    main.set("startup_mode", "new_game")
    connect_main_loading_signals()
    add_child(main)
    write_progress("diagnostic_seeded_main_startup")
    var max_frames := ceili(300.0 * float(Engine.physics_ticks_per_second))
    for frame in range(max_frames):
        await get_tree().process_frame
        if first_loading_frame_usec <= 0:
            first_loading_frame_usec = Time.get_ticks_usec()
            new_game_input_to_first_loading_frame_ms = elapsed_ms(new_game_input_started_usec)
        if startup_loading_failure != "": return false
        if startup_loading_completed:
            var readiness_domains: Dictionary = main.get("startup_readiness_domains")
            if readiness_domains.get("gameplay", {}).get("status") != "ready":
                startup_loading_failure = "seeded Main completed without gameplay readiness"
                return false
            new_game_input_to_gameplay_ready_ms = float(gameplay_ready_usec - new_game_input_started_usec) / 1000.0
            await get_tree().process_frame
            await get_tree().physics_frame
            return String(main.get("seed_text")) == diagnostic_replay_seed
        if frame % 120 == 0:
            write_progress("diagnostic_seeded_main_waiting frame=%d" % frame)
    startup_loading_failure = "Diagnostic seeded Main loading timed out"
    return false


func _prepare_data_prefetch_probe() -> void:
    # Both probe modes pause for the same bounded interval after first control.
    # Only the data mode requests a secondary viewer, so the control measures
    # the same player position and elapsed background-publication opportunity.
    var runtime = main.get("voxel_terrain_runtime") if is_instance_valid(main) else null
    var player_body = main.get("player") as CharacterBody3D if is_instance_valid(main) else null
    var started_usec := Time.get_ticks_usec()
    if data_prefetch_probe_mode == "data" and is_instance_valid(runtime) and is_instance_valid(player_body):
        data_prefetch_viewer = VoxelViewer.new()
        data_prefetch_viewer.name = "DiagnosticDataOnlyPrefetch"
        data_prefetch_viewer.requires_visuals = false
        data_prefetch_viewer.requires_collisions = false
        data_prefetch_viewer.view_distance = DATA_PREFETCH_DISTANCE
        runtime.call("_stage_secondary_viewer", DATA_PREFETCH_ID, "prefetch",
            data_prefetch_viewer, player_body.global_position, DATA_PREFETCH_DISTANCE, [], 2)
        data_prefetch_last_cell = _data_prefetch_coarse_cell(player_body.global_position)
    write_progress("data_prefetch_%s_warmup" % data_prefetch_probe_mode)
    while float(Time.get_ticks_usec() - started_usec) / 1000000.0 < DATA_PREFETCH_WARMUP_SECONDS:
        await get_tree().process_frame
        if not data_prefetch_attached and is_instance_valid(data_prefetch_viewer) \
                and data_prefetch_viewer.is_inside_tree():
            data_prefetch_attached = true
            data_prefetch_attach_ms = float(Time.get_ticks_usec() - started_usec) / 1000.0
    data_prefetch_samples.append(_data_prefetch_snapshot("after_warmup", true))


func _data_prefetch_coarse_cell(position: Vector3) -> Vector2i:
    var span := 1.35 * float(DATA_PREFETCH_CHUNK_CELLS)
    return Vector2i(floori(position.x / span), floori(position.z / span))


func _advance_data_prefetch_position(position: Vector3) -> void:
    if data_prefetch_probe_mode != "data" or not data_prefetch_attached \
            or not is_instance_valid(data_prefetch_viewer) or not position.is_finite():
        return
    var next_cell := _data_prefetch_coarse_cell(position)
    if next_cell == data_prefetch_last_cell: return
    var runtime = main.get("voxel_terrain_runtime") if is_instance_valid(main) else null
    if not is_instance_valid(runtime) or int(runtime.call("voxel_engine_pending_task_count")) > 8:
        return
    var gate = runtime.get("site_gate")
    if not is_instance_valid(gate): return
    data_prefetch_move_attempts += 1
    if bool(gate.call("request_viewer", data_prefetch_viewer, position, DATA_PREFETCH_DISTANCE)):
        data_prefetch_move_admitted += 1
    # SiteGate retains pending requests and retries them. Coalescing here avoids
    # submitting the same broad native footprint on each sampled process frame.
    data_prefetch_last_cell = next_cell


func _data_prefetch_snapshot(label: String, sample_shell: bool) -> Dictionary:
    var runtime = main.get("voxel_terrain_runtime") if is_instance_valid(main) else null
    var player_body = main.get("player") as CharacterBody3D if is_instance_valid(main) else null
    if not is_instance_valid(runtime) or not is_instance_valid(player_body):
        return {"label": label, "status": "owner_unavailable"}
    var terrain = runtime.get("terrain")
    var task_stats: Dictionary = runtime.call("voxel_engine_task_stats")
    var terrain_stats: Dictionary = terrain.get_statistics() if is_instance_valid(terrain) else {}
    var row := {"label": label, "status": "sampled",
        "elapsedMsec": Time.get_ticks_msec(),
        "viewerAttached": data_prefetch_attached,
        "viewerPosition": vec3(data_prefetch_viewer.global_position)
            if data_prefetch_attached and is_instance_valid(data_prefetch_viewer) else [],
        "nativeTasks": task_stats.get("tasks", {}),
        "remainingMainThreadBlocks": terrain_stats.get("remaining_main_thread_blocks", -1),
        "droppedBlockLoads": terrain_stats.get("dropped_block_loads", -1),
        "droppedBlockMeshes": terrain_stats.get("dropped_block_meshs", -1),
        "updatedBlocks": terrain_stats.get("updated_blocks", -1)}
    if not sample_shell or not is_instance_valid(terrain): return row
    var data_block_size := int(terrain.get_data_block_size())
    var vertical: Vector2i = runtime.call("visible_mesh_vertical_bounds")
    var shell := {}
    for radius_m in [88.0, 104.0, 112.0]:
        var counts := {"sampled": 0, "dataResident": 0, "meshComplete": 0,
            "outsideVerticalBounds": 0}
        for offset in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
            for y_offset_cells in [-8, 0, 8]:
                var sample_world: Vector3 = player_body.global_position + Vector3(
                    offset.x * radius_m, float(y_offset_cells) * 1.35,
                    offset.y * radius_m)
                var sample_cell: Vector3 = sample_world / 1.35
                if sample_cell.y < float(vertical.x) or sample_cell.y > float(vertical.y):
                    counts.outsideVerticalBounds += 1
                    continue
                var data_block := Vector3i(floori(sample_cell.x / float(data_block_size)),
                    floori(sample_cell.y / float(data_block_size)),
                    floori(sample_cell.z / float(data_block_size)))
                var mesh_block := Vector3i(floori(sample_cell.x / 16.0),
                    floori(sample_cell.y / 16.0), floori(sample_cell.z / 16.0))
                counts.sampled += 1
                if bool(terrain.has_data_block(data_block)): counts.dataResident += 1
                if bool(runtime.call("visible_mesh_area_complete", mesh_block)):
                    counts.meshComplete += 1
        shell[str(radius_m)] = counts
    row["shell"] = shell
    return row


func _data_prefetch_report() -> Dictionary:
    if data_prefetch_probe_mode.is_empty(): return {}
    return {"mode": data_prefetch_probe_mode,
        "scope": "fixture-only data loading probe; data residency never counts as visual readiness",
        "distanceWorldUnits": DATA_PREFETCH_DISTANCE,
        "warmupSeconds": DATA_PREFETCH_WARMUP_SECONDS,
        "viewerAttached": data_prefetch_attached,
        "viewerAttachMs": data_prefetch_attach_ms,
        "moveAttempts": data_prefetch_move_attempts,
        "moveAdmissions": data_prefetch_move_admitted,
        "samples": data_prefetch_samples.duplicate(true)}


func _retire_data_prefetch_viewer() -> void:
    if not is_instance_valid(data_prefetch_viewer): return
    var runtime = main.get("voxel_terrain_runtime") if is_instance_valid(main) else null
    if is_instance_valid(runtime):
        var admissions: Dictionary = runtime.get("secondary_viewer_admissions")
        admissions.erase(DATA_PREFETCH_ID)
        runtime.set("secondary_viewer_admissions", admissions)
        var gate = runtime.get("site_gate")
        if is_instance_valid(gate): gate.call("remove_viewer", data_prefetch_viewer)
    data_prefetch_viewer.queue_free()
    data_prefetch_viewer = null


func _run_visual_act(failures: Array[String]) -> void:
    var player_body := main.get("player") as CharacterBody3D
    main.call("set_game_mouse_mode", Input.MOUSE_MODE_CAPTURED)
    if not data_prefetch_probe_mode.is_empty():
        await _prepare_data_prefetch_probe()
        if data_prefetch_probe_mode == "data" and not data_prefetch_attached:
            failures.append("diagnostic data prefetch viewer was not admitted during warmup")
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
        if terrain_manifest_step_usec.size() < 600:
            var advance: Dictionary = main.get("visible_world_demand_last_advance")
            terrain_manifest_step_usec.append(maxi(0, int(advance.get("terrainAdvanceUsec", 0))))
            visual_advance_total_usec.append(maxi(0, int(advance.get("advanceTotalUsec", 0))))
            prop_manifest_step_usec.append(maxi(0, int(advance.get("propAdvanceUsec", 0))))
            structure_manifest_step_usec.append(maxi(0, int(advance.get("structureAdvanceUsec", 0))))
            coverage_step_usec.append(maxi(0, int(advance.get("coverageAdvanceUsec", 0))))
            coverage_geometry_step_usec.append(maxi(0, int(advance.get("coverageGeometryUsec", 0))))
            receipt_validation_step_usec.append(maxi(0, int(advance.get("receiptValidationUsec", 0))))
            var by_kind: Dictionary = advance.get("receiptValidationByKindUsec", {})
            for kind_value in by_kind:
                var kind := String(kind_value)
                var elapsed_usec := maxi(0, int(by_kind[kind_value]))
                var timing: Dictionary = receipt_validation_by_kind_timing.get(kind,
                    {"samples": 0, "totalUsec": 0, "maxUsec": 0})
                timing.samples = int(timing.samples) + 1
                timing.totalUsec = int(timing.totalUsec) + elapsed_usec
                timing.maxUsec = maxi(int(timing.maxUsec), elapsed_usec)
                receipt_validation_by_kind_timing[kind] = timing
        if bool(player_body.get("is_sprinting")):
            observed_sprint_ticks += 1
        if frame % 30 == 0:
            _advance_data_prefetch_position(player_body.global_position)
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
    row["nativeTerrainFrontier"] = _native_terrain_frontier_diagnostics(row)
    if not data_prefetch_probe_mode.is_empty():
        var prefetch := _data_prefetch_snapshot(name, true)
        data_prefetch_samples.append(prefetch)
        row["dataPrefetch"] = prefetch
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


func _native_terrain_frontier_diagnostics(checkpoint: Dictionary) -> Dictionary:
    var runtime = main.get("voxel_terrain_runtime") if is_instance_valid(main) else null
    if not is_instance_valid(runtime): return {"status": "runtime_unavailable"}
    var viewer = runtime.get("viewer")
    var target: Vector3 = runtime.get("foreground_collision_target")
    var result := {"status": "sampled",
        "primaryViewerPosition": vec3(viewer.global_position) if is_instance_valid(viewer) else [],
        "foregroundCollisionTarget": vec3(target) if target.is_finite() else [],
        "primaryRequestCell": str(runtime.get("primary_viewer_request_cell")),
        "startupAuxiliaryViewers": (runtime.get("startup_auxiliary_viewers") as Array).size(),
        "retainedViewers": (runtime.get("retained_chunk_viewers") as Dictionary).size(),
        "blocks": []}
    var source_ids: Array[String] = []
    for pending_value in checkpoint.get("pendingRepresentations", []):
        if not pending_value is Dictionary: continue
        var pending: Dictionary = pending_value
        if String(pending.get("kind", "")) == "terrain":
            source_ids.append(String(pending.get("sourceId", "")))
    var full: Dictionary = checkpoint.get("fullView", {})
    for gap_value in full.get("coverageGaps", []):
        if not gap_value is Dictionary: continue
        var gap: Dictionary = gap_value
        if String(gap.get("kind", "")) == "terrain":
            source_ids.append(String(gap.get("sourceId", "")))
    for source_id in source_ids:
        if (result["blocks"] as Array).size() >= 8: break
        if not source_id.begins_with("terrain-mesh:"): continue
        var components := source_id.trim_prefix("terrain-mesh:").split(",")
        if components.size() != 3 or not components[0].is_valid_int() \
                or not components[1].is_valid_int() or not components[2].is_valid_int():
            continue
        var block := Vector3i(int(components[0]), int(components[1]), int(components[2]))
        var diagnostics: Dictionary = runtime.call("visible_mesh_area_diagnostics", block)
        diagnostics["sourceId"] = source_id
        diagnostics["sourceRevision"] = String(runtime.call("visible_mesh_source_revision", block))
        (result["blocks"] as Array).append(diagnostics)
    return result


func _trace_sample(label: String) -> Dictionary:
    var player_body := main.get("player") as CharacterBody3D
    var runtime = main.get("voxel_terrain_runtime")
    var controller = main.get("visible_world_demand_controller")
    var requests: Dictionary = main.get("streaming_requests")
    var full: Dictionary = controller.call("full_view_readiness", "player",
        int(requests.get("player", 0)), String(main.get("seed_text")),
        String(runtime.call("visible_mesh_world_revision"))) \
        if is_instance_valid(controller) and is_instance_valid(runtime) else {}
    var pending_representations: Array = controller.call("pending_representation_diagnostics",
        "player", int(requests.get("player", 0)), String(main.get("seed_text")),
        String(runtime.call("visible_mesh_world_revision")), 6) \
        if is_instance_valid(controller) and is_instance_valid(runtime) \
        and int(full.get("pendingCount", 0)) > 0 else []
    var advance: Dictionary = main.get("visible_world_demand_last_advance")
    var view_center: Vector2 = main.get("visible_world_view_center_cells")
    var observer_cell := Vector2(player_body.global_position.x / 1.35,
        player_body.global_position.z / 1.35)
    var center_lag := observer_cell.distance_to(view_center)
    var row := {"label": label, "processFrame": Engine.get_process_frames(),
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
        "pendingRepresentations": pending_representations,
        "queue": full.get("queue", {}), "coverageLag": full.get("coverageLag", 0.0),
        "observerCell": [observer_cell.x, observer_cell.y],
        "viewCenterCells": [view_center.x, view_center.y],
        "liveCenterLagCells": center_lag,
        "demandAdvance": {"status": advance.get("status", ""),
            "reason": advance.get("reason", ""), "queueDepth": advance.get("queueDepth", 0),
            "terrainAdvanceUsec": advance.get("terrainAdvanceUsec", 0),
            "propAdvanceUsec": advance.get("propAdvanceUsec", 0),
            "structureAdvanceUsec": advance.get("structureAdvanceUsec", 0),
            "coverageAdvanceUsec": advance.get("coverageAdvanceUsec", 0),
            "advanceTotalUsec": advance.get("advanceTotalUsec", 0)}}
    row["viewDemand"] = _view_demand_diagnostics(controller)
    if not data_prefetch_probe_mode.is_empty() and label == "sprint":
        row["dataPrefetch"] = _data_prefetch_snapshot(label, false)
    return row


func _terrain_manifest_step_timing() -> Dictionary:
    return _timing_summary(terrain_manifest_step_usec)


func _timing_summary(durations: Array[int]) -> Dictionary:
    if durations.is_empty(): return {"samples": 0}
    var sorted := durations.duplicate()
    sorted.sort()
    var total := 0
    for duration: int in sorted: total += duration
    return {"samples": sorted.size(), "p50Usec": sorted[sorted.size() / 2],
        "p95Usec": sorted[mini(sorted.size() - 1, ceili(float(sorted.size()) * 0.95) - 1)],
        "maxUsec": sorted.back(), "totalUsec": total}


func _view_demand_diagnostics(controller: Object) -> Dictionary:
    if not is_instance_valid(controller): return {}
    var owners_value = controller.get("_owners")
    if not owners_value is Dictionary: return {}
    var state: Dictionary = owners_value.get("player", {})
    var result := {}
    for role in ["current", "pending"]:
        var view: Dictionary = state.get(role, {})
        if view.is_empty(): continue
        var center: Vector2 = view.get("center", Vector2.INF)
        var terrain: Dictionary = view.get("terrainState", {})
        var chunk_keys: Array = view.get("chunkKeys", [])
        var prop_sources: Dictionary = view.get("propSources", {})
        var structure_sources: Dictionary = view.get("structureSources", {})
        result[role] = {"centerCells": [center.x, center.y],
            "centerWorld": vec3(view.get("centerWorld", Vector3.ZERO)),
            "demandRevision": int(view.get("demandRevision", 0)),
            "publicationComplete": bool(view.get("publicationComplete", false)),
            "terrainRequiredBlocks": int(terrain.get("requiredBlocks", 0)),
            "terrainProcessedBlocks": int(terrain.get("processedBlocks", 0)),
            "terrainPendingBlocks": int(terrain.get("pendingBlocks", 0)),
            "terrainReason": String(terrain.get("reason", "")),
            "chunkSourcesExpected": chunk_keys.size(),
            "propSourcesComplete": prop_sources.size(),
            "structureSourcesComplete": structure_sources.size(),
            "missingChunkSourceCount": (view.get("missingChunkSources", {}) as Dictionary).size(),
            "lastPropReason": String((view.get("lastProp", {}) as Dictionary).get("reason", "")),
            "lastStructureReason": String((view.get("lastStructure", {}) as Dictionary).get("reason", ""))}
    return result


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
