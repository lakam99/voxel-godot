extends SceneTree

const Admission = preload("res://scripts/world/CitadelTerrainAdmission.gd")
const Queue = preload("res://scripts/world/CitadelSiteBuildQueue.gd")
const SEED := "citadel-source-lease-contract"
const REGION := Vector2i(1, 0)

var _worker_entered := Semaphore.new()
var _worker_release := Semaphore.new()
var _worker_returns_payload := false

var _failures: Array[String] = []
var _metrics := {"maxUsecByOperation":{}, "maxFrameWorkUsec":0, "steps":0}
var _trace: Array[Dictionary] = []

func _init() -> void:
	call_deferred("run")

func _check(value: bool, label: String) -> void:
	if not value: _failures.append(label)

func _measure(label: String, operation: Callable) -> Variant:
	var started := Time.get_ticks_usec()
	var result: Variant = operation.call()
	var elapsed := Time.get_ticks_usec() - started
	_metrics.maxUsecByOperation[label] = maxi(int(_metrics.maxUsecByOperation.get(label, 0)), elapsed)
	_metrics.maxFrameWorkUsec = maxi(int(_metrics.maxFrameWorkUsec), elapsed)
	_metrics.steps = int(_metrics.steps) + 1
	return result

func _new_admission(queue) -> Admission:
	var admission := Admission.new()
	admission.configure(SEED, {}, {"regionCells":140, "spawnChance":0.08})
	admission.finalize_town_inputs({})
	# The deterministic queue gate controls only worker completion; source
	# scheduling, per-region request ownership, cancellation and retirement remain
	# the production admission/queue implementations.
	admission._queue = queue
	return admission

func _step(admission: Admission) -> Dictionary:
	return _measure("admission_advance", func(): return admission.advance())

func _await_worker() -> void:
	while not _worker_entered.try_wait():
		await process_frame

func _controlled_worker(_request: Dictionary, _state, _queue) -> Dictionary:
	_worker_entered.post()
	while not _worker_release.try_wait(): OS.delay_msec(1)
	if _worker_returns_payload:
		return {"status":"prepared", "contractPayload":"x".repeat(1_000_000)}
	return {"status":"absent", "reason":"contract_source_absent"}

func run() -> void:
	await _shared_lease_case()
	await _last_lease_cancel_case()
	await _reset_during_active_case()
	await _legacy_active_reset_case()
	await _stale_terminal_release_case()
	await _pending_release_case()
	var report := {"schema":"citadel-source-lease-contract/v1",
		"passed":_failures.is_empty(), "evidenceLevel":"admission source-lease contract",
		"productionCutover":false, "failures":_failures, "metrics":_metrics,
		"terminalDecisionReleaseSemantics":"lease release drops consumer demand; the immutable terminal decision and any consumed receipt retirement remain admission-owned and may finish asynchronously",
		"trace":_trace}
	var path := OS.get_environment("VWB_CITADEL_SOURCE_LEASE_REPORT")
	if not path.is_empty():
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(report, "\t"))
	quit(0 if report.passed else 1)

func _shared_lease_case() -> void:
	var queue = Queue.new()
	_worker_entered = Semaphore.new()
	_worker_release = Semaphore.new()
	_worker_returns_payload = false
	var admission := _new_admission(queue)
	_check(queue._set_worker_callable_for_test(Callable(self, "_controlled_worker").bind(queue)), "controlled_worker_installed")
	var first: Dictionary = _measure("lease_acquire", func(): return admission.acquire_source_lease(REGION))
	var sibling: Dictionary = _measure("lease_acquire", func(): return admission.acquire_source_lease(REGION))
	var first_id := int(first.get("leaseId", 0))
	var sibling_id := int(sibling.get("leaseId", 0))
	_check(first_id > 0 and sibling_id > 0 and first_id != sibling_id, "distinct_shared_source_leases")
	_measure("lease_request", func(): return admission.request_source_with_lease(first_id))
	_measure("lease_request", func(): return admission.request_source_with_lease(sibling_id))
	_step(admission) # Submit source request into the queue.
	_step(admission) # Dispatch worker.
	await _await_worker()
	var join_before := int(queue._max_join_usec)
	var released: Dictionary = _measure("lease_release", func(): return admission.release_source_lease(first_id))
	_check(released.get("state") == "drained" and released.get("status") == "ready",
		"one_shared_lease_releases_without_cancelling_sibling")
	_check(queue._max_join_usec == join_before and queue.source_request_state(int(admission._requests[REGION].receipt.token)) == "active",
		"lease_release_does_not_poll_join_or_cancel_active_source")
	_worker_release.post()
	var sibling_state := "pending"
	while sibling_state == "pending":
		_step(admission)
		var state: Dictionary = _measure("lease_state", func(): return admission.source_lease_state(sibling_id))
		sibling_state = String(state.get("state", "failed"))
		if sibling_state == "pending": await process_frame
	_check(sibling_state == "absent", "sibling_receives_valid_source_decision")
	var sibling_result: Dictionary = admission.request_source_with_lease(sibling_id)
	_check(sibling_result.get("status") == "absent"
		and sibling_result.get("reason") == "contract_source_absent",
		"sibling_can_consume_unmodified_source_result")
	var sibling_token := int(admission._source_leases[sibling_id].get("token", 0))
	while not admission._retired.is_empty() or queue.source_request_state(sibling_token) != "absent":
		_step(admission)
		await process_frame
	_measure("lease_release", func(): return admission.release_source_lease(sibling_id))
	_trace.append({"case":"shared_active_release", "released":released,
		"siblingState":sibling_state, "queue":queue.source_request_state(sibling_token)})
	_check(admission.forget_source_lease(first_id) and admission.forget_source_lease(sibling_id),
		"terminal_shared_leases_can_be_forgotten")
	queue._worker_callable_for_test = Callable()
	admission._queue = null

func _last_lease_cancel_case() -> void:
	var queue = Queue.new()
	_worker_entered = Semaphore.new()
	_worker_release = Semaphore.new()
	_worker_returns_payload = true
	var admission := _new_admission(queue)
	_check(queue._set_worker_callable_for_test(Callable(self, "_controlled_worker").bind(queue)), "controlled_worker_installed")
	var lease: Dictionary = _measure("lease_acquire", func(): return admission.acquire_source_lease(REGION))
	var lease_id := int(lease.get("leaseId", 0))
	_measure("lease_request", func(): return admission.request_source_with_lease(lease_id))
	_step(admission)
	_step(admission)
	await _await_worker()
	var released: Dictionary = _measure("lease_release", func(): return admission.release_source_lease(lease_id))
	_check(released.get("status") == "pending" and released.get("state") == "draining",
		"last_active_lease_release_reports_draining")
	_check(admission.source_lease_state(lease_id).get("state") == "draining",
		"last_active_lease_not_falsely_drained")
	_worker_release.post()
	var retirement_seen := false
	var state := "draining"
	while state == "draining":
		_step(admission)
		var queue_state := queue.source_request_state(int(released.get("token", 0)))
		if queue_state == "retirement_pending": retirement_seen = true
		state = String(admission.source_lease_state(lease_id).get("state", "failed"))
		if state == "draining": await process_frame
	_check(retirement_seen, "cancelled_worker_payload_enters_owned_retirement")
	_check(state == "drained", "last_lease_drains_after_retirement_ack")
	_trace.append({"case":"last_active_release", "release":released,
		"retirementObserved":retirement_seen, "finalState":state,
		"maxRetirementUsec":queue._max_retirement_usec,
		"maxJoinUsec":queue._max_join_usec})
	_check(admission.forget_source_lease(lease_id), "drained_cancel_lease_can_be_forgotten")
	queue._worker_callable_for_test = Callable()
	admission._queue = null

func _pending_release_case() -> void:
	var queue = Queue.new()
	_worker_entered = Semaphore.new()
	_worker_release = Semaphore.new()
	_worker_returns_payload = false
	var admission := _new_admission(queue)
	var lease: Dictionary = _measure("lease_acquire", func(): return admission.acquire_source_lease(REGION))
	var lease_id := int(lease.get("leaseId", 0))
	_measure("lease_request", func(): return admission.request_source_with_lease(lease_id))
	var released: Dictionary = _measure("lease_release", func(): return admission.release_source_lease(lease_id))
	_check(released.get("state") == "drained" and released.get("status") == "ready",
		"undispatched_lease_releases_immediately")
	_check(queue._pending.is_empty() and queue._active.is_empty() and not queue._thread,
		"undispatched_release_creates_no_worker")
	_trace.append({"case":"pending_no_dispatch", "release":released,
		"queuePending":queue._pending.size(), "workerRunning":queue._thread != null})
	_check(admission.forget_source_lease(lease_id), "undispatched_lease_can_be_forgotten")
	admission._queue = null

func _reset_during_active_case() -> void:
	var queue = Queue.new()
	_worker_entered = Semaphore.new()
	_worker_release = Semaphore.new()
	_worker_returns_payload = true
	var admission := _new_admission(queue)
	_check(queue._set_worker_callable_for_test(Callable(self, "_controlled_worker").bind(queue)), "controlled_worker_installed")
	var lease: Dictionary = _measure("lease_acquire", func(): return admission.acquire_source_lease(REGION))
	var lease_id := int(lease.get("leaseId", 0))
	_measure("lease_request", func(): return admission.request_source_with_lease(lease_id))
	_step(admission)
	_step(admission)
	await _await_worker()
	var token := int(admission._requests[REGION].receipt.token)
	admission.configure(SEED + "-replacement", {}, {"regionCells":140, "spawnChance":0.08})
	admission.finalize_town_inputs({})
	_check(queue.source_request_state(token) == "active",
		"old_epoch_active_token_not_misreported_absent")
	_check(admission.source_lease_state(lease_id).get("state") == "draining",
		"reconfigured_admission_retains_old_lease_drain")
	_worker_release.post()
	var state := "draining"
	var retirement_seen := false
	while state == "draining":
		_step(admission)
		var queue_state := queue.source_request_state(token)
		if queue_state == "retirement_pending": retirement_seen = true
		state = String(admission.source_lease_state(lease_id).get("state", "failed"))
		if state == "draining": await process_frame
	_check(retirement_seen and state == "drained",
		"generation_replacement_drain_waits_for_retirement_ack")
	_check(admission.source_lease_state(lease_id).get("reason") == "admission_generation_replaced",
		"generation_replacement_reason_preserved")
	_trace.append({"case":"generation_reset_active", "token":token,
		"retirementObserved":retirement_seen, "finalState":state})
	_check(admission.forget_source_lease(lease_id), "reset_drained_lease_can_be_forgotten")
	queue._worker_callable_for_test = Callable()
	admission._queue = null

func _stale_terminal_release_case() -> void:
	var queue = Queue.new()
	_worker_entered = Semaphore.new()
	_worker_release = Semaphore.new()
	_worker_returns_payload = false
	var admission := _new_admission(queue)
	_check(queue._set_worker_callable_for_test(Callable(self, "_controlled_worker").bind(queue)), "controlled_worker_installed")
	var old_lease: Dictionary = _measure("lease_acquire", func(): return admission.acquire_source_lease(REGION))
	var old_id := int(old_lease.get("leaseId", 0))
	_measure("lease_request", func(): return admission.request_source_with_lease(old_id))
	_step(admission)
	_step(admission)
	await _await_worker()
	_worker_release.post()
	var terminal_state := "pending"
	while terminal_state == "pending":
		_step(admission)
		terminal_state = String(admission.source_lease_state(old_id).get("state", "failed"))
		if terminal_state == "pending": await process_frame
	_check(terminal_state == "absent", "old_generation_lease_reaches_terminal_source_decision")
	var token := int(admission._source_leases[old_id].get("token", 0))
	while not admission._retired.is_empty() or queue.source_request_state(token) != "absent":
		_step(admission)
		await process_frame
	admission.configure(SEED + "-stale-release", {}, {"regionCells":140, "spawnChance":0.08})
	admission.finalize_town_inputs({})
	_check(admission._source_leases[old_id].get("state") == "invalidated",
		"resolved_old_lease_is_invalidated_on_generation_change")
	_check(admission.set_prefetch_regions([REGION]), "new_generation_prefetch_created")
	var new_request_before: PackedByteArray = var_to_bytes(admission._requests[REGION].duplicate(true))
	var released: Dictionary = _measure("lease_release",
		func(): return admission.release_source_lease(old_id))
	_check(released.get("state") == "drained" and released.get("status") == "ready",
		"old_terminal_lease_releases_after_reconfigure")
	_check(admission._requests.has(REGION)
		and var_to_bytes(admission._requests[REGION].duplicate(true)) == new_request_before,
		"old_lease_release_does_not_mutate_new_generation_request")
	_check(admission.forget_source_lease(old_id), "invalidated_old_lease_can_be_forgotten")
	_trace.append({"case":"stale_terminal_release", "oldGeneration":old_lease.get("generation"),
		"newGeneration":admission._generation, "release":released,
		"newRequestPreserved":admission._requests.has(REGION)})
	queue._worker_callable_for_test = Callable()
	admission._queue = null

func _legacy_active_reset_case() -> void:
	var queue = Queue.new()
	_worker_entered = Semaphore.new()
	_worker_release = Semaphore.new()
	_worker_returns_payload = true
	var admission := _new_admission(queue)
	_check(queue._set_worker_callable_for_test(Callable(self, "_controlled_worker").bind(queue)), "controlled_worker_installed")
	_measure("legacy_request", func(): return admission.request_source(REGION, true))
	_step(admission)
	_step(admission)
	await _await_worker()
	var token := int(admission._requests[REGION].receipt.token)
	var lease: Dictionary = _measure("lease_acquire", func(): return admission.acquire_source_lease(REGION))
	var lease_id := int(lease.get("leaseId", 0))
	_check(lease_id > 0 and int(admission._source_leases[lease_id].get("token", 0)) == token,
		"late_lease_inherits_dispatched_legacy_token")
	admission.configure(SEED + "-legacy-reset", {}, {"regionCells":140, "spawnChance":0.08})
	admission.finalize_town_inputs({})
	_check(admission.source_lease_state(lease_id).get("state") == "draining"
		and queue.source_request_state(token) == "active",
		"late_legacy_lease_remains_draining_across_generation_reset")
	_worker_release.post()
	var state := "draining"
	var retirement_seen := false
	while state == "draining":
		_step(admission)
		var queue_state := queue.source_request_state(token)
		if queue_state == "retirement_pending": retirement_seen = true
		state = String(admission.source_lease_state(lease_id).get("state", "failed"))
		if state == "draining": await process_frame
	_check(retirement_seen and state == "drained",
		"late_legacy_lease_drains_only_after_worker_retirement")
	_trace.append({"case":"legacy_active_generation_reset", "token":token,
		"retirementObserved":retirement_seen, "finalState":state})
	_check(admission.forget_source_lease(lease_id), "late_legacy_lease_can_be_forgotten")
	queue._worker_callable_for_test = Callable()
	admission._queue = null
