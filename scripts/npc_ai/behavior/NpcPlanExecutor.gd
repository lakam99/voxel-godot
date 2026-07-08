extends RefCounted
class_name NpcPlanExecutor

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const HomeInteriorServiceScript := preload("res://scripts/npc_ai/behavior/HomeInteriorService.gd")

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
var job_selection_frame := -1
var job_selections_this_frame := 0
var guard_target_frame := -1
var guard_target_refreshes_this_frame := 0
var update_frame_serial := 0

const JOB_SELECTIONS_PER_FRAME := 1
const GUARD_TARGET_REFRESHES_PER_FRAME := 1

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

func performance_monitor():
	return main.get("runtime_perf_monitor") if main != null else null

func begin_update_frame() -> void:
	update_frame_serial += 1

func update_npc(entry: Dictionary, delta: float, night_factor: float) -> void:
	if npc_system == null:
		return
	var body := entry.get("body") as Node3D
	if body == null or not is_instance_valid(body):
		return
	var monitor = performance_monitor()
	if npc_system.has_method("update_npc_needs"):
		var needs_start: int = monitor.begin_section("npc_needs") if monitor != null else Time.get_ticks_usec()
		npc_system.call("update_npc_needs", entry, delta, night_factor)
		if monitor != null:
			monitor.end_section("npc_needs", needs_start)
	entry["cooldown"] = maxf(0.0, float(entry.get("cooldown", 0.0)) - delta)
	var context = entry.get("agentContext")
	var blackboard = entry.get("blackboard")
	var schedule_start: int = monitor.begin_section("npc_schedule") if monitor != null else Time.get_ticks_usec()
	var schedule: Dictionary = schedule_service.snapshot_for(context, entry, main, night_factor)
	if monitor != null:
		monitor.end_section("npc_schedule", schedule_start)
	var perception_start: int = monitor.begin_section("npc_perception") if monitor != null else Time.get_ticks_usec()
	var perception: Dictionary = perception_service.snapshot(entry, schedule)
	if monitor != null:
		monitor.end_section("npc_perception", perception_start)
	if npc_system.has_method("npc_is_held_by_intro_or_dialogue") and bool(npc_system.call("npc_is_held_by_intro_or_dialogue", entry, body)):
		_release_action_owned_state(entry, "script_hold")
		var held_goal := { "goalKind": NpcEnumsScript.GOAL_KIND_IDLE, "reason": "held_by_script" }
		_publish_debug(entry, blackboard, held_goal, {}, schedule, perception)
		_cache_motion_intent(entry, held_goal, {}, schedule, perception)
		return
	var goal_start: int = monitor.begin_section("npc_goal_select") if monitor != null else Time.get_ticks_usec()
	var goal: Dictionary = goal_selector.select_goal(context, blackboard, entry, perception, schedule)
	if monitor != null:
		monitor.end_section("npc_goal_select", goal_start)
	var previous_goal := String(entry.get("activeGoalKind", ""))
	var goal_kind := String(goal.get("goalKind", NpcEnumsScript.GOAL_KIND_IDLE))
	if previous_goal != "" and previous_goal != goal_kind:
		_release_action_owned_state(entry, "goal_changed_%s_to_%s" % [previous_goal, goal_kind])
	entry["activeGoalKind"] = goal_kind
	var plan_start: int = monitor.begin_section("npc_task_plan") if monitor != null else Time.get_ticks_usec()
	var plan: Dictionary = task_planner.plan(goal, context, entry, perception, schedule)
	if monitor != null:
		monitor.end_section("npc_task_plan", plan_start)
	if blackboard != null:
		blackboard.current_plan = plan
		blackboard.perception_snapshot = perception
		blackboard.schedule_state = schedule.get("scheduleState", NpcEnumsScript.SCHEDULE_STATE_DAY)
	var debug_start: int = monitor.begin_section("npc_debug_publish") if monitor != null else Time.get_ticks_usec()
	_publish_debug(entry, blackboard, goal, plan, schedule, perception)
	if monitor != null:
		monitor.end_section("npc_debug_publish", debug_start)
	_cache_motion_intent(entry, goal, plan, schedule, perception)

func advance_motion_npc(entry: Dictionary, delta: float, _night_factor := 0.0) -> Dictionary:
	if npc_system == null:
		return { "advanced": false, "reason": "missing_npc_system" }
	var body := entry.get("body") as Node3D
	if body == null or not is_instance_valid(body):
		return { "advanced": false, "reason": "missing_body" }
	if npc_system.has_method("npc_is_held_by_intro_or_dialogue") and bool(npc_system.call("npc_is_held_by_intro_or_dialogue", entry, body)):
		_release_action_owned_state(entry, "script_hold")
		return { "advanced": false, "reason": "held_by_script" }
	var goal: Dictionary = _cached_goal_for_motion(entry, body, _night_factor)
	var goal_kind: StringName = goal.get("goalKind", NpcEnumsScript.GOAL_KIND_IDLE)
	var schedule: Dictionary = entry.get("activeMotionSchedule", {}) if entry.get("activeMotionSchedule", {}) is Dictionary else {}
	var perception: Dictionary = entry.get("activeMotionPerception", {}) if entry.get("activeMotionPerception", {}) is Dictionary else {}
	var monitor = performance_monitor()
	var execute_start: int = monitor.begin_section("npc_execute_motion") if monitor != null else Time.get_ticks_usec()
	var result: Dictionary = {}
	match goal_kind:
		NpcEnumsScript.GOAL_KIND_SCRIPTED:
			result = _advance_scripted_motion(entry, body, perception, delta)
		NpcEnumsScript.GOAL_KIND_HOME:
			result = _advance_home_motion(entry, body, delta)
		NpcEnumsScript.GOAL_KIND_GUARD:
			result = _advance_guard_motion(entry, body, perception, schedule, delta)
		NpcEnumsScript.GOAL_KIND_WORK, NpcEnumsScript.GOAL_KIND_FORAGE:
			result = _advance_job_motion(entry, body, delta)
		NpcEnumsScript.GOAL_KIND_IDLE:
			result = _advance_idle_motion(entry, body, delta)
		_:
			result = { "advanced": false, "reason": "no_motion_intent", "intentKind": "idle" }
	if monitor != null:
		monitor.end_section("npc_execute_motion", execute_start)
	if npc_system.has_method("face_hostile_if_needed"):
		var threat = perception.get("threat") if perception is Dictionary else null
		var face_start: int = monitor.begin_section("npc_face_hostile") if monitor != null else Time.get_ticks_usec()
		npc_system.call("face_hostile_if_needed", body, threat)
		if monitor != null:
			monitor.end_section("npc_face_hostile", face_start)
	return result

func _cache_motion_intent(entry: Dictionary, goal: Dictionary, plan: Dictionary, schedule: Dictionary, perception: Dictionary) -> void:
	entry["activeMotionGoal"] = goal.duplicate(false)
	entry["activeMotionPlan"] = plan.duplicate(false)
	entry["activeMotionSchedule"] = schedule.duplicate(false)
	entry["activeMotionPerception"] = perception.duplicate(false)

func _cached_goal_for_motion(entry: Dictionary, body: Node3D, current_night_factor := 0.0) -> Dictionary:
	var order_kind := _scripted_order_kind(body, entry)
	var active_scripted_order := order_kind != "" or body.has_meta("npc_scripted_target")
	var active_job_motion_goal := _active_job_motion_goal(entry, current_night_factor)
	if order_kind == "go_home":
		return { "goalKind": NpcEnumsScript.GOAL_KIND_HOME, "reason": "scripted_go_home_order" }
	if order_kind in ["go_to", "wait", "face_player"]:
		return { "goalKind": NpcEnumsScript.GOAL_KIND_SCRIPTED, "reason": "scripted_%s_order" % order_kind }
	if body.has_meta("npc_scripted_target"):
		return { "goalKind": NpcEnumsScript.GOAL_KIND_SCRIPTED, "reason": "scripted_target" }
	var cached = entry.get("activeMotionGoal", {})
	var stale_scripted_cache := false
	if cached is Dictionary and not (cached as Dictionary).is_empty():
		var cached_kind := String((cached as Dictionary).get("goalKind", ""))
		var cached_schedule: Dictionary = entry.get("activeMotionSchedule", {}) if entry.get("activeMotionSchedule", {}) is Dictionary else {}
		var cached_reason := String((cached as Dictionary).get("reason", ""))
		var cached_from_script := cached_kind == String(NpcEnumsScript.GOAL_KIND_SCRIPTED) or cached_reason == "active_scripted_order" or cached_reason.begins_with("scripted_")
		if cached_from_script and not active_scripted_order:
			stale_scripted_cache = true
			cached = {}
		else:
			var current_home_time := current_night_factor > 0.05
			var cached_schedule_state := String(cached_schedule.get("scheduleState", ""))
			var cached_requires_home := bool(cached_schedule.get("mustBeInside", false)) \
				or cached_schedule_state in [String(NpcEnumsScript.SCHEDULE_STATE_DUSK), String(NpcEnumsScript.SCHEDULE_STATE_NIGHT)] \
				or current_home_time
			if cached_kind == String(NpcEnumsScript.GOAL_KIND_SCRIPTED):
				return cached
			if cached_kind == String(NpcEnumsScript.GOAL_KIND_HOME) and cached_requires_home and active_job_motion_goal.is_empty():
				return cached
			if cached_kind == String(NpcEnumsScript.GOAL_KIND_GUARD) and (bool(cached_schedule.get("activeGuardDuty", false)) or cached_reason.find("threat") >= 0):
				return cached
	if current_night_factor > 0.05 and not bool(entry.get("nightGuard", false)):
		return { "goalKind": NpcEnumsScript.GOAL_KIND_HOME, "reason": "schedule_preempts_job_for_home" }
	if not active_job_motion_goal.is_empty():
		return active_job_motion_goal
	if cached is Dictionary and not (cached as Dictionary).is_empty():
		return cached
	if stale_scripted_cache:
		return { "goalKind": NpcEnumsScript.GOAL_KIND_IDLE, "reason": "completed_scripted_order" }
	var goal_kind := String(entry.get("activeGoalKind", entry.get("goal", String(NpcEnumsScript.GOAL_KIND_IDLE))))
	return { "goalKind": StringName(goal_kind), "reason": "cached_entry_goal" }

func _active_job_motion_goal(entry: Dictionary, current_night_factor: float) -> Dictionary:
	if current_night_factor > 0.05:
		return {}
	var active_job_phase := String(entry.get("jobPhase", "idle"))
	if active_job_phase in ["outbound", "searching", "gathering", "returning", "stall"]:
		var active_job := String(entry.get("job", ""))
		if active_job == "forage":
			return { "goalKind": NpcEnumsScript.GOAL_KIND_FORAGE, "reason": "active_job_phase" }
		if active_job in ["wood", "stone", "trade"]:
			return { "goalKind": NpcEnumsScript.GOAL_KIND_WORK, "reason": "active_job_phase" }
	return {}

func _advance_scripted_motion(entry: Dictionary, body: Node3D, perception: Dictionary, delta: float) -> Dictionary:
	var order_kind := _scripted_order_kind(body, entry)
	if order_kind == "" and not body.has_meta("npc_scripted_target"):
		_release_action_owned_state(entry, "scripted_order_cancelled")
		return { "advanced": false, "reason": "scripted_order_cancelled", "intentKind": "scripted" }
	_execute_scripted(entry, body, perception, delta)
	return _motion_result(entry, "scripted", "scripted_order")

func _advance_home_motion(entry: Dictionary, body: Node3D, delta: float) -> Dictionary:
	_preempt_job_for_home(entry)
	_invalidate_stale_home_arrival(entry, body)
	_execute_home(entry, body, entry.get("activeMotionPerception", {}) if entry.get("activeMotionPerception", {}) is Dictionary else {}, delta)
	return _motion_result(entry, "home", "home_route")

func _advance_guard_motion(entry: Dictionary, body: Node3D, perception: Dictionary, schedule: Dictionary, delta: float) -> Dictionary:
	entry["insideHome"] = false
	body.set_meta("npc_inside_home", false)
	entry["homeReturnTime"] = 0.0
	entry["homeRouteIndex"] = 0
	entry["routePriority"] = 130 if bool(schedule.get("activeGuardDuty", false)) else 170
	var weapon_id := String(entry.get("weaponId", ""))
	var target_hostile = perception.get("threat") if bool(perception.get("activeThreat", false)) else null
	var hostile_key := ""
	if target_hostile != null and is_instance_valid(target_hostile):
		hostile_key = str(target_hostile.get_instance_id())
	var target: Vector3 = entry.get("guardTargetCache", entry.get("guardPosition", body.global_position))
	var refresh_timer := float(entry.get("guardTargetRefreshTimer", 0.0)) - delta
	var refresh_required := refresh_timer <= 0.0 or hostile_key != String(entry.get("guardTargetHostileKey", ""))
	var monitor = performance_monitor()
	var target_start: int = monitor.begin_section("npc_guard_target") if monitor != null else Time.get_ticks_usec()
	if refresh_required and _guard_target_refresh_budget_available(entry):
		target = npc_system.call("update_fighter_target", entry, body, target_hostile, weapon_id) if npc_system.has_method("update_fighter_target") else entry.get("guardPosition", body.global_position)
		refresh_timer = _deterministic_seconds(entry, "guard_threat_refresh", 0.25, 0.45) if target_hostile != null else _deterministic_seconds(entry, "guard_post_refresh", 2.0, 3.2)
		entry["guardTargetCache"] = target
		entry["guardTargetHostileKey"] = hostile_key
	elif refresh_required:
		refresh_timer = minf(float(entry.get("guardTargetRefreshTimer", 0.0)), 0.05)
	entry["guardTargetRefreshTimer"] = refresh_timer
	if monitor != null:
		monitor.end_section("npc_guard_target", target_start)
	target = _staged_departure_motion_target(entry, body, target)
	var move_start: int = performance_monitor().begin_section("npc_guard_move") if performance_monitor() != null else Time.get_ticks_usec()
	entry["routeIntentKind"] = "guard"
	entry["guardRouteCritical"] = target_hostile != null
	var speed := _set_motion_speed_mode(entry, "walking", "guard_route")
	var moved := float(npc_system.call("move_npc", entry, target, speed * delta, false, true, delta)) if npc_system.has_method("move_npc") else 0.0
	entry.erase("routeIntentKind")
	entry.erase("guardRouteCritical")
	if performance_monitor() != null:
		performance_monitor().end_section("npc_guard_move", move_start)
	entry["lastMoveDistance"] = moved
	entry["guardDutyState"] = "intercept_threat" if target_hostile != null else "patrol"
	body.set_meta("npc_guard_duty_state", entry["guardDutyState"])
	return _motion_result(entry, "guard", "guard_route")

func _advance_job_motion(entry: Dictionary, body: Node3D, delta: float) -> Dictionary:
	_clear_inside_home_if_not_semantic(entry, body)
	if _worker_needs_town_recovery(entry, body):
		return _advance_worker_town_recovery(entry, body, delta)
	var phase_before := String(entry.get("jobPhase", "idle"))
	var route_only_outbound := phase_before == "outbound" and entry.get("jobTarget", null) is Vector3 and String(entry.get("jobObjectId", "")) == "" and _job_target_node(entry) == null
	if not route_only_outbound:
		var monitor = performance_monitor()
		var state_start: int = monitor.begin_section("npc_update_day_job") if monitor != null else Time.get_ticks_usec()
		if _job_selection_budget_available(entry, delta):
			_update_day_job(entry, delta)
		else:
			entry["jobTimer"] = minf(float(entry.get("jobTimer", 0.0)), 0.05)
			if _inside_home_now(entry, body) or _inside_home_bounds_now(entry, body.global_position):
				if monitor != null:
					monitor.end_section("npc_update_day_job", state_start)
				return _advance_job_home_exit(entry, body, delta, "job_selection_deferred_home_exit")
		if monitor != null:
			monitor.end_section("npc_update_day_job", state_start)
	var phase := String(entry.get("jobPhase", "idle"))
	if not (phase in ["outbound", "searching", "returning"]):
		if _inside_home_now(entry, body) or _inside_home_bounds_now(entry, body.global_position):
			return _advance_job_home_exit(entry, body, delta, "job_idle_home_exit")
		entry["lastMoveDistance"] = 0.0
		return { "advanced": false, "reason": "job_phase_not_moving", "intentKind": "job" }
	var target: Vector3 = entry.get("jobTarget", body.global_position)
	target = _staged_departure_motion_target(entry, body, target)
	entry["routePriority"] = 90
	var job_intent_kind := "forage" if String(entry.get("job", "")) == "forage" else "work"
	entry["routeIntentKind"] = job_intent_kind
	var speed := _set_motion_speed_mode(entry, "walking", "%s_route" % job_intent_kind)
	var moved := float(npc_system.call("move_npc", entry, target, speed * delta, false, _job_route_allows_outside(entry, body), delta)) if npc_system.has_method("move_npc") else 0.0
	entry.erase("routeIntentKind")
	entry["lastMoveDistance"] = moved
	var route_status := String(entry.get("routeStatus", ""))
	if moved <= 0.001 and route_status != "pending":
		entry["routeForceReplan"] = true
	_clear_inside_home_if_not_semantic(entry, body)
	return _motion_result(entry, "job", "job_route")

func _advance_job_home_exit(entry: Dictionary, body: Node3D, delta: float, reason: String) -> Dictionary:
	var target := _home_exit_clearance_target(entry, body.global_position.y)
	entry["routePriority"] = maxi(int(entry.get("routePriority", 0)), 95)
	entry["routeIntentKind"] = "forage" if String(entry.get("job", "")) == "forage" else "work"
	var speed := _set_motion_speed_mode(entry, "walking", "job_home_exit")
	var moved := float(npc_system.call("move_npc", entry, target, speed * delta, false, _job_route_allows_outside(entry, body), delta)) if npc_system.has_method("move_npc") else 0.0
	entry.erase("routeIntentKind")
	entry["lastMoveDistance"] = moved
	if moved <= 0.001 and String(entry.get("routeStatus", "")) != "pending":
		entry["routeForceReplan"] = true
	_clear_inside_home_if_not_semantic(entry, body)
	return _motion_result(entry, "job", reason)

func _advance_idle_motion(entry: Dictionary, body: Node3D, delta: float) -> Dictionary:
	if not entry.has("dayTarget"):
		return { "advanced": false, "reason": "idle_no_anchor", "intentKind": "idle" }
	entry["routePriority"] = 35
	var target: Vector3 = entry.get("dayTarget", body.global_position)
	entry["routeIntentKind"] = "idle"
	var speed := _set_motion_speed_mode(entry, "walking", "idle_anchor")
	var moved := float(npc_system.call("move_npc", entry, target, speed * delta, false, false, delta)) if npc_system.has_method("move_npc") else 0.0
	entry.erase("routeIntentKind")
	entry["lastMoveDistance"] = moved
	return _motion_result(entry, "idle", "idle_anchor")

func _motion_result(entry: Dictionary, intent_kind: String, reason: String) -> Dictionary:
	return {
		"advanced": true,
		"reason": reason,
		"intentKind": intent_kind,
		"moved": float(entry.get("lastMoveDistance", 0.0)),
		"routeStatus": String(entry.get("routeStatus", "")),
		"classification": "door_state" if String(entry.get("activeDoorPortalId", "")) != "" else ""
	}

func _scripted_order_kind(body: Node, entry := {}) -> String:
	if body == null or not is_instance_valid(body):
		return _entry_scripted_order_kind(entry)
	var state := String(body.get_meta("npc_scripted_order_state", ""))
	if state in ["PENDING", "ACTIVE"]:
		return String(body.get_meta("npc_scripted_order_kind", ""))
	if state == "ARRIVED" and bool(body.get_meta("npc_scripted_hold_on_arrival", false)) and String(body.get_meta("npc_scripted_order_kind", "")) == "go_home":
		return "go_home"
	return _entry_scripted_order_kind(entry)

func _entry_scripted_order_kind(entry) -> String:
	if not (entry is Dictionary):
		return ""
	var order_value = (entry as Dictionary).get("scriptedOrder", {})
	if not (order_value is Dictionary):
		return ""
	var order: Dictionary = order_value
	var state := String(order.get("state", ""))
	if state in ["PENDING", "ACTIVE"]:
		return String(order.get("kind", ""))
	if state == "ARRIVED" and bool(order.get("holdOnArrival", false)) and String(order.get("kind", "")) == "go_home":
		return "go_home"
	return ""

func _mark_scripted_order(entry: Dictionary, state: String, reason: String) -> void:
	if npc_system != null and npc_system.has_method("scripted_order_result"):
		npc_system.call("scripted_order_result", entry, state, reason, "")
		return
	entry["scriptedOrder"] = {
		"state": state,
		"reason": reason
	}
	var body := entry.get("body") as Node
	if body != null and is_instance_valid(body):
		body.set_meta("npc_scripted_order_state", state)
		body.set_meta("npc_scripted_order_reason", reason)

func _execute_plan(entry: Dictionary, body: Node3D, goal: Dictionary, plan: Dictionary, perception: Dictionary, schedule: Dictionary, delta: float) -> void:
	var goal_kind: StringName = goal.get("goalKind", NpcEnumsScript.GOAL_KIND_IDLE)
	var monitor = performance_monitor()
	match goal_kind:
		NpcEnumsScript.GOAL_KIND_SCRIPTED:
			var scripted_start: int = monitor.begin_section("npc_execute_scripted") if monitor != null else Time.get_ticks_usec()
			_execute_scripted(entry, body, perception, delta)
			if monitor != null:
				monitor.end_section("npc_execute_scripted", scripted_start)
		NpcEnumsScript.GOAL_KIND_HOME:
			var home_start: int = monitor.begin_section("npc_execute_home") if monitor != null else Time.get_ticks_usec()
			_execute_home(entry, body, perception, delta)
			if monitor != null:
				monitor.end_section("npc_execute_home", home_start)
		NpcEnumsScript.GOAL_KIND_GUARD:
			var guard_start: int = monitor.begin_section("npc_execute_guard") if monitor != null else Time.get_ticks_usec()
			_execute_guard(entry, body, perception, schedule, delta)
			if monitor != null:
				monitor.end_section("npc_execute_guard", guard_start)
		NpcEnumsScript.GOAL_KIND_WORK:
			var work_start: int = monitor.begin_section("npc_execute_work") if monitor != null else Time.get_ticks_usec()
			_execute_job(entry, body, delta)
			if monitor != null:
				monitor.end_section("npc_execute_work", work_start)
		NpcEnumsScript.GOAL_KIND_FORAGE:
			var forage_start: int = monitor.begin_section("npc_execute_forage") if monitor != null else Time.get_ticks_usec()
			_execute_job(entry, body, delta)
			if monitor != null:
				monitor.end_section("npc_execute_forage", forage_start)
		_:
			var idle_start: int = monitor.begin_section("npc_execute_idle") if monitor != null else Time.get_ticks_usec()
			_execute_idle(entry, body, delta)
			if monitor != null:
				monitor.end_section("npc_execute_idle", idle_start)

func _execute_scripted(entry: Dictionary, body: Node3D, perception: Dictionary, delta: float) -> void:
	entry["routePriority"] = 180
	var order_kind := _scripted_order_kind(body, entry)
	if order_kind == "wait":
		entry["lastMoveDistance"] = 0.0
		_mark_scripted_order(entry, "ACTIVE", "wait")
	elif order_kind == "face_player":
		entry["lastMoveDistance"] = 0.0
		var face_target: Vector3 = body.get_meta("npc_dialogue_face_position", body.global_position)
		if main != null and main.get("player") is Node3D:
			face_target = (main.get("player") as Node3D).global_position
		if npc_system.has_method("face_position"):
			npc_system.call("face_position", body, face_target)
		_mark_scripted_order(entry, "ARRIVED", "face_player")
	elif body.has_meta("npc_scripted_target") and npc_system.has_method("update_scripted_npc"):
		_execute_scripted_combat_overlay(entry, body, perception)
		npc_system.call("update_scripted_npc", entry, body, delta)
	else:
		_release_action_owned_state(entry, "scripted_order_cancelled")
		_mark_scripted_order(entry, "FAILED_TARGET_GONE", "missing_scripted_target")

func _execute_scripted_combat_overlay(entry: Dictionary, body: Node3D, perception: Dictionary) -> void:
	entry["scriptedCombatOverlay"] = false
	body.set_meta("npc_scripted_combat_overlay", false)
	if not bool(body.get_meta("npc_scripted_combat_overlay_enabled", false)):
		return
	if npc_system == null or not npc_system.has_method("update_fighter_target"):
		return
	if not bool(entry.get("canFight", false)):
		return
	var target_hostile = perception.get("threat") if bool(perception.get("activeThreat", false)) else null
	if target_hostile == null and npc_system.has_method("scripted_combat_target"):
		target_hostile = npc_system.call("scripted_combat_target", entry, body, 42.0)
	if target_hostile == null or not is_instance_valid(target_hostile):
		return
	var weapon_id := String(entry.get("weaponId", ""))
	npc_system.call("update_fighter_target", entry, body, target_hostile, weapon_id)
	entry["scriptedCombatOverlay"] = true
	body.set_meta("npc_scripted_combat_overlay", true)

func _execute_home(entry: Dictionary, body: Node3D, perception: Dictionary, delta: float) -> void:
	_preempt_job_for_home(entry)
	_invalidate_stale_home_arrival(entry, body)
	if npc_system.has_method("settle_home_if_reached"):
		npc_system.call("settle_home_if_reached", entry)
	if bool(entry.get("insideHome", false)):
		entry["homeReturnTime"] = 0.0
		entry["lastMoveDistance"] = 0.0
		entry["routeStatus"] = "arrived"
		entry["routeReason"] = ""
		entry["pathWaypoints"] = []
		entry["routeCells"] = []
		body.set_meta("npc_route_status", "arrived")
		body.set_meta("npc_route_reason", "")
		if _scripted_order_kind(body, entry) == "go_home":
			_mark_scripted_order(entry, "ARRIVED", "home_interior_reached")
		return
	entry["homeReturnTime"] = float(entry.get("homeReturnTime", 0.0)) + delta
	entry["routePriority"] = 140
	var target: Vector3 = npc_system.call("home_route_target", entry) if npc_system.has_method("home_route_target") else entry.get("homePosition", body.global_position)
	entry["homeActiveTargetCell"] = _flat_cell_for_position(target)
	var speed_mode := _scripted_speed_mode(body) if _scripted_order_kind(body, entry) == "go_home" else "walking"
	var speed := _set_motion_speed_mode(entry, speed_mode, "home_route")
	var moved := float(npc_system.call("move_npc", entry, target, speed * delta, true, false, delta)) if npc_system.has_method("move_npc") else 0.0
	entry["lastMoveDistance"] = moved
	if moved <= 0.001 and npc_system.has_method("home_route_step_reached") and not bool(npc_system.call("home_route_step_reached", entry, target)):
		var route_status := String(entry.get("routeStatus", ""))
		if route_status in ["arrived", "partial", "blocked", "unreachable"] and (entry.get("pathWaypoints", []) as Array).is_empty():
			entry["routeForceReplan"] = true
	if npc_system.has_method("settle_home_if_reached"):
		npc_system.call("settle_home_if_reached", entry)
	_invalidate_stale_home_arrival(entry, body)
	if _scripted_order_kind(body, entry) == "go_home":
		if bool(entry.get("insideHome", false)):
			_mark_scripted_order(entry, "ARRIVED", "home_interior_reached")
		else:
			_mark_scripted_order(entry, "ACTIVE", "go_home")
	var now_perception: Dictionary = perception_service.snapshot(entry, { "scheduleState": NpcEnumsScript.SCHEDULE_STATE_NIGHT })
	var active_target_cell: Vector2i = entry.get("homeActiveTargetCell", entry.get("homeCell", Vector2i.ZERO))
	var home_cell: Vector2i = entry.get("homeCell", active_target_cell)
	if not bool(now_perception.get("insideHome", false)) and active_target_cell == home_cell and _home_route_terminal(entry):
		if _scripted_order_kind(body, entry) == "go_home":
			_mark_scripted_order(entry, "FAILED_BLOCKED", _home_failure_reason(entry, now_perception))
		recovery_policy.mark_home_blocked(entry, _home_failure_reason(entry, now_perception))

func _preempt_job_for_home(entry: Dictionary) -> void:
	var phase := String(entry.get("jobPhase", "idle"))
	if not (phase in ["outbound", "searching", "gathering", "returning", "stall"]):
		return
	_release_job_reservation(entry, "schedule_home")
	entry["jobPhase"] = "idle"
	entry["jobTimer"] = 0.0
	entry["jobTargetNode"] = null
	entry["jobObjectId"] = ""
	entry["jobReservationId"] = ""
	entry["jobApproachSlotId"] = ""
	entry["jobTarget"] = entry.get("homePosition", entry.get("porchPosition", Vector3.ZERO))
	entry["routeForceReplan"] = true
	var body := entry.get("body") as Node
	if body != null:
		body.set_meta("npc_job_phase", "idle")

func _execute_guard(entry: Dictionary, body: Node3D, perception: Dictionary, schedule: Dictionary, delta: float) -> void:
	entry["insideHome"] = false
	body.set_meta("npc_inside_home", false)
	entry["homeReturnTime"] = 0.0
	entry["homeRouteIndex"] = 0
	entry["routePriority"] = 130 if bool(schedule.get("activeGuardDuty", false)) else 170
	var weapon_id := String(entry.get("weaponId", ""))
	var target_hostile = perception.get("threat") if bool(perception.get("activeThreat", false)) else null
	var monitor = performance_monitor()
	var target_start: int = monitor.begin_section("npc_guard_target") if monitor != null else Time.get_ticks_usec()
	var target: Vector3 = entry.get("guardTargetCache", entry.get("guardPosition", body.global_position))
	var refresh_timer := float(entry.get("guardTargetRefreshTimer", 0.0)) - delta
	var hostile_key := ""
	if target_hostile != null and is_instance_valid(target_hostile):
		hostile_key = str(target_hostile.get_instance_id())
	var refresh_required := refresh_timer <= 0.0 or hostile_key != String(entry.get("guardTargetHostileKey", ""))
	if refresh_required and _guard_target_refresh_budget_available(entry):
		target = npc_system.call("update_fighter_target", entry, body, target_hostile, weapon_id) if npc_system.has_method("update_fighter_target") else entry.get("guardPosition", body.global_position)
		refresh_timer = _deterministic_seconds(entry, "guard_threat_refresh", 0.25, 0.45) if target_hostile != null else _deterministic_seconds(entry, "guard_post_refresh", 2.0, 3.2)
		entry["guardTargetCache"] = target
		entry["guardTargetHostileKey"] = hostile_key
	elif refresh_required:
		refresh_timer = minf(float(entry.get("guardTargetRefreshTimer", 0.0)), 0.05)
	entry["guardTargetRefreshTimer"] = refresh_timer
	if monitor != null:
		monitor.end_section("npc_guard_target", target_start)
	var move_start: int = monitor.begin_section("npc_guard_move") if monitor != null else Time.get_ticks_usec()
	entry["guardRouteCritical"] = target_hostile != null
	var speed := _set_motion_speed_mode(entry, "walking", "guard_route")
	var moved := float(npc_system.call("move_npc", entry, target, speed * delta, false, true, delta)) if npc_system.has_method("move_npc") else 0.0
	entry.erase("guardRouteCritical")
	if monitor != null:
		monitor.end_section("npc_guard_move", move_start)
	entry["lastMoveDistance"] = moved
	entry["guardDutyState"] = "intercept_threat" if target_hostile != null else "patrol"
	body.set_meta("npc_guard_duty_state", entry["guardDutyState"])

func _execute_job(entry: Dictionary, body: Node3D, delta: float) -> void:
	entry["homeReturnTime"] = 0.0
	entry["homeRouteIndex"] = 0
	entry["insideHome"] = false
	body.set_meta("npc_inside_home", false)
	entry["routePriority"] = 90
	if not _job_selection_budget_available(entry, delta):
		entry["lastMoveDistance"] = 0.0
		entry["routeStatus"] = "idle"
		return
	var monitor = performance_monitor()
	var job_state_start: int = monitor.begin_section("npc_update_day_job") if monitor != null else Time.get_ticks_usec()
	var moving_job := _update_day_job(entry, delta)
	if monitor != null:
		monitor.end_section("npc_update_day_job", job_state_start)
	if moving_job:
		var target: Vector3 = entry.get("jobTarget", body.global_position)
		target = _staged_departure_motion_target(entry, body, target)
		var job_move_start: int = monitor.begin_section("npc_job_move") if monitor != null else Time.get_ticks_usec()
		var speed := _set_motion_speed_mode(entry, "walking", "job_route")
		var moved := float(npc_system.call("move_npc", entry, target, speed * delta, false, _job_route_allows_outside(entry, body), delta)) if npc_system.has_method("move_npc") else 0.0
		if monitor != null:
			monitor.end_section("npc_job_move", job_move_start)
		entry["lastMoveDistance"] = moved
		var route_status := String(entry.get("routeStatus", ""))
		if moved <= 0.001 and route_status != "pending":
			entry["routeForceReplan"] = true
	else:
		entry["lastMoveDistance"] = 0.0
		if String(entry.get("jobPhase", "")) != "gathering":
			entry["routeStatus"] = "idle"

func _job_allows_outside_movement(entry: Dictionary) -> bool:
	return String(entry.get("job", "")) == "forage"

func _job_route_allows_outside(entry: Dictionary, body: Node3D) -> bool:
	if _job_allows_outside_movement(entry):
		return true
	if body == null:
		return false
	return _inside_home_bounds_now(entry, body.global_position) or _near_home_exit_needs_clearance(entry, body)

func _worker_needs_town_recovery(entry: Dictionary, body: Node3D) -> bool:
	if body == null:
		return false
	if _job_allows_outside_movement(entry) or String(entry.get("job", "")) in ["guard", ""]:
		return false
	if _point_inside_town(entry, body.global_position):
		return false
	return String(entry.get("activeGoalKind", "")) in [String(NpcEnumsScript.GOAL_KIND_WORK), "work", ""]

func _advance_worker_town_recovery(entry: Dictionary, body: Node3D, delta: float) -> Dictionary:
	_release_job_reservation(entry, "outside_town_recovery")
	entry["jobPhase"] = "idle"
	entry["jobTimer"] = 0.0
	entry["jobTargetNode"] = null
	entry["jobObjectId"] = ""
	entry["jobReservationId"] = ""
	entry["jobApproachSlotId"] = ""
	var target: Vector3 = entry.get("porchPosition", entry.get("homePosition", body.global_position))
	entry["jobTarget"] = target
	entry["routePriority"] = 120
	_reset_route_for_replan(entry, "worker_outside_town_recovery")
	var speed := _set_motion_speed_mode(entry, "walking", "worker_outside_town_recovery")
	var moved := float(npc_system.call("move_npc", entry, target, speed * delta, true, false, delta)) if npc_system.has_method("move_npc") else 0.0
	entry["lastMoveDistance"] = moved
	if _point_inside_town(entry, body.global_position):
		entry["routeForceReplan"] = true
	body.set_meta("npc_job_phase", "idle")
	return _motion_result(entry, "job", "worker_town_recovery")

func _invalidate_stale_home_arrival(entry: Dictionary, body: Node3D) -> void:
	if body == null:
		return
	if String(entry.get("routeStatus", "")) != "arrived":
		return
	var perception: Dictionary = perception_service.snapshot(entry, { "scheduleState": NpcEnumsScript.SCHEDULE_STATE_NIGHT })
	if bool(perception.get("insideHome", false)):
		return
	if _arrived_at_incomplete_home_route_step(entry):
		return
	entry["insideHome"] = false
	body.set_meta("npc_inside_home", false)
	_reset_route_for_replan(entry, "stale_home_arrival")

func _arrived_at_incomplete_home_route_step(entry: Dictionary) -> bool:
	var route_positions: Array = entry.get("homeRoutePositions", []) if entry.get("homeRoutePositions", []) is Array else []
	if route_positions.size() <= 1:
		return false
	var route_index := clampi(int(entry.get("homeRouteIndex", 0)), 0, route_positions.size())
	if route_index >= route_positions.size() - 1:
		return false
	var current_target = route_positions[route_index]
	if not (current_target is Vector3):
		return false
	var current_target_cell := _flat_cell_for_position(current_target)
	var active_target_cell: Vector2i = entry.get("homeActiveTargetCell", Vector2i(999999, 999999)) if entry.get("homeActiveTargetCell", Vector2i(999999, 999999)) is Vector2i else Vector2i(999999, 999999)
	return active_target_cell == current_target_cell

func _reset_route_for_replan(entry: Dictionary, reason: String) -> void:
	entry["routeStatus"] = "waiting"
	entry["routeReason"] = reason
	entry["routeForceReplan"] = true
	entry["pathWaypoints"] = []
	entry["routeCells"] = []
	entry["routeActions"] = {}
	entry["routeWaitTicks"] = 0
	entry["blockedMoveTime"] = 0.0
	var body := entry.get("body") as Node
	if body != null:
		body.set_meta("npc_route_status", "waiting")
		body.set_meta("npc_route_reason", reason)

func _job_selection_budget_available(entry: Dictionary, delta: float) -> bool:
	var phase := String(entry.get("jobPhase", "idle"))
	if not (phase in ["idle", "searching", "gathering", "returning"]):
		return true
	var timer := float(entry.get("jobTimer", 0.0)) - delta
	var hungry := float(entry.get("hunger", 100.0)) < 82.0
	if phase in ["idle", "searching"] and timer > 0.0 and not hungry:
		return true
	if phase in ["gathering", "returning"]:
		return true
	var frame := update_frame_serial
	if frame != job_selection_frame:
		job_selection_frame = frame
		job_selections_this_frame = 0
	if job_selections_this_frame >= JOB_SELECTIONS_PER_FRAME:
		entry["jobTimer"] = minf(float(entry.get("jobTimer", 0.0)), 0.05)
		return false
	job_selections_this_frame += 1
	return true

func _guard_target_refresh_budget_available(entry: Dictionary) -> bool:
	var frame := update_frame_serial
	if frame != guard_target_frame:
		guard_target_frame = frame
		guard_target_refreshes_this_frame = 0
	if guard_target_refreshes_this_frame >= GUARD_TARGET_REFRESHES_PER_FRAME:
		entry["guardTargetRefreshDeferredFrame"] = frame
		return false
	guard_target_refreshes_this_frame += 1
	return true

func _update_day_job(entry: Dictionary, delta: float) -> bool:
	var body := entry.get("body") as Node3D
	if body == null:
		return false
	var job := String(entry.get("job", ""))
	if not (job in ["forage", "wood", "stone", "trade"]):
		return false
	if job == "forage":
		var forage_start := _begin_job_phase_section(entry, job)
		var forage_result := _update_forager_goal(entry, body, delta)
		_end_job_phase_section("npc_job_phase_%s_%s" % [job, String(entry.get("jobPhase", "idle"))], forage_start)
		return forage_result
	if job == "trade":
		var trade_start := _begin_job_phase_section(entry, job)
		var trade_result := _update_trader_goal(entry, body, delta)
		_end_job_phase_section("npc_job_phase_%s_%s" % [job, String(entry.get("jobPhase", "idle"))], trade_start)
		return trade_result
	var phase := String(entry.get("jobPhase", "idle"))
	var phase_start := _begin_job_phase_section(entry, job)
	if phase in ["outbound", "gathering", "returning"]:
		_clear_home_route_terminal(entry)
	var timer := float(entry.get("jobTimer", 0.0)) - delta
	if phase == "idle":
		if timer > 0.0 and not _inside_home_now(entry, body):
			entry["jobTimer"] = timer
			body.set_meta("npc_job_phase", "idle")
			return false
		var resource_target := _find_job_resource_target(entry, job)
		if resource_target == null:
			entry["jobPhase"] = "searching"
			entry["jobTarget"] = _choose_job_target(entry)
			entry["jobTimer"] = _deterministic_seconds(entry, "resource_search_retry", 3.0, 7.0)
			_set_npc_goal(entry, "search for %s" % String(entry.get("jobResource", "resource")))
			body.set_meta("npc_job_phase", "searching")
			return true
		if not _reserve_job_target(entry, resource_target, "harvest_resource"):
			entry["jobTimer"] = _deterministic_seconds(entry, "resource_reserve_retry", 1.4, 3.0)
			body.set_meta("npc_job_phase", "idle")
			return false
		entry["jobPhase"] = "outbound"
		_clear_home_route_terminal(entry)
		_set_npc_goal(entry, "gather %s" % String(entry.get("jobResource", "resource")))
		entry["jobTimer"] = _deterministic_seconds(entry, "resource_outbound_timeout", 6.0, 12.0)
		body.set_meta("npc_job_phase", "outbound")
		return true
	if phase == "outbound":
		return _update_outbound_job(entry, body, timer)
	if phase == "gathering":
		return _update_gathering_job(entry, body, timer)
	if phase == "returning":
		return _update_returning_job(entry, body, timer)
	entry["jobPhase"] = "idle"
	entry["jobTimer"] = _deterministic_seconds(entry, "resource_idle_reset", 4.0, 9.0)
	body.set_meta("npc_job_phase", "idle")
	_end_job_phase_section("npc_job_phase_%s_%s" % [job, String(entry.get("jobPhase", "idle"))], phase_start)
	return false

func _staged_departure_motion_target(entry: Dictionary, body: Node3D, target: Vector3) -> Vector3:
	if body == null:
		return target
	var leaving_town := _point_inside_town(entry, body.global_position) and not _point_inside_town(entry, target)
	if _inside_home_now(entry, body) or _inside_home_bounds_now(entry, body.global_position) or (leaving_town and _near_home_exit_needs_clearance(entry, body)):
		return _home_exit_clearance_target(entry, body.global_position.y)
	return target

func _near_home_exit_needs_clearance(entry: Dictionary, body: Node3D) -> bool:
	if body == null:
		return false
	var porch_cell: Vector2i = entry.get("porchCell", entry.get("homeCell", Vector2i.ZERO))
	var current_cell := _flat_cell_for_position(body.global_position)
	if abs(current_cell.x - porch_cell.x) > 1 or abs(current_cell.y - porch_cell.y) > 1:
		return false
	return current_cell != _home_exit_clearance_cell(entry)

func _inside_home_now(entry: Dictionary, body: Node3D) -> bool:
	if body == null:
		return false
	if autonomy_system != null and autonomy_system.has_method("is_inside_home_interior"):
		return bool(autonomy_system.call("is_inside_home_interior", entry, body.global_position))
	return bool(entry.get("insideHome", false))

func _clear_inside_home_if_not_semantic(entry: Dictionary, body: Node3D) -> void:
	if body == null or not is_instance_valid(body):
		return
	if _inside_home_now(entry, body):
		return
	if bool(entry.get("insideHome", false)):
		entry["insideHome"] = false
		body.set_meta("npc_inside_home", false)

func _inside_home_bounds_now(entry: Dictionary, position: Vector3) -> bool:
	var portal = null
	if autonomy_system != null and autonomy_system.get("door_portals") != null:
		portal = HomeInteriorServiceScript.portal_for_entry(entry, autonomy_system.get("door_portals"))
	return bool(HomeInteriorServiceScript.status(entry, position, portal).get("strictInside", false))

func _home_exit_clearance_cell(entry: Dictionary) -> Vector2i:
	var home_cell: Vector2i = entry.get("homeCell", Vector2i.ZERO)
	var porch_cell: Vector2i = entry.get("porchCell", home_cell)
	var delta := porch_cell - home_cell
	var step := Vector2i.ZERO
	if abs(delta.x) > abs(delta.y):
		step.x = 1 if delta.x >= 0 else -1
	elif delta.y != 0:
		step.y = 1 if delta.y >= 0 else -1
	if step == Vector2i.ZERO:
		var min_cell: Vector2i = entry.get("interiorMinCell", home_cell)
		var max_cell: Vector2i = entry.get("interiorMaxCell", home_cell)
		if porch_cell.x < min_cell.x:
			step.x = -1
		elif porch_cell.x > max_cell.x:
			step.x = 1
		elif porch_cell.y < min_cell.y:
			step.y = -1
		elif porch_cell.y > max_cell.y:
			step.y = 1
	if step == Vector2i.ZERO:
		return porch_cell
	return porch_cell + Vector2i(step.x * 3, step.y * 3)

func _home_exit_clearance_target(entry: Dictionary, fallback_y: float) -> Vector3:
	var porch_cell: Vector2i = entry.get("porchCell", entry.get("homeCell", Vector2i.ZERO))
	var exit_cell := _home_exit_clearance_cell(entry)
	if exit_cell == porch_cell:
		return entry.get("porchPosition", Vector3(float(porch_cell.x) * NpcConstantsScript.CELL_SIZE, fallback_y, float(porch_cell.y) * NpcConstantsScript.CELL_SIZE))
	var position := Vector3(float(exit_cell.x) * NpcConstantsScript.CELL_SIZE, fallback_y, float(exit_cell.y) * NpcConstantsScript.CELL_SIZE)
	var main = npc_system.get("main") if npc_system != null else null
	if main != null and main.has_method("surface_y_at_position"):
		position.y = float(main.call("surface_y_at_position", position)) + 0.04
	return position

func _town_exit_toward(entry: Dictionary, target: Vector3, fallback_y: float) -> Vector3:
	var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
	var radius := maxi(1, int(entry.get("townRadius", 18)))
	var center_position := Vector3(float(center.x) * NpcConstantsScript.CELL_SIZE, fallback_y, float(center.y) * NpcConstantsScript.CELL_SIZE)
	var delta := target - center_position
	delta.y = 0.0
	var exit_distance := float(radius) + 5.0
	var exit_cell := Vector2(float(center.x) + 0.5, float(center.y) + exit_distance)
	if absf(delta.x) > absf(delta.z):
		exit_cell = Vector2(float(center.x) + exit_distance, float(center.y) + 0.5) if delta.x >= 0.0 else Vector2(float(center.x) - exit_distance, float(center.y) + 0.5)
	else:
		exit_cell = Vector2(float(center.x) + 0.5, float(center.y) + exit_distance) if delta.z >= 0.0 else Vector2(float(center.x) + 0.5, float(center.y) - exit_distance)
	var position := Vector3(exit_cell.x * NpcConstantsScript.CELL_SIZE, fallback_y, exit_cell.y * NpcConstantsScript.CELL_SIZE)
	var main = npc_system.get("main") if npc_system != null else null
	if main != null and main.has_method("surface_y_at_position"):
		position.y = float(main.call("surface_y_at_position", position)) + 0.04
	return position

func _begin_job_phase_section(entry: Dictionary, job: String) -> int:
	var monitor = performance_monitor()
	var phase := String(entry.get("jobPhase", "idle"))
	return monitor.begin_section("npc_job_phase_%s_%s" % [job, phase]) if monitor != null else Time.get_ticks_usec()

func _end_job_phase_section(section_name: String, start_usec: int) -> void:
	var monitor = performance_monitor()
	if monitor != null:
		monitor.end_section(section_name, start_usec)

func _update_outbound_job(entry: Dictionary, body: Node3D, timer: float) -> bool:
	var target_node := _job_target_node(entry)
	if target_node == null:
		_release_job_reservation(entry, "target_gone")
		entry["jobPhase"] = "idle"
		entry["jobTimer"] = 0.0
		entry["routeForceReplan"] = true
		body.set_meta("npc_job_phase", "idle")
		return true
	if String(entry.get("jobObjectId", "")) == "":
		_reserve_job_target(entry, target_node, "harvest_resource")
	if _current_route_failure_blocks_forager(entry):
		_release_job_reservation(entry, "route_blocked")
		entry["jobPhase"] = "idle"
		entry["jobTimer"] = 0.0
		body.set_meta("npc_job_phase", "idle")
		return true
	var target: Vector3 = entry.get("jobTarget", body.global_position)
	var target_outside := not _point_inside_town(entry, target)
	var job := String(entry.get("job", ""))
	if job in ["wood", "stone"] and target_outside:
		_release_job_reservation(entry, "outside_town_worker_target")
		entry["jobTargetNode"] = null
		entry["jobPhase"] = "idle"
		entry["jobTimer"] = 0.0
		entry["routeForceReplan"] = true
		body.set_meta("npc_job_phase", "idle")
		return true
	var route_arrived := String(entry.get("routeStatus", "")) == "arrived"
	var can_gather_at_target := target_outside if job == "forage" else not target_outside
	if can_gather_at_target and (route_arrived or body.global_position.distance_to(target) <= NpcConstantsScript.CELL_SIZE * 1.1):
		entry["jobPhase"] = "gathering"
		entry["jobTimer"] = _deterministic_seconds(entry, "resource_gather_duration", 1.8, 3.5)
		_clear_route_for_action(entry, "gathering")
		_play_npc_use(entry, "gather")
		body.set_meta("npc_job_phase", "gathering")
		return false
	elif timer <= 0.0:
		entry["jobTarget"] = _smart_object_approach_position(entry, target_node)
		entry["jobTimer"] = _deterministic_seconds(entry, "resource_approach_retry", 4.0, 8.0)
		entry["routeForceReplan"] = true
	else:
		entry["jobTimer"] = timer
	return true

func _update_gathering_job(entry: Dictionary, body: Node3D, timer: float) -> bool:
	if timer > 0.0:
		entry["jobTimer"] = timer
		body.set_meta("npc_job_phase", "gathering")
		return false
	var job := String(entry.get("job", ""))
	var inside_town := _point_inside_town(entry, body.global_position)
	if (job == "forage" and inside_town) or (job in ["wood", "stone"] and not inside_town):
		var invalid_reason := "inside_town_invalid_gather" if job == "forage" else "outside_town_worker_gather"
		_release_job_reservation(entry, invalid_reason)
		entry["jobPhase"] = "outbound"
		var replacement := _find_job_resource_target(entry, String(entry.get("job", "")))
		if replacement != null:
			_reserve_job_target(entry, replacement, "harvest_resource")
		else:
			entry["jobTarget"] = _choose_job_target(entry)
		entry["jobTimer"] = _deterministic_seconds(entry, "resource_invalid_gather_retry", 4.0, 8.0)
		body.set_meta("npc_job_phase", "outbound")
		return true
	if not _complete_worker_resource_target(entry):
		_release_job_reservation(entry, "complete_failed")
		entry["jobPhase"] = "idle"
		entry["jobTimer"] = _deterministic_seconds(entry, "resource_complete_failed_retry", 2.0, 5.0)
		body.set_meta("npc_job_phase", "idle")
		return false
	var runs := int(entry.get("jobRuns", 0)) + 1
	entry["jobRuns"] = runs
	_increment_npc_system_counter("job_runs_completed")
	entry["jobPhase"] = "returning"
	entry["jobTarget"] = entry.get("homePosition", body.global_position)
	_set_npc_goal(entry, "deliver %s" % String(entry.get("jobResource", "resource")))
	entry["jobTimer"] = _deterministic_seconds(entry, "resource_return_timeout", 8.0, 14.0)
	body.set_meta("npc_job_phase", "returning")
	body.set_meta("npc_job_runs", runs)
	body.set_meta("npc_carried_resource", String(entry.get("carriedResource", entry.get("jobResource", ""))))
	return true

func _update_returning_job(entry: Dictionary, body: Node3D, timer: float) -> bool:
	var home: Vector3 = entry.get("homePosition", entry.get("porchPosition", body.global_position))
	var inside_semantic := bool(autonomy_system.call("is_inside_home_interior", entry, body.global_position)) if autonomy_system != null and autonomy_system.has_method("is_inside_home_interior") else false
	if body.global_position.distance_to(home) <= NpcConstantsScript.CELL_SIZE * 1.15 or inside_semantic or timer <= 0.0:
		_complete_deposit_interaction(entry)
		entry["jobPhase"] = "idle"
		_set_npc_goal(entry, "idle")
		entry["jobTimer"] = _deterministic_seconds(entry, "resource_delivered_rest", 8.0, 18.0)
		body.set_meta("npc_job_phase", "idle")
		body.set_meta("npc_carried_resource", "")
		return false
	entry["jobTarget"] = home
	entry["jobTimer"] = timer
	body.set_meta("npc_job_phase", "returning")
	return true

func _update_trader_goal(entry: Dictionary, body: Node3D, delta: float) -> bool:
	var phase := String(entry.get("jobPhase", "idle"))
	var timer := float(entry.get("jobTimer", 0.0)) - delta
	if phase == "idle":
		if timer > 0.0 and not _inside_home_now(entry, body):
			entry["jobTimer"] = timer
			body.set_meta("npc_job_phase", "idle")
			return false
		var stall := _find_trader_stall(entry)
		if stall == null:
			entry["jobTarget"] = _choose_day_target(entry)
			entry["jobPhase"] = "searching"
			entry["jobTimer"] = _deterministic_seconds(entry, "trader_stall_search", 3.0, 7.0)
			_set_npc_goal(entry, "find trader stall")
			body.set_meta("npc_job_phase", "searching")
			return true
		if not _reserve_station_target(entry, stall, "use_trader_stall"):
			entry["jobTimer"] = _deterministic_seconds(entry, "trader_reserve_retry", 2.0, 5.0)
			return false
		entry["jobPhase"] = "outbound"
		entry["jobTimer"] = _deterministic_seconds(entry, "trader_outbound_timeout", 8.0, 14.0)
		_set_npc_goal(entry, "open stall")
		body.set_meta("npc_job_phase", "outbound")
		return true
	if phase == "searching":
		if timer <= 0.0:
			entry["jobPhase"] = "idle"
			entry["jobTimer"] = 0.0
		else:
			entry["jobTimer"] = timer
		return true
	if phase == "outbound":
		var target: Vector3 = entry.get("jobTarget", body.global_position)
		if body.global_position.distance_to(target) <= NpcConstantsScript.CELL_SIZE * 1.05:
			entry["jobPhase"] = "stall"
			entry["jobTimer"] = _deterministic_seconds(entry, "trader_stall_duration", 5.0, 9.0)
			_complete_station_use(entry, "use_trader_stall")
			_set_npc_goal(entry, "tend stall")
			body.set_meta("npc_job_phase", "stall")
		elif timer <= 0.0:
			entry["routeForceReplan"] = true
			entry["jobTimer"] = _deterministic_seconds(entry, "trader_route_retry", 4.0, 7.0)
		else:
			entry["jobTimer"] = timer
		return true
	if phase == "stall":
		if timer <= 0.0:
			entry["jobTimer"] = _deterministic_seconds(entry, "trader_stall_refresh", 5.0, 10.0)
			_complete_station_use(entry, "use_trader_stall")
		else:
			entry["jobTimer"] = timer
		body.set_meta("npc_job_phase", "stall")
		return true
	entry["jobPhase"] = "idle"
	entry["jobTimer"] = _deterministic_seconds(entry, "trader_idle_reset", 2.0, 5.0)
	return false

func _update_forager_goal(entry: Dictionary, body: Node3D, delta: float) -> bool:
	var phase := String(entry.get("jobPhase", "idle"))
	if phase in ["outbound", "searching", "gathering", "returning"]:
		_clear_home_route_terminal(entry)
	var timer := float(entry.get("jobTimer", 0.0)) - delta
	if phase == "idle":
		var hungry := float(entry.get("hunger", 100.0)) < 82.0
		if timer > 0.0 and not hungry and not _inside_home_now(entry, body):
			entry["jobTimer"] = timer
			_set_npc_goal(entry, "rest")
			body.set_meta("npc_job_phase", "idle")
			return false
		var forage := _find_forage_target(entry)
		if forage == null:
			entry["jobPhase"] = "searching"
			entry["jobTimer"] = _deterministic_seconds(entry, "forage_search_retry", 3.0, 7.0)
			entry["jobTarget"] = _choose_job_target(entry)
			_set_npc_goal(entry, "search for berries")
			body.set_meta("npc_job_phase", "searching")
			return true
		if not _reserve_job_target(entry, forage, "harvest_resource"):
			entry["jobPhase"] = "searching"
			entry["jobTimer"] = _deterministic_seconds(entry, "forage_reserve_retry", 2.0, 4.5)
			entry["jobTarget"] = _choose_job_target(entry)
			_set_npc_goal(entry, "search for berries")
			body.set_meta("npc_job_phase", "searching")
			return true
		entry["jobPhase"] = "outbound"
		entry["jobTimer"] = _deterministic_seconds(entry, "forage_outbound_timeout", 12.0, 22.0)
		_clear_home_route_terminal(entry)
		_set_npc_goal(entry, "forage berries")
		body.set_meta("npc_job_phase", "outbound")
		return true
	if phase == "outbound" or phase == "searching":
		var target_node := _job_target_node(entry)
		if phase == "searching" and target_node == null and timer <= 0.0:
			var forage_retry := _find_forage_target(entry)
			if forage_retry != null and _reserve_job_target(entry, forage_retry, "harvest_resource"):
				entry["jobPhase"] = "outbound"
				entry["jobTimer"] = _deterministic_seconds(entry, "forage_outbound_timeout", 12.0, 22.0)
				entry["forageRouteFailures"] = 0
				entry["routeForceReplan"] = true
				_clear_home_route_terminal(entry)
				_set_npc_goal(entry, "forage berries")
				body.set_meta("npc_job_phase", "outbound")
				return true
			entry["jobTarget"] = _choose_job_target(entry)
			entry["jobTimer"] = _deterministic_seconds(entry, "forage_search_retry", 3.0, 7.0)
			entry["routeForceReplan"] = true
			_set_npc_goal(entry, "search for berries")
			body.set_meta("npc_job_phase", "searching")
			return true
		if phase == "searching" and target_node != null:
			phase = "outbound"
			entry["jobPhase"] = "outbound"
			_set_npc_goal(entry, "forage berries")
			body.set_meta("npc_job_phase", "outbound")
		if target_node == null and phase == "outbound":
			entry["jobTargetNode"] = null
			_release_job_reservation(entry, "target_gone")
			entry["jobPhase"] = "idle"
			entry["jobTimer"] = 0.0
			return true
		if target_node != null and String(entry.get("jobObjectId", "")) == "":
			_reserve_job_target(entry, target_node, "harvest_resource")
		var target: Vector3 = entry.get("jobTarget", body.global_position)
		var outside_town := not _point_inside_town(entry, body.global_position)
		var forage_action_reach := NpcConstantsScript.CELL_SIZE * 3.0
		var vertical_ok := target_node == null or absf(body.global_position.y - target_node.global_position.y) <= NpcConstantsScript.CELL_SIZE * 2.0
		var reached_target := body.global_position.distance_to(target) <= forage_action_reach
		if target_node != null and vertical_ok and reached_target:
			entry["jobPhase"] = "gathering"
			entry["jobTimer"] = _deterministic_seconds(entry, "forage_gather_duration", 0.4, 0.8)
			_clear_route_for_action(entry, "forage_gathering")
			_set_npc_goal(entry, "pick berries")
			_play_npc_use(entry, "gather")
			body.set_meta("npc_job_phase", "gathering")
			return false
		if target_node != null and _current_route_failure_blocks_forager(entry):
			_release_job_reservation(entry, "route_blocked")
			var failures := int(entry.get("forageRouteFailures", 0)) + 1
			entry["forageRouteFailures"] = failures
			entry["routeForceReplan"] = true
			var forage_failure_limit := maxi(NpcConstantsScript.ROUTE_REPAIR_FAILURE_LIMIT, 8)
			if failures >= forage_failure_limit:
				_mark_forager_target_unreachable(entry, target_node)
				entry["jobTargetNode"] = null
				entry["jobPhase"] = "searching"
				entry["jobTarget"] = _choose_job_target(entry)
				entry["jobTimer"] = _deterministic_seconds(entry, "forage_blocked_search", 3.0, 7.0)
				_set_npc_goal(entry, "search for berries")
				body.set_meta("npc_job_phase", "searching")
				return true
			entry["jobTargetNode"] = target_node
			entry["jobPhase"] = "outbound"
			entry["jobTimer"] = _deterministic_seconds(entry, "forage_route_retry", 3.0, 7.0)
			entry["routeStatus"] = "waiting"
			entry["routeReason"] = "retry_forage_route"
			_set_npc_goal(entry, "forage berries")
			body.set_meta("npc_job_phase", "outbound")
			return true
		if phase == "searching" and outside_town and target_node == null:
			entry["jobPhase"] = "idle"
			entry["jobTimer"] = 0.0
			entry["routeForceReplan"] = true
			_set_npc_goal(entry, "search for berries")
			body.set_meta("npc_job_phase", "idle")
		else:
			_set_npc_goal(entry, "forage berries" if phase == "outbound" else "search for berries")
			if timer <= 0.0:
				if phase == "outbound" and forager_route_is_progressing(entry):
					entry["jobTimer"] = _deterministic_seconds(entry, "forage_route_continue", 3.0, 6.0)
					body.set_meta("npc_job_phase", "outbound")
					return true
				if target_node != null:
					entry["jobTarget"] = _smart_object_approach_position(entry, target_node)
				else:
					entry["jobTarget"] = _choose_job_target(entry)
				_clear_home_route_terminal(entry)
				entry["routeForceReplan"] = true
				timer = _deterministic_seconds(entry, "forage_route_retry", 3.0, 7.0)
			entry["jobTimer"] = timer
		return true
	if phase == "gathering":
		if timer > 0.0:
			entry["jobTimer"] = timer
			_set_npc_goal(entry, "pick berries")
			body.set_meta("npc_job_phase", "gathering")
			return false
		if not _harvest_forager_target(entry):
			_release_job_reservation(entry, "harvest_failed")
			entry["jobPhase"] = "idle"
			entry["jobTimer"] = _deterministic_seconds(entry, "forage_harvest_failed_retry", 2.0, 5.0)
			body.set_meta("npc_job_phase", "idle")
			return false
		entry["forageRouteFailures"] = 0
		var runs := int(entry.get("jobRuns", 0)) + 1
		entry["jobRuns"] = runs
		_increment_npc_system_counter("job_runs_completed")
		_increment_npc_system_counter("npc_forage_runs")
		entry["jobPhase"] = "returning"
		entry["jobTarget"] = entry.get("homePosition", body.global_position)
		entry["jobTimer"] = _deterministic_seconds(entry, "forage_return_timeout", 10.0, 18.0)
		_set_npc_goal(entry, "bring berries home")
		body.set_meta("npc_job_phase", "returning")
		body.set_meta("npc_job_runs", runs)
		body.set_meta("npc_carried_resource", "berries")
		return true
	if phase == "returning":
		var home: Vector3 = entry.get("homePosition", entry.get("porchPosition", body.global_position))
		var inside_semantic := bool(autonomy_system.call("is_inside_home_interior", entry, body.global_position)) if autonomy_system != null and autonomy_system.has_method("is_inside_home_interior") else false
		if body.global_position.distance_to(home) <= NpcConstantsScript.CELL_SIZE * 1.15 or inside_semantic or timer <= 0.0:
			if float(entry.get("hunger", 100.0)) < 86.0 and _npc_inventory_count(entry, "berries") > 0:
				_npc_inventory_add(entry, "berries", -1)
				entry["hunger"] = minf(float(entry.get("maxHunger", 100.0)), float(entry.get("hunger", 100.0)) + 24.0)
				_increment_npc_system_counter("npc_food_eaten")
			else:
				_complete_deposit_interaction(entry)
			entry["jobPhase"] = "idle"
			entry["jobTimer"] = _deterministic_seconds(entry, "forage_returned_rest", 5.0, 12.0)
			_set_npc_goal(entry, "rest")
			body.set_meta("npc_job_phase", "idle")
			body.set_meta("npc_carried_resource", "")
			return false
		entry["jobTarget"] = home
		entry["jobTimer"] = timer
		_set_npc_goal(entry, "bring berries home")
		body.set_meta("npc_job_phase", "returning")
		return true
	entry["jobPhase"] = "idle"
	entry["jobTimer"] = _deterministic_seconds(entry, "forage_idle_reset", 3.0, 7.0)
	return false

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
	var speed := _set_motion_speed_mode(entry, "walking", "idle_anchor")
	var moved := float(npc_system.call("move_npc", entry, target, speed * delta, false, false, delta)) if npc_system.has_method("move_npc") else 0.0
	entry["lastMoveDistance"] = moved

func _choose_semantic_idle_anchor(entry: Dictionary, body: Node3D) -> Vector3:
	if npc_system != null and npc_system.has_method("choose_day_target"):
		return npc_system.call("choose_day_target", entry)
	return entry.get("porchPosition", body.global_position)

func _deterministic_seconds(entry: Dictionary, domain: String, minimum: float, maximum: float) -> float:
	var key := "%s:%s:%s:%s:%d:%s" % [
		String(entry.get("id", "npc")),
		String(entry.get("role", "")),
		String(entry.get("job", "")),
		String(entry.get("jobPhase", "")),
		int(entry.get("jobRuns", 0)),
		domain
	]
	var unit := float(abs(hash(key)) % 100000) / 99999.0
	return lerpf(minimum, maximum, unit)

func _scripted_speed_mode(body: Node) -> String:
	if body == null or not is_instance_valid(body):
		return "walking"
	return String(body.get_meta("npc_scripted_speed_mode", "walking"))

func _set_motion_speed_mode(entry: Dictionary, speed_mode: String, reason: String) -> float:
	var normalized := speed_mode
	if npc_system != null and npc_system.has_method("set_npc_speed_mode"):
		normalized = String(npc_system.call("set_npc_speed_mode", entry, speed_mode, reason))
	if npc_system != null and npc_system.has_method("npc_speed_for_mode"):
		return float(npc_system.call("npc_speed_for_mode", entry, normalized))
	if normalized in ["sprint", "sprinting", "rush", "rushing", "run", "running"]:
		return 6.4
	return 2.6

func _set_npc_goal(entry: Dictionary, goal: String) -> void:
	if npc_system != null and npc_system.has_method("set_npc_goal"):
		npc_system.call("set_npc_goal", entry, goal)
		return
	entry["goal"] = goal
	var body := entry.get("body") as Node
	if body != null:
		body.set_meta("npc_goal", goal)

func _play_npc_use(entry: Dictionary, action: String) -> void:
	if npc_system != null and npc_system.has_method("play_npc_use"):
		npc_system.call("play_npc_use", entry, action)

func _clear_home_route_terminal(entry: Dictionary) -> void:
	if npc_system != null and npc_system.has_method("clear_home_route_terminal"):
		npc_system.call("clear_home_route_terminal", entry)

func _clear_route_for_action(entry: Dictionary, reason: String) -> void:
	entry["routeStatus"] = "arrived"
	entry["routeReason"] = reason
	entry["pathWaypoints"] = []
	entry["routeCells"] = []
	entry["routeActions"] = {}
	entry["routeForceReplan"] = false
	entry["routeWaitTicks"] = 0
	entry["blockedMoveTime"] = 0.0
	var body := entry.get("body") as Node
	if body != null:
		body.set_meta("npc_route_status", "arrived")
		body.set_meta("npc_route_reason", reason)

func _choose_day_target(entry: Dictionary) -> Vector3:
	if npc_system != null and npc_system.has_method("choose_day_target"):
		return npc_system.call("choose_day_target", entry)
	return entry.get("porchPosition", Vector3.ZERO)

func _choose_job_target(entry: Dictionary) -> Vector3:
	if npc_system != null and npc_system.has_method("choose_job_target"):
		return npc_system.call("choose_job_target", entry)
	return entry.get("porchPosition", Vector3.ZERO)

func _point_inside_town(entry: Dictionary, position: Vector3) -> bool:
	if npc_system != null and npc_system.has_method("point_inside_town"):
		return bool(npc_system.call("point_inside_town", entry, position))
	var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
	var radius := float(entry.get("townRadius", 18)) * NpcConstantsScript.CELL_SIZE
	var flat := Vector2(position.x - float(center.x) * NpcConstantsScript.CELL_SIZE, position.z - float(center.y) * NpcConstantsScript.CELL_SIZE)
	return flat.length() <= radius

func _find_job_resource_target(entry: Dictionary, job: String) -> Node3D:
	var monitor = performance_monitor()
	var start: int = monitor.begin_section("npc_find_job_resource_target") if monitor != null else Time.get_ticks_usec()
	var result = npc_system.call("find_job_resource_target", entry, job) if npc_system != null and npc_system.has_method("find_job_resource_target") else null
	if monitor != null:
		monitor.end_section("npc_find_job_resource_target", start)
	return result

func _find_forage_target(entry: Dictionary) -> Node3D:
	var monitor = performance_monitor()
	var start: int = monitor.begin_section("npc_find_forage_target") if monitor != null else Time.get_ticks_usec()
	var result = npc_system.call("find_forage_target", entry) if npc_system != null and npc_system.has_method("find_forage_target") else null
	if monitor != null:
		monitor.end_section("npc_find_forage_target", start)
	return result

func _find_trader_stall(entry: Dictionary) -> Node3D:
	return npc_system.call("find_trader_stall", entry) if npc_system != null and npc_system.has_method("find_trader_stall") else null

func _job_target_node(entry: Dictionary) -> Node3D:
	return npc_system.call("job_target_node", entry) if npc_system != null and npc_system.has_method("job_target_node") else null

func _reserve_job_target(entry: Dictionary, target_node: Node3D, action: String) -> bool:
	var monitor = performance_monitor()
	var start: int = monitor.begin_section("npc_reserve_job_target") if monitor != null else Time.get_ticks_usec()
	var result := bool(npc_system.call("reserve_job_target", entry, target_node, action)) if npc_system != null and npc_system.has_method("reserve_job_target") else false
	if monitor != null:
		monitor.end_section("npc_reserve_job_target", start)
	return result

func _reserve_station_target(entry: Dictionary, station: Node3D, action: String) -> bool:
	return bool(npc_system.call("reserve_station_target", entry, station, action)) if npc_system != null and npc_system.has_method("reserve_station_target") else false

func _release_job_reservation(entry: Dictionary, reason := "released") -> void:
	if npc_system != null and npc_system.has_method("release_job_reservation"):
		npc_system.call("release_job_reservation", entry, reason)

func _current_route_failure_blocks_forager(entry: Dictionary) -> bool:
	return bool(npc_system.call("current_route_failure_blocks_forager", entry)) if npc_system != null and npc_system.has_method("current_route_failure_blocks_forager") else false

func forager_route_is_progressing(entry: Dictionary) -> bool:
	if String(entry.get("routeStatus", "")) != "moving":
		return false
	var waypoints: Array = entry.get("pathWaypoints", [])
	if waypoints.is_empty():
		return false
	var progress: Dictionary = entry.get("corridorProgress", {}) if entry.get("corridorProgress", {}) is Dictionary else {}
	return int(progress.get("noProgressTicks", 0)) < 24

func _mark_forager_target_unreachable(entry: Dictionary, node: Node3D) -> void:
	if npc_system != null and npc_system.has_method("mark_forager_target_unreachable"):
		npc_system.call("mark_forager_target_unreachable", entry, node)

func _smart_object_approach_position(entry: Dictionary, target_node: Node3D) -> Vector3:
	return npc_system.call("smart_object_approach_position", entry, target_node) if npc_system != null and npc_system.has_method("smart_object_approach_position") else entry.get("jobTarget", target_node.global_position if target_node != null else Vector3.ZERO)

func _complete_worker_resource_target(entry: Dictionary) -> bool:
	return bool(npc_system.call("complete_worker_resource_target", entry)) if npc_system != null and npc_system.has_method("complete_worker_resource_target") else false

func _harvest_forager_target(entry: Dictionary) -> bool:
	return bool(npc_system.call("harvest_forager_target", entry)) if npc_system != null and npc_system.has_method("harvest_forager_target") else _complete_worker_resource_target(entry)

func _complete_deposit_interaction(entry: Dictionary) -> bool:
	return bool(npc_system.call("complete_deposit_interaction", entry)) if npc_system != null and npc_system.has_method("complete_deposit_interaction") else false

func _complete_station_use(entry: Dictionary, action: String) -> bool:
	return bool(npc_system.call("complete_station_use", entry, action)) if npc_system != null and npc_system.has_method("complete_station_use") else false

func _npc_inventory_count(entry: Dictionary, item_id: String) -> int:
	return int(npc_system.call("npc_inventory_count", entry, item_id)) if npc_system != null and npc_system.has_method("npc_inventory_count") else int((entry.get("personalInventory", {}) as Dictionary).get(item_id, 0))

func _npc_inventory_add(entry: Dictionary, item_id: String, amount: int) -> void:
	if npc_system != null and npc_system.has_method("npc_inventory_add"):
		npc_system.call("npc_inventory_add", entry, item_id, amount)
		return
	var personal_inventory: Dictionary = entry.get("personalInventory", {})
	var new_count := maxi(0, int(personal_inventory.get(item_id, 0)) + amount)
	if new_count <= 0:
		personal_inventory.erase(item_id)
	else:
		personal_inventory[item_id] = new_count
	entry["personalInventory"] = personal_inventory

func _increment_npc_system_counter(counter_name: String) -> void:
	if npc_system == null:
		return
	npc_system.set(counter_name, int(npc_system.get(counter_name)) + 1)

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
