extends SceneTree

const BuilderScript := preload("res://scripts/testing/trees/MathematicalTreePocConiferRecipeBuilder.gd")
const FIXED_SEED := 0x434F4E46

func _initialize() -> void:
	call_deferred("run_contract")

func run_contract() -> void:
	var builder = BuilderScript.new()
	var started := Time.get_ticks_usec()
	var first: Dictionary = builder.build_recipe(FIXED_SEED, 0.92)
	var generation_milliseconds := float(Time.get_ticks_usec() - started) / 1000.0
	var repeated: Dictionary = builder.build_recipe(FIXED_SEED, 0.92)
	var other: Dictionary = builder.build_recipe(FIXED_SEED + 5741, 0.92)
	var stats: Dictionary = first.get("stats", {})
	var counts: Dictionary = stats.get("segmentCountsByOrder", {})
	var saturation: Dictionary = stats.get("budgetSaturation", {})
	var foliage: Array = first.get("foliage", [])
	var fine_foliage_only := true
	for anchor_value in foliage:
		if not (anchor_value is Dictionary) or int((anchor_value as Dictionary).get("sourceOrder", -1)) < 2:
			fine_foliage_only = false
			break
	var lower_reach := float(stats.get("lowerWhorlMeanLength", 0.0))
	var upper_reach := float(stats.get("upperWhorlMeanLength", 0.0))
	var checks := {
		"deterministicRepeat": String(first.get("signature", "")) == String(repeated.get("signature", "")),
		"differentSeedChangesTopology": String(first.get("signature", "")) != String(other.get("signature", "")),
		"declaresConiferGrammar": String(first.get("architecture", "")) == "conifer" and String(first.get("speciesGrammar", "")) == "norway_spruce_like_poc",
		"graphConnected": bool(stats.get("connected", false)),
		"hasContinuousApicalLeader": bool(stats.get("apicalLeaderContinuous", false)) and int(counts.get("trunk", 0)) >= 12,
		"hasAgeDrivenWhorls": int(stats.get("coniferWhorlCount", 0)) >= 8,
		"firstWhorlClearsTrunkBase": float(stats.get("firstWhorlHeight", 0.0)) >= 5.0,
		"hasInterstitialBushiness": int(stats.get("interstitialSprayCount", 0)) >= 10,
		"branchletsFollowSupportVigour": int(stats.get("supportDrivenBranchletCount", 0)) >= 120 and float(stats.get("meanBoughBudCharge", 0.0)) >= 1.25,
		"lowerWhorlsOutreachUpperWhorls": lower_reach > upper_reach * 1.75,
		"hasDroopingBranchletCurtains": float(stats.get("droopingCurtainMeanPitch", 0.0)) < -0.12,
		"hasFineWood": int(counts.get("secondary", 0)) >= 24 and int(counts.get("tertiary", 0)) >= 24,
		"needlesComeFromFineWood": fine_foliage_only and bool(stats.get("foliageDerivedFromFineSegments", false)),
		"foliageIsDenseButBounded": foliage.size() >= 260 and foliage.size() <= 1480,
		"segmentsAreBounded": int(first.get("branchCount", 0)) > 0 and int(first.get("branchCount", 0)) <= 1120,
		"crownUsesThreeDimensionalBins": float((stats.get("crownOccupancy", {}) as Dictionary).get("ratio", 0.0)) >= 0.42,
		"pipeModelConservesArea": float(stats.get("pipeModelMaxRelativeError", 1.0)) <= 0.0001,
		"noRunawayBudgetSaturation": not bool(saturation.get("branchLimitReached", true)) and not bool(saturation.get("foliageLimitReached", true))
	}
	var passed := true
	for value in checks.values():
		passed = passed and bool(value)
	print(JSON.stringify({
		"runnerId": "mathematical_tree_poc_conifer_contract",
		"linearIssue": "VOX-140",
		"evidenceLevel": "synthetic_contract",
		"scope": "Pure deterministic Norway-spruce-like recipe, monopodial bud-spacing, support-driven branchlet, pipe-model and bounded-needle checks. This does not prove visual quality or production gameplay integration.",
		"passed": passed,
		"generationMilliseconds": generation_milliseconds,
		"signature": first.get("signature", ""),
		"branchCount": first.get("branchCount", 0),
		"foliageClusterCount": first.get("foliageClusterCount", 0),
		"stats": stats,
		"checks": checks
	}))
	quit(0 if passed else 1)
