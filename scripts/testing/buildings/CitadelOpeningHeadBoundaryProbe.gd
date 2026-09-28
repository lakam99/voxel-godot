extends SceneTree
## Exact pinned source geometry only; synthetic empty furnishing policy.
const Heads = preload("res://scripts/buildings/OpeningHeadBandRecipe.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/candidate21-opening-capture-01/input.bin"
const INPUT_SHA := "29b6b34ba6b4d8e0b5a7d3d2b6005ad4d601b95e33c90e3bd5f31f934a8775cc"
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("CITADEL_OPENING_BOUNDARY_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output) or FileAccess.get_sha256(INPUT) != INPUT_SHA: quit(2); return
	var file := FileAccess.open(INPUT, FileAccess.READ)
	var input: Dictionary = file.get_var(false); file.close()
	var b = Heads.Copy.copy_blueprint(input.blueprint)
	var before := var_to_bytes(b.snapshot())
	var houses: Dictionary = Heads.Copy.street_house_memberships(b)
	var members: Array = houses.houses.filter(func(house): return house.prefix == input.failedHouse)[0].memberIds
	var result := Heads.prepare_first(b, members, {"furnitureParts": [], "reservedVolumes": [], "requiredHeadroom": 1.72})
	if result.get("reason") != "trimmed_panel_blocks_aperture": quit(1); return
	var conflict: Dictionary = result.geometryConflict
	var volume: AABB = conflict.protectedVolume
	var observations: Array = []
	for label in ["originalPanel", "trimmedPanel"]:
		var record: Dictionary = conflict[label]
		var bounds := AABB(record.position - record.size * 0.5, record.size)
		observations.append({"stage": label, "centerY": float(record.position.y), "height": float(record.size.y),
			"rawTop": float(record.position.y) + float(record.size.y) * 0.5, "aabbTop": float(bounds.end.y),
			"apertureBottom": float(volume.position.y), "rawOverlap": float(record.position.y) + float(record.size.y) * 0.5 - float(volume.position.y),
			"aabbOverlap": float(bounds.end.y) - float(volume.position.y)})
	var report := {"passed": before == var_to_bytes(b.snapshot()) and FileAccess.get_sha256(INPUT) == INPUT_SHA,
		"scope": "Numeric boundary diagnosis only; no acceptance or tolerance change.", "partId": conflict.partId, "observations": observations}
	file = FileAccess.open(output, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  ", true, true)); file.flush()
	var saved := file.get_error() == OK; file.close(); quit(0 if saved and report.passed else 1)
