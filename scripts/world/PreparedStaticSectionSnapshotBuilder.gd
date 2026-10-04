extends RefCounted
## Builds deterministic, immutable section snapshots from a committed partition.
##
## This adapter owns no Nodes or Resources. It groups committed partition
## outputs by section and source part, resolves each output's immutable batch
## compatibility, and invokes the section snapshot assembler. Every requested
## impacted section receives a replacement, including an explicit empty one.

const Snapshot = preload("res://scripts/world/ChunkStaticRenderSectionSnapshot.gd")

const SCHEMA := "prepared-static-section-snapshot-envelope/v1"


static func build_replacements(partition_result: Dictionary, compatibility_by_key: Dictionary,
		impacted_section_keys: Array, candidate_generation: int, world_id: String) -> Dictionary:
	if not partition_result.is_read_only():
		return _failed("mutable_partition_result")
	if not compatibility_by_key.is_read_only():
		return _failed("mutable_compatibility_map")
	if not impacted_section_keys.is_read_only():
		return _failed("mutable_impacted_section_keys")
	if candidate_generation <= 0:
		return _failed("invalid_candidate_generation")
	if world_id.strip_edges().is_empty():
		return _failed("invalid_world_identity")
	var partition_validation := _validate_partition_result(partition_result)
	if partition_validation.get("status") != "ready":
		return partition_validation
	var partition_outputs: Array = partition_result.outputs

	var impacted: Dictionary = {}
	for key_value: Variant in impacted_section_keys:
		if not key_value is Vector3i:
			return _failed("invalid_impacted_section_key")
		var key: Vector3i = key_value
		if impacted.has(key):
			return _failed("duplicate_impacted_section_key")
		impacted[key] = true

	var output_groups: Dictionary = {}
	for output_value: Variant in partition_outputs:
		if not output_value is Dictionary or not output_value.is_read_only():
			return _failed("mutable_or_invalid_partition_output")
		var output: Dictionary = output_value
		var section_key_value: Variant = output.get("sectionKey")
		var source_id := String(output.get("sourceId", ""))
		var source_part_id := String(output.get("sourcePartId", ""))
		var source_revision := String(output.get("sourceRevision", ""))
		var batch_key := String(output.get("batchKey", ""))
		var segment_id := String(output.get("segmentId", ""))
		var owner_cell_value: Variant = output.get("ownerCell")
		var segment_value: Variant = output.get("segment")
		if not section_key_value is Vector3i or source_id.is_empty() \
				or source_part_id.is_empty() or source_revision.is_empty() \
				or batch_key.is_empty() or segment_id.is_empty() \
				or not owner_cell_value is Vector2i \
				or not segment_value is Dictionary or not segment_value.is_read_only():
			return _failed("incomplete_partition_output_identity")
		var section_key: Vector3i = section_key_value
		var compatibility_value: Variant = compatibility_by_key.get(batch_key)
		if not compatibility_value is Dictionary or not compatibility_value.is_read_only():
			return _failed("missing_or_mutable_batch_compatibility")
		var compatibility: Dictionary = compatibility_value
		if not _valid_compatibility(compatibility, batch_key):
			return _failed("invalid_batch_compatibility")
		var segment: Dictionary = segment_value
		if String(segment.get("segmentId", "")) != segment_id \
				or String(segment.get("sourceId", "")) != source_id \
				or String(segment.get("sourcePartId", "")) != source_part_id \
				or String(segment.get("sourceRevision", "")) != source_revision \
				or segment.get("ownerCell") != owner_cell_value \
				or segment.get("ownedSectionKey") != section_key \
				or String(segment.get("partitionerSchema", "")) \
					!= "chunk-static-render-section-instance-partition/v2":
			return _failed("partition_output_segment_identity_mismatch")
		var source_ranges: Variant = segment.get("sourceRanges")
		if not source_ranges is Array or not source_ranges.is_read_only():
			return _failed("invalid_partition_source_ranges")
		for range_value: Variant in source_ranges:
			if not range_value is Dictionary or not range_value.is_read_only() \
					or String(range_value.get("sourceId", "")) != source_id \
					or String(range_value.get("sourcePartId", "")) != source_part_id \
					or String(range_value.get("sourceRevision", "")) != source_revision \
					or range_value.get("ownedSectionKey") != section_key:
				return _failed("partition_source_range_identity_mismatch")
		if not impacted.has(section_key):
			continue
		if not output_groups.has(section_key):
			output_groups[section_key] = {}
		var section_groups: Dictionary = output_groups[section_key]
		if not section_groups.has(source_id):
			section_groups[source_id] = {"sourceId":source_id,
				"sourcePartId":source_part_id, "sourceRevision":source_revision,
				"ownerCell":owner_cell_value, "batches":{}}
		var contributor_group: Dictionary = section_groups[source_id]
		if contributor_group.sourcePartId != source_part_id \
				or contributor_group.sourceRevision != source_revision \
				or contributor_group.ownerCell != owner_cell_value:
			return _failed("conflicting_source_contributor_identity")
		var batches: Dictionary = contributor_group.batches
		if not batches.has(batch_key):
			batches[batch_key] = {"compatibility":compatibility, "segments":[]}
		var batch_group: Dictionary = batches[batch_key]
		if batch_group.compatibility != compatibility:
			return _failed("conflicting_batch_compatibility")
		batch_group.segments.append(segment)

	var ordered_keys: Array[Vector3i] = []
	for key_value: Variant in impacted:
		ordered_keys.append(Vector3i(key_value))
	ordered_keys.sort_custom(_vector3i_less)
	var replacements: Array[Dictionary] = []
	for section_key: Vector3i in ordered_keys:
		var contributors := _contributors_for_section(section_key,
			output_groups.get(section_key, {}))
		if contributors.get("status") != "ready":
			return contributors
		var assembled: Dictionary = Snapshot.assemble(section_key, contributors.contributors)
		if assembled.get("status") != "ready":
			return _failed("section_snapshot_assembly_failed:" + String(assembled.get("reason", "unknown")))
		var snapshot: Dictionary = assembled.snapshot
		var digest := _snapshot_digest(snapshot, world_id, candidate_generation, section_key)
		if digest.is_empty():
			return _failed("section_snapshot_digest_failed")
		var envelope := {"schema":SCHEMA, "worldId":world_id,
			"generation":candidate_generation, "sectionKey":section_key,
			"contentManifestDigest":digest, "snapshot":snapshot}
		envelope.make_read_only()
		replacements.append(envelope)
	replacements.make_read_only()
	var result := {"status":"ready", "schema":SCHEMA,
		"worldId":world_id, "generation":candidate_generation,
		"replacements":replacements}
	result.make_read_only()
	return result


static func _validate_partition_result(value: Dictionary) -> Dictionary:
	if String(value.get("schema", "")) != "chunk-static-render-section-instance-partition/v2":
		return _failed("invalid_partition_result_schema")
	var outputs_value: Variant = value.get("outputs")
	var manifest_value: Variant = value.get("sourceManifest")
	if not outputs_value is Array or not outputs_value.is_read_only() \
			or not manifest_value is Array or not manifest_value.is_read_only():
		return _failed("mutable_or_missing_partition_manifest")
	var input_count: Variant = value.get("inputInstanceCount")
	var output_count: Variant = value.get("outputInstanceCount")
	var output_segment_count: Variant = value.get("outputSegmentCount")
	var section_count: Variant = value.get("sectionCount")
	var batch_count: Variant = value.get("batchCount")
	if not input_count is int or not output_count is int \
			or not output_segment_count is int or not section_count is int \
			or not batch_count is int or input_count < 0 or output_count < 0 \
			or output_segment_count < 0 or section_count < 0 or batch_count < 0:
		return _failed("invalid_partition_result_counts")
	if input_count != output_count or output_segment_count != outputs_value.size():
		return _failed("partition_result_count_mismatch")

	var output_mappings: Dictionary = {}
	var output_sections: Dictionary = {}
	var output_batches: Dictionary = {}
	var observed_output_instances := 0
	for output_value: Variant in outputs_value:
		if not output_value is Dictionary or not output_value.is_read_only():
			return _failed("mutable_or_invalid_partition_output")
		var output: Dictionary = output_value
		var section_key_value: Variant = output.get("sectionKey")
		var segment_value: Variant = output.get("segment")
		var source_id := String(output.get("sourceId", ""))
		var source_part_id := String(output.get("sourcePartId", ""))
		var source_revision := String(output.get("sourceRevision", ""))
		var segment_id := String(output.get("segmentId", ""))
		var batch_key := String(output.get("batchKey", ""))
		var owner_cell_value: Variant = output.get("ownerCell")
		if not section_key_value is Vector3i or not segment_value is Dictionary \
				or not segment_value.is_read_only() or source_id.is_empty() \
				or source_part_id.is_empty() or source_revision.is_empty() \
				or segment_id.is_empty() or batch_key.is_empty() \
				or not owner_cell_value is Vector2i:
			return _failed("incomplete_partition_output_identity")
		var section_key: Vector3i = section_key_value
		var segment: Dictionary = segment_value
		var segment_index: Variant = segment.get("segmentIndex")
		var instance_count: Variant = segment.get("instanceCount")
		var ranges_value: Variant = segment.get("sourceRanges")
		if not segment_index is int or segment_index < 0 \
				or not instance_count is int or instance_count < 1 \
				or not ranges_value is Array or not ranges_value.is_read_only() \
				or ranges_value.size() != instance_count \
				or String(segment.get("segmentId", "")) != segment_id \
				or String(segment.get("sourceId", "")) != source_id \
				or String(segment.get("sourcePartId", "")) != source_part_id \
				or String(segment.get("sourceRevision", "")) != source_revision \
				or segment.get("ownerCell") != owner_cell_value \
				or segment.get("ownedSectionKey") != section_key \
				or String(segment.get("partitionerSchema", "")) \
					!= "chunk-static-render-section-instance-partition/v2":
			return _failed("partition_output_segment_identity_mismatch")
		output_sections[section_key] = true
		output_batches["%s\n%s\n%s\n%s" % [section_key, batch_key,
			source_id, source_revision]] = true
		observed_output_instances += instance_count
		for output_offset in range(instance_count):
			var range_value: Variant = ranges_value[output_offset]
			if not range_value is Dictionary or not range_value.is_read_only():
				return _failed("mutable_or_invalid_partition_source_range")
			var source_range: Dictionary = range_value
			if String(source_range.get("sourceId", "")) != source_id \
					or String(source_range.get("sourcePartId", "")) != source_part_id \
					or source_range.get("ownerCell") != owner_cell_value \
					or String(source_range.get("sourceRevision", "")) != source_revision \
					or String(source_range.get("sourceSegmentId", "")).is_empty() \
					or not source_range.get("sourceFirstInstance") is int \
					or int(source_range.sourceFirstInstance) < 0 \
					or int(source_range.get("outputFirstInstance", -1)) != output_offset \
					or int(source_range.get("instanceCount", 0)) != 1 \
					or source_range.get("ownedSectionKey") != section_key:
				return _failed("partition_source_range_identity_mismatch")
			var source_key := _source_instance_key(source_id, source_part_id,
				source_revision, String(source_range.sourceSegmentId),
				int(source_range.sourceFirstInstance))
			if output_mappings.has(source_key):
				return _failed("duplicate_partition_source_mapping")
			output_mappings[source_key] = {"sectionKey":section_key, "batchKey":batch_key,
				"segmentIndex":segment_index, "outputInstance":output_offset,
				"ownerCell":owner_cell_value}
	if observed_output_instances != output_count:
		return _failed("partition_output_instance_total_mismatch")
	if output_sections.size() != section_count or output_batches.size() != batch_count:
		return _failed("partition_section_or_batch_total_mismatch:%d/%d:%d/%d" % [
			output_sections.size(), section_count, output_batches.size(), batch_count])

	var manifest_mappings: Dictionary = {}
	var manifest_source_ids: Dictionary = {}
	var manifest_part_ids: Dictionary = {}
	var observed_manifest_instances := 0
	for manifest_entry_value: Variant in manifest_value:
		if not manifest_entry_value is Dictionary or not manifest_entry_value.is_read_only():
			return _failed("mutable_or_invalid_partition_source_manifest")
		var manifest_entry: Dictionary = manifest_entry_value
		var source_id := String(manifest_entry.get("sourceId", ""))
		var source_part_id := String(manifest_entry.get("sourcePartId", ""))
		var source_revision := String(manifest_entry.get("sourceRevision", ""))
		var owner_cell_value: Variant = manifest_entry.get("ownerCell")
		var count: Variant = manifest_entry.get("instanceCount")
		var instances_value: Variant = manifest_entry.get("instances")
		if source_id.is_empty() or source_part_id.is_empty() or source_revision.is_empty() \
				or not owner_cell_value is Vector2i or not count is int or count < 1 \
				or not instances_value is Array or not instances_value.is_read_only() \
				or instances_value.size() != count or manifest_source_ids.has(source_id) \
				or manifest_part_ids.has(source_part_id):
			return _failed("invalid_partition_source_manifest_identity")
		manifest_source_ids[source_id] = true
		manifest_part_ids[source_part_id] = true
		observed_manifest_instances += count
		for instance_value: Variant in instances_value:
			if not instance_value is Dictionary or not instance_value.is_read_only():
				return _failed("mutable_or_invalid_source_manifest_instance")
			var instance: Dictionary = instance_value
			var section_key_value: Variant = instance.get("sectionKey")
			var source_segment_id := String(instance.get("sourceSegmentId", ""))
			var source_index: Variant = instance.get("sourceInstance")
			var segment_index: Variant = instance.get("segmentIndex")
			var output_index: Variant = instance.get("outputInstance")
			var batch_key := String(instance.get("batchKey", ""))
			if instance.get("sourceId") != source_id \
					or instance.get("sourcePartId") != source_part_id \
					or instance.get("ownerCell") != owner_cell_value \
					or instance.get("sourceRevision") != source_revision \
					or not section_key_value is Vector3i or source_segment_id.is_empty() \
					or not source_index is int or source_index < 0 \
					or not segment_index is int or segment_index < 0 \
					or not output_index is int or output_index < 0 or batch_key.is_empty():
				return _failed("invalid_source_manifest_instance_identity")
			var source_key := _source_instance_key(source_id, source_part_id,
				source_revision, source_segment_id, source_index)
			if manifest_mappings.has(source_key):
				return _failed("duplicate_source_manifest_instance")
			manifest_mappings[source_key] = {"sectionKey":section_key_value,
				"batchKey":batch_key, "segmentIndex":segment_index,
				"outputInstance":output_index, "ownerCell":owner_cell_value}
	if observed_manifest_instances != input_count or manifest_mappings.size() != input_count:
		return _failed("partition_manifest_instance_total_mismatch")
	if manifest_mappings.size() != output_mappings.size():
		return _failed("partition_source_mapping_total_mismatch")
	for source_key: Variant in manifest_mappings:
		if not output_mappings.has(source_key) \
				or manifest_mappings[source_key] != output_mappings[source_key]:
			return _failed("partition_manifest_output_mapping_mismatch")
	return {"status":"ready"}


static func _source_instance_key(source_id: String, source_part_id: String,
		source_revision: String, source_segment_id: String, source_instance: int) -> String:
	return "%s\n%s\n%s\n%s\n%d" % [source_id, source_part_id,
		source_revision, source_segment_id, source_instance]


static func _contributors_for_section(section_key: Vector3i, source_groups: Dictionary) -> Dictionary:
	var source_ids: Array[String] = []
	for source_id_value: Variant in source_groups:
		source_ids.append(String(source_id_value))
	source_ids.sort()
	var contributors: Array[Dictionary] = []
	for source_id: String in source_ids:
		var source_group: Dictionary = source_groups[source_id]
		var batch_groups: Dictionary = source_group.batches
		var batch_keys: Array[String] = []
		for key_value: Variant in batch_groups:
			batch_keys.append(String(key_value))
		batch_keys.sort()
		var batches: Array[Dictionary] = []
		for batch_key: String in batch_keys:
			var batch_group: Dictionary = batch_groups[batch_key]
			var compatibility: Dictionary = batch_group.compatibility
			var segments: Array = batch_group.segments
			segments.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return String(a.segmentId) < String(b.segmentId))
			var readonly_segments: Array[Dictionary] = []
			for segment: Dictionary in segments:
				readonly_segments.append(segment)
			readonly_segments.make_read_only()
			var batch := {"materialKey":String(compatibility.materialKey),
				"renderTier":String(compatibility.renderTier),
				"meshKey":String(compatibility.meshResourceKey),
				"pipelineRevision":String(compatibility.pipelineRevision),
				"renderLayer":String(compatibility.renderLayer),
				"transparencySortPolicy":String(compatibility.translucentSortPolicy),
				"meshLocalBounds":compatibility.meshLocalBounds,
				"castShadows":compatibility.castShadows,
				"visibilityRangeEnd":compatibility.visibilityRangeEnd,
				"fadeMargin":compatibility.fadeMargin,
				"segments":readonly_segments}
			batch.make_read_only()
			batches.append(batch)
		batches.make_read_only()
		var contributor := {"sourceId":source_id,
			"sourcePartId":String(source_group.sourcePartId),
			"sourceRevision":String(source_group.sourceRevision),
			"ownerCell":Vector2i(source_group.ownerCell),
			"sectionKey":section_key, "bufferSpace":"section_local",
			"batches":batches}
		contributor.make_read_only()
		contributors.append(contributor)
	contributors.make_read_only()
	return {"status":"ready", "contributors":contributors}


static func _valid_compatibility(value: Dictionary, expected_batch_key: String) -> bool:
	var material_key := String(value.get("materialKey", ""))
	var render_tier := String(value.get("renderTier", ""))
	var mesh_resource_key := String(value.get("meshResourceKey", ""))
	var mesh_key := String(value.get("meshKey", ""))
	var pipeline_revision := String(value.get("pipelineRevision", ""))
	var render_layer := String(value.get("renderLayer", ""))
	var sort_policy := String(value.get("translucentSortPolicy", ""))
	var mesh_bounds_value: Variant = value.get("meshLocalBounds")
	var cast_shadows: Variant = value.get("castShadows")
	var visibility_end: Variant = value.get("visibilityRangeEnd")
	var fade_margin: Variant = value.get("fadeMargin")
	if material_key.is_empty() or render_tier.is_empty() or mesh_resource_key.is_empty() \
			or pipeline_revision.is_empty() or mesh_key != "%s|pipeline=%s|layer=%s|sort=%s" % [
				mesh_resource_key, pipeline_revision, render_layer, sort_policy] \
			or render_layer != "opaque" or sort_policy != "none" \
			or not mesh_bounds_value is AABB or not _valid_bounds(mesh_bounds_value) \
			or not cast_shadows is bool or not visibility_end is float or not fade_margin is float \
			or not is_finite(visibility_end) or not is_finite(fade_margin) \
			or visibility_end < 0.0 or fade_margin < 0.0:
		return false
	var mesh_bounds: AABB = mesh_bounds_value
	var canonical := JSON.stringify([material_key, render_tier, mesh_key, cast_shadows,
		visibility_end, fade_margin, mesh_bounds.position.x, mesh_bounds.position.y,
		mesh_bounds.position.z, mesh_bounds.size.x, mesh_bounds.size.y,
		mesh_bounds.size.z])
	var calculated_key := "section-batch:" + canonical.sha256_text()
	return expected_batch_key == calculated_key \
		and String(value.get("batchKey", "")) == calculated_key \
		and String(value.get("compatibilityKey", "")) == calculated_key


static func _snapshot_digest(snapshot: Dictionary, world_id: String,
		generation: int, section_key: Vector3i) -> String:
	var digest_input := {"worldId":world_id, "generation":generation,
		"sectionKey":section_key, "snapshot":snapshot}
	var canonicalized := _canonical_value(digest_input)
	if canonicalized.get("status") != "ready":
		return ""
	var canonical_text := JSON.stringify(canonicalized.value)
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if context.update(canonical_text.to_utf8_buffer()) != OK:
		return ""
	return context.finish().hex_encode()


static func _canonical_value(value: Variant) -> Dictionary:
	if value is Dictionary:
		var keys: Array[String] = []
		for key_value: Variant in value:
			if not key_value is String:
				return {"status":"failed", "reason":"non_string_digest_dictionary_key"}
			keys.append(key_value)
		keys.sort()
		var entries: Array = []
		for key: String in keys:
			var canonical_child := _canonical_value(value[key])
			if canonical_child.get("status") != "ready":
				return canonical_child
			entries.append([key, canonical_child.value])
		return {"status":"ready", "value":["dictionary", entries]}
	if value is Array:
		if value.get_typed_builtin() == TYPE_FLOAT:
			# Hash the engine's lossless Variant serialization of the typed buffer;
			# converting each component through JSON could round large float values.
			var buffer_hash := HashingContext.new()
			if buffer_hash.start(HashingContext.HASH_SHA256) != OK \
					or buffer_hash.update(var_to_bytes(value)) != OK:
				return {"status":"failed", "reason":"float_buffer_digest_failed"}
			return {"status":"ready", "value":["typed_float_array", value.size(),
				buffer_hash.finish().hex_encode()]}
		var values: Array = []
		for item: Variant in value:
			var canonical_item := _canonical_value(item)
			if canonical_item.get("status") != "ready":
				return canonical_item
			values.append(canonical_item.value)
		return {"status":"ready", "value":["array", values]}
	if value is Vector2i:
		return {"status":"ready", "value":["Vector2i", value.x, value.y]}
	if value is Vector3i:
		return {"status":"ready", "value":["Vector3i", value.x, value.y, value.z]}
	if value is Vector3:
		var x_value := _canonical_value(float(value.x))
		var y_value := _canonical_value(float(value.y))
		var z_value := _canonical_value(float(value.z))
		if x_value.get("status") != "ready" or y_value.get("status") != "ready" \
				or z_value.get("status") != "ready":
			return {"status":"failed", "reason":"invalid_vector3_digest_value"}
		return {"status":"ready", "value":["Vector3", x_value.value, y_value.value, z_value.value]}
	if value is AABB:
		var position := _canonical_value(value.position)
		var size := _canonical_value(value.size)
		if position.get("status") != "ready" or size.get("status") != "ready":
			return {"status":"failed", "reason":"invalid_aabb_digest_value"}
		return {"status":"ready", "value":["AABB", position.value, size.value]}
	if value is float:
		return {"status":"ready", "value":["float64_variant_bytes", var_to_bytes(value).hex_encode()]}
	if value is String or value is bool or value is int or value == null:
		return {"status":"ready", "value":value}
	return {"status":"failed", "reason":"unsupported_digest_value_type:" + type_string(typeof(value))}


static func _valid_bounds(value: AABB) -> bool:
	return value.position.is_finite() and value.size.is_finite() \
		and value.size.x > 0.0 and value.size.y > 0.0 and value.size.z > 0.0 \
		and value.end.is_finite()


static func _vector3i_less(a: Vector3i, b: Vector3i) -> bool:
	if a.x != b.x:
		return a.x < b.x
	if a.y != b.y:
		return a.y < b.y
	return a.z < b.z


static func _failed(reason: String) -> Dictionary:
	return {"status":"failed", "reason":reason}
