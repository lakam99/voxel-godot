extends SceneTree

const SOURCE := preload("res://scripts/terrain/NativeTerrainCellSource.gd")
const SERVICE := preload("res://scripts/TerrainVolumeService.gd")
var checks := {}

func _initialize() -> void:
	call_deferred("_run")

func _check(name: String, value: bool) -> void:
	checks[name] = value

func _run() -> void:
	var facade = SOURCE.new()
	_check("unbound_reader_fails_closed", facade.read_cell(Vector3i.ZERO).get("status") == "failed")
	var service = SERVICE.new()
	service.setup(null, null)
	var left := Vector3i(3079, -1, 2801)
	var right := Vector3i(3080, -1, 2801)
	var first := {"material":"stone", "biome":"deep_underground", "solid":true,
		"density":1.25, "fluid":"", "light":{"sky":3,"block":11},
		"blockId":"cutover.stone", "metadata":{"saveDelta":true,"source":"terrain_edit"}}
	var second := {"material":"air", "biome":"underground_air", "solid":false,
		"density":-1.35, "fluid":"", "light":{"sky":2,"block":0},
		"blockId":"cutover.air", "metadata":{"saveDelta":true,"source":"terrain_edit"}}
	service.set_cell_state(left, first, "native_source_contract", false)
	service.set_cell_state(right, second, "native_source_contract", false)
	var backend = ClassDB.instantiate("NativeWorldBackend")
	_check("native_class_registered", backend != null)
	if backend == null:
		_finish()
		return
	var request := {"schema":"n3-native-world-backend-initialize-from-save-v2/v1",
		"seedText":"cell-source-contract", "saveSeedText":"cell-source-contract",
		"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,
			"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
		"constants":{"cellSizeMeters":1.35,"cellCenterOffsetCells":0.5,
			"worldBottomCellY":-64,"waterLevelMeters":11.1,
			"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
		"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,
			"ordinaryRegionCells":140,"ordinarySpawnChance":0.0,"townOverrides":[]},
		"terrainVolume":service.save_all_section_deltas()}
	_check("native_initialize_from_v2", backend.initialize_from_save_v2(request).get("status") == "ready")
	_check("facade_bound", facade.bind(backend).get("status") == "ready")
	var result: Dictionary = facade.read_cells([right, left, right])
	_check("cross_page_batch_ready", result.get("status") == "ready")
	if result.get("status") == "ready":
		var states: Array = result.states
		_check("order_and_duplicate_preserved", states.size() == 3 and states[0] == states[2])
		_check("durable_air_preserved", states[0].material == "air" and not states[0].solid
			and states[0].density == -1.35 and states[0].edited)
		_check("durable_stone_preserved", states[1].material == "stone" and states[1].solid
			and states[1].density == 1.25 and states[1].edited)
		_check("light_and_metadata_preserved", states[1].light == {"sky":3,"block":11}
			and states[1].metadata.get("source") == "terrain_edit")
		_check("pinned_revision_recorded", result.nativeRevision == backend.status().terrainDeltaRevision)
	_check("empty_batch_rejected", facade.read_cells([]).get("reason") == "cell_batch_limit")
	var revised := {"schema":"n3-native-durable-cell-transaction/v1",
		"transactionId":"cell-source-contract:replace",
		"expectedRevision":int(backend.status().terrainDeltaRevision),
		"operations":[{"kind":"set", "cell":left, "state":{
			"materialId":2, "biomeId":13, "fluidId":0, "solid":true,
			"density":2.25, "light":Vector2i(1,9),
			"metadata":{"saveDelta":true,"source":"terrain_edit"},
			"blockId":"cutover.revised", "editReason":"native_source_contract"}}]}
	var commit: Dictionary = backend.commit_durable_cells(revised)
	_check("native_revision_committed", commit.get("status") == "ready"
		and commit.get("commitStatus") == "committed")
	var current: Dictionary = facade.read_cell(left)
	_check("fresh_native_pin_after_commit", current.get("status") == "ready"
		and current.get("nativeRevision") == commit.get("revision")
		and current.get("state", {}).get("material") == "dirt"
		and current.get("state", {}).get("density") == 2.25)
	_finish()

func _finish() -> void:
	var passed := not checks.values().has(false)
	var report := {"schema":"n3-native-terrain-cell-source-contract/v1", "passed":passed,
		"evidenceLevel":"native-adapter-service-contract", "productionCutover":false,
		"checks":checks}
	var path := OS.get_environment("VWB_TERRAIN_CELL_SOURCE_REPORT")
	if path != "":
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	print(JSON.stringify(report))
	quit(0 if passed else 1)
