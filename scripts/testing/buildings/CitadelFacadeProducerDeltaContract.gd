extends SceneTree
const OLD := "res://artifacts/citadel-runtime-integration/candidate21-opening-capture-01/input.bin"
const OLD_SHA := "29b6b34ba6b4d8e0b5a7d3d2b6005ad4d601b95e33c90e3bd5f31f934a8775cc"
const NEW := "res://artifacts/citadel-runtime-integration/candidate21-policy-capture-01/input.bin"
const NEW_SHA := "d6df2eeff4044d85d41cd46e1dc9b200740a01b3abd36455b6536ceb3514a903"
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var output := OS.get_environment("CITADEL_FACADE_DELTA_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output) or FileAccess.get_sha256(OLD) != OLD_SHA or FileAccess.get_sha256(NEW) != NEW_SHA: quit(2); return
	var old: Dictionary = _read(OLD).blueprint
	var current: Dictionary = _read(NEW).blueprint
	var checks := {"same_part_order": old.parts.map(func(part): return part.id) == current.parts.map(func(part): return part.id), "same_rooms": var_to_bytes(old.rooms) == var_to_bytes(current.rooms)}
	var changes: Array = []
	var unexpected: Array = []
	var max_delta := 0.0
	if checks.same_part_order:
		for index in range(old.parts.size()):
			var a: Dictionary = old.parts[index]
			var b: Dictionary = current.parts[index]
			if a.position == b.position and a.size == b.size and a.rotation == b.rotation: continue
			changes.append(a.id)
			if a.semantic not in ["citadel_urban_facade", "citadel_urban_stone_base"] or a.position.x != b.position.x or a.size.x != b.size.x or a.rotation != b.rotation or a.kind != b.kind or a.material != b.material or a.collision != b.collision or a.recipe.variation != b.recipe.variation:
				unexpected.append(a.id)
			for axis in range(3): max_delta = maxf(max_delta, maxf(absf(a.position[axis] - b.position[axis]), absf(a.size[axis] - b.size[axis])))
	checks.only_partition_geometry = unexpected.is_empty() and not changes.is_empty()
	var declarations_exact := true
	for key in old.recipe.facadeApertures:
		var a: Dictionary = old.recipe.facadeApertures[key].duplicate(true)
		var b: Dictionary = current.recipe.facadeApertures.get(key, {}).duplicate(true)
		a.erase("sourceBinding"); b.erase("sourceBinding")
		declarations_exact = declarations_exact and var_to_bytes(a) == var_to_bytes(b)
	checks.aperture_inputs_ids_domains_exact = declarations_exact and old.recipe.facadeApertures.size() == current.recipe.facadeApertures.size()
	checks.inputs_unchanged = FileAccess.get_sha256(OLD) == OLD_SHA and FileAccess.get_sha256(NEW) == NEW_SHA
	var report := {"passed": checks.values().all(func(value): return value == true), "checks": checks, "changedPartCount": changes.size(), "unexpectedGeometry": unexpected, "maximumCoordinateOrSizeDelta": max_delta,
		"scope": "Exact before/after captured producer geometry and declarations; sourceBinding seals may change. Not a complete metadata parity or physical/rendering acceptance claim."}
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(JSON.stringify(report, "  ", true, true)); file.flush()
	var saved := file.get_error() == OK; file.close(); quit(0 if saved and report.passed else 1)
func _read(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	var result: Dictionary = file.get_var(false); file.close(); return result
