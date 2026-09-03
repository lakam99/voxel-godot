extends SceneTree

## Historical caller overlap attribution only, never live gameplay acceptance.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const SOURCE := "res://artifacts/citadel-runtime-integration/candidate-recipe-09/caller-blueprint.bin"
const SOURCE_SHA := "57ab941d9e714bb91415ee28b59efcbe8fde1b5c65699401c9df9178a561db12"
const FAILURE := "res://artifacts/citadel-runtime-integration/candidate-recipe-10/failure.bin"
const FAILURE_SHA := "56156dba3ea0f3fd456944a8cd70d6b7cf6abf5cb1437698f343b15d57ec67e0"
const COMPOSER := "res://artifacts/citadel-runtime-integration/terrace-reconciliation-10/report.bin"
const COMPOSER_SHA := "d74cb0dce3c103911dbc4a7da7dc19f225e5196e9257c6b866f1ac766f9874ab"

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var output := OS.get_environment("CITADEL_KEEP_STREET_OVERLAP_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output): quit(2); return
	var checks := {"historical_source_hash":FileAccess.get_sha256(SOURCE)==SOURCE_SHA,"current_failure_hash":FileAccess.get_sha256(FAILURE)==FAILURE_SHA}
	if not checks.historical_source_hash or not checks.current_failure_hash: quit(2); return
	var file := FileAccess.open(SOURCE,FileAccess.READ)
	var snapshot: Dictionary=file.get_var(false)
	file.close()
	file=FileAccess.open(FAILURE,FileAccess.READ)
	var failure: Dictionary=file.get_var(false)
	file.close()
	var detail: Dictionary=failure.structuralCompletionFailure.detail.detail.failureEvidence
	checks["current_composer_hash"]=FileAccess.get_sha256(COMPOSER)==COMPOSER_SHA
	if not checks.current_composer_hash: quit(2); return
	file=FileAccess.open(COMPOSER,FileAccess.READ)
	var composer: Dictionary=file.get_var(false)
	file.close()
	checks["composer_evidence_passed"]=composer.passed and composer.phase=="composer"
	var gable_id := String(detail.gableId)
	var blockers: Array=[]
	for attempt: Dictionary in detail.blockedPlacements:
		if not blockers.has(attempt.blockingPartId): blockers.append(attempt.blockingPartId)
	checks["one_current_blocker"]=blockers.size()==1
	if blockers.size()!=1: quit(2); return
	var source = Copy.copy_blueprint(snapshot)
	var before := var_to_bytes(source.snapshot())
	var gable = source.find_part(gable_id)
	var tower = source.find_part(String(blockers[0]))
	checks["both_parts_exist_in_pre_repair_caller"]=gable!=null and tower!=null
	if gable==null or tower==null: quit(2); return
	checks["historical_real_parts_overlap_zero_margin"]=source.transformed_parts_overlap(gable,tower,0.0)
	var grammar: Dictionary=snapshot.recipe.castleGrammar
	var base := float(snapshot.recipe.foundationHeight)
	var depth := float(grammar.courtyardDepth)
	var front := -depth*0.5
	var keep_front := depth*float(grammar.get("keepOffset",{}).get("z",0.14))-float(grammar.keepDepth)*0.5
	var fresh = Blueprint.new("street-producer-replay",snapshot.seed,snapshot.style)
	var reset: Dictionary=Urban.reset_street_house_structural_manifest(fresh)
	var produced: Dictionary=Urban.add_street_sequence(fresh,front,keep_front,base,float(snapshot.seed%19)/100.0-0.09,snapshot.recipe.urbanPoc)
	checks["current_street_producer_ready"]=reset.ready and produced.ready
	var fresh_gable = fresh.find_part(gable_id)
	# find_part reads the physical resolver's index; a bare producer has not
	# populated it. Preserve that initial experiment and inspect emitted parts.
	var isolated_match: bool=fresh_gable!=null and var_to_bytes(fresh_gable.snapshot())==var_to_bytes(gable.snapshot())
	var emitted: Array=fresh.parts.filter(func(part): return part.id==gable_id)
	checks["current_emitted_gable_matches_historical_record"]=emitted.size()==1 and var_to_bytes(emitted[0].snapshot())==var_to_bytes(gable.snapshot())
	var realized = Copy.copy_blueprint(composer.evidence.realizedSource)
	var current_gable = realized.find_part(gable_id)
	var current_tower = realized.find_part(String(blockers[0]))
	checks["actual_composer_gable_exactly_unchanged"]=current_gable!=null and var_to_bytes(current_gable.snapshot())==var_to_bytes(gable.snapshot())
	checks["actual_composer_tower_exactly_unchanged"]=current_tower!=null and var_to_bytes(current_tower.snapshot())==var_to_bytes(tower.snapshot())
	checks["actual_composer_overlap_zero_margin"]=current_gable!=null and current_tower!=null and realized.transformed_parts_overlap(current_gable,current_tower,0.0)
	var originals: Dictionary=composer.evidence.result.terraceOriginals
	var replacements: Dictionary=composer.evidence.result.terraceReplacements
	checks["neither_part_replaced"]=not originals.has(gable_id) and not originals.has(tower.id) and not replacements.has(gable_id) and not replacements.has(tower.id)
	checks["caller_unchanged"]=before==var_to_bytes(source.snapshot())
	var report := {"passed":checks.values().all(func(value): return value==true),"checks":checks,"sourceSha256":SOURCE_SHA,"failureSha256":FAILURE_SHA,
		"gable":gable.snapshot(),"currentGable":current_gable.snapshot() if current_gable!=null else {},"blocker":tower.snapshot(),"gableBounds":source.transformed_part_bounds(gable),"blockerBounds":source.transformed_part_bounds(tower),
		"composerSha256":COMPOSER_SHA,"isolatedStreetProducerRecordMatch":isolated_match,"isolatedStreetProducerRecordPresent":fresh_gable!=null,
		"currentAttemptCount":detail.attempts,"currentCompletedHouseCount":failure.structuralCompletionFailure.detail.detail.completedHouseCount,
		"scope":"exact pre-repair caller records and current realized civic Composer records plus shared zero-margin part SAT; proves pre-existing geometric overlap, not historical facade-run equivalence, physical integrity, rendering or gameplay"}
	file=FileAccess.open(output.get_basename()+".bin",FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_var(report,false); file.flush()
	var saved := file.get_error()==OK
	file.close()
	file=FileAccess.open(output,FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(report,"\t")); file.flush()
	saved=saved and file.get_error()==OK
	file.close()
	print("Keep/street historical overlap diagnostic passed=",report.passed," checks=",checks.size())
	quit(0 if saved and report.passed else 1)
