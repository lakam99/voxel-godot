extends SceneTree

const SERVICE := preload("res://scripts/TerrainVolumeService.gd")
const MIRROR := preload("res://scripts/terrain/NativeDurableEditMirror.gd")
const EDIT_PLAN := preload("res://scripts/terrain/NativeTerrainEditRepublicationPlan.gd")

var failures: Array[String] = []

func _init() -> void:
	call_deferred("run")

func check(value: bool, label: String) -> void:
	if not value:
		failures.append(label)

func run() -> void:
	var service = SERVICE.new()
	service.setup(null, null)
	var backend = ClassDB.instantiate("NativeWorldBackend")
	check(backend != null, "native adapter registered")
	if backend == null:
		finish()
		return
	var request := {"schema": "n3-native-world-backend-initialize-from-save-v2/v1",
		"seedText": "shadow-durable-contract", "saveSeedText": "shadow-durable-contract",
		"revisions": {"sourceSchema": 2, "terrainGenerator": 1, "biomeRegionField": 2,
			"latticeQuery": 1, "cellCenterQuery": 1, "surfaceColumnQuery": 1},
		"constants": {"cellSizeMeters": 1.35, "cellCenterOffsetCells": 0.5,
			"worldBottomCellY": -64, "waterLevelMeters": 11.1,
			"minimumSurfaceMeters": 4.0, "maximumSurfaceMeters": 120.0},
		"sitePolicy": {"sourcePolicyRevision": 1, "surveyGenerationPolicyRevision": 1,
			"ordinaryRegionCells": 140, "ordinarySpawnChance": 0.08, "townOverrides": []},
		"terrainVolume": service.save_all_section_deltas()}
	check(backend.initialize_from_save_v2(request).get("status") == "ready", "native initialized from production volume")
	var mirror = MIRROR.new()
	check(mirror.bind(service, backend).get("status") == "ready", "matching initial owners bind")
	var cell := Vector3i(-17, -1, 18)
	var state := {"material": "stone", "biome": "deep_underground", "solid": true,
		"density": 1.25, "fluid": "", "blockId": "shadow.edit", "light": {"sky": 3, "block": 11},
		"metadata": {"saveDelta": true, "source": "terrain_edit"}}
	service.set_cell_state(cell, state, "shadow_test", false)
	var first: Dictionary = mirror.synchronize()
	check(first.get("status") == "ready" and first.get("commitStatus") == "committed"
		and first.get("operationCount") == 1, "negative-cell durable set mirrored")
	var changed: Array[Vector3i] = []
	changed.assign(first.get("changedCells", []))
	var edit_plan: Dictionary = EDIT_PLAN.for_committed_cells(changed, first.get("affectedSections", []))
	check(edit_plan.get("status") == "ready"
		and (edit_plan.get("replacementDataBlocks", []) as Array).has(Vector3i(-2, -1, 1)),
		"committed native receipt plans exact replacement block")
	check(mirror.synchronize().get("commitStatus") == "no_change", "unchanged source does not commit")
	state.density = 2.25
	service.set_cell_state(cell, state, "shadow_replace", false)
	check(mirror.synchronize().get("commitStatus") == "committed", "durable replacement mirrored")
	service.clear_cell_state(cell, "shadow_clear")
	var cleared: Dictionary = mirror.synchronize()
	check(cleared.get("commitStatus") == "committed" and cleared.get("operationCount") == 1,
		"durable clear mirrored")
	check(backend.export_terrain_volume_v2().get("terrainVolume", {}).get("sections", []).is_empty(),
		"native durable export empty after clear")
	state.metadata.saveDelta = false
	service.set_cell_state(cell, state, "transient_not_saved", false)
	check(mirror.synchronize().get("commitStatus") == "no_change", "non-durable service edit excluded")
	var rogue := {"schema": "n3-native-durable-cell-transaction/v1", "transactionId": "rogue",
		"expectedRevision": cleared.nativeRevision, "operations": [{"kind": "set",
			"cell": cell + Vector3i.ONE, "state": {"materialId": 3, "biomeId": 12,
				"fluidId": 0, "solid": true, "density": 1.25, "light": Vector2i(3, 11),
				"metadata": {"saveDelta": true}, "blockId": "rogue", "editReason": "external"}}]}
	check(backend.commit_durable_cells(rogue).get("status") == "ready", "external native revision changes")
	check(mirror.synchronize().get("reason") == "native_revision_drift", "external native mutation fails closed")
	check(MIRROR.new().bind(service, backend).get("reason") == "initial_volume_mismatch",
		"mismatched owners cannot rebind")
	finish()

func finish() -> void:
	var report := {"schema": "native-durable-edit-mirror-contract/v1", "passed": failures.is_empty(),
		"evidenceLevel": "shadow-service-contract", "productionCutover": false, "failures": failures}
	var path := OS.get_environment("VWB_DURABLE_MIRROR_REPORT")
	if path != "":
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	quit(0 if failures.is_empty() else 1)
