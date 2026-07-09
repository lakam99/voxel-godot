extends RefCounted
class_name NpcDebugStateExporter

func build_export(scenario_name: String, observation: Dictionary) -> Dictionary:
	var route_state := _route_state(observation)
	var task_state := _task_state(scenario_name, observation)
	var door_state := _door_state(observation)
	var slot_state := _slot_state(scenario_name, observation)
	var result := {
		"schemaVersion": 1,
		"kind": "npc_debug_state",
		"scenario": scenario_name,
		"timeMode": String(observation.get("timeMode", "")),
		"routeState": route_state,
		"taskState": task_state,
		"doorState": door_state,
		"slotState": slot_state,
		"summary": {
			"routes": int(route_state.get("count", 0)),
			"tasks": int(task_state.get("count", 0)),
			"doors": int(door_state.get("count", 0)),
			"slots": int(slot_state.get("count", 0))
		}
	}
	result["overlayLines"] = overlay_lines(result)
	result["validation"] = validate_export(result)
	return result

func build_runtime_export(npc_stats: Dictionary, autonomy_stats: Dictionary = {}, npc_entries: Array = []) -> Dictionary:
	var route_state := _runtime_route_state(npc_stats, npc_entries)
	var task_state := _runtime_task_state(autonomy_stats, npc_entries)
	var door_state := _runtime_door_state(autonomy_stats)
	var slot_state := _runtime_slot_state(autonomy_stats)
	var result := {
		"schemaVersion": 1,
		"kind": "npc_debug_state_runtime",
		"scenario": "Runtime",
		"timeMode": "",
		"routeState": route_state,
		"taskState": task_state,
		"doorState": door_state,
		"slotState": slot_state,
		"summary": {
			"routes": int(route_state.get("count", 0)),
			"tasks": int(task_state.get("count", 0)),
			"doors": int(door_state.get("count", 0)),
			"slots": int(slot_state.get("count", 0))
		}
	}
	result["overlayLines"] = overlay_lines(result)
	result["validation"] = validate_export(result)
	return result

func overlay_lines(export: Dictionary) -> Array[String]:
	var summary: Dictionary = export.get("summary", {}) if export.get("summary", {}) is Dictionary else {}
	var route_state: Dictionary = export.get("routeState", {}) if export.get("routeState", {}) is Dictionary else {}
	var door_state: Dictionary = export.get("doorState", {}) if export.get("doorState", {}) is Dictionary else {}
	var task_state: Dictionary = export.get("taskState", {}) if export.get("taskState", {}) is Dictionary else {}
	var slot_state: Dictionary = export.get("slotState", {}) if export.get("slotState", {}) is Dictionary else {}
	var route_reasons: Dictionary = route_state.get("routeReasons", {}) if route_state.get("routeReasons", {}) is Dictionary else {}
	var route_waits: Dictionary = route_state.get("routeWaitFrames", {}) if route_state.get("routeWaitFrames", {}) is Dictionary else {}
	var lines: Array[String] = [
		"NPC Debug: %s %s" % [String(export.get("scenario", "")), String(export.get("timeMode", ""))],
		"Routes %d  Tasks %d  Doors %d  Slots %d" % [int(summary.get("routes", 0)), int(summary.get("tasks", 0)), int(summary.get("doors", 0)), int(summary.get("slots", 0))],
		"Door unsafe=%d activeCrossings=%d" % [int(door_state.get("unsafeClosedDoors", 0)), int(door_state.get("activeCrossings", 0))],
		"Task failures=%d slotWaits=%d" % [int(task_state.get("failedTasks", 0)), int(slot_state.get("waiting", 0))]
	]
	lines.append("Route waits route=%d tile=%d reasons=%s" % [int(route_waits.get("maxRouteBudget", 0)), int(route_waits.get("maxNavmeshTileBudget", 0)), JSON.stringify(route_reasons)])
	return lines

func _runtime_route_state(npc_stats: Dictionary, npc_entries: Array) -> Dictionary:
	var route_counts: Dictionary = npc_stats.get("routeStatus", {}) if npc_stats.get("routeStatus", {}) is Dictionary else {}
	var route_reasons: Dictionary = npc_stats.get("routeReasons", {}) if npc_stats.get("routeReasons", {}) is Dictionary else {}
	var route_authority_states: Dictionary = npc_stats.get("routeAuthorityStates", {}) if npc_stats.get("routeAuthorityStates", {}) is Dictionary else {}
	var route_authority_reasons: Dictionary = npc_stats.get("routeAuthorityReasons", {}) if npc_stats.get("routeAuthorityReasons", {}) is Dictionary else {}
	var route_waits: Dictionary = npc_stats.get("routeWaitFrames", {}) if npc_stats.get("routeWaitFrames", {}) is Dictionary else {}
	var routes := []
	for entry_value in npc_entries:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		var path_waypoints: Array = entry.get("pathWaypoints", []) if entry.get("pathWaypoints", []) is Array else []
		var route_cells: Array = entry.get("routeCells", []) if entry.get("routeCells", []) is Array else []
		var route_actions: Dictionary = entry.get("routeActions", {}) if entry.get("routeActions", {}) is Dictionary else {}
		routes.append({
			"actorId": _entry_actor_id(entry),
			"goal": String(entry.get("goal", "idle")),
			"goalReason": String(entry.get("goalReason", "")),
			"status": String(entry.get("routeStatus", "idle")),
			"reason": String(entry.get("routeReason", "")),
			"targetCell": str(entry.get("routeGoalCell", "")),
			"pathAge": float(entry.get("pathRefreshTimer", 0.0)),
			"waypoints": path_waypoints.size(),
			"cells": route_cells.size(),
			"actions": route_actions.size(),
			"nextDoor": String(entry.get("activeDoorPortalId", "")),
			"routeKey": String(entry.get("routeKey", "")),
			"pendingKey": String(entry.get("routePendingKey", "")),
			"snapshotRevision": String(entry.get("routeSnapshotRevision", "")),
			"pendingSnapshotRevision": String(entry.get("routePendingSnapshotRevision", "")),
			"routeBudgetWaitFrames": int(entry.get("routeBudgetWaitFrames", 0)),
			"navmeshTileBudgetWaitFrames": int(entry.get("navmeshTileBudgetWaitFrames", 0)),
			"lastRoutePlanDebug": entry.get("lastRoutePlanDebug", {}),
			"lastRouteAuthority": entry.get("lastRouteAuthority", {}),
			"lastRouteCollisionProbe": entry.get("lastRouteCollisionProbe", {}),
			"lastNavmeshTilePublishDebug": entry.get("lastNavmeshTilePublishDebug", [])
		})
	return {
		"count": int(npc_stats.get("npcs", routes.size())),
		"routes": routes,
		"routeStatus": route_counts.duplicate(true),
		"routeReasons": route_reasons.duplicate(true),
		"routeAuthorityStates": route_authority_states.duplicate(true),
		"routeAuthorityReasons": route_authority_reasons.duplicate(true),
		"routeWaitFrames": route_waits.duplicate(true),
		"blockedMoves": int(npc_stats.get("blockedMoves", 0)),
		"routeReplans": int(npc_stats.get("routeReplans", 0)),
		"stuckRecoveries": int(npc_stats.get("stuckRecoveries", 0)),
		"reservationWaits": int(npc_stats.get("reservationWaits", 0)),
		"unreachableGoals": int(npc_stats.get("unreachableGoals", 0))
	}

func _runtime_task_state(autonomy_stats: Dictionary, npc_entries: Array) -> Dictionary:
	var behavior: Dictionary = autonomy_stats.get("behavior", {}) if autonomy_stats.get("behavior", {}) is Dictionary else {}
	var compliance: Dictionary = behavior.get("complianceCounters", {}) if behavior.get("complianceCounters", {}) is Dictionary else {}
	var tasks := []
	var failed_tasks := 0
	for entry_value in npc_entries:
		if not (entry_value is Dictionary):
			continue
		var entry: Dictionary = entry_value
		var route_status := String(entry.get("routeStatus", "idle"))
		var status := "active"
		if route_status == "blocked" or route_status == "unreachable" or String(entry.get("jobFailureReason", "")) != "":
			status = "failed"
			failed_tasks += 1
		elif route_status == "waiting" or String(entry.get("jobPhase", "")) == "searching":
			status = "waiting"
		elif String(entry.get("goal", "idle")) == "idle":
			status = "idle"
		tasks.append({
			"actorId": _entry_actor_id(entry),
			"goal": String(entry.get("goal", "idle")),
			"goalReason": String(entry.get("goalReason", "")),
			"job": String(entry.get("job", "")),
			"jobPhase": String(entry.get("jobPhase", "idle")),
			"taskId": _entry_task_id(entry),
			"scheduleState": String(entry.get("scheduleState", "")),
			"status": status
		})
	return {
		"count": tasks.size(),
		"tasks": tasks,
		"failedTasks": failed_tasks,
		"complianceCounters": compliance.duplicate(true),
		"complianceSamples": _counter_total(compliance)
	}

func _runtime_door_state(autonomy_stats: Dictionary) -> Dictionary:
	var door_portals: Dictionary = autonomy_stats.get("doorPortals", {}) if autonomy_stats.get("doorPortals", {}) is Dictionary else {}
	var door_traversal: Dictionary = autonomy_stats.get("doorTraversal", {}) if autonomy_stats.get("doorTraversal", {}) is Dictionary else {}
	var transition_counts: Dictionary = door_portals.get("transitionCounts", {}) if door_portals.get("transitionCounts", {}) is Dictionary else {}
	var traversal_metrics: Dictionary = door_traversal.get("metrics", {}) if door_traversal.get("metrics", {}) is Dictionary else {}
	return {
		"count": int(door_portals.get("portalCount", 0)),
		"activeCrossings": int(door_traversal.get("activeCrossings", 0)),
		"unsafeClosedDoors": int(transition_counts.get("blockedClose", traversal_metrics.get("blockedClose", 0))),
		"controllerCount": int(door_portals.get("controllerCount", 0)),
		"scheduledCloses": int(door_portals.get("scheduledCloses", 0)),
		"stateRevisions": int(door_portals.get("stateRevisions", 0)),
		"transitionCounts": transition_counts.duplicate(true),
		"traversalMetrics": traversal_metrics.duplicate(true)
	}

func _runtime_slot_state(autonomy_stats: Dictionary) -> Dictionary:
	var smart_objects: Dictionary = autonomy_stats.get("smartObjects", {}) if autonomy_stats.get("smartObjects", {}) is Dictionary else {}
	var traffic: Dictionary = autonomy_stats.get("traffic", {}) if autonomy_stats.get("traffic", {}) is Dictionary else {}
	var smart_counters: Dictionary = smart_objects.get("counters", {}) if smart_objects.get("counters", {}) is Dictionary else {}
	var active_reservations := int(traffic.get("activeReservations", traffic.get("reservationCount", 0)))
	var smart_reservations := int(smart_objects.get("reservations", 0))
	return {
		"count": smart_reservations + active_reservations,
		"registeredObjects": int(smart_objects.get("registrations", 0)),
		"smartReservations": smart_reservations,
		"trafficReservations": active_reservations,
		"waiting": int(traffic.get("queueLength", traffic.get("waiting", 0))),
		"ownerCount": int(traffic.get("ownerCount", 0)),
		"completedEffects": int(smart_objects.get("completedEffects", 0)),
		"counters": smart_counters.duplicate(true)
	}

func validate_export(export: Dictionary) -> Dictionary:
	var problems: Array[String] = []
	for key in ["routeState", "taskState", "doorState", "slotState"]:
		if not (export.get(key, {}) is Dictionary):
			problems.append("missing_%s" % key)
	var overlay: Array = export.get("overlayLines", [])
	if overlay.is_empty():
		problems.append("missing_overlay_lines")
	var summary: Dictionary = export.get("summary", {}) if export.get("summary", {}) is Dictionary else {}
	for key in ["routes", "tasks", "doors", "slots"]:
		if int(summary.get(key, 0)) < 0:
			problems.append("invalid_summary_%s" % key)
	return {
		"ok": problems.is_empty(),
		"problems": problems
	}

func _route_state(observation: Dictionary) -> Dictionary:
	var routes := []
	for npc_value in observation.get("npcs", []):
		if not (npc_value is Dictionary):
			continue
		var npc_data: Dictionary = npc_value
		var status := _route_status_for_npc(npc_data)
		routes.append({
			"actorId": String(npc_data.get("id", "")),
			"goal": String(npc_data.get("goal", "")),
			"status": status,
			"location": String(npc_data.get("location", "")),
			"homeInterior": String(npc_data.get("homeInterior", "")),
			"guardPost": String(npc_data.get("guardPost", ""))
		})
	return {
		"count": routes.size(),
		"routes": routes
	}

func _task_state(scenario_name: String, observation: Dictionary) -> Dictionary:
	var tasks := []
	var failed_tasks := 0
	for npc_value in observation.get("npcs", []):
		if not (npc_value is Dictionary):
			continue
		var npc_data: Dictionary = npc_value
		var state := String(npc_data.get("state", ""))
		var task_status := "active"
		if state.find("wait") >= 0:
			task_status = "waiting"
		elif state.find("blocked") >= 0 or state.find("failed") >= 0:
			task_status = "failed"
			failed_tasks += 1
		tasks.append({
			"actorId": String(npc_data.get("id", "")),
			"role": String(npc_data.get("role", "")),
			"taskId": state,
			"goal": String(npc_data.get("goal", "")),
			"status": task_status
		})
	var timeline := []
	for item in observation.get("timeline", []):
		if item is Dictionary:
			timeline.append((item as Dictionary).duplicate(true))
	return {
		"count": tasks.size(),
		"scenario": scenario_name,
		"tasks": tasks,
		"timeline": timeline,
		"failedTasks": failed_tasks
	}

func _door_state(observation: Dictionary) -> Dictionary:
	var doors := []
	var unsafe_closed := 0
	for door_value in observation.get("finalDoorStates", []):
		if not (door_value is Dictionary):
			continue
		var door: Dictionary = door_value
		var state := String(door.get("state", "closed"))
		var occupants := int(door.get("thresholdOccupants", 0))
		if state == "closed" and occupants > 0:
			unsafe_closed += 1
		doors.append({
			"doorId": String(door.get("doorId", "")),
			"state": state,
			"thresholdOccupants": occupants,
			"heldBy": String(door.get("heldBy", ""))
		})
	var crossings := []
	for crossing_value in observation.get("doorCrossings", []):
		if crossing_value is Dictionary:
			crossings.append((crossing_value as Dictionary).duplicate(true))
	return {
		"count": doors.size(),
		"doors": doors,
		"crossings": crossings,
		"activeCrossings": crossings.size(),
		"unsafeClosedDoors": unsafe_closed
	}

func _slot_state(scenario_name: String, observation: Dictionary) -> Dictionary:
	var slots := []
	var waiting := 0
	for npc_value in observation.get("npcs", []):
		if not (npc_value is Dictionary):
			continue
		var npc_data: Dictionary = npc_value
		var state := String(npc_data.get("state", ""))
		var location := String(npc_data.get("location", ""))
		if location == "work" or state.find("resource") >= 0 or state.find("queue") >= 0 or state.find("stall") >= 0:
			var status := "waiting" if state.find("queue") >= 0 else "occupied"
			if status == "waiting":
				waiting += 1
			slots.append({
				"slotId": "%s:%s" % [scenario_name, String(npc_data.get("id", ""))],
				"ownerId": String(npc_data.get("id", "")),
				"kind": _slot_kind_for_state(state, location),
				"status": status,
				"taskId": state
			})
	for event_value in observation.get("trafficEvents", []):
		if not (event_value is Dictionary):
			continue
		var event: Dictionary = event_value
		if String(event.get("event", "")) == "queue":
			waiting += int(event.get("actors", 0))
	return {
		"count": slots.size(),
		"slots": slots,
		"waiting": waiting
	}

func _route_status_for_npc(npc_data: Dictionary) -> String:
	var state := String(npc_data.get("state", ""))
	var location := String(npc_data.get("location", ""))
	if state.find("blocked") >= 0:
		return "blocked"
	if state.find("repair") >= 0:
		return "repairing"
	if state.find("queue") >= 0:
		return "queued"
	if location in ["indoors", "work"]:
		return "arrived"
	return "moving"

func _slot_kind_for_state(state: String, location: String) -> String:
	if state.find("door") >= 0 or state.find("queue") >= 0:
		return "door_bottleneck"
	if state.find("resource") >= 0 or state.find("gather") >= 0:
		return "resource"
	if state.find("stall") >= 0 or state.find("serve") >= 0:
		return "trader_stall"
	if location == "work":
		return "work_anchor"
	return "semantic"

func _entry_actor_id(entry: Dictionary) -> String:
	if String(entry.get("id", "")) != "":
		return String(entry.get("id"))
	var body := entry.get("body") as Node
	if body != null and is_instance_valid(body):
		if body.has_meta("npc_stable_id"):
			return String(body.get_meta("npc_stable_id"))
		return body.name
	return "npc"

func _entry_task_id(entry: Dictionary) -> String:
	var plan: Dictionary = entry.get("currentPlan", {}) if entry.get("currentPlan", {}) is Dictionary else {}
	var actions: Array = plan.get("actionIds", []) if plan.get("actionIds", []) is Array else []
	if not actions.is_empty():
		return String(actions[0])
	var job_phase := String(entry.get("jobPhase", "idle"))
	if job_phase != "" and job_phase != "idle":
		return "%s:%s" % [String(entry.get("job", "")), job_phase]
	return String(entry.get("goal", "idle"))

func _counter_total(counters: Dictionary) -> int:
	var total := 0
	for value in counters.values():
		total += int(value)
	return total
