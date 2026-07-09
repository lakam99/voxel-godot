extends RefCounted

const NpcEnumsScript := preload("res://scripts/npc_ai/NpcEnums.gd")
const NpcBlackboardScript := preload("res://scripts/npc_ai/NpcBlackboard.gd")
const GuardRosterServiceScript := preload("res://scripts/npc_ai/behavior/GuardRosterService.gd")
const NpcScheduleServiceScript := preload("res://scripts/npc_ai/behavior/NpcScheduleService.gd")
const NpcGoalSelectorScript := preload("res://scripts/npc_ai/behavior/NpcGoalSelector.gd")
const NpcActionLibraryScript := preload("res://scripts/npc_ai/behavior/NpcActionLibrary.gd")
const NpcTaskPlannerScript := preload("res://scripts/npc_ai/behavior/NpcTaskPlanner.gd")
const NpcRecoveryPolicyScript := preload("res://scripts/npc_ai/behavior/NpcRecoveryPolicy.gd")
const NpcPlanExecutorScript := preload("res://scripts/npc_ai/behavior/NpcPlanExecutor.gd")
const NpcPerceptionServiceScript := preload("res://scripts/npc_ai/behavior/NpcPerceptionService.gd")
const NpcSemanticGoalPlannerScript := preload("res://scripts/npc_ai/behavior/NpcSemanticGoalPlanner.gd")
const NpcRouteMovementControllerScript := preload("res://scripts/npc_ai/movement/NpcRouteMovementController.gd")
const CELL := 1.35

var runner = null
var roster
var schedule
var selector
var planner
var recovery

class FakeAutonomy:
	extends Node
	var traffic_releases := 0
	var door_releases := 0
	var door_portals = null

	func release_npc_traffic_reservations(_entry, _reason := "released") -> int:
		traffic_releases += 1
		return 1

	func release_npc_door_hold(_actor_or_id, _schedule_close := true) -> void:
		door_releases += 1

class FakeNavigationService:
	extends RefCounted
	var unreachable_x_threshold := INF

	func closest_walkable(position: Vector3, max_distance := INF) -> Dictionary:
		if position.x >= unreachable_x_threshold:
			return { "found": false, "reason": "test_unreachable", "position": position, "maxDistance": max_distance }
		return { "found": true, "position": position, "distance": 0.0, "source": "test_navmesh" }

class FakeDoorPortalService:
	extends RefCounted
	var portals := {}

class FakeMain:
	extends Node
	const WATER_LEVEL := -100.0

	func surface_y_at_position(_position: Vector3) -> float:
		return 0.0

class FakeRouteWorld:
	extends RefCounted

	func point_allowed(_entry: Dictionary, _position: Vector3, _allow_outside := false, _moving_home := false) -> bool:
		return true

	func world_cell(position: Vector3) -> Vector2i:
		return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

	func terrain_allows_step(_from_cell: Vector2i, _to_cell: Vector2i, _moving_home := false) -> Dictionary:
		return { "ok": true, "height": 0.0 }

	func build_snapshot(_entry: Dictionary, allow_outside := false, moving_home := false) -> Dictionary:
		return {
			"allowOutside": allow_outside,
			"movingHome": moving_home,
			"blocked": {},
			"dynamic": {},
			"doors": {},
			"paths": {}
		}

	func static_blocker(_snapshot: Dictionary, _cell: Vector2i):
		return null

	func dynamic_blocker(_snapshot: Dictionary, _cell: Vector2i):
		return null

	func revision() -> String:
		return "fake-route-world"

	func cell_key(cell: Vector2i) -> String:
		return "%d,%d" % [cell.x, cell.y]

class FakeGuardTargetWorld:
	extends RefCounted

	func world_cell(position: Vector3) -> Vector2i:
		return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

	func cell_position(cell: Vector2i) -> Vector3:
		return Vector3(float(cell.x) * CELL, 0.0, float(cell.y) * CELL)

	func point_allowed(_entry: Dictionary, _position: Vector3, _allow_outside := false, _moving_home := false) -> bool:
		return true

	func point_inside_town(_entry: Dictionary, _position: Vector3) -> bool:
		return true

	func point_inside_work_area(_entry: Dictionary, _position: Vector3) -> bool:
		return true

	func approach_cells_for_target(_entry: Dictionary, _target_position: Vector3, _allow_outside := true) -> Array[Vector2i]:
		return []

	func cell_is_standable_goal(_entry: Dictionary, _cell: Vector2i, _allow_outside := false, _moving_home := false) -> bool:
		return true

class FakeUnreachableRoutePlanner:
	extends RefCounted

	func route_cost(_entry: Dictionary, _target: Vector3, _allow_outside := false, _moving_home := false, _arrival_radius := CELL * 0.85, _approach_cells := [], _require_ready := false) -> float:
		return INF

class FakeNpcSystem:
	extends Node
	var chosen_anchor := Vector3(2.7, 0.0, 0.0)
	var move_calls := 0
	var moving_home_calls := 0
	var route_motion_calls := 0
	var motor_block_until_distance := -1.0
	var max_requested_distance := 0.0
	var allow_outside_calls := 0
	var last_allow_outside := false
	var moved_actor_ids := {}

	func update_npc_needs(_entry: Dictionary, _delta: float, _night_factor: float) -> void:
		pass

	func npc_is_held_by_intro_or_dialogue(_entry: Dictionary, _body: Node3D) -> bool:
		return false

	func choose_day_target(_entry: Dictionary) -> Vector3:
		return chosen_anchor

	func move_npc(entry: Dictionary, target: Vector3, max_distance: float, _moving_home := false, _allow_outside := false, _physics_delta := 0.0166667) -> float:
		var body := entry.get("body") as Node3D
		if body == null:
			return 0.0
		move_calls += 1
		last_allow_outside = _allow_outside
		if _allow_outside:
			allow_outside_calls += 1
		if _moving_home:
			moving_home_calls += 1
		max_requested_distance = maxf(max_requested_distance, max_distance)
		moved_actor_ids[String(entry.get("id", "npc"))] = int(moved_actor_ids.get(String(entry.get("id", "npc")), 0)) + 1
		var previous := body.global_position
		if bool(entry.get("blockMovement", false)):
			return 0.0
		body.global_position = previous.move_toward(target, max_distance)
		var moved := body.global_position.distance_to(previous)
		if moved > 0.001:
			entry["routeStatus"] = "moving"
			entry["routeReason"] = ""
		return moved

	func apply_npc_route_motion(entry: Dictionary, previous: Vector3, candidate: Vector3, _physics_delta := 0.0166667) -> Dictionary:
		route_motion_calls += 1
		var body := entry.get("body") as Node3D
		if body == null:
			return { "moved": 0.0, "position": previous, "blocked": true, "reason": "missing_body" }
		var flat := Vector2(candidate.x - previous.x, candidate.z - previous.z).length()
		if motor_block_until_distance >= 0.0 and flat < motor_block_until_distance:
			return { "moved": 0.0, "position": previous, "blocked": true, "reason": "static_or_dynamic_collision" }
		body.global_position = candidate
		entry["lastMoveDistance"] = flat
		return { "moved": flat, "position": candidate, "blocked": false, "reason": "" }

	func home_route_target(entry: Dictionary) -> Vector3:
		return entry.get("homePosition", Vector3.ZERO)

	func settle_home_if_reached(entry: Dictionary) -> void:
		var body := entry.get("body") as Node3D
		if body != null and body.global_position.distance_to(entry.get("homePosition", body.global_position)) <= 0.35:
			entry["insideHome"] = true
			body.set_meta("npc_inside_home", true)

	func update_fighter_target(entry: Dictionary, _body: Node3D, target_hostile: Node3D, _weapon_id: String) -> Vector3:
		entry["guardDutyState"] = "intercept_threat" if target_hostile != null else "patrol"
		return Vector3(4.05, 0.0, 0.0)

	func normalize_npc_speed_mode(speed_mode) -> String:
		var mode := String(speed_mode).strip_edges().to_lower()
		return "sprinting" if mode in ["sprint", "sprinting", "rush", "rushing", "run", "running"] else "walking"

	func npc_speed_for_mode(_entry: Dictionary, speed_mode := "walking") -> float:
		return 6.4 if normalize_npc_speed_mode(speed_mode) == "sprinting" else 2.6

	func set_npc_speed_mode(entry: Dictionary, speed_mode := "walking", reason := "") -> String:
		var mode := normalize_npc_speed_mode(speed_mode)
		entry["npcSpeedMode"] = mode
		entry["npcSpeed"] = npc_speed_for_mode(entry, mode)
		entry["npcSpeedReason"] = reason
		entry["npcRushing"] = mode == "sprinting"
		var body := entry.get("body") as Node
		if body != null:
			body.set_meta("npc_speed_mode", mode)
			body.set_meta("npc_speed", float(entry["npcSpeed"]))
			body.set_meta("npc_rushing", bool(entry["npcRushing"]))
		return mode

	func update_scripted_npc(entry: Dictionary, body: Node3D, delta: float) -> void:
		var target: Vector3 = body.get_meta("npc_scripted_target", body.global_position)
		var mode := set_npc_speed_mode(entry, body.get_meta("npc_scripted_speed_mode", "walking"), "scripted_go_to")
		var moved := move_npc(entry, target, npc_speed_for_mode(entry, mode) * delta, false, true, delta)
		if body.global_position.distance_to(target) <= 1.35 * 0.95:
			body.set_meta("npc_scripted_arrived", true)
		entry["lastMoveDistance"] = moved
		entry["scriptedUpdated"] = true

	func face_hostile_if_needed(_body: Node3D, _target_hostile: Node3D) -> void:
		pass

	func face_position(body: Node3D, target: Vector3) -> void:
		if body == null:
			return
		var to_target := target - body.global_position
		to_target.y = 0.0
		if to_target.length_squared() > 0.001:
			body.rotation.y = atan2(to_target.x, to_target.z)

	func scripted_order_result(entry: Dictionary, state: String, reason: String, failure_reason := "") -> Dictionary:
		var result: Dictionary = entry.get("scriptedOrder", {}) if entry.get("scriptedOrder", {}) is Dictionary else {}
		result = result.duplicate(true)
		result["state"] = state
		result["reason"] = reason
		result["failureReason"] = failure_reason
		entry["scriptedOrder"] = result
		var body := entry.get("body") as Node
		if body != null:
			body.set_meta("npc_scripted_order_state", state)
			body.set_meta("npc_scripted_order_reason", reason)
			body.set_meta("npc_scripted_order_failure_reason", failure_reason)
		return result

func setup(owner) -> void:
	runner = owner
	roster = GuardRosterServiceScript.new()
	schedule = NpcScheduleServiceScript.new()
	schedule.setup(roster)
	selector = NpcGoalSelectorScript.new()
	var library = NpcActionLibraryScript.new()
	planner = NpcTaskPlannerScript.new()
	planner.setup(library)
	recovery = NpcRecoveryPolicyScript.new()

func cases() -> Array[Dictionary]:
	return [
		case("npc_behavior_task_catalog_resource_backed", "day", "test_task_catalog_resource_backed"),
		case("npc_behavior_shared_task_definitions_cover_phase4_goals", "day", "test_shared_task_definitions_cover_phase4_goals"),
		case("npc_behavior_goal_target_validation_reachable_navmesh", "day", "test_goal_target_validation_reachable_navmesh"),
		case("npc_behavior_day_worker_reachable_job", "day", "test_day_worker_reachable_job"),
		case("npc_behavior_day_forager_goal_plan_shape", "day", "test_day_forager_goal_plan_shape"),
		case("npc_behavior_day_guard_patrol", "day", "test_day_guard_patrol"),
		case("npc_behavior_guard_target_never_falls_back_to_porch", "day", "test_guard_target_never_falls_back_to_porch"),
		case("npc_behavior_day_idle_semantic_anchor", "day", "test_day_idle_semantic_anchor"),
		case("npc_behavior_dusk_civilian_returns_before_night", "transition", "test_dusk_civilian_returns_before_night"),
		case("npc_behavior_dusk_guard_reports_to_duty", "transition", "test_dusk_guard_reports_to_duty"),
		case("npc_behavior_night_assigned_guard_outside", "night", "test_night_assigned_guard_outside"),
		case("npc_behavior_night_off_duty_guard_inside", "night", "test_night_off_duty_guard_inside"),
		case("npc_behavior_night_fighter_non_guard_inside", "night", "test_night_fighter_non_guard_inside"),
		case("npc_behavior_night_worker_inside", "night", "test_night_worker_inside"),
		case("npc_behavior_night_forager_inside", "night", "test_night_forager_inside"),
		case("npc_behavior_night_trader_inside", "night", "test_night_trader_inside"),
		case("npc_behavior_night_porch_not_inside", "night", "test_night_porch_not_inside"),
		case("npc_behavior_night_threshold_not_inside", "night", "test_night_threshold_not_inside"),
		case("npc_behavior_night_blocked_home_explicit_failure_no_teleport", "night", "test_night_blocked_home_explicit_failure_no_teleport"),
		case("npc_behavior_threat_exception_explicit", "night", "test_threat_exception_explicit"),
		case("npc_behavior_executor_decays_guard_cooldown", "night", "test_executor_decays_guard_cooldown"),
		case("npc_behavior_post_threat_schedule_restored", "night", "test_post_threat_schedule_restored"),
		case("npc_behavior_night_job_phase_does_not_override_home_motion", "night", "test_night_job_phase_does_not_override_home_motion"),
		case("npc_behavior_day_job_phase_overrides_stale_home_motion", "day", "test_day_job_phase_overrides_stale_home_motion"),
		case("npc_behavior_home_motion_stops_once_inside", "night", "test_home_motion_stops_once_inside"),
		case("npc_behavior_goal_hysteresis_no_thrashing", "day", "test_goal_hysteresis_no_thrashing"),
		case("npc_behavior_action_interrupt_releases_resources", "day", "test_action_interrupt_releases_resources"),
		case("npc_behavior_scripted_order_priority_and_cancel", "day", "test_scripted_order_priority_and_cancel"),
		case("npc_behavior_scripted_order_go_home_uses_route_stack", "day", "test_scripted_order_go_home_uses_route_stack"),
		case("npc_behavior_scripted_go_home_arrival_clears_cached_motion", "day", "test_scripted_go_home_arrival_clears_cached_motion"),
		case("npc_behavior_scripted_go_home_hold_arrival_stays_home", "day", "test_scripted_go_home_hold_arrival_stays_home"),
		case("npc_behavior_scripted_order_normal_profile_speed", "day", "test_scripted_order_normal_profile_speed"),
		case("npc_behavior_scripted_order_sprint_profile_speed", "day", "test_scripted_order_sprint_profile_speed"),
		case("npc_behavior_scripted_order_no_transform_write", "day", "test_scripted_order_no_transform_write"),
		case("npc_behavior_mira_dialogue_ack_releases_go_home_order", "day", "test_mira_dialogue_ack_releases_go_home_order"),
		case("npc_behavior_mira_home_arrival_requires_interior", "day", "test_mira_home_arrival_requires_interior"),
		case("npc_behavior_hold_intro_door_not_speed_override", "day", "test_hold_intro_door_not_speed_override"),
		case("npc_motor_every_active_actor_motion_tick_32_npcs", "day", "test_every_active_actor_motion_tick_32_npcs"),
		case("npc_behavior_brain_budget_does_not_skip_route_motion", "day", "test_brain_budget_does_not_skip_route_motion"),
		case("npc_behavior_scripted_order_moves_while_brain_skipped", "day", "test_scripted_order_moves_while_brain_skipped"),
		case("npc_behavior_mira_no_inching_after_dialogue", "day", "test_mira_no_inching_after_dialogue"),
		case("npc_behavior_morning_departures_not_brain_starved", "day", "test_morning_departures_not_brain_starved"),
		case("npc_behavior_idle_worker_exits_home_clearance", "day", "test_idle_worker_exits_home_clearance"),
		case("npc_behavior_job_selection_budget_ages_deferred_workers", "day", "test_job_selection_budget_ages_deferred_workers"),
		case("npc_behavior_resource_worker_outbound_stays_town_bound", "day", "test_resource_worker_outbound_stays_town_bound"),
		case("npc_behavior_forager_outbound_allows_outside", "day", "test_forager_outbound_allows_outside"),
		case("npc_traffic_door_crossing_continues_while_brain_skipped", "day", "test_door_crossing_continues_while_brain_skipped"),
		case("npc_behavior_motor_blocked_local_escape_forces_replan", "day", "test_motor_blocked_local_escape_forces_replan"),
		case("npc_behavior_unreachable_goal_terminal", "day", "test_unreachable_goal_terminal"),
		case("npc_behavior_all_generated_town_npcs_have_interior_home", "day", "test_all_generated_town_npcs_have_interior_home"),
		case("npc_behavior_no_raw_random_world_goal", "day", "test_no_raw_random_world_goal")
	]

func case(id: String, mode: String, method: String) -> Dictionary:
	return {
		"id": id,
		"suite": "behavior",
		"timeModes": [mode],
		"callable": Callable(self, method)
	}

func test_day_worker_reachable_job(_mode: String) -> Dictionary:
	var result := select_and_plan(entry("Carpenter", { "job": "wood" }), NpcEnumsScript.SCHEDULE_STATE_DAY)
	var passed: bool = result.goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_WORK and result.plan.get("actionIds", []).has("navigate_to_work")
	return outcome(passed, "goal=%s actions=%s" % [String(result.goal.get("goalKind")), JSON.stringify(result.plan.get("actionIds", []))], ["worker_goal_work", "worker_plan_navigates_to_work"], result)

func test_day_forager_goal_plan_shape(_mode: String) -> Dictionary:
	var result := select_and_plan(entry("Forager", { "job": "forage" }), NpcEnumsScript.SCHEDULE_STATE_DAY)
	var actions: Array = result.plan.get("actionIds", [])
	var target: Dictionary = result.plan.get("semanticTarget", {})
	var passed: bool = result.goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_FORAGE and actions == ["select_forage_target", "reserve_resource_slot", "navigate_to_resource", "harvest_resource", "eat_if_hungry"] and String(target.get("targetKind", "")) == "forage_source" and String(target.get("status", "")) == "pending"
	return outcome(passed, "actions=%s" % JSON.stringify(actions), ["forager_goal", "forager_symbolic_sequence"], result)

func test_task_catalog_resource_backed(_mode: String) -> Dictionary:
	var library := NpcActionLibraryScript.new()
	var validation: Dictionary = library.validate_catalog()
	var library_source := read_text("res://scripts/npc_ai/behavior/NpcActionLibrary.gd")
	var catalog_exists := ResourceLoader.exists("res://resources/npc_behavior/task_catalog.tres")
	var hardcoded_defaults_removed := library_source.find("func _register_defaults") < 0 and library_source.find("_add(") < 0
	var rest: Dictionary = library.definition("rest_at_bed")
	var tutorial: Dictionary = library.definition("complete_tutorial_world_action")
	var passed := bool(validation.get("ok", false)) and catalog_exists and hardcoded_defaults_removed and int(validation.get("actionCount", 0)) >= 28 and int(validation.get("sequenceCount", 0)) >= 9 and String(rest.get("targetKind", "")) == "bed" and bool(rest.get("reservationRequired", false)) and bool(rest.get("routeRequired", false)) and String(tutorial.get("targetKind", "")) == "tutorial_action"
	return outcome(passed, "validation=%s catalog=%s hardcoded=%s" % [JSON.stringify(validation), str(catalog_exists), str(hardcoded_defaults_removed)], ["resource_catalog_loads", "hardcoded_action_defaults_removed", "task_fields_declared"], { "validation": validation, "rest": rest, "tutorial": tutorial })

func test_shared_task_definitions_cover_phase4_goals(_mode: String) -> Dictionary:
	var forage := select_and_plan(entry("Forager", { "job": "forage", "jobTarget": Vector3(8.1, 0.0, 0.0) }), NpcEnumsScript.SCHEDULE_STATE_DAY)
	var trader := select_and_plan(entry("Trader", { "job": "trade", "jobTarget": Vector3(2.7, 0.0, 0.0), "stallPosition": Vector3(2.7, 0.0, 0.0) }), NpcEnumsScript.SCHEDULE_STATE_DAY)
	var guard := select_and_plan(entry("Guard", { "job": "guard", "canFight": true, "nightGuard": true }), NpcEnumsScript.SCHEDULE_STATE_DAY)
	var home := select_and_plan(entry("Villager", { "job": "" }), NpcEnumsScript.SCHEDULE_STATE_NIGHT, { "insideHome": false })
	var tutorial_entry := entry("Villager", { "id": "tutorial_npc", "tutorialActionPosition": Vector3(1.35, 0.0, 0.0) })
	var tutorial_body := tutorial_entry.get("body") as Node3D
	tutorial_body.set_meta("npc_scripted_order_kind", "tutorial_action")
	tutorial_body.set_meta("npc_scripted_order_state", "PENDING")
	tutorial_body.set_meta("npc_scripted_target", Vector3(1.35, 0.0, 0.0))
	var tutorial := select_and_plan(tutorial_entry, NpcEnumsScript.SCHEDULE_STATE_DAY, { "scriptedOrder": true, "scriptedOrderKind": "tutorial_action", "scriptedOrderState": "PENDING" })
	var passed := (
		(forage.plan.get("actionIds", []) as Array).has("reserve_resource_slot")
		and String(forage.plan.get("targetKind", "")) == "forage_source"
		and (trader.plan.get("actionIds", []) as Array).has("use_trader_stall")
		and String(trader.plan.get("sequenceId", "")) == "trader_stall_work"
		and (guard.plan.get("actionIds", []) as Array).has("occupy_guard_post")
		and (home.plan.get("actionIds", []) as Array).has("rest_at_bed")
		and (tutorial.plan.get("actionIds", []) as Array).has("complete_tutorial_world_action")
		and String(tutorial.plan.get("sequenceId", "")) == "tutorial_scripted_action"
	)
	return outcome(passed, "forage=%s trader=%s guard=%s home=%s tutorial=%s" % [JSON.stringify(forage.plan.get("actionIds", [])), JSON.stringify(trader.plan.get("actionIds", [])), JSON.stringify(guard.plan.get("actionIds", [])), JSON.stringify(home.plan.get("actionIds", [])), JSON.stringify(tutorial.plan.get("actionIds", []))], ["forage_task_definition", "trader_stall_task_definition", "guard_post_task_definition", "home_bed_task_definition", "tutorial_scripted_task_definition"], { "forage": forage.plan, "trader": trader.plan, "guard": guard.plan, "home": home.plan, "tutorial": tutorial.plan })

func test_goal_target_validation_reachable_navmesh(_mode: String) -> Dictionary:
	var library := NpcActionLibraryScript.new()
	var fake_nav := FakeNavigationService.new()
	var reachable_planner := NpcTaskPlannerScript.new()
	reachable_planner.setup(library, fake_nav)
	var reachable := select_and_plan(entry("Forager", { "job": "forage", "jobTarget": Vector3(8.1, 0.0, 0.0) }), NpcEnumsScript.SCHEDULE_STATE_DAY, {}, reachable_planner)
	var blocked_nav := FakeNavigationService.new()
	blocked_nav.unreachable_x_threshold = 50.0
	var blocked_planner := NpcTaskPlannerScript.new()
	blocked_planner.setup(library, blocked_nav)
	var blocked := select_and_plan(entry("Forager", { "job": "forage", "jobTarget": Vector3(99.0, 0.0, 0.0) }), NpcEnumsScript.SCHEDULE_STATE_DAY, {}, blocked_planner)
	var reachable_target: Dictionary = reachable.plan.get("semanticTarget", {})
	var blocked_target: Dictionary = blocked.plan.get("semanticTarget", {})
	var passed := bool(reachable_target.get("reachable", false)) and String(reachable_target.get("status", "")) == "reachable" and String(reachable_target.get("reason", "")) == "navmesh_walkable" and String(blocked.plan.get("status", "")) == "failed" and String(blocked.plan.get("failureReason", "")) == "semantic_target_unreachable" and String(blocked_target.get("reason", "")) == "test_unreachable"
	return outcome(passed, "reachable=%s blocked=%s" % [JSON.stringify(reachable_target), JSON.stringify(blocked_target)], ["reachable_semantic_target_validated_by_navmesh", "unreachable_semantic_target_fails_plan"], { "reachable": reachable.plan, "blocked": blocked.plan })

func test_day_guard_patrol(_mode: String) -> Dictionary:
	var result := select_and_plan(entry("Guard", { "job": "guard", "canFight": true, "nightGuard": true }), NpcEnumsScript.SCHEDULE_STATE_DAY)
	var actions: Array = result.plan.get("actionIds", [])
	var passed: bool = result.goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_GUARD and actions.has("patrol_guard_post")
	return outcome(passed, "goal=%s actions=%s" % [String(result.goal.get("goalKind")), JSON.stringify(actions)], ["day_guard_goal", "patrol_action"], result)

func test_guard_target_never_falls_back_to_porch(_mode: String) -> Dictionary:
	var goal_planner = NpcSemanticGoalPlannerScript.new()
	goal_planner.setup(null, FakeMain.new(), FakeGuardTargetWorld.new(), FakeUnreachableRoutePlanner.new())
	var body := Node3D.new()
	body.global_position = Vector3.ZERO
	var porch := Vector3(CELL, 0.0, 0.0)
	var guard_post := Vector3(CELL * 24.0, 0.0, 0.0)
	var entry_data := {
		"id": "guard-target-test",
		"body": body,
		"job": "guard",
		"guardPosition": guard_post,
		"porchPosition": porch,
		"townCenter": Vector2i.ZERO,
		"townRadius": 32
	}
	var target: Vector3 = goal_planner.choose_guard_target(entry_data, null, false)
	var candidates: Array = goal_planner.guard_post_candidates(entry_data)
	var porch_present := false
	for candidate in candidates:
		if candidate is Vector3 and (candidate as Vector3).distance_to(porch) <= 0.01:
			porch_present = true
	var passed := target.distance_to(guard_post) <= 0.01 and not porch_present and String(entry_data.get("routeReason", "")) == "no_reachable_guard_anchor"
	body.free()
	return outcome(
		passed,
		"target=%s guard=%s porchPresent=%s reason=%s" % [str(target), str(guard_post), str(porch_present), String(entry_data.get("routeReason", ""))],
		["guard_target_preserves_assigned_post", "guard_candidates_exclude_home_porch", "guard_unreachable_remains_diagnostic"],
		{ "target": target, "guardPost": guard_post, "porch": porch, "porchPresent": porch_present, "reason": String(entry_data.get("routeReason", "")) }
	)

func test_day_idle_semantic_anchor(_mode: String) -> Dictionary:
	var source := read_text("res://scripts/npc_ai/behavior/NpcSemanticGoalPlanner.gd")
	var town_anchor_start := source.find("func town_anchor_candidates")
	var town_anchor_end := source.find("func job_anchor_candidates")
	var town_anchor_source := source.substr(town_anchor_start, town_anchor_end - town_anchor_start)
	var result := select_and_plan(entry("Trader", { "job": "" }), NpcEnumsScript.SCHEDULE_STATE_DAY)
	var actions: Array = result.plan.get("actionIds", [])
	var passed: bool = result.goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_IDLE and actions.has("relocate_semantic_anchor") and town_anchor_source.find("add_deterministic_ring_candidates") < 0
	return outcome(passed, "idle actions=%s ringInIdle=%s" % [JSON.stringify(actions), str(town_anchor_source.find("add_deterministic_ring_candidates") >= 0)], ["idle_goal", "semantic_anchor_action", "no_ring_idle_candidates"], result)

func test_dusk_civilian_returns_before_night(_mode: String) -> Dictionary:
	var result := select_and_plan(entry("Villager", { "job": "" }), NpcEnumsScript.SCHEDULE_STATE_DUSK)
	var passed: bool = result.goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_HOME and result.plan.get("actionIds", []).has("navigate_home_approach")
	return outcome(passed, "goal=%s actions=%s" % [String(result.goal.get("goalKind")), JSON.stringify(result.plan.get("actionIds", []))], ["dusk_home_goal", "home_plan_started"], result)

func test_dusk_guard_reports_to_duty(_mode: String) -> Dictionary:
	var result := select_and_plan(entry("Guard", { "job": "guard", "canFight": true, "nightGuard": true }), NpcEnumsScript.SCHEDULE_STATE_DUSK)
	var passed: bool = result.goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_GUARD and result.schedule.get("activeGuardDuty") == true
	return outcome(passed, "goal=%s activeGuard=%s" % [String(result.goal.get("goalKind")), str(result.schedule.get("activeGuardDuty"))], ["dusk_guard_goal", "active_guard_duty"], result)

func test_night_assigned_guard_outside(_mode: String) -> Dictionary:
	var entry_data := entry("Guard", { "job": "guard", "canFight": true, "nightGuard": true })
	var schedule_data := schedule_for(entry_data, NpcEnumsScript.SCHEDULE_STATE_NIGHT)
	var compliance: Dictionary = { "insideHome": false, "onPorch": false, "onThreshold": false }
	var result := perception_compliance(entry_data, schedule_data, compliance)
	var passed: bool = bool(result.compliance.get("ok", false)) and String(result.compliance.get("reason", "")) == "assigned_guard_outside"
	return outcome(passed, JSON.stringify(result.compliance), ["assigned_guard_outside_ok"], result)

func test_night_off_duty_guard_inside(_mode: String) -> Dictionary:
	return expect_night_home_inside(entry("Guard", { "job": "guard", "canFight": true, "nightGuard": false }), "off_duty_guard")

func test_night_fighter_non_guard_inside(_mode: String) -> Dictionary:
	return expect_night_home_inside(entry("Hunter", { "job": "", "canFight": true, "nightGuard": false }), "fighter_non_guard")

func test_night_worker_inside(_mode: String) -> Dictionary:
	return expect_night_home_inside(entry("Carpenter", { "job": "wood" }), "worker")

func test_night_forager_inside(_mode: String) -> Dictionary:
	return expect_night_home_inside(entry("Forager", { "job": "forage" }), "forager")

func test_night_trader_inside(_mode: String) -> Dictionary:
	return expect_night_home_inside(entry("Trader", { "job": "" }), "trader")

func test_night_porch_not_inside(_mode: String) -> Dictionary:
	var entry_data := entry("Villager", { "position": Vector3(1.35, 0.0, 0.0), "porchCell": Vector2i(1, 0), "homeCell": Vector2i(0, 0) })
	var result := perception_compliance(entry_data, schedule_for(entry_data, NpcEnumsScript.SCHEDULE_STATE_NIGHT), { "insideHome": false, "onPorch": true, "onThreshold": false })
	var passed: bool = not bool(result.compliance.get("ok", true)) and String(result.compliance.get("reason", "")) == "porch_not_inside"
	return outcome(passed, JSON.stringify(result.compliance), ["porch_not_inside"], result)

func test_night_threshold_not_inside(_mode: String) -> Dictionary:
	var entry_data := entry("Villager", { "position": Vector3(1.35, 0.0, 0.0), "porchCell": Vector2i(1, 0), "homeCell": Vector2i(0, 0) })
	var result := perception_compliance(entry_data, schedule_for(entry_data, NpcEnumsScript.SCHEDULE_STATE_NIGHT), { "insideHome": false, "onPorch": true, "onThreshold": true })
	var passed: bool = not bool(result.compliance.get("ok", true)) and String(result.compliance.get("reason", "")) == "threshold_not_inside"
	return outcome(passed, JSON.stringify(result.compliance), ["threshold_not_inside"], result)

func test_night_blocked_home_explicit_failure_no_teleport(_mode: String) -> Dictionary:
	var entry_data := entry("Villager", { "position": Vector3(1.35, 0.0, 0.0), "porchCell": Vector2i(1, 0), "homeCell": Vector2i(0, 0) })
	var body := entry_data.get("body") as Node3D
	var before := body.global_position
	var terminal: Dictionary = recovery.mark_home_blocked(entry_data, "porch_not_inside")
	var passed: bool = bool(terminal.get("terminal", false)) and not bool(terminal.get("teleportUsed", true)) and body.global_position == before and not bool(entry_data.get("insideHome", true))
	return outcome(passed, "terminal=%s before=%s after=%s" % [JSON.stringify(terminal), str(before), str(body.global_position)], ["terminal_blocked_home", "no_teleport", "inside_false"], { "terminal": terminal })

func test_threat_exception_explicit(_mode: String) -> Dictionary:
	var result := select_and_plan(entry("Hunter", { "canFight": true, "nightGuard": false }), NpcEnumsScript.SCHEDULE_STATE_NIGHT, { "activeThreat": true, "threat": Node3D.new() })
	var passed: bool = result.goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_GUARD and String(result.goal.get("exceptionReason", "")) == "explicit_active_threat_exception"
	return outcome(passed, "goal=%s reason=%s" % [String(result.goal.get("goalKind")), String(result.goal.get("reason"))], ["threat_exception_goal", "explicit_reason"], compact_result(result))

func test_executor_decays_guard_cooldown(_mode: String) -> Dictionary:
	var fake_autonomy := FakeAutonomy.new()
	var fake_npc := FakeNpcSystem.new()
	var perception := NpcPerceptionServiceScript.new()
	perception.setup(fake_autonomy, fake_npc)
	var executor := NpcPlanExecutorScript.new()
	executor.setup(fake_autonomy, fake_npc, null, {
		"schedule": schedule,
		"guardRoster": roster,
		"perception": perception,
		"goalSelector": selector,
		"taskPlanner": planner,
		"recovery": recovery
	})
	var entry_data := entry("Guard", { "job": "guard", "canFight": true, "nightGuard": true })
	entry_data["blackboard"] = NpcBlackboardScript.new()
	entry_data["cooldown"] = 0.75
	executor.update_npc(entry_data, 0.25, 1.0)
	var cooldown_after := float(entry_data.get("cooldown", -1.0))
	var passed := absf(cooldown_after - 0.5) <= 0.001
	fake_autonomy.queue_free()
	fake_npc.queue_free()
	return outcome(passed, "cooldown %.2f -> %.2f" % [0.75, cooldown_after], ["executor_cooldown_decays"], { "cooldownAfter": cooldown_after })

func test_post_threat_schedule_restored(_mode: String) -> Dictionary:
	var result := select_and_plan(entry("Hunter", { "canFight": true, "nightGuard": false }), NpcEnumsScript.SCHEDULE_STATE_NIGHT, { "activeThreat": false })
	var passed: bool = result.goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_HOME and result.plan.get("actionIds", []).has("remain_inside")
	return outcome(passed, "goal=%s actions=%s" % [String(result.goal.get("goalKind")), JSON.stringify(result.plan.get("actionIds", []))], ["post_threat_home_goal", "home_plan_restored"], result)

func test_night_job_phase_does_not_override_home_motion(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Forager", { "job": "forage", "position": Vector3(2.7, 0.0, 0.0), "homeCell": Vector2i(0, 0), "porchCell": Vector2i(1, 0) })
	entry_data["jobPhase"] = "outbound"
	entry_data["jobTarget"] = Vector3(10.0, 0.0, 0.0)
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_HOME, "reason": "schedule_requires_interior" }
	entry_data["activeMotionSchedule"] = { "scheduleState": NpcEnumsScript.SCHEDULE_STATE_NIGHT, "mustBeInside": true }
	entry_data["activeMotionPerception"] = { "insideHome": false, "onPorch": true, "onThreshold": false }
	var body := entry_data.get("body") as Node3D
	var before := body.global_position
	var result: Dictionary = executor.advance_motion_npc(entry_data, 1.0 / 60.0, 1.0)
	var after := body.global_position
	var moved_toward_home := after.distance_to(entry_data.get("homePosition", Vector3.ZERO)) < before.distance_to(entry_data.get("homePosition", Vector3.ZERO))
	var passed: bool = fake_npc.moving_home_calls == 1 and bool(result.get("advanced", false)) and String(result.get("intentKind", "")) == "home" and moved_toward_home
	fake_npc.queue_free()
	return outcome(passed, "result=%s movingHome=%d before=%s after=%s" % [JSON.stringify(result), fake_npc.moving_home_calls, str(before), str(after)], ["night_home_goal_preempts_job_phase", "home_motion_moves_toward_interior"], { "result": result, "movingHomeCalls": fake_npc.moving_home_calls, "before": before, "after": after })

func test_day_job_phase_overrides_stale_home_motion(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Forager", { "job": "forage", "position": Vector3(2.7, 0.0, 0.0), "homeCell": Vector2i(0, 0), "porchCell": Vector2i(1, 0) })
	entry_data["jobPhase"] = "outbound"
	entry_data["jobTarget"] = Vector3(10.0, 0.0, 0.0)
	entry_data["jobTimer"] = 4.0
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_HOME, "reason": "schedule_requires_interior" }
	entry_data["activeMotionSchedule"] = { "scheduleState": NpcEnumsScript.SCHEDULE_STATE_NIGHT, "mustBeInside": true }
	entry_data["activeMotionPerception"] = { "insideHome": false, "onPorch": false, "onThreshold": false }
	var body := entry_data.get("body") as Node3D
	var before := body.global_position
	var result: Dictionary = executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var after := body.global_position
	var moved_toward_job := after.distance_to(entry_data.get("jobTarget", Vector3.ZERO)) < before.distance_to(entry_data.get("jobTarget", Vector3.ZERO))
	var passed: bool = fake_npc.moving_home_calls == 0 and bool(result.get("advanced", false)) and String(result.get("intentKind", "")) == "job" and moved_toward_job
	fake_npc.queue_free()
	return outcome(passed, "result=%s movingHome=%d before=%s after=%s" % [JSON.stringify(result), fake_npc.moving_home_calls, str(before), str(after)], ["day_job_goal_preempts_stale_home", "job_motion_moves_toward_target"], { "result": result, "movingHomeCalls": fake_npc.moving_home_calls, "before": before, "after": after })

func test_home_motion_stops_once_inside(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Forager", { "job": "forage", "position": Vector3(0.0, 0.0, 1.35), "homeCell": Vector2i(0, 0), "porchCell": Vector2i(0, 2) })
	entry_data["insideHome"] = true
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_HOME, "reason": "schedule_requires_interior" }
	entry_data["activeMotionSchedule"] = { "scheduleState": NpcEnumsScript.SCHEDULE_STATE_NIGHT, "mustBeInside": true }
	entry_data["activeMotionPerception"] = { "insideHome": true, "onPorch": false, "onThreshold": false }
	entry_data["pathWaypoints"] = [entry_data.get("porchPosition", Vector3.ZERO)]
	entry_data["routeCells"] = [entry_data.get("porchCell", Vector2i.ZERO)]
	var body := entry_data.get("body") as Node3D
	var before := body.global_position
	var result: Dictionary = executor.advance_motion_npc(entry_data, 1.0 / 60.0, 1.0)
	var after := body.global_position
	var passed: bool = fake_npc.move_calls == 0 and before == after and String(result.get("routeStatus", "")) == "arrived" and (entry_data.get("pathWaypoints", []) as Array).is_empty()
	fake_npc.queue_free()
	return outcome(passed, "result=%s moveCalls=%d before=%s after=%s" % [JSON.stringify(result), fake_npc.move_calls, str(before), str(after)], ["inside_home_stops_motion", "inside_home_clears_route"], { "result": result, "moveCalls": fake_npc.move_calls, "before": before, "after": after })

func test_goal_hysteresis_no_thrashing(_mode: String) -> Dictionary:
	var entry_data := entry("Trader", { "job": "" })
	var blackboard = NpcBlackboardScript.new()
	var schedule_data := schedule_for(entry_data, NpcEnumsScript.SCHEDULE_STATE_DAY)
	var perception := default_perception()
	var first: Dictionary = selector.select_goal(null, blackboard, entry_data, perception, schedule_data)
	var second: Dictionary = selector.select_goal(null, blackboard, entry_data, perception, schedule_data)
	var passed: bool = first.get("goalKind") == second.get("goalKind") and float(second.get("utilityBreakdown", {}).get("hysteresisMargin", 0.0)) > 0.0
	return outcome(passed, "first=%s second=%s" % [String(first.get("goalKind")), String(second.get("goalKind"))], ["stable_goal_reselection", "hysteresis_logged"], { "first": first, "second": second })

func test_action_interrupt_releases_resources(_mode: String) -> Dictionary:
	var fake_autonomy := FakeAutonomy.new()
	var executor := NpcPlanExecutorScript.new()
	executor.setup(fake_autonomy, FakeNpcSystem.new(), null, {
		"schedule": schedule,
		"guardRoster": roster,
		"perception": null,
		"goalSelector": selector,
		"taskPlanner": planner,
		"recovery": recovery
	})
	var entry_data := entry("Villager", {})
	entry_data["blackboard"] = NpcBlackboardScript.new()
	executor.call("_release_action_owned_state", entry_data, "test_interrupt")
	var passed: bool = fake_autonomy.traffic_releases == 1 and fake_autonomy.door_releases == 1 and entry_data.get("activeDoorTrafficGroupId", "") == ""
	fake_autonomy.queue_free()
	return outcome(passed, "traffic=%d door=%d" % [fake_autonomy.traffic_releases, fake_autonomy.door_releases], ["traffic_released", "door_hold_released"], { "traffic": fake_autonomy.traffic_releases, "door": fake_autonomy.door_releases })

func test_scripted_order_priority_and_cancel(_mode: String) -> Dictionary:
	var entry_data := entry("Villager", {})
	var active: Dictionary = select_and_plan(entry_data, NpcEnumsScript.SCHEDULE_STATE_DAY, { "scriptedOrder": true })
	var after_cancel: Dictionary = select_and_plan(entry_data, NpcEnumsScript.SCHEDULE_STATE_DAY, { "scriptedOrder": false })
	var passed: bool = active.goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_SCRIPTED and after_cancel.goal.get("goalKind") != NpcEnumsScript.GOAL_KIND_SCRIPTED
	return outcome(passed, "active=%s cancel=%s" % [String(active.goal.get("goalKind")), String(after_cancel.goal.get("goalKind"))], ["scripted_priority", "scripted_cancel_restores_selector"], { "active": active, "afterCancel": after_cancel })

func test_scripted_order_go_home_uses_route_stack(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Villager", { "id": "mira", "position": Vector3.ZERO, "homeCell": Vector2i(1, 0), "homePosition": Vector3(0.22, 0.0, 0.0) })
	var body := entry_data.get("body") as Node3D
	set_scripted_order_meta(entry_data, body, "go_home", "intro_acknowledged_return_home")
	for i in range(8):
		executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var order: Dictionary = entry_data.get("scriptedOrder", {})
	var passed: bool = fake_npc.move_calls > 0 and fake_npc.moving_home_calls == fake_npc.move_calls and not body.has_meta("npc_scripted_target") and String(order.get("state", "")) in ["ACTIVE", "ARRIVED"]
	fake_npc.queue_free()
	return outcome(passed, "moveCalls=%d homeCalls=%d targetMeta=%s order=%s" % [fake_npc.move_calls, fake_npc.moving_home_calls, str(body.has_meta("npc_scripted_target")), JSON.stringify(order)], ["go_home_uses_home_route", "go_home_no_scripted_target", "order_state_recorded"], { "order": order })

func test_scripted_go_home_arrival_clears_cached_motion(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Villager", { "id": "go_home_done", "position": Vector3.ZERO, "homeCell": Vector2i(6, 0), "homePosition": Vector3(8.1, 0.0, 0.0) })
	var body := entry_data.get("body") as Node3D
	entry_data["activeGoalKind"] = "home"
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_HOME, "reason": "scripted_go_home_order" }
	entry_data["activeMotionSchedule"] = { "scheduleState": NpcEnumsScript.SCHEDULE_STATE_DAY, "mustBeInside": false }
	entry_data["scriptedOrder"] = { "kind": "go_home", "state": "ARRIVED", "reason": "home_interior_reached" }
	body.set_meta("npc_scripted_order_kind", "go_home")
	body.set_meta("npc_scripted_order_state", "ARRIVED")
	body.set_meta("npc_scripted_order_reason", "home_interior_reached")
	var result: Dictionary = executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var passed: bool = fake_npc.move_calls == 0 and String(result.get("reason", "")) == "idle_no_anchor"
	fake_npc.queue_free()
	return outcome(
		passed,
		"moveCalls=%d result=%s" % [fake_npc.move_calls, JSON.stringify(result)],
		["completed_go_home_cache_not_reused", "completed_go_home_does_not_walk_back_out"],
		{ "moveCalls": fake_npc.move_calls, "result": result }
	)

func test_scripted_go_home_hold_arrival_stays_home(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Villager", { "id": "go_home_hold", "position": Vector3.ZERO, "homeCell": Vector2i(0, 0), "homePosition": Vector3.ZERO })
	var body := entry_data.get("body") as Node3D
	entry_data["insideHome"] = true
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_IDLE, "reason": "highest_utility" }
	entry_data["scriptedOrder"] = { "kind": "go_home", "state": "ARRIVED", "reason": "home_interior_reached", "holdOnArrival": true }
	body.set_meta("npc_inside_home", true)
	body.set_meta("npc_scripted_order_kind", "go_home")
	body.set_meta("npc_scripted_order_state", "ARRIVED")
	body.set_meta("npc_scripted_order_reason", "home_interior_reached")
	body.set_meta("npc_scripted_hold_on_arrival", true)
	var result: Dictionary = executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var order: Dictionary = entry_data.get("scriptedOrder", {})
	var passed: bool = fake_npc.move_calls == 0 and bool(result.get("advanced", false)) and String(result.get("intentKind", "")) == "home" and String(order.get("state", "")) == "ARRIVED"
	fake_npc.queue_free()
	return outcome(
		passed,
		"moveCalls=%d result=%s order=%s" % [fake_npc.move_calls, JSON.stringify(result), JSON.stringify(order)],
		["held_go_home_arrival_keeps_home_goal", "held_go_home_does_not_resume_idle"],
		{ "moveCalls": fake_npc.move_calls, "result": result, "order": order }
	)

func test_scripted_order_normal_profile_speed(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Villager", { "id": "scripted_speed", "position": Vector3.ZERO })
	var body := entry_data.get("body") as Node3D
	set_scripted_order_meta(entry_data, body, "go_to", "speed_check", Vector3(3.0, 0.0, 0.0))
	for i in range(4):
		executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var source := read_text("res://scripts/npc_ai/behavior/NpcPlanExecutor.gd") + "\n" + read_text("res://scripts/NpcSystem.gd")
	var no_hack_speed := source.find("speed = 20.0") < 0 and not text_contains_near(source, "holdIntroDoor", "speed", 160) and not text_contains_near(source, "speed", "holdIntroDoor", 160)
	var profile_speed_ok := fake_npc.max_requested_distance <= (2.6 * (1.0 / 60.0)) + 0.0001
	var passed: bool = fake_npc.move_calls == 4 and profile_speed_ok and no_hack_speed
	fake_npc.queue_free()
	return outcome(passed, "moveCalls=%d maxDistance=%.4f noHack=%s" % [fake_npc.move_calls, fake_npc.max_requested_distance, str(no_hack_speed)], ["normal_scripted_speed", "no_20_speed_override"], { "maxRequestedDistance": fake_npc.max_requested_distance })

func test_scripted_order_sprint_profile_speed(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Villager", { "id": "scripted_sprint_speed", "position": Vector3.ZERO })
	var body := entry_data.get("body") as Node3D
	set_scripted_order_meta(entry_data, body, "go_to", "speed_check", Vector3(3.0, 0.0, 0.0), "sprinting")
	for i in range(4):
		executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var lower_bound_ok := fake_npc.max_requested_distance >= (6.4 * (1.0 / 60.0)) - 0.0001
	var mode_ok := String(entry_data.get("npcSpeedMode", "")) == "sprinting" and bool(entry_data.get("npcRushing", false))
	var passed: bool = fake_npc.move_calls == 4 and lower_bound_ok and mode_ok
	fake_npc.queue_free()
	return outcome(passed, "moveCalls=%d maxDistance=%.4f mode=%s" % [fake_npc.move_calls, fake_npc.max_requested_distance, String(entry_data.get("npcSpeedMode", ""))], ["scripted_sprint_speed", "scripted_rushing_mode"], { "maxRequestedDistance": fake_npc.max_requested_distance, "mode": entry_data.get("npcSpeedMode", "") })

func test_scripted_order_no_transform_write(_mode: String) -> Dictionary:
	var source := read_text("res://scripts/NpcSystem.gd")
	var start := source.find("func update_scripted_npc")
	var end := source.find("func update_fighter_target", start)
	var update_source := source.substr(start, end - start)
	var passed: bool = update_source.find("global_position =") < 0 and update_source.find("position =") < 0 and update_source.find("move_npc(") >= 0
	return outcome(passed, "usesMove=%s directGlobal=%s directPosition=%s" % [str(update_source.find("move_npc(") >= 0), str(update_source.find("global_position =") >= 0), str(update_source.find("position =") >= 0)], ["scripted_order_uses_move_npc", "scripted_order_no_transform_assignment"], {})

func test_mira_dialogue_ack_releases_go_home_order(_mode: String) -> Dictionary:
	var tutorial_source := read_text("res://scripts/TutorialSystem.gd")
	var npc_source := read_text("res://scripts/NpcSystem.gd")
	var has_ack_hook := tutorial_source.find("release_intro_elder_home_order") >= 0 and tutorial_source.find("intro_acknowledged_return_home") >= 0 and tutorial_source.find("order_go_home") >= 0
	var has_order_api := npc_source.find("func order_go_home") >= 0 and npc_source.find("func order_resume_schedule") >= 0 and npc_source.find("func cancel_order") >= 0
	var passed: bool = has_ack_hook and has_order_api
	return outcome(passed, "ackHook=%s api=%s" % [str(has_ack_hook), str(has_order_api)], ["dialogue_ack_orders_mira_home", "scripted_order_api_present"], {})

func test_mira_home_arrival_requires_interior(_mode: String) -> Dictionary:
	var source := read_text("res://scripts/NpcSystem.gd")
	var start := source.find("func settle_home_if_reached")
	var end := source.find("func mark_npc_home_blocked", start)
	var settle_source := source.substr(start, end - start)
	var has_interior_check := settle_source.find("is_inside_home_interior") >= 0
	var porch_blocked := settle_source.find("home_porch_fallback_not_inside") >= 0
	var passed: bool = has_interior_check and porch_blocked
	return outcome(passed, "interiorCheck=%s porchBlocked=%s" % [str(has_interior_check), str(porch_blocked)], ["mira_home_requires_interior_semantics", "porch_fallback_not_inside"], {})

func test_hold_intro_door_not_speed_override(_mode: String) -> Dictionary:
	var source := read_text("res://scripts/NpcSystem.gd") + "\n" + read_text("res://scripts/npc_ai/behavior/NpcPlanExecutor.gd") + "\n" + read_text("res://scripts/TutorialSystem.gd") + "\n" + read_text("res://scripts/TutorialDialogueSystem.gd")
	var forbidden := source.find("speed = 20.0") >= 0 or text_contains_near(source, "holdIntroDoor", "speed", 160) or text_contains_near(source, "speed", "holdIntroDoor", 160)
	var hold_still_state_only := source.find("holdIntroDoor") >= 0 and source.find("npc_is_held_by_intro_or_dialogue") >= 0
	var passed: bool = not forbidden and hold_still_state_only
	return outcome(passed, "forbidden=%s holdStateOnly=%s" % [str(forbidden), str(hold_still_state_only)], ["hold_intro_door_not_speed", "hold_intro_door_state_only"], {})

func test_every_active_actor_motion_tick_32_npcs(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entries: Array[Dictionary] = []
	for i in range(32):
		var entry_data := entry("Villager", { "id": "cadence_%02d" % i, "position": Vector3(float(i) * 0.05, 0.0, 0.0) })
		var body := entry_data.get("body") as Node3D
		body.set_meta("npc_scripted_target", body.global_position + Vector3(1.0, 0.0, 0.0))
		entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_SCRIPTED }
		entries.append(entry_data)
	for entry_data in entries:
		executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var source := read_text("res://scripts/NpcSystem.gd")
	var active_pass_index := source.find("var active_entries")
	var budget_loop_index := source.find("while scanned < update_count and processed < budget")
	var motion_pass_index := source.find("advance_npc_motion", budget_loop_index)
	var source_split_ok := active_pass_index >= 0 and budget_loop_index > active_pass_index and motion_pass_index > budget_loop_index
	var telemetry_source := read_text("res://scripts/npc_ai/debug/NpcTelemetryService.gd")
	var counters_ok := telemetry_source.find("npc_brain_updates") >= 0 and telemetry_source.find("npc_motion_updates") >= 0 and telemetry_source.find("npc_brain_budget_skipped") >= 0 and telemetry_source.find("npc_door_action_motion_ticks") >= 0
	var passed: bool = fake_npc.move_calls == 32 and fake_npc.moved_actor_ids.size() == 32 and source_split_ok and counters_ok
	fake_npc.queue_free()
	return outcome(passed, "moveCalls=%d actors=%d sourceSplit=%s counters=%s" % [fake_npc.move_calls, fake_npc.moved_actor_ids.size(), str(source_split_ok), str(counters_ok)], ["all_32_active_motion_ticks", "motion_pass_outside_budget_loop", "r02_motion_counters_present"], { "moveCalls": fake_npc.move_calls, "actors": fake_npc.moved_actor_ids.size(), "countersOk": counters_ok })

func test_brain_budget_does_not_skip_route_motion(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Villager", { "position": Vector3.ZERO, "homeCell": Vector2i(4, 0), "homePosition": Vector3(5.4, 0.0, 0.0) })
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_HOME }
	entry_data["activeMotionPerception"] = { "insideHome": false, "onPorch": false, "onThreshold": false }
	for i in range(6):
		executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var body := entry_data.get("body") as Node3D
	var distance := body.global_position.length()
	var passed: bool = fake_npc.move_calls == 6 and distance > 0.20
	fake_npc.queue_free()
	return outcome(passed, "moveCalls=%d distance=%.3f" % [fake_npc.move_calls, distance], ["brain_skip_route_motion_continues", "route_distance_accumulates"], { "moveCalls": fake_npc.move_calls, "distance": distance })

func test_scripted_order_moves_while_brain_skipped(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Villager", { "position": Vector3.ZERO })
	var body := entry_data.get("body") as Node3D
	body.set_meta("npc_scripted_target", Vector3(2.0, 0.0, 0.0))
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_SCRIPTED }
	for i in range(4):
		executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var passed: bool = bool(entry_data.get("scriptedUpdated", false)) and fake_npc.move_calls == 4 and body.global_position.x > 0.15
	fake_npc.queue_free()
	return outcome(passed, "moveCalls=%d x=%.3f" % [fake_npc.move_calls, body.global_position.x], ["scripted_order_motion_without_brain", "scripted_position_advances"], { "moveCalls": fake_npc.move_calls, "position": body.global_position })

func test_mira_no_inching_after_dialogue(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Villager", { "id": "mira", "position": Vector3.ZERO })
	var body := entry_data.get("body") as Node3D
	body.set_meta("npc_scripted_target", Vector3(3.0, 0.0, 0.0))
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_SCRIPTED }
	var moving_frames := 0
	for i in range(8):
		executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
		if float(entry_data.get("lastMoveDistance", 0.0)) > 0.001:
			moving_frames += 1
	var passed: bool = moving_frames == 8 and body.global_position.x > 0.33
	fake_npc.queue_free()
	return outcome(passed, "movingFrames=%d x=%.3f" % [moving_frames, body.global_position.x], ["mira_like_every_frame_motion", "mira_like_no_inching"], { "movingFrames": moving_frames, "position": body.global_position })

func test_morning_departures_not_brain_starved(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Carpenter", { "job": "wood", "position": Vector3.ZERO })
	entry_data["jobPhase"] = "outbound"
	entry_data["jobTarget"] = Vector3(4.0, 0.0, 0.0)
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_WORK }
	for i in range(10):
		executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var body := entry_data.get("body") as Node3D
	var passed: bool = fake_npc.move_calls == 10 and body.global_position.x > 0.42 and String(entry_data.get("routeStatus", "moving")) != "idle"
	fake_npc.queue_free()
	return outcome(passed, "moveCalls=%d x=%.3f route=%s" % [fake_npc.move_calls, body.global_position.x, String(entry_data.get("routeStatus", ""))], ["morning_job_motion_every_frame", "morning_departure_not_brain_starved"], { "moveCalls": fake_npc.move_calls, "position": body.global_position, "routeStatus": entry_data.get("routeStatus", "") })

func test_idle_worker_exits_home_clearance(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var fake_autonomy := FakeAutonomy.new()
	var portal_service := FakeDoorPortalService.new()
	portal_service.portals["door:test"] = {
		"leaf_cells": [Vector2i(0, 0), Vector2i(0, -1)],
		"threshold_bounds": AABB(Vector3(-0.675, -1.0, -0.675), Vector3(1.35, 3.0, 1.35)),
		"clearance_bounds": AABB(Vector3(-0.675, -1.0, 0.675), Vector3(1.35, 3.0, 1.35)),
		"sweep_bounds": AABB()
	}
	fake_autonomy.door_portals = portal_service
	fake_npc.add_child(fake_autonomy)
	var executor: Variant = make_executor(fake_npc, fake_autonomy)
	var entry_data := entry("Mason", {
		"job": "stone",
		"position": Vector3(0.0, 0.0, 1.35),
		"homeCell": Vector2i(0, 2),
		"porchCell": Vector2i(0, -1)
	})
	entry_data["doorCell"] = Vector2i(0, 0)
	entry_data["interiorMinCell"] = Vector2i(-1, 1)
	entry_data["interiorMaxCell"] = Vector2i(1, 3)
	entry_data["interiorLandingCell"] = Vector2i(0, 1)
	entry_data["jobPhase"] = "idle"
	entry_data["jobTimer"] = 0.05
	entry_data["jobTarget"] = Vector3(0.0, 0.0, -1.35)
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_WORK }
	var body := entry_data.get("body") as Node3D
	var before := body.global_position
	var result: Dictionary = executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var after := body.global_position
	var passed: bool = fake_npc.move_calls == 1 \
		and bool(result.get("advanced", false)) \
		and String(result.get("reason", "")) == "job_idle_home_exit" \
		and String(result.get("intentKind", "")) == "job" \
		and after.z < before.z \
		and String(entry_data.get("jobPhase", "")) == "idle"
	fake_npc.queue_free()
	return outcome(
		passed,
		"result=%s moveCalls=%d before=%s after=%s" % [JSON.stringify(result), fake_npc.move_calls, str(before), str(after)],
		["idle_worker_in_door_clearance_moves_outward", "job_idle_not_frozen_at_home_threshold"],
		{ "result": result, "moveCalls": fake_npc.move_calls, "before": before, "after": after, "jobPhase": entry_data.get("jobPhase", "") }
	)

func test_job_selection_budget_ages_deferred_workers(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var blockers: Array[Dictionary] = []
	for i in range(3):
		var blocker := entry("Mason", {
			"id": "blocker_%d" % i,
			"job": "stone",
			"position": Vector3(2.7 + float(i), 0.0, 0.0),
			"homeCell": Vector2i(-10 - i, 0),
			"porchCell": Vector2i(-9 - i, 0)
		})
		blocker["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_WORK }
		blockers.append(blocker)
	var victim := entry("Carpenter", {
		"id": "victim_worker",
		"job": "wood",
		"position": Vector3(10.8, 0.0, 0.0),
		"homeCell": Vector2i(-20, 0),
		"porchCell": Vector2i(-19, 0)
	})
	victim["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_WORK }
	var selected_frame := -1
	for frame in range(24):
		executor.begin_update_frame()
		for blocker in blockers:
			blocker["jobPhase"] = "idle"
			blocker["jobTimer"] = 0.0
			executor.advance_motion_npc(blocker, 1.0 / 60.0, 0.0)
		if String(victim.get("jobPhase", "idle")) == "idle":
			victim["jobTimer"] = minf(float(victim.get("jobTimer", 0.0)), 0.0)
		executor.advance_motion_npc(victim, 1.0 / 60.0, 0.0)
		if String(victim.get("jobPhase", "idle")) != "idle":
			selected_frame = frame
			break
	var passed := selected_frame >= 0 and selected_frame <= 14 and String(victim.get("jobPhase", "")) == "searching"
	fake_npc.queue_free()
	return outcome(
		passed,
		"selectedFrame=%d phase=%s deferred=%d" % [selected_frame, String(victim.get("jobPhase", "")), int(victim.get("jobSelectionDeferredFrames", -1))],
		["deferred_job_selection_ages", "late_worker_gets_job_turn"],
		{ "selectedFrame": selected_frame, "phase": victim.get("jobPhase", ""), "deferredFrames": victim.get("jobSelectionDeferredFrames", -1) }
	)

func test_resource_worker_outbound_stays_town_bound(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Mason", {
		"job": "stone",
		"position": Vector3(10.8, 0.0, 0.0),
		"homeCell": Vector2i(-10, 0),
		"porchCell": Vector2i(-9, 0)
	})
	entry_data["jobPhase"] = "outbound"
	entry_data["jobTarget"] = Vector3(13.5, 0.0, 0.0)
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_WORK }
	executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var body := entry_data.get("body") as Node3D
	var passed: bool = fake_npc.move_calls == 1 and not fake_npc.last_allow_outside and fake_npc.allow_outside_calls == 0 and body.global_position.x > 0.0
	fake_npc.queue_free()
	return outcome(
		passed,
		"moveCalls=%d allowOutside=%s x=%.3f" % [fake_npc.move_calls, str(fake_npc.last_allow_outside), body.global_position.x],
		["stone_worker_outbound_uses_town_route_permission", "resource_worker_route_stays_town_bound"],
		{ "moveCalls": fake_npc.move_calls, "allowOutsideCalls": fake_npc.allow_outside_calls, "position": body.global_position }
	)

func test_forager_outbound_allows_outside(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Forager", { "job": "forage", "position": Vector3.ZERO })
	entry_data["jobPhase"] = "outbound"
	entry_data["jobTarget"] = Vector3(42.0, 0.0, 0.0)
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_FORAGE }
	executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var body := entry_data.get("body") as Node3D
	var passed: bool = fake_npc.move_calls == 1 and fake_npc.last_allow_outside and fake_npc.allow_outside_calls == 1 and body.global_position.x > 0.0
	fake_npc.queue_free()
	return outcome(
		passed,
		"moveCalls=%d allowOutside=%s x=%.3f" % [fake_npc.move_calls, str(fake_npc.last_allow_outside), body.global_position.x],
		["forager_outbound_uses_outside_route_permission", "forager_route_can_leave_town"],
		{ "moveCalls": fake_npc.move_calls, "allowOutsideCalls": fake_npc.allow_outside_calls, "position": body.global_position }
	)

func test_door_crossing_continues_while_brain_skipped(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Villager", { "position": Vector3(-1.0, 0.0, 0.0), "homeCell": Vector2i(2, 0), "homePosition": Vector3(2.7, 0.0, 0.0) })
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_HOME }
	entry_data["activeDoorPortalId"] = "door:test"
	entry_data["activeTrafficStepGroup"] = "movement:test"
	entry_data["activeDoorTrafficGroupId"] = "portal:test"
	var result: Dictionary = executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var passed: bool = fake_npc.move_calls == 1 and bool(result.get("advanced", false)) and String(result.get("classification", "")) == "door_state" and float(entry_data.get("lastMoveDistance", 0.0)) > 0.001
	fake_npc.queue_free()
	return outcome(passed, "result=%s moveCalls=%d" % [JSON.stringify(result), fake_npc.move_calls], ["door_motion_tick_without_brain", "traffic_state_preserved_during_motion"], { "result": result, "entry": { "door": entry_data.get("activeDoorPortalId", ""), "traffic": entry_data.get("activeTrafficStepGroup", "") } })

func test_motor_blocked_local_escape_forces_replan(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	fake_npc.motor_block_until_distance = CELL * 0.15
	var fake_main := FakeMain.new()
	var controller = NpcRouteMovementControllerScript.new()
	controller.setup(fake_npc, fake_main)
	var entry_data := entry("Villager", { "id": "motor_escape", "position": Vector3.ZERO })
	entry_data["corridorNoProgressTicks"] = 24
	entry_data["blockedMoveTime"] = CELL * 0.25
	entry_data["pathWaypoints"] = [Vector3(CELL * 2.0, 0.0, 0.0)]
	entry_data["_activeDoorForwardStep"] = true
	var follow := {
		"desiredVelocity": Vector3(2.45, 0.0, 0.0),
		"safeVelocity": Vector3(2.45, 0.0, 0.0)
	}
	var intent := {
		"target": Vector3(CELL * 4.0, 0.0, 0.0),
		"physicsDelta": 1.0 / 60.0,
		"movingHome": false,
		"allowOutside": true
	}
	var result: Dictionary = controller.try_motor_blocked_local_escape(entry_data, Vector3.ZERO, follow, intent, 2.45 / 60.0, FakeRouteWorld.new(), 100, "static_or_dynamic_collision")
	var body := entry_data.get("body") as Node3D
	var moved := body.global_position.length() if body != null else 0.0
	var passed := (
		String(result.get("reason", "")) == "motor_local_escape"
		and float(result.get("moved", 0.0)) >= CELL * 0.15
		and bool(entry_data.get("routeForceReplan", false))
		and fake_npc.route_motion_calls > 0
		and moved >= CELL * 0.15
	)
	fake_main.queue_free()
	fake_npc.queue_free()
	return outcome(passed, "result=%s moved=%.3f calls=%d replan=%s" % [JSON.stringify(result), moved, fake_npc.route_motion_calls, str(entry_data.get("routeForceReplan", false))], ["motor_local_escape_moves_actor", "motor_local_escape_forces_replan", "escape_uses_route_motion"], { "result": result, "moved": moved, "routeMotionCalls": fake_npc.route_motion_calls, "lastEscape": entry_data.get("lastMotorLocalEscape", {}) })

func test_unreachable_goal_terminal(_mode: String) -> Dictionary:
	var entry_data := entry("Villager", {})
	var terminal: Dictionary = recovery.mark_unreachable_goal(entry_data, "no_route")
	var passed: bool = bool(terminal.get("terminal", false)) and String(terminal.get("status", "")) == String(NpcEnumsScript.ROUTE_STATUS_UNREACHABLE)
	return outcome(passed, JSON.stringify(terminal), ["unreachable_terminal", "machine_reason"], { "terminal": terminal, "entryReason": entry_data.get("routeReason", "") })

func test_all_generated_town_npcs_have_interior_home(_mode: String) -> Dictionary:
	var source := read_text("res://scripts/NpcSystem.gd")
	var has_home_publish: bool = source.find("home_interior") >= 0 and source.find("publish_navigation_profile_semantics(entry)") >= 0
	var spawn_profile_home: bool = source.find("\"homeCell\": record.get(\"homeCell\"") >= 0 and source.find("\"porchCell\": porch_cell") >= 0
	var role_files := ["guard", "farmer", "carpenter", "forager", "mason", "trader", "civilian", "tutorial"]
	var missing := []
	for role_id in role_files:
		if not ResourceLoader.exists("res://resources/npc_roles/%s.tres" % role_id):
			missing.append(role_id)
	var passed: bool = has_home_publish and spawn_profile_home and missing.is_empty()
	return outcome(passed, "homePublish=%s spawnHome=%s missing=%s" % [str(has_home_publish), str(spawn_profile_home), JSON.stringify(missing)], ["home_semantics_published", "spawn_profile_home_cells", "role_resources_present"], { "missing": missing })

func test_no_raw_random_world_goal(_mode: String) -> Dictionary:
	var npc_source := read_text("res://scripts/NpcSystem.gd")
	var goal_source := read_text("res://scripts/npc_ai/behavior/NpcSemanticGoalPlanner.gd")
	var update_start := npc_source.find("func update_npc(entry")
	var update_end := npc_source.find("func npc_is_held_by_intro_or_dialogue")
	var update_source := npc_source.substr(update_start, update_end - update_start)
	var idle_start := goal_source.find("func town_anchor_candidates")
	var idle_end := goal_source.find("func job_anchor_candidates")
	var idle_source := goal_source.substr(idle_start, idle_end - idle_start)
	var delegates: bool = update_source.find("autonomy_system.update_npc") >= 0
	var removed_wander_method := "update_" + "wander_target"
	var removed_wander_timer := "wander" + "Timer"
	var no_raw_wander: bool = npc_source.find(removed_wander_method) < 0 and npc_source.find(removed_wander_timer) < 0
	var no_idle_ring: bool = idle_source.find("add_deterministic_ring_candidates") < 0
	var no_can_fight_guard: bool = read_text("res://scripts/NpcProfileRules.gd").find("if can_fight or role") < 0
	var passed: bool = delegates and no_raw_wander and no_idle_ring and no_can_fight_guard
	return outcome(passed, "delegates=%s noRawWander=%s noIdleRing=%s noCanFightGuard=%s" % [str(delegates), str(no_raw_wander), str(no_idle_ring), str(no_can_fight_guard)], ["executor_delegation", "raw_wander_removed", "idle_no_ring_candidates", "can_fight_not_guard_predicate"], {})

func expect_night_home_inside(entry_data: Dictionary, label: String) -> Dictionary:
	var result := select_and_plan(entry_data, NpcEnumsScript.SCHEDULE_STATE_NIGHT, { "insideHome": true })
	var compliance: Dictionary = perception_compliance(entry_data, result.schedule, { "insideHome": true, "onPorch": false, "onThreshold": false }).compliance
	var passed: bool = result.goal.get("goalKind") == NpcEnumsScript.GOAL_KIND_HOME and bool(compliance.get("ok", false))
	return outcome(passed, "%s goal=%s compliance=%s" % [label, String(result.goal.get("goalKind")), JSON.stringify(compliance)], ["night_home_goal", "%s_inside_ok" % label], { "goal": result.goal, "plan": result.plan, "compliance": compliance })

func select_and_plan(entry_data: Dictionary, state: StringName, overrides := {}, custom_planner = null) -> Dictionary:
	var blackboard = NpcBlackboardScript.new()
	var schedule_data := schedule_for(entry_data, state)
	var perception := default_perception()
	for key in overrides.keys():
		perception[key] = overrides[key]
	var goal: Dictionary = selector.select_goal(null, blackboard, entry_data, perception, schedule_data)
	var active_planner = custom_planner if custom_planner != null else planner
	var plan: Dictionary = active_planner.plan(goal, null, entry_data, perception, schedule_data)
	return { "goal": goal, "plan": plan, "schedule": schedule_data, "perception": perception }

func make_executor(fake_npc: FakeNpcSystem, fake_autonomy: Variant = null) -> Variant:
	var autonomy = fake_autonomy if fake_autonomy != null else FakeAutonomy.new()
	if fake_autonomy == null:
		fake_npc.add_child(autonomy)
	var perception := NpcPerceptionServiceScript.new()
	perception.setup(autonomy, fake_npc)
	var executor := NpcPlanExecutorScript.new()
	executor.setup(autonomy, fake_npc, null, {
		"schedule": schedule,
		"guardRoster": roster,
		"perception": perception,
		"goalSelector": selector,
		"taskPlanner": planner,
		"recovery": recovery
	})
	return executor

func schedule_for(entry_data: Dictionary, state: StringName) -> Dictionary:
	schedule.inject_snapshot({
		"timeOfDay": 0.75 if state == NpcEnumsScript.SCHEDULE_STATE_NIGHT else 0.25,
		"clockPhase": 0.0,
		"displayHour": 20.25 if state == NpcEnumsScript.SCHEDULE_STATE_NIGHT else 12.0,
		"scheduleState": state,
		"frozen": true
	})
	var snapshot: Dictionary = schedule.snapshot_for(null, entry_data, null)
	schedule.clear_injected_snapshot()
	return snapshot

func perception_compliance(entry_data: Dictionary, schedule_data: Dictionary, overrides := {}) -> Dictionary:
	var perception := default_perception()
	for key in overrides.keys():
		perception[key] = overrides[key]
	return { "perception": perception, "compliance": NpcPerceptionServiceScript.new().compliance(entry_data, perception, schedule_data) }

func default_perception() -> Dictionary:
	return {
		"insideHome": false,
		"onPorch": false,
		"onThreshold": false,
		"scriptedOrder": false,
		"scriptedHomeOrder": false,
		"scriptedOrderKind": "",
		"scriptedOrderState": "",
		"activeThreat": false,
		"threat": null
	}

func entry(role: String, options := {}) -> Dictionary:
	var body := CharacterBody3D.new()
	body.name = "BehaviorNPC_%s" % role
	if runner != null:
		runner.add_child(body)
	var position: Vector3 = options.get("position", Vector3.ZERO)
	body.global_position = position
	var home_cell: Vector2i = options.get("homeCell", Vector2i.ZERO)
	var porch_cell: Vector2i = options.get("porchCell", Vector2i(1, 0))
	var result := {
		"body": body,
		"id": String(options.get("id", "npc_%s" % role.to_lower())),
		"role": role,
		"job": String(options.get("job", "")),
		"canFight": bool(options.get("canFight", false)),
		"nightGuard": bool(options.get("nightGuard", false)),
		"homeCell": home_cell,
		"porchCell": porch_cell,
		"guardCell": options.get("guardCell", Vector2i(2, 0)),
		"homePosition": Vector3(float(home_cell.x) * 1.35, 0.0, float(home_cell.y) * 1.35),
		"porchPosition": Vector3(float(porch_cell.x) * 1.35, 0.0, float(porch_cell.y) * 1.35),
		"guardPosition": Vector3(2.7, 0.0, 0.0),
		"insideHome": false,
		"routeStatus": "idle",
		"routeReason": "",
		"personalInventory": {}
	}
	for optional_key in ["jobTarget", "jobTargetNode", "stallPosition", "tutorialActionPosition", "dayTarget", "guardTargetCache"]:
		if options.has(optional_key):
			result[optional_key] = options[optional_key]
	return result

func set_scripted_order_meta(entry_data: Dictionary, body: Node, kind: String, reason: String, target := Vector3.INF, speed_mode := "walking") -> void:
	entry_data["scriptedOrder"] = {
		"kind": kind,
		"state": "PENDING",
		"reason": reason,
		"target": target,
		"arrivalRadius": 0.45,
		"speedMode": speed_mode,
		"usesRouteStack": kind in ["go_to", "go_home"]
	}
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_HOME if kind == "go_home" else NpcEnumsScript.GOAL_KIND_SCRIPTED, "reason": reason }
	body.set_meta("npc_scripted_order_kind", kind)
	body.set_meta("npc_scripted_order_state", "PENDING")
	body.set_meta("npc_scripted_order_reason", reason)
	body.set_meta("npc_scripted_arrival_radius", 0.45)
	body.set_meta("npc_scripted_allow_outside", true)
	body.set_meta("npc_scripted_hold_on_arrival", true)
	body.set_meta("npc_scripted_speed_mode", speed_mode)
	if kind == "go_to":
		body.set_meta("npc_scripted_target", target)

func read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text

func text_contains_near(text: String, first: String, second: String, window: int) -> bool:
	var cursor := 0
	while true:
		var first_index := text.find(first, cursor)
		if first_index < 0:
			return false
		var second_index := text.find(second, first_index)
		if second_index >= 0 and second_index - first_index <= window:
			return true
		cursor = first_index + first.length()
	return false

func compact_result(result: Dictionary) -> Dictionary:
	var copy := result.duplicate(true)
	if copy.has("perception") and copy["perception"] is Dictionary:
		copy["perception"]["threat"] = copy["perception"].get("threat") != null
	return copy

func outcome(passed: bool, details: String, assertions: Array, key_state: Dictionary) -> Dictionary:
	return runner.outcome(passed, details, assertions, key_state) if runner != null else {
		"passed": passed,
		"details": details,
		"assertions": assertions,
		"keyState": key_state
	}
