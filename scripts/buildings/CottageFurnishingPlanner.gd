extends RefCounted
class_name CottageFurnishingPlanner

## Room-aware furnishing grammar for the first interior PoC. It consumes the
## published cottage's semantic room records; no fixture owns hand-placed
## furniture transforms. Future house grammars can select this planner or
## another one while keeping the same FurnishingPlan/FurnishingPart contract.

const FurnishingPlanScript := preload("res://scripts/buildings/FurnishingPlan.gd")
const InteriorFurnishingLayoutScript := preload("res://scripts/buildings/InteriorFurnishingLayout.gd")
const FurnishingArchetypeCatalogScript := preload("res://scripts/buildings/FurnishingArchetypeCatalog.gd")
const BuildingInteriorProgramScript := preload("res://scripts/buildings/BuildingInteriorProgram.gd")
const NpcConstantsScript := preload("res://scripts/buildings/layout/BuildingLayoutConstants.gd")

const FLOOR_Y := 0.70
const NPC_EGRESS_CLEARANCE := NpcConstantsScript.DEFAULT_NPC_RADIUS + NpcConstantsScript.DEFAULT_PERSONAL_SPACE_MARGIN


static func build(blueprint, furnishing_seed: int, furnishing_options: Dictionary = {}):
	var blueprint_id := String(blueprint.id) if blueprint != null else "missing-blueprint"
	var plan = FurnishingPlanScript.new("furnishing.%s.%d" % [blueprint_id, furnishing_seed], furnishing_seed, blueprint_id)
	if blueprint == null:
		return plan
	plan.set_protected_access_reservations(InteriorFurnishingLayoutScript.circulation_reservations(blueprint.rooms))
	var rooms := rooms_by_id(blueprint.rooms)
	var hearth_room: Dictionary = rooms.get("hearth_room", {}) as Dictionary
	var sleeping_room: Dictionary = rooms.get("sleeping_room", {}) as Dictionary
	if hearth_room.is_empty() or sleeping_room.is_empty():
		return plan
	var rng := RandomNumberGenerator.new()
	rng.seed = furnishing_seed
	var rug_material := "wool_moss" if rng.randi_range(0, 1) == 0 else "wool_rust"
	var blanket_material := "wool_rust" if rug_material == "wool_moss" else "wool_moss"
	var art_material := "painted_decor"
	var egress_safe := bool(furnishing_options.get("egressSafe", false))
	var furnishing_profile := String(blueprint.recipe.get("furnishingProfile", "hearth_social"))
	var dining_seat_goal := 0 if egress_safe else 2 if furnishing_profile == "hearth_social" else 1
	if dining_seat_goal > 0 and furnishing_profile == "hearth_social" and rng.randf() < 0.40:
		dining_seat_goal += 1
	# Circulation comes from semantic room accesses, not from a one-off list of
	# furniture offsets. Every substantial furnishing must respect these lanes.
	var occupied: Array[AABB] = InteriorFurnishingLayoutScript.circulation_reservations(blueprint.rooms)

	# Every placement below is sampled from room-relative anchors, then accepted
	# only if it preserves all reserved traffic/action space. This makes one seed
	# a coherent interior recipe, not a list of shuffled fixture transforms.
	var hearth = place_against_random_walls(plan, occupied, hearth_room, "hearth", "hearth", "fired_brick", ["back", "left", "right"], rng, Vector3(1.68, 1.88, 0.64), {"semantic": "hearth", "clearance": 0.10})
	var cabinet = null
	var shelf = null
	if not egress_safe:
		cabinet = place_against_random_walls(plan, occupied, hearth_room, "cabinet", "cabinet", "timber_beam", ["back", "left", "right"], rng, Vector3(0.78, 1.46, 0.42), {"semantic": "storage", "clearance": 0.08, "interactionClearance": 0.92})
		shelf = place_against_random_walls(plan, occupied, hearth_room, "shelf", "shelf", "timber_beam", ["back", "left", "right"], rng, Vector3(0.66, 1.64, 0.40), {"semantic": "shelf", "clearance": 0.08})
	place(plan, occupied, hearth_room, "hearth_rug", "rug", rug_material, Vector2(rng.randf_range(0.42, 0.62), rng.randf_range(0.32, 0.52)), Vector3(2.24, 0.035, 1.56), {"semantic": "rug", "collision": false, "reserve": false})
	var dining := place_dining_set(plan, occupied, hearth_room, rng, dining_seat_goal) if dining_seat_goal > 0 else {}
	var table = dining.get("table", null)
	if table != null:
		if rng.randf() < 0.72:
			add_candle_on_surface(plan, "table_candle", table, Vector3(rng.randf_range(-0.24, -0.08), 0.86, rng.randf_range(-0.12, 0.12)))
		if rng.randf() < 0.78:
			add_part(plan, "table_pot", "hearth_room", "pot_plant", "ceramic_glaze", table.position + Vector3(rng.randf_range(0.10, 0.28), 0.85, rng.randf_range(-0.12, 0.12)), Vector3(0.42, 0.64, 0.42), {"collision": false, "semantic": "table_decor", "mount": "table"})
	if not egress_safe and rng.randf() < 0.55:
		place_against_random_walls(plan, occupied, hearth_room, "reading_chair", "chair", "timber_board", ["back", "left", "right"], rng, Vector3(0.56, 0.92, 0.58), {"semantic": "reading_chair", "clearance": 0.04})
	if hearth != null:
		place_wall_art(plan, hearth_room, "hearth_art", art_material, String(hearth.recipe.get("supportingWall", "back")), rng.randf_range(0.16, 0.84), Vector3(0.94, 0.74, 0.08), 2.80)
	elif shelf != null:
		place_wall_art(plan, hearth_room, "hearth_art", art_material, String(shelf.recipe.get("supportingWall", "back")), rng.randf_range(0.16, 0.84), Vector3(0.94, 0.74, 0.08), 2.80)

	# Sleeping room: a bed remains essential, but its room-relative position,
	# bedside furnishing, storage wall, shelf wall and decor are seed-selected.
	var bed_normalized := Vector2(rng.randf_range(0.40, 0.64), rng.randf_range(0.80, 0.90))
	place(plan, occupied, sleeping_room, "bed_rug", "rug", rug_material, Vector2(bed_normalized.x, maxf(0.56, bed_normalized.y - 0.18)), Vector3(2.42, 0.035, 1.62), {"semantic": "rug", "collision": false, "reserve": false})
	var bed = place_essential_bed(plan, occupied, sleeping_room, bed_normalized, blanket_material)
	var bedside = null
	if bed != null and not egress_safe:
		bedside = place_at(plan, occupied, "bedside", "sleeping_room", "cabinet", "timber_beam", bed.position + Vector3(-bed.occupied_size.x * 0.5 - 0.54 * 0.5 - 0.26, 0.0, 0.0), Vector3(0.54, 0.72, 0.46), {"semantic": "bedside", "clearance": 0.06, "interactionClearance": 0.64}, sleeping_room)
	var chest = null
	var sleeping_shelf = null
	if not egress_safe:
		chest = place_against_random_walls(plan, occupied, sleeping_room, "chest", "chest", "timber_board", ["back", "right", "left"], rng, Vector3(0.96, 0.70, 0.58), {"semantic": "storage", "clearance": 0.08, "interactionClearance": 0.82})
		sleeping_shelf = place_against_random_walls(plan, occupied, sleeping_room, "sleeping_shelf", "shelf", "timber_beam", ["back", "right", "left"], rng, Vector3(0.62, 1.64, 0.38), {"semantic": "shelf", "clearance": 0.08})
	if bed != null:
		if bedside != null:
			add_candle_on_surface(plan, "bedside_candle", bedside, Vector3(rng.randf_range(-0.12, 0.12), bedside.occupied_size.y + 0.04, rng.randf_range(-0.08, 0.08)))
	if rng.randf() < 0.72:
		var art_wall := String(sleeping_shelf.recipe.get("supportingWall", "back")) if sleeping_shelf != null else String(chest.recipe.get("supportingWall", "back")) if chest != null else "back"
		place_wall_art(plan, sleeping_room, "sleeping_art", art_material, art_wall, rng.randf_range(0.18, 0.82), Vector3(0.82, 0.62, 0.08), 2.10)
	BuildingInteriorProgramScript.apply_to_plan(blueprint, plan)
	return plan


static func place_against_random_walls(plan, occupied: Array[AABB], room: Dictionary, part_id: String, archetype: String, material: String, wall_ids: Array, rng: RandomNumberGenerator, size: Vector3, options: Dictionary = {}):
	var remaining: Array = wall_ids.duplicate()
	while not remaining.is_empty():
		var index := rng.randi_range(0, remaining.size() - 1)
		var wall_id := String(remaining[index])
		remaining.remove_at(index)
		for _attempt in range(3):
			var part = place_against_wall(plan, occupied, room, part_id, archetype, material, wall_id, rng.randf_range(0.14, 0.86), size, options)
			if part != null:
				return part
	return null


static func place_essential_bed(plan, occupied: Array[AABB], room: Dictionary, preferred_normalized: Vector2, blanket_material: String):
	var candidates: Array[Vector2] = [
		preferred_normalized,
		Vector2(0.30, 0.84),
		Vector2(0.70, 0.84),
		Vector2(0.30, 0.68),
		Vector2(0.70, 0.68),
		Vector2(0.50, 0.84)
	]
	for normalized in candidates:
		var bed = place(plan, occupied, room, "bed", "bed", "timber_beam", normalized, Vector3(2.26, 0.76, 1.28), {"semantic": "bed", "blanket": blanket_material, "clearance": 0.10, "interactionClearance": 1.45})
		if bed != null:
			return bed
	for wall_id in ["right", "back", "left"]:
		var wall_bed = place_against_wall(plan, occupied, room, "bed", "bed", "timber_beam", wall_id, 0.66, Vector3(2.26, 0.76, 1.28), {"semantic": "bed", "blanket": blanket_material, "clearance": 0.10, "interactionClearance": 1.45})
		if wall_bed != null:
			return wall_bed
	for normalized in [Vector2(0.72, 0.66), Vector2(0.72, 0.50), Vector2(0.50, 0.70)]:
		var compact_bed = place(plan, occupied, room, "bed", "bed", "timber_beam", normalized, Vector3(1.34, 0.76, 2.08), {"semantic": "bed", "blanket": blanket_material, "bedVariant": "single", "clearance": 0.10, "interactionClearance": 1.45})
		if compact_bed != null:
			return compact_bed
	return null


static func place_dining_set(plan, occupied: Array[AABB], room: Dictionary, rng: RandomNumberGenerator, requested_seats: int) -> Dictionary:
	# Reserve a table and at least one table-facing chair as one transaction. A
	# failed chair candidate discards the table candidate, so the grammar cannot
	# publish a stranded table with no usable seating.
	var table_size: Vector3 = room.get("diningTableSize", Vector3(1.54, 0.84, 1.04)) as Vector3
	var chair_size := Vector3(0.56, 0.92, 0.58)
	var seat_definitions: Array[Dictionary] = [
		{"offset": Vector3(0.0, 0.0, 1.0), "yaw": 0.0},
		{"offset": Vector3(1.0, 0.0, 0.0), "yaw": PI * 0.5},
		{"offset": Vector3(0.0, 0.0, -1.0), "yaw": PI},
		{"offset": Vector3(-1.0, 0.0, 0.0), "yaw": -PI * 0.5}
	]
	for _attempt in range(16):
		var table_position := random_room_position(room, table_size, rng, 0.20)
		var table_bounds := InteriorFurnishingLayoutScript.horizontal_bounds(table_position, table_size, Vector3.ZERO, 0.08)
		if InteriorFurnishingLayoutScript.intersects_any(table_bounds, occupied):
			continue
		var provisional: Array[AABB] = occupied.duplicate()
		provisional.append(table_bounds)
		var walkability_candidates: Array[AABB] = [InteriorFurnishingLayoutScript.horizontal_bounds(table_position, table_size, Vector3.ZERO, NPC_EGRESS_CLEARANCE)]
		var remaining: Array = seat_definitions.duplicate()
		var seats: Array[Dictionary] = []
		while not remaining.is_empty() and seats.size() < maxi(1, requested_seats):
			var definition_index := rng.randi_range(0, remaining.size() - 1)
			var definition: Dictionary = remaining[definition_index] as Dictionary
			remaining.remove_at(definition_index)
			var direction: Vector3 = definition.get("offset", Vector3.ZERO) as Vector3
			var yaw := float(definition.get("yaw", 0.0))
			var separation := table_size.z * 0.5 + chair_size.z * 0.5 + 0.16 if absf(direction.z) > 0.5 else table_size.x * 0.5 + chair_size.z * 0.5 + 0.16
			var chair_position := table_position + direction * separation
			var rotation := Vector3(0.0, yaw, 0.0)
			var chair_bounds := InteriorFurnishingLayoutScript.horizontal_bounds(chair_position, chair_size, rotation, 0.04)
			if not candidate_is_inside_room(chair_bounds, room) or InteriorFurnishingLayoutScript.intersects_any(chair_bounds, provisional):
				continue
			seats.append({"position": chair_position, "rotation": rotation, "bounds": chair_bounds})
			provisional.append(chair_bounds)
			walkability_candidates.append(InteriorFurnishingLayoutScript.horizontal_bounds(chair_position, chair_size, rotation, NPC_EGRESS_CLEARANCE))
		if seats.is_empty():
			continue
		if not candidate_bounds_keep_room_walkable(plan, room, walkability_candidates):
			continue
		var table = add_part(plan, "table", String(room.get("id", "")), "table", "timber_board", table_position, table_size, {"semantic": "dining_table", "clearance": 0.08, "seatingTarget": requested_seats})
		if table == null:
			continue
		var chair_parts: Array = []
		var rejected := false
		for seat_index in range(seats.size()):
			var seat: Dictionary = seats[seat_index] as Dictionary
			var chair = add_part(plan, "dining_chair_%d" % (seat_index + 1), String(room.get("id", "")), "chair", "timber_board", seat.get("position", Vector3.ZERO) as Vector3, chair_size, {"semantic": "dining_chair", "rotation": seat.get("rotation", Vector3.ZERO), "clearance": 0.04, "tableId": "table"})
			if chair == null:
				rejected = true
				break
			chair_parts.append(chair)
		if rejected:
			plan.parts.erase(table)
			for chair in chair_parts:
				plan.parts.erase(chair)
			continue
		occupied.append(table_bounds)
		for seat_index in range(seats.size()):
			var seat: Dictionary = seats[seat_index] as Dictionary
			occupied.append(seat.get("bounds", AABB()) as AABB)
		return {"table": table, "chairs": chair_parts}
	return {}


static func place_catalogued_random(plan, occupied: Array[AABB], room: Dictionary, part_id: String, catalog_id: String, rng: RandomNumberGenerator, attempts := 10, options: Dictionary = {}):
	# Generic room-aware selector for future cottages, manors, inns and civic
	# buildings. The catalogue only describes furniture; this helper still owns
	# room bounds, access reservations and connected-floor validation.
	var definition := FurnishingArchetypeCatalogScript.definition(catalog_id)
	if definition.is_empty():
		return null
	var size: Vector3 = definition.get("size", Vector3.ONE) as Vector3
	var placement_options := definition.duplicate(true)
	placement_options.merge(options, true)
	for _attempt in range(maxi(1, attempts)):
		var position := random_room_position(room, size, rng, 0.18)
		var part = place_at(plan, occupied, part_id, String(room.get("id", "")), String(definition.get("archetype", catalog_id)), String(definition.get("material", "timber_board")), position, size, placement_options, room)
		if part != null:
			return part
	return null


static func place_catalogued_in_zones(plan, occupied: Array[AABB], room: Dictionary, part_id: String, catalog_id: String, normalized_zones: Array, rng: RandomNumberGenerator, jitter := Vector2(0.08, 0.08), options: Dictionary = {}):
	# Larger rooms should read inhabited across their useful floor area, not as a
	# random pile near one successful central candidate. Zones are room-relative
	# and shuffled/jittered per seed, so this remains a reusable grammar rule.
	var definition := FurnishingArchetypeCatalogScript.definition(catalog_id)
	if definition.is_empty():
		return null
	var size: Vector3 = definition.get("size", Vector3.ONE) as Vector3
	var placement_options := definition.duplicate(true)
	placement_options.merge(options, true)
	var remaining: Array = normalized_zones.duplicate()
	while not remaining.is_empty():
		var index := rng.randi_range(0, remaining.size() - 1)
		var zone = remaining[index]
		remaining.remove_at(index)
		if not zone is Vector2:
			continue
		var normalized: Vector2 = zone as Vector2
		var bounds: AABB = room.get("bounds", AABB()) as AABB
		var position := Vector3(
			bounds.position.x + bounds.size.x * clampf(normalized.x + rng.randf_range(-jitter.x, jitter.x), 0.0, 1.0),
			FLOOR_Y,
			bounds.position.z + bounds.size.z * clampf(normalized.y + rng.randf_range(-jitter.y, jitter.y), 0.0, 1.0)
		)
		# Normalized anchors are intentionally only a preference. The existing
		# shared placement authority rejects any candidate outside the room,
		# inside a protected lane, or disconnecting the walkable floor.
		var candidate := InteriorFurnishingLayoutScript.horizontal_bounds(position, size, placement_options.get("rotation", Vector3.ZERO) as Vector3, float(placement_options.get("clearance", 0.0)))
		if not candidate_is_inside_room(candidate, room):
			continue
		var part = place_at(plan, occupied, part_id, String(room.get("id", "")), String(definition.get("archetype", catalog_id)), String(definition.get("material", "timber_board")), position, size, placement_options, room)
		if part != null:
			return part
	return null


static func place_catalogued_on_surface(plan, support, part_id: String, catalog_id: String, local_offset := Vector3.ZERO, options: Dictionary = {}):
	# A raised lectern, altar, display, or future throne must derive from its
	# actual support record. The floor placement planner deliberately cannot do
	# this: its horizontal occupancy rules are correct for circulation but would
	# treat a legitimate vertical composition as an overlap. This helper keeps
	# one furnishing plan authoritative while recording the supporting surface.
	if support == null or not bool(support.collision_enabled):
		return null
	var definition := FurnishingArchetypeCatalogScript.definition(catalog_id)
	if definition.is_empty():
		return null
	var size: Vector3 = definition.get("size", Vector3.ONE) as Vector3
	var placement_options := definition.duplicate(true)
	placement_options.merge(options, true)
	var rotation: Vector3 = placement_options.get("rotation", support.rotation) as Vector3
	var local: Vector3 = local_offset.rotated(Vector3.UP, support.rotation.y)
	var position: Vector3 = support.position + local + Vector3(0.0, support.occupied_size.y, 0.0)
	var support_bounds: AABB = InteriorFurnishingLayoutScript.horizontal_bounds(support.position, support.occupied_size, support.rotation)
	var candidate_bounds: AABB = InteriorFurnishingLayoutScript.horizontal_bounds(position, size, rotation)
	if candidate_bounds.position.x < support_bounds.position.x or candidate_bounds.end.x > support_bounds.end.x or candidate_bounds.position.z < support_bounds.position.z or candidate_bounds.end.z > support_bounds.end.z:
		return null
	placement_options["supportedBy"] = String(support.id)
	placement_options["supportSurface"] = String(support.archetype)
	placement_options["surfaceBaseY"] = position.y
	placement_options["rotation"] = rotation
	return add_part(plan, part_id, String(support.room_id), String(definition.get("archetype", catalog_id)), String(definition.get("material", "timber_board")), position, size, placement_options)


static func place_catalogued_against_walls(plan, occupied: Array[AABB], room: Dictionary, part_id: String, catalog_id: String, wall_ids: Array, rng: RandomNumberGenerator, options: Dictionary = {}):
	var definition := FurnishingArchetypeCatalogScript.definition(catalog_id)
	if definition.is_empty():
		return null
	var placement_options := definition.duplicate(true)
	placement_options.merge(options, true)
	return place_against_random_walls(plan, occupied, room, part_id, String(definition.get("archetype", catalog_id)), String(definition.get("material", "timber_board")), wall_ids, rng, definition.get("size", Vector3.ONE) as Vector3, placement_options)


static func place_catalogued_wall_sconce(plan, room: Dictionary, part_id: String, wall_id: String, along: float):
	var definition := FurnishingArchetypeCatalogScript.definition("wall_sconce")
	if definition.is_empty():
		return null
	var size: Vector3 = definition.get("size", Vector3.ONE) as Vector3
	var rotation := InteriorFurnishingLayoutScript.wall_facing_rotation(wall_id)
	var position := InteriorFurnishingLayoutScript.wall_mount_position(room, wall_id, along, size)
	if not InteriorFurnishingLayoutScript.wall_mount_is_clear(plan.parts, wall_id, position, rotation, size, float(definition.get("mountHeight", 2.12))):
		return null
	return add_part(plan, part_id, String(room.get("id", "")), String(definition.get("archetype", "wall_sconce")), String(definition.get("material", "brass")), position, size, {
		"collision": false,
		"semantic": String(definition.get("semantic", "wall_light")),
		"supportingWall": wall_id,
		"mountHeight": float(definition.get("mountHeight", 2.12)),
		"mountMode": "back_face_on_wall",
		"rotation": rotation
	})


static func place_catalogued_wall_banner(plan, room: Dictionary, part_id: String, wall_id: String, along: float, material_override := ""):
	# The caller names a wall that the blueprint knows is solid at the selected
	# span. This generic helper is then usable by manor/castle grammars without
	# treating a banner as collision or as an alternative wall authority.
	var definition := FurnishingArchetypeCatalogScript.definition("wall_banner")
	if definition.is_empty():
		return null
	var size: Vector3 = definition.get("size", Vector3.ONE) as Vector3
	var rotation := InteriorFurnishingLayoutScript.wall_facing_rotation(wall_id)
	var position := InteriorFurnishingLayoutScript.wall_mount_position(room, wall_id, along, size)
	var mount_height := float(definition.get("mountHeight", 2.54))
	if not InteriorFurnishingLayoutScript.wall_mount_is_clear(plan.parts, wall_id, position, rotation, size, mount_height):
		return null
	var material := material_override.strip_edges().to_lower()
	if material.is_empty():
		material = String(definition.get("material", "wool_rust"))
	return add_part(plan, part_id, String(room.get("id", "")), String(definition.get("archetype", "wall_banner")), material, position, size, {
		"collision": false,
		"semantic": String(definition.get("semantic", "heraldic_wall_banner")),
		"supportingWall": wall_id,
		"mountHeight": mount_height,
		"mountMode": "back_face_on_wall",
		"rotation": rotation
	})


static func random_room_position(room: Dictionary, size: Vector3, rng: RandomNumberGenerator, padding := 0.10) -> Vector3:
	var bounds: AABB = room.get("bounds", AABB()) as AABB
	var min_x := bounds.position.x + size.x * 0.5 + padding
	var max_x := bounds.end.x - size.x * 0.5 - padding
	var min_z := bounds.position.z + size.z * 0.5 + padding
	var max_z := bounds.end.z - size.z * 0.5 - padding
	return Vector3(
		rng.randf_range(min_x, max_x) if max_x >= min_x else bounds.get_center().x,
		FLOOR_Y,
		rng.randf_range(min_z, max_z) if max_z >= min_z else bounds.get_center().z
	)


static func candidate_is_inside_room(candidate: AABB, room: Dictionary, margin := 0.04) -> bool:
	var bounds: AABB = room.get("bounds", AABB()) as AABB
	return candidate.position.x >= bounds.position.x + margin and candidate.end.x <= bounds.end.x - margin and candidate.position.z >= bounds.position.z + margin and candidate.end.z <= bounds.end.z - margin


static func candidate_bounds_keep_room_walkable(plan, room: Dictionary, candidates: Array[AABB]) -> bool:
	var room_id := String(room.get("id", ""))
	var blocked: Array[AABB] = []
	for part in plan.parts:
		if part != null and part.collision_enabled and String(part.room_id) == room_id:
			blocked.append(InteriorFurnishingLayoutScript.horizontal_bounds(part.position, part.occupied_size, part.rotation, NPC_EGRESS_CLEARANCE))
	blocked.append_array(candidates)
	var walkability: Dictionary = InteriorFurnishingLayoutScript.room_walkability_for_blocked_bounds(room, blocked, NPC_EGRESS_CLEARANCE)
	return int(walkability.get("accessSeedCells", 0)) > 0 and int(walkability.get("accessComponentCount", 0)) == 1 and int(walkability.get("unreachableCells", 0)) == 0


static func rooms_by_id(room_records: Array) -> Dictionary:
	var result := {}
	for raw_room in room_records:
		if not raw_room is Dictionary:
			continue
		var room := raw_room as Dictionary
		var room_id := String(room.get("id", "")).strip_edges()
		var bounds: AABB = room.get("bounds", AABB()) as AABB
		if not room_id.is_empty() and bounds.size.x > 0.0 and bounds.size.z > 0.0:
			result[room_id] = {
				"id": room_id,
				"bounds": bounds,
				"wallMountInset": float(room.get("wallMountInset", 0.12)),
				"accesses": (room.get("accesses", []) as Array).duplicate(true)
			}
	return result


static func place(plan, occupied: Array[AABB], room: Dictionary, part_id: String, archetype: String, material: String, normalized: Vector2, size: Vector3, options: Dictionary = {}):
	var bounds: AABB = room.get("bounds", AABB()) as AABB
	var position := Vector3(
		bounds.position.x + bounds.size.x * normalized.x,
		FLOOR_Y,
		bounds.position.z + bounds.size.z * normalized.y
	)
	return place_at(plan, occupied, part_id, String(room.get("id", "")), archetype, material, position, size, options, room)


static func place_against_wall(plan, occupied: Array[AABB], room: Dictionary, part_id: String, archetype: String, material: String, wall_id: String, along: float, size: Vector3, options: Dictionary = {}):
	var placement_options := options.duplicate(true)
	placement_options["rotation"] = InteriorFurnishingLayoutScript.wall_facing_rotation(wall_id)
	placement_options["supportingWall"] = wall_id.strip_edges().to_lower()
	var position := InteriorFurnishingLayoutScript.position_against_wall(room, wall_id, along, size)
	return place_at(plan, occupied, part_id, String(room.get("id", "")), archetype, material, position, size, placement_options, room)


static func place_at(plan, occupied: Array[AABB], part_id: String, room_id: String, archetype: String, material: String, position: Vector3, size: Vector3, options: Dictionary = {}, room: Dictionary = {}):
	var clearance := float(options.get("clearance", 0.0))
	var rotation: Vector3 = options.get("rotation", Vector3.ZERO) as Vector3
	var candidate := InteriorFurnishingLayoutScript.horizontal_bounds(position, size, rotation, clearance)
	var interaction_depth := float(options.get("interactionClearance", 0.0))
	var interaction := InteriorFurnishingLayoutScript.interaction_bounds(position, size, rotation, interaction_depth) if interaction_depth > 0.0 else AABB()
	if bool(options.get("reserve", true)):
		if InteriorFurnishingLayoutScript.intersects_any(candidate, occupied):
			return null
		if interaction_depth > 0.0 and InteriorFurnishingLayoutScript.intersects_any(interaction, occupied):
			return null
	var part = add_part(plan, part_id, room_id, archetype, material, position, size, options)
	if part == null:
		return null
	if bool(options.get("collision", true)) and not room.is_empty() and not plan_room_is_walkable(plan, room):
		plan.parts.erase(part)
		return null
	if bool(options.get("reserve", true)):
		occupied.append(candidate)
		if interaction_depth > 0.0:
			occupied.append(interaction)
	return part


static func place_wall_art(plan, room: Dictionary, part_id: String, material: String, wall_id: String, along: float, size: Vector3, mount_height: float):
	var rotation := InteriorFurnishingLayoutScript.wall_facing_rotation(wall_id)
	var position := InteriorFurnishingLayoutScript.wall_mount_position(room, wall_id, along, size)
	if not InteriorFurnishingLayoutScript.wall_mount_is_clear(plan.parts, wall_id, position, rotation, size, mount_height):
		return null
	return add_part(plan, part_id, String(room.get("id", "")), "wall_art", material, position, size, {
		"collision": false,
		"semantic": "wall_decor",
		"supportingWall": wall_id,
		"mountHeight": mount_height,
		"mountMode": "back_face_on_wall",
		"rotation": rotation
	})


static func add_candle_on_surface(plan, part_id: String, surface, local_offset: Vector3):
	if surface == null or String(surface.archetype) in ["bed", "rug", "wall_art"]:
		return null
	var position: Vector3 = surface.position + local_offset
	return add_part(plan, part_id, String(surface.room_id), "candle", "candle_wax", position, Vector3(0.15, 0.30, 0.15), {"collision": false, "semantic": "candle", "mount": String(surface.id), "mountSurface": String(surface.archetype)})


static func add_rug_under_surface(plan, part_id: String, surface, padding := Vector2(1.12, 1.12), material := "wool_rust", semantic := "woven_rug"):
	if surface == null or not surface.has_method("snapshot"):
		return null
	var size := Vector3(surface.occupied_size.x * padding.x, 0.035, surface.occupied_size.z * padding.y)
	return add_part(plan, part_id, String(surface.room_id), "rug", material, surface.position, size, {
		"collision": false,
		"reserve": false,
		"semantic": semantic,
		"mount": String(surface.id),
		"mountSurface": String(surface.archetype)
	})


static func plan_room_is_walkable(plan, room: Dictionary) -> bool:
	var room_id := String(room.get("id", ""))
	var solid_parts: Array = []
	for part in plan.parts:
		if part != null and part.collision_enabled and String(part.room_id) == room_id:
			solid_parts.append(part)
	var walkability: Dictionary = InteriorFurnishingLayoutScript.room_walkability(room, solid_parts, NPC_EGRESS_CLEARANCE)
	return int(walkability.get("accessSeedCells", 0)) > 0 and int(walkability.get("accessComponentCount", 0)) == 1 and int(walkability.get("unreachableCells", 0)) == 0


static func add_part(plan, part_id: String, room_id: String, archetype: String, material: String, position: Vector3, size: Vector3, options: Dictionary = {}):
	return plan.add_part({
		"id": part_id,
		"roomId": room_id,
		"archetype": archetype,
		"material": material,
		"position": position,
		"rotation": options.get("rotation", Vector3.ZERO),
		"occupiedSize": size,
		"collision": bool(options.get("collision", true)),
		"semantic": String(options.get("semantic", archetype)),
		"recipe": options.duplicate(true)
	})
