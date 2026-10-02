extends "res://scripts/testing/NormalRuntimePerformancePassRunner.gd"

const MAIN_SCENE := preload("res://scenes/Main.tscn")
const CHUNK_PROP_PRIORITY := preload("res://scripts/world/ChunkPropSpawnPriority.gd")
const RUN_SECONDS := 4.5
const TURN_RADIANS := PI * 0.85
const MIN_NEW_AREA_DISTANCE := 45.0
const DATA_PREFETCH_DISTANCE := 112
const MESH_PREP_DISTANCE := 32
const MESH_PREP_LEAD_DISTANCE := 96.0
const MESH_PREP_MAX_MOVE_REQUESTS := 2
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
var data_prefetch_move_deferred := 0
var data_prefetch_requested_target := Vector3.INF
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
    var startup_prop_timeout := {}
    var startup_tree_timeout := {}
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
            startup_prop_timeout = _initial_region_prop_timeout_diagnostics()
            startup_tree_timeout = _initial_region_tree_timeout_diagnostics()
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
            "movementAcceptanceExcluded": data_prefetch_probe_mode in ["mesh", "visual"],
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
    if not startup_prop_timeout.is_empty():
        report["startup"]["propSourceTimeout"] = startup_prop_timeout
    if not startup_tree_timeout.is_empty():
        report["startup"]["treeCandidateTimeout"] = startup_tree_timeout
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


func _initial_region_prop_timeout_diagnostics() -> Dictionary:
    # Read only after the production initial-region deadline fails. Keep the
    # report to one exact source; never advance its seeded producer here.
    if not is_instance_valid(main): return {}
    var failure_value = main.get("startup_loading_failure_result")
    var failure: Dictionary = failure_value if failure_value is Dictionary else {}
    if startup_loading_failure != "initial_region_readiness_timeout" \
            and String(failure.get("reason", "")) != "initial_region_readiness_timeout":
        return {}
    var pending_value = main.get("visible_world_prop_pending_reasons")
    var pending: Dictionary = pending_value if pending_value is Dictionary else {}
    var pending_keys: Array[Vector2i] = []
    for key_value in pending.keys():
        if key_value is Vector2i: pending_keys.append(key_value)
    pending_keys.sort_custom(func(a: Vector2i, b: Vector2i):
        return a.x < b.x or (a.x == b.x and a.y < b.y))
    if pending_keys.is_empty():
        return {"evidenceLevel": "failure_only_read_only_producer_snapshot",
            "pendingSourceCount": 0, "reason": "no_pending_prop_source_at_timeout"}
    var key := pending_keys[0]
    var pending_reason: Dictionary = pending.get(key, {}) if pending.get(key, {}) is Dictionary else {}
    var queue_value = main.get("pending_chunk_prop_spawns")
    var queue: Dictionary = queue_value if queue_value is Dictionary else {}
    var chunks_value = main.get("chunks")
    var chunks: Dictionary = chunks_value if chunks_value is Dictionary else {}
    var physical_root := chunks.get(key) as Node3D if is_instance_valid(chunks.get(key)) else null
    var physical_state: Dictionary = queue.get(key, {}) if queue.get(key, {}) is Dictionary else {}
    var horizon = main.get("horizon_ecology_source") as Object
    var horizon_states_value = horizon.get("states") if is_instance_valid(horizon) else {}
    var horizon_states: Dictionary = horizon_states_value if horizon_states_value is Dictionary else {}
    var horizon_state: Dictionary = horizon_states.get(key, {}) \
        if horizon_states.get(key, {}) is Dictionary else {}
    var horizon_root := horizon.call("source_for", key) as Node3D \
        if is_instance_valid(horizon) and horizon.has_method("source_for") else null
    var startup_priority: Array[Vector2i] = main.call("prioritized_startup_prop_chunk_keys")
    var visible_priority: Array[Vector2i] = main.get("visible_world_prop_chunk_keys")
    var next_underground_turn := (int(main.get("chunk_prop_spawn_queue_turn")) + 1) % 4 == 0
    var surface_order: Array[Vector2i] = CHUNK_PROP_PRIORITY.ordered_keys(
        queue, visible_priority, next_underground_turn)
    var near_bounds: Rect2i = main.get("visible_world_near_bounds")
    var chunk_size := DATA_PREFETCH_CHUNK_CELLS
    var surface_only := not Rect2i(key * chunk_size, Vector2i.ONE * chunk_size).intersects(near_bounds)
    var world = main.get("world_generation_system") as Object
    var global_volume_revision := int(world.call("terrain_volume_revision")) \
        if is_instance_valid(world) and world.has_method("terrain_volume_revision") else -1
    var chunk_volume_revision := int(world.call("terrain_volume_chunk_revision", key, chunk_size)) \
        if is_instance_valid(world) and world.has_method("terrain_volume_chunk_revision") else -1
    return {"evidenceLevel": "failure_only_read_only_producer_snapshot",
        "chunk": key, "pendingSourceCount": pending_keys.size(),
        "seed": String(main.get("seed_text")),
        "globalVolumeRevision": global_volume_revision,
        "chunkVolumeRevision": chunk_volume_revision,
        "pendingReason": {"status": String(pending_reason.get("status", "")),
            "reason": String(pending_reason.get("reason", "")),
            "candidateCount": int(pending_reason.get("candidateCount", 0)),
            "candidateId": String(pending_reason.get("candidateId", ""))},
        "manifestSurfaceOnly": surface_only,
        "selectedProducer": "horizon" if surface_only and is_instance_valid(horizon_root)
            and (not is_instance_valid(physical_root) or not bool(physical_root.get_meta(
                "chunk_surface_candidate_scan_complete", false))) else "physical",
        "physical": _chunk_prop_timeout_producer(physical_root, physical_state),
        "horizon": _chunk_prop_timeout_producer(horizon_root, horizon_state),
        "queuePriority": {"pendingStateCount": queue.size(),
            "physicalQueueIndex": queue.keys().find(key),
            "startupPriorityIndex": startup_priority.find(key),
            "visiblePriorityIndex": visible_priority.find(key),
            "surfaceFirstNextUndergroundTurn": next_underground_turn,
            "surfaceFirstNextQueueIndex": surface_order.find(key),
            "surfaceFirstNextHead": surface_order[0] if not surface_order.is_empty() else null,
            "horizonStateCount": horizon_states.size(),
            "horizonPromotionCursor": int(horizon.get("promotion_cursor")) if is_instance_valid(horizon) else -1},
        "lastManifestAttempt": _chunk_prop_timeout_last_attempt(main.get("visible_world_prop_last_attempt"))}


func _initial_region_tree_timeout_diagnostics() -> Dictionary:
    # Only inspect the already failed initial foreground. The ledger query
    # validates receipts but neither admits candidates nor advances producers.
    if not is_instance_valid(main): return {}
    var failure_value = main.get("startup_loading_failure_result")
    var failure: Dictionary = failure_value if failure_value is Dictionary else {}
    if startup_loading_failure != "initial_region_readiness_timeout" \
            and String(failure.get("reason", "")) != "initial_region_readiness_timeout":
        return {}
    var ledger = main.get("visible_world_readiness") as Object
    var runtime = main.get("voxel_terrain_runtime") as Object
    var requests_value = main.get("streaming_requests")
    var requests: Dictionary = requests_value if requests_value is Dictionary else {}
    var foreground_value = main.get("streaming_request_foreground_bounds")
    var foreground: Dictionary = foreground_value if foreground_value is Dictionary else {}
    var bounds: Rect2i = foreground.get("player", Rect2i())
    var request_id := int(requests.get("player", 0))
    var seed := String(main.get("seed_text"))
    var world_revision := String(runtime.call("visible_mesh_world_revision")) \
        if is_instance_valid(runtime) and runtime.has_method("visible_mesh_world_revision") else ""
    var view_revision := int(main.get("visible_world_view_revision"))
    var result := {"evidenceLevel": "failure_only_read_only_candidate_snapshot",
        "requestId": request_id, "seed": seed, "worldRevision": world_revision,
        "viewRevision": view_revision, "foregroundBounds": bounds,
        "ledgerPresent": is_instance_valid(ledger)}
    if not is_instance_valid(ledger) or not ledger.has_method("pending_candidate_diagnostics") \
            or request_id <= 0 or not bounds.has_area() or world_revision.is_empty():
        result["reason"] = "initial_visual_ledger_query_unavailable"
        return result
    result["ledgerIdentity"] = {"requestId": int(ledger.get("_request_id")),
        "seed": String(ledger.get("_seed")),
        "worldRevision": String(ledger.get("_world_revision")),
        "viewRevision": int(ledger.get("_view_revision")),
        "bounds": ledger.get("_bounds"), "active": bool(ledger.get("_view_active"))}
    var pending: Array[Dictionary] = ledger.call("pending_candidate_diagnostics",
        request_id, seed, world_revision, view_revision, bounds, 8)
    result["pendingCandidates"] = pending
    result["pendingCandidateLimit"] = 8
    for row: Dictionary in pending:
        if String(row.get("kind", "")) == "trees_foliage":
            result["treeProducer"] = _tree_timeout_producer(row, seed)
            break
    return result


func _tree_timeout_producer(row: Dictionary, seed: String) -> Dictionary:
    var source_id := String(row.get("sourceId", ""))
    var candidate_id := String(row.get("candidateId", ""))
    var prefix := "chunk-props:%s:" % seed
    var suffix := ":trees_foliage"
    var result := {"sourceId": source_id, "candidateId": candidate_id,
        "nodeSearchLimitPerRoot": 512}
    if not source_id.begins_with(prefix) or not source_id.ends_with(suffix):
        result["reason"] = "tree_source_identity_unrecognized"
        return result
    var coordinates := source_id.substr(prefix.length(),
        source_id.length() - prefix.length() - suffix.length()).split(",")
    if coordinates.size() != 2 or not coordinates[0].is_valid_int() \
            or not coordinates[1].is_valid_int():
        result["reason"] = "tree_chunk_coordinates_invalid"
        return result
    var key := Vector2i(int(coordinates[0]), int(coordinates[1]))
    result["chunk"] = key
    var chunks_value = main.get("chunks")
    var chunks: Dictionary = chunks_value if chunks_value is Dictionary else {}
    var physical_root := chunks.get(key) as Node if is_instance_valid(chunks.get(key)) else null
    var horizon = main.get("horizon_ecology_source") as Object
    var horizon_root := horizon.call("source_for", key) as Node \
        if is_instance_valid(horizon) and horizon.has_method("source_for") else null
    result["physical"] = _tree_timeout_node(physical_root, candidate_id)
    result["horizon"] = _tree_timeout_node(horizon_root, candidate_id)
    var queue = main.get("tree_publication_queue") as Object
    if is_instance_valid(queue) and queue.has_method("metrics"):
        var metrics_value = queue.call("metrics")
        var metrics: Dictionary = metrics_value if metrics_value is Dictionary else {}
        result["publicationQueue"] = {"pending": int(metrics.get("pending", 0)),
            "activeWorkers": int(metrics.get("activeWorkers", 0)),
            "completed": int(metrics.get("completed", 0)),
            "queued": int(metrics.get("queued", 0)),
            "published": int(metrics.get("published", 0)),
            "failed": int(metrics.get("failed", 0))}
        var priority_value = metrics.get("priorityScheduling", {})
        var priority: Dictionary = priority_value if priority_value is Dictionary else {}
        result["publicationPriority"] = {"selectionCount": int(priority.get("selectionCount", 0)),
            "maxSelectionCandidates": int(priority.get("maxSelectionCandidates", 0)),
            "fullFallbackSelections": int(priority.get("fullFallbackSelections", 0)),
            "viewlessFifoSelections": int(priority.get("viewlessFifoSelections", 0)),
            "directionalPublicationSelections": int(priority.get("directionalPublicationSelections", 0)),
            "directionalPreemptions": int(priority.get("directionalPreemptions", 0))}
        var worker_value = metrics.get("workerPriorityScheduling", {})
        var worker: Dictionary = worker_value if worker_value is Dictionary else {}
        result["workerPriority"] = {"selectionCount": int(worker.get("selectionCount", 0)),
            "maxSelectionCandidates": int(worker.get("maxSelectionCandidates", 0)),
            "fullFallbackSelections": int(worker.get("fullFallbackSelections", 0))}
        var body_id := int(result["physical"].get("bodyInstanceId", 0))
        if body_id <= 0: body_id = int(result["horizon"].get("bodyInstanceId", 0))
        result["exactQueueTask"] = _tree_timeout_queue_task(queue, body_id)
    return result


func _tree_timeout_queue_task(queue: Object, body_id: int) -> Dictionary:
    # The completed array can retain tombstones. Cap all four container scans
    # together and report truncation so absence is never mistaken for proof.
    const LIMIT := 1024
    var result := {"bodyInstanceId": body_id, "scanLimit": LIMIT,
        "inspectedEntries": 0, "found": false}
    var viewer_ref = queue.get("viewer") as WeakRef
    var viewer_node := viewer_ref.get_ref() as Node3D if viewer_ref != null else null
    var viewer_live := is_instance_valid(viewer_node) and viewer_node.is_inside_tree() \
        and not viewer_node.is_queued_for_deletion()
    result["viewer"] = {"bound": viewer_ref != null,
        "live": viewer_live,
        "instanceId": viewer_node.get_instance_id() if viewer_live else 0,
        "position": viewer_node.global_position if viewer_live else Vector3.INF}
    if body_id <= 0:
        result["reason"] = "tree_body_not_found_in_bounded_source_search"
        return result
    var pending_value = queue.get("pending_tasks")
    var pending: Dictionary = pending_value if pending_value is Dictionary else {}
    var active_value = queue.get("active")
    var active_tasks: Array = active_value if active_value is Array else []
    var completed_value = queue.get("completed")
    var completed_tasks: Array = completed_value if completed_value is Array else []
    var staged_value = queue.get("staged_publication_task")
    var staged: Dictionary = staged_value if staged_value is Dictionary else {}
    result["containerCounts"] = {"pending": pending.size(), "active": active_tasks.size(),
        "completedSlots": completed_tasks.size(), "staged": 0 if staged.is_empty() else 1}
    var inspected := 0
    for stage in ["staged", "active", "pending", "completed"]:
        var entries: Array = []
        match stage:
            "staged":
                if not staged.is_empty(): entries.append(staged)
            "active": entries = active_tasks
            "pending":
                for sequence in pending:
                    if entries.size() >= LIMIT - inspected: break
                    entries.append(pending[sequence])
            "completed": entries = completed_tasks
        for value in entries:
            if inspected >= LIMIT: break
            inspected += 1
            if not value is Dictionary: continue
            var task: Dictionary = value
            var body_ref = task.get("body") as WeakRef
            var body = body_ref.get_ref() as Node if body_ref != null else null
            if not is_instance_valid(body) or body.get_instance_id() != body_id: continue
            var position = task.get("publicationPosition", Vector3.INF)
            var request: Dictionary = task.get("request", {}) if task.get("request", {}) is Dictionary else {}
            result["found"] = true
            result["container"] = stage
            result["renderStage"] = String(task.get("renderStage", "root"))
            result["publicationPosition"] = position
            result["positionDistanceToViewer"] = (position as Vector3).distance_to(viewer_node.global_position) \
                if position is Vector3 and viewer_live else -1.0
            result["ageMs"] = float(maxi(0, Time.get_ticks_usec() - int(task.get("enqueuedUsec", 0)))) / 1000.0
            result["publicationPriority"] = float(task.get("publicationPriority", INF))
            result["enqueueSequence"] = int(task.get("enqueueSequence", 0))
            result["renderLodTier"] = String(request.get("renderLodTier", ""))
            result["recipePrepared"] = task.has("recipe")
            result["lodDerivationQueued"] = task.has("lodSourceRecipe")
            result["inspectedEntries"] = inspected
            return result
        if inspected >= LIMIT: break
    result["inspectedEntries"] = inspected
    result["scanTruncated"] = inspected >= LIMIT \
        and inspected < (pending.size() + active_tasks.size() + completed_tasks.size()
            + (0 if staged.is_empty() else 1))
    return result


func _tree_timeout_node(root: Node, candidate_id: String) -> Dictionary:
    var result := {"rootPresent": is_instance_valid(root), "found": false}
    if not is_instance_valid(root): return result
    result["rootInstanceId"] = root.get_instance_id()
    result["rootInsideTree"] = root.is_inside_tree()
    result["surfaceSourceRevision"] = String(root.get_meta("chunk_surface_candidate_source_revision", ""))
    result["fullSourceRevision"] = String(root.get_meta("chunk_prop_candidate_source_revision", ""))
    var remaining: Array[Node] = [root]
    var inspected := 0
    while not remaining.is_empty() and inspected < 512:
        var node: Node = remaining.pop_back()
        inspected += 1
        if String(node.get_meta("prop_id", "")) == candidate_id:
            result["found"] = true
            result["bodyInstanceId"] = node.get_instance_id()
            result["bodyInsideTree"] = node.is_inside_tree()
            result["bodyVisible"] = node.visible if node is Node3D else false
            result["queuedForDeletion"] = node.is_queued_for_deletion()
            result["treeVisualState"] = String(node.get_meta("tree_visual_state", ""))
            result["treeRenderLodTier"] = String(node.get_meta("tree_render_lod_tier", ""))
            result["treeRecipeSignature"] = String(node.get_meta("tree_recipe_signature", ""))
            result["horizonPublisherPresent"] = node.has_meta("horizon_visual_publisher")
            result["publicationCancelled"] = bool(node.get_meta("tree_publication_cancelled", false))
            break
        for child in node.get_children():
            if child is Node: remaining.append(child)
    result["inspectedNodes"] = inspected
    result["searchTruncated"] = not remaining.is_empty() and inspected >= 512
    return result


func _chunk_prop_timeout_producer(root: Node3D, state: Dictionary) -> Dictionary:
    var scan_value = state.get("undergroundVolumeFloorScan", {})
    var scan: Dictionary = scan_value if scan_value is Dictionary else {}
    var candidates_value = state.get("undergroundCandidates", [])
    var candidates: Array = candidates_value if candidates_value is Array else []
    var active_value = state.get("detailActiveAttempt", {})
    var active: Dictionary = active_value if active_value is Dictionary else {}
    var direct_candidates := 0
    var inspected := 0
    if is_instance_valid(root):
        for child in root.get_children():
            if inspected >= 256: break
            inspected += 1
            if child is Node and child.has_meta("prop_id"): direct_candidates += 1
    return {"rootPresent": is_instance_valid(root), "statePresent": not state.is_empty(),
        "rootInstanceId": root.get_instance_id() if is_instance_valid(root) else 0,
        "rootInsideTree": root.is_inside_tree() if is_instance_valid(root) else false,
        "surfaceScanComplete": bool(root.get_meta("chunk_surface_candidate_scan_complete", false))
            if is_instance_valid(root) else false,
        "fullScanComplete": bool(root.get_meta("chunk_prop_candidate_scan_complete", false))
            if is_instance_valid(root) else false,
        "surfaceSourceRevision": String(root.get_meta("chunk_surface_candidate_source_revision", ""))
            if is_instance_valid(root) else "",
        "fullSourceRevision": String(root.get_meta("chunk_prop_candidate_source_revision", ""))
            if is_instance_valid(root) else "",
        "horizonTerrainRevision": int(root.get_meta("horizon_chunk_revision", -1))
            if is_instance_valid(root) else -1,
        "directChildCount": root.get_child_count() if is_instance_valid(root) else 0,
        "directCandidateNodesInFirst256": direct_candidates,
        "phase": String(state.get("phase", "")),
        "propIndex": int(state.get("propIndex", -1)),
        "detailIndex": int(state.get("detailIndex", -1)),
        "detailAttempts": int(state.get("detailAttempts", -1)),
        "detailBatchIndex": int(state.get("detailBatchIndex", -1)),
        "detailBatchCount": (state.get("detailBatchKeys", []) as Array).size(),
        "activeDetail": {"phase": String(active.get("phase", "")),
            "x": int(active.get("x", -1)), "z": int(active.get("z", -1)),
            "variationIndex": int(active.get("variationIndex", -1))},
        "undergroundIndex": int(state.get("undergroundIndex", -1)),
        "undergroundCandidateCount": candidates.size(),
        "undergroundScanComplete": bool(state.get("undergroundScanComplete", false)),
        "undergroundScanColumn": int(state.get("undergroundScanColumn", -1)),
        "undergroundScanY": int(state.get("undergroundScanY", -1)),
        "volumeScan": {"phase": String(scan.get("phase", "")),
            "columnIndex": int(scan.get("columnIndex", -1)),
            "scanY": int(scan.get("scanY", -1)),
            "columnStarted": bool(scan.get("columnStarted", false)),
            "complete": bool(scan.get("complete", false)),
            "revision": int(scan.get("revision", -1)),
            "chunkSize": int(scan.get("chunkSize", 0))},
        "naturalPropAdmission": _chunk_prop_timeout_last_attempt(state.get("naturalPropAdmission", {}))}


func _chunk_prop_timeout_last_attempt(value) -> Dictionary:
    var row: Dictionary = value if value is Dictionary else {}
    var result := {}
    for field in ["status", "reason", "chunk", "sourceIdentity", "cursor", "chunkCount",
            "spawnQueueDepth", "candidateCount", "candidateId", "revision"]:
        if row.has(field): result[field] = row[field]
    return result


func _prepare_data_prefetch_probe() -> void:
    # Every probe mode pauses for the same bounded interval after first control.
    # Control makes no secondary request, preserving the elapsed background
    # publication opportunity for the pinned comparison.
    var runtime = main.get("voxel_terrain_runtime") if is_instance_valid(main) else null
    var player_body = main.get("player") as CharacterBody3D if is_instance_valid(main) else null
    var started_usec := Time.get_ticks_usec()
    if data_prefetch_probe_mode in ["data", "mesh", "visual"] \
            and is_instance_valid(runtime) and is_instance_valid(player_body):
        var probe_distance := MESH_PREP_DISTANCE if _mesh_prefetch_probe() else DATA_PREFETCH_DISTANCE
        var probe_position := _data_prefetch_target(player_body.global_position)
        data_prefetch_requested_target = probe_position
        data_prefetch_viewer = VoxelViewer.new()
        data_prefetch_viewer.name = "DiagnosticVisualMeshPrep" if data_prefetch_probe_mode == "visual" \
            else ("DiagnosticCollisionMeshPrep" if data_prefetch_probe_mode == "mesh" \
                else "DiagnosticDataOnlyPrefetch")
        # The visual mode requests native rendering meshes and may draw them
        # outside the configured 96m view. It is diagnostic, not acceptance.
        data_prefetch_viewer.requires_visuals = data_prefetch_probe_mode == "visual"
        # Collision-only demand processes native blocks without requiring a
        # render mesh and can create far colliders. Neither mesh probe is
        # movement acceptance.
        data_prefetch_viewer.requires_collisions = data_prefetch_probe_mode == "mesh"
        data_prefetch_viewer.view_distance = probe_distance
        runtime.call("_stage_secondary_viewer", DATA_PREFETCH_ID, "prefetch",
            data_prefetch_viewer, probe_position, probe_distance, [], 2)
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


func _data_prefetch_target(position: Vector3) -> Vector3:
    return position + Vector3(MESH_PREP_LEAD_DISTANCE, 0.0, 0.0) \
        if _mesh_prefetch_probe() else position


func _mesh_prefetch_probe() -> bool:
    return data_prefetch_probe_mode in ["mesh", "visual"]


func _advance_data_prefetch_position(position: Vector3) -> void:
    if data_prefetch_probe_mode not in ["data", "mesh", "visual"] or not data_prefetch_attached \
            or not is_instance_valid(data_prefetch_viewer) or not position.is_finite():
        return
    var next_cell := _data_prefetch_coarse_cell(position)
    if next_cell == data_prefetch_last_cell: return
    var runtime = main.get("voxel_terrain_runtime") if is_instance_valid(main) else null
    if not is_instance_valid(runtime): return
    if _mesh_prefetch_probe():
        # Diagnostic-only cap: make at most two extra small native requests even
        # if the production background lane is busy, then observe actual lag.
        if data_prefetch_move_attempts >= MESH_PREP_MAX_MOVE_REQUESTS:
            data_prefetch_move_deferred += 1
            return
    elif int(runtime.call("voxel_engine_pending_task_count")) > 8:
        data_prefetch_move_deferred += 1
        return
    var gate = runtime.get("site_gate")
    if not is_instance_valid(gate): return
    data_prefetch_move_attempts += 1
    var probe_distance := MESH_PREP_DISTANCE if _mesh_prefetch_probe() else DATA_PREFETCH_DISTANCE
    data_prefetch_requested_target = _data_prefetch_target(position)
    if bool(gate.call("request_viewer", data_prefetch_viewer,
            data_prefetch_requested_target, probe_distance)):
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
        "requestedTarget": vec3(data_prefetch_requested_target)
            if data_prefetch_requested_target.is_finite() else [],
        "viewerTargetLagWorld": data_prefetch_viewer.global_position.distance_to(data_prefetch_requested_target)
            if data_prefetch_attached and is_instance_valid(data_prefetch_viewer)
            and data_prefetch_requested_target.is_finite() else -1.0,
        "viewerRequiresVisuals": data_prefetch_viewer.requires_visuals
            if is_instance_valid(data_prefetch_viewer) else null,
        "viewerRequiresCollisions": data_prefetch_viewer.requires_collisions
            if is_instance_valid(data_prefetch_viewer) else null,
        "primaryViewDistanceWorld": int((runtime.get("viewer") as VoxelViewer).view_distance)
            if is_instance_valid(runtime.get("viewer")) else -1,
        "nativeTerrainGeneratesCollisions": bool(terrain.generate_collisions)
            if is_instance_valid(terrain) else null,
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
        var counts := {"sampled": 0, "dataResident": 0, "nativeAreaProcessed": 0,
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
                    counts.nativeAreaProcessed += 1
        shell[str(radius_m)] = counts
    row["shell"] = shell
    var ahead_shell := {}
    for radius_m in [64.0, 96.0, 112.0, 128.0]:
        var counts := {"sampled": 0, "nativeAreaProcessed": 0, "nativeBlockEntered": 0,
            "outsideVerticalBounds": 0}
        for y_offset_cells in [-8, 0, 8]:
            var sample_world: Vector3 = player_body.global_position + Vector3(
                radius_m, float(y_offset_cells) * 1.35, 0.0)
            var sample_cell: Vector3 = sample_world / 1.35
            if sample_cell.y < float(vertical.x) or sample_cell.y > float(vertical.y):
                counts.outsideVerticalBounds += 1
                continue
            var mesh_block := Vector3i(floori(sample_cell.x / 16.0),
                floori(sample_cell.y / 16.0), floori(sample_cell.z / 16.0))
            counts.sampled += 1
            if bool(runtime.call("visible_mesh_area_complete", mesh_block)):
                counts.nativeAreaProcessed += 1
            if bool(runtime.call("visible_mesh_block_has_geometry", mesh_block)):
                counts.nativeBlockEntered += 1
        ahead_shell[str(radius_m)] = counts
    row["aheadShell"] = ahead_shell
    return row


func _data_prefetch_report() -> Dictionary:
    if data_prefetch_probe_mode.is_empty(): return {}
    return {"mode": data_prefetch_probe_mode,
        "scope": "fixture-only visual-demand probe; native rendering meshes may draw outside configured 96m view; native area/entry counters alone do not prove installed render geometry; movement result excluded from acceptance"
            if data_prefetch_probe_mode == "visual" else
            ("fixture-only collision-demand probe; native area/entry counters do not prove rendering mesh preparation; native far colliders may be added; movement result excluded from acceptance"
                if data_prefetch_probe_mode == "mesh" else
                "fixture-only data loading probe; data residency never counts as visual readiness"),
        "viewerRequiresVisuals": data_prefetch_viewer.requires_visuals if is_instance_valid(data_prefetch_viewer) else null,
        "viewerRequiresCollisions": data_prefetch_viewer.requires_collisions if is_instance_valid(data_prefetch_viewer) else null,
        "movementAcceptanceExcluded": _mesh_prefetch_probe(),
        "distanceWorldUnits": MESH_PREP_DISTANCE if _mesh_prefetch_probe()
            else DATA_PREFETCH_DISTANCE,
        "leadDistanceWorldUnits": MESH_PREP_LEAD_DISTANCE if _mesh_prefetch_probe() else 0.0,
        "nominalAheadAnnulusWorldUnits": [MESH_PREP_LEAD_DISTANCE - MESH_PREP_DISTANCE,
            MESH_PREP_LEAD_DISTANCE + MESH_PREP_DISTANCE] if _mesh_prefetch_probe() else [],
        "warmupSeconds": DATA_PREFETCH_WARMUP_SECONDS,
        "viewerAttached": data_prefetch_attached,
        "viewerAttachMs": data_prefetch_attach_ms,
        "moveAttempts": data_prefetch_move_attempts,
        "moveAdmissions": data_prefetch_move_admitted,
        "moveDeferred": data_prefetch_move_deferred,
        "maxMoveRequests": MESH_PREP_MAX_MOVE_REQUESTS if _mesh_prefetch_probe() else -1,
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
        if data_prefetch_probe_mode in ["data", "mesh", "visual"] and not data_prefetch_attached:
            failures.append("diagnostic prefetch viewer was not admitted during warmup")
        if data_prefetch_probe_mode == "mesh" and data_prefetch_attached:
            var runtime = main.get("voxel_terrain_runtime")
            var native_terrain = runtime.get("terrain") if is_instance_valid(runtime) else null
            var primary_viewer = runtime.get("viewer") if is_instance_valid(runtime) else null
            if data_prefetch_viewer.requires_visuals or not data_prefetch_viewer.requires_collisions \
                    or not is_instance_valid(native_terrain) or not native_terrain.generate_collisions \
                    or not is_instance_valid(primary_viewer) or primary_viewer.view_distance != 96:
                failures.append("hidden mesh prep probe changed the configured visual or collision policy")
        if data_prefetch_probe_mode == "visual" and data_prefetch_attached:
            var visual_runtime = main.get("voxel_terrain_runtime")
            var visual_terrain = visual_runtime.get("terrain") if is_instance_valid(visual_runtime) else null
            var visual_primary_viewer = visual_runtime.get("viewer") if is_instance_valid(visual_runtime) else null
            if not data_prefetch_viewer.requires_visuals or data_prefetch_viewer.requires_collisions \
                    or not is_instance_valid(visual_terrain) or not visual_terrain.generate_collisions \
                    or not is_instance_valid(visual_primary_viewer) or visual_primary_viewer.view_distance != 96 \
                    or not visual_primary_viewer.requires_visuals or not visual_primary_viewer.requires_collisions:
                failures.append("visual mesh prep probe changed the configured primary view or collision policy")
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
        "nativeWork": _bounded_native_terrain_work(runtime),
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


func _bounded_native_terrain_work(runtime: Object) -> Dictionary:
    var result := {"tasks": {}, "terrain": {}, "recentViewerRequests": []}
    var engine_stats: Dictionary = runtime.call("voxel_engine_task_stats") \
        if runtime.has_method("voxel_engine_task_stats") else {}
    var tasks: Dictionary = engine_stats.get("tasks", {}) \
        if engine_stats.get("tasks", {}) is Dictionary else {}
    for key in ["streaming", "meshing", "generation", "main_thread", "gpu"]:
        (result["tasks"] as Dictionary)[key] = int(tasks.get(key, 0))
    var native_terrain = runtime.get("terrain")
    var terrain_stats: Dictionary = native_terrain.get_statistics() \
        if is_instance_valid(native_terrain) and native_terrain.has_method("get_statistics") else {}
    for key in ["remaining_main_thread_blocks", "dropped_block_loads",
            "dropped_block_meshs", "updated_blocks", "time_detect_required_blocks",
            "time_request_blocks_to_load", "time_process_load_responses",
            "time_request_blocks_to_update", "time_process_update_responses"]:
        (result["terrain"] as Dictionary)[key] = int(terrain_stats.get(key, 0))
    var requests: Array = runtime.get("native_viewer_workloads")
    for index in range(maxi(0, requests.size() - 3), requests.size()):
        var request: Dictionary = requests[index]
        (result["recentViewerRequests"] as Array).append({
            "kind": String(request.get("kind", "")),
            "position": vec3(request.get("position", Vector3.ZERO)),
            "viewDistance": int(request.get("viewDistance", 0)),
            "peakPendingTasks": int(request.get("peakPendingTasks", 0)),
            "settled": bool(request.get("settled", false)),
            "superseded": bool(request.get("superseded", false)),
            "drainMs": int(request.get("drainMs", 0))})
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
    var horizon_cache = main.get("horizon_chunk_prop_manifest_cache")
    row["horizonManifestCache"] = horizon_cache.call("diagnostics") \
        if is_instance_valid(horizon_cache) and horizon_cache.has_method("diagnostics") else {}
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
            "terrainUnvisitedBlocks": int(terrain.get("unvisitedBlocks", 0)),
            "terrainNativeUnmeshedBlocks": int(terrain.get("nativeUnmeshedBlocks", 0)),
            "terrainPublisherPendingBlocks": int(terrain.get("publisherPendingBlocks", 0)),
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
