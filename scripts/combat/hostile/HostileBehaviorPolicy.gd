extends RefCounted
class_name HostileBehaviorPolicy

const HostileBehaviorIntentScript := preload("res://scripts/combat/hostile/HostileBehaviorIntent.gd")

## Pure decision math. Inputs are snapshots gathered by a controller; output
## is an inspectable intent and never moves a physics body itself.

static func decide(profile, facts: Dictionary):
	if profile == null:
		return intent("hold", "profile_unavailable")
	var state := String(facts.get("state", "approach"))
	var state_elapsed := maxf(0.0, float(facts.get("stateElapsed", 0.0)))
	var distance := maxf(0.0, float(facts.get("distance", INF)))
	var motion_active := bool(facts.get("motionActive", false))
	var threat := bool(facts.get("threatViable", false))
	var evade_ready := bool(facts.get("evadeReady", false))
	var orbit_direction := -1.0 if float(facts.get("orbitDirection", 1.0)) < 0.0 else 1.0
	var action_serial := int(facts.get("actionSerial", 0))

	if motion_active:
		return intent("hold", "shared_motion_active", "", 0.0, orbit_direction)
	if state == "recovery" and state_elapsed < profile.recovery_duration:
		return intent("retreat", "recovery_window", "", profile.retreat_speed, orbit_direction)
	if state == "evade" and state_elapsed < profile.evade_duration:
		return intent("evade", "evade_window", "", profile.evade_speed, orbit_direction)
	# Recovery is intentionally checked before threat. A committed wolf must
	# leave a punishable opening instead of cancelling every recovery frame.
	if threat and evade_ready:
		return intent("evade", "predicted_player_motion_threat", "", profile.evade_speed, orbit_direction)
	if distance > profile.engagement_outer_distance:
		return intent("approach", "outside_engagement_band", "", profile.approach_speed, orbit_direction)
	if distance < profile.engagement_inner_distance:
		return intent("retreat", "inside_engagement_band", "", profile.retreat_speed, orbit_direction)
	if state == "probe":
		if state_elapsed < profile.probe_duration:
			return intent("hold", "probe_pause", "", 0.0, orbit_direction)
		if distance >= profile.lunge_min_distance and distance <= profile.lunge_max_distance and profile.supports_motion("forward_surge"):
			return intent("commit", "probe_to_forward_surge", "forward_surge", profile.lunge_speed, orbit_direction)
		if distance <= profile.claw_distance and profile.supports_motion("arc"):
			return intent("commit", "probe_to_arc", "arc", 0.0, orbit_direction)
		return intent("orbit", "probe_reposition", "", profile.orbit_speed, orbit_direction)
	if state == "orbit" and state_elapsed >= profile.orbit_duration:
		return intent("probe", "orbit_complete", "", 0.0, orbit_direction)
	if state == "approach" or state == "retreat":
		return intent("orbit", "engagement_band_reached", "", profile.orbit_speed, orbit_direction)
	# An alternate deterministic first choice prevents authored timing from
	# making every seed execute the identical first committed motion.
	if state == "idle" and action_serial % 2 == 1 and distance <= profile.claw_distance and profile.supports_motion("arc"):
		return intent("commit", "seeded_idle_arc", "arc", 0.0, orbit_direction)
	return intent("orbit", "maintain_pressure", "", profile.orbit_speed, orbit_direction)


static func intent(next_kind: String, next_reason: String, motion_kind := "", speed := 0.0, orbit_direction := 1.0):
	return HostileBehaviorIntentScript.new({
		"kind": next_kind,
		"reason": next_reason,
		"motionKind": motion_kind,
		"speed": speed,
		"orbitDirection": orbit_direction
	})
