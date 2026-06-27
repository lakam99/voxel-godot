extends RefCounted
class_name NpcPlanExecutor

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")

var autonomy_system = null
var npc_system = null
var main = null
var schedule_service = null
var guard_roster = null
var perception_service = null
var goal_selector = null
var task_planner = null
var recovery_policy = null
var compliance_counters := {}

func setup(autonomy, system_node, main_node, services: Dictionary) -> void:
	autonomy_system = autonomy
	npc_system = system_node
	main = main_node
	schedule_service = services.get("schedule")
	guard_roster = services.get("guardRoster")
	perception_service = services.get("perception")
	goal_selector = services.get("goalSelector")
	task_planner = services.get("taskPlanner")
	recovery_policy = services.get("recovery")

func update_legacy_npc(entry: Dictionary, delta: float, night_factor: float) -> void:
	if npc_system == null:
		return
	var body := entry.get("body") as Node3D
	if body == null or not is_instance_valid(body):
		return
	if npc_system.has_method("update_npc_needs"):
		npc_system.call("update_npc_needs", entry, delta, night_factor)
	entry["cooldown"] = maxf(0.0, float(entry.get("cooldown", 0.0)) - delta)
	var context = entry.get("agentContext")
	var blackboard = entry.get("blackboard")
	var schedule: Dictionary = schedule_service.snapshot_for(context, entry, main, night_factor)
	var perception: Dictionary = perception_service.snapshot(entry, schedule)
	if npc_system.has_method("npc_is_held_by_intro_or_dialogue") and bool(npc_system.call("npc_is_held_by_intro_or_dialogue", entry, body)):
		_release_action_owned_state(entry, "script_hold")
		_publish_debug(entry, blackboard, { "goalKind": NpcEnumsScript.GOAL_KIND_IDLE, "reason": "held_by_script" }, {}, schedule, perception)
		return
	var goal: Dictionary = goal_selector.select_goal(context, blackboard, entry, perception, schedule)
	var previous_goal := String(entry.get("activeGoalKind", ""))
	var goal_kind := String(goal.get("goalKind", NpcEnumsScript.GOAL_KIND_IDLE))
	if previous_goal != "" and previous_goal != goal_kind:
		_release_action_owned_state(entry, "goal_changed_%s_to_%s" % [previous_goal, goal_kind])
	entry["activeGoalKind"] = goal_kind
	var plan: Dictionary = task_planner.plan(goal, context, entry, perception, schedule)
	if blackboard != null:
		blackboard.current_plan = plan
		blackboard.perception_snapshot = perception
		blackboard.schedule_state = schedule.get("scheduleState", NpcEnumsScript.SCHEDULE_STATE_DAY)
	_publish_debug(entry, blackboard, goal, plan, schedule, perception)
	_execute_plan(entry, body, goal, plan, perception, schedule, delta)
	if npc_system.has_method("face_hostile_if_needed"):
		npc_system.call("face_hostile_if_needed", body, perception.get("threat"))

func _execute_plan(entry: Dictionary, body: Node3D, goal: Dictionary, plan: Dictionary, perception: Dictionary, schedule: Dictionary, delta: float) -> void:
	var goal_kind: StringName = goal.get("goalKind", NpcEnumsScript.GOAL_KIND_IDLE)
	match goal_kind:
		NpcEnumsScript.GOAL_KIND_SCRIPTED:
			_execute_scripted(entry, body, delta)
		NpcEnumsScript.GOAL_KIND_HOME:
			_execute_home(entry, body, perception, delta)
		NpcEnumsScript.GOAL_KIND_GUARD:
			_execute_guard(entry, body, perception, schedule, delta)
		NpcEnumsScript.GOAL_KIND_WORK:
			_execute_job(entry, body, delta)
		NpcEnumsScript.GOAL_KIND_FORAGE:
			_execute_job(entry, body, delta)
		_:
			_execute_idle(entry, body, delta)

func _execute_scripted(entry: Dictionary, body: Node3D, delta: float) -> void:
	entry["routePriority"] = 180
	if body.has_meta("npc_scripted_target") and npc_system.has_method("update_scripted_npc"):
		npc_system.call("update_scripted_npc", entry, body, delta)
	else:
		_release_action_owned_state(entry, "scripted_order_cancelled")

func _execute_home(entry: Dictionary, body: Node3D, perception: Dictionary, delta: float) -> void:
	entry["homeReturnTime"] = float(entry.get("homeReturnTime", 0.0)) + delta
	entry["routePriority"] = 140
	var target: Vector3 = npc_system.call("home_route_target", entry) if npc_system.has_method("home_route_target") else entry.get("homePosition", body.global_position)
	entry["homeActiveTargetCell"] = _flat_cell_for_position(target)
	var speed := 6.4
	if bool(entry.get("holdIntroDoor", false)):
		speed = 14.0
	var moved := float(npc_system.call("move_npc", entry, target, speed * delta, true, false, delta)) if npc_system.has_method("move_npc") else 0.0
	entry["lastMoveDistance"] = moved
	if npc_system.has_method("settle_home_if_reached"):
		npc_system.call("settle_home_if_reached", entry)
	var now_perception: Dictionary = perception_service.snapshot(entry, { "scheduleState": NpcEnumsScript.SCHEDULE_STATE_NIGHT })
	var active_target_cell: Vector2i = entry.get("homeActiveTargetCell", entry.get("homeCell", Vector2i.ZERO))
	var home_cell: Vector2i = entry.get("homeCell", active_target_cell)
	if not bool(now_perception.get("insideHome", false)) and active_target_cell == home_cell and _home_route_terminal(entry):
		recovery_policy.mark_home_blocked(entry, _home_failure_reason(entry, now_perception))

func _execute_guard(entry: Dictionary, body: Node3D, perception: Dictionary, schedule: Dictionary, delta: float) -> void:
	entry["insideHome"] = false
	body.set_meta("npc_inside_home", false)
	entry["homeReturnTime"] = 0.0
	entry["homeRouteIndex"] = 0
	entry["routePriority"] = 130 if bool(schedule.get("activeGuardDuty", false)) else 170
	var weapon_id := String(entry.get("weaponId", ""))
	var target_hostile = perception.get("threat") if bool(perception.get("activeThreat", false)) else null
	var target: Vector3 = npc_system.call("update_fighter_target", entry, body, target_hostile, weapon_id) if npc_system.has_method("update_fighter_target") else entry.get("guardPosition", body.global_position)
	var moved := float(npc_system.call("move_npc", entry, target, 2.65 * delta, false, true, delta)) if npc_system.has_method("move_npc") else 0.0
	entry["lastMoveDistance"] = moved
	entry["guardDutyState"] = "intercept_threat" if target_hostile != null else "patrol"
	body.set_meta("npc_guard_duty_state", entry["guardDutyState"])

func _execute_job(entry: Dictionary, body: Node3D, delta: float) -> void:
	entry["homeReturnTime"] = 0.0
	entry["homeRouteIndex"] = 0
	entry["insideHome"] = false
	body.set_meta("npc_inside_home", false)
	entry["routePriority"] = 90
	var moving_job := bool(npc_system.call("update_day_job", entry, delta)) if npc_system.has_method("update_day_job") else false
	if moving_job:
		var target: Vector3 = entry.get("jobTarget", body.global_position)
		var moved := float(npc_system.call("move_npc", entry, target, 2.45 * delta, false, true, delta)) if npc_system.has_method("move_npc") else 0.0
		entry["lastMoveDistance"] = moved
		if moved <= 0.001:
			entry["routeForceReplan"] = true
	else:
		_execute_idle(entry, body, delta)

func _execute_idle(entry: Dictionary, body: Node3D, delta: float) -> void:
	entry["homeReturnTime"] = 0.0
	entry["homeRouteIndex"] = 0
	entry["insideHome"] = false
	body.set_meta("npc_inside_home", false)
	entry["routePriority"] = 35
	var timer := float(entry.get("idleAnchorTimer", 0.0)) - delta
	var target: Vector3 = entry.get("dayTarget", body.global_position)
	if timer <= 0.0 or body.global_position.distance_to(target) < NpcConstantsScript.CELL_SIZE * 0.65:
		target = _choose_semantic_idle_anchor(entry, body)
		timer = _deterministic_idle_seconds(entry)
	entry["idleAnchorTimer"] = timer
	entry["dayTarget"] = target
	entry["idleAnchorKind"] = "semantic"
	var moved := float(npc_system.call("move_npc", entry, target, 2.25 * delta, false, false, delta)) if npc_system.has_method("move_npc") else 0.0
	entry["lastMoveDistance"] = moved

func _choose_semantic_idle_anchor(entry: Dictionary, body: Node3D) -> Vector3:
	if npc_system != null and npc_system.has_method("choose_day_target"):
		return npc_system.call("choose_day_target", entry)
	return entry.get("porchPosition", body.global_position)

func _publish_debug(entry: Dictionary, blackboard, goal: Dictionary, plan: Dictionary, schedule: Dictionary, perception: Dictionary) -> void:
	var body := entry.get("body") as Node
	var compliance: Dictionary = perception_service.compliance(entry, perception, schedule)
	_record_compliance(compliance)
	entry["goal"] = String(goal.get("goalKind", NpcEnumsScript.GOAL_KIND_IDLE))
	entry["goalReason"] = String(goal.get("reason", ""))
	entry["utilityBreakdown"] = goal.get("utilityBreakdown", {})
	entry["currentPlan"] = plan
	entry["scheduleState"] = String(schedule.get("scheduleState", "day"))
	entry["scheduleCompliance"] = compliance
	if blackboard != null:
		blackboard.utility_breakdown = entry["utilityBreakdown"]
		blackboard.current_plan = plan
	if body != null:
		body.set_meta("npc_goal", entry["goal"])
		body.set_meta("npc_goal_reason", entry["goalReason"])
		body.set_meta("npc_utility_breakdown", entry["utilityBreakdown"])
		body.set_meta("npc_plan_actions", plan.get("actionIds", []))
		body.set_meta("npc_schedule_state", entry["scheduleState"])
		body.set_meta("npc_schedule_compliance", compliance)
		body.set_meta("npc_inside_home", bool(perception.get("insideHome", false)))

func _release_action_owned_state(entry: Dictionary, reason: String) -> void:
	var body := entry.get("body") as Node
	if autonomy_system != null:
		if autonomy_system.has_method("release_npc_traffic_reservations"):
			autonomy_system.call("release_npc_traffic_reservations", entry, reason)
		if autonomy_system.has_method("release_npc_door_hold"):
			autonomy_system.call("release_npc_door_hold", body if body != null else String(entry.get("id", "")), true)
	if npc_system != null and npc_system.has_method("release_job_reservation"):
		npc_system.call("release_job_reservation", entry, reason)
	entry["activeDoorTrafficGroupId"] = ""
	entry["activeTrafficStepGroup"] = ""
	var blackboard = entry.get("blackboard")
	if blackboard != null:
		blackboard.traffic_reservations.clear()
		blackboard.door_request_token = ""

func _record_compliance(compliance: Dictionary) -> void:
	var reason := String(compliance.get("reason", "unknown"))
	compliance_counters[reason] = int(compliance_counters.get(reason, 0)) + 1

func _home_route_terminal(entry: Dictionary) -> bool:
	return String(entry.get("routeStatus", "")) in ["arrived", "partial", "blocked", "unreachable"]

func _home_failure_reason(entry: Dictionary, perception: Dictionary) -> String:
	if bool(perception.get("onThreshold", false)):
		return "threshold_not_inside"
	if bool(perception.get("onPorch", false)):
		return "porch_not_inside"
	var reason := String(entry.get("routeReason", ""))
	return reason if reason != "" else "home_unreachable"

func _flat_cell_for_position(position: Vector3) -> Vector2i:
	return Vector2i(roundi(position.x / NpcConstantsScript.CELL_SIZE), roundi(position.z / NpcConstantsScript.CELL_SIZE))

func _deterministic_idle_seconds(entry: Dictionary) -> float:
	var key := "%s:%s:%d" % [String(entry.get("id", "npc")), String(entry.get("role", "")), int(entry.get("jobRuns", 0))]
	return 4.0 + float(abs(hash(key)) % 180) / 60.0

func stats() -> Dictionary:
	return {
		"complianceCounters": compliance_counters.duplicate(true)
	}
