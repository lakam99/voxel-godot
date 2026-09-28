extends SceneTree

# Direct, independent active GDScript grammar fixture. Never calls the C++ port.
const Grammar = preload("res://scripts/environment/tree_grammars/MathematicalTreePocSavannaRecipeBuilder.gd")

func _initialize() -> void:
	for input in [[0x53415641, 0.92], [-319, 0.12], [320, 0.12], [-319, 1.0]]:
		var grammar = Grammar.new()
		var recipe: Dictionary = grammar.build_recipe(input[0], input[1])
		var stats: Dictionary = recipe.get("stats", {})
		var branches: Array = recipe.get("branches", [])
		var foliage: Array = recipe.get("foliage", [])
		var branch_parts: Array[String] = []
		for branch in branches:
			var b: Dictionary = branch
			var start: Vector3 = b.get("start", Vector3.ZERO)
			var end: Vector3 = b.get("end", Vector3.ZERO)
			branch_parts.append("%d:%d,%d,%d:%d,%d,%d:%d:%d:%d" % [
				int(b.get("childNode", -1)), roundi(start.x * 1000.0), roundi(start.y * 1000.0),
				roundi(start.z * 1000.0), roundi(end.x * 1000.0), roundi(end.y * 1000.0),
				roundi(end.z * 1000.0), roundi(float(b.get("radiusStart", 0.0)) * 1000.0),
				roundi(float(b.get("radiusEnd", 0.0)) * 1000.0), int(b.get("order", 0))])
		var foliage_parts: Array[String] = []
		for anchor in foliage:
			var f: Dictionary = anchor
			var position: Vector3 = f.get("position", Vector3.ZERO)
			foliage_parts.append("%d:%d:%d,%d,%d:%d" % [int(f.get("sourceSegment", -1)),
				int(f.get("clusterVariant", -1)), roundi(position.x * 1000.0),
				roundi(position.y * 1000.0), roundi(position.z * 1000.0), int(f.get("sourceOrder", 0))])
		var first_branch: Dictionary = branches.front() if not branches.is_empty() else {}
		var first_foliage: Dictionary = foliage.front() if not foliage.is_empty() else {}
		var cumulative := grammar.stable_hash("math-tree-v%d:%d:%d:%d:%d" % [2, input[0],
			roundi(float(input[1]) * 100000.0), roundi(float(recipe.get("height", 0.0)) * 1000.0), branches.size()])
		var branch_checkpoints := []
		for branch_index in range(branches.size()):
			var b: Dictionary = branches[branch_index]
			var start: Vector3 = b.get("start", Vector3.ZERO)
			var end: Vector3 = b.get("end", Vector3.ZERO)
			cumulative = grammar.stable_hash("%d:%d,%d,%d:%d,%d,%d:%d:%d:%d" % [cumulative,
				roundi(start.x * 1000.0), roundi(start.y * 1000.0), roundi(start.z * 1000.0),
				roundi(end.x * 1000.0), roundi(end.y * 1000.0), roundi(end.z * 1000.0),
				roundi(float(b.get("radiusStart", 0.0)) * 1000.0),
				roundi(float(b.get("radiusEnd", 0.0)) * 1000.0), int(b.get("order", 0))])
			if branch_index < 5 or branch_index % 25 == 24 or branch_index == branches.size() - 1:
				branch_checkpoints.append([branch_index, cumulative])
		var foliage_checkpoints := []
		for foliage_index in range(foliage.size()):
			var f: Dictionary = foliage[foliage_index]
			var position: Vector3 = f.get("position", Vector3.ZERO)
			cumulative = grammar.stable_hash("%d:%d,%d,%d:%d" % [cumulative,
				roundi(position.x * 1000.0), roundi(position.y * 1000.0), roundi(position.z * 1000.0),
				int(f.get("sourceOrder", 0))])
			if foliage_index < 5 or foliage_index % 25 == 24 or foliage_index == foliage.size() - 1:
				foliage_checkpoints.append([foliage_index, cumulative])
		print("VWB_SAVANNA_ORACLE:", JSON.stringify({
			"seed": input[0], "maturity": input[1], "signature": recipe.get("signature", ""),
			"height": recipe.get("height", 0.0), "trunkRadius": recipe.get("trunkRadius", 0.0),
			"canopyRadius": recipe.get("canopyRadius", 0.0), "crownBase": recipe.get("crownBase", 0.0),
			"crownHeight": recipe.get("crownHeight", 0.0), "branchCount": branches.size(),
			"foliageCount": foliage.size(), "nodeCount": stats.get("nodeCount", 0),
			"segmentCountsByOrder": stats.get("segmentCountsByOrder", {}),
			"raisedForkCount": stats.get("raisedForkCount", 0),
			"crownWindowCount": stats.get("crownWindowCount", 0),
			"viableAxisBudCount": stats.get("viableAxisBudCount", 0),
			"germinatedAxisCount": stats.get("germinatedAxisCount", 0),
			"grownMetamerCount": stats.get("grownMetamerCount", 0),
			"pipeModelJunctionCount": stats.get("pipeModelJunctionCount", 0),
			"crownOccupancy": stats.get("crownOccupancy", {}),
			"branchSelectionHash": grammar.stable_hash("|".join(branch_parts)),
			"foliageSelectionHash": grammar.stable_hash("|".join(foliage_parts)),
			"branchHashCheckpoints": branch_checkpoints, "foliageHashCheckpoints": foliage_checkpoints,
			"firstBranch": first_branch, "firstFoliage": first_foliage
		}))
	quit()
