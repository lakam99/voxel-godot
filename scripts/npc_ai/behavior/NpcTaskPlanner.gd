extends RefCounted
class_name NpcTaskPlanner

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const ActionLibraryScript := preload("res://scripts/npc_ai/behavior/NpcActionLibrary.gd")

var action_library = ActionLibraryScript.new()
var max_actions := 8

func setup(library = null) -> void:
	if library != null:
		action_library = library

func plan(goal: Dictionary, context, entry: Dictionary, perception: Dictionary, schedule: Dictionary) -> Dictionary:
	var goal_kind: StringName = goal.get("goalKind", NpcEnumsScript.GOAL_KIND_IDLE)
	var actions: Array = action_library.sequence_for_goal(goal_kind, {
		"activeThreat": bool(perception.get("activeThreat", false)),
		"scheduleState": schedule.get("scheduleState", NpcEnumsScript.SCHEDULE_STATE_DAY)
	})
	if actions.size() > max_actions:
		actions = actions.slice(0, max_actions)
	var cost := 0.0
	var action_ids: Array[String] = []
	for action in actions:
		cost += float(action.get("baseCost", 0.0))
		action_ids.append(String(action.get("actionId", "")))
	return {
		"planner": "bounded_symbolic_phase09",
		"goalKind": goal_kind,
		"goalReason": String(goal.get("reason", "")),
		"actions": actions,
		"actionIds": action_ids,
		"status": "planned" if not actions.is_empty() else "failed",
		"failureReason": "" if not actions.is_empty() else "no_action_sequence",
		"cost": cost,
		"maxActions": max_actions,
		"bounded": true,
		"ownerNpcId": String(entry.get("id", context.get("stable_id") if context != null else ""))
	}
