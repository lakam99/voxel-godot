extends SceneTree

const REQUEST := preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const MAIN := preload("res://scripts/MainCore.gd")
const STRUCTURES := preload("res://scripts/StructureSystem.gd")
const WORLD := preload("res://scripts/WorldGenerationSystem.gd")
const VOLUME := preload("res://scripts/TerrainVolumeService.gd")

var failures: Array[String] = []

func check(value: bool, label: String) -> void:
	if not value:
		failures.append(label)

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var main = MAIN.new()
	main.seed_text = "source-request-contract"
	main.structure_system = STRUCTURES.new()
	var admission = main.structure_system.citadel_terrain_admission
	admission.configure(main.seed_text, {}, {"regionCells": main.STRUCTURE_REGION_CELLS,
		"spawnChance": main.STRUCTURE_SPAWN_CHANCE})
	var town_region := Vector2i(2, -1)
	main.town_region_cache = {town_region: {"centerX": town_region.x * main.TOWN_REGION_CELLS,
		"centerZ": town_region.y * main.TOWN_REGION_CELLS, "radius": main.TOWN_RADIUS_CELLS,
		"level": main.WATER_LEVEL + 3.0}, Vector2i(-3, 4): {}}
	var built: Dictionary = REQUEST.from_main(main)
	check(built.get("status") == "ready", "finalized production source built")
	if built.get("status") == "ready":
		var request: Dictionary = built.request
		check(request.constants.cellSizeMeters == main.CELL and request.constants.worldBottomCellY == -64
			and request.constants.waterLevelMeters == main.WATER_LEVEL
			and request.constants.minimumSurfaceMeters == main.MIN_HEIGHT
			and request.constants.maximumSurfaceMeters == main.MAX_HEIGHT, "production constants")
		check(request.sitePolicy.ordinaryRegionCells == main.STRUCTURE_REGION_CELLS
			and request.sitePolicy.ordinarySpawnChance == main.STRUCTURE_SPAWN_CHANCE, "production policy")
		check(request.sitePolicy.townOverrides.size() == 2
			and request.sitePolicy.townOverrides[0].region == Vector2i(-3, 4)
			and not request.sitePolicy.townOverrides[0].hasTown
			and request.sitePolicy.townOverrides[1].region == town_region
			and request.sitePolicy.townOverrides[1].radiusCells == main.TOWN_RADIUS_CELLS,
			"finalized sorted town records")
		var backend = ClassDB.instantiate("NativeWorldBackend")
		check(backend != null, "native backend available")
		if backend != null:
			check(backend.initialize(request).get("status") == "ready", "native initialization accepts production request")
	main.world_generation_system = WORLD.new()
	main.world_generation_system.terrain_volume_service = VOLUME.new()
	var volume_service = main.world_generation_system.terrain_volume_service
	volume_service.setup(main, null)
	volume_service.set_cell_state(Vector3i(-17,-1,-1), {
		"material":"stone", "biome":"deep_underground", "solid":true,
		"density":1.25, "fluid":"", "blockId":"source-request-contract",
		"light":{"sky":3,"block":11},
		"metadata":{"saveDelta":true,"source":"terrain_edit"}}, "contract", false)
	var current_volume: Dictionary = volume_service.save_all_section_deltas()
	var restored_request: Dictionary = REQUEST.from_main_with_current_volume(main)
	check(restored_request.get("status") == "ready", "current durable volume request built")
	if restored_request.get("status") == "ready":
		check(restored_request.request.terrainVolume == current_volume
			and restored_request.request.saveSeedText == main.seed_text,
			"current durable volume and seed forwarded exactly")
		var restored_backend = ClassDB.instantiate("NativeWorldBackend")
		check(restored_backend != null and restored_backend.initialize_from_save_v2(
			restored_request.request).get("status") == "ready", "native save-v2 initialization accepts current volume")
		if restored_backend != null:
			var exported: Dictionary = restored_backend.export_terrain_volume_v2()
			check(exported.get("status") == "ready" and exported.get("terrainVolume") == current_volume,
				"native save-v2 export retains current durable volume")
	var explicit_request: Dictionary = REQUEST.from_main_with_save_volume(main, current_volume)
	check(explicit_request.get("status") == "ready"
		and explicit_request.get("request", {}) == restored_request.get("request", {}),
		"explicit v2 save envelope builds the same native initialization request")
	var explicit_backend = ClassDB.instantiate("NativeWorldBackend")
	check(explicit_backend != null and explicit_backend.initialize_from_save_v2(
		explicit_request.get("request", {})).get("status") == "ready",
		"native owner accepts explicit durable snapshot")
	main.world_generation_system = null
	check(REQUEST.from_main_with_current_volume(main).get("reason") == "terrain_volume_owner_missing"
		and REQUEST.from_main_with_save_volume(main, current_volume).get("status") == "ready",
		"explicit Continue path does not depend on script volume owner")
	check(REQUEST.from_main_with_save_volume(main, {}).get("reason") == "terrain_volume_snapshot_invalid",
		"invalid explicit volume rejected")
	check(REQUEST.from_main_with_current_volume(null).get("reason") == "main_missing",
		"missing main rejected before script volume lookup")
	main.structure_system.citadel_terrain_admission.configure("other-seed", {},
		{"regionCells": main.STRUCTURE_REGION_CELLS, "spawnChance": main.STRUCTURE_SPAWN_CHANCE})
	check(REQUEST.from_main(main).get("reason") == "site_admission_seed_mismatch", "seed mismatch fails")
	main.free()
	var report := {"schema": "native-world-source-request-contract/v1", "passed": failures.is_empty(),
		"evidenceLevel": "source-request-service-contract", "productionCutover": false,
		"failures": failures}
	var path := OS.get_environment("VWB_SOURCE_REQUEST_REPORT")
	if path != "":
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	quit(0 if failures.is_empty() else 1)
