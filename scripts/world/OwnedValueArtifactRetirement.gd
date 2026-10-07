extends RefCounted
class_name OwnedValueArtifactRetirement

## Bounded owner for dropping already-separated immutable value roots away from
## Main. One worker is started before a caller admits large source artifacts;
## shutdown only signals and joins that existing worker.
const MAX_PENDING_BATCHES := 8

class RetirementState extends RefCounted:
	var value_roots: Array[Dictionary] = []
	var main_refcounted_keepalives: Array[RefCounted] = []
	var completed := false
	var released_on_thread := -1
	var release_usec := 0

	func release_value_roots() -> int:
		var started_usec := Time.get_ticks_usec()
		value_roots.clear()
		released_on_thread = OS.get_thread_caller_id()
		release_usec = maxi(0, Time.get_ticks_usec() - started_usec)
		return release_usec


var _thread: Thread
var _semaphore := Semaphore.new()
var _mutex := Mutex.new()
var _queue: Array[RetirementState] = []
var _outstanding: Array[RetirementState] = []
var _unposted_count := 0
var _started_count := 0
var _completed_count := 0
var _start_failure_count := 0
var _worker_started := false
var _stop_requested := false
var _stopped := false
var _last := {}


func start_worker() -> Dictionary:
	if not Thread.is_main_thread():
		return {"status":"failed", "reason":"value_retirement_start_requires_main_thread"}
	if _worker_started and _thread != null and _thread.is_started():
		return {"status":"ready", "started":false}
	if _stopped or _stop_requested:
		return {"status":"failed", "reason":"value_retirement_worker_stopped"}
	_thread = Thread.new()
	var error: int = _start_worker_thread(_thread)
	if error != OK:
		_thread = null
		_start_failure_count += 1
		_last = {"status":"pending", "reason":"value_retirement_worker_start_failed",
			"error":error}
		return _last.duplicate()
	_worker_started = true
	_started_count += 1
	_last = {"status":"ready", "started":true}
	return _last.duplicate()


## Small overridable seam so contract fixtures can reproduce a transient
## Thread.start failure without changing admission or shutdown behavior.
func _start_worker_thread(thread: Thread) -> int:
	return thread.start(Callable(self, "_worker_loop"))


func can_accept() -> bool:
	if not _worker_started or _stop_requested or _stopped:
		return false
	_mutex.lock()
	var accepted := _outstanding.size() < MAX_PENDING_BATCHES
	_mutex.unlock()
	return accepted


func enqueue(value_roots: Array[Dictionary],
		main_refcounted_keepalives: Array[RefCounted] = []) -> Dictionary:
	if not Thread.is_main_thread():
		return {"status":"failed", "reason":"value_retirement_enqueue_requires_main_thread"}
	if value_roots.is_empty():
		return {"status":"ready", "accepted":false, "pendingCount":_outstanding.size()}
	if not can_accept():
		return {"status":"pending", "reason":"value_retirement_backpressure_or_worker_unavailable",
			"retryable":true, "pendingCount":_outstanding.size()}
	for root: Dictionary in value_roots:
		if not root.is_read_only():
			return {"status":"failed", "reason":"value_retirement_root_not_immutable"}
	for keepalive: RefCounted in main_refcounted_keepalives:
		if not is_instance_valid(keepalive):
			return {"status":"failed", "reason":"value_retirement_keepalive_invalid"}
	var state := RetirementState.new()
	state.value_roots = value_roots.duplicate()
	state.main_refcounted_keepalives = main_refcounted_keepalives.duplicate()
	_mutex.lock()
	if _outstanding.size() >= MAX_PENDING_BATCHES or _stop_requested:
		_mutex.unlock()
		return {"status":"pending", "reason":"value_retirement_backpressure_or_stopping",
			"retryable":true, "pendingCount":_outstanding.size()}
	_queue.append(state)
	_outstanding.append(state)
	_unposted_count += 1
	_mutex.unlock()
	return {"status":"ready", "accepted":true, "pendingCount":_outstanding.size()}


func _worker_loop() -> int:
	while true:
		_semaphore.wait()
		_mutex.lock()
		var state: RetirementState = _queue.pop_front() if not _queue.is_empty() else null
		var should_stop := state == null and _stop_requested
		_mutex.unlock()
		if should_stop:
			break
		if state == null:
			continue
		state.release_value_roots()
		_mutex.lock()
		state.completed = true
		_mutex.unlock()
	return 0


func _collect_completed() -> void:
	var completed: Array[RetirementState] = []
	_mutex.lock()
	var retained: Array[RetirementState] = []
	for state: RetirementState in _outstanding:
		if state.completed: completed.append(state)
		else: retained.append(state)
	_outstanding = retained
	_mutex.unlock()
	for state: RetirementState in completed:
		state.main_refcounted_keepalives.clear()
		_completed_count += 1
		_last = {"status":"complete", "releasedOnThread":state.released_on_thread,
			"releaseUsec":state.release_usec}


func advance() -> Dictionary:
	if not Thread.is_main_thread():
		return {"status":"failed", "reason":"value_retirement_advance_requires_main_thread"}
	_collect_completed()
	_mutex.lock()
	var wake_count := _unposted_count
	_unposted_count = 0
	_mutex.unlock()
	for _index in range(wake_count): _semaphore.post()
	return {"status":"active" if not _outstanding.is_empty() else "idle",
		"pendingCount":_outstanding.size(), "startedCount":_started_count,
		"completedCount":_completed_count}


## Wait until all accepted roots have been released while keeping the persistent
## worker alive. Used by world-epoch reset before the queue resumes admissions.
func drain() -> Dictionary:
	if not Thread.is_main_thread():
		return {"status":"failed", "reason":"value_retirement_drain_requires_main_thread"}
	if not _worker_started and _outstanding.is_empty():
		return {"status":"ready", "startedCount":_started_count,
			"completedCount":_completed_count}
	if not _worker_started:
		return {"status":"failed", "reason":"value_retirement_worker_missing_with_payload"}
	while true:
		advance()
		_collect_completed()
		_mutex.lock()
		var empty := _outstanding.is_empty()
		_mutex.unlock()
		if empty: break
		OS.delay_usec(1000)
	return {"status":"ready", "startedCount":_started_count,
		"completedCount":_completed_count}


## Stop only after queued work drains. This does not create a worker during
## teardown, so a transient Thread.start failure cannot strand final aliases.
func shutdown() -> Dictionary:
	if not Thread.is_main_thread():
		return {"status":"failed", "reason":"value_retirement_shutdown_requires_main_thread"}
	var drained: Dictionary = drain()
	if String(drained.get("status", "")) != "ready": return drained
	if _worker_started and _thread != null and _thread.is_started():
		_mutex.lock()
		_stop_requested = true
		_mutex.unlock()
		_semaphore.post()
		_thread.wait_to_finish()
	_thread = null
	_worker_started = false
	_stop_requested = true
	_stopped = true
	return {"status":"ready", "startedCount":_started_count,
		"completedCount":_completed_count}


func snapshot() -> Dictionary:
	_mutex.lock()
	var pending_count := _outstanding.size()
	var active := not _queue.is_empty() or pending_count > _queue.size()
	_mutex.unlock()
	return {"pendingCount":pending_count, "active":active,
		"workerStarted":_worker_started, "stopRequested":_stop_requested,
		"startedCount":_started_count, "completedCount":_completed_count,
		"startFailureCount":_start_failure_count, "last":_last.duplicate(true),
		"outstandingZero":pending_count == 0,
		"workerJoined":_thread == null and not _worker_started}
