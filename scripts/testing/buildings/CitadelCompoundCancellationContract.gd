extends SceneTree

## Source-only contract. Never launches scenes, physics, NPCs or navigation.
const FIELD_PATH := "res://scripts/world/CitadelSiteField.gd"
const BUILDER_PATH := "res://scripts/buildings/CastleCompoundBlueprintBuilder.gd"
const SITE_SHA := "7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf"
var output := ""
var checks: Dictionary = {}
var records: Array = []
var callback_started := 0
var previous_usec := 0
var stopped_usec := 0
var after_false := 0
var cancel_stage := ""
var stage_occurrence := 0
var cancel_occurrence := 1
var report: Dictionary = {"schema": "citadel-compound-cancellation/v1", "complete": false, "passed": false,
	"evidenceLevel": "source_contract_only", "doesNotProve": "No headed, NPC, navigation, ordinary runtime spawning, frame-budget or full Site acceptance."}

func _initialize() -> void:
	call_deferred("_run")

func _check(name: String, condition: bool) -> bool:
	checks[name] = condition
	if not condition: print("CONTRACT FAILURE: ", name)
	return condition

func _read(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > 134217728: return null
	var value: Variant = file.get_var(false)
	if file.get_error() != OK or file.get_position() != file.get_length(): return null
	return value

func _write_binary(path: String, value: Variant) -> bool:
	if FileAccess.file_exists(path): return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_var(value, false)
	file.flush()
	return file.get_error() == OK

func _bindings_match(bindings: Dictionary) -> bool:
	for path: String in bindings:
		if FileAccess.get_sha256(path) != bindings[path]: return false
	return true

func _run() -> void:
	output = OS.get_environment("CITADEL_COMPOUND_OUTPUT")
	report.phase = OS.get_environment("CITADEL_COMPOUND_PHASE")
	var launch: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(output.path_join("launch.json")))
	if not _check("dependencies_before", _bindings_match(launch.get("liveDependencies", launch.dependencies))):
		_finish(); return
	var site_path := OS.get_environment("CITADEL_COMPOUND_SITE")
	if not _check("site_hash", FileAccess.get_sha256(site_path) == SITE_SHA):
		_finish(); return
	var site: Variant = _read(site_path)
	if not _check("site_typed_complete", site is Dictionary and site.get("status") == "prepared" and site.get("sourceContext") is Dictionary):
		_finish(); return
	var field = load(FIELD_PATH)
	var candidate: Dictionary = field.candidate_for_region("atlas-1492", Vector2i(1, -3))
	var context: Dictionary = site.sourceContext.duplicate(true)
	var caller_bytes := var_to_bytes(context)
	var seed := int(candidate.get("recipeSeed", -1))
	if not _check("actual_candidate_context", seed >= 0 and context.get("siteKey") == candidate.get("siteId")):
		_finish(); return
	report.candidate = candidate
	report.context = context
	if report.phase == "baseline":
		var frozen_path := output.path_join("FrozenCastleCompoundBlueprintBuilder.gd")
		if not _check("frozen_hash", FileAccess.get_sha256(frozen_path) == launch.frozenSha256):
			_finish(); return
		var frozen = load(frozen_path)
		print("COMPOUND baseline build started seed=", seed)
		var started := Time.get_ticks_usec()
		var result: Dictionary = frozen.build_with_diagnostics(seed, context)
		report.buildUsec = Time.get_ticks_usec() - started
		if not _check("baseline_blueprint", result.get("blueprint") != null):
			_finish(); return
		var snapshot: Dictionary = result.blueprint.snapshot()
		var evidence := {"schema": "citadel-compound-baseline/v1", "engine": Engine.get_version_info(),
			"candidate": candidate, "seed": seed, "context": context, "siteSha256": SITE_SHA,
			"frozenSha256": launch.frozenSha256, "gitBuilderSha256": launch.gitBuilderSha256,
			"dependencies": launch.dependencies, "blueprint": snapshot, "diagnostics": result.diagnostics}
		_check("caller_context_unchanged", caller_bytes == var_to_bytes(context))
		_check("dependencies_after", _bindings_match(launch.dependencies))
		if false not in checks.values():
			_check("snapshot_saved_once", _write_binary(output.path_join("baseline.bin"), evidence))
			report.baselineSha256 = FileAccess.get_sha256(output.path_join("baseline.bin"))
			report.blueprintPartCount = snapshot.parts.size()
	else:
		_run_current(launch, candidate, seed, context)
	_finish()

func _callback(stage: String) -> bool:
	var now := Time.get_ticks_usec()
	if stopped_usec != 0: after_false += 1
	if stage == cancel_stage: stage_occurrence += 1
	var permitted := not (stage == cancel_stage and stage_occurrence >= cancel_occurrence)
	if not permitted and stopped_usec == 0: stopped_usec = now
	records.append({"index": records.size(), "stage": stage, "timestampUsec": now,
		"elapsedUsec": now - callback_started, "gapUsec": now - previous_usec, "continued": permitted})
	previous_usec = now
	# No per-callback I/O: timings include only bounded record append overhead.
	return permitted

func _run_current(launch: Dictionary, candidate: Dictionary, recipe_seed: int, context: Dictionary) -> void:
	var baseline_path := OS.get_environment("CITADEL_COMPOUND_BASELINE")
	if not _check("baseline_hash", FileAccess.get_sha256(baseline_path.path_join("baseline.bin")) == launch.baselineSha256): return
	var baseline: Variant = _read(baseline_path.path_join("baseline.bin"))
	if not _check("baseline_identity", baseline is Dictionary and baseline.schema == "citadel-compound-baseline/v1"
		and baseline.engine == Engine.get_version_info() and baseline.seed == recipe_seed
		and var_to_bytes(baseline.candidate) == var_to_bytes(candidate)
		and var_to_bytes(baseline.context) == var_to_bytes(context)
		and baseline.siteSha256 == SITE_SHA and baseline.frozenSha256 == launch.frozenSha256
		and baseline.gitBuilderSha256 == launch.gitBuilderSha256
		and baseline.dependencies == launch.dependencies): return
	if not _check("current_sources_before", _bindings_match(launch.currentSources)): return
	if not _check("reference_sources_before", _bindings_match(launch.referenceSources)): return
	var builder = load(BUILDER_PATH)
	var caller_bytes := var_to_bytes(context)
	seed(0x317abc)
	var expected_random := randi()
	seed(0x317abc)
	callback_started = Time.get_ticks_usec()
	previous_usec = callback_started
	var result: Dictionary
	if report.phase == "success":
		var mode := OS.get_environment("CITADEL_COMPOUND_MODE")
		report.mode = mode
		print("COMPOUND final success mode=", mode)
		if mode == "omitted": result = builder.build_with_diagnostics(recipe_seed, context)
		elif mode == "empty": result = builder.build_with_diagnostics(recipe_seed, context, Callable())
		elif mode == "true": result = builder.build_with_diagnostics(recipe_seed, context, _callback)
		else:
			_check("valid_mode", false); return
		var returned := Time.get_ticks_usec()
		report.buildUsec = returned - callback_started
		if _check("successful_blueprint", result.get("blueprint") != null):
			var snapshot: Dictionary = result.blueprint.snapshot()
			_check("complete_typed_blueprint_exact", var_to_bytes(snapshot) == var_to_bytes(baseline.blueprint))
			_check("complete_typed_diagnostics_exact", var_to_bytes(result.diagnostics) == var_to_bytes(baseline.diagnostics))
			_check("success_snapshot_saved", _write_binary(output.path_join("success.bin"), {"blueprint": snapshot, "diagnostics": result.diagnostics}))
			report.successSha256 = FileAccess.get_sha256(output.path_join("success.bin"))
			report.blueprintPartCount = snapshot.parts.size()
		if mode == "true":
			_check("callback_entry", not records.is_empty() and records[0].stage == "compound_sampler_started")
			_check("callback_precommit", not records.is_empty() and records.back().stage == "compound_geometry_completed")
		_record_timings(returned)
	elif report.phase == "cancellation":
		cancel_stage = OS.get_environment("CITADEL_COMPOUND_CANCEL_STAGE")
		cancel_occurrence = maxi(1, int(OS.get_environment("CITADEL_COMPOUND_CANCEL_OCCURRENCE")))
		report.cancelStage = cancel_stage
		report.cancelOccurrence = cancel_occurrence
		var target := OS.get_environment("CITADEL_COMPOUND_TARGET")
		report.target = target
		print("COMPOUND cancellation target=", target, " stage=", cancel_stage)
		if target == "source":
			var source = load("res://scripts/buildings/CitadelRecipePreparation.gd")
			result = source.prepare(recipe_seed, context, _callback)
			_check("source_cancel_classification", result.get("ready") == false and result.get("reason") == "cancelled")
			_check("source_no_partial_payload", not result.has("blueprint") and not result.has("furnishingPlan") and not result.has("interiorProgram"))
		else:
			result = builder.build_with_diagnostics(recipe_seed, context, _callback)
			_check("cancel_null_blueprint", result.has("blueprint") and result.blueprint == null)
			_check("explicit_cancel_only_diagnostics", result.get("diagnostics") == {"failureReason": "cancelled"})
		var returned := Time.get_ticks_usec()
		_check("cancellation_reached", stopped_usec != 0 and stage_occurrence == cancel_occurrence)
		_check("no_later_callbacks", after_false == 0 and not records.is_empty() and records.back().continued == false)
		report.cancelResult = result
		_record_timings(returned)
	elif report.phase in ["reuse-reference", "reuse"]:
		# Actual sampled compound, not a fabricated successful recipe. Reuse the
		# caller-owned diagnostic dictionary produced by a real rejected callback.
		var compound: Dictionary = baseline.blueprint.recipe.compound.duplicate(true)
		var compound_bytes := var_to_bytes(compound)
		var reused_diagnostics := {"discardedOnCancel": true}
		cancel_stage = "compound_geometry_started"
		var cancelled = builder.build_from_compound(compound, reused_diagnostics, _callback)
		_check("reuse_initial_cancel", cancelled == null and reused_diagnostics == {"failureReason": "cancelled"})
		_check("reuse_initial_no_later_callbacks", after_false == 0 and records.size() == 1)
		# This extra caller field must survive both old and new successful calls.
		reused_diagnostics["callerSentinel"] = {"preserve": [1, "typed", Vector2i(2, -3)]}
		if report.phase == "reuse-reference":
			var old = load(output.path_join("BoundOldCastleCompoundBlueprintBuilder.gd"))
			var old_started := Time.get_ticks_usec()
			var old_blueprint = old.build_from_compound(compound, reused_diagnostics)
			report.oldReuseBuildUsec = Time.get_ticks_usec() - old_started
			_check("reuse_old_success", old_blueprint != null)
			if old_blueprint != null:
				_check("reuse_baseline_blueprint_exact", var_to_bytes(old_blueprint.snapshot()) == var_to_bytes(baseline.blueprint))
				_check("reuse_reference_saved", _write_binary(output.path_join("reuse-reference.bin"), {
					"blueprint": old_blueprint.snapshot(), "diagnostics": reused_diagnostics,
					"compound": compound, "engine": Engine.get_version_info(), "baselineSha256": launch.baselineSha256,
					"gitBuilderSha256": launch.gitBuilderSha256, "dependencies": baseline.dependencies}))
				report.reuseReferenceSha256 = FileAccess.get_sha256(output.path_join("reuse-reference.bin"))
		else:
			var reference_path := OS.get_environment("CITADEL_COMPOUND_REUSE_REFERENCE").path_join("reuse-reference.bin")
			if not _check("reuse_reference_hash", FileAccess.get_sha256(reference_path) == launch.reuseReferenceSha256): return
			var reference: Variant = _read(reference_path)
			if not _check("reuse_reference_identity", reference is Dictionary and reference.engine == Engine.get_version_info()
				and reference.baselineSha256 == launch.baselineSha256 and reference.gitBuilderSha256 == launch.gitBuilderSha256
				and reference.dependencies == baseline.dependencies and var_to_bytes(reference.compound) == compound_bytes): return
			var current_started := Time.get_ticks_usec()
			var current_blueprint = builder.build_from_compound(compound, reused_diagnostics)
			report.currentReuseBuildUsec = Time.get_ticks_usec() - current_started
			_check("reuse_current_success", current_blueprint != null)
			if current_blueprint != null:
				_check("reuse_complete_blueprint_exact", var_to_bytes(reference.blueprint) == var_to_bytes(current_blueprint.snapshot()))
				_check("reuse_complete_diagnostics_exact", var_to_bytes(reference.diagnostics) == var_to_bytes(reused_diagnostics))
				_check("reuse_snapshot_saved", _write_binary(output.path_join("reuse.bin"), {"blueprint": current_blueprint.snapshot(), "diagnostics": reused_diagnostics}))
		_check("reuse_no_reset_old_fields", reused_diagnostics.has("callerSentinel") and reused_diagnostics.get("failureReason") == "cancelled")
		_check("reuse_compound_unchanged", compound_bytes == var_to_bytes(compound))
		report.elapsedUsec = Time.get_ticks_usec() - callback_started
		report.reuseScope = "Separate old/current actual full compound builds using identical caller-owned stale cancellation diagnostics. Successful compatibility preserves old diagnostic fields rather than silently resetting them."
	elif report.phase == "planner":
		_planner_controls(baseline)
	elif report.phase == "failure":
		# Deliberately malformed compound, not a generated-world acceptance test.
		# Old/current each emit one explicitly inventoried expected push_error.
		var old = load(output.path_join("BoundOldCastleCompoundBlueprintBuilder.gd"))
		var compound := {"seed": recipe_seed, "context": context.duplicate(true)}
		var compound_bytes := var_to_bytes(compound)
		var old_diagnostics := {}
		var current_diagnostics := {}
		var old_blueprint = old.build_from_compound(compound, old_diagnostics)
		var current_blueprint = builder.build_from_compound(compound, current_diagnostics, _callback)
		_check("ordinary_failure_null", old_blueprint == null and current_blueprint == null)
		_check("ordinary_failure_exact", var_to_bytes(old_diagnostics) == var_to_bytes(current_diagnostics))
		_check("ordinary_failure_not_cancelled", current_diagnostics.get("failureReason") == "invalid_sampler_entry_approach")
		_check("failure_compound_preserved", compound_bytes == var_to_bytes(compound))
		report.failureDiagnostics = current_diagnostics
		report.expectedEngineErrors = [{"message": "Castle seed %d has missing or divergent sampler-owned palace approach authority" % recipe_seed, "count": 2}]
		report.failureScope = "Synthetic malformed build_from_compound; no full source build-failure mapping exercised."
		_record_timings(Time.get_ticks_usec())
	else:
		_check("known_phase", false)
	_check("global_rng_unchanged", randi() == expected_random)
	_check("caller_context_unchanged", caller_bytes == var_to_bytes(context))
	_check("dependencies_after", _bindings_match(launch.liveDependencies))
	_check("reference_sources_after", _bindings_match(launch.referenceSources))
	_check("current_sources_after", _bindings_match(launch.currentSources))
	_check("baseline_still_immutable", FileAccess.get_sha256(baseline_path.path_join("baseline.bin")) == launch.baselineSha256)

func _planner_controls(baseline: Dictionary) -> void:
	# Small synthetic pair, reconstructed from actual sampled residence recipes.
	# This is not the legacy multi-build district repair acceptance suite.
	var old_builder = load(output.path_join("BoundOldCastleCompoundBlueprintBuilder.gd"))
	var old = load(output.path_join("FrozenCastleCourtyardDistrictPlacementPlanner.gd"))
	var current = load("res://scripts/buildings/CastleCourtyardDistrictPlacementPlanner.gd")
	var program: Array = baseline.blueprint.recipe.compound.castleGrammar.courtyardProgram
	var intents: Array = []
	var source_snapshots: Array = []
	for index in range(2):
		var spec: Dictionary = program[index].duplicate(true)
		var recipe: Dictionary = spec.residenceRecipe.duplicate(true)
		var source = old_builder.courtyard_residence_blueprint_from_recipe(spec.residenceFamily, recipe)
		if not _check("planner_source_%d" % index, source != null): return
		source_snapshots.append(source.snapshot())
		intents.append({"id": spec.id, "pairIndex": 0, "side": "left" if index == 0 else "right",
			"family": spec.residenceFamily, "recipe": recipe, "recipeHash": spec.residenceRecipeHash,
			"sourceBlueprint": source, "sourceBlueprintSignature": source.deterministic_signature(),
			"sourceSpec": spec, "nominalCenter": Vector3(-30.0 if index == 0 else 30.0, 0.0, 0.0),
			"frontDirection": spec.frontDirection, "elevation": spec.terraceElevation, "foundationElevation": 0.62})
	var bounds := {"minX": -100.0, "maxX": 100.0, "minZ": -100.0, "maxZ": 100.0}
	var inputs_before := _planner_input_snapshot(intents, bounds)
	var expected: Dictionary = old.plan(intents, [], [], bounds)
	if not _check("planner_old_default_success", expected.get("status") == "ready" and expected.get("validation", {}).get("passed") == true):
		report.plannerOldFailure = expected
		return
	var modes := {
		"omitted": current.plan(intents, [], [], bounds),
		"empty": current.plan(intents, [], [], bounds, {}, Callable()),
		"true": current.plan(intents, [], [], bounds, {}, _callback)}
	var old_validation: Dictionary = old.validate_plan(expected, intents, [], [], bounds)
	_check("planner_old_validation_success", old_validation.get("passed") == true)
	for mode: String in modes:
		_check("planner_%s_success" % mode, modes[mode].get("status") == "ready" and modes[mode].get("validation", {}).get("passed") == true)
		_check("planner_%s_complete_exact" % mode, var_to_bytes(expected) == var_to_bytes(modes[mode]))
	var validations := {"omitted": current.validate_plan(expected, intents, [], [], bounds),
		"empty": current.validate_plan(expected, intents, [], [], bounds, {}, Callable()),
		"true": current.validate_plan(expected, intents, [], [], bounds, {}, _callback)}
	for mode: String in validations:
		_check("planner_validate_%s_exact" % mode, var_to_bytes(old_validation) == var_to_bytes(validations[mode]))
	_check("planner_invalid_default_exact", var_to_bytes(old.plan([], [], [], bounds)) == var_to_bytes(current.plan([], [], [], bounds)))
	# Valid sampled sources with physically impossible bounds: this must be a
	# real infeasible plan, not merely an empty/invalid-input rejection control.
	var tiny_bounds := {"minX": -0.5, "maxX": 0.5, "minZ": -0.5, "maxZ": 0.5}
	var infeasible: Dictionary = old.plan(intents, [], [], tiny_bounds)
	_check("planner_old_genuine_infeasible", infeasible.get("status") == "infeasible" and infeasible.get("phase") != "invalid_input")
	var infeasible_modes := {"omitted": current.plan(intents, [], [], tiny_bounds),
		"empty": current.plan(intents, [], [], tiny_bounds, {}, Callable()),
		"true": current.plan(intents, [], [], tiny_bounds, {}, _callback)}
	for mode: String in infeasible_modes:
		_check("planner_infeasible_%s_exact" % mode, var_to_bytes(infeasible) == var_to_bytes(infeasible_modes[mode]))
	_check("planner_input_and_blueprints_unchanged", inputs_before == _planner_input_snapshot(intents, bounds))
	_check("planner_evidence_saved", _write_binary(output.path_join("planner.bin"), {"old": expected, "modes": modes,
		"oldValidation": old_validation, "validations": validations, "sources": source_snapshots,
		"oldInfeasible": infeasible, "infeasibleModes": infeasible_modes}))
	report.plannerScope = "Synthetic two-residence success through direct public plan/validate_plan APIs; all default options and omitted/empty/true continuation exact against frozen Git planner. Not the historical multi-build district repair suite or live placement acceptance."
	_record_timings(Time.get_ticks_usec())

func _planner_input_snapshot(intents: Array, bounds: Dictionary) -> PackedByteArray:
	var data: Array = []
	for intent: Dictionary in intents:
		var item := intent.duplicate(true)
		item.sourceBlueprint = intent.sourceBlueprint.snapshot()
		data.append(item)
	return var_to_bytes({"intents": data, "bounds": bounds})

func _record_timings(returned: int) -> void:
	report.callbackRecords = records
	report.callbackCount = records.size()
	report.returnTimestampUsec = returned
	report.elapsedUsec = returned - callback_started
	report.lastCallbackToReturnUsec = returned - previous_usec
	report.falseToReturnUsec = returned - stopped_usec if stopped_usec != 0 else 0
	var max_gap := 0
	var stage_gaps: Dictionary = {}
	for record: Dictionary in records:
		max_gap = maxi(max_gap, record.gapUsec)
		var entry: Dictionary = stage_gaps.get(record.stage, {"count": 0, "totalGapUsec": 0, "maxGapUsec": 0})
		entry.count += 1
		entry.totalGapUsec += int(record.gapUsec)
		entry.maxGapUsec = maxi(entry.maxGapUsec, record.gapUsec)
		stage_gaps[record.stage] = entry
	report.maxInterCallbackGapUsec = max_gap
	report.gapsByArrivingStage = stage_gaps

func _finish() -> void:
	report.checks = checks
	report.complete = true
	report.passed = not checks.is_empty() and false not in checks.values()
	var file := FileAccess.open(output.path_join("report.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	var summary := {"phase": report.phase, "passed": report.passed, "complete": report.complete,
		"checks": checks.size(), "buildUsec": report.get("buildUsec", 0),
		"callbackCount": report.get("callbackCount", 0), "maxInterCallbackGapUsec": report.get("maxInterCallbackGapUsec", 0),
		"elapsedUsec": report.get("elapsedUsec", 0), "falseToReturnUsec": report.get("falseToReturnUsec", 0),
		"report": output.path_join("report.json")}
	var summary_file := FileAccess.open(output.path_join("summary.json"), FileAccess.WRITE)
	summary_file.store_string(JSON.stringify(summary, "\t"))
	summary_file.close()
	print("COMPOUND RESULT ", JSON.stringify(summary))
	quit(0 if report.passed else 1)
