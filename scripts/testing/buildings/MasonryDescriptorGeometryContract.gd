extends SceneTree
## Independent frozen 76bb474 oracle, synthetic families and one historical dense
## wall. Descriptor-only owned-worker evidence: no Site build, Nodes or rendering.
const Geometry = preload("res://scripts/buildings/MasonryDescriptorGeometry.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const History = preload("res://scripts/buildings/SurfaceHistoryField.gd")
const Worker = preload("res://scripts/buildings/BuildingPublicationWorker.gd")
const INPUT := "res://artifacts/citadel-runtime-integration/actual-site-source-05/result.bin"
const INPUT_SHA := "7a188cb480f3ed0332b0c568e86f18c061a265dd70a7bc3372ac7cbfd76144bf"
const REFERENCE := "res://artifacts/citadel-runtime-integration/masonry-descriptor-reference-01/BuildingPartPublisherOriginal.gd"
const HASHES := {
	"res://artifacts/citadel-runtime-integration/masonry-descriptor-reference-01/BuildingPartPublisherOriginal.gd": "d0571ccfb9229a35cbf43769b9cc5a237eacafb3b76eaad432e94ccda224be2f",
	"res://artifacts/citadel-runtime-integration/masonry-descriptor-reference-01/SurfaceHistoryFieldOriginal.gd": "2e1f33da89fb1a80e2018010b494534d5665aba008e1e7f3dcd4a83213629d84",
	"res://artifacts/citadel-runtime-integration/masonry-descriptor-reference-01/MasonryWallGeometryOriginal.gd": "28e8a36f2d040d448ac26b91527b183d9912d1755efbb2997d1671edcd52d151",
	"res://artifacts/citadel-runtime-integration/masonry-descriptor-reference-01/SettledCobbleGeometryOriginal.gd": "db2d732126658c7e3660e34cb1eca6337c7093d070db6dc8b7e94a26da5c6503"
}

class SpyPart extends Part:
	var snapshots := 0
	func snapshot() -> Dictionary:
		snapshots += 1
		return super.snapshot()

class SyntheticHistory extends "res://artifacts/citadel-runtime-integration/masonry-descriptor-reference-01/SurfaceHistoryFieldOriginal.gd":
	var queries: Array = []
	var target: WeakRef
	var stop := -1
	var reentrant_rejected := false
	func record_query(kind: String, point: Vector3) -> void:
		queries.append([kind, point])
		if target != null and queries.size() == stop:
			var cursor = target.get_ref()
			reentrant_rejected = cursor.advance(1).get("reason") == "reentrant_advance"
			cursor.cancel()
	func conditions_at(point: Vector3) -> Dictionary:
		record_query("conditions", point)
		return {"runoff":fposmod(point.y * 0.19 + point.x * 0.07, 1.0),
			"rootDisturbance":fposmod(point.z * 0.31, 1.0), "canopyDeposit":0.37}
	func wear_contact_at(point: Vector3) -> Dictionary:
		record_query("wear", point)
		return {"influence":fposmod(point.x * 0.23 + point.z * 0.17, 1.0), "lateral":fposmod(point.z * 0.13, 1.0)}

class HistoryPart extends RefCounted:
	var id: String
	var kind: String
	var semantic: String
	var size: Vector3
	var position: Vector3
	var rotation: Vector3
	var recipe: Dictionary
	func _init(record: Dictionary) -> void:
		id=record.id; kind=record.kind; semantic=record.semantic; size=record.size
		position=record.position; rotation=record.rotation; recipe=record.recipe

class Run extends RefCounted:
	var checks: Dictionary = {}
	var cases: Array = []
	var original
	var deadline: int
	var guard: Worker.RunState
	func check(label: String, ok: bool) -> void:
		checks[label] = ok
		if not ok: print("MASONRY DESCRIPTOR FAILURE ", label)
	func bounded() -> bool:
		return Time.get_ticks_msec() < deadline and not guard.is_cancelled()
	func drain(cursor, label: String, budget: int) -> Dictionary:
		check(label+"_partial_hidden", cursor.take_result().is_empty())
		while cursor.status().status == "pending_budget" and bounded(): cursor.advance(budget)
		check(label+"_ready", cursor.status().status == "ready")
		var stats: Dictionary = cursor.status()
		var result: Dictionary = cursor.take_result()
		check(label+"_one_shot", cursor.take_result().is_empty() and cursor.status().status == "consumed")
		cases.append({"label":label, "metrics":stats})
		return result
	func synthetic_case(label: String, values: Dictionary) -> void:
		checks[label+"_completed"] = false
		guard.advance("synthetic:"+label)
		var part = Part.new(values)
		if values.has("exactSize"): part.size = values.exactSize
		var before := var_to_bytes(part.snapshot())
		var old_history := SyntheticHistory.new()
		original.surface_history = old_history
		original.source_blueprint_id = "frozen-masonry"
		var expected: Dictionary = original.describe_masonry(part)
		var expected_bytes := var_to_bytes(expected)
		var query_bytes := var_to_bytes(old_history.queries)
		var sync_history := SyntheticHistory.new()
		check(label+"_sync_exact", var_to_bytes(Geometry.describe_source(part,sync_history,"frozen-masonry")) == expected_bytes)
		check(label+"_sync_query_order", var_to_bytes(sync_history.queries) == query_bytes)
		for budget: int in [1,2500,4000]:
			var history := SyntheticHistory.new()
			var cursor = Geometry.begin_source(part,history,"frozen-masonry")
			check(label+"_setup_no_queries_"+str(budget), history.queries.is_empty())
			var value := drain(cursor,label+"_"+str(budget),budget)
			check(label+"_cursor_exact_"+str(budget), var_to_bytes(value) == expected_bytes)
			check(label+"_query_order_"+str(budget), var_to_bytes(history.queries) == query_bytes)
		check(label+"_source_unchanged", var_to_bytes(part.snapshot()) == before)
		check(label+"_typed_arrays", expected.regularTransforms.is_typed() and expected.regularCustomData.is_typed())
		var profile: Dictionary = expected.repairProfile
		for face in 4:
			var old_transforms: Array[Transform3D] = [Transform3D.IDENTITY]
			var new_transforms: Array[Transform3D] = [Transform3D.IDENTITY]
			var old_flags: Array[bool] = [false]
			var new_flags: Array[bool] = [false]
			original.append_brick_face_transforms(old_transforms,old_flags,part.size,face<2,-1.0 if face%2==0 else 1.0,0.68,0.285,0.022,0.075,0.371,profile,face)
			Geometry.append_brick_face_transforms(new_transforms,new_flags,part.size,face<2,-1.0 if face%2==0 else 1.0,0.68,0.285,0.022,0.075,0.371,profile,face)
			check(label+"_face_wrapper_"+str(face),var_to_bytes([old_transforms,old_flags])==var_to_bytes([new_transforms,new_flags]))
		original.surface_history = SyntheticHistory.new()
		var custom: Array = original.build_masonry_custom_data(expected.regularTransforms,part)
		var custom_history := SyntheticHistory.new()
		check(label+"_custom_wrapper",var_to_bytes(custom)==var_to_bytes(Geometry.build_masonry_custom_data(expected.regularTransforms,part,custom_history)))
		for point: Vector3 in [Vector3.ZERO,Vector3(0.3,0.4,-0.2)]:
			check(label+"_repair_at_"+str(point),original.masonry_repair_cluster_at(part,point,profile)==Geometry.masonry_repair_cluster_at(part,point,profile))
			check(label+"_repair_blend_"+str(point),original.masonry_repair_patch_blend(part,point,profile,0.31)==Geometry.masonry_repair_patch_blend(part,point,profile,0.31))
		checks[label+"_completed"] = true
	func cancel_controls() -> void:
		checks.cancellation_completed = false
		guard.advance("synthetic:cancellation")
		var part := SpyPart.new({"id":"front_cancel","kind":"wall","semantic":"facade","size":Vector3(7,5,0.5)})
		var history := SyntheticHistory.new()
		var cursor = Geometry.begin_source(part,history,"cancel")
		check("setup_no_snapshot_or_queries",part.snapshots==0 and history.queries.is_empty())
		check("setup_retains_input",is_same(cursor.part,part) and is_same(cursor.surface_history,history))
		check("budget_zero_rejected",cursor.advance(0).status=="rejected")
		check("budget_4001_rejected",cursor.advance(4001).status=="rejected")
		check("invalid_budget_no_work",cursor.status().units==0)
		cursor.cancel()
		check("entry_cancel",cursor.advance().status=="cancelled" and cursor.take_result().is_empty() and history.queries.is_empty())
		for stop in [1,2,3,7]:
			history = SyntheticHistory.new()
			history.stop=stop
			cursor=Geometry.begin_source(part,history,"cancel")
			history.target=weakref(cursor)
			while cursor.status().status=="pending_budget" and bounded(): cursor.advance(4000)
			check("query_cancel_"+str(stop),cursor.status().status=="cancelled" and history.queries.size()==stop and cursor.take_result().is_empty())
			check("query_reentry_"+str(stop),history.reentrant_rejected)
			var before: int = history.queries.size()
			cursor.advance(4000); cursor.cancel()
			check("query_cancel_terminal_"+str(stop),history.queries.size()==before)
		for phase in ["faces","partition","regular_custom","repair_flags","repair_custom","complete"]:
			history=SyntheticHistory.new()
			cursor=Geometry.begin_source(part,history,"cancel")
			while cursor.status().status=="pending_budget" and cursor.status().phase!=phase and bounded(): cursor._step()
			check(phase+"_reached",cursor.status().phase==phase)
			if phase=="faces":
				while cursor.transforms.is_empty() and bounded(): cursor._step()
			var count: int = cursor.transforms.size()
			var queries: int = history.queries.size()
			cursor.cancel(); cursor.advance(4000)
			check(phase+"_cancel_no_partial",cursor.status().status=="cancelled" and cursor.take_result().is_empty())
			check(phase+"_retains_partial_no_queries",cursor.transforms.size()==count and history.queries.size()==queries)
		history=SyntheticHistory.new()
		cursor=Geometry.begin_source(part,history,"cancel")
		var bounded_units := true
		while cursor.status().status=="pending_budget" and bounded():
			var count: int = cursor.transforms.size()
			var query_count: int = history.queries.size()
			cursor._step()
			bounded_units = bounded_units and cursor.transforms.size()-count<=1 and history.queries.size()-query_count<=1
		check("one_candidate_or_history_query_per_unit",bounded_units and cursor.status().status=="ready")
		var count: int = cursor.transforms.size()
		cursor.cancel()
		check("ready_cancel_hides_result_retains_arrays",cursor.take_result().is_empty() and cursor.transforms.size()==count and count>0)
		# Existing worker retirement primitive; this contract itself is already on
		# an owned worker. Weak observations do not retain either input owner.
		original.surface_history = SyntheticHistory.new()
		var part_ref: WeakRef = weakref(part)
		var history_ref: WeakRef = weakref(history)
		var retirement := Worker.RetirementState.new()
		retirement.payload={"cursor":cursor}
		part=null; history=null; cursor=null
		check("retirement_owns_cancelled_inputs",part_ref.get_ref()!=null and history_ref.get_ref()!=null)
		retirement.transferred.post()
		retirement.release_payload()
		check("retirement_releases_inputs",part_ref.get_ref()==null and history_ref.get_ref()==null)
		check("retirement_on_owned_worker",retirement.released_on_thread==OS.get_thread_caller_id() and retirement.payload.is_empty())
		checks.cancellation_completed = true
	func actual_case() -> void:
		checks.actual_completed = false
		guard.advance("actual:load")
		check("actual_source_sha",FileAccess.get_sha256(INPUT)==INPUT_SHA)
		if not checks.actual_source_sha: return
		var file := FileAccess.open(INPUT,FileAccess.READ)
		if file==null: check("actual_source_open",false); return
		var source: Dictionary = file.get_var(false)
		file.close()
		var record: Dictionary = {}
		var history_parts: Array = []
		for value: Dictionary in source.blueprint.parts:
			if value.id=="urban_civic_tower": record=value
			# These are exactly configure()'s emitters, retained in source order.
			if value.kind in ["window","door"] or String(value.semantic).contains("eave") or bool(value.recipe.get("weatheringEave",false)):
				history_parts.append(HistoryPart.new(value))
		check("actual_dense_wall_found",not record.is_empty())
		if record.is_empty(): return
		var part = Part.new(record)
		part.size=record.size # Preserve accepted dimensions, no constructor repair.
		check("actual_part_exact",var_to_bytes(part.snapshot())==var_to_bytes(record))
		original.surface_history=load("res://artifacts/citadel-runtime-integration/masonry-descriptor-reference-01/SurfaceHistoryFieldOriginal.gd").new()
		original.surface_history.configure(source.blueprint.recipe,history_parts)
		original.source_blueprint_id=String(source.blueprint.id)
		var history := History.new()
		history.configure(source.blueprint.recipe,history_parts)
		var old_history_bytes := var_to_bytes([original.surface_history.route_corridors,original.surface_history.tree_placements,original.surface_history.history_events,original.surface_history.history_event_cells])
		check("actual_history_exact",old_history_bytes==var_to_bytes([history.route_corridors,history.tree_placements,history.history_events,history.history_event_cells]))
		guard.advance("actual:old_descriptor")
		var expected: Dictionary = original.describe_masonry(part)
		var expected_bytes := var_to_bytes(expected)
		check("actual_dense_output_nonempty",expected.regularTransforms.size()>100)
		check("actual_sync_exact",expected_bytes==var_to_bytes(Geometry.describe_source(part,history,original.source_blueprint_id)))
		for budget: int in [1,2500,4000]:
			guard.advance("actual:cursor_"+str(budget))
			var cursor = Geometry.begin_source(part,history,original.source_blueprint_id)
			var value := drain(cursor,"actual_"+str(budget),budget)
			check("actual_cursor_exact_"+str(budget),expected_bytes==var_to_bytes(value))
		check("actual_part_unchanged",var_to_bytes(part.snapshot())==var_to_bytes(record))
		check("actual_history_unchanged",old_history_bytes==var_to_bytes([history.route_corridors,history.tree_placements,history.history_events,history.history_event_cells]))
		check("actual_input_hash_unchanged",FileAccess.get_sha256(INPUT)==INPUT_SHA)
		cases.append({"label":"historical_actual_dense_wall","partId":part.id,"partSize":str(part.size),
			"regular":expected.regularTransforms.size(),"repair":expected.repairTransforms.size(),
			"historyEmitterCount":history_parts.size(),"descriptorEncodedBytes":expected_bytes.size()})
		checks.actual_completed = true
	func execute() -> Dictionary:
		for path: String in HASHES: check("frozen_"+path.get_file(),FileAccess.get_sha256(path)==HASHES[path])
		if checks.values().has(false): return {"checks":checks,"cases":cases}
		original=load(REFERENCE).new()
		for entry: Dictionary in [
			{"id":"ordinary_front","kind":"wall","material":"brick","semantic":"facade","size":Vector3(4,3,0.4)},
			{"id":"rubble_front","kind":"foundation","material":"stone_foundation","size":Vector3(5,2,0.7)},
			{"id":"castle_front","kind":"wall","material":"stone_foundation","size":Vector3(8,4,0.7)},
			{"id":"castle_scaled","kind":"wall","material":"brick","size":Vector3(30,20,1)},
			{"id":"short","kind":"wall","material":"brick","size":Vector3(2,0.7,0.2)},
			{"id":"narrow","kind":"wall","material":"brick","size":Vector3(0.1,2.7,0.1)},
			{"id":"zero_rows","kind":"wall","size":Vector3.ONE,"exactSize":Vector3(2,0.0005,1)},
			{"id":"negative_front","kind":"wall","semantic":"facade","size":Vector3(3.1,2.6,0.3),"position":Vector3(-7,-1,8),"rotation":Vector3(0,0.37,0)}
		]:
			if not bounded(): check("synthetic_deadline",false); break
			synthetic_case(entry.id,entry)
		cancel_controls()
		actual_case()
		original=null
		return {"checks":checks,"cases":cases}

static func execute_worker(guard: Worker.RunState) -> Dictionary:
	guard.begin_work()
	var runner := Run.new()
	runner.guard=guard
	runner.deadline=Time.get_ticks_msec()+75000
	var result := runner.execute()
	result["threadId"]=OS.get_thread_caller_id()
	return result

func _initialize() -> void: call_deferred("run")
func run() -> void:
	var output := OS.get_environment("MASONRY_DESCRIPTOR_OUTPUT")
	if output.is_empty(): quit(2); return
	var guard := Worker.RunState.new()
	var thread := Thread.new()
	var started := Time.get_ticks_msec()
	if thread.start(execute_worker.bind(guard))!=OK: quit(2); return
	var next_progress := started+5000
	while thread.is_alive():
		if Time.get_ticks_msec()-started>75000: guard.cancel()
		if Time.get_ticks_msec()>=next_progress:
			print("MASONRY DESCRIPTOR progress ",JSON.stringify(guard.snapshot()))
			next_progress=Time.get_ticks_msec()+5000
		await process_frame
	var report: Dictionary = thread.wait_to_finish()
	report.checks.worker_joined=not thread.is_started()
	report.checks.off_main=report.threadId!=OS.get_thread_caller_id()
	report.checks.within_deadline=not guard.is_cancelled()
	report["schema"]="masonry-descriptor-contract/v1"
	report["evidence"]="Frozen 76bb474 descriptor oracle; synthetic and historical actual part; no rendering or Site generation."
	report["passed"]=not report.checks.values().has(false)
	report["checkCount"]=report.checks.size()
	report["passedCount"]=report.checks.values().count(true)
	report["elapsedMsec"]=Time.get_ticks_msec()-started
	report["sourceSha256"]=INPUT_SHA
	report["geometrySha256"]=FileAccess.get_sha256("res://scripts/buildings/MasonryDescriptorGeometry.gd")
	report["contractSha256"]=FileAccess.get_sha256("res://scripts/testing/buildings/MasonryDescriptorGeometryContract.gd")
	DirAccess.make_dir_recursive_absolute(output)
	var file := FileAccess.open(output.path_join("report.json"),FileAccess.WRITE)
	if file==null: quit(2); return
	file.store_string(JSON.stringify(report,"\t")); file.close()
	print("MASONRY DESCRIPTOR ",report.passedCount,"/",report.checkCount)
	quit(0 if report.passed else 1)
