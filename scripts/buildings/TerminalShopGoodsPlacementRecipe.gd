extends RefCounted

## Source/local-publisher geometry placement before elevation/frame assembly.
## Complete producer membership, spatial bay ownership, no ID/seed parsing.
## No scene publication or structural/collision-world authority is invoked.
const MAX_SOURCE_PARTS := 32768
const MAX_MEMBERS := 256
const MAX_GOODS_PER_BAY := 16
const MAX_COORDINATE := 1000000.0
const GoodsGeometry = preload("res://scripts/buildings/BuildingGoodsGeometry.gd")

static func plan(blueprint, member_ids: Array) -> Dictionary:
	if blueprint == null or blueprint.parts.is_empty() or blueprint.parts.size() > MAX_SOURCE_PARTS or member_ids.is_empty() or member_ids.size() > MAX_MEMBERS:
		return _fail("invalid_or_excessive_input")
	var originals: Dictionary = {}
	for part in blueprint.parts:
		if part == null or String(part.id).is_empty() or originals.has(part.id):
			return _fail("missing_or_duplicate_source_id")
		if not blueprint.has_finite_positive_bounds(part) or not _bounded(blueprint.transformed_part_bounds(part)):
			return _fail("invalid_source_bounds", {"partId": part.id})
		originals[part.id] = part
	var members: Dictionary = {}
	var jambs: Array = []
	var headers := 0
	var goods: Array = []
	var recesses: Array = []
	var boards: Array = []
	for id in member_ids:
		if not id is String or id.is_empty() or members.has(id) or not originals.has(id):
			return _fail("invalid_or_missing_member")
		members[id] = true
		var part = originals[id]
		if not String(part.semantic).begins_with("citadel_terminal_shop") and part.semantic != "citadel_urban_lantern_flame":
			return _fail("invalid_row_member_role", {"partId": id})
		if part.semantic == "citadel_terminal_shop_frame":
			if part.kind != "beam" or not _yaw_only(part):
				return _fail("invalid_frame_orientation", {"partId": id})
			if part.size.y > maxf(part.size.x, part.size.z):
				jambs.append(part)
			else:
				headers += 1
		if part.semantic == "citadel_terminal_shop_recess":
			if part.kind != "decor" or not _yaw_only(part):
				return _fail("invalid_bay_recess", {"partId": id})
			recesses.append(part)
		if part.semantic == "citadel_terminal_shop":
			if part.kind != "decor" or not _yaw_only(part) or part.size.y >= minf(part.size.x, part.size.z):
				return _fail("invalid_support_board", {"partId": id})
			boards.append(part)
		if part.semantic != "citadel_terminal_shop_goods":
			continue
		if part.kind not in ["sack", "basket", "pottery"] or not _yaw_only(part) or part.collision_enabled:
			return _fail("unsupported_floor_goods", {"partId": id})
		for key in part.recipe:
			if String(key).begins_with("physicalRequired"):
				return _fail("goods_already_has_joint_contract", {"partId": id})
		goods.append(part)
	if jambs.size() < 2 or jambs.size() != headers * 2 or recesses.size() != headers or goods.is_empty():
		return _fail("incomplete_row_geometry")
	jambs.sort_custom(func(a, b): return a.id < b.id)
	goods.sort_custom(func(a, b): return a.id < b.id)
	recesses.sort_custom(func(a, b): return a.id < b.id)
	var floor_y: float = blueprint.transformed_part_bounds(jambs[0]).position.y
	for jamb in jambs:
		if blueprint.transformed_part_bounds(jamb).position.y != floor_y:
			return _fail("inconsistent_jamb_bottoms")
	var bays: Array = []
	var assigned_jambs: Dictionary = {}
	var assigned_boards: Dictionary = {}
	for recess in recesses:
		var bay := _bay(recess, jambs, boards, floor_y)
		if not bay.ready: return bay
		for id in bay.jambIds:
			if assigned_jambs.has(id): return _fail("ambiguous_bay_jamb")
			assigned_jambs[id] = true
		if assigned_boards.has(bay.counterId): return _fail("ambiguous_bay_counter")
		assigned_boards[bay.counterId] = true
		bays.append(bay)
	var geometry: Dictionary = {}
	for part in goods:
		var choices: Array = []
		for bay in bays:
			var center: Vector3 = bay.inverse * part.position
			if center.x > bay.innerMinX and center.x < bay.innerMaxX and center.z >= bay.membershipMinZ and center.z <= bay.membershipMaxZ:
				choices.append(bay)
		if choices.size() != 1: return _fail("missing_or_ambiguous_goods_bay", {"partId": part.id})
		var bay: Dictionary = choices[0]
		if bay.goods.size() >= MAX_GOODS_PER_BAY: return _fail("goods_per_bay_limit")
		bay.goods.append(part)
		var published_boxes: Array = GoodsGeometry.local_bounds(GoodsGeometry.describe(part.kind, part.size))
		if published_boxes.is_empty() or published_boxes.size() > 16: return _fail("goods_geometry_budget")
		var boxes: Array = [AABB(-part.size * 0.5, part.size)]
		for box in published_boxes:
			if not _bounded(box): return _fail("invalid_published_goods_bounds")
			boxes.append(box)
		geometry[part.id] = boxes
	var proposals: Array = []
	for bay in bays:
		if bay.goods.is_empty(): return _fail("empty_bay_membership")
		for on_counter in [false, true]:
			var group: Array = bay.goods.filter(func(part): return (part.kind == "pottery") == on_counter)
			var packed := _pack(bay, group, geometry, on_counter, floor_y)
			if not packed.ready: return packed
			proposals.append_array(packed.placements)
	# Validate the rounded world positions, not just ideal packing coordinates.
	# Every moved envelope contains its source box AND all publisher primitives.
	# Non-goods are conservatively checked using their existing source boxes.
	var goods_ids: Array = goods.map(func(part): return part.id)
	for bay in bays:
		var placed_bounds: Array = []
		for proposal in proposals:
			var part = originals[proposal.partId]
			var bounds := _envelope(part, geometry[part.id], bay.inverse, proposal.after)
			if not _bounded(bounds): return _fail("invalid_proposed_bounds")
			if proposal.bayId == bay.bayId:
				var area: Rect2 = proposal.area
				if not area.encloses(Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))) or bounds.position.y < proposal.supportY:
					return _fail("rounded_placement_outside_support", {"partId": part.id})
				for id in members:
					if goods_ids.has(id): continue
					var other = originals[id]
					if _overlap(bounds, _source_box(other, bay.inverse)):
						return _fail("goods_intersects_row_member", {"partId": part.id, "foreignPartId": id})
			for prior in placed_bounds:
				if _overlap(bounds, prior.bounds): return _fail("goods_intersects_goods", {"partId": part.id, "foreignPartId": prior.id})
			placed_bounds.append({"id": part.id, "bounds": bounds})
	var changes: Array = []
	proposals.sort_custom(func(a, b): return a.partId < b.partId)
	for proposal in proposals:
		var before: Vector3 = originals[proposal.partId].position
		if proposal.after != before:
			changes.append({"partId": proposal.partId, "before": before, "after": proposal.after})
	var ids: Array = members.keys()
	ids.sort()
	return {"ready": true, "reason": "", "memberIds": ids, "floorY": floor_y,
		"changes": changes, "placements": proposals, "excluded": [],
		"scope": "floor_storage_and_counter_pottery", "evidenceLevel": "source_and_local_publisher_geometry",
		"doesNotProve": "Rooted floor, foreign-world clearance, whole-row elevation, frames, non-goods publisher detail, rendered visuals, physics, gameplay or navigation."}

static func _bay(recess, jambs: Array, boards: Array, floor_y: float) -> Dictionary:
	# A horizontal bay-local frame avoids world-AABB packing for rotated rows.
	var frame := Transform3D(Basis.from_euler(recess.rotation), Vector3(recess.position.x, 0, recess.position.z))
	var inverse := frame.affine_inverse()
	var recess_box := _source_box(recess, inverse)
	var posts: Array = []
	for jamb in jambs:
		var box := _source_box(jamb, inverse)
		if box.end.x > recess_box.position.x and box.position.x < recess_box.end.x and box.end.z > recess_box.position.z and box.position.z < recess_box.end.z:
			posts.append({"part": jamb, "bounds": box})
	if posts.size() != 2: return _fail("missing_or_ambiguous_bay_jambs", {"bayId": recess.id})
	posts.sort_custom(func(a, b): return a.bounds.position.x < b.bounds.position.x)
	var min_x: float = posts[0].bounds.end.x
	var max_x: float = posts[1].bounds.position.x
	var candidates: Array = []
	for board in boards:
		var center: Vector3 = inverse * board.position
		var box := _source_box(board, inverse)
		if center.x > min_x and center.x < max_x and box.position.y > floor_y:
			# Recess, counter and wall shelf must share horizontal axes.
			if board.rotation != recess.rotation: return _fail("incompatible_counter_axes")
			candidates.append({"part": board, "bounds": box})
	if candidates.is_empty(): return _fail("missing_bay_counter", {"bayId": recess.id})
	candidates.sort_custom(func(a, b): return a.bounds.end.y < b.bounds.end.y)
	if candidates.size() > 1 and candidates[0].bounds.end.y == candidates[1].bounds.end.y: return _fail("ambiguous_bay_counter")
	var counter = candidates[0].part
	var cb: AABB = candidates[0].bounds
	var min_z: float
	var max_z: float
	if cb.end.z < recess_box.position.z:
		min_z = cb.end.z
		max_z = recess_box.position.z
	elif cb.position.z > recess_box.end.z:
		min_z = recess_box.end.z
		max_z = cb.position.z
	else: return _fail("counter_recess_has_no_storage_strip")
	if max_x <= min_x: return _fail("bay_has_no_interior_width")
	var counter_min_x := maxf(min_x, cb.position.x)
	var counter_max_x := minf(max_x, cb.end.x)
	return {"ready": true, "reason": "", "bayId": recess.id, "counterId": counter.id,
		"jambIds": posts.map(func(post): return post.part.id), "frame": frame, "inverse": inverse,
		"innerMinX": min_x, "innerMaxX": max_x,
		"membershipMinZ": minf(cb.position.z, recess_box.position.z), "membershipMaxZ": maxf(cb.end.z, recess_box.end.z),
		"floorArea": Rect2(Vector2(min_x, min_z), Vector2(max_x - min_x, max_z - min_z)),
		"counterArea": Rect2(Vector2(counter_min_x, cb.position.z), Vector2(counter_max_x - counter_min_x, cb.size.z)),
		"counterTopY": cb.end.y, "goods": []}

static func _pack(bay: Dictionary, group: Array, geometry: Dictionary, on_counter: bool, floor_y: float) -> Dictionary:
	if group.is_empty(): return {"ready": true, "placements": []}
	group.sort_custom(func(a, b): return a.id < b.id)
	var area: Rect2 = bay.counterArea if on_counter else bay.floorArea
	var support_y: float = bay.counterTopY if on_counter else floor_y
	var shapes: Array = []
	var total_width := 0.0
	for part in group:
		var relative := Transform3D(bay.inverse.basis * Basis.from_euler(part.rotation), Vector3.ZERO)
		var bounds := _boxes_bounds(geometry[part.id], relative)
		if bounds.size.z >= area.size.y: return _fail("goods_too_deep_for_support", {"partId": part.id})
		total_width += bounds.size.x
		shapes.append(bounds)
	if total_width >= area.size.x: return _fail("goods_too_wide_for_support", {"bayId": bay.bayId})
	# Equal free intervals derive solely from available width and full envelopes.
	# Absolute canonical packing remains exactly idempotent after world rounding.
	var gap: float = (area.size.x - total_width) / float(group.size() + 1)
	var cursor: float = area.position.x + gap
	var placements: Array = []
	for index in range(group.size()):
		var part = group[index]
		var box: AABB = shapes[index]
		var local := Vector3(cursor - box.position.x, 0, area.get_center().y - box.get_center().z)
		var after: Vector3 = bay.frame * local
		after.y = _ceil_float32(support_y - box.position.y)
		if not after.is_finite() or absf(after.x) > MAX_COORDINATE or absf(after.y) > MAX_COORDINATE or absf(after.z) > MAX_COORDINATE:
			return _fail("invalid_proposed_bounds")
		placements.append({"partId": part.id, "kind": part.kind, "bayId": bay.bayId, "counterId": bay.counterId,
			"supportId": bay.counterId if on_counter else "", "supportY": support_y,
			"supportKind": "counter" if on_counter else "jamb_derived_floor", "area": area, "after": after})
		cursor += box.size.x + gap
	return {"ready": true, "placements": placements}

static func _source_box(part, inverse: Transform3D) -> AABB:
	return inverse * Transform3D(Basis.from_euler(part.rotation), part.position) * AABB(-part.size * 0.5, part.size)

static func _envelope(part, boxes: Array, inverse: Transform3D, position: Vector3) -> AABB:
	return _boxes_bounds(boxes, inverse * Transform3D(Basis.from_euler(part.rotation), position))

static func _boxes_bounds(boxes: Array, transform: Transform3D) -> AABB:
	var result: AABB = transform * boxes[0]
	for index in range(1, boxes.size()):
		result = result.merge(transform * boxes[index])
	return result

static func _overlap(a: AABB, b: AABB) -> bool:
	var overlap := a.end.min(b.end) - a.position.max(b.position)
	return overlap.x > 0.0 and overlap.y > 0.0 and overlap.z > 0.0

static func apply(blueprint, member_ids: Array) -> Dictionary:
	var result := plan(blueprint, member_ids)
	if not result.ready:
		return result
	var originals: Dictionary = {}
	for part in blueprint.parts:
		originals[part.id] = part
	for change in result.changes:
		originals[change.partId].position = change.after
	result["applied"] = true
	return result

static func _yaw_only(part) -> bool:
	return part.rotation.x == 0.0 and part.rotation.z == 0.0

static func _ceil_float32(value: float) -> float:
	# Smallest representable position not below the exact target. One ULP of
	# directed rounding, not added clearance or a loosened physical tolerance.
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_float(0, value)
	var rounded := bytes.decode_float(0)
	if rounded < value:
		var bits := bytes.decode_u32(0)
		bytes.encode_u32(0, bits - 1 if rounded < 0.0 else bits + 1)
		rounded = bytes.decode_float(0)
	return rounded

static func _bounded(bounds: AABB) -> bool:
	if not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.end.is_finite():
		return false
	for axis in range(3):
		if bounds.size[axis] <= 0.0 or absf(bounds.position[axis]) > MAX_COORDINATE or absf(bounds.end[axis]) > MAX_COORDINATE:
			return false
	return true

static func _fail(reason: String, detail: Dictionary = {}) -> Dictionary:
	var result := detail.duplicate()
	result["ready"] = false
	result["reason"] = reason
	result["changes"] = []
	return result
