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
	var keep_offset: Dictionary = grammar.get("keepOffset", {}) as Dictionary
	# The gate is centred at x = 0, and the keep must stay on that same axis.
	# Do not reintroduce side offsets here: the main axis is a castle invariant.
	var keep_center := Vector3(0.0, 0.0, courtyard_depth * float(keep_offset.get("z", 0.14)))
	var tower_specs := tower_specs_for_grammar(seed, courtyard_width, courtyard_depth, tower_count, tower_span, tower_height_base, tower_height_variation, int(grammar.get("towerPhase", 0)))
	var courtyard_program: Array = grammar.get("courtyardProgram", []) as Array
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
		{"id": "castle_keep", "role": "great_hall", "bounds": AABB(Vector3(keep_center.x - keep_width * 0.5, foundation_height, keep_center.z - keep_depth * 0.5), Vector3(keep_width, keep_height, keep_depth)), "wallMountInset": 0.22, "accesses": []}
	]
	append_keep_storey_room_records(room_records, keep_center, keep_width, keep_depth, foundation_height, keep_floor_height, keep_storey_count)
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
	add_part(blueprint, "castle_courtyard_paving", "foundation", "stone_foundation", Vector3(0.0, foundation_height + 0.07, 0.0), Vector3(courtyard_width - 0.82, 0.14, courtyard_depth - 0.82), {"variation": variation + 0.03, "semantic": "castle_courtyard_paving"})

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
	add_keep(blueprint, keep_center, keep_width, keep_depth, keep_height, keep_storey_count, keep_floor_height, foundation_height, variation, fortification_material)
	add_district_streets(blueprint, grammar, foundation_height, variation)
	for building_value in courtyard_buildings:
		add_courtyard_outbuilding(blueprint, building_value as Dictionary, foundation_height)
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
		var residence := sample_courtyard_residence(seed, left_source, courtyard_width, courtyard_depth, context)
		var residence_recipe: Dictionary = residence.get("recipe", {}) as Dictionary
		# Each shared residence is built with its door down local -Z. North/south
		# frontage keeps the source axes in world space; east/west frontage rotates
		# them ninety degrees. The footprint proof must use that same transform or
		# a Golden-Lane lot could be visibly clear yet be rejected as a false overlap.
		var front_direction := String(left_source.get("frontDirection", ""))
		var swaps_axes := front_direction not in ["north", "south"]
		var width := float(residence_recipe.get("depth", 6.0)) if swaps_axes else float(residence_recipe.get("width", 8.0))
		var depth := float(residence_recipe.get("width", 8.0)) if swaps_axes else float(residence_recipe.get("depth", 6.0))
		var selected_left := Vector3.ZERO
		var selected_right := Vector3.ZERO
		if district_grid:
			# The sampler allocates pairs from the curtain wall toward the keep and
			# gate toward the rear.  Do not first-fit them here: the exact footprint
			# guard below is only a safety proof, not another placement authority.
			var district_x := absf(float(left_source.get("gridCenterX", 0.0)))
			var district_z := float(left_source.get("gridCenterZ", 0.0))
			selected_left = Vector3(-district_x, 0.0, district_z)
			selected_right = Vector3(district_x, 0.0, district_z)
		else:
			selected_left = courtyard_city_block_center(-1.0, node, width, depth, courtyard_width, courtyard_depth, gate_width, tower_specs)
			selected_right = courtyard_city_block_center(1.0, node, width, depth, courtyard_width, courtyard_depth, gate_width, tower_specs)
		if not district_grid and grid_band == "inner":
			var inner_row_z := courtyard_front_city_block_z(inner_front_cursor, depth)
			selected_left.z = inner_row_z
			selected_right.z = inner_row_z
			# A small cross-street separates these successive front-block rows.
			inner_front_cursor = inner_row_z + depth * 0.5 + 1.50
		elif not district_grid:
			# Preserve the seed-selected outer-grid row whenever it is usable, but
			# never start it inside the gate's flanking towers or the prior block.
			var outer_row_min_z := courtyard_front_city_block_z(outer_front_cursor, depth)
			var outer_row_max_z := courtyard_depth * 0.5 - 2.60 - depth * 0.5
			var outer_row_z := minf(outer_row_max_z, maxf(selected_left.z, outer_row_min_z))
			selected_left.z = outer_row_z
			selected_right.z = outer_row_z
			outer_front_cursor = outer_row_z + depth * 0.5 + 1.50
		# A compound is mirrored at the block level even when individual corner
		# tower spans vary. Use the more restrictive curtain-side setback for both
		# lots instead of letting one side drift closer to its wall.
		var shared_abs_x := minf(absf(selected_left.x), absf(selected_right.x))
		selected_left.x = -shared_abs_x
		selected_right.x = shared_abs_x
		var lot_clearance := 0.32 if String(left_source.get("districtClass", "")) == "golden_lane" else 1.30
		if footprint_overlaps(selected_left, width, depth, selected_right, width, depth, 2.60) or not courtyard_building_footprint_is_clear(selected_left, width, depth, keep_center, keep_width, keep_depth, tower_specs, result, lot_clearance) or not courtyard_building_footprint_is_clear(selected_right, width, depth, keep_center, keep_width, keep_depth, tower_specs, result, lot_clearance):
			push_error("Castle seed %d planned city block %s has no clear footprint" % [seed, String(left_source.get("symmetryGroup", "pair"))])
			continue
		var left_spec := left_source.duplicate(true)
		left_spec["center"] = selected_left
		left_spec["resolvedNode"] = "district_block_row_%d_band_%d_left" % [grid_row, int(left_source.get("cityGridColumn", 0))] if district_grid else "city_block_row_%d_%s_left" % [grid_row, grid_band]
		left_spec["cityGridRow"] = grid_row
		left_spec["cityGridBand"] = grid_band
		left_spec["cityGridColumn"] = int(left_source.get("cityGridColumn", 0)) if district_grid else (0 if grid_band == "outer" else 1)
		left_spec["cityGridMode"] = "district" if district_grid else "compact"
		left_spec["width"] = width
		left_spec["depth"] = depth
		left_spec["residenceFamily"] = String(residence.get("family", "cottage"))
		left_spec["residenceRecipe"] = residence_recipe.duplicate(true)
		left_spec["residenceFacadeMaterial"] = residence_facade_material(seed, String(left_spec.get("id", "left")), masonry_palette)
		append_residence_transform(left_spec, castle_foundation_height_for_residence(residence_recipe))
		result.append(left_spec)
		var right_spec := right_source.duplicate(true)
		right_spec["center"] = selected_right
		right_spec["resolvedNode"] = "district_block_row_%d_band_%d_right" % [grid_row, int(right_source.get("cityGridColumn", 0))] if district_grid else "city_block_row_%d_%s_right" % [grid_row, grid_band]
		right_spec["cityGridRow"] = grid_row
		right_spec["cityGridBand"] = grid_band
		right_spec["cityGridColumn"] = int(right_source.get("cityGridColumn", 0)) if district_grid else (4 if grid_band == "outer" else 3)
		right_spec["cityGridMode"] = "district" if district_grid else "compact"
		right_spec["width"] = width
		right_spec["depth"] = depth
		right_spec["residenceFamily"] = String(residence.get("family", "cottage"))
		right_spec["residenceRecipe"] = residence_recipe.duplicate(true)
		right_spec["residenceFacadeMaterial"] = residence_facade_material(seed, String(right_spec.get("id", "right")), masonry_palette)
		append_residence_transform(right_spec, castle_foundation_height_for_residence(residence_recipe))
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
	spec["origin"] = Vector3(center.x, castle_foundation_height - source_foundation_height, center.z)


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
		var manor_chance := 0.20 if district_class == "golden_lane" else 0.58 if district_class == "wealthy" else 0.0
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
	var rng := RandomNumberGenerator.new()
	rng.seed = int(("%d|castle.district.cottage.lot" % residence_seed).hash())
	# Golden Lane uses the whole narrow frontage: wall gaps are kept to a minimum
	# so roof eaves almost meet, while the shallower depth keeps the shared lane
	# in front of both doors usable. Wealthy lots retain a smaller building within
	# their wider ground reservation.
	if district_class == "golden_lane":
		recipe["width"] = snappedf(clampf(lot_width * rng.randf_range(0.96, 1.00), 17.2, 19.0), 0.20)
		recipe["depth"] = snappedf(clampf(lot_depth * rng.randf_range(0.74, 0.82), 11.8, 13.4), 0.20)
	else:
		recipe["width"] = snappedf(clampf(lot_width * rng.randf_range(0.66, 0.76), 14.5, 18.2), 0.20)
		recipe["depth"] = snappedf(clampf(lot_depth * rng.randf_range(0.56, 0.66), 12.5, 16.0), 0.20)
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
	var is_golden_lane := String(source.get("districtClass", "")) == "golden_lane"
	var frontage_ratio := 0.98 if is_golden_lane else 0.72
	var depth_ratio := 0.82 if is_golden_lane else 0.82
	recipe["width"] = snappedf(minf(float(recipe.get("width", 16.0)), lot_width * frontage_ratio), 0.20)
	recipe["depth"] = snappedf(minf(float(recipe.get("depth", 12.0)), lot_depth * depth_ratio), 0.20)
	recipe["floorCount"] = mini(3, maxi(2, int(recipe.get("floorCount", 2))))
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
		add_part(blueprint, "castle_district_%s" % String(record.get("id", "street")), "foundation", "stone_foundation", Vector3(float(record.get("x", 0.0)), foundation_height + 0.155, float(record.get("z", 0.0))), Vector3(width, 0.05, depth), {"variation": variation - 0.045, "collision": false, "semantic": "castle_courtyard_street"})


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
		source_recipe["collision"] = bool(source_part.collision_enabled)
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
	for room_value in source_blueprint.rooms:
		if not room_value is Dictionary:
			continue
		var source_room: Dictionary = room_value as Dictionary
		var local_bounds: AABB = source_room.get("bounds", AABB()) as AABB
		var transformed_size := Vector3(local_bounds.size.z, local_bounds.size.y, local_bounds.size.x)
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
			access["position"] = origin + yaw_basis * local_position
			access["size"] = Vector3(local_size.z, local_size.y, local_size.x)
			transformed_accesses.append(access)
		room["accesses"] = transformed_accesses
		records.append(room)


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
	# Face the player with the actual operable gate.  Once raised, the player
	# traverses one continuous founded gatehouse passage into the courtyard.
	add_part(blueprint, "castle_gatehouse_portcullis", "door", "ironwork", Vector3(0.0, passage_floor_top + passage_height * 0.5, exterior_gate_z - 0.10), Vector3(opening_width - 0.16, passage_height, 0.18), {"variation": variation - 0.05, "semantic": "castle_portcullis", "doorPresentation": "portcullis", "doorMotion": "raise"})
	add_gatehouse_entry_steps(blueprint, opening_width, passage_floor_top, exterior_gate_z, variation)
	add_gatehouse_roof_deck_with_stair_hatch(blueprint, width, depth, height, foundation_height, center_z, -1.0 * (opening_width * 0.5 + pier_width * 0.5), pier_width, variation)
	add_crenellations(blueprint, "castle_gatehouse_battlement", Vector3(0.0, 0.0, center_z), width, depth, foundation_height + height + 0.50, variation)


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


static func add_keep(blueprint, center: Vector3, width: float, depth: float, height: float, storey_count: int, floor_height: float, foundation_height: float, variation: float, masonry_material: String) -> void:
	add_part(blueprint, "castle_keep_foundation", "foundation", "stone_foundation", Vector3(center.x, foundation_height * 0.5, center.z), Vector3(width + 0.70, foundation_height, depth + 0.70), {"variation": variation, "semantic": "castle_keep_foundation"})
	add_part(blueprint, "castle_keep_floor", "foundation", "stone_foundation", Vector3(center.x, foundation_height + 0.10, center.z), Vector3(width - 0.40, 0.20, depth - 0.40), {"variation": variation, "semantic": "castle_keep_floor"})
	var wall_y := foundation_height + height * 0.5
	var front_z := center.z - depth * 0.5
	var door_width := minf(2.30, width * 0.18)
	var front_side_width := (width - door_width) * 0.5
	for side in [-1.0, 1.0]:
		add_part(blueprint, "castle_keep_front_%d" % int(side), "wall", masonry_material, Vector3(center.x + side * (door_width * 0.5 + front_side_width * 0.5), wall_y, front_z), Vector3(front_side_width, height, 0.72), {"variation": variation, "semantic": "castle_keep_wall"})
	var entry_height := 2.80
	var entry_header_height := height - entry_height
	add_part(blueprint, "castle_keep_entry_header", "wall", masonry_material, Vector3(center.x, foundation_height + entry_height + entry_header_height * 0.5, front_z), Vector3(door_width, entry_header_height, 0.72), {"variation": variation, "semantic": "castle_keep_entry_header"})
	add_part(blueprint, "castle_keep_entry_door", "door", "painted_door", Vector3(center.x, foundation_height + entry_height * 0.5, front_z - 0.10), Vector3(door_width - 0.16, entry_height, 0.18), {"variation": variation - 0.03, "semantic": "castle_keep_entry"})
	for spec in [
		{"id": "back", "position": Vector3(center.x, wall_y, center.z + depth * 0.5), "size": Vector3(width, height, 0.72)},
		{"id": "left", "position": Vector3(center.x - width * 0.5, wall_y, center.z), "size": Vector3(0.72, height, depth)},
		{"id": "right", "position": Vector3(center.x + width * 0.5, wall_y, center.z), "size": Vector3(0.72, height, depth)}
	]:
		add_part(blueprint, "castle_keep_%s" % String(spec.get("id", "wall")), "wall", masonry_material, spec.get("position", Vector3.ZERO) as Vector3, spec.get("size", Vector3.ONE) as Vector3, {"variation": variation, "semantic": "castle_keep_wall"})
	var stairwell := keep_stairwell_layout(center, width, depth)
	var stair_center: Vector3 = stairwell.get("center", center) as Vector3
	var stair_width := float(stairwell.get("width", 3.20))
	var stair_depth := float(stairwell.get("depth", 5.00))
	# Every occupied keep level receives an actual walkable floor with a matching
	# stairwell void.  A single full floor plane would cap the stairs; a missing
	# floor would make the upper silhouette a non-playable shell.
	for storey_index in range(1, storey_count):
		add_keep_storey_floor_with_stairwell(blueprint, storey_index, center, width, depth, stair_center, stair_width, stair_depth, foundation_height, floor_height, variation)
	add_switchback_stair_flights(blueprint, "castle_keep_stair", stair_center, stair_width, stair_depth, foundation_height + 0.20, floor_height, maxi(1, storey_count - 1), "stone_foundation", variation, "castle_keep_stair")
	var upper_width := width * 0.76
	var upper_depth := depth * 0.76
	var upper_height := height * 0.28
	var lower_roof_y := foundation_height + height
	var upper_top := foundation_height + height + upper_height
	# The upper register is deliberately narrower than the keep. Publish a full
	# lower roof/terrace plane before it, or that deliberate silhouette becomes a
	# real open hole around the register. This deck overlaps the lower wall tops
	# and the upper register, making the keep one continuous enclosure.
	add_part(blueprint, "castle_keep_lower_roof_deck", "foundation", "stone_foundation", Vector3(center.x, lower_roof_y + 0.10, center.z), Vector3(width + 0.24, 0.38, depth + 0.24), {"variation": variation, "semantic": "castle_keep_lower_roof"})
	# The upper roof then sits on the enclosed upper register. Its cornice
	# overlaps both supporting levels so a precision/shadow seam cannot make the
	# roof appear detached from the keep at any review angle.
	add_part(blueprint, "castle_keep_upper_register", "wall", masonry_material, Vector3(center.x, foundation_height + height + upper_height * 0.5, center.z), Vector3(upper_width, upper_height, upper_depth), {"variation": variation + 0.01, "semantic": "castle_keep_upper_register"})
	add_part(blueprint, "castle_keep_roof_cornice", "beam", "stone_foundation", Vector3(center.x, upper_top + 0.10, center.z), Vector3(upper_width + 0.22, 0.32, upper_depth + 0.22), {"variation": variation, "semantic": "castle_keep_roof_cornice"})
	add_part(blueprint, "castle_keep_roof_deck", "foundation", "stone_foundation", Vector3(center.x, upper_top + 0.22, center.z), Vector3(upper_width + 0.30, 0.32, upper_depth + 0.30), {"variation": variation, "semantic": "castle_keep_roof"})
	add_crenellations(blueprint, "castle_keep_battlement", center, upper_width, upper_depth, upper_top + 0.64, variation)
	add_part(blueprint, "castle_keep_banner", "sign", "painted_decor", Vector3(center.x, foundation_height + height * 0.64, front_z - 0.42), Vector3(1.46, 2.60, 0.10), {"variation": variation, "collision": false, "semantic": "castle_banner"})


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
	LandmarkBuildingBlueprintBuilderScript.add_part(blueprint, part_id, kind, material, position, size, options)
