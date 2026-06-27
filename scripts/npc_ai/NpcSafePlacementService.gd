extends RefCounted
class_name NpcSafePlacementService

const CharacterMotorProfileScript := preload("res://scripts/npc_ai/contracts/CharacterMotorProfile.gd")
const NpcConstantsScript := preload("res://scripts/npc_ai/NpcConstants.gd")

var system
var main

func setup(system_node, main_node) -> void:
	system = system_node
	main = main_node

func place_spawn(body: CharacterBody3D, requested_position: Vector3, profile = null, reason := "spawn") -> Dictionary:
	if body == null:
		return result(false, requested_position, "missing_body")
	var motor_profile = profile if profile != null else CharacterMotorProfileScript.npc_default()
	var position := requested_position
	if main != null and main.has_method("height_at_world"):
		var ground_y: float = main.call("height_at_world", position.x, position.z)
		position.y = maxf(position.y, ground_y)
	var validation := validate_capsule(body, position, motor_profile)
	if not bool(validation.get("ok", false)):
		return result(false, position, String(validation.get("reason", "invalid_capsule")))
	if body.is_inside_tree():
		body.global_position = position
	else:
		body.position = position
	body.velocity = Vector3.ZERO
	body.set_meta("npc_safe_placement_reason", reason)
	body.set_meta("npc_safe_placement_validated", true)
	return result(true, position, "")

func validate_capsule(body: CharacterBody3D, position: Vector3, profile = null) -> Dictionary:
	if body == null:
		return { "ok": false, "reason": "missing_body" }
	if not position.is_finite():
		return { "ok": false, "reason": "non_finite_position" }
	if body.get_world_3d() == null:
		return { "ok": true, "reason": "no_world" }
	var motor_profile = profile if profile != null else CharacterMotorProfileScript.npc_default()
	var shape := CapsuleShape3D.new()
	shape.radius = float(motor_profile.get("capsule_radius"))
	shape.height = float(motor_profile.get("capsule_height"))
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis(), position + Vector3(0.0, float(motor_profile.get("capsule_height")) * 0.5, 0.0))
	query.collision_mask = NpcConstantsScript.COLLISION_NPC_SAFE_PLACEMENT_MASK
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = [body.get_rid()]
	var hits: Array = body.get_world_3d().direct_space_state.intersect_shape(query, 12)
	for hit in hits:
		var hit_dict: Dictionary = hit
		var collider := hit_dict.get("collider") as Node
		if collider == null or collider == body:
			continue
		var kind := String(collider.get_meta("kind", ""))
		if kind == "terrain":
			continue
		var block_type := String(collider.get_meta("block_type", ""))
		if kind == "block" and block_type in ["cobblestonePath", "torch"]:
			continue
		return { "ok": false, "reason": "occupied_capsule", "collider": collider.name }
	return { "ok": true, "reason": "" }

func result(ok: bool, position: Vector3, reason: String) -> Dictionary:
	return {
		"ok": ok,
		"position": position,
		"reason": reason
	}
