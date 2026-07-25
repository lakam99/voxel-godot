extends RefCounted
class_name MotionPoseSignal

const MotionRigProfileScript := preload("res://scripts/combat/rig/MotionRigProfile.gd")

## One body-neutral request derived from a shared motion sample. This is data
## only: a visual body may consume it, reject it by capability, or inspect it.

var instance_id := ""
var primitive_id := ""
var phase := "inactive"
var normalized_time := 0.0
var side := 1.0
var local_direction := Vector3.FORWARD
var motion_direction := Vector3.FORWARD
var limb_direction := Vector3.FORWARD
var motion_alignment := 0.0
var vertical_bias := 0.0
var role_weights: Dictionary = {}
var required_roles: Array[String] = []


func _init(values: Dictionary = {}) -> void:
	instance_id = String(values.get("instanceId", ""))
	primitive_id = String(values.get("primitiveId", "")).strip_edges().to_lower()
	phase = String(values.get("phase", "inactive")).strip_edges().to_lower()
	normalized_time = clampf(float(values.get("normalizedTime", 0.0)), 0.0, 1.0)
	side = -1.0 if float(values.get("side", 1.0)) < 0.0 else 1.0
	local_direction = values.get("localDirection", Vector3.FORWARD) as Vector3
	if local_direction.length_squared() <= 0.000001:
		local_direction = Vector3.FORWARD
	else:
		local_direction = local_direction.normalized()
	motion_direction = values.get("motionDirection", local_direction) as Vector3
	if motion_direction.length_squared() <= 0.000001:
		motion_direction = local_direction
	else:
		motion_direction = motion_direction.normalized()
	# An arm and held item point from their socket to the motion endpoint. That
	# is distinct from the path tangent retained above for motion presentation.
	limb_direction = values.get("limbDirection", local_direction) as Vector3
	if limb_direction.length_squared() <= 0.000001:
		limb_direction = local_direction
	else:
		limb_direction = limb_direction.normalized()
	motion_alignment = clampf(float(values.get("motionAlignment", 0.0)), 0.0, 1.0)
	vertical_bias = clampf(float(values.get("verticalBias", 0.0)), -1.0, 1.0)
	role_weights = (values.get("roleWeights", {}) as Dictionary).duplicate(true)
	for raw_role in values.get("requiredRoles", MotionRigProfileScript.CORE_REQUIREMENTS):
		var role := String(raw_role).strip_edges().to_lower()
		if not role.is_empty() and not required_roles.has(role):
			required_roles.append(role)


func weight_for(role: String) -> float:
	return clampf(float(role_weights.get(role, 0.0)), -1.0, 1.0)


func snapshot() -> Dictionary:
	return {
		"instanceId": instance_id,
		"primitiveId": primitive_id,
		"phase": phase,
		"normalizedTime": normalized_time,
		"side": side,
		"localDirection": local_direction,
		"motionDirection": motion_direction,
		"limbDirection": limb_direction,
		"motionAlignment": motion_alignment,
		"verticalBias": vertical_bias,
		"roleWeights": role_weights.duplicate(true),
		"requiredRoles": required_roles.duplicate()
	}
