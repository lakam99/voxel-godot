extends RefCounted
class_name InteractionResult

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

var status: StringName = NpcEnumsScript.INTERACTION_STATUS_PENDING
var reason: StringName = &"none"
var interaction_id := ""
var owner_npc_id := ""
var generation := 0
var metrics := {}

static func make(status_value: StringName, reason_value: StringName = &"none", generation_value := 0):
	var result = load("res://scripts/npc_ai/contracts/InteractionResult.gd").new()
	result.status = status_value
	result.reason = reason_value
	result.generation = generation_value
	return result

func is_terminal() -> bool:
	return NpcEnumsScript.interaction_status_is_terminal(status)

func to_summary() -> Dictionary:
	return {
		"interactionId": interaction_id,
		"ownerNpcId": owner_npc_id,
		"status": String(status),
		"reason": String(reason),
		"generation": generation,
		"metrics": metrics.duplicate(true)
	}
