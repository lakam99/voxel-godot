extends "res://scripts/testing/buildings/CitadelUrbanPocRunner.gd"
## Unheaded real-publication/physics diagnostic for the three camera poses that
## failed the last approved headed review. It never captures pixels and never
## treats a failed pose as a fixture/runtime failure.

const AUDIT_VIEW_IDS := ["outer_approach", "civic_overview", "perimeter_lane"]
const RADIAL_CANDIDATE_LIMIT := 64
const PERIMETER_SOURCE_LIMIT := 6
const TOTAL_CANDIDATE_LIMIT := 512

var audit_report_path := ""
var audit_progress_path := ""
var _audit_guard: Timer
var _latest_readiness: Dictionary = {}
var _latest_report: Dictionary = {}


func _ready() -> void:
	_audit_guard = Timer.new()
	_audit_guard.one_shot = true
	_audit_guard.timeout.connect(_on_audit_guard_timeout)
	add_child(_audit_guard)
	_audit_guard.start(470.0)
	await super._ready()


func read_arguments() -> void:
	super.read_arguments()
	audit_report_path = OS.get_environment("VOXEL_CITADEL_FAILED_CAMERA_AUDIT_REPORT")
	audit_progress_path = OS.get_environment("VOXEL_CITADEL_FAILED_CAMERA_AUDIT_PROGRESS")
	report_path = audit_report_path


static func audit_view_specs() -> Array[Dictionary]:
	return [
		{"id": "outer_approach", "subject": "gatehouse", "idPrefix": "castle_gatehouse_lintel", "semantic": "", "maximumDistance": 30.0, "minimumDistance": 8.0, "preferredDistance": 18.0, "subjectRadius": 4.5, "preferredDirectionIndex": 0},
		{"id": "civic_overview", "subject": "civic roofline", "idPrefix": "urban_civic_tower", "semantic": "citadel_civic_landmark", "maximumDistance": 34.0, "minimumDistance": 8.0, "preferredDistance": 22.0, "subjectRadius": 6.0, "preferredDirectionIndex": 0},
	]


func write_automated_report() -> void:
	var readiness := await wait_for_capture_readiness()
	_latest_readiness = readiness.duplicate(true)
	var report := _initial_audit_report(readiness)
	_latest_report = report
	_write_audit_progress("readiness_complete", {"readiness": readiness})
	if selected_seed != 208159 or not is_equal_approx(selected_citadel_scale, 1.25):
		_finish_audit_failure(report, "unexpected_fixture_identity", 1)
		return
	if not bool(readiness.get("ready", false)):
		_finish_audit_failure(report, "readiness_failed", 1)
		return
	var snapshot := build_review_visual_snapshot()
	var snapshot_summary := review_visual_snapshot_summary()
	report["reviewVisualSnapshot"] = snapshot_summary
	_write_audit_progress("visual_snapshot_complete", {"reviewVisualSnapshot": snapshot_summary})
	if not bool(snapshot.get("valid", false)) or not bool(snapshot_summary.get("valid", false)) or String(snapshot_summary.get("binding", "")).is_empty() or int(snapshot_summary.get("epoch", 0)) <= 0:
		_finish_audit_failure(report, "visual_snapshot_failed", 1)
		return
	var rows: Array[Dictionary] = []
	var total_candidates := 0
	for spec_value in audit_view_specs():
		var spec: Dictionary = spec_value
		var radial := begin_radial_audit_job(spec)
		if not bool(radial.get("valid", false)):
			report["views"] = rows
			report["totalCandidatesEvaluated"] = total_candidates
			_finish_audit_failure(report, String(radial.get("reason", "invalid_radial_subject")), 1)
			return
		var radial_result := await advance_radial_audit(radial, total_candidates)
		if not bool(radial_result.get("operational", false)):
			report["views"] = rows
			report["totalCandidatesEvaluated"] = int(radial_result.get("aggregateCandidatesEvaluated", total_candidates))
			_finish_audit_failure(report, String(radial_result.get("reason", "radial_audit_failed")), 1)
			return
		total_candidates = int(radial_result.aggregateCandidatesEvaluated)
		rows.append(radial_result.row)
		report["views"] = rows.duplicate(true)
		report["totalCandidatesEvaluated"] = total_candidates
		_write_audit_progress("view_complete", {"view": radial_result.row, "totalCandidatesEvaluated": total_candidates})
	var collection := generated_perimeter_review_sources(12.0, 22.0)
	var source_validation := validate_perimeter_sources(collection)
	if not bool(source_validation.get("valid", false)):
		report["views"] = rows
		report["totalCandidatesEvaluated"] = total_candidates
		_finish_audit_failure(report, String(source_validation.get("reason", "invalid_perimeter_sources")), 1)
		return
	var perimeter_result := await advance_perimeter_audit(source_validation.sources as Array, total_candidates)
	if not bool(perimeter_result.get("operational", false)):
		report["views"] = rows
		report["totalCandidatesEvaluated"] = int(perimeter_result.get("aggregateCandidatesEvaluated", total_candidates))
		_finish_audit_failure(report, String(perimeter_result.get("reason", "perimeter_audit_failed")), 1)
		return
	total_candidates = int(perimeter_result.aggregateCandidatesEvaluated)
	rows.append(perimeter_result.row)
	report["views"] = rows
	report["totalCandidatesEvaluated"] = total_candidates
	report["allViewsTerminal"] = rows.size() == AUDIT_VIEW_IDS.size() and rows.all(func(row: Dictionary): return bool(row.get("terminal", false)))
	report["allPosesPassed"] = bool(report.allViewsTerminal) and rows.all(func(row: Dictionary): return bool(row.get("poseOk", false)))
	if not bool(report.allViewsTerminal) or total_candidates > TOTAL_CANDIDATE_LIMIT:
		_finish_audit_failure(report, "nonterminal_or_over_budget_audit", 1)
		return
	report["status"] = "audit_complete"
	report["terminalReason"] = "all_three_views_terminal"
	_write_audit_progress("audit_complete", {"totalCandidatesEvaluated": total_candidates, "allPosesPassed": report.allPosesPassed})
	_write_audit_report(report, 0)


func begin_radial_audit_job(spec: Dictionary) -> Dictionary:
	if String(spec.get("id", "")) not in ["outer_approach", "civic_overview"]:
		return {"valid": false, "reason": "unexpected_radial_view_id"}
	var part = deterministic_review_part(String(spec.get("idPrefix", "")), String(spec.get("semantic", "")))
	if part == null:
		return {"valid": false, "reason": "missing_generated_review_subject"}
	var bounds := review_part_bounds(part)
	var target := generated_review_focus(part, bounds)
	var radial := generated_subject_radial_domain(bounds, float(spec.maximumDistance), float(spec.minimumDistance), float(spec.preferredDistance), float(spec.subjectRadius))
	var subject_ids := [String(part.id)]
	var job := begin_exterior_review_pose(target, float(radial.minimumDistance), float(radial.preferredDistance), float(radial.subjectRadius), int(spec.preferredDirectionIndex), -INF, Callable(self, "generated_subject_readability_rejection").bind(subject_ids, target), Callable(self, "generated_part_visible_surface").bind(String(part.id)))
	if job._candidate_positions.size() != RADIAL_CANDIDATE_LIMIT:
		return {"valid": false, "reason": "invalid_radial_candidate_domain"}
	for id_value in subject_ids:
		job._declared_subject_ids.append(String(id_value))
	job._visual_snapshot_binding = review_visual_snapshot_binding()
	job._visual_snapshot_epoch = int(review_visual_snapshot_summary().get("epoch", 0))
	if job._visual_snapshot_binding.is_empty() or job._visual_snapshot_epoch <= 0:
		return {"valid": false, "reason": "missing_radial_snapshot_binding"}
	return {"valid": true, "spec": spec.duplicate(true), "partId": String(part.id), "bounds": bounds, "target": target, "radial": radial, "job": job, "candidateOrder": job._candidate_positions.duplicate(true)}


func advance_radial_audit(radial: Dictionary, aggregate_before: int) -> Dictionary:
	var job: ReviewCameraJob = radial.get("job", null)
	if job == null:
		return {"operational": false, "reason": "missing_radial_job", "aggregateCandidatesEvaluated": aggregate_before}
	var progress: Dictionary = {}
	var evaluated := 0
	while evaluated < RADIAL_CANDIDATE_LIMIT and aggregate_before + evaluated < TOTAL_CANDIDATE_LIMIT:
		progress = advance_exterior_review_pose(job, 1)
		var step_count := int(progress.get("candidatesEvaluated", -1))
		if not bool(progress.get("valid", false)) or step_count < 0 or step_count > 1:
			return {"operational": false, "reason": String(progress.get("reason", "invalid_radial_progress")), "aggregateCandidatesEvaluated": aggregate_before + evaluated, "progress": progress}
		evaluated += step_count
		if bool(progress.get("complete", false)):
			break
		if step_count != 1:
			return {"operational": false, "reason": "nonterminal_radial_zero_work", "aggregateCandidatesEvaluated": aggregate_before + evaluated, "progress": progress}
		await get_tree().process_frame
	if not bool(progress.get("complete", false)):
		return {"operational": false, "reason": "radial_candidate_cap_exhausted_nonterminal", "aggregateCandidatesEvaluated": aggregate_before + evaluated, "progress": progress}
	var pose: Dictionary = progress.get("pose", {}) as Dictionary
	var spec: Dictionary = radial.spec
	var row := {"id": String(spec.id), "terminal": true, "poseOk": bool(pose.get("ok", false)), "reason": String(pose.get("reason", "")), "partId": String(radial.partId), "subjectBounds": radial.bounds, "target": radial.target, "radialDomain": radial.radial, "candidateLimit": RADIAL_CANDIDATE_LIMIT, "candidatesEvaluated": evaluated, "candidateOrder": radial.candidateOrder, "rejectedCandidates": (pose.get("rejectedCandidates", {}) as Dictionary).duplicate(true), "rejectionExamples": (pose.get("rejectionExamples", []) as Array).duplicate(true), "stageRejectionEvidence": (pose.get("stageRejectionEvidence", {}) as Dictionary).duplicate(true), "phaseTelemetry": (progress.get("phaseTelemetry", {}) as Dictionary).duplicate(true), "snapshotBinding": job._visual_snapshot_binding, "snapshotEpoch": job._visual_snapshot_epoch}
	return {"operational": true, "row": row, "aggregateCandidatesEvaluated": aggregate_before + evaluated}


func validate_perimeter_sources(collection: Dictionary) -> Dictionary:
	if not bool(collection.get("valid", false)):
		return {"valid": false, "reason": String(collection.get("reason", "invalid_perimeter_collection"))}
	var sources: Array = collection.get("sources", []) as Array
	if sources.is_empty() or sources.size() > PERIMETER_SOURCE_LIMIT:
		return {"valid": false, "reason": "perimeter_eligible_source_cap_exceeded", "sourceCount": sources.size()}
	for source_value in sources:
		if not source_value is Dictionary:
			return {"valid": false, "reason": "invalid_perimeter_source_record"}
		var source: Dictionary = source_value
		var candidates: Array = source.get("candidatePositions", []) as Array
		if candidates.is_empty() or candidates.size() > RADIAL_CANDIDATE_LIMIT:
			return {"valid": false, "reason": "invalid_perimeter_candidate_domain", "sourceId": String(source.get("sourceId", "")), "candidateCount": candidates.size()}
		if String(source.get("visualSnapshotBinding", "")) != review_visual_snapshot_binding() or int(source.get("visualSnapshotEpoch", 0)) != int(review_visual_snapshot_summary().get("epoch", 0)):
			return {"valid": false, "reason": "stale_perimeter_source_binding"}
	var ordered := sources.duplicate(false)
	ordered.sort_custom(func(a: Dictionary, b: Dictionary): return String(a.get("sourceId", a.get("alleyId", ""))) < String(b.get("sourceId", b.get("alleyId", ""))))
	return {"valid": true, "sources": ordered, "sourceCount": ordered.size()}


func advance_perimeter_audit(sources: Array, aggregate_before: int) -> Dictionary:
	var job := begin_bounded_perimeter_review_job(sources)
	var progress: Dictionary = {}
	var evaluated := 0
	var perimeter_cap := mini(PERIMETER_SOURCE_LIMIT * RADIAL_CANDIDATE_LIMIT, TOTAL_CANDIDATE_LIMIT - aggregate_before)
	while evaluated < perimeter_cap:
		progress = advance_bounded_perimeter_review_job(job, 1)
		var step_count := int(progress.get("candidatesEvaluated", -1))
		if not bool(progress.get("valid", false)) or step_count < 0 or step_count > 1:
			return {"operational": false, "reason": String(progress.get("reason", "invalid_perimeter_progress")), "aggregateCandidatesEvaluated": aggregate_before + evaluated, "progress": progress}
		evaluated += step_count
		if bool(progress.get("complete", false)):
			break
		if step_count != 1:
			return {"operational": false, "reason": "nonterminal_perimeter_zero_work", "aggregateCandidatesEvaluated": aggregate_before + evaluated, "progress": progress}
		await get_tree().process_frame
	if not bool(progress.get("complete", false)):
		return {"operational": false, "reason": "total_or_perimeter_candidate_cap_exhausted_nonterminal", "aggregateCandidatesEvaluated": aggregate_before + evaluated, "progress": progress}
	var selection: Dictionary = progress.get("result", {}) as Dictionary
	var pose: Dictionary = selection.get("pose", {}) as Dictionary
	var source_telemetry: Array = selection.get("sourceTelemetry", []) as Array
	var aggregate_rejections: Dictionary = {}
	var aggregate_examples: Array[Dictionary] = []
	for telemetry_value in source_telemetry:
		var telemetry: Dictionary = telemetry_value
		for key in (telemetry.get("rejectedCandidates", {}) as Dictionary).keys():
			aggregate_rejections[key] = int(aggregate_rejections.get(key, 0)) + int((telemetry.rejectedCandidates as Dictionary).get(key, 0))
		for example_value in telemetry.get("rejectionExamples", []):
			if aggregate_examples.size() >= 8:
				break
			var example: Dictionary = (example_value as Dictionary).duplicate(true)
			example["sourceId"] = String(telemetry.get("sourceId", ""))
			aggregate_examples.append(example)
	var source_candidate_order: Array[Dictionary] = []
	for source_value in sources:
		var source: Dictionary = source_value
		source_candidate_order.append({"sourceId": String(source.get("sourceId", source.get("alleyId", ""))), "candidatePositions": (source.get("candidatePositions", []) as Array).duplicate(true)})
	var row := {"id": "perimeter_lane", "terminal": true, "poseOk": bool(selection.get("valid", false)) and bool(pose.get("ok", false)), "reason": String(selection.get("reason", "")), "sourceLimit": PERIMETER_SOURCE_LIMIT, "sourceCount": sources.size(), "sourceOrder": sources.map(func(source: Dictionary): return String(source.get("sourceId", source.get("alleyId", "")))), "sourceCandidateOrder": source_candidate_order, "candidateLimitPerSource": RADIAL_CANDIDATE_LIMIT, "candidatesEvaluated": evaluated, "sourceTelemetry": source_telemetry.duplicate(true), "rejectedCandidates": aggregate_rejections, "rejectionExamples": aggregate_examples, "phaseTelemetry": (progress.get("phaseTelemetry", {}) as Dictionary).duplicate(true), "snapshotBinding": job._visual_snapshot_binding, "snapshotEpoch": job._visual_snapshot_epoch}
	return {"operational": true, "row": row, "aggregateCandidatesEvaluated": aggregate_before + evaluated}


func _initial_audit_report(readiness: Dictionary) -> Dictionary:
	return {"schemaVersion": 1, "runnerId": "citadel_failed_camera_pose_audit", "evidenceLevel": "unheaded_real_publication_physics_camera_pose_diagnostic_not_rendered_visual_acceptance", "status": "running", "terminalReason": "", "seed": selected_seed, "citadelScale": selected_citadel_scale, "captureReadiness": readiness, "reviewVisualSnapshot": {}, "requestedViewIds": AUDIT_VIEW_IDS.duplicate(), "limits": {"radialCandidatesPerView": RADIAL_CANDIDATE_LIMIT, "perimeterSources": PERIMETER_SOURCE_LIMIT, "perimeterCandidatesPerSource": RADIAL_CANDIDATE_LIMIT, "totalCandidates": TOTAL_CANDIDATE_LIMIT, "candidatesPerAdvance": 1}, "views": [], "totalCandidatesEvaluated": 0, "allViewsTerminal": false, "allPosesPassed": false, "doesNotProve": "Rendered pixels or visual quality, headed/live gameplay, player access, NPC behavior, navigation, or any view outside the three requested camera-pose diagnostics."}


func _finish_audit_failure(report: Dictionary, reason: String, exit_code: int) -> void:
	report["status"] = "audit_failed"
	report["terminalReason"] = reason
	_write_audit_progress("audit_failed", {"reason": reason})
	_write_audit_report(report, exit_code)


func _write_audit_progress(stage: String, details: Dictionary) -> void:
	if audit_progress_path.is_empty() or not audit_progress_path.is_absolute_path():
		return
	var file := FileAccess.open(audit_progress_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"schemaVersion": 1, "stage": stage, "seed": selected_seed, "citadelScale": selected_citadel_scale, "details": details.duplicate(true)}, "  "))
		file.close()


func _write_audit_report(report: Dictionary, exit_code: int) -> void:
	_latest_report = report.duplicate(true)
	if _audit_guard != null:
		_audit_guard.stop()
	if audit_report_path.is_empty() or not audit_report_path.is_absolute_path():
		get_tree().quit(2)
		return
	DirAccess.make_dir_recursive_absolute(audit_report_path.get_base_dir())
	var file := FileAccess.open(audit_report_path, FileAccess.WRITE)
	if file == null:
		get_tree().quit(2)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	get_tree().quit(exit_code)


func _on_audit_guard_timeout() -> void:
	var report := _latest_report.duplicate(true) if not _latest_report.is_empty() else _initial_audit_report(_latest_readiness)
	report["status"] = "audit_failed"
	report["terminalReason"] = "fixture_owned_terminal_guard_timeout"
	_write_audit_progress("audit_failed", {"reason": report.terminalReason})
	_write_audit_report(report, 3)
