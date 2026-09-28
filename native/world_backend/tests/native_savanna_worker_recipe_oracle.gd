extends SceneTree

# Independent direct TreeSpawnService worker recipe fixture. Never calls C++.
const Service = preload("res://scripts/environment/TreeSpawnService.gd")

func vector_observation(value: Variant) -> Array:
	var vector: Vector3 = value as Vector3
	return [vector.x, vector.y, vector.z]

func branch_observation(value: Dictionary) -> Dictionary:
	if value.is_empty(): return {}
	return {
		"start": vector_observation(value.get("start", Vector3.ZERO)),
		"end": vector_observation(value.get("end", Vector3.ZERO)),
		"radiusStart": float(value.get("radiusStart", 0.0)),
		"radiusEnd": float(value.get("radiusEnd", 0.0)),
		"order": int(value.get("order", -1)),
		"parentNode": int(value.get("parentNode", -1)),
		"childNode": int(value.get("childNode", -1)),
		"stratumBias": float(value.get("stratumBias", 0.0)),
		"windWeight": float(value.get("windWeight", 0.0)),
	}

func foliage_observation(value: Dictionary) -> Dictionary:
	if value.is_empty(): return {}
	return {
		"position": vector_observation(value.get("position", Vector3.ZERO)),
		"rotation": vector_observation(value.get("rotation", Vector3.ZERO)),
		"scale": vector_observation(value.get("scale", Vector3.ZERO)),
		"windWeight": float(value.get("windWeight", 0.0)),
		"variation": float(value.get("variation", 0.0)),
		"exposure": float(value.get("exposure", 0.0)),
		"clusterVariant": int(value.get("clusterVariant", -1)),
		"sourceSegment": int(value.get("sourceSegment", -1)),
		"sourceOrder": int(value.get("sourceOrder", -1)),
	}

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
			"normalized": {
				"treeId": recipe.get("treeId", ""), "worldSeed": request.get("worldSeed", ""),
				"biome": recipe.get("biome", ""), "architecture": recipe.get("architecture", ""),
				"speciesGrammar": recipe.get("speciesGrammar", ""), "ageBand": recipe.get("ageBand", ""),
				"ageYears": recipe.get("ageYears", 0.0), "growthStage": recipe.get("growthStage", 0.0),
				"geneticSeed": recipe.get("geneticSeed", 0), "height": recipe.get("height", 0.0),
				"trunkRadius": recipe.get("trunkRadius", 0.0), "canopyRadius": recipe.get("canopyRadius", 0.0),
				"canopyDensity": recipe.get("canopyDensity", 0.0),
			},
			"renderLod": recipe.get("renderLod", {}), "renderPolicy": recipe.get("renderPolicy", {}),
			"runtimeImpostor": recipe.get("runtimeImpostor", null),
			"runtimeContinuousBole": recipe.get("runtimeContinuousBole", false),
			"pocContinuousWood": recipe.get("pocContinuousWood", false),
			"continuousTrunkPath": recipe.get("continuousTrunkPath", (recipe.get("stats", {}) as Dictionary).get("continuousTrunkPath", false)),
			"graphConnected": recipe.get("graphConnected", (recipe.get("stats", {}) as Dictionary).get("connected", false)),
			"foliageDerivedFromFineSegments": recipe.get("foliageDerivedFromFineSegments", (recipe.get("stats", {}) as Dictionary).get("foliageDerivedFromFineSegments", false)),
			"collision": recipe.get("collision", {}), "crownHabit": recipe.get("crownHabit", ""),
			"interaction": {
				"treeId": (recipe.get("interactionFacts", {}) as Dictionary).get("treeId", ""),
				"worldPosition": vector_observation((recipe.get("interactionFacts", {}) as Dictionary).get("worldPosition", Vector3.ZERO)),
				"worldRotationY": (recipe.get("interactionFacts", {}) as Dictionary).get("worldRotationY", 0.0),
				"rootButtressCount": ((recipe.get("interactionFacts", {}) as Dictionary).get("rootButtresses", []) as Array).size(),
			},
			"methodology": recipe.get("methodology", ""), "firstBranch": branch_observation(first_branch),
			"firstFoliage": foliage_observation(first_foliage), "stats": recipe.get("stats", {})
		}))
	quit()
