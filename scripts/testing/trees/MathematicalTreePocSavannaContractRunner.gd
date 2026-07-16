extends SceneTree

## Narrow synthetic contract for the VOX-141 isolated species grammar.
## It validates deterministic bounded recipe data only; headed visual review is
## still the source of truth for silhouette and material continuity.

const BuilderScript := preload("res://scripts/testing/trees/MathematicalTreePocSavannaRecipeBuilder.gd")
const FIXED_SEED := 0x53415641

func _initialize() -> void:
	call_deferred("run_contract")

func run_contract() -> void:
	var builder = BuilderScript.new()
	var started := Time.get_ticks_usec()
	var first: Dictionary = builder.build_recipe(FIXED_SEED, 0.92)
	var generation_milliseconds := float(Time.get_ticks_usec() - started) / 1000.0
	var repeated: Dictionary = builder.build_recipe(FIXED_SEED, 0.92)
	var other: Dictionary = builder.build_recipe(FIXED_SEED + 6551, 0.92)
	var stats: Dictionary = first.get("stats", {})
	var counts: Dictionary = stats.get("segmentCountsByOrder", {})
	var saturation: Dictionary = stats.get("budgetSaturation", {})
	var foliage: Array = first.get("foliage", [])
	var fine_foliage_only := true
	for anchor_value in foliage:
		if not (anchor_value is Dictionary) or int((anchor_value as Dictionary).get("sourceOrder", -1)) < 2:
			fine_foliage_only = false
			break
	var crown_ratio := float(stats.get("crownVerticalToHorizontalRatio", 1.0))
	var scaffold_pitch := float(stats.get("meanLateralScaffoldPitch", 1.0))
	var checks := {
		"deterministicRepeat": String(first.get("signature", "")) == String(repeated.get("signature", "")),
		"differentSeedChangesTopology": String(first.get("signature", "")) != String(other.get("signature", "")),
		"declaresSavannaGrammar": String(first.get("architecture", "")) == "savanna" and String(first.get("speciesGrammar", "")) == "umbrella_thorn_like_poc",
		"graphConnected": bool(stats.get("connected", false)),
		"hasContinuousRaisedTrunk": bool(stats.get("continuousTrunkPath", false)) and int(counts.get("trunk", 0)) >= 7,
		"hasSubstantialRaisedForks": int(stats.get("raisedForkCount", 0)) >= 3 and int(counts.get("primary", 0)) >= 15,
		"hasLongLateralScaffolds": float(stats.get("maxMajorScaffoldReach", 0.0)) >= float(first.get("trunkRadius", 99.0)) * 4.8,
		"umbrellaCrownStaysShallow": crown_ratio > 0.08 and crown_ratio <= 0.28,
		"mainScaffoldsAreLateral": scaffold_pitch > -0.10 and scaffold_pitch < 0.62,
		"hasPerforatedFineWood": int(counts.get("tertiary", 0)) >= 120 and int(counts.get("twig", 0)) >= 120,
		"viableAxesSpendPipeGirth": int(stats.get("germinatedAxisCount", 0)) >= 24 \
			and int(stats.get("grownMetamerCount", 0)) >= 48 \
			and float(stats.get("girthWeightedBudCharge", 0.0)) > 20.0,
		"leavesComeFromFineWood": fine_foliage_only and bool(stats.get("foliageDerivedFromFineSegments", false)),
		"foliageIsDenseButBounded": foliage.size() >= 440 and foliage.size() <= 1540,
		"keepsDeterministicCrownWindows": int(stats.get("crownWindowCount", 0)) >= 20,
		"segmentsAreBounded": int(first.get("branchCount", 0)) > 0 and int(first.get("branchCount", 0)) <= 1120,
		"crownUsesThreeDimensionalBins": float((stats.get("crownOccupancy", {}) as Dictionary).get("ratio", 0.0)) >= 0.34,
		"pipeModelConservesArea": float(stats.get("pipeModelMaxRelativeError", 1.0)) <= 0.0001,
		"noRunawayBudgetSaturation": not bool(saturation.get("branchLimitReached", true)) and not bool(saturation.get("foliageLimitReached", true))
	}
	var passed := true
	for value in checks.values():
		passed = passed and bool(value)
	print(JSON.stringify({
		"runnerId": "mathematical_tree_poc_savanna_contract",
		"linearIssue": "VOX-141",
		"evidenceLevel": "synthetic_contract",
		"scope": "Pure deterministic umbrella-thorn-like recipe, raised-fork, girth-driven viable-axis, fine-wood, pipe-model and bounded-foliage checks. This does not prove visual quality or production gameplay integration.",
		"passed": passed,
		"generationMilliseconds": generation_milliseconds,
		"signature": first.get("signature", ""),
		"branchCount": first.get("branchCount", 0),
		"foliageClusterCount": first.get("foliageClusterCount", 0),
		"stats": stats,
		"checks": checks
	}))
	quit(0 if passed else 1)
