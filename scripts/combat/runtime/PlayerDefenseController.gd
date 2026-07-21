extends RefCounted
class_name PlayerDefenseController

## Pure timing/eligibility state for player defense. The PlayerController keeps
## movement, collision and terrain-publication authority; this object merely
## decides whether that controller may apply a short dodge vector.

const DODGE_STAMINA_COST := 18.0
const DODGE_DURATION_SECONDS := 0.24
const DODGE_COOLDOWN_SECONDS := 0.58
const DODGE_SPEED := 18.5

var active_remaining := 0.0
var cooldown_remaining := 0.0
var direction := Vector3.ZERO
var last_reason := "ready"
var dodge_serial := 0


func advance(delta: float) -> void:
	active_remaining = maxf(0.0, active_remaining - maxf(0.0, delta))
	cooldown_remaining = maxf(0.0, cooldown_remaining - maxf(0.0, delta))
	if active_remaining <= 0.0 and last_reason == "active":
		last_reason = "recovery"


func request(survival, requested_direction: Vector3, can_enter: bool) -> bool:
	if is_active():
		last_reason = "already_active"
		return false
	if cooldown_remaining > 0.0:
		last_reason = "cooldown"
		return false
	if not can_enter:
		last_reason = "terrain_unready"
		return false
	if requested_direction.length_squared() <= 0.0001:
		last_reason = "invalid_direction"
		return false
	if survival == null or not survival.has_method("try_spend_stamina"):
		last_reason = "survival_unavailable"
		return false
	if not bool(survival.try_spend_stamina(DODGE_STAMINA_COST, "Dodge")):
		last_reason = "insufficient_stamina"
		return false
	direction = requested_direction.normalized()
	active_remaining = DODGE_DURATION_SECONDS
	cooldown_remaining = DODGE_COOLDOWN_SECONDS
	dodge_serial += 1
	last_reason = "active"
	return true


func is_active() -> bool:
	return active_remaining > 0.0 and direction.length_squared() > 0.0001


func clear_transient_state() -> void:
	active_remaining = 0.0
	cooldown_remaining = 0.0
	direction = Vector3.ZERO
	last_reason = "ready"


func summary() -> Dictionary:
	return {
		"active": is_active(),
		"remaining": active_remaining,
		"cooldown": cooldown_remaining,
		"direction": direction,
		"lastReason": last_reason,
		"serial": dodge_serial,
		"staminaCost": DODGE_STAMINA_COST
	}
