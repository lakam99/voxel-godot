extends SceneTree

# Exact worker comparison is intentionally limited to impostors. Those tiers
# skip the oak grammar and publish an identity with zero topology, so the native
# precursor can compare them without claiming the missing branch/foliage port.
const Service = preload("res://scripts/environment/TreeSpawnService.gd")

func _initialize() -> void:
	var service = Service.new()
	for case_index in range(7):
		var request := base_request()
		if case_index == 1:
			request.presentation = "review"
		elif case_index == 2:
			request.erase("architecture")
			request.erase("canopyDensity")
			request.biomeParameters.architecture = "  BROADLEAF  "
			request.biomeParameters.canopyDensity = 0.88
		elif case_index == 3:
			request.architecture = "   "
			request.erase("canopyDensity")
			request.biomeParameters.architecture = "conifer"
			request.biomeParameters.canopyDensity = -1.0
		elif case_index == 4:
			request.architecture = "broadlé"
			request.erase("canopyDensity")
			request.biomeParameters.canopyDensity = 4.0
		elif case_index == 5:
			request.architecture = "conifer"
		elif case_index == 6:
			request.architecture = "savanna"
		var normalized: Dictionary = service.normalize_request(request)
		var recipe: Dictionary = service.build_recipe_for_worker(request)
		var policy: Dictionary = service.render_policy(normalized)
		var collision: Dictionary = recipe.get("collision", {})
		var interaction: Dictionary = recipe.get("interactionFacts", {})
		var row := {
			"caseIndex": case_index,
			"recipeIdentityKey": service.recipe_identity_key(request),
			"requestKey": service.recipe_cache_key(request),
			"signature": String(recipe.get("signature", "")),
			"topologySignature": String(recipe.get("topologySignature", "")),
			"sourceBranches": int(recipe.get("sourceBranchCount", 0)),
			"sourceFoliage": int(recipe.get("sourceFoliageClusterCount", 0)),
			"branches": (recipe.get("branches", []) as Array).size(),
			"foliage": (recipe.get("foliage", []) as Array).size(),
			"branchSelectionHash": 0,
			"foliageSelectionHash": 0,
			"normalized": {
				"treeId": normalized.treeId,
				"worldSeed": normalized.worldSeed,
				"biome": normalized.biome,
				"architecture": normalized.architecture,
				"speciesGrammar": normalized.speciesGrammar,
				"ageBand": normalized.ageBand,
				"ageYears": normalized.ageYears,
				"growthStage": normalized.maturity,
				"geneticSeed": normalized.geneticSeed,
				"height": normalized.visualHeight,
				"trunkRadius": normalized.trunkRadius,
				"canopyRadius": normalized.canopyRadius,
				"canopyDensity": normalized.canopyDensity
			},
			"renderTier": normalized.renderLodTier,
			"branchBudget": 0,
			"foliageBudget": 0,
			"review": normalized.presentation == "review",
			"impostor": bool(recipe.get("runtimeImpostor", false)),
			"renderPolicy": policy,
			"runtimeContinuousBole": bool(recipe.get("runtimeContinuousBole", false)),
			"pocContinuousWood": bool(recipe.get("pocContinuousWood", false)),
			"continuousTrunkPath": false,
			"graphConnected": false,
			"foliageDerivedFromFineSegments": false,
			"collisionRadius": float(collision.get("trunkRadius", 0.0)),
			"collisionHeight": float(collision.get("trunkHeight", 0.0)),
			"interaction": {
				"treeId": String(interaction.get("treeId", "")),
				"worldPosition": vector_json(interaction.get("worldPosition", Vector3.ZERO)),
				"worldRotationY": float(interaction.get("worldRotationY", 0.0)),
				"rootButtressCount": (interaction.get("rootButtresses", []) as Array).size()
			},
			"crownHabit": String(recipe.get("crownHabit", "")),
			"methodology": String(recipe.get("methodology", "")),
			"firstBranch": {},
			"firstFoliage": {}
		}
		print("VWB_BUSHY_OAK_SHADOW_WORKER_ORACLE:", JSON.stringify(row))
	quit()

func base_request() -> Dictionary:
	return {
		"treeId": "oracle-oak", "worldSeed": "oracle-world", "biome": "forest",
		"architecture": "broadleaf", "speciesGrammar": "bushy_oak",
		"geneticSeed": 0x4f414b42, "growthStage": 0.92,
		"visualHeight": 26.0, "trunkRadius": 1.1, "canopyRadius": 8.0,
		"canopyDensity": 0.78, "ageBand": "mature", "ageYears": 55.0,
		"renderLodTier": "impostor", "presentation": "runtime",
		"worldPosition": Vector3(4.0, 5.0, 6.0), "worldRotationY": 0.5,
		"biomeParameters": {"version": 2, "architecture": "broadleaf",
			"heightMin": 10.0, "heightMax": 43.0, "trunkRadiusMin": 0.5,
			"trunkRadiusMax": 3.1, "canopyRadiusMin": 9.0, "canopyRadiusMax": 29.0,
			"canopyDensity": 0.88, "windResponse": 1.25,
			"visibilityRange": 350.0, "shadowRange": 170.0, "exclusionMargin": 0.4}
	}

func vector_json(value: Variant) -> Array:
	var vector: Vector3 = value as Vector3
	return [vector.x, vector.y, vector.z]
