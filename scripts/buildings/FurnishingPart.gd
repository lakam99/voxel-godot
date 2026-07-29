extends RefCounted
class_name FurnishingPart

## One semantic furnishing instance. Its occupied volume, visual recipe and
## collision intent travel together; individual boards, legs and decorations
## are publisher-owned detail, not separate furniture authorities.

var id := ""
var room_id := ""
var archetype := ""
var material_id := ""
var position := Vector3.ZERO
var rotation := Vector3.ZERO
var occupied_size := Vector3.ONE
var collision_enabled := true
var semantic := ""
var recipe: Dictionary = {}


func _init(values: Dictionary = {}) -> void:
	id = String(values.get("id", "")).strip_edges()
	room_id = String(values.get("roomId", "")).strip_edges()
	archetype = String(values.get("archetype", "")).strip_edges().to_lower()
	material_id = String(values.get("material", "timber_board")).strip_edges().to_lower()
	position = values.get("position", Vector3.ZERO) as Vector3
	rotation = values.get("rotation", Vector3.ZERO) as Vector3
	occupied_size = values.get("occupiedSize", Vector3.ONE) as Vector3
	occupied_size = Vector3(maxf(0.02, occupied_size.x), maxf(0.02, occupied_size.y), maxf(0.02, occupied_size.z))
	collision_enabled = bool(values.get("collision", true))
	semantic = String(values.get("semantic", archetype)).strip_edges().to_lower()
	recipe = (values.get("recipe", {}) as Dictionary).duplicate(true)


func snapshot() -> Dictionary:
	return {
		"id": id,
		"roomId": room_id,
		"archetype": archetype,
		"material": material_id,
		"position": position,
		"rotation": rotation,
		"occupiedSize": occupied_size,
		"collision": collision_enabled,
		"semantic": semantic,
		"recipe": recipe.duplicate(true)
	}
