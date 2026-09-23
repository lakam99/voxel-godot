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

# Continue must import exactly the durable v2 volume already restored by the
# game's save owner. Voxel Tools generated blocks are never a save source.
static func from_main_with_current_volume(main) -> Dictionary:
	if main == null:
		return _failed("main_missing")
	var world = main.get("world_generation_system")
	var service = world.get("terrain_volume_service") if world != null else null
	if service == null or not service.has_method("save_all_section_deltas"):
		return _failed("terrain_volume_owner_missing")
	var volume = service.save_all_section_deltas()
	return from_main_with_save_volume(main, volume)

## Continue may pass the already-loaded v2 envelope directly to the native
## owner. This adapter never regenerates or re-exports script volume state.
static func from_main_with_save_volume(main, volume) -> Dictionary:
	var built := from_main(main)
	if built.get("status") != "ready":
		return built
	if not volume is Dictionary or volume.get("schemaVersion") != 1 or volume.get("sectionSize") != 16:
		return _failed("terrain_volume_snapshot_invalid")
	var request: Dictionary = built.request.duplicate(true)
	request.schema = "n3-native-world-backend-initialize-from-save-v2/v1"
	request["saveSeedText"] = request.seedText
	request["terrainVolume"] = volume.duplicate(true)
	return {"status":"ready", "request":request}

## Resolve current save-v2 precedence before constructing one native volume.
## Historical v2 `terrain` columns only affect the final state when the full
## terrainVolume field is absent. Their native conversion is still pending;
## never silently load an empty volume over those edits.
static func from_main_with_v2_save(main, save) -> Dictionary:
	if not save is Dictionary or int(save.get("version", -1)) != 2:
		return _failed("save_v2_required")
	if main == null:
		return _failed("main_missing")
	if String(save.get("seed", main.get("seed_text"))) != String(main.get("seed_text")):
		return _failed("save_seed_mismatch")
	var terrain_value = save.get("terrain", [])
	if not terrain_value is Array:
		return _failed("save_terrain_entries_invalid")
	var volume_value = save.get("terrainVolume", {})
	if not volume_value is Dictionary:
		return _failed("save_terrain_volume_invalid")
	var volume: Dictionary = volume_value
	if volume.is_empty():
		if not terrain_value.is_empty():
			return {"status":"pending", "reason":"native_legacy_terrain_conversion_required"}
		volume = {"schemaVersion":1, "sectionSize":16, "revision":0, "sections":[]}
	return from_main_with_save_volume(main, volume)

static func _failed(reason: String) -> Dictionary:
	return {"status": "failed", "reason": reason}
