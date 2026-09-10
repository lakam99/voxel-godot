extends RefCounted
## Near-detail packet owned by PreparedMasonry's exact source/history receipt.
## No shared cache or independent world authority. Aperture cuts have a separate
## existing producer and cannot consume this uncut packet.
const Buffer = preload("res://scripts/buildings/BuildingInstanceBuffer.gd")
const Materials = preload("res://scripts/buildings/BuildingMasonryMaterialRequest.gd")
static func compile(part, geometry: Dictionary, source_id: String, continuation: Callable):
	if part.recipe.has("masonryApertureSource"): return null
	var packet := {"frame":Transform3D(Basis.from_euler(part.rotation),part.position),"groups":{}}
	var variation := float(part.recipe.get("variation",0.0))
	var groups: Dictionary = {}
	groups.bed = _group([_box(Vector3.ZERO,geometry.mortarSize)],[Color(0.5,0.5,0.5,1.0)],
		Materials.ordinary("mortar",variation - 0.035),packet.frame,continuation)
	var top := String(part.recipe.get("topSurfaceMaterial",""))
	var size: Vector3 = part.size
	if String(part.kind)=="foundation" and not top.is_empty():
		groups.top = _group([_box(Vector3(0.0,size.y*0.5+0.014,0.0),Vector3(maxf(0.08,size.x-0.05),0.028,maxf(0.08,size.z-0.05)))],
			[Color(0.5,0.5,0.5,1.0)],Materials.ordinary(top,variation - 0.025),packet.frame,continuation)
	groups.regular = _group(geometry.regularTransforms,geometry.regularCustomData,
		Materials.ordinary(geometry.surfaceMaterialId,Materials.family_variation(part,source_id,variation)),packet.frame,continuation)
	if not geometry.repairTransforms.is_empty():
		groups.repair = _group(geometry.repairTransforms,geometry.repairCustomData,
			Materials.repair(part,geometry.surfaceMaterialId,source_id,Materials.family_variation(part,source_id,variation)),packet.frame,continuation)
	groups.make_read_only()
	packet.groups = groups
	packet.make_read_only()
	return packet

static func _group(transforms: Array, custom: Array, request: Dictionary, frame: Transform3D, continuation: Callable) -> Dictionary:
	var result := {"request":request,"segments":Buffer.compile(transforms,custom,frame,continuation)}
	result.make_read_only()
	return result

static func _box(position: Vector3, size: Vector3) -> Transform3D:
	return Transform3D(Basis(Vector3.UP,0.0).scaled(size),position)
