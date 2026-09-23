extends Node

const MENU_SCENE: PackedScene = preload("res://scenes/MainMenu.tscn")
const REPORT_SCHEMA := "world-streaming-loading-sample/v1"
const MAX_STARTUP_SECONDS := 300.0
const STARTUP_TIMELINE_RETAINED_CAPACITY := 256
const MAIN_MONITOR_POLL_INTERVAL_USEC := 1000000
const POST_READY_MODAL_OBSERVATION_FRAMES := 60

var report_path := ""
var progress_path := ""
var run_token := ""
var launch_mode := "new_game"
var cache_classification := "cold"
var requested_seed := ""
var process_test_seed := ""
var sample_id := ""
var menu: Node
var main: Node
var input_started_usec := 0
var first_loading_usec := 0
var gameplay_ready_usec := 0
var loading_completed := false
var loading_failure := ""
var loading_signal_rows: Array[Dictionary] = []
var frame_gap_ms: Array[float] = []
var last_frame_usec := 0
var overlay_visible_transitions := 0
var last_overlay_visible := false
var overlay_visible_frames := 0
var overlay_missing_frames := 0
var post_ready_modal_visible_frames := 0
var environment_errors: Array[String] = []
var main_callback_window_at_ready := {}
var observed_timeline_rows: Array[Dictionary] = []
var observed_timeline_keys := {}
var progress_heartbeat_count := 0
var progress_heartbeat_max_gap_ms := 0.0
var progress_heartbeat_last_usec := 0
var progress_heartbeat_last_owner := ""
var progress_heartbeat_last_status := ""
var progress_heartbeat_last_metrics := {}
var work_proof_rows: Array[Dictionary] = []
var last_work_revision := 0
var timeline_observation_started := false
var timeline_initial_snapshot_size := -1
var timeline_initial_snapshot_at_capacity := false
var timeline_last_retained_size := 0
var main_monitor_last_poll_usec := 0
var main_monitor_poll_count := 0
var main_monitor_max_sample_count := 0
var main_monitor_max_frame_ms := 0.0
var post_ready_modal_observation_frames := 0
var requested_resolution := Vector2i.ZERO

func _ready() -> void:
	report_path = OS.get_environment("VOXEL_WORLD_STREAMING_LOADING_SAMPLE_REPORT").strip_edges()
	progress_path = OS.get_environment("VOXEL_WORLD_STREAMING_LOADING_SAMPLE_PROGRESS").strip_edges()
	run_token = OS.get_environment("VOXEL_WORLD_STREAMING_LOADING_MATRIX_TOKEN").strip_edges()
	launch_mode = OS.get_environment("VOXEL_WORLD_STREAMING_LOADING_SAMPLE_MODE").strip_edges().to_lower()
	cache_classification = OS.get_environment("VOXEL_WORLD_STREAMING_LOADING_CACHE_CLASSIFICATION").strip_edges().to_lower()
	requested_seed = OS.get_environment("VOXEL_WORLD_STREAMING_LOADING_REQUESTED_SEED").strip_edges()
	process_test_seed = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
	sample_id = OS.get_environment("VOXEL_WORLD_STREAMING_LOADING_SAMPLE_ID").strip_edges()
	configure_resolution()
	validate_environment()
	call_deferred("run")

func configure_resolution() -> void:
	var resolution := OS.get_environment("VOXEL_WORLD_STREAMING_LOADING_RESOLUTION").strip_edges()
	if resolution not in ["1280x720", "1920x1080"]:
		environment_errors.append("Resolution must be 1280x720 or 1920x1080")
		return
	var dimensions := resolution.split("x")
	requested_resolution = Vector2i(int(dimensions[0]), int(dimensions[1]))
	DisplayServer.window_set_size(requested_resolution)
	get_tree().root.size = requested_resolution

func validate_environment() -> void:
	if report_path == "" or not report_path.is_absolute_path():
		environment_errors.append("absolute sample report path required")
	if progress_path == "" or not progress_path.is_absolute_path():
		environment_errors.append("absolute sample progress path required")
	if run_token == "" or run_token.length() > 512:
		environment_errors.append("dedicated loading-matrix token required")
	if launch_mode not in ["new_game", "continue"]:
		environment_errors.append("mode must be new_game or continue")
	if cache_classification not in ["cold", "warm_continue"]:
		environment_errors.append("cache classification must be cold or warm_continue")
	if (launch_mode == "new_game") != (cache_classification == "cold"):
		environment_errors.append("New Game must be cold and Continue must be warm_continue")
	if requested_seed == "":
		environment_errors.append("matrix cohort requested seed is required")
	if process_test_seed == "":
		environment_errors.append("VOXEL_TEST_SEED process input is required")
	if OS.get_environment("VOXEL_PLAYTEST").strip_edges() != "":
		environment_errors.append("VOXEL_PLAYTEST must remain unset")
	for forbidden in ["VOXEL_NORMAL_RUNTIME_PERF_RUN_TOKEN", "VOXEL_RUNTIME_PERF_FAST_BOOT", "VOXEL_UNDERGROUND_VISUAL_FAST_BOOT", "VOXEL_DIGGING_VISUAL_FAST_BOOT"]:
		if OS.get_environment(forbidden).strip_edges() != "":
			environment_errors.append("forbidden inherited mode: %s" % forbidden)

func run() -> void:
	write_progress("start")
	if not environment_errors.is_empty():
		write_report(false, "invalid_environment")
		get_tree().quit(2)
		return
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	menu = MENU_SCENE.instantiate()
	if menu == null:
		write_report(false, "main_menu_instantiation_failed")
		get_tree().quit(1)
		return
	add_child(menu)
	for _frame in range(4):
		await get_tree().process_frame
	var button: Button = menu.get("new_game_button") as Button if launch_mode == "new_game" else menu.get("continue_button") as Button
	if button == null or not is_instance_valid(button) or button.disabled:
		write_report(false, "menu_button_unavailable")
		get_tree().quit(1)
		return
	input_started_usec = Time.get_ticks_usec()
	last_frame_usec = input_started_usec
	progress_heartbeat_last_usec = input_started_usec
	dispatch_menu_mouse_button(button.get_global_rect().get_center(), true)
	dispatch_menu_mouse_button(button.get_global_rect().get_center(), false)
	write_progress("menu_input:%s" % launch_mode)
	var deadline_usec := input_started_usec + int(MAX_STARTUP_SECONDS * 1000000.0)
	while Time.get_ticks_usec() < deadline_usec and not loading_completed and loading_failure == "":
		await get_tree().process_frame
		attach_main_if_available()
		if loading_completed or loading_failure != "":
			break
		observe_loading_frame()
	if not loading_completed and loading_failure == "":
		loading_failure = "startup_loading_timeout"
	if loading_completed:
		if main != null and is_instance_valid(main) and main.has_method("debug_performance_state"):
			main_callback_window_at_ready = main.call("debug_performance_state", false, false)
		for _frame in range(POST_READY_MODAL_OBSERVATION_FRAMES):
			await get_tree().process_frame
			post_ready_modal_observation_frames += 1
			if modal_visible():
				post_ready_modal_visible_frames += 1
	var saved := false
	if loading_completed and main != null and is_instance_valid(main):
		saved = persist_pairing_save()
		if not saved:
			loading_failure = "pairing_save_failed"
	var passed := loading_completed and loading_failure == "" and saved \
		and first_loading_usec > 0 and overlay_missing_frames == 0 \
		and post_ready_modal_visible_frames == 0
	write_report(passed, "completed" if passed else loading_failure)
	write_progress("complete" if passed else "failed:%s" % loading_failure)
	if main != null and is_instance_valid(main) and main.has_method("request_graceful_quit"):
		main.call("request_graceful_quit", 0 if passed else 1)
		return
	get_tree().quit(0 if passed else 1)

func dispatch_menu_mouse_button(position: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = position
	event.global_position = position
	get_viewport().push_input(event, true)

func attach_main_if_available() -> void:
	if main != null and is_instance_valid(main):
		return
	var active = menu.get("active_main") if menu != null and is_instance_valid(menu) else null
	if not (active is Node):
		return
	main = active
	var step_callback := Callable(self, "_on_loading_step")
	var completed_callback := Callable(self, "_on_loading_completed")
	var failed_callback := Callable(self, "_on_loading_failed")
	if main.has_signal("startup_loading_step") and not main.is_connected("startup_loading_step", step_callback):
		main.connect("startup_loading_step", step_callback)
	if main.has_signal("startup_loading_completed") and not main.is_connected("startup_loading_completed", completed_callback):
		main.connect("startup_loading_completed", completed_callback)
	if main.has_signal("startup_loading_failed") and not main.is_connected("startup_loading_failed", failed_callback):
		main.connect("startup_loading_failed", failed_callback)
	capture_startup_timeline()
	observe_completed_work()
	observe_main_callback_monitor(true)
	var domains = main.get("startup_readiness_domains")
	if domains is Dictionary and String(domains.get("gameplay", {}).get("status", "")) == "ready" and not bool(main.get("startup_loading_active")):
		_on_loading_completed()

func observe_loading_frame() -> void:
	var now_usec := Time.get_ticks_usec()
	if last_frame_usec > 0:
		frame_gap_ms.append(float(now_usec - last_frame_usec) / 1000.0)
	last_frame_usec = now_usec
	var visible := modal_visible()
	if visible != last_overlay_visible:
		overlay_visible_transitions += 1
		last_overlay_visible = visible
	if visible:
		overlay_visible_frames += 1
	else:
		overlay_missing_frames += 1
	if first_loading_usec <= 0 and bool(menu.get("launching")) and visible:
		first_loading_usec = now_usec
		write_progress("first_loading_frame")
	capture_startup_timeline()
	observe_completed_work()
	observe_main_callback_monitor(false)

func observe_completed_work() -> void:
	if main == null or not is_instance_valid(main) or input_started_usec <= 0:
		return
	var receipt = main.get("startup_work_progress_receipt")
	if not (receipt is Dictionary) or receipt.is_empty():
		return
	var revision := int(receipt.get("completedRevision", 0))
	if revision <= last_work_revision:
		return
	last_work_revision = revision
	var observed_usec := Time.get_ticks_usec()
	work_proof_rows.append({
		"owner": String(receipt.get("owner", "")),
		"completedRevision": revision,
		"completedCount": int(receipt.get("completedCount", -1)),
		"pendingWorkCount": int(receipt.get("pendingWorkCount", -1)),
		"completedAtTicksUsec": int(receipt.get("completedAtTicksUsec", 0)),
		"observedAtInputMs": float(observed_usec - input_started_usec) / 1000.0,
		"activeWorkAgeMs": float(observed_usec - int(receipt.get("completedAtTicksUsec", 0))) / 1000.0
	})

func capture_startup_timeline() -> void:
	if main == null or not is_instance_valid(main):
		return
	var timeline_value = main.get("startup_loading_timeline")
	if not (timeline_value is Array):
		return
	var retained: Array = timeline_value
	if not timeline_observation_started:
		timeline_observation_started = true
		timeline_initial_snapshot_size = retained.size()
		timeline_initial_snapshot_at_capacity = retained.size() >= STARTUP_TIMELINE_RETAINED_CAPACITY
	timeline_last_retained_size = retained.size()
	for value in retained:
		if not (value is Dictionary):
			continue
		var row: Dictionary = value
		var key := JSON.stringify(row)
		if observed_timeline_keys.has(key):
			continue
		observed_timeline_keys[key] = true
		observed_timeline_rows.append(row.duplicate(true))
		if input_started_usec > 0 and not loading_completed:
			var observed_usec := Time.get_ticks_usec()
			progress_heartbeat_max_gap_ms = maxf(progress_heartbeat_max_gap_ms,
				float(observed_usec - progress_heartbeat_last_usec) / 1000.0)
			progress_heartbeat_last_usec = observed_usec
			progress_heartbeat_count += 1
			progress_heartbeat_last_owner = String(row.get("domain", ""))
			progress_heartbeat_last_status = String(row.get("status", ""))
			progress_heartbeat_last_metrics = (row.get("metrics", {}) as Dictionary).duplicate(true) \
				if row.get("metrics", {}) is Dictionary else {}

func startup_timeline_observation() -> Dictionary:
	var all_retained_rows_observed := true
	if main != null and is_instance_valid(main) and main.get("startup_loading_timeline") is Array:
		for value in main.get("startup_loading_timeline"):
			if value is Dictionary and not observed_timeline_keys.has(JSON.stringify(value)):
				all_retained_rows_observed = false
				break
	var complete := timeline_observation_started and not timeline_initial_snapshot_at_capacity \
		and all_retained_rows_observed and not observed_timeline_rows.is_empty() and loading_completed
	return {
		"complete": complete,
		"truncated": not complete,
		"retainedCapacity": STARTUP_TIMELINE_RETAINED_CAPACITY,
		"initialSnapshotSize": timeline_initial_snapshot_size,
		"initialSnapshotAtCapacity": timeline_initial_snapshot_at_capacity,
		"lastRetainedSize": timeline_last_retained_size,
		"observedRowCount": observed_timeline_rows.size(),
		"allRetainedRowsObserved": all_retained_rows_observed
	}

func observe_main_callback_monitor(force := false) -> void:
	if main == null or not is_instance_valid(main):
		return
	var now_usec := Time.get_ticks_usec()
	if not force and main_monitor_last_poll_usec > 0 \
			and now_usec - main_monitor_last_poll_usec < MAIN_MONITOR_POLL_INTERVAL_USEC:
		return
	main_monitor_last_poll_usec = now_usec
	var monitor = main.get("runtime_perf_monitor")
	if monitor == null or not monitor.has_method("summary"):
		return
	var summary_value = monitor.call("summary")
	if not (summary_value is Dictionary):
		return
	var summary: Dictionary = summary_value
	var sample_count := int(summary.get("sampleCount", 0))
	if sample_count <= 0:
		return
	main_monitor_poll_count += 1
	main_monitor_max_sample_count = maxi(main_monitor_max_sample_count, sample_count)
	main_monitor_max_frame_ms = maxf(main_monitor_max_frame_ms, float(summary.get("frameMaxMs", 0.0)))

func modal_visible() -> bool:
	if menu == null or not is_instance_valid(menu):
		return false
	var overlay = menu.get("loading_overlay")
	return overlay is Control and is_instance_valid(overlay) and (overlay as Control).visible

func _on_loading_step(message: String) -> void:
	capture_startup_timeline()
	observe_completed_work()
	loading_signal_rows.append({
		"elapsedMs": elapsed_ms(input_started_usec),
		"message": message
	})

func _on_loading_completed() -> void:
	if loading_completed:
		return
	gameplay_ready_usec = Time.get_ticks_usec()
	capture_startup_timeline()
	if last_frame_usec > 0:
		frame_gap_ms.append(float(gameplay_ready_usec - last_frame_usec) / 1000.0)
		last_frame_usec = gameplay_ready_usec
	if progress_heartbeat_last_usec > 0:
		progress_heartbeat_max_gap_ms = maxf(progress_heartbeat_max_gap_ms,
			float(gameplay_ready_usec - progress_heartbeat_last_usec) / 1000.0)
	loading_completed = true
	observe_main_callback_monitor(true)

func _on_loading_failed(message: String) -> void:
	loading_failure = message if message != "" else "startup_loading_failed"

func persist_pairing_save() -> bool:
	if not main.has_method("create_save_snapshot") or main.get("save_system") == null:
		return false
	var snapshot: Dictionary = main.call("create_save_snapshot")
	return not snapshot.is_empty() and bool(main.get("save_system").call("save", String(main.get("seed_text")), snapshot))

func elapsed_ms(started_usec: int) -> float:
	return float(Time.get_ticks_usec() - started_usec) / 1000.0 if started_usec > 0 else 0.0

func percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty():
		return 0.0
	var ordered := values.duplicate()
	ordered.sort()
	var index := clampi(ceili(float(ordered.size()) * fraction) - 1, 0, ordered.size() - 1)
	return float(ordered[index])

func cadence_summary() -> Dictionary:
	return {
		"sampleCount": frame_gap_ms.size(),
		"p50Ms": percentile(frame_gap_ms, 0.50),
		"p95Ms": percentile(frame_gap_ms, 0.95),
		"p99Ms": percentile(frame_gap_ms, 0.99),
		"maxMs": frame_gap_ms.max() if not frame_gap_ms.is_empty() else 0.0
	}

func stage_distribution(timeline: Array) -> Dictionary:
	var distributions := {}
	for value in timeline:
		if not (value is Dictionary):
			continue
		var row: Dictionary = value
		var domain := String(row.get("domain", "general"))
		if not distributions.has(domain):
			distributions[domain] = {"count": 0, "totalStepMs": 0.0, "maxStepMs": 0.0, "stepMs": []}
		var aggregate: Dictionary = distributions[domain]
		var step_ms := float(row.get("stepMs", 0.0))
		aggregate["count"] = int(aggregate.get("count", 0)) + 1
		aggregate["totalStepMs"] = float(aggregate.get("totalStepMs", 0.0)) + step_ms
		aggregate["maxStepMs"] = maxf(float(aggregate.get("maxStepMs", 0.0)), step_ms)
		(aggregate.get("stepMs") as Array).append(step_ms)
		distributions[domain] = aggregate
	for domain in distributions.keys():
		var aggregate: Dictionary = distributions[domain]
		var values: Array[float] = []
		for value in aggregate.get("stepMs", []):
			values.append(float(value))
		aggregate["p50StepMs"] = percentile(values, 0.50)
		aggregate["p95StepMs"] = percentile(values, 0.95)
		aggregate.erase("stepMs")
	return distributions

func write_report(passed: bool, reason: String) -> void:
	if report_path == "":
		return
	var timeline: Array = observed_timeline_rows.duplicate(true)
	var readiness := {}
	var max_step := {}
	var actual_seed := ""
	if main != null and is_instance_valid(main):
		if main.get("startup_readiness_domains") is Dictionary:
			readiness = (main.get("startup_readiness_domains") as Dictionary).duplicate(true)
		if main.get("startup_loading_max_step") is Dictionary:
			max_step = (main.get("startup_loading_max_step") as Dictionary).duplicate(true)
		actual_seed = String(main.get("seed_text"))
	var logical_viewport_resolution := Vector2i(get_tree().root.get_visible_rect().size)
	var native_window_resolution := DisplayServer.window_get_size()
	# Window.size is the renderer output target. The visible rect is the logical
	# canvas and may intentionally remain 1280x720 under canvas-item stretch.
	var render_target_resolution := get_tree().root.size
	var report := {
		"schema": REPORT_SCHEMA,
		"finished": true,
		"passed": passed,
		"reason": reason,
		"sampleId": sample_id,
		"launchMode": launch_mode,
		"cacheClassification": cache_classification,
		"requestedTestSeed": requested_seed,
		"processTestSeed": process_test_seed,
		"actualSeed": actual_seed,
		"runTokenPresent": run_token != "",
		"voxelPlaytest": OS.get_environment("VOXEL_PLAYTEST").strip_edges(),
		"savePathOverride": OS.get_environment("VOXEL_SAVE_PATH_OVERRIDE").strip_edges(),
		"timing": {
			"inputToFirstLoadingFrameMs": float(first_loading_usec - input_started_usec) / 1000.0 if first_loading_usec > 0 else 0.0,
			"inputToGameplayReadyMs": float(gameplay_ready_usec - input_started_usec) / 1000.0 if gameplay_ready_usec > 0 else 0.0,
			"loadingFrameCadence": cadence_summary(),
			"loadingSignalRows": loading_signal_rows,
			"startupTimeline": timeline,
			"stageDistributions": stage_distribution(timeline),
			"loadingCallbackIntervalMax": max_step,
			"timelineObservation": startup_timeline_observation(),
			"timelineActivity": {
				"source": "MainCore.startup_loading_timeline",
				"count": progress_heartbeat_count,
				"maxGapMs": progress_heartbeat_max_gap_ms,
				"lastOwner": progress_heartbeat_last_owner,
				"lastStatus": progress_heartbeat_last_status,
				"lastMetrics": progress_heartbeat_last_metrics
			},
			"progressHeartbeat": {
				"source": "MainCore.startup_work_progress_revision",
				"verified": not work_proof_rows.is_empty(),
				"reason": "source_owned_completed_publication_or_ready_transition",
				"workProofRows": work_proof_rows
			}
		},
		"mainCallbackWindowAtReady": main_callback_window_at_ready,
		"loadingMainCallbackObservation": {
			"complete": main_monitor_poll_count > 0 and main_monitor_max_sample_count > 0,
			"pollIntervalMs": float(MAIN_MONITOR_POLL_INTERVAL_USEC) / 1000.0,
			"pollCount": main_monitor_poll_count,
			"maxObservedMonitorSampleCount": main_monitor_max_sample_count,
			"maxObservedFrameMs": main_monitor_max_frame_ms,
			"scope": "RuntimePerformanceMonitor rolling window polled throughout the full menu-input-to-gameplay-ready interval"
		},
		"modal": {
			"overlayVisibleFrames": overlay_visible_frames,
			"overlayMissingFramesDuringLoading": overlay_missing_frames,
			"visibilityTransitionsDuringLoading": overlay_visible_transitions,
			"postReadyModalVisibleFrames": post_ready_modal_visible_frames,
			"postReadyObservationFramesRequested": POST_READY_MODAL_OBSERVATION_FRAMES,
			"postReadyObservationFramesObserved": post_ready_modal_observation_frames,
			"reenteredAfterGameplayReady": post_ready_modal_visible_frames > 0
		},
		"startupReadinessDomains": readiness,
		"environmentErrors": environment_errors,
		"runtime": {
			"engine": Engine.get_version_info(),
			"displayServer": DisplayServer.get_name(),
			"renderingMethod": RenderingServer.get_current_rendering_method(),
			"renderingDriver": RenderingServer.get_current_rendering_driver_name(),
			"videoAdapter": RenderingServer.get_video_adapter_name(),
			"requestedResolution": [requested_resolution.x, requested_resolution.y],
			"nativeWindowResolution": [native_window_resolution.x, native_window_resolution.y],
			"renderTargetResolution": [render_target_resolution.x, render_target_resolution.y],
			"logicalViewportResolution": [logical_viewport_resolution.x, logical_viewport_resolution.y],
			"resolutionScope": "nativeWindowResolution and renderTargetResolution are pass-affecting; logicalViewportResolution is the stretched UI canvas"
		}
	}
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()

func write_progress(message: String) -> void:
	if progress_path == "":
		return
	DirAccess.make_dir_recursive_absolute(progress_path.get_base_dir())
	var file := FileAccess.open(progress_path, FileAccess.WRITE)
	if file != null:
		file.store_string("%s %s\n" % [Time.get_datetime_string_from_system(true), message])
		file.close()
