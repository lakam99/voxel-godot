extends "res://scripts/testing/buildings/CitadelBuntingAnchorRecipeContract.gd"
## Synthetic lifecycle contract through the real completion stage. Inherited
## harness supplies deadline, immutable dependency hashes and safe reporting.
const Structural = preload("res://scripts/buildings/CitadelStructuralCompletionRecipe.gd")
const Manifest = preload("res://scripts/buildings/CitadelBuntingAssemblyManifest.gd")

func _exercise() -> void:
	var source = Copy.copy_blueprint(_source().snapshot())
	# Real mandatory sockets at the represented (overlong) endpoints fail the
	# ordinary physical proof. No fake failure report or injected selector.
	var initial_rope=source.find_part("line")
	initial_rope.physical_intent="facade_attachment"
	initial_rope.recipe.physicalIntent="facade_attachment"
	initial_rope.recipe.physicalRequiredAnchorPartIds=["wall_-1","wall_1"]
	var half: Vector3=Vector3(minf(initial_rope.size.y,initial_rope.size.z),initial_rope.size.y,initial_rope.size.z)*0.25
	initial_rope.recipe.physicalRequiredAnchorFacts=[]
	for side: int in [-1,1]:
		initial_rope.recipe.physicalRequiredAnchorFacts.append({"anchorId":"wall_%d"%side,"contactMode":"attachment_socket",
			"localMountCenter":Vector3(side*(initial_rope.size.x*0.5-half.x),0,0),"localMountHalfExtents":half})
	var single: Array = _assemblies()
	var passing: Dictionary = Recipe.prepare(source,single,[],_continue)
	checks.passing_fixture_ready=passing.get("ready",false)
	if not checks.passing_fixture_ready:return
	var passing_source=_apply(source,passing.changes)
	var all_assemblies: Array=single.duplicate(true)
	var second := {"ropeId":"passing_line","pennantIds":[]}
	var retained: Dictionary={}
	for id: String in ["line","flag_0","flag_1","flag_2"]:
		var record: Dictionary=passing_source.find_part(id).snapshot()
		record.id="passing_"+id
		record.position.z=-0.7
		source.add_part(record);source.parts.back().size=record.size
		retained[record.id]=var_to_bytes(source.parts.back().snapshot())
		if id!="line":second.pennantIds.append(record.id)
	all_assemblies.append(second)
	checks.manifest_declared = Manifest.declare(source,all_assemblies).ready
	var frozen := var_to_bytes(source.snapshot())
	var result: Dictionary = Structural._complete_bunting(source,[],_continue)
	evidence.completion = result.duplicate(true); evidence.completion.erase("afterSnapshot")
	checks.completion_ready = result.get("ready",false)
	checks.source_immutable = frozen == var_to_bytes(source.snapshot())
	if not checks.completion_ready: return
	checks.failed_assembly_selected = result.assemblies.size()==1 and result.assemblies[0].ropeId=="line"
	var completed = Copy.copy_blueprint(result.afterSnapshot)
	checks.mixed_batch_passing_members_exact=retained.keys().all(func(id):return retained[id]==var_to_bytes(completed.find_part(id).snapshot()))
	var terminal: Dictionary = completed.validate_physical_integrity_cancellable(_continue)
	checks.ordinary_terminal_proof_passed = terminal.get("passed",false)
	var verified: Dictionary = Recipe.verify_stored(completed,result.assemblies,result.protectedBounds,_continue)
	checks.stored_verification_passed = verified.get("ready",false) and verified.get("physicalValidations",-1)==0
	evidence.stored_verification = verified
	var actual_sweeps: Array=Structural.DoorGeometry.ordinary_sweep_bounds(Vector3(1.1,2.4,0.22),Transform3D(Basis.IDENTITY,Vector3(30,2,0)))
	checks.real_door_sweep_records_present=not actual_sweeps.is_empty() and actual_sweeps.all(func(value):return value is Dictionary and value.get("bounds") is AABB)
	var with_sweeps: Dictionary=Structural._complete_bunting(source,actual_sweeps,_continue)
	checks.real_door_records_prepare=with_sweeps.get("ready",false)
	var verify_sweeps: Dictionary=Structural._verify_final_bunting(completed,{"assemblies":result.assemblies,"protectedBounds":actual_sweeps},_continue)
	checks.real_door_records_terminal=verify_sweeps.get("ready",false)
	var blocking_sweeps: Array=Structural.DoorGeometry.ordinary_sweep_bounds(Vector3(1.1,2.4,0.22),Transform3D(Basis.IDENTITY,Vector3(0,3.5,0)))
	var rejected_sweeps: Dictionary=Structural._verify_final_bunting(completed,{"assemblies":result.assemblies,"protectedBounds":blocking_sweeps},_continue)
	checks.real_blocking_door_sweep_rejected=not blocking_sweeps.is_empty() and rejected_sweeps.get("reason")=="terminal_bunting_invalid" and rejected_sweeps.get("detail",{}).get("reason")=="bunting_span_blocked"
	var bad_records: Array=[{"name":"malformed","bounds":"not_geometry"}]
	var bad: Dictionary=Structural._verify_final_bunting(completed,{"assemblies":result.assemblies,"protectedBounds":bad_records},_continue)
	checks.invalid_door_record_rejected=bad.get("detail",{}).get("reason")=="invalid_bunting_protected_volume"
	for target: String in ["bunting_verify_stored","bunting_verify_completed"]:
		var state := {"seen":false}
		var stopped: Dictionary=Structural._verify_final_bunting(completed,result,func(stage: String)->bool:
			if stage==target:state.seen=true;return false
			return _continue(stage))
		checks["terminal_wrapper_"+target+"_cancelled"]=state.seen and stopped=={"ready":false,"reason":"cancelled"}
	for mutate_policy: bool in [false,true]:
		var trial=Copy.copy_blueprint(source.snapshot())
		var protected: Array=[]
		var state := {"seen":false}
		var stopped: Dictionary=Structural._complete_bunting(trial,protected,func(stage: String)->bool:
			if stage=="bunting_completion_started":
				state.seen=true
				if mutate_policy:protected.append(AABB(Vector3(100,100,100),Vector3.ONE))
				else:trial.recipe["entryMutation"]=true
			return _continue(stage))
		checks["entry_mutation_"+str(mutate_policy)+"_rejected"]=state.seen and stopped.get("reason")=="bunting_completion_inputs_changed" and not stopped.has("afterSnapshot")
	var repeated: Dictionary = Structural._complete_bunting(Copy.copy_blueprint(result.afterSnapshot),[],_continue)
	checks.passing_assembly_not_selected = repeated.get("ready",false) and repeated.assemblies.is_empty()
	checks.passing_source_byte_exact = repeated.get("ready",false) and var_to_bytes(repeated.afterSnapshot)==var_to_bytes(result.afterSnapshot)
	for mode: String in ["cancel_selection","cancel_proposal","cancel_completed","stale_selection","incomplete_manifest"]:
		var trial = Copy.copy_blueprint(source.snapshot())
		if mode=="incomplete_manifest":trial.recipe[Manifest.KEY]=[]
		var before := var_to_bytes(trial.snapshot())
		var state := {"seen":false}
		var failed: Dictionary = Structural._complete_bunting(trial,[],func(stage: String)->bool:
			if mode=="stale_selection" and stage=="structural_physical_completed": trial.recipe["mutated"]=true; state.seen=true
			var target: String = {"cancel_selection":"structural_physical_started","cancel_proposal":"bunting_started","cancel_completed":"bunting_completion_completed"}.get(mode,"")
			if stage==target:state.seen=true; return false
			return _continue(stage))
		checks[mode+"_fails_without_snapshot"] = not failed.get("ready",true) and not failed.has("afterSnapshot")
		if mode.begins_with("cancel_"):
			checks[mode+"_cancel_reason"] = state.seen and failed.get("reason")=="cancelled" and before==var_to_bytes(trial.snapshot())
		if mode=="stale_selection": checks.stale_callback_reached = state.seen
		evidence[mode]=failed
	# A later colliding addition must invalidate stored clearance, not prompt
	# another placement or silently accept the pre-threshold proof.
	var blocked = Copy.copy_blueprint(result.afterSnapshot)
	blocked.add_part({"id":"later_column","kind":"foundation","position":Vector3(0,2,0),"size":Vector3(1,4,1)})
	var blocked_proof: Dictionary = blocked.validate_physical_integrity_cancellable(_continue)
	var blocked_bytes := var_to_bytes(blocked.snapshot())
	var rejection: Dictionary = Recipe.verify_stored(blocked,result.assemblies,result.protectedBounds,_continue)
	checks.later_addition_rejected_without_relocation = not rejection.get("ready",true) and blocked_bytes==var_to_bytes(blocked.snapshot())
	evidence.later_addition = {"verification":rejection,"terminalPassed":blocked_proof.get("passed",false)}
	for fact_mode: String in ["foreign_anchor","missing_socket"]:
		var trial = Copy.copy_blueprint(result.afterSnapshot)
		var rope=trial.find_part("line")
		if fact_mode=="foreign_anchor":rope.recipe.physicalRequiredAnchorPartIds=["root_-1","root_1"]
		else:rope.recipe.physicalRequiredAnchorFacts=[]
		trial.validate_physical_integrity_cancellable(_continue)
		var rejected: Dictionary = Recipe.verify_stored(trial,result.assemblies,result.protectedBounds,_continue)
		checks[fact_mode+"_rejected"]=not rejected.get("ready",true)
		evidence[fact_mode]=rejected
