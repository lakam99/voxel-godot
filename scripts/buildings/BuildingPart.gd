extends RefCounted
class_name BuildingPart

## Immutable construction record. The same record drives the part's visual
## recipe, physical volume and later its support/save representation.

var _publication_sealed := false
var _publication_revision := 0

var id := "":
	set(value):
		id = value
		if _publication_sealed: _publication_revision += 1
var kind := "":
	set(value):
		kind = value
		if _publication_sealed: _publication_revision += 1
var material_id := "":
	set(value):
		material_id = value
		if _publication_sealed: _publication_revision += 1
var position := Vector3.ZERO:
	set(value):
		position = value
		if _publication_sealed: _publication_revision += 1
var rotation := Vector3.ZERO:
	set(value):
		rotation = value
		if _publication_sealed: _publication_revision += 1
var size := Vector3.ONE:
	set(value):
		size = value
		if _publication_sealed: _publication_revision += 1
var collision_enabled := true:
	set(value):
		collision_enabled = value
		if _publication_sealed: _publication_revision += 1
var semantic := "":
	set(value):
		semantic = value
		if _publication_sealed: _publication_revision += 1
var physical_intent := "":
	set(value):
		physical_intent = value
		if _publication_sealed: _publication_revision += 1
var recipe: Dictionary = {}:
	set(value):
		recipe = value
		if _publication_sealed: _publication_revision += 1


## Called only on a freshly restored, exclusively worker-owned record. The
## compiler supplies an isolated deeply frozen recipe. Later scalar/replacement
## writes invalidate receipts even if the writer restores the previous value.
func seal_for_publication(frozen_recipe: Dictionary) -> int:
	if _publication_sealed or not frozen_recipe.is_read_only(): return -1
	recipe = frozen_recipe
	_publication_sealed = true
	return _publication_revision


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
