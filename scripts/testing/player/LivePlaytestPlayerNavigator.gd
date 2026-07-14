extends RefCounted
class_name LivePlaytestPlayerNavigator

const CharacterMotorProfileScript := preload("res://scripts/npc_ai/contracts/CharacterMotorProfile.gd")
const LivePlaytestPlayerRouteAuthorityV2Script := preload("res://scripts/testing/player/LivePlaytestPlayerRouteAuthorityV2.gd")
const LiveRoutePlanningProgressWatchdogScript := preload("res://scripts/testing/player/LiveRoutePlanningProgressWatchdog.gd")

const CELL := 1.35
const DEFAULT_PLAN_TIMEOUT := 12.0
const STUCK_FRAMES := 120
const STUCK_PROGRESS_EPSILON := 0.16
const STUCK_SPEED := 0.35
const PLANNER_MUTATED_ENTRY_KEYS := [
	"routeBudgetGrantedFrame",
	"routeBudgetYieldedFrame",
	"routeBudgetWaitFrames",
	"navmeshTileBudgetWaitFrames",
	"navmeshRouteTilesStillLoading",
	"navmeshEndpointTilesStillLoading",
	"navmeshMissingEndpointTiles",
	"lastNavmeshTilePublishDebug"
]

var main: Node3D
var player: CharacterBody3D
var camera: Camera3D
var runner: Node
var last_planner_service_physics_frame := -1
var route_authority_v2 = null

func setup(main_node: Node3D, player_node: CharacterBody3D, camera_node: Camera3D, runner_node: Node = null) -> void:
	main = main_node
	player = player_node
	camera = camera_node
	runner = runner_node
	if route_authority_v2 == null:
		route_authority_v2 = LivePlaytestPlayerRouteAuthorityV2Script.new()
	route_authority_v2.setup(main, player)

func route_authority_available() -> bool:
	return route_authority_v2 != null and route_authority_v2.available()

func go_to_position(target: Vector3, options := {}) -> Dictionary:
	var label := String(options.get("label", "player_route"))
	var stop_distance := float(options.get("stopDistance", options.get("stop_distance", CELL * 0.75)))
	var timeout_seconds := float(options.get("timeout", options.get("timeoutSeconds", 20.0)))
	if bool(options.get("prepareHomeEntryDoor", false)) and not bool(options.get("skipHomeDoorPreparation", false)):
		var entry_door := await _prepare_home_entry_door(target, label, timeout_seconds, options)
		if bool(entry_door.get("attempted", false)):
			_record(label, "home_entry_door_preparation", entry_door)
			if not bool(entry_door.get("ok", false)):
				return _result(false, "home_entry_door_failed", String(entry_door.get("reason", "door_action_failed")), label, target, { "homeEntryDoor": entry_door })
	if bool(options.get("tutorialPerimeterRecovery", false)):
		var recovery_timeout := float(options.get("perimeterRecoveryTimeout", clampf(timeout_seconds * 0.55, 6.0, 18.0)))
		var recovery := await _recover_tutorial_perimeter_for_target(target, label, recovery_timeout)
		if bool(recovery.get("attempted", false)):
			_record(label, "tutorial_perimeter_recovery", recovery)
			if not bool(recovery.get("ok", false)):
				return _result(false, "perimeter_recovery_failed", String(recovery.get("reason", "perimeter_recovery_failed")), label, target, { "perimeterRecovery": recovery })
	if player != null and not options.has("candidateCells") and _flat_distance(player.global_position, target) <= stop_distance:
		_record(label, "already_at_route_target", {
			"target": _vec3(target),
			"stopDistance": _rounded(stop_distance),
			"player": _vec3(player.global_position)
		})
		return _result(true, "arrived", "", label, target, { "alreadyAtTarget": true })
	var plan_timeout := float(options.get("planTimeout", minf(DEFAULT_PLAN_TIMEOUT, maxf(2.0, timeout_seconds * 0.45))))
	var route_options := options.duplicate()
	if not route_options.has("allowOutside"):
		route_options["allowOutside"] = _allow_outside_for_target(target, route_options)
	var route_meta := _push_scripted_route_target(target, bool(route_options.get("allowOutside", true)))
	var plan := await plan_route_to_position(target, stop_distance, plan_timeout, label, route_options)
	_pop_scripted_route_target(route_meta)
	if not bool(plan.get("ok", false)):
		_record(label, String(plan.get("status", "route_failed")), {
			"target": _vec3(target),
			"stopDistance": _rounded(stop_distance),
			"reason": String(plan.get("reason", "")),
			"route": plan.get("routeSummary", {})
		})
		return _result(false, String(plan.get("status", "route_failed")), String(plan.get("reason", "")), label, target, plan)
	var route: Dictionary = plan.get("route", {})
	var accept_route_goal := bool(route_options.get("acceptRouteGoal", false))
	var completion_target := _route_completion_target(route, target, accept_route_goal)
	var completion_stop_distance := float(route_options.get(
		"completionStopDistance",
		minf(stop_distance, CELL * 0.75) if accept_route_goal else stop_distance
	))
	plan["routeGoal"] = _vec3(completion_target)
	plan["completionStopDistance"] = completion_stop_distance
	var movement_started_at := _elapsed()
	var waypoints := _route_waypoints(route)
	if waypoints.is_empty():
		var arrived := _flat_distance(player.global_position, completion_target) <= completion_stop_distance
		if arrived:
			route_authority_v2.report_arrived({ "target": _vec3(target), "routeGoal": _vec3(completion_target), "player": _vec3(player.global_position) })
		return _result(arrived, "arrived" if arrived else "empty_route", "", label, target, plan)
	var execution_entry := _make_route_entry(target, stop_distance, label, route_options)
	var execution_started: Dictionary = route_authority_v2.begin_execution(execution_entry)
	if not bool(execution_started.get("ok", false)):
		return _result(false, "route_execution_authority_failed", String(execution_started.get("reason", "begin_execution_failed")), label, target, {
			"plan": plan,
			"execution": execution_started
		})
	var actions: Dictionary = route.get("actions", {}) if route.get("actions", {}) is Dictionary else {}
	var handled_actions := {}
	_record(label, "execute_ready_route", {
		"target": _vec3(target),
		"stopDistance": _rounded(stop_distance),
		"route": _route_summary(route)
	})
	for index in range(waypoints.size()):
		if _flat_distance(player.global_position, completion_target) <= completion_stop_distance:
			route_authority_v2.report_arrived({ "waypointIndex": index, "target": _vec3(target), "routeGoal": _vec3(completion_target) })
			return _result(true, "arrived", "", label, target, plan)
		var remaining := timeout_seconds - (_elapsed() - movement_started_at)
		if remaining <= 0.0:
			route_authority_v2.report_stuck("movement_timeout", { "waypointIndex": index, "target": _vec3(target) })
			return _result(false, "movement_timeout", "timeout", label, target, plan)
		var waypoint: Vector3 = waypoints[index]
		route_authority_v2.report_segment_started(index, { "waypoint": _vec3(waypoint), "player": _vec3(player.global_position) })
		var action_info := _route_action_for_waypoint(actions, waypoint, handled_actions)
		if not action_info.is_empty():
			var action: Dictionary = action_info.get("action", {})
			var action_key := String(action_info.get("key", ""))
			var action_result := await _execute_route_action(action, action_key, label, index)
			handled_actions[action_key] = true
			if not bool(action_result.get("ok", false)):
				route_authority_v2.report_door_wait(String(action_result.get("reason", "door_action_failed")), {
					"waypointIndex": index,
					"action": _route_action_summary(action)
				})
				action_result["route"] = _route_summary(route)
				return action_result
		var waypoint_stop := completion_stop_distance if index == waypoints.size() - 1 else CELL * 0.75
		var distance := _flat_distance(player.global_position, waypoint)
		var step_timeout := minf(remaining, clampf(distance / (CELL * 2.4) + 3.0, 3.0, 14.0))
		var reached := await _drive_to_point(waypoint, waypoint_stop, step_timeout, "%s_authority_%02d" % [label, index])
		if not reached:
			route_authority_v2.report_stuck("waypoint_not_reached", {
				"waypointIndex": index,
				"waypoint": _vec3(waypoint),
				"player": _vec3(player.global_position)
			})
			_record(label, "waypoint_not_reached", {
				"index": index,
				"waypoint": _vec3(waypoint),
				"player": _vec3(player.global_position),
				"route": _route_summary(route)
			})
			return _result(false, "movement_stuck", "waypoint_not_reached", label, target, plan)
		route_authority_v2.report_segment_completed(index, { "waypoint": _vec3(waypoint), "player": _vec3(player.global_position) })
	var final_remaining := timeout_seconds - (_elapsed() - movement_started_at)
	if _flat_distance(player.global_position, completion_target) <= completion_stop_distance:
		route_authority_v2.report_arrived({ "target": _vec3(target), "routeGoal": _vec3(completion_target), "player": _vec3(player.global_position) })
		return _result(true, "arrived", "", label, target, plan)
	route_authority_v2.report_stuck("route_completed_outside_target", {
		"target": _vec3(target),
		"routeGoal": _vec3(completion_target),
		"player": _vec3(player.global_position),
		"remainingSeconds": _rounded(maxf(0.0, final_remaining))
	})
	return _result(false, "route_arrival_miss", "route_completed_outside_target", label, target, plan)

func drive_to_point_for_home_exit(target: Vector3, stop_distance: float, timeout_seconds: float, label: String) -> bool:
	return await _drive_to_point(target, stop_distance, timeout_seconds, label)

func plan_route_to_position(target: Vector3, stop_distance: float, timeout_seconds: float, label: String, options := {}) -> Dictionary:
	if route_authority_v2 == null or not route_authority_v2.available():
		return {
			"ok": false,
			"status": "route_authority_missing",
			"reason": "missing_route_authority_v2",
			"routeSummary": {}
		}
	var started_at := _elapsed()
	var attempts := 0
	var last_route := {}
	var entry := _make_route_entry(target, stop_distance, label, options)
	var semantic_kind := _route_semantic_kind(target, options)
	var authority_options: Dictionary = options.duplicate(true)
	authority_options["label"] = label
	var no_progress_timeout := float(options.get("planNoProgressTimeout", maxf(4.0, timeout_seconds)))
	var hard_timeout := float(options.get("planHardTimeout", maxf(30.0, timeout_seconds * 5.0)))
	var watchdog = LiveRoutePlanningProgressWatchdogScript.new()
	watchdog.setup(started_at, timeout_seconds, no_progress_timeout, hard_timeout)
	var timeout_reason := "hard_timeout"
	while true:
		attempts += 1
		var route: Dictionary = route_authority_v2.plan_route(entry, target, semantic_kind, authority_options)
		last_route = route
		var ready := bool(route.get("ok", false))
		var pending := bool(route.get("pending", false))
		var state := String(route.get("status", ""))
		var reason := String(route.get("reason", ""))
		if ready:
			var ready_route: Dictionary = route.get("route", {}) if route.get("route", {}) is Dictionary else {}
			var probe: Dictionary = ready_route.get("collisionProbe", {}) if ready_route.get("collisionProbe", {}) is Dictionary else {}
			var probe_ok := bool(probe.get("ok", false)) and bool(probe.get("authoritative", false))
			if probe_ok:
				_record(label, "plan_ready", {
					"attempts": attempts,
					"target": _vec3(target),
					"stopDistance": _rounded(stop_distance),
					"semanticKind": semantic_kind,
					"route": _route_summary(ready_route),
					"authority": route.get("authority", {})
				})
				return {
					"ok": true,
					"status": "ready",
					"reason": "",
					"route": ready_route,
					"routeSummary": _route_summary(ready_route),
					"attempts": attempts,
					"authority": route.get("authority", {})
				}
			state = "blocked_dynamic"
			reason = String(probe.get("reason", "collision_probe_failed"))
		if bool(route.get("terminal", false)) and not pending:
			_record(label, "plan_terminal", {
				"attempts": attempts,
				"state": state,
				"reason": reason,
				"target": _vec3(target),
				"stopDistance": _rounded(stop_distance),
				"semanticKind": semantic_kind,
				"route": route.get("routeSummary", {}),
				"authority": route.get("authority", {})
			})
			return {
				"ok": false,
				"status": state if state != "" else "route_terminal",
				"reason": reason,
				"route": route.get("route", {}),
				"routeSummary": route.get("routeSummary", {}),
				"attempts": attempts,
				"authority": route.get("authority", {})
			}
		var observed_at := _elapsed()
		var watchdog_decision: Dictionary = watchdog.observe(route, observed_at)
		if bool(watchdog_decision.get("progressed", false)):
			_record(label, "plan_progress", watchdog_decision)
		if not bool(watchdog_decision.get("continue", false)):
			timeout_reason = String(watchdog_decision.get("reason", "hard_timeout"))
			_record(label, "plan_watchdog_timeout", watchdog_decision)
			break
		if attempts == 1 or attempts % 12 == 0:
			_record(label, "plan_waiting", {
				"attempts": attempts,
				"state": state,
				"reason": reason,
				"target": _vec3(target),
				"semanticKind": semantic_kind,
				"route": route.get("routeSummary", {}),
				"authority": route.get("authority", {})
			})
		await _physics_frame()
	route_authority_v2.cancel_active(entry, "player_route_plan_%s" % timeout_reason)
	_record(label, "plan_timeout", {
		"attempts": attempts,
		"target": _vec3(target),
		"stopDistance": _rounded(stop_distance),
		"semanticKind": semantic_kind,
		"route": last_route.get("routeSummary", {}),
		"authority": last_route.get("authority", {}),
		"timeoutReason": timeout_reason
	})
	return {
		"ok": false,
		"status": "pending_%s" % timeout_reason,
		"reason": timeout_reason,
		"route": last_route.get("route", {}),
		"routeSummary": last_route.get("routeSummary", {}),
		"attempts": attempts,
		"timeoutReason": timeout_reason,
		"authority": last_route.get("authority", {})
	}

func go_to_interaction_pose(target_node: Node3D, action_kind: String, options := {}) -> Dictionary:
	if target_node == null or not is_instance_valid(target_node):
		return _result(false, "action_pose_missing", "target_missing", String(options.get("label", action_kind)), Vector3.ZERO, {})
	var label := String(options.get("label", "%s_pose" % action_kind))
	var timeout_seconds := float(options.get("timeout", options.get("timeoutSeconds", 16.0)))
	var stop_distance := float(options.get("stopDistance", CELL * 0.55))
	var candidates := _interaction_pose_candidates(target_node.global_position, action_kind, options)
	var home_context := _route_home_transition_context(target_node.global_position, options)
	var attempts: Array[Dictionary] = []
	for index in range(candidates.size()):
		var pose: Vector3 = candidates[index]
		var route_options: Dictionary = options.duplicate()
		route_options["label"] = "%s_pose_%02d" % [label, index]
		route_options["stopDistance"] = stop_distance
		route_options["timeout"] = timeout_seconds
		route_options["homeTransitionContext"] = home_context
		route_options["candidateCells"] = [_world_cell(pose)]
		route_options["routeSemanticKind"] = "interaction_target"
		var result := await go_to_position(pose, route_options)
		attempts.append({
			"index": index,
			"pose": _vec3(pose),
			"ok": bool(result.get("ok", false)),
			"status": String(result.get("status", "")),
			"reason": String(result.get("reason", ""))
		})
		if bool(result.get("ok", false)):
			result["proof"] = { "pose": _vec3(pose), "attempts": attempts }
			return result
		if _route_prerequisite_failed(result):
			return result
	return _result(false, "action_pose_missing", "no_routeable_action_pose", label, target_node.global_position, { "attempts": attempts })

func use_block(block: Node3D, label: String, options := {}) -> Dictionary:
	if block == null or not is_instance_valid(block):
		return _result(false, "action_pose_missing", "target_missing", label, Vector3.ZERO, {})
	var action_kind := String(options.get("actionKind", "use_block"))
	var timeout_seconds := float(options.get("timeout", options.get("timeoutSeconds", 14.0)))
	var pose_stop_distance := float(options.get("poseStopDistance", CELL * 0.55))
	var skip_home_door_preparation := bool(options.get("skipHomeDoorPreparation", false))
	var candidates := _interaction_pose_candidates(block.global_position, action_kind, options)
	var attempts: Array[Dictionary] = []
	var remaining_candidate_cells := _candidate_cells_for_positions(candidates)
	# Opening a door approaches it from the actor's current side; a later movement request owns any crossing.
	var route_semantic_kind := "interaction_target" if String(block.get_meta("block_type", "")) == "door" else _route_semantic_kind(block.global_position, options)
	var any_route_ok := false
	var started_at := _elapsed()
	while not remaining_candidate_cells.is_empty():
		var remaining := timeout_seconds - (_elapsed() - started_at)
		if remaining <= 0.0:
			break
		# A multi-goal route optimizes travel cost, which can prefer an entry-side cell
		# over the generated pose nearest the object. Keep each action pose explicit.
		var requested_candidate_cell: Vector2i = remaining_candidate_cells.front()
		var route_timeout := minf(remaining, clampf(_flat_distance(player.global_position, block.global_position) / (CELL * 2.4) + 4.0, 5.0, 12.0))
		var route := await go_to_position(block.global_position, {
			"label": "%s_candidates" % label,
			"stopDistance": pose_stop_distance,
			"timeout": route_timeout,
			"planTimeout": minf(8.0, maxf(4.0, route_timeout * 0.7)),
			"skipHomeDoorPreparation": skip_home_door_preparation,
			"candidateCells": [requested_candidate_cell],
			"routeSemanticKind": route_semantic_kind,
			"acceptRouteGoal": true
		})
		var route_goal_cell := _result_route_goal_cell(route)
		var route_goal_position := _cell_position(route_goal_cell) if route_goal_cell.x < 2147483000 else Vector3.ZERO
		var attempt := {
			"candidateCells": _vec2i_array(remaining_candidate_cells),
			"requestedCandidateCell": _vec2i(requested_candidate_cell),
			"routeGoalCell": _vec2i(route_goal_cell) if route_goal_cell.x < 2147483000 else [],
			"routeGoal": _vec3(route_goal_position) if route_goal_cell.x < 2147483000 else [],
			"routeOk": bool(route.get("ok", false)),
			"routeStatus": String(route.get("status", "")),
			"routeReason": String(route.get("reason", ""))
		}
		if bool(route.get("ok", false)):
			any_route_ok = true
			await _wait_physics_frames(int(options.get("postMoveFrames", 24)))
			var hit := await _aim_until_block_hit(block, "%s_route_goal" % label)
			var hit_ok := bool(hit.get("matches", false)) and bool(hit.get("withinReach", false))
			attempt["hit"] = hit
			attempt["hitMatched"] = hit_ok
			attempts.append(attempt)
			_record(label, "block_pose_attempt", attempt)
			if hit_ok:
				_record(label, "block_action_dispatched", {
					"routeGoal": attempt.get("routeGoal", []),
					"hit": hit
				})
				_dispatch_mouse_button(MOUSE_BUTTON_RIGHT, true)
				_dispatch_mouse_button(MOUSE_BUTTON_RIGHT, false)
				await _wait_physics_frames(int(options.get("postActionFrames", 24)))
				_record(label, "block_action_completed", {
					"routeGoal": attempt.get("routeGoal", []),
					"postActionFrames": int(options.get("postActionFrames", 24))
				})
				return _result(true, "used", "", label, block.global_position, { "hit": hit, "routeGoal": attempt.get("routeGoal", []), "attempts": attempts })
			if route_goal_cell.x >= 2147483000 or not remaining_candidate_cells.has(route_goal_cell):
				break
			remaining_candidate_cells.erase(route_goal_cell)
		else:
			attempts.append(attempt)
			_record(label, "block_pose_attempt", attempt)
			if _route_prerequisite_failed(route):
				return _result(false, String(route.get("status", "route_failed")), String(route.get("reason", "")), label, block.global_position, { "attempts": attempts, "route": route })
			var route_status := String(route.get("status", ""))
			if route_status in ["unreachable_static", "invalid_goal"]:
				remaining_candidate_cells.erase(requested_candidate_cell)
				continue
			return _result(false, route_status if route_status != "" else "route_failed", String(route.get("reason", "")), label, block.global_position, { "attempts": attempts, "route": route })
	var status := "raycast_miss" if any_route_ok else "action_pose_missing"
	var reason := "block_not_hit_in_reach" if any_route_ok else "no_routeable_action_pose"
	return _result(false, status, reason, label, block.global_position, { "attempts": attempts })

func talk_to(npc_body: Node3D, label: String, options := {}) -> Dictionary:
	var timeout_seconds := float(options.get("timeout", options.get("timeoutSeconds", 18.0)))
	var started_at := _elapsed()
	var moving_target_attempts := maxi(1, int(options.get("movingTargetAttempts", 3)))
	var moving_target_distance := float(options.get("movingTargetReplanDistance", CELL * 0.75))
	var attempts: Array[Dictionary] = []
	var last_result := _result(false, "action_pose_missing", "talk_not_attempted", label, npc_body.global_position)
	for attempt_index in range(moving_target_attempts):
		if npc_body == null or not is_instance_valid(npc_body):
			return _result(false, "target_missing", "npc_freed_before_talk", label, Vector3.ZERO, { "talkAttempts": attempts })
		var remaining := timeout_seconds - (_elapsed() - started_at)
		if remaining <= 0.25:
			break
		var target_before := npc_body.global_position
		var pose := await go_to_interaction_pose(npc_body, "talk", {
			"label": label,
			"timeout": remaining,
			"stopDistance": float(options.get("poseStopDistance", CELL * 0.75))
		})
		if npc_body == null or not is_instance_valid(npc_body):
			return _result(false, "target_missing", "npc_freed_during_talk", label, target_before, { "pose": pose.get("proof", {}), "talkAttempts": attempts })
		var target_after := npc_body.global_position
		var moved_distance := _flat_distance(target_before, target_after)
		if not bool(pose.get("ok", false)):
			attempts.append({
				"index": attempt_index,
				"targetBefore": target_before,
				"targetAfter": target_after,
				"movedDistance": moved_distance,
				"pose": pose
			})
			last_result = pose.duplicate(true)
		else:
			var hit := await _aim_until_npc_hit(npc_body, label)
			attempts.append({
				"index": attempt_index,
				"targetBefore": target_before,
				"targetAfter": target_after,
				"movedDistance": moved_distance,
				"pose": pose.get("proof", {}),
				"hit": hit
			})
			if bool(hit.get("matches", false)):
				_dispatch_mouse_button(MOUSE_BUTTON_RIGHT, true)
				_dispatch_mouse_button(MOUSE_BUTTON_RIGHT, false)
				await _wait_physics_frames(int(options.get("postActionFrames", 24)))
				return _result(true, "talk_clicked", "", label, npc_body.global_position, { "hit": hit, "pose": pose.get("proof", {}), "talkAttempts": attempts })
			last_result = _result(false, "raycast_miss", "npc_not_hit", label, target_after, { "hit": hit, "pose": pose.get("proof", {}) })
		if moved_distance <= moving_target_distance or attempt_index + 1 >= moving_target_attempts:
			break
		await _wait_physics_frames(2)
	var proof: Dictionary = last_result.get("proof", {}) if last_result.get("proof", {}) is Dictionary else {}
	proof["talkAttempts"] = attempts
	last_result["proof"] = proof
	return last_result

func harvest_prop(prop: Node3D, label: String, options := {}) -> Dictionary:
	var pose := await go_to_interaction_pose(prop, "harvest_prop", {
		"label": label,
		"timeout": float(options.get("timeout", options.get("timeoutSeconds", 18.0))),
		"stopDistance": float(options.get("poseStopDistance", CELL * 0.55))
	})
	if not bool(pose.get("ok", false)):
		return pose
	var hit := await _aim_until_prop_hit(prop, label)
	if not bool(hit.get("matches", false)):
		return _result(false, "raycast_miss", "prop_not_hit", label, prop.global_position, { "hit": hit, "pose": pose.get("proof", {}) })
	return _result(true, "prop_hit_ready", "", label, prop.global_position, { "hit": hit, "pose": pose.get("proof", {}) })

func place_item_at_cell(item_id: String, cell: Vector2i, label: String, options := {}) -> Dictionary:
	var target_position := _cell_position(cell)
	var candidates := _placement_pose_candidates(cell, target_position, options)
	var attempts: Array[Dictionary] = []
	if candidates.is_empty():
		return _result(false, "action_pose_missing", "no_standable_placement_pose", label, target_position, { "attempts": attempts })
	var timeout_seconds := float(options.get("timeout", options.get("timeoutSeconds", 18.0)))
	var started_at := _elapsed()
	for index in range(candidates.size()):
		var remaining := timeout_seconds - (_elapsed() - started_at)
		if remaining <= 0.0:
			break
		var pose: Vector3 = candidates[index]
		var route_timeout := minf(remaining, clampf(_flat_distance(player.global_position, pose) / (CELL * 2.4) + 2.0, 3.0, 8.0))
		var route := await go_to_position(pose, {
			"label": "%s_place_pose_%02d" % [label, index],
			"stopDistance": float(options.get("poseStopDistance", CELL * 0.45)),
			"timeout": route_timeout,
			"planTimeout": minf(4.0, maxf(1.5, route_timeout * 0.55)),
			"candidateCells": [_world_cell(pose)],
			"routeSemanticKind": "interaction_target"
		})
		var attempt := {
			"index": index,
			"pose": _vec3(pose),
			"routeOk": bool(route.get("ok", false)),
			"routeStatus": String(route.get("status", "")),
			"routeReason": String(route.get("reason", ""))
		}
		if bool(route.get("ok", false)):
			var preview := await _aim_until_placement_preview_for_cells(
				item_id,
				cell,
				_placement_aim_cells(cell, item_id, options),
				"%s_pose_%02d" % [label, index],
				bool(options.get("strictPlacementCell", false))
			)
			attempt["preview"] = preview
			attempt["previewMatched"] = bool(preview.get("matches", false))
			if bool(preview.get("matches", false)):
				if bool(options.get("performAction", true)):
					_dispatch_mouse_button(MOUSE_BUTTON_RIGHT, true)
					_dispatch_mouse_button(MOUSE_BUTTON_RIGHT, false)
					await _wait_physics_frames(int(options.get("postActionFrames", 24)))
				return _result(true, "placement_ready", "", label, target_position, { "pose": _vec3(pose), "preview": preview, "attempts": attempts + [attempt] })
		attempts.append(attempt)
		_record(label, "placement_pose_attempt", attempt)
		if _route_prerequisite_failed(route):
			return _result(false, String(route.get("status", "route_failed")), String(route.get("reason", "")), label, target_position, { "attempts": attempts, "route": route })
	return _result(false, "placement_preview_miss", "no_routeable_preview_pose", label, target_position, { "attempts": attempts })

func _make_route_entry(target: Vector3, stop_distance: float, label: String, options := {}) -> Dictionary:
	var town_center := _flat_cell(player.global_position)
	var tutorial = main.get("tutorial_system") if main != null else null
	if tutorial != null and tutorial.has_method("state"):
		var state: Dictionary = tutorial.call("state")
		var town_center_value = state.get("townCenter", town_center)
		if town_center_value is Vector2i:
			town_center = town_center_value
	var home_context := _route_home_transition_context(target, options)
	var route_home: Dictionary = home_context.get("entry", {}) if home_context.get("entry", {}) is Dictionary else {}
	var inside_home := not route_home.is_empty() and _position_inside_entry_home(route_home, player.global_position)
	var entry := {
		"id": "live_playtest_player",
		"name": "Live Playtest Player",
		"body": player,
		"position": player.global_position if player != null else Vector3.ZERO,
		"motorProfile": CharacterMotorProfileScript.player_default(),
		"agentContext": { "traversal_profile_id": "player" },
		"routeIntentKind": "scripted",
		"activeGoalKind": "scripted",
		"goal": "live_playtest_player_route",
		"job": "playtest",
		"routePriority": 220,
		"routeForceReplan": true,
		"routeStatus": "",
		"routeReason": "",
		"routeActions": {},
		"pathWaypoints": [],
		"routeCells": [],
		"routeDynamicAvoidCells": [],
		"routeBudgetGrantedFrame": -999999,
		"routeBudgetYieldedFrame": -999999,
		"routeBudgetWaitFrames": 0,
		"navmeshTileBudgetWaitFrames": 0,
		"insideHome": inside_home,
		"insideTown": absi(_flat_cell(player.global_position).x - town_center.x) <= 25 and absi(_flat_cell(player.global_position).y - town_center.y) <= 25,
		"townCenter": town_center,
		"townRadius": 25,
		"townKey": "live_tutorial_player",
		"simulationLod": "active",
		"debugRouteLabel": label,
		"debugStopDistance": stop_distance,
		"debugTarget": target
	}
	if not route_home.is_empty():
		for key in ["homeCell", "doorCell", "porchCell", "interiorLandingCell", "interiorMinCell", "interiorMaxCell", "homeStableId", "doorPortalId", "activeDoorPortalId", "porchPosition", "doorPosition"]:
			if route_home.has(key):
				entry[key] = route_home.get(key)
		entry["playerHomeTransition"] = String(home_context.get("kind", ""))
	return entry

func _apply_planner_entry_state(entry: Dictionary, state: Dictionary) -> void:
	for key in PLANNER_MUTATED_ENTRY_KEYS:
		if state.has(key):
			entry[key] = _planner_state_copy(state.get(key))

func _capture_planner_entry_state(entry: Dictionary, state: Dictionary) -> void:
	for key in PLANNER_MUTATED_ENTRY_KEYS:
		if entry.has(key):
			state[key] = _planner_state_copy(entry.get(key))
		elif state.has(key):
			state.erase(key)

func _planner_state_copy(value):
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	if value is Array:
		return (value as Array).duplicate(true)
	return value

func _planner_entry_state_summary(state: Dictionary) -> Dictionary:
	var publish_debug: Array = state.get("lastNavmeshTilePublishDebug", []) if state.get("lastNavmeshTilePublishDebug", []) is Array else []
	var publish_summary: Array[Dictionary] = []
	for item in publish_debug:
		if publish_summary.size() >= 8:
			break
		if item is Dictionary:
			var row: Dictionary = item
			var region: Dictionary = row.get("region", {}) if row.get("region", {}) is Dictionary else {}
			var summary := {
				"tile": String(row.get("tile", "")),
				"status": String(row.get("status", "")),
				"published": bool(row.get("published", false)),
				"installed": bool(row.get("installed", region.get("installed", false)))
			}
			if not region.is_empty():
				summary["regionInstalled"] = bool(region.get("installed", false))
				summary["regionDirty"] = bool(region.get("dirty", false))
				summary["surfaceCount"] = int(region.get("surfaceCount", 0))
				summary["installStatus"] = String(region.get("installStatus", ""))
			publish_summary.append(summary)
	return {
		"routeBudgetWaitFrames": int(state.get("routeBudgetWaitFrames", 0)),
		"routeBudgetGrantedFrame": int(state.get("routeBudgetGrantedFrame", -999999)),
		"routeBudgetYieldedFrame": int(state.get("routeBudgetYieldedFrame", -999999)),
		"navmeshTileBudgetWaitFrames": int(state.get("navmeshTileBudgetWaitFrames", 0)),
		"navmeshRouteTilesStillLoading": bool(state.get("navmeshRouteTilesStillLoading", false)),
		"navmeshEndpointTilesStillLoading": bool(state.get("navmeshEndpointTilesStillLoading", false)),
		"navmeshMissingEndpointTiles": state.get("navmeshMissingEndpointTiles", []),
		"lastNavmeshTilePublishDebug": publish_summary
	}

func _planner_stats_summary() -> Dictionary:
	var planner = _route_planner()
	if planner == null or not planner.has_method("stats"):
		return {}
	var stats_value = planner.call("stats")
	var stats: Dictionary = stats_value if stats_value is Dictionary else {}
	var delegate: Dictionary = stats.get("delegate", {}) if stats.get("delegate", {}) is Dictionary else {}
	var queue_debug: Array = delegate.get("lastNavmeshTileQueueDebug", []) if delegate.get("lastNavmeshTileQueueDebug", []) is Array else []
	var queue_summary: Array[Dictionary] = []
	for item in queue_debug:
		if queue_summary.size() >= 8:
			break
		if not (item is Dictionary):
			continue
		var row: Dictionary = item
		var region: Dictionary = row.get("region", {}) if row.get("region", {}) is Dictionary else {}
		var summary := {
			"tile": String(row.get("tile", "")),
			"status": String(row.get("status", "")),
			"priority": bool(row.get("priority", false)),
			"foreground": bool(row.get("foreground", false)),
			"rank": int(row.get("rank", 0))
		}
		if row.has("surfaces"):
			summary["surfaces"] = int(row.get("surfaces", 0))
		if row.has("installed"):
			summary["installed"] = bool(row.get("installed", false))
		if not region.is_empty():
			summary["regionInstalled"] = bool(region.get("installed", false))
			summary["regionDirty"] = bool(region.get("dirty", false))
			summary["surfaceCount"] = int(region.get("surfaceCount", 0))
			summary["installStatus"] = String(region.get("installStatus", ""))
		var context: Dictionary = row.get("context", {}) if row.get("context", {}) is Dictionary else {}
		if not context.is_empty():
			summary["contextReason"] = String(context.get("reason", ""))
			summary["contextIntent"] = String(context.get("intentKind", ""))
			summary["contextActor"] = String(context.get("actorId", ""))
			summary["refreshCount"] = int(context.get("queueRefreshCount", 0))
		queue_summary.append(summary)
	return {
		"authority": stats.get("authority", {}),
		"queuedNavmeshTiles": int(delegate.get("queuedNavmeshTiles", 0)),
		"queuedNavmeshTileKeys": delegate.get("queuedNavmeshTileKeys", []),
		"queuedNavmeshPriorityTiles": int(delegate.get("queuedNavmeshPriorityTiles", 0)),
		"navmeshTilePublishesThisFrame": int(delegate.get("navmeshTilePublishesThisFrame", 0)),
		"lastNavmeshTileQueueDebug": queue_summary
	}

func _service_route_planner_frame(planner) -> void:
	if planner == null or not planner.has_method("begin_frame"):
		return
	var physics_frame := Engine.get_physics_frames()
	if last_planner_service_physics_frame == physics_frame:
		return
	planner.call("begin_frame")
	last_planner_service_physics_frame = physics_frame

func _make_route_intent(target: Vector3, stop_distance: float, label: String, options := {}) -> Dictionary:
	var home_context := _route_home_transition_context(target, options)
	var moving_home := bool(options.get("movingHome", false)) or String(home_context.get("kind", "")) in ["enter", "exit"]
	return {
		"kind": "scripted",
		"target": target,
		"targetCell": _world_cell(target),
		"allowOutside": _allow_outside_for_target(target, options),
		"movingHome": moving_home,
		"arrivalRadius": stop_distance,
		"priority": 220,
		"action": "",
		"interruptible": false,
		"allowPartial": false,
		"strictArrival": true,
		"requiresAuthorityProbe": true,
		"label": label
	}

func _route_semantic_kind(target: Vector3, options := {}) -> String:
	var requested := String(options.get("routeSemanticKind", ""))
	if requested != "":
		return requested
	var home_context := _route_home_transition_context(target, options)
	var home_kind := String(home_context.get("kind", ""))
	if home_kind in ["enter", "inside"] and not bool(options.get("allowOutside", _allow_outside_for_target(target, options))):
		return "home_interior"
	if home_kind == "exit":
		return "home_exterior"
	return "interaction_target"

func _drive_to_point(target: Vector3, stop_distance: float, timeout_seconds: float, label: String) -> bool:
	if player == null:
		return false
	var started_at := _elapsed()
	var best_distance := INF
	var best_position := player.global_position
	var stuck_frames := 0
	var movement_frames := 0
	while _elapsed() - started_at < timeout_seconds:
		var offset := Vector3(target.x - player.global_position.x, 0.0, target.z - player.global_position.z)
		var distance := offset.length()
		if distance <= stop_distance:
			_stop_player()
			return true
		var horizontal_speed := Vector2(player.velocity.x, player.velocity.z).length()
		if distance < best_distance - STUCK_PROGRESS_EPSILON:
			best_distance = distance
			best_position = player.global_position
			stuck_frames = 0
		elif horizontal_speed <= STUCK_SPEED and _flat_distance(player.global_position, best_position) <= STUCK_PROGRESS_EPSILON:
			stuck_frames += 1
		else:
			stuck_frames = maxi(0, stuck_frames - 1)
		if stuck_frames >= STUCK_FRAMES:
			_stop_player()
			_record(label, "movement_stuck", {
				"target": _vec3(target),
				"player": _vec3(player.global_position),
				"bestDistance": _rounded(best_distance),
				"currentDistance": _rounded(distance),
				"velocity": _vec3(player.velocity),
				"slideCollisionCount": player.get_slide_collision_count(),
				"playerMotion": _player_motion_diagnostics()
			})
			return false
		player.set("automated_move", offset.normalized())
		player.set("automated_sprint", false)
		await _physics_frame()
		movement_frames += 1
		if movement_frames % 30 == 0:
			_record(label, "movement_progress", {
				"target": _vec3(target),
				"player": _vec3(player.global_position),
				"currentDistance": _rounded(_flat_distance(player.global_position, target)),
				"bestDistance": _rounded(best_distance),
				"movementFrames": movement_frames
			})
	_stop_player()
	return _flat_distance(player.global_position, target) <= stop_distance

func _player_motion_diagnostics() -> Dictionary:
	if player == null:
		return {}
	var proof_value = player.get("last_terrain_collision_proof")
	var proof: Dictionary = proof_value if proof_value is Dictionary else {}
	var summary := {
		"terrainCollisionHold": bool(player.get_meta("terrain_collision_hold", false)),
		"terrainCollisionHoldReason": String(player.get_meta("terrain_collision_hold_reason", "")),
		"terrainCollisionHoldFrames": int(player.get("terrain_collision_hold_frames")),
		"proofPassed": bool(proof.get("passed", false)),
		"proofReason": String(proof.get("reason", "")),
		"failedSample": int(proof.get("failedSample", -1)),
		"sampleCount": int(proof.get("sampleCount", 0))
	}
	var proofs: Array = proof.get("proofs", []) if proof.get("proofs", []) is Array else []
	if not proofs.is_empty():
		var failed_index := clampi(int(proof.get("failedSample", 0)), 0, proofs.size() - 1)
		if proofs[failed_index] is Dictionary:
			summary["failedProof"] = (proofs[failed_index] as Dictionary).duplicate(true)
	return summary

func _execute_route_action(action: Dictionary, action_key: String, label: String, waypoint_index: int) -> Dictionary:
	if String(action.get("kind", "")) != "door":
		return _result(true, "action_skipped", "", label, Vector3.ZERO, {})
	var door := _route_action_door(action)
	if door == null or not is_instance_valid(door):
		return _result(false, "door_action_failed", "door_missing", label, Vector3.ZERO, { "action": _route_action_summary(action), "actionKey": action_key })
	if bool(door.get_meta("open", false)):
		_record(label, "door_already_open", { "actionKey": action_key, "door": _node_summary(door), "waypointIndex": waypoint_index })
		return _result(true, "door_open", "", label, door.global_position, {})
	var entry_position := _vector3_from_value(action.get("entryPosition", door.global_position), door.global_position)
	if _flat_distance(player.global_position, entry_position) > CELL * 0.8:
		return _result(false, "door_action_failed", "door_entry_not_reached_by_route", label, door.global_position, {
			"door": _node_summary(door),
			"entryPosition": _vec3(entry_position),
			"player": _vec3(player.global_position)
		})
	await _wait_physics_frames(12)
	var hit := await _aim_until_block_hit(door, "%s_door_%02d" % [label, waypoint_index])
	if not bool(hit.get("matches", false)):
		return _result(false, "door_action_failed", "door_aim_miss", label, door.global_position, { "door": _node_summary(door), "hit": hit })
	_dispatch_mouse_button(MOUSE_BUTTON_RIGHT, true)
	_dispatch_mouse_button(MOUSE_BUTTON_RIGHT, false)
	await _wait_physics_frames(24)
	var opened := bool(door.get_meta("open", false))
	_record(label, "door_action", { "actionKey": action_key, "opened": opened, "door": _node_summary(door), "hit": hit })
	return _result(opened, "door_open" if opened else "door_action_failed", "" if opened else "door_did_not_open", label, door.global_position, { "door": _node_summary(door), "hit": hit })

func _recover_tutorial_perimeter_for_target(target: Vector3, label: String, timeout_seconds: float) -> Dictionary:
	if runner == null or player == null or main == null:
		return { "attempted": false, "reason": "missing_runner_or_player" }
	if not runner.has_method("tutorial_perimeter_crossing"):
		return { "attempted": false, "reason": "runner_has_no_perimeter_contract" }
	var tutorial = main.get("tutorial_system") if main != null else null
	if tutorial == null or not tutorial.has_method("state"):
		return { "attempted": false, "reason": "tutorial_state_missing" }
	var state: Dictionary = tutorial.call("state")
	var town_center: Vector2i = state.get("townCenter", _flat_cell(target))
	var current_cell := _flat_cell(player.global_position)
	var target_cell := _flat_cell(target)
	var crossing_value = runner.call("tutorial_perimeter_crossing", current_cell, target_cell, town_center)
	if not (crossing_value is Dictionary):
		return { "attempted": false, "reason": "perimeter_contract_missing" }
	var crossing: Dictionary = crossing_value
	if not bool(crossing.get("active", false)):
		return { "attempted": false, "reason": "same_perimeter_side" }
	var started_at := _elapsed()
	var approach_cell := _vector2i_from_value(crossing.get("approachCell", current_cell), current_cell)
	var gate_cell := _vector2i_from_value(crossing.get("gateCell", approach_cell), approach_cell)
	var tail_cells: Array = crossing.get("tailCells", []) if crossing.get("tailCells", []) is Array else []
	var exit_cell := approach_cell
	if tail_cells.size() >= 2:
		exit_cell = _vector2i_from_value(tail_cells[1], approach_cell)
	var proof := {
		"attempted": true,
		"direction": String(crossing.get("direction", "")),
		"currentCell": _vec2i(current_cell),
		"targetCell": _vec2i(target_cell),
		"approachCell": _vec2i(approach_cell),
		"gateCell": _vec2i(gate_cell),
		"exitCell": _vec2i(exit_cell)
	}
	var approach_position := _cell_position(approach_cell)
	var approach_result := await go_to_position(approach_position, {
		"label": "%s_perimeter_approach" % label,
		"stopDistance": CELL * 0.8,
		"timeout": minf(timeout_seconds, 10.0),
		"tutorialPerimeterRecovery": false
	})
	proof["approach"] = approach_result
	if not bool(approach_result.get("ok", false)):
		proof["ok"] = false
		proof["reason"] = "perimeter_approach_not_reached"
		return proof
	var remaining := timeout_seconds - (_elapsed() - started_at)
	if remaining <= 0.0:
		proof["ok"] = false
		proof["reason"] = "perimeter_recovery_timeout_before_gate"
		return proof
	var gate_result := await _open_tutorial_perimeter_gate(gate_cell, label, minf(remaining, 10.0))
	proof["gate"] = gate_result
	if not bool(gate_result.get("ok", false)):
		proof["ok"] = false
		proof["reason"] = String(gate_result.get("reason", "perimeter_gate_not_opened"))
		return proof
	remaining = timeout_seconds - (_elapsed() - started_at)
	if remaining <= 0.0:
		proof["ok"] = false
		proof["reason"] = "perimeter_recovery_timeout_before_exit"
		return proof
	var exit_position := _cell_position(exit_cell)
	var exit_result := await go_to_position(exit_position, {
		"label": "%s_perimeter_exit" % label,
		"stopDistance": CELL * 0.85,
		"timeout": minf(remaining, 10.0),
		"tutorialPerimeterRecovery": false
	})
	proof["exit"] = exit_result
	if not bool(exit_result.get("ok", false)):
		proof["ok"] = false
		proof["reason"] = "perimeter_exit_not_reached"
		return proof
	proof["ok"] = true
	proof["reason"] = ""
	return proof

func _open_tutorial_perimeter_gate(gate_cell: Vector2i, label: String, timeout_seconds: float) -> Dictionary:
	var gate_position := _cell_position(gate_cell)
	var gate := _nearest_block("door", gate_position)
	if gate == null or not is_instance_valid(gate) or _flat_distance(gate.global_position, gate_position) > CELL * 2.0:
		return _result(false, "door_action_failed", "perimeter_gate_missing", label, gate_position, { "gateCell": _vec2i(gate_cell), "gatePosition": _vec3(gate_position) })
	if bool(gate.get_meta("open", false)):
		return _result(true, "door_open", "", label, gate.global_position, { "gate": _node_summary(gate), "alreadyOpen": true })
	var reached := await go_to_position(gate.global_position, {
		"label": "%s_perimeter_gate" % label,
		"stopDistance": CELL * 1.65,
		"timeout": timeout_seconds,
		"tutorialPerimeterRecovery": false
	})
	if not bool(reached.get("ok", false)):
		return _result(false, "door_action_failed", "perimeter_gate_not_reached", label, gate.global_position, { "gate": _node_summary(gate), "route": reached })
	var hit := await _aim_until_block_hit(gate, "%s_perimeter_gate" % label)
	if not bool(hit.get("matches", false)):
		return _result(false, "door_action_failed", "perimeter_gate_aim_miss", label, gate.global_position, { "gate": _node_summary(gate), "hit": hit })
	_dispatch_mouse_button(MOUSE_BUTTON_RIGHT, true)
	_dispatch_mouse_button(MOUSE_BUTTON_RIGHT, false)
	await _wait_physics_frames(24)
	var opened := bool(gate.get_meta("open", false))
	return _result(opened, "door_open" if opened else "door_action_failed", "" if opened else "perimeter_gate_did_not_open", label, gate.global_position, { "gate": _node_summary(gate), "hit": hit })

func _interaction_pose_candidates(target: Vector3, action_kind: String, options := {}) -> Array[Vector3]:
	var result: Array[Vector3] = []
	var seen := {}
	var allow_outside := _allow_outside_for_target(target, options)
	var home_context := _route_home_transition_context(target, options)
	var pose_home := _interaction_pose_home(target, options)
	var pose_home_region := _interaction_pose_home_region(pose_home, options)
	var moving_home := String(home_context.get("kind", "")) in ["enter", "exit"]
	var max_pose_distance := float(options.get("maxActionPoseDistance", CELL * 5.0))
	var route_meta := _push_scripted_route_target(target, allow_outside)
	var entry := _make_route_entry(target, CELL * 0.55, "%s_candidates" % action_kind, options)
	var target_cell := _world_cell(target)
	if player != null and _flat_distance(player.global_position, target) <= float(options.get("currentPoseRadius", CELL * 3.0)):
		_add_standable_cell_position(result, seen, entry, _world_cell(player.global_position), allow_outside, moving_home, target_cell, target, max_pose_distance)
	_add_approach_cell_positions(result, seen, entry, target, allow_outside, moving_home, target_cell, max_pose_distance)
	var closest := _closest_walkable(target, float(options.get("closestWalkableRadius", max_pose_distance)))
	if bool(closest.get("found", false)) and closest.get("position") is Vector3:
		_add_standable_cell_position(result, seen, entry, _world_cell(closest.get("position")), allow_outside, moving_home, target_cell, target, max_pose_distance)
	for radius in [1.4, 2.0, 2.6, 3.2]:
		for direction in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1), Vector2(1, 1).normalized(), Vector2(-1, 1).normalized(), Vector2(1, -1).normalized(), Vector2(-1, -1).normalized()]:
			var candidate := target + Vector3(direction.x * CELL * float(radius), 0.0, direction.y * CELL * float(radius))
			candidate = _surface_position(candidate)
			var candidate_closest := _closest_walkable(candidate, CELL * 1.4)
			if bool(candidate_closest.get("found", false)) and candidate_closest.get("position") is Vector3:
				candidate = candidate_closest.get("position")
			_add_standable_cell_position(result, seen, entry, _world_cell(candidate), allow_outside, moving_home, target_cell, target, max_pose_distance)
	result = _filter_interaction_pose_home_region(result, pose_home, pose_home_region)
	result.sort_custom(func(a: Vector3, b: Vector3):
		var a_target_distance := _flat_distance(target, a)
		var b_target_distance := _flat_distance(target, b)
		if absf(a_target_distance - b_target_distance) > CELL * 0.35:
			return a_target_distance < b_target_distance
		return _flat_distance(player.global_position, a) < _flat_distance(player.global_position, b)
	)
	_pop_scripted_route_target(route_meta)
	return result

func _placement_pose_candidates(cell: Vector2i, target_position: Vector3, options := {}) -> Array[Vector3]:
	var result: Array[Vector3] = []
	var seen := {}
	var allow_outside := _allow_outside_for_target(target_position, options)
	var home_context := _route_home_transition_context(target_position, options)
	var moving_home := bool(options.get("movingHome", false)) or String(home_context.get("kind", "")) in ["enter", "exit"]
	var route_meta := _push_scripted_route_target(target_position, allow_outside)
	var entry := _make_route_entry(target_position, CELL * 0.55, "placement_candidates", options)
	var max_pose_distance := float(options.get("maxPlacementPoseDistance", CELL * 5.0))
	if player != null and _flat_distance(player.global_position, target_position) <= float(options.get("currentPoseRadius", CELL * 2.65)):
		var current_cell := _world_cell(player.global_position)
		if _cell_is_static_standable_goal(entry, current_cell, allow_outside, moving_home):
			_add_unique_position(result, seen, _cell_position(current_cell))
	_add_approach_cell_positions(result, seen, entry, target_position, allow_outside, moving_home, cell, max_pose_distance)
	for radius in range(1, int(options.get("placementSearchRadiusCells", 8)) + 1):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if max(absi(dx), absi(dz)) != radius:
					continue
				var candidate_cell := cell + Vector2i(dx, dz)
				_add_standable_cell_position(result, seen, entry, candidate_cell, allow_outside, moving_home, cell, target_position, max_pose_distance)
	var closest := _closest_walkable(target_position, max_pose_distance)
	if bool(closest.get("found", false)) and closest.get("position") is Vector3:
		var closest_position: Vector3 = closest.get("position")
		_add_standable_cell_position(result, seen, entry, _world_cell(closest_position), allow_outside, moving_home, cell, target_position, max_pose_distance)
	var has_preferred_position := false
	var preferred_position := Vector3.ZERO
	var preferred_value = options.get("preferredStandTowardCell", null)
	if preferred_value is Vector2i:
		preferred_position = _cell_position(preferred_value)
		has_preferred_position = true
	result.sort_custom(func(a: Vector3, b: Vector3):
		if has_preferred_position:
			var a_preference := _placement_side_preference(a, target_position, preferred_position)
			var b_preference := _placement_side_preference(b, target_position, preferred_position)
			if absf(a_preference - b_preference) > 0.18:
				return a_preference > b_preference
		var a_target_distance := _flat_distance(target_position, a)
		var b_target_distance := _flat_distance(target_position, b)
		if absf(a_target_distance - b_target_distance) > CELL * 0.35:
			return a_target_distance < b_target_distance
		return _flat_distance(player.global_position, a) < _flat_distance(player.global_position, b)
	)
	_pop_scripted_route_target(route_meta)
	return result

func _placement_side_preference(position: Vector3, target_position: Vector3, preferred_position: Vector3) -> float:
	var preferred := Vector2(preferred_position.x - target_position.x, preferred_position.z - target_position.z)
	var candidate := Vector2(position.x - target_position.x, position.z - target_position.z)
	if preferred.length_squared() <= 0.001 or candidate.length_squared() <= 0.001:
		return 0.0
	return candidate.normalized().dot(preferred.normalized())

func _add_approach_cell_positions(result: Array[Vector3], seen: Dictionary, entry: Dictionary, target_position: Vector3, allow_outside: bool, moving_home: bool, excluded_cell: Vector2i, max_pose_distance: float) -> void:
	var nav_world = _navigation_world()
	if nav_world == null or not nav_world.has_method("approach_cells_for_target"):
		return
	var cells: Array = nav_world.call("approach_cells_for_target", entry, target_position, allow_outside)
	for cell_value in cells:
		if cell_value is Vector2i:
			_add_standable_cell_position(result, seen, entry, cell_value, allow_outside, moving_home, excluded_cell, target_position, max_pose_distance)

func _add_standable_cell_position(result: Array[Vector3], seen: Dictionary, entry: Dictionary, cell: Vector2i, allow_outside: bool, moving_home: bool, excluded_cell: Vector2i, target_position: Vector3, max_pose_distance: float) -> void:
	if cell == excluded_cell:
		return
	var center := _cell_position(cell)
	if _flat_distance(center, target_position) > max_pose_distance:
		return
	if not _cell_is_static_standable_goal(entry, cell, allow_outside, moving_home):
		return
	_add_unique_position(result, seen, center)
	var toward := Vector2(target_position.x - center.x, target_position.z - center.z)
	if toward.length_squared() > 0.001:
		toward = toward.normalized()
		var inset := _surface_position(center + Vector3(toward.x * CELL * 0.42, 0.0, toward.y * CELL * 0.42))
		_add_unique_position(result, seen, inset)

func _cell_is_static_standable_goal(entry: Dictionary, cell: Vector2i, allow_outside := true, moving_home := false) -> bool:
	var nav_world = _navigation_world()
	if nav_world != null:
		if nav_world.has_method("cell_is_static_standable_goal"):
			return bool(nav_world.call("cell_is_static_standable_goal", entry, cell, allow_outside, moving_home))
		if nav_world.has_method("cell_is_standable_goal"):
			return bool(nav_world.call("cell_is_standable_goal", entry, cell, allow_outside, moving_home))
	var autonomy = _autonomy_system()
	if autonomy != null and autonomy.has_method("cell_is_standable_goal"):
		return bool(autonomy.call("cell_is_standable_goal", entry, cell, allow_outside, moving_home))
	return false

func _route_planner():
	var npc_system = main.get("npc_system") if main != null else null
	if npc_system == null:
		return null
	var pathing = npc_system.get("pathing")
	if pathing == null:
		return null
	var planner = pathing.get("route_planner")
	if planner != null and planner.has_method("plan_route"):
		return planner
	var coordinator = pathing.get("coordinator")
	if coordinator != null:
		planner = coordinator.get("route_planner")
		if planner != null and planner.has_method("plan_route"):
			return planner
	return null

func _navigation_world():
	var npc_system = main.get("npc_system") if main != null else null
	if npc_system == null:
		return null
	var pathing = npc_system.get("pathing")
	if pathing == null:
		return null
	var navigation_world = pathing.get("navigation_world")
	if navigation_world != null:
		return navigation_world
	var coordinator = pathing.get("coordinator")
	if coordinator != null:
		navigation_world = coordinator.get("navigation_world")
	return navigation_world

func _autonomy_system():
	var npc_system = main.get("npc_system") if main != null else null
	return npc_system.get("autonomy_system") if npc_system != null else null

func _closest_walkable(position: Vector3, max_distance: float) -> Dictionary:
	var autonomy = _autonomy_system()
	if autonomy != null and autonomy.has_method("closest_walkable"):
		var value = autonomy.call("closest_walkable", position, max_distance)
		if value is Dictionary:
			return value
	return {}

func _current_home_entry() -> Dictionary:
	if runner != null and runner.has_method("player_current_home_entry"):
		var value = runner.call("player_current_home_entry")
		if value is Dictionary:
			return value
	return {}

func _home_transition_context(target: Vector3) -> Dictionary:
	var current_home := _current_home_entry()
	var target_home := _home_entry_containing_position(target)
	if not current_home.is_empty() and not _position_inside_entry_home(current_home, target):
		return { "kind": "exit", "entry": current_home }
	if current_home.is_empty() and not target_home.is_empty():
		return { "kind": "enter", "entry": target_home }
	if not current_home.is_empty():
		return { "kind": "inside", "entry": current_home }
	return { "kind": "none", "entry": {} }

func _interaction_pose_home(target: Vector3, options := {}) -> Dictionary:
	var supplied = options.get("poseHomeEntry", {})
	if supplied is Dictionary and not (supplied as Dictionary).is_empty():
		return (supplied as Dictionary).duplicate(true)
	return _home_entry_containing_position(target)

func _interaction_pose_home_region(entry: Dictionary, options := {}) -> String:
	var requested := String(options.get("poseHomeRegion", ""))
	if requested in ["inside", "outside"] and not entry.is_empty():
		return requested
	return "inside" if not entry.is_empty() else ""

func _filter_interaction_pose_home_region(candidates: Array[Vector3], entry: Dictionary, region: String) -> Array[Vector3]:
	if entry.is_empty() or region == "":
		return candidates
	var filtered: Array[Vector3] = []
	for candidate in candidates:
		var inside := _position_inside_entry_home(entry, candidate)
		if (region == "inside" and inside) or (region == "outside" and not inside):
			filtered.append(candidate)
	return filtered

func _route_home_transition_context(target: Vector3, options := {}) -> Dictionary:
	var supplied = options.get("homeTransitionContext", {})
	if supplied is Dictionary:
		var context: Dictionary = supplied
		var kind := String(context.get("kind", ""))
		var entry: Dictionary = context.get("entry", {}) if context.get("entry", {}) is Dictionary else {}
		if kind in ["enter", "exit", "inside"] and not entry.is_empty():
			return { "kind": kind, "entry": entry.duplicate(true) }
	return _home_transition_context(target)

func _allow_outside_for_target(target: Vector3, options := {}) -> bool:
	if options.has("allowOutside"):
		return bool(options.get("allowOutside", true))
	var home_context := _route_home_transition_context(target, options)
	return String(home_context.get("kind", "")) not in ["enter", "inside"]

func _prepare_home_entry_door(target: Vector3, label: String, timeout_seconds: float, options := {}) -> Dictionary:
	var home_context := _route_home_transition_context(target, options)
	if String(home_context.get("kind", "")) != "enter":
		return { "attempted": false, "ok": true, "reason": "not_entering_home" }
	var entry: Dictionary = home_context.get("entry", {}) if home_context.get("entry", {}) is Dictionary else {}
	var door := _home_entry_door(entry)
	if door == null or not is_instance_valid(door):
		return {
			"attempted": true,
			"ok": false,
			"reason": "manifest_home_door_missing",
			"home": _home_entry_summary(entry)
		}
	if not _manifest_home_door_matches_entry(entry, door):
		return {
			"attempted": true,
			"ok": false,
			"reason": "manifest_home_door_mismatch",
			"home": _home_entry_summary(entry),
			"door": _node_summary(door)
		}
	var action_timeout := clampf(timeout_seconds * 0.45, 5.0, 12.0)
	var door_pose := await _reach_home_entry_door_pose(entry, door, "%s_home_entry_door" % label, action_timeout)
	if not bool(door_pose.get("ok", false)):
		return {
			"attempted": true,
			"ok": false,
			"reason": String(door_pose.get("reason", "home_entry_door_pose_unreachable")),
			"home": _home_entry_summary(entry),
			"door": _node_summary(door),
			"doorPose": door_pose
		}
	if bool(door.get_meta("open", false)):
		return {
			"attempted": true,
			"ok": true,
			"reason": "door_already_open",
			"home": _home_entry_summary(entry),
			"door": _node_summary(door),
			"doorPose": door_pose
		}
	_dispatch_mouse_button(MOUSE_BUTTON_RIGHT, true)
	_dispatch_mouse_button(MOUSE_BUTTON_RIGHT, false)
	await _wait_physics_frames(6)
	var opened := bool(door.get_meta("open", false))
	return {
		"attempted": true,
		"ok": opened,
		"reason": "door_opened_by_live_input" if opened else "door_action_failed",
		"home": _home_entry_summary(entry),
		"door": _node_summary(door),
		"doorOpen": opened,
		"doorPose": door_pose
	}

func _reach_home_entry_door_pose(entry: Dictionary, door: Node3D, label: String, timeout_seconds: float) -> Dictionary:
	var candidates := _interaction_pose_candidates(door.global_position, "door", {
		"allowOutside": true,
		"maxActionPoseDistance": CELL * 4.0,
		"poseHomeEntry": entry,
		"poseHomeRegion": "outside",
		"homeTransitionContext": { "kind": "enter", "entry": entry }
	})
	var attempts: Array[Dictionary] = []
	var started_at := _elapsed()
	for index in range(candidates.size()):
		var pose: Vector3 = candidates[index]
		if _position_inside_entry_home(entry, pose):
			continue
		var remaining := timeout_seconds - (_elapsed() - started_at)
		if remaining <= 0.0:
			break
		var route_timeout := minf(remaining, clampf(_flat_distance(player.global_position, pose) / (CELL * 2.4) + 2.0, 3.0, 7.0))
		var route := await go_to_position(pose, {
			"label": "%s_pose_%02d" % [label, index],
			"stopDistance": CELL * 0.6,
			"timeout": route_timeout,
			"planTimeout": minf(4.0, maxf(1.5, route_timeout * 0.55)),
			"skipHomeDoorPreparation": true,
			"homeTransitionContext": { "kind": "enter", "entry": entry },
			"candidateCells": [_world_cell(pose)],
			"routeSemanticKind": "interaction_target"
		})
		var attempt := {
			"index": index,
			"pose": _vec3(pose),
			"routeOk": bool(route.get("ok", false)),
			"routeStatus": String(route.get("status", "")),
			"routeReason": String(route.get("reason", ""))
		}
		if bool(route.get("ok", false)):
			var hit := await _aim_until_block_hit(door, "%s_pose_%02d" % [label, index])
			var hit_ok := bool(hit.get("matches", false)) and bool(hit.get("withinReach", false))
			attempt["hit"] = hit
			attempt["hitMatched"] = hit_ok
			attempts.append(attempt)
			_record(label, "door_pose_attempt", attempt)
			if hit_ok:
				return {
					"ok": true,
					"reason": "door_pose_reached",
					"pose": _vec3(pose),
					"hit": hit,
					"attempts": attempts
				}
		else:
			attempts.append(attempt)
			_record(label, "door_pose_attempt", attempt)
	return {
		"ok": false,
		"reason": "home_entry_door_pose_unreachable",
		"attempts": attempts
	}

func _home_entry_door(entry: Dictionary) -> Node3D:
	if entry.is_empty():
		return null
	var path := String(entry.get("doorPath", ""))
	if path != "" and main != null:
		var path_door := main.get_node_or_null(NodePath(path)) as Node3D
		if path_door != null and is_instance_valid(path_door):
			return path_door
	var door_position = entry.get("doorPosition", null)
	if door_position is Vector3:
		var nearby := _nearest_block("door", door_position)
		if nearby != null and is_instance_valid(nearby):
			return nearby
	return null

func _manifest_home_door_matches_entry(entry: Dictionary, door: Node3D) -> bool:
	if door == null or not is_instance_valid(door):
		return false
	if String(door.get_meta("block_type", "")) != "door":
		return false
	var expected_cell_value = entry.get("doorCell", null)
	if expected_cell_value is Vector2i and _flat_cell(door.global_position) != expected_cell_value:
		return false
	var expected_portal := String(entry.get("doorPortalId", ""))
	if expected_portal == "":
		return true
	var actual_portal := String(door.get_meta("door_portal_id", door.get_meta("portal_id", "")))
	return actual_portal == expected_portal

func _home_entry_summary(entry: Dictionary) -> Dictionary:
	return {
		"homeStableId": String(entry.get("homeStableId", "")),
		"homeCell": _vec2i(_vector2i_from_value(entry.get("homeCell", Vector2i.ZERO), Vector2i.ZERO)),
		"porchCell": _vec2i(_vector2i_from_value(entry.get("porchCell", Vector2i.ZERO), Vector2i.ZERO)),
		"doorCell": _vec2i(_vector2i_from_value(entry.get("doorCell", Vector2i.ZERO), Vector2i.ZERO)),
		"doorPortalId": String(entry.get("doorPortalId", ""))
	}

func _home_entry_containing_position(position: Vector3) -> Dictionary:
	if runner == null or not runner.has_method("player_navigation_home_entries"):
		return {}
	var values = runner.call("player_navigation_home_entries")
	if not (values is Array):
		return {}
	for entry_value in values:
		if entry_value is Dictionary and _position_inside_entry_home(entry_value, position):
			return (entry_value as Dictionary).duplicate(true)
	return {}

func _position_inside_entry_home(entry: Dictionary, position: Vector3) -> bool:
	if runner != null and runner.has_method("position_inside_entry_home"):
		return bool(runner.call("position_inside_entry_home", entry, position))
	return false

func _route_waypoints(route: Dictionary) -> Array[Vector3]:
	var result: Array[Vector3] = []
	var points: Array = route.get("waypoints", []) if route.get("waypoints", []) is Array else []
	for point in points:
		if point is Vector3:
			result.append(point)
	return result

func _route_completion_target(route: Dictionary, requested_target: Vector3, accept_route_goal: bool) -> Vector3:
	if not accept_route_goal:
		return requested_target
	var target_cell := _vector2i_from_value(route.get("targetCell", Vector2i(2147483000, 2147483000)), Vector2i(2147483000, 2147483000))
	if target_cell.x >= 2147483000:
		return requested_target
	return _cell_position(target_cell)

func _candidate_cells_for_positions(positions: Array) -> Array:
	var result: Array = []
	for position_value in positions:
		if not (position_value is Vector3):
			continue
		var cell := _world_cell(position_value)
		if not result.has(cell):
			result.append(cell)
	return result

func _result_route_goal_cell(result: Dictionary) -> Vector2i:
	var proof: Dictionary = result.get("proof", {}) if result.get("proof", {}) is Dictionary else {}
	var plan: Dictionary = proof.get("plan", proof) if proof.get("plan", proof) is Dictionary else {}
	var route: Dictionary = plan.get("route", {}) if plan.get("route", {}) is Dictionary else {}
	return _vector2i_from_value(route.get("targetCell", Vector2i(2147483000, 2147483000)), Vector2i(2147483000, 2147483000))

func _vec2i_array(cells: Array) -> Array:
	var result: Array = []
	for cell_value in cells:
		if cell_value is Vector2i:
			result.append(_vec2i(cell_value))
	return result

func _route_action_for_waypoint(actions: Dictionary, waypoint: Vector3, handled: Dictionary) -> Dictionary:
	var waypoint_cell := _flat_cell(waypoint)
	var keys := actions.keys()
	keys.sort()
	for key_value in keys:
		var key := String(key_value)
		if handled.has(key):
			continue
		var action_value = actions[key_value]
		if not (action_value is Dictionary):
			continue
		var action: Dictionary = action_value
		if String(action.get("kind", "")) != "door":
			continue
		var action_cell := _vector2i_from_value(action.get("cell", waypoint_cell), waypoint_cell)
		var exit_position := _vector3_from_value(action.get("exitPosition", waypoint), waypoint)
		if action_cell == waypoint_cell:
			return { "key": key, "action": action }
		if _flat_distance(waypoint, exit_position) <= CELL * 0.25:
			return { "key": key, "action": action }
	return {}

func _route_action_door(action: Dictionary) -> Node3D:
	var door_value = action.get("door", null)
	var door := door_value as Node3D
	if door != null and is_instance_valid(door):
		return door
	var cell := _vector2i_from_value(action.get("cell", Vector2i(999999, 999999)), Vector2i(999999, 999999))
	if cell.x == 999999:
		return null
	var door_position := _cell_position(cell)
	var nearest := _nearest_block("door", door_position)
	if nearest != null and is_instance_valid(nearest) and _flat_distance(nearest.global_position, door_position) <= CELL * 2.0:
		return nearest
	return null

func _nearest_block(block_type: String, origin: Vector3) -> Node3D:
	if runner != null and runner.has_method("nearest_block"):
		return runner.call("nearest_block", block_type, origin) as Node3D
	return null

func _aim_until_block_hit(block: Node3D, label: String) -> Dictionary:
	if runner != null and runner.has_method("aim_until_interaction_hit") and runner.has_method("interaction_hit_matches_block"):
		var hit: Dictionary = await runner.call("aim_until_interaction_hit", block, label)
		hit["matches"] = bool(runner.call("interaction_hit_matches_block", hit, block))
		return hit
	return { "hit": false, "matches": false, "reason": "missing_runner_block_aim" }

func _approach_until_block_in_reach(block: Node3D, label: String, timeout_seconds: float) -> Dictionary:
	var last_hit := {}
	if block == null or not is_instance_valid(block) or player == null or timeout_seconds <= 0.0:
		return { "hit": false, "matches": false, "withinReach": false, "reason": "missing_block_or_player" }
	var started_at := _elapsed()
	var best_distance := INF
	var stalled_frames := 0
	while _elapsed() - started_at < timeout_seconds:
		last_hit = await _aim_until_block_hit(block, label)
		var matches := bool(last_hit.get("matches", false))
		var within_reach := bool(last_hit.get("withinReach", false))
		if matches and within_reach:
			_stop_player()
			last_hit["reachApproach"] = "within_reach"
			return last_hit
		var target := block.global_position
		if last_hit.get("position") is Array:
			target = _vector3_from_value(last_hit.get("position"), block.global_position)
		elif last_hit.get("position") is Vector3:
			target = last_hit.get("position")
		var offset := Vector3(target.x - player.global_position.x, 0.0, target.z - player.global_position.z)
		var distance := offset.length()
		if distance <= CELL * 0.38:
			break
		if distance < best_distance - STUCK_PROGRESS_EPSILON:
			best_distance = distance
			stalled_frames = 0
		elif Vector2(player.velocity.x, player.velocity.z).length() <= STUCK_SPEED:
			stalled_frames += 1
		else:
			stalled_frames = maxi(0, stalled_frames - 1)
		if stalled_frames >= 30:
			break
		player.set("automated_move", offset.normalized())
		player.set("automated_sprint", false)
		_record(label, "block_reach_approach", {
			"target": _vec3(target),
			"player": _vec3(player.global_position),
			"distance": _rounded(distance),
			"hit": last_hit
		})
		await _physics_frame()
	_stop_player()
	last_hit["reachApproach"] = "not_within_reach"
	return last_hit

func _aim_until_npc_hit(body: Node3D, label: String) -> Dictionary:
	if runner != null and runner.has_method("aim_until_npc_interaction_hit") and runner.has_method("npc_interaction_hit_matches"):
		var hit: Dictionary = await runner.call("aim_until_npc_interaction_hit", body, label)
		hit["matches"] = bool(runner.call("npc_interaction_hit_matches", hit, body))
		return hit
	return { "hit": false, "matches": false, "reason": "missing_runner_npc_aim" }

func _aim_until_prop_hit(prop: Node3D, label: String) -> Dictionary:
	if runner != null and runner.has_method("aim_until_prop_hit") and runner.has_method("prop_interaction_hit_matches"):
		var hit: Dictionary = await runner.call("aim_until_prop_hit", prop, label)
		hit["matches"] = bool(runner.call("prop_interaction_hit_matches", hit, prop))
		return hit
	return { "hit": false, "matches": false, "reason": "missing_runner_prop_aim" }

func _aim_until_placement_preview(item_id: String, cell: Vector2i, label: String, strict_cell := false) -> Dictionary:
	if runner != null and runner.has_method("aim_until_placement_preview") and runner.has_method("placement_preview_matches_target"):
		var preview: Dictionary = await runner.call("aim_until_placement_preview", item_id, cell, label, strict_cell)
		preview["matches"] = bool(runner.call("placement_preview_matches_target", preview, item_id, cell, strict_cell))
		return preview
	return { "hit": false, "matches": false, "reason": "missing_runner_placement_preview" }

func _aim_until_placement_preview_for_cells(item_id: String, target_cell: Vector2i, aim_cells: Array[Vector2i], label: String, strict_cell := false) -> Dictionary:
	if runner == null or not runner.has_method("aim_until_placement_preview") or not runner.has_method("placement_preview_matches_target"):
		return { "hit": false, "matches": false, "reason": "missing_runner_placement_preview" }
	var last_preview := {}
	for index in range(aim_cells.size()):
		var aim_cell: Vector2i = aim_cells[index]
		var preview: Dictionary = await runner.call("aim_until_placement_preview", item_id, aim_cell, "%s_aim_%02d" % [label, index], strict_cell, target_cell)
		preview["aimCell"] = _vec2i(aim_cell)
		preview["matches"] = bool(runner.call("placement_preview_matches_target", preview, item_id, target_cell, strict_cell))
		last_preview = preview
		if bool(preview.get("matches", false)):
			return preview
	return last_preview if not last_preview.is_empty() else { "hit": false, "matches": false, "reason": "no_placement_aim_cells" }

func _placement_aim_cells(cell: Vector2i, item_id: String, options := {}) -> Array[Vector2i]:
	var tolerance := int(options.get("placementToleranceCells", 1 if item_id == "woodBlock" else 3))
	var result: Array[Vector2i] = []
	result.append(cell)
	for radius in range(1, tolerance + 1):
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if absi(dx) + absi(dz) != radius:
					continue
				result.append(cell + Vector2i(dx, dz))
	return result

func _dispatch_mouse_button(button_index: int, pressed: bool) -> void:
	if runner != null and runner.has_method("dispatch_mouse_button"):
		runner.call("dispatch_mouse_button", button_index, pressed)

func _stop_player() -> void:
	if player != null:
		player.set("automated_move", Vector3.ZERO)
		player.set("automated_sprint", false)

func _physics_frame() -> void:
	if runner != null and runner.get_tree() != null:
		await runner.get_tree().physics_frame

func _wait_physics_frames(count: int) -> void:
	for i in range(count):
		await _physics_frame()

func _elapsed() -> float:
	if runner != null:
		return float(runner.get("elapsed"))
	return float(Time.get_ticks_msec()) / 1000.0

func _world_cell(position: Vector3) -> Vector2i:
	var nav_world = _navigation_world()
	if nav_world != null and nav_world.has_method("world_cell"):
		var value = nav_world.call("world_cell", position)
		if value is Vector2i:
			return value
	return _flat_cell(position)

func _flat_cell(position: Vector3) -> Vector2i:
	if runner != null and runner.has_method("flat_cell"):
		return runner.call("flat_cell", position)
	if main != null and main.has_method("world_to_cell"):
		return Vector2i(int(main.call("world_to_cell", position.x)), int(main.call("world_to_cell", position.z)))
	return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

func _cell_position(cell: Vector2i) -> Vector3:
	var nav_world = _navigation_world()
	if nav_world != null and nav_world.has_method("cell_position"):
		var value = nav_world.call("cell_position", cell)
		if value is Vector3:
			return value
	if runner != null and runner.has_method("world_position_for_flat_cell"):
		return runner.call("world_position_for_flat_cell", cell)
	return _surface_position(Vector3(float(cell.x) * CELL, 0.0, float(cell.y) * CELL))

func _surface_position(position: Vector3) -> Vector3:
	var result := position
	if main != null and main.has_method("surface_y_at_position"):
		result.y = float(main.call("surface_y_at_position", position)) + 0.08
	return result

func _add_unique_position(result: Array[Vector3], seen: Dictionary, position: Vector3) -> void:
	var key := "%d,%d" % [roundi(position.x * 10.0), roundi(position.z * 10.0)]
	if seen.has(key):
		return
	seen[key] = true
	result.append(position)

func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

func _vector2i_from_value(value, fallback: Vector2i) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Vector3i:
		return Vector2i(value.x, value.z)
	if value is Vector2:
		return Vector2i(roundi(value.x), roundi(value.y))
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	if value is Dictionary:
		return Vector2i(int(value.get("x", fallback.x)), int(value.get("y", fallback.y)))
	return fallback

func _vector3_from_value(value, fallback: Vector3) -> Vector3:
	if value is Vector3:
		return value
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	if value is Dictionary:
		return Vector3(float(value.get("x", fallback.x)), float(value.get("y", fallback.y)), float(value.get("z", fallback.z)))
	return fallback

func _result(ok: bool, status: String, reason: String, label: String, target: Vector3, proof := {}) -> Dictionary:
	return {
		"ok": ok,
		"status": status,
		"reason": reason,
		"label": label,
		"player": _vec3(player.global_position) if player != null else [],
		"target": _vec3(target),
		"route": proof.get("routeSummary", proof.get("route", {})) if proof is Dictionary else {},
		"proof": proof
	}

func _route_prerequisite_failed(result: Dictionary) -> bool:
	var status := String(result.get("status", ""))
	return status == "perimeter_recovery_failed" or status == "current_home_exit_failed"

func _record(label: String, event_type: String, data: Dictionary) -> void:
	if runner != null and runner.has_method("record_player_route_event"):
		runner.call("record_player_route_event", label, event_type, data)
	if runner != null and runner.has_method("mark_progress") and event_type in ["plan_waiting", "plan_progress", "movement_progress", "block_pose_attempt", "block_action_dispatched", "block_action_completed", "placement_pose_attempt", "block_reach_approach"]:
		runner.call("mark_progress", "player_navigator_%s_%s" % [label, event_type])

func _push_scripted_route_target(target: Vector3, allow_outside: bool) -> Dictionary:
	if player == null:
		return {}
	var state := {
		"hadTarget": player.has_meta("npc_scripted_target"),
		"target": player.get_meta("npc_scripted_target") if player.has_meta("npc_scripted_target") else null,
		"hadAllowOutside": player.has_meta("npc_scripted_allow_outside"),
		"allowOutside": player.get_meta("npc_scripted_allow_outside") if player.has_meta("npc_scripted_allow_outside") else null
	}
	player.set_meta("npc_scripted_target", target)
	player.set_meta("npc_scripted_allow_outside", allow_outside)
	return state

func _pop_scripted_route_target(state: Dictionary) -> void:
	if player == null:
		return
	if bool(state.get("hadTarget", false)):
		player.set_meta("npc_scripted_target", state.get("target"))
	elif player.has_meta("npc_scripted_target"):
		player.remove_meta("npc_scripted_target")
	if bool(state.get("hadAllowOutside", false)):
		player.set_meta("npc_scripted_allow_outside", state.get("allowOutside"))
	elif player.has_meta("npc_scripted_allow_outside"):
		player.remove_meta("npc_scripted_allow_outside")

func _route_summary(route: Dictionary) -> Dictionary:
	if route.is_empty():
		return {}
	var waypoints: Array = route.get("waypoints", []) if route.get("waypoints", []) is Array else []
	var actions: Dictionary = route.get("actions", {}) if route.get("actions", {}) is Dictionary else {}
	return {
		"ok": bool(route.get("ok", false)),
		"status": String(route.get("status", "")),
		"reason": String(route.get("reason", "")),
		"source": String(route.get("source", "")),
		"routeAuthorityReady": bool(route.get("routeAuthorityReady", false)),
		"routeAuthorityState": String(route.get("routeAuthorityState", "")),
		"routeAuthorityReason": String(route.get("routeAuthorityReason", "")),
		"routeAuthorityPending": bool(route.get("routeAuthorityPending", false)),
		"routeAuthorityTerminalFailure": bool(route.get("routeAuthorityTerminalFailure", false)),
		"waypointCount": waypoints.size(),
		"waypoints": _vec3_array_limited(waypoints, 18),
		"actions": _route_actions_summary(actions),
		"collisionProbe": _collision_probe_summary(route.get("collisionProbe", {})),
		"validation": _route_validation_summary(route)
	}

func _route_validation_summary(route: Dictionary) -> Dictionary:
	var validation: Dictionary = route.get("validation", {}) if route.get("validation", {}) is Dictionary else {}
	var navmesh_route: Dictionary = route.get("navmeshRoute", {}) if route.get("navmeshRoute", {}) is Dictionary else {}
	if validation.is_empty() and navmesh_route.get("validation", {}) is Dictionary:
		validation = navmesh_route.get("validation", {})
	if validation.is_empty():
		return {}
	return {
		"reason": String(validation.get("reason", "")),
		"transitionReason": String(validation.get("transitionReason", "")),
		"blockType": String(validation.get("blockType", "")),
		"fromCell": _vec2i(_vector2i_from_value(validation.get("fromCell", Vector2i.ZERO), Vector2i.ZERO)),
		"toCell": _vec2i(_vector2i_from_value(validation.get("toCell", Vector2i.ZERO), Vector2i.ZERO)),
		"blockerCell": _vec2i(_vector2i_from_value(validation.get("blockerCell", Vector2i.ZERO), Vector2i.ZERO)),
		"segmentIndex": int(validation.get("segmentIndex", -1)),
		"navmeshStart": _vec3(_vector3_from_value(navmesh_route.get("startPosition", Vector3.ZERO), Vector3.ZERO)),
		"navmeshTarget": _vec3(_vector3_from_value(navmesh_route.get("targetPosition", Vector3.ZERO), Vector3.ZERO)),
		"navmeshPointCount": int(navmesh_route.get("pointCount", 0))
	}

func _route_actions_summary(actions: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var keys := actions.keys()
	keys.sort()
	for key_value in keys:
		var action_value = actions[key_value]
		if action_value is Dictionary:
			var summary := _route_action_summary(action_value)
			summary["key"] = String(key_value)
			result.append(summary)
	return result

func _route_action_summary(action: Dictionary) -> Dictionary:
	var summary := {
		"kind": String(action.get("kind", "")),
		"portalId": String(action.get("portalId", "")),
		"actionId": String(action.get("actionId", "")),
		"direction": String(action.get("direction", "")),
		"navLink": bool(action.get("navLink", false)),
		"requiresSmartObject": bool(action.get("requiresSmartObject", false)),
		"enabled": bool(action.get("enabled", false)),
		"cell": _vec2i(_vector2i_from_value(action.get("cell", Vector2i.ZERO), Vector2i.ZERO)),
		"entryCell": _vec2i(_vector2i_from_value(action.get("entryCell", Vector2i.ZERO), Vector2i.ZERO)),
		"entryPosition": _vec3(_vector3_from_value(action.get("entryPosition", Vector3.ZERO), Vector3.ZERO)),
		"exitPosition": _vec3(_vector3_from_value(action.get("exitPosition", Vector3.ZERO), Vector3.ZERO))
	}
	var door := _route_action_door(action)
	if door != null and is_instance_valid(door):
		summary["door"] = _node_summary(door)
	return summary

func _collision_probe_summary(value) -> Dictionary:
	if not (value is Dictionary):
		return {}
	var probe: Dictionary = value
	return {
		"ok": bool(probe.get("ok", false)),
		"status": String(probe.get("status", "")),
		"reason": String(probe.get("reason", "")),
		"authoritative": bool(probe.get("authoritative", false)),
		"sampleCount": int(probe.get("sampleCount", 0))
	}

func _node_summary(node: Node3D) -> Dictionary:
	if node == null:
		return {}
	return {
		"name": node.name,
		"path": String(node.get_path()),
		"type": String(node.get_meta("block_type", "")) if node.has_meta("block_type") else "",
		"position": _vec3(node.global_position)
	}

func _vec3(value) -> Array:
	if value is Vector3:
		return [_rounded(value.x), _rounded(value.y), _rounded(value.z)]
	return [0.0, 0.0, 0.0]

func _vec2i(value) -> Array:
	if value is Vector2i:
		return [value.x, value.y]
	return [0, 0]

func _vec3_array_limited(values, limit := 8) -> Array:
	var result := []
	if not (values is Array):
		return result
	for value in values:
		if result.size() >= limit:
			break
		result.append(_vec3(value))
	return result

func _rounded(value: float) -> float:
	return roundf(value * 1000.0) / 1000.0
