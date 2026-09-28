extends RefCounted
class_name CastleFurnishingPlanner

## Composes the same seeded residential furnishing grammars used by the small
## building PoCs into the castle's already-composed courtyard residences.  A
## castle owns only the placement transform and the namespace; cottages and
## manors remain responsible for deciding what a home contains.

const FurnishingPlanScript := preload("res://scripts/buildings/FurnishingPlan.gd")
const CottageBlueprintBuilderScript := preload("res://scripts/buildings/CottageBlueprintBuilder.gd")
const LandmarkBuildingBlueprintBuilderScript := preload("res://scripts/buildings/LandmarkBuildingBlueprintBuilder.gd")
const CottageFurnishingPlannerScript := preload("res://scripts/buildings/CottageFurnishingPlanner.gd")
const InteriorFurnishingLayoutScript := preload("res://scripts/buildings/InteriorFurnishingLayout.gd")
const CitadelResidenceManifestBuilderScript := preload("res://scripts/buildings/CitadelResidenceManifestBuilder.gd")
const BuildingNavigationManifestBuilderScript := preload("res://scripts/buildings/BuildingNavigationManifestBuilder.gd")
const BuildingInteriorProgramScript := preload("res://scripts/buildings/BuildingInteriorProgram.gd")
const CitadelUrbanHomeFurnishingPlannerScript := preload("res://scripts/buildings/CitadelUrbanHomeFurnishingPlanner.gd")


static func build(castle_blueprint, furnishing_seed: int, world_origin := Vector3.ZERO):
	var blueprint_id := String(castle_blueprint.id) if castle_blueprint != null else "missing-castle-blueprint"
	var plan = FurnishingPlanScript.new("furnishing.%s.%d" % [blueprint_id, furnishing_seed], furnishing_seed, blueprint_id)
	if castle_blueprint == null:
		return plan
	var residences: Array = castle_blueprint.recipe.get("courtyardResidences", []) as Array
	var castle_foundation_height := float(castle_blueprint.recipe.get("foundationHeight", 0.62))
	for residence_value in residences:
		if not residence_value is Dictionary:
			continue
		var residence: Dictionary = residence_value as Dictionary
		append_residence_furnishings(plan, residence, castle_foundation_height, furnishing_seed)
	var urban_home_plan = CitadelUrbanHomeFurnishingPlannerScript.build(castle_blueprint, furnishing_seed)
	if urban_home_plan == null:
		return null
	plan.add_protected_access_reservations(urban_home_plan.access_reservations_snapshot())
	for urban_part in urban_home_plan.parts:
		if urban_part == null or plan.add_part(urban_part.snapshot()) == null:
			return null
	var egress_result := rebuild_furniture_blocked_egress(plan, castle_blueprint, residences, castle_foundation_height, furnishing_seed, world_origin)
	if not bool(egress_result.get("complete", false)):
		return null
	BuildingInteriorProgramScript.apply_to_plan(castle_blueprint, plan)
	return plan


static func summary(plan, expected_residence_count := -1) -> Dictionary:
	var family_counts := {}
	var family_part_counts := {}
	var residence_families := {}
	var residence_part_counts := {}
	var collision_count := 0
	if plan == null:
		return {
			"residenceCount": 0,
			"expectedResidenceCount": expected_residence_count,
			"furnishingPartCount": 0,
			"collisionPartCount": 0,
			"familyCounts": family_counts,
			"familyPartCounts": family_part_counts,
			"residencePartCounts": residence_part_counts,
			"allResidencesFurnished": false
		}
	for part in plan.parts:
		if part == null:
			continue
		var family := String(part.recipe.get("castleResidenceFamily", "")).strip_edges().to_lower()
		var residence_id := String(part.recipe.get("castleResidenceId", "")).strip_edges()
		if not family.is_empty():
			family_part_counts[family] = int(family_part_counts.get(family, 0)) + 1
		if not residence_id.is_empty():
			residence_part_counts[residence_id] = int(residence_part_counts.get(residence_id, 0)) + 1
			if not family.is_empty():
				residence_families[residence_id] = family
		if part.collision_enabled:
			collision_count += 1
	for family_value in residence_families.values():
		var family := String(family_value)
		family_counts[family] = int(family_counts.get(family, 0)) + 1
	return {
		"residenceCount": residence_part_counts.size(),
		"expectedResidenceCount": expected_residence_count,
		"furnishingPartCount": plan.parts.size(),
		"collisionPartCount": collision_count,
		"familyCounts": family_counts,
		"familyPartCounts": family_part_counts,
		"residencePartCounts": residence_part_counts,
		"allResidencesFurnished": not residence_part_counts.is_empty() and (expected_residence_count < 0 or residence_part_counts.size() == expected_residence_count)
	}


static func append_residence_furnishings(target_plan, residence: Dictionary, castle_foundation_height: float, furnishing_seed: int, furnishing_options: Dictionary = {}) -> void:
	var residence_id := String(residence.get("id", "")).strip_edges()
	if residence_id.is_empty():
		return
	var family := String(residence.get("residenceFamily", residence.get("family", "cottage"))).strip_edges().to_lower()
	if family not in ["cottage", "manor"]:
		return
	var residence_recipe: Dictionary = residence.get("residenceRecipe", residence.get("recipe", {})) as Dictionary
	if residence_recipe.is_empty():
		return
	var source_blueprint = source_blueprint_for(family, residence_recipe)
	if source_blueprint == null:
		return
	var residence_seed := stable_residence_furnishing_seed(furnishing_seed, residence_id, family)
	var egress_candidate := int(furnishing_options.get("egressCandidate", 0))
	if egress_candidate > 0:
		residence_seed = int(("%d|egress-candidate|%d" % [residence_seed, egress_candidate]).hash())
	var source_plan = CottageFurnishingPlannerScript.build(source_blueprint, residence_seed, furnishing_options) if family == "cottage" else build_manor_residence_plan(source_blueprint, residence_seed, furnishing_options)
	if source_plan == null or source_plan.parts.is_empty():
		return
	var local_foundation_height := float(source_blueprint.recipe.get("foundationHeight", 0.48))
	var center: Vector3 = residence.get("center", Vector3.ZERO) as Vector3
	var yaw := float(residence.get("yaw", PI * 0.5 if center.x > 0.0 else -PI * 0.5))
	var origin: Vector3 = residence.get("origin", Vector3(center.x, castle_foundation_height - local_foundation_height, center.z)) as Vector3
	var egress_profile := "essential" if bool(furnishing_options.get("egressSafe", false)) else "full"
	append_transformed_plan(target_plan, source_plan, residence_id, family, origin, yaw, egress_profile)


static func source_blueprint_for(family: String, recipe: Dictionary):
	match family:
		"manor":
			return LandmarkBuildingBlueprintBuilderScript.build_from_recipe(recipe)
		_:
			return CottageBlueprintBuilderScript.build_from_recipe(recipe)


static func stable_residence_furnishing_seed(base_seed: int, residence_id: String, family: String) -> int:
	return int(("%d|castle.residence.furnishing|%s|%s" % [base_seed, residence_id, family]).hash())


static func append_transformed_plan(target_plan, source_plan, residence_id: String, family: String, origin: Vector3, yaw: float, egress_profile := "full") -> void:
	var yaw_basis := Basis(Vector3.UP, yaw)
	# Synthetic manor accesses are created by the same source furnishing grammar,
	# so preserve them when that grammar is composed into the castle. This avoids
	# a second, castle-specific interpretation of a doorway clearance.
	var transformed_accesses: Array[AABB] = []
	for source_access in source_plan.access_reservations_snapshot():
		transformed_accesses.append(transform_access_reservation(source_access, origin, yaw_basis))
	target_plan.add_protected_access_reservations(transformed_accesses)
	var id_map := {}
	for source_part in source_plan.parts:
		if source_part != null:
			id_map[String(source_part.id)] = "castle_%s__furnishing__%s" % [residence_id, String(source_part.id)]
	for source_part in source_plan.parts:
		if source_part == null:
			continue
		var values: Dictionary = source_part.snapshot()
		var transformed_basis := yaw_basis * Basis.from_euler(source_part.rotation)
		var recipe: Dictionary = source_part.recipe.duplicate(true)
		remap_furnishing_links(recipe, id_map)
		recipe["rotation"] = transformed_basis.get_euler()
		recipe["castleResidenceId"] = residence_id
		recipe["castleResidenceFamily"] = family
		recipe["castleEgressProfile"] = egress_profile
		recipe["castleResidenceSourcePart"] = String(source_part.id)
		recipe["castleResidenceFacing"] = "courtyard_core"
		values["id"] = String(id_map.get(String(source_part.id), String(source_part.id)))
		values["roomId"] = "%s_%s" % [residence_id, String(source_part.room_id)]
		values["position"] = origin + yaw_basis * source_part.position
		values["rotation"] = transformed_basis.get_euler()
		values["recipe"] = recipe
		target_plan.add_part(values)


static func rebuild_furniture_blocked_egress(plan, castle_blueprint, residences: Array, castle_foundation_height: float, furnishing_seed: int, world_origin := Vector3.ZERO) -> Dictionary:
	# Candidate replacement never mutates existing part objects. Stage the
	# replace/append operations and diagnostics; publish only a complete analysis.
	var staged = FurnishingPlanScript.new(plan.id, plan.seed, plan.source_blueprint_id)
	staged.parts = plan.parts.duplicate()
	staged.protected_access_reservations = plan.protected_access_reservations.duplicate()
	staged.egress_diagnostics = plan.egress_diagnostics.duplicate(true)
	var outcome := _rebuild_furniture_blocked_egress(staged, castle_blueprint, residences, castle_foundation_height, furnishing_seed, world_origin)
	if bool(outcome.get("complete", false)):
		plan.parts = staged.parts
		plan.protected_access_reservations = staged.protected_access_reservations
		plan.egress_diagnostics = staged.egress_diagnostics
	return outcome


static func _rebuild_furniture_blocked_egress(plan, castle_blueprint, residences: Array, castle_foundation_height: float, furnishing_seed: int, world_origin: Vector3) -> Dictionary:
	var parent_transform := Transform3D(Basis.IDENTITY, world_origin)
	var navigation_manifest := BuildingNavigationManifestBuilderScript.build(castle_blueprint, parent_transform)
	var residence_manifest := CitadelResidenceManifestBuilderScript.build(
		castle_blueprint,
		plan,
		CitadelResidenceManifestBuilderScript.DEFAULT_CELL_SIZE,
		world_origin,
		[],
		{"requireReachableHome": false}
	)
	if bool(residence_manifest.get("incomplete", false)):
		return residence_manifest
	var empty_plan = FurnishingPlanScript.new("furnishing.egress-baseline", 0, String(castle_blueprint.id))
	var citizens: Array = residence_manifest.get("citizens", []) as Array
	var furnished_routes: Dictionary = CitadelResidenceManifestBuilderScript.furnishing_egress_paths(citizens, plan, navigation_manifest, CitadelResidenceManifestBuilderScript.DEFAULT_CELL_SIZE, world_origin)
	var baseline_routes: Dictionary = CitadelResidenceManifestBuilderScript.furnishing_egress_paths(citizens, empty_plan, navigation_manifest, CitadelResidenceManifestBuilderScript.DEFAULT_CELL_SIZE, world_origin)
	for routes in [furnished_routes, baseline_routes]:
		for route in (routes as Dictionary).values():
			if bool((route as Dictionary).get("incomplete", false)):
				return route as Dictionary
	var fallback_residences := {}
	for citizen_value in citizens:
		if not (citizen_value is Dictionary):
			continue
		var citizen: Dictionary = citizen_value as Dictionary
		var citizen_id := String(citizen.get("id", ""))
		var furnished_route: Dictionary = furnished_routes.get(citizen_id, {}) as Dictionary
		if bool(furnished_route.get("reachable", false)):
			var residence_id := String(citizen.get("residenceId", ""))
			plan.egress_diagnostics[residence_id] = {
				"status": "full_furnishing_verified",
				"verifiedBedPartId": String(citizen.get("bedPartId", "")),
				"proof": furnished_route.duplicate(true)
			}
			continue
		var baseline_route: Dictionary = baseline_routes.get(citizen_id, {}) as Dictionary
		if bool(baseline_route.get("reachable", false)):
			var residence_id := String(citizen.get("residenceId", ""))
			fallback_residences[residence_id] = true
			plan.egress_diagnostics[residence_id] = {"status": "furniture_blocked_egress", "furnished": furnished_route.duplicate(true), "baseline": baseline_route.duplicate(true)}
		else:
			plan.egress_diagnostics[String(citizen.get("residenceId", ""))] = {"status": "structural_topology_unproven", "furnished": furnished_route.duplicate(true), "baseline": baseline_route.duplicate(true)}
	if fallback_residences.is_empty():
		return {"complete": true, "status": "ready"}
	for residence_value in residences:
		if not (residence_value is Dictionary):
			continue
		var residence: Dictionary = residence_value as Dictionary
		var residence_id := String(residence.get("id", "")).strip_edges()
		if residence_id.is_empty() or not fallback_residences.has(residence_id):
			continue
		var selected_candidate := -1
		var selected_route: Dictionary = {}
		for candidate_index in range(12):
			remove_residence_furnishings(plan, residence_id)
			append_residence_furnishings(plan, residence, castle_foundation_height, furnishing_seed, {
				"egressSafe": true,
				"egressCandidate": candidate_index
			})
			var candidate_manifest := CitadelResidenceManifestBuilderScript.build(
				castle_blueprint,
				plan,
				CitadelResidenceManifestBuilderScript.DEFAULT_CELL_SIZE,
				world_origin,
				[residence_id]
			)
			if bool(candidate_manifest.get("incomplete", false)):
				return candidate_manifest
			var candidate_citizens: Array = []
			for citizen_value in candidate_manifest.get("citizens", []) as Array:
				if citizen_value is Dictionary and String((citizen_value as Dictionary).get("residenceId", "")) == residence_id:
					candidate_citizens.append(citizen_value)
			if candidate_citizens.is_empty():
				continue
			var candidate_routes := CitadelResidenceManifestBuilderScript.furnishing_egress_paths(candidate_citizens, plan, navigation_manifest, CitadelResidenceManifestBuilderScript.DEFAULT_CELL_SIZE, world_origin)
			for route in candidate_routes.values():
				if bool((route as Dictionary).get("incomplete", false)):
					return route as Dictionary
			var candidate_verified := true
			for citizen_value in candidate_citizens:
				var citizen: Dictionary = citizen_value
				var candidate_route: Dictionary = candidate_routes.get(String(citizen.get("id", "")), {}) as Dictionary
				if not bool(candidate_route.get("reachable", false)):
					candidate_verified = false
					selected_route = candidate_route.duplicate(true)
					break
				selected_route = candidate_route.duplicate(true)
			if candidate_verified:
				selected_candidate = candidate_index
				break
		plan.egress_diagnostics[residence_id]["status"] = "essential_furnishing_fallback"
		plan.egress_diagnostics[residence_id]["selectedCandidate"] = selected_candidate
		plan.egress_diagnostics[residence_id]["candidateRoute"] = selected_route
	var fallback_manifest := CitadelResidenceManifestBuilderScript.build(castle_blueprint, plan, CitadelResidenceManifestBuilderScript.DEFAULT_CELL_SIZE, world_origin)
	if bool(fallback_manifest.get("incomplete", false)):
		return fallback_manifest
	var fallback_routes: Dictionary = CitadelResidenceManifestBuilderScript.furnishing_egress_paths(fallback_manifest.get("citizens", []) as Array, plan, navigation_manifest, CitadelResidenceManifestBuilderScript.DEFAULT_CELL_SIZE, world_origin)
	for route in fallback_routes.values():
		if bool((route as Dictionary).get("incomplete", false)):
			return route as Dictionary
	for citizen_value in fallback_manifest.get("citizens", []) as Array:
		if not (citizen_value is Dictionary):
			continue
		var citizen: Dictionary = citizen_value
		var residence_id := String(citizen.get("residenceId", ""))
		if not fallback_residences.has(residence_id):
			continue
		var fallback_route: Dictionary = fallback_routes.get(String(citizen.get("id", "")), {}) as Dictionary
		plan.egress_diagnostics[residence_id]["fallback"] = fallback_route.duplicate(true)
		plan.egress_diagnostics[residence_id]["verifiedBedPartId"] = String(citizen.get("bedPartId", ""))
		plan.egress_diagnostics[residence_id]["status"] = "essential_furnishing_verified" if bool(fallback_route.get("reachable", false)) else "essential_furnishing_still_blocked"
	return {"complete": true, "status": "ready"}


static func remove_residence_furnishings(plan, residence_id: String) -> void:
	var retained: Array = []
	for part in plan.parts:
		if part == null or String(part.recipe.get("castleResidenceId", "")) != residence_id:
			retained.append(part)
	plan.parts = retained


static func transform_access_reservation(reservation: AABB, origin: Vector3, yaw_basis: Basis) -> AABB:
	var minimum := Vector3(INF, reservation.position.y + origin.y, INF)
	var maximum := Vector3(-INF, reservation.end.y + origin.y, -INF)
	for x in [reservation.position.x, reservation.end.x]:
		for z in [reservation.position.z, reservation.end.z]:
			var transformed := origin + yaw_basis * Vector3(x, 0.0, z)
			minimum.x = minf(minimum.x, transformed.x)
			minimum.z = minf(minimum.z, transformed.z)
			maximum.x = maxf(maximum.x, transformed.x)
			maximum.z = maxf(maximum.z, transformed.z)
	return AABB(minimum, Vector3(maximum.x - minimum.x, reservation.size.y, maximum.z - minimum.z))


static func remap_furnishing_links(recipe: Dictionary, id_map: Dictionary) -> void:
	# These records make furniture a structured arrangement rather than a set of
	# independent visual props.  Preserve their relationships after the castle
	# namespace is applied, so later interaction can still resolve a chair,
	# candle, rug, or lectern back to its actual supporting object.
	for key in ["tableId", "supportedBy", "mount"]:
		var source_id := String(recipe.get(key, ""))
		if id_map.has(source_id):
			recipe[key] = String(id_map[source_id])


static func build_manor_residence_plan(source_blueprint, furnishing_seed: int, furnishing_options := {}):
	var blueprint_id := String(source_blueprint.id) if source_blueprint != null else "missing-manor-blueprint"
	var plan = FurnishingPlanScript.new("furnishing.%s.%d" % [blueprint_id, furnishing_seed], furnishing_seed, blueprint_id)
	if source_blueprint == null:
		return plan
	var rng := RandomNumberGenerator.new()
	rng.seed = furnishing_seed
	var rooms := manor_rooms_by_role(source_blueprint.rooms)
	var foundation_height := float(source_blueprint.recipe.get("foundationHeight", 0.48))
	var egress_safe := bool(furnishing_options.get("egressSafe", false))
	for role in ["entry_hall", "dining", "kitchen", "private_chamber", "bedroom", "store"]:
		if egress_safe and role != "bedroom":
			continue
		var source_room: Dictionary = rooms.get(role, {}) as Dictionary
		if source_room.is_empty():
			continue
		var local_room := room_with_residential_access(source_room, foundation_height)
		var room_plan = FurnishingPlanScript.new("%s.%s" % [blueprint_id, role], furnishing_seed, blueprint_id)
		var room_accesses: Array[AABB] = InteriorFurnishingLayoutScript.circulation_reservations([local_room])
		room_plan.set_protected_access_reservations(room_accesses)
		var occupied: Array[AABB] = InteriorFurnishingLayoutScript.circulation_reservations([local_room])
		match role:
			"entry_hall":
				furnish_manor_entry(room_plan, occupied, local_room, rng)
			"dining":
				furnish_manor_dining(room_plan, occupied, local_room, rng)
			"kitchen":
				furnish_manor_kitchen(room_plan, occupied, local_room, rng)
			"private_chamber":
				furnish_manor_private_chamber(room_plan, occupied, local_room, rng)
			"bedroom":
				furnish_manor_bedroom(room_plan, occupied, local_room, rng, egress_safe)
			"store":
				furnish_manor_store(room_plan, occupied, local_room, rng)
		append_room_plan(plan, room_plan, source_room, foundation_height)
	if bool(furnishing_options.get("egressSafe", false)):
		var essential_parts: Array = []
		for part in plan.parts:
			if part != null and (String(part.archetype) == "bed" or not bool(part.collision_enabled)):
				essential_parts.append(part)
		plan.parts = essential_parts
	return plan


static func manor_rooms_by_role(room_records: Array) -> Dictionary:
	var result := {}
	for room_value in room_records:
		if not room_value is Dictionary:
			continue
		var room: Dictionary = room_value as Dictionary
		var role := String(room.get("role", "")).strip_edges().to_lower()
		var bounds: AABB = room.get("bounds", AABB()) as AABB
		if role.is_empty() or bounds.size.x <= 0.0 or bounds.size.z <= 0.0:
			continue
		result[role] = room.duplicate(true)
	return result


static func room_with_residential_access(source_room: Dictionary, foundation_height: float) -> Dictionary:
	# Manor construction already has a real outer entry, connected wing and stair
	# tower.  Its first PoC room records predate furnishing access metadata, so a
	# compact home derives one conservative, room-local approach band from each
	# usable room boundary.  That band is used only by this shared furnishing
	# grammar; it prevents dense decor from sealing the room's open circulation.
	var room := source_room.duplicate(true)
	var bounds: AABB = room.get("bounds", AABB()) as AABB
	var storey_offset := maxf(0.0, bounds.position.y - foundation_height)
	var local_bounds := bounds
	local_bounds.position.y -= storey_offset
	room["bounds"] = local_bounds
	var accesses: Array = []
	for access_value in room.get("accesses", []) as Array:
		if access_value is Dictionary:
			var access: Dictionary = (access_value as Dictionary).duplicate(true)
			var access_position: Vector3 = access.get("position", Vector3.ZERO) as Vector3
			access_position.y -= storey_offset
			access["position"] = access_position
			accesses.append(access)
	if accesses.is_empty():
		var width := minf(maxf(1.30, bounds.size.x * 0.36), maxf(1.30, bounds.size.x - 0.46))
		var depth := minf(maxf(1.68, bounds.size.z * 0.30), maxf(1.68, bounds.size.z - 0.46))
		accesses = [{
			"id": "manor_%s_circulation" % String(room.get("id", "room")),
			"kind": "interior_circulation",
			"position": Vector3(bounds.get_center().x, CottageFurnishingPlannerScript.FLOOR_Y, bounds.position.z + depth * 0.5 + 0.10),
			"size": Vector3(width, 2.10, depth),
			"furnishingSize": Vector3(width + 0.38, 2.10, depth + 0.42)
		}]
	room["accesses"] = accesses.duplicate(true)
	return room


static func append_room_plan(target_plan, room_plan, source_room: Dictionary, foundation_height: float) -> void:
	# Cottage helpers use the shared ground-floor furnishing baseline.  Manor
	# room bounds carry the actual storey elevation, so add only the amount above
	# the source foundation: ground furniture stays on the ground floor while
	# solar furniture lands on its physical upper floor.
	var bounds: AABB = source_room.get("bounds", AABB()) as AABB
	var storey_offset := maxf(0.0, bounds.position.y - foundation_height)
	var shifted_accesses: Array[AABB] = []
	for access in room_plan.access_reservations_snapshot():
		shifted_accesses.append(AABB(access.position + Vector3.UP * storey_offset, access.size))
	target_plan.add_protected_access_reservations(shifted_accesses)
	for part in room_plan.parts:
		if part == null:
			continue
		var values: Dictionary = part.snapshot()
		values["position"] = part.position + Vector3(0.0, storey_offset, 0.0)
		var recipe: Dictionary = part.recipe.duplicate(true)
		recipe["manorStoreyOffset"] = storey_offset
		values["recipe"] = recipe
		var added = target_plan.add_part(values)
		if added == null and String(part.archetype) == "bed":
			append_composed_bed_fallback(target_plan, source_room, values, storey_offset)


static func append_composed_bed_fallback(target_plan, source_room: Dictionary, source_values: Dictionary, storey_offset: float) -> void:
	var bounds: AABB = source_room.get("bounds", AABB()) as AABB
	var room_id := String(source_room.get("id", "bedroom"))
	for size in [Vector3(2.26, 0.76, 1.28), Vector3(1.70, 0.72, 0.82)]:
		for yaw in [0.0, PI * 0.5]:
			for z_normalized in [0.22, 0.38, 0.50, 0.62, 0.78]:
				for x_normalized in [0.18, 0.34, 0.50, 0.66, 0.82]:
					var values := source_values.duplicate(true)
					values["position"] = Vector3(bounds.position.x + bounds.size.x * x_normalized, CottageFurnishingPlannerScript.FLOOR_Y + storey_offset, bounds.position.z + bounds.size.z * z_normalized)
					values["rotation"] = Vector3(0.0, yaw, 0.0)
					values["occupiedSize"] = size
					var recipe: Dictionary = values.get("recipe", {}) as Dictionary
					recipe["rotation"] = values["rotation"]
					recipe["compact"] = size.x < 2.0
					values["recipe"] = recipe
					var candidate_bounds := InteriorFurnishingLayoutScript.horizontal_bounds(values["position"] as Vector3, size, values["rotation"] as Vector3, 0.06)
					if InteriorFurnishingLayoutScript.intersects_any(candidate_bounds, composed_room_collision_bounds(target_plan, room_id)):
						continue
					var added = target_plan.add_part(values)
					if added == null:
						continue
					if CottageFurnishingPlannerScript.plan_room_is_walkable(target_plan, source_room):
						return
					target_plan.parts.erase(added)


static func composed_room_collision_bounds(plan, room_id: String) -> Array[AABB]:
	var result: Array[AABB] = []
	for part in plan.parts:
		if part != null and part.collision_enabled and String(part.room_id) == room_id:
			result.append(InteriorFurnishingLayoutScript.horizontal_bounds(part.position, part.occupied_size, part.rotation, 0.06))
	return result


static func furnish_manor_entry(plan, occupied: Array[AABB], room: Dictionary, rng: RandomNumberGenerator) -> void:
	CottageFurnishingPlannerScript.place(plan, occupied, room, "entry_runner", "rug", "wool_moss", Vector2(0.50, 0.55), Vector3(minf(2.20, (room.get("bounds", AABB()) as AABB).size.x * 0.46), 0.035, minf(2.90, (room.get("bounds", AABB()) as AABB).size.z * 0.56)), {"collision": false, "reserve": false, "semantic": "entry_runner"})
	CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, room, "entry_sideboard", "sideboard", ["left", "right", "back"], rng)
	CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, room, "entry_coat_rack", "coat_rack", ["left", "right", "back"], rng)
	CottageFurnishingPlannerScript.place_catalogued_wall_sconce(plan, room, "entry_sconce", "back", rng.randf_range(0.24, 0.76))


static func furnish_manor_dining(plan, occupied: Array[AABB], room: Dictionary, rng: RandomNumberGenerator) -> void:
	var bounds: AABB = room.get("bounds", AABB()) as AABB
	var seat_goal := 4 if bounds.size.x * bounds.size.z >= 20.0 else 2
	var dining := CottageFurnishingPlannerScript.place_dining_set(plan, occupied, room, rng, seat_goal)
	var table = dining.get("table", null)
	if table != null:
		CottageFurnishingPlannerScript.add_candle_on_surface(plan, "dining_candle", table, Vector3(rng.randf_range(-0.22, 0.22), table.occupied_size.y + 0.04, rng.randf_range(-0.14, 0.14)))
	CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, room, "dining_sideboard", "sideboard", ["left", "right", "back"], rng)
	CottageFurnishingPlannerScript.place_catalogued_wall_banner(plan, room, "dining_banner", "back", rng.randf_range(0.24, 0.76), "wool_rust")


static func furnish_manor_kitchen(plan, occupied: Array[AABB], room: Dictionary, rng: RandomNumberGenerator) -> void:
	CottageFurnishingPlannerScript.place_against_random_walls(plan, occupied, room, "kitchen_hearth", "hearth", "fired_brick", ["back", "left", "right"], rng, Vector3(1.68, 1.88, 0.64), {"semantic": "kitchen_hearth", "clearance": 0.10})
	CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, room, "kitchen_workbench", "workbench", ["left", "right", "back"], rng)
	CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, room, "kitchen_cabinet", "cabinet", ["left", "right", "back"], rng)
	CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, room, "kitchen_barrels", "barrel_stack", ["left", "right", "back"], rng)


static func furnish_manor_private_chamber(plan, occupied: Array[AABB], room: Dictionary, rng: RandomNumberGenerator) -> void:
	CottageFurnishingPlannerScript.place_catalogued_random(plan, occupied, room, "private_map_table", "map_table", rng, 16)
	CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, room, "private_shelf", "shelf", ["left", "right", "back"], rng)
	CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, room, "private_chest", "chest", ["left", "right", "back"], rng)
	CottageFurnishingPlannerScript.place_catalogued_wall_banner(plan, room, "private_banner", "back", rng.randf_range(0.24, 0.76), "wool_moss")


static func furnish_manor_bedroom(plan, occupied: Array[AABB], room: Dictionary, rng: RandomNumberGenerator, egress_safe := false) -> void:
	var preferred_wall := "left" if rng.randi() % 2 == 0 else "right"
	var alternate_wall := "right" if preferred_wall == "left" else "left"
	var bed_candidates: Array[Dictionary] = [
		{"wall": preferred_wall, "along": rng.randf_range(0.26, 0.74)},
		{"wall": alternate_wall, "along": 0.28},
		{"wall": preferred_wall, "along": 0.50},
		{"wall": alternate_wall, "along": 0.72},
		{"wall": preferred_wall, "along": 0.28},
		{"wall": alternate_wall, "along": 0.50},
		{"wall": preferred_wall, "along": 0.72}
	]
	var bed = null
	var bed_size := Vector3(1.70, 0.72, 0.82) if egress_safe else Vector3(2.26, 0.76, 1.28)
	for candidate in bed_candidates:
		bed = CottageFurnishingPlannerScript.place_against_wall(plan, occupied, room, "bedroom_bed", "bed", "timber_beam", String(candidate.get("wall", "left")), float(candidate.get("along", 0.5)), bed_size, {"semantic": "bedroom_bed", "blanket": "wool_moss", "bedVariant": "single" if egress_safe else "double", "clearance": 0.10, "interactionClearance": 1.45})
		if bed != null and plan.parts.has(bed):
			break
		bed = null
	if bed != null and plan.parts.has(bed):
		CottageFurnishingPlannerScript.add_rug_under_surface(plan, "bedroom_rug", bed, Vector2(1.08, 1.18), "wool_rust", "bedroom_rug")
		if egress_safe:
			return
		var bedside = CottageFurnishingPlannerScript.place_at(plan, occupied, "bedroom_bedside", String(room.get("id", "bedroom")), "cabinet", "timber_beam", bed.position + Vector3(-bed.occupied_size.x * 0.5 - 0.53, 0.0, 0.0), Vector3(0.54, 0.72, 0.46), {"semantic": "bedroom_bedside", "clearance": 0.06, "interactionClearance": 0.64}, room)
		if bedside != null:
			CottageFurnishingPlannerScript.add_candle_on_surface(plan, "bedroom_bedside_candle", bedside, Vector3(rng.randf_range(-0.12, 0.12), bedside.occupied_size.y + 0.04, rng.randf_range(-0.08, 0.08)))
	CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, room, "bedroom_chest", "chest", ["left", "right", "back"], rng)
	CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, room, "bedroom_shelf", "shelf", ["left", "right", "back"], rng)
	if not room_has_archetype(plan, String(room.get("id", "bedroom")), "bed"):
		remove_optional_room_collision(plan, String(room.get("id", "bedroom")))
		var compact_occupied := current_room_occupied_bounds(plan, room)
		for yaw in [0.0, PI * 0.5]:
			for z_normalized in [0.22, 0.38, 0.50, 0.62, 0.78]:
				for x_normalized in [0.18, 0.34, 0.50, 0.66, 0.82]:
					bed = CottageFurnishingPlannerScript.place(plan, compact_occupied, room, "bedroom_bed", "bed", "timber_beam", Vector2(x_normalized, z_normalized), Vector3(1.70, 0.72, 0.82), {"semantic": "bedroom_bed", "blanket": "wool_moss", "clearance": 0.06, "compact": true, "rotation": Vector3(0.0, yaw, 0.0), "interactionClearance": 1.45})
					if bed != null and plan.parts.has(bed):
						CottageFurnishingPlannerScript.add_rug_under_surface(plan, "bedroom_rug", bed, Vector2(1.08, 1.16), "wool_rust", "bedroom_rug")
						return


static func room_has_archetype(plan, room_id: String, archetype: String) -> bool:
	for part in plan.parts:
		if part != null and String(part.room_id) == room_id and String(part.archetype) == archetype:
			return true
	return false


static func remove_optional_room_collision(plan, room_id: String) -> void:
	var retained: Array = []
	for part in plan.parts:
		if part == null or String(part.room_id) != room_id:
			retained.append(part)
		elif not part.collision_enabled and String(part.id) != "bedroom_rug":
			retained.append(part)
	plan.parts = retained


static func current_room_occupied_bounds(plan, room: Dictionary) -> Array[AABB]:
	var occupied: Array[AABB] = InteriorFurnishingLayoutScript.circulation_reservations([room])
	var room_id := String(room.get("id", ""))
	for part in plan.parts:
		if part != null and part.collision_enabled and String(part.room_id) == room_id:
			occupied.append(InteriorFurnishingLayoutScript.horizontal_bounds(part.position, part.occupied_size, part.rotation, CottageFurnishingPlannerScript.NPC_EGRESS_CLEARANCE))
	return occupied


static func furnish_manor_store(plan, occupied: Array[AABB], room: Dictionary, rng: RandomNumberGenerator) -> void:
	# The stair tower is a circulation volume. Keep its centre clear and turn the
	# usable perimeter into storage instead of placing a central obstacle across
	# the generated stairs.
	CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, room, "store_crates", "crate_stack", ["left", "right", "back"], rng)
	CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, room, "store_barrels", "barrel_stack", ["left", "right", "back"], rng)
	CottageFurnishingPlannerScript.place_catalogued_against_walls(plan, occupied, room, "store_shelf", "shelf", ["left", "right", "back"], rng)
