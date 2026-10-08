extends SceneTree
const OwnerCompletion := preload("res://scripts/world/StaticGeometryOwnerCompletion.gd")
const OwnerSectionSlice := preload("res://scripts/world/StaticGeometryOwnerSectionSlice.gd")
## Synthetic adapter contract using a real BuildingPartPublisher artifact.
## This proves adapter/assembler schema compatibility only; it does not
## exercise CitadelPublicationService, the coordinator, native rendering, or
## legacy visual retirement.

const Publisher := preload("res://scripts/buildings/BuildingPartPublisher.gd")
const Part := preload("res://scripts/buildings/BuildingPart.gd")
const Preparation := preload("res://scripts/buildings/BuildingPublicationPreparation.gd")
const MaterialCatalog := preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")
const Adapter := preload("res://scripts/world/CitadelSectionGeometryAdapter.gd")
const Assembler := preload("res://scripts/world/WorldStaticSectionCandidateAssembler.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const Coordinator := preload("res://scripts/world/WorldStaticSectionCoordinator.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const Snapshot := preload("res://scripts/world/ChunkStaticRenderSectionSnapshot.gd")

var checks: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var parent := Node3D.new()
	root.add_child(parent)
	var publisher = Publisher.new()
	publisher.unit_box = BoxMesh.new()
	publisher.source_blueprint_id = "adapter-contract-blueprint"
	publisher.publication_site_id = "adapter-contract-site"
	publisher._scene_parent = weakref(parent)
	var material: Material = MaterialCatalog.create_material("stone_foundation")
	publisher.material_cache = {"stone_foundation":material}
	var part := Part.new({"id":"castle_tower_04_battlement_front_0",
		"kind":"beam", "material":"stone_foundation", "position":Vector3.ZERO,
		"size":Vector3.ONE, "collision":true,
		"recipe":{"visual":true, "semantic":"castle_battlement"}})
	var member_binding := Preparation.static_record_binding(part.snapshot())
	publisher.static_visual_source_part_id = part.id
	publisher.static_visual_source_revision = member_binding
	publisher.static_visual_owner_cell = Vector2i.ZERO
	publisher.static_visual_render_chunk_key = Vector2i.ZERO
	publisher.static_visual_part_tier = "structural"
	var boundary_x := float(Grid.key_for_world_position(Vector3(1.0,18.0,2.0)).x + 1) \
		* Grid.SECTION_SIZE_METERS
	var support_center_x: float = boundary_x \
		- publisher.unit_box.get_aabb().size.x * 0.54 * 0.25
	var transforms: Array[Transform3D] = [
		Transform3D(Basis.from_scale(Vector3(0.54,0.58,0.54)),Vector3(1.0,18.0,2.0)),
		Transform3D(Basis.from_scale(Vector3(0.54,0.58,0.54)),Vector3(support_center_x,18.0,2.0)),
		Transform3D(Basis.from_scale(Vector3(0.54,0.58,0.54)),Vector3(90.0,18.0,2.0))]
	var custom: Array[Color] = [Color(0.2,0.4,0.6,1.0),Color(0.8,0.3,0.1,1.0),Color(0.4,0.4,0.2,1.0)]
	for index in 2:
		publisher.collect_static_visual_transform(transforms[index],material,custom[index])
	publisher.static_visual_part_tier = "detail"
	publisher.collect_static_visual_transform(transforms[2],material,custom[2])
	publisher._record_completed_source_part(part)
	publisher._begin_static_flush(parent,false)
	var flush_steps := 0
	while publisher.has_pending_static_flush() and flush_steps < 1000:
		publisher.advance_static_flush(parent,1)
		flush_steps += 1
	var captured: Dictionary = publisher.capture_static_section_transform_artifacts(
		part.id, member_binding)
	var groups: Array = captured.get("groups", [])
	var section_key := Grid.key_for_world_position(Vector3(1.0,18.0,2.0))
	var world_id := "seed:adapter-contract:101"
	var source_id := "citadel:adapter-contract-site:member:building:%s" % part.id
	var source_identity_key := _source_part_identity_key(source_id, source_id)
	var census_revision := "census-revision-castle-battlement"
	var coverage_revision := "coverage-revision-adapter-contract"
	var provider_revision := "provider-revision-adapter-contract"
	var sections: Array[Vector3i] = [section_key]
	sections.make_read_only()
	var source_revisions := {source_identity_key:census_revision}
	source_revisions.make_read_only()
	var provider_coverage_by_section := {section_key:coverage_revision}
	provider_coverage_by_section.make_read_only()
	var provider_coverage := {"blueprint_buildings":provider_coverage_by_section}
	provider_coverage.make_read_only()
	var provider_revisions := {"blueprint_buildings":provider_revision}
	provider_revisions.make_read_only()
	var source_provider_ids := {source_identity_key:"blueprint_buildings"}
	source_provider_ids.make_read_only()
	var source_identity := {"sourceId":source_id, "sourcePartId":source_id}
	source_identity.make_read_only()
	var source_identities := {source_identity_key:source_identity}
	source_identities.make_read_only()
	var expected_members: Array[String] = [source_identity_key]
	expected_members.make_read_only()
	var expected_contributors := {section_key:expected_members}
	expected_contributors.make_read_only()
	var census := {"status":"complete", "worldId":world_id,
		"sections":sections, "sourceRevisions":source_revisions,
		"sourceIdentities":source_identities,
		"providerCoverageRevisions":provider_coverage,
		"providerSnapshotRevisions":provider_revisions,
		"sourceProviderIds":source_provider_ids,
		"expectedContributorsBySection":expected_contributors,
		"censusDigest":"census-digest-adapter-contract",
		"removalRevisions":{}}
	census.make_read_only()
	var captures := {source_id:captured}
	var bindings := {source_id:member_binding}
	var contribution_result: Dictionary = Adapter.capture_transform_artifact_contribution(
		census,section_key,7,captures,bindings)
	var contribution: Dictionary = contribution_result.get("contribution", {})
	var inputs: Array = contribution.get("inputs", [])
	var first_input: Dictionary = inputs[0] if not inputs.is_empty() else {}
	var artifact_members: Array = contribution.get("transformArtifactMembers", [])
	var artifact_member: Dictionary = artifact_members[0] \
		if not artifact_members.is_empty() else {}
	var expected_target_artifact_sources: Array[String] = []
	for group_value: Variant in groups:
		if not group_value is Dictionary:
			continue
		var group: Dictionary = group_value
		var resources: Dictionary = group.get("resourceBindings", {})
		var mesh: Variant = resources.get("mesh", null)
		if not mesh is Mesh:
			continue
		var source_to_world: Transform3D = group.get("sourceToWorld", Transform3D.IDENTITY)
		var target_group := false
		for segment_value: Variant in group.get("segments", []):
			if not segment_value is Dictionary:
				continue
			var segment: Dictionary = segment_value
			var segment_buffer: Array = segment.get("buffer", [])
			var segment_count := int(segment.get("instanceCount", 0))
			for instance_index in range(segment_count):
				var transform := Attributes.decode_transform(segment_buffer,
					instance_index * Attributes.FLOATS_PER_INSTANCE)
				var instance_world_bounds: AABB = source_to_world * (transform * mesh.get_aabb())
				var center := instance_world_bounds.position + instance_world_bounds.size * 0.5
				if Grid.key_for_world_position(center) == section_key:
					target_group = true
					break
			if target_group:
				break
		if target_group:
			expected_target_artifact_sources.append(String(group.get("sourceId", "")))
	expected_target_artifact_sources.sort()
	var emitted_target_artifact_sources: Array[String] = []
	var emitted_target_artifact_source_set: Dictionary = {}
	for input_value: Variant in inputs:
		if not input_value is Dictionary:
			continue
		var artifact_source_id := String(input_value.get("artifactSourceId", ""))
		if not artifact_source_id.is_empty() and not emitted_target_artifact_source_set.has(artifact_source_id):
			emitted_target_artifact_source_set[artifact_source_id] = true
			emitted_target_artifact_sources.append(artifact_source_id)
	emitted_target_artifact_sources.sort()
	var selected_buffer: Array = first_input.get("buffer", [])
	var selected_first_transform := Attributes.decode_transform(selected_buffer,0) \
		if selected_buffer.size() >= Attributes.FLOATS_PER_INSTANCE else Transform3D.IDENTITY
	var selected_second_transform := Attributes.decode_transform(selected_buffer,
		Attributes.FLOATS_PER_INSTANCE) \
		if selected_buffer.size() >= Attributes.FLOATS_PER_INSTANCE * 2 else Transform3D.IDENTITY
	var contributions: Array = []
	if not contribution.is_empty():
		contributions.append(contribution)
	contributions.make_read_only()
	var assembled: Dictionary = Assembler.assemble(census,section_key,contributions,7)
	var assembled_candidate: Dictionary = assembled.get("candidate", {})
	var replacement: Dictionary = assembled_candidate.get("candidate", {})
	var replacement_manifest: Array = replacement.get("snapshot", {}).get("manifest", [])
	var manifest_ids: Array[String] = []
	for row_value: Variant in replacement_manifest:
		if row_value is Dictionary:
			manifest_ids.append(String(row_value.get("sourcePartId", "")))
	manifest_ids.sort()
	checks["real_producer_artifact_ready"] = flush_steps < 1000 \
		and not publisher.has_pending_static_flush() \
		and captured.get("status") == "ready" and groups.size() == 2
	checks["direct_adapter_returns_shared_contribution_shape"] = contribution_result.get("status") == "ready" \
		and contribution.is_read_only() \
		and contribution.get("providerId") == "blueprint_buildings" \
		and contribution.get("coverageRevision") == coverage_revision \
		and contribution.get("authorityRevision") == provider_revision \
		and contribution.get("authoritySourceRevisions", {}).get(source_identity_key) == census_revision \
		and contribution.get("inputs") is Array and contribution.inputs.is_read_only() \
		and contribution.get("compatibilityByKey") is Dictionary \
		and contribution.compatibilityByKey.is_read_only() \
		and contribution.get("resourceBindings") is Dictionary \
		and contribution.resourceBindings.is_read_only()
	checks["identity_resources_and_layer_policy_survive_adapter"] = first_input.get("sourceId") == source_id \
		and first_input.get("sourcePartId") == source_id \
		and first_input.get("censusRevision") == census_revision \
		and first_input.get("memberBinding") == member_binding \
		and first_input.get("artifactSourceId", "").begins_with("building-transform:adapter-contract-site:") \
		and String(first_input.get("artifactContentDigest", "")).length() == 64 \
		and String(first_input.get("artifactSegmentDigest", "")).length() == 64 \
		and first_input.get("ownerCell") == Vector2i.ZERO \
		and first_input.get("renderChunkKey") == Vector2i.ZERO \
		and first_input.get("renderLayer") == "opaque" \
		and first_input.get("translucentSortPolicy") == "none" \
		and first_input.get("instanceCount") == 2 \
		and is_equal_approx(selected_first_transform.origin.x,1.0) \
		and is_equal_approx(selected_second_transform.origin.x,support_center_x) \
		and contribution.get("inputs", []).size() == 1 \
		and artifact_members.size() == 1
	checks["full_artifact_manifest_and_target_geometry_group_sets_match"] = \
		artifact_member.get("artifactGroupCount") == groups.size() \
		and artifact_member.get("geometryGroupCount") == expected_target_artifact_sources.size() \
		and emitted_target_artifact_sources == expected_target_artifact_sources
	checks["actual_candidate_assembler_accepts_populated_artifacts"] = assembled.get("status") == "ready" \
		and assembled_candidate.get("evidenceLevel") == "complete_authoritative_section_candidate" \
		and assembled.get("sourceCount") == 1 and assembled.get("inputCount") == 1 \
		and manifest_ids == [source_id]
	checks["missing_stale_and_partial_artifacts_remain_pending"] = \
		Adapter.capture_transform_artifact_contribution(census,section_key,8,{},bindings).get("status") == "pending" \
		and Adapter.capture_transform_artifact_contribution(census,section_key,8,captures,
			{source_id:member_binding+"-stale"}).get("status") == "pending"
	var census_without_identity := census.duplicate(false)
	census_without_identity.erase("sourceIdentities")
	census_without_identity.make_read_only()
	checks["missing_canonical_source_identity_manifest_fails_closed"] = \
		Adapter.capture_transform_artifact_contribution(census_without_identity,
			section_key,8,captures,bindings).get("status") == "pending"
	var support_section := section_key + Vector3i(1,0,0)
	var support_source_id := source_id
	var support_census := _single_source_census_for_section(census,
		support_section, support_source_id, census_revision, coverage_revision)
	var support_result: Dictionary = Adapter.capture_transform_artifact_contribution(
		support_census,support_section,9,{support_source_id:captured},
		{support_source_id:member_binding})
	var support_contribution: Dictionary = support_result.get("contribution", {})
	var support_identity_key := _source_part_identity_key(support_source_id, support_source_id)
	var support_ranges: Array = support_contribution.get("supportRangesBySource", {}).get(
		support_identity_key, [])
	var support_contributions: Array = [support_contribution]
	support_contributions.make_read_only()
	var assembled_support: Dictionary = Assembler.assemble(support_census,
		support_section, support_contributions, 9)
	checks["adjacent_center_instance_bounds_have_exact_support_without_duplicate_geometry"] = \
		support_result.get("status") == "ready" \
		and support_contribution.get("inputs", []).is_empty() \
		and support_contribution.get("explicitEmptyContributors", []).is_empty() \
		and support_ranges.size() == 1 \
		and support_ranges[0].get("geometryOwnerSection") == section_key \
		and support_ranges[0].get("supportSectionKey") == support_section \
		and support_ranges[0].get("sourceRevision") == census_revision \
		and assembled_support.get("status") == "ready" \
		and Grid.key_for_world_position(Vector3(support_center_x,18.0,2.0)) == section_key
	var matching_owner_ranges := 0
	for owner_member: Dictionary in replacement_manifest:
		for geometry_range: Dictionary in owner_member.get("geometrySourceRanges", []):
			for support_range: Dictionary in support_ranges:
				if Coordinator._static_geometry_support_matches_proof(support_range, geometry_range):
					matching_owner_ranges += 1
	checks["support_matches_exact_packed_owner_source_segment_instance_mesh_and_bounds"] = \
		matching_owner_ranges == 1 and support_source_id == source_id
	var complete_members: Array = support_result.get("geometryOwnerMembersBySource", {}).get(source_id, [])
	var sealed_roster := OwnerCompletion.seal(String(census.worldId), source_id, source_id,
		census_revision, "real-publisher:" + str(publisher.get_instance_id()), complete_members)
	var owner_sections := OwnerCompletion.owner_sections(sealed_roster.get("roster", {}))
	var owner_slice_partition := OwnerSectionSlice.partition(
		sealed_roster.get("roster", {}), owner_sections)
	var owner_slices: Array = owner_slice_partition.get("partition", {}).get("slices", [])
	var owner_slices_match: bool = owner_slice_partition.get("status") == "ready" \
		and OwnerSectionSlice.validate_partition(sealed_roster.get("roster", {}),
			owner_slice_partition.get("partition", {}), owner_sections) \
		and owner_slices.size() == owner_sections.size()
	for index in range(owner_slices.size()):
		var slice: Dictionary = owner_slices[index]
		owner_slices_match = owner_slices_match \
			and slice.get("ownerSection") == owner_sections[index] \
			and OwnerSectionSlice.validate_slice(sealed_roster.roster, slice) \
			and slice.get("members", []).all(func(member: Dictionary) -> bool:
				return member.get("geometryOwnerSection") == slice.get("ownerSection"))
	var all_owner_rows: Array[Dictionary] = []
	var all_owners_ready: bool = sealed_roster.get("status") == "ready"
	if all_owners_ready:
		for owner_section: Vector3i in OwnerCompletion.owner_sections(sealed_roster.roster):
			var owner_census := _single_source_census_for_section(census, owner_section,
				source_id, census_revision, coverage_revision)
			var owner_capture := Adapter.capture_transform_artifact_contribution(owner_census,
				owner_section, 12, captures, bindings)
			var owner_contributions: Array = [owner_capture.get("contribution", {})]
			owner_contributions.make_read_only()
			var owner_assembled := Assembler.assemble(owner_census, owner_section, owner_contributions, 12)
			all_owners_ready = all_owners_ready and owner_assembled.get("status") == "ready"
			for row: Dictionary in owner_assembled.get("candidate", {}).get("candidate", {}).get("snapshot", {}).get("manifest", []):
				all_owner_rows.append_array(row.get("geometrySourceRanges", []))
	checks["complete_real_artifact_roster_equals_all_canonical_snapshot_members"] = all_owners_ready \
		and OwnerCompletion.compare_installed_members(sealed_roster.get("roster", {}), all_owner_rows).get("status") == "ready"
	checks["real_transform_artifact_has_exhaustive_disjoint_owner_section_slices"] = \
		owner_slices_match and all_owners_ready \
		and OwnerCompletion.compare_installed_members(sealed_roster.get("roster", {}),
			all_owner_rows).get("status") == "ready"
	var incomplete_rows := all_owner_rows.duplicate()
	if not incomplete_rows.is_empty(): incomplete_rows.pop_back()
	checks["complete_real_artifact_roster_rejects_missing_packed_member"] = not all_owner_rows.is_empty() \
		and OwnerCompletion.compare_installed_members(sealed_roster.get("roster", {}), incomplete_rows).get("status") == "pending"
	_check_multiaxis_support(parent, material, census)
	var empty_section := section_key + Vector3i(3,0,0)
	var empty_source_id := source_id
	var empty_census := _single_source_census_for_section(census,
		empty_section, empty_source_id, census_revision, coverage_revision)
	var empty_contribution_result: Dictionary = Adapter.capture_transform_artifact_contribution(
		empty_census,empty_section,10,{empty_source_id:captured},
		{empty_source_id:member_binding})
	var empty_contribution: Dictionary = empty_contribution_result.get("contribution", {})
	var empty_contributions: Array = [empty_contribution]
	empty_contributions.make_read_only()
	var assembled_empty: Dictionary = Assembler.assemble(empty_census,
		empty_section,empty_contributions,10)
	var empty_manifest: Array = assembled_empty.get("candidate", {}).get("candidate", {}) \
		.get("snapshot", {}).get("manifest", [])
	checks["fully_current_nonintersecting_member_installs_as_explicit_empty"] = \
		empty_contribution_result.get("status") == "ready" \
		and empty_contribution.get("inputs", []).is_empty() \
		and empty_contribution.get("explicitEmptyContributors", []).size() == 1 \
		and String(empty_contribution.get("explicitEmptyContributors", [])[0].get(
			"sourceRevision", "")) == census_revision \
		and assembled_empty.get("status") == "ready" \
		and assembled_empty.get("inputCount") == 0 \
		and empty_manifest.size() == 1 \
		and String(empty_manifest[0].get("contributorKind", "")) == "explicit_empty"
	checks["no_legacy_packet_receipts_are_fabricated"] = contribution_result.get("status") == "ready" \
		and not contribution.has("providerPacketReceipts") \
		and not first_input.has("packetSourceId") \
		and not first_input.has("packetGeneration") \
		and publisher._chunk_static_packet_expected.is_empty() \
		and publisher._chunk_static_packet_receipts.is_empty()
	var translucent_material := StandardMaterial3D.new()
	translucent_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	checks["translucent_material_fails_closed_without_pov_descriptor"] = \
		not Adapter._material_matches_layer(translucent_material,"translucent","")
	var all_legacy_visuals_visible: bool = publisher.published_nodes.size() == groups.size()
	for legacy_visual_value: Variant in publisher.published_nodes:
		if not legacy_visual_value is MultiMeshInstance3D \
				or not (legacy_visual_value as MultiMeshInstance3D).visible:
			all_legacy_visuals_visible = false
	checks["legacy_visual_remains_visible_and_collision_ownership_is_unchanged"] = \
		all_legacy_visuals_visible \
		and part.collision_enabled and bool(part.snapshot().get("collision", false))
	var watched_resource_change_rejected := false
	var changed_capture_result: Dictionary = {}
	if not groups.is_empty():
		var watched_group: Dictionary = groups[0]
		var watched_resource: Resource = watched_group.get("resourceBindings", {}).get("mesh") as Resource
		if is_instance_valid(watched_resource):
			watched_resource.emit_changed()
			changed_capture_result = publisher.capture_static_section_transform_artifacts(
				part.id, String(watched_group.get("sourceRevision", "")))
			watched_resource_change_rejected = changed_capture_result.get("status") == "pending" \
				and changed_capture_result.get("reason") == "static_transform_artifact_resource_changed"
	checks["retained_static_artifact_resource_mutation_is_rejected_without_rehashing"] = \
		watched_resource_change_rejected
	var report := {"evidence":"synthetic_real_producer_to_citadel_transform_adapter_and_assembler_contract",
		"checks":checks, "sourcePartId":part.id, "sourceId":source_id,
		"sourceIdentityKey":source_identity_key,
		"sectionKey":section_key, "artifactGroupCount":groups.size(),
		"manifestArtifactGroupCount":int(artifact_member.get("artifactGroupCount", -1)),
		"expectedTargetArtifactGroupSources":expected_target_artifact_sources,
		"emittedTargetArtifactGroupSources":emitted_target_artifact_sources,
		"targetGeometryGroupCount":int(artifact_member.get("geometryGroupCount", -1)),
		"supportCenterX":support_center_x,
		"sectionBoundaryX":boundary_x,
		"supportStatus":support_result.get("status", "missing"),
		"supportReason":support_result.get("reason", ""),
		"supportRangeCount":support_ranges.size(),
		"inputCount":inputs.size(), "assembledInputCount":int(assembled.get("inputCount",0)),
		"assembledStatus":String(assembled.get("status", "missing")),
		"assembledReason":String(assembled.get("reason", "")),
		"assembledDetail":assembled.get("detail", assembled.get("details", {})),
		"legacyVisualCount":publisher.published_nodes.size(),
		"resourceMutationInvalidatedRevision":String(publisher._static_section_transform_artifact_invalidations.get(
			part.id, "")),
		"resourceMutationCaptureStatus":String(changed_capture_result.get("status", "not_run")),
		"resourceMutationCaptureReason":String(changed_capture_result.get("reason", "")),
		"legacyVisibleCount":publisher.published_nodes.filter(func(node: Variant) -> bool:
			return node is MultiMeshInstance3D and (node as MultiMeshInstance3D).visible).size(),
		"passed":not checks.values().has(false),
		"doesNotProve":"CitadelPublicationService integration, actual admitted site readiness, whole-section native installation/receipt, safe visual retirement, traversal, save/load, or performance."}
	var report_path := OS.get_environment("CITADEL_TRANSFORM_ADAPTER_REPORT")
	var report_file := FileAccess.open(report_path,FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report,"\t"))
		report_file.close()
	print("CITADEL TRANSFORM ARTIFACT ADAPTER ",JSON.stringify(report))
	parent.queue_free()
	quit(0 if report.passed else 1)


func _check_multiaxis_support(parent: Node3D, material: Material, base_census: Dictionary) -> void:
	var publisher = Publisher.new()
	publisher.unit_box = BoxMesh.new()
	publisher.source_blueprint_id = "multi-axis-foundation"
	publisher.publication_site_id = "multi-axis-site"
	publisher._scene_parent = weakref(parent)
	publisher.material_cache = {"stone_foundation":material}
	var part := Part.new({"id":"large-foundation", "kind":"foundation",
		"material":"stone_foundation", "position":Vector3.ZERO,
		"size":Vector3.ONE, "collision":true, "recipe":{"visual":true}})
	var binding := Preparation.static_record_binding(part.snapshot())
	publisher.static_visual_source_part_id = part.id
	publisher.static_visual_source_revision = binding
	publisher.static_visual_owner_cell = Vector2i.ZERO
	publisher.static_visual_render_chunk_key = Vector2i.ZERO
	publisher.static_visual_part_tier = "structural"
	publisher.collect_static_visual_transform(Transform3D(
		Basis.from_scale(Vector3(95.0, 0.5, 95.0)), Vector3(10.0, 18.0, 10.0)), material, Color.WHITE)
	publisher._record_completed_source_part(part)
	publisher._begin_static_flush(parent, false)
	var steps := 0
	while publisher.has_pending_static_flush() and steps < 1000:
		publisher.advance_static_flush(parent, 1)
		steps += 1
	var captured: Dictionary = publisher.capture_static_section_transform_artifacts(part.id, binding)
	var section := Vector3i(1, 0, 1)
	var source_id := "citadel:multi-axis-site:member:building:large-foundation"
	var revision := "multi-axis-foundation-revision"
	var census := _single_source_census_for_section(base_census, section, source_id,
		revision, "multi-axis-coverage")
	var result: Dictionary = Adapter.capture_transform_artifact_contribution(census, section,
		12, {source_id:captured}, {source_id:binding})
	var contribution: Dictionary = result.get("contribution", {})
	var contributions: Array = [contribution]
	contributions.make_read_only()
	var assembled: Dictionary = Assembler.assemble(census, section, contributions, 12)
	var rows: Array = contribution.get("supportRangesBySource", {}).get(
		_source_part_identity_key(source_id, source_id), [])
	print("MULTIAXIS SUPPORT DIAGNOSTIC ", JSON.stringify({
		"captureStatus":captured.get("status", ""), "captureReason":captured.get("reason", ""),
		"adapterStatus":result.get("status", ""), "adapterReason":result.get("reason", ""),
		"assemblyStatus":assembled.get("status", ""), "assemblyReason":assembled.get("reason", ""),
		"supportRowCount":rows.size()}))
	checks["real_producer_multiaxis_support_dependency_membership_assembles"] = \
		result.get("status") == "ready" and rows.size() == 1 \
		and rows[0].get("streamChunkDependencies", []).size() >= 4 \
		and assembled.get("status") == "ready"
	if rows.size() != 1: return
	var row: Dictionary = rows[0]
	var rejected_mutations := true
	for mutation: String in ["missing", "extra", "duplicate", "wrong_type"]:
		var changed := row.duplicate(false)
		var dependencies: Array = row.streamChunkDependencies.duplicate()
		match mutation:
			"missing": dependencies.pop_back()
			"extra": dependencies.append(Vector2i(9999, 9999))
			"duplicate": dependencies.append(dependencies[0])
			"wrong_type":
				var untyped: Array = []
				for key: Variant in dependencies: untyped.append(key)
				untyped[0] = "invalid"
				dependencies = untyped
		dependencies.make_read_only()
		changed["streamChunkDependencies"] = dependencies
		changed.make_read_only()
		rejected_mutations = rejected_mutations and not Snapshot._validate_support_range(
			changed, section, source_id, source_id, revision)
	checks["multiaxis_support_rejects_missing_extra_duplicate_and_mistyped_dependencies"] = rejected_mutations

func _single_source_census_for_section(base: Dictionary, section_key: Vector3i,
		source_id: String, source_revision: String,
		coverage_revision: String) -> Dictionary:
	var identity_key := _source_part_identity_key(source_id, source_id)
	var section_keys: Array[Vector3i] = [section_key]
	section_keys.make_read_only()
	var revisions := {identity_key:source_revision}
	revisions.make_read_only()
	var provider_ids := {identity_key:"blueprint_buildings"}
	provider_ids.make_read_only()
	var identity := {"sourceId":source_id, "sourcePartId":source_id}
	identity.make_read_only()
	var identities := {identity_key:identity}
	identities.make_read_only()
	var expected_members: Array[String] = [identity_key]
	expected_members.make_read_only()
	var expected := {section_key:expected_members}
	expected.make_read_only()
	var coverage_map := {section_key:coverage_revision}
	coverage_map.make_read_only()
	var provider_coverage := {"blueprint_buildings":coverage_map}
	provider_coverage.make_read_only()
	var result := base.duplicate(false)
	result["sections"] = section_keys
	result["sourceRevisions"] = revisions
	result["sourceProviderIds"] = provider_ids
	result["sourceIdentities"] = identities
	result["expectedContributorsBySection"] = expected
	result["providerCoverageRevisions"] = provider_coverage
	result.make_read_only()
	return result


func _source_part_identity_key(source_value_id: String,
		source_part_id: String) -> String:
	if source_value_id.is_empty() or source_part_id.is_empty(): return ""
	return "section-part:" + var_to_bytes([source_value_id, source_part_id]).hex_encode()
