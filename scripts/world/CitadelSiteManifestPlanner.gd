extends RefCounted
class_name CitadelSiteManifestPlanner

const TerrainPolicy := preload("res://scripts/world/CitadelTerrainOperationPolicy.gd")

const CITADEL_REGION_CELLS := 420
const SITE_RADIUS_CELLS := 76
const APPROACH_CLEARANCE_CELLS := TerrainPolicy.MAX_APPROACH_CELLS
const SITE_EDGE_CLEARANCE_CELLS := SITE_RADIUS_CELLS + APPROACH_CLEARANCE_CELLS
const SITE_SPAWN_CHANCE := 0.055
const CANDIDATE_COUNT := 8


static func manifest_for_region(
	seed_text: String,
	region_x: int,
	region_z: int,
	site_region_cells := CITADEL_REGION_CELLS,
	natural_surface_sample: Callable = Callable()
) -> Dictionary:
	if site_region_cells != CITADEL_REGION_CELLS:
		return {}
	if _hash01("%s:citadel-spawn:%d,%d" % [seed_text, region_x, region_z]) > SITE_SPAWN_CHANCE:
		return {}
	var candidates := _candidates(seed_text, region_x, region_z)
	var best := {}
	for candidate_value in candidates:
		var candidate: Dictionary = candidate_value
		var terrain_contract := _terrain_contract(candidate, natural_surface_sample)
		if terrain_contract.is_empty():
			continue
		var level := float(terrain_contract.get("level", NAN))
		if is_nan(level):
			continue
		var score := float(candidate.get("score", INF))
		if best.is_empty() or score < float(best.get("score", INF)):
			best = candidate.duplicate(true)
			best["level"] = level
			best["terrainContract"] = terrain_contract
	if best.is_empty():
		return {}
	return {
		"schemaVersion": 1,
		"id": "citadel:%d,%d" % [region_x, region_z],
		"kind": "citadel",
		"siteType": "landmark",
		"regionX": region_x,
		"regionZ": region_z,
		"siteRegionCells": CITADEL_REGION_CELLS,
		"center": best.get("center", Vector2i.ZERO),
		"centerX": int((best.get("center", Vector2i.ZERO) as Vector2i).x),
		"centerZ": int((best.get("center", Vector2i.ZERO) as Vector2i).y),
		"radius": SITE_RADIUS_CELLS,
		"level": float(best.get("level", 0.0)),
		"blueprintSeed": _hash_string("%s:citadel-blueprint:%d,%d" % [seed_text, region_x, region_z]),
		"blueprintFamily": "castle",
		"citadelProfile": "standard",
		"citadelScale": 1.0,
		"blueprintEnvelopeRadiusCells": SITE_RADIUS_CELLS,
		"terrain": best.get("terrainContract", {}),
		"terrainAuthority": "seeded_citadel_landmark",
		"seed": seed_text
	}


static func _candidates(seed_text: String, region_x: int, region_z: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = _hash_string("%s:citadel-site:%d,%d" % [seed_text, region_x, region_z])
	var candidates: Array = []
	# Keep a one-cell gap between adjacent region envelopes. This means accepted
	# citadel sites cannot require cross-region arbitration during terrain reads.
	var lower := SITE_EDGE_CLEARANCE_CELLS + 1
	var upper := CITADEL_REGION_CELLS - SITE_EDGE_CLEARANCE_CELLS - 1
	for candidate_index in range(CANDIDATE_COUNT):
		var center := Vector2i(
			region_x * CITADEL_REGION_CELLS + rng.randi_range(lower, upper),
			region_z * CITADEL_REGION_CELLS + rng.randi_range(lower, upper)
		)
		candidates.append({
			"center": center,
			"score": float(candidate_index)
		})
	return candidates


static func _terrain_contract(candidate: Dictionary, natural_surface_sample: Callable) -> Dictionary:
	var center: Vector2i = candidate.get("center", Vector2i.ZERO)
	var proof := TerrainPolicy.build_contract(center, natural_surface_sample)
	if not bool(proof.get("accepted", false)):
		return {}
	candidate["score"] = float(proof.get("maxCutFill", INF)) + float(proof.get("maximumSampledApproachGrade", INF))
	var level := float(proof.get("level", NAN))
	var approach_cells := int(proof.get("approachCells", 0))
	var reserved_min := Vector2i(center.x - SITE_EDGE_CLEARANCE_CELLS, center.y - SITE_EDGE_CLEARANCE_CELLS)
	var reserved_max := Vector2i(center.x + SITE_EDGE_CLEARANCE_CELLS, center.y + SITE_EDGE_CLEARANCE_CELLS)
	var blueprint_min := Vector2i(center.x - SITE_RADIUS_CELLS, center.y - SITE_RADIUS_CELLS)
	var blueprint_max := Vector2i(center.x + SITE_RADIUS_CELLS, center.y + SITE_RADIUS_CELLS)
	return {
		"schemaVersion": 1,
		"level": level,
		"biome": String(proof.get("biome", "")),
		"reservedBounds": {"minCell": reserved_min, "maxCell": reserved_max},
		"blueprintFootprintBounds": {"minCell": blueprint_min, "maxCell": blueprint_max},
		"propExclusionBounds": {"minCell": reserved_min, "maxCell": reserved_max},
		"terrainOperations": [
			{"kind": "flatten_disc", "center": center, "radiusCells": SITE_RADIUS_CELLS, "level": level, "material": "stone", "source": "citadel_foundation"},
			{"kind": "grade_approaches", "center": center, "radiusCells": SITE_RADIUS_CELLS + approach_cells, "level": level, "material": "stone", "source": "citadel_approach"}
		],
		"citadelTerrainOperation": {"schemaVersion": 1, "center": center, "coreRadiusCells": SITE_RADIUS_CELLS, "approachCells": approach_cells, "level": level},
		"terrainProof": proof.duplicate(true)
	}


static func _support_sample_offsets() -> Array[Vector2i]:
	return TerrainPolicy.core_sample_offsets()


static func _hash01(text: String) -> float:
	return float(absi(_hash_string(text)) % 100000) / 100000.0


static func conflicts_with_reservations(manifest: Dictionary, reservations: Array) -> bool:
	var terrain: Dictionary = manifest.get("terrain", {}) if manifest.get("terrain", {}) is Dictionary else {}
	var bounds: Dictionary = terrain.get("reservedBounds", {}) if terrain.get("reservedBounds", {}) is Dictionary else {}
	var minimum: Vector2i = bounds.get("minCell", Vector2i.ZERO)
	var maximum: Vector2i = bounds.get("maxCell", Vector2i.ZERO)
	for reservation_value in reservations:
		if not (reservation_value is Dictionary):
			continue
		var reservation: Dictionary = reservation_value
		var reservation_terrain: Dictionary = reservation.get("terrain", {}) if reservation.get("terrain", {}) is Dictionary else {}
		var reservation_bounds: Dictionary = reservation.get("reservedBounds", reservation_terrain.get("reservedBounds", {})) if reservation.get("reservedBounds", reservation_terrain.get("reservedBounds", {})) is Dictionary else {}
		var reservation_minimum: Vector2i = reservation_bounds.get("minCell", Vector2i.ZERO)
		var reservation_maximum: Vector2i = reservation_bounds.get("maxCell", Vector2i.ZERO)
		if minimum.x <= reservation_maximum.x and reservation_minimum.x <= maximum.x \
			and minimum.y <= reservation_maximum.y and reservation_minimum.y <= maximum.y:
			return true
	return false


static func resolved_manifest_for_region(
	seed_text: String,
	region_x: int,
	region_z: int,
	natural_surface_sample: Callable,
	reservations: Array
) -> Dictionary:
	var candidates: Array = []
	for scan_z in range(region_z - 1, region_z + 2):
		for scan_x in range(region_x - 1, region_x + 2):
			var candidate := manifest_for_region(seed_text, scan_x, scan_z, CITADEL_REGION_CELLS, natural_surface_sample)
			if not candidate.is_empty():
				candidates.append(candidate)
	candidates.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return String(left.get("id", "")) < String(right.get("id", "")))
	var accepted: Array = []
	for candidate_value in candidates:
		var candidate: Dictionary = candidate_value
		if conflicts_with_reservations(candidate, reservations) or conflicts_with_reservations(candidate, accepted):
			continue
		accepted.append(candidate)
	for accepted_value in accepted:
		var accepted_manifest: Dictionary = accepted_value
		if int(accepted_manifest.get("regionX", 0)) == region_x and int(accepted_manifest.get("regionZ", 0)) == region_z:
			return accepted_manifest.duplicate(true)
	return {}


static func _hash_string(text: String) -> int:
	var value := 2166136261
	for index in range(text.length()):
		value = int((value ^ text.unicode_at(index)) * 16777619) & 0xffffffff
	return value
