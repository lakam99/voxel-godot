extends RefCounted
class_name MotionContactResolution

## A deterministic geometric fact emitted by a contact resolver. It has no
## damage, hit reaction, actor, item, or presentation responsibilities.

var resolved := false
var geometry_id := ""
var instance_id := ""
var normalized_time := 0.0
var phase := "inactive"
var source_id := ""
var contact_point := Vector3.ZERO
var contact_normal := Vector3.UP
var overlap_depth := 0.0


func _init(values: Dictionary = {}) -> void:
	resolved = bool(values.get("resolved", false))
	geometry_id = String(values.get("geometryId", ""))
	instance_id = String(values.get("instanceId", ""))
	normalized_time = float(values.get("normalizedTime", 0.0))
	phase = String(values.get("phase", "inactive"))
	source_id = String(values.get("sourceId", ""))
	contact_point = values.get("contactPoint", Vector3.ZERO) as Vector3
	contact_normal = values.get("contactNormal", Vector3.UP) as Vector3
	overlap_depth = maxf(0.0, float(values.get("overlapDepth", 0.0)))


func event_key() -> String:
	return "%s:%s" % [instance_id, geometry_id]


func snapshot() -> Dictionary:
	return {
		"resolved": resolved,
		"geometryId": geometry_id,
		"instanceId": instance_id,
		"normalizedTime": normalized_time,
		"phase": phase,
		"sourceId": source_id,
		"contactPoint": contact_point,
		"contactNormal": contact_normal,
		"overlapDepth": overlap_depth,
		"eventKey": event_key()
	}
