extends SceneTree

# Independent direct TreeSpawnService worker recipe, no C++ calls.
const Service = preload("res://scripts/environment/TreeSpawnService.gd")

func _initialize() -> void:
	var service = Service.new()
	var base := {
		"treeId": "oracle-tree", "worldSeed": "oracle-world", "biome": "taiga",
		"architecture": "conifer", "speciesGrammar": "norway_spruce",
		"geneticSeed": 0x4D415448, "growthStage": 0.92,
		"visualHeight": 26.0, "trunkRadius": 1.1, "canopyRadius": 8.0,
		"canopyDensity": 0.78, "ageBand": "mature", "ageYears": 55.0,
		"renderLodTier": "near", "presentation": "runtime",
		"worldPosition": Vector3(4.0, 5.0, 6.0), "worldRotationY": 0.5,
		"biomeParameters": {"version": 2, "architecture": "conifer", "heightMin": 18.0, "heightMax": 60.0,
			"trunkRadiusMin": 0.5, "trunkRadiusMax": 3.0, "canopyRadiusMin": 4.0, "canopyRadiusMax": 18.0,
			"canopyDensity": 0.88, "windResponse": 1.25, "visibilityRange": 350.0,
			"shadowRange": 170.0, "exclusionMargin": 0.4}
	}
	for variation in [
		{},
		{"speciesGrammar": ""},
		{"geneticSeed": -319, "growthStage": 0.12, "canopyDensity": 0.20, "renderLodTier": "mid"},
		{"geneticSeed": -319, "growthStage": 1.0, "canopyDensity": 1.0, "renderLodTier": "far"},
		{"presentation": "review"},
		{"renderLodTier": "impostor"},
		{"presentation": "review", "renderLodTier": "impostor"},
		{"geneticSeed": 0, "treeId": " fallback-tree ", "worldSeed": "café", "visualHeight": 2.0,
			"trunkRadius": 0.0, "canopyRadius": 0.0, "canopyDensity": 0.05, "renderLodTier": " MID "}
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
		var first_branch_end: Vector3 = first_branch.get("end", Vector3.ZERO)
		var first_foliage_position: Vector3 = first_foliage.get("position", Vector3.ZERO)
		var first_foliage_scale: Vector3 = first_foliage.get("scale", Vector3.ZERO)
		var collision: Dictionary = recipe.get("collision", {})
		var render_lod: Dictionary = recipe.get("renderLod", {})
		var interaction: Dictionary = recipe.get("interactionFacts", {})
		var policy: Dictionary = recipe.get("renderPolicy", {})
		print("VWB_CONIFER_WORKER_ORACLE:", JSON.stringify({
			"case": variation, "version": recipe.get("version", -1),
			"treeId": recipe.get("treeId", ""), "biome": recipe.get("biome", ""),
			"geneticSeed": recipe.get("geneticSeed", 0), "growthStage": recipe.get("growthStage", 0.0),
			"height": recipe.get("height", 0.0), "trunkRadius": recipe.get("trunkRadius", 0.0),
			"canopyRadius": recipe.get("canopyRadius", 0.0), "canopyDensity": recipe.get("canopyDensity", 0.0),
			"signature": recipe.get("signature", ""), "topologySignature": recipe.get("topologySignature", ""),
			"sourceBranches": recipe.get("sourceBranchCount", -1),
			"sourceFoliage": recipe.get("sourceFoliageClusterCount", -1),
			"branches": branches.size(), "foliage": foliage.size(),
			"branchSelectionHash": service.stable_hash(",".join(branch_parts)),
			"foliageSelectionHash": service.stable_hash(",".join(foliage_parts)),
			"renderLod": render_lod, "runtimeImpostor": recipe.get("runtimeImpostor", null),
			"collision": collision, "renderPolicy": policy,
			"interactionFacts": interaction,
			"firstBranch": first_branch, "firstFoliage": first_foliage,
			"firstBranchEnd": [first_branch_end.x, first_branch_end.y, first_branch_end.z],
			"firstFoliagePosition": [first_foliage_position.x, first_foliage_position.y, first_foliage_position.z],
			"firstFoliageScale": [first_foliage_scale.x, first_foliage_scale.y, first_foliage_scale.z]
		}))
	quit()
