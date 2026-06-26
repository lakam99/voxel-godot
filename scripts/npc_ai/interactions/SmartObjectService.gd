extends RefCounted
class_name SmartObjectService

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const InteractionRequestScript := preload("res://scripts/npc_ai/contracts/InteractionRequest.gd")
const SmartObjectRegistrationScript := preload("res://scripts/npc_ai/interactions/SmartObjectRegistration.gd")

var owner: Node = null
var door_portals = null
var registrations := {}

func setup(owner_node: Node, door_portal_service) -> void:
	owner = owner_node
	door_portals = door_portal_service

func clear() -> void:
	registrations.clear()
	if door_portals != null:
		door_portals.clear()

func register_door(door: Node, metadata := {}) -> String:
	if door_portals == null:
		return ""
	var portal_id: String = door_portals.register_door(door, metadata)
	if portal_id != "":
		registrations[portal_id] = SmartObjectRegistrationScript.make(portal_id, "door", door, metadata)
	return portal_id

func request_interaction(request, actors: Array = []):
	if request == null:
		return load("res://scripts/npc_ai/contracts/InteractionResult.gd").make(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"missing_request")
	var command: StringName = request.get("command")
	if command in [
		NpcEnumsScript.DOOR_COMMAND_OPEN,
		NpcEnumsScript.DOOR_COMMAND_CLOSE,
		NpcEnumsScript.DOOR_COMMAND_HOLD,
		NpcEnumsScript.DOOR_COMMAND_RELEASE,
		NpcEnumsScript.DOOR_COMMAND_CANCEL,
		NpcEnumsScript.DOOR_COMMAND_LOCK,
		NpcEnumsScript.DOOR_COMMAND_UNLOCK,
		NpcEnumsScript.DOOR_COMMAND_DESTROY,
		NpcEnumsScript.DOOR_COMMAND_MARK_JAMMED,
		NpcEnumsScript.DOOR_COMMAND_REPAIR
	] and door_portals != null:
		return door_portals.request_interaction(request, actors)
	return load("res://scripts/npc_ai/contracts/InteractionResult.gd").make(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"unsupported")

func request_door_state(door: Node, desired_open: bool, actor: Node = null, actor_kind := "system", metadata := {}):
	if door_portals == null:
		return load("res://scripts/npc_ai/contracts/InteractionResult.gd").make(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"missing_door_service")
	return door_portals.request_door_state(door, desired_open, actor, actor_kind, metadata)

func request_door_toggle(door: Node, actor: Node = null, actor_kind := "player", metadata := {}):
	if door_portals == null:
		return load("res://scripts/npc_ai/contracts/InteractionResult.gd").make(NpcEnumsScript.INTERACTION_STATUS_FAILED, &"missing_door_service")
	return door_portals.request_door_toggle(door, actor, actor_kind, metadata)

func stats() -> Dictionary:
	return {
		"registrations": registrations.size(),
		"doorPortals": door_portals.stats() if door_portals != null else {}
	}
