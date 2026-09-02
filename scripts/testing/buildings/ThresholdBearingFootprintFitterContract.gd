extends SceneTree

## SYNTHETIC GEOMETRY CONTRACT ONLY. No world, physics, publication, gameplay,
## navigation or prepare() integration acceptance. Main/critic review before runs.
## VOXEL_THRESHOLD_FOOTPRINT_REPORT: fresh absolute .json, existing parent only.
const FITTER_PATH := "res://scripts/buildings/ThresholdBearingFootprintFitter.gd"
const MAX_REPORT_BYTES := 262144
var fitter: Script
var checks: Array = []
var evidence: Array = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path := OS.get_environment("VOXEL_THRESHOLD_FOOTPRINT_REPORT").strip_edges()
	if not _fresh_path(path):
		push_error("VOXEL_THRESHOLD_FOOTPRINT_REPORT requires a fresh absolute JSON path")
		quit(2)
		return
	# Dynamic load makes a dependency compile failure an explicit nonzero exit.
	fitter = load(FITTER_PATH) as Script
	if fitter == null or not fitter.can_instantiate():
		push_error("Threshold footprint fitter failed compile guard")
		quit(2)
		return
	_check("public_candidate_limit_64", fitter.get_script_constant_map().get("MAX_CANDIDATES") == 64)
	_geometry_cases()
	_scalar_cases()
	_count_boundary()
	_contact_cases()
	_finish(path)


func _geometry_cases() -> void:
	var out_of_range := _derive("unsupported_obstacle_bounds", [99998.0, 0.0, -1.0, 100000.0, 0.5, 1.0],
		[AABB(Vector3(99999.0, -1.0, -1.0), Vector3(4.0, 2.0, 2.0))], false)
	_check("unsupported_obstacle_bounds:not_empty_space", out_of_range.get("reason") == "unsupported_threshold_fit_obstacle_bounds")
	var malformed := _derive("malformed_obstacle", [0.0, 0.0, 0.0, 2.0, 0.5, 2.0], [AABB(Vector3.ZERO, Vector3(1, -1, 1))], false)
	_check("malformed_obstacle:rejected", malformed.get("reason") == "invalid_threshold_fit_obstacle")
	var domain := [-4.0, 0.0, -3.0, 4.0, 0.5, 3.0]
	var clear := _derive("empty_obstacles", domain, [])
	_check("empty_obstacles:whole_domain", clear.get("candidates") == [domain])
	var obstacles := [AABB(Vector3(-2, -1, -2), Vector3(2, 2, 3)),
		AABB(Vector3(-1, 0.25, 0), Vector3(3, 1, 2)),
		AABB(Vector3(3, -1, -4), Vector3(2, 2, 2))]
	var mixed := _derive("overlapping_clipped_cuts", domain, obstacles)
	_check("overlapping_clipped_cuts:three_unique", mixed.get("cutCount") == 3)
	var reordered := [obstacles[2], obstacles[0], obstacles[1], obstacles[0], obstacles[2]]
	var repeat := _derive("reordered_duplicates", domain, reordered)
	_check("sortedcuts:byte_identical_results", var_to_bytes(mixed) == var_to_bytes(repeat))
	_check("repeat:byte_identical_results", var_to_bytes(mixed) == var_to_bytes(_derive("repeat", domain, obstacles)))
	var reflected: Array = []
	for obstacle: AABB in obstacles:
		reflected.append(AABB(Vector3(-obstacle.end.x, obstacle.position.y, obstacle.position.z), obstacle.size))
	# The partition need not mirror piece-for-piece; its free-space union must.
	_derive("mixed_horizontal_mirror", domain, reflected)
	var touches := [AABB(Vector3(-4, 0.5, -3), Vector3(8, 1, 6)),
		AABB(Vector3(-4, -1, -3), Vector3(8, 1, 6)),
		AABB(Vector3(4, 0, -3), Vector3(1, 1, 6)),
		AABB(Vector3(-4, 0, 3), Vector3(8, 1, 1))]
	var ignored := _derive("boundary_touch_only", domain, touches)
	_check("boundary_touch_only:no_cuts", ignored.get("cutCount") == 0 and ignored.get("candidates") == [domain])
	var filled := _derive("no_fit", domain, [AABB(Vector3(-5, -1, -4), Vector3(10, 2, 8))])
	_check("no_fit:explicit_empty_success", filled.get("ready") == true and filled.get("candidateCount") == 0
		and filled.get("candidates") == [] and filled.get("reason") == "no_clear_threshold_footprint")
	var ranked_domain := [0.0, 0.0, 0.0, 8.0, 0.5, 4.0]
	var ranked := _derive("area_order", ranked_domain, [AABB(Vector3(2, -1, 0), Vector3(1, 2, 4))])
	# Hand-computed surviving strips: 5*4 first, then 2*4; not fitter helpers.
	var expected := [[3.0, 0.0, 0.0, 8.0, 0.5, 4.0], [0.0, 0.0, 0.0, 2.0, 0.5, 4.0]]
	_check("area_order:known_geometry", ranked.get("candidates") == expected)
	var mirrored := _derive("horizontal_mirror", [-8.0, 0.0, 0.0, 0.0, 0.5, 4.0],
		[AABB(Vector3(-3, -1, 0), Vector3(1, 2, 4))])
	_check("horizontal_mirror:known_geometry", mirrored.get("candidates") ==
		[[-8.0, 0.0, 0.0, -3.0, 0.5, 4.0], [-2.0, 0.0, 0.0, 0.0, 0.5, 4.0]])
	var equal := _derive("area_tie", [0.0, 0.0, 0.0, 5.0, 0.5, 1.0],
		[AABB(Vector3(2, -1, 0), Vector3(1, 2, 1))])
	_check("area_tie:lexical_order", equal.get("candidates") ==
		[[0.0, 0.0, 0.0, 2.0, 0.5, 1.0], [3.0, 0.0, 0.0, 5.0, 0.5, 1.0]])
	# Float32 center rounds to 1 + 4 units; native end rounds to 1 + 8.
	# Stored half-size is 5 units, so Admission occupies [1 - unit, 1 + 9 units].
	var unit := 1.0 / 33554432.0
	var rounded := AABB(Vector3(1, -1, 0), Vector3(10.0 * unit, 2, 1))
	_check("stored_transform:inward_native_bounds_control", float(rounded.position.x) > 1.0 - unit
		and float(rounded.end.x) < 1.0 + 9.0 * unit)
	var represented := _derive("stored_transform_rounding", [0.0, 0.0, 0.0, 2.0, 0.5, 1.0], [rounded])
	_check("stored_transform:known_scalar_cut", represented.get("candidates") ==
		[[0.0, 0.0, 0.0, 1.0 - unit, 0.5, 1.0], [1.0 + 9.0 * unit, 0.0, 0.0, 2.0, 0.5, 1.0]])
	var scalar_equivalent := _derive("stored_transform_scalar_equivalent", [0.0, 0.0, 0.0, 2.0, 0.5, 1.0],
		[[1.0 - unit, -1.0, 0.0, 1.0 + 9.0 * unit, 1.0, 1.0]], true, true)
	_check("stored_transform:adapter_byte_parity", var_to_bytes(represented) == var_to_bytes(scalar_equivalent))


func _scalar_cases() -> void:
	var upper := 3.875730514526367
	var domain := [0.0, 2.55, 0.0, 8.0, upper, 4.0]
	# Real positive Y intersections, including only 0.18 micrometres below U.
	# Neither buried material nor furniture may be rounded out of the domain.
	var obstacles := [[1.0, 2.55, 0.0, 2.0, 2.62, 4.0],
		[4.0, upper - 1.8e-7, 0.0, 5.0, upper + 0.5, 4.0]]
	var fitted := _derive("scalar_thin_and_near_upper", domain, obstacles, true, true)
	var expected := [[5.0, 2.55, 0.0, 8.0, upper, 4.0],
		[2.0, 2.55, 0.0, 4.0, upper, 4.0], [0.0, 2.55, 0.0, 1.0, upper, 4.0]]
	_check("scalar:exact_cuts_and_area", fitted.get("candidates") == expected and fitted.get("cutCount") == 2
		and _area(expected[0]) + _area(expected[1]) + _area(expected[2]) + 8.0 == _area(domain))
	var reverse := _derive("scalar_reverse", domain, [obstacles[1], obstacles[0]], true, true)
	var repeated := _derive("scalar_repeat", domain, obstacles, true, true)
	_check("scalar:deterministic_order", var_to_bytes(fitted) == var_to_bytes(reverse) and var_to_bytes(fitted) == var_to_bytes(repeated))
	var touch := _derive("scalar_exact_upper_touch", domain, [[0.0, upper, 0.0, 8.0, upper + 1.0, 4.0]], true, true)
	_check("scalar:exact_touch_is_not_penetration", touch.get("candidates") == [domain] and touch.get("cutCount") == 0)
	var invalid: Array = [null, "box", AABB(Vector3.ZERO, Vector3.ONE), [], [0, 0, 0, 1, 1],
		[0, 0, 0, 1, 1, "1"], [0, 0, 0, 1, 1, true], [0, 0, 0, 1, NAN, 1],
		[0, 0, 0, 1, INF, 1], [0, 0, 0, 0, 1, 1], [0, 2, 0, 1, 1, 1], [0, 0, 0, 100001, 1, 1]]
	for index in range(invalid.size()):
		# Full cover first must not hide a later malformed obstacle.
		var refused := _derive("scalar_invalid_%d" % index, domain, [domain, invalid[index]], false, true)
		_check("scalar_invalid_%d:fail_closed" % index, refused.get("reason") == "invalid_threshold_fit_obstacle"
			and not refused.has("candidates"))
	_derive("scalar_invalid_domain", [0, 0, 0, 1, 1, NAN], [], false, true)
	_check("scalar:bounds_limit_4096", fitter.get_script_constant_map().get("MAX_BOUNDS") == 4096)
	var capped: Array = []
	capped.resize(4096)
	capped.fill(obstacles[0])
	var at_cap: Dictionary = fitter.derive_scalar(domain, capped)
	_check("scalar:all_4096_bounds_accepted", at_cap.get("ready") == true and at_cap.get("cutCount") == 1)
	capped.append(obstacles[1])
	var overflow: Dictionary = fitter.derive_scalar(domain, capped)
	_check("scalar:bounds_overflow_not_truncated", overflow.get("ready") == false and not overflow.has("candidates"))


func _count_boundary() -> void:
	# 63 disjoint full-depth bars leave exactly 64 unit-width strips.
	var bars: Array = []
	for index in range(63):
		bars.append(AABB(Vector3(2 * index + 1, -1, 0), Vector3(1, 2, 1)))
	var at_limit := _derive("exactly_64", [0.0, 0.0, 0.0, 127.0, 0.5, 1.0], bars)
	_check("exactly_64:accepted", at_limit.get("ready") == true and at_limit.get("candidateCount") == 64)
	var scalar_bars: Array = []
	for index in range(63): scalar_bars.append([float(2 * index + 1), -1.0, 0.0, float(2 * index + 2), 1.0, 1.0])
	_check("scalar:64_candidate_adapter_parity", var_to_bytes(at_limit) == var_to_bytes(fitter.derive_scalar([0.0, 0.0, 0.0, 127.0, 0.5, 1.0], scalar_bars)))
	bars.append(AABB(Vector3(127, -1, 0), Vector3(1, 2, 1)))
	var overflow := _derive("overflow_65", [0.0, 0.0, 0.0, 129.0, 0.5, 1.0], bars, false)
	_check("overflow_65:fail_closed", overflow.get("ready") == false
		and overflow.get("reason") == "threshold_fit_candidate_limit" and overflow.get("candidates", []) == [])
	scalar_bars.append([127.0, -1.0, 0.0, 128.0, 1.0, 1.0])
	_check("scalar:65_candidate_failure_parity", var_to_bytes(overflow) == var_to_bytes(fitter.derive_scalar([0.0, 0.0, 0.0, 129.0, 0.5, 1.0], scalar_bars)))
	bars.reverse()
	var reverse := _derive("overflow_reversed", [0.0, 0.0, 0.0, 129.0, 0.5, 1.0], bars, false)
	_check("overflow:deterministic_failure", var_to_bytes(overflow) == var_to_bytes(reverse))


func _derive(label: String, domain: Array, obstacles: Array, expect_ready: bool = true, scalar: bool = false) -> Dictionary:
	var frozen := var_to_bytes([domain, obstacles])
	var result: Dictionary = fitter.derive_scalar(domain, obstacles) if scalar else fitter.derive(domain, obstacles)
	_check(label + ":inputs_immutable", frozen == var_to_bytes([domain, obstacles]))
	_check(label + ":ready", result.get("ready") == expect_ready)
	var cells: Variant = result.get("candidates")
	if expect_ready:
		_check(label + ":array_result", cells is Array)
		if cells is Array:
			_check(label + ":count_bound", cells.size() <= 64 and result.get("candidateCount") == cells.size())
			if cells.size() <= 64: _geometry(label, domain, obstacles, cells, scalar)
	evidence.append({"case": label, "ready": result.get("ready"), "candidateCount": result.get("candidateCount"),
		"cutCount": result.get("cutCount"), "reason": result.get("reason", "")})
	return result


func _geometry(label: String, domain: Array, obstacles: Array, cells: Array, scalar: bool = false) -> void:
	var valid := true
	for cell: Variant in cells:
		if not cell is Array or cell.size() != 6:
			valid = false
			break
		for value: Variant in cell:
			if not (value is float or value is int) or not is_finite(float(value)): valid = false
		if not valid: break
		valid = cell[1] == domain[1] and cell[4] == domain[4] and cell[0] >= domain[0] \
			and cell[3] <= domain[3] and cell[2] >= domain[2] and cell[5] <= domain[5] \
			and cell[0] < cell[3] and cell[2] < cell[5]
		if not valid: break
	_check(label + ":finite_contained_full_height", valid)
	if not valid: return
	# Same stored transform as Admission, evaluated independently per scalar axis.
	# Never use fitter/occupancy helpers or Vector3 endpoint reconstruction.
	var intervals: Array = []
	for obstacle: Variant in obstacles:
		if scalar:
			intervals.append([[obstacle[0], obstacle[3]], [obstacle[1], obstacle[4]], [obstacle[2], obstacle[5]]])
			continue
		var center: Vector3 = obstacle.get_center()
		var axes: Array = []
		for axis in range(3):
			var half_size: float = float(obstacle.size[axis]) / 2.0
			axes.append([float(center[axis]) - half_size, float(center[axis]) + half_size])
		intervals.append(axes)
	var ranked := true
	var separated := true
	for index in range(cells.size()):
		var cell: Array = cells[index]
		if index > 0:
			var previous: Array = cells[index - 1]
			ranked = ranked and (_area(previous) > _area(cell) or (_area(previous) == _area(cell) and _lexical(previous, cell)))
		for axes: Array in intervals:
			separated = separated and (axes[1][0] >= domain[4] or axes[1][1] <= domain[1]
				or _overlap(cell[0], cell[3], axes[0][0], axes[0][1]) == 0.0
				or _overlap(cell[2], cell[5], axes[2][0], axes[2][1]) == 0.0)
	_check(label + ":descending_area_lexical_ties", ranked)
	_check(label + ":no_positive_obstacle_overlap", separated)
	# Independent oracle: elementary scalar intervals, not rectangle subtraction.
	# Including candidate edges catches omissions, duplication and arbitrary cuts.
	var xs: Array = [domain[0], domain[3]]
	var zs: Array = [domain[2], domain[5]]
	for axes: Array in intervals:
		for x: float in axes[0]: xs.append(clampf(x, domain[0], domain[3]))
		for z: float in axes[2]: zs.append(clampf(z, domain[2], domain[5]))
	for cell: Array in cells:
		xs.append_array([cell[0], cell[3]])
		zs.append_array([cell[2], cell[5]])
	xs.sort()
	zs.sort()
	var covered := true
	var expected_area := 0.0
	for xi in range(xs.size() - 1):
		if xs[xi] == xs[xi + 1]: continue
		for zi in range(zs.size() - 1):
			if zs[zi] == zs[zi + 1]: continue
			var x: float = (xs[xi] + xs[xi + 1]) * 0.5
			var z: float = (zs[zi] + zs[zi + 1]) * 0.5
			var blocked := false
			for axes: Array in intervals:
				blocked = blocked or (axes[1][0] < domain[4] and axes[1][1] > domain[1]
					and x > axes[0][0] and x < axes[0][1] and z > axes[2][0] and z < axes[2][1])
			var owners := 0
			for cell: Array in cells:
				if x > cell[0] and x < cell[3] and z > cell[2] and z < cell[5]: owners += 1
			covered = covered and owners == (0 if blocked else 1)
			if not blocked: expected_area += (xs[xi + 1] - xs[xi]) * (zs[zi + 1] - zs[zi])
	var actual_area := 0.0
	for cell: Array in cells: actual_area += _area(cell)
	_check(label + ":complete_disjoint_coverage", covered and actual_area == expected_area)


func _contact_cases() -> void:
	# Dyadic represented coordinates: top plane is exactly .5, not approximate.
	var bearing := {"position": Vector3(0, 0.25, 0), "size": Vector3(2, 0.5, 2), "rotation": Vector3.ZERO}
	var threshold := {"position": Vector3(0, 0.625, 0), "size": Vector3(2, 0.25, 2), "rotation": Vector3.ZERO}
	# label, threshold center, ground, area, signed vertical gap, signed ground gap, contact, grounded.
	var tiny := 1.0 / 4194304.0
	var cases := [
		["exact_half_plane", Vector3(0, 0.625, 0), 0.0, 4.0, 0.0, 0.0, true, true],
		["edge_zero_area", Vector3(2, 0.625, 0), 0.0, 0.0, 0.0, 0.0, false, true],
		["disjoint_zero_area", Vector3(2.25, 0.625, 0), 0.0, 0.0, 0.0, 0.0, false, true],
		["partial_area", Vector3(1, 0.625, 0), 0.0, 2.0, 0.0, 0.0, true, true],
		["depth_zero_area", Vector3(0, 0.625, 2), 0.0, 0.0, 0.0, 0.0, false, true],
		["partial_both_axes", Vector3(1, 0.625, 1), 0.0, 1.0, 0.0, 0.0, true, true],
		["positive_gap", Vector3(0, 0.75, 0), 0.0, 4.0, 0.125, 0.0, false, true],
		["tiny_positive_gap", Vector3(0, 0.625 + tiny, 0), 0.0, 4.0, tiny, 0.0, false, true],
		["vertical_overlap", Vector3(0, 0.5, 0), 0.0, 4.0, -0.125, 0.0, false, true],
		["bottom_below_ground", Vector3(0, 0.625, 0), 0.25, 4.0, 0.0, -0.25, true, true],
		["bottom_above_ground", Vector3(0, 0.625, 0), -0.25, 4.0, 0.0, 0.25, true, false],
		["tiny_ground_gap", Vector3(0, 0.625, 0), -tiny, 4.0, 0.0, tiny, true, false],
		["whole_bearing_below_ground", Vector3(0, 0.625, 0), 0.75, 4.0, 0.0, -0.75, true, false],
		["top_at_ground", Vector3(0, 0.625, 0), 0.5, 4.0, 0.0, -0.5, true, false]]
	for row: Array in cases:
		threshold.position = row[1]
		var frozen := var_to_bytes([bearing, threshold])
		var result: Dictionary = fitter.measure_contact(bearing, threshold, row[2])
		_check(row[0] + ":immutable_contact_inputs", frozen == var_to_bytes([bearing, threshold]))
		_check(row[0] + ":exact_measurements", result.get("ready") == true and result.get("contactArea") == row[3]
			and result.get("verticalGap") == row[4] and result.get("groundGap") == row[5]
			and result.get("exactTopContact") == row[6] and result.get("meetsGroundPlane") == row[7])
		evidence.append({"case": row[0], "measurement": result})


func _overlap(a: float, b: float, c: float, d: float) -> float:
	return maxf(0.0, minf(b, d) - maxf(a, c))


func _area(cell: Array) -> float:
	return (cell[3] - cell[0]) * (cell[5] - cell[2])


func _lexical(a: Array, b: Array) -> bool:
	for index in range(6):
		if a[index] != b[index]: return a[index] < b[index]
	return false


func _check(id: String, passed: bool) -> void:
	checks.append({"id": id, "passed": passed})
	if not passed: push_error("Synthetic threshold footprint contract failed: " + id)


func _fresh_path(path: String) -> bool:
	return path.is_absolute_path() and not path.contains("://") and path.get_extension().to_lower() == "json" \
		and DirAccess.dir_exists_absolute(path.get_base_dir()) \
		and not FileAccess.file_exists(path) and not DirAccess.dir_exists_absolute(path)


func _finish(path: String) -> void:
	var passed := not checks.is_empty() and checks.all(func(row): return row.passed == true)
	var report := {"fixture": "ThresholdBearingFootprintFitterContract", "passed": passed,
		"evidenceLevel": "synthetic_geometry_contract_only", "checks": checks, "cases": evidence,
		"doesNotProve": "No live world, physics, rendered geometry, NPC/navigation, gameplay, performance or prepare integration acceptance."}
	var bytes := JSON.stringify(report, "\t").to_utf8_buffer()
	if bytes.size() > MAX_REPORT_BYTES or not _fresh_path(path):
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
	if not written or FileAccess.get_file_as_bytes(path) != bytes:
		quit(2)
		return
	print("Synthetic threshold footprint contract: ", passed, " checks=", checks.size(), " report=", path)
	quit(0 if passed else 1)
