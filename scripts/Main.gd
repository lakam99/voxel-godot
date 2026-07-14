extends "res://scripts/MainPropFactory.gd"

func town_region(region_x: int, region_z: int) -> Dictionary:
	var cache_key := Vector2i(region_x, region_z)
	if town_region_cache.has(cache_key):
		return town_region_cache[cache_key]
	var forced := region_x == 1 and region_z == 0
	if not forced and hash01("town:%d,%d" % [region_x, region_z]) > TOWN_SPAWN_CHANCE:
		town_region_cache[cache_key] = {}
		return {}
	var center_x: int = region_x * TOWN_REGION_CELLS
	var center_z: int = region_z * TOWN_REGION_CELLS
	var radius: int = town_radius_for_region(region_x, region_z, forced)
	var natural_level: float = natural_surface_y_at_cell(Vector3i(center_x, 0, center_z))
	var level: float = clamp(round(max(natural_level, WATER_LEVEL + 3.0) / CELL) * CELL, WATER_LEVEL + 3.0, 52.0)
	var town := {
		"regionX": region_x,
		"regionZ": region_z,
		"centerX": center_x,
		"centerZ": center_z,
		"radius": radius,
		"level": level
	}
	town_region_cache[cache_key] = town
	return town

func town_radius_for_region(region_x: int, region_z: int, forced := false) -> int:
	var radius_roll := hash01("town-radius:%d,%d" % [region_x, region_z])
	if forced:
		return TOWN_RADIUS_CELLS + int(radius_roll * 8.0)
	var class_roll := hash01("town-size-class:%d,%d" % [region_x, region_z])
	if class_roll < 0.34:
		return 22 + int(radius_roll * 7.0)
	if class_roll > 0.82:
		return 38 + int(radius_roll * 9.0)
	return TOWN_RADIUS_CELLS + int(radius_roll * 8.0)

func hash01(text: String) -> float:
	return float(abs(hash_string("%s:%s" % [seed_text, text])) % 100000) / 100000.0

func tree_chance(biome: String) -> float:
	match biome:
		"forest":
			return 0.58
		"taiga":
			return 0.48
		"plains":
			return 0.22
		"swamp":
			return 0.26
		"savanna":
			return 0.10
		_:
			return 0.02

func forage_for_biome(biome: String) -> Dictionary:
	if biome == "desert" or biome == "beach" or biome == "savanna":
		return {
			"material": "aloePatch",
			"drop": "aloe",
			"drop_min": 1,
			"drop_max": 3,
			"radius": 0.48
		}
	if biome == "swamp":
		return {
			"material": "mushroomCluster",
			"drop": "mirecap",
			"drop_min": 1,
			"drop_max": 3,
			"radius": 0.50
		}
	if biome == "snow" or biome == "tundra" or biome == "alpine" or biome == "taiga":
		return {
			"material": "frostHerbPatch",
			"drop": "frostHerb",
			"drop_min": 1,
			"drop_max": 2,
			"radius": 0.48
		}
	return {
		"material": "berryBush",
		"drop": "berries",
		"drop_min": 2,
		"drop_max": 4,
		"radius": 0.56
	}

func forage_chance(biome: String) -> float:
	match biome:
		"forest":
			return 0.20
		"plains":
			return 0.14
		"savanna":
			return 0.12
		"beach":
			return 0.08
		"desert":
			return 0.10
		"taiga":
			return 0.13
		"swamp":
			return 0.18
		"tundra":
			return 0.10
		"alpine":
			return 0.08
		"snow":
			return 0.12
		_:
			return 0.0

func wildlife_chance(biome: String, height: float) -> float:
	if height > 70.0:
		return 0.0
	match biome:
		"plains":
			return 0.10
		"forest":
			return 0.07
		"savanna":
			return 0.09
		"taiga":
			return 0.06
		"tundra":
			return 0.045
		"alpine":
			return 0.028
		"snow":
			return 0.035
		"swamp":
			return 0.035
		_:
			return 0.0

func rock_chance(biome: String, height: float) -> float:
	var base := 0.10
	match biome:
		"alpine", "tundra", "snow":
			base = 0.55
		"desert", "savanna":
			base = 0.36
		"plains":
			base = 0.16
		"forest", "taiga":
			base = 0.12
		_:
			base = 0.08
	if height > 42.0:
		base += 0.12
	return base

func ore_for_cell(biome: String, height: float, rng: RandomNumberGenerator) -> String:
	if height < 24.0 or height > 98.0:
		return ""
	var biome_bias := 0.28
	match biome:
		"alpine":
			biome_bias = 1.0
		"snow":
			biome_bias = 0.92
		"tundra":
			biome_bias = 0.82
		"desert":
			biome_bias = 0.62
		"savanna":
			biome_bias = 0.58
		"taiga":
			biome_bias = 0.54
		"plains":
			biome_bias = 0.38
		"forest":
			biome_bias = 0.34
		"swamp":
			biome_bias = 0.16
	var height_bias := 0.16
	if height > 58.0:
		height_bias = 1.0
	elif height > 42.0:
		height_bias = 0.68
	elif height > 30.0:
		height_bias = 0.40
	var iron_chance := 0.10 * biome_bias * height_bias if height > 40.0 else 0.015 * biome_bias
	var copper_chance := 0.16 * biome_bias + 0.10 * height_bias
	var roll := rng.randf()
	if roll < iron_chance:
		return "ironOre"
	if roll < iron_chance + copper_chance:
		return "copperOre"
	return ""

func noise01(noise: FastNoiseLite, x: float, z: float) -> float:
	return noise.get_noise_2d(x, z) * 0.5 + 0.5

func smoothstep_range(value: float, low: float, high: float) -> float:
	if high == low:
		return 1.0 if value >= high else 0.0
	var t: float = clamp((value - low) / (high - low), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

func hash_string(text: String) -> int:
	var h := 2166136261
	for i in range(text.length()):
		h = int((h ^ text.unicode_at(i)) * 16777619) & 0xffffffff
	return h

func world_to_cell(value: float) -> int:
	return roundi(value / CELL)

func cell_to_chunk(x: int, z: int) -> Vector2i:
	return Vector2i(floori(float(x) / float(CHUNK_SIZE)), floori(float(z) / float(CHUNK_SIZE)))

func world_to_chunk(x: float, z: float) -> Vector2i:
	return cell_to_chunk(world_to_cell(x), world_to_cell(z))
