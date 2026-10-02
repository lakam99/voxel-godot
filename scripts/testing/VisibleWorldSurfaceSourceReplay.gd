extends SceneTree

# Failure-only observation of the production chunk source queue. This neither
# submits extra demand nor advances the queue outside its normal owners.
const MENU := preload("res://scenes/MainMenu.tscn")
const TERRAIN_EXTENSION := "res://addons/terrain_meshing_backend/terrain_meshing_backend.gdextension"
const VOXEL_EXTENSION := "res://addons/zylann.voxel/voxel.gdextension"
const SEED := "atlas-1492"
const MAX_SECONDS := 270.0
const STALL_SECONDS := 35.0
const MAX_EVENTS := 2048

var _started_usec := 0
var _frame := 0
var _first_seen := {}
var _last_state := {}
var _completion_usec := {}
var _events: Array = []
var _samples: Array = []
var _last_sample_second := -1
var _last_completion_second := 0.0
var _view_first_seen_second := -1.0
var _last_counter := 0
var _slice_count := 0
var _slice_total_ms := 0.0
var _slice_max_ms := 0.0
var _failure := ""

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_started_usec = Time.get_ticks_usec()
	OS.set_environment("VOXEL_PLAYTEST", "1")
	OS.set_environment("VOXEL_TEST_SEED", SEED)
	for extension_path in [TERRAIN_EXTENSION, VOXEL_EXTENSION]:
		var load_status := GDExtensionManager.LOAD_STATUS_ALREADY_LOADED \
			if GDExtensionManager.is_extension_loaded(extension_path) \
			else GDExtensionManager.load_extension(extension_path)
		if load_status not in [GDExtensionManager.LOAD_STATUS_OK,
				GDExtensionManager.LOAD_STATUS_ALREADY_LOADED]:
			push_error("required diagnostic extension failed to load: %s (%d)" % [
				extension_path, load_status])
			quit(2)
			return
	await process_frame
	if not ClassDB.class_exists("NativeCaveField") or not ClassDB.class_exists("VoxelTerrain"):
		var setup_report := {"schema": "visible-world-surface-source-replay-setup/v1",
			"terrainExtensionLoaded": GDExtensionManager.is_extension_loaded(TERRAIN_EXTENSION),
			"voxelExtensionLoaded": GDExtensionManager.is_extension_loaded(VOXEL_EXTENSION),
			"nativeCaveClass": ClassDB.class_exists("NativeCaveField"),
			"voxelTerrainClass": ClassDB.class_exists("VoxelTerrain"),
			"reason": "required_native_class_unavailable_after_explicit_load"}
		_write_json(OS.get_environment("VOXEL_VISIBLE_SURFACE_REPLAY_REPORT"), setup_report)
		print(JSON.stringify(setup_report))
		quit(2)
		return
	if OS.get_environment("VOXEL_VISIBLE_SOURCE_REPLAY_SETUP_ONLY") == "1":
		var setup_report := {"schema": "visible-world-surface-source-replay-setup/v1",
			"terrainExtensionLoaded": GDExtensionManager.is_extension_loaded(TERRAIN_EXTENSION),
			"voxelExtensionLoaded": GDExtensionManager.is_extension_loaded(VOXEL_EXTENSION),
			"nativeCaveClass": true, "voxelTerrainClass": true, "reason": "ready"}
		_write_json(OS.get_environment("VOXEL_VISIBLE_SURFACE_REPLAY_REPORT"), setup_report)
		print(JSON.stringify(setup_report))
		quit(0)
		return
	var menu = MENU.instantiate()
	root.add_child(menu)
	await process_frame
	menu.launch_game("new_game")
	var main: Node = null
	var stop_reason := "time_limit"
	while _seconds() < MAX_SECONDS:
		await process_frame
		_frame += 1
		main = menu.get_node_or_null("Main")
		if main == null:
			continue
		if String(main.get("seed_text")) != SEED:
			_failure = "seed_mismatch"
			stop_reason = "seed_mismatch"
			break
		_observe(main)
		var startup_failure = main.get("startup_loading_failure_result")
		if startup_failure is Dictionary and not startup_failure.is_empty():
			_failure = "startup_failure"
			stop_reason = "startup_failure"
			break
		var view_keys: Array = main.get("visible_world_prop_chunk_keys")
		if view_keys.size() > 0 and _view_first_seen_second < 0.0:
			_view_first_seen_second = _seconds()
			_last_completion_second = _view_first_seen_second
		var submitted_sources: Dictionary = main.get("visible_world_prop_manifest_sources")
		if view_keys.size() > 0 and submitted_sources.size() >= view_keys.size() \
				and not bool(main.get("startup_loading_active")):
			stop_reason = "view_sources_and_startup_complete"
			break
		if _view_first_seen_second >= 0.0 \
				and _seconds() - _last_completion_second >= STALL_SECONDS:
			stop_reason = "surface_source_stall_window"
			break
	if main == null:
		_failure = "main_missing"
	var report := _report(main, stop_reason)
	var report_path := OS.get_environment("VOXEL_VISIBLE_SURFACE_REPLAY_REPORT")
	if report_path.is_empty() or not _write_json(report_path, report):
		push_error("surface replay report write failed")
		quit(2)
		return
	print(JSON.stringify({"reportPath": report_path, "stopReason": stop_reason,
		"viewSourcesComplete": report.get("viewSourcesComplete", 0),
		"viewChunkCount": report.get("viewChunkCount", 0)}))
	if main != null and is_instance_valid(main):
		main.request_graceful_quit(0 if _failure.is_empty() else 1)
		return
	quit(0 if _failure.is_empty() else 1)

func _observe(main: Node) -> void:
	var now := _seconds()
	var queue: Dictionary = main.get("pending_chunk_prop_spawns")
	var chunks: Dictionary = main.get("chunks")
	var view_keys: Array = main.get("visible_world_prop_chunk_keys")
	for key_value in queue:
		if not (key_value is Vector2i):
			continue
		var key: Vector2i = key_value
		var id := _key_id(key)
		if not _first_seen.has(id):
			_first_seen[id] = now
			_event({"atSeconds": now, "kind": "queued", "chunk": id})
		var state_value = queue[key]
		if not (state_value is Dictionary):
			continue
		var state: Dictionary = state_value
		var compact := _compact_state(state)
		if _last_state.get(id, {}) != compact:
			if String((_last_state.get(id, {}) as Dictionary).get("phase", "")) != String(compact.phase):
				_event({"atSeconds": now, "kind": "phase", "chunk": id,
					"from": (_last_state.get(id, {}) as Dictionary).get("phase", "unseen"),
					"to": compact.phase, "state": compact})
			_last_state[id] = compact
	for key_value in view_keys:
		if not (key_value is Vector2i):
			continue
		var key: Vector2i = key_value
		var id := _key_id(key)
		var chunk = chunks.get(key)
		if chunk is Node3D and is_instance_valid(chunk) \
				and bool(chunk.get_meta("chunk_surface_candidate_scan_complete", false)) \
				and not _completion_usec.has(id):
			_completion_usec[id] = now
			_last_completion_second = now
			_event({"atSeconds": now, "kind": "surface_source_complete", "chunk": id,
				"queueAgeSeconds": now - float(_first_seen.get(id, now)),
				"lastQueueState": _last_state.get(id, {})})
	var monitor = main.get("runtime_perf_monitor")
	if monitor != null:
		var counter := int(monitor.call("counter_value", "chunk_prop_spawn_slices"))
		if counter > _last_counter:
			var duration := float((monitor.get("last_section_ms") as Dictionary).get("chunk_spawn_props", 0.0))
			_slice_count += counter - _last_counter
			_slice_total_ms += duration
			_slice_max_ms = maxf(_slice_max_ms, duration)
			_last_counter = counter
	var second := int(now)
	if second != _last_sample_second:
		_last_sample_second = second
		_samples.append(_sample(main, now))

func _compact_state(state: Dictionary) -> Dictionary:
	var active: Dictionary = state.get("detailActiveAttempt", {}) \
		if state.get("detailActiveAttempt", {}) is Dictionary else {}
	var admission: Dictionary = state.get("naturalPropAdmission", {}) \
		if state.get("naturalPropAdmission", {}) is Dictionary else {}
	return {"phase": String(state.get("phase", "")),
		"admission": String(admission.get("status", "unrequested")),
		"admissionReason": String(admission.get("reason", "")),
		"propIndex": int(state.get("propIndex", 0)),
		"detailIndex": int(state.get("detailIndex", 0)),
		"detailAttempts": int(state.get("detailAttempts", -1)),
		"detailAttemptPhase": String(active.get("phase", "")),
		"detailBatchIndex": int(state.get("detailBatchIndex", 0)),
		"detailBatchCount": (state.get("detailBatchKeys", []) as Array).size(),
		"undergroundScanColumn": int(state.get("undergroundScanColumn", 0)),
		"undergroundScanComplete": bool(state.get("undergroundScanComplete", false))}

func _sample(main: Node, now: float) -> Dictionary:
	var queue: Dictionary = main.get("pending_chunk_prop_spawns")
	var chunks: Dictionary = main.get("chunks")
	var view_keys: Array = main.get("visible_world_prop_chunk_keys")
	var phases := {}
	var incomplete: Array = []
	var oldest_age := 0.0
	for key_value in view_keys:
		if not (key_value is Vector2i):
			continue
		var key: Vector2i = key_value
		var chunk = chunks.get(key)
		if chunk is Node3D and is_instance_valid(chunk) \
				and bool(chunk.get_meta("chunk_surface_candidate_scan_complete", false)):
			continue
		var id := _key_id(key)
		var state: Dictionary = queue.get(key, {}) if queue.get(key, {}) is Dictionary else {}
		var phase := String(state.get("phase", "not_queued"))
		phases[phase] = int(phases.get(phase, 0)) + 1
		var age := now - float(_first_seen.get(id, now))
		oldest_age = maxf(oldest_age, age)
		incomplete.append({"chunk": id, "queueAgeSeconds": age,
			"state": _compact_state(state) if not state.is_empty() else {"phase": phase}})
	var monitor = main.get("runtime_perf_monitor")
	var sections: Dictionary = monitor.get("last_section_ms") if monitor != null else {}
	var timeline: Array = main.get("startup_loading_timeline")
	var submitted_sources: Dictionary = main.get("visible_world_prop_manifest_sources")
	var pending_reasons: Dictionary = main.get("visible_world_prop_pending_reasons")
	var latest_step: Dictionary = timeline[timeline.size() - 1] \
		if not timeline.is_empty() and timeline[timeline.size() - 1] is Dictionary else {}
	var visual_metrics: Dictionary = latest_step.get("metrics", {}) \
		if String(latest_step.get("domain", "")) == "visible_world" \
		and latest_step.get("metrics", {}) is Dictionary else {}
	return {"atSeconds": now, "frame": _frame,
		"loadingActive": bool(main.get("startup_loading_active")),
		"startupDomain": String(latest_step.get("domain", "")),
		"fullView": {"reason": visual_metrics.get("reason", ""),
			"candidateCount": visual_metrics.get("candidateCount", 0),
			"representedCount": visual_metrics.get("representedCount", 0),
			"pendingCount": visual_metrics.get("pendingCount", 0),
			"coverageGaps": visual_metrics.get("coverageGaps", []),
			"propSourcesComplete": visual_metrics.get("propSourcesComplete", 0),
			"structureSourcesComplete": visual_metrics.get("structureSourcesComplete", 0),
			"expectedChunkSources": visual_metrics.get("expectedChunkSources", 0)},
		"viewChunkCount": view_keys.size(), "viewSourcesComplete": _complete_count(main, view_keys),
		"propManifestsSubmitted": submitted_sources.size(),
		"propManifestPendingReasons": pending_reasons.values().slice(0, 12),
		"queueDepth": queue.size(), "incompletePhases": phases,
		"oldestQueueAgeSeconds": oldest_age, "incomplete": incomplete,
		"spawnSlices": _slice_count, "lastChunkSpawnPropsMs": float(sections.get("chunk_spawn_props", 0.0))}

func _complete_count(main: Node, view_keys: Array) -> int:
	var chunks: Dictionary = main.get("chunks")
	var count := 0
	for key_value in view_keys:
		var chunk = chunks.get(key_value)
		if chunk is Node3D and is_instance_valid(chunk) \
				and bool(chunk.get_meta("chunk_surface_candidate_scan_complete", false)):
			count += 1
	return count

func _report(main: Node, stop_reason: String) -> Dictionary:
	var view_keys: Array = main.get("visible_world_prop_chunk_keys") if main != null else []
	var final_sample: Dictionary = _sample(main, _seconds()) if main != null else {}
	var monitor = main.get("runtime_perf_monitor") if main != null else null
	var slice_percentiles: Dictionary = monitor.call("section_percentiles") if monitor != null else {}
	var state_rows: Array = final_sample.get("incomplete", [])
	return {"schema": "visible-world-surface-source-replay/v1",
		"evidenceLevel": "live_visible_source_observation" if \
			OS.get_environment("VOXEL_VISIBLE_SOURCE_REPLAY_HEADED") == "1" \
			else "live_headless_failure_observation",
		"seed": SEED, "elapsedSeconds": _seconds(), "framesObserved": _frame,
		"stopReason": stop_reason, "failure": _failure,
		"viewChunkCount": view_keys.size(),
		"viewSourcesComplete": _complete_count(main, view_keys) if main != null else 0,
		"sourceCompletionSeconds": _completion_usec,
		"queueFirstSeenSeconds": _first_seen,
		"spawnSliceCount": _slice_count,
		"observedSliceDurationMs": {"mean": _slice_total_ms / float(maxi(1, _slice_count)),
			"max": _slice_max_ms,
			"scope": "last completed chunk_spawn_props section at observer frame; may omit multiple slices in one frame"},
		"productionSectionPercentiles": {
			"chunk_spawn_props": slice_percentiles.get("chunk_spawn_props", {}),
			"chunk_surface_prop_attempt": slice_percentiles.get("chunk_surface_prop_attempt", {}),
			"chunk_detail_prop_attempt": slice_percentiles.get("chunk_detail_prop_attempt", {}),
			"chunk_detail_prop_block_check": slice_percentiles.get("chunk_detail_prop_block_check", {}),
			"chunk_detail_prop_sample": slice_percentiles.get("chunk_detail_prop_sample", {}),
			"chunk_detail_batch_spawn": slice_percentiles.get("chunk_detail_batch_spawn", {})},
		"samples": _samples, "events": _events, "finalIncomplete": state_rows,
		"lastProductionStates": _last_state}

func _event(row: Dictionary) -> void:
	if _events.size() < MAX_EVENTS:
		_events.append(row)

func _seconds() -> float:
	return float(Time.get_ticks_usec() - _started_usec) / 1000000.0

func _key_id(key: Vector2i) -> String:
	return "%d,%d" % [key.x, key.y]

func _write_json(path: String, value: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(value, "\t"))
	file.close()
	return true
