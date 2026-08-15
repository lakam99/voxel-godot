extends RefCounted
class_name CitadelUrbanPocComposer

const MARKET_LANE_X := 22.0
const MARKET_TERRACE_RISE := 1.8


static func compose(blueprint, seed: int):
	if blueprint == null:
		return null
	var retained_parts: Array = []
	for part in blueprint.parts:
		var part_id := String(part.id) if part != null else ""
		if part_id.begins_with("castle_courtyard_") and part_id not in ["castle_courtyard_foundation", "castle_courtyard_paving"]:
			continue
		if part != null and String(part.kind) == "foundation" and (part_id.begins_with("castle_terrace_block_") or part_id.begins_with("castle_district_processional_")):
			part.recipe["topSurfaceMaterial"] = "worn_cobble"
		retained_parts.append(part)
	blueprint.parts = retained_parts
	blueprint.rooms = blueprint.rooms.filter(func(room): return not bool((room as Dictionary).get("castleCourtyardResidence", false)) and not bool((room as Dictionary).get("castleResidenceRoom", false)))
	var recipe: Dictionary = blueprint.recipe.duplicate(true) as Dictionary
	recipe["courtyardResidences"] = []
	var grammar: Dictionary = recipe.get("castleGrammar", {}) as Dictionary
	var foundation_height := float(recipe.get("foundationHeight", 0.62))
	var courtyard_depth := float(grammar.get("courtyardDepth", 84.0))
	var keep_depth := float(grammar.get("keepDepth", 28.0))
	var keep_center_z := courtyard_depth * float((grammar.get("keepOffset", {}) as Dictionary).get("z", 0.14))
	var keep_front_z := keep_center_z - keep_depth * 0.5
	var front_z := -courtyard_depth * 0.5
	var urban_layout := sample_urban_layout(seed, grammar, front_z, keep_front_z, foundation_height)
	recipe["urbanPoc"] = urban_layout
	blueprint.set_recipe(recipe)
	var variation := float(seed % 19) / 100.0 - 0.09
	add_street_sequence(blueprint, front_z, keep_front_z, foundation_height, variation, urban_layout)
	add_route_surface_history(blueprint, grammar, keep_front_z, foundation_height, variation)
	add_civic_landmark(blueprint, Vector3(-14.0, 0.0, keep_front_z - 4.0), foundation_height + 2.0, variation)
	add_terraced_edge(blueprint, Vector3(17.5, 0.0, keep_front_z - 9.0), foundation_height, variation)
	add_civic_quarter(blueprint, keep_front_z, foundation_height, variation)
	add_civic_commons(blueprint, keep_front_z, foundation_height, variation)
	add_perimeter_neighborhoods(blueprint, grammar, keep_front_z, foundation_height, variation)
	add_civic_service_yard(blueprint, Vector3(37.0, foundation_height, keep_front_z - 8.5), variation)
	add_dressing_clusters(blueprint, front_z, keep_front_z, foundation_height, variation)
	add_bunting_lines(blueprint, front_z, keep_front_z, foundation_height, variation, urban_layout)
	add_tree_contact_pockets(blueprint, city_tree_placements(blueprint), variation)
	return blueprint


static func add_perimeter_neighborhoods(blueprint, grammar: Dictionary, keep_front_z: float, base_y: float, variation: float) -> void:
	var courtyard_width := float(grammar.get("courtyardWidth", 104.0))
	var courtyard_depth := float(grammar.get("courtyardDepth", 96.0))
	var side_x: float = courtyard_width * 0.5 - 7.3
	var start_z := keep_front_z + 7.0
	var end_z := courtyard_depth * 0.5 - 9.0
	var row_count := 3
	var materials: Array[String] = ["painted_brick_ochre", "painted_brick_sage", "painted_brick_rose", "painted_brick_cream"]
	for side in [-1.0, 1.0]:
		for row_index in range(row_count):
			var ratio := float(row_index) / float(maxi(1, row_count - 1))
			var center_z: float = lerpf(start_z, end_z, ratio) + side * float(row_index % 2) * 0.55
			var width: float = 6.5 + float((row_index + int(side) + 4) % 3) * 0.42
			var depth: float = 8.2 + float((row_index * 2 + int(side) + 6) % 3) * 0.48
			var height: float = 6.4 + float((row_index + (1 if side > 0.0 else 0)) % 2) * 2.9
			var material := materials[(row_index + (2 if side > 0.0 else 0)) % materials.size()]
			add_street_house(blueprint, "urban_perimeter_%s_%02d" % ["east" if side > 0.0 else "west", row_index], Vector3(side * side_x, 0.0, center_z), width, depth, height, -side, base_y, material, variation + side * 0.018 + float(row_index) * 0.011)
			var alley_x: float = side * (side_x - width * 0.5 - 1.15)
			add_part(blueprint, "urban_perimeter_alley_%d_%02d" % [int(side), row_index], "ground_patch", "worn_cobble", Vector3(alley_x, base_y + 0.154, center_z), Vector3(2.1, 0.02, depth * 0.82), {"collision": false, "variation": variation - 0.04 + float(row_index) * 0.008, "semantic": "citadel_perimeter_alley"})


static func sample_urban_layout(seed: int, grammar: Dictionary, front_z: float, keep_front_z: float, foundation_height: float) -> Dictionary:
	var market_lane_x := lerpf(17.5, 25.0, stable_unit(seed, "market-lane"))
	var market_terrace_rise := lerpf(1.45, 2.15, stable_unit(seed, "market-rise"))
	var lane_centers: Array[float] = [
		lerpf(-1.4, 1.1, stable_unit(seed, "lane-0")),
		lerpf(0.6, 3.4, stable_unit(seed, "lane-1")),
		market_lane_x,
		lerpf(8.5, 15.0, stable_unit(seed, "lane-3"))
	]
	var row_center_phases: Array[float] = []
	var row_width_biases: Array[float] = []
	var row_storey_bonuses: Array[int] = []
	var nominal_phases := [0.72, 1.68, 2.62, 3.48]
	for row_index in range(4):
		row_center_phases.append(float(nominal_phases[row_index]) + lerpf(-0.075, 0.075, stable_unit(seed, "row-phase-%d" % row_index)))
		row_width_biases.append(lerpf(-0.48, 0.62, stable_unit(seed, "row-width-%d" % row_index)))
		row_storey_bonuses.append(1 if stable_unit(seed, "row-storey-%d" % row_index) > 0.72 else 0)
	var stall_specs := [
		{"side": -1.0, "depth": -1.0, "base": Vector3(-5.5, 0.0, -2.35)},
		{"side": 1.0, "depth": 1.0, "base": Vector3(5.2, 0.0, 1.75)},
		{"side": -1.0, "depth": 1.0, "base": Vector3(-2.0, 0.0, 2.55)}
	]
	var market_stalls: Array[Dictionary] = []
	for stall_index in range(stall_specs.size()):
		var stall: Dictionary = stall_specs[stall_index] as Dictionary
		var base_offset: Vector3 = stall.get("base", Vector3.ZERO) as Vector3
		var offset := base_offset + Vector3(lerpf(-0.58, 0.58, stable_unit(seed, "stall-x-%d" % stall_index)), 0.0, lerpf(-0.42, 0.42, stable_unit(seed, "stall-z-%d" % stall_index)))
		market_stalls.append({"offset": offset, "side": stall.get("side", 1.0), "depth": stall.get("depth", 1.0), "variation": lerpf(-0.035, 0.035, stable_unit(seed, "stall-material-%d" % stall_index))})
	var courtyard_width := float(grammar.get("courtyardWidth", 104.0))
	var perimeter_x := maxf(33.0, courtyard_width * 0.5 - 8.0)
	var tree_placements: Array[Vector3] = [
		Vector3(lerpf(-10.0, -5.0, stable_unit(seed, "tree-inner-x")), foundation_height + 2.0, keep_front_z - lerpf(8.0, 12.5, stable_unit(seed, "tree-inner-z"))),
		Vector3(perimeter_x, foundation_height + 0.145, keep_front_z - lerpf(5.5, 9.5, stable_unit(seed, "tree-east-z"))),
		Vector3(-perimeter_x + lerpf(-1.2, 1.2, stable_unit(seed, "tree-west-x")), foundation_height + 0.145, keep_front_z + lerpf(12.0, 18.5, stable_unit(seed, "tree-west-z"))),
		Vector3(perimeter_x - lerpf(0.5, 3.5, stable_unit(seed, "tree-rear-x")), foundation_height + 0.145, keep_front_z + lerpf(21.0, 29.0, stable_unit(seed, "tree-rear-z")))
	]
	return {
		"schemaVersion": 2,
		"layoutSeed": seed,
		"populationEvidence": "not_included_in_architecture_material_fixture",
		"referenceIntent": "dense_fortified_northern_city",
		"marketLaneX": market_lane_x,
		"marketTerraceRise": market_terrace_rise,
		"laneCenters": lane_centers,
		"rowCenterPhases": row_center_phases,
		"rowWidthBiases": row_width_biases,
		"rowStoreyBonuses": row_storey_bonuses,
		"marketStalls": market_stalls,
		"treePlacements": tree_placements,
		"frontZ": front_z,
		"keepFrontZ": keep_front_z,
		"captureRoute": ["outer_approach", "gate_threshold", "inner_lane", "market_release", "civic_overview"]
	}


static func city_tree_placements(blueprint) -> Array[Vector3]:
	var urban_layout: Dictionary = blueprint.recipe.get("urbanPoc", {}) as Dictionary
	var sampled_placements: Array[Vector3] = []
	for placement_value in urban_layout.get("treePlacements", []):
		if placement_value is Vector3:
			sampled_placements.append(placement_value as Vector3)
	if not sampled_placements.is_empty():
		return sampled_placements
	var grammar: Dictionary = blueprint.recipe.get("castleGrammar", {}) as Dictionary
	var foundation_height := float(blueprint.recipe.get("foundationHeight", 0.62))
	var courtyard_depth := float(grammar.get("courtyardDepth", 84.0))
	var keep_depth := float(grammar.get("keepDepth", 28.0))
	var keep_center_z := courtyard_depth * float((grammar.get("keepOffset", {}) as Dictionary).get("z", 0.14))
	var front_z := -courtyard_depth * 0.5
	var keep_front_z := keep_center_z - keep_depth * 0.5
	return [
		Vector3(-7.0, foundation_height + 2.0, keep_front_z - 10.0),
		Vector3(48.0, foundation_height + 0.145, keep_front_z - 7.0),
		Vector3(-44.0, foundation_height + 0.145, keep_front_z + 15.5),
		Vector3(45.0, foundation_height + 0.145, keep_front_z + 25.0)
	]


static func add_tree_contact_pockets(blueprint, placements: Array[Vector3], variation: float) -> void:
	for index in range(placements.size()):
		var center := placements[index]
		add_part(blueprint, "urban_tree_soil_%02d" % index, "ground_patch", "ground_soil", center + Vector3(0.0, 0.018, 0.0), Vector3(0.54, 0.02, 0.46), {"collision": false, "variation": variation + float(index) * 0.017, "semantic": "citadel_tree_contact"})
		for root_index in range(10):
			var root_angle := float(root_index) * TAU / 10.0 + float(index) * 0.47
			var root_length := 0.75 + float(root_index % 4) * 0.31
			var root_center := center + Vector3(cos(root_angle) * root_length * 0.44, 0.022, sin(root_angle) * root_length * 0.44)
			add_part(blueprint, "urban_tree_root_trace_%02d_%02d" % [index, root_index], "ground_patch", "ground_soil" if root_index % 3 == 0 else "wall_growth", root_center, Vector3(root_length, 0.02, 0.16 + float(root_index % 3) * 0.05), {"rotation": Vector3(0.0, -root_angle, 0.0), "collision": false, "variation": variation - 0.05 + float(root_index) * 0.007, "semantic": "citadel_tree_root_transition"})
		for pocket_index in range(18):
			var angle := float(pocket_index) * 2.399963 + float(index) * 0.63
			var radius := 0.72 + float(pocket_index % 6) * 0.31
			var pocket_center := center + Vector3(cos(angle) * radius, 0.026 + float(pocket_index % 2) * 0.004, sin(angle) * radius)
			var pocket_size := 0.20 + float((index + pocket_index) % 5) * 0.075
			var pocket_material := "leaf_litter" if pocket_index % 4 != 0 else "wall_growth"
			add_part(blueprint, "urban_tree_joint_pocket_%02d_%02d" % [index, pocket_index], "ground_patch", pocket_material, pocket_center, Vector3(pocket_size * 1.45, 0.02, pocket_size), {"collision": false, "variation": variation - 0.04 + float(pocket_index) * 0.009, "semantic": "citadel_tree_contact"})


static func add_street_sequence(blueprint, front_z: float, keep_front_z: float, base_y: float, variation: float, urban_layout: Dictionary) -> void:
	var usable_depth := maxf(42.0, keep_front_z - front_z - 5.0)
	var segment_depth := usable_depth / 4.0
	var center_phases: Array = urban_layout.get("rowCenterPhases", [0.72, 1.68, 2.62, 3.48]) as Array
	var centers: Array[float] = []
	for center_phase in center_phases:
		centers.append(front_z + segment_depth * float(center_phase))
	var lane_centers: Array = urban_layout.get("laneCenters", [0.0, 1.8, MARKET_LANE_X, 12.0]) as Array
	var market_terrace_rise := float(urban_layout.get("marketTerraceRise", MARKET_TERRACE_RISE))
	var elevations: Array[float] = [base_y, base_y, base_y + market_terrace_rise, base_y + market_terrace_rise * 2.0]
	var row_width_biases: Array = urban_layout.get("rowWidthBiases", [0.0, 0.0, 0.0, 0.0]) as Array
	var row_storey_bonuses: Array = urban_layout.get("rowStoreyBonuses", [0, 0, 0, 0]) as Array
	var row_depths: Array[float] = []
	var palette: Array[String] = ["painted_brick_cream", "painted_brick_sage", "painted_brick_rose", "painted_brick_ochre", "painted_brick_azure", "painted_brick_plum"]
	for row_index in range(centers.size()):
		var row_z := centers[row_index]
		var lane_x := float(lane_centers[row_index])
		var row_depth := segment_depth * (0.82 if row_index == 1 else 0.90)
		row_depths.append(row_depth)
		var lane_width := 5.8 if row_index != 2 else 16.0
		for side in [-1, 1]:
			var width := 7.4 + float((row_index + side + 5) % 3) * 0.9 + float(row_width_biases[row_index])
			var storeys := 2 + ((row_index + (1 if side > 0 else 0)) % 2) + int(row_storey_bonuses[row_index])
			var wall_height := 3.1 * float(storeys)
			var center_x := lane_x + float(side) * (lane_width * 0.5 + width * 0.5)
			var material := palette[(row_index * 2 + (1 if side > 0 else 0)) % palette.size()]
			add_street_house(blueprint, "urban_row_%02d_%s" % [row_index, "right" if side > 0 else "left"], Vector3(center_x, 0.0, row_z), width, row_depth, wall_height, float(-side), elevations[row_index], material, variation + float(row_index) * 0.012)
		add_lane_edge_age(blueprint, "urban_lane_%02d" % row_index, lane_x, row_z, lane_width, row_depth, elevations[row_index] + (0.334 if row_index == 2 else 0.154), variation + float(row_index) * 0.011)
	var plaza_z := centers[2]
	var market_y := elevations[2]
	add_part(blueprint, "urban_market_plaza_retaining", "foundation", "stone_foundation", Vector3(lane_centers[2], market_y + 0.12, plaza_z), Vector3(18.0, 0.24, segment_depth * 0.82), {"variation": variation - 0.05, "semantic": "citadel_market_plaza_retaining"})
	add_part(blueprint, "urban_market_plaza", "foundation", "cobblestone", Vector3(lane_centers[2], market_y + 0.27, plaza_z), Vector3(17.88, 0.10, segment_depth * 0.80), {"variation": variation - 0.04, "semantic": "citadel_market_plaza"})
	for drain_side in [-1.0, 1.0]:
		add_part(blueprint, "urban_market_edge_drain_%d" % int(drain_side), "ground_patch", "drainage_stain", Vector3(lane_centers[2] + drain_side * 8.10, market_y + 0.334, plaza_z + drain_side * 0.24), Vector3(0.72, 0.02, segment_depth * 0.72), {"collision": false, "variation": variation + drain_side * 0.018, "semantic": "citadel_market_drainage"})
	add_street_climb(blueprint, float(lane_centers[2]), centers[1] + row_depths[1] * 0.48, centers[2] - row_depths[2] * 0.46, base_y, market_terrace_rise, variation)
	add_street_climb(blueprint, float(lane_centers[3]), centers[2] + row_depths[2] * 0.48, centers[3] - row_depths[3] * 0.46, market_y, market_terrace_rise, variation)
	add_market_stalls(blueprint, Vector3(float(lane_centers[2]), market_y + 0.24, plaza_z), variation, urban_layout)
	add_terminal_shop_row(blueprint, Vector3(float(lane_centers[2]), market_y + 0.24, plaza_z + segment_depth * 0.34), variation)


static func add_lane_edge_age(blueprint, prefix: String, lane_x: float, row_z: float, lane_width: float, row_depth: float, surface_y: float, variation: float) -> void:
	var pocket_count := maxi(5, roundi(row_depth / 1.55))
	for side in [-1.0, 1.0]:
		for pocket_index in range(pocket_count):
			var phase := fposmod(sin(float(pocket_index + 1) * 19.73 + side * 7.11 + variation * 53.0) * 13457.91, 1.0)
			if phase < 0.22:
				continue
			var longitudinal := lerpf(-row_depth * 0.45, row_depth * 0.45, (float(pocket_index) + 0.5) / float(pocket_count))
			longitudinal += (phase - 0.5) * 0.72
			var edge_x: float = lane_x + side * (lane_width * 0.5 - 0.18 + phase * 0.22)
			var material := "wall_growth" if pocket_index % 4 == 0 else ("leaf_litter" if pocket_index % 3 == 0 else "drainage_stain")
			var width: float = 0.34 + phase * 0.48
			var depth: float = 0.46 + fposmod(phase * 2.73, 1.0) * 0.88
			add_part(blueprint, "%s_edge_age_%d_%02d" % [prefix, int(side), pocket_index], "ground_patch", material, Vector3(edge_x, surface_y + float(pocket_index % 2) * 0.003, row_z + longitudinal), Vector3(width, 0.02, depth), {"collision": false, "variation": variation - 0.04 + phase * 0.035, "semantic": "citadel_lane_edge_age"})


static func add_street_house(blueprint, prefix: String, center: Vector3, width: float, depth: float, wall_height: float, street_side: float, ground_y: float, material: String, variation: float) -> void:
	var base_height := minf(2.1, wall_height * 0.27)
	var upper_width := width + 0.62
	var upper_center_x := center.x + street_side * 0.31
	var facade_x := upper_center_x + street_side * (upper_width * 0.5 + 0.14)
	var room_id := "%s_interior" % prefix
	blueprint.rooms.append({
		"id": room_id,
		"bounds": AABB(Vector3(upper_center_x - upper_width * 0.5 + 0.34, ground_y + 0.18, center.z - depth * 0.5 + 0.34), Vector3(upper_width - 0.68, wall_height - 0.22, depth - 0.68)),
		"wallMountInset": 0.30,
		"citadelUrbanRoom": true,
		"accesses": [{"id": "%s_entry" % prefix, "kind": "exterior_door", "position": Vector3(facade_x - street_side * 0.84, ground_y + 0.72, center.z), "size": Vector3(1.86, 2.18, 1.86)}]
	})
	add_part(blueprint, "%s_interior_floor" % prefix, "floor", "timber_board", Vector3(upper_center_x - street_side * 0.16, ground_y + 0.11, center.z), Vector3(maxf(0.8, upper_width - 0.74), 0.20, maxf(0.8, depth - 0.74)), {"variation": variation - 0.015, "semantic": "citadel_urban_interior_floor"})
	var floor_count := maxi(2, roundi(wall_height / 3.1))
	var upper_openings: Array[Dictionary] = [{"centerY": ground_y + 1.25, "height": 2.5, "centerZ": center.z, "width": 1.48}]
	for floor_index in range(1, floor_count):
		var opening_y := ground_y + float(floor_index) * 2.75
		for window_index in [-1, 1]:
			upper_openings.append({"centerY": opening_y, "height": 1.46, "centerZ": center.z + float(window_index) * minf(depth * 0.25, 2.2), "width": 1.16})
	add_recessed_facade_mass(blueprint, "%s_stone" % prefix, center.x, center.z, width, depth, ground_y, ground_y + base_height, street_side, "stone_foundation", variation, [{"centerY": ground_y + 1.25, "height": 2.5, "centerZ": center.z, "width": 1.48}], "citadel_urban_stone_base")
	add_recessed_facade_mass(blueprint, "%s_upper" % prefix, upper_center_x, center.z, upper_width, depth, ground_y + base_height, ground_y + wall_height, street_side, material, variation, upper_openings, "citadel_urban_facade")
	for floor_index in range(1, floor_count):
		var floor_y := ground_y + float(floor_index) * 2.75
		for window_index in [-1, 1]:
			var window_z := center.z + float(window_index) * minf(depth * 0.25, 2.2)
			var window_phase := posmod(prefix.hash() + floor_index * 17 + window_index * 31, 5)
			var window_material := "window_warm_glass" if window_phase in [0, 1, 3] else "window_glass"
			add_part(blueprint, "%s_window_%02d_%d" % [prefix, floor_index, window_index], "window", window_material, Vector3(facade_x, floor_y, window_z), Vector3(0.10, 1.18, 0.88), {"collision": false, "variation": variation, "semantic": "citadel_urban_window"})
	for corner_z in [center.z - depth * 0.5 + 0.18, center.z + depth * 0.5 - 0.18]:
		add_part(blueprint, "%s_frame_%d" % [prefix, int(round(corner_z * 10.0))], "beam", "timber_beam", Vector3(facade_x + street_side * 0.05, ground_y + wall_height * 0.58, corner_z), Vector3(0.24, wall_height * 0.82, 0.24), {"collision": false, "variation": variation, "semantic": "citadel_urban_frame"})
	for intermediate_z in [center.z - depth * 0.31, center.z + depth * 0.31]:
		add_part(blueprint, "%s_upper_stud_%d" % [prefix, int(round(intermediate_z * 10.0))], "beam", "timber_beam", Vector3(facade_x + street_side * 0.06, ground_y + base_height + (wall_height - base_height) * 0.55, intermediate_z), Vector3(0.22, (wall_height - base_height) * 0.78, 0.22), {"collision": false, "variation": variation + (intermediate_z - center.z) * 0.004, "semantic": "citadel_urban_structural_frame"})
	for floor_index in range(1, maxi(2, roundi(wall_height / 3.1))):
		add_part(blueprint, "%s_floor_beam_%02d" % [prefix, floor_index], "beam", "timber_beam", Vector3(facade_x + street_side * 0.06, ground_y + float(floor_index) * 3.05, center.z), Vector3(0.24, 0.24, depth + 0.28), {"collision": false, "variation": variation, "semantic": "citadel_urban_frame"})
	for brace_sign in [-1.0, 1.0]:
		add_part(blueprint, "%s_street_brace_%d" % [prefix, int(brace_sign)], "beam", "timber_beam", Vector3(facade_x + street_side * 0.07, ground_y + 2.15, center.z + brace_sign * minf(depth * 0.28, 2.35)), Vector3(0.18, 2.45, 0.18), {"rotation": Vector3(brace_sign * deg_to_rad(31.0), 0.0, 0.0), "collision": false, "variation": variation + brace_sign * 0.018, "semantic": "citadel_urban_brace"})
	for gable_sign in [-1.0, 1.0]:
		var gable_z: float = center.z + gable_sign * (depth * 0.5 + 0.04)
		if wall_height > 5.6:
			for window_sign in [-1.0, 1.0]:
				var gable_window_material := "window_warm_glass" if posmod(prefix.hash() + int(gable_sign * 7.0) + int(window_sign * 13.0), 4) != 0 else "window_glass"
				add_part(blueprint, "%s_gable_window_%d_%d" % [prefix, int(gable_sign), int(window_sign)], "window", gable_window_material, Vector3(upper_center_x + window_sign * upper_width * 0.22, ground_y + minf(5.05, wall_height * 0.58), gable_z + gable_sign * 0.015), Vector3(0.88, 1.14, 0.10), {"collision": false, "variation": variation, "semantic": "citadel_urban_window"})
	add_part(blueprint, "%s_door_recess" % prefix, "decor", "window_recess", Vector3(facade_x - street_side * 0.18, ground_y + 1.30, center.z), Vector3(0.12, 2.66, 1.56), {"collision": false, "variation": variation - 0.03, "semantic": "citadel_urban_door_reveal"})
	add_part(blueprint, "%s_door" % prefix, "door", "painted_door", Vector3(facade_x - street_side * 0.10, ground_y + 1.25, center.z), Vector3(0.14, 2.5, 1.25), {"collision": true, "variation": variation, "semantic": "citadel_urban_door", "roomId": room_id})
	add_part(blueprint, "%s_door_lintel" % prefix, "beam", "timber_beam", Vector3(facade_x + street_side * 0.03, ground_y + 2.64, center.z), Vector3(0.24, 0.22, 1.82), {"collision": false, "variation": variation - 0.015, "semantic": "citadel_urban_door_joinery"})
	add_part(blueprint, "%s_door_hood" % prefix, "decor", "roof_shingle", Vector3(facade_x + street_side * 0.58, ground_y + 2.84, center.z), Vector3(1.28, 0.16, 2.08), {"rotation": Vector3(0.0, 0.0, street_side * deg_to_rad(-12.0)), "collision": false, "variation": variation - 0.025, "semantic": "citadel_urban_door_hood"})
	for bracket_z in [-0.66, 0.66]:
		add_part(blueprint, "%s_door_bracket_%d" % [prefix, int(bracket_z * 100.0)], "beam", "timber_beam", Vector3(facade_x + street_side * 0.31, ground_y + 2.53, center.z + bracket_z), Vector3(0.14, 0.76, 0.14), {"rotation": Vector3(0.0, 0.0, street_side * deg_to_rad(-42.0)), "collision": false, "variation": variation + bracket_z * 0.008, "semantic": "citadel_urban_door_joinery"})
	add_part(blueprint, "%s_door_threshold" % prefix, "foundation", "worn_cobble", Vector3(facade_x + street_side * 0.43, ground_y + 0.07, center.z), Vector3(0.92, 0.14, 1.58), {"collision": false, "variation": variation - 0.04, "semantic": "citadel_threshold_wear"})
	var lantern_z := center.z + minf(depth * 0.22, 1.55)
	add_part(blueprint, "%s_lantern_frame" % prefix, "decor", "ironwork", Vector3(facade_x + street_side * 0.16, ground_y + 2.35, lantern_z), Vector3(0.18, 0.48, 0.34), {"collision": false, "variation": variation, "semantic": "citadel_urban_lantern_frame"})
	add_part(blueprint, "%s_lantern_flame" % prefix, "decor", "candle_flame", Vector3(facade_x + street_side * 0.20, ground_y + 2.34, lantern_z), Vector3(0.10, 0.20, 0.12), {"collision": false, "variation": variation, "semantic": "citadel_urban_lantern_flame"})
	var household_phase := float(posmod(prefix.hash(), 997)) / 997.0
	var clutter_x := facade_x + street_side * 0.22
	var clutter_z := center.z + lerpf(-minf(depth * 0.31, 2.05), minf(depth * 0.25, 1.65), household_phase)
	if household_phase > 0.18:
		add_part(blueprint, "%s_household_barrel" % prefix, "barrel", "timber_board", Vector3(clutter_x, ground_y + 0.45, clutter_z), Vector3(0.66, 0.90, 0.66), {"collision": false, "variation": variation - 0.025, "semantic": "citadel_household_storage"})
	if household_phase < 0.84:
		add_part(blueprint, "%s_household_crate" % prefix, "crate", "timber_board", Vector3(clutter_x, ground_y + 0.31, clutter_z + lerpf(0.58, 0.96, household_phase)), Vector3(0.58, 0.62, 0.58), {"collision": false, "variation": variation + 0.018, "semantic": "citadel_household_storage"})
	var firewood_count := 3 + int(round(household_phase * 5.0))
	for log_index in range(firewood_count):
		var log_row := log_index / 3
		var log_column := log_index % 3
		add_part(blueprint, "%s_firewood_%02d" % [prefix, log_index], "beam", "timber_board", Vector3(clutter_x + street_side * 0.08, ground_y + 0.10 + float(log_row) * 0.14, clutter_z + 0.92 + float(log_column) * 0.23), Vector3(0.13, 0.13, 0.78), {"rotation": Vector3(0.0, float(log_column - 1) * deg_to_rad(4.0), 0.0), "collision": false, "variation": variation + float(log_index) * 0.009, "semantic": "citadel_household_firewood"})
	if household_phase > 0.42:
		var sign_z := center.z + lerpf(-0.72, 0.88, household_phase)
		add_part(blueprint, "%s_sign_arm" % prefix, "beam", "timber_beam", Vector3(facade_x + street_side * 0.38, ground_y + 2.70, sign_z), Vector3(0.12, 0.12, 1.05), {"collision": false, "variation": variation, "semantic": "citadel_household_sign"})
		add_part(blueprint, "%s_hanging_sign" % prefix, "sign", "painted_decor", Vector3(facade_x + street_side * 0.40, ground_y + 2.28, sign_z + 0.42), Vector3(0.12, 0.72, 0.62), {"collision": false, "variation": variation + 0.03, "semantic": "citadel_household_sign"})
	var window_box_z := center.z - minf(depth * 0.25, 2.2)
	add_part(blueprint, "%s_window_box" % prefix, "crate", "timber_board", Vector3(facade_x + street_side * 0.16, ground_y + 2.18, window_box_z), Vector3(0.36, 0.28, 1.14), {"collision": false, "variation": variation + 0.03, "semantic": "citadel_household_window_box"})
	for box_growth in range(3):
		add_part(blueprint, "%s_window_box_growth_%02d" % [prefix, box_growth], "ground_patch", "wall_growth", Vector3(facade_x + street_side * 0.38, ground_y + 2.34 + float(box_growth % 2) * 0.05, window_box_z - 0.34 + float(box_growth) * 0.34), Vector3(0.38, 0.02, 0.46 + float(box_growth % 2) * 0.12), {"rotation": Vector3(0.0, 0.0, street_side * PI * 0.5), "collision": false, "variation": variation + float(box_growth) * 0.013, "semantic": "citadel_household_window_growth"})
	if household_phase > 0.30:
		add_part(blueprint, "%s_household_tool_rack" % prefix, "tool_rack", "ironwork", Vector3(facade_x + street_side * 0.24, ground_y + 1.78, center.z - lerpf(1.65, 2.30, household_phase)), Vector3(0.20, 1.28, 1.12), {"rotation": Vector3(0.0, street_side * PI * 0.5, 0.0), "collision": false, "variation": variation, "semantic": "citadel_household_tools"})
	if household_phase < 0.58:
		add_part(blueprint, "%s_household_basket" % prefix, "basket", "timber_board", Vector3(clutter_x + street_side * 0.08, ground_y + 0.26, clutter_z - 0.62), Vector3(0.54, 0.44, 0.54), {"rotation": Vector3(0.0, household_phase * TAU, 0.0), "collision": false, "variation": variation + 0.02, "semantic": "citadel_household_storage"})
	else:
		add_part(blueprint, "%s_household_sack" % prefix, "sack", "linen", Vector3(clutter_x + street_side * 0.10, ground_y + 0.38, clutter_z - 0.56), Vector3(0.48, 0.72, 0.44), {"rotation": Vector3(0.0, household_phase * TAU, 0.0), "collision": false, "variation": variation - 0.015, "semantic": "citadel_household_storage"})
	if household_phase > 0.60:
		var bay_z := center.z + lerpf(-depth * 0.22, depth * 0.22, household_phase)
		var bay_y := ground_y + minf(wall_height * 0.66, 5.1)
		add_part(blueprint, "%s_projecting_bay" % prefix, "wall", material, Vector3(facade_x + street_side * 0.42, bay_y, bay_z), Vector3(0.78, 2.05, 2.20), {"collision": false, "variation": variation + 0.025, "semantic": "citadel_household_projecting_bay"})
		add_part(blueprint, "%s_projecting_bay_window" % prefix, "window", "window_glass", Vector3(facade_x + street_side * 0.84, bay_y + 0.08, bay_z), Vector3(0.12, 1.22, 1.10), {"collision": false, "variation": variation, "semantic": "citadel_household_projecting_bay"})
		add_part(blueprint, "%s_projecting_bay_roof" % prefix, "decor", "roof_shingle", Vector3(facade_x + street_side * 0.44, bay_y + 1.20, bay_z), Vector3(1.12, 0.18, 2.62), {"rotation": Vector3(0.0, 0.0, street_side * deg_to_rad(-8.0)), "collision": false, "variation": variation - 0.02, "semantic": "citadel_household_projecting_bay"})
	if household_phase < 0.68:
		add_part(blueprint, "%s_wall_growth" % prefix, "ground_patch", "wall_growth", Vector3(facade_x + street_side * 0.045, ground_y + 1.34 + household_phase * 1.5, center.z + lerpf(-depth * 0.31, depth * 0.30, household_phase)), Vector3(1.65 + household_phase, 0.02, 2.25), {"rotation": Vector3(0.0, 0.0, street_side * PI * 0.5), "collision": false, "variation": variation - 0.04, "semantic": "citadel_wall_growth"})
	add_part(blueprint, "%s_threshold_wear" % prefix, "ground_patch", "worn_cobble", Vector3(facade_x + street_side * 1.18, ground_y + 0.034, center.z + (household_phase - 0.5) * 0.42), Vector3(2.65, 0.02, 1.38), {"collision": false, "variation": variation - 0.03, "semantic": "citadel_threshold_wear"})
	if household_phase > 0.54:
		var shop_z := center.z + lerpf(-depth * 0.22, depth * 0.22, household_phase)
		for awning_strip in range(5):
			var strip_z := shop_z - 1.12 + float(awning_strip) * 0.56
			add_part(blueprint, "%s_shop_awning_%02d" % [prefix, awning_strip], "decor", "wool_moss" if household_phase > 0.76 else "wool_rust", Vector3(facade_x + street_side * 0.77, ground_y + 2.34 + absf(float(awning_strip) - 2.0) * 0.018, strip_z), Vector3(1.58, 0.07, 0.54), {"rotation": Vector3(0.0, 0.0, street_side * deg_to_rad(-9.0)), "collision": false, "variation": variation + float(awning_strip) * 0.006, "semantic": "citadel_shopfront"})
		add_part(blueprint, "%s_shop_shelf" % prefix, "decor", "timber_board", Vector3(facade_x + street_side * 0.24, ground_y + 1.18, shop_z), Vector3(0.38, 0.14, 2.42), {"collision": false, "variation": variation, "semantic": "citadel_shopfront"})
		for shop_good in range(4):
			add_part(blueprint, "%s_shop_good_%02d" % [prefix, shop_good], "decor", "ceramic_glaze" if shop_good % 2 == 0 else "linen", Vector3(facade_x + street_side * 0.31, ground_y + 1.38 + float(shop_good % 2) * 0.12, shop_z - 0.82 + float(shop_good) * 0.54), Vector3(0.24, 0.28 + float(shop_good % 2) * 0.12, 0.24), {"collision": false, "variation": variation + float(shop_good) * 0.012, "semantic": "citadel_shopfront_goods"})
	if household_phase > 0.26 and household_phase < 0.86:
		add_part(blueprint, "%s_masonry_repair" % prefix, "decor", "limewash_repair", Vector3(facade_x + street_side * 0.052, ground_y + 2.05 + household_phase * 1.25, center.z + lerpf(depth * 0.28, -depth * 0.24, household_phase)), Vector3(0.09, 1.05 + household_phase * 0.55, 1.18 + (1.0 - household_phase) * 0.72), {"collision": false, "variation": variation - 0.05, "semantic": "citadel_masonry_repair"})
	add_part(blueprint, "%s_eave" % prefix, "beam", "timber_beam", Vector3(facade_x + street_side * 0.22, ground_y + wall_height, center.z), Vector3(0.34, 0.30, depth + 0.54), {"collision": false, "variation": variation, "semantic": "citadel_urban_eave"})
	var roof_rise := 3.2 + fmod(absf(center.x + center.z), 1.6)
	var slope_length := sqrt(pow(upper_width * 0.5 + 0.70, 2.0) + roof_rise * roof_rise)
	var roof_angle := atan2(roof_rise, upper_width * 0.5 + 0.70)
	var roof_y := ground_y + wall_height + roof_rise * 0.5
	add_part(blueprint, "%s_roof_left" % prefix, "roof", "roof_shingle", Vector3(upper_center_x - upper_width * 0.25, roof_y, center.z), Vector3(slope_length, 0.28, depth + 1.20), {"rotation": Vector3(0.0, 0.0, roof_angle), "variation": variation, "semantic": "citadel_urban_roof"})
	add_part(blueprint, "%s_roof_right" % prefix, "roof", "roof_shingle", Vector3(upper_center_x + upper_width * 0.25, roof_y, center.z), Vector3(slope_length, 0.28, depth + 1.20), {"rotation": Vector3(0.0, 0.0, -roof_angle), "variation": variation, "semantic": "citadel_urban_roof"})
	add_part(blueprint, "%s_chimney" % prefix, "wall", "stone_foundation", Vector3(upper_center_x - upper_width * 0.22, ground_y + wall_height + roof_rise * 0.72, center.z + depth * 0.18), Vector3(0.72, roof_rise + 1.0, 0.72), {"variation": variation, "semantic": "citadel_urban_chimney"})


static func add_recessed_facade_mass(blueprint, prefix: String, center_x: float, center_z: float, width: float, depth: float, bottom_y: float, top_y: float, street_side: float, material: String, variation: float, openings: Array[Dictionary], semantic: String) -> void:
	var recess_depth := minf(0.72, width * 0.16)
	var facade_thickness := minf(0.30, recess_depth * 0.48)
	var wall_height := top_y - bottom_y
	var wall_y := (bottom_y + top_y) * 0.5
	var back_x := center_x - street_side * (width * 0.5 - facade_thickness * 0.5)
	add_part(blueprint, "%s_shell_back" % prefix, "wall", material, Vector3(back_x, wall_y, center_z), Vector3(facade_thickness, wall_height, depth), {"variation": variation - 0.008, "semantic": "%s_shell" % semantic})
	var gable_sides: Array[float] = [-1.0, 1.0]
	for gable_side in gable_sides:
		var side_z := center_z + gable_side * (depth * 0.5 - facade_thickness * 0.5)
		add_part(blueprint, "%s_shell_side_%d" % [prefix, int(gable_side)], "wall", material, Vector3(center_x, wall_y, side_z), Vector3(maxf(0.42, width - facade_thickness * 2.0), wall_height, facade_thickness), {"variation": variation + gable_side * 0.008, "semantic": "%s_shell" % semantic})
	var facade_center_x := center_x + street_side * (width * 0.5 - facade_thickness * 0.5)
	add_partitioned_street_facade(blueprint, "%s_facade" % prefix, facade_center_x, center_z, depth, bottom_y, top_y, facade_thickness, material, variation, openings, semantic)


static func add_partitioned_street_facade(blueprint, prefix: String, facade_x: float, center_z: float, depth: float, bottom_y: float, top_y: float, thickness: float, material: String, variation: float, openings: Array[Dictionary], semantic: String) -> void:
	var z_edges: Array[float] = [center_z - depth * 0.5, center_z + depth * 0.5]
	var y_edges: Array[float] = [bottom_y, top_y]
	for opening in openings:
		var opening_center_z := float(opening.get("centerZ", center_z))
		var opening_width := float(opening.get("width", 1.0))
		var opening_center_y := float(opening.get("centerY", (bottom_y + top_y) * 0.5))
		var opening_height := float(opening.get("height", 1.0))
		z_edges.append(clampf(opening_center_z - opening_width * 0.5, z_edges[0], z_edges[1]))
		z_edges.append(clampf(opening_center_z + opening_width * 0.5, z_edges[0], z_edges[1]))
		y_edges.append(clampf(opening_center_y - opening_height * 0.5, bottom_y, top_y))
		y_edges.append(clampf(opening_center_y + opening_height * 0.5, bottom_y, top_y))
	z_edges.sort()
	y_edges.sort()
	var panel_index := 0
	for y_index in range(y_edges.size() - 1):
		var cell_bottom := y_edges[y_index]
		var cell_top := y_edges[y_index + 1]
		if cell_top - cell_bottom < 0.035:
			continue
		for z_index in range(z_edges.size() - 1):
			var cell_near := z_edges[z_index]
			var cell_far := z_edges[z_index + 1]
			if cell_far - cell_near < 0.035:
				continue
			var cell_y := (cell_bottom + cell_top) * 0.5
			var cell_z := (cell_near + cell_far) * 0.5
			var inside_opening := false
			for opening in openings:
				if absf(cell_y - float(opening.get("centerY", cell_y))) < float(opening.get("height", 0.0)) * 0.5 - 0.001 and absf(cell_z - float(opening.get("centerZ", cell_z))) < float(opening.get("width", 0.0)) * 0.5 - 0.001:
					inside_opening = true
					break
			if inside_opening:
				continue
			add_part(blueprint, "%s_%03d" % [prefix, panel_index], "wall", material, Vector3(facade_x, cell_y, cell_z), Vector3(thickness, cell_top - cell_bottom, cell_far - cell_near), {"variation": variation + float(posmod(panel_index, 5) - 2) * 0.004, "semantic": semantic})
			panel_index += 1


static func add_street_climb(blueprint, center_x: float, from_z: float, to_z: float, base_y: float, rise: float, variation: float) -> void:
	var step_count := 8
	var tread_depth := maxf(0.48, (to_z - from_z) / float(step_count))
	for step_index in range(step_count):
		var step_height := rise * float(step_index + 1) / float(step_count)
		add_part(blueprint, "urban_street_climb_%d_%02d" % [int(round(base_y * 100.0)), step_index], "stair_tread", "cobblestone", Vector3(center_x, base_y + step_height * 0.5, from_z + tread_depth * (float(step_index) + 0.5)), Vector3(6.4, step_height, tread_depth + 0.03), {"variation": variation, "semantic": "citadel_street_climb"})


static func add_route_surface_history(blueprint, grammar: Dictionary, keep_front_z: float, base_y: float, variation: float) -> void:
	var courtyard_width := float(grammar.get("courtyardWidth", 104.0))
	var courtyard_depth := float(grammar.get("courtyardDepth", 96.0))
	var route_start := keep_front_z + 4.5
	var route_end := courtyard_depth * 0.5 - 5.0
	var route_length := maxf(8.0, route_end - route_start)
	for side in [-1.0, 1.0]:
		var route_x: float = float(side) * (courtyard_width * 0.5 - 18.0)
		var building_side_x: float = route_x + side * 5.15
		add_part(blueprint, "urban_perimeter_drain_%d" % int(side), "ground_patch", "drainage_stain", Vector3(route_x + side * 3.82, base_y + 0.166, route_start + route_length * 0.5), Vector3(0.58, 0.02, route_length * 0.94), {"collision": false, "variation": variation - 0.05, "semantic": "citadel_route_history"})
		for verge_index in range(11):
			var verge_phase := fposmod(sin(float(verge_index + 3) * 11.83 + side * 23.7 + variation * 61.0) * 29171.37, 1.0)
			var verge_length := route_length / 11.0
			var verge_z := route_start + verge_length * (float(verge_index) + 0.5) + (verge_phase - 0.5) * 0.82
			var verge_width := 1.65 + verge_phase * 1.15
			var verge_depth := verge_length * (0.78 + verge_phase * 0.13)
			var verge_material := "ground_soil" if verge_index % 4 in [0, 1] else ("wall_growth" if verge_index % 4 == 2 else "leaf_litter")
			add_part(blueprint, "urban_perimeter_verge_%d_%02d" % [int(side), verge_index], "ground_patch", verge_material, Vector3(building_side_x + side * (verge_phase - 0.5) * 0.36, base_y + 0.171 + float(verge_index % 2) * 0.003, verge_z), Vector3(verge_width, 0.02, verge_depth), {"rotation": Vector3(0.0, (verge_phase - 0.5) * 0.12, 0.0), "collision": false, "variation": variation - 0.05 + verge_phase * 0.035, "semantic": "citadel_route_verge"})
		for rut_index in range(8):
			var rut_phase := fposmod(sin(float(rut_index + 5) * 17.41 + side * 13.1 + variation * 37.0) * 18367.91, 1.0)
			var rut_z := lerpf(route_start, route_end, (float(rut_index) + 0.5) / 8.0) + (rut_phase - 0.5) * 1.4
			var rut_x: float = route_x - side * (0.58 + rut_phase * 0.54)
			add_part(blueprint, "urban_perimeter_rut_%d_%02d" % [int(side), rut_index], "ground_patch", "worn_cobble" if rut_index % 3 != 0 else "ground_soil", Vector3(rut_x, base_y + 0.173, rut_z), Vector3(0.52 + rut_phase * 0.62, 0.02, 1.8 + rut_phase * 2.4), {"rotation": Vector3(0.0, (rut_phase - 0.5) * 0.10, 0.0), "collision": false, "variation": variation - 0.05 + rut_phase * 0.03, "semantic": "citadel_route_rut"})
		for patch_index in range(18):
			var phase := fposmod(sin(float(patch_index + 1) * 13.71 + side * 19.3 + variation * 43.0) * 41731.13, 1.0)
			var z := lerpf(route_start, route_end, (float(patch_index) + 0.5) / 18.0) + (phase - 0.5) * 1.25
			var edge_bias := -1.0 if patch_index % 3 == 0 else 1.0
			var x: float = route_x + float(side) * edge_bias * (4.0 + phase * 2.4)
			var material := "ground_soil" if patch_index % 5 == 0 else ("leaf_litter" if patch_index % 3 == 0 else ("wall_growth" if patch_index % 4 == 0 else "worn_cobble"))
			add_part(blueprint, "urban_route_history_%d_%02d" % [int(side), patch_index], "ground_patch", material, Vector3(x, base_y + 0.169 + float(patch_index % 2) * 0.003, z), Vector3(0.65 + phase * 1.65, 0.02, 0.58 + fposmod(phase * 2.17, 1.0) * 1.85), {"rotation": Vector3(0.0, phase * TAU, 0.0), "collision": false, "variation": variation - 0.05 + phase * 0.04, "semantic": "citadel_route_history"})


static func add_market_stalls(blueprint, center: Vector3, variation: float, urban_layout: Dictionary) -> void:
	var stalls: Array = urban_layout.get("marketStalls", []) as Array
	if stalls.is_empty():
		stalls = [
			{"offset": Vector3(-5.8, 0.0, -2.55), "side": -1.0, "depth": -1.0, "variation": -0.018},
			{"offset": Vector3(5.4, 0.0, 1.82), "side": 1.0, "depth": 1.0, "variation": 0.014},
			{"offset": Vector3(-2.2, 0.0, 2.72), "side": -1.0, "depth": 1.0, "variation": 0.031}
		]
	for stall_value in stalls:
		var stall: Dictionary = stall_value as Dictionary
		add_market_stall_household(blueprint, center + (stall.get("offset", Vector3.ZERO) as Vector3), float(stall.get("side", 1.0)), float(stall.get("depth", 1.0)), variation + float(stall.get("variation", 0.0)))


static func add_terminal_shop_row(blueprint, center: Vector3, variation: float) -> void:
	for bay_index in range(3):
		var bay_x := center.x - 4.6 + float(bay_index) * 4.6
		var bay_key := "terminal_%02d" % bay_index
		var cloth_material := "wool_rust" if bay_index == 0 else ("linen" if bay_index == 1 else "wool_moss")
		add_part(blueprint, "urban_%s_recess" % bay_key, "decor", "window_recess", Vector3(bay_x, center.y + 1.30, center.z + 0.08), Vector3(3.30, 2.35, 0.12), {"collision": false, "variation": variation - 0.04, "semantic": "citadel_terminal_shop_recess"})
		for frame_side in [-1.0, 1.0]:
			add_part(blueprint, "urban_%s_jamb_%d" % [bay_key, int(frame_side)], "beam", "timber_beam", Vector3(bay_x + frame_side * 1.68, center.y + 1.34, center.z - 0.01), Vector3(0.20, 2.68, 0.22), {"collision": false, "variation": variation + frame_side * 0.018, "semantic": "citadel_terminal_shop_frame"})
			add_part(blueprint, "urban_%s_bracket_%d" % [bay_key, int(frame_side)], "beam", "timber_beam", Vector3(bay_x + frame_side * 1.48, center.y + 2.18, center.z - 0.48), Vector3(0.15, 1.18, 0.15), {"rotation": Vector3(frame_side * deg_to_rad(38.0), 0.0, 0.0), "collision": false, "variation": variation + frame_side * 0.018, "semantic": "citadel_terminal_shop_joinery"})
			add_part(blueprint, "urban_%s_shutter_%d" % [bay_key, int(frame_side)], "decor", "timber_board", Vector3(bay_x + frame_side * 1.30, center.y + 1.42, center.z - 0.08), Vector3(0.52, 1.72, 0.10), {"rotation": Vector3(0.0, frame_side * deg_to_rad(8.0), frame_side * deg_to_rad(1.5)), "collision": false, "variation": variation + frame_side * 0.026, "semantic": "citadel_terminal_shop_shutter"})
		add_part(blueprint, "urban_%s_lintel" % bay_key, "beam", "timber_beam", Vector3(bay_x, center.y + 2.62, center.z - 0.02), Vector3(3.58, 0.24, 0.24), {"collision": false, "variation": variation - 0.02, "semantic": "citadel_terminal_shop_frame"})
		for strip_index in range(7):
			var strip_x := bay_x - 1.68 + float(strip_index) * 0.56
			var strip_material := "linen" if strip_index == 1 + bay_index else cloth_material
			add_part(blueprint, "urban_%s_awning_%02d" % [bay_key, strip_index], "decor", strip_material, Vector3(strip_x, center.y + 2.50 + absf(float(strip_index) - 3.0) * 0.026, center.z - 0.72), Vector3(0.54, 0.075, 2.18), {"rotation": Vector3(deg_to_rad(-11.0), 0.0, 0.0), "collision": false, "variation": variation + float(strip_index) * 0.007, "semantic": "citadel_terminal_shop_awning"})
		add_part(blueprint, "urban_%s_counter" % bay_key, "decor", "timber_board", Vector3(bay_x, center.y + 0.76, center.z - 1.34), Vector3(3.28, 0.16, 0.68), {"collision": false, "variation": variation + float(bay_index) * 0.012, "semantic": "citadel_terminal_shop"})
		add_part(blueprint, "urban_%s_wall_shelf" % bay_key, "decor", "timber_board", Vector3(bay_x, center.y + 1.44, center.z + 0.03), Vector3(3.18, 0.14, 0.42), {"collision": false, "variation": variation, "semantic": "citadel_terminal_shop"})
		add_part(blueprint, "urban_%s_tool_rack" % bay_key, "tool_rack", "ironwork", Vector3(bay_x - 0.90, center.y + 1.86, center.z - 0.03), Vector3(1.05, 1.15, 0.18), {"collision": false, "variation": variation, "semantic": "citadel_terminal_shop_tools"})
		add_part(blueprint, "urban_%s_lantern_flame" % bay_key, "decor", "candle_flame", Vector3(bay_x + 1.02, center.y + 1.92, center.z - 0.20), Vector3(0.10, 0.18, 0.10), {"collision": false, "variation": variation, "semantic": "citadel_urban_lantern_flame"})
		add_part(blueprint, "urban_%s_sign_arm" % bay_key, "beam", "timber_beam", Vector3(bay_x - 1.18 + float(bay_index) * 0.16, center.y + 3.16, center.z - 0.08), Vector3(1.16, 0.12, 0.12), {"collision": false, "variation": variation - 0.02, "semantic": "citadel_terminal_shop_sign"})
		add_part(blueprint, "urban_%s_sign" % bay_key, "sign", "painted_decor", Vector3(bay_x - 0.66 + float(bay_index) * 0.16, center.y + 2.78, center.z - 0.16), Vector3(0.82, 0.72, 0.10), {"rotation": Vector3(0.0, 0.0, deg_to_rad(float(bay_index - 1) * 4.0)), "collision": false, "variation": variation + float(bay_index) * 0.018, "semantic": "citadel_terminal_shop_sign"})
		for goods_index in range(4):
			var goods_x := bay_x - 1.18 + float(goods_index) * 0.76
			var goods_selector := (bay_index * 2 + goods_index) % 4
			var goods_kind := "sack" if goods_selector == 0 else ("basket" if goods_selector in [1, 2] else "pottery")
			var goods_material := "linen" if goods_kind == "sack" else ("timber_board" if goods_kind == "basket" else "ceramic_glaze")
			var goods_y := center.y + (0.31 if goods_kind in ["sack", "basket"] else 1.02)
			var goods_z := center.z - 1.34 + float(goods_index % 2) * 0.48
			var goods_size := Vector3(0.46, 0.72, 0.42) if goods_kind == "sack" else Vector3(0.48, 0.46, 0.48)
			add_part(blueprint, "urban_%s_goods_%02d" % [bay_key, goods_index], goods_kind, goods_material, Vector3(goods_x, goods_y, goods_z), goods_size, {"rotation": Vector3(0.0, deg_to_rad(float(goods_index - 2) * 8.0), 0.0), "collision": false, "variation": variation + float(goods_index) * 0.015, "semantic": "citadel_terminal_shop_goods"})
		add_part(blueprint, "urban_%s_wall_growth" % bay_key, "ground_patch", "wall_growth", Vector3(bay_x - 1.34 + float(bay_index) * 0.22, center.y + 0.62, center.z + 0.15), Vector3(0.70, 0.02, 1.18), {"rotation": Vector3(PI * 0.5, 0.0, 0.0), "collision": false, "variation": variation - 0.04, "semantic": "citadel_wall_growth"})
		add_part(blueprint, "urban_%s_wear" % bay_key, "ground_patch", "worn_cobble", Vector3(bay_x, center.y + 0.042, center.z - 2.46), Vector3(2.75, 0.02, 3.20), {"collision": false, "variation": variation - 0.04, "semantic": "citadel_terminal_shop_wear"})


static func add_civic_service_yard(blueprint, center: Vector3, variation: float) -> void:
	for patch_index in range(7):
		var patch_x := center.x - 6.0 + float(patch_index % 4) * 3.4
		var patch_z := center.z - 4.4 + float(patch_index / 4) * 4.1 + float(patch_index % 2) * 0.55
		add_part(blueprint, "urban_civic_route_wear_%02d" % patch_index, "ground_patch", "worn_cobble", Vector3(patch_x, center.y + 0.232, patch_z), Vector3(4.6 + float(patch_index % 2), 0.02, 3.0 + float((patch_index + 1) % 3) * 0.44), {"collision": false, "variation": variation - 0.05 + float(patch_index) * 0.009, "semantic": "citadel_civic_route_wear"})
	add_part(blueprint, "urban_civic_drain", "ground_patch", "drainage_stain", center + Vector3(2.8, 0.238, -0.2), Vector3(0.82, 0.02, 11.5), {"collision": false, "variation": variation - 0.03, "semantic": "citadel_civic_drainage"})
	var shed_center := center + Vector3(4.2, 0.0, 1.2)
	for post_side in [-1.0, 1.0]:
		add_part(blueprint, "urban_civic_shed_post_%d" % int(post_side), "beam", "timber_beam", shed_center + Vector3(post_side * 2.0, 1.30, -0.72), Vector3(0.22, 2.60, 0.22), {"collision": false, "variation": variation + post_side * 0.018, "semantic": "citadel_civic_service_shed"})
		add_part(blueprint, "urban_civic_shed_brace_%d" % int(post_side), "beam", "timber_beam", shed_center + Vector3(post_side * 1.70, 2.10, -0.48), Vector3(0.15, 1.08, 0.15), {"rotation": Vector3(0.0, 0.0, post_side * deg_to_rad(38.0)), "collision": false, "variation": variation, "semantic": "citadel_civic_service_shed"})
	for roof_strip in range(8):
		add_part(blueprint, "urban_civic_shed_roof_%02d" % roof_strip, "decor", "timber_board", shed_center + Vector3(-2.05 + float(roof_strip) * 0.58, 2.54 + float(roof_strip % 3) * 0.018, 0.0), Vector3(0.56, 0.10, 2.25), {"rotation": Vector3(deg_to_rad(-9.0), 0.0, 0.0), "collision": false, "variation": variation + float(roof_strip) * 0.011, "semantic": "citadel_civic_service_shed"})
	for storage_index in range(5):
		var storage_x := shed_center.x - 1.55 + float(storage_index % 3) * 0.88
		var storage_z := shed_center.z + 0.48 + float(storage_index / 3) * 0.76
		var storage_kind := "barrel" if storage_index in [0, 4] else "crate"
		add_part(blueprint, "urban_civic_storage_%02d" % storage_index, storage_kind, "timber_board", Vector3(storage_x, center.y + (0.46 if storage_kind == "barrel" else 0.34), storage_z), Vector3(0.70, 0.92 if storage_kind == "barrel" else 0.68, 0.70), {"rotation": Vector3(0.0, deg_to_rad(float(storage_index - 2) * 7.0), 0.0), "collision": false, "variation": variation + float(storage_index) * 0.015, "semantic": "citadel_civic_service_storage"})
	for log_index in range(12):
		var log_row := log_index / 4
		var log_column := log_index % 4
		add_part(blueprint, "urban_civic_firewood_%02d" % log_index, "beam", "timber_board", center + Vector3(-4.8 + float(log_column) * 0.25, 0.10 + float(log_row) * 0.15, 2.8), Vector3(0.14, 0.14, 0.92), {"rotation": Vector3(0.0, deg_to_rad(float(log_column - 2) * 3.0), 0.0), "collision": false, "variation": variation + float(log_index) * 0.007, "semantic": "citadel_civic_firewood"})
	for growth_index in range(8):
		var growth_angle := float(growth_index) * TAU / 8.0
		add_part(blueprint, "urban_civic_joint_growth_%02d" % growth_index, "ground_patch", "wall_growth", center + Vector3(cos(growth_angle) * (4.2 + float(growth_index % 2)), 0.242, sin(growth_angle) * 3.6), Vector3(0.48 + float(growth_index % 3) * 0.16, 0.02, 0.34 + float((growth_index + 1) % 3) * 0.13), {"collision": false, "variation": variation + float(growth_index) * 0.009, "semantic": "citadel_civic_drainage"})


static func add_civic_quarter(blueprint, keep_front_z: float, base_y: float, variation: float) -> void:
	add_part(blueprint, "urban_civic_quarter_paving", "foundation", "cobblestone", Vector3(43.0, base_y + 0.18, keep_front_z - 8.0), Vector3(48.0, 0.08, 32.0), {"collision": false, "variation": variation - 0.025, "semantic": "citadel_civic_quarter_paving"})
	var houses := [
		{"id": "urban_civic_house_east", "center": Vector3(43.0, 0.0, keep_front_z - 2.5), "width": 10.2, "depth": 12.0, "height": 9.3, "material": "painted_brick_ochre"},
		{"id": "urban_civic_house_wall", "center": Vector3(56.0, 0.0, keep_front_z - 14.0), "width": 8.8, "depth": 10.4, "height": 7.2, "material": "painted_brick_sage"}
	]
	for house_value in houses:
		var house: Dictionary = house_value as Dictionary
		add_street_house(blueprint, String(house.get("id", "urban_civic_house")), house.get("center", Vector3.ZERO) as Vector3, float(house.get("width", 8.0)), float(house.get("depth", 9.0)), float(house.get("height", 7.0)), -1.0, base_y, String(house.get("material", "painted_brick_cream")), variation + float(String(house.get("id", "house")).hash() % 17) * 0.003)
	for route_index in range(6):
		var route_x := 23.0 + float(route_index) * 6.1
		var route_z := keep_front_z - 13.5 + float(route_index % 2) * 5.2
		add_part(blueprint, "urban_civic_quarter_route_%02d" % route_index, "ground_patch", "worn_cobble", Vector3(route_x, base_y + 0.232, route_z), Vector3(7.4, 0.02, 4.2), {"collision": false, "variation": variation - 0.04 + float(route_index) * 0.008, "semantic": "citadel_civic_route_wear"})
	for corner_index in range(10):
		var corner_x := 30.0 + float(corner_index % 5) * 6.0
		var corner_z := keep_front_z - 19.0 + float(corner_index / 5) * 16.0
		add_part(blueprint, "urban_civic_quarter_growth_%02d" % corner_index, "ground_patch", "wall_growth", Vector3(corner_x, base_y + 0.242, corner_z), Vector3(0.48 + float(corner_index % 3) * 0.18, 0.02, 0.40 + float((corner_index + 1) % 3) * 0.14), {"collision": false, "variation": variation + float(corner_index) * 0.007, "semantic": "citadel_civic_drainage"})


static func add_civic_commons(blueprint, keep_front_z: float, base_y: float, variation: float) -> void:
	var center := Vector3(28.0, base_y + 0.244, keep_front_z - 18.0)
	for patch_index in range(18):
		var angle := float(patch_index) * 2.399963 + variation * 3.7
		var radius := 1.2 + float(patch_index % 6) * 0.58
		var phase := fposmod(sin(float(patch_index + 1) * 17.31 + variation * 41.0) * 21937.71, 1.0)
		var patch_center := center + Vector3(cos(angle) * radius, float(patch_index % 2) * 0.003, sin(angle) * radius * 0.72)
		var patch_material := "ground_soil" if patch_index % 5 == 0 else ("leaf_litter" if patch_index % 3 == 0 else "wall_growth")
		add_part(blueprint, "urban_civic_commons_patch_%02d" % patch_index, "ground_patch", patch_material, patch_center, Vector3(0.42 + phase * 0.74, 0.02, 0.34 + fposmod(phase * 2.41, 1.0) * 0.66), {"rotation": Vector3(0.0, phase * TAU, 0.0), "collision": false, "variation": variation - 0.05 + phase * 0.04, "semantic": "citadel_civic_commons_growth"})
	for stone_index in range(9):
		var angle := float(stone_index) * TAU / 9.0 + 0.31
		var phase := fposmod(sin(float(stone_index + 3) * 12.73) * 17357.19, 1.0)
		var stone_center := center + Vector3(cos(angle) * (2.2 + phase * 1.3), 0.13 + phase * 0.08, sin(angle) * (1.55 + phase * 0.9))
		add_part(blueprint, "urban_civic_commons_stone_%02d" % stone_index, "decor", "stone_foundation", stone_center, Vector3(0.36 + phase * 0.52, 0.24 + phase * 0.22, 0.32 + (1.0 - phase) * 0.46), {"rotation": Vector3(phase * 0.11, angle, (phase - 0.5) * 0.16), "collision": false, "variation": variation - 0.04 + phase * 0.03, "semantic": "citadel_civic_commons_stone"})
	add_part(blueprint, "urban_civic_commons_bench", "decor", "timber_board", center + Vector3(0.8, 0.34, 3.3), Vector3(2.8, 0.17, 0.48), {"rotation": Vector3(0.0, deg_to_rad(-11.0), 0.0), "collision": false, "variation": variation - 0.02, "semantic": "citadel_civic_commons_seating"})
	for leg_side in [-1.0, 1.0]:
		add_part(blueprint, "urban_civic_commons_bench_leg_%d" % int(leg_side), "beam", "timber_beam", center + Vector3(0.8 + leg_side * 0.92, 0.18, 3.3), Vector3(0.15, 0.36, 0.36), {"rotation": Vector3(0.0, deg_to_rad(-11.0), 0.0), "collision": false, "variation": variation, "semantic": "citadel_civic_commons_seating"})


static func add_market_stall_household(blueprint, stall_center: Vector3, side: float, depth_slot: float, variation: float) -> void:
	var stall_key := "%d_%d" % [int(side), int(depth_slot)]
	var canopy_material := "wool_rust" if side * depth_slot < 0.0 else "wool_moss"
	add_part(blueprint, "urban_market_compaction_%s" % stall_key, "ground_patch", "worn_cobble", stall_center + Vector3(-side * 2.10, 0.035, -depth_slot * 0.08), Vector3(4.85, 0.02, 1.46 + (0.18 if depth_slot > 0.0 else 0.0)), {"collision": false, "variation": variation - 0.04, "semantic": "citadel_market_compaction"})
	for post_side in [-1.0, 1.0]:
		for post_depth in [-1.0, 1.0]:
			add_part(blueprint, "urban_market_knee_%s_%d_%d" % [stall_key, int(post_side), int(post_depth)], "beam", "timber_beam", stall_center + Vector3(post_side * 1.04, 2.14, post_depth * 0.72), Vector3(0.14, 0.92, 0.14), {"rotation": Vector3(0.0, 0.0, post_side * deg_to_rad(43.0)), "collision": false, "variation": variation + post_depth * 0.01, "semantic": "citadel_market_joinery"})
	for canopy_face in [-1.0, 1.0]:
		for strip_index in range(6):
			var strip_x := stall_center.x - 1.45 + float(strip_index) * 0.58
			var sag := 0.035 * absf(float(strip_index) - 2.5)
			var strip_material := "linen" if strip_index == (2 if side > 0.0 else 4) and canopy_face > 0.0 else canopy_material
			add_part(blueprint, "urban_market_canopy_%s_%d_%02d" % [stall_key, int(canopy_face), strip_index], "decor", strip_material, Vector3(strip_x, stall_center.y + 2.54 + sag, stall_center.z + canopy_face * 0.57), Vector3(0.56, 0.075, 1.30), {"rotation": Vector3(canopy_face * deg_to_rad(11.0 + float(strip_index % 3) * 0.8), 0.0, side * deg_to_rad(2.0 + float(strip_index % 2))), "collision": false, "variation": variation + canopy_face * 0.01 + float(strip_index) * 0.006, "semantic": "citadel_market_canopy"})
	add_part(blueprint, "urban_market_canopy_ridge_%s" % stall_key, "beam", "timber_beam", stall_center + Vector3(0.0, 2.68, 0.0), Vector3(3.55, 0.14, 0.14), {"collision": false, "variation": variation, "semantic": "citadel_market_canopy_ridge"})
	add_part(blueprint, "urban_market_lantern_frame_%s" % stall_key, "decor", "ironwork", stall_center + Vector3(0.0, 2.18, 0.0), Vector3(0.22, 0.42, 0.22), {"collision": false, "variation": variation, "semantic": "citadel_urban_lantern_frame"})
	add_part(blueprint, "urban_market_lantern_flame_%s" % stall_key, "decor", "candle_flame", stall_center + Vector3(0.0, 2.16, 0.0), Vector3(0.11, 0.20, 0.11), {"collision": false, "variation": variation, "semantic": "citadel_urban_lantern_flame"})
	for counter_board in range(5):
		add_part(blueprint, "urban_market_counter_%s_%02d" % [stall_key, counter_board], "decor", "timber_board", stall_center + Vector3(-1.14 + float(counter_board) * 0.57, 0.78 + float((counter_board + int(side)) % 3) * 0.012, -depth_slot * 0.10), Vector3(0.55, 0.15, 0.78), {"rotation": Vector3(0.0, deg_to_rad(float(counter_board - 2) * 0.7), 0.0), "collision": false, "variation": variation + float(counter_board) * 0.009, "semantic": "citadel_market_counter"})
	for leg_side in [-1.0, 1.0]:
		add_part(blueprint, "urban_market_counter_leg_%s_%d" % [stall_key, int(leg_side)], "beam", "timber_beam", stall_center + Vector3(leg_side * 1.18, 0.39, 0.0), Vector3(0.18, 0.78, 0.52), {"collision": false, "variation": variation, "semantic": "citadel_market_counter_leg"})
	add_part(blueprint, "urban_market_counter_shelf_%s" % stall_key, "decor", "timber_board", stall_center + Vector3(0.0, 0.31, 0.0), Vector3(2.65, 0.12, 0.66), {"collision": false, "variation": variation, "semantic": "citadel_market_counter_shelf"})
	var goods := [
		{"kind": "pottery", "material": "ceramic_glaze", "size": Vector3(0.34, 0.42, 0.34)},
		{"kind": "sack", "material": "linen", "size": Vector3(0.38, 0.46, 0.34)},
		{"kind": "basket", "material": "timber_board", "size": Vector3(0.42, 0.34, 0.42)},
		{"kind": "sack", "material": "wool_rust", "size": Vector3(0.34, 0.38, 0.32)},
		{"kind": "pottery", "material": "painted_decor", "size": Vector3(0.31, 0.36, 0.31)}
	]
	for goods_index in range(goods.size()):
		var good: Dictionary = goods[goods_index] as Dictionary
		var goods_phase := fposmod(sin(float(goods_index + 1) * 15.71 + side * 7.3 + depth_slot * 11.9) * 31757.13, 1.0)
		if goods_phase < 0.16:
			continue
		var goods_x := stall_center.x - 1.05 + float(goods_index) * 0.52 + (goods_phase - 0.5) * 0.20
		var goods_size: Vector3 = good.get("size", Vector3(0.30, 0.30, 0.30)) as Vector3
		add_part(blueprint, "urban_market_goods_%s_%02d" % [stall_key, goods_index], String(good.get("kind", "pottery")), String(good.get("material", "ceramic_glaze")), Vector3(goods_x, stall_center.y + 0.88 + goods_size.y * 0.5, stall_center.z - depth_slot * 0.10 + (goods_phase - 0.5) * 0.34), goods_size, {"rotation": Vector3(0.0, goods_phase * TAU, 0.0), "collision": false, "variation": variation + float(goods_index) * 0.012, "semantic": "citadel_market_goods"})
	for storage_index in range(2):
		var storage_phase := fposmod(sin(float(storage_index + 1) * 21.17 + side * 5.1 + depth_slot * 9.7) * 11369.37, 1.0)
		var storage_z := stall_center.z + depth_slot * (1.18 + float(storage_index) * 0.76) + (storage_phase - 0.5) * 0.42
		add_part(blueprint, "urban_market_barrel_%s_%02d" % [stall_key, storage_index], "barrel", "timber_board", Vector3(stall_center.x + side * (1.42 + storage_phase * 0.32), stall_center.y + 0.50, storage_z), Vector3(0.72, 1.0, 0.72), {"rotation": Vector3(0.0, storage_phase * TAU, 0.0), "collision": false, "variation": variation + float(storage_index) * 0.025, "semantic": "citadel_market_storage"})
		if storage_index == 0 or storage_phase > 0.42:
			add_part(blueprint, "urban_market_crate_%s_%02d" % [stall_key, storage_index], "crate", "timber_board", Vector3(stall_center.x - side * (1.05 - float(storage_index) * 0.18), stall_center.y + 0.33 + float(storage_index) * 0.13, storage_z + (storage_phase - 0.5) * 0.28), Vector3(0.62, 0.66 + float(storage_index) * 0.24, 0.62), {"rotation": Vector3(0.0, (storage_phase - 0.5) * 0.42, 0.0), "collision": false, "variation": variation + float(storage_index) * 0.018, "semantic": "citadel_market_storage"})
	var seating_phase := fposmod(sin(side * 17.0 + depth_slot * 31.0 + variation * 43.0) * 17357.19, 1.0)
	if seating_phase > 0.28:
		var bench_center := stall_center + Vector3((seating_phase - 0.5) * 0.72, 0.36, -depth_slot * (1.48 + seating_phase * 0.34))
		var bench_rotation := (seating_phase - 0.5) * deg_to_rad(12.0)
		add_part(blueprint, "urban_market_bench_%s" % stall_key, "decor", "timber_board", bench_center, Vector3(1.85 + seating_phase * 0.74, 0.16, 0.46), {"rotation": Vector3(0.0, bench_rotation, 0.0), "collision": false, "variation": variation, "semantic": "citadel_market_seating"})
		for bench_leg in [-1.0, 1.0]:
			add_part(blueprint, "urban_market_bench_leg_%s_%d" % [stall_key, int(bench_leg)], "beam", "timber_beam", bench_center + Vector3(bench_leg * (0.68 + seating_phase * 0.18), -0.18, 0.0), Vector3(0.14, 0.36, 0.34), {"rotation": Vector3(0.0, bench_rotation, 0.0), "collision": false, "variation": variation, "semantic": "citadel_market_seating"})


static func add_overhead_bridge(blueprint, center: Vector3, span: float, base_y: float, variation: float) -> void:
	add_part(blueprint, "urban_bridge_deck", "floor", "timber_beam", Vector3(center.x, base_y + 6.9, center.z), Vector3(span, 0.34, 2.4), {"variation": variation, "semantic": "citadel_overhead_bridge"})
	for side in [-1.0, 1.0]:
		add_part(blueprint, "urban_bridge_rail_%d" % int(side), "beam", "timber_beam", Vector3(center.x, base_y + 7.55, center.z + side * 1.05), Vector3(span, 1.0, 0.18), {"collision": false, "variation": variation, "semantic": "citadel_overhead_bridge_rail"})


static func add_civic_landmark(blueprint, center: Vector3, base_y: float, variation: float) -> void:
	var width := 8.4
	var depth := 9.0
	var height := 17.0
	add_part(blueprint, "urban_civic_tower", "wall", "painted_brick_cream", Vector3(center.x, base_y + height * 0.5, center.z), Vector3(width, height, depth), {"variation": variation, "semantic": "citadel_civic_landmark"})
	for level in [4.2, 8.0, 11.8]:
		add_part(blueprint, "urban_civic_window_%d" % int(level * 10.0), "window", "window_glass", Vector3(center.x + width * 0.5 + 0.04, base_y + level, center.z), Vector3(0.10, 1.45, 1.05), {"collision": false, "variation": variation, "semantic": "citadel_civic_window"})
	var roof_rise := 6.8
	var slope := sqrt(pow(width * 0.5 + 0.6, 2.0) + roof_rise * roof_rise)
	var angle := atan2(roof_rise, width * 0.5 + 0.6)
	add_part(blueprint, "urban_civic_roof_left", "roof", "roof_shingle", Vector3(center.x - width * 0.25, base_y + height + roof_rise * 0.5, center.z), Vector3(slope, 0.28, depth + 1.0), {"rotation": Vector3(0.0, 0.0, angle), "variation": variation - 0.03, "semantic": "citadel_civic_roof"})
	add_part(blueprint, "urban_civic_roof_right", "roof", "roof_shingle", Vector3(center.x + width * 0.25, base_y + height + roof_rise * 0.5, center.z), Vector3(slope, 0.28, depth + 1.0), {"rotation": Vector3(0.0, 0.0, -angle), "variation": variation - 0.03, "semantic": "citadel_civic_roof"})
	add_part(blueprint, "urban_civic_banner", "sign", "painted_decor", Vector3(center.x + width * 0.5 + 0.08, base_y + 10.0, center.z), Vector3(0.10, 3.2, 1.45), {"collision": false, "variation": variation, "semantic": "citadel_civic_banner"})


static func add_terraced_edge(blueprint, center: Vector3, base_y: float, variation: float) -> void:
	for level in range(3):
		var terrace_y := base_y + float(level) * 0.72
		var terrace_z := center.z + float(level) * 2.4
		add_part(blueprint, "urban_terrace_%02d" % level, "foundation", "stone_foundation", Vector3(center.x, terrace_y + 0.36, terrace_z), Vector3(12.0 - float(level) * 1.4, 0.72, 4.8), {"variation": variation, "semantic": "citadel_urban_terrace"})
		for step in range(4):
			add_part(blueprint, "urban_terrace_step_%02d_%02d" % [level, step], "stair_tread", "stone_foundation", Vector3(center.x - 6.6 + float(step) * 0.42, base_y + float(level) * 0.72 + float(step + 1) * 0.18, terrace_z - 2.0 + float(step) * 0.42), Vector3(1.5, 0.18, 0.46), {"variation": variation, "semantic": "citadel_urban_stair"})


static func add_dressing_clusters(blueprint, front_z: float, keep_front_z: float, base_y: float, variation: float) -> void:
	var clusters: Array[Vector3] = [Vector3(-6.8, 0.0, front_z + 18.0), Vector3(11.0, 0.0, keep_front_z - 10.0)]
	for index in range(clusters.size()):
		var center: Vector3 = clusters[index]
		var awning_material := "wool_rust" if index % 2 == 0 else "wool_moss"
		for strip_index in range(6):
			add_part(blueprint, "urban_awning_%02d_%02d" % [index, strip_index], "decor", awning_material, Vector3(center.x - 1.45 + float(strip_index) * 0.58, base_y + 2.35 + absf(float(strip_index) - 2.5) * 0.025, center.z), Vector3(0.56, 0.075, 1.76), {"rotation": Vector3(deg_to_rad(-9.0), 0.0, 0.0), "collision": false, "variation": variation + float(index) * 0.02 + float(strip_index) * 0.005, "semantic": "citadel_market_awning"})
		for support_side in [-1.0, 1.0]:
			add_part(blueprint, "urban_awning_support_%02d_%d" % [index, int(support_side)], "beam", "timber_beam", Vector3(center.x + support_side * 1.52, base_y + 1.18, center.z + 0.52), Vector3(0.16, 2.36, 0.16), {"collision": false, "variation": variation, "semantic": "citadel_market_awning_support"})
		for crate_index in range(3):
			add_part(blueprint, "urban_crate_%02d_%02d" % [index, crate_index], "crate", "timber_board", Vector3(center.x - 1.1 + float(crate_index) * 0.82, base_y + 0.34, center.z + 0.8), Vector3(0.68, 0.68 + float(crate_index % 2) * 0.25, 0.68), {"collision": false, "variation": variation, "semantic": "citadel_market_crate"})
	for banner_index in range(5):
		var banner_z := front_z + 12.0 + float(banner_index) * 8.0
		var banner_x := -4.1 if banner_index % 2 == 0 else 7.2
		add_part(blueprint, "urban_street_banner_%02d" % banner_index, "sign", "painted_decor", Vector3(banner_x, base_y + 5.4, banner_z), Vector3(0.12, 2.3, 1.0), {"collision": false, "variation": variation + float(banner_index) * 0.01, "semantic": "citadel_street_banner"})


static func add_bunting_lines(blueprint, front_z: float, keep_front_z: float, base_y: float, variation: float, urban_layout: Dictionary) -> void:
	var market_lane_x := float(urban_layout.get("marketLaneX", MARKET_LANE_X))
	var market_terrace_rise := float(urban_layout.get("marketTerraceRise", MARKET_TERRACE_RISE))
	var lines := [
		{"start": -4.2, "end": 5.8, "z": front_z + 20.0, "y": base_y + 5.8},
		{"start": market_lane_x - 8.0, "end": market_lane_x + 8.0, "z": front_z + 33.5, "y": base_y + market_terrace_rise + 6.0},
		{"start": 3.0, "end": 20.0, "z": keep_front_z - 9.0, "y": base_y + market_terrace_rise * 2.0 + 5.4}
	]
	var cloth_materials: Array[String] = ["wool_rust", "linen", "wool_moss"]
	for line_index in range(lines.size()):
		var line: Dictionary = lines[line_index] as Dictionary
		var start_x := float(line.get("start", 0.0))
		var end_x := float(line.get("end", 0.0))
		var line_y := float(line.get("y", base_y + 5.5))
		var line_z := float(line.get("z", front_z))
		add_part(blueprint, "urban_bunting_rope_%02d" % line_index, "beam", "ironwork", Vector3((start_x + end_x) * 0.5, line_y + 0.33, line_z), Vector3(end_x - start_x, 0.035, 0.035), {"collision": false, "variation": variation, "semantic": "citadel_bunting_rope"})
		var pennant_count := 9 if line_index == 0 else 13
		for pennant_index in range(pennant_count):
			var ratio := (float(pennant_index) + 0.5) / float(pennant_count)
			var pennant_x := lerpf(start_x, end_x, ratio)
			var sag := sin(ratio * PI) * 0.28
			var material := cloth_materials[(line_index + pennant_index) % cloth_materials.size()]
			add_part(blueprint, "urban_bunting_%02d_%02d" % [line_index, pennant_index], "pennant", material, Vector3(pennant_x, line_y - sag, line_z), Vector3(maxf(0.38, (end_x - start_x) / float(pennant_count) * 0.56), 0.68, 0.055), {"rotation": Vector3(0.0, 0.0, deg_to_rad(-8.0 if pennant_index % 2 == 0 else 8.0)), "collision": false, "variation": variation + float(pennant_index) * 0.006, "semantic": "citadel_bunting"})


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


static func stable_unit(seed: int, channel: String) -> float:
	return float(stable_hash("%d:%s" % [seed, channel]) & 0x7fffffff) / float(0x7fffffff)


static func stable_hash(text: String) -> int:
	var hash_value := 2166136261
	for index in range(text.length()):
		hash_value = int((hash_value ^ text.unicode_at(index)) * 16777619) & 0xffffffff
	return hash_value
