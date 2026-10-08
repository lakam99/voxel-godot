extends RefCounted
## Pure partitioning of prepared static-mesh instances into render sections.
##
## Each read-only input Dictionary contains sourceId, sourceRevision,
## sourceToWorld, meshLocalBounds, batchKey, segmentId, buffer, and
## instanceCount. The buffer uses a 16-float transform/custom-data layout. Its
## transforms are local to the source root; sourceToWorld is required and the
## output transforms are local to the owning section. Each instance is assigned
## once by the transformed mesh-local AABB center. The complete transformed AABB
## and every intersecting streamed chunk key are retained as dependencies.
## This is a pure data contract; it creates no rendering or collision objects.

const Grid = preload("res://scripts/world/StaticRenderSectionGrid.gd")
const Attributes = preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const INSTANCE_ATTRIBUTE_LAYOUT := Attributes.LAYOUT_SCHEMA
const FLOATS_PER_INSTANCE := Attributes.FLOATS_PER_INSTANCE
const MAX_OUTPUT_INSTANCES := 256
static func partition(inputs: Array) -> Dictionary:
	if not inputs.is_read_only():
		return _failed("mutable_input_list")
	var source_revisions: Dictionary = {}
	var source_owner_cells: Dictionary = {}
	var source_part_identities: Dictionary = {}
	var identities: Dictionary = {}
	var buckets: Dictionary = {}
	var batch_bounds: Dictionary = {}
	var input_instance_count := 0
	for input_value: Variant in inputs:
		if not input_value is Dictionary or not input_value.is_read_only():
			return _failed("mutable_or_invalid_input")
		var input: Dictionary = input_value
		var source_id := String(input.get("sourceId", ""))
		var instance_attribute_layout := String(input.get("instanceAttributeLayout", ""))
		var source_part_id := String(input.get("sourcePartId", ""))
		var source_revision := String(input.get("sourceRevision", ""))
		var owner_cell_value: Variant = input.get("ownerCell")
		var batch_key := String(input.get("batchKey", ""))
		var segment_id := String(input.get("segmentId", ""))
		var source_to_world_value: Variant = input.get("sourceToWorld")
		var mesh_bounds_value: Variant = input.get("meshLocalBounds")
		var buffer_value: Variant = input.get("buffer")
		var instance_count_value: Variant = input.get("instanceCount")
		if instance_attribute_layout != INSTANCE_ATTRIBUTE_LAYOUT:
			return _failed("unsupported_instance_attribute_layout")
		if source_id.is_empty() or source_part_id.is_empty() or source_revision.is_empty() \
				or not owner_cell_value is Vector2i or batch_key.is_empty() or segment_id.is_empty():
			return _failed("incomplete_source_or_batch_identity")
		if not source_to_world_value is Transform3D or not _valid_transform(source_to_world_value):
			return _failed("invalid_source_to_world_transform")
		if not mesh_bounds_value is AABB or not _valid_bounds(mesh_bounds_value):
			return _failed("invalid_mesh_local_bounds")
		if batch_bounds.has(batch_key) and batch_bounds[batch_key] != mesh_bounds_value:
			return _failed("batch_mesh_bounds_mismatch")
		batch_bounds[batch_key] = mesh_bounds_value
		if not buffer_value is Array or buffer_value.get_typed_builtin() != TYPE_FLOAT \
				or not buffer_value.is_read_only():
			return _failed("mutable_or_invalid_instance_buffer")
		if not instance_count_value is int or instance_count_value < 1 \
				or buffer_value.size() != instance_count_value * FLOATS_PER_INSTANCE:
			return _failed("invalid_instance_count_or_buffer_length")
		for component_index in range(buffer_value.size()):
			if not is_finite(float(buffer_value[component_index])):
				return _failed("nonfinite_instance_buffer_value")
		var source_part_identity := _source_part_identity_key(source_id, source_part_id)
		if source_part_identity.is_empty():
			return _failed("invalid_source_part_identity")
		if source_revisions.has(source_part_identity) \
				and source_revisions[source_part_identity] != source_revision:
			return _failed("conflicting_source_part_revisions")
		if source_owner_cells.has(source_part_identity) \
				and source_owner_cells[source_part_identity] != owner_cell_value:
			return _failed("conflicting_source_part_owner")
		source_revisions[source_part_identity] = source_revision
		source_owner_cells[source_part_identity] = owner_cell_value
		source_part_identities[source_part_identity] = {"sourceId":source_id,
			"sourcePartId":source_part_id, "ownerCell":owner_cell_value}
		var identity := var_to_bytes([source_id, source_part_id, source_revision, segment_id]).hex_encode()
		if identities.has(identity):
			return _failed("duplicate_source_segment")
		identities[identity] = true
		var source_to_world: Transform3D = source_to_world_value
		var mesh_local_bounds: AABB = mesh_bounds_value
		for instance_index in range(instance_count_value):
			var offset := instance_index * FLOATS_PER_INSTANCE
			var local_transform := Attributes.decode_transform(buffer_value, offset)
			if not _valid_transform(local_transform):
				return _failed("invalid_instance_transform")
			var world_transform := source_to_world * local_transform
			if not _valid_transform(world_transform):
				return _failed("nonfinite_world_transform")
			var world_bounds := world_transform * mesh_local_bounds
			if not _valid_bounds(world_bounds):
				return _failed("invalid_transformed_mesh_bounds")
			var world_center := world_bounds.position + world_bounds.size * 0.5
			var anchor: Variant = input.get("compoundAnchor", null)
			var policy := String(input.get("ownershipPolicy", "transformed_mesh_aabb_center/v1"))
			if (anchor != null and policy != "compound_attachment_anchor/v1") \
					or (anchor == null and policy != "transformed_mesh_aabb_center/v1"):
				return _failed("compound_attachment_ownership_policy_mismatch")
			if anchor != null and (not anchor is Dictionary or not anchor.is_read_only() \
					or anchor.size() != 2 or String(anchor.get("key", "")).is_empty() \
					or not anchor.get("worldPosition") is Vector3 or not anchor.worldPosition.is_finite()):
				return _failed("invalid_compound_attachment_anchor")
			var section_key := Grid.key_for_world_position(anchor.worldPosition if anchor != null else world_center)
			var section_origin := Grid.origin_for_key(section_key)
			var section_local_transform := Transform3D(Basis.IDENTITY, -section_origin) * world_transform
			var local_bounds := section_local_transform * mesh_local_bounds
			if not _valid_bounds(local_bounds):
				return _failed("invalid_section_local_mesh_bounds")
			var instance_color := Color(float(buffer_value[offset + Attributes.COLOR_OFFSET]),
				float(buffer_value[offset + Attributes.COLOR_OFFSET + 1]),
				float(buffer_value[offset + Attributes.COLOR_OFFSET + 2]),
				float(buffer_value[offset + Attributes.COLOR_OFFSET + 3]))
			var output_record := Attributes.encode_transform(section_local_transform,
				buffer_value, offset, instance_color)
			var bucket_key := _bucket_key(section_key, batch_key, source_id,
				source_part_id, source_revision)
			if not buckets.has(bucket_key):
				buckets[bucket_key] = {"sectionKey":section_key, "batchKey":batch_key,
					"sourceId":source_id, "sourcePartId":source_part_id,
					"ownerCell":owner_cell_value,
					"sourceRevision":source_revision, "records":[], "compoundAnchor":anchor}
			elif buckets[bucket_key].compoundAnchor != anchor:
				return _failed("mixed_compound_attachment_anchor")
			buckets[bucket_key].records.append({
				"sourceId":source_id,
				"sourcePartId":source_part_id,
				"ownerCell":owner_cell_value,
				"sourceRevision":source_revision,
				"segmentId":segment_id,
				"sourceInstance":instance_index,
				"meshLocalBounds":mesh_local_bounds,
				"buffer":output_record,
				"worldBounds":world_bounds,
				"localBounds":local_bounds})
			input_instance_count += 1
	var bucket_keys: Array[String] = []
	for key: Variant in buckets:
		bucket_keys.append(String(key))
	bucket_keys.sort()
	var outputs: Array[Dictionary] = []
	var output_instance_count := 0
	var output_segment_count := 0
	var all_source_mappings: Array[Dictionary] = []
	for bucket_key: String in bucket_keys:
		var bucket: Dictionary = buckets[bucket_key]
		var records: Array = bucket.records
		records.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if String(a.sourceId) != String(b.sourceId):
				return String(a.sourceId) < String(b.sourceId)
			if String(a.sourceRevision) != String(b.sourceRevision):
				return String(a.sourceRevision) < String(b.sourceRevision)
			if String(a.segmentId) != String(b.segmentId):
				return String(a.segmentId) < String(b.segmentId)
			return int(a.sourceInstance) < int(b.sourceInstance))
		var segment_index := 0
		var cursor := 0
		while cursor < records.size():
			var end := mini(cursor + MAX_OUTPUT_INSTANCES, records.size())
			var output_buffer: Array[float] = []
			var source_ranges: Array[Dictionary] = []
			var output_bounds: AABB
			var output_world_bounds: AABB
			for record_index in range(cursor, end):
				var record: Dictionary = records[record_index]
				output_buffer.append_array(record.buffer)
				output_bounds = record.localBounds if record_index == cursor \
					else output_bounds.merge(record.localBounds)
				output_world_bounds = record.worldBounds if record_index == cursor \
					else output_world_bounds.merge(record.worldBounds)
				var mapping := {"sourceId":record.sourceId,
					"sourcePartId":record.sourcePartId,
					"ownerCell":record.ownerCell,
					"sourceRevision":record.sourceRevision,
				"sourceSegmentId":record.segmentId,
				"sourceFirstInstance":record.sourceInstance,
				"outputFirstInstance":record_index - cursor,
				"instanceCount":1,
				"ownedSectionKey":bucket.sectionKey,
					"ownershipPolicy":"transformed_mesh_aabb_center/v1"}
				if bucket.compoundAnchor != null:
					mapping["ownershipPolicy"] = "compound_attachment_anchor/v1"
					mapping["compoundAnchor"] = bucket.compoundAnchor
				mapping.make_read_only()
				source_ranges.append(mapping)
				all_source_mappings.append({
					"sectionKey":bucket.sectionKey,
					"batchKey":bucket.batchKey,
					"segmentIndex":segment_index,
					"sourceId":record.sourceId,
					"sourcePartId":record.sourcePartId,
					"ownerCell":record.ownerCell,
					"sourceRevision":record.sourceRevision,
					"sourceSegmentId":record.segmentId,
					"sourceInstance":record.sourceInstance,
					"outputInstance":record_index - cursor})
			output_buffer.make_read_only()
			source_ranges.make_read_only()
			var dependencies := _stream_chunks_intersecting_bounds(output_world_bounds)
			if dependencies.is_empty():
				return _failed("empty_stream_chunk_dependencies")
			var stable_segment_id := "partition:" + (bucket_key + "\n" + str(segment_index)).sha256_text()
			var segment := {"instanceAttributeLayout":INSTANCE_ATTRIBUTE_LAYOUT,
				"segmentIndex":segment_index,
				"segmentId":stable_segment_id,
				"sourceId":bucket.sourceId,
				"sourcePartId":bucket.sourcePartId,
				"ownerCell":bucket.ownerCell,
				"sourceRevision":bucket.sourceRevision,
				"partitionerSchema":"chunk-static-render-section-instance-partition/v3",
				"ownershipPolicy":"transformed_mesh_aabb_center/v1",
				"meshLocalBounds":bucket.records[cursor].meshLocalBounds,
				"ownedSectionKey":bucket.sectionKey,
				"buffer":output_buffer,
				"instanceCount":end - cursor,
				"sourceRanges":source_ranges,
				"bounds":output_bounds,
				"worldBounds":output_world_bounds,
				"streamChunkDependencies":dependencies}
			if bucket.compoundAnchor != null:
				segment["ownershipPolicy"] = "compound_attachment_anchor/v1"
				segment["compoundAnchor"] = bucket.compoundAnchor
			segment.make_read_only()
			outputs.append({"instanceAttributeLayout":INSTANCE_ATTRIBUTE_LAYOUT,
				"sectionKey":bucket.sectionKey,
				"batchKey":bucket.batchKey,
				"sourceId":bucket.sourceId,
				"sourcePartId":bucket.sourcePartId,
				"ownerCell":bucket.ownerCell,
				"sourceRevision":bucket.sourceRevision,
				"segmentId":stable_segment_id,
				"segment":segment})
			output_instance_count += end - cursor
			output_segment_count += 1
			segment_index += 1
			cursor = end
	for index in range(outputs.size()):
		outputs[index].make_read_only()
	outputs.make_read_only()
	var mapping_by_source_part: Dictionary = {}
	for row_value: Variant in all_source_mappings:
		var row: Dictionary = row_value
		var source_key := _source_part_identity_key(String(row.sourceId),
			String(row.sourcePartId))
		if not mapping_by_source_part.has(source_key):
			mapping_by_source_part[source_key] = []
		mapping_by_source_part[source_key].append(row)
	var source_manifest: Array[Dictionary] = []
	var source_part_keys: Array[String] = []
	for source_part_key_value: Variant in source_part_identities:
		source_part_keys.append(String(source_part_key_value))
	source_part_keys.sort()
	for source_part_key: String in source_part_keys:
		var identity_value: Dictionary = source_part_identities[source_part_key]
		var source_id := String(identity_value.sourceId)
		var source_part_id := String(identity_value.sourcePartId)
		var rows: Array = mapping_by_source_part.get(source_part_key, [])
		rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if Vector3i(a.sectionKey) != Vector3i(b.sectionKey):
				return _vector3i_less(a.sectionKey, b.sectionKey)
			if String(a.batchKey) != String(b.batchKey):
				return String(a.batchKey) < String(b.batchKey)
			if String(a.sourceSegmentId) != String(b.sourceSegmentId):
				return String(a.sourceSegmentId) < String(b.sourceSegmentId)
			return int(a.sourceInstance) < int(b.sourceInstance))
		for row: Dictionary in rows:
			row.make_read_only()
		rows.make_read_only()
		var owner_cell := Vector2i(identity_value.ownerCell)
		var manifest := {"sourceId":source_id,
			"sourcePartId":source_part_id,
			"ownerCell":owner_cell,
			"sourceRevision":source_revisions[source_part_key],
			"instanceCount":rows.size(),
			"instances":rows}
		manifest.make_read_only()
		source_manifest.append(manifest)
	source_manifest.make_read_only()
	var result := {"schema":"chunk-static-render-section-instance-partition/v3",
		"instanceAttributeLayout":INSTANCE_ATTRIBUTE_LAYOUT,
		"outputs":outputs,
		"sourceManifest":source_manifest,
		"inputInstanceCount":input_instance_count,
		"outputInstanceCount":output_instance_count,
		"outputSegmentCount":output_segment_count,
		"sectionCount":_distinct_section_count(outputs),
		"batchCount":_distinct_batch_count(outputs)}
	result.make_read_only()
	return {"status":"ready", "result":result}


static func _valid_transform(transform: Transform3D) -> bool:
	return transform.origin.is_finite() and transform.basis.x.is_finite() \
		and transform.basis.y.is_finite() and transform.basis.z.is_finite() \
		and absf(transform.basis.determinant()) > 0.000001


static func _valid_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() \
		and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0 \
		and bounds.end.is_finite()


static func _stream_chunks_intersecting_bounds(bounds: AABB) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var size := Grid.STREAM_CHUNK_SIZE_METERS
	var low_x := _floor_index(bounds.position.x, size)
	var low_z := _floor_index(bounds.position.z, size)
	var high_x := _ceil_index(bounds.end.x, size) - 1
	var high_z := _ceil_index(bounds.end.z, size) - 1
	for z in range(low_z, high_z + 1):
		for x in range(low_x, high_x + 1):
			result.append(Vector2i(x, z))
	result.make_read_only()
	return result


static func _floor_index(value: float, size: float) -> int:
	var quotient := value / size
	var nearest := roundf(quotient)
	if absf(quotient - nearest) <= 0.000001:
		quotient = nearest
	return floori(quotient)


static func _ceil_index(value: float, size: float) -> int:
	var quotient := value / size
	var nearest := roundf(quotient)
	if absf(quotient - nearest) <= 0.000001:
		quotient = nearest
	return ceili(quotient)


static func _bucket_key(section_key: Vector3i, batch_key: String,
		source_id: String, source_part_id: String, source_revision: String) -> String:
	return "section-bucket:" + var_to_bytes([section_key, batch_key, source_id,
		source_part_id, source_revision]).hex_encode()


static func _source_part_identity_key(source_id: String, source_part_id: String) -> String:
	if source_id.is_empty() or source_part_id.is_empty(): return ""
	return "section-part:" + var_to_bytes([source_id, source_part_id]).hex_encode()


static func _vector3i_less(a: Vector3i, b: Vector3i) -> bool:
	if a.x != b.x:
		return a.x < b.x
	if a.y != b.y:
		return a.y < b.y
	return a.z < b.z


static func _distinct_section_count(outputs: Array) -> int:
	var values: Dictionary = {}
	for output: Dictionary in outputs:
		values[output.sectionKey] = true
	return values.size()


static func _distinct_batch_count(outputs: Array) -> int:
	var values: Dictionary = {}
	for output: Dictionary in outputs:
		values[_bucket_key(output.sectionKey, String(output.batchKey),
			String(output.sourceId), String(output.sourcePartId),
			String(output.sourceRevision))] = true
	return values.size()


static func _failed(reason: String) -> Dictionary:
	return {"status":"failed", "reason":reason}
