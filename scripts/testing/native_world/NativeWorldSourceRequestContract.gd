extends SceneTree

const REQUEST := preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const MAIN := preload("res://scripts/Main.gd")
const STRUCTURES := preload("res://scripts/StructureSystem.gd")
const WORLD := preload("res://scripts/WorldGenerationSystem.gd")
const VOLUME := preload("res://scripts/TerrainVolumeService.gd")
const LEGACY_CONVERTER := preload("res://scripts/terrain/NativeV2LegacyTerrainConverter.gd")

var failures: Array[String] = []

class PendingPages extends RefCounted:
	func request_page(_page: Vector2i) -> Dictionary:
		return {"status":"pending", "reason":"test_page_pending"}

func semantic_cells(volume: Dictionary) -> Dictionary:
	var indexed := {}
	for section in volume.get("sections", []):
		for record in section.get("cells", []):
			var state: Dictionary = record.get("state", {})
			indexed[JSON.stringify(record.get("cell", []))] = {"material":state.get("material"),
				"biome":state.get("biome"), "solid":state.get("solid"),
				"density":state.get("density"), "fluid":state.get("fluid"),
				"metadata":state.get("metadata"), "blockId":state.get("blockId"),
				"editReason":state.get("editReason")}
	return indexed

func check(value: bool, label: String) -> void:
	if not value:
		failures.append(label)

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var main = MAIN.new()
	main.seed_text = "source-request-contract"
	main.seed_hash = main.hash_string(main.seed_text)
	main.setup_noise()
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
	var absent_v2 := {"version":2, "seed":main.seed_text, "terrain":[]}
	var empty_v2 := {"version":2, "seed":main.seed_text, "terrain":[], "terrainVolume":{}}
	var expected_empty := {"schemaVersion":1, "sectionSize":16, "revision":0, "sections":[]}
	for save in [absent_v2, empty_v2]:
		var resolved: Dictionary = REQUEST.from_main_with_v2_save(main, save)
		check(resolved.get("status") == "ready"
			and resolved.get("request", {}).get("terrainVolume") == expected_empty,
			"absent or empty v2 volume resolves to canonical empty native snapshot")
		var empty_backend = ClassDB.instantiate("NativeWorldBackend")
		check(empty_backend != null and empty_backend.initialize_from_save_v2(
			resolved.get("request", {})).get("status") == "ready"
			and empty_backend.export_terrain_volume_v2().get("terrainVolume") == expected_empty,
			"canonical empty v2 Continue snapshot native round trip")
	var legacy_entry := {"x":-17, "z":-1, "surfaceY":-4.0}
	var legacy_only := {"version":2, "seed":main.seed_text, "terrain":[legacy_entry]}
	check(REQUEST.from_main_with_v2_save(main, legacy_only).get("reason")
		== "native_legacy_terrain_conversion_required",
		"nonempty historical v2 terrain list cannot silently become empty native volume")
	var both := {"version":2, "seed":main.seed_text, "terrain":[legacy_entry],
		"terrainVolume":current_volume}
	check(REQUEST.from_main_with_v2_save(main, both).get("request", {}).get("terrainVolume")
		== current_volume, "full v2 volume retains current restore precedence over terrain list")
	main.world_generation_system = WORLD.new()
	main.world_generation_system.setup(main)
	var column := Vector3i(-17, 0, -1)
	var old_surface := float(main.world_generation_system.surface_y_for_cell(column))
	var new_surface: float = old_surface - 2.0 * main.CELL
	var legacy_save := {"version":2, "seed":main.seed_text,
		"terrain":[{"x":column.x, "z":column.z, "surfaceY":new_surface}]}
	var converter = LEGACY_CONVERTER.new()
	check(converter.setup(main, legacy_save).get("status") == "ready",
		"native historical v2 conversion starts")
	var real_pages = converter._pages
	converter._pages = PendingPages.new()
	check(converter.advance().get("status") == "pending"
		and converter.export_volume().get("status") == "pending",
		"shaping page pending retains conversion and withholds snapshot")
	converter._pages = real_pages
	var converted: Dictionary = {}
	var max_conversion_step_usec := 0
	for frame in range(300):
		var step_started := Time.get_ticks_usec()
		converted = converter.advance()
		max_conversion_step_usec = maxi(max_conversion_step_usec,
			Time.get_ticks_usec() - step_started)
		if converted.get("status") != "pending": break
		await process_frame
	check(converted.get("status") == "ready"
		and not converted.get("terrainVolume", {}).get("sections", []).is_empty(),
		"native historical v2 excavation produces durable volume")
	var new_y := floori(new_surface / main.CELL)
	main.restore_volume_edits(legacy_save.terrain)
	var script_volume: Dictionary = main.world_generation_system.save_terrain_volume_deltas()
	var script_state := {}
	for section in script_volume.get("sections", []):
		for record in section.get("cells", []):
			if record.get("cell") == [column.x,new_y,column.z]:
				script_state = record.get("state", {})
	var converted_volume: Dictionary = converted.get("terrainVolume", {})
	var converted_record := {}
	for section in converted_volume.get("sections", []):
		for record in section.get("cells", []):
			if record.get("cell") == [column.x,new_y,column.z]:
				converted_record = record.get("state", {})
	var same_legacy_cell: bool = (converted_record.get("material") == script_state.get("material")
		and converted_record.get("biome") == script_state.get("biome")
		and converted_record.get("solid") == script_state.get("solid")
		and is_equal_approx(float(converted_record.get("density", 0)), float(script_state.get("density", 1)))
		and converted_record.get("metadata") == script_state.get("metadata"))
	check(same_legacy_cell, "native conversion preserves historical excavation cell semantics")
	check(semantic_cells(converted_volume) == semantic_cells(script_volume),
		"complete native excavation durable cells match MainSaveState restore")
	check(converted_volume == script_volume,
		"native v2 excavation matches exact saved volume revisions and records")
	var resolved_legacy: Dictionary = converter.resolved_save()
	var canonical_legacy_save: Dictionary = resolved_legacy.get("save", {})
	var converted_request: Dictionary = REQUEST.from_main_with_v2_save(main, canonical_legacy_save)
	var converted_backend = ClassDB.instantiate("NativeWorldBackend")
	check(resolved_legacy.get("status") == "ready"
		and canonical_legacy_save.get("terrain", []) == []
		and converted_request.get("status") == "ready"
		and converted_backend.initialize_from_save_v2(
			converted_request.get("request", {})).get("status") == "ready"
		and converted_backend.export_terrain_volume_v2().get("terrainVolume") == script_volume,
		"converted valid v2 save enters the ordinary native Continue owner exactly")
	var second_surface: float = old_surface - 4.0 * main.CELL
	var duplicate_save := {"version":2, "seed":main.seed_text,
		"terrain":[{"x":column.x, "z":column.z, "surfaceY":new_surface},
			{"x":column.x, "z":column.z, "surfaceY":second_surface}]}
	var duplicate_converter = LEGACY_CONVERTER.new()
	check(duplicate_converter.setup(main, duplicate_save).get("status") == "ready",
		"duplicate-column native conversion starts")
	var duplicate_result: Dictionary = {}
	for frame in range(300):
		duplicate_result = duplicate_converter.advance()
		if duplicate_result.get("status") != "pending": break
		await process_frame
	main.world_generation_system = WORLD.new()
	main.world_generation_system.setup(main)
	main.restore_volume_edits(duplicate_save.terrain)
	check(duplicate_result.get("status") == "ready"
		and duplicate_result.get("terrainVolume", {})
			== main.world_generation_system.save_terrain_volume_deltas(),
		"duplicate negative column follows ordered native surface and edit semantics")
	var deep_save := {"version":2, "seed":main.seed_text,
		"terrain":[{"x":column.x, "z":column.z, "surfaceY":old_surface - 65.0 * main.CELL}]}
	var deep_converter = LEGACY_CONVERTER.new()
	check(deep_converter.setup(main, deep_save).get("status") == "ready",
		"deep native excavation starts")
	var progress_count := 0
	var deep_result: Dictionary = {}
	var max_deep_step_usec := 0
	for frame in range(300):
		var step_started := Time.get_ticks_usec()
		deep_result = deep_converter.advance()
		max_deep_step_usec = maxi(max_deep_step_usec,
			Time.get_ticks_usec() - step_started)
		if deep_result.get("reason") in ["legacy_conversion_progress", "preparing_legacy_column"]:
			progress_count += 1
		if deep_result.get("status") != "pending": break
		await process_frame
	check(deep_result.get("status") == "ready" and progress_count >= 2,
		"deep column commits in bounded native batches")
	main.world_generation_system = WORLD.new()
	main.world_generation_system.setup(main)
	main.restore_volume_edits(deep_save.terrain)
	check(deep_result.get("terrainVolume", {})
			== main.world_generation_system.save_terrain_volume_deltas(),
		"deep column preserves one transaction and exact v2 section revisions")
	var oversized := {"version":2, "seed":main.seed_text,
		"terrain":[{"x":column.x, "z":column.z,
			"surfaceY":old_surface - 4097.0 * main.CELL}]}
	var oversized_converter = LEGACY_CONVERTER.new()
	check(oversized_converter.setup(main, oversized).get("status") == "ready",
		"oversized historical column enters bounded conversion")
	var oversized_result: Dictionary = {}
	var max_oversized_step_usec := 0
	var slowest_oversized_step := {}
	for frame in range(300):
		var step_started := Time.get_ticks_usec()
		oversized_result = oversized_converter.advance()
		var elapsed := Time.get_ticks_usec() - step_started
		if elapsed > max_oversized_step_usec:
			max_oversized_step_usec = elapsed
			slowest_oversized_step = {"reason":oversized_result.get("reason", ""),
				"status":oversized_result.get("status", ""),
				"preparedCells":oversized_result.get("preparedCells", 0)}
		if oversized_result.get("status") != "pending": break
		await process_frame
	main.world_generation_system = WORLD.new()
	main.world_generation_system.setup(main)
	main.restore_volume_edits(oversized.terrain)
	check(oversized_result.get("status") == "ready"
		and oversized_result.get("terrainVolume", {})
			== main.world_generation_system.save_terrain_volume_deltas(),
		"oversized historical column stages past 4096 with one exact native revision")
	var partial_converter = LEGACY_CONVERTER.new()
	check(partial_converter.setup(main, deep_save).get("status") == "ready",
		"partial conversion starts on private native backend")
	var partial_step: Dictionary = {}
	for frame in range(100):
		partial_step = partial_converter.advance()
		if partial_step.get("reason") == "preparing_legacy_column": break
		await process_frame
	var partial_backend = partial_converter._backend
	check(partial_step.get("reason") == "preparing_legacy_column"
		and int(partial_backend.status().get("terrainDeltaRevision", -1)) == 0
		and partial_backend.export_terrain_volume_v2().get("terrainVolume", {}).get("sections", []) == []
		and partial_converter.cancel().get("status") == "ready",
		"cancel after staged cells leaves durable native volume unpublished")
	var in_flight_converter = LEGACY_CONVERTER.new()
	check(in_flight_converter.setup(main, oversized).get("status") == "ready",
		"large conversion can start before asynchronous cancellation")
	var in_flight_step: Dictionary = {}
	for frame in range(300):
		in_flight_step = in_flight_converter.advance()
		if in_flight_step.get("reason") == "native_legacy_commit_in_flight": break
		await process_frame
	var cancellation: Dictionary = in_flight_converter.cancel()
	for frame in range(300):
		if cancellation.get("status") == "ready": break
		await process_frame
		cancellation = in_flight_converter.advance()
	check(in_flight_step.get("reason") == "native_legacy_commit_in_flight"
		and cancellation.get("cancelled") == true
		and in_flight_converter.export_volume().get("status") != "ready",
		"cancel while native commit runs drains worker without publishing owner")
	var cancelled = LEGACY_CONVERTER.new()
	check(cancelled.setup(main, legacy_save).get("status") == "ready"
		and cancelled.cancel().get("status") == "ready"
		and cancelled.advance().get("status") == "failed"
		and cancelled.export_volume().get("status") != "ready",
		"cancelled conversion cannot publish partial durable volume")
	var malformed := {"version":2, "seed":main.seed_text,
		"terrain":[{"x":"bad", "z":column.z, "surfaceY":new_surface}]}
	check(LEGACY_CONVERTER.new().setup(main, malformed).get("reason") == "legacy_terrain_entry_invalid",
		"malformed historical entry rejected before native initialization")
	main.structure_system.citadel_terrain_admission.configure("other-seed", {},
		{"regionCells": main.STRUCTURE_REGION_CELLS, "spawnChance": main.STRUCTURE_SPAWN_CHANCE})
	check(REQUEST.from_main(main).get("reason") == "site_admission_seed_mismatch", "seed mismatch fails")
	main.free()
	var report := {"schema": "native-world-source-request-contract/v1", "passed": failures.is_empty(),
		"evidenceLevel": "source-request-service-contract", "productionCutover": false,
		"failures": failures, "maxConversionStepUsec": max_conversion_step_usec,
		"maxDeepStepUsec": max_deep_step_usec,
		"maxOversizedStepUsec": max_oversized_step_usec,
		"slowestOversizedStep":slowest_oversized_step}
	var path := OS.get_environment("VWB_SOURCE_REQUEST_REPORT")
	if path != "":
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	quit(0 if failures.is_empty() else 1)
