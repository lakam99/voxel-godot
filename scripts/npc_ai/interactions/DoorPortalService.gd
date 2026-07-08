extends RefCounted
class_name DoorPortalService

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const InteractionRequestScript := preload("res://scripts/npc_ai/contracts/InteractionRequest.gd")
const DoorPortalScript := preload("res://scripts/npc_ai/interactions/DoorPortal.gd")
const DoorControllerScript := preload("res://scripts/npc_ai/interactions/DoorController.gd")
const DOOR_LIFECYCLE_TRACE_CAPACITY := 512

var main: Node = null
var owner: Node = null
var portals := {}
var controllers := {}
var door_to_portal := {}
var scheduled_closes := {}
var state_revisions := 0
var transition_counts := {
	"open": 0,
	"close": 0,
	"blockedClose": 0
}
var lifecycle_trace: Array[Dictionary] = []

func setup(main_node: Node, owner_node: Node = null) -> void:
	main = main_node
	owner = owner_node

func clear() -> void:
	portals.clear()
	controllers.clear()
	door_to_portal.clear()
	scheduled_closes.clear()
	state_revisions = 0
	transition_counts = { "open": 0, "close": 0, "blockedClose": 0 }
	lifecycle_trace.clear()

func register_door(door: Node, metadata := {}) -> String:
	if door == null or not is_instance_valid(door):
		return ""
	var portal_id := _portal_id_for_door(door, metadata)
	var portal = portals.get(portal_id)
	if portal == null:
		portal = DoorPortalScript.new()
		portal.portal_id = portal_id
		portal.group_id = String(door.get_meta("door_group_id", portal_id))
		portal.policy_id = String(door.get_meta("door_policy", metadata.get("policy", "private_home")))
		portal.public_access = bool(door.get_meta("door_public_access", metadata.get("publicAccess", true)))
		portals[portal_id] = portal
		var controller = DoorControllerScript.new()
		controller.setup(portal, Callable(self, "_on_controller_state_changed"))
		controllers[portal_id] = controller
	portal.add_leaf(door)
	var registered_controller = controllers.get(portal_id)
	if registered_controller != null:
		registered_controller.apply_current_state("register")
	door_to_portal[door.get_instance_id()] = portal_id
	door.set_meta("door_portal_id", portal_id)
	door.set_meta("door_group_id", portal.group_id)
	door.set_meta("door_state", String(portal.state))
	door.set_meta("door_state_revision", portal.state_revision)
	return portal_id

func request_interaction(interaction_request, actors: Array = []):
	var portal_id := resolve_portal_id(interaction_request.get("object_node"), String(interaction_request.get("object_id")))
	if portal_id == "":
		var result = load("res://scripts/npc_ai/contracts/InteractionResult.gd").make(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"missing")
		return result
	var controller = controllers.get(portal_id)
	if controller == null:
		var missing = load("res://scripts/npc_ai/contracts/InteractionResult.gd").make(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"missing")
		return missing
	var before: Dictionary = controller.transition_counts.duplicate()
	var request_actors := _actors_for_request(actors, interaction_request)
	var before_snapshot := _trace_snapshot(portal_id, request_actors)
	var result = controller.request_interaction(interaction_request, request_actors)
	_record_transition_delta(controller, before, result)
	_record_lifecycle_event("request_interaction", portal_id, interaction_request, request_actors, before, controller.transition_counts.duplicate(), result, before_snapshot)
	if result != null and result.status == NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED:
		var command: StringName = interaction_request.get("command")
		if command == NpcEnumsScript.DOOR_COMMAND_OPEN or command == NpcEnumsScript.DOOR_COMMAND_HOLD:
			scheduled_closes.erase(portal_id)
		elif command == NpcEnumsScript.DOOR_COMMAND_DESTROY and owner != null and owner.get("traffic_reservations") != null:
			owner.get("traffic_reservations").destroy_portal(portal_id)
	return result

func request_door_state(door: Node, desired_open: bool, actor: Node = null, actor_kind := "system", metadata := {}):
	var portal_id := register_door(door, metadata)
	var interaction_request = InteractionRequestScript.make(NpcEnumsScript.DOOR_COMMAND_OPEN if desired_open else NpcEnumsScript.DOOR_COMMAND_CLOSE, portal_id, _actor_id(actor, actor_kind), metadata)
	interaction_request.object_node = door
	interaction_request.actor_node = actor
	interaction_request.actor_kind = actor_kind
	interaction_request.desired_state = NpcEnumsScript.DOOR_STATE_OPEN if desired_open else NpcEnumsScript.DOOR_STATE_CLOSED
	return request_interaction(interaction_request, Array(metadata.get("actors", [])))

func request_player_door_use(door: Node, actor: Node = null, actor_kind := "player", metadata := {}):
	door = _interaction_block_from_collider(door)
	if door == null:
		var result = load("res://scripts/npc_ai/contracts/InteractionResult.gd").make(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"missing")
		return result
	var portal_id := register_door(door, metadata)
	var portal = portals.get(portal_id)
	var logical_open: bool = portal != null and portal.state == NpcEnumsScript.DOOR_STATE_OPEN
	var desired_open: bool = not logical_open
	return request_door_state(door, desired_open, actor, actor_kind, metadata)

func hold_open(door: Node, actor: Node, actor_kind := "npc", metadata := {}):
	var portal_id := register_door(door, metadata)
	var interaction_request = InteractionRequestScript.make(NpcEnumsScript.DOOR_COMMAND_HOLD, portal_id, _actor_id(actor, actor_kind), metadata)
	interaction_request.object_node = door
	interaction_request.actor_node = actor
	interaction_request.actor_kind = actor_kind
	interaction_request.desired_state = NpcEnumsScript.DOOR_STATE_OPEN
	return request_interaction(interaction_request, Array(metadata.get("actors", [])))

func release_actor(door_or_portal, actor_id: String, schedule_close := true):
	var portal_id := resolve_portal_id(door_or_portal if door_or_portal is Node else null, String(door_or_portal) if not (door_or_portal is Node) else "")
	if portal_id == "":
		return null
	var interaction_request = InteractionRequestScript.make(NpcEnumsScript.DOOR_COMMAND_RELEASE, portal_id, actor_id)
	interaction_request.actor_kind = "npc"
	var result = request_interaction(interaction_request)
	if schedule_close:
		schedule_close_for_portal(portal_id, NpcConstantsScript.DOOR_PRIVATE_CLOSE_DELAY_SECONDS)
	return result

func schedule_close_for_portal(portal_id: String, delay: float) -> void:
	if portal_id == "":
		return
	scheduled_closes[portal_id] = maxf(0.0, delay)
	_record_lifecycle_note("schedule_close", portal_id, {
		"delay": delay,
		"scheduledCloseRemaining": float(scheduled_closes.get(portal_id, 0.0))
	})

func process(delta: float, actors: Array = []) -> Dictionary:
	var closed := 0
	var blocked := 0
	var blocked_reasons: Array[String] = []
	for portal_id in portals.keys():
		var portal = portals[portal_id]
		if portal != null:
			portal.advance(delta)
			if owner != null and owner.get("traffic_reservations") != null and owner.get("traffic_reservations").has_method("queued_owners_for_resource_prefix"):
				var traffic = owner.get("traffic_reservations")
				var queued_owners: Array = traffic.queued_owners_for_portal(portal_id) if traffic.has_method("queued_owners_for_portal") else traffic.queued_owners_for_resource_prefix("portal:%s" % portal_id)
				for actor_id in queued_owners:
					portal.queue(String(actor_id), "traffic")
	for portal_id in scheduled_closes.keys().duplicate():
		var remaining := float(scheduled_closes.get(portal_id, 0.0)) - delta
		if remaining > 0.0:
			scheduled_closes[portal_id] = remaining
			continue
		var request = InteractionRequestScript.make(NpcEnumsScript.DOOR_COMMAND_CLOSE, portal_id, "policy")
		request.actor_kind = "policy"
		var controller = controllers.get(portal_id)
		if controller == null:
			scheduled_closes.erase(portal_id)
			continue
		var before: Dictionary = controller.transition_counts.duplicate()
		var request_actors := _current_actors(actors)
		var before_snapshot := _trace_snapshot(portal_id, request_actors)
		var result = controller.request_interaction(request, request_actors)
		_record_transition_delta(controller, before, result)
		_record_lifecycle_event("policy_close", portal_id, request, request_actors, before, controller.transition_counts.duplicate(), result, before_snapshot)
		if result != null and result.status == NpcEnumsScript.INTERACTION_STATUS_SUCCEEDED:
			closed += 1
			scheduled_closes.erase(portal_id)
		else:
			blocked += 1
			if result != null:
				blocked_reasons.append("%s:%s" % [portal_id, String(result.reason)])
			scheduled_closes[portal_id] = NpcConstantsScript.DOOR_BLOCKED_CLOSE_RETRY_SECONDS
	return { "closed": closed, "blocked": blocked, "scheduled": scheduled_closes.size(), "blockedReasons": blocked_reasons }

func portal_for_door(door: Node):
	var portal_id := resolve_portal_id(door, "")
	return portals.get(portal_id)

func controller_for_door(door: Node):
	var portal_id := resolve_portal_id(door, "")
	return controllers.get(portal_id)

func resolve_portal_id(door: Node = null, object_id := "") -> String:
	if object_id != "" and portals.has(object_id):
		return object_id
	if door != null:
		door = _interaction_block_from_collider(door)
		if door_to_portal.has(door.get_instance_id()):
			return String(door_to_portal[door.get_instance_id()])
		if door.has_meta("door_portal_id"):
			return String(door.get_meta("door_portal_id"))
	return ""

func stats() -> Dictionary:
	return {
		"portalCount": portals.size(),
		"controllerCount": controllers.size(),
		"scheduledCloses": scheduled_closes.size(),
		"stateRevisions": state_revisions,
		"transitionCounts": transition_counts.duplicate()
	}

func to_summary() -> Dictionary:
	var portal_summaries := {}
	for portal_id in portals.keys():
		portal_summaries[portal_id] = portals[portal_id].to_summary()
	return {
		"stats": stats(),
		"portals": portal_summaries,
		"lifecycleTraceTail": lifecycle_trace_snapshot("", 48)
	}

func lifecycle_trace_snapshot(portal_id := "", limit := 96) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var max_rows := maxi(1, int(limit))
	for index in range(lifecycle_trace.size() - 1, -1, -1):
		var row: Dictionary = lifecycle_trace[index]
		if portal_id != "" and String(row.get("portalId", "")) != portal_id:
			continue
		rows.push_front(row.duplicate(true))
		if rows.size() >= max_rows:
			break
	return rows

func _portal_id_for_door(door: Node, metadata := {}) -> String:
	if door.has_meta("door_portal_id"):
		var door_portal_id := String(door.get_meta("door_portal_id", ""))
		if door_portal_id != "":
			return door_portal_id
	if metadata is Dictionary and String(metadata.get("portalId", "")) != "":
		return String(metadata.get("portalId"))
	var cell: Vector3i = door.get_meta("cell", Vector3i.ZERO)
	return "door:%d,%d,%d" % [cell.x, cell.y, cell.z]

func _actor_id(actor: Node, actor_kind: String) -> String:
	if actor != null and is_instance_valid(actor):
		if actor.has_meta("npc_stable_id"):
			return String(actor.get_meta("npc_stable_id"))
		return "%s:%d" % [actor.name, actor.get_instance_id()]
	return actor_kind

func _actors_for_request(explicit_actors: Array, request) -> Array:
	var result := _current_actors(explicit_actors)
	var actor_node := request.get("actor_node") as Node3D
	if actor_node != null and is_instance_valid(actor_node) and not result.has(actor_node):
		result.append(actor_node)
	return result

func _current_actors(extra: Array = []) -> Array:
	var result: Array = []
	for actor in extra:
		if actor is Node3D and is_instance_valid(actor) and _actor_participates_in_door_policy(actor):
			result.append(actor)
	if main != null:
		var player = main.get("player")
		if player is Node3D and is_instance_valid(player) and _actor_participates_in_door_policy(player) and not result.has(player):
			result.append(player)
		var npc_system = main.get("npc_system")
		if npc_system != null:
			var npcs_value = npc_system.get("npcs")
			if npcs_value is Array:
				for entry in npcs_value:
					if entry is Dictionary:
						var body := (entry as Dictionary).get("body") as Node3D
						if body != null and is_instance_valid(body) and _actor_participates_in_door_policy(body) and not result.has(body):
							result.append(body)
	return result

func _actor_participates_in_door_policy(actor) -> bool:
	var node := actor as Node3D
	if node == null or not is_instance_valid(node):
		return false
	if node is CollisionObject3D:
		var collider := node as CollisionObject3D
		if int(collider.collision_layer) == 0 and int(collider.collision_mask) == 0:
			return false
	return true

func _interaction_block_from_collider(collider: Node) -> Node:
	if collider == null:
		return null
	if main != null and main.has_method("interaction_block_from_collider"):
		var block = main.call("interaction_block_from_collider", collider)
		if block is Node and is_instance_valid(block):
			return block
	return collider

func _record_transition_delta(controller, before: Dictionary, result) -> void:
	if controller == null:
		return
	var after: Dictionary = controller.transition_counts
	var opened := int(after.get("open", 0)) - int(before.get("open", 0))
	var closed := int(after.get("close", 0)) - int(before.get("close", 0))
	if opened > 0:
		transition_counts["open"] = int(transition_counts.get("open", 0)) + opened
	if closed > 0:
		transition_counts["close"] = int(transition_counts.get("close", 0)) + closed
	if result != null and result.status == NpcEnumsScript.INTERACTION_STATUS_FAILED and bool(result.metrics.get("obstructed", false)):
		transition_counts["blockedClose"] = int(transition_counts.get("blockedClose", 0)) + 1

func _record_lifecycle_event(kind: String, portal_id: String, request, actors: Array, before_counts: Dictionary, after_counts: Dictionary, result, before_snapshot: Dictionary) -> void:
	var portal = portals.get(portal_id)
	var result_summary := {}
	if result != null and result.has_method("to_summary"):
		result_summary = result.to_summary()
	elif result != null:
		result_summary = {
			"status": String(result.get("status")),
			"reason": String(result.get("reason")),
			"metrics": result.get("metrics") if result.get("metrics") is Dictionary else {}
		}
	var opened := int(after_counts.get("open", 0)) - int(before_counts.get("open", 0))
	var closed := int(after_counts.get("close", 0)) - int(before_counts.get("close", 0))
	var request_summary: Dictionary = request.to_summary() if request != null and request.has_method("to_summary") else {}
	_record_lifecycle_note(kind, portal_id, {
		"source": _source_for_request(request),
		"request": request_summary,
		"result": result_summary,
		"transitionDelta": {
			"open": opened,
			"close": closed
		},
		"transitionCountsBefore": before_counts.duplicate(true),
		"transitionCountsAfter": after_counts.duplicate(true),
		"stateBefore": before_snapshot.get("state", ""),
		"stateAfter": String(portal.state) if portal != null else "",
		"portalBefore": before_snapshot,
		"portalAfter": _trace_snapshot(portal_id, actors)
	})

func _record_lifecycle_note(kind: String, portal_id: String, metadata := {}) -> void:
	var row := {
		"kind": kind,
		"portalId": portal_id,
		"elapsedMsec": Time.get_ticks_msec(),
		"metadata": metadata.duplicate(true) if metadata is Dictionary else {}
	}
	lifecycle_trace.append(row)
	while lifecycle_trace.size() > DOOR_LIFECYCLE_TRACE_CAPACITY:
		lifecycle_trace.pop_front()

func _source_for_request(request) -> String:
	if request == null:
		return "unknown"
	var actor_kind := String(request.get("actor_kind"))
	var command := String(request.get("command"))
	if actor_kind == "policy":
		return "policy_close"
	if actor_kind == "player":
		return "player_interaction"
	if actor_kind == "npc":
		if command == String(NpcEnumsScript.DOOR_COMMAND_HOLD):
			return "npc_traversal_hold"
		if command == String(NpcEnumsScript.DOOR_COMMAND_RELEASE):
			return "npc_traversal_release"
		if command == String(NpcEnumsScript.DOOR_COMMAND_OPEN):
			return "npc_open_request"
		return "npc_%s" % command
	if actor_kind == "system":
		return "system_%s" % command
	if actor_kind == "":
		return "unspecified_%s" % command
	return "%s_%s" % [actor_kind, command]

func _trace_snapshot(portal_id: String, actors: Array) -> Dictionary:
	var portal = portals.get(portal_id)
	if portal == null:
		return {}
	var controller = controllers.get(portal_id)
	return {
		"state": String(portal.state),
		"stateRevision": int(portal.state_revision),
		"scheduledCloseRemaining": float(scheduled_closes.get(portal_id, -1.0)) if scheduled_closes.has(portal_id) else -1.0,
		"holds": portal.open_holds.keys(),
		"queue": portal.queued_actors.keys(),
		"activeCrossing": portal.active_crossing.duplicate(true) if portal.active_crossing is Dictionary else {},
		"controllerTransitions": controller.transition_counts.duplicate(true) if controller != null else {},
		"thresholdActors": portal.occupied_actors(actors, "threshold"),
		"sweepActors": portal.occupied_actors(actors, "sweep"),
		"clearanceActors": portal.occupied_actors(actors, "clearance"),
		"activeTraversal": _active_traversal_for_portal(portal_id),
		"actors": _actor_trace_rows(portal, actors)
	}

func _active_traversal_for_portal(portal_id: String) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	if owner == null or owner.get("door_traversal") == null:
		return rows
	var traversal = owner.get("door_traversal")
	var crossings: Dictionary = traversal.get("active_crossings") if traversal.get("active_crossings") is Dictionary else {}
	for key in crossings.keys():
		var active: Dictionary = crossings[key]
		if String(active.get("portalId", "")) != portal_id:
			continue
		rows.append({
			"key": String(key),
			"actorId": String(active.get("actorId", "")),
			"direction": String(active.get("direction", "")),
			"groupId": String(active.get("groupId", "")),
			"reservationIds": active.get("reservationIds", [])
		})
	return rows

func _actor_trace_rows(portal, actors: Array) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for actor in actors:
		var node := actor as Node3D
		if node == null or not is_instance_valid(node):
			continue
		var actor_id: String = portal.actor_id_for_node(node) if portal != null else _actor_id(node, "actor")
		var row := {
			"actorId": actor_id,
			"name": String(node.name),
			"position": _vec3(node.global_position),
			"cell": _flat_cell_summary(node.global_position),
			"inThreshold": _bounds_contains(portal.threshold_bounds, node.global_position) if portal != null else false,
			"inSweep": _bounds_contains(portal.sweep_bounds, node.global_position) if portal != null else false,
			"inClearance": _bounds_contains(portal.clearance_bounds, node.global_position) if portal != null else false
		}
		var npc_entry := _npc_entry_for_actor(actor_id, node)
		if not npc_entry.is_empty():
			row["npc"] = _npc_trace_summary(npc_entry)
		rows.append(row)
	return rows

func _npc_entry_for_actor(actor_id: String, node: Node3D) -> Dictionary:
	if main == null:
		return {}
	var npc_system = main.get("npc_system")
	if npc_system == null:
		return {}
	var npcs_value = npc_system.get("npcs")
	if not (npcs_value is Array):
		return {}
	for entry in npcs_value:
		if not (entry is Dictionary):
			continue
		var npc: Dictionary = entry
		if String(npc.get("id", "")) == actor_id:
			return npc
		var body := npc.get("body") as Node3D
		if body == node:
			return npc
	return {}

func _npc_trace_summary(entry: Dictionary) -> Dictionary:
	var home_route_positions: Array = entry.get("homeRoutePositions", []) if entry.get("homeRoutePositions", []) is Array else []
	return {
		"id": String(entry.get("id", "")),
		"name": String(entry.get("name", "")),
		"role": String(entry.get("role", "")),
		"job": String(entry.get("job", "")),
		"goal": String(entry.get("goal", "")),
		"activeGoalKind": String(entry.get("activeGoalKind", "")),
		"scheduleState": String(entry.get("scheduleState", "")),
		"jobPhase": String(entry.get("jobPhase", "")),
		"routeStatus": String(entry.get("routeStatus", "")),
		"routeReason": String(entry.get("routeReason", "")),
		"routeGoalCell": _vec2i(entry.get("routeGoalCell", Vector2i(999999, 999999))),
		"homeActiveTargetCell": _vec2i(entry.get("homeActiveTargetCell", Vector2i(999999, 999999))),
		"insideHome": bool(entry.get("insideHome", false)),
		"movingHome": bool(entry.get("movingHome", false)),
		"routeMovingHome": bool(entry.get("routeMovingHome", false)),
		"activeDoorPortalId": String(entry.get("activeDoorPortalId", "")),
		"activeDoorDirection": String(entry.get("activeDoorDirection", "")),
		"homeRouteIndex": int(entry.get("homeRouteIndex", 0)),
		"homeRoutePositionCount": home_route_positions.size(),
		"homeSettleDebug": entry.get("homeSettleDebug", {}).duplicate(true) if entry.get("homeSettleDebug", {}) is Dictionary else {}
	}

func _bounds_contains(bounds: AABB, position: Vector3) -> bool:
	if bounds.size == Vector3.ZERO:
		return false
	var expanded := bounds.grow(NpcConstantsScript.DEFAULT_NPC_RADIUS)
	expanded.position.y -= NpcConstantsScript.CELL_SIZE
	expanded.size.y += NpcConstantsScript.CELL_SIZE
	return expanded.has_point(position)

func _flat_cell_summary(position: Vector3) -> Dictionary:
	return {
		"x": roundi(position.x / NpcConstantsScript.CELL_SIZE),
		"z": roundi(position.z / NpcConstantsScript.CELL_SIZE)
	}

func _vec2i(value) -> Dictionary:
	if value is Vector2i:
		return { "x": value.x, "z": value.y }
	return {}

func _vec3(value: Vector3) -> Dictionary:
	return {
		"x": snappedf(value.x, 0.001),
		"y": snappedf(value.y, 0.001),
		"z": snappedf(value.z, 0.001)
	}

func _on_controller_state_changed(portal, reason: String) -> void:
	state_revisions += 1
	if owner != null and owner.has_method("emit_door_state_revision"):
		for leaf in portal.leaf_nodes.duplicate():
			if leaf == null or not is_instance_valid(leaf):
				portal.leaf_nodes.erase(leaf)
				continue
			owner.call("emit_door_state_revision", leaf, portal.state == NpcEnumsScript.DOOR_STATE_OPEN, reason, portal.state_revision)
