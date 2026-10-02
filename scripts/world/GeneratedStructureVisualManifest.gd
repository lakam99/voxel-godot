extends RefCounted
class_name GeneratedStructureVisualManifest

## Reads only completed production structure regions and receipts the actual
## generated block meshes. Physical readiness remains owned by StructureSystem.
const MAX_BLOCKS := 100000


static func submit(main: Object, structure_system: Object, readiness: Object,
		request_id: int, view_revision: int, bounds: Rect2i,
		near_bounds: Rect2i, require_physical: bool = true,
		global_near_bounds: Rect2i = Rect2i()) -> Dictionary:
	if not is_instance_valid(main) or not is_instance_valid(structure_system) \
			or not is_instance_valid(readiness) \
			or not main.has_method("generated_structure_visual_blocks") \
			or not structure_system.has_method("region_publication_readiness") \
			or not structure_system.has_method("region_dependency_requirements") \
			or not structure_system.has_method("region_dependency_revision") \
			or not readiness.has_method("expect_source") \
			or not readiness.has_method("describe_candidate") \
			or not readiness.has_method("has_candidate") \
			or not readiness.has_method("candidate_in_view") \
			or not readiness.has_method("accept_receipt") \
			or not readiness.has_method("finish_source"):
		return {"status": "failed", "reason": "generated_structure_visual_owner_missing"}
	if bounds.size.x <= 0 or bounds.size.y <= 0 or near_bounds.size.x <= 0 \
			or near_bounds.size.y <= 0 or not bounds.encloses(near_bounds):
		return {"status": "failed", "reason": "invalid_generated_structure_visual_bounds"}
	# A chunk source may straddle the near/horizon boundary. The source-local
	# rectangle proves coverage; this optional view rectangle selects the tier
	# without claiming physical readiness for the horizon.
	var tier_near_bounds := global_near_bounds if global_near_bounds.has_area() else near_bounds
	var source_method := "region_publication_readiness" if require_physical else "region_dependency_requirements"
	var required_status := "ready" if require_physical else "described"
	var source_state: Dictionary = structure_system.call(source_method, bounds)
	if source_state.get("status") != required_status:
		return {"status": String(source_state.get("status", "pending")),
			"reason": String(source_state.get("reason", "structure_source_description_pending")),
			"sourceDescription": source_state,
			"physicalPublication": source_state if require_physical else {}}
	var dependency_revision := String(structure_system.call("region_dependency_revision", bounds))
	var block_values: Array = main.call("generated_structure_visual_blocks", bounds)
	if block_values.size() > MAX_BLOCKS:
		return {"status": "pending", "reason": "generated_structure_visual_capacity", "retryable": true}
	var candidates: Array[Dictionary] = []
	var candidate_ids: Array[String] = []
	var candidates_by_id := {}
	for block_value in block_values:
		if not block_value is Dictionary:
			return {"status": "failed", "reason": "generated_structure_block_record_invalid"}
		var block_record: Dictionary = block_value
		var body := block_record.get("owner") as Node3D
		if not is_instance_valid(body) or not body.is_inside_tree() or body.is_queued_for_deletion():
			return {"status": "pending", "reason": "generated_structure_block_owner_stale", "retryable": true}
		if not bool(body.get_meta("generated", false)) or bool(body.get_meta("player_placed", false)):
			return {"status": "failed", "reason": "generated_structure_block_owner_mismatch"}
		var cell_value_meta: Variant = block_record.get("cell", body.get_meta("cell", Vector3i(-1, -1, -1)))
		if not cell_value_meta is Vector3i:
			return {"status": "failed", "reason": "generated_structure_block_cell_missing"}
		var cell: Vector3i = cell_value_meta
		var position_xz := Vector2(float(cell.x) + 0.5, float(cell.z) + 0.5)
		if not bounds.has_point(Vector2i(cell.x, cell.z)):
			return {"status": "failed", "reason": "generated_structure_block_outside_region"}
		# Bounds are a broad-phase rectangle. Only cells whose centers are in
		# the configured circular view are obligations for this visual demand.
		if not bool(readiness.call("candidate_in_view", position_xz)):
			continue
		var representation := _visible_renderable(body)
		var candidate_id := "structure-block:%d,%d,%d:%s" % [
			cell.x, cell.y, cell.z, String(body.get_meta("block_type", ""))]
		candidate_ids.append(candidate_id)
		var candidate := {"candidateId": candidate_id, "positionXZ": position_xz,
			"owner": body, "representation": representation, "cell": cell}
		candidates.append(candidate)
		candidates_by_id[candidate_id] = candidate
	candidate_ids.sort()
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	_update_hasher(hasher, dependency_revision)
	for candidate_id: String in candidate_ids:
		var candidate: Dictionary = candidates_by_id[candidate_id]
		_update_hasher(hasher, candidate_id)
		_update_hasher(hasher, str(candidate["owner"].get_instance_id()))
		_update_hasher(hasher, str(candidate["representation"].get_instance_id()) \
			if is_instance_valid(candidate["representation"]) else "pending")
	var source_identity := "generated-structure-blocks:%d:%d:%s" % [
		main.get_instance_id(), structure_system.get_instance_id(), str(bounds)]
	var source_revision := hasher.finish().hex_encode()
	var source_id := "generated-structure-blocks:%s" % str(bounds)
	var declared: Dictionary = readiness.call("expect_source", source_id, "structures",
		source_identity, source_revision, bounds, view_revision)
	if declared.get("status") != "ready":
		return declared
	var represented := 0
	var pending := 0
	var pending_ids: Array[String] = []
	for candidate: Dictionary in candidates:
		var candidate_id := String(candidate["candidateId"])
		var position_xz: Vector2 = candidate["positionXZ"]
		var required_tier := "near" if tier_near_bounds.has_point(
			Vector2i(floori(position_xz.x), floori(position_xz.y))) else "horizon"
		if not bool(readiness.call("has_candidate", source_id, candidate_id)):
			var described: Dictionary = readiness.call("describe_candidate", source_id,
				candidate_id, required_tier, {"positionXZ": position_xz, "cell": candidate.cell})
			if described.get("status") != "ready":
				return described
		if not is_instance_valid(candidate["representation"]):
			pending += 1
			pending_ids.append(candidate_id)
			continue
		var receipt: Dictionary = readiness.call("accept_receipt", source_id, candidate_id,
			"%s:installed" % candidate_id, required_tier, source_identity,
			source_revision, view_revision, candidate["owner"], candidate["representation"])
		if receipt.get("status") == "failed":
			return receipt
		if receipt.get("status") == "ready":
			represented += 1
		else:
			pending += 1
			pending_ids.append(candidate_id)
	var current_source: Dictionary = structure_system.call(source_method, bounds)
	var current_dependency_revision := String(structure_system.call("region_dependency_revision", bounds))
	if current_source.get("status") != required_status or current_dependency_revision != dependency_revision:
		return {"status": "pending", "reason": "generated_structure_source_revision_changed",
			"sourceRevision": source_revision, "dependencyRevision": dependency_revision,
			"currentDependencyRevision": current_dependency_revision,
			"sourceDescription": current_source,
			"physicalPublication": current_source if require_physical else {}}
	var finished: Dictionary = readiness.call("finish_source", source_id,
		source_identity, source_revision, view_revision)
	if finished.get("status") != "ready":
		return finished
	return {"status": "pending" if pending > 0 else "ready",
		"reason": "structure_visual_publication_pending" if pending > 0 else "",
		"sourceId": source_id, "sourceIdentity": source_identity,
		"sourceRevision": source_revision, "requestId": request_id,
		"viewRevision": view_revision, "bounds": bounds,
		"candidateCount": candidates.size(), "representedCount": represented,
		"pendingCount": pending, "pendingIds": pending_ids,
		"sourceDescription": source_state,
		"physicalPublication": source_state if require_physical else {}}


static func _visible_renderable(root_node: Node) -> Node3D:
	if root_node is GeometryInstance3D:
		var geometry := root_node as GeometryInstance3D
		if geometry.visible and geometry.is_visible_in_tree():
			if geometry is MeshInstance3D and (geometry as MeshInstance3D).mesh != null:
				return geometry
			if geometry is MultiMeshInstance3D and (geometry as MultiMeshInstance3D).multimesh != null:
				return geometry
	for child in root_node.get_children():
		if child is Node:
			var found := _visible_renderable(child)
			if found != null:
				return found
	return null


static func _update_hasher(hasher: HashingContext, value: String) -> void:
	var bytes := value.to_utf8_buffer()
	var length := PackedByteArray()
	length.resize(4)
	length.encode_u32(0, bytes.size())
	hasher.update(length)
	if not bytes.is_empty():
		hasher.update(bytes)
