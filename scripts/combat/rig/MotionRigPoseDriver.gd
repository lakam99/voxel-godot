extends Node
class_name MotionRigPoseDriver

const MotionPoseSolverScript := preload("res://scripts/combat/rig/MotionPoseSolver.gd")

## Visual-only receiver for the shared runtime's semantic motion output. It
## owns bone pose offsets; the parent body remains authoritative for movement,
## collision, targeting and combat state.

var profile
var skeleton: Skeleton3D
var validation: Dictionary = {}
var last_solution: Dictionary = {"contributions": {}, "rejected": []}
var bound_runtime: Node
var controlled_bones: Dictionary = {}
var locomotion_phase := 0.0
var locomotion_weight := 0.0
var locomotion_rotations: Dictionary = {}
var gaze_rotations: Dictionary = {}


func configure(next_profile, next_skeleton: Skeleton3D) -> Dictionary:
	profile = next_profile
	skeleton = next_skeleton
	validation = profile.validate(skeleton) if profile != null else {"valid": false, "errors": ["missing MotionRigProfile"]}
	controlled_bones.clear()
	if bool(validation.get("valid", false)) and profile != null and skeleton != null:
		for role in profile.role_bindings.keys():
			for binding in profile.bindings_for(String(role)):
				var index := skeleton.find_bone(String((binding as Dictionary).get("bone", "")))
				if index >= 0:
					controlled_bones[index] = true
		reset_pose()
	return validation.duplicate(true)


func bind_motion_runtime(runtime: Node) -> void:
	if bound_runtime != null and is_instance_valid(bound_runtime):
		if bound_runtime.has_signal("motion_pose_signals") and bound_runtime.motion_pose_signals.is_connected(_on_motion_pose_signals):
			bound_runtime.motion_pose_signals.disconnect(_on_motion_pose_signals)
		if bound_runtime.has_signal("motion_finished") and bound_runtime.motion_finished.is_connected(_on_motion_finished):
			bound_runtime.motion_finished.disconnect(_on_motion_finished)
	bound_runtime = runtime
	if bound_runtime == null or not is_instance_valid(bound_runtime):
		return
	if bound_runtime.has_signal("motion_pose_signals"):
		bound_runtime.motion_pose_signals.connect(_on_motion_pose_signals)
	if bound_runtime.has_signal("motion_finished"):
		bound_runtime.motion_finished.connect(_on_motion_finished)


func _exit_tree() -> void:
	bind_motion_runtime(null)


func _on_motion_pose_signals(source_body, signals: Array, _summary: Dictionary) -> void:
	if source_body != get_parent():
		return
	apply_signals(signals)


func _on_motion_finished(source_body, _summary: Dictionary) -> void:
	if source_body == get_parent():
		last_solution = {"contributions": {}, "rejected": []}
		apply_combined_pose()


func apply_signals(signals: Array) -> Dictionary:
	if not bool(validation.get("valid", false)) or skeleton == null or not is_instance_valid(skeleton):
		return {"contributions": {}, "rejected": ["invalid rig profile"]}
	last_solution = MotionPoseSolverScript.solve(profile, signals)
	apply_combined_pose()
	return last_solution.duplicate(true)


func apply_locomotion_velocity(world_velocity: Vector3, delta: float) -> void:
	# Locomotion is a purely visual overlay sourced from the same actual velocity
	# that the collision-backed CharacterBody3D just applied. It never changes
	# transforms, navigation, hit timing or the motion recipe.
	if not bool(validation.get("valid", false)) or profile == null or skeleton == null or not is_instance_valid(skeleton):
		return
	var config: Dictionary = profile.metadata.get("locomotion", {}) as Dictionary
	if config.is_empty():
		return
	var horizontal_speed := Vector2(world_velocity.x, world_velocity.z).length()
	var reference_speed := maxf(0.1, float(config.get("referenceSpeed", 4.0)))
	var target_weight := clampf(horizontal_speed / reference_speed, 0.0, 1.0)
	var blend_rate := maxf(1.0, float(config.get("blendRate", 10.0)))
	locomotion_weight = move_toward(locomotion_weight, target_weight, blend_rate * maxf(0.0, delta))
	if target_weight > 0.01:
		var stride_frequency := maxf(0.1, float(config.get("strideFrequency", 5.0)))
		locomotion_phase = fposmod(locomotion_phase + delta * stride_frequency * TAU * lerpf(0.35, 1.0, target_weight), TAU)
	locomotion_rotations = locomotion_rotation_map(config)
	apply_combined_pose()


func apply_gaze_target(target_position: Vector3, delta: float) -> void:
	# A declared gaze layer allows a circling creature to keep its collision body
	# facing real travel while its head watches the target. This is a semantic rig
	# presentation feature; it never writes the parent transform or steering.
	if not bool(validation.get("valid", false)) or profile == null or skeleton == null or not is_instance_valid(skeleton):
		return
	var config: Dictionary = profile.metadata.get("gazeTracking", {}) as Dictionary
	if config.is_empty():
		return
	var body := get_parent() as Node3D
	if body == null or not is_instance_valid(body):
		return
	var local_target := body.global_transform.basis.orthonormalized().inverse() * (target_position - body.global_position)
	local_target.y = 0.0
	if local_target.length_squared() <= 0.000001:
		return
	apply_gaze_local_direction(local_target, delta, config)


func apply_gaze_direction(world_direction: Vector3, delta: float) -> void:
	# Movement-facing locomotion can deliberately release target tracking for a
	# retreat. The collision body owns its heading, so returning the head to the
	# same world direction makes the full creature read as moving away instead of
	# snapping its head back toward the player. This is a generic rig operation;
	# it does not encode a creature or action-specific exception.
	if not bool(validation.get("valid", false)) or profile == null or skeleton == null or not is_instance_valid(skeleton):
		return
	var config: Dictionary = profile.metadata.get("gazeTracking", {}) as Dictionary
	if config.is_empty() or world_direction.length_squared() <= 0.000001:
		return
	var body := get_parent() as Node3D
	if body == null or not is_instance_valid(body):
		return
	var local_direction := body.global_transform.basis.orthonormalized().inverse() * world_direction.normalized()
	local_direction.y = 0.0
	if local_direction.length_squared() <= 0.000001:
		return
	apply_gaze_local_direction(local_direction, delta, config)


func apply_gaze_local_direction(local_direction: Vector3, delta: float, config: Dictionary) -> void:
	var max_yaw := deg_to_rad(clampf(float(config.get("maxYawDegrees", 52.0)), 0.0, 120.0))
	var desired_yaw := clampf(atan2(-local_direction.x, -local_direction.z), -max_yaw, max_yaw)
	var desired := Quaternion(Vector3.UP, desired_yaw)
	var blend_rate := maxf(0.1, float(config.get("blendRate", 9.0)))
	var blend := 1.0 - exp(-blend_rate * maxf(0.0, delta))
	var role := String(config.get("role", "gaze")).strip_edges().to_lower()
	for binding in profile.bindings_for(role):
		var bone_name := String((binding as Dictionary).get("bone", ""))
		if bone_name.is_empty():
			continue
		var previous: Quaternion = gaze_rotations.get(bone_name, Quaternion.IDENTITY) as Quaternion
		gaze_rotations[bone_name] = previous.slerp(desired, blend)
	apply_combined_pose()


func locomotion_rotation_map(config: Dictionary) -> Dictionary:
	var rotations: Dictionary = {}
	if locomotion_weight <= 0.001:
		return rotations
	var axis: Vector3 = config.get("axis", Vector3.RIGHT) as Vector3
	axis = axis.normalized() if axis.length_squared() > 0.000001 else Vector3.RIGHT
	var amplitude := deg_to_rad(clampf(float(config.get("maxDegrees", 24.0)), 0.0, 80.0)) * locomotion_weight
	for side in ["left", "right"]:
		var phase_offset := 0.0 if side == "left" else PI
		var raw_bindings: Array = config.get(side, []) as Array
		for raw_binding in raw_bindings:
			var data: Dictionary = raw_binding as Dictionary
			var role := String(data.get("role", "")).strip_edges().to_lower()
			if role.is_empty():
				continue
			var role_offset := float(data.get("phaseOffset", 0.0))
			var sign := -1.0 if float(data.get("sign", 1.0)) < 0.0 else 1.0
			var angle := sin(locomotion_phase + phase_offset + role_offset) * amplitude * sign
			for binding in profile.bindings_for(role):
				var bone_name := String((binding as Dictionary).get("bone", ""))
				if not bone_name.is_empty():
					rotations[bone_name] = Quaternion(axis, angle)
	return rotations


func apply_combined_pose() -> void:
	if skeleton == null or not is_instance_valid(skeleton):
		return
	var contributions: Dictionary = last_solution.get("contributions", {}) as Dictionary
	for bone_index_value in controlled_bones.keys():
		skeleton.set_bone_pose_rotation(int(bone_index_value), Quaternion.IDENTITY)
	for bone_name in contributions.keys():
		var bone_index := skeleton.find_bone(String(bone_name))
		if bone_index < 0:
			continue
		var entry: Dictionary = contributions.get(bone_name, {}) as Dictionary
		var degrees: Vector3 = entry.get("rotationDegrees", Vector3.ZERO) as Vector3
		var radians := Vector3(deg_to_rad(degrees.x), deg_to_rad(degrees.y), deg_to_rad(degrees.z))
		var pose_rotation := Basis.from_euler(radians).get_rotation_quaternion()
		var alignment_direction: Vector3 = entry.get("motionAlignmentDirection", Vector3.ZERO) as Vector3
		var alignment_weight := clampf(float(entry.get("motionAlignmentWeight", 0.0)), 0.0, 1.0)
		if alignment_weight > 0.0 and alignment_direction.length_squared() > 0.000001:
			var rest_direction: Vector3 = entry.get("motionAlignmentRestDirection", Vector3.DOWN) as Vector3
			if rest_direction.length_squared() <= 0.000001:
				rest_direction = Vector3.DOWN
			var aligned_rotation := Quaternion(rest_direction.normalized(), alignment_direction.normalized())
			pose_rotation = pose_rotation.slerp(aligned_rotation, alignment_weight)
		var gait_rotation: Quaternion = locomotion_rotations.get(String(bone_name), Quaternion.IDENTITY) as Quaternion
		var gaze_rotation: Quaternion = gaze_rotations.get(String(bone_name), Quaternion.IDENTITY) as Quaternion
		skeleton.set_bone_pose_rotation(bone_index, gaze_rotation * gait_rotation * pose_rotation)
	for bone_name_value in locomotion_rotations.keys():
		var gait_bone_name := String(bone_name_value)
		if contributions.has(gait_bone_name):
			continue
		var gait_bone_index := skeleton.find_bone(gait_bone_name)
		if gait_bone_index >= 0:
			var gait_only_rotation: Quaternion = locomotion_rotations.get(gait_bone_name, Quaternion.IDENTITY) as Quaternion
			var gaze_only_rotation: Quaternion = gaze_rotations.get(gait_bone_name, Quaternion.IDENTITY) as Quaternion
			skeleton.set_bone_pose_rotation(gait_bone_index, gaze_only_rotation * gait_only_rotation)
	for gaze_bone_name_value in gaze_rotations.keys():
		var gaze_bone_name := String(gaze_bone_name_value)
		if contributions.has(gaze_bone_name) or locomotion_rotations.has(gaze_bone_name):
			continue
		var gaze_bone_index := skeleton.find_bone(gaze_bone_name)
		if gaze_bone_index >= 0:
			skeleton.set_bone_pose_rotation(gaze_bone_index, gaze_rotations.get(gaze_bone_name, Quaternion.IDENTITY) as Quaternion)
	skeleton.force_update_all_bone_transforms()


func reset_pose() -> void:
	if skeleton == null or not is_instance_valid(skeleton):
		return
	for bone_index_value in controlled_bones.keys():
		skeleton.set_bone_pose_rotation(int(bone_index_value), Quaternion.IDENTITY)
	skeleton.force_update_all_bone_transforms()
	last_solution = {"contributions": {}, "rejected": []}
	locomotion_phase = 0.0
	locomotion_weight = 0.0
	locomotion_rotations.clear()
	gaze_rotations.clear()


func diagnostics() -> Dictionary:
	return {
		"profile": profile.snapshot() if profile != null else {},
		"validation": validation.duplicate(true),
		"controlledBoneCount": controlled_bones.size(),
		"solution": last_solution.duplicate(true),
		"locomotionPhase": locomotion_phase,
		"locomotionWeight": locomotion_weight,
		"locomotionBones": locomotion_rotations.keys(),
		"gazeBones": gaze_rotations.keys()
	}
