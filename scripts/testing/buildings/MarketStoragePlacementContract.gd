extends SceneTree

## Producer-backed source/service contract only. No scene, publisher, collision,
## canopy construction, placement planner or navigation is executed here.
## VOXEL_MARKET_STORAGE_PLACEMENT_REPORT: new absolute JSON path; parent exists.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Storage = preload("res://scripts/buildings/MarketStoragePlacementRecipe.gd")
const STORAGE_SEMANTIC := "citadel_market_storage"
const KNEE_SEMANTIC := "citadel_market_joinery"
const RIDGE_SEMANTIC := "citadel_market_canopy_ridge"
# Independent transformed-corner projection versus the recipe's analytic OBB
# extent uses float32 vectors. This is arithmetic comparison only, NOT a changed
# physical contact tolerance. Snapshot preservation/idempotence remain exact.
const PROJECTION_ARITHMETIC_EPS := 0.00001
var _checks: Array = []
var _changed_cases := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := OS.get_environment("VOXEL_MARKET_STORAGE_PLACEMENT_REPORT").strip_edges().simplify_path()
	if not path.is_absolute_path() or path.get_extension().to_lower() != "json" or FileAccess.file_exists(path):
		printerr("Set VOXEL_MARKET_STORAGE_PLACEMENT_REPORT to a new absolute JSON path")
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var matrix_count := 0
	for side in [-1.0, 1.0]:
		for depth in [-1.0, 1.0]:
			for variation in [-0.04, 0.0, 0.13, 0.4]:
				for scale_value in [0.8, 1.0, 1.25, 1.5]:
					_positive(_fixture(side, depth, variation, scale_value), "producer_%02d" % matrix_count)
					matrix_count += 1
	_record("four_side_depth_pairs_variation_scale_matrix", matrix_count == 64)
	for quarter in range(4):
		for depth in [-1.0, 1.0]:
			_positive(_fixture(-1.0, depth, 0.13, 1.25, quarter), "cardinal_pose_%d_depth_%s" % [quarter, str(depth)])
	_record("producer_cases_exercise_real_storage_changes", _changed_cases > 0, {"changedCases": _changed_cases})
	for mode in ["empty_members", "missing_member", "duplicate_member", "nonstring_member", "duplicate_source_member",
		"missing_ridge", "missing_knee", "double_ridge", "double_knee", "too_many_members",
		"front_nonfinite", "front_zero", "front_vertical", "front_not_unit",
		"front_x_positive", "front_x_negative", "front_diagonal_positive", "front_diagonal_negative",
		"ridge_pitch", "ridge_roll"]:
		_input_negative(mode)
	for semantic in [STORAGE_SEMANTIC, RIDGE_SEMANTIC, KNEE_SEMANTIC]:
		for field in ["position", "rotation", "size"]:
			for invalid in [NAN, INF]:
				var fixture := _fixture(-1.0, -1.0, 0.13, 1.25)
				var part = _semantic_members(fixture, semantic)[0]
				var value: Vector3 = part.get(field)
				value.x = invalid
				part.set(field, value)
				_reject_atomic("nonfinite:%s:%s:%s" % [semantic, field, str(invalid)], fixture, "invalid_or_duplicate_member")
	_late_overflow_control()
	var passed := not _checks.is_empty() and _checks.all(func(check): return bool(check.passed))
	var report := {"fixture": "MarketStoragePlacementContract", "evidenceLevel": "producer_backed_source_service_contract",
		"passed": passed, "checks": _checks, "checkCount": _checks.size(), "elapsedMsec": Time.get_ticks_msec() - started,
		"projectionArithmeticEpsilon": PROJECTION_ARITHMETIC_EPS,
		"doesNotProve": "Actual published crate/barrel/post mesh clearance, storage-to-storage or circulation clearance, whole-canopy physical acceptance, frozen-source integration, visuals, physics, NPC/navigation or gameplay. Producer IDs are real; scale/pose and invalid-input controls are synthetic."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("Cannot create market storage contract report")
		quit(2)
		return
	file.store_string(JSON.stringify(_json(report), "\t"))
	file.flush()
	var error := file.get_error()
	file.close()
	print("Market storage source contract: %s (%d checks)" % ["PASS" if passed else "FAIL", _checks.size()])
	quit(2 if error != OK else (0 if passed else 1))

func _fixture(side: float, depth: float, variation: float, scale_value: float, quarter := 0) -> Dictionary:
	var b = Blueprint.new("producer_storage_contract", 101, "timber")
	b.recipe = {"preservation": {"contents": ["unchanged"], "variation": variation}}
	b.rooms = [{"id": "unrelated_room", "role": "courtyard"}]
	# Same semantic but outside producer membership: it must never be moved.
	b.add_part({"id": "unrelated_storage_sentinel", "kind": "crate", "material": "timber_board",
		"position": Vector3(11, 1, -6), "size": Vector3.ONE, "collision": false,
		"semantic": STORAGE_SEMANTIC, "recipe": {"contents": ["not_owned"]}})
	var start: int = b.parts.size()
	Urban.add_market_stall_household(b, Vector3.ZERO, side, depth, variation)
	var members: Array = []
	var turn := _turn(quarter)
	var origin := Vector3(11.0, 0.75, -6.0)
	for index in range(start, b.parts.size()):
		var part = b.parts[index]
		members.append(String(part.id))
		part.position = origin + turn * (part.position * scale_value)
		part.size *= scale_value
		part.rotation = (turn * Basis.from_euler(part.rotation)).get_euler()
	for part in b.parts:
		b.physical_parts_by_id[part.id] = part
	return {"b": b, "members": members, "front": turn * Vector3(0, 0, -depth),
		"parameters": {"side": side, "depth": depth, "variation": variation, "scale": scale_value, "quarter": quarter}}

func _positive(fixture: Dictionary, label: String) -> void:
	var b = fixture.b
	var before: Dictionary = b.snapshot()
	var members_before := _bytes(fixture.members)
	var aliases: Array = b.parts.duplicate()
	var recipe_aliases: Array = b.parts.map(func(part): return part.recipe)
	var index_before: Dictionary = b.physical_parts_by_id.duplicate()
	var storage_parts := _semantic_members(fixture, STORAGE_SEMANTIC)
	var ridges := _semantic_members(fixture, RIDGE_SEMANTIC)
	var knees := _semantic_members(fixture, KNEE_SEMANTIC)
	var valid_producer := not storage_parts.is_empty() and ridges.size() == 1 and knees.size() == 4
	_record(label + ":producer_membership", valid_producer, fixture.parameters)
	if not valid_producer:
		return
	var ridge = ridges[0]
	var rear: Vector3 = -fixture.front
	var section: float = maxf(ridge.size.y, ridge.size.z) * 1.5
	for knee in knees:
		section = maxf(section, maxf(knee.size.x, knee.size.z) * 1.5)
	var plane := -INF
	for knee in knees:
		plane = maxf(plane, (knee.position - ridge.position).dot(rear) + section * 0.5)
	var clearance := section * 0.2
	var group_shift := 0.0
	var corner_group_shift := 0.0
	var storage_before: Dictionary = {}
	for part in storage_parts:
		storage_before[part.id] = part.position
		var basis := Basis.from_euler(part.rotation)
		var half_extent: float = (absf(basis.x.dot(rear)) * part.size.x + absf(basis.y.dot(rear)) * part.size.y + absf(basis.z.dot(rear)) * part.size.z) * 0.5
		group_shift = maxf(group_shift, plane + clearance + half_extent - (part.position - ridge.position).dot(rear))
		corner_group_shift = maxf(corner_group_shift, plane + clearance - _nearest_corner_projection(part.snapshot(), ridge.position, rear))
	var group_translation: Vector3 = rear * group_shift
	var result: Dictionary = Storage.place(b, fixture.members, fixture.front)
	_record(label + ":ready_and_derived_plane", result.get("ready", false) and result.get("rear") == rear and result.get("rearPostPlane") == plane and result.get("clearance") == clearance, result)
	if not result.get("ready", false):
		return
	if not result.changes.is_empty():
		_changed_cases += 1
	var preserved: bool = b.parts.size() == before.parts.size()
	var positions_valid := true
	var change_rows_valid := true
	var changes_by_id: Dictionary = {}
	for change in result.changes:
		if not change is Dictionary or not change.get("partId") is String or changes_by_id.has(change.partId):
			change_rows_valid = false
			continue
		changes_by_id[change.partId] = change
	var observations: Array = []
	for index in range(mini(b.parts.size(), before.parts.size())):
		var part = b.parts[index]
		var old: Dictionary = before.parts[index]
		var current: Dictionary = part.snapshot()
		preserved = preserved and is_same(aliases[index], part) and is_same(recipe_aliases[index], part.recipe)
		var owns_storage: bool = fixture.members.has(old.id) and old.semantic == STORAGE_SEMANTIC
		if owns_storage:
			var delta: Vector3 = part.position - old.position
			var before_near := _nearest_corner_projection(old, ridge.position, rear)
			var after_near := _nearest_corner_projection(current, ridge.position, rear)
			var shift: float = delta.dot(rear)
			positions_valid = positions_valid and part.position == old.position + group_translation and delta.y == 0.0 and delta.cross(rear) == Vector3.ZERO and shift >= 0.0 and after_near + PROJECTION_ARITHMETIC_EPS >= plane + clearance and absf(shift - corner_group_shift) <= PROJECTION_ARITHMETIC_EPS
			observations.append({"partId": part.id, "beforeNearestCorner": before_near, "afterNearestCorner": after_near, "requiredPlane": plane + clearance, "shift": shift})
			if changes_by_id.has(part.id):
				var change: Dictionary = changes_by_id[part.id]
				change_rows_valid = change_rows_valid and change.get("before") == old.position and change.get("after") == part.position
			elif part.position != old.position:
				change_rows_valid = false
			current.position = old.position
		elif changes_by_id.has(part.id):
			change_rows_valid = false
		preserved = preserved and _bytes(old) == _bytes(current)
	for id in changes_by_id:
		change_rows_valid = change_rows_valid and fixture.members.has(id) and storage_parts.any(func(part): return part.id == id)
	_record(label + ":only_owned_storage_position_changes", preserved and members_before == _bytes(fixture.members) and index_before == b.physical_parts_by_id and before.recipe == b.recipe and before.rooms == b.rooms and before.id == b.id and before.seed == b.seed and before.style == b.style)
	_record(label + ":rear_plane_clearance_and_uniform_group_translation", positions_valid, {"groupShift": group_shift, "cornerGroupShift": corner_group_shift, "parts": observations})
	var spacing_preserved := true
	var max_spacing_error := 0.0
	for first in range(storage_parts.size()):
		for second in range(first + 1, storage_parts.size()):
			var a = storage_parts[first]
			var c = storage_parts[second]
			var old_offset: Vector3 = storage_before[c.id] - storage_before[a.id]
			var new_offset: Vector3 = c.position - a.position
			# Subtracting float32 translated positions can round differently;
			# exact shared-addition checks above still forbid individual movement.
			var spacing_error := (new_offset - old_offset).length()
			max_spacing_error = maxf(max_spacing_error, spacing_error)
			spacing_preserved = spacing_preserved and spacing_error <= PROJECTION_ARITHMETIC_EPS
	_record(label + ":all_storage_pairwise_relative_spacing_preserved", storage_parts.size() >= 2 and spacing_preserved, {"maxSpacingError": max_spacing_error})
	_record(label + ":complete_group_change_membership", changes_by_id.size() == (storage_parts.size() if group_shift > 0.0 else 0))
	_record(label + ":reported_changes_match_records", change_rows_valid)
	var once := _bytes(b.snapshot())
	var again: Dictionary = Storage.place(b, fixture.members, fixture.front)
	_record(label + ":exact_idempotence", again.get("ready", false) and again.get("changes", []).is_empty() and once == _bytes(b.snapshot()), again)
	var reordered = _copy(before)
	reordered.parts.reverse()
	var ids: Array = fixture.members.duplicate()
	ids.reverse()
	var replay: Dictionary = Storage.place(reordered, ids, fixture.front)
	_record(label + ":order_stable_per_id_decisions", replay.get("ready", false) and _bytes(_sorted_records(reordered)) == _bytes(_sorted_snapshot_records(before, result.changes)))
	# Reporting array order may follow source iteration. Compare its exact per-ID
	# proposals, not timing or incidental traversal order; never round positions.
	_record(label + ":order_stable_change_set", replay.get("ready", false) and _bytes(_sorted_changes(replay.get("changes", []))) == _bytes(_sorted_changes(result.changes)))

func _input_negative(mode: String) -> void:
	var fixture := _fixture(-1.0, -1.0, 0.13, 1.25)
	var b = fixture.b
	var ridge = _semantic_members(fixture, RIDGE_SEMANTIC)[0]
	var knee = _semantic_members(fixture, KNEE_SEMANTIC)[0]
	var reason := "invalid_storage_layout_input"
	match mode:
		"empty_members": fixture.members.clear()
		"missing_member": fixture.members.append("missing_member"); reason = "missing_member"
		"duplicate_member": fixture.members.append(fixture.members[0]); reason = "invalid_or_duplicate_member"
		"nonstring_member": fixture.members.append(17); reason = "invalid_or_duplicate_member"
		"duplicate_source_member": b.add_part(knee.snapshot()); reason = "invalid_or_duplicate_member"
		"missing_ridge": fixture.members.erase(ridge.id); reason = "missing_canopy_geometry"
		"missing_knee": fixture.members.erase(knee.id); reason = "missing_canopy_geometry"
		"double_ridge", "double_knee":
			var record: Dictionary = ridge.snapshot() if mode == "double_ridge" else knee.snapshot()
			record.id = "extra_geometry_record"
			b.add_part(record)
			fixture.members.append(record.id)
			reason = "missing_canopy_geometry"
		"too_many_members": fixture.members.resize(129)
		"front_nonfinite": fixture.front = Vector3(NAN, 0, 1)
		"front_zero": fixture.front = Vector3.ZERO
		"front_vertical": fixture.front = Vector3.UP
		"front_not_unit": fixture.front = Vector3(0, 0, 2)
		"front_x_positive": fixture.front = Vector3.RIGHT; reason = "unsupported_canopy_front"
		"front_x_negative": fixture.front = Vector3.LEFT; reason = "unsupported_canopy_front"
		"front_diagonal_positive": fixture.front = Vector3(0.6, 0, 0.8); reason = "unsupported_canopy_front"
		"front_diagonal_negative": fixture.front = Vector3(-0.6, 0, -0.8); reason = "unsupported_canopy_front"
		"ridge_pitch": ridge.rotation.x = 0.2; reason = "unsupported_canopy_front"
		"ridge_roll": ridge.rotation.z = 0.2; reason = "unsupported_canopy_front"
	_reject_atomic(mode, fixture, reason)

func _late_overflow_control() -> void:
	var fixture := _fixture(-1.0, 1.0, 0.13, 1.0)
	var storage_parts := _semantic_members(fixture, STORAGE_SEMANTIC)
	_record("late_overflow_multiple_producer_storage_precondition", storage_parts.size() >= 2)
	if storage_parts.size() < 2:
		return
	for part in fixture.b.parts:
		if fixture.members.has(part.id):
			part.position.z = 3e38
	# The finite group shift gives the first piece a finite proposal (1e38 -> 3e38).
	# A later piece at 3e38 overflows when that same group shift is added.
	# Any premature application of that first proposal must fail byte preservation.
	storage_parts[0].position.z = 1e38
	storage_parts.back().rotation = Vector3.ZERO
	storage_parts.back().size.z = 3e38
	_reject_atomic("late_nonfinite_proposal_cannot_commit_earlier_storage", fixture, "invalid_storage_position")

func _reject_atomic(label: String, fixture: Dictionary, expected_reason: String) -> void:
	var b = fixture.b
	var before := _bytes(b.snapshot())
	var members_before := _bytes(fixture.members)
	var aliases: Array = b.parts.duplicate()
	var recipe_aliases: Array = b.parts.map(func(part): return part.recipe)
	var index_before: Dictionary = b.physical_parts_by_id.duplicate()
	var result: Dictionary = Storage.place(b, fixture.members, fixture.front)
	var aliases_ok: bool = aliases.size() == b.parts.size()
	for index in range(mini(aliases.size(), b.parts.size())):
		aliases_ok = aliases_ok and is_same(aliases[index], b.parts[index]) and is_same(recipe_aliases[index], b.parts[index].recipe)
	_record("reject:" + label, not result.get("ready", false) and result.get("reason", "") == expected_reason and before == _bytes(b.snapshot()) and members_before == _bytes(fixture.members) and aliases_ok and index_before == b.physical_parts_by_id and result.get("changes", []).is_empty(), result)

func _nearest_corner_projection(record: Dictionary, origin: Vector3, rear: Vector3) -> float:
	var transform := Transform3D(Basis.from_euler(record.rotation), record.position)
	var nearest := INF
	for x in [-1.0, 1.0]:
		for y in [-1.0, 1.0]:
			for z in [-1.0, 1.0]:
				var point: Vector3 = transform * (record.size * Vector3(x, y, z) * 0.5)
				nearest = minf(nearest, (point - origin).dot(rear))
	return nearest

func _semantic_members(fixture: Dictionary, semantic: String) -> Array:
	return fixture.b.parts.filter(func(part): return fixture.members.has(part.id) and part.semantic == semantic)

func _copy(source: Dictionary):
	var b = Blueprint.new(source.id, source.seed, source.style)
	b.recipe = source.recipe.duplicate(true)
	b.rooms = source.rooms.duplicate(true)
	for record in source.parts:
		var part = b.add_part(record)
		b.physical_parts_by_id[part.id] = part
	return b

func _sorted_records(b) -> Array:
	var records: Array = b.part_snapshots()
	records.sort_custom(func(a, c): return String(a.id) < String(c.id))
	return records

func _sorted_snapshot_records(before: Dictionary, changes: Array) -> Array:
	var records: Array = before.parts.duplicate(true)
	var positions: Dictionary = {}
	for change in changes:
		positions[change.partId] = change.after
	for record in records:
		if positions.has(record.id):
			record.position = positions[record.id]
	records.sort_custom(func(a, c): return String(a.id) < String(c.id))
	return records

func _sorted_changes(changes: Array) -> Array:
	var sorted := changes.duplicate(true)
	sorted.sort_custom(func(a, c): return String(a.partId) < String(c.partId))
	return sorted

func _turn(quarter: int) -> Basis:
	match quarter:
		1: return Basis(Vector3(0, 0, -1), Vector3.UP, Vector3(1, 0, 0))
		2: return Basis(Vector3(-1, 0, 0), Vector3.UP, Vector3(0, 0, -1))
		3: return Basis(Vector3(0, 0, 1), Vector3.UP, Vector3(-1, 0, 0))
	return Basis.IDENTITY

func _bytes(value: Variant) -> PackedByteArray:
	return var_to_bytes(value)

func _record(name: String, passed: bool, detail: Variant = "") -> void:
	_checks.append({"name": name, "passed": passed, "detail": detail})

func _json(value: Variant) -> Variant:
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value:
			result[key] = _json(value[key])
		return result
	if value is Array:
		return value.map(func(item): return _json(item))
	return value
