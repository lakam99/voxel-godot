extends Node
class_name MotionEquipmentAdapter

const MotionVolumeSampleScript := preload("res://scripts/combat/contact/MotionVolumeSample.gd")
const ItemVisualFactoryScript := preload("res://scripts/ItemVisualFactory.gd")

## Bridges one rig profile's semantic lead sockets to an item profile. It owns
## neither a motion recipe nor combat resolution: it exposes the equipped
## item's measured contact segment so the existing runtime can sample it.

var source_body: Node3D
var skeleton: Skeleton3D
var rig_profile
var equipment_profile
var validation: Dictionary = {}
var sockets_by_role: Dictionary = {}
var item_roots_by_role: Dictionary = {}
var grip_locals_by_role: Dictionary = {}
var grip_nodes_by_role: Dictionary = {}
var bound_runtime: Node


func configure(next_body: Node3D, next_skeleton: Skeleton3D, next_rig_profile, next_equipment_profile) -> Dictionary:
	source_body = next_body
	skeleton = next_skeleton
	rig_profile = next_rig_profile
	equipment_profile = next_equipment_profile
	validation = validate_configuration()
	if not bool(validation.get("valid", false)):
		return validation.duplicate(true)
	for role in ["lead_left", "lead_right"]:
		add_socket_for_role(role)
	if source_body != null and is_instance_valid(source_body):
		source_body.set_meta("motion_contact_provider", self)
	return validation.duplicate(true)


func validate_configuration() -> Dictionary:
	var errors: Array[String] = []
	if source_body == null or not is_instance_valid(source_body):
		errors.append("missing source body")
	if skeleton == null or not is_instance_valid(skeleton):
		errors.append("missing Skeleton3D")
	if rig_profile == null:
		errors.append("missing MotionRigProfile")
	if equipment_profile == null:
		errors.append("missing MotionEquipmentProfile")
	if errors.is_empty():
		for role in ["lead_left", "lead_right"]:
			var bindings: Array = rig_profile.bindings_for(role)
			if bindings.is_empty():
				errors.append("missing semantic socket role '%s'" % role)
				continue
			var bone := String((bindings[0] as Dictionary).get("bone", ""))
			if skeleton.find_bone(bone) < 0:
				errors.append("socket role '%s' references absent bone '%s'" % [role, bone])
	return {"valid": errors.is_empty(), "errors": errors}


func add_socket_for_role(role: String) -> void:
	if sockets_by_role.has(role):
		return
	var bindings: Array = rig_profile.bindings_for(role)
	if bindings.is_empty():
		return
	var bone_name := String((bindings[0] as Dictionary).get("bone", ""))
	var attachment := Node3D.new()
	attachment.name = "MotionEquipmentSocket_%s" % role
	source_body.add_child(attachment)
	var socket := Node3D.new()
	socket.name = "EquipmentAnchor"
	# The attachment itself is positioned at the profile's bone-relative socket
	# in sync_socket_transform(). Keep this child at its origin so the visual
	# does not receive that offset a second time and float beyond the hand.
	socket.position = Vector3.ZERO
	attachment.add_child(socket)
	var item_root := Node3D.new()
	item_root.name = "EquippedMotionItem_%s" % equipment_profile.item_id
	var item_basis := Basis.from_euler(equipment_profile.item_rotation)
	item_root.position = -(item_basis * equipment_profile.item_grip_local)
	item_root.basis = item_basis
	var visual_factory = ItemVisualFactoryScript.new()
	socket.add_child(item_root)
	visual_factory.build_item(item_root, equipment_profile.item_id, false)
	var grip_node = resolved_item_grip_node(item_root)
	var grip_local: Vector3 = local_position_from_item_root(item_root, grip_node) if grip_node != null else equipment_profile.item_grip_local
	# The item's true visual grip is the authority for its attachment. Its local
	# point is transformed by the selected item orientation into the socket, so
	# the hilt stays in the hand while the arm moves through any shared motion.
	item_root.position = -(item_basis * grip_local)
	attachment.visible = role == "lead_right"
	sockets_by_role[role] = attachment
	item_roots_by_role[role] = item_root
	grip_locals_by_role[role] = grip_local
	grip_nodes_by_role[role] = grip_node
	sync_socket_transform(role)


func bind_motion_runtime(runtime: Node) -> void:
	if bound_runtime != null and is_instance_valid(bound_runtime):
		if bound_runtime.has_signal("motion_started") and bound_runtime.motion_started.is_connected(_on_motion_started):
			bound_runtime.motion_started.disconnect(_on_motion_started)
		if bound_runtime.has_signal("motion_pose_signals") and bound_runtime.motion_pose_signals.is_connected(_on_motion_pose_signals):
			bound_runtime.motion_pose_signals.disconnect(_on_motion_pose_signals)
		if bound_runtime.has_signal("motion_finished") and bound_runtime.motion_finished.is_connected(_on_motion_finished):
			bound_runtime.motion_finished.disconnect(_on_motion_finished)
	bound_runtime = runtime
	if bound_runtime == null or not is_instance_valid(bound_runtime):
		return
	if bound_runtime.has_signal("motion_started"):
		bound_runtime.motion_started.connect(_on_motion_started)
	if bound_runtime.has_signal("motion_pose_signals"):
		bound_runtime.motion_pose_signals.connect(_on_motion_pose_signals)
	if bound_runtime.has_signal("motion_finished"):
		bound_runtime.motion_finished.connect(_on_motion_finished)


func _exit_tree() -> void:
	bind_motion_runtime(null)
	if source_body != null and is_instance_valid(source_body) and source_body.get_meta("motion_contact_provider", null) == self:
		source_body.remove_meta("motion_contact_provider")


func _on_motion_started(body, _target, _target_kind: String, _variant: String, summary: Dictionary) -> void:
	if body != source_body:
		return
	# This is deliberately a semantic hand selection, not a biped/weapon rule.
	# The motion runtime provides the sampled side; each compatible rig resolves
	# its own lead appendage and equips the same item to it before wind-up.
	prepare_for_motion_side(float(summary.get("leadMotionSide", 1.0)))


func _on_motion_pose_signals(body, signals: Array, _summary: Dictionary) -> void:
	if body != source_body or signals.is_empty():
		return
	prepare_for_motion_side(float(signals[0].side))


func prepare_for_motion_side(side: float) -> void:
	if rig_profile == null:
		return
	show_lead_socket(rig_profile.resolved_role("lead_appendage", side))
	sync_socket_transforms()


func visible_lead_role() -> String:
	for role_value in sockets_by_role.keys():
		var attachment = sockets_by_role.get(role_value) as Node3D
		if attachment != null and is_instance_valid(attachment) and attachment.visible:
			return String(role_value)
	return ""


func _on_motion_finished(body, _summary: Dictionary) -> void:
	if body == source_body:
		show_lead_socket("lead_right")


func show_lead_socket(active_role: String) -> void:
	for role_value in sockets_by_role.keys():
		var attachment = sockets_by_role.get(role_value) as Node3D
		if attachment != null and is_instance_valid(attachment):
			attachment.visible = String(role_value) == active_role


func sync_socket_transforms() -> void:
	for role_value in sockets_by_role.keys():
		sync_socket_transform(String(role_value))


func sync_socket_transform(role: String) -> void:
	if skeleton == null or not is_instance_valid(skeleton) or rig_profile == null or equipment_profile == null:
		return
	var attachment = sockets_by_role.get(role, null) as Node3D
	var bindings: Array = rig_profile.bindings_for(role)
	if attachment == null or not is_instance_valid(attachment) or bindings.is_empty():
		return
	var bone_name := String((bindings[0] as Dictionary).get("bone", ""))
	var bone_index := skeleton.find_bone(bone_name)
	if bone_index < 0:
		return
	var socket_transform := skeleton.get_bone_global_pose(bone_index) * Transform3D(Basis.IDENTITY, equipment_profile.socket_offset)
	# Arena catalogue construction happens before the body enters SceneTree. Keep
	# this setup local until then; normal motion signals update the world transform
	# once the visual is live, avoiding an invalid early global-transform query.
	if attachment.is_inside_tree():
		attachment.global_transform = skeleton.global_transform * socket_transform
	else:
		attachment.transform = socket_transform


func sample_contact_volume(motion_sample, volume_recipe):
	if not bool(validation.get("valid", false)) or motion_sample == null:
		return MotionVolumeSampleScript.new()
	var role: String = String(rig_profile.resolved_role("lead_appendage", motion_sample.direction))
	sync_socket_transform(role)
	var attachment = sockets_by_role.get(role, null) as Node3D
	if attachment == null or not is_instance_valid(attachment):
		return MotionVolumeSampleScript.new()
	var active: bool = bool(motion_sample.active) and volume_recipe != null and volume_recipe.allows_phase(String(motion_sample.phase)) and equipment_profile.allows_phase(String(motion_sample.phase))
	return MotionVolumeSampleScript.new({
		"instanceId": motion_sample.instance_id,
		"anchorId": "%s:%s" % [motion_sample.anchor_id, equipment_profile.id],
		"normalizedTime": motion_sample.normalized_time,
		"localTime": motion_sample.local_time,
		"phase": motion_sample.phase,
		"shapeId": "equipped_segment",
		"active": active,
		"segmentStart": attachment.to_global(equipment_profile.contact_base_offset),
		"segmentEnd": attachment.to_global(equipment_profile.contact_tip_offset),
		"radius": equipment_profile.contact_radius,
		"facing": motion_sample.facing
	})


func grip_position_for_motion(motion_sample) -> Vector3:
	if not bool(validation.get("valid", false)) or motion_sample == null:
		return Vector3.ZERO
	var role: String = String(rig_profile.resolved_role("lead_appendage", motion_sample.direction))
	sync_socket_transform(role)
	var item_root = item_roots_by_role.get(role, null) as Node3D
	var grip_local: Vector3 = grip_locals_by_role.get(role, equipment_profile.item_grip_local) as Vector3
	return item_root.to_global(grip_local) if item_root != null and is_instance_valid(item_root) else Vector3.ZERO


func socket_position_for_motion(motion_sample) -> Vector3:
	if not bool(validation.get("valid", false)) or motion_sample == null:
		return Vector3.ZERO
	var role: String = String(rig_profile.resolved_role("lead_appendage", motion_sample.direction))
	sync_socket_transform(role)
	var attachment = sockets_by_role.get(role, null) as Node3D
	return attachment.global_position if attachment != null and is_instance_valid(attachment) else Vector3.ZERO


func has_visual_grip_anchor_for_motion(motion_sample) -> bool:
	if not bool(validation.get("valid", false)) or motion_sample == null:
		return false
	var role: String = String(rig_profile.resolved_role("lead_appendage", motion_sample.direction))
	var grip_node = grip_nodes_by_role.get(role, null) as Node3D
	return grip_node != null and is_instance_valid(grip_node)


func resolved_item_grip_node(item_root: Node3D):
	if item_root == null or not is_instance_valid(item_root) or equipment_profile.item_grip_node_path.is_empty():
		return null
	var direct = item_root.get_node_or_null(NodePath(equipment_profile.item_grip_node_path)) as Node3D
	if direct != null:
		return direct
	# Imported GLB wrappers may insert an extra root node. Resolve by the final
	# declared anchor name so a profile stays stable across that harmless layout.
	var anchor_name: String = equipment_profile.item_grip_node_path.get_file()
	return item_root.find_child(anchor_name, true, false) as Node3D if not anchor_name.is_empty() else null


func local_position_from_item_root(item_root: Node3D, child: Node3D) -> Vector3:
	var relative := Transform3D.IDENTITY
	var current: Node = child
	while current != null and current != item_root:
		if not (current is Node3D):
			return equipment_profile.item_grip_local
		relative = (current as Node3D).transform * relative
		current = current.get_parent()
	return relative.origin if current == item_root else equipment_profile.item_grip_local


func diagnostics() -> Dictionary:
	return {
		"validation": validation.duplicate(true),
		"profile": equipment_profile.snapshot() if equipment_profile != null else {},
		"socketRoles": sockets_by_role.keys()
	}
