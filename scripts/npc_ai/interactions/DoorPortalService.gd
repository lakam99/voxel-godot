extends RefCounted
class_name DoorPortalService

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const InteractionRequestScript := preload("res://scripts/npc_ai/contracts/InteractionRequest.gd")
const DoorPortalScript := preload("res://scripts/npc_ai/interactions/DoorPortal.gd")
const DoorControllerScript := preload("res://scripts/npc_ai/interactions/DoorController.gd")

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
	var result = controller.request_interaction(interaction_request, _actors_for_request(actors, interaction_request))
	_record_transition_delta(controller, before, result)
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

func request_door_toggle(door: Node, actor: Node = null, actor_kind := "player", metadata := {}):
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
	var result = request_interaction(interaction_request)
	if schedule_close:
		schedule_close_for_portal(portal_id, NpcConstantsScript.DOOR_PRIVATE_CLOSE_DELAY_SECONDS)
	return result

func schedule_close_for_portal(portal_id: String, delay: float) -> void:
	if portal_id == "":
		return
	scheduled_closes[portal_id] = maxf(0.0, delay)

func process(delta: float, actors: Array = []) -> Dictionary:
	var closed := 0
	var blocked := 0
	var blocked_reasons: Array[String] = []
	for portal_id in portals.keys():
		var portal = portals[portal_id]
		if portal != null:
			portal.advance(delta)
			if owner != null and owner.get("traffic_reservations") != null and owner.get("traffic_reservations").has_method("queued_owners_for_resource_prefix"):
				for actor_id in owner.get("traffic_reservations").queued_owners_for_resource_prefix("portal:%s" % portal_id):
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
		var result = controller.request_interaction(request, _current_actors(actors))
		_record_transition_delta(controller, before, result)
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
		"portals": portal_summaries
	}

func _portal_id_for_door(door: Node, metadata := {}) -> String:
	if metadata is Dictionary and String(metadata.get("portalId", "")) != "":
		return String(metadata.get("portalId"))
	if door.has_meta("door_portal_id"):
		return String(door.get_meta("door_portal_id"))
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
		if actor is Node3D and is_instance_valid(actor):
			result.append(actor)
	if main != null:
		var player = main.get("player")
		if player is Node3D and is_instance_valid(player) and not result.has(player):
			result.append(player)
		var npc_system = main.get("npc_system")
		if npc_system != null:
			var npcs_value = npc_system.get("npcs")
			if npcs_value is Array:
				for entry in npcs_value:
					if entry is Dictionary:
						var body := (entry as Dictionary).get("body") as Node3D
						if body != null and is_instance_valid(body) and not result.has(body):
							result.append(body)
	return result

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

func _on_controller_state_changed(portal, reason: String) -> void:
	state_revisions += 1
	if owner != null and owner.has_method("emit_door_state_revision"):
		for leaf in portal.leaf_nodes.duplicate():
			if leaf == null or not is_instance_valid(leaf):
				portal.leaf_nodes.erase(leaf)
				continue
			owner.call("emit_door_state_revision", leaf, portal.state == NpcEnumsScript.DOOR_STATE_OPEN, reason, portal.state_revision)
