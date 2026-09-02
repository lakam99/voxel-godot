extends RefCounted
class_name StandaloneStructureCandidate

## Pure extraction of StructureSystem's pre-terrain standalone sequence.
## Callers supply the ordinary world's region size and spawn chance (currently
## 140 and 0.26); no second tuning/configuration authority lives here.
## A nonempty result is a RAW candidate, not terrain admission or publication.
## In particular, deterministic citadel exclusion must protect raw candidates,
## not test flatness against terrain already changed by the citadel itself.


static func candidate_for_region(world_seed: String, region: Vector2i, region_cells: int, spawn_chance: float) -> Dictionary:
	# Same Unicode FNV, seed text, modulo, comparison and RNG order as Main /
	# StructureSystem. Presence is a hash, NOT an extra draw from the layout RNG.
	var rng_seed := _hash_string("%s:structure:%d,%d" % [world_seed, region.x, region.y])
	var roll := float(absi(rng_seed) % 100000) / 100000.0
	if roll > spawn_chance:
		return {}
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var base_x: int = region.x * region_cells + rng.randi_range(16, region_cells - 18)
	var base_z: int = region.y * region_cells + rng.randi_range(16, region_cells - 18)
	var structure_type := standalone_structure_type(rng)
	var dimensions := structure_dimensions_for_type(structure_type, rng)
	return {
		"region": region,
		"baseCell": Vector2i(base_x, base_z),
		"structureType": structure_type,
		"dimensions": dimensions,
		"presenceRoll": roll,
		"rngSeed": rng.seed,
		"rngState": rng.state,
	}


static func continuation_rng(candidate: Dictionary) -> RandomNumberGenerator:
	# Setting seed changes state. Always restore it first; no draws here.
	var rng := RandomNumberGenerator.new()
	rng.seed = int(candidate["rngSeed"])
	rng.state = int(candidate["rngState"])
	return rng


static func standalone_structure_type(rng: RandomNumberGenerator) -> String:
	var roll := rng.randf()
	if roll < 0.12:
		return "shrine"
	if roll < 0.32:
		return "mine"
	if roll < 0.58:
		return "ruin"
	if roll < 0.74:
		return "camp"
	return "cabin"


static func structure_dimensions_for_type(structure_type: String, rng: RandomNumberGenerator) -> Vector2i:
	if structure_type == "shrine":
		return Vector2i(9, 9)
	if structure_type == "mine":
		return Vector2i(rng.randi_range(10, 12), rng.randi_range(12, 14))
	if structure_type == "camp":
		return Vector2i(rng.randi_range(11, 13), rng.randi_range(10, 12))
	return Vector2i(rng.randi_range(7, 10), rng.randi_range(7, 10))


static func terrain_influence_for_candidate(candidate: Dictionary) -> Dictionary:
	## Half-open WORLD XZ CELL bounds of direct terrain writes / scene-block
	## overlay columns and the terrain samples used to admit this standalone.
	## Not a render AABB, lighting propagation radius, mesh halo, exact support
	## mask or a Y-range. Citadel callers must supply their complete terrain
	## influence (including their own apron/sampling halo) when intersecting.
	## No RNG is consumed and no terrain/world/live scene is consulted.
	##
	## Source audit (StructureSystem, 2026-09-02):
	## - reserve_structure_terrain_footprint: inclusive X [-1,width], Z [-1,depth]
	##   at floorY-3..floorY, with interior air contained in that XZ rectangle.
	## - cabin build_building: roof [-1,width] x [-1,depth]; place_porch is only
	##   one cell outside a wall in any of four directions, also contained.
	## - ruin: walls, rubble and loot remain within [0,width-1] x [0,depth-1].
	## - shrine: paths, pillars, beams, torches and loot remain within the yard.
	## - camp and mine: approach is centerX + [-1,1], Z [-5,-1]. Camp traps at
	##   Z=-2 and mine torches at Z=-1 are contained by the enclosing rectangle.
	## - build_mine has NO descending shaft/tunnel/carve call in this source;
	##   its yard/supports/ore walls end at depth-1. Never assume this bound
	##   covers a future tunnel extension: audit that source before widening it.
	## - place_path/place_structure_block/place_utility -> MainChunkTerrain
	##   create_block -> sync_block_state_to_terrain writes only the given XZ
	##   cell; foundation edits are the only multi-column terrain writes here.
	if candidate.is_empty():
		return {"bounded": false, "reason": "absent_candidate"}
	var kind := String(candidate.get("structureType", ""))
	var dimensions: Vector2i = candidate.get("dimensions", Vector2i.ZERO)
	if kind not in ["cabin", "ruin", "shrine", "camp", "mine"] or dimensions.x <= 0 or dimensions.y <= 0:
		return {"bounded": false, "reason": "unsupported_source"}
	var base: Vector2i = candidate["baseCell"]
	var foundation := Rect2i(base - Vector2i.ONE, dimensions + Vector2i(2, 2))
	var influence := foundation
	var approach := Rect2i()
	if kind == "camp" or kind == "mine":
		approach = Rect2i(base + Vector2i(int(dimensions.x / 2) - 1, -5), Vector2i(3, 5))
		influence = foundation.merge(approach)
	return {
		"bounded": true,
		"evidenceLevel": "source_audited_conservative_xz_columns",
		"influenceCells": influence,
		"foundationCells": foundation,
		"approachCells": approach,
		"terrainAdmissionTested": false,
		"publicationReady": false,
	}


static func _hash_string(text: String) -> int:
	var value := 2166136261
	for index in range(text.length()):
		value = int((value ^ text.unicode_at(index)) * 16777619) & 0xffffffff
	return value
