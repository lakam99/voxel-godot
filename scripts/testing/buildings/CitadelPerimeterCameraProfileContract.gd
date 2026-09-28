extends SceneTree

const Profile = preload("res://scripts/testing/buildings/CitadelPerimeterCameraProfile.gd")
const FurnishingPlanScript = preload("res://scripts/buildings/FurnishingPlan.gd")

class ContractProfile extends Profile:
	var source_calls := 0
	var candidate_calls := 0
	var snapshot_valid := true
	var lifecycle: Array[String] = []
	var written_report: Dictionary = {}
	var written_exit_code := -1
	func _ready() -> void:
		pass
	func wait_for_capture_readiness() -> Dictionary:
		lifecycle.append("readiness")
		return {"ready": true, "expectedPartCount": 4501, "publishedPartCount": 4501, "registeredDoorCount": 20}
	func build_review_visual_snapshot() -> Dictionary:
		lifecycle.append("snapshot_build")
		return {"valid": snapshot_valid, "binding": "profile.contract:visual-snapshot-sha", "buildUsec": 37, "canonicalSignature": "visual-snapshot-sha"} if snapshot_valid else {"valid": false, "reason": "synthetic_invalid_visual_snapshot"}
	func review_visual_snapshot_summary() -> Dictionary:
		lifecycle.append("snapshot_summary")
		return {"valid": snapshot_valid, "binding": "profile.contract:visual-snapshot-sha" if snapshot_valid else "", "buildUsec": 37 if snapshot_valid else 0, "canonicalSignature": "visual-snapshot-sha" if snapshot_valid else "", "reason": "" if snapshot_valid else "synthetic_invalid_visual_snapshot"}
	func generated_perimeter_review_sources(_preferred_distance: float = 12.0, _maximum_distance: float = 22.0) -> Dictionary:
		source_calls += 1
		lifecycle.append("source_derivation")
		return {"valid": false, "reason": "synthetic_stop_after_derivation", "sources": [], "sourceCount": 0}
	func begin_bounded_perimeter_review_job(_eligible_sources: Array):
		candidate_calls += 1
		return null
	func _write_profile_progress(stage: String, _details: Dictionary) -> void:
		lifecycle.append("progress:" + stage)
	func _write_profile_report(report: Dictionary, exit_code: int) -> void:
		written_report = report.duplicate(true)
		written_exit_code = exit_code

var checks: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _check(id: String, passed: bool) -> void:
	checks[id] = passed


func _run() -> void:
	var runner := ContractProfile.new()
	var real_plan = FurnishingPlanScript.new("profile.contract", 208159, "citadel.contract")
	runner.furnishing_plan = real_plan
	runner.selected_seed = 208159
	runner.selected_citadel_scale = 1.25
	var readiness := {"ready": true, "expectedPartCount": 4501, "publishedPartCount": 4501, "registeredDoorCount": 20}
	var report := runner.build_initial_profile_report(readiness)
	_check("real_furnishing_plan_report_construction_completes", report is Dictionary and report.captureReadiness == readiness)
	_check("report_is_explicitly_profiling_only", String(report.evidenceLevel) == "unheaded_real_publication_physics_profile_not_camera_visual_gameplay_navigation_or_npc_acceptance" and String(report.doesNotProve).contains("Milestone 6 acceptance"))
	_check("report_construction_does_no_source_or_candidate_scene_work", runner.source_calls == 0 and runner.candidate_calls == 0)
	_check("hard_caps_preserved", int(report.sourceLimit) == 1 and int(report.candidateLimit) == 4)
	var source := FileAccess.get_file_as_string("res://scripts/testing/buildings/CitadelPerimeterCameraProfile.gd")
	_check("undeclared_placements_property_absent", not source.contains("furnishing_plan.placements"))
	_check("fixture_owned_terminal_guard_present", source.contains("_profile_guard.start(450.0)") and source.contains("_profile_guard.start(60.0)") and source.contains("fixture_failed_before_profile") and source.contains("_write_profile_report(report, 3)"))
	_check("one_candidate_per_advance_and_frame_yield", source.contains("advance_bounded_perimeter_review_job(job, 1)") and source.contains("await get_tree().process_frame"))

	await runner.write_automated_report()
	var snapshot_build_index := runner.lifecycle.find("snapshot_build")
	var snapshot_summary_index := runner.lifecycle.find("snapshot_summary")
	var source_derivation_index := runner.lifecycle.find("source_derivation")
	_check("valid_snapshot_built_after_readiness", runner.lifecycle.find("progress:readiness_complete") >= 0 and snapshot_build_index > runner.lifecycle.find("progress:readiness_complete"))
	_check("valid_snapshot_built_before_source_derivation", snapshot_build_index >= 0 and snapshot_summary_index > snapshot_build_index and source_derivation_index > snapshot_summary_index)
	_check("valid_snapshot_summary_records_binding_and_build_usec", bool(runner.written_report.get("reviewVisualSnapshot", {}).get("valid", false)) and String(runner.written_report.reviewVisualSnapshot.get("binding", "")) == "profile.contract:visual-snapshot-sha" and int(runner.written_report.reviewVisualSnapshot.get("buildUsec", 0)) == 37)
	_check("valid_snapshot_reaches_source_derivation_only", runner.source_calls == 1 and runner.candidate_calls == 0 and String(runner.written_report.get("status", "")) == "source_derivation_failed" and runner.written_exit_code == 1)

	var invalid_runner := ContractProfile.new()
	invalid_runner.furnishing_plan = FurnishingPlanScript.new("profile.contract.invalid", 208159, "citadel.contract")
	invalid_runner.selected_seed = 208159
	invalid_runner.selected_citadel_scale = 1.25
	invalid_runner.snapshot_valid = false
	await invalid_runner.write_automated_report()
	_check("invalid_snapshot_fails_closed_before_source_derivation", invalid_runner.source_calls == 0 and invalid_runner.candidate_calls == 0 and not invalid_runner.lifecycle.has("source_derivation"))
	_check("invalid_snapshot_records_summary_and_failure", String(invalid_runner.written_report.get("status", "")) == "visual_snapshot_failed" and String(invalid_runner.written_report.get("reviewVisualSnapshot", {}).get("reason", "")) == "synthetic_invalid_visual_snapshot" and invalid_runner.written_exit_code == 1)
	_check("invalid_snapshot_still_occurs_after_readiness", invalid_runner.lifecycle.find("snapshot_build") > invalid_runner.lifecycle.find("progress:readiness_complete"))
	runner.free()
	invalid_runner.free()
	var passed := not checks.values().has(false)
	var report_path := OS.get_environment("VOXEL_CITADEL_CAMERA_PROFILE_CONTRACT_REPORT")
	if report_path.is_empty() or not report_path.is_absolute_path() or FileAccess.file_exists(report_path):
		quit(2)
		return
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify({"schemaVersion": 1, "passed": passed, "checkCount": checks.size(), "checks": checks, "evidenceLevel": "synthetic_profile_fixture_contract_not_real_publication_or_physics"}, "  "))
	file.close()
	quit(0 if passed else 2)
