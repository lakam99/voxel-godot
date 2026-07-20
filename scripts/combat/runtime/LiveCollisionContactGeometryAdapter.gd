extends RefCounted
class_name LiveCollisionContactGeometryAdapter

const PassiveContactSphereScript := preload("res://scripts/combat/contact/PassiveContactSphere.gd")

## Runtime-only conversion from an actor's existing CollisionShape3D authority
## to the passive sphere geometry accepted by the pure motion resolver. It does
## not query physics, change actors, select targets, or apply consequences.

static func passive_spheres_for_body(body: Node3D, target_id: String) -> Array:
	var result: Array = []
	if body == null or not is_instance_valid(body):
		return result
	for collider in collision_shapes_for_body(body):
		if collider.disabled or collider.shape == null:
			continue
		if collider.shape is CapsuleShape3D:
			return capsule_passive_spheres(collider, target_id)
		if collider.shape is SphereShape3D:
			var sphere := collider.shape as SphereShape3D
			var radius := sphere.radius * maximum_axis_scale(collider.global_transform.basis)
			result.append(PassiveContactSphereScript.new({
				"geometryId": "%s:sphere" % target_id,
				"center": collider.global_position,
				"radius": radius
			}))
			return result
	return result


static func collision_shapes_for_body(body: Node3D) -> Array[CollisionShape3D]:
	var result: Array[CollisionShape3D] = []
	var pending: Array[Node] = [body]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		if node == null or not is_instance_valid(node):
			continue
		var collider := node as CollisionShape3D
		if collider != null:
			result.append(collider)
			continue
		for child in node.get_children():
			if child is Node:
				pending.append(child)
	return result


static func capsule_passive_spheres(collider: CollisionShape3D, target_id: String) -> Array:
	var shape := collider.shape as CapsuleShape3D
	var scale := maximum_axis_scale(collider.global_transform.basis)
	var radius := shape.radius * scale
	var half_axis := maxf(0.0, (shape.height * scale - radius * 2.0) * 0.5)
	var axis := collider.global_transform.basis * Vector3.UP
	axis = axis.normalized() if axis.length_squared() > 0.0000001 else Vector3.UP
	var centers: Array[Vector3] = [
		collider.global_position - axis * half_axis,
		collider.global_position,
		collider.global_position + axis * half_axis
	]
	var result: Array = []
	for index in range(centers.size()):
		result.append(PassiveContactSphereScript.new({
			"geometryId": "%s:capsule:%d" % [target_id, index],
			"center": centers[index],
			"radius": radius
		}))
	return result


static func maximum_axis_scale(basis: Basis) -> float:
	var scale := basis.get_scale()
	return maxf(0.01, maxf(absf(scale.x), maxf(absf(scale.y), absf(scale.z))))
