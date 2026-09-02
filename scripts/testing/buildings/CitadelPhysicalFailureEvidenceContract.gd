extends SceneTree

## SYNTHETIC DIRECT-HELPER CONTRACT ONLY. Supplied validation outcomes are fixtures,
## not physical acceptance. No generation, publication, physics, NPCs or rendering.
## VOXEL_PHYSICAL_FAILURE_EVIDENCE_REPORT must name a fresh absolute JSON file in
## an existing directory. Exit 0: pass; 1: assertion failure; 2: report writer error.
const Evidence = preload("res://scripts/buildings/CitadelPhysicalFailureEvidence.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const BYTE_LIMIT := 1048576
const SCOPE := "Synthetic direct-helper evidence projection only: supplied checks, geometry records, references, deterministic ordering, input immutability and diagnostic caps. Does not prove production integration, physical validity, generated Citadel acceptance, rendering, gameplay or NPC/navigation behavior."

class ObservedBlueprint extends Blueprint:
	var validation_calls := 0
	var resolution_calls := 0

	func validate_physical_integrity() -> Dictionary:
		validation_calls += 1
		return {"passed": true, "checks": [], "violations": []}

	func resolve_physical_contracts() -> void:
		resolution_calls += 1

var checks: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path := OS.get_environment("VOXEL_PHYSICAL_FAILURE_EVIDENCE_REPORT").strip_edges()
	if not _fresh_path(path):
		push_error("VOXEL_PHYSICAL_FAILURE_EVIDENCE_REPORT requires a fresh absolute .json path with an existing parent")
		quit(2)
		return
	var started := Time.get_ticks_msec()
	_exact_case()
	_reference_cases()
	_malformed_cases()
	_cap_cases()
	_byte_cases()
	_check("bounded_synthetic_runtime_under_60_seconds", Time.get_ticks_msec() - started < 60000)
	var passed := not checks.is_empty() and checks.all(func(row): return bool(row.passed))
	if not _write_report(path, {"passed": passed, "checks": checks, "scope": SCOPE}):
		quit(2)
		return
	print("SYNTHETIC physical failure evidence contract: ", "PASS" if passed else "FAIL", " checks=", checks.size(), " report=", path)
	quit(0 if passed else 1)


func _exact_case() -> void:
	var proof := ObservedBlueprint.new("synthetic_evidence", 37, "stone")
	var beam = _part(proof, "beam", {
		"physicalRequiredSupportPartIds": ["support_missing", "support"],
		"physicalRequiredSeatPartIds": ["seat"],
		"physicalRequiredAnchorPartIds": ["anchor_missing", "anchor"]})
	var anchor = _part(proof, "anchor")
	var seat = _part(proof, "seat")
	var support = _part(proof, "support", {"physicalRequiredSupportPartIds": ["grandparent"]})
	_part(proof, "grandparent")
	_part(proof, "unrelated")
	var samples: Array = []
	for index in range(25):
		samples.append({"sample": "sample_%02d" % index, "position": Vector3(index, -0.25, index * 0.5),
			"supportPartId": "support" if index != 24 else "", "supported": index != 24})
	var failed_row := {"partId": "beam", "passed": false, "intent": "structural_mass",
		"supportPartIds": ["support"], "anchorPartIds": ["anchor"], "supportCoverage": samples,
		"requiredSupportPartIds": ["support_missing", "support"], "requiredSeatPartIds": ["seat"],
		"requiredAnchorPartIds": ["anchor_missing", "anchor"], "reachesGroundRoot": false,
		"hasRootedCoverage": false, "hasRootedSeats": true, "classification": "supplied_only",
		"extension": {"nested": [false, 25, {"preserve": "all fields"}]}}
	var other_row := {"partId": "beam", "passed": true, "phase": "local", "retained": [1, 2, 3]}
	var support_row := {"partId": "support", "passed": true, "supportPartIds": ["grandparent"], "detail": {"root": false}}
	var report := {"passed": false, "failureCount": 1,
		"checks": [other_row, support_row, failed_row, {"partId": "unrelated", "passed": true}],
		"violations": ["beam z supplied failure", "beamer not this ID", "beam a supplied failure", "unrelated ignored"]}
	var result := _collect("exact", proof, report)
	_expect_counts("exact", result, [1, 1, 5, 5, 2, 2])
	_check("exact_complete_and_schema", result.get("schema") == "citadel_physical_failure_evidence/v1" and result.get("complete") == true and result.get("overflowReasons") == [])
	var entry := _entry(result, "beam")
	_check("exact_all_check_rows_and_25_samples", entry.get("checkRows") == _sorted_rows([failed_row, other_row]))
	_check("exact_full_failed_geometry", entry.get("part") == {"occurrenceCount": 1, "records": [_geometry(beam)]})
	_check("exact_required_minus_discovered", entry.get("requiredMinusDiscovered") == {"support": ["support_missing"], "anchor": ["anchor_missing"]})
	_check("exact_sorted_boundary_matched_violations", entry.get("violations") == ["beam a supplied failure", "beam z supplied failure"])
	var expected_dependencies := [
		_dependency("anchor", [_geometry(anchor)]), _dependency("anchor_missing", []),
		_dependency("seat", [_geometry(seat)]), _dependency("support", [_geometry(support)], [support_row]),
		_dependency("support_missing", [])]
	_check("exact_direct_dependencies_geometry_rows_missing_and_no_recursive_expansion", entry.get("dependencies") == expected_dependencies)
	# Reverse unique input records and outcome rows, not sample order inside a row:
	# complete rows must remain intact, including meaningful nested array order.
	proof.parts.reverse()
	report.checks.reverse()
	report.violations.reverse()
	var reordered := _collect("reordered_unique_inputs", proof, report)
	_check("reordered_unique_inputs_identical_json", JSON.stringify(result, "\t") == JSON.stringify(reordered, "\t"))
	# Editing returned nested evidence must not alias the original supplied report.
	var original_bytes := var_to_bytes(_snapshot(proof, report))
	for row in entry.get("checkRows", []):
		if row.has("supportCoverage"):
			row.supportCoverage[0]["supported"] = false
	for record in entry.get("part", {}).get("records", []):
		record.requiredSupportPartIds.append("output_only")
	_check("returned_nested_records_are_detached", original_bytes == var_to_bytes(_snapshot(proof, report)))


func _reference_cases() -> void:
	for count in [0, 1, 2, 3, 7]:
		for duplicate_owner in ["failed", "dependency"]:
			var proof := ObservedBlueprint.new()
			if duplicate_owner == "dependency":
				_part(proof, "failed", {"physicalRequiredSupportPartIds": ["dependency", "dependency"],
					"physicalRequiredSeatPartIds": ["dependency"], "physicalRequiredAnchorPartIds": ["dependency"]})
			var expected: Array = []
			for index in range(count):
				var part = _part(proof, duplicate_owner)
				part.position.x = float(index)
				expected.append(_geometry(part))
			var report := {"passed": false, "checks": [{"partId": "failed", "passed": false}], "violations": ["failed original failure"]}
			var label := "%s_occurrences_%d" % [duplicate_owner, count]
			var result := _collect(label, proof, report)
			var entry := _entry(result, "failed")
			var record: Dictionary = entry.get("part", {})
			if duplicate_owner == "dependency":
				var dependencies: Array = entry.get("dependencies", [])
				record = dependencies[0] if dependencies.size() == 1 else {}
				_check(label + "_unique_direct_ref", result.get("dependencyTotal") == 1 and result.get("dependencyEmitted") == 1)
			_check(label + "_exact_count_and_capped_geometry", record.get("occurrenceCount") == count and record.get("records") == _sorted_rows(expected).slice(0, 2))
			_check(label + "_explicit_completeness", result.get("complete") == (count <= 2) and result.get("overflowReasons") == (["duplicate_geometry_limit"] if count > 2 else []))
	var proof := ObservedBlueprint.new()
	# An invalid unreferenced geometry is intentional: collection must not validate it.
	_part(proof, "not_checked", {"physicalRequiredSupportPartIds": ["absent"]})
	var report := {"passed": true, "checks": [], "violations": []}
	var empty := _collect("empty_supplied_outcomes", proof, report)
	_expect_counts("empty", empty, [0, 0, 0, 0, 0, 0])
	_check("empty_no_invented_failures", empty.get("complete") == true and empty.get("failures") == [] and empty.get("overflowReasons") == [])
	report = {"passed": false, "failureCount": 3, "checks": [{"partId": "not_checked", "passed": true}], "violations": ["external failure without a failed row"]}
	var external := _collect("external_original_failure", proof, report)
	_check("nonzero_original_failure_not_reinterpreted_as_pass", report.passed == false and report.failureCount == 3 and external.get("failures") == [] and not external.has("passed"))
	var row_only := _collect("row_only_required_references", ObservedBlueprint.new(), {
		"passed": false, "checks": [{"partId": "failed", "passed": false,
			"requiredSupportPartIds": ["support"], "requiredAnchorPartIds": ["anchor"]}], "violations": []})
	_check("row_only_required_minus_discovered", _entry(row_only, "failed").get("requiredMinusDiscovered") == {"support": ["support"], "anchor": ["anchor"]})


func _malformed_cases() -> void:
	var recipe_fields := ["physicalRequiredSupportPartIds", "physicalRequiredSeatPartIds", "physicalRequiredAnchorPartIds"]
	var row_fields := ["supportPartIds", "anchorPartIds", "requiredSupportPartIds", "requiredSeatPartIds", "requiredAnchorPartIds"]
	for source in ["recipe", "row"]:
		for field in (recipe_fields if source == "recipe" else row_fields):
			for spec in [
				["nonarray", "bogus_id", [{"index": -1, "type": TYPE_STRING}]],
				["null", null, [{"index": -1, "type": TYPE_NIL}]],
				["mixed", ["valid", null, 42, {}, [], true, "", " padded "], [
					{"index": 1, "type": TYPE_NIL}, {"index": 2, "type": TYPE_INT},
					{"index": 3, "type": TYPE_DICTIONARY}, {"index": 4, "type": TYPE_ARRAY},
					{"index": 5, "type": TYPE_BOOL}, {"index": 6, "type": TYPE_STRING},
					{"index": 7, "type": TYPE_STRING}]]]:
				var proof := ObservedBlueprint.new()
				var part = _part(proof, "failed")
				_part(proof, "valid")
				var row := {"partId": "failed", "passed": false}
				if source == "recipe":
					part.recipe[field] = spec[1]
				else:
					row[field] = spec[1]
				var report := {"passed": false, "checks": [row], "violations": ["failed original"]}
				var label := "malformed_%s_%s_%s" % [source, field, spec[0]]
				var result := _collect(label, proof, report)
				var entry := _entry(result, "failed")
				_check(label + "_explicit_incomplete", result.get("complete") == false and result.get("overflowReasons") == ["malformed_reference_field"])
				_check(label + "_no_stringified_bogus_ids", _ids(entry.get("dependencies", [])) == (["valid"] if spec[0] == "mixed" else []))
				_check(label + "_complete_original_check_row", entry.get("checkRows") == [row])
				var expected_diagnostics: Array = []
				for invalid in spec[2]:
					expected_diagnostics.append({"ownerId": "failed", "field": field, "index": invalid.index, "type": invalid.type})
				var diagnostics: Array = result.get("malformedFields", [])
				# The total counts observations, not unique fields: a recipe can be
				# visited during both dependency gathering and geometry projection.
				_check(label + "_typed_observations", not diagnostics.is_empty()
					and diagnostics.all(func(item): return expected_diagnostics.has(item))
					and expected_diagnostics.all(func(item): return diagnostics.has(item)))
				_check(label + "_all_observations_accounted", result.get("malformedFieldTotal", -1) == diagnostics.size()
					and result.get("malformedFieldEmitted", -1) == diagnostics.size() and diagnostics.size() <= 128)
				var geometry_ok := true
				for record in entry.get("part", {}).get("records", []):
					for key in ["requiredSupportPartIds", "requiredSeatPartIds", "requiredAnchorPartIds"]:
						var projected: Variant = record.get(key)
						geometry_ok = geometry_ok and projected is Array
						if projected is Array:
							geometry_ok = geometry_ok and projected.all(func(id): return id is String and id == "valid")
				_check(label + "_geometry_references_valid_strings_only", geometry_ok)
	# A malformed declaration encountered only in dependency geometry is included.
	var proof := ObservedBlueprint.new()
	_part(proof, "failed", {"physicalRequiredSupportPartIds": ["dependency"]})
	_part(proof, "dependency", {"physicalRequiredAnchorPartIds": null})
	var dependency_result := _collect("malformed_dependency_geometry", proof,
		{"passed": false, "checks": [{"partId": "failed", "passed": false}], "violations": []})
	_check("malformed_dependency_geometry_reported", dependency_result.get("complete") == false
		and dependency_result.get("malformedFields", []).has({"ownerId": "dependency", "field": "physicalRequiredAnchorPartIds", "index": -1, "type": TYPE_NIL}))
	for invalid_count in [128, 129]:
		var invalid: Array = []
		invalid.resize(invalid_count)
		var report := {"passed": false, "checks": [{"partId": "failed", "passed": false, "supportPartIds": invalid}], "violations": []}
		var result := _collect("malformed_budget_%d" % invalid_count, ObservedBlueprint.new(), report)
		var diagnostics: Array = result.get("malformedFields", [])
		_check("malformed_budget_%d_exact_observed_total" % invalid_count, result.get("malformedFieldTotal") == invalid_count)
		_check("malformed_budget_%d_emitted_bounded" % invalid_count, diagnostics.size() == mini(invalid_count, 128) and result.get("malformedFieldEmitted") == diagnostics.size())
		_check("malformed_budget_%d_sorted_reasons" % invalid_count, result.get("complete") == false
			and result.get("overflowReasons") == (["malformed_field_limit", "malformed_reference_field"] if invalid_count > 128 else ["malformed_reference_field"]))
		_check("malformed_budget_%d_typed_records" % invalid_count, diagnostics.all(func(item):
			return item is Dictionary and item.size() == 4 and item.get("ownerId") == "failed" \
				and item.get("field") == "supportPartIds" and typeof(item.get("index")) == TYPE_INT \
				and item.index >= 0 and item.index < 128 and typeof(item.get("type")) == TYPE_INT and item.type == TYPE_NIL))


func _cap_cases() -> void:
	# Shared dependencies still count once per emitted failure's direct evidence.
	for spec in [
		["failure_boundary", 16, 0, 1, [16, 16, 0, 0, 16, 16], []],
		["failure_overflow", 17, 1, 1, [17, 16, 17, 16, 17, 16], ["failed_part_limit"]],
		["dependency_boundary", 1, 64, 0, [1, 1, 64, 64, 0, 0], []],
		["dependency_overflow", 1, 65, 0, [1, 1, 65, 64, 0, 0], ["per_failure_dependency_limit"]],
		["global_dependency_boundary", 4, 64, 0, [4, 4, 256, 256, 0, 0], []],
		["global_dependency_overflow", 5, 64, 0, [5, 5, 320, 256, 0, 0], ["total_dependency_limit"]],
		["violation_boundary", 1, 0, 128, [1, 1, 0, 0, 128, 128], []],
		["violation_overflow", 1, 0, 129, [1, 1, 0, 0, 129, 128], ["violation_limit"]],
		["combined_overflow", 17, 65, 9, [17, 16, 1105, 256, 153, 128],
			["failed_part_limit", "per_failure_dependency_limit", "total_dependency_limit", "violation_limit"]]]:
		var fixture := _cap_fixture(int(spec[1]), int(spec[2]), int(spec[3]))
		var result := _collect(String(spec[0]), fixture.proof, fixture.report)
		_expect_counts(String(spec[0]), result, spec[4])
		_check(String(spec[0]) + "_completeness_reasons", result.get("complete") == (spec[5] == []) and result.get("overflowReasons") == spec[5])
		var expected_ids: Array = []
		for index in range(mini(int(spec[1]), 16)):
			expected_ids.append("failure_%03d" % index)
		_check(String(spec[0]) + "_sorted_failure_prefix", _ids(result.get("failures", [])) == expected_ids)
		var dependencies_seen := 0
		var violations_seen := 0
		var prefixes_ok := true
		for entry in result.get("failures", []):
			var expected_deps: Array = []
			for index in range(mini(mini(int(spec[2]), 64), 256 - dependencies_seen)):
				expected_deps.append("dependency_%03d" % index)
			var expected_violations: Array = []
			for index in range(mini(int(spec[3]), 128 - violations_seen)):
				expected_violations.append("%s violation_%03d" % [entry.partId, index])
			prefixes_ok = prefixes_ok and _ids(entry.dependencies) == expected_deps and entry.violations == expected_violations
			dependencies_seen += entry.dependencies.size()
			violations_seen += entry.violations.size()
		_check(String(spec[0]) + "_exact_dependency_violation_prefixes", prefixes_ok)
		_check(String(spec[0]) + "_counters_match_arrays", dependencies_seen == result.get("dependencyEmitted") and violations_seen == result.get("violationEmitted"))


func _byte_cases() -> void:
	var fixture := _cap_fixture(1, 1, 1)
	fixture.report.checks[0]["padding"] = ""
	var baseline := _collect("byte_baseline", fixture.proof, fixture.report)
	var padding_bytes := BYTE_LIMIT - _nested_bytes(baseline)
	_check("byte_fixture_has_positive_padding_budget", padding_bytes > 0)
	if padding_bytes <= 0:
		return
	# Multibyte text tests bytes, not character count; pretty indentation is material.
	var padding := "é".repeat(floori(float(padding_bytes) / 2.0)) + ("x" if padding_bytes % 2 else "")
	fixture.report.checks[0].padding = padding
	var expected := baseline.duplicate(true)
	expected.failures[0].checkRows[0].padding = padding
	_check("byte_fixture_exact_nested_pretty_limit", _nested_bytes(expected) == BYTE_LIMIT)
	var boundary := _collect("byte_exact_boundary", fixture.proof, fixture.report)
	_check("exact_one_mib_is_complete", boundary.get("complete") == true and boundary == expected)
	fixture.report.checks[0].padding += "x"
	expected.failures[0].checkRows[0].padding += "x"
	_check("byte_overflow_standalone_fits_but_nested_exceeds", JSON.stringify(expected, "\t").to_utf8_buffer().size() <= BYTE_LIMIT and _nested_bytes(expected) == BYTE_LIMIT + 1)
	var overflow := _collect("pretty_byte_overflow", fixture.proof, fixture.report)
	_expect_counts("pretty_byte_overflow", overflow, [1, 0, 1, 0, 1, 0])
	_check("byte_overflow_clears_only_evidence", overflow.get("complete") == false and overflow.get("failures") == [] and overflow.get("overflowReasons") == ["diagnostic_byte_limit"])
	_check("byte_overflow_retains_external_failure", fixture.report.passed == false and fixture.report.failureCount == 1 and fixture.report.violations == ["failure_000 violation_000"])
	_check("byte_overflow_result_bounded", _nested_bytes(overflow) <= BYTE_LIMIT)
	fixture.report.checks[0].padding = "x".repeat(BYTE_LIMIT + 1)
	var oversized := _collect("oversized_single_string", fixture.proof, fixture.report)
	_expect_counts("oversized_single_string", oversized, [1, 0, 1, 0, 1, 0])
	_check("oversized_single_string_clears_evidence", oversized.get("complete") == false and oversized.get("failures") == [] and oversized.get("overflowReasons") == ["diagnostic_byte_limit"] and _nested_bytes(oversized) <= BYTE_LIMIT)


func _nested_bytes(result: Dictionary) -> int:
	return JSON.stringify({"structuralCompletionFailure": {"physicalFailureEvidence": result}}, "\t").to_utf8_buffer().size()


func _cap_fixture(failure_count: int, dependency_count: int, violation_count: int) -> Dictionary:
	var proof := ObservedBlueprint.new()
	var ids: Array = []
	for index in range(dependency_count - 1, -1, -1):
		var id := "dependency_%03d" % index
		ids.append(id)
		_part(proof, id)
	var report := {"passed": false, "failureCount": failure_count, "checks": [], "violations": []}
	for index in range(failure_count - 1, -1, -1):
		var id := "failure_%03d" % index
		_part(proof, id, {"physicalRequiredSupportPartIds": ids.duplicate()})
		report.checks.append({"partId": id, "passed": false})
		for violation in range(violation_count - 1, -1, -1):
			report.violations.append("%s violation_%03d" % [id, violation])
	return {"proof": proof, "report": report}


func _part(proof, id: String, recipe: Dictionary = {}):
	var values := recipe.duplicate(true)
	values["physicalRoot"] = true
	return proof.add_part({"id": id, "kind": "beam", "semantic": "synthetic_member", "material": "timber_board",
		"position": Vector3(1.25, -2.5, 3.75), "rotation": Vector3(0.125, -0.25, 0.5),
		"size": Vector3(2.0, 3.0, 4.0), "collision": false, "physicalIntent": "structural_mass", "recipe": values})


func _geometry(part) -> Dictionary:
	var support: Array = part.recipe.get("physicalRequiredSupportPartIds", []).duplicate()
	var seat: Array = part.recipe.get("physicalRequiredSeatPartIds", []).duplicate()
	var anchor: Array = part.recipe.get("physicalRequiredAnchorPartIds", []).duplicate()
	support.sort()
	seat.sort()
	anchor.sort()
	return {"id": part.id, "kind": part.kind, "semantic": part.semantic,
		"position": part.position, "rotation": part.rotation, "size": part.size,
		"collision": part.collision_enabled, "physicalIntent": part.physical_intent,
		"physicalRoot": part.recipe.get("physicalRoot", false), "requiredSupportPartIds": support,
		"requiredSeatPartIds": seat, "requiredAnchorPartIds": anchor}


func _dependency(id: String, records: Array, rows: Array = []) -> Dictionary:
	return {"partId": id, "occurrenceCount": records.size(), "records": records, "checkRows": rows}


func _snapshot(proof, report: Dictionary) -> Dictionary:
	return {"id": proof.id, "seed": proof.seed, "style": proof.style, "recipe": proof.recipe,
		"rooms": proof.rooms, "parts": proof.part_snapshots(), "partsById": proof.physical_parts_by_id,
		"supportGrid": proof.structural_support_grid, "invalidGableIds": proof.invalid_gable_part_ids,
		"report": report}


func _collect(label: String, proof, report: Dictionary) -> Dictionary:
	var before := var_to_bytes(_snapshot(proof, report))
	var original_pass: Variant = report.get("passed")
	var original_parts: Array = proof.parts.duplicate()
	var result: Dictionary = Evidence.collect(proof, report)
	_check(label + "_input_immutability", before == var_to_bytes(_snapshot(proof, report)) and original_parts == proof.parts)
	_check(label + "_no_revalidation_or_resolution", proof.validation_calls == 0 and proof.resolution_calls == 0)
	_check(label + "_original_pass_preserved", report.get("passed") == original_pass and not result.has("passed"))
	return result


func _expect_counts(label: String, result: Dictionary, expected: Array) -> void:
	var keys := ["failedPartTotal", "failedPartEmitted", "dependencyTotal", "dependencyEmitted", "violationTotal", "violationEmitted"]
	var actual: Array = []
	for key in keys:
		actual.append(result.get(key, -1))
	_check(label + "_exact_totals_and_emitted_counts", actual == expected)
	_check(label + "_failure_count_matches_array", result.get("failedPartEmitted", -1) == result.get("failures", []).size())


func _entry(result: Dictionary, id: String) -> Dictionary:
	for entry in result.get("failures", []):
		if entry.get("partId") == id:
			return entry
	return {}


func _ids(entries: Array) -> Array:
	var ids: Array = []
	for entry in entries:
		ids.append(entry.get("partId", ""))
	return ids


func _sorted_rows(rows: Array) -> Array:
	var result := rows.duplicate(true)
	result.sort_custom(func(a, b): return JSON.stringify(a) < JSON.stringify(b))
	return result


func _check(id: String, passed: bool) -> void:
	checks.append({"id": id, "passed": passed})
	if not passed:
		push_error("Synthetic evidence assertion failed: " + id)


func _fresh_path(path: String) -> bool:
	return not path.is_empty() and path.is_absolute_path() and not path.contains("://") \
		and path.get_extension().to_lower() == "json" and DirAccess.dir_exists_absolute(path.get_base_dir()) \
		and not FileAccess.file_exists(path) and not DirAccess.dir_exists_absolute(path)


func _write_report(path: String, report: Dictionary) -> bool:
	var encoded := JSON.stringify(report, "\t")
	if not _fresh_path(path) or encoded.to_utf8_buffer().size() > BYTE_LIMIT:
		push_error("Evidence contract report path is occupied or report exceeds its byte limit")
		return false
	var output := FileAccess.open(path, FileAccess.WRITE)
	if output == null:
		push_error("Cannot open evidence contract report: %s" % FileAccess.get_open_error())
		return false
	output.store_string(encoded)
	output.flush()
	var error := output.get_error()
	output.close()
	if error != OK:
		push_error("Evidence contract report write failed: %s" % error)
		return false
	return FileAccess.get_file_as_string(path) == encoded
