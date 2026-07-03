extends Node

const MAIN_SCENE := preload("res://scenes/Main.tscn")
const DEFAULT_SCENARIOS := ["DayWork", "DuskReturnHome", "MidnightTown", "CrowdedDoorTraffic", "SprintTraversal", "AutosaveEnabled", "AutosaveDisabled"]
const TARGET_NPC_COUNT := 32
const SAMPLE_EVERY_FRAMES := 6
const SPRINT_TRAVERSAL_DIRECTION := Vector3(1.0, 0.0, 0.0)
const SPRINT_TRAVERSAL_CELL_DIRECTION := Vector2i(1, 0)

var scenario := "All"
var seed := "atlas-1492"
var report_path := ""
var progress_path := ""
var run_token := ""
var duration_seconds := 60.0
var watchdog_seconds := 300.0
var elapsed := 0.0
var finished := false
var main: Node = null
var measured_player_start := Vector3.INF
var measured_player_end := Vector3.INF

func _ready() -> void:
    configure_from_environment()
    write_progress("start")
    call_deferred("run")

func _process(delta: float) -> void:
    if finished:
        return
    elapsed += delta
    if elapsed > watchdog_seconds:
        write_report(make_failure_report("runtime performance watchdog exceeded %.1fs" % watchdog_seconds))
        finish(1)

func configure_from_environment() -> void:
    scenario = OS.get_environment("VOXEL_RUNTIME_PERF_SCENARIO")
    if scenario == "":
        scenario = "All"
    seed = OS.get_environment("VOXEL_TEST_SEED")
    if seed == "":
        seed = "atlas-1492"
    report_path = OS.get_environment("VOXEL_RUNTIME_PERF_REPORT")
    if report_path == "":
        report_path = "user://runtime-performance-observation.json"
    progress_path = OS.get_environment("VOXEL_RUNTIME_PERF_PROGRESS")
    run_token = OS.get_environment("VOXEL_RUNTIME_PERF_RUN_TOKEN")
    var duration_value := OS.get_environment("VOXEL_RUNTIME_PERF_DURATION_SECONDS")
    if duration_value != "":
        duration_seconds = maxf(1.0, float(duration_value))
    var watchdog_value := OS.get_environment("VOXEL_RUNTIME_PERF_WATCHDOG_SECONDS")
    var requested_watchdog := watchdog_seconds
    if watchdog_value != "":
        requested_watchdog = float(watchdog_value)
    watchdog_seconds = maxf(minimum_watchdog_seconds(), requested_watchdog)

func minimum_watchdog_seconds() -> float:
    return duration_seconds * float(scenarios_to_run().size()) + 30.0

func run() -> void:
    var started_utc := Time.get_datetime_string_from_system(true)
    var results := []
    var failure_count := 0
    for scenario_name in scenarios_to_run():
        write_progress("scenario:%s" % scenario_name)
        var result: Dictionary = await run_scenario(scenario_name)
        results.append(result)
        if not bool(result.get("passed", false)):
            failure_count += 1
    var report := {
        "schemaVersion": 1,
        "suite": "runtime_performance_observation",
        "scenario": scenario,
        "seed": seed,
        "runToken": run_token,
        "durationSecondsPerScenario": duration_seconds,
        "startedUtc": started_utc,
        "finishedUtc": Time.get_datetime_string_from_system(true),
        "resultCount": results.size(),
        "failureCount": failure_count,
        "results": results,
        "metrics": summarize_results(results),
        "artifacts": {
            "report": report_path,
            "progress": progress_path
        }
    }
    write_report(report)
    finish(1 if failure_count > 0 else 0)

func scenarios_to_run() -> Array:
    if scenario == "All":
        return DEFAULT_SCENARIOS.duplicate()
    return [scenario]

func run_scenario(scenario_name: String) -> Dictionary:
    main = MAIN_SCENE.instantiate()
    add_child(main)
    await get_tree().process_frame
    await get_tree().physics_frame
    configure_main_for_scenario(scenario_name)
    var warmup_count := 90
    if scenario_name == "CrowdedDoorTraffic":
        warmup_count = 240
    elif scenario_name == "SprintTraversal":
        warmup_count = 120
    await warmup_frames(warmup_count)
    prime_navigation_snapshot()
    reset_performance_monitor()
    measured_player_start = measured_player_position()
    var samples := []
    var frame_count := maxi(1, roundi(duration_seconds * 60.0))
    for frame in range(frame_count):
        update_scenario_frame(scenario_name, frame)
        await get_tree().process_frame
        if frame % SAMPLE_EVERY_FRAMES == 0 and main != null and main.has_method("debug_performance_state"):
            samples.append(main.debug_performance_state())
    measured_player_end = measured_player_position()
    var metrics := summarize_samples(samples)
    append_scenario_metrics(metrics, scenario_name)
    var failures: Array[String] = performance_failures(metrics)
    var passed := not samples.is_empty() and failures.is_empty()
    var details := "samples=%d p99=%.2f max=%.2f chunkMax=%.2f npcMax=%.2f routeMax=%.2f navMax=%.2f jobMax=%.2f saveMax=%.2f navmeshInstallP95=%dus navmeshQueryP95=%dus" % [
        samples.size(),
        float(metrics.get("frameP99Ms", 0.0)),
        float(metrics.get("frameMaxMs", 0.0)),
        float(metrics.get("maxChunkMs", 0.0)),
        float(metrics.get("maxNpcMs", 0.0)),
        float(metrics.get("maxRoutePlanMs", 0.0)),
        float(metrics.get("maxNavSnapshotMs", 0.0)),
        float(metrics.get("maxJobScanMs", 0.0)),
        float(metrics.get("maxAutosaveMs", 0.0)),
        int(metrics.get("maxNavmeshInstallP95Usec", 0)),
        int(metrics.get("maxNavmeshPathQueryP95Usec", 0))
    ]
    if main != null:
        main.queue_free()
        main = null
        await get_tree().process_frame
    return {
        "id": "runtime_perf_%s" % scenario_name.to_lower(),
        "scenario": scenario_name,
        "seed": seed,
        "passed": passed,
        "durationSeconds": duration_seconds,
        "details": details,
        "metrics": metrics,
        "failures": failures,
        "sampleCount": samples.size()
    }

func configure_main_for_scenario(scenario_name: String) -> void:
    if main == null:
        return
    if main.get("tutorial_system") != null:
        var tutorial = main.get("tutorial_system")
        tutorial.set("intro_repair_active", false)
        tutorial.set("intro_bed_used", true)
        tutorial.set("final_night_active", false)
        tutorial.set("final_night_complete", true)
    if scenario_name == "DuskReturnHome":
        main.set("time_of_day", 0.52)
    elif scenario_name == "MidnightTown":
        main.set("time_of_day", 0.75)
    else:
        main.set("time_of_day", 0.25)
    main.set("autosave_enabled", scenario_name != "AutosaveDisabled")
    main.set("autosave_interval_seconds", 60.0)
    if scenario_name == "AutosaveEnabled" and main.has_method("mark_world_dirty"):
        main.set("autosave_elapsed", 59.5)
        main.mark_world_dirty("performance_observation")
    if main.get("player") != null:
        main.get("player").set("automated_input", true)
        main.get("player").set("automated_sprint", false)
        main.get("player").set("automated_move", Vector3.ZERO)
    force_npc_count(TARGET_NPC_COUNT)
    if scenario_name == "CrowdedDoorTraffic":
        setup_crowded_door_traffic()
    elif scenario_name == "SprintTraversal":
        setup_sprint_traversal()

func setup_sprint_traversal() -> void:
    if main == null:
        return
    var player_body := main.get("player") as CharacterBody3D
    if player_body == null:
        return
    var start_cell := sprint_traversal_start_cell()
    var start_y := float(main.call("surface_y_at_cell", Vector3i(start_cell.x, 0, start_cell.y))) + 0.08
    player_body.global_position = Vector3(float(start_cell.x) * 1.35, start_y, float(start_cell.y) * 1.35)
    player_body.velocity = Vector3.ZERO
    player_body.set("automated_input", true)
    player_body.set("automated_sprint", true)
    player_body.set("automated_move", SPRINT_TRAVERSAL_DIRECTION)
    if main.has_method("update_chunks"):
        main.call("update_chunks", true)

func sprint_traversal_start_cell() -> Vector2i:
    var player_body := main.get("player") as Node3D
    var origin := player_body.global_position if player_body != null else Vector3.ZERO
    var origin_cell := Vector2i(int(main.call("world_to_cell", origin.x)), int(main.call("world_to_cell", origin.z)))
    var offsets: Array[Vector2i] = [
        Vector2i(96, 24),
        Vector2i(128, -32),
        Vector2i(160, 48),
        Vector2i(192, -64),
        Vector2i(224, 80),
        Vector2i(256, -96)
    ]
    for offset in offsets:
        var candidate: Vector2i = origin_cell + offset
        if sprint_traversal_lane_ok(candidate):
            return candidate
    return origin_cell + offsets[0]

func sprint_traversal_lane_ok(start_cell: Vector2i) -> bool:
    var previous_height: float = INF
    for step in range(48):
        var cell: Vector2i = start_cell + SPRINT_TRAVERSAL_CELL_DIRECTION * step
        var height := float(main.call("surface_y_at_cell", Vector3i(cell.x, 0, cell.y)))
        if height < 1.35 * 3.0 or height > 92.0:
            return false
        var biome := String(main.call("surface_biome_at_cell", Vector3i(cell.x, 0, cell.y)))
        if biome in ["ocean", "beach", "town"]:
            return false
        if previous_height != INF and absf(height - previous_height) > 1.35 * 1.15:
            return false
        previous_height = height
    return true

func update_scenario_frame(scenario_name: String, _frame: int) -> void:
    if scenario_name != "SprintTraversal" or main == null:
        return
    var player_body := main.get("player") as CharacterBody3D
    if player_body == null:
        return
    player_body.set("automated_input", true)
    player_body.set("automated_sprint", true)
    player_body.set("automated_move", SPRINT_TRAVERSAL_DIRECTION)

func measured_player_position() -> Vector3:
    if main == null:
        return Vector3.INF
    var player_body := main.get("player") as Node3D
    if player_body == null:
        return Vector3.INF
    return player_body.global_position

func append_scenario_metrics(metrics: Dictionary, scenario_name: String) -> void:
    if scenario_name != "SprintTraversal":
        return
    if measured_player_start == Vector3.INF or measured_player_end == Vector3.INF:
        metrics["playerTravelDistance"] = 0.0
        return
    var delta := measured_player_end - measured_player_start
    delta.y = 0.0
    metrics["playerTravelDistance"] = delta.length()
    metrics["playerStart"] = [measured_player_start.x, measured_player_start.y, measured_player_start.z]
    metrics["playerEnd"] = [measured_player_end.x, measured_player_end.y, measured_player_end.z]

func setup_crowded_door_traffic() -> void:
    if main == null:
        return
    var npc_system = main.get("npc_system")
    var player_body := main.get("player") as Node3D
    if npc_system == null or player_body == null:
        return
    var center := Vector2i(main.call("world_to_cell", player_body.global_position.x), main.call("world_to_cell", player_body.global_position.z)) + Vector2i(22, 0)
    var base_height: float = main.call("surface_y_at_cell", Vector3i(center.x, 0, center.y))
    var wall_y := base_height + 1.35 * 0.48
    var wall_cell_y := floori(wall_y / 1.35) + 1
    var door_cell := Vector3i(center.x, wall_cell_y, center.y)
    for dz in range(-4, 5):
        var cell := Vector3i(center.x, wall_cell_y, center.y + dz)
        main.call("create_block", cell, "door" if cell == door_cell else "stoneBlock", { "world_y": wall_y })
    var entries: Array = npc_system.get("npcs")
    for i in range(entries.size()):
        var entry: Dictionary = entries[i]
        var body := entry.get("body") as CharacterBody3D
        if body == null or not is_instance_valid(body):
            continue
        var side := -1 if i % 2 == 0 else 1
        var lane := int(i / 2) % 8 - 4
        var start_cell := center + Vector2i(side * 6, lane)
        var target_cell := center + Vector2i(-side * 6, -lane)
        var start_position := Vector3(float(start_cell.x) * 1.35, float(main.call("surface_y_at_cell", Vector3i(start_cell.x, 0, start_cell.y))) + 0.04, float(start_cell.y) * 1.35)
        var target_position := Vector3(float(target_cell.x) * 1.35, float(main.call("surface_y_at_cell", Vector3i(target_cell.x, 0, target_cell.y))) + 0.04, float(target_cell.y) * 1.35)
        npc_system.safe_place_npc(body, start_position, entry.get("motorProfile"), "runtime_perf_crowded_door")
        entry["townCenter"] = center
        entry["townRadius"] = 30
        entry["homeCell"] = start_cell
        entry["porchCell"] = start_cell
        entry["guardCell"] = center + Vector2i(0, lane)
        if npc_system.has_method("set_scripted_target"):
            npc_system.set_scripted_target(body, target_position, true, true)

func force_npc_count(target_count: int) -> void:
    var npc_system = main.get("npc_system") if main != null else null
    if npc_system == null:
        return
    if npc_system.has_method("spawn_generic_town_npcs"):
        npc_system.spawn_generic_town_npcs()
    var entries: Array = npc_system.get("npcs")
    if entries.size() >= target_count:
        return
    var player_body := main.get("player") as Node3D
    var origin := player_body.global_position if player_body != null else Vector3.ZERO
    var center := Vector2i(main.call("world_to_cell", origin.x), main.call("world_to_cell", origin.z))
    var level := float(main.call("surface_y_at_position", origin))
    var start_index := entries.size()
    for i in range(start_index, target_count):
        var offset := Vector2i((i % 8) * 2 - 8, int(i / 8) * 2 + 6)
        var home_cell := center + offset
        var record := {
            "id": "perf_npc_%02d" % i,
            "townKey": "runtime_perf",
            "townCenter": center,
            "townRadius": 24,
            "level": level,
            "homeCell": home_cell,
            "porchCell": home_cell + Vector2i(0, 1),
            "interiorMinCell": home_cell + Vector2i(-1, -1),
            "interiorMaxCell": home_cell + Vector2i(1, 1),
            "guardCell": center + Vector2i(i % 6 - 3, -6)
        }
        npc_system.spawn_town_npc(record, i)

func warmup_frames(count: int) -> void:
    for _i in range(count):
        await get_tree().process_frame

func prime_navigation_snapshot() -> void:
    if main == null:
        return
    var npc_system = main.get("npc_system")
    if npc_system == null:
        return
    var entries: Array = npc_system.get("npcs")
    if entries.is_empty():
        return
    var pathing = npc_system.get("pathing")
    var world = pathing.get("navigation_world") if pathing != null else null
    if world != null and world.has_method("build_snapshot"):
        world.build_snapshot(entries[0], true, false)

func reset_performance_monitor() -> void:
    if main == null:
        return
    var monitor = main.get("runtime_perf_monitor")
    if monitor != null and monitor.has_method("reset"):
        monitor.reset()
    var npc_system = main.get("npc_system")
    var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
    var navmesh_world = autonomy.get("navmesh_world") if autonomy != null else null
    if navmesh_world != null and navmesh_world.has_method("reset_timing_stats"):
        navmesh_world.reset_timing_stats()

func summarize_samples(samples: Array) -> Dictionary:
    var frames := []
    var rolling_frame_max := 0.0
    var max_npc := 0.0
    var max_route := 0.0
    var max_route_request := 0.0
    var max_route_search := 0.0
    var max_route_record := 0.0
    var max_route_convert := 0.0
    var max_chunk := 0.0
    var max_chunk_create := 0.0
    var max_chunk_build_mesh := 0.0
    var max_chunk_trimesh := 0.0
    var max_chunk_spawn_props := 0.0
    var chunks_created := 0
    var chunk_asset_cache_misses := 0
    var max_runtime_graph := 0.0
    var max_runtime_graph_snapshot := 0.0
    var max_runtime_graph_targets := 0.0
    var max_runtime_graph_candidates := 0.0
    var max_runtime_graph_continue := 0.0
    var max_runtime_graph_sync_nodes := 0.0
    var max_runtime_graph_sync_edges := 0.0
    var max_nav := 0.0
    var max_job := 0.0
    var max_save := 0.0
    var static_rebuild_count := 0
    var dynamic_update_count := 0
    var route_jobs_completed := 0
    var route_jobs_pending := 0
    var autosave_completed := 0
    var autosave_pending := false
    var max_autosave_read_parse := 0.0
    var max_autosave_stringify_write := 0.0
    var job_scan_nodes := 0
    var forage_scan_nodes := 0
    var indexed_resource_queries := 0
    var max_navmesh_install_usec := 0
    var max_navmesh_install_p95_usec := 0
    var max_navmesh_path_query_usec := 0
    var max_navmesh_path_query_p95_usec := 0
    var max_navmesh_path_query_failures := 0
    var slowest_navmesh_path_query := {}
    var section_maxima := {}
    var last_spike := {}
    for sample_value in samples:
        var sample: Dictionary = sample_value
        frames.append(float(sample.get("frameMs", 0.0)))
        rolling_frame_max = maxf(rolling_frame_max, float(sample.get("frameMaxMs", 0.0)))
        max_npc = maxf(max_npc, float(sample.get("npcMs", 0.0)))
        var section_max: Dictionary = sample.get("perfSectionMaxMs", {}) if sample.get("perfSectionMaxMs", {}) is Dictionary else {}
        for section_name in section_max.keys():
            section_maxima[String(section_name)] = maxf(float(section_maxima.get(String(section_name), 0.0)), float(section_max.get(section_name, 0.0)))
        max_route = maxf(max_route, maxf(float(sample.get("routePlanMs", 0.0)), float(section_max.get("route_planning", 0.0))))
        max_route_request = maxf(max_route_request, float(section_max.get("route_runtime_request", 0.0)))
        max_route_search = maxf(max_route_search, float(section_max.get("route_search_step", 0.0)))
        max_route_record = maxf(max_route_record, float(section_max.get("route_record_result", 0.0)))
        max_route_convert = maxf(max_route_convert, float(section_max.get("route_result_convert", 0.0)))
        max_chunk = maxf(max_chunk, maxf(float(sample.get("chunkMs", 0.0)), float(section_max.get("chunk", 0.0))))
        max_chunk_create = maxf(max_chunk_create, float(section_max.get("chunk_create", 0.0)))
        max_chunk_build_mesh = maxf(max_chunk_build_mesh, float(section_max.get("chunk_build_mesh", 0.0)))
        max_chunk_trimesh = maxf(max_chunk_trimesh, float(section_max.get("chunk_create_trimesh_shape", 0.0)))
        max_chunk_spawn_props = maxf(max_chunk_spawn_props, float(section_max.get("chunk_spawn_props", 0.0)))
        max_runtime_graph = maxf(max_runtime_graph, float(section_max.get("runtime_graph_build", 0.0)))
        max_runtime_graph_snapshot = maxf(max_runtime_graph_snapshot, float(section_max.get("runtime_graph_snapshot", 0.0)))
        max_runtime_graph_targets = maxf(max_runtime_graph_targets, float(section_max.get("runtime_graph_targets", 0.0)))
        max_runtime_graph_candidates = maxf(max_runtime_graph_candidates, float(section_max.get("runtime_graph_candidates", 0.0)))
        max_runtime_graph_continue = maxf(max_runtime_graph_continue, float(section_max.get("runtime_graph_continue", 0.0)))
        max_runtime_graph_sync_nodes = maxf(max_runtime_graph_sync_nodes, float(section_max.get("runtime_graph_sync_nodes", 0.0)))
        max_runtime_graph_sync_edges = maxf(max_runtime_graph_sync_edges, float(section_max.get("runtime_graph_sync_edges", 0.0)))
        max_nav = maxf(max_nav, maxf(float(sample.get("navSnapshotMs", 0.0)), float(section_max.get("navigation_snapshot_rebuild", 0.0))))
        max_job = maxf(max_job, maxf(float(sample.get("jobScanMs", 0.0)), float(section_max.get("job_forage_scan", 0.0))))
        max_save = maxf(max_save, maxf(float(sample.get("autosaveMs", 0.0)), float(section_max.get("autosave_snapshot", 0.0))))
        var counters: Dictionary = sample.get("perfCounters", {})
        static_rebuild_count = max(static_rebuild_count, int(counters.get("nav_static_rebuild_count", static_rebuild_count)))
        dynamic_update_count = max(dynamic_update_count, int(counters.get("nav_dynamic_update_count", dynamic_update_count)))
        var autosave_stats: Dictionary = sample.get("autosaveStats", {})
        max_autosave_read_parse = maxf(max_autosave_read_parse, float(autosave_stats.get("lastReadParseMs", 0.0)))
        max_autosave_stringify_write = maxf(max_autosave_stringify_write, maxf(
            float(autosave_stats.get("lastStringifyWriteMs", 0.0)),
            float(section_max.get("autosave_json_stringify_write", 0.0))
        ))
        autosave_completed = max(autosave_completed, int(autosave_stats.get("asyncCompleted", autosave_completed)))
        autosave_pending = autosave_pending or bool(autosave_stats.get("asyncPending", false))
        chunks_created = max(chunks_created, int(counters.get("chunks_created", chunks_created)))
        chunk_asset_cache_misses = max(chunk_asset_cache_misses, int(counters.get("chunk_asset_cache_misses", chunk_asset_cache_misses)))
        route_jobs_completed = max(route_jobs_completed, int(counters.get("route_jobs_completed", route_jobs_completed)))
        route_jobs_pending = max(route_jobs_pending, int(counters.get("route_jobs_pending", route_jobs_pending)))
        job_scan_nodes = max(job_scan_nodes, int(counters.get("job_scan_nodes", job_scan_nodes)))
        forage_scan_nodes = max(forage_scan_nodes, int(counters.get("forage_scan_nodes", forage_scan_nodes)))
        indexed_resource_queries = max(indexed_resource_queries, int(counters.get("indexed_resource_queries", indexed_resource_queries)))
        var navmesh_stats: Dictionary = sample.get("navmeshWorld", {}) if sample.get("navmeshWorld", {}) is Dictionary else {}
        max_navmesh_install_usec = max(max_navmesh_install_usec, int(navmesh_stats.get("lastInstallUsec", 0)))
        max_navmesh_install_p95_usec = max(max_navmesh_install_p95_usec, int(navmesh_stats.get("installP95Usec", 0)))
        var sample_navmesh_path_query_usec := int(navmesh_stats.get("maxPathQueryUsec", 0))
        if sample_navmesh_path_query_usec >= max_navmesh_path_query_usec:
            slowest_navmesh_path_query = navmesh_stats.get("slowestPathQuery", {}) if navmesh_stats.get("slowestPathQuery", {}) is Dictionary else {}
        max_navmesh_path_query_usec = max(max_navmesh_path_query_usec, sample_navmesh_path_query_usec)
        max_navmesh_path_query_p95_usec = max(max_navmesh_path_query_p95_usec, int(navmesh_stats.get("pathQueryP95Usec", 0)))
        max_navmesh_path_query_failures = max(max_navmesh_path_query_failures, int(navmesh_stats.get("pathQueryFailureCount", 0)))
        if float(sample.get("lastSpikeFrameMs", 0.0)) >= float(last_spike.get("frameMs", 0.0)):
            last_spike = {
                "frameMs": float(sample.get("lastSpikeFrameMs", 0.0)),
                "reason": String(sample.get("lastSpikeReason", "")),
                "topSections": sample.get("lastSpikeTopSections", [])
            }
    return {
        "frameP50Ms": percentile(frames, 0.50),
        "frameP95Ms": percentile(frames, 0.95),
        "frameP99Ms": percentile(frames, 0.99),
        "frameMaxMs": maxf(max_value(frames), rolling_frame_max),
        "maxUpdateNpcsMs": max_npc,
        "maxNpcMs": max_npc,
        "maxRoutePlanMs": max_route,
        "maxRouteRequestMs": max_route_request,
        "maxRouteSearchMs": max_route_search,
        "maxRouteRecordMs": max_route_record,
        "maxRouteConvertMs": max_route_convert,
        "maxChunkMs": max_chunk,
        "maxChunkCreateMs": max_chunk_create,
        "maxChunkBuildMeshMs": max_chunk_build_mesh,
        "maxChunkCreateTrimeshShapeMs": max_chunk_trimesh,
        "maxChunkSpawnPropsMs": max_chunk_spawn_props,
        "chunksCreated": chunks_created,
        "chunkAssetCacheMisses": chunk_asset_cache_misses,
        "maxRuntimeGraphBuildMs": max_runtime_graph,
        "maxRuntimeGraphSnapshotMs": max_runtime_graph_snapshot,
        "maxRuntimeGraphTargetsMs": max_runtime_graph_targets,
        "maxRuntimeGraphCandidatesMs": max_runtime_graph_candidates,
        "maxRuntimeGraphContinueMs": max_runtime_graph_continue,
        "maxRuntimeGraphSyncNodesMs": max_runtime_graph_sync_nodes,
        "maxRuntimeGraphSyncEdgesMs": max_runtime_graph_sync_edges,
        "maxNavSnapshotMs": max_nav,
        "maxJobScanMs": max_job,
        "maxAutosaveMs": max_save,
        "maxAutosaveJsonReadParseMs": max_autosave_read_parse,
        "maxAutosaveJsonStringifyWriteMs": max_autosave_stringify_write,
        "navStaticRebuildCount": static_rebuild_count,
        "navDynamicUpdateCount": dynamic_update_count,
        "routeJobsCompleted": route_jobs_completed,
        "routeJobsPending": route_jobs_pending,
        "autosaveJobsCompleted": autosave_completed,
        "autosaveJobsPending": autosave_pending,
        "jobScanNodes": job_scan_nodes,
        "forageScanNodes": forage_scan_nodes,
        "indexedResourceQueries": indexed_resource_queries,
        "maxNavmeshInstallUsec": max_navmesh_install_usec,
        "maxNavmeshInstallP95Usec": max_navmesh_install_p95_usec,
        "maxNavmeshPathQueryUsec": max_navmesh_path_query_usec,
        "maxNavmeshPathQueryP95Usec": max_navmesh_path_query_p95_usec,
        "maxNavmeshPathQueryFailures": max_navmesh_path_query_failures,
        "slowestNavmeshPathQuery": slowest_navmesh_path_query,
        "topSectionMaxMs": top_section_maxima(section_maxima, 20),
        "lastSpike": last_spike
    }

func top_section_maxima(section_maxima: Dictionary, limit: int) -> Array:
    var rows := []
    for section_name in section_maxima.keys():
        rows.append({
            "name": String(section_name),
            "ms": float(section_maxima.get(section_name, 0.0))
        })
    rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
        return float(a.get("ms", 0.0)) > float(b.get("ms", 0.0))
    )
    if rows.size() > limit:
        rows.resize(limit)
    return rows

func performance_failures(metrics: Dictionary) -> Array[String]:
    var failures: Array[String] = []
    if float(metrics.get("frameP99Ms", 0.0)) > 22.0:
        failures.append("p99 frame time exceeds 22ms tolerated threshold")
    if float(metrics.get("frameMaxMs", 0.0)) > 33.0:
        failures.append("max frame time exceeds 33ms threshold")
    if float(metrics.get("maxRoutePlanMs", 0.0)) > 2.0:
        failures.append("route planning exceeded 2ms frame budget")
    if float(metrics.get("maxNavSnapshotMs", 0.0)) > 2.0:
        failures.append("navigation snapshot rebuild exceeded 2ms frame budget")
    if float(metrics.get("maxJobScanMs", 0.0)) > 2.0:
        failures.append("job scan exceeded 2ms frame budget")
    if float(metrics.get("maxAutosaveMs", 0.0)) > 2.0:
        failures.append("autosave exceeded 2ms main-thread budget")
    if int(metrics.get("jobScanNodes", 0)) > 0 or int(metrics.get("forageScanNodes", 0)) > 0:
        failures.append("job/forage target selection used recursive scan nodes")
    if int(metrics.get("maxNavmeshInstallP95Usec", 0)) > 4000:
        failures.append("navmesh install p95 exceeded 4ms budget")
    if int(metrics.get("maxNavmeshPathQueryP95Usec", 0)) > 1000:
        failures.append("navmesh path query p95 exceeded 1ms budget")
    return failures

func summarize_results(results: Array) -> Dictionary:
    var worst := {}
    for result_value in results:
        var result: Dictionary = result_value
        var metrics: Dictionary = result.get("metrics", {})
        var worst_metrics: Dictionary = worst.get("metrics", {}) if worst.get("metrics", {}) is Dictionary else {}
        if float(metrics.get("frameMaxMs", 0.0)) > float(worst_metrics.get("frameMaxMs", 0.0)):
            worst = result
    return {
        "scenarioCount": results.size(),
        "worstScenario": String(worst.get("scenario", "")),
        "worstMetrics": worst.get("metrics", {})
    }

func percentile(values: Array, ratio: float) -> float:
    if values.is_empty():
        return 0.0
    var sorted := values.duplicate()
    sorted.sort()
    var index := clampi(ceili(float(sorted.size()) * ratio) - 1, 0, sorted.size() - 1)
    return float(sorted[index])

func max_value(values: Array) -> float:
    var result := 0.0
    for value in values:
        result = maxf(result, float(value))
    return result

func write_progress(label: String) -> void:
    if progress_path == "":
        return
    var file := FileAccess.open(progress_path, FileAccess.WRITE)
    if file == null:
        return
    file.store_string("%s\n" % label)
    file.close()

func write_report(report: Dictionary) -> void:
    var file := FileAccess.open(report_path, FileAccess.WRITE)
    if file == null:
        push_error("Unable to write runtime performance report: %s" % report_path)
        return
    file.store_string(JSON.stringify(report, "  "))
    file.close()

func make_failure_report(reason: String) -> Dictionary:
    return {
        "schemaVersion": 1,
        "suite": "runtime_performance_observation",
        "scenario": scenario,
        "seed": seed,
        "runToken": run_token,
        "resultCount": 1,
        "failureCount": 1,
        "results": [{
            "id": "runtime_perf_failure",
            "scenario": scenario,
            "passed": false,
            "details": reason
        }]
    }

func finish(code: int) -> void:
    finished = true
    write_progress("finished")
    get_tree().quit(code)
