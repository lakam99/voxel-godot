extends SceneTree
## Synthetic CPU/service contracts, all preparation and disposal on one owned
## worker. No Source rebuild, scene Nodes, GPU or live gameplay acceptance.
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const History = preload("res://scripts/buildings/SurfaceHistoryField.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Plan = preload("res://scripts/buildings/FurnishingPlan.gd")
const Geometry = preload("res://scripts/buildings/MasonryDescriptorGeometry.gd")
const BINDING := {"siteId":"history-contract", "sourceKey":"synthetic", "generation":1}

class Reject extends RefCounted:
	var target := ""
	var occurrence := 1
	var seen := 0
	var rejected := false
	var after_false := 0
	var after_configure := false
	var armed := false
	func advance(stage: String) -> bool:
		if rejected: after_false += 1
		if stage == "publication_history_configured": armed = true
		if stage == target and (not after_configure or armed):
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

static func roots(field) -> Array:
	return [field.route_corridors, field.tree_placements, field.history_events, field.history_event_cells]

static func frozen(value: Variant) -> bool:
	if value is Dictionary:
		if not value.is_read_only(): return false
		for key in value:
			if not frozen(key) or not frozen(value[key]): return false
	elif value is Array:
		if not value.is_read_only(): return false
		for item in value:
			if not frozen(item): return false
	elif typeof(value) > TYPE_NODE_PATH: return false
	return true

static func fixture():
	var b := Blueprint.new("synthetic-history", 73, "castle")
	var typed: Array[int] = [9, 2, 4]
	b.recipe = {"sourceBlueprintId":"canonical-history", "routeCorridors":[
		{"center":Vector3.ZERO, "span":Vector2(9, 3), "heading":0.3, "extra":{"typed":typed, "path":NodePath("a/b")}}],
		"landscapeTrees":[{"id":"tree", "position":Vector3(1,0,1), "canopyRadius":2.0,
			"rootButtressFootprints":[{"start":Vector3(1,0,1), "end":Vector3(2,0,2)}]}]}
	for kind in ["window", "door", "beam"]:
		b.add_part({"id":kind, "kind":kind, "semantic":"eave" if kind=="beam" else kind,
			"position":Vector3(0,2,0), "size":Vector3(2,1,0.3), "materialId":"brick"})
	return b

static func run_worker() -> Dictionary:
	var checks := {"parity_completed":false, "replacements_completed":false,
		"unsupported_completed":false, "cancellation_completed":false, "pipeline_completed":false}
	var report := {"checks":checks, "evidenceLevel":"synthetic CPU/service owned worker; no Nodes/GPU/live acceptance",
		"workerThreadId":OS.get_thread_caller_id()}
	var b = fixture()
	var before := encoded(b.snapshot())
	var old := History.new()
	old.configure(b.recipe, b.parts)
	var result: Dictionary = Preparation._compile_history(b)
	checks.ready = result.ready and result.preparedHistory != null
	if not checks.ready: return report
	var artifact = result.preparedHistory
	var field = artifact.history
	checks.history_content_exact = encoded(roots(old)) == encoded(roots(field))
	checks.input_exact = before == encoded(b.snapshot())
	checks.scope_exact = artifact.matches(field, "canonical-history")
	checks.scope_wrong = not artifact.matches(field, b.id)
	checks.null_rejected = not artifact.matches(null, "canonical-history")
	checks.equal_field_rejected = not artifact.matches(old, "canonical-history")
	checks.all_roots_nested_readonly = roots(field).all(frozen)
	checks.typed_events = field.history_events.is_typed() and field.history_events.get_typed_builtin() == TYPE_DICTIONARY
	checks.isolated_route = not is_same(b.recipe.routeCorridors, field.route_corridors)
	checks.input_mutable = not b.recipe.is_read_only() and not b.recipe.routeCorridors.is_read_only() \
		and not b.recipe.routeCorridors[0].extra.typed.is_read_only()
	for index in 9:
		var pos := Vector3(index-4, 0, index%3-1)
		checks["conditions_%d"%index] = encoded(old.conditions_at(pos)) == encoded(field.conditions_at(pos))
		checks["wear_%d"%index] = encoded(old.wear_contact_at(pos)) == encoded(field.wear_contact_at(pos))
		checks["root_%d"%index] = encoded(old.root_buttress_contact(pos, Vector2.ONE)) == encoded(field.root_buttress_contact(pos, Vector2.ONE))
		checks["history_%d"%index] = old.history_for(b.parts[0],pos,0.5,0.3) == field.history_for(b.parts[0],pos,0.5,0.3)
	checks.descriptor_exact = encoded(Geometry.describe_source(b.parts[0],old,"canonical-history")) \
		== encoded(Geometry.describe_source(b.parts[0],field,"canonical-history"))
	checks.summary_exact = encoded(old.summary()) == encoded(field.summary())
	var preserved := encoded(roots(field))
	b.recipe.routeCorridors[0].center = Vector3(99,0,99)
	b.recipe.routeCorridors[0].extra.typed.append(8)
	b.recipe.landscapeTrees[0].position = Vector3(88,0,88)
	checks.caller_changes_isolated = encoded(roots(field)) == preserved
	checks.reusable_identity = artifact.matches(field,"canonical-history") and artifact.matches(field,"canonical-history")
	checks.parity_completed = true
	var names := ["route_corridors", "tree_placements", "history_events", "history_event_cells"]
	for name in names:
		var saved: Variant = field.get(name)
		field.set(name, saved.duplicate(true))
		checks[name+"_replacement_rejected"] = not artifact.matches(field,"canonical-history")
		field.set(name, saved)
		checks[name+"_restored_matches"] = artifact.matches(field,"canonical-history")
	artifact.history = old
	checks.artifact_field_replacement_rejected = not artifact.matches(old,"canonical-history") and not artifact.matches(field,"canonical-history")
	artifact.history = field
	checks.replacements_completed = true
	for mode in ["absent", "empty", "fallback", "urban"]:
		var tiny := Blueprint.new("fallback-id",1)
		if mode=="empty": tiny.recipe={"routeCorridors":[]}
		if mode=="fallback": tiny.recipe={"pavingTreatments":[{"center":Vector3.ZERO,"span":Vector2.ONE}]}
		if mode=="urban": tiny.recipe={"urbanPoc":{"treePlacements":[Vector3.ZERO]}}
		var legacy := History.new()
		legacy.configure(tiny.recipe, tiny.parts)
		var prepared: Dictionary = Preparation._compile_history(tiny)
		checks[mode+"_ready_exact"] = prepared.ready and prepared.preparedHistory != null \
			and encoded(roots(legacy)) == encoded(roots(prepared.preparedHistory.history))
		checks[mode+"_scope_fallback"] = prepared.preparedHistory.matches(prepared.preparedHistory.history,"fallback-id")
	for mode in ["packed", "object", "cycle", "typed_object", "bad_routes", "bad_trees", "bad_urban"]:
		var malformed := Blueprint.new("unsupported",1)
		var cyclic: Array = []
		var objects: Array[RefCounted] = []
		match mode:
			"packed": malformed.recipe={"routeCorridors":[{"extra":PackedInt32Array([1,2])}]}
			"object": malformed.recipe={"landscapeTrees":[{"extra":RefCounted.new()}]}
			"cycle":
				cyclic.append(cyclic)
				malformed.recipe={"landscapeTrees":cyclic}
			"typed_object": malformed.recipe={"routeCorridors":objects}
			"bad_routes": malformed.recipe={"routeCorridors":null}
			"bad_trees": malformed.recipe={"landscapeTrees":3}
			"bad_urban": malformed.recipe={"urbanPoc":[]}
		var omitted: Dictionary = Preparation._compile_history(malformed)
		checks[mode+"_omitted_not_failed"] = omitted.ready and omitted.preparedHistory == null
		checks[mode+"_input_not_frozen"] = not malformed.recipe.is_read_only()
		cyclic.clear() # Explicitly break the synthetic cycle on its owning worker.
	checks.unsupported_completed = true
	for stage in ["publication_history_started", "publication_history_walk", "publication_history_configure", "publication_history_configured", "publication_history_completed"]:
		var reject := Reject.new()
		reject.target = stage
		var cancelled: Dictionary = Preparation._compile_history(fixture(),reject.advance)
		checks[stage+"_cancelled"] = cancelled == {"ready":false,"reason":"cancelled"}
		checks[stage+"_terminal"] = reject.rejected and reject.after_false==0
	var late := Reject.new()
	late.target="publication_history_walk"; late.occurrence=2; late.after_configure=true
	var late_result: Dictionary = Preparation._compile_history(fixture(),late.advance)
	checks.freeze_walk_cancelled = late_result == {"ready":false,"reason":"cancelled"} and late.rejected and late.after_false==0
	checks.cancellation_completed = true
	# Small real preparation pipeline, not a full historical Source rebuild.
	var empty := Blueprint.new("pipeline",1)
	var plan := Plan.new("pipeline-furniture",1,"pipeline")
	var furniture: Dictionary = plan.snapshot()
	furniture["accessReservations"] = plan.access_reservations_snapshot()
	var ready: Dictionary = Preparation.prepare_source(empty.snapshot(),furniture,BINDING)
	checks.pipeline_ready = ready.ready
	if not ready.ready: return report
	checks.wrong_receipt_not_consumed = ready.prepared.take({"siteId":"wrong"}).is_empty()
	var payload: Dictionary = ready.prepared.take(BINDING)
	checks.pipeline_history = payload.preparedHistory != null and payload.preparedHistory.matches(payload.preparedHistory.history,"pipeline")
	checks.pipeline_one_shot = ready.prepared.take(BINDING).is_empty()
	checks.pipeline_metadata_preserved = payload.staticRecords.is_empty() and payload.staticRecords.is_read_only()
	checks.history_timing = payload.historyPreparationUsec >= 0 and result.historyPreparationUsec >= 0
	var terminal := Reject.new()
	terminal.target="publication_history_completed"
	var cancelled_pipeline: Dictionary = Preparation.prepare_source(empty.snapshot(),furniture,BINDING,terminal.advance)
	checks.pipeline_cancel = cancelled_pipeline == {"ready":false,"reason":"cancelled"} and terminal.rejected and terminal.after_false==0
	checks.pipeline_completed = true
	return report # All history/blueprint aliases are released here on the worker.

func _initialize() -> void: call_deferred("run")

func run() -> void:
	var output := OS.get_environment("BUILDING_PREPARED_HISTORY_OUTPUT")
	if output.is_empty(): quit(2); return
	var worker := Thread.new()
	var started := Time.get_ticks_msec()
	if worker.start(run_worker) != OK: quit(2); return
	while worker.is_alive(): await process_frame
	var report: Dictionary = worker.wait_to_finish()
	report.checks.worker_joined = not worker.is_started()
	report.checks.off_main = report.workerThreadId != OS.get_thread_caller_id()
	report.checks.within_cap = Time.get_ticks_msec()-started < 90000
	var passed := 0
	for key in report.checks:
		if report.checks[key]: passed += 1
		else: print("PREPARED HISTORY FAILURE ",key)
	report["passed"] = passed == report.checks.size()
	report["passedCount"] = passed
	report["checkCount"] = report.checks.size()
	report["elapsedMsec"] = Time.get_ticks_msec()-started
	report["preparationSha256"] = FileAccess.get_sha256("res://scripts/buildings/BuildingPublicationPreparation.gd")
	report["contractSha256"] = FileAccess.get_sha256("res://scripts/testing/buildings/BuildingPreparedHistoryContract.gd")
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file == null: quit(2); return
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("PREPARED HISTORY ",passed,"/",report.checks.size())
	quit(0 if report.passed else 1)
