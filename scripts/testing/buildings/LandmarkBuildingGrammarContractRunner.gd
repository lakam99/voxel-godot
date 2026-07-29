extends SceneTree

## Pure VOX-208 contract. This validates deterministic family and compound
## recipes before any landmark becomes a live town/city publication concern.

const BuildingFamilyCatalogScript := preload("res://scripts/buildings/BuildingFamilyCatalog.gd")
const LandmarkBuildingRecipeSamplerScript := preload("res://scripts/buildings/LandmarkBuildingRecipeSampler.gd")
const LandmarkBuildingBlueprintBuilderScript := preload("res://scripts/buildings/LandmarkBuildingBlueprintBuilder.gd")
const CastleCompoundBlueprintBuilderScript := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const BuildingPartPublisherScript := preload("res://scripts/buildings/BuildingPartPublisher.gd")
const ConstructionMaterialCatalogScript := preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")

const SEED := 208154
const FAMILIES: Array[String] = ["town_hall", "manor", "keep", "gatehouse", "tower", "curtain_wall", "courtyard"]

var report_path := ""
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("run_contract")


func run_contract() -> void:
	report_path = OS.get_environment("VOXEL_LANDMARK_BUILDING_GRAMMAR_REPORT").strip_edges()
	if report_path.is_empty():
		report_path = ProjectSettings.globalize_path("res://artifacts/buildings/landmark-building-grammar-contract.json")
	var context_a := {"settlementTier": "town", "biome": "forest", "siteKey": "central-square", "style": "masonry"}
	var context_b := {"style": "masonry", "siteKey": "central-square", "biome": "forest", "settlementTier": "town"}
	var rows: Array[Dictionary] = []
	for family in FAMILIES:
		rows.append(verify_family(family, context_a, context_b))
	var town_hall_variants := verify_town_hall_variants()
	# Ordinary coverage stays at the original citadel scale; the dedicated
	# sixfold proof below exercises the scalable district without making every
	# 24-seed grammar audit publish a city-sized blueprint.
	var castle_context := context_a.duplicate(true)
	castle_context["citadelScale"] = 1.0
	var castle := verify_castle(castle_context)
	var castle_variation := verify_castle_variation(castle_context)
	var sixfold_citadel := verify_sixfold_citadel(context_a)
	var passed := failures.is_empty()
	var report := {
		"runnerId": "landmark_building_grammar_contract",
		"evidenceLevel": "contract+headless",
		"scope": "Pure deterministic family and compound recipe grammar with ordinary BuildingPartPublisher coverage. It does not prove live StructureSystem integration, runtime collision behavior, navigation, or city traversal.",
		"seed": SEED,
		"passed": passed,
		"families": rows,
		"townHallVariants": town_hall_variants,
		"castle": castle,
		"castleVariation": castle_variation,
		"sixfoldCitadel": sixfold_citadel,
		"failures": failures
	}
	write_report(report)
	print(JSON.stringify(report))
	quit(0 if passed else 1)


func verify_family(family: String, context_a: Dictionary, context_b: Dictionary) -> Dictionary:
	var first := LandmarkBuildingRecipeSamplerScript.sample(SEED, family, context_a)
	var replay := LandmarkBuildingRecipeSamplerScript.sample(SEED, family, context_b)
	var different_seed := LandmarkBuildingRecipeSamplerScript.sample(SEED + 1, family, context_a)
	check(JSON.stringify(first) == JSON.stringify(replay), "%s recipe depends on context dictionary ordering" % family)
	check(JSON.stringify(first) != JSON.stringify(different_seed), "%s recipe is not seed-sensitive" % family)
	check(String(first.get("family", "")) == family, "%s recipe normalized to the wrong family" % family)
	check(String(first.get("landmarkRole", "")).strip_edges() != "", "%s lacks a landmark role" % family)
	check(float(first.get("width", 0.0)) > 0.0 and float(first.get("depth", 0.0)) > 0.0, "%s has an invalid footprint" % family)
	check(int(first.get("floorCount", -1)) >= 0, "%s has invalid floor count" % family)
	var opening: Dictionary = first.get("openingPolicy", {}) as Dictionary
	check(not String(opening.get("entrySide", "")).is_empty(), "%s lacks an entry policy" % family)
	check(float(opening.get("entryWidth", 0.0)) > 0.0, "%s has invalid entry width" % family)
	var room_ids := {}
	var room_program: Array = first.get("roomProgram", []) as Array
	for room_value in room_program:
		if not room_value is Dictionary:
			check(false, "%s has malformed room program entry" % family)
			continue
		var room := room_value as Dictionary
		var room_id := String(room.get("id", ""))
		check(not room_id.is_empty() and not room_ids.has(room_id), "%s has missing or duplicate room id %s" % [family, room_id])
		room_ids[room_id] = true
		check(int(room.get("floor", -1)) >= 0 and int(room.get("floor", -1)) < maxi(1, int(first.get("floorCount", 0))), "%s room %s has invalid floor assignment" % [family, room_id])
	var blueprint = LandmarkBuildingBlueprintBuilderScript.build_from_recipe(first)
	var replay_blueprint = LandmarkBuildingBlueprintBuilderScript.build_from_recipe(replay)
	check(blueprint != null and not blueprint.parts.is_empty(), "%s recipe did not produce a construction blueprint" % family)
	check(blueprint != null and replay_blueprint != null and blueprint.deterministic_signature() == replay_blueprint.deterministic_signature(), "%s blueprint replay is not deterministic" % family)
	if family == "town_hall" and blueprint != null:
		validate_town_hall(blueprint)
	if family == "manor" and blueprint != null:
		validate_manor(blueprint)
	var publication := {}
	if blueprint != null:
		var fixture := Node3D.new()
		get_root().add_child(fixture)
		var publisher = BuildingPartPublisherScript.new()
		publication = publisher.publish(blueprint, fixture)
		check(int(publication.get("publishedPartCount", -1)) == blueprint.parts.size(), "%s publisher omitted source parts" % family)
		fixture.free()
	return {
		"family": family,
		"signature": JSON.stringify(first).hash(),
		"footprint": {"width": first.get("width"), "depth": first.get("depth")},
		"floorCount": first.get("floorCount"),
		"roomCount": room_ids.size(),
		"landmarkRole": first.get("landmarkRole"),
		"blueprintParts": blueprint.parts.size() if blueprint != null else 0,
		"publication": publication
	}


func validate_town_hall(blueprint) -> void:
	var parts_by_id := {}
	var room_roles := {}
	for room in blueprint.rooms:
		if room is Dictionary:
			room_roles[String((room as Dictionary).get("role", ""))] = room
	for part in blueprint.parts:
		if part != null:
			parts_by_id[String(part.id)] = part
	var layout := String(blueprint.recipe.get("townHallLayout", "standard"))
	var required_roles: Array[String] = ["public_hall", "notice_archive"]
	if layout in ["standard", "expanded"]:
		required_roles.append("steward_office")
	if layout == "expanded":
		required_roles.append("civic_store")
	for role in required_roles:
		check(room_roles.has(role), "Town Hall lacks the %s room record" % role)
	check(room_roles.size() == required_roles.size(), "Town Hall %s layout has an unexpected fixed room program" % layout)
	var public_hall: Dictionary = room_roles.get("public_hall", {}) as Dictionary
	var public_accesses: Array = public_hall.get("accesses", []) as Array
	check(public_accesses.size() >= required_roles.size(), "Town Hall %s layout lacks declared exterior/interior circulation" % layout)
	for required_part in ["front_door", "entry_ramp", "civic_bell", "civic_portico_lintel", "civic_clock_face"]:
		check(parts_by_id.has(required_part), "Town Hall lacks structural part %s" % required_part)
	check(parts_by_id.has("divider_header"), "Town Hall does not close the interior passages with a structural divider header")
	var rear_divider_count := 0
	for part in blueprint.parts:
		if part != null and String(part.id).begins_with("rear_divider_"):
			rear_divider_count += 1
	check(rear_divider_count == maxi(0, required_roles.size() - 2), "Town Hall %s layout has the wrong number of physical rear dividers" % layout)
	var front_gable_count := 0
	var back_gable_count := 0
	for part in blueprint.parts:
		if part == null:
			continue
		if String(part.id).begins_with("front_gable_"):
			front_gable_count += 1
		if String(part.id).begins_with("back_gable_"):
			back_gable_count += 1
	check(front_gable_count > 0 and back_gable_count > 0, "Town Hall roof has no published physical gable end caps")
	for access_value in public_accesses:
		if not access_value is Dictionary:
			continue
		var access := access_value as Dictionary
		var opening_size: Vector3 = access.get("size", Vector3.ZERO) as Vector3
		var furnishing_size: Vector3 = access.get("furnishingSize", Vector3.ZERO) as Vector3
		check(furnishing_size.x >= opening_size.x and furnishing_size.z >= opening_size.z, "Town Hall access %s lacks protected furnishing clearance" % String(access.get("id", "")))
	var belfry_pier_count := 0
	for part in blueprint.parts:
		if part != null and String(part.id).begins_with("civic_belfry_pier_"):
			belfry_pier_count += 1
	check(belfry_pier_count == 4, "Town Hall belfry does not resolve to four structural piers")
	var door = parts_by_id.get("front_door", null)
	check(door != null and String(door.kind) == "door" and door.collision_enabled, "Town Hall front door is not a physical door part")
	var windows: Array = []
	for part in blueprint.parts:
		if part != null and String(part.kind) == "window":
			windows.append(part)
	check(windows.size() >= 5, "Town Hall lacks readable window parts")
	for opening_part in windows + [door]:
		if opening_part == null:
			continue
		var opening_bounds := part_bounds(opening_part)
		for wall in blueprint.parts:
			if wall == null or String(wall.kind) != "wall":
				continue
			check(not positive_volume_overlap(opening_bounds, part_bounds(wall)), "Town Hall wall %s still fills the opening %s" % [String(wall.id), String(opening_part.id)])


func verify_town_hall_variants() -> Dictionary:
	var observed := {}
	for style in ["timber", "masonry"]:
		for seed in [208154, 208155, 306701, 420901]:
			var recipe := LandmarkBuildingRecipeSamplerScript.sample(seed, "town_hall", {"settlementTier": "town", "biome": "temperate", "siteKey": "civic-square", "style": style})
			var layout := String(recipe.get("townHallLayout", ""))
			observed[layout] = true
			var blueprint = LandmarkBuildingBlueprintBuilderScript.build_from_recipe(recipe)
			check(blueprint != null, "Town Hall %s seed %d %s layout did not build" % [style, seed, layout])
			if blueprint != null:
				validate_town_hall(blueprint)
	for layout in ["compact", "standard", "expanded"]:
		check(observed.has(layout), "Town Hall footprint sampling never emitted the %s layout" % layout)
	return {"observedLayouts": observed.keys()}


func validate_manor(blueprint) -> void:
	var parts_by_id := {}
	for part in blueprint.parts:
		if part != null:
			parts_by_id[String(part.id)] = part
	for required_part in ["manor_main_foundation", "manor_service_foundation", "manor_tower_foundation", "manor_main_lower_floor", "manor_solar_upper_floor", "manor_service_wing_floor", "manor_stair_tower_floor", "manor_main_lower_left_header", "manor_service_wing_right_header", "manor_main_lower_right_header", "manor_solar_upper_right_header", "manor_stair_tower_left_header_0", "manor_wing_threshold", "manor_lower_tower_bridge", "manor_solar_tower_bridge", "manor_main_roof_left", "manor_service_roof_left", "manor_tower_roof_left", "manor_portico_roof"]:
		check(parts_by_id.has(required_part), "Manor lacks assembled structural part %s" % required_part)
	var lower = parts_by_id.get("manor_main_lower_floor", null)
	var solar = parts_by_id.get("manor_solar_upper_floor", null)
	var wing = parts_by_id.get("manor_service_wing_floor", null)
	var tower = parts_by_id.get("manor_stair_tower_floor", null)
	check(lower != null and solar != null and solar.position.y > lower.position.y and solar.size.x > lower.size.x and solar.size.z > lower.size.z, "Manor upper solar is not a broader projected floor above the lower hall")
	check(lower != null and wing != null and horizontal_volumes_touch(lower, wing), "Manor service wing is not attached to the main hall")
	check(lower != null and tower != null and horizontal_volumes_touch(lower, tower), "Manor stair tower is not attached to the main hall")
	if int(blueprint.recipe.get("floorCount", 0)) >= 3:
		check(parts_by_id.has("manor_solar_upper_ceiling"), "Three-storey manor leaves the solar-to-attic junction open")
		check(parts_by_id.has("manor_attic_tower_bridge"), "Three-storey manor has no physical tower-to-attic connection")
	var stair_count := 0
	for part in blueprint.parts:
		if part != null and String(part.id).begins_with("manor_stair_"):
			stair_count += 1
	check(stair_count >= maxi(3, (int(blueprint.recipe.get("floorCount", 2)) - 1) * 3), "Manor lacks the collision-backed stair flights and landings required for its floors")
	var tower_top := 0.0
	var tower_base := INF
	for part in blueprint.parts:
		if part != null and (String(part.id).begins_with("manor_stair_tower_") or String(part.id).begins_with("manor_tower_")):
			tower_top = maxf(tower_top, part.position.y + part.size.y * 0.5)
			tower_base = minf(tower_base, part.position.y - part.size.y * 0.5)
	check(tower_top - tower_base > float(blueprint.recipe.get("floorHeight", 0.0)) * 1.8, "Manor tower does not rise through multiple floors")
	var door = parts_by_id.get("manor_main_lower_entry_door", null)
	check(door != null and String(door.kind) == "door" and door.collision_enabled, "Manor lacks a physical main entry door")
	var window_count := 0
	for part in blueprint.parts:
		if part != null and String(part.kind) == "window":
			window_count += 1
	check(window_count >= 8, "Manor wall openings do not publish their matching glass panes")


func horizontal_volumes_touch(first, second, tolerance := 0.45) -> bool:
	var first_min_x: float = first.position.x - first.size.x * 0.5 - tolerance
	var first_max_x: float = first.position.x + first.size.x * 0.5 + tolerance
	var first_min_z: float = first.position.z - first.size.z * 0.5 - tolerance
	var first_max_z: float = first.position.z + first.size.z * 0.5 + tolerance
	var second_min_x: float = second.position.x - second.size.x * 0.5
	var second_max_x: float = second.position.x + second.size.x * 0.5
	var second_min_z: float = second.position.z - second.size.z * 0.5
	var second_max_z: float = second.position.z + second.size.z * 0.5
	return first_min_x <= second_max_x and first_max_x >= second_min_x and first_min_z <= second_max_z and first_max_z >= second_min_z


func part_bounds(part) -> AABB:
	return AABB(part.position - part.size * 0.5, part.size)


func positive_volume_overlap(first: AABB, second: AABB) -> bool:
	var epsilon := 0.0001
	return first.position.x < second.end.x - epsilon and first.end.x > second.position.x + epsilon and first.position.y < second.end.y - epsilon and first.end.y > second.position.y + epsilon and first.end.z > second.position.z + epsilon and first.position.z < second.end.z - epsilon


func verify_castle(context: Dictionary) -> Dictionary:
	var first := LandmarkBuildingRecipeSamplerScript.sample_compound(SEED, "castle", context)
	var replay := LandmarkBuildingRecipeSamplerScript.sample_compound(SEED, "castle", context)
	var members: Array = first.get("members", []) as Array
	check(JSON.stringify(first) == JSON.stringify(replay), "castle compound is not deterministic")
	check(BuildingFamilyCatalogScript.is_compound("castle"), "catalog does not identify castle as a compound")
	check(members.size() >= 8, "castle compound lacks its required members")
	var member_ids := {}
	var family_counts := {}
	for member_value in members:
		if not member_value is Dictionary:
			check(false, "castle has malformed member")
			continue
		var member := member_value as Dictionary
		var member_id := String(member.get("id", ""))
		var family := String(member.get("family", ""))
		member_ids[member_id] = true
		family_counts[family] = int(family_counts.get(family, 0)) + 1
		check(member_id != "" and BuildingFamilyCatalogScript.family_ids().has(family), "castle member %s has invalid family %s" % [member_id, family])
		var recipe: Dictionary = member.get("recipe", {}) as Dictionary
		check(String(recipe.get("family", "")) == family, "castle member %s recipe lost its family identity" % member_id)
	check(member_ids.size() == members.size(), "castle compound repeats member ids")
	for required_family in ["gatehouse", "curtain_wall", "tower", "courtyard", "keep"]:
		check(int(family_counts.get(required_family, 0)) > 0, "castle is missing %s" % required_family)
	var grammar: Dictionary = first.get("castleGrammar", {}) as Dictionary
	check(not grammar.is_empty(), "castle lacks a compound spatial grammar")
	check(int(grammar.get("towerCount", 0)) >= 4 and int(grammar.get("towerCount", 0)) <= 8, "castle has an invalid generated tower count")
	check(float(grammar.get("courtyardWidth", 0.0)) >= 40.0 and float(grammar.get("courtyardDepth", 0.0)) >= 34.0, "castle has an undersized generated bailey")
	check(float(grammar.get("keepHeight", 0.0)) > float(grammar.get("wallHeight", 0.0)), "castle keep does not rise above its curtain wall")
	var masonry: Dictionary = grammar.get("citadelMasonry", {}) as Dictionary
	var civic_masonry := String(masonry.get("fortification", ""))
	var residence_palette: Array = masonry.get("residences", []) as Array
	check(ConstructionMaterialCatalogScript.is_masonry_material(civic_masonry), "castle lacks a valid seed-derived civic masonry material")
	check(residence_palette.size() >= 3, "castle lacks a sufficiently varied residence facade palette")
	for material_value in residence_palette:
		check(ConstructionMaterialCatalogScript.is_masonry_material(String(material_value)), "castle facade palette contains a non-masonry material")
	var courtyard_grid: Dictionary = grammar.get("courtyardGrid", {}) as Dictionary
	var grid_mode := String(courtyard_grid.get("mode", "compact_grid"))
	var grid_columns := int(courtyard_grid.get("columns", 0))
	var grid_rows := int(courtyard_grid.get("rows", 0))
	if grid_mode == "district_grid":
		var bands_per_side := int(courtyard_grid.get("bandsPerSide", 0))
		check(grid_columns == bands_per_side * 2 + 1 and grid_columns >= 5 and grid_rows >= 5, "castle district lattice has invalid dimensions")
	else:
		check(grid_columns == 5 and grid_rows == 5, "castle lacks its five-column courtyard occupancy lattice")
	var grid_cells: Array = courtyard_grid.get("cells", []) as Array
	check(grid_cells.size() == grid_rows and not grid_cells.is_empty() and (grid_cells[0] as Array).size() == grid_columns, "castle courtyard occupancy lattice has invalid dimensions")
	if grid_cells.size() == grid_rows:
		for row_index in range(grid_cells.size()):
			var row: Array = grid_cells[row_index] as Array
			check(row.size() == grid_columns, "castle courtyard occupancy lattice row %d has invalid width" % row_index)
			if row.size() == grid_columns:
				check(int(row[grid_columns / 2]) == 0 or (grid_mode == "compact_grid" and row_index == 0), "castle courtyard occupancy lattice does not reserve the gate-to-keep centre route")
	var courtyard_program: Array = grammar.get("courtyardProgram", []) as Array
	var max_program_size := int(courtyard_grid.get("lotPairCount", grid_rows * maxi(1, grid_columns - 1))) * 2 if grid_mode == "district_grid" else grid_rows * maxi(1, grid_columns - 1)
	check(courtyard_program.size() >= 2 and courtyard_program.size() <= max_program_size and courtyard_program.size() % 2 == 0, "castle has an invalid mirrored courtyard building count")
	if grid_mode == "district_grid":
		check(courtyard_program.size() == max_program_size, "castle district grid did not fill all non-boulevard residence lots")
		check((courtyard_grid.get("streetRecords", []) as Array).size() >= 2, "castle district grid lacks a boulevard and cross-street graph")
	var courtyard_ids := {}
	var courtyard_slots := {}
	var symmetry_groups := {}
	for building_value in courtyard_program:
		check(building_value is Dictionary, "castle courtyard program has a malformed building")
		if not building_value is Dictionary:
			continue
		var building := building_value as Dictionary
		var building_id := String(building.get("id", ""))
		var building_slot := String(building.get("slot", ""))
		var graph_node := String(building.get("graphNode", ""))
		var symmetry_group := String(building.get("symmetryGroup", ""))
		var mirror_side := String(building.get("mirrorSide", ""))
		courtyard_ids[building_id] = true
		courtyard_slots[building_slot] = true
		if not symmetry_groups.has(symmetry_group):
			symmetry_groups[symmetry_group] = []
		(symmetry_groups[symmetry_group] as Array).append(building)
		check(not building_id.is_empty(), "castle courtyard program has a building without a stable id")
		check(not building_slot.is_empty(), "castle courtyard program has a building without a spatial slot")
		check(graph_node.begins_with("district_band_") if grid_mode == "district_grid" else graph_node in ["gate_outer", "lower_outer", "middle_outer", "rear_outer", "gate_inner", "lower_inner"], "castle courtyard program uses a non-city-grid graph node")
		if grid_mode == "district_grid":
			check(String(building.get("cityGridMode", "")) == "district", "castle district building %s lost its district-grid identity" % building_id)
			check(int(building.get("cityGridRow", -1)) >= 0 and int(building.get("cityGridColumn", -1)) >= 0, "castle district building %s lacks a grid coordinate" % building_id)
		check(not symmetry_group.is_empty(), "castle courtyard program has a building without a symmetry group")
		check(mirror_side in ["left", "right"], "castle courtyard program has a building without a mirror side")
		check(not String(building.get("kind", "")).is_empty(), "castle courtyard program has a building without a kind")
		check(float(building.get("width", 0.0)) > 0.0 and float(building.get("depth", 0.0)) > 0.0, "castle courtyard building %s has an invalid footprint" % building_id)
	check(courtyard_ids.size() == courtyard_program.size(), "castle courtyard program repeats building ids")
	check(courtyard_slots.size() == courtyard_program.size(), "castle courtyard program repeats spatial slots")
	for group_value in symmetry_groups.values():
		var pair: Array = group_value as Array
		check(pair.size() == 2, "castle courtyard symmetry group does not contain exactly two buildings")
		if pair.size() != 2:
			continue
		var first_pair_building: Dictionary = pair[0] as Dictionary
		var second_pair_building: Dictionary = pair[1] as Dictionary
		check(String(first_pair_building.get("mirrorSide", "")) != String(second_pair_building.get("mirrorSide", "")), "castle courtyard symmetry pair repeats a mirror side")
		check(String(first_pair_building.get("kind", "")) == String(second_pair_building.get("kind", "")), "castle courtyard symmetry pair has mismatched building roles")
		check(is_equal_approx(float(first_pair_building.get("width", 0.0)), float(second_pair_building.get("width", 0.0))) and is_equal_approx(float(first_pair_building.get("depth", 0.0)), float(second_pair_building.get("depth", 0.0))), "castle courtyard symmetry pair has mismatched footprints")
	var keep_offset: Dictionary = grammar.get("keepOffset", {}) as Dictionary
	check(is_zero_approx(float(keep_offset.get("x", 1.0))), "castle keep is not centred on the gate axis")
	var blueprint = CastleCompoundBlueprintBuilderScript.build_from_compound(first)
	var replay_blueprint = CastleCompoundBlueprintBuilderScript.build_from_compound(replay)
	check(blueprint != null and replay_blueprint != null and blueprint.deterministic_signature() == replay_blueprint.deterministic_signature(), "castle compound blueprint replay is not deterministic")
	var published_towers := 0
	var published_courtyard_buildings := 0
	if blueprint != null:
		for part in blueprint.parts:
			if part != null and String(part.id).begins_with("castle_tower_") and String(part.id).ends_with("_floor"):
				published_towers += 1
		for room_value in blueprint.rooms:
			if room_value is Dictionary and bool((room_value as Dictionary).get("castleCourtyardResidence", false)):
				published_courtyard_buildings += 1
	check(published_towers == int(grammar.get("towerCount", 0)), "castle published %d tower floors for a %d-tower grammar" % [published_towers, int(grammar.get("towerCount", 0))])
	check(published_courtyard_buildings == courtyard_program.size(), "castle published %d courtyard building floors for a %d-building grammar" % [published_courtyard_buildings, courtyard_program.size()])
	if blueprint != null:
		validate_castle_courtyard_placement(blueprint, grammar, courtyard_program)
		validate_castle_keep_roof(blueprint)
		validate_castle_gate_entry(blueprint)
		validate_castle_vertical_circulation(blueprint)
		validate_castle_seeded_masonry(blueprint, grammar)
	return {"id": first.get("id"), "memberCount": members.size(), "familyCounts": family_counts, "grammar": grammar, "courtyardBuildingCount": courtyard_program.size(), "blueprintParts": blueprint.parts.size() if blueprint != null else 0}


func verify_sixfold_citadel(base_context: Dictionary) -> Dictionary:
	# Find a deterministic grand profile, then prove the context scale grows its
	# physical span and fills every city-lattice lot through the same compound
	# builder used by the visual PoC.
	var context := base_context.duplicate(true)
	context["citadelScale"] = 6.0
	var compound := {}
	var selected_seed := -1
	for candidate_seed in range(SEED, SEED + 96):
		var candidate := LandmarkBuildingRecipeSamplerScript.sample_compound(candidate_seed, "castle", context)
		var candidate_grammar: Dictionary = candidate.get("castleGrammar", {}) as Dictionary
		if String(candidate_grammar.get("profile", "")) == "grand_citadel":
			compound = candidate
			selected_seed = candidate_seed
			break
	check(selected_seed >= 0, "sixfold citadel proof could not find a seeded grand-citadel profile")
	if selected_seed < 0:
		return {}
	var grammar: Dictionary = compound.get("castleGrammar", {}) as Dictionary
	var grid: Dictionary = grammar.get("courtyardGrid", {}) as Dictionary
	var program: Array = grammar.get("courtyardProgram", []) as Array
	check(is_equal_approx(float(grammar.get("grandScale", 0.0)), 6.0), "sixfold citadel lost its requested scale")
	check(float(grammar.get("courtyardWidth", 0.0)) <= 672.0 and float(grammar.get("courtyardDepth", 0.0)) <= 576.0, "sixfold citadel exceeded the six-times maximum envelope")
	check(float(grammar.get("courtyardWidth", 0.0)) > 128.0 and float(grammar.get("courtyardDepth", 0.0)) > 112.0, "sixfold citadel did not grow past the former courtyard maximum")
	check(float(grammar.get("keepHeightScale", 0.0)) >= 2.45 and int(grammar.get("keepStoreys", 0)) >= 12, "sixfold citadel keep did not scale vertically into a city landmark")
	check(float(grammar.get("keepWidth", 0.0)) >= float(grammar.get("courtyardWidth", 0.0)) * 0.30 and float(grammar.get("keepDepth", 0.0)) >= float(grammar.get("courtyardDepth", 0.0)) * 0.26, "sixfold citadel keep did not retain a landmark-scale footprint")
	check(String(grid.get("mode", "")) == "district_grid", "sixfold citadel did not select the scalable district grid")
	var golden_lane_pairs := 0
	var wealthy_pairs := 0
	for lot_value in grid.get("lotPairs", []) as Array:
		if not lot_value is Dictionary:
			continue
		match String((lot_value as Dictionary).get("districtClass", "")):
			"golden_lane":
				golden_lane_pairs += 1
			"wealthy":
				wealthy_pairs += 1
	check(golden_lane_pairs > 0, "sixfold citadel did not allocate a dense Golden-Lane district")
	check(wealthy_pairs > 0, "sixfold citadel did not allocate a spacious keep-adjacent district")
	var expected_homes := int(grid.get("rows", 0)) * maxi(0, int(grid.get("columns", 0)) - 1)
	expected_homes = int(grid.get("lotPairCount", expected_homes / 2)) * 2
	check(program.size() == expected_homes and program.size() >= 100, "sixfold citadel district does not fill its planned grid")
	var keep_offset: Dictionary = grammar.get("keepOffset", {}) as Dictionary
	var keep_front_z := float(grammar.get("courtyardDepth", 0.0)) * float(keep_offset.get("z", 0.0)) - float(grammar.get("keepDepth", 0.0)) * 0.5
	var forecourt_lot_found := false
	for lot_value in grid.get("lotPairs", []) as Array:
		if not lot_value is Dictionary:
			continue
		var lot: Dictionary = lot_value as Dictionary
		if float(lot.get("centerZ", 0.0)) < keep_front_z - 4.0 and float(lot.get("centerX", INF)) < float(grammar.get("keepWidth", 0.0)) * 0.5:
			forecourt_lot_found = true
			break
	check(forecourt_lot_found, "sixfold citadel leaves the whole forecourt empty instead of filling street blocks around the boulevard")
	var blueprint = CastleCompoundBlueprintBuilderScript.build_from_compound(compound)
	check(blueprint != null, "sixfold citadel did not build through the shared castle builder")
	if blueprint != null:
		validate_castle_courtyard_placement(blueprint, grammar, program)
		validate_castle_seeded_masonry(blueprint, grammar)
	return {"seed": selected_seed, "courtyardWidth": grammar.get("courtyardWidth"), "courtyardDepth": grammar.get("courtyardDepth"), "keepWidth": grammar.get("keepWidth"), "keepDepth": grammar.get("keepDepth"), "keepHeight": grammar.get("keepHeight"), "keepStoreys": grammar.get("keepStoreys"), "keepHeightScale": grammar.get("keepHeightScale"), "citadelMasonry": grammar.get("citadelMasonry"), "grid": grid, "homeCount": program.size(), "blueprintParts": blueprint.parts.size() if blueprint != null else 0}


func validate_castle_seeded_masonry(blueprint, grammar: Dictionary) -> void:
	# Material identity is part of the shared blueprint, not a post-publication
	# tint. Fortifications receive the civic colour. Each residence records one
	# stable facade selection which is used by every one of its masonry parts.
	var masonry: Dictionary = grammar.get("citadelMasonry", {}) as Dictionary
	var civic_material := String(masonry.get("fortification", ""))
	var residence_palette: Array = masonry.get("residences", []) as Array
	var planned_residences: Array = blueprint.recipe.get("courtyardResidences", []) as Array
	var selected_facades := {}
	var non_civic_facade_count := 0
	for residence_value in planned_residences:
		if not residence_value is Dictionary:
			continue
		var residence: Dictionary = residence_value as Dictionary
		var residence_id := String(residence.get("id", ""))
		var facade := String(residence.get("residenceFacadeMaterial", ""))
		check(ConstructionMaterialCatalogScript.is_masonry_material(facade), "castle residence %s lacks a masonry facade material" % residence_id)
		check(residence_palette.has(facade), "castle residence %s selected a facade outside the city palette" % residence_id)
		selected_facades[facade] = true
		if facade != civic_material:
			non_civic_facade_count += 1
	for part in blueprint.parts:
		if part == null:
			continue
		var semantic := String(part.semantic)
		var source_facade := String(part.recipe.get("castleResidenceFacadeMaterial", ""))
		if not source_facade.is_empty() and ConstructionMaterialCatalogScript.is_masonry_material(String(part.material_id)):
			check(String(part.material_id) == source_facade, "castle residence part %s escaped its seeded facade material" % String(part.id))
		elif String(part.kind) == "wall" and (semantic.begins_with("castle_tower_") or semantic.begins_with("castle_curtain_") or semantic.begins_with("castle_gatehouse_") or semantic.begins_with("castle_keep_")):
			check(String(part.material_id) == civic_material, "castle civic wall %s does not use its seed-derived masonry colour" % String(part.id))
	if planned_residences.size() >= 12:
		check(selected_facades.size() >= 2, "city citadel residences lack visible facade variety")
		check(non_civic_facade_count > planned_residences.size() * 0.5, "city citadel did not paint most residence facades with individual colour")


func validate_castle_courtyard_placement(blueprint, grammar: Dictionary, courtyard_program: Array) -> void:
	var castle_seed := int(blueprint.recipe.get("seed", 0))
	var courtyard_width := float(grammar.get("courtyardWidth", 0.0))
	var courtyard_depth := float(grammar.get("courtyardDepth", 0.0))
	var gate_to_keep_corridor_half_width := maxf(2.40, float(grammar.get("gateWidth", 0.0)) * 0.5 + 1.00)
	var keep_bounds := AABB()
	var outbuilding_bounds: Array[AABB] = []
	var outbuilding_bounds_by_id := {}
	var tower_bounds: Array[AABB] = []
	var courtyard_doors: Array = []
	var residence_families := {}
	var residence_roof_counts := {}
	var planned_residences: Array = blueprint.recipe.get("courtyardResidences", []) as Array
	var planned_residences_by_id := {}
	for planned_value in planned_residences:
		if planned_value is Dictionary:
			var planned: Dictionary = planned_value as Dictionary
			planned_residences_by_id[String(planned.get("id", ""))] = planned
	for room_value in blueprint.rooms:
		if not room_value is Dictionary:
			continue
		var room := room_value as Dictionary
		var room_id := String(room.get("id", ""))
		var bounds: AABB = room.get("bounds", AABB()) as AABB
		if room_id == "castle_keep":
			keep_bounds = bounds
		elif bool(room.get("castleCourtyardResidence", false)):
			outbuilding_bounds.append(bounds)
			outbuilding_bounds_by_id[room_id] = bounds
	for part in blueprint.parts:
		if part == null:
			continue
		var part_id := String(part.id)
		if part_id.begins_with("castle_tower_") and part_id.ends_with("_foundation"):
			tower_bounds.append(part_bounds(part))
		elif String(part.semantic) == "castle_courtyard_building_door":
			courtyard_doors.append(part)
		if part.recipe.has("castleResidenceFamily"):
			var residence_id := part_id.get_slice("__", 0)
			residence_families[residence_id] = String(part.recipe.get("castleResidenceFamily", ""))
			if String(part.kind) == "roof":
				residence_roof_counts[residence_id] = int(residence_roof_counts.get(residence_id, 0)) + 1
	check(outbuilding_bounds.size() == courtyard_program.size(), "castle lost a room record for a courtyard building")
	check(courtyard_doors.size() == courtyard_program.size(), "castle lost a core-facing entry door for a courtyard building")
	check(planned_residences.size() == courtyard_program.size(), "castle lost resolved city blocks for its courtyard program")
	validate_castle_courtyard_city_blocks(planned_residences, courtyard_program)
	for room_id_value in outbuilding_bounds_by_id.keys():
		var residence_id := "castle_%s" % String(room_id_value)
		var family := String(residence_families.get(residence_id, ""))
		check(family in ["cottage", "manor"], "castle courtyard residence %s did not use a shared cottage/manor family" % residence_id)
		check(int(residence_roof_counts.get(residence_id, 0)) >= 2, "castle courtyard residence %s lacks the shared roof grammar" % residence_id)
	# Dense compounds may select only compact cottages when their four live flank
	# rows leave no legal manor footprint.  The builder still composes manor
	# source recipes whenever the grammar emits its dedicated rear lot; neither
	# category is faked solely to satisfy this aggregate fixture.
	check(residence_families.values().has("cottage"), "castle courtyard did not retain seeded cottage residences")
	var has_district_lots := not planned_residences.is_empty() and planned_residences[0] is Dictionary and String((planned_residences[0] as Dictionary).get("cityGridMode", "")) == "district"
	if has_district_lots:
		check(residence_families.values().has("manor"), "castle district did not include seeded manor frontage among its cottage rows")
	check(is_zero_approx(keep_bounds.get_center().x), "castle keep blueprint is not centred on the gate axis")
	for door in courtyard_doors:
		var door_forward := Vector3(0.0, 0.0, -1.0).rotated(Vector3.UP, door.rotation.y)
		var owner_id := String(door.id).get_slice("__", 0)
		if owner_id.begins_with("castle_"):
			owner_id = owner_id.trim_prefix("castle_")
		var owner_spec: Dictionary = planned_residences_by_id.get(owner_id, {}) as Dictionary
		var front_direction := String(owner_spec.get("frontDirection", ""))
		var expected_forward := Vector3(-signf(door.position.x), 0.0, 0.0)
		match front_direction:
			"north":
				expected_forward = Vector3(0.0, 0.0, -1.0)
			"south":
				expected_forward = Vector3(0.0, 0.0, 1.0)
			"east":
				expected_forward = Vector3(1.0, 0.0, 0.0)
			"west":
				expected_forward = Vector3(-1.0, 0.0, 0.0)
		var approach_bounds := courtyard_door_approach_bounds(door)
		check(absf(door.position.x) > gate_to_keep_corridor_half_width, "castle courtyard entry door was generated inside the gate-to-keep approach corridor")
		check(door_forward.dot(expected_forward) > 0.98, "castle courtyard entry door %s does not face its planned street" % String(door.id))
		check(not horizontal_positive_overlap(approach_bounds, keep_bounds), "castle seed %d courtyard entry door %s has no approach clearance before the keep" % [castle_seed, String(door.id)])
		for other_id_value in outbuilding_bounds_by_id.keys():
			var other_id := String(other_id_value)
			if other_id == owner_id:
				continue
			var other_bounds: AABB = outbuilding_bounds_by_id[other_id] as AABB
			check(not horizontal_positive_overlap(approach_bounds, other_bounds), "castle seed %d courtyard entry door %s has no approach clearance before %s" % [castle_seed, String(door.id), other_id])
	for index in range(0, courtyard_program.size(), 2):
		if index + 1 >= courtyard_program.size() or not courtyard_program[index] is Dictionary or not courtyard_program[index + 1] is Dictionary:
			continue
		var left_program: Dictionary = courtyard_program[index] as Dictionary
		var right_program: Dictionary = courtyard_program[index + 1] as Dictionary
		var left_bounds: AABB = outbuilding_bounds_by_id.get(String(left_program.get("id", "")), AABB()) as AABB
		var right_bounds: AABB = outbuilding_bounds_by_id.get(String(right_program.get("id", "")), AABB()) as AABB
		var left_center := left_bounds.get_center()
		var right_center := right_bounds.get_center()
		check(is_equal_approx(left_center.x, -right_center.x) and is_equal_approx(left_center.z, right_center.z), "castle courtyard symmetry pair %s is not mirrored around the keep axis" % String(left_program.get("symmetryGroup", "")))
	for index in range(outbuilding_bounds.size()):
		var bounds := outbuilding_bounds[index]
		check(bounds.position.x >= -courtyard_width * 0.5 and bounds.end.x <= courtyard_width * 0.5 and bounds.position.z >= -courtyard_depth * 0.5 and bounds.end.z <= courtyard_depth * 0.5, "castle courtyard building %d escapes the curtain envelope" % index)
		# Homes should claim the usable cells around the keep, not retreat to the
		# curtain walls and leave the whole court empty. The builder's own exact
		# footprint checks remain responsible for tower/keep/roof clearance.
		var district_lot := not planned_residences.is_empty() and planned_residences[index] is Dictionary and String((planned_residences[index] as Dictionary).get("cityGridMode", "")) == "district"
		check(absf(bounds.get_center().x) <= courtyard_width * (0.50 if district_lot else 0.48), "castle courtyard building %d escaped the keep-adjacent occupancy lattice" % index)
		check(bounds.end.x <= -gate_to_keep_corridor_half_width or bounds.position.x >= gate_to_keep_corridor_half_width, "castle courtyard building %d intrudes into the gate-to-keep approach corridor" % index)
		check(not positive_volume_overlap(bounds, keep_bounds), "castle courtyard building %d overlaps the keep" % index)
		for other_index in range(index):
			check(not positive_volume_overlap(bounds, outbuilding_bounds[other_index]), "castle courtyard buildings %d and %d overlap" % [index, other_index])
			check(not horizontal_positive_overlap(horizontal_expanded_bounds(bounds, 0.36), horizontal_expanded_bounds(outbuilding_bounds[other_index], 0.36)), "castle courtyard buildings %d and %d have no visible roof clearance" % [index, other_index])
		for tower_bounds_value in tower_bounds:
			check(not horizontal_positive_overlap(bounds, tower_bounds_value), "castle courtyard building %d overlaps a tower footprint" % index)


func validate_castle_courtyard_city_blocks(planned_residences: Array, courtyard_program: Array) -> void:
	# A compound may vary source dimensions and furniture, but city-level lot
	# topology is deliberately stable: clear perimeter blocks first, then two
	# front inner rows. This makes a readable planned settlement instead of a
	# first-fit cluster that happens to pass collision checks.
	var district_grid := not planned_residences.is_empty() and planned_residences[0] is Dictionary and String((planned_residences[0] as Dictionary).get("cityGridMode", "")) == "district"
	if district_grid:
		# Every district pair is sampled from an explicit mirrored cell. The
		# builder must preserve those coordinates instead of collapsing a giant
		# citadel back into its compact five-column fallback.
		for index in range(0, planned_residences.size(), 2):
			if index + 1 >= planned_residences.size() or index + 1 >= courtyard_program.size() or not planned_residences[index] is Dictionary or not planned_residences[index + 1] is Dictionary:
				continue
			var left: Dictionary = planned_residences[index] as Dictionary
			var right: Dictionary = planned_residences[index + 1] as Dictionary
			var left_program: Dictionary = courtyard_program[index] as Dictionary
			var right_program: Dictionary = courtyard_program[index + 1] as Dictionary
			var left_center: Vector3 = left.get("center", Vector3.ZERO) as Vector3
			var right_center: Vector3 = right.get("center", Vector3.ZERO) as Vector3
			var band_index := int(left_program.get("cityGridColumn", -1))
			var district_class := String(left_program.get("districtClass", ""))
			check(String(left.get("cityGridMode", "")) == "district" and String(right.get("cityGridMode", "")) == "district", "castle district pair %d lost its grid authority" % (index / 2 + 1))
			check(int(left.get("cityGridRow", -1)) == int(right.get("cityGridRow", -2)), "castle district pair %d does not share a grid row" % (index / 2 + 1))
			check(int(left.get("cityGridColumn", -1)) == band_index and int(right.get("cityGridColumn", -1)) > band_index, "castle district pair %d lost its mirrored grid bands" % (index / 2 + 1))
			check(is_equal_approx(absf(left_center.x), absf(right_center.x)) and is_equal_approx(left_center.z, right_center.z), "castle district pair %d is not mirrored around the boulevard" % (index / 2 + 1))
			check(district_class in ["golden_lane", "wealthy"] and district_class == String(right_program.get("districtClass", "")), "castle district pair %d lost its shared neighbourhood class" % (index / 2 + 1))
			if district_class == "golden_lane":
				check(String(left_program.get("frontDirection", "")) in ["north", "south"] and String(right_program.get("frontDirection", "")) in ["north", "south"], "Golden-Lane pair %d does not front a transverse street" % (index / 2 + 1))
		return
	var expected_nodes := expected_castle_city_nodes(planned_residences.size())
	for index in range(0, planned_residences.size(), 2):
		if index + 1 >= planned_residences.size() or index + 1 >= courtyard_program.size() or not planned_residences[index] is Dictionary or not planned_residences[index + 1] is Dictionary:
			continue
		var pair_index := index / 2
		var expected_node := expected_nodes[pair_index] if pair_index < expected_nodes.size() else ""
		var left: Dictionary = planned_residences[index] as Dictionary
		var right: Dictionary = planned_residences[index + 1] as Dictionary
		var left_program: Dictionary = courtyard_program[index] as Dictionary
		var right_program: Dictionary = courtyard_program[index + 1] as Dictionary
		var expected_band := "outer" if expected_node.ends_with("_outer") else "inner"
		var expected_column_left := 0 if expected_band == "outer" else 1
		var expected_column_right := 4 if expected_band == "outer" else 3
		check(String(left_program.get("graphNode", "")) == expected_node and String(right_program.get("graphNode", "")) == expected_node, "castle courtyard pair %d does not follow the perimeter-first city-block order" % (pair_index + 1))
		check(String(left.get("cityGridBand", "")) == expected_band and String(right.get("cityGridBand", "")) == expected_band, "castle courtyard pair %d lost its planned city-grid band" % (pair_index + 1))
		check(int(left.get("cityGridColumn", -1)) == expected_column_left and int(right.get("cityGridColumn", -1)) == expected_column_right, "castle courtyard pair %d lost its mirrored grid columns" % (pair_index + 1))
		check(int(left.get("cityGridRow", -1)) == int(right.get("cityGridRow", -2)), "castle courtyard pair %d does not share a city-grid row" % (pair_index + 1))


func expected_castle_city_nodes(residence_count: int) -> Array[String]:
	if residence_count <= 4:
		return ["gate_outer", "rear_outer"]
	if residence_count <= 6:
		return ["gate_outer", "middle_outer", "rear_outer"]
	return ["gate_outer", "lower_outer", "middle_outer", "rear_outer", "gate_inner", "lower_inner"]


func courtyard_door_approach_bounds(door) -> AABB:
	# The rectangle begins beyond the leaf rather than treating a core-facing
	# rotation as proof that a player can actually step into the residence.
	var forward: Vector3 = Vector3(0.0, 0.0, -1.0).rotated(Vector3.UP, door.rotation.y).normalized()
	var approach_length := 2.80
	var approach_width := 2.20
	var center: Vector3 = door.position + forward * (approach_length * 0.5 + 0.32)
	if absf(forward.x) >= absf(forward.z):
		return AABB(center - Vector3(approach_length * 0.5, 0.0, approach_width * 0.5), Vector3(approach_length, maxf(2.0, door.size.y), approach_width))
	return AABB(center - Vector3(approach_width * 0.5, 0.0, approach_length * 0.5), Vector3(approach_width, maxf(2.0, door.size.y), approach_length))


func validate_castle_keep_roof(blueprint) -> void:
	var parts_by_id := {}
	for part in blueprint.parts:
		if part != null:
			parts_by_id[String(part.id)] = part
	var upper_register = parts_by_id.get("castle_keep_upper_register", null)
	var lower_roof_deck = parts_by_id.get("castle_keep_lower_roof_deck", null)
	var roof_cornice = parts_by_id.get("castle_keep_roof_cornice", null)
	var roof_deck = parts_by_id.get("castle_keep_roof_deck", null)
	check(upper_register != null and lower_roof_deck != null and roof_cornice != null and roof_deck != null, "castle keep lacks a complete lower-roof/upper-register/cornice/roof stack")
	if lower_roof_deck != null and upper_register != null:
		check(positive_volume_overlap(part_bounds(lower_roof_deck), part_bounds(upper_register)), "castle keep upper register is not seated into its lower roof deck")
	for lower_wall_id in ["castle_keep_back", "castle_keep_left", "castle_keep_right", "castle_keep_front_-1", "castle_keep_front_1"]:
		var lower_wall = parts_by_id.get(lower_wall_id, null)
		if lower_roof_deck != null and lower_wall != null:
			check(positive_volume_overlap(part_bounds(lower_roof_deck), part_bounds(lower_wall)), "castle keep lower roof deck does not close %s" % lower_wall_id)
	if upper_register != null and roof_cornice != null:
		check(positive_volume_overlap(part_bounds(upper_register), part_bounds(roof_cornice)), "castle keep cornice is detached from its upper register")
	if roof_cornice != null and roof_deck != null:
		check(positive_volume_overlap(part_bounds(roof_cornice), part_bounds(roof_deck)), "castle keep roof deck is detached from its cornice")


func validate_castle_gate_entry(blueprint) -> void:
	var parts_by_id := {}
	for part in blueprint.parts:
		if part != null:
			parts_by_id[String(part.id)] = part
	var previous_top := 0.0
	for step_index in range(1, 4):
		var step_id := "castle_gatehouse_entry_step_%02d" % step_index
		var step = parts_by_id.get(step_id, null)
		check(step != null, "castle gatehouse lacks entry step %d" % step_index)
		if step == null:
			continue
		var bounds := part_bounds(step)
		check(bounds.size.x > 1.80 and bounds.size.y > previous_top, "castle gatehouse entry step %d is not a usable rising tread" % step_index)
		previous_top = bounds.end.y
	var portcullis = parts_by_id.get("castle_gatehouse_portcullis", null)
	var gatehouse_foundation = parts_by_id.get("castle_gatehouse_foundation", null)
	var top_step = parts_by_id.get("castle_gatehouse_entry_step_03", null)
	check(gatehouse_foundation != null, "castle gatehouse lacks its continuous foundation")
	if gatehouse_foundation != null:
		for pier_id in ["castle_gatehouse_pier_-1", "castle_gatehouse_pier_1"]:
			var pier = parts_by_id.get(pier_id, null)
			if pier != null:
				check(is_equal_approx(part_bounds(gatehouse_foundation).end.y, part_bounds(pier).position.y), "castle gatehouse foundation does not support %s" % pier_id)
	if portcullis != null and top_step != null:
		check(horizontal_positive_overlap(part_bounds(portcullis), horizontal_expanded_bounds(part_bounds(top_step), 0.12)), "castle gatehouse top step does not meet the usable gate threshold")
		check(String(portcullis.material_id) == "ironwork", "castle gate is not published as ironwork")
		check(String(portcullis.recipe.get("doorPresentation", "")) == "portcullis" and String(portcullis.recipe.get("doorMotion", "")) == "raise", "castle gate lacks its raised-portcullis door contract")
	if gatehouse_foundation != null and top_step != null:
		check(horizontal_positive_overlap(part_bounds(gatehouse_foundation), horizontal_expanded_bounds(part_bounds(top_step), 0.12)), "castle gatehouse top step does not meet the founded passage floor")
	if portcullis != null and gatehouse_foundation != null:
		# From the raised gate to the inner edge of the founded gatehouse, the
		# only collision that may occupy the player-height central arch is the
		# closed gate itself.  This guards against a later wall/roof piece turning
		# the apparently open gatehouse into a dead-end masonry tunnel.
		var gate_bounds := part_bounds(portcullis)
		var foundation_bounds := part_bounds(gatehouse_foundation)
		var passage_start_z := gate_bounds.end.z + 0.06
		var passage_end_z := foundation_bounds.end.z - 0.08
		var passage_width := maxf(0.20, gate_bounds.size.x - 0.24)
		var passage_height := maxf(0.20, gate_bounds.size.y - 0.20)
		var passage_bounds := AABB(Vector3(-passage_width * 0.5, foundation_bounds.end.y + 0.06, passage_start_z), Vector3(passage_width, passage_height, maxf(0.02, passage_end_z - passage_start_z)))
		check(passage_bounds.size.z > 0.20, "castle gatehouse has no clear founded passage length")
		for part in blueprint.parts:
			if part == null or not bool(part.collision_enabled) or String(part.id) == "castle_gatehouse_portcullis" or String(part.kind) in ["foundation", "floor"]:
				continue
			check(not positive_volume_overlap(part_bounds(part), passage_bounds), "castle gatehouse passage is blocked by %s" % String(part.id))


func validate_castle_vertical_circulation(blueprint) -> void:
	# These checks cover published construction topology, not a teleport or
	# metadata route: every level has a room record, treads, stringers, a landing
	# and an exit on the physical floor above it.  The headed walkthrough remains
	# the evidence for player control on those stairs.
	var parts_by_id := {}
	var keep_storey_rooms := {}
	for part in blueprint.parts:
		if part != null:
			parts_by_id[String(part.id)] = part
	for room_value in blueprint.rooms:
		if room_value is Dictionary and (room_value as Dictionary).has("castleKeepStorey"):
			keep_storey_rooms[int((room_value as Dictionary).get("castleKeepStorey", -1))] = room_value
	var storey_count := int(blueprint.recipe.get("keepStoreyCount", 0))
	check(storey_count >= 3, "castle keep has no multi-storey circulation contract")
	check(keep_storey_rooms.size() == storey_count, "castle keep lacks room records for one or more occupied storeys")
	for storey_index in range(storey_count):
		var room: Dictionary = keep_storey_rooms.get(storey_index, {}) as Dictionary
		check(not room.is_empty() and not (room.get("accesses", []) as Array).is_empty(), "castle keep storey %d lacks its stair access record" % storey_index)
	for level in range(maxi(0, storey_count - 1)):
		var suffix := "%02d" % level
		var up_stringer = parts_by_id.get("castle_keep_stair_up_stringer_%s" % suffix, null)
		var return_stringer = parts_by_id.get("castle_keep_stair_return_stringer_%s" % suffix, null)
		var landing = parts_by_id.get("castle_keep_stair_landing_%s" % suffix, null)
		var exit = parts_by_id.get("castle_keep_stair_exit_%s" % suffix, null)
		check(up_stringer != null and return_stringer != null, "castle keep level %d lacks collision-backed stair stringers" % level)
		check(landing != null and exit != null, "castle keep level %d lacks a stair landing or upper-floor exit" % level)
		var tread_count := 0
		for part_id_value in parts_by_id.keys():
			var part_id := String(part_id_value)
			if part_id.begins_with("castle_keep_stair_up_tread_%s_" % suffix) or part_id.begins_with("castle_keep_stair_return_tread_%s_" % suffix):
				tread_count += 1
		check(tread_count >= 10, "castle keep level %d has too few visible stair treads" % level)
		var floor_panel_count := 0
		for part_id_value in parts_by_id.keys():
			if String(part_id_value).begins_with("castle_keep_storey_%02d_floor_" % (level + 1)):
				floor_panel_count += 1
		check(floor_panel_count >= 2, "castle keep storey %d does not split its floor around the stairwell" % (level + 1))
	var stair_door = parts_by_id.get("castle_gatehouse_wall_stair_door", null)
	check(stair_door != null and String(stair_door.kind) == "door" and String(stair_door.semantic) == "castle_gatehouse_wall_stair_entry", "castle gatehouse lacks the ordinary door into its wall staircase")
	var gate_stair_treads := 0
	var gate_stair_exits := 0
	for part_id_value in parts_by_id.keys():
		var part_id := String(part_id_value)
		if part_id.begins_with("castle_gatehouse_wall_stair_") and "_tread_" in part_id:
			gate_stair_treads += 1
		if part_id.begins_with("castle_gatehouse_wall_stair_exit_"):
			gate_stair_exits += 1
	check(gate_stair_treads >= 14 and gate_stair_exits >= 2, "castle gatehouse wall stair does not reach the wall walk through visible treads")
	for deck_id in ["castle_gatehouse_roof_deck_front", "castle_gatehouse_roof_deck_back", "castle_gatehouse_roof_deck_hatch_outer", "castle_gatehouse_roof_deck_hatch_inner"]:
		check(parts_by_id.has(deck_id), "castle gatehouse roof does not preserve deck panel %s around its stair hatch" % deck_id)


func horizontal_positive_overlap(first: AABB, second: AABB) -> bool:
	var epsilon := 0.0001
	return first.position.x < second.end.x - epsilon and first.end.x > second.position.x + epsilon and first.position.z < second.end.z - epsilon and first.end.z > second.position.z + epsilon


func horizontal_expanded_bounds(bounds: AABB, padding: float) -> AABB:
	return AABB(bounds.position - Vector3(padding, 0.0, padding), bounds.size + Vector3(padding * 2.0, 0.0, padding * 2.0))


func verify_castle_variation(context: Dictionary) -> Dictionary:
	var samples: Array = []
	var profiles := {}
	var widths: Array[float] = []
	var depths: Array[float] = []
	var tower_counts: Array[int] = []
	var keep_heights: Array[float] = []
	var courtyard_building_counts: Array[int] = []
	for sample_seed in range(208154, 208178):
		var compound := LandmarkBuildingRecipeSamplerScript.sample_compound(sample_seed, "castle", context)
		var grammar: Dictionary = compound.get("castleGrammar", {}) as Dictionary
		profiles[String(grammar.get("profile", ""))] = true
		widths.append(float(grammar.get("courtyardWidth", 0.0)))
		depths.append(float(grammar.get("courtyardDepth", 0.0)))
		tower_counts.append(int(grammar.get("towerCount", 0)))
		keep_heights.append(float(grammar.get("keepHeight", 0.0)))
		var courtyard_program: Array = grammar.get("courtyardProgram", []) as Array
		courtyard_building_counts.append(courtyard_program.size())
		var sample_blueprint = CastleCompoundBlueprintBuilderScript.build_from_compound(compound)
		check(sample_blueprint != null, "castle seed %d did not build a compound blueprint" % sample_seed)
		if sample_blueprint != null:
			validate_castle_courtyard_placement(sample_blueprint, grammar, courtyard_program)
			validate_castle_keep_roof(sample_blueprint)
			validate_castle_gate_entry(sample_blueprint)
			validate_castle_vertical_circulation(sample_blueprint)
		samples.append({"seed": sample_seed, "profile": grammar.get("profile"), "width": grammar.get("courtyardWidth"), "depth": grammar.get("courtyardDepth"), "towerCount": grammar.get("towerCount"), "keepHeight": grammar.get("keepHeight"), "courtyardBuildingCount": courtyard_program.size()})
	check(profiles.has("compact_keep") and profiles.has("walled_bailey") and profiles.has("grand_citadel"), "castle samples do not cover all seeded scale profiles")
	check(widths.max() - widths.min() >= 40.0, "castle width variation is too narrow")
	check(depths.max() - depths.min() >= 34.0, "castle depth variation is too narrow")
	check(tower_counts.max() - tower_counts.min() >= 3, "castle tower-count variation is too narrow")
	check(keep_heights.max() - keep_heights.min() >= 12.0, "castle height variation is too narrow")
	check(courtyard_building_counts.min() >= 2 and courtyard_building_counts.max() >= 12 and courtyard_building_counts.max() - courtyard_building_counts.min() >= 10, "castle courtyard building-program variation is too narrow")
	return {"samples": samples, "profiles": profiles.keys(), "widthRange": [widths.min(), widths.max()], "depthRange": [depths.min(), depths.max()], "towerCountRange": [tower_counts.min(), tower_counts.max()], "keepHeightRange": [keep_heights.min(), keep_heights.max()], "courtyardBuildingCountRange": [courtyard_building_counts.min(), courtyard_building_counts.max()]}


func check(condition: bool, failure: String) -> void:
	if not condition:
		failures.append(failure)


func write_report(report: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
