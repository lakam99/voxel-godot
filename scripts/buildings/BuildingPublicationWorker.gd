extends RefCounted
class_name BuildingPublicationWorker

## One main-thread owner, one worker shared by preparation and retirement.
## dispatch/retire only retain ownership; poll starts work on a later owner call.
## The controller retains demand when busy and keeps polling through shutdown.
## Inputs come from Admission's deeply frozen source, never scene objects.
const Preparation = preload("res://scripts/buildings/BuildingPublicationPreparation.gd")

class RunState extends RefCounted:
	var source: Dictionary = {}
	var binding: Dictionary = {}
	var mutex := Mutex.new()
	var cancelled := false
	var stage := "queued"
	var stage_count := 0
	var started_usec := 0
	var previous_usec := 0
	var max_stage_gap_usec := 0
	var released_on_thread := -1
	var input_release_usec := 0
	func begin_work() -> void:
		mutex.lock()
		started_usec = Time.get_ticks_usec()
		previous_usec = started_usec
		max_stage_gap_usec = 0
		stage_count = 0
		mutex.unlock()
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
		stage = next_stage.left(160)
		stage_count += 1
		mutex.unlock()
		return true
	func snapshot() -> Dictionary:
		mutex.lock()
		var value := {"stage":stage, "stageCount":stage_count, "cancelRequested":cancelled,
			"elapsedUsec":Time.get_ticks_usec()-started_usec if started_usec > 0 else 0, "maxStageGapUsec":max_stage_gap_usec}
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

func dispatch(source: Dictionary, binding: Dictionary) -> Dictionary:
	var started := Time.get_ticks_usec()
	# Capture the three scalar identity fields before callbacks or worker work.
	var captured := binding.duplicate()
	if not Preparation.valid_binding(captured): return _rejected("failed", "invalid_publication_binding")
	captured.make_read_only()
	if _closing: return _rejected("failed", "shutting_down")
	for entry: Dictionary in [_active, _completed]:
		if entry.get("epoch",0) == _epoch and entry.get("binding",{}) == captured and not entry.get("cancelled",false):
			var duplicate := _receipt(entry, "queued")
			duplicate["duplicate"] = true
			return duplicate
	if _thread != null or _state != null or not _active.is_empty() or not _completed.is_empty() or not _retired.is_empty():
		return _rejected("busy", "publication_worker_busy")
	# Admission owns full recursive freezing/validation. These constant-work
	# checks reject mutable envelopes without scanning/hashing source on main.
	if not source.is_read_only() or source.get("status") != "prepared" \
			or not source.get("blueprint") is Dictionary or not source.get("furnishingPlan") is Dictionary \
			or not source.get("profile") is Dictionary:
		return _rejected("failed", "invalid_publication_source")
	if not source.blueprint.is_read_only() or not source.furnishingPlan.is_read_only() or not source.profile.is_read_only():
		return _rejected("failed", "mutable_publication_source")
	_state = RunState.new()
	_state.source = source
	_state.binding = captured
	_active = {"kind":"preparation", "token":_next_token, "epoch":_epoch, "binding":captured, "cancelled":false}
	_next_token += 1
	_preparation_start_error = OK
	_max_dispatch_usec = maxi(_max_dispatch_usec, Time.get_ticks_usec()-started)
	return _receipt(_active, "queued")

func poll() -> Dictionary:
	var started := Time.get_ticks_usec()
	var joined := false
	if _thread != null and not _thread.is_alive():
		var join_started := Time.get_ticks_usec()
		var result: Variant = _thread.wait_to_finish()
		_max_join_usec = maxi(_max_join_usec, Time.get_ticks_usec()-join_started)
		_thread = null
		joined = true
		if _active.get("kind") == "retirement":
			_max_retirement_usec = maxi(_max_retirement_usec, int(result))
			_last_retirement_thread = _retirement.released_on_thread
			_retirement = null
		else:
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
		_preparation_start_error = _start_thread(_run.bind(_state))
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
		"shutdownComplete":_closing and _thread == null and _state == null and _active.is_empty() and _completed.is_empty() and _retired.is_empty() and _retirement == null,
		"retirementPending":not _retired.is_empty() or _retirement != null,
		"preparationStartError":_preparation_start_error, "retirementStartError":_retirement_start_error,
		"maxPollUsec":_max_poll_usec, "maxJoinUsec":_max_join_usec, "maxDispatchUsec":_max_dispatch_usec,
		"maxRetirementWorkUsec":_max_retirement_usec, "lastRetirementThreadId":_last_retirement_thread,
		"maxInputReleaseUsec":_max_input_release_usec, "lastInputReleaseThreadId":_last_input_release_thread,
		"discardedStale":_discarded_stale}

func take_result(token: int, expected_binding: Dictionary) -> Dictionary:
	if not _completed.is_empty() and _completed.token == token and _completed.epoch == _epoch and _completed.binding == expected_binding:
		var receipt := _receipt(_completed, "consumed")
		receipt["result"] = _completed.result
		_completed = {}
		return receipt
	if _active.get("kind") == "preparation" and _active.get("token",0) == token and _active.epoch == _epoch and _active.binding == expected_binding:
		return _receipt(_active, "pending")
	return _rejected("stale_token", "token_or_binding_mismatch")

func cancel(token: int) -> bool:
	if _active.get("kind") == "preparation" and _active.get("token",0) == token and _active.epoch == _epoch:
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
		if _completed.ownsWorkerPayload: _queue_retirement(_completed.result)
		_completed = {}
		return true
	return false

func reset() -> int:
	_epoch += 1
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

func _start_thread(work: Callable) -> int:
	return _thread.start(work)

func _prepare_source(source: Dictionary, binding: Dictionary, continuation: Callable) -> Dictionary:
	return Preparation.prepare_source(source.blueprint, source.furnishingPlan, binding, continuation)

func _run(state: RunState) -> Dictionary:
	state.begin_work() # Queue residence and failed-start retries are not run time.
	var result := _failed("cancelled")
	if state.advance("publication_worker_started"):
		result = _prepare_source(state.source, state.binding, state.advance)
		if bool(result.get("ready", false)):
			# Retain only the admitted frozen profile, not the whole input source.
			# A later Admission cache eviction cannot require another source build.
			result["profile"] = state.source.profile
		if not state.advance("publication_worker_completed"):
			# Drop any late prepared holder HERE, before returning a small terminal.
			result = _failed("cancelled")
	var release_started := Time.get_ticks_usec()
	state.source = {}
	state.binding = {}
	state.input_release_usec = Time.get_ticks_usec()-release_started
	state.released_on_thread = OS.get_thread_caller_id()
	return result

func _store_completed(result: Dictionary, owns_worker_payload := true) -> void:
	_completed = {"token":_active.token, "epoch":_active.epoch, "binding":_active.binding,
		"cancelled":_active.cancelled, "result":result, "ownsWorkerPayload":owns_worker_payload}

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
	return {"status":status, "token":entry.token, "binding":entry.binding}

static func _rejected(status: String, reason: String) -> Dictionary:
	return {"status":status, "reason":reason, "token":0, "binding":{}}

static func _failed(reason: String) -> Dictionary:
	return {"ready":false, "reason":reason}
