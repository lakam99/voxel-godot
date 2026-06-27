extends RefCounted
class_name NpcActionLibrary

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

var definitions := {}

func _init() -> void:
	_register_defaults()

func definition(action_id: String) -> Dictionary:
	return definitions.get(action_id, {}).duplicate(true)

func sequence_for_goal(goal_kind: StringName, context := {}) -> Array:
	match goal_kind:
		NpcEnumsScript.GOAL_KIND_SCRIPTED:
			return [_action("scripted_order")]
		NpcEnumsScript.GOAL_KIND_HOME:
			return [_action("navigate_home_approach"), _action("open_cross_home_door"), _action("navigate_home_interior"), _action("remain_inside")]
		NpcEnumsScript.GOAL_KIND_GUARD:
			if bool(context.get("activeThreat", false)):
				return [_action("choose_intercept"), _action("navigate_guard_intercept"), _action("engage_threat"), _action("resume_guard_duty")]
			return [_action("report_to_guard_post"), _action("patrol_guard_post")]
		NpcEnumsScript.GOAL_KIND_FORAGE:
			return [_action("select_forage_target"), _action("navigate_to_resource"), _action("harvest_resource"), _action("eat_if_hungry")]
		NpcEnumsScript.GOAL_KIND_WORK:
			return [_action("choose_work_target"), _action("navigate_to_work"), _action("perform_work"), _action("return_or_deliver")]
	return [_action("relocate_semantic_anchor"), _action("remain_idle")]

func _register_defaults() -> void:
	_add("scripted_order", ["scripted_target_present"], ["scripted_target_reached_or_cancelled"], 0.1, false, 60.0, "scripted_move")
	_add("navigate_home_approach", ["assigned_home", "route_available_or_pending"], ["at_home_approach"], 1.0, true, 45.0, "route")
	_add("open_cross_home_door", ["at_home_approach", "door_openable"], ["inside_portal_side", "door_hold_released"], 1.5, false, 12.0, "door_traversal")
	_add("navigate_home_interior", ["inside_portal_side", "interior_anchor_known"], ["inside_home_interior"], 0.7, true, 20.0, "route")
	_add("remain_inside", ["inside_home_interior"], ["schedule_compliant_inside"], 0.1, true, 0.0, "idle")
	_add("report_to_guard_post", ["assigned_guard_duty", "guard_post_known"], ["at_guard_post"], 0.9, true, 35.0, "route")
	_add("patrol_guard_post", ["at_guard_post"], ["guard_duty_active"], 0.4, true, 0.0, "patrol")
	_add("choose_intercept", ["active_threat", "can_fight"], ["reachable_intercept_selected"], 0.3, true, 3.0, "target_select")
	_add("navigate_guard_intercept", ["reachable_intercept_selected"], ["in_threat_range"], 0.9, true, 20.0, "route")
	_add("engage_threat", ["in_threat_range", "weapon_available"], ["threat_handled_or_reassess"], 0.7, false, 8.0, "combat")
	_add("resume_guard_duty", ["guard_duty_or_schedule_known"], ["post_threat_schedule_restored"], 0.2, true, 4.0, "restore")
	_add("select_forage_target", ["forager_role", "hunger_or_role_need"], ["forage_target_selected"], 0.2, true, 4.0, "target_select")
	_add("navigate_to_resource", ["resource_target_selected"], ["at_resource_approach"], 1.0, true, 35.0, "route")
	_add("harvest_resource", ["at_resource_approach", "resource_available"], ["resource_in_inventory"], 0.6, false, 8.0, "smart_object")
	_add("eat_if_hungry", ["food_in_inventory_or_not_hungry"], ["hunger_improved"], 0.1, true, 2.0, "needs")
	_add("choose_work_target", ["worker_role"], ["work_target_selected"], 0.2, true, 4.0, "target_select")
	_add("navigate_to_work", ["work_target_selected"], ["at_work_target"], 1.0, true, 35.0, "route")
	_add("perform_work", ["at_work_target"], ["job_effect_applied"], 0.8, false, 12.0, "job")
	_add("return_or_deliver", ["job_effect_applied"], ["job_loop_continues"], 0.5, true, 20.0, "route")
	_add("relocate_semantic_anchor", ["semantic_anchor_available"], ["at_idle_anchor"], 0.4, true, 16.0, "route")
	_add("remain_idle", ["at_idle_anchor_or_no_anchor"], ["idle_stable"], 0.1, true, 0.0, "idle")

func _add(action_id: String, preconditions: Array, effects: Array, base_cost: float, interruptible: bool, timeout_seconds: float, execution: String) -> void:
	definitions[action_id] = {
		"actionId": action_id,
		"preconditions": preconditions.duplicate(),
		"effects": effects.duplicate(),
		"baseCost": base_cost,
		"contextCost": {},
		"interruptible": interruptible,
		"timeoutSeconds": timeout_seconds,
		"execution": execution,
		"failureReasons": ["precondition_failed", "timeout", "target_invalidated", "route_terminal_failure"]
	}

func _action(action_id: String) -> Dictionary:
	return definition(action_id)
