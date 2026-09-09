extends RefCounted
class_name BiomeRegionField

## A pure, global-coordinate surface-biome field. It intentionally has no
## chunk ownership, random-number-generator dependency, or SceneTree state.
## One jitter-bounded site per 6km lattice cell keeps every site at least
## 5.36km from a cardinal neighbour, giving every dominant region a 2km+ core
## around its site even after the boundary ecotone.

const FIELD_VERSION := 2
const REGION_SPACING_METERS := 6000.0
const REGION_SITE_JITTER_METERS := 320.0
const MINIMUM_SITE_SEPARATION_METERS := REGION_SPACING_METERS - REGION_SITE_JITTER_METERS * 2.0
const MINIMUM_CORE_RADIUS_METERS := MINIMUM_SITE_SEPARATION_METERS * 0.5
const MINIMUM_CORE_DIAMETER_METERS := MINIMUM_SITE_SEPARATION_METERS
const ECOTONE_WIDTH_METERS := 320.0
const CLIMATE_LATTICE_METERS := 18000.0

# Pure value memoization, owned by this field instance. Mutex protects callers
# sharing a generator; computation happens outside the lock (climate uses sites).
const MEMO_LIMIT := 4096
var _site_memo := {}
var _climate_memo := {}
var _memo_mutex := Mutex.new()

func sample(world_seed: String, world_position: Vector2) -> Dictionary:
	var seed_key := world_seed.strip_edges()
	if seed_key == "":
		seed_key = "default"
	var grid := Vector2i(
		floori(world_position.x / REGION_SPACING_METERS),
		floori(world_position.y / REGION_SPACING_METERS)
	)
	var nearest_region := Vector2i.ZERO
	var nearest_site := Vector2.ZERO
	var nearest_distance := INF
	var second_distance := INF
	for region_z in range(grid.y - 1, grid.y + 2):
		for region_x in range(grid.x - 1, grid.x + 2):
			var candidate := Vector2i(region_x, region_z)
			var site := site_position(seed_key, candidate)
			var distance := world_position.distance_to(site)
			if distance < nearest_distance:
				second_distance = nearest_distance
				nearest_distance = distance
				nearest_region = candidate
				nearest_site = site
			elif distance < second_distance:
				second_distance = distance
	var temperature := climate_channel(seed_key, nearest_region, "temperature")
	var moisture := climate_channel(seed_key, nearest_region, "moisture")
	var edge_distance := maxf(0.0, (second_distance - nearest_distance) * 0.5)
	var ecotone_weight := 1.0 - smoothstep_range(edge_distance, 0.0, ECOTONE_WIDTH_METERS)
	return {
		"version": FIELD_VERSION,
		"region": nearest_region,
		"regionId": region_id(seed_key, nearest_region),
		"sitePosition": nearest_site,
		"biome": biome_for_climate(temperature, moisture),
		"temperature": temperature,
		"moisture": moisture,
		"edgeDistanceMeters": edge_distance,
		"ecotoneWeight": ecotone_weight,
		"minimumCoreRadiusMeters": MINIMUM_CORE_RADIUS_METERS,
		"minimumCoreDiameterMeters": MINIMUM_CORE_DIAMETER_METERS
	}

func site_position(world_seed: String, region: Vector2i) -> Vector2:
	var key := [world_seed, region]
	_memo_mutex.lock()
	if _site_memo.has(key):
		var cached: Vector2 = _site_memo[key]
		_memo_mutex.unlock()
		return cached
	_memo_mutex.unlock()
	var base := Vector2(
		(float(region.x) + 0.5) * REGION_SPACING_METERS,
		(float(region.y) + 0.5) * REGION_SPACING_METERS
	)
	var jitter := Vector2(
		lerpf(-REGION_SITE_JITTER_METERS, REGION_SITE_JITTER_METERS, stable_unit("biome-region-site-x:%s:%d,%d" % [world_seed, region.x, region.y])),
		lerpf(-REGION_SITE_JITTER_METERS, REGION_SITE_JITTER_METERS, stable_unit("biome-region-site-z:%s:%d,%d" % [world_seed, region.x, region.y]))
	)
	var result := base + jitter
	_memo_mutex.lock()
	if _site_memo.size() >= MEMO_LIMIT: _site_memo.clear()
	_site_memo[key] = result
	_memo_mutex.unlock()
	return result

func region_id(world_seed: String, region: Vector2i) -> String:
	return "biome-v%d:%s:%d,%d" % [FIELD_VERSION, world_seed, region.x, region.y]

func climate_channel(world_seed: String, region: Vector2i, channel: String) -> float:
	var key := [world_seed, region, channel]
	_memo_mutex.lock()
	if _climate_memo.has(key):
		var cached: float = _climate_memo[key]
		_memo_mutex.unlock()
		return cached
	_memo_mutex.unlock()
	var site := site_position(world_seed, region)
	var broad := value_noise(world_seed, Vector2(site.x, site.y) / CLIMATE_LATTICE_METERS, "%s-broad" % channel)
	var regional := stable_unit("biome-region-climate:%s:%s:%d,%d" % [world_seed, channel, region.x, region.y])
	var result := clampf(broad * 0.72 + regional * 0.28, 0.0, 1.0)
	_memo_mutex.lock()
	if _climate_memo.size() >= MEMO_LIMIT: _climate_memo.clear()
	_climate_memo[key] = result
	_memo_mutex.unlock()
	return result

func biome_for_climate(temperature: float, moisture: float) -> String:
	if temperature < 0.19:
		return "snow"
	if temperature < 0.33:
		return "taiga" if moisture >= 0.42 else "tundra"
	if moisture > 0.79:
		return "swamp"
	if temperature > 0.70 and moisture < 0.30:
		return "desert"
	if temperature > 0.60 and moisture < 0.49:
		return "savanna"
	if moisture > 0.62:
		return "forest"
	return "plains"

func value_noise(world_seed: String, point: Vector2, channel: String) -> float:
	var x0 := floori(point.x)
	var z0 := floori(point.y)
	var tx := smooth_curve(point.x - float(x0))
	var tz := smooth_curve(point.y - float(z0))
	var a := lattice_unit(world_seed, channel, x0, z0)
	var b := lattice_unit(world_seed, channel, x0 + 1, z0)
	var c := lattice_unit(world_seed, channel, x0, z0 + 1)
	var d := lattice_unit(world_seed, channel, x0 + 1, z0 + 1)
	return lerpf(lerpf(a, b, tx), lerpf(c, d, tx), tz)

func lattice_unit(world_seed: String, channel: String, x: int, z: int) -> float:
	return stable_unit("biome-region-lattice:%s:%s:%d,%d" % [world_seed, channel, x, z])

func smooth_curve(value: float) -> float:
	var clamped := clampf(value, 0.0, 1.0)
	return clamped * clamped * (3.0 - 2.0 * clamped)

func smoothstep_range(value: float, low: float, high: float) -> float:
	if high <= low:
		return 1.0 if value >= high else 0.0
	var t := clampf((value - low) / (high - low), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

func stable_unit(text: String) -> float:
	var hash_value := 2166136261
	for index in range(text.length()):
		hash_value = int((hash_value ^ text.unicode_at(index)) * 16777619) & 0xffffffff
	return float(hash_value & 0x7fffffff) / float(0x7fffffff)
