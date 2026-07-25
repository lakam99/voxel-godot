extends RefCounted
class_name MotionRigVisualFactory

const MotionRigProfileScript := preload("res://scripts/combat/rig/MotionRigProfile.gd")
const MotionRigPoseDriverScript := preload("res://scripts/combat/rig/MotionRigPoseDriver.gd")

## Small generated skeletal bodies for the arena and hostile factory. The
## factory deliberately returns a normal Skeleton3D plus a MotionRigProfile;
## imported GLBs can use the exact same profile/driver contract later.

static func add_ash_wolf(body: Node3D, scale: float, fur_material: Material, accent_material: Material, eye_material: Material) -> Dictionary:
	var skeleton := create_skeleton(body, "WolfMotionSkeleton", [
		# Rest transforms retain the prior production wolf silhouette. Pose is an
		# offset from these authored proportions, never a replacement layout.
		{"name": "Root", "parent": "", "rest": Vector3(0.0, 0.66, 0.05) * scale},
		{"name": "Spine", "parent": "Root", "rest": Vector3.ZERO},
		{"name": "Chest", "parent": "Spine", "rest": Vector3(0.0, 0.17, -0.53) * scale},
		{"name": "Head", "parent": "Chest", "rest": Vector3(0.0, 0.17, -0.24) * scale},
		{"name": "FrontLeftLeg", "parent": "Chest", "rest": Vector3(-0.28, -0.30, 0.10) * scale},
		{"name": "FrontRightLeg", "parent": "Chest", "rest": Vector3(0.28, -0.30, 0.10) * scale},
		{"name": "BackLeftLeg", "parent": "Spine", "rest": Vector3(-0.28, -0.13, 0.45) * scale},
		{"name": "BackRightLeg", "parent": "Spine", "rest": Vector3(0.28, -0.13, 0.45) * scale},
		{"name": "Tail", "parent": "Spine", "rest": Vector3(0.0, 0.20, 0.81) * scale}
	])
	add_box(skeleton, "Root", "WolfBody", Vector3(0.82, 0.50, 1.34) * scale, Vector3.ZERO, fur_material)
	add_box(skeleton, "Chest", "WolfShoulders", Vector3(0.72, 0.38, 0.52) * scale, Vector3.ZERO, accent_material)
	add_box(skeleton, "Head", "WolfHead", Vector3(0.56, 0.48, 0.54) * scale, Vector3.ZERO, fur_material)
	add_box(skeleton, "Head", "WolfMuzzle", Vector3(0.36, 0.26, 0.32) * scale, Vector3(0.0, -0.09, -0.34) * scale, accent_material)
	for x in [-0.21, 0.21]:
		add_cone(skeleton, "Head", "WolfEar", 0.17 * scale, 0.0, 0.42 * scale, Vector3(x * scale, 0.37 * scale, -0.04 * scale), fur_material)
		add_box(skeleton, "Head", "WolfEye", Vector3(0.075, 0.075, 0.05) * scale, Vector3(x * scale, 0.06 * scale, -0.29 * scale), eye_material)
	for side in [{"bone": "FrontLeftLeg", "x": -1.0}, {"bone": "FrontRightLeg", "x": 1.0}, {"bone": "BackLeftLeg", "x": -1.0}, {"bone": "BackRightLeg", "x": 1.0}]:
		var bone := String(side.get("bone", ""))
		add_box(skeleton, bone, "%sVisual" % bone, Vector3(0.16, 0.52, 0.18) * scale, Vector3(0.0, -0.26 * scale, 0.0), fur_material)
		add_box(skeleton, bone, "%sPaw" % bone, Vector3(0.20, 0.11, 0.30) * scale, Vector3(0.0, -0.50 * scale, -0.05 * scale), accent_material)
	add_cylinder(skeleton, "Tail", "WolfTail", 0.18 * scale, 0.10 * scale, 0.92 * scale, Vector3.ZERO, Vector3(deg_to_rad(52.0), 0.0, 0.0), fur_material)
	return finalize_rig(body, skeleton, wolf_profile())


static func add_training_construct(body: Node3D, scale: float, body_material: Material, accent_material: Material, eye_material: Material) -> Dictionary:
	var skeleton := create_skeleton(body, "ConstructMotionSkeleton", [
		{"name": "Root", "parent": "", "rest": Vector3(0.0, 0.88, 0.0) * scale},
		{"name": "Torso", "parent": "Root", "rest": Vector3(0.0, 0.34, 0.0) * scale},
		{"name": "Head", "parent": "Torso", "rest": Vector3(0.0, 0.42, 0.0) * scale},
		{"name": "ArmLeft", "parent": "Torso", "rest": Vector3(-0.37, 0.18, 0.0) * scale},
		{"name": "ArmRight", "parent": "Torso", "rest": Vector3(0.37, 0.18, 0.0) * scale},
		{"name": "LegLeft", "parent": "Root", "rest": Vector3(-0.20, -0.06, 0.0) * scale},
		{"name": "LegRight", "parent": "Root", "rest": Vector3(0.20, -0.06, 0.0) * scale}
	])
	add_box(skeleton, "Root", "ConstructPelvis", Vector3(0.52, 0.26, 0.32) * scale, Vector3.ZERO, accent_material)
	add_box(skeleton, "Torso", "ConstructTorso", Vector3(0.72, 0.76, 0.36) * scale, Vector3(0.0, 0.15 * scale, 0.0), body_material)
	add_box(skeleton, "Head", "ConstructHead", Vector3(0.46, 0.46, 0.42) * scale, Vector3.ZERO, body_material)
	for x in [-0.12, 0.12]:
		add_box(skeleton, "Head", "ConstructEye", Vector3(0.07, 0.07, 0.04) * scale, Vector3(x * scale, 0.04 * scale, -0.23 * scale), eye_material)
	for bone in ["ArmLeft", "ArmRight"]:
		add_box(skeleton, bone, "%sVisual" % bone, Vector3(0.18, 0.64, 0.20) * scale, Vector3(0.0, -0.31 * scale, 0.0), body_material)
		add_box(skeleton, bone, "%sHand" % bone, Vector3(0.22, 0.16, 0.24) * scale, Vector3(0.0, -0.66 * scale, -0.03 * scale), accent_material)
	for bone in ["LegLeft", "LegRight"]:
		add_box(skeleton, bone, "%sVisual" % bone, Vector3(0.22, 0.76, 0.24) * scale, Vector3(0.0, -0.38 * scale, 0.0), body_material)
		add_box(skeleton, bone, "%sFoot" % bone, Vector3(0.26, 0.15, 0.36) * scale, Vector3(0.0, -0.79 * scale, -0.08 * scale), accent_material)
	return finalize_rig(body, skeleton, construct_profile())


static func create_skeleton(body: Node3D, skeleton_name: String, bones: Array) -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	skeleton.name = skeleton_name
	body.add_child(skeleton)
	for raw_bone in bones:
		var data: Dictionary = raw_bone as Dictionary
		skeleton.add_bone(String(data.get("name", "Bone")))
	for raw_bone in bones:
		var data: Dictionary = raw_bone as Dictionary
		var bone_index := skeleton.find_bone(String(data.get("name", "")))
		var parent_name := String(data.get("parent", ""))
		if not parent_name.is_empty():
			skeleton.set_bone_parent(bone_index, skeleton.find_bone(parent_name))
		var rest_position: Vector3 = data.get("rest", Vector3.ZERO) as Vector3
		skeleton.set_bone_rest(bone_index, Transform3D(Basis.IDENTITY, rest_position))
	skeleton.reset_bone_poses()
	return skeleton


static func add_attachment(skeleton: Skeleton3D, bone_name: String, part_name: String) -> BoneAttachment3D:
	var attachment := BoneAttachment3D.new()
	attachment.name = "%sAttachment" % part_name
	attachment.bone_name = bone_name
	skeleton.add_child(attachment)
	return attachment


static func add_box(skeleton: Skeleton3D, bone_name: String, part_name: String, size: Vector3, position: Vector3, material: Material) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.name = part_name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	add_attachment(skeleton, bone_name, part_name).add_child(instance)


static func add_cone(skeleton: Skeleton3D, bone_name: String, part_name: String, bottom_radius: float, top_radius: float, height: float, position: Vector3, material: Material) -> void:
	var mesh := CylinderMesh.new()
	mesh.bottom_radius = bottom_radius
	mesh.top_radius = top_radius
	mesh.height = height
	mesh.radial_segments = 4
	var instance := MeshInstance3D.new()
	instance.name = part_name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	add_attachment(skeleton, bone_name, part_name).add_child(instance)


static func add_cylinder(skeleton: Skeleton3D, bone_name: String, part_name: String, bottom_radius: float, top_radius: float, height: float, position: Vector3, rotation: Vector3, material: Material) -> void:
	var mesh := CylinderMesh.new()
	mesh.bottom_radius = bottom_radius
	mesh.top_radius = top_radius
	mesh.height = height
	mesh.radial_segments = 5
	var instance := MeshInstance3D.new()
	instance.name = part_name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	instance.rotation = rotation
	add_attachment(skeleton, bone_name, part_name).add_child(instance)


static func finalize_rig(body: Node3D, skeleton: Skeleton3D, profile) -> Dictionary:
	var driver = MotionRigPoseDriverScript.new()
	driver.name = "MotionRigPoseDriver"
	body.add_child(driver)
	var validation := driver.configure(profile, skeleton)
	body.set_meta("motion_rig_profile", profile)
	body.set_meta("motion_rig_profile_id", profile.id)
	body.set_meta("motion_rig_validation", validation)
	body.set_meta("visual_source", "procedural_motion_rig")
	body.set_meta("character_asset_parts", [])
	return {"profile": profile, "skeleton": skeleton, "driver": driver, "validation": validation}


static func wolf_profile():
	return MotionRigProfileScript.new({
		"id": "quadruped.ash_wolf.v1",
		"skeletonPath": "WolfMotionSkeleton",
		"metadata": {"family": "quadruped", "visual": "ash_wolf"},
		"roles": {
			"root": {"bone": "Root", "axis": Vector3.UP, "maxDegrees": 12.0},
			"torso": [{"bone": "Spine", "axis": Vector3.UP, "maxDegrees": 17.0, "weight": 0.54}, {"bone": "Chest", "axis": Vector3.UP, "maxDegrees": 25.0, "weight": 0.82}],
			"gaze": {"bone": "Head", "axis": Vector3.UP, "maxDegrees": 14.0},
			"lead_left": {"bone": "FrontLeftLeg", "axis": Vector3.FORWARD, "maxDegrees": 44.0},
			"lead_right": {"bone": "FrontRightLeg", "axis": Vector3.FORWARD, "maxDegrees": 44.0, "sign": -1.0},
			"counter_left": {"bone": "BackLeftLeg", "axis": Vector3.FORWARD, "maxDegrees": 25.0, "sign": -1.0},
			"counter_right": {"bone": "BackRightLeg", "axis": Vector3.FORWARD, "maxDegrees": 25.0}
		}
	})


static func construct_profile():
	return MotionRigProfileScript.new({
		"id": "biped.training_construct.v1",
		"skeletonPath": "ConstructMotionSkeleton",
		"metadata": {"family": "biped", "visual": "training_construct"},
		"roles": {
			# Keep the construct's parent chain neutral during its direct arm
			# alignment: this makes the visible limb match the shared motion vector
			# instead of inheriting an unrelated torso turn.
			"root": {"bone": "Root", "axis": Vector3.UP, "maxDegrees": 0.0},
			"torso": {"bone": "Torso", "axis": Vector3.UP, "maxDegrees": 0.0},
			"gaze": {"bone": "Head", "axis": Vector3.UP, "maxDegrees": 19.0},
			"lead_left": {"bone": "ArmLeft", "axis": Vector3.FORWARD, "maxDegrees": 0.0, "motionAlign": true, "restDirection": Vector3.DOWN},
			"lead_right": {"bone": "ArmRight", "axis": Vector3.FORWARD, "maxDegrees": 0.0, "motionAlign": true, "restDirection": Vector3.DOWN},
			"counter_left": {"bone": "LegLeft", "axis": Vector3.FORWARD, "maxDegrees": 21.0, "sign": -1.0},
			"counter_right": {"bone": "LegRight", "axis": Vector3.FORWARD, "maxDegrees": 21.0}
		}
	})
