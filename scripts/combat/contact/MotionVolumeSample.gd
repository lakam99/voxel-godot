extends RefCounted
class_name MotionVolumeSample

## One local capsule-style contact envelope sampled from a MotionSample. This
## is geometry data only; later systems may consume it for presentation or
## queries, but it never performs either itself.

var instance_id := ""
var anchor_id := ""
var normalized_time := 0.0
var local_time := 0.0
var phase := "inactive"
var shape_id := ""
var active := false
var segment_start := Vector3.ZERO
var segment_end := Vector3.ZERO
var radius := 0.0
var facing := Vector3.FORWARD


func _init(values: Dictionary = {}) -> void:
	instance_id = String(values.get("instanceId", ""))
	anchor_id = String(values.get("anchorId", ""))
	normalized_time = float(values.get("normalizedTime", 0.0))
	local_time = float(values.get("localTime", 0.0))
	phase = String(values.get("phase", "inactive"))
	shape_id = String(values.get("shapeId", ""))
	active = bool(values.get("active", false))
	segment_start = values.get("segmentStart", Vector3.ZERO) as Vector3
	segment_end = values.get("segmentEnd", Vector3.ZERO) as Vector3
	radius = float(values.get("radius", 0.0))
	facing = values.get("facing", Vector3.FORWARD) as Vector3


func snapshot() -> Dictionary:
	return {
		"instanceId": instance_id,
		"anchorId": anchor_id,
		"normalizedTime": normalized_time,
		"localTime": local_time,
		"phase": phase,
		"shapeId": shape_id,
		"active": active,
		"segmentStart": segment_start,
		"segmentEnd": segment_end,
		"radius": radius,
		"facing": facing
	}
