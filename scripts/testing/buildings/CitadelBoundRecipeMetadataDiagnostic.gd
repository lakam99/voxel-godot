extends SceneTree

func _initialize() -> void:
	var rows := {}
	for label: String in ["input", "expected"]:
		var path := OS.get_environment("VOXEL_BOUND_%s" % label.to_upper()).simplify_path()
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			quit(2)
			return
		var archive: Variant = bytes_to_var(file.get_buffer(file.get_length()))
		file.close()
		var selected: Array = []
		for part: Dictionary in archive.afterSnapshot.parts:
			if part.get("semantic") == "castle_keep_forecourt_pavilion":
				selected.append({"id": part.id, "partyWallModes": part.get("recipe", {}).get("physicalPartyWallBearingModes", [])})
		rows[label] = selected
	print(JSON.stringify(rows))
	quit(0)
