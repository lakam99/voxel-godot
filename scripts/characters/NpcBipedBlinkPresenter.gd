extends Node
class_name NpcBipedBlinkPresenter

## Visual-only eye closure.  The owning actor never receives state, movement,
## combat, or navigation writes from this component.

var eyes: Array[MeshInstance3D] = []
var blink_interval := 3.2
var blink_phase := 0.0
var elapsed := 0.0


func configure(next_eyes: Array[MeshInstance3D], seed_data: Dictionary) -> void:
	eyes = next_eyes.duplicate()
	blink_interval = maxf(0.75, float(seed_data.get("blinkInterval", 3.2)))
	blink_phase = fposmod(float(seed_data.get("blinkPhase", 0.0)), blink_interval)


func _process(delta: float) -> void:
	elapsed += maxf(0.0, delta)
	var phase := fposmod(elapsed + blink_phase, blink_interval)
	var blink_duration := 0.17
	var closure := sin(clampf(phase / blink_duration, 0.0, 1.0) * PI) if phase < blink_duration else 0.0
	for eye in eyes:
		if eye == null or not is_instance_valid(eye):
			continue
		eye.scale.y = lerpf(1.0, 0.08, closure)
