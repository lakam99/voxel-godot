extends RefCounted
class_name CastleCompoundBlueprintBuilder

## Turns the deterministic castle member list into one ordinary construction
## blueprint.  The visual PoC and later settlement publication therefore share
## recipe sampling, part records, materials and collision publication.

const BuildingBlueprintScript := preload("res://scripts/buildings/BuildingBlueprint.gd")
const CottageRecipeSamplerScript := preload("res://scripts/buildings/CottageRecipeSampler.gd")
const CottageBlueprintBuilderScript := preload("res://scripts/buildings/CottageBlueprintBuilder.gd")
const LandmarkBuildingRecipeSamplerScript := preload("res://scripts/buildings/LandmarkBuildingRecipeSampler.gd")
const LandmarkBuildingBlueprintBuilderScript := preload("res://scripts/buildings/LandmarkBuildingBlueprintBuilder.gd")


static func build(seed: int, raw_context: Dictionary = {}):
	var context := raw_context.duplicate(true)
	context["settlementTier"] = "city"
	context["style"] = "masonry"
	return build_from_compound(LandmarkBuildingRecipeSamplerScript.sample_compound(seed, "castle", context))


static func build_keep_poc(seed: int, raw_context: Dictionary = {}):
	var context := raw_context.duplicate(true)
	context["settlementTier"] = "city"
	context["style"] = "masonry"
	var compound: Dictionary = LandmarkBuildingRecipeSamplerScript.sample_compound(seed, "castle", context)
	var grammar: Dictionary = compound.get("castleGrammar", {}) as Dictionary
	var members: Array = compound.get("members", []) as Array
	var keep_recipe := member_recipe(members, "keep")
	var keep_width := float(grammar.get("keepWidth", keep_recipe.get("width", 26.0)))
	var keep_depth := float(grammar.get("keepDepth", keep_recipe.get("depth", 24.0)))
	var keep_height := float(grammar.get("keepHeight", float(keep_recipe.get("floorHeight", 3.7)) * 4.0))
	var reference_floor_height := clampf(float(keep_recipe.get("floorHeight", 3.70)), 3.20, 4.20)
	var storey_count := clampi(roundi(keep_height / reference_floor_height), 3, 24)
	var floor_height := keep_height / float(storey_count)
	var foundation_height := 0.62
	var palace_grammar: Dictionary = grammar.get("palaceGrammar", {}) as Dictionary
	var enclosed_storey_count := clampi(int(palace_grammar.get("hallStoreys", 4)), 1, storey_count)
	var masonry_palette: Dictionary = grammar.get("citadelMasonry", {}) as Dictionary
	var fortification_material := String(masonry_palette.get("fortification", "fired_brick"))
	var variation := float(seed % 19) / 100.0 - 0.09
	var blueprint = BuildingBlueprintScript.new("poc.keep.%d.%s" % [seed, String(context.get("siteKey", "keep-poc"))], seed, "masonry")
	blueprint.set_recipe({
		"schemaVersion": int(compound.get("schemaVersion", 1)),
		"family": "keep",
		"seed": seed,
		"context": context.duplicate(true),
		"castleGrammar": grammar.duplicate(true),
		"palaceGrammar": palace_grammar.duplicate(true),
		"width": keep_width,
		"depth": keep_depth,
		"wallHeight": keep_height,
		"floorCount": storey_count,
		"floorHeight": floor_height,
		"foundationHeight": foundation_height,
		"landmarkRole": "citadel_palace"
	})
	var room_records: Array = [
		{"id": "castle_keep", "role": "great_hall", "bounds": AABB(Vector3(-keep_width * 0.5, foundation_height, -keep_depth * 0.5), Vector3(keep_width, keep_height, keep_depth)), "wallMountInset": 0.22, "accesses": []}
	]
	append_keep_storey_room_records(room_records, Vector3.ZERO, keep_width, keep_depth, foundation_height, floor_height, enclosed_storey_count)
	blueprint.set_room_records(room_records)
	add_keep(blueprint, Vector3.ZERO, keep_width, keep_depth, keep_height, storey_count, floor_height, foundation_height, variation, fortification_material, palace_grammar)
	return blueprint


static func build_from_compound(compound: Dictionary):
	var members: Array = compound.get("members", []) as Array
	var keep_recipe := member_recipe(members, "keep")
	var gatehouse_recipe := member_recipe(members, "gatehouse")
	var courtyard_recipe := member_recipe(members, "courtyard")
	var tower_recipes := member_recipes(members, "tower")
	var seed := int(compound.get("seed", 0))
	var context: Dictionary = compound.get("context", {}) as Dictionary
	var grammar: Dictionary = compound.get("castleGrammar", {}) as Dictionary
	var variation := float(seed % 19) / 100.0 - 0.09
	var masonry_palette: Dictionary = grammar.get("citadelMasonry", {}) as Dictionary
	var palace_grammar: Dictionary = grammar.get("palaceGrammar", {}) as Dictionary
	var fortification_material := String(masonry_palette.get("fortification", "fired_brick"))
	var courtyard_width := float(grammar.get("courtyardWidth", courtyard_recipe.get("width", 46.0)))
	var courtyard_depth := float(grammar.get("courtyardDepth", courtyard_recipe.get("depth", 42.0)))
	var tower_span := float(grammar.get("towerSpan", (tower_recipes[0] as Dictionary).get("width", 6.4) if not tower_recipes.is_empty() else 6.4))
	var tower_count := clampi(int(grammar.get("towerCount", 4)), 4, 8)
	var wall_height := float(grammar.get("wallHeight", float(gatehouse_recipe.get("floorHeight", 3.6)) * 1.70))
	var tower_height_base := float(grammar.get("towerHeightBase", float((tower_recipes[0] as Dictionary).get("floorHeight", 3.6)) * 3.4 if not tower_recipes.is_empty() else 12.4))
	var tower_height_variation := float(grammar.get("towerHeightVariation", 0.16))
	var keep_width := minf(float(grammar.get("keepWidth", float(keep_recipe.get("width", 26.0)) * 0.52)), courtyard_width - tower_span * 2.50)
	var keep_depth := minf(float(grammar.get("keepDepth", float(keep_recipe.get("depth", 24.0)) * 0.48)), courtyard_depth - tower_span * 2.50)
	var keep_height := float(grammar.get("keepHeight", float(keep_recipe.get("floorHeight", 3.7)) * float(maxi(3, int(keep_recipe.get("floorCount", 4))))))
	# Castle grammar predates an explicit storey count, but its sampled height is
	# already derived from an ordinary floor height.  Reconstruct the occupied
	# levels here so the physical keep never advertises a multi-storey silhouette
	# while containing one uninterrupted empty volume.
	var keep_reference_floor_height := clampf(float(keep_recipe.get("floorHeight", 3.70)), 3.20, 4.20)
	var keep_storey_count := clampi(roundi(keep_height / keep_reference_floor_height), 3, 24)
	var keep_floor_height := keep_height / float(keep_storey_count)
	var gate_width := minf(float(grammar.get("gateWidth", gatehouse_recipe.get("width", 11.0))), courtyard_width * 0.42)
	var gate_depth := float(grammar.get("gateDepth", gatehouse_recipe.get("depth", 9.0)))
	var gate_height := maxf(wall_height + 1.80, float(grammar.get("gateHeight", float(gatehouse_recipe.get("floorHeight", 3.6)) * 2.30)))
	var foundation_height := 0.62
	var keep_foundation_height := foundation_height + citadel_keep_terrace_elevation(grammar)
	var keep_offset: Dictionary = grammar.get("keepOffset", {}) as Dictionary
	# The gate is centred at x = 0, and the keep must stay on that same axis.
	# Do not reintroduce side offsets here: the main axis is a castle invariant.
	var keep_center := Vector3(0.0, 0.0, courtyard_depth * float(keep_offset.get("z", 0.14)))
	var tower_specs := tower_specs_for_grammar(seed, courtyard_width, courtyard_depth, tower_count, tower_span, tower_height_base, tower_height_variation, int(grammar.get("towerPhase", 0)))
	var courtyard_program: Array = grammar.get("courtyardProgram", []) as Array
	var enclosed_keep_storey_count := clampi(int(palace_grammar.get("hallStoreys", 4)), 1, keep_storey_count)
	var courtyard_buildings := courtyard_building_specs(courtyard_program, courtyard_width, courtyard_depth, keep_center, keep_width, keep_depth, gate_width, tower_specs, seed, context, masonry_palette)
	var blueprint = BuildingBlueprintScript.new("compound.castle.%d.%s" % [seed, String(context.get("siteKey", "citadel"))], seed, "masonry")
	blueprint.set_recipe({
		"schemaVersion": int(compound.get("schemaVersion", 1)),
		"family": "castle",
		"compound": compound.duplicate(true),
		"seed": seed,
		"context": context.duplicate(true),
		"castleGrammar": grammar.duplicate(true),
		"style": "masonry",
		"width": courtyard_width + tower_span * 1.10,
		"depth": courtyard_depth + tower_span * 1.10 + gate_depth * 0.58,
		"floorCount": keep_storey_count,
		"keepStoreyCount": keep_storey_count,
		"keepFloorHeight": keep_floor_height,
		"citadelMasonry": masonry_palette.duplicate(true),
		"wallHeight": keep_height,
		"towerCount": tower_specs.size(),
		"courtyardBuildingCount": courtyard_buildings.size(),
		# These are resolved source recipes and transforms, not a second castle
		# house authority.  CastleFurnishingPlanner rebuilds these exact shared
		# source blueprints before transforming their seeded furnishing plans.
		"courtyardResidences": courtyard_buildings.duplicate(true),
		"foundationHeight": foundation_height,
		"landmarkRole": "fortified_compound"
	})
	var room_records: Array = [
		{"id": "castle_courtyard", "role": "courtyard", "bounds": AABB(Vector3(-courtyard_width * 0.5, foundation_height, -courtyard_depth * 0.5), Vector3(courtyard_width, wall_height, courtyard_depth)), "wallMountInset": 0.22, "accesses": []},
		{"id": "castle_keep", "role": "great_hall", "bounds": AABB(Vector3(keep_center.x - keep_width * 0.5, keep_foundation_height, keep_center.z - keep_depth * 0.5), Vector3(keep_width, keep_height, keep_depth)), "wallMountInset": 0.22, "accesses": []}
	]
	append_keep_storey_room_records(room_records, keep_center, keep_width, keep_depth, keep_foundation_height, keep_floor_height, enclosed_keep_storey_count)
	for building_value in courtyard_buildings:
		var building: Dictionary = building_value as Dictionary
		var building_center: Vector3 = building.get("center", Vector3.ZERO) as Vector3
		var building_width := float(building.get("width", 6.0))
		var building_depth := float(building.get("depth", 6.0))
		var building_height := float((building.get("residenceRecipe", {}) as Dictionary).get("wallHeight", building.get("height", 4.0)))
		# A residence record is the one graph node occupying a wall lane. Its
		# inherited rooms follow below and must not be mistaken for neighbour
		# buildings by compound-level clearance validation.
		room_records.append({"id": String(building.get("id", "courtyard_building")), "role": String(building.get("kind", "residence")), "bounds": AABB(Vector3(building_center.x - building_width * 0.5, foundation_height, building_center.z - building_depth * 0.5), Vector3(building_width, building_height, building_depth)), "wallMountInset": 0.20, "accesses": [], "castleCourtyardResidence": true, "castleResidenceFamily": String(building.get("residenceFamily", "cottage"))})
		append_courtyard_residence_rooms(room_records, building, foundation_height)
	blueprint.set_room_records(room_records)

	# The courtyard is a physical, paved interior of the perimeter—not an empty
	# ground plane placed underneath a decorative wall ring.
	add_part(blueprint, "castle_courtyard_foundation", "foundation", "stone_foundation", Vector3(0.0, foundation_height * 0.5, 0.0), Vector3(courtyard_width, foundation_height, courtyard_depth), {"variation": variation, "semantic": "castle_courtyard_foundation"})
	add_part(blueprint, "castle_courtyard_paving", "foundation", "cobblestone", Vector3(0.0, foundation_height + 0.07, 0.0), Vector3(courtyard_width - 0.82, 0.14, courtyard_depth - 0.82), {"variation": variation + 0.03, "semantic": "castle_courtyard_paving"})
	add_citadel_terraces(blueprint, grammar, courtyard_width, courtyard_depth, foundation_height, variation)

	var half_width := courtyard_width * 0.5
	var half_depth := courtyard_depth * 0.5
	for index in range(tower_specs.size()):
		var tower_spec: Dictionary = tower_specs[index] as Dictionary
		add_tower(blueprint, "castle_tower_%02d" % (index + 1), tower_spec.get("position", Vector3.ZERO) as Vector3, float(tower_spec.get("span", tower_span)), float(tower_spec.get("height", tower_height_base)), foundation_height, variation + float(index) * 0.006, fortification_material)

	# Four curtain runs terminate against the corner towers. The front run is
	# deliberately split around the real gatehouse instead of covering a gate
	# visual with a continuous collision wall.
	var front_z := -half_depth
	var back_z := half_depth
	var left_x := -half_width
	var right_x := half_width
	var northwest_span := tower_span_for_role(tower_specs, "northwest", tower_span)
	var northeast_span := tower_span_for_role(tower_specs, "northeast", tower_span)
	var southeast_span := tower_span_for_role(tower_specs, "southeast", tower_span)
	var southwest_span := tower_span_for_role(tower_specs, "southwest", tower_span)
	add_curtain_x_segment(blueprint, "castle_front_wall_left", front_z, -half_width + northwest_span * 0.5, -gate_width * 0.5, wall_height, foundation_height, variation, fortification_material)
	add_curtain_x_segment(blueprint, "castle_front_wall_right", front_z, gate_width * 0.5, half_width - northeast_span * 0.5, wall_height, foundation_height, variation, fortification_material)
	add_curtain_x_segment(blueprint, "castle_back_wall", back_z, -half_width + southwest_span * 0.5, half_width - southeast_span * 0.5, wall_height, foundation_height, variation, fortification_material)
	add_curtain_z_segment(blueprint, "castle_left_wall", left_x, -half_depth + northwest_span * 0.5, half_depth - southwest_span * 0.5, wall_height, foundation_height, variation, fortification_material)
	add_curtain_z_segment(blueprint, "castle_right_wall", right_x, -half_depth + northeast_span * 0.5, half_depth - southwest_span * 0.5, wall_height, foundation_height, variation, fortification_material)

	add_gatehouse(blueprint, gate_width, gate_depth, gate_height, foundation_height, front_z, variation, fortification_material)
	add_keep(blueprint, keep_center, keep_width, keep_depth, keep_height, keep_storey_count, keep_floor_height, keep_foundation_height, variation, fortification_material, palace_grammar)
	add_district_streets(blueprint, grammar, foundation_height, variation)
	add_citadel_urban_room_dressing(blueprint, grammar, foundation_height, variation)
	for building_value in courtyard_buildings:
		add_courtyard_outbuilding(blueprint, building_value as Dictionary, foundation_height)
	add_citadel_residence_facade_details(blueprint, courtyard_buildings, grammar, foundation_height, variation)
	add_part(blueprint, "castle_banner_gate", "sign", "painted_decor", Vector3(0.0, foundation_height + gate_height * 0.72, front_z - gate_depth * 0.54), Vector3(1.32, 2.30, 0.10), {"variation": variation, "collision": false, "semantic": "castle_banner"})
	return blueprint


static func append_keep_storey_room_records(records: Array, center: Vector3, width: float, depth: float, foundation_height: float, floor_height: float, storey_count: int) -> void:
	# These are ordinary room records for the occupied keep levels.  The shared
	# furnishing/layout authority can now see the same vertical circulation that
	# the construction builder publishes below instead of treating the keep as a
	# single impossible room spanning every floor.
	var roles: Array[String] = ["great_hall", "guard_chamber", "armory", "archive", "private_chamber", "watch_chamber", "roof_watch", "roof_watch"]
	var stairwell := keep_stairwell_layout(center, width, depth)
	var stair_center: Vector3 = stairwell.get("center", center) as Vector3
	var stair_width := float(stairwell.get("width", 3.20))
	var stair_depth := float(stairwell.get("depth", 5.00))
	for level in range(storey_count):
		var level_y := foundation_height + floor_height * float(level)
		var access_kind := "stair_up" if level < storey_count - 1 else "stair_down"
		records.append({
			"id": "castle_keep_storey_%02d" % level,
			"role": roles[mini(level, roles.size() - 1)],
			"bounds": AABB(Vector3(center.x - width * 0.5 + 0.74, level_y, center.z - depth * 0.5 + 0.74), Vector3(width - 1.48, floor_height, depth - 1.48)),
			"wallMountInset": 0.22,
			"accesses": [{"id": "keep_stair_%02d" % level, "kind": access_kind, "position": Vector3(stair_center.x, level_y + 0.86, stair_center.z), "size": Vector3(stair_width, 2.20, stair_depth)}],
			"castleKeepStorey": level
		})


static func keep_stairwell_layout(center: Vector3, width: float, depth: float) -> Dictionary:
	# The stairwell sits in the rear-right quarter of the keep.  It is wide enough
	# for a true two-flight stair, remains inside the structural walls, and leaves
	# the entry axis and great hall clear for normal play.
	var stair_width := clampf(width * 0.22, 3.10, 4.30)
	var stair_depth := clampf(depth * 0.38, 4.80, 6.40)
	var interior_right := center.x + width * 0.5 - 0.76
	var interior_back := center.z + depth * 0.5 - 0.76
	return {
		"center": Vector3(interior_right - stair_width * 0.5, 0.0, interior_back - stair_depth * 0.5),
		"width": stair_width,
		"depth": stair_depth
	}


static func member_recipe(members: Array, family: String) -> Dictionary:
	for value in members:
		if value is Dictionary and String((value as Dictionary).get("family", "")) == family:
			return ((value as Dictionary).get("recipe", {}) as Dictionary).duplicate(true)
	return {}


static func member_recipes(members: Array, family: String) -> Array:
	var result: Array = []
	for value in members:
		if value is Dictionary and String((value as Dictionary).get("family", "")) == family:
			result.append(((value as Dictionary).get("recipe", {}) as Dictionary).duplicate(true))
	return result


static func tower_specs_for_grammar(seed: int, courtyard_width: float, courtyard_depth: float, tower_count: int, base_span: float, base_height: float, height_variation: float, phase: int) -> Array[Dictionary]:
	# Corners carry the perimeter structurally. Extra towers come in mirrored
	# pairs around the gate-to-keep axis. A centre-front tower would occupy the
	# real gatehouse passage, so the gate is flanked rather than blocked.
	var resolved_count := 4 if tower_count <= 4 else (6 if tower_count <= 6 else 8)
	var normalized_positions: Array[Dictionary] = [
		{"role": "northwest", "x": -0.5, "z": -0.5},
		{"role": "northeast", "x": 0.5, "z": -0.5},
		{"role": "southeast", "x": 0.5, "z": 0.5},
		{"role": "southwest", "x": -0.5, "z": 0.5}
	]
	if resolved_count >= 6:
		normalized_positions.append({"role": "north_gate_flank_left", "x": -0.28, "z": -0.5})
		normalized_positions.append({"role": "north_gate_flank_right", "x": 0.28, "z": -0.5})
	if resolved_count >= 8:
		normalized_positions.append({"role": "south_wall_flank_left", "x": -0.28, "z": 0.5})
		normalized_positions.append({"role": "south_wall_flank_right", "x": 0.28, "z": 0.5})
	var rng := RandomNumberGenerator.new()
	rng.seed = int(("%d|castle.tower.specs" % seed).hash())
	var specs: Array[Dictionary] = []
	for source_value in normalized_positions:
		var source: Dictionary = source_value as Dictionary
		var span := snappedf(base_span * rng.randf_range(0.88, 1.18), 0.20)
		var height := snappedf(base_height * rng.randf_range(1.0 - height_variation, 1.0 + height_variation), 0.20)
		specs.append({
			"role": String(source.get("role", "tower")),
			"position": Vector3(courtyard_width * float(source.get("x", 0.0)), 0.0, courtyard_depth * float(source.get("z", 0.0))),
			"span": span,
			"height": height
		})
	return specs


static func tower_span_for_role(specs: Array[Dictionary], role: String, fallback: float) -> float:
	for spec in specs:
		if String(spec.get("role", "")) == role:
			return float(spec.get("span", fallback))
	return fallback


static func courtyard_building_specs(program: Array, courtyard_width: float, courtyard_depth: float, keep_center: Vector3, keep_width: float, keep_depth: float, gate_width: float, tower_specs: Array[Dictionary], seed: int, context: Dictionary, masonry_palette: Dictionary) -> Array[Dictionary]:
	# This is a small city-block plan, not a first-fit search.  Each pair owns a
	# named row and band: outer blocks are held back from the curtain wall, then
	# a few inner blocks occupy protected front rows with a planned street between
	# them.  The keep and its axial gate-to-door route remain public space.
	var graph_nodes := courtyard_city_grid_nodes()
	var result: Array[Dictionary] = []
	# Inner rows are a genuine front block. Their centres advance from the
	# gatehouse by their actual seeded depths, so a wide cottage never overlaps
	# its neighbour just because the compound reused a nominal normalized row.
	var front_city_cursor := courtyard_inner_front_cursor(courtyard_depth, tower_specs)
	var outer_front_cursor := front_city_cursor
	var inner_front_cursor := front_city_cursor
	for index in range(0, program.size(), 2):
		if index + 1 >= program.size() or not program[index] is Dictionary or not program[index + 1] is Dictionary:
			push_error("Castle courtyard program has an incomplete symmetry pair")
			continue
		var left_source: Dictionary = program[index] as Dictionary
		var right_source: Dictionary = program[index + 1] as Dictionary
		if String(left_source.get("mirrorSide", "")) != "left" or String(right_source.get("mirrorSide", "")) != "right" or String(left_source.get("symmetryGroup", "")) != String(right_source.get("symmetryGroup", "")):
			push_error("Castle courtyard program lost its left/right symmetry pairing")
			continue
		# A district lot carries an already-resolved, seed-derived grid coordinate.
		# The smaller profiles retain the named five-column grammar below.  Both
		# paths still sample and publish the same cottage/manor blueprints.
		var district_grid := String(left_source.get("cityGridMode", "")) == "district"
		var requested_node := String(left_source.get("graphNode", "gate_outer"))
		var node: Dictionary = graph_nodes.get(requested_node, graph_nodes["gate_outer"]) as Dictionary
		var grid_row := int(left_source.get("cityGridRow", -1)) if district_grid else int(node.get("row", -1))
		var grid_band := String(left_source.get("cityGridBand", "district")) if district_grid else String(node.get("band", "outer"))
		var left_residence := sample_courtyard_residence(seed, left_source, courtyard_width, courtyard_depth, context)
		var right_residence := sample_courtyard_residence(seed, right_source, courtyard_width, courtyard_depth, context) if district_grid else left_residence
		var left_residence_recipe: Dictionary = left_residence.get("recipe", {}) as Dictionary
		var right_residence_recipe: Dictionary = right_residence.get("recipe", {}) as Dictionary
		# Each shared residence is built with its door down local -Z. North/south
		# frontage keeps the source axes in world space; east/west frontage rotates
		# them ninety degrees. The footprint proof must use that same transform or
		# a Golden-Lane lot could be visibly clear yet be rejected as a false overlap.
		var left_swaps_axes := String(left_source.get("frontDirection", "")) not in ["north", "south"]
		var right_swaps_axes := String(right_source.get("frontDirection", "")) not in ["north", "south"]
		var left_width := float(left_residence_recipe.get("depth", 6.0)) if left_swaps_axes else float(left_residence_recipe.get("width", 8.0))
		var left_depth := float(left_residence_recipe.get("width", 8.0)) if left_swaps_axes else float(left_residence_recipe.get("depth", 6.0))
		var right_width := float(right_residence_recipe.get("depth", 6.0)) if right_swaps_axes else float(right_residence_recipe.get("width", 8.0))
		var right_depth := float(right_residence_recipe.get("width", 8.0)) if right_swaps_axes else float(right_residence_recipe.get("depth", 6.0))
		var selected_left := Vector3.ZERO
		var selected_right := Vector3.ZERO
		if district_grid:
			# The sampler allocates pairs from the curtain wall toward the keep and
			# gate toward the rear.  Do not first-fit them here: the exact footprint
			# guard below is only a safety proof, not another placement authority.
			selected_left = Vector3(float(left_source.get("gridCenterX", 0.0)), 0.0, float(left_source.get("gridCenterZ", 0.0)))
			selected_right = Vector3(float(right_source.get("gridCenterX", 0.0)), 0.0, float(right_source.get("gridCenterZ", 0.0)))
		else:
			selected_left = courtyard_city_block_center(-1.0, node, left_width, left_depth, courtyard_width, courtyard_depth, gate_width, tower_specs)
			selected_right = courtyard_city_block_center(1.0, node, right_width, right_depth, courtyard_width, courtyard_depth, gate_width, tower_specs)
		if not district_grid and grid_band == "inner":
			var inner_row_z := courtyard_front_city_block_z(inner_front_cursor, maxf(left_depth, right_depth))
			selected_left.z = inner_row_z
			selected_right.z = inner_row_z
			# A small cross-street separates these successive front-block rows.
			inner_front_cursor = inner_row_z + maxf(left_depth, right_depth) * 0.5 + 1.50
		elif not district_grid:
			# Preserve the seed-selected outer-grid row whenever it is usable, but
			# never start it inside the gate's flanking towers or the prior block.
			var outer_depth := maxf(left_depth, right_depth)
			var outer_row_min_z := courtyard_front_city_block_z(outer_front_cursor, outer_depth)
			var outer_row_max_z := courtyard_depth * 0.5 - 2.60 - outer_depth * 0.5
			var outer_row_z := minf(outer_row_max_z, maxf(selected_left.z, outer_row_min_z))
			selected_left.z = outer_row_z
			selected_right.z = outer_row_z
			outer_front_cursor = outer_row_z + outer_depth * 0.5 + 1.50
		# A compound is mirrored at the block level even when individual corner
		# tower spans vary. Use the more restrictive curtain-side setback for both
		# lots instead of letting one side drift closer to its wall.
		if not district_grid:
			var shared_abs_x := minf(absf(selected_left.x), absf(selected_right.x))
			selected_left.x = -shared_abs_x
			selected_right.x = shared_abs_x
		var lot_clearance := 0.08 if district_grid else 1.30
		if footprint_overlaps(selected_left, left_width, left_depth, selected_right, right_width, right_depth, 2.60) or not courtyard_building_footprint_is_clear(selected_left, left_width, left_depth, keep_center, keep_width, keep_depth, tower_specs, result, lot_clearance) or not courtyard_building_footprint_is_clear(selected_right, right_width, right_depth, keep_center, keep_width, keep_depth, tower_specs, result, lot_clearance):
			push_error("Castle seed %d planned city block %s has no clear footprint" % [seed, String(left_source.get("symmetryGroup", "pair"))])
			continue
		var left_spec := left_source.duplicate(true)
		left_spec["center"] = selected_left
		left_spec["resolvedNode"] = "district_block_row_%d_band_%d_left" % [grid_row, int(left_source.get("cityGridColumn", 0))] if district_grid else "city_block_row_%d_%s_left" % [grid_row, grid_band]
		left_spec["cityGridRow"] = grid_row
		left_spec["cityGridBand"] = grid_band
		left_spec["cityGridColumn"] = int(left_source.get("cityGridColumn", 0)) if district_grid else (0 if grid_band == "outer" else 1)
		left_spec["cityGridMode"] = "district" if district_grid else "compact"
		left_spec["width"] = left_width
		left_spec["depth"] = left_depth
		left_spec["residenceFamily"] = String(left_residence.get("family", "cottage"))
		left_spec["residenceRecipe"] = left_residence_recipe.duplicate(true)
		left_spec["residenceFacadeMaterial"] = residence_facade_material(seed, String(left_spec.get("id", "left")), masonry_palette)
		left_spec["terraceElevation"] = float(left_source.get("terraceElevation", 0.0))
		append_residence_transform(left_spec, castle_foundation_height_for_residence(left_residence_recipe))
		result.append(left_spec)
		var right_spec := right_source.duplicate(true)
		right_spec["center"] = selected_right
		right_spec["resolvedNode"] = "district_block_row_%d_band_%d_right" % [grid_row, int(right_source.get("cityGridColumn", 0))] if district_grid else "city_block_row_%d_%s_right" % [grid_row, grid_band]
		right_spec["cityGridRow"] = grid_row
		right_spec["cityGridBand"] = grid_band
		right_spec["cityGridColumn"] = int(right_source.get("cityGridColumn", 0)) if district_grid else (4 if grid_band == "outer" else 3)
		right_spec["cityGridMode"] = "district" if district_grid else "compact"
		right_spec["width"] = right_width
		right_spec["depth"] = right_depth
		right_spec["residenceFamily"] = String(right_residence.get("family", "cottage"))
		right_spec["residenceRecipe"] = right_residence_recipe.duplicate(true)
		right_spec["residenceFacadeMaterial"] = residence_facade_material(seed, String(right_spec.get("id", "right")), masonry_palette)
		right_spec["terraceElevation"] = float(right_source.get("terraceElevation", 0.0))
		append_residence_transform(right_spec, castle_foundation_height_for_residence(right_residence_recipe))
		result.append(right_spec)
	return result


static func residence_facade_material(castle_seed: int, residence_id: String, masonry_palette: Dictionary) -> String:
	# Most inner-city homes take a painted façade, with a minority retaining the
	# civic masonry colour. Stable lot ids make visual personality deterministic
	# without breaking the mirrored street graph or replaying spatial RNG.
	var rng := RandomNumberGenerator.new()
	rng.seed = int(("%d|castle.residence.facade|%s" % [castle_seed, residence_id]).hash())
	var civic_material := String(masonry_palette.get("fortification", "fired_brick"))
	var residences: Array = masonry_palette.get("residences", [civic_material]) as Array
	if residences.is_empty() or rng.randf() < 0.16:
		return civic_material
	return String(residences[rng.randi_range(0, residences.size() - 1)])


static func courtyard_city_grid_nodes() -> Dictionary:
	# Grid rows run gate (4) to rear wall (0).  The outer band begins at the
	# curtain walls with a service setback. The only inner lots are in front of
	# the keep, where their door streets lead to the public axis rather than
	# dead-ending against its masonry.
	return {
		"gate_outer": {"z": -0.34, "row": 4, "band": "outer"},
		"lower_outer": {"z": -0.10, "row": 3, "band": "outer"},
		"middle_outer": {"z": 0.10, "row": 2, "band": "outer"},
		"rear_outer": {"z": 0.30, "row": 0, "band": "outer"},
		"gate_inner": {"z": -0.44, "row": 4, "band": "inner"},
		"lower_inner": {"z": -0.30, "row": 3, "band": "inner"}
	}


static func courtyard_city_block_center(side: float, node: Dictionary, width: float, depth: float, courtyard_width: float, courtyard_depth: float, gate_width: float, tower_specs: Array[Dictionary]) -> Vector3:
	var wall_setback := 2.60
	var street_width := 3.20
	var half_width := courtyard_width * 0.5
	var side_tower_setback := courtyard_side_tower_setback(side, half_width, tower_specs)
	var max_x := maxf(0.0, half_width - maxf(wall_setback, side_tower_setback) - width * 0.5)
	var max_z := maxf(0.0, courtyard_depth * 0.5 - wall_setback - depth * 0.5)
	var route_half_width := maxf(2.40, gate_width * 0.5 + 1.00)
	var band := String(node.get("band", "outer"))
	var x := half_width - maxf(wall_setback, side_tower_setback) - width * 0.5
	if band == "inner":
		x = route_half_width + width * 0.5 + street_width
	return Vector3(side * minf(max_x, x), 0.0, clampf(courtyard_depth * float(node.get("z", 0.0)), -max_z, max_z))


static func courtyard_front_city_block_z(front_cursor: float, depth: float) -> float:
	return front_cursor + depth * 0.5


static func courtyard_side_tower_setback(side: float, half_width: float, tower_specs: Array[Dictionary]) -> float:
	var result := 0.0
	for tower_spec in tower_specs:
		var tower_position: Vector3 = tower_spec.get("position", Vector3.ZERO) as Vector3
		# Only the towers seated on this curtain wall reserve its service lane;
		# the two gate flanks are handled by the front-row cursor instead.
		if signf(tower_position.x) != signf(side) or absf(tower_position.x) < half_width * 0.70:
			continue
		result = maxf(result, float(tower_spec.get("span", 0.0)) * 0.5 + 0.34)
	return result


static func courtyard_inner_front_cursor(courtyard_depth: float, tower_specs: Array[Dictionary]) -> float:
	# Gatehouse flank towers are part of the deterministic compound grammar, not
	# optional scenery. Start the first inner block after their physical depth so
	# every grid row has a real cross-street from the gate instead of clipping a
	# tower's foundation on six/eight-tower variants.
	var front_setback := 2.70
	for tower_spec in tower_specs:
		if String(tower_spec.get("role", "")).begins_with("north_gate_flank"):
			front_setback = maxf(front_setback, float(tower_spec.get("span", 0.0)) * 0.5 + 0.34)
	return -courtyard_depth * 0.5 + front_setback


static func castle_foundation_height_for_residence(_residence_recipe: Dictionary) -> float:
	# This remains one compound foundation datum.  Keeping it in this helper
	# prevents the construction and furnishing transforms from quietly diverging.
	return 0.62


static func citadel_keep_terrace_elevation(grammar: Dictionary) -> float:
	var grid: Dictionary = grammar.get("courtyardGrid", {}) as Dictionary
	if String(grid.get("mode", "")) != "district_grid":
		return 0.0
	var courtyard_depth := float(grammar.get("courtyardDepth", 0.0))
	var keep_depth := float(grammar.get("keepDepth", 0.0))
	var keep_offset: Dictionary = grammar.get("keepOffset", {}) as Dictionary
	var keep_front_z := courtyard_depth * float(keep_offset.get("z", 0.14)) - keep_depth * 0.5
	return citadel_terrace_elevation_at_z(grid, keep_front_z)


static func append_residence_transform(spec: Dictionary, castle_foundation_height: float) -> void:
	var center: Vector3 = spec.get("center", Vector3.ZERO) as Vector3
	var recipe: Dictionary = spec.get("residenceRecipe", {}) as Dictionary
	var source_foundation_height := float(recipe.get("foundationHeight", 0.48))
	# Cottage/manor source doors point down local -Z. District homes choose the
	# nearest boulevard or cross-street as their frontage, so a city block reads
	# as connected streets instead of every door staring at the keep wall.
	var front_direction := String(spec.get("frontDirection", ""))
	var yaw := PI * 0.5 if center.x > 0.0 else -PI * 0.5
	match front_direction:
		"north":
			yaw = 0.0
		"south":
			yaw = PI
		"east":
			yaw = -PI * 0.5
		"west":
			yaw = PI * 0.5
	spec["yaw"] = yaw
	spec["origin"] = Vector3(center.x, castle_foundation_height - source_foundation_height + float(spec.get("terraceElevation", 0.0)), center.z)


static func sample_courtyard_residence(castle_seed: int, source: Dictionary, courtyard_width: float, courtyard_depth: float, context: Dictionary) -> Dictionary:
	# Courtyard homes reuse the real cottage/manor grammars. Compact baileys use
	# cottages; broad compounds can earn larger paired manor forms on their outer
	# keep flank. The choice is deterministic and source-size-aware, never a
	# hand-picked showcase building.
	var node := String(source.get("graphNode", "gate_inner"))
	var residence_seed := int(("%d|castle.courtyard.residence|%s" % [castle_seed, String(source.get("symmetryGroup", "pair"))]).hash())
	# A manor needs a much deeper wall lane than a compact/walled bailey can
	# guarantee after its keep, tower clearances and mirrored neighbour have
	# reserved their space. Grand citadels satisfy that physical condition;
	# smaller compounds remain richly varied cottages instead of forcing overlap.
	# Dense live rows remain cottages, while the grand-only outer keep flank can
	# carry paired compact manors without cutting across the central passage.
	# Exact lot clearance below is still authoritative for every seed.
	var supports_manor := courtyard_width >= 76.0 and courtyard_depth >= 66.0 and node == "middle_outer"
	if supports_manor:
		var manor_context := context.duplicate(true)
		manor_context["settlementTier"] = "city"
		manor_context["siteKey"] = "castle-courtyard"
		manor_context["style"] = "masonry"
		return {"family": "manor", "recipe": courtyard_manor_recipe(LandmarkBuildingRecipeSamplerScript.sample(residence_seed, "manor", manor_context))}
	if String(source.get("cityGridMode", "")) == "district":
		var district_rng := RandomNumberGenerator.new()
		district_rng.seed = int(("%d|castle.district.wealthy.family" % residence_seed).hash())
		var district_class := String(source.get("districtClass", ""))
		# The dense lane remains mainly cottage frontage, but occasional narrow
		# two-storey manors break its roofline. Inner lots have the much higher manor
		# share expected of the keep-adjacent wealthier district.
		var manor_chance := 1.0 if district_class == "sightline_screen" else 0.0 if district_class == "civic_anchor" else 0.20 if district_class == "golden_lane" else 0.82 if district_class == "civic" else 0.58 if district_class == "wealthy" else 0.0
		if district_rng.randf() < manor_chance:
			var manor_context := context.duplicate(true)
			manor_context["settlementTier"] = "city"
			manor_context["siteKey"] = "castle-%s-district" % district_class
			manor_context["style"] = "masonry"
			return {"family": "manor", "recipe": district_manor_recipe(LandmarkBuildingRecipeSamplerScript.sample(residence_seed, "manor", manor_context), source)}
	var cottage_recipe := CottageRecipeSamplerScript.sample(residence_seed, "masonry")
	if String(source.get("cityGridMode", "")) == "district":
		cottage_recipe = district_cottage_recipe(cottage_recipe, source, residence_seed)
	return {"family": "cottage", "recipe": cottage_recipe}


static func district_cottage_recipe(raw_recipe: Dictionary, source: Dictionary, residence_seed: int) -> Dictionary:
	# A district cell is a genuine urban lot, not a tiny rural cottage placed at
	# the centre of a 28m square.  This remains the same cottage grammar and
	# furnishing path, with its dimensions constrained by the sampled lot so the
	# populated citadel reads as a city while retaining street and door clearance.
	var recipe := raw_recipe.duplicate(true)
	var lot_width := float(source.get("width", 24.0))
	var lot_depth := float(source.get("depth", 24.0))
	var district_class := String(source.get("districtClass", "district"))
	var east_west_frontage := String(source.get("frontDirection", "")) in ["east", "west"]
	var rng := RandomNumberGenerator.new()
	rng.seed = int(("%d|castle.district.cottage.lot" % residence_seed).hash())
	# Golden Lane uses the whole narrow frontage: wall gaps are kept to a minimum
	# so roof eaves almost meet, while the shallower depth keeps the shared lane
	# in front of both doors usable. Wealthy lots retain a smaller building within
	# their wider ground reservation.
	if district_class == "golden_lane":
		recipe["width"] = snappedf(clampf((lot_depth if east_west_frontage else lot_width) * rng.randf_range(0.95, 0.99), 11.8, 12.8), 0.20)
		recipe["depth"] = snappedf(clampf((lot_width if east_west_frontage else lot_depth) * rng.randf_range(0.78, 0.86), 8.8, 13.8), 0.20)
	else:
		recipe["width"] = snappedf(clampf((lot_depth if east_west_frontage else lot_width) * rng.randf_range(0.94, 0.98), 11.6, 12.8), 0.20)
		recipe["depth"] = snappedf(clampf((lot_width if east_west_frontage else lot_depth) * rng.randf_range(0.72, 0.82), 9.8, 14.8), 0.20)
	var floor_height := float(recipe.get("floorHeight", 3.45))
	if district_class == "civic_anchor":
		recipe["width"] = snappedf(clampf(float(recipe.get("width", 10.0)), 8.8, 10.6), 0.20)
		recipe["depth"] = snappedf(clampf(float(recipe.get("depth", 8.0)), 7.0, 8.8), 0.20)
	var floor_count := 2 if district_class == "civic_anchor" else 3 if district_class == "civic" or (district_class == "golden_lane" and rng.randf() < 0.34) else 2
	recipe["floorCount"] = floor_count
	recipe["wallHeight"] = snappedf(floor_height * float(floor_count), 0.05)
	recipe["districtLot"] = district_class
	return recipe


static func district_manor_recipe(raw_recipe: Dictionary, source: Dictionary) -> Dictionary:
	# A district manor is still a normal manor recipe. Golden-Lane variants share
	# the tight row-house frontage; wealthy variants use the same builder with
	# their intentionally more generous site reservation.
	var recipe := raw_recipe.duplicate(true)
	var floor_height := float(recipe.get("floorHeight", 3.55))
	var lot_width := float(source.get("width", 28.0))
	var lot_depth := float(source.get("depth", 16.0))
	var district_class := String(source.get("districtClass", ""))
	var east_west_frontage := String(source.get("frontDirection", "")) in ["east", "west"]
	var is_golden_lane := district_class == "golden_lane"
	var frontage_ratio := 0.98 if is_golden_lane else 0.88 if district_class == "sightline_screen" else 0.72
	var depth_ratio := 0.82 if is_golden_lane else 0.82
	var source_width_limit := lot_width * 0.98 if district_class == "sightline_screen" else float(recipe.get("width", 16.0))
	recipe["width"] = snappedf(minf(source_width_limit, (lot_depth if east_west_frontage else lot_width) * (0.98 if east_west_frontage else frontage_ratio)), 0.20)
	recipe["depth"] = snappedf(minf(float(recipe.get("depth", 12.0)), (lot_width if east_west_frontage else lot_depth) * (0.92 if district_class == "sightline_screen" else depth_ratio)), 0.20)
	# The manor grammar publishes at most three occupied body levels. Declaring a
	# fourth level here only extends its stair tower and internal stair stack above
	# the inhabited roofline, making the screen compete with the palace crown.
	recipe["floorCount"] = 3 if district_class == "sightline_screen" or district_class == "civic_anchor" else mini(3, maxi(2, int(recipe.get("floorCount", 2))))
	recipe["wallHeight"] = snappedf(floor_height * float(recipe["floorCount"]), 0.05)
	recipe["districtLot"] = "golden_lane_manor" if is_golden_lane else "wealthy_manor"
	return recipe


static func courtyard_manor_recipe(raw_recipe: Dictionary) -> Dictionary:
	# This is a lot constraint, not a second manor builder.  A courtyard manor
	# still goes through LandmarkBuildingBlueprintBuilder and its ordinary room,
	# stair, roof and furnishing grammar; the compound merely reserves a compact
	# urban lot so several real homes can coexist around the keep.
	var recipe := raw_recipe.duplicate(true)
	var floor_height := float(recipe.get("floorHeight", 3.55))
	var floor_count := mini(2, maxi(2, int(recipe.get("floorCount", 2))))
	recipe["width"] = minf(float(recipe.get("width", 16.0)), 14.00)
	recipe["depth"] = minf(float(recipe.get("depth", 12.0)), 10.00)
	recipe["floorCount"] = floor_count
	recipe["wallHeight"] = snappedf(floor_height * float(floor_count), 0.05)
	recipe["castleCourtyardLot"] = "compact_manor"
	return recipe


static func courtyard_building_footprint_is_clear(center: Vector3, width: float, depth: float, keep_center: Vector3, keep_width: float, keep_depth: float, tower_specs: Array[Dictionary], placed: Array[Dictionary], neighbour_clearance := 1.30) -> bool:
	if footprint_overlaps(center, width, depth, keep_center, keep_width, keep_depth, 0.04):
		return false
	for tower_spec in tower_specs:
		var tower_center: Vector3 = tower_spec.get("position", Vector3.ZERO) as Vector3
		var tower_span := float(tower_spec.get("span", 6.4)) + 0.54
		if footprint_overlaps(center, width, depth, tower_center, tower_span, tower_span, 0.04):
			return false
	for placed_spec in placed:
		var placed_center: Vector3 = placed_spec.get("center", Vector3.ZERO) as Vector3
		if footprint_overlaps(center, width, depth, placed_center, float(placed_spec.get("width", 7.0)), float(placed_spec.get("depth", 6.0)), neighbour_clearance):
			return false
	return true


static func footprint_overlaps(first_center: Vector3, first_width: float, first_depth: float, second_center: Vector3, second_width: float, second_depth: float, clearance := 0.0) -> bool:
	return absf(first_center.x - second_center.x) < (first_width + second_width) * 0.5 + clearance and absf(first_center.z - second_center.z) < (first_depth + second_depth) * 0.5 + clearance


static func add_district_streets(blueprint, grammar: Dictionary, foundation_height: float, variation: float) -> void:
	# Streets are part of the compound grammar, not omitted ground between a
	# collection of homes. They remain non-colliding paving because the existing
	# courtyard foundation owns the walkable physical surface underneath.
	var grid: Dictionary = grammar.get("courtyardGrid", {}) as Dictionary
	if String(grid.get("mode", "")) != "district_grid":
		return
	var street_records: Array = grid.get("streetRecords", []) as Array
	for record_value in street_records:
		if not record_value is Dictionary:
			continue
		var record: Dictionary = record_value as Dictionary
		var width := float(record.get("width", 0.0))
		var depth := float(record.get("depth", 0.0))
		if width <= 0.20 or depth <= 0.20:
			continue
		var street_elevation := float(record.get("elevation", citadel_terrace_elevation_at_z(grid, float(record.get("z", 0.0)))))
		var street_id := String(record.get("id", "street"))
		var center := Vector3(float(record.get("x", 0.0)), foundation_height + street_elevation + 0.155, float(record.get("z", 0.0)))
		var runs_along_z := depth >= width
		var longitudinal_span := depth if runs_along_z else width
		var available_cross_span := width if runs_along_z else depth
		var base_channel_span := minf(3.45, available_cross_span * 0.60)
		var module_count := clampi(int(ceil(longitudinal_span / 1.9)), 2, 72)
		var module_run := longitudinal_span / float(module_count)
		for module_index in range(module_count):
			var stable_phase := float((street_id.hash() + module_index * 17) % 9)
			var width_bias := (stable_phase - 4.0) * 0.045
			var module_cross_span := clampf(base_channel_span + width_bias, base_channel_span * 0.86, available_cross_span * 0.68)
			var lateral_offset := sin(float(module_index) * 1.73 + float(street_id.hash() % 11)) * 0.12
			var longitudinal_offset := -longitudinal_span * 0.5 + module_run * (float(module_index) + 0.5)
			var module_center := center + (Vector3(lateral_offset, 0.008 + absf(lateral_offset) * 0.02, longitudinal_offset) if runs_along_z else Vector3(longitudinal_offset, 0.008 + absf(lateral_offset) * 0.02, lateral_offset))
			var module_size := Vector3(module_cross_span, 0.07, module_run + 0.035) if runs_along_z else Vector3(module_run + 0.035, 0.07, module_cross_span)
			add_part(blueprint, "castle_district_%s_cobble_%03d" % [street_id, module_index], "foundation", "cobblestone", module_center, module_size, {"variation": variation - 0.035 + width_bias * 0.4, "collision": false, "semantic": "castle_route_cobbled_module"})
		var cross_span := width if runs_along_z else depth
		var margin_span := maxf(0.34, (cross_span - base_channel_span) * 0.5)
		for side in [-1.0, 1.0]:
			var margin_offset: float = side * (base_channel_span * 0.5 + margin_span * 0.5)
			var margin_center := center + (Vector3(margin_offset, 0.012, 0.0) if runs_along_z else Vector3(0.0, 0.012, margin_offset))
			var margin_size := Vector3(margin_span, 0.045, depth) if runs_along_z else Vector3(width, 0.045, margin_span)
			add_part(blueprint, "castle_district_%s_margin_%d" % [street_id, int(side)], "foundation", "stone_foundation", margin_center, margin_size, {"variation": variation + 0.035 + side * 0.006, "collision": false, "semantic": "castle_route_pedestrian_margin"})
		var drain_offset := base_channel_span * 0.5 + 0.16
		var drain_center := center + (Vector3(drain_offset, 0.022, 0.0) if runs_along_z else Vector3(0.0, 0.022, drain_offset))
		var drain_size := Vector3(0.28, 0.055, depth) if runs_along_z else Vector3(width, 0.055, 0.28)
		add_part(blueprint, "castle_district_%s_drain" % street_id, "foundation", "stone_foundation", drain_center, drain_size, {"collision": false, "variation": variation - 0.08, "semantic": "castle_route_constructed_gutter"})


static func add_citadel_terraces(blueprint, grammar: Dictionary, courtyard_width: float, courtyard_depth: float, foundation_height: float, variation: float) -> void:
	var grid: Dictionary = grammar.get("courtyardGrid", {}) as Dictionary
	if String(grid.get("mode", "")) != "district_grid":
		return
	var row_centers: Array = grid.get("rowCenters", []) as Array
	if row_centers.is_empty():
		return
	var boulevard_half_width := float(grid.get("boulevardHalfWidth", 7.0))
	var route_centers: Array = grid.get("routeCenters", []) as Array
	var front_z := -courtyard_depth * 0.5 + 1.2
	var previous_elevation := 0.0
	for row_index in range(row_centers.size()):
		var row_z := float(row_centers[row_index])
		var next_z := float(row_centers[row_index + 1]) if row_index + 1 < row_centers.size() else courtyard_depth * 0.5 - 1.2
		var elevation := citadel_terrace_elevation_at_z(grid, row_z)
		var depth := maxf(1.0, next_z - front_z)
		var route_x := float(route_centers[mini(row_index, route_centers.size() - 1)]) if not route_centers.is_empty() else 0.0
		var route_clear_half_width := boulevard_half_width * 1.12
		var terrace_min_x := -courtyard_width * 0.5 + 1.2
		var terrace_max_x := courtyard_width * 0.5 - 1.2
		var left_edge := route_x - route_clear_half_width
		var right_edge := route_x + route_clear_half_width
		var terrace_center_z := front_z + depth * 0.5
		var left_width := maxf(0.0, left_edge - terrace_min_x)
		var right_width := maxf(0.0, terrace_max_x - right_edge)
		if left_width > 0.2:
			add_part(blueprint, "castle_terrace_block_%02d_left" % row_index, "foundation", "stone_foundation", Vector3(terrace_min_x + left_width * 0.5, foundation_height + elevation * 0.5, terrace_center_z), Vector3(left_width, maxf(0.12, elevation), depth), {"variation": variation - 0.025, "semantic": "castle_inhabited_terrace_block"})
		if right_width > 0.2:
			add_part(blueprint, "castle_terrace_block_%02d_right" % row_index, "foundation", "stone_foundation", Vector3(right_edge + right_width * 0.5, foundation_height + elevation * 0.5, terrace_center_z), Vector3(right_width, maxf(0.12, elevation), depth), {"variation": variation - 0.025, "semantic": "castle_inhabited_terrace_block"})
		if elevation > 0.1:
			for retaining_side in [-1.0, 1.0]:
				add_part(blueprint, "castle_terrace_route_wall_%02d_%d" % [row_index, int(retaining_side)], "wall", "stone_foundation", Vector3(route_x + retaining_side * route_clear_half_width, foundation_height + elevation * 0.5, terrace_center_z), Vector3(0.28, elevation, depth), {"variation": variation - 0.035, "semantic": "castle_terrace_route_retaining_wall"})
		if elevation > previous_elevation + 0.01:
			add_citadel_processional_steps(blueprint, "castle_terrace_stair_%02d" % row_index, route_x, row_z - 1.6, route_clear_half_width * 1.82, previous_elevation, elevation, foundation_height, variation)
		previous_elevation = elevation
		front_z = next_z


static func add_citadel_urban_room_dressing(blueprint, grammar: Dictionary, foundation_height: float, variation: float) -> void:
	var grid: Dictionary = grammar.get("courtyardGrid", {}) as Dictionary
	var rooms: Dictionary = grid.get("urbanRooms", {}) as Dictionary
	if rooms.is_empty():
		return
	var gate: Dictionary = rooms.get("gate", {}) as Dictionary
	var gate_center: Vector3 = gate.get("center", Vector3.ZERO) as Vector3
	var gate_width := float(gate.get("width", 16.0))
	var gate_depth := float(gate.get("depth", 8.0))
	for side in [-1.0, 1.0]:
		var edge_x: float = gate_center.x + side * gate_width * 0.42
		for use_index in range(3):
			var use_z := gate_center.z + lerpf(-gate_depth * 0.26, gate_depth * 0.26, float(use_index) / 2.0)
			add_part(blueprint, "castle_gate_frontage_counter_%d_%02d" % [int(side), use_index], "decor", "timber_board", Vector3(edge_x, foundation_height + 0.72, use_z), Vector3(0.58, 0.18, 1.05), {"collision": false, "variation": variation + float(use_index) * 0.01, "semantic": "castle_gate_frontage_use"})
			add_part(blueprint, "castle_gate_frontage_goods_%d_%02d" % [int(side), use_index], "decor", "painted_decor", Vector3(edge_x, foundation_height + 0.98, use_z), Vector3(0.34, 0.34, 0.48), {"collision": false, "variation": variation + float(use_index) * 0.02, "semantic": "castle_gate_frontage_goods"})
	var palace: Dictionary = rooms.get("palace", {}) as Dictionary
	var palace_center: Vector3 = palace.get("center", Vector3.ZERO) as Vector3
	var palace_width := float(palace.get("width", 24.0))
	var palace_depth := float(palace.get("depth", 10.0))
	for side in [-1.0, 1.0]:
		var pocket_x: float = palace_center.x + side * palace_width * 0.38
		var pocket_z: float = palace_center.z - palace_depth * 0.28
		add_part(blueprint, "castle_palace_planting_bed_%d" % int(side), "foundation", "mortar", Vector3(pocket_x, foundation_height + palace_center.y + 0.10, pocket_z), Vector3(palace_width * 0.18, 0.08, palace_depth * 0.34), {"collision": false, "variation": variation + side * 0.01, "semantic": "castle_palace_planting_bed"})
		for planting_index in range(4):
			var planting_z := pocket_z + lerpf(-palace_depth * 0.12, palace_depth * 0.12, float(planting_index) / 3.0)
			add_part(blueprint, "castle_palace_planting_%d_%02d" % [int(side), planting_index], "decor", "wool_moss", Vector3(pocket_x, foundation_height + palace_center.y + 0.42, planting_z), Vector3(palace_width * 0.12, 0.50, palace_depth * 0.07), {"collision": false, "variation": variation + side * 0.01 + float(planting_index) * 0.005, "semantic": "castle_palace_planting"})
		add_part(blueprint, "castle_palace_room_banner_%d" % int(side), "sign", "painted_decor", Vector3(pocket_x, foundation_height + palace_center.y + 3.2, palace_center.z + palace_depth * 0.28), Vector3(0.72, 1.8, 0.10), {"collision": false, "variation": variation + side * 0.02, "semantic": "castle_palace_room_banner"})


static func add_citadel_route_necks(blueprint, grammar: Dictionary, residences: Array[Dictionary], foundation_height: float, variation: float) -> void:
	var grid: Dictionary = grammar.get("courtyardGrid", {}) as Dictionary
	var necks: Array = grid.get("routeNecks", []) as Array
	var masonry: Dictionary = grammar.get("citadelMasonry", {}) as Dictionary
	var material := String(masonry.get("fortification", "fired_brick"))
	for neck_value in necks:
		if not neck_value is Dictionary:
			continue
		var neck: Dictionary = neck_value as Dictionary
		var neck_id := String(neck.get("id", "route_neck"))
		var center: Vector3 = neck.get("center", Vector3.ZERO) as Vector3
		var clear_width := float(neck.get("clearWidth", 5.6))
		var clear_height := float(neck.get("clearHeight", 4.2))
		var projection_depth := float(neck.get("projectionDepth", 2.8))
		var runs_along_z := String(neck.get("direction", "z")) == "z"
		var hosts := citadel_route_neck_hosts(residences, center, runs_along_z)
		if hosts.size() != 2:
			continue
		var negative_host: Dictionary = hosts[0] as Dictionary
		var positive_host: Dictionary = hosts[1] as Dictionary
		var negative_center: Vector3 = negative_host.get("center", Vector3.ZERO) as Vector3
		var positive_center: Vector3 = positive_host.get("center", Vector3.ZERO) as Vector3
		var negative_cross_span := float(negative_host.get("width", 0.0)) if runs_along_z else float(negative_host.get("depth", 0.0))
		var positive_cross_span := float(positive_host.get("width", 0.0)) if runs_along_z else float(positive_host.get("depth", 0.0))
		var negative_inner_facade := negative_center.x + negative_cross_span * 0.5 if runs_along_z else negative_center.z + negative_cross_span * 0.5
		var positive_inner_facade := positive_center.x - positive_cross_span * 0.5 if runs_along_z else positive_center.z - positive_cross_span * 0.5
		var route_cross_center := center.x if runs_along_z else center.z
		var negative_inner_local := negative_inner_facade - route_cross_center
		var positive_inner_local := positive_inner_facade - route_cross_center
		var negative_structural_depth := float(negative_host.get("depth", 0.0)) if runs_along_z else float(negative_host.get("width", 0.0))
		var positive_structural_depth := float(positive_host.get("depth", 0.0)) if runs_along_z else float(positive_host.get("width", 0.0))
		var facade_gap := positive_inner_facade - negative_inner_facade
		var maximum_gap := clear_width + minf(negative_structural_depth, positive_structural_depth) * 0.72
		if facade_gap <= clear_width or facade_gap > maximum_gap:
			continue
		var room_height := 1.85
		var connector_floor_y := foundation_height + center.y + clear_height
		var bridge_center := Vector3(center.x, connector_floor_y + room_height * 0.5, center.z)
		var dominant_inner_edge := clear_width * 0.08
		var secondary_inner_edge := clear_width * 0.34
		var connector_center_axis := (dominant_inner_edge + secondary_inner_edge) * 0.5
		var connector_span := secondary_inner_edge - dominant_inner_edge + 0.18
		var negative_projection_span := absf(dominant_inner_edge - (negative_inner_local - 0.42))
		var positive_projection_span := absf(secondary_inner_edge - (positive_inner_local + 0.42))
		if negative_projection_span > negative_structural_depth * 0.82 or positive_projection_span > positive_structural_depth * 0.82:
			continue
		for side in [-1.0, 1.0]:
			var host: Dictionary = negative_host if side < 0.0 else positive_host
			var host_center: Vector3 = host.get("center", Vector3.ZERO) as Vector3
			var host_cross_span := float(host.get("width", 0.0)) if runs_along_z else float(host.get("depth", 0.0))
			var host_inner_world := host_center.x + host_cross_span * 0.5 if runs_along_z and side < 0.0 else host_center.x - host_cross_span * 0.5 if runs_along_z else host_center.z + host_cross_span * 0.5 if side < 0.0 else host_center.z - host_cross_span * 0.5
			var host_inner_edge := host_inner_world - route_cross_center
			var inner_edge: float = dominant_inner_edge if side < 0.0 else secondary_inner_edge
			var outer_edge := host_inner_edge - 0.42 if side < 0.0 else host_inner_edge + 0.42
			var projection_span := absf(inner_edge - outer_edge)
			var projection_offset := (inner_edge + outer_edge) * 0.5
			var wing_height := room_height if side < 0.0 else room_height * 0.78
			var wing_depth := projection_depth * 1.18 if side < 0.0 else projection_depth * 0.76
			var wing_lift := 0.0 if side < 0.0 else 0.42
			var host_material := String(host.get("residenceFacadeMaterial", material))
			var projection_center := bridge_center + Vector3(0.0, wing_lift, 0.0) + (Vector3(projection_offset, 0.0, -projection_depth * 0.10) if runs_along_z else Vector3(-projection_depth * 0.10, 0.0, projection_offset))
			var projection_size := Vector3(projection_span, wing_height, wing_depth) if runs_along_z else Vector3(wing_depth, wing_height, projection_span)
			add_part(blueprint, "castle_route_neck_%s_host_projection_%d" % [neck_id, int(side)], "wall", host_material, projection_center, projection_size, {"variation": variation - 0.015 + side * 0.008, "semantic": "castle_route_neck_host_projection", "hostResidenceId": String(host.get("id", ""))})
			var wing_roof_size := Vector3(projection_span + 0.34, 0.42, wing_depth + 0.38) if runs_along_z else Vector3(wing_depth + 0.38, 0.42, projection_span + 0.34)
			add_part(blueprint, "castle_route_neck_%s_host_roof_%d" % [neck_id, int(side)], "roof", "roof_shingle", projection_center + Vector3(0.0, wing_height * 0.5 + 0.22, 0.0), wing_roof_size, {"collision": false, "variation": variation + side * 0.008, "semantic": "castle_route_neck_host_roof"})
			var facade_window_count := 2 if projection_span >= 2.8 else 1
			for bay_index in range(facade_window_count):
				var bay_progress := (float(bay_index) + 1.0) / (float(facade_window_count) + 1.0)
				var bay_axis := lerpf(minf(inner_edge, outer_edge), maxf(inner_edge, outer_edge), bay_progress)
				var bay_center := projection_center
				if runs_along_z:
					bay_center.x = center.x + bay_axis
					bay_center.z += wing_depth * 0.5 + 0.025
				else:
					bay_center.z = center.z + bay_axis
					bay_center.x += wing_depth * 0.5 + 0.025
				var bay_size := Vector3(0.68, minf(1.10, wing_height * 0.62), 0.08) if runs_along_z else Vector3(0.08, minf(1.10, wing_height * 0.62), 0.68)
				add_part(blueprint, "castle_route_neck_%s_host_window_%d_%02d" % [neck_id, int(side), bay_index], "window", "window_glass", bay_center, bay_size, {"collision": false, "variation": variation + side * 0.01 + float(bay_index) * 0.004, "semantic": "castle_route_neck_occupied_bay"})
				var lintel_center := bay_center + Vector3(0.0, bay_size.y * 0.5 + 0.08, 0.0)
				var lintel_size := Vector3(bay_size.x + 0.24, 0.12, 0.12) if runs_along_z else Vector3(0.12, 0.12, bay_size.z + 0.24)
				add_part(blueprint, "castle_route_neck_%s_host_lintel_%d_%02d" % [neck_id, int(side), bay_index], "beam", "timber_beam", lintel_center, lintel_size, {"collision": false, "variation": variation, "semantic": "castle_route_neck_window_frame"})
			for frame_side in [-1.0, 1.0]:
				var frame_axis: float = projection_offset + frame_side * projection_span * 0.46
				var frame_center := projection_center
				if runs_along_z:
					frame_center.x = center.x + frame_axis
					frame_center.z += wing_depth * 0.5 + 0.035
				else:
					frame_center.z = center.z + frame_axis
					frame_center.x += wing_depth * 0.5 + 0.035
				var frame_size := Vector3(0.12, wing_height * 0.88, 0.10) if runs_along_z else Vector3(0.10, wing_height * 0.88, 0.12)
				add_part(blueprint, "castle_route_neck_%s_host_frame_%d_%d" % [neck_id, int(side), int(frame_side)], "beam", "timber_beam", frame_center, frame_size, {"collision": false, "variation": variation, "semantic": "castle_route_neck_host_frame"})
			var bond_axis: float = outer_edge + side * 0.06
			var bond_center := bridge_center + Vector3(0.0, wing_lift, 0.0) + (Vector3(bond_axis, 0.0, -projection_depth * 0.10) if runs_along_z else Vector3(-projection_depth * 0.10, 0.0, bond_axis))
			var bond_size := Vector3(0.22, wing_height + 0.34, wing_depth + 0.16) if runs_along_z else Vector3(wing_depth + 0.16, wing_height + 0.34, 0.22)
			add_part(blueprint, "castle_route_neck_%s_host_bond_%d" % [neck_id, int(side)], "beam", "timber_beam", bond_center, bond_size, {"collision": false, "variation": variation + side * 0.006, "semantic": "castle_route_neck_host_bond"})
		var connector_center := bridge_center + (Vector3(connector_center_axis, -0.18, projection_depth * 0.18) if runs_along_z else Vector3(projection_depth * 0.18, -0.18, connector_center_axis))
		var connector_size := Vector3(connector_span, room_height * 0.66, projection_depth * 0.54) if runs_along_z else Vector3(projection_depth * 0.54, room_height * 0.66, connector_span)
		add_part(blueprint, "castle_route_neck_%s_connector" % neck_id, "wall", material, connector_center, connector_size, {"variation": variation - 0.01, "semantic": "castle_route_neck_connector"})
		var connector_roof_size := Vector3(connector_span + 0.30, 0.22, projection_depth * 0.72 + 0.30) if runs_along_z else Vector3(projection_depth * 0.72 + 0.30, 0.22, connector_span + 0.30)
		add_part(blueprint, "castle_route_neck_%s_connector_roof" % neck_id, "roof", "roof_shingle", connector_center + Vector3(0.0, connector_size.y * 0.5 + 0.15, 0.0), connector_roof_size, {"collision": false, "variation": variation - 0.006, "semantic": "castle_route_neck_connector_roof"})
		for side in [-1.0, 1.0]:
			var corbel_axis := -clear_width * 0.22 if side < 0.0 else clear_width * 0.27
			var corbel_offset := Vector3(corbel_axis, -room_height * 0.58, 0.0) if runs_along_z else Vector3(0.0, -room_height * 0.58, corbel_axis)
			var corbel_size := Vector3(0.42, 0.34, projection_depth + 0.24) if runs_along_z else Vector3(projection_depth + 0.24, 0.34, 0.42)
			add_part(blueprint, "castle_route_neck_%s_corbel_%d" % [neck_id, int(side)], "beam", "timber_beam", bridge_center + corbel_offset, corbel_size, {"collision": false, "variation": variation, "semantic": "castle_route_neck_corbel"})
			var window_axis := -clear_width * 0.18 if side < 0.0 else clear_width * 0.43
			var window_depth := projection_depth * 0.59 if side < 0.0 else projection_depth * 0.39
			var window_offset := Vector3(window_axis, 0.04 + (0.42 if side > 0.0 else 0.0), window_depth) if runs_along_z else Vector3(window_depth, 0.04 + (0.42 if side > 0.0 else 0.0), window_axis)
			var window_size := Vector3(0.78, 1.12, 0.10) if runs_along_z else Vector3(0.10, 1.12, 0.78)
			var window_center := bridge_center + window_offset
			add_part(blueprint, "castle_route_neck_%s_window_%d" % [neck_id, int(side)], "window", "window_glass", window_center, window_size, {"collision": false, "variation": variation + side * 0.01, "semantic": "castle_route_neck_window"})
			if side < 0.0:
				var oriel_size := Vector3(1.24, 0.22, 0.34) if runs_along_z else Vector3(0.34, 0.22, 1.24)
				var oriel_offset := Vector3(0.0, -0.68, 0.15) if runs_along_z else Vector3(0.15, -0.68, 0.0)
				add_part(blueprint, "castle_route_neck_%s_oriel_sill" % neck_id, "beam", "timber_beam", window_center + oriel_offset, oriel_size, {"collision": false, "variation": variation, "semantic": "castle_route_neck_oriel"})
		var connector_frame_size := Vector3(connector_span + 0.08, 0.14, projection_depth * 0.76) if runs_along_z else Vector3(projection_depth * 0.76, 0.14, connector_span + 0.08)
		add_part(blueprint, "castle_route_neck_%s_timber_frame" % neck_id, "beam", "timber_beam", connector_center + Vector3(0.0, -connector_size.y * 0.36, 0.0), connector_frame_size, {"collision": false, "variation": variation, "semantic": "castle_route_neck_frame"})


static func citadel_route_neck_hosts(residences: Array[Dictionary], center: Vector3, runs_along_z: bool) -> Array[Dictionary]:
	var negative_host: Dictionary = {}
	var positive_host: Dictionary = {}
	var negative_distance := INF
	var positive_distance := INF
	for residence_value in residences:
		var residence: Dictionary = residence_value as Dictionary
		var residence_center: Vector3 = residence.get("center", Vector3.ZERO) as Vector3
		var route_axis_distance := absf(residence_center.z - center.z) if runs_along_z else absf(residence_center.x - center.x)
		var route_axis_span := float(residence.get("depth", 0.0)) if runs_along_z else float(residence.get("width", 0.0))
		var cross_delta := residence_center.x - center.x if runs_along_z else residence_center.z - center.z
		var cross_span := float(residence.get("width", 0.0)) if runs_along_z else float(residence.get("depth", 0.0))
		var facade_distance := absf(cross_delta) - cross_span * 0.5
		var route_gap := maxf(0.0, route_axis_distance - route_axis_span * 0.5)
		var score := maxf(0.0, facade_distance) + route_gap * 1.4 + route_axis_distance * 0.12
		if cross_delta < 0.0 and score < negative_distance:
			negative_host = residence
			negative_distance = score
		elif cross_delta > 0.0 and score < positive_distance:
			positive_host = residence
			positive_distance = score
	if negative_host.is_empty() or positive_host.is_empty():
		return []
	return [negative_host, positive_host]


static func add_citadel_processional_steps(blueprint, prefix: String, center_x: float, center_z: float, width: float, from_elevation: float, to_elevation: float, foundation_height: float, variation: float) -> void:
	var step_count := 7
	var tread_depth := 0.48
	for step_index in range(step_count):
		var progress := float(step_index + 1) / float(step_count)
		var elevation := lerpf(from_elevation, to_elevation, progress)
		var step_z := center_z - tread_depth * float(step_count - step_index)
		add_part(blueprint, "%s_%02d" % [prefix, step_index + 1], "foundation", "stone_foundation", Vector3(center_x, foundation_height + elevation * 0.5, step_z), Vector3(width, maxf(0.12, elevation), tread_depth + 0.04), {"variation": variation - 0.04, "semantic": "castle_processional_step"})


static func add_citadel_residence_facade_details(blueprint, residences: Array[Dictionary], grammar: Dictionary, foundation_height: float, variation: float) -> void:
	var grid: Dictionary = grammar.get("courtyardGrid", {}) as Dictionary
	var route_centers: Array = grid.get("routeCenters", []) as Array
	for residence_value in residences:
		var residence: Dictionary = residence_value as Dictionary
		var center: Vector3 = residence.get("center", Vector3.ZERO) as Vector3
		var terrace_elevation := float(residence.get("terraceElevation", 0.0))
		var wall_height := float((residence.get("residenceRecipe", {}) as Dictionary).get("wallHeight", 7.0))
		var width := float(residence.get("width", 8.0))
		var depth := float(residence.get("depth", 8.0))
		var front_direction := String(residence.get("frontDirection", "east"))
		var outward := Vector3.RIGHT
		if front_direction == "west":
			outward = Vector3.LEFT
		elif front_direction == "north":
			outward = Vector3.FORWARD
		elif front_direction == "south":
			outward = Vector3.BACK
		var front_distance := (width if absf(outward.x) > 0.5 else depth) * 0.5 + 0.42
		var facade_center := center + outward * front_distance
		var detail_y := foundation_height + terrace_elevation + minf(wall_height * 0.58, 6.2)
		var detail_span := clampf((depth if absf(outward.x) > 0.5 else width) * 0.24, 1.8, 3.0)
		var awning_size := Vector3(0.92, 0.14, detail_span) if absf(outward.x) > 0.5 else Vector3(detail_span, 0.14, 0.92)
		add_part(blueprint, "castle_residence_awning_%s" % String(residence.get("id", "home")), "roof", "painted_decor", Vector3(facade_center.x, detail_y, facade_center.z), awning_size, {"collision": false, "variation": variation + float(String(residence.get("id", "")).hash() % 11) * 0.004, "semantic": "castle_residence_awning"})
		for bracket_side in [-1.0, 1.0]:
			var bracket_offset := Vector3(0.0, -0.30, bracket_side * detail_span * 0.38) if absf(outward.x) > 0.5 else Vector3(bracket_side * detail_span * 0.38, -0.30, 0.0)
			var bracket_size := Vector3(0.56, 0.10, 0.10) if absf(outward.x) > 0.5 else Vector3(0.10, 0.10, 0.56)
			add_part(blueprint, "castle_residence_awning_bracket_%s_%d" % [String(residence.get("id", "home")), int(bracket_side)], "beam", "timber_beam", Vector3(facade_center.x, detail_y, facade_center.z) + bracket_offset - outward * 0.18, bracket_size, {"collision": false, "variation": variation, "semantic": "castle_residence_awning_bracket"})
		if String(residence.get("districtClass", "")) == "civic_anchor":
			var market_center := facade_center + outward * 0.18
			var counter_size := Vector3(0.46, 0.22, detail_span * 0.82) if absf(outward.x) > 0.5 else Vector3(detail_span * 0.82, 0.22, 0.46)
			add_part(blueprint, "castle_gate_market_counter_%s" % String(residence.get("id", "anchor")), "decor", "timber_board", Vector3(market_center.x, foundation_height + terrace_elevation + 1.02, market_center.z), counter_size, {"collision": false, "variation": variation, "semantic": "castle_gate_market_counter"})
			for goods_index in range(3):
				var lateral := (float(goods_index) - 1.0) * detail_span * 0.28
				var goods_offset := Vector3(0.0, 0.0, lateral) if absf(outward.x) > 0.5 else Vector3(lateral, 0.0, 0.0)
				add_part(blueprint, "castle_gate_market_goods_%s_%02d" % [String(residence.get("id", "anchor")), goods_index], "decor", "painted_decor", Vector3(market_center.x, foundation_height + terrace_elevation + 1.30 + float(goods_index % 2) * 0.10, market_center.z) + goods_offset, Vector3(0.30, 0.34 + float(goods_index % 2) * 0.12, 0.30), {"collision": false, "variation": variation + float(goods_index) * 0.03, "semantic": "castle_gate_market_goods"})
		if terrace_elevation > 0.1:
			var balcony_size := Vector3(1.05, 0.18, detail_span * 0.88) if absf(outward.x) > 0.5 else Vector3(detail_span * 0.88, 0.18, 1.05)
			add_part(blueprint, "castle_residence_balcony_%s" % String(residence.get("id", "home")), "decor", "timber_board", Vector3(facade_center.x, detail_y - 0.36, facade_center.z), balcony_size, {"collision": false, "variation": variation, "semantic": "castle_residence_balcony"})
			for rail_side in [-1.0, 1.0]:
				var rail_offset := Vector3(0.0, 0.34, rail_side * detail_span * 0.40) if absf(outward.x) > 0.5 else Vector3(rail_side * detail_span * 0.40, 0.34, 0.0)
				add_part(blueprint, "castle_residence_balcony_rail_%s_%d" % [String(residence.get("id", "home")), int(rail_side)], "beam", "timber_beam", Vector3(facade_center.x, detail_y - 0.36, facade_center.z) + rail_offset, Vector3(0.12, 0.68, 0.12), {"collision": false, "variation": variation, "semantic": "castle_residence_balcony"})
			var doorstep_center := facade_center - outward * 0.28
			var doorstep_size := Vector3(1.42, 0.16, 2.20) if absf(outward.x) > 0.5 else Vector3(2.20, 0.16, 1.42)
			add_part(blueprint, "castle_residence_upper_door_landing_%s" % String(residence.get("id", "home")), "foundation", "stone_foundation", Vector3(doorstep_center.x, foundation_height + terrace_elevation + 0.10, doorstep_center.z), doorstep_size, {"collision": false, "variation": variation - 0.02, "semantic": "castle_upper_door_landing"})
		var district_class := String(residence.get("districtClass", ""))
		if district_class == "sightline_screen":
			var screen_material := String(residence.get("residenceFacadeMaterial", "painted_brick_cream"))
			var side_axis := Vector3.RIGHT if absf(outward.z) > 0.5 else Vector3.FORWARD
			var screen_side := -1.0 if center.x > 0.0 else 1.0
			var visibility_projection := 0.45
			var corner_face_center := center + outward * ((depth if absf(outward.z) > 0.5 else width) * 0.5 + 0.18) + side_axis * screen_side * ((width if absf(outward.z) > 0.5 else depth) * 0.34 + visibility_projection)
			for step_index in range(2):
				var step_width := (width if absf(outward.z) > 0.5 else depth) * (0.25 - float(step_index) * 0.055)
				var step_depth := 0.86 + float(step_index) * 0.24
				var step_height := wall_height * (0.54 - float(step_index) * 0.12)
				var step_center := corner_face_center - side_axis * screen_side * float(step_index) * step_width * 0.92 - outward * float(step_index) * 0.34 + outward * step_depth * 0.5
				step_center.y = foundation_height + terrace_elevation + step_height * 0.5
				var step_size := Vector3(step_width, step_height, step_depth) if absf(outward.z) > 0.5 else Vector3(step_depth, step_height, step_width)
				add_part(blueprint, "castle_sightline_screen_corner_%02d" % step_index, "wall", screen_material, step_center, step_size, {"collision": false, "variation": variation + float(step_index) * 0.008, "semantic": "castle_sightline_screen_corner_step"})
				var step_window_center := step_center + outward * (step_depth * 0.5 + 0.045)
				step_window_center.y = foundation_height + terrace_elevation + minf(step_height * 0.62, 6.8)
				var step_window_size := Vector3(step_width * 0.48, 1.28, 0.10) if absf(outward.z) > 0.5 else Vector3(0.10, 1.28, step_width * 0.48)
				add_part(blueprint, "castle_sightline_screen_corner_window_%02d" % step_index, "window", "window_glass", step_window_center, step_window_size, {"collision": false, "variation": variation, "semantic": "castle_sightline_screen_corner_window"})
				var roof_center := step_center + Vector3(0.0, step_height * 0.5 + 0.22, 0.0) - outward * 0.10
				var roof_size := Vector3(step_width + 0.42, 0.24, step_depth + 0.50) if absf(outward.z) > 0.5 else Vector3(step_depth + 0.50, 0.24, step_width + 0.42)
				add_part(blueprint, "castle_sightline_screen_corner_roof_%02d" % step_index, "roof", "roof_shingle", roof_center, roof_size, {"collision": false, "variation": variation - 0.01 + float(step_index) * 0.006, "semantic": "castle_sightline_screen_corner_gable"})
		if district_class in ["civic", "civic_anchor", "sightline_screen"]:
			var stable_selector := absi(String(residence.get("id", "home")).hash()) % 5
			var publishes_oriel := district_class == "sightline_screen" or stable_selector in [1, 3, 4]
			if publishes_oriel:
				var projection_depth := 0.72 + float(stable_selector % 3) * 0.18
				var projection_span := clampf((depth if absf(outward.x) > 0.5 else width) * (0.30 + float(stable_selector % 2) * 0.05), 2.5, 4.2)
				var projection_height := clampf(wall_height * 0.30, 1.75, 2.35)
				var lateral_bias := (float(stable_selector) - 2.0) * 0.24
				var lateral_axis := Vector3.FORWARD if absf(outward.x) > 0.5 else Vector3.RIGHT
				var projection_center := facade_center + outward * (projection_depth * 0.5 - 0.36) + lateral_axis * lateral_bias
				projection_center.y = foundation_height + terrace_elevation + wall_height - projection_height * 0.56
				var projection_size := Vector3(projection_depth, projection_height, projection_span) if absf(outward.x) > 0.5 else Vector3(projection_span, projection_height, projection_depth)
				var facade_material := String(residence.get("residenceFacadeMaterial", "painted_brick_cream"))
				add_part(blueprint, "castle_route_frontage_oriel_%s" % String(residence.get("id", "home")), "wall", facade_material, projection_center, projection_size, {"collision": false, "variation": variation + float(stable_selector) * 0.006, "semantic": "castle_route_frontage_oriel"})
				var roof_center := projection_center + Vector3(0.0, projection_height * 0.5 + 0.16, 0.0) + outward * 0.08
				var roof_size := Vector3(projection_depth + 0.34, 0.22, projection_span + 0.32) if absf(outward.x) > 0.5 else Vector3(projection_span + 0.32, 0.22, projection_depth + 0.34)
				add_part(blueprint, "castle_route_frontage_oriel_roof_%s" % String(residence.get("id", "home")), "roof", "roof_shingle", roof_center, roof_size, {"collision": false, "variation": variation - 0.01, "semantic": "castle_route_frontage_oriel_roof"})
				var window_center := projection_center + outward * (projection_depth * 0.5 + 0.045)
				var window_size := Vector3(0.10, minf(1.24, projection_height * 0.64), projection_span * 0.56) if absf(outward.x) > 0.5 else Vector3(projection_span * 0.56, minf(1.24, projection_height * 0.64), 0.10)
				add_part(blueprint, "castle_route_frontage_oriel_window_%s" % String(residence.get("id", "home")), "window", "window_glass", window_center, window_size, {"collision": false, "variation": variation, "semantic": "castle_route_frontage_occupied_window"})
				for bracket_side in [-1.0, 1.0]:
					var bracket_lateral: Vector3 = lateral_axis * bracket_side * projection_span * 0.34
					var bracket_center: Vector3 = projection_center - outward * projection_depth * 0.22 - Vector3(0.0, projection_height * 0.58, 0.0) + bracket_lateral
					var bracket_size := Vector3(projection_depth * 0.72, 0.18, 0.16) if absf(outward.x) > 0.5 else Vector3(0.16, 0.18, projection_depth * 0.72)
					add_part(blueprint, "castle_route_frontage_oriel_bracket_%s_%d" % [String(residence.get("id", "home")), int(bracket_side)], "beam", "timber_beam", bracket_center, bracket_size, {"collision": false, "variation": variation, "semantic": "castle_route_frontage_oriel_bracket"})


static func citadel_terrace_elevation_at_z(grid: Dictionary, z: float) -> float:
	var step_height := float(grid.get("terraceStepHeight", 1.75))
	if String(grid.get("layoutFamily", "")) == "bent_processional":
		if z < float(grid.get("firstTurnZ", 0.0)):
			return 0.0
		if z < float(grid.get("finalTurnZ", 0.0)):
			return step_height
		return step_height * 2.0
	var rows: Array = grid.get("rowCenters", []) as Array
	var row_index := 0
	for candidate_index in range(rows.size()):
		if z >= float(rows[candidate_index]):
			row_index = candidate_index
	return minf(7.0, float(row_index) * step_height)


static func add_curtain_x_segment(blueprint, prefix: String, z: float, from_x: float, to_x: float, height: float, foundation_height: float, variation: float, masonry_material: String) -> void:
	var length := to_x - from_x
	if length <= 0.20:
		return
	add_curtain_run(blueprint, prefix, Vector3((from_x + to_x) * 0.5, 0.0, z), Vector3(length, height, 0.72), foundation_height, variation, masonry_material)


static func add_curtain_z_segment(blueprint, prefix: String, x: float, from_z: float, to_z: float, height: float, foundation_height: float, variation: float, masonry_material: String) -> void:
	var length := to_z - from_z
	if length <= 0.20:
		return
	add_curtain_run(blueprint, prefix, Vector3(x, 0.0, (from_z + to_z) * 0.5), Vector3(0.72, height, length), foundation_height, variation, masonry_material)


static func add_courtyard_outbuilding(blueprint, spec: Dictionary, castle_foundation_height: float) -> void:
	# This is intentionally a composition seam, not a third house grammar. The
	# castle reserves a valid wall lane; the existing cottage/manor builders own
	# every roof, room, window, door, stair and material decision within it.
	var source_blueprint = courtyard_residence_blueprint(spec)
	if source_blueprint == null:
		push_error("Castle courtyard residence has no shared source blueprint")
		return
	var prefix := "castle_%s" % String(spec.get("id", "courtyard_building"))
	var center: Vector3 = spec.get("center", Vector3.ZERO) as Vector3
	var local_foundation_height := float(source_blueprint.recipe.get("foundationHeight", 0.48))
	var yaw := float(spec.get("yaw", PI * 0.5 if center.x > 0.0 else -PI * 0.5))
	var origin: Vector3 = spec.get("origin", Vector3(center.x, castle_foundation_height - local_foundation_height, center.z)) as Vector3
	append_transformed_residence_parts(blueprint, source_blueprint, prefix, origin, yaw, String(spec.get("residenceFamily", "cottage")), String(spec.get("residenceFacadeMaterial", "fired_brick")))


static func courtyard_residence_blueprint(spec: Dictionary):
	var residence_recipe: Dictionary = spec.get("residenceRecipe", {}) as Dictionary
	match String(spec.get("residenceFamily", "cottage")):
		"manor":
			return LandmarkBuildingBlueprintBuilderScript.build_from_recipe(residence_recipe)
		_:
			return CottageBlueprintBuilderScript.build_from_recipe(residence_recipe)


static func append_transformed_residence_parts(target_blueprint, source_blueprint, prefix: String, origin: Vector3, yaw: float, family: String, facade_material: String) -> void:
	var yaw_basis := Basis(Vector3.UP, yaw)
	for source_part in source_blueprint.parts:
		if source_part == null:
			continue
		var source_recipe: Dictionary = source_part.recipe.duplicate(true)
		source_recipe["castleResidenceFamily"] = family
		source_recipe["castleResidenceSourcePart"] = String(source_part.id)
		source_recipe["castleResidenceFacing"] = "courtyard_core"
		source_recipe["castleResidenceFacadeMaterial"] = facade_material
		var local_basis := Basis.from_euler(source_part.rotation)
		var transformed_basis := yaw_basis * local_basis
		var semantic := "castle_courtyard_building_door" if String(source_part.kind) == "door" else "castle_courtyard_residence_%s" % String(source_part.semantic)
		source_recipe["rotation"] = transformed_basis.get_euler()
		var collision_enabled := bool(source_part.collision_enabled)
		if family == "cottage" and String(source_part.semantic) == "entry_ramp":
			collision_enabled = false
		source_recipe["collision"] = collision_enabled
		source_recipe["semantic"] = semantic
		var material_id := facade_material if String(source_part.material_id) == "fired_brick" else String(source_part.material_id)
		add_part(target_blueprint, "%s__%s" % [prefix, String(source_part.id)], String(source_part.kind), material_id, origin + yaw_basis * source_part.position, source_part.size, source_recipe)


static func append_courtyard_residence_rooms(records: Array, spec: Dictionary, castle_foundation_height: float) -> void:
	var source_blueprint = courtyard_residence_blueprint(spec)
	if source_blueprint == null:
		return
	var center: Vector3 = spec.get("center", Vector3.ZERO) as Vector3
	var local_foundation_height := float(source_blueprint.recipe.get("foundationHeight", 0.48))
	var yaw := float(spec.get("yaw", PI * 0.5 if center.x > 0.0 else -PI * 0.5))
	var yaw_basis := Basis(Vector3.UP, yaw)
	var origin: Vector3 = spec.get("origin", Vector3(center.x, castle_foundation_height - local_foundation_height, center.z)) as Vector3
	var prefix := String(spec.get("id", "courtyard_building"))
	var part_prefix := "castle_%s" % prefix
	for room_value in source_blueprint.rooms:
		if not room_value is Dictionary:
			continue
		var source_room: Dictionary = room_value as Dictionary
		var local_bounds: AABB = source_room.get("bounds", AABB()) as AABB
		var transformed_size := transformed_horizontal_size(local_bounds.size, yaw_basis)
		var room := source_room.duplicate(true)
		room["id"] = "%s_%s" % [prefix, String(source_room.get("id", "room"))]
		room["bounds"] = AABB(origin + yaw_basis * local_bounds.get_center() - transformed_size * 0.5, transformed_size)
		room["castleResidenceFamily"] = String(spec.get("residenceFamily", "cottage"))
		room["castleResidenceRoom"] = true
		var transformed_accesses: Array = []
		var source_accesses: Array = source_room.get("accesses", []) as Array
		for access_value in source_accesses:
			if not access_value is Dictionary:
				continue
			var access: Dictionary = (access_value as Dictionary).duplicate(true)
			var local_position: Vector3 = access.get("position", Vector3.ZERO) as Vector3
			var local_size: Vector3 = access.get("size", Vector3.ZERO) as Vector3
			var local_furnishing_size: Vector3 = access.get("furnishingSize", local_size) as Vector3
			var source_orientation: Vector3 = access.get("orientation", Vector3.ZERO) as Vector3
			var access_basis := yaw_basis * Basis.from_euler(source_orientation)
			access["position"] = origin + yaw_basis * local_position
			access["navigationSize"] = local_size
			access["size"] = transformed_horizontal_size(local_size, access_basis)
			access["furnishingSize"] = transformed_horizontal_size(local_furnishing_size, access_basis)
			access["orientation"] = access_basis.get_euler()
			var support_part_id := String(access.get("supportPartId", ""))
			if not support_part_id.is_empty():
				access["supportPartId"] = "%s__%s" % [part_prefix, support_part_id]
			transformed_accesses.append(access)
		room["accesses"] = transformed_accesses
		records.append(room)


static func transformed_horizontal_size(size: Vector3, basis: Basis) -> Vector3:
	var axis_x := basis * Vector3.RIGHT
	var axis_z := basis * Vector3.FORWARD
	return Vector3(
		absf(axis_x.x) * size.x + absf(axis_z.x) * size.z,
		size.y,
		absf(axis_x.z) * size.x + absf(axis_z.z) * size.z
	)


static func add_tower(blueprint, prefix: String, center: Vector3, span: float, height: float, foundation_height: float, variation: float, masonry_material: String) -> void:
	add_part(blueprint, "%s_foundation" % prefix, "foundation", "stone_foundation", Vector3(center.x, foundation_height * 0.5, center.z), Vector3(span + 0.54, foundation_height, span + 0.54), {"variation": variation, "semantic": "castle_tower_foundation"})
	add_part(blueprint, "%s_floor" % prefix, "foundation", "stone_foundation", Vector3(center.x, foundation_height + 0.09, center.z), Vector3(span - 0.38, 0.18, span - 0.38), {"variation": variation, "semantic": "castle_tower_floor"})
	var wall_y := foundation_height + height * 0.5
	for spec in [
		{"id": "front", "position": Vector3(center.x, wall_y, center.z - span * 0.5), "size": Vector3(span, height, 0.62)},
		{"id": "back", "position": Vector3(center.x, wall_y, center.z + span * 0.5), "size": Vector3(span, height, 0.62)},
		{"id": "left", "position": Vector3(center.x - span * 0.5, wall_y, center.z), "size": Vector3(0.62, height, span)},
		{"id": "right", "position": Vector3(center.x + span * 0.5, wall_y, center.z), "size": Vector3(0.62, height, span)}
	]:
		add_part(blueprint, "%s_%s" % [prefix, String(spec.get("id", "wall"))], "wall", masonry_material, spec.get("position", Vector3.ZERO) as Vector3, spec.get("size", Vector3.ONE) as Vector3, {"variation": variation, "semantic": "castle_tower_wall"})
	add_part(blueprint, "%s_roof_deck" % prefix, "foundation", "stone_foundation", Vector3(center.x, foundation_height + height + 0.12, center.z), Vector3(span - 0.28, 0.24, span - 0.28), {"variation": variation, "semantic": "castle_tower_roof"})
	add_crenellations(blueprint, "%s_battlement" % prefix, center, span, span, foundation_height + height + 0.50, variation)


static func add_curtain_run(blueprint, prefix: String, center: Vector3, size: Vector3, foundation_height: float, variation: float, masonry_material: String) -> void:
	if size.x <= 0.20 or size.z <= 0.20:
		return
	add_part(blueprint, "%s_foundation" % prefix, "foundation", "stone_foundation", Vector3(center.x, foundation_height * 0.5, center.z), Vector3(size.x + 0.20, foundation_height, size.z + 0.20), {"variation": variation, "semantic": "castle_curtain_foundation"})
	add_part(blueprint, "%s_wall" % prefix, "wall", masonry_material, Vector3(center.x, foundation_height + size.y * 0.5, center.z), size, {"variation": variation, "semantic": "castle_curtain_wall"})
	add_crenellations(blueprint, "%s_battlement" % prefix, center, size.x, size.z, foundation_height + size.y + 0.36, variation)


static func add_gatehouse(blueprint, width: float, depth: float, height: float, foundation_height: float, front_z: float, variation: float, masonry_material: String) -> void:
	var center_z := front_z - depth * 0.42
	var exterior_gate_z := center_z - depth * 0.5
	# The gatehouse must preserve the broad axial opening claimed by the curtain
	# wall.  A narrow 3m chute makes the inner piers read as a solid rear wall;
	# this proportional arch keeps a clear, legible route into the courtyard at
	# every seeded compound scale.
	var opening_width := clampf(width * 0.48, 4.00, 6.00)
	var pier_width := (width - opening_width) * 0.5
	var wall_y := foundation_height + height * 0.5
	var passage_floor_top := foundation_height + 0.14
	# The gatehouse is a raised, load-bearing part of the compound.  Its full
	# footprint supplies the continuous passage floor and physically supports
	# both piers; entry steps meet this exterior edge from normal terrain.
	add_part(blueprint, "castle_gatehouse_foundation", "foundation", "stone_foundation", Vector3(0.0, foundation_height * 0.5, center_z), Vector3(width + 0.22, foundation_height, depth + 0.22), {"variation": variation, "semantic": "castle_gatehouse_foundation"})
	# Match the courtyard paving elevation throughout the passage.  Without this
	# cap the inner threshold leaves a small but real collision ledge after the
	# gate has opened.
	add_part(blueprint, "castle_gatehouse_paving", "foundation", "stone_foundation", Vector3(0.0, foundation_height + 0.07, center_z), Vector3(width - 0.34, 0.14, depth - 0.18), {"variation": variation + 0.02, "semantic": "castle_gatehouse_paving"})
	for side in [-1.0, 1.0]:
		var pier_center_x: float = side * (opening_width * 0.5 + pier_width * 0.5)
		if side < 0.0:
			# The left pier is a real enclosed stair bay rather than a decorative
			# solid.  Its rear door opens from the courtyard; all of its masonry
			# remains outside the central arch, so the gate passage stays clear.
			add_gatehouse_stair_bay(blueprint, pier_center_x, pier_width, center_z, depth, height, foundation_height, variation, masonry_material)
		else:
			add_part(blueprint, "castle_gatehouse_pier_%d" % int(side), "wall", masonry_material, Vector3(pier_center_x, wall_y, center_z), Vector3(pier_width, height, depth), {"variation": variation, "semantic": "castle_gatehouse_pier"})
	var passage_height := 2.88
	var lintel_height := height - passage_height
	add_part(blueprint, "castle_gatehouse_lintel", "wall", masonry_material, Vector3(0.0, foundation_height + passage_height + lintel_height * 0.5, center_z), Vector3(opening_width, lintel_height, depth), {"variation": variation, "semantic": "castle_gatehouse_lintel"})
	add_gatehouse_threshold_composition(blueprint, opening_width, depth, height, foundation_height, center_z, exterior_gate_z, variation)
	# Face the player with the actual operable gate.  Once raised, the player
	# traverses one continuous founded gatehouse passage into the courtyard.
	add_part(blueprint, "castle_gatehouse_portcullis", "door", "ironwork", Vector3(0.0, passage_floor_top + passage_height * 0.5, exterior_gate_z - 0.10), Vector3(opening_width - 0.16, passage_height, 0.18), {"variation": variation - 0.05, "semantic": "castle_portcullis", "doorPresentation": "portcullis", "doorMotion": "raise"})
	add_gatehouse_entry_steps(blueprint, opening_width, passage_floor_top, exterior_gate_z, variation)
	add_gatehouse_roof_deck_with_stair_hatch(blueprint, width, depth, height, foundation_height, center_z, -1.0 * (opening_width * 0.5 + pier_width * 0.5), pier_width, variation)
	add_crenellations(blueprint, "castle_gatehouse_battlement", Vector3(0.0, 0.0, center_z), width, depth, foundation_height + height + 0.50, variation)


static func add_gatehouse_threshold_composition(blueprint, opening_width: float, depth: float, height: float, foundation_height: float, center_z: float, exterior_gate_z: float, variation: float) -> void:
	var passage_height := 2.88
	var trim_depth := 0.18
	var trim_width := clampf(opening_width * 0.075, 0.30, 0.44)
	var exterior_trim_z := exterior_gate_z - 0.23
	var inner_gate_z := center_z + depth * 0.5 - 0.12
	for threshold_index in range(2):
		var threshold_z := exterior_trim_z if threshold_index == 0 else inner_gate_z
		var threshold_prefix := "outer" if threshold_index == 0 else "inner"
		for side in [-1.0, 1.0]:
			add_part(blueprint, "castle_gatehouse_%s_arch_jamb_%d" % [threshold_prefix, int(side)], "beam", "stone_foundation", Vector3(side * (opening_width * 0.5 + trim_width * 0.5), foundation_height + passage_height * 0.5, threshold_z), Vector3(trim_width, passage_height + 0.22, trim_depth), {"collision": false, "variation": variation + side * 0.006, "semantic": "castle_gatehouse_arch_trim"})
		add_part(blueprint, "castle_gatehouse_%s_arch_header" % threshold_prefix, "beam", "stone_foundation", Vector3(0.0, foundation_height + passage_height + trim_width * 0.5, threshold_z), Vector3(opening_width + trim_width * 2.0, trim_width, trim_depth), {"collision": false, "variation": variation + 0.01, "semantic": "castle_gatehouse_arch_trim"})

	# Repeated pale ribs break the deep passage into readable spatial bays. They
	# are presentation only and stay flush with the structural shell, preserving
	# the full collision-backed opening for players, NPCs, and the raised gate.
	var bay_count := clampi(roundi(depth / 2.25), 3, 5)
	for bay_index in range(1, bay_count):
		var bay_t := float(bay_index) / float(bay_count)
		var bay_z := lerpf(exterior_gate_z, center_z + depth * 0.5, bay_t)
		for side in [-1.0, 1.0]:
			add_part(blueprint, "castle_gatehouse_passage_rib_%02d_%d" % [bay_index, int(side)], "beam", "stone_foundation", Vector3(side * (opening_width * 0.5 - 0.055), foundation_height + passage_height * 0.52, bay_z), Vector3(0.11, passage_height * 0.92, 0.16), {"collision": false, "variation": variation + bay_t * 0.02, "semantic": "castle_gatehouse_passage_rib"})
		add_part(blueprint, "castle_gatehouse_passage_header_%02d" % bay_index, "beam", "timber_beam", Vector3(0.0, foundation_height + passage_height - 0.10, bay_z), Vector3(opening_width - 0.12, 0.16, 0.20), {"collision": false, "variation": variation - bay_t * 0.02, "semantic": "castle_gatehouse_passage_header"})

	# The upper gatehouse reads as occupied civic architecture rather than a
	# blank defensive slab. Window orders and a central heraldic recess derive
	# entirely from the gate span, so every generated compound receives the same
	# scalable threshold grammar.
	var upper_base_y := foundation_height + passage_height + 0.74
	var upper_height := maxf(1.2, height - passage_height - 1.10)
	var window_height := minf(1.34, upper_height * 0.52)
	var window_width := clampf(opening_width * 0.15, 0.62, 0.90)
	for side in [-1.0, 1.0]:
		add_part(blueprint, "castle_gatehouse_upper_window_%d" % int(side), "window", "window_glass", Vector3(side * opening_width * 0.27, upper_base_y + window_height * 0.5, exterior_trim_z - 0.015), Vector3(window_width, window_height, 0.12), {"collision": false, "variation": variation + side * 0.01, "semantic": "castle_gatehouse_upper_window"})
	var panel_height := minf(1.0, upper_height * 0.40)
	add_part(blueprint, "castle_gatehouse_heraldic_recess", "beam", "painted_brick_cream", Vector3(0.0, upper_base_y + panel_height * 0.5, exterior_trim_z - 0.005), Vector3(window_width * 0.72, panel_height, 0.10), {"collision": false, "variation": variation - 0.02, "semantic": "castle_gatehouse_heraldic_recess"})


static func add_gatehouse_stair_bay(blueprint, center_x: float, span: float, center_z: float, depth: float, height: float, foundation_height: float, variation: float, masonry_material: String) -> void:
	# Retain the pier's structural envelope, but hollow its centre into an
	# enclosed, courtyard-entered vertical route.  The inner wall finishes at
	# the arch edge; no stair part may cross that boundary into the main passage.
	var shell_thickness := minf(0.62, span * 0.22)
	var rear_z := center_z + depth * 0.5
	var front_z := center_z - depth * 0.5
	var wall_y := foundation_height + height * 0.5
	var door_width := clampf(span * 0.48, 1.02, 1.30)
	var door_height := minf(2.44, height - 0.40)
	var rear_side_width := (span - door_width) * 0.5
	# Preserve the historical pier id on the exterior load-bearing front face;
	# downstream shell/foundation checks still see a pier seated on the same
	# foundation while the new bay owns its usable interior.
	add_part(blueprint, "castle_gatehouse_pier_-1", "wall", masonry_material, Vector3(center_x, wall_y, front_z), Vector3(span, height, shell_thickness), {"variation": variation, "semantic": "castle_gatehouse_stair_bay_front"})
	add_part(blueprint, "castle_gatehouse_stair_bay_outer_wall", "wall", masonry_material, Vector3(center_x - span * 0.5, wall_y, center_z), Vector3(shell_thickness, height, depth), {"variation": variation, "semantic": "castle_gatehouse_stair_bay_wall"})
	# The inside face is exactly flush with the left edge of the central arch.
	# It therefore encloses the stair without stealing even a fraction of the
	# player-width gate route.
	add_part(blueprint, "castle_gatehouse_stair_bay_inner_wall", "wall", masonry_material, Vector3(center_x + span * 0.5 - shell_thickness * 0.5, wall_y, center_z), Vector3(shell_thickness, height, depth), {"variation": variation, "semantic": "castle_gatehouse_stair_bay_wall"})
	for side in [-1.0, 1.0]:
		if rear_side_width > 0.08:
			add_part(blueprint, "castle_gatehouse_stair_bay_rear_%d" % int(side), "wall", masonry_material, Vector3(center_x + side * (door_width * 0.5 + rear_side_width * 0.5), foundation_height + door_height * 0.5, rear_z), Vector3(rear_side_width, door_height, shell_thickness), {"variation": variation, "semantic": "castle_gatehouse_stair_bay_rear"})
	var rear_header_height := height - door_height
	add_part(blueprint, "castle_gatehouse_stair_bay_rear_header", "wall", masonry_material, Vector3(center_x, foundation_height + door_height + rear_header_height * 0.5, rear_z), Vector3(door_width, rear_header_height, shell_thickness), {"variation": variation, "semantic": "castle_gatehouse_stair_bay_rear_header"})
	add_part(blueprint, "castle_gatehouse_wall_stair_door", "door", "painted_door", Vector3(center_x, foundation_height + door_height * 0.5, rear_z + shell_thickness * 0.68), Vector3(door_width - 0.14, door_height, 0.16), {"rotation": Vector3(0.0, PI, 0.0), "variation": variation - 0.03, "semantic": "castle_gatehouse_wall_stair_entry"})
	var climb_segments := clampi(ceili(height / 3.55), 2, 5)
	add_switchback_stair_flights(blueprint, "castle_gatehouse_wall_stair", Vector3(center_x, 0.0, center_z), span - shell_thickness * 2.0 - 0.08, depth - shell_thickness * 2.0 - 0.12, foundation_height + 0.20, height / float(climb_segments), climb_segments, "stone_foundation", variation, "castle_gatehouse_wall_stair")


static func add_gatehouse_roof_deck_with_stair_hatch(blueprint, width: float, depth: float, height: float, foundation_height: float, center_z: float, stair_center_x: float, stair_span: float, variation: float) -> void:
	# The roof is a ring around the stair bay, not a decorative solid deck that
	# would cap the last tread.  The hatch is the actual route onto the gatehouse
	# roof/wall walk and is sized from the same pier envelope as the stairs.
	var deck_y := foundation_height + height + 0.12
	var deck_width := width + 0.22
	var deck_depth := depth + 0.22
	var min_x := -deck_width * 0.5
	var max_x := deck_width * 0.5
	var min_z := center_z - deck_depth * 0.5
	var max_z := center_z + deck_depth * 0.5
	var hatch_min_x := stair_center_x - stair_span * 0.5 + 0.26
	var hatch_max_x := stair_center_x + stair_span * 0.5 - 0.26
	var hatch_min_z := center_z - depth * 0.5 + 0.48
	var hatch_max_z := center_z + depth * 0.5 - 0.48
	add_gatehouse_roof_panel(blueprint, "castle_gatehouse_roof_deck_front", min_x, max_x, min_z, hatch_min_z, deck_y, variation)
	add_gatehouse_roof_panel(blueprint, "castle_gatehouse_roof_deck_back", min_x, max_x, hatch_max_z, max_z, deck_y, variation)
	add_gatehouse_roof_panel(blueprint, "castle_gatehouse_roof_deck_hatch_outer", min_x, hatch_min_x, hatch_min_z, hatch_max_z, deck_y, variation)
	add_gatehouse_roof_panel(blueprint, "castle_gatehouse_roof_deck_hatch_inner", hatch_max_x, max_x, hatch_min_z, hatch_max_z, deck_y, variation)


static func add_gatehouse_roof_panel(blueprint, part_id: String, min_x: float, max_x: float, min_z: float, max_z: float, y: float, variation: float) -> void:
	if max_x - min_x <= 0.08 or max_z - min_z <= 0.08:
		return
	add_part(blueprint, part_id, "foundation", "stone_foundation", Vector3((min_x + max_x) * 0.5, y, (min_z + max_z) * 0.5), Vector3(max_x - min_x, 0.24, max_z - min_z), {"variation": variation, "semantic": "castle_gatehouse_roof"})


static func add_gatehouse_entry_steps(blueprint, opening_width: float, passage_floor_top: float, exterior_gate_z: float, variation: float) -> void:
	# The gate is a real player/NPC entry, not a decorative opening raised above
	# terrain. These shared construction parts make the exterior ground meet the
	# published courtyard floor through climbable, collision-backed stone steps.
	var step_count := 3
	var tread_depth := 0.54
	for step_index in range(step_count):
		var progress := float(step_index + 1) / float(step_count)
		var step_height := passage_floor_top * progress
		var step_z := exterior_gate_z - tread_depth * (float(step_count - step_index) - 0.5)
		add_part(blueprint, "castle_gatehouse_entry_step_%02d" % (step_index + 1), "foundation", "stone_foundation", Vector3(0.0, step_height * 0.5, step_z), Vector3(opening_width + 0.72, step_height, tread_depth + 0.03), {"variation": variation, "semantic": "castle_gatehouse_entry_step"})


static func add_keep(blueprint, center: Vector3, width: float, depth: float, height: float, storey_count: int, floor_height: float, foundation_height: float, variation: float, masonry_material: String, palace_grammar: Dictionary = {}) -> void:
	var palace_material := String(palace_grammar.get("palaceMaterial", "painted_brick_cream"))
	var enclosed_storey_count := clampi(int(palace_grammar.get("hallStoreys", 4)), 1, storey_count)
	var hall_height := minf(height, floor_height * float(enclosed_storey_count))
	add_part(blueprint, "castle_keep_foundation", "foundation", "stone_foundation", Vector3(center.x, foundation_height * 0.5, center.z), Vector3(width + 0.70, foundation_height, depth + 0.70), {"variation": variation, "semantic": "castle_keep_foundation"})
	add_part(blueprint, "castle_keep_floor", "foundation", "stone_foundation", Vector3(center.x, foundation_height + 0.10, center.z), Vector3(width - 0.40, 0.20, depth - 0.40), {"variation": variation, "semantic": "castle_keep_floor"})
	var wall_y := foundation_height + hall_height * 0.5
	var front_z := center.z - depth * 0.5
	var door_width := minf(2.30, width * 0.18)
	var front_side_width := (width - door_width) * 0.5
	for side in [-1.0, 1.0]:
		add_part(blueprint, "castle_keep_front_%d" % int(side), "wall", palace_material, Vector3(center.x + side * (door_width * 0.5 + front_side_width * 0.5), wall_y, front_z), Vector3(front_side_width, hall_height, 0.72), {"variation": variation, "semantic": "castle_keep_wall"})
	var entry_height := 2.80
	var entry_header_height := hall_height - entry_height
	add_part(blueprint, "castle_keep_entry_header", "wall", masonry_material, Vector3(center.x, foundation_height + entry_height + entry_header_height * 0.5, front_z), Vector3(door_width, entry_header_height, 0.72), {"variation": variation, "semantic": "castle_keep_entry_header"})
	add_part(blueprint, "castle_keep_entry_door", "door", "painted_door", Vector3(center.x, foundation_height + entry_height * 0.5, front_z - 0.10), Vector3(door_width - 0.16, entry_height, 0.18), {"variation": variation - 0.03, "semantic": "castle_keep_entry"})
	for spec in [
		{"id": "back", "position": Vector3(center.x, wall_y, center.z + depth * 0.5), "size": Vector3(width, hall_height, 0.72)},
		{"id": "left", "position": Vector3(center.x - width * 0.5, wall_y, center.z), "size": Vector3(0.72, hall_height, depth)},
		{"id": "right", "position": Vector3(center.x + width * 0.5, wall_y, center.z), "size": Vector3(0.72, hall_height, depth)}
	]:
		add_part(blueprint, "castle_keep_%s" % String(spec.get("id", "wall")), "wall", palace_material, spec.get("position", Vector3.ZERO) as Vector3, spec.get("size", Vector3.ONE) as Vector3, {"variation": variation, "semantic": "castle_keep_wall"})
	var stairwell := keep_stairwell_layout(center, width, depth)
	var stair_center: Vector3 = stairwell.get("center", center) as Vector3
	var stair_width := float(stairwell.get("width", 3.20))
	var stair_depth := float(stairwell.get("depth", 5.00))
	# Every occupied keep level receives an actual walkable floor with a matching
	# stairwell void.  A single full floor plane would cap the stairs; a missing
	# floor would make the upper silhouette a non-playable shell.
	for storey_index in range(1, enclosed_storey_count):
		add_keep_storey_floor_with_stairwell(blueprint, storey_index, center, width, depth, stair_center, stair_width, stair_depth, foundation_height, floor_height, variation)
	add_switchback_stair_flights(blueprint, "castle_keep_stair", stair_center, stair_width, stair_depth, foundation_height + 0.20, floor_height, maxi(1, enclosed_storey_count - 1), "stone_foundation", variation, "castle_keep_stair")
	var upper_width := width * float(palace_grammar.get("upperWidthRatio", 0.34))
	var upper_depth := depth * float(palace_grammar.get("upperDepthRatio", 0.38))
	# The upper register is a roof transition, not the remainder of the keep's
	# nominal storey count. Letting every non-hall storey accumulate here creates
	# a tall detached tower above the palace roof at grand scales. One civic
	# storey keeps the drum structurally seated while the main hall owns the mass.
	var upper_height := clampf(height - hall_height, floor_height * 0.90, floor_height * 1.25)
	var upper_center := center + Vector3(width * float(palace_grammar.get("upperOffsetXRatio", 0.08)), 0.0, depth * float(palace_grammar.get("upperOffsetZRatio", 0.12)))
	var lower_roof_y := foundation_height + hall_height
	var hall_roof_rise := maxf(3.8, width * float(palace_grammar.get("hallRoofRiseRatio", 0.20)))
	var upper_top := lower_roof_y + upper_height
	# The upper register is deliberately narrower than the keep. Close the hall
	# with a bounded pitched roof rather than an elevated deck: vertical travel
	# remains inside the stairwell and the exterior silhouette stays architectural.
	add_keep_gabled_roof(blueprint, "castle_keep_hall_roof", center, width, depth, lower_roof_y, hall_roof_rise, variation)
	# The crown then sits on the enclosed upper register. Its seat overlaps both
	# supporting levels so a precision/shadow seam cannot make it appear detached.
	add_part(blueprint, "castle_keep_upper_register", "wall", palace_material, Vector3(upper_center.x, lower_roof_y + upper_height * 0.5, upper_center.z), Vector3(upper_width, upper_height, upper_depth), {"variation": variation + 0.01, "semantic": "castle_keep_upper_register"})
	var crown_seat_y := maxf(upper_top, lower_roof_y + hall_roof_rise) - 0.18
	add_part(blueprint, "castle_keep_upper_crown_seat", "beam", "stone_foundation", Vector3(upper_center.x, crown_seat_y, upper_center.z), Vector3(upper_width + 0.82, 0.54, upper_depth + 0.82), {"variation": variation - 0.01, "semantic": "castle_keep_upper_crown_seat"})
	add_keep_palace_central_hierarchy(blueprint, center, width, depth, hall_height, foundation_height, variation, palace_material, palace_grammar)
	add_keep_facade_articulation(blueprint, center, width, depth, hall_height, foundation_height, variation, palace_material, palace_grammar)
	add_keep_palace_wings(blueprint, center, width, depth, hall_height, foundation_height, variation, palace_material, palace_grammar)
	add_keep_palace_dome(blueprint, Vector3(upper_center.x, 0.0, upper_center.z + depth * float(palace_grammar.get("domeOffsetZRatio", -0.05))), upper_width, crown_seat_y + 0.18 - upper_height, upper_height, variation, palace_material, palace_grammar)
	add_keep_palace_entry_court(blueprint, center, width, depth, foundation_height, variation, palace_grammar)
	add_keep_palace_forecourt_galleries(blueprint, center, width, depth, foundation_height, variation, palace_material, palace_grammar)
	add_keep_palace_rear_court(blueprint, center, width, depth, hall_height, foundation_height, variation, palace_material, palace_grammar)
	add_keep_palace_window_rhythm(blueprint, center, width, depth, hall_height, foundation_height, variation, palace_grammar)
	add_part(blueprint, "castle_keep_banner", "sign", "painted_decor", Vector3(center.x, foundation_height + height * 0.64, front_z - 0.42), Vector3(1.46, 2.60, 0.10), {"variation": variation, "collision": false, "semantic": "castle_banner"})


static func add_keep_palace_central_hierarchy(blueprint, center: Vector3, width: float, depth: float, hall_height: float, foundation_height: float, variation: float, masonry_material: String, palace_grammar: Dictionary) -> void:
	var front_z := center.z - depth * 0.5
	var bay_width := width * float(palace_grammar.get("entranceBayWidthRatio", 0.25))
	var bay_depth := depth * float(palace_grammar.get("entranceBayDepthRatio", 0.09))
	var bay_height := hall_height * float(palace_grammar.get("entranceBayHeightRatio", 0.82))
	var bay_center := Vector3(center.x, 0.0, front_z - bay_depth * 0.5)
	var portal_width := minf(2.30, width * 0.18) + 0.34
	var portal_height := 3.18
	var bay_side_width := maxf(0.80, (bay_width - portal_width) * 0.5)
	for side in [-1.0, 1.0]:
		var bay_side_x: float = center.x + side * (portal_width * 0.5 + bay_side_width * 0.5)
		add_part(blueprint, "castle_keep_palace_entrance_bay_side_%d" % int(side), "wall", masonry_material, Vector3(bay_side_x, foundation_height + bay_height * 0.5, bay_center.z), Vector3(bay_side_width, bay_height, bay_depth), {"variation": variation - 0.006 + side * 0.004, "semantic": "castle_keep_palace_entrance_bay"})
	var bay_header_height := bay_height - portal_height
	add_part(blueprint, "castle_keep_palace_entrance_bay_header", "wall", masonry_material, Vector3(center.x, foundation_height + portal_height + bay_header_height * 0.5, bay_center.z), Vector3(portal_width, bay_header_height, bay_depth), {"variation": variation - 0.006, "semantic": "castle_keep_palace_entrance_bay_header"})
	var portal_face_z := front_z - bay_depth - 0.08
	add_part(blueprint, "castle_keep_palace_entrance_recess_header", "beam", "stone_foundation", Vector3(center.x, foundation_height + portal_height + 0.18, portal_face_z), Vector3(portal_width + 0.72, 0.42, 0.32), {"variation": variation - 0.03, "semantic": "castle_keep_palace_entrance_recess"})
	for side in [-1.0, 1.0]:
		add_part(blueprint, "castle_keep_palace_entrance_recess_pier_%d" % int(side), "beam", "stone_foundation", Vector3(center.x + side * (portal_width * 0.5 + 0.18), foundation_height + portal_height * 0.48, portal_face_z), Vector3(0.36, portal_height * 0.96, 0.32), {"variation": variation - 0.03, "semantic": "castle_keep_palace_entrance_recess"})
	var flank_step := width * float(palace_grammar.get("entranceFlankStepRatio", 0.12))
	for side in [-1.0, 1.0]:
		var flank_width := maxf(2.8, flank_step)
		var flank_height := bay_height * (0.82 if side < 0.0 else 0.74)
		var flank_depth := bay_depth * (0.72 if side < 0.0 else 0.56)
		var flank_center := Vector3(center.x + side * (bay_width * 0.5 + flank_width * 0.5 - 0.18), 0.0, front_z - flank_depth * 0.5)
		add_part(blueprint, "castle_keep_palace_entrance_flank_%d" % int(side), "wall", masonry_material, Vector3(flank_center.x, foundation_height + flank_height * 0.5, flank_center.z), Vector3(flank_width, flank_height, flank_depth), {"variation": variation + side * 0.008, "semantic": "castle_keep_palace_entrance_flank"})
		add_part(blueprint, "castle_keep_palace_entrance_flank_cornice_%d" % int(side), "beam", "stone_foundation", Vector3(flank_center.x, foundation_height + flank_height * 0.82, flank_center.z - flank_depth * 0.5 - 0.06), Vector3(flank_width * 0.82, 0.30, 0.26), {"variation": variation - 0.02, "semantic": "castle_keep_palace_entrance_order"})
	var root_width := width * float(palace_grammar.get("rotundaRootWidthRatio", 0.28))
	var root_depth := depth * float(palace_grammar.get("rotundaRootProjectionRatio", 0.06))
	var root_height := hall_height * 0.54
	var root_center := Vector3(center.x, foundation_height + hall_height - root_height * 0.5, front_z - root_depth * 0.5 - bay_depth * 0.18)
	add_part(blueprint, "castle_keep_palace_rotunda_root", "wall", masonry_material, root_center, Vector3(root_width, root_height, root_depth), {"variation": variation + 0.005, "semantic": "castle_keep_palace_rotunda_root"})
	var order_levels := 3
	for level in range(order_levels):
		var order_y := foundation_height + portal_height + 1.10 + float(level) * minf(2.55, hall_height * 0.19)
		for bay in [-1.0, 0.0, 1.0]:
			var order_x: float = center.x + bay * bay_width * 0.25
			add_part(blueprint, "castle_keep_palace_entrance_window_%02d_%d" % [level, int(bay)], "window", "window_glass", Vector3(order_x, order_y, front_z - bay_depth - 0.055), Vector3(bay_width * 0.15, 1.34 + float(level) * 0.08, 0.12), {"collision": false, "variation": variation + float(level) * 0.004, "semantic": "castle_keep_palace_entrance_window"})
		add_part(blueprint, "castle_keep_palace_entrance_order_%02d" % level, "beam", "stone_foundation", Vector3(center.x, order_y + 0.88, front_z - bay_depth - 0.04), Vector3(bay_width * 0.88, 0.26, 0.24), {"variation": variation - 0.02, "semantic": "castle_keep_palace_entrance_order"})
	add_part(blueprint, "castle_keep_palace_entrance_cornice", "beam", "stone_foundation", Vector3(center.x, foundation_height + bay_height - 0.28, front_z - bay_depth - 0.05), Vector3(bay_width + 0.72, 0.56, 0.34), {"variation": variation - 0.03, "semantic": "castle_keep_palace_entrance_cornice"})


static func add_keep_gabled_roof(blueprint, prefix: String, center: Vector3, width: float, depth: float, eave_y: float, rise: float, variation: float) -> void:
	var overhang := 0.72
	var slope_length := sqrt(width * width * 0.25 + rise * rise) + overhang
	var angle := atan2(rise, width * 0.5)
	var roof_y := eave_y + rise * 0.5
	add_part(blueprint, "%s_left" % prefix, "roof", "roof_shingle", Vector3(center.x - width * 0.25, roof_y, center.z), Vector3(slope_length, 0.28, depth + overhang * 2.0), {"rotation": Vector3(0.0, 0.0, angle), "variation": variation, "semantic": "castle_keep_roof"})
	add_part(blueprint, "%s_right" % prefix, "roof", "roof_shingle", Vector3(center.x + width * 0.25, roof_y, center.z), Vector3(slope_length, 0.28, depth + overhang * 2.0), {"rotation": Vector3(0.0, 0.0, -angle), "variation": variation, "semantic": "castle_keep_roof"})
	add_part(blueprint, "%s_ridge" % prefix, "beam", "timber_beam", Vector3(center.x, eave_y + rise, center.z), Vector3(0.42, 0.34, depth + overhang * 2.0 + 0.08), {"variation": variation, "semantic": "castle_keep_roof_ridge"})
	var gable_course_count := 7
	for face in [-1.0, 1.0]:
		for course in range(gable_course_count):
			var progress := float(course + 1) / float(gable_course_count)
			var course_width := width * (1.0 - progress * 0.88)
			var course_height := rise / float(gable_course_count) + 0.04
			var course_y := eave_y + (float(course) + 0.5) * rise / float(gable_course_count)
			add_part(blueprint, "%s_gable_%d_%02d" % [prefix, int(face), course], "wall", "stone_foundation", Vector3(center.x, course_y, center.z + face * (depth * 0.5 - 0.08)), Vector3(course_width, course_height, 0.34), {"variation": variation, "semantic": "castle_keep_roof_gable"})


static func add_keep_facade_articulation(blueprint, center: Vector3, width: float, depth: float, hall_height: float, foundation_height: float, variation: float, masonry_material: String, palace_grammar: Dictionary) -> void:
	var front_z := center.z - depth * 0.5 - 0.58
	var tower_span := clampf(width * float(palace_grammar.get("frontTowerSpanRatio", 0.18)), 4.6, 6.4)
	var tower_height := hall_height + clampf(hall_height * 0.16, 2.4, 4.2)
	var dominant_side := float(palace_grammar.get("dominantSide", -1.0))
	for side in [-1.0, 1.0]:
		var resolved_tower_height := tower_height + (float(palace_grammar.get("frontTowerDominantHeight", 3.4)) if side == dominant_side else float(palace_grammar.get("frontTowerSecondaryHeight", -1.8)))
		var tower_center := Vector3(center.x + side * (width * 0.5 - tower_span * 0.42), 0.0, front_z + tower_span * 0.34)
		add_part(blueprint, "castle_keep_front_tower_%d" % int(side), "wall", masonry_material, Vector3(tower_center.x, foundation_height + resolved_tower_height * 0.5, tower_center.z), Vector3(tower_span, resolved_tower_height, tower_span), {"variation": variation + side * 0.01, "semantic": "castle_keep_tower"})
		add_keep_gabled_roof(blueprint, "castle_keep_front_tower_roof_%d" % int(side), tower_center, tower_span + 0.34, tower_span + 0.34, foundation_height + resolved_tower_height, tower_span * 0.62, variation + side * 0.01)
	var bay_count := maxi(2, floori(width / 9.0))
	for bay in range(1, bay_count):
		var x := lerpf(center.x - width * 0.5, center.x + width * 0.5, float(bay) / float(bay_count))
		if absf(x - center.x) < maxf(2.4, width * 0.08):
			continue
		add_part(blueprint, "castle_keep_front_buttress_%02d" % bay, "wall", "stone_foundation", Vector3(x, foundation_height + hall_height * 0.30, front_z - 0.12), Vector3(0.72, hall_height * 0.60, 1.14), {"variation": variation - 0.03, "semantic": "castle_keep_buttress"})
	for wear_side in [-1.0, 1.0]:
		add_part(blueprint, "castle_keep_entry_damp_%d" % int(wear_side), "ground_patch", "drainage_stain", Vector3(center.x + wear_side * 2.05, foundation_height + 1.02, front_z - 0.74), Vector3(1.10, 0.02, 1.72), {"rotation": Vector3(PI * 0.5, 0.0, 0.0), "collision": false, "variation": variation - 0.05 + wear_side * 0.008, "semantic": "castle_keep_entry_weathering"})
		add_part(blueprint, "castle_keep_entry_growth_%d" % int(wear_side), "ground_patch", "wall_growth", Vector3(center.x + wear_side * 2.62, foundation_height + 0.42, front_z - 0.76), Vector3(0.72, 0.02, 0.58), {"rotation": Vector3(PI * 0.5, 0.0, 0.0), "collision": false, "variation": variation - 0.04, "semantic": "castle_keep_entry_weathering"})


static func add_keep_palace_wings(blueprint, center: Vector3, width: float, depth: float, hall_height: float, foundation_height: float, variation: float, masonry_material: String, palace_grammar: Dictionary) -> void:
	var wing_width := width * float(palace_grammar.get("wingWidthRatio", 0.68))
	var wing_depth := depth * float(palace_grammar.get("wingDepthRatio", 0.68))
	var wing_height := hall_height * float(palace_grammar.get("wingHeightRatio", 0.74))
	var wing_z := center.z + depth * float(palace_grammar.get("wingZRatio", -0.16))
	var wing_z_asymmetry := float(palace_grammar.get("wingZAsymmetry", 1.4))
	var dominant_side := float(palace_grammar.get("dominantSide", -1.0))
	for side in [-1.0, 1.0]:
		var offset_ratio := float(palace_grammar.get("wingOffsetLeftRatio", 0.58)) if side < 0.0 else float(palace_grammar.get("wingOffsetRightRatio", 0.54))
		var resolved_depth_bias := float(palace_grammar.get("dominantWingDepthBias", 0.0)) if side == dominant_side else float(palace_grammar.get("secondaryWingDepthBias", 0.0))
		var resolved_wing_depth := wing_depth * (1.0 + resolved_depth_bias)
		var forward_bias := float(palace_grammar.get("dominantWingForwardBias", 0.0)) if side == dominant_side else float(palace_grammar.get("secondaryWingForwardBias", 0.0))
		var wing_center := Vector3(center.x + side * width * offset_ratio, 0.0, wing_z + side * wing_z_asymmetry * 0.5 - depth * forward_bias)
		add_part(blueprint, "castle_keep_palace_wing_%d" % int(side), "wall", masonry_material, Vector3(wing_center.x, foundation_height + wing_height * 0.5, wing_center.z), Vector3(wing_width, wing_height, resolved_wing_depth), {"variation": variation + side * 0.012, "semantic": "castle_keep_palace_wing"})
		add_keep_gabled_roof(blueprint, "castle_keep_palace_wing_roof_%d" % int(side), wing_center, wing_width, resolved_wing_depth, foundation_height + wing_height, maxf(3.4, wing_width * 0.32), variation + side * 0.012)
		var resolved_outer_x: float = wing_center.x + side * (wing_width * 0.5 + 0.39)
		var outer_bay_count := 3
		for outer_bay in range(outer_bay_count):
			var outer_bay_z := wing_center.z + lerpf(-resolved_wing_depth * 0.32, resolved_wing_depth * 0.32, float(outer_bay) / float(outer_bay_count - 1))
			add_part(blueprint, "castle_keep_palace_wing_outer_pier_%d_%02d" % [int(side), outer_bay], "wall", "stone_foundation", Vector3(resolved_outer_x + side * 0.10, foundation_height + wing_height * 0.34, outer_bay_z), Vector3(0.52, wing_height * 0.68, 0.68), {"variation": variation - 0.02, "semantic": "castle_keep_palace_wing_outer_bay"})
			for level in range(2):
				add_part(blueprint, "castle_keep_palace_wing_outer_window_%d_%02d_%02d" % [int(side), level, outer_bay], "window", "window_glass", Vector3(resolved_outer_x + side * 0.22, foundation_height + 2.15 + float(level) * 3.25, outer_bay_z), Vector3(0.14, 1.58, 0.96), {"collision": false, "variation": variation, "semantic": "castle_keep_palace_window"})
		add_part(blueprint, "castle_keep_palace_wing_outer_cornice_%d" % int(side), "beam", "stone_foundation", Vector3(resolved_outer_x + side * 0.12, foundation_height + wing_height * 0.72, wing_center.z), Vector3(0.46, 0.44, resolved_wing_depth * 0.78), {"variation": variation - 0.02, "semantic": "castle_keep_palace_wing_outer_bay"})
		for transverse_face in [-1.0, 1.0]:
			var transverse_z: float = wing_center.z + transverse_face * (resolved_wing_depth * 0.5 + 0.39)
			add_part(blueprint, "castle_keep_palace_wing_transverse_cornice_%d_%d" % [int(side), int(transverse_face)], "beam", "stone_foundation", Vector3(wing_center.x, foundation_height + wing_height * 0.72, transverse_z), Vector3(wing_width * 0.76, 0.44, 0.46), {"variation": variation - 0.02, "semantic": "castle_keep_palace_wing_transverse_bay"})
			for transverse_bay in range(3):
				var transverse_x := wing_center.x + (float(transverse_bay) - 1.0) * wing_width * 0.24
				add_part(blueprint, "castle_keep_palace_wing_transverse_pier_%d_%d_%02d" % [int(side), int(transverse_face), transverse_bay], "wall", "stone_foundation", Vector3(transverse_x, foundation_height + wing_height * 0.34, transverse_z + transverse_face * 0.10), Vector3(0.68, wing_height * 0.68, 0.52), {"variation": variation - 0.02, "semantic": "castle_keep_palace_wing_transverse_bay"})
				for level in range(2):
					add_part(blueprint, "castle_keep_palace_wing_transverse_window_%d_%d_%02d_%02d" % [int(side), int(transverse_face), level, transverse_bay], "window", "window_glass", Vector3(transverse_x, foundation_height + 2.15 + float(level) * 3.25, transverse_z + transverse_face * 0.22), Vector3(0.96, 1.58, 0.14), {"collision": false, "variation": variation, "semantic": "castle_keep_palace_window"})
		var hall_edge_x: float = center.x + side * width * 0.5
		var wing_inner_x: float = wing_center.x - side * wing_width * 0.5
		var connector_width := absf(wing_inner_x - hall_edge_x) + 1.20
		var connector_center_x: float = (hall_edge_x + wing_inner_x) * 0.5
		var connector_depth := resolved_wing_depth * float(palace_grammar.get("connectorDepthRatio", 0.50))
		var connector_height := wing_height * float(palace_grammar.get("connectorHeightRatio", 0.54))
		var connector_center := Vector3(connector_center_x, 0.0, lerpf(center.z, wing_center.z, 0.58))
		add_part(blueprint, "castle_keep_palace_connector_%d" % int(side), "wall", masonry_material, Vector3(connector_center.x, foundation_height + connector_height * 0.5, connector_center.z), Vector3(connector_width, connector_height, connector_depth), {"variation": variation + side * 0.009, "semantic": "castle_keep_palace_connector"})
		add_keep_gabled_roof(blueprint, "castle_keep_palace_connector_roof_%d" % int(side), connector_center, connector_width, connector_depth, foundation_height + connector_height, maxf(1.8, connector_width * 0.24), variation + side * 0.009)
		var pavilion_span := clampf(wing_width * float(palace_grammar.get("pavilionSpanRatio", 0.40)), 4.4, 6.2)
		var pavilion_center := wing_center + Vector3(side * wing_width * 0.36, 0.0, -resolved_wing_depth * 0.34)
		var pavilion_height := wing_height + float(palace_grammar.get("pavilionHeightAdd", 2.2))
		add_part(blueprint, "castle_keep_palace_pavilion_%d" % int(side), "wall", masonry_material, Vector3(pavilion_center.x, foundation_height + pavilion_height * 0.5, pavilion_center.z), Vector3(pavilion_span, pavilion_height, pavilion_span), {"variation": variation - side * 0.01, "semantic": "castle_keep_palace_pavilion"})
		add_keep_gabled_roof(blueprint, "castle_keep_palace_pavilion_roof_%d" % int(side), pavilion_center, pavilion_span + 0.28, pavilion_span + 0.28, foundation_height + pavilion_height, pavilion_span * 0.68, variation - side * 0.01)
		var end_depth := resolved_wing_depth * float(palace_grammar.get("endPavilionDepthRatio", 0.44))
		var end_width := wing_width * (0.34 if side == dominant_side else 0.27)
		var end_height := wing_height * (1.10 if side == dominant_side else 0.88)
		var end_inset := resolved_wing_depth * float(palace_grammar.get("endPavilionInsetRatio", 0.10))
		var end_center := Vector3(wing_center.x + side * (wing_width * 0.5 - end_width * 0.5), 0.0, wing_center.z + resolved_wing_depth * 0.5 - end_depth * 0.5 - end_inset)
		add_part(blueprint, "castle_keep_palace_end_pavilion_%d" % int(side), "wall", masonry_material, Vector3(end_center.x, foundation_height + end_height * 0.5, end_center.z), Vector3(end_width, end_height, end_depth), {"variation": variation + side * 0.014, "semantic": "castle_keep_palace_end_pavilion"})
		add_keep_gabled_roof(blueprint, "castle_keep_palace_end_pavilion_roof_%d" % int(side), end_center, end_width, end_depth, foundation_height + end_height, maxf(2.2, end_width * 0.42), variation + side * 0.014)
		var end_face_x: float = end_center.x + side * (end_width * 0.5 + 0.42)
		add_part(blueprint, "castle_keep_palace_end_recess_%d" % int(side), "wall", "stone_foundation", Vector3(end_face_x, foundation_height + end_height * 0.46, end_center.z), Vector3(0.34, end_height * 0.72, end_depth * 0.62), {"variation": variation - 0.02, "semantic": "castle_keep_palace_recessed_bay"})
		for level in range(2):
			for bay in range(2):
				var end_window_z := end_center.z + (float(bay) - 0.5) * end_depth * 0.28
				add_part(blueprint, "castle_keep_palace_end_window_%d_%d_%d" % [int(side), level, bay], "window", "window_glass", Vector3(end_face_x + side * 0.20, foundation_height + 2.2 + float(level) * 3.2, end_window_z), Vector3(0.14, 1.6, 0.92), {"collision": false, "variation": variation, "semantic": "castle_keep_palace_window"})


static func add_keep_palace_dome(blueprint, center: Vector3, span: float, base_y: float, register_height: float, variation: float, masonry_material: String, palace_grammar: Dictionary) -> void:
	var drum_span := maxf(12.4, span * float(palace_grammar.get("drumSpanRatio", 1.36)))
	var drum_height := maxf(4.0, register_height * float(palace_grammar.get("drumHeightRatio", 0.60)))
	var drum_base_y := base_y + register_height - float(palace_grammar.get("drumSeatOverlap", 0.24))
	var drum_y := drum_base_y + drum_height * 0.5
	var drum_radius := drum_span * 0.46
	var drum_panel_width := drum_span * 0.38
	for panel_index in range(8):
		var panel_angle := float(panel_index) * TAU / 8.0
		var panel_center := Vector3(center.x + sin(panel_angle) * drum_radius, drum_y, center.z + cos(panel_angle) * drum_radius)
		add_part(blueprint, "castle_keep_palace_drum_%02d" % panel_index, "wall", masonry_material, panel_center, Vector3(drum_panel_width, drum_height, 0.72), {"rotation": Vector3(0.0, panel_angle, 0.0), "variation": variation + float(panel_index) * 0.003, "semantic": "castle_keep_palace_drum"})
		if panel_index % 2 == 0:
			var window_center := panel_center + Vector3(sin(panel_angle) * 0.38, 0.0, cos(panel_angle) * 0.38)
			add_part(blueprint, "castle_keep_palace_drum_window_%02d" % panel_index, "window", "window_glass", window_center, Vector3(1.16, minf(2.2, drum_height * 0.46), 0.14), {"rotation": Vector3(0.0, panel_angle, 0.0), "collision": false, "variation": variation, "semantic": "castle_keep_palace_window"})
	var tier_count := int(palace_grammar.get("domeTierCount", 7))
	var tier_step := float(palace_grammar.get("domeTierStep", 0.78))
	var dome_twist := bool(palace_grammar.get("domeTwist", false))
	var dome_base_y := drum_base_y + drum_height
	# A nested octagonal shell is stable under every scale and has no transformed
	# panel seams. Each course overlaps the one below and narrows toward the
	# lantern, preserving the compact stepped crown already proven in the keep PoC.
	for tier_index in range(tier_count):
		var progress := float(tier_index) / float(maxi(1, tier_count - 1))
		var tier_span := lerpf(drum_span * 1.04, maxf(2.4, drum_span * 0.18), progress)
		var tier_y := dome_base_y + float(tier_index) * tier_step + tier_step * 0.50
		var tier_radius := tier_span * 0.44
		var panel_width := tier_span * 0.40
		for panel_index in range(8):
			var panel_angle := float(panel_index) * TAU / 8.0 + (PI * 0.125 if dome_twist and tier_index % 2 == 1 else 0.0)
			var panel_center := Vector3(center.x + sin(panel_angle) * tier_radius, tier_y, center.z + cos(panel_angle) * tier_radius)
			add_part(blueprint, "castle_keep_palace_dome_%02d_%02d" % [tier_index, panel_index], "roof", "roof_shingle", panel_center, Vector3(panel_width, tier_step + 0.08, 0.54), {"rotation": Vector3(0.0, panel_angle, 0.0), "variation": variation + float(panel_index) * 0.002, "semantic": "castle_keep_palace_dome"})
	var lantern_base_y := dome_base_y + float(tier_count) * tier_step
	add_part(blueprint, "castle_keep_palace_lantern", "beam", "stone_foundation", Vector3(center.x, lantern_base_y + 1.4, center.z), Vector3(1.35, 2.8, 1.35), {"variation": variation - 0.02, "semantic": "castle_keep_palace_lantern"})
	add_keep_gabled_roof(blueprint, "castle_keep_palace_lantern_roof", Vector3(center.x, 0.0, center.z), 2.05, 2.05, lantern_base_y + 2.8, 1.48, variation - 0.02)


static func add_keep_palace_entry_court(blueprint, center: Vector3, width: float, depth: float, foundation_height: float, variation: float, palace_grammar: Dictionary) -> void:
	var front_z := center.z - depth * 0.5
	var court_width := width * float(palace_grammar.get("courtWidthRatio", 0.56))
	var court_depth := clampf(depth * float(palace_grammar.get("courtDepthRatio", 0.24)), 5.0, 8.0)
	add_part(blueprint, "castle_keep_palace_entry_court", "foundation", "stone_foundation", Vector3(center.x, foundation_height + 0.14, front_z - court_depth * 0.5), Vector3(court_width, 0.28, court_depth), {"variation": variation - 0.04, "semantic": "castle_keep_palace_entry_court"})
	var entry_step_count := int(palace_grammar.get("entryStepCount", 4))
	var approach_length := depth * float(palace_grammar.get("approachLengthRatio", 0.40))
	add_part(blueprint, "castle_keep_palace_processional_terrace", "foundation", "stone_foundation", Vector3(center.x, foundation_height * 0.38, front_z - court_depth - approach_length * 0.5), Vector3(court_width * 0.62, foundation_height * 0.76, approach_length), {"variation": variation - 0.04, "semantic": "castle_keep_palace_processional_terrace"})
	var court_wall_height := float(palace_grammar.get("courtWallHeight", 1.4))
	add_part(blueprint, "castle_keep_palace_court_gate_header", "beam", "stone_foundation", Vector3(center.x, foundation_height + court_wall_height * 1.08, front_z - court_depth - approach_length), Vector3(court_width * 0.42, 0.72, 0.84), {"variation": variation - 0.04, "semantic": "castle_keep_palace_court_gate"})
	for landing_index in range(3):
		var landing_depth := approach_length / 3.0
		var landing_height := foundation_height * (0.30 + float(landing_index) * 0.22)
		add_part(blueprint, "castle_keep_palace_processional_landing_%02d" % landing_index, "foundation", "stone_foundation", Vector3(center.x, landing_height * 0.5, front_z - court_depth - approach_length + landing_depth * (float(landing_index) + 0.5)), Vector3(court_width * (0.48 + float(landing_index) * 0.06), landing_height, landing_depth), {"variation": variation - 0.04, "semantic": "castle_keep_palace_processional_landing"})
	for step_index in range(entry_step_count):
		var step_progress := float(step_index + 1) / float(entry_step_count)
		var step_height := foundation_height * step_progress
		var step_depth := 0.72
		var step_z := front_z - court_depth - approach_length - float(entry_step_count - step_index) * step_depth + step_depth * 0.5
		add_part(blueprint, "castle_keep_palace_entry_step_%02d" % step_index, "foundation", "stone_foundation", Vector3(center.x, step_height * 0.5, step_z), Vector3(court_width * (0.52 + step_progress * 0.18), step_height, step_depth + 0.04), {"variation": variation - 0.04, "semantic": "castle_keep_palace_entry_step"})
	for side in [-1.0, 1.0]:
		add_part(blueprint, "castle_keep_palace_entry_column_%d" % int(side), "beam", "stone_foundation", Vector3(center.x + side * 2.15, foundation_height + 2.30, front_z - 0.62), Vector3(0.72, 4.60, 0.72), {"variation": variation - 0.03, "semantic": "castle_keep_palace_entry_column"})
	add_part(blueprint, "castle_keep_palace_entry_pediment", "beam", "stone_foundation", Vector3(center.x, foundation_height + 4.34, front_z - 0.62), Vector3(5.18, 0.54, 0.88), {"variation": variation - 0.03, "semantic": "castle_keep_palace_entry_pediment"})


static func add_keep_palace_forecourt_galleries(blueprint, center: Vector3, width: float, depth: float, foundation_height: float, variation: float, masonry_material: String, palace_grammar: Dictionary) -> void:
	var front_z := center.z - depth * 0.5
	var base_gallery_depth := clampf(depth * (float(palace_grammar.get("galleryDepthRatio", 0.36)) + float(palace_grammar.get("galleryDepthBias", 0.0))), 7.0, 14.0)
	var gallery_x := width * float(palace_grammar.get("galleryXRatio", 0.34))
	var gallery_width := clampf(width * float(palace_grammar.get("galleryWidthRatio", 0.20)), 4.8, 6.4)
	var gallery_height := maxf(5.8, float(palace_grammar.get("galleryHeight", 4.8)))
	var dominant_side := float(palace_grammar.get("dominantSide", -1.0))
	var arcade_share := float(palace_grammar.get("galleryArcadeShare", 0.50))
	var flare_ratio := float(palace_grammar.get("galleryFlareRatio", 0.07))
	for side in [-1.0, 1.0]:
		var depth_scale := float(palace_grammar.get("dominantGalleryDepthScale", 0.78)) if side == dominant_side else float(palace_grammar.get("secondaryGalleryDepthScale", 0.54))
		var gallery_depth := base_gallery_depth * depth_scale
		var arcade_depth := gallery_depth * arcade_share
		var pavilion_depth := maxf(2.8, gallery_depth * float(palace_grammar.get("galleryPavilionDepthRatio", 0.34)))
		var gallery_center := Vector3(center.x + side * gallery_x, 0.0, front_z - arcade_depth * 0.5)
		var outer_flare: float = side * width * flare_ratio * (1.0 if side == dominant_side else 0.72)
		var pavilion_center := Vector3(gallery_center.x + outer_flare, 0.0, front_z - arcade_depth - pavilion_depth * 0.5 + 0.30)
		var gallery_bay_count := maxi(2, roundi(float(palace_grammar.get("galleryBayCount", 5)) * depth_scale * arcade_share + 0.5))
		add_part(blueprint, "castle_keep_forecourt_gallery_floor_%d" % int(side), "foundation", "stone_foundation", Vector3(gallery_center.x, foundation_height + 0.10, gallery_center.z), Vector3(gallery_width, 0.20, arcade_depth), {"variation": variation, "semantic": "castle_keep_forecourt_gallery"})
		var arcade_clear_height := clampf(gallery_height * 0.48, 2.8, 3.2)
		var upper_storey_height := gallery_height - arcade_clear_height
		var outer_wall_x: float = gallery_center.x + side * (gallery_width * 0.5 - 0.25)
		add_part(blueprint, "castle_keep_forecourt_gallery_outer_wall_%d" % int(side), "wall", masonry_material, Vector3(outer_wall_x, foundation_height + gallery_height * 0.5, gallery_center.z), Vector3(0.50, gallery_height, arcade_depth), {"variation": variation + side * 0.008, "semantic": "castle_keep_forecourt_gallery_occupied_wall"})
		var inner_wall_x: float = gallery_center.x - side * (gallery_width * 0.5 - 0.25)
		add_part(blueprint, "castle_keep_forecourt_gallery_upper_storey_%d" % int(side), "wall", masonry_material, Vector3(inner_wall_x, foundation_height + arcade_clear_height + upper_storey_height * 0.5, gallery_center.z), Vector3(0.50, upper_storey_height, arcade_depth), {"variation": variation + side * 0.008, "semantic": "castle_keep_forecourt_gallery_upper_storey"})
		var bay_depth := arcade_depth / float(gallery_bay_count)
		for bay in range(gallery_bay_count):
			var occupied_z := gallery_center.z - arcade_depth * 0.5 + bay_depth * (float(bay) + 0.5)
			var window_x: float = inner_wall_x - side * 0.30
			add_part(blueprint, "castle_keep_forecourt_gallery_window_%d_%02d" % [int(side), bay], "window", "window_glass", Vector3(window_x, foundation_height + arcade_clear_height + upper_storey_height * 0.52, occupied_z), Vector3(0.12, minf(1.38, upper_storey_height * 0.58), maxf(0.58, bay_depth * 0.42)), {"collision": false, "variation": variation + side * 0.01, "semantic": "castle_keep_forecourt_gallery_window"})
		for bay in range(gallery_bay_count + 1):
			var bay_z := gallery_center.z - arcade_depth * 0.5 + float(bay) * arcade_depth / float(gallery_bay_count)
			add_part(blueprint, "castle_keep_forecourt_gallery_column_%d_%02d" % [int(side), bay], "beam", "stone_foundation", Vector3(inner_wall_x, foundation_height + arcade_clear_height * 0.5, bay_z), Vector3(0.48, arcade_clear_height, 0.48), {"variation": variation + side * 0.008, "semantic": "castle_keep_forecourt_arcade"})
		add_part(blueprint, "castle_keep_forecourt_gallery_arcade_header_%d" % int(side), "beam", masonry_material, Vector3(inner_wall_x, foundation_height + arcade_clear_height - 0.18, gallery_center.z), Vector3(0.58, 0.36, arcade_depth + 0.18), {"variation": variation + side * 0.008, "semantic": "castle_keep_forecourt_arcade_header"})
		add_keep_gabled_roof(blueprint, "castle_keep_forecourt_gallery_roof_%d" % int(side), gallery_center, gallery_width, arcade_depth, foundation_height + gallery_height, 2.2, variation + side * 0.008)
		var pavilion_height := gallery_height + float(palace_grammar.get("galleryPavilionHeightAdd", 1.8)) * (1.0 if side == dominant_side else 0.72)
		var pavilion_width := gallery_width * (1.12 if side == dominant_side else 0.94)
		add_part(blueprint, "castle_keep_forecourt_pavilion_%d" % int(side), "wall", masonry_material, Vector3(pavilion_center.x, foundation_height + pavilion_height * 0.5, pavilion_center.z), Vector3(pavilion_width, pavilion_height, pavilion_depth), {"variation": variation + side * 0.012, "semantic": "castle_keep_forecourt_pavilion"})
		add_keep_gabled_roof(blueprint, "castle_keep_forecourt_pavilion_roof_%d" % int(side), pavilion_center, pavilion_width, pavilion_depth, foundation_height + pavilion_height, maxf(2.2, pavilion_width * 0.46), variation + side * 0.012)
		for level in range(2):
			var window_center := Vector3(pavilion_center.x - side * (pavilion_width * 0.5 + 0.04), foundation_height + 1.78 + float(level) * 2.45, pavilion_center.z)
			add_part(blueprint, "castle_keep_forecourt_pavilion_window_%d_%02d" % [int(side), level], "window", "window_glass", window_center, Vector3(0.10, 1.30, minf(1.04, pavilion_depth * 0.34)), {"collision": false, "variation": variation + side * 0.01, "semantic": "castle_keep_palace_window"})


static func add_keep_palace_rear_court(blueprint, center: Vector3, width: float, depth: float, hall_height: float, foundation_height: float, variation: float, masonry_material: String, palace_grammar: Dictionary) -> void:
	var rear_z := center.z + depth * 0.5
	var court_depth := clampf(depth * float(palace_grammar.get("rearCourtDepthRatio", 0.22)), 4.2, 8.4)
	var portico_width := width * float(palace_grammar.get("rearPorticoWidthRatio", 0.36))
	var portico_height := clampf(hall_height * 0.28, 3.8, 5.4)
	var portico_center := Vector3(center.x, 0.0, rear_z + court_depth * 0.46)
	add_part(blueprint, "castle_keep_rear_court", "foundation", "stone_foundation", Vector3(center.x, foundation_height + 0.10, rear_z + court_depth * 0.5), Vector3(width * 0.72, 0.20, court_depth), {"variation": variation, "semantic": "castle_keep_rear_court"})
	for column_index in range(5):
		var column_x := center.x + lerpf(-portico_width * 0.5, portico_width * 0.5, float(column_index) / 4.0)
		add_part(blueprint, "castle_keep_rear_portico_column_%02d" % column_index, "beam", "stone_foundation", Vector3(column_x, foundation_height + portico_height * 0.5, portico_center.z), Vector3(0.58, portico_height, 0.58), {"variation": variation, "semantic": "castle_keep_rear_portico"})
	add_part(blueprint, "castle_keep_rear_portico_entablature", "beam", masonry_material, Vector3(portico_center.x, foundation_height + portico_height - 0.26, portico_center.z), Vector3(portico_width + 0.60, 0.52, 0.82), {"variation": variation, "semantic": "castle_keep_rear_portico"})
	add_keep_gabled_roof(blueprint, "castle_keep_rear_portico_roof", portico_center, portico_width + 0.8, maxf(3.2, court_depth * 0.52), foundation_height + portico_height, 2.0, variation)
	var service_bias := width * float(palace_grammar.get("rearServiceWingBias", 0.08))
	for side in [-1.0, 1.0]:
		var service_width := width * (0.22 if side < 0.0 else 0.18)
		var service_depth := court_depth * (0.72 if side < 0.0 else 0.58)
		var service_height := portico_height * (1.18 if side < 0.0 else 0.96)
		var service_center := Vector3(center.x + side * (width * 0.34 + service_bias * side), 0.0, rear_z + service_depth * 0.42)
		add_part(blueprint, "castle_keep_rear_service_%d" % int(side), "wall", masonry_material, Vector3(service_center.x, foundation_height + service_height * 0.5, service_center.z), Vector3(service_width, service_height, service_depth), {"variation": variation + side * 0.01, "semantic": "castle_keep_rear_service"})
		add_keep_gabled_roof(blueprint, "castle_keep_rear_service_roof_%d" % int(side), service_center, service_width, service_depth, foundation_height + service_height, maxf(1.8, service_width * 0.28), variation + side * 0.01)
	var dominant_side := float(palace_grammar.get("dominantSide", -1.0))
	var cross_width := width * float(palace_grammar.get("rearCrossWingWidthRatio", 0.30))
	var cross_depth := depth * float(palace_grammar.get("rearCrossWingDepthRatio", 0.50))
	for side in [-1.0, 1.0]:
		var cross_height := hall_height * float(palace_grammar.get("rearCrossWingHeightRatio", 0.54)) * (1.10 if side == dominant_side else 0.90)
		var cross_center := Vector3(center.x + side * width * 0.30, 0.0, rear_z + cross_depth * 0.30)
		add_part(blueprint, "castle_keep_rear_cross_wing_%d" % int(side), "wall", masonry_material, Vector3(cross_center.x, foundation_height + cross_height * 0.5, cross_center.z), Vector3(cross_width, cross_height, cross_depth), {"variation": variation + side * 0.012, "semantic": "castle_keep_rear_cross_wing"})
		add_keep_gabled_roof(blueprint, "castle_keep_rear_cross_wing_roof_%d" % int(side), cross_center, cross_width, cross_depth, foundation_height + cross_height, maxf(2.4, cross_width * 0.34), variation + side * 0.012)
		var rear_face_z := cross_center.z + cross_depth * 0.5 + 0.39
		for level in range(2):
			for bay in range(3):
				var window_x := cross_center.x + (float(bay) - 1.0) * cross_width * 0.24
				if side == dominant_side and level == 0 and bay == 1:
					continue
				add_part(blueprint, "castle_keep_rear_cross_window_%d_%d_%d" % [int(side), level, bay], "window", "window_glass", Vector3(window_x, foundation_height + 2.15 + float(level) * 3.15, rear_face_z), Vector3(1.06, 1.58, 0.14), {"collision": false, "variation": variation, "semantic": "castle_keep_palace_window"})
		if side == dominant_side:
			add_part(blueprint, "castle_keep_rear_secondary_door", "door", "painted_door", Vector3(cross_center.x, foundation_height + 1.36, rear_face_z + 0.04), Vector3(1.42, 2.72, 0.18), {"variation": variation - 0.02, "semantic": "castle_keep_secondary_entry"})
			add_part(blueprint, "castle_keep_rear_secondary_lintel", "beam", "stone_foundation", Vector3(cross_center.x, foundation_height + 3.02, rear_face_z + 0.02), Vector3(2.38, 0.44, 0.42), {"variation": variation - 0.02, "semantic": "castle_keep_secondary_entry"})


static func add_keep_palace_window_rhythm(blueprint, center: Vector3, width: float, depth: float, hall_height: float, foundation_height: float, variation: float, palace_grammar: Dictionary) -> void:
	var front_z := center.z - depth * 0.5 - 0.39
	var levels := clampi(floori(hall_height / 3.7), 3, 5)
	var central_columns := int(palace_grammar.get("centralWindowColumns", 5))
	for level in range(levels):
		var y := foundation_height + 2.15 + float(level) * 3.35
		for column in range(central_columns):
			if level == 0 and column == central_columns / 2:
				continue
			var x := center.x + (float(column) - float(central_columns - 1) * 0.5) * width * 0.145
			add_part(blueprint, "castle_keep_palace_window_c_%02d_%02d" % [level, column], "window", "window_glass", Vector3(x, y, front_z), Vector3(1.18, 1.72, 0.14), {"collision": false, "variation": variation + float(column) * 0.004, "semantic": "castle_keep_palace_window"})
	var wing_width := width * float(palace_grammar.get("wingWidthRatio", 0.68))
	var wing_depth := depth * float(palace_grammar.get("wingDepthRatio", 0.68))
	var wing_front_z := center.z + depth * float(palace_grammar.get("wingZRatio", -0.16)) - wing_depth * 0.5 - 0.39
	for side in [-1.0, 1.0]:
		var offset_ratio := float(palace_grammar.get("wingOffsetLeftRatio", 0.58)) if side < 0.0 else float(palace_grammar.get("wingOffsetRightRatio", 0.54))
		var wing_center_x: float = center.x + side * width * offset_ratio
		for level in range(maxi(2, levels - 1)):
			var y := foundation_height + 2.15 + float(level) * 3.35
			var wing_columns := int(palace_grammar.get("wingWindowColumns", 4))
			for column in range(wing_columns):
				var x: float = wing_center_x + (float(column) - float(wing_columns - 1) * 0.5) * wing_width * 0.21
				add_part(blueprint, "castle_keep_palace_window_w%d_%02d_%02d" % [int(side), level, column], "window", "window_glass", Vector3(x, y, wing_front_z), Vector3(1.08, 1.62, 0.14), {"collision": false, "variation": variation + side * 0.01, "semantic": "castle_keep_palace_window"})
	var rear_z := center.z + depth * 0.5 + 0.39
	var rear_columns := int(palace_grammar.get("rearWindowColumns", 5))
	for level in range(levels):
		var rear_y := foundation_height + 2.15 + float(level) * 3.35
		for column in range(rear_columns):
			var rear_x := center.x + (float(column) - float(rear_columns - 1) * 0.5) * width * 0.14
			add_part(blueprint, "castle_keep_palace_window_rear_%02d_%02d" % [level, column], "window", "window_glass", Vector3(rear_x, rear_y, rear_z), Vector3(1.08, 1.62, 0.14), {"rotation": Vector3(0.0, PI, 0.0), "collision": false, "variation": variation, "semantic": "castle_keep_palace_window"})
	var wing_end_columns := int(palace_grammar.get("wingEndWindowColumns", 2))
	var wing_z_center := center.z + depth * float(palace_grammar.get("wingZRatio", -0.16))
	for side in [-1.0, 1.0]:
		var offset_ratio := float(palace_grammar.get("wingOffsetLeftRatio", 0.58)) if side < 0.0 else float(palace_grammar.get("wingOffsetRightRatio", 0.54))
		var outer_x: float = center.x + side * (width * offset_ratio + wing_width * 0.5 + 0.39)
		for level in range(maxi(2, levels - 1)):
			var end_y := foundation_height + 2.15 + float(level) * 3.35
			for column in range(wing_end_columns):
				var end_z := wing_z_center + (float(column) - float(wing_end_columns - 1) * 0.5) * wing_depth * 0.28
				add_part(blueprint, "castle_keep_palace_window_end%d_%02d_%02d" % [int(side), level, column], "window", "window_glass", Vector3(outer_x, end_y, end_z), Vector3(0.14, 1.62, 1.08), {"collision": false, "variation": variation + side * 0.01, "semantic": "castle_keep_palace_window"})
	var hall_side_columns := int(palace_grammar.get("hallSideWindowColumns", 4))
	for side in [-1.0, 1.0]:
		var side_x: float = center.x + side * (width * 0.5 + 0.39)
		for level in range(levels):
			var side_y := foundation_height + 2.15 + float(level) * 3.35
			for column in range(hall_side_columns):
				var side_z := center.z + (float(column) - float(hall_side_columns - 1) * 0.5) * depth * 0.21
				add_part(blueprint, "castle_keep_palace_window_side%d_%02d_%02d" % [int(side), level, column], "window", "window_glass", Vector3(side_x, side_y, side_z), Vector3(0.14, 1.62, 1.08), {"collision": false, "variation": variation + side * 0.01, "semantic": "castle_keep_palace_window"})
		for pier_index in range(1, hall_side_columns):
			var pier_z := center.z + lerpf(-depth * 0.42, depth * 0.42, float(pier_index) / float(hall_side_columns))
			add_part(blueprint, "castle_keep_palace_side_pier%d_%02d" % [int(side), pier_index], "wall", "stone_foundation", Vector3(side_x + side * 0.10, foundation_height + hall_height * 0.30, pier_z), Vector3(0.68, hall_height * 0.60, 0.78), {"variation": variation - 0.03, "semantic": "castle_keep_buttress"})
		var side_bay_count := int(palace_grammar.get("sideBayCount", 3))
		for bay_index in range(side_bay_count):
			var bay_z := center.z + lerpf(-depth * 0.34, depth * 0.34, float(bay_index) / float(maxi(1, side_bay_count - 1)))
			var bay_height := hall_height * (0.42 + 0.06 * float((bay_index + 1) % 2))
			add_part(blueprint, "castle_keep_palace_side_bay%d_%02d" % [int(side), bay_index], "wall", "stone_foundation", Vector3(side_x + side * 0.56, foundation_height + bay_height * 0.5, bay_z), Vector3(1.12, bay_height, maxf(2.2, depth * 0.14)), {"variation": variation - 0.02, "semantic": "castle_keep_palace_side_bay"})


static func add_keep_storey_floor_with_stairwell(blueprint, storey_index: int, center: Vector3, width: float, depth: float, stair_center: Vector3, stair_width: float, stair_depth: float, foundation_height: float, floor_height: float, variation: float) -> void:
	var inset := 0.74
	var min_x := center.x - width * 0.5 + inset
	var max_x := center.x + width * 0.5 - inset
	var min_z := center.z - depth * 0.5 + inset
	var max_z := center.z + depth * 0.5 - inset
	var hole_min_x := stair_center.x - stair_width * 0.5 - 0.06
	var hole_max_x := stair_center.x + stair_width * 0.5 + 0.06
	var hole_min_z := stair_center.z - stair_depth * 0.5 - 0.06
	var hole_max_z := stair_center.z + stair_depth * 0.5 + 0.06
	var floor_y := foundation_height + floor_height * float(storey_index) + 0.10
	# Four panels surround the stairwell on the exact same elevation.  The rear
	# right well is intentionally open, while all other floor area stays real
	# collision-backed stone.
	add_keep_floor_panel(blueprint, "castle_keep_storey_%02d_floor_front" % storey_index, min_x, max_x, min_z, hole_min_z, floor_y, variation)
	add_keep_floor_panel(blueprint, "castle_keep_storey_%02d_floor_back" % storey_index, min_x, max_x, hole_max_z, max_z, floor_y, variation)
	add_keep_floor_panel(blueprint, "castle_keep_storey_%02d_floor_left" % storey_index, min_x, hole_min_x, hole_min_z, hole_max_z, floor_y, variation)
	add_keep_floor_panel(blueprint, "castle_keep_storey_%02d_floor_right" % storey_index, hole_max_x, max_x, hole_min_z, hole_max_z, floor_y, variation)


static func add_keep_floor_panel(blueprint, part_id: String, min_x: float, max_x: float, min_z: float, max_z: float, y: float, variation: float) -> void:
	if max_x - min_x <= 0.08 or max_z - min_z <= 0.08:
		return
	add_part(blueprint, part_id, "floor", "stone_foundation", Vector3((min_x + max_x) * 0.5, y, (min_z + max_z) * 0.5), Vector3(max_x - min_x, 0.20, max_z - min_z), {"variation": variation, "semantic": "castle_keep_storey_floor"})


static func add_switchback_stair_flights(blueprint, prefix: String, center: Vector3, span_width: float, span_depth: float, base_y: float, rise_per_level: float, level_count: int, material: String, variation: float, semantic: String) -> void:
	# This is the same construction logic proven by the manor: visible treads
	# express the staircase, while continuous hidden stringers provide smooth
	# collision all the way between landings.  It is shared here so the keep and
	# gatehouse do not grow competing vertical-movement implementations.
	var run := maxf(1.42, span_depth - 0.72)
	var half_rise := rise_per_level * 0.5
	var angle := atan2(half_rise, run)
	var ramp_width := clampf(span_width * 0.30, 0.70, 1.10)
	var lateral_offset := minf(span_width * 0.20, maxf(0.34, span_width * 0.5 - ramp_width * 0.60))
	var left_x := center.x - lateral_offset
	var right_x := center.x + lateral_offset
	var tread_count := maxi(7, ceili(half_rise / 0.24))
	var tread_run := run / float(tread_count)
	var tread_rise := half_rise / float(tread_count)
	for level in range(maxi(1, level_count)):
		var level_base_y := base_y + rise_per_level * float(level)
		add_part(blueprint, "%s_up_stringer_%02d" % [prefix, level], "ramp", material, Vector3(left_x, level_base_y + half_rise * 0.5, center.z), Vector3(ramp_width, 0.18, run), {"rotation": Vector3(-angle, 0.0, 0.0), "visual": false, "variation": variation, "semantic": "%s_stringer" % semantic})
		for tread_index in range(tread_count):
			var up_z := center.z - run * 0.5 + tread_run * (float(tread_index) + 0.5)
			var up_y := level_base_y + tread_rise * float(tread_index + 1) - 0.055
			add_part(blueprint, "%s_up_tread_%02d_%02d" % [prefix, level, tread_index], "stair_tread", material, Vector3(left_x, up_y, up_z), Vector3(ramp_width, 0.11, tread_run + 0.025), {"variation": variation, "semantic": "%s_tread" % semantic})
		add_part(blueprint, "%s_landing_%02d" % [prefix, level], "floor", material, Vector3(center.x, level_base_y + half_rise, center.z + run * 0.5), Vector3(span_width - 0.18, 0.20, 0.58), {"variation": variation, "semantic": "%s_landing" % semantic})
		add_part(blueprint, "%s_return_stringer_%02d" % [prefix, level], "ramp", material, Vector3(right_x, level_base_y + half_rise * 1.50, center.z), Vector3(ramp_width, 0.18, run), {"rotation": Vector3(angle, 0.0, 0.0), "visual": false, "variation": variation, "semantic": "%s_stringer" % semantic})
		for tread_index in range(tread_count):
			var return_z := center.z + run * 0.5 - tread_run * (float(tread_index) + 0.5)
			var return_y := level_base_y + half_rise + tread_rise * float(tread_index + 1) - 0.055
			add_part(blueprint, "%s_return_tread_%02d_%02d" % [prefix, level, tread_index], "stair_tread", material, Vector3(right_x, return_y, return_z), Vector3(ramp_width, 0.11, tread_run + 0.025), {"variation": variation, "semantic": "%s_tread" % semantic})
		add_part(blueprint, "%s_exit_%02d" % [prefix, level], "floor", material, Vector3(center.x, level_base_y + rise_per_level, center.z - run * 0.5), Vector3(span_width - 0.18, 0.20, 0.58), {"variation": variation, "semantic": "%s_exit" % semantic})


static func add_crenellations(blueprint, prefix: String, center: Vector3, width: float, depth: float, y: float, variation: float) -> void:
	var unit := 1.18
	var x_count := maxi(2, ceili(width / unit))
	var z_count := maxi(2, ceili(depth / unit))
	for index in range(x_count):
		var x := center.x - width * 0.5 + width * (float(index) + 0.5) / float(x_count)
		add_part(blueprint, "%s_front_%d" % [prefix, index], "beam", "stone_foundation", Vector3(x, y, center.z - depth * 0.5), Vector3(width / float(x_count) * 0.54, 0.58, 0.54), {"variation": variation, "semantic": "castle_battlement"})
		add_part(blueprint, "%s_back_%d" % [prefix, index], "beam", "stone_foundation", Vector3(x, y, center.z + depth * 0.5), Vector3(width / float(x_count) * 0.54, 0.58, 0.54), {"variation": variation, "semantic": "castle_battlement"})
	for index in range(z_count):
		var z := center.z - depth * 0.5 + depth * (float(index) + 0.5) / float(z_count)
		add_part(blueprint, "%s_left_%d" % [prefix, index], "beam", "stone_foundation", Vector3(center.x - width * 0.5, y, z), Vector3(0.54, 0.58, depth / float(z_count) * 0.54), {"variation": variation, "semantic": "castle_battlement"})
		add_part(blueprint, "%s_right_%d" % [prefix, index], "beam", "stone_foundation", Vector3(center.x + width * 0.5, y, z), Vector3(0.54, 0.58, depth / float(z_count) * 0.54), {"variation": variation, "semantic": "castle_battlement"})


static func add_part(blueprint, part_id: String, kind: String, material: String, position: Vector3, size: Vector3, options: Dictionary = {}) -> void:
	var resolved_material := material
	var semantic := String(options.get("semantic", kind))
	if kind == "window" and material == "window_glass" and (semantic.contains("palace") or semantic.contains("occupied") or semantic.contains("gallery")):
		var window_phase := posmod(part_id.hash(), 7)
		if window_phase in [0, 2, 3]:
			resolved_material = "window_warm_glass"
	LandmarkBuildingBlueprintBuilderScript.add_part(blueprint, part_id, kind, resolved_material, position, size, options)
