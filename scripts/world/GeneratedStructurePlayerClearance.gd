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
	for index in range(result.get_collision_count()):
		maximum = maxf(maximum,result.get_collision_depth(index))
	return {"passed":maximum <= body.safe_margin + 0.000001,
		"reason":"player_capsule_clear" if maximum <= body.safe_margin + 0.000001 else "player_capsule_overlaps_completed_world",
		"maximumPenetration":maximum,"safeMargin":body.safe_margin,"contactCount":result.get_collision_count()}
