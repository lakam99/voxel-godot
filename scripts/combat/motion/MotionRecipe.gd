extends RefCounted
class_name MotionRecipe

## Immutable, engine-unplugged description of one procedural motion.
##
## A recipe has no knowledge of an attacker, weapon, rig, scene, collision, or
## combat result. It is just stable input for the mathematical sampler.

var primitive_id: String
var seed: int
var parameters: Dictionary


func _init(next_primitive_id: String, next_seed: int, next_parameters: Dictionary = {}) -> void:
	primitive_id = next_primitive_id.strip_edges().to_lower()
	seed = next_seed
	parameters = next_parameters.duplicate(true)


func value(key: String, fallback = null):
	return parameters.get(key, fallback)


func snapshot() -> Dictionary:
	return {
		"primitiveId": primitive_id,
		"seed": seed,
		"parameters": parameters.duplicate(true)
	}
