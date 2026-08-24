extends RefCounted
class_name VoxelWorldGenerationContext

const CELL := 1.35
const CHUNK_SIZE := 28
const MIN_HEIGHT := 4.0
const MAX_HEIGHT := 120.0
const WATER_LEVEL := 11.1
const TOWN_REGION_CELLS := CHUNK_SIZE * 10
const TOWN_RADIUS_CELLS := 30
const TOWN_SPAWN_CHANCE := 0.18
const LANDMARK_MANIFEST_CACHE_METHODS := ["acquire_region", "wait_for_region", "heartbeat_region", "publish_region", "abort_region"]

var seed_text := "atlas-1492"
var seed_hash := 1
var height_noise: FastNoiseLite
var ridge_noise: FastNoiseLite
var flat_noise: FastNoiseLite
var moisture_noise: FastNoiseLite
var temp_noise: FastNoiseLite
var town_region_cache := {}
var pinned_town_regions := {}
var pinned_landmark_regions := {}
var landmark_manifest_cache
var generation_failure_authority
var town_slope_apron_cache := {}
var initial_terrain_edits := {}
# Worker contexts need the generator only for a few callback-style terrain
# queries. A strong reference here would close a RefCounted cycle with the
# short-lived WorldGenerationSystem created by VoxelTerrain's native workers.
var generator_ref: WeakRef

func setup_from_main(main) -> void:
	seed_text = String(main.get("seed_text"))
	seed_hash = int(main.get("seed_hash"))
	var main_town_cache = main.get("town_region_cache")
	if main_town_cache is Dictionary:
		for region_value in (main_town_cache as Dictionary).keys():
			if not (region_value is Vector2i):
				continue
			var town_value = main_town_cache[region_value]
			pinned_town_regions[region_value] = town_value.duplicate(true) if town_value is Dictionary else {}
	var settlement_sites = main.get("settlement_site_authority")
	if settlement_sites != null and settlement_sites.has_method("snapshot_by_region"):
		var reserved_regions: Dictionary = settlement_sites.call("snapshot_by_region")
		for region_value in reserved_regions.keys():
			if not (region_value is Vector2i):
				continue
			var reserved_value = reserved_regions[region_value]
			pinned_town_regions[region_value] = reserved_value.duplicate(true) if reserved_value is Dictionary else {}
	var landmark_sites = main.get("landmark_site_authority")
	if landmark_sites != null and landmark_sites.has_method("snapshot_by_region"):
		var landmark_regions: Dictionary = landmark_sites.call("snapshot_by_region")
		for region_value in landmark_regions.keys():
			if region_value is Vector2i and landmark_regions[region_value] is Array:
				pinned_landmark_regions[region_value] = (landmark_regions[region_value] as Array).duplicate(true)
	var world_generation = main.get("world_generation_system")
	var volume_service = world_generation.get("terrain_volume_service") if world_generation != null else null
	var edited_value = volume_service.get("edited_cells") if volume_service != null else null
	if edited_value is Dictionary:
		for cell_value in (edited_value as Dictionary).keys():
			if not (cell_value is Vector3i):
				continue
			var state: Dictionary = edited_value[cell_value] if edited_value[cell_value] is Dictionary else {}
			if volume_service.has_method("cell_state_affects_terrain_mesh") and not bool(volume_service.call("cell_state_affects_terrain_mesh", state)):
				continue
			initial_terrain_edits[cell_value] = state.duplicate(true)
	setup_noise()

func clone_for_worker():
	var context = get_script().new()
	context.seed_text = seed_text
	context.seed_hash = seed_hash
	context.pinned_town_regions = pinned_town_regions
	context.pinned_landmark_regions = pinned_landmark_regions
	context.landmark_manifest_cache = landmark_manifest_cache
	context.generation_failure_authority = generation_failure_authority
	context.initial_terrain_edits = initial_terrain_edits
	# These noise resources are immutable after setup and safe to share for
	# concurrent sampling. Reusing them avoids constructing five resources for
	# every 16^3 VoxelTerrain generation block.
	context.height_noise = height_noise
	context.ridge_noise = ridge_noise
	context.flat_noise = flat_noise
	context.moisture_noise = moisture_noise
	context.temp_noise = temp_noise
	return context

func set_generator(generator_node) -> void:
	generator_ref = weakref(generator_node) if generator_node != null else null

func active_generator():
	return generator_ref.get_ref() if generator_ref != null else null

func setup_noise() -> void:
	height_noise = make_noise(17, 0.0058, 4)
	ridge_noise = make_noise(43, 0.014, 3)
	flat_noise = make_noise(71, 0.0024, 3)
	moisture_noise = make_noise(107, 0.006, 3)
	temp_noise = make_noise(131, 0.005, 3)

func make_noise(salt: int, frequency: float, octaves: int) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = int((seed_hash + salt * 7919) & 0x7fffffff)
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = frequency
	noise.fractal_octaves = octaves
	noise.fractal_gain = 0.5
	noise.fractal_lacunarity = 2.0
	return noise

func town_region(region_x: int, region_z: int) -> Dictionary:
	var cache_key := Vector2i(region_x, region_z)
	if pinned_town_regions.has(cache_key):
		return pinned_town_regions[cache_key]
	if town_region_cache.has(cache_key):
		return town_region_cache[cache_key]
	var forced := region_x == 1 and region_z == 0
	if not forced and hash01("town:%d,%d" % [region_x, region_z]) > TOWN_SPAWN_CHANCE:
		town_region_cache[cache_key] = {}
		return {}
	var center_x := region_x * TOWN_REGION_CELLS
	var center_z := region_z * TOWN_REGION_CELLS
	var natural_level := WATER_LEVEL + 3.0
	var generation = active_generator()
	if generation != null and generation.has_method("natural_surface_y_for_cell"):
		natural_level = float(generation.call("natural_surface_y_for_cell", Vector3i(center_x, 0, center_z)))
	var level := clampf(round(maxf(natural_level, WATER_LEVEL + 3.0) / CELL) * CELL, WATER_LEVEL + 3.0, 52.0)
	var town := {
		"regionX": region_x,
		"regionZ": region_z,
		"centerX": center_x,
		"centerZ": center_z,
		"radius": town_radius_for_region(region_x, region_z, forced),
		"level": level
	}
	town_region_cache[cache_key] = town
	return town

func landmark_sites_for_region(region_x: int, region_z: int, _region_span := 420) -> Array:
	var key := Vector2i(region_x, region_z)
	if not landmark_manifest_cache_protocol_ready():
		report_generation_failure("landmark_manifest_cache_unavailable", {"region": key})
		return []
	while true:
		var cache_claim: Dictionary = landmark_manifest_cache.call("acquire_region", key)
		while String(cache_claim.get("state", "")) == "wait":
			cache_claim = landmark_manifest_cache.call("wait_for_region", key, cache_claim.get("semaphore", null))
		if String(cache_claim.get("state", "")) == "ready":
			return cache_claim.get("sites", []) if cache_claim.get("sites", []) is Array else []
		var claim = cache_claim.get("claim", null)
		if String(cache_claim.get("state", "")) != "owner" or claim == null:
			report_generation_failure("landmark_manifest_cache_invalid_claim", {"region": key, "state": String(cache_claim.get("state", ""))})
			return []
		var records: Array = []
		for record_value in registered_landmark_sites_for_region(region_x, region_z):
			records.append(record_value)
		var generation = active_generator()
		if generation == null or not generation.has_method("natural_landmark_site_sample"):
			if landmark_manifest_cache != null and landmark_manifest_cache.has_method("abort_region") and claim != null:
				landmark_manifest_cache.call("abort_region", key, claim, "landmark_manifest_worker_generator_unavailable")
			report_generation_failure("landmark_manifest_worker_generator_unavailable", {"region": key})
			return []
		var heartbeat_state := {"lost": false}
		var heartbeat := func() -> void:
			if landmark_manifest_cache != null and claim != null and not bool(landmark_manifest_cache.call("heartbeat_region", key, claim)):
				heartbeat_state["lost"] = true
		var catalog := preload("res://scripts/world/CitadelLandmarkCatalog.gd")
		var resolved: Dictionary = catalog.resolved_manifest_for_region(seed_text, seed_hash, region_x, region_z, Callable(generation, "natural_landmark_site_sample"), Callable(self, "town_region"), registered_landmark_sites_for_region(region_x, region_z), heartbeat)
		if bool(heartbeat_state.get("lost", false)):
			continue
		if not resolved.is_empty():
			var resolved_id := String(resolved.get("id", ""))
			if not records.any(func(value) -> bool: return value is Dictionary and String((value as Dictionary).get("id", "")) == resolved_id):
				records.append(resolved)
		records.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return String(left.get("id", "")) < String(right.get("id", "")))
		if bool(landmark_manifest_cache.call("publish_region", key, claim, records)):
			return records
	return []

func report_generation_failure(code: String, details: Dictionary = {}) -> void:
	if generation_failure_authority != null and generation_failure_authority.has_method("report_failure"):
		generation_failure_authority.call("report_failure", code, details)
		return
	push_error("Terrain generation authority failure %s without a failure authority: %s" % [code, JSON.stringify(details)])

func landmark_manifest_cache_protocol_ready() -> bool:
	if landmark_manifest_cache == null:
		return false
	for method_name_value in LANDMARK_MANIFEST_CACHE_METHODS:
		if not landmark_manifest_cache.has_method(String(method_name_value)):
			return false
	return true

func registered_landmark_sites_for_region(region_x: int, region_z: int) -> Array:
	var value = pinned_landmark_regions.get(Vector2i(region_x, region_z), [])
	return value if value is Array else []

func prewarm_landmark_regions(regions: Array, natural_surface_sample: Callable, town_region_resolver: Callable) -> int:
	if not landmark_manifest_cache_protocol_ready():
		report_generation_failure("landmark_manifest_prewarm_cache_unavailable")
		return 0
	if not natural_surface_sample.is_valid() or not town_region_resolver.is_valid():
		report_generation_failure("landmark_manifest_prewarm_inputs_invalid")
		return 0
	var catalog := preload("res://scripts/world/CitadelLandmarkCatalog.gd")
	var added := 0
	for region_value in regions:
		if not (region_value is Vector2i):
			report_generation_failure("landmark_manifest_prewarm_region_invalid", {"region": str(region_value)})
			continue
		var region: Vector2i = region_value
		while true:
			var cache_claim: Dictionary = landmark_manifest_cache.call("acquire_region", region)
			while String(cache_claim.get("state", "")) == "wait":
				cache_claim = landmark_manifest_cache.call("wait_for_region", region, cache_claim.get("semaphore", null))
			if String(cache_claim.get("state", "")) == "ready":
				break
			var claim = cache_claim.get("claim", null)
			if String(cache_claim.get("state", "")) != "owner" or claim == null:
				report_generation_failure("landmark_manifest_prewarm_invalid_claim", {"region": region, "state": String(cache_claim.get("state", ""))})
				break
			var records: Array = []
			for record_value in registered_landmark_sites_for_region(region.x, region.y):
				records.append(record_value)
			var heartbeat_state := {"lost": false}
			var heartbeat := func() -> void:
				if not bool(landmark_manifest_cache.call("heartbeat_region", region, claim)):
					heartbeat_state["lost"] = true
			var resolved: Dictionary = catalog.resolved_manifest_for_region(seed_text, seed_hash, region.x, region.y, natural_surface_sample, town_region_resolver, registered_landmark_sites_for_region(region.x, region.y), heartbeat)
			if bool(heartbeat_state.get("lost", false)):
				continue
			if not resolved.is_empty():
				records.append(resolved)
			records.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return String(left.get("id", "")) < String(right.get("id", "")))
			if bool(landmark_manifest_cache.call("publish_region", region, claim, records)):
				added += 1
				break
	return added

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
	return float(absi(hash_string("%s:%s" % [seed_text, text])) % 100000) / 100000.0

func hash_string(text: String) -> int:
	var value := 2166136261
	for index in range(text.length()):
		value = int((value ^ text.unicode_at(index)) * 16777619) & 0xffffffff
	return value

func noise01(noise: FastNoiseLite, x: float, z: float) -> float:
	return noise.get_noise_2d(x, z) * 0.5 + 0.5

func smoothstep_range(value: float, low: float, high: float) -> float:
	if high == low:
		return 1.0 if value >= high else 0.0
	var t := clampf((value - low) / (high - low), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
