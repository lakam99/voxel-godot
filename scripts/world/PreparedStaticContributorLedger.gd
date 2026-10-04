extends RefCounted
## Revisioned, value-only transaction ledger for prepared static section inputs.
##
## begin_boundary() declares the complete source-part/revision/segment set and
## exact replacements/removals. Prepared segments can then arrive over several
## incremental producer flushes. prepare_boundary() builds and validates an
## entire candidate partition without changing committed state. The ledger
## promotes it only after accept_installed_candidate() receives an exact set of
## matching section install receipts; any rejection or abort retains the prior
## committed ledger.
##
## No Resource, Node, Callable, or rendering object is retained. The current
## implementation performs candidate partitioning synchronously; production
## integration may move that pure calculation to an owned worker while keeping
## the same boundary token and revision checks.

const Partitioner = preload("res://scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd")
const SnapshotBuilder = preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")

var _committed: Dictionary = {}
var _committed_partition: Dictionary = {}
var _committed_impacted_sections: Array[Vector3i] = []
var _pending: Dictionary = {}
var _prepared_candidate: Dictionary = {}
var _last_changed_source_parts: Array[String] = []


func begin_boundary(boundary_id: String, declarations: Array, removals: Array) -> Dictionary:
	if not _pending.is_empty():
		return _failed("boundary_already_open")
	if boundary_id.is_empty() or not declarations.is_read_only() or not removals.is_read_only():
		return _failed("invalid_boundary_header")
	var declared: Dictionary = {}
	var source_ids: Dictionary = {}
	var staged_declarations: Dictionary = {}
	var staged_removals: Dictionary = {}
	for declaration_value: Variant in declarations:
		if not declaration_value is Dictionary or not declaration_value.is_read_only():
			return _failed("mutable_or_invalid_declaration")
		var declaration: Dictionary = declaration_value
		var part_id := String(declaration.get("sourcePartId", ""))
		var source_id := String(declaration.get("sourceId", ""))
		var revision := String(declaration.get("sourceRevision", ""))
		var owner_cell_value: Variant = declaration.get("ownerCell")
		var source_to_world: Variant = declaration.get("sourceToWorld")
		var segment_declarations: Variant = declaration.get("segments")
		if part_id.is_empty() or source_id.is_empty() or revision.is_empty() \
				or not source_to_world is Transform3D or not _valid_transform(source_to_world) \
				or not owner_cell_value is Vector2i \
				or not segment_declarations is Array or not segment_declarations.is_read_only():
			return _failed("invalid_source_declaration")
		if declared.has(part_id) or source_ids.has(source_id):
			return _failed("duplicate_boundary_source")
		declared[part_id] = true
		source_ids[source_id] = true
		var segments: Dictionary = {}
		for segment_value: Variant in segment_declarations:
			if not segment_value is Dictionary or not segment_value.is_read_only():
				return _failed("mutable_or_invalid_segment_declaration")
			var segment_declaration: Dictionary = segment_value
			var segment_id := String(segment_declaration.get("segmentId", ""))
			var compatibility := _validated_compatibility(segment_declaration)
			if segment_id.is_empty() or compatibility.is_empty():
				return _failed("invalid_segment_declaration")
			if segments.has(segment_id):
				return _failed("duplicate_declared_segment")
			segments[segment_id] = compatibility
		var segment_ids: Array[String] = []
		for segment_id_value: Variant in segments:
			segment_ids.append(String(segment_id_value))
		segment_ids.sort()
		segment_ids.make_read_only()
		var source_record := {"sourcePartId":part_id, "sourceId":source_id,
			"sourceRevision":revision, "sourceToWorld":source_to_world,
			"ownerCell":owner_cell_value,
			"segments":segments, "declaredSegmentIds":segment_ids,
			"receivedSegments":{}}
		staged_declarations[part_id] = source_record
	for removal_value: Variant in removals:
		if not removal_value is Dictionary or not removal_value.is_read_only():
			return _failed("mutable_or_invalid_removal")
		var removal: Dictionary = removal_value
		var part_id := String(removal.get("sourcePartId", ""))
		var source_id := String(removal.get("sourceId", ""))
		var revision := String(removal.get("sourceRevision", ""))
		if part_id.is_empty() or source_id.is_empty() or revision.is_empty():
			return _failed("invalid_removal_declaration")
		if not _committed.has(part_id) or String(_committed[part_id].sourceId) != source_id:
			return _failed("removal_source_not_committed")
		if declared.has(part_id) or source_ids.has(source_id):
			return _failed("duplicate_boundary_source")
		declared[part_id] = true
		source_ids[source_id] = true
		var removal_record := {"sourcePartId":part_id, "sourceId":source_id,
			"sourceRevision":revision, "remove":true}
		removal_record.make_read_only()
		staged_removals[part_id] = removal_record
	if declared.is_empty():
		return _failed("empty_publication_boundary")
	for committed_part_value: Variant in _committed:
		var committed_part := String(committed_part_value)
		if declared.has(committed_part):
			continue
		var committed_source_id := String(_committed[committed_part].sourceId)
		if source_ids.has(committed_source_id):
			return _failed("source_id_conflicts_with_unaffected_part")
	_pending = {"boundaryId":boundary_id, "declared":declared,
		"declarations":staged_declarations, "removals":staged_removals, "open":true}
	return {"status":"ready", "boundaryId":boundary_id,
		"replacementCount":_pending.declarations.size(), "removalCount":_pending.removals.size()}


func accept_prepared_segment(boundary_id: String, input: Dictionary) -> Dictionary:
	if _pending.is_empty() or not bool(_pending.get("open", false)) \
			or boundary_id != String(_pending.get("boundaryId", "")):
		return _failed("boundary_not_current")
	if not _prepared_candidate.is_empty():
		return _failed("boundary_candidate_already_prepared")
	if not input.is_read_only():
		return _failed("mutable_prepared_segment")
	if input.has("mesh") or input.has("material") or input.has("resource"):
		return _failed("render_resources_not_allowed")
	var part_id := String(input.get("sourcePartId", ""))
	var source_id := String(input.get("sourceId", ""))
	var revision := String(input.get("sourceRevision", ""))
	var segment_id := String(input.get("segmentId", ""))
	var buffer_value: Variant = input.get("buffer")
	var instance_count: Variant = input.get("instanceCount")
	if part_id.is_empty() or source_id.is_empty() or revision.is_empty() or segment_id.is_empty():
		return _failed("incomplete_prepared_segment_identity")
	if not buffer_value is Array or buffer_value.get_typed_builtin() != TYPE_FLOAT \
			or not buffer_value.is_read_only() or not instance_count is int \
			or instance_count < 1 or instance_count > Partitioner.MAX_OUTPUT_INSTANCES \
			or buffer_value.size() != instance_count * Partitioner.FLOATS_PER_INSTANCE:
		return _failed("invalid_prepared_segment_buffer")
	for component: float in buffer_value:
		if not is_finite(component):
			return _failed("nonfinite_prepared_segment_buffer")
	var compatibility := _validated_compatibility(input)
	if compatibility.is_empty():
		return _failed("invalid_prepared_segment_compatibility")
	var declaration: Dictionary = _pending.get("declarations", {}).get(part_id, {})
	if declaration.is_empty():
		return _failed("undeclared_source_part")
	if declaration.sourceId != source_id or declaration.sourceRevision != revision:
		return _failed("prepared_segment_source_revision_mismatch")
	if not declaration.segments.has(segment_id):
		return _failed("undeclared_segment")
	if declaration.segments[segment_id] != compatibility:
		return _failed("prepared_segment_compatibility_mismatch")
	if declaration.receivedSegments.has(segment_id):
		return _failed("duplicate_prepared_segment")
	var sealed_input := {"sourceId":source_id, "sourcePartId":part_id,
		"sourceRevision":revision, "segmentId":segment_id,
		"batchKey":String(compatibility.batchKey),
		"compatibility":compatibility, "buffer":buffer_value,
		"instanceCount":instance_count}
	sealed_input.make_read_only()
	declaration.receivedSegments[segment_id] = sealed_input
	return {"status":"accepted", "sourcePartId":part_id, "segmentId":segment_id}


func pending_partition_inputs(boundary_id: String) -> Dictionary:
	if _pending.is_empty() or boundary_id != String(_pending.get("boundaryId", "")):
		return _failed("boundary_not_current")
	var result := _partition_inputs_for(_pending.get("declarations", {}))
	result["boundaryId"] = boundary_id
	return result


func prepare_boundary(boundary_id: String, current_source_revisions: Dictionary,
		world_id: String, candidate_generation: int) -> Dictionary:
	if _pending.is_empty() or boundary_id != String(_pending.get("boundaryId", "")):
		return _failed("boundary_not_current")
	var revision_check := _validate_current_source_revisions(current_source_revisions)
	if revision_check.get("status") != "ready":
		return revision_check
	if not _prepared_candidate.is_empty():
		return _failed("boundary_candidate_already_prepared")
	if world_id.strip_edges().is_empty() or candidate_generation <= 0:
		return _failed("invalid_section_candidate_identity")
	var declared_inputs := _partition_inputs_for(_pending.get("declarations", {}))
	if declared_inputs.get("status") != "ready":
		return declared_inputs
	var next_committed := _committed.duplicate(false)
	var changed: Array[String] = []
	for part_id_value: Variant in _pending.removals:
		var part_id := String(part_id_value)
		changed.append(part_id)
		next_committed.erase(part_id)
	for part_id_value: Variant in _pending.declarations:
		var part_id := String(part_id_value)
		var source_record: Dictionary = _pending.declarations[part_id]
		var accepted_segments: Dictionary = source_record.receivedSegments
		var frozen_segments := accepted_segments.duplicate(false)
		frozen_segments.make_read_only()
		var record := {"sourcePartId":part_id, "sourceId":source_record.sourceId,
			"sourceRevision":source_record.sourceRevision,
			"sourceToWorld":source_record.sourceToWorld,
			"ownerCell":source_record.ownerCell,
			"segments":frozen_segments}
		record.make_read_only()
		next_committed[part_id] = record
		changed.append(part_id)
	changed.sort()
	var inputs_result := _partition_inputs_for(next_committed)
	if inputs_result.get("status") != "ready":
		return inputs_result
	var partitioned: Dictionary = Partitioner.partition(inputs_result.inputs)
	if partitioned.get("status") != "ready":
		return _failed("candidate_partition_failed:" + String(partitioned.get("reason", "unknown")))
	var next_readonly := next_committed.duplicate(false)
	next_readonly.make_read_only()
	var impacts := _impacted_sections_for(partitioned.result, _committed_partition, changed)
	if impacts.get("status") != "ready":
		return impacts
	var impacted_keys := _readonly_vector3i(impacts.sections)
	var replacements := SnapshotBuilder.build_replacements(partitioned.result,
		inputs_result.compatibilityByKey, impacted_keys, candidate_generation, world_id)
	if replacements.get("status") != "ready":
		return _failed("section_replacement_build_failed:" + String(replacements.get("reason", "unknown")))
	var candidate := {"boundaryId":boundary_id,
		"nextCommitted":next_readonly,
		"partition":partitioned.result,
		"impactedSectionKeys":impacted_keys,
		"worldId":world_id,
		"generation":candidate_generation,
		"replacements":replacements.replacements,
		"changedSourceParts":_readonly_strings(changed),
		"compatibilityByKey":inputs_result.compatibilityByKey}
	_prepared_candidate = candidate
	return {"status":"prepared", "boundaryId":boundary_id,
		"changedSourceParts":candidate.changedSourceParts,
		"impactedSectionKeys":candidate.impactedSectionKeys,
		"worldId":candidate.worldId,
		"generation":candidate.generation,
		"replacements":candidate.replacements,
		"candidateSourcePartCount":candidate.nextCommitted.size(),
		"compatibilityByKey":candidate.compatibilityByKey,
		"partition":candidate.partition}


func accept_installed_candidate(boundary_id: String, section_receipts: Array,
		current_source_revisions: Dictionary) -> Dictionary:
	if _pending.is_empty() or boundary_id != String(_pending.get("boundaryId", "")) \
			or _prepared_candidate.is_empty() \
			or boundary_id != String(_prepared_candidate.get("boundaryId", "")):
		return _failed("prepared_boundary_not_current")
	var revision_check := _validate_current_source_revisions(current_source_revisions)
	if revision_check.get("status") != "ready":
		return revision_check
	if not section_receipts.is_read_only():
		return _failed("mutable_section_receipts")
	var expected_replacements: Array = _prepared_candidate.replacements
	if section_receipts.size() != expected_replacements.size():
		return _failed("installed_section_set_mismatch")
	var replacement_by_key: Dictionary = {}
	for replacement_value: Variant in expected_replacements:
		if not replacement_value is Dictionary or not replacement_value.is_read_only():
			return _failed("invalid_bound_section_replacement")
		var replacement: Dictionary = replacement_value
		var replacement_key: Variant = replacement.get("sectionKey")
		if not replacement_key is Vector3i or replacement_by_key.has(replacement_key):
			return _failed("invalid_or_duplicate_bound_section_replacement")
		replacement_by_key[replacement_key] = replacement
	for receipt_value: Variant in section_receipts:
		if not receipt_value is Dictionary or not receipt_value.is_read_only():
			return _failed("mutable_or_invalid_section_receipt")
		var receipt: Dictionary = receipt_value
		var section_key: Variant = receipt.get("sectionKey")
		if not section_key is Vector3i:
			return _failed("unexpected_or_duplicate_section_receipt")
		var replacement_value: Variant = replacement_by_key.get(section_key)
		if not replacement_value is Dictionary:
			return _failed("unexpected_or_duplicate_section_receipt")
		var replacement: Dictionary = replacement_value
		if receipt.get("status") != "installed" \
				or String(receipt.get("worldId", "")) != String(replacement.worldId) \
				or int(receipt.get("generation", 0)) != int(replacement.generation) \
				or String(receipt.get("contentManifestDigest", "")) \
					!= String(replacement.contentManifestDigest):
			return _failed("section_receipt_does_not_match_candidate")
		replacement_by_key.erase(section_key)
	if not replacement_by_key.is_empty():
		return _failed("missing_section_install_receipt")
	# Promotion happens only after the full impacted section set has matching
	# install receipts. Callers must source these receipts from live section-slot
	# owners and revalidate their world/owner revision immediately before calling.
	_committed = _prepared_candidate.nextCommitted
	_committed_partition = _prepared_candidate.partition
	_committed_impacted_sections = _prepared_candidate.impactedSectionKeys
	_last_changed_source_parts = _prepared_candidate.changedSourceParts
	var result := {"status":"committed", "boundaryId":boundary_id,
		"changedSourceParts":_last_changed_source_parts,
		"impactedSectionKeys":_committed_impacted_sections,
		"sourcePartCount":_committed.size(),
		"partition":_committed_partition}
	_pending.clear()
	_prepared_candidate.clear()
	return result


func abort_boundary(boundary_id: String) -> Dictionary:
	if _pending.is_empty() or boundary_id != String(_pending.get("boundaryId", "")):
		return _failed("boundary_not_current")
	_pending.clear()
	_prepared_candidate.clear()
	return {"status":"aborted", "boundaryId":boundary_id,
		"committedSourcePartCount":_committed.size()}


func _validate_current_source_revisions(current_source_revisions: Dictionary) -> Dictionary:
	if not current_source_revisions.is_read_only():
		return _failed("mutable_current_revision_map")
	var declared: Dictionary = _pending.get("declared", {})
	if current_source_revisions.size() != declared.size():
		return _failed("current_source_set_mismatch")
	for part_id: Variant in declared:
		if not current_source_revisions.has(part_id):
			return _failed("current_source_missing")
		var current_revision := String(current_source_revisions[part_id])
		var expected_revision := _expected_revision(String(part_id))
		if current_revision != expected_revision:
			return _failed("stale_source_revision")
	return {"status":"ready"}


func committed_partition_inputs() -> Dictionary:
	return _partition_inputs_for(_committed)


func committed_impacted_section_keys() -> Array[Vector3i]:
	return _readonly_vector3i(_committed_impacted_sections)


func committed_source_part_ids() -> Array[String]:
	var result: Array[String] = []
	for part_id: Variant in _committed:
		result.append(String(part_id))
	result.sort()
	result.make_read_only()
	return result


func _partition_inputs_for(declarations: Dictionary) -> Dictionary:
	var inputs: Array[Dictionary] = []
	var inputs_by_source: Dictionary = {}
	var compatibility_by_key: Dictionary = {}
	var part_ids: Array[String] = []
	for part_id_value: Variant in declarations:
		part_ids.append(String(part_id_value))
	part_ids.sort()
	for part_id: String in part_ids:
		var declaration: Dictionary = declarations[part_id]
		var source_inputs: Array[Dictionary] = []
		var accepted_key := "receivedSegments" if declaration.has("receivedSegments") else "segments"
		var accepted: Dictionary = declaration.get(accepted_key, {})
		var segment_ids: Array[String] = []
		if declaration.has("declaredSegmentIds"):
			for segment_id_value: Variant in declaration.declaredSegmentIds:
				segment_ids.append(String(segment_id_value))
		else:
			for segment_id_value: Variant in accepted:
				segment_ids.append(String(segment_id_value))
		segment_ids.sort()
		for segment_id: String in segment_ids:
			if not accepted.has(segment_id):
				return _failed("boundary_incomplete")
			var received: Dictionary = accepted[segment_id]
			var compatibility: Dictionary = received.compatibility
			var partition_input := {"sourceId":declaration.sourceId,
				"sourcePartId":part_id,
				"sourceRevision":declaration.sourceRevision,
				"sourceToWorld":declaration.sourceToWorld,
				"ownerCell":declaration.ownerCell,
				"meshLocalBounds":compatibility.meshLocalBounds,
				"batchKey":compatibility.batchKey,
				"segmentId":segment_id, "buffer":received.buffer,
				"instanceCount":received.instanceCount,
				"compatibility":compatibility}
			partition_input.make_read_only()
			source_inputs.append(partition_input)
			inputs.append(partition_input)
			compatibility_by_key[String(compatibility.batchKey)] = compatibility
		source_inputs.make_read_only()
		inputs_by_source[part_id] = source_inputs
	inputs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if String(a.sourcePartId) != String(b.sourcePartId):
			return String(a.sourcePartId) < String(b.sourcePartId)
		if String(a.sourceId) != String(b.sourceId):
			return String(a.sourceId) < String(b.sourceId)
		return String(a.segmentId) < String(b.segmentId))
	inputs.make_read_only()
	var source_keys: Array[String] = []
	for part_id: Variant in inputs_by_source:
		source_keys.append(String(part_id))
	source_keys.sort()
	var ordered_by_source: Dictionary = {}
	for part_id: String in source_keys:
		ordered_by_source[part_id] = inputs_by_source[part_id]
	ordered_by_source.make_read_only()
	compatibility_by_key.make_read_only()
	return {"status":"ready", "inputs":inputs, "inputsBySourcePart":ordered_by_source,
		"compatibilityByKey":compatibility_by_key}


func _impacted_sections_for(partition_result: Dictionary, previous_partition: Dictionary,
		changed_source_parts: Array[String]) -> Dictionary:
	var sections: Dictionary = {}
	for output: Dictionary in previous_partition.get("outputs", []):
		if changed_source_parts.has(String(output.get("sourcePartId", ""))):
			sections[Vector3i(output.sectionKey)] = true
	for output: Dictionary in partition_result.outputs:
		if changed_source_parts.has(String(output.get("sourcePartId", ""))):
			sections[Vector3i(output.sectionKey)] = true
	var result: Array[Vector3i] = []
	for key: Variant in sections:
		result.append(Vector3i(key))
	result.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	return {"status":"ready", "sections":result}


func _expected_revision(part_id: String) -> String:
	if _pending.get("removals", {}).has(part_id):
		return String(_pending.removals[part_id].sourceRevision)
	return String(_pending.get("declarations", {}).get(part_id, {}).get("sourceRevision", ""))


func _validated_compatibility(value: Dictionary) -> Dictionary:
	var material_key := String(value.get("materialKey", ""))
	var render_tier := String(value.get("renderTier", ""))
	var mesh_key := String(value.get("meshKey", ""))
	var mesh_bounds_value: Variant = value.get("meshLocalBounds")
	var pipeline_revision := String(value.get("pipelineRevision", ""))
	var render_layer := String(value.get("renderLayer", ""))
	var translucent_sort_policy := String(value.get("translucentSortPolicy", ""))
	var cast_shadows: Variant = value.get("castShadows")
	var visibility_end: Variant = value.get("visibilityRangeEnd")
	var fade_margin: Variant = value.get("fadeMargin")
	# BuildingPartPublisher's prepared unit-box path is explicitly hard opaque.
	# Other layer/sort policies need their own ordered layer compiler contract.
	if material_key.is_empty() or render_tier.is_empty() or mesh_key.is_empty() \
			or not mesh_bounds_value is AABB or not _valid_bounds(mesh_bounds_value) \
			or pipeline_revision.is_empty() or render_layer != "opaque" \
			or translucent_sort_policy != "none" \
			or not cast_shadows is bool or not visibility_end is float or not fade_margin is float \
			or not is_finite(visibility_end) or not is_finite(fade_margin) \
			or visibility_end < 0.0 or fade_margin < 0.0:
		return {}
	# Fold pipeline and the enforced layer/sort mode into the stable mesh
	# compatibility component. This keeps the downstream six-field snapshot key
	# compatible while preventing incompatible producers from sharing a batch.
	var section_mesh_key := "%s|pipeline=%s|layer=%s|sort=%s" % [mesh_key,
		pipeline_revision, render_layer, translucent_sort_policy]
	var mesh_local_bounds: AABB = mesh_bounds_value
	var canonical := JSON.stringify([material_key, render_tier, section_mesh_key, cast_shadows,
		visibility_end, fade_margin, mesh_local_bounds.position.x, mesh_local_bounds.position.y,
		mesh_local_bounds.position.z, mesh_local_bounds.size.x, mesh_local_bounds.size.y,
		mesh_local_bounds.size.z])
	var batch_key := "section-batch:" + canonical.sha256_text()
	var supplied := String(value.get("compatibilityKey", batch_key))
	if supplied != batch_key:
		return {}
	var result := {"materialKey":material_key, "renderTier":render_tier,
		"meshResourceKey":mesh_key, "meshKey":section_mesh_key,
		"meshLocalBounds":mesh_local_bounds,
		"pipelineRevision":pipeline_revision, "renderLayer":render_layer,
		"translucentSortPolicy":translucent_sort_policy, "castShadows":cast_shadows,
		"visibilityRangeEnd":visibility_end, "fadeMargin":fade_margin,
		"batchKey":batch_key, "compatibilityKey":batch_key}
	result.make_read_only()
	return result


func _valid_transform(value: Transform3D) -> bool:
	return value.origin.is_finite() and value.basis.x.is_finite() \
		and value.basis.y.is_finite() and value.basis.z.is_finite() \
		and absf(value.basis.determinant()) > 0.000001


func _valid_bounds(value: AABB) -> bool:
	return value.position.is_finite() and value.size.is_finite() \
		and value.size.x > 0.0 and value.size.y > 0.0 and value.size.z > 0.0 \
		and value.end.is_finite()


func _readonly_strings(values: Array[String]) -> Array[String]:
	var result := values.duplicate()
	result.make_read_only()
	return result


func _readonly_vector3i(values: Array[Vector3i]) -> Array[Vector3i]:
	var result := values.duplicate()
	result.make_read_only()
	return result


func _failed(reason: String) -> Dictionary:
	return {"status":"failed", "reason":reason}
