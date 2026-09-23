extends RefCounted
class_name NativeDurableEditMirror

# Shadow-only bridge. TerrainVolumeService remains the gameplay/save owner until
# the native volume cutover; no native result is used to answer a game query.
const MATERIALS := ["air", "grass", "dirt", "stone", "sand", "snow", "deepStone", "bedrock", "clay", "gravel", "coalOre", "ironOre", "crystalOre", "copperOre", "mud", "water", "lava"]
const BIOMES := ["plains", "forest", "swamp", "desert", "savanna", "snow", "taiga", "tundra", "ocean", "beach", "town", "underground", "deep_underground", "underground_air", "alpine"]
const FLUIDS := ["", "water", "lava"]
const MAX_OPERATIONS := 4096

var _service
var _backend
var _records := {}
var _service_revision := -1
var _native_revision := -1
var _sequence := 0

func bind(service, backend) -> Dictionary:
	if service == null or backend == null or not service.has_method("save_all_section_deltas") \
			or not backend.has_method("commit_durable_cells"):
		return _failed("owner_missing")
	var source: Dictionary = service.save_all_section_deltas()
	var native: Dictionary = backend.export_terrain_volume_v2()
	if native.get("status") != "ready" or native.get("terrainVolume") != source:
		return _failed("initial_volume_mismatch")
	var indexed := _index(source)
	if indexed.get("status") != "ready":
		return indexed
	_service = service
	_backend = backend
	_records = indexed.records
	_service_revision = int(source.revision)
	_native_revision = int(native.get("terrainDeltaRevision", -1))
	_sequence = 0
	return {"status": "ready", "sourceRevision": _service_revision,
		"nativeRevision": _native_revision, "recordCount": _records.size()}

func synchronize() -> Dictionary:
	if _service == null or _backend == null:
		return _failed("not_bound")
	var source: Dictionary = _service.save_all_section_deltas()
	var source_revision := int(source.get("revision", -1))
	if source_revision < _service_revision:
		return _failed("source_revision_rewound")
	var indexed := _index(source)
	if indexed.get("status") != "ready":
		return indexed
	var next_records: Dictionary = indexed.records
	var native: Dictionary = _backend.export_terrain_volume_v2()
	if native.get("status") != "ready" or int(native.get("terrainDeltaRevision", -1)) != _native_revision:
		return _failed("native_revision_drift")
	var native_indexed := _index(native.get("terrainVolume", {}))
	if native_indexed.get("status") != "ready" or native_indexed.records != _records:
		return _failed("native_volume_drift")
	var cells: Array = []
	for cell in _records:
		if not next_records.has(cell) or next_records[cell] != _records[cell]:
			cells.append(cell)
	for cell in next_records:
		if not _records.has(cell):
			cells.append(cell)
	if cells.size() > MAX_OPERATIONS:
		return _failed("operation_limit_exceeded")
	cells.sort_custom(func(a: Vector3i, b: Vector3i): return a.z < b.z or a.z == b.z and (a.y < b.y or a.y == b.y and a.x < b.x))
	var operations: Array = []
	for cell: Vector3i in cells:
		if not next_records.has(cell):
			operations.append({"kind": "clear", "cell": cell})
			continue
		var state: Dictionary = next_records[cell]
		var material := MATERIALS.find(String(state.get("material", "")))
		var biome := BIOMES.find(String(state.get("biome", "")))
		var fluid := FLUIDS.find(String(state.get("fluid", "")))
		if material < 0 or biome < 0 or fluid < 0:
			return _failed("unsupported_cell_identity")
		var light: Dictionary = state.get("light", {})
		operations.append({"kind": "set", "cell": cell, "state": {
			"materialId": material, "biomeId": biome, "fluidId": fluid,
			"solid": state.solid, "density": state.density,
			"light": Vector2i(int(light.get("sky", -1)), int(light.get("block", -1))),
			"metadata": state.metadata, "blockId": state.blockId,
			"editReason": state.editReason}})
	if operations.is_empty():
		_records = next_records
		_service_revision = source_revision
		return {"status": "ready", "commitStatus": "no_change", "operationCount": 0,
			"sourceRevision": _service_revision, "nativeRevision": _native_revision}
	var request := {"schema": "n3-native-durable-cell-transaction/v1",
		"transactionId": "shadow-volume:%d:%d" % [_native_revision, _sequence],
		"expectedRevision": _native_revision, "operations": operations}
	var receipt: Dictionary = _backend.commit_durable_cells(request)
	if receipt.get("status") != "ready" or receipt.get("commitStatus") != "committed":
		return _failed("native_commit_failed: " + String(receipt.get("reason", receipt.get("commitStatus", ""))))
	var after: Dictionary = _backend.export_terrain_volume_v2()
	var after_indexed := _index(after.get("terrainVolume", {}))
	if after.get("status") != "ready" or after_indexed.get("status") != "ready" \
			or after_indexed.records != next_records or int(after.get("terrainDeltaRevision", -1)) != _native_revision + 1:
		return _failed("native_commit_verification_failed")
	_records = next_records
	_service_revision = source_revision
	_native_revision += 1
	_sequence += 1
	return {"status": "ready", "commitStatus": "committed", "operationCount": operations.size(),
		"sourceRevision": _service_revision, "nativeRevision": _native_revision,
		"affectedSections": receipt.get("affectedSections", [])}

static func _index(snapshot) -> Dictionary:
	if not snapshot is Dictionary or snapshot.get("schemaVersion") != 1 or snapshot.get("sectionSize") != 16:
		return _failed("volume_schema_invalid")
	var result := {}
	var sections = snapshot.get("sections", null)
	if not sections is Array:
		return _failed("volume_sections_invalid")
	for section in sections:
		if not section is Dictionary or not section.get("cells", null) is Array:
			return _failed("volume_section_invalid")
		for record in section.cells:
			if not record is Dictionary or not record.get("state", null) is Dictionary:
				return _failed("volume_record_invalid")
			var coordinates = record.get("cell", null)
			if not coordinates is Array or coordinates.size() != 3:
				return _failed("volume_cell_invalid")
			var cell := Vector3i(int(coordinates[0]), int(coordinates[1]), int(coordinates[2]))
			if result.has(cell):
				return _failed("volume_duplicate_cell")
			result[cell] = record.state
	return {"status": "ready", "records": result}

static func _failed(reason: String) -> Dictionary:
	return {"status": "failed", "reason": reason}
