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
		reset_pose()


func apply_signals(signals: Array) -> Dictionary:
	if not bool(validation.get("valid", false)) or skeleton == null or not is_instance_valid(skeleton):
		return {"contributions": {}, "rejected": ["invalid rig profile"]}
	last_solution = MotionPoseSolverScript.solve(profile, signals)
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
		skeleton.set_bone_pose_rotation(bone_index, pose_rotation)
	skeleton.force_update_all_bone_transforms()
	return last_solution.duplicate(true)


func reset_pose() -> void:
	if skeleton == null or not is_instance_valid(skeleton):
		return
	for bone_index_value in controlled_bones.keys():
		skeleton.set_bone_pose_rotation(int(bone_index_value), Quaternion.IDENTITY)
	skeleton.force_update_all_bone_transforms()
	last_solution = {"contributions": {}, "rejected": []}


func diagnostics() -> Dictionary:
	return {
		"profile": profile.snapshot() if profile != null else {},
		"validation": validation.duplicate(true),
		"controlledBoneCount": controlled_bones.size(),
		"solution": last_solution.duplicate(true)
	}
