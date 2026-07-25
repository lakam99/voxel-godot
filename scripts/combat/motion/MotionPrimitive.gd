extends RefCounted
class_name MotionPrimitive

const MotionSampleScript := preload("res://scripts/combat/motion/MotionSample.gd")

## Stateless mathematical primitives. New motions belong here only when their
## kinematic rule is truly reusable; "claw", "sword", and "attack" are not
## primitive names.

static func sample(recipe, local_time: float, direction := 1.0, origin := Vector3.ZERO, instance_id := "", anchor_id := "") -> MotionSample:
	if recipe == null or not ["side_arc_motion", "arc_motion", "forward_surge_motion"].has(String(recipe.primitive_id)):
		return MotionSampleScript.new({
			"instanceId": instance_id,
			"anchorId": anchor_id,
			"localTime": local_time,
			"origin": origin
		})
	return sample_forward_surge(recipe, local_time, direction, origin, instance_id, anchor_id) if String(recipe.primitive_id) == "forward_surge_motion" else sample_arc(recipe, local_time, direction, origin, instance_id, anchor_id)


static func sample_side_arc(recipe, local_time: float, direction: float, origin: Vector3, instance_id: String, anchor_id: String) -> MotionSample:
	return sample_arc(recipe, local_time, direction, origin, instance_id, anchor_id)


static func sample_arc(recipe, local_time: float, direction: float, origin: Vector3, instance_id: String, anchor_id: String) -> MotionSample:
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
	# A generic arc is a great-circle sweep in a deterministic local plane. The
	# legacy side arc has zero central pitch and uses attackPlaneTiltDegrees as
	# its roll, so its old trajectory remains unchanged. Multi-plane recipes only
	# vary those two numbers; nothing here knows a weapon, actor, or attack type.
	var central_pitch := deg_to_rad(float(parameters.get("centralPitchDegrees", 0.0)))
	var plane_forward := Vector3.FORWARD.rotated(Vector3.RIGHT, central_pitch).normalized()
	var plane_tilt := deg_to_rad(float(parameters.get("sweepRollDegrees", parameters.get("attackPlaneTiltDegrees", 0.0))))
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
		"direction": signed_direction,
		"origin": origin,
		"tip": tip,
		"facing": facing
	})


static func sample_forward_surge(recipe, local_time: float, direction: float, origin: Vector3, instance_id: String, anchor_id: String) -> MotionSample:
	var t := clampf(local_time, 0.0, 1.0)
	var parameters: Dictionary = recipe.parameters
	var windup := float(parameters.get("windupFraction", 0.27))
	var strike := float(parameters.get("strikeFraction", 0.34))
	var strike_end := windup + strike
	var reach := float(parameters.get("reach", 3.4))
	var depth := 0.0
	var lift := 0.0
	var phase := "recovery"
	if t < windup:
		var progress := ease(clampf(t / maxf(windup, 0.001), 0.0, 1.0), 0.58)
		depth = -reach * lerpf(0.04, 0.24, progress)
		lift = -0.08 * sin(progress * PI)
		phase = "windup"
	elif t < strike_end:
		var progress := ease(clampf((t - windup) / maxf(strike, 0.001), 0.0, 1.0), -1.75)
		depth = lerpf(-reach * 0.24, reach, progress)
		lift = sin(progress * PI) * float(parameters.get("verticalLift", 0.1))
		phase = "surge"
	else:
		var recovery := clampf((t - strike_end) / maxf(1.0 - strike_end, 0.001), 0.0, 1.0)
		depth = lerpf(reach, reach * 0.18, ease(recovery, 0.72))
		lift = lerpf(0.0, 0.04, recovery)
		phase = "recovery"
	var signed_direction := -1.0 if direction < 0.0 else 1.0
	var lateral := Vector3.RIGHT * signed_direction * sin(t * PI) * reach * 0.045
	var motion_origin := origin + Vector3.UP * float(parameters.get("startHeight", 0.7))
	var tip := motion_origin + Vector3.FORWARD * depth + lateral + Vector3.UP * lift
	var facing := (tip - origin).normalized()
	return MotionSampleScript.new({
		"instanceId": instance_id,
		"anchorId": anchor_id,
		"localTime": t,
		"phase": phase,
		"active": true,
		"direction": signed_direction,
		"origin": origin,
		"tip": tip,
		"facing": facing
	})
