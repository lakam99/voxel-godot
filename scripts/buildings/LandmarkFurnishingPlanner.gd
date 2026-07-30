extends RefCounted
class_name LandmarkFurnishingPlanner

## Role-aware furnishing for landmark blueprints. It deliberately reuses the
## existing furnishing records and collision-aware placement helpers instead
## of creating a separate civic-interior publication path.

const FurnishingPlanScript := preload("res://scripts/buildings/FurnishingPlan.gd")
const CottageFurnishingPlannerScript := preload("res://scripts/buildings/CottageFurnishingPlanner.gd")
const InteriorFurnishingLayoutScript := preload("res://scripts/buildings/InteriorFurnishingLayout.gd")


static func build(blueprint, furnishing_seed: int):
	var blueprint_id := String(blueprint.id) if blueprint != null else "missing-blueprint"
	var plan = FurnishingPlanScript.new("furnishing.%s.%d" % [blueprint_id, furnishing_seed], furnishing_seed, blueprint_id)
	if blueprint == null:
		return plan
	plan.set_protected_access_reservations(InteriorFurnishingLayoutScript.access_reservations(blueprint.rooms))
	var rooms := rooms_by_role(blueprint.rooms)
	var public_hall: Dictionary = rooms.get("public_hall", {}) as Dictionary
	var archive: Dictionary = rooms.get("notice_archive", {}) as Dictionary
	var office: Dictionary = rooms.get("steward_office", {}) as Dictionary
	var civic_store: Dictionary = rooms.get("civic_store", {}) as Dictionary
	if public_hall.is_empty() or archive.is_empty():
		return plan
	var rng := RandomNumberGenerator.new()
	rng.seed = furnishing_seed
	var occupied: Array[AABB] = InteriorFurnishingLayoutScript.access_reservations(blueprint.rooms)

	# A public hall is a speaker-and-audience room, not a council dining room.
	# The dais must be placed first because the lectern's height and footprint
	# are derived from that physical support. Audience benches then face the
	# stage from the open central hall, preserving the entry-to-stage aisle.
	var civic_dais = CottageFurnishingPlannerScript.place_catalogued_in_zones(plan, occupied, public_hall, "civic_dais", "dais", [Vector2(0.50, 0.66)], rng, Vector2(0.025, 0.025))
	if civic_dais != null:
		# The audience sees the speaker's back of podium. The reading plane faces
		# inward toward the stage so the paper is not presented to the benches.
		CottageFurnishingPlannerScript.place_catalogued_on_surface(plan, civic_dais, "civic_lectern", "lectern", Vector3(0.0, 0.0, -0.22), {"rotation": civic_dais.rotation + Vector3(0.0, PI, 0.0), "semantic": "civic_lectern"})
	# Window-bearing exterior walls are intentionally excluded. The blueprint
	# declares usable room space; the furnishing grammar must respect apertures
	# rather than hiding them with a hearth or storage.
	CottageFurnishingPlannerScript.place_against_random_walls(plan, occupied, public_hall, "public_hearth", "hearth", "fired_brick", ["back"], rng, Vector3(1.68, 1.88, 0.64), {"semantic": "public_hearth", "clearance": 0.12})
	CottageFurnishingPlannerScript.place_against_random_walls(plan, occupied, public_hall, "notice_cabinet", "cabinet", "timber_beam", ["back"], rng, Vector3(1.16, 1.46, 0.46), {"semantic": "public_notice_storage", "clearance": 0.10, "interactionClearance": 0.92})
	# These use the shared catalogue rather than Town-Hall-only geometry. The
	# paired bench zones form a legible audience while leaving a central aisle
	# and all declared doorway/passage approach lanes clear.
	CottageFurnishingPlannerScript.place_catalogued_in_zones(plan, occupied, public_hall, "audience_bench_front_left", "bench", [Vector2(0.28, 0.50)], rng, Vector2(0.035, 0.035))
	CottageFurnishingPlannerScript.place_catalogued_in_zones(plan, occupied, public_hall, "audience_bench_front_right", "bench", [Vector2(0.72, 0.50)], rng, Vector2(0.035, 0.035))
	CottageFurnishingPlannerScript.place_catalogued_in_zones(plan, occupied, public_hall, "audience_bench_rear_left", "bench", [Vector2(0.28, 0.34)], rng, Vector2(0.035, 0.035))
	CottageFurnishingPlannerScript.place_catalogued_in_zones(plan, occupied, public_hall, "audience_bench_rear_right", "bench", [Vector2(0.72, 0.34)], rng, Vector2(0.035, 0.035))
	CottageFurnishingPlannerScript.place_catalogued_random(plan, occupied, public_hall, "public_planter", "planter", rng, 18)
	CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, public_hall, "public_sideboard", "sideboard", ["back"], rng)
	CottageFurnishingPlannerScript.place_catalogued_in_zones(plan, occupied, public_hall, "civic_display", "display_plinth", [Vector2(0.16, 0.46), Vector2(0.84, 0.46)], rng)
	CottageFurnishingPlannerScript.place_catalogued_in_zones(plan, occupied, public_hall, "civic_aisle_runner", "aisle_runner", [Vector2(0.50, 0.34), Vector2(0.50, 0.48)], rng, Vector2(0.04, 0.06))
	CottageFurnishingPlannerScript.place_catalogued_in_zones(plan, occupied, public_hall, "entry_coat_rack", "coat_rack", [Vector2(0.12, 0.26), Vector2(0.88, 0.26)], rng)
	# The public side walls are solid behind this rearward span; the front wall
	# is intentionally not eligible because it contains the civic door/windows.
	CottageFurnishingPlannerScript.place_catalogued_wall_banner(plan, public_hall, "public_banner_left", "left", 0.78, "wool_moss")
	CottageFurnishingPlannerScript.place_catalogued_wall_banner(plan, public_hall, "public_banner_right", "right", 0.78, "wool_rust")

	# The archive exists in every footprint. Shelves/cabinets reserve an
	# interaction face, while the optional office below receives a desk only
	# when the shared walking-grid predicate preserves its declared passage.
	# The archive keeps its left wall available for heraldry and fills its
	# remaining perimeter with capacity-aware record storage.
	var archive_shelf_a = CottageFurnishingPlannerScript.place_against_random_walls(plan, occupied, archive, "archive_shelf_a", "shelf", "timber_beam", ["right"], rng, Vector3(1.16, 1.82, 0.42), {"semantic": "archive_shelf", "clearance": 0.08})
	CottageFurnishingPlannerScript.place_against_random_walls(plan, occupied, archive, "archive_shelf_b", "shelf", "timber_beam", ["right"], rng, Vector3(0.82, 1.72, 0.40), {"semantic": "archive_shelf", "clearance": 0.08})
	if archive_shelf_a != null:
		CottageFurnishingPlannerScript.add_candle_on_surface(plan, "archive_shelf_candle", archive_shelf_a, Vector3(0.12, archive_shelf_a.occupied_size.y + 0.04, -0.04))
	CottageFurnishingPlannerScript.place_against_random_walls(plan, occupied, archive, "archive_chest", "chest", "timber_board", ["right"], rng, Vector3(0.96, 0.70, 0.58), {"semantic": "archive_storage", "clearance": 0.08, "interactionClearance": 0.82})
	CottageFurnishingPlannerScript.place_catalogued_random(plan, occupied, archive, "archive_map_table", "map_table", rng, 16)
	CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, archive, "archive_crates", "crate_stack", ["right"], rng)
	CottageFurnishingPlannerScript.place_catalogued_random(plan, occupied, archive, "archive_planter", "planter", rng, 12)
	CottageFurnishingPlannerScript.place_catalogued_in_zones(plan, occupied, archive, "archive_workbench", "workbench", [Vector2(0.42, 0.66), Vector2(0.58, 0.42)], rng)
	CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, archive, "archive_barrels", "barrel_stack", ["right"], rng)
	# Archive capacity scales with the actual room footprint. These wall-bound
	# stacks turn spare perimeter into usable records/storage space without
	# consuming the passage approach or inventing a room-specific visual path.
	CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, archive, "archive_record_crates", "crate_stack", ["left", "right"], rng)
	CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, archive, "archive_record_barrels", "barrel_stack", ["left", "right"], rng)
	# The archive/office divider is a complete wall with no doorway. It is an
	# eligible visible support for civic decor, unlike the public hall's rear
	# divider which contains the two actual passage openings.
	CottageFurnishingPlannerScript.place_wall_art(plan, archive, "civic_notice_board", "painted_decor", "right", rng.randf_range(0.18, 0.82), Vector3(1.28, 0.82, 0.08), 2.72)
	CottageFurnishingPlannerScript.place_catalogued_wall_sconce(plan, archive, "archive_sconce", "right", rng.randf_range(0.16, 0.84))
	CottageFurnishingPlannerScript.place_catalogued_wall_banner(plan, archive, "archive_banner", "left", 0.72, "wool_moss")

	if not office.is_empty():
		var office_desk: Variant = place_office_desk(plan, occupied, office, rng)
		if office_desk != null and rng.randf() < 0.92:
			CottageFurnishingPlannerScript.add_candle_on_surface(plan, "office_candle", office_desk, Vector3(rng.randf_range(-0.18, 0.18), 0.86, rng.randf_range(-0.12, 0.12)))
		CottageFurnishingPlannerScript.place_wall_art(plan, office, "office_chart", "painted_decor", "back", rng.randf_range(0.18, 0.82), Vector3(1.08, 0.70, 0.08), 2.48)
		# The desk keeps its documented approach lane while the remainder of the
		# office perimeter becomes legitimate supply storage.
		CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, office, "office_sideboard", "sideboard", ["right"], rng)
		CottageFurnishingPlannerScript.place_against_random_walls(plan, occupied, office, "office_supply_cabinet", "cabinet", "timber_beam", ["right", "back"], rng, Vector3(0.84, 1.42, 0.44), {"semantic": "office_supply_storage", "clearance": 0.08, "interactionClearance": 0.78})
		CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, office, "office_supply_crates", "crate_stack", ["right", "back"], rng)
		CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, office, "office_supply_barrels", "barrel_stack", ["right", "back"], rng)
		CottageFurnishingPlannerScript.place_catalogued_random(plan, occupied, office, "office_planter", "planter", rng, 12)
		CottageFurnishingPlannerScript.place_catalogued_wall_sconce(plan, office, "office_sconce", "back", rng.randf_range(0.16, 0.84))
		CottageFurnishingPlannerScript.place_catalogued_wall_banner(plan, office, "office_banner", "left", 0.70, "wool_rust")

	if not civic_store.is_empty():
		# Wide/deep Town Halls earn a dedicated stockroom. All pieces remain
		# ordinary catalogued furniture, allowing the same grammar in future
		# manors and castles rather than creating a special storage scene.
		# Back-wall shelving leaves both side lanes free for bulky stock and keeps
		# the front passage approach open from the public hall.
		CottageFurnishingPlannerScript.place_against_random_walls(plan, occupied, civic_store, "store_shelf_a", "shelf", "timber_beam", ["back"], rng, Vector3(1.16, 1.82, 0.42), {"semantic": "civic_store_shelf", "clearance": 0.08})
		CottageFurnishingPlannerScript.place_against_random_walls(plan, occupied, civic_store, "store_shelf_b", "shelf", "timber_beam", ["back"], rng, Vector3(0.88, 1.72, 0.40), {"semantic": "civic_store_shelf", "clearance": 0.08})
		CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, civic_store, "store_crates_a", "crate_stack", ["left", "right", "back"], rng)
		CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, civic_store, "store_crates_b", "crate_stack", ["left", "right", "back"], rng)
		CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, civic_store, "store_barrels", "barrel_stack", ["left", "right", "back"], rng)
		CottageFurnishingPlannerScript.place_against_random_walls(plan, occupied, civic_store, "store_chest", "chest", "timber_board", ["left", "right", "back"], rng, Vector3(0.96, 0.70, 0.58), {"semantic": "civic_store_chest", "clearance": 0.08, "interactionClearance": 0.82})
		CottageFurnishingPlannerScript.place_catalogued_in_zones(plan, occupied, civic_store, "store_floor_crates_left", "crate_stack", [Vector2(0.20, 0.60), Vector2(0.24, 0.76)], rng, Vector2(0.025, 0.035))
		CottageFurnishingPlannerScript.place_catalogued_in_zones(plan, occupied, civic_store, "store_floor_crates_right", "crate_stack", [Vector2(0.80, 0.60), Vector2(0.76, 0.76)], rng, Vector2(0.025, 0.035))
		CottageFurnishingPlannerScript.place_catalogued_in_zones(plan, occupied, civic_store, "store_floor_barrels_left", "barrel_stack", [Vector2(0.20, 0.82), Vector2(0.28, 0.66)], rng, Vector2(0.025, 0.030))
		CottageFurnishingPlannerScript.place_catalogued_in_zones(plan, occupied, civic_store, "store_floor_barrels_right", "barrel_stack", [Vector2(0.80, 0.82), Vector2(0.72, 0.66)], rng, Vector2(0.025, 0.030))
	return plan


static func rooms_by_role(room_records: Array) -> Dictionary:
	var result := {}
	for raw_room in room_records:
		if not raw_room is Dictionary:
			continue
		var room := raw_room as Dictionary
		var role := String(room.get("role", "")).strip_edges().to_lower()
		var bounds: AABB = room.get("bounds", AABB()) as AABB
		if role.is_empty() or bounds.size.x <= 0.0 or bounds.size.z <= 0.0:
			continue
		var projected := room.duplicate(true)
		projected["id"] = String(room.get("id", role))
		projected["bounds"] = bounds
		projected["wallMountInset"] = float(room.get("wallMountInset", 0.12))
		projected["accesses"] = (room.get("accesses", []) as Array).duplicate(true)
		result[role] = projected
	return result


static func place_office_desk(plan, occupied: Array[AABB], room: Dictionary, rng: RandomNumberGenerator):
	var desk_size := Vector3(1.56, 0.84, 1.06)
	var chair_size := Vector3(0.56, 0.92, 0.58)
	# A desk belongs on the office's solid rear wall, with its chair facing into
	# the room. This keeps the entire forward circulation band open from the
	# office passage instead of hoping a random centre placement leaves it so.
	for along in [rng.randf_range(0.62, 0.80), rng.randf_range(0.20, 0.38), 0.50]:
		var desk_position := InteriorFurnishingLayoutScript.position_against_wall(room, "back", float(along), desk_size)
		var desk_bounds := InteriorFurnishingLayoutScript.horizontal_bounds(desk_position, desk_size, Vector3.ZERO, 0.10)
		if InteriorFurnishingLayoutScript.intersects_any(desk_bounds, occupied):
			continue
		var chair_position := desk_position + Vector3(0.0, 0.0, -(desk_size.z * 0.5 + chair_size.z * 0.5 + 0.18))
		var chair_rotation := Vector3(0.0, PI, 0.0)
		var chair_bounds := InteriorFurnishingLayoutScript.horizontal_bounds(chair_position, chair_size, chair_rotation, 0.08)
		if not CottageFurnishingPlannerScript.candidate_is_inside_room(chair_bounds, room) or InteriorFurnishingLayoutScript.intersects_any(chair_bounds, occupied):
			continue
		if not CottageFurnishingPlannerScript.candidate_bounds_keep_room_walkable(plan, room, [desk_bounds, chair_bounds]):
			continue
		var desk = CottageFurnishingPlannerScript.add_part(plan, "steward_desk", String(room.get("id", "")), "table", "timber_board", desk_position, desk_size, {"semantic": "steward_desk", "clearance": 0.10, "supportingWall": "back"})
		CottageFurnishingPlannerScript.add_part(plan, "steward_chair", String(room.get("id", "")), "chair", "timber_board", chair_position, chair_size, {"semantic": "steward_chair", "rotation": chair_rotation, "clearance": 0.08, "tableId": "steward_desk"})
		occupied.append(desk_bounds)
		occupied.append(chair_bounds)
		return desk
	return null
