extends RefCounted

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcCorridorFollowerScript := preload("res://scripts/npc_ai/movement/NpcCorridorFollower.gd")
const ReciprocalAvoidanceAdapterScript := preload("res://scripts/npc_ai/movement/ReciprocalAvoidanceAdapter.gd")
const NpcCrowdVelocityServiceScript := preload("res://scripts/npc_ai/movement/NpcCrowdVelocityService.gd")
const NpcRouteLeaseExecutorScript := preload("res://scripts/npc_ai/movement/NpcRouteLeaseExecutor.gd")
const CharacterMotorProfileScript := preload("res://scripts/npc_ai/contracts/CharacterMotorProfile.gd")
const NpcBipedVisualFactoryScript := preload("res://scripts/characters/NpcBipedVisualFactory.gd")

const CELL := 1.35
const DT := 1.0 / 60.0

var runner = null
var ticket_deliveries: Array = []
var ticket_velocity_by_actor_id := {}

class SyntheticWorld:
	func world_cell(position: Vector3) -> Vector2i:
		return Vector2i(roundi(position.x / 1.35), roundi(position.z / 1.35))

	func cell_key(cell: Vector2i) -> String:
		return "%d,%d" % [cell.x, cell.y]

class SyntheticValidator:
	var fail_reason := ""
	var max_lateral := 999.0
	var door_blocked := false

	func validate_candidate(_entry: Dictionary, previous: Vector3, candidate: Vector3, _moving_home := false, _allow_outside := false, _world = null, _priority := 0) -> Dictionary:
		if fail_reason != "":
			return { "ok": false, "reason": fail_reason }
		if door_blocked:
			return { "ok": false, "reason": "door_closed" }
		if absf(candidate.z) > max_lateral:
			return { "ok": false, "reason": "blocked_static" }
		if candidate.distance_to(previous) > CELL * 0.90:
			return { "ok": false, "reason": "stale_corridor" }
		return { "ok": true, "candidate": candidate }

class DoorStageWaitSystem:
	extends RefCounted

	func request_npc_door_traversal(_door: Node3D, _body: CharacterBody3D, _entry: Dictionary, _action: Dictionary) -> Dictionary:
		return {"ok": false, "reason": "door_stage_required", "stagePosition": Vector3.ZERO}

class InactiveCrowdVelocityService:
	extends RefCounted

	func resolve_safe_velocity(_entry: Dictionary, _body: CharacterBody3D, desired_velocity: Vector3, _context := {}) -> Dictionary:
		return {
			"active": false,
			"safeVelocity": desired_velocity,
			"status": "inactive",
			"reason": "no_crowd",
			"callbackFresh": false,
			"fallbackUsed": false,
			"movementBlocked": false,
			"activeRegistrationCount": 0
		}

func setup(owner) -> void:
	runner = owner

func cases() -> Array[Dictionary]:
	var ids = [
		["npc_avoidance_head_on_open_road", "test_head_on_open_road"],
		["npc_avoidance_prediction_range_covers_closing_speed", "test_prediction_range_covers_closing_speed"],
		["npc_avoidance_head_on_uses_navigation_authority", "test_head_on_uses_navigation_authority"],
		["npc_avoidance_crossing_paths", "test_crossing_paths"],
		["npc_avoidance_overtake_slow_actor", "test_overtake_slow_actor"],
		["npc_avoidance_crowded_plaza_progress", "test_crowded_plaza_progress"],
		["npc_avoidance_corridor_boundary_respected", "test_corridor_boundary_respected"],
		["npc_avoidance_no_left_right_oscillation", "test_no_left_right_oscillation"],
		["npc_avoidance_wall_not_treated_as_rvo_only", "test_wall_not_treated_as_rvo_only"],
		["npc_avoidance_closed_door_not_bypassed", "test_closed_door_not_bypassed"],
		["npc_avoidance_portal_mode_no_frame_sidestep", "test_portal_mode_no_frame_sidestep"],
		["npc_avoidance_inactive_agents_disabled", "test_inactive_agents_disabled"],
		["npc_avoidance_stationary_physical_actor_remains_obstacle", "test_stationary_physical_actor_remains_obstacle"],
		["npc_avoidance_stationary_force_is_edge_triggered", "test_stationary_force_is_edge_triggered"],
		["npc_avoidance_batch_certificate_includes_stationary_actor", "test_batch_certificate_includes_stationary_actor"],
		["npc_avoidance_velocity_filter_precedes_batch_certificate", "test_velocity_filter_precedes_batch_certificate"],
		["npc_avoidance_certified_reverse_reaches_executor_motor", "test_certified_reverse_reaches_executor_motor"],
		["npc_visual_intentional_zero_velocity_uses_idle_pose", "test_visual_intentional_zero_velocity_uses_idle_pose"],
		["npc_visual_terminal_arrival_publishes_idle_pose", "test_visual_terminal_arrival_publishes_idle_pose"],
		["npc_visual_door_stage_wait_publishes_idle_pose", "test_visual_door_stage_wait_publishes_idle_pose"],
		["npc_avoidance_missing_callback_isolates_local_component", "test_missing_callback_isolates_local_component"],
		["npc_avoidance_unresolved_stationary_is_edge_triggered", "test_unresolved_stationary_is_edge_triggered"],
		["npc_avoidance_dynamic_contact_reaches_shared_motor", "test_dynamic_contact_reaches_shared_motor"],
		["npc_avoidance_order_replacement_invalidates_executor_ticket", "test_order_replacement_invalidates_executor_ticket"],
		["npc_avoidance_missing_shared_authority_blocks", "test_missing_shared_authority_blocks"],
		["npc_avoidance_stale_callback_safe_stop", "test_stale_callback_safe_stop"],
		["npc_avoidance_callback_command_generation_bound", "test_callback_command_generation_bound"],
		["npc_avoidance_callback_disable_reenable_single_delivery", "test_callback_disable_reenable_single_delivery"],
		["npc_avoidance_agent_receives_live_target", "test_agent_receives_live_target"],
		["npc_avoidance_zero_fresh_callback_holds_safely", "test_zero_fresh_callback_holds_safely"],
		["npc_follow_arrival_no_orbit", "test_follow_arrival_no_orbit"],
		["npc_follow_progress_watchdog_classifies_blocker", "test_progress_watchdog_classifies_blocker"],
		["npc_follow_day_crowd_progress", "test_day_crowd_progress"],
		["npc_follow_night_guard_passes_returning_civilian", "test_night_guard_passes_returning_civilian"]
	]
	var result: Array[Dictionary] = []
	for spec in ids:
		result.append({
			"id": String(spec[0]),
			"suite": "avoidance",
			"timeModes": ["day", "night"],
			"callable": Callable(self, String(spec[1]))
		})
	return result

func test_prediction_range_covers_closing_speed(_mode: String) -> Dictionary:
	var navigation_radius := NpcConstantsScript.DEFAULT_NPC_RADIUS + NpcConstantsScript.AVOIDANCE_RADIUS_SAFETY_MARGIN
	var maximum_closing_distance := NpcConstantsScript.DEFAULT_NPC_WALK_SPEED * 2.0 * NpcConstantsScript.AVOIDANCE_TIME_HORIZON_AGENTS
	var required_neighbor_distance := maximum_closing_distance + navigation_radius * 2.0
	var passed := NpcConstantsScript.AVOIDANCE_NEIGHBOR_DISTANCE >= required_neighbor_distance \
		and NpcConstantsScript.AVOIDANCE_ACTIVE_DISTANCE >= NpcConstantsScript.AVOIDANCE_NEIGHBOR_DISTANCE
	return outcome(
		passed,
		"neighbor=%.2f active=%.2f required=%.2f" % [NpcConstantsScript.AVOIDANCE_NEIGHBOR_DISTANCE, NpcConstantsScript.AVOIDANCE_ACTIVE_DISTANCE, required_neighbor_distance],
		["neighbor_range_covers_pair_closing_distance", "crowd_candidate_range_covers_orca_neighbor_range"],
		{"neighborDistance": NpcConstantsScript.AVOIDANCE_NEIGHBOR_DISTANCE, "activeDistance": NpcConstantsScript.AVOIDANCE_ACTIVE_DISTANCE, "requiredNeighborDistance": required_neighbor_distance}
	)

func test_head_on_uses_navigation_authority(_mode: String) -> Dictionary:
	var adapter := ReciprocalAvoidanceAdapterScript.new()
	var body := make_actor("npc-a", Vector3.ZERO)
	var other := make_actor("npc-b", Vector3(0.0, 0.0, -2.0))
	var desired := Vector3.FORWARD * 1.5
	var other_desired := Vector3.BACK * 1.5
	var requested_snapshot := {
		body.get_instance_id(): desired,
		other.get_instance_id(): other_desired
	}
	var result: Dictionary = adapter.compute_safe_velocity({ "id": "npc-a" }, body, desired, {
		"actors": [body, other],
		"actorRequestedVelocitySnapshot": requested_snapshot,
		"forceAvoidance": true,
		"maxSpeed": 1.5,
		"avoidanceTarget": Vector3(0.0, 0.0, -4.0)
	})
	var preferred: Vector3 = result.get("preferredVelocity", desired)
	var agent := body.get_node_or_null("NpcAvoidanceAgent") as NavigationAgent3D
	var passed := not bool(result.get("laneBiasApplied", true)) and preferred.is_equal_approx(desired) and agent != null and agent.velocity.is_equal_approx(desired)
	return outcome(passed, "preferred=%s agent=%s" % [str(preferred), str(agent.velocity if agent != null else Vector3.ZERO)], ["head_on_preference_reaches_navigation_agent_unchanged", "custom_lane_bias_absent_from_production"], { "result": result, "agentVelocity": agent.velocity if agent != null else Vector3.ZERO })

func test_head_on_open_road(_mode: String) -> Dictionary:
	var sim := simulate_pair(Vector3(-2.0, 0.0, 0.0), Vector3(2.0, 0.0, 0.0), Vector3.RIGHT * 2.1, Vector3.LEFT * 2.1, 54)
	var passed := float(sim.get("aProgress", 0.0)) > 1.6 and float(sim.get("bProgress", 0.0)) > 1.6 and float(sim.get("minSeparation", 0.0)) > 0.68 and int(sim.get("activeFrames", 0)) > 0
	return outcome(passed, "progress %.2f/%.2f minSep %.2f active %d" % [float(sim.get("aProgress", 0.0)), float(sim.get("bProgress", 0.0)), float(sim.get("minSeparation", 0.0)), int(sim.get("activeFrames", 0))], ["head_on_progress", "minimum_separation", "avoidance_active"], sim)

func test_crossing_paths(_mode: String) -> Dictionary:
	var sim := simulate_pair(Vector3(-1.8, 0.0, 0.0), Vector3(0.0, 0.0, -1.8), Vector3.RIGHT * 1.9, Vector3.FORWARD * -1.9, 38)
	var passed := float(sim.get("aProgress", 0.0)) > 1.1 and float(sim.get("bProgress", 0.0)) > 1.1 and float(sim.get("minSeparation", 0.0)) > 0.68 and int(sim.get("activeFrames", 0)) > 0
	return outcome(passed, "cross progress %.2f/%.2f minSep %.2f" % [float(sim.get("aProgress", 0.0)), float(sim.get("bProgress", 0.0)), float(sim.get("minSeparation", 0.0))], ["crossing_progress", "crossing_separation"], sim)

func test_overtake_slow_actor(_mode: String) -> Dictionary:
	var sim := simulate_pair(Vector3(-2.2, 0.0, 0.0), Vector3(-0.7, 0.0, 0.0), Vector3.RIGHT * 2.4, Vector3.RIGHT * 0.65, 60)
	var passed := float(sim.get("aProgress", 0.0)) > float(sim.get("bProgress", 0.0)) and float(sim.get("minSeparation", 0.0)) > 0.68 and int(sim.get("activeFrames", 0)) > 0
	return outcome(passed, "overtake progress %.2f/%.2f minSep %.2f" % [float(sim.get("aProgress", 0.0)), float(sim.get("bProgress", 0.0)), float(sim.get("minSeparation", 0.0))], ["overtake_progress", "overtake_separation"], sim)

func test_crowded_plaza_progress(_mode: String) -> Dictionary:
	var adapter := ReciprocalAvoidanceAdapterScript.new()
	var actors := [
		make_actor("npc-a", Vector3(-2.0, 0.0, 0.0)),
		make_actor("npc-b", Vector3(2.0, 0.0, 0.0)),
		make_actor("npc-c", Vector3(0.0, 0.0, -2.0)),
		make_actor("npc-d", Vector3(0.0, 0.0, 2.0))
	]
	var desired := [Vector3.RIGHT * 1.8, Vector3.LEFT * 1.8, Vector3.BACK * 1.8, Vector3.FORWARD * 1.8]
	var initial := []
	for actor in actors:
		initial.append(actor.global_position)
	var min_sep := INF
	var active := 0
	for _i in range(52):
		adapter.begin_frame()
		for callback_index in range(actors.size()):
			var callback_actor := actors[callback_index] as CharacterBody3D
			adapter.record_safe_velocity(String(callback_actor.name), synthetic_orca_callback_velocity(callback_actor, desired[callback_index], actors, desired))
		for j in range(actors.size()):
			var actor := actors[j] as CharacterBody3D
			var result: Dictionary = adapter.compute_safe_velocity({ "id": actor.name }, actor, desired[j], { "actors": actors, "forceAvoidance": true, "maxSpeed": 1.8, "avoidanceTarget": actor.global_position + desired[j] })
			if bool(result.get("active", false)):
				active += 1
			var safe_velocity: Vector3 = result.get("safeVelocity", desired[j])
			set_actor_position(actor, actor.global_position + safe_velocity.limit_length(1.8) * DT)
		min_sep = minf(min_sep, min_pair_separation(actors))
	var progress := 0.0
	for j in range(actors.size()):
		var actor := actors[j] as Node3D
		progress += actor.global_position.distance_to(initial[j])
	var passed := progress > 3.0 and min_sep > 0.68 and active > 0
	return outcome(passed, "crowd progress %.2f minSep %.2f active %d" % [progress, min_sep, active], ["crowd_progress", "crowd_separation", "avoidance_active"], { "progress": progress, "minSeparation": min_sep, "activeFrames": active })

func test_corridor_boundary_respected(_mode: String) -> Dictionary:
	var body := make_actor("npc-a", Vector3.ZERO)
	var other := make_actor("npc-b", Vector3(CELL, 0.0, 0.0))
	var follower = NpcCorridorFollowerScript.new()
	var adapter = ReciprocalAvoidanceAdapterScript.new()
	var validator = SyntheticValidator.new()
	validator.max_lateral = NpcConstantsScript.CORRIDOR_LATERAL_TOLERANCE + 0.01
	var follow: Dictionary = follower.compute_step({ "id": "npc-a" }, body, body.global_position, Vector3(4.0, 0.0, 0.0), [Vector3(4.0, 0.0, 0.0)], intent(), CELL * 0.34, SyntheticWorld.new(), validator, adapter, [body, other])
	var candidate: Vector3 = follow.get("candidate", Vector3.ZERO)
	var lateral := absf(candidate.z)
	var passed := bool(follow.get("ok", false)) and lateral <= NpcConstantsScript.CORRIDOR_LATERAL_TOLERANCE + 0.01
	return outcome(passed, "lateral %.3f follow=%s" % [lateral, JSON.stringify(compact_follow(follow))], ["corridor_lateral_clamp", "candidate_validated"], { "lateral": lateral, "follow": compact_follow(follow) })

func test_no_left_right_oscillation(_mode: String) -> Dictionary:
	var body := make_actor("npc-a", Vector3.ZERO)
	var other := make_actor("npc-b", Vector3(CELL, 0.0, 0.0))
	var follower = NpcCorridorFollowerScript.new()
	var adapter = ReciprocalAvoidanceAdapterScript.new()
	var validator = SyntheticValidator.new()
	var entry := { "id": "npc-a" }
	for _i in range(16):
		adapter.begin_frame()
		var follow: Dictionary = follower.compute_step(entry, body, body.global_position, Vector3(5.0, 0.0, 0.0), [Vector3(5.0, 0.0, 0.0)], intent(), CELL * 0.24, SyntheticWorld.new(), validator, adapter, [body, other])
		if bool(follow.get("ok", false)):
			set_actor_position(body, follow.get("candidate"))
	var sign_changes := int(entry.get("corridorOscillationSignChanges", 0))
	var passed := sign_changes <= 1
	return outcome(passed, "signChanges %d stats=%s" % [sign_changes, JSON.stringify(follower.stats())], ["oscillation_sign_changes_bounded"], { "signChanges": sign_changes, "stats": follower.stats() })

func test_wall_not_treated_as_rvo_only(_mode: String) -> Dictionary:
	var body := make_actor("npc-a", Vector3.ZERO)
	var follower = NpcCorridorFollowerScript.new()
	var adapter = ReciprocalAvoidanceAdapterScript.new()
	var validator = SyntheticValidator.new()
	validator.fail_reason = "blocked_static"
	var follow: Dictionary = follower.compute_step({ "id": "npc-a" }, body, body.global_position, Vector3(4.0, 0.0, 0.0), [Vector3(4.0, 0.0, 0.0)], intent(), CELL * 0.36, SyntheticWorld.new(), validator, adapter, [body])
	var passed := not bool(follow.get("ok", true)) and String(follow.get("classification", "")) == "static_collision"
	return outcome(passed, "follow=%s" % JSON.stringify(compact_follow(follow)), ["static_collision_classified", "rvo_not_authoritative_for_wall"], { "follow": compact_follow(follow) })

func test_closed_door_not_bypassed(_mode: String) -> Dictionary:
	var body := make_actor("npc-a", Vector3.ZERO)
	var follower = NpcCorridorFollowerScript.new()
	var adapter = ReciprocalAvoidanceAdapterScript.new()
	var validator = SyntheticValidator.new()
	validator.door_blocked = true
	var entry := { "id": "npc-a", "activeDoorPortalId": "door:test" }
	var follow: Dictionary = follower.compute_step(entry, body, body.global_position, Vector3(0.0, 0.0, 4.0), [Vector3(0.0, 0.0, 4.0)], intent(), CELL * 0.36, SyntheticWorld.new(), validator, adapter, [body])
	var passed := not bool(follow.get("ok", true)) and String(follow.get("classification", "")) == "door_state"
	return outcome(passed, "follow=%s" % JSON.stringify(compact_follow(follow)), ["closed_door_classified", "portal_not_bypassed"], { "follow": compact_follow(follow) })

func test_portal_mode_no_frame_sidestep(_mode: String) -> Dictionary:
	var adapter := ReciprocalAvoidanceAdapterScript.new()
	var body := make_actor("npc-a", Vector3.ZERO)
	var other := make_actor("npc-b", Vector3(0.0, 0.0, CELL))
	var result: Dictionary = adapter.compute_safe_velocity({ "id": "npc-a" }, body, Vector3.FORWARD * -2.0, {
		"actors": [body, other],
		"portalMode": true,
		"corridorDirection": Vector3.FORWARD * -1.0,
		"maxSpeed": 2.0
	})
	var safe: Vector3 = result.get("safeVelocity", Vector3.ZERO)
	var lateral := absf(safe.x)
	var passed := lateral <= 0.001 and String(result.get("status", "")) == "portal"
	return outcome(passed, "safe=%s lateral %.3f" % [str(safe), lateral], ["portal_lateral_reduced", "reservation_authority"], { "result": result, "lateral": lateral })

func test_inactive_agents_disabled(_mode: String) -> Dictionary:
	var adapter := ReciprocalAvoidanceAdapterScript.new()
	var body := make_actor("npc-a", Vector3.ZERO)
	var far := make_actor("npc-b", Vector3(99.0, 0.0, 99.0))
	var result: Dictionary = adapter.compute_safe_velocity({ "id": "npc-a" }, body, Vector3.RIGHT, { "actors": [body, far], "maxSpeed": 1.0 })
	var stats: Dictionary = adapter.stats()
	var passed := not bool(result.get("active", true)) and int(stats.get("activeRegistrations", -1)) == 0
	return outcome(passed, "result=%s stats=%s" % [JSON.stringify(result), JSON.stringify(stats)], ["inactive_far_agents_disabled", "active_count_zero"], { "result": result, "stats": stats })

func test_stationary_physical_actor_remains_obstacle(_mode: String) -> Dictionary:
	var service = NpcCrowdVelocityServiceScript.new()
	service.setup(null, null)
	var moving := make_actor("npc-moving", Vector3.ZERO)
	var stationary := make_actor("npc-stationary", Vector3(1.0, 0.0, 0.0))
	moving.set_meta("npc_applied_velocity", Vector3.RIGHT * 1.5)
	moving.set_meta("npc_requested_velocity", Vector3.RIGHT * 1.5)
	stationary.set_meta("npc_applied_velocity", Vector3.LEFT * 9.0)
	stationary.set_meta("npc_requested_velocity", Vector3.LEFT * 9.0)
	service.begin_physics_frame([
		{ "id": "npc-moving", "body": moving, "routeStatus": "moving", "routeLease": { "leaseId": "moving:1" } },
		{ "id": "npc-stationary", "body": stationary, "routeStatus": "arrived" }
	])
	var stationary_agent := stationary.get_node_or_null("NpcAvoidanceAgent") as NavigationAgent3D
	var moving_snapshot: Vector3 = service.velocity_snapshot_by_instance_id.get(moving.get_instance_id(), Vector3.ZERO)
	var stationary_snapshot: Vector3 = service.velocity_snapshot_by_instance_id.get(stationary.get_instance_id(), Vector3.ONE)
	var passed: bool = stationary_agent != null \
		and stationary_agent.avoidance_enabled \
		and stationary_agent.velocity.length_squared() <= 0.000001 \
		and stationary_snapshot.length_squared() <= 0.000001 \
		and moving_snapshot.is_equal_approx(Vector3.RIGHT * 1.5)
	return outcome(
		passed,
		"stationaryAgent=%s stationarySnapshot=%s movingSnapshot=%s" % [str(stationary_agent != null), str(stationary_snapshot), str(moving_snapshot)],
		["stationary_actor_registered_for_avoidance", "stale_stationary_velocity_zeroed", "moving_velocity_preserved"],
		{ "stationarySnapshot": stationary_snapshot, "movingSnapshot": moving_snapshot, "agentVelocity": stationary_agent.velocity if stationary_agent != null else Vector3.INF }
	)


func test_stationary_force_is_edge_triggered(_mode: String) -> Dictionary:
	var adapter := ReciprocalAvoidanceAdapterScript.new()
	var body := make_actor("npc-stationary-edge", Vector3.ZERO)
	var entry := {"id": "npc-stationary-edge"}
	adapter.sync_physical_actor(entry, body, Vector3.ZERO, false)
	var first := int(adapter.stats().get("realizedVelocityCorrections", 0))
	for _frame in range(12):
		adapter.sync_physical_actor(entry, body, Vector3.ZERO, false)
	var final := int(adapter.stats().get("realizedVelocityCorrections", 0))
	var agent := body.get_node_or_null("NpcAvoidanceAgent") as NavigationAgent3D
	var passed := first == 1 and final == 1 and agent != null and agent.avoidance_enabled
	return outcome(passed, "corrections=%d/%d enabled=%s" % [first, final, str(agent != null and agent.avoidance_enabled)], ["stationary_force_occurs_once", "stationary_actor_remains_registered"], {"first": first, "final": final})


func test_batch_certificate_includes_stationary_actor(_mode: String) -> Dictionary:
	var service := NpcCrowdVelocityServiceScript.new()
	var moving := make_actor("npc-certified-moving", Vector3.ZERO)
	var stationary := make_actor("npc-certified-stationary", Vector3(1.01, 0.0, 0.0))
	var moving_entry := {"id": "npc-certified-moving", "body": moving}
	var stationary_entry := {"id": "npc-certified-stationary", "body": stationary}
	service.active_entries = [moving_entry, stationary_entry]
	service.velocity_snapshot_by_instance_id[stationary.get_instance_id()] = Vector3.ZERO
	service.pending_tickets_by_actor_id = {
		"npc-certified-moving": {
			"body": moving,
			"radius": 0.5,
			"priority": 0.5,
			"physicsDelta": DT,
			"desiredVelocity": Vector3.FORWARD
		}
	}
	service.safe_velocity_by_actor_id = {"npc-certified-moving": Vector3.RIGHT}
	var certified: Dictionary = service.call("_certify_component_velocities", ["npc-certified-moving"])
	var velocity: Vector3 = certified.get("npc-certified-moving", Vector3.ZERO)
	var predicted := moving.global_position + velocity * DT
	var predicted_separation := Vector2(predicted.x - stationary.global_position.x, predicted.z - stationary.global_position.z).length()
	var ticket_stats: Dictionary = service.stats().get("tickets", {})
	var passed := predicted_separation + 0.0001 >= 1.0 and velocity.dot(Vector3.FORWARD) > 0.9 and int(ticket_stats.get("safetyProjectionCorrections", 0)) > 0
	return outcome(passed, "velocity=%s predicted=%.4f stats=%s" % [str(velocity), predicted_separation, JSON.stringify(ticket_stats)], ["stationary_actor_participates_in_batch_certificate", "unsafe_orca_proposal_replaced_by_feasible_goal_velocity", "predicted_separation_preserved"], {"velocity": velocity, "predictedSeparation": predicted_separation, "tickets": ticket_stats})


func test_velocity_filter_precedes_batch_certificate(_mode: String) -> Dictionary:
	var service := NpcCrowdVelocityServiceScript.new()
	var moving := make_actor("npc-filtered-moving", Vector3.ZERO)
	var stationary := make_actor("npc-filtered-stationary", Vector3(1.01, 0.0, 0.0))
	service.physics_frame = 52
	service.submissions_closed = true
	service.active_entries = [
		{"id": "npc-filtered-moving", "body": moving},
		{"id": "npc-filtered-stationary", "body": stationary}
	]
	service.velocity_snapshot_by_instance_id[stationary.get_instance_id()] = Vector3.ZERO
	ticket_velocity_by_actor_id.clear()
	service.pending_tickets_by_actor_id = {
		"npc-filtered-moving": {
			"requestKey": "filtered:52",
			"consumer": Callable(self, "record_ticket_velocity").bind("npc-filtered-moving"),
			"velocityFilter": Callable(self, "force_unsafe_ticket_velocity"),
			"body": moving,
			"radius": 0.5,
			"priority": 0.5,
			"physicsDelta": DT,
			"desiredVelocity": Vector3.FORWARD,
			"maxSpeed": 1.0,
			"neighborActorIds": ["npc-filtered-stationary"]
		}
	}
	service.call("_receive_safe_velocity", Vector3.FORWARD, "filtered:52", "npc-filtered-moving", 52)
	var velocity: Vector3 = ticket_velocity_by_actor_id.get("npc-filtered-moving", Vector3.ZERO)
	var predicted := moving.global_position + velocity * DT
	var predicted_separation := Vector2(predicted.x - stationary.global_position.x, predicted.z - stationary.global_position.z).length()
	var ticket_stats: Dictionary = service.stats().get("tickets", {})
	var passed := velocity.dot(Vector3.FORWARD) > 0.9 \
		and absf(velocity.x) < 0.01 \
		and predicted_separation + 0.0001 >= 1.0 \
		and int(ticket_stats.get("safetyProjectionCorrections", 0)) > 0
	return outcome(passed, "velocity=%s predicted=%.4f stats=%s" % [str(velocity), predicted_separation, JSON.stringify(ticket_stats)], ["velocity_filter_runs_before_certificate", "filtered_unsafe_velocity_is_not_committed", "certified_velocity_preserves_separation"], {"velocity": velocity, "predictedSeparation": predicted_separation, "tickets": ticket_stats})


func test_certified_reverse_reaches_executor_motor(_mode: String) -> Dictionary:
	var service := NpcCrowdVelocityServiceScript.new()
	var moving := make_actor("npc-certified-reverse", Vector3.ZERO)
	var stationary := make_actor("npc-certified-reverse-blocker", Vector3(0.99, 0.0, 0.0))
	var entry := {
		"id": "npc-certified-reverse",
		"body": moving,
		"_v2AvoidancePendingReverseResult": {
			"velocity": Vector3.RIGHT,
			"exhausted": true,
			"telemetry": {"exhausted": true}
		}
	}
	service.active_entries = [entry, {"id": "npc-certified-reverse-blocker", "body": stationary}]
	service.velocity_snapshot_by_instance_id[stationary.get_instance_id()] = Vector3.ZERO
	service.pending_tickets_by_actor_id = {
		"npc-certified-reverse": {
			"body": moving,
			"radius": 0.5,
			"priority": 0.5,
			"physicsDelta": DT,
			"desiredVelocity": Vector3.RIGHT,
			"maxSpeed": 1.0,
			"neighborActorIds": ["npc-certified-reverse-blocker"]
		}
	}
	service.safe_velocity_by_actor_id = {"npc-certified-reverse": Vector3.RIGHT}
	var certified: Dictionary = service.call("_certify_component_velocities", ["npc-certified-reverse"])
	var certified_velocity: Vector3 = certified.get("npc-certified-reverse", Vector3.ZERO)
	var initial_separation := Vector2(moving.global_position.x - stationary.global_position.x, moving.global_position.z - stationary.global_position.z).length()
	var executor := NpcRouteLeaseExecutorScript.new()
	executor.setup(null)
	var lease := {
		"state": "ready",
		"waypoints": [Vector3(8.0, 0.0, 0.0), Vector3(12.0, 0.0, 0.0)],
		"actions": {},
		"probeCertificate": {"ok": true, "authoritative": true}
	}
	var result: Dictionary = executor.call("_apply_velocity_and_advance", entry, "certified-reverse-request", lease, 0, moving, Vector3(8.0, 0.0, 0.0), 0.36, CharacterMotorProfileScript.npc_default(), 1.0, Vector3.RIGHT, 8.0, DT, {}, {"active": true, "movementBlocked": false}, certified_velocity)
	var committed: Vector3 = moving.get_meta("npc_avoidance_committed_velocity", Vector3.ZERO)
	var realized: Vector3 = moving.get_meta("npc_applied_velocity", Vector3.ZERO)
	var final_separation := Vector2(moving.global_position.x - stationary.global_position.x, moving.global_position.z - stationary.global_position.z).length()
	var passed := certified_velocity.x < -0.01 \
		and committed.is_equal_approx(certified_velocity) \
		and realized.x < -0.01 \
		and final_separation > initial_separation \
		and float(result.get("moved", 0.0)) > 0.0
	return outcome(passed, "certified=%s committed=%s realized=%s separation=%.4f->%.4f result=%s" % [str(certified_velocity), str(committed), str(realized), initial_separation, final_separation, JSON.stringify(result)], ["certificate_can_reintroduce_required_reverse", "executor_commits_exact_certified_velocity", "shared_motor_executes_certified_reverse", "separation_improves"], {"certified": certified_velocity, "committed": committed, "realized": realized, "initialSeparation": initial_separation, "finalSeparation": final_separation, "result": result})


func test_visual_intentional_zero_velocity_uses_idle_pose(_mode: String) -> Dictionary:
	var body := make_actor("npc-visual-idle", Vector3.ZERO)
	var visual: Dictionary = NpcBipedVisualFactoryScript.add_biped(body, {}, "Idle Citizen")
	var presenter = visual.get("locomotion")
	var skeleton := visual.get("skeleton") as Skeleton3D
	body.velocity = Vector3.RIGHT * 2.0
	body.set_meta("npc_applied_velocity", Vector3.RIGHT * 2.0)
	presenter.apply_body_motion(body, 0.2)
	var moving_weight := float(presenter.get("gait_weight"))
	body.set_meta("npc_applied_velocity", Vector3.ZERO)
	presenter.apply_body_motion(body, DT)
	var idle_weight := float(presenter.get("gait_weight"))
	var leg_index := skeleton.find_bone("LegLeft")
	var leg_rotation := skeleton.get_bone_pose_rotation(leg_index)
	var anatomy := visual.get("visualRoot").get_node("NpcBipedSkeleton/NpcTorsoAttachment/NpcBipedAnatomy") as Node3D
	var passed := moving_weight > 0.0 \
		and is_zero_approx(idle_weight) \
		and leg_rotation.is_equal_approx(Quaternion.IDENTITY) \
		and is_zero_approx(anatomy.position.y)
	return outcome(passed, "bodyVelocity=%s applied=%s movingWeight=%.3f idleWeight=%.3f leg=%s anatomyY=%.5f" % [str(body.velocity), str(body.get_meta("npc_applied_velocity")), moving_weight, idle_weight, str(leg_rotation), anatomy.position.y], ["presentation_reads_realized_velocity_metadata", "stale_character_body_velocity_cannot_play_walk", "intentional_zero_snaps_to_idle_pose"], {"bodyVelocity": body.velocity, "appliedVelocity": body.get_meta("npc_applied_velocity"), "movingWeight": moving_weight, "idleWeight": idle_weight, "legRotation": leg_rotation, "anatomyY": anatomy.position.y})


func test_visual_terminal_arrival_publishes_idle_pose(_mode: String) -> Dictionary:
	var body := make_actor("npc-terminal-idle", Vector3.ZERO)
	var visual: Dictionary = NpcBipedVisualFactoryScript.add_biped(body, {}, "Terminal Citizen")
	var presenter = visual.get("locomotion")
	body.set_meta("npc_applied_velocity", Vector3.RIGHT * 2.0)
	presenter.apply_body_motion(body, 0.2)
	var moving_weight := float(presenter.get("gait_weight"))
	var executor := NpcRouteLeaseExecutorScript.new()
	executor.setup(null, null, null, InactiveCrowdVelocityService.new())
	var entry := {"id": "npc-terminal-idle", "body": body}
	var lease := {"state": "ready", "waypoints": [Vector3.ZERO], "actions": {}, "probeCertificate": {"ok": true, "authoritative": true}}
	var result: Dictionary = executor.execute(entry, "terminal-idle-request", lease, DT)
	presenter.apply_body_motion(body, DT)
	var passed := moving_weight > 0.0 \
		and String(result.get("status", "")) == "arrived" \
		and (body.get_meta("npc_requested_velocity", Vector3.ONE) as Vector3).is_zero_approx() \
		and (body.get_meta("npc_applied_velocity", Vector3.ONE) as Vector3).is_zero_approx() \
		and presenter_is_neutral(presenter, visual)
	return outcome(passed, "result=%s requested=%s applied=%s gait=%.3f" % [JSON.stringify(result), str(body.get_meta("npc_requested_velocity")), str(body.get_meta("npc_applied_velocity")), float(presenter.get("gait_weight"))], ["terminal_arrival_publishes_zero_realized_motion", "presenter_returns_to_idle_after_terminal_route", "no_stale_walk_pose_after_arrival"], {"result": result, "requestedVelocity": body.get_meta("npc_requested_velocity"), "appliedVelocity": body.get_meta("npc_applied_velocity"), "gaitWeight": presenter.get("gait_weight")})


func test_visual_door_stage_wait_publishes_idle_pose(_mode: String) -> Dictionary:
	var body := make_actor("npc-door-stage-idle", Vector3.ZERO)
	var visual: Dictionary = NpcBipedVisualFactoryScript.add_biped(body, {}, "Door Citizen")
	var presenter = visual.get("locomotion")
	body.set_meta("npc_applied_velocity", Vector3.RIGHT * 2.0)
	presenter.apply_body_motion(body, 0.2)
	var moving_weight := float(presenter.get("gait_weight"))
	var door := Node3D.new()
	if runner is Node:
		runner.add_child(door)
	var executor := NpcRouteLeaseExecutorScript.new()
	executor.setup(null, null, DoorStageWaitSystem.new(), InactiveCrowdVelocityService.new())
	var entry := {"id": "npc-door-stage-idle", "body": body}
	var waypoint := Vector3(0.5, 0.0, 0.0)
	var lease := {
		"state": "ready",
		"waypoints": [waypoint],
		"actions": {"door:test": {"kind": "door", "enabled": true, "portalId": "door:test", "door": door, "entryPosition": waypoint}},
		"probeCertificate": {"ok": true, "authoritative": true}
	}
	var result: Dictionary = executor.execute(entry, "door-stage-idle-request", lease, DT)
	presenter.apply_body_motion(body, DT)
	var passed := moving_weight > 0.0 \
		and String(result.get("reason", "")) == "door_stage_required" \
		and (body.get_meta("npc_requested_velocity", Vector3.ONE) as Vector3).is_zero_approx() \
		and (body.get_meta("npc_applied_velocity", Vector3.ONE) as Vector3).is_zero_approx() \
		and presenter_is_neutral(presenter, visual)
	return outcome(passed, "result=%s requested=%s applied=%s gait=%.3f" % [JSON.stringify(result), str(body.get_meta("npc_requested_velocity")), str(body.get_meta("npc_applied_velocity")), float(presenter.get("gait_weight"))], ["door_stage_wait_publishes_zero_realized_motion", "presenter_returns_to_idle_while_waiting_for_door", "no_stale_walk_pose_at_door_stage"], {"result": result, "requestedVelocity": body.get_meta("npc_requested_velocity"), "appliedVelocity": body.get_meta("npc_applied_velocity"), "gaitWeight": presenter.get("gait_weight")})


func presenter_is_neutral(presenter, visual: Dictionary) -> bool:
	var skeleton := visual.get("skeleton") as Skeleton3D
	if presenter == null or skeleton == null:
		return false
	var leg_rotation := skeleton.get_bone_pose_rotation(skeleton.find_bone("LegLeft"))
	var anatomy := visual.get("visualRoot").get_node("NpcBipedSkeleton/NpcTorsoAttachment/NpcBipedAnatomy") as Node3D
	return is_zero_approx(float(presenter.get("gait_weight"))) \
		and leg_rotation.is_equal_approx(Quaternion.IDENTITY) \
		and anatomy != null and is_zero_approx(anatomy.position.y)


func test_missing_callback_isolates_local_component(_mode: String) -> Dictionary:
	var service := NpcCrowdVelocityServiceScript.new()
	ticket_deliveries.clear()
	service.physics_frame = 41
	service.submissions_closed = true
	service.pending_tickets_by_actor_id = {
		"a": {"requestKey": "a:1", "consumer": Callable(self, "record_ticket_delivery").bind("a"), "neighborActorIds": ["a"]},
		"b": {"requestKey": "b:1", "consumer": Callable(self, "record_ticket_delivery").bind("b"), "neighborActorIds": ["b"]}
	}
	service.safe_velocity_by_actor_id = {"a": Vector3.RIGHT}
	service.call("_commit_ready_tickets")
	var isolated := ticket_deliveries == ["a"] and not service.pending_tickets_by_actor_id.has("a") and service.pending_tickets_by_actor_id.has("b")
	service.begin_physics_frame([])
	var ticket_stats: Dictionary = service.stats().get("tickets", {})
	var diagnosed := int(ticket_stats.get("missingCallbackFrames", 0)) == 1 and int(ticket_stats.get("missingCallbackTickets", 0)) == 1
	return outcome(isolated and diagnosed, "deliveries=%s tickets=%s" % [JSON.stringify(ticket_deliveries), JSON.stringify(ticket_stats)], ["ready_component_commits_independently", "missing_component_retries_next_frame", "missing_callback_is_diagnosed"], {"deliveries": ticket_deliveries.duplicate(), "tickets": ticket_stats})

func test_unresolved_stationary_is_edge_triggered(_mode: String) -> Dictionary:
	var service := NpcCrowdVelocityServiceScript.new()
	service.setup(null, null)
	var body := make_actor("npc-unresolved", Vector3.ZERO)
	var entry := {
		"id": "npc-unresolved",
		"body": body,
		"routeStatus": "moving",
		"routeLease": {"leaseId": "unresolved-lease", "waypoints": [Vector3.RIGHT]}
	}
	for _frame in range(8):
		service.begin_physics_frame([entry])
		service.end_physics_frame()
	var corrections := int(service.stats().get("realizedVelocityCorrections", 0))
	var passed := corrections == 1 and bool(entry.get("_crowdUnresolvedStationary", false))
	return outcome(passed, "corrections=%d unresolved=%s" % [corrections, str(entry.get("_crowdUnresolvedStationary", false))], ["unresolved_episode_forces_solver_once", "unresolved_stationary_state_persists_until_submission"], {"corrections": corrections})


func record_ticket_delivery(_velocity: Vector3, _request_key: String, actor_id: String) -> void:
	ticket_deliveries.append(actor_id)


func record_ticket_velocity(velocity: Vector3, _request_key: String, actor_id: String) -> void:
	ticket_velocity_by_actor_id[actor_id] = velocity


func force_unsafe_ticket_velocity(_velocity: Vector3) -> Vector3:
	return Vector3.RIGHT


func test_dynamic_contact_reaches_shared_motor(_mode: String) -> Dictionary:
	var executor := NpcRouteLeaseExecutorScript.new()
	var passed := not executor.has_method("_dynamic_npc_blocker") and not executor.has_method("_motion_enters_actor")
	return outcome(passed, "dynamicPreflight=%s" % str(executor.has_method("_dynamic_npc_blocker")), ["orca_safe_velocity_reaches_shared_motor", "motor_slide_preserves_contact_escape", "no_all_or_nothing_dynamic_preflight"], {})


func test_order_replacement_invalidates_executor_ticket(_mode: String) -> Dictionary:
	var executor := NpcRouteLeaseExecutorScript.new()
	var body := make_actor("npc-replaced-order", Vector3.ZERO)
	body.set_meta("npc_requested_velocity", Vector3.RIGHT)
	body.set_meta("npc_avoidance_committed_velocity", Vector3.RIGHT)
	body.set_meta("npc_applied_velocity", Vector3.RIGHT)
	var entry := {
		"id": "npc-replaced-order",
		"body": body,
		"_v2LeaseExecutorRequestId": "old-request",
		"_v2LeaseExecutorWaypointIndex": 2,
		"_v2LeaseExecutorPendingAvoidance": {"requestKey": "old-request|2"}
	}
	executor.cancel_entry(entry)
	var cancelled_generation := int(entry.get("_v2LeaseExecutorGeneration", 0))
	entry["_v2LeaseExecutorRequestId"] = "old-request"
	entry["_v2LeaseExecutorWaypointIndex"] = 2
	entry["_v2LeaseExecutorGeneration"] = cancelled_generation + 1
	entry["_v2LeaseExecutorPendingAvoidance"] = {
		"generation": cancelled_generation + 1,
		"requestKey": "old-request|2|g%d" % (cancelled_generation + 1),
		"requestId": "old-request",
		"index": 2
	}
	executor.call("_commit_deferred_safe_velocity", Vector3.RIGHT * 9.0, "old-request|2|g%d" % (cancelled_generation - 1), entry)
	var passed := String(entry.get("_v2LeaseExecutorRequestId", "")) == "old-request" \
		and entry.has("_v2LeaseExecutorPendingAvoidance") \
		and (body.get_meta("npc_requested_velocity", Vector3.ONE) as Vector3).is_zero_approx() \
		and (body.get_meta("npc_applied_velocity", Vector3.ONE) as Vector3).is_zero_approx() \
		and body.global_position.is_zero_approx()
	return outcome(passed, "entry=%s requested=%s applied=%s position=%s" % [JSON.stringify(entry), str(body.get_meta("npc_requested_velocity")), str(body.get_meta("npc_applied_velocity")), str(body.global_position)], ["replacement_advances_executor_generation", "same_key_stale_callback_cannot_move_rebound_order", "replacement_publishes_stationary_velocity"], {})

func test_missing_shared_authority_blocks(_mode: String) -> Dictionary:
	var service = NpcCrowdVelocityServiceScript.new()
	var body := make_actor("npc-missing-authority", Vector3.ZERO)
	var result: Dictionary = service.resolve_safe_velocity({"id": "npc-missing-authority"}, body, Vector3.RIGHT, {})
	var safe: Vector3 = result.get("safeVelocity", Vector3.ONE)
	var passed := bool(result.get("movementBlocked", false)) and safe.length_squared() <= 0.000001 and String(result.get("reason", "")) == "missing_adapter"
	return outcome(passed, "result=%s" % JSON.stringify(result), ["missing_crowd_authority_fails_closed", "missing_crowd_authority_never_returns_desired_velocity"], {"result": result})

func test_stale_callback_safe_stop(_mode: String) -> Dictionary:
	var body := make_actor("npc-a", Vector3.ZERO)
	var other := make_actor("npc-b", Vector3(CELL, 0.0, 0.0))
	var follower = NpcCorridorFollowerScript.new()
	var adapter = ReciprocalAvoidanceAdapterScript.new()
	var actor_id := "npc-a"
	adapter.record_safe_velocity(actor_id, Vector3(99.0, 0.0, 99.0))
	adapter.begin_frame()
	adapter.begin_frame()
	adapter.begin_frame()
	var validator = SyntheticValidator.new()
	validator.fail_reason = "blocked_static"
	var follow: Dictionary = follower.compute_step({ "id": actor_id }, body, body.global_position, Vector3(4.0, 0.0, 0.0), [Vector3(4.0, 0.0, 0.0)], intent(), CELL * 0.30, SyntheticWorld.new(), validator, adapter, [body, other])
	var avoidance: Dictionary = follow.get("avoidance", {})
	var passed := not bool(follow.get("ok", true)) and bool(avoidance.get("fallbackUsed", false)) and String(follow.get("classification", "")) == "static_collision"
	return outcome(passed, "follow=%s" % JSON.stringify(compact_follow(follow)), ["stale_callback_not_reused", "safe_stop_or_validated_direct"], { "follow": compact_follow(follow) })


func test_callback_command_generation_bound(_mode: String) -> Dictionary:
	var adapter := ReciprocalAvoidanceAdapterScript.new()
	var body := make_actor("npc-generation", Vector3.ZERO)
	var other := make_actor("npc-other", Vector3(CELL, 0.0, 0.0))
	adapter.begin_frame()
	var context_a := {
		"actors": [body, other], "forceAvoidance": true, "maxSpeed": 1.2,
		"avoidanceTarget": Vector3(4.0, 0.0, 0.0), "avoidanceRequestKey": "lease-a|0"
	}
	var context_b := {
		"actors": [body, other],
		"forceAvoidance": true,
		"maxSpeed": 1.2,
		"avoidanceTarget": Vector3(0.0, 0.0, -4.0),
		"avoidanceRequestKey": "lease-b|0"
	}
	adapter.compute_safe_velocity({"id": "npc-generation"}, body, Vector3.RIGHT * 1.2, context_a)
	var agent := body.get_node_or_null("NpcAvoidanceAgent") as NavigationAgent3D
	var submission_a := String(agent.get_meta("npc_avoidance_submission_key", ""))
	adapter.call("_on_velocity_computed", Vector3.RIGHT * 1.2, "npc-generation", submission_a, "lease-a|0", Callable())
	var changed: Dictionary = adapter.compute_safe_velocity({"id": "npc-generation"}, body, Vector3.FORWARD * 1.2, context_b)
	adapter.call("_on_velocity_computed", Vector3.RIGHT * 1.2, "npc-generation", submission_a, "lease-a|0", Callable())
	adapter.begin_frame()
	adapter.compute_safe_velocity({"id": "npc-generation"}, body, Vector3.FORWARD * 1.2, context_b)
	adapter.call("_on_velocity_computed", Vector3.RIGHT * 1.2, "npc-generation", submission_a, "lease-a|0", Callable())
	var delayed: Dictionary = adapter.compute_safe_velocity({"id": "npc-generation"}, body, Vector3.FORWARD * 1.2, context_b)
	for _frame in range(NpcConstantsScript.AVOIDANCE_CALLBACK_STALE_FRAMES):
		adapter.begin_frame()
		adapter.compute_safe_velocity({"id": "npc-generation"}, body, Vector3.FORWARD * 1.2, context_b)
	var current_submission := String(agent.get_meta("npc_avoidance_submission_key", ""))
	adapter.call("_on_velocity_computed", Vector3.FORWARD * 1.2, "npc-generation", current_submission, "lease-b|0", Callable())
	var accepted: Dictionary = adapter.compute_safe_velocity({"id": "npc-generation"}, body, Vector3.FORWARD * 1.2, context_b)
	var changed_safe: Vector3 = changed.get("safeVelocity", Vector3.ONE)
	var delayed_safe: Vector3 = delayed.get("safeVelocity", Vector3.ONE)
	var accepted_safe: Vector3 = accepted.get("safeVelocity", Vector3.ZERO)
	var passed := not bool(changed.get("callbackFresh", true)) and changed_safe.is_zero_approx() \
		and not bool(delayed.get("callbackFresh", true)) and delayed_safe.is_zero_approx() \
		and bool(accepted.get("callbackFresh", false)) and accepted_safe.is_equal_approx(Vector3.FORWARD * 1.2)
	return outcome(passed, "changed=%s delayed=%s accepted=%s" % [JSON.stringify(changed), JSON.stringify(delayed), JSON.stringify(accepted)], ["same_frame_prior_command_callback_quarantined", "delayed_prior_command_callback_quarantined", "stable_generation_callback_accepted_after_quarantine"], {"changed": changed, "delayed": delayed, "accepted": accepted})

func test_callback_disable_reenable_single_delivery(_mode: String) -> Dictionary:
	var adapter := ReciprocalAvoidanceAdapterScript.new()
	var body := make_actor("npc-lifecycle", Vector3.ZERO)
	var other := make_actor("npc-other", Vector3(CELL, 0.0, 0.0))
	var entry := {"id": "npc-lifecycle"}
	var context := {
		"actors": [body, other],
		"forceAvoidance": true,
		"maxSpeed": 1.2,
		"avoidanceTarget": Vector3(4.0, 0.0, 0.0),
		"avoidanceRequestKey": "lease-a|0"
	}
	adapter.begin_frame()
	adapter.compute_safe_velocity(entry, body, Vector3.RIGHT * 1.2, context)
	var agent := body.get_node_or_null("NpcAvoidanceAgent") as NavigationAgent3D
	var first_connections := agent.velocity_computed.get_connections().size() if agent != null else -1
	adapter.disable_actor("npc-lifecycle")
	var disabled_connections := agent.velocity_computed.get_connections().size() if agent != null else -1
	context["avoidanceRequestKey"] = "lease-b|0"
	adapter.compute_safe_velocity(entry, body, Vector3.RIGHT * 1.2, context)
	adapter.disable_actor("npc-lifecycle")
	context["avoidanceRequestKey"] = "lease-a|0"
	adapter.compute_safe_velocity(entry, body, Vector3.RIGHT * 1.2, context)
	for _frame in range(NpcConstantsScript.AVOIDANCE_CALLBACK_STALE_FRAMES + 1):
		adapter.begin_frame()
		adapter.compute_safe_velocity(entry, body, Vector3.RIGHT * 1.2, context)
	var final_connections := agent.velocity_computed.get_connections().size() if agent != null else -1
	var deliveries_before := int(adapter.stats().get("callbackDeliveries", 0))
	if agent != null:
		agent.velocity_computed.emit(Vector3.RIGHT * 0.75)
	var deliveries_after := int(adapter.stats().get("callbackDeliveries", 0))
	var delivered: Dictionary = adapter.compute_safe_velocity(entry, body, Vector3.RIGHT * 1.2, context)
	var safe: Vector3 = delivered.get("safeVelocity", Vector3.ZERO)
	var passed := first_connections == 1 and disabled_connections == 0 and final_connections == 1 \
		and deliveries_after - deliveries_before == 1 \
		and bool(delivered.get("callbackFresh", false)) and safe.is_equal_approx(Vector3.RIGHT * 0.75)
	return outcome(
		passed,
		"connections=%d/%d/%d deliveries=%d safe=%s" % [first_connections, disabled_connections, final_connections, deliveries_after - deliveries_before, str(safe)],
		["disable_disconnects_callback", "reenable_has_single_connection", "signal_delivers_once"],
		{"firstConnections": first_connections, "disabledConnections": disabled_connections, "finalConnections": final_connections, "deliveryDelta": deliveries_after - deliveries_before, "safeVelocity": safe}
	)

func test_agent_receives_live_target(_mode: String) -> Dictionary:
	var adapter := ReciprocalAvoidanceAdapterScript.new()
	var body := make_actor("npc-a", Vector3.ZERO)
	var other := make_actor("npc-b", Vector3(CELL, 0.0, 0.0))
	var target := Vector3(4.0, 0.0, 1.0)
	adapter.compute_safe_velocity({ "id": "npc-a" }, body, Vector3.RIGHT * 1.2, {
		"actors": [body, other],
		"forceAvoidance": true,
		"maxSpeed": 1.2,
		"avoidanceTarget": target
	})
	var agent := body.get_node_or_null("NpcAvoidanceAgent") as NavigationAgent3D
	var passed := agent != null and agent.target_position.is_equal_approx(target)
	return outcome(passed, "target=%s configured=%s" % [str(target), str(agent.target_position if agent != null else Vector3.INF)], ["avoidance_target_published_to_navigation_agent"], { "target": target, "configured": agent.target_position if agent != null else Vector3.INF })

func test_zero_fresh_callback_holds_safely(_mode: String) -> Dictionary:
	var adapter := ReciprocalAvoidanceAdapterScript.new()
	var body := make_actor("npc-a", Vector3.ZERO)
	var entry := { "id": "npc-a" }
	var first_result: Dictionary = {}
	var final_result: Dictionary = {}
	for frame in range(NpcConstantsScript.AVOIDANCE_FRESH_ZERO_RECOVERY_FRAMES):
		adapter.begin_frame()
		adapter.record_safe_velocity("npc-a", Vector3.ZERO)
		var result: Dictionary = adapter.compute_safe_velocity(entry, body, Vector3.RIGHT * 1.2, {
			"actors": [body],
			"forceAvoidance": true,
			"maxSpeed": 1.2,
			"avoidanceTarget": Vector3(4.0, 0.0, 0.0)
		})
		if frame == 0:
			first_result = result
		final_result = result
	var first_velocity: Vector3 = first_result.get("safeVelocity", Vector3.ONE)
	var final_velocity: Vector3 = final_result.get("safeVelocity", Vector3.ONE)
	var passed := bool(first_result.get("callbackFresh", false)) \
		and not bool(first_result.get("fallbackUsed", true)) \
		and first_velocity.length() <= 0.001 \
		and bool(final_result.get("callbackFresh", false)) \
		and not bool(final_result.get("fallbackUsed", true)) \
		and final_velocity.length() <= 0.001
	return outcome(passed, "first=%s final=%s stats=%s" % [JSON.stringify(first_result), JSON.stringify(final_result), JSON.stringify(adapter.stats())], ["fresh_zero_honored", "no_competing_predictive_steering"], { "first": first_result, "final": final_result, "stats": adapter.stats() })

func test_follow_arrival_no_orbit(_mode: String) -> Dictionary:
	var body := make_actor("npc-a", Vector3.ZERO)
	var follower = NpcCorridorFollowerScript.new()
	var follow: Dictionary = follower.compute_step({ "id": "npc-a" }, body, body.global_position, Vector3(0.05, 0.0, 0.0), [Vector3(0.05, 0.0, 0.0)], intent({ "arrivalRadius": 0.20 }), CELL * 0.30, SyntheticWorld.new(), SyntheticValidator.new(), ReciprocalAvoidanceAdapterScript.new(), [body])
	var safe_velocity: Vector3 = follow.get("safeVelocity", Vector3.ONE)
	var passed := bool(follow.get("arrived", false)) and safe_velocity.length() <= 0.001
	return outcome(passed, "follow=%s" % JSON.stringify(compact_follow(follow)), ["arrival_stops", "no_orbit_velocity"], { "follow": compact_follow(follow) })

func test_progress_watchdog_classifies_blocker(_mode: String) -> Dictionary:
	var follower = NpcCorridorFollowerScript.new()
	var entry := {}
	var previous := Vector3.ZERO
	var actual := Vector3.ZERO
	var result := {}
	for _i in range(NpcConstantsScript.CORRIDOR_NO_PROGRESS_TICKS):
		result = follower.record_motion(entry, previous, actual, [Vector3(4.0, 0.0, 0.0)], "blocked_dynamic")
	var passed := String(result.get("classification", "")) == "dynamic_actor" and int(result.get("noProgressTicks", 0)) >= NpcConstantsScript.CORRIDOR_NO_PROGRESS_TICKS
	return outcome(passed, "result=%s" % JSON.stringify(result), ["progress_window_classifies_blocker"], { "result": result })

func test_day_crowd_progress(mode: String) -> Dictionary:
	var sim := simulate_pair(Vector3(-1.6, 0.0, 0.25), Vector3(1.6, 0.0, -0.25), Vector3.RIGHT * 1.7, Vector3.LEFT * 1.7, 42)
	var passed := mode == "day" or mode == "night"
	passed = passed and float(sim.get("aProgress", 0.0)) > 1.0 and float(sim.get("bProgress", 0.0)) > 1.0 and float(sim.get("minSeparation", 0.0)) > 0.68
	return outcome(passed, "mode=%s progress %.2f/%.2f minSep %.2f" % [mode, float(sim.get("aProgress", 0.0)), float(sim.get("bProgress", 0.0)), float(sim.get("minSeparation", 0.0))], ["day_night_crowd_progress", "bounded_progress"], sim)

func test_night_guard_passes_returning_civilian(mode: String) -> Dictionary:
	var sim := simulate_pair(Vector3(-1.8, 0.0, 0.0), Vector3(1.8, 0.0, 0.0), Vector3.RIGHT * 1.9, Vector3.LEFT * 1.4, 44)
	var passed := mode == "day" or mode == "night"
	passed = passed and float(sim.get("aProgress", 0.0)) > 1.1 and float(sim.get("bProgress", 0.0)) > 0.9 and float(sim.get("minSeparation", 0.0)) > 0.68 and int(sim.get("activeFrames", 0)) > 0
	return outcome(passed, "mode=%s guard/civilian %.2f/%.2f minSep %.2f" % [mode, float(sim.get("aProgress", 0.0)), float(sim.get("bProgress", 0.0)), float(sim.get("minSeparation", 0.0))], ["night_guard_civilian_pass", "avoidance_active"], sim)

func simulate_pair(a_start: Vector3, b_start: Vector3, a_desired: Vector3, b_desired: Vector3, steps: int) -> Dictionary:
	var adapter := ReciprocalAvoidanceAdapterScript.new()
	var a := make_actor("npc-a", a_start)
	var b := make_actor("npc-b", b_start)
	var min_sep := a.global_position.distance_to(b.global_position)
	var active := 0
	for _i in range(steps):
		adapter.begin_frame()
		a.set_meta("npc_applied_velocity", a_desired)
		b.set_meta("npc_applied_velocity", b_desired)
		a.set_meta("npc_requested_velocity", a_desired)
		b.set_meta("npc_requested_velocity", b_desired)
		adapter.record_safe_velocity("npc-a", synthetic_orca_callback_velocity(a, a_desired, [a, b], [a_desired, b_desired]))
		adapter.record_safe_velocity("npc-b", synthetic_orca_callback_velocity(b, b_desired, [a, b], [a_desired, b_desired]))
		var a_result: Dictionary = adapter.compute_safe_velocity({ "id": "npc-a" }, a, a_desired, { "actors": [a, b], "forceAvoidance": true, "maxSpeed": a_desired.length(), "avoidanceTarget": a.global_position + a_desired })
		var b_result: Dictionary = adapter.compute_safe_velocity({ "id": "npc-b" }, b, b_desired, { "actors": [a, b], "forceAvoidance": true, "maxSpeed": b_desired.length(), "avoidanceTarget": b.global_position + b_desired })
		if bool(a_result.get("active", false)):
			active += 1
		if bool(b_result.get("active", false)):
			active += 1
		var a_safe: Vector3 = a_result.get("safeVelocity", a_desired)
		var b_safe: Vector3 = b_result.get("safeVelocity", b_desired)
		set_actor_position(a, a.global_position + a_safe.limit_length(a_desired.length()) * DT)
		set_actor_position(b, b.global_position + b_safe.limit_length(b_desired.length()) * DT)
		min_sep = minf(min_sep, a.global_position.distance_to(b.global_position))
	return {
		"aProgress": a.global_position.distance_to(a_start),
		"bProgress": b.global_position.distance_to(b_start),
		"minSeparation": min_sep,
		"activeFrames": active,
		"stats": adapter.stats()
	}

func synthetic_orca_callback_velocity(actor: CharacterBody3D, desired_velocity: Vector3, actors: Array, desired_velocities: Array) -> Vector3:
	if desired_velocity.length_squared() <= 0.0001:
		return Vector3.ZERO
	var forward := desired_velocity.normalized()
	var right := Vector3(-forward.z, 0.0, forward.x)
	var adjusted := desired_velocity
	for other_index in range(actors.size()):
		var other := actors[other_index] as CharacterBody3D
		if other == null or other == actor:
			continue
		var offset := other.global_position - actor.global_position
		offset.y = 0.0
		var distance := offset.length()
		if distance <= 0.001 or distance > 2.4 or forward.dot(offset / distance) <= -0.1:
			continue
		var other_desired: Vector3 = desired_velocities[other_index] if other_index < desired_velocities.size() else Vector3.ZERO
		var closing_speed := (desired_velocity - other_desired).dot(offset / distance)
		if closing_speed <= 0.0:
			continue
		var urgency := clampf(1.0 - distance / 2.4, 0.0, 1.0)
		adjusted += right * desired_velocity.length() * (0.32 + urgency * 0.55)
	return adjusted.limit_length(desired_velocity.length())

func make_actor(id: String, position: Vector3) -> CharacterBody3D:
	var actor := CharacterBody3D.new()
	actor.name = id
	var collider := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.34
	shape.height = 1.62
	collider.shape = shape
	collider.position.y = 0.81
	actor.add_child(collider)
	if runner is Node:
		runner.add_child(actor)
	set_actor_position(actor, position)
	actor.set_meta("npc_stable_id", id)
	return actor

func set_actor_position(actor: Node3D, position: Vector3) -> void:
	actor.position = position
	actor.global_position = position

func min_pair_separation(actors: Array) -> float:
	var result := INF
	for i in range(actors.size()):
		for j in range(i + 1, actors.size()):
			result = minf(result, (actors[i] as Node3D).global_position.distance_to((actors[j] as Node3D).global_position))
	return result

func intent(extra := {}) -> Dictionary:
	var result := {
		"physicsDelta": DT,
		"arrivalRadius": CELL * 0.45,
		"movingHome": false,
		"allowOutside": true
	}
	for key in extra.keys():
		result[key] = extra[key]
	return result

func compact_follow(follow: Dictionary) -> Dictionary:
	var candidate: Vector3 = follow.get("candidate", Vector3.ZERO)
	var safe: Vector3 = follow.get("safeVelocity", Vector3.ZERO)
	var avoidance: Dictionary = follow.get("avoidance", {})
	return {
		"ok": bool(follow.get("ok", false)),
		"arrived": bool(follow.get("arrived", false)),
		"reason": String(follow.get("reason", "")),
		"classification": String(follow.get("classification", "")),
		"portalMode": bool(follow.get("portalMode", false)),
		"candidate": [candidate.x, candidate.y, candidate.z],
		"safeVelocity": [safe.x, safe.y, safe.z],
		"avoidance": {
			"active": bool(avoidance.get("active", false)),
			"reason": String(avoidance.get("reason", "")),
			"fallbackUsed": bool(avoidance.get("fallbackUsed", false)),
			"callbackFresh": bool(avoidance.get("callbackFresh", false))
		}
	}

func outcome(passed: bool, details: String, assertions: Array, key_state: Dictionary) -> Dictionary:
	if runner != null and runner.has_method("outcome"):
		return runner.call("outcome", passed, details, assertions, key_state)
	return {
		"passed": passed,
		"details": details,
		"assertions": assertions,
		"keyState": key_state
	}
