extends RefCounted
class_name HostileBehaviorIntent

## Pure output from a hostile behavior policy. The intent never has a scene
## reference; a motor executor later turns it into real body movement.

var kind := "hold"
var reason := "idle"
var motion_kind := ""
var speed := 0.0
var orbit_direction := 1.0
var direction := Vector3.ZERO


func _init(values: Dictionary = {}) -> void:
	kind = String(values.get("kind", kind)).strip_edges().to_lower()
	reason = String(values.get("reason", reason))
	motion_kind = String(values.get("motionKind", motion_kind)).strip_edges().to_lower()
	speed = maxf(0.0, float(values.get("speed", speed)))
	orbit_direction = -1.0 if float(values.get("orbitDirection", orbit_direction)) < 0.0 else 1.0
	direction = values.get("direction", direction) as Vector3


func snapshot() -> Dictionary:
	return {
		"kind": kind,
		"reason": reason,
		"motionKind": motion_kind,
		"speed": speed,
		"orbitDirection": orbit_direction,
		"direction": direction
	}
