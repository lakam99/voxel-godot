extends RefCounted
class_name NavSpanKey

var tile_key := ""
var cell := Vector3i.ZERO
var span_index := 0
var stable_id := ""

static func make(tile_key_value: String, cell_value: Vector3i, span_index_value := 0):
	var key = load("res://scripts/npc_ai/contracts/NavSpanKey.gd").new()
	key.tile_key = tile_key_value
	key.cell = cell_value
	key.span_index = span_index_value
	key.stable_id = "%s:%d,%d,%d:%d" % [tile_key_value, cell_value.x, cell_value.y, cell_value.z, span_index_value]
	return key

static func from_string(value: String):
	var key = load("res://scripts/npc_ai/contracts/NavSpanKey.gd").new()
	key.stable_id = value
	var parts := value.split(":")
	if parts.size() >= 3:
		key.tile_key = String(parts[0])
		var coords := String(parts[1]).split(",")
		if coords.size() == 3:
			key.cell = Vector3i(int(coords[0]), int(coords[1]), int(coords[2]))
		key.span_index = int(parts[2])
	return key

func as_string() -> String:
	if stable_id == "":
		stable_id = "%s:%d,%d,%d:%d" % [tile_key, cell.x, cell.y, cell.z, span_index]
	return stable_id

func to_summary() -> Dictionary:
	return {
		"id": as_string(),
		"tileKey": tile_key,
		"cell": [cell.x, cell.y, cell.z],
		"spanIndex": span_index
	}
