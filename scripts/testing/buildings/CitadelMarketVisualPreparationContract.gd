extends SceneTree

## Headless static preparation only. Never instantiates or launches the scene.
const Visual = preload("res://scripts/testing/buildings/CitadelMarketRecipeVisual.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := OS.get_environment("VOXEL_MARKET_PREPARATION_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path):
		quit(2)
		return
	var fixture_script: Script = Visual
	if not fixture_script.has_method("_prepare_frozen_recipe"):
		quit(2)
		return
	var result: Dictionary = Visual._prepare_frozen_recipe(OS.get_environment("VOXEL_ROOF_INTEGRATION_BASELINE"), true)
	if result.has("blueprint"):
		result["partCount"] = result.blueprint.parts.size()
		result.erase("blueprint")
	if result.has("furnishingPlan"):
		result["preparedFurnishingCount"] = result.furnishingPlan.parts.size()
		result.erase("furnishingPlan")
	result["evidenceLevel"] = "headless_static_visual_preparation_contract"
	result["doesNotProve"] = "No scene instance, background-thread lifecycle, image, live collision, gameplay, or final physical acceptance. Executes the exact proposed fixture preparation on the main thread only."
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_json(result), "\t"))
	file.close()
	quit(0 if result.get("ready", false) else 1)

func _json(value: Variant) -> Variant:
	if value is Transform3D:
		return {"origin": _json(value.origin), "basis": [_json(value.basis.x), _json(value.basis.y), _json(value.basis.z)]}
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Vector2:
		return [value.x, value.y]
	if value is Rect2 or value is AABB:
		return {"position": _json(value.position), "size": _json(value.size)}
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value:
			result[key] = _json(value[key])
		return result
	if value is Array:
		return value.map(func(item): return _json(item))
	return value
