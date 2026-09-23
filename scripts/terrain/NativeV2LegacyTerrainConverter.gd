extends RefCounted
class_name NativeV2LegacyTerrainConverter

## Loading-only conversion for valid v2 saves with historical `terrain`
## columns and no terrainVolume. Uses native surface facts and typed deltas;
## each advance admits at most one 64-cell transaction.
const SourceRequest = preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const PageAdmission = preload("res://scripts/world/NativeShapingPageAdmission.gd")
const CellSource = preload("res://scripts/terrain/NativeTerrainCellSource.gd")
const DurableCodec = preload("res://scripts/terrain/NativeDurableEditMirror.gd")
const MAX_CELLS_PER_STEP := 64
const MAX_COLUMN_OPERATIONS := 4096

var _backend
var _pages
var _admission
var _entries: Array = []
var _entry_index := 0
var _column := Vector2i.ZERO
var _next_y := 0
var _last_y := -1
var _state := "new"
var _failure := ""
var _cell_meters := 0.0
var _staged_operations: Array = []
var _save_snapshot := {}

func setup(main, save: Dictionary) -> Dictionary:
	if _state != "new": return _failed("converter_already_started")
	if main == null or int(save.get("version", -1)) != 2 \
			or String(save.get("seed", main.get("seed_text"))) != String(main.get("seed_text")):
		return _failed("save_v2_identity_invalid")
	var entries = save.get("terrain", null)
	if not entries is Array or entries.is_empty() \
			or not save.get("terrainVolume", {}) is Dictionary \
			or not (save.get("terrainVolume", {}) as Dictionary).is_empty():
		return _failed("legacy_terrain_only_save_required")
	for entry in entries:
		if not entry is Dictionary or not entry.get("x", 0) is int \
				or not entry.get("z", 0) is int:
			return _failed("legacy_terrain_entry_invalid")
		var height = entry.get("surfaceY", entry.get("height", null))
		if height != null and (not height is float and not height is int \
				or not is_finite(float(height))):
			return _failed("legacy_terrain_entry_invalid")
	var source: Dictionary = SourceRequest.from_main_with_save_volume(main,
		{"schemaVersion":1, "sectionSize":16, "revision":0, "sections":[]})
	if source.get("status") != "ready": return _failed(String(source.get("reason", "native_source_invalid")))
	_cell_meters = float(source.request.constants.cellSizeMeters)
	if _cell_meters <= 0.0 or DurableCodec.BIOMES.find("underground_air") < 0:
		return _failed("native_legacy_constants_invalid")
	_backend = ClassDB.instantiate("NativeWorldBackend")
	if _backend == null: return _failed("native_backend_unavailable")
	var initialized: Dictionary = _backend.initialize_from_save_v2(source.request)
	if initialized.get("status") != "ready":
		return _failed(String(initialized.get("reason", "native_initialize_failed")))
	var structures = main.get("structure_system")
	_admission = structures.get("citadel_terrain_admission") if structures != null else null
	_pages = PageAdmission.new()
	var bound: Dictionary = _pages.setup(_backend, _admission)
	if bound.get("status") != "ready":
		return _failed(String(bound.get("reason", "shaping_admission_missing")))
	_entries = entries.duplicate(true)
	_save_snapshot = save.duplicate(true)
	_state = "active"
	return {"status":"ready", "entryCount":_entries.size()}

func advance() -> Dictionary:
	if _state == "complete": return export_volume()
	if _state != "active": return _failed("converter_not_active")
	if _entry_index >= _entries.size():
		_state = "complete"
		return export_volume()
	if _next_y > _last_y:
		var entry = _entries[_entry_index]
		if not entry is Dictionary:
			return _failed("legacy_terrain_entry_invalid")
		_column = Vector2i(int(entry.get("x", 0)), int(entry.get("z", 0)))
		var page := Vector2i(floori(float(_column.x) / CellSource.PAGE_CELLS),
			floori(float(_column.y) / CellSource.PAGE_CELLS))
		var site: Dictionary = _admission.advance()
		if not String(site.get("failure", "")).is_empty():
			return _failed(String(site.failure))
		var admitted: Dictionary = _pages.request_page(page)
		if admitted.get("status") != "ready": return admitted
		var pin: Dictionary = _backend.pin_effective_page(page)
		if pin.get("status") != "ready": return pin
		var smooth: Dictionary = pin.page.sample_continuous_surface(_column)
		var page_status: Dictionary = pin.page.status()
		if smooth.get("status") != "ready" or smooth.get("column") != _column \
				or smooth.get("sourceIdentity") != page_status.get("sourceIdentity") \
				or smooth.get("pinIdentity") != page_status.get("pinIdentity") \
				or smooth.get("terrainDeltaRevision") != page_status.get("terrainDeltaRevision") \
				or smooth.get("shapingRegistryRevision") != page_status.get("shapingRegistryRevision"):
			return _failed("native_legacy_surface_unavailable")
		var old_surface := float(smooth.surfaceY)
		var new_surface := float(entry.get("surfaceY", entry.get("height", old_surface)))
		if new_surface >= old_surface - _cell_meters * 0.10:
			_entry_index += 1
			return {"status":"pending", "reason":"no_excavation"}
		_next_y = floori(new_surface / _cell_meters)
		_last_y = ceili(old_surface / _cell_meters)
		_staged_operations.clear()
		if _last_y - _next_y + 1 > MAX_COLUMN_OPERATIONS:
			return _failed("legacy_column_operation_limit")
		if _next_y > _last_y:
			_entry_index += 1
			return {"status":"pending", "reason":"no_excavation"}
	var operations: Array = []
	var end_y := mini(_last_y, _next_y + MAX_CELLS_PER_STEP - 1)
	for y in range(_next_y, end_y + 1):
		operations.append({"kind":"set", "cell":Vector3i(_column.x, y, _column.y),
			"state":{"materialId":DurableCodec.MATERIALS.find("air"),
				"biomeId":DurableCodec.BIOMES.find("underground_air"),
				"fluidId":DurableCodec.FLUIDS.find(""),
				"solid":false, "density":-_cell_meters, "light":Vector2i.ZERO,
				"metadata":{"source":"legacy_volume_edit", "terrainMeshAffects":true,
					"saveDelta":true}, "blockId":"air",
				"editReason":"legacy_volume_edit_restore"}})
	_staged_operations.append_array(operations)
	_next_y = end_y + 1
	if _next_y <= _last_y:
		return {"status":"pending", "reason":"preparing_legacy_column",
			"preparedCells":_staged_operations.size(), "completedEntries":_entry_index}
	var before: Dictionary = _backend.status()
	var transaction := {"schema":"n3-native-durable-cell-transaction/v1",
		"transactionId":"v2-legacy:%d" % _entry_index,
		"expectedRevision":int(before.get("terrainDeltaRevision", -1)),
		"operations":_staged_operations}
	var committed: Dictionary = _backend.commit_durable_cells(transaction)
	if committed.get("status") != "ready" or committed.get("commitStatus") != "committed":
		return _failed(String(committed.get("reason", "native_legacy_commit_failed")))
	_staged_operations.clear()
	_entry_index += 1
	return {"status":"pending", "reason":"legacy_conversion_progress",
		"completedEntries":_entry_index, "entryCount":_entries.size()}

func export_volume() -> Dictionary:
	if _state != "complete": return {"status":"pending", "reason":"legacy_conversion_incomplete"}
	var exported: Dictionary = _backend.export_terrain_volume_v2()
	if exported.get("status") != "ready": return _failed("native_legacy_export_failed")
	return {"status":"ready", "terrainVolume":exported.terrainVolume,
		"nativeRevision":exported.terrainDeltaRevision}

func resolved_save() -> Dictionary:
	var exported: Dictionary = export_volume()
	if exported.get("status") != "ready": return exported
	var save: Dictionary = _save_snapshot.duplicate(true)
	save["terrainVolume"] = exported.terrainVolume
	save["terrain"] = []
	return {"status":"ready", "save":save}

func cancel() -> Dictionary:
	if _state == "complete": return {"status":"failed", "reason":"converter_already_complete"}
	_state = "cancelled"
	_backend = null
	_pages = null
	_admission = null
	_staged_operations.clear()
	return {"status":"ready", "cancelled":true}

func _failed(reason: String) -> Dictionary:
	_failure = reason
	_state = "failed"
	return {"status":"failed", "reason":reason}
