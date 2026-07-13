extends Node

const MAIN_SCENE := preload("res://scenes/Main.tscn")
const RuntimePerformanceObservationRunnerScript := preload("res://scripts/testing/RuntimePerformanceObservationRunner.gd")

const SAMPLE_EVERY_FRAMES := 6
const DEFAULT_DURATION_SECONDS := 75.0
const DEFAULT_WARMUP_FRAMES := 120
const SEGMENT_SECONDS := 8.0
const SEGMENT_PAUSE_SECONDS := 0.65
const SEGMENT_LANE_CHECK_CELLS := 48
const JUMP_INTERVAL_FRAMES := 150
const MIN_RUNTIME_TRAVEL_DISTANCE := 45.0
const MAX_ALLOWED_BELOW_COLLISION := 1.35

var report_path := ""
var progress_path := ""
var screenshot_path := ""
var run_token := ""
var duration_seconds := DEFAULT_DURATION_SECONDS
var watchdog_seconds := 240.0
var warmup_frames := DEFAULT_WARMUP_FRAMES
var scenario := "NormalSprintTraversal"
var main: Node = null
var finished := false
var watchdog_elapsed := 0.0
var boot_add_child_ms := 0.0
var boot_first_frames_ms := 0.0
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
    OS.set_environment("VOXEL_PLAYTEST", "")
    OS.set_environment("VOXEL_RUNTIME_PERF_FAST_BOOT", "")
    OS.set_environment("VOXEL_UNDERGROUND_VISUAL_FAST_BOOT", "")
    OS.set_environment("VOXEL_DIGGING_VISUAL_FAST_BOOT", "")
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
    write_progress("instantiate_main")
    main = MAIN_SCENE.instantiate()
    var add_child_started := Time.get_ticks_usec()
    add_child(main)
    boot_add_child_ms = elapsed_ms(add_child_started)
    write_progress("main_added")
    var first_frames_started := Time.get_ticks_usec()
    await get_tree().process_frame
    await get_tree().physics_frame
    boot_first_frames_ms = elapsed_ms(first_frames_started)
    write_progress("main_first_frames")
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

func flush_async_save() -> void:
    if main == null:
        return
    var save_system = main.get("save_system")
    if save_system != null and save_system.has_method("poll_async_save"):
        save_system.call("poll_async_save", true)

func append_normal_metrics(metrics: Dictionary, frame_count: int) -> void:
    metrics["bootAddChildMs"] = boot_add_child_ms
    metrics["bootFirstFramesMs"] = boot_first_frames_ms
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
    if measurement_start == Vector3.INF or measurement_end == Vector3.INF:
        metrics["playerTravelDistance"] = 0.0
        return
    var delta := measurement_end - measurement_start
    delta.y = 0.0
    metrics["playerTravelDistance"] = accumulated_travel_distance
    metrics["playerDisplacementDistance"] = delta.length()
    metrics["playerStart"] = vec3(measurement_start)
    metrics["playerEnd"] = vec3(measurement_end)

func result_details(metrics: Dictionary, failures: Array) -> String:
    return "samples=%d p99=%.2f max=%.2f chunkMax=%.2f npcMax=%.2f saveMax=%.2f travel=%.2f turns=%d jumps=%d/%d bootAddChild=%.2f failures=%d" % [
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
        float(metrics.get("bootAddChildMs", 0.0)),
        failures.size()
    ]

func normal_runtime_controls() -> Dictionary:
    return {
        "voxelPlaytest": OS.get_environment("VOXEL_PLAYTEST").strip_edges(),
        "runtimePerfFastBoot": OS.get_environment("VOXEL_RUNTIME_PERF_FAST_BOOT").strip_edges(),
        "fixedFps": false,
        "autosaveExpectedEnabled": true,
        "savePathOverride": OS.get_environment("VOXEL_SAVE_PATH_OVERRIDE").strip_edges(),
        "requestedTestSeed": OS.get_environment("VOXEL_TEST_SEED").strip_edges(),
        "deterministicSeedSequence": OS.get_environment("VOXEL_NORMAL_RUNTIME_PERF_RUN_TOKEN").strip_edges() != "",
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
            "bootAddChildMs": boot_add_child_ms,
            "bootFirstFramesMs": boot_first_frames_ms
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
    if main != null and is_instance_valid(main):
        main.queue_free()
    call_deferred("_quit_deferred", code)

func _quit_deferred(code: int) -> void:
    get_tree().quit(code)

func elapsed_ms(start_usec: int) -> float:
    return float(Time.get_ticks_usec() - start_usec) / 1000.0

func vec3(value: Vector3) -> Array:
    return [value.x, value.y, value.z]
