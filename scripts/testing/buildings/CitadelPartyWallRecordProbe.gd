extends SceneTree

func _initialize() -> void:
	var input := OS.get_environment("VOXEL_PROBE_INPUT")
	var output := OS.get_environment("VOXEL_PROBE_OUTPUT")
	var file := FileAccess.open(input, FileAccess.READ)
	if file == null: quit(2); return
	var raw = bytes_to_var(file.get_buffer(file.get_length()))
	file.close()
	var rows: Array = []
	for record: Dictionary in raw.afterSnapshot.parts:
		if String(record.id).begins_with("urban_row_03_right_upper_facade_00") or record.get("semantic") == "castle_keep_forecourt_pavilion": rows.append(record)
	var out := FileAccess.open(output, FileAccess.WRITE)
	out.store_string(JSON.stringify(_json(rows), "\t"))
	out.close()
	quit(0)

func _json(value: Variant) -> Variant:
	if value is Vector3: return {"x": value.x, "y": value.y, "z": value.z}
	if value is Dictionary:
		var out := {}
		for key in value: out[String(key)] = _json(value[key])
		return out
	if value is Array:
		var out := []
		for item in value: out.append(_json(item))
		return out
	return value
