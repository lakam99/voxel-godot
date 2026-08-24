extends SceneTree

const Planner := preload("res://scripts/world/CitadelSiteManifestPlanner.gd")
const TerrainPolicy := preload("res://scripts/world/CitadelTerrainOperationPolicy.gd")
const Authority := preload("res://scripts/world/LandmarkSiteAuthority.gd")
const Catalog := preload("res://scripts/world/CitadelLandmarkCatalog.gd")
const Context := preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const StoryReservationField := preload("res://scripts/story/data/StorySiteReservationField.gd")
const LandmarkManifestCache := preload("res://scripts/world/LandmarkManifestCache.gd")
const StructureSystemScript := preload("res://scripts/StructureSystem.gd")
const TerrainGenerationFailureAuthority := preload("res://scripts/terrain/TerrainGenerationFailureAuthority.gd")
const CitadelRecipeContext := preload("res://scripts/world/CitadelRecipeContext.gd")
const CitadelBlueprintBuildJob := preload("res://scripts/buildings/CitadelBlueprintBuildJob.gd")
const BuildingNavigationManifestBuilder := preload("res://scripts/buildings/BuildingNavigationManifestBuilder.gd")

class StaticNaturalSampler:
	extends RefCounted
	func natural_landmark_site_sample(_cell: Vector2i) -> Dictionary:
		return {
			"surfaceY": 27.0,
			"solid": true,
			"fluid": "",
			"biome": "plains",
			"inTown": false,
			"variation": 0.0,
			"waterLevel": 11.1
		}

class FakeStructureMain:
	extends Node3D
	const RENDER_DISTANCE := 4
	const CHUNK_SIZE := 16
	const CELL := 1.35
	var render_distance := 4
	var manifest: Dictionary = {}

	func landmark_sites_for_region(region_x: int, region_z: int, _region_span := 420) -> Array:
		if region_x == int(manifest.get("regionX", 0)) and region_z == int(manifest.get("regionZ", 0)):
			return [manifest.duplicate(true)]
		return []

class PartialManifestCache:
	extends RefCounted
	func acquire_region(_region: Vector2i) -> Dictionary:
		return {"state": "owner", "claim": RefCounted.new()}


func _init() -> void:
	var failures: Array[String] = []
	var first := first_manifest("citadel-contract-seed")
	var repeated := first_manifest("citadel-contract-seed")
	if first.is_empty() or repeated.is_empty() or first != repeated:
		failures.append("planner is not deterministic")
	var terrain: Dictionary = first.get("terrain", {}) if first.get("terrain", {}) is Dictionary else {}
	if not terrain.has("reservedBounds") or not terrain.has("blueprintFootprintBounds") or not terrain.has("terrainOperations"):
		failures.append("manifest omits terrain authority records")
	verify_terrain_grade_contract(failures)
	verify_exact_recipe_worker_replay(failures)
	var authority = Authority.new()
	authority.reset_for_seed("citadel-contract-seed")
	var registration: Dictionary = authority.register_site(first, int(first.get("siteRegionCells", 420)))
	if not bool(registration.get("accepted", false)):
		failures.append("typed landmark authority rejected a valid manifest")
	var overlapping := first.duplicate(true)
	overlapping["id"] = "%s:overlap" % String(first.get("id", ""))
	var overlap_result: Dictionary = authority.register_site(overlapping, int(first.get("siteRegionCells", 420)))
	if bool(overlap_result.get("accepted", false)):
		failures.append("typed landmark authority accepted an overlapping site")
	var center: Vector2i = first.get("center", Vector2i.ZERO)
	var region_span := int(first.get("siteRegionCells", 420))
	var sites: Array = authority.sites_for_region(floori(float(center.x) / float(region_span)), floori(float(center.y) / float(region_span)))
	if sites.size() != 1 or String((sites[0] as Dictionary).get("id", "")) != String(first.get("id", "")):
		failures.append("typed landmark registry lookup is incomplete")
	var sampler := StaticNaturalSampler.new()
	var context = Context.new()
	context.seed_text = "citadel-contract-seed"
	context.seed_hash = 9127
	context.setup_noise()
	context.landmark_manifest_cache = LandmarkManifestCache.new()
	context.set_generator(sampler)
	var distant_result := first_distant_manifest(context, sampler)
	var distant: Dictionary = distant_result.get("manifest", {}) if distant_result.get("manifest", {}) is Dictionary else {}
	if distant.is_empty():
		failures.append("implicit catalog did not resolve a distant region (raw=%d, town=%d)" % [int(distant_result.get("rawCandidates", 0)), int(distant_result.get("townConflicts", 0))])
	else:
		var distant_region := Vector2i(int(distant.get("regionX", 0)), int(distant.get("regionZ", 0)))
		context.prewarm_landmark_regions([distant_region], Callable(sampler, "natural_landmark_site_sample"), Callable(context, "town_region"))
		context.set_generator(null)
		var worker_sites: Array = context.landmark_sites_for_region(distant_region.x, distant_region.y)
		if not worker_sites.any(func(value) -> bool: return value is Dictionary and String((value as Dictionary).get("id", "")) == String(distant.get("id", ""))):
			failures.append("prewarmed worker context does not resolve the same distant manifest")
	var raw_catalog := Planner.manifest_for_region("citadel-contract-seed", int(first.get("regionX", 0)), int(first.get("regionZ", 0)), 420, Callable(self, "flat_natural_sample"))
	var typed_fixture := raw_catalog.duplicate(true)
	typed_fixture["id"] = "typed-landmark-conflict"
	var typed_conflict := Catalog.resolved_manifest_for_region("citadel-contract-seed", 9127, int(raw_catalog.get("regionX", 0)), int(raw_catalog.get("regionZ", 0)), Callable(sampler, "natural_landmark_site_sample"), Callable(self, "no_town"), [typed_fixture])
	if raw_catalog.is_empty():
		failures.append("typed landmark collision fixture is missing")
	elif not typed_conflict.is_empty():
		failures.append("implicit citadel overlaps a typed landmark")
	var blocked_story_sites := StoryReservationField.sites_for_region("citadel-contract-seed", 9127, 0, 0, Callable(self, "blocked_story_sample"))
	if not blocked_story_sites.is_empty():
		failures.append("story field emits a marker without a valid location")
	verify_structure_system_manifest_consumption(first, failures)
	verify_missing_cache_blocks_generation(failures)
	verify_manifest_cache_contracts(failures)
	if failures.is_empty():
		print("CitadelSiteManifestContractRunner: PASS")
		quit(0)
		return
	push_error("CitadelSiteManifestContractRunner: %s" % JSON.stringify(failures))
	quit(1)


func first_manifest(seed_text: String) -> Dictionary:
	for region_z in range(-6, 7):
		for region_x in range(-6, 7):
			var manifest := Planner.manifest_for_region(seed_text, region_x, region_z, 420, Callable(self, "natural_sample"))
			if not manifest.is_empty():
				return manifest
	return {}


func natural_sample(cell: Vector3i) -> Dictionary:
	return {
		"surfaceY": 27.0 + float(posmod(cell.x + cell.z, 3)) * 0.4,
		"solid": true,
		"fluid": "",
		"biome": "plains"
	}

func first_distant_manifest(context, sampler) -> Dictionary:
	var raw_candidates := 0
	var town_conflicts := 0
	for region_z in range(40, 55):
		for region_x in range(40, 55):
			var raw := Planner.manifest_for_region(String(context.seed_text), region_x, region_z, 420, Callable(self, "flat_natural_sample"))
			if not raw.is_empty():
				raw_candidates += 1
				var reservations: Array = Catalog.reservations_for_neighborhood(String(context.seed_text), int(context.seed_hash), region_x, region_z, Callable(sampler, "natural_landmark_site_sample"), Callable(context, "town_region"))
				for reservation_value in reservations:
					if not (reservation_value is Dictionary) or not Planner.conflicts_with_reservations(raw, [reservation_value]):
						continue
					if String((reservation_value as Dictionary).get("kind", "")) == "town":
						town_conflicts += 1
			var manifest: Dictionary = Catalog.resolved_manifest_for_region(
				String(context.seed_text),
				int(context.seed_hash),
				region_x,
				region_z,
				Callable(sampler, "natural_landmark_site_sample"),
				Callable(context, "town_region")
			)
			if not manifest.is_empty():
				return {"manifest": manifest, "rawCandidates": raw_candidates, "townConflicts": town_conflicts}
	return {"manifest": {}, "rawCandidates": raw_candidates, "townConflicts": town_conflicts}

func flat_natural_sample(_cell: Vector3i) -> Dictionary:
	return {"surfaceY": 27.0, "solid": true, "fluid": "", "biome": "plains"}

func no_town(_region_x: int, _region_z: int) -> Dictionary:
	return {}

func blocked_story_sample(_cell: Vector2i) -> Dictionary:
	return {"surfaceY": 27.0, "solid": true, "fluid": "", "biome": "plains", "inTown": false, "inLandmark": true, "variation": 0.0, "waterLevel": 11.1}

func verify_terrain_grade_contract(failures: Array[String]) -> void:
	var accepted: Dictionary = Planner._terrain_contract({"center": Vector2i.ZERO}, Callable(self, "accepted_grade_sample"))
	if accepted.is_empty():
		failures.append("terrain contract rejects a solid lowland site within the declared approach grade")
	else:
		var proof: Dictionary = accepted.get("terrainProof", {}) if accepted.get("terrainProof", {}) is Dictionary else {}
		if absf(float(proof.get("maximumApproachGrade", 0.0)) - TerrainPolicy.MAX_APPROACH_GRADE) > 0.0001 or int(proof.get("approachCells", 0)) < TerrainPolicy.MIN_APPROACH_CELLS or int(proof.get("approachCells", 0)) > TerrainPolicy.MAX_APPROACH_CELLS:
			failures.append("terrain contract omits its physical approach-grade proof")
	var rejected: Dictionary = Planner._terrain_contract({"center": Vector2i.ZERO}, Callable(self, "excessive_grade_sample"))
	if not rejected.is_empty():
		failures.append("terrain contract accepts a site steeper than its published approach grade")
	var fluid_rejected: Dictionary = Planner._terrain_contract({"center": Vector2i.ZERO}, Callable(self, "fluid_grade_sample"))
	if not fluid_rejected.is_empty():
		failures.append("terrain contract accepts fluid support because elevation is otherwise valid")

func accepted_grade_sample(cell: Vector3i) -> Dictionary:
	return {"surfaceY": 16.2 + (2.0 if cell.x > 0 else -2.0), "solid": true, "fluid": "", "biome": "plains", "waterLevel": 11.1}

func excessive_grade_sample(cell: Vector3i) -> Dictionary:
	return {"surfaceY": 27.0 + (20.0 if cell.x > 0 else -20.0), "solid": true, "fluid": "", "biome": "plains", "waterLevel": 11.1}

func fluid_grade_sample(_cell: Vector3i) -> Dictionary:
	return {"surfaceY": 27.0, "solid": true, "fluid": "water", "biome": "plains"}

func verify_exact_recipe_worker_replay(failures: Array[String]) -> void:
	var manifest := {
		"id": "citadel:-1,5",
		"blueprintSeed": 1265777314,
		"citadelProfile": "standard",
		"citadelScale": 1.0,
		"blueprintEnvelopeRadiusCells": 76,
		"centerX": -267,
		"centerZ": 2351,
		"level": 22.95,
		"terrain": {"biome": "plains"}
	}
	var context_result: Dictionary = CitadelRecipeContext.from_manifest(manifest, 1.35)
	if not bool(context_result.get("ok", false)):
		failures.append("exact production recipe tuple did not serialize")
		return
	var incomplete := manifest.duplicate(true)
	incomplete.erase("citadelScale")
	if bool(CitadelRecipeContext.from_manifest(incomplete, 1.35).get("ok", false)):
		failures.append("recipe context accepts a missing manifest-owned citadel scale")
	var missing_envelope := manifest.duplicate(true)
	missing_envelope.erase("blueprintEnvelopeRadiusCells")
	if bool(CitadelRecipeContext.from_manifest(missing_envelope, 1.35).get("ok", false)):
		failures.append("recipe context accepts a missing manifest-owned collision envelope")
	var context: Dictionary = context_result.get("context", {}) as Dictionary
	context["recipeContextSignature"] = String(context_result.get("signature", ""))
	var job = CitadelBlueprintBuildJob.new()
	job.run(int(context_result.get("blueprintSeed", 0)), context)
	var result: Dictionary = job.result_snapshot()
	if result.get("blueprint") == null or result.get("furnishingPlan") == null or not bool((result.get("residenceValidation", {}) as Dictionary).get("passed", false)):
		failures.append("exact production recipe worker replay failed: %s" % JSON.stringify({"failureReason": result.get("failureReason", ""), "buildDiagnostics": result.get("buildDiagnostics", {})}))
	if String(result.get("recipeContextSignature", "")) != String(context_result.get("signature", "")):
		failures.append("recipe worker did not preserve the exact manifest context signature")
	if not bool((result.get("envelopeValidation", {}) as Dictionary).get("passed", false)):
		failures.append("recipe worker collision envelope exceeded its manifest reservation: %s" % JSON.stringify(result.get("envelopeValidation", {})))
	var blueprint = result.get("blueprint")
	if blueprint != null:
		var navigation_manifest := BuildingNavigationManifestBuilder.build(blueprint)
		var transition_part_ids := {}
		var navigation_support_ids := {}
		for support_value in navigation_manifest.get("supports", []) as Array:
			if support_value is Dictionary:
				navigation_support_ids[String((support_value as Dictionary).get("id", ""))] = true
		for link_value in navigation_manifest.get("verticalLinks", []) as Array:
			if link_value is Dictionary:
				transition_part_ids[String((link_value as Dictionary).get("sourcePartId", ""))] = link_value
		for residence_value in blueprint.recipe.get("courtyardResidences", []) as Array:
			if not (residence_value is Dictionary):
				continue
			var residence_id := String((residence_value as Dictionary).get("id", ""))
			var ramp_part_id := "castle_%s__front_entry_ramp" % residence_id
			if not transition_part_ids.has(ramp_part_id):
				failures.append("exact production recipe omitted declared residence transition %s" % ramp_part_id)
				continue
			var transition: Dictionary = transition_part_ids.get(ramp_part_id, {}) as Dictionary
			if String(transition.get("startSupportId", "")).is_empty() or String(transition.get("endSupportId", "")).is_empty():
				failures.append("exact production residence transition lacks landing supports: %s" % JSON.stringify(transition))
			elif not navigation_support_ids.has(String(transition.get("startSupportId", ""))) or not navigation_support_ids.has(String(transition.get("endSupportId", ""))):
				failures.append("exact production residence transition references an unpublished landing support: %s" % JSON.stringify(transition))

func verify_structure_system_manifest_consumption(manifest: Dictionary, failures: Array[String]) -> void:
	var fake_main := FakeStructureMain.new()
	fake_main.manifest = manifest.duplicate(true)
	root.add_child(fake_main)
	var structures = StructureSystemScript.new()
	structures.setup(fake_main)
	structures.update_citadels(manifest.get("center", Vector2i.ZERO) as Vector2i, true)
	if structures.pending_structure_op_count() != 1:
		failures.append("StructureSystem did not queue one manifest-driven citadel build")
		return
	var op: Dictionary = structures.pending_structure_ops[structures.pending_structure_op_index] as Dictionary
	var queued_manifest: Dictionary = op.get("manifest", {}) if op.get("manifest", {}) is Dictionary else {}
	if String(op.get("type", "")) != "citadel_build_start" or String(queued_manifest.get("id", "")) != String(manifest.get("id", "")):
		failures.append("StructureSystem replaced the authoritative citadel manifest while queueing publication")

func verify_missing_cache_blocks_generation(failures: Array[String]) -> void:
	var context = Context.new()
	context.generation_failure_authority = TerrainGenerationFailureAuthority.new()
	var sites: Array = context.landmark_sites_for_region(2, 3)
	var failure: Dictionary = context.generation_failure_authority.snapshot()
	if not sites.is_empty() or String(failure.get("code", "")) != "landmark_manifest_cache_unavailable":
		failures.append("missing landmark cache does not publish a typed terrain generation failure")
	var prewarm_context = Context.new()
	prewarm_context.generation_failure_authority = TerrainGenerationFailureAuthority.new()
	prewarm_context.prewarm_landmark_regions([Vector2i.ZERO], Callable(self, "flat_natural_sample"), Callable(self, "no_town"))
	var prewarm_failure: Dictionary = prewarm_context.generation_failure_authority.snapshot()
	if String(prewarm_failure.get("code", "")) != "landmark_manifest_prewarm_cache_unavailable":
		failures.append("missing landmark cache does not block required initial prewarm")
	var partial_context = Context.new()
	partial_context.landmark_manifest_cache = PartialManifestCache.new()
	partial_context.generation_failure_authority = TerrainGenerationFailureAuthority.new()
	partial_context.landmark_sites_for_region(4, 5)
	var partial_failure: Dictionary = partial_context.generation_failure_authority.snapshot()
	if String(partial_failure.get("code", "")) != "landmark_manifest_cache_unavailable":
		failures.append("partial landmark cache protocol can bypass typed terrain failure")

func verify_manifest_cache_contracts(failures: Array[String]) -> void:
	var cache = LandmarkManifestCache.new()
	var published_region := Vector2i(8, 9)
	var owner: Dictionary = cache.acquire_region(published_region)
	var waiter: Dictionary = cache.acquire_region(published_region)
	if String(owner.get("state", "")) != "owner" or String(waiter.get("state", "")) != "wait":
		failures.append("manifest cache does not establish single-flight ownership")
		return
	if cache.publish_region(published_region, RefCounted.new(), [{"id": "poison"}]):
		failures.append("manifest cache accepted a non-owner publisher")
	if not cache.publish_region(published_region, owner.get("claim", null), [{"id": "published"}]):
		failures.append("manifest cache rejected its owner publisher")
	var waited: Dictionary = cache.wait_for_region(published_region, waiter.get("semaphore", null))
	var waited_sites: Array = waited.get("sites", []) if waited.get("sites", []) is Array else []
	if String(waited.get("state", "")) != "ready" or waited_sites.is_empty() or String((waited_sites[0] as Dictionary).get("id", "")) != "published":
		failures.append("manifest cache waiter did not receive published records")
	var ready: Dictionary = cache.acquire_region(published_region)
	var ready_sites: Array = ready.get("sites", []) if ready.get("sites", []) is Array else []
	if not ready_sites.is_empty():
		(ready_sites[0] as Dictionary)["id"] = "mutated"
	var repeated: Dictionary = cache.acquire_region(published_region)
	var repeated_sites: Array = repeated.get("sites", []) if repeated.get("sites", []) is Array else []
	if repeated_sites.is_empty() or String((repeated_sites[0] as Dictionary).get("id", "")) != "published":
		failures.append("manifest cache exposed mutable internal records")
	var aborted_region := Vector2i(10, 11)
	var abort_owner: Dictionary = cache.acquire_region(aborted_region)
	var abort_waiter: Dictionary = cache.acquire_region(aborted_region)
	if not cache.abort_region(aborted_region, abort_owner.get("claim", null), "fixture_abort"):
		failures.append("manifest cache rejected its owner abort")
	else:
		var abort_result: Dictionary = cache.wait_for_region(aborted_region, abort_waiter.get("semaphore", null))
		if String(abort_result.get("state", "")) != "owner" or abort_result.get("claim", null) == null:
			failures.append("manifest cache abort did not wake a deterministic retry owner")
		else:
			if cache.publish_region(aborted_region, abort_owner.get("claim", null), [{"id": "stale"}]):
				failures.append("manifest cache accepted a stale owner after successor claim")
			cache.publish_region(aborted_region, abort_result.get("claim", null), [])
