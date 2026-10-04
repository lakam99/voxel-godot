extends SceneTree
## Pure prepared-section adapter contract; no render resources are created.

const Grid = preload("res://scripts/world/StaticRenderSectionGrid.gd")
const Partitioner = preload("res://scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd")
const Builder = preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")

var checks: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var wood := _compatibility("wood", "structural", "wood-unit-v1")
	var slate := _compatibility("slate", "detail", "slate-unit-v1")
	var compat: Dictionary = {wood.batchKey:wood, slate.batchKey:slate}
	compat.make_read_only()
	var inputs := _inputs([
		_input("part-b", "source-b", "rev-b", Vector3(4.0, 2.0, 2.0), slate.batchKey),
		_input("part-c", "source-c", "rev-c", Vector3(Grid.SECTION_SIZE_METERS + 1.0, 2.0, 2.0), wood.batchKey),
		_input("part-a", "source-a", "rev-a", Vector3(2.0, 2.0, 2.0), wood.batchKey)])
	var partitioned: Dictionary = Partitioner.partition(inputs)
	var partition_result: Dictionary = partitioned.get("result", {})
	var outputs: Array = partition_result.get("outputs", [])
	var impacted: Array[Vector3i] = [Vector3i(1, 0, 0), Vector3i(8, 0, -3), Vector3i.ZERO]
	impacted.make_read_only()
	var built: Dictionary = Builder.build_replacements(partition_result, compat, impacted, 41, "world-test-a")
	checks["every_impacted_section_gets_one_immutable_replacement_in_key_order"] = \
		partitioned.get("status") == "ready" and built.get("status") == "ready" \
		and built.replacements.size() == 3 \
		and _replacement_keys(built.replacements) == [Vector3i.ZERO, Vector3i(1, 0, 0), Vector3i(8, 0, -3)] \
		and built.replacements.is_read_only() \
		and built.replacements.all(func(value: Dictionary) -> bool:
			return value.is_read_only() and value.snapshot.is_read_only())
	checks["contributors_batches_and_source_ranges_preserve_partition_identity"] = \
		_built_source_contract(built, Vector3i.ZERO, ["source-a", "source-b"],
			["part-a", "part-b"])
	checks["empty_impacted_section_has_explicit_zero_content_snapshot"] = \
		_empty_replacement(built, Vector3i(8, 0, -3))
	checks["snapshot_layer_manifest_covers_all_layers_and_explicit_zeros"] = \
		_layer_manifest_is_complete(built, Vector3i.ZERO, 2, 2) \
		and _layer_manifest_is_complete(built, Vector3i(8, 0, -3), 0, 0)

	var reversed_outputs: Array = outputs.duplicate()
	reversed_outputs.reverse()
	reversed_outputs.make_read_only()
	var reversed_compat: Dictionary = {slate.batchKey:slate, wood.batchKey:wood}
	reversed_compat.make_read_only()
	var reversed_impacted: Array[Vector3i] = [Vector3i.ZERO, Vector3i(8, 0, -3), Vector3i(1, 0, 0)]
	reversed_impacted.make_read_only()
	var reordered_partition: Dictionary = partition_result.duplicate(false)
	reordered_partition["outputs"] = reversed_outputs
	reordered_partition.make_read_only()
	var reordered: Dictionary = Builder.build_replacements(reordered_partition, reversed_compat,
		reversed_impacted, 41, "world-test-a")
	checks["digest_and_snapshot_bytes_are_stable_under_input_and_key_order"] = \
		built.get("status") == "ready" and reordered.get("status") == "ready" \
		and _same_replacement_digests(built.replacements, reordered.replacements) \
		and _same_snapshot_bytes(built.replacements, reordered.replacements)
	var next_generation: Dictionary = Builder.build_replacements(partition_result, compat,
		impacted, 42, "world-test-a")
	checks["digest_binds_world_and_candidate_generation"] = \
		built.get("status") == "ready" and next_generation.get("status") == "ready" \
		and _replacement_digest(built.replacements, Vector3i.ZERO) \
			!= _replacement_digest(next_generation.replacements, Vector3i.ZERO)
	checks["digest_changes_for_exact_float_buffer_payload_change"] = \
		_float_payload_changes_digest(inputs, compat, impacted, built)
	checks["digest_rejects_non_string_dictionary_keys_and_unsupported_values"] = \
		Builder._snapshot_digest({"bad-key":{1:"value"}}, "world-test-a", 41, Vector3i.ZERO).is_empty() \
		and Builder._snapshot_digest({"unsupported":Transform3D.IDENTITY},
			"world-test-a", 41, Vector3i.ZERO).is_empty()
	checks["tiny_vector3_and_bounds_changes_alter_digest"] = \
		_tiny_vector_or_bounds_change_alters_digest()
	checks["unknown_batch_compatibility_is_rejected"] = _rejects_missing_compatibility(partition_result)
	checks["tampered_range_owner_cell_is_rejected"] = \
		_rejects_range_owner_tampering(partition_result, compat, impacted)
	checks["tampered_manifest_owner_cell_is_rejected"] = \
		_rejects_manifest_owner_tampering(partition_result, compat, impacted)
	checks["omitted_output_cannot_forge_empty_or_partial_replacement"] = \
		_rejects_omitted_output(partition_result, compat, impacted)
	checks["omitted_source_manifest_is_rejected"] = \
		_rejects_omitted_source_manifest(partition_result, compat, impacted)
	checks["mismatched_partition_counts_are_rejected"] = \
		_rejects_mismatched_counts(partition_result, compat, impacted)
	checks["mutable_impact_list_is_rejected"] = \
		Builder.build_replacements(partition_result, compat, [Vector3i.ZERO], 41, "world-test-a") \
			.get("reason") == "mutable_impacted_section_keys"
	checks["invalid_world_or_generation_is_rejected"] = \
		Builder.build_replacements(partition_result, compat, impacted, 0, "world-test-a") \
			.get("reason") == "invalid_candidate_generation" \
		and Builder.build_replacements(partition_result, compat, impacted, 41, " ") \
			.get("reason") == "invalid_world_identity"

	var report := {"schema":"prepared-static-section-snapshot-builder-contract/v1",
		"checks":checks, "passed":not checks.values().has(false),
		"initialBuildStatus":built.get("status", "missing"),
		"initialBuildReason":built.get("reason", ""),
		"evidence":"pure immutable adapter contract for committed section outputs, compatibility manifests, explicit per-layer counts/empty layers, empty replacements and deterministic digests; no publisher installation, upload acknowledgement, or live gameplay acceptance"}
	var report_path := OS.get_environment("PREPARED_STATIC_SECTION_SNAPSHOT_BUILDER_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	print("PREPARED STATIC SECTION SNAPSHOT BUILDER ", JSON.stringify(report))
	quit(0 if report.passed else 1)


func _compatibility(material: String, tier: String, mesh: String) -> Dictionary:
	const MESH_DIGEST := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	var bounds := AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
	var mesh_key := "%s|pipeline=%s|layer=opaque|sort=none" % [mesh, "building-static-v1"]
	var canonical := JSON.stringify([material, tier, mesh_key, MESH_DIGEST, true, 240.0, 18.0,
		bounds.position.x, bounds.position.y, bounds.position.z,
		bounds.size.x, bounds.size.y, bounds.size.z])
	var key := "section-batch:" + canonical.sha256_text()
	var value := {"materialKey":material, "renderTier":tier,
		"meshResourceKey":mesh, "meshKey":mesh_key, "meshContentDigest":MESH_DIGEST,
		"meshLocalBounds":bounds,
		"pipelineRevision":"building-static-v1", "renderLayer":"opaque",
		"translucentSortPolicy":"none", "castShadows":true,
		"visibilityRangeEnd":240.0, "fadeMargin":18.0,
		"batchKey":key, "compatibilityKey":key}
	value.make_read_only()
	return value


func _input(part_id: String, source_id: String, revision: String,
		world_position: Vector3, batch_key: String) -> Dictionary:
	var buffer: Array[float] = [1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0,
		0.0, 0.0, 1.0, 0.0, 0.1, 0.2, 0.3, 1.0]
	buffer.make_read_only()
	var root := Transform3D(Basis.IDENTITY, world_position)
	var input := {"sourceId":source_id, "sourcePartId":part_id,
		"sourceRevision":revision,
		"ownerCell":Grid.logical_owner_cell_for_world_position(world_position),
		"sourceToWorld":root,
		"meshLocalBounds":AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE),
		"batchKey":batch_key, "segmentId":part_id + ":segment",
		"buffer":buffer, "instanceCount":1}
	input.make_read_only()
	return input


func _inputs(values: Array) -> Array:
	values.make_read_only()
	return values


func _replacement_keys(replacements: Array) -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	for replacement: Dictionary in replacements:
		keys.append(Vector3i(replacement.sectionKey))
	return keys


func _built_source_contract(result: Dictionary, section_key: Vector3i,
		source_ids: Array[String], part_ids: Array[String]) -> bool:
	if result.get("status") != "ready":
		return false
	var replacement := _replacement_for(result.replacements, section_key)
	if replacement.is_empty() or replacement.worldId != "world-test-a" \
			or replacement.generation != 41 or replacement.snapshot.contributorCount != 2:
		return false
	var actual_sources: Array[String] = []
	var actual_parts: Array[String] = []
	for row: Dictionary in replacement.snapshot.manifest:
		actual_sources.append(String(row.sourceId))
		actual_parts.append(String(row.sourcePartId))
	return actual_sources == source_ids and actual_parts == part_ids \
		and replacement.snapshot.batchCount == 2 \
		and replacement.contentManifestDigest.length() == 64


func _empty_replacement(result: Dictionary, section_key: Vector3i) -> bool:
	if result.get("status") != "ready":
		return false
	var replacement := _replacement_for(result.replacements, section_key)
	return not replacement.is_empty() and replacement.snapshot.contributorCount == 0 \
		and replacement.snapshot.instanceCount == 0 \
		and replacement.snapshot.segmentCount == 0 \
		and replacement.snapshot.batchKeys.is_empty()


func _layer_manifest_is_complete(result: Dictionary, section_key: Vector3i,
		expected_batches: int, expected_instances: int) -> bool:
	var replacement := _replacement_for(result.get("replacements", []), section_key)
	if replacement.is_empty():
		return false
	var layers: Variant = replacement.snapshot.get("renderLayers")
	if not layers is Array or layers.size() != 3:
		return false
	var by_name: Dictionary = {}
	for layer_value: Variant in layers:
		if not layer_value is Dictionary or not layer_value.is_read_only():
			return false
		by_name[String(layer_value.get("layer", ""))] = layer_value
	return by_name.size() == 3 \
		and by_name.has("opaque") and by_name.has("cutout") and by_name.has("translucent") \
		and int(by_name.opaque.get("expectedBatchCount", -1)) == expected_batches \
		and int(by_name.opaque.get("expectedInstanceCount", -1)) == expected_instances \
		and int(by_name.cutout.get("expectedBatchCount", -1)) == 0 \
		and int(by_name.cutout.get("expectedInstanceCount", -1)) == 0 \
		and int(by_name.translucent.get("expectedBatchCount", -1)) == 0 \
		and int(by_name.translucent.get("expectedInstanceCount", -1)) == 0


func _replacement_for(replacements: Array, section_key: Vector3i) -> Dictionary:
	for replacement: Dictionary in replacements:
		if replacement.sectionKey == section_key:
			return replacement
	return {}


func _replacement_digest(replacements: Array, section_key: Vector3i) -> String:
	var replacement := _replacement_for(replacements, section_key)
	return String(replacement.get("contentManifestDigest", ""))


func _same_replacement_digests(first: Array, second: Array) -> bool:
	if first.size() != second.size():
		return false
	for row: Dictionary in first:
		var other := _replacement_for(second, Vector3i(row.sectionKey))
		if other.is_empty() or row.contentManifestDigest != other.contentManifestDigest:
			return false
	return true


func _same_snapshot_bytes(first: Array, second: Array) -> bool:
	for row: Dictionary in first:
		var other := _replacement_for(second, Vector3i(row.sectionKey))
		if other.is_empty() or var_to_bytes(row.snapshot) != var_to_bytes(other.snapshot):
			return false
	return true


func _rejects_missing_compatibility(partition_result: Dictionary) -> bool:
	var missing: Dictionary = {}
	missing.make_read_only()
	var impacts: Array[Vector3i] = [Vector3i.ZERO]
	impacts.make_read_only()
	return Builder.build_replacements(partition_result, missing, impacts, 1, "world-test-a") \
		.get("reason") == "missing_or_mutable_batch_compatibility"


func _rejects_omitted_output(partition_result: Dictionary, compat: Dictionary,
		impacts: Array[Vector3i]) -> bool:
	var shortened_outputs: Array = partition_result.outputs.duplicate()
	var removed_instance_count := 0
	var removed_index := -1
	for index in range(shortened_outputs.size()):
		if String(shortened_outputs[index].sourceId) == "source-a":
			removed_instance_count = int(shortened_outputs[index].segment.instanceCount)
			removed_index = index
			break
	if removed_index < 0:
		return false
	shortened_outputs.remove_at(removed_index)
	shortened_outputs.make_read_only()
	var candidate := partition_result.duplicate(false)
	candidate["outputs"] = shortened_outputs
	# Simulate a truncated output list whose summary counts were also rewritten.
	candidate["inputInstanceCount"] = int(candidate.inputInstanceCount) - removed_instance_count
	candidate["outputInstanceCount"] = int(candidate.outputInstanceCount) - removed_instance_count
	candidate["outputSegmentCount"] = int(candidate.outputSegmentCount) - 1
	candidate["batchCount"] = int(candidate.batchCount) - 1
	candidate.make_read_only()
	var rejected: Dictionary = Builder.build_replacements(candidate, compat, impacts, 41, "world-test-a")
	return rejected.get("status") == "failed" \
		and rejected.get("reason") == "partition_manifest_instance_total_mismatch"


func _rejects_omitted_source_manifest(partition_result: Dictionary, compat: Dictionary,
		impacts: Array[Vector3i]) -> bool:
	var candidate := partition_result.duplicate(false)
	var no_manifest: Array = []
	no_manifest.make_read_only()
	candidate["sourceManifest"] = no_manifest
	candidate.make_read_only()
	return Builder.build_replacements(candidate, compat, impacts, 41, "world-test-a").get("status") == "failed"


func _rejects_mismatched_counts(partition_result: Dictionary, compat: Dictionary,
		impacts: Array[Vector3i]) -> bool:
	var candidate := partition_result.duplicate(false)
	candidate["outputInstanceCount"] = int(candidate.outputInstanceCount) + 1
	candidate.make_read_only()
	return Builder.build_replacements(candidate, compat, impacts, 41, "world-test-a").get("status") == "failed"


func _float_payload_changes_digest(inputs: Array, compat: Dictionary,
		impacts: Array[Vector3i], baseline: Dictionary) -> bool:
	var changed_inputs: Array = []
	for input_value: Variant in inputs:
		var input: Dictionary = input_value
		if String(input.sourceId) != "source-a":
			changed_inputs.append(input)
			continue
		var changed_buffer: Array[float] = input.buffer.duplicate()
		changed_buffer[12] = 0.10000000000000002
		changed_buffer.make_read_only()
		var changed_input := input.duplicate(false)
		changed_input["buffer"] = changed_buffer
		changed_input.make_read_only()
		changed_inputs.append(changed_input)
	changed_inputs.make_read_only()
	var partitioned := Partitioner.partition(changed_inputs)
	if partitioned.get("status") != "ready":
		return false
	var built_changed := Builder.build_replacements(partitioned.result, compat,
		impacts, 41, "world-test-a")
	return built_changed.get("status") == "ready" \
		and _replacement_digest(baseline.replacements, Vector3i.ZERO) \
		!= _replacement_digest(built_changed.replacements, Vector3i.ZERO)


func _tiny_vector_or_bounds_change_alters_digest() -> bool:
	var base_position := Vector3(1.0, 2.0, 3.0)
	var changed_position := Vector3(1.000001, 2.0, 3.0)
	var base_vector_digest := Builder._snapshot_digest({"position":base_position},
		"world-test-a", 41, Vector3i.ZERO)
	var changed_vector_digest := Builder._snapshot_digest({"position":changed_position},
		"world-test-a", 41, Vector3i.ZERO)
	var base_bounds_digest := Builder._snapshot_digest({"bounds":AABB(base_position, Vector3.ONE)},
		"world-test-a", 41, Vector3i.ZERO)
	var changed_bounds_digest := Builder._snapshot_digest({"bounds":AABB(changed_position, Vector3.ONE)},
		"world-test-a", 41, Vector3i.ZERO)
	return not base_vector_digest.is_empty() and not changed_vector_digest.is_empty() \
		and not base_bounds_digest.is_empty() and not changed_bounds_digest.is_empty() \
		and base_vector_digest != changed_vector_digest \
		and base_bounds_digest != changed_bounds_digest


func _rejects_range_owner_tampering(partition_result: Dictionary, compat: Dictionary,
		impacts: Array[Vector3i]) -> bool:
	var tampered := partition_result.duplicate(false)
	var outputs: Array = partition_result.outputs.duplicate()
	var first_output: Dictionary = outputs[0]
	var segment: Dictionary = first_output.segment.duplicate(false)
	var ranges: Array = segment.sourceRanges.duplicate()
	var first_range: Dictionary = ranges[0].duplicate(false)
	first_range["ownerCell"] = Vector2i(first_range.ownerCell) + Vector2i(1, 0)
	first_range.make_read_only()
	ranges[0] = first_range
	ranges.make_read_only()
	segment["sourceRanges"] = ranges
	segment.make_read_only()
	var output := first_output.duplicate(false)
	output["segment"] = segment
	output.make_read_only()
	outputs[0] = output
	outputs.make_read_only()
	tampered["outputs"] = outputs
	tampered.make_read_only()
	return Builder.build_replacements(tampered, compat, impacts, 41, "world-test-a").get("reason") \
		== "partition_source_range_identity_mismatch"


func _rejects_manifest_owner_tampering(partition_result: Dictionary, compat: Dictionary,
		impacts: Array[Vector3i]) -> bool:
	var tampered := partition_result.duplicate(false)
	var manifests: Array = partition_result.sourceManifest.duplicate()
	var changed := false
	for index in range(manifests.size()):
		var manifest: Dictionary = manifests[index]
		if String(manifest.sourceId) != "source-a":
			continue
		var changed_manifest := manifest.duplicate(false)
		changed_manifest["ownerCell"] = Vector2i(manifest.ownerCell) + Vector2i(1, 0)
		changed_manifest.make_read_only()
		manifests[index] = changed_manifest
		changed = true
		break
	if not changed:
		return false
	manifests.make_read_only()
	tampered["sourceManifest"] = manifests
	tampered.make_read_only()
	return Builder.build_replacements(tampered, compat, impacts, 41, "world-test-a").get("reason") \
		== "invalid_source_manifest_instance_identity"
