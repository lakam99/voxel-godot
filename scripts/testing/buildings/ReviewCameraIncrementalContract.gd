extends SceneTree
## Synthetic camera scheduling/contract evidence only: no live physics or GPU.
const Runner = preload("res://scripts/testing/buildings/CitadelUrbanPocRunner.gd")
const EXPECTED_PHASE_ORDER := ["support", "capsule", "visualVolume", "visibilityTarget", "physicsSightline", "visualSightline", "frameChecks", "nearFieldComposition", "subjectReadability"]
const EXPECTED_VISIT_KEYS := ["parts", "segments", "samples", "queries"]
const MAX_PHASE_TELEMETRY_BYTES := 16384
const MAX_COMPOSITE_CANDIDATE_VISITS := 8 * 64
const MAX_VISITS_PER_PHASE_PER_CANDIDATE := 64

class SyntheticRunner extends Runner:
	var calls: Array = []
	var attempted: Array[Vector3] = []
	var mode: String = ""
	var reject_attempts: int = 0
	var active_job: Variant
	var reentrant_result: Dictionary = {}

	func _ready() -> void:
		pass

	func _blocked(stage: String) -> bool:
		if mode == "mixed":
			return attempted.size() <= 7 and ["support", "capsule", "volume", "endpoint", "physics", "visual", "subject"][attempted.size() - 1] == stage
		return mode == stage

	func exterior_support_for_review(horizontal: Vector3, target_y: float, minimum_y: float) -> Dictionary:
		attempted.append(horizontal)
		calls.append(["support", horizontal, target_y, minimum_y])
		return {} if _blocked("support") else {"position": Vector3(horizontal.x, 0.0, horizontal.z)}

	func review_capsule_clearance(feet: Vector3, collider) -> Dictionary:
		calls.append(["capsule", feet, collider])
		return {"clear": not _blocked("capsule")}

	func review_visual_volume_is_clear(feet: Vector3) -> bool:
		calls.append(["volume", feet])
		return not _blocked("volume")

	func review_near_camera_visual_composition(_camera_position: Vector3, _target: Vector3) -> Dictionary:
		return {"clear": true, "blockedSamples": 0, "sampleCount": 8, "blockerIds": []}

	func endpoint(position: Vector3) -> Variant:
		calls.append(["endpoint", position])
		return 42 if _blocked("endpoint") else Vector3(0.25, 1.58, 0.5)

	func review_line_is_clear(from: Vector3, target: Vector3) -> bool:
		calls.append(["physics", from, target])
		return not _blocked("physics")

	func review_visual_line_is_clear(from: Vector3, target: Vector3) -> bool:
		calls.append(["visual", from, target])
		return not _blocked("visual")

	func requirement(position: Vector3) -> Variant:
		calls.append(["subject", position])
		if mode == "reentrant":
			reentrant_result = advance_exterior_review_pose(active_job, 1)
		if mode == "invalid_subject":
			return 42
		return "hidden" if _blocked("subject") or attempted.size() <= reject_attempts else ""

class CompositeSyntheticRunner extends SyntheticRunner:
	var active_source: Dictionary = {}
	var composite_order: Array = []
	var composite_active_job: Variant
	var composite_advance_callback: Callable
	var composite_reentrant_result: Dictionary = {}
	var synchronous_chooser_calls := 0
	var predicate_counts: Dictionary = {}
	func choose_bounded_perimeter_review_view(eligible_sources: Array) -> Dictionary:
		synchronous_chooser_calls += 1
		return super.choose_bounded_perimeter_review_view(eligible_sources)
	func reset_predicate_counts(source: Dictionary) -> void:
		active_source = source
		predicate_counts = {}
	func bounded_exterior_support_for_review(surface_candidate: Vector3, minimum_y: float) -> Dictionary:
		composite_order.append([String(active_source.get("sourceId", "")), surface_candidate])
		return exterior_support_for_review(surface_candidate, surface_candidate.y, minimum_y)
	func chooser_subject_readability_rejection(position: Vector3, _allowed: bool = true) -> Variant:
		calls.append(["subject", position])
		if mode == "composite_reentrant" and composite_advance_callback.is_valid():
			composite_reentrant_result = composite_advance_callback.call(composite_active_job, 1)
		return "hidden" if bool(active_source.get("rejectAll", false)) else ""

var _checks: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _check(label: String, value: bool) -> void:
	_checks[label] = value

func _same(a: Variant, b: Variant) -> bool:
	return var_to_bytes(a) == var_to_bytes(b)

func _begin(r: SyntheticRunner, radius: float = 2.0, callbacks: bool = true) -> Variant:
	return r.begin_exterior_review_pose(Vector3(0.0, 1.58, 0.0), 5.0, 6.0, radius, -3, -INF, r.requirement if callbacks else Callable(), r.endpoint if callbacks else Callable())

func _sync(r: SyntheticRunner, radius: float = 2.0, callbacks: bool = true) -> Dictionary:
	return r.solve_exterior_review_pose(Vector3(0.0, 1.58, 0.0), 5.0, 6.0, radius, -3, -INF, r.requirement if callbacks else Callable(), r.endpoint if callbacks else Callable())

func _pair(label: String, mode: String, reject_count: int, stride: int, radius: float = 2.0, callbacks: bool = true) -> void:
	var sync := SyntheticRunner.new()
	var incremental := SyntheticRunner.new()
	sync.mode = mode
	incremental.mode = mode
	sync.reject_attempts = reject_count
	incremental.reject_attempts = reject_count
	var expected: Dictionary = _sync(sync, radius, callbacks)
	var job: Variant = _begin(incremental, radius, callbacks)
	_check(label + "_begin_no_scene_work", incremental.calls.is_empty())
	var progress: Dictionary = {}
	var prior: int = 0
	var step_counts_valid: bool = true
	for _step in range(64):
		progress = incremental.advance_exterior_review_pose(job, stride)
		var count: int = int(progress.get("candidatesEvaluated", -1))
		var timings: Array = progress.get("candidateUsec", [])
		step_counts_valid = step_counts_valid and bool(progress.get("valid", false)) and count >= 1 and count <= stride and timings.size() == count
		var maximum: int = 0
		for timing in timings:
			step_counts_valid = step_counts_valid and timing is int and timing >= 0
			maximum = maxi(maximum, int(timing))
		step_counts_valid = step_counts_valid and maximum == int(progress.get("maxCandidateUsec", -1))
		prior += count
		step_counts_valid = step_counts_valid and prior == int(progress.get("totalCandidatesEvaluated", -1))
		if bool(progress.get("complete", false)):
			break
	_check(label + "_bounded_steps", step_counts_valid and bool(progress.get("complete", false)) and prior <= 64)
	var should_succeed: bool = radius >= 2.0 and (mode.is_empty() or mode == "mixed")
	var expected_attempts: int = 8 if mode == "mixed" else (reject_count + 1 if should_succeed else 64)
	_check(label + "_expected_completion", prior == expected_attempts and bool(expected.get("ok", false)) == should_succeed)
	_check(label + "_exact_pose", _same(expected, progress.get("pose", {})))
	_check(label + "_exact_call_order", _same(sync.calls, incremental.calls))
	_check(label + "_exact_candidate_order", _same(sync.attempted, incremental.attempted))
	var call_count: int = incremental.calls.size()
	var finished: Dictionary = incremental.advance_exterior_review_pose(job, 1)
	_check(label + "_completed_idempotent", bool(finished.valid) and bool(finished.complete) and int(finished.candidatesEvaluated) == 0 and incremental.calls.size() == call_count and _same(finished.pose, expected))
	if prior == 64:
		var independently_expected: Array[Vector3] = []
		for distance in [6.0, 5.0, lerpf(5.0, 6.0, 0.30), lerpf(5.0, 6.0, 0.64)]:
			for offset in range(16):
				var angle: float = TAU * float(posmod(-3 + offset, 16)) / 16.0
				independently_expected.append(Vector3(0.0, 1.58, 0.0) + Vector3(sin(angle), 0.0, -cos(angle)).normalized() * float(distance))
		_check(label + "_legacy_64_lattice", _same(independently_expected, incremental.attempted))
		_check(label + "_examples_bounded", expected.get("rejectionExamples", []).size() <= 8)
	if mode == "mixed":
		var stages: Array = []
		for call in incremental.calls:
			stages.append(call[0])
		_check(label + "_prerequisite_sequence", stages == [
			"support",
			"support", "capsule",
			"support", "capsule", "volume",
			"support", "capsule", "volume", "endpoint",
			"support", "capsule", "volume", "endpoint", "physics",
			"support", "capsule", "volume", "endpoint", "physics", "visual",
			"support", "capsule", "volume", "endpoint", "physics", "visual", "subject",
			"support", "capsule", "volume", "endpoint", "physics", "visual", "subject"])
	sync.free()
	incremental.free()

func _composite_source(id: String, count: int, reject_all: bool) -> Dictionary:
	var candidates: Array[Vector3] = []
	for index in range(count):
		candidates.append(Vector3(float(index) * 0.20, 0.0, -6.0 - float(index) * 0.05))
	return {"sourceId": id, "focus": Vector3(0.0, 1.58, 0.0), "candidatePositions": candidates, "subjectRadius": 2.0, "minimumSupportY": -INF, "rejectAll": reject_all, "readabilityAllowed": not reject_all}

func _begin_composite(r: CompositeSyntheticRunner, sources: Array) -> Variant:
	return r.begin_bounded_perimeter_review_job(sources)

func _advance_composite(r: CompositeSyntheticRunner, value: Variant, max_candidates: int) -> Dictionary:
	return r.advance_bounded_perimeter_review_job(value, max_candidates)

func _drain_composite(r: CompositeSyntheticRunner, job: Variant, stride: int) -> Dictionary:
	var progress: Dictionary = {}
	for _step in range(512):
		progress = _advance_composite(r, job, stride)
		if bool(progress.get("complete", false)): break
	return progress

func _phase_scope_shape_valid(scope: Dictionary, candidate_limit: int) -> bool:
	if scope.keys() != EXPECTED_PHASE_ORDER:
		return false
	for phase in EXPECTED_PHASE_ORDER:
		var row_value: Variant = scope.get(phase, {})
		if not row_value is Dictionary:
			return false
		var row: Dictionary = row_value as Dictionary
		if row.keys() != ["count", "totalUsec", "maxUsec", "visits"]:
			return false
		var count := int(row.get("count", -1))
		var total_usec := int(row.get("totalUsec", -1))
		var maximum_usec := int(row.get("maxUsec", -1))
		var visits_value: Variant = row.get("visits", {})
		if count < 0 or count > candidate_limit or total_usec < 0 or maximum_usec < 0 or maximum_usec > total_usec or not visits_value is Dictionary:
			return false
		if count == 0 and (total_usec != 0 or maximum_usec != 0):
			return false
		var visits: Dictionary = visits_value as Dictionary
		if visits.keys() != EXPECTED_VISIT_KEYS:
			return false
		for visit_key in EXPECTED_VISIT_KEYS:
			var visit_count := int(visits.get(visit_key, -1))
			if visit_count < 0 or visit_count > candidate_limit * MAX_VISITS_PER_PHASE_PER_CANDIDATE:
				return false
	return true

func _phase_scope_without_wall_clock(scope: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for phase in EXPECTED_PHASE_ORDER:
		var row: Dictionary = scope.get(phase, {}) as Dictionary
		result[phase] = {"count": int(row.get("count", -1)), "totalUsec": 0, "maxUsec": 0, "visits": (row.get("visits", {}) as Dictionary).duplicate(true)}
	return result

func _phase_telemetry_without_wall_clock(telemetry: Dictionary) -> Dictionary:
	return {
		"phaseOrder": (telemetry.get("phaseOrder", []) as Array).duplicate(true),
		"visitKeys": (telemetry.get("visitKeys", []) as Array).duplicate(true),
		"latestAdvance": _phase_scope_without_wall_clock(telemetry.get("latestAdvance", {}) as Dictionary),
		"runGlobal": _phase_scope_without_wall_clock(telemetry.get("runGlobal", {}) as Dictionary),
		"runGlobalMaxCandidateUsec": 0,
	}

func _phase_telemetry_from(progress: Dictionary) -> Dictionary:
	var value: Variant = progress.get("phaseTelemetry", {})
	return value as Dictionary if value is Dictionary else {}

func _phase_telemetry_shape_valid(progress: Dictionary) -> bool:
	var telemetry := _phase_telemetry_from(progress)
	var phase_order_value: Variant = telemetry.get("phaseOrder", [])
	var visit_keys_value: Variant = telemetry.get("visitKeys", [])
	if not phase_order_value is Array or not visit_keys_value is Array:
		return false
	var latest: Variant = telemetry.get("latestAdvance", {})
	var global: Variant = telemetry.get("runGlobal", {})
	var latest_limit := int(progress.get("candidatesEvaluated", -1))
	var global_limit := int(progress.get("totalCandidatesEvaluated", -1))
	return telemetry.keys() == ["phaseOrder", "visitKeys", "latestAdvance", "runGlobal", "runGlobalMaxCandidateUsec"] \
		and phase_order_value == EXPECTED_PHASE_ORDER and visit_keys_value == EXPECTED_VISIT_KEYS \
		and latest is Dictionary and global is Dictionary \
		and latest_limit >= 0 and global_limit >= 0 and global_limit <= MAX_COMPOSITE_CANDIDATE_VISITS \
		and _phase_scope_shape_valid(latest as Dictionary, latest_limit) \
		and _phase_scope_shape_valid(global as Dictionary, global_limit) \
		and int(telemetry.get("runGlobalMaxCandidateUsec", -1)) >= 0 \
		and JSON.stringify(telemetry).to_utf8_buffer().size() <= MAX_PHASE_TELEMETRY_BYTES

func _phase_accumulated_exactly(previous_global: Dictionary, progress: Dictionary) -> bool:
	var telemetry := _phase_telemetry_from(progress)
	var latest: Dictionary = telemetry.get("latestAdvance", {}) as Dictionary
	var global: Dictionary = telemetry.get("runGlobal", {}) as Dictionary
	for phase in EXPECTED_PHASE_ORDER:
		var before: Dictionary = previous_global.get(phase, {}) as Dictionary
		var step: Dictionary = latest.get(phase, {}) as Dictionary
		var total: Dictionary = global.get(phase, {}) as Dictionary
		if int(total.get("count", -1)) != int(before.get("count", -1)) + int(step.get("count", -1)):
			return false
		if int(total.get("totalUsec", -1)) != int(before.get("totalUsec", -1)) + int(step.get("totalUsec", -1)):
			return false
		if int(total.get("maxUsec", -1)) != maxi(int(before.get("maxUsec", -1)), int(step.get("maxUsec", -1))):
			return false
		var before_visits: Dictionary = before.get("visits", {}) as Dictionary
		var step_visits: Dictionary = step.get("visits", {}) as Dictionary
		var total_visits: Dictionary = total.get("visits", {}) as Dictionary
		for visit_key in EXPECTED_VISIT_KEYS:
			if int(total_visits.get(visit_key, -1)) != int(before_visits.get(visit_key, -1)) + int(step_visits.get(visit_key, -1)):
				return false
	return true

func _zero_phase_scope() -> Dictionary:
	var result: Dictionary = {}
	for phase in EXPECTED_PHASE_ORDER:
		var visits: Dictionary = {}
		for visit_key in EXPECTED_VISIT_KEYS:
			visits[visit_key] = 0
		result[phase] = {"count": 0, "totalUsec": 0, "maxUsec": 0, "visits": visits}
	return result

func _phase_telemetry_contract_cases() -> void:
	var sources := [_composite_source("telemetry_a", 3, true), _composite_source("telemetry_b", 2, true)]
	var runner := CompositeSyntheticRunner.new()
	var job: Variant = _begin_composite(runner, sources)
	_check("phase_telemetry_begin_zero_scene_work", runner.calls.is_empty() and runner.composite_order.is_empty())
	var first := _advance_composite(runner, job, 2)
	var first_telemetry := _phase_telemetry_from(first)
	_check("phase_telemetry_required_shape", _phase_telemetry_shape_valid(first))
	var first_latest: Dictionary = first_telemetry.get("latestAdvance", {}) as Dictionary
	var first_global: Dictionary = first_telemetry.get("runGlobal", {}) as Dictionary
	_check("phase_telemetry_first_advance_is_global", _same(first_latest, first_global))
	_check("phase_telemetry_first_advance_visit_bounds", int((first_latest.get("support", {}) as Dictionary).get("count", -1)) == int(first.get("candidatesEvaluated", -2)) and int((first_global.get("support", {}) as Dictionary).get("count", -1)) <= MAX_COMPOSITE_CANDIDATE_VISITS)
	var previous_global := first_global.duplicate(true)
	var second := _advance_composite(runner, job, 2)
	var second_telemetry := _phase_telemetry_from(second)
	_check("phase_telemetry_stable_keys_and_order", _same(first_telemetry.get("phaseOrder", []), second_telemetry.get("phaseOrder", [])) and _same(first_telemetry.get("visitKeys", []), second_telemetry.get("visitKeys", [])))
	_check("phase_telemetry_accumulates_across_advances", _phase_telemetry_shape_valid(second) and _phase_accumulated_exactly(previous_global, second))
	var second_latest: Dictionary = second_telemetry.get("latestAdvance", {}) as Dictionary
	var second_global: Dictionary = second_telemetry.get("runGlobal", {}) as Dictionary
	_check("phase_telemetry_latest_and_global_are_separate", int((second_latest.get("support", {}) as Dictionary).get("count", -1)) == int(second.get("candidatesEvaluated", -2)) and int((second_global.get("support", {}) as Dictionary).get("count", -1)) == int(second.get("totalCandidatesEvaluated", -2)) and int(second_telemetry.get("runGlobalMaxCandidateUsec", -1)) >= int(second.get("maxCandidateUsec", -1)))
	previous_global = second_global.duplicate(true)
	var third := _advance_composite(runner, job, 2)
	var third_telemetry := _phase_telemetry_from(third)
	_check("phase_telemetry_accumulates_across_sources", third.complete and _phase_telemetry_shape_valid(third) and _phase_accumulated_exactly(previous_global, third) and int(((third_telemetry.get("runGlobal", {}) as Dictionary).get("support", {}) as Dictionary).get("count", -1)) == int(third.get("totalCandidatesEvaluated", -2)))
	_check("phase_telemetry_bounded_serialization", JSON.stringify(third_telemetry).to_utf8_buffer().size() <= MAX_PHASE_TELEMETRY_BYTES and (third_telemetry.get("phaseOrder", []) as Array).size() == EXPECTED_PHASE_ORDER.size() and (third_telemetry.get("visitKeys", []) as Array).size() == EXPECTED_VISIT_KEYS.size())
	var completed_global: Dictionary = (third_telemetry.get("runGlobal", {}) as Dictionary).duplicate(true)
	var completed_global_max := int(third_telemetry.get("runGlobalMaxCandidateUsec", -1))
	var finished := _advance_composite(runner, job, 1)
	var finished_telemetry := _phase_telemetry_from(finished)
	_check("phase_telemetry_completed_idempotent", _phase_telemetry_shape_valid(finished) and _same(completed_global, finished_telemetry.get("runGlobal", {})) and _same(_zero_phase_scope(), finished_telemetry.get("latestAdvance", {})) and completed_global_max == int(finished_telemetry.get("runGlobalMaxCandidateUsec", -2)))

	var reversed: Array = sources.duplicate(true)
	reversed.reverse()
	var reversed_runner := CompositeSyntheticRunner.new()
	var reversed_job: Variant = _begin_composite(reversed_runner, reversed)
	var reversed_progress: Dictionary = {}
	for _step in range(3):
		reversed_progress = _advance_composite(reversed_runner, reversed_job, 2)
	_check("phase_telemetry_deterministic_counts_and_visits", _same(_phase_telemetry_without_wall_clock(third_telemetry), _phase_telemetry_without_wall_clock(_phase_telemetry_from(reversed_progress))))
	runner.free()
	reversed_runner.free()

func _composite_incremental_cases() -> void:
	_phase_telemetry_contract_cases()
	var sources := [_composite_source("perimeter_a", 3, true), _composite_source("perimeter_b", 1, false)]
	var r := CompositeSyntheticRunner.new()
	var job: Variant = _begin_composite(r, sources)
	_check("composite_begin_zero_scene_work", r.calls.is_empty() and r.composite_order.is_empty())
	var steps: Array = []
	var progress: Dictionary = {}
	for _step in range(8):
		progress = _advance_composite(r, job, 2)
		steps.append([int(progress.get("activeSourceIndex", -1)), int(progress.get("candidatesEvaluated", 0))])
		if bool(progress.get("complete", false)): break
	_check("composite_small_steps_one_stable_source", steps == [[0, 2], [0, 1], [1, 1]])
	_check("composite_first_source_exhausts_second_succeeds", progress.complete and progress.result.valid and progress.result.selectedSourceId == "perimeter_b" and progress.sourceTelemetry.size() == 2 and not progress.sourceTelemetry[0].poseOk and progress.sourceTelemetry[1].poseOk)
	var expected_order := [["perimeter_a", Vector3(0.0, 0.0, -6.0)], ["perimeter_a", Vector3(0.20, 0.0, -6.05)], ["perimeter_a", Vector3(0.40, 0.0, -6.10)], ["perimeter_b", Vector3(0.0, 0.0, -6.0)]]
	_check("composite_exact_cross_frame_source_candidate_order", _same(r.composite_order, expected_order))
	_check("composite_bounded_step_and_total_work", steps.all(func(row): return int(row[1]) >= 1 and int(row[1]) <= 2) and int(progress.totalCandidatesEvaluated) == 4 and int(progress.totalCandidatesEvaluated) <= 8 * 64)
	var calls_after_complete := r.calls.size()
	var finished := _advance_composite(r, job, 1)
	_check("composite_completed_idempotent", finished.valid and finished.complete and int(finished.candidatesEvaluated) == 0 and r.calls.size() == calls_after_complete and _same(finished.result, progress.result))

	var reversed_sources: Array = sources.duplicate(true)
	reversed_sources.reverse()
	var reversed_runner := CompositeSyntheticRunner.new()
	var reversed_job: Variant = _begin_composite(reversed_runner, reversed_sources)
	var reversed := _drain_composite(reversed_runner, reversed_job, 2)
	_check("composite_reversed_input_stable", _same({"source": progress.result.selectedSourceId, "pose": progress.result.pose}, {"source": reversed.result.selectedSourceId, "pose": reversed.result.pose}) and _same(r.composite_order, reversed_runner.composite_order))

	var exhausted_runner := CompositeSyntheticRunner.new()
	var exhausted_job: Variant = _begin_composite(exhausted_runner, [_composite_source("perimeter_a", 2, true), _composite_source("perimeter_b", 2, true)])
	var exhausted := _drain_composite(exhausted_runner, exhausted_job, 1)
	_check("composite_all_sources_exhaust_fail_closed", exhausted.complete and not exhausted.result.valid and exhausted.result.reason == "no_perimeter_review_source_has_valid_full_pose" and exhausted.sourceTelemetry.size() == 2 and int(exhausted.totalCandidatesEvaluated) == 4 and int(exhausted.totalCandidatesEvaluated) <= 8 * 64)

	var oversized_runner := CompositeSyntheticRunner.new()
	var oversized_sources: Array = []
	for index in range(9): oversized_sources.append(_composite_source("perimeter_%02d" % index, 1, false))
	var oversized_job: Variant = _begin_composite(oversized_runner, oversized_sources)
	_check("composite_oversized_begin_zero_scene_work", oversized_runner.calls.is_empty() and oversized_runner.composite_order.is_empty())
	var oversized := _advance_composite(oversized_runner, oversized_job, 1)
	_check("composite_oversized_fails_closed", oversized.valid and oversized.complete and not oversized.result.valid and oversized.result.reason == "perimeter_review_source_cap_exceeded" and int(oversized.totalCandidatesEvaluated) == 0)

	var other := CompositeSyntheticRunner.new()
	var foreign_calls := r.calls.size()
	_check("composite_foreign_owner_fails_closed", not _advance_composite(other, job, 1).valid and r.calls.size() == foreign_calls and other.calls.is_empty())
	var reentrant_runner := CompositeSyntheticRunner.new()
	reentrant_runner.mode = "composite_reentrant"
	var reentrant_job: Variant = _begin_composite(reentrant_runner, [_composite_source("perimeter_a", 1, false)])
	reentrant_runner.composite_active_job = reentrant_job
	reentrant_runner.composite_advance_callback = Callable(self, "_reentrant_composite_advance").bind(reentrant_runner)
	var reentrant := _advance_composite(reentrant_runner, reentrant_job, 1)
	_check("composite_reentrant_fails_closed_without_extra_candidate", reentrant.valid and reentrant.complete and int(reentrant.totalCandidatesEvaluated) == 1 and not reentrant_runner.composite_reentrant_result.valid and int(reentrant_runner.composite_reentrant_result.candidatesEvaluated) == 0 and reentrant_runner.composite_order.size() == 1)

	var expiry_runner := CompositeSyntheticRunner.new()
	var expired_source := _composite_source("perimeter_a", 1, false)
	var expiry_job: Variant = _begin_composite(expiry_runner, [expired_source])
	var callback_owner := SyntheticRunner.new()
	expiry_job._active_camera_job = expiry_runner.begin_exterior_review_pose_from_candidates(expired_source.focus, expired_source.candidatePositions, 2.0, -INF, callback_owner.requirement, callback_owner.endpoint)
	callback_owner.free()
	var expired := _advance_composite(expiry_runner, expiry_job, 1)
	_check("composite_callback_expiry_fails_closed", not expired.valid and expired.complete and int(expired.candidatesEvaluated) == 0 and expiry_runner.calls.is_empty() and expiry_runner.composite_order.is_empty())

	var runner_source := FileAccess.get_file_as_string("res://scripts/testing/buildings/CitadelUrbanPocRunner.gd")
	var perimeter_body_start := runner_source.find("func perimeter_lane_review_view(")
	var perimeter_body_end := runner_source.find("\n\nfunc ", perimeter_body_start + 1)
	var perimeter_body := runner_source.substr(perimeter_body_start, perimeter_body_end - perimeter_body_start)
	_check("capture_generation_awaits_incremental_perimeter_stage", runner_source.contains("var perimeter_view: Dictionary = await perimeter_lane_review_view(") and perimeter_body.contains("advance_bounded_perimeter_review_job(job, PERIMETER_REVIEW_CANDIDATES_PER_FRAME)") and perimeter_body.contains("await get_tree().process_frame") and not perimeter_body.contains("choose_bounded_perimeter_review_view"))
	_check("capture_generation_writes_bounded_stage_progress", perimeter_body.contains("_write_camera_stage_progress(\"perimeter_review_begin\"") and perimeter_body.contains("_write_camera_stage_progress(\"perimeter_review_complete\""))
	r.free(); reversed_runner.free(); exhausted_runner.free(); oversized_runner.free(); other.free(); reentrant_runner.free(); expiry_runner.free()

func _reentrant_composite_advance(job: Variant, stride: int, r: CompositeSyntheticRunner) -> Dictionary:
	return _advance_composite(r, job, stride)

func _run() -> void:
	_composite_incremental_cases()
	_pair("default", "", 0, 1, 2.0, false)
	_pair("surface_callback", "", 0, 1)
	_pair("mixed_prerequisites", "mixed", 0, 3)
	_pair("late_success", "", 63, 7)
	_pair("all_subject_rejected", "subject", 0, 1)
	_pair("invalid_subject", "invalid_subject", 0, 2)
	_pair("frame_coverage", "", 0, 5, 0.01)
	for stage in ["support", "capsule", "volume", "endpoint", "physics", "visual"]:
		_pair(stage, stage, 0, 1)

	var r := SyntheticRunner.new()
	var other := SyntheticRunner.new()
	var job: Variant = _begin(r)
	for bad in [null, {}, 42, RefCounted.new()]:
		var invalid: Dictionary = r.advance_exterior_review_pose(bad, 1)
		_check("invalid_handle_" + str(typeof(bad)), not bool(invalid.valid) and int(invalid.candidatesEvaluated) == 0 and not bool(invalid.pose.ok))
	for stride in [-1, 0, 65]:
		var invalid: Dictionary = r.advance_exterior_review_pose(job, stride)
		_check("invalid_stride_" + str(stride), not bool(invalid.valid) and r.calls.is_empty())
	_check("wrong_owner", not bool(other.advance_exterior_review_pose(job, 1).valid) and r.calls.is_empty() and other.calls.is_empty())
	var malformed: Variant = _begin(r)
	malformed._cursor = 65
	_check("invalid_cursor", not bool(r.advance_exterior_review_pose(malformed, 1).valid) and r.calls.is_empty())
	var progress: Dictionary = r.advance_exterior_review_pose(job, 1)
	_check("valid_after_bad_calls", bool(progress.valid) and bool(progress.pose.ok) and int(progress.candidatesEvaluated) == 1)
	var pristine: Dictionary = progress.pose.duplicate(true)
	progress.pose.rejectedCandidates.support = 999
	_check("returned_pose_isolated", _same(r.advance_exterior_review_pose(job, 1).pose, pristine))
	var view: Dictionary = r.make_exterior_review_view_from_pose("fixture", "synthetic", Vector3(0.0, 1.58, 0.0), 20.0, pristine)
	var direct: Dictionary = other.make_exterior_review_view("fixture", "synthetic", Vector3(0.0, 1.58, 0.0), 20.0, 5.0, 6.0, 2.0, -3, -INF, other.requirement, other.endpoint)
	_check("view_fields_exact", _same(view, direct))
	_check("surface_target_recorded", view.get("cameraPoseSightlineTarget") == Vector3(0.25, 1.58, 0.5))
	var default_pose: Dictionary = _sync(other, 2.0, false)
	_check("default_has_no_added_pose_field", not default_pose.has("sightlineTarget") and default_pose.size() == 8)
	_check("default_has_no_added_view_field", not other.make_exterior_review_view_from_pose("fixture", "synthetic", Vector3(0.0, 1.58, 0.0), 20.0, default_pose).has("cameraPoseSightlineTarget"))
	r.mode = "reentrant"
	r.active_job = _begin(r)
	progress = r.advance_exterior_review_pose(r.active_job, 1)
	_check("reentrant_no_extra_attempt", bool(progress.valid) and int(progress.totalCandidatesEvaluated) == 1 and not bool(r.reentrant_result.valid) and int(r.reentrant_result.candidatesEvaluated) == 0)
	var callback_owner := SyntheticRunner.new()
	var expired: Variant = r.begin_exterior_review_pose(Vector3.ZERO, 5.0, 6.0, 2.0, 0, -INF, callback_owner.requirement)
	callback_owner.free()
	var call_count: int = r.calls.size()
	progress = r.advance_exterior_review_pose(expired, 1)
	_check("expired_callback_fail_closed", not bool(progress.valid) and not bool(progress.pose.ok) and r.calls.size() == call_count)
	_check("expired_callback_stays_failed", not bool(r.advance_exterior_review_pose(expired, 1).valid) and r.calls.size() == call_count)
	r.free()
	other.free()
	var passed: bool = not _checks.values().has(false)
	var report: Dictionary = {"schemaVersion": 1, "evidence": "synthetic_camera_job_and_static_runner_wiring_contract_not_live_physics_or_renderer_acceptance", "passed": passed, "checks": _checks, "checkCount": _checks.size(), "pendingIntegrationPoints": [], "runnerSha256": FileAccess.get_sha256("res://scripts/testing/buildings/CitadelUrbanPocRunner.gd")}
	var path: String = OS.get_environment("VOXEL_REVIEW_CAMERA_INCREMENTAL_REPORT")
	if path.is_empty() or not path.is_absolute_path() or FileAccess.file_exists(path):
		print(JSON.stringify({"passed": false, "reason": "fresh_absolute_report_required"}))
		quit(2)
		return
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		print(JSON.stringify({"passed": false, "reason": "report_open_failed"}))
		quit(2)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.flush()
	var written: bool = file.get_error() == OK
	file.close()
	print(JSON.stringify({"passed": passed and written, "checkCount": _checks.size(), "report": path}))
	quit(0 if passed and written else 2)
