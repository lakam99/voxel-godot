extends SceneTree

## Synthetic immutable visual-review-index contract only. It uses recipe records
## and runner geometry helpers; it does not publish a scene or prove an image.
const Runner = preload("res://scripts/testing/buildings/CitadelUrbanPocRunner.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const REQUIRED_APIS := [
	"build_review_visual_snapshot",
	"clear_review_visual_snapshot",
	"review_visual_snapshot_binding",
	"review_visual_snapshot_candidates",
	"review_visual_snapshot_reference_candidates",
]
const MAX_INDEX_REPORT_BYTES := 32768

class SyntheticRunner extends Runner:
	var physics_line_calls := 0
	var snapshot_query_calls := 0
	var broadphase_candidates := 0
	var exact_tests := 0
	func _ready() -> void: pass
	func review_line_is_clear(_from: Vector3, _target: Vector3) -> bool:
		physics_line_calls += 1
		return true
	func reset_instrumentation() -> void:
		physics_line_calls = 0
		snapshot_query_calls = 0
		broadphase_candidates = 0
		exact_tests = 0
	func instrumentation() -> Dictionary:
		return {"snapshotQueries": snapshot_query_calls, "broadphaseCandidates": broadphase_candidates, "exactTests": exact_tests, "physicsQueries": physics_line_calls}
	func review_visual_snapshot_candidates(envelope: AABB, stable_order: bool = false, expected_binding: String = "") -> Dictionary:
		var result := super.review_visual_snapshot_candidates(envelope, stable_order, expected_binding)
		snapshot_query_calls += 1
		broadphase_candidates += int(result.get("candidateCount", 0))
		return result
	func review_part_intersects_capsule(part, feet: Vector3, radius: float, height: float) -> bool:
		exact_tests += 1
		return super.review_part_intersects_capsule(part, feet, radius, height)
	func review_part_intersects_segment(part, from: Vector3, target: Vector3) -> bool:
		exact_tests += 1
		return super.review_part_intersects_segment(part, from, target)
	func review_part_intersects_near_segment(part, from: Vector3, target: Vector3) -> bool:
		exact_tests += 1
		return super.review_part_intersects_near_segment(part, from, target)

class ReferenceRunner extends SyntheticRunner:
	func review_visual_snapshot_candidates(envelope: AABB, stable_order: bool = false, expected_binding: String = "") -> Dictionary:
		var result := review_visual_snapshot_reference_candidates(envelope, stable_order, expected_binding)
		snapshot_query_calls += 1
		broadphase_candidates += int(result.get("candidateCount", 0))
		return result

var _checks: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(id: String, passed: bool, actual: Variant = null) -> void:
	var row := {"id": id, "passed": passed}
	if not passed and actual != null:
		var encoded := JSON.stringify(actual)
		row["actualPreview"] = encoded.left(512)
		row["actualSha256"] = encoded.sha256_text()
	_checks.append(row)

func _part(id: String, kind: String, position: Vector3, size: Vector3, rotation_y: float = 0.0, visual: bool = true) -> Dictionary:
	return {
		"id": id,
		"kind": kind,
		"material": "stone_wall",
		"position": position,
		"rotation": Vector3(0.0, rotation_y, 0.0),
		"size": size,
		"collision": false,
		"recipe": {"visual": visual},
	}

func _declarations() -> Array[Dictionary]:
	return [
		_part("source_subject_a", "decor", Vector3(24.0, 1.7, 5.0), Vector3(1.2, 2.6, 0.6)),
		_part("source_subject_b", "decor", Vector3(26.0, 1.7, 5.0), Vector3(1.2, 2.6, 0.6)),
		_part("blocker_first", "wall", Vector3(0.0, 1.4, -2.0), Vector3(1.2, 2.8, 0.8)),
		_part("blocker_second", "wall", Vector3(0.0, 1.4, 0.0), Vector3(1.2, 2.8, 0.8)),
		_part("rotated_member", "beam", Vector3(8.05, 1.2, 0.0), Vector3(4.0, 2.0, 0.5), deg_to_rad(45.0)),
		_part("cell_left", "wall", Vector3(7.90, 1.0, 9.0), Vector3(0.20, 2.0, 0.20)),
		_part("cell_right", "wall", Vector3(8.10, 1.0, 9.0), Vector3(0.20, 2.0, 0.20)),
		_part("capsule_edge", "wall", Vector3(16.23, 0.81, 0.0), Vector3(0.10, 1.62, 0.10)),
		_part("long_segment_blocker", "wall", Vector3(40.0, 1.2, 16.0), Vector3(0.50, 2.4, 4.0), deg_to_rad(18.0)),
		_part("hidden_visual_false", "wall", Vector3(0.0, 1.4, -4.0), Vector3(2.0, 2.8, 0.8), 0.0, false),
		_part("excluded_foundation", "foundation", Vector3(0.0, 0.25, 0.0), Vector3(96.0, 0.5, 48.0)),
		_part("near_field_a", "decor", Vector3(-0.65, 1.1, -7.2), Vector3(0.7, 2.2, 0.7)),
		_part("near_field_b", "decor", Vector3(0.65, 1.1, -7.2), Vector3(0.7, 2.2, 0.7)),
	]

func _blueprint(values: Array[Dictionary], id: String = "synthetic.review.visual.index"):
	var result = Blueprint.new(id, 17057, "test")
	for declaration in values:
		var part = result.add_part(declaration)
		result.physical_parts_by_id[part.id] = part
	return result

func _api_ready(r: SyntheticRunner) -> bool:
	var ready := true
	for method in REQUIRED_APIS:
		var present := r.has_method(method)
		_check("required_api_%s" % method, present)
		ready = ready and present
	return ready

func _without_instrumentation(value: Dictionary) -> Dictionary:
	var result := value.duplicate(true)
	result.erase("instrumentation")
	result.erase("binding")
	return result

func _without_build_clock(value: Dictionary) -> Dictionary:
	var result := value.duplicate(true)
	result.erase("buildUsec")
	return result

func _ids(records: Array) -> Array[String]:
	var result: Array[String] = []
	for value in records:
		if value is Dictionary:
			result.append(String((value as Dictionary).get("id", "")))
	return result

func _unique(values: Array[String]) -> bool:
	var seen: Dictionary = {}
	for value in values:
		if seen.has(value):
			return false
		seen[value] = true
	return true


func _contains_object(value: Variant) -> bool:
	if value is Object:
		return true
	if value is Dictionary:
		for nested in (value as Dictionary).values():
			if _contains_object(nested):
				return true
	if value is Array:
		for nested in value:
			if _contains_object(nested):
				return true
	return false

func _reference_bounds_hits(r: SyntheticRunner, envelope: AABB) -> Array[String]:
	var result: Array[String] = []
	for part in r.blueprint.parts:
		if part == null or not bool(part.recipe.get("visual", true)):
			continue
		if r.review_part_bounds(part).intersects(envelope):
			result.append(String(part.id))
	return result

func _instrumentation_valid(result: Dictionary, source_limit: int) -> bool:
	var value: Variant = result.get("instrumentation", {})
	if not value is Dictionary:
		return false
	var instrumentation: Dictionary = value
	if instrumentation.keys() != ["snapshotQueries", "broadphaseCandidates", "exactTests", "physicsQueries"]:
		return false
	for key in instrumentation.keys():
		var count := int(instrumentation.get(key, -1))
		if count < 0 or count > source_limit * 64:
			return false
	return true

func _run_high_level_query(r: SyntheticRunner, kind: String, arguments: Dictionary) -> Dictionary:
	r.reset_instrumentation()
	var outcome: Variant
	var selected_id := ""
	match kind:
		"visualVolume":
			outcome = r.review_visual_volume_is_clear(arguments.get("feet", Vector3.ZERO) as Vector3)
		"visualSightline":
			var blocker := r.review_visual_line_blocker(arguments.get("from", Vector3.ZERO) as Vector3, arguments.get("target", Vector3.ZERO) as Vector3)
			outcome = blocker.is_empty()
			selected_id = String(blocker.get("id", ""))
		"visibleSurface":
			var surface: Variant = r.generated_part_visible_surface(arguments.get("cameraPosition", Vector3.ZERO) as Vector3, String(arguments.get("partId", "")))
			outcome = surface
			selected_id = String(arguments.get("partId", "")) if surface is Vector3 and surface.is_finite() else ""
		"subjectVisibleSurface":
			var subject_evidence := r.generated_subject_visible_surface_evidence(arguments.get("cameraPosition", Vector3.ZERO) as Vector3, arguments.get("partIds", []) as Array)
			outcome = subject_evidence
			selected_id = String(subject_evidence.get("partId", ""))
		"nearField":
			var near_evidence := r.review_near_camera_visual_composition(arguments.get("cameraPosition", Vector3.ZERO) as Vector3, arguments.get("target", Vector3.ZERO) as Vector3)
			outcome = near_evidence
			var blockers: Array = near_evidence.get("blockerIds", []) as Array
			selected_id = String(blockers[0]) if not blockers.is_empty() else ""
		"readabilityAll":
			outcome = r.generated_subject_readability_rejection(arguments.get("cameraPosition", Vector3.ZERO) as Vector3, arguments.get("partIds", []) as Array)
		"readabilityAny":
			outcome = r.generated_any_subject_readability_rejection(arguments.get("cameraPosition", Vector3.ZERO) as Vector3, arguments.get("partIds", []) as Array)
			var any_evidence := r.generated_subject_visible_surface_evidence(arguments.get("cameraPosition", Vector3.ZERO) as Vector3, arguments.get("partIds", []) as Array)
			selected_id = String(any_evidence.get("partId", ""))
		_:
			return {"valid": false, "reason": "unknown_high_level_query", "kind": kind, "instrumentation": r.instrumentation()}
	return {"valid": true, "kind": kind, "outcome": outcome, "selectedId": selected_id, "instrumentation": r.instrumentation()}

func _query_pair(cached_runner: SyntheticRunner, reference_runner: ReferenceRunner, id: String, kind: String, arguments: Dictionary, expected_selected_id: String = "") -> Dictionary:
	var reference := _run_high_level_query(reference_runner, kind, arguments)
	var cached := _run_high_level_query(cached_runner, kind, arguments)
	_check(id + "_reference_valid", bool(reference.get("valid", false)), reference)
	_check(id + "_cached_valid", bool(cached.get("valid", false)), cached)
	_check(id + "_exact_cached_reference_outcome", _without_instrumentation(cached) == _without_instrumentation(reference), {"cached": cached, "reference": reference})
	if not expected_selected_id.is_empty():
		_check(id + "_selected_member_or_blocker", String(cached.get("selectedId", "")) == expected_selected_id, cached)
	_check(id + "_reference_instrumentation_bounded", _instrumentation_valid(reference, reference_runner.blueprint.parts.size()), reference.get("instrumentation", {}))
	_check(id + "_cached_instrumentation_bounded", _instrumentation_valid(cached, cached_runner.blueprint.parts.size()), cached.get("instrumentation", {}))
	_check(id + "_reference_physics_query_count_exact", int((reference.get("instrumentation", {}) as Dictionary).get("physicsQueries", -1)) == reference_runner.physics_line_calls, reference.get("instrumentation", {}))
	_check(id + "_cached_physics_query_count_exact", int((cached.get("instrumentation", {}) as Dictionary).get("physicsQueries", -1)) == cached_runner.physics_line_calls, cached.get("instrumentation", {}))
	return cached

func _broadphase_cases(r: SyntheticRunner, binding: String) -> void:
	var envelopes := [
		AABB(Vector3(7.80, 0.0, 8.80), Vector3(0.40, 2.2, 0.40)),
		AABB(Vector3(5.0, 0.0, -3.0), Vector3(6.5, 3.0, 6.0)),
		AABB(Vector3(-1.0, 0.0, -12.0), Vector3(42.0, 3.0, 30.0)),
		AABB(Vector3(15.75, 0.0, -0.25), Vector3(0.50, 1.62, 0.50)),
	]
	for index in range(envelopes.size()):
		var envelope: AABB = envelopes[index]
		var query: Dictionary = r.review_visual_snapshot_candidates(envelope, false, binding)
		var actual := _ids(query.get("records", []) as Array)
		var reference := _reference_bounds_hits(r, envelope)
		var eligible_actual := actual.filter(func(id): return id in reference)
		_check("broadphase_%d_valid" % index, bool(query.get("valid", false)), query)
		_check("broadphase_%d_contains_every_reference_exact_hit" % index, reference.all(func(id): return id in actual), {"actual": actual, "reference": reference})
		_check("broadphase_%d_has_no_duplicates" % index, _unique(actual), actual)
		_check("broadphase_%d_restores_original_eligible_order" % index, eligible_actual == reference, {"actual": actual, "eligibleActual": eligible_actual, "reference": reference})
	var boundary: Dictionary = r.review_visual_snapshot_candidates(envelopes[0], true, binding)
	var boundary_ids := _ids(boundary.get("records", []) as Array)
	_check("cell_boundary_returns_both_adjacent_members", "cell_left" in boundary_ids and "cell_right" in boundary_ids and boundary_ids.find("cell_left") < boundary_ids.find("cell_right"), boundary_ids)

func _query_matrix(r: SyntheticRunner, reference: ReferenceRunner) -> Dictionary:
	var outcomes: Dictionary = {}
	var expected_first_blocker := "blocker_first" if r.blueprint.parts.find(r.blueprint.find_part("blocker_first")) < r.blueprint.parts.find(r.blueprint.find_part("blocker_second")) else "blocker_second"
	outcomes["visualVolume"] = _query_pair(r, reference, "visual_volume_capsule_envelope", "visualVolume", {"feet": Vector3(16.0, 0.0, 0.0)})
	outcomes["visualSightline"] = _query_pair(r, reference, "visual_sightline_first_blocker", "visualSightline", {"from": Vector3(0.0, 1.4, -10.0), "target": Vector3(0.0, 1.4, 6.0)}, expected_first_blocker)
	outcomes["longSegment"] = _query_pair(r, reference, "long_segment_crosses_many_cells", "visualSightline", {"from": Vector3(0.0, 1.2, 16.0), "target": Vector3(80.0, 1.2, 16.0)}, "long_segment_blocker")
	outcomes["visibleSurface"] = _query_pair(r, reference, "rotated_visible_surface", "visibleSurface", {"cameraPosition": Vector3(8.05, 1.2, -8.0), "partId": "rotated_member"}, "rotated_member")
	outcomes["subjectSurface"] = _query_pair(r, reference, "stable_subject_member_selection", "subjectVisibleSurface", {"cameraPosition": Vector3(25.0, 1.7, -8.0), "partIds": ["source_subject_b", "source_subject_a"]}, "source_subject_a")
	outcomes["nearField"] = _query_pair(r, reference, "near_field_selected_blockers", "nearField", {"cameraPosition": Vector3(0.0, 1.58, -9.0), "target": Vector3(0.0, 1.58, 5.0)})
	outcomes["readabilityAll"] = _query_pair(r, reference, "all_readability", "readabilityAll", {"cameraPosition": Vector3(25.0, 1.7, -8.0), "partIds": ["source_subject_b", "source_subject_a"]})
	outcomes["readabilityAny"] = _query_pair(r, reference, "any_readability", "readabilityAny", {"cameraPosition": Vector3(25.0, 1.7, -8.0), "partIds": ["source_subject_b", "source_subject_a"]}, "source_subject_a")
	outcomes["visualFalse"] = _query_pair(r, reference, "visual_false_record_excluded", "visualSightline", {"from": Vector3(0.0, 1.4, -6.0), "target": Vector3(0.0, 1.4, -3.0)})
	outcomes["foundation"] = _query_pair(r, reference, "foundation_excluded", "visualVolume", {"feet": Vector3(24.0, 0.5, 8.0)})
	return outcomes

func _run() -> void:
	var report_path := OS.get_environment("VOXEL_CITADEL_REVIEW_VISUAL_INDEX_REPORT")
	if report_path.is_empty() or not report_path.is_absolute_path() or FileAccess.file_exists(report_path):
		print(JSON.stringify({"passed": false, "reason": "fresh_absolute_report_required"}))
		quit(2)
		return
	var runner := SyntheticRunner.new()
	if not _api_ready(runner):
		_write_report(report_path, false, "required_runner_api_absent")
		runner.free()
		quit(1)
		return
	runner.blueprint = _blueprint(_declarations())
	var reference_runner := ReferenceRunner.new()
	reference_runner.blueprint = _blueprint(_declarations())
	var build: Dictionary = runner.build_review_visual_snapshot()
	var reference_build: Dictionary = reference_runner.build_review_visual_snapshot()
	var binding := runner.review_visual_snapshot_binding()
	_check("snapshot_build_valid", bool(build.get("valid", false)) and not binding.is_empty(), build)
	_check("snapshot_binding_matches_build", binding == String(build.get("binding", "")), {"binding": binding, "build": build})
	_check("reference_snapshot_same_binding", bool(reference_build.get("valid", false)) and String(reference_build.get("binding", "")) == binding, reference_build)
	_broadphase_cases(runner, binding)
	var outcomes := _query_matrix(runner, reference_runner)

	var rebuilt: Dictionary = runner.build_review_visual_snapshot()
	_check("same_source_rebuild_deterministic_signature", String(rebuilt.get("canonicalSignature", "")) == String(build.get("canonicalSignature", "")) and String(rebuilt.get("binding", "")) == binding, {"first": build, "rebuilt": rebuilt})
	_check("same_source_cache_bytes_ignore_build_clock", var_to_bytes(_without_build_clock(rebuilt)) == var_to_bytes(_without_build_clock(build)))
	var replay_outcomes := _query_matrix(runner, reference_runner)
	_check("same_source_instrumentation_deterministic", var_to_bytes(outcomes) == var_to_bytes(replay_outcomes))

	runner.clear_review_visual_snapshot()
	_check("clear_removes_binding", runner.review_visual_snapshot_binding().is_empty())
	var cleared := runner.review_visual_snapshot_candidates(AABB(Vector3(-1.0, 0.0, -10.0), Vector3(2.0, 3.0, 16.0)), false, binding)
	_check("cleared_cache_fails_closed", not bool(cleared.get("valid", false)), cleared)
	var reference_after_clear := _run_high_level_query(reference_runner, "visualSightline", {"from": Vector3(0.0, 1.4, -10.0), "target": Vector3(0.0, 1.4, 6.0)})
	_check("reference_survives_cache_clear", bool(reference_after_clear.get("valid", false)), reference_after_clear)
	var restored: Dictionary = runner.build_review_visual_snapshot()
	var restored_cached := _run_high_level_query(runner, "visualSightline", {"from": Vector3(0.0, 1.4, -10.0), "target": Vector3(0.0, 1.4, 6.0)})
	_check("cache_cleared_rebuild_restores_parity", _without_instrumentation(restored_cached) == _without_instrumentation(reference_after_clear), {"cached": restored_cached, "reference": reference_after_clear})
	_check("cached_snapshot_contains_no_object_values", not _contains_object(runner._review_visual_snapshot))

	var stale_binding := String(restored.get("binding", ""))
	var frozen_snapshot_bytes := var_to_bytes(runner._review_visual_snapshot)
	var frozen_outcome := _run_high_level_query(runner, "visualSightline", {"from": Vector3(0.0, 1.4, -10.0), "target": Vector3(0.0, 1.4, 6.0)})
	var mutable_part = runner.blueprint.find_part("rotated_member")
	mutable_part.position += Vector3(1.0, 0.0, 0.0)
	var post_mutation_outcome := _run_high_level_query(runner, "visualSightline", {"from": Vector3(0.0, 1.4, -10.0), "target": Vector3(0.0, 1.4, 6.0)})
	_check("post_build_source_mutation_does_not_mutate_cached_values", frozen_snapshot_bytes == var_to_bytes(runner._review_visual_snapshot) and _without_instrumentation(frozen_outcome) == _without_instrumentation(post_mutation_outcome))
	var mutated: Dictionary = runner.build_review_visual_snapshot()
	_check("source_mutation_changes_binding", String(mutated.get("binding", "")) != stale_binding, {"before": stale_binding, "after": mutated.get("binding", "")})
	var stale := runner.review_visual_snapshot_candidates(AABB(Vector3.ZERO, Vector3.ONE), false, stale_binding)
	_check("stale_binding_fails_closed", not bool(stale.get("valid", false)) and String(stale.get("reason", "")) == "stale_visual_snapshot_binding", stale)
	var bound_summary := runner.review_visual_snapshot_summary()
	var source := {"sourceId": "stale_job_source", "visualSnapshotBinding": runner.review_visual_snapshot_binding(), "visualSnapshotEpoch": int(bound_summary.get("epoch", 0)), "focus": Vector3.ZERO, "candidatePositions": [Vector3(0.0, 0.0, -6.0)], "subjectRadius": 2.0, "minimumSupportY": -INF, "readabilityAllowed": true}
	var stale_job = runner.begin_bounded_perimeter_review_job([source])
	var exact_tests_before_stale_advance := runner.exact_tests
	runner.clear_review_visual_snapshot()
	runner.build_review_visual_snapshot()
	var stale_progress := runner.advance_bounded_perimeter_review_job(stale_job, 1)
	_check("clear_rebuild_between_begin_and_advance_fails_before_candidate_work", not bool(stale_progress.get("valid", true)) and int(stale_progress.get("candidatesEvaluated", -1)) == 0 and int(stale_progress.get("totalCandidatesEvaluated", -1)) == 0 and runner.exact_tests == exact_tests_before_stale_advance, stale_progress)

	var reversed_declarations := _declarations()
	reversed_declarations.reverse()
	var reversed_runner := SyntheticRunner.new()
	reversed_runner.blueprint = _blueprint(reversed_declarations, "synthetic.review.visual.index.reversed")
	var reversed_reference := ReferenceRunner.new()
	reversed_reference.blueprint = _blueprint(reversed_declarations, "synthetic.review.visual.index.reversed")
	var reversed_build: Dictionary = reversed_runner.build_review_visual_snapshot()
	reversed_reference.build_review_visual_snapshot()
	var reversed_outcomes := _query_matrix(reversed_runner, reversed_reference)
	_check("reversed_input_build_valid", bool(reversed_build.get("valid", false)), reversed_build)
	for kind in outcomes.keys():
		var forward_outcome: Dictionary = _without_instrumentation(outcomes[kind] as Dictionary)
		var reversed_outcome: Dictionary = _without_instrumentation(reversed_outcomes[kind] as Dictionary)
		if String(kind) == "visualSightline":
			forward_outcome.erase("selectedId")
			reversed_outcome.erase("selectedId")
		_check("reversed_input_%s_outcome_parity" % String(kind), forward_outcome == reversed_outcome, {"forward": outcomes[kind], "reversed": reversed_outcomes[kind]})
	var stable_envelope := AABB(Vector3(-2.0, 0.0, -3.0), Vector3(12.0, 4.0, 14.0))
	var stable_forward_runner := SyntheticRunner.new()
	stable_forward_runner.blueprint = _blueprint(_declarations())
	stable_forward_runner.build_review_visual_snapshot()
	var forward_stable := stable_forward_runner.review_visual_snapshot_candidates(stable_envelope, true, stable_forward_runner.review_visual_snapshot_binding())
	var reverse_stable := reversed_runner.review_visual_snapshot_candidates(stable_envelope, true, reversed_runner.review_visual_snapshot_binding())
	_check("stable_order_candidate_parity_reversed_input", _ids(forward_stable.get("records", []) as Array) == _ids(reverse_stable.get("records", []) as Array), {"forward": _ids(forward_stable.get("records", []) as Array), "reversed": _ids(reverse_stable.get("records", []) as Array)})

	var passed := _checks.all(func(row: Dictionary): return bool(row.passed))
	_write_report(report_path, passed, "")
	runner.free()
	reference_runner.free()
	reversed_runner.free()
	reversed_reference.free()
	stable_forward_runner.free()
	quit(0 if passed else 1)

func _write_report(path: String, passed: bool, reason: String) -> void:
	var report := {
		"schemaVersion": 1,
		"passed": passed,
		"reason": reason,
		"checks": _checks,
		"checkCount": _checks.size(),
		"requiredApis": REQUIRED_APIS,
		"evidenceLevel": "synthetic_recipe_record_visual_index_contract",
		"doesNotProve": "No scene publication, renderer pixels, headed capture, player access, NPC or navigation behavior.",
	}
	if JSON.stringify(report).to_utf8_buffer().size() > MAX_INDEX_REPORT_BYTES:
		report = {"schemaVersion": 1, "passed": false, "reason": "contract_report_exceeded_bound", "checkCount": _checks.size(), "requiredApis": REQUIRED_APIS}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print(JSON.stringify({"passed": bool(report.passed), "checkCount": int(report.checkCount), "report": path}))
