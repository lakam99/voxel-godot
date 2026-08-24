extends SceneTree

const CastleCompoundBlueprintBuilderScript := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")


func _init() -> void:
	var start_seed := int(OS.get_environment("VOXEL_CITADEL_BALCONY_SEED_START"))
	if start_seed == 0:
		start_seed = 208150
	var end_seed := int(OS.get_environment("VOXEL_CITADEL_BALCONY_SEED_END"))
	if end_seed == 0:
		end_seed = start_seed + 31
	var matches: Array[Dictionary] = []
	for seed in range(start_seed, end_seed + 1):
		var blueprint = CastleCompoundBlueprintBuilderScript.build(seed, {
			"biome": "forest",
			"siteKey": "river-citadel",
			"citadelScale": 1.25
		})
		var balconies: Array[String] = []
		for part in blueprint.parts:
			if part != null and String(part.semantic) == "castle_residence_balcony":
				balconies.append(String(part.id))
		if not balconies.is_empty():
			matches.append({"seed": seed, "balconyPartIds": balconies})
	print(JSON.stringify({"runnerId": "citadel_balcony_seed_finder", "startSeed": start_seed, "endSeed": end_seed, "matches": matches}))
	quit(0 if not matches.is_empty() else 1)
