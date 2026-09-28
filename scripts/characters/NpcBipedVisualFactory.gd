extends RefCounted
class_name NpcBipedVisualFactory

const NpcBipedBlinkPresenterScript := preload("res://scripts/characters/NpcBipedBlinkPresenter.gd")
const NpcBipedLocomotionPresenterScript := preload("res://scripts/characters/NpcBipedLocomotionPresenter.gd")

## Recipe-backed, low-poly human biped presentation.  The returned semantic
## skeleton is intentionally useful beyond this PoC: later NPC runtime code
## can replace the old capsule visual by consuming the same recipe and bones,
## without changing NPC collision or route authority.

static func add_biped(parent: Node3D, recipe: Dictionary, display_name := "Citizen") -> Dictionary:
	var visual_root := Node3D.new()
	visual_root.name = "NpcBipedVisual"
	parent.add_child(visual_root)
	var scale_factor := clampf(float(recipe.get("stature", 1.0)), 0.82, 1.22)
	var shoulder_scale := clampf(float(recipe.get("shoulderScale", 1.0)), 0.82, 1.22)
	var materials := materials_for(recipe)
	var skeleton := create_skeleton(visual_root, scale_factor, shoulder_scale)
	var anatomy_root := Node3D.new()
	anatomy_root.name = "NpcBipedAnatomy"
	skeleton.add_child(anatomy_root)
	# Keep the skin/garments as child pieces of their semantic bones.  The
	# visible body is a proper biped hierarchy, never a single capsule that
	# happens to look like a person.
	add_torso(skeleton, anatomy_root, scale_factor, shoulder_scale, materials, recipe)
	add_head(skeleton, scale_factor, materials, recipe)
	add_limbs(skeleton, scale_factor, shoulder_scale, materials)
	var blink := NpcBipedBlinkPresenterScript.new()
	blink.name = "NpcBipedBlinkPresenter"
	blink.configure(eye_meshes(skeleton), recipe.get("eyes", {}) as Dictionary)
	visual_root.add_child(blink)
	var locomotion := NpcBipedLocomotionPresenterScript.new()
	locomotion.name = "NpcBipedLocomotionPresenter"
	locomotion.configure(visual_root, skeleton, anatomy_root)
	visual_root.add_child(locomotion)
	add_label(visual_root, display_name, recipe)
	visual_root.set_meta("npc_biped_recipe", recipe.duplicate(true))
	visual_root.set_meta("visual_source", "npc_biped_recipe")
	return {"visualRoot": visual_root, "skeleton": skeleton, "locomotion": locomotion, "blink": blink}


static func materials_for(recipe: Dictionary) -> Dictionary:
	var skin: Dictionary = recipe.get("skin", {}) as Dictionary
	var hair: Dictionary = recipe.get("hair", {}) as Dictionary
	var outfit: Dictionary = recipe.get("outfit", {}) as Dictionary
	var eyes: Dictionary = recipe.get("eyes", {}) as Dictionary
	return {
		"skin": make_material(skin.get("color", Color("b97957")) as Color, 0.82),
		"hair": make_material(hair.get("color", Color("2f1b18")) as Color, 0.88),
		"cloth": make_material(outfit.get("primary", Color("466d4c")) as Color, 0.88),
		"accent": make_material(outfit.get("secondary", Color("c49a55")) as Color, 0.82),
		"eye": make_material(eyes.get("color", Color("281a18")) as Color, 0.54),
		"sole": make_material(Color("33241e"), 0.92)
	}


static func create_skeleton(parent: Node3D, scale_factor: float, shoulder_scale: float) -> Skeleton3D:
	var skeleton := Skeleton3D.new()
	skeleton.name = "NpcBipedSkeleton"
	parent.add_child(skeleton)
	var bones: Array[Dictionary] = [
		{"name": "Root", "parent": "", "rest": Vector3.ZERO},
		{"name": "Pelvis", "parent": "Root", "rest": Vector3(0.0, 0.80, 0.0) * scale_factor},
		{"name": "Spine", "parent": "Pelvis", "rest": Vector3(0.0, 0.18, 0.0) * scale_factor},
		{"name": "Chest", "parent": "Spine", "rest": Vector3(0.0, 0.30, 0.0) * scale_factor},
		{"name": "Head", "parent": "Chest", "rest": Vector3(0.0, 0.30, -0.02) * scale_factor},
		{"name": "ArmLeft", "parent": "Chest", "rest": Vector3(-0.31 * shoulder_scale, 0.08, 0.0) * scale_factor},
		{"name": "ArmRight", "parent": "Chest", "rest": Vector3(0.31 * shoulder_scale, 0.08, 0.0) * scale_factor},
		{"name": "LegLeft", "parent": "Pelvis", "rest": Vector3(-0.18, -0.02, 0.0) * scale_factor},
		{"name": "LegRight", "parent": "Pelvis", "rest": Vector3(0.18, -0.02, 0.0) * scale_factor}
	]
	for bone in bones:
		skeleton.add_bone(String(bone.get("name", "Bone")))
	for bone in bones:
		var index := skeleton.find_bone(String(bone.get("name", "")))
		var parent_name := String(bone.get("parent", ""))
		if not parent_name.is_empty():
			skeleton.set_bone_parent(index, skeleton.find_bone(parent_name))
		skeleton.set_bone_rest(index, Transform3D(Basis.IDENTITY, bone.get("rest", Vector3.ZERO) as Vector3))
	skeleton.reset_bone_poses()
	return skeleton


static func add_torso(skeleton: Skeleton3D, anatomy_root: Node3D, scale_factor: float, shoulder_scale: float, materials: Dictionary, recipe: Dictionary) -> void:
	# anatomy_root is a presentation pivot for gait bob while all parts below
	# retain their ordinary semantic bone attachment.
	var torso_attachment := add_attachment(skeleton, "Pelvis", "NpcTorsoAttachment")
	anatomy_root.reparent(torso_attachment, false)
	add_cylinder(anatomy_root, "NpcTunicTorso", 0.31 * shoulder_scale * scale_factor, 0.36 * shoulder_scale * scale_factor, 0.70 * scale_factor, Vector3(0.0, 0.34 * scale_factor, 0.0), materials.get("cloth") as Material, 7)
	add_box(anatomy_root, "NpcBelt", Vector3(0.68 * shoulder_scale, 0.085, 0.36) * scale_factor, Vector3(0.0, 0.20 * scale_factor, -0.005), materials.get("accent") as Material)
	var outfit: Dictionary = recipe.get("outfit", {}) as Dictionary
	match String(outfit.get("design", "tunic")):
		"doublet":
			add_box(anatomy_root, "NpcDoubletFront", Vector3(0.42 * shoulder_scale, 0.48, 0.045) * scale_factor, Vector3(0.0, 0.42 * scale_factor, -0.305 * scale_factor), materials.get("accent") as Material)
			add_box(anatomy_root, "NpcDoubletCollar", Vector3(0.42 * shoulder_scale, 0.10, 0.38) * scale_factor, Vector3(0.0, 0.66 * scale_factor, 0.0), materials.get("accent") as Material)
		"traveller_wrap":
			add_box(anatomy_root, "NpcTravellerWrap", Vector3(0.52 * shoulder_scale, 0.18, 0.055) * scale_factor, Vector3(0.08 * scale_factor, 0.49 * scale_factor, -0.31 * scale_factor), materials.get("accent") as Material)
			add_box(anatomy_root, "NpcTravellerSashTail", Vector3(0.10, 0.40, 0.06) * scale_factor, Vector3(0.24 * scale_factor, 0.13 * scale_factor, -0.18 * scale_factor), materials.get("accent") as Material)
		"layered_vest":
			add_box(anatomy_root, "NpcLayeredVestLeft", Vector3(0.18, 0.50, 0.06) * scale_factor, Vector3(-0.15 * scale_factor, 0.43 * scale_factor, -0.31 * scale_factor), materials.get("accent") as Material)
			add_box(anatomy_root, "NpcLayeredVestRight", Vector3(0.18, 0.50, 0.06) * scale_factor, Vector3(0.15 * scale_factor, 0.43 * scale_factor, -0.31 * scale_factor), materials.get("accent") as Material)
		_:
			add_cylinder(anatomy_root, "NpcTunicHem", 0.35 * shoulder_scale * scale_factor, 0.38 * shoulder_scale * scale_factor, 0.16 * scale_factor, Vector3(0.0, 0.08 * scale_factor, 0.0), materials.get("cloth") as Material, 7)


static func add_head(skeleton: Skeleton3D, scale_factor: float, materials: Dictionary, recipe: Dictionary) -> void:
	var head := add_attachment(skeleton, "Head", "NpcHeadAttachment")
	add_sphere(head, "NpcHead", 0.215 * scale_factor, Vector3(0.0, 0.15 * scale_factor, 0.0), materials.get("skin") as Material)
	var eyes: Array[MeshInstance3D] = []
	for side in [-1.0, 1.0]:
		var eye := add_box(head, "NpcEyeLeft" if side < 0.0 else "NpcEyeRight", Vector3(0.048, 0.052, 0.025) * scale_factor, Vector3(side * 0.075 * scale_factor, 0.17 * scale_factor, -0.205 * scale_factor), materials.get("eye") as Material)
		eye.set_meta("npc_eye", true)
		eyes.append(eye)
	add_hair(head, scale_factor, materials.get("hair") as Material, recipe)
	# Store the exact visible eyes on the skeleton.  It avoids a second lookup or
	# a name-based identity rule when the blink presenter is constructed.
	skeleton.set_meta("npc_biped_eyes", eyes)


static func add_hair(head: Node3D, scale_factor: float, hair_material: Material, recipe: Dictionary) -> void:
	var hair: Dictionary = recipe.get("hair", {}) as Dictionary
	match String(hair.get("style", "bald")):
		"bald":
			return
		"receding":
			add_sphere(head, "NpcRecedingCrown", 0.222 * scale_factor, Vector3(0.0, 0.22 * scale_factor, 0.035 * scale_factor), hair_material, Vector3(1.0, 0.42, 0.94))
			add_box(head, "NpcRecedingTempleLeft", Vector3(0.06, 0.13, 0.16) * scale_factor, Vector3(-0.16 * scale_factor, 0.22 * scale_factor, -0.02 * scale_factor), hair_material)
			add_box(head, "NpcRecedingTempleRight", Vector3(0.06, 0.13, 0.16) * scale_factor, Vector3(0.16 * scale_factor, 0.22 * scale_factor, -0.02 * scale_factor), hair_material)
		"long":
			add_hair_cap(head, "NpcLongHairCap", 0.225 * scale_factor, Vector3(0.0, 0.15 * scale_factor, 0.0), hair_material)
			add_box(head, "NpcLongHairLeft", Vector3(0.075, 0.34, 0.13) * scale_factor, Vector3(-0.19 * scale_factor, 0.04 * scale_factor, 0.05 * scale_factor), hair_material)
			add_box(head, "NpcLongHairRight", Vector3(0.075, 0.34, 0.13) * scale_factor, Vector3(0.19 * scale_factor, 0.04 * scale_factor, 0.05 * scale_factor), hair_material)
			add_box(head, "NpcLongHairBack", Vector3(0.31, 0.36, 0.065) * scale_factor, Vector3(0.0, 0.04 * scale_factor, 0.18 * scale_factor), hair_material)
		_:
			add_hair_cap(head, "NpcCroppedHairCap", 0.222 * scale_factor, Vector3(0.0, 0.15 * scale_factor, 0.0), hair_material)


static func add_hair_cap(parent: Node3D, name: String, radius: float, position: Vector3, material: Material) -> MeshInstance3D:
	# A sphere mesh squashed over the head still leaves visible skin gaps at
	# some viewing angles.  Build an actual continuous spherical cap instead:
	# it spans the entire crown and reaches just above the eye line, without
	# covering the face.  Receding hair intentionally does not use this cap.
	var radial_segments := 10
	var ring_count := 5
	var cap_angle := deg_to_rad(82.0)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for ring in range(ring_count):
		var theta_a := cap_angle * float(ring) / float(ring_count)
		var theta_b := cap_angle * float(ring + 1) / float(ring_count)
		for segment in range(radial_segments):
			var azimuth_a := TAU * float(segment) / float(radial_segments)
			var azimuth_b := TAU * float(segment + 1) / float(radial_segments)
			var top_left := sphere_cap_point(radius, theta_a, azimuth_a)
			var top_right := sphere_cap_point(radius, theta_a, azimuth_b)
			var bottom_left := sphere_cap_point(radius, theta_b, azimuth_a)
			var bottom_right := sphere_cap_point(radius, theta_b, azimuth_b)
			surface.add_vertex(top_left)
			surface.add_vertex(bottom_left)
			surface.add_vertex(bottom_right)
			surface.add_vertex(top_left)
			surface.add_vertex(bottom_right)
			surface.add_vertex(top_right)
	surface.generate_normals()
	var instance := MeshInstance3D.new()
	instance.name = name
	instance.mesh = surface.commit()
	instance.material_override = material
	instance.position = position
	parent.add_child(instance)
	return instance


static func sphere_cap_point(radius: float, polar_angle: float, azimuth: float) -> Vector3:
	var ring_radius := radius * sin(polar_angle)
	return Vector3(ring_radius * cos(azimuth), radius * cos(polar_angle), ring_radius * sin(azimuth))


static func add_limbs(skeleton: Skeleton3D, scale_factor: float, shoulder_scale: float, materials: Dictionary) -> void:
	for side in [-1.0, 1.0]:
		var arm_bone := "ArmLeft" if side < 0.0 else "ArmRight"
		var arm := add_attachment(skeleton, arm_bone, "Npc%sAttachment" % arm_bone)
		add_cylinder(arm, "Npc%sSleeve" % arm_bone, 0.085 * scale_factor, 0.10 * scale_factor, 0.34 * scale_factor, Vector3(0.0, -0.17 * scale_factor, 0.0), materials.get("cloth") as Material, 6)
		add_cylinder(arm, "Npc%sForearm" % arm_bone, 0.064 * scale_factor, 0.072 * scale_factor, 0.28 * scale_factor, Vector3(0.0, -0.47 * scale_factor, 0.0), materials.get("skin") as Material, 6)
		add_sphere(arm, "Npc%sHand" % arm_bone, 0.078 * scale_factor, Vector3(0.0, -0.62 * scale_factor, 0.0), materials.get("skin") as Material, Vector3(0.84, 1.0, 0.84))
		var leg_bone := "LegLeft" if side < 0.0 else "LegRight"
		var leg := add_attachment(skeleton, leg_bone, "Npc%sAttachment" % leg_bone)
		add_cylinder(leg, "Npc%sTrouser" % leg_bone, 0.105 * scale_factor, 0.13 * scale_factor, 0.66 * scale_factor, Vector3(0.0, -0.34 * scale_factor, 0.0), materials.get("cloth") as Material, 6)
		add_box(leg, "Npc%sBoot" % leg_bone, Vector3(0.20, 0.12, 0.32) * scale_factor, Vector3(0.0, -0.70 * scale_factor, -0.075 * scale_factor), materials.get("sole") as Material)


static func eye_meshes(skeleton: Skeleton3D) -> Array[MeshInstance3D]:
	var eyes: Array[MeshInstance3D] = []
	var raw: Array = skeleton.get_meta("npc_biped_eyes", []) as Array
	for value in raw:
		if value is MeshInstance3D:
			eyes.append(value as MeshInstance3D)
	return eyes


static func add_attachment(skeleton: Skeleton3D, bone_name: String, attachment_name: String) -> BoneAttachment3D:
	var attachment := BoneAttachment3D.new()
	attachment.name = attachment_name
	attachment.bone_name = bone_name
	skeleton.add_child(attachment)
	return attachment


static func add_box(parent: Node3D, name: String, size: Vector3, position: Vector3, material: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.name = name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	parent.add_child(instance)
	return instance


static func add_cylinder(parent: Node3D, name: String, top_radius: float, bottom_radius: float, height: float, position: Vector3, material: Material, radial_segments := 6) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top_radius
	mesh.bottom_radius = bottom_radius
	mesh.height = height
	mesh.radial_segments = radial_segments
	var instance := MeshInstance3D.new()
	instance.name = name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	parent.add_child(instance)
	return instance


static func add_sphere(parent: Node3D, name: String, radius: float, position: Vector3, material: Material, scale_override := Vector3.ONE) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 8
	mesh.rings = 5
	var instance := MeshInstance3D.new()
	instance.name = name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	instance.scale = scale_override
	parent.add_child(instance)
	return instance


static func add_label(visual_root: Node3D, display_name: String, recipe: Dictionary) -> void:
	var hair: Dictionary = recipe.get("hair", {}) as Dictionary
	var outfit: Dictionary = recipe.get("outfit", {}) as Dictionary
	var skin: Dictionary = recipe.get("skin", {}) as Dictionary
	var label := Label3D.new()
	label.name = "NpcBipedRecipeLabel"
	label.text = "%s\n%s | %s | %s" % [display_name, String(skin.get("id", "skin")).replace("_", " "), String(hair.get("style", "hair")), String(outfit.get("design", "outfit")).replace("_", " ")]
	label.position = Vector3(0.0, 2.30 * float(recipe.get("stature", 1.0)), 0.0)
	label.font_size = 30
	label.outline_size = 4
	label.modulate = Color("e9f5ff")
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = false
	visual_root.add_child(label)


static func make_material(color: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material
