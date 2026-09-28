extends SceneTree

## SYNTHETIC DIRECT-HELPER CONTRACT ONLY. No blueprint validation, builders,
## generated world, scene, publisher, physics, actors or navigation are exercised.
## Inputs model checks already produced by local validation and the gable pass;
## this does not prove that production calls the helper after that pass.
## Malformed declarations deliberately bypass earlier unsafe casts: passing
## these tests DOES NOT establish whole-validator malformed-input robustness.
## All-true, well-formed cycles remain true: failure closure is not a proof of
## rootedness, structural safety, or cycle validity. No geometry is certified.
## Run later with --headless --script res://scripts/testing/buildings/MandatoryPhysicalDependencyContract.gd
## VOXEL_MANDATORY_DEPENDENCY_REPORT must name a NEW absolute JSON file with an
## existing parent directory. No default path, directory creation or overwrite.
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Dependency = preload("res://scripts/buildings/MandatoryPhysicalDependencyValidator.gd")
const REQUIRED := [
	"physicalRequiredSupportPartIds",
	"physicalRequiredSeatPartIds",
	"physicalRequiredAnchorPartIds"
]
const MAX_REPORT_BYTES := 8388608
const FAILED_REASON := "has a failed, missing or ambiguous required physical dependency"
const MALFORMED_REASON := "has an invalid required physical dependency declaration"

var _cases: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path := OS.get_environment("VOXEL_MANDATORY_DEPENDENCY_REPORT").strip_edges()
	if not _new_absolute_report_path(path):
		push_error("Set VOXEL_MANDATORY_DEPENDENCY_REPORT to a new absolute .json file in an existing directory")
		quit(2)
		return
	var started := Time.get_ticks_msec()
	_graph_cases()
	_reference_cases()
	_malformed_cases()
	_scope_cases()
	_permutation_cases()
	var passed := not _cases.is_empty() and _cases.all(func(record): return bool(record.passed))
	var report := {
		"schema": "mandatory-physical-dependency-contract/v1",
		"evidenceLevel": "synthetic_direct_helper_contract",
		"passed": passed, "caseCount": _cases.size(), "cases": _cases,
		"reportPath": path, "elapsedMsec": Time.get_ticks_msec() - started,
		"helper": "res://scripts/buildings/MandatoryPhysicalDependencyValidator.gd",
		"entryPoint": "static apply(parts: Array, checks: Array, violations: Array) -> void",
		"requiredRecipeKeys": REQUIRED,
		"scope": "Monotonic failure closure of authored Support/Seat/Anchor requirements over supplied local/gable outcomes. Every fixture calls the real helper directly twice.",
		"doesNotProve": [
			"Whole-validator malformed-input robustness: earlier casts are unsafe and are bypassed here.",
			"Production integration or placement after the gable pass.",
			"Rootedness, physical validity of an all-true cycle, or geometry/collision correctness.",
			"Queue implementation, asymptotic performance, rendered visuals, or live gameplay/NPC acceptance."
		]
	}
	if not _write_report(path, report):
		quit(2)
		return
	print("SYNTHETIC mandatory dependency contract: ", "PASS" if passed else "FAIL", " report=", path)
	quit(0 if passed else 1)


func _graph_cases() -> void:
	# Reverse dependency order defeats a one-pass forward-only implementation.
	var chain := [
		_part("cap", {REQUIRED[2]: ["beam"]}),
		_part("beam", {REQUIRED[0]: ["post"]}),
		_part("post", {REQUIRED[1]: ["base"]}), _part("base"), _part("unrelated")
	]
	_exercise("mixed_chain_from_local_failure", chain, ["base"], ["base", "post", "beam", "cap"])
	_exercise("mixed_chain_all_true", chain, [], [])
	var diamond := [
		_part("top", {REQUIRED[1]: ["left", "right"]}),
		_part("left", {REQUIRED[0]: ["base"]}),
		_part("right", {REQUIRED[2]: ["base"]}), _part("base"), _part("unrelated")
	]
	_exercise("diamond_shared_failed_base", diamond, ["base"], ["base", "left", "right", "top"])
	_exercise("diamond_one_failed_arm", diamond, ["left"], ["left", "top"])
	_exercise("diamond_all_true", diamond, [], [])
	for key in REQUIRED:
		var bearers := [_part("span", {key: ["left", "right"]}), _part("left"), _part("right")]
		_exercise("and_" + key + "_left_failed", bearers, ["left"], ["left", "span"])
		_exercise("and_" + key + "_right_failed", bearers, ["right"], ["right", "span"])
		_exercise("and_" + key + "_both_failed", bearers, ["left", "right"], ["left", "right", "span"])
		_exercise("and_" + key + "_all_true", bearers, [], [])
	var all_kinds := [
		_part("owner", {REQUIRED[0]: ["support"], REQUIRED[1]: ["seat"], REQUIRED[2]: ["anchor"]}),
		_part("support"), _part("seat"), _part("anchor")
	]
	for seed_id in ["support", "seat", "anchor"]:
		_exercise("and_across_keys_" + seed_id, all_kinds, [seed_id], [seed_id, "owner"])
	_exercise("and_across_keys_all_true", all_kinds, [], [])
	var cycle := [
		_part("a", {REQUIRED[0]: ["b"]}), _part("b", {REQUIRED[1]: ["c"]}),
		_part("c", {REQUIRED[2]: ["a"]}), _part("tail", {REQUIRED[1]: ["b"]}), _part("unrelated")
	]
	for seed_id in ["a", "b", "c"]:
		_exercise("initially_failed_cycle_" + seed_id, cycle, [seed_id], ["a", "b", "c", "tail"])
	_exercise("well_formed_unseeded_cycle_all_true_scope_boundary", cycle, [], [])
	_exercise("self_cycle_initially_failed", [_part("self", {REQUIRED[1]: ["self"]})], ["self"], ["self"])
	_exercise("self_cycle_all_true_scope_boundary", [_part("self", {REQUIRED[1]: ["self"]})], [], [])
	# Bounded depth coverage only; not a timing benchmark or queue-source audit.
	var long_chain: Array = []
	var expected: Array = []
	for index in range(255, -1, -1):
		var part_id := "link_%03d" % index
		long_chain.append(_part(part_id, {} if index == 0 else {REQUIRED[index % 3]: ["link_%03d" % (index - 1)]}))
		expected.append(part_id)
	_exercise("reverse_256_member_chain", long_chain, ["link_000"], expected)


func _reference_cases() -> void:
	for key in REQUIRED:
		_exercise("missing_target_" + key, [
			_part("owner", {key: ["missing"]}), _part("tail", {REQUIRED[1]: ["owner"]}), _part("unrelated")
		], [], ["owner", "tail"])
		_exercise("missing_one_of_two_targets_" + key, [
			_part("owner", {key: ["present", "missing"]}), _part("present"),
			_part("tail", {REQUIRED[2]: ["owner"]})
		], [], ["owner", "tail"])
		# Two real BuildingPart records share an ID, but the supplied local check
		# is true. A dictionary overwrite must not certify a unique target.
		_exercise("duplicate_source_target_id_" + key, [
			_part("owner", {key: ["twin"]}), _part("twin"), _part("twin"),
			_part("tail", {REQUIRED[0]: ["owner"]}), _part("unrelated")
		], [], ["owner", "tail"])
		_exercise("duplicate_source_and_check_ids_leave_twins_true_" + key, [
			_part("owner", {key: ["twin"]}), _part("twin"), _part("twin"),
			_part("tail", {REQUIRED[0]: ["owner"]})
		], [], ["owner", "tail"], ["twin", "owner", "tail", "twin"])
		var parts := [_part("owner", {key: ["target"]}), _part("target"), _part("tail", {REQUIRED[0]: ["owner"]})]
		_exercise("missing_target_local_check_" + key, parts, [], ["owner", "tail"], ["tail", "owner"])
		_exercise("ambiguous_target_local_checks_" + key, parts, [], ["owner", "tail"], ["tail", "target", "owner", "target"])


func _malformed_cases() -> void:
	# Values are inserted AFTER BuildingPart construction; no constructor cast
	# or full-validator path can accidentally stand in for the helper test.
	var bad_arrays := [null, "target", 17, 2.5, true, {"target": true}, PackedStringArray(["target"])]
	var bad_values := [null, 17, 2.5, true, {"id": "target"}, ["target"], Vector3.ONE,
		&"target", "", "   ", " target", "target ", "\ttarget\n"]
	for key in REQUIRED:
		for index in bad_arrays.size():
			_malformed_case("malformed_array_" + key + "_%02d" % index, key, bad_arrays[index])
		for index in bad_values.size():
			_malformed_case("malformed_value_" + key + "_%02d" % index, key, [bad_values[index]])
			_malformed_case("mixed_valid_invalid_values_" + key + "_%02d" % index, key, ["target", bad_values[index]])
		_exercise("empty_required_array_is_no_obligation_" + key, [_part("owner", {key: []})], [], [])


func _malformed_case(case_id: String, key: String, value: Variant) -> void:
	var owner = _part("owner")
	owner.recipe[key] = value
	_exercise(case_id, [owner, _part("target"), _part("tail", {REQUIRED[2]: ["owner"]}), _part("unrelated")],
		[], ["owner", "tail"], [], false, ["owner"])


func _scope_cases() -> void:
	var ignored := {
		"physicalSupportPartIds": ["failed", "missing"],
		"physicalAnchorPartIds": ["failed", "missing"],
		"physicalAllowedSupportPartIds": ["failed", "missing"],
		"physicalAllowedSeatPartIds": ["failed", "missing"],
		"physicalAllowedAnchorPartIds": ["failed", "missing"],
		"physicalRequiredPurlinPartIds": ["failed"],
		"physicalRequiredPostPartIds": ["failed"],
		"physicalRequiredGableBearerId": "failed"
	}
	_exercise("unrelated_inferred_allowed_and_gable_specific_not_edges", [
		_part("failed"), _part("ignored", ignored), _part("unrelated"),
		_part("dependent_of_ignored", {REQUIRED[0]: ["ignored"]})
	], ["failed"], ["failed"])
	var malformed_ignored := ignored.duplicate(true)
	for key in malformed_ignored:
		malformed_ignored[key] = 42
	_exercise("malformed_nonmandatory_fields_not_owned_here", [_part("ignored", malformed_ignored)], [], [])
	_exercise("incidental_good_support_cannot_rescue_required_failure", [
		_part("failed"), _part("good"), _part("owner", {
			REQUIRED[1]: ["failed"], "physicalSupportPartIds": ["good"],
			"physicalAllowedSupportPartIds": ["good"], "physicalRoot": true
		})
	], ["failed"], ["failed", "owner"])
	# The pre-existing reason emulates a completed gable rejection. This tests
	# consumption of that failure, NOT the gable validator or integration order.
	_exercise("supplied_post_gable_failure_propagates", [
		_part("gable"), _part("mounted", {REQUIRED[2]: ["gable"]})
	], ["gable"], ["gable", "mounted"])
	_exercise("empty_input", [], [], [])
	_exercise("minimal_checks_have_no_required_local_fact_schema", [
		_part("base"), _part("owner", {REQUIRED[1]: ["base"]})
	], ["base"], ["base", "owner"], [], true)


func _permutation_cases() -> void:
	var source := [
		_part("root_a"), _part("root_b"), _part("left", {REQUIRED[0]: ["root_a"]}),
		_part("right", {REQUIRED[2]: ["root_b"]}),
		_part("join", {REQUIRED[1]: ["left", "right"], REQUIRED[0]: ["root_b"]}),
		_part("missing_owner", {REQUIRED[2]: ["absent"]}),
		_part("tip", {REQUIRED[0]: ["join", "missing_owner"]}), _part("unrelated")
	]
	var expected := ["root_a", "root_b", "left", "right", "join", "missing_owner", "tip"]
	var orders := [
		[0, 1, 2, 3, 4, 5, 6, 7], [7, 6, 5, 4, 3, 2, 1, 0],
		[6, 4, 2, 0, 7, 5, 3, 1], [1, 3, 5, 7, 0, 2, 4, 6]
	]
	var baseline: Dictionary = {}
	# Vary source order independently of checks; never use global RNG.
	for source_index in orders.size():
		for check_index in orders.size():
			var parts: Array = []
			var check_ids: Array = []
			for index in orders[source_index]:
				parts.append(source[index])
			for index in orders[check_index]:
				check_ids.append(source[index].id)
			var result := _exercise("order_%d_%d" % [source_index, check_index], parts,
				["root_a", "root_b"], expected, check_ids)
			if baseline.is_empty():
				baseline = result
			var assertions: Dictionary = result["assertions"]
			assertions["same_failed_ids_as_baseline"] = result["failedPartIds"] == baseline["failedPartIds"]
			assertions["same_reasons_per_id_as_baseline"] = result["reasonsPerId"] == baseline["reasonsPerId"]
			result["passed"] = assertions.values().all(func(value): return bool(value))


func _part(part_id: String, recipe: Dictionary = {}):
	var part = Part.new({
		"id": part_id, "kind": "beam", "material": "oak",
		"position": Vector3(1.25, 3.5, -2.75), "rotation": Vector3(0.1, 0.2, 0.3),
		"size": Vector3(0.3, 2.5, 0.4), "collision": true,
		"semantic": "synthetic_dependency_member", "physicalIntent": "structural_mass",
		"recipe": {"visual": {"tint": [0.3, 0.5, 0.7], "grain": "preserve"}}
	})
	part.recipe.merge(recipe.duplicate(true), true)
	return part


func _exercise(case_id: String, parts: Array, initial_failed: Array, expected_failed: Array,
		check_order: Array = [], minimal_checks: bool = false, malformed_ids: Array = []) -> Dictionary:
	var ids := check_order.duplicate()
	if ids.is_empty():
		for part in parts:
			if not ids.has(part.id):
				ids.append(part.id)
	# Use the typed production containers as well as real BuildingPart objects.
	var checks: Array[Dictionary] = []
	for index in ids.size():
		var check := {"partId": ids[index], "passed": not initial_failed.has(ids[index])}
		if not minimal_checks:
			check.merge({
				"reachesGroundRoot": true, "hasRootedSeats": true,
				"hasValidGableFrame": not initial_failed.has(ids[index]),
				"supportCoverage": [{"cell": Vector3(1, 2, 3), "passed": true}],
				"arbitraryLocalFacts": {"ordinal": index, "nested": [false, null, {"note": "keep me"}]},
				"localReasons": ["local observation retained", "second observation retained"]
			})
		checks.append(check)
	var violations: Array[String] = []
	for part_id in initial_failed:
		violations.append("%s existing local failure (first reason)" % part_id)
		violations.append("%s existing local failure (second reason)" % part_id)
	var original_checks := checks.duplicate(true)
	var original_violations := violations.duplicate(true)
	var original_parts := _part_snapshots(parts)
	var original_references := parts.duplicate()
	Dependency.apply(parts, checks, violations)
	var failed := _failed_ids(checks)
	var expected := expected_failed.duplicate()
	expected.sort()
	var reasons := _reasons_per_id(ids, violations)
	var assertions := {
		"exact_failed_ids": failed == expected,
		"monotonic_no_failure_resurrected": initial_failed.all(func(part_id): return failed.has(part_id)),
		"checks_order_count_and_original_local_facts_preserved": _checks_preserved(original_checks, checks),
		"only_new_failures_gain_dependency_false_metadata": _only_expected_check_changes(original_checks, checks, expected),
		"existing_reasons_preserved_in_original_order": violations.slice(0, original_violations.size()) == original_violations,
		"exact_constant_reason_once_per_new_failure": _exact_new_reasons(original_checks, violations.slice(original_violations.size()), expected, malformed_ids),
		"all_failed_ids_have_reasons": failed.all(func(part_id): return not reasons.get(part_id, []).is_empty()),
		"no_new_reasons_for_passing_ids": _new_reasons_only_for_failed(violations.slice(original_violations.size()), failed),
		"no_duplicate_added_reasons": _unique_additions(original_violations, violations),
		"unaffected_checks_exactly_unchanged": _unaffected_checks_preserved(original_checks, checks, expected),
		"source_parts_recipes_geometry_and_order_unchanged": _same(original_parts, _part_snapshots(parts)) and parts == original_references
	}
	var once_checks := checks.duplicate(true)
	var once_violations := violations.duplicate(true)
	Dependency.apply(parts, checks, violations)
	assertions["idempotent_checks_and_reasons_including_order"] = _same(once_checks, checks) and _same(once_violations, violations)
	assertions["second_apply_source_snapshot_unchanged"] = _same(original_parts, _part_snapshots(parts)) and parts == original_references
	var result := {
		"id": case_id, "passed": assertions.values().all(func(value): return bool(value)),
		"assertions": assertions, "partCount": parts.size(), "checkOrder": ids,
		"initialFailedIds": initial_failed, "expectedFailedIds": expected, "failedPartIds": failed,
		"originalReasons": original_violations, "violations": once_violations, "reasonsPerId": reasons
	}
	_cases.append(result)
	return result


func _checks_preserved(before: Array, after: Array) -> bool:
	if before.size() != after.size():
		return false
	for index in before.size():
		if not after[index] is Dictionary or typeof(after[index].get("passed")) != TYPE_BOOL:
			return false
		for key in before[index]:
			if key != "passed" and (not after[index].has(key) or not _same(before[index][key], after[index][key])):
				return false
	return true


func _only_expected_check_changes(before: Array, after: Array, failed: Array) -> bool:
	if before.size() != after.size():
		return false
	for index in before.size():
		var expected: Dictionary = before[index].duplicate(true)
		if expected.passed and failed.has(expected.partId):
			expected["passed"] = false
			expected["hasValidRequiredDependencies"] = false
		if not _same(expected, after[index]):
			return false
	return true


func _exact_new_reasons(before: Array, added: Array, failed: Array, malformed_ids: Array) -> bool:
	var expected: Array = []
	for check in before:
		if check.passed and failed.has(check.partId):
			var reason := MALFORMED_REASON if malformed_ids.has(check.partId) else FAILED_REASON
			expected.append("%s %s" % [check.partId, reason])
	# Original reasons retain their order; added reasons are compared as a
	# multiset so source/check permutations are not required to share an order.
	var actual := added.duplicate()
	expected.sort()
	actual.sort()
	return expected == actual


func _unaffected_checks_preserved(before: Array, after: Array, failed: Array) -> bool:
	if before.size() != after.size():
		return false
	for index in before.size():
		if not failed.has(before[index].partId) and not _same(before[index], after[index]):
			return false
	return true


func _failed_ids(checks: Array) -> Array:
	var result: Array = []
	for check in checks:
		if not check.get("passed", false) and not result.has(check.partId):
			result.append(check.partId)
	result.sort()
	return result


func _reasons_per_id(ids: Array, violations: Array) -> Dictionary:
	# Production violations use '<partId> <reason>'. Compare full reason strings
	# per ID without imposing new global ordering on the appended suffix.
	var result: Dictionary = {}
	for part_id in ids:
		var reasons: Array = []
		for reason in violations:
			if reason.begins_with(part_id + " "):
				reasons.append(reason)
		reasons.sort()
		result[part_id] = reasons
	return result


func _new_reasons_only_for_failed(reasons: Array, failed: Array) -> bool:
	for reason in reasons:
		if not failed.any(func(part_id): return reason.begins_with(part_id + " ") and reason.length() > part_id.length() + 1):
			return false
	return true


func _unique_additions(before: Array, after: Array) -> bool:
	var seen := before.duplicate()
	for reason in after.slice(before.size()):
		if seen.has(reason):
			return false
		seen.append(reason)
	return true


func _part_snapshots(parts: Array) -> Array:
	var snapshots: Array = []
	for part in parts:
		snapshots.append(part.snapshot())
	return snapshots


func _same(left: Variant, right: Variant) -> bool:
	# Binary comparison preserves nested Variant types and dictionary/array order.
	return var_to_bytes(left) == var_to_bytes(right)


func _new_absolute_report_path(path: String) -> bool:
	return not path.is_empty() and path.is_absolute_path() and not path.contains("://") \
		and path.get_extension().to_lower() == "json" \
		and DirAccess.dir_exists_absolute(path.get_base_dir()) \
		and not FileAccess.file_exists(path) and not DirAccess.dir_exists_absolute(path)


func _write_report(path: String, report: Dictionary) -> bool:
	var encoded := JSON.stringify(report, "\t")
	# Recheck immediately before opening, so a completed prior run is not reused.
	if not _new_absolute_report_path(path) or encoded.to_utf8_buffer().size() > MAX_REPORT_BYTES:
		push_error("Mandatory dependency report path is no longer new, or report exceeds byte limit")
		return false
	var output := FileAccess.open(path, FileAccess.WRITE)
	if output == null:
		push_error("Cannot open mandatory dependency report: %s (error %s)" % [path, FileAccess.get_open_error()])
		return false
	output.store_string(encoded)
	output.flush()
	var error := output.get_error()
	output.close()
	if error != OK:
		push_error("Mandatory dependency report write failed: %s" % error)
		return false
	return true
