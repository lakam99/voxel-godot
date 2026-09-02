extends SceneTree

## SYNTHETIC MATH / ACTUAL BuildingPart CONTRACT ONLY. No source recipe,
## production sampler, validator, world, publication, physics or visual gameplay.
## VOXEL_THRESHOLD_COURSES_REPORT must name a fresh absolute .json path with
## an existing parent. Run separately by Main; no scene or controller edits.
const SPLITTER_PATH := "res://scripts/buildings/ThresholdBearingCourseSplitter.gd"
const PART_PATH := "res://scripts/buildings/BuildingPart.gd"
const MAX_REPORT_BYTES := 262144
var splitter: Script
var part_script: Script
var checks: Array = []
var cases: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path := OS.get_environment("VOXEL_THRESHOLD_COURSES_REPORT").strip_edges()
	if not _fresh_path(path):
		push_error("VOXEL_THRESHOLD_COURSES_REPORT requires a fresh absolute JSON path")
		quit(2)
		return
	splitter = load(SPLITTER_PATH) as Script
	part_script = load(PART_PATH) as Script
	if splitter == null or part_script == null or not splitter.can_instantiate() or not part_script.can_instantiate():
		push_error("Threshold course contract dependency failed compile guard")
		quit(2)
		return
	var constants := splitter.get_script_constant_map()
	_check("policy:fixed_bounds", constants.get("MAX_CANDIDATES") == 64
		and constants.get("MIN_EXPONENT") == -126 and constants.get("MAX_EXPONENT") == 13
		and constants.get("NEIGHBOR_STEPS") == 4 and constants.get("MIN_HEIGHT") == 0.02
		and constants.get("MAX_DIMENSION") == 10000.0)
	_positive_cases()
	_failure_cases()
	_clamp_control()
	_finish(path)


func _positive_cases() -> void:
	var lower := float(Vector3(0, 0.62, 0).y)
	_check("fixture:float32_062", lower == 0.62000000476837158203125)
	var singleton := _case("singleton_half_to_four", 0.5, 4.0, true)
	_check("singleton:preferred", singleton.get("splitTrials") == 0 and singleton.get("candidateCount") == 0
		and singleton.get("courses") == [{"centerY": 2.25, "height": 3.5, "bottom": 0.5, "top": 4.0}])
	var two := _case("float32_062_to_four", lower, 4.0, true)
	_check("two:known_first_fit", two.get("splitTrials") == 5 and two.get("candidateCount") == 18
		and (two.get("courses", []) as Array).size() == 2 and two.courses[0].top == 1.0)
	# Independent bit construction: four's predecessor/successor, no splitter
	# float32 stepping or exact-pair helper is called from this contract.
	var below := _from_bits(0x407fffff)
	var above := _from_bits(0x40800001)
	var predecessor := _case("noninteger_upper_predecessor", lower, below, true)
	_check("predecessor:first_neighbor", predecessor.get("splitTrials") == 1
		and (predecessor.get("courses", []) as Array).size() == 2
		and predecessor.courses[0].top == _from_bits(0x3f7ffffc))
	var successor := _case("noninteger_upper_successor", lower, above, true)
	_check("successor:first_fit", successor.get("splitTrials") == 5
		and (successor.get("courses", []) as Array).size() == 2 and successor.courses[0].top == 1.0)
	for offset in range(2, 5):
		var down := _case("upper_predecessor_%d" % offset, lower, _from_bits(0x40800000 - offset), true)
		var up := _case("upper_successor_%d" % offset, lower, _from_bits(0x40800000 + offset), true)
		_check("upper_neighbors_%d:ordered_first_fit" % offset,
			down.get("splitTrials") == (1 if offset == 3 else 5) and up.get("splitTrials") == 5
			and down.get("candidateCount") == 18 and up.get("candidateCount") == 18)
	_case("minimum_dyadic_course", 1.0, 1.03125, true)
	var minimum_stored_height := _from_bits(0x3ca3d70b)
	_case("first_float32_height_above_clamp", minimum_stored_height / 2.0, minimum_stored_height * 1.5, true)
	_case("upper_bound_inclusive", 9999.0, 10000.0, true)
	# Large candidate space must not reject an already exact singleton.
	var wide := _case("singleton_before_search_limit", 0.5, 10000.0, true)
	_check("wide:singleton_no_search", wide.get("splitTrials") == 0 and wide.get("candidateCount") == 0)


func _failure_cases() -> void:
	var lower := float(Vector3(0, 0.62, 0).y)
	var invalid := [
		["nan_lower", NAN, 4.0, "nonfinite_threshold_course_input"],
		["nan_upper", 0.5, NAN, "nonfinite_threshold_course_input"],
		["infinite_lower", INF, 4.0, "nonfinite_threshold_course_input"],
		["infinite_upper", 0.5, INF, "nonfinite_threshold_course_input"],
		["negative_infinity", -INF, 4.0, "nonfinite_threshold_course_input"],
		["negative_lower", -0.5, 4.0, "invalid_threshold_course_bounds"],
		["negative_upper", 0.5, -4.0, "invalid_threshold_course_bounds"],
		["zero_lower", 0.0, 4.0, "invalid_threshold_course_bounds"],
		["negative_zero_lower", -0.0, 4.0, "invalid_threshold_course_bounds"],
		["zero_span", 0.5, 0.5, "invalid_threshold_course_bounds"],
		["reversed", 4.0, 0.5, "invalid_threshold_course_bounds"],
		["upper_out_of_bounds", 0.5, 10000.5, "invalid_threshold_course_bounds"],
		["both_out_of_bounds", 10001.0, 10002.0, "invalid_threshold_course_bounds"],
		["huge_finite", 0.5, 1.0e300, "invalid_threshold_course_bounds"],
		["too_short", 1.0, 1.015625, "threshold_course_span_too_short"],
		["zero_upper", 0.5, 0.0, "invalid_threshold_course_bounds"]]
	for row: Array in invalid:
		var result := _case(row[0], row[1], row[2], false)
		_check(row[0] + ":explicit_reason_no_search", result.get("reason") == row[3]
			and result.get("splitTrials") == 0 and result.get("candidateCount") == 0)
	var nofit := _case("non_float32_decimal_no_fit", 0.62, 4.0, false)
	_check("nofit:complete_exhaustion", nofit.get("reason") == "no_exact_threshold_courses"
		and nofit.get("splitTrials") == 18 and nofit.get("candidateCount") == 18)
	var below_minimum := _from_bits(0x3ca3d70a)
	var clamp_edge := _case("float32_point02_below_minimum", below_minimum / 2.0, below_minimum * 1.5, false)
	_check("clamp_edge:strict_minimum", clamp_edge.get("reason") == "threshold_course_span_too_short"
		and clamp_edge.get("splitTrials") == 0)
	var empty := _case("no_eligible_split_plane", lower, float(Vector3(0, 0.66, 0).y), false)
	_check("empty:explicit_exhaustion", empty.get("reason") == "no_exact_threshold_courses"
		and empty.get("candidateCount") == 0 and empty.get("splitTrials") == 0)
	var overflow := _case("overflow_despite_early_exact_fit", lower, 10000.0, false)
	_check("overflow:all_planes_before_trials", overflow.get("reason") == "threshold_course_search_overflow"
		and overflow.get("candidateCount") == 126 and overflow.get("splitTrials") == 0)
	# Witness that early truncation WOULD succeed: real part construction,
	# independently supplied two-course geometry. The oversized search must fail.
	var witness := {"ready": true, "courses": [
		{"centerY": (lower + 1.0) / 2.0, "height": 1.0 - lower, "bottom": lower, "top": 1.0},
		{"centerY": 5000.5, "height": 9999.0, "bottom": 1.0, "top": 10000.0}]}
	_verify_parts("overflow:early_fit_witness", lower, 10000.0, witness)
	var subnormal := _case("positive_subnormal_bounded", _from_bits(1), 4.0, false)
	_check("subnormal:bounded_exhaustion", subnormal.get("reason") == "no_exact_threshold_courses"
		and subnormal.get("candidateCount") == 63 and subnormal.get("splitTrials") == 63)


func _case(label: String, lower: float, upper: float, expected_ready: bool) -> Dictionary:
	var frozen := var_to_bytes([lower, upper])
	var result: Dictionary = splitter.prepare(lower, upper)
	var repeated: Dictionary = splitter.prepare(lower, upper)
	_check(label + ":unchanged_input", frozen == var_to_bytes([lower, upper]))
	_check(label + ":ready", result.get("ready") == expected_ready)
	_check(label + ":deterministic_repeat", var_to_bytes(result) == var_to_bytes(repeated))
	_check(label + ":bounded_typed_result", result.get("ready") is bool and result.get("courses") is Array
		and result.get("splitTrials") is int and result.get("candidateCount") is int
		and int(result.get("splitTrials", -1)) >= 0 and int(result.get("splitTrials", 65)) <= 64
		and int(result.get("candidateCount", -1)) >= 0 and int(result.get("candidateCount", 1261)) <= 1260
		and var_to_bytes(result).size() <= 4096)
	var decoded: Variant = bytes_to_var(var_to_bytes(result))
	_check(label + ":result_roundtrip", decoded is Dictionary and var_to_bytes(decoded) == var_to_bytes(result))
	# Every ready result, including repeat and deserialized result, is constructed
	# as actual BuildingPart records; a claimed failure never skips a ready result.
	for index in range(3):
		var proposal: Dictionary = [result, repeated, decoded][index]
		var stage := label + ":proposal_%d" % index
		if proposal.get("ready") == true:
			_verify_parts(stage, lower, upper, proposal)
		else:
			_check(stage + ":closed_failure", proposal.get("courses") == []
				and proposal.get("reason") is String and not String(proposal.get("reason", "")).is_empty())
	cases.append({"id": label, "lower": _json_number(lower), "upper": _json_number(upper), "result": result})
	return result


func _verify_parts(label: String, lower: float, upper: float, result: Dictionary) -> void:
	var courses: Variant = result.get("courses")
	var shape_valid: bool = courses is Array and courses.size() >= 1 and courses.size() <= 2
	_check(label + ":one_or_two_courses", shape_valid)
	if not shape_valid: return
	var previous_top := lower
	var total_height := 0.0
	var exact := true
	var size_preserved := true
	var contact := true
	var roundtrip := true
	var parts: Array = []
	for index in range(courses.size()):
		var course: Variant = courses[index]
		var fields_valid: bool = course is Dictionary
		if fields_valid:
			for key: String in ["centerY", "height", "bottom", "top"]:
				fields_valid = fields_valid and course.get(key) is float and is_finite(float(course.get(key, NAN)))
		_check(label + ":course_%d_fields" % index, fields_valid)
		if not fields_valid: return
		var part = part_script.new({"id": label + ":part_%d" % index, "kind": "foundation",
			"position": Vector3(0, course.centerY, 0), "size": Vector3(1, course.height, 1),
			"collision": true, "physicalIntent": "structural_mass"})
		# Compute faces from the ACTUAL clamped record, independently of solver.
		var bottom: float = float(part.position.y) - float(part.size.y) / 2.0
		var top: float = float(part.position.y) + float(part.size.y) / 2.0
		exact = exact and bottom == course.bottom and top == course.top and bottom >= lower and top <= upper and top > bottom
		size_preserved = size_preserved and float(part.size.y) == course.height and course.height >= 0.02
		size_preserved = size_preserved and float(part.position.y) == course.centerY and part.size.x == 1.0 and part.size.z == 1.0
		contact = contact and bottom == previous_top and part.rotation == Vector3.ZERO and part.collision_enabled
		if not parts.is_empty():
			var prior = parts.back()
			# Positive XZ face area plus zero Y gap: not mere edge contact.
			var overlap_x: float = minf(float(prior.position.x) + float(prior.size.x) / 2.0, float(part.position.x) + float(part.size.x) / 2.0) - maxf(float(prior.position.x) - float(prior.size.x) / 2.0, float(part.position.x) - float(part.size.x) / 2.0)
			var overlap_z: float = minf(float(prior.position.z) + float(prior.size.z) / 2.0, float(part.position.z) + float(part.size.z) / 2.0) - maxf(float(prior.position.z) - float(prior.size.z) / 2.0, float(part.position.z) - float(part.size.z) / 2.0)
			contact = contact and overlap_x * overlap_z == 1.0
		var snapshot: Dictionary = part.snapshot()
		var restored = part_script.new(bytes_to_var(var_to_bytes(snapshot)))
		roundtrip = roundtrip and var_to_bytes(restored.snapshot()) == var_to_bytes(snapshot)
		roundtrip = roundtrip and float(restored.position.y) - float(restored.size.y) / 2.0 == bottom
		roundtrip = roundtrip and float(restored.position.y) + float(restored.size.y) / 2.0 == top
		parts.append(part)
		previous_top = top
		total_height += float(part.size.y)
	_check(label + ":exact_stored_faces", exact)
	_check(label + ":no_clamp_or_storage_change", size_preserved)
	_check(label + ":exact_contact_disjoint_complete_union", contact and previous_top == upper and total_height == upper - lower)
	_check(label + ":part_snapshot_roundtrip", roundtrip)


func _clamp_control() -> void:
	var part = part_script.new({"id": "clamp_control", "position": Vector3(0, 1.0078125, 0), "size": Vector3(1, 0.015625, 1)})
	_check("clamp_control:actual_constructor_changes_faces", float(part.size.y) != 0.015625
		and float(part.position.y) - float(part.size.y) / 2.0 != 1.0
		and float(part.position.y) + float(part.size.y) / 2.0 != 1.015625)


func _from_bits(bits: int) -> float:
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_u32(0, bits)
	return bytes.decode_float(0)


func _json_number(value: float) -> Variant:
	return value if is_finite(value) else str(value)


func _check(id: String, passed: bool) -> void:
	checks.append({"id": id, "passed": passed})
	if not passed: push_error("Synthetic threshold course contract failed: " + id)


func _fresh_path(path: String) -> bool:
	return path.is_absolute_path() and not path.contains("://") and path.get_extension().to_lower() == "json" \
		and DirAccess.dir_exists_absolute(path.get_base_dir()) \
		and not FileAccess.file_exists(path) and not DirAccess.dir_exists_absolute(path)


func _unique_ids(rows: Array) -> bool:
	var seen: Dictionary = {}
	for row: Dictionary in rows:
		if not row.get("id") is String or String(row.id).is_empty() or seen.has(row.id): return false
		seen[row.id] = true
	return true


func _finish(path: String) -> void:
	_check("report:unique_case_ids", _unique_ids(cases))
	_check("report:unique_check_ids", _unique_ids(checks) and not checks.any(func(row): return row.id == "report:unique_check_ids"))
	var passed := not checks.is_empty() and checks.all(func(row): return row.passed == true)
	var report := {"fixture": "ThresholdBearingCourseSplitterContract", "passed": passed,
		"evidenceLevel": "synthetic_math_and_actual_building_part_contract_only", "checks": checks, "cases": cases,
		"doesNotProve": "No production sampler/house recipe integration, validator, publication, rendered visuals, live physics, gameplay, NPC/navigation or performance acceptance."}
	var bytes := JSON.stringify(report, "\t", true, true).to_utf8_buffer()
	if bytes.size() > MAX_REPORT_BYTES or not _fresh_path(path):
		push_error("Threshold course report exceeds bound or path is no longer fresh")
		quit(2)
		return
	var output := FileAccess.open(path, FileAccess.WRITE)
	if output == null:
		quit(2)
		return
	output.store_buffer(bytes)
	output.flush()
	var written := output.get_error() == OK and output.get_position() == bytes.size()
	output.close()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not written or FileAccess.get_file_as_bytes(path) != bytes or not parsed is Dictionary:
		quit(2)
		return
	if parsed.get("fixture") != report.fixture or parsed.get("passed") != passed \
		or not parsed.get("checks") is Array or not parsed.get("cases") is Array \
		or parsed.checks.size() != checks.size() or parsed.cases.size() != cases.size() \
		or not _unique_ids(parsed.checks) or not _unique_ids(parsed.cases):
		quit(2)
		return
	print("Synthetic threshold course contract: ", passed, " checks=", checks.size(), " report=", path)
	quit(0 if passed else 1)
