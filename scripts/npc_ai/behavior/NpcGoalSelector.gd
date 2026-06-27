extends RefCounted
class_name NpcGoalSelector

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

const HYSTERESIS_MARGIN := 0.08

func select_goal(context, blackboard, entry: Dictionary, perception: Dictionary, schedule: Dictionary) -> Dictionary:
	var scores := {
		String(NpcEnumsScript.GOAL_KIND_IDLE): 0.20,
		String(NpcEnumsScript.GOAL_KIND_WORK): 0.0,
		String(NpcEnumsScript.GOAL_KIND_FORAGE): 0.0,
		String(NpcEnumsScript.GOAL_KIND_HOME): 0.0,
		String(NpcEnumsScript.GOAL_KIND_GUARD): 0.0,
		String(NpcEnumsScript.GOAL_KIND_SCRIPTED): 0.0
	}
	var reasons := {}
	var schedule_state := String(schedule.get("scheduleState", "day"))
	if bool(perception.get("scriptedOrder", false)):
		scores[String(NpcEnumsScript.GOAL_KIND_SCRIPTED)] = 2.00
		reasons[String(NpcEnumsScript.GOAL_KIND_SCRIPTED)] = "active_scripted_order"
	if bool(perception.get("activeThreat", false)) and bool(entry.get("canFight", false)):
		scores[String(NpcEnumsScript.GOAL_KIND_GUARD)] = maxf(float(scores[String(NpcEnumsScript.GOAL_KIND_GUARD)]), 1.80)
		reasons[String(NpcEnumsScript.GOAL_KIND_GUARD)] = "explicit_active_threat_exception"
	if bool(schedule.get("activeGuardDuty", false)):
		scores[String(NpcEnumsScript.GOAL_KIND_GUARD)] = maxf(float(scores[String(NpcEnumsScript.GOAL_KIND_GUARD)]), 1.60 if schedule_state == "dusk" else 1.70)
		reasons[String(NpcEnumsScript.GOAL_KIND_GUARD)] = "assigned_night_guard_duty"
	elif bool(schedule.get("mustBeInside", false)):
		scores[String(NpcEnumsScript.GOAL_KIND_HOME)] = 1.50 if schedule_state == "dusk" else 1.75
		reasons[String(NpcEnumsScript.GOAL_KIND_HOME)] = "schedule_requires_interior"
	if schedule_state in ["day", "dawn"]:
		var job := String(entry.get("job", ""))
		if job == "forage":
			scores[String(NpcEnumsScript.GOAL_KIND_FORAGE)] = 1.05
			reasons[String(NpcEnumsScript.GOAL_KIND_FORAGE)] = "role_forager_food_loop"
		elif job in ["wood", "stone"]:
			scores[String(NpcEnumsScript.GOAL_KIND_WORK)] = 1.00
			reasons[String(NpcEnumsScript.GOAL_KIND_WORK)] = "role_worker_job"
		elif job == "guard":
			scores[String(NpcEnumsScript.GOAL_KIND_GUARD)] = maxf(float(scores[String(NpcEnumsScript.GOAL_KIND_GUARD)]), 0.95)
			reasons[String(NpcEnumsScript.GOAL_KIND_GUARD)] = "day_guard_patrol"
	var candidate := _best_goal(scores)
	var chosen := _apply_hysteresis(candidate, scores, blackboard, perception, schedule)
	var reason := String(reasons.get(String(chosen), "highest_utility"))
	var goal := {
		"goalKind": chosen,
		"score": float(scores.get(String(chosen), 0.0)),
		"reason": reason,
		"utilityBreakdown": {
			"scores": scores.duplicate(true),
			"reasons": reasons.duplicate(true),
			"scheduleState": schedule_state,
			"previousGoal": String(blackboard.get("selected_goal_kind")) if blackboard != null else "",
			"hysteresisMargin": HYSTERESIS_MARGIN
		},
		"exceptionReason": reason if reason.find("exception") >= 0 else ""
	}
	if blackboard != null:
		blackboard.selected_goal_kind = chosen
		blackboard.utility_breakdown = goal["utilityBreakdown"]
	return goal

func _best_goal(scores: Dictionary) -> StringName:
	var best_key := ""
	var best_score := -INF
	var keys := scores.keys()
	keys.sort()
	for key in keys:
		var score := float(scores[key])
		if score > best_score:
			best_score = score
			best_key = String(key)
	return StringName(best_key)

func _apply_hysteresis(candidate: StringName, scores: Dictionary, blackboard, perception: Dictionary, schedule: Dictionary) -> StringName:
	if blackboard == null:
		return candidate
	if bool(perception.get("scriptedOrder", false)) or bool(perception.get("activeThreat", false)) or bool(schedule.get("mustBeInside", false)) or bool(schedule.get("activeGuardDuty", false)):
		return candidate
	var previous: StringName = blackboard.get("selected_goal_kind")
	if String(previous) == "" or previous == candidate:
		return candidate
	var previous_score := float(scores.get(String(previous), -INF))
	var candidate_score := float(scores.get(String(candidate), -INF))
	if previous_score + HYSTERESIS_MARGIN >= candidate_score:
		return previous
	return candidate
