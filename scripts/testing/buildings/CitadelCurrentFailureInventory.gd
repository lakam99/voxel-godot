extends SceneTree

## Read-only source inventory for a bound candidate archive. This reports
## current recipe ownership and physical checks; it does not propose repairs.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const MAX_BYTES := 128 * 1024 * 1024

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var input := OS.get_environment("VOXEL_CITADEL_INVENTORY_INPUT").simplify_path()
	var expected_sha := OS.get_environment("VOXEL_CITADEL_INVENTORY_SHA").to_lower()
	var output := OS.get_environment("VOXEL_CITADEL_INVENTORY_REPORT").simplify_path()
	if not input.is_absolute_path() or not output.is_absolute_path() or expected_sha.length() != 64 \
		or not FileAccess.file_exists(input) or FileAccess.get_sha256(input) != expected_sha \
		or FileAccess.file_exists(output):
		quit(2); return
	var file := FileAccess.open(input, FileAccess.READ)
	if file == null or file.get_length() <= 0 or file.get_length() > MAX_BYTES:
		quit(2); return
	var bytes := file.get_buffer(file.get_length())
	file.close()
	var raw: Variant = bytes_to_var(bytes)
	if not raw is Dictionary or var_to_bytes(raw) != bytes or not raw.get("afterSnapshot") is Dictionary:
		quit(2); return
	var source = Copy.copy_blueprint(raw.afterSnapshot)
	Copy.clear_caches(source)
	var grid := Copy.validation_grid_work(source)
	if not grid.ready:
		quit(2); return
	var physical: Dictionary = source.validate_physical_integrity()
	var declarations: Variant = source.recipe.get("facadeApertures", {})
	var declaration_by_part := {}
	if declarations is Dictionary:
		var keys: Array = declarations.keys()
		keys.sort()
		for key: String in keys:
			var declaration: Variant = declarations[key]
			if declaration is Dictionary and declaration.get("partIds") is Array:
				for id: Variant in declaration.partIds:
					if id is String: declaration_by_part[id] = key
	var rows: Array = []
	for check: Variant in physical.get("checks", []):
		if not check is Dictionary or check.get("passed") != false: continue
		var id: String = String(check.get("partId", ""))
		var part = source.find_part(id)
		rows.append({
			"id": id,
			"kind": part.kind if part != null else "",
			"semantic": part.semantic if part != null else "",
			"physicalIntent": part.physical_intent if part != null else "",
			"declarationKey": declaration_by_part.get(id, ""),
			"requiredSeatIds": part.recipe.get("physicalRequiredSeatPartIds", []) if part != null else [],
			"requiredAnchorIds": part.recipe.get("physicalRequiredAnchorPartIds", []) if part != null else [],
			"assemblyRole": part.recipe.get("physicalAssemblyRole", "") if part != null else "",
			"check": check
		})
	rows.sort_custom(func(a, b): return a.id < b.id)
	var groups := {}
	for row: Dictionary in rows:
		var key := "%s|%s" % [row.semantic, row.kind]
		groups[key] = int(groups.get(key, 0)) + 1
	var report := {"passed": rows.size() == physical.get("violations", []).size(),
		"inputSha256": expected_sha, "failureCount": rows.size(), "groups": groups,
		"failures": rows, "violations": physical.get("violations", []),
		"scope": "Bound source-only physical failure inventory; no repair, publication, rendering or gameplay claim."}
	var target := FileAccess.open(output, FileAccess.WRITE)
	if target == null:
		quit(2); return
	target.store_string(JSON.stringify(_json(report), "\t"))
	target.close()
	quit(0 if report.passed else 1)

func _json(value: Variant) -> Variant:
	if value is Vector2: return {"x": value.x, "y": value.y}
	if value is Vector3: return {"x": value.x, "y": value.y, "z": value.z}
	if value is AABB: return {"position": _json(value.position), "size": _json(value.size)}
	if value is Dictionary:
		var result := {}
		for key: Variant in value: result[String(key)] = _json(value[key])
		return result
	if value is Array: return value.map(func(item): return _json(item))
	return value
