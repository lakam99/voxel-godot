extends RefCounted
class_name LandmarkBuildingBlueprintBuilder

## Converts a landmark-family recipe into ordinary BuildingBlueprint/Part
## records. Family logic decides topology; all material, collision and visual
## publication remains owned by the existing construction-part pipeline.

const BuildingBlueprintScript := preload("res://scripts/buildings/BuildingBlueprint.gd")
const GabledRoofFrameBuilderScript := preload("res://scripts/buildings/GabledRoofFrameBuilder.gd")
const LandmarkBuildingRecipeSamplerScript := preload("res://scripts/buildings/LandmarkBuildingRecipeSampler.gd")
const MANOR_STAIR_TRANSITION_WALL_CLEARANCE := 1.42
const MANOR_STAIR_TRANSITION_DEPTH := 1.40
const MANOR_TOWER_PASSAGE_CROSSING := 1.80
const MANOR_TOWER_PASSAGE_HEIGHT := 2.48
const MANOR_TOWER_PASSAGE_WIDTH := 1.80


static func build(seed: int, requested_family := "town_hall", context: Dictionary = {}):
	return build_from_recipe(LandmarkBuildingRecipeSamplerScript.sample(seed, requested_family, context))


static func build_from_recipe(raw_recipe: Dictionary):
	var recipe := raw_recipe.duplicate(true)
	match String(recipe.get("family", "cottage")):
		"town_hall":
			return build_town_hall(recipe)
		"manor":
			return build_manor(recipe)
		_:
			return build_family_envelope(recipe)


static func build_manor(recipe: Dictionary):
	# A manor is a family of attached volumes, not a larger cottage envelope.
	# Its recipe controls the main hall, an upper solar that deliberately projects
	# past the lower footprint, a service wing, an attached stair tower, and a
	# covered entry. Each is still published as normal BuildingPart records.
	var seed := int(recipe.get("seed", 0))
	var style := normalized_style(String(recipe.get("style", "timber")))
	var width := float(recipe.get("width", 20.0))
	var depth := float(recipe.get("depth", 15.0))
	var floor_count := maxi(2, int(recipe.get("floorCount", 2)))
	var floor_height := float(recipe.get("floorHeight", 3.55))
	var wall_thickness := float(recipe.get("wallThickness", 0.28))
	var foundation_height := float(recipe.get("foundationHeight", 0.48))
	var roof_overhang := float(recipe.get("roofOverhang", 0.58))
	var roof_rise := float(recipe.get("roofRise", 2.45))
	var variation := float(recipe.get("materialVariation", 0.0))
	var wall_material := "fired_brick" if style == "masonry" else "timber_board"
	var beam_material := "stone_foundation" if style == "masonry" else "timber_beam"
	var blueprint = BuildingBlueprintScript.new("landmark.manor.%s.%d" % [style, seed], seed, style)
	blueprint.set_recipe(recipe)

	var lower_width := snappedf(width * 0.56, 0.20)
	var lower_depth := snappedf(depth * 0.64, 0.20)
	var lower_center := Vector3(-width * 0.06, 0.0, -depth * 0.10)
	var solar_width := lower_width + clampf(width * 0.13, 2.10, 3.10)
	var solar_depth := lower_depth + clampf(depth * 0.11, 1.55, 2.35)
	var solar_center := lower_center + Vector3(-0.22, 0.0, 0.16)
	var wing_width := snappedf(width * 0.38, 0.20)
	var wing_depth := snappedf(depth * 0.48, 0.20)
	# The service wing deliberately projects toward the entry-facing side of the
	# main volume.  Keeping it on the near side of the principal hall makes the
	# L-shaped footprint legible from an ordinary settlement approach instead of
	# hiding a second rectangular mass behind the manor.
	var wing_center := Vector3(lower_center.x - lower_width * 0.5 - wing_width * 0.5 + wall_thickness * 1.25, 0.0, lower_center.z - lower_depth * 0.18)
	var wing_height := floor_height * 0.96
	var tower_span := clampf(snappedf(width * 0.23, 0.20), 5.00, 5.80)
	# Keep the attached tower rear-biased, but derive that bias from the occupied
	# room envelopes. A depth percentage placed both back walls through the stair
	# landings on some sampled proportions.
	var tower_back_limit := minf(
		lower_center.z + lower_depth * 0.5 - tower_span * 0.5 - wall_thickness,
		solar_center.z + solar_depth * 0.5 - tower_span * 0.5 - wall_thickness
	)
	var tower_center := Vector3(width * 0.35, 0.0, tower_back_limit)
	var tower_height := floor_height * float(floor_count) + 1.55
	var wing_passage_z := wing_center.z
	var wing_passage_width := minf(1.62, wing_depth * 0.34)
	var wing_passage := {"side": "left", "coordinate": wing_passage_z, "width": wing_passage_width}
	var main_passage := {"side": "right", "coordinate": wing_passage_z, "width": wing_passage_width}
	var stair_run := manor_stair_run(tower_span)
	var tower_entry_z := tower_center.z - stair_run * 0.5
	var tower_passage := {"side": "right", "coordinate": tower_entry_z, "width": MANOR_TOWER_PASSAGE_WIDTH}
	var upper_passage := {"side": "right", "coordinate": tower_entry_z, "width": MANOR_TOWER_PASSAGE_WIDTH}
	var tower_passage_x := tower_center.x - tower_span * 0.5
	var passage_width := float(tower_passage.get("width", MANOR_TOWER_PASSAGE_WIDTH))
	var lower_floor_access := manor_tower_passage_access("manor_lower_floor_to_bridge", tower_passage_x, foundation_height + 0.20, tower_entry_z, passage_width, "manor_main_lower_floor", -1)
	var lower_bridge_room_access := manor_tower_passage_access("manor_lower_floor_to_bridge", tower_passage_x, foundation_height + 0.20, tower_entry_z, passage_width, "manor_lower_tower_bridge", 1)
	var lower_bridge_stair_access := manor_tower_passage_access("manor_lower_bridge_to_stair", tower_passage_x, foundation_height + 0.20, tower_entry_z, passage_width, "manor_lower_tower_bridge", -1)
	var lower_stair_access := manor_tower_passage_access("manor_lower_bridge_to_stair", tower_passage_x, foundation_height + 0.20, tower_entry_z, passage_width, "manor_stair_tower_floor", 1)
	var upper_floor_access := manor_tower_passage_access("manor_solar_floor_to_bridge", tower_passage_x, foundation_height + floor_height + 0.20, tower_entry_z, passage_width, "manor_solar_upper_floor", -1)
	var upper_bridge_room_access := manor_tower_passage_access("manor_solar_floor_to_bridge", tower_passage_x, foundation_height + floor_height + 0.20, tower_entry_z, passage_width, "manor_solar_tower_bridge", 1)
	var upper_bridge_stair_access := manor_tower_passage_access("manor_solar_bridge_to_stair", tower_passage_x, foundation_height + floor_height + 0.20, tower_entry_z, passage_width, "manor_solar_tower_bridge", -1)
	var upper_stair_access := manor_tower_passage_access("manor_solar_bridge_to_stair", tower_passage_x, foundation_height + floor_height + 0.20, tower_entry_z, passage_width, "manor_stair_exit_0", 1)
	var tower_room_accesses: Array = [lower_bridge_room_access, lower_stair_access, upper_bridge_room_access, upper_stair_access]
	if floor_count > 2:
		var attic_floor_y := foundation_height + floor_height * 2.0 + 0.20
		tower_room_accesses.append(manor_tower_passage_access("manor_attic_floor_to_bridge", tower_passage_x, attic_floor_y, tower_entry_z, passage_width, "manor_attic_tower_bridge", 1))
		tower_room_accesses.append(manor_tower_passage_access("manor_attic_bridge_to_stair", tower_passage_x, attic_floor_y, tower_entry_z, passage_width, "manor_stair_exit_1", 1))

	var lower_bounds := AABB(Vector3(lower_center.x - lower_width * 0.5, foundation_height, lower_center.z - lower_depth * 0.5), Vector3(lower_width, floor_height, lower_depth))
	var solar_bounds := AABB(Vector3(solar_center.x - solar_width * 0.5, foundation_height + floor_height, solar_center.z - solar_depth * 0.5), Vector3(solar_width, floor_height, solar_depth))
	var wing_bounds := AABB(Vector3(wing_center.x - wing_width * 0.5, foundation_height, wing_center.z - wing_depth * 0.5), Vector3(wing_width, wing_height, wing_depth))
	var tower_bounds := AABB(Vector3(tower_center.x - tower_span * 0.5, foundation_height, tower_center.z - tower_span * 0.5), Vector3(tower_span, tower_height, tower_span))
	var entry_door_width := minf(1.78, lower_width * 0.22)
	var entry_access := {
		"id": "manor_main_entry",
		"kind": "exterior_entry",
		"position": Vector3(lower_center.x, foundation_height + 0.20, lower_center.z - lower_depth * 0.5 + 0.82),
		"size": Vector3(entry_door_width + 0.72, MANOR_TOWER_PASSAGE_HEIGHT, 2.20),
		"furnishingSize": Vector3(entry_door_width + 1.04, MANOR_TOWER_PASSAGE_HEIGHT, 2.64),
		"crossingAxis": Vector3.FORWARD
	}
	blueprint.set_room_records([
		{"id": "entry_hall", "role": "entry_hall", "bounds": AABB(lower_bounds.position, Vector3(lower_bounds.size.x * 0.52, floor_height, lower_bounds.size.z)), "wallMountInset": wall_thickness * 0.5, "accesses": [entry_access]},
		{"id": "dining", "role": "dining", "bounds": AABB(Vector3(lower_bounds.position.x + lower_bounds.size.x * 0.52, foundation_height, lower_bounds.position.z), Vector3(lower_bounds.size.x * 0.48, floor_height, lower_bounds.size.z)), "wallMountInset": wall_thickness * 0.5, "accesses": [lower_floor_access, lower_bridge_stair_access]},
		{"id": "kitchen", "role": "kitchen", "bounds": wing_bounds, "wallMountInset": wall_thickness * 0.5, "accesses": []},
		{"id": "private_chamber", "role": "private_chamber", "bounds": AABB(solar_bounds.position, Vector3(solar_bounds.size.x * 0.52, floor_height, solar_bounds.size.z)), "wallMountInset": wall_thickness * 0.5, "accesses": []},
		{"id": "bedroom", "role": "bedroom", "bounds": AABB(Vector3(solar_bounds.position.x + solar_bounds.size.x * 0.52, solar_bounds.position.y, solar_bounds.position.z), Vector3(solar_bounds.size.x * 0.48, floor_height, solar_bounds.size.z)), "wallMountInset": wall_thickness * 0.5, "accesses": [upper_floor_access, upper_bridge_stair_access]},
		{"id": "store", "role": "store", "bounds": tower_bounds, "wallMountInset": wall_thickness * 0.5, "accesses": tower_room_accesses}
	])

	add_manor_foundation(blueprint, "manor_main_foundation", lower_center, lower_width, lower_depth, foundation_height, variation)
	add_manor_foundation(blueprint, "manor_service_foundation", wing_center, wing_width, wing_depth, foundation_height, variation)
	add_manor_foundation(blueprint, "manor_tower_foundation", tower_center, tower_span, tower_span, foundation_height, variation)
	add_manor_storey_shell(blueprint, "manor_main_lower", wall_material, lower_center, lower_width, lower_depth, foundation_height, floor_height, wall_thickness, variation, true, wing_passage, {"right": tower_passage})
	# Each occupied level meets the same stair tower through a published floor
	# bridge.  The bridge covers the small intentional separation between the
	# composed volumes, so the visible connection and the walkable collision
	# connection are one construction fact.
	add_manor_tower_bridge(blueprint, "manor_lower_tower_bridge", tower_center, tower_span, lower_center, lower_width, tower_entry_z, float(tower_passage.get("width", MANOR_TOWER_PASSAGE_WIDTH)), foundation_height, variation)
	add_manor_storey_shell(blueprint, "manor_solar_upper", wall_material, solar_center, solar_width, solar_depth, foundation_height + floor_height, floor_height, wall_thickness, variation, false, upper_passage)
	add_manor_tower_bridge(blueprint, "manor_solar_tower_bridge", tower_center, tower_span, solar_center, solar_width, tower_entry_z, float(upper_passage.get("width", MANOR_TOWER_PASSAGE_WIDTH)), foundation_height + floor_height, variation)
	add_manor_solar_corbels(blueprint, lower_center, lower_width, lower_depth, solar_center, solar_width, solar_depth, foundation_height + floor_height, beam_material, variation)
	var roof_center := solar_center
	var roof_width := solar_width
	var roof_depth := solar_depth
	var roof_eave_y := foundation_height + floor_height * 2.0
	var roof_shell_prefix := "manor_solar_upper"
	if floor_count >= 3:
		# The third-storey attic sits inside the broader solar footprint. Publish
		# that full ceiling/floor plane first: otherwise the narrower attic floor
		# leaves a visible, physically open gap around the upper-storey wall.
		# Match the occupied upper-storey floor envelope.  The previous wider
		# ceiling sent its joists past the real wall headers, leaving a gap in
		# their load path despite appearing to cover the room from below.
		var ceiling_size := Vector3(solar_width - wall_thickness, 0.20, solar_depth - wall_thickness)
		var ceiling: BuildingPart = add_part(blueprint, "manor_solar_upper_ceiling", "floor", "timber_board", Vector3(solar_center.x, roof_eave_y - 0.10, solar_center.z), ceiling_size, {"variation": variation, "semantic": "manor_solar_ceiling", "physicalAssemblyRole": "floor_diaphragm"})
		var ceiling_bearer_ids: Array[String] = []
		for bearer_index in range(3):
			var bearer_z := lerpf(solar_center.z - ceiling_size.z * 0.5 + 0.18, solar_center.z + ceiling_size.z * 0.5 - 0.18, float(bearer_index) * 0.5)
			var bearer_id := "manor_solar_upper_ceiling_bearer_%d" % bearer_index
			ceiling_bearer_ids.append(bearer_id)
			add_part(blueprint, bearer_id, "beam", beam_material, Vector3(solar_center.x, roof_eave_y - 0.18, bearer_z), Vector3(ceiling_size.x, 0.28, 0.30), {"variation": variation - 0.02, "semantic": "manor_solar_ceiling_bearer", "physicalAssemblyRole": "floor_bearer", "physicalRequiredSeatPartIds": ["manor_solar_upper_left_header", "manor_solar_upper_right_header"], "physicalRequiredSeatFacts": [{"seatId": "manor_solar_upper_left_header", "bearerFace": "min_x", "seatFace": "max_x"}, {"seatId": "manor_solar_upper_right_header", "bearerFace": "max_x", "seatFace": "min_x"}]})
		ceiling.recipe["physicalRequiredSupportPartIds"] = ceiling_bearer_ids
		ceiling.recipe["physicalRequiredCoverageByZIndex"] = ceiling_bearer_ids
		var attic_width := solar_width * 0.76
		var attic_depth := solar_depth * 0.78
		var attic_center := solar_center + Vector3(0.20, 0.0, 0.08)
		blueprint.rooms.append({
			"id": "attic",
			"role": "store",
			"bounds": AABB(
				Vector3(attic_center.x - attic_width * 0.5, foundation_height + floor_height * 2.0, attic_center.z - attic_depth * 0.5),
				Vector3(attic_width, floor_height * 0.82, attic_depth)
			),
			"wallMountInset": wall_thickness * 0.5,
			"accesses": [
				manor_tower_passage_access("manor_attic_floor_to_bridge", tower_passage_x, foundation_height + floor_height * 2.0 + 0.20, tower_entry_z, passage_width, "manor_attic_floor", -1),
				manor_tower_passage_access("manor_attic_bridge_to_stair", tower_passage_x, foundation_height + floor_height * 2.0 + 0.20, tower_entry_z, passage_width, "manor_attic_tower_bridge", -1)
			]
		})
		add_manor_storey_shell(blueprint, "manor_attic", wall_material, attic_center, attic_width, attic_depth, foundation_height + floor_height * 2.0, floor_height * 0.82, wall_thickness, variation, false, upper_passage)
		add_manor_tower_bridge(blueprint, "manor_attic_tower_bridge", tower_center, tower_span, attic_center, attic_width, tower_entry_z, float(upper_passage.get("width", MANOR_TOWER_PASSAGE_WIDTH)), foundation_height + floor_height * 2.0, variation)
		roof_center = attic_center
		roof_width = attic_width
		roof_depth = attic_depth
		roof_eave_y = foundation_height + floor_height * 2.0 + floor_height * 0.82
		roof_shell_prefix = "manor_attic"
	add_manor_gabled_roof(blueprint, "manor_main_roof", wall_material, beam_material, roof_center, roof_width, roof_depth, roof_eave_y, roof_rise, roof_overhang, variation, ["%s_left_header" % roof_shell_prefix, "%s_right_header" % roof_shell_prefix], [0.0, 0.0], true)

	add_manor_storey_shell(blueprint, "manor_service_wing", wall_material, wing_center, wing_width, wing_depth, foundation_height, wing_height, wall_thickness, variation, false, main_passage)
	add_manor_gabled_roof(blueprint, "manor_service_roof", wall_material, beam_material, wing_center, wing_width, wing_depth, foundation_height + wing_height, roof_rise * 0.72, roof_overhang * 0.82, variation, ["manor_service_wing_left_header", "manor_service_wing_right_header"], [0.0, 0.0], true)

	# The stair tower has a real exterior wall.  Its left side is split into one
	# doorway-height opening per occupied storey, rather than being removed as a
	# single open face.  This preserves an enclosed tower while connecting every
	# generated level through the same core.
	add_manor_storey_shell(blueprint, "manor_stair_tower", wall_material, tower_center, tower_span, tower_span, foundation_height, tower_height, wall_thickness, variation, false, {}, {}, ["left"])
	add_manor_tower_left_wall_with_storey_passages(blueprint, "manor_stair_tower_left", wall_material, tower_center, tower_span, foundation_height, tower_height, floor_height, floor_count, tower_entry_z, float(tower_passage.get("width", 1.40)), wall_thickness, variation)
	add_manor_tower_stairs(blueprint, tower_center, tower_span, foundation_height, floor_height, floor_count, variation)
	add_part(blueprint, "manor_tower_crown", "beam", beam_material, Vector3(tower_center.x, foundation_height + tower_height + 0.18, tower_center.z), Vector3(tower_span + 0.32, 0.36, tower_span + 0.32), {"variation": variation, "semantic": "manor_tower_crown"})
	add_manor_gabled_roof(blueprint, "manor_tower_roof", wall_material, beam_material, tower_center, tower_span + 0.24, tower_span + 0.24, foundation_height + tower_height + 0.34, roof_rise * 0.82, roof_overhang * 0.58, variation, ["manor_tower_crown", "manor_tower_crown"], [0.0, 0.0], false)

	# A threshold sits at the published opening shared by the main hall and the
	# wing. It records the connection as a real construction fact rather than a
	# fixture-only traversal exception.
	add_part(blueprint, "manor_wing_threshold", "floor", "timber_board", Vector3(lower_center.x - lower_width * 0.5, foundation_height + 0.10, wing_passage_z), Vector3(wall_thickness * 2.20, 0.20, wing_passage_width), {"variation": variation, "semantic": "manor_wing_threshold"})
	add_manor_portico(blueprint, lower_center, lower_width, lower_depth, foundation_height, floor_height, beam_material, variation)
	return blueprint


static func add_manor_storey_shell(blueprint, prefix: String, wall_material: String, center: Vector3, width: float, depth: float, bottom_y: float, height: float, thickness: float, variation: float, has_entry_door := false, side_passage: Dictionary = {}, side_passages: Dictionary = {}, open_sides: Array = []) -> void:
	var wall_y := bottom_y + height * 0.5
	var front_z := center.z - depth * 0.5
	var back_z := center.z + depth * 0.5
	var window_height := minf(1.34, height * 0.42)
	var window_y := bottom_y + height * 0.60
	var side_window_depth := minf(1.64, depth * 0.26)
	var left_passage: Dictionary = side_passages.get("left", side_passage if String(side_passage.get("side", "")) == "left" else {}) as Dictionary
	var right_passage: Dictionary = side_passages.get("right", side_passage if String(side_passage.get("side", "")) == "right" else {}) as Dictionary
	var floor_size := Vector3(width - thickness, 0.20, depth - thickness)
	var floor: BuildingPart = add_part(blueprint, "%s_floor" % prefix, "floor", "timber_board", Vector3(center.x, bottom_y + 0.10, center.z), floor_size, {"variation": variation, "semantic": "%s_floor" % prefix, "navigationRole": "walkable_support", "physicalAssemblyRole": "floor_diaphragm"})
	if not open_sides.has("left") and not open_sides.has("right"):
		var front_left_seat := "%s_front_left_sill" % prefix if has_entry_door else "%s_front_sill" % prefix
		var front_right_seat := "%s_front_right_sill" % prefix if has_entry_door else "%s_front_sill" % prefix
		var left_receiver_id := "%s_left_floor_ledger" % prefix
		var right_receiver_id := "%s_right_floor_ledger" % prefix
		add_part(blueprint, left_receiver_id, "beam", "timber_beam", Vector3(center.x - width * 0.5 + thickness * 0.25, bottom_y + 0.04, center.z), Vector3(thickness * 0.50, 0.30, floor_size.z), {"variation": variation - 0.025, "semantic": "%s_left_floor_ledger" % prefix, "physicalAssemblyRole": "floor_ledger", "physicalRequiredSeatPartIds": [front_left_seat, "%s_back_sill" % prefix], "physicalRequiredSeatFacts": [{"seatId": front_left_seat, "bearerFace": "min_z", "seatFace": "max_z"}, {"seatId": "%s_back_sill" % prefix, "bearerFace": "max_z", "seatFace": "min_z"}]})
		add_part(blueprint, right_receiver_id, "beam", "timber_beam", Vector3(center.x + width * 0.5 - thickness * 0.25, bottom_y + 0.04, center.z), Vector3(thickness * 0.50, 0.30, floor_size.z), {"variation": variation - 0.025, "semantic": "%s_right_floor_ledger" % prefix, "physicalAssemblyRole": "floor_ledger", "physicalRequiredSeatPartIds": [front_right_seat, "%s_back_sill" % prefix], "physicalRequiredSeatFacts": [{"seatId": front_right_seat, "bearerFace": "min_z", "seatFace": "max_z"}, {"seatId": "%s_back_sill" % prefix, "bearerFace": "max_z", "seatFace": "min_z"}]})
		var bearer_ids: Array[String] = []
		for bearer_index in range(3):
			var z_fraction := float(bearer_index) * 0.5
			var bearer_z := lerpf(center.z - floor_size.z * 0.5 + 0.16, center.z + floor_size.z * 0.5 - 0.16, z_fraction)
			var bearer_id := "%s_floor_bearer_%d" % [prefix, bearer_index]
			bearer_ids.append(bearer_id)
			add_part(blueprint, bearer_id, "beam", "timber_beam", Vector3(center.x, bottom_y + 0.04, bearer_z), Vector3(floor_size.x, 0.30, 0.32), {"variation": variation - 0.02, "semantic": "%s_floor_bearer" % prefix, "physicalAssemblyRole": "floor_bearer", "physicalRequiredSeatPartIds": [left_receiver_id, right_receiver_id], "physicalRequiredSeatFacts": [{"seatId": left_receiver_id, "bearerFace": "min_x", "seatFace": "max_x"}, {"seatId": right_receiver_id, "bearerFace": "max_x", "seatFace": "min_x"}]})
		floor.recipe["physicalRequiredSupportPartIds"] = bearer_ids
		floor.recipe["physicalRequiredCoverageByZIndex"] = bearer_ids
	if has_entry_door:
		var door_width := minf(1.78, width * 0.22)
		var segment_width := (width - door_width) * 0.5
		var left_center_x := center.x - door_width * 0.5 - segment_width * 0.5
		var right_center_x := center.x + door_width * 0.5 + segment_width * 0.5
		var side_window_width := minf(1.48, segment_width - 0.28)
		add_manor_wall_with_window(blueprint, "%s_front_left" % prefix, wall_material, Vector3(left_center_x, wall_y, front_z), Vector3(segment_width, height, thickness), Vector3(left_center_x, window_y, front_z), Vector3(side_window_width, window_height, thickness + 0.05), variation)
		add_manor_wall_with_window(blueprint, "%s_front_right" % prefix, wall_material, Vector3(right_center_x, wall_y, front_z), Vector3(segment_width, height, thickness), Vector3(right_center_x, window_y, front_z), Vector3(side_window_width, window_height, thickness + 0.05), variation)
		add_part(blueprint, "%s_entry_door" % prefix, "door", "painted_door", Vector3(center.x, bottom_y + minf(height * 0.50, 1.28), front_z - thickness * 0.70), Vector3(door_width, minf(height - 0.44, 2.56), 0.16), {"variation": variation, "semantic": "manor_entry_door", "doorEgress": {"approachPartIds": ["manor_portico_floor", "manor_portico_transition"], "clearanceLaneWidth": door_width + 1.04, "outwardEndpointPartId": "manor_portico_transition"}})
	else:
		add_manor_wall_with_window(blueprint, "%s_front" % prefix, wall_material, Vector3(center.x, wall_y, front_z), Vector3(width, height, thickness), Vector3(center.x + width * 0.20, window_y, front_z), Vector3(minf(1.56, width * 0.22), window_height, thickness + 0.05), variation)
	add_manor_wall_with_window(blueprint, "%s_back" % prefix, wall_material, Vector3(center.x, wall_y, back_z), Vector3(width, height, thickness), Vector3(center.x - width * 0.20, window_y, back_z), Vector3(minf(1.56, width * 0.22), window_height, thickness + 0.05), variation)
	if open_sides.has("left"):
		pass
	elif not left_passage.is_empty():
		add_manor_wall_with_passage(blueprint, "%s_left" % prefix, wall_material, Vector3(center.x - width * 0.5, wall_y, center.z), Vector3(thickness, height, depth), float(left_passage.get("coordinate", center.z)), float(left_passage.get("width", 1.40)), bottom_y, variation)
	else:
		add_manor_wall_with_window(blueprint, "%s_left" % prefix, wall_material, Vector3(center.x - width * 0.5, wall_y, center.z), Vector3(thickness, height, depth), Vector3(center.x - width * 0.5, window_y, center.z - depth * 0.18), Vector3(thickness + 0.05, window_height, side_window_depth), variation)
	if open_sides.has("right"):
		pass
	elif not right_passage.is_empty():
		add_manor_wall_with_passage(blueprint, "%s_right" % prefix, wall_material, Vector3(center.x + width * 0.5, wall_y, center.z), Vector3(thickness, height, depth), float(right_passage.get("coordinate", center.z)), float(right_passage.get("width", 1.40)), bottom_y, variation)
	else:
		add_manor_wall_with_window(blueprint, "%s_right" % prefix, wall_material, Vector3(center.x + width * 0.5, wall_y, center.z), Vector3(thickness, height, depth), Vector3(center.x + width * 0.5, window_y, center.z + depth * 0.18), Vector3(thickness + 0.05, window_height, side_window_depth), variation)


static func add_manor_foundation(blueprint, part_id: String, center: Vector3, width: float, depth: float, height: float, variation: float) -> void:
	add_part(blueprint, part_id, "foundation", "stone_foundation", Vector3(center.x, height * 0.5, center.z), Vector3(width + 0.42, height, depth + 0.42), {"variation": variation, "semantic": "manor_foundation", "navigationRole": "structural_mass"})


static func manor_stair_run(tower_span: float) -> float:
	return maxf(2.20, tower_span - MANOR_STAIR_TRANSITION_WALL_CLEARANCE * 2.0)


static func manor_tower_passage_access(access_id: String, passage_x: float, floor_y: float, passage_z: float, passage_width: float, support_part_id: String, endpoint_side: int) -> Dictionary:
	return {
		"id": access_id,
		"kind": "interior_passage",
		"position": Vector3(passage_x, floor_y, passage_z),
		"size": Vector3(MANOR_TOWER_PASSAGE_CROSSING, MANOR_TOWER_PASSAGE_HEIGHT, passage_width),
		"furnishingSize": Vector3(MANOR_TOWER_PASSAGE_CROSSING + 0.80, MANOR_TOWER_PASSAGE_HEIGHT, passage_width + 0.40),
		"crossingAxis": Vector3.RIGHT,
		"endpointSide": endpoint_side,
		"supportPartId": support_part_id
	}


static func add_manor_tower_stairs(blueprint, tower_center: Vector3, tower_span: float, foundation_height: float, floor_height: float, floor_count: int, variation: float) -> void:
	# A real stair flight uses visible treads, an exposed carriage below each
	# flight, and one broad masonry pier beneath each landing. The collision
	# surface therefore comes from the same construction members the player sees.
	var run := manor_stair_run(tower_span)
	var half_rise := floor_height * 0.5
	var angle := atan2(half_rise, run)
	var ramp_width := tower_span * 0.28
	var left_x := tower_center.x - tower_span * 0.20
	var right_x := tower_center.x + tower_span * 0.20
	var tread_count := maxi(7, ceili(half_rise / 0.24))
	var tread_run := run / float(tread_count)
	var tread_rise := half_rise / float(tread_count)
	for level in range(maxi(1, floor_count - 1)):
		var base_y := foundation_height + floor_height * float(level)
		var base_pier_id := "manor_stair_base_pier_%d" % level
		var landing_pier_id := "manor_stair_landing_pier_%d" % level
		var exit_pier_id := "manor_stair_exit_pier_%d" % level
		var base_underframe_id := "manor_stair_base_underframe_%d" % level
		var landing_underframe_id := "manor_stair_landing_underframe_%d" % level
		var exit_underframe_id := "manor_stair_exit_underframe_%d" % level
		var shoe_thickness := 0.14
		add_manor_stair_bearing_pier(blueprint, base_pier_id, Vector3(tower_center.x, 0.0, tower_center.z - run * 0.5), base_y - 0.27, tower_span - 0.70, MANOR_STAIR_TRANSITION_DEPTH, variation)
		add_manor_stair_bearing_pier(blueprint, landing_pier_id, Vector3(tower_center.x, 0.0, tower_center.z + run * 0.5), base_y + half_rise - 0.27, tower_span - 0.70, MANOR_STAIR_TRANSITION_DEPTH, variation)
		add_manor_stair_bearing_pier(blueprint, exit_pier_id, Vector3(tower_center.x, 0.0, tower_center.z - run * 0.5), base_y + floor_height - 0.17, tower_span - 0.70, MANOR_STAIR_TRANSITION_DEPTH, variation)
		add_part(blueprint, base_underframe_id, "beam", "timber_beam", Vector3(tower_center.x, base_y - 0.18, tower_center.z - run * 0.5), Vector3(tower_span - 0.70, 0.18, MANOR_STAIR_TRANSITION_DEPTH), {"variation": variation - 0.022, "semantic": "manor_stair_base_bearing_cap", "physicalAssemblyRole": "landing_underframe", "physicalRequiredSeatPartIds": [base_pier_id], "physicalRequiredSeatFacts": [{"seatId": base_pier_id, "loadDirection": "world_down", "localPatchCenter": Vector3(0.0, -0.09, 0.0), "localPatchHalfExtents": Vector2((tower_span - 0.70) * 0.35, 0.10), "seatFace": "max_y"}]})
		for tread_index in range(tread_count):
			var up_z := tower_center.z - run * 0.5 + tread_run * (float(tread_index) + 0.5)
			var up_y := base_y + tread_rise * float(tread_index + 1) - 0.055
			add_part(blueprint, "manor_stair_up_tread_%d_%d" % [level, tread_index], "stair_tread", "timber_board", Vector3(left_x, up_y, up_z), Vector3(ramp_width, 0.11, tread_run + 0.025), {"collision": false, "variation": variation, "semantic": "manor_stair_tread"})
		var landing_center := Vector3(tower_center.x, base_y + half_rise, tower_center.z + run * 0.5)
		add_part(blueprint, "manor_stair_landing_%d" % level, "floor", "timber_board", landing_center, Vector3(tower_span - 0.70, 0.20, MANOR_STAIR_TRANSITION_DEPTH), {"variation": variation, "semantic": "manor_stair_landing"})
		add_part(blueprint, landing_underframe_id, "beam", "timber_beam", Vector3(landing_center.x, landing_center.y - 0.18, landing_center.z), Vector3(tower_span - 0.70, 0.18, MANOR_STAIR_TRANSITION_DEPTH), {"variation": variation - 0.022, "semantic": "manor_stair_landing_underframe", "physicalAssemblyRole": "landing_underframe", "physicalRequiredSeatPartIds": [landing_pier_id], "physicalRequiredSeatFacts": [{"seatId": landing_pier_id, "loadDirection": "world_down", "localPatchCenter": Vector3(0.0, -0.09, 0.0), "localPatchHalfExtents": Vector2((tower_span - 0.70) * 0.35, 0.10), "seatFace": "max_y"}]})
		for tread_index in range(tread_count):
			var return_z := tower_center.z + run * 0.5 - tread_run * (float(tread_index) + 0.5)
			var return_y := base_y + half_rise + tread_rise * float(tread_index + 1) - 0.055
			add_part(blueprint, "manor_stair_return_tread_%d_%d" % [level, tread_index], "stair_tread", "timber_board", Vector3(right_x, return_y, return_z), Vector3(ramp_width, 0.11, tread_run + 0.025), {"collision": false, "variation": variation, "semantic": "manor_stair_tread"})
		var exit_center := Vector3(tower_center.x, base_y + floor_height + 0.10, tower_center.z - run * 0.5)
		add_part(blueprint, "manor_stair_exit_%d" % level, "floor", "timber_board", exit_center, Vector3(tower_span - 0.70, 0.20, MANOR_STAIR_TRANSITION_DEPTH), {"variation": variation, "semantic": "manor_stair_exit"})
		add_part(blueprint, exit_underframe_id, "beam", "timber_beam", Vector3(exit_center.x, exit_center.y - 0.18, exit_center.z), Vector3(tower_span - 0.70, 0.18, MANOR_STAIR_TRANSITION_DEPTH), {"variation": variation - 0.022, "semantic": "manor_stair_exit_underframe", "physicalAssemblyRole": "landing_underframe", "physicalRequiredSeatPartIds": [exit_pier_id], "physicalRequiredSeatFacts": [{"seatId": exit_pier_id, "loadDirection": "world_down", "localPatchCenter": Vector3(0.0, -0.09, 0.0), "localPatchHalfExtents": Vector2((tower_span - 0.70) * 0.35, 0.10), "seatFace": "max_y"}]})
		var up_lower_shoe_id := "manor_stair_up_lower_shoe_%d" % level
		var up_upper_shoe_id := "manor_stair_up_upper_shoe_%d" % level
		var up_assembly_id := "manor_stair_up_%d" % level
		var up_lower_shoe_center := Vector3(left_x, base_y - 0.09 + shoe_thickness * 0.5, tower_center.z - run * 0.5)
		var up_upper_shoe_center := Vector3(left_x, landing_center.y - 0.09 + shoe_thickness * 0.5, tower_center.z + run * 0.5)
		var up_geometry := manor_stair_housed_geometry(up_lower_shoe_center, up_upper_shoe_center, ramp_width, 0.18)
		var up_start_support_id := "manor_stair_tower_floor" if level == 0 else "manor_stair_exit_%d" % (level - 1)
		add_manor_stair_shoe(blueprint, up_lower_shoe_id, up_lower_shoe_center, ramp_width, shoe_thickness, base_underframe_id, up_assembly_id, variation)
		add_manor_stair_shoe(blueprint, up_upper_shoe_id, up_upper_shoe_center, ramp_width, shoe_thickness, landing_underframe_id, up_assembly_id, variation)
		add_part(blueprint, "manor_stair_up_carriage_%d" % level, "ramp", "timber_board", up_geometry.get("carriageCenter", Vector3.ZERO) as Vector3, Vector3(ramp_width, 0.18, float(up_geometry.get("length", run))), {"rotation": up_geometry.get("rotation", Vector3.ZERO) as Vector3, "variation": variation - 0.025, "semantic": "manor_visible_stair_carriage", "navigationStartSupportPartId": up_start_support_id, "navigationEndSupportPartId": "manor_stair_landing_%d" % level, "physicalIntent": "structural_mass", "physicalAssemblyRole": "stair_sloped_span", "physicalStairAssemblyId": up_assembly_id, "physicalRequiredAssemblyBearingBlockIds": [up_lower_shoe_id, up_upper_shoe_id], "physicalRequiredSeatPartIds": [up_lower_shoe_id, up_upper_shoe_id], "physicalRequiredSeatFacts": [manor_stair_housed_joint_fact(up_lower_shoe_id, -1.0, up_geometry), manor_stair_housed_joint_fact(up_upper_shoe_id, 1.0, up_geometry)]})
		var return_lower_shoe_id := "manor_stair_return_lower_shoe_%d" % level
		var return_upper_shoe_id := "manor_stair_return_upper_shoe_%d" % level
		var return_assembly_id := "manor_stair_return_%d" % level
		var return_lower_shoe_center := Vector3(right_x, landing_center.y - 0.09 + shoe_thickness * 0.5, tower_center.z + run * 0.5)
		var return_upper_shoe_center := Vector3(right_x, exit_center.y - 0.09 + shoe_thickness * 0.5, tower_center.z - run * 0.5)
		var return_geometry := manor_stair_housed_geometry(return_lower_shoe_center, return_upper_shoe_center, ramp_width, 0.18)
		add_manor_stair_shoe(blueprint, return_lower_shoe_id, return_lower_shoe_center, ramp_width, shoe_thickness, landing_underframe_id, return_assembly_id, variation)
		add_manor_stair_shoe(blueprint, return_upper_shoe_id, return_upper_shoe_center, ramp_width, shoe_thickness, exit_underframe_id, return_assembly_id, variation)
		add_part(blueprint, "manor_stair_return_carriage_%d" % level, "ramp", "timber_board", return_geometry.get("carriageCenter", Vector3.ZERO) as Vector3, Vector3(ramp_width, 0.18, float(return_geometry.get("length", run))), {"rotation": return_geometry.get("rotation", Vector3.ZERO) as Vector3, "variation": variation - 0.025, "semantic": "manor_visible_stair_carriage", "navigationStartSupportPartId": "manor_stair_landing_%d" % level, "navigationEndSupportPartId": "manor_stair_exit_%d" % level, "physicalIntent": "structural_mass", "physicalAssemblyRole": "stair_sloped_span", "physicalStairAssemblyId": return_assembly_id, "physicalRequiredAssemblyBearingBlockIds": [return_lower_shoe_id, return_upper_shoe_id], "physicalRequiredSeatPartIds": [return_lower_shoe_id, return_upper_shoe_id], "physicalRequiredSeatFacts": [manor_stair_housed_joint_fact(return_lower_shoe_id, -1.0, return_geometry), manor_stair_housed_joint_fact(return_upper_shoe_id, 1.0, return_geometry)]})


static func add_manor_stair_bearing_pier(blueprint, part_id: String, center: Vector3, top_y: float, width: float, depth: float, variation: float) -> void:
	var height := maxf(0.20, top_y)
	add_part(blueprint, part_id, "foundation", "stone_foundation", Vector3(center.x, height * 0.5, center.z), Vector3(width, height, depth), {"variation": variation - 0.028, "semantic": "manor_stair_bearing_pier", "physicalAssemblyRole": "stair_bearing_pier"})


static func add_manor_stair_shoe(blueprint, part_id: String, center: Vector3, width: float, thickness: float, underframe_id: String, assembly_id: String, variation: float) -> void:
	add_part(blueprint, part_id, "beam", "timber_beam", center, Vector3(width + 0.08, thickness, 0.56), {"variation": variation - 0.018, "semantic": "manor_stair_carriage_shoe", "physicalAssemblyRole": "stair_carriage_bearing_block", "physicalStairAssemblyId": assembly_id, "physicalRequiredSeatPartIds": [underframe_id], "physicalRequiredSeatFacts": [{"seatId": underframe_id, "loadDirection": "world_down", "localPatchCenter": Vector3(0.0, -thickness * 0.5, 0.0), "localPatchHalfExtents": Vector2(width * 0.35, 0.10), "seatFace": "max_y"}]})


static func manor_stair_housed_geometry(lower_shoe_center: Vector3, upper_shoe_center: Vector3, width: float, thickness: float) -> Dictionary:
	const HOUSED_EMBED_CENTER := 0.14
	const HOUSED_VERTICAL_CENTER := 0.04
	var tangent := (upper_shoe_center - lower_shoe_center).normalized()
	var normal := Vector3(0.0, tangent.z, -tangent.y).normalized()
	if normal.y < 0.0:
		normal = -normal
	var lateral := normal.cross(tangent).normalized()
	var basis := Basis(lateral, normal, tangent)
	var lower_endpoint := lower_shoe_center - tangent * HOUSED_EMBED_CENTER - normal * HOUSED_VERTICAL_CENTER
	var upper_endpoint := upper_shoe_center + tangent * HOUSED_EMBED_CENTER - normal * HOUSED_VERTICAL_CENTER
	return {"carriageCenter": (lower_endpoint + upper_endpoint) * 0.5 + normal * (thickness * 0.5), "length": lower_endpoint.distance_to(upper_endpoint), "rotation": basis.get_euler(), "width": width, "housedEmbedCenter": HOUSED_EMBED_CENTER, "housedOverlapHalfExtents": Vector3(width * 0.25, 0.021, 0.061)}


static func manor_stair_housed_joint_fact(shoe_id: String, end_sign: float, geometry: Dictionary) -> Dictionary:
	var length := float(geometry.get("length", 0.0))
	var embed_center := float(geometry.get("housedEmbedCenter", 0.14))
	return {"seatId": shoe_id, "contactMode": "housed_overlap", "localOverlapCenter": Vector3(0.0, -0.05, end_sign * (length * 0.5 - embed_center)), "localOverlapHalfExtents": geometry.get("housedOverlapHalfExtents", Vector3(0.16, 0.021, 0.061)), "minimumLongitudinalEmbedment": 0.12, "minimumVerticalOverlap": 0.04}


static func add_manor_tower_bridge(blueprint, part_id: String, tower_center: Vector3, tower_span: float, source_center: Vector3, source_width: float, exit_z: float, passage_width: float, floor_y: float, variation: float) -> void:
	var tower_left := tower_center.x - tower_span * 0.5
	var source_right := source_center.x + source_width * 0.5
	# Components can overlap slightly at upper floors, while the lower hall has
	# a deliberate reveal.  A minimum bridge width keeps both cases continuous
	# without a special collision-only patch.
	var bridge_width := maxf(MANOR_TOWER_PASSAGE_CROSSING, absf(tower_left - source_right) + 0.44)
	var bridge_center_x := (tower_left + source_right) * 0.5
	# The connector is an exposed framed bridge, not a floating collision slab.
	# Its broad soffit is visible from the lower volume and carries the entire
	# published deck without changing the clear walkable width above it.
	var underframe_id := "%s_underframe" % part_id
	add_part(blueprint, underframe_id, "beam", "timber_beam", Vector3(bridge_center_x, floor_y - 0.10, exit_z), Vector3(bridge_width, 0.20, passage_width), {"variation": variation - 0.024, "semantic": "manor_tower_bridge_underframe", "physicalIntent": "structural_mass", "allowEnclosingStructuralSupport": true})
	var bridge: BuildingPart = add_part(blueprint, part_id, "floor", "timber_board", Vector3(bridge_center_x, floor_y + 0.10, exit_z), Vector3(bridge_width, 0.20, passage_width), {"variation": variation, "semantic": "manor_tower_bridge", "physicalAssemblyRole": "floor_diaphragm"})
	bridge.recipe["physicalRequiredSupportPartIds"] = [underframe_id]


static func add_manor_wall_with_passage(blueprint, prefix: String, material: String, center: Vector3, size: Vector3, passage_z: float, passage_width: float, bottom_y: float, variation: float) -> void:
	# Attached volumes must exchange real interior space. Split the shared wall
	# around a door-height opening instead of leaving two overlapping exterior
	# walls that look connected from outside yet create a dead end inside.
	var min_z := center.z - size.z * 0.5
	var max_z := center.z + size.z * 0.5
	var opening_min := clampf(passage_z - passage_width * 0.5, min_z + 0.24, max_z - 0.64)
	var opening_max := clampf(passage_z + passage_width * 0.5, opening_min + 0.60, max_z - 0.24)
	var opening_height := minf(2.48, size.y - 0.42)
	var opening_y := bottom_y + opening_height * 0.5
	var header_height := size.y - opening_height
	if opening_min - min_z > 0.02:
		add_wall(blueprint, "%s_near" % prefix, material, Vector3(center.x, opening_y, min_z + (opening_min - min_z) * 0.5), Vector3(size.x, opening_height, opening_min - min_z), variation)
	if max_z - opening_max > 0.02:
		add_wall(blueprint, "%s_far" % prefix, material, Vector3(center.x, opening_y, opening_max + (max_z - opening_max) * 0.5), Vector3(size.x, opening_height, max_z - opening_max), variation)
	add_wall(blueprint, "%s_header" % prefix, material, Vector3(center.x, bottom_y + opening_height + header_height * 0.5, center.z), Vector3(size.x, header_height, size.z), variation)


static func add_manor_tower_left_wall_with_storey_passages(blueprint, prefix: String, material: String, tower_center: Vector3, tower_span: float, bottom_y: float, tower_height: float, floor_height: float, floor_count: int, passage_z: float, passage_width: float, thickness: float, variation: float) -> void:
	# The normal side-passage helper represents a single room-height opening.
	# A tower needs the same opening repeated per generated level, with a header
	# closing each band before the next level begins.  The result is an actual
	# continuous exterior wall with deterministic circulation apertures.
	var min_z := tower_center.z - tower_span * 0.5
	var max_z := tower_center.z + tower_span * 0.5
	var opening_min := clampf(passage_z - passage_width * 0.5, min_z + 0.24, max_z - 0.64)
	var opening_max := clampf(passage_z + passage_width * 0.5, opening_min + 0.60, max_z - 0.24)
	var wall_x := tower_center.x - tower_span * 0.5
	var current_y := bottom_y
	var wall_top := bottom_y + tower_height
	for level in range(maxi(1, floor_count)):
		if current_y >= wall_top - 0.02:
			break
		var band_height := minf(floor_height, wall_top - current_y)
		var opening_height := minf(2.48, band_height - 0.30)
		var opening_center_y := current_y + opening_height * 0.5
		if opening_min - min_z > 0.02:
			add_wall(blueprint, "%s_near_%d" % [prefix, level], material, Vector3(wall_x, opening_center_y, min_z + (opening_min - min_z) * 0.5), Vector3(thickness, opening_height, opening_min - min_z), variation)
		if max_z - opening_max > 0.02:
			add_wall(blueprint, "%s_far_%d" % [prefix, level], material, Vector3(wall_x, opening_center_y, opening_max + (max_z - opening_max) * 0.5), Vector3(thickness, opening_height, max_z - opening_max), variation)
		var header_height := band_height - opening_height
		if header_height > 0.02:
			add_wall(blueprint, "%s_header_%d" % [prefix, level], material, Vector3(wall_x, current_y + opening_height + header_height * 0.5, tower_center.z), Vector3(thickness, header_height, tower_span), variation)
		current_y += band_height
	if wall_top - current_y > 0.02:
		add_wall(blueprint, "%s_crown" % prefix, material, Vector3(wall_x, current_y + (wall_top - current_y) * 0.5, tower_center.z), Vector3(thickness, wall_top - current_y, tower_span), variation)


static func add_manor_gabled_roof(blueprint, prefix: String, wall_material: String, beam_material: String, center: Vector3, width: float, depth: float, eave_y: float, rise: float, overhang: float, variation: float, eave_bearing_part_ids: Array, eave_bearing_patch_offsets: Array, align_eave_plates_to_bearers: bool) -> void:
	GabledRoofFrameBuilderScript.add_gabled_roof_frame(blueprint, {
		"prefix": prefix,
		"center": center,
		"width": width,
		"depth": depth,
		"eaveY": eave_y,
		"rise": rise,
		"overhang": overhang,
		"variation": variation,
		"wallMaterial": wall_material,
		"beamMaterial": beam_material,
		"roofSemantic": "manor_roof",
		"gableSemantic": "manor_roof_gable",
		"eaveBearingPartIds": eave_bearing_part_ids,
		"eaveBearingPatchOffsets": eave_bearing_patch_offsets,
		"alignEavePlatesToBearers": align_eave_plates_to_bearers,
		"gableIdStyle": "manor"
	})


static func add_manor_solar_corbels(blueprint, lower_center: Vector3, lower_width: float, lower_depth: float, solar_center: Vector3, solar_width: float, solar_depth: float, support_y: float, beam_material: String, variation: float) -> void:
	# The upper floor intentionally projects beyond the lower hall. Four ordinary
	# beam parts make that allometric hierarchy legible rather than leaving a
	# visually unsupported floating rectangle.
	var lower_bounds := AABB(Vector3(lower_center.x - lower_width * 0.5, 0.0, lower_center.z - lower_depth * 0.5), Vector3(lower_width, 1.0, lower_depth))
	var solar_bounds := AABB(Vector3(solar_center.x - solar_width * 0.5, 0.0, solar_center.z - solar_depth * 0.5), Vector3(solar_width, 1.0, solar_depth))
	for x in [solar_bounds.position.x + 0.26, solar_bounds.end.x - 0.26]:
		for z in [solar_bounds.position.z + 0.26, solar_bounds.end.z - 0.26]:
			if x < lower_bounds.position.x - 0.08 or x > lower_bounds.end.x + 0.08 or z < lower_bounds.position.z - 0.08 or z > lower_bounds.end.z + 0.08:
				var side_sign := -1.0 if x < solar_center.x else 1.0
				var depth_sign := -1.0 if z < solar_center.z else 1.0
				var ledger_id := "manor_solar_upper_left_floor_ledger" if side_sign < 0.0 else "manor_solar_upper_right_floor_ledger"
				# This is exposed joinery below the overhang, not a hidden collision
				# pillar.  It slightly enters the upper floor so its visible socket is
				# attached to a collision-backed perimeter ledger rather than to the
				# walkable floor surface itself.
				add_part(blueprint, "manor_solar_corbel_%d" % blueprint.parts.size(), "beam", beam_material, Vector3(float(x), support_y - 0.22, float(z)), Vector3(0.32, 0.48, 0.32), {"collision": false, "variation": variation, "semantic": "manor_solar_corbel", "physicalIntent": "facade_attachment", "physicalRequiredAnchorPartIds": [ledger_id], "physicalRequiredAnchorFacts": [{"anchorId": ledger_id, "contactMode": "attachment_socket", "localMountCenter": Vector3(side_sign * 0.14, 0.235, depth_sign * -0.155), "localMountHalfExtents": Vector3(0.012, 0.012, 0.012)}]})


static func add_manor_portico(blueprint, lower_center: Vector3, lower_width: float, lower_depth: float, foundation_height: float, floor_height: float, beam_material: String, variation: float) -> void:
	var front_z := lower_center.z - lower_depth * 0.5
	var portico_z := front_z - 1.08
	var height := minf(3.20, floor_height * 0.84)
	add_part(blueprint, "manor_portico_floor", "floor", "timber_board", Vector3(lower_center.x, foundation_height + 0.10, front_z - 0.72), Vector3(minf(4.80, lower_width * 0.48), 0.20, 1.58), {"variation": variation, "semantic": "manor_portico", "navigationRole": "walkable_support", "doorEgressFor": "manor_main_lower_entry_door"})
	var transition_size := Vector3(minf(4.46, lower_width * 0.44), 0.14, 1.36)
	var transition_rotation := Vector3(-atan2(foundation_height + 0.18, transition_size.z), 0.0, 0.0)
	var transition_basis := Basis.from_euler(transition_rotation)
	var transition_upper_end := transition_basis * Vector3(0.0, transition_size.y * 0.5, transition_size.z * 0.5)
	var portico_outer_edge_z := front_z - 1.51
	var transition_position := Vector3(lower_center.x, foundation_height + 0.20 - transition_upper_end.y, portico_outer_edge_z - transition_upper_end.z)
	add_part(blueprint, "manor_portico_transition", "ramp", "timber_board", transition_position, transition_size, {"rotation": transition_rotation, "variation": variation, "semantic": "entry_ramp", "navigationRole": "transition", "doorEgressFor": "manor_main_lower_entry_door"})
	var post_ids: Array[String] = []
	for side in [-1, 1]:
		var post_id := "manor_portico_post_%d" % side
		post_ids.append(post_id)
		var post_x := lower_center.x + float(side) * minf(1.86, lower_width * 0.20)
		add_part(blueprint, post_id, "beam", beam_material, Vector3(post_x, foundation_height + height * 0.5, portico_z), Vector3(0.36, height, 0.36), {"variation": variation, "semantic": "manor_portico"})
	var lintel_width := minf(4.60, lower_width * 0.52)
	var post_offset := minf(1.86, lower_width * 0.20)
	var lintel_seat_facts: Array[Dictionary] = []
	for side in [-1, 1]:
		lintel_seat_facts.append({"seatId": "manor_portico_post_%d" % side, "loadDirection": "world_down", "localPatchCenter": Vector3(float(side) * post_offset, -0.15, 0.0), "localPatchHalfExtents": Vector2(0.12, 0.12), "seatFace": "max_y"})
	add_part(blueprint, "manor_portico_lintel", "beam", beam_material, Vector3(lower_center.x, foundation_height + height + 0.15, portico_z), Vector3(lintel_width, 0.30, 0.42), {"variation": variation, "semantic": "manor_portico", "physicalRequiredSeatPartIds": post_ids, "physicalRequiredSeatFacts": lintel_seat_facts})
	add_part(blueprint, "manor_portico_roof", "roof", "roof_shingle", Vector3(lower_center.x, foundation_height + height + 0.28, front_z - 0.74), Vector3(minf(5.00, lower_width * 0.56), 0.18, 2.02), {"rotation": Vector3(deg_to_rad(-8.0), 0.0, 0.0), "variation": variation, "semantic": "manor_portico_roof", "physicalRequiredSupportPartIds": ["manor_portico_lintel"]})


static func build_town_hall(recipe: Dictionary):
	var seed := int(recipe.get("seed", 0))
	var style := normalized_style(String(recipe.get("style", "masonry")))
	var width := float(recipe.get("width", 17.0))
	var depth := float(recipe.get("depth", 12.0))
	var wall_height := float(recipe.get("wallHeight", 3.65))
	var wall_thickness := float(recipe.get("wallThickness", 0.34))
	var foundation_height := float(recipe.get("foundationHeight", 0.48))
	var roof_rise := float(recipe.get("roofRise", 2.65))
	var roof_overhang := float(recipe.get("roofOverhang", 0.58))
	var opening: Dictionary = recipe.get("openingPolicy", {}) as Dictionary
	var door_width := float(opening.get("entryWidth", 1.82))
	var door_height := float(opening.get("entryHeight", 2.62))
	var variation := float(recipe.get("materialVariation", 0.0))
	var front_z := -depth * 0.5
	var back_z := depth * 0.5
	var wall_material := "fired_brick" if style == "masonry" else "timber_board"
	var beam_material := "stone_foundation" if style == "masonry" else "timber_beam"
	var blueprint = BuildingBlueprintScript.new("landmark.town_hall.%s.%d" % [style, seed], seed, style)
	blueprint.set_recipe(recipe)

	var divider_z := snappedf(depth * 0.10, 0.20)
	var passage_width := 1.82
	var public_depth := divider_z - front_z
	var rear_depth := back_z - divider_z
	var rear_rooms := town_hall_rear_room_specs(width, String(recipe.get("townHallLayout", "standard")))
	var public_accesses: Array = [{"id": "civic_entry", "kind": "exterior_door", "position": Vector3(0.0, 0.70, front_z + 0.98), "size": Vector3(door_width + 0.72, 2.30, 1.96), "furnishingSize": Vector3(door_width + 2.40, 2.30, 3.20)}]
	var room_records: Array = [{
		"id": "public_hall",
		"role": "public_hall",
		"bounds": AABB(Vector3(-width * 0.5, 0.0, front_z), Vector3(width, wall_height, public_depth)),
		"wallMountInset": wall_thickness * 0.5,
		"accesses": public_accesses
	}]
	for rear_room in rear_rooms:
		var passage_id := String(rear_room.get("passageId", ""))
		var passage_x := float(rear_room.get("passageX", 0.0))
		var public_passage := {"id": passage_id, "kind": "interior_passage", "position": Vector3(passage_x, 0.70, divider_z), "size": Vector3(passage_width, 2.30, 1.62), "furnishingSize": Vector3(passage_width + 1.72, 2.30, 2.80), "crossingAxis": Vector3.BACK, "endpointSide": -1, "supportPartId": "civic_floor"}
		var rear_passage := public_passage.duplicate(true)
		rear_passage["endpointSide"] = 1
		public_accesses.append(public_passage)
		room_records.append({
			"id": String(rear_room.get("id", "rear_room")),
			"role": String(rear_room.get("role", "civic_store")),
			"bounds": AABB(Vector3(float(rear_room.get("minimumX", 0.0)), 0.0, divider_z), Vector3(float(rear_room.get("maximumX", 0.0)) - float(rear_room.get("minimumX", 0.0)), wall_height, rear_depth)),
			"wallMountInset": wall_thickness * 0.5,
			"accesses": [rear_passage]
		})
	blueprint.set_room_records(room_records)

	# Footing and floor establish one physical volume/visual source for the
	# whole civic building. The doorway splits the front footing rather than
	# hiding a blocked entrance with an overlaid door.
	var left_foundation_width := width * 0.5 - door_width * 0.5
	add_part(blueprint, "foundation_front_left", "foundation", "stone_foundation", Vector3((-width * 0.5 - door_width * 0.5) * 0.5, foundation_height * 0.5, front_z), Vector3(left_foundation_width, foundation_height, 0.66), {"variation": variation})
	add_part(blueprint, "foundation_front_right", "foundation", "stone_foundation", Vector3((width * 0.5 + door_width * 0.5) * 0.5, foundation_height * 0.5, front_z), Vector3(left_foundation_width, foundation_height, 0.66), {"variation": variation})
	add_part(blueprint, "foundation_back", "foundation", "stone_foundation", Vector3(0.0, foundation_height * 0.5, back_z), Vector3(width + 0.56, foundation_height, 0.66), {"variation": variation})
	add_part(blueprint, "foundation_left", "foundation", "stone_foundation", Vector3(-width * 0.5, foundation_height * 0.5, 0.0), Vector3(0.66, foundation_height, depth), {"variation": variation})
	add_part(blueprint, "foundation_right", "foundation", "stone_foundation", Vector3(width * 0.5, foundation_height * 0.5, 0.0), Vector3(0.66, foundation_height, depth), {"variation": variation})
	add_part(blueprint, "civic_floor", "floor", "timber_board", Vector3(0.0, foundation_height + 0.10, 0.0), Vector3(width - 0.28, 0.20, depth - 0.28), {"variation": variation, "boardAxis": "z", "semantic": "floor"})

	var front_segment_width := (width - door_width) * 0.5
	var front_left_center := -door_width * 0.5 - front_segment_width * 0.5
	var front_right_center := door_width * 0.5 + front_segment_width * 0.5
	var front_window_size := Vector3(minf(2.24, front_segment_width - 0.72), 1.30, wall_thickness + 0.06)
	var window_y := foundation_height + wall_height * 0.58
	add_wall_with_window(blueprint, "front_left", wall_material, Vector3(front_left_center, foundation_height + wall_height * 0.5, front_z), Vector3(front_segment_width, wall_height, wall_thickness), Vector3(front_left_center, window_y, front_z), front_window_size, variation)
	add_wall_with_window(blueprint, "front_right", wall_material, Vector3(front_right_center, foundation_height + wall_height * 0.5, front_z), Vector3(front_segment_width, wall_height, wall_thickness), Vector3(front_right_center, window_y, front_z), front_window_size, variation)
	add_part(blueprint, "front_door", "door", "painted_door", Vector3(0.0, foundation_height + door_height * 0.5, front_z - wall_thickness * 0.78), Vector3(door_width, door_height, 0.16), {"variation": variation, "semantic": "door", "landmarkRole": "civic_entry"})
	add_part(blueprint, "entry_ramp", "ramp", "timber_board", Vector3(0.0, 0.38, front_z - 0.82), Vector3(door_width * 1.10, 0.16, 1.70), {"rotation": Vector3(-atan2(foundation_height + 0.18, 1.70), 0.0, 0.0), "variation": variation, "semantic": "entry_ramp"})

	var side_window_size := Vector3(wall_thickness + 0.06, 1.30, minf(2.40, depth * 0.20))
	add_wall_with_window(blueprint, "left", wall_material, Vector3(-width * 0.5, foundation_height + wall_height * 0.5, 0.0), Vector3(wall_thickness, wall_height, depth), Vector3(-width * 0.5, window_y, -depth * 0.20), side_window_size, variation)
	add_wall_with_window(blueprint, "right", wall_material, Vector3(width * 0.5, foundation_height + wall_height * 0.5, 0.0), Vector3(wall_thickness, wall_height, depth), Vector3(width * 0.5, window_y, depth * 0.20), side_window_size, variation)
	add_wall_with_window(blueprint, "back", wall_material, Vector3(0.0, foundation_height + wall_height * 0.5, back_z), Vector3(width, wall_height, wall_thickness), Vector3(-width * 0.23, window_y, back_z), Vector3(2.10, 1.30, wall_thickness + 0.06), variation)

	# Rear-room count derives from the sampled footprint. Their passages are
	# actual gaps in the divider and their interior splits are real walls, not
	# metadata on a fixed three-room Town Hall.
	var divider_passage_height := 2.30
	var divider_passage_y := foundation_height + divider_passage_height * 0.5
	var divider_full_wall_y := foundation_height + wall_height * 0.5
	var divider_cursor := -width * 0.5
	for rear_room in rear_rooms:
		var gap_center := float(rear_room.get("passageX", 0.0))
		var gap_min := gap_center - passage_width * 0.5
		var gap_max := gap_center + passage_width * 0.5
		add_wall_x_segment(blueprint, "divider_lower_%02d" % blueprint.parts.size(), wall_material, divider_cursor, gap_min, divider_passage_y, divider_z, divider_passage_height, wall_thickness, variation)
		divider_cursor = gap_max
	add_wall_x_segment(blueprint, "divider_lower_%02d" % blueprint.parts.size(), wall_material, divider_cursor, width * 0.5, divider_passage_y, divider_z, divider_passage_height, wall_thickness, variation)
	var divider_header_height := wall_height - divider_passage_height
	add_wall(blueprint, "divider_header", wall_material, Vector3(0.0, foundation_height + divider_passage_height + divider_header_height * 0.5, divider_z), Vector3(width, divider_header_height, wall_thickness), variation)
	for rear_index in range(1, rear_rooms.size()):
		var split_x := float((rear_rooms[rear_index] as Dictionary).get("minimumX", 0.0))
		add_wall(blueprint, "rear_divider_%02d" % rear_index, wall_material, Vector3(split_x, divider_full_wall_y, (divider_z + back_z) * 0.5), Vector3(wall_thickness, wall_height, back_z - divider_z), variation)

	for corner in [Vector3(-width * 0.5, 0.0, front_z), Vector3(width * 0.5, 0.0, front_z), Vector3(-width * 0.5, 0.0, back_z), Vector3(width * 0.5, 0.0, back_z)]:
		add_part(blueprint, "frame_%d" % blueprint.parts.size(), "beam", beam_material, corner + Vector3(0.0, foundation_height + wall_height * 0.5, 0.0), Vector3(0.42, wall_height + 0.42, 0.42), {"variation": variation, "semantic": "civic_frame"})
	add_part(blueprint, "front_beam", "beam", beam_material, Vector3(0.0, foundation_height + wall_height, front_z), Vector3(width + 0.36, 0.34, 0.34), {"variation": variation, "semantic": "civic_frame"})
	add_part(blueprint, "back_beam", "beam", beam_material, Vector3(0.0, foundation_height + wall_height, back_z), Vector3(width + 0.36, 0.34, 0.34), {"variation": variation, "semantic": "civic_frame"})

	add_window(blueprint, "front_left_window", Vector3(front_left_center, window_y, front_z), front_window_size, variation)
	add_window(blueprint, "front_right_window", Vector3(front_right_center, window_y, front_z), front_window_size, variation)
	add_window(blueprint, "left_window", Vector3(-width * 0.5, window_y, -depth * 0.20), side_window_size, variation)
	add_window(blueprint, "right_window", Vector3(width * 0.5, window_y, depth * 0.20), side_window_size, variation)
	add_window(blueprint, "back_window", Vector3(-width * 0.23, window_y, back_z), Vector3(2.10, 1.30, wall_thickness + 0.06), variation)

	GabledRoofFrameBuilderScript.add_gabled_roof_frame(blueprint, {
		"prefix": "roof",
		"center": Vector3.ZERO,
		"width": width,
		"depth": depth,
		"eaveY": foundation_height + wall_height,
		"rise": roof_rise,
		"overhang": roof_overhang,
		"variation": variation,
		"wallMaterial": wall_material,
		"beamMaterial": beam_material,
		"roofSemantic": "civic_roof",
		"gableSemantic": "civic_roof_gable",
		"eaveBearingPartIds": ["left_header", "right_header"],
		"eaveBearingPatchOffsets": [0.0, 0.0],
		"alignEavePlatesToBearers": true,
		"gableIdStyle": "manor"
	})
	# The square-facing facade is a structural hierarchy: public door, covered
	# threshold, then a raised civic register/clock. It is generated from the
	# same footprint and material choices, rather than being a per-scene decal.
	var facade_register_height := maxf(2.40, roof_rise * 0.72)
	var facade_register_y := foundation_height + door_height + 0.30 + facade_register_height * 0.5
	add_part(blueprint, "civic_facade_register", "wall", wall_material, Vector3(0.0, facade_register_y, front_z + wall_thickness * 0.32), Vector3(5.20, facade_register_height, wall_thickness + 0.12), {"variation": variation, "semantic": "civic_facade_register"})
	for facade_x in [-2.40, 2.40]:
		add_part(blueprint, "civic_facade_pilaster_%d" % blueprint.parts.size(), "beam", beam_material, Vector3(facade_x, facade_register_y, front_z - wall_thickness * 0.42), Vector3(0.40, facade_register_height + 0.44, 0.42), {"variation": variation, "semantic": "civic_facade_pilaster"})
	add_part(blueprint, "civic_facade_cornice", "beam", beam_material, Vector3(0.0, facade_register_y + facade_register_height * 0.5 + 0.12, front_z - wall_thickness * 0.36), Vector3(5.56, 0.30, 0.42), {"variation": variation, "semantic": "civic_facade_cornice"})
	add_part(blueprint, "civic_clock_face", "sign", "linen", Vector3(0.0, facade_register_y, front_z - wall_thickness * 0.76), Vector3(1.10, 1.10, 0.10), {"variation": variation, "collision": false, "semantic": "civic_clock_face"})
	for banner_x in [-width * 0.28, width * 0.28]:
		add_part(blueprint, "civic_banner_%d" % blueprint.parts.size(), "sign", "painted_decor", Vector3(banner_x, foundation_height + wall_height * 0.57, front_z - wall_thickness * 0.70), Vector3(0.72, 1.68, 0.08), {"variation": variation, "collision": false, "semantic": "civic_banner"})
	# A town hall needs a civic silhouette rather than a scaled cottage. The
	# belfry remains assembled from normal structural parts, so it can share
	# the same material, collision and later persistence authority as every
	# other generated building element.
	var belfry_base_y := foundation_height + wall_height + roof_rise + 0.10
	var belfry_height := 3.10
	var belfry_span := 3.80
	for corner_x in [-belfry_span * 0.5 + 0.26, belfry_span * 0.5 - 0.26]:
		for corner_z in [-belfry_span * 0.5 + 0.26, belfry_span * 0.5 - 0.26]:
			add_part(blueprint, "civic_belfry_pier_%d" % blueprint.parts.size(), "beam", beam_material, Vector3(corner_x, belfry_base_y + belfry_height * 0.5, corner_z), Vector3(0.48, belfry_height, 0.48), {"variation": variation, "semantic": "civic_belfry_pier"})
	add_part(blueprint, "civic_belfry_crown_front", "beam", beam_material, Vector3(0.0, belfry_base_y + belfry_height, -belfry_span * 0.5), Vector3(belfry_span, 0.42, 0.42), {"variation": variation, "semantic": "civic_belfry_crown"})
	add_part(blueprint, "civic_belfry_crown_back", "beam", beam_material, Vector3(0.0, belfry_base_y + belfry_height, belfry_span * 0.5), Vector3(belfry_span, 0.42, 0.42), {"variation": variation, "semantic": "civic_belfry_crown"})
	add_part(blueprint, "civic_bell", "decor", "brass", Vector3(0.0, belfry_base_y + belfry_height * 0.56, 0.0), Vector3(0.92, 1.10, 0.92), {"variation": variation, "collision": false, "semantic": "civic_bell"})
	var belfry_roof_rise := 1.35
	var belfry_roof_angle := atan2(belfry_roof_rise, belfry_span * 0.5 + 0.20)
	var belfry_slope_length := sqrt(pow(belfry_span * 0.5 + 0.20, 2.0) + pow(belfry_roof_rise, 2.0))
	var belfry_roof_y := belfry_base_y + belfry_height + belfry_roof_rise * 0.5
	add_part(blueprint, "civic_belfry_roof_left", "roof", "roof_shingle", Vector3(-belfry_span * 0.25, belfry_roof_y, 0.0), Vector3(belfry_slope_length, 0.20, belfry_span + 0.32), {"rotation": Vector3(0.0, 0.0, belfry_roof_angle), "variation": variation, "semantic": "civic_belfry_roof"})
	add_part(blueprint, "civic_belfry_roof_right", "roof", "roof_shingle", Vector3(belfry_span * 0.25, belfry_roof_y, 0.0), Vector3(belfry_slope_length, 0.20, belfry_span + 0.32), {"rotation": Vector3(0.0, 0.0, -belfry_roof_angle), "variation": variation, "semantic": "civic_belfry_roof"})
	add_part(blueprint, "civic_belfry_ridge", "beam", beam_material, Vector3(0.0, belfry_base_y + belfry_height + belfry_roof_rise, 0.0), Vector3(0.32, 0.26, belfry_span + 0.36), {"variation": variation, "semantic": "civic_belfry_roof_ridge"})

	# The covered entry anchors the building to its square-facing approach and
	# makes the public door readable from distance without adding a facade-only
	# scene or a second collision representation.
	var portico_z := front_z - 1.24
	var portico_height := door_height + 0.40
	for portico_x in [-2.24, 2.24]:
		add_part(blueprint, "civic_portico_post_%d" % blueprint.parts.size(), "beam", beam_material, Vector3(portico_x, foundation_height + portico_height * 0.5, portico_z), Vector3(0.44, portico_height, 0.44), {"variation": variation, "semantic": "civic_portico"})
	add_part(blueprint, "civic_portico_lintel", "beam", beam_material, Vector3(0.0, foundation_height + portico_height, portico_z), Vector3(5.10, 0.36, 0.46), {"variation": variation, "semantic": "civic_portico"})
	add_part(blueprint, "civic_portico_roof", "roof", "roof_shingle", Vector3(0.0, foundation_height + portico_height + 0.30, front_z - 0.96), Vector3(5.60, 0.18, 2.10), {"rotation": Vector3(deg_to_rad(-8.0), 0.0, 0.0), "variation": variation, "semantic": "civic_portico_roof"})
	add_part(blueprint, "civic_sign", "sign", "painted_decor", Vector3(0.0, foundation_height + wall_height * 0.72, front_z - wall_thickness * 0.66), Vector3(2.80, 0.66, 0.08), {"variation": variation, "collision": false, "semantic": "civic_sign"})
	return blueprint


static func town_hall_rear_room_specs(width: float, layout: String) -> Array:
	var half_width := width * 0.5
	match layout.strip_edges().to_lower():
		"compact":
			return [{
				"id": "notice_archive", "role": "notice_archive",
				"minimumX": -half_width, "maximumX": half_width,
				"passageId": "archive_passage", "passageX": 0.0
			}]
		"expanded":
			var left_split := -width / 6.0
			var right_split := width / 6.0
			return [
				{"id": "notice_archive", "role": "notice_archive", "minimumX": -half_width, "maximumX": left_split, "passageId": "archive_passage", "passageX": -width / 3.0},
				{"id": "steward_office", "role": "steward_office", "minimumX": left_split, "maximumX": right_split, "passageId": "office_passage", "passageX": 0.0},
				{"id": "civic_store", "role": "civic_store", "minimumX": right_split, "maximumX": half_width, "passageId": "store_passage", "passageX": width / 3.0}
			]
		_:
			return [
				{"id": "notice_archive", "role": "notice_archive", "minimumX": -half_width, "maximumX": 0.0, "passageId": "archive_passage", "passageX": -width * 0.25},
				{"id": "steward_office", "role": "steward_office", "minimumX": 0.0, "maximumX": half_width, "passageId": "office_passage", "passageX": width * 0.25}
			]


static func build_family_envelope(recipe: Dictionary):
	# Other families are intentionally represented by the same recipe/part
	# authority before their specialised topology PoCs are implemented. This
	# prevents an interim parallel visual architecture.
	var seed := int(recipe.get("seed", 0))
	var family := String(recipe.get("family", "cottage"))
	var style := normalized_style(String(recipe.get("style", "timber")))
	var width := float(recipe.get("width", 10.0))
	var depth := float(recipe.get("depth", 8.0))
	var wall_height := float(recipe.get("wallHeight", 3.5))
	var variation := float(recipe.get("materialVariation", 0.0))
	var wall_material := "fired_brick" if style == "masonry" else "timber_board"
	var blueprint = BuildingBlueprintScript.new("landmark.%s.%s.%d" % [family, style, seed], seed, style)
	blueprint.set_recipe(recipe)
	blueprint.set_room_records([{"id": "envelope", "role": "future_%s" % family, "bounds": AABB(Vector3(-width * 0.5, 0.0, -depth * 0.5), Vector3(width, wall_height, depth)), "wallMountInset": 0.14, "accesses": []}])
	add_part(blueprint, "foundation", "foundation", "stone_foundation", Vector3(0.0, 0.24, 0.0), Vector3(width + 0.50, 0.48, depth + 0.50), {"variation": variation})
	add_part(blueprint, "floor", "floor", "timber_board", Vector3(0.0, 0.58, 0.0), Vector3(width - 0.22, 0.20, depth - 0.22), {"variation": variation})
	add_wall(blueprint, "front", wall_material, Vector3(0.0, 0.48 + wall_height * 0.5, -depth * 0.5), Vector3(width, wall_height, 0.30), variation)
	add_wall(blueprint, "back", wall_material, Vector3(0.0, 0.48 + wall_height * 0.5, depth * 0.5), Vector3(width, wall_height, 0.30), variation)
	add_wall(blueprint, "left", wall_material, Vector3(-width * 0.5, 0.48 + wall_height * 0.5, 0.0), Vector3(0.30, wall_height, depth), variation)
	add_wall(blueprint, "right", wall_material, Vector3(width * 0.5, 0.48 + wall_height * 0.5, 0.0), Vector3(0.30, wall_height, depth), variation)
	return blueprint


static func normalized_style(value: String) -> String:
	var style := value.strip_edges().to_lower()
	return style if style in ["timber", "masonry"] else "timber"


static func add_wall_x_segment(blueprint, part_id: String, material: String, minimum_x: float, maximum_x: float, y: float, z: float, height: float, thickness: float, variation: float) -> void:
	var segment_width := maximum_x - minimum_x
	if segment_width <= 0.02:
		return
	add_wall(blueprint, part_id, material, Vector3((minimum_x + maximum_x) * 0.5, y, z), Vector3(segment_width, height, thickness), variation)


static func add_gable_end_cap(blueprint, prefix: String, material: String, center_x: float, z: float, width: float, thickness: float, eave_y: float, roof_rise: float, variation: float) -> void:
	# A stepped triangular fill preserves the voxel construction language while
	# following the same eave-to-ridge roof equation used by the roof planes.
	# Each course is an ordinary wall part, therefore visual and collision
	# publication remain one authority.
	var strip_count := 12
	var strip_width := width / float(strip_count)
	for strip_index in range(strip_count):
		var local_x := -width * 0.5 + strip_width * (float(strip_index) + 0.5)
		var normalized_rise := maxf(0.0, 1.0 - absf(local_x) / (width * 0.5))
		var height := roof_rise * normalized_rise
		if height <= 0.06:
			continue
		add_wall(blueprint, "%s_%02d" % [prefix, strip_index], material, Vector3(center_x + local_x, eave_y + height * 0.5, z), Vector3(strip_width + 0.025, height, thickness + 0.02), variation)


static func add_manor_wall_with_window(blueprint, prefix: String, material: String, center: Vector3, size: Vector3, window_center: Vector3, window_size: Vector3, variation: float) -> void:
	# The opening and its pane are one building rule. Keeping both calls together
	# prevents a valid cut-out from silently publishing as a dark void.
	add_wall_with_window(blueprint, prefix, material, center, size, window_center, window_size, variation)
	add_window(blueprint, "%s_window" % prefix, window_center, window_size, variation)


static func add_wall(blueprint, part_id: String, material: String, center: Vector3, size: Vector3, variation: float) -> void:
	add_part(blueprint, part_id, "wall", material, center, size, {"variation": variation, "semantic": "wall"})


static func add_wall_with_window(blueprint, prefix: String, material: String, center: Vector3, size: Vector3, window_center: Vector3, window_size: Vector3, variation: float) -> void:
	var wall_bottom := center.y - size.y * 0.5
	var wall_top := center.y + size.y * 0.5
	var opening_bottom := window_center.y - window_size.y * 0.5
	var opening_top := window_center.y + window_size.y * 0.5
	if opening_bottom <= wall_bottom or opening_top >= wall_top:
		add_wall(blueprint, prefix, material, center, size, variation)
		return
	var sill_height := opening_bottom - wall_bottom
	var header_height := wall_top - opening_top
	add_wall(blueprint, "%s_sill" % prefix, material, Vector3(center.x, wall_bottom + sill_height * 0.5, center.z), Vector3(size.x, sill_height, size.z), variation)
	add_wall(blueprint, "%s_header" % prefix, material, Vector3(center.x, opening_top + header_height * 0.5, center.z), Vector3(size.x, header_height, size.z), variation)
	if size.x >= size.z:
		var wall_min := center.x - size.x * 0.5
		var wall_max := center.x + size.x * 0.5
		var opening_min := window_center.x - window_size.x * 0.5
		var opening_max := window_center.x + window_size.x * 0.5
		add_wall_x_segment(blueprint, "%s_jamb_left" % prefix, material, wall_min, opening_min, window_center.y, center.z, window_size.y, size.z, variation)
		add_wall_x_segment(blueprint, "%s_jamb_right" % prefix, material, opening_max, wall_max, window_center.y, center.z, window_size.y, size.z, variation)
	else:
		var wall_min := center.z - size.z * 0.5
		var wall_max := center.z + size.z * 0.5
		var opening_min := window_center.z - window_size.z * 0.5
		var opening_max := window_center.z + window_size.z * 0.5
		var near_width := opening_min - wall_min
		var far_width := wall_max - opening_max
		if near_width > 0.02:
			add_wall(blueprint, "%s_jamb_near" % prefix, material, Vector3(center.x, window_center.y, wall_min + near_width * 0.5), Vector3(size.x, window_size.y, near_width), variation)
		if far_width > 0.02:
			add_wall(blueprint, "%s_jamb_far" % prefix, material, Vector3(center.x, window_center.y, opening_max + far_width * 0.5), Vector3(size.x, window_size.y, far_width), variation)


static func add_window(blueprint, part_id: String, center: Vector3, size: Vector3, variation: float) -> void:
	add_part(blueprint, part_id, "window", "window_glass", center, size, {"variation": variation, "collision": true, "semantic": "window"})


static func add_part(blueprint, part_id: String, kind: String, material: String, position: Vector3, size: Vector3, options: Dictionary = {}) -> BuildingPart:
	return blueprint.add_part({
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
