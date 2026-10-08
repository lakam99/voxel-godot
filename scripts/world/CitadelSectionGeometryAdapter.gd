extends RefCounted
class_name CitadelSectionGeometryAdapter

## Adapts already compiled Citadel static-batch segments to the shared section
## instance partitioner. This does not compile recipes, create visuals, or
## replace the live BuildingPartPublisher path. A section remains pending if
## even one census member has no matching, revision-bound packet geometry.

const Partitioner := preload("res://scripts/world/ChunkStaticRenderSectionInstancePartitioner.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const OwnerCompletion := preload("res://scripts/world/StaticGeometryOwnerCompletion.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const SectionSnapshot := preload("res://scripts/world/ChunkStaticRenderSectionSnapshot.gd")
const OrdinaryGeometryAdapter := preload("res://scripts/world/OrdinaryStructureSectionGeometryAdapter.gd")
const TreeGeometryAdapter := preload("res://scripts/world/TreeSectionValueAdapter.gd")
const PresentationMembers := preload("res://scripts/world/StaticSectionPresentationMembers.gd")
const TranslucentPreparation := preload("res://scripts/world/StaticTranslucentMeshPreparation.gd")

const SCHEMA := "citadel-section-geometry-adapter/v1"
const PIPELINE_REVISION := "citadel-prepared-static-batch/v1"
const TRANSFORM_ARTIFACT_SCHEMA := "building-static-transform-section-artifact/v1"


## `member_bindings` is copied from the current immutable
## PreparedPhysicalGroupPacket entries, keyed by exact census source ID.
## `packet_groups` are the existing publisher's already prepared static groups;
## their `sourceRevision` must match the corresponding packet entry binding.
## The resource handles are returned separately from the value-only candidate.
static func capture_section(census: Dictionary, section_key: Vector3i,
		candidate_generation: int, packet_groups: Array,
		member_bindings: Dictionary, source_to_world: Transform3D,
		default_mesh: Mesh) -> Dictionary:
	if candidate_generation <= 0 or not _valid_transform(source_to_world):
		return _failed("invalid_citadel_candidate_identity")
	if census.get("status") != "complete" or not census.get("sections") is Dictionary \
			or not census.get("sourceRevisions") is Dictionary:
		return _pending("citadel_member_census_unavailable")
	var section_rows: Dictionary = census.sections
	var census_row: Variant = section_rows.get(section_key)
	if not census_row is Dictionary or census_row.get("status") not in ["complete", "empty"] \
			or not census_row.get("sourcePartIds") is Array:
		return _pending("citadel_section_census_pending", {"section":section_key})
	if census_row.get("status") == "empty":
		var empty_inputs: Array[Dictionary] = []
		empty_inputs.make_read_only()
		var empty_partition_result: Dictionary = Partitioner.partition(empty_inputs)
		if empty_partition_result.get("status") != "ready":
			return _failed("citadel_empty_section_partition_failed")
		var empty_compatibility: Dictionary = {}
		empty_compatibility.make_read_only()
		var empty := {"status":"ready", "schema":SCHEMA,
			"worldId":String(census.get("worldId", "")), "sectionKey":section_key,
			"candidateGeneration":candidate_generation,
			"coverageRevision":String(census_row.get("coverageRevision", "")),
			"authorityRevision":String(census.get("authorityRevision", "")),
			"inputs":empty_inputs,
			"partition":empty_partition_result.get("result", {}),
			"compatibilityByKey":empty_compatibility, "resourceBindings":{},
			"memberCount":0, "packetGroupCount":0}
		empty.make_read_only()
		return empty
	if String(census.get("worldId", "")).is_empty() \
			or String(census_row.get("coverageRevision", "")).is_empty():
		return _pending("citadel_census_revision_missing")
	if not member_bindings.is_read_only():
		return _pending("citadel_prepared_member_bindings_unsealed")
	if default_mesh == null and not packet_groups.is_empty():
		return _pending("citadel_prepared_static_geometry_missing")

	var groups_by_part: Dictionary = {}
	for group_value: Variant in packet_groups:
		if not group_value is Dictionary:
			return _failed("invalid_citadel_packet_group")
		var group: Dictionary = group_value
		var part_id := String(group.get("sourcePartId", ""))
		var site_id := String(group.get("siteId", ""))
		if site_id.is_empty() or String(group.get("packetSourceId", "")).is_empty() \
				or not group.get("packetGeneration") is int \
				or int(group.get("packetGeneration", 0)) <= 0 \
				or String(group.get("packetDigest", "")).length() != 64 \
				or group.get("packetOwnerCell") != group.get("ownerCell") \
				or part_id.is_empty() or not group.get("ownerCell") is Vector2i \
				or String(group.get("sourceRevision", "")).is_empty() \
				or String(group.get("materialKey", "")).is_empty() \
				or String(group.get("renderTier", "")).is_empty() \
				or not group.get("preparedSegments") is Dictionary \
				or group.preparedSegments.is_empty():
			return _pending("citadel_packet_group_incomplete", {"sourcePartId":part_id})
		var group_key := site_id + "\n" + part_id
		if not groups_by_part.has(group_key):
			groups_by_part[group_key] = []
		groups_by_part[group_key].append(group)

	var member_rows: Array[Dictionary] = []
	var inputs: Array[Dictionary] = []
	var compatibility_by_key: Dictionary = {}
	var resources_by_key: Dictionary = {}
	var source_revision_map: Dictionary = census.get("sourceRevisions", {})
	var census_ids: Array[String] = []
	for raw_id: Variant in census_row.sourcePartIds:
		if not raw_id is String or String(raw_id).is_empty():
			return _failed("invalid_citadel_census_member_id")
		census_ids.append(String(raw_id))
	census_ids.sort()
	for census_source_id: String in census_ids:
		var member_id := _member_id_from_census_source(census_source_id)
		if member_id.is_empty() or not member_id.begins_with("building:"):
			return _pending("citadel_member_kind_has_no_static_packet_geometry", {
				"sourceId":census_source_id, "memberId":member_id})
		var part_id := member_id.trim_prefix("building:")
		var site_id := _site_id_from_census_source(census_source_id)
		var source_revision := String(source_revision_map.get(census_source_id, ""))
		var member_binding := String(member_bindings.get(census_source_id, ""))
		if source_revision.is_empty() or member_binding.is_empty():
			return _pending("citadel_prepared_member_revision_missing", {
				"sourceId":census_source_id, "memberId":member_id})
		var matching_groups: Array = groups_by_part.get(site_id + "\n" + part_id, [])
		if matching_groups.is_empty():
			return _pending("citadel_member_packet_geometry_missing", {
				"sourceId":census_source_id, "sourcePartId":part_id})
		var normalized_groups: Array[Dictionary] = []
		for group_value: Variant in matching_groups:
			var group: Dictionary = group_value
			if String(group.sourceRevision) != member_binding:
				return _pending("citadel_packet_member_revision_mismatch", {
					"sourceId":census_source_id, "sourcePartId":part_id})
			var group_source_to_world: Transform3D = group.get("sourceToWorld", source_to_world)
			if not _valid_transform(group_source_to_world):
				return _pending("citadel_packet_source_transform_unavailable", {
					"sourceId":census_source_id, "sourcePartId":part_id})
			var prepared := _prepare_group(group, census_source_id, part_id,
				source_revision, member_binding, group_source_to_world, default_mesh)
			if prepared.get("status") != "ready":
				return prepared
			normalized_groups.append(prepared)
		normalized_groups.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a.get("groupKey", "")) < String(b.get("groupKey", "")))
		var revision_payload: Array = [SCHEMA, String(census.worldId),
			section_key, census_source_id, source_revision, member_binding,
			candidate_generation]
		for normalized: Dictionary in normalized_groups:
			revision_payload.append(String(normalized.contentDigest))
		var digest := HashingContext.new()
		if digest.start(HashingContext.HASH_SHA256) != OK \
				or digest.update(var_to_bytes(revision_payload)) != OK:
			return _failed("citadel_member_revision_digest_failed")
		var candidate_source_revision := digest.finish().hex_encode()
		var manifest_groups: Array[String] = []
		for normalized: Dictionary in normalized_groups:
			var compatibility: Dictionary = normalized.compatibility
			var batch_key := String(compatibility.batchKey)
			if compatibility_by_key.has(batch_key) \
					and compatibility_by_key[batch_key] != compatibility:
				return _failed("citadel_batch_compatibility_conflict")
			compatibility_by_key[batch_key] = compatibility
			var resource_binding := {"mesh":normalized.mesh,
				"material":normalized.material,
				"materialDigest":normalized.materialDigest}
			resource_binding.make_read_only()
			resources_by_key[batch_key] = resource_binding
			manifest_groups.append(batch_key)
			for segment: Dictionary in normalized.segments:
				var input: Dictionary = {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
					"sourceId":census_source_id, "sourcePartId":census_source_id,
					"packetMemberId":member_id, "packetPartId":part_id,
					"sourceRevision":candidate_source_revision,
					"ownerCell":normalized.ownerCell,
					"sourceToWorld":normalized.sourceToWorld,
					"meshLocalBounds":normalized.meshLocalBounds,
					"batchKey":batch_key, "segmentId":String(segment.segmentId),
					"buffer":segment.buffer, "instanceCount":int(segment.instanceCount)}
				input.make_read_only()
				inputs.append(input)
		manifest_groups.sort()
		var manifest := {"sourceId":census_source_id,
			"sourcePartId":census_source_id, "packetMemberId":member_id,
			"packetPartId":part_id, "sourceRevision":candidate_source_revision,
			"memberBinding":member_binding,
			"censusRevision":source_revision,
			"groupMembershipRevision":source_revision,
			"packetBatchKeys":manifest_groups,
			"packetSourceIds":_packet_source_ids(normalized_groups),
			"packetDigest":_member_packet_digest(normalized_groups),
			"geometryGroupCount":normalized_groups.size()}
		manifest.packetBatchKeys.make_read_only()
		manifest.packetSourceIds.make_read_only()
		manifest.make_read_only()
		member_rows.append(manifest)
	inputs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if String(a.sourceId) != String(b.sourceId):
			return String(a.sourceId) < String(b.sourceId)
		if String(a.batchKey) != String(b.batchKey):
			return String(a.batchKey) < String(b.batchKey)
		return String(a.segmentId) < String(b.segmentId))
	inputs.make_read_only()
	var census_part_ids: Dictionary = {}
	for census_source_id: String in census_ids:
		census_part_ids[_site_id_from_census_source(census_source_id) + "\n" \
			+ _member_id_from_census_source(census_source_id).trim_prefix("building:")] = true
	for group_key: Variant in groups_by_part:
		if not census_part_ids.has(String(group_key)):
			return _pending("citadel_packet_group_not_in_census", {"groupKey":String(group_key)})
	member_rows.make_read_only()
	compatibility_by_key.make_read_only()
	resources_by_key.make_read_only()
	var partition: Dictionary = Partitioner.partition(inputs)
	if partition.get("status") != "ready":
		return _failed("citadel_section_partition_failed:" + String(partition.get("reason", "unknown")))
	var partition_result: Dictionary = partition.get("result", {})
	if not partition_result.is_read_only():
		return _failed("citadel_partition_result_unsealed")
	var candidate := {"status":"ready", "schema":SCHEMA,
		"worldId":String(census.worldId), "sectionKey":section_key,
		"candidateGeneration":candidate_generation,
		"coverageRevision":String(census_row.coverageRevision),
		"authorityRevision":String(census.get("authorityRevision", "")),
		"members":member_rows, "inputs":inputs, "partition":partition_result,
		"compatibilityByKey":compatibility_by_key,
		"resourceBindings":resources_by_key,
		"memberCount":member_rows.size(),
		"packetGroupCount":resources_by_key.size()}
	candidate.make_read_only()
	return candidate


## Build the shared assembler contribution directly from committed
## BuildingPartPublisher transform artifacts. `captures_by_source` and
## `member_bindings` are keyed by exact authoritative census source ID. Each
## capture is the result of capture_static_section_transform_artifacts(part,
## currentPublisherBinding). This path does not consume or fabricate legacy
## per-source packet receipts.
static func capture_transform_artifact_contribution(census: Dictionary,
		section_key: Vector3i, candidate_generation: int,
		captures_by_source: Dictionary, member_bindings: Dictionary,
		pov_snapshot: Dictionary = {}) -> Dictionary:
	if candidate_generation <= 0 or not census.is_read_only() \
			or census.get("status") != "complete" \
			or String(census.get("worldId", "")).is_empty() \
			or not census.get("sections") is Array or not census.sections.is_read_only() \
			or not census.get("sourceRevisions") is Dictionary \
			or not census.sourceRevisions.is_read_only() \
			or not census.get("sourceProviderIds") is Dictionary \
			or not census.sourceProviderIds.is_read_only() \
			or not census.get("sourceIdentities") is Dictionary \
			or not census.sourceIdentities.is_read_only() \
			or not census.get("expectedContributorsBySection") is Dictionary:
		return _pending("citadel_transform_artifact_census_unavailable")
	if not census.expectedContributorsBySection.is_read_only() \
			or not census.get("providerCoverageRevisions") is Dictionary \
			or not census.providerCoverageRevisions.is_read_only() \
			or not census.get("providerSnapshotRevisions") is Dictionary \
			or not census.providerSnapshotRevisions.is_read_only():
		return _pending("citadel_transform_artifact_census_manifests_unsealed")
	if section_key not in census.sections:
		return _pending("citadel_transform_artifact_section_census_unavailable")
	var expected_by_section: Dictionary = census.expectedContributorsBySection
	var expected_value: Variant = expected_by_section.get(section_key, null)
	if not expected_value is Array or not expected_value.is_read_only():
		return _pending("citadel_transform_artifact_expected_members_unavailable")
	var provider_ids: Dictionary = census.sourceProviderIds
	var source_identities: Dictionary = census.sourceIdentities
	var source_ids: Array[String] = []
	var source_id_set: Dictionary = {}
	var identity_key_by_source_id: Dictionary = {}
	for source_value: Variant in expected_value:
		if not source_value is String or String(source_value).is_empty():
			return _failed("invalid_citadel_transform_artifact_census_member")
		if source_id_set.has(String(source_value)):
			return _failed("duplicate_citadel_transform_artifact_census_member")
		source_id_set[String(source_value)] = true
		if String(provider_ids.get(String(source_value), "")) == "blueprint_buildings":
			var identity_value: Variant = source_identities.get(String(source_value), null)
			if not identity_value is Dictionary or not identity_value.is_read_only():
				return _pending("citadel_transform_artifact_identity_unavailable",
					{"identityKey":String(source_value)})
			var raw_source_id := String(identity_value.get("sourceId", ""))
			var raw_source_part_id := String(identity_value.get("sourcePartId", ""))
			if raw_source_id.is_empty() or raw_source_part_id.is_empty() \
					or _section_source_identity_key(raw_source_id, raw_source_part_id) \
					!= String(source_value) or identity_key_by_source_id.has(raw_source_id):
				return _pending("citadel_transform_artifact_identity_invalid",
					{"identityKey":String(source_value)})
			source_ids.append(raw_source_id)
			identity_key_by_source_id[raw_source_id] = String(source_value)
	source_ids.sort()
	var coverage_map: Variant = census.get("providerCoverageRevisions", {}).get(
		"blueprint_buildings", {})
	var coverage_revision := String(coverage_map.get(section_key, "")) \
		if coverage_map is Dictionary else ""
	if coverage_revision.is_empty():
		return _pending("citadel_transform_artifact_provider_coverage_missing")
	if captures_by_source.size() != source_ids.size() \
			or member_bindings.size() != source_ids.size():
		return _pending("citadel_transform_artifact_capture_roster_incomplete")
	var provider_revision := String(census.get("providerSnapshotRevisions", {}).get(
		"blueprint_buildings", ""))
	if provider_revision.is_empty():
		return _pending("citadel_transform_artifact_provider_revision_unavailable")

	var inputs: Array[Dictionary] = []
	var compatibility_by_key: Dictionary = {}
	var resource_bindings: Dictionary = {}
	var attachment_bindings: Dictionary = {}
	var authority_source_revisions: Dictionary = {}
	var member_manifests: Array[Dictionary] = []
	var explicit_empty_contributors: Array[Dictionary] = []
	var presentation_contributors: Array[Dictionary] = []
	var support_ranges_by_source: Dictionary = {}
	var observed_group_ids: Dictionary = {}
	var complete_members_by_source: Dictionary = {}
	var presentation_owner_members_by_source: Dictionary = {}
	for census_source_id: String in source_ids:
		var member_id := _member_id_from_census_source(census_source_id)
		var site_id := _site_id_from_census_source(census_source_id)
		if not site_id.is_empty() and member_id.begins_with("tree:"):
			var identity_key := String(identity_key_by_source_id.get(census_source_id, ""))
			var census_revision := String(census.get("sourceRevisions", {}).get(identity_key, ""))
			var capture: Variant = captures_by_source.get(census_source_id)
			var member_binding := String(member_bindings.get(census_source_id, ""))
			if not capture is Dictionary or capture.get("sourceId") != census_source_id \
					or member_binding.is_empty() or census_revision.is_empty():
				return _pending("citadel_tree_contributor_binding_missing")
			var tree := TreeGeometryAdapter.capture_compiled_contributor(
				capture.get("producer", {}), census_source_id, census_revision, section_key)
			if tree.get("status") != "ready": return tree
			inputs.append_array(tree.inputs)
			complete_members_by_source[census_source_id] = tree.geometryOwnerMembers
			authority_source_revisions[identity_key] = census_revision
			if not tree.supportRanges.is_empty(): support_ranges_by_source[identity_key] = tree.supportRanges
			for batch_key: String in tree.compatibilityByKey:
				if compatibility_by_key.has(batch_key) and compatibility_by_key[batch_key] != tree.compatibilityByKey[batch_key]:
					return _failed("citadel_tree_contributor_batch_conflict")
				compatibility_by_key[batch_key] = tree.compatibilityByKey[batch_key]
				resource_bindings[batch_key] = tree.resourceBindings[batch_key]
			if tree.inputs.is_empty() and tree.supportRanges.is_empty():
				var empty := {"sourceId":census_source_id, "sourcePartId":census_source_id,
					"sourceRevision":census_revision, "sectionKey":section_key,
					"ownerCell":Grid.chunk_key_for_section(section_key),
					"memberBinding":member_binding, "geometryGroupCount":0,
					"artifactRevision":String(tree.compiledSourceRevision)}
				empty.make_read_only()
				explicit_empty_contributors.append(empty)
			var tree_manifest := {"sourceId":census_source_id, "sourcePartId":census_source_id,
				"memberId":member_id, "sourceRevision":census_revision, "memberBinding":member_binding,
				"producerSourceId":tree.producerSourceId, "compiledSourceRevision":tree.compiledSourceRevision}
			tree_manifest.make_read_only()
			member_manifests.append(tree_manifest)
			continue
		if site_id.is_empty() or not (member_id.begins_with("building:") or member_id.begins_with("furnishing:")):
			return _pending("citadel_transform_artifact_member_kind_unsupported", {
				"sourceId":census_source_id, "memberId":member_id})
		var part_id := member_id.trim_prefix("furnishing:") if member_id.begins_with("furnishing:") else member_id.trim_prefix("building:")
		var identity_key := String(identity_key_by_source_id.get(census_source_id, ""))
		var census_revision := String(census.get("sourceRevisions", {}).get(identity_key, ""))
		var member_binding := String(member_bindings.get(census_source_id, ""))
		var capture_value: Variant = captures_by_source.get(census_source_id, null)
		if census_revision.is_empty() or member_binding.is_empty() \
				or not capture_value is Dictionary:
			return _pending("citadel_transform_artifact_member_identity_missing", {
				"sourceId":census_source_id})
		var capture: Dictionary = capture_value
		var groups_value: Variant = capture.get("groups", null)
		if capture.get("status") != "ready" \
				or String(capture.get("sourcePartId", "")) != part_id \
				or String(capture.get("sourceRevision", "")) != member_binding \
				or not groups_value is Array or not groups_value.is_read_only():
			return _pending("citadel_transform_artifact_roster_missing_or_stale", {
				"sourceId":census_source_id, "sourcePartId":part_id})
		var normalized_groups: Array[Dictionary] = []
		var geometry_groups: Array[Dictionary] = []
		var intersecting_support_instance_count := 0
		var member_support_ranges: Array[Dictionary] = []
		var complete_members: Array[Dictionary] = []
		for group_value: Variant in groups_value:
			if not group_value is Dictionary or not group_value.is_read_only():
				return _pending("citadel_transform_artifact_group_unsealed", {
					"sourceId":census_source_id})
			var group: Dictionary = group_value
			var group_source_id := String(group.get("sourceId", ""))
			var group_content_digest := String(group.get("contentDigest", ""))
			var artifact_kind := "furnishing-transform" if member_id.begins_with("furnishing:") else "building-transform"
			var expected_group_source_id := "%s:%s:%s:%s" % [
				artifact_kind, site_id, part_id, group_content_digest.substr(0, 24)]
			if group_source_id.is_empty() or observed_group_ids.has(group_source_id) \
					or group_source_id != expected_group_source_id:
				return _pending("citadel_transform_artifact_group_identity_mismatch", {
					"sourceId":census_source_id, "artifactSourceId":group_source_id})
			observed_group_ids[group_source_id] = true
			var prepared_groups := _prepare_transform_artifact_groups(group,
				census_source_id, part_id, census_revision, member_binding,
				section_key, pov_snapshot)
			if prepared_groups.get("status") != "ready":
				prepared_groups["sourceId"] = census_source_id
				return prepared_groups
			for normalized: Dictionary in prepared_groups.groups:
				normalized_groups.append(normalized)
				complete_members.append_array(normalized.geometryOwnerMembers)
				intersecting_support_instance_count += int(normalized.get("supportInstanceCount", 0))
				member_support_ranges.append_array(normalized.get("supportRanges", []))
				if not normalized.get("segments", []).is_empty(): geometry_groups.append(normalized)
		member_support_ranges.make_read_only()
		complete_members.make_read_only()
		complete_members_by_source[census_source_id] = complete_members
		if not member_support_ranges.is_empty():
			support_ranges_by_source[identity_key] = member_support_ranges
		normalized_groups.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a.get("groupKey", "")) < String(b.get("groupKey", "")))
		geometry_groups.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return String(a.get("groupKey", "")) < String(b.get("groupKey", "")))
		var captured_presentations: Variant = capture.get("presentationMounts", null)
		var captured_bindings: Variant = capture.get("presentationBindings", null)
		var presentation_digest := String(capture.get("presentationDigest", ""))
		if not captured_presentations is Array or not captured_presentations.is_read_only() \
				or not captured_bindings is Dictionary or not captured_bindings.is_read_only():
			return _pending("citadel_transform_artifact_presentation_roster_unavailable", {
				"sourceId":census_source_id})
		if captured_presentations.size() > PresentationMembers.MAX_MEMBERS \
				or captured_bindings.size() != captured_presentations.size() \
				or presentation_digest != _sha256([
					"building-practical-light-presentation/v1", captured_presentations]):
			return _failed("citadel_transform_artifact_presentation_roster_invalid")
		var presentation_rows: Array[Dictionary] = []
		var presentation_keys: Dictionary = {}
		for raw_value: Variant in captured_presentations:
			if not raw_value is Dictionary or not raw_value.is_read_only():
				return _pending("citadel_transform_artifact_presentation_member_unsealed", {
					"sourceId":census_source_id})
			var raw: Dictionary = raw_value
			var attachment_key := String(raw.get("attachmentKey", ""))
			var presentation_member_id := String(raw.get("presentationMemberId", ""))
			if attachment_key.is_empty() or presentation_keys.has(attachment_key) \
					or String(raw.get("sourcePartId", "")) != part_id \
					or String(raw.get("sourceRevision", "")) != member_binding:
				return _pending("citadel_transform_artifact_presentation_source_mismatch", {
					"sourceId":census_source_id, "sourcePartId":part_id})
			var member := {"schema":PresentationMembers.SCHEMA,
				"sourceId":census_source_id, "sourcePartId":census_source_id,
				"sourceRevision":census_revision,
				"producerSourceRevision":member_binding,
				"presentationMemberId":presentation_member_id, "attachmentKey":attachment_key,
				"ownershipKind":String(raw.get("ownershipKind", "")),
				"intendedVisible":raw.get("intendedVisible", false),
				"neutralParentToWorld":raw.get("neutralParentToWorld", Transform3D.IDENTITY),
				"sweptWorldBounds":raw.get("sweptWorldBounds", AABB()),
				"motion":raw.get("motion", {})}
			member.make_read_only()
			var validation := PresentationMembers.validate(member,
				census_source_id, census_source_id, census_revision)
			if validation.get("status") != "ready": return validation
			var raw_binding_value: Variant = captured_bindings.get(attachment_key, null)
			if not raw_binding_value is Dictionary or not raw_binding_value.is_read_only():
				return _pending("citadel_transform_artifact_presentation_binding_missing", {
					"sourceId":census_source_id, "attachmentKey":attachment_key})
			var binding: Dictionary = raw_binding_value.duplicate(false)
			binding["sourceId"] = census_source_id
			binding["sourcePartId"] = census_source_id
			binding["sourceRevision"] = census_revision
			binding["producerSourceRevision"] = member_binding
			binding["producerSourcePartId"] = part_id
			for field: String in ["sourceId", "sourcePartId", "sourceRevision",
					"producerSourceRevision", "presentationMemberId", "attachmentKey", "ownershipKind", "intendedVisible",
					"neutralParentToWorld", "sweptWorldBounds", "motion"]:
				if not binding.has(field) or binding[field] != member[field]:
					return _pending("citadel_transform_artifact_presentation_binding_mismatch", {
						"sourceId":census_source_id, "field":field})
			binding.make_read_only()
			if attachment_bindings.has(attachment_key) \
					and attachment_bindings[attachment_key] != binding:
				return _pending("citadel_transform_artifact_presentation_binding_conflict", {
					"sourceId":census_source_id, "attachmentKey":attachment_key})
			attachment_bindings[attachment_key] = binding
			presentation_keys[attachment_key] = true
			presentation_rows.append(member)
		presentation_rows.make_read_only()
		presentation_owner_members_by_source[census_source_id] = presentation_rows
		if normalized_groups.is_empty() and member_support_ranges.is_empty() \
				and presentation_rows.is_empty():
			return _pending("citadel_transform_artifact_member_roster_empty", {
				"sourceId":census_source_id, "sectionKey":section_key})
		var revision_payload: Array = [SCHEMA, String(census.worldId), section_key,
			census_source_id, census_revision, member_binding, candidate_generation,
			presentation_digest]
		for normalized_group: Dictionary in normalized_groups:
			revision_payload.append([String(normalized_group.get("artifactSourceId", "")),
				String(normalized_group.get("artifactContentDigest", "")),
				String(normalized_group.get("contentDigest", ""))])
		var revision_hash := _sha256(revision_payload)
		if revision_hash.is_empty():
			return _failed("citadel_transform_artifact_member_revision_hash_failed")
		var presentation_rows_owned_here: Array[Dictionary] = []
		for presentation_row: Dictionary in presentation_rows:
			var neutral_value: Variant = presentation_row.get("neutralParentToWorld", null)
			if not neutral_value is Transform3D or not neutral_value.is_finite():
				return _failed("citadel_transform_artifact_presentation_anchor_invalid")
			var presentation_owner_section := Grid.key_for_world_position(
				(neutral_value as Transform3D).origin)
			if presentation_owner_section == section_key:
				presentation_rows_owned_here.append(presentation_row)
		presentation_rows_owned_here.make_read_only()
		# Logical source ownership is independent of the section installing it.
		# Mixed geometry and borrowed presentation must name the same producer owner.
		var presentation_owner_cell := Grid.chunk_key_for_section(section_key)
		if not normalized_groups.is_empty():
			presentation_owner_cell = normalized_groups[0].ownerCell
			for source_group: Dictionary in normalized_groups:
				if source_group.ownerCell != presentation_owner_cell:
					return _failed("citadel_transform_artifact_source_owner_conflict")
		if not presentation_rows_owned_here.is_empty():
			var presentation_contributor := {"sourceId":census_source_id,
				"sourcePartId":census_source_id, "sourceRevision":census_revision,
				"sectionKey":section_key,
				"ownerCell":presentation_owner_cell,
				"presentationMembers":presentation_rows_owned_here}
			presentation_contributor.make_read_only()
			presentation_contributors.append(presentation_contributor)
		if geometry_groups.is_empty() and member_support_ranges.is_empty() \
				and presentation_rows_owned_here.is_empty():
			var empty_contributor := {"sourceId":census_source_id,
				"sourcePartId":census_source_id, "sourceRevision":census_revision,
				"sectionKey":section_key,
				"ownerCell":Grid.chunk_key_for_section(section_key),
				"artifactRevision":revision_hash,
				"memberBinding":member_binding,
				"geometryGroupCount":0}
			empty_contributor.make_read_only()
			explicit_empty_contributors.append(empty_contributor)
		authority_source_revisions[identity_key] = census_revision
		var member_batch_keys: Array[String] = []
		for normalized_group: Dictionary in geometry_groups:
			var compatibility: Dictionary = normalized_group.compatibility
			var batch_key := String(compatibility.get("batchKey", ""))
			if batch_key.is_empty() or not compatibility.is_read_only():
				return _failed("citadel_transform_artifact_batch_compatibility_invalid")
			if compatibility_by_key.has(batch_key) \
					and compatibility_by_key[batch_key] != compatibility:
				return _failed("citadel_transform_artifact_batch_compatibility_conflict")
			compatibility_by_key[batch_key] = compatibility
			var resources := {"mesh":normalized_group.mesh,
				"material":normalized_group.material,
				"materialDigest":String(normalized_group.materialDigest)}
			resources.make_read_only()
			resource_bindings[batch_key] = resources
			var attachment_key := String(compatibility.get("attachmentKey", ""))
			if not attachment_key.is_empty():
				var binding: Variant = normalized_group.get("attachmentBinding")
				if not binding is Dictionary or not binding.is_read_only():
					return _pending("citadel_attachment_binding_unavailable")
				var candidate_binding: Dictionary = binding.duplicate(false)
				candidate_binding["sourceId"] = census_source_id
				candidate_binding["sourcePartId"] = census_source_id
				candidate_binding["sourceRevision"] = census_revision
				candidate_binding["producerSourceRevision"] = member_binding
				candidate_binding.make_read_only()
				if attachment_bindings.has(attachment_key) \
						and attachment_bindings[attachment_key] != candidate_binding:
					return _pending("citadel_attachment_binding_conflict")
				attachment_bindings[attachment_key] = candidate_binding
			member_batch_keys.append(batch_key)
			for segment: Dictionary in normalized_group.segments:
				var input := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
					"sourceId":census_source_id, "sourcePartId":census_source_id,
					"sourceRevision":census_revision,
					"producerSourceRevision":member_binding,
					"artifactRevision":revision_hash,
					"ownerCell":normalized_group.ownerCell,
					"renderChunkKey":normalized_group.renderChunkKey,
					"sourceToWorld":normalized_group.sourceToWorld,
					"meshLocalBounds":normalized_group.meshLocalBounds,
					"batchKey":batch_key, "segmentId":String(segment.segmentId),
					"buffer":segment.buffer, "instanceCount":int(segment.instanceCount),
					"artifactSourceId":String(normalized_group.artifactSourceId),
					"artifactContentDigest":String(normalized_group.artifactContentDigest),
					"artifactSegmentId":String(segment.get("artifactSegmentId", "")),
					"artifactSegmentDigest":String(segment.get("artifactSegmentDigest", "")),
					"memberBinding":member_binding, "censusRevision":census_revision,
					"renderLayer":String(compatibility.renderLayer),
					"translucentSortPolicy":String(compatibility.translucentSortPolicy)}
				if compatibility.has("compoundAnchor"):
					input["compoundAnchor"] = compatibility.compoundAnchor
					input["ownershipPolicy"] = "compound_attachment_anchor/v1"
				input.make_read_only()
				inputs.append(input)
		member_batch_keys.sort()
		var member_manifest := {"sourceId":census_source_id,
			"sourcePartId":census_source_id, "memberId":member_id,
			"sourceRevision":census_revision,
			"producerSourceRevision":member_binding, "artifactRevision":revision_hash,
			"memberBinding":member_binding,
			"censusRevision":census_revision, "artifactGroupCount":normalized_groups.size(),
			"geometryGroupCount":geometry_groups.size(),
			"batchKeys":member_batch_keys}
		member_manifest.batchKeys.make_read_only()
		member_manifest.make_read_only()
		member_manifests.append(member_manifest)
	inputs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if String(a.sourceId) != String(b.sourceId):
			return String(a.sourceId) < String(b.sourceId)
		if String(a.batchKey) != String(b.batchKey):
			return String(a.batchKey) < String(b.batchKey)
		return String(a.segmentId) < String(b.segmentId))
	inputs.make_read_only()
	explicit_empty_contributors.make_read_only()
	support_ranges_by_source.make_read_only()
	authority_source_revisions.make_read_only()
	compatibility_by_key.make_read_only()
	resource_bindings.make_read_only()
	attachment_bindings.make_read_only()
	member_manifests.make_read_only()
	presentation_contributors.make_read_only()
	presentation_owner_members_by_source.make_read_only()
	var contribution := {"providerId":"blueprint_buildings",
		"sectionKey":section_key, "coverageRevision":coverage_revision,
		"authorityRevision":provider_revision,
		"authoritySourceRevisions":authority_source_revisions,
		"inputs":inputs, "explicitEmptyContributors":explicit_empty_contributors,
		"supportRangesBySource":support_ranges_by_source,
		"presentationContributors":presentation_contributors,
		"compatibilityByKey":compatibility_by_key,
		"resourceBindings":resource_bindings, "attachmentBindings":attachment_bindings,
		"transformArtifactMembers":member_manifests,
		"candidateGeneration":candidate_generation}
	contribution.transformArtifactMembers.make_read_only()
	contribution.make_read_only()
	complete_members_by_source.make_read_only()
	return {"status":"ready", "contribution":contribution,
		"geometryOwnerMembersBySource":complete_members_by_source,
		"presentationOwnerMembersBySource":presentation_owner_members_by_source,
		"memberCount":source_ids.size(), "inputCount":inputs.size(),
		"batchCount":compatibility_by_key.size(),
		"evidenceScope":"sealed publisher transform artifacts normalized to the shared assembler contribution schema; no service integration or native install"}


static func _prepare_transform_artifact_groups(group: Dictionary,
		source_id: String, part_id: String, census_revision: String,
		member_binding: String, section_key: Vector3i, pov: Dictionary) -> Dictionary:
	# Validate the complete original immutable artifact before deriving anything.
	var original := _prepare_transform_artifact_group(group, source_id, part_id,
		census_revision, member_binding, section_key)
	if original.get("status") != "ready": return original
	if group.get("renderLayer") != "translucent": return {"status":"ready", "groups":[original]}
	var prepared := TranslucentPreparation.prepare(group, pov)
	if prepared.get("status") != "ready": return prepared
	var groups: Array[Dictionary] = []
	for row: Dictionary in prepared.groups:
		var bounds: AABB = row.mesh.get_aabb()
		var segment := {"segmentId":row.segmentId, "buffer":row.buffer,
			"bounds":bounds, "instanceCount":1, "instanceAttributeLayout":Attributes.LAYOUT_SCHEMA}
		segment["contentDigest"] = _sha256([segment.segmentId, 1, bounds, row.buffer])
		segment.make_read_only()
		var segments: Array[Dictionary] = [segment]
		segments.make_read_only()
		var resources := {"mesh":row.mesh, "material":group.resourceBindings.material}
		resources.make_read_only()
		var derived := group.duplicate(false)
		derived["sourceId"] = String(group.sourceId) + ":" + String(row.segmentId)
		derived["segments"] = segments
		derived["resourceBindings"] = resources
		derived["instanceCount"] = 1
		derived["sourceToWorld"] = row.sourceToWorld
		derived["localBounds"] = bounds
		derived["worldBounds"] = row.sourceToWorld * bounds
		# The baked mesh has its own local frame. Do not inherit the original
		# window mesh's support box when validating this derived candidate.
		derived["meshSupportBounds"] = bounds
		derived["meshContentDigest"] = row.meshContentDigest
		derived["meshKey"] = "building-mesh:" + String(row.meshContentDigest)
		derived["translucentSortDescriptor"] = row.descriptor
		derived["contentDigest"] = _transform_artifact_content_digest(derived)
		derived["sourceId"] = String(derived.sourceId) + ":" + String(derived.contentDigest).substr(0,24)
		derived.make_read_only()
		var normalized := _prepare_transform_artifact_group(derived, source_id, part_id,
			census_revision, member_binding, section_key)
		if normalized.get("status") != "ready": return normalized
		normalized["translucentBakeUsec"] = prepared.bakeUsec
		groups.append(normalized)
	return {"status":"ready", "groups":groups}


static func _prepare_transform_artifact_group(group: Dictionary,
		source_id: String, part_id: String, census_revision: String,
		member_binding: String, section_key: Vector3i) -> Dictionary:
	var artifact_source_id := String(group.get("sourceId", ""))
	var resource_value: Variant = group.get("resourceBindings", null)
	if not resource_value is Dictionary or not resource_value.is_read_only():
		return _pending("citadel_transform_artifact_resources_unsealed", {
			"sourceId":source_id, "artifactSourceId":artifact_source_id})
	var resources: Dictionary = resource_value
	var mesh: Variant = resources.get("mesh")
	var material: Variant = resources.get("material")
	var segments_value: Variant = group.get("segments", null)
	var source_to_world: Variant = group.get("sourceToWorld", null)
	var local_bounds: Variant = group.get("localBounds", null)
	var world_bounds: Variant = group.get("worldBounds", null)
	var owner_cell: Variant = group.get("ownerCell", null)
	var render_chunk_key: Variant = group.get("renderChunkKey", null)
	var render_layer := String(group.get("renderLayer", ""))
	var sort_policy := String(group.get("transparencySortPolicy", ""))
	if String(group.get("schema", "")) != TRANSFORM_ARTIFACT_SCHEMA \
			or String(group.get("sourcePartId", "")) != part_id \
			or String(group.get("sourceRevision", "")) != member_binding \
			or String(group.get("contentDigest", "")).length() != 64 \
			or not artifact_source_id.ends_with(String(group.get("contentDigest", "")).substr(0, 24)) \
			or String(group.get("materialKey", "")).is_empty() \
			or String(group.get("meshKey", "")).is_empty() \
			or String(group.get("instanceAttributeLayout", "")) != Attributes.LAYOUT_SCHEMA \
			or not owner_cell is Vector2i or not render_chunk_key is Vector2i \
			or not source_to_world is Transform3D or not _valid_transform(source_to_world) \
			or not local_bounds is AABB or not _valid_bounds(local_bounds) \
			or not world_bounds is AABB or not _valid_bounds(world_bounds) \
			or not segments_value is Array or not segments_value.is_read_only() \
			or segments_value.is_empty() or not is_instance_valid(mesh) \
			or not mesh is Mesh or not is_instance_valid(material) \
			or not material is Material:
		return _pending("citadel_transform_artifact_group_manifest_incomplete", {
			"sourceId":source_id, "artifactSourceId":artifact_source_id})
	if render_layer not in ["opaque", "cutout", "translucent"] \
			or not _material_matches_layer(material as Material, render_layer, sort_policy):
		return _pending("citadel_transform_artifact_layer_policy_unsupported", {
			"sourceId":source_id, "renderLayer":render_layer,
			"transparencySortPolicy":sort_policy, "materialClass":material.get_class()})
	var mesh_fingerprint: Dictionary = MeshFingerprint.inspect(mesh as Mesh)
	var material_fingerprint: Dictionary = OrdinaryGeometryAdapter._material_identity(
		material as Material)
	if mesh_fingerprint.get("status") != "ready" \
			or String(mesh_fingerprint.get("contentDigest", "")) \
			!= String(group.get("meshContentDigest", "")) \
			or String(material_fingerprint.get("digest", "")) \
			!= String(group.get("materialContentDigest", "")) \
			or String(group.get("meshKey", "")) \
			!= "building-mesh:" + String(mesh_fingerprint.get("contentDigest", "")):
		return _pending("citadel_transform_artifact_resource_identity_stale", {
			"sourceId":source_id, "artifactSourceId":artifact_source_id})
	if _transform_artifact_content_digest(group) != String(group.get("contentDigest", "")):
		return _pending("citadel_transform_artifact_content_digest_stale", {
			"sourceId":source_id, "artifactSourceId":artifact_source_id})
	if not _bounds_approx(source_to_world * (local_bounds as AABB), world_bounds as AABB):
		return _pending("citadel_transform_artifact_world_bounds_mismatch", {
			"sourceId":source_id, "artifactSourceId":artifact_source_id})
	var actual_mesh_bounds := (mesh as Mesh).get_aabb()
	var support_bounds_value: Variant = group.get("meshSupportBounds", actual_mesh_bounds)
	if not support_bounds_value is AABB:
		return _pending("citadel_transform_artifact_mesh_bounds_invalid", {"sourceId":source_id})
	var mesh_bounds: AABB = support_bounds_value
	if not _valid_bounds(mesh_bounds) \
			or not actual_mesh_bounds.position.is_finite() \
			or not actual_mesh_bounds.size.is_finite() \
			or not _bounds_contains(mesh_bounds, actual_mesh_bounds):
		return _pending("citadel_transform_artifact_mesh_bounds_invalid", {"sourceId":source_id})
	var tier := String(group.get("renderTier", ""))
	var policy := _render_policy(tier)
	# Furnishings share the native detail tier, while preserving the source
	# publisher's unlimited range and shadow policy in the draw compatibility.
	if artifact_source_id.begins_with("furnishing-transform:") and tier == "detail":
		policy = {"visibilityRangeEnd":0.0, "fadeMargin":0.0, "castShadows":true}
	if policy.is_empty():
		return _pending("citadel_transform_artifact_render_tier_unsupported", {
			"sourceId":source_id, "renderTier":tier})
	var pipeline_revision := "building-transform-static/v1/" + render_layer
	var material_key := String(group.materialKey) + "|" + String(material_fingerprint.digest)
	var mesh_digest := String(mesh_fingerprint.contentDigest)
	var mesh_resource_key := "building-mesh:" + mesh_digest
	var mesh_key := "%s|pipeline=%s|layer=%s|sort=%s" % [
		mesh_resource_key, pipeline_revision, render_layer, sort_policy]
	var compatibility := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"materialKey":material_key, "renderTier":tier,
		"meshResourceKey":mesh_resource_key, "meshContentDigest":mesh_digest,
		"meshKey":mesh_key, "pipelineRevision":pipeline_revision,
		"renderLayer":render_layer, "translucentSortPolicy":sort_policy,
		"meshLocalBounds":mesh_bounds, "castShadows":bool(policy.castShadows),
		"visibilityRangeEnd":float(policy.visibilityRangeEnd),
		"fadeMargin":float(policy.fadeMargin)}
	if group.has("translucentSortDescriptor"):
		compatibility["translucentSortDescriptor"] = group.translucentSortDescriptor
		# Distinct placements can share identical sorted vertices but use a different
		# local camera. They must not merge into an invalid multi-instance batch.
		compatibility["pipelineRevision"] = pipeline_revision + "/" + _sha256([group.sourceId, group.sourceToWorld])
		compatibility["meshKey"] = "%s|pipeline=%s|layer=%s|sort=%s" % [mesh_resource_key,
			compatibility.pipelineRevision, render_layer, sort_policy]
	if group.has("compoundAnchor") and not group.get("intendedVisible") is bool:
		return _pending("citadel_compound_visibility_policy_missing")
	compatibility["intendedVisible"] = group.get("intendedVisible", true)
	if group.has("compoundAnchor"):
		var anchor: Variant = group.get("compoundAnchor")
		if not SectionSnapshot.valid_compound_anchor(anchor) \
				or anchor.key != "building-door:%s:%s:bundle" % [_site_id_from_census_source(source_id),part_id]:
			return _pending("citadel_compound_anchor_invalid")
		compatibility["compoundAnchor"] = anchor
		compatibility["ownershipPolicy"] = "compound_attachment_anchor/v1"
	if not String(group.get("attachmentKey", "")).is_empty():
		compatibility["producerSourceRevision"] = member_binding
		for field: String in ["attachmentKey", "neutralParentToWorld", "sweptWorldBounds", "motion"]:
			compatibility[field] = group.get(field)
	var batch_key := SnapshotBuilder.batch_compatibility_key(compatibility)
	# Compound render attachments own their full visual bundle at the source
	# anchor, like a Minecraft section's block-entity roster.
	if batch_key.is_empty():
		return _pending("citadel_transform_artifact_batch_key_invalid", {"sourceId":source_id})
	compatibility["batchKey"] = batch_key
	compatibility["compatibilityKey"] = batch_key
	compatibility.make_read_only()
	var normalized_segments: Array[Dictionary] = []
	var all_local_bounds := AABB()
	var all_selected_bounds := AABB()
	var all_world_bounds := AABB()
	var local_bound_count := 0
	var first_local_segment := true
	var support_instance_count := 0
	var support_ranges: Array[Dictionary] = []
	var complete_members: Array[Dictionary] = []
	for segment_value: Variant in segments_value:
		if not segment_value is Dictionary or not segment_value.is_read_only():
			return _pending("citadel_transform_artifact_segment_unsealed", {"sourceId":source_id})
		var segment: Dictionary = segment_value
		var segment_id := String(segment.get("segmentId", ""))
		var buffer: Variant = segment.get("buffer", null)
		var count_value: Variant = segment.get("instanceCount", null)
		var segment_bounds: Variant = segment.get("bounds", null)
		if segment_id.is_empty() or not buffer is Array \
				or buffer.get_typed_builtin() != TYPE_FLOAT or not buffer.is_read_only() \
				or not count_value is int or int(count_value) <= 0 or int(count_value) > 256 \
				or buffer.size() != int(count_value) * Attributes.FLOATS_PER_INSTANCE \
				or not segment_bounds is AABB or not _valid_bounds(segment_bounds) \
				or segment.get("instanceAttributeLayout") != Attributes.LAYOUT_SCHEMA:
			return _pending("citadel_transform_artifact_segment_layout_invalid", {
				"sourceId":source_id, "segmentId":segment_id})
		var expected_segment_digest := _sha256([segment_id, int(count_value), segment_bounds, buffer])
		if expected_segment_digest.is_empty() \
				or expected_segment_digest != String(segment.get("contentDigest", "")):
			return _pending("citadel_transform_artifact_segment_digest_stale", {
				"sourceId":source_id, "segmentId":segment_id})
		for component_value: Variant in buffer:
			if not is_finite(float(component_value)):
				return _failed("citadel_transform_artifact_segment_nonfinite_attribute")
		var selected_buffer: Array[float] = []
		var selected_segment_bounds := AABB()
		var selected_world_bounds := AABB()
		var local_segment_bounds := AABB()
		var segment_selected_count := 0
		var owner_instance_counts: Dictionary = {}
		for instance_index in range(int(count_value)):
			var offset := instance_index * Attributes.FLOATS_PER_INSTANCE
			var local_transform := Attributes.decode_transform(buffer, offset)
			if not _valid_transform(local_transform):
				return _failed("citadel_transform_artifact_instance_transform_invalid")
			var instance_local_bounds := local_transform * mesh_bounds
			local_segment_bounds = instance_local_bounds if instance_index == 0 \
				else local_segment_bounds.merge(instance_local_bounds)
			var instance_world_bounds := (source_to_world as Transform3D) * instance_local_bounds
			var support_bounds: AABB = group.get("sweptWorldBounds", instance_world_bounds)
			if not _valid_bounds(instance_world_bounds):
				return _failed("citadel_transform_artifact_instance_bounds_invalid")
			all_world_bounds = instance_world_bounds if local_bound_count == 0 \
				else all_world_bounds.merge(instance_world_bounds)
			local_bound_count += 1
			var center := instance_world_bounds.position + instance_world_bounds.size * 0.5
			var owner_position: Vector3 = group.get("compoundAnchor", {}).get("worldPosition", center)
			var instance_owner_section := Grid.key_for_world_position(owner_position)
			var owner_instance_index := int(owner_instance_counts.get(instance_owner_section, 0))
			owner_instance_counts[instance_owner_section] = owner_instance_index + 1
			var complete_segment_id := "%s:%s@%d,%d,%d" % [artifact_source_id,
				segment_id, instance_owner_section.x, instance_owner_section.y, instance_owner_section.z]
			var complete_member := OwnerCompletion.capture_member(source_id, source_id,
				census_revision, complete_segment_id, owner_instance_index, source_to_world,
				mesh_bounds, buffer, offset, compatibility)
			if complete_member.is_empty():
				return _pending("citadel_full_geometry_owner_member_invalid", {"sourceId":source_id})
			complete_members.append(complete_member)
			if instance_owner_section != section_key:
				if Grid.keys_intersecting_bounds(support_bounds).has(section_key):
					support_instance_count += 1
					var owner_section := instance_owner_section
					var source_segment := "%s:%s@%d,%d,%d" % [artifact_source_id,
						segment_id, owner_section.x, owner_section.y, owner_section.z]
					var dependencies: Array[Vector2i] = SectionSnapshot._stream_chunk_keys_intersecting_bounds(
						support_bounds).duplicate()
					var owner_chunk := Grid.chunk_key_for_section(owner_section)
					if owner_chunk not in dependencies:
						dependencies.append(owner_chunk)
					dependencies.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
						if a.x != b.x: return a.x < b.x
						return a.y < b.y)
					dependencies.make_read_only()
					var support := {"sourceId":source_id, "sourcePartId":source_id,
						"sourceRevision":census_revision,
						"memberId":"%s:%d" % [source_segment, owner_instance_index],
						"propId":source_id, "sourceSegmentId":source_segment,
						"sourceInstance":owner_instance_index, "ownerCell":owner_cell,
						"artifactInstanceIndex":instance_index,
						"sourceOwnerChunk":owner_chunk,
						"geometryOwnerSection":owner_section, "supportSectionKey":section_key,
						"worldBounds":instance_world_bounds, "streamChunkDependencies":dependencies,
						"ownershipPolicy":"citadel_center_geometry_owner/aabb_support_sections_v1",
						"meshContentDigest":String(mesh_fingerprint.contentDigest),
						"artifactSourceId":artifact_source_id,
						"artifactContentDigest":String(group.get("contentDigest", "")),
						"artifactSegmentId":segment_id,
						"artifactSegmentDigest":expected_segment_digest,
						"memberBinding":member_binding}
					if group.has("compoundAnchor"):
						support["compoundAnchor"] = group.compoundAnchor
						support["ownershipPolicy"] = "compound_anchor_geometry_owner/swept_support_sections_v1"
					if not String(group.get("attachmentKey", "")).is_empty():
						for field: String in ["attachmentKey", "neutralParentToWorld", "sweptWorldBounds", "motion"]:
							support[field] = group[field]
					support.make_read_only()
					support_ranges.append(support)
				continue
			for component_index in range(Attributes.FLOATS_PER_INSTANCE):
				selected_buffer.append(float(buffer[offset + component_index]))
			var selected_local_bounds := instance_local_bounds
			selected_segment_bounds = selected_local_bounds if segment_selected_count == 0 \
				else selected_segment_bounds.merge(selected_local_bounds)
			selected_world_bounds = instance_world_bounds if segment_selected_count == 0 \
				else selected_world_bounds.merge(instance_world_bounds)
			segment_selected_count += 1
		if not _bounds_approx(local_segment_bounds, segment_bounds as AABB):
			return _pending("citadel_transform_artifact_segment_bounds_mismatch", {
				"sourceId":source_id, "segmentId":segment_id})
		all_local_bounds = local_segment_bounds if first_local_segment \
			else all_local_bounds.merge(local_segment_bounds)
		first_local_segment = false
		if segment_selected_count > 0 and not selected_buffer.is_empty():
			selected_buffer.make_read_only()
			var slice_id := "%s@%d,%d,%d" % [artifact_source_id + ":" + segment_id,
				section_key.x, section_key.y, section_key.z]
			var slice_digest := _sha256([slice_id, segment_selected_count,
				selected_segment_bounds, selected_buffer])
			if slice_digest.is_empty():
				return _failed("citadel_transform_artifact_section_slice_digest_failed")
			var normalized_segment := {"segmentId":slice_id,
				"artifactSegmentId":segment_id,
				"artifactSegmentDigest":String(segment.get("contentDigest", "")),
				"buffer":selected_buffer,
				"bounds":selected_segment_bounds,
				"worldBounds":selected_world_bounds,
				"instanceCount":segment_selected_count,
				"contentDigest":slice_digest}
			normalized_segment.make_read_only()
			normalized_segments.append(normalized_segment)
			all_selected_bounds = selected_world_bounds if normalized_segments.size() == 1 \
				else all_selected_bounds.merge(selected_world_bounds)
	if int(group.get("instanceCount", -1)) != local_bound_count \
			or not _bounds_approx(all_local_bounds, local_bounds as AABB) \
			or not _valid_bounds(all_world_bounds) \
			or not _bounds_contains(world_bounds as AABB, all_world_bounds) \
			or (not normalized_segments.is_empty() and not _valid_bounds(all_selected_bounds)):
		return _pending("citadel_transform_artifact_group_bounds_mismatch", {
			"sourceId":source_id, "artifactSourceId":artifact_source_id})
	normalized_segments.make_read_only()
	support_ranges.make_read_only()
	complete_members.make_read_only()
	var group_digest := _sha256([SCHEMA, artifact_source_id,
		String(group.get("contentDigest", "")), source_id, census_revision,
		member_binding, section_key, String(mesh_fingerprint.contentDigest),
		String(material_fingerprint.digest), source_to_world,
		owner_cell, render_chunk_key, render_layer, sort_policy])
	if group_digest.is_empty():
		return _failed("citadel_transform_artifact_group_digest_failed")
	return {"status":"ready", "groupKey":batch_key,
		"artifactSourceId":artifact_source_id,
		"artifactContentDigest":String(group.get("contentDigest", "")),
		"contentDigest":group_digest, "compatibility":compatibility,
		"producerSourceRevision":member_binding,
		"segments":normalized_segments, "ownerCell":owner_cell,
		"renderChunkKey":render_chunk_key,
		"meshLocalBounds":mesh_bounds, "mesh":mesh,
		"material":material, "materialDigest":String(material_fingerprint.digest),
		"supportInstanceCount":support_instance_count,
		"supportRanges":support_ranges,
		"geometryOwnerMembers":complete_members,
		"sourceToWorld":source_to_world,
		"attachmentBinding":group.get("attachmentBinding", {})}


static func _material_matches_layer(material: Material, layer: String,
		sort_policy: String) -> bool:
	if material is ShaderMaterial:
		return layer == "opaque" and sort_policy == "none" \
			and OrdinaryGeometryAdapter._material_is_opaque(material)
	if not material is StandardMaterial3D:
		return false
	var standard := material as StandardMaterial3D
	match standard.transparency:
		BaseMaterial3D.TRANSPARENCY_DISABLED:
			return layer == "opaque" and sort_policy == "none" \
				and standard.albedo_color.a >= 0.999
		BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			return layer == "cutout" and sort_policy == "none"
		BaseMaterial3D.TRANSPARENCY_ALPHA:
			return layer == "translucent" and sort_policy == "camera_depth"
	return false


static func _sha256(value: Variant) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes(value)) != OK:
		return ""
	return context.finish().hex_encode()


static func _transform_artifact_content_digest(group: Dictionary) -> String:
	var segments: Variant = group.get("segments", null)
	var resources: Variant = group.get("resourceBindings", null)
	if not segments is Array or not resources is Dictionary:
		return ""
	var mesh: Variant = resources.get("mesh")
	var material: Variant = resources.get("material")
	if not mesh is Mesh or not material is Material:
		return ""
	var mesh_identity: Dictionary = MeshFingerprint.inspect(mesh as Mesh)
	var material_identity: Dictionary = OrdinaryGeometryAdapter._material_identity(material as Material)
	if mesh_identity.get("status") != "ready" or material_identity.is_empty():
		return ""
	var payload := [String(group.get("sourcePartId", "")),
		String(group.get("sourceRevision", "")), group.get("ownerCell"),
		group.get("renderChunkKey"), String(group.get("materialKey", "")),
		String(group.get("renderTier", "")), String(group.get("renderLayer", "")),
		String(group.get("transparencySortPolicy", "")),
		String(mesh_identity.get("contentDigest", "")),
		String(material_identity.get("digest", "")),
		group.get("sourceToWorld"), int(group.get("instanceCount", 0))]
	if group.has("intendedVisible"): payload.append(group.intendedVisible)
	if not String(group.get("attachmentKey", "")).is_empty():
		payload.append([group.get("attachmentKey"),group.get("neutralParentToWorld"),group.get("sweptWorldBounds"),group.get("motion")])
	if group.has("compoundAnchor"): payload.append(group.compoundAnchor)
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes(payload)) != OK:
		return ""
	for segment_value: Variant in segments:
		if not segment_value is Dictionary:
			return ""
		var segment: Dictionary = segment_value
		if context.update(var_to_bytes([String(segment.get("segmentId", "")),
				segment.get("bounds"), int(segment.get("instanceCount", 0)),
				String(segment.get("contentDigest", ""))])) != OK:
			return ""
	return context.finish().hex_encode()


static func _bounds_contains(outer: AABB, inner: AABB) -> bool:
	const EPSILON := 0.001
	return outer.position.x <= inner.position.x + EPSILON \
		and outer.position.y <= inner.position.y + EPSILON \
		and outer.position.z <= inner.position.z + EPSILON \
		and outer.end.x + EPSILON >= inner.end.x \
		and outer.end.y + EPSILON >= inner.end.y \
		and outer.end.z + EPSILON >= inner.end.z


static func _prepare_group(group: Dictionary, source_id: String, part_id: String,
		census_revision: String, member_binding: String,
		source_to_world: Transform3D, default_mesh: Mesh) -> Dictionary:
	var material: Variant = group.get("material")
	if not material is Material:
		return _pending("citadel_packet_material_unavailable", {"sourcePartId":part_id})
	var layer := _opaque_layer(material)
	if layer.is_empty():
		return _pending("citadel_packet_material_layer_not_supported", {
			"sourceId":source_id, "materialClass":material.get_class()})
	var mesh: Mesh = group.get("mesh", default_mesh) as Mesh
	if mesh == null:
		return _pending("citadel_packet_mesh_unavailable", {"sourcePartId":part_id})
	var mesh_fingerprint: Dictionary = MeshFingerprint.inspect(mesh)
	if mesh_fingerprint.get("status") != "ready":
		return _pending("citadel_packet_mesh_digest_unavailable", {
			"reason":String(mesh_fingerprint.get("reason", ""))})
	var material_fingerprint := _material_identity(material)
	if material_fingerprint.is_empty():
		return _pending("citadel_packet_material_digest_unavailable", {"sourcePartId":part_id})
	var material_key := String(group.get("materialKey", "")) + "|" + String(material_fingerprint.get("digest", ""))
	var mesh_digest := String(mesh_fingerprint.contentDigest)
	var mesh_key := "citadel-packet-mesh:" + mesh_digest
	var tier := String(group.get("renderTier", ""))
	var policy := _render_policy(tier)
	if policy.is_empty():
		return _pending("citadel_packet_render_tier_not_supported", {"renderTier":tier})
	var mesh_bounds := mesh.get_aabb()
	if not _valid_bounds(mesh_bounds):
		return _failed("citadel_packet_mesh_bounds_invalid")
	var pipeline_revision := PIPELINE_REVISION + "/" + layer
	var sort_policy := "none"
	var mesh_resource_key := mesh_key
	var mesh_pipeline_key := "%s|pipeline=%s|layer=%s|sort=%s" % [
		mesh_resource_key, pipeline_revision, layer, sort_policy]
	var compatibility := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"materialKey":material_key, "renderTier":tier,
		"meshResourceKey":mesh_resource_key, "meshContentDigest":mesh_digest,
		"meshKey":mesh_pipeline_key, "pipelineRevision":pipeline_revision,
		"renderLayer":layer, "translucentSortPolicy":sort_policy,
		"meshLocalBounds":mesh_bounds, "castShadows":bool(policy.castShadows),
		"visibilityRangeEnd":float(policy.visibilityRangeEnd),
		"fadeMargin":float(policy.fadeMargin)}
	var batch_key := SnapshotBuilder.batch_compatibility_key(compatibility)
	if batch_key.is_empty():
		return _pending("citadel_packet_batch_compatibility_invalid", {"sourcePartId":part_id})
	compatibility["batchKey"] = batch_key
	compatibility["compatibilityKey"] = batch_key
	compatibility.make_read_only()
	var segments: Array[Dictionary] = []
	var segment_keys: Array = group.preparedSegments.keys()
	segment_keys.sort()
	for segment_key: Variant in segment_keys:
		var source: Variant = group.preparedSegments[segment_key]
		if not source is Dictionary or not source.is_read_only() \
				or not source.get("buffer") is Array \
				or source.buffer.get_typed_builtin() != TYPE_FLOAT \
				or not source.buffer.is_read_only() \
				or not source.get("bounds") is AABB \
				or not source.get("instanceCount") is int:
			return _pending("citadel_packet_segment_value_unsealed", {"sourcePartId":part_id})
		var count := int(source.instanceCount)
		if count < 1 or source.buffer.size() != count * Attributes.FLOATS_PER_INSTANCE \
				or not _valid_bounds(source.bounds):
			return _failed("citadel_packet_segment_layout_invalid")
		for component: Variant in source.buffer:
			if not is_finite(float(component)):
				return _failed("citadel_packet_segment_nonfinite_attribute")
		var segment_copy: Array[float] = []
		segment_copy.assign(source.buffer)
		segment_copy.make_read_only()
		var actual_bounds := AABB()
		for instance_index in range(count):
			var instance_transform := Attributes.decode_transform(segment_copy,
				instance_index * Attributes.FLOATS_PER_INSTANCE)
			var instance_bounds := instance_transform * mesh_bounds
			actual_bounds = instance_bounds if instance_index == 0 \
				else actual_bounds.merge(instance_bounds)
		if not _bounds_approx(actual_bounds, source.bounds):
			return _pending("citadel_packet_segment_bounds_disagree_with_instances", {
				"sourcePartId":part_id, "segmentIndex":segment_key})
		var digest := HashingContext.new()
		if digest.start(HashingContext.HASH_SHA256) != OK \
				or digest.update(var_to_bytes([source.bounds, count, segment_copy])) != OK:
			return _failed("citadel_packet_segment_digest_failed")
		var segment := {"segmentId":"citadel:%s:%s:%s" % [part_id,
			batch_key, String(source.get("segmentId", str(segment_key)))],
			"buffer":segment_copy, "bounds":source.bounds, "instanceCount":count,
			"contentDigest":digest.finish().hex_encode()}
		segment.make_read_only()
		segments.append(segment)
	segments.make_read_only()
	var group_digest := HashingContext.new()
	var group_payload: Array = [SCHEMA, source_id, part_id, census_revision,
		member_binding, String(group.sourceRevision), batch_key,
		String(group.get("packetSourceId", "")),
		int(group.get("packetGeneration", 0)), String(group.get("packetDigest", "")),
		String(mesh_fingerprint.contentDigest), material_fingerprint.digest,
		source_to_world]
	for segment: Dictionary in segments:
		group_payload.append([segment.segmentId, segment.contentDigest])
	if group_digest.start(HashingContext.HASH_SHA256) != OK \
			or group_digest.update(var_to_bytes(group_payload)) != OK:
		return _failed("citadel_packet_group_digest_failed")
	return {"status":"ready", "groupKey":batch_key,
		"contentDigest":group_digest.finish().hex_encode(),
		"compatibility":compatibility, "segments":segments,
		"ownerCell":Vector2i(group.ownerCell), "meshLocalBounds":mesh_bounds,
		"mesh":mesh, "material":material, "sourceToWorld":source_to_world,
		"packetSourceId":String(group.get("packetSourceId", "")),
		"materialDigest":material_fingerprint.digest}


static func _member_packet_digest(groups: Array[Dictionary]) -> String:
	var rows: Array = []
	for group: Dictionary in groups:
		rows.append([String(group.groupKey), String(group.contentDigest)])
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes(rows)) != OK:
		return ""
	return context.finish().hex_encode()


static func _packet_source_ids(groups: Array[Dictionary]) -> Array[String]:
	var result: Array[String] = []
	for group: Dictionary in groups:
		var source_id := String(group.get("packetSourceId", ""))
		if not source_id.is_empty() and source_id not in result:
			result.append(source_id)
	result.sort()
	return result


static func _member_id_from_census_source(source_id: String) -> String:
	var marker := ":member:"
	var start := source_id.find(marker)
	var end := source_id.find(":section:", start + marker.length())
	if end < 0:
		end = source_id.length()
	if start < 0 or end <= start + marker.length():
		return ""
	return source_id.substr(start + marker.length(), end - start - marker.length())


static func _site_id_from_census_source(source_id: String) -> String:
	if not source_id.begins_with("citadel:"):
		return ""
	var marker := source_id.find(":member:")
	return "" if marker <= "citadel:".length() else source_id.substr("citadel:".length(),
		marker - "citadel:".length())


static func _opaque_layer(material: Material) -> String:
	if material is StandardMaterial3D:
		var standard := material as StandardMaterial3D
		if standard.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED \
				and standard.albedo_color.a >= 0.999:
			return "opaque"
	return ""


static func _material_identity(material: Material) -> Dictionary:
	if not is_instance_valid(material):
		return {}
	var properties: Array = []
	for property: Dictionary in material.get_property_list():
		var name := String(property.get("name", ""))
		if name.is_empty() or name.begins_with("resource_") \
				or name in ["script", "resource_local_to_scene"]:
			continue
		var value: Variant = material.get(name)
		if value is Resource:
			# Resource paths identify references, not their current contents. This
			# adapter has no canonical texture/shader asset digest yet, so fail closed.
			return {}
		elif value is Object or value is Callable:
			return {}
		properties.append([name, value])
	properties.sort_custom(func(a: Array, b: Array) -> bool:
		return String(a[0]) < String(b[0]))
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes([material.get_class(), properties])) != OK:
		return {}
	return {"digest":context.finish().hex_encode()}


static func _render_policy(tier: String) -> Dictionary:
	match tier:
		"silhouette": return {"visibilityRangeEnd":360.0, "fadeMargin":24.0, "castShadows":true}
		"detail": return {"visibilityRangeEnd":140.0, "fadeMargin":14.0, "castShadows":false}
		"structural": return {"visibilityRangeEnd":240.0, "fadeMargin":18.0, "castShadows":true}
	return {}


static func _section_source_identity_key(source_id: String, source_part_id: String) -> String:
	if source_id.is_empty() or source_part_id.is_empty(): return ""
	return "section-part:" + var_to_bytes([source_id, source_part_id]).hex_encode()


static func _valid_transform(value: Transform3D) -> bool:
	return value.origin.is_finite() and value.basis.x.is_finite() \
		and value.basis.y.is_finite() and value.basis.z.is_finite()


static func _valid_bounds(value: AABB) -> bool:
	return value.position.is_finite() and value.size.is_finite() \
		and value.size.x > 0.0 and value.size.y > 0.0 \
		and value.size.z > 0.0 and value.end.is_finite()


static func _bounds_approx(a: AABB, b: AABB) -> bool:
	const EPSILON := 0.001
	return a.position.distance_to(b.position) <= EPSILON \
		and a.size.distance_to(b.size) <= EPSILON


static func _pending(reason: String, detail := {}) -> Dictionary:
	var result := {"status":"pending", "reason":reason, "retryable":true}
	result.merge(detail, true)
	return result


static func _failed(reason: String) -> Dictionary:
	return {"status":"failed", "reason":reason, "retryable":false}
