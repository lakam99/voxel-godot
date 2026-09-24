extends Node

const MENU = preload("res://scenes/MainMenu.tscn")

var _report_path := ""
var _capture_dir := ""
var _failure := ""
var _pending_seen := false
var _ready_seen := false
var _pending_capture := ""
var _ready_capture := ""
var _started_msec := 0

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	_report_path = OS.get_environment("VWB_N3_PRIVATE_MAIN_REPORT")
	_capture_dir = OS.get_environment("VWB_N3_PRIVATE_MAIN_CAPTURE_DIR")
	var launch_mode := OS.get_environment("VWB_N3_PRIVATE_MAIN_MODE")
	if launch_mode.is_empty(): launch_mode = "new_game"
	var is_continue := launch_mode != "new_game"
	_started_msec = Time.get_ticks_msec()
	var menu = MENU.instantiate()
	get_tree().root.add_child(menu)
	await get_tree().process_frame
	menu.launch_game("continue" if is_continue else "new_game")
	var main
	while Time.get_ticks_msec() - _started_msec < 360000:
		await get_tree().process_frame
		main = menu.get_node_or_null("Main")
		if main == null: continue
		var stage = main.get("_native_private_load_stage")
		if stage != null:
			var stage_state: Dictionary = stage.snapshot()
			if not _pending_seen and stage_state.get("state") in ["converting", "importing"]:
				_pending_seen = true
				_pending_capture = await _capture("private-pending-%s.png" % launch_mode)
			if not _ready_seen and stage_state.get("state") == "ready":
				_ready_seen = true
				_ready_capture = await _capture("private-ready-%s.png" % launch_mode)
		if main.get("startup_loading_failure_result") is Dictionary \
				and not (main.get("startup_loading_failure_result") as Dictionary).is_empty():
			_failure = String((main.get("startup_loading_failure_result") as Dictionary).get("reason", "startup_failed"))
			break
		if not bool(main.get("startup_loading_active")) and _ready_seen:
			break
	if main == null: _failure = "main_missing"
	elif bool(main.get("startup_loading_active")) and _failure.is_empty(): _failure = "startup_timeout"
	elif not _ready_seen and _failure.is_empty(): _failure = "private_candidate_missing"
	var runtime_continue := false
	var save_written := false
	var save_decoded := false
	var pre_runtime_flags := {}
	var initial_generation := 0
	var final_generation := 0
	if _failure.is_empty() and main != null and launch_mode == "new_game":
		var initial_stage = main.get("_native_private_load_stage")
		if initial_stage != null:
			initial_generation = int(initial_stage.snapshot().get("transaction", {}).get("generation", 0))
		var save: Dictionary = main.create_save_snapshot()
		save_written = main.save_system.save(String(main.get("seed_text")), save)
		var decoded: Dictionary = main.save_system.load(String(main.get("seed_text"))) if save_written else {}
		save_decoded = int(decoded.get("version", -1)) == 2
		pre_runtime_flags = {"startupOperation":bool(main.get("startup_operation_active")),
			"startupLoading":bool(main.get("startup_loading_active")),
			"runtimeLoading":bool(main.get("runtime_loading_active")),
			"shutdown":bool(main.get("shutdown_requested")),
			"saveSeed":String(decoded.get("seed", "")),
			"worldSeed":String(main.get("seed_text"))}
		runtime_continue = bool(await main.try_load_world_staged(false, decoded)) if save_decoded else false
		var final_stage = main.get("_native_private_load_stage")
		if final_stage != null:
			final_generation = int(final_stage.snapshot().get("transaction", {}).get("generation", 0))
		if not runtime_continue or final_stage == null or final_stage.snapshot().get("state") != "ready":
			_failure = "runtime_continue_private_candidate_failed"
	var stage_state: Dictionary = main.get("_native_private_load_stage").snapshot() \
		if main != null and main.get("_native_private_load_stage") != null else {}
	var domains: Dictionary = main.get("startup_readiness_domains") \
		if main != null and main.get("startup_readiness_domains") is Dictionary else {}
	var failure_result: Dictionary = main.get("startup_loading_failure_result") \
		if main != null and main.get("startup_loading_failure_result") is Dictionary else {}
	var timeline: Array = main.get("startup_loading_timeline") \
		if main != null and main.get("startup_loading_timeline") is Array else []
	var timeline_tail := []
	for row_value in timeline.slice(maxi(0, timeline.size() - 12)):
		if row_value is Dictionary:
			var row: Dictionary = row_value
			timeline_tail.append({"domain":row.get("domain", ""),
				"status":row.get("status", ""), "message":row.get("message", ""),
				"elapsedMs":row.get("elapsedMs", 0), "stepMs":row.get("stepMs", 0)})
	var gameplay_row: Dictionary = domains.get("gameplay", {}) if domains.get("gameplay", {}) is Dictionary else {}
	var save_row: Dictionary = domains.get("save_restore", {}) if domains.get("save_restore", {}) is Dictionary else {}
	var admitted_records := int(stage_state.get("transaction", {}).get("recordsAdmitted", 0))
	var report := {"schema":"n3-private-main-load-headed/v1",
		"passed":_failure.is_empty() and _pending_seen and _ready_seen \
			and (is_continue or (save_written and save_decoded and runtime_continue)) \
			and String(gameplay_row.get("status", "")) == "ready" \
			and (not is_continue or String(save_row.get("status", "")) == "ready") \
			and (launch_mode != "historical_continue" or admitted_records > 0),
		"launchMode":launch_mode,
		"failure":_failure, "elapsedMs":Time.get_ticks_msec() - _started_msec,
		"pendingSeen":_pending_seen, "readySeen":_ready_seen,
		"runtimeContinue":runtime_continue,
		"saveWritten":save_written, "saveDecoded":save_decoded,
		"preRuntimeFlags":pre_runtime_flags,
		"initialGeneration":initial_generation, "finalGeneration":final_generation,
		"pendingCapture":_pending_capture, "readyCapture":_ready_capture,
		"privateStage":stage_state,
		"recordsAdmitted":admitted_records,
		"startupFailureResult":failure_result,
		"startupTimelineTail":timeline_tail,
		"startupOperationActive":bool(main.get("startup_operation_active")) if main != null else false,
		"runtimeLoadingActive":bool(main.get("runtime_loading_active")) if main != null else false,
		"gameplayReadiness":{"status":gameplay_row.get("status", ""),
			"elapsedMs":gameplay_row.get("elapsedMs", 0), "stepMs":gameplay_row.get("stepMs", 0)},
		"saveRestoreReadiness":save_row.get("status", ""),
		"sourceAuthority":"script_and_voxel_tools_unchanged",
		"doesNotProve":"No fresh-process Continue, collision cutover, native gameplay query publication, or full N3 acceptance."}
	if not _report_path.is_empty():
		var file := FileAccess.open(_report_path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(report, "\t"))
	if main != null and main.has_method("request_graceful_quit"):
		main.request_graceful_quit(0 if report.passed else 1)
	else:
		get_tree().quit(0 if report.passed else 1)

func _capture(name: String) -> String:
	if _capture_dir.is_empty(): return ""
	await RenderingServer.frame_post_draw
	var path := _capture_dir.path_join(name)
	var image := get_viewport().get_texture().get_image()
	if image == null or image.save_png(path) != OK: return ""
	return path
