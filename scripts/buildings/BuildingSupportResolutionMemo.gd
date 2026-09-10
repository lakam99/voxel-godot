extends "res://scripts/buildings/BuildingBlueprint.gd"

## Private base-implementation proof copies only. Cache sample resolution within
## one completion transaction, never root reachability or a validation report.
## Exact ordered indexed geometry and target query inputs bind every result.
var identities: Dictionary = {}
var observed := false
var resolving := false
var observations := {"poolRepeated":false,"hits":0,"misses":0,"candidates":0,"identityUsec":0,"resolutionUsec":0}

func _native_support_implementation_supported() -> bool:
	return get_script()==load("res://scripts/buildings/BuildingSupportResolutionMemo.gd")

func _resolve_physical_contracts(continuation: Callable) -> bool:
	observed = false
	resolving = true
	var completed := super._resolve_physical_contracts(continuation)
	resolving = false
	if not completed: identities.clear()
	return completed

func _cancel_physical_validation(cache_owner: bool) -> Dictionary:
	identities.clear()
	return super._cancel_physical_validation(cache_owner)

func resolved_support_record(target) -> Dictionary:
	if not resolving: return super.resolved_support_record(target)
	var started := Time.get_ticks_usec()
	if not observed:
		observed = true
		var pool: Array = []
		var ids: Dictionary = {}
		var unique := true
		for candidate in parts:
			if candidate == null: continue
			if ids.has(String(candidate.id)): unique = false
			ids[String(candidate.id)] = true
			if not is_structural_support_candidate(candidate) or not has_finite_positive_bounds(candidate): continue
			pool.append([String(candidate.id),candidate.position,candidate.rotation,candidate.size,
				bool(candidate.collision_enabled),String(candidate.physical_intent),bool(candidate.recipe.get("physicalRoot",false))])
		var binding := var_to_bytes(pool)
		observations.candidates = pool.size()
		observations.poolRepeated = unique and identities.get("pool",PackedByteArray()) == binding
		if not observations.poolRepeated: identities["targets"] = {}
		identities["pool"] = binding
		identities["unique"] = unique
	var key := var_to_bytes([String(target.id),target.position,target.rotation,target.size,String(target.physical_intent),
		target.recipe.get("physicalRequiredSupportPartIds",[]),bool(target.recipe.get("allowEnclosingStructuralSupport",false)),
		String(target.recipe.get("physicalSupportsPartId",""))]).hex_encode()
	var repeated: bool = identities.unique and parts.has(target) and identities.targets.has(key)
	if repeated: observations.hits += 1
	else: observations.misses += 1
	observations.identityUsec += Time.get_ticks_usec()-started
	if repeated: return identities.targets[key].duplicate(true)
	started = Time.get_ticks_usec()
	var result := super.resolved_support_record(target)
	var elapsed := Time.get_ticks_usec()-started
	observations.resolutionUsec += elapsed
	if identities.unique and parts.has(target):
		if identities.targets.size()>=10000: identities.targets.clear()
		identities.targets[key] = result.duplicate(true)
	return result
