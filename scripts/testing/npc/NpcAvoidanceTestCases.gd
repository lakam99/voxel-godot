extends RefCounted

const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")
const NpcCorridorFollowerScript := preload("res://scripts/npc_ai/movement/NpcCorridorFollower.gd")
const ReciprocalAvoidanceAdapterScript := preload("res://scripts/npc_ai/movement/ReciprocalAvoidanceAdapter.gd")

const CELL := 1.35
const DT := 1.0 / 60.0

var runner = null

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

func setup(owner) -> void:
	runner = owner

func cases() -> Array[Dictionary]:
	var ids = [
		["npc_avoidance_head_on_open_road", "test_head_on_open_road"],
		["npc_avoidance_crossing_paths", "test_crossing_paths"],
		["npc_avoidance_overtake_slow_actor", "test_overtake_slow_actor"],
		["npc_avoidance_crowded_plaza_progress", "test_crowded_plaza_progress"],
		["npc_avoidance_corridor_boundary_respected", "test_corridor_boundary_respected"],
		["npc_avoidance_no_left_right_oscillation", "test_no_left_right_oscillation"],
		["npc_avoidance_wall_not_treated_as_rvo_only", "test_wall_not_treated_as_rvo_only"],
		["npc_avoidance_closed_door_not_bypassed", "test_closed_door_not_bypassed"],
		["npc_avoidance_portal_mode_no_frame_sidestep", "test_portal_mode_no_frame_sidestep"],
		["npc_avoidance_inactive_agents_disabled", "test_inactive_agents_disabled"],
		["npc_avoidance_stale_callback_safe_stop", "test_stale_callback_safe_stop"],
		["npc_avoidance_zero_fresh_callback_falls_back", "test_zero_fresh_callback_falls_back"],
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

func test_head_on_open_road(_mode: String) -> Dictionary:
	var sim := simulate_pair(Vector3(-2.0, 0.0, 0.0), Vector3(2.0, 0.0, 0.0), Vector3.RIGHT * 2.1, Vector3.LEFT * 2.1, 54)
	var passed := float(sim.get("aProgress", 0.0)) > 1.6 and float(sim.get("bProgress", 0.0)) > 1.6 and float(sim.get("minSeparation", 0.0)) > 0.44 and int(sim.get("activeFrames", 0)) > 0
	return outcome(passed, "progress %.2f/%.2f minSep %.2f active %d" % [float(sim.get("aProgress", 0.0)), float(sim.get("bProgress", 0.0)), float(sim.get("minSeparation", 0.0)), int(sim.get("activeFrames", 0))], ["head_on_progress", "minimum_separation", "avoidance_active"], sim)

func test_crossing_paths(_mode: String) -> Dictionary:
	var sim := simulate_pair(Vector3(-1.8, 0.0, 0.0), Vector3(0.0, 0.0, -1.8), Vector3.RIGHT * 1.9, Vector3.FORWARD * -1.9, 38)
	var passed := float(sim.get("aProgress", 0.0)) > 1.1 and float(sim.get("bProgress", 0.0)) > 1.1 and float(sim.get("minSeparation", 0.0)) > 0.38 and int(sim.get("activeFrames", 0)) > 0
	return outcome(passed, "cross progress %.2f/%.2f minSep %.2f" % [float(sim.get("aProgress", 0.0)), float(sim.get("bProgress", 0.0)), float(sim.get("minSeparation", 0.0))], ["crossing_progress", "crossing_separation"], sim)

func test_overtake_slow_actor(_mode: String) -> Dictionary:
	var sim := simulate_pair(Vector3(-2.2, 0.0, 0.0), Vector3(-0.7, 0.0, 0.0), Vector3.RIGHT * 2.4, Vector3.RIGHT * 0.65, 60)
	var passed := float(sim.get("aProgress", 0.0)) > float(sim.get("bProgress", 0.0)) and float(sim.get("minSeparation", 0.0)) > 0.30 and int(sim.get("activeFrames", 0)) > 0
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
		for j in range(actors.size()):
			var actor := actors[j] as CharacterBody3D
			var result: Dictionary = adapter.compute_safe_velocity({ "id": actor.name }, actor, desired[j], { "actors": actors, "forceAvoidance": true, "maxSpeed": 1.8 })
			if bool(result.get("active", false)):
				active += 1
			var safe_velocity: Vector3 = result.get("safeVelocity", desired[j])
			set_actor_position(actor, actor.global_position + safe_velocity.limit_length(1.8) * DT)
		min_sep = minf(min_sep, min_pair_separation(actors))
	var progress := 0.0
	for j in range(actors.size()):
		var actor := actors[j] as Node3D
		progress += actor.global_position.distance_to(initial[j])
	var passed := progress > 3.0 and min_sep > 0.30 and active > 0
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

func test_zero_fresh_callback_falls_back(_mode: String) -> Dictionary:
	var adapter := ReciprocalAvoidanceAdapterScript.new()
	var body := make_actor("npc-a", Vector3.ZERO)
	adapter.record_safe_velocity("npc-a", Vector3.ZERO)
	var result: Dictionary = adapter.compute_safe_velocity({ "id": "npc-a" }, body, Vector3.RIGHT * 1.2, {
		"actors": [body],
		"forceAvoidance": true,
		"maxSpeed": 1.2
	})
	var safe_velocity: Vector3 = result.get("safeVelocity", Vector3.ZERO)
	var passed := bool(result.get("active", false)) and bool(result.get("fallbackUsed", false)) and not bool(result.get("callbackFresh", true)) and safe_velocity.length() > 0.1
	return outcome(passed, "result=%s stats=%s" % [JSON.stringify(result), JSON.stringify(adapter.stats())], ["fresh_zero_callback_not_permanent_stop", "predictive_fallback_progress"], { "result": result, "stats": adapter.stats() })

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
	var sim := simulate_pair(Vector3(-1.6, 0.0, 0.25), Vector3(1.6, 0.0, -0.25), Vector3.RIGHT * 1.7, Vector3.LEFT * 1.7, 36)
	var passed := mode == "day" or mode == "night"
	passed = passed and float(sim.get("aProgress", 0.0)) > 1.0 and float(sim.get("bProgress", 0.0)) > 1.0 and float(sim.get("minSeparation", 0.0)) > 0.34
	return outcome(passed, "mode=%s progress %.2f/%.2f minSep %.2f" % [mode, float(sim.get("aProgress", 0.0)), float(sim.get("bProgress", 0.0)), float(sim.get("minSeparation", 0.0))], ["day_night_crowd_progress", "bounded_progress"], sim)

func test_night_guard_passes_returning_civilian(mode: String) -> Dictionary:
	var sim := simulate_pair(Vector3(-1.8, 0.0, 0.0), Vector3(1.8, 0.0, 0.0), Vector3.RIGHT * 1.9, Vector3.LEFT * 1.4, 44)
	var passed := mode == "day" or mode == "night"
	passed = passed and float(sim.get("aProgress", 0.0)) > 1.1 and float(sim.get("bProgress", 0.0)) > 0.9 and float(sim.get("minSeparation", 0.0)) > 0.34 and int(sim.get("activeFrames", 0)) > 0
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
		var a_result: Dictionary = adapter.compute_safe_velocity({ "id": "npc-a" }, a, a_desired, { "actors": [a, b], "forceAvoidance": true, "maxSpeed": a_desired.length() })
		var b_result: Dictionary = adapter.compute_safe_velocity({ "id": "npc-b" }, b, b_desired, { "actors": [a, b], "forceAvoidance": true, "maxSpeed": b_desired.length() })
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
