extends RefCounted
class_name MotionPrimitive

const MotionSampleScript := preload("res://scripts/combat/motion/MotionSample.gd")

## Stateless mathematical primitives. New motions belong here only when their
## kinematic rule is truly reusable; "claw", "sword", and "attack" are not
## primitive names.

static func sample(recipe, local_time: float, direction := 1.0, origin := Vector3.ZERO, instance_id := "", anchor_id := "") -> MotionSample:
	if recipe == null or String(recipe.primitive_id) != "side_arc_motion":
		return MotionSampleScript.new({
			"instanceId": instance_id,
			"anchorId": anchor_id,
			"localTime": local_time,
			"origin": origin
		})
	return sample_side_arc(recipe, local_time, direction, origin, instance_id, anchor_id)


static func sample_side_arc(recipe, local_time: float, direction: float, origin: Vector3, instance_id: String, anchor_id: String) -> MotionSample:
	var t := clampf(local_time, 0.0, 1.0)
	var parameters: Dictionary = recipe.parameters
	var windup := float(parameters.get("windupFraction", 0.25))
	var strike := float(parameters.get("strikeFraction", 0.40))
	var strike_end := windup + strike
	var arc_half := deg_to_rad(float(parameters.get("arcDegrees", 126.0)) * 0.5)
	var signed_direction := -1.0 if direction < 0.0 else 1.0
	var yaw := 0.0
	var lift := 0.0
	var phase := "recovery"
	if t < windup:
		var progress := ease(clampf(t / maxf(windup, 0.001), 0.0, 1.0), 0.55)
		yaw = lerpf(0.0, -signed_direction * arc_half * 1.18, progress)
		lift = -0.12 * sin(progress * PI)
		phase = "windup"
	elif t < strike_end:
		var progress := ease(clampf((t - windup) / maxf(strike, 0.001), 0.0, 1.0), -1.85)
		yaw = lerpf(-signed_direction * arc_half * 1.18, signed_direction * arc_half, progress)
		lift = sin(progress * PI) * float(parameters.get("verticalLift", 0.50))
		phase = "arc"
	else:
		var recovery := clampf((t - strike_end) / maxf(1.0 - strike_end, 0.001), 0.0, 1.0)
		yaw = lerpf(signed_direction * arc_half, signed_direction * arc_half * 0.16, ease(recovery, 0.68))
		lift = lerpf(0.0, 0.06, recovery)
		phase = "recovery"
	var reach := float(parameters.get("reach", 3.0))
	# A side arc starts as a horizontal sweep, then rotates around its forward
	# axis into the recipe's deterministic attack plane. This is still one
	# generic side-arc formula: no weapon, creature, or authored animation data
	# participates in the result.
	var plane_forward := Vector3.FORWARD
	var plane_tilt := deg_to_rad(float(parameters.get("attackPlaneTiltDegrees", 0.0)))
	var plane_side := Vector3.RIGHT.rotated(plane_forward, plane_tilt).normalized()
	var plane_up := plane_side.cross(plane_forward).normalized()
	var arc_center := origin + Vector3.UP * float(parameters.get("startHeight", 0.90))
	var tip := arc_center + plane_side * sin(yaw) * reach + plane_forward * cos(yaw) * reach + plane_up * lift
	var facing := (tip - origin).normalized()
	return MotionSampleScript.new({
		"instanceId": instance_id,
		"anchorId": anchor_id,
		"localTime": t,
		"phase": phase,
		"active": true,
		"origin": origin,
		"tip": tip,
		"facing": facing
	})
