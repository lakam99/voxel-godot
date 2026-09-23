extends SceneTree

# Direct, independent active GDScript grammar fixture. Never calls the C++ port.
const Grammar = preload("res://scripts/environment/tree_grammars/MathematicalTreePocConiferRecipeBuilder.gd")

func _initialize() -> void:
	print("VWB_ROUNDI_ORACLE:", JSON.stringify([roundi(-1.5), roundi(-0.5), roundi(0.5), roundi(1.5)]))
	for input in [[0x4D415448, 0.92], [-319, 0.12], [320, 0.12], [-319, 1.0]]:
		var recipe: Dictionary = Grammar.new().build_recipe(input[0], input[1])
		var stats: Dictionary = recipe.get("stats", {})
		var branches: Array = recipe.get("branches", [])
		var foliage: Array = recipe.get("foliage", [])
		var first_branch: Dictionary = branches.front() if not branches.is_empty() else {}
		var first_anchor: Dictionary = foliage.front() if not foliage.is_empty() else {}
		var hash_value := Grammar.new().stable_hash("math-tree-v%d:%d:%d:%d:%d" % [2, input[0], roundi(float(input[1]) * 100000.0), roundi(float(recipe.get("height", 0.0)) * 1000.0), branches.size()])
		var hash_checkpoints := []
		for branch_index in range(branches.size()):
			var b: Dictionary = branches[branch_index]
			var start: Vector3 = b.get("start", Vector3.ZERO)
			var end: Vector3 = b.get("end", Vector3.ZERO)
			hash_value = Grammar.new().stable_hash("%d:%d,%d,%d:%d,%d,%d:%d:%d:%d" % [hash_value, roundi(start.x * 1000.0), roundi(start.y * 1000.0), roundi(start.z * 1000.0), roundi(end.x * 1000.0), roundi(end.y * 1000.0), roundi(end.z * 1000.0), roundi(float(b.get("radiusStart", 0.0)) * 1000.0), roundi(float(b.get("radiusEnd", 0.0)) * 1000.0), int(b.get("order", 0))])
			if branch_index < 5 or branch_index % 25 == 24 or branch_index == branches.size() - 1:
				hash_checkpoints.append([branch_index, hash_value])
		var foliage_hash_checkpoints := []
		for foliage_index in range(foliage.size()):
			var f: Dictionary = foliage[foliage_index]
			var position: Vector3 = f.get("position", Vector3.ZERO)
			hash_value = Grammar.new().stable_hash("%d:%d,%d,%d:%d" % [hash_value, roundi(position.x * 1000.0), roundi(position.y * 1000.0), roundi(position.z * 1000.0), int(f.get("sourceOrder", 0))])
			if foliage_index < 5 or foliage_index % 25 == 24 or foliage_index == foliage.size() - 1 or (foliage_index >= 275 and foliage_index <= 299):
				foliage_hash_checkpoints.append([foliage_index, hash_value, roundi(position.x * 1000.0), roundi(position.y * 1000.0), roundi(position.z * 1000.0)])
		print("VWB_CONIFER_ORACLE:", JSON.stringify({
			"seed": input[0], "maturity": input[1],
			"signature": recipe.get("signature", ""),
			"height": recipe.get("height", 0.0),
			"trunkRadius": recipe.get("trunkRadius", 0.0),
			"canopyRadius": recipe.get("canopyRadius", 0.0),
			"branchCount": branches.size(), "foliageCount": foliage.size(),
			"nodeCount": stats.get("nodeCount", 0),
			"segmentCountsByOrder": stats.get("segmentCountsByOrder", {}),
			"coniferWhorlCount": stats.get("coniferWhorlCount", 0),
			"interstitialSprayCount": stats.get("interstitialSprayCount", 0),
			"supportDrivenBranchletCount": stats.get("supportDrivenBranchletCount", 0),
			"crownOccupancy": stats.get("crownOccupancy", {}),
			"firstBranch": first_branch,
			"firstFoliage": first_anchor
			,"branchHashCheckpoints": hash_checkpoints, "foliageHashCheckpoints": foliage_hash_checkpoints
		}))
	quit()
