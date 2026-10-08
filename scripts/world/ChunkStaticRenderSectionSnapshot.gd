extends RefCounted
const OwnerCompletion := preload("res://scripts/world/StaticGeometryOwnerCompletion.gd")
const PresentationMembers := preload("res://scripts/world/StaticSectionPresentationMembers.gd")
## Pure, immutable contributor aggregation for one static render section.
##
## API: assemble(section_key: Vector3i, contributors: Array) -> Dictionary.
## Each contributor must be a read-only Dictionary with sourceId, sourcePartId,
## sourceRevision, logical ownerCell, sectionKey, bufferSpace="section_local",
## and a read-only batches Array. Each batch declares
## materialKey, renderTier, meshKey, render policy, and immutable segments. A
## segment carries segmentId, a read-only typed Array[float] buffer in the
## canonical transform/color/custom 20-float instance layout, bounds, and count. Compatible
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
const Attributes = preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const INSTANCE_ATTRIBUTE_LAYOUT := Attributes.LAYOUT_SCHEMA
const FLOATS_PER_INSTANCE := Attributes.FLOATS_PER_INSTANCE
const MAX_BATCH_INSTANCES := 256
const MAX_INPUT_SEGMENTS := 4096
const MAX_NATIVE_BATCHES := 4096
const MAX_PACKET_BUFFER_BYTES := 64 * 1024 * 1024
const MAX_INPUT_BUFFER_BYTES := 64 * 1024 * 1024


static func assemble(section_key: Vector3i, contributors: Array) -> Dictionary:
	var prepared := prepare_compile(section_key, contributors)
	if prepared.get("status") != "ready": return prepared
	return finalize_compile(prepared.preparation)


static func prepare_compile(section_key: Vector3i, contributors: Array) -> Dictionary:
	if not contributors.is_read_only():
		return _failed("mutable_contributor_list")
	var section_bounds := AABB(Vector3.ZERO, Vector3.ONE * Grid.SECTION_SIZE_METERS)
	var source_part_identities: Dictionary = {}
	var manifests_by_source: Dictionary = {}
	var manifest_rows: Array[Dictionary] = []
	var batch_map: Dictionary = {}
	var total_instances := 0
	var total_segments := 0
	var total_buffer_bytes := 0
	var stream_dependencies: Dictionary = {}
	var presentation_members: Array[Dictionary] = []
	var presentation_keys: Dictionary = {}
	var presentation_ids: Dictionary = {}
	for contributor_value: Variant in contributors:
		if not contributor_value is Dictionary or not contributor_value.is_read_only():
			return _failed("mutable_or_invalid_contributor")
		var contributor: Dictionary = contributor_value
		var source_id := String(contributor.get("sourceId", ""))
		var source_part_id := String(contributor.get("sourcePartId", ""))
		var source_revision := String(contributor.get("sourceRevision", ""))
		var attribute_layout := String(contributor.get("instanceAttributeLayout", ""))
		if source_id.is_empty() or source_part_id.is_empty() or source_revision.is_empty():
			return _failed("incomplete_contributor_identity")
		if attribute_layout != INSTANCE_ATTRIBUTE_LAYOUT:
			return _failed("unsupported_contributor_instance_attribute_layout")
		if contributor.get("sectionKey") != section_key:
			return _failed("contributor_section_key_mismatch")
		if String(contributor.get("bufferSpace", "")) != "section_local":
			return _failed("contributor_buffer_space_mismatch")
		var identity_key := _source_part_identity_key(source_id, source_part_id)
		if identity_key.is_empty() or source_part_identities.has(identity_key):
			return _failed("duplicate_contributor_source_identity")
		source_part_identities[identity_key] = true
		var owner_cell_value: Variant = contributor.get("ownerCell")
		if not owner_cell_value is Vector2i:
			return _failed("invalid_logical_owner_cell")
		var source_batches: Variant = contributor.get("batches")
		var geometry_source_ranges: Array[Dictionary] = []
		if not source_batches is Array or not source_batches.is_read_only():
			return _failed("mutable_or_invalid_batch_list")
		var inferred_kind := "explicit_empty" if source_batches.is_empty() else "geometry"
		var declared_kind := String(contributor.get("contributorKind", inferred_kind))
		var empty_support_ranges: Array = []
		empty_support_ranges.make_read_only()
		var support_ranges_value: Variant = contributor.get("supportRanges", empty_support_ranges)
		if declared_kind not in ["geometry", "presentation", "support_only", "explicit_empty"] \
				or not support_ranges_value is Array or not support_ranges_value.is_read_only():
			return _failed("invalid_support_contributor_manifest")
		var support_ranges: Array = support_ranges_value
		var member_values: Variant = contributor.get("presentationMembers", null)
		if member_values == null and not contributor.has("presentationMembers"):
			member_values = []
			member_values.make_read_only()
		if not member_values is Array or not member_values.is_read_only():
			return _failed("mutable_or_invalid_section_presentation_members")
		for member_value: Variant in member_values:
			var validation := PresentationMembers.validate(member_value, source_id,
				source_part_id, source_revision)
			if validation.get("status") != "ready": return validation
			var member: Dictionary = member_value
			if presentation_keys.has(member.attachmentKey) \
					or presentation_ids.has(member.presentationMemberId):
				return _failed("duplicate_section_presentation_member")
			if not PresentationMembers.valid_grid_position(member.neutralParentToWorld.origin,
					Grid.SECTION_SIZE_METERS) \
					or Grid.key_for_world_position(member.neutralParentToWorld.origin) != section_key:
				return _failed("presentation_member_anchor_section_mismatch")
			presentation_keys[member.attachmentKey] = true
			presentation_ids[member.presentationMemberId] = true
			presentation_members.append(member)
			if presentation_members.size() > PresentationMembers.MAX_MEMBERS:
				return _failed("section_presentation_member_capacity")
			var extent_validation := PresentationMembers.validate_stream_dependency_bounds(
				member.sweptWorldBounds, Grid.STREAM_CHUNK_SIZE_METERS)
			if extent_validation.get("status") != "ready": return extent_validation
			for dependency: Vector2i in _stream_chunk_keys_intersecting_bounds(member.sweptWorldBounds):
				stream_dependencies[dependency] = true
				if stream_dependencies.size() > PresentationMembers.MAX_STREAM_DEPENDENCIES:
					return _failed("section_presentation_dependency_capacity")
		for support_value: Variant in support_ranges:
			if not support_value is Dictionary or not support_value.is_read_only() \
					or not _validate_support_range(support_value, section_key,
						source_id, source_part_id, source_revision):
				return _failed("invalid_section_support_range")
			var support_dependencies: Array = support_value.get("streamChunkDependencies", [])
			for dependency_value: Variant in support_dependencies:
				stream_dependencies[Vector2i(dependency_value)] = true
			stream_dependencies[Vector2i(support_value.get("sourceOwnerChunk"))] = true
			if stream_dependencies.size() > PresentationMembers.MAX_STREAM_DEPENDENCIES:
				return _failed("section_stream_dependency_capacity")
		if declared_kind == "support_only" and (not source_batches.is_empty() \
				or not member_values.is_empty() \
				or support_ranges.is_empty()):
			return _failed("support_only_contributor_has_geometry_or_no_support")
		if declared_kind == "explicit_empty" and (not source_batches.is_empty() \
				or not support_ranges.is_empty() or not member_values.is_empty()):
			return _failed("explicit_empty_contributor_has_support_or_geometry")
		if declared_kind == "geometry" and source_batches.is_empty():
			return _failed("geometry_contributor_has_no_batches")
		if declared_kind == "presentation" and (member_values.is_empty() \
				or not source_batches.is_empty()):
			return _failed("presentation_contributor_missing_members_or_has_geometry")
		var sealed_support_ranges: Array = support_ranges.duplicate()
		sealed_support_ranges.make_read_only()
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
			var mesh_content_digest := String(batch.get("meshContentDigest", ""))
			var pipeline_revision := String(batch.get("pipelineRevision", ""))
			var render_layer := String(batch.get("renderLayer", ""))
			var transparency_sort_policy := String(batch.get("transparencySortPolicy", ""))
			var mesh_local_bounds_value: Variant = batch.get("meshLocalBounds")
			var cast_shadows: Variant = batch.get("castShadows")
			var intended_visible: Variant = batch.get("intendedVisible", true)
			var visibility_end: Variant = batch.get("visibilityRangeEnd")
			var fade_margin: Variant = batch.get("fadeMargin")
			var batch_attribute_layout := String(batch.get("instanceAttributeLayout", ""))
			if not intended_visible is bool or batch_attribute_layout != INSTANCE_ATTRIBUTE_LAYOUT \
					or material_key.is_empty() or render_tier.is_empty() or mesh_key.is_empty() \
					or mesh_content_digest.length() != 64 \
					or not mesh_content_digest.is_valid_hex_number(false) \
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
			if not valid_geometry_ownership_descriptor(batch): return _failed("section_batch_ownership_policy_mismatch")
			var batch_key := _compatible_batch_key(material_key, render_tier, mesh_key,
				mesh_content_digest,
				pipeline_revision, render_layer, transparency_sort_policy,
				cast_shadows, visibility_end, fade_margin, mesh_local_bounds,
				batch_attribute_layout, String(batch.get("attachmentKey", "")),
				batch.get("neutralParentToWorld", Transform3D.IDENTITY),
				batch.get("sweptWorldBounds", AABB()), batch.get("motion", {}), batch.get("compoundAnchor", {}), intended_visible, batch.get("producerSourceRevision", ""))
			if batch_key.is_empty(): return _failed("invalid_section_attachment_descriptor")
			var segments_value: Variant = batch.get("segments")
			if not segments_value is Array or not segments_value.is_read_only():
				return _failed("mutable_or_invalid_segment_list")
			if not seen_batch_keys.has(batch_key):
				seen_batch_keys[batch_key] = true
				manifest_batch_keys.append(batch_key)
			if not batch_map.has(batch_key):
				batch_map[batch_key] = {"instanceAttributeLayout":batch_attribute_layout,
					"batchKey":batch_key, "materialKey":material_key,
					"renderTier":render_tier, "meshKey":mesh_key,
					"meshContentDigest":mesh_content_digest,
					"meshLocalBounds":mesh_local_bounds,
					"pipelineRevision":pipeline_revision, "renderLayer":render_layer,
					"transparencySortPolicy":transparency_sort_policy,
					"castShadows":cast_shadows,
					"intendedVisible":intended_visible,
					"visibilityRangeEnd":visibility_end, "fadeMargin":fade_margin,
					"inputContributions":[]}
				if batch.has("compoundAnchor"):
					batch_map[batch_key]["compoundAnchor"] = batch.compoundAnchor
					batch_map[batch_key]["ownershipPolicy"] = "compound_attachment_anchor/v1"
				if not String(batch.get("attachmentKey", "")).is_empty():
					for field: String in ["attachmentKey", "producerSourceRevision", "neutralParentToWorld", "sweptWorldBounds", "motion"]:
						batch_map[batch_key][field] = batch[field]
					var extent_check := PresentationMembers.validate_stream_dependency_bounds(
						batch.sweptWorldBounds, Grid.STREAM_CHUNK_SIZE_METERS)
					if extent_check.get("status") != "ready": return extent_check
					for dependency: Vector2i in _stream_chunk_keys_intersecting_bounds(batch.sweptWorldBounds):
						stream_dependencies[dependency] = true
						if stream_dependencies.size() > PresentationMembers.MAX_STREAM_DEPENDENCIES:
							return _failed("section_stream_dependency_capacity")
				if batch.has("translucentSortDescriptor"):
					var sort_descriptor: Variant = batch.get("translucentSortDescriptor")
					if not sort_descriptor is Dictionary or not sort_descriptor.is_read_only():
						return _failed("mutable_or_invalid_translucent_sort_descriptor")
					batch_map[batch_key]["translucentSortDescriptor"] = sort_descriptor
			var target: Dictionary = batch_map[batch_key]
			if batch.has("translucentSortDescriptor") \
					and target.get("translucentSortDescriptor") != batch.get("translucentSortDescriptor"):
				return _failed("conflicting_translucent_sort_descriptor_for_compatible_batch")
			for segment_value: Variant in segments_value:
				if not segment_value is Dictionary or not segment_value.is_read_only():
					return _failed("mutable_or_invalid_segment")
				var segment: Dictionary = segment_value
				if segment.get("compoundAnchor") != batch.get("compoundAnchor"):
					return _failed("compound_anchor_segment_manifest_mismatch")
				var segment_id := String(segment.get("segmentId", ""))
				var buffer_value: Variant = segment.get("buffer")
				var bounds_value: Variant = segment.get("bounds")
				var segment_mesh_bounds: Variant = segment.get("meshLocalBounds")
				var instance_count_value: Variant = segment.get("instanceCount")
				if String(segment.get("instanceAttributeLayout", "")) != INSTANCE_ATTRIBUTE_LAYOUT \
						or segment_id.is_empty() or not buffer_value is Array \
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
				var extent_check := PresentationMembers.validate_stream_dependency_bounds(
					world_bounds, Grid.STREAM_CHUNK_SIZE_METERS)
				if extent_check.get("status") != "ready": return extent_check
				var expected_dependencies := _stream_chunk_keys_intersecting_bounds(world_bounds)
				if segment.has("streamChunkDependencies") and (not declared_dependencies is Array \
						or not _vector2i_arrays_equal(declared_dependencies, expected_dependencies)):
					return _failed("segment_stream_chunk_dependencies_mismatch")
				if _has_valid_center_ownership(segment, section_key) \
						and not segment.has("streamChunkDependencies"):
					return _failed("center_owned_segment_missing_stream_dependencies")
				for dependency: Vector2i in expected_dependencies:
					stream_dependencies[dependency] = true
					if stream_dependencies.size() > PresentationMembers.MAX_STREAM_DEPENDENCIES:
						return _failed("section_stream_dependency_capacity")
				var segment_key := identity_key + "\n" + batch_key + "\n" + segment_id
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
				if _has_valid_center_ownership(segment, section_key):
					# Preserve the already validated producer-to-partition mapping.
					# Final batch packing renumbers segments, so support residency must
					# not infer original member identity from the final buffer label.
					for mapping: Dictionary in segment.sourceRanges:
						var geometry_range := OwnerCompletion.packed_member(source_id, source_part_id,
							source_revision, String(mapping.sourceSegmentId), int(mapping.sourceFirstInstance),
							section_key, mesh_local_bounds, buffer_value,
							int(mapping.outputFirstInstance) * FLOATS_PER_INSTANCE, batch)
						if geometry_range.is_empty():
							return _failed("invalid_geometry_owner_packed_member")
						geometry_source_ranges.append(geometry_range)
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
		geometry_source_ranges.make_read_only()
		var manifest := {"instanceAttributeLayout":attribute_layout,
			"sourceId":source_id, "sourcePartId":source_part_id,
			"sourceRevision":source_revision, "ownerCell":owner_cell_value,
			"sectionKey":section_key, "bufferSpace":"section_local",
			"contributorKind":declared_kind,
			"supportRanges":sealed_support_ranges,
			"presentationMembers":member_values,
			"geometrySourceRanges":geometry_source_ranges,
			"batchKeys":manifest_batch_keys, "ranges":[]}
		manifests_by_source[identity_key] = manifest
		manifest_rows.append(manifest)
	manifest_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _source_part_identity_key(String(a.sourceId), String(a.sourcePartId)) \
			< _source_part_identity_key(String(b.sourceId), String(b.sourcePartId)))
	var batch_keys: Array[String] = []
	for key: Variant in batch_map:
		batch_keys.append(String(key))
	batch_keys.sort()
	for batch_key: String in batch_keys:
		var mutable_batch: Dictionary = batch_map[batch_key]
		mutable_batch.inputContributions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if String(a.sourceId) != String(b.sourceId):
				return String(a.sourceId) < String(b.sourceId)
			return String(a.segmentId) < String(b.segmentId))
		for input: Dictionary in mutable_batch.inputContributions:
			input.make_read_only()
		mutable_batch.inputContributions.make_read_only()
		mutable_batch.make_read_only()
	for row: Dictionary in manifest_rows:
		row.ranges.make_read_only()
		row.make_read_only()
	manifest_rows.make_read_only()
	batch_keys.make_read_only()
	batch_map.make_read_only()
	presentation_members.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.attachmentKey) < String(b.attachmentKey))
	presentation_members.make_read_only()
	for batch_key: String in batch_keys:
		if presentation_keys.has(String(batch_map[batch_key].get("attachmentKey", ""))):
			return _failed("borrowed_member_cannot_own_geometry_batch")
	var preparation := {"schema":"static-section-compile-preparation/v1",
		"instanceAttributeLayout":INSTANCE_ATTRIBUTE_LAYOUT,
		"sectionKey":section_key, "sectionBounds":section_bounds,
		"batchKeys":batch_keys, "batches":batch_map, "manifest":manifest_rows,
		"presentationMembers":presentation_members,
		"streamChunkDependencies":_readonly_stream_dependencies(section_key, stream_dependencies),
		"inputSegmentCount":total_segments, "instanceCount":total_instances}
	preparation.make_read_only()
	return {"status":"ready", "preparation":preparation}


## With compiled_groups supplied, only receipt validation and immutable assembly
## run here. The synchronous path is retained for existing service contracts.
static func finalize_compile(preparation: Dictionary, compiled_groups: Variant = null) -> Dictionary:
	var section_key: Vector3i = preparation.sectionKey
	var section_bounds: AABB = preparation.sectionBounds
	var batch_keys: Array = preparation.batchKeys
	var manifests_by_source: Dictionary = {}
	var manifest_rows: Array[Dictionary] = []
	for original: Dictionary in preparation.manifest:
		var row := original.duplicate(false)
		row["ranges"] = []
		manifest_rows.append(row)
		manifests_by_source[_source_part_identity_key(String(row.sourceId), String(row.sourcePartId))] = row
	if compiled_groups != null and (not compiled_groups is Dictionary or compiled_groups.size() != batch_keys.size()):
		return _failed("compiled_section_group_count_mismatch")
	var frozen_batches: Dictionary = {}
	var native_batch_count := 0
	for batch_key: String in batch_keys:
		var mutable_batch: Dictionary = preparation.batches[batch_key].duplicate(false)
		var merged: Dictionary
		if compiled_groups == null:
			merged = _merge_compatible_batch(batch_key, mutable_batch.inputContributions,
				section_bounds, manifests_by_source)
		else:
			merged = _accept_compiled_batch(batch_key, mutable_batch.inputContributions,
				compiled_groups.get(batch_key), manifests_by_source)
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
		var manifest_key := _source_part_identity_key(String(row.sourceId),
			String(row.sourcePartId))
		var ranges: Array = manifests_by_source[manifest_key].get("ranges", [])
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
	var render_layers: Array[Dictionary] = []
	for layer_name: String in ["opaque", "cutout", "translucent"]:
		var layer_batch_count := 0
		var layer_instance_count := 0
		for batch_key: String in batch_keys:
			var batch: Dictionary = frozen_batches[batch_key]
			if String(batch.get("renderLayer", "")) != layer_name:
				continue
			layer_batch_count += (batch.get("segments", []) as Array).size()
			for segment_value: Variant in batch.get("segments", []):
				layer_instance_count += int((segment_value as Dictionary).get("instanceCount", 0))
		var layer_manifest := {"layer":layer_name,
			"expectedBatchCount":layer_batch_count,
			"expectedInstanceCount":layer_instance_count}
		layer_manifest.make_read_only()
		render_layers.append(layer_manifest)
	render_layers.make_read_only()
	var snapshot := {"schema":"chunk-static-render-section-snapshot/v3",
		"instanceAttributeLayout":INSTANCE_ATTRIBUTE_LAYOUT,
		"sectionKey":section_key,
		"sectionOrigin":Grid.origin_for_key(section_key), "sectionBounds":section_bounds,
		"bufferSpace":"section_local",
		"streamChunkKey":Grid.chunk_key_for_section(section_key),
		"streamChunkDependencies":preparation.streamChunkDependencies,
		"manifest":manifest_rows, "batchKeys":batch_keys,
		"presentationMembers":preparation.presentationMembers,
		"renderLayers":render_layers,
		"batches":frozen_batches, "contributorCount":manifest_rows.size(),
		"batchGroupCount":batch_keys.size(), "batchCount":native_batch_count,
		"inputSegmentCount":int(preparation.inputSegmentCount),
		"segmentCount":native_batch_count,
		"instanceCount":int(preparation.instanceCount)}
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
		== "chunk-static-render-section-instance-partition/v3" \
		and String(segment.get("instanceAttributeLayout", "")) == INSTANCE_ATTRIBUTE_LAYOUT \
		and valid_geometry_ownership_descriptor(segment) \
		and (not segment.has("compoundAnchor") \
			or Grid.key_for_world_position(segment.compoundAnchor.worldPosition) == section_key) \
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
				or source_range.get("ownedSectionKey") != section_key \
				or not valid_geometry_ownership_descriptor(source_range) \
				or source_range.get("compoundAnchor") != segment.get("compoundAnchor"):
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
		if segment.has("compoundAnchor"): world_center = segment.compoundAnchor.worldPosition
		if Grid.key_for_world_position(world_center) != section_key:
			return false
		local_bounds = local_instance_bounds if not have_bounds else local_bounds.merge(local_instance_bounds)
		world_bounds = world_instance_bounds if not have_bounds else world_bounds.merge(world_instance_bounds)
		have_bounds = true
	return have_bounds and _bounds_approximately_equal(local_bounds, declared_local_bounds) \
		and _bounds_approximately_equal(world_bounds, declared_world_bounds)


static func _validate_support_range(value: Dictionary, section_key: Vector3i,
		source_id: String, source_part_id: String, source_revision: String) -> bool:
	var world_bounds: Variant = value.get("worldBounds", null)
	var owner_section: Variant = value.get("geometryOwnerSection", null)
	var support_section: Variant = value.get("supportSectionKey", null)
	var source_owner_chunk: Variant = value.get("sourceOwnerChunk", null)
	var owner_cell: Variant = value.get("ownerCell", null)
	var dependencies_value: Variant = value.get("streamChunkDependencies", null)
	var source_instance: Variant = value.get("sourceInstance", null)
	var member_id := String(value.get("memberId", ""))
	var prop_id := String(value.get("propId", ""))
	var source_segment_id := String(value.get("sourceSegmentId", ""))
	var ownership_policy := String(value.get("ownershipPolicy", ""))
	var ecology_support := ownership_policy == "center_geometry_owner/aabb_support_sections_v1"
	var ordinary_support := ownership_policy \
		== "ordinary_center_geometry_owner/aabb_support_sections_v1"
	var citadel_support := ownership_policy \
		== "citadel_center_geometry_owner/aabb_support_sections_v1"
	var compound_support := ownership_policy == "compound_anchor_geometry_owner/swept_support_sections_v1"
	if not valid_support_ownership_descriptor(value): return false
	citadel_support = citadel_support or compound_support
	var valid_member_identity := false
	if ecology_support:
		valid_member_identity = source_segment_id == "ecology-static:%s:%s" \
			% [member_id, source_revision] and owner_cell is Vector2i \
			and owner_cell == source_owner_chunk
	elif ordinary_support:
		valid_member_identity = member_id == source_segment_id \
			and prop_id == source_part_id and source_instance == 0 \
			and owner_cell is Vector2i \
			and String(value.get("meshContentDigest", "")).length() == 64 \
			and String(value.get("meshContentDigest", "")).is_valid_hex_number(false)
	elif citadel_support and owner_section is Vector3i and source_instance is int:
		var artifact_source_id := String(value.get("artifactSourceId", ""))
		var artifact_segment_id := String(value.get("artifactSegmentId", ""))
		var artifact_digest := String(value.get("artifactContentDigest", ""))
		valid_member_identity = not artifact_source_id.is_empty() \
			and owner_section != section_key \
			and not artifact_segment_id.is_empty() \
			and artifact_source_id.ends_with(artifact_digest.substr(0, 24)) \
			and source_segment_id == "%s:%s@%d,%d,%d" % [artifact_source_id,
				artifact_segment_id, owner_section.x, owner_section.y, owner_section.z] \
			and member_id == "%s:%d" % [source_segment_id, source_instance] \
			and prop_id == source_part_id and owner_cell is Vector2i \
			and not String(value.get("memberBinding", "")).is_empty() \
			and value.get("artifactInstanceIndex") is int \
			and int(value.get("artifactInstanceIndex", -1)) >= int(source_instance)
		for digest_field: String in ["meshContentDigest", "artifactContentDigest", "artifactSegmentDigest"]:
			var digest := String(value.get(digest_field, ""))
			valid_member_identity = valid_member_identity and digest.length() == 64 \
				and digest.is_valid_hex_number(false)
	if not world_bounds is AABB or not _valid_bounds(world_bounds): return false
	var owner_anchor: Variant = value.get("compoundAnchor", {}).get("worldPosition", world_bounds.get_center())
	if not owner_anchor is Vector3 \
			or not PresentationMembers.valid_grid_position(owner_anchor, Grid.SECTION_SIZE_METERS):
		return false
	if String(value.get("sourceId", "")) != source_id \
			or String(value.get("sourcePartId", "")) != source_part_id \
			or String(value.get("sourceRevision", "")) != source_revision \
			or not (ecology_support or ordinary_support or citadel_support) \
			or member_id.is_empty() or prop_id.is_empty() or source_segment_id.is_empty() \
			or not source_instance is int or source_instance < 0 \
			or not owner_section is Vector3i or not support_section is Vector3i \
			or support_section != section_key \
			or owner_section != Grid.key_for_world_position(owner_anchor) \
			or not valid_member_identity:
		return false
	if not source_owner_chunk is Vector2i or not owner_cell is Vector2i \
			or (ecology_support and owner_cell != source_owner_chunk) \
			or ((ordinary_support or citadel_support) and source_owner_chunk != Grid.chunk_key_for_section(owner_section)) \
			or not dependencies_value is Array \
			or not dependencies_value.is_read_only():
		return false
	var support_bounds: AABB = world_bounds
	if value.has("compoundAnchor") and not valid_compound_anchor(value.compoundAnchor): return false
	if not String(value.get("attachmentKey", "")).is_empty():
		var swept: Variant = value.get("sweptWorldBounds")
		var neutral: Variant = value.get("neutralParentToWorld")
		if not citadel_support or not swept is AABB or not _valid_bounds(swept) \
				or not neutral is Transform3D or not neutral.is_finite() \
				or not valid_attachment_motion(value.get("motion")): return false
		support_bounds = swept
		if not _bounds_contained(support_bounds, world_bounds): return false
	if PresentationMembers.validate_stream_dependency_bounds(support_bounds,
			Grid.STREAM_CHUNK_SIZE_METERS).get("status") != "ready": return false
	# Membership uses the same snapped half-open grid bounds without enumerating
	# every section in a tall support volume just to test one target.
	if not PresentationMembers.valid_grid_position(support_bounds.position, Grid.SECTION_SIZE_METERS) \
			or not PresentationMembers.valid_grid_position(support_bounds.end, Grid.SECTION_SIZE_METERS):
		return false
	for axis: int in range(3):
		if section_key[axis] < _floor_partition_coordinate(support_bounds.position[axis], Grid.SECTION_SIZE_METERS) \
				or section_key[axis] > _ceil_partition_coordinate(support_bounds.end[axis], Grid.SECTION_SIZE_METERS) - 1:
			return false
	if dependencies_value.size() > PresentationMembers.MAX_STREAM_DEPENDENCIES:
		return false
	var expected_dependencies: Array[Vector2i] = \
		_stream_chunk_keys_intersecting_bounds(support_bounds).duplicate()
	if source_owner_chunk not in expected_dependencies:
		expected_dependencies.append(source_owner_chunk)
	# Membership is the dependency authority. Producers retain their sealed
	# serialization order in the snapshot digest; compare only owned copies here.
	var actual_dependencies: Array[Vector2i] = []
	for dependency: Variant in dependencies_value:
		if not dependency is Vector2i: return false
		actual_dependencies.append(dependency)
	var dependency_order := func(a: Vector2i, b: Vector2i) -> bool:
		if a.x != b.x: return a.x < b.x
		return a.y < b.y
	expected_dependencies.sort_custom(dependency_order)
	actual_dependencies.sort_custom(dependency_order)
	# The computed set is unique, so duplicates also fail this exact comparison.
	if actual_dependencies != expected_dependencies:
		return false
	return true


static func _source_part_identity_key(source_id: String, source_part_id: String) -> String:
	if source_id.is_empty() or source_part_id.is_empty(): return ""
	return "section-part:" + var_to_bytes([source_id, source_part_id]).hex_encode()


static func _decode_instance_transform(buffer: Array, offset: int) -> Transform3D:
	return Attributes.decode_transform(buffer, offset)


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


static func _accept_compiled_batch(batch_key: String, inputs: Array,
		segments_value: Variant, manifests_by_source: Dictionary) -> Dictionary:
	if not segments_value is Array:
		return _failed("compiled_section_segments_missing")
	var segments: Array[Dictionary] = []
	var input_index := 0
	var source_cursor := 0
	for value: Variant in segments_value:
		if not value is Dictionary: return _failed("compiled_section_segment_invalid")
		var segment: Dictionary = value.duplicate(false)
		var count := int(segment.get("instanceCount", 0))
		var buffer_value: Variant = segment.get("buffer")
		var ranges_value: Variant = segment.get("sourceRanges")
		if count < 1 or count > MAX_BATCH_INSTANCES or not buffer_value is Array \
				or buffer_value.get_typed_builtin() != TYPE_FLOAT \
				or buffer_value.size() != count * FLOATS_PER_INSTANCE \
				or not ranges_value is Array or int(segment.get("batchIndex", -1)) != segments.size():
			return _failed("compiled_section_segment_capacity_mismatch")
		var ranges: Array[Dictionary] = []
		var observed := 0
		var bounds: AABB
		for range_value: Variant in ranges_value:
			if input_index >= inputs.size() or not range_value is Dictionary:
				return _failed("compiled_section_range_overflow")
			var input: Dictionary = inputs[input_index]
			var range_count := mini(MAX_BATCH_INSTANCES - observed, int(input.instanceCount) - source_cursor)
			var expected := {"batchKey":batch_key, "batchIndex":segments.size(),
				"firstInstance":observed, "instanceCount":range_count,
				"sourceId":String(input.sourceId), "sourcePartId":String(input.sourcePartId),
				"sourceRevision":String(input.sourceRevision), "sourceSegmentId":String(input.segmentId),
				"sourceFirstInstance":source_cursor}
			if range_count <= 0 or range_value != expected:
				return _failed("compiled_section_source_range_mismatch")
			bounds = input.bounds if observed == 0 else bounds.merge(input.bounds)
			expected.make_read_only()
			ranges.append(expected)
			manifests_by_source[_source_part_identity_key(String(input.sourceId), String(input.sourcePartId))].ranges.append(expected)
			observed += range_count
			source_cursor += range_count
			if source_cursor == int(input.instanceCount):
				input_index += 1
				source_cursor = 0
		if observed != count or not segment.get("bounds") is AABB \
				or not _bounds_approximately_equal(bounds, segment.bounds) \
				or (input_index < inputs.size() and count != MAX_BATCH_INSTANCES):
			return _failed("compiled_section_bounds_or_count_mismatch")
		buffer_value.make_read_only()
		ranges.make_read_only()
		segment["sourceRanges"] = ranges
		segment["segmentId"] = "merged:" + (batch_key + "\n" + str(segments.size())).sha256_text()
		segment["instanceAttributeLayout"] = INSTANCE_ATTRIBUTE_LAYOUT
		segment.make_read_only()
		segments.append(segment)
	if input_index != inputs.size() or source_cursor != 0:
		return _failed("compiled_section_source_missing")
	segments.make_read_only()
	return {"status":"ready", "segments":segments}


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
			var manifest_key := _source_part_identity_key(String(input.sourceId),
				String(input.sourcePartId))
			var manifest: Dictionary = manifests_by_source[manifest_key]
			manifest.ranges.append(range_row)
			output_instances += count
			source_cursor += count
			if output_instances == MAX_BATCH_INSTANCES:
				var sealed_buffer := output_buffer
				sealed_buffer.make_read_only()
				output_ranges.make_read_only()
				var segment_id := "merged:" + (batch_key + "\n" + str(output_segments.size())).sha256_text()
				var segment := {"segmentId":segment_id,
					"instanceAttributeLayout":INSTANCE_ATTRIBUTE_LAYOUT,
					"batchIndex":output_segments.size(), "buffer":sealed_buffer,
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
		var segment_id := "merged:" + (batch_key + "\n" + str(output_segments.size())).sha256_text()
		var segment := {"segmentId":segment_id,
			"instanceAttributeLayout":INSTANCE_ATTRIBUTE_LAYOUT,
			"batchIndex":output_segments.size(), "buffer":sealed_buffer,
			"bounds":output_bounds, "instanceCount":output_instances, "sourceRanges":output_ranges}
		segment.make_read_only()
		output_segments.append(segment)
	output_segments.make_read_only()
	return {"status":"ready", "segments":output_segments}


static func _compatible_batch_key(material_key: String, render_tier: String,
	mesh_key: String, mesh_content_digest: String, pipeline_revision: String, render_layer: String,
	transparency_sort_policy: String, cast_shadows: bool,
	visibility_end: float, fade_margin: float, mesh_local_bounds: AABB,
	instance_attribute_layout: String, attachment_key := "",
	neutral: Variant = Transform3D.IDENTITY, swept: Variant = AABB(), motion: Variant = {}, anchor: Dictionary = {}, intended_visible: bool = true, producer_revision: Variant = "") -> String:
	var canonical_fields: Array = [instance_attribute_layout, material_key, render_tier, mesh_key, mesh_content_digest,
		pipeline_revision, render_layer, transparency_sort_policy, cast_shadows,
		visibility_end, fade_margin, mesh_local_bounds.position.x,
		mesh_local_bounds.position.y, mesh_local_bounds.position.z,
		mesh_local_bounds.size.x, mesh_local_bounds.size.y, mesh_local_bounds.size.z]
	canonical_fields.append(intended_visible)
	if not attachment_key.is_empty():
		if not producer_revision is String or String(producer_revision).is_empty(): return ""
		if not neutral is Transform3D or not neutral.is_finite() \
				or absf(neutral.basis.determinant()) < 0.000001 \
				or not swept is AABB or not _valid_bounds(swept) or not valid_attachment_motion(motion): return ""
		canonical_fields.append([attachment_key, producer_revision, var_to_bytes(neutral).hex_encode(), var_to_bytes(swept).hex_encode(),var_to_bytes(motion).hex_encode()])
	if not anchor.is_empty():
		if not valid_compound_anchor(anchor): return ""
		canonical_fields.append(var_to_bytes(anchor).hex_encode())
	var canonical := JSON.stringify(canonical_fields)
	return "section-batch:" + canonical.sha256_text()


static func _bounds_contained(section_bounds: AABB, bounds: AABB) -> bool:
	const EPSILON := 0.0001
	return bounds.position.x >= section_bounds.position.x - EPSILON \
		and bounds.position.y >= section_bounds.position.y - EPSILON \
		and bounds.position.z >= section_bounds.position.z - EPSILON \
		and bounds.end.x <= section_bounds.end.x + EPSILON \
		and bounds.end.y <= section_bounds.end.y + EPSILON \
		and bounds.end.z <= section_bounds.end.z + EPSILON

static func valid_attachment_motion(value: Variant) -> bool:
	if not value is Dictionary or not value.is_read_only() or value.size() != 4 \
			or value.get("kind") not in ["swing", "raise"] \
			or not value.get("closedParentToBody") is Transform3D \
			or not value.get("raiseOffset") is Vector3 or not value.get("swing") is float: return false
	var closed: Transform3D = value.closedParentToBody
	return closed.is_finite() and absf(closed.basis.determinant()) > 0.000001 \
		and value.raiseOffset.is_finite() and is_finite(value.swing) and absf(value.swing) <= PI \
		and (value.kind != "raise" or value.raiseOffset.length_squared() > 0.000001)

static func valid_support_ownership_descriptor(value: Dictionary) -> bool:
	var policy := String(value.get("ownershipPolicy", ""))
	if value.has("compoundAnchor"):
		return policy == "compound_anchor_geometry_owner/swept_support_sections_v1" \
			and valid_compound_anchor(value.compoundAnchor)
	return policy in ["center_geometry_owner/aabb_support_sections_v1",
		"ordinary_center_geometry_owner/aabb_support_sections_v1",
		"citadel_center_geometry_owner/aabb_support_sections_v1"]


static func valid_geometry_ownership_descriptor(value: Dictionary) -> bool:
	var policy := String(value.get("ownershipPolicy", "transformed_mesh_aabb_center/v1"))
	if value.has("compoundAnchor"):
		return policy == "compound_attachment_anchor/v1" and valid_compound_anchor(value.compoundAnchor)
	return policy == "transformed_mesh_aabb_center/v1"


static func valid_compound_anchor(value: Variant) -> bool:
	return value is Dictionary and value.is_read_only() and value.size() == 2 \
		and value.get("key") is String and not String(value.key).is_empty() \
		and value.get("worldPosition") is Vector3 and value.worldPosition.is_finite()


static func _valid_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() \
		and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0 \
		and bounds.end.is_finite()


static func _failed(reason: String) -> Dictionary:
	return {"status":"failed", "reason":reason}
