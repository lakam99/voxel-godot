extends SceneTree

const Door = preload("res://scripts/buildings/BuildingDoorGeometry.gd")
var checks: Dictionary = {}
var results: Array = []

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var path := OS.get_environment("VOXEL_ORDINARY_DOOR_SWEEP_REPORT").simplify_path()
	if not path.is_absolute_path() or path.get_extension() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()): quit(2); return
	var cases := [
		{"size": Vector3(1.0, 2.5, 0.12), "world": Transform3D.IDENTITY, "angle": Door.DEFAULT_OPEN_SWING},
		{"size": Vector3(1.45, 3.1, 0.18), "world": Transform3D(Basis.from_euler(Vector3(0, 0.71, 0)), Vector3(-8, 2, 11)), "angle": Door.DEFAULT_OPEN_SWING},
		{"size": Vector3(0.62, 1.7, 0.08), "world": Transform3D(Basis.from_euler(Vector3(0, -1.1, 0)), Vector3(4, -0.5, -3)), "angle": 0.0},
		{"size": Vector3(1.2, 2.2, 0.15), "world": Transform3D(Basis.from_euler(Vector3(0, 0.33, 0)), Vector3(3, 1, 9)), "angle": -PI / 3.0}]
	for index in range(cases.size()): _case(index, cases[index])
	checks["default_is_exact_publisher_negative_quarter_turn"] = Door.DEFAULT_OPEN_SWING == -PI * 0.5
	checks["invalid_size_rejects"] = Door.ordinary_sweep_bounds(Vector3.ZERO, Transform3D.IDENTITY).is_empty()
	checks["invalid_angle_rejects"] = Door.ordinary_sweep_bounds(Vector3.ONE, Transform3D.IDENTITY, INF).is_empty()
	var first: Dictionary = cases[0]
	var exact: Array = Door.ordinary_sweep_bounds(first.size, first.world, first.angle)
	checks["repeat_byte_exact"] = var_to_bytes(exact) == var_to_bytes(Door.ordinary_sweep_bounds(first.size, first.world, first.angle))
	checks["quarter_sweep_strictly_smaller_than_legacy_full_circle"] = _union(exact).get_volume() < _legacy(first.size, first.world).get_volume()
	var passed := not checks.is_empty() and checks.values().all(func(value): return value == true)
	var report := {"passed": passed, "checks": checks, "results": results,
		"limitations": "Pure source geometry and sampled exact corner trajectories. No live DoorController, physics, player traversal, published visual, furniture, NPC/navigation or headed acceptance."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(JSON.stringify(_json(report), "\t")); file.flush(); var ok := file.get_error() == OK; file.close()
	quit(0 if passed and ok else 1)

func _case(index: int, data: Dictionary) -> void:
	var sweep: Array = Door.ordinary_sweep_bounds(data.size, data.world, data.angle)
	var names: Array = sweep.map(func(row): return row.name)
	checks["case_%d_exact_schema" % index] = sweep.size() == 10 and names == ["DoorBoard_0", "DoorBoard_1", "DoorBoard_2", "DoorBoard_3", "DoorBoard_4", "brace", "handle", "frameLeft", "frameRight", "frameTop"] and sweep.all(func(row): return row.bounds is AABB and row.bounds.size.x > 0 and row.bounds.size.y > 0 and row.bounds.size.z > 0)
	checks["case_%d_exact_moving_flags" % index] = sweep.slice(0, 7).all(func(row): return row.moving == true) and sweep.slice(7).all(func(row): return row.moving == false)
	var description := Door.describe(data.size)
	var samples := 0
	var contained := true
	var unmatched := 0
	var first_outside: Dictionary = {}
	for row: Dictionary in sweep:
		var piece: Dictionary
		if String(row.name).begins_with("DoorBoard_"): piece = description.boards[int(String(row.name).trim_prefix("DoorBoard_"))]
		else: piece = description[row.name]
		if row.moving:
			for step in range(65):
				var angle: float = data.angle * float(step) / 64.0
				var pose: Transform3D = data.world * Transform3D(Basis.IDENTITY, description.pivotPosition) * Transform3D(Basis(Vector3.UP, angle), Vector3.ZERO) * Transform3D(Basis.IDENTITY, description.leafPosition + piece.position)
				for corner in range(8):
					var point: Vector3 = pose * AABB(-piece.size * 0.5, piece.size).get_endpoint(corner)
					if not _contains(row.bounds, point) and first_outside.is_empty(): first_outside = {"name": row.name, "angle": angle, "point": point, "bounds": row.bounds}
					contained = contained and _contains(row.bounds, point)
					samples += 1
		else:
			var pose: Transform3D = data.world * Transform3D(Basis.IDENTITY, piece.position) * Transform3D(Basis.from_scale(piece.size), Vector3.ZERO)
			var expected: AABB = Door._translated_box_envelope(pose, Vector3.ZERO)
			if row.bounds != expected: unmatched += 1
	checks["case_%d_all_actual_corners_contained" % index] = contained and samples == 7 * 65 * 8
	checks["case_%d_stationary_exact_not_swept" % index] = unmatched == 0
	results.append({"index": index, "sampledCorners": samples, "stationaryMismatches": unmatched, "firstOutside": first_outside, "union": _union(sweep)})

func _contains(bounds: AABB, point: Vector3) -> bool:
	return point.x >= bounds.position.x and point.y >= bounds.position.y and point.z >= bounds.position.z and point.x <= bounds.end.x and point.y <= bounds.end.y and point.z <= bounds.end.z

func _union(rows: Array) -> AABB:
	var result: AABB = rows[0].bounds
	for row: Dictionary in rows.slice(1): result = result.merge(row.bounds)
	return result

func _legacy(size: Vector3, world: Transform3D) -> AABB:
	var geometry := Door.describe(size); var radius := 0.0; var low_y := INF; var high_y := -INF
	for primitive: Dictionary in Door.closed_primitives(size, Transform3D.IDENTITY):
		low_y = minf(low_y, primitive.bounds.position.y); high_y = maxf(high_y, primitive.bounds.end.y)
		for x: float in [primitive.bounds.position.x, primitive.bounds.end.x]:
			for z: float in [primitive.bounds.position.z, primitive.bounds.end.z]: radius = maxf(radius, Vector2(x - geometry.pivotPosition.x, z).length())
	var extent := Vector3(radius, maxf(absf(low_y), absf(high_y)), radius)
	return world * Transform3D(Basis.IDENTITY, geometry.pivotPosition) * AABB(-extent, extent * 2.0)

func _json(value: Variant) -> Variant:
	if value is Vector3: return [value.x, value.y, value.z]
	if value is AABB: return {"position": _json(value.position), "size": _json(value.size)}
	if value is Dictionary:
		var result := {}
		for key: Variant in value: result[str(key)] = _json(value[key])
		return result
	if value is Array: return value.map(func(item): return _json(item))
	return value
