extends SceneTree

## Offline continuation of an exact public Recipe artifact. Never injected into
## the game, and never scene/rendering/NPC or gameplay acceptance.
const Diagnostic = preload("res://scripts/testing/buildings/CitadelCandidateRecipeDiagnostic.gd")
const Restore = preload("res://scripts/buildings/BuildingPublicationSource.gd")
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Manifest = preload("res://scripts/buildings/BuildingSiteManifestBuilder.gd")
const Site = preload("res://scripts/world/CitadelSitePreparation.gd")
const Queue = preload("res://scripts/world/CitadelSiteBuildQueue.gd")
const MainPolicy = preload("res://scripts/MainInterface.gd")
const SOURCE := "res://artifacts/citadel-runtime-integration/candidate-recipe-19/source.bin"
const SOURCE_SHA := "53942402985c5282b28f7e7a3e4f4f020e801292837485ebdee419ea9cd27059"
const INPUT := "res://artifacts/citadel-runtime-integration/candidate-recipe-19/input.bin"
const INPUT_SHA := "76879149d64ee73af3a8a0bf2aaf334b6bcbd0ce5094b5a380c11cc02986f759"
var state = Diagnostic.Progress.new()
var output := ""
var source_path := SOURCE
var source_sha := SOURCE_SHA
var input_path := INPUT
var input_sha := INPUT_SHA
var checks: Dictionary={}
var evidence: Dictionary={}

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	output=OS.get_environment("CITADEL_CANDIDATE_CONTINUATION_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output):quit(2);return
	if not OS.get_environment("CITADEL_CONTINUATION_SOURCE").is_empty():
		source_path=OS.get_environment("CITADEL_CONTINUATION_SOURCE")
		source_sha=OS.get_environment("CITADEL_CONTINUATION_SOURCE_SHA")
		input_path=OS.get_environment("CITADEL_CONTINUATION_INPUT")
		input_sha=OS.get_environment("CITADEL_CONTINUATION_INPUT_SHA")
		if not source_path.is_absolute_path() or not input_path.is_absolute_path() or source_sha.length()!=64 or input_sha.length()!=64:quit(2);return
	state.started=Time.get_ticks_msec()
	state.begin_phase("restore_and_manifest",30000)
	var thread := Thread.new()
	if thread.start(_work)!=OK:quit(2);return
	var next_progress := 0
	while thread.is_alive():
		if Time.get_ticks_msec()>=next_progress:
			_write(output.get_base_dir().path_join("progress.json"),state.snapshot())
			next_progress=Time.get_ticks_msec()+1000
		await process_frame
	var outcome: Dictionary=thread.wait_to_finish()
	checks.final_deadline=state.checkpoint("continuation_worker_returned")
	state.finish()
	var report := {"passed":outcome.get("ready",false) and checks.values().all(func(value):return value==true),
		"checks":checks,"outcome":outcome,"evidence":evidence,"progress":state.snapshot(true),
		"sourceSha256":source_sha,"inputSha256":input_sha,"sourcePath":source_path,"inputPath":input_path,
		"scope":"Exact artifact restoration, actual candidate/town/policy terrain admission and CPU publication preparation. No Recipe rebuild, scene publication, native terrain activation, furniture gameplay, rendering or NPC acceptance."}
	var encoded := JSON.stringify(report,"  ",true,true)
	if not state.checkpoint("continuation_report_encoded"):
		report.passed=false
		report.progress=state.snapshot(true)
		report.checks.final_deadline=false
		encoded=JSON.stringify(report,"  ",true,true)
	var report_file := FileAccess.open(output,FileAccess.WRITE)
	if report_file==null:quit(2);return
	report_file.store_string(encoded);report_file.flush()
	var saved := report_file.get_error()==OK
	report_file.close()
	print("CANDIDATE INTEGRATION CONTINUATION passed=",report.passed," outcome=",outcome)
	quit(0 if saved and report.passed else 1)

func _work() -> Dictionary:
	checks.pinned_artifacts=FileAccess.get_sha256(source_path)==source_sha and FileAccess.get_sha256(input_path)==input_sha
	if not checks.pinned_artifacts:return _fail("artifact_hash_mismatch")
	var source := _read(source_path)
	var input := _read(input_path)
	if source.is_empty() or input.is_empty():return _fail("artifact_read_failed")
	var frozen := var_to_bytes(source)
	var frozen_input := var_to_bytes(input)
	var candidate: Dictionary=Site.Field.candidate_for_region(input.worldSeed,input.candidate.region)
	checks.exact_candidate=candidate==input.candidate and candidate.recipeSeed==source.blueprint.seed
	if not checks.exact_candidate:return _fail("candidate_identity_mismatch")
	var context=Diagnostic.Context.new()
	context.seed_text=input.worldSeed;context.seed_hash=context.hash_string(input.worldSeed);context.setup_noise()
	var world=Diagnostic.World.new()
	world.setup(context);context.set_generator(world)
	var tutorial_region: Vector2i=Diagnostic.Tutorial.TUTORIAL_TOWN_REGION
	var town: Dictionary=context.town_region(tutorial_region.x,tutorial_region.y).duplicate(true)
	town.radius=Diagnostic.Tutorial.FENCE_RADIUS_CELLS
	var towns := {tutorial_region:town}
	checks.ordinary_towns_match_pinned_input=var_to_bytes(towns)==var_to_bytes(input.townOverrides)
	if not checks.ordinary_towns_match_pinned_input:return _fail("ordinary_town_input_mismatch")
	var furniture: Dictionary=source.furnishingPlan.duplicate(true)
	furniture["accessReservations"]=source.accessReservations.duplicate(true)
	var restored := Restore.restore(source.blueprint,furniture,state.checkpoint)
	checks.exact_restoration=restored.ready
	if not restored.ready:return restored
	var manifest := Manifest.build(restored.blueprint,restored.furnishingPlan,Site.CELL)
	checks.manifest_ready=manifest.ready
	if not manifest.ready:return manifest
	evidence.manifest={"sourceSignature":manifest.sourceSignature,"groundY":manifest.groundY}
	var policy := {"regionCells":MainPolicy.STRUCTURE_REGION_CELLS,"spawnChance":MainPolicy.STRUCTURE_SPAWN_CHANCE}
	var request := Queue._canonical_request(input.worldSeed,candidate.region,towns,policy)
	checks.production_request_valid=not request.is_empty()
	if request.is_empty():return _fail("invalid_canonical_request")
	evidence.candidate=candidate;evidence.ordinaryPolicy=policy;evidence.townOverrides=towns
	if not state.begin_phase("terrain_admission",60000):return _fail("cancelled")
	var level := roundf(float(input.centerSurvey.minimumSurfaceY)/Site.CELL)*Site.CELL
	var terrain := Site.prepare_terrain(manifest,candidate,request.towns,level,request.ordinaryPolicy,state.checkpoint)
	checks.terrain_prepared=terrain.get("status")=="prepared"
	if not checks.terrain_prepared:
		evidence.terrain=terrain
		return _fail("candidate_terrain_rejected",terrain)
	checks.profile_valid=Site.Profile.valid(terrain.profile,input.worldSeed,Site.CELL)
	checks.profile_source_bound=terrain.profile.sourceSignature==manifest.sourceSignature and terrain.profile.siteId==candidate.siteId
	checks.reservation_current=terrain.reservationCells.encloses(terrain.profile.reservationCells) and terrain.reservationCells.encloses(terrain.influenceCells) and Site.Field.reservation_fits_region(candidate.region,terrain.reservationCells)
	evidence.terrain={"status":terrain.status,"gradingRule":terrain.gradingRule,"survey":terrain.survey,
		"influenceCells":terrain.influenceCells,"reservationCells":terrain.reservationCells,
		"sourceSignature":terrain.profile.sourceSignature,"level":terrain.profile.level,"apronCells":terrain.profile.apronCells}
	if not checks.values().all(func(value):return value==true):return _fail("terrain_binding_failed")
	var binding := {"siteId":candidate.siteId,"sourceKey":request.sourceKey,"generation":1}
	evidence.bindingScope="Production candidate/source key; isolated service generation token, not runtime admission."
	evidence.binding=binding
	if not state.begin_phase("publication_preparation",60000):return _fail("cancelled")
	var prepared := Preparation.prepare_source(source.blueprint,furniture,binding,state.checkpoint)
	checks.publication_prepared=prepared.ready
	if not prepared.ready:return prepared
	var payload: Dictionary=prepared.prepared.take(binding)
	checks.prepared_binding_consumed=not payload.is_empty() and prepared.prepared.take(binding).is_empty()
	if payload.is_empty():return _fail("prepared_binding_failed")
	var physical: Dictionary=payload.physicalIntegrity
	checks.physical_passed=physical.get("passed")==true and physical.get("violations",[]).is_empty() and physical.get("checkedPartCount")==source.blueprint.parts.size()
	var expected_static: int=payload.blueprint.parts.filter(func(part):return part.collision_enabled and part.kind!="door").size()
	var expected_masonry: int=payload.blueprint.parts.filter(func(part):return Preparation.MasonrySelection.selected(part)).size()
	checks.static_metadata_complete=payload.staticRecords.size()==expected_static and payload.staticRecordBindings.size()==expected_static
	checks.history_complete=payload.preparedHistory!=null
	checks.masonry_complete=payload.preparedMasonry!=null and payload.preparedMasonry.count()==expected_masonry
	var source_id := String(payload.blueprint.recipe.get("sourceBlueprintId",payload.blueprint.id))
	checks.history_identity=payload.preparedHistory!=null and payload.preparedHistory.matches(payload.preparedHistory.history,source_id)
	checks.masonry_history_identity=checks.history_identity and payload.preparedMasonry!=null and payload.preparedMasonry.matches_history(payload.preparedHistory,payload.preparedHistory.history,source_id)
	checks.static_record_identity=true
	checks.masonry_part_identity=true
	for part in payload.blueprint.parts:
		if not state.checkpoint("publication_artifact_identity"):return _fail("cancelled")
		if part.collision_enabled and part.kind!="door":
			var encoded := Preparation.static_record_binding(part.snapshot())
			checks.static_record_identity=checks.static_record_identity and not encoded.is_empty() and payload.staticRecords.has(part.id) and payload.staticRecordBindings.get(part.id)==encoded and Preparation.static_record_binding(payload.staticRecords[part.id])==encoded
		if Preparation.MasonrySelection.selected(part):
			checks.masonry_part_identity=checks.masonry_part_identity and payload.preparedMasonry!=null and payload.preparedMasonry.validate_part(part)
	checks.furniture_exact=var_to_bytes(payload.furnishingPlan.snapshot())==var_to_bytes(source.furnishingPlan) and payload.furnishingPlan.access_reservations_snapshot()==source.accessReservations
	if not state.begin_phase("evidence_export",10000):return _fail("cancelled")
	evidence.publication={"physical":physical,"raisedRouteGeometry":payload.raisedRouteCoverage,
		"staticRecords":payload.staticRecords.size(),"expectedStaticRecords":expected_static,
		"masonryRecords":payload.preparedMasonry.count() if payload.preparedMasonry!=null else 0,"expectedMasonryRecords":expected_masonry,
		"metadataPreparationUsec":payload.metadataPreparationUsec,"historyPreparationUsec":payload.historyPreparationUsec,
		"masonryPreparationUsec":payload.masonryPreparationUsec,"physicalUsec":payload.physicalUsec,
		"furnitureCount":payload.furnishingPlan.parts.size(),"raisedRouteGeometryRequiredForPublication":false}
	checks.artifacts_immutable=frozen==var_to_bytes(source) and frozen_input==var_to_bytes(input) and FileAccess.get_sha256(source_path)==source_sha and FileAccess.get_sha256(input_path)==input_sha
	checks.evidence_deadline=state.checkpoint("continuation_evidence_completed")
	return {"ready":checks.values().all(func(value):return value==true),"reason":"" if checks.values().all(func(value):return value==true) else "continuation_checks_failed"}

func _read(path: String) -> Dictionary:
	var file := FileAccess.open(path,FileAccess.READ)
	if file==null or file.get_length()>67108864:return {}
	var value: Variant=file.get_var(false)
	if file.get_error()!=OK or file.get_position()!=file.get_length() or not value is Dictionary:return {}
	return value

func _write(path: String, value: Dictionary) -> bool:
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file==null:return false
	file.store_string(JSON.stringify(value,"  ",true,true));file.flush()
	return file.get_error()==OK

func _fail(reason: String, detail: Dictionary = {}) -> Dictionary:
	return {"ready":false,"reason":reason,"detail":detail}
