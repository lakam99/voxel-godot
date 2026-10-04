extends RefCounted
## Pure, immutable contributor aggregation for one static render section.
##
## API: assemble(section_key: Vector3i, contributors: Array) -> Dictionary.
## Each contributor must be a read-only Dictionary with sourceId, sourcePartId,
## sourceRevision, logical ownerCell, sectionKey, bufferSpace="section_local",
## and a read-only batches Array. Each batch declares
## materialKey, renderTier, meshKey, render policy, and immutable segments. A
## segment carries segmentId, a read-only typed Array[float] buffer in the
## existing 16-float instance layout, bounds, and instanceCount. Compatible
## contributor buffers are concatenated in stable order into native batches of
## at most 256 instances; source ranges remain in the manifest.
##
## The returned value owns new read-only manifests, groups, and merged buffers.
## It does not create Godot rendering resources, split a segment across
## sections, or publish a packet.
## Inputs must already be captured for this section and source revisions.
## This is a synchronous full-snapshot assembler, not a frame-budgeted queue.
## Callers must keep contributor sets bounded or run it in their worker stage.
## Inputs must already be partitioned into section-local segments. A segment
## whose instance AABB overhangs the owning section is accepted only with the
## explicit center-ownership partitioner proof and complete world-space
## streamed-chunk dependencies. Native packet-count and byte limits apply.

const Grid = preload("res://scripts/world/StaticRenderSectionGrid.gd")
const FLOATS_PER_INSTANCE := 16
const MAX_BATCH_INSTANCES := 256
const MAX_INPUT_SEGMENTS := 4096
const MAX_NATIVE_BATCHES := 4096
const MAX_PACKET_BUFFER_BYTES := 64 * 1024 * 1024
const MAX_INPUT_BUFFER_BYTES := 64 * 1024 * 1024


static func assemble(section_key: Vector3i, contributors: Array) -> Dictionary:
	if not contributors.is_read_only():
		return _failed("mutable_contributor_list")
	var section_bounds := AABB(Vector3.ZERO, Vector3.ONE * Grid.SECTION_SIZE_METERS)
	var source_ids: Dictionary = {}
	var manifests_by_source: Dictionary = {}
	var manifest_rows: Array[Dictionary] = []
	var batch_map: Dictionary = {}
	var total_instances := 0
	var total_segments := 0
	var total_buffer_bytes := 0
	var stream_dependencies: Dictionary = {}
	for contributor_value: Variant in contributors:
		if not contributor_value is Dictionary or not contributor_value.is_read_only():
			return _failed("mutable_or_invalid_contributor")
		var contributor: Dictionary = contributor_value
		var source_id := String(contributor.get("sourceId", ""))
		var source_part_id := String(contributor.get("sourcePartId", ""))
		var source_revision := String(contributor.get("sourceRevision", ""))
		if source_id.is_empty() or source_part_id.is_empty() or source_revision.is_empty():
			return _failed("incomplete_contributor_identity")
		if contributor.get("sectionKey") != section_key:
			return _failed("contributor_section_key_mismatch")
		if String(contributor.get("bufferSpace", "")) != "section_local":
			return _failed("contributor_buffer_space_mismatch")
		if source_ids.has(source_id):
			return _failed("duplicate_contributor_source_id")
		source_ids[source_id] = true
		var owner_cell_value: Variant = contributor.get("ownerCell")
		if not owner_cell_value is Vector2i:
			return _failed("invalid_logical_owner_cell")
		var source_batches: Variant = contributor.get("batches")
		if not source_batches is Array or not source_batches.is_read_only():
			return _failed("mutable_or_invalid_batch_list")
		var manifest_batch_keys: Array[String] = []
		var seen_batch_keys: Dictionary = {}
		var seen_segment_ids: Dictionary = {}
		for batch_value: Variant in source_batches:
			if not batch_value is Dictionary or not batch_value.is_read_only():
				return _failed("mutable_or_invalid_batch")
			var batch: Dictionary = batch_value
			var material_key := String(batch.get("materialKey", ""))
			var render_tier := String(batch.get("renderTier", ""))
			var mesh_key := String(batch.get("meshKey", ""))
			var pipeline_revision := String(batch.get("pipelineRevision", ""))
			var render_layer := String(batch.get("renderLayer", ""))
			var transparency_sort_policy := String(batch.get("transparencySortPolicy", ""))
			var mesh_local_bounds_value: Variant = batch.get("meshLocalBounds")
			var cast_shadows: Variant = batch.get("castShadows")
			var visibility_end: Variant = batch.get("visibilityRangeEnd")
			var fade_margin: Variant = batch.get("fadeMargin")
			if material_key.is_empty() or render_tier.is_empty() or mesh_key.is_empty() \
					or pipeline_revision.is_empty() \
					or render_layer not in ["opaque", "cutout", "translucent"] \
					or (render_layer in ["opaque", "cutout"] and transparency_sort_policy != "none") \
					or (render_layer == "translucent" and transparency_sort_policy not in ["camera_depth", "weighted_oit"]) \
					or not mesh_local_bounds_value is AABB or not _valid_bounds(mesh_local_bounds_value) \
					or not cast_shadows is bool or not visibility_end is float or not fade_margin is float \
					or not is_finite(visibility_end) or not is_finite(fade_margin) \
					or visibility_end < 0.0 or fade_margin < 0.0:
				return _failed("invalid_batch_compatibility_key")
			var mesh_local_bounds: AABB = mesh_local_bounds_value
			var batch_key := _compatible_batch_key(material_key, render_tier, mesh_key,
				pipeline_revision, render_layer, transparency_sort_policy,
				cast_shadows, visibility_end, fade_margin, mesh_local_bounds)
			var segments_value: Variant = batch.get("segments")
			if not segments_value is Array or not segments_value.is_read_only():
				return _failed("mutable_or_invalid_segment_list")
			if not seen_batch_keys.has(batch_key):
				seen_batch_keys[batch_key] = true
				manifest_batch_keys.append(batch_key)
			if not batch_map.has(batch_key):
				batch_map[batch_key] = {"batchKey":batch_key, "materialKey":material_key,
					"renderTier":render_tier, "meshKey":mesh_key,
					"meshLocalBounds":mesh_local_bounds,
					"pipelineRevision":pipeline_revision, "renderLayer":render_layer,
					"transparencySortPolicy":transparency_sort_policy,
					"castShadows":cast_shadows,
					"visibilityRangeEnd":visibility_end, "fadeMargin":fade_margin,
					"inputContributions":[]}
			var target: Dictionary = batch_map[batch_key]
			for segment_value: Variant in segments_value:
				if not segment_value is Dictionary or not segment_value.is_read_only():
					return _failed("mutable_or_invalid_segment")
				var segment: Dictionary = segment_value
				var segment_id := String(segment.get("segmentId", ""))
				var buffer_value: Variant = segment.get("buffer")
				var bounds_value: Variant = segment.get("bounds")
				var segment_mesh_bounds: Variant = segment.get("meshLocalBounds")
				var instance_count_value: Variant = segment.get("instanceCount")
				if segment_id.is_empty() or not buffer_value is Array \
						or buffer_value.get_typed_builtin() != TYPE_FLOAT or not buffer_value.is_read_only() \
						or not bounds_value is AABB or not bounds_value.position.is_finite() \
						or not segment_mesh_bounds is AABB or segment_mesh_bounds != mesh_local_bounds \
						or not bounds_value.size.is_finite() or bounds_value.size.x <= 0.0 \
						or bounds_value.size.y <= 0.0 or bounds_value.size.z <= 0.0 \
						or not instance_count_value is int or instance_count_value < 1 \
						or instance_count_value > MAX_BATCH_INSTANCES \
					or buffer_value.size() != instance_count_value * FLOATS_PER_INSTANCE:
					return _failed("invalid_segment_payload")
				for component: float in buffer_value:
					if not is_finite(component):
						return _failed("non_finite_segment_buffer")
				var world_bounds: Variant = _segment_world_bounds(segment, section_key, bounds_value)
				if not world_bounds is AABB:
					return _failed("invalid_segment_world_bounds")
				var declared_dependencies: Variant = segment.get("streamChunkDependencies", [])
				var expected_dependencies := _stream_chunk_keys_intersecting_bounds(world_bounds)
				if segment.has("streamChunkDependencies") and (not declared_dependencies is Array \
						or not _vector2i_arrays_equal(declared_dependencies, expected_dependencies)):
					return _failed("segment_stream_chunk_dependencies_mismatch")
				if _has_valid_center_ownership(segment, section_key) \
						and not segment.has("streamChunkDependencies"):
					return _failed("center_owned_segment_missing_stream_dependencies")
				for dependency: Vector2i in expected_dependencies:
					stream_dependencies[dependency] = true
				var segment_key := source_id + "\n" + batch_key + "\n" + segment_id
				if seen_segment_ids.has(segment_key):
					return _failed("duplicate_source_batch_segment")
				seen_segment_ids[segment_key] = true
				if not _bounds_contained(section_bounds, bounds_value) \
						and not _has_valid_center_ownership(segment, section_key):
					return _failed("segment_crosses_render_section")
				if _has_valid_center_ownership(segment, section_key) \
					and not _validate_center_owned_segment(segment, section_key, source_id,
							source_revision, instance_count_value, mesh_local_bounds,
							bounds_value, world_bounds):
					return _failed("invalid_center_owned_segment_proof")
				var contribution := {"sourceId":source_id, "sourcePartId":source_part_id,
					"sourceRevision":source_revision, "segmentId":segment_id,
					"buffer":buffer_value, "bounds":bounds_value,
					"meshLocalBounds":mesh_local_bounds,
					"worldBounds":world_bounds,
					"streamChunkDependencies":expected_dependencies,
					"instanceCount":instance_count_value}
				contribution.make_read_only()
				target.inputContributions.append(contribution)
				total_instances += instance_count_value
				total_segments += 1
				total_buffer_bytes += buffer_value.size() * 4
			if total_segments > MAX_INPUT_SEGMENTS:
				return _failed("section_snapshot_input_segment_limit")
			if total_buffer_bytes > MAX_INPUT_BUFFER_BYTES:
				return _failed("section_snapshot_input_buffer_capacity")
		manifest_batch_keys.sort()
		manifest_batch_keys.make_read_only()
		var manifest := {"sourceId":source_id, "sourcePartId":source_part_id,
			"sourceRevision":source_revision, "ownerCell":owner_cell_value,
			"sectionKey":section_key, "bufferSpace":"section_local",
			"batchKeys":manifest_batch_keys, "ranges":[]}
		manifests_by_source[source_id] = manifest
		manifest_rows.append(manifest)
	manifest_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.sourceId) < String(b.sourceId))
	var batch_keys: Array[String] = []
	for key: Variant in batch_map:
		batch_keys.append(String(key))
	batch_keys.sort()
	var frozen_batches: Dictionary = {}
	var native_batch_count := 0
	for batch_key: String in batch_keys:
		var mutable_batch: Dictionary = batch_map[batch_key]
		mutable_batch.inputContributions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if String(a.sourceId) != String(b.sourceId):
				return String(a.sourceId) < String(b.sourceId)
			return String(a.segmentId) < String(b.segmentId))
		var merged := _merge_compatible_batch(batch_key, mutable_batch.inputContributions,
			section_bounds, manifests_by_source)
		if merged.get("status") != "ready":
			return _failed(String(merged.get("reason", "compatible_batch_merge_failed")))
		mutable_batch.erase("inputContributions")
		mutable_batch["segments"] = merged.get("segments", [])
		native_batch_count += int(mutable_batch.segments.size())
		if native_batch_count > MAX_NATIVE_BATCHES:
			return _failed("section_packet_batch_capacity")
		mutable_batch.make_read_only()
		frozen_batches[batch_key] = mutable_batch
	for row: Dictionary in manifest_rows:
		var ranges: Array = manifests_by_source[String(row.sourceId)].get("ranges", [])
		ranges.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if String(a.batchKey) != String(b.batchKey):
				return String(a.batchKey) < String(b.batchKey)
			if int(a.batchIndex) != int(b.batchIndex):
				return int(a.batchIndex) < int(b.batchIndex)
			return int(a.firstInstance) < int(b.firstInstance))
		ranges.make_read_only()
		row["ranges"] = ranges
		row.make_read_only()
	batch_keys.make_read_only()
	frozen_batches.make_read_only()
	manifest_rows.make_read_only()
	var snapshot := {"schema":"chunk-static-render-section-snapshot/v2",
		"sectionKey":section_key,
		"sectionOrigin":Grid.origin_for_key(section_key), "sectionBounds":section_bounds,
		"bufferSpace":"section_local",
		"streamChunkKey":Grid.chunk_key_for_section(section_key),
		"streamChunkDependencies":_readonly_stream_dependencies(section_key, stream_dependencies),
		"manifest":manifest_rows, "batchKeys":batch_keys,
		"batches":frozen_batches, "contributorCount":manifest_rows.size(),
		"batchGroupCount":batch_keys.size(), "batchCount":native_batch_count,
		"inputSegmentCount":total_segments,
		"segmentCount":native_batch_count,
		"instanceCount":total_instances}
	snapshot.make_read_only()
	return {"status":"ready", "snapshot":snapshot}


static func _readonly_stream_dependencies(section_key: Vector3i,
		additional: Dictionary) -> Array[Vector2i]:
	var dependency_set: Dictionary = {}
	for key: Vector2i in Grid.stream_chunk_keys_intersecting_section(section_key):
		dependency_set[key] = true
	for key: Variant in additional:
		dependency_set[key] = true
	var dependencies: Array[Vector2i] = []
	for key_value: Variant in dependency_set:
		dependencies.append(Vector2i(key_value))
	dependencies.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.x != b.x:
			return a.x < b.x
		return a.y < b.y)
	dependencies.make_read_only()
	return dependencies


static func _segment_world_bounds(segment: Dictionary, section_key: Vector3i,
		local_bounds: AABB) -> Variant:
	var world_bounds: Variant = segment.get("worldBounds")
	if world_bounds is AABB:
		if not world_bounds.position.is_finite() or not world_bounds.size.is_finite() \
				or not world_bounds.end.is_finite() or world_bounds.size.x <= 0.0 \
				or world_bounds.size.y <= 0.0 or world_bounds.size.z <= 0.0:
			return null
		return world_bounds
	if segment.has("partitionerSchema") or segment.has("streamChunkDependencies"):
		return null
	var origin := Grid.origin_for_key(section_key)
	return AABB(local_bounds.position + origin, local_bounds.size)


static func _has_valid_center_ownership(segment: Dictionary, section_key: Vector3i) -> bool:
	return String(segment.get("partitionerSchema", "")) \
		== "chunk-static-render-section-instance-partition/v2" \
		and String(segment.get("ownershipPolicy", "")) == "transformed_mesh_aabb_center/v1" \
		and segment.get("ownedSectionKey") == section_key \
		and segment.get("worldBounds") is AABB and segment.get("meshLocalBounds") is AABB


static func _validate_center_owned_segment(segment: Dictionary, section_key: Vector3i,
		source_id: String, source_revision: String, instance_count: int,
		mesh_local_bounds: AABB, declared_local_bounds: AABB,
		declared_world_bounds: AABB) -> bool:
	var source_ranges: Variant = segment.get("sourceRanges")
	if not source_ranges is Array or not source_ranges.is_read_only() \
			or source_ranges.size() != instance_count:
		return false
	var local_bounds: AABB
	var world_bounds: AABB
	var have_bounds := false
	var seen_source_instances: Dictionary = {}
	var section_to_world := Transform3D(Basis.IDENTITY, Grid.origin_for_key(section_key))
	for index in range(instance_count):
		var range_value: Variant = source_ranges[index]
		if not range_value is Dictionary or not range_value.is_read_only():
			return false
		var source_range: Dictionary = range_value
		var source_segment_id := String(source_range.get("sourceSegmentId", ""))
		var source_first: Variant = source_range.get("sourceFirstInstance")
		if String(source_range.get("sourceId", "")) != source_id \
				or String(source_range.get("sourceRevision", "")) != source_revision \
				or source_segment_id.is_empty() or not source_first is int or source_first < 0 \
				or int(source_range.get("outputFirstInstance", -1)) != index \
				or int(source_range.get("instanceCount", 0)) != 1 \
				or source_range.get("ownedSectionKey") != section_key:
			return false
		var source_instance_key := source_segment_id + "\n" + str(source_first)
		if seen_source_instances.has(source_instance_key):
			return false
		seen_source_instances[source_instance_key] = true
		var buffer_offset := index * FLOATS_PER_INSTANCE
		var instance_transform := _decode_instance_transform(segment.buffer, buffer_offset)
		if not _transform_is_finite(instance_transform):
			return false
		var local_instance_bounds: AABB = instance_transform * mesh_local_bounds
		var world_instance_bounds: AABB = (section_to_world * instance_transform) * mesh_local_bounds
		if not local_instance_bounds.position.is_finite() or not local_instance_bounds.end.is_finite() \
				or not world_instance_bounds.position.is_finite() or not world_instance_bounds.end.is_finite():
			return false
		var world_center := world_instance_bounds.position + world_instance_bounds.size * 0.5
		if Grid.key_for_world_position(world_center) != section_key:
			return false
		local_bounds = local_instance_bounds if not have_bounds else local_bounds.merge(local_instance_bounds)
		world_bounds = world_instance_bounds if not have_bounds else world_bounds.merge(world_instance_bounds)
		have_bounds = true
	return have_bounds and _bounds_approximately_equal(local_bounds, declared_local_bounds) \
		and _bounds_approximately_equal(world_bounds, declared_world_bounds)


static func _decode_instance_transform(buffer: Array, offset: int) -> Transform3D:
	return Transform3D(Basis(
		Vector3(float(buffer[offset]), float(buffer[offset + 4]), float(buffer[offset + 8])),
		Vector3(float(buffer[offset + 1]), float(buffer[offset + 5]), float(buffer[offset + 9])),
		Vector3(float(buffer[offset + 2]), float(buffer[offset + 6]), float(buffer[offset + 10]))),
		Vector3(float(buffer[offset + 3]), float(buffer[offset + 7]), float(buffer[offset + 11])))


static func _transform_is_finite(value: Transform3D) -> bool:
	return value.origin.is_finite() and value.basis.x.is_finite() \
		and value.basis.y.is_finite() and value.basis.z.is_finite() \
		and absf(value.basis.determinant()) > 0.000001


static func _bounds_approximately_equal(a: AABB, b: AABB) -> bool:
	const EPSILON := 0.0001
	return a.position.distance_to(b.position) <= EPSILON \
		and a.end.distance_to(b.end) <= EPSILON


static func _stream_chunk_keys_intersecting_bounds(bounds: AABB) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var size := Grid.STREAM_CHUNK_SIZE_METERS
	var low_x := _floor_partition_coordinate(bounds.position.x, size)
	var low_z := _floor_partition_coordinate(bounds.position.z, size)
	var high_x := _ceil_partition_coordinate(bounds.end.x, size) - 1
	var high_z := _ceil_partition_coordinate(bounds.end.z, size) - 1
	for z in range(low_z, high_z + 1):
		for x in range(low_x, high_x + 1):
			result.append(Vector2i(x, z))
	result.make_read_only()
	return result


static func _floor_partition_coordinate(value: float, size: float) -> int:
	var quotient := value / size
	var nearest := roundf(quotient)
	if absf(quotient - nearest) <= 0.000001:
		quotient = nearest
	return floori(quotient)


static func _ceil_partition_coordinate(value: float, size: float) -> int:
	var quotient := value / size
	var nearest := roundf(quotient)
	if absf(quotient - nearest) <= 0.000001:
		quotient = nearest
	return ceili(quotient)


static func _vector2i_arrays_equal(left: Array, right: Array[Vector2i]) -> bool:
	if left.size() != right.size():
		return false
	for index in range(left.size()):
		if not left[index] is Vector2i or left[index] != right[index]:
			return false
	return true


static func _merge_compatible_batch(batch_key: String, inputs: Array,
		section_bounds: AABB, manifests_by_source: Dictionary) -> Dictionary:
	var output_segments: Array[Dictionary] = []
	var output_buffer: Array[float] = []
	var output_ranges: Array[Dictionary] = []
	var output_instances := 0
	var output_bounds: AABB
	var has_output_bounds := false
	for input_value: Variant in inputs:
		if not input_value is Dictionary:
			return {"status":"failed", "reason":"invalid_merge_contribution"}
		var input: Dictionary = input_value
		var input_buffer: Array = input.buffer
		var input_bounds: AABB = input.bounds
		var source_cursor := 0
		while source_cursor < int(input.instanceCount):
			var count := mini(MAX_BATCH_INSTANCES - output_instances,
				int(input.instanceCount) - source_cursor)
			if count <= 0:
				return {"status":"failed", "reason":"invalid_merged_batch_capacity"}
			var output_start := output_instances
			output_bounds = input_bounds if not has_output_bounds else output_bounds.merge(input_bounds)
			has_output_bounds = true
			for instance_offset in range(count):
				var input_start := (source_cursor + instance_offset) * FLOATS_PER_INSTANCE
				for component in range(FLOATS_PER_INSTANCE):
					output_buffer.append(float(input_buffer[input_start + component]))
			var range_row := {"batchKey":batch_key, "batchIndex":output_segments.size(),
				"firstInstance":output_start, "instanceCount":count,
				"sourceId":String(input.sourceId), "sourcePartId":String(input.sourcePartId),
				"sourceRevision":String(input.sourceRevision), "sourceSegmentId":String(input.segmentId),
				"sourceFirstInstance":source_cursor}
			range_row.make_read_only()
			output_ranges.append(range_row)
			var manifest: Dictionary = manifests_by_source[String(input.sourceId)]
			manifest.ranges.append(range_row)
			output_instances += count
			source_cursor += count
			if output_instances == MAX_BATCH_INSTANCES:
				var sealed_buffer := output_buffer
				sealed_buffer.make_read_only()
				output_ranges.make_read_only()
				var segment := {"batchIndex":output_segments.size(), "buffer":sealed_buffer,
					"bounds":output_bounds, "instanceCount":output_instances, "sourceRanges":output_ranges}
				segment.make_read_only()
				output_segments.append(segment)
				output_buffer = []
				output_ranges = []
				output_instances = 0
				has_output_bounds = false
		if source_cursor > int(input.instanceCount):
			return {"status":"failed", "reason":"merged_source_range_overflow"}
	if output_instances > 0:
		var sealed_buffer := output_buffer
		sealed_buffer.make_read_only()
		output_ranges.make_read_only()
		var segment := {"batchIndex":output_segments.size(), "buffer":sealed_buffer,
			"bounds":output_bounds, "instanceCount":output_instances, "sourceRanges":output_ranges}
		segment.make_read_only()
		output_segments.append(segment)
	output_segments.make_read_only()
	return {"status":"ready", "segments":output_segments}


static func _compatible_batch_key(material_key: String, render_tier: String,
		mesh_key: String, pipeline_revision: String, render_layer: String,
		transparency_sort_policy: String, cast_shadows: bool,
		visibility_end: float, fade_margin: float, mesh_local_bounds: AABB) -> String:
	var canonical := JSON.stringify([material_key, render_tier, mesh_key,
		pipeline_revision, render_layer, transparency_sort_policy, cast_shadows,
		visibility_end, fade_margin, mesh_local_bounds.position.x,
		mesh_local_bounds.position.y, mesh_local_bounds.position.z,
		mesh_local_bounds.size.x, mesh_local_bounds.size.y, mesh_local_bounds.size.z])
	return "section-batch:" + canonical.sha256_text()


static func _bounds_contained(section_bounds: AABB, bounds: AABB) -> bool:
	const EPSILON := 0.0001
	return bounds.position.x >= section_bounds.position.x - EPSILON \
		and bounds.position.y >= section_bounds.position.y - EPSILON \
		and bounds.position.z >= section_bounds.position.z - EPSILON \
		and bounds.end.x <= section_bounds.end.x + EPSILON \
		and bounds.end.y <= section_bounds.end.y + EPSILON \
		and bounds.end.z <= section_bounds.end.z + EPSILON


static func _valid_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() \
		and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0 \
		and bounds.end.is_finite()


static func _failed(reason: String) -> Dictionary:
	return {"status":"failed", "reason":reason}
