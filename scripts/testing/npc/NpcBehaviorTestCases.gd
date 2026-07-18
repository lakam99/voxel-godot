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
const NpcRouteAuthorityV2Script := preload("res://scripts/npc_ai/routing/NpcRouteAuthorityV2.gd")
const NpcSimulationLodServiceScript := preload("res://scripts/npc_ai/lifecycle/NpcSimulationLodService.gd")
const HostileSystemScript := preload("res://scripts/HostileSystem.gd")
const NpcCombatScript := preload("res://scripts/NpcCombat.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
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
	var route_authority_v2 = null
	var route_world = null

	func release_npc_traffic_reservations(_entry, _reason := "released") -> int:
		traffic_releases += 1
		return 1

	func release_npc_door_hold(_actor_or_id, _schedule_close := true) -> void:
		door_releases += 1

	func generated_navigation_adapter():
		return route_world

	func is_inside_home_interior(entry: Dictionary, position: Vector3) -> bool:
		var home_cell: Vector2i = entry.get("homeCell", Vector2i.ZERO)
		var min_cell: Vector2i = entry.get("interiorMinCell", home_cell)
		var max_cell: Vector2i = entry.get("interiorMaxCell", home_cell)
		var cell := Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))
		return cell.x >= mini(min_cell.x, max_cell.x) \
			and cell.x <= maxi(min_cell.x, max_cell.x) \
			and cell.y >= mini(min_cell.y, max_cell.y) \
			and cell.y <= maxi(min_cell.y, max_cell.y)

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

class FakeCollisionProbe:
	extends RefCounted

	func setup(_system_node, _main_node) -> void:
		pass

	func probe_route(_entry: Dictionary, route: Dictionary, _intent: Dictionary, _options := {}) -> Dictionary:
		var waypoints: Array = route.get("waypoints", []) if route.get("waypoints", []) is Array else []
		return {
			"ok": not waypoints.is_empty(),
			"status": "passed" if not waypoints.is_empty() else "invalid_goal",
			"reason": "" if not waypoints.is_empty() else "empty_waypoints",
			"authoritative": true,
			"sampleCount": maxi(1, waypoints.size()),
			"details": {
				"pointCount": waypoints.size(),
				"testProbe": true
			}
		}

class FakeMain:
	extends Node
	const WATER_LEVEL := -100.0

	func surface_y_at_position(_position: Vector3) -> float:
		return 0.0

class FakeHostileClockMain:
	extends Node
	var day_factor := 1.0

	func clock_day_factor() -> float:
		return day_factor

class FakeRouteWorld:
	extends RefCounted

	func point_allowed(_entry: Dictionary, _position: Vector3, _allow_outside := false, _moving_home := false) -> bool:
		return true

	func world_cell(position: Vector3) -> Vector2i:
		return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

	func cell_position(cell: Vector2i) -> Vector3:
		return Vector3(float(cell.x) * CELL, 0.0, float(cell.y) * CELL)

	func point_inside_town(entry: Dictionary, position: Vector3) -> bool:
		var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
		var radius := float(entry.get("townRadius", 18)) * CELL
		var flat := Vector2(position.x - float(center.x) * CELL, position.z - float(center.y) * CELL)
		return flat.length() <= radius

	func point_inside_work_area(entry: Dictionary, position: Vector3) -> bool:
		var center: Vector2i = entry.get("townCenter", Vector2i.ZERO)
		var radius_cells := float(entry.get("townRadius", 18))
		if String(entry.get("job", "")) == "forage":
			radius_cells += 24.0
		var flat := Vector2(position.x - float(center.x) * CELL, position.z - float(center.y) * CELL)
		return flat.length() <= radius_cells * CELL

	func approach_cells_for_target(_entry: Dictionary, target_position: Vector3, _allow_outside := true) -> Array[Vector2i]:
		var center := world_cell(target_position)
		return [
			center,
			center + Vector2i(1, 0),
			center + Vector2i(-1, 0),
			center + Vector2i(0, 1),
			center + Vector2i(0, -1)
		]

	func cell_is_standable_goal(_entry: Dictionary, _cell: Vector2i, _allow_outside := false, _moving_home := false) -> bool:
		return true

	func terrain_allows_step(_from_cell: Vector2i, _to_cell: Vector2i, _moving_home := false) -> Dictionary:
		return { "ok": true, "height": 0.0 }

	func build_snapshot(_entry: Dictionary, allow_outside := false, moving_home := false) -> Dictionary:
		return {
			"allowOutside": allow_outside,
			"movingHome": moving_home,
			"revision": "fake-route-world",
			"blocked": {},
			"dynamic": {},
			"doors": {},
			"paths": {}
		}

	func cached_validation_snapshot(entry: Dictionary, allow_outside := false, moving_home := false) -> Dictionary:
		return build_snapshot(entry, allow_outside, moving_home)

	func static_blocker(_snapshot: Dictionary, _cell: Vector2i):
		return null

	func dynamic_blocker(_snapshot: Dictionary, _cell: Vector2i):
		return null

	func static_collision_blocker(_snapshot: Dictionary, _cell: Vector2i) -> Dictionary:
		return {}

	func cell_transition_pathable(_entry: Dictionary, _snapshot: Dictionary, _from_cell: Vector2i, _to_cell: Vector2i, _target_lookup := {}, _ignore_dynamic := false) -> Dictionary:
		return { "ok": true, "reason": "" }

	func revision() -> String:
		return "fake-route-world"

	func cell_key(cell: Vector2i) -> String:
		return "%d,%d" % [cell.x, cell.y]

class FakeGuardTargetWorld:
	extends RefCounted
	var snapshot_calls := 0
	var static_goal_checks := 0
	var cell_position_calls := 0

	func world_cell(position: Vector3) -> Vector2i:
		return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

	func cell_position(cell: Vector2i) -> Vector3:
		cell_position_calls += 1
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

	func cell_is_static_standable_goal(_entry: Dictionary, _cell: Vector2i, _allow_outside := false, _moving_home := false) -> bool:
		static_goal_checks += 1
		return true

	func cached_validation_snapshot(_entry: Dictionary, _allow_outside := false, _moving_home := false) -> Dictionary:
		snapshot_calls += 1
		return {}

class FakeUnreachableRoutePlanner:
	extends RefCounted
	var route_cost_calls := 0

	func route_cost(_entry: Dictionary, _target: Vector3, _allow_outside := false, _moving_home := false, _arrival_radius := CELL * 0.85, _approach_cells := [], _require_ready := false) -> float:
		route_cost_calls += 1
		return INF

class FakeForageSmartObjectService:
	extends RefCounted
	var nodes: Array[Node3D] = []
	var last_options: Dictionary = {}

	func query_resource_nodes(_entry: Dictionary, _kinds: Array, options := {}) -> Array[Node3D]:
		last_options = options.duplicate(true) if options is Dictionary else {}
		return nodes.duplicate()

class FakeForageSystem:
	extends RefCounted
	var service = null

	func smart_object_service():
		return service

class FakeNpcSystem:
	extends Node
	var chosen_anchor := Vector3(2.7, 0.0, 0.0)
	var move_calls := 0
	var moving_home_calls := 0
	var route_motion_calls := 0
	var motor_block_until_distance := -1.0
	var max_requested_distance := 0.0
	var max_route_step_distance := 0.0
	var allow_outside_calls := 0
	var last_allow_outside := false
	var moved_actor_ids := {}
	var reservation_releases := 0
	var reservation_release_reasons: Array[String] = []
	var reservation_route_binds := 0
	var forage_slot_advances := 0
	var forage_target_deferrals := 0
	var deferred_forage_target_names: Array[String] = []
	var fighter_target_updates := 0
	var test_route_authority_v2 = null

	func safe_place_npc(body: CharacterBody3D, target: Vector3, _profile = null, _reason := "test") -> Dictionary:
		if body == null:
			return {"ok": false, "reason": "missing_body"}
		body.global_position = target
		return {"ok": true, "position": target, "reason": "test_safe_placement"}

	func update_npc_needs(_entry: Dictionary, _delta: float, _night_factor: float) -> void:
		pass

	func npc_movement_is_paused(_entry: Dictionary, _body: Node3D) -> bool:
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
		moved_actor_ids[String(entry.get("id", "npc"))] = int(moved_actor_ids.get(String(entry.get("id", "npc")), 0)) + 1
		var body := entry.get("body") as Node3D
		if body == null:
			return { "moved": 0.0, "position": previous, "blocked": true, "reason": "missing_body" }
		var flat := Vector2(candidate.x - previous.x, candidate.z - previous.z).length()
		max_route_step_distance = maxf(max_route_step_distance, flat)
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
		fighter_target_updates += 1
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

	func job_target_node(entry: Dictionary) -> Node3D:
		var value = entry.get("jobTargetNode")
		return value if value is Node3D and is_instance_valid(value) else null

	func smart_object_action_reach(_object_id: String, fallback: float) -> float:
		return fallback

	func smart_object_approach_position(entry: Dictionary, target_node: Node3D) -> Vector3:
		return entry.get("jobTarget", target_node.global_position if target_node != null else Vector3.ZERO)

	func release_job_reservation(entry: Dictionary, reason := "released") -> void:
		if String(entry.get("jobObjectId", "")) == "":
			return
		reservation_releases += 1
		reservation_release_reasons.append(String(reason))
		entry["jobObjectId"] = ""
		entry["jobReservationId"] = ""
		entry["jobApproachSlotId"] = ""

	func bind_job_reservation_to_route(entry: Dictionary, authority: Dictionary, semantic_kind: String) -> Dictionary:
		reservation_route_binds += 1
		entry["jobReservationRouteRequestId"] = String(authority.get("requestId", ""))
		entry["jobReservationRouteGeneration"] = int(authority.get("generation", 0))
		return {
			"ok": semantic_kind == "forage_target",
			"status": "succeeded" if semantic_kind == "forage_target" else "failed",
			"reason": "heartbeat",
			"routeRequestId": String(authority.get("requestId", "")),
			"routeGeneration": int(authority.get("generation", 0))
		}

	func advance_forage_approach_slot(entry: Dictionary, _target_node: Node3D) -> bool:
		var candidates: Array = entry.get("jobApproachCandidates", []) if entry.get("jobApproachCandidates", []) is Array else []
		var next_index := int(entry.get("jobApproachCandidateIndex", -1)) + 1
		if next_index >= candidates.size() or not (candidates[next_index] is Dictionary):
			return false
		release_job_reservation(entry, "forage_slot_route_rejected")
		var candidate: Dictionary = candidates[next_index]
		forage_slot_advances += 1
		entry["jobApproachCandidateIndex"] = next_index
		entry["jobObjectId"] = String(entry.get("jobApproachTargetObjectId", "prop:next-slot"))
		entry["jobApproachSlotId"] = String(candidate.get("slotId", ""))
		entry["jobReservationId"] = "%s:%s:%s:next" % [String(entry.get("jobObjectId", "")), String(entry.get("jobApproachSlotId", "")), String(entry.get("id", ""))]
		entry["jobTarget"] = candidate.get("position", Vector3.ZERO)
		entry["jobApproachSlotPosition"] = entry["jobTarget"]
		entry["jobApproachSlotCell"] = candidate.get("cell", Vector2i.ZERO)
		return true

	func defer_forager_target(_entry: Dictionary, target_node: Node3D, _seconds: float) -> void:
		forage_target_deferrals += 1
		deferred_forage_target_names.append(target_node.name if target_node != null else "")

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
		case("npc_behavior_guard_departure_does_not_arrive_at_exit_as_post", "day", "test_guard_departure_does_not_arrive_at_exit_as_post"),
		case("npc_behavior_guard_near_porch_does_not_restart_departure", "day", "test_guard_near_porch_does_not_restart_departure"),
		case("npc_behavior_forager_pending_route_budget_keeps_lifecycle_owner", "day", "test_forager_pending_route_budget_keeps_lifecycle_owner"),
		case("npc_behavior_guard_target_never_falls_back_to_porch", "day", "test_guard_target_never_falls_back_to_porch"),
		case("npc_behavior_guard_intercept_defers_topology_to_v2", "day", "test_guard_intercept_defers_topology_to_v2"),
		case("npc_behavior_guard_intercept_selection_is_incremental", "day", "test_guard_intercept_selection_is_incremental"),
		case("npc_behavior_guard_pending_intercept_does_not_submit_stale_route", "day", "test_guard_pending_intercept_does_not_submit_stale_route"),
		case("npc_behavior_daylight_inactive_hostile_not_selected", "day", "test_daylight_inactive_hostile_not_selected"),
		case("npc_behavior_scripted_hostile_leash_returns_without_named_logic", "day", "test_scripted_hostile_leash_returns_without_named_logic"),
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
		case("npc_behavior_route_order_promotes_abstract_actor", "day", "test_route_order_promotes_abstract_actor"),
		case("npc_behavior_scripted_go_home_arrival_clears_cached_motion", "day", "test_scripted_go_home_arrival_clears_cached_motion"),
		case("npc_behavior_scripted_go_home_hold_arrival_stays_home", "day", "test_scripted_go_home_hold_arrival_stays_home"),
		case("npc_behavior_scripted_order_normal_profile_speed", "day", "test_scripted_order_normal_profile_speed"),
		case("npc_behavior_scripted_order_sprint_profile_speed", "day", "test_scripted_order_sprint_profile_speed"),
		case("npc_behavior_scripted_order_no_transform_write", "day", "test_scripted_order_no_transform_write"),
		case("npc_behavior_dialogue_ack_submits_generic_go_home_order", "day", "test_dialogue_ack_submits_generic_go_home_order"),
		case("npc_behavior_mira_home_arrival_requires_interior", "day", "test_mira_home_arrival_requires_interior"),
		case("npc_behavior_tutorial_uses_generic_orders_without_speed_override", "day", "test_tutorial_uses_generic_orders_without_speed_override"),
		case("npc_motor_every_active_actor_motion_tick_32_npcs", "day", "test_every_active_actor_motion_tick_32_npcs"),
		case("npc_behavior_brain_budget_does_not_skip_route_motion", "day", "test_brain_budget_does_not_skip_route_motion"),
		case("npc_behavior_scripted_order_moves_while_brain_skipped", "day", "test_scripted_order_moves_while_brain_skipped"),
		case("npc_behavior_scripted_combat_overlay_advances_with_v2_route_service", "day", "test_scripted_combat_overlay_advances_with_v2_route_service"),
		case("npc_behavior_mira_no_inching_after_dialogue", "day", "test_mira_no_inching_after_dialogue"),
		case("npc_behavior_morning_departures_not_brain_starved", "day", "test_morning_departures_not_brain_starved"),
		case("npc_behavior_idle_worker_exits_home_clearance", "day", "test_idle_worker_exits_home_clearance"),
		case("npc_behavior_job_selection_budget_ages_deferred_workers", "day", "test_job_selection_budget_ages_deferred_workers"),
		case("npc_behavior_resource_worker_outbound_stays_town_bound", "day", "test_resource_worker_outbound_stays_town_bound"),
		case("npc_behavior_forager_outbound_allows_outside", "day", "test_forager_outbound_allows_outside"),
		case("npc_behavior_forager_active_goal_enters_search_from_idle", "day", "test_forager_active_goal_enters_search_from_idle"),
		case("npc_behavior_forager_search_excludes_current_cell", "day", "test_forager_search_excludes_current_cell"),
		case("npc_behavior_forager_unscored_search_anchor_defers_to_v2", "day", "test_forager_unscored_search_anchor_defers_to_v2"),
		case("npc_behavior_forager_semantic_catalog_accepts_biome_food", "day", "test_forager_semantic_catalog_accepts_biome_food"),
		case("npc_behavior_vox42_generic_forager_stale_reservation_regression", "day", "test_vox42_generic_forager_stale_reservation_regression"),
		case("npc_behavior_vox42_terminal_v2_releases_reservation", "day", "test_vox42_terminal_v2_releases_reservation"),
		case("npc_behavior_vox42_blocked_dynamic_repairs_then_releases", "day", "test_vox42_blocked_dynamic_repairs_then_releases"),
		case("npc_behavior_vox42_home_departure_yields_to_forage", "day", "test_vox42_home_departure_yields_to_forage"),
		case("npc_behavior_vox42_forage_route_binds_reservation", "day", "test_vox42_forage_route_binds_reservation"),
		case("npc_behavior_vox42_force_replan_preserves_pending_request", "day", "test_vox42_force_replan_preserves_pending_request"),
		case("npc_behavior_vox42_terminal_forage_handoff_survives_stale_force", "day", "test_vox42_terminal_forage_handoff_survives_stale_force"),
		case("npc_behavior_vox42_reservation_deadline_retargets", "day", "test_vox42_reservation_deadline_retargets"),
		case("npc_behavior_vox42_gathering_requires_exact_arrived_claim", "day", "test_vox42_gathering_requires_exact_arrived_claim"),
		case("npc_behavior_vox42_blocked_slot_replans_to_clear_slot", "day", "test_vox42_blocked_slot_replans_to_clear_slot"),
		case("npc_behavior_vox42_pending_probe_publishes_bounded_semantic", "day", "test_vox42_pending_probe_publishes_bounded_semantic"),
		case("npc_behavior_vox42_forage_goal_cancels_stale_home_route", "day", "test_vox42_forage_goal_cancels_stale_home_route"),
		case("npc_behavior_vox42_pending_forage_keeps_lifecycle_owner", "day", "test_vox42_pending_forage_keeps_lifecycle_owner"),
		case("npc_behavior_vox42_pending_forage_timeout_defers_target", "day", "test_vox42_pending_forage_timeout_defers_target"),
		case("npc_behavior_vox42_non_home_door_keeps_forage_route", "day", "test_vox42_non_home_door_keeps_forage_route"),
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
	var scripted: Dictionary = library.definition("complete_scripted_world_action")
	var passed := bool(validation.get("ok", false)) and catalog_exists and hardcoded_defaults_removed and int(validation.get("actionCount", 0)) >= 28 and int(validation.get("sequenceCount", 0)) >= 9 and String(rest.get("targetKind", "")) == "bed" and bool(rest.get("reservationRequired", false)) and bool(rest.get("routeRequired", false)) and String(scripted.get("targetKind", "")) == "scripted_action"
	return outcome(passed, "validation=%s catalog=%s hardcoded=%s" % [JSON.stringify(validation), str(catalog_exists), str(hardcoded_defaults_removed)], ["resource_catalog_loads", "hardcoded_action_defaults_removed", "task_fields_declared"], { "validation": validation, "rest": rest, "scripted": scripted })

func test_shared_task_definitions_cover_phase4_goals(_mode: String) -> Dictionary:
	var forage := select_and_plan(entry("Forager", { "job": "forage", "jobTarget": Vector3(8.1, 0.0, 0.0) }), NpcEnumsScript.SCHEDULE_STATE_DAY)
	var trader := select_and_plan(entry("Trader", { "job": "trade", "jobTarget": Vector3(2.7, 0.0, 0.0), "stallPosition": Vector3(2.7, 0.0, 0.0) }), NpcEnumsScript.SCHEDULE_STATE_DAY)
	var guard := select_and_plan(entry("Guard", { "job": "guard", "canFight": true, "nightGuard": true }), NpcEnumsScript.SCHEDULE_STATE_DAY)
	var home := select_and_plan(entry("Villager", { "job": "" }), NpcEnumsScript.SCHEDULE_STATE_NIGHT, { "insideHome": false })
	var scripted_entry := entry("Villager", { "id": "scripted_npc", "scriptedActionPosition": Vector3(1.35, 0.0, 0.0) })
	var scripted_body := scripted_entry.get("body") as Node3D
	scripted_body.set_meta("npc_scripted_order_kind", "scripted_action")
	scripted_body.set_meta("npc_scripted_order_state", "PENDING")
	scripted_body.set_meta("npc_scripted_target", Vector3(1.35, 0.0, 0.0))
	var scripted := select_and_plan(scripted_entry, NpcEnumsScript.SCHEDULE_STATE_DAY, { "scriptedOrder": true, "scriptedOrderKind": "scripted_action", "scriptedOrderState": "PENDING" })
	var passed := (
		(forage.plan.get("actionIds", []) as Array).has("reserve_resource_slot")
		and String(forage.plan.get("targetKind", "")) == "forage_source"
		and (trader.plan.get("actionIds", []) as Array).has("use_trader_stall")
		and String(trader.plan.get("sequenceId", "")) == "trader_stall_work"
		and (guard.plan.get("actionIds", []) as Array).has("occupy_guard_post")
		and (home.plan.get("actionIds", []) as Array).has("rest_at_bed")
		and (scripted.plan.get("actionIds", []) as Array).has("complete_scripted_world_action")
		and String(scripted.plan.get("sequenceId", "")) == "scripted_world_action"
	)
	return outcome(passed, "forage=%s trader=%s guard=%s home=%s scripted=%s" % [JSON.stringify(forage.plan.get("actionIds", [])), JSON.stringify(trader.plan.get("actionIds", [])), JSON.stringify(guard.plan.get("actionIds", [])), JSON.stringify(home.plan.get("actionIds", [])), JSON.stringify(scripted.plan.get("actionIds", []))], ["forage_task_definition", "trader_stall_task_definition", "guard_post_task_definition", "home_bed_task_definition", "scripted_world_task_definition"], { "forage": forage.plan, "trader": trader.plan, "guard": guard.plan, "home": home.plan, "scripted": scripted.plan })

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

func test_guard_departure_does_not_arrive_at_exit_as_post(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	# Mirrors the generated-town guard geometry from VOX-94. Exercise the real
	# brain/physics ownership handoff, not a direct executor-only shortcut.
	var home_cell := Vector2i(2228, -10)
	var porch_cell := Vector2i(2226, -14)
	var guard_cell := Vector2i(2226, -43)
	var guard_post := Vector3(float(guard_cell.x) * CELL, 0.0, float(guard_cell.y) * CELL)
	var entry_data := entry("Guard", {
		"job": "guard",
		"canFight": true,
		"nightGuard": true,
		"position": Vector3(float(home_cell.x) * CELL, 0.0, float(home_cell.y) * CELL),
		"homeCell": home_cell,
		"porchCell": porch_cell,
		"guardCell": guard_cell,
		"guardPosition": guard_post,
		"guardTargetCache": guard_post
	})
	entry_data["interiorMinCell"] = Vector2i(2225, -12)
	entry_data["interiorMaxCell"] = Vector2i(2229, -7)
	entry_data["guardTargetRefreshTimer"] = 100.0
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_GUARD, "reason": "day_guard_patrol" }
	entry_data["activeMotionSchedule"] = { "scheduleState": NpcEnumsScript.SCHEDULE_STATE_DAY, "activeGuardDuty": false }
	entry_data["activeMotionPerception"] = { "insideHome": true, "activeThreat": false, "threat": null }
	var departure_request_targets: Array[Vector2i] = []
	var last_departure_request := ""
	var guard_post_intent: Dictionary = {}
	for _i in range(900):
		fake_npc.test_route_authority_v2.begin_frame()
		var result: Dictionary = executor.advance_physics_route_service(entry_data, 1.0 / 60.0) \
			if executor.physics_route_service_owns_motion(entry_data) \
			else executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
		var routine_intent: Dictionary = entry_data.get("_routineRouteV2Intent", {}) if entry_data.get("_routineRouteV2Intent", {}) is Dictionary else {}
		if String(routine_intent.get("semanticKind", "")) == "home_departure_clearance":
			var request_id := String(entry_data.get("routineRouteV2RequestId", ""))
			if request_id != "" and request_id != last_departure_request:
				last_departure_request = request_id
				var target_cell: Vector2i = routine_intent.get("targetCell", Vector2i(999999, 999999)) if routine_intent.get("targetCell", Vector2i(999999, 999999)) is Vector2i else Vector2i(999999, 999999)
				departure_request_targets.append(target_cell)
		if String(routine_intent.get("semanticKind", "")) == "guard_post":
			guard_post_intent = routine_intent.duplicate(true)
			break
		if not bool(result.get("advanced", false)):
			break
	var target_cell: Vector2i = guard_post_intent.get("targetCell", Vector2i(999999, 999999)) if guard_post_intent.get("targetCell", Vector2i(999999, 999999)) is Vector2i else Vector2i(999999, 999999)
	var passed := fake_npc.move_calls == 0 \
		and departure_request_targets == [porch_cell, Vector2i(2226, -17)] \
		and String(guard_post_intent.get("kind", "")) == "guard" \
		and String(guard_post_intent.get("semanticKind", "")) == "guard_post" \
		and target_cell == guard_cell
	fake_npc.queue_free()
	return outcome(
		passed,
		"departureTargets=%s guardIntent=%s legacyMoveCalls=%d position=%s" % [str(departure_request_targets), JSON.stringify(guard_post_intent), fake_npc.move_calls, str((entry_data.get("body") as Node3D).global_position)],
		["guard_departure_uses_ordered_interior_and_exterior_clearance_routes", "guard_physics_route_service_hands_off_to_assigned_post", "guard_route_does_not_use_legacy_move"],
		{ "departureTargets": departure_request_targets, "guardPostIntent": guard_post_intent, "moveCalls": fake_npc.move_calls }
	)

func test_guard_near_porch_does_not_restart_departure(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var home_cell := Vector2i(2228, -10)
	var porch_cell := Vector2i(2226, -14)
	var guard_cell := Vector2i(2226, -43)
	var body_position := Vector3(float(porch_cell.x) * CELL, 0.0, float(porch_cell.y - 1) * CELL)
	var entry_data := entry("Guard", {
		"job": "guard",
		"canFight": true,
		"nightGuard": true,
		"position": body_position,
		"homeCell": home_cell,
		"porchCell": porch_cell,
		"guardCell": guard_cell,
		"guardPosition": Vector3(float(guard_cell.x) * CELL, 0.0, float(guard_cell.y) * CELL),
		"guardTargetCache": Vector3(float(guard_cell.x) * CELL, 0.0, float(guard_cell.y) * CELL)
	})
	entry_data["interiorMinCell"] = Vector2i(2225, -12)
	entry_data["interiorMaxCell"] = Vector2i(2229, -7)
	entry_data["guardTargetRefreshTimer"] = 100.0
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_GUARD, "reason": "day_guard_patrol" }
	entry_data["activeMotionSchedule"] = { "scheduleState": NpcEnumsScript.SCHEDULE_STATE_DAY, "activeGuardDuty": false }
	entry_data["activeMotionPerception"] = { "insideHome": false, "activeThreat": false, "threat": null }
	var status: Dictionary = executor.call("_home_interior_status", entry_data, body_position)
	var result: Dictionary = executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var routine_intent: Dictionary = entry_data.get("_routineRouteV2Intent", {}) if entry_data.get("_routineRouteV2Intent", {}) is Dictionary else {}
	var passed := not bool(status.get("strictInside", false)) \
		and bool(status.get("clearOfDoor", false)) \
		and bool(result.get("advanced", false)) \
		and String(routine_intent.get("semanticKind", "")) == "guard_post" \
		and String(routine_intent.get("reason", "")) == "guard_route"
	fake_npc.queue_free()
	return outcome(
		passed,
		"status=%s result=%s intent=%s" % [JSON.stringify(status), JSON.stringify(result), JSON.stringify(routine_intent)],
		["outside_guard_near_porch_preserves_normal_route", "clear_of_door_does_not_restart_departure", "guard_route_uses_v2_authority"],
		{ "status": status, "result": result, "intent": routine_intent }
	)

func test_forager_pending_route_budget_keeps_lifecycle_owner(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var authority = fake_npc.test_route_authority_v2
	authority.plan_attempt_budget_per_frame = 0
	var entry_data := entry("Forager", {
		"id": "pending-budget-resume",
		"job": "forage",
		"position": Vector3.ZERO,
		"homeCell": Vector2i(-4, 0),
		"porchCell": Vector2i(-3, 0),
		"jobTarget": Vector3(CELL * 4.0, 0.0, 0.0)
	})
	entry_data["jobPhase"] = "outbound"
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_FORAGE, "reason": "budget_resume" }
	var first: Dictionary = executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var request_id := String(entry_data.get("routineRouteV2RequestId", ""))
	var pending: Dictionary = authority.runtime_for_entry(entry_data)
	var cached_intent: Dictionary = entry_data.get("_routineRouteV2Intent", {}) if entry_data.get("_routineRouteV2Intent", {}) is Dictionary else {}
	authority.plan_attempt_budget_per_frame = 4
	authority.begin_frame()
	var service_owns: bool = executor.physics_route_service_owns_motion(entry_data)
	var resumed: Dictionary = executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var after: Dictionary = authority.runtime_for_entry(entry_data)
	var body := entry_data.get("body") as Node3D
	var passed: bool = request_id != "" \
		and String(pending.get("state", "")) == "pending_budget" \
		and String(cached_intent.get("kind", "")) == "forage" \
		and String(cached_intent.get("semanticKind", "")) != "" \
		and cached_intent.get("target", null) is Vector3 \
		and not service_owns \
		and bool(resumed.get("advanced", false)) \
		and String(after.get("state", "")) != "pending_budget" \
		and String(resumed.get("reason", "")) == "job_route" \
		and body != null
	fake_npc.queue_free()
	return outcome(
		passed,
		"first=%s pending=%s intent=%s serviceOwns=%s resumed=%s after=%s" % [JSON.stringify(first), JSON.stringify(pending), JSON.stringify(cached_intent), str(service_owns), JSON.stringify(resumed), JSON.stringify(after)],
		["initial_budget_deferral_retains_semantic_intent", "forager_job_lifecycle_resumes_pending_route", "physics_service_cannot_starve_forager_target_selection"],
		{ "first": first, "pending": pending, "intent": cached_intent, "serviceOwns": service_owns, "resumed": resumed, "after": after }
	)

func test_guard_target_never_falls_back_to_porch(_mode: String) -> Dictionary:
	var goal_planner = NpcSemanticGoalPlannerScript.new()
	var world := FakeGuardTargetWorld.new()
	var route_planner := FakeUnreachableRoutePlanner.new()
	goal_planner.setup(null, FakeMain.new(), world, route_planner)
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
	var passed := target.distance_to(guard_post) <= 0.01 \
		and not porch_present \
		and route_planner.route_cost_calls == 0 \
		and world.static_goal_checks == 0 \
		and String(entry_data.get("routeReason", "")) == ""
	body.free()
	return outcome(
		passed,
		"target=%s guard=%s porchPresent=%s routeCostCalls=%d staticGoalChecks=%d reason=%s" % [str(target), str(guard_post), str(porch_present), route_planner.route_cost_calls, world.static_goal_checks, String(entry_data.get("routeReason", ""))],
		["guard_target_preserves_assigned_post", "guard_candidates_exclude_home_porch", "guard_target_defers_route_reachability_to_v2"],
		{ "target": target, "guardPost": guard_post, "porch": porch, "porchPresent": porch_present, "routeCostCalls": route_planner.route_cost_calls, "staticGoalChecks": world.static_goal_checks, "reason": String(entry_data.get("routeReason", "")) }
	)

func test_guard_intercept_defers_topology_to_v2(_mode: String) -> Dictionary:
	var goal_planner = NpcSemanticGoalPlannerScript.new()
	var world := FakeGuardTargetWorld.new()
	var route_planner := FakeUnreachableRoutePlanner.new()
	goal_planner.setup(null, FakeMain.new(), world, route_planner)
	var body := Node3D.new()
	body.global_position = Vector3.ZERO
	var hostile := Node3D.new()
	hostile.global_position = Vector3(CELL * 12.0, 0.0, 0.0)
	var entry_data := {
		"id": "guard-intercept-test",
		"body": body,
		"job": "guard",
		"guardPosition": Vector3(CELL * 4.0, 0.0, 0.0),
		"porchPosition": Vector3(CELL, 0.0, 0.0),
		"townCenter": Vector2i.ZERO,
		"townRadius": 32
	}
	var target := Vector3.INF
	for _refresh in range(8):
		target = goal_planner.choose_guard_target(entry_data, hostile, false)
		if not bool(entry_data.get("guardInterceptSelectionPending", false)):
			break
	var target_distance := target.distance_to(hostile.global_position) if target != Vector3.INF else INF
	var passed := target != Vector3.INF \
		and target_distance >= CELL * 2.5 \
		and not bool(entry_data.get("guardInterceptSelectionPending", false)) \
		and world.snapshot_calls == 0 \
		and world.static_goal_checks == 0 \
		and route_planner.route_cost_calls == 0
	body.free()
	hostile.free()
	return outcome(
		passed,
		"target=%s hostileDistance=%.3f snapshotCalls=%d staticGoalChecks=%d routeCostCalls=%d" % [str(target), target_distance, world.snapshot_calls, world.static_goal_checks, route_planner.route_cost_calls],
		["guard_intercept_is_bounded_semantic_anchor", "guard_intercept_defers_topology_to_v2", "guard_intercept_defers_route_cost_to_v2"],
		{ "target": target, "targetDistance": target_distance, "snapshotCalls": world.snapshot_calls, "staticGoalChecks": world.static_goal_checks, "routeCostCalls": route_planner.route_cost_calls }
	)

func test_guard_intercept_selection_is_incremental(_mode: String) -> Dictionary:
	var goal_planner = NpcSemanticGoalPlannerScript.new()
	var world := FakeGuardTargetWorld.new()
	goal_planner.setup(null, FakeMain.new(), world, FakeUnreachableRoutePlanner.new())
	var body := Node3D.new()
	body.global_position = Vector3.ZERO
	var hostile := Node3D.new()
	hostile.global_position = Vector3(CELL * 12.0, 0.0, 0.0)
	var entry_data := {
		"id": "guard-intercept-budget-test",
		"body": body,
		"job": "guard",
		"guardPosition": Vector3(CELL * 4.0, 0.0, 0.0),
		"porchPosition": Vector3(CELL, 0.0, 0.0),
		"townCenter": Vector2i.ZERO,
		"townRadius": 32
	}
	var calls_per_refresh: Array[int] = []
	var target := Vector3.INF
	for _refresh in range(8):
		var before := world.cell_position_calls
		target = goal_planner.choose_guard_target(entry_data, hostile, false)
		calls_per_refresh.append(world.cell_position_calls - before)
		if not bool(entry_data.get("guardInterceptSelectionPending", false)):
			break
	var target_distance := target.distance_to(hostile.global_position) if target != Vector3.INF else INF
	var passed := calls_per_refresh == [2, 2, 2, 2, 2, 2, 2, 2] \
		and world.cell_position_calls == 16 \
		and not bool(entry_data.get("guardInterceptSelectionPending", false)) \
		and target_distance >= CELL * 2.5 \
		and world.snapshot_calls == 0 \
		and world.static_goal_checks == 0
	body.free()
	hostile.free()
	return outcome(
		passed,
		"calls=%s total=%d target=%s distance=%.3f pending=%s" % [JSON.stringify(calls_per_refresh), world.cell_position_calls, str(target), target_distance, str(entry_data.get("guardInterceptSelectionPending", false))],
		["guard_intercept_evaluates_two_grounded_cells_per_refresh", "guard_intercept_preserves_semantic_candidate_set", "guard_intercept_defers_topology_to_v2"],
		{ "callsPerRefresh": calls_per_refresh, "totalCellPositionCalls": world.cell_position_calls, "target": target, "targetDistance": target_distance }
	)

func test_guard_pending_intercept_does_not_submit_stale_route(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var hostile := Node3D.new()
	hostile.global_position = Vector3(CELL * 12.0, 0.0, 0.0)
	var entry_data := entry("Guard", {
		"id": "guard-pending-intercept-test",
		"job": "guard",
		"canFight": true,
		"nightGuard": true,
		"position": Vector3.ZERO,
		"guardPosition": Vector3(CELL * 4.0, 0.0, 0.0)
	})
	entry_data["guardInterceptSelectionPending"] = true
	entry_data["guardTargetRefreshTimer"] = 0.0
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_GUARD, "reason": "guard_intercept" }
	entry_data["activeMotionSchedule"] = { "scheduleState": NpcEnumsScript.SCHEDULE_STATE_NIGHT, "activeGuardDuty": true }
	entry_data["activeMotionPerception"] = { "insideHome": false, "activeThreat": true, "threat": hostile }
	executor.begin_update_frame()
	var refresh_slot_consumed := bool(executor.call("_guard_target_refresh_budget_available", {}))
	var result: Dictionary = executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var passed := refresh_slot_consumed \
		and String(result.get("reason", "")) == "guard_target_selection_pending" \
		and String(entry_data.get("routineRouteV2RequestId", "")) == "" \
		and not entry_data.has("_routineRouteV2Intent") \
		and fake_npc.move_calls == 0
	(entry_data.get("body") as Node3D).free()
	hostile.free()
	fake_npc.queue_free()
	return outcome(
		passed,
		"slotConsumed=%s result=%s request=%s intent=%s moveCalls=%d" % [str(refresh_slot_consumed), JSON.stringify(result), String(entry_data.get("routineRouteV2RequestId", "")), JSON.stringify(entry_data.get("_routineRouteV2Intent", {})), fake_npc.move_calls],
		["pending_guard_intercept_holds_motion", "refresh_budget_deferral_does_not_submit_stale_guard_route", "no_legacy_move"],
		{ "result": result, "requestId": entry_data.get("routineRouteV2RequestId", ""), "intent": entry_data.get("_routineRouteV2Intent", {}), "moveCalls": fake_npc.move_calls }
	)

func test_daylight_inactive_hostile_not_selected(_mode: String) -> Dictionary:
	var hostile_system = HostileSystemScript.new()
	var clock_main := FakeHostileClockMain.new()
	hostile_system.main = clock_main
	var combat = NpcCombatScript.new()
	combat.hostile_system = hostile_system
	var ordinary := Node3D.new()
	ordinary.name = "ordinary_shadow"
	ordinary.global_position = Vector3(CELL * 4.0, 0.0, 0.0)
	var daylight_immune := Node3D.new()
	daylight_immune.name = "daylight_immune_guardian"
	daylight_immune.global_position = Vector3(CELL * 8.0, 0.0, 0.0)
	var scripted_battle := Node3D.new()
	scripted_battle.name = "scripted_battle_hostile"
	scripted_battle.global_position = Vector3(CELL * 12.0, 0.0, 0.0)
	hostile_system.enemies = [
		{ "body": ordinary, "daylightImmune": false, "scriptedEncounter": "", "scriptedPhase": "" },
		{ "body": daylight_immune, "daylightImmune": true, "scriptedEncounter": "", "scriptedPhase": "" },
		{ "body": scripted_battle, "daylightImmune": false, "scriptedEncounter": "story_encounter", "scriptedPhase": "battle" }
	]
	var day_target = combat.nearest_hostile(Vector3.ZERO, CELL * 24.0)
	var day_target_name: String = String(day_target.name) if day_target != null else ""
	var ordinary_day_available := hostile_system.hostile_available_for_npc_combat(ordinary, Vector3.ZERO)
	var immune_day_available := hostile_system.hostile_available_for_npc_combat(daylight_immune, Vector3.ZERO)
	var battle_day_available := hostile_system.hostile_available_for_npc_combat(scripted_battle, Vector3.ZERO)
	clock_main.day_factor = 0.0
	var night_target = combat.nearest_hostile(Vector3.ZERO, CELL * 24.0)
	var night_target_name: String = String(night_target.name) if night_target != null else ""
	var ordinary_night_available := hostile_system.hostile_available_for_npc_combat(ordinary, Vector3.ZERO)
	var passed := day_target == daylight_immune \
		and not ordinary_day_available \
		and immune_day_available \
		and battle_day_available \
		and night_target == ordinary \
		and ordinary_night_available
	ordinary.free()
	daylight_immune.free()
	scripted_battle.free()
	clock_main.free()
	hostile_system.free()
	return outcome(
		passed,
		"dayTarget=%s nightTarget=%s ordinaryDay=%s immuneDay=%s battleDay=%s ordinaryNight=%s" % [day_target_name, night_target_name, str(ordinary_day_available), str(immune_day_available), str(battle_day_available), str(ordinary_night_available)],
		["ordinary_daylight_hostile_not_a_threat", "night_hostile_remains_selectable", "daylight_immune_hostile_remains_selectable", "scripted_battle_remains_selectable"],
		{ "ordinaryDayAvailable": ordinary_day_available, "immuneDayAvailable": immune_day_available, "battleDayAvailable": battle_day_available, "ordinaryNightAvailable": ordinary_night_available }
	)

func test_scripted_hostile_leash_returns_without_named_logic(_mode: String) -> Dictionary:
	var hostile_system = HostileSystemScript.new()
	var enemy := {
		"scriptedEncounter": "generic_story_encounter",
		"scriptedPhase": "battle",
		"scriptedLeashAnchor": Vector3.ZERO,
		"scriptedLeashRadius": CELL * 12.0,
		"scriptedLeashReleaseRadius": CELL * 8.0,
		"scriptedLeashReturning": false
	}
	var outside := hostile_system.scripted_leash_state(enemy, Vector3(CELL * 12.1, 0.0, 0.0))
	var inside := hostile_system.scripted_leash_state(enemy, Vector3(CELL * 7.9, 0.0, 0.0))
	var unconfigured := hostile_system.scripted_leash_state({
		"scriptedEncounter": "generic_story_encounter",
		"scriptedPhase": "battle"
	}, Vector3(CELL * 40.0, 0.0, 0.0))
	var outside_direction: Vector3 = outside.get("direction", Vector3.ZERO)
	var passed := bool(outside.get("enabled", false)) \
		and bool(outside.get("returning", false)) \
		and outside_direction.is_equal_approx(Vector3.LEFT) \
		and not bool(inside.get("returning", true)) \
		and int(enemy.get("scriptedLeashReturnCount", 0)) == 1 \
		and not bool(unconfigured.get("enabled", true))
	hostile_system.free()
	return outcome(
		passed,
		"outside=%s inside=%s returnCount=%d unconfigured=%s" % [str(outside), str(inside), int(enemy.get("scriptedLeashReturnCount", 0)), str(unconfigured)],
		["generic_scripted_leash_enters_before_boundary", "leash_releases_inside_hysteresis", "unconfigured_hostiles_unchanged"],
		{"outside": outside, "inside": inside, "unconfigured": unconfigured}
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
	var entry_data := entry("Forager", { "job": "forage", "position": Vector3(2.7, 0.0, 0.0), "homeCell": Vector2i(3, 0), "porchCell": Vector2i(1, 0) })
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
	var home_intent: Dictionary = entry_data.get("_homeRouteV2Intent", {}) if entry_data.get("_homeRouteV2Intent", {}) is Dictionary else {}
	var passed: bool = fake_npc.moving_home_calls == 0 \
		and String(home_intent.get("kind", "")) == "home" \
		and bool(home_intent.get("movingHome", false)) \
		and int(home_intent.get("priority", 0)) >= 180 \
		and bool(result.get("advanced", false)) \
		and String(result.get("intentKind", "")) == "home" \
		and moved_toward_home
	fake_npc.queue_free()
	return outcome(passed, "result=%s v2=%s before=%s after=%s" % [JSON.stringify(result), JSON.stringify(home_intent), str(before), str(after)], ["night_home_goal_preempts_job_phase", "schedule_home_route_is_urgent", "home_motion_uses_v2_authority", "home_motion_moves_toward_interior"], { "result": result, "homeIntent": home_intent, "before": before, "after": after })

func test_day_job_phase_overrides_stale_home_motion(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Forager", { "job": "forage", "position": Vector3(5.4, 0.0, 0.0), "homeCell": Vector2i(4, 0), "porchCell": Vector2i(1, 0) })
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
	var moved_toward_exit := after.distance_to(entry_data.get("porchPosition", Vector3.ZERO)) < before.distance_to(entry_data.get("porchPosition", Vector3.ZERO))
	var routine_intent: Dictionary = entry_data.get("_routineRouteV2Intent", {}) if entry_data.get("_routineRouteV2Intent", {}) is Dictionary else {}
	var passed: bool = fake_npc.moving_home_calls == 0 \
		and String(routine_intent.get("kind", "")) == "forage" \
		and String(routine_intent.get("semanticKind", "")) == "home_departure_clearance" \
		and bool(result.get("advanced", false)) \
		and String(result.get("intentKind", "")) == "job" \
		and String(result.get("reason", "")) == "job_departure_home_exit" \
		and moved_toward_exit
	fake_npc.queue_free()
	return outcome(passed, "result=%s v2=%s before=%s after=%s" % [JSON.stringify(result), JSON.stringify(routine_intent), str(before), str(after)], ["day_job_goal_preempts_stale_home", "job_motion_uses_v2_authority", "job_departure_routes_to_clearance_first"], { "result": result, "routineIntent": routine_intent, "before": before, "after": after })

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
	var entry_data := entry("Villager", { "id": "mira", "position": Vector3.ZERO, "homeCell": Vector2i(3, 0), "porchCell": Vector2i(1, 0) })
	var body := entry_data.get("body") as Node3D
	set_scripted_order_meta(entry_data, body, "go_home", "tutorial_knock_complete")
	for i in range(8):
		executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var order: Dictionary = entry_data.get("scriptedOrder", {})
	var home_intent: Dictionary = entry_data.get("_homeRouteV2Intent", {}) if entry_data.get("_homeRouteV2Intent", {}) is Dictionary else {}
	var passed: bool = String(home_intent.get("kind", "")) == "home" and bool(home_intent.get("movingHome", false)) and int(home_intent.get("priority", 0)) == 180 and not body.has_meta("npc_scripted_target") and String(order.get("state", "")) in ["ACTIVE", "ARRIVED"]
	fake_npc.queue_free()
	return outcome(passed, "v2=%s targetMeta=%s order=%s" % [JSON.stringify(home_intent), str(body.has_meta("npc_scripted_target")), JSON.stringify(order)], ["go_home_uses_v2_home_route", "scripted_home_priority_preserved", "go_home_no_scripted_target", "order_state_recorded"], { "order": order, "homeIntent": home_intent })

func test_route_order_promotes_abstract_actor(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var lod := NpcSimulationLodServiceScript.new()
	lod.setup(null, fake_npc, null)
	var entry_data := entry("Villager", {"id": "abstract_order_actor", "position": Vector3(8.1, 0.0, 0.0)})
	var body := entry_data.get("body") as CharacterBody3D
	entry_data["simulationLod"] = "abstract"
	entry_data["abstractSimulated"] = true
	entry_data["scriptedOrder"] = {
		"id": "abstract_order_actor:go_to:1",
		"kind": "go_to",
		"state": "PENDING",
		"usesRouteStack": true
	}
	body.visible = false
	body.set_meta("npc_simulation_lod", "abstract")
	lod.register_actor(entry_data)
	var result: Dictionary = lod.update_actor(entry_data, 1.0 / 60.0, Vector3.INF, {"allowStationaryAbstract": true})
	var passed := String(result.get("state", "")) == "active" \
		and String(entry_data.get("simulationLod", "")) == "active" \
		and not bool(entry_data.get("abstractSimulated", true)) \
		and body.visible
	fake_npc.queue_free()
	return outcome(
		passed,
		"result=%s lod=%s visible=%s" % [JSON.stringify(result), String(entry_data.get("simulationLod", "")), str(body.visible)],
		["route_order_promotes_abstract_actor", "accepted_order_can_service_motion"],
		{"result": result, "simulationLod": entry_data.get("simulationLod", ""), "visible": body.visible}
	)

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
	var maximum_move := 0.0
	for i in range(16):
		fake_npc.test_route_authority_v2.begin_frame()
		executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
		maximum_move = maxf(maximum_move, float(entry_data.get("lastMoveDistance", 0.0)))
	var source := read_text("res://scripts/npc_ai/behavior/NpcPlanExecutor.gd") + "\n" + read_text("res://scripts/NpcSystem.gd")
	var no_hack_speed := source.find("speed = 20.0") < 0 and not text_contains_near(source, "holdIntroDoor", "speed", 160) and not text_contains_near(source, "speed", "holdIntroDoor", 160)
	var moved := body.global_position.x
	var profile_speed_ok := maximum_move > 0.0 and maximum_move <= (2.6 * (1.0 / 60.0)) + 0.0001
	var passed: bool = moved > 0.0 and profile_speed_ok and no_hack_speed
	fake_npc.queue_free()
	return outcome(passed, "moved=%.4f maximumMove=%.4f noHack=%s" % [moved, maximum_move, str(no_hack_speed)], ["normal_scripted_speed", "no_20_speed_override"], { "position": body.global_position, "maximumMove": maximum_move })

func test_scripted_order_sprint_profile_speed(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Villager", { "id": "scripted_sprint_speed", "position": Vector3.ZERO })
	var body := entry_data.get("body") as Node3D
	set_scripted_order_meta(entry_data, body, "go_to", "speed_check", Vector3(3.0, 0.0, 0.0), "sprinting")
	var maximum_move := 0.0
	for i in range(16):
		fake_npc.test_route_authority_v2.begin_frame()
		executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
		maximum_move = maxf(maximum_move, float(entry_data.get("lastMoveDistance", 0.0)))
	var lower_bound_ok := maximum_move >= (6.4 * (1.0 / 60.0)) - 0.0001
	var mode_ok := String(entry_data.get("npcSpeedMode", "")) == "sprinting" and bool(entry_data.get("npcRushing", false))
	var passed: bool = body.global_position.x > 0.0 and lower_bound_ok and mode_ok
	fake_npc.queue_free()
	return outcome(passed, "moved=%.4f maximumMove=%.4f mode=%s" % [body.global_position.x, maximum_move, String(entry_data.get("npcSpeedMode", ""))], ["scripted_sprint_speed", "scripted_rushing_mode"], { "position": body.global_position, "maximumMove": maximum_move, "mode": entry_data.get("npcSpeedMode", "") })

func test_scripted_order_no_transform_write(_mode: String) -> Dictionary:
	var source := read_text("res://scripts/NpcSystem.gd")
	var start := source.find("func update_scripted_npc")
	var end := source.find("func update_fighter_target", start)
	var update_source := source.substr(start, end - start)
	var passed: bool = update_source.find("global_position =") < 0 and update_source.find("position =") < 0 and update_source.find("move_npc(") >= 0
	return outcome(passed, "usesMove=%s directGlobal=%s directPosition=%s" % [str(update_source.find("move_npc(") >= 0), str(update_source.find("global_position =") >= 0), str(update_source.find("position =") >= 0)], ["scripted_order_uses_move_npc", "scripted_order_no_transform_assignment"], {})

func test_dialogue_ack_submits_generic_go_home_order(_mode: String) -> Dictionary:
	var tutorial_source := read_text("res://scripts/TutorialSystem.gd")
	var npc_source := read_text("res://scripts/NpcSystem.gd")
	var has_ack_hook := tutorial_source.find('order_go_home(actor, "tutorial_knock_complete")') >= 0 \
		and tutorial_source.find('"reason": "tutorial_knock_pending"') >= 0 \
		and tutorial_source.find("release_intro_elder_home_order") < 0
	var has_order_api := npc_source.find("func order_go_home") >= 0 and npc_source.find("func order_resume_schedule") >= 0 and npc_source.find("func cancel_order") >= 0
	var passed: bool = has_ack_hook and has_order_api
	return outcome(passed, "ackHook=%s api=%s" % [str(has_ack_hook), str(has_order_api)], ["dialogue_ack_submits_generic_home", "scripted_order_api_present"], {})

func test_mira_home_arrival_requires_interior(_mode: String) -> Dictionary:
	var source := read_text("res://scripts/NpcSystem.gd")
	var start := source.find("func settle_home_if_reached")
	var end := source.find("func mark_npc_home_blocked", start)
	var settle_source := source.substr(start, end - start)
	var has_interior_check := settle_source.find("is_inside_home_interior") >= 0
	var outside_terminal_blocked := settle_source.find("home_route_terminal_outside") >= 0
	var passed: bool = has_interior_check and outside_terminal_blocked
	return outcome(passed, "interiorCheck=%s outsideTerminalBlocked=%s" % [str(has_interior_check), str(outside_terminal_blocked)], ["home_arrival_requires_interior_semantics", "terminal_outside_is_not_inside"], {})

func test_tutorial_uses_generic_orders_without_speed_override(_mode: String) -> Dictionary:
	var source := read_text("res://scripts/NpcSystem.gd") + "\n" + read_text("res://scripts/npc_ai/behavior/NpcPlanExecutor.gd") + "\n" + read_text("res://scripts/TutorialSystem.gd") + "\n" + read_text("res://scripts/TutorialDialogueSystem.gd")
	var removed_privileges := source.find("holdIntroDoor") < 0 and source.find("npc_hold_intro_door") < 0 and source.find("release_intro_hold_and_order_home") < 0
	var generic_orders := source.find("order_wait(actor_id") >= 0 and source.find("order_go_home(actor_id") >= 0 and source.find("tutorial_knock_complete") >= 0
	var no_speed_override := source.find("speed = 20.0") < 0
	var passed: bool = removed_privileges and generic_orders and no_speed_override
	return outcome(passed, "removed=%s generic=%s noHack=%s" % [str(removed_privileges), str(generic_orders), str(no_speed_override)], ["intro_hold_privileges_removed", "tutorial_uses_generic_orders", "no_20_speed_override"], {})

func test_every_active_actor_motion_tick_32_npcs(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entries: Array[Dictionary] = []
	for i in range(32):
		var entry_data := entry("Villager", { "id": "cadence_%02d" % i, "position": Vector3(float(i) * 0.05, 0.0, 0.0) })
		var body := entry_data.get("body") as Node3D
		entry_data["cadenceStartX"] = body.global_position.x
		body.set_meta("npc_scripted_target", body.global_position + Vector3(CELL * 4.0, 0.0, 0.0))
		entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_SCRIPTED }
		entries.append(entry_data)
	for _frame in range(16):
		fake_npc.test_route_authority_v2.begin_frame()
		for entry_data in entries:
			executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var source := read_text("res://scripts/NpcSystem.gd")
	var active_pass_index := source.find("var active_entries")
	var budget_loop_index := source.find("while scanned < update_count and processed < budget")
	var motion_pass_index := source.find("advance_npc_motion", budget_loop_index)
	var source_split_ok := active_pass_index >= 0 and budget_loop_index > active_pass_index and motion_pass_index > budget_loop_index
	var telemetry_source := read_text("res://scripts/npc_ai/debug/NpcTelemetryService.gd")
	var counters_ok := telemetry_source.find("npc_brain_updates") >= 0 and telemetry_source.find("npc_motion_updates") >= 0 and telemetry_source.find("npc_brain_budget_skipped") >= 0 and telemetry_source.find("npc_door_action_motion_ticks") >= 0
	var moved_actors := 0
	for entry_data in entries:
		var body := entry_data.get("body") as Node3D
		if body != null and body.global_position.x > float(entry_data.get("cadenceStartX", body.global_position.x)):
			moved_actors += 1
	var passed: bool = moved_actors == 32 and source_split_ok and counters_ok
	fake_npc.queue_free()
	return outcome(passed, "movedActors=%d sourceSplit=%s counters=%s" % [moved_actors, str(source_split_ok), str(counters_ok)], ["all_32_active_motion_ticks", "motion_pass_outside_budget_loop", "r02_motion_counters_present"], { "movedActors": moved_actors, "countersOk": counters_ok })

func test_brain_budget_does_not_skip_route_motion(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Villager", { "position": Vector3.ZERO, "homeCell": Vector2i(4, 0), "porchCell": Vector2i(1, 0), "homePosition": Vector3(5.4, 0.0, 0.0) })
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_HOME }
	entry_data["activeMotionPerception"] = { "insideHome": false, "onPorch": false, "onThreshold": false }
	for i in range(6):
		executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var body := entry_data.get("body") as Node3D
	var distance := body.global_position.length()
	var home_intent: Dictionary = entry_data.get("_homeRouteV2Intent", {}) if entry_data.get("_homeRouteV2Intent", {}) is Dictionary else {}
	var passed: bool = fake_npc.move_calls == 0 \
		and distance > 0.20 \
		and String(home_intent.get("kind", "")) == "home" \
		and String(entry_data.get("routeStatus", "")) != "idle"
	fake_npc.queue_free()
	return outcome(passed, "legacyMoveCalls=%d routeMotionCalls=%d distance=%.3f v2=%s route=%s" % [fake_npc.move_calls, fake_npc.route_motion_calls, distance, JSON.stringify(home_intent), String(entry_data.get("routeStatus", ""))], ["brain_skip_route_motion_continues", "route_distance_accumulates", "home_motion_uses_v2_authority"], { "moveCalls": fake_npc.move_calls, "routeMotionCalls": fake_npc.route_motion_calls, "distance": distance, "homeIntent": home_intent, "routeStatus": entry_data.get("routeStatus", "") })

func test_scripted_order_moves_while_brain_skipped(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Villager", { "position": Vector3.ZERO })
	var body := entry_data.get("body") as Node3D
	body.set_meta("npc_scripted_target", Vector3(CELL * 3.0, 0.0, 0.0))
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_SCRIPTED }
	for i in range(16):
		fake_npc.test_route_authority_v2.begin_frame()
		executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var order: Dictionary = entry_data.get("scriptedOrder", {}) if entry_data.get("scriptedOrder", {}) is Dictionary else {}
	var route_state := String(entry_data.get("routeStatus", ""))
	var passed: bool = String(order.get("state", "")) in ["PENDING", "ACTIVE", "ARRIVED"] and route_state in ["pending", "moving", "arrived"] and body.global_position.x > 0.15
	fake_npc.queue_free()
	return outcome(passed, "order=%s route=%s x=%.3f lastMove=%.4f" % [String(order.get("state", "")), route_state, body.global_position.x, float(entry_data.get("lastMoveDistance", 0.0))], ["scripted_order_motion_without_brain", "scripted_position_advances"], { "order": order, "routeStatus": route_state, "position": body.global_position, "lastMoveDistance": entry_data.get("lastMoveDistance", 0.0) })

func test_scripted_combat_overlay_advances_with_v2_route_service(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Guard", { "position": Vector3.ZERO, "canFight": true, "weaponId": "hunterBow" })
	var body := entry_data.get("body") as Node3D
	var hostile := Node3D.new()
	if runner != null:
		runner.add_child(hostile)
	hostile.global_position = Vector3(CELL * 2.0, 0.0, 0.0)
	set_scripted_order_meta(entry_data, body, "go_to", "scripted_combat_route_service", Vector3(CELL * 5.0, 0.0, 0.0))
	body.set_meta("npc_scripted_combat_overlay_enabled", true)
	entry_data["activeMotionPerception"] = { "activeThreat": true, "threat": hostile }
	fake_npc.test_route_authority_v2.begin_frame()
	executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var service_owns: bool = executor.physics_route_service_owns_motion(entry_data)
	# The brain pass normally refreshes this cache before the physics service.
	# Keep the act phase focused on the service ownership boundary itself.
	entry_data["activeMotionPerception"] = { "activeThreat": true, "threat": hostile }
	fake_npc.fighter_target_updates = 0
	entry_data["scriptedCombatOverlay"] = false
	body.set_meta("npc_scripted_combat_overlay", false)
	var before := body.global_position
	fake_npc.test_route_authority_v2.begin_frame()
	var result: Dictionary = executor.advance_physics_route_service(entry_data, 1.0 / 60.0) if service_owns else {}
	var combat_inputs := {
		"enabled": body.get_meta("npc_scripted_combat_overlay_enabled", false),
		"canFight": entry_data.get("canFight", null),
		"activeThreat": (entry_data.get("activeMotionPerception", {}) as Dictionary).get("activeThreat", null),
		"threatValid": is_instance_valid(hostile),
		"hasUpdate": fake_npc.has_method("update_fighter_target")
	}
	var passed := service_owns \
		and fake_npc.fighter_target_updates == 1 \
		and bool(entry_data.get("scriptedCombatOverlay", false)) \
		and bool(body.get_meta("npc_scripted_combat_overlay", false)) \
		and String(result.get("status", "")) in ["moving", "arrived"] \
		and body.global_position.distance_to(before) > 0.001
	hostile.free()
	fake_npc.queue_free()
	return outcome(
		passed,
		"serviceOwns=%s fighterUpdates=%d overlay=%s overlayReason=%s inputs=%s result=%s moved=%.4f" % [str(service_owns), fake_npc.fighter_target_updates, str(entry_data.get("scriptedCombatOverlay", false)), String(entry_data.get("scriptedCombatOverlayReason", "missing")), JSON.stringify(combat_inputs), JSON.stringify(result), body.global_position.distance_to(before)],
		["scripted_v2_route_service_preserves_combat_overlay", "scripted_combat_target_updates_during_route_motion", "scripted_route_motion_continues_with_combat_overlay"],
		{ "serviceOwns": service_owns, "fighterTargetUpdates": fake_npc.fighter_target_updates, "overlay": entry_data.get("scriptedCombatOverlay", false), "combatInputs": combat_inputs, "result": result }
	)

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
	var entry_data := entry("Carpenter", { "job": "wood", "position": Vector3.ZERO, "homeCell": Vector2i(-10, 0), "porchCell": Vector2i(-9, 0) })
	entry_data["jobPhase"] = "outbound"
	entry_data["jobTarget"] = Vector3(4.0, 0.0, 0.0)
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_WORK }
	for i in range(10):
		executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var body := entry_data.get("body") as Node3D
	var routine_intent: Dictionary = entry_data.get("_routineRouteV2Intent", {}) if entry_data.get("_routineRouteV2Intent", {}) is Dictionary else {}
	var passed: bool = fake_npc.move_calls == 0 \
		and body.global_position.x > 0.42 \
		and String(routine_intent.get("kind", "")) == "work" \
		and String(entry_data.get("routeStatus", "moving")) != "idle"
	fake_npc.queue_free()
	return outcome(passed, "legacyMoveCalls=%d routeMotionCalls=%d x=%.3f route=%s v2=%s" % [fake_npc.move_calls, fake_npc.route_motion_calls, body.global_position.x, String(entry_data.get("routeStatus", "")), JSON.stringify(routine_intent)], ["morning_job_motion_every_frame", "morning_departure_not_brain_starved", "morning_departure_uses_v2_authority"], { "moveCalls": fake_npc.move_calls, "routeMotionCalls": fake_npc.route_motion_calls, "position": body.global_position, "routeStatus": entry_data.get("routeStatus", ""), "routineIntent": routine_intent })

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
	var routine_intent: Dictionary = entry_data.get("_routineRouteV2Intent", {}) if entry_data.get("_routineRouteV2Intent", {}) is Dictionary else {}
	var passed: bool = fake_npc.move_calls == 0 \
		and bool(result.get("advanced", false)) \
		and String(result.get("reason", "")) == "job_departure_home_exit" \
		and String(result.get("intentKind", "")) == "job" \
		and after.z < before.z \
		and String(routine_intent.get("kind", "")) == "work" \
		and String(routine_intent.get("semanticKind", "")) == "home_departure_clearance"
	fake_npc.queue_free()
	return outcome(
		passed,
		"result=%s legacyMoveCalls=%d routeMotionCalls=%d before=%s after=%s v2=%s" % [JSON.stringify(result), fake_npc.move_calls, fake_npc.route_motion_calls, str(before), str(after), JSON.stringify(routine_intent)],
		["idle_worker_in_door_clearance_moves_outward", "job_idle_not_frozen_at_home_threshold", "job_home_exit_uses_v2_authority", "active_job_departure_uses_clearance_route"],
		{ "result": result, "moveCalls": fake_npc.move_calls, "routeMotionCalls": fake_npc.route_motion_calls, "before": before, "after": after, "jobPhase": entry_data.get("jobPhase", ""), "routineIntent": routine_intent }
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
	var before := (entry_data.get("body") as Node3D).global_position
	executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var body := entry_data.get("body") as Node3D
	var routine_intent: Dictionary = entry_data.get("_routineRouteV2Intent", {}) if entry_data.get("_routineRouteV2Intent", {}) is Dictionary else {}
	var passed: bool = fake_npc.move_calls == 0 \
		and String(routine_intent.get("kind", "")) == "work" \
		and not bool(routine_intent.get("allowOutside", true)) \
		and body.global_position.x > before.x
	fake_npc.queue_free()
	return outcome(
		passed,
		"legacyMoveCalls=%d routeMotionCalls=%d allowOutside=%s before=%s after=%s v2=%s" % [fake_npc.move_calls, fake_npc.route_motion_calls, str(routine_intent.get("allowOutside", null)), str(before), str(body.global_position), JSON.stringify(routine_intent)],
		["stone_worker_outbound_uses_town_route_permission", "resource_worker_route_stays_town_bound", "resource_worker_uses_v2_authority"],
		{ "moveCalls": fake_npc.move_calls, "routeMotionCalls": fake_npc.route_motion_calls, "position": body.global_position, "routineIntent": routine_intent }
	)

func test_forager_outbound_allows_outside(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Forager", { "job": "forage", "position": Vector3.ZERO, "homeCell": Vector2i(-10, 0), "porchCell": Vector2i(-9, 0) })
	entry_data["jobPhase"] = "outbound"
	entry_data["jobTarget"] = Vector3(42.0, 0.0, 0.0)
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_FORAGE }
	for _tick in range(8):
		if fake_npc.test_route_authority_v2 != null:
			fake_npc.test_route_authority_v2.begin_frame()
		executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
		if (entry_data.get("body") as Node3D).global_position.x > 0.0:
			break
	var body := entry_data.get("body") as Node3D
	var routine_intent: Dictionary = entry_data.get("_routineRouteV2Intent", {}) if entry_data.get("_routineRouteV2Intent", {}) is Dictionary else {}
	var passed: bool = fake_npc.move_calls == 0 \
		and String(routine_intent.get("kind", "")) == "forage" \
		and String(routine_intent.get("semanticKind", "")) == "forage_search_anchor" \
		and bool(routine_intent.get("allowOutside", false)) \
		and body.global_position.x > 0.0
	fake_npc.queue_free()
	return outcome(
		passed,
		"legacyMoveCalls=%d routeMotionCalls=%d allowOutside=%s x=%.3f v2=%s" % [fake_npc.move_calls, fake_npc.route_motion_calls, str(routine_intent.get("allowOutside", null)), body.global_position.x, JSON.stringify(routine_intent)],
		["forager_outbound_uses_outside_route_permission", "forager_search_uses_exact_anchor_semantic", "forager_route_can_leave_town", "forager_uses_v2_authority"],
		{ "moveCalls": fake_npc.move_calls, "routeMotionCalls": fake_npc.route_motion_calls, "position": body.global_position, "routineIntent": routine_intent }
	)

func test_forager_active_goal_enters_search_from_idle(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Forager", {
		"job": "forage",
		"position": Vector3(CELL * 4.0, 0.0, 0.0),
		"homeCell": Vector2i(-10, 0),
		"porchCell": Vector2i(-9, 0)
	})
	entry_data["jobPhase"] = "idle"
	entry_data["jobTimer"] = 8.0
	entry_data["hunger"] = 100.0
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_FORAGE, "reason": "role_forager_food_loop" }
	entry_data["activeGoalKind"] = NpcEnumsScript.GOAL_KIND_FORAGE
	var result: Dictionary = executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var routine_intent: Dictionary = entry_data.get("_routineRouteV2Intent", {}) if entry_data.get("_routineRouteV2Intent", {}) is Dictionary else {}
	var last_authority: Dictionary = entry_data.get("routineRouteV2LastAuthority", {}) if entry_data.get("routineRouteV2LastAuthority", {}) is Dictionary else {}
	var service_owns: bool = executor.physics_route_service_owns_motion(entry_data)
	var passed := bool(result.get("advanced", false)) \
		and String(entry_data.get("jobPhase", "")) == "searching" \
		and String(entry_data.get("goal", "")) == "search for forage" \
		and fake_npc.move_calls == 0 \
		and String(entry_data.get("routeStatus", "")) != "idle" \
		and String(entry_data.get("routineRouteV2RequestId", "")) != "" \
		and not service_owns \
		and not last_authority.is_empty()
	fake_npc.queue_free()
	return outcome(
		passed,
		"result=%s phase=%s legacyMoveCalls=%d routeStatus=%s serviceOwns=%s v2=%s authority=%s" % [JSON.stringify(result), String(entry_data.get("jobPhase", "")), fake_npc.move_calls, String(entry_data.get("routeStatus", "")), str(service_owns), JSON.stringify(routine_intent), JSON.stringify(last_authority)],
		["forager_active_goal_promotes_idle_to_searching", "forager_idle_intent_uses_v2_authority", "forager_idle_intent_does_not_rest_outside", "forager_lifecycle_owns_search_anchor"],
		{ "result": result, "jobPhase": entry_data.get("jobPhase", ""), "moveCalls": fake_npc.move_calls, "routeStatus": entry_data.get("routeStatus", ""), "serviceOwns": service_owns, "routineIntent": routine_intent, "lastAuthority": last_authority }
	)

func test_forager_search_excludes_current_cell(_mode: String) -> Dictionary:
	var semantic_planner := NpcSemanticGoalPlannerScript.new()
	var body := Node3D.new()
	body.global_position = Vector3(CELL * 3.0, 0.0, CELL * 2.0)
	var current_cell_candidate := body.global_position + Vector3(0.2, 0.0, -0.2)
	var next_cell_candidate := body.global_position + Vector3(CELL, 0.0, 0.0)
	var filtered := semantic_planner.forage_search_candidates_away_from_current_cell(
		{ "body": body },
		[current_cell_candidate, next_cell_candidate]
	)
	var passed := filtered.size() == 1 and semantic_planner.position_key(filtered[0]) == semantic_planner.position_key(next_cell_candidate)
	body.queue_free()
	return outcome(
		passed,
		"filtered=%s" % JSON.stringify(filtered),
		["forager_search_filters_current_cell_before_route_scoring", "forager_search_retains_next_cell_candidate"],
		{ "filtered": filtered }
	)

func test_forager_unscored_search_anchor_defers_to_v2(_mode: String) -> Dictionary:
	var semantic_planner := NpcSemanticGoalPlannerScript.new()
	var world := FakeRouteWorld.new()
	var body := Node3D.new()
	body.global_position = Vector3(CELL * 3.0, 0.0, 0.0)
	semantic_planner.setup(null, FakeMain.new(), world, FakeUnreachableRoutePlanner.new())
	var entry_data := {
		"id": "forager-unscored-search-anchor",
		"job": "forage",
		"jobPhase": "searching",
		"body": body,
		"townCenter": Vector2i.ZERO,
		"townRadius": 2,
		"homePosition": Vector3(CELL * 6.0, 0.0, 0.0),
		"porchPosition": Vector3(CELL * 5.0, 0.0, 0.0)
	}
	var target := semantic_planner.choose_forage_search_target(entry_data)
	var passed := target != Vector3.INF \
		and semantic_planner.forage_search_target_requires_travel(entry_data, target) \
		and not world.point_inside_town(entry_data, target) \
		and world.point_inside_work_area(entry_data, target)
	body.queue_free()
	return outcome(
		passed,
		"target=%s routeReason=%s" % [str(target), String(entry_data.get("routeReason", ""))],
		["semantic_search_anchor_survives_unscored_route_cost", "search_anchor_is_outside_town", "v2_remains_collision_route_authority"],
		{ "target": target, "routeReason": String(entry_data.get("routeReason", "")) }
	)

func test_forager_semantic_catalog_accepts_biome_food(_mode: String) -> Dictionary:
	var service := FakeForageSmartObjectService.new()
	var system := FakeForageSystem.new()
	system.service = service
	var semantic_planner := NpcSemanticGoalPlannerScript.new()
	semantic_planner.setup(system, FakeMain.new(), FakeRouteWorld.new(), null)
	var aloe := Node3D.new()
	aloe.set_meta("kind", "prop")
	aloe.set_meta("material", "aloePatch")
	aloe.set_meta("drop", "aloe")
	aloe.global_position = Vector3(CELL * 24.0, 0.0, 0.0)
	service.nodes = [aloe]
	var entry_data := {
		"job": "forage",
		"townCenter": Vector2i.ZERO,
		"townRadius": 18
	}
	var queried := semantic_planner.indexed_resource_props(entry_data, "forage")
	var drops: Array = service.last_options.get("drops", []) if service.last_options.get("drops", []) is Array else []
	var passed := drops == ["aloe", "berries", "frostHerb", "mirecap"] \
		and queried.size() == 1 \
		and semantic_planner.prop_matches_job(aloe, entry_data, "forage")
	aloe.queue_free()
	return outcome(
		passed,
		"drops=%s queried=%d" % [JSON.stringify(drops), queried.size()],
		["forager_semantic_query_uses_catalog_food_ids", "forager_semantic_validation_accepts_biome_food"],
		{ "drops": drops, "queried": queried.size() }
	)

func test_vox42_generic_forager_stale_reservation_regression(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var rng := RandomNumberGenerator.new()
	rng.seed = 42042
	var forager_id := "forager_%d" % rng.randi_range(100000, 999999)
	var prop := Node3D.new()
	prop.name = "VOX42_Berry_%s" % forager_id
	fake_npc.add_child(prop)
	var target_position := Vector3(CELL * 40.0, 0.0, 0.0)
	prop.position = target_position
	var object_id := "prop:vox42-%s" % forager_id
	var reservation_id := "%s:slot:0:%s:1" % [object_id, forager_id]
	var entry_data := entry("Forager", {
		"id": forager_id,
		"job": "forage",
		"position": Vector3.ZERO,
		"homeCell": Vector2i(-4, 0),
		"porchCell": Vector2i(-3, 0)
	})
	var body := entry_data.get("body") as Node3D
	body.global_position = Vector3.ZERO
	entry_data["jobPhase"] = "outbound"
	entry_data["jobTimer"] = 0.0
	entry_data["jobTargetNode"] = prop
	entry_data["jobTarget"] = target_position
	entry_data["jobObjectId"] = object_id
	entry_data["jobReservationId"] = reservation_id
	entry_data["jobApproachSlotId"] = "slot:0"
	entry_data["routeStatus"] = "moving"
	entry_data["routeReason"] = "stuck"
	entry_data["pathWaypoints"] = [entry_data["jobTarget"]]
	entry_data["corridorProgress"] = { "noProgressTicks": 48 }
	entry_data["lastMoveDistance"] = 0.0
	entry_data["routineRouteV2RequestId"] = "%s:v2:2:1" % forager_id
	entry_data["routineRouteV2IntentKind"] = "forage"
	entry_data["routineRouteV2SemanticKind"] = "forage_target"
	entry_data["routineRouteV2Key"] = "%s|forage|forage_target|40,0|true|%s|job_route|0" % [forager_id, object_id]
	entry_data["_routineRouteV2Intent"] = { "jobObjectId": object_id }
	entry_data["routeAuthorityV2"] = {
		"requestId": entry_data["routineRouteV2RequestId"],
		"generation": 2,
		"state": "blocked_dynamic",
		"reason": "stuck"
	}
	entry_data["jobReservationRouteRequestId"] = entry_data["routineRouteV2RequestId"]
	entry_data["jobReservationRouteGeneration"] = 2
	entry_data["forageRouteRepairAttempts"] = 1
	var distance_before := body.global_position.distance_to(target_position)
	var moving_job := bool(executor.call("_update_forager_goal", entry_data, body, 1.0))
	var distance_after := body.global_position.distance_to(target_position)
	var still_reserved := String(entry_data.get("jobObjectId", "")) == object_id and String(entry_data.get("jobReservationId", "")) == reservation_id
	var passed: bool = forager_id != "niko" \
		and moving_job \
		and not still_reserved \
		and fake_npc.reservation_releases == 1 \
		and fake_npc.reservation_release_reasons == ["route_blocked_dynamic_after_repair"] \
		and bool(entry_data.get("routeForceReplan", false)) \
		and String(entry_data.get("jobPhase", "")) == "searching"
	var details := {
		"foragerId": forager_id,
		"objectId": object_id,
		"reservationId": reservation_id,
		"stillReserved": still_reserved,
		"releaseCount": fake_npc.reservation_releases,
		"releaseReasons": fake_npc.reservation_release_reasons.duplicate(),
		"jobPhase": String(entry_data.get("jobPhase", "")),
		"routeStatus": String(entry_data.get("routeStatus", "")),
		"distanceBefore": distance_before,
		"distanceAfter": distance_after,
		"noProgressTicks": int((entry_data.get("corridorProgress", {}) as Dictionary).get("noProgressTicks", -1)),
		"routeForceReplan": bool(entry_data.get("routeForceReplan", false))
	}
	fake_npc.queue_free()
	return outcome(passed, "generic=%s stillReserved=%s releases=%d phase=%s noProgress=%d" % [forager_id, str(still_reserved), fake_npc.reservation_releases, String(details.get("jobPhase", "")), int(details.get("noProgressTicks", -1))], ["generic_forager_not_niko", "stale_forage_reservation_released", "no_progress_does_not_keep_capacity_busy"], details)

func test_vox42_terminal_v2_releases_reservation(_mode: String) -> Dictionary:
	var setup := vox42_reserved_forager_setup("terminal")
	var fake_npc: FakeNpcSystem = setup.fakeNpc
	var executor: Variant = setup.executor
	var entry_data: Dictionary = setup.entry
	var body: CharacterBody3D = entry_data.get("body")
	entry_data["routeAuthorityV2"] = {
		"requestId": "forager-terminal:v2:8:1",
		"generation": 8,
		"state": "unreachable_static",
		"reason": "no_route"
	}
	entry_data["routineRouteV2RequestId"] = "forager-terminal:v2:8:1"
	entry_data["routineRouteV2SemanticKind"] = "forage_target"
	entry_data["routineRouteV2IntentKind"] = "forage"
	entry_data["routineRouteV2Key"] = "forager-terminal|forage|forage_target|40,0|true|prop:terminal|job_route|0"
	entry_data["_routineRouteV2Intent"] = { "jobObjectId": "prop:terminal" }
	entry_data["jobReservationRouteRequestId"] = "forager-terminal:v2:8:1"
	entry_data["jobReservationRouteGeneration"] = 8
	var moving_job := bool(executor.call("_update_forager_goal", entry_data, body, 1.0 / 60.0))
	var passed := moving_job \
		and fake_npc.reservation_releases == 1 \
		and fake_npc.reservation_release_reasons == ["route_unreachable_static"] \
		and String(entry_data.get("jobPhase", "")) == "searching" \
		and String(entry_data.get("jobObjectId", "")) == "" \
		and entry_data.get("jobTargetNode") == null
	var details := {
		"releaseCount": fake_npc.reservation_releases,
		"releaseReasons": fake_npc.reservation_release_reasons.duplicate(),
		"jobPhase": String(entry_data.get("jobPhase", "")),
		"jobFailureReason": String(entry_data.get("jobFailureReason", ""))
	}
	fake_npc.queue_free()
	return outcome(passed, JSON.stringify(details), ["terminal_v2_state_releases_once", "terminal_target_reselected"], details)

func test_vox42_blocked_dynamic_repairs_then_releases(_mode: String) -> Dictionary:
	var setup := vox42_reserved_forager_setup("dynamic")
	var fake_npc: FakeNpcSystem = setup.fakeNpc
	var executor: Variant = setup.executor
	var entry_data: Dictionary = setup.entry
	var body: CharacterBody3D = entry_data.get("body")
	entry_data["routeAuthorityV2"] = {
		"requestId": "forager-dynamic:v2:5:1",
		"generation": 5,
		"state": "blocked_dynamic",
		"reason": "stuck"
	}
	entry_data["routineRouteV2RequestId"] = "forager-dynamic:v2:5:1"
	entry_data["routineRouteV2SemanticKind"] = "forage_target"
	entry_data["routineRouteV2IntentKind"] = "forage"
	entry_data["routineRouteV2Key"] = "forager-dynamic|forage|forage_target|40,0|true|prop:dynamic|job_route|0"
	entry_data["_routineRouteV2Intent"] = { "jobObjectId": "prop:dynamic" }
	entry_data["jobReservationRouteRequestId"] = "forager-dynamic:v2:5:1"
	entry_data["jobReservationRouteGeneration"] = 5
	var first_moving := bool(executor.call("_update_forager_goal", entry_data, body, 1.0 / 60.0))
	var first_release_count := fake_npc.reservation_releases
	var first_repair_count := int(entry_data.get("forageRouteRepairAttempts", 0))
	entry_data["routeAuthorityV2"] = {
		"requestId": "forager-dynamic:v2:6:2",
		"generation": 6,
		"state": "blocked_dynamic",
		"reason": "stuck"
	}
	entry_data["routineRouteV2RequestId"] = "forager-dynamic:v2:6:2"
	entry_data["jobReservationRouteRequestId"] = "forager-dynamic:v2:6:2"
	entry_data["jobReservationRouteGeneration"] = 6
	var second_moving := bool(executor.call("_update_forager_goal", entry_data, body, 1.0 / 60.0))
	var passed := first_moving \
		and first_release_count == 0 \
		and first_repair_count == 1 \
		and second_moving \
		and fake_npc.reservation_releases == 1 \
		and fake_npc.reservation_release_reasons == ["route_blocked_dynamic_after_repair"] \
		and String(entry_data.get("jobPhase", "")) == "searching"
	var details := {
		"firstReleaseCount": first_release_count,
		"firstRepairCount": first_repair_count,
		"releaseCount": fake_npc.reservation_releases,
		"releaseReasons": fake_npc.reservation_release_reasons.duplicate(),
		"jobPhase": String(entry_data.get("jobPhase", ""))
	}
	fake_npc.queue_free()
	return outcome(passed, JSON.stringify(details), ["dynamic_block_gets_one_repair", "repeated_dynamic_block_releases_once"], details)

func test_vox42_home_departure_yields_to_forage(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var fake_autonomy := FakeAutonomy.new()
	fake_npc.add_child(fake_autonomy)
	var executor: Variant = make_executor(fake_npc, fake_autonomy)
	var entry_data := entry("Forager", {
		"id": "forager_departure",
		"job": "forage",
		"homeCell": Vector2i.ZERO,
		"porchCell": Vector2i(1, 0),
		"position": Vector3(CELL * 4.0, 0.0, 0.0)
	})
	var body: CharacterBody3D = entry_data.get("body")
	entry_data["jobPhase"] = "outbound"
	entry_data["jobObjectId"] = "prop:departure"
	entry_data["jobReservationId"] = "prop:departure:slot:0:forager_departure:1"
	entry_data["jobApproachSlotId"] = "slot:0"
	entry_data["activeDoorPortalId"] = "door:departure"
	var result: Dictionary = executor.call("_advance_job_home_exit", entry_data, body, 1.0 / 60.0, "job_departure_home_exit")
	var passed := String(result.get("routeStatus", "")) == "waiting" \
		and fake_autonomy.door_releases == 1 \
		and String(entry_data.get("activeDoorPortalId", "")) == "" \
		and bool(entry_data.get("routeForceReplan", false))
	var details := {
		"result": result,
		"doorReleases": fake_autonomy.door_releases,
		"activeDoorPortalId": String(entry_data.get("activeDoorPortalId", "")),
		"routeForceReplan": bool(entry_data.get("routeForceReplan", false))
	}
	fake_npc.queue_free()
	return outcome(passed, JSON.stringify(details), ["departure_arrival_releases_door", "departure_arrival_forces_forage_route"], details)

func test_vox42_forage_route_binds_reservation(_mode: String) -> Dictionary:
	var setup := vox42_reserved_forager_setup("binding")
	var fake_npc: FakeNpcSystem = setup.fakeNpc
	var executor: Variant = setup.executor
	var entry_data: Dictionary = setup.entry
	entry_data["jobTimer"] = 5.0
	(entry_data.get("body") as CharacterBody3D).global_position = Vector3(CELL * 4.0, 0.0, 0.0)
	var result := {}
	for _tick in range(8):
		if fake_npc.test_route_authority_v2 != null:
			fake_npc.test_route_authority_v2.begin_frame()
		result = executor.call("_advance_job_motion", entry_data, entry_data.get("body"), 1.0 / 60.0)
		var current_authority: Dictionary = entry_data.get("routeAuthorityV2", {}) if entry_data.get("routeAuthorityV2", {}) is Dictionary else {}
		if current_authority.get("interactionClaim", {}) is Dictionary and not (current_authority.get("interactionClaim", {}) as Dictionary).is_empty():
			break
	var bound_request_id := String(entry_data.get("jobReservationRouteRequestId", ""))
	var bound_generation := int(entry_data.get("jobReservationRouteGeneration", 0))
	var intent: Dictionary = entry_data.get("_routineRouteV2Intent", {}) if entry_data.get("_routineRouteV2Intent", {}) is Dictionary else {}
	var claim: Dictionary = intent.get("interactionClaim", {}) if intent.get("interactionClaim", {}) is Dictionary else {}
	var authority: Dictionary = entry_data.get("routeAuthorityV2", {}) if entry_data.get("routeAuthorityV2", {}) is Dictionary else {}
	var lease_claim: Dictionary = authority.get("interactionClaim", {}) if authority.get("interactionClaim", {}) is Dictionary else {}
	var candidate_cells: Array = intent.get("candidateCells", []) if intent.get("candidateCells", []) is Array else []
	var passed := fake_npc.reservation_route_binds >= 1 \
		and bound_request_id != "" \
		and bound_generation > 0 \
		and String(intent.get("semanticKind", "")) == "forage_target" \
		and String(intent.get("jobObjectId", "")) == "prop:binding" \
		and candidate_cells.size() == 1 \
		and String(claim.get("reservationId", "")) == String(entry_data.get("jobReservationId", "")) \
		and String(claim.get("slotId", "")) == "slot:0" \
		and int(lease_claim.get("routeGeneration", 0)) == bound_generation
	var details := {
		"result": result,
		"bindCount": fake_npc.reservation_route_binds,
		"boundRequestId": bound_request_id,
		"boundGeneration": bound_generation,
		"intent": intent,
		"leaseClaim": lease_claim
	}
	fake_npc.queue_free()
	return outcome(passed, JSON.stringify(details), ["forage_target_route_binds_reservation", "binding_uses_v2_generation"], details)

func test_vox42_force_replan_preserves_pending_request(_mode: String) -> Dictionary:
	var setup := vox42_reserved_forager_setup("force_replan")
	var fake_npc: FakeNpcSystem = setup.fakeNpc
	var executor: Variant = setup.executor
	var entry_data: Dictionary = setup.entry
	var body: CharacterBody3D = entry_data.get("body")
	body.global_position = Vector3(CELL * 4.0, 0.0, 0.0)
	entry_data["routeForceReplan"] = true
	var first: Dictionary = executor.call("_advance_job_motion", entry_data, body, 1.0 / 60.0)
	var first_request_id := String(entry_data.get("routineRouteV2RequestId", ""))
	var first_authority: Dictionary = entry_data.get("routeAuthorityV2", {}) if entry_data.get("routeAuthorityV2", {}) is Dictionary else {}
	var first_generation := int(first_authority.get("generation", 0))
	entry_data["routeForceReplan"] = true
	var second: Dictionary = executor.call("_advance_job_motion", entry_data, body, 1.0 / 60.0)
	var second_request_id := String(entry_data.get("routineRouteV2RequestId", ""))
	var second_authority: Dictionary = entry_data.get("routeAuthorityV2", {}) if entry_data.get("routeAuthorityV2", {}) is Dictionary else {}
	var second_generation := int(second_authority.get("generation", 0))
	var passed := not bool(entry_data.get("routeForceReplan", true)) \
		and first_request_id != "" \
		and second_request_id == first_request_id \
		and first_generation > 0 \
		and second_generation == first_generation \
		and String(entry_data.get("jobReservationId", "")) != ""
	var details := {
		"first": first,
		"second": second,
		"firstRequestId": first_request_id,
		"secondRequestId": second_request_id,
		"firstGeneration": first_generation,
		"secondGeneration": second_generation,
		"routeForceReplan": bool(entry_data.get("routeForceReplan", false))
	}
	fake_npc.queue_free()
	return outcome(passed, JSON.stringify(details), ["force_replan_consumed_once", "pending_route_request_identity_stable", "forage_lease_not_rebound_each_tick"], details)

func test_vox42_terminal_forage_handoff_survives_stale_force(_mode: String) -> Dictionary:
	var setup := vox42_reserved_forager_setup("terminal_handoff")
	var fake_npc: FakeNpcSystem = setup.fakeNpc
	var executor: Variant = setup.executor
	var entry_data: Dictionary = setup.entry
	var body: CharacterBody3D = entry_data.get("body")
	body.global_position = Vector3(CELL * 4.0, 0.0, 0.0)
	entry_data["routeForceReplan"] = true
	executor.call("_advance_job_motion", entry_data, body, 1.0 / 60.0)
	var request_id := String(entry_data.get("routineRouteV2RequestId", ""))
	var authority = fake_npc.test_route_authority_v2
	var terminal: Dictionary = authority.report_unreachable_static(request_id, "blocked_capsule_probe")
	entry_data["routeForceReplan"] = true
	var motion: Dictionary = executor.call("_advance_job_motion", entry_data, body, 1.0 / 60.0)
	var current: Dictionary = entry_data.get("routeAuthorityV2", {}) if entry_data.get("routeAuthorityV2", {}) is Dictionary else {}
	var passed := request_id != "" \
		and String(terminal.get("state", "")) == "unreachable_static" \
		and fake_npc.reservation_releases == 1 \
		and fake_npc.reservation_release_reasons == ["route_unreachable_static"] \
		and String(entry_data.get("jobObjectId", "")) == "" \
		and String(entry_data.get("jobReservationId", "")) == "" \
		and String(entry_data.get("jobPhase", "")) == "searching" \
		and not bool(entry_data.get("routeForceReplan", true)) \
		and int(current.get("generation", 0)) > int(terminal.get("generation", 0))
	var details := {
		"requestId": request_id,
		"terminal": terminal,
		"current": current,
		"motion": motion,
		"releaseReasons": fake_npc.reservation_release_reasons.duplicate(),
		"jobPhase": String(entry_data.get("jobPhase", "")),
		"routeForceReplan": bool(entry_data.get("routeForceReplan", false))
	}
	fake_npc.queue_free()
	return outcome(passed, JSON.stringify(details), ["terminal_forage_state_not_cancelled", "behavior_can_observe_terminal", "stale_force_consumed"], details)

func test_vox42_reservation_deadline_retargets(_mode: String) -> Dictionary:
	var setup := vox42_reserved_forager_setup("deadline")
	var fake_npc: FakeNpcSystem = setup.fakeNpc
	var executor: Variant = setup.executor
	var entry_data: Dictionary = setup.entry
	var body: CharacterBody3D = entry_data.get("body")
	var deadline_frames := ceili(NpcConstantsScript.FORAGE_RESERVATION_DEADLINE_SECONDS * float(Engine.physics_ticks_per_second))
	entry_data["forageReservationStartedPhysicsFrame"] = Engine.get_physics_frames() - deadline_frames - 1
	var moving_job := bool(executor.call("_update_forager_goal", entry_data, body, 1.0 / 60.0))
	var passed := moving_job \
		and fake_npc.reservation_releases == 1 \
		and fake_npc.reservation_release_reasons == ["forage_reservation_deadline"] \
		and fake_npc.forage_target_deferrals == 1 \
		and String(entry_data.get("jobReservationId", "")) == "" \
		and String(entry_data.get("jobObjectId", "")) == "" \
		and String(entry_data.get("jobPhase", "")) == "searching" \
		and not entry_data.has("forageReservationStartedPhysicsFrame")
	var details := {
		"movingJob": moving_job,
		"releaseCount": fake_npc.reservation_releases,
		"releaseReasons": fake_npc.reservation_release_reasons.duplicate(),
		"targetDeferrals": fake_npc.forage_target_deferrals,
		"jobPhase": String(entry_data.get("jobPhase", "")),
		"jobObjectId": String(entry_data.get("jobObjectId", "")),
		"jobReservationId": String(entry_data.get("jobReservationId", ""))
	}
	fake_npc.queue_free()
	return outcome(passed, JSON.stringify(details), ["forage_reservation_has_hard_deadline", "deadline_releases_capacity", "deadline_retargets_generic_forager"], details)

func test_vox42_gathering_requires_exact_arrived_claim(_mode: String) -> Dictionary:
	var setup := vox42_reserved_forager_setup("arrival")
	var fake_npc: FakeNpcSystem = setup.fakeNpc
	var executor: Variant = setup.executor
	var entry_data: Dictionary = setup.entry
	var body: CharacterBody3D = entry_data.get("body")
	var target: Vector3 = entry_data.get("jobTarget")
	body.global_position = target
	var target_cell := Vector2i(roundi(target.x / CELL), roundi(target.z / CELL))
	entry_data["jobApproachSlotPosition"] = target
	entry_data["jobApproachSlotCell"] = target_cell
	entry_data["routineRouteV2RequestId"] = "forager_arrival:v2:3:1"
	entry_data["routineRouteV2IntentKind"] = "forage"
	entry_data["routineRouteV2SemanticKind"] = "forage_target"
	entry_data["_routineRouteV2Intent"] = { "jobObjectId": "prop:arrival" }
	entry_data["jobReservationRouteRequestId"] = "forager_arrival:v2:3:1"
	entry_data["jobReservationRouteGeneration"] = 3
	entry_data["routeAuthorityV2"] = {
		"requestId": "forager_arrival:v2:3:1",
		"generation": 3,
		"state": "moving",
		"interactionClaim": {
			"objectId": "prop:arrival",
			"reservationId": String(entry_data.get("jobReservationId", "")),
			"slotId": "slot:0",
			"slotCell": target_cell,
			"slotPosition": target,
			"routeGeneration": 3
		},
		"routeLease": { "targetCell": target_cell }
	}
	executor.call("_update_forager_goal", entry_data, body, 1.0 / 60.0)
	var moving_phase := String(entry_data.get("jobPhase", ""))
	entry_data["routeAuthorityV2"]["state"] = "arrived"
	executor.call("_update_forager_goal", entry_data, body, 1.0 / 60.0)
	var arrived_phase := String(entry_data.get("jobPhase", ""))
	var passed := moving_phase == "outbound" and arrived_phase == "gathering"
	var details := { "movingPhase": moving_phase, "arrivedPhase": arrived_phase, "targetCell": target_cell }
	fake_npc.queue_free()
	return outcome(passed, JSON.stringify(details), ["proximity_without_arrival_cannot_gather", "exact_arrived_claim_enters_gathering"], details)

func test_vox42_blocked_slot_replans_to_clear_slot(_mode: String) -> Dictionary:
	var setup := vox42_reserved_forager_setup("slot_retry")
	var fake_npc: FakeNpcSystem = setup.fakeNpc
	var executor: Variant = setup.executor
	var entry_data: Dictionary = setup.entry
	var body: CharacterBody3D = entry_data.get("body")
	var blocked_position: Vector3 = entry_data.get("jobTarget")
	var clear_position := blocked_position + Vector3(0.0, 0.0, CELL)
	entry_data["jobApproachTargetObjectId"] = "prop:slot_retry"
	entry_data["jobApproachCandidateIndex"] = 0
	entry_data["jobApproachCandidates"] = [
		{ "slotId": "slot:0", "position": blocked_position, "cell": Vector2i(40, 0) },
		{ "slotId": "slot:1", "position": clear_position, "cell": Vector2i(40, 1) }
	]
	entry_data["routineRouteV2RequestId"] = "forager_slot_retry:v2:2:1"
	entry_data["routineRouteV2IntentKind"] = "forage"
	entry_data["routineRouteV2SemanticKind"] = "forage_target"
	entry_data["_routineRouteV2Intent"] = { "jobObjectId": "prop:slot_retry" }
	entry_data["jobReservationRouteRequestId"] = "forager_slot_retry:v2:2:1"
	entry_data["jobReservationRouteGeneration"] = 2
	entry_data["routeAuthorityV2"] = {
		"requestId": "forager_slot_retry:v2:2:1",
		"generation": 2,
		"state": "unreachable_static",
		"reason": "blocked_capsule_probe"
	}
	executor.call("_update_forager_goal", entry_data, body, 1.0 / 60.0)
	var advanced_slot := String(entry_data.get("jobApproachSlotId", ""))
	body.global_position = Vector3(CELL * 4.0, 0.0, 0.0)
	var route_result: Dictionary = executor.call("_advance_job_motion", entry_data, body, 1.0 / 60.0)
	var intent: Dictionary = entry_data.get("_routineRouteV2Intent", {}) if entry_data.get("_routineRouteV2Intent", {}) is Dictionary else {}
	var claim: Dictionary = intent.get("interactionClaim", {}) if intent.get("interactionClaim", {}) is Dictionary else {}
	var cells: Array = intent.get("candidateCells", []) if intent.get("candidateCells", []) is Array else []
	var passed: bool = fake_npc.forage_slot_advances == 1 \
		and advanced_slot == "slot:1" \
		and String(entry_data.get("jobPhase", "")) == "outbound" \
		and cells == [Vector2i(40, 1)] \
		and String(claim.get("slotId", "")) == "slot:1" \
		and claim.get("slotCell", Vector2i.ZERO) == Vector2i(40, 1)
	var details := {
		"slotAdvances": fake_npc.forage_slot_advances,
		"advancedSlot": advanced_slot,
		"releaseReasons": fake_npc.reservation_release_reasons.duplicate(),
		"routeResult": route_result,
		"intent": intent
	}
	fake_npc.queue_free()
	return outcome(passed, JSON.stringify(details), ["blocked_exact_slot_released", "clear_exact_slot_replanned_and_claimed"], details)

func test_vox42_pending_probe_publishes_bounded_semantic(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var fake_autonomy := FakeAutonomy.new()
	fake_npc.add_child(fake_autonomy)
	var executor: Variant = make_executor(fake_npc, fake_autonomy)
	fake_autonomy.route_authority_v2.probe_sample_budget_per_frame = 0
	var prop := Node3D.new()
	fake_npc.add_child(prop)
	prop.position = Vector3(CELL * 40.0, 0.0, 0.0)
	var entry_data := entry("Forager", { "id": "forager_pending_semantic", "job": "forage", "position": Vector3(CELL * 4.0, 0.0, 0.0) })
	var body: CharacterBody3D = entry_data.get("body")
	entry_data["jobPhase"] = "outbound"
	entry_data["jobTimer"] = 5.0
	entry_data["jobTargetNode"] = prop
	entry_data["jobTarget"] = prop.position
	entry_data["jobObjectId"] = "prop:pending_semantic"
	entry_data["jobReservationId"] = "prop:pending_semantic:slot:0:forager_pending_semantic:1"
	entry_data["jobApproachSlotId"] = "slot:0"
	entry_data["jobApproachSlotPosition"] = prop.position
	entry_data["jobApproachSlotCell"] = Vector2i(40, 0)
	for _slice in range(512):
		fake_autonomy.route_authority_v2.begin_frame()
		executor.call("_advance_job_motion", entry_data, body, 1.0 / 60.0)
		var slice_authority: Dictionary = entry_data.get("routeAuthorityV2", {}) if entry_data.get("routeAuthorityV2", {}) is Dictionary else {}
		if String(slice_authority.get("state", "")) == "probing":
			break
	var semantic_kind := String(entry_data.get("routineRouteV2SemanticKind", ""))
	var intent_kind := String(entry_data.get("routineRouteV2IntentKind", ""))
	var authority: Dictionary = entry_data.get("routeAuthorityV2", {}) if entry_data.get("routeAuthorityV2", {}) is Dictionary else {}
	authority["pendingProbeFrames"] = 300
	entry_data["routeAuthorityV2"] = authority
	var timed_out := bool(executor.call("_forager_pending_route_timed_out", entry_data, 1.0 / 60.0))
	var passed := semantic_kind == "forage_target" \
		and intent_kind == "forage" \
		and String(authority.get("state", "")) == "probing" \
		and timed_out
	var details := { "semanticKind": semantic_kind, "intentKind": intent_kind, "authority": authority, "timedOut": timed_out }
	fake_npc.queue_free()
	return outcome(passed, JSON.stringify(details), ["probing_request_publishes_forage_semantic", "probe_starvation_enters_bounded_pending_policy"], details)

func test_vox42_forage_goal_cancels_stale_home_route(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var authority = fake_npc.test_route_authority_v2
	var entry_data := entry("Forager", {
		"id": "forager-stale-home-route",
		"job": "forage",
		"position": Vector3(CELL * 4.0, 0.0, 0.0),
		"homeCell": Vector2i(-4, 0),
		"porchCell": Vector2i(-3, 0)
	})
	entry_data["activeGoalKind"] = NpcEnumsScript.GOAL_KIND_FORAGE
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_FORAGE, "reason": "role_forager_food_loop" }
	var stale_home_intent := {
		"kind": "home",
		"semanticKind": "home_interior",
		"target": Vector3(-CELL * 4.0, 0.0, 0.0),
		"priority": 140
	}
	var request: Dictionary = authority.submit_request(entry_data, stale_home_intent, { "priority": 140 })
	var request_id := String(request.get("requestId", ""))
	entry_data["homeRouteV2RequestId"] = request_id
	entry_data["_homeRouteV2Intent"] = stale_home_intent
	var service_owns: bool = executor.physics_route_service_owns_motion(entry_data)
	var runtime: Dictionary = authority.runtime_for_entry(entry_data)
	var passed: bool = request_id != "" \
		and not service_owns \
		and String(entry_data.get("homeRouteV2RequestId", "")) == "" \
		and String(runtime.get("state", "")) == "cancelled"
	var details := {
		"requestId": request_id,
		"serviceOwns": service_owns,
		"homeRequestAfter": String(entry_data.get("homeRouteV2RequestId", "")),
		"runtime": runtime
	}
	fake_npc.queue_free()
	return outcome(passed, JSON.stringify(details), ["active_forage_goal_preempts_obsolete_home_route", "obsolete_home_route_cannot_starve_forager_lifecycle"], details)

func test_vox42_pending_forage_keeps_lifecycle_owner(_mode: String) -> Dictionary:
	var setup := vox42_reserved_forager_setup("pending_lifecycle_owner")
	var fake_npc: FakeNpcSystem = setup.fakeNpc
	var executor: Variant = setup.executor
	var entry_data: Dictionary = setup.entry
	var body: CharacterBody3D = entry_data.get("body")
	body.global_position = Vector3(CELL * 4.0, 0.0, 0.0)
	fake_npc.test_route_authority_v2.plan_attempt_budget_per_frame = 0
	fake_npc.test_route_authority_v2.begin_frame()
	executor.call("_advance_job_motion", entry_data, body, 1.0 / 60.0)
	var authority: Dictionary = entry_data.get("routeAuthorityV2", {}) if entry_data.get("routeAuthorityV2", {}) is Dictionary else {}
	authority["pendingBudgetFrames"] = 300
	entry_data["routeAuthorityV2"] = authority
	var service_owns: bool = executor.physics_route_service_owns_motion(entry_data)
	var timed_out: bool = bool(executor.call("_forager_pending_route_timed_out", entry_data, 1.0 / 60.0))
	var passed: bool = String(authority.get("state", "")) == "pending_budget" \
		and String(entry_data.get("routineRouteV2IntentKind", "")) == "forage" \
		and String(entry_data.get("routineRouteV2SemanticKind", "")) == "forage_target" \
		and not service_owns \
		and timed_out
	var details := {
		"authority": authority,
		"serviceOwns": service_owns,
		"timedOut": timed_out,
		"intentKind": String(entry_data.get("routineRouteV2IntentKind", "")),
		"semanticKind": String(entry_data.get("routineRouteV2SemanticKind", ""))
	}
	fake_npc.queue_free()
	return outcome(passed, JSON.stringify(details), ["pending_forage_route_stays_with_job_lifecycle", "pending_budget_enters_bounded_release_policy"], details)

func test_vox42_pending_forage_timeout_defers_target(_mode: String) -> Dictionary:
	var setup := vox42_reserved_forager_setup("pending_timeout_defer")
	var fake_npc: FakeNpcSystem = setup.fakeNpc
	var executor: Variant = setup.executor
	var entry_data: Dictionary = setup.entry
	var body: CharacterBody3D = entry_data.get("body")
	body.global_position = Vector3(CELL * 4.0, 0.0, 0.0)
	fake_npc.test_route_authority_v2.plan_attempt_budget_per_frame = 0
	fake_npc.test_route_authority_v2.begin_frame()
	executor.call("_advance_job_motion", entry_data, body, 1.0 / 60.0)
	var authority: Dictionary = entry_data.get("routeAuthorityV2", {}) if entry_data.get("routeAuthorityV2", {}) is Dictionary else {}
	authority["pendingBudgetFrames"] = 300
	entry_data["routeAuthorityV2"] = authority
	entry_data["foragePendingRouteRetries"] = 1
	var moving_job: bool = bool(executor.call("_update_forager_goal", entry_data, body, 1.0 / 60.0))
	var passed: bool = moving_job \
		and fake_npc.reservation_releases == 1 \
		and fake_npc.reservation_release_reasons == ["pending_route_timeout"] \
		and fake_npc.forage_target_deferrals == 1 \
		and String(entry_data.get("jobPhase", "")) == "searching" \
		and String(entry_data.get("jobObjectId", "")) == "" \
		and String(entry_data.get("jobReservationId", "")) == ""
	var details := {
		"movingJob": moving_job,
		"releaseReasons": fake_npc.reservation_release_reasons.duplicate(),
		"targetDeferrals": fake_npc.forage_target_deferrals,
		"jobPhase": String(entry_data.get("jobPhase", ""))
	}
	fake_npc.queue_free()
	return outcome(passed, JSON.stringify(details), ["pending_timeout_releases_generic_reservation", "pending_timeout_defers_target_before_search"], details)

func test_vox42_non_home_door_keeps_forage_route(_mode: String) -> Dictionary:
	var setup := vox42_reserved_forager_setup("non_home_door")
	var fake_npc: FakeNpcSystem = setup.fakeNpc
	var executor: Variant = setup.executor
	var entry_data: Dictionary = setup.entry
	var body: CharacterBody3D = entry_data.get("body")
	body.global_position = Vector3(CELL * 4.0, 0.0, 0.0)
	entry_data["activeDoorPortalId"] = "door:other-building"
	entry_data["activeDoorDirection"] = "z+"
	var result: Dictionary = executor.call("_advance_job_motion", entry_data, body, 1.0 / 60.0)
	var intent: Dictionary = entry_data.get("_routineRouteV2Intent", {}) if entry_data.get("_routineRouteV2Intent", {}) is Dictionary else {}
	var passed: bool = String(intent.get("semanticKind", "")) == "forage_target" \
		and intent.get("targetCell", Vector2i.ZERO) == Vector2i(40, 0) \
		and String(result.get("reason", "")) == "job_route"
	var details := { "result": result, "intent": intent, "activeDoorPortalId": String(entry_data.get("activeDoorPortalId", "")) }
	fake_npc.queue_free()
	return outcome(passed, JSON.stringify(details), ["non_home_door_does_not_hijack_job_route", "door_crossing_continues_exact_forage_intent"], details)

func vox42_reserved_forager_setup(suffix: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var prop := Node3D.new()
	prop.name = "VOX42_%s" % suffix
	fake_npc.add_child(prop)
	prop.position = Vector3(CELL * 40.0, 0.0, 0.0)
	var entry_data := entry("Forager", {
		"id": "forager_%s" % suffix,
		"job": "forage",
		"position": Vector3.ZERO
	})
	entry_data["jobPhase"] = "outbound"
	entry_data["jobTimer"] = 5.0
	entry_data["jobTargetNode"] = prop
	entry_data["jobTarget"] = prop.position
	entry_data["jobObjectId"] = "prop:%s" % suffix
	entry_data["jobReservationId"] = "prop:%s:slot:0:forager_%s:1" % [suffix, suffix]
	entry_data["jobApproachSlotId"] = "slot:0"
	entry_data["jobApproachSlotPosition"] = prop.position
	entry_data["jobApproachSlotCell"] = Vector2i(40, 0)
	return { "fakeNpc": fake_npc, "executor": executor, "entry": entry_data }

func test_door_crossing_continues_while_brain_skipped(_mode: String) -> Dictionary:
	var fake_npc := FakeNpcSystem.new()
	var executor: Variant = make_executor(fake_npc)
	var entry_data := entry("Villager", { "position": Vector3(-1.0, 0.0, 0.0), "homeCell": Vector2i(3, 0), "porchCell": Vector2i(1, 0), "homePosition": Vector3(4.05, 0.0, 0.0) })
	entry_data["activeMotionGoal"] = { "goalKind": NpcEnumsScript.GOAL_KIND_HOME }
	entry_data["activeDoorPortalId"] = "door:test"
	entry_data["activeTrafficStepGroup"] = "movement:test"
	entry_data["activeDoorTrafficGroupId"] = "portal:test"
	var result: Dictionary = executor.advance_motion_npc(entry_data, 1.0 / 60.0, 0.0)
	var home_intent: Dictionary = entry_data.get("_homeRouteV2Intent", {}) if entry_data.get("_homeRouteV2Intent", {}) is Dictionary else {}
	var passed: bool = fake_npc.move_calls == 0 \
		and bool(result.get("advanced", false)) \
		and String(result.get("classification", "")) == "door_state" \
		and float(entry_data.get("lastMoveDistance", 0.0)) > 0.001 \
		and String(home_intent.get("kind", "")) == "home"
	fake_npc.queue_free()
	return outcome(passed, "result=%s legacyMoveCalls=%d routeMotionCalls=%d v2=%s" % [JSON.stringify(result), fake_npc.move_calls, fake_npc.route_motion_calls, JSON.stringify(home_intent)], ["door_motion_tick_without_brain", "traffic_state_preserved_during_motion", "door_crossing_uses_v2_home_route"], { "result": result, "homeIntent": home_intent, "entry": { "door": entry_data.get("activeDoorPortalId", ""), "traffic": entry_data.get("activeTrafficStepGroup", "") } })

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
	var update_end := npc_source.find("func npc_movement_is_paused")
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
	var fake_main := FakeMain.new()
	autonomy.route_world = FakeRouteWorld.new()
	autonomy.route_authority_v2 = NpcRouteAuthorityV2Script.new()
	autonomy.route_authority_v2.setup(fake_npc, fake_main, FakeCollisionProbe.new())
	fake_npc.test_route_authority_v2 = autonomy.route_authority_v2
	var perception := NpcPerceptionServiceScript.new()
	perception.setup(autonomy, fake_npc)
	var executor := NpcPlanExecutorScript.new()
	executor.setup(autonomy, fake_npc, fake_main, {
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
		"guardPosition": options.get("guardPosition", Vector3(2.7, 0.0, 0.0)),
		"insideHome": false,
		"routeStatus": "idle",
		"routeReason": "",
		"personalInventory": {}
	}
	for optional_key in ["jobTarget", "jobTargetNode", "stallPosition", "scriptedActionPosition", "dayTarget", "guardTargetCache"]:
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
