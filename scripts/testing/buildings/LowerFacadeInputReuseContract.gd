extends "res://scripts/testing/buildings/LowerFacadeBearingBatchContract.gd"
func _run() -> void:
	var old=load("res://artifacts/citadel-runtime-integration/support-query-baseline/LowerFacadeBearingRecipe.gd")
	var checks := {}
	for count in range(1,5):
		for blocked in [false,true]:
			var fixture := _batch_fixture(count)
			if blocked: fixture.policy.furnitureParts.append(_batch_blocking_furniture(0))
			var frozen := var_to_bytes(fixture)
			var expected: Dictionary=old.prepare_all_bottom_rows(fixture.snapshot,fixture.policy)
			var actual: Dictionary=Recipe.prepare_all_bottom_rows(fixture.snapshot,fixture.policy)
			var label:=str(count)+"_"+str(blocked)
			checks[label+"_exact"]=var_to_bytes(expected)==var_to_bytes(actual)
			checks[label+"_unchanged_input"]=var_to_bytes(fixture)==frozen
			checks[label+"_ready"]=actual.get("ready",false)
			for stop in ["lower_facade_panel","lower_facade_remaining_proof_started","lower_facade_verification_started"]:
				var callback:=func(stage):return not String(stage).begins_with(stop)
				var cancelled: Dictionary=Recipe.prepare_all_bottom_rows(fixture.snapshot,fixture.policy,callback)
				checks[label+"_"+stop]=not cancelled.get("ready",false) and cancelled.get("reason")=="cancelled" and var_to_bytes(fixture)==frozen
	var overlap:=_batch_fixture(1)
	var second: Dictionary=overlap.snapshot.parts[2].duplicate(true)
	second.id="synthetic_upper_panel_b"
	overlap.snapshot.parts.append(second)
	var declaration: Dictionary=overlap.snapshot.recipe.facadeApertures.synthetic_upper_a.duplicate(true)
	declaration.producerPrefix="synthetic_upper_b"
	declaration.openings[0].id="synthetic_opening_b"
	declaration.erase("sourceBinding")
	overlap.snapshot.recipe.facadeApertures["synthetic_upper_b"]=Recipe.Aperture.seal(declaration,[Part.new(second)])
	var expected_overlap: Dictionary=old.prepare_all_bottom_rows(overlap.snapshot,overlap.policy)
	var actual_overlap: Dictionary=Recipe.prepare_all_bottom_rows(overlap.snapshot,overlap.policy)
	checks.overlapping_panels_exact=var_to_bytes(expected_overlap)==var_to_bytes(actual_overlap)
	var component := _component_comparison()
	checks["component_exact"] = component.exact
	var f:=FileAccess.open(OS.get_environment("LOWER_INPUT_REPORT"),FileAccess.WRITE)
	f.store_string(JSON.stringify({"passed":not checks.values().has(false),"checks":checks,"component":component,"scope":"Synthetic whole-completion baseline differential/cancellation and generated-record component replay; not live gameplay."},"\t"));f.close()
	quit(0 if not checks.values().has(false) else 1)

func _component_comparison() -> Dictionary:
	var old_path := "res://artifacts/citadel-runtime-integration/biome-runtime-35/FrozenLowerFacadeBearingRecipe.gd"
	if FileAccess.get_sha256(old_path)!="53e06087e3012955c50703d1d8d54c1983eb6687604de5e3782cd6339408e6e0": return {"exact":false}
	var old=load(old_path)
	var source_path := "res://artifacts/citadel-runtime-integration/candidate-recipe-35/source.bin"
	var report: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://artifacts/citadel-runtime-integration/candidate-recipe-35/report.json"))
	if FileAccess.get_sha256(source_path)!=report.receipt.sourceSha256: return {"exact":false}
	var source: Dictionary=FileAccess.open(source_path,FileAccess.READ).get_var(false)
	var before: Dictionary=source.blueprint.duplicate(true)
	var body_id := ""
	for record: Dictionary in before.parts:
		if record.semantic=="lower_facade_bearing": body_id=record.id; break
	if body_id.is_empty(): return {"exact":false}
	var ids := [body_id,body_id+"_connection_0",body_id+"_connection_1"]
	var additions: Array=before.parts.filter(func(p):return ids.has(p.id))
	if additions.size()!=3: return {"exact":false}
	before.parts=before.parts.filter(func(p):return not ids.has(p.id))
	var after: Dictionary=before.duplicate(true)
	after.parts.append_array(additions)
	var panel_id:=body_id.trim_suffix("_lower_bearing")
	var exact:=true
	var times := {"oldDeltaUsec":0,"newDeltaUsec":0,"oldAdvanceUsec":0,"newAdvanceUsec":0}
	for repeat in range(5):
		var a := {"blueprint":Recipe.Copy.copy_blueprint(before),"obstacles":[]}
		var b := {"blueprint":Recipe.Copy.copy_blueprint(before),"obstacles":[]}
		var started:=Time.get_ticks_usec()
		var expected: Dictionary=old._accepted_change_support_delta(before,after,panel_id)
		times.oldDeltaUsec+=Time.get_ticks_usec()-started
		started=Time.get_ticks_usec()
		var actual: Dictionary=Recipe._accepted_change_support_delta(before,after,panel_id,b.blueprint.parts)
		times.newDeltaUsec+=Time.get_ticks_usec()-started
		exact=exact and var_to_bytes(expected)==var_to_bytes(actual)
		started=Time.get_ticks_usec()
		var ea: Dictionary=old._advance_prepared_input(a,after)
		times.oldAdvanceUsec+=Time.get_ticks_usec()-started
		started=Time.get_ticks_usec()
		var aa: Dictionary=Recipe._advance_prepared_input(b,after,panel_id)
		times.newAdvanceUsec+=Time.get_ticks_usec()-started
		exact=exact and ea==aa and var_to_bytes(a.blueprint.snapshot())==var_to_bytes(b.blueprint.snapshot()) and var_to_bytes(a.obstacles)==var_to_bytes(b.obstacles)
		for id: String in ids+[panel_id]: exact=exact and b.blueprint.find_part(id)!=null
	return {"exact":exact,"repeats":5,"timing":times,"scope":"Component replay with three generated bearing records moved to an append-only delta; no accepted-composition or gameplay claim."}
