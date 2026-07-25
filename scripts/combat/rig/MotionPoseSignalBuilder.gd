extends RefCounted
class_name MotionPoseSignalBuilder

const MotionPoseSignalScript := preload("res://scripts/combat/rig/MotionPoseSignal.gd")
const MotionRigProfileScript := preload("res://scripts/combat/rig/MotionRigProfile.gd")

## Converts the shared mathematical motion output into semantic pose requests.
## It deliberately depends only on MotionStack data; rigs and body nodes live
## on the other side of this boundary.

static func build_for_stack(stack, normalized_time: float) -> Array:
	var result: Array = []
	if stack == null or not stack.has_method("samples_at"):
		return result
	var recipes_by_instance: Dictionary = {}
	for instance in stack.instances:
		if instance != null:
			recipes_by_instance[String(instance.instance_id)] = instance.recipe
	for sample in stack.samples_at(normalized_time):
		if sample == null or not sample.active:
			continue
		var recipe = recipes_by_instance.get(String(sample.instance_id), null)
		if recipe == null:
			continue
		result.append(build_from_sample(sample, recipe))
	return result


static func build_from_sample(sample, recipe):
	var primitive_id := String(recipe.primitive_id).strip_edges().to_lower()
	var phase := String(sample.phase).strip_edges().to_lower()
	# Motion origin is a world/presentation anchor. A limb instead pivots from
	# the primitive's centre height, avoiding a false upward arm bias.
	var limb_direction: Vector3 = sample.tip - limb_origin_for(sample, recipe)
	if limb_direction.length_squared() <= 0.000001:
		limb_direction = Vector3.FORWARD
	else:
		limb_direction = limb_direction.normalized()
	var local_direction := limb_direction
	local_direction.y = 0.0
	if local_direction.length_squared() <= 0.000001:
		local_direction = Vector3.FORWARD
	else:
		local_direction = local_direction.normalized()
	var vertical_span: float = sample.tip.y - sample.origin.y
	var reach := maxf(0.001, float(recipe.parameters.get("reach", 1.0)))
	var role_weights := role_weights_for(primitive_id, phase, sample.local_time, sample.direction)
	var motion_direction := sweep_axis_direction_for(sample, recipe)
	if motion_direction.length_squared() <= 0.000001:
		motion_direction = local_direction
	return MotionPoseSignalScript.new({
		"instanceId": sample.instance_id,
		"primitiveId": primitive_id,
		"phase": phase,
		"normalizedTime": sample.normalized_time,
		"side": sample.direction,
		"localDirection": local_direction,
		"motionDirection": motion_direction,
		"limbDirection": limb_direction,
		"motionAlignment": motion_alignment_for(phase, sample.local_time),
		"verticalBias": clampf(vertical_span / reach, -1.0, 1.0),
		"roleWeights": role_weights,
		"requiredRoles": MotionRigProfileScript.CORE_REQUIREMENTS
	})


static func limb_origin_for(sample, recipe) -> Vector3:
	var primitive_id := String(recipe.primitive_id).strip_edges().to_lower()
	if primitive_id in ["arc_motion", "side_arc_motion", "forward_surge_motion"]:
		return sample.origin + Vector3.UP * float(recipe.parameters.get("startHeight", 0.0))
	return sample.origin


static func sweep_axis_direction_for(sample, recipe) -> Vector3:
	# The arm follows the path's geometric sweep axis, not the finite-difference
	# velocity. The authored phases intentionally change their velocity to wind
	# up, strike, and recover, so a velocity tangent can have a cusp at those
	# joins. The analytic tangent below is perpendicular to the current radial
	# point in the recipe plane and remains continuous through every phase.
	var primitive_id := String(recipe.primitive_id).strip_edges().to_lower()
	if primitive_id in ["arc_motion", "side_arc_motion"]:
		var parameters: Dictionary = recipe.parameters
		var central_pitch := deg_to_rad(float(parameters.get("centralPitchDegrees", 0.0)))
		var plane_forward := Vector3.FORWARD.rotated(Vector3.RIGHT, central_pitch).normalized()
		var plane_tilt := deg_to_rad(float(parameters.get("sweepRollDegrees", parameters.get("attackPlaneTiltDegrees", 0.0))))
		var plane_side := Vector3.RIGHT.rotated(plane_forward, plane_tilt).normalized()
		var plane_up := plane_side.cross(plane_forward).normalized()
		var arc_center: Vector3 = sample.origin + Vector3.UP * float(parameters.get("startHeight", 0.90))
		var radial: Vector3 = sample.tip - arc_center
		var tangent: Vector3 = radial.cross(plane_up) * sample.direction
		if tangent.length_squared() > 0.000001:
			return tangent.normalized()
	if primitive_id == "forward_surge_motion":
		return Vector3.FORWARD
	return sample.facing.normalized()


static func role_weights_for(primitive_id: String, phase: String, local_time: float, side: float) -> Dictionary:
	var side_sign := -1.0 if side < 0.0 else 1.0
	var windup := phase_progress(phase, local_time, true)
	var execution := phase_progress(phase, local_time, false)
	var recovery := recovery_progress(phase, local_time)
	if primitive_id == "forward_surge_motion":
		return {
			"root": -0.26 * windup + 0.16 * execution,
			"torso": -0.72 * windup + 0.58 * execution - 0.20 * recovery,
			"lead_appendage": -0.66 * windup + 0.94 * execution - 0.18 * recovery,
			"counterbalance": 0.42 * windup - 0.30 * execution + 0.12 * recovery,
			"gaze": side_sign * (0.12 * windup + 0.20 * execution)
		}
	return {
		"root": side_sign * (-0.24 * windup + 0.17 * execution - 0.04 * recovery),
		"torso": side_sign * (-0.72 * windup + 0.98 * execution - 0.24 * recovery),
		"lead_appendage": side_sign * (-0.64 * windup + 1.0 * execution - 0.18 * recovery),
		"counterbalance": side_sign * (0.46 * windup - 0.52 * execution + 0.16 * recovery),
		"gaze": side_sign * (0.10 * windup + 0.22 * execution - 0.04 * recovery)
	}


static func phase_progress(phase: String, local_time: float, wants_windup: bool) -> float:
	if wants_windup:
		if phase == "windup":
			return ease(clampf(local_time / 0.25, 0.0, 1.0), 0.58)
		return 1.0 if phase in ["arc", "surge"] else 0.0
	if phase in ["arc", "surge"]:
		return ease(clampf((local_time - 0.25) / 0.40, 0.0, 1.0), -1.75)
	return 0.0


static func recovery_progress(phase: String, local_time: float) -> float:
	if phase != "recovery":
		return 0.0
	return ease(clampf((local_time - 0.65) / 0.35, 0.0, 1.0), 0.72)


static func motion_alignment_for(phase: String, local_time: float) -> float:
	# A limb which opts into directional alignment joins the wind-up smoothly,
	# tracks the exact sampled vector throughout execution, then releases during
	# recovery. This is motion timing, not a body- or weapon-specific curve.
	if phase == "windup":
		return ease(clampf(local_time / 0.25, 0.0, 1.0), 0.58)
	if phase in ["arc", "surge"]:
		return 1.0
	if phase == "recovery":
		return 1.0 - ease(clampf((local_time - 0.65) / 0.35, 0.0, 1.0), 0.72)
	return 0.0
