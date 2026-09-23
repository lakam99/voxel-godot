extends SceneTree

const SOURCE := preload("res://scripts/terrain/NativeTerrainNumericSource.gd")
const ORACLE := preload("res://scripts/testing/native_world/N3EffectiveTerrainOracle.gd")
const CELL := 1.35
var checks := {}

class UnresolvedBackend extends RefCounted:
	var page_status := "pending"
	func status() -> Dictionary:
		return {"status":"ready", "terrainDeltaRevision":0, "shapingRegistryRevision":0}
	func pin_effective_page(_page: Vector2i) -> Dictionary:
		return {"status":page_status, "reason":"shaping_dependency_unresolved" if page_status == "pending" else "shaping_dependency_failed"}

func _initialize() -> void:
	call_deferred("_run")

func _check(name: String, value: bool) -> void:
	checks[name] = value

func _run() -> void:
	var facade = SOURCE.new()
	_check("unbound_numeric_fails_closed", facade.read_world_numeric(Vector3.ZERO).get("status") == "failed")
	var unresolved = UnresolvedBackend.new()
	var unresolved_facade = SOURCE.new()
	unresolved_facade.bind(unresolved)
	_check("pending_page_propagated_without_sample", unresolved_facade.read_world_numeric(Vector3.ZERO).get("status") == "pending")
	unresolved.page_status = "failed"
	_check("failed_page_propagated_without_sample", unresolved_facade.read_surface_projection_numeric(Vector3i.ZERO).get("status") == "failed")
	var bundle: Dictionary = ORACLE.build_world("numeric-source-contract")
	_check("script_oracle_ready", bool(bundle.get("ok", false)))
	if not bool(bundle.get("ok", false)):
		_finish()
		return
	var edited_negative := Vector3i(-5601, -11, -5601)
	bundle.volume.set_cell_state(edited_negative, {"material":"air",
		"biome":"underground_air", "solid":false, "density":-0.77,
		"fluid":"", "light":{"sky":0,"block":0},
		"metadata":{"saveDelta":true,"source":"terrain_edit", "terrainMeshAffects":true}},
		"numeric_source_contract", false)
	var backend = ClassDB.instantiate("NativeWorldBackend")
	_check("native_registered", backend != null)
	if backend == null:
		_finish()
		return
	var request := {"schema":"n3-native-world-backend-initialize-from-save-v2/v1",
		"seedText":"numeric-source-contract", "saveSeedText":"numeric-source-contract",
		"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,
			"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
		"constants":{"cellSizeMeters":CELL,"cellCenterOffsetCells":0.5,
			"worldBottomCellY":-64,"waterLevelMeters":11.1,
			"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
		"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,
			"ordinaryRegionCells":140,"ordinarySpawnChance":0.0,"townOverrides":[]},
		"terrainVolume":bundle.volume.save_all_section_deltas()}
	_check("native_initialized", backend.initialize_from_save_v2(request).get("status") == "ready")
	_check("numeric_facade_bound", facade.bind(backend).get("status") == "ready")
	var cells: Array[Vector3i] = [Vector3i(5600, 10, 5600),
		Vector3i(-5601, -11, -5601), Vector3i(5601, 12, 5601)]
	var positions: Array[Vector3] = []
	for cell in cells:
		positions.append(Vector3((float(cell.x) + 0.5) * CELL,
			(float(cell.y) + 0.5) * CELL, (float(cell.z) + 0.5) * CELL))
	var result: Dictionary = facade.read_numeric_batch(positions, cells)
	_check("mixed_page_native_batch_ready", result.get("status") == "ready")
	if result.get("status") == "ready":
		_check("channel_order_preserved", result.worldNumeric.size() == cells.size()
			and result.surfaceProjectionNumeric.size() == cells.size())
		var world_match := true
		var projection_match := true
		for index in range(cells.size()):
			var expected_world: Vector3 = bundle.volume.numeric_sample_world(positions[index])
			var actual_world: Dictionary = result.worldNumeric[index]
			var world_numeric := Vector3(float(actual_world.density),
				0.0 if bool(actual_world.undergroundAirVoid) else INF,
				float(actual_world.surfaceY))
			world_match = world_match and world_numeric == expected_world
			var expected_projection: Vector3 = bundle.world.volume_surface_numeric_sample_at_grid_cell(cells[index])
			var actual_projection: Dictionary = result.surfaceProjectionNumeric[index]
			var projection_numeric := Vector3(float(actual_projection.density),
				0.0 if bool(actual_projection.undergroundAirVoid) else INF,
				float(actual_projection.surfaceY))
			projection_match = projection_match and projection_numeric == expected_projection
		_check("world_numeric_matches_script_vector", world_match)
		_check("projection_numeric_matches_script_vector", projection_match)
		_check("negative_durable_edit_in_both_channels",
			bool(result.worldNumeric[1].edited) and bool(result.surfaceProjectionNumeric[1].edited))
		_check("exact_channel_intents", result.worldNumeric[0].intent == "terrain_mesh"
			and result.surfaceProjectionNumeric[0].requested.intent == "terrain_collision"
			and result.surfaceProjectionNumeric[0].semanticRevision == 1)
	_check("empty_batch_rejected", facade.read_numeric_batch([], []).get("status") == "failed")
	_finish()

func _finish() -> void:
	var passed := not checks.values().has(false)
	var report := {"schema":"n3-native-terrain-numeric-source-contract/v1",
		"passed":passed, "evidenceLevel":"native-script-numeric-contract",
		"productionCutover":false, "checks":checks}
	var path := OS.get_environment("VWB_TERRAIN_NUMERIC_SOURCE_REPORT")
	if path != "":
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	print(JSON.stringify(report))
	quit(0 if passed else 1)
