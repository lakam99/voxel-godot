extends SceneTree

## Multi-seed proof for the recipe-driven cottage PoC. It verifies that each
## seed has one stable blueprint/furnishing authority, while sampled recipes
## genuinely differ and retain access/collision invariants.

const CottageRecipeSamplerScript := preload("res://scripts/buildings/CottageRecipeSampler.gd")
const CottageBlueprintBuilderScript := preload("res://scripts/buildings/CottageBlueprintBuilder.gd")
const CottageFurnishingPlannerScript := preload("res://scripts/buildings/CottageFurnishingPlanner.gd")
const BuildingPartPublisherScript := preload("res://scripts/buildings/BuildingPartPublisher.gd")
const InteriorFurnishingLayoutScript := preload("res://scripts/buildings/InteriorFurnishingLayout.gd")

const SEEDS: Array[int] = [1543, 7651, 207154, 481516, 17, 89, 512, 4096, 7331, 10007, 22222, 91357]

var report_path := ""
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("run_contract")


func run_contract() -> void:
	report_path = OS.get_environment("VOXEL_SEEDED_COTTAGE_RECIPE_CONTRACT_REPORT").strip_edges()
	if report_path.is_empty():
		report_path = ProjectSettings.globalize_path("res://artifacts/buildings/seeded-cottage-recipe-contract.json")
	var styles: Array[Dictionary] = []
	for style in ["timber", "masonry"]:
		styles.append(verify_style(style))
	var passed := failures.is_empty()
	var report := {
		"runnerId": "seeded_cottage_recipe_contract",
		"evidenceLevel": "contract+headless-multiseed",
		"scope": "Twelve deterministic cottage recipes per material style. This proves recipe replay, cross-seed variation, source-to-publication continuity, furnishing logic, and room accessibility; visual review remains the PoC acceptance gate.",
		"seeds": SEEDS,
		"passed": passed,
		"styles": styles,
		"failures": failures
	}
	write_report(report)
	print(JSON.stringify(report))
	quit(0 if passed else 1)


func verify_style(style: String) -> Dictionary:
	var rows: Array[Dictionary] = []
	var recipe_signatures := {}
	var blueprint_signatures := {}
	var furnishing_signatures := {}
	for seed in SEEDS:
		var recipe := CottageRecipeSamplerScript.sample(seed, style)
		var replay_recipe := CottageRecipeSamplerScript.sample(seed, style)
		var recipe_signature := JSON.stringify(recipe)
		check(recipe_signature == JSON.stringify(replay_recipe), "%s seed %d recipe is not deterministic" % [style, seed])
		recipe_signatures[recipe_signature] = true
		var blueprint = CottageBlueprintBuilderScript.build(seed, style)
		var replay_blueprint = CottageBlueprintBuilderScript.build(seed, style)
		check(blueprint.deterministic_signature() == replay_blueprint.deterministic_signature(), "%s seed %d blueprint is not deterministic" % [style, seed])
		check(JSON.stringify(blueprint.recipe) == recipe_signature, "%s seed %d blueprint did not retain its sampled recipe" % [style, seed])
		blueprint_signatures[blueprint.deterministic_signature()] = true
		validate_blueprint(style, seed, blueprint)
		var fixture := Node3D.new()
		get_root().add_child(fixture)
		var publisher = BuildingPartPublisherScript.new()
		var publication: Dictionary = publisher.publish(blueprint, fixture)
		check(int(publication.get("publishedPartCount", -1)) == blueprint.parts.size(), "%s seed %d publisher omitted a blueprint part" % [style, seed])
		fixture.free()
		var furnishing = CottageFurnishingPlannerScript.build(blueprint, seed * 7919 + 37)
		var replay_furnishing = CottageFurnishingPlannerScript.build(blueprint, seed * 7919 + 37)
		check(furnishing.deterministic_signature() == replay_furnishing.deterministic_signature(), "%s seed %d furnishing plan is not deterministic" % [style, seed])
		furnishing_signatures[furnishing.deterministic_signature()] = true
		validate_furnishing(style, seed, blueprint, furnishing)
		rows.append({
			"seed": seed,
			"recipe": {
				"width": recipe.get("width"), "depth": recipe.get("depth"), "wallHeight": recipe.get("wallHeight"),
				"roofRise": recipe.get("roofRise"), "dividerX": recipe.get("dividerX"), "furnishingProfile": recipe.get("furnishingProfile")
			},
			"blueprintParts": blueprint.parts.size(),
			"furnishingParts": furnishing.parts.size(),
			"publication": publication
		})
	check(recipe_signatures.size() == SEEDS.size(), "%s sampled recipes did not vary across the PoC seed set" % style)
	check(blueprint_signatures.size() == SEEDS.size(), "%s blueprints did not vary across the PoC seed set" % style)
	check(furnishing_signatures.size() == SEEDS.size(), "%s furnishing plans did not vary across the PoC seed set" % style)
	return {"style": style, "seeds": rows}


func validate_blueprint(style: String, seed: int, blueprint) -> void:
	for part in blueprint.parts:
		check(part != null and part.size.x > 0.0 and part.size.y > 0.0 and part.size.z > 0.0, "%s seed %d has invalid construction volume" % [style, seed])
		if part == null or part.semantic != "window":
			continue
		var window_bounds := AABB(part.position - part.size * 0.5, part.size)
		for wall in blueprint.parts:
			if wall == null or wall.kind != "wall":
				continue
			check(not positive_volume_overlap(window_bounds, AABB(wall.position - wall.size * 0.5, wall.size)), "%s seed %d leaves wall volume in window %s" % [style, seed, String(part.id)])


func validate_furnishing(style: String, seed: int, blueprint, furnishing) -> void:
	var parts_by_id := {}
	var collision_parts: Array = []
	var dining_chairs: Array = []
	var rooms_by_id := {}
	for raw_room in blueprint.rooms:
		if raw_room is Dictionary:
			var room := raw_room as Dictionary
			rooms_by_id[String(room.get("id", ""))] = room
	for part in furnishing.parts:
		if part == null:
			continue
		parts_by_id[String(part.id)] = part
		if part.collision_enabled:
			collision_parts.append(part)
		if String(part.semantic) == "dining_chair":
			dining_chairs.append(part)
	var table = parts_by_id.get("table", null)
	check(table != null, "%s seed %d lost its dining table" % [style, seed])
	check(not dining_chairs.is_empty(), "%s seed %d generated a table without dining chairs" % [style, seed])
	check(parts_by_id.has("hearth"), "%s seed %d lost its hearth" % [style, seed])
	check(parts_by_id.has("bed"), "%s seed %d lost its bed" % [style, seed])
	for chair in dining_chairs:
		check(String(chair.recipe.get("tableId", "")) == "table", "%s seed %d chair %s lacks a table relation" % [style, seed, String(chair.id)])
		if table != null:
			var toward_table: Vector3 = table.position - chair.position
			toward_table.y = 0.0
			var facing := Vector3(0.0, 0.0, -1.0).rotated(Vector3.UP, chair.rotation.y)
			check(toward_table.length_squared() > 0.0001 and facing.normalized().dot(toward_table.normalized()) > 0.72, "%s seed %d chair %s does not face its table" % [style, seed, String(chair.id)])
	for first_index in range(collision_parts.size()):
		var first = collision_parts[first_index]
		var first_bounds := InteriorFurnishingLayoutScript.horizontal_bounds(first.position, first.occupied_size, first.rotation)
		for second_index in range(first_index + 1, collision_parts.size()):
			var second = collision_parts[second_index]
			var second_bounds := InteriorFurnishingLayoutScript.horizontal_bounds(second.position, second.occupied_size, second.rotation)
			check(not first_bounds.intersects(second_bounds), "%s seed %d furnishings %s and %s overlap" % [style, seed, String(first.id), String(second.id)])
	var accesses := InteriorFurnishingLayoutScript.access_reservations(blueprint.rooms)
	for part in collision_parts:
		var interaction_depth := float(part.recipe.get("interactionClearance", 0.0))
		if interaction_depth <= 0.0:
			continue
		var interaction := InteriorFurnishingLayoutScript.interaction_bounds(part.position, part.occupied_size, part.rotation, interaction_depth)
		check(not InteriorFurnishingLayoutScript.intersects_any(interaction, accesses), "%s seed %d action furniture %s blocks room access" % [style, seed, String(part.id)])
		for other in collision_parts:
			if other == part:
				continue
			var other_bounds := InteriorFurnishingLayoutScript.horizontal_bounds(other.position, other.occupied_size, other.rotation)
			check(not interaction.intersects(other_bounds), "%s seed %d action furniture %s has blocked front access" % [style, seed, String(part.id)])
	for part in furnishing.parts:
		if part == null:
			continue
		if String(part.archetype) == "candle":
			check(String(part.recipe.get("mountSurface", "")) in ["table", "cabinet", "chest", "shelf"], "%s seed %d candle %s has unsafe support" % [style, seed, String(part.id)])
		if String(part.archetype) == "wall_art":
			var art_wall := String(part.recipe.get("supportingWall", ""))
			var art_room: Dictionary = rooms_by_id.get(String(part.room_id), {}) as Dictionary
			check(String(part.recipe.get("mountMode", "")) == "back_face_on_wall", "%s seed %d wall art %s lacks a back-face mount contract" % [style, seed, String(part.id)])
			check(InteriorFurnishingLayoutScript.wall_mount_back_face_is_on_wall(art_room, art_wall, part.position, part.rotation, part.occupied_size), "%s seed %d wall art %s is not physically mounted to its wall" % [style, seed, String(part.id)])
		if part.recipe.has("supportingWall") and part.collision_enabled:
			var expected_rotation := InteriorFurnishingLayoutScript.wall_facing_rotation(String(part.recipe.get("supportingWall", "")))
			check(absf(wrapf(part.rotation.y - expected_rotation.y, -PI, PI)) < 0.001, "%s seed %d wall furnishing %s faces incorrectly" % [style, seed, String(part.id)])
	for raw_room in blueprint.rooms:
		if not raw_room is Dictionary:
			continue
		var room := raw_room as Dictionary
		var room_id := String(room.get("id", ""))
		var solids: Array = []
		for part in furnishing.parts:
			if part != null and part.collision_enabled and String(part.room_id) == room_id:
				solids.append(part)
		var walkability: Dictionary = InteriorFurnishingLayoutScript.room_walkability(room, solids)
		check(int(walkability.get("accessSeedCells", 0)) > 0, "%s seed %d room %s has no accessible entry" % [style, seed, room_id])
		check(int(walkability.get("unreachableCells", 0)) == 0, "%s seed %d room %s strands open floor" % [style, seed, room_id])


func positive_volume_overlap(first: AABB, second: AABB) -> bool:
	var epsilon := 0.0001
	return first.position.x < second.end.x - epsilon and first.end.x > second.position.x + epsilon and first.position.y < second.end.y - epsilon and first.end.y > second.position.y + epsilon and first.position.z < second.end.z - epsilon and first.end.z > second.position.z + epsilon


func check(condition: bool, failure: String) -> void:
	if not condition:
		failures.append(failure)


func write_report(report: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
