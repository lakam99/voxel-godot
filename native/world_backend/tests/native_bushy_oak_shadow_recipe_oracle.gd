extends SceneTree

# Source-bound scalar projection of the live v21 grammar. The grammar is
# executed with a bounded profile, but topology is deliberately projected out:
# native broadleaf topology remains pending and this oracle must not imply it.
const Grammar = preload("res://scripts/environment/tree_grammars/MathematicalTreePocBushyOakRecipeBuilder.gd")
const Service = preload("res://scripts/environment/TreeSpawnService.gd")

func _initialize() -> void:
	var service = Service.new()
	for request in [
		{"seed": 0x4f414b42, "maturity": 0.92, "density": 0.78, "tier": "near"},
		{"seed": -319, "maturity": 0.12, "density": 0.20, "tier": "mid"},
		{"seed": -319, "maturity": 1.0, "density": 1.0, "tier": "far"}
	]:
		var seed := int(request.seed)
		var maturity := float(request.maturity)
		var normalized: Dictionary = service.normalize_request({
			"treeId": "scalar-oak", "worldSeed": "oracle-world", "biome": "forest",
			"architecture": "broadleaf", "speciesGrammar": "bushy_oak",
			"geneticSeed": seed, "growthStage": maturity, "canopyDensity": request.density,
			"renderLodTier": request.tier
		})
		var profile: Dictionary = service.runtime_growth_profile(normalized)
		var budgets: Dictionary = service.runtime_render_budgets(normalized)
		var raw: Dictionary = Grammar.new().build_recipe(seed, maturity, profile)
		var rng := RandomNumberGenerator.new()
		rng.seed = seed
		var row := {
			"seed": seed,
			"maturity": float(raw.get("maturity", 0.0)),
			"signature": "",
			"height": float(raw.get("height", 0.0)),
			"trunkRadius": float(raw.get("trunkRadius", 0.0)),
			"canopyRadius": float(raw.get("canopyRadius", 0.0)),
			"crownBase": float(raw.get("crownBase", 0.0)),
			"crownHeight": float(raw.get("crownHeight", 0.0)),
			"crownPhase": rng.randf() * TAU,
			"crownCenter": vector_json(raw.get("crownCenter", Vector3.ZERO)),
			"crownRadii": vector_json(raw.get("crownRadii", Vector3.ZERO)),
			"growthProfile": [
				int(profile.get("attractionPointCount", 0)),
				int(profile.get("branchSegmentBudget", 0)),
				int(profile.get("foliageClusterBudget", 0)),
				int(profile.get("spaceColonizationIterationBudget", 0)),
				int(profile.get("derivedAxisMaximumGrowthSeasons", 0))
			],
			"renderBudgets": [int(budgets.branchBudget), int(budgets.foliageBudget)],
			"branchCount": 0,
			"foliageCount": 0,
			"nodeCount": 0,
			"segmentCountsByOrder": [0, 0, 0, 0, 0],
			"raisedForkCount": 0,
			"crownWindowCount": 0,
			"viableAxisBudCount": 0,
			"germinatedAxisCount": 0,
			"grownMetamerCount": 0,
			"pipeModelJunctionCount": 0,
			"occupiedCrownBins": 0,
			"branchSelectionHash": 0,
			"foliageSelectionHash": 0,
			"branchHashCheckpoints": [],
			"foliageHashCheckpoints": []
		}
		print("VWB_BUSHY_OAK_SHADOW_ORACLE:", JSON.stringify(row))
	quit()

func vector_json(value: Variant) -> Array:
	var vector: Vector3 = value as Vector3
	return [vector.x, vector.y, vector.z]
