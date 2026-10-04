extends SceneTree

const Grid = preload("res://scripts/world/StaticRenderSectionGrid.gd")
const Partitioner = preload("res://scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd")
const Attributes = preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")

var checks: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var same_section := _input_list([
		_input("root-a", "rev-1", "segment-a", Transform3D(Basis.IDENTITY, Vector3(22.0, 2.0, 2.0)), "wood", [0.0, 0.25]),
		_input("root-b", "rev-9", "segment-b", Transform3D(Basis.IDENTITY, Vector3(25.0, 2.0, 2.0)), "wood", [0.0, 0.75])])
	var same_section_result := Partitioner.partition(same_section)
	checks["different_roots_are_transformed_into_same_section_space"] = \
		same_section_result.get("status") == "ready" \
		and same_section_result.result.sectionCount == 1 \
		and same_section_result.result.outputs.size() == 2 \
		and same_section_result.result.outputInstanceCount == 4 \
		and _has_local_x_for_source(same_section_result.result, "root-a", 0, 0.4) \
		and _has_local_x_for_source(same_section_result.result, "root-b", 0, 3.4) \
		and _output_for_source(same_section_result.result, "root-a").sourceRevision == "rev-1" \
		and _output_for_source(same_section_result.result, "root-b").sourceRevision == "rev-9"
	checks["source_revision_and_segment_offsets_are_preserved"] = \
		same_section_result.get("status") == "ready" \
		and _manifest_has(same_section_result.result, "root-a", "rev-1", "segment-a", 0) \
		and _manifest_has(same_section_result.result, "root-b", "rev-9", "segment-b", 1)
	checks["source_ranges_preserve_logical_owner_cell"] = \
		_owner_cell_ranges_match_source_manifest(same_section_result.result)
	checks["custom_data_is_preserved"] = same_section_result.get("status") == "ready" \
		and is_equal_approx(_output_for_source(same_section_result.result, "root-a").segment.buffer[16 + 1], 0.25)
	checks["instance_color_and_custom_lanes_remain_independent"] = same_section_result.get("status") == "ready" \
		and is_equal_approx(_output_for_source(same_section_result.result, "root-b").segment.buffer[32], 0.75) \
		and is_equal_approx(_output_for_source(same_section_result.result, "root-b").segment.buffer[33], 0.5) \
		and is_equal_approx(_output_for_source(same_section_result.result, "root-b").segment.buffer[36], 0.0) \
		and is_equal_approx(_output_for_source(same_section_result.result, "root-b").segment.buffer[37], 0.25)

	var crossing := _input_list([_input("cross", "r1", "s1",
		Transform3D(Basis.IDENTITY, Vector3(37.7, 1.0, 1.0)), "stone", [0.2])])
	var crossing_result := Partitioner.partition(crossing)
	checks["cross_boundary_instance_has_one_canonical_section_owner"] = \
		crossing_result.get("status") == "ready" \
		and crossing_result.result.sectionCount == 1 \
		and crossing_result.result.outputInstanceCount == 1 \
		and _output_section(crossing_result.result, 0) == Grid.key_for_world_position(Vector3(37.7, 1.0, 1.0))
	checks["cross_boundary_bounds_are_conservative_and_keep_full_stream_coverage"] = \
		crossing_result.get("status") == "ready" \
		and _output_segment(crossing_result.result, 0).worldBounds.position.x < Grid.STREAM_CHUNK_SIZE_METERS \
		and _output_segment(crossing_result.result, 0).worldBounds.end.x > Grid.STREAM_CHUNK_SIZE_METERS \
		and _output_segment(crossing_result.result, 0).streamChunkDependencies == [Vector2i(0, 0), Vector2i(1, 0)]
	var section_crossing := Partitioner.partition(_input_list([_input("section-cross", "r1", "s1",
		Transform3D(Basis.IDENTITY, Vector3(Grid.SECTION_SIZE_METERS * 2.0, 1.0, 1.0)), "stone", [0.0])]))
	checks["section_overhang_retains_full_local_bounds_and_center_owner_evidence"] = \
		section_crossing.get("status") == "ready" \
		and section_crossing.result.outputInstanceCount == 1 \
		and _output_section(section_crossing.result, 0) == Vector3i(2, 0, 0) \
		and _output_segment(section_crossing.result, 0).ownedSectionKey == Vector3i(2, 0, 0) \
		and _output_segment(section_crossing.result, 0).ownershipPolicy == "transformed_mesh_aabb_center/v1" \
		and _output_segment(section_crossing.result, 0).bounds.position.x < 0.0 \
		and _output_segment(section_crossing.result, 0).bounds.end.x > 0.0 \
		and _output_segment(section_crossing.result, 0).streamChunkDependencies == [Vector2i(1, 0)]
	var offset_mesh_bounds := AABB(Vector3.ZERO, Vector3(8.0, 1.0, 1.0))
	var actual_mesh_input := _input("mesh-aabb", "r1", "mesh-seg",
		Transform3D(Basis.IDENTITY, Vector3(40.0, 1.0, 1.0)), "mesh-family", [0.0], offset_mesh_bounds)
	var actual_mesh_result := Partitioner.partition(_input_list([actual_mesh_input]))
	checks["ownership_uses_actual_mesh_aabb_instead_of_unit_box"] = \
		actual_mesh_result.get("status") == "ready" \
		and _output_section(actual_mesh_result.result, 0) == Vector3i(2, 0, 0) \
		and _output_segment(actual_mesh_result.result, 0).meshLocalBounds == offset_mesh_bounds \
		and _output_segment(actual_mesh_result.result, 0).bounds.position.x < 0.0 \
		and _output_segment(actual_mesh_result.result, 0).ownershipPolicy == "transformed_mesh_aabb_center/v1"

	var rotated := _input_list([_input("rotated", "r1", "s1",
		Transform3D(Basis.from_euler(Vector3(0.0, 0.6, 0.0)).scaled(Vector3(2.0, 1.0, 0.5)),
			Vector3(2.0, 2.0, 2.0)), "stone", [0.3])])
	var rotated_result := Partitioner.partition(rotated)
	checks["bounds_cover_rotated_scaled_unit_mesh"] = rotated_result.get("status") == "ready" \
		and _output_segment(rotated_result.result, 0).worldBounds.size.x >= 1.0 \
		and _output_segment(rotated_result.result, 0).worldBounds.size.y >= 1.0 \
		and _output_segment(rotated_result.result, 0).worldBounds.size.z >= 0.5

	var deterministic_a := Partitioner.partition(_input_list([
		_input("z", "r1", "z-seg", Transform3D(Basis.IDENTITY, Vector3(2, 2, 2)), "wood", [0.1]),
		_input("a", "r1", "a-seg", Transform3D(Basis.IDENTITY, Vector3(4, 2, 2)), "wood", [0.2])]))
	var deterministic_b := Partitioner.partition(_input_list([
		_input("a", "r1", "a-seg", Transform3D(Basis.IDENTITY, Vector3(4, 2, 2)), "wood", [0.2]),
		_input("z", "r1", "z-seg", Transform3D(Basis.IDENTITY, Vector3(2, 2, 2)), "wood", [0.1])]))
	checks["input_order_does_not_change_output_bytes_or_manifest_order"] = \
		deterministic_a.get("status") == "ready" and deterministic_b.get("status") == "ready" \
		and deterministic_a.result.sourceManifest[0].sourceId == "a" \
		and deterministic_b.result.sourceManifest[0].sourceId == "a" \
		and deterministic_a.result.outputs[0].segment.buffer == deterministic_b.result.outputs[0].segment.buffer

	checks["rejects_mutable_input_list"] = Partitioner.partition([]).get("reason") == "mutable_input_list"
	checks["rejects_mutable_segment_buffer"] = _rejects_mutable_buffer()
	checks["rejects_nonfinite_transform_component"] = _rejects_nonfinite_input()
	checks["rejects_nonfinite_custom_data_component"] = _rejects_nonfinite_custom_data()
	checks["rejects_nonfinite_source_to_world_coordinate"] = _rejects_nonfinite_source_to_world()
	checks["rejects_conflicting_revisions_for_source"] = _rejects_conflicting_revision()
	checks["rejects_singular_source_transform"] = _rejects_singular_source()
	checks["rejects_truncated_buffer"] = _rejects_truncated_buffer()

	var report := {"schema":"chunk-static-render-section-instance-partitioner-contract/v1",
		"checks":checks, "passed":not checks.values().has(false),
		"evidence":"pure prepared static-mesh instance transform/partition contract; no renderer integration, queue behavior, collision, or live gameplay acceptance",
		"inputInstances":4,
		"crossBoundaryCanonicalOutputInstances":1,
		"sourceRootsKeptSeparate":2,
		"crossBoundaryStreamChunkDependencies":["0,0", "1,0"]}
	var report_path := OS.get_environment("CHUNK_STATIC_RENDER_SECTION_INSTANCE_PARTITIONER_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	print("CHUNK STATIC RENDER SECTION INSTANCE PARTITIONER ", JSON.stringify(report))
	quit(0 if report.passed else 1)


func _input(source_id: String, revision: String, segment_id: String, source_to_world: Transform3D,
		batch_key: String, origins: Array[float],
		mesh_local_bounds := AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)) -> Dictionary:
	var buffer: Array[float] = []
	for x_value: float in origins:
		buffer.append_array(_encode(Transform3D(Basis.IDENTITY, Vector3(x_value, 0.0, 0.0)),
			Color(x_value, 0.5, 0.75, 1.0), Color(0.0, 0.25, 0.5, 1.0)))
	buffer.make_read_only()
	var input := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"sourceId":source_id, "sourceRevision":revision,
		"sourcePartId":source_id + ":part",
		"ownerCell":Grid.logical_owner_cell_for_world_position(source_to_world.origin),
		"sourceToWorld":source_to_world, "meshLocalBounds":mesh_local_bounds,
		"batchKey":batch_key,
		"segmentId":segment_id, "buffer":buffer,
		"instanceCount":origins.size()}
	input.make_read_only()
	return input


func _input_list(values: Array) -> Array:
	values.make_read_only()
	return values


func _encode(transform: Transform3D, instance_color: Color, custom: Color) -> Array[float]:
	var values: Array[float] = []
	for value: float in Attributes.encode(transform, custom, instance_color):
		values.append(value)
	return values


func _output_segment(result: Dictionary, index: int) -> Dictionary:
	return result.outputs[index].segment


func _output_for_source(result: Dictionary, source_id: String) -> Dictionary:
	for output: Dictionary in result.outputs:
		if String(output.sourceId) == source_id:
			return output
	return {}


func _output_section(result: Dictionary, index: int) -> Vector3i:
	return result.outputs[index].sectionKey


func _has_local_x_for_source(result: Dictionary, source_id: String,
		instance_index: int, expected: float) -> bool:
	var output := _output_for_source(result, source_id)
	return not output.is_empty() and is_equal_approx(
		float(output.segment.buffer[instance_index * Attributes.FLOATS_PER_INSTANCE + 3]), expected)


func _manifest_has(result: Dictionary, source: String, revision: String, segment: String,
		source_instance: int) -> bool:
	for manifest: Dictionary in result.sourceManifest:
		if String(manifest.sourceId) != source or String(manifest.sourceRevision) != revision:
			continue
		for row: Dictionary in manifest.instances:
			if String(row.sourceSegmentId) == segment and int(row.sourceInstance) == source_instance:
				return true
	return false


func _owner_cell_ranges_match_source_manifest(result: Dictionary) -> bool:
	for output: Dictionary in result.outputs:
		var segment: Dictionary = output.segment
		for source_range: Dictionary in segment.sourceRanges:
			if source_range.ownerCell != output.ownerCell \
					or source_range.ownerCell != segment.ownerCell:
				return false
			var matched := false
			for manifest: Dictionary in result.sourceManifest:
				if String(manifest.sourceId) != String(source_range.sourceId):
					continue
				if manifest.ownerCell != source_range.ownerCell:
					return false
				for instance: Dictionary in manifest.instances:
					if String(instance.sourceSegmentId) == String(source_range.sourceSegmentId) \
							and int(instance.sourceInstance) == int(source_range.sourceFirstInstance) \
							and int(instance.outputInstance) == int(source_range.outputFirstInstance):
						matched = instance.ownerCell == source_range.ownerCell
			if not matched:
				return false
	return true


func _rejects_mutable_buffer() -> bool:
	var input := _input("mutable", "r1", "s1", Transform3D.IDENTITY, "stone", [0.0]).duplicate(false)
	var mutable_buffer: Array[float] = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0,
		0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0]
	input["buffer"] = mutable_buffer
	input.make_read_only()
	return Partitioner.partition(_input_list([input])).get("reason") == "mutable_or_invalid_instance_buffer"


func _rejects_nonfinite_input() -> bool:
	var input := _input("nan", "r1", "s1", Transform3D.IDENTITY, "stone", [0.0]).duplicate(false)
	var buffer: Array[float] = _encode(Transform3D(Basis.IDENTITY, Vector3(INF, 0.0, 0.0)), Color.WHITE, Color.WHITE)
	buffer.make_read_only()
	input["buffer"] = buffer
	input.make_read_only()
	return Partitioner.partition(_input_list([input])).get("reason") == "nonfinite_instance_buffer_value"


func _rejects_nonfinite_custom_data() -> bool:
	var input := _input("nan-custom", "r1", "s1", Transform3D.IDENTITY, "stone", [0.0]).duplicate(false)
	var buffer: Array[float] = _encode(Transform3D.IDENTITY, Color.WHITE, Color(INF, 0.0, 0.0, 1.0))
	buffer.make_read_only()
	input["buffer"] = buffer
	input.make_read_only()
	return Partitioner.partition(_input_list([input])).get("reason") == "nonfinite_instance_buffer_value"


func _rejects_nonfinite_source_to_world() -> bool:
	var invalid := Transform3D(Basis.IDENTITY, Vector3(0.0, INF, 0.0))
	return Partitioner.partition(_input_list([
		_input("nan-root", "r1", "s1", invalid, "stone", [0.0])])).get("reason") \
		== "invalid_source_to_world_transform"


func _rejects_conflicting_revision() -> bool:
	return Partitioner.partition(_input_list([
		_input("same", "r1", "a", Transform3D.IDENTITY, "stone", [0.0]),
		_input("same", "r2", "b", Transform3D.IDENTITY, "stone", [1.0])])).get("reason") \
		== "conflicting_source_revisions"


func _rejects_singular_source() -> bool:
	var singular := Transform3D(Basis(Vector3.ZERO, Vector3.UP, Vector3.BACK), Vector3.ZERO)
	return Partitioner.partition(_input_list([
		_input("singular", "r1", "s1", singular, "stone", [0.0])])).get("reason") \
		== "invalid_source_to_world_transform"


func _rejects_truncated_buffer() -> bool:
	var input := _input("short", "r1", "s1", Transform3D.IDENTITY, "stone", [0.0]).duplicate(false)
	var short_buffer: Array[float] = [0.0, 1.0]
	short_buffer.make_read_only()
	input["buffer"] = short_buffer
	input.make_read_only()
	return Partitioner.partition(_input_list([input])).get("reason") \
		== "invalid_instance_count_or_buffer_length"
