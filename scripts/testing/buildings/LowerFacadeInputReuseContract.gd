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
	var f:=FileAccess.open(OS.get_environment("LOWER_INPUT_REPORT"),FileAccess.WRITE)
	f.store_string(JSON.stringify({"passed":not checks.values().has(false),"checks":checks,"scope":"Synthetic whole-completion baseline differential and cancellation; not live gameplay."},"\t"));f.close()
	quit(0 if not checks.values().has(false) else 1)
