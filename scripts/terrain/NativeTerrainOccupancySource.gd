extends RefCounted
class_name NativeTerrainOccupancySource

## Gameplay occupancy vocabulary derived from one pinned native cell batch.
## This is source data, not a physical collision or navigation receipt.
var _cells

func bind(cell_source) -> Dictionary:
	if cell_source == null or not cell_source.has_method("read_cells"):
		return {"status":"failed", "reason":"native_cell_source_missing"}
	_cells = cell_source
	return {"status":"ready"}

func read_occupancy(cell: Vector3i) -> Dictionary:
	if _cells == null:
		return {"status":"failed", "reason":"native_cell_source_missing"}
	var cells: Array[Vector3i] = [cell, cell + Vector3i.UP, cell + Vector3i.DOWN]
	var sampled: Dictionary = _cells.read_cells(cells)
	if sampled.get("status") != "ready": return sampled
	var states: Array = sampled.get("states", [])
	if states.size() != 3:
		return {"status":"failed", "reason":"native_occupancy_batch_incomplete"}
	var center: Dictionary = states[0]
	var above: Dictionary = states[1]
	var below: Dictionary = states[2]
	var solid := bool(center.get("solid", false))
	var floor_solid := bool(below.get("solid", false))
	var ceiling_solid := bool(above.get("solid", false))
	return {"status":"ready", "nativeRevision":sampled.nativeRevision,
		"sourceIdentity":sampled.sourceIdentity,
		"occupancy":{"cell":cell, "solid":solid, "air":not solid,
			"material":String(center.get("material", "air")),
			"biome":String(center.get("biome", "")),
			"fluid":String(center.get("fluid", "")),
			"light":center.get("light", {"sky":0, "block":0}),
			"floorSolid":floor_solid, "ceilingSolid":ceiling_solid,
			"walkableAir":not solid and floor_solid and not ceiling_solid}}
