extends "res://scripts/testing/buildings/CitadelUrbanPocRunner.gd"
## Real publication/physics profiling only. This fixture never claims camera,
## visual, gameplay, navigation, or NPC acceptance.

const PROFILE_SOURCE_LIMIT := 1
const PROFILE_CANDIDATE_LIMIT := 4

var profile_report_path := ""
var profile_progress_path := ""
var _profile_guard: Timer
var _latest_readiness: Dictionary = {}


func _ready() -> void:
	_profile_guard = Timer.new()
	_profile_guard.one_shot = true
	_profile_guard.timeout.connect(_on_profile_guard_timeout)
	add_child(_profile_guard)
	_profile_guard.start(450.0)
	await super._ready()
	if _profile_guard != null and not _profile_guard.is_stopped():
		_profile_guard.start(60.0)


func read_arguments() -> void:
	super.read_arguments()
	profile_report_path = OS.get_environment("VOXEL_CITADEL_CAMERA_PROFILE_REPORT")
	profile_progress_path = OS.get_environment("VOXEL_CITADEL_CAMERA_PROFILE_PROGRESS")
	report_path = profile_report_path


func write_automated_report() -> void:
	_write_profile_progress("readiness_begin", {})
	var readiness := await wait_for_capture_readiness()
	_latest_readiness = readiness.duplicate(true)
	_write_profile_progress("readiness_complete", {"readiness": readiness})
	var report := build_initial_profile_report(readiness)
	if not bool(readiness.get("ready", false)):
		report["status"] = "readiness_failed"
		_write_profile_report(report, 1)
		return
	_write_profile_progress("visual_snapshot_begin", {"readiness": readiness})
	var snapshot := build_review_visual_snapshot()
	report["reviewVisualSnapshot"] = review_visual_snapshot_summary()
	_write_profile_progress("visual_snapshot_complete", {"reviewVisualSnapshot": report.reviewVisualSnapshot})
	if not bool(snapshot.get("valid", false)):
		report["status"] = "visual_snapshot_failed"
		_write_profile_report(report, 1)
		return
	var derivation_started := Time.get_ticks_usec()
	_write_profile_progress("source_derivation_begin", {"readiness": readiness})
	var collection := generated_perimeter_review_sources(12.0, 22.0)
	var derivation_usec := Time.get_ticks_usec() - derivation_started
	report["sourceDerivationUsec"] = derivation_usec
	report["eligibleSourceCount"] = (collection.get("sources", []) as Array).size()
	_write_profile_progress("source_derivation_complete", {"sourceDerivationUsec": derivation_usec, "collection": {"valid": collection.get("valid", false), "reason": collection.get("reason", ""), "sourceCount": collection.get("sourceCount", 0), "eligibleSourceCount": report.eligibleSourceCount}})
	var sources: Array = collection.get("sources", []) as Array
	if not bool(collection.get("valid", false)) or sources.is_empty():
		report["status"] = "source_derivation_failed"
		_write_profile_report(report, 1)
		return
	var source: Dictionary = (sources[0] as Dictionary).duplicate(false)
	var candidates: Array = source.get("candidatePositions", []) as Array
	report["selectedSource"] = {"sourceId": String(source.get("sourceId", source.get("alleyId", ""))), "alleyId": String(source.get("alleyId", "")), "facadeId": String(source.get("facadeId", "")), "supportIds": (source.get("supportIds", []) as Array).duplicate(true), "candidateCount": candidates.size()}
	report["candidateOrder"] = candidates.slice(0, mini(PROFILE_CANDIDATE_LIMIT, candidates.size())).duplicate(true)
	var job := begin_bounded_perimeter_review_job([source])
	var profiles: Array[Dictionary] = []
	var progress: Dictionary = {}
	var prior_rejected: Dictionary = {}
	for candidate_index in range(mini(PROFILE_CANDIDATE_LIMIT, candidates.size())):
		progress = advance_bounded_perimeter_review_job(job, 1)
		var rejected: Dictionary = {}
		if job._active_camera_job is ReviewCameraJob:
			rejected = (job._active_camera_job as ReviewCameraJob)._rejected.duplicate(true)
		var rejection_delta: Dictionary = {}
		for key in rejected:
			var delta := int(rejected.get(key, 0)) - int(prior_rejected.get(key, 0))
			if delta > 0:
				rejection_delta[key] = delta
		prior_rejected = rejected
		var phase_telemetry: Dictionary = progress.get("phaseTelemetry", {}) as Dictionary
		profiles.append({"candidateIndex": candidate_index, "candidatePosition": candidates[candidate_index], "elapsedUsec": int(progress.get("maxCandidateUsec", 0)), "rejectionDelta": rejection_delta, "complete": bool(progress.get("complete", false)), "result": (progress.get("result", {}) as Dictionary).duplicate(true), "phaseRows": (phase_telemetry.get("latestAdvance", {}) as Dictionary).duplicate(true), "visits": _profile_phase_visits(phase_telemetry.get("latestAdvance", {}) as Dictionary)})
		report["candidateProfiles"] = profiles.duplicate(true)
		report["finalProgress"] = progress.duplicate(true)
		_write_profile_progress("candidate_complete", {"candidateIndex": candidate_index, "selectedSource": report.selectedSource, "progress": progress, "candidateProfile": profiles.back()})
		if bool(progress.get("complete", false)):
			break
		await get_tree().process_frame
	report["status"] = "profile_complete"
	_write_profile_report(report, 0)


func build_initial_profile_report(readiness: Dictionary) -> Dictionary:
	return {
		"schemaVersion": 1,
		"runnerId": "citadel_perimeter_camera_profile",
		"evidenceLevel": "unheaded_real_publication_physics_profile_not_camera_visual_gameplay_navigation_or_npc_acceptance",
		"seed": selected_seed,
		"citadelScale": selected_citadel_scale,
		"sourceLimit": PROFILE_SOURCE_LIMIT,
		"candidateLimit": PROFILE_CANDIDATE_LIMIT,
		"captureReadiness": readiness,
		"sourceDerivationUsec": 0,
		"eligibleSourceCount": 0,
		"selectedSource": {},
		"candidateOrder": [],
		"candidateProfiles": [],
		"finalProgress": {},
		"context": {
			"expectedPartCount": blueprint.parts.size() if blueprint != null else 0,
			"publishedPartCount": int((building_publisher.summary() if building_publisher != null else {}).get("publishedPartCount", 0))
		},
		"doesNotProve": "Camera composition, rendered visuals, gameplay, navigation, NPC behavior, or Milestone 6 acceptance."
	}


func _profile_phase_visits(rows: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for phase_value in REVIEW_CAMERA_PHASES:
		var phase := String(phase_value)
		result[phase] = ((rows.get(phase, {}) as Dictionary).get("visits", {}) as Dictionary).duplicate(true)
	return result


func _write_profile_progress(stage: String, details: Dictionary) -> void:
	if profile_progress_path.is_empty() or not profile_progress_path.is_absolute_path():
		return
	var payload := {"schemaVersion": 1, "stage": stage, "seed": selected_seed, "citadelScale": selected_citadel_scale, "sourceLimit": PROFILE_SOURCE_LIMIT, "candidateLimit": PROFILE_CANDIDATE_LIMIT, "details": details.duplicate(true)}
	var file := FileAccess.open(profile_progress_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(payload, "  "))
		file.close()


func _write_profile_report(report: Dictionary, exit_code: int) -> void:
	if _profile_guard != null:
		_profile_guard.stop()
	if profile_report_path.is_empty() or not profile_report_path.is_absolute_path():
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(profile_report_path.get_base_dir())
	var file := FileAccess.open(profile_report_path, FileAccess.WRITE)
	if file == null:
		get_tree().quit(2)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	get_tree().quit(exit_code)


func _on_profile_guard_timeout() -> void:
	var report := build_initial_profile_report(_latest_readiness)
	report["status"] = "fixture_failed_before_profile"
	report["failureReason"] = "fixture_owned_terminal_guard_timeout"
	_write_profile_progress("fixture_failed_before_profile", {"readiness": _latest_readiness, "reason": report.failureReason})
	_write_profile_report(report, 3)
