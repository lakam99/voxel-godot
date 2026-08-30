extends RefCounted
class_name BuildingPart

## Immutable construction record. The same record drives the part's visual
## recipe, physical volume and later its support/save representation.

var id := ""
var kind := ""
var material_id := ""
var position := Vector3.ZERO
var rotation := Vector3.ZERO
var size := Vector3.ONE
var collision_enabled := true
var semantic := ""
var physical_intent := ""
var recipe: Dictionary = {}


func _init(values: Dictionary = {}) -> void:
	id = String(values.get("id", "")).strip_edges()
	kind = String(values.get("kind", "")).strip_edges().to_lower()
	material_id = String(values.get("material", "stone_foundation")).strip_edges().to_lower()
	position = values.get("position", Vector3.ZERO) as Vector3
	rotation = values.get("rotation", Vector3.ZERO) as Vector3
	size = values.get("size", Vector3.ONE) as Vector3
	size = Vector3(maxf(0.02, size.x), maxf(0.02, size.y), maxf(0.02, size.z))
	collision_enabled = bool(values.get("collision", true))
	semantic = String(values.get("semantic", kind)).strip_edges().to_lower()
	recipe = (values.get("recipe", {}) as Dictionary).duplicate(true)
	physical_intent = String(recipe.get("physicalIntent", values.get("physicalIntent", ""))).strip_edges().to_lower()


func snapshot() -> Dictionary:
	return {
		"id": id,
		"kind": kind,
		"material": material_id,
		"position": position,
		"rotation": rotation,
		"size": size,
		"collision": collision_enabled,
		"semantic": semantic,
		"physicalIntent": physical_intent,
		"recipe": recipe.duplicate(true)
	}
