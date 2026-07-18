extends SceneTree

const TreeSpawnServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")

func _initialize() -> void:
	call_deferred("run_contract")

func run_contract() -> void:
	var tree_service = TreeSpawnServiceScript.new()
	var signatures := {}
	var grammars := {}
	var branch_counts := {}
	var foliage_counts := {}
	var structural_fingerprints := {}
	var recipes: Array[Dictionary] = []
	for index in range(12):
		var spec := {
			"treeId": "variety-contract:%d" % index,
			"worldSeed": "variety-contract-seed",
			"biome": "forest",
			"architecture": "broadleaf",
			"speciesGrammar": "bushy_oak",
			"ageBand": "old",
			"ageYears": 240.0,
			"growthStage": 0.78,
			"geneticSeed": 18731 + index * 7919,
			"visualHeight": 68.0,
			"trunkRadius": 5.2,
			"canopyRadius": 28.0,
			"canopyDensity": 0.82
		}
		var recipe: Dictionary = tree_service.build_recipe(spec)
		recipes.append(recipe)
		signatures[String(recipe.get("signature", ""))] = true
		grammars[String(recipe.get("speciesGrammar", ""))] = true
		branch_counts[int(recipe.get("branchCount", 0))] = true
		foliage_counts[int(recipe.get("foliageClusterCount", 0))] = true
		structural_fingerprints[structural_fingerprint(recipe)] = true
	var repeat_spec := {
		"treeId": "variety-contract:0",
		"worldSeed": "variety-contract-seed",
		"biome": "forest",
		"architecture": "broadleaf",
		"speciesGrammar": "bushy_oak",
		"ageBand": "old",
		"ageYears": 240.0,
		"growthStage": 0.78,
		"geneticSeed": 18731,
		"visualHeight": 68.0,
		"trunkRadius": 5.2,
		"canopyRadius": 28.0,
		"canopyDensity": 0.82
	}
	var repeated: Dictionary = tree_service.build_recipe(repeat_spec)
	var deterministic := not recipes.is_empty() and String(recipes[0].get("signature", "")) == String(repeated.get("signature", ""))
	var bounded := true
	for recipe in recipes:
		bounded = bounded \
			and int(recipe.get("branchCount", 0)) > 0 \
			and int(recipe.get("branchCount", 0)) <= 520 \
			and int(recipe.get("foliageClusterCount", 0)) > 0 \
			and int(recipe.get("foliageClusterCount", 0)) <= 620
	var passed := signatures.size() == 12 \
		# Every specimen uses the one production oak grammar.  Diversity must come
		# from deterministic genetic/ecological inputs, never a retired parallel
		# broadleaf implementation or authored template alternation.
		and grammars.size() == 1 and grammars.has("bushy_oak") \
		# Runtime keeps an explicit upper render budget, so branch/foliage totals
		# are intentionally allowed to converge. Verify the actual generated
		# support graph instead of mistaking a shared budget for authored clones.
		and structural_fingerprints.size() == 12 \
		and deterministic \
		and bounded
	print(JSON.stringify({
		"runnerId": "procedural_tree_recipe_contract",
		"evidenceLevel": "contract",
		"passed": passed,
		"treeCount": recipes.size(),
		"uniqueSignatures": signatures.size(),
		"grammars": grammars.keys(),
		"uniqueBranchCounts": branch_counts.keys(),
		"uniqueFoliageCounts": foliage_counts.keys(),
		"uniqueStructuralFingerprints": structural_fingerprints.size(),
		"deterministicRepeat": deterministic,
		"bounded": bounded
	}))
	quit(0 if passed else 1)

func structural_fingerprint(recipe: Dictionary) -> String:
	var branches: Array = recipe.get("branches", [])
	if branches.is_empty():
		return "empty"
	var sample_indices := [0, branches.size() / 5, branches.size() * 2 / 5, branches.size() * 3 / 5, branches.size() * 4 / 5, branches.size() - 1]
	var parts: Array[String] = []
	for raw_index in sample_indices:
		var branch: Dictionary = branches[clampi(int(raw_index), 0, branches.size() - 1)] as Dictionary
		var start: Vector3 = branch.get("start", Vector3.ZERO)
		var end: Vector3 = branch.get("end", Vector3.ZERO)
		parts.append("%d:%d:%d:%d:%d:%d:%d:%d" % [
			int(branch.get("order", -1)), int(branch.get("parentNode", -1)), int(branch.get("childNode", -1)),
			roundi(start.x * 10.0), roundi(start.y * 10.0), roundi(start.z * 10.0),
			roundi(end.x * 10.0), roundi(end.z * 10.0)
		])
	return "|".join(parts)
