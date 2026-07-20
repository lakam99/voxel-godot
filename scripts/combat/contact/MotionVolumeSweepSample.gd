extends RefCounted
class_name MotionVolumeSweepSample

## Consecutive contact envelopes expressed as a pure swept interval. Keeping
## both endpoints prevents a future query layer from treating fast motion as a
## set of disconnected instantaneous points.

var instance_id := ""
var normalized_time := 0.0
var active := false
var from_segment_start := Vector3.ZERO
var from_segment_end := Vector3.ZERO
var to_segment_start := Vector3.ZERO
var to_segment_end := Vector3.ZERO
var radius := 0.0


func _init(values: Dictionary = {}) -> void:
	instance_id = String(values.get("instanceId", ""))
	normalized_time = float(values.get("normalizedTime", 0.0))
	active = bool(values.get("active", false))
	from_segment_start = values.get("fromSegmentStart", Vector3.ZERO) as Vector3
	from_segment_end = values.get("fromSegmentEnd", Vector3.ZERO) as Vector3
	to_segment_start = values.get("toSegmentStart", Vector3.ZERO) as Vector3
	to_segment_end = values.get("toSegmentEnd", Vector3.ZERO) as Vector3
	radius = float(values.get("radius", 0.0))


func snapshot() -> Dictionary:
	return {
		"instanceId": instance_id,
		"normalizedTime": normalized_time,
		"active": active,
		"fromSegmentStart": from_segment_start,
		"fromSegmentEnd": from_segment_end,
		"toSegmentStart": to_segment_start,
		"toSegmentEnd": to_segment_end,
		"radius": radius
	}
