extends RefCounted
class_name LiveRoutePlanningProgressWatchdog

var started_at_seconds := 0.0
var last_progress_at_seconds := 0.0
var soft_timeout_seconds := 4.0
var no_progress_timeout_seconds := 4.0
var hard_timeout_seconds := 30.0
var last_marker := {}

func setup(started_at: float, soft_timeout: float, no_progress_timeout: float, hard_timeout: float) -> void:
	started_at_seconds = started_at
	last_progress_at_seconds = started_at
	soft_timeout_seconds = maxf(0.1, soft_timeout)
	no_progress_timeout_seconds = maxf(0.1, no_progress_timeout)
	hard_timeout_seconds = maxf(soft_timeout_seconds, hard_timeout)
	last_marker = {}

func observe(result: Dictionary, now_seconds: float) -> Dictionary:
	var marker := progress_marker(result)
	var progressed := last_marker.is_empty() or marker_advanced(last_marker, marker)
	if progressed:
		last_progress_at_seconds = now_seconds
	last_marker = marker.duplicate(true)
	var elapsed := maxf(0.0, now_seconds - started_at_seconds)
	var no_progress_elapsed := maxf(0.0, now_seconds - last_progress_at_seconds)
	var soft_exceeded := elapsed >= soft_timeout_seconds
	var decision := {
		"continue": true,
		"reason": "progressing" if progressed else "waiting_for_progress",
		"progressed": progressed,
		"softExceeded": soft_exceeded,
		"elapsedSeconds": elapsed,
		"noProgressSeconds": no_progress_elapsed,
		"softTimeoutSeconds": soft_timeout_seconds,
		"noProgressTimeoutSeconds": no_progress_timeout_seconds,
		"hardTimeoutSeconds": hard_timeout_seconds,
		"marker": marker
	}
	if elapsed >= hard_timeout_seconds:
		decision["continue"] = false
		decision["reason"] = "hard_timeout"
	elif soft_exceeded and no_progress_elapsed >= no_progress_timeout_seconds:
		decision["continue"] = false
		decision["reason"] = "no_progress_timeout"
	return decision

func progress_marker(result: Dictionary) -> Dictionary:
	var authority: Dictionary = result.get("authority", {}) if result.get("authority", {}) is Dictionary else {}
	var details: Dictionary = result.get("details", {}) if result.get("details", {}) is Dictionary else {}
	var route: Dictionary = details.get("route", {}) if details.get("route", {}) is Dictionary else {}
	if route.is_empty() and result.get("routeSummary", {}) is Dictionary:
		route = result.get("routeSummary", {})
	var candidates: Dictionary = details.get("candidatePoses", {}) if details.get("candidatePoses", {}) is Dictionary else {}
	var candidate_progress: Dictionary = candidates.get("candidateProgress", {}) if candidates.get("candidateProgress", {}) is Dictionary else {}
	var repair_avoids: Array = authority.get("probeRepairAvoidCells", []) if authority.get("probeRepairAvoidCells", []) is Array else []
	return {
		"requestId": String(result.get("requestId", authority.get("requestId", ""))),
		"state": String(result.get("status", authority.get("state", ""))),
		"reason": String(result.get("reason", authority.get("reason", ""))),
		"candidateValidated": int(candidate_progress.get("validated", 0)),
		"candidateTotal": int(candidate_progress.get("total", 0)),
		"searchExpansions": int(route.get("searchExpansions", 0)),
		"searchVisited": int(route.get("searchVisited", 0)),
		"probeSamples": int(route.get("probeSamples", 0)),
		"repairAttempt": int(route.get("repairAttempt", 0)),
		"repairAvoidCount": repair_avoids.size(),
		"lastServicedFrame": int(authority.get("lastServicedFrame", -1)),
		"pendingBudgetFrames": int(authority.get("pendingBudgetFrames", 0)),
		"pendingProbeFrames": int(authority.get("pendingProbeFrames", 0))
	}

func marker_advanced(previous: Dictionary, current: Dictionary) -> bool:
	var previous_request := String(previous.get("requestId", ""))
	var current_request := String(current.get("requestId", ""))
	if current_request != "" and current_request != previous_request:
		return true
	if String(current.get("state", "")) != String(previous.get("state", "")):
		return true
	for key in ["candidateValidated", "searchExpansions", "searchVisited", "probeSamples", "repairAttempt", "repairAvoidCount"]:
		if int(current.get(key, 0)) > int(previous.get(key, 0)):
			return true
	return false
