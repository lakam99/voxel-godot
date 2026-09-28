extends SceneTree

func _initialize() -> void:
	var left: Variant = _read(OS.get_environment("VOXEL_SHELL_LEFT"))
	var right: Variant = _read(OS.get_environment("VOXEL_SHELL_RIGHT"))
	var differences := []
	if left is Dictionary and right is Dictionary:
		var a: Dictionary = left.afterSnapshot.duplicate(true)
		var b: Dictionary = right.afterSnapshot.duplicate(true)
		a.erase("parts"); b.erase("parts")
		var keys := a.keys()
		for key in b.keys():
			if not keys.has(key): keys.append(key)
		keys.sort()
		for key in keys:
			if not a.has(key) or not b.has(key) or var_to_bytes(a.get(key)) != var_to_bytes(b.get(key)):
				differences.append({"key": String(key), "left": str(a.get(key)), "right": str(b.get(key))})
	var output := FileAccess.open(OS.get_environment("VOXEL_SHELL_REPORT"), FileAccess.WRITE)
	if output != null: output.store_string(JSON.stringify({"differences": differences}, "\t")); output.close()
	quit(0)

func _read(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return null
	var value: Variant = bytes_to_var(file.get_buffer(file.get_length()))
	file.close()
	return value
