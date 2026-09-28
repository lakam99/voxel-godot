extends SceneTree

const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Recipe = preload("res://scripts/buildings/ChimneyBearingRecipe.gd")

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var input := OS.get_environment("VOXEL_CHIMNEY_PROBE_INPUT")
	var output := OS.get_environment("VOXEL_CHIMNEY_PROBE_OUTPUT")
	var expected_sha := OS.get_environment("VOXEL_CHIMNEY_PROBE_SHA")
	if FileAccess.get_sha256(input) != expected_sha: quit(2); return
	var file := FileAccess.open(input, FileAccess.READ)
	if file == null: quit(2); return
	var raw = bytes_to_var(file.get_buffer(file.get_length()))
	file.close()
	if not raw is Dictionary: quit(2); return
	var obstacles: Array = []
	for record: Dictionary in raw.furnitureSnapshot.parts:
		var bounds := Transform3D(Basis.from_euler(record.rotation), record.position) * AABB(Vector3(-record.occupiedSize.x * 0.5, 0, -record.occupiedSize.z * 0.5), record.occupiedSize)
		obstacles.append({"id": "furnishing:" + record.id, "bounds": bounds})
	for index in range(raw.protectedReservations.size()):
		obstacles.append({"id": "furnishing_access:%d" % index, "bounds": raw.protectedReservations[index]})
	var id := "urban_row_01_right_chimney"
	var prefix := id.trim_suffix("_chimney")
	var result: Dictionary = Recipe.plan(Copy.copy_blueprint(raw.afterSnapshot), id,
		[prefix + "_upper_shell_side_-1", prefix + "_upper_shell_side_1"],
		[prefix + "_foundation", prefix + "_stone_shell_side_-1", prefix + "_stone_shell_side_1"], obstacles)
	var banner_record: Dictionary = {}
	for record: Dictionary in raw.afterSnapshot.parts:
		if record.id == "urban_street_banner_01": banner_record = record; break
	var near_banner: Array = []
	if not banner_record.is_empty():
		var banner_bounds := _bounds(banner_record).grow(1.5)
		for record: Dictionary in raw.afterSnapshot.parts:
			if banner_bounds.intersects(_bounds(record)): near_banner.append(record)
	result["bannerRecord"] = banner_record
	result["chimneyRecord"] = raw.afterSnapshot.parts.filter(func(record): return record.id == id).front()
	result["nearBannerRecords"] = near_banner
	var out := FileAccess.open(output, FileAccess.WRITE)
	if out == null: quit(2); return
	out.store_string(JSON.stringify(_json(result), "\t"))
	out.close()
	quit(0)

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

func _bounds(record: Dictionary) -> AABB:
	return Transform3D(Basis.from_euler(record.rotation), record.position) * AABB(-record.size * 0.5, record.size)
