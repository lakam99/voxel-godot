extends SceneTree

const BuilderScript := preload("res://scripts/testing/trees/MathematicalTreePocRecipeBuilder.gd")
const FIXED_SEED := 0x4D415448

func _initialize() -> void:
	call_deferred("run_contract")

func run_contract() -> void:
	var builder = BuilderScript.new()
	var started := Time.get_ticks_usec()
	var first: Dictionary = builder.build_recipe(FIXED_SEED, 0.92)
	var generation_milliseconds := float(Time.get_ticks_usec() - started) / 1000.0
	var repeated: Dictionary = builder.build_recipe(FIXED_SEED, 0.92)
	var other: Dictionary = builder.build_recipe(FIXED_SEED + 7919, 0.92)
	var stats: Dictionary = first.get("stats", {})
	var counts: Dictionary = stats.get("segmentCountsByOrder", {})
	var saturation: Dictionary = stats.get("budgetSaturation", {})
	var pitch: Dictionary = stats.get("branchPitchByCrownStratum", {})
	var major_wood_reach_to_trunk_width := float(stats.get("majorWoodReachToTrunkWidth", 0.0))
	var lower_pitch: Dictionary = pitch.get("lower", {})
	var middle_pitch: Dictionary = pitch.get("middle", {})
	var upper_pitch: Dictionary = pitch.get("upper", {})
	var foliage: Array = first.get("foliage", [])
	var fine_foliage_only := true
	for anchor_value in foliage:
		if not (anchor_value is Dictionary) or int((anchor_value as Dictionary).get("sourceOrder", -1)) < 2:
			fine_foliage_only = false
			break
	var checks := {
		"deterministicRepeat": String(first.get("signature", "")) == String(repeated.get("signature", "")),
		"differentSeedChangesTopology": String(first.get("signature", "")) != String(other.get("signature", "")),
		"graphConnected": bool(stats.get("connected", false)),
		"hasTrunk": int(counts.get("trunk", 0)) >= 6,
		"hasPrimaryScaffolds": int(counts.get("primary", 0)) >= 7,
		"hasSecondaryBranches": int(counts.get("secondary", 0)) >= 8,
		"hasTertiaryBranches": int(counts.get("tertiary", 0)) >= 8,
		"hasTerminalTwigs": int(counts.get("twig", 0)) >= 8,
		"pipeModelConservesArea": float(stats.get("pipeModelMaxRelativeError", 1.0)) <= 0.0001,
		"foliageComesFromFineWood": fine_foliage_only and bool(stats.get("foliageDerivedFromFineSegments", false)),
		"foliageIsDenseButBounded": foliage.size() >= 180 and foliage.size() <= 1250,
		"segmentsAreBounded": int(first.get("branchCount", 0)) > 0 and int(first.get("branchCount", 0)) <= 1050,
		"crownUsesThreeDimensionalBins": float((stats.get("crownOccupancy", {}) as Dictionary).get("ratio", 0.0)) >= 0.50,
		# A mature crown's load-bearing wood must travel materially farther than
		# its trunk is wide. This protects the intended broad-reach allometry
		# without making trunk thickness a visual workaround.
		"majorWoodReachExceedsTrunkWidth": major_wood_reach_to_trunk_width >= 2.65,
		"branchPitchProgressesWithCrownHeight": int(lower_pitch.get("segmentCount", 0)) > 0 \
			and int(middle_pitch.get("segmentCount", 0)) > 0 \
			and int(upper_pitch.get("segmentCount", 0)) > 0 \
			and float(lower_pitch.get("averageVerticalDirection", 1.0)) < float(middle_pitch.get("averageVerticalDirection", 0.0)) \
			and float(middle_pitch.get("averageVerticalDirection", 0.0)) < float(upper_pitch.get("averageVerticalDirection", -1.0)) \
			and float(lower_pitch.get("averageVerticalDirection", 1.0)) < -0.02 \
			and float(upper_pitch.get("averageVerticalDirection", -1.0)) > 0.02,
		"noRunawayBudgetSaturation": not bool(saturation.get("branchLimitReached", true)) and not bool(saturation.get("foliageLimitReached", true))
	}
	var passed := true
	for value in checks.values():
		passed = passed and bool(value)
	print(JSON.stringify({
		"runnerId": "mathematical_tree_poc_contract",
		"evidenceLevel": "synthetic_contract",
		"scope": "Pure deterministic recipe, graph, branch-order, major-wood reach, pipe-model and bounded-foliage checks. This does not prove visual quality or production gameplay integration.",
		"passed": passed,
		"generationMilliseconds": generation_milliseconds,
		"signature": first.get("signature", ""),
		"branchCount": first.get("branchCount", 0),
		"foliageClusterCount": first.get("foliageClusterCount", 0),
		"stats": stats,
		"checks": checks
	}))
	quit(0 if passed else 1)
