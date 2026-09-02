extends SceneTree

func _initialize() -> void:
	var input := OS.get_environment("VOXEL_HISTORY_INPUT")
	var output := OS.get_environment("VOXEL_HISTORY_OUTPUT")
	var sha := OS.get_environment("VOXEL_HISTORY_SHA")
	if FileAccess.get_sha256(input) != sha: quit(2); return
	var file := FileAccess.open(input, FileAccess.READ)
	if file == null: quit(2); return
	var raw = bytes_to_var(file.get_buffer(file.get_length()))
	file.close()
	if not raw is Dictionary: quit(2); return
	var result := {"candidateHistory": raw.get("candidateHistory", []),
		"partCount": raw.afterSnapshot.parts.size(), "roomCount": raw.afterSnapshot.rooms.size(),
		"furnitureCount": raw.furnitureSnapshot.parts.size(), "reservationCount": raw.protectedReservations.size()}
	var out := FileAccess.open(output, FileAccess.WRITE)
	if out == null: quit(2); return
	out.store_string(JSON.stringify(_json(result), "\t")); out.close(); quit(0)

func _json(value: Variant) -> Variant:
	if value is Vector2: return {"x": value.x, "y": value.y}
	if value is Vector3: return {"x": value.x, "y": value.y, "z": value.z}
	if value is AABB: return {"position": _json(value.position), "size": _json(value.size)}
	if value is Dictionary:
		var out := {}
		for key in value: out[String(key)] = _json(value[key])
		return out
	if value is Array:
		var out := []
		for item in value: out.append(_json(item))
		return out
	return value
