extends RefCounted
## Shared final buffers for the existing paving and roof geometry authorities.
## Material requests are values; their normal main-thread hooks retain ordering.
const Buffer = preload("res://scripts/buildings/BuildingInstanceBuffer.gd")
const Materials = preload("res://scripts/buildings/BuildingMasonryMaterialRequest.gd")

static func compile(part, geometry: Dictionary, family: String, continuation: Callable) -> Dictionary:
	var frame := Transform3D(Basis.from_euler(part.rotation),part.position)
	var variation := float(part.recipe.get("variation",0.0))
	var groups: Dictionary = {}
	var stage := "publication_"+family+"_packet"
	if family=="paving":
		groups.bed=_box_group(geometry.bed,Materials.ordinary(geometry.bed.materialId,variation-0.025),frame,continuation,stage)
		groups.regular=_group(geometry.regularTransforms,geometry.regularCustomData,Materials.ordinary(part.material_id,variation),frame,continuation,stage)
		groups.worn=_group(geometry.wornTransforms,geometry.wornCustomData,Materials.ordinary("worn_cobble",variation-0.016),frame,continuation,stage)
	else:
		groups.regular=_group(geometry.regularTransforms,geometry.regularCustomData,Materials.ordinary(part.material_id,variation),frame,continuation,stage)
		groups.weathered=_group(geometry.weatheredTransforms,geometry.weatheredCustomData,Materials.ordinary("roof_slate_weathered",variation-0.025),frame,continuation,stage)
		var cap := Materials.ordinary("roof_slate_cap",variation-0.015)
		groups.eave=_box_group(geometry.eave,cap,frame,continuation,stage)
		groups.ridge=_box_group(geometry.ridge,cap,frame,continuation,stage)
	groups.make_read_only()
	var packet := {"frame":frame,"groups":groups,"family":family}
	packet.make_read_only()
	return packet

static func _box_group(box: Dictionary, request: Dictionary, frame: Transform3D, continuation: Callable, stage: String) -> Dictionary:
	return _group([Transform3D(Basis(Vector3.UP,0.0).scaled(box.size),box.position)],
		[Color(0.5,0.5,0.5,1.0)],request,frame,continuation,stage)

static func _group(transforms: Array, custom: Array, request: Dictionary, frame: Transform3D, continuation: Callable, stage: String) -> Dictionary:
	var group := {"request":request,"segments":Buffer.compile(transforms,custom,frame,continuation,stage)}
	group.make_read_only()
	return group
