extends SceneTree

const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var path := OS.get_environment("VOXEL_CITADEL_NATURAL_GROUND_REPORT").strip_edges().simplify_path()
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var seed := 237207443
	var source = Castle.build(seed, {"biome": "forest", "citadelScale": 1.25, "siteKey": "river-citadel"})
	var result: Dictionary = Urban.compose_prepared(source, seed)
	var blueprint = result.get("blueprint")
	var forbidden: Array = []
	if blueprint != null:
		forbidden = blueprint.parts.filter(func(part):
			var id := String(part.id)
			return id.begins_with("castle_terrace_block_") or id.begins_with("castle_terrace_stair_") \
				or id.begins_with("urban_street_climb_") or id.begins_with("urban_market_plaza_retaining") \
				or String(part.semantic) in ["castle_inhabited_terrace_block", "castle_terrace_route_wall", "castle_processional_step", "citadel_urban_terrace", "citadel_urban_stair"])
	var passed := bool(result.get("ready", false)) and blueprint != null and forbidden.is_empty()
	var report := {
		"passed": passed,
		"seed": seed,
		"ready": result.get("ready", false),
		"reason": result.get("reason", ""),
		"failure": result.get("civicClearanceFailure", result.get("shopFailure", result.get("terminalFoundationFailure", {}))),
		"forbiddenPartIds": forbidden.map(func(part): return String(part.id)),
		"partCount": blueprint.parts.size() if blueprint != null else 0,
		"evidenceLevel": "full_source_composition_contract",
		"doesNotProve": "No publication, rendered appearance, terrain conformity, routing, navigation or gameplay acceptance."
	}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_json(report), "\t"))
	file.close()
	quit(0 if passed else 1)


static func _json(value: Variant) -> Variant:
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Vector2:
		return [value.x, value.y]
	if value is AABB or value is Rect2:
		return {"position": _json(value.position), "size": _json(value.size)}
	if value is float and not is_finite(value):
		return str(value)
	if value is Object:
		return str(value)
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value:
			result[key] = _json(value[key])
		return result
	if value is Array:
		return value.map(func(item): return _json(item))
	return value
