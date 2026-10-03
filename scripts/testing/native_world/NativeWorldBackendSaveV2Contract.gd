extends SceneTree

const TerrainVolumeServiceScript := preload("res://scripts/TerrainVolumeService.gd")
const SaveSystemScript := preload("res://scripts/SaveSystem.gd")

const CELL := 1.35
const SEED := "atlas-1492"
const INITIALIZE_FROM_SAVE_SCHEMA := "n3-native-world-backend-initialize-from-save-v2/v1"
const DURABLE_TRANSACTION_SCHEMA := "n3-native-durable-cell-transaction/v1"
const TYPED_TRANSACTION_SCHEMA := "n3-native-typed-cell-transaction/v1"
const EMPTY_BATCH_SCHEMA := "n3-effective-terrain-batch-request/v1"
const SECTION_SIZE := 16
const SECTION_CELL_COUNT := SECTION_SIZE * SECTION_SIZE * SECTION_SIZE
const MAX_RECORDS := 65536

var failures: Array[String] = []
var checks := 0


func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures.append(label)


func failed(value: Dictionary, needle: String, label: String) -> void:
	check(value.get("status") == "failed", label + " status")
	check(needle.is_empty() or String(value.get("reason", "")).contains(needle),
		label + " reason: " + String(value.get("reason", "")))


func initialization(schema := "n3-native-world-backend-initialize/v1") -> Dictionary:
	return {
		"schema": schema,
		"seedText": SEED,
		"revisions": {
			"sourceSchema": 2,
			"terrainGenerator": 1,
			"biomeRegionField": 2,
			"latticeQuery": 1,
			"cellCenterQuery": 1,
			"surfaceColumnQuery": 1,
		},
		"constants": {
			"cellSizeMeters": CELL,
			"cellCenterOffsetCells": 0.5,
			"worldBottomCellY": -64,
			"waterLevelMeters": 11.1,
			"minimumSurfaceMeters": 4.0,
			"maximumSurfaceMeters": 120.0,
		},
		"sitePolicy": {
			"sourcePolicyRevision": 1,
			"surveyGenerationPolicyRevision": 1,
			"ordinaryRegionCells": 140,
			"ordinarySpawnChance": 0.08,
			"townOverrides": [],
		},
	}


func empty_volume(revision := 0) -> Dictionary:
	return {"schemaVersion": 1, "sectionSize": SECTION_SIZE, "revision": revision, "sections": []}


func instantiate_backend():
	var backend = ClassDB.instantiate("NativeWorldBackend")
	check(backend != null, "adapter registration")
	return backend


func initialized_owner():
	var backend = instantiate_backend()
	if backend == null:
		return null
	check(backend.has_method("initialize_from_save_v2"), "initialize_from_save_v2 binding")
	check(backend.has_method("export_terrain_volume_v2"), "export_terrain_volume_v2 binding")
	var receipt: Dictionary = backend.call("initialize", initialization())
	check(receipt.get("status") == "ready", "ordinary initialization")
	return backend


func restore_owner(terrain_volume: Dictionary, save_seed := SEED) -> Dictionary:
	var backend = instantiate_backend()
	if backend == null:
		return {"owner": null, "receipt": {}}
	check(backend.has_method("initialize_from_save_v2"), "restore binding")
	check(backend.has_method("export_terrain_volume_v2"), "export binding")
	if not backend.has_method("initialize_from_save_v2"):
		return {"owner": backend, "receipt": {}}
	var request := initialization(INITIALIZE_FROM_SAVE_SCHEMA)
	request["saveSeedText"] = save_seed
	request["terrainVolume"] = terrain_volume
	var receipt: Dictionary = backend.call("initialize_from_save_v2", request)
	return {"owner": backend, "receipt": receipt}


func export_volume(backend) -> Dictionary:
	if backend == null or not backend.has_method("export_terrain_volume_v2"):
		return {}
	var result: Variant = backend.call("export_terrain_volume_v2")
	return result if result is Dictionary else {}


func volume_from_export(result: Dictionary) -> Dictionary:
	var value: Variant = result.get("terrainVolume", {})
	return value if value is Dictionary else {}


func volume_state(material: String, biome: String, solid: bool, density: float,
		fluid: String, block_id: String, metadata: Dictionary) -> Dictionary:
	return {
		"material": material,
		"biome": biome,
		"solid": solid,
		"density": density,
		"fluid": fluid,
		"blockId": block_id,
		"light": {"sky": 3, "block": 11},
		"metadata": metadata,
	}


func native_state(material_id: int, biome_id: int, solid: bool, density: float,
		fluid_id: int, block_id: String, edit_reason: String, metadata: Dictionary) -> Dictionary:
	return {
		"materialId": material_id,
		"biomeId": biome_id,
		"solid": solid,
		"density": density,
		"fluidId": fluid_id,
		"light": Vector2i(3, 11),
		"metadata": metadata,
		"blockId": block_id,
		"editReason": edit_reason,
	}


func build_service_snapshot() -> Dictionary:
	var service = TerrainVolumeServiceScript.new()
	service.setup(null, null)
	service.set_cell_state(Vector3i(-17, -1, -1),
		volume_state("stone", "deep_underground", true, 1.25, "", "contract.negative",
			{"saveDelta": true, "source": "terrain_edit", "nested": {"name": "negative", "values": [1, true, "kept"]}}),
		"negative_contract", false)
	service.set_cell_state(Vector3i(0, 0, 0),
		volume_state("water", "ocean", false, 0.0, "water", "contract.water",
			{"saveDelta": true, "source": "terrain_edit", "fluidMarker": "water"}),
		"water_contract", false)
	service.set_cell_state(Vector3i(16, 17, -16),
		volume_state("lava", "underground", false, 0.0, "lava", "contract.lava",
			{"saveDelta": true, "source": "terrain_edit", "fluidMarker": "lava"}),
		"lava_contract", false)
	return service.save_all_section_deltas()


func find_saved_record(volume: Dictionary, cell: Array) -> Dictionary:
	var sections: Variant = volume.get("sections", [])
	if not sections is Array:
		return {}
	for section_value in sections:
		if not section_value is Dictionary:
			continue
		var cells: Variant = section_value.get("cells", [])
		if not cells is Array:
			continue
		for record_value in cells:
			if record_value is Dictionary and record_value.get("cell", []) == cell:
				return record_value
	return {}


func has_saved_cell(volume: Dictionary, cell: Array) -> bool:
	return not find_saved_record(volume, cell).is_empty()


func json_semantic_value(value: Variant) -> Variant:
	if value is Dictionary:
		var keys: Array = value.keys()
		keys.sort_custom(func(left: Variant, right: Variant) -> bool: return String(left) < String(right))
		var normalized := {}
		for key in keys:
			normalized[String(key)] = json_semantic_value(value[key])
		return normalized
	if value is Array:
		var normalized: Array = []
		for item in value:
			normalized.append(json_semantic_value(item))
		return normalized
	if value is int or value is float:
		return float(value)
	return value


func assert_export_envelope(result: Dictionary, expected_seed: String, label: String) -> void:
	check(result.get("schema") == "n3-native-world-backend-adapter/v1", label + " envelope schema")
	check(result.get("operation") == "export_terrain_volume_v2", label + " operation")
	check(result.get("status") == "ready", label + " ready")
	check(result.get("saveSeedText") == expected_seed, label + " save seed")
	check(result.get("sourceIdentity", {}) is Dictionary, label + " source identity")
	check(result.has("terrainDeltaRevision") and result.has("persistedRevision"), label + " revisions")


func test_empty_export() -> Dictionary:
	var backend = initialized_owner()
	if backend == null:
		return {}
	var status: Dictionary = backend.call("status")
	check(status.get("saveV2InitializationSupported") == true, "save-v2 initialization capability")
	check(status.get("terrainVolumeV2ExportSupported") == true, "terrainVolume export capability")
	var result := export_volume(backend)
	assert_export_envelope(result, SEED, "empty export")
	check(volume_from_export(result) == empty_volume(), "empty export exact terrainVolume")
	check(int(result.get("terrainDeltaRevision", -1)) == 0, "empty native revision zero")
	check(int(result.get("persistedRevision", -1)) == 0, "empty persisted revision zero")
	return {"terrainDeltaRevision": result.get("terrainDeltaRevision", -1),
		"persistedRevision": result.get("persistedRevision", -1)}


func save_system_round_trip(terrain_volume: Dictionary, report_path: String) -> Dictionary:
	var save_path := "user://n3_native_world_backend_save_v2_contract.bin"
	if report_path != "":
		save_path = report_path.get_base_dir().path_join("n3-save-v2-actual-save-system.bin")
	var save_system = SaveSystemScript.new(save_path)
	save_system.delete(SEED)
	var wrote: bool = save_system.save(SEED, {
		"terrainVolume": terrain_volume,
		"contractMarker": {"negative": [-17, -1, -1], "kind": "actual_binary_round_trip"},
	})
	var loaded: Dictionary = save_system.load(SEED)
	check(wrote, "SaveSystem actual binary write")
	check(int(loaded.get("version", 0)) == SaveSystemScript.SAVE_VERSION, "SaveSystem v2 envelope")
	check(loaded.get("seed") == SEED, "SaveSystem seed")
	var loaded_volume: Dictionary = loaded.get("terrainVolume", {}) if loaded.get("terrainVolume", {}) is Dictionary else {}
	check(json_semantic_value(loaded_volume) == json_semantic_value(terrain_volume),
		"SaveSystem terrainVolume binary roundtrip")
	var marker: Dictionary = loaded.get("contractMarker", {}) if loaded.get("contractMarker", {}) is Dictionary else {}
	var marker_negative: Array = marker.get("negative", []) if marker.get("negative", []) is Array else []
	check(marker.get("kind") == "actual_binary_round_trip" and marker_negative.size() == 3
		and int(marker_negative[0]) == -17 and int(marker_negative[1]) == -1 and int(marker_negative[2]) == -1,
		"SaveSystem adjacent domain preserved")
	var cleaned: bool = save_system.delete(SEED)
	check(cleaned, "SaveSystem contract cleanup")
	return {"wrote": wrote, "loadedVersion": loaded.get("version", 0), "cleaned": cleaned,
		"loadedTerrainVolume": loaded_volume}


func test_service_and_save_round_trip(report_path: String) -> Dictionary:
	var snapshot := build_service_snapshot()
	check(snapshot.get("schemaVersion") == 1 and snapshot.get("sectionSize") == SECTION_SIZE,
		"TerrainVolumeService current schema")
	check((snapshot.get("sections", []) as Array).size() == 3, "negative multi-section snapshot")
	var negative := find_saved_record(snapshot, [-17, -1, -1])
	var water := find_saved_record(snapshot, [0, 0, 0])
	var lava := find_saved_record(snapshot, [16, 17, -16])
	check(negative.get("local", []) == [15, 15, 15], "negative floor section/local decomposition")
	check((negative.get("state", {}) as Dictionary).get("metadata", {}).get("nested", {}).get("values", []) == [1, true, "kept"],
		"recursive metadata retained by service")
	check((water.get("state", {}) as Dictionary).get("material") == "water"
		and (water.get("state", {}) as Dictionary).get("fluid") == "water", "water identity in service save")
	check((lava.get("state", {}) as Dictionary).get("material") == "lava"
		and (lava.get("state", {}) as Dictionary).get("fluid") == "lava", "lava identity in service save")

	var save_result := save_system_round_trip(snapshot, report_path)
	var loaded_volume: Dictionary = save_result.get("loadedTerrainVolume", {})
	var save_evidence := save_result.duplicate(true)
	save_evidence.erase("loadedTerrainVolume")
	check(not loaded_volume.is_empty(), "SaveSystem loaded terrainVolume is present")
	var json_restored := restore_owner(loaded_volume)
	check(json_restored.receipt.get("status") == "ready",
		"JSON whole-number floats accepted by native restore")
	var restored := json_restored
	var receipt: Dictionary = restored.receipt
	check(receipt.get("status") == "ready", "service snapshot native restore")
	check(int(receipt.get("terrainDeltaRevision", -1)) == 0, "restore begins native revision zero")
	var exported := export_volume(restored.owner)
	assert_export_envelope(exported, SEED, "service roundtrip export")
	check(json_semantic_value(volume_from_export(exported)) == json_semantic_value(loaded_volume),
		"TerrainVolumeService native exact semantic roundtrip")
	check(int(exported.get("terrainDeltaRevision", -1)) == 0, "roundtrip native revision zero")
	check(int(exported.get("persistedRevision", -1)) == int(snapshot.get("revision", -2)),
		"roundtrip persisted revision")
	return {"sectionCount": (snapshot.get("sections", []) as Array).size(),
		"recordCount": 3, "rootRevision": snapshot.get("revision", -1), "saveSystem": save_evidence,
		"restoreReceipt": receipt}


func test_overlay_is_not_persisted() -> Dictionary:
	var snapshot := build_service_snapshot()
	var restored := restore_owner(snapshot)
	var backend = restored.owner
	if backend == null or restored.receipt.get("status") != "ready":
		return {}
	var before := export_volume(backend)
	var overlay_cell := Vector3i(7, 8, 9)
	var overlay_state := native_state(0, 0, false, -0.75, 0, "contract.overlay", "overlay_contract",
		{"source": "scene_block", "saveDelta": false, "terrainMeshAffects": false})
	var request := {
		"schema": TYPED_TRANSACTION_SCHEMA,
		"transactionId": "save-v2:overlay-only",
		"expectedRevision": 0,
		"operations": [{"namespace": "scene_overlay", "kind": "set", "cell": overlay_cell, "state": overlay_state}],
	}
	var commit: Dictionary = backend.call("commit_typed_cells", request)
	check(commit.get("status") == "ready" and commit.get("commitStatus") == "committed"
		and int(commit.get("revision", -1)) == 1, "overlay-only commit")
	var after := export_volume(backend)
	assert_export_envelope(after, SEED, "overlay export")
	check(volume_from_export(after) == volume_from_export(before), "overlay leaves terrainVolume exact")
	check(int(after.get("terrainDeltaRevision", -1)) == 1, "overlay advances native revision")
	check(int(after.get("persistedRevision", -1)) == int(before.get("persistedRevision", -2)),
		"overlay does not advance persisted revision")
	check(not has_saved_cell(volume_from_export(after), [overlay_cell.x, overlay_cell.y, overlay_cell.z]),
		"overlay cell absent from export")

	var service = TerrainVolumeServiceScript.new()
	service.setup(null, null)
	var durable_cell := Vector3i(1, 2, 3)
	service.set_cell_state(durable_cell,
		volume_state("stone", "plains", true, 1.0, "", "contract.service.durable", {"saveDelta": true}),
		"service_durable", false)
	var service_before: Dictionary = service.save_all_section_deltas()
	service.set_scene_block_overlay(overlay_cell,
		volume_state("air", "plains", false, -1.0, "", "contract.service.overlay", {"saveDelta": false}),
		"service_overlay")
	var service_after: Dictionary = service.save_all_section_deltas()
	check(service_after.get("sections", []) == service_before.get("sections", []),
		"TerrainVolumeService overlay leaves durable sections exact")
	check(not has_saved_cell(service_after, [overlay_cell.x, overlay_cell.y, overlay_cell.z]),
		"TerrainVolumeService overlay is not a saved record")
	return {"nativeRevisionBefore": before.get("terrainDeltaRevision", -1),
		"nativeRevisionAfter": after.get("terrainDeltaRevision", -1),
		"persistedRevision": after.get("persistedRevision", -1)}


func empty_batch() -> Dictionary:
	return {"schema": EMPTY_BATCH_SCHEMA, "surfaceColumns": [], "cellCenters": [],
		"latticeNumeric": [], "worldNumeric": [], "surfaceProjectionNumeric": []}


func find_ready_page(backend) -> Vector2i:
	for z in range(-12, 13):
		for x in range(-12, 13):
			var page := Vector2i(x, z)
			if backend.call("shaping_requests", page).get("status") == "ready":
				return page
	return Vector2i(2147483647, 2147483647)


func sample_cell(page, cell: Vector3i) -> Dictionary:
	if page == null:
		return {}
	var request := empty_batch()
	request.cellCenters = [{"coordinate": cell, "intent": "gameplay"}]
	var result: Dictionary = page.sample_batch(request)
	if result.get("status") != "ready" or (result.get("cellCenters", []) as Array).size() != 1:
		return {}
	return result.cellCenters[0]


func test_commit_replay_stale_and_pin() -> Dictionary:
	var snapshot := build_service_snapshot()
	var restored := restore_owner(snapshot)
	var backend = restored.owner
	if backend == null or restored.receipt.get("status") != "ready":
		return {}
	var page_key := find_ready_page(backend)
	check(page_key != Vector2i(2147483647, 2147483647), "ready page for pin immutability")
	if page_key == Vector2i(2147483647, 2147483647):
		return {}
	var cell := Vector3i(page_key.x * 280 + 5, 6, page_key.y * 280 + 7)
	var old_pin: Dictionary = backend.call("pin_effective_page", page_key)
	var old_page = old_pin.get("page")
	check(old_pin.get("status") == "ready" and old_page != null, "pre-commit pin")
	var before_export := export_volume(backend)
	var state := native_state(3, 0, true, 1.75, 0, "contract.first.durable", "first_durable_contract",
		{"saveDelta": true, "source": "terrain_edit", "nested": {"order": [3, 2, 1]}})
	var request := {
		"schema": DURABLE_TRANSACTION_SCHEMA,
		"transactionId": "save-v2:first-durable",
		"expectedRevision": 0,
		"operations": [{"kind": "set", "cell": cell, "state": state}],
	}
	var committed: Dictionary = backend.call("commit_durable_cells", request)
	check(committed.get("status") == "ready" and committed.get("commitStatus") == "committed"
		and int(committed.get("revision", -1)) == 1, "first durable commit after restore")
	var replay: Dictionary = backend.call("commit_durable_cells", request)
	check(replay.get("status") == "ready" and replay.get("commitStatus") == "idempotent_replay"
		and int(replay.get("revision", -1)) == 1, "durable idempotent replay")
	var changed := request.duplicate(true)
	changed.operations[0].state.density = 1.5
	failed(backend.call("commit_durable_cells", changed), "transaction", "changed durable replay")
	var stale := request.duplicate(true)
	stale.transactionId = "save-v2:stale"
	stale.expectedRevision = 0
	stale.operations[0].cell = cell + Vector3i.ONE
	failed(backend.call("commit_durable_cells", stale), "revision", "stale durable commit")

	var after_export := export_volume(backend)
	var exported_volume := volume_from_export(after_export)
	check(int(after_export.get("terrainDeltaRevision", -1)) == 1, "durable export native revision")
	check(int(after_export.get("persistedRevision", -1)) == int(before_export.get("persistedRevision", -2)) + 1,
		"durable export advances persisted revision once")
	var record := find_saved_record(exported_volume, [cell.x, cell.y, cell.z])
	check(not record.is_empty(), "first durable cell exported")
	check(json_semantic_value((record.get("state", {}) as Dictionary).get("metadata", {}).get("nested", {}).get("order", []))
		== json_semantic_value([3, 2, 1]),
		"first durable metadata exported")
	check(int(exported_volume.get("revision", -1)) == int(after_export.get("persistedRevision", -2)),
		"export root and persisted revision agree")

	var new_pin: Dictionary = backend.call("pin_effective_page", page_key)
	var new_page = new_pin.get("page")
	check(new_pin.get("status") == "ready" and new_page != null, "post-commit pin")
	var old_sample := sample_cell(old_page, cell)
	var new_sample := sample_cell(new_page, cell)
	check(not old_sample.is_empty() and old_sample.get("edited") == false, "old pin excludes later durable commit")
	var new_sparse: Variant = new_sample.get("editedSparseState")
	check(new_sample.get("edited") == true and new_sparse is Dictionary
		and new_sparse.get("blockId") == "contract.first.durable",
		"new pin observes durable commit")
	var old_page_status: Dictionary = old_pin.get("pageStatus", {})
	var new_page_status: Dictionary = new_pin.get("pageStatus", {})
	check(int(old_page_status.get("terrainDeltaRevision", -1)) == 0
		and int(new_page_status.get("terrainDeltaRevision", -1)) == 1,
		"pin revisions immutable")
	return {"importedPersistedRevision": before_export.get("persistedRevision", -1),
		"committedNativeRevision": committed.get("revision", -1),
		"exportedPersistedRevision": after_export.get("persistedRevision", -1),
		"oldPinEdited": old_sample.get("edited", null), "newPinEdited": new_sample.get("edited", null)}


func test_seed_and_one_shot_failures() -> Dictionary:
	var snapshot := build_service_snapshot()
	var mismatched := restore_owner(snapshot, SEED + "-wrong")
	failed(mismatched.receipt, "seed", "save seed mismatch")
	var backend = mismatched.owner
	if backend != null:
		var retry := initialization(INITIALIZE_FROM_SAVE_SCHEMA)
		retry.saveSeedText = SEED
		retry.terrainVolume = snapshot
		failed(backend.call("initialize_from_save_v2", retry), "one_shot", "failed restore consumes owner")
		failed(backend.call("initialize", initialization()), "one_shot", "failed restore blocks ordinary initialize")

	var ordinary = initialized_owner()
	if ordinary != null:
		var late := initialization(INITIALIZE_FROM_SAVE_SCHEMA)
		late.saveSeedText = SEED
		late.terrainVolume = snapshot
		failed(ordinary.call("initialize_from_save_v2", late), "one_shot", "restore cannot replace live owner")
	return {"seedMismatchFailed": mismatched.receipt.get("status") == "failed", "oneShot": true}


func capacity_state(cell: Array, section: Array, local: Array) -> Dictionary:
	return {
		"cell": cell,
		"sectionKey": section,
		"localCell": local,
		"blockId": "contract.capacity",
		"material": "stone",
		"biome": "plains",
		"solid": true,
		"density": 1.0,
		"fluid": "",
		"light": {"sky": 0, "block": 0},
		"metadata": {},
		"generated": false,
		"edited": true,
		"editReason": "capacity_contract",
	}


func capacity_snapshot(record_count: int) -> Dictionary:
	var sections: Array = []
	var remaining := record_count
	var section_z := 0
	while remaining > 0:
		var section_count := mini(remaining, SECTION_CELL_COUNT)
		var section := [0, 0, section_z]
		var origin := [0, 0, section_z * SECTION_SIZE]
		var cells: Array = []
		cells.resize(section_count)
		for ordinal in range(section_count):
			var local_x := ordinal % SECTION_SIZE
			var local_y := int(ordinal / SECTION_SIZE) % SECTION_SIZE
			var local_z := int(ordinal / (SECTION_SIZE * SECTION_SIZE))
			var local := [local_x, local_y, local_z]
			var cell := [local_x, local_y, origin[2] + local_z]
			cells[ordinal] = {"local": local, "cell": cell, "state": capacity_state(cell, section, local)}
		sections.append({"schemaVersion": 1, "sectionKey": section, "originCell": origin,
			"revision": 23, "cells": cells})
		remaining -= section_count
		section_z += 1
	return {"schemaVersion": 1, "sectionSize": SECTION_SIZE, "revision": 23, "sections": sections}


func over_capacity_shape_only_snapshot() -> Dictionary:
	# Deliberately leave the cell entries null. The adapter must sum and reject
	# 65,537 records before it parses or copies a single save-owned cell.
	var sections: Array = []
	for section_z in range(17):
		var count := SECTION_CELL_COUNT if section_z < 16 else 1
		var cells: Array = []
		cells.resize(count)
		sections.append({"schemaVersion": 1, "sectionKey": [0, 0, section_z],
			"originCell": [0, 0, section_z * SECTION_SIZE], "revision": 23, "cells": cells})
	return {"schemaVersion": 1, "sectionSize": SECTION_SIZE, "revision": 23, "sections": sections}


func over_section_capacity_shape_only_snapshot() -> Dictionary:
	# As above, null cells prove the 4,097 count is rejected before descent.
	var cells: Array = []
	cells.resize(SECTION_CELL_COUNT + 1)
	return {"schemaVersion": 1, "sectionSize": SECTION_SIZE, "revision": 23, "sections": [
		{"schemaVersion": 1, "sectionKey": [0, 0, 0], "originCell": [0, 0, 0],
			"revision": 23, "cells": cells},
	]}


func test_json_integer_and_metadata_semantics() -> Dictionary:
	var snapshot := build_service_snapshot()

	var bool_false := snapshot.duplicate(true)
	bool_false.sections[0].cells[0].state.metadata.saveDelta = false
	var bool_false_restore := restore_owner(bool_false)
	failed(bool_false_restore.receipt, "saveDelta", "bool false saveDelta rejection")

	# Match TerrainVolumeService.cell_state_saved_in_delta's Godot 4.6.1
	# bool(Variant) boundary: nonzero numeric values are truthy and preserved;
	# zero and non-convertible Variant kinds cannot be canonical durable output.
	var numeric_truthy := snapshot.duplicate(true)
	var numeric_truthy_cell: Array = numeric_truthy.sections[0].cells[0].cell
	numeric_truthy.sections[0].cells[0].state.metadata.saveDelta = 2.0
	var numeric_truthy_restore := restore_owner(numeric_truthy)
	check(numeric_truthy_restore.receipt.get("status") == "ready", "numeric truthy saveDelta accepted")
	var numeric_truthy_record := find_saved_record(
		volume_from_export(export_volume(numeric_truthy_restore.owner)), numeric_truthy_cell)
	check((numeric_truthy_record.get("state", {}) as Dictionary).get("metadata", {}).get("saveDelta", null) == 2.0,
		"numeric truthy saveDelta preserved")

	var numeric_zero := snapshot.duplicate(true)
	numeric_zero.sections[0].cells[0].state.metadata.saveDelta = 0.0
	var numeric_zero_restore := restore_owner(numeric_zero)
	failed(numeric_zero_restore.receipt, "zero saveDelta", "numeric zero saveDelta rejection")

	var nonconvertible := snapshot.duplicate(true)
	nonconvertible.sections[0].cells[0].state.metadata.saveDelta = "true"
	var nonconvertible_restore := restore_owner(nonconvertible)
	failed(nonconvertible_restore.receipt, "non-convertible saveDelta", "non-convertible saveDelta rejection")

	var fractional_revision := snapshot.duplicate(true)
	fractional_revision.revision = 1.5
	var fractional_revision_restore := restore_owner(fractional_revision)
	failed(fractional_revision_restore.receipt, "exact JSON integer", "fractional root revision rejection")

	var fractional_coordinate := snapshot.duplicate(true)
	fractional_coordinate.sections[0].sectionKey[0] = -2.5
	var fractional_coordinate_restore := restore_owner(fractional_coordinate)
	failed(fractional_coordinate_restore.receipt, "exact JSON integer", "fractional coordinate rejection")

	return {
		"booleanFalseRejected": bool_false_restore.receipt.get("status") == "failed",
		"numericTruthyPreserved": not numeric_truthy_record.is_empty(),
		"numericTruthyReceipt": numeric_truthy_restore.receipt,
		"numericZeroRejected": numeric_zero_restore.receipt.get("status") == "failed",
		"nonConvertibleRejected": nonconvertible_restore.receipt.get("status") == "failed",
		"fractionalRevisionRejected": fractional_revision_restore.receipt.get("status") == "failed",
		"fractionalCoordinateRejected": fractional_coordinate_restore.receipt.get("status") == "failed",
	}


func test_capacity_and_ordering() -> Dictionary:
	var exact := capacity_snapshot(MAX_RECORDS)
	var exact_sections: Array = exact.sections
	check(exact_sections.size() == 16 and (exact_sections[0].cells as Array).size() == SECTION_CELL_COUNT,
		"capacity fixture has full 4096-cell sections")
	var exact_restore := restore_owner(exact)
	var exact_accepted: bool = exact_restore.receipt.get("status") == "ready"
	check(exact_accepted, "exact 65536-record restore")
	exact_restore = {}
	exact = {}

	var excessive := over_capacity_shape_only_snapshot()
	var excessive_restore := restore_owner(excessive)
	failed(excessive_restore.receipt, "capacity", "65537-record restore")
	var plus_one_rejected: bool = excessive_restore.receipt.get("status") == "failed"
	excessive_restore = {}
	excessive = {}

	var oversized_section := over_section_capacity_shape_only_snapshot()
	var oversized_section_restore := restore_owner(oversized_section)
	failed(oversized_section_restore.receipt, "section cell count", "4097-cell section restore")
	var section_plus_one_rejected: bool = oversized_section_restore.receipt.get("status") == "failed"

	var unordered_sections := build_service_snapshot().duplicate(true)
	var section_values: Array = unordered_sections.sections
	var first_section: Variant = section_values[0]
	section_values[0] = section_values[1]
	section_values[1] = first_section
	var unordered_section_restore := restore_owner(unordered_sections)
	failed(unordered_section_restore.receipt, "terrain", "out-of-order sections")

	var unordered_cells := capacity_snapshot(2)
	var cell_values: Array = unordered_cells.sections[0].cells
	var first_cell: Variant = cell_values[0]
	cell_values[0] = cell_values[1]
	cell_values[1] = first_cell
	var unordered_cell_restore := restore_owner(unordered_cells)
	failed(unordered_cell_restore.receipt, "terrain", "out-of-order cells")
	return {"sectionCellLimit": SECTION_CELL_COUNT, "recordLimit": MAX_RECORDS,
		"exactSectionCount": 16, "exactAccepted": exact_accepted, "plusOneRejected": plus_one_rejected,
		"plusOneRejectedBeforeCellParse": plus_one_rejected,
		"sectionPlusOneRejectedBeforeCellParse": section_plus_one_rejected}


func _init() -> void:
	call_deferred("run")


func run() -> void:
	var report_path := OS.get_environment("VWB_N3_SAVE_V2_CONTRACT_REPORT")
	var empty := test_empty_export()
	var round_trip := test_service_and_save_round_trip(report_path)
	var overlay := test_overlay_is_not_persisted()
	var mutation := test_commit_replay_stale_and_pin()
	var one_shot := test_seed_and_one_shot_failures()
	var value_semantics := test_json_integer_and_metadata_semantics()
	var capacity := test_capacity_and_ordering()
	var report := {
		"schema": "native-world-backend-save-v2-contract/v1",
		"passed": failures.is_empty(),
		"evidenceLevel": "shadow-service-save-contract-only",
		"productionCutover": false,
		"checks": checks,
		"emptyExport": empty,
		"serviceRoundTrip": round_trip,
		"overlayPersistence": overlay,
		"mutationSemantics": mutation,
		"oneShotInitialization": one_shot,
		"jsonIntegerAndMetadataSemantics": value_semantics,
		"capacityAndOrdering": capacity,
		"failures": failures,
	}
	if report_path != "":
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	quit(0 if report.passed else 1)
