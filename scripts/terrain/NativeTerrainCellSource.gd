extends RefCounted
class_name NativeTerrainCellSource

## One N3 cutover slice: canonical gameplay cell state comes from a pinned
## native effective page. Pending shaping and revision races are explicit;
## there is no script sampler fallback or partial batch result.
const PAGE_CELLS := 280
const MAX_CELLS := 64
const MAX_PAGES := 8
const SCHEMA := "n3-effective-terrain-batch-request/v1"

var _backend

func bind(backend) -> Dictionary:
	if backend == null or not backend.has_method("pin_effective_page") \
			or not backend.has_method("status"):
		return {"status":"failed", "reason":"native_terrain_owner_missing"}
	_backend = backend
	return {"status":"ready"}

func read_cell(cell: Vector3i) -> Dictionary:
	var result := read_cells([cell])
	if result.get("status") != "ready":
		return result
	return {"status":"ready", "cell":cell, "state":result.states[0],
		"nativeRevision":result.nativeRevision, "shapingRevision":result.shapingRevision,
		"sourceIdentity":result.sourceIdentity}

func read_cells(cells: Array[Vector3i]) -> Dictionary:
	if _backend == null:
		return {"status":"failed", "reason":"native_terrain_owner_missing"}
	if cells.is_empty() or cells.size() > MAX_CELLS:
		return {"status":"failed", "reason":"cell_batch_limit"}
	var before: Dictionary = _backend.status()
	if before.get("status") != "ready":
		return {"status":"failed", "reason":"native_backend_not_ready"}
	var revision := int(before.get("terrainDeltaRevision", -1))
	var shaping_revision := int(before.get("shapingRegistryRevision", -1))
	if revision < 0 or shaping_revision < 0:
		return {"status":"failed", "reason":"native_revision_missing"}
	var groups := {}
	for index in range(cells.size()):
		var cell := cells[index]
		var page := Vector2i(floori(float(cell.x) / PAGE_CELLS),
			floori(float(cell.z) / PAGE_CELLS))
		var entries: Array = groups.get(page, [])
		entries.append({"index":index, "cell":cell})
		groups[page] = entries
		if groups.size() > MAX_PAGES:
			return {"status":"failed", "reason":"page_batch_limit"}
	var states: Array[Dictionary] = []
	states.resize(cells.size())
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
		var entries: Array = groups[page]
		for entry in entries:
			request.cellCenters.append({"coordinate":entry.cell, "intent":"gameplay"})
		var sampled: Dictionary = source.sample_batch(request)
		if sampled.get("status") != "ready" or int(sampled.get("terrainDeltaRevision", -1)) != revision \
				or int(sampled.get("shapingRegistryRevision", -1)) != shaping_revision \
				or (sampled.get("cellCenters", []) as Array).size() != entries.size():
			return {"status":"failed", "reason":"native_page_result_stale_or_incomplete", "page":page}
		if identity.is_empty():
			identity = sampled.get("sourceIdentity", {})
		elif identity != sampled.get("sourceIdentity", {}):
			return {"status":"failed", "reason":"mixed_native_source_identity"}
		for offset in range(entries.size()):
			var record: Dictionary = sampled.cellCenters[offset]
			if record.get("sourceCell") != entries[offset].cell \
					or record.get("requested", {}).get("intent") != "gameplay":
				return {"status":"failed", "reason":"native_cell_order_mismatch", "page":page}
			var sparse: Dictionary = record.get("editedSparseState", {}) if record.get("editedSparseState", {}) is Dictionary else {}
			var light: Vector2i = record.get("light", Vector2i.ZERO)
			states[int(entries[offset].index)] = {"material":String(record.material),
				"biome":String(record.biome), "fluid":String(record.fluid),
				"solid":bool(record.solid), "density":float(record.density),
				"light":{"sky":light.x, "block":light.y},
				"metadata":sparse.get("metadata", {}), "blockId":sparse.get("blockId", ""),
				"editReason":sparse.get("editReason", ""),
				"edited":bool(record.edited), "generated":bool(record.generated)}
	var after: Dictionary = _backend.status()
	if after.get("status") != "ready" or int(after.get("terrainDeltaRevision", -1)) != revision \
			or int(after.get("shapingRegistryRevision", -1)) != shaping_revision:
		return {"status":"failed", "reason":"native_revision_changed_during_read"}
	return {"status":"ready", "states":states, "nativeRevision":revision,
		"shapingRevision":shaping_revision, "sourceIdentity":identity}
