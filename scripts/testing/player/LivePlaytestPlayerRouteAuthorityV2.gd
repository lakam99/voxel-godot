extends RefCounted
class_name LivePlaytestPlayerRouteAuthorityV2

const CollisionBackedRouteSubstrateScript := preload("res://scripts/npc_ai/routing/CollisionBackedRouteSubstrate.gd")

const STATE_READY := "ready"
const STATE_MOVING := "moving"
const STATE_PROBING := "probing"
const TERMINAL_STATES := ["blocked_dynamic", "unreachable_static", "invalid_goal", "arrived", "cancelled"]

var main: Node3D
var player: CharacterBody3D
var authority = null
var world = null
var substrate = null
var active_request_id := ""
var active_signature := ""
var active_route := {}
var active_intent := {}
var active_entry_id := ""
var active_commit_options := {}

func setup(main_node: Node3D, player_node: CharacterBody3D) -> void:
	main = main_node
	player = player_node

func available() -> bool:
	return bool(_components().get("ok", false))

func plan_route(entry: Dictionary, target: Vector3, semantic_kind: String, options := {}) -> Dictionary:
	var components := _components()
	if not bool(components.get("ok", false)):
		return _result(false, "route_authority_missing", String(components.get("reason", "missing_v2_components")), {}, {}, {})
	if entry.is_empty() or player == null or not is_instance_valid(player):
		return _result(false, "invalid_goal", "missing_player_route_entry", {}, {}, {})
	_bind_entry(entry)
	var allow_outside := bool(options.get("allowOutside", true))
	var moving_home := semantic_kind == "home_interior" or bool(options.get("movingHome", false))
	var signature := _request_signature(entry, target, semantic_kind, allow_outside, options)
	if active_request_id == "" or signature != active_signature:
		cancel_active(entry, "player_route_replaced")
		active_signature = signature
		active_entry_id = String(entry.get("id", ""))
		active_intent = _intent(entry, target, semantic_kind, allow_outside, moving_home, [], options)
		var submitted: Dictionary = authority.submit_request(entry, active_intent, { "priority": int(active_intent.get("priority", 220)) })
		active_request_id = String(submitted.get("requestId", ""))
		active_route = {}
		active_commit_options = {}
		if active_request_id == "":
			return _result(false, "failed_internal", String(submitted.get("reason", "request_submission_failed")), {}, submitted, {})
	var runtime := _runtime(entry)
	var state := String(runtime.get("state", ""))
	if state in [STATE_READY, STATE_MOVING]:
		return _runtime_result(runtime, {})
	if state in TERMINAL_STATES:
		return _runtime_result(runtime, {})
	if state == STATE_PROBING and not active_route.is_empty():
		var resumed: Dictionary = authority.commit_route_after_probe(entry, active_request_id, active_route, active_intent, active_commit_options)
		return _runtime_result(resumed, { "resumedProbe": true, "route": _route_summary(active_route) })
	var planning_budget: Dictionary = authority.claim_planning_budget(active_request_id, "live_playtest_player_route")
	if not bool(planning_budget.get("granted", planning_budget.get("ok", false))):
		return _runtime_result(planning_budget, { "planningBudget": planning_budget })
	var candidates_result := _candidate_poses(entry, target, semantic_kind, allow_outside, moving_home, options)
	if not bool(candidates_result.get("ok", false)):
		var candidate_classification := String(candidates_result.get("classification", "invalid_goal"))
		var candidate_reason := String(candidates_result.get("reason", "no_routeable_candidate_pose"))
		var candidate_state := _report_failure(candidate_classification, candidate_reason)
		return _runtime_result(candidate_state, { "candidatePoses": candidates_result })
	var candidate_cells := _candidate_cells(candidates_result)
	if candidate_cells.is_empty():
		var no_candidates: Dictionary = authority.report_invalid_goal(active_request_id, "no_v2_compatible_candidate_pose")
		return _runtime_result(no_candidates, { "candidatePoses": candidates_result })
	active_intent = _intent(entry, target, semantic_kind, allow_outside, moving_home, candidate_cells, options)
	var start_cell := _world_cell(player.global_position)
	var plan_options := {
		"allowOutside": allow_outside,
		"movingHome": moving_home,
		"semanticKind": semantic_kind,
		"startPosition": player.global_position,
		"maxExpansions": int(options.get("maxExpansions", 8192)),
		"expansionsPerCall": int(options.get("expansionsPerCall", 16))
	}
	var requested_avoids: Array = options.get("avoidCells", []) if options.get("avoidCells", []) is Array else []
	var repair_avoids: Array = runtime.get("probeRepairAvoidCells", []) if runtime.get("probeRepairAvoidCells", []) is Array else []
	var combined_avoids := _merge_avoid_cells(requested_avoids, repair_avoids)
	if not combined_avoids.is_empty():
		plan_options["avoidCells"] = combined_avoids
	var route: Dictionary = substrate.plan_route(entry, start_cell, candidate_cells, plan_options)
	if not bool(route.get("ok", false)):
		var route_classification := String(route.get("classification", "unreachable_static"))
		var route_reason := String(route.get("reason", "no_collision_backed_route"))
		var route_state := _report_failure(route_classification, route_reason)
		return _runtime_result(route_state, { "candidatePoses": candidates_result, "route": _route_summary(route) })
	route["interactionClaim"] = active_intent.get("interactionClaim", {}).duplicate(true) if active_intent.get("interactionClaim", {}) is Dictionary else {}
	active_route = route.duplicate(true)
	active_commit_options = _commit_options(plan_options, start_cell, candidate_cells)
	var committed: Dictionary = authority.commit_route_after_probe(entry, active_request_id, route, active_intent, active_commit_options)
	return _runtime_result(committed, { "candidatePoses": candidates_result, "route": _route_summary(route) })

func begin_execution(entry: Dictionary) -> Dictionary:
	if active_request_id == "" or authority == null:
		return { "ok": false, "reason": "missing_active_player_route" }
	_bind_entry(entry)
	return authority.begin_moving(active_request_id, "live_playtest_player_controller")

func report_segment_started(segment_index: int, details := {}) -> Dictionary:
	if active_request_id == "" or authority == null:
		return { "ok": false, "reason": "missing_active_player_route" }
	return authority.report_segment_started(active_request_id, segment_index, details)

func report_segment_completed(segment_index: int, details := {}) -> Dictionary:
	if active_request_id == "" or authority == null:
		return { "ok": false, "reason": "missing_active_player_route" }
	return authority.report_segment_completed(active_request_id, segment_index, details)

func report_door_wait(reason: String, details := {}) -> Dictionary:
	if active_request_id == "" or authority == null:
		return { "ok": false, "reason": "missing_active_player_route" }
	return authority.report_door_wait(active_request_id, reason, details)

func report_stuck(reason: String, details := {}) -> Dictionary:
	if active_request_id == "" or authority == null:
		return { "ok": false, "reason": "missing_active_player_route" }
	return authority.report_stuck(active_request_id, reason, details)

func report_arrived(details := {}) -> Dictionary:
	if active_request_id == "" or authority == null:
		return { "ok": false, "reason": "missing_active_player_route" }
	if not details.is_empty():
		authority.report_execution_event(active_request_id, "player_arrival", "player_controller_arrived", details)
	return authority.report_arrived(active_request_id, "live_playtest_player_arrived")

func cancel_active(entry: Dictionary, reason := "cancelled") -> Dictionary:
	if active_request_id == "" or authority == null:
		active_request_id = ""
		active_signature = ""
		active_route = {}
		active_intent = {}
		active_commit_options = {}
		return { "ok": true, "cancelled": false, "reason": "no_active_player_route" }
	_bind_entry(entry)
	var cancelled: Dictionary = authority.cancel_request(active_request_id, reason)
	active_request_id = ""
	active_signature = ""
	active_route = {}
	active_intent = {}
	active_commit_options = {}
	return cancelled

func active_debug(entry: Dictionary) -> Dictionary:
	if authority == null:
		return { "hasRequest": false, "reason": "missing_v2_authority" }
	_bind_entry(entry)
	return authority.debug_for_entry(entry)

func _components() -> Dictionary:
	if main == null or not is_instance_valid(main):
		return { "ok": false, "reason": "missing_main" }
	var npc_system = main.get("npc_system")
	if npc_system == null:
		return { "ok": false, "reason": "missing_npc_system" }
	var autonomy = npc_system.get("autonomy_system")
	if autonomy == null:
		return { "ok": false, "reason": "missing_autonomy_system" }
	var current_authority = autonomy.get("route_authority_v2")
	if current_authority == null:
		return { "ok": false, "reason": "missing_route_authority_v2" }
	var current_world = autonomy.call("generated_navigation_adapter") if autonomy.has_method("generated_navigation_adapter") else null
	if current_world == null:
		return { "ok": false, "reason": "missing_generated_navigation_adapter" }
	authority = current_authority
	if substrate == null or world != current_world:
		world = current_world
		substrate = CollisionBackedRouteSubstrateScript.new()
		substrate.setup(world)
	return { "ok": true }

func _bind_entry(entry: Dictionary) -> void:
	entry["body"] = player
	entry["position"] = player.global_position if player != null else Vector3.ZERO
	if authority != null:
		authority.register_actor(entry)

func _candidate_poses(entry: Dictionary, target: Vector3, semantic_kind: String, allow_outside: bool, moving_home: bool, options: Dictionary) -> Dictionary:
	var candidates: Dictionary = substrate.candidate_poses_for_target(entry, _target_data(entry, target, semantic_kind, options), semantic_kind, {
		"allowOutside": allow_outside,
		"movingHome": moving_home
	})
	var unfiltered_cells := _candidate_cells(candidates)
	var constrained: Array = []
	var max_candidate_distance := float(options.get("maxCandidateDistance", -1.0))
	var exclude_target_cell := bool(options.get("excludeTargetCell", false))
	var target_cell := _world_cell(target)
	for candidate_value in candidates.get("candidates", []):
		if not (candidate_value is Dictionary):
			continue
		var candidate: Dictionary = candidate_value
		var candidate_cell = candidate.get("cell", Vector2i(2147483000, 2147483000))
		if not (candidate_cell is Vector2i):
			continue
		if exclude_target_cell and candidate_cell == target_cell:
			continue
		var candidate_position = candidate.get("position", Vector3.ZERO)
		if max_candidate_distance >= 0.0 and candidate_position is Vector3:
			var offset: Vector3 = candidate_position - target
			offset.y = 0.0
			if offset.length() > max_candidate_distance:
				continue
		constrained.append(candidate)
	candidates["candidates"] = constrained
	candidates["unfilteredCandidateCells"] = unfiltered_cells
	candidates["maxCandidateDistance"] = max_candidate_distance
	candidates["targetCellExcluded"] = exclude_target_cell
	var requested_cells: Array = options.get("candidateCells", []) if options.get("candidateCells", []) is Array else []
	if requested_cells.is_empty():
		if constrained.is_empty():
			candidates["ok"] = false
			candidates["classification"] = "invalid_goal"
			candidates["reason"] = "no_v2_compatible_candidate_pose"
		return candidates
	var requested_lookup := {}
	for value in requested_cells:
		if value is Vector2i:
			requested_lookup[value] = true
	var filtered: Array = []
	for candidate_value in candidates.get("candidates", []):
		if candidate_value is Dictionary and requested_lookup.has((candidate_value as Dictionary).get("cell", Vector2i(2147483000, 2147483000))):
			filtered.append(candidate_value)
	candidates["candidates"] = filtered
	candidates["requestedCandidateCells"] = requested_cells.duplicate()
	if filtered.is_empty():
		candidates["ok"] = false
		candidates["classification"] = "invalid_goal"
		candidates["reason"] = "no_v2_compatible_candidate_pose"
	return candidates

func _target_data(entry: Dictionary, target: Vector3, semantic_kind: String, options: Dictionary = {}) -> Dictionary:
	var target_cell := _world_cell(target)
	var result := { "position": target, "cell": target_cell }
	var candidate_cells: Array = options.get("candidateCells", []) if options.get("candidateCells", []) is Array else []
	if not candidate_cells.is_empty():
		result["candidateCells"] = candidate_cells.duplicate()
	if semantic_kind == "home_interior":
		result["homeCell"] = entry.get("homeCell", target_cell)
		result["interiorMinCell"] = entry.get("interiorMinCell", target_cell)
		result["interiorMaxCell"] = entry.get("interiorMaxCell", target_cell)
	return result

func _intent(entry: Dictionary, target: Vector3, semantic_kind: String, allow_outside: bool, moving_home: bool, candidate_cells: Array, options: Dictionary) -> Dictionary:
	return {
		"kind": "scripted",
		"semanticKind": semantic_kind,
		"movingHome": moving_home,
		"allowOutside": allow_outside,
		"priority": int(options.get("priority", entry.get("routePriority", 220))),
		"target": target,
		"targetCell": _world_cell(target),
		"candidateCells": candidate_cells.duplicate(),
		"reason": String(options.get("label", "live_playtest_player_route"))
	}

func _commit_options(plan_options := {}, start_cell := Vector2i(2147483000, 2147483000), candidate_cells: Array = []) -> Dictionary:
	var result := {
		"repairSubstrate": substrate,
		"maxProbeRepairAttempts": 3
	}
	if not plan_options.is_empty():
		result["repairStartCell"] = start_cell
		result["repairCandidateCells"] = candidate_cells.duplicate()
		result["repairPlanOptions"] = plan_options.duplicate(true)
	return result

func _candidate_cells(candidates_result: Dictionary) -> Array:
	var result: Array = []
	for candidate_value in candidates_result.get("candidates", []):
		if not (candidate_value is Dictionary):
			continue
		var cell = (candidate_value as Dictionary).get("cell", Vector2i(2147483000, 2147483000))
		if cell is Vector2i and not result.has(cell):
			result.append(cell)
	return result


func _candidate_summary(candidates_result: Dictionary) -> Dictionary:
	var accepted := _candidate_cells(candidates_result)
	var requested: Array = candidates_result.get("requestedCandidateCells", []) if candidates_result.get("requestedCandidateCells", []) is Array else []
	var unfiltered: Array = candidates_result.get("unfilteredCandidateCells", []) if candidates_result.get("unfilteredCandidateCells", []) is Array else []
	return {
		"acceptedCount": accepted.size(),
		"acceptedCells": _limited_cell_keys(accepted),
		"requestedCount": requested.size(),
		"requestedCells": _limited_cell_keys(requested),
		"unfilteredCount": unfiltered.size(),
		"unfilteredCells": _limited_cell_keys(unfiltered),
		"rejectedCount": (candidates_result.get("rejected", []) as Array).size() if candidates_result.get("rejected", []) is Array else 0,
		"reason": String(candidates_result.get("reason", "")),
		"classification": String(candidates_result.get("classification", ""))
	}


func _limited_cell_keys(values: Array, limit := 16) -> Array[String]:
	var result: Array[String] = []
	for value in values:
		if not (value is Vector2i) or result.size() >= limit:
			continue
		var cell: Vector2i = value
		result.append("%d,%d" % [cell.x, cell.y])
	return result

func _merge_avoid_cells(first, second) -> Array:
	var result: Array = []
	for values in [first, second]:
		if not (values is Array):
			continue
		for value in values:
			if value is Vector2i and not result.has(value):
				result.append(value)
	return result

func _report_failure(classification: String, reason: String) -> Dictionary:
	if classification == "pending_nav_data":
		return authority.mark_pending_nav_data(active_request_id, reason)
	if classification == "pending_budget":
		return authority.mark_pending_budget(active_request_id, reason)
	if classification == "blocked_dynamic":
		return authority.report_blocked_dynamic(active_request_id, reason)
	if classification == "invalid_goal":
		return authority.report_invalid_goal(active_request_id, reason)
	return authority.report_unreachable_static(active_request_id, reason)

func _runtime(entry: Dictionary) -> Dictionary:
	_bind_entry(entry)
	return authority.runtime_for_entry(entry) if authority != null else { "state": "failed_internal", "reason": "missing_route_authority_v2" }

func _runtime_result(runtime: Dictionary, details: Dictionary) -> Dictionary:
	var state := String(runtime.get("state", ""))
	var lease: Dictionary = runtime.get("routeLease", {}) if runtime.get("routeLease", {}) is Dictionary else {}
	var route := _route_from_lease(lease)
	if route.is_empty() and not active_route.is_empty():
		route = active_route.duplicate(true)
	var result := _result(state in [STATE_READY, STATE_MOVING], state, String(runtime.get("reason", "")), route, runtime, details)
	var candidate_value = details.get("candidatePoses", {})
	if candidate_value is Dictionary:
		result["routeSummary"]["candidatePoses"] = _candidate_summary(candidate_value)
	result["pending"] = not bool(result.get("ok", false)) and not (state in TERMINAL_STATES)
	result["terminal"] = state in TERMINAL_STATES
	return result

func _route_from_lease(lease: Dictionary) -> Dictionary:
	if lease.is_empty():
		return {}
	return {
		"ok": true,
		"status": "routed",
		"reason": String((lease.get("route", {}) as Dictionary).get("reason", "")) if lease.get("route", {}) is Dictionary else "",
		"source": String(lease.get("source", "collision_backed_route_substrate")),
		"cells": (lease.get("cells", []) as Array).duplicate() if lease.get("cells", []) is Array else [],
		"waypoints": (lease.get("waypoints", []) as Array).duplicate() if lease.get("waypoints", []) is Array else [],
		"actions": (lease.get("actions", {}) as Dictionary).duplicate(true) if lease.get("actions", {}) is Dictionary else {},
		"targetCell": lease.get("targetCell", Vector2i(2147483000, 2147483000)),
		"snapshotRevision": String(lease.get("snapshotRevision", "")),
		"collisionProbe": (lease.get("probeCertificate", {}) as Dictionary).duplicate(true) if lease.get("probeCertificate", {}) is Dictionary else {},
		"routeLease": lease.duplicate(true),
		"routeAuthorityState": STATE_READY,
		"routeAuthorityReady": true,
		"routeAuthorityPending": false,
		"routeAuthorityTerminalFailure": false,
		"routeAuthoritySource": "NpcRouteAuthorityV2"
	}

func _request_signature(entry: Dictionary, target: Vector3, semantic_kind: String, allow_outside: bool, options: Dictionary) -> String:
	var candidate_keys: Array[String] = []
	for value in options.get("candidateCells", []):
		if value is Vector2i:
			var cell: Vector2i = value
			candidate_keys.append("%d,%d" % [cell.x, cell.y])
	candidate_keys.sort()
	var avoid_keys: Array[String] = []
	for value in options.get("avoidCells", []):
		if value is Vector2i:
			var avoid_cell: Vector2i = value
			avoid_keys.append("%d,%d" % [avoid_cell.x, avoid_cell.y])
	avoid_keys.sort()
	var target_cell := _world_cell(target)
	return "%s|%s|%d,%d|%s|%s|%s|%s" % [
		String(entry.get("id", "")),
		semantic_kind,
		target_cell.x,
		target_cell.y,
		"1" if allow_outside else "0",
		String(entry.get("homeStableId", "")),
		",".join(candidate_keys),
		",".join(avoid_keys)
	]

func _world_cell(position: Vector3) -> Vector2i:
	if world != null and world.has_method("world_cell"):
		var cell = world.call("world_cell", position)
		if cell is Vector2i:
			return cell
	return Vector2i(roundi(position.x / 1.35), roundi(position.z / 1.35))

func _route_summary(route: Dictionary) -> Dictionary:
	var proof: Dictionary = route.get("proof", {}) if route.get("proof", {}) is Dictionary else {}
	var probe_repair: Dictionary = route.get("probeRepair", {}) if route.get("probeRepair", {}) is Dictionary else {}
	var collision_probe: Dictionary = route.get("collisionProbe", {}) if route.get("collisionProbe", {}) is Dictionary else {}
	var completed_validation: Dictionary = proof.get("completedRouteValidation", {}) if proof.get("completedRouteValidation", {}) is Dictionary else {}
	return {
		"ok": bool(route.get("ok", false)),
		"classification": String(route.get("classification", "")),
		"status": String(route.get("status", "")),
		"reason": String(route.get("reason", "")),
		"source": String(route.get("source", "")),
		"cellCount": (route.get("cells", []) as Array).size() if route.get("cells", []) is Array else 0,
		"waypointCount": (route.get("waypoints", []) as Array).size() if route.get("waypoints", []) is Array else 0,
		"actionCount": (route.get("actions", {}) as Dictionary).size() if route.get("actions", {}) is Dictionary else 0,
		"targetCell": route.get("targetCell", Vector2i(2147483000, 2147483000)),
		"searchExpansions": int(proof.get("expansions", 0)),
		"searchVisited": int(proof.get("visitedCount", 0)),
		"searchStartedRevision": String(proof.get("searchStartedRevision", "")),
		"searchSnapshotRevision": String(proof.get("searchSnapshotRevision", "")),
		"searchSnapshotChanged": bool(proof.get("searchSnapshotChanged", false)),
		"completedValidation": {
			"ok": bool(completed_validation.get("ok", false)),
			"reason": String(completed_validation.get("reason", "")),
			"cell": completed_validation.get("cell", Vector2i(2147483000, 2147483000)),
			"index": int(completed_validation.get("index", -1))
		} if not completed_validation.is_empty() else {},
		"probeSamples": int(collision_probe.get("sampleCount", 0)),
		"repairAttempt": int(probe_repair.get("attempt", 0))
	}

func _result(ok: bool, status: String, reason: String, route: Dictionary, authority_summary: Dictionary, details: Dictionary) -> Dictionary:
	return {
		"ok": ok,
		"status": status,
		"reason": reason,
		"route": route,
		"routeSummary": _route_summary(route),
		"authority": authority_summary.duplicate(true),
		"details": details.duplicate(true),
		"requestId": active_request_id
	}
