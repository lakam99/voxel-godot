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
const MaterialFingerprint := preload("res://scripts/world/StaticRenderMaterialFingerprint.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const SectionSnapshot := preload("res://scripts/world/ChunkStaticRenderSectionSnapshot.gd")
const PresentationMembers := preload("res://scripts/world/StaticSectionPresentationMembers.gd")

const SCHEMA := "world-static-section-production-candidate/v1"


static func assemble(census: Dictionary, section_key: Vector3i,
		contributions: Array, candidate_generation: int) -> Dictionary:
	return _assemble(census, section_key, contributions, candidate_generation, false)


static func prepare_compile(census: Dictionary, section_key: Vector3i,
		contributions: Array, candidate_generation: int) -> Dictionary:
	return _assemble(census, section_key, contributions, candidate_generation, true)


static func _assemble(census: Dictionary, section_key: Vector3i,
		contributions: Array, candidate_generation: int, defer_compile: bool) -> Dictionary:
	if census.get("status") != "complete" or candidate_generation <= 0 \
			or String(census.get("worldId", "")).is_empty():
		return _pending("authoritative_section_census_unavailable")
	if not census.get("sections") is Array or not census.get("sourceRevisions") is Dictionary \
			or not census.get("sourceProviderIds") is Dictionary \
			or not census.get("sourceIdentities") is Dictionary \
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
	for identity_key_value: Variant in expected_value:
		if not identity_key_value is String or String(identity_key_value).is_empty():
			return _failed("invalid_section_census_source_part")
		var identity_key := String(identity_key_value)
		var identity_value: Variant = census.sourceIdentities.get(identity_key, null)
		if not identity_value is Dictionary \
				or _source_part_identity_key(String(identity_value.get("sourceId", "")),
					String(identity_value.get("sourcePartId", ""))) != identity_key:
			return _failed("section_census_source_identity_missing")
		var provider_id := String(census.sourceProviderIds.get(identity_key, ""))
		if provider_id.is_empty():
			return _failed("section_census_provider_identity_missing:" + identity_key)
		if not expected_by_provider.has(provider_id):
			expected_by_provider[provider_id] = {}
		expected_by_provider[provider_id][identity_key] = true

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
	var material_content_digests: Dictionary = {}
	var meshes: Dictionary = {}
	var mesh_content_digests: Dictionary = {}
	var attachment_bindings: Dictionary = {}
	var inputs: Array[Dictionary] = []
	var explicit_empty_contributors: Array[Dictionary] = []
	var presentation_contributors: Array[Dictionary] = []
	var support_ranges_by_source: Dictionary = {}
	var provider_coverage: Array = []
	var support_coverage_identities: Array[Dictionary] = []
	for contribution_value: Variant in contributions:
		if not contribution_value is Dictionary or not contribution_value.is_read_only():
			return _failed("mutable_or_invalid_section_provider_contribution")
		var contribution: Dictionary = contribution_value
		var bindings: Variant = contribution.get("attachmentBindings", {})
		if not bindings is Dictionary: return _failed("invalid_attachment_bindings")
		for attachment_key: Variant in bindings:
			if not attachment_key is String or String(attachment_key).is_empty() \
					or not bindings[attachment_key] is Dictionary:
				return _failed("invalid_attachment_binding_identity")
			if attachment_bindings.has(attachment_key) and attachment_bindings[attachment_key] != bindings[attachment_key]:
				return _failed("conflicting_attachment_binding")
			attachment_bindings[attachment_key] = bindings[attachment_key]
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
		for identity_key_value: Variant in authority_revisions_value:
			var identity_key := String(identity_key_value)
			var authority_revision := String(authority_revisions_value[identity_key_value])
			if not expected_members.has(identity_key) or authority_revision.is_empty() \
					or String(census.sourceRevisions.get(identity_key, "")) != authority_revision:
				return _pending("section_provider_source_revision_stale", {
					"providerId":provider_id, "sourceIdentity":identity_key,
					"expectedMember":expected_members.has(identity_key),
					"providerRevision":authority_revision,
					"censusRevision":String(census.sourceRevisions.get(identity_key, ""))})
			if observed_source_parts.has(identity_key):
				return _failed("section_source_part_owned_by_multiple_providers:" + identity_key)
			observed_source_parts[identity_key] = provider_id
		var empty_values: Variant = contribution.get("explicitEmptyContributors", [])
		if not empty_values is Array:
			return _failed("section_provider_explicit_empty_manifest_invalid:" + provider_id)
		if not contribution.has("explicitEmptyContributors") and not empty_values.is_read_only():
			empty_values.make_read_only()
		if not empty_values.is_read_only():
			return _failed("section_provider_explicit_empty_manifest_mutable:" + provider_id)
		var empty_by_part: Dictionary = {}
		for empty_value: Variant in empty_values:
			if not empty_value is Dictionary or not empty_value.is_read_only():
				return _failed("section_provider_explicit_empty_entry_invalid:" + provider_id)
			var empty_row: Dictionary = empty_value
			var empty_source_id := String(empty_row.get("sourceId", ""))
			var empty_part_id := String(empty_row.get("sourcePartId", ""))
			var empty_identity_key := _source_part_identity_key(empty_source_id, empty_part_id)
			var empty_revision := String(empty_row.get("sourceRevision", ""))
			if empty_source_id.is_empty() or empty_part_id.is_empty() \
					or empty_revision.is_empty() or empty_row.get("sectionKey") != section_key \
					or not empty_row.get("ownerCell") is Vector2i \
				or not expected_members.has(empty_identity_key) \
				or String(authority_revisions_value.get(empty_identity_key, "")) != empty_revision \
				or empty_by_part.has(empty_identity_key):
				return _failed("section_provider_explicit_empty_identity_invalid:" + provider_id)
			empty_by_part[empty_identity_key] = empty_row
		var input_members: Dictionary = {}
		for input_value: Variant in inputs_value:
			if input_value is Dictionary:
				var input_identity_key := _source_part_identity_key(
					String(input_value.get("sourceId", "")),
					String(input_value.get("sourcePartId", "")))
				input_members[input_identity_key] = true
		var presentation_values: Variant = contribution.get("presentationContributors", null)
		if presentation_values == null and not contribution.has("presentationContributors"):
			presentation_values = []
			presentation_values.make_read_only()
		if not presentation_values is Array or not presentation_values.is_read_only():
			return _failed("section_provider_presentation_manifest_invalid:" + provider_id)
		var presentation_by_part: Dictionary = {}
		for presentation_value: Variant in presentation_values:
			if not presentation_value is Dictionary or not presentation_value.is_read_only():
				return _failed("section_provider_presentation_contributor_invalid:" + provider_id)
			var presentation: Dictionary = presentation_value
			for field: String in ["sourceId", "sourcePartId", "sourceRevision"]:
				if not presentation.get(field) is String \
						or String(presentation[field]).strip_edges().is_empty():
					return _failed("section_provider_presentation_identity_invalid:" + provider_id)
			var source_id := String(presentation.get("sourceId", ""))
			var part_id := String(presentation.get("sourcePartId", ""))
			var revision := String(presentation.get("sourceRevision", ""))
			var identity_key := _source_part_identity_key(source_id, part_id)
			var members: Variant = presentation.get("presentationMembers", null)
			if not expected_members.has(identity_key) or presentation_by_part.has(identity_key) \
					or revision.is_empty() or authority_revisions_value.get(identity_key) != revision \
					or presentation.get("sectionKey") != section_key \
					or not presentation.get("ownerCell") is Vector2i \
					or not members is Array or not members.is_read_only() or members.is_empty() \
					or members.size() > PresentationMembers.MAX_MEMBERS:
				return _failed("section_provider_presentation_identity_invalid:" + provider_id)
			for member: Variant in members:
				var validation := PresentationMembers.validate(member, source_id, part_id, revision)
				if validation.get("status") != "ready": return validation
				if not bindings.has(member.attachmentKey):
					return _failed("section_provider_presentation_binding_missing:" + provider_id)
				var binding: Dictionary = bindings[member.attachmentKey]
				for field: String in ["sourceId", "sourcePartId", "sourceRevision",
						"presentationMemberId", "ownershipKind", "intendedVisible",
						"neutralParentToWorld", "sweptWorldBounds", "motion"]:
					if not binding.has(field) or binding[field] != member[field]:
						return _failed("section_provider_presentation_binding_mismatch:" + provider_id + ":" + field)
			presentation_by_part[identity_key] = true
			presentation_contributors.append(presentation)
		var support_values: Variant = contribution.get("supportRangesBySource", null)
		if support_values == null and not contribution.has("supportRangesBySource"):
			var empty_support_map: Dictionary = {}
			empty_support_map.make_read_only()
			support_values = empty_support_map
		if not support_values is Dictionary or not support_values.is_read_only():
			return _failed("section_provider_support_ranges_invalid:" + provider_id)
		for identity_key_value: Variant in support_values:
			var identity_key := String(identity_key_value)
			var identity: Dictionary = census.sourceIdentities.get(identity_key, {})
			var source_part_id := String(identity.get("sourcePartId", ""))
			var rows_value: Variant = support_values[identity_key_value]
			if not expected_members.has(identity_key) or not rows_value is Array \
					or not rows_value.is_read_only():
				return _failed("section_provider_support_source_invalid:" + provider_id)
			if support_ranges_by_source.has(identity_key):
				return _failed("section_support_source_owned_by_multiple_providers:" + identity_key)
			var sealed_rows: Array = []
			var seen_support_ranges: Dictionary = {}
			for support_value: Variant in rows_value:
				if not support_value is Dictionary or not support_value.is_read_only() \
					or not _support_range_is_current(support_value, section_key,
							String(support_value.get("sourceId", "")), source_part_id,
							String(authority_revisions_value.get(identity_key, ""))):
					return _pending("section_provider_support_range_stale", {
						"providerId":provider_id, "sourcePartId":source_part_id})
				var range_key := "%s|%s|%s" % [String(support_value.get("memberId", "")),
					String(support_value.get("sourceSegmentId", "")),
					str(support_value.get("sourceInstance", ""))]
				if seen_support_ranges.has(range_key):
					return _failed("duplicate_section_support_range:" + source_part_id)
				seen_support_ranges[range_key] = true
				sealed_rows.append(support_value)
			sealed_rows.make_read_only()
			support_ranges_by_source[identity_key] = sealed_rows
		for identity_key_value: Variant in expected_members:
			var expected_identity_key := String(identity_key_value)
			var has_input := input_members.has(expected_identity_key)
			var has_empty := empty_by_part.has(expected_identity_key)
			var has_support := support_ranges_by_source.has(expected_identity_key)
			var has_presentation := presentation_by_part.has(expected_identity_key)
			if has_empty and (has_input or has_support or has_presentation) \
					or not has_empty and not has_input and not has_support and not has_presentation:
				return _pending("section_source_geometry_or_explicit_empty_missing", {
					"providerId":provider_id, "sourceIdentity":expected_identity_key})
		for empty_part_id: Variant in empty_by_part:
			explicit_empty_contributors.append(empty_by_part[empty_part_id])
		var resource_result := merge_provider_render_resources(contribution,
			compatibility_value, compatibility_by_key, materials, material_content_digests,
			meshes, mesh_content_digests)
		if resource_result.get("status") != "ready":
			return resource_result
		for input_value: Variant in inputs_value:
			if not input_value is Dictionary or not input_value.is_read_only():
				return _failed("mutable_or_invalid_section_instance_input")
			var input: Dictionary = input_value
			var source_id := String(input.get("sourceId", ""))
			var source_part_id := String(input.get("sourcePartId", ""))
			var identity_key := _source_part_identity_key(source_id, source_part_id)
			var source_revision := String(input.get("sourceRevision", ""))
			var batch_key := String(input.get("batchKey", ""))
			if source_part_id.is_empty() or source_id.is_empty() or source_revision.is_empty() \
				or batch_key.is_empty() or not expected_members.has(identity_key) \
					or not compatibility_value.has(batch_key):
				return _failed("section_instance_input_not_in_provider_manifest:" + provider_id)
			if not observed_source_parts.has(identity_key) \
					or String(observed_source_parts[identity_key]) != provider_id:
				return _failed("section_instance_input_source_owner_mismatch:" + identity_key)
			var expected_input_revision := String(authority_revisions_value.get(identity_key, ""))
			if source_revision != expected_input_revision \
					or source_revision != String(census.sourceRevisions.get(identity_key, "")):
				return _pending("section_instance_input_source_revision_stale", {
					"providerId":provider_id, "sourceIdentity":identity_key})
			var normalized := input.duplicate(false)
			normalized["providerId"] = provider_id
			normalized.make_read_only()
			inputs.append(normalized)
		var coverage_row: Array = [provider_id, coverage_revision,
			String(contribution.authorityRevision)]
		coverage_row.make_read_only()
		provider_coverage.append(coverage_row)
		if contribution.has("supportCoverageIdentity"):
			var identity_value: Variant = contribution.get("supportCoverageIdentity")
			if not identity_value is Dictionary or not identity_value.is_read_only() \
					or String(identity_value.get("schema", "")) \
					!= "ecology-support-coverage-identity/v1" \
					or String(identity_value.get("providerId", "")) != provider_id \
					or identity_value.get("sectionKey", null) != section_key \
					or int(identity_value.get("sourceIndexRevision", -1)) < 0 \
					or String(identity_value.get("coverageDigest", "")) != coverage_revision:
				return _pending("section_provider_support_coverage_identity_invalid", {
					"providerId":provider_id, "sectionKey":section_key})
			support_coverage_identities.append(identity_value)
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
	support_coverage_identities.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("providerId", "")) < String(b.get("providerId", "")))
	support_coverage_identities.make_read_only()
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
	explicit_empty_contributors.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _source_part_identity_key(String(a.get("sourceId", "")),
			String(a.get("sourcePartId", ""))) < _source_part_identity_key(
			String(b.get("sourceId", "")), String(b.get("sourcePartId", ""))))
	explicit_empty_contributors.make_read_only()
	var explicit_empty_by_section: Dictionary = {section_key:explicit_empty_contributors}
	explicit_empty_by_section.make_read_only()
	var replacements := SnapshotBuilder.build_replacements(partition,
		compatibility_by_key, impacted_sections, candidate_generation,
		String(census.worldId), explicit_empty_by_section,
		{section_key:support_ranges_by_source}, defer_compile,
		{section_key:_freeze_presentation_contributors(presentation_contributors)})
	if replacements.get("status") != "ready":
		return _failed("whole_section_snapshot_build_failed:" + String(replacements.get("reason", "unknown")))
	var replacement_rows: Array = replacements.get("replacements", [])
	if replacement_rows.size() != 1 or not replacement_rows[0] is Dictionary:
		return _failed("whole_section_snapshot_replacement_missing")
	var replacement: Dictionary = replacement_rows[0]
	attachment_bindings.make_read_only()
	var context := {"census":_capture_value(census), "sectionKey":section_key,
		"generation":candidate_generation, "expectedSourceIds":expected_source_ids,
		"providerCoverage":provider_coverage, "supportCoverageIdentities":support_coverage_identities,
		"materialBindings":materials, "meshBindings":meshes, "attachmentBindings":attachment_bindings,
		"inputCount":inputs.size(), "providerCount":expected_providers.size(),
		"batchCount":compatibility_by_key.size()}
	context.providerCoverage.make_read_only()
	context.expectedSourceIds.make_read_only()
	context.make_read_only()
	if defer_compile:
		var native_preparation: Dictionary = replacement.preparation
		var input_digest := SnapshotBuilder._snapshot_digest(native_preparation,
			String(census.worldId), candidate_generation, section_key)
		if input_digest.is_empty(): return _failed("section_compile_input_digest_failed")
		var preparation := {"context":context, "replacement":replacement, "inputDigest":input_digest}
		preparation.make_read_only()
		return {"status":"ready", "preparation":preparation,
			"nativePreparation":native_preparation, "inputDigest":input_digest}
	return _finish_candidate(context, replacement)


static func _freeze_presentation_contributors(values: Array[Dictionary]) -> Array[Dictionary]:
	values.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _source_part_identity_key(a.sourceId, a.sourcePartId) < \
			_source_part_identity_key(b.sourceId, b.sourcePartId))
	values.make_read_only()
	return values


static func finalize_compile(preparation: Dictionary, native_result: Dictionary) -> Dictionary:
	if native_result.get("status") != "ready" or not native_result.get("groups") is Dictionary:
		return _failed("section_compile_result_unavailable")
	var identity_value: Variant = native_result.get("identity")
	if not identity_value is Dictionary \
			or String(identity_value.get("preparedPayloadDigest", "")) != String(preparation.inputDigest) \
			or identity_value.get("sectionKey") != preparation.context.sectionKey \
			or int(identity_value.get("generation", -1)) != int(preparation.context.generation) \
			or String(identity_value.get("worldEpoch", "")) != String(preparation.context.census.worldId) \
			or String(identity_value.get("providerRevisionDigest", "")) != String(preparation.context.census.get("censusDigest", "")) \
			or String(identity_value.get("coverageDigest", "")) != String(preparation.context.census.get("censusDigest", "")):
		return _failed("section_compile_result_identity_mismatch")
	var finalized := SnapshotBuilder.finalize_replacement(preparation.replacement, native_result.groups)
	if finalized.get("status") != "ready": return finalized
	return _finish_candidate(preparation.context, finalized.replacement)


## The retained census crosses frames; freeze nested revision containers too.
static func _capture_value(value: Variant) -> Variant:
	if value is Dictionary:
		var dictionary: Dictionary = value.duplicate(false)
		for key: Variant in dictionary:
			dictionary[key] = _capture_value(dictionary[key])
		dictionary.make_read_only()
		return dictionary
	if value is Array:
		var array: Array = value.duplicate(false)
		for index in range(array.size()):
			array[index] = _capture_value(array[index])
		array.make_read_only()
		return array
	return value


static func _finish_candidate(context: Dictionary, replacement: Dictionary) -> Dictionary:
	var census: Dictionary = context.census
	var expected_source_ids: Array = context.expectedSourceIds
	var provider_coverage: Array = context.providerCoverage.duplicate(false)
	var manifest_ids: Array[String] = []
	for row_value: Variant in replacement.get("snapshot", {}).get("manifest", []):
		manifest_ids.append(_source_part_identity_key(String(row_value.get("sourceId", "")),
			String(row_value.get("sourcePartId", ""))))
	manifest_ids.sort()
	if manifest_ids != expected_source_ids:
		return _failed("whole_section_candidate_manifest_not_exact")
	provider_coverage.sort_custom(func(a: Array, b: Array) -> bool:
		return String(a[0]) < String(b[0]))
	# The census can cover several sections. The installed receipt may claim
	# only the current and removed members of this exact target section.
	var section_source_revisions: Dictionary = {}
	for identity_key: String in expected_source_ids:
		section_source_revisions[identity_key] = census.sourceRevisions[identity_key]
	var section_removal_revisions: Dictionary = {}
	var section_removal_identities: Dictionary = {}
	for removal_value: Variant in census.get("removalsBySection", {}).get(context.sectionKey, []):
		if not removal_value is Dictionary or removal_value.get("sectionKey") != context.sectionKey:
			return _failed("section_removal_identity_invalid")
		var identity_key := _source_part_identity_key(String(removal_value.get("sourceId", "")),
			String(removal_value.get("sourcePartId", "")))
		var revision := String(removal_value.get("sourceRevision", ""))
		if identity_key.is_empty() or revision.is_empty() or section_source_revisions.has(identity_key) \
				or String(census.get("removalRevisions", {}).get(identity_key, "")) != revision \
				or section_removal_revisions.has(identity_key):
			return _failed("section_removal_revision_invalid")
		section_removal_revisions[identity_key] = revision
		var removal_identity := {"sourceId":String(removal_value.sourceId),
			"sourcePartId":String(removal_value.sourcePartId), "sourceRevision":revision}
		removal_identity.make_read_only()
		section_removal_identities[identity_key] = removal_identity
	section_source_revisions.make_read_only()
	section_removal_revisions.make_read_only()
	section_removal_identities.make_read_only()
	var candidate := {"schema":SCHEMA, "worldId":String(census.worldId),
		"sectionKey":context.sectionKey, "generation":int(context.generation),
		"contentManifestDigest":String(replacement.get("contentManifestDigest", "")),
		"censusDigest":String(census.get("censusDigest", "")),
		"sourceRevisions":section_source_revisions,
		"removalRevisions":section_removal_revisions,
		"removalSourceIdentities":section_removal_identities,
		"providerCoverage":provider_coverage,
		"supportCoverageIdentities":context.supportCoverageIdentities,
		"candidate":replacement,
		"materialBindings":context.materialBindings, "meshBindings":context.meshBindings,
		"attachmentBindings":context.attachmentBindings,
		"inputCount":int(context.inputCount), "evidenceLevel":"complete_authoritative_section_candidate"}
	candidate.providerCoverage.make_read_only()
	candidate.make_read_only()
	return {"status":"ready", "candidate":candidate,
		"providerCount":int(context.providerCount),
		"sourceCount":expected_source_ids.size(), "inputCount":int(context.inputCount),
		"batchCount":int(context.batchCount),
		"contentManifestDigest":String(replacement.get("contentManifestDigest", ""))}


static func merge_provider_render_resources(contribution: Dictionary,
		provider_compatibility: Dictionary, merged_compatibility: Dictionary,
		merged_materials: Dictionary, merged_material_content_digests: Dictionary,
		merged_meshes: Dictionary,
		merged_mesh_content_digests: Dictionary) -> Dictionary:
	var source_materials: Variant = contribution.get("materialBindings", {})
	var source_meshes: Variant = contribution.get("meshBindings", {})
	var resource_bindings: Variant = contribution.get("resourceBindings", {})
	if not source_materials is Dictionary or not source_meshes is Dictionary \
			or not resource_bindings is Dictionary:
		return _failed("section_provider_resource_bindings_invalid")
	var material_digests_by_instance: Dictionary = {}
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
		var material_instance_id: int = material.get_instance_id()
		if not material_digests_by_instance.has(material_instance_id):
			var material_identity: Dictionary = MaterialFingerprint.inspect(material)
			if material_identity.get("status") != "ready":
				return _pending("section_provider_material_resource_unavailable", {"batchKey":batch_key})
			material_digests_by_instance[material_instance_id] = String(
				material_identity.get("contentDigest", ""))
		var material_content_digest := String(material_digests_by_instance[material_instance_id])
		if merged_materials.has(material_key):
			if String(merged_material_content_digests.get(material_key, "")) \
					!= material_content_digest:
				return _failed("cross_domain_material_binding_conflict:" + material_key)
		else:
			# Reuse one canonical resource object for independent captures with the
			# same inspected content, whether the key is semantic or digest-bearing.
			merged_materials[material_key] = material
			merged_material_content_digests[material_key] = material_content_digest
		var mesh_content_digest := String(mesh_identity.get("contentDigest", ""))
		if merged_meshes.has(mesh_resource_key):
			if String(merged_mesh_content_digests.get(mesh_resource_key, "")) != mesh_content_digest:
				return _failed("cross_domain_mesh_binding_conflict:" + mesh_resource_key)
		else:
			# Resource keys name immutable mesh content, not a particular RefCounted
			# instance. Keep the first verified mesh as the canonical binding when
			# independent providers captured equivalent resources.
			merged_meshes[mesh_resource_key] = mesh
			merged_mesh_content_digests[mesh_resource_key] = mesh_content_digest
		merged_compatibility[batch_key] = compatibility_value
		# SnapshotBuilder stores meshResourceKey in renderer batches, while
		# compatibility.meshKey also includes pipeline/layer/sort identity.
	return {"status":"ready"}


static func _support_range_is_current(value: Dictionary, section_key: Vector3i,
		source_id: String, source_part_id: String, source_revision: String) -> bool:
	return SectionSnapshot._validate_support_range(value, section_key,
		 source_id, source_part_id, source_revision)


static func _source_part_identity_key(source_id: String, source_part_id: String) -> String:
	if source_id.is_empty() or source_part_id.is_empty(): return ""
	return "section-part:" + var_to_bytes([source_id, source_part_id]).hex_encode()


static func _pending(reason: String, detail := {}) -> Dictionary:
	var result := {"status":"pending", "reason":reason, "retryable":true}
	result.merge(detail, true)
	return result


static func _failed(reason: String) -> Dictionary:
	return {"status":"failed", "reason":reason, "retryable":false}
