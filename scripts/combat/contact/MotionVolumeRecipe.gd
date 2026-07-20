extends RefCounted
class_name MotionVolumeRecipe

## Immutable, engine-unplugged contact-envelope description. The recipe says
## how an existing motion sample maps to a generic local volume; it has no
## target, collision, damage, character, or gameplay knowledge.

var shape_id: String
var seed: int
var parameters: Dictionary
var active_phases: Array[String] = []


func _init(next_shape_id: String, next_seed: int, next_parameters: Dictionary = {}) -> void:
	shape_id = next_shape_id.strip_edges().to_lower()
	seed = next_seed
	parameters = next_parameters.duplicate(true)
	for raw_phase in parameters.get("activePhases", ["arc"]):
		var phase := String(raw_phase).strip_edges().to_lower()
		if not phase.is_empty() and not active_phases.has(phase):
			active_phases.append(phase)
	parameters["activePhases"] = active_phases.duplicate()


func value(key: String, fallback = null):
	return parameters.get(key, fallback)


func allows_phase(phase: String) -> bool:
	return active_phases.has(phase.strip_edges().to_lower())


func snapshot() -> Dictionary:
	return {
		"shapeId": shape_id,
		"seed": seed,
		"parameters": parameters.duplicate(true)
	}
