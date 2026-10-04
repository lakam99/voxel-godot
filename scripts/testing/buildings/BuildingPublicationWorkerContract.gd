extends SceneTree
## Synthetic service/thread ownership controls plus one empty-source real prepare.
## No Site build, publication, Nodes on workers, terrain or gameplay acceptance.
const Worker = preload("res://scripts/buildings/BuildingPublicationWorker.gd")
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Plan = preload("res://scripts/buildings/FurnishingPlan.gd")
const Profile = preload("res://scripts/world/BuildingTerrainProfile.gd")
const BINDING := {"siteId":"synthetic-site", "sourceKey":"synthetic-source", "generation":1}

class Trace extends RefCounted:
	var mutex := Mutex.new()
	var thread_id := -1
	func record() -> void:
		mutex.lock(); thread_id=OS.get_thread_caller_id(); mutex.unlock()
	func read() -> int:
		mutex.lock(); var result := thread_id; mutex.unlock(); return result

class Probe extends RefCounted:
	var trace: Trace
	func _init(value: Trace) -> void: trace=value
	func _notification(what: int) -> void:
		if what==NOTIFICATION_PREDELETE: trace.record()

class SyntheticWorker extends Worker:
	var gated := false
	var gate := Semaphore.new()
	var entered := Semaphore.new()
	var output_trace := Trace.new()
	var fail_prepare_count := 0
	var fail_retire_count := 0
	func _prepare_source(_source: Dictionary, binding: Dictionary, _continuation: Callable, _description_callback: Callable = Callable()) -> Dictionary:
		if gated:
			entered.post()
			gate.wait()
		# Deliberately ignores cancellation to exercise _run's late-reject path.
		var holder := Preparation.PreparedSource.new()
		holder._binding=binding
		holder._payload={"syntheticDisposalProbe":Probe.new(output_trace)}
		return {"ready":true,"reason":"","prepared":holder}
	func _start_thread(work: Callable) -> int:
		if _active.get("kind")=="preparation" and fail_prepare_count>0:
			fail_prepare_count-=1
			return ERR_CANT_CREATE
		if _active.get("kind")=="retirement" and fail_retire_count>0:
			fail_retire_count-=1
			return ERR_CANT_CREATE
		return super._start_thread(work)

class DescriptionGateWorker extends Worker:
	var gate := Semaphore.new()
	var entered := Semaphore.new()
	func _prepare_source(input: Dictionary, binding: Dictionary, continuation: Callable, description_callback: Callable = Callable()) -> Dictionary:
		return super._prepare_source(input,binding,continuation,func(description):
			var accepted: bool = description_callback.is_valid() and description_callback.call(description) == true
			if accepted:
				entered.post()
				gate.wait()
			return accepted)

class DescriptionProbe extends RefCounted:
	var binding: Dictionary
	var trace: Trace
	func _init(source_binding: Dictionary, value: Trace) -> void:
		binding = source_binding
		trace = value
	func _notification(what: int) -> void:
		if what == NOTIFICATION_PREDELETE: trace.record()

class DescriptionProbeWorker extends Worker:
	# Explicit synthetic lifetime probe, not a valid production source artifact.
	var gate := Semaphore.new()
	var entered := Semaphore.new()
	var trace := Trace.new()
	func _prepare_source(_input: Dictionary, binding: Dictionary, _continuation: Callable, description_callback: Callable = Callable()) -> Dictionary:
		var description := DescriptionProbe.new(binding,trace)
		if not description_callback.call(description): return {"ready":false,"reason":"cancelled"}
		entered.post()
		gate.wait()
		return {"ready":false,"reason":"cancelled"}

var checks: Dictionary = {}
var metrics: Dictionary = {}
func _initialize() -> void: call_deferred("_run")
func check(label: String, passed: bool) -> void:
	checks[label]=passed
	if not passed: print("WORKER CONTRACT FAILURE ",label)
static func freeze(value: Variant) -> void:
	if value is Dictionary:
		for item in value.values(): freeze(item)
		value.make_read_only()
	elif value is Array:
		for item in value: freeze(item)
		value.make_read_only()
static func profile() -> Dictionary:
	var mask: Array = []
	var distances: Array = []
	for z in range(-2,3):
		for x in range(-2,3):
			mask.append(1 if absi(x)<=1 and absi(z)<=1 else 0)
			distances.append(float(maxi(0,maxi(absi(x),absi(z))-1)))
	return {"version":1,"worldSeed":"synthetic-world","siteId":BINDING.siteId,"sourceSignature":"a".repeat(64),
		"cellSize":1.35,"coreCells":Rect2i(-1,-1,3,3),"envelopeCells":Rect2i(-2,-2,5,5),
		"origin":Vector3.ZERO,"level":0.0,"apronCells":1,"reservationCells":Rect2i(-1,-1,3,3),
		"groundRootPoints":[Vector3(-0.4,0,-0.4),Vector3(0.4,0,-0.4),Vector3(0.4,0,0.4),Vector3(-0.4,0,0.4)],
		"supportMask":mask,"distanceCells":distances}
static func source(trace: Trace = null, profile_trace: Trace = null) -> Dictionary:
	var b = Blueprint.new("synthetic-empty",1,"stone")
	var f = Plan.new("synthetic-empty-furniture",1,b.id)
	var furniture: Dictionary = f.snapshot()
	furniture["accessReservations"]=f.access_reservations_snapshot()
	var value := {"status":"prepared","blueprint":b.snapshot(),"furnishingPlan":furniture,"profile":profile()}
	# Intentional test-only lifetime sentinel; production Admission has no Objects.
	if trace!=null: value["syntheticInputProbe"]=Probe.new(trace)
	if profile_trace!=null: value.profile["syntheticProfileProbe"]=Probe.new(profile_trace)
	freeze(value)
	return value
func off_main(trace: Trace) -> bool:
	return trace.read()!=-1 and trace.read()!=OS.get_thread_caller_id()
func wait_completed(job, label: String) -> Dictionary:
	var deadline := Time.get_ticks_msec()+5000
	var state: Dictionary = job.poll()
	while state.completedToken==0 and Time.get_ticks_msec()<deadline:
		await process_frame
		state=job.poll()
	check(label+"_completed",state.completedToken>0)
	metrics[label]=state
	return state
func drain(job, label: String, closing := false) -> Dictionary:
	var deadline := Time.get_ticks_msec()+5000
	var state: Dictionary = job.poll()
	while (not state.shutdownComplete if closing else state.busy) and Time.get_ticks_msec()<deadline:
		await process_frame
		state=job.poll()
	check(label+"_drained",state.shutdownComplete if closing else not state.busy)
	check(label+"_no_completion_slot",state.completedToken==0)
	metrics[label]=state
	return state

func real_empty() -> void:
	var job := Worker.new()
	var input := source()
	var frozen_profile: Dictionary = input.profile
	check("tiny_profile_valid",Profile.valid(frozen_profile,"synthetic-world",1.35))
	var identity := BINDING.duplicate()
	var receipt: Dictionary = job.dispatch(input,identity)
	identity.generation=99
	check("dispatch_queued",receipt.status=="queued" and receipt.token>0)
	check("binding_copied",receipt.binding==BINDING and receipt.binding.is_read_only())
	check("dispatch_deferred",job._thread==null)
	check("queued_elapsed_zero",job._state.snapshot().elapsedUsec==0)
	var duplicate: Dictionary = job.dispatch(input,BINDING)
	check("duplicate_controller_compatible",duplicate.status=="queued" and duplicate.token==receipt.token)
	check("busy_retains_demand",job.dispatch(input,identity).status=="busy")
	input={}
	var run_state = job._state
	# Synthetic stale queue clock: real entry must replace this, not inherit it.
	run_state.started_usec=-70000000
	run_state.previous_usec=-70000000
	run_state.max_stage_gap_usec=70000000
	var launch_floor := Time.get_ticks_usec()
	var status := await wait_completed(job,"real")
	check("clock_reset_on_actual_entry",run_state.started_usec>=launch_floor and run_state.previous_usec>=run_state.started_usec and run_state.max_stage_gap_usec<70000000)
	check("run_state_input_refs_released",run_state.source.is_empty() and run_state.binding.is_empty())
	check("completed_not_running",not status.workerRunning and status.workerKind=="")
	for i in range(3):
		await process_frame
		status=job.poll()
	check("paused_owner_keeps_ready_slot",status.completedToken==receipt.token and not status.workerRunning)
	check("wrong_binding_does_not_consume",job.take_result(receipt.token,identity).status=="stale_token")
	var taken: Dictionary = job.take_result(receipt.token,BINDING)
	check("real_prepared_consumed",taken.status=="consumed" and taken.result.ready and taken.result.prepared is Preparation.PreparedSource)
	check("result_retains_same_frozen_profile",is_same(taken.result.profile,frozen_profile) and taken.result.profile.is_read_only() and taken.result.profile.supportMask.is_read_only())
	check("worker_spatial_origin_matches_profile",taken.result.prepared._payload.spatialDependencies.origin==frozen_profile.origin)
	check("worker_spatial_binding_matches_source",taken.result.prepared._payload.spatialDependencies.binding==BINDING)
	frozen_profile={}
	check("take_one_shot",job.take_result(receipt.token,BINDING).status=="stale_token")
	job.request_shutdown()
	check("retirement_accepted_while_closing",job.retire_external_payload(taken))
	taken={}
	check("retirement_deferred",job._thread==null and not job._retired.is_empty())
	await drain(job,"real_shutdown",true)
	check("closed_rejects_dispatch",job.dispatch(source(),BINDING).reason=="shutting_down")

func queued_cancel() -> void:
	var job := SyntheticWorker.new()
	var trace := Trace.new()
	var input := source(trace)
	var receipt: Dictionary = job.dispatch(input,BINDING)
	input={}
	check("queued_cancel_accepted",job.cancel(receipt.token))
	check("queued_cancel_no_owner_disposal",trace.read()==-1 and job._thread==null)
	await drain(job,"queued_cancel")
	check("queued_input_retired_off_main",off_main(trace))
	check("queued_cancel_token_forgotten",job.take_result(receipt.token,BINDING).status=="stale_token")
	job.request_shutdown()
	await drain(job,"queued_shutdown",true)

func completed_cancel() -> void:
	var job := SyntheticWorker.new()
	var trace := Trace.new()
	var profile_trace := Trace.new()
	var input := source(trace,profile_trace)
	var receipt: Dictionary = job.dispatch(input,BINDING)
	input={}
	await wait_completed(job,"completed_cancel_ready")
	check("completed_input_released_off_main",off_main(trace))
	check("profile_outlives_evicted_input",profile_trace.read()==-1)
	check("completed_cancel_accepted",job.cancel(receipt.token))
	check("completed_cancel_vacates_slot",job._completed.is_empty())
	await drain(job,"completed_cancel")
	check("completed_holder_retired_off_main",off_main(job.output_trace))
	check("completed_profile_retired_off_main",off_main(profile_trace))
	check("new_demand_after_abandoned_completion",job.dispatch(source(),BINDING).status=="queued")
	job.request_shutdown()
	await drain(job,"completed_shutdown",true)

func active_cancel() -> void:
	var job := SyntheticWorker.new()
	job.gated=true
	var receipt: Dictionary = job.dispatch(source(),BINDING)
	var status: Dictionary = job.poll()
	check("running_preparation_status",status.workerRunning and status.workerKind=="preparation" and status.progress.has("elapsedUsec"))
	var deadline := Time.get_ticks_msec()+5000
	var entered := job.entered.try_wait()
	while not entered and Time.get_ticks_msec()<deadline:
		await process_frame
		entered=job.entered.try_wait()
	check("active_worker_entered",entered)
	check("active_cancel_accepted",job.cancel(receipt.token))
	job.gate.post()
	await drain(job,"active_cancel")
	check("active_late_prepared_disposed_off_main",off_main(job.output_trace))
	job.request_shutdown()
	await drain(job,"active_shutdown",true)

func stale_terminal() -> void:
	var job := SyntheticWorker.new()
	var receipt: Dictionary = job.dispatch(source(),BINDING)
	job.poll()
	var deadline := Time.get_ticks_msec()+5000
	while job._thread.is_alive() and Time.get_ticks_msec()<deadline: await process_frame
	check("stale_worker_terminal_before_reset",not job._thread.is_alive())
	job.reset()
	await drain(job,"stale_terminal")
	check("stale_holder_retired_off_main",off_main(job.output_trace))
	check("stale_receipt_rejected",job.take_result(receipt.token,BINDING).status=="stale_token")
	job.request_shutdown()
	await drain(job,"stale_shutdown",true)

func failed_starts() -> void:
	var job := SyntheticWorker.new()
	job.fail_prepare_count=1
	job.fail_retire_count=1
	var trace := Trace.new()
	var input := source(trace)
	job.dispatch(input,BINDING)
	input={}
	var status: Dictionary = job.poll()
	check("prepare_start_failure_keeps_input",not status.workerRunning and status.preparationStartError==ERR_CANT_CREATE and trace.read()==-1)
	check("failed_start_elapsed_zero",status.progress.elapsedUsec==0)
	job.request_shutdown()
	status=job.poll()
	check("retire_start_failure_keeps_input",not status.shutdownComplete and not status.workerRunning and status.retirementStartError==ERR_CANT_CREATE and trace.read()==-1)
	await drain(job,"failed_starts_shutdown",true)
	check("failed_start_payload_eventually_worker_retired",off_main(trace))

func wait_description_gate(job, label: String) -> void:
	job.poll()
	var deadline := Time.get_ticks_msec()+5000
	var entered: bool = job.entered.try_wait()
	while not entered and Time.get_ticks_msec()<deadline:
		await process_frame
		entered=job.entered.try_wait()
	check(label+"_description_boundary_entered",entered)

func description_handoff(consume_early: bool, cancel_after: bool) -> void:
	var label := "description_" + ("early" if consume_early else "late") + ("_cancel" if cancel_after else "_complete")
	var job := DescriptionGateWorker.new()
	var input := source()
	var profile_identity: Dictionary = input.profile
	var receipt := job.dispatch(input,BINDING)
	input={}
	await wait_description_gate(job,label)
	check(label+"_preparation_still_running",job._thread != null and job._thread.is_alive() and job.poll().completedToken==0)
	var wrong := BINDING.duplicate(); wrong.sourceKey += ":changed"
	check(label+"_wrong_binding_rejected",job.take_description(receipt.token,wrong).status=="pending")
	var early: Dictionary = job.take_description(receipt.token,BINDING) if consume_early else {}
	if consume_early:
		check(label+"_delivered",early.get("status")=="described")
		if early.get("status")=="described":
			var description = early.description
			check(label+"_facts_frozen_without_dense",description.parts.is_read_only() and description.cells.is_read_only() \
				and description.navigation.is_read_only() and description.solid_records.is_read_only() \
				and description.navigation_tiles.is_read_only() and description.navigation_tiles.is_empty())
			check(label+"_same_profile",is_same(early.profile,profile_identity))
			check(label+"_description_not_publication",description.requirements(Rect2i(-1,-1,2,2)).publicationAcknowledged==false)
			check(label+"_one_transfer_while_active",job.take_description(receipt.token,BINDING).status=="pending")
			description=null
	profile_identity={}
	if cancel_after:
		check(label+"_cancel_accepted",job.cancel(receipt.token))
		check(label+"_cancel_rejects_description",job.take_description(receipt.token,BINDING).status=="pending")
	job.gate.post()
	if cancel_after:
		await drain(job,label)
		check(label+"_no_late_description",job.take_description(receipt.token,BINDING).status=="pending")
	else:
		await wait_completed(job,label)
		var late := job.take_description(receipt.token,BINDING)
		check(label+"_completed_transfer_policy",late.status==("pending" if consume_early else "described"))
		if not consume_early:
			early=late
			check(label+"_completed_one_transfer",job.take_description(receipt.token,BINDING).status=="pending")
		late={}
		var complete := job.take_result(receipt.token,BINDING)
		check(label+"_normal_result_preserved",complete.get("status")=="consumed" and complete.get("result",{}).get("ready",false))
		if complete.get("status")=="consumed" and early.get("status")=="described":
			var dense = complete.result.prepared._payload.spatialDependencies
			check(label+"_dense_shares_immutable_source",dense!=early.description and is_same(dense.parts,early.description.parts) \
				and is_same(dense.navigation,early.description.navigation) and is_same(dense.solid_records,early.description.solid_records))
			check(label+"_dense_did_not_mutate_description",dense.navigation_tiles.get("ready",false) and early.description.navigation_tiles.is_empty())
			dense=null
		early["completeResult"]=complete
		complete={}
	job.request_shutdown()
	if not early.is_empty():
		check(label+"_external_retirement_accepted",job.retire_external_payload(early))
		early={}
	await drain(job,label+"_shutdown",true)

func unclaimed_description_retirement(reset_owner: bool) -> void:
	var label := "unclaimed_description_" + ("reset" if reset_owner else "cancel")
	var job := DescriptionProbeWorker.new()
	var receipt := job.dispatch(source(),BINDING)
	await wait_description_gate(job,label)
	check(label+"_probe_retained",job.trace.read()==-1)
	if reset_owner: job.reset()
	else: check(label+"_cancel_accepted",job.cancel(receipt.token))
	check(label+"_stale_description_rejected",job.take_description(receipt.token,BINDING).status=="pending")
	job.gate.post()
	await drain(job,label)
	check(label+"_disposed_on_worker",off_main(job.trace))
	job.request_shutdown()
	await drain(job,label+"_shutdown",true)

## This uses the ordinary worker entry points, but stays source/packet-only:
## no scene root, publisher, collision, navigation or gameplay is involved.
func base_and_physical_packet() -> void:
	var job := Worker.new()
	var blueprint := Blueprint.new("packet-worker",1,"timber")
	blueprint.add_part({"id":"packet-wall","kind":"wall","material":"fired_brick",
		"size":Vector3(4,3,0.4),"position":Vector3(-4,1.5,0)})
	blueprint.add_part({"id":"packet-paving","kind":"foundation","material":"cobblestone",
		"size":Vector3(4,0.12,3),"position":Vector3(0,0.06,0),
		"recipe":{"pavingFamily":"civic_setts","pavingHeading":"x"}})
	blueprint.add_part({"id":"packet-roof","kind":"roof","material":"roof_slate",
		"size":Vector3(4,0.15,3),"position":Vector3(4,3,0)})
	var furnishings := Plan.new("packet-worker-furnishings",1,blueprint.id)
	var furnishing_source: Dictionary = furnishings.snapshot()
	furnishing_source.accessReservations=[]
	var input := {"status":"prepared","blueprint":blueprint.snapshot(),"furnishingPlan":furnishing_source,"profile":profile()}
	freeze(input)
	var base_receipt: Dictionary = job.dispatch_publication_base(input,BINDING)
	check("packet_base_dispatch_queued",base_receipt.status=="queued" and base_receipt.token>0)
	input={}
	await wait_completed(job,"packet_base")
	var base_taken: Dictionary = job.take_result(base_receipt.token,BINDING)
	var base = base_taken.get("result",{}).get("base")
	check("packet_base_worker_result",base_taken.status=="consumed" and base!=null and base.matches(BINDING) \
		and base.description.publication_groups.get("ready",false))
	if base==null:
		job.request_shutdown()
		await drain(job,"packet_base_shutdown",true)
		return
	var navigation_receipt: Dictionary = job.dispatch_publication_base_navigation(base,BINDING)
	check("packet_base_navigation_dispatch_queued",navigation_receipt.status=="queued" and navigation_receipt.token>0)
	await wait_completed(job,"packet_base_navigation")
	var navigation_taken: Dictionary = job.take_result(navigation_receipt.token,BINDING)
	var navigation_source: Dictionary = navigation_taken.get("result",{}).get("navigationSource",{})
	check("packet_base_navigation_source_matches_base",navigation_taken.status=="consumed" and navigation_source.is_read_only() \
		and navigation_source.get("binding",{})==BINDING and navigation_source.get("producer")!=null)
	var group_ids: Array[String] = []
	for group_id in base.description.publication_groups.order: group_ids.append(String(group_id))
	group_ids.sort()
	var unsorted: Array[String] = group_ids.duplicate()
	unsorted.reverse()
	if unsorted==group_ids: unsorted.append("missing")
	check("packet_worker_unsorted_scope_rejected",job.dispatch_physical_group_packet(base,unsorted,BINDING).reason=="invalid_physical_group_ids")
	var packet_receipt: Dictionary = job.dispatch_physical_group_packet(base,group_ids,BINDING)
	check("packet_worker_dispatch_queued",packet_receipt.status=="queued" and packet_receipt.token>0)
	await wait_completed(job,"packet_worker")
	var packet_taken: Dictionary = job.take_result(packet_receipt.token,BINDING)
	var packet = packet_taken.get("result",{}).get("packet")
	check("packet_worker_result_matches_base",packet_taken.status=="consumed" and packet!=null and packet.matches(base,group_ids))
	check("packet_worker_group_scope_value_keyed",packet!=null and packet.building_entries.has("packet-wall") \
		and packet.building_entries.has("packet-paving") and packet.building_entries.has("packet-roof"))
	if packet!=null and packet.building_entries.has("packet-wall"):
		var wall_entry: Dictionary = packet.building_entries["packet-wall"]
		var wall_spatial: Dictionary = base.description.parts["building:packet-wall"]
		check("packet_worker_owner_cell_and_bounds_match_source",wall_entry.get("ownerCell") is Vector2i \
			and wall_entry.ownerCell==wall_spatial.ownerCell and wall_entry.bounds==wall_spatial.bounds)
		var old_entries: Dictionary = packet.building_entries
		var tampered_entries := old_entries.duplicate()
		var tampered_wall: Dictionary = wall_entry.duplicate()
		tampered_wall.ownerCell+=Vector2i.ONE
		tampered_wall.make_read_only()
		tampered_entries["packet-wall"]=tampered_wall
		tampered_entries.make_read_only()
		packet.building_entries=tampered_entries
		check("packet_worker_rejects_owner_cell_tamper",not packet.matches(base,group_ids))
		packet.building_entries=old_entries
	job.request_shutdown()
	check("packet_worker_external_retirement_accepted",job.retire_external_payload({"base":base,"packet":packet,"navigationSource":navigation_source}))
	base=null
	packet=null
	navigation_source={}
	base_taken={}
	packet_taken={}
	navigation_taken={}
	await drain(job,"packet_worker_shutdown",true)

func _run() -> void:
	await real_empty()
	await queued_cancel()
	await completed_cancel()
	await active_cancel()
	await stale_terminal()
	await failed_starts()
	await description_handoff(true,false)
	await description_handoff(false,false)
	await description_handoff(true,true)
	await unclaimed_description_retirement(false)
	await unclaimed_description_retirement(true)
	await base_and_physical_packet()
	var report := {"schema":"building-publication-worker-contract/v1","complete":true,"passed":not checks.values().has(false),
		"evidenceLevel":"synthetic_owned_worker_retirement_and_empty_real_preparation","checks":checks,"metrics":metrics,
		"doesNotProve":"No actual Site build, scene publication, runtime lifecycle, terrain, headed or gameplay acceptance."}
	var output := OS.get_environment("BUILDING_PUBLICATION_WORKER_OUTPUT")
	var file := FileAccess.open(output+"/report.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	print("WORKER CONTRACT COMPLETE ",JSON.stringify({"passed":report.passed,"checks":checks.size()}))
	quit(0 if report.passed else 1)
