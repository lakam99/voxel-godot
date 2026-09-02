extends RefCounted
class_name CitadelSitePreparation

## Owned-worker operation, never a main-frame call. The one shared recipe
## produces local geometry; only the ordinary WGS will publish its ground.
## No scene, NPC, navigation, tree publication or save state is created here.
const Field := preload("res://scripts/world/CitadelSiteField.gd")
const Survey := preload("res://scripts/world/CitadelSiteSurvey.gd")
const Source := preload("res://scripts/buildings/CitadelRecipePreparation.gd")
const Manifest := preload("res://scripts/buildings/BuildingSiteManifestBuilder.gd")
const Profile := preload("res://scripts/world/BuildingTerrainProfile.gd")
const Standalone := preload("res://scripts/world/StandaloneStructureCandidate.gd")
const CELL := 1.35
const SCALE := 1.25
const MIN_APRON_CELLS := 18
# Rise/run contribution from blending to a level pad. This does not certify
# native collision slope: the natural field also has its own local variation.
const BLEND_RISE_PER_RUN := 0.35
# A declaration used for safe prefetch. Final actual geometry must fit; an
# oversized source fails explicitly, never clips, shrinks or relocates.
const MAX_INFLUENCE_RADIUS_CELLS := 384


static func prepare(world_seed: String, region: Vector2i, town_overrides: Dictionary, ordinary_structure_policy: Dictionary, continue_stage: Callable = Callable()) -> Dictionary:
	var started := Time.get_ticks_usec()
	var candidate := Field.candidate_for_region(world_seed, region)
	if candidate.is_empty(): return _result("absent", "no_candidate")
	if not _continue(continue_stage, "site_center_survey"): return _result("cancelled", "cancelled")
	var survey := Survey.new()
	var center: Vector2i = candidate.centerCell
	var center_result := survey.begin(world_seed, region, Rect2i(center, Vector2i.ONE), town_overrides)
	while center_result.status == "pending_budget":
		if not _continue(continue_stage, "site_center_survey"): return _result("cancelled", "cancelled")
		center_result = survey.advance()
	if center_result.status != "surveyed":
		return _survey_failure(center_result)
	var biomes: Array = center_result.biomeCounts.keys()
	var context := {"biome": String(biomes[0]), "siteKey": candidate.siteId, "citadelScale": SCALE}
	var source := Source.prepare(int(candidate.recipeSeed), context, continue_stage)
	if not source.get("ready", false):
		var failed := _result("cancelled" if source.get("reason") == "cancelled" else "failed", String(source.get("reason", "source_preparation_failed")))
		failed["sourceFailure"] = source
		return failed
	if not _continue(continue_stage, "site_geometry_manifest"): return _result("cancelled", "cancelled")
	var manifest := Manifest.build(source.blueprint, source.furnishingPlan, CELL)
	if not manifest.ready: return _result("failed", manifest.reason)
	var level := roundf(float(center_result.minimumSurfaceY) / CELL) * CELL
	var terrain := prepare_terrain(manifest, candidate, town_overrides, level, ordinary_structure_policy, continue_stage)
	if terrain.status != "prepared": return terrain
	terrain["candidate"] = candidate
	terrain["blueprint"] = source.blueprint
	terrain["furnishingPlan"] = source.furnishingPlan
	terrain["interiorProgram"] = source.interiorProgram
	terrain["manifest"] = manifest
	terrain["sourceContext"] = context
	terrain["preparationUsec"] = Time.get_ticks_usec() - started
	return terrain


static func prepare_terrain(manifest: Dictionary, candidate: Dictionary, town_overrides: Dictionary, level: float, ordinary_structure_policy: Dictionary, continue_stage: Callable = Callable()) -> Dictionary:
	var region_cells := int(ordinary_structure_policy.get("regionCells", 0))
	var spawn_chance := float(ordinary_structure_policy.get("spawnChance", NAN))
	if region_cells < 34 or not is_finite(spawn_chance) or spawn_chance < 0.0 or spawn_chance > 1.0:
		return _result("failed", "invalid_ordinary_structure_policy")
	if candidate.is_empty() or not candidate.get("region") is Vector2i or candidate != Field.candidate_for_region(String(candidate.get("worldSeed", "")), candidate.region):
		return _result("failed", "invalid_site_candidate")
	var center: Vector2i = candidate.centerCell
	var declared := Rect2i(center - Vector2i.ONE * MAX_INFLUENCE_RADIUS_CELLS, Vector2i.ONE * (MAX_INFLUENCE_RADIUS_CELLS * 2 + 1))
	var apron := MIN_APRON_CELLS
	while apron <= Profile.MAX_APRON_CELLS:
		if not _continue(continue_stage, "site_full_envelope_survey"): return _result("cancelled", "cancelled")
		var made := Profile.create(manifest, candidate.worldSeed, candidate.siteId, center, level, apron, CELL)
		if not made.ready: return _result("failed", made.reason)
		var profile: Dictionary = made.profile
		# One extra column covers floating-grid rounding in density sampling.
		# Native mesh/block admission will add its own independently measured halo.
		var influence: Rect2i = profile.envelopeCells.grow(1)
		var reservation: Rect2i = influence.merge(profile.reservationCells)
		if not declared.encloses(reservation) or not Field.reservation_fits_region(candidate.region, reservation):
			return _result("failed", "geometry_exceeds_declared_site_influence")
		var conflict := _standalone_conflict(candidate.worldSeed, reservation, region_cells, spawn_chance)
		if not conflict.is_empty():
			var rejected := _result("absent", "ordinary_structure_overlap")
			rejected["conflict"] = conflict
			return rejected
		var survey := Survey.new()
		var result := survey.begin(candidate.worldSeed, candidate.region, influence, town_overrides)
		while result.status == "pending_budget":
			if not _continue(continue_stage, "site_full_envelope_survey"): return _result("cancelled", "cancelled")
			result = survey.advance()
		if result.status != "surveyed": return _survey_failure(result)
		# Visual-only space is reserved/surveyed but never used to choose the
		# grading plane or terrain support policy.
		if reservation != influence:
			var visual_survey := Survey.new()
			var visual_result := visual_survey.begin(candidate.worldSeed,candidate.region,reservation,town_overrides)
			while visual_result.status == "pending_budget":
				if not _continue(continue_stage,"site_visual_reservation_survey"): return _result("cancelled","cancelled")
				visual_result = visual_survey.advance()
			if visual_result.status != "surveyed": return _survey_failure(visual_result)
		# The source ground plane is zero, but its world elevation belongs to the
		# ENTIRE site, not a possibly outlying center cell. Midrange minimizes the
		# largest cut/fill distance (with one-cell quantization), treating peaks
		# and valleys symmetrically. Repeat after expansion before final admission.
		level = roundf((float(result.minimumSurfaceY) + float(result.maximumSurfaceY)) * 0.5 / CELL) * CELL
		var height_delta := maxf(absf(level - float(result.minimumSurfaceY)), absf(level - float(result.maximumSurfaceY)))
		# max derivative of smoothstep is 1.5. Increasing the apron can encounter
		# new elevations, so survey its WHOLE enlarged footprint again to a fixed
		# point. This deterministic rule is independent of scheduler/query order.
		var required := maxi(MIN_APRON_CELLS, ceili(1.5 * height_delta / (CELL * BLEND_RISE_PER_RUN)))
		if required <= apron:
			made = Profile.create(manifest, candidate.worldSeed, candidate.siteId, center, level, apron, CELL)
			if not made.ready: return _result("failed", made.reason)
			profile = made.profile
			return {"status": "prepared", "reason": "", "profile": profile,
				"survey": result, "influenceCells": influence, "reservationCells": reservation,
				"gradingRule": "quantized_minimax_cut_fill_over_full_envelope",
				"terrainReady": false, "publicationReady": false}
		apron = required
	return _result("absent", "terrain_relief_exceeds_supported_apron")


static func _standalone_conflict(world_seed: String, influence: Rect2i, region_cells: int, spawn_chance: float) -> Dictionary:
	# Current ordinary sources are contained in their home region plus small
	# approaches. Include adjacent regions; no flatness query on modified ground.
	var low := Vector2i(floori(float(influence.position.x) / region_cells), floori(float(influence.position.y) / region_cells)) - Vector2i.ONE
	var high := Vector2i(floori(float(influence.end.x - 1) / region_cells), floori(float(influence.end.y - 1) / region_cells)) + Vector2i.ONE
	for z in range(low.y, high.y + 1):
		for x in range(low.x, high.x + 1):
			var candidate := Standalone.candidate_for_region(world_seed, Vector2i(x,z), region_cells, spawn_chance)
			if candidate.is_empty(): continue
			var bounds := Standalone.terrain_influence_for_candidate(candidate)
			if not bounds.bounded or influence.intersects(bounds.influenceCells):
				return candidate
	return {}


static func _survey_failure(survey: Dictionary) -> Dictionary:
	var reason := String(survey.reason)
	var excluded := reason == "town_reservation_overlap" or reason.begins_with("excluded_biome:")
	var result := _result("absent" if excluded else "failed", reason)
	result["survey"] = survey
	return result


static func _continue(callback: Callable, stage: String) -> bool:
	return not callback.is_valid() or callback.call(stage) == true


static func _result(status: String, reason: String) -> Dictionary:
	return {"status": status, "reason": reason, "terrainReady": false, "publicationReady": false}
