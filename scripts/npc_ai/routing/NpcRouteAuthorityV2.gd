extends RefCounted
class_name NpcRouteAuthorityV2

const RouteLeaseScript := preload("res://scripts/npc_ai/contracts/RouteLease.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const CollisionProbeServiceScript := preload("res://scripts/npc_ai/routing/CollisionProbeService.gd")
const NpcRouteStateStoreScript := preload("res://scripts/npc_ai/routing/NpcRouteStateStore.gd")

const DEFAULT_PROBE_SAMPLE_BUDGET_PER_FRAME := 160
const DEFAULT_PLAN_ATTEMPT_BUDGET_PER_FRAME := 4
const PLANNING_STARVATION_FRAME_LIMIT := 24
const PROBE_STARVATION_FRAME_LIMIT := 24
const MAX_PROBE_REPAIR_ATTEMPTS := 3
const INVALID_CELL := Vector2i(2147483000, 2147483000)

const STATE_NONE := "none"
const STATE_QUEUED := "queued"
const STATE_PENDING_NAV_DATA := "pending_nav_data"
const STATE_PENDING_BUDGET := "pending_budget"
const STATE_PROBING := "probing"
const STATE_READY := "ready"
const STATE_MOVING := "moving"
const STATE_BLOCKED_DYNAMIC := "blocked_dynamic"
const STATE_UNREACHABLE_STATIC := "unreachable_static"
const STATE_INVALID_GOAL := "invalid_goal"
const STATE_ARRIVED := "arrived"
const STATE_CANCELLED := "cancelled"

const PENDING_STATES := [STATE_QUEUED, STATE_PENDING_NAV_DATA, STATE_PENDING_BUDGET, STATE_PROBING]
const TERMINAL_STATES := [STATE_BLOCKED_DYNAMIC, STATE_UNREACHABLE_STATIC, STATE_INVALID_GOAL, STATE_ARRIVED, STATE_CANCELLED]

var frame_serial := 0
var request_sequence := 0
var actor_generations := {}
var active_request_by_actor := {}
var requests_by_id := {}
var registered_actors := {}
var actor_entries := {}
var system = null
var main = null
var collision_probe = null
var collision_probe_required := true
var plan_attempt_budget_per_frame := DEFAULT_PLAN_ATTEMPT_BUDGET_PER_FRAME
var plan_attempts_used_this_frame := 0
var planning_starvation_override_used_this_frame := false
var probe_sample_budget_per_frame := DEFAULT_PROBE_SAMPLE_BUDGET_PER_FRAME
var probe_samples_used_this_frame := 0
var probe_starvation_override_used_this_frame := false
var probe_cursors := {}
var counters := {
	"registeredActors": 0,
	"requests": 0,
	"planningBudgetGrants": 0,
	"planningBudgetDeferrals": 0,
	"planningStarvationOverrides": 0,
	"planningWaitFrames": 0,
	"queueWaitFrames": 0,
	"probeWaitFrames": 0,
	"maxPlanningWaitFrames": 0,
	"maxQueueWaitFrames": 0,
	"maxProbeWaitFrames": 0,
	"ready": 0,
	"moving": 0,
	"arrived": 0,
	"successfulArrivals": 0,
	"cancelled": 0,
	"blockedDynamic": 0,
	"dynamicBlocks": 0,
	"unreachableStatic": 0,
	"staticUnreachable": 0,
	"invalidGoal": 0,
	"routeRepairs": 0,
	"stuckRecovery": 0,
	"probePassed": 0,
	"probeFailed": 0,
	"probeSkipped": 0,
	"probeBudgetDeferrals": 0,
	"probeStarvationOverrides": 0
}

func setup(system_node, main_node, route_probe = null) -> void:
	system = system_node
	main = main_node
	if route_probe != null:
		collision_probe = route_probe
	else:
		collision_probe = CollisionProbeServiceScript.new()
		collision_probe.setup(system, main)

func begin_frame() -> void:
	frame_serial += 1
	plan_attempts_used_this_frame = 0
	planning_starvation_override_used_this_frame = false
	probe_samples_used_this_frame = 0
	probe_starvation_override_used_this_frame = false
	for request_id in requests_by_id.keys():
		var record: Dictionary = requests_by_id[request_id]
		if String(record.get("state", STATE_NONE)) in TERMINAL_STATES:
			continue
		_increment_state_frame(record)
		_observe_wait_counters(record)
		requests_by_id[request_id] = record

func register_actor(entry: Dictionary) -> Dictionary:
	var actor_id := actor_id_for_entry(entry)
	if actor_id == "":
		return { "ok": false, "reason": "missing_actor_id" }
	if not registered_actors.has(actor_id):
		registered_actors[actor_id] = true
		counters["registeredActors"] = int(counters.get("registeredActors", 0)) + 1
	actor_entries[actor_id] = entry
	var debug := debug_for_actor(actor_id)
	entry["routeAuthorityV2"] = debug
	return debug

func submit_request(entry: Dictionary, intent: Dictionary, options := {}) -> Dictionary:
	var actor_id := actor_id_for_entry(entry)
	if actor_id == "":
		return { "ok": false, "reason": "missing_actor_id" }
	register_actor(entry)
	request_sequence += 1
	var generation := int(actor_generations.get(actor_id, 0)) + 1
	actor_generations[actor_id] = generation
	var request_id := "%s:v2:%d:%d" % [actor_id, generation, request_sequence]
	var record := {
		"requestId": request_id,
		"actorId": actor_id,
		"generation": generation,
		"intent": intent.duplicate(true),
		"state": STATE_QUEUED,
		"reason": "queued",
		"priority": int(options.get("priority", intent.get("priority", 0))),
		"deadlineFrame": int(options.get("deadlineFrame", -1)),
		"createdFrame": frame_serial,
		"updatedFrame": frame_serial,
		"lastServicedFrame": -1,
		"stateFrameCounts": _empty_state_frame_counts(),
		"route": {},
		"routeLease": {},
		"routeProof": {},
		"events": [_event("queued", "queued")]
	}
	requests_by_id[request_id] = record
	active_request_by_actor[actor_id] = request_id
	counters["requests"] = int(counters.get("requests", 0)) + 1
	_publish_entry_debug(entry, record)
	return record_summary(record)

func mark_pending_budget(request_id: String, reason := "pending_budget") -> Dictionary:
	return transition_request(request_id, STATE_PENDING_BUDGET, reason)

func mark_pending_nav_data(request_id: String, reason := "pending_nav_data") -> Dictionary:
	return transition_request(request_id, STATE_PENDING_NAV_DATA, reason)

func mark_probing(request_id: String, reason := "probing") -> Dictionary:
	return transition_request(request_id, STATE_PROBING, reason)

func claim_planning_budget(request_id: String, reason := "planning") -> Dictionary:
	if not requests_by_id.has(request_id):
		return { "ok": false, "granted": false, "reason": "missing_request", "requestId": request_id }
	var record: Dictionary = requests_by_id[request_id]
	var state := String(record.get("state", STATE_NONE))
	if state in [STATE_READY, STATE_MOVING] or state in TERMINAL_STATES:
		return {
			"ok": true,
			"granted": true,
			"requestId": request_id,
			"state": state,
			"reason": "already_terminal_or_ready",
			"budget": _planning_budget_debug(record)
		}
	var wait_frames := _planning_wait_frames(record)
	var starvation_override := wait_frames >= PLANNING_STARVATION_FRAME_LIMIT and not planning_starvation_override_used_this_frame
	if plan_attempts_used_this_frame < plan_attempt_budget_per_frame or starvation_override:
		plan_attempts_used_this_frame += 1
		if starvation_override and plan_attempts_used_this_frame > plan_attempt_budget_per_frame:
			planning_starvation_override_used_this_frame = true
			counters["planningStarvationOverrides"] = int(counters.get("planningStarvationOverrides", 0)) + 1
		counters["planningBudgetGrants"] = int(counters.get("planningBudgetGrants", 0)) + 1
		_record_service_event(record, "planning_budget_granted", reason, {
			"waitFrames": wait_frames,
			"budgetPerFrame": plan_attempt_budget_per_frame,
			"usedThisFrame": plan_attempts_used_this_frame,
			"starvationOverride": starvation_override
		})
		requests_by_id[request_id] = record
		return {
			"ok": true,
			"granted": true,
			"requestId": request_id,
			"state": state,
			"reason": reason,
			"budget": _planning_budget_debug(record),
			"starvationOverride": starvation_override
		}
	counters["planningBudgetDeferrals"] = int(counters.get("planningBudgetDeferrals", 0)) + 1
	_transition_record(record, STATE_PENDING_BUDGET, "planning_budget")
	requests_by_id[request_id] = record
	_publish_record_to_entry(record)
	var summary := record_summary(record)
	summary["granted"] = false
	summary["budget"] = _planning_budget_debug(record)
	return summary

func mark_ready(request_id: String, route: Dictionary, proof := {}) -> Dictionary:
	if not requests_by_id.has(request_id):
		return { "ok": false, "reason": "missing_request", "requestId": request_id }
	var proof_dict: Dictionary = proof if proof is Dictionary else {}
	var certificate := _probe_certificate_from_proof(proof_dict)
	if collision_probe_required and not _probe_certificate_allows_ready(certificate):
		var current_record: Dictionary = requests_by_id[request_id]
		return {
			"ok": false,
			"reason": "missing_successful_probe_certificate",
			"requestId": request_id,
			"state": String(current_record.get("state", STATE_NONE)),
			"hasLease": false,
			"proof": proof_dict.duplicate(true)
		}
	var record: Dictionary = requests_by_id[request_id]
	var actor_id := String(record.get("actorId", ""))
	var generation := int(record.get("generation", 0))
	var route_copy := route.duplicate(true)
	route_copy["probeCertificate"] = certificate.duplicate(true)
	var lease = RouteLeaseScript.from_route(route_copy, actor_id, generation, NpcEnumsScript.ROUTE_AUTHORITY_READY, NpcEnumsScript.ROUTE_REASON_NONE)
	record["route"] = route_copy
	record["routeProof"] = proof_dict.duplicate(true)
	record["routeLease"] = lease.to_dictionary()
	_transition_record(record, STATE_READY, "ready")
	counters["ready"] = int(counters.get("ready", 0)) + 1
	requests_by_id[request_id] = record
	_publish_record_to_entry(record)
	return record_summary(record)

func commit_route_after_probe(entry: Dictionary, request_id: String, route: Dictionary, intent := {}, options := {}) -> Dictionary:
	if not requests_by_id.has(request_id):
		return { "ok": false, "reason": "missing_request", "requestId": request_id }
	var intent_dict: Dictionary = intent if intent is Dictionary else {}
	var route_copy := route.duplicate(true)
	var route_geometry := _validate_route_geometry(route_copy)
	if not bool(route_geometry.get("ok", false)):
		var invalid_proof := _route_proof(route_copy, {
			"ok": false,
			"status": "invalid_route_geometry",
			"reason": String(route_geometry.get("reason", "invalid_route_geometry")),
			"authoritative": true,
			"sampleCount": 0,
			"details": route_geometry
		})
		_record_probe_decision(request_id, route_copy, invalid_proof)
		return report_invalid_goal(request_id, String(route_geometry.get("reason", "invalid_route_geometry")))
	var repair_attempts := 0
	var repair_avoid_cells: Array = []
	while true:
		mark_probing(request_id, "collision_probe")
		var certificate := _probe_ready_route(entry, request_id, route_copy, intent_dict, options)
		var proof := _route_proof(route_copy, certificate)
		_record_probe_decision(request_id, route_copy, proof)
		if _probe_certificate_allows_ready(certificate):
			return mark_ready(request_id, route_copy, proof)
		var reason := String(certificate.get("reason", "collision_probe_failed"))
		if reason == "collision_probe_budget" or String(certificate.get("status", "")) == "pending_probe":
			return mark_probing(request_id, reason)
		if not bool(certificate.get("authoritative", false)) or String(certificate.get("status", "")) == "skipped":
			return mark_probing(request_id, reason)
		var state := _state_for_probe_certificate(certificate)
		if state == STATE_BLOCKED_DYNAMIC:
			return report_blocked_dynamic(request_id, reason)
		if state == STATE_INVALID_GOAL:
			return report_invalid_goal(request_id, reason)
		repair_avoid_cells = _merge_repair_avoid_cells(repair_avoid_cells, _probe_repair_avoid_cells(certificate))
		if _should_attempt_probe_repair(certificate, state, options, repair_attempts):
			var repaired_route := _plan_probe_repair_route(entry, request_id, route_copy, intent_dict, certificate, options, repair_avoid_cells, repair_attempts)
			if not repaired_route.is_empty() and bool(repaired_route.get("ok", false)):
				route_copy = repaired_route
				repair_attempts += 1
				continue
		return report_unreachable_static(request_id, reason)
	return report_unreachable_static(request_id, "probe_commit_exhausted")

func begin_moving(request_id: String, reason := "lease_following") -> Dictionary:
	if not requests_by_id.has(request_id):
		return { "ok": false, "reason": "missing_request", "requestId": request_id }
	var record: Dictionary = requests_by_id[request_id]
	if String(record.get("state", STATE_NONE)) != STATE_READY:
		return {
			"ok": false,
			"reason": "route_not_ready",
			"requestId": request_id,
			"state": String(record.get("state", STATE_NONE)),
			"hasLease": false
		}
	var result := transition_request(request_id, STATE_MOVING, reason)
	if bool(result.get("ok", false)):
		counters["moving"] = int(counters.get("moving", 0)) + 1
	return result

func report_arrived(request_id: String, reason := "arrived") -> Dictionary:
	var result := transition_request(request_id, STATE_ARRIVED, reason)
	if bool(result.get("ok", false)):
		counters["arrived"] = int(counters.get("arrived", 0)) + 1
		counters["successfulArrivals"] = int(counters.get("successfulArrivals", 0)) + 1
	return result

func report_segment_started(request_id: String, segment_index: int, details := {}) -> Dictionary:
	return report_execution_event(request_id, "segment_started", "segment_started", _execution_details_with_segment(segment_index, details))

func report_segment_completed(request_id: String, segment_index: int, details := {}) -> Dictionary:
	return report_execution_event(request_id, "segment_completed", "segment_completed", _execution_details_with_segment(segment_index, details))

func report_stuck(request_id: String, reason := "stuck", details := {}) -> Dictionary:
	var result := report_execution_event(request_id, "stuck", reason, details)
	if not bool(result.get("ok", false)):
		return result
	counters["stuckRecovery"] = int(counters.get("stuckRecovery", 0)) + 1
	if not requests_by_id.has(request_id):
		return result
	var record: Dictionary = requests_by_id[request_id]
	var state := String(record.get("state", STATE_NONE))
	if not (state in [STATE_READY, STATE_MOVING]):
		return result
	record.erase("routeLease")
	_transition_record(record, STATE_BLOCKED_DYNAMIC, reason)
	requests_by_id[request_id] = record
	_publish_record_to_entry(record)
	counters["blockedDynamic"] = int(counters.get("blockedDynamic", 0)) + 1
	counters["dynamicBlocks"] = int(counters.get("dynamicBlocks", 0)) + 1
	return record_summary(record)

func report_route_repair(request_id: String, reason := "route_repair", details := {}) -> Dictionary:
	var result := report_execution_event(request_id, "route_repair", reason, details)
	if bool(result.get("ok", false)):
		counters["routeRepairs"] = int(counters.get("routeRepairs", 0)) + 1
	return result

func report_unexpected_collision(request_id: String, reason := "unexpected_collision", details := {}) -> Dictionary:
	return report_execution_event(request_id, "unexpected_collision", reason, details)

func report_door_wait(request_id: String, reason := "door_wait", details := {}) -> Dictionary:
	return report_execution_event(request_id, "door_wait", reason, details)

func report_execution_event(request_id: String, event_type: String, reason := "", details := {}) -> Dictionary:
	if not requests_by_id.has(request_id):
		return { "ok": false, "reason": "missing_request", "requestId": request_id }
	var record: Dictionary = requests_by_id[request_id]
	var details_dict: Dictionary = details if details is Dictionary else {}
	var events: Array = record.get("events", []) if record.get("events", []) is Array else []
	events.append(_event("execution:%s" % event_type, reason, details_dict))
	record["events"] = events
	record["updatedFrame"] = frame_serial
	record["lastServicedFrame"] = frame_serial
	requests_by_id[request_id] = record
	return record_summary(record)

func report_blocked_dynamic(request_id: String, reason := "blocked_dynamic") -> Dictionary:
	var result := transition_request(request_id, STATE_BLOCKED_DYNAMIC, reason)
	if bool(result.get("ok", false)):
		counters["blockedDynamic"] = int(counters.get("blockedDynamic", 0)) + 1
		counters["dynamicBlocks"] = int(counters.get("dynamicBlocks", 0)) + 1
	return result

func report_unreachable_static(request_id: String, reason := "unreachable_static") -> Dictionary:
	var result := transition_request(request_id, STATE_UNREACHABLE_STATIC, reason)
	if bool(result.get("ok", false)):
		counters["unreachableStatic"] = int(counters.get("unreachableStatic", 0)) + 1
		counters["staticUnreachable"] = int(counters.get("staticUnreachable", 0)) + 1
	return result

func report_invalid_goal(request_id: String, reason := "invalid_goal") -> Dictionary:
	var result := transition_request(request_id, STATE_INVALID_GOAL, reason)
	if bool(result.get("ok", false)):
		counters["invalidGoal"] = int(counters.get("invalidGoal", 0)) + 1
	return result

func cancel_request(request_id: String, reason := "cancelled") -> Dictionary:
	var result := transition_request(request_id, STATE_CANCELLED, reason)
	if bool(result.get("ok", false)):
		counters["cancelled"] = int(counters.get("cancelled", 0)) + 1
	return result

func transition_request(request_id: String, state: String, reason := "") -> Dictionary:
	if not requests_by_id.has(request_id):
		return { "ok": false, "reason": "missing_request", "requestId": request_id }
	var record: Dictionary = requests_by_id[request_id]
	_transition_record(record, state, reason)
	requests_by_id[request_id] = record
	_publish_record_to_entry(record)
	return record_summary(record)

func debug_for_entry(entry: Dictionary) -> Dictionary:
	return debug_for_actor(actor_id_for_entry(entry))

func debug_for_actor(actor_id: String) -> Dictionary:
	if actor_id == "":
		return { "hasRequest": false, "state": STATE_NONE, "reason": "missing_actor_id" }
	var request_id := String(active_request_by_actor.get(actor_id, ""))
	if request_id != "" and requests_by_id.has(request_id):
		var record: Dictionary = requests_by_id[request_id]
		var summary := record_summary(record)
		summary["hasRequest"] = true
		return summary
	return {
		"hasRequest": false,
		"actorId": actor_id,
		"state": STATE_NONE,
		"reason": "no_active_request",
		"queuedFrames": 0,
		"pendingBudgetFrames": 0,
		"pendingNavDataFrames": 0,
		"pendingProbeFrames": 0,
		"lastServicedFrame": -1
	}

func debug_snapshot() -> Dictionary:
	var actors := {}
	for actor_id in registered_actors.keys():
		actors[actor_id] = debug_for_actor(String(actor_id))
	return {
		"frame": frame_serial,
		"actorCount": registered_actors.size(),
		"requestCount": requests_by_id.size(),
		"activeRequestCount": active_request_by_actor.size(),
		"counters": counters.duplicate(true),
		"planAttemptBudgetPerFrame": plan_attempt_budget_per_frame,
		"planAttemptsUsedThisFrame": plan_attempts_used_this_frame,
		"planningStarvationOverrideUsedThisFrame": planning_starvation_override_used_this_frame,
		"probeCursors": probe_cursors.size(),
		"probeSampleBudgetPerFrame": probe_sample_budget_per_frame,
		"probeSamplesUsedThisFrame": probe_samples_used_this_frame,
		"probeStarvationOverrideUsedThisFrame": probe_starvation_override_used_this_frame,
		"actors": actors
	}

func stats() -> Dictionary:
	return debug_snapshot()

func record_summary(record: Dictionary) -> Dictionary:
	var counts: Dictionary = record.get("stateFrameCounts", {}) if record.get("stateFrameCounts", {}) is Dictionary else {}
	var lease: Dictionary = record.get("routeLease", {}) if record.get("routeLease", {}) is Dictionary else {}
	var proof: Dictionary = record.get("routeProof", {}) if record.get("routeProof", {}) is Dictionary else {}
	var route: Dictionary = record.get("route", {}) if record.get("route", {}) is Dictionary else {}
	return {
		"ok": true,
		"requestId": String(record.get("requestId", "")),
		"actorId": String(record.get("actorId", "")),
		"generation": int(record.get("generation", 0)),
		"state": String(record.get("state", STATE_NONE)),
		"reason": String(record.get("reason", "")),
		"priority": int(record.get("priority", 0)),
		"createdFrame": int(record.get("createdFrame", 0)),
		"updatedFrame": int(record.get("updatedFrame", 0)),
		"lastServicedFrame": int(record.get("lastServicedFrame", -1)),
		"planningWaitFrames": _planning_wait_frames(record),
		"queuedFrames": int(counts.get(STATE_QUEUED, 0)),
		"pendingBudgetFrames": int(counts.get(STATE_PENDING_BUDGET, 0)),
		"pendingNavDataFrames": int(counts.get(STATE_PENDING_NAV_DATA, 0)),
		"pendingProbeFrames": int(counts.get(STATE_PROBING, 0)),
		"hasLease": not lease.is_empty(),
		"leaseId": String(lease.get("leaseId", "")),
		"routeLease": lease.duplicate(true),
		"route": _record_route_summary(route),
		"proof": proof.duplicate(true),
		"eventCount": (record.get("events", []) as Array).size() if record.get("events", []) is Array else 0,
		"recentEvents": _recent_events(record, 8)
	}

func _record_route_summary(route: Dictionary) -> Dictionary:
	if route.is_empty():
		return {}
	return {
		"ok": bool(route.get("ok", false)),
		"status": String(route.get("status", "")),
		"classification": String(route.get("classification", "")),
		"reason": String(route.get("reason", "")),
		"source": String(route.get("source", "")),
		"cells": (route.get("cells", []) as Array).duplicate() if route.get("cells", []) is Array else [],
		"waypoints": (route.get("waypoints", []) as Array).duplicate() if route.get("waypoints", []) is Array else [],
		"actions": (route.get("actions", {}) as Dictionary).duplicate(true) if route.get("actions", {}) is Dictionary else {},
		"targetCell": route.get("targetCell", INVALID_CELL),
		"snapshotRevision": String(route.get("snapshotRevision", "")),
		"probeRepair": (route.get("probeRepair", {}) as Dictionary).duplicate(true) if route.get("probeRepair", {}) is Dictionary else {}
	}

func _probe_ready_route(entry: Dictionary, request_id: String, route: Dictionary, intent: Dictionary, options := {}) -> Dictionary:
	if collision_probe == null:
		return {
			"ok": false,
			"status": "skipped",
			"reason": "missing_collision_probe_service",
			"authoritative": false,
			"sampleCount": 0,
			"details": {}
		}
	var requested_max_samples := int(options.get("maxSamples", probe_sample_budget_per_frame - probe_samples_used_this_frame))
	var max_samples := requested_max_samples
	var remaining_budget := maxi(0, max_samples)
	if remaining_budget <= 0:
		var probe_wait_frames := _request_state_wait_frames(request_id, STATE_PROBING)
		var starvation_override := probe_wait_frames >= PROBE_STARVATION_FRAME_LIMIT and not probe_starvation_override_used_this_frame
		if starvation_override:
			probe_starvation_override_used_this_frame = true
			remaining_budget = maxi(1, probe_sample_budget_per_frame)
			counters["probeStarvationOverrides"] = int(counters.get("probeStarvationOverrides", 0)) + 1
		else:
			counters["probeBudgetDeferrals"] = int(counters.get("probeBudgetDeferrals", 0)) + 1
			return {
				"ok": false,
				"status": "pending_probe",
				"reason": "collision_probe_budget",
				"authoritative": true,
				"sampleCount": 0,
				"details": {
					"budgetPerFrame": probe_sample_budget_per_frame,
					"samplesUsedThisFrame": probe_samples_used_this_frame,
					"probeWaitFrames": probe_wait_frames
				}
			}
	var cursor_key := _probe_cursor_key(request_id, route, intent)
	var cursor: Dictionary = probe_cursors.get(cursor_key, {}) if probe_cursors.get(cursor_key, {}) is Dictionary else {}
	var probe_options := options.duplicate(true)
	probe_options["maxSamples"] = remaining_budget
	probe_options["cursor"] = cursor
	var certificate: Dictionary = collision_probe.probe_route(entry, route, intent, probe_options)
	probe_samples_used_this_frame += int(certificate.get("sampleCount", 0))
	if String(certificate.get("reason", "")) == "collision_probe_budget":
		var next_cursor := _probe_cursor_from_certificate(certificate, cursor)
		if not next_cursor.is_empty():
			probe_cursors[cursor_key] = next_cursor
			certificate["details"] = _probe_details_with_cursor_key(certificate, cursor_key, next_cursor)
	else:
		probe_cursors.erase(cursor_key)
	if _probe_certificate_allows_ready(certificate):
		counters["probePassed"] = int(counters.get("probePassed", 0)) + 1
	elif String(certificate.get("status", "")) == "skipped":
		counters["probeSkipped"] = int(counters.get("probeSkipped", 0)) + 1
	else:
		counters["probeFailed"] = int(counters.get("probeFailed", 0)) + 1
	if String(certificate.get("reason", "")) == "collision_probe_budget":
		counters["probeBudgetDeferrals"] = int(counters.get("probeBudgetDeferrals", 0)) + 1
	return certificate

func _route_proof(route: Dictionary, certificate: Dictionary) -> Dictionary:
	return {
		"ok": _probe_certificate_allows_ready(certificate),
		"status": String(certificate.get("status", "")),
		"reason": String(certificate.get("reason", "")),
		"probeCertificate": certificate.duplicate(true),
		"doorProbeEdges": _door_probe_edges_from_route(route),
		"routeSource": String(route.get("source", "")),
		"snapshotRevision": String(route.get("snapshotRevision", "")),
		"collisionBacked": true,
		"authoritative": bool(certificate.get("authoritative", false))
	}

func _record_probe_decision(request_id: String, route: Dictionary, proof: Dictionary) -> void:
	if not requests_by_id.has(request_id):
		return
	var record: Dictionary = requests_by_id[request_id]
	var route_copy := route.duplicate(true)
	route_copy["probeCertificate"] = _probe_certificate_from_proof(proof)
	record["route"] = route_copy
	record["routeProof"] = proof.duplicate(true)
	requests_by_id[request_id] = record

func _validate_route_geometry(route: Dictionary) -> Dictionary:
	var waypoints: Array = route.get("waypoints", []) if route.get("waypoints", []) is Array else []
	if waypoints.is_empty():
		return {
			"ok": false,
			"reason": "invalid_route_geometry",
			"waypointCount": waypoints.size()
		}
	for waypoint in waypoints:
		if not (waypoint is Vector3):
			return {
				"ok": false,
				"reason": "invalid_route_geometry",
				"badWaypoint": str(waypoint)
			}
	return { "ok": true, "reason": "" }

func _probe_certificate_from_proof(proof: Dictionary) -> Dictionary:
	var certificate = proof.get("probeCertificate", proof)
	return certificate.duplicate(true) if certificate is Dictionary else {}

func _probe_certificate_allows_ready(certificate: Dictionary) -> bool:
	if certificate.is_empty():
		return false
	var status := String(certificate.get("status", ""))
	return bool(certificate.get("ok", false)) and bool(certificate.get("authoritative", false)) and status in ["passed", "clear"]

func _state_for_probe_certificate(certificate: Dictionary) -> String:
	var reason := String(certificate.get("reason", ""))
	var status := String(certificate.get("status", ""))
	if reason == "collision_probe_budget" or status == "pending_probe":
		return STATE_PROBING
	if reason in ["invalid_route_geometry", "empty_waypoints", "single_point_route"]:
		return STATE_INVALID_GOAL
	if reason in ["door_unavailable", "door_closed", "door_blocked", "door_clearance_blocked"]:
		return STATE_BLOCKED_DYNAMIC
	var details: Dictionary = certificate.get("details", {}) if certificate.get("details", {}) is Dictionary else {}
	var kind := String(details.get("kind", ""))
	var block_type := String(details.get("blockType", ""))
	var collider_class := String(details.get("class", ""))
	if kind in ["npc", "actor", "character"] or block_type in ["npc", "actor"] or collider_class in ["CharacterBody3D", "KinematicBody3D"]:
		return STATE_BLOCKED_DYNAMIC
	return STATE_UNREACHABLE_STATIC

func _should_attempt_probe_repair(certificate: Dictionary, state: String, options: Dictionary, repair_attempts: int) -> bool:
	if not bool(options.get("enableProbeRepair", true)):
		return false
	if state != STATE_UNREACHABLE_STATIC:
		return false
	if repair_attempts >= int(options.get("maxProbeRepairAttempts", MAX_PROBE_REPAIR_ATTEMPTS)):
		return false
	if options.get("repairSubstrate", null) == null:
		return false
	var reason := String(certificate.get("reason", ""))
	return reason in ["blocked_capsule_probe", "path_crosses_static_collision", "blocked_static_collision", "blocked_static_transition"]

func _plan_probe_repair_route(entry: Dictionary, request_id: String, failed_route: Dictionary, intent: Dictionary, certificate: Dictionary, options: Dictionary, repair_avoid_cells: Array, repair_attempts: int) -> Dictionary:
	var substrate = options.get("repairSubstrate", null)
	if substrate == null or not substrate.has_method("repair_route_after_probe"):
		return {}
	var start_cell: Vector2i = _cell_from_value(options.get("repairStartCell", INVALID_CELL))
	if start_cell == INVALID_CELL:
		_record_probe_repair_attempt(request_id, false, "missing_repair_start_cell", certificate, repair_avoid_cells, repair_attempts, {})
		return {}
	var candidate_cells: Array = options.get("repairCandidateCells", []) if options.get("repairCandidateCells", []) is Array else []
	if candidate_cells.is_empty():
		_record_probe_repair_attempt(request_id, false, "missing_repair_candidate_cells", certificate, repair_avoid_cells, repair_attempts, {})
		return {}
	var repair_plan_options: Dictionary = options.get("repairPlanOptions", {}) if options.get("repairPlanOptions", {}) is Dictionary else {}
	repair_plan_options = repair_plan_options.duplicate(true)
	repair_plan_options["probeRepairAttempt"] = repair_attempts + 1
	repair_plan_options["avoidCells"] = _merge_repair_avoid_cells(repair_plan_options.get("avoidCells", []), repair_avoid_cells)
	var repaired = substrate.call("repair_route_after_probe", entry, start_cell, candidate_cells, failed_route, certificate, repair_plan_options)
	var repaired_route: Dictionary = repaired if repaired is Dictionary else {}
	if repaired_route.is_empty() or not bool(repaired_route.get("ok", false)):
		_record_probe_repair_attempt(request_id, false, String(repaired_route.get("reason", "probe_repair_no_route")), certificate, repair_avoid_cells, repair_attempts, repaired_route)
		return {}
	_record_probe_repair_attempt(request_id, true, "probe_collision_repair", certificate, repair_avoid_cells, repair_attempts, {
		"targetCell": repaired_route.get("targetCell", INVALID_CELL),
		"cellCount": (repaired_route.get("cells", []) as Array).size() if repaired_route.get("cells", []) is Array else 0,
		"source": String(repaired_route.get("source", ""))
	})
	return repaired_route

func _record_probe_repair_attempt(request_id: String, ok: bool, reason: String, certificate: Dictionary, repair_avoid_cells: Array, repair_attempts: int, details := {}) -> void:
	if request_id == "" or not requests_by_id.has(request_id):
		return
	var event_details := {
		"ok": ok,
		"attempt": repair_attempts + 1,
		"blockedReason": String(certificate.get("reason", "")),
		"blockedCell": _cell_from_value((certificate.get("details", {}) as Dictionary).get("cell", INVALID_CELL)) if certificate.get("details", {}) is Dictionary else INVALID_CELL,
		"avoidCells": repair_avoid_cells.duplicate()
	}
	if details is Dictionary:
		for key in (details as Dictionary).keys():
			event_details[key] = (details as Dictionary).get(key)
	report_route_repair(request_id, reason, event_details)

func _probe_repair_avoid_cells(certificate: Dictionary) -> Array:
	var details: Dictionary = certificate.get("details", {}) if certificate.get("details", {}) is Dictionary else {}
	var blocked_cell := _cell_from_value(details.get("cell", INVALID_CELL))
	var result: Array = []
	_append_repair_avoid_cell(result, blocked_cell)
	_append_repair_avoid_cell(result, _cell_from_value(details.get("sample", INVALID_CELL)))
	return result

func _merge_repair_avoid_cells(first, second) -> Array:
	var result: Array = []
	if first is Array:
		for value in first:
			_append_repair_avoid_cell(result, _cell_from_value(value))
	if second is Array:
		for value in second:
			_append_repair_avoid_cell(result, _cell_from_value(value))
	return result

func _append_repair_avoid_cell(result: Array, cell: Vector2i) -> void:
	if cell == INVALID_CELL or result.has(cell):
		return
	result.append(cell)

func _cell_from_value(value) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Vector3:
		var position: Vector3 = value
		return Vector2i(roundi(position.x / NpcConstantsScript.CELL_SIZE), roundi(position.z / NpcConstantsScript.CELL_SIZE))
	if value is Dictionary:
		var dict: Dictionary = value
		return Vector2i(int(dict.get("x", 2147483000)), int(dict.get("z", dict.get("y", 2147483000))))
	if value is Array and (value as Array).size() >= 2:
		var array_value: Array = value
		return Vector2i(int(array_value[0]), int(array_value[1]))
	return INVALID_CELL

func _door_probe_edges_from_route(route: Dictionary) -> Array:
	var result: Array = []
	var proof: Dictionary = route.get("proof", {}) if route.get("proof", {}) is Dictionary else {}
	for edge_value in proof.get("doorEdges", []):
		if edge_value is Dictionary:
			var edge: Dictionary = edge_value
			result.append({
				"fromCell": edge.get("fromCell", Vector2i(999999, 999999)),
				"toCell": edge.get("toCell", Vector2i(999999, 999999)),
				"door": edge.get("door", {}),
				"checks": ["approach_side", "door_open_state", "crossing_clearance", "destination_side", "threshold_clearance"]
			})
	var actions: Dictionary = route.get("actions", {}) if route.get("actions", {}) is Dictionary else {}
	var action_keys := actions.keys()
	action_keys.sort()
	for key in action_keys:
		var action_value = actions.get(key)
		if not (action_value is Dictionary):
			continue
		var action: Dictionary = action_value
		if String(action.get("kind", "")) != "door":
			continue
		result.append({
			"actionKey": String(key),
			"portalId": String(action.get("portalId", action.get("portal_id", ""))),
			"checks": ["approach_side", "door_open_state", "crossing_clearance", "destination_side", "threshold_clearance"]
		})
	return result

func _probe_cursor_key(request_id: String, route: Dictionary, intent: Dictionary) -> String:
	var parts := PackedStringArray()
	parts.append(request_id)
	parts.append(String(intent.get("kind", "move")))
	parts.append(_probe_cell_key(intent.get("targetCell", route.get("targetCell", Vector2i(999999, 999999)))))
	parts.append(String(route.get("source", "")))
	parts.append(String(route.get("snapshotRevision", "")))
	var waypoints: Array = route.get("waypoints", []) if route.get("waypoints", []) is Array else []
	for waypoint_value in waypoints:
		if waypoint_value is Vector3:
			var waypoint: Vector3 = waypoint_value
			parts.append("%.3f,%.3f,%.3f" % [waypoint.x, waypoint.y, waypoint.z])
	return "|".join(parts)

func _probe_cell_key(value) -> String:
	if value is Vector2i:
		var cell: Vector2i = value
		return "%d,%d" % [cell.x, cell.y]
	return str(value)

func _probe_cursor_from_certificate(certificate: Dictionary, previous_cursor := {}) -> Dictionary:
	var details: Dictionary = certificate.get("details", {}) if certificate.get("details", {}) is Dictionary else {}
	var cursor: Dictionary = details.get("cursor", {}) if details.get("cursor", {}) is Dictionary else {}
	if not cursor.is_empty():
		return cursor.duplicate(true)
	if previous_cursor is Dictionary and not (previous_cursor as Dictionary).is_empty():
		var merged: Dictionary = (previous_cursor as Dictionary).duplicate(true)
		merged["completedSamples"] = int(details.get("completedSamples", merged.get("completedSamples", 0)))
		return merged
	return {}

func _probe_details_with_cursor_key(certificate: Dictionary, cursor_key: String, cursor: Dictionary) -> Dictionary:
	var details: Dictionary = certificate.get("details", {}) if certificate.get("details", {}) is Dictionary else {}
	var result := details.duplicate(true)
	result["cursorKey"] = cursor_key
	result["cursor"] = cursor.duplicate(true)
	return result

func actor_id_for_entry(entry: Dictionary) -> String:
	var actor_id := String(entry.get("id", ""))
	if actor_id != "":
		return actor_id
	var body := entry.get("body") as Node
	if body != null and is_instance_valid(body):
		return str(body.get_instance_id())
	return ""

func _transition_record(record: Dictionary, state: String, reason: String) -> void:
	_increment_state_frame(record)
	record["state"] = state
	record["reason"] = reason
	record["updatedFrame"] = frame_serial
	record["lastServicedFrame"] = frame_serial
	var events: Array = record.get("events", []) if record.get("events", []) is Array else []
	events.append(_event(state, reason))
	record["events"] = events

func _increment_state_frame(record: Dictionary) -> void:
	var state := String(record.get("state", STATE_NONE))
	if not (state in PENDING_STATES):
		return
	var counts: Dictionary = record.get("stateFrameCounts", {}) if record.get("stateFrameCounts", {}) is Dictionary else _empty_state_frame_counts()
	counts[state] = int(counts.get(state, 0)) + 1
	record["stateFrameCounts"] = counts

func _empty_state_frame_counts() -> Dictionary:
	return {
		STATE_QUEUED: 0,
		STATE_PENDING_BUDGET: 0,
		STATE_PENDING_NAV_DATA: 0,
		STATE_PROBING: 0
	}

func _execution_details_with_segment(segment_index: int, details) -> Dictionary:
	var result: Dictionary = details.duplicate(true) if details is Dictionary else {}
	result["segmentIndex"] = segment_index
	return result

func _record_service_event(record: Dictionary, event_state: String, reason: String, details := {}) -> void:
	var events: Array = record.get("events", []) if record.get("events", []) is Array else []
	events.append(_event(event_state, reason, details))
	record["events"] = events
	record["updatedFrame"] = frame_serial
	record["lastServicedFrame"] = frame_serial

func _observe_wait_counters(record: Dictionary) -> void:
	var state := String(record.get("state", STATE_NONE))
	if state == STATE_QUEUED:
		counters["queueWaitFrames"] = int(counters.get("queueWaitFrames", 0)) + 1
		_set_counter_max("maxQueueWaitFrames", _request_state_wait_frames(String(record.get("requestId", "")), STATE_QUEUED, record))
	if state in [STATE_QUEUED, STATE_PENDING_BUDGET, STATE_PENDING_NAV_DATA]:
		counters["planningWaitFrames"] = int(counters.get("planningWaitFrames", 0)) + 1
		_set_counter_max("maxPlanningWaitFrames", _planning_wait_frames(record))
	if state == STATE_PROBING:
		counters["probeWaitFrames"] = int(counters.get("probeWaitFrames", 0)) + 1
		_set_counter_max("maxProbeWaitFrames", _request_state_wait_frames(String(record.get("requestId", "")), STATE_PROBING, record))

func _set_counter_max(counter_name: String, value: int) -> void:
	counters[counter_name] = maxi(int(counters.get(counter_name, 0)), value)

func _planning_wait_frames(record: Dictionary) -> int:
	var counts: Dictionary = record.get("stateFrameCounts", {}) if record.get("stateFrameCounts", {}) is Dictionary else {}
	return int(counts.get(STATE_QUEUED, 0)) + int(counts.get(STATE_PENDING_BUDGET, 0)) + int(counts.get(STATE_PENDING_NAV_DATA, 0))

func _request_state_wait_frames(request_id: String, state: String, record_override := {}) -> int:
	var record: Dictionary = record_override if record_override is Dictionary and not (record_override as Dictionary).is_empty() else {}
	if record.is_empty() and requests_by_id.has(request_id):
		record = requests_by_id[request_id]
	var counts: Dictionary = record.get("stateFrameCounts", {}) if record.get("stateFrameCounts", {}) is Dictionary else {}
	return int(counts.get(state, 0))

func _planning_budget_debug(record: Dictionary) -> Dictionary:
	return {
		"budgetPerFrame": plan_attempt_budget_per_frame,
		"usedThisFrame": plan_attempts_used_this_frame,
		"planningWaitFrames": _planning_wait_frames(record),
		"starvationFrameLimit": PLANNING_STARVATION_FRAME_LIMIT
	}

func _recent_events(record: Dictionary, limit: int) -> Array:
	var events: Array = record.get("events", []) if record.get("events", []) is Array else []
	if events.size() <= limit:
		return events.duplicate(true)
	return events.slice(events.size() - limit, events.size()).duplicate(true)

func _event(state: String, reason: String, details := {}) -> Dictionary:
	var result := {
		"frame": frame_serial,
		"state": state,
		"reason": reason
	}
	if details is Dictionary and not (details as Dictionary).is_empty():
		result["details"] = (details as Dictionary).duplicate(true)
	return result

func _publish_entry_debug(entry: Dictionary, record: Dictionary) -> void:
	if entry.is_empty():
		return
	var summary := record_summary(record)
	entry["routeAuthorityV2"] = summary
	NpcRouteStateStoreScript.write_status(entry, _legacy_route_status_for_state(String(record.get("state", STATE_NONE))), String(record.get("reason", "")), "NpcRouteAuthorityV2")
	var lease: Dictionary = record.get("routeLease", {}) if record.get("routeLease", {}) is Dictionary else {}
	if lease.is_empty():
		NpcRouteStateStoreScript.clear_route_lease(entry, "NpcRouteAuthorityV2")
	else:
		NpcRouteStateStoreScript.write_route_lease(entry, lease, String(lease.get("leaseId", "")), lease.get("generation", null), "NpcRouteAuthorityV2")


func _publish_record_to_entry(record: Dictionary) -> void:
	var actor_id := String(record.get("actorId", ""))
	var entry = actor_entries.get(actor_id)
	if entry is Dictionary:
		_publish_entry_debug(entry, record)


func _legacy_route_status_for_state(state: String) -> String:
	if state in [STATE_QUEUED, STATE_PENDING_NAV_DATA, STATE_PENDING_BUDGET, STATE_PROBING]:
		return "pending"
	if state in [STATE_READY, STATE_MOVING]:
		return "moving"
	if state == STATE_ARRIVED:
		return "arrived"
	if state == STATE_UNREACHABLE_STATIC:
		return "unreachable"
	if state in [STATE_BLOCKED_DYNAMIC, STATE_INVALID_GOAL]:
		return "blocked"
	if state == STATE_CANCELLED:
		return "idle"
	return "idle"
