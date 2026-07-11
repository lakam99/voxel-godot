extends RefCounted
class_name NpcPlanExecutor

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const HomeInteriorServiceScript := preload("res://scripts/npc_ai/behavior/HomeInteriorService.gd")
const NpcRouteStateStoreScript := preload("res://scripts/npc_ai/routing/NpcRouteStateStore.gd")
const CollisionBackedRouteSubstrateScript := preload("res://scripts/npc_ai/routing/CollisionBackedRouteSubstrate.gd")
const NpcRouteLeaseExecutorScript := preload("res://scripts/npc_ai/movement/NpcRouteLeaseExecutor.gd")

const HOME_V2_ROUTE_MAX_EXPANSIONS := 8192
const HOME_V2_WAYPOINT_RADIUS := 0.28
const ROUTINE_V2_ROUTE_MAX_EXPANSIONS := 8192
const ROUTINE_V2_WAYPOINT_RADIUS := 0.32
const V2_ROUTE_EXPANSIONS_PER_CALL := 16
const V2_EXECUTION_REPAIR_RETRY_FRAMES := 1

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
var home_route_substrate = null
var home_route_executor = null
var home_route_world = null
var home_route_authority = null

const JOB_SELECTIONS_PER_FRAME := 1
const JOB_SELECTION_DEFERRED_FRAME_LIMIT := 12
const GUARD_TARGET_REFRESHES_PER_FRAME := 1
const FORAGE_PENDING_ROUTE_TIMEOUT_SECONDS := 4.0
const FORAGE_PENDING_ROUTE_FAILURE_LIMIT := 2
const FORAGE_DYNAMIC_REPAIR_LIMIT := 1

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
	if _guard_needs_departure_stage(entry, body, target):
		return _advance_guard_departure_stage(entry, body, delta)
	var move_start: int = performance_monitor().begin_section("npc_guard_move") if performance_monitor() != null else Time.get_ticks_usec()
	entry["guardRouteCritical"] = true
	var speed := _set_motion_speed_mode(entry, "walking", "guard_route")
	var semantic_kind := "interaction_target" if target_hostile != null else "guard_post"
	var route_result := _execute_routine_route_v2(entry, body, delta, speed, "guard", target, semantic_kind, true, int(entry.get("routePriority", 130)), "guard_route")
	entry.erase("guardRouteCritical")
	if performance_monitor() != null:
		performance_monitor().end_section("npc_guard_move", move_start)
	entry["lastMoveDistance"] = float(route_result.get("moved", 0.0))
	entry["guardDutyState"] = "intercept_threat" if target_hostile != null else "patrol"
	body.set_meta("npc_guard_duty_state", entry["guardDutyState"])
	return _motion_result(entry, "guard", "guard_route")

func _guard_needs_departure_stage(entry: Dictionary, body: Node3D, target: Vector3) -> bool:
	if body == null:
		return false
	if _inside_home_now(entry, body) or _inside_home_bounds_now(entry, body.global_position):
		return not _inside_home_bounds_now(entry, target)
	return _near_home_exit_needs_clearance(entry, body)

func _advance_guard_departure_stage(entry: Dictionary, body: Node3D, delta: float) -> Dictionary:
	var target := _home_exit_stage_target(entry, body)
	entry["routePriority"] = maxi(int(entry.get("routePriority", 0)), 170)
	var speed := _set_motion_speed_mode(entry, "walking", "guard_home_exit")
	var route_result := _execute_routine_route_v2(entry, body, delta, speed, "guard", target, "home_departure_clearance", true, int(entry.get("routePriority", 170)), "guard_departure_home_exit")
	entry["lastMoveDistance"] = float(route_result.get("moved", 0.0))
	if String(route_result.get("status", route_result.get("state", ""))) == "arrived":
		_reset_route_for_replan(entry, "guard_departure_stage_complete")
	entry["guardDutyState"] = "patrol"
	body.set_meta("npc_guard_duty_state", entry["guardDutyState"])
	_clear_inside_home_if_not_semantic(entry, body)
	return _motion_result(entry, "guard", "guard_departure_home_exit")

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
		if _inside_home_now(entry, body) \
			or _inside_home_bounds_now(entry, body.global_position) \
			or _near_home_exit_needs_clearance(entry, body):
			return _advance_job_home_exit(entry, body, delta, "job_idle_home_exit")
		entry["lastMoveDistance"] = 0.0
		if phase in ["gathering", "stall"]:
			return { "advanced": true, "reason": "job_action_phase", "intentKind": "job" }
		return { "advanced": false, "reason": "job_phase_not_moving", "intentKind": "job" }
	if phase in ["outbound", "searching"] and (
		_inside_home_now(entry, body)
		or _inside_home_bounds_now(entry, body.global_position)
		or _near_home_exit_needs_clearance(entry, body)
	):
		return _advance_job_home_exit(entry, body, delta, "job_departure_home_exit")
	var target: Vector3 = entry.get("jobTarget", body.global_position)
	target = _staged_departure_motion_target(entry, body, target)
	entry["routePriority"] = 90
	var job_intent_kind := "forage" if String(entry.get("job", "")) == "forage" else "work"
	var speed := _set_motion_speed_mode(entry, "walking", "%s_route" % job_intent_kind)
	var semantic_kind := _routine_v2_semantic_for_job(entry, phase)
	var route_result := _execute_routine_route_v2(entry, body, delta, speed, job_intent_kind, target, semantic_kind, _job_route_allows_outside(entry, body), int(entry.get("routePriority", 90)), "job_route")
	if job_intent_kind == "forage" and semantic_kind == "forage_target":
		_bind_forage_reservation_to_route(entry, semantic_kind)
	entry["lastMoveDistance"] = float(route_result.get("moved", 0.0))
	_clear_inside_home_if_not_semantic(entry, body)
	return _motion_result(entry, "job", "job_route")

func _advance_job_home_exit(entry: Dictionary, body: Node3D, delta: float, reason: String) -> Dictionary:
	var target := _home_exit_stage_target(entry, body)
	entry["routePriority"] = maxi(int(entry.get("routePriority", 0)), 95)
	var job_intent_kind := "forage" if String(entry.get("job", "")) == "forage" else "work"
	var speed := _set_motion_speed_mode(entry, "walking", "job_home_exit")
	var route_result := _execute_routine_route_v2(entry, body, delta, speed, job_intent_kind, target, "home_departure_clearance", _job_route_allows_outside(entry, body), int(entry.get("routePriority", 95)), reason)
	entry["lastMoveDistance"] = float(route_result.get("moved", 0.0))
	if String(route_result.get("status", route_result.get("state", ""))) == "arrived" and not _inside_home_now(entry, body) and not _near_home_exit_needs_clearance(entry, body):
		_complete_job_departure_stage(entry, body)
	_clear_inside_home_if_not_semantic(entry, body)
	return _motion_result(entry, "job", reason)

func _complete_job_departure_stage(entry: Dictionary, body: Node3D) -> void:
	if String(entry.get("activeDoorPortalId", "")) != "" and autonomy_system != null:
		if autonomy_system.has_method("release_npc_door_hold"):
			autonomy_system.call("release_npc_door_hold", body if body != null else String(entry.get("id", "")), true)
		if autonomy_system.has_method("release_npc_traffic_reservations"):
			autonomy_system.call("release_npc_traffic_reservations", entry, "job_departure_stage_complete")
	for key in [
		"activeDoorPortalId",
		"activeDoorActorId",
		"activeDoorDirection",
		"activeDoorTrafficGroupId",
		"_activeDoorForwardStep",
		"portalRecenterTicks"
	]:
		entry.erase(key)
	_reset_route_for_replan(entry, "job_departure_stage_complete")

func _advance_idle_motion(entry: Dictionary, body: Node3D, delta: float) -> Dictionary:
	if not entry.has("dayTarget"):
		return { "advanced": false, "reason": "idle_no_anchor", "intentKind": "idle" }
	entry["routePriority"] = 35
	var target: Vector3 = entry.get("dayTarget", body.global_position)
	var speed := _set_motion_speed_mode(entry, "walking", "idle_anchor")
	var route_result := _execute_routine_route_v2(entry, body, delta, speed, "idle", target, "interaction_target", false, int(entry.get("routePriority", 35)), "idle_anchor")
	entry["lastMoveDistance"] = float(route_result.get("moved", 0.0))
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
	elif order_kind == "go_home":
		_execute_home(entry, body, perception, delta)
	elif body.has_meta("npc_scripted_target"):
		_execute_scripted_combat_overlay(entry, body, perception)
		_execute_scripted_go_to_route_v2(entry, body, delta)
	else:
		_release_action_owned_state(entry, "scripted_order_cancelled")
		_mark_scripted_order(entry, "FAILED_TARGET_GONE", "missing_scripted_target")

func _execute_scripted_go_to_route_v2(entry: Dictionary, body: Node3D, delta: float) -> Dictionary:
	var target: Vector3 = body.get_meta("npc_scripted_target", body.global_position)
	var allow_outside := bool(body.get_meta("npc_scripted_allow_outside", true))
	var arrival_radius := float(body.get_meta("npc_scripted_arrival_radius", NpcConstantsScript.CELL_SIZE * 0.45))
	var speed_mode := _scripted_speed_mode(body)
	var speed := _set_motion_speed_mode(entry, speed_mode, "scripted_go_to")
	var priority := 210 if String(entry.get("npcSpeedMode", speed_mode)) == "sprinting" else maxi(int(entry.get("routePriority", 180)), 180)
	entry["routePriority"] = priority
	var route_result := _execute_routine_route_v2(entry, body, delta, speed, "scripted", target, "scripted_target", allow_outside, priority, "scripted_go_to")
	entry["lastMoveDistance"] = float(route_result.get("moved", 0.0))
	var state := String(route_result.get("state", route_result.get("status", "")))
	if state == "arrived" or body.global_position.distance_to(target) <= arrival_radius:
		body.set_meta("npc_scripted_arrived", true)
		entry.erase("scriptedRouteBlockedTime")
		_mark_scripted_order(entry, "ARRIVED", "target_reached")
		if not bool(body.get_meta("npc_scripted_hold_on_arrival", true)):
			body.remove_meta("npc_scripted_target")
			entry.erase("activeMotionGoal")
			entry.erase("activeMotionPlan")
	elif state in ["unreachable_static", "invalid_goal", "cancelled"]:
		_mark_scripted_order(entry, "FAILED_BLOCKED", String(route_result.get("reason", state)))
	else:
		_mark_scripted_order(entry, "ACTIVE", "go_to")
	return route_result

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
		_finish_home_v2_arrival_if_needed(entry, "home_interior_reached")
		NpcRouteStateStoreScript.write_status(entry, "arrived", "", "NpcPlanExecutor.home_inside")
		entry["pathWaypoints"] = []
		entry["routeCells"] = []
		entry["routeActions"] = {}
		entry["routeMovingHome"] = false
		if _scripted_order_kind(body, entry) == "go_home":
			_mark_scripted_order(entry, "ARRIVED", "home_interior_reached")
		return
	entry["homeReturnTime"] = float(entry.get("homeReturnTime", 0.0)) + delta
	entry["routePriority"] = 140
	var speed_mode := _scripted_speed_mode(body) if _scripted_order_kind(body, entry) == "go_home" else "walking"
	var speed := _set_motion_speed_mode(entry, speed_mode, "home_route")
	var home_result := _execute_home_route_v2(entry, body, delta, speed)
	entry["lastMoveDistance"] = float(home_result.get("moved", 0.0))
	if npc_system.has_method("settle_home_if_reached"):
		npc_system.call("settle_home_if_reached", entry)
	_invalidate_stale_home_arrival(entry, body)
	if _scripted_order_kind(body, entry) == "go_home":
		if bool(entry.get("insideHome", false)):
			_mark_scripted_order(entry, "ARRIVED", "home_interior_reached")
		elif _home_v2_result_is_terminal_failure(home_result):
			_mark_scripted_order(entry, "FAILED_BLOCKED", String(home_result.get("reason", "home_route_failed")))
		else:
			_mark_scripted_order(entry, "ACTIVE", "go_home")
	if _home_v2_result_is_terminal_failure(home_result) and _home_v2_terminal_recovery_needed(entry, home_result):
		recovery_policy.mark_home_blocked(entry, String(home_result.get("reason", "home_route_failed")))

func _execute_home_route_v2(entry: Dictionary, body: Node3D, delta: float, speed: float) -> Dictionary:
	var components := _ensure_home_v2_components()
	if not bool(components.get("ok", false)):
		var missing_reason := String(components.get("reason", "home_v2_unavailable"))
		NpcRouteStateStoreScript.write_status(entry, "pending", missing_reason, "NpcPlanExecutor.home_v2_missing_components")
		return { "ok": false, "status": "pending", "state": "pending_nav_data", "reason": missing_reason, "moved": 0.0 }
	if not (body is CharacterBody3D):
		NpcRouteStateStoreScript.write_status(entry, "pending", "home_v2_missing_character_body", "NpcPlanExecutor.home_v2_missing_body")
		return { "ok": false, "status": "pending", "state": "pending_nav_data", "reason": "home_v2_missing_character_body", "moved": 0.0 }
	var authority = components.get("authority")
	var substrate = components.get("substrate")
	var executor = components.get("executor")
	var world = components.get("world")
	var active := _home_v2_active_summary(authority, entry)
	var state := String(active.get("state", "none"))
	if state in ["ready", "moving"]:
		if _home_v2_repair_replan_due(entry):
			_cancel_home_v2_request(authority, entry, "home_execution_repair_replan")
			return _plan_and_commit_home_v2_route(entry, body, authority, substrate, world, {}, delta, speed)
		return _execute_home_v2_lease(entry, body, authority, executor, active, delta, speed)
	if state == "probing" and entry.get("_homeRouteV2Route", {}) is Dictionary:
		var authority_route: Dictionary = active.get("route", {}) if active.get("route", {}) is Dictionary else {}
		var stored_route: Dictionary = authority_route if not authority_route.is_empty() else entry.get("_homeRouteV2Route", {})
		var stored_intent: Dictionary = entry.get("_homeRouteV2Intent", {}) if entry.get("_homeRouteV2Intent", {}) is Dictionary else _home_v2_intent(entry, [])
		var probe_start_cell := _home_v2_world_cell(world, body.global_position)
		var probe_candidate_cells := _home_v2_candidate_cells(entry, probe_start_cell, world)
		var probe_options := _v2_probe_repair_commit_options(substrate, probe_start_cell, probe_candidate_cells, _home_v2_plan_options(body.global_position))
		var probe_result: Dictionary = authority.commit_route_after_probe(entry, String(active.get("requestId", "")), stored_route, stored_intent, probe_options)
		_update_v2_stored_route_from_authority(entry, "_homeRouteV2Route", probe_result)
		entry["homeRouteV2LastAuthority"] = probe_result
		if String(probe_result.get("state", "")) in ["ready", "moving"]:
			return _execute_home_v2_lease(entry, body, authority, executor, probe_result, delta, speed)
		return _home_v2_pending_or_failure_result(probe_result)
	if state in ["queued", "pending_nav_data", "pending_budget"]:
		return _plan_and_commit_home_v2_route(entry, body, authority, substrate, world, active, delta, speed)
	if state == "blocked_dynamic":
		if not _home_v2_dynamic_retry_due(entry):
			return { "ok": false, "status": state, "state": state, "reason": String(active.get("reason", state)), "moved": 0.0, "authority": active }
		entry.erase("homeRouteV2RequestId")
	if state in ["unreachable_static", "invalid_goal", "arrived", "cancelled"]:
		if not bool(entry.get("routeForceReplan", false)):
			return { "ok": false, "status": state, "state": state, "reason": String(active.get("reason", state)), "moved": 0.0 }
		entry.erase("homeRouteV2RequestId")
	return _plan_and_commit_home_v2_route(entry, body, authority, substrate, world, {}, delta, speed)


func _plan_and_commit_home_v2_route(entry: Dictionary, body: Node3D, authority, substrate, world, active: Dictionary, _delta: float, speed: float) -> Dictionary:
	var start_cell := _home_v2_world_cell(world, body.global_position)
	var candidate_cells := _home_v2_candidate_cells(entry, start_cell, world)
	if candidate_cells.is_empty():
		var invalid_request := _home_v2_request(authority, entry, "home_v2_no_strict_interior_candidates")
		var invalid_result: Dictionary = authority.report_invalid_goal(String(invalid_request.get("requestId", "")), "home_v2_no_strict_interior_candidates")
		entry["homeRouteV2LastAuthority"] = invalid_result
		return _home_v2_pending_or_failure_result(invalid_result)
	var request := active
	if request.is_empty() or String(request.get("requestId", "")) == "":
		request = _home_v2_request(authority, entry, "home_route")
	var request_id := String(request.get("requestId", ""))
	var planning_budget := _claim_v2_planning_budget(authority, request_id, "home_route_plan")
	if not bool(planning_budget.get("granted", planning_budget.get("ok", false))):
		entry["homeRouteV2LastAuthority"] = planning_budget
		return _home_v2_pending_or_failure_result(planning_budget)
	var intent := _home_v2_intent(entry, candidate_cells)
	entry["_homeRouteV2Intent"] = intent.duplicate(true)
	var plan_options := _home_v2_plan_options(body.global_position)
	var route: Dictionary = substrate.plan_route(entry, start_cell, candidate_cells, plan_options)
	entry["homeRouteV2LastPlan"] = _home_v2_route_debug(route)
	if not bool(route.get("ok", false)):
		var failure := _apply_home_v2_route_failure(authority, request_id, route)
		entry["homeRouteV2LastAuthority"] = failure
		return _home_v2_pending_or_failure_result(failure)
	entry["_homeRouteV2Route"] = route.duplicate(true)
	entry["routeForceReplan"] = false
	var commit_options := _v2_probe_repair_commit_options(substrate, start_cell, candidate_cells, plan_options)
	var commit: Dictionary = authority.commit_route_after_probe(entry, request_id, route, intent, commit_options)
	_update_v2_stored_route_from_authority(entry, "_homeRouteV2Route", commit)
	entry["homeRouteV2LastAuthority"] = commit
	if String(commit.get("state", "")) in ["ready", "moving"]:
		return _execute_home_v2_lease(entry, body, authority, home_route_executor, commit, _delta, speed)
	return _home_v2_pending_or_failure_result(commit)


func _execute_home_v2_lease(entry: Dictionary, body: Node3D, authority, executor, summary: Dictionary, delta: float, speed: float) -> Dictionary:
	var request_id := String(summary.get("requestId", entry.get("homeRouteV2RequestId", "")))
	var lease: Dictionary = summary.get("routeLease", {}) if summary.get("routeLease", {}) is Dictionary else {}
	if lease.is_empty():
		var refreshed: Dictionary = authority.runtime_for_entry(entry)
		lease = refreshed.get("routeLease", {}) if refreshed.get("routeLease", {}) is Dictionary else {}
	if lease.is_empty():
		return { "ok": false, "status": "pending", "state": "pending_budget", "reason": "home_v2_missing_lease", "moved": 0.0 }
	var execution: Dictionary = executor.execute(entry, request_id, lease, delta, {
		"speed": speed,
		"waypointRadius": HOME_V2_WAYPOINT_RADIUS,
		"deferArrivalReport": true,
		"allowDoorStageMotion": true,
		"intentKind": "home",
		"semanticKind": "home_interior",
		"movingHome": true
	})
	entry["homeRouteV2LastExecution"] = execution
	if String(execution.get("status", "")) == "route_complete":
		if npc_system != null and npc_system.has_method("settle_home_if_reached"):
			npc_system.call("settle_home_if_reached", entry)
		if bool(entry.get("insideHome", false)):
			var arrived: Dictionary = authority.report_arrived(request_id, "home_interior_reached")
			_clear_home_v2_route_state(entry)
			return { "ok": true, "status": "arrived", "state": "arrived", "reason": "home_interior_reached", "moved": float(execution.get("moved", 0.0)), "authority": arrived }
		var strict_status := _home_interior_status(entry, body.global_position)
		var reason := "home_route_complete_not_strict_inside:%s" % String(strict_status.get("reason", "not_inside"))
		var failed: Dictionary = authority.report_unreachable_static(request_id, reason)
		entry["homeRouteV2StrictFailure"] = strict_status
		return { "ok": false, "status": "unreachable_static", "state": "unreachable_static", "reason": reason, "moved": float(execution.get("moved", 0.0)), "authority": failed }
	if not bool(execution.get("ok", false)) and String(execution.get("reason", "")) in ["unexpected_collision", "stuck", "door_stage_blocked"]:
		entry["homeRouteV2RetryAfterFrame"] = Engine.get_physics_frames() + V2_EXECUTION_REPAIR_RETRY_FRAMES
		_report_v2_route_repair(authority, request_id, "home_execution_repair_pending", execution)
	return execution


func _home_v2_request(authority, entry: Dictionary, reason: String) -> Dictionary:
	var intent := _home_v2_intent(entry, [])
	var request: Dictionary = authority.submit_request(entry, intent, { "priority": 140 })
	entry["homeRouteV2RequestId"] = String(request.get("requestId", ""))
	entry["homeRouteV2RequestReason"] = reason
	return request


func _apply_home_v2_route_failure(authority, request_id: String, route: Dictionary) -> Dictionary:
	var classification := String(route.get("classification", route.get("status", "")))
	var reason := String(route.get("reason", classification))
	if classification == "pending_nav_data":
		return authority.mark_pending_nav_data(request_id, reason)
	if classification == "pending_budget":
		return authority.mark_pending_budget(request_id, reason)
	if classification == "blocked_dynamic":
		return authority.report_blocked_dynamic(request_id, reason)
	if classification == "invalid_goal":
		return authority.report_invalid_goal(request_id, reason)
	return authority.report_unreachable_static(request_id, reason)


func _claim_v2_planning_budget(authority, request_id: String, reason: String) -> Dictionary:
	if authority != null and authority.has_method("claim_planning_budget"):
		return authority.claim_planning_budget(request_id, reason)
	return { "ok": true, "granted": true, "requestId": request_id, "state": "queued", "reason": reason }


func _report_v2_route_repair(authority, request_id: String, reason: String, details := {}) -> void:
	if request_id == "" or authority == null or not authority.has_method("report_route_repair"):
		return
	authority.report_route_repair(request_id, reason, details)


func _home_v2_pending_or_failure_result(summary: Dictionary) -> Dictionary:
	var state := String(summary.get("state", summary.get("status", "")))
	return {
		"ok": state in ["ready", "moving", "arrived"],
		"status": state,
		"state": state,
		"reason": String(summary.get("reason", "")),
		"moved": 0.0,
		"authority": summary
	}


func _finish_home_v2_arrival_if_needed(entry: Dictionary, reason: String) -> void:
	var request_id := String(entry.get("homeRouteV2RequestId", ""))
	if request_id == "":
		return
	var components := _ensure_home_v2_components()
	if not bool(components.get("ok", false)):
		return
	var authority = components.get("authority")
	if authority != null and authority.has_method("report_arrived"):
		var active := _home_v2_active_summary(authority, entry)
		var state := String(active.get("state", ""))
		if state in ["queued", "pending_nav_data", "pending_budget", "probing", "ready", "moving"]:
			entry["homeRouteV2LastAuthority"] = authority.report_arrived(request_id, reason)
	_clear_home_v2_route_state(entry)


func _home_v2_active_summary(authority, entry: Dictionary) -> Dictionary:
	if authority == null or not authority.has_method("runtime_for_entry"):
		return {}
	var request_id := String(entry.get("homeRouteV2RequestId", ""))
	if request_id == "":
		return {}
	var debug: Dictionary = authority.runtime_for_entry(entry)
	if String(debug.get("requestId", "")) != request_id:
		return {}
	return debug


func _ensure_home_v2_components() -> Dictionary:
	if autonomy_system == null:
		return { "ok": false, "reason": "missing_autonomy_system" }
	var authority = autonomy_system.get("route_authority_v2")
	if authority == null:
		return { "ok": false, "reason": "missing_route_authority_v2" }
	var world = autonomy_system.call("generated_navigation_adapter") if autonomy_system.has_method("generated_navigation_adapter") else null
	if world == null:
		return { "ok": false, "reason": "missing_generated_navigation_adapter" }
	if home_route_substrate == null or home_route_world != world:
		home_route_substrate = CollisionBackedRouteSubstrateScript.new()
		home_route_substrate.setup(world)
		home_route_world = world
	if home_route_executor == null or home_route_authority != authority:
		home_route_executor = NpcRouteLeaseExecutorScript.new()
		home_route_executor.setup(authority, main, npc_system)
		home_route_authority = authority
	return {
		"ok": true,
		"authority": authority,
		"substrate": home_route_substrate,
		"executor": home_route_executor,
		"world": world
	}


func _home_v2_candidate_cells(entry: Dictionary, start_cell: Vector2i, world = null) -> Array:
	var result: Array = []
	var rejected: Array = []
	var min_cell: Vector2i = entry.get("interiorMinCell", entry.get("homeCell", start_cell))
	var max_cell: Vector2i = entry.get("interiorMaxCell", entry.get("homeCell", start_cell))
	for z in range(mini(min_cell.y, max_cell.y), maxi(min_cell.y, max_cell.y) + 1):
		for x in range(mini(min_cell.x, max_cell.x), maxi(min_cell.x, max_cell.x) + 1):
			var cell := Vector2i(x, z)
			if not HomeInteriorServiceScript.cell_inside_home_bounds(entry, cell, true):
				continue
			var pose := _home_v2_cell_position(world, cell)
			var status := _home_v2_strict_arrival_pose_status(entry, pose, HOME_V2_WAYPOINT_RADIUS)
			if bool(status.get("ok", false)):
				result.append(cell)
			else:
				rejected.append({
					"cell": cell,
					"reason": String(status.get("reason", "not_strict_inside"))
				})
	var deep_candidates: Array = []
	for cell in result:
		if _home_v2_door_clearance_bucket(entry, cell) == 0:
			deep_candidates.append(cell)
	if not deep_candidates.is_empty():
		for cell in result:
			if not deep_candidates.has(cell):
				rejected.append({
					"cell": cell,
					"reason": "shallower_than_available_clearance_terminal"
				})
		result = deep_candidates
	entry["homeRouteV2RejectedGoalCells"] = rejected
	result.sort_custom(func(a, b):
		var a_bucket := _home_v2_door_clearance_bucket(entry, a)
		var b_bucket := _home_v2_door_clearance_bucket(entry, b)
		if a_bucket != b_bucket:
			return a_bucket < b_bucket
		return _cell_distance(a, start_cell) < _cell_distance(b, start_cell)
	)
	return result


func _home_v2_door_clearance_bucket(entry: Dictionary, cell: Vector2i) -> int:
	var depth := _home_v2_depth_past_door(entry, cell)
	if depth >= 2:
		return 0
	if depth >= 1:
		return 1
	return 2


func _home_v2_depth_past_door(entry: Dictionary, cell: Vector2i) -> int:
	var door_cell := HomeInteriorServiceScript.door_cell_for_entry(entry)
	var inward := HomeInteriorServiceScript.inward_direction_for_entry(entry)
	if not HomeInteriorServiceScript.is_valid_cell(door_cell) or inward == Vector2i.ZERO:
		return 999
	var door_to_cell := cell - door_cell
	return door_to_cell.x * inward.x + door_to_cell.y * inward.y


func _home_v2_strict_arrival_pose_status(entry: Dictionary, pose: Vector3, arrival_radius: float) -> Dictionary:
	var radius := maxf(0.0, arrival_radius)
	var samples: Array[Vector3] = [
		Vector3.ZERO,
		Vector3(radius, 0.0, 0.0),
		Vector3(-radius, 0.0, 0.0),
		Vector3(0.0, 0.0, radius),
		Vector3(0.0, 0.0, -radius)
	]
	for offset: Vector3 in samples:
		var sample_position: Vector3 = pose + offset
		var status := _home_interior_status(entry, sample_position)
		if not bool(status.get("strictInside", false)):
			return {
				"ok": false,
				"reason": String(status.get("reason", "not_strict_inside")),
				"sampleOffset": offset,
				"status": status
			}
	return {
		"ok": true,
		"reason": "strict_arrival_pose",
		"arrivalRadius": radius
	}


func _home_v2_intent(entry: Dictionary, candidate_cells: Array) -> Dictionary:
	var target_cell: Vector2i = candidate_cells[0] if not candidate_cells.is_empty() and candidate_cells[0] is Vector2i else entry.get("homeCell", Vector2i.ZERO)
	return {
		"kind": "home",
		"movingHome": true,
		"allowOutside": false,
		"priority": 140,
		"target": entry.get("homePosition", Vector3.ZERO),
		"targetCell": target_cell,
		"candidateCells": candidate_cells.duplicate()
	}


func _home_v2_plan_options(start_position: Vector3) -> Dictionary:
	return {
		"allowOutside": false,
		"movingHome": true,
		"ignoreDynamic": false,
		"startPosition": start_position,
		"maxExpansions": HOME_V2_ROUTE_MAX_EXPANSIONS,
		"expansionsPerCall": V2_ROUTE_EXPANSIONS_PER_CALL
	}


func _routine_v2_plan_options(allow_outside: bool, semantic_kind: String, start_position: Vector3) -> Dictionary:
	return {
		"allowOutside": allow_outside,
		"movingHome": semantic_kind == "home_interior",
		"ignoreDynamic": false,
		"semanticKind": semantic_kind,
		"startPosition": start_position,
		"maxExpansions": ROUTINE_V2_ROUTE_MAX_EXPANSIONS,
		"expansionsPerCall": V2_ROUTE_EXPANSIONS_PER_CALL
	}


func _v2_probe_repair_commit_options(substrate, start_cell: Vector2i, candidate_cells: Array, plan_options: Dictionary) -> Dictionary:
	return {
		"repairSubstrate": substrate,
		"repairStartCell": start_cell,
		"repairCandidateCells": candidate_cells.duplicate(),
		"repairPlanOptions": plan_options.duplicate(true),
		"maxProbeRepairAttempts": 3
	}


func _update_v2_stored_route_from_authority(entry: Dictionary, key: String, summary: Dictionary) -> void:
	var route: Dictionary = summary.get("route", {}) if summary.get("route", {}) is Dictionary else {}
	if route.is_empty() or not bool(route.get("ok", false)):
		return
	entry[key] = route.duplicate(true)


func _home_v2_world_cell(world, position: Vector3) -> Vector2i:
	if world != null and world.has_method("world_cell"):
		return world.call("world_cell", position)
	return _flat_cell_for_position(position)


func _home_v2_cell_position(world, cell: Vector2i) -> Vector3:
	if world != null and world.has_method("cell_position"):
		var position = world.call("cell_position", cell)
		if position is Vector3:
			return position
	return Vector3(float(cell.x) * NpcConstantsScript.CELL_SIZE, 0.0, float(cell.y) * NpcConstantsScript.CELL_SIZE)


func _home_v2_dynamic_retry_due(entry: Dictionary) -> bool:
	var retry_after := int(entry.get("homeRouteV2RetryAfterFrame", 0))
	return retry_after <= 0 or Engine.get_physics_frames() >= retry_after


func _home_v2_repair_replan_due(entry: Dictionary) -> bool:
	var retry_after := int(entry.get("homeRouteV2RetryAfterFrame", 0))
	return retry_after > 0 and Engine.get_physics_frames() >= retry_after


func _home_v2_result_is_terminal_failure(result: Dictionary) -> bool:
	var state := String(result.get("state", result.get("status", "")))
	return state in ["unreachable_static", "invalid_goal", "blocked", "unreachable"]


func _home_v2_terminal_recovery_needed(entry: Dictionary, result: Dictionary) -> bool:
	var authority: Dictionary = result.get("authority", {}) if result.get("authority", {}) is Dictionary else {}
	var request_id := String(authority.get("requestId", entry.get("homeRouteV2RequestId", "")))
	if request_id == "":
		request_id = String(entry.get("homeRouteV2RequestId", ""))
	if request_id != "" and String(entry.get("homeRouteV2RecoveryMarkedRequestId", "")) == request_id:
		return false
	entry["homeRouteV2RecoveryMarkedRequestId"] = request_id
	return true


func _home_v2_route_debug(route: Dictionary) -> Dictionary:
	var proof: Dictionary = route.get("proof", {}) if route.get("proof", {}) is Dictionary else {}
	var blocked: Array = proof.get("blocked", []) if proof.get("blocked", []) is Array else []
	return {
		"ok": bool(route.get("ok", false)),
		"status": String(route.get("status", "")),
		"classification": String(route.get("classification", "")),
		"reason": String(route.get("reason", "")),
		"cellCount": (route.get("cells", []) as Array).size() if route.get("cells", []) is Array else 0,
		"waypointCount": (route.get("waypoints", []) as Array).size() if route.get("waypoints", []) is Array else 0,
		"actionCount": (route.get("actions", {}) as Dictionary).size() if route.get("actions", {}) is Dictionary else 0,
		"targetCell": route.get("targetCell", Vector2i(999999, 999999)),
		"source": String(route.get("source", "")),
		"acceptedGoals": proof.get("acceptedGoals", []),
		"rejectedGoals": proof.get("rejectedGoals", []),
		"visitedCount": (route.get("visited", []) as Array).size() if route.get("visited", []) is Array else 0,
		"totalVisitedCount": int(proof.get("visitedCount", 0)),
		"expansions": int(proof.get("expansions", 0)),
		"blockedCount": blocked.size(),
		"blockedSample": blocked.slice(0, mini(blocked.size(), 8)),
		"doorEdges": proof.get("doorEdges", []),
		"exploredDoorEdges": proof.get("exploredDoorEdges", [])
	}


func _execute_routine_route_v2(entry: Dictionary, body: Node3D, delta: float, speed: float, intent_kind: String, target: Vector3, semantic_kind: String, allow_outside: bool, priority: int, reason: String) -> Dictionary:
	var components := _ensure_home_v2_components()
	if not bool(components.get("ok", false)):
		var missing_reason := String(components.get("reason", "routine_v2_unavailable"))
		NpcRouteStateStoreScript.write_status(entry, "pending", missing_reason, "NpcPlanExecutor.routine_v2_missing_components")
		return { "ok": false, "status": "pending", "state": "pending_nav_data", "reason": missing_reason, "moved": 0.0 }
	if not (body is CharacterBody3D):
		NpcRouteStateStoreScript.write_status(entry, "pending", "routine_v2_missing_character_body", "NpcPlanExecutor.routine_v2_missing_body")
		return { "ok": false, "status": "pending", "state": "pending_nav_data", "reason": "routine_v2_missing_character_body", "moved": 0.0 }
	entry["routineRouteV2IntentKind"] = intent_kind
	entry["routineRouteV2SemanticKind"] = semantic_kind
	var authority = components.get("authority")
	var substrate = components.get("substrate")
	var executor = components.get("executor")
	var world = components.get("world")
	var target_cell := _home_v2_world_cell(world, target)
	var route_key := _routine_v2_route_key(entry, intent_kind, semantic_kind, target_cell, allow_outside, reason)
	var active := _routine_v2_active_summary(authority, entry, route_key)
	var state := String(active.get("state", "none"))
	if bool(entry.get("routeForceReplan", false)):
		entry["routeForceReplan"] = false
		var forage_terminal_handoff := intent_kind == "forage" \
			and semantic_kind == "forage_target" \
			and state in ["blocked_dynamic", "unreachable_static", "invalid_goal", "arrived"]
		if not (state in ["queued", "pending_nav_data", "pending_budget", "probing"]) and not forage_terminal_handoff:
			_cancel_routine_v2_request(authority, entry, "route_force_replan")
			active = {}
			state = "none"
	if state in ["ready", "moving"]:
		if _routine_v2_repair_replan_due(entry):
			_cancel_routine_v2_request(authority, entry, "routine_execution_repair_replan")
			return _plan_and_commit_routine_v2_route(entry, body, authority, substrate, world, {}, delta, speed, intent_kind, target, semantic_kind, allow_outside, priority, reason, route_key)
		return _execute_routine_v2_lease(entry, body, authority, executor, active, delta, speed, intent_kind, semantic_kind)
	if state == "probing" and entry.get("_routineRouteV2Route", {}) is Dictionary and String(entry.get("routineRouteV2Key", "")) == route_key:
		var authority_route: Dictionary = active.get("route", {}) if active.get("route", {}) is Dictionary else {}
		var stored_route: Dictionary = authority_route if not authority_route.is_empty() else entry.get("_routineRouteV2Route", {})
		var stored_intent: Dictionary = entry.get("_routineRouteV2Intent", {}) if entry.get("_routineRouteV2Intent", {}) is Dictionary else _routine_v2_intent(entry, intent_kind, semantic_kind, target, target_cell, [], allow_outside, priority, reason)
		var probe_start_cell := _home_v2_world_cell(world, body.global_position)
		var probe_candidate_cells: Array = stored_intent.get("candidateCells", []) if stored_intent.get("candidateCells", []) is Array else []
		var probe_options := _v2_probe_repair_commit_options(substrate, probe_start_cell, probe_candidate_cells, _routine_v2_plan_options(allow_outside, semantic_kind, body.global_position))
		var probe_result: Dictionary = authority.commit_route_after_probe(entry, String(active.get("requestId", "")), stored_route, stored_intent, probe_options)
		_update_v2_stored_route_from_authority(entry, "_routineRouteV2Route", probe_result)
		entry["routineRouteV2LastAuthority"] = probe_result
		if String(probe_result.get("state", "")) in ["ready", "moving"]:
			return _execute_routine_v2_lease(entry, body, authority, executor, probe_result, delta, speed, intent_kind, semantic_kind)
		return _routine_v2_pending_or_failure_result(probe_result)
	if state in ["queued", "pending_nav_data", "pending_budget"]:
		return _plan_and_commit_routine_v2_route(entry, body, authority, substrate, world, active, delta, speed, intent_kind, target, semantic_kind, allow_outside, priority, reason, route_key)
	if state == "blocked_dynamic":
		if intent_kind == "forage" and semantic_kind == "forage_target":
			return { "ok": false, "status": state, "state": state, "reason": String(active.get("reason", state)), "moved": 0.0, "authority": active }
		if not _routine_v2_dynamic_retry_due(entry):
			return { "ok": false, "status": state, "state": state, "reason": String(active.get("reason", state)), "moved": 0.0, "authority": active }
		_cancel_routine_v2_request(authority, entry, "blocked_dynamic_retry")
	if state in ["unreachable_static", "invalid_goal", "arrived", "cancelled"]:
		if not bool(entry.get("routeForceReplan", false)) and String(entry.get("routineRouteV2Key", "")) == route_key:
			return { "ok": state == "arrived", "status": state, "state": state, "reason": String(active.get("reason", state)), "moved": 0.0, "authority": active }
		_cancel_routine_v2_request(authority, entry, "routine_target_changed")
	return _plan_and_commit_routine_v2_route(entry, body, authority, substrate, world, {}, delta, speed, intent_kind, target, semantic_kind, allow_outside, priority, reason, route_key)


func _plan_and_commit_routine_v2_route(entry: Dictionary, body: Node3D, authority, substrate, world, active: Dictionary, _delta: float, speed: float, intent_kind: String, target: Vector3, semantic_kind: String, allow_outside: bool, priority: int, reason: String, route_key: String) -> Dictionary:
	var start_cell := _home_v2_world_cell(world, body.global_position)
	var target_cell := _home_v2_world_cell(world, target)
	var target_data := _routine_v2_target_data(entry, target, target_cell, semantic_kind)
	var moving_home := semantic_kind == "home_interior"
	var request := active
	if request.is_empty() or String(request.get("requestId", "")) == "":
		request = _routine_v2_request(authority, entry, intent_kind, semantic_kind, target, target_cell, [], allow_outside, priority, reason, route_key)
	var request_id := String(request.get("requestId", ""))
	var planning_budget := _claim_v2_planning_budget(authority, request_id, "routine_route_plan")
	if not bool(planning_budget.get("granted", planning_budget.get("ok", false))):
		entry["routineRouteV2LastAuthority"] = planning_budget
		return _routine_v2_pending_or_failure_result(planning_budget)
	var candidates_result: Dictionary = substrate.candidate_poses_for_target(entry, target_data, semantic_kind, {
		"allowOutside": allow_outside,
		"movingHome": moving_home
	})
	entry["routineRouteV2LastCandidates"] = candidates_result
	var candidate_cells := _routine_v2_candidate_cells(candidates_result)
	if candidate_cells.is_empty():
		var invalid_result: Dictionary = authority.report_invalid_goal(request_id, String(candidates_result.get("reason", "no_routeable_candidate_pose")))
		entry["routineRouteV2LastAuthority"] = invalid_result
		return _routine_v2_pending_or_failure_result(invalid_result)
	var intent := _routine_v2_intent(entry, intent_kind, semantic_kind, target, target_cell, candidate_cells, allow_outside, priority, reason)
	var interaction_claim: Dictionary = intent.get("interactionClaim", {}) if intent.get("interactionClaim", {}) is Dictionary else {}
	interaction_claim["routeGeneration"] = int(request.get("generation", 0))
	intent["interactionClaim"] = interaction_claim
	entry["_routineRouteV2Intent"] = intent.duplicate(true)
	var plan_options := _routine_v2_plan_options(allow_outside, semantic_kind, body.global_position)
	var route: Dictionary = substrate.plan_route(entry, start_cell, candidate_cells, plan_options)
	entry["routineRouteV2LastPlan"] = _home_v2_route_debug(route)
	if not bool(route.get("ok", false)):
		var failure := _apply_home_v2_route_failure(authority, request_id, route)
		entry["routineRouteV2LastAuthority"] = failure
		return _routine_v2_pending_or_failure_result(failure)
	route["interactionClaim"] = interaction_claim.duplicate(true)
	entry["_routineRouteV2Route"] = route.duplicate(true)
	entry["routeForceReplan"] = false
	var commit_options := _v2_probe_repair_commit_options(substrate, start_cell, candidate_cells, plan_options)
	var commit: Dictionary = authority.commit_route_after_probe(entry, request_id, route, intent, commit_options)
	_update_v2_stored_route_from_authority(entry, "_routineRouteV2Route", commit)
	entry["routineRouteV2LastAuthority"] = commit
	if String(commit.get("state", "")) in ["ready", "moving"]:
		return _execute_routine_v2_lease(entry, body, authority, home_route_executor, commit, _delta, speed, intent_kind, semantic_kind)
	return _routine_v2_pending_or_failure_result(commit)


func _execute_routine_v2_lease(entry: Dictionary, body: Node3D, authority, executor, summary: Dictionary, delta: float, speed: float, intent_kind: String, semantic_kind: String) -> Dictionary:
	var request_id := String(summary.get("requestId", entry.get("routineRouteV2RequestId", "")))
	var lease: Dictionary = summary.get("routeLease", {}) if summary.get("routeLease", {}) is Dictionary else {}
	if lease.is_empty():
		var refreshed: Dictionary = authority.runtime_for_entry(entry)
		lease = refreshed.get("routeLease", {}) if refreshed.get("routeLease", {}) is Dictionary else {}
	if lease.is_empty():
		return { "ok": false, "status": "pending", "state": "pending_budget", "reason": "routine_v2_missing_lease", "moved": 0.0 }
	var execution: Dictionary = executor.execute(entry, request_id, lease, delta, {
		"speed": speed,
		"waypointRadius": ROUTINE_V2_WAYPOINT_RADIUS,
		"deferArrivalReport": false,
		"allowDoorStageMotion": true,
		"intentKind": intent_kind,
		"semanticKind": semantic_kind,
		"movingHome": semantic_kind == "home_interior"
	})
	entry["routineRouteV2LastExecution"] = execution
	entry["routineRouteV2IntentKind"] = intent_kind
	entry["routineRouteV2SemanticKind"] = semantic_kind
	if not bool(execution.get("ok", false)) and String(execution.get("reason", "")) in ["unexpected_collision", "stuck", "door_stage_blocked"]:
		entry["routineRouteV2RetryAfterFrame"] = Engine.get_physics_frames() + V2_EXECUTION_REPAIR_RETRY_FRAMES
		_report_v2_route_repair(authority, request_id, "routine_execution_repair_pending", execution)
	return execution


func _routine_v2_request(authority, entry: Dictionary, intent_kind: String, semantic_kind: String, target: Vector3, target_cell: Vector2i, candidate_cells: Array, allow_outside: bool, priority: int, reason: String, route_key: String) -> Dictionary:
	var intent := _routine_v2_intent(entry, intent_kind, semantic_kind, target, target_cell, candidate_cells, allow_outside, priority, reason)
	var request: Dictionary = authority.submit_request(entry, intent, { "priority": priority })
	entry["routineRouteV2RequestId"] = String(request.get("requestId", ""))
	entry["routineRouteV2Key"] = route_key
	entry["routineRouteV2RequestReason"] = reason
	return request


func _routine_v2_intent(entry: Dictionary, intent_kind: String, semantic_kind: String, target: Vector3, target_cell: Vector2i, candidate_cells: Array, allow_outside: bool, priority: int, reason: String) -> Dictionary:
	var intent := {
		"kind": intent_kind,
		"semanticKind": semantic_kind,
		"movingHome": semantic_kind == "home_interior",
		"allowOutside": allow_outside,
		"priority": priority,
		"target": target,
		"targetCell": target_cell,
		"candidateCells": candidate_cells.duplicate(),
		"job": String(entry.get("job", "")),
		"jobPhase": String(entry.get("jobPhase", "")),
		"jobObjectId": String(entry.get("jobObjectId", "")),
		"reason": reason
	}
	if semantic_kind == "forage_target":
		intent["interactionClaim"] = _forage_interaction_claim(entry, target, target_cell)
	return intent

func _forage_interaction_claim(entry: Dictionary, target: Vector3, target_cell: Vector2i) -> Dictionary:
	return {
		"objectId": String(entry.get("jobObjectId", "")),
		"reservationId": String(entry.get("jobReservationId", "")),
		"slotId": String(entry.get("jobApproachSlotId", "")),
		"slotPosition": entry.get("jobApproachSlotPosition", target),
		"slotCell": entry.get("jobApproachSlotCell", target_cell),
		"routeGeneration": int(entry.get("jobReservationRouteGeneration", 0))
	}


func _routine_v2_target_data(entry: Dictionary, target: Vector3, target_cell: Vector2i, semantic_kind: String) -> Dictionary:
	var data := {
		"position": target,
		"cell": target_cell
	}
	if semantic_kind == "home_interior":
		data["interiorMinCell"] = entry.get("interiorMinCell", entry.get("homeCell", target_cell))
		data["interiorMaxCell"] = entry.get("interiorMaxCell", entry.get("homeCell", target_cell))
		data["homeCell"] = entry.get("homeCell", target_cell)
	elif semantic_kind == "home_exterior" or semantic_kind == "home_departure_clearance":
		var porch_cell: Vector2i = entry.get("porchCell", target_cell)
		data["position"] = target
		data["cell"] = target_cell
		data["porchCell"] = porch_cell if target_cell == porch_cell else CollisionBackedRouteSubstrateScript.INVALID_CELL
	elif semantic_kind == "forage_target":
		data["position"] = entry.get("jobApproachSlotPosition", target)
		data["cell"] = entry.get("jobApproachSlotCell", target_cell)
		data["exactSlotCell"] = entry.get("jobApproachSlotCell", target_cell)
		data["interactionClaim"] = _forage_interaction_claim(entry, target, target_cell)
	elif semantic_kind == "guard_post":
		data["guardCell"] = entry.get("guardCell", target_cell)
		data["guardPosition"] = entry.get("guardPosition", target)
	return data


func _routine_v2_candidate_cells(candidates_result: Dictionary) -> Array:
	var result: Array = []
	var candidates: Array = candidates_result.get("candidates", []) if candidates_result.get("candidates", []) is Array else []
	for candidate_value in candidates:
		if not (candidate_value is Dictionary):
			continue
		var cell = (candidate_value as Dictionary).get("cell", Vector2i(999999, 999999))
		if cell is Vector2i and not result.has(cell):
			result.append(cell)
	return result


func _routine_v2_active_summary(authority, entry: Dictionary, route_key: String) -> Dictionary:
	if authority == null or not authority.has_method("runtime_for_entry"):
		return {}
	if String(entry.get("routineRouteV2Key", "")) != route_key:
		_cancel_routine_v2_request(authority, entry, "routine_route_key_changed")
		return {}
	var request_id := String(entry.get("routineRouteV2RequestId", ""))
	if request_id == "":
		return {}
	var debug: Dictionary = authority.runtime_for_entry(entry)
	if String(debug.get("requestId", "")) != request_id:
		return {}
	return debug


func _cancel_routine_v2_request(authority, entry: Dictionary, reason: String) -> void:
	var request_id := String(entry.get("routineRouteV2RequestId", ""))
	if request_id != "" and authority != null and authority.has_method("cancel_request"):
		_report_v2_route_repair(authority, request_id, reason, {
			"routeKey": String(entry.get("routineRouteV2Key", ""))
		})
		authority.cancel_request(request_id, reason)
	entry.erase("routineRouteV2RequestId")
	entry.erase("routineRouteV2Key")
	entry.erase("_routineRouteV2Route")
	entry.erase("_routineRouteV2Intent")
	entry.erase("routineRouteV2RetryAfterFrame")
	entry["routeActions"] = {}
	entry["routeCells"] = []
	entry["pathWaypoints"] = []


func _cancel_home_v2_request(authority, entry: Dictionary, reason: String) -> void:
	var request_id := String(entry.get("homeRouteV2RequestId", ""))
	if request_id != "" and authority != null and authority.has_method("cancel_request"):
		_report_v2_route_repair(authority, request_id, reason, {})
		authority.cancel_request(request_id, reason)
	_clear_home_v2_route_state(entry)


func _routine_v2_pending_or_failure_result(summary: Dictionary) -> Dictionary:
	var state := String(summary.get("state", summary.get("status", "")))
	return {
		"ok": state in ["ready", "moving", "arrived"],
		"status": state,
		"state": state,
		"reason": String(summary.get("reason", "")),
		"moved": 0.0,
		"authority": summary
	}


func _routine_v2_dynamic_retry_due(entry: Dictionary) -> bool:
	var retry_after := int(entry.get("routineRouteV2RetryAfterFrame", 0))
	return retry_after <= 0 or Engine.get_physics_frames() >= retry_after


func _routine_v2_repair_replan_due(entry: Dictionary) -> bool:
	var retry_after := int(entry.get("routineRouteV2RetryAfterFrame", 0))
	return retry_after > 0 and Engine.get_physics_frames() >= retry_after


func _routine_v2_route_key(entry: Dictionary, intent_kind: String, semantic_kind: String, target_cell: Vector2i, allow_outside: bool, reason: String) -> String:
	return "%s|%s|%s|%d,%d|%s|%s|%s|%d" % [
		String(entry.get("id", "")),
		intent_kind,
		semantic_kind,
		target_cell.x,
		target_cell.y,
		str(allow_outside),
		String(entry.get("jobObjectId", "")),
		reason,
		int(entry.get("forageSearchSerial", 0))
	]


func _routine_v2_semantic_for_job(entry: Dictionary, phase: String) -> String:
	if phase == "returning":
		return "home_interior"
	if String(entry.get("job", "")) == "forage":
		return "forage_target" if _job_target_node(entry) != null else "forage_search_anchor"
	return "interaction_target" if _job_target_node(entry) != null else "work_area"


func _clear_home_v2_route_state(entry: Dictionary) -> void:
	entry.erase("_homeRouteV2Route")
	entry.erase("_homeRouteV2Intent")
	entry.erase("homeRouteV2RequestId")
	entry.erase("homeRouteV2RetryAfterFrame")
	entry["routeActions"] = {}
	entry["routeCells"] = []
	entry["pathWaypoints"] = []
	entry["routeMovingHome"] = false


func _cell_distance(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


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
	entry["guardRouteCritical"] = true
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
		NpcRouteStateStoreScript.write_status_preserving_reason(entry, "idle", "NpcPlanExecutor.job_selection_budget")
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
			NpcRouteStateStoreScript.write_status_preserving_reason(entry, "idle", "NpcPlanExecutor.job_not_moving")

func _job_allows_outside_movement(entry: Dictionary) -> bool:
	return _resource_job_uses_outside_work_area(String(entry.get("job", "")))

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
	var route_result := _execute_routine_route_v2(entry, body, delta, speed, "work", target, "home_exterior", false, int(entry.get("routePriority", 120)), "worker_outside_town_recovery")
	entry["lastMoveDistance"] = float(route_result.get("moved", 0.0))
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
	NpcRouteStateStoreScript.write_status(entry, "waiting", reason, "NpcPlanExecutor.reset_route_for_replan")
	entry["routeForceReplan"] = true
	entry["pathWaypoints"] = []
	entry["routeCells"] = []
	entry["routeActions"] = {}
	entry["routeWaitTicks"] = 0
	entry["blockedMoveTime"] = 0.0

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
	var deferred_frames := int(entry.get("jobSelectionDeferredFrames", 0))
	if job_selections_this_frame >= JOB_SELECTIONS_PER_FRAME:
		if deferred_frames < JOB_SELECTION_DEFERRED_FRAME_LIMIT:
			entry["jobTimer"] = minf(float(entry.get("jobTimer", 0.0)), 0.05)
			entry["jobSelectionDeferredFrames"] = deferred_frames + 1
			entry["jobSelectionDeferredFrame"] = frame
			return false
	job_selections_this_frame += 1
	entry["jobSelectionDeferredFrames"] = 0
	entry.erase("jobSelectionDeferredFrame")
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
			entry["routeForceReplan"] = true
			entry["jobTimer"] = _deterministic_seconds(entry, "resource_search_retry", 3.0, 7.0)
			_set_npc_goal(entry, "search for %s" % String(entry.get("jobResource", "resource")))
			body.set_meta("npc_job_phase", "searching")
			return true
		if not _reserve_job_target(entry, resource_target, "harvest_resource"):
			entry["jobPhase"] = "searching"
			entry["jobTarget"] = _choose_job_target(entry)
			entry["routeForceReplan"] = true
			entry["jobTimer"] = _deterministic_seconds(entry, "resource_reserve_search", 2.0, 4.5)
			_set_npc_goal(entry, "search for %s" % String(entry.get("jobResource", "resource")))
			body.set_meta("npc_job_phase", "searching")
			return true
		entry["jobPhase"] = "outbound"
		_clear_home_route_terminal(entry)
		_set_npc_goal(entry, "gather %s" % String(entry.get("jobResource", "resource")))
		entry["jobTimer"] = _deterministic_seconds(entry, "resource_outbound_timeout", 6.0, 12.0)
		body.set_meta("npc_job_phase", "outbound")
		return true
	if phase == "outbound":
		return _update_outbound_job(entry, body, timer)
	if phase == "searching":
		return _update_searching_resource_job(entry, body, timer)
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
	var inside_home := _inside_home_now(entry, body) or _inside_home_bounds_now(entry, body.global_position)
	if inside_home and not _inside_home_bounds_now(entry, target):
		return _home_door_exit_target(entry, body.global_position.y)
	var leaving_town := _point_inside_town(entry, body.global_position) and not _point_inside_town(entry, target)
	if leaving_town and _near_home_exit_needs_clearance(entry, body):
		return _home_exit_clearance_target(entry, body.global_position.y)
	return target

func _home_exit_stage_target(entry: Dictionary, body: Node3D) -> Vector3:
	if body == null:
		return _home_exit_clearance_target(entry, 0.0)
	if _inside_home_now(entry, body) or _inside_home_bounds_now(entry, body.global_position):
		return _home_door_exit_target(entry, body.global_position.y)
	return _home_exit_clearance_target(entry, body.global_position.y)

func _near_home_exit_needs_clearance(entry: Dictionary, body: Node3D) -> bool:
	if body == null:
		return false
	var porch_cell: Vector2i = entry.get("porchCell", entry.get("homeCell", Vector2i.ZERO))
	var current_cell := _flat_cell_for_position(body.global_position)
	var status := _home_interior_status(entry, body.global_position)
	if bool(status.get("doorThresholdOccupied", false)) \
		or bool(status.get("doorSweepOccupied", false)) \
		or bool(status.get("doorClearanceOccupied", false)):
		return true
	var status_reason := String(status.get("reason", ""))
	if status_reason in ["door_cell_not_inside", "door_clearance_not_inside", "not_past_door_plane"]:
		return true
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
	return bool(_home_interior_status(entry, position).get("strictInside", false))

func _home_interior_status(entry: Dictionary, position: Vector3) -> Dictionary:
	var portal = null
	if autonomy_system != null and autonomy_system.get("door_portals") != null:
		portal = HomeInteriorServiceScript.portal_for_entry(entry, autonomy_system.get("door_portals"))
	return HomeInteriorServiceScript.status(entry, position, portal)

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

func _home_door_exit_target(entry: Dictionary, fallback_y: float) -> Vector3:
	var porch_cell: Vector2i = entry.get("porchCell", entry.get("homeCell", Vector2i.ZERO))
	var position: Vector3 = entry.get("porchPosition", Vector3(float(porch_cell.x) * NpcConstantsScript.CELL_SIZE, fallback_y, float(porch_cell.y) * NpcConstantsScript.CELL_SIZE))
	if position == Vector3.INF:
		position = Vector3(float(porch_cell.x) * NpcConstantsScript.CELL_SIZE, fallback_y, float(porch_cell.y) * NpcConstantsScript.CELL_SIZE)
	var main_node = npc_system.get("main") if npc_system != null else null
	if main_node != null and main_node.has_method("surface_y_at_position"):
		position.y = float(main_node.call("surface_y_at_position", position)) + 0.04
	return position

func _home_exit_clearance_target(entry: Dictionary, fallback_y: float) -> Vector3:
	var porch_cell: Vector2i = entry.get("porchCell", entry.get("homeCell", Vector2i.ZERO))
	var exit_cell := _home_exit_clearance_cell(entry)
	if exit_cell == porch_cell:
		return _home_door_exit_target(entry, fallback_y)
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
		var blocked_job := String(entry.get("job", ""))
		_mark_job_resource_target_unreachable(entry, target_node, blocked_job)
		_release_job_reservation(entry, "route_blocked")
		entry["jobTargetNode"] = null
		entry["jobPhase"] = "searching"
		entry["jobTarget"] = _choose_job_target(entry)
		entry["jobTimer"] = _deterministic_seconds(entry, "resource_blocked_search", 2.0, 5.0)
		entry["routeForceReplan"] = true
		_set_npc_goal(entry, "search for %s" % String(entry.get("jobResource", "resource")))
		body.set_meta("npc_job_phase", "searching")
		return true
	var job := String(entry.get("job", ""))
	var target: Vector3 = entry.get("jobTarget", body.global_position)
	var target_inside_town := _point_inside_town(entry, target)
	var target_in_work_area := _point_inside_work_area(entry, target)
	var outside_work_area_job := _resource_job_uses_outside_work_area(job)
	if outside_work_area_job and (target_inside_town or not target_in_work_area):
		var invalid_target_reason := "resource_target_inside_town" if target_inside_town else "resource_target_outside_work_area"
		_release_job_reservation(entry, invalid_target_reason)
		entry["jobTargetNode"] = null
		entry["jobPhase"] = "idle"
		entry["jobTimer"] = 0.0
		entry["routeForceReplan"] = true
		body.set_meta("npc_job_phase", "idle")
		return true
	var route_arrived := String(entry.get("routeStatus", "")) == "arrived"
	var can_gather_at_target := (target_in_work_area and not target_inside_town) if outside_work_area_job else target_inside_town
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

func _update_searching_resource_job(entry: Dictionary, body: Node3D, timer: float) -> bool:
	var job := String(entry.get("job", ""))
	var route_blocked := String(entry.get("routeStatus", "")) == "blocked"
	var search_arrived := String(entry.get("routeStatus", "")) == "arrived" or body.global_position.distance_to(entry.get("jobTarget", body.global_position)) <= NpcConstantsScript.CELL_SIZE * 1.2
	if timer <= 0.0 or route_blocked or search_arrived:
		var resource_target := _find_job_resource_target(entry, job)
		if resource_target != null and _reserve_job_target(entry, resource_target, "harvest_resource"):
			entry["jobPhase"] = "outbound"
			entry["jobTimer"] = _deterministic_seconds(entry, "resource_outbound_timeout", 6.0, 12.0)
			entry["routeForceReplan"] = true
			_clear_home_route_terminal(entry)
			_set_npc_goal(entry, "gather %s" % String(entry.get("jobResource", "resource")))
			body.set_meta("npc_job_phase", "outbound")
			return true
		entry["jobTarget"] = _choose_job_target(entry)
		entry["jobTimer"] = _deterministic_seconds(entry, "resource_search_roam", 2.0, 5.0)
		entry["routeForceReplan"] = true
		_clear_home_route_terminal(entry)
		_set_npc_goal(entry, "search for %s" % String(entry.get("jobResource", "resource")))
	else:
		entry["jobTimer"] = timer
	body.set_meta("npc_job_phase", "searching")
	return true

func _update_gathering_job(entry: Dictionary, body: Node3D, timer: float) -> bool:
	if timer > 0.0:
		entry["jobTimer"] = timer
		body.set_meta("npc_job_phase", "gathering")
		return false
	var job := String(entry.get("job", ""))
	var inside_town := _point_inside_town(entry, body.global_position)
	var inside_work_area := _point_inside_work_area(entry, body.global_position)
	var outside_work_area_job := _resource_job_uses_outside_work_area(job)
	var invalid_resource_gather := (outside_work_area_job and (inside_town or not inside_work_area)) or (not outside_work_area_job and not inside_town)
	if invalid_resource_gather:
		var invalid_reason := "inside_town_invalid_gather" if inside_town else "outside_work_area_invalid_gather"
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
		var active_forage_intent := _entry_has_active_goal_kind(entry, NpcEnumsScript.GOAL_KIND_FORAGE)
		if timer > 0.0 and not hungry and not _inside_home_now(entry, body) and not active_forage_intent:
			entry["jobTimer"] = timer
			_set_npc_goal(entry, "rest")
			body.set_meta("npc_job_phase", "idle")
			return false
		if active_forage_intent or _point_inside_town(entry, body.global_position):
			entry["jobPhase"] = "searching"
			_advance_forage_search_serial(entry)
			entry["jobTimer"] = _deterministic_seconds(entry, "forage_depart_town_search", 3.0, 7.0)
			entry["jobTarget"] = _choose_job_target(entry)
			entry["routeForceReplan"] = true
			_clear_home_route_terminal(entry)
			_set_npc_goal(entry, "search for berries")
			body.set_meta("npc_job_phase", "searching")
			return true
		var forage := _find_forage_target(entry)
		if forage == null:
			entry["jobPhase"] = "searching"
			_advance_forage_search_serial(entry)
			entry["jobTimer"] = _deterministic_seconds(entry, "forage_search_retry", 3.0, 7.0)
			entry["jobTarget"] = _choose_job_target(entry)
			entry["routeForceReplan"] = true
			_set_npc_goal(entry, "search for berries")
			body.set_meta("npc_job_phase", "searching")
			return true
		if not _reserve_job_target(entry, forage, "harvest_resource"):
			entry["jobPhase"] = "searching"
			_advance_forage_search_serial(entry)
			entry["jobTimer"] = _deterministic_seconds(entry, "forage_reserve_retry", 2.0, 4.5)
			entry["jobTarget"] = _choose_job_target(entry)
			entry["routeForceReplan"] = true
			_set_npc_goal(entry, "search for berries")
			body.set_meta("npc_job_phase", "searching")
			return true
		entry["jobPhase"] = "outbound"
		entry["jobTimer"] = _deterministic_seconds(entry, "forage_outbound_timeout", 12.0, 22.0)
		entry["foragePendingRouteRetries"] = 0
		_clear_home_route_terminal(entry)
		_set_npc_goal(entry, "forage berries")
		body.set_meta("npc_job_phase", "outbound")
		return true
	if phase == "outbound" or phase == "searching":
		var target_node := _job_target_node(entry)
		if target_node != null and _forager_reservation_deadline_exceeded(entry):
			return _retarget_forager_after_route_failure(entry, body, target_node, "forage_reservation_deadline", false)
		var inside_town := _point_inside_town(entry, body.global_position)
		if phase == "searching" and target_node == null and timer <= 0.0:
			var forage_retry := _find_forage_target(entry) if not inside_town else null
			if forage_retry != null and _reserve_job_target(entry, forage_retry, "harvest_resource"):
				entry["jobPhase"] = "outbound"
				entry["jobTimer"] = _deterministic_seconds(entry, "forage_outbound_timeout", 12.0, 22.0)
				entry["forageRouteFailures"] = 0
				entry["foragePendingRouteRetries"] = 0
				entry["routeForceReplan"] = true
				_clear_home_route_terminal(entry)
				_set_npc_goal(entry, "forage berries")
				body.set_meta("npc_job_phase", "outbound")
				return true
			_advance_forage_search_serial(entry)
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
			entry["jobPhase"] = "searching"
			_advance_forage_search_serial(entry)
			entry["jobTarget"] = _choose_job_target(entry)
			entry["jobTimer"] = _deterministic_seconds(entry, "forage_target_gone_search", 2.0, 5.0)
			entry["routeForceReplan"] = true
			_set_npc_goal(entry, "search for berries")
			body.set_meta("npc_job_phase", "searching")
			return true
		if target_node != null and String(entry.get("jobObjectId", "")) == "":
			_reserve_job_target(entry, target_node, "harvest_resource")
		var target: Vector3 = entry.get("jobTarget", body.global_position)
		var arrival_proof := _forager_exact_arrival_proof(entry, body)
		entry["forageArrivalProof"] = arrival_proof.duplicate(true)
		if target_node != null and bool(arrival_proof.get("ok", false)):
			entry["jobPhase"] = "gathering"
			entry["jobTimer"] = _deterministic_seconds(entry, "forage_gather_duration", 0.4, 0.8)
			entry["foragePendingRouteTime"] = 0.0
			entry["foragePendingRouteRetries"] = 0
			_clear_route_for_action(entry, "forage_gathering")
			_set_npc_goal(entry, "pick berries")
			_play_npc_use(entry, "gather")
			body.set_meta("npc_job_phase", "gathering")
			return false
		var route_disposition := _forager_v2_route_disposition(entry)
		var route_action := String(route_disposition.get("action", "continue"))
		if target_node != null and route_action == "repair":
			entry["forageRouteRepairAttempts"] = int(entry.get("forageRouteRepairAttempts", 0)) + 1
			entry["jobTimer"] = _deterministic_seconds(entry, "forage_dynamic_repair", 2.0, 4.0)
			_reset_route_for_replan(entry, "forage_blocked_dynamic_repair")
			_set_npc_goal(entry, "forage berries")
			body.set_meta("npc_job_phase", "outbound")
			return true
		if target_node != null and route_action == "release":
			return _retarget_forager_after_route_failure(entry, body, target_node, String(route_disposition.get("releaseReason", "route_failed")), bool(route_disposition.get("markUnreachable", false)))
		if target_node != null and route_action == "next_slot":
			if _advance_forage_approach_slot(entry, target_node):
				entry.erase("_routineRouteV2Intent")
				entry.erase("routineRouteV2IntentKind")
				entry.erase("routineRouteV2SemanticKind")
				entry["forageRouteRepairAttempts"] = 0
				entry["routeForceReplan"] = true
				entry["jobPhase"] = "outbound"
				entry["jobTimer"] = _deterministic_seconds(entry, "forage_next_slot_route", 3.0, 6.0)
				_set_npc_goal(entry, "forage berries")
				body.set_meta("npc_job_phase", "outbound")
				return true
			return _retarget_forager_after_route_failure(entry, body, target_node, String(route_disposition.get("releaseReason", "route_slot_failed")), bool(route_disposition.get("markUnreachable", false)))
		var pending_route_timeout := target_node != null and _forager_pending_route_timed_out(entry, delta)
		if target_node != null and pending_route_timeout:
			var failures := int(entry.get("foragePendingRouteRetries", 0)) + 1
			entry["foragePendingRouteRetries"] = failures
			entry["routeForceReplan"] = true
			if failures >= FORAGE_PENDING_ROUTE_FAILURE_LIMIT:
				return _retarget_forager_after_route_failure(entry, body, target_node, "pending_route_timeout", false)
			entry["jobTargetNode"] = target_node
			entry["jobPhase"] = "outbound"
			entry["jobTimer"] = _deterministic_seconds(entry, "forage_route_retry", 3.0, 7.0)
			entry["foragePendingRouteTime"] = 0.0
			entry.erase("foragePendingRouteFrame")
			entry.erase("foragePendingRouteKey")
			NpcRouteStateStoreScript.write_status(entry, "waiting", "retry_forage_pending_route", "NpcPlanExecutor.forage_route_retry")
			_set_npc_goal(entry, "forage berries")
			body.set_meta("npc_job_phase", "outbound")
			return true
		var search_anchor_arrived := phase == "searching" and target_node == null and (String(entry.get("routeStatus", "")) == "arrived" or body.global_position.distance_to(target) <= NpcConstantsScript.CELL_SIZE * 1.2)
		var search_route_blocked := phase == "searching" and target_node == null and String(entry.get("routeStatus", "")) == "blocked"
		if search_anchor_arrived or search_route_blocked:
			var nearby_forage := _find_forage_target(entry) if not _point_inside_town(entry, body.global_position) else null
			if nearby_forage != null and _reserve_job_target(entry, nearby_forage, "harvest_resource"):
				entry["jobPhase"] = "outbound"
				entry["jobTimer"] = _deterministic_seconds(entry, "forage_outbound_timeout", 12.0, 22.0)
				entry["forageRouteFailures"] = 0
				entry["foragePendingRouteRetries"] = 0
				entry["routeForceReplan"] = true
				_clear_home_route_terminal(entry)
				_set_npc_goal(entry, "forage berries")
				body.set_meta("npc_job_phase", "outbound")
				return true
			_advance_forage_search_serial(entry)
			entry["jobTarget"] = _choose_job_target(entry)
			entry["jobTimer"] = _deterministic_seconds(entry, "forage_search_roam", 2.0, 5.0)
			entry["routeForceReplan"] = true
			NpcRouteStateStoreScript.write_reason(entry, "forage_search_roam", "NpcPlanExecutor.forage_search_roam")
			_set_npc_goal(entry, "search for berries")
			body.set_meta("npc_job_phase", "searching")
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
					_advance_forage_search_serial(entry)
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

func _forager_v2_route_disposition(entry: Dictionary) -> Dictionary:
	if String(entry.get("jobObjectId", "")) == "" or String(entry.get("jobReservationId", "")) == "":
		return { "action": "continue", "reason": "no_reservation" }
	var binding: Dictionary = entry.get("forageReservationRouteBinding", {}) if entry.get("forageReservationRouteBinding", {}) is Dictionary else {}
	var binding_reason := String(binding.get("reason", ""))
	if not binding.is_empty() and not bool(binding.get("ok", false)) and binding_reason in [
		"missing_registration",
		"missing_reservation",
		"reservation_owner_mismatch",
		"reservation_slot_mismatch",
		"reservation_deadline",
		"stale_route_generation",
		"route_request_generation_conflict"
	]:
		return { "action": "release", "releaseReason": "reservation_route_%s" % binding_reason, "markUnreachable": false }
	if String(entry.get("routineRouteV2IntentKind", "")) != "forage" or String(entry.get("routineRouteV2SemanticKind", "")) != "forage_target":
		return { "action": "continue", "reason": "route_not_for_forage_target" }
	var intent: Dictionary = entry.get("_routineRouteV2Intent", {}) if entry.get("_routineRouteV2Intent", {}) is Dictionary else {}
	if String(intent.get("jobObjectId", "")) != String(entry.get("jobObjectId", "")):
		return { "action": "continue", "reason": "route_object_mismatch" }
	var authority: Dictionary = entry.get("routeAuthorityV2", {}) if entry.get("routeAuthorityV2", {}) is Dictionary else {}
	var request_id := String(authority.get("requestId", ""))
	var generation := int(authority.get("generation", 0))
	if request_id == "" or request_id != String(entry.get("routineRouteV2RequestId", "")):
		return { "action": "continue", "reason": "route_request_not_current" }
	var bound_generation := int(entry.get("jobReservationRouteGeneration", 0))
	var bound_request_id := String(entry.get("jobReservationRouteRequestId", ""))
	if bound_generation > 0 and (generation < bound_generation or (generation == bound_generation and bound_request_id != "" and bound_request_id != request_id)):
		return { "action": "release", "releaseReason": "stale_reservation_route_identity", "markUnreachable": false }
	var state := String(authority.get("state", ""))
	if state in ["unreachable_static", "invalid_goal"]:
		return {
			"action": "next_slot",
			"releaseReason": "route_%s" % state,
			"markUnreachable": true,
			"state": state,
			"reason": String(authority.get("reason", ""))
		}
	if state == "blocked_dynamic":
		if int(entry.get("forageRouteRepairAttempts", 0)) < FORAGE_DYNAMIC_REPAIR_LIMIT:
			return { "action": "repair", "state": state, "reason": String(authority.get("reason", "")) }
		return {
			"action": "next_slot",
			"releaseReason": "route_blocked_dynamic_after_repair",
			"markUnreachable": false,
			"state": state,
			"reason": String(authority.get("reason", ""))
		}
	return { "action": "continue", "state": state, "reason": String(authority.get("reason", "")) }

func _forager_exact_arrival_proof(entry: Dictionary, body: Node3D) -> Dictionary:
	if body == null:
		return { "ok": false, "reason": "missing_body" }
	var authority: Dictionary = entry.get("routeAuthorityV2", {}) if entry.get("routeAuthorityV2", {}) is Dictionary else {}
	if String(authority.get("state", "")) != "arrived":
		return { "ok": false, "reason": "route_not_arrived", "state": String(authority.get("state", "")) }
	var request_id := String(authority.get("requestId", ""))
	if request_id == "" or request_id != String(entry.get("routineRouteV2RequestId", "")) or request_id != String(entry.get("jobReservationRouteRequestId", "")):
		return { "ok": false, "reason": "arrival_request_mismatch", "requestId": request_id }
	var generation := int(authority.get("generation", 0))
	if generation <= 0 or generation != int(entry.get("jobReservationRouteGeneration", 0)):
		return { "ok": false, "reason": "arrival_generation_mismatch", "generation": generation }
	var claim: Dictionary = authority.get("interactionClaim", {}) if authority.get("interactionClaim", {}) is Dictionary else {}
	var expected_object_id := String(entry.get("jobObjectId", ""))
	var expected_reservation_id := String(entry.get("jobReservationId", ""))
	var expected_slot_id := String(entry.get("jobApproachSlotId", ""))
	if String(claim.get("objectId", "")) != expected_object_id \
		or String(claim.get("reservationId", "")) != expected_reservation_id \
		or String(claim.get("slotId", "")) != expected_slot_id \
		or int(claim.get("routeGeneration", 0)) != generation:
		return { "ok": false, "reason": "arrival_claim_mismatch", "claim": claim }
	var expected_cell = entry.get("jobApproachSlotCell", Vector2i(999999, 999999))
	var claim_cell = claim.get("slotCell", Vector2i(999999, 999999))
	var lease: Dictionary = authority.get("routeLease", {}) if authority.get("routeLease", {}) is Dictionary else {}
	if not (expected_cell is Vector2i) or claim_cell != expected_cell or lease.get("targetCell", Vector2i(999999, 999999)) != expected_cell:
		return { "ok": false, "reason": "arrival_cell_mismatch", "expectedCell": expected_cell, "claimCell": claim_cell, "leaseTargetCell": lease.get("targetCell") }
	var slot_position = entry.get("jobApproachSlotPosition", entry.get("jobTarget", Vector3.INF))
	if not (slot_position is Vector3) or slot_position == Vector3.INF:
		return { "ok": false, "reason": "missing_slot_position" }
	var flat_distance := _flat_distance(body.global_position, slot_position)
	var vertical_distance := absf(body.global_position.y - slot_position.y)
	var arrival_radius := ROUTINE_V2_WAYPOINT_RADIUS + 0.10
	if flat_distance > arrival_radius or vertical_distance > NpcConstantsScript.CELL_SIZE * 0.72:
		return { "ok": false, "reason": "actor_not_at_reserved_slot", "flatDistance": flat_distance, "verticalDistance": vertical_distance, "arrivalRadius": arrival_radius }
	return {
		"ok": true,
		"reason": "arrived_at_reserved_slot",
		"requestId": request_id,
		"generation": generation,
		"objectId": expected_object_id,
		"reservationId": expected_reservation_id,
		"slotId": expected_slot_id,
		"slotCell": expected_cell,
		"flatDistance": flat_distance
	}

func _retarget_forager_after_route_failure(entry: Dictionary, body: Node3D, target_node: Node3D, release_reason: String, mark_unreachable: bool) -> bool:
	_release_job_reservation(entry, release_reason)
	if release_reason.find("reservation_deadline") >= 0 and target_node != null:
		_defer_forager_target(entry, target_node)
	elif mark_unreachable and target_node != null:
		_mark_forager_target_unreachable(entry, target_node)
	entry["jobTargetNode"] = null
	entry["jobPhase"] = "searching"
	entry["jobFailureReason"] = release_reason
	entry["forageRouteRepairAttempts"] = 0
	entry["forageRouteFailures"] = 0
	entry["foragePendingRouteRetries"] = 0
	entry["foragePendingRouteTime"] = 0.0
	entry.erase("foragePendingRouteFrame")
	entry.erase("foragePendingRouteKey")
	entry.erase("forageReservationRouteBinding")
	entry.erase("forageReservationStartedPhysicsFrame")
	entry.erase("forageReservationElapsedSeconds")
	entry.erase("jobApproachCandidates")
	entry.erase("jobApproachCandidateIndex")
	entry.erase("jobApproachTargetObjectId")
	_advance_forage_search_serial(entry)
	entry["jobTarget"] = _choose_job_target(entry)
	entry["jobTimer"] = _deterministic_seconds(entry, "forage_route_failure_search", 3.0, 7.0)
	entry["routeForceReplan"] = true
	_set_npc_goal(entry, "search for berries")
	if body != null:
		body.set_meta("npc_job_phase", "searching")
	return true

func _bind_forage_reservation_to_route(entry: Dictionary, semantic_kind: String) -> Dictionary:
	if npc_system == null or not npc_system.has_method("bind_job_reservation_to_route"):
		return { "ok": false, "status": "failed", "reason": "missing_reservation_route_binding" }
	var authority: Dictionary = entry.get("routeAuthorityV2", {}) if entry.get("routeAuthorityV2", {}) is Dictionary else {}
	if authority.is_empty():
		return { "ok": false, "status": "failed", "reason": "missing_route_authority_state" }
	var result: Dictionary = npc_system.call("bind_job_reservation_to_route", entry, authority, semantic_kind)
	entry["forageReservationRouteBinding"] = result.duplicate(true)
	return result

func _advance_forage_approach_slot(entry: Dictionary, target_node: Node3D) -> bool:
	return bool(npc_system.call("advance_forage_approach_slot", entry, target_node)) if npc_system != null and npc_system.has_method("advance_forage_approach_slot") else false

func _entry_has_active_goal_kind(entry: Dictionary, expected_kind) -> bool:
	var expected := String(expected_kind)
	if String(entry.get("activeGoalKind", "")) == expected:
		return true
	var active_goal_value = entry.get("activeMotionGoal", {})
	if active_goal_value is Dictionary and String((active_goal_value as Dictionary).get("goalKind", "")) == expected:
		return true
	return false

func _advance_forage_search_serial(entry: Dictionary) -> void:
	var serial := int(entry.get("forageSearchSerial", 0)) + 1
	entry["forageSearchSerial"] = serial
	var body := entry.get("body") as Node
	if body != null and is_instance_valid(body):
		body.set_meta("npc_forage_search_serial", serial)

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
	NpcRouteStateStoreScript.write_status(entry, "arrived", reason, "NpcPlanExecutor.clear_route_for_action")
	entry["pathWaypoints"] = []
	entry["routeCells"] = []
	entry["routeActions"] = {}
	entry["routeForceReplan"] = false
	entry["routeWaitTicks"] = 0
	entry["blockedMoveTime"] = 0.0

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

func _point_inside_work_area(entry: Dictionary, position: Vector3) -> bool:
	if npc_system != null and npc_system.has_method("point_inside_work_area"):
		return bool(npc_system.call("point_inside_work_area", entry, position))
	var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
	var radius := (float(entry.get("townRadius", 18)) + 24.0) * NpcConstantsScript.CELL_SIZE
	var flat := Vector2(position.x - float(center.x) * NpcConstantsScript.CELL_SIZE, position.z - float(center.y) * NpcConstantsScript.CELL_SIZE)
	return flat.length() <= radius

func _resource_job_uses_outside_work_area(job: String) -> bool:
	if npc_system != null and npc_system.has_method("resource_job_uses_outside_work_area"):
		return bool(npc_system.call("resource_job_uses_outside_work_area", job))
	return job == "forage"

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

func _forager_pending_route_timed_out(entry: Dictionary, delta: float) -> bool:
	var authority: Dictionary = entry.get("routeAuthorityV2", {}) if entry.get("routeAuthorityV2", {}) is Dictionary else {}
	var state := String(authority.get("state", ""))
	var waiting_for_route_readiness := state in ["queued", "pending_nav_data", "pending_budget", "probing"] \
		and String(entry.get("routineRouteV2IntentKind", "")) == "forage" \
		and String(entry.get("routineRouteV2SemanticKind", "")) == "forage_target" \
		and String(authority.get("requestId", "")) == String(entry.get("routineRouteV2RequestId", ""))
	if not waiting_for_route_readiness:
		entry["foragePendingRouteTime"] = 0.0
		entry.erase("foragePendingRouteFrame")
		entry.erase("foragePendingRouteKey")
		return false
	var target: Vector3 = entry.get("jobTarget", Vector3.ZERO)
	var authority_wait_frames := maxi(
		maxi(int(authority.get("pendingNavDataFrames", 0)), int(authority.get("pendingBudgetFrames", 0))),
		maxi(int(authority.get("pendingProbeFrames", 0)), int(authority.get("planningWaitFrames", 0)))
	)
	var ticks_per_second := maxf(float(Engine.physics_ticks_per_second), 1.0)
	var pending_key := "%s|%s|%s|%d,%d" % [
		String(entry.get("jobObjectId", "")),
		state,
		String(authority.get("requestId", "")),
		roundi(target.x / NpcConstantsScript.CELL_SIZE),
		roundi(target.z / NpcConstantsScript.CELL_SIZE)
	]
	var current_frame := Engine.get_physics_frames()
	if String(entry.get("foragePendingRouteKey", "")) != pending_key:
		entry["foragePendingRouteKey"] = pending_key
		entry["foragePendingRouteFrame"] = current_frame
		entry["foragePendingRouteTime"] = 0.0
		if float(authority_wait_frames) / ticks_per_second < FORAGE_PENDING_ROUTE_TIMEOUT_SECONDS:
			return false
	var start_frame := int(entry.get("foragePendingRouteFrame", current_frame))
	var pending_time := maxf(
		maxf(float(current_frame - start_frame) / ticks_per_second, float(authority_wait_frames) / ticks_per_second),
		float(entry.get("foragePendingRouteTime", 0.0)) + maxf(delta, 0.0)
	)
	entry["foragePendingRouteTime"] = pending_time
	return pending_time >= FORAGE_PENDING_ROUTE_TIMEOUT_SECONDS

func _forager_reservation_deadline_exceeded(entry: Dictionary) -> bool:
	if String(entry.get("jobReservationId", "")) == "":
		entry.erase("forageReservationStartedPhysicsFrame")
		entry.erase("forageReservationElapsedSeconds")
		return false
	var current_frame := Engine.get_physics_frames()
	var started_frame := int(entry.get("forageReservationStartedPhysicsFrame", current_frame))
	if not entry.has("forageReservationStartedPhysicsFrame"):
		entry["forageReservationStartedPhysicsFrame"] = current_frame
	var elapsed := float(maxi(0, current_frame - started_frame)) / maxf(float(Engine.physics_ticks_per_second), 1.0)
	entry["forageReservationElapsedSeconds"] = elapsed
	return elapsed >= NpcConstantsScript.FORAGE_RESERVATION_DEADLINE_SECONDS

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

func _defer_forager_target(entry: Dictionary, node: Node3D) -> void:
	if npc_system != null and npc_system.has_method("defer_forager_target"):
		npc_system.call("defer_forager_target", entry, node, NpcConstantsScript.FORAGE_TARGET_RETRY_COOLDOWN_SECONDS)

func _mark_job_resource_target_unreachable(entry: Dictionary, node: Node3D, job: String) -> void:
	if npc_system != null and npc_system.has_method("mark_job_resource_target_unreachable"):
		npc_system.call("mark_job_resource_target_unreachable", entry, node, job)

func _smart_object_approach_position(entry: Dictionary, target_node: Node3D) -> Vector3:
	return npc_system.call("smart_object_approach_position", entry, target_node) if npc_system != null and npc_system.has_method("smart_object_approach_position") else entry.get("jobTarget", target_node.global_position if target_node != null else Vector3.ZERO)

func _complete_worker_resource_target(entry: Dictionary) -> bool:
	return bool(npc_system.call("complete_worker_resource_target", entry)) if npc_system != null and npc_system.has_method("complete_worker_resource_target") else false

func _harvest_forager_target(entry: Dictionary) -> bool:
	return bool(npc_system.call("harvest_forager_target", entry)) if npc_system != null and npc_system.has_method("harvest_forager_target") else _complete_worker_resource_target(entry)

func _smart_object_action_reach(entry: Dictionary, fallback: float) -> float:
	if npc_system == null or not npc_system.has_method("smart_object_action_reach"):
		return fallback
	return float(npc_system.call("smart_object_action_reach", String(entry.get("jobObjectId", "")), fallback))

func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

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
