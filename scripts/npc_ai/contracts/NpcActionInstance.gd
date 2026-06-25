extends RefCounted
class_name NpcActionInstance

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

var action_id := ""
var owner_npc_id := ""
var status: StringName = NpcEnumsScript.ACTION_STATUS_PENDING
var failure_reason: StringName = &"none"
var action_generation := 0
var substate := ""
var metrics := {}

func is_terminal() -> bool:
	return NpcEnumsScript.action_status_is_terminal(status)

func next_generation() -> int:
	action_generation += 1
	status = NpcEnumsScript.ACTION_STATUS_PENDING
	failure_reason = &"none"
	return action_generation

func apply_terminal(generation: int, terminal_status: StringName, reason: StringName = &"none") -> bool:
	if generation != action_generation or is_terminal() or not NpcEnumsScript.action_status_is_terminal(terminal_status):
		return false
	status = terminal_status
	failure_reason = reason
	return true

func to_summary() -> Dictionary:
	return {
		"actionId": action_id,
		"ownerNpcId": owner_npc_id,
		"status": String(status),
		"reason": String(failure_reason),
		"generation": action_generation,
		"substate": substate
	}

