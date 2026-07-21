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
var motion_set: Array[String] = []


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
	for raw_motion in values.get("motionSet", ["arc", "forward_surge"]):
		var motion := String(raw_motion).strip_edges().to_lower()
		if not motion.is_empty() and not motion_set.has(motion):
			motion_set.append(motion)


func supports_motion(motion_kind: String) -> bool:
	return motion_set.has(motion_kind.strip_edges().to_lower())


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
		"motionSet": motion_set.duplicate()
	}
