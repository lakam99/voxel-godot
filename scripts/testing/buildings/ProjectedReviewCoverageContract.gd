extends SceneTree
## Synthetic camera-review policy checks. No renderer, scene rays or gameplay.
const Coverage = preload("res://scripts/testing/buildings/ProjectedReviewCoverage.gd")
var _checks: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _check(label: String, passed: bool) -> void:
	_checks[label] = passed

func _run() -> void:
	var rect := Rect2(10.0, 20.0, 100.0, 200.0)
	var full: Array = [true, true, true, true, true, true, true, true, true]
	var empty: Array = [false, false, false, false, false, false, false, false, false]
	var six: Array = [true, true, true, true, false, false, true, false, true]
	var before: PackedByteArray = var_to_bytes([rect, full, empty, six])
	var points: Array[Vector2] = Coverage.sample_positions(rect)
	var expected: Array[Vector2] = [
		Vector2(25, 50), Vector2(60, 50), Vector2(95, 50),
		Vector2(25, 120), Vector2(60, 120), Vector2(95, 120),
		Vector2(25, 190), Vector2(60, 190), Vector2(95, 190)]
	_check("nine_row_major_positions", points == expected)
	var readable: Dictionary = Coverage.evaluate(rect, full)
	_check("readable_all_nine", readable.passed and readable.visibleCount == 9 and readable.sampleCount == 9)
	_check("reported_projected_spread", readable.spreadX == 0.7 and readable.spreadY == 0.7)
	_check("six_distributed_readable", Coverage.evaluate(rect, six).passed)
	_check("one_visible_hit_reject", not Coverage.evaluate(rect, [false, false, false, false, true, false, false, false, false]).passed)
	_check("vertical_slit_reject", not Coverage.evaluate(rect, [false, true, false, false, true, false, false, true, false]).passed)
	_check("visible_corner_reject", not Coverage.evaluate(rect, [true, true, false, true, true, false, false, false, false]).passed)
	var top_two_rows: Dictionary = Coverage.evaluate(rect, [true, true, true, true, true, true, false, false, false])
	var left_two_columns: Dictionary = Coverage.evaluate(rect, [true, true, false, true, true, false, true, true, false])
	_check("six_hits_insufficient_vertical_spread", not top_two_rows.passed and top_two_rows.visibleCount == 6 and top_two_rows.reason == "insufficient_visible_spread")
	_check("six_hits_insufficient_horizontal_spread", not left_two_columns.passed and left_two_columns.visibleCount == 6 and left_two_columns.reason == "insufficient_visible_spread")
	_check("separated_corners_still_need_six", not Coverage.evaluate(rect, [true, false, true, false, false, false, true, false, true]).passed)
	var hidden: Dictionary = Coverage.evaluate(rect, empty)
	_check("hidden_participant_independently_rejects", readable.passed and not hidden.passed and hidden.visibleCount == 0)
	_check("all_hidden_finite_zero_spread", hidden.spreadX == 0.0 and hidden.spreadY == 0.0)
	_check("participant_flags_cannot_pool", not Coverage.evaluate(rect, full + empty).passed)
	_check("four_pixel_boundary_passes", Coverage.evaluate(Rect2(0, 0, 4, 4), full).passed)
	_check("small_width_rejects", Coverage.evaluate(Rect2(0, 0, 3.99, 20), full).reason == "projected_rect_too_small")
	_check("small_height_rejects", Coverage.evaluate(Rect2(0, 0, 20, 3.99), full).reason == "projected_rect_too_small")
	_check("translated_rect_passes", Coverage.evaluate(Rect2(-100, -300, 100, 200), six).passed)
	var bad_rects: Array = [null, {}, Vector2.ZERO, Rect2(0, 0, 0, 20),
		Rect2(0, 0, -20, 20), Rect2(Vector2(NAN, 0), Vector2(20, 20)),
		Rect2(Vector2.ZERO, Vector2(INF, 20)), Rect2(Vector2(3.0e38, 0), Vector2(3.0e38, 20)),
		Rect2(Vector2(1.0e20, 0), Vector2(4, 4))]
	for index in range(bad_rects.size()):
		_check("invalid_rect_%02d" % index, not Coverage.evaluate(bad_rects[index], full).passed and Coverage.sample_positions(bad_rects[index]).is_empty())
	for count in [0, 1, 8, 10]:
		var incomplete: Array = []
		incomplete.resize(count)
		incomplete.fill(true)
		_check("budget_incomplete_or_wrong_count_%02d" % count, Coverage.evaluate(rect, incomplete).reason == "incomplete_or_invalid_sample_count")
	for index in range(9):
		var malformed: Array = full.duplicate()
		malformed[index] = 1
		_check("nonbool_at_%02d" % index, Coverage.evaluate(rect, malformed).reason == "non_boolean_sample")
	for invalid in [null, {}, PackedByteArray([1, 1, 1, 1, 1, 1, 1, 1, 1])]:
		_check("nonarray_flags_%02d" % typeof(invalid), Coverage.evaluate(rect, invalid).reason == "flags_not_array")
	_check("deterministic_result", var_to_bytes(readable) == var_to_bytes(Coverage.evaluate(rect, full)))
	_check("source_arguments_unchanged", before == var_to_bytes([rect, full, empty, six]))
	points[0] = Vector2.ZERO
	_check("returned_samples_not_shared", Coverage.sample_positions(rect) == expected)
	var passed: bool = not _checks.values().has(false)
	var report: Dictionary = {"schemaVersion": 1, "passed": passed,
		"evidence": "synthetic_camera_review_heuristic_not_gameplay_or_geometry_acceptance",
		"checkCount": _checks.size(), "checks": _checks,
		"helperSha256": FileAccess.get_sha256("res://scripts/testing/buildings/ProjectedReviewCoverage.gd")}
	var path: String = OS.get_environment("VOXEL_PROJECTED_REVIEW_COVERAGE_REPORT")
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
