extends SceneTree

# Independent direct TreeSpawnService worker recipe fixture. Never calls C++.
const Service = preload("res://scripts/environment/TreeSpawnService.gd")

func _initialize() -> void:
	var service = Service.new()
	var base := {
		"treeId": "oracle-tree", "worldSeed": "oracle-world", "biome": "savanna",
		"architecture": "savanna", "speciesGrammar": "umbrella_thorn",
		"geneticSeed": 0x53415641, "growthStage": 0.92,
		"visualHeight": 26.0, "trunkRadius": 1.1, "canopyRadius": 8.0,
		"canopyDensity": 0.78, "ageBand": "mature", "ageYears": 55.0,
		"renderLodTier": "near", "presentation": "runtime",
		"worldPosition": Vector3(4.0, 5.0, 6.0), "worldRotationY": 0.5,
		"biomeParameters": {"version": 2, "architecture": "savanna", "heightMin": 10.0,
			"heightMax": 30.0, "trunkRadiusMin": 0.5, "trunkRadiusMax": 3.0,
			"canopyRadiusMin": 7.0, "canopyRadiusMax": 24.0, "canopyDensity": 0.88,
			"windResponse": 1.25, "visibilityRange": 350.0, "shadowRange": 170.0,
			"exclusionMargin": 0.4}
	}
	for variation in [
		{},
		{"speciesGrammar": ""},
		{"geneticSeed": -319, "growthStage": 0.12, "canopyDensity": 0.20, "renderLodTier": "mid"},
		{"geneticSeed": -319, "growthStage": 1.0, "canopyDensity": 1.0, "renderLodTier": "far"},
		{"presentation": "review"},
		{"renderLodTier": "impostor"},
		{"presentation": "review", "renderLodTier": "impostor"}
	]:
		var request: Dictionary = base.duplicate(true)
		request.merge(variation, true)
		var recipe: Dictionary = service.build_recipe_for_worker(request)
		var branches: Array = recipe.get("branches", [])
		var foliage: Array = recipe.get("foliage", [])
		var branch_parts: Array[String] = []
		for branch in branches: branch_parts.append(str(int(branch.get("childNode", -1))))
		var foliage_parts: Array[String] = []
		for anchor in foliage: foliage_parts.append("%d:%d" % [int(anchor.get("sourceSegment", -1)), int(anchor.get("clusterVariant", -1))])
		var first_branch: Dictionary = branches.front() if not branches.is_empty() else {}
		var first_foliage: Dictionary = foliage.front() if not foliage.is_empty() else {}
		print("VWB_SAVANNA_WORKER_ORACLE:", JSON.stringify({
			"case": variation, "signature": recipe.get("signature", ""),
			"topologySignature": recipe.get("topologySignature", ""),
			"sourceBranches": recipe.get("sourceBranchCount", -1),
			"sourceFoliage": recipe.get("sourceFoliageClusterCount", -1),
			"branches": branches.size(), "foliage": foliage.size(),
			"branchSelectionHash": service.stable_hash(",".join(branch_parts)),
			"foliageSelectionHash": service.stable_hash(",".join(foliage_parts)),
			"renderLod": recipe.get("renderLod", {}), "runtimeImpostor": recipe.get("runtimeImpostor", null),
			"collision": recipe.get("collision", {}), "crownHabit": recipe.get("crownHabit", ""),
			"methodology": recipe.get("methodology", ""), "firstBranch": first_branch,
			"firstFoliage": first_foliage, "stats": recipe.get("stats", {})
		}))
	quit()
