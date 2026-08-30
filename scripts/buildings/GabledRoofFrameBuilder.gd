extends RefCounted

const ROOF_PLATE_THICKNESS := 0.52
const ROOF_PLATE_HEIGHT := 0.56
const ROOF_TIE_HEIGHT := 0.44
const ROOF_TIE_DEPTH := 0.38
const ROOF_POST_WIDTH := 0.36
const ROOF_RIDGE_WIDTH := 0.52
const ROOF_RIDGE_HEIGHT := 0.48
const ROOF_JOINT_HALF_EXTENTS := Vector3(0.07, 0.035, 0.13)
const ROOF_RIDGE_JOINT_HALF_EXTENTS := Vector3(0.10, 0.05, 0.07)


static func add_gabled_roof_frame(blueprint, definition: Dictionary) -> void:
	var prefix := String(definition.get("prefix", ""))
	var center: Vector3 = definition.get("center", Vector3.ZERO) as Vector3
	var width := float(definition.get("width", 0.0))
	var depth := float(definition.get("depth", 0.0))
	var eave_y := float(definition.get("eaveY", 0.0))
	var rise := float(definition.get("rise", 0.0))
	var overhang := float(definition.get("overhang", 0.0))
	var variation := float(definition.get("variation", 0.0))
	var wall_material := String(definition.get("wallMaterial", "stone_foundation"))
	var beam_material := String(definition.get("beamMaterial", "timber_beam"))
	var roof_material := String(definition.get("roofMaterial", "roof_shingle"))
	var roof_semantic := String(definition.get("roofSemantic", "gabled_roof"))
	var gable_semantic := String(definition.get("gableSemantic", "%s_gable" % roof_semantic))
	var eave_bearers: Array = definition.get("eaveBearingPartIds", []) as Array
	var eave_bearing_patch_offsets: Array = definition.get("eaveBearingPatchOffsets", [0.0, 0.0]) as Array
	var align_eave_plates_to_bearers := bool(definition.get("alignEavePlatesToBearers", false))
	if prefix.is_empty() or width <= 0.0 or depth <= 0.0 or rise <= 0.0 or eave_bearers.size() != 2 or eave_bearing_patch_offsets.size() != 2:
		push_error("Gabled roof frame requires a prefix, dimensions, rise, and two explicit eave bearers")
		return
	var left_bearer_id := String(eave_bearers[0])
	var right_bearer_id := String(eave_bearers[1])
	var left_patch_offset_x := float(eave_bearing_patch_offsets[0])
	var right_patch_offset_x := float(eave_bearing_patch_offsets[1])
	var default_patch_half_x := ROOF_PLATE_THICKNESS * (0.19 if align_eave_plates_to_bearers else 0.20)
	var left_patch_half_x := ROOF_PLATE_THICKNESS * 0.135 if absf(left_patch_offset_x) > 0.0 else default_patch_half_x
	var right_patch_half_x := ROOF_PLATE_THICKNESS * 0.135 if absf(right_patch_offset_x) > 0.0 else default_patch_half_x
	if left_bearer_id.is_empty() or right_bearer_id.is_empty():
		push_error("Gabled roof frame %s has an empty named eave bearer" % prefix)
		return
	var frame_id := "%s_frame" % prefix
	var half_width := width * 0.5
	var run := half_width + overhang
	var angle := atan2(rise, run)
	var cosine := maxf(0.18, cos(angle))
	var slope_length := sqrt(run * run + rise * rise)
	var panel_offset := half_width * 0.5 + overhang * 0.5
	var plate_half_x := ROOF_PLATE_THICKNESS * 0.5
	var plate_height := maxf(ROOF_PLATE_HEIGHT, rise * (overhang + plate_half_x) / run + 0.50)
	var plate_z_span := depth + 0.04
	var plate_y := eave_y + ROOF_PLATE_HEIGHT * 0.5
	var left_plate_id := "%s_left_plate" % prefix
	var right_plate_id := "%s_right_plate" % prefix
	plate_y = eave_y + plate_height * 0.5
	var left_plate_x := center.x - half_width if align_eave_plates_to_bearers else center.x - half_width + plate_half_x
	var right_plate_x := center.x + half_width if align_eave_plates_to_bearers else center.x + half_width - plate_half_x
	add_part(blueprint, left_plate_id, "beam", beam_material, Vector3(left_plate_x, plate_y, center.z), Vector3(ROOF_PLATE_THICKNESS, plate_height, plate_z_span), {
		"variation": variation - 0.012,
		"semantic": "%s_wall_plate" % roof_semantic,
		"physicalIntent": "structural_mass",
		"physicalAssemblyRole": "roof_wall_plate",
		"physicalRoofFrameId": frame_id,
		"physicalRequiredSeatPartIds": [left_bearer_id],
		"physicalRequiredSeatFacts": [world_down_seat_fact(left_bearer_id, Vector3(left_patch_offset_x, -plate_height * 0.5, 0.0), Vector2(left_patch_half_x, minf(depth * 0.34, 1.30)))]
	})
	add_part(blueprint, right_plate_id, "beam", beam_material, Vector3(right_plate_x, plate_y, center.z), Vector3(ROOF_PLATE_THICKNESS, plate_height, plate_z_span), {
		"variation": variation + 0.012,
		"semantic": "%s_wall_plate" % roof_semantic,
		"physicalIntent": "structural_mass",
		"physicalAssemblyRole": "roof_wall_plate",
		"physicalRoofFrameId": frame_id,
		"physicalRequiredSeatPartIds": [right_bearer_id],
		"physicalRequiredSeatFacts": [world_down_seat_fact(right_bearer_id, Vector3(right_patch_offset_x, -plate_height * 0.5, 0.0), Vector2(right_patch_half_x, minf(depth * 0.34, 1.30)))]
	})

	var tie_length := width - ROOF_PLATE_THICKNESS + 0.24 + (ROOF_PLATE_THICKNESS * 0.92 if align_eave_plates_to_bearers else 0.0)
	var tie_z := maxf(0.0, depth * 0.5 - 0.26)
	var tie_y := eave_y + ROOF_TIE_HEIGHT * 0.5
	var front_tie_id := "%s_front_tie" % prefix
	var back_tie_id := "%s_back_tie" % prefix
	for tie_definition in [{"id": front_tie_id, "z": center.z - tie_z}, {"id": back_tie_id, "z": center.z + tie_z}]:
		var tie_id := String((tie_definition as Dictionary).get("id", ""))
		var resolved_tie_z := float((tie_definition as Dictionary).get("z", center.z))
		add_part(blueprint, tie_id, "beam", beam_material, Vector3(center.x, tie_y, resolved_tie_z), Vector3(tie_length, ROOF_TIE_HEIGHT, ROOF_TIE_DEPTH), {
			"variation": variation - 0.018,
			"semantic": "%s_tie_beam" % roof_semantic,
			"physicalIntent": "structural_mass",
			"physicalAssemblyRole": "roof_tie_beam",
			"physicalRoofFrameId": frame_id,
			"physicalRequiredSeatPartIds": [left_plate_id, right_plate_id],
			"physicalRequiredSeatFacts": [
				housed_joint_fact(left_plate_id, -1.0, tie_length, 0.10, Vector3(0.07, 0.05, 0.09), "x"),
				housed_joint_fact(right_plate_id, 1.0, tie_length, 0.10, Vector3(0.07, 0.05, 0.09), "x")
			]
		})

	var ridge_y := eave_y + rise
	var post_bottom_y := eave_y + ROOF_TIE_HEIGHT
	var post_height := maxf(0.32, ridge_y + ROOF_RIDGE_HEIGHT * 0.36 - post_bottom_y)
	var post_y := post_bottom_y + post_height * 0.5
	var front_post_id := "%s_front_king_post" % prefix
	var back_post_id := "%s_back_king_post" % prefix
	for post_definition in [{"id": front_post_id, "tieId": front_tie_id, "z": center.z - tie_z}, {"id": back_post_id, "tieId": back_tie_id, "z": center.z + tie_z}]:
		var post_id := String((post_definition as Dictionary).get("id", ""))
		var tie_id := String((post_definition as Dictionary).get("tieId", ""))
		var post_z := float((post_definition as Dictionary).get("z", center.z))
		add_part(blueprint, post_id, "beam", beam_material, Vector3(center.x, post_y, post_z), Vector3(ROOF_POST_WIDTH, post_height, ROOF_POST_WIDTH), {
			"variation": variation - 0.026,
			"semantic": "%s_king_post" % roof_semantic,
			"physicalIntent": "structural_mass",
			"physicalAssemblyRole": "roof_king_post",
			"physicalRoofFrameId": frame_id,
			"physicalRequiredSeatPartIds": [tie_id],
			"physicalRequiredSeatFacts": [world_down_seat_fact(tie_id, Vector3(0.0, -post_height * 0.5, 0.0), Vector2(ROOF_POST_WIDTH * 0.30, ROOF_POST_WIDTH * 0.30))]
		})

	var ridge_id := "%s_ridge" % prefix
	add_part(blueprint, ridge_id, "beam", beam_material, Vector3(center.x, ridge_y, center.z), Vector3(ROOF_RIDGE_WIDTH, ROOF_RIDGE_HEIGHT, depth + overhang * 2.0 + 0.08), {
		"variation": variation,
		"semantic": "%s_ridge" % roof_semantic,
		"physicalIntent": "structural_mass",
		"physicalAssemblyRole": "roof_ridge_beam",
		"physicalRoofFrameId": frame_id,
		"physicalRequiredRoofFramePostIds": [front_post_id, back_post_id],
		"physicalRequiredSeatPartIds": [front_post_id, back_post_id],
		"physicalRequiredSeatFacts": [
			ridge_housed_joint_fact(front_post_id, -1.0, depth + overhang * 2.0 + 0.08, tie_z, "z"),
			ridge_housed_joint_fact(back_post_id, 1.0, depth + overhang * 2.0 + 0.08, tie_z, "z")
		]
	})

	var eave_joint_depth := minf(slope_length * 0.5 - 0.12, maxf(0.16, (overhang if align_eave_plates_to_bearers else overhang + plate_half_x) / cosine))
	var ridge_joint_depth := minf(slope_length * 0.5 - 0.12, 0.18)
	add_roof_panel(blueprint, "%s_left" % prefix, roof_material, roof_semantic, Vector3(center.x - panel_offset, eave_y + rise * 0.5, center.z), Vector3(slope_length, 0.28, depth + overhang * 2.0), Vector3(0.0, 0.0, angle), variation, frame_id, left_plate_id, ridge_id, -1.0, eave_joint_depth, 1.0, ridge_joint_depth)
	add_roof_panel(blueprint, "%s_right" % prefix, roof_material, roof_semantic, Vector3(center.x + panel_offset, eave_y + rise * 0.5, center.z), Vector3(slope_length, 0.28, depth + overhang * 2.0), Vector3(0.0, 0.0, -angle), variation, frame_id, right_plate_id, ridge_id, 1.0, eave_joint_depth, -1.0, ridge_joint_depth)
	add_gable_skins(blueprint, definition, frame_id, "%s_left" % prefix, "%s_right" % prefix, ridge_id, center, width, depth, eave_y, rise, overhang, variation, wall_material, gable_semantic)


static func add_roof_panel(blueprint, part_id: String, material: String, semantic: String, position: Vector3, size: Vector3, rotation: Vector3, variation: float, frame_id: String, plate_id: String, ridge_id: String, eave_end_sign: float, eave_depth: float, ridge_end_sign: float, ridge_depth: float) -> void:
	add_part(blueprint, part_id, "roof", material, position, size, {
		"rotation": rotation,
		"variation": variation,
		"semantic": semantic,
		"physicalIntent": "structural_mass",
		"physicalAssemblyRole": "roof_sloped_span",
		"physicalRoofFrameId": frame_id,
		"physicalRequiredRoofFramePartIds": [plate_id, ridge_id],
		"physicalRequiredSeatPartIds": [plate_id, ridge_id],
		"physicalRequiredSeatFacts": [
			housed_joint_fact(plate_id, eave_end_sign, size.x, eave_depth, ROOF_JOINT_HALF_EXTENTS, "x"),
			housed_joint_fact(ridge_id, ridge_end_sign, size.x, ridge_depth, ROOF_JOINT_HALF_EXTENTS, "x")
		]
	})


static func add_gable_skins(blueprint, definition: Dictionary, frame_id: String, left_panel_id: String, right_panel_id: String, ridge_id: String, center: Vector3, width: float, depth: float, eave_y: float, rise: float, overhang: float, variation: float, wall_material: String, semantic: String) -> void:
	var gable_style := String(definition.get("gableIdStyle", "manor"))
	var strip_count := int(definition.get("gableStripCount", 12))
	var strip_width := width / float(maxi(1, strip_count))
	for face in [-1.0, 1.0]:
		for strip_index in range(strip_count):
			var local_x := -width * 0.5 + strip_width * (float(strip_index) + 0.5)
			var normalized_rise := maxf(0.0, 1.0 - absf(local_x) / (width * 0.5 + overhang))
			var height := rise * normalized_rise
			if height <= 0.06:
				continue
			var part_id := "%s_%s_gable_%02d" % [String(definition.get("prefix", "")), "front" if face < 0.0 else "back", strip_index]
			if gable_style == "castle":
				part_id = "%s_gable_%d_%02d" % [String(definition.get("prefix", "")), int(face), strip_index]
			var anchor_id := ridge_id if absf(local_x) <= 0.001 else left_panel_id if local_x < 0.0 else right_panel_id
			var mount_y := height * 0.5 - minf(0.08, height * 0.25)
			add_part(blueprint, part_id, "wall", wall_material, Vector3(center.x + local_x, eave_y + height * 0.5, center.z + face * depth * 0.5), Vector3(strip_width + 0.025, height, 0.32), {
				"collision": false,
				"variation": variation,
				"semantic": semantic,
				"physicalIntent": "facade_attachment",
				"physicalRoofFrameId": frame_id,
				"physicalRequiredAnchorPartIds": [anchor_id],
				"physicalRequiredAnchorFacts": [{
					"anchorId": anchor_id,
					"contactMode": "attachment_socket",
					"localMountCenter": Vector3(0.0, mount_y, -face * 0.14),
					"localMountHalfExtents": Vector3(0.025, 0.025, 0.025)
				}]
			})


static func housed_joint_fact(seat_id: String, local_end_sign: float, span_length: float, depth_from_end: float, half_extents: Vector3, span_axis: String) -> Dictionary:
	var local_center := Vector3.ZERO
	local_center[local_span_axis_index(span_axis)] = local_end_sign * (span_length * 0.5 - depth_from_end)
	return {
		"seatId": seat_id,
		"contactMode": "housed_overlap",
		"localSpanAxis": span_axis,
		"localOverlapCenter": local_center,
		"localOverlapHalfExtents": half_extents,
		"minimumLongitudinalEmbedment": half_extents[local_span_axis_index(span_axis)] * 2.0,
		"minimumVerticalOverlap": half_extents.y * 2.0
	}


static func ridge_housed_joint_fact(post_id: String, local_end_sign: float, ridge_length: float, post_offset: float, span_axis: String) -> Dictionary:
	var local_center := Vector3.ZERO
	local_center[local_span_axis_index(span_axis)] = local_end_sign * post_offset
	return {
		"seatId": post_id,
		"contactMode": "housed_overlap",
		"localSpanAxis": span_axis,
		"localOverlapCenter": local_center,
		"localOverlapHalfExtents": ROOF_RIDGE_JOINT_HALF_EXTENTS,
		"minimumLongitudinalEmbedment": ROOF_RIDGE_JOINT_HALF_EXTENTS[local_span_axis_index(span_axis)] * 2.0,
		"minimumVerticalOverlap": ROOF_RIDGE_JOINT_HALF_EXTENTS.y * 2.0
	}


static func world_down_seat_fact(seat_id: String, local_patch_center: Vector3, half_extents: Vector2) -> Dictionary:
	return {
		"seatId": seat_id,
		"loadDirection": "world_down",
		"seatFace": "max_y",
		"localPatchCenter": local_patch_center,
		"localPatchHalfExtents": half_extents
	}


static func local_span_axis_index(axis_name: String) -> int:
	match axis_name:
		"x":
			return 0
		"y":
			return 1
		"z":
			return 2
	return 2


static func add_part(blueprint, part_id: String, kind: String, material: String, position: Vector3, size: Vector3, options: Dictionary) -> void:
	blueprint.add_part({
		"id": part_id,
		"kind": kind,
		"material": material,
		"position": position,
		"rotation": options.get("rotation", Vector3.ZERO),
		"size": size,
		"collision": bool(options.get("collision", true)),
		"semantic": String(options.get("semantic", kind)),
		"recipe": options.duplicate(true)
	})
