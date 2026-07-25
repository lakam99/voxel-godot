extends RefCounted
class_name MotionPoseSolver

## Pure conversion from semantic signals to per-bone local rotation offsets.
## The solver receives a body profile but never sees a CharacterBody3D, scene,
## collision shape, target, or combat result.

static func solve(profile, signals: Array) -> Dictionary:
	var contributions: Dictionary = {}
	var rejected: Array[String] = []
	if profile == null:
		return {"contributions": contributions, "rejected": ["missing MotionRigProfile"]}
	for pose_signal in signals:
		if pose_signal == null:
			continue
		var missing := missing_requirements(profile, pose_signal.required_roles)
		if not missing.is_empty():
			rejected.append("%s rejected: %s" % [pose_signal.instance_id, ", ".join(missing)])
			continue
		for requirement in pose_signal.role_weights.keys():
			var semantic_role := String(requirement)
			var resolved_role: String = String(profile.resolved_role(semantic_role, pose_signal.side))
			for binding in profile.bindings_for(resolved_role):
				accumulate(contributions, binding as Dictionary, pose_signal.weight_for(semantic_role), pose_signal)
	finalize_motion_alignments(contributions)
	return {"contributions": contributions, "rejected": rejected}


static func missing_requirements(profile, requirements: Array[String]) -> Array[String]:
	var result: Array[String] = []
	for requirement in requirements:
		var role := String(requirement)
		if not profile.supports_requirement(role):
			result.append(role)
	return result


static func accumulate(contributions: Dictionary, binding: Dictionary, semantic_weight: float, pose_signal) -> void:
	var bone := String(binding.get("bone", ""))
	var motion_alignment: float = float(pose_signal.motion_alignment) if bool(binding.get("motionAlign", false)) else 0.0
	if bone.is_empty() or (is_zero_approx(semantic_weight) and is_zero_approx(motion_alignment)):
		return
	var axis: Vector3 = binding.get("axis", Vector3.RIGHT) as Vector3
	var degrees := float(binding.get("maxDegrees", 0.0)) * float(binding.get("weight", 1.0)) * float(binding.get("sign", 1.0)) * semantic_weight
	var entry: Dictionary = contributions.get(bone, {"rotationDegrees": Vector3.ZERO, "contributors": [], "motionAlignmentDirection": Vector3.ZERO, "motionAlignmentWeight": 0.0, "motionAlignmentRestDirection": Vector3.DOWN}) as Dictionary
	entry["rotationDegrees"] = (entry.get("rotationDegrees", Vector3.ZERO) as Vector3) + axis * degrees
	var source_ids: Array = entry.get("contributors", []) as Array
	if not source_ids.has(pose_signal.instance_id):
		source_ids.append(pose_signal.instance_id)
	entry["contributors"] = source_ids
	if motion_alignment > 0.0:
		# Use the shared endpoint ray for an articulated limb. The path tangent
		# would force the arena to turn a target-facing body sideways merely to
		# make its item cross the player.
		entry["motionAlignmentDirection"] = (entry.get("motionAlignmentDirection", Vector3.ZERO) as Vector3) + pose_signal.limb_direction * motion_alignment
		entry["motionAlignmentWeight"] = maxf(float(entry.get("motionAlignmentWeight", 0.0)), motion_alignment)
		entry["motionAlignmentRestDirection"] = binding.get("restDirection", Vector3.DOWN) as Vector3
	contributions[bone] = entry


static func finalize_motion_alignments(contributions: Dictionary) -> void:
	for bone_name in contributions.keys():
		var entry: Dictionary = contributions.get(bone_name, {}) as Dictionary
		var direction: Vector3 = entry.get("motionAlignmentDirection", Vector3.ZERO) as Vector3
		if direction.length_squared() > 0.000001:
			entry["motionAlignmentDirection"] = direction.normalized()
		contributions[bone_name] = entry
