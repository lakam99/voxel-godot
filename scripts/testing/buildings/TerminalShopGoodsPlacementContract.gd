extends SceneTree

## Producer/source and publisher-local-bounds SERVICE contract only.
## No scene publication, physics frames, screenshots, or visual acceptance.
## VOXEL_TERMINAL_GOODS_PLACEMENT_REPORT: fresh absolute JSON path.
## Optional VOXEL_ROOF_INTEGRATION_BASELINE: RAW frozen source envelope.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Goods = preload("res://scripts/buildings/TerminalShopGoodsPlacementRecipe.gd")

# Execute the real publisher's local primitive construction, intercepting only
# its scene/material sinks. This is explicitly service evidence, not a render.
class LocalBoundsProbe extends "res://scripts/buildings/BuildingPartPublisher.gd":
	var bounds: Array = []

	func material_for(_part) -> Material:
		return null

	func material_for_id(_material_id: String, _variation := 0.0) -> Material:
		return null

	func add_mesh_visual(_parent: Node3D, mesh: Mesh, size: Vector3, position: Vector3, _material: Material, _node_name: String) -> void:
		bounds.append(Transform3D(Basis.from_scale(size), position) * mesh.get_aabb())

	func add_box_visual(_parent: Node3D, size: Vector3, position: Vector3, _material: Material, _node_name: String) -> void:
		bounds.append(AABB(position - size * 0.5, size))

var _checks: Array = []
var _frozen: Dictionary = {"requested": false}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := OS.get_environment("VOXEL_TERMINAL_GOODS_PLACEMENT_REPORT").strip_edges().simplify_path()
	if not path.is_absolute_path() or path.get_extension().to_lower() != "json" or FileAccess.file_exists(path):
		quit(2)
		return
	for scale_value in [0.5, 1.0, 1.4]:
		for variation in [-0.04, 0.18]:
			for floor_y in [-3.17, 0.0, 4.22]:
				for yaw in [0.0, 0.61, PI * 0.5]:
					_positive(_fixture(scale_value, variation, floor_y, yaw), "producer:%s:%s:%s:%s" % [scale_value, variation, floor_y, yaw])
	var renamed := _fixture()
	for index in range(renamed.b.parts.size()):
		var part = renamed.b.parts[index]
		var member_index: int = renamed.ids.find(part.id)
		part.id = "opaque_%03d" % (renamed.b.parts.size() - index)
		if member_index >= 0:
			renamed.ids[member_index] = part.id
	_positive(renamed, "opaque_ids_no_prefix_authority")
	for mode in ["empty", "missing", "double_member", "nonstring", "double_source", "too_many",
		"missing_jamb", "inconsistent_floor", "tilted_jamb", "tilted_goods", "collision_goods",
		"unknown_goods", "foreign_role", "joint_goods", "nonfinite_member", "nonfinite_foreign", "huge_finite", "zero_size",
		"missing_counter", "duplicate_counter", "missing_recess", "outside_bay", "oversized_floor_goods", "oversized_pottery",
		"tilted_counter", "blocked_floor_strip", "counter_source_overlap"]:
		_negative(mode)
	_frozen_control()
	var passed := not _checks.is_empty() and _checks.all(func(check): return bool(check.passed))
	var report := {"fixture": "TerminalShopGoodsPlacementContract", "passed": passed,
		"evidenceLevel": "producer_source_and_publisher_local_bounds_service", "checks": _checks, "frozen": _frozen,
		"doesNotProve": "Rooted floor, foreign-world clearance, non-goods publisher detail, whole-row elevation, live publication, visuals, physics, gameplay or navigation."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_json(report), "\t"))
	file.flush()
	var error := file.get_error()
	file.close()
	print("Terminal goods source contract: %s (%d checks)" % ["PASS" if passed else "FAIL", _checks.size()])
	quit(2 if error != OK else (0 if passed else 1))

func _fixture(scale_value := 1.0, variation := 0.05, floor_y := 4.22, yaw := 0.0) -> Dictionary:
	var b := Blueprint.new("terminal_goods_source_contract", 101, "timber")
	b.recipe = {"preserve": ["whole_source"]}
	b.rooms = [{"id": "untouched_room"}]
	Urban.add_terminal_shop_row(b, Vector3.ZERO, variation)
	var ids: Array = b.parts.map(func(part): return part.id)
	for part in b.parts:
		part.position = Vector3(30, floor_y, -20) + Basis(Vector3.UP, yaw) * (part.position * scale_value)
		part.size *= scale_value
		# Yaw-only goods/jambs stay strictly upright; other producer rotations
		# are retained under the same whole-source rotation.
		part.rotation = Vector3(0, part.rotation.y + yaw, 0) if part.rotation.x == 0.0 and part.rotation.z == 0.0 else (Basis(Vector3.UP, yaw) * Basis.from_euler(part.rotation)).get_euler()
	b.add_part({"id": "unrelated_source", "kind": "decor", "position": Vector3(80, 2, 80), "size": Vector3.ONE, "recipe": {"keep": 17}})
	return {"b": b, "ids": ids}

func _positive(fixture: Dictionary, label: String) -> void:
	var b = fixture.b
	var before: Dictionary = b.snapshot()
	var aliases: Array = b.parts.duplicate()
	var recipes: Array = b.parts.map(func(part): return part.recipe)
	var result: Dictionary = Goods.plan(b, fixture.ids)
	_check(label + ":plan_readonly", var_to_bytes(before) == var_to_bytes(b.snapshot()))
	_check(label + ":all_twelve_supported", result.get("ready", false) and result.get("placements", []).size() == 12 and result.get("excluded", []).is_empty(), result.get("reason", ""))
	if not result.get("ready", false):
		return
	var reversed = _copy(before)
	reversed.parts.reverse()
	var reverse_ids: Array = fixture.ids.duplicate()
	reverse_ids.reverse()
	_check(label + ":order_stable", var_to_bytes(result) == var_to_bytes(Goods.plan(reversed, reverse_ids)))
	var expected := before.duplicate(true)
	var positions: Dictionary = {}
	for change in result.changes:
		positions[change.partId] = change.after
	for record in expected.parts:
		if positions.has(record.id):
			record.position = positions[record.id]
	var applied: Dictionary = Goods.apply(b, fixture.ids)
	var preserved: bool = applied.get("ready", false) and var_to_bytes(expected) == var_to_bytes(b.snapshot())
	var goods_ids: Array = result.placements.map(func(item): return item.partId)
	for index in range(b.parts.size()):
		var part = b.parts[index]
		preserved = preserved and is_same(aliases[index], part) and is_same(recipes[index], part.recipe)
		if not goods_ids.has(part.id):
			preserved = preserved and var_to_bytes(part.snapshot()) == var_to_bytes(before.parts[index])
	_check(label + ":only_goods_positions_changed", preserved)
	var source_clear := true
	var publisher_clear := true
	var support_footprints := true
	var row_clear := true
	var source_by_id: Dictionary = {}
	for part in b.parts: source_by_id[part.id] = part
	var primitive_sets: Array = []
	for part in b.parts:
		if not goods_ids.has(part.id):
			continue
		var placement: Dictionary = result.placements.filter(func(item): return item.partId == part.id)[0]
		var recess = source_by_id[placement.bayId]
		var counter = source_by_id[placement.counterId]
		var inverse := Transform3D(Basis.from_euler(recess.rotation), Vector3(recess.position.x, 0, recess.position.z)).affine_inverse()
		var counter_box: AABB = inverse * Transform3D(Basis.from_euler(counter.rotation), counter.position) * AABB(-counter.size * 0.5, counter.size)
		var source_bottom: float = part.position.y - part.size.y * 0.5
		source_clear = source_clear and source_bottom >= placement.supportY and b.transformed_part_bounds(part).position.y >= placement.supportY
		support_footprints = support_footprints and placement.supportY == (counter_box.end.y if part.kind == "pottery" else result.floorY)
		# Exact minimal representable centre: predecessor must be below target.
		var bytes := PackedByteArray()
		bytes.resize(4)
		bytes.encode_float(0, part.position.y)
		var bits := bytes.decode_u32(0)
		bytes.encode_u32(0, 0x80000001 if part.position.y == 0.0 else (bits + 1 if part.position.y < 0.0 else bits - 1))
		source_clear = source_clear and bytes.decode_float(0) - part.size.y * 0.5 < placement.supportY
		var probe := LocalBoundsProbe.new()
		match part.kind:
			"sack": probe.publish_sack(part, null)
			"basket": probe.publish_basket(part, null)
			"pottery": probe.publish_pottery(part, null)
		publisher_clear = publisher_clear and probe.bounds.size() == {"sack": 4, "basket": 5, "pottery": 2}[part.kind]
		var primitives: Array = []
		for bounds in probe.bounds:
			publisher_clear = publisher_clear and bounds.position.y >= -part.size.y * 0.5 and part.position.y + bounds.position.y >= placement.supportY
			var local_box: AABB = inverse * Transform3D(Basis.from_euler(part.rotation), part.position) * bounds
			var footprint := Rect2(Vector2(local_box.position.x, local_box.position.z), Vector2(local_box.size.x, local_box.size.z))
			support_footprints = support_footprints and (placement.area as Rect2).encloses(footprint)
			if part.kind == "pottery":
				support_footprints = support_footprints and Rect2(Vector2(counter_box.position.x, counter_box.position.z), Vector2(counter_box.size.x, counter_box.size.z)).encloses(footprint)
			else:
				var recess_box: AABB = inverse * Transform3D(Basis.from_euler(recess.rotation), recess.position) * AABB(-recess.size * 0.5, recess.size)
				support_footprints = support_footprints and ((local_box.position.z >= counter_box.end.z and local_box.end.z <= recess_box.position.z) or (local_box.end.z <= counter_box.position.z and local_box.position.z >= recess_box.end.z))
			for other in b.parts:
				if not fixture.ids.has(other.id) or goods_ids.has(other.id): continue
				var other_box: AABB = inverse * Transform3D(Basis.from_euler(other.rotation), other.position) * AABB(-other.size * 0.5, other.size)
				row_clear = row_clear and not _positive_overlap(local_box, other_box)
			primitives.append(bounds)
		primitive_sets.append({"part": part, "boxes": primitives})
	var mutual_clear := true
	for first in range(primitive_sets.size()):
		var a = primitive_sets[first].part
		# Common row axes, actual independently captured primitive bounds.
		var axes := Transform3D(Basis.from_euler(b.parts.filter(func(item): return item.semantic == "citadel_terminal_shop_recess")[0].rotation).inverse(), Vector3.ZERO)
		for second in range(first + 1, primitive_sets.size()):
			var c = primitive_sets[second].part
			for box_a in primitive_sets[first].boxes:
				for box_c in primitive_sets[second].boxes:
					mutual_clear = mutual_clear and not _positive_overlap(axes * Transform3D(Basis.from_euler(a.rotation), a.position) * box_a, axes * Transform3D(Basis.from_euler(c.rotation), c.position) * box_c)
	_check(label + ":source_bottom_minimal_nonpenetrating", source_clear)
	_check(label + ":actual_publisher_local_bottom_within_source_bottom", publisher_clear)
	_check(label + ":floor_and_counter_full_published_footprints", support_footprints)
	_check(label + ":published_goods_clear_source_row_including_counter", row_clear)
	_check(label + ":published_goods_mutual_clearance", mutual_clear)
	var once := var_to_bytes(b.snapshot())
	var again: Dictionary = Goods.apply(b, fixture.ids)
	_check(label + ":exact_idempotence", again.get("ready", false) and again.get("changes", []).is_empty() and once == var_to_bytes(b.snapshot()))

func _negative(mode: String) -> void:
	var fixture := _fixture()
	var b = fixture.b
	var good = b.parts.filter(func(part): return part.kind == "sack")[0]
	var jamb = b.parts.filter(func(part): return part.semantic == "citadel_terminal_shop_frame" and part.size.y > part.size.x)[0]
	var counter = b.parts.filter(func(part): return part.semantic == "citadel_terminal_shop")[0]
	match mode:
		"empty": fixture.ids.clear()
		"missing": fixture.ids.append("missing")
		"double_member": fixture.ids.append(fixture.ids[0])
		"nonstring": fixture.ids.append(3)
		"double_source": b.add_part(good.snapshot())
		"too_many": fixture.ids.resize(Goods.MAX_MEMBERS + 1)
		"missing_jamb": fixture.ids.erase(jamb.id)
		"inconsistent_floor": jamb.position.y += 0.2
		"tilted_jamb": jamb.rotation.x = 0.1
		"tilted_goods": good.rotation.z = 0.1
		"collision_goods": good.collision_enabled = true
		"unknown_goods": good.kind = "crate"
		"foreign_role": fixture.ids.append("unrelated_source")
		"joint_goods": good.recipe["physicalRequiredSupportPartIds"] = [jamb.id]
		"nonfinite_member": good.position.y = NAN
		"nonfinite_foreign": b.parts.back().size.x = INF
		"huge_finite": good.position.y = 1e30
		"zero_size": good.size.y = 0.0
		"missing_counter":
			fixture.ids.erase(counter.id)
			b.parts.erase(counter)
		"duplicate_counter":
			var record: Dictionary = counter.snapshot()
			record.id = "duplicate_support"
			b.add_part(record)
			fixture.ids.append(record.id)
		"missing_recess": fixture.ids.erase(b.parts.filter(func(part): return part.semantic == "citadel_terminal_shop_recess")[0].id)
		"outside_bay": good.position.x += 50.0
		"oversized_floor_goods": good.size.x *= 20.0
		"oversized_pottery": b.parts.filter(func(part): return part.kind == "pottery")[0].size.z *= 20.0
		"tilted_counter": counter.rotation.y += 0.2
		"blocked_floor_strip":
			var recess = b.parts.filter(func(part): return part.semantic == "citadel_terminal_shop_recess")[0]
			counter.position.z = recess.position.z
		"counter_source_overlap":
			# A fixed owned record blocks the otherwise valid floor packing.
			var record := {"id": "owned_obstacle", "kind": "decor", "semantic": "citadel_terminal_shop_fixture", "position": counter.position + Vector3(0, -0.4, 0.8), "size": Vector3(3, 1, 0.7)}
			b.add_part(record)
			fixture.ids.append(record.id)
	var before := var_to_bytes(b.snapshot())
	var aliases: Array = b.parts.duplicate()
	var result: Dictionary = Goods.apply(b, fixture.ids)
	var atomic := before == var_to_bytes(b.snapshot())
	for index in range(b.parts.size()):
		atomic = atomic and is_same(aliases[index], b.parts[index])
	_check("reject_atomic:" + mode, not result.get("ready", false) and result.get("changes", []).is_empty() and atomic, result.get("reason", ""))

func _frozen_control() -> void:
	var path := OS.get_environment("VOXEL_ROOF_INTEGRATION_BASELINE").strip_edges().simplify_path()
	if path.is_empty(): return
	_frozen = {"requested": true, "ready": false}
	if not path.is_absolute_path() or not FileAccess.file_exists(path):
		_check("frozen_input_present", false)
		return
	var digest := FileAccess.get_sha256(path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_check("frozen_input_readable", false)
		return
	if file.get_length() > 128 * 1024 * 1024:
		file.close()
		_check("frozen_input_bounded", false)
		return
	var envelope: Variant = file.get_var(false)
	var read_ok := file.get_error() == OK and file.get_position() == file.get_length()
	file.close()
	if not read_ok or not envelope is Dictionary or not envelope.get("output") is Dictionary or not envelope.output.get("sourceSnapshot") is Dictionary:
		_check("frozen_raw_source_envelope", false)
		return
	var source: Dictionary = envelope.output.sourceSnapshot
	if not source.get("parts") is Array or source.parts.size() > Goods.MAX_SOURCE_PARTS:
		_check("frozen_source_bounded", false)
		return
	var b = _copy(source)
	var scratch := Blueprint.new("producer_membership", b.seed, b.style)
	Urban.add_terminal_shop_row(scratch, Vector3.ZERO, float(int(b.seed) % 19) / 100.0 - 0.09)
	var ids: Array = scratch.parts.map(func(part): return part.id)
	var proposal: Dictionary = Goods.plan(b, ids)
	_frozen = {"requested": true, "ready": proposal.get("ready", false), "reason": proposal.get("reason", ""),
		"sourceSha256": digest, "placements": proposal.get("placements", []), "excluded": proposal.get("excluded", [])}
	_positive({"b": b, "ids": ids}, "raw_frozen_source")
	_check("frozen_archive_unchanged", FileAccess.get_sha256(path) == digest)

func _copy(source: Dictionary):
	var b := Blueprint.new(source.id, source.seed, source.style)
	b.recipe = source.recipe.duplicate(true)
	b.rooms = source.rooms.duplicate(true)
	for record in source.parts:
		var part = b.add_part(record)
		part.physical_intent = record.get("physicalIntent", "")
	return b

func _check(label: String, passed: bool, detail: Variant = "") -> void:
	_checks.append({"name": label, "passed": passed, "detail": detail})

static func _json(value: Variant) -> Variant:
	if value is Vector3: return [value.x, value.y, value.z]
	if value is Vector2: return [value.x, value.y]
	if value is Rect2: return {"position": _json(value.position), "size": _json(value.size)}
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value: result[key] = _json(value[key])
		return result
	if value is Array: return value.map(func(item): return _json(item))
	return value

static func _positive_overlap(a: AABB, b: AABB) -> bool:
	var extent := a.end.min(b.end) - a.position.max(b.position)
	return extent.x > 0.0 and extent.y > 0.0 and extent.z > 0.0
