extends RefCounted
class_name BuildingPublicationWorker

## One main-thread owner, one worker shared by preparation and retirement.
## dispatch/retire only retain ownership; poll starts work on a later owner call.
## The controller retains demand when busy and keeps polling through shutdown.
## Inputs come from Admission's deeply frozen source, never scene objects.
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const NavigationProducer = preload("res://scripts/buildings/BuildingNavigationTileProducer.gd")
const MAX_NAVIGATION_BATCH_TILES := 8
const NAVIGATION_BATCH_USEC := 8000
# A finite worker turn amortizes main-owner handoffs while still checking
# cancellation between every producer kernel. These are separate from the
# eight TILE limit. A headed citadel capture measured about 65 ms of work per
# old turn but 1-2 s at each owner boundary, so the previous 64 ms cap spent
# most of its time waiting to resume an unchanged active tile.
const MAX_NAVIGATION_KERNEL_STEPS := 64
const NAVIGATION_TURN_USEC := 512000
const NAVIGATION_TIMING_HISTORY_LIMIT := 64

class RunState extends RefCounted:
	var kind := "preparation"
	var source: Dictionary = {}
	var navigation_source: Dictionary = {}
	var packet_base: Preparation.PreparedPublicationBase
	var packet_group_ids: Array[String] = []
	var tile_keys: Array[String] = []
	var tile_order: Array[String] = []
	var binding: Dictionary = {}
	var mutex := Mutex.new()
	var cancelled := false
	var stage := "queued"
	var stage_count := 0
	var started_usec := 0
	var finished_usec := 0
	var work_thread_id := -1
	var previous_usec := 0
	var max_stage_gap_usec := 0
	var released_on_thread := -1
	var input_release_usec := 0
	var phase := "restore"
	var phase_started_usec := 0
	var phase_usec: Dictionary = {}
	var description
	var description_profile: Dictionary = {}
	var navigation_progress: Dictionary = {}
	func publish_description(value) -> bool:
		mutex.lock()
		var accepted: bool = not cancelled and description == null and value != null and value.binding == binding
		if accepted:
			description = value
			description_profile = source.profile
		mutex.unlock()
		return accepted
	func take_description() -> Dictionary:
		mutex.lock()
		var result := {}
		if not cancelled and description != null:
			result = {"description":description,"profile":description_profile}
			description = null
			description_profile = {}
		mutex.unlock()
		return result
	func release_description() -> void:
		mutex.lock()
		description = null
		description_profile = {}
		mutex.unlock()
	func begin_work() -> void:
		mutex.lock()
		started_usec = Time.get_ticks_usec()
		work_thread_id = OS.get_thread_caller_id()
		previous_usec = started_usec
		max_stage_gap_usec = 0
		stage_count = 0
		phase = "restore"
		phase_started_usec = started_usec
		phase_usec.clear()
		mutex.unlock()
	func finish_work() -> void:
		mutex.lock()
		finished_usec = Time.get_ticks_usec()
		mutex.unlock()
	func work_timing_snapshot() -> Dictionary:
		mutex.lock()
		var value := {"startedUsec":started_usec,"finishedUsec":finished_usec,"threadId":work_thread_id}
		mutex.unlock()
		return value
	func cancel() -> void:
		mutex.lock()
		cancelled = true
		mutex.unlock()
	func is_cancelled() -> bool:
		mutex.lock()
		var value := cancelled
		mutex.unlock()
		return value
	func advance(next_stage: String) -> bool:
		mutex.lock()
		if cancelled:
			mutex.unlock()
			return false
		var now := Time.get_ticks_usec()
		max_stage_gap_usec = maxi(max_stage_gap_usec, now - previous_usec)
		previous_usec = now
		# Aggregate preparation phases, with no per-part records or snapshots.
		if next_stage != stage:
			var next_phase := phase
			match next_stage:
				"navigation_batch_started": next_phase = "dense_navigation"
				"navigation_batch_completed": next_phase = "ready"
				"publication_route_started": next_phase = "route_geometry"
				"publication_route_completed": next_phase = "physical"
				"publication_physical_completed": next_phase = "metadata"
				"publication_metadata_started": next_phase = "metadata"
				"publication_history_started": next_phase = "history"
				"publication_masonry_started": next_phase = "masonry"
				"publication_paving_started": next_phase = "paving"
				"publication_roof_started": next_phase = "roof"
				"publication_spatial_part": next_phase = "spatial_dependencies"
				"publication_navigation_manifest": next_phase = "navigation_manifest"
				"publication_navigation_dense_started": next_phase = "dense_navigation"
				"publication_preparation_ready": next_phase = "ready"
			if next_phase != phase:
				phase_usec[phase] = now - phase_started_usec
				phase = next_phase
				phase_started_usec = now
		stage = next_stage.left(160)
		stage_count += 1
		mutex.unlock()
		return true
	# Only bounded scalar progress crosses the mutex. The owner never accesses
	# the mutable producer, its dependency cursors or emitted source geometry.
	func record_navigation_progress(progress: Dictionary, pending_keys: Array[String], advance_usec := -1) -> void:
		var selected := tile_keys.duplicate()
		var order := tile_order.duplicate()
		var pending := pending_keys.duplicate()
		selected.make_read_only()
		order.make_read_only()
		pending.make_read_only()
		mutex.lock()
		navigation_progress = {"selectedTileKeys":selected,"selectedTileOrder":order,"pendingTileKeys":pending,
			"sliceCount":int(navigation_progress.get("sliceCount",0))+(1 if advance_usec>=0 else 0),
			"advanceElapsedUsec":int(navigation_progress.get("advanceElapsedUsec",0))+maxi(0,advance_usec),
			"maxAdvanceElapsedUsec":maxi(int(navigation_progress.get("maxAdvanceElapsedUsec",0)),advance_usec),
			"producerPhase":String(progress.get("phase","")).left(64),
			"activeTileKey":String(progress.get("activeTileKey","")).left(23),
			"producerPendingCount":int(progress.get("pendingRequestCount",0)),
			"completedTileCount":int(progress.get("completedTileCount",0)),
			"compiledProducerCount":int(progress.get("compiledProducerCount",0)),
			"sampleCount":int(progress.get("sampleCount",0)),
			"surfaceCount":int(progress.get("surfaceCount",0)),
			"preparationUsec":int(progress.get("preparationUsec",0)),
			"preparationTimeScope":"producer_begin_and_advance_wall",
			"workerThreadId":OS.get_thread_caller_id()}
		mutex.unlock()
	func navigation_snapshot() -> Dictionary:
		mutex.lock()
		var value := navigation_progress.duplicate(true)
		mutex.unlock()
		return value
	func snapshot() -> Dictionary:
		mutex.lock()
		var value := {"stage":stage, "stageCount":stage_count, "cancelRequested":cancelled,
			"descriptionAvailable":description != null,
			"elapsedUsec":Time.get_ticks_usec()-started_usec if started_usec > 0 else 0, "maxStageGapUsec":max_stage_gap_usec}
		value.phaseUsec = phase_usec.duplicate()
		value.navigation = navigation_progress.duplicate(true)
		if started_usec > 0 and phase != "ready": value.phaseUsec[phase] = Time.get_ticks_usec()-phase_started_usec
		mutex.unlock()
		return value

class RetirementState extends RefCounted:
	var payload: Dictionary = {}
	var transferred := Semaphore.new()
	var released_on_thread := -1
	func release_payload() -> int:
		transferred.wait()
		var started := Time.get_ticks_usec()
		# The bound callable may live until owner-side join. Empty its holder HERE.
		payload = {}
		released_on_thread = OS.get_thread_caller_id()
		return Time.get_ticks_usec() - started

var _epoch := 1
var _next_token := 1
var _active: Dictionary = {} # Small identity only; never source/input aliases.
var _completed: Dictionary = {}
var _state: RunState
var _thread: Thread
var _retired: Dictionary = {}
var _retirement: RetirementState
var _closing := false
var _preparation_start_error := OK
var _retirement_start_error := OK
var _discarded_stale := 0
var _max_poll_usec := 0
var _max_join_usec := 0
var _max_dispatch_usec := 0
var _max_retirement_usec := 0
var _max_input_release_usec := 0
var _last_retirement_thread := -1
var _last_input_release_thread := -1
var _last_navigation_batch: Dictionary = {}
var _navigation_timing_history: Array[Dictionary] = []
var _navigation_timing_queued := 0
var _navigation_timing_dropped := 0
var _navigation_timing_aggregates: Dictionary = {
	"queuedToStarted":{"count":0,"totalUsec":0,"maxUsec":0},
	"execution":{"count":0,"totalUsec":0,"maxUsec":0},
	"finishedToJoined":{"count":0,"totalUsec":0,"maxUsec":0},
	"joinedToTaken":{"count":0,"totalUsec":0,"maxUsec":0}}

func dispatch(source: Dictionary, binding: Dictionary) -> Dictionary:
	var started := Time.get_ticks_usec()
	# Capture the three scalar identity fields before callbacks or worker work.
	var captured := binding.duplicate()
	if not Preparation.valid_binding(captured): return _rejected("failed", "invalid_publication_binding")
	captured.make_read_only()
	if _closing: return _rejected("failed", "shutting_down")
	for entry: Dictionary in [_active, _completed]:
		if entry.get("kind") == "preparation" and entry.get("epoch",0) == _epoch and entry.get("binding",{}) == captured \
				and entry.get("demandedNavigation",false) == bool(source.get("demandedNavigation",false)) and not entry.get("cancelled",false):
			var duplicate := _receipt(entry, "queued")
			duplicate["duplicate"] = true
			return duplicate
	if _thread != null or _state != null or not _active.is_empty() or not _completed.is_empty() or not _retired.is_empty():
		return _rejected("busy", "publication_worker_busy")
	# Admission owns full recursive freezing/validation. These constant-work
	# checks reject mutable envelopes without scanning/hashing source on main.
	var source_error := _source_validation_failure(source)
	if not source_error.is_empty(): return _rejected("failed", source_error)
	_state = RunState.new()
	_state.source = source
	_state.binding = captured
	_active = {"kind":"preparation", "token":_next_token, "epoch":_epoch, "binding":captured, "cancelled":false,
		"demandedNavigation":bool(source.get("demandedNavigation",false))}
	_next_token += 1
	_preparation_start_error = OK
	_max_dispatch_usec = maxi(_max_dispatch_usec, Time.get_ticks_usec()-started)
	return _receipt(_active, "queued")

## Runtime scene preparation builds a bound producer instead of draining all
## dense tiles. Existing dispatch/virtual preparation hooks remain unchanged.
func dispatch_scene_source(source: Dictionary, binding: Dictionary) -> Dictionary:
	var source_error := _source_validation_failure(source)
	if not source_error.is_empty(): return _rejected("failed",source_error)
	var envelope := source.duplicate(false)
	envelope["demandedNavigation"] = true
	envelope.make_read_only()
	return dispatch(envelope,binding)


## Produce only the immutable source/dependency prerequisite for a later
## demand-bound physical packet. This is deliberately a separate worker kind:
## a base is not a PreparedSource and cannot be passed to legacy publication.
func dispatch_publication_base(source: Dictionary, binding: Dictionary) -> Dictionary:
	var captured := binding.duplicate()
	if not Preparation.valid_binding(captured): return _rejected("failed","invalid_publication_binding")
	captured.make_read_only()
	if _closing: return _rejected("failed","shutting_down")
	var source_error := _source_validation_failure(source)
	if not source_error.is_empty(): return _rejected("failed",source_error)
	for entry: Dictionary in [_active,_completed]:
		if entry.get("kind")=="publication_base" and entry.get("epoch",0)==_epoch and entry.get("binding",{})==captured and not entry.get("cancelled",false):
			var duplicate := _receipt(entry,"queued")
			duplicate["duplicate"] = true
			return duplicate
	if _thread != null or _state != null or not _active.is_empty() or not _completed.is_empty() or not _retired.is_empty():
		return _rejected("busy","publication_worker_busy")
	_state=RunState.new()
	_state.kind="publication_base"
	_state.source=source
	_state.binding=captured
	_active={"kind":"publication_base","token":_next_token,"epoch":_epoch,"binding":captured,"cancelled":false}
	_next_token+=1
	_preparation_start_error=OK
	return _receipt(_active,"queued")


## Compile exactly one already-selected group closure. The immutable base stays
## read-only throughout; this worker reconstructs its own source graph and
## returns value-keyed geometry only. It has no scene/publication meaning.
func dispatch_physical_group_packet(base: Preparation.PreparedPublicationBase, group_ids: Array[String], binding: Dictionary) -> Dictionary:
	var captured := binding.duplicate()
	if not Preparation.valid_binding(captured): return _rejected("failed","invalid_publication_binding")
	captured.make_read_only()
	if _closing: return _rejected("failed","shutting_down")
	if base==null or not base.matches(captured): return _rejected("failed","invalid_publication_base")
	var ordered: Array[String]=group_ids.duplicate()
	ordered.sort()
	if ordered.is_empty() or ordered!=group_ids: return _rejected("failed","invalid_physical_group_ids")
	for group_id: String in ordered:
		if group_id.is_empty() or not base.description.publication_groups.groups.has(group_id): return _rejected("failed","invalid_physical_group_ids")
	if _thread != null or _state != null or not _active.is_empty() or not _completed.is_empty() or not _retired.is_empty():
		return _rejected("busy","publication_worker_busy")
	ordered.make_read_only()
	_state=RunState.new()
	_state.kind="physical_group_packet"
	_state.packet_base=base
	_state.packet_group_ids=ordered
	_state.binding=captured
	_active={"kind":"physical_group_packet","token":_next_token,"epoch":_epoch,"binding":captured,
		"groupIds":ordered,"cancelled":false}
	_next_token+=1
	_preparation_start_error=OK
	return _receipt(_active,"queued")


## Build the navigation producer from an already admitted base description.
## This keeps navigation authoritative when physical groups move to packet mode
## without re-entering legacy whole-source scene preparation.
func dispatch_publication_base_navigation(base: Preparation.PreparedPublicationBase, binding: Dictionary) -> Dictionary:
	var captured := binding.duplicate()
	if not Preparation.valid_binding(captured): return _rejected("failed","invalid_publication_binding")
	captured.make_read_only()
	if _closing: return _rejected("failed","shutting_down")
	if base == null or not base.matches(captured): return _rejected("failed","invalid_publication_base")
	if _thread != null or _state != null or not _active.is_empty() or not _completed.is_empty() or not _retired.is_empty():
		return _rejected("busy","publication_worker_busy")
	_state=RunState.new()
	_state.kind="publication_base_navigation"
	_state.packet_base=base
	_state.binding=captured
	_active={"kind":"publication_base_navigation","token":_next_token,"epoch":_epoch,"binding":captured,"cancelled":false}
	_next_token+=1
	_preparation_start_error=OK
	return _receipt(_active,"queued")

## On queued, the caller relinquishes ALL aliases to navigation_source and its
## mutable producer before poll. A busy/failed receipt leaves ownership there.
## The frozen association originates at Preparation, separately from the scene
## holder; only this existing worker may mutate the transferred producer.
func dispatch_navigation(navigation_source: Dictionary, tile_keys: Array[String], binding: Dictionary, dispatch_order: Array[String] = []) -> Dictionary:
	var started := Time.get_ticks_usec()
	var captured := binding.duplicate()
	if not Preparation.valid_binding(captured): return _rejected("failed","invalid_publication_binding")
	captured.make_read_only()
	if _closing: return _rejected("failed","shutting_down")
	var keys := _navigation_batch_keys(tile_keys)
	if keys.is_empty(): return _rejected("failed","invalid_navigation_batch_tiles")
	var order := _navigation_batch_order(keys,dispatch_order)
	if order.is_empty(): return _rejected("failed","invalid_navigation_batch_order")
	if not navigation_source.is_read_only() or not navigation_source.get("binding") is Dictionary \
			or not navigation_source.binding.is_read_only() or navigation_source.binding != captured \
			or not navigation_source.get("producer") is NavigationProducer:
		return _rejected("failed","invalid_navigation_producer_binding")
	# Read immutable association/object identity only; never inspect producer
	# progress while an earlier accepted dispatch might be mutating it.
	var producer_id: int = navigation_source.producer.get_instance_id()
	for entry: Dictionary in [_active,_completed]:
		if entry.get("kind") == "navigation" and entry.get("epoch",0) == _epoch and entry.get("binding",{}) == captured \
				and entry.get("producerId",0) == producer_id and entry.get("tileKeys",[]) == keys and not entry.get("cancelled",false):
			var duplicate := _receipt(entry,"queued")
			duplicate["duplicate"] = true
			return duplicate
	if _thread != null or _state != null or not _active.is_empty() or not _completed.is_empty() or not _retired.is_empty():
		return _rejected("busy","publication_worker_busy")
	keys.make_read_only()
	order.make_read_only()
	_state = RunState.new()
	_state.kind = "navigation"
	_state.navigation_source = navigation_source
	_state.tile_keys = keys
	_state.tile_order = order
	_state.binding = captured
	_active = {"kind":"navigation","token":_next_token,"epoch":_epoch,"binding":captured,
		"cancelled":false,"producerId":producer_id,"tileKeys":keys,"tileOrder":order}
	_navigation_timing_begin(_active)
	_next_token += 1
	_preparation_start_error = OK
	_max_dispatch_usec = maxi(_max_dispatch_usec,Time.get_ticks_usec()-started)
	return _receipt(_active,"queued")

static func _navigation_batch_keys(tile_keys: Array[String]) -> Array[String]:
	var result: Array[String] = []
	if tile_keys.is_empty() or tile_keys.size()>MAX_NAVIGATION_BATCH_TILES: return result
	for key: String in tile_keys:
		if key.length()>23: return []
		var coordinates := key.split(",",true)
		if coordinates.size()!=2 or not coordinates[0].is_valid_int() or not coordinates[1].is_valid_int(): return []
		var x := int(coordinates[0])
		var z := int(coordinates[1])
		if x < -2147483648 or x > 2147483647 or z < -2147483648 or z > 2147483647 or key!="%d,%d" % [x,z]: return []
		if not result.has(key): result.append(key)
	result.sort()
	return result

static func _navigation_batch_order(keys: Array[String], dispatch_order: Array[String]) -> Array[String]:
	if dispatch_order.is_empty(): return keys.duplicate()
	if dispatch_order.size()!=keys.size(): return []
	var result: Array[String] = []
	for key: String in dispatch_order:
		if not keys.has(key) or result.has(key): return []
		result.append(key)
	return result

func poll() -> Dictionary:
	var started := Time.get_ticks_usec()
	var joined := false
	if _thread != null and not _thread.is_alive():
		var join_started := Time.get_ticks_usec()
		var result: Variant = _thread.wait_to_finish()
		var joined_usec := Time.get_ticks_usec()
		_max_join_usec = maxi(_max_join_usec, joined_usec-join_started)
		_thread = null
		joined = true
		if _active.get("kind") == "retirement":
			_max_retirement_usec = maxi(_max_retirement_usec, int(result))
			_last_retirement_thread = _retirement.released_on_thread
			_retirement = null
		else:
			if _active.get("kind")=="navigation":
				_last_navigation_batch = {"token":_active.token,"epoch":_active.epoch,
					"binding":_active.binding.duplicate(),"progress":_state.navigation_snapshot()}
				_navigation_timing_join(_active,_state,joined_usec)
			_last_input_release_thread = _state.released_on_thread
			_max_input_release_usec = maxi(_max_input_release_usec, _state.input_release_usec)
			if _active.epoch != _epoch or _closing:
				if result is Dictionary: _queue_retirement(result)
				_discarded_stale += 1
			elif _active.cancelled or _state.is_cancelled():
				if result is Dictionary: _queue_retirement(result)
				# Departure forgets its token. Do not leave a cancelled completion
				# blocking the next demand when nobody will call take_result.
			elif result is Dictionary:
				_store_completed(result)
			else:
				_store_completed(_failed("invalid_worker_return"), false)
		# Drop the join-local alias BEFORE starting the retirement worker.
		result = null
		_active = {}
		_state = null
	if _thread == null and not _retired.is_empty():
		_start_retirement()
	elif _thread == null and _state != null and _completed.is_empty() and not _closing:
		_thread = Thread.new()
		# Only RunState is bound; _run empties its source on the worker before
		# returning. Never bind source or its nested snapshots into this callable.
		if _active.get("kind")=="navigation": _active.navigationTiming.startAttempts += 1
		_preparation_start_error = _start_thread(_run.bind(_state))
		if _active.get("kind")=="navigation": _active.navigationTiming.lastStartError = _preparation_start_error
		if _preparation_start_error != OK:
			_thread = null # Retain state/input for retry or worker retirement.
	_max_poll_usec = maxi(_max_poll_usec, Time.get_ticks_usec()-started)
	var completed_result: Dictionary = _completed.get("result",{})
	var completed_status := ""
	if not _completed.is_empty():
		completed_status = "ready" if completed_result.get("ready",false) else ("cancelled" if completed_result.get("reason") == "cancelled" else "failed")
	return {"epoch":_epoch, "workerRunning":_thread != null, "workerJoined":joined,
		"workerKind":_active.get("kind", ""), "activeToken":_active.get("token",0),
		"completedToken":_completed.get("token",0), "completedStatus":completed_status,
		"busy":_thread != null or _state != null or not _completed.is_empty() or not _retired.is_empty(),
		"progress":_state.snapshot() if _state != null else {},
		"lastNavigationBatch":_last_navigation_batch.duplicate(true),
		"shutdownComplete":_closing and _thread == null and _state == null and _active.is_empty() and _completed.is_empty() and _retired.is_empty() and _retirement == null,
		"retirementPending":not _retired.is_empty() or _retirement != null,
		"preparationStartError":_preparation_start_error, "retirementStartError":_retirement_start_error,
		"maxPollUsec":_max_poll_usec, "maxJoinUsec":_max_join_usec, "maxDispatchUsec":_max_dispatch_usec,
		"maxRetirementWorkUsec":_max_retirement_usec, "lastRetirementThreadId":_last_retirement_thread,
		"maxInputReleaseUsec":_max_input_release_usec, "lastInputReleaseThreadId":_last_input_release_thread,
		"discardedStale":_discarded_stale}

func take_result(token: int, expected_binding: Dictionary) -> Dictionary:
	if not _completed.is_empty() and _completed.token == token and _completed.epoch == _epoch and _completed.binding == expected_binding:
		if _completed.get("kind")=="navigation":
			var timing: Dictionary = _completed.navigationTiming
			timing.takenUsec = Time.get_ticks_usec()
			timing.disposition = "taken"
			_navigation_timing_add("joinedToTaken",timing.joinedUsec,timing.takenUsec)
		var receipt := _receipt(_completed, "consumed")
		receipt["result"] = _completed.result
		_completed = {}
		return receipt
	if _active.get("kind") in ["preparation","navigation"] and _active.get("token",0) == token and _active.epoch == _epoch and _active.binding == expected_binding:
		return _receipt(_active, "pending")
	return _rejected("stale_token", "token_or_binding_mismatch")

## Transfer an immutable phase-boundary product while preparation continues.
## This does not wait/join, copy source geometry or acknowledge publication.
func take_description(token: int, expected_binding: Dictionary) -> Dictionary:
	if _active.get("kind") == "preparation" and _active.get("token",0) == token \
		and _active.epoch == _epoch and _active.binding == expected_binding and not _active.cancelled and not _closing:
		var result := _state.take_description()
		if not result.is_empty():
			_active["descriptionTaken"] = true
			result.merge(_receipt(_active,"described"))
			return result
	if _completed.get("kind") == "preparation" and _completed.get("token",0) == token and _completed.get("epoch",0) == _epoch \
		and _completed.get("binding",{}) == expected_binding and not _completed.get("cancelled",false) \
		and not _completed.get("descriptionTaken",false) and not _closing:
		var result: Dictionary = _completed.get("result",{})
		if result.get("ready",false) and result.get("description") != null:
			_completed["descriptionTaken"] = true
			return {"status":"described","token":token,"binding":expected_binding,"description":result.description,"profile":result.profile}
	return _rejected("pending","description_not_available")

func cancel(token: int) -> bool:
	if _active.get("kind") in ["preparation","publication_base","physical_group_packet","publication_base_navigation","navigation"] and _active.get("token",0) == token and _active.epoch == _epoch:
		_navigation_timing_cancel(_active,"cancel_requested" if _thread!=null else "cancelled_before_start")
		_active.cancelled = true
		_state.cancel()
		if _thread == null:
			# A queued/failed-start request has not entered _run. Its RunState,
			# including the last input alias, must instead die on retirement worker.
			_queue_retirement({"inputState":_state})
			_state = null
			_active = {}
		return true
	if _completed.get("token",0) == token and _completed.get("epoch",0) == _epoch:
		_navigation_timing_cancel(_completed,"cancelled_after_join")
		if _completed.ownsWorkerPayload: _queue_retirement(_completed.result)
		_completed = {}
		return true
	return false

func reset() -> int:
	_navigation_timing_cancel(_active,"reset_pending" if _thread!=null else "reset_before_start")
	_navigation_timing_cancel(_completed,"discarded_on_reset")
	_epoch += 1
	_last_navigation_batch = {}
	if _completed.get("ownsWorkerPayload",false): _queue_retirement(_completed.result)
	_completed = {}
	if _state != null:
		_state.cancel()
		if _thread == null:
			_queue_retirement({"inputState":_state})
			_state = null
			_active = {}
	return _epoch

func retire_external_payload(payload: Dictionary) -> bool:
	# Caller relinquishes ALL its aliases after true, before the next poll.
	# Accept during closing too: shutdown must drain externally detached state.
	if _thread != null or _state != null or not _active.is_empty() or not _completed.is_empty() or not _retired.is_empty(): return false
	if not payload.is_empty(): _queue_retirement(payload)
	return true

func request_shutdown() -> void:
	_closing = true
	reset()

func has_pending_work() -> bool:
	return _thread != null or _state != null or not _active.is_empty() \
		or not _completed.is_empty() or not _retired.is_empty() or _retirement != null

func _start_thread(work: Callable) -> int:
	return _thread.start(work)

func _source_validation_failure(source: Dictionary) -> String:
	if not source.is_read_only() or source.get("status") != "prepared" \
			or not source.get("blueprint") is Dictionary or not source.get("furnishingPlan") is Dictionary \
			or not source.get("profile") is Dictionary:
		return "invalid_publication_source"
	if not source.blueprint.is_read_only() or not source.furnishingPlan.is_read_only() or not source.profile.is_read_only():
		return "mutable_publication_source"
	return ""

func _prepare_source(source: Dictionary, binding: Dictionary, continuation: Callable, description_callback: Callable = Callable()) -> Dictionary:
	return Preparation.prepare_source(source.blueprint, source.furnishingPlan, binding, continuation, source.profile.origin, description_callback,
		bool(source.get("demandedNavigation",false)))

func _run(state: RunState) -> Dictionary:
	state.begin_work() # Queue residence and failed-start retries are not run time.
	if state.kind == "navigation": return _run_navigation(state)
	var result := _failed("cancelled")
	if state.advance("publication_worker_started"):
		if state.kind=="preparation":
			result = _prepare_source(state.source, state.binding, state.advance, state.publish_description)
			if bool(result.get("ready", false)):
				# Retain only the admitted frozen profile, not the whole input source.
				# A later Admission cache eviction cannot require another source build.
				result["profile"] = state.source.profile
		elif state.kind=="publication_base":
			result=Preparation.prepare_publication_base(state.source.blueprint,state.source.furnishingPlan,state.binding,state.source.profile,state.advance)
			if bool(result.get("ready",false)): result["profile"]=state.source.profile
		elif state.kind=="physical_group_packet":
			result=Preparation.compile_physical_group_packet(state.packet_base,state.packet_group_ids,state.advance)
		elif state.kind=="publication_base_navigation":
			result=Preparation.prepare_navigation_source(state.packet_base,state.binding,state.advance)
		if not state.advance("publication_worker_completed"):
			# Drop any late prepared holder HERE, before returning a small terminal.
			result = _failed("cancelled")
	var release_started := Time.get_ticks_usec()
	state.source = {}
	state.packet_base=null
	state.packet_group_ids=[]
	state.binding = {}
	state.release_description() # Release unclaimed aliases on the worker.
	state.input_release_usec = Time.get_ticks_usec()-release_started
	state.released_on_thread = OS.get_thread_caller_id()
	return result

func _run_navigation(state: RunState) -> Dictionary:
	var result := _failed("cancelled")
	if state.advance("navigation_batch_started"):
		var producer: NavigationProducer = state.navigation_source.producer
		var progress: Dictionary = producer.status()
		var receipts := {}
		var pending: Array[String] = []
		# Read the cursor only after ownership transferred to this worker. An
		# already active output cannot be omitted to make room for urgent demand.
		var active_output := String(progress.get("activeTileKey",""))
		if progress.get("status")=="ready" and not active_output.is_empty() and not state.tile_keys.has(active_output):
			progress = {"status":"failed","reason":"navigation_active_output_not_selected"}
		if progress.get("status")=="ready":
			for key: String in state.tile_keys: producer.request(key)
			progress = producer.prioritize_waiting(state.tile_order)
			for key: String in state.tile_keys:
				var receipt: Dictionary = producer.take(key)
				if receipt.get("status")=="ready": receipts[key] = receipt
				else: pending.append(key)
		state.record_navigation_progress(progress,pending)
		var turn_started := Time.get_ticks_usec()
		var kernel_steps := 0
		var yield_reason := ""
		while progress.get("status")=="ready" and not pending.is_empty() and not state.is_cancelled():
			# Do not start another kernel once either owner-turn limit is reached.
			# A single existing kernel operation may overrun its cooperative budget.
			if kernel_steps>=MAX_NAVIGATION_KERNEL_STEPS:
				yield_reason = "kernel_step_limit"
				break
			if kernel_steps>0 and Time.get_ticks_usec()-turn_started>=NAVIGATION_TURN_USEC:
				yield_reason = "elapsed_turn_limit"
				break
			# Missing work is only inconsistent when the producer is explicitly
			# idle with no queued work. Stable scan/sample counters are not failure.
			if progress.get("phase")=="idle" and int(progress.get("pendingRequestCount",0))==0:
				progress = {"status":"failed","reason":"navigation_producer_missing_requested_work"}
				break
			var advance_started := Time.get_ticks_usec()
			progress = producer.advance(NAVIGATION_BATCH_USEC,state.advance,state.tile_keys)
			var advance_elapsed := Time.get_ticks_usec()-advance_started
			kernel_steps += 1
			receipts = {}
			pending = []
			for key: String in state.tile_keys:
				var receipt: Dictionary = producer.take(key)
				if receipt.get("status")=="ready": receipts[key] = receipt
				else: pending.append(key)
			state.record_navigation_progress(progress,pending,advance_elapsed)
		if progress.get("status")=="ready" and state.advance("navigation_batch_completed"):
			receipts.make_read_only()
			progress.make_read_only()
			# ready preserves the existing completed-TURN contract. Incomplete
			# tiles stay pending and the owner regains the same producer association.
			var batch_progress := state.navigation_snapshot()
			batch_progress["turnElapsedUsec"] = Time.get_ticks_usec()-turn_started
			batch_progress["yieldReason"] = yield_reason
			result = {"ready":true,"kind":"navigation_batch","navigationSource":state.navigation_source,
				"requestedTileKeys":state.tile_keys,"requestedTileOrder":state.tile_order,"tileReceipts":receipts,"batchComplete":pending.is_empty(),
				"producerStatus":progress,"batchProgress":batch_progress}
		else:
			var failure := String(progress.get("reason",""))
			result = _failed("cancelled" if state.is_cancelled() else (failure if not failure.is_empty() else "navigation_producer_failed"))
		if not state.advance("navigation_batch_returned"): result = _failed("cancelled")
		producer = null # Never leave a producer alias in an owner-bound callable.
	var release_started := Time.get_ticks_usec()
	state.navigation_source = {}
	state.tile_keys = []
	state.tile_order = []
	state.binding = {}
	state.input_release_usec = Time.get_ticks_usec()-release_started
	state.released_on_thread = OS.get_thread_caller_id()
	state.finish_work() # Actual navigation execution end, after input release.
	return result

func _store_completed(result: Dictionary, owns_worker_payload := true) -> void:
	_completed = {"token":_active.token, "epoch":_active.epoch, "binding":_active.binding,"descriptionTaken":_active.get("descriptionTaken",false),
		"kind":_active.kind,"producerId":_active.get("producerId",0),"tileKeys":_active.get("tileKeys",[]),"tileOrder":_active.get("tileOrder",[]),
		"demandedNavigation":_active.get("demandedNavigation",false),
		"cancelled":_active.cancelled, "result":result, "ownsWorkerPayload":owns_worker_payload}
	if _active.get("kind")=="navigation": _completed.navigationTiming = _active.navigationTiming

## Observational only: no polling, completion transfer, producer access or
## scheduling. Rows and aggregate totals span this worker's lifetime; reset
## retains bounded old-epoch cancellation evidence. Zero is an unreached clock.
func navigation_timing() -> Dictionary:
	var history: Array[Dictionary] = _navigation_timing_history.duplicate(true)
	var entry: Dictionary = _active if _active.get("kind")=="navigation" else _completed
	var active: Dictionary = {}
	if entry.get("kind")=="navigation":
		active = entry.navigationTiming.duplicate(true)
		if is_same(entry,_active) and _state!=null:
			active.merge(_state.work_timing_snapshot(),true)
			if active.disposition=="queued" and active.startedUsec>0:
				active.disposition = "finished" if active.finishedUsec>0 else "running"
		for index: int in range(history.size()):
			if history[index].token==active.token and history[index].epoch==active.epoch:
				history[index] = active.duplicate(true)
				break
	return {"schema":"building-navigation-worker-timing/v1","epoch":_epoch,"observedUsec":Time.get_ticks_usec(),
		"historyLimit":NAVIGATION_TIMING_HISTORY_LIMIT,"queuedCount":_navigation_timing_queued,"droppedCount":_navigation_timing_dropped,
		"history":history,"active":active,"aggregates":_navigation_timing_aggregates.duplicate(true),
		"scope":"Monotonic wall clocks, not CPU time. Navigation batches only; aggregates count reached join/take boundaries, including cancelled or stale joined work. Reset preserves epoch-tagged history and lifetime totals. No source geometry retained."}

func _navigation_timing_begin(entry: Dictionary) -> void:
	var row := {"token":entry.token,"epoch":entry.epoch,"binding":entry.binding,
		"tileKeys":entry.tileKeys,"tileOrder":entry.tileOrder,"queuedUsec":Time.get_ticks_usec(),
		"startedUsec":0,"finishedUsec":0,"joinedUsec":0,"takenUsec":0,"threadId":-1,
		"startAttempts":0,"lastStartError":OK,"disposition":"queued","cancelRequestedUsec":0,
		"activeTileKey":"","producerPhase":"","preparationUsec":0,"sliceCount":0}
	entry.navigationTiming = row # Scalar-only owner alias; never bound on worker.
	_navigation_timing_history.append(row)
	_navigation_timing_queued += 1
	if _navigation_timing_history.size()>NAVIGATION_TIMING_HISTORY_LIMIT:
		_navigation_timing_history.pop_front()
		_navigation_timing_dropped += 1

func _navigation_timing_join(entry: Dictionary, state: RunState, joined_usec: int) -> void:
	var row: Dictionary = entry.navigationTiming
	row.merge(state.work_timing_snapshot(),true)
	row.joinedUsec = joined_usec
	row.disposition = "discarded_stale" if entry.epoch!=_epoch or _closing else ("cancelled" if entry.cancelled or state.is_cancelled() else "completed")
	var progress: Dictionary = state.navigation_snapshot()
	for field: String in ["activeTileKey","producerPhase","preparationUsec","sliceCount"]:
		if progress.has(field): row[field] = progress[field]
	_navigation_timing_add("queuedToStarted",row.queuedUsec,row.startedUsec)
	_navigation_timing_add("execution",row.startedUsec,row.finishedUsec)
	_navigation_timing_add("finishedToJoined",row.finishedUsec,row.joinedUsec)

func _navigation_timing_cancel(entry: Dictionary, disposition: String) -> void:
	if entry.get("kind")!="navigation": return
	var row: Dictionary = entry.navigationTiming
	if row.cancelRequestedUsec==0: row.cancelRequestedUsec = Time.get_ticks_usec()
	row.disposition = disposition

func _navigation_timing_add(name: String, begin: int, end: int) -> void:
	if begin<=0 or end<begin: return
	var elapsed: int = end-begin
	var aggregate: Dictionary = _navigation_timing_aggregates[name]
	aggregate.count += 1
	aggregate.totalUsec += elapsed
	aggregate.maxUsec = maxi(aggregate.maxUsec,elapsed)

func _queue_retirement(payload: Dictionary) -> void:
	assert(_retired.is_empty())
	_retired = payload

func _start_retirement() -> void:
	_retirement = RetirementState.new()
	_retirement.payload = _retired
	_active = {"kind":"retirement", "token":0, "epoch":_epoch}
	_thread = Thread.new()
	_retirement_start_error = _start_thread(_retirement.release_payload)
	if _retirement_start_error != OK:
		_thread = null
		_active = {}
		_retirement = null # _retired still owns payload; never dispose on main.
		return
	_retired = {}
	_retirement.transferred.post()

static func _receipt(entry: Dictionary, status: String) -> Dictionary:
	var receipt := {"status":status, "token":entry.token, "binding":entry.binding}
	# Canonical keys remain idempotence identity. A duplicate cannot reprioritize
	# an owned turn, and observes its original accepted immutable dispatch order.
	if entry.get("kind")=="navigation": receipt["requestedTileOrder"] = entry.get("tileOrder",[])
	return receipt

static func _rejected(status: String, reason: String) -> Dictionary:
	return {"status":status, "reason":reason, "token":0, "binding":{}}

static func _failed(reason: String) -> Dictionary:
	return {"ready":false, "reason":reason}
