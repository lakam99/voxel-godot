extends SceneTree
## Synthetic worker preparation/ownership contract, not scene or live acceptance.
## Existing descriptor arithmetic is the oracle; no source rebuild or GPU work.
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Plan = preload("res://scripts/buildings/FurnishingPlan.gd")
const Geometry = preload("res://scripts/buildings/MasonryDescriptorGeometry.gd")
const Worker = preload("res://scripts/buildings/BuildingPublicationWorker.gd")
const BINDING := {"siteId":"masonry-contract", "sourceKey":"synthetic", "generation":1}

class Reject extends RefCounted:
	var target := ""
	var occurrence := 1
	var seen := 0
	var rejected := false
	var after_false := 0
	var freeze_only := false
	var armed := false
	func advance(stage: String) -> bool:
		if rejected: after_false += 1
		if stage == "publication_masonry_freeze": armed = true
		if stage == target and (not freeze_only or armed):
			seen += 1
			if seen == occurrence:
				rejected = true
				return false
		return true

static func encoded(value: Variant) -> PackedByteArray:
	var bytes := var_to_bytes(value)
	bytes.fill(0)
	bytes.encode_var(0, value)
	return bytes

static func all_frozen(value: Variant) -> bool:
	if value is Dictionary:
		if not value.is_read_only(): return false
		for key in value:
			if not all_frozen(key) or not all_frozen(value[key]): return false
	elif value is Array:
		if not value.is_read_only(): return false
		for item in value:
			if not all_frozen(item): return false
	elif typeof(value) > TYPE_NODE_PATH: return false
	return true

static func fixture():
	var b := Blueprint.new("synthetic-masonry",73,"castle")
	b.recipe = {"sourceBlueprintId":"canonical-masonry", "routeCorridors":[
		{"center":Vector3.ZERO,"span":Vector2(9,3),"heading":0.3}],
		"landscapeTrees":[{"id":"tree","position":Vector3(1,0,1),"canopyRadius":2.0}]}
	for values: Dictionary in [
		{"id":"ordinary","kind":"wall","material":"fired_brick","size":Vector3(4,3,0.4)},
		{"id":"rubble","kind":"foundation","material":"stone_foundation","size":Vector3(5,2,0.7)},
		{"id":"castle_front","kind":"wall","material":"aged_castle_stone","size":Vector3(8,4,0.7)},
		{"id":"castle_scaled","kind":"wall","material":"fired_brick","size":Vector3(30,20,1)},
		{"id":"short","kind":"wall","material":"painted_brick_white","size":Vector3(2,0.7,0.2)},
		{"id":"narrow","kind":"wall","material":"fired_brick","size":Vector3(0.1,2.7,0.1)},
		{"id":"zero_rows","kind":"wall","material":"stone_foundation","size":Vector3.ONE},
		{"id":"negative","kind":"wall","material":"aged_castle_stone","size":Vector3(3.1,2.6,0.3),"position":Vector3(-7,-1,8),"rotation":Vector3(0,0.37,0)},
		{"id":"aperture","kind":"wall","material":"fired_brick","size":Vector3(4,3,0.4),"recipe":{"masonryApertureSource":{"key":"synthetic-tag-only"}}}
	]:
		var part = b.add_part(values)
		if part.id == "zero_rows": part.size = Vector3(2,0.0005,1)
	return b

static func retirement_case() -> Dictionary:
	var b := Blueprint.new("retire",1)
	var part = b.add_part({"id":"retained","kind":"wall","material":"fired_brick"})
	var history: Dictionary = Preparation._compile_history(b)
	var masonry: Dictionary = Preparation._compile_masonry(b,history.preparedHistory)
	return {"payload":{"artifact":masonry.preparedMasonry}, "part":weakref(part),
		"history":weakref(history.preparedHistory),"field":weakref(history.preparedHistory.history),
		"artifact":weakref(masonry.preparedMasonry)}

static func run_worker() -> Dictionary:
	var checks := {"parity_completed":false,"mutation_completed":false,"unsupported_completed":false,
		"cancel_completed":false,"pipeline_completed":false,"retirement_completed":false}
	var report := {"checks":checks,"evidenceLevel":"synthetic CPU/service; no Nodes/GPU/live acceptance",
		"workerThreadId":OS.get_thread_caller_id()}
	var b = fixture()
	var before := encoded(b.snapshot())
	var history: Dictionary = Preparation._compile_history(b)
	var result: Dictionary = Preparation._compile_masonry(b,history.preparedHistory)
	checks.ready = result.ready and result.preparedMasonry != null
	if not checks.ready: return report
	var artifact = result.preparedMasonry
	checks.count_nine = artifact.count() == 9
	checks.maps_readonly = artifact._entries.is_read_only() and artifact._ids.is_read_only()
	checks.history_bound = artifact.matches_history(history.preparedHistory,history.preparedHistory.history,"canonical-masonry")
	checks.wrong_source = not artifact.matches_history(history.preparedHistory,history.preparedHistory.history,b.id)
	var other_history: Dictionary = Preparation._compile_history(b)
	checks.wrong_history_artifact = not artifact.matches_history(other_history.preparedHistory,history.preparedHistory.history,"canonical-masonry")
	checks.wrong_history_field = not artifact.matches_history(history.preparedHistory,other_history.preparedHistory.history,"canonical-masonry")
	checks.null_history = not artifact.matches_history(null,null,"canonical-masonry")
	for part in b.parts:
		var geometry: Dictionary = artifact.geometry_for(part)
		checks[part.id+"_typed_exact"] = encoded(geometry) == encoded(Geometry.describe_source(part,history.preparedHistory.history,"canonical-masonry"))
		checks[part.id+"_deep_readonly"] = all_frozen(geometry) and artifact._entries[part].is_read_only()
		checks[part.id+"_typed_arrays"] = geometry.regularTransforms.get_typed_builtin()==TYPE_TRANSFORM3D \
			and geometry.regularCustomData.get_typed_builtin()==TYPE_COLOR
		checks[part.id+"_part_valid"] = artifact.has_part(part) and artifact.validate_part(part)
		checks[part.id+"_binding_exact"] = artifact._entries[part].binding == encoded(part.snapshot()).hex_encode()
	checks.inputs_exact = encoded(b.snapshot()) == before
	checks.inputs_mutable = not b.recipe.is_read_only() and not b.parts[8].recipe.is_read_only()
	checks.parity_completed = true
	var part = b.parts[0]
	var same_id = Part.new(part.snapshot())
	checks.replacement_recognized = artifact.has_part(same_id)
	checks.replacement_rejected = not artifact.validate_part(same_id) and artifact.geometry_for(same_id).is_empty()
	checks.unknown_absent = not artifact.has_part(Part.new({"id":"unknown"}))
	var missing = Part.new({"id":"unexpected-new","kind":"wall","material":"fired_brick"})
	checks.new_eligible_missing_rejected = artifact.has_part(missing) and not artifact.validate_part(missing) and artifact.geometry_for(missing).is_empty()
	checks.null_absent = not artifact.has_part(null) and not artifact.validate_part(null)
	for field: String in ["id","kind","material_id","position","rotation","size","collision_enabled","semantic","physical_intent","recipe"]:
		var saved: Variant = part.get(field)
		match field:
			"position","rotation","size": part.set(field,saved+Vector3.ONE)
			"collision_enabled": part.set(field,not saved)
			"recipe": part.recipe={"changed":true}
			_: part.set(field,String(saved)+"_changed")
		checks[field+"_mutation_recognized"] = artifact.has_part(part)
		checks[field+"_mutation_rejected"] = not artifact.validate_part(part) and artifact.geometry_for(part).is_empty()
		part.set(field,saved)
		checks[field+"_restored_valid"] = artifact.validate_part(part)
	for field: String in ["route_corridors","tree_placements","history_events","history_event_cells"]:
		var saved: Variant = history.preparedHistory.history.get(field)
		history.preparedHistory.history.set(field,saved.duplicate(true))
		checks[field+"_history_rejected"] = not artifact.matches_history(history.preparedHistory,history.preparedHistory.history,"canonical-masonry") \
			and not artifact.validate_part(part) and artifact.geometry_for(part).is_empty()
		history.preparedHistory.history.set(field,saved)
	checks.mutation_completed = true
	# Eligibility mirrors publisher dispatch, without excluding aperture tags or
	# non-colliding visible masonry. Invalid graphs are introduced AFTER history.
	var selection := Blueprint.new("selection",1)
	var selected = selection.add_part({"id":"visible-noncollision","kind":"wall","material":"fired_brick","collision":false})
	for values: Dictionary in [{"id":"hidden","kind":"wall","material":"fired_brick","recipe":{"visual":false}},
		{"id":"cobble","kind":"foundation","material":"cobblestone"},
		{"id":"timber","kind":"wall","material":"timber_board"},
		{"id":"roof","kind":"roof","material":"fired_brick"}]: selection.add_part(values)
	var selection_history: Dictionary = Preparation._compile_history(selection)
	var selection_result: Dictionary = Preparation._compile_masonry(selection,selection_history.preparedHistory)
	checks.selection_exact = selection_result.ready and selection_result.preparedMasonry.count()==1 and selection_result.preparedMasonry.has_part(selected)
	var omitted: Dictionary = Preparation._compile_masonry(selection,null)
	checks.no_history_optional = omitted.ready and omitted.preparedMasonry==null
	for mode: String in ["cycle","packed","object","typed_object","container_key"]:
		var bad := Blueprint.new("bad",1)
		var bad_part = bad.add_part({"id":"bad","kind":"wall","material":"fired_brick"})
		var bad_history: Dictionary = Preparation._compile_history(bad)
		var cyclic: Array = []
		var typed: Array[RefCounted] = []
		match mode:
			"cycle":
				cyclic.append(cyclic); bad_part.recipe={"cycle":cyclic}
			"packed": bad_part.recipe={"packed":PackedVector3Array([Vector3.ONE])}
			"object": bad_part.recipe={"object":RefCounted.new()}
			"typed_object": bad_part.recipe={"typed":typed}
			"container_key": bad_part.recipe={[1]:true}
		var bad_result: Dictionary = Preparation._compile_masonry(bad,bad_history.preparedHistory)
		checks[mode+"_omitted"] = bad_result.ready and bad_result.preparedMasonry.count()==0
		checks[mode+"_intentional_fallback"] = not bad_result.preparedMasonry.has_part(bad_part) and bad_result.preparedMasonry.geometry_for(bad_part).is_empty()
		checks[mode+"_omission_maps_readonly"] = bad_result.preparedMasonry._omitted.is_read_only() and bad_result.preparedMasonry._omitted_ids.is_read_only()
		var replacement = Part.new({"id":"bad","kind":"wall","material":"fired_brick"})
		checks[mode+"_omission_replacement_rejected"] = bad_result.preparedMasonry.has_part(replacement) and not bad_result.preparedMasonry.validate_part(replacement)
		bad_part.id="changed"
		checks[mode+"_omission_changed_id_rejected"] = bad_result.preparedMasonry.has_part(bad_part) and not bad_result.preparedMasonry.validate_part(bad_part)
		bad_part.id="bad"
		checks[mode+"_input_mutable"] = not bad_part.recipe.is_read_only()
		part.recipe=bad_part.recipe
		checks[mode+"_late_rejected"] = not artifact.validate_part(part) and artifact.geometry_for(part).is_empty()
		part.recipe={}; cyclic.clear()
	var duplicate := Blueprint.new("duplicate",1)
	duplicate.add_part({"id":"same","kind":"wall","material":"fired_brick"})
	duplicate.add_part({"id":"same","kind":"foundation","material":"stone_foundation"})
	var duplicate_history: Dictionary = Preparation._compile_history(duplicate)
	var duplicate_result: Dictionary = Preparation._compile_masonry(duplicate,duplicate_history.preparedHistory)
	checks.duplicate_rejected = duplicate_result == {"ready":false,"reason":"duplicate_masonry_part_id"}
	var wrong: Dictionary = Preparation._compile_masonry(b,selection_history.preparedHistory)
	checks.compile_wrong_history_rejected = wrong == {"ready":false,"reason":"stale_prepared_history"}
	checks.unsupported_completed = true
	for stage: String in ["publication_masonry_started","publication_masonry_part","publication_masonry_walk","publication_masonry_cursor",
		"publication_masonry_freeze","publication_masonry_record","publication_masonry_validate","publication_masonry_completed"]:
		var reject := Reject.new()
		reject.target=stage
		var cancelled: Dictionary = Preparation._compile_masonry(b,history.preparedHistory,reject.advance)
		checks[stage+"_cancel"] = cancelled == {"ready":false,"reason":"cancelled"}
		checks[stage+"_terminal"] = reject.rejected and reject.after_false==0
	var dense := Blueprint.new("canonical-masonry",1)
	dense.parts=[b.parts[3]]
	var repeat := Reject.new()
	repeat.target="publication_masonry_cursor"; repeat.occurrence=2
	var repeated: Dictionary = Preparation._compile_masonry(dense,history.preparedHistory,repeat.advance)
	checks.cursor_repeat_cancel = repeated == {"ready":false,"reason":"cancelled"} and repeat.rejected and repeat.after_false==0
	var freeze_reject := Reject.new()
	freeze_reject.target="publication_masonry_walk"; freeze_reject.freeze_only=true; freeze_reject.occurrence=2
	var frozen_cancel: Dictionary = Preparation._compile_masonry(b,history.preparedHistory,freeze_reject.advance)
	checks.freeze_walk_cancel = frozen_cancel == {"ready":false,"reason":"cancelled"} and freeze_reject.rejected and freeze_reject.after_false==0
	checks.cancel_completed = true
	var empty := Blueprint.new("pipeline",1)
	var plan := Plan.new("pipeline-furniture",1,"pipeline")
	var furniture: Dictionary = plan.snapshot()
	furniture["accessReservations"]=plan.access_reservations_snapshot()
	var pipeline: Dictionary = Preparation.prepare_source(empty.snapshot(),furniture,BINDING)
	checks.pipeline_ready = pipeline.ready
	if not pipeline.ready: return report
	checks.wrong_receipt_not_consumed = pipeline.prepared.take({"siteId":"wrong"}).is_empty()
	var payload: Dictionary = pipeline.prepared.take(BINDING)
	checks.pipeline_artifact = payload.preparedMasonry != null and payload.preparedMasonry.count()==0 \
		and payload.preparedMasonry.matches_history(payload.preparedHistory,payload.preparedHistory.history,"pipeline")
	checks.pipeline_one_shot = pipeline.prepared.take(BINDING).is_empty()
	checks.pipeline_metadata_unchanged = payload.staticRecords.is_empty() and payload.staticRecords.is_read_only()
	checks.timing_present = payload.masonryPreparationUsec>=0 and result.masonryPreparationUsec>=0
	var terminal := Reject.new()
	terminal.target="publication_masonry_completed"
	var failed_pipeline: Dictionary = Preparation.prepare_source(empty.snapshot(),furniture,BINDING,terminal.advance)
	checks.pipeline_cancel = failed_pipeline == {"ready":false,"reason":"cancelled"} and terminal.rejected and terminal.after_false==0
	checks.pipeline_completed = true
	var retirement: Dictionary = retirement_case()
	checks.retains_source_until_retirement = retirement.part.get_ref()!=null and retirement.history.get_ref()!=null and retirement.field.get_ref()!=null
	var state := Worker.RetirementState.new()
	state.payload=retirement.payload; retirement.payload={}
	state.transferred.post()
	state.release_payload() # Already on the owning worker, no main disposal.
	checks.retirement_releases_all = retirement.part.get_ref()==null and retirement.history.get_ref()==null \
		and retirement.field.get_ref()==null and retirement.artifact.get_ref()==null
	checks.retirement_worker_thread = state.released_on_thread==OS.get_thread_caller_id()
	checks.retirement_completed = true
	report["masonryPreparationUsec"]=result.masonryPreparationUsec
	return report

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var output := OS.get_environment("BUILDING_PREPARED_MASONRY_OUTPUT")
	if output.is_empty(): quit(2); return
	var worker := Thread.new()
	var started := Time.get_ticks_msec()
	if worker.start(run_worker)!=OK: quit(2); return
	while worker.is_alive(): await process_frame
	var report: Dictionary = worker.wait_to_finish()
	report.checks.worker_joined = not worker.is_started()
	report.checks.off_main = report.workerThreadId!=OS.get_thread_caller_id()
	report.checks.within_cap = Time.get_ticks_msec()-started<90000
	var passed := 0
	for key in report.checks:
		if report.checks[key]: passed+=1
		else: print("PREPARED MASONRY FAILURE ",key)
	report["passed"]=passed==report.checks.size()
	report["passedCount"]=passed; report["checkCount"]=report.checks.size()
	report["elapsedMsec"]=Time.get_ticks_msec()-started
	report["preparationSha256"]=FileAccess.get_sha256("res://scripts/buildings/BuildingPublicationPreparation.gd")
	report["contractSha256"]=FileAccess.get_sha256("res://scripts/testing/buildings/BuildingPreparedMasonryContract.gd")
	report["geometrySha256"]=FileAccess.get_sha256("res://scripts/buildings/MasonryDescriptorGeometry.gd")
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("PREPARED MASONRY ",passed,"/",report.checks.size())
	quit(0 if report.passed else 1)
