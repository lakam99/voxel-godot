extends RefCounted
class_name HostileBehaviorProfile

## Immutable, data-only description of a combat creature's behavioral
## affordances. A profile selects shared systems; it never owns a body, scene,
## transform, contact result, renderer, or damage implementation.

var id := ""
var display_name := "Hostile"
var visual_variant := "shadow"
var max_health := 24.0
var preferred_distance := 3.8
var engagement_inner_distance := 2.35
var engagement_outer_distance := 5.25
var claw_distance := 2.9
var lunge_min_distance := 3.1
var lunge_max_distance := 5.6
var approach_speed := 4.1
var orbit_speed := 3.65
var retreat_speed := 3.85
var lunge_speed := 9.4
var evade_speed := 10.6
var orbit_duration := 1.45
var probe_duration := 0.42
var recovery_duration := 0.84
var evade_duration := 0.28
var evade_cooldown := 1.55
var evade_stamina_cost := 26.0
var evade_stamina_max := 100.0
var evade_stamina_regen := 22.0
var evade_lookahead_seconds := 0.18
var motion_damage := 14.0
var claw_plane_profile := "lateral"
var facing_mode := "movement"
var gaze_mode := "target"
var motion_set: Array[String] = []
var motion_combos: Dictionary = {}


func _init(values: Dictionary = {}) -> void:
	id = String(values.get("id", id)).strip_edges().to_lower()
	display_name = String(values.get("displayName", display_name))
	visual_variant = String(values.get("visualVariant", visual_variant)).strip_edges().to_lower()
	max_health = maxf(1.0, float(values.get("maxHealth", max_health)))
	preferred_distance = maxf(0.5, float(values.get("preferredDistance", preferred_distance)))
	engagement_inner_distance = clampf(float(values.get("engagementInnerDistance", engagement_inner_distance)), 0.2, preferred_distance)
	engagement_outer_distance = maxf(preferred_distance + 0.15, float(values.get("engagementOuterDistance", engagement_outer_distance)))
	claw_distance = clampf(float(values.get("clawDistance", claw_distance)), engagement_inner_distance, engagement_outer_distance)
	lunge_min_distance = clampf(float(values.get("lungeMinDistance", lunge_min_distance)), engagement_inner_distance, engagement_outer_distance)
	lunge_max_distance = clampf(float(values.get("lungeMaxDistance", lunge_max_distance)), lunge_min_distance, engagement_outer_distance + 2.0)
	approach_speed = maxf(0.1, float(values.get("approachSpeed", approach_speed)))
	orbit_speed = maxf(0.1, float(values.get("orbitSpeed", orbit_speed)))
	retreat_speed = maxf(0.1, float(values.get("retreatSpeed", retreat_speed)))
	lunge_speed = maxf(0.1, float(values.get("lungeSpeed", lunge_speed)))
	evade_speed = maxf(0.1, float(values.get("evadeSpeed", evade_speed)))
	orbit_duration = maxf(0.05, float(values.get("orbitDuration", orbit_duration)))
	probe_duration = maxf(0.05, float(values.get("probeDuration", probe_duration)))
	recovery_duration = maxf(0.05, float(values.get("recoveryDuration", recovery_duration)))
	evade_duration = maxf(0.05, float(values.get("evadeDuration", evade_duration)))
	evade_cooldown = maxf(0.0, float(values.get("evadeCooldown", evade_cooldown)))
	evade_stamina_cost = maxf(0.0, float(values.get("evadeStaminaCost", evade_stamina_cost)))
	evade_stamina_max = maxf(evade_stamina_cost, float(values.get("evadeStaminaMax", evade_stamina_max)))
	evade_stamina_regen = maxf(0.0, float(values.get("evadeStaminaRegen", evade_stamina_regen)))
	evade_lookahead_seconds = clampf(float(values.get("evadeLookaheadSeconds", evade_lookahead_seconds)), 0.02, 0.5)
	motion_damage = maxf(0.0, float(values.get("motionDamage", motion_damage)))
	claw_plane_profile = String(values.get("clawPlaneProfile", claw_plane_profile)).strip_edges().to_lower()
	facing_mode = String(values.get("facingMode", facing_mode)).strip_edges().to_lower()
	if facing_mode not in ["movement", "target"]:
		facing_mode = "movement"
	gaze_mode = String(values.get("gazeMode", gaze_mode)).strip_edges().to_lower()
	if gaze_mode not in ["movement", "target"]:
		gaze_mode = "target"
	for raw_motion in values.get("motionSet", ["arc", "forward_surge"]):
		var motion := String(raw_motion).strip_edges().to_lower()
		if not motion.is_empty() and not motion_set.has(motion):
			motion_set.append(motion)
	var raw_combos: Dictionary = values.get("motionCombos", {}) as Dictionary
	for raw_trigger in raw_combos.keys():
		var trigger := String(raw_trigger).strip_edges().to_lower()
		var raw_steps = raw_combos.get(raw_trigger, [])
		if trigger.is_empty() or not raw_steps is Array:
			continue
		var steps: Array = []
		for raw_step in raw_steps as Array:
			if not raw_step is Dictionary:
				continue
			var source: Dictionary = raw_step as Dictionary
			var motion_kind := String(source.get("motionKind", "")).strip_edges().to_lower()
			if not supports_motion(motion_kind):
				continue
			var side := float(source.get("side", 0.0))
			var vertical_direction := String(source.get("verticalDirection", "")).strip_edges().to_lower()
			if vertical_direction not in ["", "up", "down"]:
				vertical_direction = ""
			# A motion remains body-neutral.  A profile can separately declare a
			# normal locomotion intent for a named motion phase, which lets wind-up
			# and movement overlap without introducing a family-specific animation.
			var locomotion_kind := String(source.get("locomotionKind", "")).strip_edges().to_lower()
			if locomotion_kind not in ["", "approach", "lunge", "retreat", "orbit"]:
				locomotion_kind = ""
			var locomotion_phases: Array[String] = []
			if not locomotion_kind.is_empty():
				for raw_phase in source.get("locomotionPhases", []):
					var phase := String(raw_phase).strip_edges().to_lower()
					if phase in ["windup", "arc", "surge", "recovery"] and not locomotion_phases.has(phase):
						locomotion_phases.append(phase)
			var pose_roles: Array[String] = []
			for raw_role in source.get("poseRoles", []):
				var role := String(raw_role).strip_edges().to_lower()
				if not role.is_empty() and not pose_roles.has(role):
					pose_roles.append(role)
			steps.append({
				"motionKind": motion_kind,
				# A nonzero side selects an anatomical lead limb through the shared
				# rig profile. Zero preserves the recipe's seeded side selection.
				"side": -1.0 if side < -0.001 else (1.0 if side > 0.001 else 0.0),
				"planeProfile": String(source.get("planeProfile", claw_plane_profile)).strip_edges().to_lower(),
				"verticalDirection": vertical_direction,
				"locomotionKind": locomotion_kind,
				"locomotionPhases": locomotion_phases,
				"poseRoles": pose_roles,
				"showTelegraph": bool(source.get("showTelegraph", true))
			})
		if not steps.is_empty():
			motion_combos[trigger] = steps


func supports_motion(motion_kind: String) -> bool:
	return motion_set.has(motion_kind.strip_edges().to_lower())


func combo_steps(trigger_motion: String) -> Array:
	var trigger := trigger_motion.strip_edges().to_lower()
	var steps: Array = motion_combos.get(trigger, []) as Array
	return steps.duplicate(true)


func snapshot() -> Dictionary:
	return {
		"id": id,
		"displayName": display_name,
		"visualVariant": visual_variant,
		"maxHealth": max_health,
		"preferredDistance": preferred_distance,
		"engagementInnerDistance": engagement_inner_distance,
		"engagementOuterDistance": engagement_outer_distance,
		"clawDistance": claw_distance,
		"lungeMinDistance": lunge_min_distance,
		"lungeMaxDistance": lunge_max_distance,
		"approachSpeed": approach_speed,
		"orbitSpeed": orbit_speed,
		"retreatSpeed": retreat_speed,
		"lungeSpeed": lunge_speed,
		"evadeSpeed": evade_speed,
		"orbitDuration": orbit_duration,
		"probeDuration": probe_duration,
		"recoveryDuration": recovery_duration,
		"evadeDuration": evade_duration,
		"evadeCooldown": evade_cooldown,
		"evadeStaminaCost": evade_stamina_cost,
		"evadeStaminaMax": evade_stamina_max,
		"evadeStaminaRegen": evade_stamina_regen,
		"evadeLookaheadSeconds": evade_lookahead_seconds,
		"motionDamage": motion_damage,
		"clawPlaneProfile": claw_plane_profile,
		"facingMode": facing_mode,
		"gazeMode": gaze_mode,
		"motionSet": motion_set.duplicate(),
		"motionCombos": motion_combos.duplicate(true)
	}
