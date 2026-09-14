extends RefCounted
class_name CitadelUrbanHomeFurnishingPlanner

## Adapts procedurally generated Citadel house envelopes to the shared cottage
## furnishing grammar.  The urban composer owns final room/door geometry; this
## planner owns no house positions and never invents a parallel structure.

const BuildingBlueprintScript := preload("res://scripts/buildings/BuildingBlueprint.gd")
const FurnishingPlanScript := preload("res://scripts/buildings/FurnishingPlan.gd")
const CottageFurnishingPlannerScript := preload("res://scripts/buildings/CottageFurnishingPlanner.gd")
const InteriorFurnishingLayoutScript := preload("res://scripts/buildings/InteriorFurnishingLayout.gd")

const MAX_LAYOUT_CANDIDATES := 12
const MIN_ROOM_SPAN := 4.80
const STREET_FACADE_FURNITURE_CLEARANCE := 0.72


static func build(castle_blueprint, furnishing_seed: int):
	var result := prepare(castle_blueprint, furnishing_seed)
	return result.get("plan", null) if bool(result.get("ready", false)) else null


static func prepare(castle_blueprint, furnishing_seed: int) -> Dictionary:
	var blueprint_id := String(castle_blueprint.id) if castle_blueprint != null else "missing-citadel"
	var target = FurnishingPlanScript.new("urban-home-furnishing.%s.%d" % [blueprint_id, furnishing_seed], furnishing_seed, blueprint_id)
	if castle_blueprint == null:
		return {"ready": true, "plan": target, "homeCount": 0}
	var homes: Array = castle_blueprint.recipe.get("citadelUrbanHomes", []) as Array
	var seen_ids := {}
	for home_value in homes:
		if not home_value is Dictionary:
			return {"ready": false, "reason": "invalid_home_record"}
		var home: Dictionary = home_value as Dictionary
		var home_id := String(home.get("id", "")).strip_edges()
		if home_id.is_empty() or seen_ids.has(home_id):
			return {"ready": false, "reason": "missing_or_duplicate_home_id", "homeId": home_id}
		seen_ids[home_id] = true
		var source = _source_blueprint(home, furnishing_seed)
		if source == null:
			return {"ready": false, "reason": "invalid_home_envelope", "homeId": home_id}
		var selected = null
		var candidate_counts: Array = []
		for candidate_index in range(MAX_LAYOUT_CANDIDATES):
			var candidate_seed := int(("%d|citadel-urban-home|%s|%d" % [furnishing_seed, home_id, candidate_index]).hash())
			var candidate = _build_open_plan(source, candidate_seed)
			candidate_counts.append(_archetype_counts(candidate))
			if _has_required_home_furniture(candidate):
				selected = candidate
				break
		if selected == null:
			return {"ready": false, "reason": "required_furniture_layout_unavailable", "homeId": home_id, "candidateArchetypes": candidate_counts}
		if not _append_home(target, selected, home):
			return {"ready": false, "reason": "home_furniture_append_failed", "homeId": home_id}
	return {"ready": true, "plan": target, "homeCount": homes.size(), "partCount": target.parts.size()}


static func _source_blueprint(home: Dictionary, furnishing_seed: int):
	var home_id := String(home.get("id", "")).strip_edges()
	var width := float(home.get("interiorWidth", 0.0))
	var depth := float(home.get("interiorDepth", 0.0))
	var height := float(home.get("interiorHeight", 0.0))
	var street_side := signf(float(home.get("streetSide", 0.0)))
	if home_id.is_empty() or width < MIN_ROOM_SPAN or depth < MIN_ROOM_SPAN or height < 2.20 or is_zero_approx(street_side):
		return null
	var local_door_x := street_side * (width * 0.5 - 0.34)
	var access_size := Vector3(1.16, 2.18, 1.16)
	var exterior_access := {"id": "exterior_entry", "kind": "exterior_door", "position": Vector3(local_door_x, 0.52, 0.0), "size": access_size}
	var source = BuildingBlueprintScript.new("urban-home.%s" % home_id, furnishing_seed, "citadel_urban")
	source.set_recipe({"foundationHeight": 0.0, "furnishingProfile": "hearth_social", "streetSide": street_side})
	source.set_room_records([
		{"id": "home_room", "bounds": AABB(Vector3(-width * 0.5, 0.0, -depth * 0.5), Vector3(width, height, depth)), "wallMountInset": 0.30, "accesses": [exterior_access]}
	])
	return source


static func _build_open_plan(source, candidate_seed: int):
	var plan = FurnishingPlanScript.new("%s.%d" % [String(source.id), candidate_seed], candidate_seed, String(source.id))
	if source.rooms.is_empty():
		return plan
	var room: Dictionary = source.rooms[0] as Dictionary
	var rng := RandomNumberGenerator.new()
	rng.seed = candidate_seed
	var occupied: Array[AABB] = InteriorFurnishingLayoutScript.circulation_reservations(source.rooms)
	plan.set_protected_access_reservations(occupied)
	# Keep the generated street facade clear for its door, windows and structural
	# opening bearings. This is a local placement exclusion only; publishing it as
	# an access reservation would make the structural recipe reject its own wall.
	var room_bounds: AABB = room.get("bounds", AABB()) as AABB
	var street_side := signf(float(source.recipe.get("streetSide", 0.0)))
	var facade_clearance := AABB(
		Vector3(room_bounds.end.x - STREET_FACADE_FURNITURE_CLEARANCE, 0.0, room_bounds.position.z) if street_side > 0.0 else room_bounds.position,
		Vector3(STREET_FACADE_FURNITURE_CLEARANCE, room_bounds.size.y, room_bounds.size.z)
	)
	occupied.append(facade_clearance)
	var furnishing_walls: Array = ["back", "left"] if street_side > 0.0 else ["back", "right"]
	var bed = CottageFurnishingPlannerScript.place_essential_bed(plan, occupied, room, Vector2(rng.randf_range(0.24, 0.76), rng.randf_range(0.68, 0.88)), "wool_moss" if rng.randi_range(0, 1) == 0 else "wool_rust")
	var hearth = CottageFurnishingPlannerScript.place_against_random_walls(plan, occupied, room, "hearth", "hearth", "fired_brick", furnishing_walls, rng, Vector3(1.68, 1.88, 0.64), {"semantic": "hearth", "clearance": 0.10})
	var dining := CottageFurnishingPlannerScript.place_dining_set(plan, occupied, room, rng, 2)
	var table = dining.get("table", null)
	if bed != null:
		CottageFurnishingPlannerScript.add_rug_under_surface(plan, "bed_rug", bed, Vector2(1.10, 1.12), "wool_moss", "bedside_rug")
	if table != null:
		CottageFurnishingPlannerScript.add_rug_under_surface(plan, "table_rug", table, Vector2(1.18, 1.20), "wool_rust", "dining_rug")
		if rng.randf() < 0.72:
			CottageFurnishingPlannerScript.add_candle_on_surface(plan, "table_candle", table, Vector3(-0.16, 0.86, 0.08))
	CottageFurnishingPlannerScript.place_against_random_walls(plan, occupied, room, "storage", "chest", "timber_board", furnishing_walls, rng, Vector3(0.96, 0.70, 0.58), {"semantic": "storage", "clearance": 0.08, "interactionClearance": 0.82})
	if hearth != null and rng.randf() < 0.66:
		CottageFurnishingPlannerScript.place_wall_art(plan, room, "hearth_art", "painted_decor", String(hearth.recipe.get("supportingWall", "back")), rng.randf_range(0.18, 0.82), Vector3(0.82, 0.62, 0.08), 2.10)
	return plan


static func _has_required_home_furniture(plan) -> bool:
	if plan == null:
		return false
	var required := {"bed": false, "table": false, "chair": false, "hearth": false}
	for part in plan.parts:
		if part == null:
			continue
		var archetype := String(part.archetype)
		if required.has(archetype):
			required[archetype] = true
	return required.values().all(func(value): return value == true)


static func _archetype_counts(plan) -> Dictionary:
	var counts := {}
	if plan == null:
		return counts
	for part in plan.parts:
		if part != null:
			counts[String(part.archetype)] = int(counts.get(String(part.archetype), 0)) + 1
	return counts


static func _append_home(target, source_plan, home: Dictionary) -> bool:
	var home_id := String(home.get("id", "")).strip_edges()
	var room_id := String(home.get("roomId", "")).strip_edges()
	var origin: Vector3 = home.get("origin", Vector3.INF) as Vector3
	if home_id.is_empty() or room_id.is_empty() or not origin.is_finite():
		return false
	var id_map := {}
	for source_part in source_plan.parts:
		if source_part != null:
			id_map[String(source_part.id)] = "urban_home_%s__furnishing__%s" % [home_id, String(source_part.id)]
	# The generated Citadel room already publishes this same door/access record.
	# The local plan consumed it while choosing furniture, but must not republish
	# an ownerless duplicate into the castle-wide reservation collection.
	for source_part in source_plan.parts:
		if source_part == null:
			continue
		var values: Dictionary = source_part.snapshot()
		var recipe: Dictionary = source_part.recipe.duplicate(true)
		_remap_links(recipe, id_map)
		recipe["castleResidenceId"] = home_id
		recipe["castleResidenceFamily"] = "urban_home"
		recipe["citadelUrbanHomeId"] = home_id
		recipe["citadelUrbanSourceRoom"] = String(source_part.room_id)
		values["id"] = String(id_map.get(String(source_part.id), String(source_part.id)))
		values["roomId"] = room_id
		values["position"] = source_part.position + origin
		values["recipe"] = recipe
		if target.add_part(values) == null:
			return false
	return true


static func _remap_links(recipe: Dictionary, id_map: Dictionary) -> void:
	for key in ["tableId", "supportedBy", "mount"]:
		var source_id := String(recipe.get(key, "")).strip_edges()
		if not source_id.is_empty() and id_map.has(source_id):
			recipe[key] = id_map[source_id]
