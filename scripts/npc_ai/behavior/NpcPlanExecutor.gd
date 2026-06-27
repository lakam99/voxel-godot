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
		_publish_debug(entry, blackboard, { "goalKind": NpcEnumsScript.GOAL_KIND_IDLE, "reason": "held_by_script" }, {}, schedule, perception)
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
	var execute_start: int = monitor.begin_section("npc_execute_plan") if monitor != null else Time.get_ticks_usec()
	_execute_plan(entry, body, goal, plan, perception, schedule, delta)
	if monitor != null:
		monitor.end_section("npc_execute_plan", execute_start)
	if npc_system.has_method("face_hostile_if_needed"):
		var face_start: int = monitor.begin_section("npc_face_hostile") if monitor != null else Time.get_ticks_usec()
		npc_system.call("face_hostile_if_needed", body, perception.get("threat"))
		if monitor != null:
			monitor.end_section("npc_face_hostile", face_start)

func _execute_plan(entry: Dictionary, body: Node3D, goal: Dictionary, plan: Dictionary, perception: Dictionary, schedule: Dictionary, delta: float) -> void:
	var goal_kind: StringName = goal.get("goalKind", NpcEnumsScript.GOAL_KIND_IDLE)
	var monitor = performance_monitor()
	match goal_kind:
		NpcEnumsScript.GOAL_KIND_SCRIPTED:
			var scripted_start: int = monitor.begin_section("npc_execute_scripted") if monitor != null else Time.get_ticks_usec()
			_execute_scripted(entry, body, delta)
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
		speed = 20.0
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
	var moved := float(npc_system.call("move_npc", entry, target, 2.65 * delta, false, true, delta)) if npc_system.has_method("move_npc") else 0.0
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
		var job_move_start: int = monitor.begin_section("npc_job_move") if monitor != null else Time.get_ticks_usec()
		var moved := float(npc_system.call("move_npc", entry, target, 3.10 * delta, false, true, delta)) if npc_system.has_method("move_npc") else 0.0
		if monitor != null:
			monitor.end_section("npc_job_move", job_move_start)
		entry["lastMoveDistance"] = moved
		var route_status := String(entry.get("routeStatus", ""))
		if moved <= 0.001 and route_status != "pending":
			entry["routeForceReplan"] = true
	else:
		entry["lastMoveDistance"] = 0.0
		entry["routeStatus"] = "idle"

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
		if timer > 0.0:
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
	var route_arrived := String(entry.get("routeStatus", "")) == "arrived"
	if target_outside and (route_arrived or body.global_position.distance_to(target) <= NpcConstantsScript.CELL_SIZE * 1.1 or body.global_position.distance_to(target_node.global_position) <= NpcConstantsScript.CELL_SIZE * 1.75):
		entry["jobPhase"] = "gathering"
		entry["jobTimer"] = _deterministic_seconds(entry, "resource_gather_duration", 1.8, 3.5)
		_play_npc_use(entry, "gather")
		body.set_meta("npc_job_phase", "gathering")
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
		return true
	if _point_inside_town(entry, body.global_position):
		_release_job_reservation(entry, "inside_town_invalid_gather")
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
		if timer > 0.0:
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
		if timer > 0.0 and not hungry:
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
		if target_node == null and phase == "outbound":
			entry["jobTargetNode"] = null
			_release_job_reservation(entry, "target_gone")
			entry["jobPhase"] = "idle"
			entry["jobTimer"] = 0.0
			return true
		if target_node != null and String(entry.get("jobObjectId", "")) == "":
			_reserve_job_target(entry, target_node, "harvest_resource")
		if target_node != null and _current_route_failure_blocks_forager(entry):
			_mark_forager_target_unreachable(entry, target_node)
			_release_job_reservation(entry, "route_blocked")
			var failures := int(entry.get("forageRouteFailures", 0)) + 1
			entry["forageRouteFailures"] = failures
			entry["jobTargetNode"] = null
			entry["routeForceReplan"] = true
			if failures >= NpcConstantsScript.ROUTE_REPAIR_FAILURE_LIMIT:
				entry["jobPhase"] = "searching"
				entry["jobTarget"] = _choose_job_target(entry)
				entry["jobTimer"] = _deterministic_seconds(entry, "forage_blocked_search", 3.0, 7.0)
				_set_npc_goal(entry, "search for berries")
				body.set_meta("npc_job_phase", "searching")
				return true
			entry["jobPhase"] = "idle"
			entry["jobTimer"] = 0.0
			_set_npc_goal(entry, "forage berries")
			body.set_meta("npc_job_phase", "idle")
			return true
		var target: Vector3 = entry.get("jobTarget", body.global_position)
		var outside_town := not _point_inside_town(entry, body.global_position)
		var reached_target := body.global_position.distance_to(target) <= NpcConstantsScript.CELL_SIZE * 1.15
		var reached_forage_node := target_node != null and body.global_position.distance_to(target_node.global_position) <= NpcConstantsScript.CELL_SIZE * 1.75
		var route_arrived := String(entry.get("routeStatus", "")) == "arrived"
		if route_arrived or reached_target or reached_forage_node or (phase == "searching" and outside_town):
			entry["jobPhase"] = "gathering"
			entry["jobTimer"] = _deterministic_seconds(entry, "forage_gather_duration", 1.0, 1.8)
			_set_npc_goal(entry, "pick berries")
			_play_npc_use(entry, "gather")
			body.set_meta("npc_job_phase", "gathering")
		else:
			_set_npc_goal(entry, "forage berries" if phase == "outbound" else "search for berries")
			if timer <= 0.0:
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
			return true
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
	var moved := float(npc_system.call("move_npc", entry, target, 2.25 * delta, false, false, delta)) if npc_system.has_method("move_npc") else 0.0
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
