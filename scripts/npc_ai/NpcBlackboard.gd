extends RefCounted
class_name NpcBlackboard

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

var selected_goal_kind: StringName = NpcEnumsScript.GOAL_KIND_IDLE
var utility_breakdown := {}
var current_plan = null
var current_action = null
var action_substate := ""
var route_generation := 0
var action_generation := 0
var current_route_result = null
var current_target = null
var arrival_contract := ""
var traffic_reservations: Array = []
var door_request_token := ""
var blocker_owner_id := ""
var wait_for_owner_id := ""
var progress_timestamp := 0.0
var distance_history: Array[float] = []
var recovery_count := 0
var recovery_reason: StringName = NpcEnumsScript.RECOVERY_REASON_NONE
var perception_snapshot := {}
var schedule_state: StringName = NpcEnumsScript.SCHEDULE_STATE_DAY
var terminal_status: StringName = &"none"

func next_route_generation() -> int:
	route_generation += 1
	return route_generation

func next_action_generation() -> int:
	action_generation += 1
	return action_generation

func accept_route_result(result) -> bool:
	if result == null or int(result.get("generation")) != route_generation:
		return false
	current_route_result = result
	terminal_status = result.get("status") if bool(result.call("is_terminal")) else &"none"
	return true

func remember_distance(distance: float, limit := 16) -> void:
	distance_history.append(distance)
	while distance_history.size() > limit:
		distance_history.pop_front()

func to_summary() -> Dictionary:
	return {
		"goalKind": String(selected_goal_kind),
		"routeGeneration": route_generation,
		"actionGeneration": action_generation,
		"arrivalContract": arrival_contract,
		"reservations": traffic_reservations.size(),
		"blocker": blocker_owner_id,
		"waitFor": wait_for_owner_id,
		"recoveryCount": recovery_count,
		"recoveryReason": String(recovery_reason),
		"scheduleState": String(schedule_state),
		"terminalStatus": String(terminal_status)
	}

