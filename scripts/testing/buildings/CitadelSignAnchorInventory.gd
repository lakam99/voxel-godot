extends SceneTree

const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")

func _initialize() -> void:
	var path := OS.get_environment("VOXEL_SIGN_ANCHOR_INPUT")
	var sha := OS.get_environment("VOXEL_SIGN_ANCHOR_SHA").to_lower()
	if not FileAccess.file_exists(path) or FileAccess.get_sha256(path) != sha: quit(2); return
	var file := FileAccess.open(path, FileAccess.READ)
	var bytes := file.get_buffer(file.get_length()); file.close()
	var raw: Variant = bytes_to_var(bytes)
	if not raw is Dictionary: quit(2); return
	var source = Copy.copy_blueprint(raw.afterSnapshot)
	var prefix := "urban_row_00_right"
	var key := prefix + "_upper_facade"
	var declaration: Dictionary = source.recipe.facadeApertures[key]
	var declared: Array = []
	for id: String in declaration.partIds:
		var part = _part(source, id)
		if part != null and part.semantic == "citadel_urban_facade": declared.append(_row(source, part))
	var membership := Copy.street_house_memberships(source)
	var house: Dictionary = membership.houses.filter(func(row): return row.prefix == prefix)[0]
	var accepted_view: Array = house.facadeIds.map(func(id): return _row(source, _part(source, id)))
	var report := {"passed": membership.ready, "declared": declared, "membership": accepted_view,
		"declaredIds": declared.map(func(row): return row.id), "membershipIds": accepted_view.map(func(row): return row.id)}
	var output := FileAccess.open(OS.get_environment("VOXEL_SIGN_ANCHOR_REPORT"), FileAccess.WRITE)
	output.store_string(JSON.stringify(report, "\t")); output.close(); quit(0)

func _row(source, part) -> Dictionary:
	return {"id": part.id, "semantic": part.semantic, "kind": part.kind, "collision": part.collision_enabled,
		"rotation": part.rotation, "intent": part.physical_intent, "finite": source.has_finite_positive_bounds(part)}

func _part(source, id: String):
	for part in source.parts:
		if part.id == id: return part
	return null
