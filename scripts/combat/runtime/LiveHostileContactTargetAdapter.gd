extends RefCounted
class_name LiveHostileContactTargetAdapter

const LiveCollisionContactGeometryAdapterScript := preload("res://scripts/combat/runtime/LiveCollisionContactGeometryAdapter.gd")

## Runtime-only bridge from the existing hostile collision authority to the
## passive geometry consumed by the pure resolver. It does not query physics,
## mutate hostiles, choose damage, or make contact decisions. A hostile capsule
## becomes a small, overlapping sphere chain so the current generic resolver
## keeps its one-shape input while honouring the live collider's real extent.

static func targets_from_hostile_system(hostile_system) -> Array:
	var result: Array = []
	if hostile_system == null:
		return result
	var enemies = hostile_system.get("enemies")
	if not (enemies is Array):
		return result
	for enemy_value in enemies:
		if not (enemy_value is Dictionary):
			continue
		var enemy: Dictionary = enemy_value
		var body := enemy.get("body") as Node3D
		if body == null or not is_instance_valid(body) or not body.visible:
			continue
		var target_id := "hostile:%d" % body.get_instance_id()
		for passive_geometry in LiveCollisionContactGeometryAdapterScript.passive_spheres_for_body(body, target_id):
			result.append({
				"targetId": target_id,
				"geometry": passive_geometry,
				"body": body,
				"variant": String(enemy.get("variant", "shadow"))
			})
	return result
