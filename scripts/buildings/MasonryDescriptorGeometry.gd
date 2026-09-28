extends RefCounted

## One CPU descriptor algorithm for ordinary publication, apertures and tests.
## No Nodes, render resources, generation, RNG or alternate history sampler.
## Caller owns unchanged part/history through completion or worker retirement.
const Wall = preload("res://scripts/buildings/MasonryWallGeometry.gd")
const Cobble = preload("res://scripts/buildings/SettledCobbleGeometry.gd")
const MONUMENTAL_MASONRY_INSTANCE_BUDGET := 2400

static func begin_source(part, history, source_blueprint_id: String) -> Cursor:
	return Cursor.new(part, history, source_blueprint_id)

static func describe_source(part, history, source_blueprint_id: String) -> Dictionary:
	var cursor := begin_source(part, history, source_blueprint_id)
	while cursor.status().status == "pending_budget": cursor.advance(4000)
	return cursor.take_result()

## Preserve the legacy entry signatures through publisher delegation. All drains
## below use the SAME unit implementations as Cursor, not copied synchronous loops.
static func append_brick_face_transforms(transforms: Array[Transform3D], repair_flags: Array[bool], size: Vector3, axis_x: bool, face_sign: float, unit_length: float, unit_height: float, joint_width: float, face_depth: float, masonry_phase: float, repair_profile: Dictionary, face_index: int) -> void:
	var face := FaceCursor.new(transforms, repair_flags, size, axis_x, face_sign, unit_length, unit_height, joint_width, face_depth, masonry_phase, repair_profile, face_index)
	while not face.complete: face.step()

static func build_masonry_custom_data(transforms: Array[Transform3D], part, history, repair_flags: Array[bool] = [], repair_profile: Dictionary = {}) -> Array[Color]:
	var custom := CustomDataCursor.new(transforms, part, history, repair_flags, repair_profile)
	while not custom.complete and not custom.cancelled: custom.step()
	return custom.result

static func masonry_repair_profile(part, surface_history, source_blueprint_id: String) -> Dictionary:
	return Rules.masonry_repair_profile(part, surface_history, source_blueprint_id)

static func masonry_repair_cluster_at(part, origin: Vector3, repair_profile: Dictionary) -> bool:
	return Rules.masonry_repair_cluster_at(part, origin, repair_profile)

static func masonry_repair_cluster_matches(repair_profile: Dictionary, face_index: int, normalized_y: float, normalized_along: float, course_index := -1) -> bool:
	return Rules.masonry_repair_cluster_matches(repair_profile, face_index, normalized_y, normalized_along, course_index)

static func masonry_repair_patch_blend(part, origin: Vector3, repair_profile: Dictionary, stone_phase: float) -> float:
	return Rules.masonry_repair_patch_blend(part, origin, repair_profile, stone_phase)

static func history_custom_data(world_position: Vector3, history) -> Color:
	var conditions: Dictionary = history.conditions_at(world_position)
	var wear_contact: Dictionary = history.wear_contact_at(world_position)
	return _history_color(conditions, wear_contact)

static func _history_color(conditions: Dictionary, wear_contact: Dictionary) -> Color:
	return Rules._history_color(conditions, wear_contact)

class Rules extends RefCounted:
	# Pure arithmetic shared by sibling cursors and compatibility wrappers.
	static func masonry_repair_profile(part, surface_history, source_blueprint_id: String) -> Dictionary:
		var largest_span := maxf(part.size.x, maxf(part.size.y, part.size.z))
		if String(part.kind) not in ["wall", "foundation"] or largest_span < 2.60 or part.size.y < 1.35:
			return {}
		var phase := float(posmod((source_blueprint_id + ":repair:" + String(part.id)).hash(), 4093)) / 4093.0
		var exterior_front := String(part.id).contains("front") or String(part.semantic).contains("facade")
		if phase < 0.34 and not exterior_front:
			return {}
		var runoff: float = float(surface_history.conditions_at(part.position + Vector3(0.0, part.size.y * 0.18, 0.0)).get("runoff", 0.0))
		return {"face": 0 if exterior_front else int(floor(phase * 17.0)) % 4, "centerY": lerpf(0.30, 0.68, fposmod(phase * 5.17, 1.0)) * (1.0 - runoff * 0.22), "centerAlong": lerpf(0.28, 0.72, fposmod(phase * 9.31, 1.0)), "radiusY": lerpf(0.075, 0.125, fposmod(phase * 13.73, 1.0)), "radiusAlong": lerpf(0.065, 0.115, fposmod(phase * 19.37, 1.0)), "edgePhase": phase}

	static func masonry_repair_cluster_at(part, origin: Vector3, repair_profile: Dictionary) -> bool:
		if repair_profile.is_empty():
			return false
		var face_index := 0
		var along: float = origin.x
		var length: float = part.size.x
		if absf(origin.x) > absf(origin.z):
			face_index = 2 if origin.x < 0.0 else 3
			along = origin.z
			length = part.size.z
		else:
			face_index = 0 if origin.z < 0.0 else 1
		var normalized_y := origin.y / maxf(part.size.y, 0.001) + 0.5
		var normalized_along := along / maxf(length, 0.001) + 0.5
		return masonry_repair_cluster_matches(repair_profile, face_index, normalized_y, normalized_along)

	static func masonry_repair_cluster_matches(repair_profile: Dictionary, face_index: int, normalized_y: float, normalized_along: float, course_index := -1) -> bool:
		if repair_profile.is_empty() or int(repair_profile.get("face", -1)) != face_index:
			return false
		var radius_y := float(repair_profile.get("radiusY", 0.0))
		var vertical_ratio := absf(normalized_y - float(repair_profile.get("centerY", 0.5))) / maxf(radius_y, 0.001)
		if vertical_ratio > 1.0:
			return false
		var phase := float(repair_profile.get("edgePhase", 0.0))
		var resolved_course := course_index if course_index >= 0 else floori(normalized_y * 17.0)
		var row_noise := fposmod(sin(float(resolved_course + 1) * 19.193 + phase * 71.713) * 15731.743, 1.0)
		var center_along := float(repair_profile.get("centerAlong", 0.5)) + (row_noise - 0.5) * float(repair_profile.get("radiusAlong", 0.0)) * 1.35
		var taper := 0.46 + (1.0 - vertical_ratio) * 0.34 + (row_noise - 0.5) * 0.30
		var row_radius := maxf(0.045, float(repair_profile.get("radiusAlong", 0.0)) * taper)
		return absf(normalized_along - center_along) <= row_radius

	static func masonry_repair_patch_blend(part, origin: Vector3, repair_profile: Dictionary, stone_phase: float) -> float:
		if repair_profile.is_empty():
			return 0.70
		var face_index := 0
		var along: float = origin.x
		var length: float = part.size.x
		if absf(origin.x) > absf(origin.z):
			face_index = 2 if origin.x < 0.0 else 3
			along = origin.z
			length = part.size.z
		else:
			face_index = 0 if origin.z < 0.0 else 1
		if face_index != int(repair_profile.get("face", -1)):
			return 0.70
		var normalized_y := origin.y / maxf(part.size.y, 0.001) + 0.5
		var normalized_along := along / maxf(length, 0.001) + 0.5
		var vertical_ratio := absf(normalized_y - float(repair_profile.get("centerY", 0.5))) / maxf(float(repair_profile.get("radiusY", 0.0)), 0.001)
		var horizontal_ratio := absf(normalized_along - float(repair_profile.get("centerAlong", 0.5))) / maxf(float(repair_profile.get("radiusAlong", 0.0)), 0.001)
		var boundary := clampf(maxf(vertical_ratio, horizontal_ratio), 0.0, 1.0)
		var boundary_blend := smoothstep(0.48, 1.0, boundary)
		return clampf(0.96 - boundary_blend * 0.70 + (stone_phase - 0.5) * 0.18, 0.12, 1.0)

	static func _history_color(conditions: Dictionary, wear_contact: Dictionary) -> Color:
		var route_use := float(wear_contact.get("influence", 0.0))
		var route_lateral := float(wear_contact.get("lateral", 1.0))
		return Color(
			clampf(float(conditions.get("runoff", 0.0)), 0.0, 1.0),
			Cobble.pack_route_history(route_use, route_lateral),
			clampf(float(conditions.get("rootDisturbance", 0.0)), 0.0, 1.0),
			clampf(float(conditions.get("canopyDeposit", 0.0)), 0.0, 1.0)
		)

class SourceValues extends RefCounted:
	# Fixed-size scalar capture only. Never part.snapshot() / recipe/history copy.
	var id: String
	var kind: String
	var material_id: String
	var semantic: String
	var position: Vector3
	var size: Vector3
	func _init(part) -> void:
		id=String(part.id); kind=String(part.kind); material_id=String(part.material_id)
		semantic=String(part.semantic); position=part.position; size=part.size

class FaceCursor extends RefCounted:
	var transforms: Array[Transform3D]
	var repair_flags: Array[bool]
	var size: Vector3
	var axis_x: bool
	var face_sign: float
	var unit_length: float
	var unit_height: float
	var joint_width: float
	var face_depth: float
	var masonry_phase: float
	var repair_profile: Dictionary
	var face_index: int
	var length: float
	var row := 0
	var consumed_height := 0.0
	var column := 0
	var cursor := 0.0
	var actual_height := 0.0
	var monumental := false
	var row_active := false
	var complete := false
	func _init(output: Array[Transform3D], flags: Array[bool], source_size: Vector3, along_x: bool, sign_value: float, length_unit: float, height_unit: float, joint: float, depth: float, phase: float, repair: Dictionary, face: int) -> void:
		transforms=output; repair_flags=flags; size=source_size; axis_x=along_x
		face_sign=sign_value; unit_length=length_unit; unit_height=height_unit
		joint_width=joint; face_depth=depth; masonry_phase=phase; repair_profile=repair; face_index=face
		length = size.x if axis_x else size.z
	func step() -> void:
		if complete: return
		if not row_active:
			if consumed_height >= size.y - 0.001:
				complete = true
				return
			var course_noise := fposmod(sin(float(row + 1) * 19.193 + masonry_phase * 71.713) * 15731.743, 1.0)
			monumental = unit_height > 0.40
			actual_height = minf(size.y - consumed_height, unit_height * lerpf(0.78 if monumental else 0.84, 1.18 if monumental else 1.14, course_noise))
			var offset := unit_length * (0.46 + (course_noise - 0.5) * 0.13) if row % 2 == 1 else unit_length * (course_noise - 0.5) * (0.08 if monumental else 0.18)
			cursor = -length * 0.5 - offset
			column = 0
			row_active = true
			return
		if cursor >= length * 0.5 - 0.04:
			consumed_height += actual_height
			row += 1
			row_active = false
			return
		var face_seed := (1.0 if axis_x else 17.0) + masonry_phase * 113.0
		face_seed += 31.0 if face_sign > 0.0 else 0.0
		var piece_noise := fposmod(sin(float(row + 1) * 12.9898 + float(column + 1) * 78.233 + face_seed) * 43758.5453, 1.0)
		var second_noise := fposmod(sin(float(row + 1) * 39.3467 + float(column + 1) * 11.135 + face_seed) * 24634.6345, 1.0)
		var nominal_length := unit_length * lerpf(0.60 if monumental else 0.82, 1.42 if monumental else 1.16, piece_noise)
		var piece_start := maxf(cursor, -length * 0.5)
		var piece_end := minf(cursor + nominal_length, length * 0.5)
		if piece_end - piece_start < 0.12:
			cursor += nominal_length
			column += 1
			return
		var along := (piece_start + piece_end) * 0.5
		var normalized_y := (consumed_height + actual_height * 0.5) / maxf(size.y, 0.001)
		var normalized_along := along / maxf(length, 0.001) + 0.5
		var repair_cluster := Rules.masonry_repair_cluster_matches(repair_profile, face_index, normalized_y, normalized_along, row)
		var repair_perimeter := repair_cluster and (not Rules.masonry_repair_cluster_matches(repair_profile, face_index, normalized_y, normalized_along - 0.075, row) or not Rules.masonry_repair_cluster_matches(repair_profile, face_index, normalized_y, normalized_along + 0.075, row) or not Rules.masonry_repair_cluster_matches(repair_profile, face_index, normalized_y - 0.065, normalized_along, row - 1) or not Rules.masonry_repair_cluster_matches(repair_profile, face_index, normalized_y + 0.065, normalized_along, row + 1))
		var replacement := piece_noise > (0.79 if monumental else 0.84) and second_noise < 0.58
		var chip_factor := lerpf(0.80 if monumental else 0.84, 0.955 if monumental else 0.97, second_noise) if piece_noise > (0.87 if monumental else 0.90) else 1.0
		var resolved_length := maxf(0.08, piece_end - piece_start - joint_width) * chip_factor
		var resolved_height := maxf(0.04, (actual_height - joint_width * 0.72) * lerpf(0.90 if monumental else 0.86, 1.0, second_noise) * (0.90 if replacement else 1.0))
		var resolved_depth := face_depth * lerpf(0.84 if monumental else 0.72, 1.14 if monumental else 1.18, piece_noise) * (1.14 if replacement else 1.0)
		if repair_cluster:
			resolved_length *= lerpf(0.965, 1.0, second_noise)
			resolved_height *= lerpf(0.955, 1.0, piece_noise)
			resolved_depth *= lerpf(0.92, 1.06, second_noise)
			if repair_perimeter:
				resolved_length *= lerpf(0.955, 0.985, second_noise)
				resolved_height *= lerpf(0.955, 0.985, piece_noise)
				resolved_depth *= lerpf(0.90, 1.02, piece_noise)
		var brick_size := Vector3(resolved_length, resolved_height, resolved_depth) if axis_x else Vector3(resolved_depth, resolved_height, resolved_length)
		var along_jitter := (second_noise - 0.5) * (0.010 if monumental else 0.018)
		if chip_factor < 0.99:
			along_jitter += (unit_length - resolved_length) * (0.04 if second_noise > 0.5 else -0.04)
		var course_jitter := (piece_noise - 0.5) * (0.002 if monumental else 0.012)
		var resolved_y := -size.y * 0.5 + consumed_height + actual_height * 0.5 + course_jitter
		var face_displacement := (second_noise - 0.5) * (0.032 if monumental else 0.026)
		var face_position := face_sign * ((size.z if axis_x else size.x) * 0.5 + resolved_depth * 0.18 + face_displacement)
		var position := Vector3(along + along_jitter, resolved_y, face_position) if axis_x else Vector3(face_position, resolved_y, along + along_jitter)
		var settlement_angle := (second_noise - 0.5) * deg_to_rad(1.15 if monumental else 1.15)
		var settlement_basis := Basis(Vector3.FORWARD if axis_x else Vector3.RIGHT, settlement_angle).scaled(brick_size)
		transforms.append(Transform3D(settlement_basis, position))
		repair_flags.append(repair_cluster)
		cursor += nominal_length
		column += 1

class CustomDataCursor extends RefCounted:
	var transforms: Array[Transform3D]
	var part
	var history
	var repair_flags: Array[bool]
	var repair_profile: Dictionary
	var result: Array[Color] = []
	var index := 0
	var phase := "conditions"
	var complete := false
	var cancelled := false
	var query_position: Vector3
	var conditions: Dictionary = {}
	var max_history_query_usec := 0
	func _init(source: Array[Transform3D], source_part, surface_history, flags: Array[bool], profile: Dictionary) -> void:
		transforms=source; part=source_part; history=surface_history; repair_flags=flags; repair_profile=profile
	func step() -> void:
		if complete or cancelled: return
		if index >= transforms.size():
			complete = true
			return
		if phase == "conditions":
			var origin := transforms[index].origin
			query_position = part.position + origin
			var started := Time.get_ticks_usec()
			conditions = history.conditions_at(query_position)
			max_history_query_usec = maxi(max_history_query_usec, Time.get_ticks_usec()-started)
			if cancelled: return
			phase = "wear"
			return
		var started := Time.get_ticks_usec()
		var wear_contact: Dictionary = history.wear_contact_at(query_position)
		max_history_query_usec = maxi(max_history_query_usec, Time.get_ticks_usec()-started)
		if cancelled: return
		result.append(Rules._history_color(conditions, wear_contact))
		index += 1
		phase = "conditions"

class Cursor extends RefCounted:
	# Cancellation only invalidates. Partial arrays and input owners survive until
	# this cursor is handed to the existing retirement worker and released there.
	var part
	var surface_history
	var source_blueprint_id: String
	var transforms: Array[Transform3D] = []
	var repair_flags: Array[bool] = []
	var regular_transforms: Array[Transform3D] = []
	var repair_transforms: Array[Transform3D] = []
	var regular_custom_data: Array[Color] = []
	var repair_custom_data: Array[Color] = []
	var repair_custom_flags: Array[bool] = []
	var repair_profile: Dictionary = {}
	var _input: SourceValues
	var _state := "pending_budget"
	var _phase := "setup"
	var _face: FaceCursor
	var _custom: CustomDataCursor
	var _face_index := 0
	var _index := 0
	var _unit_length: float
	var _unit_height: float
	var _joint_width: float
	var _face_depth: float
	var _masonry_phase: float
	var _mortar_size: Vector3
	var _surface_material_id: String
	var _result: Dictionary = {}
	var _advancing := false
	var _units := 0
	var _max_unit_usec := 0
	var _max_slice_usec := 0
	var _max_history_query_usec := 0
	var _overruns := 0
	var _phase_metrics: Dictionary = {}
	func _init(source_part, history, source_id: String) -> void:
		part=source_part; surface_history=history; source_blueprint_id=source_id
		_input=SourceValues.new(part)
	func advance(budget_usec: int = 2500) -> Dictionary:
		if budget_usec < 1 or budget_usec > 4000: return {"status":"rejected", "reason":"invalid_slice_budget"}
		if _advancing: return {"status":"rejected", "reason":"reentrant_advance"}
		if _state != "pending_budget": return status()
		_advancing = true
		var started := Time.get_ticks_usec()
		var count := 0
		while _state == "pending_budget" and (count == 0 or Time.get_ticks_usec()-started < budget_usec):
			var phase := _phase + (":" + _custom.phase if _custom != null else "")
			var unit_started := Time.get_ticks_usec()
			_step()
			var elapsed := Time.get_ticks_usec()-unit_started
			_max_unit_usec = maxi(_max_unit_usec, elapsed)
			var metric: Dictionary = _phase_metrics.get(phase, {"units":0, "maxUnitUsec":0})
			metric.units += 1
			metric.maxUnitUsec = maxi(metric.maxUnitUsec, elapsed)
			_phase_metrics[phase] = metric
			_units += 1
			count += 1
		var elapsed := Time.get_ticks_usec()-started
		_max_slice_usec = maxi(_max_slice_usec, elapsed)
		if elapsed > budget_usec: _overruns += 1
		_advancing = false
		return status()
	func status() -> Dictionary:
		return {"status":_state, "phase":_phase, "units":_units, "bricks":transforms.size(),
			"regular":regular_transforms.size(), "repair":repair_transforms.size(),
			"maxUnitUsec":_max_unit_usec, "maxSliceUsec":_max_slice_usec,
			"maxHistoryQueryUsec":_max_history_query_usec, "overruns":_overruns,
			"phaseMetrics":_phase_metrics.duplicate(true)}
	func cancel() -> void:
		if _state in ["consumed", "cancelled"]: return
		_state = "cancelled"
		if _custom != null: _custom.cancelled = true
	func take_result() -> Dictionary:
		if _state != "ready": return {}
		_state = "consumed"
		var result := _result
		_result = {}
		return result
	func _step() -> void:
		if _state != "pending_budget": return
		match _phase:
			"setup":
				var size: Vector3 = _input.size
				var material_id := String(_input.material_id)
				var is_monumental_geometry := String(_input.id).begins_with("castle_")
				var uses_aged_castle_stone := is_monumental_geometry and material_id == "stone_foundation"
				var is_rubble_foundation := material_id == "stone_foundation" and not is_monumental_geometry
				_unit_length = 1.18 if is_monumental_geometry else (0.88 if is_rubble_foundation else 0.68)
				_unit_height = 0.52 if is_monumental_geometry else (0.38 if is_rubble_foundation else 0.285)
				if is_monumental_geometry:
					var estimated_instances := 2.0 * (size.x + size.z) * size.y / maxf(_unit_length * _unit_height, 0.001)
					if estimated_instances > float(MONUMENTAL_MASONRY_INSTANCE_BUDGET):
						var density_scale := sqrt(estimated_instances / float(MONUMENTAL_MASONRY_INSTANCE_BUDGET))
						_unit_length *= density_scale
						_unit_height *= density_scale
				_joint_width = 0.018 if is_monumental_geometry else (0.030 if is_rubble_foundation else 0.022)
				_face_depth = 0.105 if is_monumental_geometry else (0.11 if is_rubble_foundation else 0.075)
				_mortar_size = Wall.bed_size(size)
				_masonry_phase = float(posmod(String(_input.id).hash(), 1009)) / 1009.0
				var started := Time.get_ticks_usec()
				repair_profile = Rules.masonry_repair_profile(_input, surface_history, source_blueprint_id)
				_max_history_query_usec = maxi(_max_history_query_usec, Time.get_ticks_usec()-started)
				if _state != "pending_budget": return
				_surface_material_id = "aged_castle_stone" if uses_aged_castle_stone else material_id
				_phase = "faces"
			"faces":
				if _face_index == 4:
					_phase = "partition"
					return
				if _face == null:
					_face = FaceCursor.new(transforms, repair_flags, _input.size, _face_index < 2,
						-1.0 if _face_index % 2 == 0 else 1.0, _unit_length, _unit_height,
						_joint_width, _face_depth, _masonry_phase, repair_profile, _face_index)
				_face.step()
				if _face.complete:
					_face_index += 1
					_face = null
			"partition":
				if _index == transforms.size():
					_custom = CustomDataCursor.new(regular_transforms, _input, surface_history, [], {})
					_phase = "regular_custom"
					_index = 0
					return
				var transform := transforms[_index]
				if repair_flags[_index]: repair_transforms.append(transform)
				else: regular_transforms.append(transform)
				_index += 1
			"regular_custom", "repair_custom":
				_custom.step()
				_max_history_query_usec = maxi(_max_history_query_usec, _custom.max_history_query_usec)
				if _state != "pending_budget": return
				if _custom.complete:
					if _phase == "regular_custom":
						regular_custom_data = _custom.result
						_phase = "repair_flags" if not repair_transforms.is_empty() else "complete"
					else:
						repair_custom_data = _custom.result
						_phase = "complete"
					_custom = null
			"repair_flags":
				if _index < repair_transforms.size():
					repair_custom_flags.append(true)
					_index += 1
					return
				_custom = CustomDataCursor.new(repair_transforms, _input, surface_history, repair_custom_flags, repair_profile)
				_phase = "repair_custom"
			"complete":
				_result = {"mortarSize":_mortar_size, "regularTransforms":regular_transforms, "repairTransforms":repair_transforms,
					"regularCustomData":regular_custom_data, "repairCustomData":repair_custom_data,
					"surfaceMaterialId":_surface_material_id, "repairProfile":repair_profile}
				_state = "ready"
