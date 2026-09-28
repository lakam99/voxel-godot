extends SceneTree

## Synthetic control contract for the unheaded failed-pose audit fixture. No
## real publication, physics, capture, rendered image, NPC or navigation work.
const Audit = preload("res://scripts/testing/buildings/CitadelFailedCameraPoseAudit.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")

class OrchestrationProfile extends Audit:
	var readiness_ready := true
	var snapshot_valid := true
	var radial_begin_calls := 0
	var perimeter_source_calls := 0
	var reports: Array[Dictionary] = []
	var exit_codes: Array[int] = []
	var events: Array[String] = []
	func _ready() -> void: pass
	func wait_for_capture_readiness() -> Dictionary:
		events.append("readiness")
		return {"ready": readiness_ready}
	func build_review_visual_snapshot() -> Dictionary:
		events.append("snapshot")
		return {"valid": snapshot_valid}
	func review_visual_snapshot_summary() -> Dictionary:
		return {"valid": snapshot_valid, "binding": "audit.synthetic.binding" if snapshot_valid else "", "epoch": 1 if snapshot_valid else 0, "buildUsec": 11}
	func review_visual_snapshot_binding() -> String:
		return "audit.synthetic.binding" if snapshot_valid else ""
	func begin_radial_audit_job(spec: Dictionary) -> Dictionary:
		radial_begin_calls += 1
		return {"valid": true, "spec": spec.duplicate(true)}
	func advance_radial_audit(radial: Dictionary, aggregate_before: int) -> Dictionary:
		var spec: Dictionary = radial.spec
		return {"operational": true, "aggregateCandidatesEvaluated": aggregate_before + 1, "row": {"id": String(spec.id), "terminal": true, "poseOk": true, "candidatesEvaluated": 1}}
	func generated_perimeter_review_sources(_preferred_distance: float = 12.0, _maximum_distance: float = 22.0) -> Dictionary:
		perimeter_source_calls += 1
		return {"valid": true, "sources": [{"sourceId": "perimeter_a"}]}
	func validate_perimeter_sources(collection: Dictionary) -> Dictionary:
		return {"valid": true, "sources": (collection.get("sources", []) as Array).duplicate(true)}
	func advance_perimeter_audit(_sources: Array, aggregate_before: int) -> Dictionary:
		return {"operational": true, "aggregateCandidatesEvaluated": aggregate_before + 1, "row": {"id": "perimeter_lane", "terminal": true, "poseOk": true, "candidatesEvaluated": 1}}
	func _write_audit_progress(stage: String, _details: Dictionary) -> void:
		events.append("progress:" + stage)
	func _write_audit_report(report: Dictionary, exit_code: int) -> void:
		reports.append(report.duplicate(true))
		exit_codes.append(exit_code)

class SyntheticPerimeterJob extends RefCounted:
	var _visual_snapshot_binding := "audit.synthetic.binding"
	var _visual_snapshot_epoch := 1

class IncrementalProfile extends Audit:
	var radial_terminal_at := 3
	var perimeter_terminal_at := 3
	var radial_calls := 0
	var perimeter_calls := 0
	var radial_steps: Array[int] = []
	var perimeter_steps: Array[int] = []
	func _ready() -> void: pass
	func advance_exterior_review_pose(_job: Variant, max_candidates: int = 1) -> Dictionary:
		radial_steps.append(max_candidates)
		radial_calls += 1
		var complete := radial_calls >= radial_terminal_at
		return {"valid": true, "complete": complete, "candidatesEvaluated": 1, "totalCandidatesEvaluated": radial_calls, "pose": {"ok": complete, "reason": "" if complete else "pending", "rejectedCandidates": {}, "rejectionExamples": []}, "phaseTelemetry": {}}
	func begin_bounded_perimeter_review_job(_sources: Array):
		return SyntheticPerimeterJob.new()
	func advance_bounded_perimeter_review_job(_job: Variant, max_candidates: int = 1) -> Dictionary:
		perimeter_steps.append(max_candidates)
		perimeter_calls += 1
		var complete := perimeter_calls >= perimeter_terminal_at
		return {"valid": true, "complete": complete, "candidatesEvaluated": 1, "totalCandidatesEvaluated": perimeter_calls, "result": {"valid": complete, "reason": "" if complete else "pending", "pose": {"ok": complete, "rejectedCandidates": {}, "rejectionExamples": []}, "sourceTelemetry": []}, "phaseTelemetry": {}}

class StaleProfile extends Audit:
	var support_calls := 0
	func _ready() -> void: pass
	func exterior_support_for_review(_horizontal: Vector3, _target_y: float, _minimum_y: float) -> Dictionary:
		support_calls += 1
		return {"position": Vector3.ZERO}
	func bounded_exterior_support_for_review(_surface_candidate: Vector3, _minimum_y: float) -> Dictionary:
		support_calls += 1
		return {"position": Vector3.ZERO}

class ValidationProfile extends Audit:
	func _ready() -> void: pass
	func review_visual_snapshot_binding() -> String:
		return "audit.synthetic.binding"
	func review_visual_snapshot_summary() -> Dictionary:
		return {"valid": true, "binding": "audit.synthetic.binding", "epoch": 1}

var _checks: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _check(id: String, passed: bool) -> void:
	_checks[id] = passed

func _same(a: Variant, b: Variant) -> bool:
	return var_to_bytes(a) == var_to_bytes(b)

func _radial_fixture(profile: IncrementalProfile) -> Dictionary:
	var candidates: Array[Vector3] = []
	for index in range(Audit.RADIAL_CANDIDATE_LIMIT):
		candidates.append(Vector3(float(index), 1.58, -6.0))
	var job := profile.begin_exterior_review_pose_from_candidates(Vector3.ZERO, candidates, 2.0, -INF)
	job._visual_snapshot_binding = "audit.synthetic.binding"
	job._visual_snapshot_epoch = 1
	return {"valid": true, "spec": {"id": "outer_approach"}, "partId": "gatehouse", "bounds": AABB(Vector3.ZERO, Vector3.ONE), "target": Vector3.ZERO, "radial": {}, "job": job, "candidateOrder": candidates}

func _source(id: String, binding: String = "audit.synthetic.binding", epoch: int = 1, count: int = 1) -> Dictionary:
	var candidates: Array[Vector3] = []
	for index in range(count):
		candidates.append(Vector3(float(index), 0.0, -6.0))
	return {"sourceId": id, "focus": Vector3.ZERO, "candidatePositions": candidates, "visualSnapshotBinding": binding, "visualSnapshotEpoch": epoch}

func _orchestration_cases() -> void:
	var success := OrchestrationProfile.new()
	root.add_child(success)
	success.selected_seed = 208159
	success.selected_citadel_scale = 1.25
	await success.write_automated_report()
	var success_report: Dictionary = success.reports.back()
	_check("success_terminal_status", success.exit_codes == [0] and String(success_report.status) == "audit_complete" and String(success_report.terminalReason) == "all_three_views_terminal")
	_check("success_exact_allowlist_order", (success_report.views as Array).map(func(row): return String((row as Dictionary).id)) == Audit.AUDIT_VIEW_IDS)
	_check("success_all_views_terminal", bool(success_report.allViewsTerminal) and bool(success_report.allPosesPassed) and int(success_report.totalCandidatesEvaluated) == 3)

	var readiness_failure := OrchestrationProfile.new()
	root.add_child(readiness_failure)
	readiness_failure.selected_seed = 208159
	readiness_failure.selected_citadel_scale = 1.25
	readiness_failure.readiness_ready = false
	await readiness_failure.write_automated_report()
	var readiness_report: Dictionary = readiness_failure.reports.back()
	_check("readiness_fails_closed", readiness_failure.exit_codes == [1] and String(readiness_report.terminalReason) == "readiness_failed" and readiness_failure.radial_begin_calls == 0 and readiness_failure.perimeter_source_calls == 0 and not readiness_failure.events.has("snapshot"))

	var snapshot_failure := OrchestrationProfile.new()
	root.add_child(snapshot_failure)
	snapshot_failure.selected_seed = 208159
	snapshot_failure.selected_citadel_scale = 1.25
	snapshot_failure.snapshot_valid = false
	await snapshot_failure.write_automated_report()
	var snapshot_report: Dictionary = snapshot_failure.reports.back()
	_check("snapshot_fails_closed", snapshot_failure.exit_codes == [1] and String(snapshot_report.terminalReason) == "visual_snapshot_failed" and snapshot_failure.radial_begin_calls == 0 and snapshot_failure.perimeter_source_calls == 0)
	_check("report_failure_is_terminal", String(snapshot_report.status) == "audit_failed" and snapshot_failure.events.has("progress:audit_failed"))
	success.free(); readiness_failure.free(); snapshot_failure.free()

func _incremental_cases() -> void:
	var radial_success := IncrementalProfile.new()
	root.add_child(radial_success)
	var radial_result: Dictionary = await radial_success.advance_radial_audit(_radial_fixture(radial_success), 7)
	_check("radial_success_terminal", bool(radial_result.operational) and bool(radial_result.row.terminal) and int(radial_result.row.candidatesEvaluated) == 3 and int(radial_result.aggregateCandidatesEvaluated) == 10)
	_check("radial_one_candidate_per_advance", radial_success.radial_steps == [1, 1, 1])

	var radial_exhausted := IncrementalProfile.new()
	root.add_child(radial_exhausted)
	radial_exhausted.radial_terminal_at = 999
	var exhausted_result: Dictionary = await radial_exhausted.advance_radial_audit(_radial_fixture(radial_exhausted), 0)
	_check("radial_64_cap_exhausted_terminal_failure", not bool(exhausted_result.operational) and String(exhausted_result.reason) == "radial_candidate_cap_exhausted_nonterminal" and int(exhausted_result.aggregateCandidatesEvaluated) == 64 and radial_exhausted.radial_calls == 64)
	_check("radial_exhausted_still_one_candidate_per_advance", radial_exhausted.radial_steps.all(func(value): return int(value) == 1))

	var perimeter_success := IncrementalProfile.new()
	root.add_child(perimeter_success)
	var perimeter_result: Dictionary = await perimeter_success.advance_perimeter_audit([_source("a")], 20)
	_check("perimeter_success_terminal", bool(perimeter_result.operational) and bool(perimeter_result.row.terminal) and int(perimeter_result.row.candidatesEvaluated) == 3 and int(perimeter_result.aggregateCandidatesEvaluated) == 23)
	_check("perimeter_one_candidate_per_advance", perimeter_success.perimeter_steps == [1, 1, 1])

	var perimeter_exhausted := IncrementalProfile.new()
	root.add_child(perimeter_exhausted)
	perimeter_exhausted.perimeter_terminal_at = 999
	var six_sources: Array = []
	for id in ["a", "b", "c", "d", "e", "f"]:
		six_sources.append(_source(id, "audit.synthetic.binding", 1, 64))
	var perimeter_cap_result: Dictionary = await perimeter_exhausted.advance_perimeter_audit(six_sources, 0)
	_check("perimeter_6x64_cap_exhausted_terminal_failure", not bool(perimeter_cap_result.operational) and String(perimeter_cap_result.reason) == "total_or_perimeter_candidate_cap_exhausted_nonterminal" and int(perimeter_cap_result.aggregateCandidatesEvaluated) == 384 and perimeter_exhausted.perimeter_calls == 384 and perimeter_exhausted.perimeter_steps.all(func(value): return int(value) == 1))

	var total_exhausted := IncrementalProfile.new()
	root.add_child(total_exhausted)
	total_exhausted.perimeter_terminal_at = 999
	var total_cap_result: Dictionary = await total_exhausted.advance_perimeter_audit([_source("a")], 511)
	_check("perimeter_total_512_cap_exhausted_terminal_failure", not bool(total_cap_result.operational) and String(total_cap_result.reason) == "total_or_perimeter_candidate_cap_exhausted_nonterminal" and int(total_cap_result.aggregateCandidatesEvaluated) == 512 and total_exhausted.perimeter_calls == 1 and total_exhausted.perimeter_steps == [1])
	radial_success.free(); radial_exhausted.free(); perimeter_success.free(); perimeter_exhausted.free(); total_exhausted.free()

func _source_validation_cases() -> void:
	var profile := ValidationProfile.new()
	root.add_child(profile)
	var sources: Array = []
	for id in ["c", "a", "b", "f", "d", "e"]:
		sources.append(_source(id, "audit.synthetic.binding", 1, 64))
	var validated := profile.validate_perimeter_sources({"valid": true, "sources": sources})
	var reversed := sources.duplicate(true)
	reversed.reverse()
	var replay := profile.validate_perimeter_sources({"valid": true, "sources": reversed})
	_check("perimeter_six_source_64_each_cap_valid", bool(validated.valid) and int(validated.sourceCount) == 6)
	_check("perimeter_reversed_input_stable_order", _same((validated.sources as Array).map(func(row): return String((row as Dictionary).sourceId)), (replay.sources as Array).map(func(row): return String((row as Dictionary).sourceId))) and (validated.sources as Array).map(func(row): return String((row as Dictionary).sourceId)) == ["a", "b", "c", "d", "e", "f"])
	var too_many := profile.validate_perimeter_sources({"valid": true, "sources": sources + [_source("g")]})
	_check("perimeter_seventh_source_fails_closed", not bool(too_many.valid) and String(too_many.reason) == "perimeter_eligible_source_cap_exceeded")
	var oversized := profile.validate_perimeter_sources({"valid": true, "sources": [_source("a", "audit.synthetic.binding", 1, 65)]})
	_check("perimeter_65th_candidate_fails_closed", not bool(oversized.valid) and String(oversized.reason) == "invalid_perimeter_candidate_domain")
	profile.free()

func _stale_snapshot_cases() -> void:
	var profile := StaleProfile.new()
	root.add_child(profile)
	profile.blueprint = Blueprint.new("failed.camera.audit.stale", 208159, "test")
	for declaration in [
		{"id": "castle_gatehouse_lintel_fixture", "kind": "beam", "position": Vector3(0.0, 2.0, 0.0), "size": Vector3(3.0, 1.0, 1.0), "collision": false},
		{"id": "urban_civic_tower_fixture", "kind": "wall", "semantic": "citadel_civic_landmark", "position": Vector3(10.0, 3.0, 0.0), "size": Vector3(3.0, 6.0, 3.0), "collision": false},
	]:
		var part = profile.blueprint.add_part(declaration)
		profile.blueprint.physical_parts_by_id[part.id] = part
	profile.build_review_visual_snapshot()
	var old_binding := profile.review_visual_snapshot_binding()
	var old_epoch := int(profile.review_visual_snapshot_summary().epoch)
	var clear_radial := profile.begin_radial_audit_job(Audit.audit_view_specs()[0])
	var rebuild_radial := profile.begin_radial_audit_job(Audit.audit_view_specs()[0])
	var stale_source := _source("stale_perimeter", old_binding, old_epoch, 1)
	_check("stale_fixture_jobs_start_valid", bool(clear_radial.get("valid", false)) and bool(rebuild_radial.get("valid", false)) and not old_binding.is_empty() and old_epoch > 0)
	profile.clear_review_visual_snapshot()
	var radial_after_clear: Dictionary = await profile.advance_radial_audit(clear_radial, 0)
	var perimeter_after_clear: Dictionary = await profile.advance_perimeter_audit([stale_source], 0)
	_check("stale_clear_radial_perimeter_zero_work", not bool(radial_after_clear.operational) and not bool(perimeter_after_clear.operational) and int(radial_after_clear.aggregateCandidatesEvaluated) == 0 and int(perimeter_after_clear.aggregateCandidatesEvaluated) == 0 and profile.support_calls == 0)
	profile.build_review_visual_snapshot()
	var radial_after_rebuild: Dictionary = await profile.advance_radial_audit(rebuild_radial, 0)
	var perimeter_after_rebuild: Dictionary = await profile.advance_perimeter_audit([stale_source], 0)
	_check("stale_rebuild_radial_perimeter_zero_work", not bool(radial_after_rebuild.operational) and not bool(perimeter_after_rebuild.operational) and int(radial_after_rebuild.aggregateCandidatesEvaluated) == 0 and int(perimeter_after_rebuild.aggregateCandidatesEvaluated) == 0 and profile.support_calls == 0)
	profile.free()

func _run() -> void:
	var specs := Audit.audit_view_specs()
	_check("exact_allowlist_order", Audit.AUDIT_VIEW_IDS == ["outer_approach", "civic_overview", "perimeter_lane"])
	_check("exact_radial_specs", specs == [
		{"id": "outer_approach", "subject": "gatehouse", "idPrefix": "castle_gatehouse_lintel", "semantic": "", "maximumDistance": 30.0, "minimumDistance": 8.0, "preferredDistance": 18.0, "subjectRadius": 4.5, "preferredDirectionIndex": 0},
		{"id": "civic_overview", "subject": "civic roofline", "idPrefix": "urban_civic_tower", "semantic": "citadel_civic_landmark", "maximumDistance": 34.0, "minimumDistance": 8.0, "preferredDistance": 22.0, "subjectRadius": 6.0, "preferredDirectionIndex": 0},
	])
	var report_profile := OrchestrationProfile.new()
	var report := report_profile._initial_audit_report({"ready": true})
	report_profile.free()
	_check("exact_caps_64_6x64_512_stride1", Audit.RADIAL_CANDIDATE_LIMIT == 64 and Audit.PERIMETER_SOURCE_LIMIT == 6 and Audit.TOTAL_CANDIDATE_LIMIT == 512 and report.limits == {"radialCandidatesPerView": 64, "perimeterSources": 6, "perimeterCandidatesPerSource": 64, "totalCandidates": 512, "candidatesPerAdvance": 1})
	await _orchestration_cases()
	await _incremental_cases()
	_source_validation_cases()
	await _stale_snapshot_cases()
	var source := FileAccess.get_file_as_string("res://scripts/testing/buildings/CitadelFailedCameraPoseAudit.gd")
	_check("frame_yield_after_incomplete_radial_and_perimeter_advance", source.count("await get_tree().process_frame") == 2 and source.contains("advance_exterior_review_pose(job, 1)") and source.contains("advance_bounded_perimeter_review_job(job, 1)"))
	_check("no_capture_path", not source.contains("capture_views(") and not source.contains("get_image(") and not source.contains("save_png(") and not source.contains("screenshot"))
	_check("report_path_fails_closed", source.contains("if audit_report_path.is_empty() or not audit_report_path.is_absolute_path():") and source.contains("get_tree().quit(2)"))
	var passed := not _checks.values().has(false)
	var path := OS.get_environment("VOXEL_CITADEL_FAILED_CAMERA_AUDIT_CONTRACT_REPORT")
	if path.is_empty() or not path.is_absolute_path() or FileAccess.file_exists(path):
		quit(2)
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify({"schemaVersion": 1, "passed": passed, "checkCount": _checks.size(), "checks": _checks, "evidenceLevel": "synthetic_failed_camera_audit_control_contract_not_real_publication_physics_or_visual_acceptance"}, "  "))
	file.close()
	quit(0 if passed else 1)
