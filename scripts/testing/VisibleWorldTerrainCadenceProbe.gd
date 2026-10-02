extends SceneTree

# Read-only observation of the ordinary menu -> New Game terrain path.
# No demand is submitted by this diagnostic.
const MENU := preload("res://scenes/MainMenu.tscn")
const TERRAIN_EXTENSION := "res://addons/terrain_meshing_backend/terrain_meshing_backend.gdextension"
const VOXEL_EXTENSION := "res://addons/zylann.voxel/voxel.gdextension"
const SEED := "atlas-1492"
const MAX_SECONDS := 235.0

var _started_usec := 0
var _last_frame_usec := 0
var _frames := 0
var _cadence_max_ms := 0.0
var _cadence_over_33 := 0
var _cadence_over_100 := 0
var _cadence_values: Array[float] = []
var _samples: Array[Dictionary] = []
var _events: Array[Dictionary] = []
var _last_second := -1
var _last_stage := ""
var _last_retained_count := -1
var _last_distance := -1
var _last_mesh_count := -1
var _final_distance_seen := -1.0
var _second_retained_seen := -1.0
var _failure := ""

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_started_usec = Time.get_ticks_usec()
	_last_frame_usec = _started_usec
	OS.set_environment("VOXEL_PLAYTEST", "1")
	OS.set_environment("VOXEL_TEST_SEED", SEED)
	for extension_path in [TERRAIN_EXTENSION, VOXEL_EXTENSION]:
		var load_status := GDExtensionManager.LOAD_STATUS_ALREADY_LOADED \
			if GDExtensionManager.is_extension_loaded(extension_path) \
			else GDExtensionManager.load_extension(extension_path)
		if load_status not in [GDExtensionManager.LOAD_STATUS_OK,
				GDExtensionManager.LOAD_STATUS_ALREADY_LOADED]:
			_failure = "native_extension_load_failed:%s:%d" % [extension_path, load_status]
			await _finish(null, "setup_failed")
			return
	await process_frame
	if not ClassDB.class_exists("NativeCaveField") or not ClassDB.class_exists("VoxelTerrain"):
		_failure = "native_class_missing"
		await _finish(null, "setup_failed")
		return
	var menu = MENU.instantiate()
	root.add_child(menu)
	await process_frame
	menu.launch_game("new_game")
	var main: Node = null
	var stop_reason := "time_limit"
	while _seconds() < MAX_SECONDS:
		await process_frame
		_observe_cadence()
		main = menu.get_node_or_null("Main")
		if main == null:
			continue
		if String(main.get("seed_text")) != SEED:
			_failure = "seed_mismatch"
			stop_reason = _failure
			break
		if int(_seconds()) != _last_second:
			_last_second = int(_seconds())
			_sample(main)
		var startup_failure = main.get("startup_loading_failure_result")
		if startup_failure is Dictionary and not startup_failure.is_empty():
			_failure = "startup_failure"
			stop_reason = _failure
			break
		if not bool(main.get("startup_loading_active")):
			stop_reason = "startup_complete"
			break
		# Keep the comparison alive through first control or the bounded limit;
		# two viewer admissions alone cannot prove that all retained demand drained.
	if main == null and _failure.is_empty():
		_failure = "main_missing"
	await _finish(main, stop_reason)

func _observe_cadence() -> void:
	var now := Time.get_ticks_usec()
	var duration_ms := float(now - _last_frame_usec) / 1000.0
	_last_frame_usec = now
	_frames += 1
	_cadence_max_ms = maxf(_cadence_max_ms, duration_ms)
	if duration_ms > 33.0: _cadence_over_33 += 1
	if duration_ms > 100.0: _cadence_over_100 += 1
	# A bounded rolling sample distinguishes total callback cadence from Main's
	# own _process timing without sorting or retaining an entire long run.
	if _cadence_values.size() < 900:
		_cadence_values.append(duration_ms)
	else:
		_cadence_values[_frames % 900] = duration_ms

func _sample(main: Node) -> void:
	var runtime = main.get("voxel_terrain_runtime")
	if not is_instance_valid(runtime):
		_samples.append({"atSeconds": _seconds(), "stage": "runtime_missing"})
		return
	var task_stats: Dictionary = runtime.call("voxel_engine_task_stats")
	var tasks: Dictionary = task_stats.get("tasks", {}) if task_stats.get("tasks", {}) is Dictionary else {}
	var runtime_stats: Dictionary = runtime.call("stats")
	var terrain = runtime.get("terrain")
	var terrain_stats: Dictionary = terrain.get_statistics() if is_instance_valid(terrain) else {}
	var timeline: Array = main.get("startup_loading_timeline")
	var step: Dictionary = timeline[-1] if not timeline.is_empty() and timeline[-1] is Dictionary else {}
	var stage := String(step.get("domain", ""))
	var retained_count := int(runtime_stats.get("retainedRegionViewers", 0))
	var distance := int(runtime_stats.get("currentViewDistance", 0))
	var mesh_count := int(runtime_stats.get("publishedMeshBlocks", 0))
	if stage != _last_stage or retained_count != _last_retained_count \
			or distance != _last_distance:
		_event({"atSeconds": _seconds(), "stage": stage, "viewDistance": distance,
			"retainedViewers": retained_count, "meshBlocks": mesh_count,
			"tasks": _compact_tasks(tasks),
			"admissionReason": runtime_stats.get("secondaryViewerAdmissionReason", ""),
			"retainedReason": runtime_stats.get("retainedActivationReason", "")})
	_last_stage = stage
	_last_retained_count = retained_count
	_last_distance = distance
	_last_mesh_count = mesh_count
	if distance >= int(runtime_stats.get("finalViewDistance", 96)) and _final_distance_seen < 0.0:
		_final_distance_seen = _seconds()
	if retained_count >= 2 and _second_retained_seen < 0.0:
		_second_retained_seen = _seconds()
	var perf = main.get("runtime_perf_monitor")
	var perf_summary: Dictionary = perf.call("summary") if is_instance_valid(perf) else {}
	_samples.append({"atSeconds": _seconds(), "stage": stage,
		"loadingActive": bool(main.get("startup_loading_active")),
		"frameCount": _frames, "cadenceMaxMs": _cadence_max_ms,
		"cadenceOver33": _cadence_over_33, "cadenceOver100": _cadence_over_100,
		"mainProcessP95Ms": perf_summary.get("frameP95Ms", 0.0),
		"mainProcessMaxMs": perf_summary.get("frameMaxMs", 0.0),
		"mainLastSpikeReason": perf_summary.get("lastSpikeReason", ""),
		"mainLastSpikeTopSections": perf_summary.get("lastSpikeTopSections", []),
		"tasks": _compact_tasks(tasks), "nativeTaskTotal": runtime.call("voxel_engine_pending_task_count"),
		"viewerDistance": distance, "viewerGroups": runtime_stats.get("retainedQueuedViewerGroups", 0),
		"retainedViewers": retained_count,
		"secondaryPendingAdmissions": runtime_stats.get("secondaryViewerPendingAdmissions", 0),
		"secondaryAdmissionReason": runtime_stats.get("secondaryViewerAdmissionReason", ""),
		"retainedActivationReason": runtime_stats.get("retainedActivationReason", ""),
		"nativeViewerWorkloads": (runtime_stats.get("nativeViewerWorkloads", []) as Array).slice(-3),
		"publishedMeshBlocks": mesh_count,
		"publishedGameplayChunks": runtime_stats.get("publishedGameplayChunks", 0),
		"pendingGameplayChunks": runtime_stats.get("pendingGameplayChunks", 0),
		"collisionProbeAttempts": runtime_stats.get("collisionProbeAttempts", 0),
		"collisionProbePasses": runtime_stats.get("collisionProbePasses", 0),
		"nearPropQueue": _near_prop_queue(main),
		"undergroundCellsScanned": int(perf.call("counter_value", "underground_prop_cells_scanned"))
			if is_instance_valid(perf) else 0,
		"terrainStats": terrain_stats,
		"stepElapsedMs": step.get("elapsedMs", 0.0),
		"stepMetrics": _compact_step(step.get("metrics", {}))})

func _near_prop_queue(main: Node) -> Array[Dictionary]:
	var bounds: Rect2i = main.get("visible_world_near_bounds")
	if not bounds.has_area(): return []
	var pending: Dictionary = main.get("pending_chunk_prop_spawns")
	var rows: Array[Dictionary] = []
	for key_value in pending:
		if not (key_value is Vector2i): continue
		var key: Vector2i = key_value
		if not Rect2i(key * 28, Vector2i.ONE * 28).intersects(bounds): continue
		var state_value = pending[key]
		if not (state_value is Dictionary): continue
		var state: Dictionary = state_value
		var volume: Dictionary = state.get("undergroundVolumeFloorScan", {}) \
			if state.get("undergroundVolumeFloorScan", {}) is Dictionary else {}
		rows.append({"chunk": key, "phase": state.get("phase", ""),
			"scanColumn": volume.get("columnIndex", 0), "scanY": volume.get("scanY", 0),
			"scanComplete": state.get("undergroundScanComplete", false),
			"candidateCount": (state.get("undergroundCandidates", []) as Array).size()})
	rows.sort_custom(func(a: Dictionary, b: Dictionary):
		return a.chunk.x < b.chunk.x if a.chunk.x != b.chunk.x else a.chunk.y < b.chunk.y)
	return rows.slice(0, 12)

func _compact_tasks(tasks: Dictionary) -> Dictionary:
	var result := {}
	for name in ["streaming", "meshing", "generation", "main_thread", "gpu"]:
		result[name] = int(tasks.get(name, 0))
	return result

func _compact_step(value: Variant) -> Dictionary:
	if not value is Dictionary: return {}
	var source: Dictionary = value
	var result := {}
	for key in ["currentViewDistance", "publishedRetainedGameplayChunks",
			"retainedGameplayChunks", "retainedRegionViewers", "retainedViewerGroups",
			"pendingNativeTasks", "quietFrames", "requiredQuietFrames",
			"status", "reason", "candidateCount", "representedCount", "pendingCount",
			"byKind", "coverageGaps", "queue", "coverageLag",
			"visualDemandRevision", "publication"]:
		if source.has(key): result[key] = source[key]
	return result

func _event(row: Dictionary) -> void:
	if _events.size() < 512: _events.append(row)

func _finish(main: Node, stop_reason: String) -> void:
	var report := {"schema": "visible-world-terrain-cadence/v1",
		"seed": SEED, "evidenceLevel": "live_headed_diagnostic",
		"elapsedSeconds": _seconds(), "stopReason": stop_reason, "failure": _failure,
		"framesObserved": _frames, "cadenceMaxMs": _cadence_max_ms,
		"cadenceOver33": _cadence_over_33, "cadenceOver100": _cadence_over_100,
		"cadenceSampleP95Ms": _percentile(_cadence_values, 0.95),
		"cadenceSampleScope": "SceneTree callback-to-callback intervals; includes rendering, scheduling and observer overhead, not exclusive CPU time",
		"finalDistanceSeenSeconds": _final_distance_seen,
		"secondRetainedViewerSeenSeconds": _second_retained_seen,
		"samples": _samples, "events": _events}
	var report_path := OS.get_environment("VOXEL_TERRAIN_CADENCE_REPORT")
	if main != null and is_instance_valid(main) and stop_reason == "startup_complete":
		var runtime = main.get("voxel_terrain_runtime")
		var controller = main.get("visible_world_demand_controller")
		if is_instance_valid(runtime) and is_instance_valid(controller):
			var full: Dictionary = controller.call("full_view_readiness", "player",
				int((main.get("streaming_requests") as Dictionary).get("player", 0)),
				String(main.get("seed_text")),
				String(runtime.call("visible_mesh_world_revision")))
			report["firstControlFullView"] = {
				"status": full.get("status", "pending"), "reason": full.get("reason", ""),
				"candidateCount": full.get("candidateCount", 0),
				"representedCount": full.get("representedCount", 0),
				"pendingCount": full.get("pendingCount", 0),
				"byKind": full.get("byKind", {}), "tiers": full.get("tiers", {}),
				"coverageGaps": full.get("coverageGaps", []),
				"viewRevision": full.get("viewRevision", 0),
				"visualDemandRevision": full.get("visualDemandRevision", 0)}
		await RenderingServer.frame_post_draw
		var screenshot_path := report_path.get_base_dir().path_join("first_control.png")
		var image := root.get_texture().get_image()
		report["firstControlScreenshot"] = screenshot_path if image.save_png(screenshot_path) == OK else ""
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("terrain cadence report write failed")
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print(JSON.stringify({"reportPath": report_path, "stopReason": stop_reason,
		"elapsedSeconds": report.elapsedSeconds, "sampleCount": _samples.size()}))
	if main != null and is_instance_valid(main):
		main.request_graceful_quit(0 if _failure.is_empty() else 1)
	else:
		quit(0 if _failure.is_empty() else 1)

func _seconds() -> float:
	return float(Time.get_ticks_usec() - _started_usec) / 1000000.0

func _percentile(values: Array[float], ratio: float) -> float:
	if values.is_empty(): return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var index := clampi(ceili(float(sorted.size()) * ratio) - 1, 0, sorted.size() - 1)
	return sorted[index]
