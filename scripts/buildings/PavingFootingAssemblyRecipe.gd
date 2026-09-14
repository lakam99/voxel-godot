extends RefCounted

## Private construction transaction input, not a second paving generator.
## The caller commits the complete frame and returned joint records together.
## Artifacts contain transient mesh resources and must never enter snapshots.
const Geometry = preload("res://scripts/buildings/SettledCobbleGeometry.gd")
const History = preload("res://scripts/buildings/SurfaceHistoryField.gd")
const FootCuts = preload("res://scripts/buildings/PavingFootingCutRecipe.gd")
const Artifact = preload("res://scripts/buildings/PavingConstructionArtifact.gd")
const Materials = preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const MAX_FINISHES := 4


## Legacy main-thread entry point. Preserve its mesh-bearing artifacts and
## clearance check while delegating all construction to the value-only path.
static func prepare(b, finish_ids: Array, feet: Array, nominal_joint: float) -> Dictionary:
	var unit := BoxMesh.new()
	unit.size = Vector3.ONE
	var value := prepare_value(b, finish_ids, feet, nominal_joint, unit.surface_get_arrays(0))
	if not value.ready:
		return value
	var bounds: Array[AABB] = []
	for foot in feet:
		bounds.append(AABB(foot.position - foot.size * 0.5, foot.size))
	var artifacts: Dictionary = {}
	for id in finish_ids:
		var finalized: Dictionary = Artifact.hydrate_value(value.artifacts[id])
		if not finalized.completed: return _failure("finalization:" + String(finalized.get("reason", "")))
		var clearance: Dictionary = Artifact.clear_of_boxes(finalized, bounds)
		if not clearance.completed or not clearance.get("clear", false): return _failure("real_foot_clearance_not_proven")
		artifacts[id] = finalized
	return {"ready": true, "artifacts": artifacts, "joints": value.joints}


## Worker-safe construction result. Its finished artifacts retain only typed
## packet values; no BoxMesh or ArrayMesh can escape this method.
static func prepare_value(b, finish_ids: Array, feet: Array, nominal_joint: float, unit_surface_arrays: Array) -> Dictionary:
	if b == null or b.parts.size() > 10000 or finish_ids.is_empty() or finish_ids.size() > MAX_FINISHES or feet.is_empty() or feet.size() > FootCuts.MAX_FEET:
		return _failure("assembly_collection_limit")
	var by_id: Dictionary = {}
	for part in b.parts:
		if part == null or by_id.has(part.id): return _failure("invalid_source_parts")
		by_id[part.id] = part
	var foot_ids: Array = []
	var bounds: Array[AABB] = []
	for foot in feet:
		if foot == null or foot_ids.has(foot.id) or foot.id.is_empty() or foot.rotation != Vector3.ZERO or not foot.collision_enabled or foot.kind != "beam" or not Materials.is_masonry_material(foot.material_id) or not b.has_finite_positive_bounds(foot):
			return _failure("invalid_actual_foot")
		foot_ids.append(foot.id)
		bounds.append(AABB(foot.position - foot.size * 0.5, foot.size))
	var history := History.new()
	history.configure(b.recipe, b.parts)
	var source_id: String = String(b.recipe.get("sourceBlueprintId", b.id))
	var artifacts: Dictionary = {}
	var joints: Dictionary = {}
	for id in finish_ids:
		if not id is String or not by_id.has(id) or artifacts.has(id): return _failure("invalid_finish_ids")
		var finish = by_id[id]
		if finish.collision_enabled or finish.kind != "foundation" or not Materials.is_cobble_material(finish.material_id) or not b.has_finite_positive_bounds(finish):
			return _failure("requires_noncollision_cobble_dressing")
		var described: Dictionary = Geometry.describe_source(finish, history, source_id)
		var cut: Dictionary = FootCuts.derive(described, b.part_transform(finish), bounds, nominal_joint)
		if not cut.completed: return _failure("cut_recipe:" + String(cut.get("reason", "")))
		var construction: Dictionary = Artifact.compile(described, b.part_transform(finish), cut.apertures)
		if not construction.completed: return _failure("construction:" + String(construction.get("reason", "")))
		var finalized: Dictionary = Artifact.finalize_value(construction, unit_surface_arrays)
		if not finalized.completed: return _failure("finalization:" + String(finalized.get("reason", "")))
		var clearance: Dictionary = Artifact.clear_of_boxes_value(finalized, bounds)
		if not clearance.completed or not clearance.get("clear", false): return _failure("real_foot_clearance_not_proven")
		artifacts[id] = finalized
		joints[id] = {"footPartIds": foot_ids.duplicate(), "nominalJoint": nominal_joint,
			"geometryDigest": finalized.geometryDigest, "constructionDigest": construction.constructionDigest}
	return {"ready": true, "artifacts": artifacts, "joints": joints}


## Extend explicit per-finish membership on a private recipe transaction.
## Replay committed declarations BEFORE building any replacement; recompiling
## the original descriptor with the complete union preserves prior apertures.
## Neither caller records nor old declarations are changed by this method.
## Publication continues to consume prepare(), not a second geometry path.
static func prepare_extension(b, finish_feet: Dictionary, nominal_joint: float) -> Dictionary:
	if b == null or b.parts.size() > 10000 or finish_feet.is_empty() or finish_feet.size() > MAX_FINISHES:
		return _failure("extension_collection_limit")
	if not is_finite(nominal_joint) or nominal_joint <= 0.0 or nominal_joint > FootCuts.MAX_JOINT:
		return _failure("invalid_nominal_joint")
	var by_id: Dictionary = {}
	var declarations: Dictionary = {}
	var old_feet: Dictionary = {}
	for part in b.parts:
		if not part is Part or part.id.is_empty() or by_id.has(part.id): return _failure("invalid_source_parts")
		by_id[part.id] = part
		if part.recipe.has("pavingFootingJoints"):
			declarations[part.id] = part.recipe.pavingFootingJoints
			if declarations.size() > MAX_FINISHES: return _failure("extension_finish_limit")
	# Validate every prior declaration, including untouched finishes, before
	# expensive preparation. Caps cover the transaction, not individual calls.
	for finish_id in declarations:
		var declaration: Variant = declarations[finish_id]
		if not _valid_finish(b, by_id[finish_id]): return _failure("invalid_extension_finish")
		if not declaration is Dictionary or declaration.size() != 4 or not declaration.get("footPartIds") is Array:
			return _failure("invalid_prior_declaration")
		if not (declaration.get("nominalJoint") is float or declaration.get("nominalJoint") is int): return _failure("invalid_prior_joint")
		var prior_joint: float = declaration.nominalJoint
		if not is_finite(prior_joint) or prior_joint <= 0.0 or prior_joint > FootCuts.MAX_JOINT: return _failure("invalid_prior_joint")
		for key in ["geometryDigest", "constructionDigest"]:
			if not declaration.get(key) is String or declaration[key].length() != 64 or not declaration[key].is_valid_hex_number(false): return _failure("invalid_prior_digest")
		if declaration.footPartIds.is_empty() or declaration.footPartIds.size() > FootCuts.MAX_FEET: return _failure("invalid_prior_foot_collection")
		var seen: Dictionary = {}
		for id in declaration.footPartIds:
			if not id is String or not by_id.has(id) or seen.has(id) or not _valid_foot(b, by_id[id]): return _failure("invalid_prior_foot")
			seen[id] = true
			old_feet[id] = by_id[id]
			if old_feet.size() > FootCuts.MAX_FEET: return _failure("extension_total_foot_limit")
	var all_finishes: Dictionary = declarations.duplicate()
	var proposed: Dictionary = {}
	var per_finish: Dictionary = {}
	var appended_ids: Dictionary = {}
	for finish_id in finish_feet:
		if not finish_id is String or not by_id.has(finish_id) or not _valid_finish(b, by_id[finish_id]): return _failure("invalid_extension_finish")
		var feet: Variant = finish_feet[finish_id]
		if not feet is Array or feet.is_empty() or feet.size() > FootCuts.MAX_FEET: return _failure("invalid_extension_foot_collection")
		if declarations.has(finish_id) and float(declarations[finish_id].nominalJoint) != nominal_joint: return _failure("extension_joint_changed")
		all_finishes[finish_id] = true
		if all_finishes.size() > MAX_FINISHES: return _failure("extension_finish_limit")
		var selected: Dictionary = {}
		for foot in feet:
			if not _valid_foot(b, foot): return _failure("invalid_actual_foot")
			# Appending construction feet must not add history emitters or a
			# second finish declaration after the preparation snapshot was read.
			if foot.semantic.contains("eave") or bool(foot.recipe.get("weatheringEave", false)) or foot.recipe.has("pavingFootingJoints"):
				return _failure("extension_foot_changes_publication_policy")
			if selected.has(foot.id) or old_feet.has(foot.id): return _failure("duplicate_extension_foot")
			if (by_id.has(foot.id) and by_id[foot.id] != foot) or (proposed.has(foot.id) and proposed[foot.id] != foot): return _failure("aliased_extension_foot")
			if not by_id.has(foot.id): appended_ids[foot.id] = true
			if b.parts.size() + appended_ids.size() > 10000: return _failure("extension_projected_source_limit")
			selected[foot.id] = foot
			proposed[foot.id] = foot
			if old_feet.size() + proposed.size() > FootCuts.MAX_FEET: return _failure("extension_total_foot_limit")
		per_finish[finish_id] = selected
	var prior_ids: Array = declarations.keys()
	prior_ids.sort()
	for finish_id in prior_ids:
		var declaration: Dictionary = declarations[finish_id]
		var feet: Array = []
		for id in declaration.footPartIds: feet.append(old_feet[id])
		# Preserve stored order for exact replay, even if an older declaration
		# predates canonical extension ordering. Never rebase a stale digest.
		var replay: Dictionary = prepare(b, [finish_id], feet, float(declaration.nominalJoint))
		if not replay.ready: return _failure("prior_replay:" + String(replay.get("reason", "")))
		if var_to_bytes(replay.joints[finish_id]) != var_to_bytes(declaration): return _failure("stale_prior_declaration")
	var artifacts: Dictionary = {}
	var joints: Dictionary = {}
	var requested_ids: Array = per_finish.keys()
	requested_ids.sort()
	for finish_id in requested_ids:
		var union: Dictionary = per_finish[finish_id].duplicate()
		if declarations.has(finish_id):
			for id in declarations[finish_id].footPartIds: union[id] = old_feet[id]
		var ids: Array = union.keys()
		ids.sort()
		var feet: Array = []
		for id in ids: feet.append(union[id])
		var replacement: Dictionary = prepare(b, [finish_id], feet, nominal_joint)
		if not replacement.ready: return _failure("extension_prepare:" + String(replacement.get("reason", "")))
		artifacts[finish_id] = replacement.artifacts[finish_id]
		joints[finish_id] = replacement.joints[finish_id]
	return {"ready": true, "artifacts": artifacts, "joints": joints}


static func _valid_finish(b, part) -> bool:
	return part is Part and not part.collision_enabled and part.kind == "foundation" and Materials.is_cobble_material(part.material_id) and part.recipe.get("visual", true) == true and b.has_finite_positive_bounds(part)


static func _valid_foot(b, foot) -> bool:
	return foot is Part and not foot.id.is_empty() and foot.rotation == Vector3.ZERO and foot.collision_enabled and foot.kind == "beam" and Materials.is_masonry_material(foot.material_id) and b.has_finite_positive_bounds(foot)


static func _failure(reason: String) -> Dictionary:
	return {"ready": false, "reason": reason}
