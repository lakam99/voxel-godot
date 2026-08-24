extends SceneTree

## A focused procedural-navigation contract. It validates source-manifest door
## endpoints against their physical support ownership; it does not prove live
## collision, route execution, door animation, or player traversal.

const CastleCompoundBlueprintBuilderScript := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const BuildingNavigationManifestBuilderScript := preload("res://scripts/buildings/BuildingNavigationManifestBuilder.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

const SEEDS: Array[int] = [208158, 208159, 306701, 724169]
const ENDPOINT_SURFACE_OFFSET := 0.04
const DOOR_PORTAL_CLEARANCE := NpcConstantsScript.DEFAULT_NPC_RADIUS + NpcConstantsScript.DEFAULT_PERSONAL_SPACE_MARGIN
const MAX_SUPPORT_PLANE_DELTA := NpcConstantsScript.CELL_SIZE * 0.82

var failures: Array[String] = []
var report_path := ""


func _initialize() -> void:
	call_deferred("run_contract")


func run_contract() -> void:
	report_path = OS.get_environment("VOXEL_CITADEL_DOOR_PORTAL_CONTRACT_REPORT").strip_edges()
	if report_path.is_empty():
		report_path = ProjectSettings.globalize_path("res://artifacts/buildings/citadel-door-portal-contract.json")
	var rows: Array[Dictionary] = []
	for seed in requested_seeds():
		rows.append(verify_seed(seed))
	var report := {
		"runnerId": "citadel_door_portal_contract",
		"evidenceLevel": "contract",
		"scope": "Source-manifest door endpoints bind to collision-bearing procedural supports. It does not prove live collision, route execution, door animation, player traversal, or NPC behaviour.",
		"passed": failures.is_empty(),
		"rows": rows,
		"failures": failures
	}
	write_report(report)
	print(JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)


func requested_seeds() -> Array[int]:
	var raw := OS.get_environment("VOXEL_CITADEL_DOOR_PORTAL_CONTRACT_SEEDS").strip_edges()
	if raw.is_empty():
		return SEEDS.duplicate()
	var result: Array[int] = []
	for value in raw.split(",", false):
		var seed_text := String(value).strip_edges()
		if seed_text.is_valid_int():
			result.append(seed_text.to_int())
	return result if not result.is_empty() else SEEDS.duplicate()


func verify_seed(seed: int) -> Dictionary:
	var castle = CastleCompoundBlueprintBuilderScript.build(seed, {
		"biome": "forest",
		"siteKey": "citadel-door-portal-contract",
		"citadelScale": 1.25
	})
	var navigation_manifest := BuildingNavigationManifestBuilderScript.build(castle)
	var support_by_id := {}
	for support_value in navigation_manifest.get("supports", []) as Array:
		if support_value is Dictionary:
			var support: Dictionary = support_value
			support_by_id[String(support.get("id", ""))] = support
	var door_by_part_id := {}
	for door_value in navigation_manifest.get("doors", []) as Array:
		if door_value is Dictionary:
			var door: Dictionary = door_value
			door_by_part_id[String(door.get("sourcePartId", ""))] = door
	var part_by_id := {}
	for part in castle.parts:
		if part != null:
			part_by_id[String(part.id)] = part
	var static_collision: Array[Dictionary] = []
	for collision_value in navigation_manifest.get("staticCollision", []) as Array:
		if collision_value is Dictionary:
			static_collision.append(collision_value as Dictionary)
	var proofs: Array[Dictionary] = []
	for door_part in residence_door_parts(castle):
		var source_part_id := String(door_part.id)
		var door: Dictionary = door_by_part_id.get(source_part_id, {}) as Dictionary
		var interior_support_id := String(door.get("interiorSupportId", ""))
		var exterior_support_id := String(door.get("exteriorSupportId", ""))
		var interior_support: Dictionary = support_by_id.get(interior_support_id, {}) as Dictionary
		var exterior_support: Dictionary = support_by_id.get(exterior_support_id, {}) as Dictionary
		var owner_prefix := source_part_id.left(source_part_id.find("__") + 2) if source_part_id.find("__") >= 0 else ""
		check(not door.is_empty(), "seed %d residence door %s is missing from the navigation manifest" % [seed, source_part_id])
		check(bool(door.get("sourcePortalReady", false)), "seed %d residence door %s failed source support staging: %s" % [seed, source_part_id, JSON.stringify(door.get("portalSupportResolution", {}))])
		var interior: Vector3 = door.get("interior", Vector3.INF) as Vector3
		var exterior: Vector3 = door.get("exterior", Vector3.INF) as Vector3
		var interior_tile_key := tile_key_for_position(interior)
		var exterior_tile_key := tile_key_for_position(exterior)
		check(String(door.get("interiorTileKey", "")) == interior_tile_key, "seed %d residence door %s interior tile ownership does not match the resolved endpoint" % [seed, source_part_id])
		check(String(door.get("exteriorTileKey", "")) == exterior_tile_key, "seed %d residence door %s exterior tile ownership does not match the resolved endpoint" % [seed, source_part_id])
		check(String(door.get("ownerTileKey", "")) == interior_tile_key, "seed %d residence door %s owner tile must be its resolved interior endpoint tile" % [seed, source_part_id])
		check(not interior_support.is_empty(), "seed %d residence door %s has no interior support" % [seed, source_part_id])
		check(not exterior_support.is_empty(), "seed %d residence door %s has no exterior support" % [seed, source_part_id])
		if not owner_prefix.is_empty() and not interior_support.is_empty():
			check(String(interior_support.get("sourcePartId", "")).begins_with(owner_prefix), "seed %d residence door %s interior support is not owned by its procedural residence: %s" % [seed, source_part_id, String(interior_support.get("sourcePartId", ""))])
			check(String(interior_support.get("kind", "")) == "floor", "seed %d residence door %s interior staging must select its finished floor, not %s" % [seed, source_part_id, String(interior_support.get("sourcePartId", ""))])
		var support_resolution: Dictionary = door.get("portalSupportResolution", {}) as Dictionary
		validate_endpoint(seed, source_part_id, "interior", interior, interior_support, support_resolution.get("interior", {}) as Dictionary)
		validate_endpoint(seed, source_part_id, "exterior", exterior, exterior_support, support_resolution.get("exterior", {}) as Dictionary)
		var egress_seam := validate_public_egress_seam(seed, door_part, owner_prefix, part_by_id, support_by_id, navigation_manifest.get("supports", []) as Array, static_collision)
		proofs.append({
			"sourcePartId": source_part_id,
			"sourcePortalReady": bool(door.get("sourcePortalReady", false)),
			"interiorSupportId": interior_support_id,
			"interiorSupportPartId": String(interior_support.get("sourcePartId", "")),
			"exteriorSupportId": exterior_support_id,
			"exteriorSupportPartId": String(exterior_support.get("sourcePartId", "")),
			"interior": interior,
			"exterior": exterior,
			"interiorTileKey": interior_tile_key,
			"exteriorTileKey": exterior_tile_key,
			"ownerTileKey": String(door.get("ownerTileKey", "")),
			"portalSupportResolution": door.get("portalSupportResolution", {}),
			"publicEgressSeam": egress_seam
		})
	return {"seed": seed, "doorCount": proofs.size(), "proofs": proofs}


func residence_door_parts(castle) -> Array:
	var result: Array = []
	for part in castle.parts:
		if part != null and String(part.kind) == "door" and String(part.id).contains("castle_courtyard_"):
			result.append(part)
	result.sort_custom(func(first, second) -> bool: return String(first.id) < String(second.id))
	return result


func validate_endpoint(seed: int, source_part_id: String, side: String, endpoint: Vector3, support: Dictionary, resolution: Dictionary) -> void:
	check(endpoint.is_finite(), "seed %d residence door %s %s endpoint is not finite" % [seed, source_part_id, side])
	check(bool(resolution.get("resolved", false)), "seed %d residence door %s %s staging resolution is not ready" % [seed, source_part_id, side])
	if support.is_empty() or not endpoint.is_finite():
		return
	var selected: Vector3 = resolution.get("selectedPosition", Vector3.INF) as Vector3
	check(selected.is_finite() and selected.distance_to(endpoint) <= 0.001, "seed %d residence door %s %s selected staging position does not match the published endpoint" % [seed, source_part_id, side])
	check(point_within_support_xz(endpoint, support), "seed %d residence door %s %s endpoint is outside its selected support polygon" % [seed, source_part_id, side])
	var clearance := support_edge_clearance(endpoint, support)
	check(clearance + 0.0001 >= DOOR_PORTAL_CLEARANCE, "seed %d residence door %s %s endpoint has %.3f support clearance; requires %.3f" % [seed, source_part_id, side, clearance, DOOR_PORTAL_CLEARANCE])
	var support_y := support_surface_y(support, endpoint)
	check(absf(endpoint.y - (support_y + ENDPOINT_SURFACE_OFFSET)) <= 0.001, "seed %d residence door %s %s endpoint does not lie on the support plane" % [seed, source_part_id, side])
	var requested_position: Vector3 = resolution.get("requestedPosition", Vector3.INF) as Vector3
	check(requested_position.is_finite() and absf(support_y - requested_position.y) <= MAX_SUPPORT_PLANE_DELTA + 0.0001, "seed %d residence door %s %s support plane delta exceeds the bounded staging contract" % [seed, source_part_id, side])


func validate_public_egress_seam(seed: int, door_part, owner_prefix: String, part_by_id: Dictionary, support_by_id: Dictionary, supports: Array, static_collision: Array[Dictionary]) -> Dictionary:
	var source_part_id := String(door_part.id)
	var egress: Dictionary = door_part.recipe.get("doorEgress", {}) as Dictionary
	var outward_part_id := String(egress.get("outwardEndpointPartId", ""))
	check(not outward_part_id.is_empty(), "seed %d residence door %s has no declared outward egress part" % [seed, source_part_id])
	if outward_part_id.is_empty():
		return {"passed": false, "reason": "missing_outward_egress"}
	var transition_id := "%s%s" % [owner_prefix, outward_part_id]
	var transition = part_by_id.get(transition_id, null)
	check(transition != null, "seed %d residence door %s outward egress part %s is missing" % [seed, source_part_id, transition_id])
	if transition == null:
		return {"passed": false, "reason": "missing_transition", "transitionPartId": transition_id}
	var transition_support: Dictionary = support_by_id.get("building:compound.castle.%d.citadel-door-portal-contract:support:%s" % [seed, transition_id], {}) as Dictionary
	check(not transition_support.is_empty(), "seed %d residence door %s outward egress has no published walkable support" % [seed, source_part_id])
	var transform := Transform3D(Basis.from_euler(transition.rotation), transition.position)
	var first: Vector3 = transform * Vector3(0.0, transition.size.y * 0.5, -transition.size.z * 0.5)
	var second: Vector3 = transform * Vector3(0.0, transition.size.y * 0.5, transition.size.z * 0.5)
	var outer := first if first.y <= second.y else second
	var inner := second if first.y <= second.y else first
	var outward := outer - inner
	outward.y = 0.0
	if outward.length_squared() <= 0.0001:
		outward = Vector3.FORWARD
	else:
		outward = outward.normalized()
	var public_position := outer + outward * 0.06
	var public_support := public_support_at(supports, public_position, owner_prefix)
	check(not public_support.is_empty(), "seed %d residence door %s transition has no public walkable seam" % [seed, source_part_id])
	if public_support.is_empty():
		return {"passed": false, "reason": "missing_public_support", "transitionPartId": transition_id, "outerPosition": outer}
	var public_surface_y := support_surface_y(public_support, public_position)
	var slope_delta := absf(public_surface_y - outer.y)
	check(slope_delta <= 0.08, "seed %d residence door %s transition/public support seam differs by %.3f" % [seed, source_part_id, slope_delta])
	var public_surface_position := public_position
	public_surface_position.y = public_surface_y
	var clearance_position := public_surface_position
	clearance_position.y += ENDPOINT_SURFACE_OFFSET
	var blocker := static_collision_at(clearance_position, static_collision)
	check(blocker.is_empty(), "seed %d residence door %s public egress seam intersects structural collision %s" % [seed, source_part_id, String(blocker.get("sourcePartId", ""))])
	return {
		"passed": not public_support.is_empty() and slope_delta <= 0.08 and blocker.is_empty(),
		"transitionPartId": transition_id,
		"transitionSupportId": String(transition_support.get("id", "")),
		"outerPosition": outer,
		"publicPosition": public_surface_position,
		"publicSupportId": String(public_support.get("id", "")),
		"slopeDelta": slope_delta,
		"blocker": blocker
	}


func public_support_at(supports: Array, position: Vector3, owner_prefix: String) -> Dictionary:
	for support_value in supports:
		if not (support_value is Dictionary):
			continue
		var support: Dictionary = support_value as Dictionary
		var source_part_id := String(support.get("sourcePartId", ""))
		if source_part_id.begins_with(owner_prefix) or not String(support.get("semantic", "")).contains("castle_courtyard_paving"):
			continue
		if point_within_support_xz(position, support):
			return support
	return {}


func static_collision_at(position: Vector3, static_collision: Array[Dictionary]) -> Dictionary:
	var clearance_bottom := position.y + 0.01
	var clearance_top := clearance_bottom + NpcConstantsScript.DEFAULT_NPC_STANDING_HEIGHT
	for fact in static_collision:
		var bounds: AABB = fact.get("bounds", AABB()) as AABB
		if bounds.end.y <= clearance_bottom or bounds.position.y >= clearance_top:
			continue
		if position.x + DOOR_PORTAL_CLEARANCE <= bounds.position.x or position.x - DOOR_PORTAL_CLEARANCE >= bounds.end.x:
			continue
		if position.z + DOOR_PORTAL_CLEARANCE <= bounds.position.z or position.z - DOOR_PORTAL_CLEARANCE >= bounds.end.z:
			continue
		return fact
	return {}


func point_within_support_xz(position: Vector3, support: Dictionary) -> bool:
	var polygon: Array = support.get("polygon", []) if support.get("polygon", []) is Array else []
	if polygon.size() < 3:
		return false
	var inside := false
	var previous: Vector3 = polygon[polygon.size() - 1] if polygon[polygon.size() - 1] is Vector3 else Vector3.ZERO
	for point_value in polygon:
		if not (point_value is Vector3):
			return false
		var point: Vector3 = point_value
		if (point.z > position.z) != (previous.z > position.z):
			var denominator := previous.z - point.z
			if absf(denominator) > 0.000001:
				var x_at_z := (previous.x - point.x) * (position.z - point.z) / denominator + point.x
				if position.x < x_at_z:
					inside = not inside
		previous = point
	return inside


func support_edge_clearance(position: Vector3, support: Dictionary) -> float:
	var polygon: Array = support.get("polygon", []) if support.get("polygon", []) is Array else []
	if polygon.size() < 3:
		return -INF
	var point := Vector2(position.x, position.z)
	var minimum_distance_squared := INF
	for index in range(polygon.size()):
		if not (polygon[index] is Vector3) or not (polygon[(index + 1) % polygon.size()] is Vector3):
			return -INF
		var first: Vector3 = polygon[index] as Vector3
		var second: Vector3 = polygon[(index + 1) % polygon.size()] as Vector3
		minimum_distance_squared = minf(minimum_distance_squared, point_to_segment_distance_squared(point, Vector2(first.x, first.z), Vector2(second.x, second.z)))
	return sqrt(maxf(0.0, minimum_distance_squared))


func point_to_segment_distance_squared(point: Vector2, first: Vector2, second: Vector2) -> float:
	var segment := second - first
	var length_squared := segment.length_squared()
	if length_squared <= 0.000001:
		return point.distance_squared_to(first)
	var ratio := clampf((point - first).dot(segment) / length_squared, 0.0, 1.0)
	return point.distance_squared_to(first + segment * ratio)


func support_surface_y(support: Dictionary, position: Vector3) -> float:
	var polygon: Array = support.get("polygon", []) if support.get("polygon", []) is Array else []
	if polygon.size() >= 3 and polygon[0] is Vector3 and polygon[1] is Vector3 and polygon[2] is Vector3:
		var first: Vector3 = polygon[0] as Vector3
		var second: Vector3 = polygon[1] as Vector3
		var third: Vector3 = polygon[2] as Vector3
		var normal := (second - first).cross(third - first)
		if absf(normal.y) > 0.0001:
			return first.y - (normal.x * (position.x - first.x) + normal.z * (position.z - first.z)) / normal.y
	return (support.get("worldPosition", position) as Vector3).y


func tile_key_for_position(position: Vector3) -> String:
	if not position.is_finite():
		return ""
	var cell_x := roundi(position.x / NpcConstantsScript.CELL_SIZE)
	var cell_z := roundi(position.z / NpcConstantsScript.CELL_SIZE)
	return "%d,%d" % [
		floori(float(cell_x) / float(NpcConstantsScript.NAV_TILE_CELL_SIZE)),
		floori(float(cell_z) / float(NpcConstantsScript.NAV_TILE_CELL_SIZE))
	]


func check(condition: bool, failure: String) -> void:
	if not condition:
		failures.append(failure)


func write_report(report: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
