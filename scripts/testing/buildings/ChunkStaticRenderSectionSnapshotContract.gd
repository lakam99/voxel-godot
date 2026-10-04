extends SceneTree
## Pure snapshot contract. It does not create render resources or call native code.

const Grid = preload("res://scripts/world/StaticRenderSectionGrid.gd")
const Snapshot = preload("res://scripts/world/ChunkStaticRenderSectionSnapshot.gd")
const TEST_MESH_DIGEST := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
const Partitioner = preload("res://scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd")
const Attributes = preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")

var checks: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var key := Vector3i(0, 0, 0)
	var first := _contributor("site-a:wall-1", "wall-1", "rev-a", [
		_batch("stone", "structural", "unit-box", true, 240.0, 18.0,
			[_segment("wall:000", AABB(Vector3(1, 1, 1), Vector3(1, 1, 1)), 1, 0.1)])])
	var second := _contributor("site-b:wall-2", "wall-2", "rev-b", [
		_batch("stone", "structural", "unit-box", true, 240.0, 18.0,
			[_segment("wall:000", AABB(Vector3(4, 1, 1), Vector3(1, 1, 1)), 1, 0.2)])])
	var third := _contributor("site-a:roof-1", "roof-1", "rev-c", [
		_batch("slate", "detail", "unit-box", false, 140.0, 14.0,
			[_segment("roof:000", AABB(Vector3(2, 3, 2), Vector3(1, 1, 1)), 1, 0.3)])])
	var inputs := [second, third, first]
	inputs.make_read_only()
	var assembled: Dictionary = Snapshot.assemble(key, inputs)
	var snapshot: Dictionary = assembled.get("snapshot", {})
	checks["valid_snapshot"] = assembled.get("status") == "ready" \
		and snapshot.get("schema") == "chunk-static-render-section-snapshot/v3" \
		and snapshot.get("instanceAttributeLayout") == Attributes.LAYOUT_SCHEMA \
		and snapshot.get("bufferSpace") == "section_local"
	checks["compatible_sources_share_batch"] = snapshot.get("batchCount") == 2 \
		and snapshot.get("batches", {}).size() == 2 \
		and snapshot.get("batches", {}).get(_batch_key("stone", "structural", "unit-box", true, 240.0, 18.0), {}) \
			.get("segments", []).size() == 1
	checks["manifest_sorted_and_source_to_batch_preserved"] = _manifest_ids(snapshot) == [
		"site-a:roof-1", "site-a:wall-1", "site-b:wall-2"] \
		and _manifest_batch_count(snapshot, "site-a:wall-1") == 1 \
		and _manifest_batch_count(snapshot, "site-a:roof-1") == 1
	checks["merged_batch_source_ranges_sorted"] = _batch_source_ids(snapshot,
		_batch_key("stone", "structural", "unit-box", true, 240.0, 18.0)) == [
		"site-a:wall-1", "site-b:wall-2"]
	checks["compatible_buffers_are_physically_coalesced"] = _coalesced_stone_payload(snapshot)
	checks["snapshot_tree_is_read_only"] = snapshot.is_read_only() \
		and snapshot.manifest.is_read_only() and snapshot.batchKeys.is_read_only() \
		and snapshot.batches.is_read_only() \
		and snapshot.batches[snapshot.batchKeys[0]].is_read_only() \
		and snapshot.batches[snapshot.batchKeys[0]].segments.is_read_only() \
		and snapshot.batches[snapshot.batchKeys[0]].segments[0].sourceRanges.is_read_only()
	var stone_batch: Dictionary = snapshot.batches[
		_batch_key("stone", "structural", "unit-box", true, 240.0, 18.0)]
	checks["merged_output_buffers_are_read_only"] = stone_batch.segments[0].buffer.is_read_only() \
		and stone_batch.segments[0].buffer.size() == 2 * Snapshot.FLOATS_PER_INSTANCE \
		and stone_batch.segments[0].sourceRanges.size() == 2
	var reversed_inputs: Array = [first, third, second]
	reversed_inputs.make_read_only()
	var reordered := Snapshot.assemble(key, reversed_inputs)
	checks["assembly_order_does_not_change_snapshot"] = reordered.get("status") == "ready" \
		and var_to_bytes(snapshot) == var_to_bytes(reordered.snapshot)
	var copy_on_write_inputs: Array = [first, second]
	copy_on_write_inputs.make_read_only()
	var next_snapshot := Snapshot.assemble(key, copy_on_write_inputs)
	checks["new_snapshot_does_not_mutate_prior_snapshot"] = next_snapshot.get("status") == "ready" \
		and snapshot.contributorCount == 3 and next_snapshot.snapshot.contributorCount == 2
	var empty_inputs: Array = []
	empty_inputs.make_read_only()
	var empty_result := Snapshot.assemble(key, empty_inputs)
	checks["empty_section_is_explicit_ready_snapshot"] = empty_result.get("status") == "ready" \
		and empty_result.snapshot.contributorCount == 0 \
		and empty_result.snapshot.segmentCount == 0 and empty_result.snapshot.batchKeys.is_empty()
	checks["negative_section_keeps_source_owner_separate"] = _negative_section_owner_contract()
	checks["crossing_section_records_stream_dependencies"] = _stream_dependency_contract()
	checks["unproven_cross_section_segment_rejected"] = _rejects_cross_section_segment()
	checks["center_owned_overhang_accepts_exact_source_proof_and_dependencies"] = \
		_accepts_center_owned_overhang()
	checks["center_owner_proof_uses_actual_mesh_bounds"] = _accepts_non_unit_mesh_bounds()
	checks["segment_mesh_bounds_cannot_disagree_with_batch_key"] = _rejects_mesh_bounds_mismatch()
	checks["forged_center_owner_proof_rejected"] = _rejects_forged_center_owner_proof()
	checks["invalid_logical_owner_rejected"] = _rejects_invalid_owner()
	checks["wrong_section_key_rejected"] = _rejects_wrong_section_key()
	checks["wrong_coordinate_frame_rejected"] = _rejects_wrong_coordinate_frame()
	checks["non_finite_instance_rejected"] = _rejects_non_finite_instance()
	checks["duplicate_contributor_rejected"] = _rejects_duplicate_contributor()
	checks["mutable_contributor_list_rejected"] = _rejects_mutable_input()
	checks["incompatible_policy_stays_separate"] = _separates_shadow_policy()
	checks["render_layer_and_pipeline_revision_stay_separate"] = _separates_render_layer_policy()
	checks["invalid_translucency_sort_policy_rejected"] = _rejects_invalid_sort_policy()
	checks["merged_batches_split_at_native_instance_limit"] = _splits_coalesced_batches_at_native_limit()
	var report := {"schema":"chunk-static-render-section-snapshot-contract/v1",
		"checks":checks, "passed":not checks.values().has(false),
		"evidence":"pure immutable snapshot contract; no rendering integration or gameplay acceptance"}
	var report_path := OS.get_environment("CHUNK_STATIC_RENDER_SECTION_SNAPSHOT_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	print("CHUNK STATIC RENDER SECTION SNAPSHOT ", JSON.stringify(report))
	quit(0 if report.passed else 1)


func _contributor(source_id: String, part_id: String, revision: String,
		batches: Array) -> Dictionary:
	batches.make_read_only()
	var contributor := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"sourceId":source_id, "sourcePartId":part_id,
		"sourceRevision":revision, "ownerCell":Vector2i.ZERO, "sectionKey":Vector3i.ZERO,
		"bufferSpace":"section_local", "batches":batches}
	contributor.make_read_only()
	return contributor


func _batch(material: String, tier: String, mesh_key: String, shadows: bool,
		visibility: float, fade: float, segments: Array,
		render_layer := "opaque", sort_policy := "none",
		pipeline_revision := "building_static_pipeline/v1",
		mesh_local_bounds := AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)) -> Dictionary:
	var sealed_segments: Array[Dictionary] = []
	for segment_value: Variant in segments:
		var segment: Dictionary = segment_value.duplicate(false)
		if not segment.has("meshLocalBounds"):
			segment["meshLocalBounds"] = mesh_local_bounds
		segment.make_read_only()
		sealed_segments.append(segment)
	sealed_segments.make_read_only()
	var batch := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"materialKey":material, "renderTier":tier, "meshKey":mesh_key,
		"meshContentDigest":TEST_MESH_DIGEST,
		"pipelineRevision":pipeline_revision, "renderLayer":render_layer,
		"transparencySortPolicy":sort_policy,
		"meshLocalBounds":mesh_local_bounds,
		"castShadows":shadows, "visibilityRangeEnd":visibility,
		"fadeMargin":fade, "segments":sealed_segments}
	batch.make_read_only()
	return batch


func _segment(segment_id: String, bounds: AABB, instances: int, first_value: float) -> Dictionary:
	var buffer: Array[float] = []
	for i in range(instances):
		var instance_origin := bounds.position + Vector3(0.5, 0.5, 0.5)
		buffer.append_array(Attributes.encode(Transform3D(Basis.IDENTITY, instance_origin),
			Color(first_value, 0.4, 0.6, 1.0), Color(first_value, 0.2, 0.3, 1.0)))
	buffer.make_read_only()
	var segment := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"segmentId":segment_id, "buffer":buffer,
		"bounds":bounds, "instanceCount":instances}
	segment.make_read_only()
	return segment


func _manifest_ids(snapshot: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for row: Dictionary in snapshot.get("manifest", []):
		result.append(String(row.sourceId))
	return result


func _manifest_batch_count(snapshot: Dictionary, source_id: String) -> int:
	for row: Dictionary in snapshot.get("manifest", []):
		if String(row.sourceId) == source_id:
			return row.batchKeys.size()
	return -1


func _batch_source_ids(snapshot: Dictionary, batch_key: String) -> Array[String]:
	var result: Array[String] = []
	for segment: Dictionary in snapshot.batches.get(batch_key, {}).get("segments", []):
		for range_row: Dictionary in segment.get("sourceRanges", []):
			if result.is_empty() or result.back() != String(range_row.sourceId):
				result.append(String(range_row.sourceId))
	return result


func _coalesced_stone_payload(snapshot: Dictionary) -> bool:
	var batch: Dictionary = snapshot.batches.get(
		_batch_key("stone", "structural", "unit-box", true, 240.0, 18.0), {})
	if batch.is_empty() or batch.segments.size() != 1:
		return false
	var segment: Dictionary = batch.segments[0]
	return segment.instanceCount == 2 and segment.buffer.size() == 2 * Snapshot.FLOATS_PER_INSTANCE \
		and is_equal_approx(segment.buffer[12], 0.1) \
		and is_equal_approx(segment.buffer[Snapshot.FLOATS_PER_INSTANCE + 12], 0.2) \
		and is_equal_approx(segment.buffer[16 + 1], 0.4) \
		and is_equal_approx(segment.buffer[Snapshot.FLOATS_PER_INSTANCE + 16 + 1], 0.4)


func _batch_key(material: String, tier: String, mesh_key: String, shadows: bool,
		visibility: float, fade: float, render_layer := "opaque",
		sort_policy := "none", pipeline_revision := "building_static_pipeline/v1",
		mesh_local_bounds := AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)) -> String:
	return "section-batch:" + JSON.stringify([
		Attributes.LAYOUT_SCHEMA, material, tier, mesh_key, TEST_MESH_DIGEST, pipeline_revision, render_layer, sort_policy,
		shadows, visibility, fade, mesh_local_bounds.position.x,
		mesh_local_bounds.position.y, mesh_local_bounds.position.z,
		mesh_local_bounds.size.x, mesh_local_bounds.size.y,
		mesh_local_bounds.size.z]).sha256_text()


func _negative_section_owner_contract() -> bool:
	var key := Vector3i(-1, 0, -1)
	var buffer := _segment("negative", AABB(Vector3(0.1, 1.0, 0.1), Vector3(0.25, 0.25, 0.25)), 1, 0.4)
	var contributor := _contributor("negative-source", "negative-part", "negative-r1", [
		_batch("stone", "structural", "unit-box", true, 240.0, 18.0, [buffer])])
	var corrected := contributor.duplicate(false)
	corrected["sectionKey"] = key
	corrected.make_read_only()
	var values: Array = [corrected]
	values.make_read_only()
	var result := Snapshot.assemble(key, values)
	return result.get("status") == "ready" \
		and result.snapshot.streamChunkKey == Grid.chunk_key_for_section(key) \
		and result.snapshot.manifest[0].ownerCell == Vector2i.ZERO \
		and result.snapshot.sectionKey == key


func _stream_dependency_contract() -> bool:
	var values: Array = []
	values.make_read_only()
	var result := Snapshot.assemble(Vector3i(1, 0, 0), values)
	return result.get("status") == "ready" \
		and result.snapshot.streamChunkKey == Vector2i.ZERO \
		and result.snapshot.streamChunkDependencies == [Vector2i.ZERO, Vector2i(1, 0)]


func _rejects_cross_section_segment() -> bool:
	var contributor := _contributor("cross-source", "cross-part", "cross-r1", [
		_batch("stone", "structural", "unit-box", true, 240.0, 18.0,
			[_segment("cross", AABB(Vector3(21.5, 1.0, 1.0), Vector3(0.2, 0.25, 0.25)), 1, 0.5)])])
	var values: Array = [contributor]
	values.make_read_only()
	var result := Snapshot.assemble(Vector3i.ZERO, values)
	return result.get("status") == "failed" and result.get("reason") == "segment_crosses_render_section"


func _accepts_center_owned_overhang() -> bool:
	var partitioned := Partitioner.partition(_partition_input("overhang", "r1", "seg",
		Transform3D(Basis.IDENTITY, Vector3(21.4, 1.0, 1.0))))
	if partitioned.get("status") != "ready" or partitioned.result.outputs.size() != 1:
		return false
	var output: Dictionary = partitioned.result.outputs[0]
	var segment: Dictionary = output.segment
	var contributor := _contributor(String(segment.sourceId), "part", String(segment.sourceRevision), [
		_batch("stone", "structural", "unit-box", true, 240.0, 18.0, [segment])])
	var corrected := contributor.duplicate(false)
	corrected["sectionKey"] = output.sectionKey
	corrected.make_read_only()
	var values: Array = [corrected]
	values.make_read_only()
	var result := Snapshot.assemble(output.sectionKey, values)
	return result.get("status") == "ready" \
		and result.snapshot.streamChunkDependencies.has(Vector2i.ZERO) \
		and result.snapshot.batchCount == 1


func _accepts_non_unit_mesh_bounds() -> bool:
	var mesh_bounds := AABB(Vector3.ZERO, Vector3(8.0, 1.0, 1.0))
	var partitioned := Partitioner.partition(_partition_input("wide-mesh", "r1", "seg",
		Transform3D(Basis.IDENTITY, Vector3(40.0, 1.0, 1.0)), mesh_bounds))
	if partitioned.get("status") != "ready" or partitioned.result.outputs.size() != 1:
		return false
	var output: Dictionary = partitioned.result.outputs[0]
	var segment: Dictionary = output.segment
	var contributor := _contributor(String(segment.sourceId), "wide-mesh-part",
		String(segment.sourceRevision), [
			_batch("stone", "structural", "wide-mesh", true, 240.0, 18.0,
				[segment], "opaque", "none", "building_static_pipeline/v1", mesh_bounds)])
	var corrected := contributor.duplicate(false)
	corrected["sectionKey"] = output.sectionKey
	corrected.make_read_only()
	var values: Array = [corrected]
	values.make_read_only()
	var result := Snapshot.assemble(output.sectionKey, values)
	return output.sectionKey == Vector3i(2, 0, 0) and result.get("status") == "ready" \
		and result.snapshot.manifest[0].sourceId == "wide-mesh" \
		and result.snapshot.manifest[0].ranges.size() == 1


func _rejects_mesh_bounds_mismatch() -> bool:
	var mesh_bounds := AABB(Vector3.ZERO, Vector3(8.0, 1.0, 1.0))
	var partitioned := Partitioner.partition(_partition_input("mismatch", "r1", "seg",
		Transform3D(Basis.IDENTITY, Vector3(40.0, 1.0, 1.0)), mesh_bounds))
	if partitioned.get("status") != "ready": return false
	var output: Dictionary = partitioned.result.outputs[0]
	var contributor := _contributor(String(output.sourceId), "mismatch-part",
		String(output.sourceRevision), [
			_batch("stone", "structural", "unit-box", true, 240.0, 18.0,
				[output.segment])])
	var corrected := contributor.duplicate(false)
	corrected["sectionKey"] = output.sectionKey
	corrected.make_read_only()
	var values: Array = [corrected]
	values.make_read_only()
	var result := Snapshot.assemble(output.sectionKey, values)
	return result.get("status") == "failed" and result.get("reason") == "invalid_segment_payload"


func _rejects_forged_center_owner_proof() -> bool:
	var partitioned := Partitioner.partition(_partition_input("forged", "r1", "seg",
		Transform3D(Basis.IDENTITY, Vector3(21.4, 1.0, 1.0))))
	if partitioned.get("status") != "ready" or partitioned.result.outputs.size() != 1:
		return false
	var output: Dictionary = partitioned.result.outputs[0]
	var segment: Dictionary = output.segment.duplicate(false)
	var buffer: Array[float] = segment.buffer.duplicate()
	buffer[3] += 2.0
	buffer.make_read_only()
	segment["buffer"] = buffer
	segment.make_read_only()
	var contributor := _contributor(String(segment.sourceId), "part", String(segment.sourceRevision), [
		_batch("stone", "structural", "unit-box", true, 240.0, 18.0, [segment])])
	var corrected := contributor.duplicate(false)
	corrected["sectionKey"] = output.sectionKey
	corrected.make_read_only()
	var values: Array = [corrected]
	values.make_read_only()
	var result := Snapshot.assemble(output.sectionKey, values)
	return result.get("status") == "failed" \
		and result.get("reason") == "invalid_center_owned_segment_proof"


func _partition_input(source_id: String, revision: String, segment_id: String,
		source_to_world: Transform3D,
		mesh_local_bounds := AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)) -> Array:
	var buffer: Array[float] = []
	for value: float in Attributes.encode(Transform3D.IDENTITY,
			Color(0.2, 0.3, 0.4, 1.0), Color.WHITE):
		buffer.append(value)
	buffer.make_read_only()
	var input := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"sourceId":source_id, "sourceRevision":revision,
		"sourcePartId":source_id + ":part",
		"ownerCell":Grid.logical_owner_cell_for_world_position(source_to_world.origin),
		"sourceToWorld":source_to_world, "meshLocalBounds":mesh_local_bounds,
		"batchKey":"stone", "segmentId":segment_id,
		"buffer":buffer, "instanceCount":1}
	input.make_read_only()
	var values: Array = [input]
	values.make_read_only()
	return values


func _rejects_invalid_owner() -> bool:
	var contributor := _contributor("wrong-owner", "part", "r1", [
		_batch("stone", "structural", "unit-box", true, 240.0, 18.0,
			[_segment("one", AABB(Vector3(1, 1, 1), Vector3.ONE), 1, 0.6)])])
	var invalid := contributor.duplicate(false)
	invalid["ownerCell"] = "chunk-zero"
	invalid.make_read_only()
	var values: Array = [invalid]
	values.make_read_only()
	var result := Snapshot.assemble(Vector3i.ZERO, values)
	return result.get("status") == "failed" and result.get("reason") == "invalid_logical_owner_cell"


func _rejects_wrong_section_key() -> bool:
	var contributor := _contributor("wrong-section", "part", "r1", [
		_batch("stone", "structural", "unit-box", true, 240.0, 18.0,
			[_segment("one", AABB(Vector3.ONE, Vector3.ONE), 1, 0.6)])])
	var wrong := contributor.duplicate(false)
	wrong["sectionKey"] = Vector3i(1, 0, 0)
	wrong.make_read_only()
	var values: Array = [wrong]
	values.make_read_only()
	var result := Snapshot.assemble(Vector3i.ZERO, values)
	return result.get("status") == "failed" \
		and result.get("reason") == "contributor_section_key_mismatch"


func _rejects_wrong_coordinate_frame() -> bool:
	var contributor := _contributor("wrong-frame", "part", "r1", [
		_batch("stone", "structural", "unit-box", true, 240.0, 18.0,
			[_segment("one", AABB(Vector3.ONE, Vector3.ONE), 1, 0.6)])])
	var wrong := contributor.duplicate(false)
	wrong["bufferSpace"] = "site_local"
	wrong.make_read_only()
	var values: Array = [wrong]
	values.make_read_only()
	var result := Snapshot.assemble(Vector3i.ZERO, values)
	return result.get("status") == "failed" \
		and result.get("reason") == "contributor_buffer_space_mismatch"


func _rejects_non_finite_instance() -> bool:
	var segment := _segment("non-finite", AABB(Vector3.ONE, Vector3.ONE), 1, 0.6)
	var buffer: Array[float] = segment.buffer.duplicate()
	buffer[3] = INF
	buffer.make_read_only()
	var bad_segment := segment.duplicate(false)
	bad_segment["buffer"] = buffer
	bad_segment.make_read_only()
	var contributor := _contributor("non-finite", "part", "r1", [
		_batch("stone", "structural", "unit-box", true, 240.0, 18.0, [bad_segment])])
	var values: Array = [contributor]
	values.make_read_only()
	var result := Snapshot.assemble(Vector3i.ZERO, values)
	return result.get("status") == "failed" \
		and result.get("reason") == "non_finite_segment_buffer"


func _rejects_duplicate_contributor() -> bool:
	var contributor := _contributor("duplicate", "part-a", "r1", [
		_batch("stone", "structural", "unit-box", true, 240.0, 18.0,
			[_segment("one", AABB(Vector3(1, 1, 1), Vector3.ONE), 1, 0.7)])])
	var other := _contributor("duplicate", "part-b", "r2", [
		_batch("wood", "structural", "unit-box", true, 240.0, 18.0,
			[_segment("two", AABB(Vector3(2, 1, 1), Vector3.ONE), 1, 0.8)])])
	var values: Array = [contributor, other]
	values.make_read_only()
	var result := Snapshot.assemble(Vector3i.ZERO, values)
	return result.get("status") == "failed" and result.get("reason") == "duplicate_contributor_source_id"


func _rejects_mutable_input() -> bool:
	var contributor := _contributor("mutable", "part", "r1", [])
	var values: Array = [contributor]
	var result := Snapshot.assemble(Vector3i.ZERO, values)
	return result.get("status") == "failed" and result.get("reason") == "mutable_contributor_list"


func _separates_shadow_policy() -> bool:
	var first := _contributor("policy-a", "a", "r1", [
		_batch("stone", "structural", "unit-box", true, 240.0, 18.0,
			[_segment("a", AABB(Vector3(1, 1, 1), Vector3.ONE), 1, 0.9)])])
	var second := _contributor("policy-b", "b", "r2", [
		_batch("stone", "structural", "unit-box", false, 240.0, 18.0,
			[_segment("b", AABB(Vector3(3, 1, 1), Vector3.ONE), 1, 1.0)])])
	var values: Array = [first, second]
	values.make_read_only()
	var result := Snapshot.assemble(Vector3i.ZERO, values)
	return result.get("status") == "ready" and result.snapshot.batchCount == 2


func _separates_render_layer_policy() -> bool:
	var first := _contributor("layer-opaque", "part-a", "r1", [
		_batch("shared", "structural", "unit-box", true, 240.0, 18.0,
			[_segment("a", AABB(Vector3(1, 1, 1), Vector3.ONE), 1, 0.9),], "opaque")])
	var second := _contributor("layer-cutout", "part-b", "r1", [
		_batch("shared", "structural", "unit-box", true, 240.0, 18.0,
			[_segment("b", AABB(Vector3(2, 1, 1), Vector3.ONE), 1, 1.0),], "cutout")])
	var values: Array = [first, second]
	values.make_read_only()
	var result := Snapshot.assemble(Vector3i.ZERO, values)
	if result.get("status") != "ready" or result.snapshot.batchCount != 2:
		return false
	var saw_opaque := false
	var saw_cutout := false
	for batch_key: String in result.snapshot.batchKeys:
		var layer := String(result.snapshot.batches[batch_key].renderLayer)
		saw_opaque = saw_opaque or layer == "opaque"
		saw_cutout = saw_cutout or layer == "cutout"
	return saw_opaque and saw_cutout


func _rejects_invalid_sort_policy() -> bool:
	var contributor := _contributor("bad-sort", "part", "r1", [
		_batch("glass", "detail", "pane", false, 100.0, 10.0,
			[_segment("pane", AABB(Vector3.ONE, Vector3.ONE), 1, 0.4)],
			"translucent", "none")])
	var values: Array = [contributor]
	values.make_read_only()
	return Snapshot.assemble(Vector3i.ZERO, values).get("reason") == "invalid_batch_compatibility_key"


func _splits_coalesced_batches_at_native_limit() -> bool:
	var many := _contributor("many", "many-part", "many-r1", [
		_batch("stone", "structural", "unit-box", true, 240.0, 18.0, [
			_segment("many-a", AABB(Vector3(1, 1, 1), Vector3.ONE), 200, 0.2),
			_segment("many-b", AABB(Vector3(2, 1, 1), Vector3.ONE), 100, 0.3)])])
	var values: Array = [many]
	values.make_read_only()
	var result := Snapshot.assemble(Vector3i.ZERO, values)
	if result.get("status") != "ready" or result.snapshot.batchCount != 2:
		return false
	var batch: Dictionary = result.snapshot.batches.values()[0]
	if batch.segments.size() != 2:
		return false
	var first: Dictionary = batch.segments[0]
	var second: Dictionary = batch.segments[1]
	return first.instanceCount == Snapshot.MAX_BATCH_INSTANCES \
		and second.instanceCount == 44 \
		and first.sourceRanges.size() == 2 \
		and second.sourceRanges.size() == 1 \
		and second.sourceRanges[0].sourceFirstInstance == 56
