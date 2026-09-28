extends SceneTree

## Procedural producer/service contract.  It exercises the real street-house
## builder and shared castle furnishing service across varied generated house
## envelopes.  It does not render or prove live gameplay.

const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Furniture = preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const UrbanFurniture = preload("res://scripts/buildings/CitadelUrbanHomeFurnishingPlanner.gd")
const Interior = preload("res://scripts/buildings/BuildingInteriorProgram.gd")
const Layout = preload("res://scripts/buildings/InteriorFurnishingLayout.gd")


func _init() -> void:
	var output_path := OS.get_environment("VOXEL_CITADEL_URBAN_HOME_FURNISHING_REPORT").simplify_path()
	if not output_path.is_absolute_path() or FileAccess.file_exists(output_path) or not DirAccess.dir_exists_absolute(output_path.get_base_dir()):
		quit(2)
		return
	var cases: Array = []
	var passed := true
	for seed in [3101, 88417, 1393179273]:
		var result := _case(seed)
		cases.append(result)
		passed = passed and bool(result.get("passed", false))
	var report := {
		"schema": "citadel_urban_home_furnishing_contract/v1",
		"passed": passed,
		"cases": cases,
		"scope": "Real procedural street-house producer and shared furnishing service; no rendering, publication, terrain, NPC, navigation, performance or live gameplay claim."
	}
	var output := FileAccess.open(output_path, FileAccess.WRITE)
	if output == null:
		quit(2)
		return
	output.store_string(JSON.stringify(_json(report), "\t"))
	output.close()
	quit(0 if passed else 1)


func _case(seed: int) -> Dictionary:
	var blueprint = Blueprint.new("citadel-urban-home-contract-%d" % seed, seed, "citadel_urban")
	blueprint.set_recipe({"foundationHeight": 0.62, "courtyardResidences": [], "citadelUrbanHomes": []})
	var generated := true
	var specs := [
		{"center": Vector3(-12.0, 0.0, -8.0), "width": 7.20, "depth": 6.20, "height": 6.20, "side": -1.0},
		{"center": Vector3(12.0, 0.0, -8.0), "width": 8.05, "depth": 7.10, "height": 7.05, "side": 1.0},
		{"center": Vector3(-12.0, 0.0, 8.0), "width": 8.80, "depth": 8.15, "height": 8.10, "side": -1.0},
		{"center": Vector3(12.0, 0.0, 8.0), "width": 9.45, "depth": 9.20, "height": 9.00, "side": 1.0}
	]
	for index in range(specs.size()):
		var spec: Dictionary = specs[index] as Dictionary
		generated = generated and Urban.add_street_house(blueprint, "generated_%d_%02d" % [seed, index], spec.center, spec.width, spec.depth, spec.height, spec.side, 0.62 + float(index) * 0.14, "painted_brick_cream", float(posmod(seed + index * 31, 101)) / 500.0)
	var homes: Array = blueprint.recipe.get("citadelUrbanHomes", []) as Array
	var urban_preparation := UrbanFurniture.prepare(blueprint, seed * 7919 + 37)
	var plan = Furniture.build(blueprint, seed * 7919 + 37)
	var room_by_id := {}
	for room_value in blueprint.rooms:
		if room_value is Dictionary:
			room_by_id[String((room_value as Dictionary).get("id", ""))] = room_value
	var home_results: Array = []
	var complete := generated and plan != null and homes.size() == specs.size()
	for home_value in homes:
		var home: Dictionary = home_value as Dictionary
		var home_id := String(home.get("id", ""))
		var room_id := String(home.get("roomId", ""))
		var room: Dictionary = room_by_id.get(room_id, {}) as Dictionary
		var parts: Array = []
		if plan != null:
			for part in plan.parts:
				if part != null and String(part.recipe.get("citadelUrbanHomeId", "")) == home_id:
					parts.append(part)
		var archetypes := {}
		var contained := not room.is_empty()
		var street_side := signf(float(home.get("streetSide", 0.0)))
		var street_facade_clear := not room.is_empty() and not is_zero_approx(street_side)
		var bound_room_owned := true
		for part in parts:
			archetypes[String(part.archetype)] = int(archetypes.get(String(part.archetype), 0)) + 1
			bound_room_owned = bound_room_owned and String(part.room_id) == room_id
			if not room.is_empty():
				var room_bounds: AABB = room.get("bounds", AABB()) as AABB
				var part_bounds := Layout.horizontal_bounds(part.position, part.occupied_size, part.rotation)
				contained = contained and _inside_room(part_bounds, room_bounds)
				street_facade_clear = street_facade_clear and (part_bounds.end.x <= room_bounds.end.x - UrbanFurniture.STREET_FACADE_FURNITURE_CLEARANCE + 0.015 if street_side > 0.0 \
					else part_bounds.position.x >= room_bounds.position.x + UrbanFurniture.STREET_FACADE_FURNITURE_CLEARANCE - 0.015)
		var required := ["bed", "table", "chair", "hearth"]
		var home_passed := not parts.is_empty() and bound_room_owned and contained and street_facade_clear and required.all(func(archetype): return int(archetypes.get(archetype, 0)) > 0)
		home_results.append({"id": home_id, "roomId": room_id, "partCount": parts.size(), "archetypes": archetypes, "contained": contained, "streetFacadeClear": street_facade_clear, "roomOwned": bound_room_owned, "passed": home_passed})
		complete = complete and home_passed
	var interior_audit := Interior.audit_plan(blueprint, plan) if plan != null else {"passed": false}
	var window_ornaments := 0
	if plan != null:
		for part in plan.parts:
			if part != null and not String(part.recipe.get("interiorProgramWindowId", "")).is_empty():
				window_ornaments += 1
	var near_tree := {"id": "near", "position": (homes[0] as Dictionary).get("origin", Vector3.ZERO), "canopyRadius": 4.0}
	var far_tree := {"id": "far", "position": Vector3(0.0, 0.62, 32.0), "canopyRadius": 3.0}
	var retained_trees := Urban.retain_home_clear_tree_records(blueprint, [near_tree, far_tree])
	var checks := {
		"procedural_house_count_matches_descriptors": generated and homes.size() == specs.size(),
		"every_generated_home_has_required_room_owned_furniture": complete,
		"clear_view_windows_have_no_sill_ornaments": window_ornaments == 0 and bool(interior_audit.get("passed", false)),
		"actual_canopy_envelope_rejects_home_overlap": retained_trees.size() == 1 and String((retained_trees[0] as Dictionary).get("id", "")) == "far"
	}
	return {"seed": seed, "passed": checks.values().all(func(value): return value == true), "checks": checks, "generatedHomeCount": homes.size(), "furnishingPartCount": plan.parts.size() if plan != null else 0, "urbanPreparation": urban_preparation, "windowAudit": interior_audit, "homes": home_results}


func _inside_room(part_bounds: AABB, room_bounds: AABB) -> bool:
	var margin := 0.015
	return part_bounds.position.x >= room_bounds.position.x - margin and part_bounds.end.x <= room_bounds.end.x + margin \
		and part_bounds.position.z >= room_bounds.position.z - margin and part_bounds.end.z <= room_bounds.end.z + margin


func _json(value: Variant) -> Variant:
	if value is Vector2:
		return [value.x, value.y]
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is AABB:
		return {"position": _json(value.position), "size": _json(value.size)}
	if value is Dictionary:
		var result := {}
		for key in value:
			result[String(key)] = _json(value[key])
		return result
	if value is Array:
		return value.map(func(item): return _json(item))
	return value
