extends RefCounted
class_name NpcRecoveryPolicy

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NpcRouteStateStoreScript := preload("res://scripts/npc_ai/routing/NpcRouteStateStore.gd")

func mark_home_blocked(entry: Dictionary, reason: String) -> Dictionary:
	entry["insideHome"] = false
	entry["homeBlocked"] = true
	NpcRouteStateStoreScript.write_status(entry, "blocked", reason, "NpcRecoveryPolicy.mark_home_blocked")
	entry["unreachableGoals"] = int(entry.get("unreachableGoals", 0)) + 1
	var body := entry.get("body") as Node
	if body != null:
		body.set_meta("npc_inside_home", false)
		body.set_meta("npc_home_blocked", true)
	return {
		"terminal": true,
		"status": String(NpcEnumsScript.ROUTE_STATUS_UNREACHABLE),
		"reason": reason,
		"teleportUsed": false
	}

func mark_unreachable_goal(entry: Dictionary, reason: String) -> Dictionary:
	NpcRouteStateStoreScript.write_status(entry, "blocked", reason, "NpcRecoveryPolicy.mark_unreachable_goal")
	entry["unreachableGoals"] = int(entry.get("unreachableGoals", 0)) + 1
	return {
		"terminal": true,
		"status": String(NpcEnumsScript.ROUTE_STATUS_UNREACHABLE),
		"reason": reason,
		"teleportUsed": false
	}
