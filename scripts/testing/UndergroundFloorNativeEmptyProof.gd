extends SceneTree

const MainScript := preload("res://scripts/Main.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main = MainScript.new()
	main.apply_world_seed("atlas-85218211", false)
	var world = main.get("world_generation_system") as Object
	var volume = world.get("terrain_volume_service") as Object if is_instance_valid(world) else null
	var selected := Vector2i(999, 999)
	if is_instance_valid(volume):
		for key in [Vector2i.ZERO, Vector2i(2, 2), Vector2i(-2, 2),
				Vector2i(3, -2), Vector2i(-3, -2)]:
			if bool(volume.call("generated_underground_floor_source_proven_empty", key, 28)):
				selected = key
				break
	var old_cells: Array = []
	var fast: Dictionary = {}
	if selected != Vector2i(999, 999):
		old_cells = volume.call("exposed_underground_floor_cells", selected, 28, 36, 0)
		var state: Dictionary = volume.call("begin_exposed_underground_floor_scan", selected, 28)
		fast = volume.call("advance_exposed_underground_floor_scan", state, 8, 1.35)
	var passed := selected != Vector2i(999, 999) and old_cells.is_empty() \
		and bool(fast.get("complete", false)) \
		and (fast.get("newCandidates", []) as Array).is_empty() \
		and String(fast.get("emptyProof", "")) == "no_cave_recipe_or_local_edits"
	print(JSON.stringify({"schema": "underground-floor-native-empty-proof/v1",
		"evidenceLevel": "direct_production_service_differential", "passed": passed,
		"seed": "atlas-85218211", "chunk": [selected.x, selected.y],
		"oldCandidateCount": old_cells.size(), "fastProof": fast.get("emptyProof", "")}))
	main.free()
	quit(0 if passed else 1)
