extends RefCounted

## Conservative fixture-level occupancy check for a declared replacement region.
## The caller must supply the complete live actor set and hold admission while
## the owner switches shapes; this helper does not establish either contract.
static func inspect(actors: Array, affected_bounds: AABB, forecast_seconds: float) -> Dictionary:
	if not affected_bounds.position.is_finite() or not affected_bounds.size.is_finite() \
			or affected_bounds.size.x <= 0.0 or affected_bounds.size.y <= 0.0 \
			or affected_bounds.size.z <= 0.0 or not is_finite(forecast_seconds) \
			or forecast_seconds < 0.0 or forecast_seconds > 1.0:
		return {"clear": false, "reason": "invalid_guard_region"}
	for actor in actors:
		if not actor is PhysicsBody3D or not is_instance_valid(actor) \
				or not actor.is_inside_tree() or actor.is_queued_for_deletion():
			return {"clear": false, "reason": "actor_registry_invalid"}
		var body: PhysicsBody3D = actor
		var has_shape := false
		for child in body.get_children():
			if not child is CollisionShape3D:
				continue
			var collision_shape: CollisionShape3D = child
			if collision_shape.disabled or collision_shape.shape == null:
				continue
			var mesh := collision_shape.shape.get_debug_mesh()
			if mesh == null:
				return {"clear": false, "reason": "actor_shape_bounds_unavailable"}
			has_shape = true
			var current: AABB = collision_shape.global_transform * mesh.get_aabb()
			var velocity := (body as CharacterBody3D).velocity if body is CharacterBody3D else Vector3.ZERO
			var predicted := AABB(current.position + velocity * forecast_seconds, current.size)
			if current.merge(predicted).intersects(affected_bounds):
				return {"clear": false, "reason": "actor_occupies_replacement", "actorId": body.get_instance_id()}
		if not has_shape:
			return {"clear": false, "reason": "actor_without_collision_shape"}
	return {"clear": true, "actorCount": actors.size()}


static func motion_intersects(actor: PhysicsBody3D, affected_bounds: AABB,
		motion: Vector3) -> bool:
	if actor == null or not is_instance_valid(actor) or not motion.is_finite():
		return true
	var has_shape := false
	for child in actor.get_children():
		if not child is CollisionShape3D:
			continue
		var collision_shape: CollisionShape3D = child
		if collision_shape.disabled or collision_shape.shape == null:
			continue
		var mesh := collision_shape.shape.get_debug_mesh()
		if mesh == null:
			return true
		has_shape = true
		var current: AABB = collision_shape.global_transform * mesh.get_aabb()
		if current.merge(AABB(current.position + motion, current.size)).intersects(affected_bounds):
			return true
	return not has_shape


static func placement_intersects(actor: PhysicsBody3D, affected_bounds: AABB,
		proposed_transform: Transform3D) -> bool:
	if actor == null or not is_instance_valid(actor) \
			or not proposed_transform.origin.is_finite() \
			or not proposed_transform.basis.is_finite():
		return true
	var has_shape := false
	for child in actor.get_children():
		if not child is CollisionShape3D:
			continue
		var collision_shape: CollisionShape3D = child
		if collision_shape.disabled or collision_shape.shape == null:
			continue
		var mesh := collision_shape.shape.get_debug_mesh()
		if mesh == null:
			return true
		has_shape = true
		if (proposed_transform * collision_shape.transform * mesh.get_aabb()).intersects(affected_bounds):
			return true
	return not has_shape
