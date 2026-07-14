extends RefCounted
class_name NpcTaskPlanner

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const ActionLibraryScript := preload("res://scripts/npc_ai/behavior/NpcActionLibrary.gd")

var action_library = ActionLibraryScript.new()
var max_actions := 8
var navigation_service = null

func setup(library = null, nav_service = null) -> void:
	if library != null:
		action_library = library
	navigation_service = nav_service

func plan(goal: Dictionary, context, entry: Dictionary, perception: Dictionary, schedule: Dictionary) -> Dictionary:
	var goal_kind: StringName = goal.get("goalKind", NpcEnumsScript.GOAL_KIND_IDLE)
	var library_context := {
		"activeThreat": bool(perception.get("activeThreat", false)),
		"scheduleState": String(schedule.get("scheduleState", NpcEnumsScript.SCHEDULE_STATE_DAY)),
		"scriptedOrderKind": String(perception.get("scriptedOrderKind", "")),
		"job": String(entry.get("job", "")),
		"role": String(entry.get("role", "")),
		"goalReason": String(goal.get("reason", ""))
	}
	var sequence_metadata: Dictionary = action_library.sequence_metadata_for_goal(goal_kind, library_context) if action_library.has_method("sequence_metadata_for_goal") else {}
	var actions: Array = action_library.sequence_for_goal(goal_kind, library_context)
	if actions.size() > max_actions:
		actions = actions.slice(0, max_actions)
	var cost := 0.0
	var action_ids: Array[String] = []
	for action in actions:
		cost += float(action.get("baseCost", 0.0))
		action_ids.append(String(action.get("actionId", "")))
	var semantic_target := validate_semantic_target(goal_kind, sequence_metadata, actions, entry, perception, schedule)
	var status := "planned" if not actions.is_empty() else "failed"
	var failure_reason := "" if not actions.is_empty() else "no_action_sequence"
	if status == "planned" and bool(semantic_target.get("required", false)) and not bool(semantic_target.get("reachable", false)):
		var validation_status := String(semantic_target.get("status", ""))
		if validation_status == "unreachable":
			status = "failed"
			failure_reason = "semantic_target_unreachable"
		elif validation_status == "missing":
			status = "failed"
			failure_reason = "semantic_target_missing"
	return {
		"planner": "resource_backed_phase04",
		"goalKind": goal_kind,
		"goalReason": String(goal.get("reason", "")),
		"sequenceId": String(sequence_metadata.get("sequenceId", "")),
		"targetKind": String(sequence_metadata.get("targetKind", "")),
		"actions": actions,
		"actionIds": action_ids,
		"status": status,
		"failureReason": failure_reason,
		"cost": cost,
		"maxActions": max_actions,
		"bounded": true,
		"semanticTarget": semantic_target,
		"ownerNpcId": String(entry.get("id", context.get("stable_id") if context != null else ""))
	}

func validate_semantic_target(goal_kind: StringName, sequence_metadata: Dictionary, actions: Array, entry: Dictionary, perception: Dictionary, schedule: Dictionary) -> Dictionary:
	var target_kind := String(sequence_metadata.get("targetKind", _target_kind_from_actions(actions)))
	var route_required := bool(sequence_metadata.get("routeRequired", _any_action_requires(actions, "routeRequired")))
	var reservation_required := bool(sequence_metadata.get("reservationRequired", _any_action_requires(actions, "reservationRequired")))
	var result := {
		"required": route_required or reservation_required or target_kind != "",
		"targetKind": target_kind,
		"routeRequired": route_required,
		"reservationRequired": reservation_required,
		"reachable": false,
		"status": "not_required",
		"reason": ""
	}
	if not bool(result.get("required", false)):
		result["reachable"] = true
		return result
	var target_position = _semantic_target_position(goal_kind, target_kind, entry, perception, schedule)
	if not (target_position is Vector3) or target_position == Vector3.INF:
		result["status"] = "pending" if _sequence_selects_target(actions) else "missing"
		result["reason"] = "target_selection_pending" if result["status"] == "pending" else "missing_semantic_target"
		return result
	result["position"] = target_position
	var reachability := _reachable_target(target_position, entry)
	result["reachable"] = bool(reachability.get("reachable", false))
	result["status"] = String(reachability.get("status", "reachable" if bool(result["reachable"]) else "unreachable"))
	result["reason"] = String(reachability.get("reason", ""))
	if reachability.has("walkablePosition"):
		result["walkablePosition"] = reachability["walkablePosition"]
	if reachability.has("walkableDistance"):
		result["walkableDistance"] = reachability["walkableDistance"]
	return result

func _target_kind_from_actions(actions: Array) -> String:
	for action in actions:
		if action is Dictionary:
			var kind := String((action as Dictionary).get("targetKind", ""))
			if kind != "":
				return kind
	return ""

func _any_action_requires(actions: Array, key: String) -> bool:
	for action in actions:
		if action is Dictionary and bool((action as Dictionary).get(key, false)):
			return true
	return false

func _sequence_selects_target(actions: Array) -> bool:
	for action in actions:
		if action is Dictionary and String((action as Dictionary).get("execution", "")) == "target_select":
			return true
	return false

func _semantic_target_position(goal_kind: StringName, target_kind: String, entry: Dictionary, perception: Dictionary, _schedule: Dictionary):
	var body := entry.get("body") as Node3D
	if target_kind == "scripted_target":
		if body != null and body.has_meta("npc_scripted_target"):
			return body.get_meta("npc_scripted_target")
		if entry.get("scriptedTarget", null) is Vector3:
			return entry.get("scriptedTarget")
		return Vector3.INF
	if target_kind == "scripted_action":
		if entry.get("scriptedActionPosition", null) is Vector3:
			return entry.get("scriptedActionPosition")
		if body != null and body.has_meta("npc_scripted_target"):
			return body.get_meta("npc_scripted_target")
		return Vector3.INF
	if target_kind in ["home_interior", "bed"]:
		return entry.get("homePosition", Vector3.INF)
	if target_kind == "guard_post":
		return entry.get("guardPosition", entry.get("porchPosition", Vector3.INF))
	if target_kind in ["forage_source", "resource_slot"]:
		if entry.get("jobTarget", null) is Vector3:
			return entry.get("jobTarget")
		var target_node := entry.get("jobTargetNode") as Node3D
		if target_node != null and is_instance_valid(target_node):
			return target_node.global_position
		return Vector3.INF
	if target_kind in ["work_slot", "trader_stall", "workstation"]:
		if entry.get("jobTarget", null) is Vector3:
			return entry.get("jobTarget")
		if entry.get("stallPosition", null) is Vector3:
			return entry.get("stallPosition")
		return entry.get("porchPosition", Vector3.INF)
	if target_kind == "threat_intercept":
		var threat = perception.get("threat")
		if threat is Node3D and is_instance_valid(threat):
			return (threat as Node3D).global_position
		if entry.get("guardTargetCache", null) is Vector3:
			return entry.get("guardTargetCache")
		return Vector3.INF
	if target_kind == "idle_anchor":
		return entry.get("dayTarget", entry.get("porchPosition", Vector3.INF))
	if String(goal_kind) == String(NpcEnumsScript.GOAL_KIND_HOME):
		return entry.get("homePosition", Vector3.INF)
	return entry.get("porchPosition", Vector3.INF)

func _reachable_target(target_position: Vector3, entry: Dictionary) -> Dictionary:
	if navigation_service != null and navigation_service.has_method("closest_walkable"):
		var closest: Dictionary = navigation_service.closest_walkable(target_position, 2.70)
		if bool(closest.get("found", false)):
			return {
				"reachable": true,
				"status": "reachable",
				"reason": "navmesh_walkable",
				"walkablePosition": closest.get("position", target_position),
				"walkableDistance": float(closest.get("distance", 0.0))
			}
		var generated_fallback := _generated_approach_reachability(target_position, entry)
		if bool(generated_fallback.get("reachable", false)):
			return generated_fallback
		return {
			"reachable": false,
			"status": "unreachable",
			"reason": String(closest.get("reason", "no_walkable_target"))
		}
	var generated_only := _generated_approach_reachability(target_position, entry)
	if bool(generated_only.get("reachable", false)):
		return generated_only
	return {
		"reachable": target_position != Vector3.INF,
		"status": "reachable" if target_position != Vector3.INF else "missing",
		"reason": "no_navigation_validator"
	}

func _generated_approach_reachability(target_position: Vector3, entry: Dictionary) -> Dictionary:
	if navigation_service == null or not navigation_service.has_method("approach_cells_for_target"):
		return {}
	var approach_cells: Array = navigation_service.approach_cells_for_target(entry, target_position, true)
	if approach_cells.is_empty():
		return {}
	var walkable_position := target_position
	if navigation_service.has_method("cell_position") and approach_cells[0] is Vector2i:
		walkable_position = navigation_service.cell_position(approach_cells[0])
	return {
		"reachable": true,
		"status": "reachable",
		"reason": "generated_approach_cell",
		"walkablePosition": walkable_position,
		"walkableDistance": Vector2(walkable_position.x - target_position.x, walkable_position.z - target_position.z).length()
	}
