extends SceneTree
## Source/service evidence only. Frozen reviewed geometry is reused as an input
## to admission; no claim that it is the candidate's generated recipe or play.
const Preparation := preload("res://scripts/world/CitadelSitePreparation.gd")
const ManifestContract := preload("res://scripts/testing/buildings/BuildingSiteManifestContract.gd")
const Field := preload("res://scripts/world/CitadelSiteField.gd")
const Context := preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const World := preload("res://scripts/WorldGenerationSystem.gd")
var checks := {}
var attempts: Array = []
var report_path := ""
var progress_path := ""
func _initialize() -> void: call_deferred("run")
func run() -> void:
	report_path = OS.get_environment("VOXEL_CITADEL_SITE_PREPARATION_REPORT")
	progress_path = OS.get_environment("VOXEL_CITADEL_SITE_PREPARATION_PROGRESS")
	if report_path.is_empty() or progress_path.is_empty() or FileAccess.file_exists(report_path) or FileAccess.file_exists(progress_path): quit(2); return
	var reference := ManifestContract.run()
	checks["exact_source_manifest"] = reference.passed
	if not reference.passed: _finish(); return
	var manifest: Dictionary = reference.reference.manifest
	var seed := "atlas-1492"
	var context := Context.new()
	context.seed_text = seed
	context.seed_hash = context.hash_string(seed)
	context.setup_noise()
	var world := World.new()
	world.setup(context)
	context.set_generator(world)
	var policy := {"regionCells":140, "spawnChance":0.26}
	var accepted := {}
	for z in range(-4,5):
		for x in range(-4,5):
			var region := Vector2i(x,z)
			var candidate := Field.candidate_for_region(seed, region)
			if candidate.is_empty(): continue
			var center: Vector2i = candidate.centerCell
			var level := roundf(world.natural_surface_y_for_cell(Vector3i(center.x,0,center.y)) / Context.CELL) * Context.CELL
			var started := Time.get_ticks_usec()
			var result := Preparation.prepare_terrain(manifest,candidate,{},level,policy,_progress)
			attempts.append({"candidate":candidate,"status":result.status,"reason":result.reason,"elapsedUsec":Time.get_ticks_usec()-started})
			if result.status == "prepared":
				accepted = {"candidate":candidate,"level":level,"result":result}
				break
		if not accepted.is_empty(): break
	checks["actual_land_envelope_accepted"] = not accepted.is_empty()
	if accepted.is_empty(): _finish(); return
	var result: Dictionary = accepted.result
	var candidate: Dictionary = accepted.candidate
	checks["all_columns_surveyed"] = result.survey.columnsInspected == result.survey.totalColumns
	checks["source_signature_bound"] = result.profile.sourceSignature == manifest.sourceSignature
	checks["no_terrain_or_publication_claim"] = not result.terrainReady and not result.publicationReady
	checks["all_actual_roots_retained"] = result.profile.groundRootPoints.size() == manifest.groundRoots.size() * 4
	var expected_level := roundf((float(result.survey.minimumSurfaceY) + float(result.survey.maximumSurfaceY)) * 0.5 / Context.CELL) * Context.CELL
	checks["grading_level_uses_entire_site"] = result.profile.level == expected_level
	var repeat := Preparation.prepare_terrain(manifest,candidate,{},accepted.level,policy)
	checks["repeat_profile_exact"] = var_to_bytes(result.profile) == var_to_bytes(repeat.get("profile"))
	checks["repeat_survey_identity_exact"] = result.survey.requestIdentity == repeat.get("survey",{}).get("requestIdentity")
	var cancelled := Preparation.prepare(seed,candidate.region,{},policy,func(_stage): return false)
	checks["cancel_before_recipe_has_no_source"] = cancelled.status == "cancelled" and not cancelled.has("blueprint")
	cancelled = Preparation.prepare_terrain(manifest,candidate,{},accepted.level,policy,func(_stage): return false)
	checks["cancel_before_survey_has_no_profile"] = cancelled.status == "cancelled" and not cancelled.has("profile")
	var forged := candidate.duplicate(true)
	forged.recipeSeed += 1
	checks["forged_candidate_rejected"] = Preparation.prepare_terrain(manifest,forged,{},accepted.level,policy).reason == "invalid_site_candidate"
	checks["world_profile_admitted"] = world.configure_generated_site_profiles([result.profile]).ready
	for root: Vector3 in result.profile.groundRootPoints:
		var cell := Vector3i(floori(root.x / Context.CELL),0,floori(root.z / Context.CELL))
		checks["every_actual_root_has_volume_surface"] = checks.get("every_actual_root_has_volume_surface",true) and world.base_surface_y_for_cell(cell) == expected_level
	_finish()
func _progress(stage: String) -> bool:
	var file := FileAccess.open(progress_path,FileAccess.WRITE)
	file.store_string(JSON.stringify({"stage":stage,"attempts":attempts}))
	return true
func _finish() -> void:
	var passed := not checks.values().has(false)
	var report := {"passed":passed,"checks":checks,"attempts":attempts,"evidenceLevel":"frozen_geometry_real_world_source_admission_not_runtime_spawn"}
	var file := FileAccess.open(report_path,FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
	print(JSON.stringify(report))
	quit(0 if passed else 1)
