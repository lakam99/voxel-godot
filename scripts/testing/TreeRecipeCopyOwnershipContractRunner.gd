extends SceneTree

## Checks that the recipe-copy optimization preserves the old recipe payload
## and keeps cached/source recipe data isolated from caller mutations.

const TreeSpawnServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")
const CertifiedRequestFixture := preload("res://scripts/testing/CertifiedTreeRequestFixture.gd")

func _initialize() -> void:
	call_deferred("run_contract")

func run_contract() -> void:
	var report_path := OS.get_environment("VOXEL_TREE_RECIPE_COPY_OWNERSHIP_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/vegetation/tree-recipe-copy-ownership-contract.json")
	var service = TreeSpawnServiceScript.new()
	var family_fixtures := [
		{"treeId":"copy-golden-oak", "worldSeed":"copy-golden-seed", "biome":"forest", "architecture":"broadleaf", "speciesGrammar":"bushy_oak", "growthStage":0.82, "geneticSeed":314159, "canopyDensity":0.84},
		{"treeId":"copy-golden-spruce", "worldSeed":"copy-golden-seed", "biome":"taiga", "architecture":"conifer", "speciesGrammar":"norway_spruce", "growthStage":0.73, "geneticSeed":271828, "canopyDensity":0.76},
		{"treeId":"copy-golden-thorn", "worldSeed":"copy-golden-seed", "biome":"savanna", "architecture":"savanna", "speciesGrammar":"umbrella_thorn", "growthStage":0.69, "geneticSeed":161803, "canopyDensity":0.72}
	]
	var lod_tiers := ["near", "mid", "far", "impostor"]
	var golden_cases: Array[Dictionary] = []
	var payload_match := true
	var fixtures: Array[Dictionary] = []
	for family_fixture in family_fixtures:
		for lod_tier in lod_tiers:
			var request: Dictionary = (family_fixture as Dictionary).duplicate(true)
			request["treeId"] = "%s-%s" % [String(request.get("treeId", "")), String(lod_tier)]
			request["renderLodTier"] = String(lod_tier)
			request = CertifiedRequestFixture.prepare_or_fail(request)
			fixtures.append(request)
			var normalized: Dictionary = service.normalize_request(request)
			var raw: Dictionary
			if lod_tier == "impostor":
				raw = {
					"signature":"impostor:%s:%s:%s" % [normalized.get("worldSeed", ""), normalized.get("treeId", ""), normalized.get("speciesGrammar", "")],
					"height":1.0, "trunkRadius":1.0, "canopyRadius":1.0,
					"architecture":String(normalized.get("architecture", "broadleaf")),
					"speciesGrammar":String(normalized.get("speciesGrammar", "bushy_oak")),
					"crownHabit":"distance_impostor", "branches":[], "foliage":[]
				}
			else:
				var grammar = service.grammar_for(String(normalized.get("speciesGrammar", "")))
				raw = grammar.build_recipe(int(normalized.get("geneticSeed", 0)), float(normalized.get("maturity", 0.58)), service.runtime_growth_profile(normalized))
				raw = service.reduce_raw_runtime_recipe(raw, normalized)
			var legacy_canonical: Dictionary = legacy_adapt_recipe(raw, normalized, service)
			var expected: Dictionary = legacy_render_recipe(legacy_canonical, normalized, service)
			var actual: Dictionary = service.build_recipe(request)
			var stable_actual := stable_recipe_payload(actual)
			var stable_expected := stable_recipe_payload(expected)
			var exact_match: bool = stable_actual == stable_expected
			var mismatched_keys: Array[String] = []
			if not exact_match:
				for key in stable_expected.keys():
					if not stable_actual.has(key) or stable_actual[key] != stable_expected[key]:
						mismatched_keys.append(String(key))
				for key in stable_actual.keys():
					if not stable_expected.has(key) and not mismatched_keys.has(String(key)):
						mismatched_keys.append(String(key))
			payload_match = payload_match and exact_match
			golden_cases.append({
				"treeId": String(request.get("treeId", "")),
				"family": String(request.get("speciesGrammar", "")),
				"tier": String(lod_tier),
				"signature": String(actual.get("signature", "")),
				"branchCount": int(actual.get("branchCount", 0)),
				"foliageClusterCount": int(actual.get("foliageClusterCount", 0)),
				"sourceBranchCount": int(actual.get("sourceBranchCount", 0)),
				"sourceFoliageClusterCount": int(actual.get("sourceFoliageClusterCount", 0)),
				"mismatchedKeys": mismatched_keys,
				"legacyPayloadMatch": exact_match
			})
	var repeat_service = TreeSpawnServiceScript.new()
	var first_golden: Dictionary = repeat_service.build_recipe(fixtures[0])
	var repeated_golden: Dictionary = repeat_service.build_recipe(fixtures[0])
	var deterministic_repeat := first_golden == repeated_golden

	var adaptation_raw := {
		"signature":"copy-adaptation-fixture",
		"height":10.0,
		"trunkRadius":0.5,
		"canopyRadius":4.0,
		"architecture":"broadleaf",
		"speciesGrammar":"bushy_oak",
		"branches":[{"start":Vector3(1.0, 2.0, 3.0), "end":Vector3(1.0, 8.0, 3.0), "radiusStart":0.3, "radiusEnd":0.1, "custom":{"samples":[11]}}],
		"foliage":[{"position":Vector3(2.0, 7.0, 1.0), "scale":Vector3.ONE, "custom":{"samples":[13]}}],
		"stats":{"nested":[{"value":17}]}
	}
	var adaptation_raw_before: Dictionary = adaptation_raw.duplicate(true)
	var adaptation_request: Dictionary = service.normalize_request({"treeId":"copy-adaptation", "worldSeed":"copy-seed", "visualHeight":20.0, "trunkRadius":1.0, "canopyRadius":8.0})
	var adapted: Dictionary = service.adapt_grammar_recipe(adaptation_raw, adaptation_request)
	var adapted_branch: Dictionary = adapted["branches"][0]
	var adapted_branch_custom: Dictionary = adapted_branch["custom"]
	var adapted_samples: Array = adapted_branch_custom["samples"]
	adapted_samples[0] = -11
	var adapted_stats: Dictionary = adapted["stats"]
	var adapted_nested: Array = adapted_stats["nested"]
	var adapted_nested_entry: Dictionary = adapted_nested[0]
	adapted_nested_entry["value"] = -17
	var adaptation_source_isolated := adaptation_raw == adaptation_raw_before
	var mutation_service = TreeSpawnServiceScript.new()
	var mutation_request: Dictionary = fixtures[0].duplicate(true)
	mutation_request["treeId"] = "copy-cache-mutation"
	mutation_service.build_recipe(mutation_request)
	var mutation_key := mutation_service.recipe_cache_key(mutation_request)
	var cached_canonical: Dictionary = mutation_service.recipe_cache[mutation_key]
	cached_canonical["rootButtressFootprints"] = [{
		"start":Vector3.ZERO, "end":Vector3.UP, "radiusStart":0.3, "radiusEnd":0.1,
		"role":"root_buttress", "custom":{"nested":[901]}
	}]
	var cached_biome_parameters: Dictionary = cached_canonical.get("biomeParameters", {}).duplicate(true)
	cached_biome_parameters["extension"] = {"samples":[902]}
	cached_canonical["biomeParameters"] = cached_biome_parameters
	var cached_render_policy: Dictionary = cached_canonical.get("renderPolicy", {}).duplicate(true)
	cached_render_policy["extension"] = {"values":[903]}
	cached_canonical["renderPolicy"] = cached_render_policy
	var canonical_before: Dictionary = mutation_service.recipe_cache[mutation_key].duplicate(true)
	var returned_recipe: Dictionary = mutation_service.build_recipe(mutation_request)
	var returned_branches: Array = returned_recipe.get("branches", [])
	var returned_foliage: Array = returned_recipe.get("foliage", [])
	if not returned_branches.is_empty():
		var returned_branch: Dictionary = returned_branches[0]
		returned_branch["order"] = -901
	if not returned_foliage.is_empty():
		var returned_anchor: Dictionary = returned_foliage[0]
		returned_anchor["sourceSegment"] = -902
	var returned_biome_parameters: Dictionary = returned_recipe.get("biomeParameters", {})
	returned_biome_parameters["windResponse"] = -903.0
	var returned_biome_extension: Dictionary = returned_biome_parameters["extension"]
	var returned_biome_samples: Array = returned_biome_extension["samples"]
	returned_biome_samples[0] = -904
	var returned_render_policy: Dictionary = returned_recipe.get("renderPolicy", {})
	var returned_render_extension: Dictionary = returned_render_policy["extension"]
	var returned_render_values: Array = returned_render_extension["values"]
	returned_render_values[0] = -905
	var returned_root_footprints: Array = returned_recipe.get("rootButtressFootprints", [])
	var returned_root_footprint: Dictionary = returned_root_footprints[0]
	var returned_root_custom: Dictionary = returned_root_footprint["custom"]
	var returned_root_nested: Array = returned_root_custom["nested"]
	returned_root_nested[0] = -906
	var canonical_isolated: bool = mutation_service.recipe_cache[mutation_key] == canonical_before
	var repeated_after_mutation: Dictionary = mutation_service.build_recipe(mutation_request)
	var repeated_branches: Array = repeated_after_mutation.get("branches", [])
	var repeated_foliage: Array = repeated_after_mutation.get("foliage", [])
	var repeated_branch: Dictionary = repeated_branches[0] if not repeated_branches.is_empty() else {}
	var repeated_anchor: Dictionary = repeated_foliage[0] if not repeated_foliage.is_empty() else {}
	var repeated_biome_parameters: Dictionary = repeated_after_mutation.get("biomeParameters", {})
	var repeated_biome_extension: Dictionary = repeated_biome_parameters.get("extension", {})
	var repeated_biome_samples: Array = repeated_biome_extension.get("samples", [])
	var repeated_render_policy: Dictionary = repeated_after_mutation.get("renderPolicy", {})
	var repeated_render_extension: Dictionary = repeated_render_policy.get("extension", {})
	var repeated_render_values: Array = repeated_render_extension.get("values", [])
	var repeated_root_footprints: Array = repeated_after_mutation.get("rootButtressFootprints", [])
	var repeated_root_footprint: Dictionary = repeated_root_footprints[0] if not repeated_root_footprints.is_empty() else {}
	var repeated_root_custom: Dictionary = repeated_root_footprint.get("custom", {})
	var repeated_root_nested: Array = repeated_root_custom.get("nested", [])
	var returned_recipe_isolated := String(repeated_after_mutation.get("signature", "")) == String(canonical_before.get("signature", "")) \
		and int(repeated_branch.get("order", -1)) != -901 \
		and int(repeated_anchor.get("sourceSegment", -1)) != -902 \
		and float(repeated_biome_parameters.get("windResponse", -1.0)) >= 0.0 \
		and int(repeated_biome_samples[0]) == 902 \
		and int(repeated_render_values[0]) == 903 \
		and int(repeated_root_nested[0]) == 901

	var synthetic_source := synthetic_canonical_recipe()
	var synthetic_before: Dictionary = synthetic_source.duplicate(true)
	var mid_request: Dictionary = service.normalize_request({"treeId":"copy-lod-mutation", "worldSeed":"copy-seed", "renderLodTier":"mid"})
	var budgets: Dictionary = service.runtime_render_budgets(mid_request)
	var expected_branches: Array = service.graph_preserving_reduce(synthetic_source["branches"], int(budgets.get("branchBudget", 0)))
	var expected_foliage: Array = service.support_aware_foliage_reduce(synthetic_source["foliage"], int(budgets.get("foliageBudget", 0)))
	var downshifted: Dictionary = service.render_recipe(synthetic_source, mid_request)
	var downshift_payload_match: bool = downshifted.get("branches", []) == expected_branches \
		and downshifted.get("foliage", []) == expected_foliage \
		and expected_branches.size() <= int(budgets.get("branchBudget", 0)) \
		and expected_foliage.size() <= int(budgets.get("foliageBudget", 0)) \
		and downshifted.get("stats", {}) == synthetic_source.get("stats", {}) \
		and downshifted.get("rootButtressFootprints", []) == synthetic_source.get("rootButtressFootprints", []) \
		and downshifted.get("biomeParameters", {}) == synthetic_source.get("biomeParameters", {}) \
		and downshifted.get("renderPolicy", {}) == synthetic_source.get("renderPolicy", {})
	var downshift_before_mutation: Dictionary = downshifted.duplicate(true)
	var downshift_branches: Array = downshifted.get("branches", [])
	var downshift_foliage: Array = downshifted.get("foliage", [])
	if not downshift_branches.is_empty():
		var downshift_branch: Dictionary = downshift_branches[0]
		var branch_custom: Dictionary = downshift_branch["custom"]
		var branch_deep: Array = branch_custom["deep"]
		branch_deep[0] = -991
	if not downshift_foliage.is_empty():
		var downshift_anchor: Dictionary = downshift_foliage[0]
		var anchor_custom: Dictionary = downshift_anchor["custom"]
		var anchor_deep: Array = anchor_custom["deep"]
		anchor_deep[0] = -992
	var downshift_stats: Dictionary = downshifted["stats"]
	var downshift_nested: Array = downshift_stats["nested"]
	var downshift_nested_entry: Dictionary = downshift_nested[0]
	downshift_nested_entry["value"] = -993
	var downshift_footprints: Array = downshifted["rootButtressFootprints"]
	var downshift_footprint: Dictionary = downshift_footprints[0]
	var footprint_custom: Dictionary = downshift_footprint["custom"]
	var footprint_nested: Array = footprint_custom["nested"]
	footprint_nested[0] = -994
	var downshift_biome: Dictionary = downshifted["biomeParameters"]
	var biome_extension: Dictionary = downshift_biome["extension"]
	var biome_samples: Array = biome_extension["samples"]
	biome_samples[0] = -995
	var downshift_render_policy: Dictionary = downshifted["renderPolicy"]
	var render_extension: Dictionary = downshift_render_policy["extension"]
	var render_values: Array = render_extension["values"]
	render_values[0] = -996
	var repeated_downshift: Dictionary = service.render_recipe(synthetic_source, mid_request)
	var downshift_source_isolated := synthetic_source == synthetic_before \
		and repeated_downshift == downshift_before_mutation
	var budget_boundaries := run_budget_boundary_contract(service)
	var ancestry_cases := run_ancestry_contract(service)

	var passed: bool = payload_match and deterministic_repeat and adaptation_source_isolated \
		and canonical_isolated and returned_recipe_isolated and downshift_payload_match and downshift_source_isolated \
		and bool(budget_boundaries.get("passed", false)) and bool(ancestry_cases.get("passed", false))
	var report := {
		"runnerId":"tree_recipe_copy_ownership_contract",
		"evidenceLevel":"contract",
		"passed":passed,
		"ignoredNondeterministicRecipeStats":["stats.timingUsec", "stats.colonizationTimingUsec"],
		"legacyPayloadMatch":payload_match,
		"deterministicRepeat":deterministic_repeat,
		"adaptationInputIsolated":adaptation_source_isolated,
		"cachedCanonicalIsolated":canonical_isolated,
		"returnedRecipeIsolated":returned_recipe_isolated,
		"downshiftPayloadMatch":downshift_payload_match,
		"downshiftSourceIsolated":downshift_source_isolated,
		"budgetBoundaries":budget_boundaries,
		"branchAncestry":ancestry_cases,
		"goldenCases":golden_cases,
		"downshiftSourceCounts":{"branches":synthetic_source["branches"].size(), "foliage":synthetic_source["foliage"].size()},
		"downshiftResultCounts":{"branches":downshift_branches.size(), "foliage":downshift_foliage.size()}
	}
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var report_file := FileAccess.open(report_path, FileAccess.WRITE)
	if report_file == null:
		report["passed"] = false
		report["reportWriteError"] = FileAccess.get_open_error()
	else:
		report_file.store_string(JSON.stringify(report, "  "))
		report_file.close()
	print(JSON.stringify(report))
	quit(0 if bool(report.get("passed", false)) else 1)

func stable_recipe_payload(recipe: Dictionary) -> Dictionary:
	var stable: Dictionary = recipe.duplicate(true)
	# Admission provenance is request metadata. It does not participate in the
	# legacy render-payload oracle and is validated when the fixture is prepared.
	stable.erase("treeAdmissionCertificate")
	stable.erase("treeProducerCatalogRevision")
	stable.erase("treeProducerEnvelopeDigest")
	if stable.get("stats", {}) is Dictionary:
		var stable_stats: Dictionary = stable.get("stats", {})
		stable_stats.erase("timingUsec")
		stable_stats.erase("colonizationTimingUsec")
		stable["stats"] = stable_stats
	return stable

func legacy_adapt_recipe(raw: Dictionary, request: Dictionary, service) -> Dictionary:
	# This deliberately retains the former clone-per-element plus whole-graph
	# clone algorithm as an executable recipe payload oracle for fixed inputs.
	var source_height := maxf(0.01, float(raw.get("height", 1.0)))
	var source_radius := maxf(0.01, float(raw.get("trunkRadius", 0.1)))
	var source_canopy := maxf(0.01, float(raw.get("canopyRadius", 1.0)))
	var vertical_scale := float(request.get("visualHeight", source_height)) / source_height
	var radius_scale := float(request.get("trunkRadius", source_radius)) / source_radius
	var horizontal_scale := float(request.get("canopyRadius", source_canopy)) / source_canopy
	var branches: Array[Dictionary] = []
	for source_value in raw.get("branches", []):
		if not source_value is Dictionary:
			continue
		var source: Dictionary = source_value
		var branch: Dictionary = source.duplicate(true)
		branch["start"] = service.scale_position(source.get("start", Vector3.ZERO), horizontal_scale, vertical_scale)
		branch["end"] = service.scale_position(source.get("end", Vector3.UP), horizontal_scale, vertical_scale)
		branch["radiusStart"] = maxf(0.018, float(source.get("radiusStart", 0.04)) * radius_scale)
		branch["radiusEnd"] = maxf(0.012, float(source.get("radiusEnd", 0.02)) * radius_scale)
		var wind_response := float((request.get("biomeParameters", {}) as Dictionary).get("windResponse", 1.0))
		branch["windWeight"] = clampf(maxf((branch["start"] as Vector3).y, (branch["end"] as Vector3).y) / maxf(1.0, float(request.get("visualHeight", 1.0))) * wind_response, 0.0, 1.0)
		branches.append(branch)
	var foliage: Array[Dictionary] = []
	for source_value in raw.get("foliage", []):
		if not source_value is Dictionary:
			continue
		var source: Dictionary = source_value
		var anchor: Dictionary = source.duplicate(true)
		anchor["position"] = service.scale_position(source.get("position", Vector3.ZERO), horizontal_scale, vertical_scale)
		var source_scale: Vector3 = source.get("scale", Vector3.ONE)
		anchor["scale"] = Vector3(source_scale.x * horizontal_scale, source_scale.y * vertical_scale, source_scale.z * horizontal_scale)
		var foliage_wind_response := float((request.get("biomeParameters", {}) as Dictionary).get("windResponse", 1.0))
		anchor["windWeight"] = clampf((anchor["position"] as Vector3).y / maxf(1.0, float(request.get("visualHeight", 1.0))) * foliage_wind_response, 0.20, 1.0)
		foliage.append(anchor)
	var recipe: Dictionary = raw.duplicate(true)
	recipe["version"] = service.RECIPE_VERSION
	recipe["treeId"] = String(request.get("treeId", ""))
	recipe["biome"] = String(request.get("biome", "forest"))
	recipe["architecture"] = String(request.get("architecture", raw.get("architecture", "broadleaf")))
	recipe["speciesGrammar"] = String(request.get("speciesGrammar", raw.get("speciesGrammar", "bushy_oak")))
	recipe["ageBand"] = String(request.get("ageBand", "mature"))
	recipe["ageYears"] = float(request.get("ageYears", 0.0))
	recipe["growthStage"] = float(request.get("maturity", 0.58))
	recipe["geneticSeed"] = int(request.get("geneticSeed", 0))
	recipe["height"] = float(request.get("visualHeight", source_height))
	recipe["trunkRadius"] = float(request.get("trunkRadius", source_radius))
	recipe["canopyRadius"] = float(request.get("canopyRadius", source_canopy))
	recipe["canopyDensity"] = float(request.get("canopyDensity", 0.78))
	recipe["biomeParameters"] = (request.get("biomeParameters", {}) as Dictionary).duplicate(true)
	recipe["renderPolicy"] = service.render_policy(request)
	recipe["branches"] = branches
	var footprints: Array[Dictionary] = []
	for footprint_value in raw.get("rootButtressFootprints", []) as Array:
		if not footprint_value is Dictionary:
			continue
		var footprint: Dictionary = footprint_value as Dictionary
		footprints.append({
			"start":service.scale_position(footprint.get("start", Vector3.ZERO), horizontal_scale, vertical_scale),
			"end":service.scale_position(footprint.get("end", Vector3.ZERO), horizontal_scale, vertical_scale),
			"radiusStart":maxf(0.018, float(footprint.get("radiusStart", 0.04)) * radius_scale),
			"radiusEnd":maxf(0.012, float(footprint.get("radiusEnd", 0.02)) * radius_scale),
			"role":String(footprint.get("role", "root_buttress"))
		})
	recipe["rootButtressFootprints"] = footprints
	recipe["foliage"] = foliage
	recipe["sourceBranchCount"] = int(raw.get("sourceBranchCount", branches.size()))
	recipe["sourceFoliageClusterCount"] = int(raw.get("sourceFoliageClusterCount", foliage.size()))
	recipe["runtimeRecipePassCount"] = int(raw.get("runtimeRecipePassCount", 1))
	recipe["runtimeFoliageSupplementCount"] = int(raw.get("runtimeFoliageSupplementCount", 0))
	recipe["branchCount"] = branches.size()
	recipe["foliageClusterCount"] = foliage.size()
	recipe["topologySignature"] = String(raw.get("signature", ""))
	recipe["signature"] = service.runtime_recipe_signature(recipe, request)
	recipe["collision"] = service.collision_summary(recipe)
	return recipe

func legacy_render_recipe(canonical: Dictionary, request: Dictionary, service) -> Dictionary:
	var recipe: Dictionary = canonical.duplicate(true)
	var lod_tier := String(request.get("renderLodTier", "near"))
	if lod_tier == "impostor":
		recipe["branches"] = []
		recipe["foliage"] = []
		recipe["branchCount"] = 0
		recipe["foliageClusterCount"] = 0
		recipe["renderLod"] = {"tier":lod_tier, "branchBudget":0, "foliageBudget":0, "impostor":true}
		recipe["runtimeImpostor"] = true
		recipe["runtimeContinuousBole"] = false
		recipe["pocContinuousWood"] = false
		return service.attach_interaction_facts(recipe, request)
	var budgets: Dictionary = service.runtime_render_budgets(request)
	var branch_budget := int(budgets.get("branchBudget", 0))
	var foliage_budget := int(budgets.get("foliageBudget", 0))
	recipe["branches"] = service.graph_preserving_reduce(canonical.get("branches", []), branch_budget)
	recipe["foliage"] = service.support_aware_foliage_reduce(canonical.get("foliage", []), foliage_budget)
	recipe["branchCount"] = (recipe["branches"] as Array).size()
	recipe["foliageClusterCount"] = (recipe["foliage"] as Array).size()
	recipe["renderLod"] = {"tier":lod_tier, "branchBudget":branch_budget, "foliageBudget":foliage_budget, "impostor":false}
	recipe["runtimeImpostor"] = false
	recipe["runtimeContinuousBole"] = true
	recipe["pocContinuousWood"] = false
	return service.attach_interaction_facts(recipe, request)

func run_budget_boundary_contract(service) -> Dictionary:
	var base_request: Dictionary = service.normalize_request({"treeId":"copy-budget-boundary", "worldSeed":"copy-seed", "renderLodTier":"near"})
	var budgets: Dictionary = service.runtime_render_budgets(base_request)
	var branch_budget := int(budgets.get("branchBudget", 0))
	var foliage_budget := int(budgets.get("foliageBudget", 0))
	var cases: Array[Dictionary] = []
	var passed := branch_budget > 1 and foliage_budget > 1
	for delta in [-1, 0, 1]:
		var source := budget_boundary_recipe(branch_budget + int(delta), foliage_budget + int(delta))
		var expected: Dictionary = legacy_render_recipe(source, base_request, service)
		var actual: Dictionary = service.render_recipe(source, base_request)
		var exact_match := actual == expected
		passed = passed and exact_match
		cases.append({
			"deltaFromBudget":int(delta),
			"sourceBranches":(source.get("branches", []) as Array).size(),
			"sourceFoliage":(source.get("foliage", []) as Array).size(),
			"branchBudget":branch_budget,
			"foliageBudget":foliage_budget,
			"branchCount":int(actual.get("branchCount", -1)),
			"foliageCount":int(actual.get("foliageClusterCount", -1)),
			"legacyPayloadMatch":exact_match
		})
	return {"passed":passed, "cases":cases}

func run_ancestry_contract(service) -> Dictionary:
	var rooted_branches: Array[Dictionary] = []
	rooted_branches.append({"order":0, "parentNode":-1, "childNode":0})
	for index in range(1, 6):
		rooted_branches.append({"order":1, "parentNode":0, "childNode":index})
	for index in range(6, 11):
		rooted_branches.append({"order":2, "parentNode":1 + (index - 6), "childNode":index})
	for index in range(11, 16):
		rooted_branches.append({"order":3, "parentNode":6 + (index - 11), "childNode":index})
	var reduced_rooted: Array = service.graph_preserving_reduce(rooted_branches, 8)
	var retained_children := {}
	var maximum_retained_order := -1
	for branch_value in reduced_rooted:
		var branch: Dictionary = branch_value
		retained_children[int(branch.get("childNode", -1))] = true
		maximum_retained_order = maxi(maximum_retained_order, int(branch.get("order", -1)))
	var rooted_paths_closed := not reduced_rooted.is_empty()
	for branch_value in reduced_rooted:
		var branch: Dictionary = branch_value
		var parent_node := int(branch.get("parentNode", -1))
		if parent_node >= 0 and not retained_children.has(parent_node):
			rooted_paths_closed = false
	var long_trunk: Array[Dictionary] = []
	for index in range(40):
		long_trunk.append({"order":0, "parentNode":index - 1, "childNode":index})
	for index in range(40, 80):
		long_trunk.append({"order":1, "parentNode":39, "childNode":index})
	var trunk_budget := 8
	var reduced_long_trunk: Array = service.graph_preserving_reduce(long_trunk, trunk_budget)
	var retained_trunk_children := {}
	for branch_value in reduced_long_trunk:
		var branch: Dictionary = branch_value
		retained_trunk_children[int(branch.get("childNode", -1))] = true
	var all_mandatory_trunk_segments_retained := true
	for index in range(40):
		all_mandatory_trunk_segments_retained = all_mandatory_trunk_segments_retained and retained_trunk_children.has(index)
	var over_cap_trunk_preserved := reduced_long_trunk.size() == 40 and reduced_long_trunk.size() > trunk_budget \
		and all_mandatory_trunk_segments_retained
	return {
		"passed":rooted_paths_closed and maximum_retained_order >= 2 and over_cap_trunk_preserved,
		"rootedSourceBranches":rooted_branches.size(),
		"rootedReducedBranches":reduced_rooted.size(),
		"rootedMaximumOrderRetained":maximum_retained_order,
		"rootedPathsClosed":rooted_paths_closed,
		"longTrunkSourceBranches":long_trunk.size(),
		"longTrunkRequestedBudget":trunk_budget,
		"longTrunkReducedBranches":reduced_long_trunk.size(),
		"mandatoryTrunkExceedsBudgetAndRemainsWhole":over_cap_trunk_preserved
	}

func budget_boundary_recipe(branch_count: int, foliage_count: int) -> Dictionary:
	var branches: Array[Dictionary] = []
	for index in range(branch_count):
		branches.append({
			"order":0 if index == 0 else 1,
			"parentNode":-1,
			"childNode":index,
			"start":Vector3.ZERO,
			"end":Vector3(0.1, 1.0, 0.0),
			"custom":{"deep":[index]}
		})
	var foliage: Array[Dictionary] = []
	var group_count := maxi(1, mini(branch_count, 101))
	for index in range(foliage_count):
		foliage.append({"sourceSegment":index % group_count, "position":Vector3(0.0, 1.0, 0.0), "scale":Vector3.ONE, "custom":{"deep":[index]}})
	return {
		"branches":branches,
		"foliage":foliage,
		"branchCount":branch_count,
		"foliageClusterCount":foliage_count,
		"height":20.0,
		"trunkRadius":1.0,
		"canopyRadius":8.0,
		"architecture":"broadleaf",
		"speciesGrammar":"bushy_oak",
		"treeId":"budget-boundary",
		"topologySignature":"budget-boundary-signature",
		"rootButtressFootprints":[],
		"stats":{"nested":[{"value":1}]}
	}

func synthetic_canonical_recipe() -> Dictionary:
	var branches: Array[Dictionary] = []
	for index in range(540):
		branches.append({
			"order":0 if index == 0 else 1 + ((index - 1) % 4),
			"parentNode":-1,
			"childNode":index,
			"start":Vector3(float(index % 13), float(index % 41), 0.0),
			"end":Vector3(float(index % 13) + 0.2, float(index % 41) + 1.0, 0.1),
			"radiusStart":0.12,
			"radiusEnd":0.08,
			"custom":{"deep":[index]}
		})
	var foliage: Array[Dictionary] = []
	for index in range(700):
		foliage.append({"sourceSegment":index % 540, "position":Vector3(float(index % 29), 8.0, 2.0), "scale":Vector3.ONE, "custom":{"deep":[index]}})
	return {
		"branches":branches,
		"foliage":foliage,
		"branchCount":branches.size(),
		"foliageClusterCount":foliage.size(),
		"height":32.0,
		"trunkRadius":1.2,
		"canopyRadius":12.0,
		"architecture":"broadleaf",
		"speciesGrammar":"bushy_oak",
		"treeId":"synthetic-copy-source",
		"topologySignature":"synthetic-copy-signature",
		"rootButtressFootprints":[{"start":Vector3.ZERO, "end":Vector3.UP, "radiusStart":0.3, "radiusEnd":0.1, "role":"root_buttress", "custom":{"nested":[994]}}],
		"biomeParameters":{"windResponse":0.8, "extension":{"samples":[995]}},
		"renderPolicy":{"visibilityRange":420.0, "extension":{"values":[996]}},
		"stats":{"nested":[{"value":993}], "segmentCountsByOrder":[1,120,150,150,119]}
	}
