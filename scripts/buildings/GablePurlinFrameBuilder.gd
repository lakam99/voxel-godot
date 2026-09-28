extends RefCounted

## Frame-only composition: retain the supplied roof skins and gable walls.
## The urban composer installs each declared roof frame exactly once.
const Seats = preload("res://scripts/buildings/GabledRoofFrameBuilder.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")

static func add_frame(blueprint, panel_ids: Array, bearer_ids: Array, frame_id: String) -> Dictionary:
	if panel_ids.size() != 2 or bearer_ids.size() != 2 or frame_id.is_empty():
		return {"ready": false, "reason": "invalid_frame_declaration"}
	for value in panel_ids + bearer_ids:
		if not value is String or value.is_empty():
			return {"ready": false, "reason": "invalid_member_id"}
	var panels: Array = [_find(blueprint, panel_ids[0]), _find(blueprint, panel_ids[1])]
	var bearers: Array = [_find(blueprint, bearer_ids[0]), _find(blueprint, bearer_ids[1])]
	if panels.has(null) or bearers.has(null) or panels[0] == panels[1] or bearers[0] == bearers[1]:
		return {"ready": false, "reason": "missing_or_duplicate_members"}
	for member in panels + bearers:
		if not blueprint.has_finite_positive_bounds(member) or not member.collision_enabled:
			return {"ready": false, "reason": "invalid_member_geometry"}
	for panel in panels:
		if panel.kind != "roof" or panel.recipe.has("physicalAssemblyRole"):
			return {"ready": false, "reason": "roof_already_has_assembly_or_wrong_kind"}
	for bearer in bearers:
		if bearer.kind != "wall":
			return {"ready": false, "reason": "gable_bearer_is_not_wall"}
	panels.sort_custom(func(a, b): return a.position.x < b.position.x)
	bearers.sort_custom(func(a, b): return a.position.z < b.position.z)
	var center_x: float = (panels[0].position.x + panels[1].position.x) * 0.5
	var width: float = (panels[1].position.x - panels[0].position.x) * 2.0
	var center_z: float = (bearers[0].position.z + bearers[1].position.z) * 0.5
	var depth: float = bearers[1].position.z - bearers[0].position.z + minf(bearers[0].size.z, bearers[1].size.z)
	if width <= 4.4 or depth <= 1.0:
		return {"ready": false, "reason": "insufficient_frame_space"}
	var records: Array = []
	var panel_recipes: Array = []
	for side_index in range(2):
		var panel = panels[side_index]
		var side := -1.0 if side_index == 0 else 1.0
		if absf(panel.rotation.x) > 0.0001 or absf(panel.rotation.y) > 0.0001 or side * panel.rotation.z >= 0.0:
			return {"ready": false, "reason": "unsupported_roof_orientation"}
		var purlin_ids: Array = []
		var panel_facts: Array = []
		for offset_index in range(2):
			var offset := width * 0.5 - 1.10 if offset_index == 0 else 1.0
			var x := center_x + side * offset
			var top: float = panel.position.y + (x - panel.position.x) * tan(panel.rotation.z) - 0.04
			var bottom := top - 0.60
			var purlin_id := "%s_purlin_%d_%d" % [frame_id, side_index, offset_index]
			var post_ids: Array = []
			var post_facts: Array = []
			for end_index in range(2):
				var bearer = bearers[end_index]
				if bearer.rotation != Vector3.ZERO or not bearer.collision_enabled:
					return {"ready": false, "reason": "unsupported_gable_bearer"}
				var wall_top: float = bearer.position.y + bearer.size.y * 0.5
				var height := bottom - wall_top
				if height < 0.12 or absf(x - bearer.position.x) + 0.14 > bearer.size.x * 0.5:
					return {"ready": false, "reason": "upright_does_not_fit_bearer"}
				var post_id := "%s_post_%d" % [purlin_id, end_index]
				post_ids.append(post_id)
				records.append(_record(post_id, Vector3(x, wall_top + height * 0.5, bearer.position.z), Vector3(0.28, height, 0.24), {
					"physicalGableFrameId": frame_id, "physicalAssemblyRole": "gable_roof_post",
					"physicalRequiredGableBearerId": bearer.id, "physicalRequiredSeatPartIds": [bearer.id],
					"physicalRequiredSeatFacts": [Seats.world_down_seat_fact(bearer.id, Vector3(0, -height * 0.5, 0), Vector2(0.08, 0.06))]
				}))
				post_facts.append(Seats.world_down_seat_fact(post_id, Vector3(0, -0.30, bearer.position.z - center_z), Vector2(0.06, 0.06)))
			purlin_ids.append(purlin_id)
			records.append(_record(purlin_id, Vector3(x, top - 0.30, center_z), Vector3(0.24, 0.60, depth), {
				"physicalGableFrameId": frame_id, "physicalAssemblyRole": "gable_roof_purlin",
				"physicalRequiredPostPartIds": post_ids, "physicalRequiredSeatPartIds": post_ids.duplicate(), "physicalRequiredSeatFacts": post_facts
			}))
			var local_center: Vector3 = blueprint.part_transform(panel).affine_inverse() * Vector3(x, top - 0.08, center_z)
			panel_facts.append({"seatId": purlin_id, "contactMode": "housed_overlap", "localSpanAxis": "x",
				"localOverlapCenter": local_center, "localOverlapHalfExtents": Vector3(0.075, 0.025, 0.075),
				"minimumLongitudinalEmbedment": 0.15, "minimumVerticalOverlap": 0.05})
		panel_recipes.append({"physicalIntent": "structural_mass", "physicalGableFrameId": frame_id,
			"physicalAssemblyRole": "gable_roof_panel", "physicalRequiredPurlinPartIds": purlin_ids,
			"physicalRequiredSeatPartIds": purlin_ids.duplicate(), "physicalRequiredSeatFacts": panel_facts})
	# Stage everything before mutation: invalid dimensions never leave half a frame.
	var staged: Dictionary = {}
	for bearer in bearers:
		staged[bearer.id] = bearer
	for record in records:
		if _find(blueprint, record.id) != null:
			return {"ready": false, "reason": "frame_id_already_present"}
		staged[record.id] = Part.new(record)
	for record in records:
		var member = staged[record.id]
		for fact in member.recipe.physicalRequiredSeatFacts:
			if not _joint_fits(blueprint, member, staged[fact.seatId], fact):
				return {"ready": false, "reason": "staged_gravity_seat_does_not_fit"}
	for index in range(2):
		for fact in panel_recipes[index].physicalRequiredSeatFacts:
			if not _joint_fits(blueprint, panels[index], staged[fact.seatId], fact):
				return {"ready": false, "reason": "staged_roof_joint_does_not_fit"}
	var added: Array = []
	for record in records:
		blueprint.add_part(record)
		added.append(record.id)
	for index in range(2):
		panels[index].recipe.merge(panel_recipes[index], true)
		panels[index].physical_intent = "structural_mass"
	return {"ready": true, "reason": "", "partIds": added}

static func _joint_fits(blueprint, member, seat, fact: Dictionary) -> bool:
	# Staging proves finite geometry only. Rooting and all mandatory upstream
	# obligations remain the independent validator's responsibility.
	var relative: Transform3D = blueprint.part_transform(seat).affine_inverse() * blueprint.part_transform(member)
	var margin: float = blueprint.PHYSICAL_CONTACT_MARGIN
	if fact.get("loadDirection", "") == "world_down":
		var center: Vector3 = fact.localPatchCenter
		var half: Vector2 = fact.localPatchHalfExtents
		if absf(center.x) + half.x > member.size.x * 0.5 - margin or absf(center.z) + half.y > member.size.z * 0.5 - margin:
			return false
		for x in [-1.0, 0.0, 1.0]:
			for z in [-1.0, 0.0, 1.0]:
				var point := relative * (center + Vector3(x * half.x, 0, z * half.y))
				if not point.is_finite() or absf(point.y - seat.size.y * 0.5) > margin or absf(point.x) > seat.size.x * 0.5 - margin or absf(point.z) > seat.size.z * 0.5 - margin:
					return false
		return true
	var center: Vector3 = fact.localOverlapCenter
	var half: Vector3 = fact.localOverlapHalfExtents
	for x in [-1.0, 1.0]:
		for y in [-1.0, 1.0]:
			for z in [-1.0, 1.0]:
				var local := center + half * Vector3(x, y, z)
				var point := relative * local
				if not point.is_finite():
					return false
				for axis in range(3):
					if absf(local[axis]) >= member.size[axis] * 0.5 - blueprint.STAIR_HOUSED_JOINT_INSET or absf(point[axis]) >= seat.size[axis] * 0.5 - blueprint.STAIR_HOUSED_JOINT_INSET:
						return false
	return true

static func _record(part_id: String, position: Vector3, size: Vector3, recipe: Dictionary) -> Dictionary:
	recipe["physicalIntent"] = "structural_mass"
	recipe["preserveBearingFaces"] = true
	return {"id": part_id, "kind": "beam", "material": "timber_beam", "position": position, "size": size,
		"collision": true, "semantic": "gable_roof_framing", "recipe": recipe}

static func _find(blueprint, part_id):
	for part in blueprint.parts:
		if part.id == String(part_id):
			return part
	return null
