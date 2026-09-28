extends RefCounted

## Private accelerator for one owned resolution pass. The blueprint supplies
## ordered neighbors; this holder owns no geometry or validation authority.
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const MAX_PARTS := 10000
# Acceleration eligibility only: leave extreme inputs to the original path.
# This keeps sums, rotated corners and inverse transforms far below float overflow.
const MAX_COMPONENT := 1.0e12
var _kernel: Object
var _indices: Dictionary = {}
var _neighborhoods: Dictionary = {}
var failure := ""

static func inputs_supported(blueprint) -> bool:
	if blueprint.parts.size()>MAX_PARTS: return false
	for part in blueprint.parts:
		if part==null: continue
		if not part is Part or part.get_script()!=Part or not blueprint.has_finite_positive_bounds(part): return false
		for value in [part.position, part.size, part.rotation]:
			if maxf(absf(value.x), maxf(absf(value.y), absf(value.z))) > MAX_COMPONENT: return false
	return true

func prepare(blueprint) -> bool:
	_kernel=ClassDB.instantiate("BuildingSupportKernel")
	if _kernel==null or not _kernel.has_method("protocol_version") or _kernel.protocol_version()!=1:
		failure="native_support_protocol_mismatch"; return false
	var records: Array=[]
	for part in blueprint.parts:
		if part==null: continue
		_indices[part]=records.size()
		var cardinal: bool=part.rotation==Vector3.ZERO
		records.append({"id":String(part.id),"excluded":String(part.recipe.get("physicalSupportsPartId","")),
			"position":part.position,"size":part.size,"cardinal":cardinal,
			"candidate":blueprint.is_structural_support_candidate(part),"root":bool(part.recipe.get("physicalRoot",false)),
			"enclosing":bool(part.recipe.get("allowEnclosingStructuralSupport",false)),
			"required":(part.recipe.get("physicalRequiredSupportPartIds",[]) as Array).map(func(value):return String(value)),
			"transform":Transform3D.IDENTITY if cardinal else blueprint.part_transform(part),
			"inverse":Transform3D.IDENTITY if cardinal else blueprint.part_inverse_transform(part)})
	if not _kernel.configure(records): failure="native_support_configuration_rejected"; return false
	return true

func has_target(target) -> bool:
	return _indices.has(target)

func query(target, point: Vector3, origin: Vector2i, blueprint) -> Dictionary:
	if not _neighborhoods.has(origin):
		var indices:=PackedInt32Array()
		for candidate in blueprint.structural_candidates_near(point):
			if not _indices.has(candidate):
				failure="native_support_unknown_candidate"; return {}
			indices.append(int(_indices[candidate]))
		_neighborhoods[origin]=indices
	var result: Dictionary=_kernel.query(_neighborhoods[origin],_indices[target],point,
		blueprint.PHYSICAL_CONTACT_MARGIN,blueprint.STRUCTURAL_SUPPORT_MAX_GAP)
	if result.has("nativeSupportError"):
		failure="native_support_query:"+String(result.nativeSupportError); return {}
	return result
