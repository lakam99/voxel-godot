extends SceneTree

## Explicitly synthetic masonry geometry through real declaration/physical
## proof APIs. No Castle build, archive replay, scene or gameplay acceptance.
const Recipe = preload("res://scripts/buildings/MasonryPartyWallBearingRecipe.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Completion = preload("res://scripts/buildings/CitadelStructuralCompletionRecipe.gd")
const ORIGINAL := "res://artifacts/citadel-runtime-integration/party-wall-frozen-original/MasonryPartyWallBearingRecipe.gd"
const ORIGINAL_SHA := "7e76cdd46d12b6c159787428135763c3838ff6c43147078063b7133bf3a1202b"
var output := ""
var deadline := 0
var checks: Dictionary = {}
var evidence: Dictionary = {}
var reject_stage := ""
var rejected := false
var after_false := 0
var stage_counts: Dictionary = {}

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	output=OS.get_environment("MASONRY_PARTY_WALL_PROOF_REUSE_REPORT")
	if not output.is_absolute_path() or FileAccess.file_exists(output) or FileAccess.file_exists(output.get_basename()+".bin"): quit(2); return
	deadline=Time.get_ticks_msec()+30000
	var worker := Thread.new()
	if worker.start(_work)!=OK: quit(2); return
	while worker.is_alive(): await process_frame
	var report: Dictionary=worker.wait_to_finish()
	var saved: bool=_write(report)
	print("Party-wall proof reuse checks=",checks.size()," passed=",report.passed)
	quit(0 if saved and report.passed else 1)

func _work() -> Dictionary:
	var started := Time.get_ticks_usec()
	var hashes: Dictionary=_hashes()
	_exercise()
	var after: Dictionary=_hashes()
	checks["sources_unchanged"]=hashes==after
	checks["deadline"]=Time.get_ticks_msec()<deadline
	return {"passed":checks.values().all(func(value): return value==true),"checks":checks,"evidence":evidence,"sourceHashesBefore":hashes,"sourceHashesAfter":after,"elapsedUsec":Time.get_ticks_usec()-started,"internalDeadlineSeconds":30,
		"scope":"Synthetic two-panel facade, independently rooted masonry overlap wall and second supported declaration. Real source proof/planning APIs, no archived/full Recipe, scene or gameplay acceptance."}

func _exercise() -> void:
	var key := "synthetic_facade"
	var source = Recipe.Blueprint.new("synthetic-party-wall-proof",123,"masonry")
	source.add_part({"id":"seat_root","kind":"foundation","position":Vector3(0,0.25,-1.5),"size":Vector3(1,0.5,1)})
	var seat = source.add_part({"id":"other_producer_wall","kind":"wall","position":Vector3(0,2,-1.5),"size":Vector3(1,3,1)})
	checks["declared_synthetic_seat"]=Recipe.declare_party_wall_seat(seat)
	var lower = source.add_part({"id":key+"_lower","kind":"wall","semantic":"citadel_urban_facade","position":Vector3(0,2,0),"size":Vector3(0.3,1,4)})
	var upper = source.add_part({"id":key+"_upper","kind":"wall","semantic":"citadel_urban_facade","position":Vector3(0,3,0),"size":Vector3(0.3,1,4)})
	source.recipe["facadeApertures"]={key:Recipe.Aperture.seal({"producerPrefix":key},[lower,upper])}
	var seats: Dictionary={seat.id:true}; var roots: Dictionary={"seat_root":true}
	evidence["syntheticSource"]=source.snapshot()
	var initial: PackedByteArray=var_to_bytes(source.snapshot())
	var prepared: Dictionary=Recipe.prepare_context(source,_continue)
	checks["actual_context_ready"]=prepared.get("ready")==true and prepared.has("context")
	if not checks.actual_context_ready: evidence["preparationFailure"]=prepared; return
	var context = prepared.context
	var plain: Dictionary=Recipe.plan(source,key)
	var cached: Dictionary=Recipe.plan(source,key,context,_continue)
	var repeat: Dictionary=Recipe.plan(source,key,context,_continue)
	checks["actual_successful_party_wall_plan"]=plain.get("ready")==true and not plain.get("changes",[]).is_empty()
	checks["actual_cached_uncached_exact"]=var_to_bytes(plain)==var_to_bytes(cached)
	checks["deterministic_context_reuse"]=var_to_bytes(cached)==var_to_bytes(repeat)
	checks["independent_proof_never_reused"]=context.independent_validations==2
	checks["source_immutable_after_reuse"]=initial==var_to_bytes(source.snapshot())
	evidence["actualPlan"]=cached
	if not checks.actual_successful_party_wall_plan: return
	checks["exact_floating_bottom_target"]=plain.targetIds==[lower.id]
	_support_memo_controls(source,plain)
	_geometric_controls(source,key,plain,seats,roots)
	_noop(source,"missing-declaration","missing_declaration","missing_facade_declaration")
	var applied = Copy.copy_blueprint(source.snapshot())
	checks["apply_actual_plan"]=Recipe.apply_plan(applied,plain).get("ready")==true
	_noop(applied,key,"already_supported","no_failed_bottom_cohort")
	_noop_mutation_controls(applied,key)
	var stale = Copy.copy_blueprint(source.snapshot())
	stale.parts[0].recipe["fixtureRevision"]=1
	_reject_plan("stale_source",stale,key,context,"stale_party_wall_source_proof")
	_reject_plan("empty_context",source,key,Recipe.ProofContext.new(),"invalid_party_wall_proof_context")
	_reject_plan("malformed_context",source,key,{},"invalid_party_wall_proof_context")
	_context_controls(source,key)
	for control: String in ["roots_removed","circular_seat_obligation"]:
		var negative = Copy.copy_blueprint(source.snapshot())
		if control=="roots_removed": negative.parts=negative.parts.filter(func(part): return not roots.has(part.id))
		else:
			for part in negative.parts:
				if seats.has(part.id): part.recipe["physicalRequiredSeatPartIds"]=[plain.targetIds[0]]
		var negative_before: PackedByteArray=var_to_bytes(negative.snapshot())
		var negative_context: Dictionary=Recipe.prepare_context(negative,_continue)
		checks[control+"_context_ready"]=negative_context.get("ready")==true
		if not negative_context.get("ready",false): continue
		var uncached: Dictionary=Recipe.plan(negative,key)
		var bounded: Dictionary=Recipe.plan(negative,key,negative_context.context,_continue)
		checks[control+"_independent_rejection"]=uncached.get("reason")=="no_finite_rooted_party_wall" and var_to_bytes(uncached)==var_to_bytes(bounded) and not bounded.has("changes") and negative_context.context.independent_validations==1 and negative_context.context.geometric_rejections==0 and negative_before==var_to_bytes(negative.snapshot())
		evidence[control]=bounded
	_integration(source,key)
	_cancellation_controls(source,key,context)
	checks["source_still_immutable"]=initial==var_to_bytes(source.snapshot())

func _warm_support(source, identities: Dictionary) -> void:
	var copy=Copy.copy_blueprint(source.snapshot())
	var proof=Recipe.SupportMemo.new(copy.id,copy.seed,copy.style)
	proof.recipe=copy.recipe; proof.rooms=copy.rooms; proof.parts=copy.parts; proof.identities=identities
	proof.validate_physical_integrity()

func _support_memo_controls(source, plan: Dictionary) -> void:
	var identities:Dictionary={}
	_warm_support(source,identities)
	var fresh:=Recipe.prepare_context(source)
	var shared:=Recipe._prepare_context_with_support_memo(source,Callable(),identities)
	checks["support_memo_complete_report_snapshot_parity"]=fresh.ready and shared.ready and var_to_bytes(fresh.context.report)==var_to_bytes(shared.context.report) and var_to_bytes(fresh.context.proof.snapshot())==var_to_bytes(shared.context.proof.snapshot())
	if not shared.ready:return
	checks["support_memo_hits_and_public_default_fresh"]=shared.context.proof.observations.hits>0 and fresh.context.proof.get_script()==Recipe.Blueprint
	checks["support_memo_context_detached"]=shared.context.proof.identities.is_empty() and not is_same(shared.context.proof.identities,identities)
	shared.context.proof.parts[0].recipe["tampered"]=true
	checks["support_memo_context_tamper_rejected"]=not Recipe._context_valid(source,shared.context).ready
	for mode in ["accepted_plan","moved_root"]:
		var changed=Copy.copy_blueprint(source.snapshot())
		if mode=="accepted_plan": Recipe.apply_plan(changed,plan)
		else: changed.parts[0].position.x+=20
		_warm_support(source,identities)
		var cold:=Recipe.prepare_context(changed)
		var warm:=Recipe._prepare_context_with_support_memo(changed,Callable(),identities)
		checks["support_memo_changed_proof_"+mode]=cold.ready and warm.ready and var_to_bytes(cold.context.report)==var_to_bytes(warm.context.report) and var_to_bytes(cold.context.proof.snapshot())==var_to_bytes(warm.context.proof.snapshot())
		if mode=="moved_root":checks["support_memo_pool_change_misses"]=warm.ready and not warm.context.proof.observations.poolRepeated and warm.context.proof.observations.misses>0
	for stage in ["party_wall_proof_started","physical_resolve_support","party_wall_proof_completed"]:
		_warm_support(source,identities)
		var result:=Recipe._prepare_context_with_support_memo(source,func(label):return label!=stage,identities)
		checks["support_memo_cancel_"+stage]=result.get("reason")=="cancelled" and identities.is_empty()

func _geometric_controls(source, key: String, positive: Dictionary, seats: Dictionary, roots: Dictionary) -> void:
	checks["frozen_original_sha"]=FileAccess.file_exists(ORIGINAL) and FileAccess.get_sha256(ORIGINAL)==ORIGINAL_SHA
	if not checks.frozen_original_sha: return
	var oracle = load(ORIGINAL)
	var initial: PackedByteArray=var_to_bytes(source.snapshot())
	var old_positive: Dictionary=oracle.plan(source,key)
	checks["original_success_complete_byte_parity"]=var_to_bytes(old_positive)==var_to_bytes(positive) and initial==var_to_bytes(source.snapshot())
	var disjoint = Copy.copy_blueprint(source.snapshot())
	for part in disjoint.parts:
		if seats.has(part.id) or roots.has(part.id): part.position.x+=20.0
	var before: PackedByteArray=var_to_bytes(disjoint.snapshot())
	var prepared: Dictionary=Recipe.prepare_context(disjoint,_continue)
	checks["disjoint_context_ready"]=prepared.get("ready")==true
	if not prepared.get("ready",false): return
	var old_result: Dictionary=oracle.plan(disjoint,key)
	var current: Dictionary=Recipe.plan(disjoint,key,prepared.context,_continue)
	checks["disjoint_original_complete_byte_parity"]=old_result.get("reason")=="no_finite_rooted_party_wall" and var_to_bytes(old_result)==var_to_bytes(current) and before==var_to_bytes(disjoint.snapshot())
	checks["disjoint_skips_only_independent_proof"]=prepared.context.independent_validations==0 and prepared.context.geometric_rejections==1
	evidence["disjointGeometricRejection"]={"old":old_result,"current":current,"independentValidations":prepared.context.independent_validations,"geometricRejections":prepared.context.geometric_rejections}
	for mode: String in ["cancel","source_mutation"]:
		var target = Copy.copy_blueprint(disjoint.snapshot())
		var bound: Dictionary=Recipe.prepare_context(target,_continue)
		checks["prefilter_context_ready_"+mode]=bound.get("ready")==true
		if not bound.get("ready",false): continue
		var state: Dictionary={"reached":false,"rejected":false,"after":0}
		var callback := func(stage: String) -> bool:
			if state.rejected: state.after+=1; return false
			if stage=="party_wall_contact_prefilter" and not state.reached:
				state.reached=true
				if mode=="cancel": state.rejected=true; return false
				target.recipe["fixturePrefilterMutation"]=true
			return _continue(stage)
		var result: Dictionary=Recipe.plan(target,key,bound.context,callback)
		var reason: String="cancelled" if mode=="cancel" else "stale_party_wall_source_proof"
		checks["prefilter_guard_"+mode]=state.reached and state.after==0 and result.get("ready")==false and result.get("reason")==reason and not result.has("changes") and not result.has("targetIds") and bound.context.independent_validations==0
		if mode=="cancel": checks["prefilter_cancel_source_immutable"]=before==var_to_bytes(target.snapshot())
		evidence["prefilter_guard_"+mode]={"result":result,"callbackState":state}

func _noop(source, key: String, label: String, reason: String) -> void:
	var before: PackedByteArray=var_to_bytes(source.snapshot())
	var prepared: Dictionary=Recipe.prepare_context(source,_continue)
	checks[label+"_context_ready"]=prepared.get("ready")==true
	if not prepared.get("ready",false): return
	var plain: Dictionary=Recipe.plan(source,key)
	var cached: Dictionary=Recipe.plan(source,key,prepared.context,_continue)
	checks[label+"_exact_noop"]=plain.get("reason")==reason and not plain.has("changes") and var_to_bytes(plain)==var_to_bytes(cached) and prepared.context.independent_validations==0 and before==var_to_bytes(source.snapshot())
	evidence[label]=plain

func _reject_plan(label: String, source, key: String, context, reason: String) -> void:
	var before: PackedByteArray=var_to_bytes(source.snapshot())
	var result: Dictionary=Recipe.plan(source,key,context,_continue)
	checks[label]=result.get("ready")==false and result.get("reason")==reason and not result.has("changes") and not result.has("targetIds") and not result.has("blueprint") and before==var_to_bytes(source.snapshot())
	evidence[label]=result

func _noop_mutation_controls(applied, key: String) -> void:
	for mode: String in ["source","report"]:
		var source = Copy.copy_blueprint(applied.snapshot())
		var prepared: Dictionary=Recipe.prepare_context(source,_continue)
		checks["direct_noop_context_ready_"+mode]=prepared.get("ready")==true
		if not prepared.get("ready",false): continue
		var state: Dictionary={"mutated":false,"panelCallbacks":0}
		var callback := func(stage: String) -> bool:
			if stage=="party_wall_panel":
				state.panelCallbacks+=1
				if not state.mutated:
					if mode=="source": source.recipe["fixtureNoopMutation"]=true
					else: prepared.context.report["fixtureNoopMutation"]=true
					state.mutated=true
			return _continue(stage)
		var result: Dictionary=Recipe.plan(source,key,prepared.context,callback)
		var reason: String="stale_party_wall_source_proof" if mode=="source" else "modified_party_wall_proof_context"
		checks["direct_noop_pending_binding_"+mode]=state.mutated and state.panelCallbacks>0 and result.get("ready")==false and result.get("reason")==reason and not result.has("changes") and not result.has("targetIds") and prepared.context.independent_validations==0
		evidence["direct_noop_pending_binding_"+mode]={"result":result,"callbackState":state}

func _context_controls(source, key: String) -> void:
	for field: String in ["proof","report","invalid_gable","index_missing","index_replacement","active_cache"]:
		var prepared: Dictionary=Recipe.prepare_context(source,_continue)
		checks["tamper_context_ready_"+field]=prepared.get("ready")==true
		if not prepared.get("ready",false): continue
		var context = prepared.context
		match field:
			"proof": context.proof.parts[0].position.x+=0.125
			"report": context.report["fixtureTamper"]=true
			"invalid_gable": context.proof.invalid_gable_part_ids["fixture"]=true
			"index_missing": context.proof.physical_parts_by_id.erase(context.proof.parts[0].id)
			"index_replacement": context.proof.physical_parts_by_id[context.proof.parts[0].id]=Recipe.Part.new(context.proof.parts[0].snapshot())
			"active_cache": context.proof._validation_cache_active=true
		_reject_plan("tamper_"+field,source,key,context,"modified_party_wall_proof_context")

func _integration(source, key: String) -> void:
	var working = Copy.copy_blueprint(source.snapshot())
	working.add_part({"id":"synthetic_root","kind":"foundation","position":Vector3(100,0.5,0),"size":Vector3(4,1,4)})
	var panel = working.add_part({"id":"synthetic_supported_panel","kind":"wall","semantic":"citadel_urban_facade","position":Vector3(100,2,0),"size":Vector3(0.3,2,2)})
	var noop_key := "synthetic_supported"
	working.recipe.facadeApertures[noop_key]=Recipe.Aperture.seal({"producerPrefix":noop_key},[panel])
	var expected = Copy.copy_blueprint(working.snapshot())
	var planned: Dictionary=Recipe.plan(expected,key)
	checks["integration_uncached_success"]=planned.get("ready")==true
	if not planned.get("ready",false): return
	Recipe.apply_plan(expected,planned)
	var result: Dictionary=Completion._complete_party_walls(working,[{"facadeDeclarationKeys":[key,noop_key,noop_key]}],_continue)
	evidence["syntheticCompletionIntegration"]=result
	checks["completion_exact_apply_and_noop"]=result.get("ready")==true and result.accepted.size()==1 and result.pending.is_empty() and var_to_bytes(working.snapshot())==var_to_bytes(expected.snapshot())
	checks["completion_proof_accounting"]=result.get("sourceProofBuilds")==2 and result.get("sourceProofReuses")==1 and result.get("sourceProofInvalidations")==1 and result.get("independentProofs")==1
	var passing: Dictionary=Recipe.prepare_context(working,_continue)
	checks["last_noop_mutation_fixture_has_no_failures"]=passing.get("ready")==true and Copy.failed_ids(passing.context.report).is_empty()
	# Callback mutation is deliberate synthetic hostile/reentrant caller behavior.
	for mode: String in ["last_noop","post_apply","last_noop_proof_started"]:
		var mutated = Copy.copy_blueprint(source.snapshot() if mode=="post_apply" else working.snapshot())
		var state: Dictionary={"seen":0,"mutated":false,"after":0}
		var target_stage: String="party_wall_item:"+noop_key if mode=="last_noop" else "party_wall_item_completed:"+key
		if mode=="last_noop_proof_started": target_stage="party_wall_proof_started"
		var callback := func(stage: String) -> bool:
			if state.mutated: state.after+=1
			if stage==target_stage:
				state.seen+=1
				if mode!="last_noop" or state.seen==2:
					mutated.recipe["fixtureCallbackMutation"]=mode
					state.mutated=true
			return _continue(stage)
		var keys: Array=[noop_key,noop_key] if mode=="last_noop" else [key]
		if mode=="last_noop_proof_started": keys=[noop_key]
		var rejection: Dictionary=Completion._complete_party_walls(mutated,[{"facadeDeclarationKeys":keys}],callback)
		var expected_reason: String="stale_party_wall_source_proof" if mode=="last_noop_proof_started" else "party_wall_source_changed_during_completion"
		checks["callback_mutation_"+mode]=state.mutated and state.after==0 and rejection.get("ready")==false and rejection.get("reason")==expected_reason and not rejection.has("accepted") and not rejection.has("context") and not rejection.has("changes")
		evidence["callback_mutation_"+mode]={"result":rejection,"callbackState":state}

func _cancellation_controls(source, key: String, context) -> void:
	for mode: String in ["prepare_validator","independent_validator","independent_completed"]:
		rejected=false; after_false=0; stage_counts.clear()
		reject_stage="party_wall_independent_proof_completed" if mode=="independent_completed" else "physical_validation_part"
		var before: PackedByteArray=var_to_bytes(source.snapshot())
		var result: Dictionary=Recipe.prepare_context(source,_continue) if mode=="prepare_validator" else Recipe.plan(source,key,context,_continue)
		checks["cancel_"+mode]=rejected and after_false==0 and result.get("reason")=="cancelled" and not result.has("context") and not result.has("changes") and not result.has("targetIds") and before==var_to_bytes(source.snapshot())
		if mode!="prepare_validator": checks["independent_stage_reached_"+mode]=stage_counts.has("party_wall_independent_proof_started")
		evidence["cancel_"+mode]={"result":result,"stageCounts":stage_counts.duplicate(),"afterFalse":after_false}
	rejected=false; after_false=0; stage_counts.clear()
	reject_stage="party_wall_independent_proof_completed"
	var working = Copy.copy_blueprint(source.snapshot())
	var initial: PackedByteArray=var_to_bytes(working.snapshot())
	var stage_result: Dictionary=Completion._complete_party_walls(working,[{"facadeDeclarationKeys":[key]}],_continue)
	checks["completion_cancel_no_later_callback"]=rejected and stage_counts.has(reject_stage) and after_false==0 and stage_result.get("ready")==false and stage_result.get("reason")=="cancelled" and not stage_result.has("accepted") and not stage_result.has("changes") and initial==var_to_bytes(working.snapshot())
	evidence["completionCancellation"]={"result":stage_result,"stageCounts":stage_counts.duplicate(),"afterFalse":after_false}
	reject_stage=""; rejected=false; after_false=0

func _continue(stage: String) -> bool:
	if rejected: after_false+=1; return false
	stage_counts[stage]=int(stage_counts.get(stage,0))+1
	rejected=stage==reject_stage or Time.get_ticks_msec()>=deadline
	return not rejected

func _hashes() -> Dictionary:
	var result: Dictionary={}
	var pending: Array[String]=[get_script().resource_path]
	var regex := RegEx.create_from_string('["\'](res://[^"\'\\r\\n]+)["\']')
	while not pending.is_empty():
		var path: String=pending.pop_back()
		if result.has(path): continue
		result[path]=FileAccess.get_sha256(path) if FileAccess.file_exists(path) else ""
		if String(result[path]).length()!=64: checks["source_hashes_valid"]=false; continue
		for matched: RegExMatch in regex.search_all(FileAccess.get_file_as_string(path)):
			var dependency: String=matched.get_string(1)
			if dependency.get_extension() in ["gd","gdshader"]: pending.append(dependency)
	return result

func _write(report: Dictionary) -> bool:
	var file := FileAccess.open(output.get_basename()+".bin",FileAccess.WRITE)
	if file==null: return false
	file.store_var(report,false); file.flush()
	var saved: bool=file.get_error()==OK
	file.close()
	file=FileAccess.open(output,FileAccess.WRITE)
	if file==null: return false
	file.store_string(JSON.stringify(_json(report),"\t",true,true)); file.flush()
	saved=saved and file.get_error()==OK
	file.close()
	return saved

func _json(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary={}
		for key: Variant in value: result[str(key)]=_json(value[key])
		return result
	if value is Array: return value.map(_json)
	if value is Vector3: return {"type":"Vector3","value":[value.x,value.y,value.z]}
	if value is Vector2: return {"type":"Vector2","value":[value.x,value.y]}
	if value is AABB or value is Rect2: return {"type":type_string(typeof(value)),"position":_json(value.position),"size":_json(value.size)}
	return value
