extends SceneTree

## Source/geometry contract only: no scene, publication, navigation or gameplay.
## Baselines are isolated copies of the pre-patch planner/builder; see launch.json.
## Each seed runs in a separate process under an external <=120 second watchdog.
const Builder := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Blueprint := preload("res://scripts/buildings/BuildingBlueprint.gd")
const Sampler := preload("res://scripts/buildings/LandmarkBuildingRecipeSampler.gd")
const Planner := preload("res://scripts/buildings/CastleCourtyardDistrictPlacementPlanner.gd")
const Codec := preload("res://scripts/testing/buildings/CitadelStructuralComposerCheckpointCodec.gd")
const OPTIONS := {"fixedClearance": 0.04, "residenceClearance": 0.08, "pairClearance": 2.60, "boundaryClearance": 0.90}
const FAILED_SEED := 1298433643
const FAILED_INTENT := "courtyard_granary_003_right"
const CONTEXT := {"biome": "forest", "siteKey": "river-citadel", "citadelScale": 1.25, "settlementTier": "city", "style": "masonry"}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var report_path := OS.get_environment("VOXEL_PACKING_COUPLING_REPORT")
	var baseline_dir := OS.get_environment("VOXEL_PACKING_COUPLING_BASELINE")
	var seed := int(OS.get_environment("VOXEL_PACKING_COUPLING_SEED"))
	if seed not in [FAILED_SEED, 237207443, 208159] or not report_path.is_absolute_path() or FileAccess.file_exists(report_path) or baseline_dir.is_empty():
		quit(2)
		return
	var old_planner = load(baseline_dir.path_join("old-planner.gd"))
	var old_builder = load(baseline_dir.path_join("old-builder.gd"))
	if old_planner == null or old_builder == null:
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var context := CONTEXT.duplicate(true)
	if seed == FAILED_SEED:
		context["biome"] = "plains"
		context["siteKey"] = "citadel-site-v1:10:atlas-1492:1,-3"
	print("PACKING COUPLING: inputs seed=", seed)
	var inputs := _ordinary_inputs(seed, context)
	if not bool(inputs.get("ready", false)):
		push_error("Ordinary sampler/builder input reconstruction failed")
		quit(1)
		return
	var input_hash := _input_hash(inputs)
	print("PACKING COUPLING: current plan")
	var plan: Dictionary = _plan(Planner, inputs)
	print("PACKING COUPLING: independent pre-patch plan")
	var old_plan: Dictionary = _plan(old_planner, inputs)
	var checks := {
		"complete_ready_plan": _ready(plan, inputs.intents.size()),
		"inputs_unmodified": input_hash == _input_hash(inputs)
	}
	var validation: Dictionary = Planner.validate_plan(plan, inputs.intents, inputs.streetRecords, inputs.structureParts, inputs.courtyardBounds, OPTIONS)
	checks["full_exact_geometry_recomputed"] = bool(validation.get("passed", false)) and (validation.get("rejections", []) as Array).is_empty()
	checks["full_geometry_comparison_counts"] = int(validation.telemetry.descriptionCalls) == inputs.intents.size() and int(validation.telemetry.exactStreetComparisons) == inputs.intents.size() * inputs.streetRecords.size() and int(validation.telemetry.exactStructureComparisons) == inputs.intents.size() * inputs.structureParts.size() and int(validation.telemetry.exactPriorComparisons) == inputs.intents.size() * (inputs.intents.size() - 1) / 2
	var evidence := {"oldPlan": _summary(old_plan), "currentPlan": _summary(plan), "validation": validation}
	if seed == FAILED_SEED:
		checks["actual_site_has_twelve_intents"] = inputs.intents.size() == 12
		checks["old_planner_reproduces_fixed_axis_only_failure"] = old_plan.get("status") == "infeasible" and int(old_plan.telemetry.coupledRepairTriggerCount) == 0 and _fixed_axis_trigger(old_plan.rejections)
		var repairs: Array = plan.telemetry.get("coupledRepairs", [])
		checks["coupled_repair_records_exact_trigger_reason"] = repairs.size() == 1 and repairs[0].intentId == FAILED_INTENT and _fixed_axis_trigger(repairs[0].triggerRejections)
		checks["bounded_exact_repair_selected"] = repairs.size() == 1 and not bool(repairs[0].exhausted) and int(repairs[0].selectedOrdinal) >= 0 and int(repairs[0].evaluatedCount) > 0 and int(repairs[0].evaluatedCount) <= 1024 and int(repairs[0].candidateCap) == 1024
		print("PACKING COUPLING: fresh inputs reverse-order replay")
		var replay_inputs := _ordinary_inputs(seed, context)
		replay_inputs.intents.reverse()
		replay_inputs.streetRecords.reverse()
		replay_inputs.structureParts.reverse()
		var replay := _plan(Planner, replay_inputs)
		checks["fresh_reversed_inputs_exact_determinism"] = var_to_bytes(plan) == var_to_bytes(replay)
		# Deliberately corrupt a placed transform; full validation must reject it.
		var invalid: Dictionary = plan.duplicate(true)
		if not (invalid.get("placements", []) as Array).is_empty():
			invalid.placements[0].center += Vector3(1.0, 0.0, 0.0)
		var negative: Dictionary = Planner.validate_plan(invalid, inputs.intents, inputs.streetRecords, inputs.structureParts, inputs.courtyardBounds, OPTIONS)
		checks["corrupted_transform_rejected"] = not bool(negative.get("passed", true)) and not (negative.get("rejections", []) as Array).is_empty()
		evidence["corruptedTransformValidation"] = negative
	else:
		checks["independent_old_plan_ready"] = _ready(old_plan, inputs.intents.size())
		checks["known_seed_exact_placements_preserved"] = var_to_bytes(old_plan.get("placements")) == var_to_bytes(plan.get("placements"))
		checks["known_seed_complete_plan_preserved"] = var_to_bytes(old_plan) == var_to_bytes(plan)
		print("PACKING COUPLING: independent old builder snapshot")
		var old_built: Dictionary = old_builder.build_with_diagnostics(seed, context)
		print("PACKING COUPLING: current builder snapshot")
		var built: Dictionary = Builder.build_with_diagnostics(seed, context)
		checks["both_builders_produce_source"] = old_built.get("blueprint") != null and built.get("blueprint") != null
		if checks.both_builders_produce_source:
			var old_snapshot: Dictionary = old_built.blueprint.snapshot()
			var snapshot: Dictionary = built.blueprint.snapshot()
			checks["complete_source_snapshot_byte_identical"] = var_to_bytes(old_snapshot) == var_to_bytes(snapshot)
			checks["complete_source_recipe_byte_identical"] = var_to_bytes(old_built.blueprint.recipe) == var_to_bytes(built.blueprint.recipe)
			evidence["sourceSnapshots"] = {"oldSha256": Codec.hash_variant(old_snapshot), "currentSha256": Codec.hash_variant(snapshot), "oldRecipeSha256": Codec.hash_variant(old_built.blueprint.recipe), "currentRecipeSha256": Codec.hash_variant(built.blueprint.recipe), "partCount": built.blueprint.parts.size()}
			if seed == 208159:
				checks["historical_208159_snapshot_hash_unchanged"] = Codec.hash_variant(snapshot) == "6caefa897a3cdd38492c899684535c8e1ed02153a8974d4e2c715102ffa307c0"
	var passed: bool = checks.values().all(func(value): return bool(value))
	var report := {"schema": "castle_district_packing_coupling_contract/v1", "evidenceLevel": "source_geometry_contract", "complete": true, "passed": passed, "seed": seed, "context": context, "checks": checks, "evidence": evidence, "elapsedMs": Time.get_ticks_msec() - started, "inputSha256": input_hash, "sources": {"plannerSha256": FileAccess.get_sha256("res://scripts/buildings/CastleCourtyardDistrictPlacementPlanner.gd"), "builderSha256": FileAccess.get_sha256("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd"), "oldPlannerSha256": FileAccess.get_sha256(baseline_dir.path_join("old-planner.gd")), "oldBuilderSha256": FileAccess.get_sha256(baseline_dir.path_join("old-builder.gd"))}, "doesNotProve": ["No rendered visuals, live physics, NPC routing, publication, full CitadelRecipePreparation, terrain, saving or runtime performance acceptance.", "Input reconstruction uses shared sampler and builder helpers, matching the existing district contract; it is not a live-world test.", "Pre-patch builder snapshots share unchanged production dependencies; they isolate this planner trigger change, not the entire historical application."]}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("PACKING COUPLING: ", "PASS" if passed else "FAIL", " seed=", seed, " checks=", JSON.stringify(checks))
	quit(0 if passed else 1)

func _plan(planner, inputs: Dictionary) -> Dictionary:
	return planner.plan(inputs.intents, inputs.streetRecords, inputs.structureParts, inputs.courtyardBounds, OPTIONS)

func _ready(plan: Dictionary, count: int) -> bool:
	return plan.get("status") == "ready" and int(plan.get("placementCount", -1)) == count and (plan.get("placements", []) as Array).size() == count and int(plan.get("unresolvedIntentCount", -1)) == 0 and (plan.get("rejections", []) as Array).is_empty() and bool((plan.get("validation", {}) as Dictionary).get("passed", false))

func _summary(plan: Dictionary) -> Dictionary:
	var summary: Dictionary = plan.duplicate(true)
	summary.erase("placements")
	summary["completePlacementSha256"] = Codec.hash_variant(plan.get("placements", []))
	return summary

func _fixed_axis_trigger(rejections: Array) -> bool:
	var street_ids: Array[String] = []
	var prior_count := 0
	for rejection in rejections:
		if rejection.get("intentId") != FAILED_INTENT:
			return false
		var details: Dictionary = rejection.get("details", {})
		if rejection.get("code") == "street_overlap":
			street_ids.append(String(details.get("streetId", "")))
		elif rejection.get("code") == "prior_residence_overlap":
			prior_count += 1
			if details.get("priorResidenceId") != "courtyard_barracks_002_left" or absf(float(details.get("fixedPackDeltaX", 0.0))) <= Planner.EPSILON or not is_zero_approx(float(details.get("rowPackDeltaZ", 1.0))) or not is_zero_approx(float(details.get("boundaryDeltaX", 1.0))) or not is_zero_approx(float(details.get("boundaryDeltaZ", 1.0))) or bool(details.get("overlapAfterRowPack", true)) or not bool(details.get("overlapAfterFixedPack", false)):
				return false
		else:
			return false
	street_ids.sort()
	return rejections.size() == 3 and prior_count == 1 and street_ids == ["processional_02b_civic_climb", "processional_03_final_turn"]

func _input_hash(inputs: Dictionary) -> String:
	var records: Array = []
	for intent in inputs.intents:
		var record: Dictionary = intent.duplicate(true)
		record["sourceBlueprint"] = intent.sourceBlueprint.snapshot()
		records.append(record)
	return Codec.hash_variant([records, inputs.streetRecords, inputs.structureParts, inputs.courtyardBounds])

func _ordinary_inputs(seed: int, input_context: Dictionary) -> Dictionary:
	var context := input_context.duplicate(true)
	var compound: Dictionary = Sampler.sample_compound(seed, "castle", context)
	var members: Array = compound.get("members", []) as Array
	var grammar: Dictionary = compound.get("castleGrammar", {}) as Dictionary
	var keep_recipe: Dictionary = Builder.member_recipe(members, "keep")
	var courtyard_recipe: Dictionary = Builder.member_recipe(members, "courtyard")
	var tower_recipes: Array = Builder.member_recipes(members, "tower")
	if keep_recipe.is_empty() or courtyard_recipe.is_empty():
		return {"ready": false, "reason": "missing_sampled_castle_members"}
	var courtyard_width := float(grammar.get("courtyardWidth", courtyard_recipe.get("width", 46.0)))
	var courtyard_depth := float(grammar.get("courtyardDepth", courtyard_recipe.get("depth", 42.0)))
	var tower_span := float(grammar.get("towerSpan", (tower_recipes[0] as Dictionary).get("width", 6.4) if not tower_recipes.is_empty() else 6.4))
	var tower_count := clampi(int(grammar.get("towerCount", 4)), 4, 8)
	var tower_height_base := float(grammar.get("towerHeightBase", float((tower_recipes[0] as Dictionary).get("floorHeight", 3.6)) * 3.4 if not tower_recipes.is_empty() else 12.4))
	var tower_height_variation := float(grammar.get("towerHeightVariation", 0.16))
	var keep_width := minf(float(grammar.get("keepWidth", float(keep_recipe.get("width", 26.0)) * 0.52)), courtyard_width - tower_span * 2.50)
	var keep_depth := minf(float(grammar.get("keepDepth", float(keep_recipe.get("depth", 24.0)) * 0.48)), courtyard_depth - tower_span * 2.50)
	var keep_height := float(grammar.get("keepHeight", float(keep_recipe.get("floorHeight", 3.7)) * float(maxi(3, int(keep_recipe.get("floorCount", 4))))))
	var keep_reference_floor_height := clampf(float(keep_recipe.get("floorHeight", 3.70)), 3.20, 4.20)
	var keep_storey_count := clampi(roundi(keep_height / keep_reference_floor_height), 3, 24)
	var keep_floor_height := keep_height / float(keep_storey_count)
	var foundation_height := 0.62
	var keep_foundation_height := foundation_height + Builder.citadel_keep_terrace_elevation(grammar)
	var keep_offset: Dictionary = grammar.get("keepOffset", {}) as Dictionary
	var keep_center := Vector3(0.0, 0.0, courtyard_depth * float(keep_offset.get("z", 0.14)))
	var variation := float(seed % 19) / 100.0 - 0.09
	var masonry_palette: Dictionary = grammar.get("citadelMasonry", {}) as Dictionary
	var fortification_material := String(masonry_palette.get("fortification", "fired_brick"))
	var palace_grammar: Dictionary = grammar.get("palaceGrammar", {}) as Dictionary
	var tower_specs: Array[Dictionary] = Builder.tower_specs_for_grammar(seed, courtyard_width, courtyard_depth, tower_count, tower_span, tower_height_base, tower_height_variation, int(grammar.get("towerPhase", 0)))
	var source_blueprint = Blueprint.new("compound.castle.%d.%s" % [seed, String(context.siteKey)], seed, "masonry")
	Builder.add_keep(source_blueprint, keep_center, keep_width, keep_depth, keep_height, keep_storey_count, keep_floor_height, keep_foundation_height, variation, fortification_material, palace_grammar)
	for index in range(tower_specs.size()):
		var tower_spec: Dictionary = tower_specs[index]
		Builder.add_tower(source_blueprint, "castle_tower_%02d" % (index + 1), tower_spec.get("position", Vector3.ZERO) as Vector3, float(tower_spec.get("span", tower_span)), float(tower_spec.get("height", tower_height_base)), foundation_height, variation + float(index) * 0.006, fortification_material)
	var structure_parts: Array[Dictionary] = Builder.keep_collision_footprints(source_blueprint.parts)
	var program: Array = grammar.get("courtyardProgram", []) as Array
	var grid: Dictionary = grammar.get("courtyardGrid", {}) as Dictionary
	var lot_pairs: Array = grid.get("lotPairs", []) as Array
	var street_records: Array = grid.get("streetRecords", []) as Array
	if String(grid.get("mode", "")) != "district_grid" or program.size() != lot_pairs.size() * 2 or street_records.is_empty():
		return {"ready": false, "reason": "invalid_sampled_district_domain", "programCount": program.size(), "lotPairCount": lot_pairs.size(), "streetCount": street_records.size()}
	var intents: Array = []
	for index in range(0, program.size(), 2):
		var pair_index := index >> 1
		var lot_pair: Dictionary = lot_pairs[pair_index]
		var sources: Array = [program[index], program[index + 1]]
		for side_index in range(2):
			var source: Dictionary = sources[side_index]
			var side := "left" if side_index == 0 else "right"
			if not Builder.sampled_district_lot_binding_valid(source, lot_pair, side) or not Builder.sampled_residence_authority_valid(source, lot_pair, side):
				return {"ready": false, "reason": "sampled_authority_mismatch", "pairIndex": pair_index, "side": side}
			var identity := String(source.get("id", ""))
			var family := String(source.get("residenceFamily", ""))
			var recipe: Dictionary = (source.get("residenceRecipe", {}) as Dictionary).duplicate(true)
			var residence_blueprint = Builder.courtyard_residence_blueprint_from_recipe(family, recipe)
			if residence_blueprint == null:
				return {"ready": false, "reason": "source_blueprint_failed", "intentId": identity}
			var source_spec := source.duplicate(true)
			source_spec["residenceFacadeMaterial"] = Builder.residence_facade_material(seed, identity, masonry_palette)
			intents.append({
				"id": identity,
				"pairIndex": pair_index,
				"side": side,
				"family": family,
				"recipe": recipe,
				"recipeHash": String(source.get("residenceRecipeHash", "")),
				"sourceBlueprint": residence_blueprint,
				"sourceBlueprintSignature": residence_blueprint.deterministic_signature(),
				"sourceSpec": source_spec,
				"nominalCenter": Vector3(float(source.get("gridCenterX")), 0.0, float(source.get("gridCenterZ"))),
				"frontDirection": String(source.get("frontDirection", "")),
				"elevation": float(source.get("terraceElevation")),
				"foundationElevation": foundation_height
			})
	return {
		"ready": intents.size() == program.size(),
		"compound": compound,
		"grammar": grammar,
		"program": program,
		"lotPairs": lot_pairs,
		"streetRecords": street_records,
		"structureParts": structure_parts,
		"intents": intents,
		"courtyardBounds": {"minX": -courtyard_width * 0.5, "maxX": courtyard_width * 0.5, "minZ": -courtyard_depth * 0.5, "maxZ": courtyard_depth * 0.5},
		"sourceBlueprintPartCount": source_blueprint.parts.size(),
		"sourceBlueprintSignature": source_blueprint.deterministic_signature()
	}



