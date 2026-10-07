extends SceneTree
## Synthetic thread/ownership contract; no gameplay or renderer proof.

const Retirement := preload("res://scripts/world/OwnedValueArtifactRetirement.gd")
var checks: Dictionary = {}


class FailFirstStartRetirement extends Retirement:
	var start_attempts := 0

	func _start_worker_thread(thread: Thread) -> int:
		start_attempts += 1
		if start_attempts == 1:
			return FAILED
		return super._start_worker_thread(thread)


class AlwaysFailStartRetirement extends Retirement:
	var start_attempts := 0

	func _start_worker_thread(_thread: Thread) -> int:
		start_attempts += 1
		return FAILED


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check_start_failure_retry()
	await _check_deferred_release_and_resource_ack()
	_check_backpressure_drain_and_shutdown()
	_finish()


func _check_start_failure_retry() -> void:
	var helper := FailFirstStartRetirement.new()
	var first_start: Dictionary = helper.start_worker()
	var root_values: Array[Dictionary] = [_root_value("retry-root")]
	var rejected_enqueue: Dictionary = helper.enqueue(root_values)
	var failed_snapshot: Dictionary = helper.snapshot()
	var retry_start: Dictionary = helper.start_worker()
	var accepted_enqueue: Dictionary = helper.enqueue(root_values)
	var drained: Dictionary = helper.drain()
	var final_snapshot: Dictionary = helper.snapshot()
	_check("transient_start_failure_keeps_admission_retryable",
		String(first_start.get("status", "")) == "pending" \
		and String(rejected_enqueue.get("status", "")) == "pending" \
		and int(failed_snapshot.get("pendingCount", -1)) == 0 \
		and int(failed_snapshot.get("startFailureCount", -1)) == 1 \
		and String(retry_start.get("status", "")) == "ready" \
		and String(accepted_enqueue.get("status", "")) == "ready" \
		and String(drained.get("status", "")) == "ready" \
		and int(final_snapshot.get("completedCount", -1)) == 1)
	var shutdown: Dictionary = helper.shutdown()
	_check("shutdown_joins_retry_started_worker",
		String(shutdown.get("status", "")) == "ready" \
		and bool(helper.snapshot().get("workerJoined", false)) \
		and helper.start_attempts == 2)
	var never_started := AlwaysFailStartRetirement.new()
	var start_failed: Dictionary = never_started.start_worker()
	var shutdown_without_worker: Dictionary = never_started.shutdown()
	_check("shutdown_never_retries_thread_start_without_admitted_payload",
		String(start_failed.get("status", "")) == "pending" \
		and String(shutdown_without_worker.get("status", "")) == "ready" \
		and never_started.start_attempts == 1 \
		and bool(never_started.snapshot().get("workerJoined", false)))


func _check_deferred_release_and_resource_ack() -> void:
	var helper := Retirement.new()
	var start: Dictionary = helper.start_worker()
	var root_values: Array[Dictionary] = [_root_value("deferred-root")]
	var resource_keepalive: Resource = Resource.new()
	var resource_ref: WeakRef = weakref(resource_keepalive)
	var refcounted_keepalive: RefCounted = RefCounted.new()
	var refcounted_ref: WeakRef = weakref(refcounted_keepalive)
	var surface_tool_keepalive: SurfaceTool = SurfaceTool.new()
	var surface_tool_ref: WeakRef = weakref(surface_tool_keepalive)
	var keepalives: Array[RefCounted] = [resource_keepalive,
		refcounted_keepalive, surface_tool_keepalive]
	var enqueue_result: Dictionary = helper.enqueue(root_values, keepalives)
	root_values.clear()
	keepalives.clear()
	resource_keepalive = null
	refcounted_keepalive = null
	surface_tool_keepalive = null
	var state_value: Variant = helper._outstanding[0] if not helper._outstanding.is_empty() else null
	var queued_roots: Array = state_value.value_roots if state_value != null else []
	var main_thread_id := OS.get_thread_caller_id()
	var before_advance := state_value != null \
		and not bool(state_value.completed) \
		and queued_roots.size() == 1 \
		and int(state_value.released_on_thread) == -1
	var signal_result: Dictionary = helper.advance()
	var worker_completed := await _wait_for_worker_completion(helper, state_value)
	var before_ack_snapshot: Dictionary = helper.snapshot()
	var retained_until_ack := resource_ref.get_ref() != null \
		and refcounted_ref.get_ref() != null \
		and surface_tool_ref.get_ref() != null \
		and int(before_ack_snapshot.get("pendingCount", -1)) == 1 \
		and int(before_ack_snapshot.get("completedCount", -1)) == 0
	var state_roots_after_worker: Array = state_value.value_roots if state_value != null else [null]
	var released_on_worker := worker_completed and state_roots_after_worker.is_empty() \
		and int(state_value.released_on_thread) != main_thread_id
	var ack: Dictionary = helper.advance()
	var after_ack_snapshot: Dictionary = helper.snapshot()
	_check("enqueue_defers_release_until_advance_then_releases_on_worker",
		String(start.get("status", "")) == "ready" \
		and String(enqueue_result.get("status", "")) == "ready" \
		and before_advance and String(signal_result.get("status", "")) == "active" \
		and released_on_worker)
	_check("main_resource_keepalive_lives_until_completion_ack_collection",
		retained_until_ack and String(ack.get("status", "")) == "idle" \
		and resource_ref.get_ref() == null \
		and refcounted_ref.get_ref() == null \
		and surface_tool_ref.get_ref() == null \
		and int(after_ack_snapshot.get("pendingCount", -1)) == 0 \
		and int(after_ack_snapshot.get("completedCount", -1)) == 1)
	var shutdown: Dictionary = helper.shutdown()
	_check("worker_shutdown_after_ack_is_joined",
		String(shutdown.get("status", "")) == "ready" \
		and bool(helper.snapshot().get("workerJoined", false)))


func _check_backpressure_drain_and_shutdown() -> void:
	var helper := Retirement.new()
	var started: Dictionary = helper.start_worker()
	var accepted_count := 0
	for index in range(Retirement.MAX_PENDING_BATCHES):
		var roots: Array[Dictionary] = [_root_value("capacity-%d" % index)]
		var accepted: Dictionary = helper.enqueue(roots)
		roots.clear()
		if String(accepted.get("status", "")) == "ready":
			accepted_count += 1
	var full_snapshot: Dictionary = helper.snapshot()
	var rejects_while_full := not helper.can_accept()
	var blocked_roots: Array[Dictionary] = [_root_value("backpressure")]
	var blocked: Dictionary = helper.enqueue(blocked_roots)
	blocked_roots.clear()
	var drained: Dictionary = helper.drain()
	var after_drain: Dictionary = helper.snapshot()
	var can_reuse_worker_after_drain := helper.can_accept()
	var post_drain_roots: Array[Dictionary] = [_root_value("after-drain")]
	var post_drain_enqueue: Dictionary = helper.enqueue(post_drain_roots)
	post_drain_roots.clear()
	var second_drain: Dictionary = helper.drain()
	var before_shutdown: Dictionary = helper.snapshot()
	var shutdown: Dictionary = helper.shutdown()
	var after_shutdown: Dictionary = helper.snapshot()
	_check("outstanding_batch_cap_applies_backpressure_until_ack",
		String(started.get("status", "")) == "ready" \
		and accepted_count == Retirement.MAX_PENDING_BATCHES \
		and int(full_snapshot.get("pendingCount", -1)) == Retirement.MAX_PENDING_BATCHES \
		and rejects_while_full \
		and String(blocked.get("status", "")) == "pending" \
		and bool(blocked.get("retryable", false)))
	_check("drain_flushes_batches_and_keeps_worker_available_for_reuse",
		String(drained.get("status", "")) == "ready" \
		and int(drained.get("completedCount", -1)) == Retirement.MAX_PENDING_BATCHES \
		and bool(after_drain.get("workerStarted", false)) \
		and not bool(after_drain.get("workerJoined", true)) \
		and can_reuse_worker_after_drain \
		and String(post_drain_enqueue.get("status", "")) == "ready" \
		and String(second_drain.get("status", "")) == "ready" \
		and int(before_shutdown.get("completedCount", -1)) \
			== Retirement.MAX_PENDING_BATCHES + 1)
	_check("shutdown_drains_then_joins_the_persistent_worker",
		String(shutdown.get("status", "")) == "ready" \
		and int(shutdown.get("startedCount", -1)) == 1 \
		and int(shutdown.get("completedCount", -1)) == Retirement.MAX_PENDING_BATCHES + 1 \
		and bool(after_shutdown.get("workerJoined", false)) \
		and not bool(after_shutdown.get("workerStarted", true)) \
		and bool(after_shutdown.get("stopRequested", false)))


func _wait_for_worker_completion(helper: Retirement, state: Variant) -> bool:
	if not state is Object:
		return false
	var finished := false
	for _attempt in range(3000):
		helper._mutex.lock()
		finished = bool(state.completed)
		helper._mutex.unlock()
		if finished:
			return true
		OS.delay_usec(1000)
	helper._mutex.lock()
	finished = bool(state.completed)
	helper._mutex.unlock()
	return finished


func _root_value(root_id: String) -> Dictionary:
	var root_value := {"schema":"owned-value-artifact-retirement-fixture/v1",
		"rootId":root_id, "payload":[1, 2, 3]}
	root_value.make_read_only()
	return root_value


func _check(name: String, passed: bool) -> void:
	checks[name] = passed


func _finish() -> void:
	var report := {"schema":"owned-value-artifact-retirement-contract/v1",
		"passed":not checks.values().has(false), "checks":checks,
		"checkCount":checks.size(),
		"evidenceLevel":"synthetic_owned_value_retirement_thread_and_ack_contract",
		"doesNotProve":"No production queue integration, live renderer install, gameplay, or performance acceptance."}
	var report_path := OS.get_environment("OWNED_VALUE_ARTIFACT_RETIREMENT_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	print("OWNED VALUE ARTIFACT RETIREMENT ", JSON.stringify(report))
	quit(0 if report.passed else 1)
