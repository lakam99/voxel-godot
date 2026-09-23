extends SceneTree

const SOURCE := preload("res://scripts/terrain/NativeTerrainCellSource.gd")
const SERVICE := preload("res://scripts/TerrainVolumeService.gd")
const ORACLE := preload("res://scripts/testing/native_world/N3EffectiveTerrainOracle.gd")
const CELL := 1.35
var checks := {}
var generated_rows: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(name: String, value: bool) -> void:
	checks[name] = value

func _typed_state(state: Dictionary) -> Dictionary:
	var light: Dictionary = state.get("light", {}) if state.get("light", {}) is Dictionary else {}
	return {"solid":bool(state.get("solid", false)),
		"density":float(state.get("density", 0.0)),
		"material":String(state.get("material", "")),
		"biome":String(state.get("biome", "")),
		"fluid":String(state.get("fluid", "")),
		"light":{"sky":int(light.get("sky", 0)), "block":int(light.get("block", 0))}}

func _typed_states_match(actual: Dictionary, expected: Dictionary) -> bool:
	return actual.get("solid") == expected.get("solid") \
		and is_equal_approx(float(actual.get("density", 0.0)), float(expected.get("density", 0.0))) \
		and actual.get("material") == expected.get("material") \
		and actual.get("biome") == expected.get("biome") \
		and actual.get("fluid") == expected.get("fluid") \
		and actual.get("light") == expected.get("light")

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
	_check_generated_state_parity()
	_finish()

func _check_generated_state_parity() -> void:
	var seed := "atlas-1492"
	var overrides := {
		Vector2i(-2, -2):{}, Vector2i(-2, -1):{}, Vector2i(-1, -2):{},
		Vector2i(-1, -1):{}, Vector2i(0, 0):{}}
	var bundle: Dictionary = ORACLE.build_world(seed, [], overrides)
	_check("generated_oracle_ready", bool(bundle.get("ok", false)))
	if not bool(bundle.get("ok", false)): return
	var cells: Array[Vector3i] = [
		Vector3i(-125, 3, -128), # fixed oracle: natural underground water
		Vector3i(-56, -56, -128), # fixed oracle: natural underground lava
		Vector3i(0, -64, 0), # fixed oracle: bedrock stratum
		Vector3i(-281, 8, -281), # immediately before negative page boundary
		Vector3i(-280, 8, -280)] # immediately after negative page boundary
	var expected: Array[Dictionary] = []
	for cell in cells:
		expected.append(_typed_state(bundle.world.get_cell_state(cell)))
	_check("oracle_water_is_underground_fluid",
		expected[0].material == "water" and expected[0].biome == "underground_air"
		and expected[0].fluid == "water" and not expected[0].solid)
	_check("oracle_lava_is_underground_fluid",
		expected[1].material == "lava" and expected[1].biome == "underground_air"
		and expected[1].fluid == "lava" and not expected[1].solid)
	_check("oracle_bedrock_is_solid_deep_stratum",
		expected[2].material == "bedrock" and expected[2].biome == "deep_underground"
		and expected[2].solid and expected[2].fluid.is_empty())
	var left_page := Vector2i(floori(float(cells[3].x) / SOURCE.PAGE_CELLS),
		floori(float(cells[3].z) / SOURCE.PAGE_CELLS))
	var right_page := Vector2i(floori(float(cells[4].x) / SOURCE.PAGE_CELLS),
		floori(float(cells[4].z) / SOURCE.PAGE_CELLS))
	_check("negative_page_boundary_is_crossed", left_page != right_page
		and cells[3].x < cells[4].x and cells[3].z < cells[4].z)
	for cell in cells:
		var state: Dictionary = bundle.world.get_cell_state(cell)
		_check("generated_state_%s" % str(cell), bool(state.get("generated", false))
			and not bool(state.get("edited", true)))
	var request := {"schema":"n3-native-world-backend-initialize-from-save-v2/v1",
		"seedText":seed, "saveSeedText":seed,
		"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,
			"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
		"constants":{"cellSizeMeters":CELL,"cellCenterOffsetCells":0.5,
			"worldBottomCellY":-64,"waterLevelMeters":11.1,
			"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
		"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,
			"ordinaryRegionCells":280,"ordinarySpawnChance":0.0,
			"townOverrides":[{"region":Vector2i(-2,-2),"hasTown":false},
				{"region":Vector2i(-2,-1),"hasTown":false},
				{"region":Vector2i(-1,-2),"hasTown":false},
				{"region":Vector2i(-1,-1),"hasTown":false},
				{"region":Vector2i(0,0),"hasTown":false}]},
		"terrainVolume":bundle.volume.save_all_section_deltas()}
	var backend = ClassDB.instantiate("NativeWorldBackend")
	_check("generated_native_class_registered", backend != null)
	if backend == null: return
	var initialized: Dictionary = backend.initialize_from_save_v2(request)
	_check("generated_native_initialized", initialized.get("status") == "ready")
	if initialized.get("status") != "ready":
		generated_rows.append({"initialization":initialized})
		return
	var generated_source = SOURCE.new()
	generated_source.bind(backend)
	var batch: Dictionary = generated_source.read_cells(cells)
	_check("generated_cross_page_batch_ready", batch.get("status") == "ready")
	if batch.get("status") != "ready":
		generated_rows.append({"batch":batch})
		return
	var rows: Array = batch.get("states", [])
	var parity := rows.size() == cells.size()
	for index in range(mini(rows.size(), cells.size())):
		var actual := _typed_state(rows[index])
		var matched := _typed_states_match(actual, expected[index])
		parity = parity and matched
		generated_rows.append({"cell":cells[index], "kind":["water","lava","bedrock","negative_page_left","negative_page_right"][index],
			"matched":matched, "actual":actual, "expected":expected[index],
			"generated":rows[index].get("generated", false),
			"edited":rows[index].get("edited", true)})
	_check("native_generated_typed_fields_match_script", parity)
	_check("native_rows_remain_generated_unedited", rows.size() == cells.size())
	for index in range(mini(rows.size(), cells.size())):
		_check("native_generated_provenance_%s" % str(cells[index]),
			bool(rows[index].get("generated", false))
			and not bool(rows[index].get("edited", true)))
	_check("native_water_fluid_semantics", rows.size() == cells.size()
		and rows[0].get("material") == "water" and rows[0].get("fluid") == "water"
		and rows[0].get("biome") == "underground_air")
	_check("native_lava_fluid_semantics", rows.size() == cells.size()
		and rows[1].get("material") == "lava" and rows[1].get("fluid") == "lava"
		and rows[1].get("biome") == "underground_air")
	_check("native_bedrock_semantics", rows.size() == cells.size()
		and rows[2].get("material") == "bedrock" and rows[2].get("biome") == "deep_underground"
		and rows[2].get("solid", false))
	var override_cell := cells[0]
	var override_state := {"material":"stone", "biome":"underground", "solid":true,
		"density":3.25, "fluid":"", "light":{"sky":1,"block":7},
		"blockId":"cell-source-generated-override",
		"metadata":{"saveDelta":true,"source":"terrain_edit"}}
	var script_override: Dictionary = bundle.volume.set_cell_state(override_cell,
		override_state, "generated_state_parity_override", false)
	var native_edit := {"schema":"n3-native-durable-cell-transaction/v1",
		"transactionId":"cell-source-generated-override", "expectedRevision":0,
		"operations":[{"kind":"set", "cell":override_cell, "state":{
			"materialId":3, "biomeId":11, "fluidId":0, "solid":true,
			"density":3.25, "light":Vector2i(1,7),
			"metadata":{"saveDelta":true,"source":"terrain_edit"},
			"blockId":"cell-source-generated-override",
			"editReason":"generated_state_parity_override"}}]}
	var committed: Dictionary = backend.commit_durable_cells(native_edit)
	_check("generated_override_committed", committed.get("commitStatus") == "committed")
	var native_override: Dictionary = generated_source.read_cell(override_cell)
	var native_override_state: Dictionary = _typed_state(native_override.get("state", {}))
	var script_override_state := _typed_state(script_override)
	var override_matches: bool = native_override.get("status") == "ready" \
		and _typed_states_match(native_override_state, script_override_state) \
		and bool(native_override.get("state", {}).get("edited", false))
	_check("durable_generated_override_matches_script", override_matches)
	generated_rows.append({"cell":override_cell, "kind":"durable_override",
		"matched":override_matches, "actual":native_override_state,
		"expected":script_override_state})

func _finish() -> void:
	var passed := not checks.values().has(false)
	var report := {"schema":"n3-native-terrain-cell-source-contract/v1", "passed":passed,
		"evidenceLevel":"native-adapter-service-contract", "productionCutover":false,
		"checks":checks, "fixedSeed":"atlas-1492",
		"generatedParityRows":generated_rows}
	var path := OS.get_environment("VWB_TERRAIN_CELL_SOURCE_REPORT")
	if path != "":
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	print(JSON.stringify(report))
	quit(0 if passed else 1)
