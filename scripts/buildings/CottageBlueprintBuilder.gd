extends RefCounted
class_name CottageBlueprintBuilder

## Converts a deterministic cottage recipe into the common BuildingBlueprint
## contract. Runtime cottages and visual PoCs therefore exercise identical
## geometry, room/access records, furnishing inputs, collision and materials.

const BuildingBlueprintScript := preload("res://scripts/buildings/BuildingBlueprint.gd")
const CottageRecipeSamplerScript := preload("res://scripts/buildings/CottageRecipeSampler.gd")


static func build(seed: int, requested_style := "timber"):
	return build_from_recipe(CottageRecipeSamplerScript.sample(seed, requested_style))


static func build_from_recipe(raw_recipe: Dictionary):
	var recipe := raw_recipe.duplicate(true)
	var seed := int(recipe.get("seed", 0))
	var style := String(recipe.get("style", "timber")).strip_edges().to_lower()
	if style not in ["timber", "masonry"]:
		style = "timber"
	var width := float(recipe.get("width", 8.8))
	var depth := float(recipe.get("depth", 6.6))
	var wall_height := float(recipe.get("wallHeight", 3.45))
	var wall_thickness := float(recipe.get("wallThickness", 0.26))
	var foundation_height := float(recipe.get("foundationHeight", 0.48))
	var roof_rise := float(recipe.get("roofRise", 2.35))
	var roof_overhang := float(recipe.get("roofOverhang", 0.48))
	var door_width := float(recipe.get("doorWidth", 1.34))
	var door_height := float(recipe.get("doorHeight", 2.36))
	var door_x := float(recipe.get("doorX", -width * 0.22))
	var divider_x := float(recipe.get("dividerX", 0.0))
	var divider_gap := float(recipe.get("dividerGap", 1.08))
	var window_height := float(recipe.get("windowHeight", 1.18))
	var window_center_y := float(recipe.get("windowCenterY", foundation_height + 2.08))
	var front_window_width := float(recipe.get("frontWindowWidth", 1.42))
	var side_window_length := float(recipe.get("sideWindowLength", 1.46))
	var front_z := -depth * 0.5
	var front_window_center := Vector3(float(recipe.get("frontWindowX", width * 0.23)), window_center_y, front_z)
	var front_window_size := Vector3(front_window_width, window_height, wall_thickness + 0.06)
	var left_window_center := Vector3(-width * 0.5, window_center_y, float(recipe.get("leftWindowZ", -0.72)))
	var left_window_size := Vector3(wall_thickness + 0.06, window_height, side_window_length)
	var right_window_center := Vector3(width * 0.5, window_center_y, float(recipe.get("rightWindowZ", 1.10)))
	var right_window_size := Vector3(wall_thickness + 0.06, window_height, side_window_length)
	var variation := float(recipe.get("materialVariation", 0.0))
	var wall_material := "timber_board" if style == "timber" else "fired_brick"
	var beam_material := "timber_beam" if style == "timber" else "stone_foundation"
	var blueprint = BuildingBlueprintScript.new("cottage.recipe.%s.%d" % [style, seed], seed, style)
	blueprint.set_recipe(recipe)

	# The two rooms and their circulation lanes are authored as blueprint facts.
	# Furnishing grammars consume these records; they never guess from visuals.
	var hearth_width := divider_x + width * 0.5
	var sleeping_width := width * 0.5 - divider_x
	blueprint.set_room_records([
		{
			"id": "hearth_room",
			"bounds": AABB(Vector3(-width * 0.5, 0.0, -depth * 0.5), Vector3(hearth_width, wall_height, depth)),
			# Room bounds run through the wall centres. Consumers that mount an
			# object on a wall use this to find the actual interior wall surface.
			"wallMountInset": wall_thickness * 0.5,
			"accesses": [
				{"id": "front_entry", "kind": "exterior_door", "position": Vector3(door_x, 0.70, front_z + 0.93), "size": Vector3(door_width + 0.62, 2.10, 1.86)},
				{"id": "hearth_to_sleeping", "kind": "interior_passage", "position": Vector3(divider_x, 0.70, 0.0), "size": Vector3(1.50, 2.10, divider_gap + 0.34)}
			]
		},
		{
			"id": "sleeping_room",
			"bounds": AABB(Vector3(divider_x, 0.0, -depth * 0.5), Vector3(sleeping_width, wall_height, depth)),
			"wallMountInset": wall_thickness * 0.5,
			"accesses": [
				{"id": "hearth_to_sleeping", "kind": "interior_passage", "position": Vector3(divider_x, 0.70, 0.0), "size": Vector3(1.50, 2.10, divider_gap + 0.34)}
			]
		}
	])

	var left_door_edge := door_x - door_width * 0.5
	var right_door_edge := door_x + door_width * 0.5
	add_part(blueprint, "foundation_front_left", "foundation", "stone_foundation", Vector3((-width * 0.5 + left_door_edge) * 0.5, foundation_height * 0.5, front_z), Vector3(left_door_edge + width * 0.5, foundation_height, 0.58), {"variation": variation})
	add_part(blueprint, "foundation_front_right", "foundation", "stone_foundation", Vector3((right_door_edge + width * 0.5) * 0.5, foundation_height * 0.5, front_z), Vector3(width * 0.5 - right_door_edge, foundation_height, 0.58), {"variation": variation})
	add_part(blueprint, "foundation_back", "foundation", "stone_foundation", Vector3(0.0, foundation_height * 0.5, depth * 0.5), Vector3(width + 0.46, foundation_height, 0.58), {"variation": variation})
	add_part(blueprint, "foundation_left", "foundation", "stone_foundation", Vector3(-width * 0.5, foundation_height * 0.5, 0.0), Vector3(0.58, foundation_height, depth), {"variation": variation})
	add_part(blueprint, "foundation_right", "foundation", "stone_foundation", Vector3(width * 0.5, foundation_height * 0.5, 0.0), Vector3(0.58, foundation_height, depth), {"variation": variation})
	add_part(blueprint, "board_floor", "floor", "timber_board", Vector3(0.0, foundation_height + 0.10, 0.0), Vector3(width - 0.22, 0.20, depth - 0.22), {"variation": variation, "boardAxis": "z"})

	add_wall(blueprint, "front_left", wall_material, Vector3((-width * 0.5 + left_door_edge) * 0.5, foundation_height + wall_height * 0.5, front_z), Vector3(left_door_edge + width * 0.5, wall_height, wall_thickness), variation)
	add_wall_with_window(blueprint, "front_right", wall_material, Vector3((right_door_edge + width * 0.5) * 0.5, foundation_height + wall_height * 0.5, front_z), Vector3(width * 0.5 - right_door_edge, wall_height, wall_thickness), front_window_center, front_window_size, variation)
	add_wall(blueprint, "front_lintel", wall_material, Vector3(door_x, foundation_height + door_height + (wall_height - door_height) * 0.5, front_z), Vector3(door_width, wall_height - door_height, wall_thickness), variation)
	add_part(blueprint, "front_door", "door", "painted_door", Vector3(door_x, foundation_height + door_height * 0.5, front_z - wall_thickness * 0.76), Vector3(door_width, door_height, 0.16), {"variation": variation, "semantic": "door"})
	var entry_ramp_length := 1.45
	var entry_ramp_angle := -atan2(foundation_height + 0.18, entry_ramp_length)
	add_part(blueprint, "front_entry_ramp", "ramp", "timber_board", Vector3(door_x, 0.38, front_z - 0.70), Vector3(door_width * 0.94, 0.14, entry_ramp_length), {"rotation": Vector3(entry_ramp_angle, 0.0, 0.0), "variation": variation, "semantic": "entry_ramp"})

	add_wall(blueprint, "back", wall_material, Vector3(0.0, foundation_height + wall_height * 0.5, depth * 0.5), Vector3(width, wall_height, wall_thickness), variation)
	add_wall_with_window(blueprint, "left", wall_material, Vector3(-width * 0.5, foundation_height + wall_height * 0.5, 0.0), Vector3(wall_thickness, wall_height, depth), left_window_center, left_window_size, variation)
	add_wall_with_window(blueprint, "right", wall_material, Vector3(width * 0.5, foundation_height + wall_height * 0.5, 0.0), Vector3(wall_thickness, wall_height, depth), right_window_center, right_window_size, variation)
	add_gable_layers(blueprint, "front_gable", wall_material, -depth * 0.5, variation, width, roof_rise, foundation_height, wall_height, wall_thickness)
	add_gable_layers(blueprint, "back_gable", wall_material, depth * 0.5, variation, width, roof_rise, foundation_height, wall_height, wall_thickness)

	add_wall(blueprint, "divider_front", wall_material, Vector3(divider_x, foundation_height + wall_height * 0.5, (-depth * 0.5 - divider_gap * 0.5) * 0.5), Vector3(wall_thickness, wall_height, depth * 0.5 - divider_gap * 0.5), variation)
	add_wall(blueprint, "divider_back", wall_material, Vector3(divider_x, foundation_height + wall_height * 0.5, (divider_gap * 0.5 + depth * 0.5) * 0.5), Vector3(wall_thickness, wall_height, depth * 0.5 - divider_gap * 0.5), variation)
	add_wall(blueprint, "divider_lintel", wall_material, Vector3(divider_x, foundation_height + 2.18 + (wall_height - 2.18) * 0.5, 0.0), Vector3(wall_thickness, wall_height - 2.18, divider_gap), variation)

	for corner in [Vector3(-width * 0.5, 0.0, -depth * 0.5), Vector3(width * 0.5, 0.0, -depth * 0.5), Vector3(-width * 0.5, 0.0, depth * 0.5), Vector3(width * 0.5, 0.0, depth * 0.5)]:
		add_part(blueprint, "frame_%d" % blueprint.parts.size(), "beam", beam_material, corner + Vector3(0.0, foundation_height + wall_height * 0.5, 0.0), Vector3(0.36, wall_height + 0.34, 0.36), {"variation": variation})
	add_part(blueprint, "front_beam", "beam", "timber_beam", Vector3(0.0, foundation_height + wall_height, -depth * 0.5), Vector3(width + 0.30, 0.30, 0.30), {"variation": variation})
	add_part(blueprint, "back_beam", "beam", "timber_beam", Vector3(0.0, foundation_height + wall_height, depth * 0.5), Vector3(width + 0.30, 0.30, 0.30), {"variation": variation})

	add_window(blueprint, "entry_window", front_window_center, front_window_size, variation)
	add_window(blueprint, "left_window", left_window_center, left_window_size, variation)
	add_window(blueprint, "right_window", right_window_center, right_window_size, variation)

	var roof_angle := atan2(roof_rise, width * 0.5 + roof_overhang)
	var slope_length := sqrt(pow(width * 0.5 + roof_overhang, 2.0) + pow(roof_rise, 2.0))
	var roof_y := foundation_height + wall_height + roof_rise * 0.5
	add_part(blueprint, "roof_left", "roof", "roof_shingle", Vector3(-width * 0.25, roof_y, 0.0), Vector3(slope_length, 0.22, depth + roof_overhang * 2.0), {"rotation": Vector3(0.0, 0.0, roof_angle), "variation": variation, "semantic": "roof"})
	add_part(blueprint, "roof_right", "roof", "roof_shingle", Vector3(width * 0.25, roof_y, 0.0), Vector3(slope_length, 0.22, depth + roof_overhang * 2.0), {"rotation": Vector3(0.0, 0.0, -roof_angle), "variation": variation, "semantic": "roof"})
	add_part(blueprint, "ridge", "beam", "timber_beam", Vector3(0.0, foundation_height + wall_height + roof_rise, 0.0), Vector3(0.32, 0.26, depth + roof_overhang * 2.0 + 0.06), {"variation": variation, "semantic": "roof_ridge"})
	add_part(blueprint, "chimney", "chimney", "fired_brick", Vector3(width * 0.18, foundation_height + wall_height + roof_rise * 0.66, depth * 0.16), Vector3(0.72, 2.20, 0.72), {"variation": variation})
	return blueprint


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
		var left_width := opening_min - wall_min
		var right_width := wall_max - opening_max
		if left_width > 0.0:
			add_wall(blueprint, "%s_jamb_left" % prefix, material, Vector3(wall_min + left_width * 0.5, window_center.y, center.z), Vector3(left_width, window_size.y, size.z), variation)
		if right_width > 0.0:
			add_wall(blueprint, "%s_jamb_right" % prefix, material, Vector3(opening_max + right_width * 0.5, window_center.y, center.z), Vector3(right_width, window_size.y, size.z), variation)
	else:
		var wall_min := center.z - size.z * 0.5
		var wall_max := center.z + size.z * 0.5
		var opening_min := window_center.z - window_size.z * 0.5
		var opening_max := window_center.z + window_size.z * 0.5
		var near_width := opening_min - wall_min
		var far_width := wall_max - opening_max
		if near_width > 0.0:
			add_wall(blueprint, "%s_jamb_near" % prefix, material, Vector3(center.x, window_center.y, wall_min + near_width * 0.5), Vector3(size.x, window_size.y, near_width), variation)
		if far_width > 0.0:
			add_wall(blueprint, "%s_jamb_far" % prefix, material, Vector3(center.x, window_center.y, opening_max + far_width * 0.5), Vector3(size.x, window_size.y, far_width), variation)


static func add_gable_layers(blueprint, prefix: String, material: String, z: float, variation: float, width: float, roof_rise: float, foundation_height: float, wall_height: float, wall_thickness: float) -> void:
	var layer_count := 5
	var layer_height := roof_rise / float(layer_count)
	for layer in range(layer_count):
		var midpoint := (float(layer) + 0.5) / float(layer_count)
		var layer_width := maxf(0.36, width * (1.0 - midpoint))
		add_wall(blueprint, "%s_%02d" % [prefix, layer], material, Vector3(0.0, foundation_height + wall_height + layer_height * (float(layer) + 0.5), z), Vector3(layer_width, layer_height, wall_thickness), variation)


static func add_window(blueprint, part_id: String, center: Vector3, size: Vector3, variation: float) -> void:
	add_part(blueprint, part_id, "window", "window_glass", center, size, {"variation": variation, "collision": true, "semantic": "window"})


static func add_part(blueprint, part_id: String, kind: String, material: String, position: Vector3, size: Vector3, options: Dictionary = {}) -> void:
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
