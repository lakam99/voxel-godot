extends SceneTree

## Source-only cancellation contracts using production APIs and a real builder.
## Callback boundaries are observed synchronously, not compiler interruption.
const Source := preload("res://scripts/buildings/CitadelRecipePreparation.gd")
const Site := preload("res://scripts/world/CitadelSitePreparation.gd")
const Field := preload("res://scripts/world/CitadelSiteField.gd")
const SEED := 237207443
const CONTEXT := {"biome": "forest", "siteKey": "river-citadel", "citadelScale": 1.25}
const WORLD_SEED := "atlas-1492"
const REGION := Vector2i(1, -3)
const POLICY := {"regionCells": 140, "spawnChance": 0.26}
const SOURCE_PATHS := [
	"res://scripts/buildings/CitadelRecipePreparation.gd",
	"res://scripts/world/CitadelSitePreparation.gd",
	"res://scripts/buildings/CitadelUrbanPocComposer.gd",
	"res://scripts/buildings/CastleCompoundBlueprintBuilder.gd",
	"res://scripts/buildings/LandmarkBuildingRecipeSampler.gd",
	"res://scripts/buildings/CastleCourtyardDistrictPlacementPlanner.gd",
	"res://scripts/buildings/CastleResidencePlacementGeometry.gd",
	"res://scripts/buildings/TerminalShopElevationRecipe.gd",
	"res://scripts/world/CitadelSiteField.gd",
	"res://scripts/world/CitadelSiteSurvey.gd",
	"res://scripts/world/BuildingTerrainProfile.gd",
	"res://scripts/testing/buildings/CitadelPreparationCancellationContract.gd"
]
const FORBIDDEN_KEYS := [
	"blueprint", "furnishingPlan", "furniture", "interiorProgram", "profile",
	"manifest", "terrainProfile", "preparedBlueprint", "preparedFurniture"
]
var _cases: Array[Dictionary] = []
var _checks: Dictionary = {}
var _report_path := ""
var _progress_path := ""

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_report_path = OS.get_environment("VOXEL_CITADEL_CANCELLATION_REPORT")
	_progress_path = OS.get_environment("VOXEL_CITADEL_CANCELLATION_PROGRESS")
	if not _report_path.is_absolute_path() or not _progress_path.is_absolute_path() or _report_path == _progress_path or FileAccess.file_exists(_report_path) or FileAccess.file_exists(_progress_path):
		quit(2)
		return
	var started := Time.get_ticks_usec()
	var source_before := _source_hashes()
	var context_before := var_to_bytes(CONTEXT)
	var candidate := Field.candidate_for_region(WORLD_SEED, REGION)
	_checks["site_candidate_is_real_known_land_case"] = not candidate.is_empty() and candidate.get("recipeSeed") == 1298433643 and candidate.get("siteId") == "citadel-site-v1:10:atlas-1492:1,-3"
	_source_case("source_entry", "compound_started", ["compound_started"])
	_site_case()
	_source_case("nested_composer_after_real_builder", "base_layout_started", ["compound_started", "compound_completed", "base_layout_started"])
	_checks["caller_context_unchanged"] = context_before == var_to_bytes(CONTEXT)
	var source_after := _source_hashes()
	_checks["recorded_sources_unchanged_during_run"] = source_before == source_after
	_checks["source_hashes_complete"] = source_before.size() == SOURCE_PATHS.size() and source_before.values().all(func(value): return String(value).length() == 64)
	var passed: bool = _checks.values().all(func(value): return bool(value))
	var report := {
		"schema": "citadel_preparation_cancellation_contract/v1",
		"evidenceLevel": "source_only_actual_builder_callback_cancellation",
		"complete": true, "passed": passed, "checks": _checks, "cases": _cases,
		"sourceSeed": SEED, "sourceContext": CONTEXT,
		"siteWorldSeed": WORLD_SEED, "siteRegion": REGION, "siteCandidate": candidate,
		"sourceSha256Before": source_before, "sourceSha256After": source_after,
		"engine": Engine.get_version_info(), "elapsedUsec": Time.get_ticks_usec() - started,
		"doesNotProve": [
			"No bounded cancellation latency inside CastleBuilder, the compiler, or any synchronous stage; elapsed times are observations only.",
			"No cancellation at every later composer/furniture/terrain stage, asynchronous worker cancellation, full preparation success, or worker reuse proof.",
			"No rendered visuals, terrain publication, runtime spawning, gameplay, NPC navigation, save behavior, or memory-allocator leak proof.",
			"No returned source artifacts or object references is a handoff check; clean process/resource logs are separate watchdog evidence.",
			"Site cancellation reaches Source compound_started after real center survey, but does not build that site's castle.",
			"Nested cancellation uses Source.prepare with real CastleBuilder and rejects the first Composer callback; it is not a nested Site full build."
		]
	}
	var file := FileAccess.open(_report_path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("CITADEL PREPARATION CANCELLATION: ", "PASS" if passed else "FAIL", " checks=", JSON.stringify(_checks))
	quit(0 if passed else 1)

func _source_case(name: String, reject_stage: String, expected: Array) -> void:
	var trace := _new_trace(name, reject_stage)
	var callback := func(stage: String) -> bool: return _continue(trace, stage)
	var result: Dictionary = Source.prepare(SEED, CONTEXT, callback)
	_checks[name + ":cancelled_not_composition_failed"] = result == {"ready": false, "reason": "cancelled"}
	_checks[name + ":exact_stage_sequence"] = trace.stages == expected
	_record_case(trace, result)
	if name == "nested_composer_after_real_builder":
		_checks[name + ":real_builder_completed_before_nested_rejection"] = trace.stages == ["compound_started", "compound_completed", "base_layout_started"] and trace.rejectionIndex == 2

func _site_case() -> void:
	var trace := _new_trace("site_entering_source", "compound_started")
	var callback := func(stage: String) -> bool: return _continue(trace, stage)
	var result: Dictionary = Site.prepare(WORLD_SEED, REGION, {}, POLICY, callback)
	_checks["site_entering_source:status_and_reason_cancelled"] = result.get("status") == "cancelled" and result.get("reason") == "cancelled"
	_checks["site_entering_source:source_failure_is_cancellation"] = result.get("sourceFailure") == {"ready": false, "reason": "cancelled"}
	_checks["site_entering_source:not_terrain_or_publication_ready"] = result.get("terrainReady") == false and result.get("publicationReady") == false
	var stages: Array = trace.stages
	var prework_only_before_source: bool = stages.size() >= 2 and stages.back() == "compound_started"
	for index in range(maxi(0, stages.size() - 1)):
		prework_only_before_source = prework_only_before_source and stages[index] == "site_center_survey"
	_checks["site_entering_source:survey_allowed_source_rejected_not_prework"] = prework_only_before_source and trace.rejectionIndex == stages.size() - 1
	_record_case(trace, result)

func _new_trace(name: String, reject_stage: String) -> Dictionary:
	print("CITADEL CANCELLATION CASE: ", name, " reject=", reject_stage)
	return {"name": name, "rejectStage": reject_stage, "startedUsec": Time.get_ticks_usec(), "stages": [], "events": [], "rejectionIndex": -1, "callbacksAfterRejection": 0}

func _continue(trace: Dictionary, stage: String) -> bool:
	var after_rejection := int(trace.rejectionIndex) >= 0
	if after_rejection:
		trace.callbacksAfterRejection += 1
	var index: int = trace.stages.size()
	var accepted := not after_rejection and stage != String(trace.rejectStage)
	if not accepted and not after_rejection:
		trace.rejectionIndex = index
	trace.stages.append(stage)
	trace.events.append({"stage": stage, "accepted": accepted, "afterRejection": after_rejection, "elapsedUsec": Time.get_ticks_usec() - int(trace.startedUsec)})
	print("CITADEL CANCELLATION STAGE: ", trace.name, " ", stage, " accepted=", accepted)
	var file := FileAccess.open(_progress_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({"activeCase": trace, "completedCases": _cases}, "\t"))
		file.close()
	return accepted

func _record_case(trace: Dictionary, result: Dictionary) -> void:
	var name := String(trace.name)
	_checks[name + ":rejection_reached_once"] = int(trace.rejectionIndex) >= 0 and (trace.stages as Array).count(trace.rejectStage) == 1
	_checks[name + ":no_later_callbacks"] = int(trace.callbacksAfterRejection) == 0 and trace.stages.size() == int(trace.rejectionIndex) + 1
	var leaks: Array[String] = []
	_find_handoff_leaks(result, "$", leaks)
	_checks[name + ":no_blueprint_furniture_interior_profile_or_objects"] = leaks.is_empty()
	_cases.append({"name": name, "rejectStage": trace.rejectStage, "stages": trace.stages, "events": trace.events, "rejectionIndex": trace.rejectionIndex, "callbacksAfterRejection": trace.callbacksAfterRejection, "handoff": result, "handoffLeaks": leaks, "elapsedUsec": Time.get_ticks_usec() - int(trace.startedUsec)})

func _find_handoff_leaks(value: Variant, path: String, leaks: Array[String]) -> void:
	if value is Object:
		leaks.append(path + ":object")
	elif value is Dictionary:
		for key in value:
			var next := path + "." + String(key)
			if String(key) in FORBIDDEN_KEYS:
				leaks.append(next + ":forbidden_artifact_key")
			_find_handoff_leaks(value[key], next, leaks)
	elif value is Array:
		for index in range(value.size()):
			_find_handoff_leaks(value[index], path + "[%d]" % index, leaks)

func _source_hashes() -> Dictionary:
	var hashes := {}
	for path in SOURCE_PATHS:
		hashes[path] = FileAccess.get_sha256(path)
	return hashes
