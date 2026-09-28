extends RefCounted

## Neutral represented-construction arithmetic shared by recipes and admission.
## Extraction only: scalar seam accounting and float32 stepping are unchanged.
const ReplacementOccupancy = preload("res://scripts/buildings/ReplacementBoxOccupancy.gd")
const EDGE_EPS := 0.00001 # Existing grouping/seam policy, not joint forgiveness.

static func construction_seam_cells(bounds: Array, panels: Array) -> Dictionary:
	if not ReplacementOccupancy.valid(bounds) or panels.is_empty() or panels.size() > 512: return _fail("invalid_seam_input")
	var old: Array = []
	for panel in panels:
		if panel == null or panel.rotation != Vector3.ZERO or not panel.position.is_finite() or not panel.size.is_finite(): return _fail("invalid_seam_panel")
		old.append([float(panel.position.x) - float(panel.size.x) * 0.5, float(panel.position.y) - float(panel.size.y) * 0.5, float(panel.position.z) - float(panel.size.z) * 0.5,
			float(panel.position.x) + float(panel.size.x) * 0.5, float(panel.position.y) + float(panel.size.y) * 0.5, float(panel.position.z) + float(panel.size.z) * 0.5])
	var difference := ReplacementOccupancy.cover(bounds, old)
	if not difference.ready: return difference
	for cell: Array in difference.uncovered:
		if minf(cell[4] - cell[1], cell[5] - cell[2]) > EDGE_EPS: return _fail("undeclared_facade_void_would_be_filled")
	return {"ready": true, "addedSolidCells": difference.uncovered, "work": difference.work, "maximumSeamWidth": EDGE_EPS,
		"policy": "Existing opening-head construction seam policy; every added cell still requires aperture and occupancy admission."}

static func next_float32_up(value: float) -> float:
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_float(0, value)
	var bits := bytes.decode_u32(0)
	if value == 0.0: bits = 1
	else: bits += 1 if value > 0.0 else -1
	bytes.encode_u32(0, bits)
	return bytes.decode_float(0)

static func _fail(reason: String) -> Dictionary:
	return {"ready": false, "reason": reason}
