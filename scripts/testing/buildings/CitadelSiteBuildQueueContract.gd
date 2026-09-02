extends SceneTree

## SOURCE-ONLY SYNTHETIC CONTRACT. Real queue/Thread; controlled Site substitute.
## No geometry preparation, actual-05 parity, scene, gameplay or frame-budget proof.
const POLICY := {"regionCells": 140, "spawnChance": 0.26}
const REGION := Vector2i(1, -3)
const SEED := "atlas-1492"
const WAIT_USEC := 3000000
const RESPONSIVE_USEC := 100000 # Deadlock/stall guard, NOT a runtime frame budget.

class SyntheticQueue extends "res://scripts/world/CitadelSiteBuildQueue.gd":
	var enter_gate := Semaphore.new()
	var exit_gate := Semaphore.new()
	var observation_lock := Mutex.new()
	var observations: Array[Dictionary] = []
	var fail_start := false
	var retained_raw: Dictionary = {}

	func _start_thread(callback: Callable) -> int:
		if fail_start:
			return ERR_CANT_CREATE
		return super._start_thread(callback)

	func _prepare_site(request: Dictionary, continue_stage: Callable) -> Dictionary:
		_note({"event": "entered", "immutable": _frozen(request)})
		enter_gate.wait()
		var allowed: bool = continue_stage.call("synthetic_checkpoint")
		_note({"event": "checkpoint", "allowed": allowed, "request": request.duplicate(true)})
		# Deliberately hold AFTER acknowledging cancellation. Cancellation is not join.
		exit_gate.wait()
		# Deliberately return non-cancelled data after cancellation: late-result fencing.
		retained_raw = {"status": "absent", "synthetic": true, "request": request,
			"payload": {"items": [{"value": 17}]}}
		return retained_raw

	func _note(value: Dictionary) -> void:
		observation_lock.lock()
		observations.append(value)
		observation_lock.unlock()

	func observed() -> Array[Dictionary]:
		observation_lock.lock()
		var copy: Array[Dictionary] = observations.duplicate(true)
		observation_lock.unlock()
		return copy

	static func _frozen(value: Variant) -> bool:
		if value is Dictionary:
			if not value.is_read_only(): return false
			for child in value.values():
				if not _frozen(child): return false
		elif value is Array:
			if not value.is_read_only(): return false
			for child in value:
				if not _frozen(child): return false
		return not value is Object

var _checks: Dictionary = {}
var _trace: Array[Dictionary] = []
var _max_poll_usec := 0
var _bounded := true
var _small_status := true

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var path := OS.get_environment("VOXEL_CITADEL_QUEUE_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path):
		quit(2)
		return
	var started := Time.get_ticks_usec()
	_alias_duplicate_consume()
	_validation()
	_saturation_fairness()
	_reset_same_seed()
	_cancel_races()
	_start_failure()
	_shutdown()
	_retirement_case("cancel")
	_retirement_case("reset")
	_retirement_case("shutdown_retry")
	_check("all_observed_queue_bounds", _bounded)
	_check("poll_is_small_status_without_result", _small_status)
	_check("poll_responsive_100ms_guard_not_frame_budget", _max_poll_usec < RESPONSIVE_USEC)
	var failures: Array = []
	for name in _checks:
		if not _checks[name]: failures.append(name)
	var report := {"schema": "citadel-site-build-queue-contract/v1",
		"evidenceLevel": "source_only_synthetic_threaded_queue_contract",
		"complete": true, "passed": failures.is_empty(), "checks": _checks,
		"failures": failures, "trace": _trace, "maxPollUsec": _max_poll_usec,
		"elapsedUsec": Time.get_ticks_usec() - started, "engine": Engine.get_version_info(),
		"seed": SEED, "region": [REGION.x, REGION.y],
		"doesNotProve": ["Site.prepare execution or actual-site-source-05 equivalence",
			"live spawning, terrain, navigation, visuals, saves or gameplay",
			"production-stage cancellation latency or runtime frame budgets",
			"large-payload destruction cost or prepared-object conversion; retirement cases use small synthetic dictionaries",
			"exhaustive thread interleavings; only explicitly gated race boundaries"]}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print("CITADEL QUEUE SYNTHETIC CONTRACT: ", "PASS" if failures.is_empty() else "FAIL", " checks=", _checks.size())
	quit(0 if failures.is_empty() else 1)

func _alias_duplicate_consume() -> void:
	var q := SyntheticQueue.new()
	var towns := {Vector2i.ZERO: {"centerX": 0, "centerZ": 0, "radius": 27, "level": 10.0}, Vector2i(2, 2): {}}
	var policy := POLICY.duplicate(true)
	var ticket := q.submit(SEED, REGION, towns, policy)
	_check("submit_queued_identity", ticket.get("status") == "queued" and int(ticket.get("token", 0)) > 0 and ticket.has("epoch") and not String(ticket.get("sourceKey", "")).is_empty())
	var reordered := {Vector2i(2, 2): {}, Vector2i.ZERO: {"level": 10.0, "radius": 27, "centerZ": 0, "centerX": 0}}
	var duplicate := q.submit(SEED, REGION, reordered, {"spawnChance": 0.26, "regionCells": 140}, true)
	_check("duplicate_order_independent_same_identity", duplicate.get("status") == "duplicate" and duplicate.get("token") == ticket.get("token") and duplicate.get("sourceKey") == ticket.get("sourceKey") and duplicate.get("epoch") == ticket.get("epoch"))
	_check("active_started", _until(q, func(_s): return q.observed().size() == 1))
	towns[Vector2i.ZERO].radius = 77
	towns.clear()
	policy.regionCells = 999
	_check("pending_has_no_result", _take(q, ticket.token, "pending").is_empty())
	q.enter_gate.post()
	_check("alias_checkpoint_reached", _until(q, func(_s): return q.observed().size() == 2))
	var observed := q.observed()
	_check("request_deeply_immutable", observed.size() == 2 and observed[0].immutable)
	if observed.size() == 2:
		_check("submission_alias_isolation", _contains_pair(observed[1].request, "radius", 27) and _contains_pair(observed[1].request, "regionCells", 140) and not _contains_pair(observed[1].request, "radius", 77))
	q.exit_gate.post()
	_check("first_completion", _completed(q, ticket.token))
	_check("completed_duplicate", q.submit(SEED, REGION, reordered, POLICY).get("status") == "duplicate")
	var result := _take(q, ticket.token, "consumed")
	_check("result_deeply_immutable", not result.is_empty() and SyntheticQueue._frozen(result))
	if not q.retained_raw.payload.items[0].is_read_only():
		q.retained_raw.payload.items[0].value = 999
	_check("result_detached_from_worker_alias", q.retained_raw.payload.items[0].value == 999)
	_check("synthetic_payload_intact", result.get("payload") == {"items": [{"value": 17}]})
	_take(q, ticket.token, "stale_token")
	_check("consume_releases_completed_slot", int(_poll(q).get("completedToken", -1)) == 0)
	_finish(q, "alias")

func _validation() -> void:
	var q := SyntheticQueue.new()
	var cases := [
		["empty_seed", "", REGION, {}, POLICY],
		["region_overflow", SEED, Vector2i(2147483647, 0), {}, POLICY],
		["town_key", SEED, REGION, {"bad": {}}, POLICY],
		["town_radius", SEED, REGION, {Vector2i.ZERO: {"centerX": 0, "centerZ": 0, "radius": -1, "level": 0.0}}, POLICY],
		["town_nonfinite", SEED, REGION, {Vector2i.ZERO: {"centerX": 0, "centerZ": 0, "radius": 27, "level": NAN}}, POLICY],
		["policy_region", SEED, REGION, {}, {"regionCells": 1, "spawnChance": 0.26}],
		["policy_chance", SEED, REGION, {}, {"regionCells": 140, "spawnChance": NAN}],
		["policy_missing", SEED, REGION, {}, {}]]
	for item in cases:
		_check("invalid_" + item[0], q.submit(item[1], item[2], item[3], item[4]).get("status") == "failed")
	_check("invalid_never_dispatched", q.observed().is_empty() and int(_poll(q).get("pendingCount", -1)) == 0)
	_finish(q, "validation")

func _saturation_fairness() -> void:
	var q := SyntheticQueue.new()
	var active := q.submit(SEED, REGION, {}, POLICY)
	_check("saturation_active_started", _until(q, func(_s): return q.observed().size() == 1))
	var regular: Array[Dictionary] = []
	var priority: Array[Dictionary] = []
	for i in range(4):
		var ticket := q.submit(SEED + ":regular%d" % i, REGION, {}, POLICY)
		_check("regular_admitted_%d" % i, ticket.get("status") == "queued")
		regular.append(ticket)
	for i in range(4):
		var ticket := q.submit(SEED + ":priority%d" % i, REGION, {}, POLICY, true)
		_check("priority_admitted_%d" % i, ticket.get("status") == "queued")
		priority.append(ticket)
	_check("exact_eight_pending", int(_poll(q).get("pendingCount", -1)) == 8)
	_check("saturated_rejected", q.submit(SEED + ":overflow", REGION, {}, POLICY).get("status") == "failed")
	_check("saturated_duplicate_not_rejected", q.submit(SEED, REGION, {}, POLICY).get("status") == "duplicate")
	_release(q)
	_check("saturated_active_completes", _completed(q, active.token))
	var held := _poll(q)
	_check("completed_backpressure", int(held.get("completedToken", -1)) == active.token and int(held.get("pendingCount", -1)) == 8 and not held.get("workerRunning", true))
	_take(q, active.token, "consumed")
	# The implemented tie-break is canonical sourceKey, independent of submit order.
	regular.sort_custom(func(a, b): return a.sourceKey < b.sourceKey)
	priority.sort_custom(func(a, b): return a.sourceKey < b.sourceKey)
	var expected: Array[int] = [priority[0].token, priority[1].token, priority[2].token, regular[0].token, priority[3].token, regular[1].token, regular[2].token, regular[3].token]
	var order: Array[int] = []
	for token in expected:
		_check("dispatch_%d" % token, _until(q, func(s): return int(s.get("activeToken", -1)) > 0))
		order.append(int(_poll(q).get("activeToken", -1)))
		_release(q)
		_check("completion_%d" % token, _completed(q, order.back()))
		_take(q, order.back(), "consumed")
	_check("priority_source_key_ties_max_three_then_waiting_regular", order == expected)
	_trace.append({"case": "fairness", "expectedTokens": expected, "actualTokens": order})
	_finish(q, "fairness")

func _reset_same_seed() -> void:
	var q := SyntheticQueue.new()
	var old := q.submit(SEED, REGION, {}, POLICY)
	_check("reset_old_started", _until(q, func(_s): return q.observed().size() == 1))
	var pending := q.submit(SEED + ":pending", REGION, {}, POLICY)
	var started := Time.get_ticks_usec()
	var epoch := q.reset()
	_check("reset_responsive_and_new_epoch", Time.get_ticks_usec() - started < RESPONSIVE_USEC and epoch > old.epoch)
	_take(q, old.token, "stale_token")
	_take(q, pending.token, "stale_token")
	var fresh := q.submit(SEED, REGION, {}, POLICY)
	_check("same_seed_new_token_epoch_stable_source", fresh.get("status") == "queued" and fresh.token != old.token and fresh.epoch == epoch and fresh.sourceKey == old.sourceKey)
	var held := _poll(q)
	_check("reset_not_worker_termination", held.get("workerRunning") == true and held.get("workerJoined") == false)
	_release(q)
	_check("fresh_dispatched_after_stale_worker_drained", _until(q, func(s): return int(s.get("activeToken", -1)) == fresh.token))
	_take(q, old.token, "stale_token")
	_release(q)
	_check("fresh_completion", _completed(q, fresh.token))
	_take(q, fresh.token, "consumed")
	_finish(q, "reset")

func _cancel_races() -> void:
	var q := SyntheticQueue.new()
	var ticket := q.submit(SEED, REGION, {}, POLICY)
	_check("cancel_worker_started", _until(q, func(_s): return q.observed().size() == 1))
	var pending := q.submit(SEED + ":pending", REGION, {}, POLICY)
	_check("cancel_pending", q.cancel(pending.token))
	_take(q, pending.token, "stale_token")
	_check("cancel_active", q.cancel(ticket.token))
	_take(q, ticket.token, "pending")
	_check("unknown_cancel_false", not q.cancel(2147483647))
	q.enter_gate.post()
	_check("cancel_ack_observed", _until(q, func(_s): return q.observed().size() == 2))
	var observed := q.observed()
	var held := _poll(q)
	_check("cancellation_ack_is_not_termination", observed.size() == 2 and not observed[1].allowed and held.get("workerRunning") == true and held.get("workerJoined") == false)
	q.exit_gate.post()
	_check("cancelled_worker_eventually_joined", _until(q, func(s): return not s.get("workerRunning", true) and s.get("workerJoined", false)))
	_check("late_result_replaced_with_cancelled", _take(q, ticket.token, "consumed").get("status") == "cancelled")
	_take(q, ticket.token, "stale_token")
	var late := q.submit(SEED, REGION, {}, POLICY)
	_release(q)
	_check("late_cancel_completion_reached", _completed(q, late.token))
	_check("cancel_completed_before_consume", q.cancel(late.token))
	_check("completed_cancelled_result", _take(q, late.token, "consumed").get("status") == "cancelled")
	_take(q, late.token, "stale_token")
	_finish(q, "cancel")

func _start_failure() -> void:
	var q := SyntheticQueue.new()
	q.fail_start = true
	var ticket := q.submit(SEED, REGION, {}, POLICY)
	# Admission succeeds; the overridden thread launcher fails on dispatch in poll.
	_check("start_failure_admitted", ticket.get("status") == "queued")
	_check("start_failure_completion", _completed(q, int(ticket.get("token", -1))))
	var status := _poll(q)
	_check("start_failure_no_worker", not status.get("workerRunning", true) and status.get("completedStatus") == "failed" and q.observed().is_empty())
	_check("start_failure_result", _take(q, ticket.token, "consumed").get("status") == "failed")
	q.fail_start = false
	var retry := q.submit(SEED, REGION, {}, POLICY)
	_check("start_failure_reusable", retry.get("status") == "queued" and retry.token != ticket.token)
	_release(q)
	_check("retry_completes", _completed(q, retry.token))
	_take(q, retry.token, "consumed")
	_finish(q, "start_failure")

func _shutdown() -> void:
	var q := SyntheticQueue.new()
	var active := q.submit(SEED, REGION, {}, POLICY)
	_check("shutdown_worker_started", _until(q, func(_s): return q.observed().size() == 1))
	var pending := q.submit(SEED + ":pending", REGION, {}, POLICY)
	var started := Time.get_ticks_usec()
	q.request_shutdown()
	_check("shutdown_request_responsive", Time.get_ticks_usec() - started < RESPONSIVE_USEC)
	q.request_shutdown()
	_check("shutdown_rejects_submissions", q.submit(SEED, REGION, {}, POLICY).get("status") == "failed")
	_take(q, active.token, "stale_token")
	_take(q, pending.token, "stale_token")
	var held := _poll(q)
	_check("shutdown_waits_for_actual_termination", not held.get("shutdownComplete", true) and held.get("workerRunning") == true and held.get("workerJoined") == false and int(held.get("pendingCount", -1)) == 0)
	_finish(q, "shutdown")
	q.reset()
	_check("shutdown_terminal", q.submit(SEED, REGION, {}, POLICY).get("status") == "failed" and _poll(q).get("shutdownComplete") == true)

func _retirement_case(mode: String) -> void:
	var q := SyntheticQueue.new()
	var label := "retirement_" + mode
	var ticket := q.submit(SEED + ":" + label, REGION, {}, POLICY)
	_release(q)
	_check(label + "_source_completed", _completed(q, ticket.token))
	# White-box queue ownership check only. Release this temporary alias BEFORE
	# launching retirement; the fixture must not keep the payload alive for it.
	var original: Dictionary = q._completed.get("result", {})
	var original_bytes := var_to_bytes(original)
	_check(label + "_owns_frozen_payload", not original.is_empty() and SyntheticQueue._frozen(original))
	var started := Time.get_ticks_usec()
	if mode == "reset": q.reset()
	else: _check(label + "_cancel_completed", q.cancel(ticket.token))
	_check(label + "_enqueue_responsive", Time.get_ticks_usec() - started < RESPONSIVE_USEC)
	for i in range(3):
		if mode == "reset": q.reset()
		else: _check(label + "_repeat_cancel_%d" % i, q.cancel(ticket.token))
		_check(label + "_same_single_slot_%d" % i, is_same(q._retired, original) and var_to_bytes(q._retired) == original_bytes and q._retirement == null)
	if mode == "reset":
		_take(q, ticket.token, "stale_token")
	else:
		_check(label + "_terminal_slot_retained", q._completed.get("token") == ticket.token and q._completed.result.get("status") == "cancelled" and not q._completed.ownsWorkerPayload)
		_check(label + "_consume_terminal", _take(q, ticket.token, "consumed").get("status") == "cancelled")
	var next := q.submit(SEED + ":next:" + label, REGION, {}, POLICY, true)
	_check(label + "_next_queued", next.get("status") == "queued")
	if mode == "shutdown_retry":
		q.fail_start = true
		for i in range(3):
			var failed := _poll(q)
			_check(label + "_start_failure_retains_%d" % i, failed.get("retirementPending") == true and failed.get("retirementStartError") == ERR_CANT_CREATE and not failed.get("workerRunning", true) and failed.get("workerKind") == "" and failed.get("activeToken") == 0 and failed.get("pendingCount") == 1 and is_same(q._retired, original) and var_to_bytes(q._retired) == original_bytes and q.observed().size() == 2)
		for i in range(3):
			q.cancel(ticket.token)
			q.reset()
			q.request_shutdown()
			var failed := _poll(q)
			_check(label + "_repeated_close_retains_%d" % i, not failed.get("shutdownComplete", true) and failed.get("retirementPending") == true and failed.get("retirementStartError") == ERR_CANT_CREATE and failed.get("pendingCount") == 0 and is_same(q._retired, original) and var_to_bytes(q._retired) == original_bytes)
		_take(q, next.token, "stale_token")
	# Drop all test-held payload references before the real holder worker starts.
	original = {}
	q.fail_start = false
	var retiring := _poll(q)
	_check(label + "_retirement_dispatched_first", retiring.get("workerKind") == "retirement" and retiring.get("workerRunning") == true and retiring.get("retirementPending") == true and retiring.get("retirementStartError") == OK and retiring.get("activeToken") == 0 and q.observed().size() == 2)
	_check(label + "_one_holder_slot", q._retired.is_empty() and q._retirement != null)
	if mode == "shutdown_retry":
		_check(label + "_shutdown_not_complete_before_join", not retiring.get("shutdownComplete", true))
		_check(label + "_retry_drains_closed_queue", _until(q, func(s): return s.get("shutdownComplete", false) and s.get("workerJoined", false) and not s.get("retirementPending", true)))
	else:
		_check(label + "_source_still_pending_before_join", retiring.get("pendingCount") == 1)
		_take(q, next.token, "pending")
		# First new-source dispatch must occur in the poll that joins retirement.
		var resumed := {}
		var deadline := Time.get_ticks_usec() + WAIT_USEC
		while Time.get_ticks_usec() < deadline:
			resumed = _poll(q)
			if resumed.get("workerKind") == "source": break
			OS.delay_usec(1000)
		_check(label + "_source_only_after_retirement_join", resumed.get("activeToken") == next.token and resumed.get("workerKind") == "source" and resumed.get("workerJoined") == true and not resumed.get("retirementPending", true))
		_release(q)
		_check(label + "_next_completes", _completed(q, next.token))
		_take(q, next.token, "consumed")
	var drained := _poll(q)
	_check(label + "_released_on_non_owner_thread", int(drained.get("lastRetirementThreadId", -1)) > 0 and int(drained.get("lastRetirementThreadId", -1)) != OS.get_thread_caller_id())
	_check(label + "_empty_after_retirement_join", not drained.get("retirementPending", true) and q._retired.is_empty() and q._retirement == null)
	_trace.append({"case": label, "retirementDispatch": retiring, "afterJoin": drained})
	_finish(q, label)

func _poll(q: SyntheticQueue) -> Dictionary:
	var started := Time.get_ticks_usec()
	var status := q.poll()
	_max_poll_usec = maxi(_max_poll_usec, Time.get_ticks_usec() - started)
	_bounded = _bounded and int(status.get("pendingCount", -1)) >= 0 and int(status.get("pendingCount", 99)) <= 8
	_small_status = _small_status and not status.has("result") and var_to_bytes(status).size() < 4096
	for key in ["workerRunning", "workerJoined", "activeToken", "pendingCount", "completedToken", "completedStatus", "epoch", "shutdownComplete", "progress", "retirementPending", "retirementStartError", "workerKind", "maxRetirementWorkUsec", "lastRetirementThreadId"]:
		_small_status = _small_status and status.has(key)
	return status

func _until(q: SyntheticQueue, predicate: Callable) -> bool:
	var deadline := Time.get_ticks_usec() + WAIT_USEC
	while Time.get_ticks_usec() < deadline:
		if predicate.call(_poll(q)): return true
		OS.delay_usec(1000)
	return false

func _completed(q: SyntheticQueue, token: int) -> bool:
	return _until(q, func(s): return int(s.get("completedToken", -1)) == token and not s.get("workerRunning", true))

func _take(q: SyntheticQueue, token: int, expected: String) -> Dictionary:
	var value := q.take_result(token)
	_check("take_%d_%s_%d" % [token, expected, _checks.size()], value.get("status") == expected and value.get("token") == token and value.has("result") == (expected == "consumed"))
	if expected == "consumed":
		_check("consumed_identity_%d" % _checks.size(), value.has("epoch") and value.has("sourceKey"))
	return value.get("result", {})

func _release(q: SyntheticQueue) -> void:
	q.enter_gate.post()
	q.exit_gate.post()

func _finish(q: SyntheticQueue, label: String) -> void:
	q.request_shutdown()
	_release(q)
	var complete := _until(q, func(s): return s.get("shutdownComplete", false))
	_check(label + "_shutdown_drained", complete)
	_trace.append({"case": label, "status": _poll(q), "events": q.observed().size()})
	if not complete:
		# Do not destroy a queue with a live held worker; watchdog owns this failure.
		print("SYNTHETIC QUEUE DRAIN FAILED: ", label)
		quit(2)

func _contains_pair(value: Variant, key: String, expected: Variant) -> bool:
	if value is Dictionary:
		if value.get(key) == expected: return true
		for child in value.values():
			if _contains_pair(child, key, expected): return true
	elif value is Array:
		for child in value:
			if _contains_pair(child, key, expected): return true
	return false

func _check(name: String, passed: bool) -> void:
	_checks[name] = passed
	if not passed: print("CONTRACT FAILURE: ", name)
