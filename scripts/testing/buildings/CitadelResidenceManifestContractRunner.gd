extends SceneTree

## A focused data contract. It proves deterministic bed-to-citizen manifests
## from the shared castle and furnishing grammar; it does not prove physics,
## player traversal, door use, scheduling, or visual behaviour.

const CastleCompoundBlueprintBuilderScript := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const CastleFurnishingPlannerScript := preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const CitadelResidenceManifestBuilderScript := preload("res://scripts/buildings/CitadelResidenceManifestBuilder.gd")
const BuildingNavigationManifestBuilderScript := preload("res://scripts/buildings/BuildingNavigationManifestBuilder.gd")
const InteriorFurnishingLayoutScript := preload("res://scripts/buildings/InteriorFurnishingLayout.gd")

const SEEDS: Array[int] = [208158, 208159, 306701, 724169]
const RESIDENT_ACCESS_RADIUS := 0.34
const RESIDENT_ACCESS_STEP := 0.32
const RESIDENT_ACCESS_SNAP_DISTANCE := 0.56

var failures: Array[String] = []
var report_path := ""


func _initialize() -> void:
	call_deferred("run_contract")


func run_contract() -> void:
	report_path = OS.get_environment("VOXEL_CITADEL_RESIDENCE_MANIFEST_REPORT").strip_edges()
	if report_path.is_empty():
		report_path = ProjectSettings.globalize_path("res://artifacts/buildings/citadel-residence-manifest-contract.json")
	var contract_seeds := requested_seeds()
	var rows: Array[Dictionary] = []
	for seed in contract_seeds:
		rows.append(verify_seed(seed))
	var report := {
		"runnerId": "citadel_residence_manifest_contract",
		"evidenceLevel": "contract",
		"scope": "Deterministic semantic residences, bed assignments and published-door identifiers. It does not prove NPC physics, live pathfinding, player movement or visual gameplay.",
		"seeds": contract_seeds,
		"siteKey": requested_site_key(),
		"passed": failures.is_empty(),
		"rows": rows,
		"failures": failures
	}
	write_report(report)
	print(JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)


func requested_seeds() -> Array[int]:
	var raw_seeds := OS.get_environment("VOXEL_CITADEL_RESIDENCE_MANIFEST_SEEDS").strip_edges()
	if raw_seeds.is_empty():
		return SEEDS.duplicate()
	var result: Array[int] = []
	for value in raw_seeds.split(",", false):
		var seed_text := String(value).strip_edges()
		if seed_text.is_valid_int():
			result.append(seed_text.to_int())
	return result if not result.is_empty() else SEEDS.duplicate()


func requested_site_key() -> String:
	return OS.get_environment("VOXEL_CITADEL_RESIDENCE_MANIFEST_SITE_KEY").strip_edges()


func verify_seed(seed: int) -> Dictionary:
	var requested_site := requested_site_key()
	var castle = CastleCompoundBlueprintBuilderScript.build(seed, {
		"biome": "forest",
		"siteKey": requested_site if not requested_site.is_empty() else "citadel-life" if seed == 724169 else "citadel-life-contract",
		"citadelScale": 1.25
	})
	var furnishing_seed := seed * 7919 + 37
	var furnishing = CastleFurnishingPlannerScript.build(castle, furnishing_seed)
	var replay_furnishing = CastleFurnishingPlannerScript.build(castle, furnishing_seed)
	var manifest := CitadelResidenceManifestBuilderScript.build(castle, furnishing)
	var replay := CitadelResidenceManifestBuilderScript.build(castle, replay_furnishing)
	var building_navigation_manifest := BuildingNavigationManifestBuilderScript.build(castle)
	var support_by_id := {}
	var door_by_part_id := {}
	for support_value in building_navigation_manifest.get("supports", []) as Array:
		if support_value is Dictionary:
			var support: Dictionary = support_value
			support_by_id[String(support.get("id", ""))] = support
	for door_value in building_navigation_manifest.get("doors", []) as Array:
		if door_value is Dictionary:
			var door: Dictionary = door_value
			door_by_part_id[String(door.get("sourcePartId", ""))] = door
	check(
		CitadelResidenceManifestBuilderScript.deterministic_signature(manifest) == CitadelResidenceManifestBuilderScript.deterministic_signature(replay),
		"seed %d residence manifest did not replay deterministically" % seed
	)
	var source_bed_ids := {}
	var access_reservations: Array[AABB] = furnishing.access_reservations_snapshot()
	check(not access_reservations.is_empty(), "seed %d castle furnishing lacks source access reservations" % seed)
	for part in furnishing.parts:
		if part == null:
			continue
		if String(part.archetype) in ["rug", "aisle_runner"]:
			continue
		var part_bounds := InteriorFurnishingLayoutScript.horizontal_bounds(part.position, part.occupied_size, part.rotation)
		check(not InteriorFurnishingLayoutScript.intersects_any(part_bounds, access_reservations), "seed %d furnishing %s occupies a protected castle access" % [seed, String(part.id)])
	for part in furnishing.parts:
		if part == null or String(part.archetype) != "bed":
			continue
		if not String(part.recipe.get("castleResidenceId", "")).is_empty():
			source_bed_ids[String(part.id)] = true
	check(not source_bed_ids.is_empty(), "seed %d did not expose any castle residence beds" % seed)
	check((manifest.get("missingDoors", []) as Array).is_empty(), "seed %d has courtyard residences without source door parts: %s" % [seed, JSON.stringify(manifest.get("missingDoors", []))])
	check((manifest.get("unassignedBeds", []) as Array).is_empty(), "seed %d has beds without a strict interior stand cell: %s" % [seed, JSON.stringify(manifest.get("unassignedBeds", []))])
	for residence_value in manifest.get("residences", []) as Array:
		if residence_value is Dictionary:
			var residence: Dictionary = residence_value
			check(int(residence.get("bedCount", 0)) > 0, "seed %d residence %s has no bed" % [seed, String(residence.get("residenceId", ""))])
	var seen_citizens := {}
	var assigned_bed_ids := {}
	var residences_without_beds: Array[Dictionary] = []
	for residence_value in manifest.get("residences", []) as Array:
		if not (residence_value is Dictionary):
			continue
		var residence: Dictionary = residence_value
		if int(residence.get("bedCount", 0)) > 0:
			continue
		var residence_id := String(residence.get("residenceId", ""))
		residences_without_beds.append(residence_without_bed_diagnostic(castle, residence_id))
	for citizen_value in manifest.get("citizens", []) as Array:
		if not citizen_value is Dictionary:
			continue
		var citizen: Dictionary = citizen_value
		var id := String(citizen.get("id", ""))
		var bed_id := String(citizen.get("bedPartId", ""))
		check(not id.is_empty() and not seen_citizens.has(id), "seed %d repeats/omits citizen id %s" % [seed, id])
		check(source_bed_ids.has(bed_id) and not assigned_bed_ids.has(bed_id), "seed %d does not maintain one citizen per bed %s" % [seed, bed_id])
		seen_citizens[id] = true
		assigned_bed_ids[bed_id] = true
		var home_cell: Vector2i = citizen.get("homeCell", Vector2i.ZERO)
		var interior_min: Vector2i = citizen.get("interiorMinCell", Vector2i.ZERO)
		var interior_max: Vector2i = citizen.get("interiorMaxCell", Vector2i.ZERO)
		var door_cell: Vector2i = citizen.get("doorCell", CitadelResidenceManifestBuilderScript.INVALID_CELL)
		var porch_cell: Vector2i = citizen.get("porchCell", CitadelResidenceManifestBuilderScript.INVALID_CELL)
		var porch_position: Vector3 = citizen.get("porchPosition", Vector3.INF)
		var porch_support_id := String(citizen.get("porchSupportId", ""))
		var door_interior_position: Vector3 = citizen.get("doorInteriorPosition", Vector3.INF)
		var source_door: Dictionary = door_by_part_id.get(String(citizen.get("doorPartId", "")), {}) as Dictionary
		check(home_cell.x >= interior_min.x and home_cell.x <= interior_max.x and home_cell.y >= interior_min.y and home_cell.y <= interior_max.y, "seed %d citizen %s has home cell outside strict interior bounds" % [seed, id])
		check(home_cell != door_cell, "seed %d citizen %s stands on the home door cell" % [seed, id])
		check(porch_position.is_finite() and is_equal_approx(porch_position.x, float(porch_cell.x) * 1.35) and is_equal_approx(porch_position.z, float(porch_cell.y) * 1.35), "seed %d citizen %s has a porch position that does not match its porch cell" % [seed, id])
		check(not porch_support_id.is_empty() and support_by_id.has(porch_support_id), "seed %d citizen %s has no published support for its porch" % [seed, id])
		if support_by_id.has(porch_support_id):
			var porch_support: Dictionary = support_by_id[porch_support_id] as Dictionary
			var expected_porch_y := CitadelResidenceManifestBuilderScript.support_surface_y(porch_support, porch_position) + 0.04
			check(is_equal_approx(porch_position.y, expected_porch_y), "seed %d citizen %s porch height does not match its published support" % [seed, id])
		check(door_interior_position.is_finite() and not source_door.is_empty(), "seed %d citizen %s has no published interior door endpoint" % [seed, id])
		if not source_door.is_empty():
			var expected_door_interior: Vector3 = source_door.get("interior", Vector3.INF) as Vector3
			check(door_interior_position.distance_to(expected_door_interior) <= 0.001, "seed %d citizen %s egress target does not match its published interior door endpoint" % [seed, id])
		var home_position := Vector3(float(home_cell.x) * 1.35, float(citizen.get("level", 0.0)), float(home_cell.y) * 1.35)
		var home_blocker := furnishing_blocker_for_resident_position(furnishing, home_position)
		check(home_blocker.is_empty(), "seed %d citizen %s home stand cell overlaps furnishing %s" % [seed, id, home_blocker])
		var access := CitadelResidenceManifestBuilderScript.furnishing_egress_path(citizen, furnishing, building_navigation_manifest, 1.35)
		check(bool(access.get("reachable", false)), "seed %d citizen %s has no collision-clear route from its published interior door endpoint to bed stand: %s" % [seed, id, JSON.stringify(access)])
		check(String(citizen.get("doorPortalId", "")).begins_with("building:%s:castle_" % String(castle.id)), "seed %d citizen %s has a portal id that cannot be produced by BuildingPartPublisher" % [seed, id])
	check(assigned_bed_ids.size() == source_bed_ids.size(), "seed %d assigned %d citizens to %d semantic beds" % [seed, assigned_bed_ids.size(), source_bed_ids.size()])
	return {
		"seed": seed,
		"castleParts": castle.parts.size(),
		"furnishingParts": furnishing.parts.size(),
		"residenceCount": (manifest.get("residences", []) as Array).size(),
		"bedCount": source_bed_ids.size(),
		"citizenCount": (manifest.get("citizens", []) as Array).size(),
		"egressProfiles": egress_profiles_by_residence(furnishing),
		"residencesWithoutBeds": residences_without_beds
	}


func egress_profiles_by_residence(furnishing) -> Dictionary:
	var profiles := {}
	if furnishing == null:
		return profiles
	for part in furnishing.parts:
		if part == null:
			continue
		var residence_id := String(part.recipe.get("castleResidenceId", "")).strip_edges()
		var profile := String(part.recipe.get("castleEgressProfile", "")).strip_edges()
		if residence_id.is_empty() or profile.is_empty():
			continue
		profiles[residence_id] = profile
	return profiles


func residence_without_bed_diagnostic(castle, residence_id: String) -> Dictionary:
	var recipe: Dictionary = {}
	for residence_value in castle.recipe.get("courtyardResidences", []) as Array:
		if residence_value is Dictionary and String((residence_value as Dictionary).get("id", "")) == residence_id:
			recipe = ((residence_value as Dictionary).get("residenceRecipe", {}) as Dictionary).duplicate(true)
			break
	var rooms: Array[Dictionary] = []
	for room_value in castle.rooms:
		if not (room_value is Dictionary):
			continue
		var room: Dictionary = room_value
		if not String(room.get("id", "")).begins_with("%s_" % residence_id):
			continue
		var bounds: AABB = room.get("bounds", AABB()) as AABB
		rooms.append({
			"id": String(room.get("id", "")),
			"bounds": bounds,
			"accesses": room.get("accesses", [])
		})
	return {
		"residenceId": residence_id,
		"recipe": recipe,
		"rooms": rooms
	}


func resident_access_path(citizen: Dictionary, furnishing, cell_size: float) -> Dictionary:
	var minimum: Vector2i = citizen.get("interiorMinCell", Vector2i.ZERO)
	var maximum: Vector2i = citizen.get("interiorMaxCell", Vector2i.ZERO)
	var start_cell: Vector2i = citizen.get("interiorLandingCell", minimum)
	var target_cell: Vector2i = citizen.get("homeCell", minimum)
	var level := float(citizen.get("level", 0.0))
	var minimum_position := Vector2((float(minimum.x) - 0.5) * cell_size + RESIDENT_ACCESS_RADIUS, (float(minimum.y) - 0.5) * cell_size + RESIDENT_ACCESS_RADIUS)
	var maximum_position := Vector2((float(maximum.x) + 0.5) * cell_size - RESIDENT_ACCESS_RADIUS, (float(maximum.y) + 0.5) * cell_size - RESIDENT_ACCESS_RADIUS)
	var columns := maxi(1, floori((maximum_position.x - minimum_position.x) / RESIDENT_ACCESS_STEP) + 1)
	var rows := maxi(1, floori((maximum_position.y - minimum_position.y) / RESIDENT_ACCESS_STEP) + 1)
	var free := {}
	var blocked_parts := {}
	for row in range(rows):
		for column in range(columns):
			var index := Vector2i(column, row)
			var position := Vector3(minimum_position.x + float(column) * RESIDENT_ACCESS_STEP, level, minimum_position.y + float(row) * RESIDENT_ACCESS_STEP)
			var blocker_id := furnishing_blocker_for_resident_position(furnishing, position)
			if blocker_id.is_empty():
				free[index] = position
			else:
				blocked_parts[blocker_id] = true
	var start_position := Vector3(float(start_cell.x) * cell_size, level, float(start_cell.y) * cell_size)
	var target_position := Vector3(float(target_cell.x) * cell_size, level, float(target_cell.y) * cell_size)
	var start := nearest_free_access_index(free, start_position)
	var target := nearest_free_access_index(free, target_position)
	if start == CitadelResidenceManifestBuilderScript.INVALID_CELL or target == CitadelResidenceManifestBuilderScript.INVALID_CELL:
		return {
			"reachable": false,
			"reason": "landing_or_bed_stand_has_no_clear_footprint",
			"landingReachable": start != CitadelResidenceManifestBuilderScript.INVALID_CELL,
			"bedStandReachable": target != CitadelResidenceManifestBuilderScript.INVALID_CELL,
			"blockedParts": blocked_parts.keys()
		}
	var frontier: Array[Vector2i] = [start]
	var visited := {start: true}
	var cursor := 0
	while cursor < frontier.size():
		var cell := frontier[cursor]
		cursor += 1
		if cell == target:
			return {"reachable": true, "blockedParts": blocked_parts.keys(), "visitedCellCount": visited.size()}
		for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var next: Vector2i = cell + offset
			if next.x < 0 or next.x >= columns or next.y < 0 or next.y >= rows:
				continue
			if not free.has(next) or visited.has(next):
				continue
			visited[next] = true
			frontier.append(next)
	return {"reachable": false, "reason": "furnishing_access_disconnected", "blockedParts": blocked_parts.keys(), "visitedCellCount": visited.size()}


func nearest_free_access_index(free: Dictionary, position: Vector3) -> Vector2i:
	var result := CitadelResidenceManifestBuilderScript.INVALID_CELL
	var best_distance := INF
	for index_value in free.keys():
		if not (index_value is Vector2i):
			continue
		var index: Vector2i = index_value
		var candidate: Vector3 = free[index] as Vector3
		var distance := Vector2(candidate.x - position.x, candidate.z - position.z).length()
		if distance <= RESIDENT_ACCESS_SNAP_DISTANCE and distance < best_distance:
			result = index
			best_distance = distance
	return result


func furnishing_blocker_for_resident_position(furnishing, position: Vector3) -> String:
	for part in furnishing.parts:
		if part == null or not bool(part.collision_enabled):
			continue
		var part_base_y: float = part.position.y
		var part_top_y: float = part_base_y + part.occupied_size.y
		if part_top_y < position.y + 0.04 or part_base_y > position.y + 1.70:
			continue
		var bounds := InteriorFurnishingLayoutScript.horizontal_bounds(part.position, part.occupied_size, part.rotation, RESIDENT_ACCESS_RADIUS)
		if InteriorFurnishingLayoutScript.point_inside_horizontal_bounds(position, bounds):
			return String(part.id)
	return ""


func check(condition: bool, failure: String) -> void:
	if not condition:
		failures.append(failure)


func write_report(report: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
