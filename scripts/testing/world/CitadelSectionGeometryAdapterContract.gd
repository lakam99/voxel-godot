extends SceneTree

const Adapter := preload("res://scripts/world/CitadelSectionGeometryAdapter.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")

var checks: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	var section := Vector3i.ZERO
	var source_id := "citadel:site-a:member:building:part-1:section:0,0,0"
	var census := _census(section, source_id, "census-rev-1")
	var part_binding := "record-binding-1"
	var segment_buffer: Array[float] = []
	segment_buffer.assign(Attributes.encode(Transform3D(Basis.IDENTITY, Vector3(2, 2, 2)),
		Color(0.1, 0.2, 0.3, 1.0), Color(0.8, 0.7, 0.6, 1.0)))
	segment_buffer.make_read_only()
	var segment := {"segmentId":"segment-0", "buffer":segment_buffer,
		"bounds":AABB(Vector3(1.5, 1.5, 1.5), Vector3.ONE), "instanceCount":1}
	segment.make_read_only()
	var segment_map := {0:segment}
	segment_map.make_read_only()
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.45, 0.35, 0.25, 1.0)
	var mesh := BoxMesh.new()
	var group := {"sourcePartId":"part-1", "sourceRevision":part_binding,
		"siteId":"site-a", "packetSourceId":"building:site-a:part-1:0,0:mesh-a",
		"packetGeneration":4, "packetDigest":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		"packetOwnerCell":Vector2i.ZERO,
		"ownerCell":Vector2i.ZERO, "materialKey":"masonry-stone",
		"renderTier":"structural", "material":material,
		"sourceToWorld":Transform3D.IDENTITY,
		"preparedSegments":segment_map}
	var bindings := {source_id:part_binding}
	bindings.make_read_only()
	var captured: Dictionary = Adapter.capture_section(census, section, 7,
		[group], bindings, Transform3D.IDENTITY, mesh)
	check("compiled_packet_enters_shared_partition_candidate",
		captured.get("status") == "ready"
		and captured.get("schema") == "citadel-section-geometry-adapter/v1"
		and captured.get("candidateGeneration") == 7
		and captured.get("memberCount") == 1
		and captured.get("partition", {}).get("inputInstanceCount", 0) == 1,
		captured)
	check("candidate_has_digest_bound_mesh_material_and_batch_mapping",
		captured.get("compatibilityByKey", {}).size() == 1
		and captured.get("resourceBindings", {}).size() == 1
		and captured.get("members", [])[0].get("packetSourceIds", []).has(group.packetSourceId)
		and String(captured.get("members", [])[0].get("packetDigest", "")).length() == 64,
		captured)
	var census_contributor_ids: Array = census.sections[section].sourcePartIds.duplicate()
	var manifest_source_ids: Array = []
	for manifest_value: Variant in captured.get("members", []):
		if manifest_value is Dictionary:
			manifest_source_ids.append(String(manifest_value.get("sourcePartId", "")))
	manifest_source_ids.sort()
	check("candidate_manifest_source_ids_exactly_match_section_census_contributors",
		census_contributor_ids == manifest_source_ids
		and manifest_source_ids == [source_id]
		and captured.members[0].get("sourceId") == source_id
		and captured.members[0].get("packetMemberId") == "building:part-1"
		and captured.members[0].get("packetPartId") == "part-1",
		{"censusContributorIds":census_contributor_ids,
			"manifestSourceIds":manifest_source_ids,
			"manifest":captured.get("members", [])})
	var partition_output: Dictionary = captured.partition.outputs[0]
	var mapped_batch_key := String(partition_output.get("batchKey", ""))
	var member_manifest: Dictionary = captured.members[0]
	var source_range: Dictionary = partition_output.segment.sourceRanges[0]
	check("section_output_maps_exactly_to_member_packet_and_live_resources",
		captured.compatibilityByKey.has(mapped_batch_key)
		and captured.resourceBindings.has(mapped_batch_key)
		and source_range.get("sourceId") == member_manifest.sourceId
		and source_range.get("sourcePartId") == member_manifest.sourcePartId
		and source_range.get("sourceRevision") == member_manifest.sourceRevision
		and member_manifest.packetBatchKeys.has(mapped_batch_key), partition_output)
	var second_source_id := "citadel:site-b:member:building:part-1:section:0,0,0"
	var combined_census := _census(section, source_id, "census-rev-1")
	combined_census.sourceRevisions[second_source_id] = "census-rev-2"
	combined_census.sections[section].sourcePartIds.append(second_source_id)
	combined_census.sections[section].sourcePartIds.sort()
	var second_group := group.duplicate(false)
	second_group["siteId"] = "site-b"
	second_group["packetSourceId"] = "building:site-b:part-1:0,0:mesh-b"
	second_group["sourceRevision"] = "record-binding-2"
	second_group["sourceToWorld"] = Transform3D(Basis.IDENTITY, Vector3(1.0, 0.0, 0.0))
	var combined_bindings := {source_id:part_binding, second_source_id:"record-binding-2"}
	combined_bindings.make_read_only()
	var combined: Dictionary = Adapter.capture_section(combined_census, section, 7,
		[group, second_group], combined_bindings, Transform3D.IDENTITY, mesh)
	check("same_part_id_from_another_site_keeps_packet_ownership_separate",
		combined.get("status") == "ready" and combined.get("memberCount") == 2
		and combined.get("partition", {}).get("inputInstanceCount", 0) == 2
		and combined.members[0].sourceId == source_id
		and combined.members[1].sourceId == second_source_id,
		combined)
	var impacted: Array[Vector3i] = [section]
	impacted.make_read_only()
	var snapshot_result: Dictionary = SnapshotBuilder.build_replacements(
		captured.partition, captured.compatibilityByKey, impacted, 7,
		String(captured.worldId))
	check("prepared_packet_builds_the_shared_immutable_section_snapshot",
		snapshot_result.get("status") == "ready"
		and snapshot_result.get("replacements", []).size() == 1
		and snapshot_result.get("replacements", [])[0].get("snapshot", {}).get("instanceCount", 0) == 1,
		snapshot_result)
	var repeat: Dictionary = Adapter.capture_section(census, section, 7,
		[group], bindings, Transform3D.IDENTITY, mesh)
	check("same_candidate_inputs_keep_revision_and_packet_digest",
		String(repeat.get("members", [])[0].get("sourceRevision", ""))
			== String(captured.get("members", [])[0].get("sourceRevision", ""))
		and String(repeat.get("members", [])[0].get("packetDigest", ""))
			== String(captured.get("members", [])[0].get("packetDigest", "")), repeat)
	var changed_generation: Dictionary = Adapter.capture_section(census, section, 8,
		[group], bindings, Transform3D.IDENTITY, mesh)
	check("candidate_generation_is_revision_bound",
		String(changed_generation.get("members", [])[0].get("sourceRevision", ""))
			!= String(captured.get("members", [])[0].get("sourceRevision", "")), changed_generation)
	var changed_buffer: Array[float] = []
	changed_buffer.assign(Attributes.encode(Transform3D(Basis.IDENTITY, Vector3(2, 2, 2)),
		Color(0.1, 0.2, 0.3, 1.0), Color(0.2, 0.4, 0.6, 1.0)))
	changed_buffer.make_read_only()
	var changed_segment := {"segmentId":"segment-0", "buffer":changed_buffer,
		"bounds":AABB(Vector3(1.5, 1.5, 1.5), Vector3.ONE), "instanceCount":1}
	changed_segment.make_read_only()
	var changed_segments := {0:changed_segment}
	changed_segments.make_read_only()
	var changed_group := group.duplicate()
	changed_group.preparedSegments = changed_segments
	var changed_content: Dictionary = Adapter.capture_section(census, section, 7,
		[changed_group], bindings, Transform3D.IDENTITY, mesh)
	check("packet_attribute_content_change_fences_member_and_packet_digests",
		changed_content.get("status") == "ready"
		and String(changed_content.members[0].packetDigest) != String(captured.members[0].packetDigest)
		and String(changed_content.members[0].sourceRevision) != String(captured.members[0].sourceRevision),
		changed_content)
	var stale_group := group.duplicate()
	stale_group.sourceRevision = "stale-binding"
	var stale: Dictionary = Adapter.capture_section(census, section, 7,
		[stale_group], bindings, Transform3D.IDENTITY, mesh)
	check("packet_member_binding_mismatch_stays_pending",
		stale.get("status") == "pending"
		and stale.get("reason") == "citadel_packet_member_revision_mismatch", stale)
	var missing: Dictionary = Adapter.capture_section(census, section, 7,
		[], bindings, Transform3D.IDENTITY, mesh)
	check("missing_packet_geometry_stays_pending",
		missing.get("status") == "pending", missing)
	var tree_id := "citadel:site-a:member:tree:oak-1:section:0,0,0"
	var tree_pending: Dictionary = Adapter.capture_section(_census(section,
		tree_id, "tree-census-rev"), section, 7, [group], bindings,
		Transform3D.IDENTITY, mesh)
	check("tree_member_without_static_packet_mesh_stays_pending",
		tree_pending.get("status") == "pending"
		and tree_pending.get("reason") == "citadel_member_kind_has_no_static_packet_geometry",
		tree_pending)
	var transparent := StandardMaterial3D.new()
	transparent.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var transparent_group := group.duplicate()
	transparent_group.material = transparent
	var unsupported_layer: Dictionary = Adapter.capture_section(census, section, 7,
		[transparent_group], bindings, Transform3D.IDENTITY, mesh)
	check("unsupported_material_layer_stays_pending",
		unsupported_layer.get("status") == "pending"
		and unsupported_layer.get("reason") == "citadel_packet_material_layer_not_supported",
		unsupported_layer)
	var empty: Dictionary = Adapter.capture_section(_empty_census(section), section, 7,
		[], bindings, Transform3D.IDENTITY, mesh)
	check("authoritative_empty_census_is_explicit_empty_candidate",
		empty.get("status") == "ready" and empty.get("memberCount") == 0
		and empty.get("partition", {}).get("inputInstanceCount", -1) == 0, empty)
	var output := {"schema":"citadel-section-geometry-adapter-contract/v1",
		"complete":checks.all(func(row: Dictionary) -> bool: return bool(row.get("passed", false))),
		"passed":checks.all(func(row: Dictionary) -> bool: return bool(row.get("passed", false))),
		"checkCount":checks.size(), "evidenceLevel":"synthetic_prepared_packet_to_shared_partition_contract",
		"checks":checks}
	var report_path := OS.get_environment("VOXEL_CITADEL_SECTION_ADAPTER_REPORT")
	if report_path.is_empty():
		push_error("VOXEL_CITADEL_SECTION_ADAPTER_REPORT is required")
		quit(2)
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("cannot write Citadel adapter report: " + report_path)
		quit(2)
	file.store_string(JSON.stringify(output, "\t"))
	file.close()
	quit(0 if output.passed else 1)


func _census(section: Vector3i, source_id: String, revision: String) -> Dictionary:
	return {"status":"complete", "worldId":"seed:adapter-contract:1",
		"authorityRevision":"authority-rev-1",
		"sourceRevisions":{source_id:revision},
		"sections":{section:{"status":"complete", "coverageRevision":"coverage-rev-1",
			"sourcePartIds":[source_id]}}}


func _empty_census(section: Vector3i) -> Dictionary:
	return {"status":"complete", "worldId":"seed:adapter-contract:1",
		"authorityRevision":"authority-rev-1", "sourceRevisions":{},
		"sections":{section:{"status":"empty", "coverageRevision":"empty-rev-1",
			"sourcePartIds":[]}}}


func check(name: String, passed: bool, evidence: Dictionary = {}) -> void:
	checks.append({"name":name, "passed":passed, "evidence":evidence})
	if not passed:
		push_error("Citadel section adapter contract failed: " + name + " " + str(evidence))
