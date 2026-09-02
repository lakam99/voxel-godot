extends RefCounted

## Generic private-state fixed-point driver. Domain callbacks remain the sole
## authority for eligibility and construction; this owns only deterministic
## ordering, monotone rejection exhaustion, hard-failure propagation and caps.
static func run(initial_state: Dictionary, discover: Callable, attempt: Callable, max_attempts: int) -> Dictionary:
	if not discover.is_valid() or not attempt.is_valid() or max_attempts < 1 or max_attempts > 1024:
		return _fail("invalid_completion_driver")
	var state := initial_state.duplicate(true)
	var attempted: Dictionary = {}
	var accepted: Array = []
	var rejected: Array = []
	var attempt_count := 0
	while attempt_count < max_attempts:
		var discovery: Variant = discover.call(state.duplicate(true))
		if not discovery is Dictionary or not discovery.get("ready") is bool or not discovery.ready or not discovery.get("candidateIds") is Array:
			return _hard("completion_discovery_failed", discovery)
		var candidates: Array = discovery.candidateIds.duplicate()
		var seen: Dictionary = {}
		for id: Variant in candidates:
			if not id is String or id.is_empty() or seen.has(id): return _hard("invalid_completion_candidates", discovery)
			seen[id] = true
		candidates.sort()
		var pending: Array = candidates.filter(func(id): return not attempted.has(id))
		if pending.is_empty():
			return {"ready": true, "exhausted": true, "state": state,
				"accepted": accepted, "rejected": rejected,
				"remainingCandidateIds": candidates, "attemptCount": attempt_count}
		var id: String = pending[0]
		attempted[id] = true
		var outcome: Variant = attempt.call(state.duplicate(true), id)
		attempt_count += 1
		if not outcome is Dictionary or not outcome.get("ready") is bool:
			return _hard("invalid_completion_attempt", outcome, id)
		if outcome.ready:
			if not outcome.get("afterState") is Dictionary:
				return _hard("completion_attempt_missing_state", outcome, id)
			state = outcome.afterState.duplicate(true)
			accepted.append(id)
		elif outcome.get("monotone") == true and outcome.get("reason") is String and not outcome.reason.is_empty():
			rejected.append({"panelId": id, "reason": outcome.reason})
		else:
			return _hard("completion_attempt_failed", outcome, id)
	return _fail("completion_attempt_limit")

static func _hard(reason: String, detail: Variant, id: String = "") -> Dictionary:
	var result := {"ready": false, "reason": reason, "detail": detail}
	if not id.is_empty(): result["candidateId"] = id
	return result

static func _fail(reason: String) -> Dictionary:
	return {"ready": false, "reason": reason}
