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


static func add_shadow_stalker(body: Node3D, scale: float, asset_registry, material_map: Dictionary) -> Dictionary:
	# The Shadow Stalker is the first family to consume authored generated mesh
	# parts through the same semantic Skeleton3D contract. The asset pieces are
	# visible anatomy; the capsule that may accompany the actor remains physics
	# only and is never used as this body's presentation.
	var skeleton := create_skeleton(body, "ShadowStalkerMotionSkeleton", [
		{"name": "Root", "parent": "", "rest": Vector3(0.0, 1.28, 0.0) * scale},
		{"name": "Spine", "parent": "Root", "rest": Vector3(0.0, 0.22, 0.08) * scale},
		{"name": "Chest", "parent": "Spine", "rest": Vector3(0.0, 0.32, -0.12) * scale},
		{"name": "Head", "parent": "Chest", "rest": Vector3(0.0, 0.44, -0.18) * scale},
		{"name": "ArmLeft", "parent": "Chest", "rest": Vector3(-0.43, 0.16, -0.06) * scale},
		{"name": "ArmRight", "parent": "Chest", "rest": Vector3(0.43, 0.16, -0.06) * scale},
		# The continuous leg mesh begins at its hip. Place that origin just inside
		# the continuous torso base so the generated anatomy has a real overlap
		# instead of a visible gap below the Root attachment.
		{"name": "LegLeft", "parent": "Root", "rest": Vector3(-0.23, 0.04, 0.06) * scale},
		{"name": "LegRight", "parent": "Root", "rest": Vector3(0.23, 0.04, 0.06) * scale},
		{"name": "Tail", "parent": "Spine", "rest": Vector3(0.0, 0.06, 0.36) * scale}
	])
	var assets := [
		{"id": "shadow_stalker_torso", "bone": "Root", "name": "ShadowStalkerTorso", "position": Vector3.ZERO, "rotation": Vector3.ZERO},
		# The generated head's authored forward axis is opposite the shared Godot
		# target-facing convention. Normalize it at the semantic attachment so the
		# mesh family remains reusable while every consumer sees the actual face
		# looking toward the target/body forward direction.
		{"id": "shadow_stalker_head", "bone": "Head", "name": "ShadowStalkerHead", "position": Vector3.ZERO, "rotation": Vector3(0.0, PI, 0.0)},
		{"id": "shadow_stalker_arm", "bone": "ArmLeft", "name": "ShadowStalkerArmLeft", "position": Vector3.ZERO, "rotation": Vector3(PI, 0.0, 0.0)},
		{"id": "shadow_stalker_arm", "bone": "ArmRight", "name": "ShadowStalkerArmRight", "position": Vector3.ZERO, "rotation": Vector3(PI, 0.0, 0.0)},
		{"id": "shadow_stalker_leg", "bone": "LegLeft", "name": "ShadowStalkerLegLeft", "position": Vector3.ZERO, "rotation": Vector3(PI, 0.0, 0.0)},
		{"id": "shadow_stalker_leg", "bone": "LegRight", "name": "ShadowStalkerLegRight", "position": Vector3.ZERO, "rotation": Vector3(PI, 0.0, 0.0)},
		{"id": "shadow_stalker_tail", "bone": "Tail", "name": "ShadowStalkerTail", "position": Vector3.ZERO, "rotation": Vector3(deg_to_rad(-72.0), 0.0, 0.0)}
	]
	var attached_asset_ids: Array[String] = []
	for raw in assets:
		var asset_data: Dictionary = raw as Dictionary
		var asset_id := String(asset_data.get("id", ""))
		var part: Node3D = asset_registry.instantiate_asset(asset_id) if asset_registry != null and asset_registry.has_method("instantiate_asset") else null
		if part == null:
			var errors := ["Missing generated Shadow Stalker asset %s" % asset_id]
			skeleton.queue_free()
			return {"profile": shadow_stalker_profile(), "validation": {"valid": false, "errors": errors}, "assetIds": attached_asset_ids}
		part.name = String(asset_data.get("name", asset_id))
		part.position = asset_data.get("position", Vector3.ZERO) as Vector3
		part.rotation = asset_data.get("rotation", Vector3.ZERO) as Vector3
		part.scale = Vector3.ONE * scale
		if asset_registry.has_method("apply_material_map"):
			asset_registry.apply_material_map(part, material_map)
		add_attachment(skeleton, String(asset_data.get("bone", "Root")), part.name).add_child(part)
		attached_asset_ids.append(asset_id)
	var result := finalize_rig(body, skeleton, shadow_stalker_profile())
	body.set_meta("character_asset_parts", attached_asset_ids)
	body.set_meta("visual_source", "generated_shadow_stalker_mesh")
	result["assetIds"] = attached_asset_ids
	return result


static func add_frost_predator(body: Node3D, scale: float, asset_registry, material_map: Dictionary) -> Dictionary:
	# The Frost Predator is a generated quadruped family, not a scaled copy of
	# Ash Wolf. Its visible load-bearing body and each limb come from the asset
	# pipeline, while this semantic skeleton remains the reusable bridge between
	# its anatomy and all shared motion/contact systems.
	var skeleton := create_skeleton(body, "FrostPredatorMotionSkeleton", [
		{"name": "Root", "parent": "", "rest": Vector3(0.0, 0.83, 0.38) * scale},
		{"name": "Spine", "parent": "Root", "rest": Vector3(0.0, 0.03, -0.37) * scale},
		{"name": "Chest", "parent": "Spine", "rest": Vector3(0.0, 0.09, -0.76) * scale},
		{"name": "Head", "parent": "Chest", "rest": Vector3(0.0, 0.08, -0.44) * scale},
		{"name": "ForeLeft", "parent": "Chest", "rest": Vector3(-0.42, -0.18, 0.09) * scale},
		{"name": "ForeRight", "parent": "Chest", "rest": Vector3(0.42, -0.18, 0.09) * scale},
		{"name": "HindLeft", "parent": "Root", "rest": Vector3(-0.38, -0.12, 0.11) * scale},
		{"name": "HindRight", "parent": "Root", "rest": Vector3(0.38, -0.12, 0.11) * scale},
		{"name": "Tail", "parent": "Root", "rest": Vector3(0.0, 0.05, 0.30) * scale}
	])
	var assets := [
		{"id": "frost_predator_torso", "bone": "Root", "name": "FrostPredatorTorso", "position": Vector3(0.0, -0.16, 0.0), "rotation": Vector3.ZERO},
		{"id": "frost_predator_head", "bone": "Head", "name": "FrostPredatorHead", "position": Vector3.ZERO, "rotation": Vector3.ZERO},
		{"id": "frost_predator_foreleg", "bone": "ForeLeft", "name": "FrostPredatorForeLeft", "position": Vector3(0.0, 0.12, 0.0), "rotation": Vector3(PI, 0.0, 0.0)},
		{"id": "frost_predator_foreleg", "bone": "ForeRight", "name": "FrostPredatorForeRight", "position": Vector3(0.0, 0.12, 0.0), "rotation": Vector3(PI, 0.0, 0.0)},
		{"id": "frost_predator_hindleg", "bone": "HindLeft", "name": "FrostPredatorHindLeft", "position": Vector3(0.0, 0.12, 0.0), "rotation": Vector3(PI, 0.0, 0.0)},
		{"id": "frost_predator_hindleg", "bone": "HindRight", "name": "FrostPredatorHindRight", "position": Vector3(0.0, 0.12, 0.0), "rotation": Vector3(PI, 0.0, 0.0)},
		{"id": "frost_predator_tail", "bone": "Tail", "name": "FrostPredatorTail", "position": Vector3.ZERO, "rotation": Vector3.ZERO}
	]
	var attached_asset_ids: Array[String] = []
	for raw in assets:
		var asset_data: Dictionary = raw as Dictionary
		var asset_id := String(asset_data.get("id", ""))
		var part: Node3D = asset_registry.instantiate_asset(asset_id) if asset_registry != null and asset_registry.has_method("instantiate_asset") else null
		if part == null:
			var errors := ["Missing generated Frost Predator asset %s" % asset_id]
			skeleton.queue_free()
			return {"profile": frost_predator_profile(), "validation": {"valid": false, "errors": errors}, "assetIds": attached_asset_ids}
		part.name = String(asset_data.get("name", asset_id))
		part.position = asset_data.get("position", Vector3.ZERO) as Vector3
		part.rotation = asset_data.get("rotation", Vector3.ZERO) as Vector3
		part.scale = Vector3.ONE * scale
		if asset_registry.has_method("apply_material_map"):
			asset_registry.apply_material_map(part, material_map)
		add_attachment(skeleton, String(asset_data.get("bone", "Root")), part.name).add_child(part)
		attached_asset_ids.append(asset_id)
	var result := finalize_rig(body, skeleton, frost_predator_profile())
	body.set_meta("character_asset_parts", attached_asset_ids)
	body.set_meta("visual_source", "generated_frost_predator_mesh")
	result["assetIds"] = attached_asset_ids
	return result


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


static func shadow_stalker_profile():
	return MotionRigProfileScript.new({
		"id": "biped.shadow_stalker.v1",
		"skeletonPath": "ShadowStalkerMotionSkeleton",
		"metadata": {
			"family": "shadow_stalker",
			"visual": "generated_shadow_stalker",
			"locomotion": {
				"left": [{"role": "counter_left"}],
				"right": [{"role": "counter_right"}],
				"axis": Vector3.RIGHT,
				"maxDegrees": 31.0,
				"referenceSpeed": 4.55,
				"strideFrequency": 3.6,
				"blendRate": 12.0
			},
			"gazeTracking": {
				"role": "gaze",
				# Orbit locomotion keeps the collision body tangent to travel. Give the
				# independent head enough range to hold the player in its view across
				# that right-angle circle rather than only glancing toward them.
				"maxYawDegrees": 82.0,
				"blendRate": 10.0
			}
		},
		"roles": {
			"root": {"bone": "Root", "axis": Vector3.UP, "maxDegrees": 8.0},
			"torso": [{"bone": "Spine", "axis": Vector3.UP, "maxDegrees": 15.0, "weight": 0.52}, {"bone": "Chest", "axis": Vector3.UP, "maxDegrees": 24.0, "weight": 0.86}],
			"gaze": {"bone": "Head", "axis": Vector3.UP, "maxDegrees": 18.0},
			"lead_left": {"bone": "ArmLeft", "axis": Vector3.FORWARD, "maxDegrees": 0.0, "motionAlign": true, "restDirection": Vector3.DOWN},
			"lead_right": {"bone": "ArmRight", "axis": Vector3.FORWARD, "maxDegrees": 0.0, "motionAlign": true, "restDirection": Vector3.DOWN},
			"counter_left": {"bone": "LegLeft", "axis": Vector3.FORWARD, "maxDegrees": 24.0, "sign": -1.0},
			"counter_right": {"bone": "LegRight", "axis": Vector3.FORWARD, "maxDegrees": 24.0}
		}
	})


static func frost_predator_profile():
	return MotionRigProfileScript.new({
		"id": "quadruped.frost_predator.v1",
		"skeletonPath": "FrostPredatorMotionSkeleton",
		"metadata": {
			"family": "frost_predator",
			"visual": "generated_frost_predator",
			"locomotion": {
				# Diagonal pairs are normal four-legged gait data. This only controls
				# a visual pose overlay from the true CharacterBody velocity.
				"left": [{"role": "lead_left"}, {"role": "counter_right"}],
				"right": [{"role": "lead_right"}, {"role": "counter_left"}],
				# Rotate the downward rest limbs around their lateral axis so gait
				# travels fore-and-aft. A forward-axis rotation would only sway them
				# side-to-side regardless of the real motor heading.
				"axis": Vector3.RIGHT,
				"maxDegrees": 29.0,
				"referenceSpeed": 4.25,
				"strideFrequency": 4.15,
				"blendRate": 12.0
			},
			"gazeTracking": {"role": "gaze", "maxYawDegrees": 46.0, "blendRate": 11.0}
		},
		"roles": {
			"root": {"bone": "Root", "axis": Vector3.UP, "maxDegrees": 9.0},
			"torso": [{"bone": "Spine", "axis": Vector3.UP, "maxDegrees": 13.0, "weight": 0.50}, {"bone": "Chest", "axis": Vector3.UP, "maxDegrees": 20.0, "weight": 0.82}],
			"gaze": {"bone": "Head", "axis": Vector3.UP, "maxDegrees": 14.0},
			"lead_left": {"bone": "ForeLeft", "axis": Vector3.FORWARD, "maxDegrees": 0.0, "motionAlign": true, "restDirection": Vector3.DOWN},
			"lead_right": {"bone": "ForeRight", "axis": Vector3.FORWARD, "maxDegrees": 0.0, "motionAlign": true, "restDirection": Vector3.DOWN},
			"counter_left": {"bone": "HindLeft", "axis": Vector3.FORWARD, "maxDegrees": 24.0, "sign": -1.0},
			"counter_right": {"bone": "HindRight", "axis": Vector3.FORWARD, "maxDegrees": 24.0}
		}
	})
