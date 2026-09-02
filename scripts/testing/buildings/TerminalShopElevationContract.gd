extends SceneTree

## Source/service contract, not an engine acceptance or publisher test.
## Main runs this later. Never calls Visual._prepare_frozen_recipe: that path
## already constructs terminal joints. Frozen fixture uses RAW sourceSnapshot.
## VOXEL_TERMINAL_ELEVATION_REPORT: fresh absolute JSON path, existing parent.
## VOXEL_ROOF_INTEGRATION_BASELINE: original frozen binary (read only).
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Elevation = preload("res://scripts/buildings/TerminalShopElevationRecipe.gd")
var _checks: Array = []
var _frozen: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var output := OS.get_environment("VOXEL_TERMINAL_ELEVATION_REPORT").strip_edges().simplify_path()
	if not output.is_absolute_path() or output.get_extension().to_lower() != "json" or FileAccess.file_exists(output):
		quit(2)
		return
	for scale_value in [0.5, 0.75]:
		for variation in [-0.04, 0.05, 0.18]:
			for quarter in range(4):
				_positive(_fixture(scale_value, variation, quarter), "producer:%s:%s:%d" % [str(scale_value), str(variation), quarter])
	for mode in ["empty_members", "missing_member", "duplicate_member", "nonstring_member", "duplicate_source",
		"missing_jamb", "inconsistent_base", "tilted_jamb", "bad_member_role", "row_has_joints",
		"nonfinite_member", "nonfinite_foreign", "huge_finite_bounds", "missing_root", "cached_fake_root",
		"declared_fake_root", "conflicting_root_intents", "conflicting_seat_intents", "malformed_support_intent",
		"missing_dependency", "invalid_fact", "narrow_seat", "foreign_collision"]:
		_negative(mode)
	_stable_support_tie()
	_lateral_controls()
	_frozen_control()
	var passed := not _checks.is_empty() and _checks.all(func(check): return bool(check.passed))
	var report := {"fixture": "TerminalShopElevationContract", "evidenceLevel": "source_service_contract",
		"passed": passed, "checks": _checks, "frozen": _frozen,
		"doesNotProve": "Frozen proposal readiness is separate from contract pass. No publisher meshes, elevated TerminalFrame integration, actual collisions, headed visuals, gameplay or navigation are accepted by this runner."}
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_json(report), "\t"))
	file.flush()
	var error := file.get_error()
	file.close()
	print("Terminal elevation contract: %s (%d checks); frozen ready=%s" % ["PASS" if passed else "FAIL", _checks.size(), str(_frozen.get("ready", false))])
	quit(2 if error != OK else (0 if passed else 1))

func _fixture(scale_value := 0.75, variation := 0.05, quarter := 0) -> Dictionary:
	var b := Blueprint.new("producer_elevation_contract", 101, "timber")
	b.recipe = {"preserve": {"contents": ["original"]}}
	b.rooms = [{"id": "unrelated", "role": "courtyard", "bounds": AABB(Vector3(-50, 0, -50), Vector3(100, 10, 100))}]
	var origin := Vector3(30, 0, -20)
	b.add_part({"id": "root", "kind": "foundation", "position": origin + Vector3(0, 0.5, 0), "size": Vector3(24, 1, 24), "collision": true})
	b.add_part({"id": "seat", "kind": "foundation", "position": origin + Vector3(0, 2, 0), "size": Vector3(20, 2, 20), "collision": true})
	var start := b.parts.size()
	Urban.add_terminal_shop_row(b, Vector3.ZERO, variation)
	var ids: Array = []
	var turn := Basis.IDENTITY
	match quarter:
		1: turn = Basis(Vector3(0, 0, -1), Vector3.UP, Vector3(1, 0, 0))
		2: turn = Basis(Vector3(-1, 0, 0), Vector3.UP, Vector3(0, 0, -1))
		3: turn = Basis(Vector3(0, 0, 1), Vector3.UP, Vector3(-1, 0, 0))
	for index in range(start, b.parts.size()):
		var part = b.parts[index]
		ids.append(part.id)
		part.position = origin + Vector3(0, 1.5, 0) + turn * (part.position * scale_value)
		part.size *= scale_value
		part.rotation = (turn * Basis.from_euler(part.rotation)).get_euler()
	for part in b.parts:
		b.physical_parts_by_id[part.id] = part
	return {"b": b, "ids": ids}

func _positive(fixture: Dictionary, label: String) -> void:
	var b = fixture.b
	var before: Dictionary = b.snapshot()
	var aliases: Array = b.parts.duplicate()
	var recipe_aliases: Array = b.parts.map(func(part): return part.recipe)
	var indexes := _bytes(b.physical_parts_by_id.keys())
	var planned: Dictionary = Elevation.plan(b, fixture.ids)
	_check(label + ":plan_readonly", _bytes(before) == _bytes(b.snapshot()))
	_check(label + ":ready_with_actual_upstream", planned.get("ready", false) and planned.get("supportId") == "seat" and planned.get("upstreamIds", []) == ["root"], _compact(planned))
	if not planned.get("ready", false):
		return
	var reordered = _copy(before)
	reordered.parts.reverse()
	var reverse_ids: Array = fixture.ids.duplicate()
	reverse_ids.reverse()
	var replay: Dictionary = Elevation.plan(reordered, reverse_ids)
	_check(label + ":order_stable_plan", _bytes(planned) == _bytes(replay))
	var applied: Dictionary = Elevation.apply(b, fixture.ids)
	_check(label + ":apply_matches_plan", applied.get("ready", false) and _bytes(applied.get("changes", [])) == _bytes(planned.changes))
	var allowed := before.duplicate(true)
	var after_by_id: Dictionary = {}
	for change in planned.changes:
		after_by_id[change.partId] = change.after
	for record in allowed.parts:
		if after_by_id.has(record.id):
			record.position = after_by_id[record.id]
	_check(label + ":all_other_fields_and_records_exact", _bytes(allowed) == _bytes(b.snapshot()))
	var identities := true
	for index in range(b.parts.size()):
		identities = identities and is_same(aliases[index], b.parts[index]) and is_same(recipe_aliases[index], b.parts[index].recipe)
	_check(label + ":object_recipe_and_cache_identity", identities and indexes == _bytes(b.physical_parts_by_id.keys()))
	var uniform := true
	var old_positions: Dictionary = {}
	for record in before.parts:
		old_positions[record.id] = record.position
	for id in fixture.ids:
		uniform = uniform and b.find_part(id).position == old_positions[id] + planned.translation
	_check(label + ":entire_row_same_y_translation", uniform and planned.translation.x == 0.0 and planned.translation.z == 0.0)
	var once := _bytes(b.snapshot())
	var twice: Dictionary = Elevation.apply(b, fixture.ids)
	_check(label + ":exact_idempotence", twice.get("ready", false) and twice.get("changes", []).is_empty() and once == _bytes(b.snapshot()), _compact(twice))

func _negative(mode: String) -> void:
	var fixture := _fixture()
	var b = fixture.b
	var seat = b.find_part("seat")
	var jamb = b.parts.filter(func(part): return part.semantic == "citadel_terminal_shop_frame" and part.size.y > part.size.x)[0]
	match mode:
		"empty_members": fixture.ids.clear()
		"missing_member": fixture.ids.append("missing")
		"duplicate_member": fixture.ids.append(fixture.ids[0])
		"nonstring_member": fixture.ids.append(12)
		"duplicate_source": b.add_part(seat.snapshot())
		"missing_jamb": fixture.ids.erase(jamb.id)
		"inconsistent_base": jamb.position.y += 0.25
		"tilted_jamb": jamb.rotation.x = 0.2
		"bad_member_role": fixture.ids.append("seat")
		"row_has_joints": jamb.recipe["physicalRequiredSupportPartIds"] = ["seat"]
		"nonfinite_member": jamb.position.x = NAN
		"nonfinite_foreign": seat.rotation.z = INF
		"huge_finite_bounds": seat.size.x = 1e30
		"missing_root": b.parts.erase(b.find_part("root"))
		"cached_fake_root":
			b.parts.erase(b.find_part("root"))
			seat.recipe["physicalRoot"] = true
			seat.recipe["physicalSupportPartIds"] = ["root"]
		"declared_fake_root": seat.physical_intent = "structural_root"
		"conflicting_root_intents":
			var root = b.find_part("root")
			root.physical_intent = "structural_mass"
			root.recipe["physicalIntent"] = "structural_root"
		"conflicting_seat_intents":
			seat.physical_intent = "structural_mass"
			seat.recipe["physicalIntent"] = "structural_root"
		"malformed_support_intent": seat.recipe["physicalIntent"] = 12
		"missing_dependency": seat.recipe["physicalRequiredSupportPartIds"] = ["missing"]
		"invalid_fact": seat.recipe["physicalRequiredSeatFacts"] = [{"seatId": "root", "loadDirection": "world_down", "localPatchCenter": Vector3(NAN, 0, 0)}]
		"narrow_seat": seat.size.x = 0.5
		"foreign_collision":
			var counter = b.parts.filter(func(part): return part.semantic == "citadel_terminal_shop")[0]
			b.add_part({"id": "foreign_obstacle", "kind": "wall", "collision": true, "position": counter.position + Vector3(0, 1.5, 0), "size": Vector3(48, 1, 48)})
	var before := _bytes(b.snapshot())
	var aliases: Array = b.parts.duplicate()
	var result: Dictionary = Elevation.apply(b, fixture.ids)
	var identities := true
	for index in range(b.parts.size()):
		identities = identities and is_same(aliases[index], b.parts[index])
	_check("reject_atomic:" + mode, not result.get("ready", false) and result.get("changes", []).is_empty() and before == _bytes(b.snapshot()) and identities, _compact(result))

func _stable_support_tie() -> void:
	var fixture := _fixture()
	var record: Dictionary = fixture.b.find_part("seat").snapshot()
	record.id = "seat_z"
	fixture.b.add_part(record)
	var before := _bytes(fixture.b.snapshot())
	var result: Dictionary = Elevation.plan(fixture.b, fixture.ids)
	# The deterministic winner is seat. The duplicate seat is still foreign
	# collision, so ties must not exempt neighbouring geometry from rejection.
	_check("stable_id_tie_and_no_neighbour_exemption", result.get("supportId") == "seat" and not result.get("ready", false) and result.get("reason") == "no_lateral_row_clearance" and before == _bytes(fixture.b.snapshot()), _compact(result))

func _lateral_controls() -> void:
	for quarter in range(4):
		var fixture := _fixture(0.75, 0.05, quarter)
		var original: Dictionary = Elevation.plan(fixture.b, fixture.ids)
		if not original.ready:
			_check("lateral_positive_precondition", false, _compact(original))
			continue
		var row: AABB = original.householdBounds
		var axis := 0 if quarter % 2 == 0 else 2
		var position: Vector3 = row.get_center() + original.translation
		position[axis] = row.end[axis] + 0.05
		var size := row.size
		size[axis] = 0.2
		fixture.b.add_part({"id": "neighbour", "kind": "wall", "collision": true, "position": position, "size": size})
		var before: Dictionary = fixture.b.snapshot()
		var result: Dictionary = Elevation.apply(fixture.b, fixture.ids)
		var expected := before.duplicate(true)
		if result.ready:
			for record in expected.parts:
				if fixture.ids.has(record.id): record.position += result.translation
		var check: bool = result.ready and result.translation[axis] < 0 and result.translation[2 if axis == 0 else 0] == 0 and _bytes(expected) == _bytes(fixture.b.snapshot())
		_check("lateral_whole_row_preservation:%d" % quarter, check, _compact(result))
		var reversed = _copy(before)
		reversed.parts.reverse()
		var replay: Dictionary = Elevation.plan(reversed, fixture.ids)
		_check("lateral_order_stability:%d" % quarter, replay.ready and result.ready and replay.translation == result.translation)

func _frozen_control() -> void:
	var path := OS.get_environment("VOXEL_ROOF_INTEGRATION_BASELINE").strip_edges().simplify_path()
	if not path.is_absolute_path() or not FileAccess.file_exists(path):
		_check("frozen_input_required", false)
		return
	var digest := FileAccess.get_sha256(path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > 128 * 1024 * 1024:
		_check("frozen_input_bounded", false)
		if file != null: file.close()
		return
	var envelope: Variant = file.get_var(false)
	var read_ok := file.get_error() == OK and file.get_position() == file.get_length()
	file.close()
	if not read_ok or not envelope is Dictionary or not envelope.get("output") is Dictionary or not envelope.output.get("sourceSnapshot") is Dictionary:
		_check("raw_frozen_source_snapshot", false)
		return
	var source: Dictionary = envelope.output.sourceSnapshot
	if not source.get("parts") is Array or source.parts.size() > Elevation.MAX_SOURCE_PARTS:
		_check("raw_frozen_source_parts", false)
		return
	var b = _copy(source)
	var scratch := Blueprint.new("producer_membership_only", b.seed, b.style)
	Urban.add_terminal_shop_row(scratch, Vector3.ZERO, float(int(b.seed) % 19) / 100.0 - 0.09)
	var ids: Array = scratch.parts.map(func(part): return String(part.id))
	var complete := ids.all(func(id): return b.find_part(id) != null)
	_check("frozen_exact_original_producer_membership", complete and not ids.is_empty())
	if not complete:
		return
	var original := _bytes(b.snapshot())
	var result: Dictionary = Elevation.plan(b, ids)
	_frozen = _compact(result)
	_frozen["rawSourcePath"] = path
	_frozen["rawSourceSha256"] = digest
	_frozen["rawSourcePartCount"] = b.parts.size()
	_frozen["producerMemberCount"] = ids.size()
	_check("frozen_plan_and_archive_unchanged", original == _bytes(b.snapshot()) and digest == FileAccess.get_sha256(path))
	if result.get("ready", false):
		var applied: Dictionary = Elevation.apply(b, ids)
		var allowed := source.duplicate(true)
		var positions: Dictionary = {}
		for change in result.changes: positions[change.partId] = change.after
		for record in allowed.parts:
			if positions.has(record.id): record.position = positions[record.id]
		_check("frozen_ready_apply_preserves_full_source", applied.get("ready", false) and _bytes(allowed) == _bytes(b.snapshot()))
		var once := _bytes(b.snapshot())
		var again: Dictionary = Elevation.apply(b, ids)
		_check("frozen_ready_idempotence", again.get("ready", false) and again.get("changes", []).is_empty() and once == _bytes(b.snapshot()), _compact(again))
	else:
		var rejected: Dictionary = Elevation.apply(b, ids)
		_check("frozen_block_is_explicit_and_atomic", result.reason in ["no_enclosing_intersecting_foundation", "support_closure_unproven", "proposed_source_bounds_overlap", "no_lateral_row_clearance"] and not rejected.get("ready", false) and original == _bytes(b.snapshot()), _compact(rejected))
	_check("frozen_archive_still_unchanged", digest == FileAccess.get_sha256(path))

func _copy(source: Dictionary):
	var b := Blueprint.new(source.id, source.seed, source.style)
	b.recipe = source.recipe.duplicate(true)
	b.rooms = source.rooms.duplicate(true)
	for record in source.parts:
		var part = b.add_part(record)
		# Raw snapshot property is authoritative input too; constructor recipe
		# precedence must not erase a disagreement before the recipe sees it.
		part.physical_intent = record.get("physicalIntent", "")
		b.physical_parts_by_id[part.id] = part
	return b

func _compact(result: Dictionary) -> Dictionary:
	var out := result.duplicate(true)
	if out.has("supportClosure"):
		out.supportClosure.erase("records")
		# Keep source-owned support identities and the independently recomputed
		# closure verdict, without emitting every 5x5 footprint sample.
		if out.supportClosure.has("checks"):
			out.supportClosure.checks = out.supportClosure.checks.map(func(check): return {"partId": check.partId, "passed": check.passed, "supportPartIds": check.get("supportPartIds", [])})
	out.erase("changes")
	return out

func _bytes(value: Variant) -> PackedByteArray:
	return var_to_bytes(value)

func _check(name: String, passed: bool, detail: Variant = "") -> void:
	_checks.append({"name": name, "passed": passed, "detail": detail})

static func _json(value: Variant) -> Variant:
	if value is Vector3: return [_json(value.x), _json(value.y), _json(value.z)]
	if value is Vector2: return [_json(value.x), _json(value.y)]
	if value is AABB or value is Rect2: return {"position": _json(value.position), "size": _json(value.size)}
	if value is float and not is_finite(value): return str(value)
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value: result[key] = _json(value[key])
		return result
	if value is Array: return value.map(func(item): return _json(item))
	return value
