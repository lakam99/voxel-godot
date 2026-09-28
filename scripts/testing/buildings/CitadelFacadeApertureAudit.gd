extends SceneTree
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/candidate21-opening-producer-02/input.bin"
const SHA := "36ba4b715af39c9fad9cffcd7953c5f591afba1881daee61cedc6addf242bd80"
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("CITADEL_APERTURE_AUDIT_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output) or FileAccess.get_sha256(INPUT) != SHA: quit(2); return
	var file := FileAccess.open(INPUT, FileAccess.READ)
	var input: Dictionary = file.get_var(false); file.close()
	var source = Copy.copy_blueprint(input.blueprint)
	var missing: Array = []
	var hits: Array = []
	var total := 0
	for key in source.recipe.facadeApertures:
		var declaration: Dictionary = source.recipe.facadeApertures[key]
		for id: String in declaration.partIds:
			var part = source.find_part(id)
			if part == null: missing.append(id); continue
			var bounds: AABB = source.transformed_part_bounds(part)
			for opening: Dictionary in declaration.openings:
				var volume: AABB = opening.fullVolume
				if not bounds.intersects(volume): continue
				total += 1
				if hits.size() < 16: hits.append({"declaration": key, "part": part.snapshot(), "bounds": bounds, "opening": opening, "overlap": bounds.end.min(volume.end) - bounds.position.max(volume.position)})
	var report := {"passed": FileAccess.get_sha256(INPUT) == SHA, "missing": missing, "hitCount": total, "hits": hits,
		"scope": "Pinned source aperture intersection audit. Passing means observations completed, not aperture clearance or gameplay acceptance."}
	file = FileAccess.open(output, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  ", true, true)); file.flush()
	var saved := file.get_error() == OK; file.close(); quit(0 if saved and report.passed else 1)
