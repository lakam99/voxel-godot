extends SceneTree

## Focused repair contract for the ordinary castle sampler/builder/planner
## handoff. It reconstructs production inputs exactly, proves the repaired seed,
## and pins the previously accepted seed without becoming gameplay evidence.

const Builder := preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Blueprint := preload("res://scripts/buildings/BuildingBlueprint.gd")
const Sampler := preload("res://scripts/buildings/LandmarkBuildingRecipeSampler.gd")
const Planner := preload("res://scripts/buildings/CastleCourtyardDistrictPlacementPlanner.gd")
const Codec := preload("res://scripts/testing/buildings/CitadelStructuralComposerCheckpointCodec.gd")

const FIXED_SEED := 237207443
const KNOWN_ACCEPTED_SEED := 208159
const EXPECTED_INTENT_COUNT := 14
const CONTEXT := {
	"biome": "forest",
	"siteKey": "river-citadel",
	"citadelScale": 1.25,
	"settlementTier": "city",
	"style": "masonry"
}
const OPTIONS := {
	"fixedClearance": 0.04,
	"residenceClearance": 0.08,
	"pairClearance": 2.60,
	"boundaryClearance": 0.90
}
const EXPECTED_REPAIR_SOURCE_KINDS := ["staged_centers", "courtyard_edges", "fixed_blocker_edges", "prior_residence_edges"]
const EXPECTED_REPAIR_CANDIDATE_CAP := 1024
const MAXIMUM_REPORT_BYTES := 2 * 1024 * 1024
const PHASE_A06_REPORT_SHA256 := "8190c5f2da40cda3afa9f580c8260536a9bd2a3741a14dac56359b98f8231835"
const PHASE_B03_REPORT_SHA256 := "b03c465807c25869c209cf302095b49168b0a309b1b60eda07483dddb9a72c94"
const KNOWN_SOURCE_SNAPSHOT_SHA256 := "6caefa897a3cdd38492c899684535c8e1ed02153a8974d4e2c715102ffa307c0"
const KNOWN_SOURCE_RECIPE_SHA256 := "0fabe5afcb479851848a00c17b44faa789a6e0757bb41141605c4de2ce122ff3"
const SAMPLER_SOURCE_SHA256 := "a6a747e89f812d4e92c53c51febe1f294f8dca790655a9f042d29b850531afbc"
const COMPOSER_SOURCE_SHA256 := "3c74700e15eca8d7c2cf25e065d942f55866a765bc7a02796380c8aa9e6328d6"
const PHASE_A06_REPORT_PATH := "res://artifacts/citadel-visual-reset/structural-composer-phase-a-06/phase-a-report.json"
const PHASE_B03_REPORT_PATH := "res://artifacts/citadel-visual-reset/structural-composer-phase-b-03/phase-b-report.json"
const FAILED_CONTRACT_02_REPORT_PATH := "res://artifacts/citadel-visual-reset/district-placement-repair-contract-02/report.json"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var report_path := OS.get_environment("VOXEL_DISTRICT_PLACEMENT_DIAGNOSTIC_REPORT").simplify_path()
	if report_path.is_empty() or not report_path.is_absolute_path() or FileAccess.file_exists(report_path):
		quit(2)
		return
	if OS.get_environment("VOXEL_DISTRICT_PLACEMENT_REPORT_PREFLIGHT") == "1":
		var preflight_result := _write_report(report_path, {
			"schema": "castle_courtyard_district_placement_report_preflight/v1",
			"evidenceLevel": "write_preflight_only",
			"passed": true,
			"doesNotProve": ["Does not construct or validate a castle, district plan, or production behavior."]
		})
		print("CASTLE COURTYARD DISTRICT REPORT PREFLIGHT: %s" % JSON.stringify(preflight_result))
		quit(0 if bool(preflight_result.get("passed", false)) else 2)
		return
	if OS.get_environment("VOXEL_DISTRICT_PLACEMENT_REPORT_SIZE_DIAGNOSTIC") == "1":
		var size_diagnostic := _report_size_diagnostic()
		var diagnostic_write := _write_report(report_path, size_diagnostic)
		print("CASTLE COURTYARD DISTRICT REPORT SIZE DIAGNOSTIC: %s" % JSON.stringify(diagnostic_write))
		quit(0 if bool(size_diagnostic.get("passed", false)) and bool(diagnostic_write.get("passed", false)) else 2)
		return
	var target_inputs := _ordinary_inputs(FIXED_SEED)
	var known_inputs := _ordinary_inputs(KNOWN_ACCEPTED_SEED)
	if not bool(target_inputs.get("ready", false)) or not bool(known_inputs.get("ready", false)):
		var early_write := _write_report(report_path, {
			"schema": "castle_courtyard_district_placement_repair_contract/v1",
			"evidenceLevel": "focused_contract",
			"seed": FIXED_SEED,
			"passed": false,
			"reason": "input_reconstruction_failed",
			"targetInputDiagnostics": _sanitize(target_inputs),
			"knownInputDiagnostics": _sanitize(known_inputs),
			"doesNotProve": _disclaimer()
		})
		if not bool(early_write.get("passed", false)):
			print("CASTLE COURTYARD DISTRICT REPORT WRITE FAILURE: %s" % JSON.stringify(early_write))
		quit(1 if bool(early_write.get("passed", false)) else 2)
		return
	var intents: Array = target_inputs.intents
	var streets: Array = target_inputs.streetRecords
	var structures: Array = target_inputs.structureParts
	var bounds: Dictionary = target_inputs.courtyardBounds
	var authority_before := _intent_authority_manifest(intents)
	var plan: Dictionary = Planner.plan(intents, streets, structures, bounds, OPTIONS)
	var trace: Dictionary = _trace_plan(intents, streets, structures, bounds)
	var authority_after := _intent_authority_manifest(intents)
	var variants := _source_order_variants(intents, streets, structures, bounds)
	var target_telemetry: Dictionary = plan.get("telemetry", {}) as Dictionary
	var synthetic_controls := _synthetic_coupled_controls(intents)
	var synthetic_edge_repair: Dictionary = synthetic_controls.get("edgeRepair", {}) as Dictionary
	var synthetic_no_solution: Dictionary = synthetic_controls.get("noSolution", {}) as Dictionary
	var builder_result: Dictionary = Builder.build_with_diagnostics(FIXED_SEED, CONTEXT)
	var builder_diagnostics: Dictionary = builder_result.get("diagnostics", {}) as Dictionary
	var plan_summary := _plan_without_placements(plan)
	var impossible_intents: Array = [intents[0], intents[1]] if intents.size() >= 2 else []
	var impossible_plan: Dictionary = Planner.plan(impossible_intents, [], [], {
		"minX": -0.5, "maxX": 0.5, "minZ": -0.5, "maxZ": 0.5
	}, OPTIONS)
	var known_plan: Dictionary = Planner.plan(known_inputs.intents as Array, known_inputs.streetRecords as Array, known_inputs.structureParts as Array, known_inputs.courtyardBounds as Dictionary, OPTIONS)
	var known_builder: Dictionary = Builder.build_with_diagnostics(KNOWN_ACCEPTED_SEED, CONTEXT)
	var known_blueprint = known_builder.get("blueprint")
	var known_snapshot_sha := Codec.hash_variant(known_blueprint.snapshot()) if known_blueprint != null else ""
	var known_recipe_sha := Codec.hash_variant(known_blueprint.recipe) if known_blueprint != null else ""
	var source_manifest := _source_manifest()
	var rejection_bound := streets.size() + structures.size() + intents.size() + 1
	var checks := {
		"fixed_seed_is_ready_14_of_14": _ready_plan(plan, EXPECTED_INTENT_COUNT),
		"fixed_seed_preserves_target_authority": authority_before == authority_after and _placements_preserve_authority(plan, authority_before),
		"exact_replay_matches_ready_plan_and_telemetry": bool(trace.get("passed", false)) and String(trace.get("phase", "")) == "ready" \
			and _canonical_json(trace.get("priorPlacements", [])).to_utf8_buffer() == _canonical_json(plan.get("placements", [])).to_utf8_buffer() \
			and _canonical_json(trace.get("telemetry", {})).to_utf8_buffer() == _canonical_json(plan.get("telemetry", {})).to_utf8_buffer(),
		"builder_uses_exact_ready_plan": _ready_builder_projection_matches(builder_result, builder_diagnostics, plan_summary, EXPECTED_INTENT_COUNT),
		"intent_reversal_is_byte_identical": _plans_and_telemetry_byte_identical(plan, variants.intentReversed as Dictionary),
		"street_reversal_is_byte_identical": _plans_and_telemetry_byte_identical(plan, variants.streetReversed as Dictionary),
		"structure_reversal_is_byte_identical": _plans_and_telemetry_byte_identical(plan, variants.structureReversed as Dictionary),
		"all_source_reversals_are_byte_identical": _plans_and_telemetry_byte_identical(plan, variants.allReversed as Dictionary),
		"repair_telemetry_schema_cap_selection_trigger_source": _repair_telemetry_valid(target_telemetry, true, true, false),
		"synthetic_boundary_domain_edge_repair_succeeds": bool(synthetic_edge_repair.get("passed", false)) \
			and _repair_telemetry_valid(synthetic_edge_repair.get("telemetry", {}) as Dictionary, true, true, false) \
			and bool(synthetic_edge_repair.get("selectedFromTriggerEdge", false)),
		"synthetic_coupled_no_solution_exhausts_and_fails_closed": not bool(synthetic_no_solution.get("passed", true)) \
			and _repair_telemetry_valid(synthetic_no_solution.get("telemetry", {}) as Dictionary, true, false, true),
		"telemetry_and_rejections_are_bounded": (plan.get("rejections", []) as Array).size() <= rejection_bound and _telemetry_within_declared_bounds(target_telemetry),
		"synthetic_impossible_domain_fails_closed": String(impossible_plan.get("status", "")) == "infeasible" and not (impossible_plan.get("rejections", []) as Array).is_empty(),
		"known_seed_fast_path_uses_zero_candidates": _ready_plan(known_plan, (known_inputs.intents as Array).size()) and _repair_telemetry_valid(known_plan.get("telemetry", {}) as Dictionary, false, false, false),
		"known_seed_source_matches_phase_a06": known_snapshot_sha == KNOWN_SOURCE_SNAPSHOT_SHA256 and known_recipe_sha == KNOWN_SOURCE_RECIPE_SHA256,
		"phase_evidence_and_source_manifest_are_immutable": bool(source_manifest.get("passed", false)),
		"structure_descriptors_reconstruct_exact_bounds": _structure_bounds_are_exact(structures) and _structure_bounds_are_exact(known_inputs.structureParts as Array),
		"ordinary_input_provenance_is_complete": _input_provenance_complete(target_inputs) and _input_provenance_complete(known_inputs)
	}
	var report := {
		"schema": "castle_courtyard_district_placement_repair_contract/v1",
		"evidenceLevel": "focused_contract",
		"seed": FIXED_SEED,
		"passed": checks.values().all(func(value): return bool(value)),
		"checks": checks,
		"target": _bounded_plan_evidence(plan),
		"exactReplay": {"passed": bool(trace.get("passed", false)), "phase": String(trace.get("phase", "")), "placementSha256": _canonical_json(trace.get("priorPlacements", [])).sha256_text(), "telemetrySha256": _canonical_json(trace.get("telemetry", {})).sha256_text()},
		"builderDiagnostics": _sanitize(builder_diagnostics),
		"sourceOrderVariants": _variant_evidence(variants),
		"syntheticCoupledControls": _sanitize(synthetic_controls),
		"syntheticImpossibleControl": _bounded_plan_evidence(impossible_plan),
		"knownAcceptedSeed": {"seed": KNOWN_ACCEPTED_SEED, "plan": _bounded_plan_evidence(known_plan), "sourceSnapshotSha256": known_snapshot_sha, "sourceRecipeSha256": known_recipe_sha},
		"sourceManifest": source_manifest,
		"inputProvenance": {"target": _input_provenance(target_inputs), "knownAccepted": _input_provenance(known_inputs)},
		"bounds": {
			"rejectionCount": (plan.get("rejections", []) as Array).size(),
			"maximumRejectionCount": rejection_bound,
			"intentCount": intents.size(),
			"streetCount": streets.size(),
			"structureCount": structures.size()
		},
		"doesNotProve": _disclaimer()
	}
	checks["complete_report_contains_no_objects"] = not _contains_object(report)
	var report_byte_count := JSON.stringify(_sanitize(report), "\t").to_utf8_buffer().size()
	checks["complete_report_is_bounded"] = report_byte_count <= MAXIMUM_REPORT_BYTES
	report["reportByteCountBeforeFinalChecks"] = report_byte_count
	report["maximumReportBytes"] = MAXIMUM_REPORT_BYTES
	report["passed"] = checks.values().all(func(value): return bool(value))
	var write_result := _write_report(report_path, _sanitize(report))
	if not bool(write_result.get("passed", false)):
		print("CASTLE COURTYARD DISTRICT REPORT WRITE FAILURE: %s" % JSON.stringify(write_result))
		quit(2)
		return
	print("CASTLE COURTYARD DISTRICT PLACEMENT REPAIR CONTRACT: %s" % ("PASS" if report.passed else "FAIL"))
	quit(0 if report.passed else 1)


func _ready_plan(plan: Dictionary, expected_count: int) -> bool:
	return String(plan.get("status", "")) == "ready" and int(plan.get("intentCount", -1)) == expected_count \
		and int(plan.get("placementCount", -1)) == expected_count and int(plan.get("unresolvedIntentCount", -1)) == 0 \
		and (plan.get("placements", []) as Array).size() == expected_count and (plan.get("rejections", []) as Array).is_empty() \
		and bool((plan.get("validation", {}) as Dictionary).get("passed", false)) and not String(plan.get("placementSignature", "")).is_empty()


func _plan_without_placements(plan: Dictionary) -> Dictionary:
	var result := plan.duplicate(true)
	result.erase("placements")
	return result


func _source_order_variants(intents: Array, streets: Array, structures: Array, bounds: Dictionary) -> Dictionary:
	var reversed_intents := intents.duplicate()
	var reversed_streets := streets.duplicate(true)
	var reversed_structures := structures.duplicate(true)
	reversed_intents.reverse()
	reversed_streets.reverse()
	reversed_structures.reverse()
	return {
		"intentReversed": Planner.plan(reversed_intents, streets, structures, bounds, OPTIONS),
		"streetReversed": Planner.plan(intents, reversed_streets, structures, bounds, OPTIONS),
		"structureReversed": Planner.plan(intents, streets, reversed_structures, bounds, OPTIONS),
		"allReversed": Planner.plan(reversed_intents, reversed_streets, reversed_structures, bounds, OPTIONS)
	}


func _plans_and_telemetry_byte_identical(expected: Dictionary, actual: Dictionary) -> bool:
	return _canonical_json(expected).to_utf8_buffer() == _canonical_json(actual).to_utf8_buffer() \
		and _canonical_json(expected.get("telemetry", {})).to_utf8_buffer() == _canonical_json(actual.get("telemetry", {})).to_utf8_buffer()


func _intent_authority_manifest(intents: Array) -> Array:
	var result: Array = []
	for value in intents:
		var intent: Dictionary = value as Dictionary
		var source_blueprint = intent.get("sourceBlueprint")
		result.append({
			"id": String(intent.get("id", "")), "identity": String(intent.get("id", "")),
			"pairIndex": int(intent.get("pairIndex", -1)), "side": String(intent.get("side", "")),
			"family": String(intent.get("family", "")), "recipeHash": String(intent.get("recipeHash", "")),
			"recipeBytesSha256": _canonical_json(intent.get("recipe", {})).sha256_text(),
			"sourceSpecSha256": _canonical_json(intent.get("sourceSpec", {})).sha256_text(),
			"frontDirection": String(intent.get("frontDirection", "")), "nominalCenter": intent.get("nominalCenter", Vector3.ZERO),
			"elevation": float(intent.get("elevation", 0.0)), "sourceBlueprintSignature": String(intent.get("sourceBlueprintSignature", "")),
			"sourceGeometrySha256": Codec.hash_variant(source_blueprint.snapshot()) if source_blueprint != null else ""
		})
	return result


func _placements_preserve_authority(plan: Dictionary, authority: Array) -> bool:
	var by_id := {}
	for row_value in authority:
		var row: Dictionary = row_value as Dictionary
		by_id[String(row.get("id", ""))] = row
	var placements: Array = plan.get("placements", []) as Array
	if placements.size() != authority.size():
		return false
	for value in placements:
		var placement: Dictionary = value as Dictionary
		var identity := String(placement.get("id", ""))
		if not by_id.has(identity):
			return false
		var source: Dictionary = by_id[identity] as Dictionary
		for key in ["id", "identity", "pairIndex", "side", "family", "recipeHash", "frontDirection", "nominalCenter", "elevation", "sourceBlueprintSignature"]:
			if placement.get(key) != source.get(key):
				return false
		if String(placement.get("compositionSignature", "")).is_empty() or String(placement.get("placementSignature", "")).is_empty():
			return false
	return true


func _ready_builder_projection_matches(result: Dictionary, diagnostics: Dictionary, plan_summary: Dictionary, expected_count: int) -> bool:
	var blueprint = result.get("blueprint")
	var keys := diagnostics.keys()
	keys.sort_custom(func(left, right): return String(left) < String(right))
	var pair_rows: Array = diagnostics.get("postGeometryPairs", []) as Array
	return blueprint != null and keys == ["districtPlacementPlan", "postGeometryPairs"] \
		and diagnostics.get("districtPlacementPlan", {}) == plan_summary and pair_rows.size() * 2 == expected_count \
		and pair_rows.all(func(row): return row is Dictionary and String((row as Dictionary).get("mode", "")) == "post_geometry_exact" \
			and int((row as Dictionary).get("attemptCount", -1)) == 1 and not bool((row as Dictionary).get("fallback", true)) \
			and String((row as Dictionary).get("terminalReason", "")) == "accepted" \
			and not String((row as Dictionary).get("leftPlacementSignature", "")).is_empty() \
			and not String((row as Dictionary).get("rightPlacementSignature", "")).is_empty())


func _repair_telemetry_valid(telemetry: Dictionary, require_trigger: bool, require_selection: bool, require_exhaustion: bool) -> bool:
	var repairs: Array = telemetry.get("coupledRepairs", []) as Array
	var trigger_count := int(telemetry.get("coupledRepairTriggerCount", -1))
	var evaluated_count := int(telemetry.get("coupledCandidateEvaluatedCount", -1))
	if int(telemetry.get("coupledCandidateCapPerTrigger", -1)) != EXPECTED_REPAIR_CANDIDATE_CAP \
			or trigger_count != repairs.size() or trigger_count < 0 \
			or trigger_count > int(telemetry.get("maximumCoupledRepairTriggers", -1)) \
			or evaluated_count < 0 or evaluated_count > int(telemetry.get("maximumCoupledCandidateEvaluations", -1)):
		return false
	if require_trigger and repairs.is_empty():
		return false
	if not require_trigger and (not repairs.is_empty() or evaluated_count != 0):
		return false
	var selected_count := 0
	var exhausted_count := 0
	for value in repairs:
		if not value is Dictionary:
			return false
		var row: Dictionary = value as Dictionary
		var required := ["intentId", "pairIndex", "side", "triggerRejections", "axisCandidateLimit", "candidateCap", "xCandidateCount", "zCandidateCount", "candidateDomainCount", "evaluatedCount", "selectedOrdinal", "selectedCenter", "selectedPlacementSignature", "exhausted", "sourceKinds", "domainSignature", "work"]
		if not required.all(func(key): return row.has(key)) or String(row.get("intentId", "")).is_empty() \
				or String(row.get("side", "")) not in ["left", "right"] or (row.get("triggerRejections", []) as Array).is_empty() \
				or int(row.get("axisCandidateLimit", -1)) != 32 \
				or int(row.get("candidateCap", -1)) != EXPECTED_REPAIR_CANDIDATE_CAP \
				or int(row.get("xCandidateCount", -1)) < 0 or int(row.get("xCandidateCount", 0)) > 32 \
				or int(row.get("zCandidateCount", -1)) < 0 or int(row.get("zCandidateCount", 0)) > 32 \
				or int(row.get("candidateDomainCount", -1)) < 0 or int(row.get("candidateDomainCount", 0)) > EXPECTED_REPAIR_CANDIDATE_CAP \
				or int(row.get("evaluatedCount", -1)) < 0 or int(row.get("evaluatedCount", 0)) > int(row.get("candidateDomainCount", 0)) \
				or row.get("sourceKinds", []) != EXPECTED_REPAIR_SOURCE_KINDS or String(row.get("domainSignature", "")).is_empty():
			return false
		if bool(row.get("exhausted", false)):
			exhausted_count += 1
			if int(row.get("candidateDomainCount", 0)) <= 0 \
					or int(row.get("evaluatedCount", -1)) != int(row.get("candidateDomainCount", 0)) \
					or int(row.get("selectedOrdinal", -1)) != -1 \
					or not String(row.get("selectedPlacementSignature", "")).is_empty():
				return false
		else:
			selected_count += 1
			if int(row.get("selectedOrdinal", -1)) < 0 \
					or int(row.get("selectedOrdinal", -1)) >= int(row.get("evaluatedCount", 0)) \
					or int(row.get("selectedOrdinal", -1)) >= int(row.get("candidateDomainCount", 0)) \
					or String(row.get("selectedPlacementSignature", "")).is_empty() \
					or not row.get("xSource") is Dictionary or not row.get("zSource") is Dictionary \
					or String((row.get("xSource") as Dictionary).get("kind", "")).is_empty() \
					or String((row.get("zSource") as Dictionary).get("kind", "")).is_empty():
				return false
	if require_selection and selected_count == 0:
		return false
	if require_exhaustion and exhausted_count == 0:
		return false
	return true


func _synthetic_coupled_controls(intents: Array) -> Dictionary:
	var intent := _intent_for_id(intents, "courtyard_granary_002_right")
	if intent.is_empty() and not intents.is_empty():
		intent = intents[intents.size() - 1] as Dictionary
	if intent.is_empty():
		return {"edgeRepair": {"passed": false, "reason": "missing_intent"}, "noSolution": {"passed": true, "reason": "missing_intent"}}
	var bounds := {"minX": -25.0, "maxX": 25.0, "minZ": -25.0, "maxZ": 25.0}
	var probe_telemetry := Planner._new_telemetry(1, 0, 0)
	var probe: Dictionary = Planner._describe(intent, Vector3.ZERO, probe_telemetry)
	if not bool(probe.get("passed", false)):
		return {"edgeRepair": {"passed": false, "reason": "probe_description_failed"}, "noSolution": {"passed": true, "reason": "probe_description_failed"}}
	var probe_bounds: Dictionary = Planner._composition_bounds(probe.get("composition", {}) as Dictionary)
	var half_x := (float(probe_bounds.maxX) - float(probe_bounds.minX)) * 0.5
	var offset_x := (float(probe_bounds.minX) + float(probe_bounds.maxX)) * 0.5
	var staged_center := Vector3(float(bounds.maxX) - float(OPTIONS.boundaryClearance) - half_x - offset_x, 0.0, 0.0)
	var staged_telemetry := Planner._new_telemetry(1, 0, 0)
	var staged: Dictionary = Planner._describe(intent, staged_center, staged_telemetry)
	if not bool(staged.get("passed", false)):
		return {"edgeRepair": {"passed": false, "reason": "staged_description_failed"}, "noSolution": {"passed": true, "reason": "staged_description_failed"}}
	var staged_composition: Dictionary = staged.get("composition", {}) as Dictionary
	var staged_bounds: Dictionary = Planner._composition_bounds(staged_composition)
	var staged_aggregate_center := Vector3(
		(float(staged_bounds.minX) + float(staged_bounds.maxX)) * 0.5,
		0.0,
		(float(staged_bounds.minZ) + float(staged_bounds.maxZ)) * 0.5
	)
	var edge_part := {
		"partId": "synthetic_trigger_edge",
		"center": staged_aggregate_center,
		"size": Vector3(2.0, 1000.0, float(staged_bounds.maxZ) - float(staged_bounds.minZ) + 4.0),
		"basis": Basis.IDENTITY
	}
	var edge_telemetry := Planner._new_telemetry(1, 0, 1)
	var edge_fixed_result: Dictionary = Planner._fixed_blockers([], [edge_part], edge_telemetry)
	var nominal_center := staged_center + Vector3(10.0, 0.0, 0.0)
	var trigger := [{"code": "structure_overlap", "phase": "exact_revalidation", "intentId": String(intent.get("id", "")), "pairIndex": int(intent.get("pairIndex", -1)), "side": String(intent.get("side", "")), "details": {"structurePartId": "synthetic_trigger_edge", "structureIndex": 0}}]
	var edge_result := {"passed": false}
	if bool(edge_fixed_result.get("passed", false)):
		edge_result = Planner._resolve_coupled_candidate(
			intent, bounds, OPTIONS, edge_fixed_result.get("blockers", []) as Array[Dictionary], [], [edge_part],
			[], [], [], nominal_center, nominal_center, nominal_center, staged_center, staged_composition, trigger, edge_telemetry
		)
	var edge_repairs: Array = edge_telemetry.get("coupledRepairs", []) as Array
	var edge_record: Dictionary = edge_repairs[0] as Dictionary if edge_repairs.size() == 1 else {}
	var selected_from_trigger_edge := _source_is_trigger_edge(edge_record.get("xSource", {}) as Dictionary) \
		or _source_is_trigger_edge(edge_record.get("zSource", {}) as Dictionary)
	var spanning_part := {
		"partId": "synthetic_spanning_blocker",
		"center": Vector3.ZERO,
		"size": Vector3(50.0, 1000.0, 50.0),
		"basis": Basis.IDENTITY
	}
	var no_solution_telemetry := Planner._new_telemetry(1, 0, 1)
	var spanning_fixed_result: Dictionary = Planner._fixed_blockers([], [spanning_part], no_solution_telemetry)
	var no_solution_result := {"passed": true}
	if bool(spanning_fixed_result.get("passed", false)):
		var spanning_trigger := [{"code": "structure_overlap", "phase": "exact_revalidation", "intentId": String(intent.get("id", "")), "pairIndex": int(intent.get("pairIndex", -1)), "side": String(intent.get("side", "")), "details": {"structurePartId": "synthetic_spanning_blocker", "structureIndex": 0}}]
		no_solution_result = Planner._resolve_coupled_candidate(
			intent, bounds, OPTIONS, spanning_fixed_result.get("blockers", []) as Array[Dictionary], [], [spanning_part],
			[], [], [], nominal_center, nominal_center, nominal_center, staged_center, staged_composition, spanning_trigger, no_solution_telemetry
		)
	return {
		"edgeRepair": {
			"passed": bool(edge_result.get("passed", false)),
			"selectedFromTriggerEdge": selected_from_trigger_edge,
			"telemetry": edge_telemetry.duplicate(true)
		},
		"noSolution": {
			"passed": bool(no_solution_result.get("passed", false)),
			"telemetry": no_solution_telemetry.duplicate(true)
		}
	}


func _source_is_trigger_edge(source: Dictionary) -> bool:
	return String(source.get("kind", "")) == "structure" \
		and String(source.get("id", "")).begins_with("synthetic_trigger_edge:")


func _source_manifest() -> Dictionary:
	var actual := {
		"sampler": FileAccess.get_sha256("res://scripts/buildings/LandmarkBuildingRecipeSampler.gd").to_lower(),
		"composer": FileAccess.get_sha256("res://scripts/buildings/CitadelUrbanPocComposer.gd").to_lower(),
		"phaseA06Report": FileAccess.get_sha256(PHASE_A06_REPORT_PATH).to_lower(),
		"phaseB03Report": FileAccess.get_sha256(PHASE_B03_REPORT_PATH).to_lower()
	}
	var expected := {"sampler": SAMPLER_SOURCE_SHA256, "composer": COMPOSER_SOURCE_SHA256, "phaseA06Report": PHASE_A06_REPORT_SHA256, "phaseB03Report": PHASE_B03_REPORT_SHA256}
	return {"passed": actual == expected, "actual": actual, "expected": expected}


func _structure_bounds_are_exact(structures: Array) -> bool:
	var telemetry := Planner._new_telemetry(0, 0, structures.size())
	var result: Dictionary = Planner._fixed_blockers([], Planner._ordered_structure_parts(structures), telemetry)
	var blockers: Array = result.get("blockers", []) as Array
	if not bool(result.get("passed", false)) or blockers.size() != structures.size():
		return false
	var seen := {}
	for value in blockers:
		var blocker: Dictionary = value as Dictionary
		var identity := String(blocker.get("id", ""))
		var exact_bounds: Dictionary = blocker.get("bounds", {}) as Dictionary
		if identity.is_empty() or seen.has(identity) or Planner._footprint_bounds(exact_bounds).is_empty():
			return false
		seen[identity] = true
	return true


func _bounded_plan_evidence(plan: Dictionary) -> Dictionary:
	var telemetry: Dictionary = plan.get("telemetry", {}) as Dictionary
	return {
		"status": String(plan.get("status", "")), "phase": String(plan.get("phase", "")),
		"intentCount": int(plan.get("intentCount", -1)), "placementCount": int(plan.get("placementCount", -1)),
		"placementSignature": String(plan.get("placementSignature", "")),
		"validationPassed": bool((plan.get("validation", {}) as Dictionary).get("passed", false)),
		"rejections": (plan.get("rejections", []) as Array).slice(0, 32),
		"telemetry": telemetry.duplicate(true), "canonicalPlanSha256": _canonical_json(plan).sha256_text()
	}


func _variant_evidence(variants: Dictionary) -> Dictionary:
	var result := {}
	for key in variants:
		result[String(key)] = _bounded_plan_evidence(variants[key] as Dictionary)
	return result


func _ordinary_inputs(seed: int) -> Dictionary:
	var context := CONTEXT.duplicate(true)
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


func _trace_plan(intents: Array, streets: Array, structures: Array, bounds: Dictionary) -> Dictionary:
	var telemetry: Dictionary = Planner._new_telemetry(intents.size(), streets.size(), structures.size())
	var input_check: Dictionary = Planner._validate_inputs(intents, streets, structures, bounds, OPTIONS)
	if not bool(input_check.get("passed", false)):
		return {"passed": false, "phase": "invalid_input", "rejections": input_check.get("rejections", []), "telemetry": telemetry}
	var settings: Dictionary = input_check.get("settings", {}) as Dictionary
	var ordered_intents: Array[Dictionary] = []
	for value in intents:
		ordered_intents.append(value as Dictionary)
	ordered_intents.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return Planner._intent_precedes(left, right))
	var street_footprints: Array[Dictionary] = []
	for street_value in streets:
		street_footprints.append(Planner._street_footprint(street_value as Dictionary))
	street_footprints.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return String(left.get("id", "")) < String(right.get("id", "")))
	var ordered_structures: Array = Planner._ordered_structure_parts(structures)
	var fixed_result: Dictionary = Planner._fixed_blockers(street_footprints, ordered_structures, telemetry)
	if not bool(fixed_result.get("passed", false)):
		return {"passed": false, "phase": "invalid_obstacle_geometry", "rejections": fixed_result.get("rejections", []), "telemetry": telemetry}
	var fixed_blockers: Array[Dictionary] = fixed_result.get("blockers", []) as Array[Dictionary]
	var placements: Array[Dictionary] = []
	var compositions: Array[Dictionary] = []
	var blockers: Array[Dictionary] = []
	var nominal_centers: Array[Vector3] = []
	for intent in ordered_intents:
		var failed_stages := _placement_stages(intent, bounds, settings, fixed_blockers, placements, blockers, nominal_centers)
		var result: Dictionary = Planner._place_one(intent, bounds, settings, fixed_blockers, street_footprints, ordered_structures, placements, compositions, blockers, nominal_centers, telemetry)
		if not bool(result.get("passed", false)):
			return {
				"passed": false,
				"phase": String(result.get("phase", "placement")),
				"rejections": (result.get("rejections", []) as Array).duplicate(true),
				"failedIntent": intent,
				"failedStages": failed_stages,
				"priorPlacements": placements,
				"priorCompositions": compositions,
				"streetFootprints": street_footprints,
				"orderedStructures": ordered_structures,
				"telemetry": telemetry
			}
		var placement: Dictionary = result.get("placement", {}) as Dictionary
		placements.append(placement)
		compositions.append((placement.get("composition", {}) as Dictionary).duplicate(true))
		blockers.append((result.get("blocker", {}) as Dictionary).duplicate(true))
		nominal_centers.append(intent.get("nominalCenter", Vector3.ZERO) as Vector3)
	return {"passed": true, "phase": "ready", "priorPlacements": placements, "priorCompositions": compositions, "streetFootprints": street_footprints, "orderedStructures": ordered_structures, "telemetry": telemetry}


func _placement_stages(intent: Dictionary, bounds: Dictionary, settings: Dictionary, fixed_blockers: Array[Dictionary], placements: Array[Dictionary], placed_blockers: Array[Dictionary], nominal_centers: Array[Vector3]) -> Dictionary:
	var telemetry := Planner._new_telemetry(1, 0, 0)
	var nominal_center: Vector3 = intent.get("nominalCenter", Vector3.ZERO) as Vector3
	var center := nominal_center
	var description: Dictionary = Planner._describe(intent, center, telemetry)
	if not bool(description.get("passed", false)):
		return {"ready": false, "phase": "description", "reason": description.get("reason", ""), "geometryUnavailable": true, "finalAggregateFootprint": {}}
	var composition: Dictionary = description.get("composition", {}) as Dictionary
	var blocker: Dictionary = Planner._composition_bounds(composition)
	var nominal_composition := composition
	var progression_sign := Planner._progression_sign(nominal_center, nominal_centers, bounds)
	var z_delta := 0.0
	var prior_order: Array[int] = Planner._clearance_adjusted_prior_encounter_order(placed_blockers, placements, int(intent.get("pairIndex", -1)), progression_sign, settings)
	for prior_index in prior_order:
		var prior_pair_index := int(placements[prior_index].get("pairIndex", -2)) if prior_index < placements.size() else -2
		var prior_clearance := float(settings.get("pairClearance", 2.60)) if prior_pair_index == int(intent.get("pairIndex", -1)) else float(settings.get("residenceClearance", 0.08))
		if Planner._footprints_overlap(Planner._shift_bounds(blocker, 0.0, z_delta), placed_blockers[prior_index], prior_clearance):
			z_delta = Planner._monotonic_axis_delta(blocker, placed_blockers[prior_index], "z", progression_sign, prior_clearance, z_delta)
	if absf(z_delta) > 0.00001:
		center.z += z_delta
		description = Planner._describe(intent, center, telemetry)
		if not bool(description.get("passed", false)):
			return {"ready": false, "phase": "row_pack", "reason": description.get("reason", ""), "geometryUnavailable": true, "finalAggregateFootprint": {}}
		composition = description.get("composition", {}) as Dictionary
		blocker = Planner._composition_bounds(composition)
	var row_center := center
	var row_composition := composition
	var outward_sign := Planner._outward_sign(nominal_center, bounds)
	if outward_sign == 0:
		return {"ready": false, "phase": "fixed_pack", "reason": "ambiguous_outward_domain", "nominalCenter": nominal_center, "rowPackedCenter": row_center, "finalCenter": center, "finalAggregateFootprint": (composition.get("aggregateFootprint", {}) as Dictionary).duplicate(true)}
	var x_delta := 0.0
	for fixed in fixed_blockers:
		var fixed_bounds: Dictionary = fixed.get("bounds", {}) as Dictionary
		if Planner._footprints_overlap(Planner._shift_bounds(blocker, x_delta, 0.0), fixed_bounds, float(settings.get("fixedClearance", 0.04))):
			x_delta = Planner._monotonic_axis_delta(blocker, fixed_bounds, "x", outward_sign, float(settings.get("fixedClearance", 0.04)), x_delta)
	if absf(x_delta) > 0.00001:
		center.x += x_delta
		description = Planner._describe(intent, center, telemetry)
		if not bool(description.get("passed", false)):
			return {"ready": false, "phase": "fixed_pack", "reason": description.get("reason", ""), "geometryUnavailable": true, "finalAggregateFootprint": {}}
		composition = description.get("composition", {}) as Dictionary
		blocker = Planner._composition_bounds(composition)
	var fixed_center := center
	var fixed_composition := composition
	var boundary: Dictionary = Planner._boundary_adjustment(blocker, bounds, float(settings.get("boundaryClearance", 0.90)))
	if not bool(boundary.get("possible", false)):
		return {"ready": false, "phase": "boundary", "reason": "composition_exceeds_courtyard_domain", "nominalCenter": nominal_center, "rowPackedCenter": row_center, "fixedPackedCenter": fixed_center, "finalCenter": fixed_center, "rowPackDeltaZ": row_center.z - nominal_center.z, "fixedPackDeltaX": fixed_center.x - row_center.x, "boundaryDeltaX": 0.0, "boundaryDeltaZ": 0.0, "finalAggregateFootprint": (composition.get("aggregateFootprint", {}) as Dictionary).duplicate(true)}
	var adjustment: Vector2 = boundary.get("delta", Vector2.ZERO) as Vector2
	if adjustment.length_squared() > 0.00001 * 0.00001:
		center.x += adjustment.x
		center.z += adjustment.y
		description = Planner._describe(intent, center, telemetry)
		if not bool(description.get("passed", false)):
			return {"ready": false, "phase": "boundary", "reason": description.get("reason", ""), "geometryUnavailable": true, "finalAggregateFootprint": {}}
		composition = description.get("composition", {}) as Dictionary
	return {
		"ready": true,
		"nominalCenter": nominal_center,
		"rowPackedCenter": row_center,
		"fixedPackedCenter": fixed_center,
		"finalCenter": center,
		"rowPackDeltaZ": row_center.z - nominal_center.z,
		"fixedPackDeltaX": fixed_center.x - row_center.x,
		"boundaryDeltaX": center.x - fixed_center.x,
		"boundaryDeltaZ": center.z - fixed_center.z,
		"nominalAggregateFootprint": (nominal_composition.get("aggregateFootprint", {}) as Dictionary).duplicate(true),
		"rowPackedAggregateFootprint": (row_composition.get("aggregateFootprint", {}) as Dictionary).duplicate(true),
		"fixedPackedAggregateFootprint": (fixed_composition.get("aggregateFootprint", {}) as Dictionary).duplicate(true),
		"finalComposition": composition.duplicate(true),
		"finalAggregateFootprint": (composition.get("aggregateFootprint", {}) as Dictionary).duplicate(true)
	}


func _enrich_rejection(rejection: Dictionary, inputs: Dictionary, trace: Dictionary) -> Dictionary:
	var result := rejection.duplicate(true)
	var intent := _intent_for_id(inputs.intents as Array, String(rejection.get("intentId", "")))
	if intent.is_empty() and trace.get("failedIntent", null) is Dictionary:
		intent = trace.failedIntent as Dictionary
	var pair_index := int(rejection.get("pairIndex", intent.get("pairIndex", -1)))
	var lot_pair: Dictionary = (inputs.lotPairs as Array)[pair_index] as Dictionary if pair_index >= 0 and pair_index < (inputs.lotPairs as Array).size() else {}
	var details: Dictionary = rejection.get("details", {}) as Dictionary
	var failed_stages: Dictionary = trace.get("failedStages", {}) as Dictionary
	var displacement_stages := failed_stages.duplicate(true)
	displacement_stages.erase("finalComposition")
	for key in ["nominalCenter", "rowPackedCenter", "fixedPackedCenter", "finalCenter", "rowPackDeltaZ", "fixedPackDeltaX", "boundaryDeltaX", "boundaryDeltaZ", "overlapAfterRowPack", "overlapAfterFixedPack"]:
		if details.has(key):
			displacement_stages["annotated_%s" % key] = details[key]
	result["sampledLotPair"] = lot_pair.duplicate(true)
	result["residence"] = _intent_summary(intent)
	result["transformedAggregateFootprint"] = (failed_stages.get("finalAggregateFootprint", {}) as Dictionary).duplicate(true)
	result["courtyardBounds"] = (inputs.courtyardBounds as Dictionary).duplicate(true)
	result["displacementStages"] = displacement_stages
	result["relevantStreet"] = _street_context(String(details.get("streetId", "")), inputs.streetRecords as Array)
	result["relevantStructure"] = _structure_context(details, trace.get("orderedStructures", []) as Array)
	result["relevantPriorResidence"] = _prior_context(details, trace)
	return result


func _intent_summary(intent: Dictionary) -> Dictionary:
	if intent.is_empty():
		return {}
	var recipe: Dictionary = intent.get("recipe", {}) as Dictionary
	return {
		"id": String(intent.get("id", "")),
		"pairIndex": int(intent.get("pairIndex", -1)),
		"side": String(intent.get("side", "")),
		"family": String(intent.get("family", "")),
		"recipeHash": String(intent.get("recipeHash", "")),
		"sourceBlueprintSignature": String(intent.get("sourceBlueprintSignature", "")),
		"recipeDimensions": {"width": recipe.get("width"), "depth": recipe.get("depth"), "foundationHeight": recipe.get("foundationHeight")},
		"frontDirection": String(intent.get("frontDirection", "")),
		"nominalCenter": intent.get("nominalCenter", Vector3.ZERO),
		"elevation": intent.get("elevation"),
		"sourceSpec": (intent.get("sourceSpec", {}) as Dictionary).duplicate(true)
	}


func _street_context(street_id: String, streets: Array) -> Dictionary:
	if street_id.is_empty():
		return {}
	for value in streets:
		var street: Dictionary = value as Dictionary
		if String(street.get("id", "")) == street_id:
			return {"record": street.duplicate(true), "footprint": Planner._street_footprint(street)}
	return {"missingStreetId": street_id}


func _structure_context(details: Dictionary, structures: Array) -> Dictionary:
	var structure_id := String(details.get("structurePartId", ""))
	var structure_index := int(details.get("structureIndex", -1))
	if structure_index >= 0 and structure_index < structures.size():
		return _exact_structure_context(structure_id, structure_index, structures[structure_index] as Dictionary)
	if not structure_id.is_empty():
		for index in range(structures.size()):
			if Planner._part_id(structures[index]) == structure_id:
				return _exact_structure_context(structure_id, index, structures[index] as Dictionary)
		return {"missingStructureId": structure_id}
	return {}


func _exact_structure_context(structure_id: String, index: int, descriptor: Dictionary) -> Dictionary:
	var telemetry := Planner._new_telemetry(0, 0, 1)
	var fixed: Dictionary = Planner._fixed_blockers([], [descriptor], telemetry)
	var blockers: Array = fixed.get("blockers", []) as Array
	return {
		"id": structure_id,
		"index": index,
		"descriptor": descriptor.duplicate(true),
		"horizontalBounds": ((blockers[0] as Dictionary).get("bounds", {}) as Dictionary).duplicate(true) if bool(fixed.get("passed", false)) and blockers.size() == 1 else {}
	}


func _prior_context(details: Dictionary, trace: Dictionary) -> Dictionary:
	var prior_index := int(details.get("priorIndex", -1))
	var placements: Array = trace.get("priorPlacements", []) as Array
	var compositions: Array = trace.get("priorCompositions", []) as Array
	if prior_index < 0 or prior_index >= placements.size() or prior_index >= compositions.size():
		return {} if String(details.get("priorResidenceId", "")).is_empty() else {"missingPriorResidenceId": details.get("priorResidenceId", "")}
	var placement: Dictionary = placements[prior_index]
	var composition: Dictionary = compositions[prior_index]
	var failed_intent: Dictionary = trace.get("failedIntent", {}) as Dictionary
	var clearance := float(OPTIONS.pairClearance) if int(placement.get("pairIndex", -2)) == int(failed_intent.get("pairIndex", -1)) else float(OPTIONS.residenceClearance)
	return {
		"id": String(placement.get("id", "")),
		"index": prior_index,
		"pairIndex": int(placement.get("pairIndex", -1)),
		"clearance": clearance,
		"placement": placement.duplicate(true),
		"aggregateFootprint": (composition.get("aggregateFootprint", {}) as Dictionary).duplicate(true)
	}


func _input_provenance(inputs: Dictionary) -> Dictionary:
	var intents: Array = inputs.intents as Array
	var lot_pairs: Array = inputs.lotPairs as Array
	var streets: Array = inputs.streetRecords as Array
	var structures: Array = inputs.structureParts as Array
	var source_specs: Array = []
	for value in intents:
		source_specs.append(((value as Dictionary).get("sourceSpec", {}) as Dictionary).duplicate(true))
	var compact_authority := _compact_intent_authority_manifest(intents)
	var source_blueprint_signature := String(inputs.sourceBlueprintSignature)
	return {
		"intentCount": intents.size(),
		"lotPairCount": lot_pairs.size(),
		"streetCount": streets.size(),
		"structureCount": structures.size(),
		"sourceBlueprintPartCount": int(inputs.sourceBlueprintPartCount),
		"sourceBlueprintSignatureSha256": source_blueprint_signature.sha256_text(),
		"sourceBlueprintSignatureBytes": source_blueprint_signature.to_utf8_buffer().size(),
		"courtyardBounds": (inputs.courtyardBounds as Dictionary).duplicate(true),
		"intentAuthority": compact_authority,
		"intentAuthoritySha256": _canonical_json(compact_authority).sha256_text(),
		"lotPairsSha256": _canonical_json(lot_pairs).sha256_text(),
		"streetRecordsSha256": _canonical_json(streets).sha256_text(),
		"structurePartsSha256": _canonical_json(structures).sha256_text(),
		"sourceSpecsSha256": _canonical_json(source_specs).sha256_text(),
		"options": OPTIONS.duplicate(true)
	}


func _compact_intent_authority_manifest(intents: Array) -> Array:
	var result: Array = []
	for value in _intent_authority_manifest(intents):
		var row: Dictionary = (value as Dictionary).duplicate(true)
		var source_signature := String(row.get("sourceBlueprintSignature", ""))
		row.erase("sourceBlueprintSignature")
		row["sourceBlueprintSignatureSha256"] = source_signature.sha256_text()
		row["sourceBlueprintSignatureBytes"] = source_signature.to_utf8_buffer().size()
		result.append(row)
	return result


func _input_provenance_complete(inputs: Dictionary) -> bool:
	return bool(inputs.get("ready", false)) and not (inputs.intents as Array).is_empty() \
		and (inputs.intents as Array).size() == (inputs.lotPairs as Array).size() * 2 \
		and not (inputs.streetRecords as Array).is_empty() and not (inputs.structureParts as Array).is_empty() \
		and not String(inputs.sourceBlueprintSignature).is_empty()


func _report_size_diagnostic() -> Dictionary:
	var target_inputs := _ordinary_inputs(FIXED_SEED)
	var known_inputs := _ordinary_inputs(KNOWN_ACCEPTED_SEED)
	if not bool(target_inputs.get("ready", false)) or not bool(known_inputs.get("ready", false)):
		return {
			"schema": "castle_courtyard_district_report_size_diagnostic/v1",
			"evidenceLevel": "report_construction_diagnostic",
			"passed": false,
			"reason": "input_reconstruction_failed"
		}
	var target_provenance := _input_provenance(target_inputs)
	var known_provenance := _input_provenance(known_inputs)
	var compact_provenance := {"target": target_provenance, "knownAccepted": known_provenance}
	var prior_report_value = JSON.parse_string(FileAccess.get_file_as_string(FAILED_CONTRACT_02_REPORT_PATH)) if FileAccess.file_exists(FAILED_CONTRACT_02_REPORT_PATH) else null
	var projected_report: Dictionary = (prior_report_value as Dictionary).duplicate(true) if prior_report_value is Dictionary else {}
	if not projected_report.is_empty():
		projected_report["inputProvenance"] = compact_provenance
		projected_report["reportByteCountBeforeFinalChecks"] = 0
	var target_authority := _compact_intent_authority_manifest(target_inputs.intents as Array)
	var known_authority := _compact_intent_authority_manifest(known_inputs.intents as Array)
	return {
		"schema": "castle_courtyard_district_report_size_diagnostic/v1",
		"evidenceLevel": "report_construction_diagnostic",
		"passed": not projected_report.is_empty(),
		"reason": "measured" if not projected_report.is_empty() else "missing_contract_02_report",
		"doesNotProve": ["Does not execute the planner, reversals, synthetic controls, builder projection, or gameplay."],
		"target": _compact_provenance_size_evidence(target_inputs, target_provenance, target_authority),
		"knownAccepted": _compact_provenance_size_evidence(known_inputs, known_provenance, known_authority),
		"compactInputProvenanceBytes": _pretty_bytes(compact_provenance),
		"compactInputProvenanceSha256": _canonical_json(compact_provenance).sha256_text(),
		"projectedFinalReportBytes": _pretty_bytes(projected_report),
		"projectedFinalReportSectionBytes": _dictionary_field_bytes(projected_report),
		"sourceReportPath": FAILED_CONTRACT_02_REPORT_PATH,
		"sourceReportSha256": FileAccess.get_sha256(FAILED_CONTRACT_02_REPORT_PATH).to_lower() if FileAccess.file_exists(FAILED_CONTRACT_02_REPORT_PATH) else "",
		"maximumReportBytes": MAXIMUM_REPORT_BYTES
	}


func _compact_provenance_size_evidence(inputs: Dictionary, provenance: Dictionary, authority: Array) -> Dictionary:
	var authority_json := _canonical_json(authority)
	var source_blueprint_signature := String(inputs.sourceBlueprintSignature)
	return {
		"intentCount": (inputs.intents as Array).size(),
		"lotPairCount": (inputs.lotPairs as Array).size(),
		"streetCount": (inputs.streetRecords as Array).size(),
		"structureCount": (inputs.structureParts as Array).size(),
		"sourceBlueprintPartCount": int(inputs.sourceBlueprintPartCount),
		"sourceBlueprintSignatureSha256": source_blueprint_signature.sha256_text(),
		"sourceBlueprintSignatureBytes": source_blueprint_signature.to_utf8_buffer().size(),
		"provenanceBytes": _pretty_bytes(provenance),
		"provenanceFieldBytes": _dictionary_field_bytes(provenance),
		"provenanceSha256": _canonical_json(provenance).sha256_text(),
		"intentAuthorityRowCount": authority.size(),
		"intentAuthorityBytes": _pretty_bytes(authority),
		"intentAuthoritySha256": authority_json.sha256_text(),
		"intentAuthorityHashBytes": authority_json.sha256_text().to_utf8_buffer().size()
	}


func _dictionary_field_bytes(value: Dictionary) -> Dictionary:
	var result := {}
	var keys := value.keys()
	keys.sort_custom(func(left, right): return String(left) < String(right))
	for key in keys:
		result[String(key)] = _pretty_bytes(value[key])
	return result


func _pretty_bytes(value: Variant) -> int:
	return JSON.stringify(_sanitize(value), "\t").to_utf8_buffer().size()


func _enriched_rejection_complete(value: Variant) -> bool:
	if not value is Dictionary:
		return false
	var row: Dictionary = value as Dictionary
	var residence: Dictionary = row.get("residence", {}) as Dictionary
	var details: Dictionary = row.get("details", {}) as Dictionary
	var relevant_ok := true
	if String(row.get("code", "")) == "street_overlap":
		relevant_ok = not (row.get("relevantStreet", {}) as Dictionary).is_empty()
	elif String(row.get("code", "")) == "structure_overlap":
		var structure: Dictionary = row.get("relevantStructure", {}) as Dictionary
		relevant_ok = not structure.is_empty() and not (structure.get("horizontalBounds", {}) as Dictionary).is_empty()
	elif String(row.get("code", "")) == "prior_residence_overlap":
		var annotated_keys := ["nominalCenter", "rowPackedCenter", "fixedPackedCenter", "finalCenter", "rowPackDeltaZ", "fixedPackDeltaX", "boundaryDeltaX", "boundaryDeltaZ", "overlapAfterRowPack", "overlapAfterFixedPack"]
		relevant_ok = not (row.get("relevantPriorResidence", {}) as Dictionary).is_empty() and annotated_keys.all(func(key): return details.has(key)) \
			and _stage_annotations_match(row.get("displacementStages", {}) as Dictionary, details)
	var aggregate_present := not (row.get("transformedAggregateFootprint", {}) as Dictionary).is_empty()
	var geometry_unavailable := bool((row.get("displacementStages", {}) as Dictionary).get("geometryUnavailable", false)) \
		and String(row.get("code", "")) in ["invalid_composition", "missing_composition_blocker", "invalid_composition_after_row_pack", "invalid_composition_after_fixed_pack", "invalid_composition_after_boundary_adjustment"]
	return not String(row.get("code", "")).is_empty() and not String(row.get("phase", "")).is_empty() \
		and not String(row.get("intentId", "")).is_empty() and int(row.get("pairIndex", -1)) >= 0 \
		and String(row.get("side", "")) in ["left", "right"] and not residence.is_empty() \
		and not (row.get("sampledLotPair", {}) as Dictionary).is_empty() \
		and (aggregate_present or geometry_unavailable) \
		and not (row.get("courtyardBounds", {}) as Dictionary).is_empty() and relevant_ok


func _trace_summary(trace: Dictionary) -> Dictionary:
	return {
		"passed": bool(trace.get("passed", false)),
		"phase": String(trace.get("phase", "")),
		"rejections": (trace.get("rejections", []) as Array).duplicate(true),
		"failedIntent": _intent_summary(trace.get("failedIntent", {}) as Dictionary),
		"failedStages": (trace.get("failedStages", {}) as Dictionary).duplicate(true),
		"priorPlacements": (trace.get("priorPlacements", []) as Array).duplicate(true),
		"priorCompositions": (trace.get("priorCompositions", []) as Array).duplicate(true),
		"telemetry": (trace.get("telemetry", {}) as Dictionary).duplicate(true)
	}


func _intent_for_id(intents: Array, identity: String) -> Dictionary:
	for value in intents:
		var intent: Dictionary = value as Dictionary
		if String(intent.get("id", "")) == identity:
			return intent
	return {}


func _telemetry_within_declared_bounds(telemetry: Dictionary) -> bool:
	var obstacle_actual := int(telemetry.get("algebraicObstacleComparisons", 0)) + int(telemetry.get("exactStreetComparisons", 0)) + int(telemetry.get("exactStructureComparisons", 0))
	var prior_actual := int(telemetry.get("algebraicPriorComparisons", 0)) + int(telemetry.get("exactPriorComparisons", 0))
	var traversed_items := 0
	for row_value in telemetry.get("priorTraversals", []) as Array:
		traversed_items += int((row_value as Dictionary).get("traversedPriorCount", 0))
	var repairs: Array = telemetry.get("coupledRepairs", []) as Array
	return int(telemetry.get("descriptionCalls", 0)) <= int(telemetry.get("maximumDescriptionCalls", -1)) \
		and obstacle_actual <= int(telemetry.get("maximumObstacleComparisons", -1)) \
		and prior_actual <= int(telemetry.get("maximumPriorComparisons", -1)) \
		and (telemetry.get("priorTraversals", []) as Array).size() <= int(telemetry.get("maximumPriorTraversalEntries", -1)) \
		and traversed_items <= int(telemetry.get("maximumPriorTraversalItems", -1)) \
		and repairs.size() == int(telemetry.get("coupledRepairTriggerCount", -1)) \
		and repairs.size() <= int(telemetry.get("maximumCoupledRepairTriggers", -1)) \
		and int(telemetry.get("coupledCandidateEvaluatedCount", -1)) >= 0 \
		and int(telemetry.get("coupledCandidateEvaluatedCount", -1)) <= int(telemetry.get("maximumCoupledCandidateEvaluations", -1))


func _builder_projection_matches(diagnostics: Dictionary, plan_summary: Dictionary, rejections: Array) -> bool:
	var required_keys := ["failureReason", "districtPlacementPlan", "pairDiagnostics"]
	if diagnostics.keys().size() != required_keys.size() or not required_keys.all(func(key): return diagnostics.has(key)) \
			or diagnostics.get("failureReason", "") != "district_placement_infeasible" or diagnostics.get("districtPlacementPlan", {}) != plan_summary:
		return false
	var pair: Dictionary = diagnostics.get("pairDiagnostics", {}) as Dictionary
	return pair.keys().size() == 6 and pair.get("mode", "") == "post_geometry_exact" and int(pair.get("attemptCount", -1)) == 0 \
		and not bool(pair.get("fallback", true)) and pair.get("terminalReason", "") == plan_summary.get("phase", "") \
		and int(pair.get("pairIndex", 0)) == -1 and pair.get("rejections", []) == rejections


func _stage_annotations_match(stages: Dictionary, details: Dictionary) -> bool:
	for key in ["nominalCenter", "rowPackedCenter", "fixedPackedCenter", "finalCenter"]:
		if not stages.has(key) or not details.has(key) or not stages[key] is Vector3 or not details[key] is Vector3 \
				or not (stages[key] as Vector3).is_equal_approx(details[key] as Vector3):
			return false
	for key in ["rowPackDeltaZ", "fixedPackDeltaX", "boundaryDeltaX", "boundaryDeltaZ"]:
		if not stages.has(key) or not details.has(key) or not is_equal_approx(float(stages[key]), float(details[key])):
			return false
	return true


func _contains_object(value: Variant) -> bool:
	if value is Object:
		return true
	if value is Dictionary:
		for key in (value as Dictionary).keys():
			if _contains_object(key) or _contains_object((value as Dictionary)[key]):
				return true
	elif value is Array:
		for item in value as Array:
			if _contains_object(item):
				return true
	return false


func _sanitize(value: Variant) -> Variant:
	if value is Object:
		return {"objectRejected": true, "class": (value as Object).get_class()}
	if value is Dictionary:
		var result := {}
		var keys := (value as Dictionary).keys()
		keys.sort_custom(func(left, right): return String(left) < String(right))
		for key in keys:
			result[String(key)] = _sanitize((value as Dictionary)[key])
		return result
	if value is Array:
		var result: Array = []
		for item in value as Array:
			result.append(_sanitize(item))
		return result
	return value


func _canonical_json(value: Variant) -> String:
	return JSON.stringify(_sanitize(value))


func _disclaimer() -> Array[String]:
	return [
		"Proves only the focused deterministic sampler-builder-planner handoff for the two declared seeds.",
		"Does not prove rendered visuals, gameplay, NPC behavior, navigation, or production publication.",
		"Uses ordinary recipe and source geometry authority without authored placement exceptions."
	]


func _write_report(path: String, report: Dictionary) -> Dictionary:
	var payload := JSON.stringify(report, "\t")
	var payload_bytes := payload.to_utf8_buffer().size()
	var section_bytes := {}
	var section_keys := report.keys()
	section_keys.sort_custom(func(left, right): return String(left) < String(right))
	for key in section_keys:
		section_bytes[String(key)] = JSON.stringify(report[key], "\t").to_utf8_buffer().size()
	var result := {
		"passed": false,
		"reason": "",
		"resolvedReportPath": path,
		"parentDirectory": path.get_base_dir(),
		"parentDirectoryExists": DirAccess.dir_exists_absolute(path.get_base_dir()),
		"maximumReportBytes": MAXIMUM_REPORT_BYTES,
		"payloadBytes": payload_bytes,
		"writtenBytes": 0,
		"sectionBytes": section_bytes
	}
	if payload_bytes > MAXIMUM_REPORT_BYTES:
		result["reason"] = "payload_oversize"
		return result
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		result["reason"] = "open_failed"
		result["fileAccessError"] = int(FileAccess.get_open_error())
		return result
	file.store_string(payload)
	file.flush()
	var written_size := FileAccess.get_file_as_bytes(path).size() if FileAccess.file_exists(path) else 0
	result["writtenBytes"] = written_size
	if written_size <= 0 or written_size > MAXIMUM_REPORT_BYTES:
		result["reason"] = "written_size_invalid"
		return result
	result["passed"] = true
	result["reason"] = "written"
	return result
