extends RefCounted
class_name NativeTerrainNumericSource

## N3 source slice for the old numeric mesh sample and numeric surface
## projection contracts. Both channels are resolved from the same native
## source/delta/shaping revision. This is not a collision publication receipt.
const PAGE_CELLS := 280
const CELL_METERS := 1.35
const SEMANTIC_REVISION := 1
const MAX_QUERIES := 64
const MAX_PAGES := 8
const SCHEMA := "n3-effective-terrain-batch-request/v1"

var _backend

func bind(backend) -> Dictionary:
	if backend == null or not backend.has_method("pin_effective_page") \
			or not backend.has_method("status"):
		return {"status":"failed", "reason":"native_terrain_owner_missing"}
	_backend = backend
	return {"status":"ready"}

func read_world_numeric(position: Vector3) -> Dictionary:
	var result := read_numeric_batch([position], [])
	if result.get("status") != "ready":
		return result
	return {"status":"ready", "facts":result.worldNumeric[0],
		"nativeRevision":result.nativeRevision, "sourceIdentity":result.sourceIdentity}

func read_surface_projection_numeric(cell: Vector3i) -> Dictionary:
	var result := read_numeric_batch([], [cell])
	if result.get("status") != "ready":
		return result
	return {"status":"ready", "facts":result.surfaceProjectionNumeric[0],
		"nativeRevision":result.nativeRevision, "sourceIdentity":result.sourceIdentity}

func read_numeric_batch(world_positions: Array[Vector3], projection_cells: Array[Vector3i]) -> Dictionary:
	if _backend == null:
		return {"status":"failed", "reason":"native_terrain_owner_missing"}
	if world_positions.size() + projection_cells.size() <= 0 \
			or world_positions.size() + projection_cells.size() > MAX_QUERIES:
		return {"status":"failed", "reason":"numeric_batch_limit"}
	var before: Dictionary = _backend.status()
	if before.get("status") != "ready":
		return {"status":"failed", "reason":"native_backend_not_ready"}
	var revision := int(before.get("terrainDeltaRevision", -1))
	var shaping_revision := int(before.get("shapingRegistryRevision", -1))
	if revision < 0 or shaping_revision < 0:
		return {"status":"failed", "reason":"native_revision_missing"}
	var groups := {}
	for index in range(world_positions.size()):
		var position := world_positions[index]
		var cell := Vector3i(floori(position.x / CELL_METERS),
			floori(position.y / CELL_METERS), floori(position.z / CELL_METERS))
		_add_group(groups, _page(cell), {"channel":"world", "index":index, "position":position})
	for index in range(projection_cells.size()):
		var cell := projection_cells[index]
		_add_group(groups, _page(cell), {"channel":"projection", "index":index, "cell":cell})
	if groups.size() > MAX_PAGES:
		return {"status":"failed", "reason":"page_batch_limit"}
	var world_rows: Array[Dictionary] = []
	world_rows.resize(world_positions.size())
	var projection_rows: Array[Dictionary] = []
	projection_rows.resize(projection_cells.size())
	var identity := {}
	for page: Vector2i in groups:
		var pinned: Dictionary = _backend.pin_effective_page(page)
		if pinned.get("status") != "ready":
			return {"status":pinned.get("status", "failed"),
				"reason":pinned.get("reason", "native_page_not_ready"), "page":page}
		var source = pinned.get("page")
		if source == null:
			return {"status":"failed", "reason":"native_page_pin_missing", "page":page}
		var request := {"schema":SCHEMA, "surfaceColumns":[], "cellCenters":[],
			"latticeNumeric":[], "worldNumeric":[], "surfaceProjectionNumeric":[]}
		var world_entries: Array = []
		var projection_entries: Array = []
		for entry in groups[page]:
			if entry.channel == "world":
				world_entries.append(entry)
				request.worldNumeric.append({"position":entry.position,
					"intent":"terrain_mesh", "semanticRevision":SEMANTIC_REVISION})
			else:
				projection_entries.append(entry)
				request.surfaceProjectionNumeric.append({"coordinate":entry.cell,
					"intent":"terrain_collision", "semanticRevision":SEMANTIC_REVISION})
		var sampled: Dictionary = source.sample_batch(request)
		if sampled.get("status") != "ready" or int(sampled.get("terrainDeltaRevision", -1)) != revision \
				or int(sampled.get("shapingRegistryRevision", -1)) != shaping_revision \
				or (sampled.get("worldNumeric", []) as Array).size() != world_entries.size() \
				or (sampled.get("surfaceProjectionNumeric", []) as Array).size() != projection_entries.size():
			return {"status":"failed", "reason":"native_page_result_stale_or_incomplete", "page":page}
		if identity.is_empty():
			identity = sampled.get("sourceIdentity", {})
		elif identity != sampled.get("sourceIdentity", {}):
			return {"status":"failed", "reason":"mixed_native_source_identity"}
		for offset in range(world_entries.size()):
			var row: Dictionary = sampled.worldNumeric[offset]
			var entry: Dictionary = world_entries[offset]
			if row.get("requestedPosition") != entry.position or row.get("intent") != "terrain_mesh" \
					or int(row.get("semanticRevision", -1)) != SEMANTIC_REVISION:
				return {"status":"failed", "reason":"native_world_query_mismatch"}
			world_rows[int(entry.index)] = row
		for offset in range(projection_entries.size()):
			var row: Dictionary = sampled.surfaceProjectionNumeric[offset]
			var entry: Dictionary = projection_entries[offset]
			if row.get("requestedCell") != entry.cell \
					or row.get("requested", {}).get("intent") != "terrain_collision" \
					or int(row.get("semanticRevision", -1)) != SEMANTIC_REVISION:
				return {"status":"failed", "reason":"native_projection_query_mismatch"}
			projection_rows[int(entry.index)] = row
	var after: Dictionary = _backend.status()
	if after.get("status") != "ready" or int(after.get("terrainDeltaRevision", -1)) != revision \
			or int(after.get("shapingRegistryRevision", -1)) != shaping_revision:
		return {"status":"failed", "reason":"native_revision_changed_during_read"}
	return {"status":"ready", "worldNumeric":world_rows,
		"surfaceProjectionNumeric":projection_rows, "nativeRevision":revision,
		"shapingRevision":shaping_revision, "sourceIdentity":identity}

static func _add_group(groups: Dictionary, page: Vector2i, entry: Dictionary) -> void:
	var entries: Array = groups.get(page, [])
	entries.append(entry)
	groups[page] = entries

static func _page(cell: Vector3i) -> Vector2i:
	return Vector2i(floori(float(cell.x) / PAGE_CELLS), floori(float(cell.z) / PAGE_CELLS))
