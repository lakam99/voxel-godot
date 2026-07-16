extends SceneTree

## Narrow synthetic contract for VOX-142. It proves deterministic bounded
## recipe data only; visual quality remains subject to headed review.

const BuilderScript := preload("res://scripts/testing/trees/MathematicalTreePocBushyOakRecipeBuilder.gd")
const FIXED_SEED := 0x4F414B42

func _initialize() -> void:
	call_deferred("run_contract")

func run_contract() -> void:
	var builder = BuilderScript.new()
	var started := Time.get_ticks_usec()
	var first: Dictionary = builder.build_recipe(FIXED_SEED, 0.92)
	var generation_milliseconds := float(Time.get_ticks_usec() - started) / 1000.0
	var repeated: Dictionary = builder.build_recipe(FIXED_SEED, 0.92)
	var other: Dictionary = builder.build_recipe(FIXED_SEED + 9079, 0.92)
	var stats: Dictionary = first.get("stats", {})
	var counts: Dictionary = stats.get("segmentCountsByOrder", {})
	var saturation: Dictionary = stats.get("budgetSaturation", {})
	var derived_axis_growth: Dictionary = stats.get("derivedAxisGrowth", {})
	var density_seasons: Array = derived_axis_growth.get("seasons", [])
	var density_feedback_reduces_gap := false
	if density_seasons.size() >= 2:
		var first_density_season: Dictionary = density_seasons[0]
		var second_density_season: Dictionary = density_seasons[1]
		density_feedback_reduces_gap = float(second_density_season.get("meanCrownDensityDeficit", 1.0)) \
			< float(first_density_season.get("meanCrownDensityDeficit", 1.0))
	# The current PoC's critical biological rule: a viable bud funds an actual
	# child axis of multiple metamers, and the latent-bud rate grows from solved
	# pipe girth. This is recipe-level evidence only, not gameplay acceptance.
	var full_axis_propagation := float(derived_axis_growth.get("girthEligibleLength", 0.0)) >= 120.0 \
		and float(derived_axis_growth.get("girthWeightedBudCharge", 0.0)) \
			>= float(derived_axis_growth.get("integratedBudCharge", 0.0)) \
		and int(derived_axis_growth.get("grownMetamerCount", 0)) \
			>= int(derived_axis_growth.get("germinatedBudCount", 0)) * 2 \
		and int(derived_axis_growth.get("coDominantForkCount", 0)) >= 8 \
		and int(derived_axis_growth.get("fineAxisBudCount", 0)) >= 35
	var foliage: Array = first.get("foliage", [])
	var foliage_has_supporting_wood := true
	for anchor_value in foliage:
		if not (anchor_value is Dictionary) or int((anchor_value as Dictionary).get("sourceOrder", -1)) < 1:
			foliage_has_supporting_wood = false
			break
	var checks := {
		"deterministicRepeat": String(first.get("signature", "")) == String(repeated.get("signature", "")),
		"differentSeedChangesTopology": String(first.get("signature", "")) != String(other.get("signature", "")),
		"declaresBushyOakGrammar": String(first.get("architecture", "")) == "broadleaf" and String(first.get("speciesGrammar", "")) == "bushy_spreading_oak_poc" and String(first.get("methodology", "")) == "deterministic_oak_space_colonization_pipe_model",
		"graphConnected": bool(stats.get("connected", false)),
		"hasContinuousRaisedTrunk": bool(stats.get("continuousTrunkPath", false)) and int(counts.get("trunk", 0)) >= 7,
		"hasStructuralCrownBudOrigins": int(stats.get("germinatedMidCrownBudCount", 0)) >= 6,
		"hasDistributedSpaceColonizedWood": int(counts.get("primary", 0)) >= 90 and int(counts.get("secondary", 0)) >= 300 and int(counts.get("tertiary", 0)) >= 140,
		"longLimbsOutreachTrunk": float(stats.get("majorWoodReachToTrunkWidth", 0.0)) >= 2.65,
		"usesOutwardDomeSpaceColonization": String(stats.get("crownConstruction", "")) == "decurrent_oak_space_colonization_with_outward_dome_constraint",
		"derivesForksFromActualGirth": String(derived_axis_growth.get("rule", "")) == "continuous_derived_axis_resource_competition_seasons" and int(derived_axis_growth.get("seasonCount", 0)) >= 3 and int(derived_axis_growth.get("derivedAxisCount", 0)) >= 180 and int(derived_axis_growth.get("candidatePlanCount", 0)) >= 50 and int(derived_axis_growth.get("eligibleSegmentCount", 0)) >= 35 and int(derived_axis_growth.get("germinatedBudCount", 0)) >= 35 and int(derived_axis_growth.get("continuousSegmentSplitCount", 0)) == int(derived_axis_growth.get("germinatedBudCount", 0)) and full_axis_propagation and int(derived_axis_growth.get("lowerAxisBudCount", 0)) >= 16 and int(derived_axis_growth.get("densityProbeCount", 0)) >= 192 and density_feedback_reduces_gap and float(derived_axis_growth.get("integratedBudCharge", 0.0)) >= float(derived_axis_growth.get("emittedBudCharge", 0.0)) and int(derived_axis_growth.get("coneCompetitionRejections", 0)) >= 8 and float(derived_axis_growth.get("allocatedResource", 0.0)) > 0.0 and float(derived_axis_growth.get("minimumForkRadius", 0.0)) >= 0.50,
		"foliageComesFromSupportingWood": foliage_has_supporting_wood and bool(stats.get("foliageUsesSupportingWoodAcrossOrders", false)),
		"foliageIsBushyButBounded": foliage.size() >= 640 and foliage.size() <= 1250,
		# A long, low oak uses fewer height bins than an upright oval broadleaf;
		# this still requires broad 3D distribution rather than a single leaf tier.
		"crownUsesThreeDimensionalBins": float((stats.get("crownOccupancy", {}) as Dictionary).get("ratio", 0.0)) >= 0.30,
		"segmentsAreBounded": int(first.get("branchCount", 0)) > 0 and int(first.get("branchCount", 0)) <= 1607,
		"pipeModelConservesArea": float(stats.get("pipeModelMaxRelativeError", 1.0)) <= 0.0001,
		"branchGrowthStaysWithinBudget": not bool(saturation.get("branchLimitReached", true))
	}
	var passed := true
	for value in checks.values():
		passed = passed and bool(value)
	print(JSON.stringify({
		"runnerId": "mathematical_tree_poc_bushy_oak_contract",
		"linearIssue": "VOX-142",
		"evidenceLevel": "synthetic_contract",
		"scope": "Pure deterministic bushy spreading-oak recipe. It verifies SCA crown growth, pipe-model continuity, girth-gated derived-axis forks and bounds; it does not prove visual quality or production gameplay integration.",
		"passed": passed,
		"generationMilliseconds": generation_milliseconds,
		"signature": first.get("signature", ""),
		"branchCount": first.get("branchCount", 0),
		"foliageClusterCount": first.get("foliageClusterCount", 0),
		"stats": stats,
		"checks": checks
	}))
	quit(0 if passed else 1)
