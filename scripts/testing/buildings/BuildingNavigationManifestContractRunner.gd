extends SceneTree

## Focused VOX-223 source contract.  It proves that the construction blueprint
## produces deterministic, source-addressable walkable supports, physical
## stair links, and construction/furnishing collision facts. It deliberately
## does not claim live NPC movement or navmesh traversal; the Citadel Life
## fixture remains that evidence level.

const CastleCompoundBlueprintBuilderScript := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const CastleFurnishingPlannerScript := preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const BuildingNavigationManifestBuilderScript := preload("res://scripts/buildings/BuildingNavigationManifestBuilder.gd")
const FurnishingNavigationManifestBuilderScript := preload("res://scripts/buildings/FurnishingNavigationManifestBuilder.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

const SEEDS: Array[int] = [208158, 208159, 306701]
const CELL := NpcConstantsScript.CELL_SIZE

var failures: Array[String] = []
var report_path := ""


func _initialize() -> void:
	call_deferred("run_contract")


func run_contract() -> void:
	report_path = OS.get_environment("VOXEL_BUILDING_NAVIGATION_MANIFEST_REPORT").strip_edges()
	if report_path.is_empty():
		report_path = ProjectSettings.globalize_path("res://artifacts/buildings/building-navigation-manifest-contract.json")
	var rows: Array[Dictionary] = []
	for seed in SEEDS:
		rows.append(verify_seed(seed))
	var interior_passage_link_count := 0
	for row in rows:
		interior_passage_link_count += int(row.get("interiorPassageLinkCount", 0))
	check(interior_passage_link_count > 0, "navigation manifest contract published no collision-backed interior passage links across its seed set")
	var report := {
		"runnerId": "building_navigation_manifest_contract",
		"evidenceLevel": "contract",
		"scope": "Deterministic BuildingPart- and FurnishingPart-derived support, stair-link, doorway-anchor, rotated collision-footprint, and collision facts for layered buildings. It does not prove NavMesh installation, CharacterBody3D movement, live door traversal, or Citadel Life behavior.",
		"seeds": SEEDS,
		"passed": failures.is_empty(),
		"rows": rows,
		"failures": failures
	}
	write_report(report)
	print(JSON.stringify(report))
	quit(0 if failures.is_empty() else 1)


func verify_seed(seed: int) -> Dictionary:
	var context := {
		"biome": "forest",
		"siteKey": "building-navigation-contract",
		"citadelScale": 1.25
	}
	var first_blueprint = CastleCompoundBlueprintBuilderScript.build(seed, context)
	var replay_blueprint = CastleCompoundBlueprintBuilderScript.build(seed, context)
	var parent_transform := Transform3D(Basis.from_euler(Vector3(0.0, 0.37, 0.0)), Vector3(13.0, 2.5, -7.0))
	var manifest := BuildingNavigationManifestBuilderScript.build(first_blueprint, parent_transform)
	var replay := BuildingNavigationManifestBuilderScript.build(replay_blueprint, parent_transform)
	var furnishing_plan = CastleFurnishingPlannerScript.build(first_blueprint, seed * 7919 + 37)
	var furnishing_replay = CastleFurnishingPlannerScript.build(replay_blueprint, seed * 7919 + 37)
	var furnishing_manifest := FurnishingNavigationManifestBuilderScript.build(furnishing_plan, parent_transform)
	var furnishing_manifest_replay := FurnishingNavigationManifestBuilderScript.build(furnishing_replay, parent_transform)
	check(JSON.stringify(manifest) == JSON.stringify(replay), "seed %d navigation manifest is not deterministic" % seed)
	check(JSON.stringify(furnishing_manifest) == JSON.stringify(furnishing_manifest_replay), "seed %d furnishing navigation manifest is not deterministic" % seed)
	var source_ids := {}
	for id_value in manifest.get("sourcePartIds", []):
		source_ids[String(id_value)] = true
	var supports: Array = manifest.get("supports", []) as Array
	var links: Array = manifest.get("verticalLinks", []) as Array
	var support_seam_links: Array = manifest.get("supportSeamLinks", []) as Array
	var interior_passage_links: Array = manifest.get("interiorPassageLinks", []) as Array
	var doors: Array = manifest.get("doors", []) as Array
	var collision_parts: Array = manifest.get("staticCollision", []) as Array
	var furnishing_collision_parts: Array = furnishing_manifest.get("staticCollision", []) as Array
	var manor_tower_passages := {}
	var support_part_ids := {}
	for support_value in manifest.get("supports", []) as Array:
		if support_value is Dictionary:
			support_part_ids[String((support_value as Dictionary).get("sourcePartId", ""))] = true
	check(not supports.is_empty(), "seed %d published no walkable building supports" % seed)
	check(not links.is_empty(), "seed %d published no physical stair/ramp links" % seed)
	check(int(manifest.get("supportCount", -1)) == supports.size(), "seed %d support count disagrees with support facts" % seed)
	check(int(manifest.get("verticalLinkCount", -1)) == links.size(), "seed %d link count disagrees with link facts" % seed)
	check(int(manifest.get("supportSeamLinkCount", -1)) == support_seam_links.size(), "seed %d support seam link count disagrees with link facts" % seed)
	check(int(manifest.get("interiorPassageLinkCount", -1)) == interior_passage_links.size(), "seed %d interior passage link count disagrees with link facts" % seed)
	check(int(manifest.get("doorCount", -1)) == doors.size(), "seed %d door count disagrees with door facts" % seed)
	check(int(manifest.get("staticCollisionCount", -1)) == collision_parts.size(), "seed %d construction collision count disagrees with collision facts" % seed)
	check(int(furnishing_manifest.get("staticCollisionCount", -1)) == furnishing_collision_parts.size(), "seed %d furnishing collision count disagrees with collision facts" % seed)
	for collision_value in collision_parts:
		if collision_value is Dictionary:
			var collision: Dictionary = collision_value
			check(not support_part_ids.has(String(collision.get("sourcePartId", ""))), "seed %d emits a walkable support as a static navigation blocker" % seed)
	var support_ids := {}
	var supports_by_id := {}
	var elevations := {}
	for support_value in supports:
		if not (support_value is Dictionary):
			check(false, "seed %d has malformed support fact" % seed)
			continue
		var support: Dictionary = support_value
		var support_id := String(support.get("id", ""))
		var source_part_id := String(support.get("sourceCollisionPartId", ""))
		check(not support_id.is_empty() and not support_ids.has(support_id), "seed %d has missing/duplicate support id %s" % [seed, support_id])
		check(source_ids.has(source_part_id), "seed %d support %s does not cite a collision source part" % [seed, support_id])
		check((support.get("polygon", []) as Array).size() >= 3, "seed %d support %s lacks a physical top polygon" % [seed, support_id])
		var normal: Vector3 = support.get("floorNormal", Vector3.ZERO) as Vector3
		check(normal.y >= 0.68, "seed %d support %s is not physically walkable" % [seed, support_id])
		var position: Vector3 = support.get("worldPosition", Vector3.ZERO) as Vector3
		elevations[roundi(position.y * 10.0)] = true
		support_ids[support_id] = true
		supports_by_id[support_id] = support
	check(elevations.size() >= 3, "seed %d did not expose multiple physical walkable elevations" % seed)
	for link_value in links:
		if not (link_value is Dictionary):
			check(false, "seed %d has malformed vertical link" % seed)
			continue
		var link: Dictionary = link_value
		var link_id := String(link.get("id", ""))
		var source_part_id := String(link.get("sourceCollisionPartId", ""))
		var start_support_id := String(link.get("startSupportId", ""))
		var end_support_id := String(link.get("endSupportId", ""))
		var start: Vector3 = link.get("start", Vector3.ZERO) as Vector3
		var end: Vector3 = link.get("end", Vector3.ZERO) as Vector3
		check(not link_id.is_empty(), "seed %d has an unnamed vertical link" % seed)
		check(source_ids.has(source_part_id), "seed %d vertical link %s does not cite a collision source part" % [seed, link_id])
		check(supports_by_id.has(start_support_id), "seed %d vertical link %s lacks a lower landing support" % [seed, link_id])
		check(supports_by_id.has(end_support_id), "seed %d vertical link %s lacks an upper landing support" % [seed, link_id])
		if supports_by_id.has(start_support_id):
			check(String((supports_by_id[start_support_id] as Dictionary).get("kind", "")) != "ramp", "seed %d vertical link %s anchors its lower endpoint to itself" % [seed, link_id])
		if supports_by_id.has(end_support_id):
			check(String((supports_by_id[end_support_id] as Dictionary).get("kind", "")) != "ramp", "seed %d vertical link %s anchors its upper endpoint to itself" % [seed, link_id])
		check(end.y > start.y + 0.10, "seed %d vertical link %s is not an ascending physical ramp" % [seed, link_id])
		check_navigation_link_tiles(seed, "vertical", link)
	for link_value in support_seam_links:
		if not (link_value is Dictionary):
			check(false, "seed %d has malformed support seam link" % seed)
			continue
		var link: Dictionary = link_value
		var link_id := String(link.get("id", ""))
		var source_part_id := String(link.get("sourceCollisionPartId", ""))
		var support_id := String(link.get("supportId", ""))
		var start: Vector3 = link.get("start", Vector3.ZERO) as Vector3
		var end: Vector3 = link.get("end", Vector3.ZERO) as Vector3
		var tile_keys: Array = link.get("tileKeys", []) as Array
		check(not link_id.is_empty(), "seed %d has an unnamed support seam link" % seed)
		check(source_ids.has(source_part_id), "seed %d support seam link %s does not cite a collision source part" % [seed, link_id])
		check(supports_by_id.has(support_id), "seed %d support seam link %s cites an unknown support" % [seed, link_id])
		check(start.distance_to(end) > 0.10, "seed %d support seam link %s has coincident endpoints" % [seed, link_id])
		check(tile_keys.size() >= 2, "seed %d support seam link %s does not span navigation tiles" % [seed, link_id])
		check_navigation_link_tiles(seed, "support seam", link)
		if supports_by_id.has(support_id):
			var support: Dictionary = supports_by_id[support_id] as Dictionary
			check(point_within_support_xz(start, support), "seed %d support seam link %s start falls outside its support" % [seed, link_id])
			check(point_within_support_xz(end, support), "seed %d support seam link %s end falls outside its support" % [seed, link_id])
	for link_value in interior_passage_links:
		if not (link_value is Dictionary):
			check(false, "seed %d has malformed interior passage link" % seed)
			continue
		var link: Dictionary = link_value
		var link_id := String(link.get("id", ""))
		var access_id := String(link.get("sourceAccessId", ""))
		var room_ids: Array = link.get("roomIds", []) as Array
		var first_support_id := String(link.get("firstSupportId", ""))
		var second_support_id := String(link.get("secondSupportId", ""))
		var first_support_part_id := String(link.get("firstSupportPartId", ""))
		var second_support_part_id := String(link.get("secondSupportPartId", ""))
		var start: Vector3 = link.get("start", Vector3.ZERO) as Vector3
		var end: Vector3 = link.get("end", Vector3.ZERO) as Vector3
		check(not link_id.is_empty(), "seed %d has an unnamed interior passage link" % seed)
		check(not access_id.is_empty(), "seed %d interior passage link %s lacks its source access" % [seed, link_id])
		check(room_ids.size() == 2 and String(room_ids[0]) != String(room_ids[1]), "seed %d interior passage link %s does not connect two rooms" % [seed, link_id])
		check(supports_by_id.has(first_support_id), "seed %d interior passage link %s cites an unknown first support" % [seed, link_id])
		check(supports_by_id.has(second_support_id), "seed %d interior passage link %s cites an unknown second support" % [seed, link_id])
		check(start.distance_to(end) > 0.10, "seed %d interior passage link %s has coincident endpoints" % [seed, link_id])
		check_navigation_link_tiles(seed, "interior passage", link)
		if supports_by_id.has(first_support_id):
			check(point_within_support_xz(start, supports_by_id[first_support_id] as Dictionary), "seed %d interior passage link %s start falls outside its support" % [seed, link_id])
		if supports_by_id.has(second_support_id):
			check(point_within_support_xz(end, supports_by_id[second_support_id] as Dictionary), "seed %d interior passage link %s end falls outside its support" % [seed, link_id])
		if access_id in ["manor_lower_tower", "manor_solar_tower"]:
			manor_tower_passages[access_id] = manor_tower_passages.get(access_id, 0) + 1
			check(first_support_part_id != second_support_part_id, "seed %d manor passage %s does not bridge distinct physical supports" % [seed, link_id])
			if access_id == "manor_lower_tower":
				check(first_support_part_id.ends_with("__manor_main_lower_floor"), "seed %d manor lower passage %s is not anchored to the hall floor" % [seed, link_id])
				check(second_support_part_id.ends_with("__manor_stair_tower_floor"), "seed %d manor lower passage %s is not anchored to the tower floor" % [seed, link_id])
			elif access_id == "manor_solar_tower":
				check(first_support_part_id.ends_with("__manor_solar_upper_floor"), "seed %d manor upper passage %s is not anchored to the solar floor" % [seed, link_id])
				check(second_support_part_id.ends_with("__manor_stair_exit_0"), "seed %d manor upper passage %s is not anchored to the stair exit" % [seed, link_id])
	check(int(manor_tower_passages.get("manor_lower_tower", 0)) > 0, "seed %d published no lower manor-to-tower passage links" % seed)
	check(int(manor_tower_passages.get("manor_solar_tower", 0)) > 0, "seed %d published no upper manor-to-tower passage links" % seed)
	var source_portal_count := 0
	for door_value in doors:
		if not (door_value is Dictionary):
			check(false, "seed %d has malformed doorway fact" % seed)
			continue
		var door: Dictionary = door_value
		var source_part_id := String(door.get("sourceCollisionPartId", ""))
		var interior: Vector3 = door.get("interior", Vector3.ZERO) as Vector3
		var exterior: Vector3 = door.get("exterior", Vector3.ZERO) as Vector3
		check(source_ids.has(source_part_id), "seed %d doorway does not cite a source door part" % seed)
		if bool(door.get("sourcePortalReady", false)):
			source_portal_count += 1
			check(interior.distance_to(exterior) >= 0.50, "seed %d doorway %s has coincident source anchors" % [seed, source_part_id])
			var interior_support_id := String(door.get("interiorSupportId", ""))
			var exterior_support_id := String(door.get("exteriorSupportId", ""))
			check(not interior_support_id.is_empty() and not exterior_support_id.is_empty(), "seed %d doorway %s lacks source support anchors" % [seed, source_part_id])
			check(supports_by_id.has(interior_support_id), "seed %d doorway %s cites an unknown interior support" % [seed, source_part_id])
			check(supports_by_id.has(exterior_support_id), "seed %d doorway %s cites an unknown exterior support" % [seed, source_part_id])
			if supports_by_id.has(interior_support_id):
				check(point_within_support_xz(interior, supports_by_id[interior_support_id] as Dictionary), "seed %d doorway %s interior anchor falls outside its support" % [seed, source_part_id])
			if supports_by_id.has(exterior_support_id):
				check(point_within_support_xz(exterior, supports_by_id[exterior_support_id] as Dictionary), "seed %d doorway %s exterior anchor falls outside its support" % [seed, source_part_id])
	check(source_portal_count > 0, "seed %d published no source-supported doorway anchors" % seed)
	for collision_value in collision_parts:
		if not (collision_value is Dictionary):
			check(false, "seed %d has malformed construction collision fact" % seed)
			continue
		var collision: Dictionary = collision_value
		var source_part_id := String(collision.get("sourceCollisionPartId", ""))
		var bounds: AABB = collision.get("bounds", AABB()) as AABB
		var footprint: Array = collision.get("footprint", []) as Array
		check(source_ids.has(source_part_id), "seed %d construction collision does not cite a source part" % seed)
		check(bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0, "seed %d construction collision %s lacks physical bounds" % [seed, source_part_id])
		check(footprint.size() == 4 and footprint.all(func(point) -> bool: return point is Vector3), "seed %d construction collision %s lacks an exact rotated footprint" % [seed, source_part_id])
	var furnishing_source_ids := {}
	for part in furnishing_plan.parts:
		if part != null and bool(part.collision_enabled):
			furnishing_source_ids[String(part.id)] = true
	for collision_value in furnishing_collision_parts:
		if not (collision_value is Dictionary):
			check(false, "seed %d has malformed furnishing collision fact" % seed)
			continue
		var collision: Dictionary = collision_value
		var source_part_id := String(collision.get("sourceCollisionPartId", ""))
		var bounds: AABB = collision.get("bounds", AABB()) as AABB
		var footprint: Array = collision.get("footprint", []) as Array
		check(furnishing_source_ids.has(source_part_id), "seed %d furnishing collision does not cite a source part" % seed)
		check(bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0, "seed %d furnishing collision %s lacks physical bounds" % [seed, source_part_id])
		check(footprint.size() == 4 and footprint.all(func(point) -> bool: return point is Vector3), "seed %d furnishing collision %s lacks an exact rotated footprint" % [seed, source_part_id])
	return {
		"seed": seed,
		"blueprintParts": first_blueprint.parts.size() if first_blueprint != null else 0,
		"supportCount": supports.size(),
		"verticalLinkCount": links.size(),
		"supportSeamLinkCount": support_seam_links.size(),
		"interiorPassageLinkCount": interior_passage_links.size(),
		"manorTowerPassageCounts": manor_tower_passages,
		"doorCount": doors.size(),
		"sourcePortalCount": source_portal_count,
		"supportElevationCount": elevations.size(),
		"constructionCollisionCount": collision_parts.size(),
		"furnishingCollisionCount": furnishing_collision_parts.size()
	}


func check(condition: bool, failure: String) -> void:
	if not condition:
		failures.append(failure)


func check_navigation_link_tiles(seed: int, kind: String, link: Dictionary) -> void:
	var link_id := String(link.get("id", ""))
	var start: Vector3 = link.get("start", Vector3.INF) as Vector3
	var end: Vector3 = link.get("end", Vector3.INF) as Vector3
	var tile_keys: Array = link.get("tileKeys", []) as Array
	var start_tile_key := String(link.get("startTileKey", ""))
	var end_tile_key := String(link.get("endTileKey", ""))
	var owner_tile_key := String(link.get("ownerTileKey", ""))
	check(not start_tile_key.is_empty(), "seed %d %s link %s lacks a start tile" % [seed, kind, link_id])
	check(not end_tile_key.is_empty(), "seed %d %s link %s lacks an end tile" % [seed, kind, link_id])
	check(not owner_tile_key.is_empty(), "seed %d %s link %s lacks an owner tile" % [seed, kind, link_id])
	if start.is_finite():
		check(start_tile_key == navigation_tile_key_for_position(start), "seed %d %s link %s start tile does not contain its endpoint" % [seed, kind, link_id])
	if end.is_finite():
		check(end_tile_key == navigation_tile_key_for_position(end), "seed %d %s link %s end tile does not contain its endpoint" % [seed, kind, link_id])
	check(owner_tile_key == start_tile_key, "seed %d %s link %s owner is not its start endpoint tile" % [seed, kind, link_id])
	check(tile_keys.has(start_tile_key), "seed %d %s link %s omits its start tile from coverage" % [seed, kind, link_id])
	check(tile_keys.has(end_tile_key), "seed %d %s link %s omits its end tile from coverage" % [seed, kind, link_id])


func navigation_tile_key_for_position(position: Vector3) -> String:
	var tile_cells := NpcConstantsScript.NAV_TILE_CELL_SIZE
	var cell_x := roundi(position.x / CELL)
	var cell_z := roundi(position.z / CELL)
	return "%d,%d" % [
		floori(float(cell_x) / float(tile_cells)),
		floori(float(cell_z) / float(tile_cells))
	]


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
		var crosses := (point.z > position.z) != (previous.z > position.z)
		if crosses:
			var denominator := previous.z - point.z
			if absf(denominator) > 0.000001:
				var x_at_z := (previous.x - point.x) * (position.z - point.z) / denominator + point.x
				if position.x < x_at_z:
					inside = not inside
		previous = point
	return inside


func write_report(report: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
