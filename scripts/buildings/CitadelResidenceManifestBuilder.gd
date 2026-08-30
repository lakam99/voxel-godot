extends RefCounted
class_name CitadelResidenceManifestBuilder

## Resolves inhabited courtyard homes from the same immutable castle shell and
## furnishing records that publish the citadel.  The result is intentionally
## semantic data, never a scan of StaticBody3D or MeshInstance3D output.

const DEFAULT_CELL_SIZE := 1.35
const RESIDENT_STAND_RADIUS := 0.34
const RESIDENT_STANDING_HEIGHT := 1.70
const RESIDENT_WALL_MARGIN := 0.16

const INVALID_CELL := Vector2i(999999, 999999)
const BuildingNavigationManifestBuilderScript := preload("res://scripts/buildings/BuildingNavigationManifestBuilder.gd")
const FurnishingNavigationManifestBuilderScript := preload("res://scripts/buildings/FurnishingNavigationManifestBuilder.gd")
const BuildingLayoutClearanceScript := preload("res://scripts/buildings/layout/BuildingLayoutClearance.gd")
const NpcConstantsScript := preload("res://scripts/buildings/layout/BuildingLayoutConstants.gd")

static func build(castle_blueprint, furnishing_plan, cell_size := DEFAULT_CELL_SIZE, world_origin := Vector3.ZERO, residence_ids := [], options := {}) -> Dictionary:
	var blueprint_id := String(castle_blueprint.id) if castle_blueprint != null else "missing-citadel"
	var result := {
		"blueprintId": blueprint_id,
		"seed": int(castle_blueprint.seed) if castle_blueprint != null else 0,
		"cellSize": cell_size,
		"residences": [],
		"citizens": [],
		"unassignedBeds": [],
		"unassignedBedDiagnostics": [],
		"missingDoors": [],
		"navigationPassageRejections": []
	}
	if castle_blueprint == null or furnishing_plan == null:
		return result
	var parent_transform := Transform3D(Basis.IDENTITY, world_origin)
	var navigation_manifest := BuildingNavigationManifestBuilderScript.build(castle_blueprint, parent_transform)
	var furnishing_navigation_manifest := FurnishingNavigationManifestBuilderScript.build(furnishing_plan, parent_transform)
	var source_navigation_adapter = BuildingLayoutClearanceScript.new()
	source_navigation_adapter._load_source_navigation_manifests(navigation_manifest, [furnishing_navigation_manifest])
	var require_reachable_home := bool(options.get("requireReachableHome", true))
	var home_snap_policy := NpcConstantsScript.route_snap_distances("home", cell_size * 0.75, false)
	var home_start_snap_distance := float(home_snap_policy.get("start", cell_size * 0.95))
	result["navigationPassageRejections"] = (navigation_manifest.get("interiorPassageRejections", []) as Array).duplicate(true)
	var navigation_supports: Array = navigation_manifest.get("supports", []) as Array
	var navigation_doors: Array = navigation_manifest.get("doors", []) as Array
	var residences := sorted_residences(castle_blueprint.recipe.get("courtyardResidences", []) as Array)
	var requested_residence_ids := {}
	for residence_id_value in residence_ids:
		var requested_residence_id := String(residence_id_value).strip_edges()
		if not requested_residence_id.is_empty():
			requested_residence_ids[requested_residence_id] = true
	var rooms_by_id := room_records_by_id(castle_blueprint.rooms)
	var beds_by_residence := beds_by_residence(furnishing_plan)
	for residence_value in residences:
		var residence: Dictionary = residence_value
		var residence_id := String(residence.get("id", "")).strip_edges()
		if residence_id.is_empty() or (not requested_residence_ids.is_empty() and not requested_residence_ids.has(residence_id)):
			continue
		var door = residence_door_part(castle_blueprint.parts, residence_id)
		if door == null:
			result["missingDoors"].append(residence_id)
			continue
		var shell := residence_shell(residence, door, blueprint_id, cell_size, world_origin, navigation_supports, navigation_doors)
		var resident_beds: Array = beds_by_residence.get(residence_id, []) as Array
		var used_stand_cells := {}
		var citizen_count := 0
		for bed_value in resident_beds:
			var bed = bed_value
			var room: Dictionary = rooms_by_id.get(String(bed.room_id), {}) as Dictionary
			var bedroom_bounds := cell_bounds_for_room(room, shell, cell_size, world_origin)
			var bed_walk_level := maxf(float(shell.get("level", 0.0)), bed.position.y + world_origin.y)
			var stand_cell := INVALID_CELL
			var stand_position := Vector3.INF
			var home_connector_proof: Dictionary = {}
			var stand_candidates := bed_stand_cell_candidates(bed, bedroom_bounds, shell, used_stand_cells, furnishing_plan, cell_size, world_origin)
			var egress_diagnostic: Dictionary = furnishing_plan.egress_diagnostics.get(residence_id, {}) as Dictionary
			var verified_route: Dictionary = egress_diagnostic.get("fallback", egress_diagnostic.get("proof", {})) as Dictionary
			if require_reachable_home \
				and String(egress_diagnostic.get("verifiedBedPartId", "")) == String(bed.id) \
				and bool(verified_route.get("reachable", false)) \
				and String(verified_route.get("sourceCollisionRevision", "")) == String(source_navigation_adapter.cached_revision):
				for probe_value in verified_route.get("probes", []) as Array:
					if not (probe_value is Dictionary) or String((probe_value as Dictionary).get("id", "")) != "home":
						continue
					var verified_probe: Dictionary = probe_value
					var verified_position: Vector3 = verified_probe.get("position", Vector3.INF) as Vector3
					var verified_cell := cell_for_position(verified_position, cell_size) if verified_position.is_finite() else INVALID_CELL
					if verified_position.is_finite() and stand_position_inside_room(verified_position, room, world_origin) and not used_stand_cells.has(cell_key(verified_cell)) and resident_stand_cell_is_clear(verified_cell, bed, furnishing_plan, cell_size, world_origin):
						stand_position = verified_position
						stand_cell = verified_cell
						home_connector_proof = verified_probe.duplicate(true)
						home_connector_proof["reusedEgressProof"] = true
						home_connector_proof["sourceCollisionRevision"] = String(verified_route.get("sourceCollisionRevision", ""))
					break
			var candidate_probes: Array[Dictionary] = []
			for candidate_index in range(stand_candidates.size()):
				var candidate_cell: Vector2i = stand_candidates[candidate_index]
				var candidate_position := Vector3(float(candidate_cell.x) * cell_size, bed_walk_level, float(candidate_cell.y) * cell_size)
				var candidate_support := support_for_position(navigation_supports, candidate_position)
				candidate_probes.append({
					"id": "candidate_%d" % candidate_index,
					"candidateIndex": candidate_index,
					"position": candidate_position,
					"supportId": String(candidate_support.get("id", "")),
					"snapDistance": home_start_snap_distance
				})
			var candidate_resolution_result: Dictionary = {}
			if stand_cell != INVALID_CELL:
				candidate_resolution_result = {"reusedEgressProof": true, "sourceCollisionRevision": String(source_navigation_adapter.cached_revision)}
			elif require_reachable_home:
				candidate_resolution_result = source_navigation_adapter._source_support_reachable_probe_resolutions(
					String(shell.get("doorInteriorSupportId", "")),
					candidate_probes,
					{
						"id": "door_interior",
						"position": shell.get("doorInteriorPosition", Vector3.INF),
						"supportId": String(shell.get("doorInteriorSupportId", "")),
						"snapDistance": home_start_snap_distance
					},
					home_start_snap_distance
				)
			else:
				candidate_resolution_result = source_navigation_adapter._source_support_probe_resolutions(
					String(shell.get("doorInteriorSupportId", "")),
					candidate_probes,
					home_start_snap_distance,
					false
				)
			if bool(candidate_resolution_result.get("incomplete", false)):
				# Publication capacity/readiness is not a geometric rejection of a bed.
				result["incomplete"] = true
				result["status"] = candidate_resolution_result.get("status", "failed")
				result["reason"] = candidate_resolution_result.get("reason", "home_support_analysis_incomplete")
				result["residences"] = []
				result["citizens"] = []
				return result
			for candidate_resolution_value in candidate_resolution_result.get("resolutions", []) as Array:
				var candidate_resolution: Dictionary = candidate_resolution_value as Dictionary
				var sample_position: Vector3 = candidate_resolution.get("position", Vector3.INF) as Vector3
				var sample_proven := bool(candidate_resolution.get("resolved", false)) and (not require_reachable_home or bool(candidate_resolution.get("reachableToTarget", false)))
				if not sample_proven or not stand_position_inside_room(sample_position, room, world_origin):
					continue
				stand_position = sample_position
				stand_cell = cell_for_position(stand_position, cell_size)
				home_connector_proof = candidate_resolution
				home_connector_proof["usesExactSupportSample"] = true
				break
			if stand_cell == INVALID_CELL:
				result["unassignedBeds"].append(String(bed.id))
				result["unassignedBedDiagnostics"].append({
					"bedPartId": String(bed.id),
					"residenceId": residence_id,
					"roomId": String(bed.room_id),
					"bedPosition": bed.position + world_origin,
					"bedroomBounds": bedroom_bounds,
					"doorPartId": String(door.id),
					"doorNavigation": navigation_door_for_part(navigation_doors, String(door.id)),
					"residenceShell": shell,
					"candidateCells": stand_candidates,
					"candidateResolution": candidate_resolution_result
				})
				continue
			used_stand_cells[cell_key(stand_cell)] = true
			var citizen_id := "citadel:%s:%s:%s" % [blueprint_id, residence_id, String(bed.id)]
			var citizen := shell.duplicate(true)
			# A resident's home elevation belongs to the bed/furnishing source it was
			# assigned, not the lower edge of a doorway.  The latter is intentionally
			# recessed into the threshold while the bed sits on the completed interior
			# floor; using it made a real capsule overlap the published floor collider.
			citizen.merge({
				"id": citizen_id,
				"homeStableId": "citadel-home:%s:%s" % [blueprint_id, residence_id],
				"homeKey": stable_home_key(blueprint_id, residence_id),
				"residenceId": residence_id,
				"bedPartId": String(bed.id),
				"bedRoomId": String(bed.room_id),
				"bedCell": cell_for_position(bed.position + world_origin, cell_size),
				"homeCell": stand_cell,
				"homePosition": stand_position,
				"homeSupportId": String(home_connector_proof.get("supportId", "")),
				"interiorLandingCell": shell.get("interiorLandingCell", stand_cell),
				"job": "civic",
				"role": "Citizen",
				"canFight": false,
				"nightGuard": false,
				"doorLevel": float(shell.get("level", 0.0)),
				"level": bed_walk_level,
				"homeConnectorProof": home_connector_proof
			}, true)
			result["citizens"].append(citizen)
			citizen_count += 1
		var residence_summary := shell.duplicate(true)
		residence_summary["residenceId"] = residence_id
		residence_summary["bedCount"] = resident_beds.size()
		residence_summary["citizenCount"] = citizen_count
		result["residences"].append(residence_summary)
	return result


static func deterministic_signature(manifest: Dictionary) -> String:
	return JSON.stringify(manifest)

static func validate_semantic_completeness(manifest: Dictionary) -> Dictionary:
	var failures: Array[String] = []
	if bool(manifest.get("incomplete", false)):
		failures.append("navigation_analysis_incomplete:%s" % String(manifest.get("reason", "unknown")))
	var residences: Array = manifest.get("residences", []) if manifest.get("residences", []) is Array else []
	var citizens: Array = manifest.get("citizens", []) if manifest.get("citizens", []) is Array else []
	if residences.is_empty():
		failures.append("residences_missing")
	if citizens.is_empty():
		failures.append("citizens_missing")
	if not (manifest.get("missingDoors", []) as Array).is_empty():
		failures.append("residence_doors_missing")
	if not (manifest.get("unassignedBeds", []) as Array).is_empty():
		failures.append("beds_unassigned")
	var passage_rejections: Array = manifest.get("navigationPassageRejections", []) as Array
	if not passage_rejections.is_empty():
		failures.append("navigation_passages_rejected:%s" % JSON.stringify(passage_rejections.slice(0, 12)))
	for residence_value in residences:
		var residence: Dictionary = residence_value as Dictionary
		if int(residence.get("bedCount", 0)) <= 0:
			failures.append("%s_has_no_bed" % String(residence.get("residenceId", "residence")))
		if int(residence.get("citizenCount", 0)) <= 0:
			failures.append("%s_has_no_citizen" % String(residence.get("residenceId", "residence")))
	return {"passed": failures.is_empty(), "failures": failures, "residenceCount": residences.size(), "citizenCount": citizens.size()}


static func sorted_residences(raw_residences: Array) -> Array:
	var result: Array = []
	for value in raw_residences:
		if value is Dictionary:
			result.append((value as Dictionary).duplicate(true))
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("id", "")) < String(b.get("id", ""))
	)
	return result


static func room_records_by_id(raw_rooms: Array) -> Dictionary:
	var result := {}
	for value in raw_rooms:
		if not (value is Dictionary):
			continue
		var room: Dictionary = value
		var room_id := String(room.get("id", "")).strip_edges()
		if not room_id.is_empty():
			result[room_id] = room.duplicate(true)
	return result


static func beds_by_residence(furnishing_plan) -> Dictionary:
	var result := {}
	for part in furnishing_plan.parts:
		if part == null or String(part.archetype) != "bed":
			continue
		var residence_id := String(part.recipe.get("castleResidenceId", "")).strip_edges()
		if residence_id.is_empty():
			continue
		if not result.has(residence_id):
			result[residence_id] = []
		(result[residence_id] as Array).append(part)
	for residence_id in result.keys():
		(result[residence_id] as Array).sort_custom(func(a, b) -> bool:
			return String(a.id) < String(b.id)
		)
	return result


static func residence_door_part(parts: Array, residence_id: String):
	var prefix := "castle_%s__" % residence_id
	var matched: Array = []
	for part in parts:
		if part == null or String(part.kind) != "door":
			continue
		if String(part.id).begins_with(prefix):
			matched.append(part)
	matched.sort_custom(func(a, b) -> bool:
		return String(a.id) < String(b.id)
	)
	return matched[0] if not matched.is_empty() else null


static func residence_shell(residence: Dictionary, door, blueprint_id: String, cell_size: float, world_origin: Vector3, navigation_supports: Array = [], navigation_doors: Array = []) -> Dictionary:
	var center: Vector3 = (residence.get("center", Vector3.ZERO) as Vector3) + world_origin
	var width := maxf(cell_size, float(residence.get("width", cell_size * 3.0)))
	var depth := maxf(cell_size, float(residence.get("depth", cell_size * 3.0)))
	var door_position: Vector3 = door.position + world_origin
	var walk_level := door_position.y - maxf(0.0, door.size.y * 0.5)
	var door_cell := cell_for_position(door_position, cell_size)
	var outward := outward_cell_direction(float(residence.get("yaw", 0.0)), center, door_cell, cell_size)
	var porch_cell := door_cell + outward
	var door_navigation := navigation_door_for_part(navigation_doors, String(door.id))
	var door_interior_position := door_navigation.get("interior", Vector3.INF) as Vector3
	var door_exterior_position := door_navigation.get("exterior", Vector3.INF) as Vector3
	# Thick authored walls can put the finite door-fact exterior endpoint more than one
	# gameplay cell from the door part's center. The published door manifest owns
	# that geometry. Prefer one clear cell beyond its exterior endpoint, but keep
	# the porch on the endpoint's support when a compact landing does not
	# extend another complete gameplay cell outward.
	if door_exterior_position.is_finite():
		porch_cell = cell_for_position(door_exterior_position, cell_size) + outward
	var porch_y := door_exterior_position.y if door_exterior_position.is_finite() else walk_level + 0.04
	var porch_position := Vector3(float(porch_cell.x) * cell_size, porch_y, float(porch_cell.y) * cell_size)
	var porch_support := support_for_position(navigation_supports, porch_position)
	if porch_support.is_empty() and door_exterior_position.is_finite():
		porch_cell = cell_for_position(door_exterior_position, cell_size)
		porch_position = Vector3(float(porch_cell.x) * cell_size, door_exterior_position.y, float(porch_cell.y) * cell_size)
		porch_support = support_for_position(navigation_supports, porch_position)
	if not porch_support.is_empty():
		porch_position.y = support_surface_y(porch_support, porch_position) + 0.04
	if not door_interior_position.is_finite():
		var fallback_outward := Vector3(float(outward.x), 0.0, float(outward.y))
		door_interior_position = door_position - fallback_outward * cell_size
		door_interior_position.y = walk_level + 0.04
	var interior_landing := door_cell - outward
	var interior_inset := RESIDENT_STAND_RADIUS + RESIDENT_WALL_MARGIN
	var min_cell := Vector2i(
		ceil_to_cell(center.x - width * 0.5 + interior_inset, cell_size),
		ceil_to_cell(center.z - depth * 0.5 + interior_inset, cell_size)
	)
	var max_cell := Vector2i(
		floor_to_cell(center.x + width * 0.5 - interior_inset, cell_size),
		floor_to_cell(center.z + depth * 0.5 - interior_inset, cell_size)
	)
	min_cell = Vector2i(mini(min_cell.x, max_cell.x), mini(min_cell.y, max_cell.y))
	max_cell = Vector2i(maxi(min_cell.x, max_cell.x), maxi(min_cell.y, max_cell.y))
	if not cell_inside_bounds(interior_landing, min_cell, max_cell):
		interior_landing = nearest_cell_in_bounds(interior_landing, min_cell, max_cell)
	return {
		"doorPartId": String(door.id),
		"doorPortalId": "building:%s:%s" % [blueprint_id, String(door.id)],
		"doorCell": door_cell,
		"porchCell": porch_cell,
		"porchPosition": porch_position,
		"porchSupportId": String(porch_support.get("id", "")),
		"doorInteriorPosition": door_interior_position,
		"doorInteriorSupportId": String(door_navigation.get("interiorSupportId", "")),
		"doorExteriorPosition": door_exterior_position,
		"doorExteriorSupportId": String(door_navigation.get("exteriorSupportId", "")),
		"interiorLandingCell": interior_landing,
		"interiorMinCell": min_cell,
		"interiorMaxCell": max_cell,
		"outward": outward,
		"townCenter": cell_for_position(center, cell_size),
		"townRadius": maxi(12, ceili(maxf(width, depth) / cell_size) + 8),
		"doorLevel": walk_level,
		"level": walk_level
	}


static func navigation_door_for_part(doors: Array, source_part_id: String) -> Dictionary:
	if source_part_id.is_empty():
		return {}
	for door_value in doors:
		if not (door_value is Dictionary):
			continue
		var door: Dictionary = door_value as Dictionary
		if String(door.get("sourcePartId", "")) == source_part_id:
			return door
	return {}


static func support_for_position(supports: Array, position: Vector3) -> Dictionary:
	var result: Dictionary = {}
	var nearest_vertical_distance := INF
	var resolved_surface_y := -INF
	for support_value in supports:
		if not (support_value is Dictionary):
			continue
		var support: Dictionary = support_value
		if not point_within_support_xz(position, support):
			continue
		var support_y := support_surface_y(support, position)
		var vertical_distance := absf(support_y + 0.04 - position.y)
		if vertical_distance < nearest_vertical_distance - 0.0001 or (is_equal_approx(vertical_distance, nearest_vertical_distance) and support_y > resolved_surface_y):
			result = support
			nearest_vertical_distance = vertical_distance
			resolved_surface_y = support_y
	return result


static func point_within_support_xz(position: Vector3, support: Dictionary) -> bool:
	var polygon: Array = support.get("polygon", []) if support.get("polygon", []) is Array else []
	if polygon.size() < 3:
		return false
	var inside := false
	var previous: Vector3 = polygon[polygon.size() - 1] if polygon[polygon.size() - 1] is Vector3 else Vector3.ZERO
	for point_value in polygon:
		if not (point_value is Vector3):
			return false
		var point: Vector3 = point_value
		var crosses := (point.z > position.z) != (previous.z > position.z)
		if crosses:
			var denominator := previous.z - point.z
			if absf(denominator) > 0.000001:
				var x_at_z := (previous.x - point.x) * (position.z - point.z) / denominator + point.x
				if position.x < x_at_z:
					inside = not inside
		previous = point
	return inside


static func support_surface_y(support: Dictionary, position: Vector3) -> float:
	var polygon: Array = support.get("polygon", []) if support.get("polygon", []) is Array else []
	if polygon.size() >= 3 and polygon[0] is Vector3 and polygon[1] is Vector3 and polygon[2] is Vector3:
		var a: Vector3 = polygon[0]
		var b: Vector3 = polygon[1]
		var c: Vector3 = polygon[2]
		var normal := (b - a).cross(c - a)
		if absf(normal.y) > 0.0001:
			return a.y - (normal.x * (position.x - a.x) + normal.z * (position.z - a.z)) / normal.y
	var center: Vector3 = support.get("worldPosition", position) if support.get("worldPosition", position) is Vector3 else position
	return center.y


static func cell_bounds_for_room(room: Dictionary, shell: Dictionary, cell_size: float, world_origin: Vector3) -> Dictionary:
	var bounds: AABB = room.get("bounds", AABB()) as AABB
	bounds.position += world_origin
	if bounds.size == Vector3.ZERO:
		return {
			"min": shell.get("interiorMinCell", Vector2i.ZERO),
			"max": shell.get("interiorMaxCell", Vector2i.ZERO)
		}
	var margin := RESIDENT_STAND_RADIUS
	var min_cell := Vector2i(
		ceil_to_cell(bounds.position.x + margin, cell_size),
		ceil_to_cell(bounds.position.z + margin, cell_size)
	)
	var max_cell := Vector2i(
		floor_to_cell(bounds.end.x - margin, cell_size),
		floor_to_cell(bounds.end.z - margin, cell_size)
	)
	var shell_min: Vector2i = shell.get("interiorMinCell", min_cell)
	var shell_max: Vector2i = shell.get("interiorMaxCell", max_cell)
	min_cell = Vector2i(maxi(min_cell.x, shell_min.x), maxi(min_cell.y, shell_min.y))
	max_cell = Vector2i(mini(max_cell.x, shell_max.x), mini(max_cell.y, shell_max.y))
	if min_cell.x > max_cell.x or min_cell.y > max_cell.y:
		return {"min": shell_min, "max": shell_max}
	return {"min": min_cell, "max": max_cell}


static func stand_position_inside_room(position: Vector3, room: Dictionary, world_origin: Vector3) -> bool:
	if not position.is_finite():
		return false
	var bounds: AABB = room.get("bounds", AABB()) as AABB
	bounds.position += world_origin
	if bounds.size == Vector3.ZERO:
		return false
	return position.x >= bounds.position.x + RESIDENT_STAND_RADIUS and position.x <= bounds.end.x - RESIDENT_STAND_RADIUS \
		and position.z >= bounds.position.z + RESIDENT_STAND_RADIUS and position.z <= bounds.end.z - RESIDENT_STAND_RADIUS


static func bed_stand_cell_candidates(bed, bedroom_bounds: Dictionary, shell: Dictionary, used: Dictionary, furnishing_plan, cell_size: float, world_origin: Vector3) -> Array[Vector2i]:
	var minimum: Vector2i = bedroom_bounds.get("min", shell.get("interiorMinCell", Vector2i.ZERO))
	var maximum: Vector2i = bedroom_bounds.get("max", shell.get("interiorMaxCell", Vector2i.ZERO))
	var bed_cell := cell_for_position(bed.position + world_origin, cell_size)
	var yaw := float(bed.rotation.y)
	var forward := normalized_cell_direction(Vector2i(roundi(-sin(yaw)), roundi(-cos(yaw))))
	var right := normalized_cell_direction(Vector2i(roundi(cos(yaw)), roundi(-sin(yaw))))
	var candidates := [
		bed_cell + forward * 2,
		bed_cell - forward * 2,
		bed_cell + right * 2,
		bed_cell - right * 2,
		bed_cell + forward,
		bed_cell - forward,
		bed_cell + right,
		bed_cell - right
	]
	var result: Array[Vector2i] = []
	var seen := {}
	for candidate in candidates:
		if candidate == shell.get("doorCell", INVALID_CELL):
			continue
		if cell_inside_bounds(candidate, minimum, maximum) and not used.has(cell_key(candidate)) and resident_stand_cell_is_clear(candidate, bed, furnishing_plan, cell_size, world_origin):
			result.append(candidate)
			seen[cell_key(candidate)] = true
	for z in range(minimum.y, maximum.y + 1):
		for x in range(minimum.x, maximum.x + 1):
			var candidate := Vector2i(x, z)
			if candidate != shell.get("doorCell", INVALID_CELL) and not seen.has(cell_key(candidate)) and not used.has(cell_key(candidate)) and resident_stand_cell_is_clear(candidate, bed, furnishing_plan, cell_size, world_origin):
				result.append(candidate)
				seen[cell_key(candidate)] = true
	return result


static func resident_stand_cell_is_clear(cell: Vector2i, bed, furnishing_plan, cell_size: float, world_origin: Vector3) -> bool:
	if furnishing_plan == null:
		return false
	var position := Vector3(float(cell.x) * cell_size, bed.position.y + world_origin.y, float(cell.y) * cell_size)
	for part in furnishing_plan.parts:
		if part == null or not bool(part.collision_enabled):
			continue
		var part_base_y: float = part.position.y + world_origin.y
		var part_top_y: float = part_base_y + part.occupied_size.y
		if part_top_y < position.y + 0.04 or part_base_y > position.y + RESIDENT_STANDING_HEIGHT:
			continue
		var bounds := horizontal_bounds(part.position + world_origin, part.occupied_size, part.rotation, RESIDENT_STAND_RADIUS)
		if point_inside_horizontal_bounds(position, bounds):
			return false
	return true


static func furnishing_egress_path(citizen: Dictionary, furnishing_plan, building_navigation_manifest: Dictionary, cell_size := DEFAULT_CELL_SIZE, world_origin := Vector3.ZERO) -> Dictionary:
	var start_cell: Vector2i = citizen.get("homeCell", INVALID_CELL)
	if start_cell == INVALID_CELL or furnishing_plan == null:
		return {"reachable": false, "reason": "missing_residence_cells"}
	var passage_rejections: Array = building_navigation_manifest.get("interiorPassageRejections", []) as Array
	if not passage_rejections.is_empty():
		return {"reachable": false, "reason": "navigation_passage_manifest_rejected", "rejections": passage_rejections.slice(0, 12)}
	var home_level := float(citizen.get("level", 0.0))
	var door_level := float(citizen.get("doorLevel", citizen.get("level", 0.0)))
	var target_position: Vector3 = citizen.get("doorInteriorPosition", Vector3.INF) as Vector3
	if not target_position.is_finite():
		var target_cell: Vector2i = citizen.get("interiorLandingCell", INVALID_CELL)
		if target_cell == INVALID_CELL:
			return {"reachable": false, "reason": "missing_door_interior_target"}
		target_position = Vector3(float(target_cell.x) * cell_size, door_level, float(target_cell.y) * cell_size)
	var start_position: Vector3 = citizen.get("homePosition", Vector3.INF) as Vector3
	if not start_position.is_finite():
		start_position = Vector3(float(start_cell.x) * cell_size, home_level, float(start_cell.y) * cell_size)
	var support_id := String(citizen.get("doorInteriorSupportId", ""))
	if support_id.is_empty():
		var support := support_for_position(building_navigation_manifest.get("supports", []) as Array, target_position)
		support_id = String(support.get("id", ""))
	var furnishing_manifest := FurnishingNavigationManifestBuilderScript.build(furnishing_plan, Transform3D(Basis.IDENTITY, world_origin))
	var snap_policy := NpcConstantsScript.route_snap_distances("home", cell_size * 0.75, false)
	var start_snap_distance := float(snap_policy.get("start", cell_size * 0.95))
	var target_snap_distance := float(snap_policy.get("target", cell_size * 0.95))
	return BuildingLayoutClearanceScript.source_support_connectivity(
		building_navigation_manifest,
		[furnishing_manifest],
		support_id,
		[
			{"id": "home", "position": start_position, "supportId": String(citizen.get("homeSupportId", "")), "snapDistance": start_snap_distance},
			{"id": "door_interior", "position": target_position, "supportId": support_id, "snapDistance": target_snap_distance}
		],
		maxf(start_snap_distance, target_snap_distance)
	)


static func furnishing_egress_paths(citizens: Array, furnishing_plan, building_navigation_manifest: Dictionary, cell_size := DEFAULT_CELL_SIZE, world_origin := Vector3.ZERO) -> Dictionary:
	if furnishing_plan == null or not (building_navigation_manifest.get("interiorPassageRejections", []) as Array).is_empty():
		return {}
	var furnishing_manifest := FurnishingNavigationManifestBuilderScript.build(furnishing_plan, Transform3D(Basis.IDENTITY, world_origin))
	var requests: Array[Dictionary] = []
	for citizen_value in citizens:
		if not (citizen_value is Dictionary):
			continue
		var citizen: Dictionary = citizen_value
		var citizen_id := String(citizen.get("id", ""))
		var start_cell: Vector2i = citizen.get("homeCell", INVALID_CELL)
		var start_position: Vector3 = citizen.get("homePosition", Vector3.INF) as Vector3
		var target_position: Vector3 = citizen.get("doorInteriorPosition", Vector3.INF) as Vector3
		var support_id := String(citizen.get("doorInteriorSupportId", ""))
		if citizen_id.is_empty() or start_cell == INVALID_CELL or not start_position.is_finite() or not target_position.is_finite() or support_id.is_empty():
			continue
		var snap_policy := NpcConstantsScript.route_snap_distances("home", cell_size * 0.75, false)
		var start_snap_distance := float(snap_policy.get("start", cell_size * 0.95))
		var target_snap_distance := float(snap_policy.get("target", cell_size * 0.95))
		requests.append({
			"id": citizen_id,
			"supportId": support_id,
			"snapDistance": maxf(start_snap_distance, target_snap_distance),
			"probes": [
				{"id": "home", "position": start_position, "supportId": String(citizen.get("homeSupportId", "")), "snapDistance": start_snap_distance},
				{"id": "door_interior", "position": target_position, "supportId": support_id, "snapDistance": target_snap_distance}
			]
		})
	return BuildingLayoutClearanceScript.source_support_connectivities(building_navigation_manifest, [furnishing_manifest], requests)


static func horizontal_bounds(position: Vector3, size: Vector3, rotation: Vector3, padding: float) -> AABB:
	var yaw := rotation.y
	var half_x := absf(cos(yaw)) * size.x * 0.5 + absf(sin(yaw)) * size.z * 0.5 + padding
	var half_z := absf(sin(yaw)) * size.x * 0.5 + absf(cos(yaw)) * size.z * 0.5 + padding
	return AABB(Vector3(position.x - half_x, position.y, position.z - half_z), Vector3(half_x * 2.0, size.y, half_z * 2.0))


static func point_inside_horizontal_bounds(position: Vector3, bounds: AABB) -> bool:
	return position.x >= bounds.position.x and position.x <= bounds.end.x and position.z >= bounds.position.z and position.z <= bounds.end.z


static func outward_cell_direction(yaw: float, center: Vector3, door_cell: Vector2i, cell_size: float) -> Vector2i:
	var candidate := normalized_cell_direction(Vector2i(roundi(-sin(yaw)), roundi(-cos(yaw))))
	if candidate != Vector2i.ZERO:
		return candidate
	var center_cell := cell_for_position(center, cell_size)
	return normalized_cell_direction(door_cell - center_cell)


static func normalized_cell_direction(value: Vector2i) -> Vector2i:
	if value == Vector2i.ZERO:
		return Vector2i.ZERO
	if absi(value.x) >= absi(value.y):
		return Vector2i(1 if value.x >= 0 else -1, 0)
	return Vector2i(0, 1 if value.y >= 0 else -1)


static func cell_for_position(position: Vector3, cell_size: float) -> Vector2i:
	return Vector2i(roundi(position.x / cell_size), roundi(position.z / cell_size))


static func ceil_to_cell(value: float, cell_size: float) -> int:
	return ceili(value / cell_size)


static func floor_to_cell(value: float, cell_size: float) -> int:
	return floori(value / cell_size)


static func cell_inside_bounds(cell: Vector2i, minimum: Vector2i, maximum: Vector2i) -> bool:
	return cell.x >= minimum.x and cell.x <= maximum.x and cell.y >= minimum.y and cell.y <= maximum.y


static func nearest_cell_in_bounds(cell: Vector2i, minimum: Vector2i, maximum: Vector2i) -> Vector2i:
	return Vector2i(clampi(cell.x, minimum.x, maximum.x), clampi(cell.y, minimum.y, maximum.y))


static func stable_home_key(blueprint_id: String, residence_id: String) -> int:
	return abs(("%s|%s" % [blueprint_id, residence_id]).hash())


static func cell_key(cell: Vector2i) -> String:
	return "%d,%d" % [cell.x, cell.y]
