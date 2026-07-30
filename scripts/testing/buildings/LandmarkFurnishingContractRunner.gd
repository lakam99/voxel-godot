extends SceneTree

## Focused contract for the civic furniture grammar. This is not a gameplay
## acceptance: it proves deterministic, access-preserving furnishing records
## before the headed Town Hall walkthrough consumes them.

const LandmarkBuildingBlueprintBuilderScript := preload("res://scripts/buildings/LandmarkBuildingBlueprintBuilder.gd")
const LandmarkFurnishingPlannerScript := preload("res://scripts/buildings/LandmarkFurnishingPlanner.gd")
const InteriorFurnishingLayoutScript := preload("res://scripts/buildings/InteriorFurnishingLayout.gd")
const FurnishingArchetypeCatalogScript := preload("res://scripts/buildings/FurnishingArchetypeCatalog.gd")

const SEEDS: Array[int] = [208154, 208155, 306701, 420901]

var report_path := ""
var failures: Array[String] = []
var observed_layouts := {}


func _initialize() -> void:
	call_deferred("run_contract")


func run_contract() -> void:
	report_path = OS.get_environment("VOXEL_LANDMARK_FURNISHING_CONTRACT_REPORT").strip_edges()
	if report_path.is_empty():
		report_path = ProjectSettings.globalize_path("res://artifacts/buildings/landmark-furnishing-contract.json")
	var rows: Array[Dictionary] = []
	for catalog_id in ["bench", "sideboard", "lectern", "map_table", "workbench", "crate_stack", "barrel_stack", "display_plinth", "dais", "civic_rug", "aisle_runner", "coat_rack", "planter", "wall_sconce", "wall_banner"]:
		check(FurnishingArchetypeCatalogScript.is_known(catalog_id), "Furnishing catalogue lacks reusable archetype %s" % catalog_id)
	for style in ["timber", "masonry"]:
		for seed in SEEDS:
			rows.append(verify_style_seed(style, seed))
	for layout in ["compact", "standard", "expanded"]:
		check(observed_layouts.has(layout), "Town Hall footprint sampling never produced the %s room layout" % layout)
	var report := {
		"runnerId": "landmark_furnishing_contract",
		"evidenceLevel": "contract",
		"scope": "Deterministic Town Hall furnishing records and access/walkability reservations. It does not prove visual readability, player physics, real door use, or live settlement integration.",
		"seeds": SEEDS,
		"observedLayouts": observed_layouts.keys(),
		"passed": failures.is_empty(),
		"styles": rows,
		"failures": failures
	}
	write_report(report)
	print(JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)


func verify_style_seed(style: String, seed: int) -> Dictionary:
	var blueprint = LandmarkBuildingBlueprintBuilderScript.build(seed, "town_hall", {
		"settlementTier": "town",
		"biome": "temperate",
		"siteKey": "civic-square",
		"style": style
	})
	var furnishing_seed := seed * 7919 + 37
	var plan = LandmarkFurnishingPlannerScript.build(blueprint, furnishing_seed)
	var replay = LandmarkFurnishingPlannerScript.build(blueprint, furnishing_seed)
	var layout := String(blueprint.recipe.get("townHallLayout", ""))
	observed_layouts[layout] = true
	check(plan.deterministic_signature() == replay.deterministic_signature(), "%s seed %d Town Hall furnishing did not replay deterministically" % [style, seed])
	check(plan.parts.size() >= 20 + blueprint.rooms.size() * 2, "%s seed %d %s Town Hall furnishing lacks landmark-scale density" % [style, seed, layout])
	var ids := {}
	var access_reservations: Array[AABB] = InteriorFurnishingLayoutScript.access_reservations(blueprint.rooms)
	var room_parts := {}
	var civic_dais = null
	var civic_lectern = null
	var public_table_count := 0
	var audience_bench_count := 0
	var audience_benches: Array = []
	var civic_notice_board = null
	var banner_count := 0
	for part in plan.parts:
		check(part != null, "%s seed %d plan contains a null furnishing" % [style, seed])
		if part == null:
			continue
		check(not ids.has(part.id), "%s seed %d repeats furnishing id %s" % [style, seed, String(part.id)])
		ids[part.id] = true
		var bounds := InteriorFurnishingLayoutScript.horizontal_bounds(part.position, part.occupied_size, part.rotation, 0.04)
		if String(part.archetype) not in ["rug", "aisle_runner"]:
			check(not InteriorFurnishingLayoutScript.intersects_any(bounds, access_reservations), "%s seed %d furnishing %s occupies declared access" % [style, seed, String(part.id)])
		if String(part.room_id) == "public_hall" and String(part.archetype) == "table":
			public_table_count += 1
		if String(part.id) == "civic_dais":
			civic_dais = part
		if String(part.id) == "civic_lectern":
			civic_lectern = part
		if String(part.id).begins_with("audience_bench_"):
			audience_bench_count += 1
			audience_benches.append(part)
		if String(part.id) == "civic_notice_board":
			civic_notice_board = part
		if String(part.archetype) == "wall_banner":
			banner_count += 1
			check(not part.collision_enabled and not String(part.recipe.get("supportingWall", "")).is_empty(), "%s seed %d banner %s is not a non-collision wall mount" % [style, seed, String(part.id)])
		var room_id := String(part.room_id)
		if not room_parts.has(room_id):
			room_parts[room_id] = []
		(room_parts[room_id] as Array).append(part)
	check(public_table_count == 0, "%s seed %d Town Hall mixed a council table into the speaker-and-audience hall" % [style, seed])
	check(civic_dais != null and civic_lectern != null, "%s seed %d Town Hall lacks its required dais and supported lectern" % [style, seed])
	if civic_dais != null and civic_lectern != null:
		check(String(civic_lectern.recipe.get("supportedBy", "")) == String(civic_dais.id), "%s seed %d civic lectern is not supported by the dais" % [style, seed])
		check(is_equal_approx(civic_lectern.position.y, civic_dais.position.y + civic_dais.occupied_size.y), "%s seed %d civic lectern is not physically on top of the dais" % [style, seed])
		check(footprint_contains(civic_dais, civic_lectern), "%s seed %d civic lectern hangs outside the dais footprint" % [style, seed])
		check(absf(wrapf(civic_lectern.rotation.y - civic_dais.rotation.y - PI, -PI, PI)) <= 0.001, "%s seed %d civic lectern still presents its paper side to the audience" % [style, seed])
	check(audience_bench_count >= 4, "%s seed %d Town Hall lacks the audience benches in front of the civic stage" % [style, seed])
	if civic_dais != null:
		for bench in audience_benches:
			check(is_in_front_of_stage(civic_dais, bench), "%s seed %d audience bench %s is not in front of the civic stage" % [style, seed, String(bench.id)])
	check(civic_notice_board != null and String(civic_notice_board.room_id) == "notice_archive" and String(civic_notice_board.recipe.get("supportingWall", "")) == "right", "%s seed %d civic notice board is not mounted on the archive's declared solid wall" % [style, seed])
	var expected_banner_count := 3 + (1 if has_room_role(blueprint.rooms, "steward_office") else 0)
	check(banner_count >= expected_banner_count, "%s seed %d %s Town Hall lacks reusable heraldic banner coverage" % [style, seed, layout])
	for room in blueprint.rooms:
		if not room is Dictionary:
			continue
		var room_record := room as Dictionary
		var room_id := String(room_record.get("id", ""))
		var parts: Array = room_parts.get(room_id, []) as Array
		var solid_parts: Array = []
		for part in parts:
			if part != null and part.collision_enabled:
				solid_parts.append(part)
		var walkability := InteriorFurnishingLayoutScript.room_walkability(room_record, solid_parts)
		check(int(walkability.get("accessSeedCells", 0)) > 0, "%s seed %d room %s lost all access cells" % [style, seed, room_id])
		check(int(walkability.get("unreachableCells", 0)) == 0, "%s seed %d room %s has unreachable floor after furnishing" % [style, seed, room_id])
		if String(room_record.get("role", "")) != "public_hall":
			var storage_count := 0
			for part in parts:
				if part != null and String(part.archetype) in ["shelf", "cabinet", "chest", "crate_stack", "barrel_stack", "sideboard"]:
					storage_count += 1
			check(parts.size() >= 5 and storage_count >= 3, "%s seed %d room %s leaves usable capacity without storage" % [style, seed, room_id])
	check((room_parts.get("public_hall", []) as Array).size() >= 12, "%s seed %d public hall lacks distributed civic furnishings" % [style, seed])
	check((room_parts.get("notice_archive", []) as Array).size() >= 8, "%s seed %d archive lacks role-appropriate work/storage furnishings" % [style, seed])
	if has_room_role(blueprint.rooms, "steward_office"):
		check((room_parts.get("steward_office", []) as Array).size() >= 6, "%s seed %d office lacks role-appropriate furnishings" % [style, seed])
	if has_room_role(blueprint.rooms, "civic_store"):
		check((room_parts.get("civic_store", []) as Array).size() >= 8, "%s seed %d civic store leaves too much usable capacity unfurnished" % [style, seed])
	for first_index in range(plan.parts.size()):
		var first = plan.parts[first_index]
		if first == null or not first.collision_enabled:
			continue
		var first_bounds := occupied_volume_bounds(first, 0.04)
		for second_index in range(first_index + 1, plan.parts.size()):
			var second = plan.parts[second_index]
			if second == null or not second.collision_enabled or String(first.room_id) != String(second.room_id):
				continue
			var second_bounds := occupied_volume_bounds(second, 0.04)
			check(not InteriorFurnishingLayoutScript.intersects_any(first_bounds, [second_bounds]), "%s seed %d furnishings %s and %s overlap" % [style, seed, String(first.id), String(second.id)])
	return {
		"style": style,
		"seed": seed,
		"blueprintSignature": hash(blueprint.deterministic_signature()),
		"furnishingSignature": hash(plan.deterministic_signature()),
		"layout": layout,
		"partCount": plan.parts.size(),
		"roomPartCounts": room_part_counts(room_parts)
	}


func room_part_counts(room_parts: Dictionary) -> Dictionary:
	var counts := {}
	for room_id in room_parts.keys():
		counts[String(room_id)] = (room_parts[room_id] as Array).size()
	return counts


func has_room_role(rooms: Array, required_role: String) -> bool:
	for raw_room in rooms:
		if raw_room is Dictionary and String((raw_room as Dictionary).get("role", "")) == required_role:
			return true
	return false


func occupied_volume_bounds(part, padding := 0.0) -> AABB:
	var horizontal := InteriorFurnishingLayoutScript.horizontal_bounds(part.position, part.occupied_size, part.rotation, padding)
	return AABB(Vector3(horizontal.position.x, part.position.y, horizontal.position.z), Vector3(horizontal.size.x, part.occupied_size.y, horizontal.size.z))


func footprint_contains(support, child) -> bool:
	var support_bounds := InteriorFurnishingLayoutScript.horizontal_bounds(support.position, support.occupied_size, support.rotation)
	var child_bounds := InteriorFurnishingLayoutScript.horizontal_bounds(child.position, child.occupied_size, child.rotation)
	return child_bounds.position.x >= support_bounds.position.x and child_bounds.end.x <= support_bounds.end.x and child_bounds.position.z >= support_bounds.position.z and child_bounds.end.z <= support_bounds.end.z


func is_in_front_of_stage(dais, bench) -> bool:
	var stage_front: Vector3 = Vector3(0.0, 0.0, -1.0).rotated(Vector3.UP, dais.rotation.y)
	var displacement: Vector3 = bench.position - dais.position
	return displacement.dot(stage_front) > dais.occupied_size.z * 0.5


func check(condition: bool, failure: String) -> void:
	if not condition:
		failures.append(failure)


func write_report(report: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
