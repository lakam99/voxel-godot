extends RefCounted
class_name TreeRecipeCache

## Main-thread bounded cache for immutable tree recipes.  Recipe generation is
## intentionally pure and worker-safe; cache ownership remains on the
## publication queue so worker threads never contend over shared state.
##
## Stored recipes are read-only after publication.  Returning the same recipe
## object is deliberate: deep-copying hundreds of branch and foliage records
## in a gameplay frame would recreate the hitch this cache is meant to avoid.

const DEFAULT_ENTRY_CAPACITY := 96
const DEFAULT_BYTE_CAPACITY := 12 * 1024 * 1024
const RECIPE_FIXED_COST_BYTES := 2048
const BRANCH_ESTIMATE_BYTES := 192
const FOLIAGE_ESTIMATE_BYTES := 128

var entry_capacity := DEFAULT_ENTRY_CAPACITY
var byte_capacity := DEFAULT_BYTE_CAPACITY
var recipes := {}
var access_ticks := {}
var recipe_bytes := {}
## Cache metadata deliberately remains separate from the immutable recipe
## dictionary.  The queue can find a higher-detail graph for a deterministic
## tree and derive a lower LOD on a worker without pinning an extra copy of
## the graph outside this bounded cache.
var recipe_identity_keys := {}
var recipe_lod_tiers := {}
# Identity -> { near|mid|far: exact cache key }.  Streaming frequently asks
# whether an already-cached tree can downshift to a cheaper LOD; a global scan
# over every retained recipe is bounded, but still needless main-thread work
# while chunks are arriving.  This index remains cache-owned and is removed
# with eviction, so it cannot retain an unbounded second recipe graph.
var recipe_identity_lod_keys := {}
var access_tick := 0
var estimated_bytes := 0
var hits := 0
var misses := 0
var evictions := 0
var oversized_rejections := 0
var lod_derivation_hits := 0
var lod_derivation_misses := 0
var lod_derivation_index_lookups := 0

func configure(max_entries: int, max_bytes: int) -> void:
	entry_capacity = maxi(1, max_entries)
	byte_capacity = maxi(1024, max_bytes)
	trim_to_capacity()

func fetch(key: String) -> Dictionary:
	if key == "" or not recipes.has(key):
		misses += 1
		return {}
	hits += 1
	touch(key)
	return recipes[key] as Dictionary

func store(key: String, recipe: Dictionary, identity_key := "", lod_tier := "") -> bool:
	if key == "" or recipe.is_empty():
		return false
	var bytes := estimate_recipe_bytes(recipe)
	if bytes > byte_capacity:
		oversized_rejections += 1
		return false
	if recipes.has(key):
		remove_entry(key)
	while (recipes.size() >= entry_capacity or estimated_bytes + bytes > byte_capacity) and not recipes.is_empty():
		evict_oldest()
	recipes[key] = recipe
	recipe_bytes[key] = bytes
	recipe_identity_keys[key] = identity_key
	recipe_lod_tiers[key] = lod_tier
	index_identity_lod_key(identity_key, lod_tier, key)
	estimated_bytes += bytes
	touch(key)
	return true

func fetch_compatible_lod_source(identity_key: String, requested_lod_tier: String) -> Dictionary:
	# Reuse only a graph with at least the requested detail.  Growing a distant
	# tree at near quality just to populate a cache would trade worker pressure
	# for a distant-tree cost regression, so this is intentionally a one-way
	# near -> mid -> far reduction.
	var requested_rank := lod_detail_rank(requested_lod_tier)
	if identity_key == "" or requested_rank <= 0:
		lod_derivation_misses += 1
		return {}
	lod_derivation_index_lookups += 1
	var indexed_tiers: Dictionary = recipe_identity_lod_keys.get(identity_key, {})
	var selected_key := ""
	# Prefer the closest available detail source.  This is still one-way
	# downshift reuse: a far recipe never becomes a near one.
	for candidate_tier in compatible_source_tiers(requested_lod_tier):
		var candidate_key := String(indexed_tiers.get(candidate_tier, ""))
		if candidate_key == "":
			continue
		var candidate: Dictionary = recipes.get(candidate_key, {})
		if candidate.is_empty():
			continue
		selected_key = candidate_key
		break
	if selected_key == "":
		lod_derivation_misses += 1
		return {}
	lod_derivation_hits += 1
	touch(selected_key)
	return recipes.get(selected_key, {}) as Dictionary

func clear() -> void:
	recipes.clear()
	access_ticks.clear()
	recipe_bytes.clear()
	recipe_identity_keys.clear()
	recipe_lod_tiers.clear()
	recipe_identity_lod_keys.clear()
	estimated_bytes = 0

func metrics() -> Dictionary:
	return {
		"entries": recipes.size(),
		"entryCapacity": entry_capacity,
		"estimatedBytes": estimated_bytes,
		"byteCapacity": byte_capacity,
		"hits": hits,
		"misses": misses,
		"evictions": evictions,
		"oversizedRejections": oversized_rejections,
		"lodDerivationHits": lod_derivation_hits,
		"lodDerivationMisses": lod_derivation_misses,
		"lodDerivationIndexLookups": lod_derivation_index_lookups
	}

func estimate_recipe_bytes(recipe: Dictionary) -> int:
	var branches: Array = recipe.get("branches", [])
	var foliage: Array = recipe.get("foliage", [])
	return RECIPE_FIXED_COST_BYTES + branches.size() * BRANCH_ESTIMATE_BYTES + foliage.size() * FOLIAGE_ESTIMATE_BYTES

func touch(key: String) -> void:
	access_tick += 1
	access_ticks[key] = access_tick

func trim_to_capacity() -> void:
	while (recipes.size() > entry_capacity or estimated_bytes > byte_capacity) and not recipes.is_empty():
		evict_oldest()

func evict_oldest() -> void:
	var oldest_key := ""
	var oldest_tick := 9223372036854775807
	for key_value in access_ticks.keys():
		var key := String(key_value)
		var tick := int(access_ticks.get(key, oldest_tick))
		if tick < oldest_tick:
			oldest_tick = tick
			oldest_key = key
	if oldest_key == "":
		return
	remove_entry(oldest_key)
	evictions += 1

func remove_entry(key: String) -> void:
	var identity_key := String(recipe_identity_keys.get(key, ""))
	var lod_tier := String(recipe_lod_tiers.get(key, ""))
	estimated_bytes = maxi(0, estimated_bytes - int(recipe_bytes.get(key, 0)))
	recipes.erase(key)
	recipe_bytes.erase(key)
	access_ticks.erase(key)
	recipe_identity_keys.erase(key)
	recipe_lod_tiers.erase(key)
	if identity_key != "" and recipe_identity_lod_keys.has(identity_key):
		var indexed_tiers: Dictionary = recipe_identity_lod_keys.get(identity_key, {})
		if String(indexed_tiers.get(lod_tier, "")) == key:
			indexed_tiers.erase(lod_tier)
		if indexed_tiers.is_empty():
			recipe_identity_lod_keys.erase(identity_key)
		else:
			recipe_identity_lod_keys[identity_key] = indexed_tiers

func index_identity_lod_key(identity_key: String, lod_tier: String, key: String) -> void:
	if identity_key == "" or lod_detail_rank(lod_tier) <= 0:
		return
	var indexed_tiers: Dictionary = recipe_identity_lod_keys.get(identity_key, {})
	indexed_tiers[lod_tier] = key
	recipe_identity_lod_keys[identity_key] = indexed_tiers

func compatible_source_tiers(requested_lod_tier: String) -> Array[String]:
	match requested_lod_tier.strip_edges().to_lower():
		"near": return ["near"]
		"mid": return ["mid", "near"]
		"far": return ["far", "mid", "near"]
		_: return []

func lod_detail_rank(lod_tier: String) -> int:
	match lod_tier.strip_edges().to_lower():
		"near": return 3
		"mid": return 2
		"far": return 1
		_: return 0
