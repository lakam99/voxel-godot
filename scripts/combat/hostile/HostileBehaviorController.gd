extends RefCounted
class_name HostileBehaviorController

const HostileBehaviorIntentScript := preload("res://scripts/combat/hostile/HostileBehaviorIntent.gd")
const HostileBehaviorPolicyScript := preload("res://scripts/combat/hostile/HostileBehaviorPolicy.gd")
const HostileLocomotionDriverScript := preload("res://scripts/combat/hostile/HostileLocomotionDriver.gd")

## Stateful adapter around the pure policy. It gathers live facts, selects a
## shared intent, asks the shared motion runtime to start a motion when needed,
## and hands movement only to HostileLocomotionDriver.

var profile
var deterministic_seed := 1
var state := "approach"
var state_elapsed := 0.0
var action_serial := 0
var motion_seed_serial := 0
var orbit_direction := 1.0
var evade_direction := Vector3.ZERO
var evade_cooldown_remaining := 0.0
var evade_stamina := 100.0
var committed_motion_kind := ""
var last_intent
var last_motor: Dictionary = {}
var last_threat: Dictionary = {}
var last_evade_reason := "not_evaluated"
var transitions: Array[Dictionary] = []
var threat_observations: Array[Dictionary] = []


func setup(next_profile, next_seed: int) -> void:
	profile = next_profile
	deterministic_seed = maxi(1, abs(next_seed))
	evade_stamina = float(profile.evade_stamina_max) if profile != null else 0.0
	orbit_direction = -1.0 if hash01("orbit") < 0.5 else 1.0
	state = "approach"
	state_elapsed = 0.0
	action_serial = 0
	motion_seed_serial = 0
	committed_motion_kind = ""
	evade_cooldown_remaining = 0.0
	evade_direction = Vector3.ZERO
	last_intent = HostileBehaviorIntentScript.new({"kind": "approach", "reason": "initial"})
	last_motor = {}
	last_threat = {}
	last_evade_reason = "not_evaluated"
	transitions.clear()
	threat_observations.clear()


func advance(delta: float, body: CharacterBody3D, target: Node3D, motion_runtime, player_motion = null, bounds: Dictionary = {}) -> Dictionary:
	if profile == null or body == null or target == null or not is_instance_valid(body) or not is_instance_valid(target):
		return summary()
	delta = maxf(0.0, delta)
	state_elapsed += delta
	evade_cooldown_remaining = maxf(0.0, evade_cooldown_remaining - delta)
	evade_stamina = minf(profile.evade_stamina_max, evade_stamina + profile.evade_stamina_regen * delta)
	var motion_active: bool = motion_runtime != null and motion_runtime.has_method("is_motion_active") and bool(motion_runtime.is_motion_active(body))
	var motion_summary: Dictionary = motion_runtime.summary_for_body(body) if motion_active and motion_runtime != null and motion_runtime.has_method("summary_for_body") else {}
	last_threat = player_threat(player_motion, body)
	var to_target: Vector3 = target.global_position - body.global_position
	to_target.y = 0.0
	var distance: float = to_target.length()
	var threat_viable: bool = bool(last_threat.get("viable", false))
	var evade_ready: bool = evade_cooldown_remaining <= 0.0 and evade_stamina >= profile.evade_stamina_cost and not motion_active and state != "recovery"
	if threat_viable:
		last_evade_reason = "ready" if evade_ready else evade_decline_reason(motion_active)
	elif state != "evade":
		last_evade_reason = String(last_threat.get("reason", "no_player_motion"))

	if state == "commit" and not motion_active and state_elapsed >= 0.06:
		transition_to("recovery", "shared_motion_finished")
	if state == "evade" and state_elapsed >= profile.evade_duration:
		transition_to("orbit", "evade_complete")
	if state == "recovery" and state_elapsed >= profile.recovery_duration:
		transition_to("orbit", "recovery_complete")

	var facts := {
		"state": state,
		"stateElapsed": state_elapsed,
		"distance": distance,
		"motionActive": motion_active,
		"motion": motion_summary,
		"threatViable": threat_viable,
		"evadeReady": evade_ready,
		"orbitDirection": orbit_direction,
		"actionSerial": action_serial,
		"evadeStamina": evade_stamina
	}
	var intent = HostileBehaviorPolicyScript.decide(profile, facts)
	if intent == null:
		intent = HostileBehaviorIntentScript.new({"kind": "hold", "reason": "policy_unavailable"})

	if String(intent.kind) == "probe":
		transition_to("probe", String(intent.reason))
		intent = HostileBehaviorIntentScript.new({"kind": "hold", "reason": "probe_entered", "orbitDirection": orbit_direction})
	elif String(intent.kind) == "commit":
		if begin_committed_motion(String(intent.motion_kind), body, target, motion_runtime):
			transition_to("commit", String(intent.reason))
			intent = HostileBehaviorIntentScript.new({"kind": "hold", "reason": "motion_windup", "orbitDirection": orbit_direction})
		else:
			intent = HostileBehaviorIntentScript.new({"kind": "orbit", "reason": "motion_start_declined", "speed": profile.orbit_speed, "orbitDirection": orbit_direction})
	elif String(intent.kind) == "evade" and state != "evade":
		if evade_ready and enter_evade(body, target):
			transition_to("evade", String(intent.reason))
			intent.direction = evade_direction
		else:
			last_evade_reason = evade_decline_reason(motion_active)
			intent = HostileBehaviorIntentScript.new({"kind": "orbit", "reason": "evade_declined_%s" % last_evade_reason, "speed": profile.orbit_speed, "orbitDirection": orbit_direction})
	elif String(intent.kind) == "orbit" and state != "orbit":
		transition_to("orbit", String(intent.reason))
	elif String(intent.kind) == "approach" and state != "approach":
		transition_to("approach", String(intent.reason))
	elif String(intent.kind) == "retreat" and state != "recovery" and state != "retreat":
		transition_to("retreat", String(intent.reason))

	if state == "commit":
		var active_phase := String(motion_summary.get("phase", ""))
		if committed_motion_kind == "forward_surge" and active_phase == "surge":
			intent = HostileBehaviorIntentScript.new({"kind": "lunge", "reason": "forward_surge_active", "speed": profile.lunge_speed, "orbitDirection": orbit_direction})
		else:
			intent = HostileBehaviorIntentScript.new({"kind": "hold", "reason": "committed_motion_%s" % active_phase, "orbitDirection": orbit_direction})
	elif state == "evade":
		intent = HostileBehaviorIntentScript.new({"kind": "evade", "reason": "evade_active", "speed": profile.evade_speed, "orbitDirection": orbit_direction, "direction": evade_direction})
	elif state == "recovery":
		intent = HostileBehaviorIntentScript.new({"kind": "retreat", "reason": "recovery_window", "speed": profile.retreat_speed, "orbitDirection": orbit_direction})
	elif state == "probe":
		intent = HostileBehaviorIntentScript.new({"kind": "hold", "reason": "probe_pause", "orbitDirection": orbit_direction})

	last_intent = intent
	last_motor = HostileLocomotionDriverScript.step(body, target, intent, profile, delta, bounds)
	return summary()


func begin_committed_motion(motion_kind: String, body: CharacterBody3D, target: Node3D, motion_runtime) -> bool:
	if motion_runtime == null or body == null or target == null:
		return false
	motion_seed_serial += 1
	action_serial += 1
	var seed := motion_seed(motion_seed_serial)
	var started := false
	if motion_kind == "forward_surge" and profile.supports_motion("forward_surge") and motion_runtime.has_method("begin_forward_surge_motion"):
		started = bool(motion_runtime.begin_forward_surge_motion(body, target, "arena_player", profile.motion_damage, profile.visual_variant, seed, true))
	elif motion_kind == "arc" and profile.supports_motion("arc") and motion_runtime.has_method("begin_arc_motion"):
		started = bool(motion_runtime.begin_arc_motion(body, target, "arena_player", profile.motion_damage, profile.visual_variant, seed, profile.claw_plane_profile, true))
	if started:
		committed_motion_kind = motion_kind
	return started


func enter_evade(body: CharacterBody3D, target: Node3D) -> bool:
	if body == null or target == null or evade_stamina < profile.evade_stamina_cost:
		return false
	var radial := body.global_position - target.global_position
	radial.y = 0.0
	radial = radial.normalized() if radial.length_squared() > 0.0001 else Vector3.BACK
	var sign := -1.0 if hash01("evade:%d" % (action_serial + 1)) < 0.5 else 1.0
	evade_direction = (radial.rotated(Vector3.UP, sign * PI * 0.56) + radial * 0.28).normalized()
	evade_stamina = maxf(0.0, evade_stamina - profile.evade_stamina_cost)
	evade_cooldown_remaining = profile.evade_cooldown
	last_evade_reason = "executed_predicted_threat"
	return true


func player_threat(player_motion, body: CharacterBody3D) -> Dictionary:
	if player_motion == null or not is_instance_valid(player_motion) or not player_motion.has_method("threat_snapshot_for_body"):
		return {"viable": false, "reason": "player_motion_unavailable"}
	var result = player_motion.threat_snapshot_for_body(body, profile.evade_lookahead_seconds)
	var snapshot: Dictionary = result if result is Dictionary else {"viable": false, "reason": "invalid_threat_snapshot"}
	if String(snapshot.get("reason", "")) != "player_motion_inactive":
		threat_observations.append(snapshot.duplicate(true))
		if threat_observations.size() > 32:
			threat_observations.pop_front()
	return snapshot


func evade_decline_reason(motion_active: bool) -> String:
	if motion_active:
		return "committed_motion_active"
	if state == "recovery":
		return "recovery_window"
	if evade_cooldown_remaining > 0.0:
		return "cooldown"
	if evade_stamina < profile.evade_stamina_cost:
		return "insufficient_stamina"
	return "unavailable"


func transition_to(next_state: String, reason: String) -> void:
	next_state = next_state.strip_edges().to_lower()
	if next_state == state:
		return
	transitions.append({
		"from": state,
		"to": next_state,
		"reason": reason,
		"at": state_elapsed
	})
	if transitions.size() > 32:
		transitions.pop_front()
	state = next_state
	state_elapsed = 0.0
	if state == "orbit":
		orbit_direction *= -1.0 if hash01("orbit:%d" % (action_serial + transitions.size())) < 0.24 else 1.0
	if state == "recovery":
		committed_motion_kind = ""


func motion_seed(serial: int) -> int:
	return posmod(deterministic_seed + serial * 7919 + 17431, 2147483629)


func hash01(salt: String) -> float:
	var value := posmod(deterministic_seed, 2147483629)
	for index in range(salt.length()):
		value = posmod(value * 48271 + salt.unicode_at(index) + 1, 2147483629)
	return float(value) / 2147483629.0


func summary() -> Dictionary:
	return {
		"profile": profile.snapshot() if profile != null and profile.has_method("snapshot") else {},
		"state": state,
		"stateElapsed": state_elapsed,
		"actionSerial": action_serial,
		"motionSeedSerial": motion_seed_serial,
		"orbitDirection": orbit_direction,
		"committedMotionKind": committed_motion_kind,
		"evadeCooldown": evade_cooldown_remaining,
		"evadeStamina": evade_stamina,
		"lastEvadeReason": last_evade_reason,
		"intent": last_intent.snapshot() if last_intent != null and last_intent.has_method("snapshot") else {},
		"motor": last_motor.duplicate(true),
		"threat": last_threat.duplicate(true),
		"threatObservations": threat_observations.duplicate(true),
		"transitions": transitions.duplicate(true)
	}
