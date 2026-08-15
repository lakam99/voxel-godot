extends RefCounted
class_name CottageBlueprintBuilder

## Converts a deterministic cottage recipe into the common BuildingBlueprint
## contract. Runtime cottages and visual PoCs therefore exercise identical
## geometry, room/access records, furnishing inputs, collision and materials.

const BuildingBlueprintScript := preload("res://scripts/buildings/BuildingBlueprint.gd")
const CottageRecipeSamplerScript := preload("res://scripts/buildings/CottageRecipeSampler.gd")
const MIN_INTERIOR_PASSAGE_WIDTH := 1.72


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
	var divider_gap := maxf(float(recipe.get("dividerGap", 1.08)), MIN_INTERIOR_PASSAGE_WIDTH)
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
	var beam_material := "timber_beam"
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
	add_cottage_frame_lattice(blueprint, width, depth, wall_height, wall_thickness, foundation_height, door_x, door_width, front_window_center.x, front_window_width, variation)
	add_cottage_material_age(blueprint, style, width, depth, wall_height, foundation_height, door_x, front_window_center, variation)
	for brace_sign in [-1.0, 1.0]:
		add_part(blueprint, "front_knee_brace_%d" % int(brace_sign), "beam", "timber_beam", Vector3(brace_sign * width * 0.31, foundation_height + wall_height * 0.72, front_z - 0.03), Vector3(0.20, minf(2.35, wall_height * 0.72), 0.20), {"rotation": Vector3(0.0, 0.0, brace_sign * deg_to_rad(39.0)), "collision": false, "variation": variation + brace_sign * 0.015, "semantic": "cottage_frame_brace"})
	for log_index in range(7):
		var log_row := log_index / 4
		var log_column := log_index % 4
		add_part(blueprint, "front_firewood_%02d" % log_index, "beam", "timber_board", Vector3(width * 0.32 + float(log_column) * 0.18, 0.10 + float(log_row) * 0.14, front_z - 0.30), Vector3(0.14, 0.14, 0.72), {"rotation": Vector3(0.0, float(log_column - 2) * deg_to_rad(3.0), 0.0), "collision": false, "variation": variation + float(log_index) * 0.008, "semantic": "cottage_firewood"})

	add_window(blueprint, "entry_window", front_window_center, front_window_size, variation, "window_warm_glass")
	add_window(blueprint, "left_window", left_window_center, left_window_size, variation)
	add_window(blueprint, "right_window", right_window_center, right_window_size, variation, "window_warm_glass")

	var roof_angle := atan2(roof_rise, width * 0.5 + roof_overhang)
	var slope_length := sqrt(pow(width * 0.5 + roof_overhang, 2.0) + pow(roof_rise, 2.0))
	var roof_y := foundation_height + wall_height + roof_rise * 0.5
	add_part(blueprint, "roof_left", "roof", "roof_shingle", Vector3(-width * 0.25, roof_y, 0.0), Vector3(slope_length, 0.22, depth + roof_overhang * 2.0), {"rotation": Vector3(0.0, 0.0, roof_angle), "variation": variation, "semantic": "roof"})
	add_part(blueprint, "roof_right", "roof", "roof_shingle", Vector3(width * 0.25, roof_y, 0.0), Vector3(slope_length, 0.22, depth + roof_overhang * 2.0), {"rotation": Vector3(0.0, 0.0, -roof_angle), "variation": variation, "semantic": "roof"})
	add_part(blueprint, "ridge", "beam", "timber_beam", Vector3(0.0, foundation_height + wall_height + roof_rise, 0.0), Vector3(0.32, 0.26, depth + roof_overhang * 2.0 + 0.06), {"variation": variation, "semantic": "roof_ridge"})
	add_part(blueprint, "chimney", "chimney", "fired_brick", Vector3(width * 0.18, foundation_height + wall_height + roof_rise * 0.66, depth * 0.16), Vector3(0.72, 2.20, 0.72), {"variation": variation})
	return blueprint


static func add_cottage_frame_lattice(blueprint, width: float, depth: float, wall_height: float, wall_thickness: float, foundation_height: float, door_x: float, door_width: float, front_window_x: float, front_window_width: float, variation: float) -> void:
	var face_offset := wall_thickness * 0.5 + 0.075
	var front_z := -depth * 0.5 - face_offset
	var back_z := depth * 0.5 + face_offset
	var frame_y := foundation_height + wall_height * 0.52
	for stud_index in range(5):
		var stud_x := lerpf(-width * 0.40, width * 0.40, float(stud_index) / 4.0)
		if absf(stud_x - door_x) > door_width * 0.66 and absf(stud_x - front_window_x) > front_window_width * 0.62:
			add_part(blueprint, "front_frame_stud_%02d" % stud_index, "beam", "timber_beam", Vector3(stud_x, frame_y, front_z), Vector3(0.20, wall_height * 0.84, 0.20), {"collision": false, "variation": variation + float(stud_index) * 0.007, "semantic": "cottage_frame_lattice"})
		add_part(blueprint, "back_frame_stud_%02d" % stud_index, "beam", "timber_beam", Vector3(stud_x, frame_y, back_z), Vector3(0.20, wall_height * 0.84, 0.20), {"collision": false, "variation": variation - float(stud_index) * 0.006, "semantic": "cottage_frame_lattice"})
	var rail_y := foundation_height + wall_height * 0.56
	var left_rail_width := maxf(0.28, door_x - door_width * 0.5 + width * 0.5)
	var right_rail_width := maxf(0.28, width * 0.5 - (door_x + door_width * 0.5))
	add_part(blueprint, "front_frame_rail_left", "beam", "timber_beam", Vector3(-width * 0.5 + left_rail_width * 0.5, rail_y, front_z), Vector3(left_rail_width, 0.20, 0.20), {"collision": false, "variation": variation - 0.01, "semantic": "cottage_frame_lattice"})
	add_part(blueprint, "front_frame_rail_right", "beam", "timber_beam", Vector3(door_x + door_width * 0.5 + right_rail_width * 0.5, rail_y, front_z), Vector3(right_rail_width, 0.20, 0.20), {"collision": false, "variation": variation + 0.01, "semantic": "cottage_frame_lattice"})
	add_part(blueprint, "back_frame_rail", "beam", "timber_beam", Vector3(0.0, rail_y, back_z), Vector3(width * 0.88, 0.20, 0.20), {"collision": false, "variation": variation, "semantic": "cottage_frame_lattice"})
	for side in [-1.0, 1.0]:
		var side_x: float = side * (width * 0.5 + face_offset)
		for stud_z in [-depth * 0.25, 0.0, depth * 0.25]:
			add_part(blueprint, "side_frame_stud_%d_%d" % [int(side), int(round(stud_z * 100.0))], "beam", "timber_beam", Vector3(side_x, frame_y, stud_z), Vector3(0.20, wall_height * 0.84, 0.20), {"collision": false, "variation": variation + side * 0.012, "semantic": "cottage_frame_lattice"})
		add_part(blueprint, "side_frame_rail_%d" % int(side), "beam", "timber_beam", Vector3(side_x, rail_y, 0.0), Vector3(0.20, 0.20, depth * 0.88), {"collision": false, "variation": variation + side * 0.012, "semantic": "cottage_frame_lattice"})
	for gable_side in [-1.0, 1.0]:
		var gable_z: float = float(gable_side) * (depth * 0.5 + face_offset)
		for brace_side in [-1.0, 1.0]:
			add_part(blueprint, "gable_frame_brace_%d_%d" % [int(gable_side), int(brace_side)], "beam", "timber_beam", Vector3(brace_side * width * 0.19, foundation_height + wall_height + 0.72, gable_z), Vector3(0.18, minf(2.1, wall_height * 0.58), 0.18), {"rotation": Vector3(0.0, 0.0, brace_side * deg_to_rad(48.0)), "collision": false, "variation": variation + gable_side * 0.011 + brace_side * 0.008, "semantic": "cottage_frame_gable"})


static func add_cottage_material_age(blueprint, style: String, width: float, depth: float, wall_height: float, foundation_height: float, door_x: float, front_window_center: Vector3, variation: float) -> void:
	var front_z := -depth * 0.5 - 0.21
	var repair_x := lerpf(-width * 0.31, width * 0.28, fposmod(sin(float(blueprint.seed) * 0.017) * 3719.17, 1.0))
	if absf(repair_x - door_x) < 1.15:
		repair_x += width * 0.28
	if style == "masonry":
		for repair_index in range(4):
			var repair_width := 0.52 + float(repair_index % 2) * 0.22
			var repair_height := 0.34 + float((repair_index + 1) % 3) * 0.16
			add_part(blueprint, "front_limewash_repair_%02d" % repair_index, "decor", "fired_brick_light", Vector3(clampf(repair_x, -width * 0.36, width * 0.36) - 0.42 + float(repair_index % 2) * 0.58, foundation_height + wall_height * 0.40 + float(repair_index / 2) * 0.46, front_z), Vector3(repair_width, repair_height, 0.045), {"rotation": Vector3(0.0, 0.0, deg_to_rad(-2.0 + float(repair_index) * 1.2)), "collision": false, "variation": variation - 0.055 + float(repair_index) * 0.012, "semantic": "cottage_masonry_repair"})
		add_part(blueprint, "front_damp_foot", "ground_patch", "drainage_stain", Vector3(width * 0.27, foundation_height + 0.36, front_z - 0.002), Vector3(2.15, 0.02, 0.62), {"rotation": Vector3(PI * 0.5, 0.0, 0.0), "collision": false, "variation": variation - 0.04, "semantic": "cottage_masonry_damp"})
	else:
		for replacement_index in range(3):
			var replacement_x := -width * 0.30 + float(replacement_index) * width * 0.29
			add_part(blueprint, "front_replacement_board_%02d" % replacement_index, "decor", "timber_board", Vector3(replacement_x, foundation_height + 0.72 + float(replacement_index % 2) * 0.46, front_z - 0.012), Vector3(width * 0.24, 0.18, 0.08), {"rotation": Vector3(0.0, 0.0, deg_to_rad(-1.4 + float(replacement_index) * 1.1)), "collision": false, "variation": variation + 0.10 + float(replacement_index) * 0.025, "semantic": "cottage_replacement_timber"})
	add_part(blueprint, "entry_leaf_litter", "ground_patch", "leaf_litter", Vector3(door_x + 0.54, 0.018, front_z - 0.82), Vector3(1.42, 0.02, 0.72), {"rotation": Vector3(0.0, variation * 2.0, 0.0), "collision": false, "variation": variation - 0.035, "semantic": "cottage_threshold_litter"})
	add_part(blueprint, "entry_joint_growth", "ground_patch", "wall_growth", Vector3(door_x - 0.64, 0.021, front_z - 0.48), Vector3(0.78, 0.02, 0.46), {"rotation": Vector3(0.0, -0.34, 0.0), "collision": false, "variation": variation - 0.025, "semantic": "cottage_threshold_growth"})
	add_part(blueprint, "front_window_box", "crate", "timber_board", Vector3(front_window_center.x, front_window_center.y - 0.72, front_z - 0.16), Vector3(1.34, 0.28, 0.34), {"collision": false, "variation": variation + 0.025, "semantic": "cottage_window_box"})
	for growth_index in range(3):
		add_part(blueprint, "front_window_box_growth_%02d" % growth_index, "ground_patch", "wall_growth", Vector3(front_window_center.x - 0.42 + float(growth_index) * 0.42, front_window_center.y - 0.49 + float(growth_index % 2) * 0.05, front_z - 0.35), Vector3(0.38, 0.02, 0.45 + float(growth_index % 2) * 0.12), {"rotation": Vector3(PI * 0.5, 0.0, 0.0), "collision": false, "variation": variation + float(growth_index) * 0.014, "semantic": "cottage_window_growth"})


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


static func add_window(blueprint, part_id: String, center: Vector3, size: Vector3, variation: float, material := "window_glass") -> void:
	add_part(blueprint, part_id, "window", material, center, size, {"variation": variation, "collision": true, "semantic": "window"})


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
