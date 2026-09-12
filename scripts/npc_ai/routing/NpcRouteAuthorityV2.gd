extends RefCounted
class_name NpcRouteAuthorityV2

const RouteLeaseScript := preload("res://scripts/npc_ai/contracts/RouteLease.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const CollisionProbeServiceScript := preload("res://scripts/npc_ai/routing/CollisionProbeService.gd")
const NpcRouteStateStoreScript := preload("res://scripts/npc_ai/routing/NpcRouteStateStore.gd")

const DEFAULT_PROBE_SAMPLE_BUDGET_PER_FRAME := 160
const DEFAULT_PLAN_ATTEMPT_BUDGET_PER_FRAME := 4
const DEFAULT_ROUTE_SEARCH_EXPANSION_BUDGET_PER_FRAME := 64
const DEFAULT_ROUTE_SEARCH_EXPANSIONS_PER_REQUEST := 16
const URGENT_ROUTE_PRIORITY := 180
const URGENT_ROUTE_SEARCH_EXPANSIONS_PER_REQUEST := 48
const PLANNING_STARVATION_FRAME_LIMIT := 24
const PROBE_STARVATION_FRAME_LIMIT := 24
const MAX_PROBE_REPAIR_ATTEMPTS := 3
# Collision probes see live CharacterBody3D actors. Keep one cell of clearance when
# repairing around one so the replacement route is not committed into the same body.
const DYNAMIC_PROBE_REPAIR_AVOID_RADIUS := 1
const MAX_REQUEST_EVENTS := 64
const PENDING_STALL_TRACE_WALL_MSEC := 8000
const STALL_TRACE_PATH := "user://npc_route_stall_trace.json"
const SCRIPTED_ORDER_STALL_TRACE_PATH := "user://npc_scripted_order_stall_trace.json"
const COLLISION_RECOVERY_STALL_TRACE_PATH := "user://npc_route_collision_recovery_stall_trace.json"
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
var planning_grants_this_frame := {}
var planning_claimed_this_frame := {}
var planning_grants_prepared_frame := -1
var route_search_expansion_budget_per_frame := DEFAULT_ROUTE_SEARCH_EXPANSION_BUDGET_PER_FRAME
var route_search_expansions_used_this_frame := 0
var probe_sample_budget_per_frame := DEFAULT_PROBE_SAMPLE_BUDGET_PER_FRAME
var probe_samples_used_this_frame := 0
var probe_starvation_override_used_this_frame := false
var probe_cursors := {}
var pending_stall_trace_records: Array = []
var scripted_order_stall_trace_records: Array = []
var collision_recovery_stalls_by_actor := {}
var collision_recovery_stall_trace_records: Array = []
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
	"collisionRecoveryStallTraceCaptures": 0,
	"probeBudgetDeferrals": 0,
	"probeStarvationOverrides": 0,
	"pendingStallTraceCaptures": 0,
	"scriptedOrderStallTraceCaptures": 0
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
	route_search_expansions_used_this_frame = 0
	planning_starvation_override_used_this_frame = false
	planning_grants_this_frame.clear()
	planning_claimed_this_frame.clear()
	planning_grants_prepared_frame = -1
	probe_samples_used_this_frame = 0
	probe_starvation_override_used_this_frame = false
	for request_id in requests_by_id.keys():
		var record: Dictionary = requests_by_id[request_id]
		if String(record.get("state", STATE_NONE)) in TERMINAL_STATES:
			continue
		_increment_state_frame(record)
		_observe_wait_counters(record)
		_maybe_capture_pending_stall_trace(record)
		requests_by_id[request_id] = record
	for actor_id_value in actor_entries.keys():
		var actor_id := String(actor_id_value)
		var entry_value = actor_entries.get(actor_id, {})
		if entry_value is Dictionary:
			_maybe_capture_scripted_order_stall_trace(actor_id, entry_value)
	_prepare_planning_grants()

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
		"maxExpansionsPerPlanningSlice": maxi(0, int(options.get("maxExpansionsPerPlanningSlice", 0))),
		"deadlineFrame": int(options.get("deadlineFrame", -1)),
		"createdFrame": frame_serial,
		"createdWallMsec": Time.get_ticks_msec(),
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
	if planning_grants_prepared_frame == frame_serial:
		_prepare_planning_grants()
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
	_ensure_planning_grants()
	var grant: Dictionary = planning_grants_this_frame.get(request_id, {}) if planning_grants_this_frame.get(request_id, {}) is Dictionary else {}
	var wait_frames := _planning_wait_frames(record)
	var starvation_override := bool(grant.get("starvationOverride", false))
	var route_search_expansions := maxi(1, int(grant.get("routeSearchExpansions", DEFAULT_ROUTE_SEARCH_EXPANSIONS_PER_REQUEST)))
	if not grant.is_empty() and plan_attempts_used_this_frame < plan_attempt_budget_per_frame and route_search_expansions_used_this_frame + route_search_expansions <= route_search_expansion_budget_per_frame:
		planning_grants_this_frame.erase(request_id)
		planning_claimed_this_frame[request_id] = true
		plan_attempts_used_this_frame += 1
		route_search_expansions_used_this_frame += route_search_expansions
		if starvation_override:
			planning_starvation_override_used_this_frame = true
			counters["planningStarvationOverrides"] = int(counters.get("planningStarvationOverrides", 0)) + 1
		counters["planningBudgetGrants"] = int(counters.get("planningBudgetGrants", 0)) + 1
		_record_service_event(record, "planning_budget_granted", reason, {
			"waitFrames": wait_frames,
			"budgetPerFrame": plan_attempt_budget_per_frame,
			"usedThisFrame": plan_attempts_used_this_frame,
			"routeSearchExpansions": route_search_expansions,
			"routeSearchExpansionBudgetPerFrame": route_search_expansion_budget_per_frame,
			"routeSearchExpansionsUsedThisFrame": route_search_expansions_used_this_frame,
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
			"routeSearchExpansions": route_search_expansions,
			"starvationOverride": starvation_override
		}
	counters["planningBudgetDeferrals"] = int(counters.get("planningBudgetDeferrals", 0)) + 1
	_mark_planning_deferred(record)
	requests_by_id[request_id] = record
	_publish_record_to_entry(record)
	var summary := record_summary(record)
	summary["granted"] = false
	summary["budget"] = _planning_budget_debug(record)
	return summary

func _ensure_planning_grants() -> void:
	if planning_grants_prepared_frame != frame_serial:
		_prepare_planning_grants()

func _prepare_planning_grants() -> void:
	planning_grants_prepared_frame = frame_serial
	planning_grants_this_frame.clear()
	var available_attempts := maxi(0, plan_attempt_budget_per_frame - plan_attempts_used_this_frame)
	var available_expansions := maxi(0, route_search_expansion_budget_per_frame - route_search_expansions_used_this_frame)
	if available_attempts == 0 or available_expansions == 0:
		return
	var eligible: Array[Dictionary] = []
	for request_id in requests_by_id.keys():
		if planning_claimed_this_frame.has(request_id):
			continue
		var record: Dictionary = requests_by_id[request_id]
		var actor_id := String(record.get("actorId", ""))
		if String(active_request_by_actor.get(actor_id, "")) != String(request_id):
			continue
		if not String(record.get("state", STATE_NONE)) in [STATE_QUEUED, STATE_PENDING_NAV_DATA, STATE_PENDING_BUDGET]:
			continue
		eligible.append(record)
	if eligible.is_empty():
		return
	eligible.sort_custom(Callable(self, "_planning_record_precedes"))
	var remaining := eligible.duplicate()
	var starved_record := _most_starved_planning_record(remaining)
	var starvation_override_id := String(starved_record.get("requestId", ""))
	var ordinary_record := _first_ordinary_planning_record(remaining, starved_record)

	# Preserve the former 64-expansion global cap. Reserve one normal slice whenever
	# ordinary work is waiting; divide the rest between selected urgent requests so
	# a busy scripted moment continues to service every active actor fairly.
	if not ordinary_record.is_empty() and available_attempts > 0 and available_expansions > 0:
		var ordinary_slice := _planning_slice_for_record(ordinary_record, available_expansions)
		_grant_planning_slice(ordinary_record, ordinary_slice, String(ordinary_record.get("requestId", "")) == starvation_override_id)
		_remove_planning_record(remaining, String(ordinary_record.get("requestId", "")))
		available_attempts -= 1
		available_expansions -= ordinary_slice
	var urgent_records := _selected_urgent_planning_records(remaining, starved_record, available_attempts)
	if not urgent_records.is_empty() and available_expansions > 0:
		var urgent_count := urgent_records.size()
		var base_urgent_slice := int(available_expansions / urgent_count)
		var urgent_remainder := available_expansions % urgent_count
		for index in range(urgent_count):
			var urgent_record: Dictionary = urgent_records[index]
			var urgent_slice := base_urgent_slice + (1 if index < urgent_remainder else 0)
			var urgent_cap := int(urgent_record.get("maxExpansionsPerPlanningSlice", 0))
			if urgent_cap > 0:
				urgent_slice = mini(urgent_slice, urgent_cap)
			_grant_planning_slice(urgent_record, urgent_slice, String(urgent_record.get("requestId", "")) == starvation_override_id)
			_remove_planning_record(remaining, String(urgent_record.get("requestId", "")))
			available_attempts -= 1
			available_expansions -= urgent_slice
	while urgent_records.is_empty() and available_attempts > 0 and available_expansions > 0 and not remaining.is_empty():
		var record: Dictionary = remaining[0]
		var slice := _planning_slice_for_record(record, available_expansions)
		_grant_planning_slice(record, slice, String(record.get("requestId", "")) == starvation_override_id)
		remaining.remove_at(0)
		available_attempts -= 1
		available_expansions -= slice

func _most_starved_planning_record(records: Array) -> Dictionary:
	var starved: Array[Dictionary] = []
	for record_value in records:
		if record_value is Dictionary and _is_starved_planning_record(record_value):
			starved.append(record_value)
	if starved.is_empty():
		return {}
	starved.sort_custom(Callable(self, "_planning_starved_precedes"))
	return starved[0]

func _selected_urgent_planning_records(records: Array, starved_record: Dictionary, maximum_count: int) -> Array[Dictionary]:
	var selected: Array[Dictionary] = []
	if maximum_count <= 0:
		return selected
	if not starved_record.is_empty() and int(starved_record.get("priority", 0)) >= URGENT_ROUTE_PRIORITY:
		selected.append(starved_record)
	for record_value in records:
		if not record_value is Dictionary or int(record_value.get("priority", 0)) < URGENT_ROUTE_PRIORITY:
			continue
		if String(record_value.get("requestId", "")) == String(starved_record.get("requestId", "")):
			continue
		selected.append(record_value)
		if selected.size() >= maximum_count:
			break
	return selected

func _first_ordinary_planning_record(records: Array, starved_record: Dictionary) -> Dictionary:
	if not starved_record.is_empty() and int(starved_record.get("priority", 0)) < URGENT_ROUTE_PRIORITY:
		return starved_record
	for record_value in records:
		if record_value is Dictionary and int(record_value.get("priority", 0)) < URGENT_ROUTE_PRIORITY:
			return record_value
	return {}

func _is_starved_planning_record(record: Dictionary) -> bool:
	return _planning_service_age(record) >= PLANNING_STARVATION_FRAME_LIMIT

func _planning_slice_for_record(record: Dictionary, available_expansions: int) -> int:
	var requested := int(record.get("maxExpansionsPerPlanningSlice", 0))
	if requested <= 0:
		requested = DEFAULT_ROUTE_SEARCH_EXPANSIONS_PER_REQUEST
	return mini(requested, available_expansions)


func _grant_planning_slice(record: Dictionary, route_search_expansions: int, starvation_override: bool) -> void:
	var request_id := String(record.get("requestId", ""))
	if request_id == "":
		return
	planning_grants_this_frame[request_id] = {
		"starvationOverride": starvation_override,
		"routeSearchExpansions": maxi(1, route_search_expansions)
	}

func _remove_planning_record(records: Array, request_id: String) -> void:
	for index in range(records.size() - 1, -1, -1):
		if String((records[index] as Dictionary).get("requestId", "")) == request_id:
			records.remove_at(index)
			return

func _planning_record_precedes(a: Dictionary, b: Dictionary) -> bool:
	var priority_a := int(a.get("priority", 0))
	var priority_b := int(b.get("priority", 0))
	if priority_a != priority_b:
		return priority_a > priority_b
	var age_a := _planning_service_age(a)
	var age_b := _planning_service_age(b)
	if age_a != age_b:
		return age_a > age_b
	var created_a := int(a.get("createdFrame", 0))
	var created_b := int(b.get("createdFrame", 0))
	if created_a != created_b:
		return created_a < created_b
	return String(a.get("requestId", "")) < String(b.get("requestId", ""))

func _planning_starved_precedes(a: Dictionary, b: Dictionary) -> bool:
	var age_a := _planning_service_age(a)
	var age_b := _planning_service_age(b)
	if age_a != age_b:
		return age_a > age_b
	return _planning_record_precedes(a, b)

func _planning_service_age(record: Dictionary) -> int:
	var last_serviced := int(record.get("lastServicedFrame", -1))
	if last_serviced >= 0:
		return maxi(0, frame_serial - last_serviced)
	return maxi(1, frame_serial - int(record.get("createdFrame", frame_serial)) + 1)

func _mark_planning_deferred(record: Dictionary) -> void:
	record["state"] = STATE_PENDING_BUDGET
	record["reason"] = "planning_budget"
	record["updatedFrame"] = frame_serial
	_append_event(record, _event(STATE_PENDING_BUDGET, "planning_budget"))

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
	record.erase("probeRepairAvoidCells")
	record.erase("probeRepairFailedGoalCells")
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
	var intent_record: Dictionary = requests_by_id[request_id]
	intent_record["intent"] = intent_dict.duplicate(true)
	requests_by_id[request_id] = intent_record
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
	var repair_avoid_cells: Array = intent_record.get("probeRepairAvoidCells", []).duplicate() if intent_record.get("probeRepairAvoidCells", []) is Array else []
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
		if state == STATE_INVALID_GOAL:
			return report_invalid_goal(request_id, reason)
		repair_avoid_cells = _merge_repair_avoid_cells(repair_avoid_cells, _probe_repair_avoid_cells(certificate))
		var repair_record: Dictionary = requests_by_id[request_id]
		repair_record["probeRepairAvoidCells"] = repair_avoid_cells.duplicate()
		requests_by_id[request_id] = repair_record
		if _should_attempt_probe_repair(certificate, state, options, repair_attempts):
			var repaired_route := _plan_probe_repair_route(entry, request_id, route_copy, intent_dict, certificate, options, repair_avoid_cells, repair_attempts)
			var repair_classification := String(repaired_route.get("classification", repaired_route.get("status", ""))) if not repaired_route.is_empty() else ""
			if repair_classification == STATE_PENDING_BUDGET:
				return mark_pending_budget(request_id, String(repaired_route.get("reason", "probe_repair_budget")))
			if repair_classification == STATE_PENDING_NAV_DATA:
				return mark_pending_nav_data(request_id, String(repaired_route.get("reason", "probe_repair_nav_data")))
			if not repaired_route.is_empty() and bool(repaired_route.get("ok", false)):
				route_copy = repaired_route
				repair_attempts += 1
				continue
		if state == STATE_BLOCKED_DYNAMIC:
			return report_blocked_dynamic(request_id, reason)
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
		_reset_collision_recovery_stall_for_request(request_id)
	return result

func report_segment_started(request_id: String, segment_index: int, details := {}) -> Dictionary:
	return report_execution_event(request_id, "segment_started", "segment_started", _execution_details_with_segment(segment_index, details))

func report_segment_completed(request_id: String, segment_index: int, details := {}) -> Dictionary:
	var result := report_execution_event(request_id, "segment_completed", "segment_completed", _execution_details_with_segment(segment_index, details))
	if bool(result.get("ok", false)):
		_reset_collision_recovery_stall_for_request(request_id)
	return result

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
	var result := report_execution_event(request_id, "unexpected_collision", reason, details)
	if bool(result.get("ok", false)) and requests_by_id.has(request_id):
		_observe_collision_recovery_stall(requests_by_id[request_id], details)
	return result

func report_door_wait(request_id: String, reason := "door_wait", details := {}) -> Dictionary:
	return report_execution_event(request_id, "door_wait", reason, details)

func report_execution_event(request_id: String, event_type: String, reason := "", details := {}) -> Dictionary:
	if not requests_by_id.has(request_id):
		return { "ok": false, "reason": "missing_request", "requestId": request_id }
	var record: Dictionary = requests_by_id[request_id]
	var details_dict: Dictionary = details if details is Dictionary else {}
	_append_event(record, _event("execution:%s" % event_type, reason, details_dict))
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

func telemetry_for_entry(entry: Dictionary) -> Dictionary:
	return telemetry_for_actor(actor_id_for_entry(entry))

func runtime_for_entry(entry: Dictionary) -> Dictionary:
	return runtime_for_actor(actor_id_for_entry(entry))

func runtime_for_actor(actor_id: String) -> Dictionary:
	if actor_id == "":
		return { "hasRequest": false, "state": STATE_NONE, "reason": "missing_actor_id" }
	var request_id := String(active_request_by_actor.get(actor_id, ""))
	if request_id == "" or not requests_by_id.has(request_id):
		return {
			"hasRequest": false,
			"actorId": actor_id,
			"state": STATE_NONE,
			"reason": "no_active_request"
		}
	var record: Dictionary = requests_by_id[request_id]
	var counts: Dictionary = record.get("stateFrameCounts", {}) if record.get("stateFrameCounts", {}) is Dictionary else {}
	return {
		"ok": true,
		"hasRequest": true,
		"requestId": request_id,
		"actorId": actor_id,
		"generation": int(record.get("generation", 0)),
		"state": String(record.get("state", STATE_NONE)),
		"reason": String(record.get("reason", "")),
		"priority": int(record.get("priority", 0)),
		"lastServicedFrame": int(record.get("lastServicedFrame", -1)),
		"planningWaitFrames": _planning_wait_frames(record),
		"queuedFrames": int(counts.get(STATE_QUEUED, 0)),
		"pendingBudgetFrames": int(counts.get(STATE_PENDING_BUDGET, 0)),
		"pendingNavDataFrames": int(counts.get(STATE_PENDING_NAV_DATA, 0)),
		"pendingProbeFrames": int(counts.get(STATE_PROBING, 0)),
		"routeLease": record.get("routeLease", {}),
		"route": record.get("route", {}),
		"probeRepairAvoidCells": (record.get("probeRepairAvoidCells", []) as Array).duplicate() if record.get("probeRepairAvoidCells", []) is Array else [],
		"probeRepairFailedGoalCells": (record.get("probeRepairFailedGoalCells", []) as Array).duplicate() if record.get("probeRepairFailedGoalCells", []) is Array else []
	}

func telemetry_for_actor(actor_id: String) -> Dictionary:
	if actor_id == "":
		return { "hasRequest": false, "state": STATE_NONE, "reason": "missing_actor_id" }
	var request_id := String(active_request_by_actor.get(actor_id, ""))
	if request_id == "" or not requests_by_id.has(request_id):
		return {
			"hasRequest": false,
			"actorId": actor_id,
			"state": STATE_NONE,
			"reason": "no_active_request"
		}
	var record: Dictionary = requests_by_id[request_id]
	var counts: Dictionary = record.get("stateFrameCounts", {}) if record.get("stateFrameCounts", {}) is Dictionary else {}
	var lease: Dictionary = record.get("routeLease", {}) if record.get("routeLease", {}) is Dictionary else {}
	var route: Dictionary = record.get("route", {}) if record.get("route", {}) is Dictionary else {}
	var proof: Dictionary = record.get("routeProof", {}) if record.get("routeProof", {}) is Dictionary else {}
	return {
		"hasRequest": true,
		"requestId": request_id,
		"actorId": actor_id,
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
		"interactionClaim": (lease.get("interactionClaim", {}) as Dictionary).duplicate(true) if lease.get("interactionClaim", {}) is Dictionary else {},
		"route": {
			"ok": bool(route.get("ok", false)),
			"status": String(route.get("status", "")),
			"classification": String(route.get("classification", "")),
			"reason": String(route.get("reason", "")),
			"source": String(route.get("source", "")),
			"targetCell": route.get("targetCell", INVALID_CELL),
			"cellCount": (route.get("cells", []) as Array).size() if route.get("cells", []) is Array else 0,
			"waypointCount": (route.get("waypoints", []) as Array).size() if route.get("waypoints", []) is Array else 0
		},
		"proof": {
			"ok": bool(proof.get("ok", false)),
			"status": String(proof.get("status", "")),
			"reason": String(proof.get("reason", "")),
			"authoritative": bool(proof.get("authoritative", false)),
			"sampleCount": int(proof.get("sampleCount", 0))
		},
		"probeRepairFailedGoalCells": (record.get("probeRepairFailedGoalCells", []) as Array).duplicate() if record.get("probeRepairFailedGoalCells", []) is Array else [],
		"eventCount": (record.get("events", []) as Array).size() if record.get("events", []) is Array else 0
	}

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
		"routeSearchExpansionBudgetPerFrame": route_search_expansion_budget_per_frame,
		"routeSearchExpansionsUsedThisFrame": route_search_expansions_used_this_frame,
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
		"interactionClaim": (lease.get("interactionClaim", {}) as Dictionary).duplicate(true) if lease.get("interactionClaim", {}) is Dictionary else {},
		"routeLease": lease.duplicate(true),
		"route": _record_route_summary(route),
		"probeRepairAvoidCells": (record.get("probeRepairAvoidCells", []) as Array).duplicate() if record.get("probeRepairAvoidCells", []) is Array else [],
		"probeRepairFailedGoalCells": (record.get("probeRepairFailedGoalCells", []) as Array).duplicate() if record.get("probeRepairFailedGoalCells", []) is Array else [],
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
	var certificate := _probe_certificate_from_proof(proof)
	route_copy["probeCertificate"] = certificate
	if not _probe_certificate_allows_ready(certificate) and _state_for_probe_certificate(certificate) == STATE_UNREACHABLE_STATIC:
		var failed_goal := _cell_from_value(route_copy.get("targetCell", INVALID_CELL))
		if failed_goal != INVALID_CELL:
			var failed_goals: Array = record.get("probeRepairFailedGoalCells", []).duplicate() if record.get("probeRepairFailedGoalCells", []) is Array else []
			record["probeRepairFailedGoalCells"] = _merge_repair_avoid_cells(failed_goals, [failed_goal])
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
	if state == STATE_BLOCKED_DYNAMIC:
		return _probe_certificate_is_dynamic_actor_block(certificate, options, repair_attempts)
	if state != STATE_UNREACHABLE_STATIC:
		return false
	if repair_attempts >= int(options.get("maxProbeRepairAttempts", MAX_PROBE_REPAIR_ATTEMPTS)):
		return false
	if options.get("repairSubstrate", null) == null:
		return false
	var reason := String(certificate.get("reason", ""))
	# The motion probe is the final collision authority for terrain.  It reports the
	# sampled world position rather than a navigation-cell collision, so let the
	# normal bounded repair path convert that sample into an avoid cell and seek a
	# different collision-backed route.  Treating it as terminal here leaves a
	# valid alternative interaction pose unreachable after the substrate succeeded.
	return reason in ["blocked_capsule_probe", "blocked_terrain_motion_probe", "path_crosses_static_collision", "blocked_static_collision", "blocked_static_transition"]


func _probe_certificate_is_dynamic_actor_block(certificate: Dictionary, options: Dictionary, repair_attempts: int) -> bool:
	if repair_attempts >= int(options.get("maxProbeRepairAttempts", MAX_PROBE_REPAIR_ATTEMPTS)):
		return false
	if options.get("repairSubstrate", null) == null:
		return false
	if String(certificate.get("reason", "")) != "blocked_capsule_probe":
		return false
	var details: Dictionary = certificate.get("details", {}) if certificate.get("details", {}) is Dictionary else {}
	var kind := String(details.get("kind", ""))
	var block_type := String(details.get("blockType", ""))
	var collider_class := String(details.get("class", ""))
	return kind in ["npc", "actor", "character", "player"] \
		or block_type in ["npc", "actor", "player"] \
		or collider_class in ["CharacterBody3D", "KinematicBody3D"]

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
	if _state_for_probe_certificate(certificate) == STATE_BLOCKED_DYNAMIC:
		repair_plan_options["probeRepairAvoidRadius"] = maxi(
			int(repair_plan_options.get("probeRepairAvoidRadius", 0)),
			DYNAMIC_PROBE_REPAIR_AVOID_RADIUS
		)
	var repaired = substrate.call("repair_route_after_probe", entry, start_cell, candidate_cells, failed_route, certificate, repair_plan_options)
	var repaired_route: Dictionary = repaired if repaired is Dictionary else {}
	if repaired_route.is_empty():
		_record_probe_repair_attempt(request_id, false, String(repaired_route.get("reason", "probe_repair_no_route")), certificate, repair_avoid_cells, repair_attempts, repaired_route)
		return {}
	var classification := String(repaired_route.get("classification", repaired_route.get("status", "")))
	if not bool(repaired_route.get("ok", false)):
		_record_probe_repair_attempt(request_id, false, String(repaired_route.get("reason", "probe_repair_no_route")), certificate, repair_avoid_cells, repair_attempts, repaired_route)
		if classification in [STATE_PENDING_BUDGET, STATE_PENDING_NAV_DATA]:
			return repaired_route
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
	# begin_frame is the sole physics clock for pending-state durations.
	record["state"] = state
	record["reason"] = reason
	record["updatedFrame"] = frame_serial
	record["lastServicedFrame"] = frame_serial
	_append_event(record, _event(state, reason))

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
	_append_event(record, _event(event_state, reason, details))
	record["updatedFrame"] = frame_serial
	record["lastServicedFrame"] = frame_serial

func _append_event(record: Dictionary, event: Dictionary) -> void:
	var events: Array = record.get("events", []) if record.get("events", []) is Array else []
	events.append(event)
	while events.size() > MAX_REQUEST_EVENTS:
		events.remove_at(0)
	record["events"] = events

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
		"routeSearchExpansionBudgetPerFrame": route_search_expansion_budget_per_frame,
		"routeSearchExpansionsUsedThisFrame": route_search_expansions_used_this_frame,
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
		"wallMsec": Time.get_ticks_msec(),
		"state": state,
		"reason": reason
	}
	if details is Dictionary and not (details as Dictionary).is_empty():
		result["details"] = (details as Dictionary).duplicate(true)
	return result


func _maybe_capture_pending_stall_trace(record: Dictionary) -> void:
	var state := String(record.get("state", STATE_NONE))
	if not (state in PENDING_STATES) or bool(record.get("pendingStallTraceCaptured", false)):
		return
	var now_msec := Time.get_ticks_msec()
	var created_msec := int(record.get("createdWallMsec", now_msec))
	var wall_wait_msec := maxi(0, now_msec - created_msec)
	if wall_wait_msec < PENDING_STALL_TRACE_WALL_MSEC:
		return
	record["pendingStallTraceCaptured"] = true
	counters["pendingStallTraceCaptures"] = int(counters.get("pendingStallTraceCaptures", 0)) + 1
	var actor_id := String(record.get("actorId", ""))
	var entry_value = actor_entries.get(actor_id, {})
	var entry: Dictionary = entry_value if entry_value is Dictionary else {}
	var body := entry.get("body") as Node3D
	var position = body.global_position if body != null and is_instance_valid(body) else null
	var route: Dictionary = record.get("route", {}) if record.get("route", {}) is Dictionary else {}
	var proof: Dictionary = record.get("routeProof", {}) if record.get("routeProof", {}) is Dictionary else {}
	var trace := {
		"capturedWallMsec": now_msec,
		"authorityPhysicsFrame": frame_serial,
		"worldSeed": String(main.get("seed_text")) if main != null else "",
		"actorId": actor_id,
		"requestId": String(record.get("requestId", "")),
		"generation": int(record.get("generation", 0)),
		"intent": _trace_safe_value(record.get("intent", {})),
		"state": state,
		"reason": String(record.get("reason", "")),
		"priority": int(record.get("priority", 0)),
		"createdFrame": int(record.get("createdFrame", 0)),
		"createdWallMsec": created_msec,
		"wallWaitMsec": wall_wait_msec,
		"stateFrameCounts": _trace_safe_value(record.get("stateFrameCounts", {})),
		"lastServicedFrame": int(record.get("lastServicedFrame", -1)),
		"recentEvents": _trace_safe_value(_recent_events(record, MAX_REQUEST_EVENTS)),
		"route": _trace_safe_value(_record_route_summary(route)),
		"proof": _trace_safe_value({
			"ok": bool(proof.get("ok", false)),
			"status": String(proof.get("status", "")),
			"reason": String(proof.get("reason", "")),
			"sampleCount": int(proof.get("sampleCount", 0))
		}),
		"bodyPosition": _trace_safe_value(position),
		"routePhysicsService": _trace_safe_value({
			"ticks": int(entry.get("routePhysicsServiceTicks", 0)),
			"lastFrame": int(entry.get("routePhysicsServiceLastFrame", -1)),
			"kind": String(entry.get("routePhysicsServiceKind", "")),
			"reason": String(entry.get("routePhysicsServiceReason", "")),
			"sinceBrainFrames": int(entry.get("routePhysicsServiceSinceBrainFrames", -1))
		}),
		"lastPlan": _trace_safe_value(entry.get("homeRouteV2LastPlan", {}))
	}
	pending_stall_trace_records.append(trace)
	while pending_stall_trace_records.size() > 8:
		pending_stall_trace_records.remove_at(0)
	_write_pending_stall_trace()


func _write_pending_stall_trace() -> void:
	var file := FileAccess.open(STALL_TRACE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"schemaVersion": 1,
		"captureKind": "npc_route_pending_stall",
		"thresholdWallMsec": PENDING_STALL_TRACE_WALL_MSEC,
		"traces": pending_stall_trace_records
	}, "\t"))


func _maybe_capture_scripted_order_stall_trace(actor_id: String, entry: Dictionary) -> void:
	var order_value = entry.get("scriptedOrder", {})
	if not (order_value is Dictionary):
		return
	var order: Dictionary = order_value
	var order_state := String(order.get("state", ""))
	if not bool(order.get("usesRouteStack", false)) or not (order_state in ["PENDING", "ACTIVE"]):
		return
	var active_request_id := String(active_request_by_actor.get(actor_id, ""))
	if active_request_id != "" and requests_by_id.has(active_request_id):
		return
	var order_id := String(order.get("id", ""))
	if order_id == "" or String(entry.get("_scriptedOrderStallTraceOrderId", "")) == order_id:
		return
	var now_msec := Time.get_ticks_msec()
	var submitted_msec := int(order.get("submittedWallMsec", now_msec))
	var wall_wait_msec := maxi(0, now_msec - submitted_msec)
	if wall_wait_msec < PENDING_STALL_TRACE_WALL_MSEC:
		return
	entry["_scriptedOrderStallTraceOrderId"] = order_id
	counters["scriptedOrderStallTraceCaptures"] = int(counters.get("scriptedOrderStallTraceCaptures", 0)) + 1
	var body := entry.get("body") as Node3D
	var trace_seed = main.get("seed_text") if main != null else null
	var trace := {
		"capturedWallMsec": now_msec,
		"authorityPhysicsFrame": frame_serial,
		"worldSeed": trace_seed if trace_seed is String else "",
		"actorId": actor_id,
		"order": _trace_safe_value(order),
		"submittedPhysicsFrame": int(order.get("submittedPhysicsFrame", -1)),
		"submittedWallMsec": submitted_msec,
		"wallWaitMsec": wall_wait_msec,
		"activeRequestId": active_request_id,
		"routeStatus": String(entry.get("routeStatus", "")),
		"routeReason": String(entry.get("routeReason", "")),
		"homeRequestId": String(entry.get("homeRouteV2RequestId", "")),
		"routineRequestId": String(entry.get("routineRouteV2RequestId", "")),
		"bodyPosition": _trace_safe_value(body.global_position if body != null and is_instance_valid(body) else null),
		"dialogueFocused": bool(body.get_meta("npc_dialogue_focused", false)) if body != null and is_instance_valid(body) else false,
		"brain": _trace_safe_value({
			"lastTick": int(entry.get("npc_last_brain_tick", -1)),
			"budgetSkipStreak": int(entry.get("npc_brain_budget_skip_streak", 0)),
			"lastSkipReason": String(entry.get("npc_brain_budget_skip_reason", ""))
		}),
		"routePhysicsService": _trace_safe_value({
			"ticks": int(entry.get("routePhysicsServiceTicks", 0)),
			"lastFrame": int(entry.get("routePhysicsServiceLastFrame", -1)),
			"kind": String(entry.get("routePhysicsServiceKind", "")),
			"reason": String(entry.get("routePhysicsServiceReason", ""))
		})
	}
	scripted_order_stall_trace_records.append(trace)
	while scripted_order_stall_trace_records.size() > 8:
		scripted_order_stall_trace_records.remove_at(0)
	_write_scripted_order_stall_trace()


func _write_scripted_order_stall_trace() -> void:
	var file := FileAccess.open(SCRIPTED_ORDER_STALL_TRACE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"schemaVersion": 1,
		"captureKind": "npc_scripted_order_without_route_request_stall",
		"thresholdWallMsec": PENDING_STALL_TRACE_WALL_MSEC,
		"traces": scripted_order_stall_trace_records
	}, "\t"))


func _observe_collision_recovery_stall(record: Dictionary, details) -> void:
	var actor_id := String(record.get("actorId", ""))
	if actor_id == "":
		return
	var now_msec := Time.get_ticks_msec()
	var state_value = collision_recovery_stalls_by_actor.get(actor_id, {})
	var state: Dictionary = state_value if state_value is Dictionary else {}
	if state.is_empty():
		state = {
			"firstWallMsec": now_msec,
			"collisionCount": 0,
			"captured": false
		}
	state["lastWallMsec"] = now_msec
	state["collisionCount"] = int(state.get("collisionCount", 0)) + 1
	state["lastRequestId"] = String(record.get("requestId", ""))
	state["lastCollision"] = _trace_safe_value(details if details is Dictionary else {})
	collision_recovery_stalls_by_actor[actor_id] = state
	if bool(state.get("captured", false)) or int(state.get("collisionCount", 0)) < 2:
		return
	var first_msec := int(state.get("firstWallMsec", now_msec))
	var wall_wait_msec := maxi(0, now_msec - first_msec)
	if wall_wait_msec < PENDING_STALL_TRACE_WALL_MSEC:
		return
	state["captured"] = true
	collision_recovery_stalls_by_actor[actor_id] = state
	counters["collisionRecoveryStallTraceCaptures"] = int(counters.get("collisionRecoveryStallTraceCaptures", 0)) + 1
	var entry_value = actor_entries.get(actor_id, {})
	var entry: Dictionary = entry_value if entry_value is Dictionary else {}
	var body := entry.get("body") as Node3D
	var trace_seed = main.get("seed_text") if main != null else null
	var trace := {
		"capturedWallMsec": now_msec,
		"authorityPhysicsFrame": frame_serial,
		"worldSeed": trace_seed if trace_seed is String else "",
		"actorId": actor_id,
		"firstCollisionWallMsec": first_msec,
		"wallRecoveryMsec": wall_wait_msec,
		"collisionCount": int(state.get("collisionCount", 0)),
		"lastRequestId": String(state.get("lastRequestId", "")),
		"lastCollision": state.get("lastCollision", {}),
		"activeRequest": _trace_safe_value(runtime_for_actor(actor_id)),
		"bodyPosition": _trace_safe_value(body.global_position if body != null and is_instance_valid(body) else null),
		"scriptedOrder": _trace_safe_value(entry.get("scriptedOrder", {})),
		"routePhysicsService": _trace_safe_value({
			"ticks": int(entry.get("routePhysicsServiceTicks", 0)),
			"lastFrame": int(entry.get("routePhysicsServiceLastFrame", -1)),
			"kind": String(entry.get("routePhysicsServiceKind", "")),
			"reason": String(entry.get("routePhysicsServiceReason", ""))
		})
	}
	collision_recovery_stall_trace_records.append(trace)
	while collision_recovery_stall_trace_records.size() > 8:
		collision_recovery_stall_trace_records.remove_at(0)
	_write_collision_recovery_stall_trace()


func _reset_collision_recovery_stall_for_request(request_id: String) -> void:
	if request_id == "" or not requests_by_id.has(request_id):
		return
	var record: Dictionary = requests_by_id[request_id]
	var actor_id := String(record.get("actorId", ""))
	if actor_id != "":
		collision_recovery_stalls_by_actor.erase(actor_id)


func _write_collision_recovery_stall_trace() -> void:
	var file := FileAccess.open(COLLISION_RECOVERY_STALL_TRACE_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({
		"schemaVersion": 1,
		"captureKind": "npc_repeated_collision_recovery_stall",
		"thresholdWallMsec": PENDING_STALL_TRACE_WALL_MSEC,
		"traces": collision_recovery_stall_trace_records
	}, "\t"))


func _trace_safe_value(value, depth := 0):
	if depth >= 5:
		return str(value)
	if value is Vector3:
		var vector3: Vector3 = value
		return [vector3.x, vector3.y, vector3.z]
	if value is Vector2:
		var vector2: Vector2 = value
		return [vector2.x, vector2.y]
	if value is Vector3i:
		var vector3i: Vector3i = value
		return [vector3i.x, vector3i.y, vector3i.z]
	if value is Vector2i:
		var vector2i: Vector2i = value
		return [vector2i.x, vector2i.y]
	if value is Dictionary:
		var result := {}
		var count := 0
		for key in (value as Dictionary).keys():
			if count >= 48:
				break
			result[str(key)] = _trace_safe_value((value as Dictionary).get(key), depth + 1)
			count += 1
		return result
	if value is Array:
		var result: Array = []
		for item in value:
			if result.size() >= 48:
				break
			result.append(_trace_safe_value(item, depth + 1))
		return result
	if value is PackedVector3Array:
		var result: Array = []
		for item in value:
			if result.size() >= 48:
				break
			result.append(_trace_safe_value(item, depth + 1))
		return result
	if value == null or value is bool or value is int or value is float or value is String:
		return value
	return str(value)

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
