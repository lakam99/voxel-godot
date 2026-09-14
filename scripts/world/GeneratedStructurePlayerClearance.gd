extends RefCounted
class_name GeneratedStructurePlayerClearance

## Observe the existing player's actual collision body without applying motion
## or recovery. Only the engine's ordinary safe margin is tolerated as contact.
static func inspect(body: CharacterBody3D) -> Dictionary:
	if not is_instance_valid(body) or not body.is_inside_tree() or body.get_world_3d() == null:
		return {"passed":false,"reason":"player_physics_body_missing"}
	var collider := body.get_node_or_null("PlayerCollider") as CollisionShape3D
	if collider == null or collider.disabled or not collider.shape is CapsuleShape3D:
		return {"passed":false,"reason":"player_capsule_missing"}
	var parameters := PhysicsTestMotionParameters3D.new()
	parameters.from = body.global_transform
	parameters.motion = Vector3.ZERO
	parameters.margin = body.safe_margin
	parameters.recovery_as_collision = true
	parameters.max_collisions = 32
	var result := PhysicsTestMotionResult3D.new()
	PhysicsServer3D.body_test_motion(body.get_rid(),parameters,result)
	var maximum := 0.0
	var contacts: Array[Dictionary] = []
	for index in range(result.get_collision_count()):
		var depth := result.get_collision_depth(index)
		maximum = maxf(maximum,depth)
		contacts.append(_contact_receipt(result,index,depth))
	return {"passed":maximum <= body.safe_margin + 0.000001,
		"reason":"player_capsule_clear" if maximum <= body.safe_margin + 0.000001 else "player_capsule_overlaps_completed_world",
		"maximumPenetration":maximum,"safeMargin":body.safe_margin,"contactCount":result.get_collision_count(),"contacts":contacts}


## Keep the receipt JSON-safe so a headed diagnostic can identify the physical
## owner of an overlap without changing how the query or its tolerance behaves.
static func _contact_receipt(result: PhysicsTestMotionResult3D, index: int, depth: float) -> Dictionary:
	var point := result.get_collision_point(index)
	var normal := result.get_collision_normal(index)
	var receipt: Dictionary = {
		"index":index,
		"depth":depth,
		"point":{"x":point.x,"y":point.y,"z":point.z},
		"normal":{"x":normal.x,"y":normal.y,"z":normal.z},
		"colliderInstanceId":0,
		"colliderRid":"",
		"colliderName":"",
		"colliderPath":""
	}
	if result.has_method("get_collider_rid"):
		receipt["colliderRid"] = str(result.get_collider_rid(index))
	if not result.has_method("get_collider"):
		return receipt
	var collision_collider = result.get_collider(index)
	if collision_collider == null or not is_instance_valid(collision_collider):
		if result.has_method("get_collider_id"):
			receipt["colliderInstanceId"] = result.get_collider_id(index)
		return receipt
	receipt["colliderInstanceId"] = collision_collider.get_instance_id()
	var collider_node := collision_collider as Node
	if collider_node == null:
		return receipt
	receipt["colliderName"] = String(collider_node.name)
	if collider_node.is_inside_tree():
		receipt["colliderPath"] = String(collider_node.get_path())
	receipt["structureParts"] = _structure_parts_at_contact(collider_node,point)
	return receipt

static func _structure_parts_at_contact(collider: Node, point: Vector3) -> Array[Dictionary]:
	var matches: Array[Dictionary] = []
	for child in collider.get_children():
		var shape_node := child as CollisionShape3D
		var box := shape_node.shape as BoxShape3D if shape_node != null else null
		if box == null or shape_node.disabled: continue
		var local := shape_node.global_transform.affine_inverse() * point
		var half := box.size * 0.5 + Vector3(0.002,0.002,0.002)
		if absf(local.x)>half.x or absf(local.y)>half.y or absf(local.z)>half.z: continue
		matches.append({"id":String(shape_node.get_meta("building_part_id", "")),
			"kind":String(shape_node.get_meta("building_part_kind", "")),
			"semantic":String(shape_node.get_meta("building_semantic", "")),
			"role":String(shape_node.get_meta("building_collision_role", "")),"path":String(shape_node.get_path())})
	return matches
