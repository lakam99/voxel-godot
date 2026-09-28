extends SceneTree

## Synthetic scheduling/lifetime controls around the real owned worker and
## producer, plus empty-source real scene preparation and a reused nonempty
## synthetic source oracle. No scene construction,
## NavigationServer, live receipt, generated citadel or gameplay acceptance.
const Worker = preload("res://scripts/buildings/BuildingPublicationWorker.gd")
const Producer = preload("res://scripts/buildings/BuildingNavigationTileProducer.gd")
const SourceFixture = preload("res://scripts/testing/buildings/BuildingPublicationWorkerContract.gd")
const ProducerFixture = preload("res://scripts/testing/buildings/BuildingNavigationTileProducerContract.gd")
const TilePreparation = preload("res://scripts/buildings/BuildingNavigationTilePreparation.gd")
const Service = preload("res://scripts/world/CitadelPublicationService.gd")
const BINDING := {"siteId":"synthetic-site","sourceKey":"synthetic-source","generation":1}

class Trace extends RefCounted:
	var mutex := Mutex.new()
	var entered := Semaphore.new()
	var resume := Semaphore.new()
	var freed_on_thread := -1
	var advanced_on_threads: Array[int] = []
	var first_advance_state: Dictionary = {}
	var service_progress_held := false
	func hold_service_progress(held: bool) -> void:
		mutex.lock(); service_progress_held = held; mutex.unlock()
	func service_progress_is_held() -> bool:
		mutex.lock(); var held := service_progress_held; mutex.unlock(); return held
	func record_free() -> void:
		mutex.lock(); freed_on_thread = OS.get_thread_caller_id(); mutex.unlock()
	func record_advance(progress: Dictionary, waiting: Array[String], eligible: Array[String]) -> void:
		mutex.lock()
		advanced_on_threads.append(OS.get_thread_caller_id())
		if first_advance_state.is_empty():
			first_advance_state = {"phase":String(progress.get("phase","")),"activeTileKey":String(progress.get("activeTileKey","")),
				"waiting":waiting.slice(0,Worker.MAX_NAVIGATION_BATCH_TILES),"eligible":eligible.duplicate()}
		mutex.unlock()
	func snapshot() -> Dictionary:
		mutex.lock()
		var value := {"freedOnThread":freed_on_thread,"advanceThreads":advanced_on_threads.duplicate(),"firstAdvanceState":first_advance_state.duplicate(true)}
		mutex.unlock()
		return value

class ControlledProducer extends Producer:
	var trace: Trace
	var defer_once := false
	var gate_advance := false
	var gate_on_call := 0
	var defer_steps := 0
	var advance_count := 0
	func advance(budget_usec := 4000, continuation: Callable = Callable(), eligible_outputs: Array[String] = []) -> Dictionary:
		trace.record_advance(status(),_requests,eligible_outputs)
		advance_count += 1
		# Named synthetic scheduling control only. The real active apron job and
		# sampler state remain unchanged while the real worker yields its source.
		if trace.service_progress_is_held(): return status()
		if gate_on_call==advance_count:
			trace.entered.post()
			trace.resume.wait()
		if gate_advance:
			trace.entered.post()
			trace.resume.wait()
			# Deliberately ignore cancellation once; the worker must reject a
			# late successful result and dispose its last source alias off-thread.
			return super.advance(budget_usec,Callable(),eligible_outputs)
		if defer_steps>0:
			defer_steps -= 1
			return status()
		if defer_once:
			defer_once = false
			return status()
		return super.advance(budget_usec,continuation,eligible_outputs)
	func _notification(what: int) -> void:
		if what==NOTIFICATION_PREDELETE and trace!=null: trace.record_free()

class ControlledWorker extends Worker:
	var trace := Trace.new()
	var defer_once := false
	var gate_advance := false
	var gate_on_call := 0
	var defer_steps := 0
	var nonempty_fixture := false
	var prime_active_fixture := false
	var fail_navigation_count := 0
	var fail_retirement_count := 0
	func _prepare_source(source: Dictionary, binding: Dictionary, continuation: Callable, _description_callback: Callable = Callable()) -> Dictionary:
		var producer := ControlledProducer.new()
		producer.trace = trace
		producer.defer_once = defer_once
		producer.gate_advance = gate_advance
		producer.gate_on_call = gate_on_call
		producer.defer_steps = defer_steps
		var fixture: Dictionary = ProducerFixture._fixture() if nonempty_fixture else {
			"manifest":{"supports":[],"doors":[],"verticalLinks":[],"supportSeamLinks":[],"interiorPassageLinks":[]},
			"furniture":{"staticCollision":[]},"solids":[]}
		var expected_tiles := {}
		if nonempty_fixture:
			# An independent full drain of the unchanged sampler is the wrapper
			# oracle. Only the two selected immutable tiles survive preparation.
			var full: Dictionary = TilePreparation.compile(fixture.manifest,fixture.furniture,continuation,fixture.solids)
			if not full.get("ready",false) or not full.get("tiles",{}).has("2,0") or not full.get("tiles",{}).has("30,0"):
				return {"ready":false,"reason":"synthetic_nonempty_oracle_incomplete"}
			for key: String in ["2,0","30,0"]: expected_tiles[key] = full.tiles[key]
			expected_tiles.make_read_only()
		var initialized: Dictionary = producer.begin(fixture.manifest,fixture.furniture,continuation,fixture.solids)
		if initialized.status!="ready": return {"ready":false,"reason":"synthetic_producer_initialization_failed"}
		if prime_active_fixture:
			# Synthetic deterministic setup, performed on the preparation worker:
			# establish a real active apron sample job and an older waiting tail.
			for key: String in ["2,0","30,0","31,0"]: producer.request(key)
			producer._step(0)
			producer._step(0)
			if producer.status().phase!="sample" or producer.status().activeTileKey!="2,0":
				return {"ready":false,"reason":"synthetic_active_apron_setup_failed"}
		var source_binding := binding.duplicate()
		source_binding.make_read_only()
		var envelope := {"producer":producer,"binding":source_binding,"domain":producer.domain()}
		if nonempty_fixture: envelope["expectedTiles"] = expected_tiles
		envelope.make_read_only()
		return {"ready":true,"navigationSource":envelope,"demandedNavigationObserved":bool(source.get("demandedNavigation",false))}
	func _start_thread(work: Callable) -> int:
		if _active.get("kind")=="navigation" and fail_navigation_count>0:
			fail_navigation_count -= 1
			return ERR_CANT_CREATE
		if _active.get("kind")=="retirement" and fail_retirement_count>0:
			fail_retirement_count -= 1
			return ERR_CANT_CREATE
		return super._start_thread(work)

class SyntheticFairnessAdmission extends RefCounted:
	var states: Dictionary = {}
	func stats() -> Dictionary: return {"generation":1,"worldSeed":"synthetic-actual-start-fairness"}
	func source_state(region: Vector2i) -> Dictionary: return states.get(region,{"status":"absent"})

var checks: Dictionary = {}
var metrics: Dictionary = {}

func _initialize() -> void: call_deferred("_run")

func _check(label: String, passed: bool) -> void:
	checks[label] = passed
	if not passed: print("NAVIGATION WORKER FAILURE ",label)

func _off_main(trace: Trace) -> bool:
	var observed := trace.snapshot()
	return observed.freedOnThread!=-1 and observed.freedOnThread!=OS.get_thread_caller_id()

func _worker_thread_running(worker) -> bool:
	# A Thread retains its returned Variant after join. Keep observation aliases
	# in a synchronous frame, never in the fixture coroutine across await/reset.
	var observed: Thread = worker._thread
	return observed!=null and observed.is_alive()

func _worker_thread_terminal(worker) -> bool:
	var observed: Thread = worker._thread
	return observed!=null and not observed.is_alive()

func _worker_thread_weak(worker) -> WeakRef:
	var observed: Thread = worker._thread
	return weakref(observed) if observed!=null else null

func _weak_thread_live(observed: WeakRef) -> bool:
	if observed==null: return false
	var thread: Thread = observed.get_ref() as Thread
	return thread!=null

func _timing_row(worker, token: int) -> Dictionary:
	for row: Dictionary in worker.navigation_timing().history:
		if row.token==token: return row
	return {}

func _joined_timing_order(row: Dictionary, taken := false) -> bool:
	return row.get("queuedUsec",0)>0 and row.get("startedUsec",0)>=row.queuedUsec \
		and row.get("finishedUsec",0)>=row.startedUsec and row.get("joinedUsec",0)>=row.finishedUsec \
		and (row.get("takenUsec",0)>=row.joinedUsec if taken else row.get("takenUsec",-1)==0) \
		and row.get("threadId",-1)>0 and row.threadId!=OS.get_thread_caller_id()

func _timing_values_only(value: Variant) -> bool:
	if value is Dictionary:
		for key: Variant in value:
			if not key is String or not _timing_values_only(value[key]): return false
		return true
	if value is Array:
		for item: Variant in value:
			if not _timing_values_only(item): return false
		return true
	return value is String or value is int or value is bool

func _completed(worker, label: String) -> Dictionary:
	var deadline := Time.get_ticks_msec()+5000
	var state: Dictionary = worker.poll()
	while state.completedToken==0 and state.busy and Time.get_ticks_msec()<deadline:
		await process_frame
		state = worker.poll()
	_check(label+"_completed",state.completedToken>0)
	metrics[label] = state
	return state

func _drain(worker, label: String, closing := false) -> Dictionary:
	var deadline := Time.get_ticks_msec()+5000
	var state: Dictionary = worker.poll()
	while (not state.shutdownComplete if closing else state.busy) and Time.get_ticks_msec()<deadline:
		await process_frame
		state = worker.poll()
	_check(label+"_drained",state.shutdownComplete if closing else not state.busy)
	_check(label+"_zero_owned_work",not worker.has_pending_work() and state.completedToken==0)
	metrics[label] = state
	return state

func _prepared_envelope(worker, label: String) -> Dictionary:
	var queued: Dictionary = worker.dispatch_scene_source(SourceFixture.source(),BINDING)
	_check(label+"_scene_mode_queued",queued.status=="queued" and worker._thread==null)
	await _completed(worker,label+"_prepare")
	var taken: Dictionary = worker.take_result(int(queued.get("token",0)),BINDING)
	var result: Dictionary = taken.get("result",{})
	var envelope: Dictionary = result.get("navigationSource",{})
	_check(label+"_immutable_source_association",result.get("ready",false) and envelope.is_read_only()
		and envelope.get("binding")==BINDING and envelope.get("producer") is Producer)
	_check(label+"_scene_dispatch_preserves_virtual_hook",result.get("demandedNavigationObserved",false))
	return envelope

func _wait_gate(worker, label: String) -> bool:
	worker.poll()
	var deadline := Time.get_ticks_msec()+5000
	var entered: bool = worker.trace.entered.try_wait()
	while not entered and Time.get_ticks_msec()<deadline:
		await process_frame
		entered = worker.trace.entered.try_wait()
	_check(label+"_entered",entered)
	return entered

func _resumable_batch() -> void:
	var worker := ControlledWorker.new()
	worker.defer_steps = Worker.MAX_NAVIGATION_KERNEL_STEPS+1
	var envelope: Dictionary = await _prepared_envelope(worker,"resume")
	if envelope.is_empty():
		worker.request_shutdown(); await _drain(worker,"resume_setup_failure",true); return
	var producer_id: int = envelope.producer.get_instance_id()
	var wrong := BINDING.duplicate(); wrong.generation += 1
	var malformed: Dictionary = envelope.duplicate(false)
	var too_many: Array[String] = []
	for index in range(Worker.MAX_NAVIGATION_BATCH_TILES+1): too_many.append("%d,0" % index)
	_check("invalid_source_binding_keeps_caller_ownership",worker.dispatch_navigation(envelope,["0,0"],wrong).reason=="invalid_navigation_producer_binding"
		and worker.dispatch_navigation(malformed,["0,0"],BINDING).reason=="invalid_navigation_producer_binding" and not worker.has_pending_work())
	_check("invalid_batch_is_bounded_before_transfer",worker.dispatch_navigation(envelope,too_many,BINDING).reason=="invalid_navigation_batch_tiles"
		and worker.dispatch_navigation(envelope,["00,0"],BINDING).reason=="invalid_navigation_batch_tiles" and not worker.has_pending_work())
	_check("invalid_dispatch_order_rejected_before_transfer",worker.dispatch_navigation(envelope,["0,0","1,0"],BINDING,["0,0"]).reason=="invalid_navigation_batch_order"
		and worker.dispatch_navigation(envelope,["0,0","1,0"],BINDING,["0,0","0,0"]).reason=="invalid_navigation_batch_order"
		and worker.dispatch_navigation(envelope,["0,0","1,0"],BINDING,["0,0","2,0"]).reason=="invalid_navigation_batch_order"
		and not worker.has_pending_work())
	malformed = {}
	var keys: Array[String] = ["1,0","0,0"]
	var order: Array[String] = ["1,0","0,0"]
	var queued: Dictionary = worker.dispatch_navigation(envelope,keys,BINDING,order)
	var duplicate: Dictionary = worker.dispatch_navigation(envelope,["0,0","1,0"],BINDING)
	_check("navigation_dispatch_deferred_and_idempotent",queued.status=="queued" and worker._thread==null
		and duplicate.get("duplicate",false) and duplicate.token==queued.token)
	var queued_timing: Dictionary = worker.navigation_timing()
	var queued_row: Dictionary = queued_timing.active
	_check("timing_duplicate_is_one_unstarted_batch",queued_timing.queuedCount==1 and queued_timing.history.size()==1
		and queued_row.get("token")==queued.token and queued_row.get("binding")==BINDING
		and queued_row.get("tileKeys")==["0,0","1,0"] and queued_row.get("tileOrder")==["1,0","0,0"]
		and queued_row.get("queuedUsec",0)>0 and queued_row.get("startedUsec",-1)==0
		and queued_row.get("finishedUsec",-1)==0 and queued_row.get("joinedUsec",-1)==0
		and queued_row.get("takenUsec",-1)==0 and queued_row.get("startAttempts",-1)==0)
	queued_timing.history[0].binding.sourceKey = "caller_mutation"
	queued_timing.history[0].tileKeys.append("3,0")
	queued_timing.aggregates.execution.count = 99
	_check("timing_observer_copies_cannot_mutate_worker",_timing_row(worker,queued.token).binding==BINDING
		and _timing_row(worker,queued.token).tileKeys==["0,0","1,0"] and worker.navigation_timing().aggregates.execution.count==0
		and _timing_values_only(worker.navigation_timing()) and worker._thread==null)
	_check("canonical_duplicate_preserves_original_priority_order",queued.get("requestedTileOrder",[])==["1,0","0,0"]
		and duplicate.get("requestedTileOrder",[])==["1,0","0,0"] and duplicate.requestedTileOrder.is_read_only()
		and worker.dispatch_navigation(envelope,["0,0","1,0"],BINDING,["0,0","0,0"]).reason=="invalid_navigation_batch_order")
	_check("preparation_cannot_alias_navigation_mode",worker.dispatch(SourceFixture.source(),BINDING).status=="busy")
	_check("description_api_cannot_consume_navigation_producer",worker.take_description(queued.token,BINDING).status=="pending")
	envelope = {}
	keys.append("2,0")
	order.reverse()
	await _completed(worker,"resume_owner_turn")
	var joined_timing: Dictionary = _timing_row(worker,queued.token)
	_check("timing_completed_clocks_precede_owner_take",_joined_timing_order(joined_timing)
		and joined_timing.get("disposition")=="completed" and joined_timing.get("startAttempts")==1)
	_check("wrong_binding_cannot_consume_producer",worker.take_result(queued.token,wrong).status=="stale_token")
	_check("timing_rejected_take_does_not_claim_collection",_timing_row(worker,queued.token).takenUsec==0)
	var taken: Dictionary = worker.take_result(queued.token,BINDING)
	var taken_timing: Dictionary = _timing_row(worker,queued.token)
	_check("timing_take_completes_ordered_wall_intervals",_joined_timing_order(taken_timing,true)
		and taken_timing.disposition=="taken" and worker.navigation_timing().aggregates.joinedToTaken.count==1
		and worker.navigation_timing().aggregates.execution.totalUsec==taken_timing.finishedUsec-taken_timing.startedUsec
		and taken_timing.preparationUsec>0 and taken_timing.sliceCount>=1)
	var result: Dictionary = taken.get("result",{})
	_check("bounded_turn_returns_owned_partial_producer_without_empty_success",result.get("ready",false)
		and result.get("kind")=="navigation_batch" and not result.get("batchComplete",true)
		and result.get("tileReceipts",{}).is_empty() and result.get("requestedTileKeys",[])==["0,0","1,0"]
		and result.get("producerStatus",{}).get("pendingRequestCount")==2
		and result.get("navigationSource",{}).get("producer") is Producer
		and result.navigationSource.producer.get_instance_id()==producer_id)
	var first_progress: Dictionary = result.get("batchProgress",{})
	_check("dispatch_order_is_private_frozen_and_reported",result.get("requestedTileOrder",[])==["1,0","0,0"]
		and result.requestedTileOrder.is_read_only() and first_progress.get("selectedTileOrder",[])==["1,0","0,0"])
	_check("producer_elapsed_is_actual_preparation_wall",first_progress.get("preparationUsec",-1)==result.get("producerStatus",{}).get("preparationUsec",-2)
		and int(first_progress.get("preparationUsec",0))>0 and first_progress.get("preparationTimeScope")=="producer_begin_and_advance_wall")
	var calls := int(first_progress.get("sliceCount",0))
	var elapsed := int(first_progress.get("turnElapsedUsec",0))
	_check("continuation_count_and_elapsed_have_explicit_yield",calls>=1 and calls<=Worker.MAX_NAVIGATION_KERNEL_STEPS
		and (calls==Worker.MAX_NAVIGATION_KERNEL_STEPS or elapsed>=Worker.NAVIGATION_TURN_USEC)
		and first_progress.get("yieldReason")==("kernel_step_limit" if calls==Worker.MAX_NAVIGATION_KERNEL_STEPS else "elapsed_turn_limit")
		and first_progress.get("selectedTileKeys",[])==["0,0","1,0"]
		and first_progress.get("pendingTileKeys",[])==["0,0","1,0"])
	var first_trace: Dictionary = worker.trace.snapshot()
	_check("incomplete_kernels_share_thread_before_owner_yield",not first_trace.advanceThreads.is_empty()
		and first_trace.advanceThreads.all(func(id: int): return id==first_trace.advanceThreads[0])
		and taken.token==queued.token and calls==first_trace.advanceThreads.size())
	_check("partial_navigation_result_is_one_transfer",worker.take_result(queued.token,BINDING).status=="stale_token")
	var deadline := Time.get_ticks_msec()+5000
	while result.get("ready",false) and not result.get("batchComplete",false) and Time.get_ticks_msec()<deadline:
		envelope = result.get("navigationSource",{})
		taken = {}; result = {}
		if envelope.is_empty(): break
		queued = worker.dispatch_navigation(envelope,["0,0","1,0"],BINDING)
		envelope = {}
		await _completed(worker,"resume_next_owner_turn")
		taken = worker.take_result(queued.token,BINDING)
		result = taken.get("result",{})
	var receipts: Dictionary = result.get("tileReceipts",{})
	var complete: bool = result.get("ready",false) and result.get("batchComplete",false) and receipts.size()==2
	_check("resumed_real_producer_completes_exact_requested_tiles",complete)
	_check("navigation_result_is_one_transfer",worker.take_result(queued.token,BINDING).status=="stale_token")
	if complete:
		_check("completed_tile_artifacts_are_immutable_source_proofs",receipts.is_read_only()
			and receipts["0,0"].is_read_only() and receipts["1,0"].is_read_only()
			and not receipts["0,0"].outputPresent and not receipts["1,0"].outputPresent)
		_check("producer_identity_survives_owned_round_trip",result.navigationSource.producer.get_instance_id()==producer_id)
	else:
		_check("completed_tile_artifacts_are_immutable_source_proofs",false)
		_check("producer_identity_survives_owned_round_trip",false)
	var trace: Dictionary = worker.trace.snapshot()
	_check("all_producer_mutation_occurs_off_main",trace.advanceThreads.size()>=2
		and trace.advanceThreads.all(func(id: int): return id!=OS.get_thread_caller_id()))
	_check("completed_progress_has_no_pending_keys",result.get("batchProgress",{}).get("pendingTileKeys",["missing"]).is_empty()
		and result.get("batchProgress",{}).get("selectedTileKeys",[])==["0,0","1,0"])
	_check("external_producer_retirement_accepted",worker.retire_external_payload(taken))
	taken = {}; result = {}; receipts = {}
	await _drain(worker,"resume_retirement")
	_check("resumed_producer_last_alias_released_off_main",_off_main(worker.trace))
	worker.request_shutdown()
	await _drain(worker,"resume_shutdown",true)

func _elapsed_owner_yield() -> void:
	var worker := ControlledWorker.new()
	worker.defer_steps = 1
	worker.gate_on_call = 1
	var envelope: Dictionary = await _prepared_envelope(worker,"elapsed")
	if envelope.is_empty():
		worker.request_shutdown(); await _drain(worker,"elapsed_setup_failure",true); return
	var queued: Dictionary = worker.dispatch_navigation(envelope,["0,0"],BINDING)
	envelope = {}
	var entered: bool = await _wait_gate(worker,"elapsed_kernel")
	if not entered:
		worker.cancel(queued.token)
		worker.trace.resume.post()
		await _drain(worker,"elapsed_gate_failure")
		worker.request_shutdown(); await _drain(worker,"elapsed_gate_failure_shutdown",true); return
	# Deterministic semaphore observation: real elapsed time passes while this
	# deliberately controlled kernel is blocked. No sleep or producer clock stub.
	var release_at := Time.get_ticks_usec()+Worker.NAVIGATION_TURN_USEC
	while Time.get_ticks_usec()<release_at: await process_frame
	worker.trace.resume.post()
	await _completed(worker,"elapsed_owner_turn")
	var taken: Dictionary = worker.take_result(queued.token,BINDING)
	var result: Dictionary = taken.get("result",{})
	var progress: Dictionary = result.get("batchProgress",{})
	_check("elapsed_limit_returns_partial_before_second_kernel",result.get("ready",false) and not result.get("batchComplete",true)
		and result.get("tileReceipts",{}).is_empty() and progress.get("sliceCount")==1
		and progress.get("yieldReason")=="elapsed_turn_limit" and int(progress.get("turnElapsedUsec",0))>=Worker.NAVIGATION_TURN_USEC
		and worker.trace.snapshot().advanceThreads.size()==1)
	_check("elapsed_yield_keeps_source_for_owned_retirement",result.get("navigationSource",{}).get("producer") is Producer
		and worker.retire_external_payload(taken))
	taken = {}; result = {}
	await _drain(worker,"elapsed_retirement")
	_check("elapsed_source_last_alias_released_off_main",_off_main(worker.trace))
	worker.request_shutdown()
	await _drain(worker,"elapsed_shutdown",true)

func _nonempty_batch() -> void:
	var worker := ControlledWorker.new()
	worker.nonempty_fixture = true
	var envelope: Dictionary = await _prepared_envelope(worker,"nonempty")
	if envelope.is_empty():
		worker.request_shutdown(); await _drain(worker,"nonempty_setup_failure",true); return
	var producer_id: int = envelope.producer.get_instance_id()
	var queued: Dictionary = worker.dispatch_navigation(envelope,["30,0","2,0"],BINDING,["30,0","2,0"])
	envelope = {}
	await _completed(worker,"nonempty_batch")
	var taken: Dictionary = worker.take_result(queued.token,BINDING)
	var result: Dictionary = taken.get("result",{})
	var deadline := Time.get_ticks_msec()+5000
	while result.get("ready",false) and not result.get("batchComplete",false) and Time.get_ticks_msec()<deadline:
		envelope = result.get("navigationSource",{})
		taken = {}; result = {}
		if envelope.is_empty(): break
		queued = worker.dispatch_navigation(envelope,["30,0","2,0"],BINDING,["30,0","2,0"])
		envelope = {}
		await _completed(worker,"nonempty_next_owner_turn")
		taken = worker.take_result(queued.token,BINDING)
		result = taken.get("result",{})
	var receipts: Dictionary = result.get("tileReceipts",{})
	var expected: Dictionary = result.get("navigationSource",{}).get("expectedTiles",{})
	var complete: bool = result.get("ready",false) and result.get("batchComplete",false) and receipts.size()==2 \
		and receipts.has("2,0") and receipts.has("30,0") and expected.size()==2
	_check("nonempty_wrapper_returns_exact_selected_batch",complete and result.get("requestedTileKeys",[])==["2,0","30,0"])
	_check("nonempty_priority_order_keeps_canonical_receipt_order",complete and result.get("requestedTileOrder",[])==["30,0","2,0"]
		and receipts.keys()==["2,0","30,0"] and result.get("producerStatus",{}).get("activeTileKey","").is_empty())
	if complete:
		_check("nonempty_wrapper_exact_typed_tile_parity",ProducerFixture._digest(receipts["2,0"].tile)==ProducerFixture._digest(expected["2,0"])
			and ProducerFixture._digest(receipts["30,0"].tile)==ProducerFixture._digest(expected["30,0"]))
		_check("nonempty_wrapper_proves_present_geometry",receipts["2,0"].outputPresent and receipts["30,0"].outputPresent
			and receipts["2,0"].tile.surfaces.size()==2 and receipts["30,0"].tile.collisionRecords.size()==2
			and receipts["30,0"].tile.collisionRecords[0].id==receipts["30,0"].tile.collisionRecords[1].id)
		_check("nonempty_wrapper_preserves_frozen_identity",Producer._sealed(receipts)
			and result.navigationSource.producer.get_instance_id()==producer_id)
	else:
		_check("nonempty_wrapper_exact_typed_tile_parity",false)
		_check("nonempty_wrapper_proves_present_geometry",false)
		_check("nonempty_wrapper_preserves_frozen_identity",false)
	_check("nonempty_result_is_one_transfer",worker.take_result(queued.token,BINDING).status=="stale_token")
	var trace: Dictionary = worker.trace.snapshot()
	_check("nonempty_all_producer_mutation_off_main",not trace.advanceThreads.is_empty()
		and trace.advanceThreads.all(func(id: int): return id!=OS.get_thread_caller_id()))
	_check("nonempty_priority_is_actual_waiting_order",trace.get("firstAdvanceState",{}).get("waiting",[])==["30,0","2,0"]
		and trace.firstAdvanceState.get("eligible",[])==["2,0","30,0"])
	_check("nonempty_source_and_oracle_retire_together",worker.retire_external_payload(taken))
	taken = {}; result = {}; receipts = {}; expected = {}
	await _drain(worker,"nonempty_retirement")
	_check("nonempty_producer_last_alias_released_off_main",_off_main(worker.trace))
	worker.request_shutdown()
	await _drain(worker,"nonempty_shutdown",true)

func _active_priority_batch(omit_active: bool) -> void:
	var label := "active_omitted" if omit_active else "active_priority"
	var worker := ControlledWorker.new()
	worker.nonempty_fixture = true
	worker.prime_active_fixture = true
	var envelope: Dictionary = await _prepared_envelope(worker,label)
	if envelope.is_empty():
		worker.request_shutdown(); await _drain(worker,label+"_setup_failure",true); return
	var keys: Array[String] = ["31,0"]
	var order: Array[String] = ["31,0"]
	if not omit_active:
		keys.push_front("2,0")
		order.append("2,0")
	var queued: Dictionary = worker.dispatch_navigation(envelope,keys,BINDING,order)
	envelope = {}
	await _completed(worker,label+"_batch")
	var taken: Dictionary = worker.take_result(queued.token,BINDING)
	var result: Dictionary = taken.get("result",{})
	if omit_active:
		_check("omitted_active_output_rejected_before_any_kernel",not result.get("ready",true)
			and result.get("reason")=="navigation_active_output_not_selected" and worker.trace.snapshot().advanceThreads.is_empty())
		_check("omitted_active_source_released_off_main",_off_main(worker.trace))
	else:
		var deadline := Time.get_ticks_msec()+5000
		var coverage_valid := true
		while result.get("ready",false) and not result.get("batchComplete",false) and Time.get_ticks_msec()<deadline:
			var active := String(result.get("producerStatus",{}).get("activeTileKey",""))
			coverage_valid = coverage_valid and (active.is_empty() or keys.has(active))
			envelope = result.get("navigationSource",{})
			taken = {}; result = {}
			if envelope.is_empty(): break
			queued = worker.dispatch_navigation(envelope,keys,BINDING,order)
			envelope = {}
			await _completed(worker,label+"_next_turn")
			taken = worker.take_result(queued.token,BINDING)
			result = taken.get("result",{})
		var receipts: Dictionary = result.get("tileReceipts",{})
		var complete: bool = result.get("ready",false) and result.get("batchComplete",false) and receipts.keys()==["2,0","31,0"]
		_check("late_urgent_batch_retains_active_output_coverage",complete and coverage_valid
			and result.get("producerStatus",{}).get("activeTileKey","").is_empty()
			and result.get("producerStatus",{}).get("pendingRequestCount")==1)
		var observed: Dictionary = worker.trace.snapshot().firstAdvanceState
		_check("active_apron_job_precedes_reordered_waiting_output",observed.get("phase")=="sample" and observed.get("activeTileKey")=="2,0"
			and observed.get("waiting",[])==["31,0","30,0"] and observed.get("eligible",[])==["2,0","31,0"])
		if complete:
			_check("late_urgent_active_apron_exact_typed_output",ProducerFixture._digest(receipts["2,0"].tile)
				==ProducerFixture._digest(result.navigationSource.expectedTiles["2,0"]) and receipts["2,0"].outputPresent
				and receipts["31,0"].outputPresent and receipts["31,0"].tile.collisionRecords.size()==1)
		else: _check("late_urgent_active_apron_exact_typed_output",false)
		receipts = {}
		_check("active_priority_source_retirement_accepted",worker.retire_external_payload(taken))
	taken = {}; result = {}
	await _drain(worker,label+"_retirement")
	_check(label+"_last_alias_released_off_main",_off_main(worker.trace))
	worker.request_shutdown()
	await _drain(worker,label+"_shutdown",true)

func _cancellation(mode: String) -> void:
	var worker := ControlledWorker.new()
	var observed_thread: WeakRef
	worker.gate_advance = mode=="active"
	var envelope: Dictionary = await _prepared_envelope(worker,mode)
	if envelope.is_empty():
		worker.request_shutdown(); await _drain(worker,mode+"_setup_failure",true); return
	var queued: Dictionary = worker.dispatch_navigation(envelope,["0,0"],BINDING)
	envelope = {}
	if mode=="active":
		worker.poll()
		var deadline := Time.get_ticks_msec()+5000
		var entered: bool = worker.trace.entered.try_wait()
		while not entered and Time.get_ticks_msec()<deadline:
			await process_frame
			entered = worker.trace.entered.try_wait()
		_check("active_navigation_entered_owned_worker",entered)
		var held: Dictionary = worker.poll()
		var pending: Dictionary = worker.take_result(queued.token,BINDING)
		_check("running_kernel_keeps_source_without_result_transfer",entered and held.workerRunning
			and held.activeToken==queued.token and held.completedToken==0
			and pending.status=="pending" and not pending.has("result"))
		var held_timing: Dictionary = _timing_row(worker,queued.token)
		_check("timing_held_kernel_has_start_without_finish_or_join",held_timing.get("startedUsec",0)>=held_timing.get("queuedUsec",1)
			and held_timing.get("startedUsec",0)>0 and held_timing.get("finishedUsec",-1)==0
			and held_timing.get("joinedUsec",-1)==0 and held_timing.get("takenUsec",-1)==0)
	elif mode=="completed":
		await _completed(worker,"cancel_completed_slice")
	elif mode=="stale":
		worker.poll()
		observed_thread = _worker_thread_weak(worker)
		var deadline := Time.get_ticks_msec()+5000
		while _worker_thread_running(worker) and Time.get_ticks_msec()<deadline: await process_frame
		_check("stale_navigation_terminal_before_owner_reset",_worker_thread_terminal(worker))
		var terminal_timing: Dictionary = _timing_row(worker,queued.token)
		await process_frame # Deliberate owner collection delay; no sleep or poll.
		var delayed_timing: Dictionary = _timing_row(worker,queued.token)
		_check("timing_finished_worker_remains_unjoined_until_owner_poll",terminal_timing.get("finishedUsec",0)>0
			and delayed_timing.get("finishedUsec")==terminal_timing.finishedUsec and delayed_timing.get("joinedUsec",-1)==0
			and delayed_timing.get("takenUsec",-1)==0 and worker._completed.is_empty() and _worker_thread_terminal(worker))
	if mode=="stale": worker.reset()
	else: _check(mode+"_navigation_cancel_accepted",worker.cancel(queued.token))
	if mode=="active": worker.trace.resume.post()
	var drained: Dictionary = await _drain(worker,mode+"_navigation_retirement")
	var release_trace: Dictionary = worker.trace.snapshot()
	metrics[mode+"_release_observation"] = {
		"destructorThreadId":int(release_trace.get("freedOnThread",-1)),
		"mainThreadId":OS.get_thread_caller_id(),
		"advanceThreadIds":release_trace.advanceThreads,
		"inputReleaseThreadId":int(drained.get("lastInputReleaseThreadId",-1)),
		"retirementThreadId":int(drained.get("lastRetirementThreadId",-1)),
		"observedThreadCaptured":observed_thread!=null,
		"observedThreadAliveAfterDrain":_weak_thread_live(observed_thread)}
	_check(mode+"_producer_retired_off_main",_off_main(worker.trace))
	_check(mode+"_late_token_cannot_return_producer",worker.take_result(queued.token,BINDING).status=="stale_token")
	var cancelled_timing: Dictionary = _timing_row(worker,queued.token)
	var cancellation_order: bool = cancelled_timing.get("cancelRequestedUsec",0)>=cancelled_timing.get("queuedUsec",1) \
		and cancelled_timing.get("takenUsec",-1)==0
	if mode=="queued":
		cancellation_order = cancellation_order and cancelled_timing.get("startedUsec",-1)==0 \
			and cancelled_timing.get("joinedUsec",-1)==0 and cancelled_timing.get("disposition")=="cancelled_before_start"
	else:
		cancellation_order = cancellation_order and _joined_timing_order(cancelled_timing) \
			and cancelled_timing.get("disposition")==("discarded_stale" if mode=="stale" else ("cancelled_after_join" if mode=="completed" else "cancelled"))
	_check(mode+"_timing_preserves_cancelled_epoch_without_fake_take",cancellation_order
		and (cancelled_timing.epoch<worker.navigation_timing().epoch if mode=="stale" else cancelled_timing.epoch==worker.navigation_timing().epoch))
	metrics[mode+"_navigation_timing"] = worker.navigation_timing()
	worker.request_shutdown()
	await _drain(worker,mode+"_shutdown",true)

func _failed_starts() -> void:
	var worker := ControlledWorker.new()
	var envelope: Dictionary = await _prepared_envelope(worker,"failed_start")
	if envelope.is_empty():
		worker.request_shutdown(); await _drain(worker,"failed_start_setup_failure",true); return
	worker.fail_navigation_count = 1
	worker.fail_retirement_count = 1
	var queued: Dictionary = worker.dispatch_navigation(envelope,["0,0"],BINDING)
	envelope = {}
	var state: Dictionary = worker.poll()
	_check("navigation_start_failure_keeps_exclusive_producer",queued.status=="queued" and not state.workerRunning
		and state.preparationStartError==ERR_CANT_CREATE and state.progress.elapsedUsec==0 and worker.trace.snapshot().freedOnThread==-1)
	var failed_timing: Dictionary = _timing_row(worker,queued.token)
	_check("timing_failed_start_counts_attempt_without_execution",failed_timing.get("startAttempts")==1
		and failed_timing.get("lastStartError")==ERR_CANT_CREATE and failed_timing.get("startedUsec",-1)==0
		and failed_timing.get("finishedUsec",-1)==0 and failed_timing.get("joinedUsec",-1)==0)
	worker.request_shutdown()
	state = worker.poll()
	_check("retirement_start_failure_preserves_producer",not state.shutdownComplete and not state.workerRunning
		and state.retirementStartError==ERR_CANT_CREATE and worker.trace.snapshot().freedOnThread==-1)
	await _drain(worker,"failed_start_shutdown",true)
	_check("failed_start_producer_eventually_retires_off_main",_off_main(worker.trace))
	_check("timing_reset_of_failed_start_does_not_invent_worker_run",_timing_row(worker,queued.token).disposition=="reset_before_start"
		and worker.navigation_timing().aggregates.execution.count==0)

func _real_scene_source() -> void:
	var worker := Worker.new()
	var source: Dictionary = SourceFixture.source()
	var queued: Dictionary = worker.dispatch_scene_source(source,BINDING)
	_check("scene_mode_does_not_mutate_admitted_source",not source.has("demandedNavigation"))
	_check("full_prepare_cannot_alias_demanded_scene_mode",worker.dispatch(source,BINDING).status=="busy")
	await _completed(worker,"real_empty_scene_source")
	var taken: Dictionary = worker.take_result(queued.token,BINDING)
	var result: Dictionary = taken.get("result",{})
	var navigation: Dictionary = result.get("navigationSource",{})
	var valid: bool = result.get("ready",false) and result.get("prepared")!=null and navigation.get("producer") is Producer
	_check("real_scene_preparation_returns_separate_bound_producer",valid and navigation.is_read_only() and navigation.get("binding")==BINDING)
	if valid:
		var description = result.prepared.describe(BINDING)
		_check("scene_description_does_not_own_mutable_navigation_producer",description!=null and description.navigation_tiles.is_empty())
		description = null
	else: _check("scene_description_does_not_own_mutable_navigation_producer",false)
	_check("real_scene_and_producer_retire_together",worker.retire_external_payload(taken))
	taken = {}; result = {}; navigation = {}; source = {}
	worker.request_shutdown()
	await _drain(worker,"real_scene_shutdown",true)

func _fairness_manifest(owner: int, priority: int, query: Rect2i, keys: Array[String]) -> Dictionary:
	return {"ownerId":owner,"priority":priority,"bounds":query,
		"admissionKeys":Service.DemandSet.from_regions([query],28,256,32).keys.keys(),
		"navigationTileKeys":keys,"sites":[]}

func _timing_retention() -> void:
	var worker := ControlledWorker.new()
	var envelope: Dictionary = await _prepared_envelope(worker,"timing_retention")
	if envelope.is_empty():
		worker.request_shutdown(); await _drain(worker,"timing_retention_setup_failure",true); return
	worker.fail_navigation_count = 1
	var first_token := 0
	var last_token := 0
	var completed_count := 0
	var all_valid := true
	# The real empty producer emits once, then serves its exact retained output.
	# Each consumed dispatch is a real new owner turn; no synthetic history rows.
	for index: int in range(Worker.NAVIGATION_TIMING_HISTORY_LIMIT+1):
		var queued: Dictionary = worker.dispatch_navigation(envelope,["0,0"],BINDING)
		if queued.get("status")!="queued": all_valid=false; break
		if index==0: first_token = int(queued.token)
		all_valid = all_valid and int(queued.token)>last_token
		last_token = int(queued.token)
		envelope = {}
		await _completed(worker,"timing_retention_turn")
		var taken: Dictionary = worker.take_result(last_token,BINDING)
		var result: Dictionary = taken.get("result",{})
		all_valid = all_valid and result.get("ready",false) and result.get("batchComplete",false)
		if result.get("navigationSource") is Dictionary: envelope = result.navigationSource
		taken = {}; result = {}
		if not all_valid or envelope.is_empty(): break
		completed_count += 1
		if index==0:
			_check("timing_failed_start_retry_keeps_one_batch",_timing_row(worker,last_token).startAttempts==2
				and worker.navigation_timing().queuedCount==1 and _joined_timing_order(_timing_row(worker,last_token),true))
	var timing: Dictionary = worker.navigation_timing()
	_check("timing_history_is_bounded_by_real_completed_batches",all_valid and completed_count==Worker.NAVIGATION_TIMING_HISTORY_LIMIT+1
		and timing.history.size()==Worker.NAVIGATION_TIMING_HISTORY_LIMIT and timing.droppedCount==1
		and timing.queuedCount==completed_count and timing.history[0].token>first_token and timing.history.back().token==last_token
		and timing.history.all(func(row: Dictionary): return _joined_timing_order(row,true)))
	_check("timing_aggregates_include_evicted_rows",timing.aggregates.execution.count==completed_count
		and timing.aggregates.queuedToStarted.count==completed_count and timing.aggregates.finishedToJoined.count==completed_count
		and timing.aggregates.joinedToTaken.count==completed_count and _timing_values_only(timing))
	var prior_epoch: int = timing.epoch
	worker.reset()
	var reset_timing: Dictionary = worker.navigation_timing()
	_check("timing_reset_retains_epoch_tagged_history_and_totals",reset_timing.epoch==prior_epoch+1
		and reset_timing.history==timing.history and reset_timing.aggregates==timing.aggregates
		and reset_timing.active.is_empty() and reset_timing.queuedCount==timing.queuedCount)
	metrics["navigationTimingRetention"] = reset_timing
	_check("timing_retention_source_retirement_accepted",worker.retire_external_payload(envelope))
	envelope = {}
	await _drain(worker,"timing_retention_disposal")
	_check("timing_history_does_not_retain_the_producer",_off_main(worker.trace))
	worker.request_shutdown()
	await _drain(worker,"timing_retention_shutdown",true)

func _fairness_service_turn(service, ready: Dictionary, label: String) -> Dictionary:
	service._dispatch(ready,Vector2i.ZERO)
	var work: Dictionary = service._inflight.duplicate(true) # Binding/selection scalars only.
	var admitted: bool = work.get("kind")=="navigation" and work.get("token",0)>0
	_check(label+"_real_service_dispatch",admitted)
	if not admitted: return {"valid":false,"order":[]}
	var keys: Array = work.get("tileKeys",[])
	var order: Array = work.get("tileOrder",[])
	var sorted: Array = order.duplicate()
	sorted.sort()
	var coverage: bool = keys.size()<=Worker.MAX_NAVIGATION_BATCH_TILES and keys==sorted and keys.size()==order.size()
	service._last_worker_status = await _completed(service._worker,label)
	service._collect(ready,true)
	var valid: bool = coverage and service._inflight.is_empty() and service._failures.is_empty()
	_check(label+"_real_service_collect",valid)
	return {"valid":valid,"order":order,"dispatchTurn":service._dispatch_turn}

func _fairness_shutdown(service, worker) -> void:
	worker.trace.hold_service_progress(false)
	service.request_shutdown()
	var deadline := Time.get_ticks_msec()+5000
	var state: Dictionary = service.advance()
	while not state.get("shutdownComplete",false) and Time.get_ticks_msec()<deadline:
		await process_frame
		state = service.advance()
	_check("service_fairness_shutdown_drains_owner",state.get("shutdownComplete",false)
		and service._navigation.is_empty() and not worker.has_pending_work())
	_check("service_fairness_producer_released_off_main",_off_main(worker.trace))
	metrics["serviceFairnessShutdown"] = state

func _actual_start_fairness() -> void:
	# Real Service -> Worker -> Producer. Only admission and the duration of an
	# already active job are synthetic; receipts use the unchanged real sampler.
	var worker := ControlledWorker.new()
	worker.nonempty_fixture = true
	worker.prime_active_fixture = true
	var admission := SyntheticFairnessAdmission.new()
	var service := Service.new()
	service._worker = worker
	service.configure(admission)
	var envelope: Dictionary = await _prepared_envelope(worker,"service_fairness")
	if envelope.is_empty():
		await _fairness_shutdown(service,worker)
		return
	var expected_cold: Dictionary = envelope.get("expectedTiles",{}).get("30,0",{})
	var expected_active: Dictionary = envelope.get("expectedTiles",{}).get("2,0",{})
	var valid_source: bool = not expected_cold.is_empty() and not expected_active.is_empty() \
		and envelope.get("domain") is Dictionary and envelope.domain.get("status")=="complete"
	_check("service_fairness_real_nonempty_oracle",valid_source)
	if not valid_source:
		_check("service_fairness_failed_setup_retires_source",worker.retire_external_payload(envelope))
		envelope = {}
		await _fairness_shutdown(service,worker)
		return
	var region := Vector2i.ZERO
	var source := {"status":"ready","binding":BINDING,"reservationCells":Rect2i(0,0,1024,1024)}
	var ready := {region:source}
	admission.states = ready
	var entry := {"binding":envelope.binding,"domain":envelope.domain,"navigationSource":envelope,
		"requested":{},"receipts":{},"activeTileKey":"2,0","producerProgress":{}}
	service._navigation[region] = entry
	service._prepared[region] = {"binding":BINDING} # Named synthetic resident marker; no scene holder.
	envelope = {}
	var hot_keys: Array[String] = ["2,0"]
	var requests_valid: bool = service._request_navigation_tile(entry,"2,0") and service._request_navigation_tile(entry,"30,0")
	for x: int in range(31,41):
		var key := "%d,0" % x
		hot_keys.append(key)
		requests_valid = service._request_navigation_tile(entry,key) and requests_valid
	var hot: Dictionary = _fairness_manifest(1,0,Rect2i(32,0,1,1),hot_keys)
	var cold: Dictionary = _fairness_manifest(2,0,Rect2i(480,0,1,1),["30,0"])
	var pending_identity: Dictionary = entry.requested["30,0"].duplicate()
	var promoted: bool = service.set_retained_source_requests([hot,cold]) and service._navigation_priority("30,0")==0
	cold.priority = 4
	var demoted: bool = service.set_retained_source_requests([hot,cold]) and service._navigation_priority("30,0")==4
	var released: bool = service.set_retained_source_requests([hot]) and service._navigation_priority("30,0")==4
	var repeated: bool = service._request_navigation_tile(entry,"30,0")
	_check("service_fairness_priority_changes_preserve_pending_age",requests_valid and promoted and demoted and released and repeated
		and entry.requested["30,0"]==pending_identity and entry.requested.size()==12)
	if not requests_valid or not promoted or not demoted or not released:
		entry = {}
		await _fairness_shutdown(service,worker)
		return
	worker.trace.hold_service_progress(true)
	var observed: Array[Dictionary] = []
	var offered := false
	var held_valid := true
	# Four policy quanta age default4 to0. The cold request is older than every
	# hot waiter; selection alone must not erase that credit before active ends.
	for _turn: int in range(4*Service.PRIORITY_AGING_DISPATCH_TURNS+1):
		var result: Dictionary = await _fairness_service_turn(service,ready,"service_fairness_held")
		observed.append(result)
		held_valid = held_valid and result.valid and entry.activeTileKey=="2,0" and entry.receipts.is_empty()
		if not held_valid: break
		if result.order.has("30,0"):
			offered = true
			break
	var cold_after_offer: Dictionary = entry.requested.get("30,0",{})
	_check("service_fairness_cold_selected_while_active_cannot_progress",held_valid and offered
		and cold_after_offer.get("firstPendingTurn",-1)==pending_identity.get("firstPendingTurn",-2)
		and int(cold_after_offer.get("lastDispatchTurn",-1))==service._dispatch_turn)
	metrics["serviceFairnessHeldTurns"] = observed
	if not held_valid or not offered:
		entry = {}
		await _fairness_shutdown(service,worker)
		return
	# The old selection-age comparator ranks all ten hot waiters before cold
	# immediately after this offer. The next real dispatch below must retain it.
	var old_hot_predecessors := 0
	for key: String in hot_keys:
		if key!="2,0" and service._schedule_before(0,entry.requested[key],4,entry.requested["30,0"]): old_hot_predecessors += 1
	_check("service_fairness_fixture_exposes_selection_age_counterexample",offered and old_hot_predecessors>Worker.MAX_NAVIGATION_BATCH_TILES)
	worker.trace.hold_service_progress(false)
	var deadline := Time.get_ticks_msec()+5000
	var completed := false
	var progressed_valid: bool = held_valid and offered
	var continuation_count := 0
	while progressed_valid and Time.get_ticks_msec()<deadline and continuation_count<64:
		var result: Dictionary = await _fairness_service_turn(service,ready,"service_fairness_released")
		continuation_count += 1
		progressed_valid = result.valid and result.order.has("30,0")
		if entry.receipts.has("30,0"):
			completed = true
			break
	_check("service_fairness_cold_gets_real_receipt_after_active_release",progressed_valid and completed
		and entry.receipts.has("2,0") and not entry.requested.has("30,0"))
	var exact := false
	if completed and entry.receipts.has("2,0"):
		exact = entry.receipts["30,0"].outputPresent and entry.receipts["2,0"].outputPresent \
			and ProducerFixture._digest(entry.receipts["30,0"].tile)==ProducerFixture._digest(expected_cold) \
			and ProducerFixture._digest(entry.receipts["2,0"].tile)==ProducerFixture._digest(expected_active)
	_check("service_fairness_keeps_exact_cold_and_active_geometry",exact)
	var before_completed_query: int = entry.requested.size()
	_check("service_fairness_completed_query_does_not_requeue",completed and service._request_navigation_tile(entry,"30,0")
		and not entry.requested.has("30,0") and entry.requested.size()==before_completed_query)
	metrics["serviceFairnessProgress"] = {"continuationsAfterRelease":continuation_count,
		"oldPolicyHotPredecessors":old_hot_predecessors,"sourceScheduling":service.stats().sourceScheduling,
		"scope":"synthetic long-active duration; real service dispatch, worker ownership and ordered sampler receipts"}
	entry = {}
	await _fairness_shutdown(service,worker)

func _run() -> void:
	await _resumable_batch()
	await _elapsed_owner_yield()
	await _nonempty_batch()
	await _active_priority_batch(false)
	await _active_priority_batch(true)
	for mode: String in ["queued","active","completed","stale"]: await _cancellation(mode)
	await _failed_starts()
	await _real_scene_source()
	await _actual_start_fairness()
	await _timing_retention()
	var report := {"schema":"building-navigation-worker-contract/v1","complete":true,"passed":not checks.values().has(false),
		"checks":checks,"metrics":metrics,"evidenceLevel":"synthetic_worker_ownership_with_real_empty_and_nonempty_source_proofs",
		"doesNotProve":"No full citadel geometry, source parity, live installation acknowledgements, gameplay movement or runtime performance."}
	var file := FileAccess.open(OS.get_environment("BUILDING_NAVIGATION_WORKER_REPORT"),FileAccess.WRITE)
	if file==null:
		push_error("Cannot write navigation worker contract report")
		quit(2)
		return
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	print("NAVIGATION WORKER CONTRACT COMPLETE ",JSON.stringify({"passed":report.passed,"checks":checks.size()}))
	quit(0 if report.passed else 1)
