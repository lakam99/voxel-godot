extends RefCounted
class_name RouteResult

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

var status: StringName = NpcEnumsScript.ROUTE_STATUS_PENDING
var reason: StringName = NpcEnumsScript.ROUTE_REASON_NONE
var owner_npc_id := ""
var request_id := ""
var generation := 0
var cost := 0.0
var metrics := {}
var topology_revision := 0
var dynamic_revision := 0
var corridor = null
var arrival_contract := ""
var repair_graph := {}
var repair_start_key := ""
var repair_goal_keys: Array = []
var repair_request = null

static func make(status_value: StringName, reason_value: StringName = NpcEnumsScript.ROUTE_REASON_NONE, generation_value := 0):
	var result = load("res://scripts/npc_ai/contracts/RouteResult.gd").new()
	result.status = status_value
	result.reason = reason_value
	result.generation = generation_value
	return result

func is_terminal() -> bool:
	return NpcEnumsScript.route_status_is_terminal(status)

func is_arrival() -> bool:
	return status == NpcEnumsScript.ROUTE_STATUS_COMPLETE

func satisfies_arrival_contract(expected_contract := "") -> bool:
	return is_arrival() and arrival_contract != "" and (expected_contract == "" or arrival_contract == expected_contract)

func to_summary() -> Dictionary:
	return {
		"status": String(status),
		"reason": String(reason),
		"ownerNpcId": owner_npc_id,
		"requestId": request_id,
		"generation": generation,
		"cost": cost,
		"topologyRevision": topology_revision,
		"dynamicRevision": dynamic_revision,
		"arrivalContract": arrival_contract
	}
