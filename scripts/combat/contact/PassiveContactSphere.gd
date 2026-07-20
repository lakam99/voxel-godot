extends RefCounted
class_name PassiveContactSphere

## Immutable passive geometry used by isolated contact-resolution proofs.
## It represents only a bounded surface in local space, never an actor,
## collision object, health pool, or gameplay owner.

var geometry_id := ""
var center := Vector3.ZERO
var radius := 0.0


func _init(values: Dictionary = {}) -> void:
	geometry_id = String(values.get("geometryId", "passive_geometry"))
	center = values.get("center", Vector3.ZERO) as Vector3
	radius = clampf(float(values.get("radius", 0.25)), 0.01, 32.0)


func snapshot() -> Dictionary:
	return {
		"geometryId": geometry_id,
		"shapeId": "sphere",
		"center": center,
		"radius": radius
	}
