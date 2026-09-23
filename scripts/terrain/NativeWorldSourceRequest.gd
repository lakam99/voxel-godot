extends RefCounted
class_name NativeWorldSourceRequest

const WORLD_GENERATION := preload("res://scripts/WorldGenerationSystem.gd")
const SITE_QUEUE := preload("res://scripts/world/CitadelSiteBuildQueue.gd")
const SITE_SURVEY := preload("res://scripts/world/CitadelSiteSurvey.gd")

# Constructs the native initialization envelope from the same finalized inputs
# used by production site admission. This does not request or sample terrain.
static func from_main(main) -> Dictionary:
	if main == null:
		return _failed("main_missing")
	var seed := String(main.get("seed_text"))
	if seed.is_empty():
		return _failed("seed_missing")
	var structures = main.get("structure_system")
	if structures == null:
		return _failed("structure_system_missing")
	var admission = structures.get("citadel_terrain_admission")
	if admission == null or admission.profile_store == null:
		return _failed("site_admission_missing")
	if String(admission.world_seed) != seed or String(admission.profile_store.world_seed()) != seed:
		return _failed("site_admission_seed_mismatch")
	var finalized: Dictionary = admission.finalize_town_inputs(main.get("town_region_cache"))
	if String(finalized.get("status", "")) != "ready":
		return _failed(String(finalized.get("reason", "town_inputs_not_ready")))
	var towns = finalized.get("towns")
	if not towns is Dictionary:
		return _failed("finalized_towns_invalid")
	var policy = admission.source_policy_snapshot()
	if not policy is Dictionary:
		return _failed("ordinary_policy_missing")
	var expected_policy := {"regionCells": int(main.STRUCTURE_REGION_CELLS),
		"spawnChance": float(main.STRUCTURE_SPAWN_CHANCE)}
	if policy != expected_policy:
		return _failed("ordinary_policy_mismatch")
	var canonical: Dictionary = SITE_QUEUE._canonical_request(seed, Vector2i.ZERO, towns, policy)
	if canonical.is_empty() or canonical.towns != towns:
		return _failed("finalized_source_inputs_invalid")
	var rows: Array = []
	var regions: Array = towns.keys()
	regions.sort_custom(func(a: Vector2i, b: Vector2i): return a.x < b.x or a.x == b.x and a.y < b.y)
	for region: Vector2i in regions:
		var town: Dictionary = towns[region]
		var row := {"region": region, "hasTown": not town.is_empty()}
		if not town.is_empty():
			row["centerX"] = town.centerX
			row["centerZ"] = town.centerZ
			row["radiusCells"] = town.radius
			row["levelMeters"] = float(town.level)
		rows.append(row)
	var request := {"schema": "n3-native-world-backend-initialize/v1", "seedText": seed,
		"revisions": {"sourceSchema": 2, "terrainGenerator": 1, "biomeRegionField": 2,
			"latticeQuery": 1, "cellCenterQuery": 1, "surfaceColumnQuery": 1},
		"constants": {"cellSizeMeters": float(main.CELL), "cellCenterOffsetCells": 0.5,
			"worldBottomCellY": WORLD_GENERATION.WORLD_BOTTOM_CELL_Y,
			"waterLevelMeters": float(main.WATER_LEVEL),
			"minimumSurfaceMeters": float(main.MIN_HEIGHT),
			"maximumSurfaceMeters": float(main.MAX_HEIGHT)},
		"sitePolicy": {"sourcePolicyRevision": SITE_QUEUE.SOURCE_POLICY_REVISION,
			"surveyGenerationPolicyRevision": SITE_SURVEY.GENERATION_POLICY_VERSION,
			"ordinaryRegionCells": policy.regionCells,
			"ordinarySpawnChance": float(policy.spawnChance), "townOverrides": rows}}
	return {"status": "ready", "request": request}

static func _failed(reason: String) -> Dictionary:
	return {"status": "failed", "reason": reason}
