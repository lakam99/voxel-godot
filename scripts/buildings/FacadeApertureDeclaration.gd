extends RefCounted
const Part = preload("res://scripts/buildings/BuildingPart.gd")

## Bind a producer's aperture inputs to its emitted geometry. This is a stale
## data check, not a substitute for aperture/contact geometry validation.
static func seal(declaration: Dictionary, parts: Array) -> Dictionary:
	var result := declaration.duplicate(true)
	result["partIds"] = parts.map(func(part): return part.id)
	result["sourceBinding"] = _digest([result, parts.map(_geometry)])
	return result

static func validate(declaration: Variant, by_id: Dictionary) -> bool:
	if not declaration is Dictionary or not declaration.get("partIds") is Array or not declaration.get("sourceBinding") is String:
		return false
	if declaration.partIds.is_empty() or declaration.partIds.size() > 512: return false
	var parts: Array = []
	var seen: Dictionary = {}
	for id in declaration.partIds:
		if not id is String or seen.has(id) or not by_id.has(id) or not by_id[id] is Part: return false
		seen[id] = true
		parts.append(by_id[id])
	var payload: Dictionary = declaration.duplicate(true)
	payload.erase("sourceBinding")
	return declaration.sourceBinding == _digest([payload, parts.map(_geometry)])

static func _geometry(part) -> Dictionary:
	return {"id": part.id, "kind": part.kind, "semantic": part.semantic, "position": part.position,
		"rotation": part.rotation, "size": part.size, "material": part.material_id, "collision": part.collision_enabled}

static func _digest(value: Variant) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(value))
	return context.finish().hex_encode()
