extends RefCounted
class_name NpcRouteTicketBroker

const RouteTicketScript := preload("res://scripts/npc_ai/contracts/RouteTicket.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

const CELL := 1.35
const MAX_TICKET_JOBS_PER_FRAME := 12
const MAX_TICKET_ATTEMPTS_BEFORE_FAILURE := 240

var system = null
var main = null
var world = null
var authority_planner = null
var tickets_by_actor := {}
var ticket_order: Array[String] = []
var sequence := 0
var generation_by_actor := {}

func setup(system_node, main_node, navigation_world, planner) -> void:
	system = system_node
	main = main_node
	world = navigation_world
	authority_planner = planner

func begin_frame() -> void:
	if not NpcConstantsScript.NPC_NAV_ENABLE_ROUTE_TICKET_PIPELINE:
		return
	_process_tickets(MAX_TICKET_JOBS_PER_FRAME)

func invalidate() -> void:
	for ticket_value in tickets_by_actor.values():
		var ticket = ticket_value
		if ticket != null:
			ticket.state = RouteTicketScript.State.INVALIDATED
			ticket.reason = "navigation_invalidated"
			ticket.updated_frame = Engine.get_physics_frames()
	tickets_by_actor.clear()
	ticket_order.clear()

func plan_route(entry: Dictionary, intent: Dictionary) -> Dictionary:
	if not NpcConstantsScript.NPC_NAV_ENABLE_ROUTE_TICKET_PIPELINE:
		return authority_planner.plan_route(entry, intent) if authority_planner != null and authority_planner.has_method("plan_route") else _failure("blocked", "missing_authority_planner", intent)

	var actor_id := String(entry.get("id", "npc"))
	var key_info := _ticket_key(entry, intent)
	var key := String(key_info.get("key", ""))
	var goal_key := String(key_info.get("goalKey", ""))
	var ticket = tickets_by_actor.get(actor_id, null)
	var current_waypoints: Array = entry.get("pathWaypoints", []) if entry.get("pathWaypoints", []) is Array else []
	var fresh_start_replan: bool = ticket != null \
		and ticket.key != key \
		and ticket.is_ready() \
		and current_waypoints.is_empty() \
		and bool(entry.get("routeForceReplan", false))

	if ticket == null or ticket.goal_key != goal_key or fresh_start_replan:
		ticket = _submit_ticket(entry, actor_id, key_info, intent)
		tickets_by_actor[actor_id] = ticket
		ticket_order.erase(actor_id)
		ticket_order.append(actor_id)
		_publish_ticket_state(ticket, entry)
		return ticket.to_pending_route()

	_publish_ticket_state(ticket, entry)

	if ticket.is_ready():
		var ready_route: Dictionary = ticket.route.duplicate(true)
		ready_route["ticketId"] = ticket.ticket_id
		ready_route["routeTicketState"] = ticket.state_name()
		ticket.state = RouteTicketScript.State.FOLLOWING
		ticket.updated_frame = Engine.get_physics_frames()
		_publish_ticket_state(ticket, entry)
		return ready_route

	if ticket.is_terminal_failure():
		var failed_route: Dictionary = ticket.route.duplicate(true) if ticket.route is Dictionary else {}
		if failed_route.is_empty():
			failed_route = _failure("blocked", ticket.reason, intent)
		failed_route["ticketId"] = ticket.ticket_id
		failed_route["routeTicketState"] = ticket.state_name()
		_publish_ticket_state(ticket, entry)
		return failed_route

	return ticket.to_pending_route()

func stats() -> Dictionary:
	var states := {}
	for ticket_value in tickets_by_actor.values():
		var ticket = ticket_value
		if ticket == null:
			continue
		var ticket_state_name := String(ticket.state_name())
		states[ticket_state_name] = int(states.get(ticket_state_name, 0)) + 1
	var planner_stats: Dictionary = authority_planner.stats() if authority_planner != null and authority_planner.has_method("stats") else {}
	return {
		"tickets": tickets_by_actor.size(),
		"ticketStates": states,
		"ticketOrder": ticket_order.duplicate(),
		"delegate": planner_stats
	}

func _process_tickets(max_jobs: int) -> void:
	if authority_planner == null or not authority_planner.has_method("plan_route"):
		return
	var now := Engine.get_physics_frames()
	var jobs := 0
	var actors := ticket_order.duplicate()
	for actor_id_value in actors:
		if jobs >= max_jobs:
			break
		var actor_id := String(actor_id_value)
		var ticket = tickets_by_actor.get(actor_id, null)
		if ticket == null:
			ticket_order.erase(actor_id)
			continue
		if not ticket.is_pending():
			continue
		if ticket.retry_frame > now:
			continue
		jobs += 1
		_process_one_ticket(ticket)

func _process_one_ticket(ticket) -> void:
	ticket.attempts += 1
	ticket.updated_frame = Engine.get_physics_frames()
	ticket.state = RouteTicketScript.State.PLANNING
	ticket.reason = "planning"

	var actor_entry := _entry_for_actor(ticket.actor_id)
	var request_context := _apply_ticket_request_context(ticket, actor_entry)
	var route: Dictionary = authority_planner.plan_route(actor_entry, _planner_intent_for_ticket(ticket))
	_restore_ticket_request_context(actor_entry, request_context)
	var status := String(route.get("status", ""))
	var reason := String(route.get("reason", ""))
	var authority_state := String(route.get("routeAuthorityState", ""))

	if status == "pending" or bool(route.get("routeAuthorityPending", false)):
		ticket.route = route.duplicate(true)
		ticket.reason = reason if reason != "" else "route_pending"
		if authority_state == "pending_nav_data":
			ticket.state = RouteTicketScript.State.WAITING_NAV_DATA
		elif authority_state == "pending_probe":
			ticket.state = RouteTicketScript.State.PROBING
		else:
			ticket.state = RouteTicketScript.State.QUEUED
		ticket.retry_frame = Engine.get_physics_frames() + _retry_frames_for_reason(ticket.reason)
		if ticket.attempts >= MAX_TICKET_ATTEMPTS_BEFORE_FAILURE:
			ticket.state = RouteTicketScript.State.FAILED_INTERNAL
			ticket.reason = "ticket_attempt_limit"
		_publish_ticket_state(ticket, actor_entry)
		return

	if bool(route.get("ok", false)) and bool(route.get("routeAuthorityReady", false)) and not (route.get("waypoints", []) as Array).is_empty():
		ticket.route = route.duplicate(true)
		ticket.state = RouteTicketScript.State.READY
		ticket.reason = "ready"
		ticket.retry_frame = Engine.get_physics_frames()
		_publish_ticket_state(ticket, actor_entry)
		return

	ticket.route = route.duplicate(true)
	if status in ["blocked", "unreachable", "partial"]:
		ticket.state = RouteTicketScript.State.FAILED_UNREACHABLE
		ticket.reason = reason if reason != "" else status
	elif status in ["cancelled"]:
		ticket.state = RouteTicketScript.State.CANCELLED
		ticket.reason = reason if reason != "" else "cancelled"
	else:
		ticket.state = RouteTicketScript.State.FAILED_INTERNAL
		ticket.reason = reason if reason != "" else "route_failed"
	_publish_ticket_state(ticket, actor_entry)

func _submit_ticket(entry: Dictionary, actor_id: String, key_info: Dictionary, intent: Dictionary):
	sequence += 1
	var generation := int(generation_by_actor.get(actor_id, 0)) + 1
	generation_by_actor[actor_id] = generation
	var ticket_intent := intent.duplicate(true)
	if entry.has("_externalDirectMoveFrame"):
		ticket_intent["_routeTicketExternalDirectMoveFrame"] = int(entry.get("_externalDirectMoveFrame", Engine.get_physics_frames()))
	if entry.has("_standaloneNpcUpdateFrame"):
		ticket_intent["_routeTicketStandaloneNpcUpdateFrame"] = int(entry.get("_standaloneNpcUpdateFrame", Engine.get_process_frames()))
	var ticket = RouteTicketScript.new()
	ticket.configure(
		"ticket:%s:%06d" % [actor_id, sequence],
		actor_id,
		String(key_info.get("key", "")),
		String(key_info.get("goalKey", "")),
		key_info.get("startCell", Vector2i(999999, 999999)),
		key_info.get("targetCell", Vector2i(999999, 999999)),
		ticket_intent,
		generation
	)
	return ticket

func _publish_ticket_state(ticket, entry: Dictionary) -> void:
	if ticket == null:
		return
	entry["routeTicketId"] = ticket.ticket_id
	entry["routeTicketState"] = ticket.state_name()
	entry["routeTicketReason"] = ticket.reason
	entry["routeTicketAttempts"] = ticket.attempts
	entry["routeTicketUpdatedFrame"] = ticket.updated_frame

func _planner_intent_for_ticket(ticket) -> Dictionary:
	var planner_intent: Dictionary = ticket.intent.duplicate(true) if ticket.intent is Dictionary else {}
	planner_intent.erase("_routeTicketExternalDirectMoveFrame")
	planner_intent.erase("_routeTicketStandaloneNpcUpdateFrame")
	return planner_intent

func _apply_ticket_request_context(ticket, entry: Dictionary) -> Dictionary:
	var context := {
		"hadExternalDirectMoveFrame": entry.has("_externalDirectMoveFrame"),
		"externalDirectMoveFrame": entry.get("_externalDirectMoveFrame", null),
		"hadStandaloneNpcUpdateFrame": entry.has("_standaloneNpcUpdateFrame"),
		"standaloneNpcUpdateFrame": entry.get("_standaloneNpcUpdateFrame", null)
	}
	if ticket.intent is Dictionary and (ticket.intent as Dictionary).has("_routeTicketExternalDirectMoveFrame"):
		entry["_externalDirectMoveFrame"] = Engine.get_physics_frames()
	if ticket.intent is Dictionary and (ticket.intent as Dictionary).has("_routeTicketStandaloneNpcUpdateFrame"):
		entry["_standaloneNpcUpdateFrame"] = Engine.get_process_frames()
	return context

func _restore_ticket_request_context(entry: Dictionary, context: Dictionary) -> void:
	if bool(context.get("hadExternalDirectMoveFrame", false)):
		entry["_externalDirectMoveFrame"] = context.get("externalDirectMoveFrame")
	else:
		entry.erase("_externalDirectMoveFrame")
	if bool(context.get("hadStandaloneNpcUpdateFrame", false)):
		entry["_standaloneNpcUpdateFrame"] = context.get("standaloneNpcUpdateFrame")
	else:
		entry.erase("_standaloneNpcUpdateFrame")

func _ticket_key(entry: Dictionary, intent: Dictionary) -> Dictionary:
	var target: Vector3 = intent.get("target", Vector3.ZERO)
	var target_cell: Vector2i = intent.get("targetCell", world.world_cell(target) if world != null and world.has_method("world_cell") else Vector2i(roundi(target.x / CELL), roundi(target.z / CELL)))
	var body := entry.get("body") as Node3D
	var start_position: Vector3 = body.global_position if body != null and is_instance_valid(body) else entry.get("porchPosition", target)
	var start_cell: Vector2i = world.world_cell(start_position) if world != null and world.has_method("world_cell") else Vector2i(roundi(start_position.x / CELL), roundi(start_position.z / CELL))
	var revision := String(world.revision()) if world != null and world.has_method("revision") else ""
	var goal_key := "%s:%d,%d:%s:%s:%s:%s:%.3f" % [
		String(intent.get("kind", "move")),
		target_cell.x,
		target_cell.y,
		str(bool(intent.get("allowOutside", false))),
		str(bool(intent.get("movingHome", false))),
		String(intent.get("action", "")),
		str(bool(intent.get("strictArrival", false))),
		float(intent.get("arrivalRadius", CELL * 0.75))
	]
	var key := "%d,%d->%s:%s" % [start_cell.x, start_cell.y, goal_key, revision]
	return {
		"key": key,
		"goalKey": goal_key,
		"startCell": start_cell,
		"targetCell": target_cell
	}

func _entry_for_actor(actor_id: String) -> Dictionary:
	if system == null:
		return { "id": actor_id }
	var by_id = system.get("npc_by_id")
	if by_id is Dictionary and (by_id as Dictionary).has(actor_id):
		var entry = (by_id as Dictionary).get(actor_id)
		if entry is Dictionary:
			return entry
	var entries = system.get("npcs")
	if entries is Array:
		for entry_value in entries:
			if entry_value is Dictionary and String((entry_value as Dictionary).get("id", "")) == actor_id:
				return entry_value
	return { "id": actor_id }

func _retry_frames_for_reason(reason: String) -> int:
	if reason in ["route_budget", "navmesh_tile_budget", "collision_probe_budget"]:
		return 1
	if reason.find("navmesh") >= 0 or reason.find("tile") >= 0:
		return 2
	return 1

func _failure(status: String, reason: String, intent: Dictionary) -> Dictionary:
	var target_cell: Vector2i = intent.get("targetCell", Vector2i(999999, 999999))
	return {
		"ok": false,
		"status": status,
		"reason": reason,
		"targetCell": target_cell,
		"fallbackCell": target_cell,
		"cells": [],
		"waypoints": [],
		"actions": {},
		"routeAuthorityReady": false,
		"routeAuthorityState": "failed_internal"
	}
