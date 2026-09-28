extends SceneTree
const Current = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Memo = preload("res://scripts/buildings/BuildingSupportResolutionMemo.gd")
func _initialize() -> void: call_deferred("_run")
func _run() -> void:
	var old_script = load("res://artifacts/citadel-runtime-integration/support-query-baseline/BuildingBlueprint.gd")
	var input := "res://artifacts/citadel-runtime-integration/candidate-recipe-26/source.bin"
	if FileAccess.get_sha256(input) != "7c2047c45b51f05dbd99c4747c9bde63c8184eb50140c5b46af2bb67179ca70e": quit(2); return
	var source: Dictionary = FileAccess.open(input,FileAccess.READ).get_var(false)
	var results := []
	for script in [old_script, Current]:
		var b = script.new(source.blueprint.id, source.blueprint.seed, source.blueprint.style)
		b.recipe = source.blueprint.recipe.duplicate(true)
		b.rooms = source.blueprint.rooms.duplicate(true)
		var copied = Copy.copy_blueprint(source.blueprint)
		b.parts = copied.parts
		var started := Time.get_ticks_usec()
		var report: Dictionary = b.validate_physical_integrity()
		results.append({"usec":Time.get_ticks_usec()-started,"report":report,"snapshot":b.snapshot()})
	var checks := {"report_exact":var_to_bytes(results[0].report)==var_to_bytes(results[1].report),"snapshot_exact":var_to_bytes(results[0].snapshot)==var_to_bytes(results[1].snapshot),"physical_passed":results[1].report.passed}
	var memo_evidence := _memo_differential(source.blueprint,results[1],checks)
	var file := FileAccess.open(OS.get_environment("SUPPORT_QUERY_REPORT"),FileAccess.WRITE)
	file.store_string(JSON.stringify({"passed":not checks.values().has(false),"checks":checks,"baselineUsec":results[0].usec,"candidateUsec":results[1].usec,"memo":memo_evidence,"scope":"Pinned full-source physical differential and synthetic invalidation; not gameplay acceptance."},"\t")); file.close()
	quit(0 if not checks.values().has(false) else 1)

func _proof(snapshot: Dictionary, shared: Dictionary):
	var copied = Copy.copy_blueprint(snapshot)
	var proof := Memo.new(copied.id,copied.seed,copied.style)
	proof.recipe=copied.recipe; proof.rooms=copied.rooms; proof.parts=copied.parts
	proof.identities=shared
	return proof

func _memo_differential(snapshot: Dictionary, expected: Dictionary, checks: Dictionary) -> Dictionary:
	var shared := {}
	var timings := []
	for i in range(2):
		var proof = _proof(snapshot,shared)
		var started := Time.get_ticks_usec()
		var report: Dictionary = proof.validate_physical_integrity()
		timings.append(Time.get_ticks_usec()-started)
		checks["memo_full_report_%d"%i]=var_to_bytes(report)==var_to_bytes(expected.report)
		checks["memo_full_snapshot_%d"%i]=var_to_bytes(proof.snapshot())==var_to_bytes(expected.snapshot)
		if i==1: checks["memo_full_hits"]=proof.observations.hits>3000
		# Returned coverage is mutable; it must not alias the stored result.
		for part in proof.parts:
			if not part.recipe.get("physicalSupportCoverage",[]).is_empty():
				part.recipe.physicalSupportCoverage[0].supported=false
				break
	var fixture := Current.new("memo-controls",1,"stone")
	var root = fixture.add_part({"id":"root","kind":"foundation","size":Vector3(4,1,4),"position":Vector3(0,0.5,0)})
	var target = fixture.add_part({"id":"target","kind":"wall","size":Vector3(1,1,1),"position":Vector3(0,1.5,0)})
	var base: Dictionary = fixture.snapshot()
	for i in range(12):
		var changed = Copy.copy_blueprint(base)
		var a = changed.parts[0]; var b = changed.parts[1]
		match i:
			0: a.position.x=8
			1: a.size.x=0.2
			2: a.rotation.y=0.4
			3: a.collision_enabled=false
			4: a.recipe["physicalRoot"]=true; a.position.y=2
			5: b.recipe["physicalRequiredSupportPartIds"]=["missing"]
			6: b.recipe["physicalSupportsPartId"]="root"
			7: b.recipe["allowEnclosingStructuralSupport"]=true
			8: changed.parts.reverse()
			9: changed.add_part({"id":"root","kind":"foundation"})
			10: changed.parts.remove_at(0)
			11: b.rotation.z=0.1
		var local := {}
		_proof(base,local).validate_physical_integrity()
		var actual = _proof(changed.snapshot(),local)
		var baseline = Copy.copy_blueprint(changed.snapshot())
		checks["memo_mutation_%d"%i]=var_to_bytes(actual.validate_physical_integrity())==var_to_bytes(baseline.validate_physical_integrity()) and var_to_bytes(actual.snapshot())==var_to_bytes(baseline.snapshot())
	for stage in ["physical_resolve_support","physical_validation_part","physical_validation_completed"]:
		var local := {}
		_proof(base,local).validate_physical_integrity()
		var proof = _proof(base,local)
		var cancelled: Dictionary=proof.validate_physical_integrity_cancellable(func(label):return label!=stage)
		checks["memo_cancel_"+stage]=cancelled.get("cancelled",false) and local.is_empty()
	return {"coldUsec":timings[0],"warmUsec":timings[1]}
