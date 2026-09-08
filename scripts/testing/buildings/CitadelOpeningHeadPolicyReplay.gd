extends "res://scripts/testing/buildings/CitadelOpeningHeadOrderedReplay.gd"
const Facades = preload("res://scripts/buildings/CitadelFacadeCompletionRecipe.gd")
func _input_path() -> String: return "res://artifacts/citadel-runtime-integration/candidate21-policy-capture-01/input.bin"
func _input_sha() -> String: return "d6df2eeff4044d85d41cd46e1dc9b200740a01b3abd36455b6536ceb3514a903"
func _policy(input: Dictionary) -> Dictionary:
	return {"furnitureParts": input.policy.furnitureParts.duplicate(true), "reservedVolumes": input.policy.reservedVolumes.duplicate(true), "requiredHeadroom": Facades.REQUIRED_HEADROOM}
func _scope() -> String: return "Exact captured production source and furnishing policy, ordered opening-head geometry/bearing/occupancy/clearance staging. No later structural completion, full candidate, publication, rendering or gameplay acceptance."
