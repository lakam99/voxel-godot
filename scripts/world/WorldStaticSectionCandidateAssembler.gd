extends RefCounted
class_name WorldStaticSectionCandidateAssembler

## Merges complete domain captures into one production render-section snapshot.
##
## Provider adapters own deterministic source discovery and geometry capture.
## This assembler verifies that their prepared inputs cover exactly the
## authoritative roster, combines compatible batches across domains, partitions
## once, and creates one immutable section replacement. It performs no scene
## installation and cannot retire the currently visible representation.

const Partitioner := preload("res://scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")

const SCHEMA := "world-static-section-production-candidate/v1"


static func assemble(census: Dictionary, section_key: Vector3i,
		contributions: Array, candidate_generation: int) -> Dictionary:
	if census.get("status") != "complete" or candidate_generation <= 0 \
			or String(census.get("worldId", "")).is_empty():
		return _pending("authoritative_section_census_unavailable")
	if not census.get("sections") is Array or not census.get("sourceRevisions") is Dictionary \
			or not census.get("sourceProviderIds") is Dictionary \
			or not census.get("providerSnapshotRevisions") is Dictionary \
			or not census.get("providerCoverageRevisions") is Dictionary \
			or not census.get("expectedContributorsBySection") is Dictionary:
		return _failed("incomplete_authoritative_section_census")
	if not contributions.is_read_only():
		return _failed("mutable_section_provider_contributions")
	var expected_by_section: Dictionary = census.expectedContributorsBySection
	var expected_value: Variant = expected_by_section.get(section_key, null)
	if not expected_value is Array or not expected_value.is_read_only():
		return _pending("section_contributor_census_missing", {"sectionKey":section_key})
	var expected_by_provider: Dictionary = {}
	for source_part_value: Variant in expected_value:
		if not source_part_value is String or String(source_part_value).is_empty():
			return _failed("invalid_section_census_source_part")
		var source_part_id := String(source_part_value)
		var provider_id := String(census.sourceProviderIds.get(source_part_id, ""))
		if provider_id.is_empty():
			return _failed("section_census_provider_identity_missing:" + source_part_id)
		if not expected_by_provider.has(provider_id):
			expected_by_provider[provider_id] = {}
		expected_by_provider[provider_id][source_part_id] = true

	var expected_providers: Array[String] = []
	for provider_value: Variant in census.providerSnapshotRevisions:
		if not provider_value is String or String(provider_value).is_empty():
			return _failed("invalid_section_census_provider_id")
		expected_providers.append(String(provider_value))
	expected_providers.sort()
	if contributions.size() < expected_providers.size():
		return _pending("section_provider_contribution_missing")
	if contributions.size() > expected_providers.size():
		return _failed("section_provider_contribution_count_mismatch")

	var observed_provider_ids: Dictionary = {}
	var observed_source_parts: Dictionary = {}
	var source_revisions: Dictionary = census.sourceRevisions.duplicate(false)
	var compatibility_by_key: Dictionary = {}
	var materials: Dictionary = {}
	var meshes: Dictionary = {}
	var inputs: Array[Dictionary] = []
	var provider_coverage: Array = []
	for contribution_value: Variant in contributions:
		if not contribution_value is Dictionary or not contribution_value.is_read_only():
			return _failed("mutable_or_invalid_section_provider_contribution")
		var contribution: Dictionary = contribution_value
		var provider_id := String(contribution.get("providerId", ""))
		if provider_id.is_empty() or observed_provider_ids.has(provider_id) \
				or not expected_providers.has(provider_id):
			return _failed("duplicate_or_unregistered_section_provider_contribution")
		observed_provider_ids[provider_id] = true
		if contribution.get("sectionKey") != section_key:
			return _failed("section_provider_contribution_key_mismatch:" + provider_id)
		var expected_coverage: Variant = census.providerCoverageRevisions.get(provider_id, {})
		var coverage_revision := String(contribution.get("coverageRevision", ""))
		if not expected_coverage is Dictionary \
				or coverage_revision.is_empty() \
				or String(expected_coverage.get(section_key, "")) != coverage_revision:
			return _pending("section_provider_coverage_revision_mismatch", {
				"providerId":provider_id, "sectionKey":section_key})
		if String(contribution.get("authorityRevision", "")) \
				!= String(census.providerSnapshotRevisions.get(provider_id, "")):
			return _pending("section_provider_authority_revision_mismatch", {
				"providerId":provider_id})
		var authority_revisions_value: Variant = contribution.get("authoritySourceRevisions", null)
		var inputs_value: Variant = contribution.get("inputs", null)
		var compatibility_value: Variant = contribution.get("compatibilityByKey", null)
		if not authority_revisions_value is Dictionary or not authority_revisions_value.is_read_only() \
				or not inputs_value is Array or not inputs_value.is_read_only() \
				or not compatibility_value is Dictionary or not compatibility_value.is_read_only():
			return _failed("incomplete_section_provider_payload:" + provider_id)
		var expected_members: Dictionary = expected_by_provider.get(provider_id, {})
		if authority_revisions_value.size() != expected_members.size():
			return _failed("section_provider_member_count_mismatch:" + provider_id)
		for source_part_value: Variant in authority_revisions_value:
			var source_part_id := String(source_part_value)
			var authority_revision := String(authority_revisions_value[source_part_value])
			if not expected_members.has(source_part_id) or authority_revision.is_empty() \
					or String(census.sourceRevisions.get(source_part_id, "")) != authority_revision:
				return _pending("section_provider_source_revision_stale", {
					"providerId":provider_id, "sourcePartId":source_part_id})
			if observed_source_parts.has(source_part_id):
				return _failed("section_source_part_owned_by_multiple_providers:" + source_part_id)
			observed_source_parts[source_part_id] = provider_id
		if inputs_value.size() != expected_members.size() and not expected_members.is_empty():
			# Each declared contributor must supply geometry. A census member with
			# no render input is not an explicit visual-empty success.
			var input_members: Dictionary = {}
			for input_value: Variant in inputs_value:
				if input_value is Dictionary:
					input_members[String(input_value.get("sourcePartId", ""))] = true
			for source_part_value: Variant in expected_members:
				if not input_members.has(String(source_part_value)):
					return _pending("section_source_has_no_render_geometry", {
						"providerId":provider_id, "sourcePartId":String(source_part_value)})
		var resource_result := _merge_provider_resources(contribution,
			compatibility_value, compatibility_by_key, materials, meshes)
		if resource_result.get("status") != "ready":
			return resource_result
		for input_value: Variant in inputs_value:
			if not input_value is Dictionary or not input_value.is_read_only():
				return _failed("mutable_or_invalid_section_instance_input")
			var input: Dictionary = input_value
			var source_part_id := String(input.get("sourcePartId", ""))
			var source_id := String(input.get("sourceId", ""))
			var source_revision := String(input.get("sourceRevision", ""))
			var batch_key := String(input.get("batchKey", ""))
			if source_part_id.is_empty() or source_id.is_empty() or source_revision.is_empty() \
					or batch_key.is_empty() or not expected_members.has(source_part_id) \
					or not compatibility_value.has(batch_key):
				return _failed("section_instance_input_not_in_provider_manifest:" + provider_id)
			if not observed_source_parts.has(source_part_id) \
					or String(observed_source_parts[source_part_id]) != provider_id:
				return _failed("section_instance_input_source_owner_mismatch:" + source_part_id)
			var normalized := input.duplicate(false)
			normalized["providerId"] = provider_id
			normalized.make_read_only()
			inputs.append(normalized)
		var coverage_row: Array = [provider_id, coverage_revision,
			String(contribution.authorityRevision)]
		coverage_row.make_read_only()
		provider_coverage.append(coverage_row)
	for provider_id: String in expected_providers:
		if not observed_provider_ids.has(provider_id):
			return _pending("section_provider_contribution_missing:" + provider_id)
	var expected_source_ids: Array[String] = []
	for source_part_value: Variant in expected_value:
		expected_source_ids.append(String(source_part_value))
	expected_source_ids.sort()
	var observed_source_ids: Array[String] = []
	for source_part_value: Variant in observed_source_parts:
		observed_source_ids.append(String(source_part_value))
	observed_source_ids.sort()
	if expected_source_ids != observed_source_ids:
		return _failed("whole_section_source_manifest_mismatch")
	inputs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if String(a.sourceId) != String(b.sourceId): return String(a.sourceId) < String(b.sourceId)
		if String(a.batchKey) != String(b.batchKey): return String(a.batchKey) < String(b.batchKey)
		return String(a.segmentId) < String(b.segmentId))
	inputs.make_read_only()
	compatibility_by_key.make_read_only()
	materials.make_read_only()
	meshes.make_read_only()
	var partition_result := Partitioner.partition(inputs)
	if partition_result.get("status") != "ready":
		return _failed("whole_section_cross_domain_partition_failed:" + String(partition_result.get("reason", "unknown")))
	var partition: Dictionary = partition_result.result
	for output_value: Variant in partition.get("outputs", []):
		if output_value.get("sectionKey") != section_key:
			return _pending("whole_section_candidate_owns_adjacent_section", {
				"requestedSection":section_key,
				"ownedSection":output_value.get("sectionKey"),
				"sourcePartId":String(output_value.get("sourcePartId", ""))})
	var impacted_sections: Array[Vector3i] = [section_key]
	impacted_sections.make_read_only()
	var replacements := SnapshotBuilder.build_replacements(partition,
		compatibility_by_key, impacted_sections, candidate_generation,
		String(census.worldId))
	if replacements.get("status") != "ready":
		return _failed("whole_section_snapshot_build_failed:" + String(replacements.get("reason", "unknown")))
	var replacement_rows: Array = replacements.get("replacements", [])
	if replacement_rows.size() != 1 or not replacement_rows[0] is Dictionary:
		return _failed("whole_section_snapshot_replacement_missing")
	var replacement: Dictionary = replacement_rows[0]
	var manifest_ids: Array[String] = []
	for row_value: Variant in replacement.get("snapshot", {}).get("manifest", []):
		manifest_ids.append(String(row_value.get("sourcePartId", "")))
	manifest_ids.sort()
	if manifest_ids != expected_source_ids:
		return _failed("whole_section_candidate_manifest_not_exact")
	provider_coverage.sort_custom(func(a: Array, b: Array) -> bool:
		return String(a[0]) < String(b[0]))
	var candidate := {"schema":SCHEMA, "worldId":String(census.worldId),
		"sectionKey":section_key, "generation":candidate_generation,
		"contentManifestDigest":String(replacement.get("contentManifestDigest", "")),
		"censusDigest":String(census.get("censusDigest", "")),
		"sourceRevisions":census.sourceRevisions,
		"removalRevisions":census.get("removalRevisions", {}),
		"providerCoverage":provider_coverage,
		"candidate":replacement,
		"materialBindings":materials, "meshBindings":meshes,
		"inputCount":inputs.size(), "evidenceLevel":"complete_authoritative_section_candidate"}
	candidate.providerCoverage.make_read_only()
	candidate.make_read_only()
	return {"status":"ready", "candidate":candidate,
		"providerCount":expected_providers.size(),
		"sourceCount":expected_source_ids.size(), "inputCount":inputs.size(),
		"batchCount":compatibility_by_key.size(),
		"contentManifestDigest":String(replacement.get("contentManifestDigest", ""))}


static func _merge_provider_resources(contribution: Dictionary,
		provider_compatibility: Dictionary, merged_compatibility: Dictionary,
		merged_materials: Dictionary, merged_meshes: Dictionary) -> Dictionary:
	var source_materials: Variant = contribution.get("materialBindings", {})
	var source_meshes: Variant = contribution.get("meshBindings", {})
	var resource_bindings: Variant = contribution.get("resourceBindings", {})
	if not source_materials is Dictionary or not source_meshes is Dictionary \
			or not resource_bindings is Dictionary:
		return _failed("section_provider_resource_bindings_invalid")
	for batch_key_value: Variant in provider_compatibility:
		var batch_key := String(batch_key_value)
		var compatibility_value: Variant = provider_compatibility[batch_key_value]
		if not batch_key_value is String or not compatibility_value is Dictionary \
				or not compatibility_value.is_read_only() \
				or String(compatibility_value.get("batchKey", "")) != batch_key:
			return _failed("section_provider_compatibility_key_invalid")
		if merged_compatibility.has(batch_key) \
				and merged_compatibility[batch_key] != compatibility_value:
			return _failed("cross_domain_batch_compatibility_conflict:" + batch_key)
		var material_key := String(compatibility_value.get("materialKey", ""))
		var mesh_key := String(compatibility_value.get("meshKey", ""))
		var resource_value: Variant = resource_bindings.get(batch_key, {})
		var material: Variant = source_materials.get(material_key,
			resource_value.get("material") if resource_value is Dictionary else null)
		var mesh_resource_key := String(compatibility_value.get("meshResourceKey", ""))
		var mesh: Variant = source_meshes.get(mesh_key,
			source_meshes.get(mesh_resource_key,
			resource_value.get("mesh") if resource_value is Dictionary else null)
			)
		if material_key.is_empty() or mesh_key.is_empty() or mesh_resource_key.is_empty() \
				or not material is Material or not mesh is Mesh:
			return _pending("section_provider_render_resource_unavailable", {"batchKey":batch_key})
		var mesh_identity: Dictionary = MeshFingerprint.inspect(mesh)
		if mesh_identity.get("status") != "ready" \
				or String(mesh_identity.get("contentDigest", "")) \
					!= String(compatibility_value.get("meshContentDigest", "")):
			return _pending("section_provider_mesh_resource_stale", {"batchKey":batch_key})
		if merged_materials.has(material_key) and merged_materials[material_key] != material:
			return _failed("cross_domain_material_binding_conflict:" + material_key)
		if merged_meshes.has(mesh_resource_key) and merged_meshes[mesh_resource_key] != mesh:
			return _failed("cross_domain_mesh_binding_conflict:" + mesh_resource_key)
		merged_compatibility[batch_key] = compatibility_value
		merged_materials[material_key] = material
		# SnapshotBuilder stores meshResourceKey in renderer batches, while
		# compatibility.meshKey also includes pipeline/layer/sort identity.
		merged_meshes[mesh_resource_key] = mesh
	return {"status":"ready"}


static func _pending(reason: String, detail := {}) -> Dictionary:
	var result := {"status":"pending", "reason":reason, "retryable":true}
	result.merge(detail, true)
	return result


static func _failed(reason: String) -> Dictionary:
	return {"status":"failed", "reason":reason, "retryable":false}
