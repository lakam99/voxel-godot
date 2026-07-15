extends RefCounted
class_name TreeEcologySampler

const INVALID_CELL := Vector2i(2147483647, 2147483647)
const AGE_BANDS := ["young", "established", "mature", "old", "ancient"]

func sample_tree(
	profile: BiomeEnvironmentProfile,
	biome: String,
	world_seed: String,
	prop_id: String,
	world_cell := INVALID_CELL
) -> Dictionary:
	if profile == null:
		return {}
	var resolved_cell := world_cell
	if resolved_cell == INVALID_CELL:
		resolved_cell = cell_from_prop_id(prop_id)
	if resolved_cell == INVALID_CELL:
		var pseudo_hash := stable_hash("tree-cell:%s:%s" % [biome, prop_id])
		resolved_cell = Vector2i((pseudo_hash & 0xffff) - 32768, ((pseudo_hash >> 16) & 0xffff) - 32768)
	var seed_key := world_seed.strip_edges()
	if seed_key == "":
		seed_key = seed_from_prop_id(prop_id)
	if seed_key == "":
		seed_key = "default"
	var field_scale := maxf(8.0, profile.tree_maturity_cell_scale)
	var maturity := maturity_at(seed_key, biome, resolved_cell, field_scale)
	var effective_maturity := lerpf(0.5, maturity, clampf(profile.tree_maturity_influence, 0.0, 1.0))
	var minimum_age := maxf(0.0, profile.tree_age_min_years)
	var typical_age := maxf(minimum_age, profile.tree_age_typical_years)
	var maximum_age := maxf(typical_age, profile.tree_age_max_years)
	var center_age := minimum_age
	if effective_maturity <= 0.5:
		center_age = lerpf(minimum_age, typical_age, effective_maturity * 2.0)
	else:
		center_age = lerpf(typical_age, maximum_age, (effective_maturity - 0.5) * 2.0)
	var total_span := maxf(0.0, maximum_age - minimum_age)
	var local_span := maxf(1.0, total_span * clampf(profile.tree_local_age_span, 0.05, 1.0))
	var range_min := clampf(center_age - local_span * 0.5, minimum_age, maximum_age)
	var range_max := clampf(center_age + local_span * 0.5, minimum_age, maximum_age)
	if range_max - range_min < minf(1.0, total_span):
		range_max = minf(maximum_age, range_min + minf(1.0, total_span))
	var age_roll := stable_unit("tree-age:%s:%s:%s:%d,%d" % [seed_key, biome, prop_id, resolved_cell.x, resolved_cell.y])
	var skew := clampf(profile.tree_age_distribution_skew, 0.2, 3.0)
	var exact_age := lerpf(range_min, range_max, pow(age_roll, skew))
	var growth_stage := 1.0 if total_span <= 0.0001 else clampf((exact_age - minimum_age) / total_span, 0.0, 1.0)
	var band := age_band_for_stage(growth_stage, profile.tree_age_band_thresholds)
	var genetic_unit := stable_unit("tree-genetics:%s:%s:%s" % [seed_key, biome, prop_id])
	return {
		"architecture": profile.tree_architecture,
		"worldCell": resolved_cell,
		"maturity": maturity,
		"effectiveMaturity": effective_maturity,
		"fieldScaleCells": field_scale,
		"ageRangeMin": range_min,
		"ageRangeMax": range_max,
		"ageYears": exact_age,
		"growthStage": growth_stage,
		"ageBand": band,
		"geneticUnit": genetic_unit,
		"geneticSeed": stable_hash("tree-genetics-seed:%s:%s:%s" % [seed_key, biome, prop_id]),
		"heightGrowth": pow(growth_stage, clampf(profile.tree_height_growth_exponent, 0.25, 2.0)),
		"girthGrowth": pow(growth_stage, clampf(profile.tree_girth_growth_exponent, 0.25, 2.0)),
		"crownGrowth": pow(growth_stage, clampf(profile.tree_crown_growth_exponent, 0.25, 2.0))
	}

func maturity_at(world_seed: String, biome: String, world_cell: Vector2i, field_scale_cells: float) -> float:
	var scale := maxf(8.0, field_scale_cells)
	var base := value_noise(world_seed, biome, Vector2(world_cell) / scale, "base")
	var detail := value_noise(world_seed, biome, Vector2(world_cell) / (scale * 0.46), "detail")
	return clampf(base * 0.78 + detail * 0.22, 0.0, 1.0)

func value_noise(world_seed: String, biome: String, point: Vector2, octave: String) -> float:
	var x0 := floori(point.x)
	var y0 := floori(point.y)
	var tx := smooth_curve(point.x - float(x0))
	var ty := smooth_curve(point.y - float(y0))
	var n00 := lattice_unit(world_seed, biome, x0, y0, octave)
	var n10 := lattice_unit(world_seed, biome, x0 + 1, y0, octave)
	var n01 := lattice_unit(world_seed, biome, x0, y0 + 1, octave)
	var n11 := lattice_unit(world_seed, biome, x0 + 1, y0 + 1, octave)
	return lerpf(lerpf(n00, n10, tx), lerpf(n01, n11, tx), ty)

func lattice_unit(world_seed: String, biome: String, x: int, y: int, octave: String) -> float:
	return stable_unit("tree-maturity:%s:%s:%s:%d,%d" % [world_seed, biome, octave, x, y])

func smooth_curve(value: float) -> float:
	var clamped := clampf(value, 0.0, 1.0)
	return clamped * clamped * (3.0 - 2.0 * clamped)

func age_band_for_stage(stage: float, thresholds: PackedFloat32Array) -> String:
	for index in range(mini(4, thresholds.size())):
		if stage < float(thresholds[index]):
			return AGE_BANDS[index]
	return AGE_BANDS[4]

func cell_from_prop_id(prop_id: String) -> Vector2i:
	for segment in prop_id.split(":", false):
		if not segment.contains(","):
			continue
		var coordinates := segment.split(",", false)
		if coordinates.size() < 2:
			continue
		if String(coordinates[0]).is_valid_int() and String(coordinates[1]).is_valid_int():
			return Vector2i(int(coordinates[0]), int(coordinates[1]))
	return INVALID_CELL

func seed_from_prop_id(prop_id: String) -> String:
	var separator := prop_id.find(":")
	return prop_id.substr(0, separator) if separator > 0 else ""

func stable_unit(text: String) -> float:
	return float(stable_hash(text) & 0x7fffffff) / float(0x7fffffff)

func stable_hash(text: String) -> int:
	var hash_value := 2166136261
	for index in range(text.length()):
		hash_value = int((hash_value ^ text.unicode_at(index)) * 16777619) & 0xffffffff
	return hash_value
