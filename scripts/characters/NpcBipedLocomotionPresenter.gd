extends Node
class_name NpcBipedLocomotionPresenter

## Presentation-only biped gait.  Callers supply an already measured or
## intended world velocity.  This script never changes an actor's position,
## CharacterBody3D velocity, collision, navigation, route state, or combat.

var visual_root: Node3D
var skeleton: Skeleton3D
var anatomy_root: Node3D
var leg_left_index := -1
var leg_right_index := -1
var arm_left_index := -1
var arm_right_index := -1
var spine_index := -1
var gait_phase := 0.0
var gait_weight := 0.0
var visual_yaw := 0.0


func configure(next_visual_root: Node3D, next_skeleton: Skeleton3D, next_anatomy_root: Node3D) -> void:
	visual_root = next_visual_root
	skeleton = next_skeleton
	anatomy_root = next_anatomy_root
	if skeleton == null:
		return
	leg_left_index = skeleton.find_bone("LegLeft")
	leg_right_index = skeleton.find_bone("LegRight")
	arm_left_index = skeleton.find_bone("ArmLeft")
	arm_right_index = skeleton.find_bone("ArmRight")
	spine_index = skeleton.find_bone("Spine")
	visual_yaw = visual_root.global_rotation.y if visual_root != null and visual_root.is_inside_tree() else (visual_root.rotation.y if visual_root != null else 0.0)


func apply_velocity(world_velocity: Vector3, delta: float) -> void:
	if visual_root == null or skeleton == null or not is_instance_valid(visual_root) or not is_instance_valid(skeleton):
		return
	var horizontal := Vector3(world_velocity.x, 0.0, world_velocity.z)
	var speed := horizontal.length()
	if speed <= 0.0001:
		gait_weight = 0.0
		apply_gait()
		return
	var target_weight := clampf(speed / 3.3, 0.0, 1.0)
	gait_weight = move_toward(gait_weight, target_weight, maxf(0.0, delta) * 8.5)
	if speed > 0.035:
		var heading := horizontal / speed
		var target_yaw := atan2(-heading.x, -heading.z)
		visual_yaw = lerp_angle(visual_yaw, target_yaw, 1.0 - exp(-10.0 * maxf(0.0, delta)))
		visual_root.global_rotation = Vector3(0.0, visual_yaw, 0.0)
		gait_phase = fposmod(gait_phase + delta * TAU * lerpf(1.35, 3.15, target_weight), TAU)
	apply_gait()


func apply_body_motion(body: CharacterBody3D, delta: float) -> void:
	if body == null or not is_instance_valid(body):
		apply_velocity(Vector3.ZERO, delta)
		return
	var applied_velocity: Vector3 = body.get_meta("npc_applied_velocity", Vector3.ZERO)
	apply_velocity(applied_velocity, delta)


func apply_gait() -> void:
	if skeleton == null or not is_instance_valid(skeleton):
		return
	var leg_angle := deg_to_rad(28.0) * sin(gait_phase) * gait_weight
	var arm_angle := deg_to_rad(20.0) * sin(gait_phase) * gait_weight
	set_bone_rotation(leg_left_index, Quaternion(Vector3.RIGHT, leg_angle))
	set_bone_rotation(leg_right_index, Quaternion(Vector3.RIGHT, -leg_angle))
	set_bone_rotation(arm_left_index, Quaternion(Vector3.RIGHT, -arm_angle))
	set_bone_rotation(arm_right_index, Quaternion(Vector3.RIGHT, arm_angle))
	set_bone_rotation(spine_index, Quaternion(Vector3.FORWARD, deg_to_rad(2.2) * sin(gait_phase * 2.0) * gait_weight))
	if anatomy_root != null and is_instance_valid(anatomy_root):
		anatomy_root.position.y = 0.024 * sin(gait_phase * 2.0) * gait_weight
	skeleton.force_update_all_bone_transforms()


func set_bone_rotation(index: int, rotation: Quaternion) -> void:
	if index >= 0:
		skeleton.set_bone_pose_rotation(index, rotation)
