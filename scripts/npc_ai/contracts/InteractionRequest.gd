extends RefCounted
class_name InteractionRequest

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

var request_id := ""
var object_id := ""
var object_node: Node = null
var actor_id := ""
var actor_node: Node = null
var actor_kind := ""
var command: StringName = &"none"
var desired_state: StringName = &""
var generation := 0
var metadata := {}

static func make(command_value: StringName, object_value := "", actor_value := "", metadata_value := {}):
	var request = load("res://scripts/npc_ai/contracts/InteractionRequest.gd").new()
	request.command = command_value
	request.object_id = String(object_value)
	request.actor_id = String(actor_value)
	request.metadata = metadata_value.duplicate(true) if metadata_value is Dictionary else {}
	request.request_id = "%s:%s:%s:%d" % [String(command_value), request.object_id, request.actor_id, request.generation]
	return request

func to_summary() -> Dictionary:
	return {
		"requestId": request_id,
		"objectId": object_id,
		"actorId": actor_id,
		"actorKind": actor_kind,
		"command": String(command),
		"desiredState": String(desired_state),
		"generation": generation,
		"metadata": metadata.duplicate(true)
	}
