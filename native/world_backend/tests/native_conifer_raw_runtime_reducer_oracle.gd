extends SceneTree

# Independent direct-service oracle for the exact raw reduction boundary.
const Service = preload("res://scripts/environment/TreeSpawnService.gd")
const Grammar = preload("res://scripts/environment/tree_grammars/MathematicalTreePocConiferRecipeBuilder.gd")

func _initialize() -> void:
	var service = Service.new()
	for case in [
		[0x4D415448, 0.92, 0.78, "near"],
		[0x4D415448, 0.92, 0.20, "mid"],
		[0x4D415448, 0.92, 1.00, "far"],
		[-319, 0.12, 0.65, "near"],
		[-319, 1.00, 0.90, "mid"],
		[-319, 0.12, -0.25, "near"],
		[0x4D415448, 0.92, 0.10, "mid"],
		[0x4D415448, 0.92, 2.00, "far"]
	]:
		var raw: Dictionary = Grammar.new().build_recipe(case[0], case[1])
		var request := {"canopyDensity": case[2], "renderLodTier": case[3]}
		var reduced: Dictionary = service.reduce_raw_runtime_recipe(raw, request)
		var branches: Array = reduced.get("branches", [])
		var foliage: Array = reduced.get("foliage", [])
		var branch_parts: Array[String] = []
		for branch in branches:
			branch_parts.append(str(int(branch.get("childNode", -1))))
		var foliage_parts: Array[String] = []
		for anchor in foliage:
			foliage_parts.append("%d:%d" % [int(anchor.get("sourceSegment", -1)), int(anchor.get("clusterVariant", -1))])
		print("VWB_CONIFER_REDUCTION_ORACLE:", JSON.stringify({
			"seed": case[0], "maturity": case[1], "density": case[2], "lod": case[3],
			"branchBudget": int(service.runtime_render_budgets(request).get("branchBudget", -1)),
			"foliageBudget": int(service.runtime_render_budgets(request).get("foliageBudget", -1)),
			"sourceBranches": int(reduced.get("sourceBranchCount", -1)),
			"sourceFoliage": int(reduced.get("sourceFoliageClusterCount", -1)),
			"branches": branches.size(), "foliage": foliage.size(),
			"branchSelectionHash": service.stable_hash(",".join(branch_parts)),
			"foliageSelectionHash": service.stable_hash(",".join(foliage_parts))
		}))
	quit()
