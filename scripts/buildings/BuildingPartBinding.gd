extends RefCounted
## Immediate raw binding, not a snapshot or cache. The caller still owns the
## mutable part and its recipe; neither is retained, copied, frozen or rewritten.
const Part = preload("res://scripts/buildings/BuildingPart.gd")

static func encode(part) -> PackedByteArray:
	# Only this exact implementation has the known snapshot shape. Inherited,
	# overridden and duck-typed snapshots retain their original call dispatch.
	if part.get_script() != Part:
		return var_to_bytes(part.snapshot())
	return var_to_bytes({
		"id": part.id,
		"kind": part.kind,
		"material": part.material_id,
		"position": part.position,
		"rotation": part.rotation,
		"size": part.size,
		"collision": part.collision_enabled,
		"semantic": part.semantic,
		"physicalIntent": part.physical_intent,
		"recipe": part.recipe
	})
