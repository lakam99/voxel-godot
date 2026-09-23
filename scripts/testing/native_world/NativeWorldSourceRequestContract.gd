extends SceneTree

const REQUEST := preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const MAIN := preload("res://scripts/MainCore.gd")
const STRUCTURES := preload("res://scripts/StructureSystem.gd")

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
