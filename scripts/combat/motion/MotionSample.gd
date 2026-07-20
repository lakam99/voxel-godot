extends RefCounted
class_name MotionSample

## One sampled instant of a motion. Coordinates are local to a caller-provided
## anchor frame; this object intentionally has no Node or gameplay dependency.

var instance_id := ""
var anchor_id := ""
var normalized_time := 0.0
var local_time := 0.0
var phase := "inactive"
var active := false
var origin := Vector3.ZERO
var tip := Vector3.ZERO
var facing := Vector3.FORWARD


func _init(values: Dictionary = {}) -> void:
	instance_id = String(values.get("instanceId", ""))
	anchor_id = String(values.get("anchorId", ""))
	normalized_time = float(values.get("normalizedTime", 0.0))
	local_time = float(values.get("localTime", 0.0))
	phase = String(values.get("phase", "inactive"))
	active = bool(values.get("active", false))
	origin = values.get("origin", Vector3.ZERO) as Vector3
	tip = values.get("tip", Vector3.ZERO) as Vector3
	facing = values.get("facing", Vector3.FORWARD) as Vector3


func snapshot() -> Dictionary:
	return {
		"instanceId": instance_id,
		"anchorId": anchor_id,
		"normalizedTime": normalized_time,
		"localTime": local_time,
		"phase": phase,
		"active": active,
		"origin": origin,
		"tip": tip,
		"facing": facing
	}
