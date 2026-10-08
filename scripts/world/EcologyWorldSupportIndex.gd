extends RefCounted
class_name EcologyWorldSupportIndex

## Revisioned, value-only index from deterministic ecology producer domains to
## the render sections supported by their contributors. It owns no Nodes,
## Resources, gameplay state, or save data.

const QUERY_SCHEMA := "ecology-world-support-query/v1"
const CERTIFICATE_SCHEMA := "ecology-source-domain-coverage/v1"
const SOURCE_SCHEMA := "ecology-world-support-source/v1"
const INFLUENCE_POLICY_REVISION := "ecology-support-influence-policy/v1"
const OWNER_LEASE_SCHEMA := "ecology-support-owner-lease/v1"
const TREE_MEMBER_SUPPORT_POLICY := "tree-factory-support-envelope/v2"
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const ProducerDomain := preload("res://scripts/world/EcologyProducerDomain.gd")
const SOURCE_PUBLICATION_SECTION_BAND_SLICE_SCHEMA := \
	"ecology-source-publication-section-band-slice/v1"
const CompiledTreeArtifact := preload("res://scripts/world/CompiledTreeSectionArtifact.gd")
const STATIC_MEMBER_ENVELOPE_SCHEMA := ProducerDomain.STATIC_MEMBER_ENVELOPE_SCHEMA

var _world_id := ""
var _catalog_resolver: Object
var _world_epoch := -1
var _next_source_index_revision := 0
var _section_index_revision: Dictionary = {} # Vector3i -> monotonic section-local revision
var _domains: Dictionary = {} # Vector2i -> immutable completeness certificate
var _sources: Dictionary = {} # source ID -> current immutable row
var _postings_by_section: Dictionary = {} # Vector3i -> source ID -> immutable row
var _retired_postings_by_section: Dictionary = {} # retained tombstones pending receipt
var _required_domains_by_section: Dictionary = {} # Vector3i -> sorted Vector2i[]
var _required_families_by_section: Dictionary = {} # Vector3i -> family -> sorted Vector2i[]
var _family_domains: Dictionary = {} # Vector2i -> family -> immutable completeness receipt
var _family_band_receipts: Dictionary = {} # Vector2i -> family -> Vector3i -> immutable projection receipt
var _tree_source_family_band_authorities: Dictionary = {} # chunk -> section -> validated full producer/band authority
var _tree_section_geometry_overlays: Dictionary = {} # chunk -> section -> complete rendered section projection
var _retired_tree_section_overlays: Dictionary = {} # section -> old support rows retained through install acknowledgement
var _tree_overlay_publication_leases: Dictionary = {} # chunk -> section -> retained source publication lease/view
var _detached_tree_sections: Dictionary = {} # section -> retained until explicit native teardown receipt
var _latest_query_by_section: Dictionary = {}
var _receipt_by_section: Dictionary = {}
var _source_census_certificate_by_section: Dictionary = {}
var _catalog_domain_leases: Dictionary = {} # source chunk -> Main-thread lease row
var _catalog_census_leases: Dictionary = {} # section -> artifact ID -> Main-thread lease row
var _family_publication_leases: Dictionary = {} # source chunk -> family -> publication lease/view
var _band_expectation_call_count := 0
var _band_expectation_elapsed_usec := 0
var _band_domain_resolve_call_count := 0
var _band_domain_resolve_elapsed_usec := 0
var _band_owner_currentness_call_count := 0
var _band_owner_currentness_elapsed_usec := 0
var _band_local_currentness_call_count := 0
var _band_local_currentness_elapsed_usec := 0


func configure(world_id: String) -> Dictionary:
	if world_id.strip_edges().is_empty():
		return {"status":"failed", "reason":"ecology_support_index_world_invalid"}
	if not _world_id.is_empty() and _world_id != world_id:
		return {"status":"failed", "reason":"ecology_support_index_world_replaced"}
	if _world_id.is_empty():
		_world_id = world_id
	return {"status":"ready", "worldId":_world_id,
		"sourceIndexRevision":_next_source_index_revision}


func bind_catalog_artifact_resolver(resolver: Object, world_epoch: int) -> Dictionary:
	if not is_instance_valid(resolver) or world_epoch < 0 \
			or not resolver.has_method("acquire_ecology_catalog_artifact_lease") \
			or not resolver.has_method("resolve_ecology_catalog_artifact") \
			or not resolver.has_method("release_ecology_catalog_artifact_lease") \
			or not resolver.has_method("admit_ecology_source_publication") \
			or not resolver.has_method("acquire_ecology_source_publication") \
			or not resolver.has_method("resolve_ecology_source_publication") \
			or not resolver.has_method("ecology_source_publication_local_is_current") \
			or not resolver.has_method("ecology_source_publication_is_current") \
			or not resolver.has_method("resolve_ecology_source_publication_section_band_slice") \
			or not resolver.has_method("release_ecology_source_publication"):
		return {"status":"failed", "reason":"ecology_catalog_resolver_invalid"}
	if _catalog_resolver == resolver and _world_epoch == world_epoch:
		return {"status":"ready", "worldId":_world_id, "worldEpoch":_world_epoch}
	_release_all_catalog_leases()
	_catalog_resolver = resolver
	_world_epoch = world_epoch
	_domains.clear()
	_family_domains.clear()
	_family_band_receipts.clear()
	_release_tree_overlay_publication_leases()
	_tree_source_family_band_authorities.clear()
	_tree_section_geometry_overlays.clear()
	_retired_tree_section_overlays.clear()
	_detached_tree_sections.clear()
	_sources.clear()
	_postings_by_section.clear()
	_retired_postings_by_section.clear()
	_required_domains_by_section.clear()
	_required_families_by_section.clear()
	_family_domains.clear()
	_source_census_certificate_by_section.clear()
	_latest_query_by_section.clear()
	_receipt_by_section.clear()
	_section_index_revision.clear()
	_bump_all_index_revision()
	return {"status":"ready", "worldId":_world_id, "worldEpoch":_world_epoch}


## Declare the producer source domains that can influence a section. The caller
## must derive this complete set from the certified producer influence policy;
## an empty/missing set never implies empty world content.
func set_required_source_domains(section_key: Vector3i,
		source_chunk_keys: Array, census_certificate: Dictionary,
		keep_family_mapping := false) -> Dictionary:
	if not is_instance_valid(_catalog_resolver) or _world_epoch < 0:
		return {"status":"pending", "reason":"ecology_catalog_resolver_unbound"}
	if String(census_certificate.get("schema", "")).is_empty() \
			or String(census_certificate.get("status", "")) != "ready" \
			or census_certificate.get("sectionKey", null) != section_key:
		return {"status":"pending", "reason":"ecology_support_influence_census_unproven"}
	var keys: Array[Vector2i] = []
	for value: Variant in source_chunk_keys:
		if not value is Vector2i or value in keys:
			return {"status":"failed", "reason":"ecology_support_domain_key_invalid"}
		keys.append(value)
	keys.sort_custom(_chunk_less)
	var certified_keys: Variant = census_certificate.get("sourceChunkKeys", null)
	if not certified_keys is Array or certified_keys != keys:
		return {"status":"pending", "reason":"ecology_support_influence_census_mismatch"}
	var artifact_id := String(census_certificate.get("catalogArtifactId", ""))
	var content_digest := String(census_certificate.get("catalogContentDigest", ""))
	if artifact_id.is_empty() or content_digest.length() != 64:
		return {"status":"pending", "reason":"ecology_support_census_catalog_identity_missing"}
	var owner_key := _section_owner_key(section_key)
	var old_leases: Dictionary = _catalog_census_leases.get(section_key, {})
	var old_lease: Dictionary = old_leases.get(artifact_id, {})
	var acquired := _acquire_or_resolve_catalog_lease(artifact_id,
		"support_section_census", owner_key, content_digest,
		String(census_certificate.get("influencePolicyRevision", "")),
		String(census_certificate.get("influencePolicyDigest", "")), old_lease)
	if acquired.get("status") != "ready":
		return acquired
	var admitted_inputs: Variant = census_certificate.get("sourceInputs", null)
	if not admitted_inputs is Dictionary \
			or String(admitted_inputs.get("schema", "")) != "ecology-source-domain-inputs/v2" \
			or String(admitted_inputs.get("catalogArtifactId", "")) != artifact_id \
			or String(admitted_inputs.get("catalogContentDigest", "")) != content_digest \
			or int(admitted_inputs.get("worldEpoch", -1)) != _world_epoch:
		if not bool(acquired.get("reusedLease", false)):
			_release_catalog_lease(acquired.leaseToken)
		return {"status":"pending", "reason":"ecology_support_census_compact_inputs_invalid"}
	var expected_census := ProducerDomain.source_domain_census_certificate(section_key,
		admitted_inputs, acquired.artifact)
	if not ProducerDomain.validate_source_domain_census_certificate(
			census_certificate, section_key, {}, acquired.artifact):
		if not bool(acquired.get("reusedLease", false)):
			_release_catalog_lease(acquired.leaseToken)
		return {"status":"pending", "reason":"ecology_support_census_certificate_invalid"}
	for field: String in ["influencePolicyRevision", "influencePolicyDigest",
			"sourceChunkSizeMeters", "sourceOriginDomainFootprintMeters",
			"maxHorizontalSupportMeters", "sourceChunkKeysDigest"]:
		if census_certificate.get(field, null) != expected_census.get(field, null):
			if not bool(acquired.get("reusedLease", false)):
				_release_catalog_lease(acquired.leaseToken)
			return {"status":"pending", "reason":"ecology_support_census_policy_mismatch"}
	if expected_census.get("sourceChunkKeys", []) != keys:
		if not bool(acquired.get("reusedLease", false)):
			_release_catalog_lease(acquired.leaseToken)
		return {"status":"pending", "reason":"ecology_support_census_domain_mismatch"}
	if census_certificate.get("sourceChunkKeysByFamily", null) \
			!= expected_census.get("sourceChunkKeysByFamily", null):
		if not bool(acquired.get("reusedLease", false)):
			_release_catalog_lease(acquired.leaseToken)
		return {"status":"pending", "reason":"ecology_support_family_census_mismatch"}
	var new_section_leases: Dictionary = {}
	new_section_leases[artifact_id] = {"leaseToken":acquired.leaseToken,
		"catalogArtifactId":artifact_id, "catalogContentDigest":content_digest,
		"worldEpoch":_world_epoch}
	for old_id_value: Variant in old_leases.keys():
		var old_id := String(old_id_value)
		if old_id != artifact_id:
			_release_catalog_lease(String((old_leases[old_id] as Dictionary).get("leaseToken", "")))
	_catalog_census_leases[section_key] = new_section_leases
	if _required_domains_by_section.get(section_key, []) != keys:
		_required_domains_by_section[section_key] = keys.duplicate()
		_source_census_certificate_by_section[section_key] = _compact_census_certificate(census_certificate)
		_bump_section_revision(section_key)
		_latest_query_by_section.erase(section_key)
	elif _source_census_certificate_by_section.get(section_key, {}) != \
			_compact_census_certificate(census_certificate):
		_source_census_certificate_by_section[section_key] = _compact_census_certificate(census_certificate)
		_bump_section_revision(section_key)
	if not keep_family_mapping and _required_families_by_section.has(section_key):
		_required_families_by_section.erase(section_key)
		_bump_section_revision(section_key)
	_retire_unreferenced_domains()
	return {"status":"ready", "sectionKey":section_key,
		"sourceDomains":keys.duplicate(), "sourceIndexRevision":_section_revision(section_key)}


## Declare exact producer-owner closures per content family. The shared union is
## retained for compatibility and residency accounting, while query readiness
## proves every family/key pair independently; an absent family result cannot be
## interpreted as an empty family.
func set_required_source_domains_by_family(section_key: Vector3i,
		source_chunk_keys_by_family: Dictionary, census_certificate: Dictionary) -> Dictionary:
	var family_map: Dictionary = {}
	var union_keys: Dictionary = {}
	for family_value: Variant in ProducerDomain.REQUIRED_CATEGORIES:
		var family := String(family_value)
		var values: Variant = source_chunk_keys_by_family.get(family, null)
		if not values is Array:
			return {"status":"pending", "reason":"ecology_family_source_closure_missing",
				"family":family}
		var keys: Array[Vector2i] = []
		for key_value: Variant in values:
			if not key_value is Vector2i or key_value in keys:
				return {"status":"failed", "reason":"ecology_family_source_key_invalid",
					"family":family}
			keys.append(key_value)
			union_keys[key_value] = true
		keys.sort_custom(_chunk_less)
		family_map[family] = keys
	if source_chunk_keys_by_family.size() != family_map.size() \
			or source_chunk_keys_by_family != census_certificate.get(
				"sourceChunkKeysByFamily", null):
		return {"status":"pending", "reason":"ecology_family_source_closure_certificate_mismatch"}
	var union: Array[Vector2i] = []
	for key_value: Variant in union_keys:
		union.append(Vector2i(key_value))
	union.sort_custom(_chunk_less)
	var declared: Dictionary = set_required_source_domains(section_key, union,
		census_certificate, true)
	if String(declared.get("status", "")) != "ready":
		return declared
	var previous: Dictionary = _required_families_by_section.get(section_key, {})
	if previous != family_map:
		_required_families_by_section[section_key] = family_map
		_bump_section_revision(section_key)
	return {"status":"ready", "sectionKey":section_key,
		"sourceDomains":union.duplicate(),
		"sourceChunkKeysByFamily":family_map.duplicate(true),
		"sourceIndexRevision":_section_revision(section_key)}


## Publish rows derived from an independently sealed deterministic source
## snapshot. Runtime gameplay Node identity is deliberately not source authority.
func publish_source_domain(world_id: String, source_chunk_key: Vector2i,
		snapshot: Dictionary, rows: Array) -> Dictionary:
	if world_id != _world_id or not is_instance_valid(_catalog_resolver):
		return {"status":"pending", "reason":"ecology_catalog_resolver_unbound"}
	var source_inputs: Variant = snapshot.get("sourceInputs", null)
	if not source_inputs is Dictionary:
		return {"status":"pending", "reason":"ecology_source_compact_inputs_missing"}
	var artifact_id := String(source_inputs.get("catalogArtifactId", ""))
	var content_digest := String(source_inputs.get("catalogContentDigest", ""))
	var world_epoch := int(source_inputs.get("worldEpoch", -1))
	if artifact_id.is_empty() or content_digest.length() != 64 or world_epoch != _world_epoch:
		return {"status":"pending", "reason":"ecology_source_catalog_identity_stale"}
	var existing: Dictionary = _catalog_domain_leases.get(source_chunk_key, {})
	var acquired := _acquire_or_resolve_catalog_lease(artifact_id, "support_domain",
		_domain_owner_key(world_id, source_chunk_key), content_digest,
		String(source_inputs.get("influencePolicyRevision", "")),
		String(source_inputs.get("influencePolicyDigest", "")), existing)
	if acquired.get("status") != "ready":
		return acquired
	var result := _publish_source_domain_resolved(world_id, source_chunk_key,
		snapshot, rows, acquired.supportPolicy, acquired.artifact)
	if result.get("status") == "ready":
		var old_token := String(existing.get("leaseToken", ""))
		if not bool(result.get("changed", false)) and not bool(acquired.get("reusedLease", false)):
			var old_domain: Dictionary = _domains.get(source_chunk_key, {}).duplicate()
			old_domain["sourceInputs"] = source_inputs.duplicate()
			old_domain["sourceInputs"].make_read_only()
			old_domain.make_read_only()
			_domains[source_chunk_key] = old_domain
		if not bool(acquired.get("reusedLease", false)) or existing.is_empty():
			_catalog_domain_leases[source_chunk_key] = {"leaseToken":acquired.leaseToken,
				"catalogArtifactId":artifact_id, "catalogContentDigest":content_digest,
				"worldEpoch":_world_epoch}
		if not old_token.is_empty() and old_token != String(acquired.leaseToken):
			_release_catalog_lease(old_token)
	else:
		if not bool(acquired.get("reusedLease", false)):
			_release_catalog_lease(String(acquired.get("leaseToken", "")))
	return result


## Atomically replace only the requested family rows. Unrequested family receipts
## and postings remain current; a missing row can never be treated as an empty
## result because the producer bundle validator requires explicit completion.
func publish_source_domain_family_bundle(world_id: String,
		source_chunk_key: Vector2i, bundle: Dictionary,
		rows_by_family: Dictionary, publication_view: Dictionary = {},
		caller_publication_lease_token := "") -> Dictionary:
	var requested: Variant = bundle.get("requestedFamilies", null)
	if not requested is Array:
		return {"status":"pending", "reason":"ecology_source_family_bundle_identity_missing"}
	return _publish_source_domain_family_selected(world_id, source_chunk_key,
		bundle, rows_by_family, publication_view, caller_publication_lease_token,
		requested, false)


## Publish only selected support-index families from an already admitted full
## producer publication. The bundle/view remain the full immutable capture; this
## projection never creates a second publication or narrows tree authority.
func publish_source_domain_family_projection(world_id: String,
		source_chunk_key: Vector2i, bundle: Dictionary,
		rows_by_family: Dictionary, publication_view: Dictionary,
		caller_publication_lease_token: String,
		selected_families: Array) -> Dictionary:
	if publication_view.is_empty() or caller_publication_lease_token.is_empty():
		return {"status":"pending", "reason":"ecology_source_family_projection_requires_admitted_view"}
	return _publish_source_domain_family_selected(world_id, source_chunk_key,
		bundle, rows_by_family, publication_view, caller_publication_lease_token,
		selected_families, true)


func _publish_source_domain_family_selected(world_id: String,
		source_chunk_key: Vector2i, bundle: Dictionary,
		rows_by_family: Dictionary, publication_view: Dictionary,
		caller_publication_lease_token: String, selected_families: Array,
		require_existing_view: bool) -> Dictionary:
	if world_id != _world_id or not is_instance_valid(_catalog_resolver):
		return {"status":"pending", "reason":"ecology_catalog_resolver_unbound"}
	var source_inputs: Variant = bundle.get("sourceInputs", null)
	var bundle_families_value: Variant = bundle.get("requestedFamilies", null)
	if not source_inputs is Dictionary or not bundle_families_value is Array:
		return {"status":"pending", "reason":"ecology_source_family_bundle_identity_missing"}
	var bundle_families: Array[String] = []
	for family_value: Variant in bundle_families_value:
		var family := String(family_value)
		if family not in ProducerDomain.REQUIRED_CATEGORIES or family in bundle_families:
			return {"status":"pending", "reason":"ecology_source_family_bundle_request_invalid"}
		bundle_families.append(family)
	bundle_families.sort()
	var requested: Array[String] = []
	for family_value: Variant in selected_families:
		var family := String(family_value)
		if family not in ProducerDomain.REQUIRED_CATEGORIES or family in requested:
			return {"status":"pending", "reason":"ecology_source_family_selection_invalid",
				"family":family}
		if family not in bundle_families:
			return {"status":"pending", "reason":"ecology_source_family_selection_unrelated",
				"family":family}
		requested.append(family)
	requested.sort()
	if requested.is_empty() or rows_by_family.size() != requested.size():
		return {"status":"pending", "reason":"ecology_source_family_rows_missing"}
	for family_value: Variant in rows_by_family:
		if String(family_value) not in requested:
			return {"status":"pending", "reason":"ecology_source_family_rows_unselected",
				"family":String(family_value)}
	for family: String in requested:
		if not rows_by_family.has(family) or not rows_by_family[family] is Array:
			return {"status":"pending", "reason":"ecology_source_family_rows_missing",
				"family":family}
	var artifact_id := String(source_inputs.get("catalogArtifactId", ""))
	var content_digest := String(source_inputs.get("catalogContentDigest", ""))
	var world_epoch := int(source_inputs.get("worldEpoch", -1))
	if artifact_id.is_empty() or content_digest.length() != 64 or world_epoch != _world_epoch:
		return {"status":"pending", "reason":"ecology_source_family_bundle_invalid"}
	if require_existing_view and (publication_view.is_empty() \
			or caller_publication_lease_token.is_empty()):
		return {"status":"pending", "reason":"ecology_source_family_projection_requires_admitted_view"}
	var admission := _resolve_family_publication_view(world_id, source_chunk_key,
		bundle, publication_view, caller_publication_lease_token, requested)
	if String(admission.get("status", "")) != "ready":
		return admission
	var admitted_view: Dictionary = admission.get("view", {})
	var temporary_admission_token := String(admission.get("temporaryAdmissionToken", ""))
	var reject_cleanup := {"temporaryAdmissionToken":temporary_admission_token}
	var runtime_policy: Dictionary = admitted_view.get("supportPolicy", {})
	var source_revision := String(bundle.get("sourceRevision", ""))
	var removed_projection_digest := String(bundle.get("removedSourceProjectionDigest", ""))
	var source_manifest_revision := String(bundle.get("sourceManifestDigest", ""))
	var terrain_revision := String(bundle.get("terrainVolumeChunkRevision",
		source_inputs.get("terrainVolumeChunkRevision", "")))
	var structure_revision := String(bundle.get("structureAdmissionRevision",
		source_inputs.get("structureAdmissionRevision", "")))
	var structure_status := String(bundle.get("structureAdmissionStatus",
		source_inputs.get("structureAdmissionStatus", "")))
	var influence_revision := String(bundle.get("influencePolicyRevision", ""))
	var influence_digest := String(bundle.get("influencePolicyDigest", ""))
	if source_revision.is_empty() or removed_projection_digest.length() != 64 \
			or source_manifest_revision.length() != 64 or terrain_revision.is_empty() \
			or structure_revision.is_empty() or structure_status not in ["ready", "complete"] \
			or String(runtime_policy.get("revision", "")) != influence_revision \
			or String(runtime_policy.get("digest", "")) != influence_digest:
		return _family_publish_reject(reject_cleanup,
			"ecology_source_family_bundle_provenance_invalid")
	# Validate every requested row set before changing any family posting.
	var prepared_by_family: Dictionary = {}
	var domain_by_family: Dictionary = {}
	var member_family_by_key: Dictionary = {}
	for family: String in requested:
		var family_result: Dictionary = admitted_view.get(
			"familyResultsById", {}).get(family, {})
		if String(family_result.get("status", "")) != "ready" \
				or String(family_result.get("disposition", "")) \
				not in ["complete_nonempty", "complete_empty"]:
			return _family_publish_reject(reject_cleanup,
				"ecology_source_family_result_incomplete", {"family":family,
				"disposition":String(family_result.get("disposition", ""))})
		var producer_sources: Dictionary = admitted_view.get("sourceIdsByFamily", {}).get(
			family, {})
		var family_revision := String(family_result.get("familyRevision", ""))
		var family_policy_revision := String(family_result.get("familyPolicyRevision", ""))
		var family_policy_digest := String(family_result.get("familyPolicyDigest", ""))
		var family_manifest_digest := String(family_result.get("sourceManifestDigest", ""))
		var prepared_rows: Array[Dictionary] = []
		var represented_sources: Dictionary = {}
		var seen_member_rows: Dictionary = {}
		var stable_tuples: Array = []
		for row_value: Variant in rows_by_family[family]:
			if not row_value is Dictionary or String(row_value.get("family", "")) != family:
				return _family_publish_reject(reject_cleanup,
					"ecology_source_family_row_invalid", {"family":family})
			var row: Dictionary = row_value
			if String(row.get("producerSnapshotRevision", "")) != family_revision \
					or String(row.get("familyRevision", "")) != family_revision \
					or String(row.get("familyPolicyRevision", "")) != family_policy_revision \
					or String(row.get("familyPolicyDigest", "")) != family_policy_digest \
					or String(row.get("familyManifestDigest", "")) != family_manifest_digest:
				return _family_publish_reject(reject_cleanup,
					"ecology_source_family_row_provenance_mismatch", {"family":family,
					"sourceId":String(row.get("sourceId", ""))})
			var source_id := String(row.get("sourceId", ""))
			if not producer_sources.has(source_id):
				return _family_publish_reject(reject_cleanup,
					"ecology_source_family_row_not_in_producer_result", {
					"family":family, "sourceId":source_id})
			represented_sources[source_id] = true
			var validated := _validate_source_row(row, world_id, source_chunk_key,
				source_revision, runtime_policy)
			if String(validated.get("status", "")) != "ready":
				return _family_publish_propagate(reject_cleanup, validated)
			var accepted: Dictionary = validated.row.duplicate(true)
			var accepted_member_key := _row_key(accepted)
			if accepted_member_key.is_empty() or seen_member_rows.has(accepted_member_key):
				return _family_publish_reject(reject_cleanup,
					"ecology_source_family_row_duplicate", {"family":family,
					"sourceId":source_id, "sourcePartId":String(accepted.get("sourcePartId", ""))})
			seen_member_rows[accepted_member_key] = true
			accepted["familyRevision"] = String(family_result.get("familyRevision", ""))
			accepted["familyPolicyRevision"] = String(family_result.get("familyPolicyRevision", ""))
			accepted["familyPolicyDigest"] = String(family_result.get("familyPolicyDigest", ""))
			accepted["familyManifestDigest"] = String(family_result.get("sourceManifestDigest", ""))
			accepted["catalogArtifactId"] = artifact_id
			accepted["catalogContentDigest"] = content_digest
			accepted["publicationOwnerReceiptDigest"] = _owner_receipt_digest(
				admitted_view.get("ownerReceipt", {}))
			accepted["worldEpoch"] = world_epoch
			accepted["sourceDomainRevision"] = source_revision
			accepted["terrainVolumeChunkRevision"] = terrain_revision
			accepted["structureAdmissionRevision"] = structure_revision
			accepted["removedSourceProjectionDigest"] = removed_projection_digest
			accepted["influencePolicyRevision"] = influence_revision
			accepted["influencePolicyDigest"] = influence_digest
			if String(accepted.familyRevision).length() != 64 \
					or String(accepted.familyPolicyDigest).length() != 64:
				return _family_publish_reject(reject_cleanup,
					"ecology_source_family_identity_invalid", {"family":family})
			var member_key := _row_key(accepted)
			if member_family_by_key.has(member_key) \
					and String(member_family_by_key[member_key]) != family:
				return _family_publish_reject(reject_cleanup,
					"ecology_source_family_member_identity_collision",
					{"family":family, "sourceId":String(accepted.get("sourceId", "")),
					"sourcePartId":String(accepted.get("sourcePartId", ""))})
			member_family_by_key[member_key] = family
			accepted.make_read_only()
			prepared_rows.append(accepted)
			stable_tuples.append(_stable_source_tuple(accepted))
		if represented_sources.size() != producer_sources.size():
			return _family_publish_reject(reject_cleanup,
				"ecology_source_family_without_support_row", {"family":family,
				"producerSourceCount":producer_sources.size(),
				"supportSourceCount":represented_sources.size()})
		stable_tuples.sort_custom(_source_tuple_less)
		var support_digest := _sha256_bytes(var_to_bytes([
			"ecology-family-support-manifest/v1", source_chunk_key, family,
			source_revision, family_revision, stable_tuples]))
		if support_digest.is_empty():
			return _family_publish_reject(reject_cleanup,
				"ecology_family_support_manifest_digest_failed", {}, "failed")
		var family_domain := {"sourceChunkKey":source_chunk_key,
			"worldId":world_id, "family":family, "sourceRevision":source_revision,
			"familyRevision":family_revision,
			"familyPolicyRevision":String(family_result.get("familyPolicyRevision", "")),
			"familyPolicyDigest":String(family_result.get("familyPolicyDigest", "")),
			"disposition":String(family_result.get("disposition", "")), "complete":true,
			"memberCount":int(family_result.get("memberCount", -1)),
			"producerSnapshotRevision":family_revision,
			"producerComplete":true, "enumeratedSourceCount":int(
				family_result.get("memberCount", -1)),
			"categoriesComplete":[family],
			"removedPropsRevision":String(bundle.get("removedPropsRevision", "")),
			"sourceManifestDigest":String(family_result.get("sourceManifestDigest", "")),
			"supportManifestDigest":support_digest,
			"terrainVolumeChunkRevision":terrain_revision,
			"structureAdmissionRevision":structure_revision,
			"structureAdmissionStatus":structure_status,
			"removedSourceProjectionDigest":removed_projection_digest,
			"influencePolicyRevision":influence_revision,
			"influencePolicyDigest":influence_digest,
			"catalogArtifactId":artifact_id, "catalogContentDigest":content_digest,
			"worldEpoch":world_epoch, "sourceInputs":source_inputs,
			"publicationId":String(admitted_view.get("publicationId", "")),
			"publicationContentDigest":String(admitted_view.get("contentDigest", "")),
			"ownerReceipt":admitted_view.get("ownerReceipt", {}),
			"ownerReceiptDigest":_owner_receipt_digest(admitted_view.get("ownerReceipt", {}))}
		family_domain.make_read_only()
		prepared_by_family[family] = prepared_rows
		domain_by_family[family] = family_domain
	for existing_row_value: Variant in _sources.values():
		if not existing_row_value is Dictionary \
				or Vector2i(existing_row_value.get("sourceChunkKey", Vector2i.ZERO)) \
				!= source_chunk_key:
			continue
		var existing_family := String(existing_row_value.get("family", ""))
		var new_family: String = String(member_family_by_key.get(_row_key(existing_row_value), ""))
		if not new_family.is_empty() and existing_family != new_family \
				and existing_family not in requested:
			return _family_publish_reject(reject_cleanup,
				"ecology_source_family_member_identity_collision", {
				"family":new_family, "existingFamily":existing_family,
				"sourceId":String(existing_row_value.get("sourceId", "")),
				"sourcePartId":String(existing_row_value.get("sourcePartId", ""))})
	var family_lease_rows: Dictionary = _family_publication_leases.get(
		source_chunk_key, {}).duplicate()
	var acquired_family_leases: Dictionary = {}
	var family_unchanged: Dictionary = {}
	for family: String in requested:
		var next_domain: Dictionary = domain_by_family[family]
		var prepared_rows: Array = prepared_by_family[family]
		var old_domain: Dictionary = _family_domains.get(source_chunk_key, {}).get(family, {})
		var old_family_lease: Dictionary = family_lease_rows.get(family, {})
		var old_rows_for_family: Array[Dictionary] = _source_rows_for_chunk_family(
			source_chunk_key, family)
		var next_tuples: Array = []
		for row: Dictionary in prepared_rows:
			next_tuples.append(_stable_source_tuple(row))
		next_tuples.sort_custom(_source_tuple_less)
		var old_tuples: Array = []
		for row: Dictionary in old_rows_for_family:
			old_tuples.append(_stable_source_tuple(row))
		old_tuples.sort_custom(_source_tuple_less)
		var unchanged := String(old_domain.get("familyRevision", "")) == \
			String(next_domain.get("familyRevision", "")) \
			and String(old_domain.get("supportManifestDigest", "")) == \
			String(next_domain.get("supportManifestDigest", "")) \
			and String(old_domain.get("catalogArtifactId", "")) == artifact_id \
			and String(old_domain.get("catalogContentDigest", "")) == content_digest \
			and String(old_domain.get("ownerReceiptDigest", "")) == \
			String(next_domain.get("ownerReceiptDigest", "")) \
			and int(old_domain.get("worldEpoch", -1)) == world_epoch \
			and _family_domain_owner_current(old_domain, old_family_lease) \
			and old_tuples == next_tuples
		family_unchanged[family] = unchanged
		if unchanged:
			continue
		var lease_result := _acquire_family_publication_lease(
			String(admitted_view.get("publicationId", "")), world_id,
			world_epoch, source_chunk_key, family, admitted_view)
		if String(lease_result.get("status", "")) != "ready":
			for acquired_value: Variant in acquired_family_leases.values():
				if acquired_value is Dictionary:
					_release_source_publication_lease(String(
						acquired_value.get("leaseToken", "")))
			return _family_publish_reject(reject_cleanup,
				String(lease_result.get("reason", "ecology_source_publication_lease_pending")),
				{"family":family}, String(lease_result.get("status", "pending")))
		acquired_family_leases[family] = lease_result
	# All family results are now sealed and valid; replace them in one synchronous
	# publication transaction while retaining superseded rows as tombstones.
	var affected_sections: Dictionary = {}
	for family: String in requested:
		var prepared_rows: Array = prepared_by_family[family]
		var old_domain: Dictionary = _family_domains.get(source_chunk_key, {}).get(family, {})
		var next_domain: Dictionary = domain_by_family[family]
		var new_tuples: Array = []
		for row: Dictionary in prepared_rows: new_tuples.append(_stable_source_tuple(row))
		new_tuples.sort_custom(_source_tuple_less)
		var old_rows: Array[Dictionary] = _source_rows_for_chunk_family(
			source_chunk_key, family)
		var old_tuples: Array = []
		for row: Dictionary in old_rows: old_tuples.append(_stable_source_tuple(row))
		old_tuples.sort_custom(_source_tuple_less)
		if bool(family_unchanged.get(family, false)):
			continue
		# A changed family result must invalidate only sections whose exact family
		# closure includes this source chunk. Unchanged family publication is a true
		# no-op and must not stale a certificate captured moments earlier.
		for required_section_value: Variant in _required_families_by_section:
			if not required_section_value is Vector3i:
				continue
			var required_by_family: Dictionary = _required_families_by_section[
				required_section_value]
			var required_chunks: Array = required_by_family.get(family, [])
			if source_chunk_key in required_chunks:
				affected_sections[required_section_value] = true
		var new_by_key: Dictionary = {}
		for row: Dictionary in prepared_rows: new_by_key[_row_key(row)] = row
		for old_row: Dictionary in old_rows:
			var row_key := _row_key(old_row)
			var replacement: Variant = new_by_key.get(row_key, null)
			if replacement is Dictionary and _stable_source_tuple(old_row) == _stable_source_tuple(replacement):
				new_by_key.erase(row_key)
				continue
			if replacement is Dictionary and _same_source_content_ignoring_catalog_artifact(
					old_row, replacement):
				# The source geometry and semantic revisions are unchanged, but its
				# catalog owner receipt has rotated. Rebind the current row and every
				# live posting to the newly validated proof without retiring the visible
				# member. The changed owner lease token still requires a fresh section
				# acceptance before the new proof is current.
				_sources[row_key] = replacement
				for section_value: Variant in old_row.get("supportSectionKeys", []):
					if not section_value is Vector3i:
						continue
					var postings: Dictionary = _postings_by_section.get(section_value, {})
					postings[row_key] = replacement
					affected_sections[section_value] = true
				new_by_key.erase(row_key)
				continue
			for section_value: Variant in old_row.get("supportSectionKeys", []):
				if section_value is Vector3i: affected_sections[section_value] = true
			_retire_source_to_tombstone(row_key, old_row, source_revision)
			_sources.erase(row_key)
		for new_row_key: String in new_by_key:
			var new_row: Dictionary = new_by_key[new_row_key]
			_sources[new_row_key] = new_row
			_post_row(new_row)
			for section_value: Variant in new_row.get("supportSectionKeys", []):
				if section_value is Vector3i: affected_sections[section_value] = true
		var family_map: Dictionary = _family_domains.get(source_chunk_key, {})
		family_map[family] = next_domain
		_family_domains[source_chunk_key] = family_map
	for family: String in acquired_family_leases:
		var old_lease_row: Dictionary = family_lease_rows.get(family, {})
		var new_lease_row: Dictionary = acquired_family_leases[family]
		family_lease_rows[family] = new_lease_row
		var old_publication_token := String(old_lease_row.get("leaseToken", ""))
		if not old_publication_token.is_empty() and old_publication_token != \
				String(new_lease_row.get("leaseToken", "")):
			_release_source_publication_lease(old_publication_token)
	if not family_lease_rows.is_empty():
		_family_publication_leases[source_chunk_key] = family_lease_rows
	_release_source_publication_lease(temporary_admission_token)
	_bump_sections(affected_sections)
	return {"status":"ready", "sourceChunkKey":source_chunk_key,
		"requestedFamilies":requested, "changedSections":_sorted_sections(affected_sections),
		"sourceIndexRevision":_next_source_index_revision}


## Return the support-index projection proof for one family in one exact 3D
## output section. The canonical source-family rows remain whole and unchanged.
func expected_source_family_section_band_projection(world_id: String,
		source_chunk_key: Vector2i, section_key: Vector3i, family: String) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	var result: Dictionary
	if world_id != _world_id or family not in ProducerDomain.REQUIRED_CATEGORIES:
		result = {"status":"pending", "reason":"ecology_band_expectation_identity_invalid"}
	else:
		var domain: Variant = _family_domains.get(source_chunk_key, {}).get(family, null)
		var currentness: Dictionary = {}
		if not domain is Dictionary or not _valid_family_domain(domain, source_chunk_key,
				family, currentness):
			result = {"status":"pending", "reason":"ecology_support_source_family_incomplete",
				"sourceChunkKey":source_chunk_key, "sectionKey":section_key, "family":family}
		else:
			result = _expected_source_family_section_band_projection(source_chunk_key,
				section_key, family, domain)
	_band_expectation_call_count += 1
	_band_expectation_elapsed_usec += Time.get_ticks_usec() - started_usec
	return result


func source_band_registration_profile_snapshot() -> Dictionary:
	return {"schema":"ecology-source-band-registration-profile/v1",
		"expectationCallCount":_band_expectation_call_count,
		"expectationElapsedUsec":_band_expectation_elapsed_usec,
		"domainPublicationResolveCallCount":_band_domain_resolve_call_count,
		"domainPublicationResolveElapsedUsec":_band_domain_resolve_elapsed_usec,
		"ownerCurrentnessCallCount":_band_owner_currentness_call_count,
		"ownerCurrentnessElapsedUsec":_band_owner_currentness_elapsed_usec,
		"localCurrentnessCallCount":_band_local_currentness_call_count,
		"localCurrentnessElapsedUsec":_band_local_currentness_elapsed_usec}


func _expected_source_family_section_band_projection(source_chunk_key: Vector2i,
		section_key: Vector3i, family: String, domain: Dictionary) -> Dictionary:
	var projected_rows := _source_family_rows_for_section(source_chunk_key, family, section_key)
	var source_ids := _source_ids_for_rows(projected_rows)
	var all_rows := _source_rows_for_chunk_family(source_chunk_key, family)
	var full_source_ids := _source_ids_for_rows(all_rows)
	var support_digest := _source_family_support_projection_digest(domain,
		section_key, projected_rows)
	if support_digest.is_empty():
		return {"status":"pending", "reason":"ecology_band_support_digest_failed",
			"sourceChunkKey":source_chunk_key, "sectionKey":section_key, "family":family}
	return {"status":"ready", "sourceChunkKey":source_chunk_key,
		"sectionKey":section_key, "bandBounds":ProducerDomain.section_bounds(section_key),
		"family":family,
		"sourceFamilyRevision":String(domain.get("familyRevision", "")),
		"sourceFamilyManifestDigest":String(domain.get("sourceManifestDigest", "")),
		"sourceDomainRevision":String(domain.get("sourceRevision", "")),
		"familyPolicyRevision":String(domain.get("familyPolicyRevision", "")),
		"familyPolicyDigest":String(domain.get("familyPolicyDigest", "")),
		"catalogArtifactId":String(domain.get("catalogArtifactId", "")),
		"catalogContentDigest":String(domain.get("catalogContentDigest", "")),
		"worldEpoch":int(domain.get("worldEpoch", -1)),
		"removedSourceProjectionDigest":String(domain.get("removedSourceProjectionDigest", "")),
		"expectedSourceIds":source_ids,
		"expectedSourceIdsDigest":ProducerDomain._digest(source_ids),
		"sourceFamilyIdsDigest":ProducerDomain._digest(full_source_ids),
		"sourceFamilySourceIdCount":full_source_ids.size(),
		"sourceFamilyMemberRowCount":int(domain.get("memberCount", full_source_ids.size())),
		"sourceFamilyMemberCount":int(domain.get("memberCount", full_source_ids.size())),
		"expectedSupportMemberDigest":support_digest,
		"expectedSupportMemberCount":projected_rows.size()}


## Validate and store the producer's band projection without replacing the
## canonical full-family row store. The snapshot must be an immutable sealed
## capture; its full source and per-family revisions are checked against the
## currently admitted index proofs. A call is atomic across included families.
func register_source_family_section_band_projection(world_id: String,
		source_chunk_key: Vector2i, section_key: Vector3i,
		source_snapshot: Dictionary, projected_bundle: Dictionary,
		selected_families: Array = [], publication_view: Dictionary = {},
		publication_lease_token := "") -> Dictionary:
	var owner_slice_authorized := false
	var source_band_bundle: Dictionary = projected_bundle
	if String(projected_bundle.get("schema", "")) == \
			SOURCE_PUBLICATION_SECTION_BAND_SLICE_SCHEMA:
		if publication_view.is_empty() or publication_lease_token.is_empty() \
				or not is_same(publication_view.get("payload", null), source_snapshot) \
				or not is_instance_valid(_catalog_resolver) \
				or not _catalog_resolver.has_method(
				"resolve_ecology_source_publication_section_band_slice"):
			return {"status":"pending", "reason":"ecology_band_slice_owner_resolver_unavailable"}
		var owner_result: Variant = _catalog_resolver.call(
			"resolve_ecology_source_publication_section_band_slice",
			publication_view, publication_lease_token, section_key, projected_bundle)
		if not owner_result is Dictionary or String(owner_result.get("status", "")) != "ready" \
				or not is_same(owner_result.get("slice", null), projected_bundle):
			return owner_result if owner_result is Dictionary else {
				"status":"pending", "reason":"ecology_band_slice_owner_result_invalid"}
		var bundle_value: Variant = projected_bundle.get("bundle", null)
		if not bundle_value is Dictionary or not bundle_value.is_read_only():
			return {"status":"pending", "reason":"ecology_band_slice_bundle_unsealed"}
		source_band_bundle = bundle_value
		owner_slice_authorized = true
	if world_id != _world_id or String(projected_bundle.get("schema", "")) \
			!= (SOURCE_PUBLICATION_SECTION_BAND_SLICE_SCHEMA if owner_slice_authorized \
			else ProducerDomain.FAMILY_BAND_BUNDLE_SCHEMA) \
			or String(source_band_bundle.get("status", "")) != "ready" \
			or source_band_bundle.get("worldId", null) != world_id \
			or source_band_bundle.get("sourceChunkKey", null) != source_chunk_key \
			or source_band_bundle.get("bandKey", null) != section_key \
			or source_band_bundle.get("bandBounds", null) != ProducerDomain.section_bounds(section_key):
		return {"status":"pending", "reason":"ecology_band_projection_identity_invalid",
			"sourceChunkKey":source_chunk_key, "sectionKey":section_key}
	var families_value: Variant = source_band_bundle.get("requestedFamilies", null)
	var coverage_value: Variant = source_band_bundle.get("familyCoverage", null)
	if not families_value is Array or families_value.is_empty() \
			or not coverage_value is Array \
			or coverage_value.size() != families_value.size() \
			or coverage_value.size() > ProducerDomain.REQUIRED_CATEGORIES.size():
		return {"status":"pending", "reason":"ecology_band_projection_family_manifest_invalid"}
	var families: Array[String] = []
	for family_value: Variant in families_value:
		var family := String(family_value)
		if family not in ProducerDomain.REQUIRED_CATEGORIES or family in families:
			return {"status":"pending", "reason":"ecology_band_projection_family_invalid",
				"family":family}
		families.append(family)
	families.sort()
	var selected: Array[String] = []
	if selected_families.is_empty():
		selected = families.duplicate()
	else:
		for family_value: Variant in selected_families:
			var family := String(family_value)
			if family not in ProducerDomain.REQUIRED_CATEGORIES or family in selected:
				return {"status":"pending", "reason":"ecology_band_projection_selection_invalid",
					"family":family}
			if family not in families:
				return {"status":"pending", "reason":"ecology_band_projection_selection_unrelated",
					"family":family}
			selected.append(family)
		selected.sort()
		if selected.is_empty():
			return {"status":"pending", "reason":"ecology_band_projection_selection_empty"}
	var artifact_id := String(source_band_bundle.get("catalogArtifactId", ""))
	var catalog_lease: Dictionary = _catalog_resolver.call(
		"acquire_ecology_catalog_artifact_lease", artifact_id,
		"support_index_band_projection", _domain_owner_key(world_id, source_chunk_key),
		world_id, _world_epoch)
	if String(catalog_lease.get("status", "")) != "ready": return catalog_lease
	var artifact_token := String(catalog_lease.get("leaseToken", ""))
	var artifact_result: Variant = _catalog_resolver.call(
		"resolve_ecology_catalog_artifact", artifact_token, world_id, _world_epoch)
	var artifact: Dictionary = artifact_result.get("artifact", {}) \
		if artifact_result is Dictionary and String(artifact_result.get("status", "")) == "ready" else {}
	if artifact.is_empty() or (not owner_slice_authorized and \
			not ProducerDomain.validate_source_domain_family_bundle(
				source_snapshot, world_id, source_chunk_key, artifact)) \
			or (not owner_slice_authorized and \
				not ProducerDomain.validate_source_domain_family_band_bundle(
					source_band_bundle, source_snapshot, section_key,
					ProducerDomain.section_bounds(section_key), artifact)):
		_catalog_resolver.call("release_ecology_catalog_artifact_lease", artifact_token)
		return {"status":"pending", "reason":"ecology_band_projection_provenance_invalid",
			"sourceChunkKey":source_chunk_key, "sectionKey":section_key}
	var prepared: Dictionary = {}
	for family: String in selected:
		var expected := expected_source_family_section_band_projection(world_id,
			source_chunk_key, section_key, family)
		if String(expected.get("status", "")) != "ready":
			_catalog_resolver.call("release_ecology_catalog_artifact_lease", artifact_token)
			return expected
		var band: Dictionary = _band_family_receipt(coverage_value, family)
		var producer_rows: Variant = band.get("sourceRows", [])
		var source_ids := _source_ids_for_rows(producer_rows if producer_rows is Array else [])
		var canonical_family: Dictionary = publication_view.get("familyResultsById", {}).get(
			family, {}) if owner_slice_authorized else \
			ProducerDomain.source_family_result(source_snapshot, family, artifact)
		var domain: Dictionary = _family_domains[source_chunk_key][family]
		if not _source_snapshot_family_matches_current(source_snapshot, domain,
				family, canonical_family) \
				or not _band_family_matches_expected(band, expected, source_ids, canonical_family):
			_catalog_resolver.call("release_ecology_catalog_artifact_lease", artifact_token)
			return {"status":"pending", "reason":"ecology_band_projection_family_mismatch",
				"sourceChunkKey":source_chunk_key, "sectionKey":section_key, "family":family}
		var receipt := _build_band_receipt(world_id, source_chunk_key,
			section_key, family, expected, band, source_ids, domain, source_band_bundle)
		receipt.make_read_only()
		prepared[family] = receipt
	_catalog_resolver.call("release_ecology_catalog_artifact_lease", artifact_token)
	var changed := false
	for family: String in selected:
		if not _family_band_receipts.has(source_chunk_key): _family_band_receipts[source_chunk_key] = {}
		var family_receipts: Dictionary = _family_band_receipts[source_chunk_key]
		if not family_receipts.has(family): family_receipts[family] = {}
		var by_section: Dictionary = family_receipts[family]
		if by_section.get(section_key, null) == prepared[family]: continue
		by_section[section_key] = prepared[family]
		changed = true
	if changed: _bump_section_revision(section_key)
	return {"status":"ready", "sourceChunkKey":source_chunk_key,
		"sectionKey":section_key, "families":selected, "changed":changed,
		"sourceIndexRevision":_section_revision(section_key)}


## Admit the complete producer tree-family proof for one exact section before
## geometry compilation. This is separate from `_family_domains` and `_sources`:
## it certifies source identity/coverage only and cannot stand in for rendered
## members or authorize a candidate until a complete geometry overlay exists.
func admit_tree_source_family_section_band(world_id: String,
		source_chunk_key: Vector2i, section_key: Vector3i,
		source_snapshot: Dictionary, projected_bundle: Dictionary,
		publication_view: Dictionary, publication_lease_token: String) -> Dictionary:
	var owner_slice_authorized := false
	var source_band_bundle: Dictionary = projected_bundle
	if String(projected_bundle.get("schema", "")) == \
			SOURCE_PUBLICATION_SECTION_BAND_SLICE_SCHEMA:
		var owner_result: Variant = _catalog_resolver.call(
			"resolve_ecology_source_publication_section_band_slice",
			publication_view, publication_lease_token, section_key, projected_bundle) \
			if is_instance_valid(_catalog_resolver) and _catalog_resolver.has_method(
				"resolve_ecology_source_publication_section_band_slice") else null
		if not owner_result is Dictionary or String(owner_result.get("status", "")) != "ready" \
				or not is_same(owner_result.get("slice", null), projected_bundle):
			return owner_result if owner_result is Dictionary else {
				"status":"pending", "reason":"tree_band_slice_owner_resolver_unavailable"}
		var bundle_value: Variant = projected_bundle.get("bundle", null)
		if not bundle_value is Dictionary or not bundle_value.is_read_only():
			return {"status":"pending", "reason":"tree_band_slice_bundle_unsealed"}
		source_band_bundle = bundle_value
		owner_slice_authorized = true
	if world_id != _world_id or source_snapshot.get("status", "") != "ready" \
			or source_snapshot.get("sourceChunkKey", null) != source_chunk_key \
			or String(projected_bundle.get("schema", "")) != ( \
				SOURCE_PUBLICATION_SECTION_BAND_SLICE_SCHEMA if owner_slice_authorized \
				else ProducerDomain.FAMILY_BAND_BUNDLE_SCHEMA) \
			or source_band_bundle.get("status", "") != "ready" \
			or source_band_bundle.get("worldId", null) != world_id \
			or source_band_bundle.get("sourceChunkKey", null) != source_chunk_key \
			or source_band_bundle.get("bandKey", null) != section_key \
			or source_band_bundle.get("bandBounds", null) != ProducerDomain.section_bounds(section_key):
		return {"status":"pending", "reason":"tree_band_authority_identity_invalid"}
	if not is_instance_valid(_catalog_resolver) or publication_view.is_empty() \
			or publication_lease_token.is_empty() \
			or not is_same(publication_view.get("payload", null), source_snapshot):
		return {"status":"pending", "reason":"tree_band_authority_publication_missing"}
	var current: Variant = _catalog_resolver.call(
		"ecology_source_publication_local_is_current", publication_view,
		publication_lease_token)
	if not current is Dictionary or String(current.get("status", "")) != "ready":
		return current if current is Dictionary else {"status":"pending",
			"reason":"tree_band_authority_currentness_unavailable"}
	var requested: Variant = source_band_bundle.get("requestedFamilies", null)
	var coverage: Variant = source_band_bundle.get("familyCoverage", null)
	if not requested is Array or "trees" not in requested \
			or not coverage is Array:
		return {"status":"pending", "reason":"tree_band_authority_tree_receipt_missing"}
	var tree_band := _band_family_receipt(coverage, "trees")
	var tree_source_ids := _source_ids_for_rows(tree_band.get("sourceRows", []))
	# The owner-slice branch above has already resolved the exact retained band
	# alias from this admitted publication. The checks below compare its selected
	# source IDs and family manifest with the index's current local support proof.
	# Direct legacy callers still pass the full source and band validators above.
	var inputs: Variant = source_snapshot.get("sourceInputs", null)
	if not inputs is Dictionary:
		return {"status":"pending", "reason":"tree_band_authority_source_inputs_missing"}
	var artifact_lease: Dictionary = _catalog_resolver.call(
		"acquire_ecology_catalog_artifact_lease",
		String(source_snapshot.get("catalogArtifactId", "")),
		"tree_section_band_authority", _domain_owner_key(world_id, source_chunk_key),
		world_id, _world_epoch)
	if String(artifact_lease.get("status", "")) != "ready": return artifact_lease
	var artifact_token := String(artifact_lease.get("leaseToken", ""))
	var resolved: Variant = _catalog_resolver.call("resolve_ecology_catalog_artifact",
		artifact_token, world_id, _world_epoch)
	var artifact: Dictionary = resolved.get("artifact", {}) \
		if resolved is Dictionary and String(resolved.get("status", "")) == "ready" else {}
	if artifact.is_empty() or (not owner_slice_authorized and \
			not ProducerDomain.validate_source_domain_family_bundle(
				source_snapshot, world_id, source_chunk_key, artifact)) \
			or (not owner_slice_authorized and \
				not ProducerDomain.validate_source_domain_family_band_bundle(
					source_band_bundle, source_snapshot, section_key,
					ProducerDomain.section_bounds(section_key), artifact)):
		_catalog_resolver.call("release_ecology_catalog_artifact_lease", artifact_token)
		return {"status":"pending", "reason":"tree_band_authority_projection_invalid"}
	var canonical_tree: Dictionary = publication_view.get("familyResultsById", {}).get(
		"trees", {}) if owner_slice_authorized else \
		ProducerDomain.source_family_result(source_snapshot, "trees", artifact)
	var canonical_ids := _source_ids_for_rows(canonical_tree.get("sourceRows", []))
	if String(canonical_tree.get("status", "")) != "ready" \
			or canonical_tree.get("sourceRows", []) != publication_view.get(
			"familyResultsById", {}).get("trees", {}).get("sourceRows", []) \
			or tree_source_ids != _source_ids_for_rows(tree_band.get("sourceRows", [])):
		_catalog_resolver.call("release_ecology_catalog_artifact_lease", artifact_token)
		return {"status":"pending", "reason":"tree_band_authority_family_rows_mismatch"}
	var publication_alias_index := _tree_publication_member_alias_index(publication_view)
	if String(publication_alias_index.get("status", "")) != "ready":
		_catalog_resolver.call("release_ecology_catalog_artifact_lease", artifact_token)
		return publication_alias_index
	var aliases_by_key: Dictionary = publication_alias_index.get("rowsByKey", {})
	for source_row_value: Variant in canonical_tree.get("sourceRows", []):
		if not source_row_value is Dictionary:
			_catalog_resolver.call("release_ecology_catalog_artifact_lease", artifact_token)
			return {"status":"pending", "reason":"tree_band_authority_source_row_invalid"}
		var source_row: Dictionary = source_row_value
		var alias_result := _tree_publication_member_alias_for_family_row(
			aliases_by_key, source_row)
		if String(alias_result.get("status", "")) != "ready":
			_catalog_resolver.call("release_ecology_catalog_artifact_lease", artifact_token)
			return alias_result
		var publication_row: Dictionary = alias_result.get("row", {})
		var source_current: Variant = _catalog_resolver.call(
			"ecology_source_publication_record_is_current", publication_view,
			publication_lease_token, publication_row) \
			if _catalog_resolver.has_method("ecology_source_publication_record_is_current") else null
		if not source_current is Dictionary or String(source_current.get("status", "")) != "ready":
			_catalog_resolver.call("release_ecology_catalog_artifact_lease", artifact_token)
			return source_current if source_current is Dictionary else {"status":"pending",
				"reason":"tree_band_authority_record_currentness_unavailable"}
	var retained: Variant = _catalog_resolver.call("acquire_ecology_source_publication",
		String(publication_view.get("publicationId", "")),
		"tree_section_geometry_overlay", _domain_owner_key(world_id, source_chunk_key) \
			+ "|" + str(section_key))
	_catalog_resolver.call("release_ecology_catalog_artifact_lease", artifact_token)
	if not retained is Dictionary or String(retained.get("status", "")) != "ready":
		return retained if retained is Dictionary else {"status":"pending",
			"reason":"tree_band_authority_lease_unavailable"}
	var retained_token := String(retained.get("leaseToken", ""))
	var retained_view: Dictionary = retained.get("view", {})
	if retained_token.is_empty() or retained_view.is_empty() \
			or not is_same(retained_view, publication_view):
		if not retained_token.is_empty():
			_catalog_resolver.call("release_ecology_source_publication", retained_token)
		return {"status":"pending", "reason":"tree_band_authority_lease_view_mismatch"}
	var authority := {"schema":"ecology-tree-source-family-band-authority/v1",
		"worldId":world_id, "worldEpoch":_world_epoch, "family":"trees",
		"sourceChunkKey":source_chunk_key, "sectionKey":section_key,
		"bandBounds":ProducerDomain.section_bounds(section_key),
		"sourcePublicationId":String(publication_view.get("publicationId", "")),
		"sourcePublicationContentDigest":String(publication_view.get("contentDigest", "")),
		"publicationOwnerReceiptDigest":_owner_receipt_digest(publication_view.get("ownerReceipt", {})),
		"sourceRevision":String(source_snapshot.get("sourceRevision", "")),
		"sourceManifestDigest":String(source_snapshot.get("sourceManifestDigest", "")),
		"sourceFamilyRevision":String(canonical_tree.get("familyRevision", "")),
		"sourceFamilyManifestDigest":String(canonical_tree.get("sourceManifestDigest", "")),
		"familyPolicyRevision":String(canonical_tree.get("familyPolicyRevision", "")),
		"familyPolicyDigest":String(canonical_tree.get("familyPolicyDigest", "")),
		"catalogArtifactId":String(source_snapshot.get("catalogArtifactId", "")),
		"catalogContentDigest":String(source_snapshot.get("catalogContentDigest", "")),
		"terrainVolumeChunkRevision":String(source_snapshot.get("terrainVolumeChunkRevision", "")),
		"structureAdmissionRevision":String(source_snapshot.get("structureAdmissionRevision", "")),
		"structureAdmissionStatus":String(source_snapshot.get("structureAdmissionStatus", "")),
		"removedSourceProjectionDigest":String(source_snapshot.get("removedSourceProjectionDigest", "")),
		"influencePolicyRevision":String(source_snapshot.get("influencePolicyRevision", "")),
		"influencePolicyDigest":String(source_snapshot.get("influencePolicyDigest", "")),
		"producerBandManifestDigest":String(tree_band.get("sourceManifestDigest", "")),
		"producerBandRevision":String(tree_band.get("familyRevision", "")),
		"producerSourceIds":tree_source_ids,
		"producerSourceIdsDigest":ProducerDomain._digest(tree_source_ids),
		"sourceFamilySourceIds":canonical_ids,
		"sourceFamilySourceIdsDigest":ProducerDomain._digest(canonical_ids),
		"sourceFamilySourceIdCount":canonical_ids.size(),
		"producerSnapshotRevision":String(canonical_tree.get("familyRevision", "")),
		"producerDisposition":String(tree_band.get("disposition", "")),
		"sourceBundleDigest":String(source_band_bundle.get("sourceBundleDigest", "")),
		"publicationLeaseToken":retained_token}
	var authority_identity: Dictionary = authority.duplicate(true)
	# Lease tokens are per acquisition and must not rotate semantic authority.
	authority_identity.erase("publicationLeaseToken")
	var authority_digest := _sha256_bytes(var_to_bytes(authority_identity))
	if authority_digest.is_empty():
		_catalog_resolver.call("release_ecology_source_publication", retained_token)
		return {"status":"failed", "reason":"tree_band_authority_digest_failed"}
	authority["authorityDigest"] = authority_digest
	_deep_freeze(authority)
	var by_chunk: Dictionary = _tree_source_family_band_authorities.get(source_chunk_key, {})
	var prior: Dictionary = by_chunk.get(section_key, {})
	var retired_lease_tokens: Array = []
	if not prior.is_empty() and String(prior.get("authorityDigest", "")) == authority_digest:
		var prior_lease: Dictionary = _tree_overlay_publication_leases.get(
			source_chunk_key, {}).get(section_key, {})
		var prior_token := String(prior_lease.get("leaseToken", ""))
		if retained_token != prior_token:
			_catalog_resolver.call("release_ecology_source_publication", retained_token)
		return {"status":"ready", "authority":prior, "changed":false}
	if not prior.is_empty():
		var old_overlay: Dictionary = _tree_section_geometry_overlays.get(source_chunk_key, {}).get(section_key, {})
		if not old_overlay.is_empty():
			var retired_rows: Array = _retired_tree_section_overlays.get(section_key, [])
			for row_value: Variant in old_overlay.get("supportRows", []):
				if row_value is Dictionary:
					retired_rows.append(_tree_overlay_row_as_tombstone(row_value,
						String(authority_digest)))
			_retired_tree_section_overlays[section_key] = retired_rows
			_tree_section_geometry_overlays[source_chunk_key].erase(section_key)
			var lease_rows: Dictionary = _tree_overlay_publication_leases.get(source_chunk_key, {})
			var old_lease: Dictionary = lease_rows.get(section_key, {})
			retired_lease_tokens = old_lease.get("retiredLeaseTokens", []).duplicate()
			if not String(old_lease.get("leaseToken", "")).is_empty():
				retired_lease_tokens.append(String(old_lease.leaseToken))
	by_chunk[section_key] = authority
	_tree_source_family_band_authorities[source_chunk_key] = by_chunk
	var leases: Dictionary = _tree_overlay_publication_leases.get(source_chunk_key, {})
	var lease_record := {"leaseToken":retained_token, "view":retained_view,
		"retiredLeaseTokens":retired_lease_tokens}
	leases[section_key] = lease_record
	_tree_overlay_publication_leases[source_chunk_key] = leases
	_bump_section_revision(section_key)
	return {"status":"ready", "authority":authority, "changed":true,
		"expectedSourceIds":tree_source_ids}


## Atomically attach one exact section's compiled tree output to its matching
## producer-band authority. Source-level completeness is checked independently
## from owner member and support reference completeness.
func register_tree_section_geometry_overlay(world_id: String,
		source_chunk_key: Vector2i, section_key: Vector3i,
		projected_source_ids: Array, compiled_artifact: Dictionary,
		support_rows: Array) -> Dictionary:
	var authority: Dictionary = _tree_source_family_band_authorities.get(
		source_chunk_key, {}).get(section_key, {})
	var lease: Dictionary = _tree_overlay_publication_leases.get(
		source_chunk_key, {}).get(section_key, {})
	if not _tree_band_authority_current(authority, lease, world_id,
		source_chunk_key, section_key):
		return {"status":"pending", "reason":"tree_section_overlay_authority_stale"}
	var expected_ids: Array = authority.get("producerSourceIds", [])
	var ids := projected_source_ids.duplicate()
	ids.sort()
	if ids != expected_ids or not compiled_artifact.is_read_only() \
			or String(compiled_artifact.get("schema", "")) != CompiledTreeArtifact.SCHEMA \
			or String(compiled_artifact.get("worldId", "")) != world_id \
			or compiled_artifact.get("sourceChunkKey", null) != source_chunk_key \
			or compiled_artifact.get("sectionKey", null) != section_key \
			or String(compiled_artifact.get("authorityDigest", "")) != String(authority.get("authorityDigest", "")) \
			or String(compiled_artifact.get("sourceRevision", "")) != String(authority.get("sourceRevision", "")) \
			or String(compiled_artifact.get("treeFamilyRevision", "")) != String(authority.get("sourceFamilyRevision", "")) \
			or String(compiled_artifact.get("treeFamilyManifestDigest", "")) != String(authority.get("sourceFamilyManifestDigest", "")):
		return {"status":"pending", "reason":"tree_section_overlay_compile_identity_mismatch"}
	var compiled_ids: Array[String] = []
	for source_value: Variant in compiled_artifact.get("sources", []):
		if not source_value is Dictionary:
			return {"status":"pending", "reason":"tree_section_overlay_source_manifest_invalid"}
		var source_id := String(source_value.get("sourceId", ""))
		if source_id.is_empty() or source_id in compiled_ids:
			return {"status":"pending", "reason":"tree_section_overlay_source_manifest_duplicate"}
		compiled_ids.append(source_id)
	compiled_ids.sort()
	if compiled_ids != expected_ids:
		return {"status":"pending", "reason":"tree_section_overlay_source_completeness_pending",
			"expectedSourceCount":expected_ids.size(), "compiledSourceCount":compiled_ids.size()}
	var artifact_match := _tree_overlay_artifact_matches_rows(compiled_artifact,
		section_key, support_rows)
	if String(artifact_match.get("status", "")) != "ready":
		return artifact_match
	var prepared_rows: Array[Dictionary] = []
	var owner_member_keys: Dictionary = {}
	var support_member_keys: Dictionary = {}
	for row_value: Variant in support_rows:
		if not row_value is Dictionary:
			return {"status":"pending", "reason":"tree_section_overlay_support_row_invalid"}
		var row: Dictionary = row_value.duplicate(true)
		var source_id := String(row.get("sourceId", ""))
		var member_id := String(row.get("sourcePartId", ""))
		var bounds: Variant = row.get("conservativeWorldBounds", null)
		var owner: Variant = row.get("geometryOwnerSection", null)
		var supports: Variant = row.get("conservativeSupportSectionKeys", null)
		if source_id not in expected_ids or member_id.is_empty() or not bounds is AABB \
				or not owner is Vector3i or not supports is Array \
				or section_key not in supports \
				or owner != Grid.key_for_world_position((bounds as AABB).get_center()):
			return {"status":"pending", "reason":"tree_section_overlay_member_ownership_invalid",
				"sourceId":source_id, "sourcePartId":member_id}
		var member_key := _row_key(row)
		if support_member_keys.has(member_key):
			return {"status":"pending", "reason":"tree_section_overlay_member_duplicate"}
		support_member_keys[member_key] = true
		if owner == section_key:
			owner_member_keys[member_key] = true
		row["sourceChunkKey"] = source_chunk_key
		row["sourceDomainRevision"] = String(authority.get("sourceRevision", ""))
		row["family"] = "trees"
		row["familyRevision"] = String(authority.get("sourceFamilyRevision", ""))
		row["familyPolicyRevision"] = String(authority.get("familyPolicyRevision", ""))
		row["familyPolicyDigest"] = String(authority.get("familyPolicyDigest", ""))
		row["familyManifestDigest"] = String(authority.get("sourceFamilyManifestDigest", ""))
		row["catalogArtifactId"] = String(authority.get("catalogArtifactId", ""))
		row["catalogContentDigest"] = String(authority.get("catalogContentDigest", ""))
		row["worldEpoch"] = int(authority.get("worldEpoch", -1))
		row["terrainVolumeChunkRevision"] = String(authority.get("terrainVolumeChunkRevision", ""))
		row["structureAdmissionRevision"] = String(authority.get("structureAdmissionRevision", ""))
		row["removedSourceProjectionDigest"] = String(authority.get("removedSourceProjectionDigest", ""))
		row["influencePolicyRevision"] = String(authority.get("influencePolicyRevision", ""))
		row["influencePolicyDigest"] = String(authority.get("influencePolicyDigest", ""))
		row["state"] = "compiled"
		row["overlayAuthorityDigest"] = String(authority.get("authorityDigest", ""))
		var runtime_policy: Dictionary = lease.get("view", {}).get("supportPolicy", {})
		var validated_row := _validate_source_row(row, world_id, source_chunk_key,
			String(authority.get("sourceRevision", "")), runtime_policy)
		if String(validated_row.get("status", "")) != "ready":
			return validated_row
		row = validated_row.get("row", {}).duplicate(true)
		row["supportSectionKeys"] = row.get("conservativeSupportSectionKeys", []).duplicate()
		row["familyRevision"] = String(authority.get("sourceFamilyRevision", ""))
		row["familyPolicyRevision"] = String(authority.get("familyPolicyRevision", ""))
		row["familyPolicyDigest"] = String(authority.get("familyPolicyDigest", ""))
		row["familyManifestDigest"] = String(authority.get("sourceFamilyManifestDigest", ""))
		row["catalogArtifactId"] = String(authority.get("catalogArtifactId", ""))
		row["catalogContentDigest"] = String(authority.get("catalogContentDigest", ""))
		row["worldEpoch"] = int(authority.get("worldEpoch", -1))
		row["publicationOwnerReceiptDigest"] = String(authority.get(
			"publicationOwnerReceiptDigest", ""))
		row["producerSnapshotRevision"] = String(authority.get("producerSnapshotRevision", ""))
		row["terrainVolumeChunkRevision"] = String(authority.get("terrainVolumeChunkRevision", ""))
		row["structureAdmissionRevision"] = String(authority.get("structureAdmissionRevision", ""))
		row["removedSourceProjectionDigest"] = String(authority.get("removedSourceProjectionDigest", ""))
		row["influencePolicyRevision"] = String(authority.get("influencePolicyRevision", ""))
		row["influencePolicyDigest"] = String(authority.get("influencePolicyDigest", ""))
		row.make_read_only()
		prepared_rows.append(row)
	var expected_member_ids := _sorted_overlay_member_keys(support_member_keys)
	var owner_member_ids := _sorted_overlay_member_keys(owner_member_keys)
	prepared_rows.sort_custom(_row_less)
	var geometry_tuples: Array = []
	for prepared_row: Dictionary in prepared_rows:
		geometry_tuples.append(_stable_source_tuple(prepared_row))
	var compiled_artifact_digest := String(artifact_match.get("compiledArtifactDigest", ""))
	var compiled_batch_digest := String(artifact_match.get("compiledBatchDigest", ""))
	var source_completion_digest := String(artifact_match.get("sourceCompletionDigest", ""))
	var owner_batch_payload_digest := String(artifact_match.get("ownerBatchPayloadDigest", ""))
	var resource_binding_digest := String(artifact_match.get("resourceBindingDigest", ""))
	var support_digest := _sha256_bytes(var_to_bytes(["tree-section-geometry-overlay/v1",
		world_id, source_chunk_key, section_key,
		String(authority.get("authorityDigest", "")), expected_ids, geometry_tuples,
		compiled_artifact_digest, compiled_batch_digest, source_completion_digest,
		owner_batch_payload_digest, resource_binding_digest]))
	var owner_digest := _sha256_bytes(var_to_bytes(owner_member_ids))
	var support_member_digest := _sha256_bytes(var_to_bytes(expected_member_ids))
	if support_digest.is_empty() or owner_digest.is_empty() or support_member_digest.is_empty():
		return {"status":"failed", "reason":"tree_section_overlay_digest_failed"}
	var overlay := {"schema":"ecology-tree-section-geometry-overlay/v1",
		"worldId":world_id, "worldEpoch":int(authority.get("worldEpoch", -1)),
		"sourceChunkKey":source_chunk_key, "sectionKey":section_key,
		"authorityDigest":String(authority.get("authorityDigest", "")),
		"sourceRevision":String(authority.get("sourceRevision", "")),
		"sourceFamilyRevision":String(authority.get("sourceFamilyRevision", "")),
		"sourceFamilyManifestDigest":String(authority.get("sourceFamilyManifestDigest", "")),
		"producerBandManifestDigest":String(authority.get("producerBandManifestDigest", "")),
		"producerSourceIds":expected_ids,
		"producerSourceIdsDigest":String(authority.get("producerSourceIdsDigest", "")),
		"sourceCompletionCount":compiled_ids.size(),
		"compiledArtifactDigest":compiled_artifact_digest,
		"compiledBatchDigest":compiled_batch_digest,
		"sourceCompletionDigest":source_completion_digest,
		"ownerBatchPayloadDigest":owner_batch_payload_digest,
		"resourceBindingDigest":resource_binding_digest,
		"ownerMemberIds":owner_member_ids, "ownerMemberCount":owner_member_ids.size(),
		"ownerMemberDigest":owner_digest,
		"supportMemberIds":expected_member_ids, "supportMemberCount":expected_member_ids.size(),
		"supportMemberDigest":support_member_digest,
		"disposition":"complete_empty" if owner_member_ids.is_empty() \
			else "complete_nonempty",
		"supportDisposition":"support_empty" if expected_member_ids.is_empty() \
			else ("support_only" if owner_member_ids.is_empty() else "support_nonempty"),
		"geometryDigest":support_digest, "supportRows":prepared_rows}
	_deep_freeze(overlay)
	var prior: Dictionary = _tree_section_geometry_overlays.get(source_chunk_key, {}).get(section_key, {})
	if not prior.is_empty() \
			and String(prior.get("authorityDigest", "")) == String(overlay.get("authorityDigest", "")) \
			and String(prior.get("geometryDigest", "")) == String(overlay.get("geometryDigest", "")) \
			and String(prior.get("ownerMemberDigest", "")) == String(overlay.get("ownerMemberDigest", "")) \
			and String(prior.get("supportMemberDigest", "")) == String(overlay.get("supportMemberDigest", "")):
		return {"status":"ready", "overlay":prior, "changed":false,
			"sourceIndexRevision":_section_revision(section_key)}
	if not prior.is_empty():
		var retired: Array = _retired_tree_section_overlays.get(section_key, [])
		for old_row_value: Variant in prior.get("supportRows", []):
			if old_row_value is Dictionary:
				retired.append(_tree_overlay_row_as_tombstone(old_row_value,
					String(overlay.get("geometryDigest", ""))))
		_retired_tree_section_overlays[section_key] = retired
	var chunk_overlays: Dictionary = _tree_section_geometry_overlays.get(source_chunk_key, {})
	chunk_overlays[section_key] = overlay
	_tree_section_geometry_overlays[source_chunk_key] = chunk_overlays
	_bump_section_revision(section_key)
	return {"status":"ready", "overlay":overlay,
		"sourceCompletionCount":compiled_ids.size(),
		"ownerMemberCount":owner_member_ids.size(),
		"supportMemberCount":expected_member_ids.size(),
		"sourceIndexRevision":_section_revision(section_key)}


func _sorted_overlay_member_keys(keys: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for key_value: Variant in keys:
		result.append(String(key_value))
	result.sort()
	return result


func _tree_overlay_artifact_matches_rows(artifact: Dictionary,
		section_key: Vector3i, rows: Array) -> Dictionary:
	var sources_value: Variant = artifact.get("sources", null)
	var expected_source_ids_value: Variant = artifact.get("expectedSourceIds", null)
	var completion_value: Variant = artifact.get("sourceCompletionManifest", null)
	var batches_value: Variant = artifact.get("batches", null)
	var owner_payload_value: Variant = artifact.get("ownerBatchContributors", null)
	var resource_bindings_value: Variant = artifact.get("resourceBindings", null)
	if not sources_value is Array or not expected_source_ids_value is Array \
			or not completion_value is Array or not batches_value is Array \
			or not owner_payload_value is Array or not resource_bindings_value is Dictionary \
			or not sources_value.is_read_only() or not expected_source_ids_value.is_read_only() \
			or not completion_value.is_read_only() or not batches_value.is_read_only() \
			or not owner_payload_value.is_read_only() or not resource_bindings_value.is_read_only():
		return {"status":"pending", "reason":"tree_overlay_artifact_completion_proof_missing"}
	var sources: Array = sources_value
	var expected_source_ids: Array[String] = []
	var source_by_id: Dictionary = {}
	for source_value: Variant in sources:
		if not source_value is Dictionary or not source_value.is_read_only():
			return {"status":"pending", "reason":"tree_overlay_artifact_source_invalid"}
		var source: Dictionary = source_value
		var source_id := String(source.get("sourceId", ""))
		if source_id.is_empty() or source_by_id.has(source_id) \
				or not source.get("geometryOwnership", null) is Array \
				or not source.get("geometryOwnership", []).is_read_only():
			return {"status":"pending", "reason":"tree_overlay_artifact_source_manifest_missing"}
		expected_source_ids.append(source_id)
		source_by_id[source_id] = source
	expected_source_ids.sort()
	var declared_source_ids: Array = expected_source_ids_value.duplicate()
	declared_source_ids.sort()
	if declared_source_ids != expected_source_ids:
		return {"status":"pending", "reason":"tree_overlay_artifact_source_completion_identity_mismatch"}
	var source_artifact_digests_value: Variant = artifact.get("sourceArtifactDigests", null)
	if not source_artifact_digests_value is Array \
			or not source_artifact_digests_value.is_read_only() \
			or source_artifact_digests_value.size() != expected_source_ids.size():
		return {"status":"pending", "reason":"tree_overlay_artifact_source_geometry_digest_set_missing"}
	for source_index: int in range(expected_source_ids.size()):
		var source_digest_row_value: Variant = source_artifact_digests_value[source_index]
		var expected_source_id := expected_source_ids[source_index]
		if not source_digest_row_value is Dictionary \
				or not source_digest_row_value.is_read_only() \
				or String(source_digest_row_value.get("sourceId", "")) != expected_source_id \
				or String(source_digest_row_value.get("sourceRecordDigest", "")) \
				!= String(source_by_id.get(expected_source_id, {}).get("sourceRecordDigest", "")) \
				or String(source_digest_row_value.get("sourceArtifactDigest", "")).length() != 64:
			return {"status":"pending", "reason":"tree_overlay_artifact_source_geometry_digest_identity_mismatch",
				"sourceId":expected_source_id}
	var completion_by_id: Dictionary = {}
	for completion_value_entry: Variant in completion_value:
		if not completion_value_entry is Dictionary or not completion_value_entry.is_read_only():
			return {"status":"pending", "reason":"tree_overlay_artifact_completion_manifest_invalid"}
		var completion: Dictionary = completion_value_entry
		var source_id := String(completion.get("sourceId", ""))
		if source_id.is_empty() or completion_by_id.has(source_id) \
				or not source_by_id.has(source_id) \
				or String(completion.get("completionState", "")) != "complete":
			return {"status":"pending", "reason":"tree_overlay_artifact_source_completion_incomplete"}
		var source: Dictionary = source_by_id[source_id]
		if String(completion.get("sourceRecordDigest", "")) != String(source.get("sourceRecordDigest", "")) \
				or String(completion.get("recipeArtifactRevision", "")) != String(source.get("recipeArtifactRevision", "")) \
				or String(completion.get("recipeSignature", "")) != String(source.get("recipeSignature", "")):
			return {"status":"pending", "reason":"tree_overlay_artifact_completion_provenance_mismatch"}
		var owner_ids: Array[String] = []
		var support_ids: Array[String] = []
		for member_value: Variant in source.get("geometryOwnership", []):
			if not member_value is Dictionary:
				return {"status":"pending", "reason":"tree_overlay_artifact_owner_manifest_invalid"}
			var member: Dictionary = member_value
			var member_id := String(member.get("memberId", ""))
			var owner: Variant = member.get("ownedSectionKey",
				member.get("geometryOwnerSectionKey", null))
			var supports: Variant = member.get("supportSectionKeys", null)
			if member_id.is_empty() or not owner is Vector3i or not supports is Array:
				return {"status":"pending", "reason":"tree_overlay_artifact_owner_identity_invalid"}
			if owner not in supports:
				return {"status":"pending", "reason":"tree_overlay_artifact_geometry_owner_not_supported"}
			if owner == section_key: owner_ids.append(member_id)
			if section_key in supports: support_ids.append(member_id)
		owner_ids.sort()
		support_ids.sort()
		if completion.get("ownerMemberIds", null) != owner_ids \
				or int(completion.get("ownerMemberCount", -1)) != owner_ids.size() \
				or String(completion.get("ownerMemberDigest", "")) != _sha256_bytes(var_to_bytes(owner_ids)) \
				or completion.get("supportMemberIds", null) != support_ids \
				or int(completion.get("supportMemberCount", -1)) != support_ids.size() \
				or String(completion.get("supportMemberDigest", "")) != _sha256_bytes(var_to_bytes(support_ids)):
			return {"status":"pending", "reason":"tree_overlay_artifact_member_completion_mismatch"}
		completion_by_id[source_id] = completion
	if completion_by_id.size() != expected_source_ids.size():
		return {"status":"pending", "reason":"tree_overlay_artifact_source_completion_manifest_incomplete",
			"expected":expected_source_ids.size(), "actual":completion_by_id.size()}
	var source_completion_digest := _sha256_bytes(var_to_bytes(completion_value))
	if source_completion_digest.is_empty() \
			or String(artifact.get("sourceCompletionDigest", "")) != source_completion_digest:
		return {"status":"pending", "reason":"tree_overlay_artifact_completion_digest_mismatch"}
	var expected: Dictionary = {}
	var expected_owners: Dictionary = {}
	for source_value: Variant in sources:
		var source: Dictionary = source_value
		var source_id := String(source.get("sourceId", ""))
		for member_value: Variant in source.get("geometryOwnership", null):
			if not member_value is Dictionary:
				return {"status":"pending", "reason":"tree_overlay_artifact_owner_manifest_invalid"}
			var member: Dictionary = member_value
			var member_id := String(member.get("memberId", ""))
			var owner: Variant = member.get("ownedSectionKey",
				member.get("geometryOwnerSectionKey", null))
			var supports: Variant = member.get("supportSectionKeys", null)
			var bounds: Variant = member.get("conservativeWorldBounds", null)
			if source_id.is_empty() or member_id.is_empty() or not owner is Vector3i \
					or not supports is Array or not bounds is AABB:
				return {"status":"pending", "reason":"tree_overlay_artifact_owner_identity_invalid"}
			if owner not in supports:
				return {"status":"pending", "reason":"tree_overlay_artifact_geometry_owner_not_supported"}
			if owner == section_key: expected_owners[_source_part_identity_key(source_id, member_id)] = true
			if section_key not in supports:
				continue
			var identity := _source_part_identity_key(source_id, member_id)
			if identity.is_empty() or expected.has(identity):
				return {"status":"pending", "reason":"tree_overlay_artifact_member_duplicate"}
			expected[identity] = {"owner":owner, "supports":supports.duplicate(), "bounds":bounds}
	var expected_disposition := "complete_empty" if expected_owners.is_empty() \
		else "complete_nonempty"
	if String(artifact.get("disposition", "")) != expected_disposition:
		return {"status":"pending", "reason":"tree_overlay_artifact_disposition_mismatch",
			"expected":expected_disposition,
			"actual":String(artifact.get("disposition", "")),
			"expectedOwnerMemberCount":expected_owners.size()}
	var actual: Dictionary = {}
	for row_value: Variant in rows:
		if not row_value is Dictionary:
			return {"status":"pending", "reason":"tree_overlay_artifact_row_invalid"}
		var row: Dictionary = row_value
		var identity := _source_part_identity_key(String(row.get("sourceId", "")),
			String(row.get("sourcePartId", "")))
		if identity.is_empty() or actual.has(identity):
			return {"status":"pending", "reason":"tree_overlay_artifact_row_duplicate"}
		actual[identity] = row
	if actual.size() != expected.size():
		return {"status":"pending", "reason":"tree_overlay_artifact_support_set_mismatch",
			"expected":expected.size(), "actual":actual.size()}
	for identity: String in expected:
		if not actual.has(identity):
			return {"status":"pending", "reason":"tree_overlay_artifact_support_member_missing",
				"member":identity}
		var expected_member: Dictionary = expected[identity]
		var row: Dictionary = actual[identity]
		if row.get("geometryOwnerSection", null) != expected_member.owner \
				or row.get("conservativeWorldBounds", null) != expected_member.bounds \
				or row.get("conservativeSupportSectionKeys", []) != expected_member.supports:
			return {"status":"pending", "reason":"tree_overlay_artifact_support_proof_mismatch",
				"member":identity}
	var batches: Array = batches_value
	var batch_owners: Dictionary = {}
	var source_owner_members: Dictionary = {}
	var batch_compatibility_by_key: Dictionary = {}
	var batch_slice_keys: Dictionary = {}
	for source_id_value: Variant in source_by_id:
		var source_id := String(source_id_value)
		var source: Dictionary = source_by_id[source_id]
		for member_value: Variant in source.get("geometryOwnership", []):
			var member: Dictionary = member_value
			var member_id := String(member.get("memberId", ""))
			if member.get("ownedSectionKey", member.get("geometryOwnerSectionKey", null)) == section_key:
				source_owner_members[_source_part_identity_key(source_id, member_id)] = {
					"source":source, "member":member}
	var owner_payload_rows: Array = []
	for batch_value: Variant in batches:
		if not batch_value is Dictionary or not batch_value.is_read_only():
			return {"status":"pending", "reason":"tree_overlay_artifact_batch_invalid"}
		var batch: Dictionary = batch_value
		if batch.get("sectionKey", null) != section_key:
			return {"status":"pending", "reason":"tree_overlay_artifact_batch_outside_target"}
		var batch_key := String(batch.get("batchKey", ""))
		var compatibility_value: Variant = batch.get("compatibilityKey", null)
		if batch_key.is_empty() or not compatibility_value is Dictionary \
				or String(compatibility_value.get("batchKey", "")) != batch_key \
				or String(compatibility_value.get("compatibilityKey", "")) != batch_key:
			return {"status":"pending", "reason":"tree_overlay_artifact_batch_identity_invalid"}
		if batch_compatibility_by_key.has(batch_key) \
				and batch_compatibility_by_key[batch_key] != compatibility_value:
			return {"status":"pending", "reason":"tree_overlay_artifact_compatibility_slice_conflict",
				"batchKey":batch_key}
		batch_compatibility_by_key[batch_key] = compatibility_value
		var mesh_key := String(batch.get("meshKey", ""))
		var material_key := String(batch.get("materialKey", ""))
		var mesh_digest := String(batch.get("meshContentDigest", ""))
		var material_digest := String(batch.get("materialContentDigest", ""))
		if mesh_key.is_empty() or material_key.is_empty() \
				or mesh_digest.is_empty() or material_digest.is_empty() \
				or not resource_bindings_value.has(mesh_key) \
				or not resource_bindings_value.has(material_key) \
				or not mesh_key.contains(mesh_digest) \
				or not material_key.contains(material_digest):
			return {"status":"pending", "reason":"tree_overlay_artifact_batch_resource_binding_mismatch"}
		var aggregate_attributes: Variant = batch.get("instanceAttributes", null)
		var batch_count_value: Variant = batch.get("instanceCount", null)
		if not aggregate_attributes is Array \
				or aggregate_attributes.get_typed_builtin() != TYPE_FLOAT \
				or not aggregate_attributes.is_read_only() \
				or not batch_count_value is int or int(batch_count_value) < 1 \
				or aggregate_attributes.size() != int(batch_count_value) \
				* Attributes.FLOATS_PER_INSTANCE:
			return {"status":"pending", "reason":"tree_overlay_artifact_batch_buffer_invalid"}
		var contributors: Variant = batch.get("contributors", null)
		if not contributors is Dictionary or not contributors.is_read_only():
			return {"status":"pending", "reason":"tree_overlay_artifact_batch_contributors_missing"}
		var covered_offsets: Dictionary = {}
		for contributor_value: Variant in contributors.values():
			if not contributor_value is Dictionary or not contributor_value.is_read_only():
				return {"status":"pending", "reason":"tree_overlay_artifact_batch_contributor_invalid"}
			var contributor: Dictionary = contributor_value
			var contributor_source_id := String(contributor.get("sourceId", ""))
			var contributor_member_id := String(contributor.get("sourcePartId", ""))
			var identity := _source_part_identity_key(contributor_source_id, contributor_member_id)
			var slice_identity := identity + "|batch:" + batch_key
			if identity.is_empty() or not expected_owners.has(identity):
				return {"status":"pending", "reason":"tree_overlay_artifact_batch_owner_invalid"}
			if batch_owners.has(identity) or batch_slice_keys.has(slice_identity) \
					or not source_owner_members.has(identity):
				return {"status":"pending", "reason":"tree_overlay_artifact_batch_owner_duplicate"}
			batch_owners[identity] = true
			batch_slice_keys[slice_identity] = true
			var owner_record: Dictionary = source_owner_members[identity]
			var owner_source: Dictionary = owner_record.source
			var owner_member: Dictionary = owner_record.member
			var contributor_attributes: Variant = contributor.get("instanceAttributes", null)
			var offsets_value: Variant = contributor.get("instanceAttributeOffsets", null)
			if String(contributor.get("sourceRevision", "")) != String(
					owner_source.get("sourceRevision", "")) \
					or not contributor_attributes is Array \
					or contributor_attributes.get_typed_builtin() != TYPE_FLOAT \
					or not contributor_attributes.is_read_only() \
					or not offsets_value is Array or not offsets_value.is_read_only() \
					or contributor_attributes.size() % Attributes.FLOATS_PER_INSTANCE != 0 \
					or offsets_value.size() != contributor_attributes.size() \
					/ Attributes.FLOATS_PER_INSTANCE:
				return {"status":"pending", "reason":"tree_overlay_artifact_contributor_slice_invalid"}
			for contributor_index: int in range(offsets_value.size()):
				var offset_value: Variant = offsets_value[contributor_index]
				if not offset_value is int or int(offset_value) < 0 \
						or int(offset_value) >= int(batch_count_value) \
						or covered_offsets.has(int(offset_value)):
					return {"status":"pending", "reason":"tree_overlay_artifact_contributor_offset_invalid"}
				covered_offsets[int(offset_value)] = true
				for attribute_index: int in range(Attributes.FLOATS_PER_INSTANCE):
					var source_offset := contributor_index * Attributes.FLOATS_PER_INSTANCE \
						+ attribute_index
					var target_offset := int(offset_value) * Attributes.FLOATS_PER_INSTANCE \
						+ attribute_index
					if contributor_attributes[source_offset] != aggregate_attributes[target_offset]:
						return {"status":"pending", "reason":"tree_overlay_artifact_contributor_buffer_mismatch"}
			var payload := [contributor_source_id, contributor_member_id,
				String(owner_source.get("recipeArtifactRevision", "")),
				String(owner_source.get("recipeSignature", "")),
				String(batch.get("meshContentDigest", "")),
				String(batch.get("materialContentDigest", "")),
				String(owner_member.get("meshContentDigest", "")),
				owner_member.get("conservativeWorldBounds", AABB()),
				String(owner_member.get("certifiedEnvelopeDigest", "")),
				contributor.get("instanceAttributes", [])]
			owner_payload_rows.append([String(batch.get("batchKey", "")), payload])
		if covered_offsets.size() != int(batch_count_value):
			return {"status":"pending", "reason":"tree_overlay_artifact_batch_offset_coverage_incomplete"}
	if batch_owners.size() != expected_owners.size():
		return {"status":"pending", "reason":"tree_overlay_artifact_owner_batch_set_mismatch",
			"expected":expected_owners.size(), "actual":batch_owners.size()}
	for identity: String in expected_owners:
		if not batch_owners.has(identity):
			return {"status":"pending", "reason":"tree_overlay_artifact_owner_batch_missing",
				"member":identity}
	owner_payload_rows.sort_custom(func(a: Array, b: Array) -> bool:
		return String(a[0]) + var_to_str(a[1]) < String(b[0]) + var_to_str(b[1]))
	var owner_batch_payload_digest := _sha256_bytes(var_to_bytes(owner_payload_rows))
	if owner_payload_value != owner_payload_rows \
			or owner_batch_payload_digest.is_empty() \
			or String(artifact.get("ownerBatchPayloadDigest", "")) != owner_batch_payload_digest:
		return {"status":"pending", "reason":"tree_overlay_artifact_owner_batch_digest_mismatch"}
	var resource_binding_keys: Array[String] = []
	for key_value: Variant in resource_bindings_value:
		var resource_key := String(key_value)
		var resource_value: Variant = resource_bindings_value[key_value]
		if resource_key.is_empty() or not resource_value is Resource \
				or not is_instance_valid(resource_value):
			return {"status":"pending", "reason":"tree_overlay_artifact_resource_binding_invalid"}
		resource_binding_keys.append(resource_key)
	resource_binding_keys.sort()
	var resource_binding_digest := _sha256_bytes(var_to_bytes(resource_binding_keys))
	var compiled_batch_digest := _sha256_bytes(var_to_bytes(batches))
	var compiled_artifact_digest := _sha256_bytes(var_to_bytes([
		String(artifact.get("schema", "")), expected_source_ids,
		source_artifact_digests_value,
		String(artifact.get("sourceCompletionDigest", "")),
		String(artifact.get("ownerBatchPayloadDigest", "")),
		compiled_batch_digest, resource_binding_digest]))
	if compiled_batch_digest.is_empty() or resource_binding_digest.is_empty() \
			or compiled_artifact_digest.is_empty():
		return {"status":"failed", "reason":"tree_overlay_artifact_digest_failed"}
	return {"status":"ready", "supportMemberCount":expected.size(),
		"ownerMemberCount":expected_owners.size(),
		"sourceCompletionDigest":source_completion_digest,
		"ownerBatchPayloadDigest":owner_batch_payload_digest,
		"compiledBatchDigest":compiled_batch_digest,
		"resourceBindingDigest":resource_binding_digest,
		"compiledArtifactDigest":compiled_artifact_digest}


func _tree_overlay_row_as_tombstone(row: Dictionary, replacement_digest: String) -> Dictionary:
	var copy: Dictionary = row.duplicate(true)
	copy["state"] = "tombstoned"
	copy["tombstoneRevision"] = _sha256_bytes(var_to_bytes([
		"tree-section-overlay-retirement/v1", _world_id,
		row.get("sourceChunkKey", Vector2i.ZERO), row.get("sourceId", ""),
		row.get("sourcePartId", ""), row.get("sourceRevision", ""),
		replacement_digest]))
	copy.make_read_only()
	return copy


func _tree_band_authority_current(authority: Dictionary, lease: Dictionary,
		world_id: String, source_chunk_key: Vector2i, section_key: Vector3i) -> bool:
	if authority.is_empty() or lease.is_empty() or world_id != _world_id \
			or String(authority.get("schema", "")) != "ecology-tree-source-family-band-authority/v1" \
			or String(authority.get("worldId", "")) != world_id \
			or int(authority.get("worldEpoch", -1)) != _world_epoch \
			or authority.get("sourceChunkKey", null) != source_chunk_key \
			or authority.get("sectionKey", null) != section_key \
			or authority.get("bandBounds", null) != ProducerDomain.section_bounds(section_key) \
			or String(authority.get("publicationLeaseToken", "")) != String(lease.get("leaseToken", "")):
		return false
	var view: Dictionary = lease.get("view", {})
	if view.is_empty() or String(view.get("publicationId", "")) != String(
			authority.get("sourcePublicationId", "")) \
			or String(view.get("contentDigest", "")) != String(
			authority.get("sourcePublicationContentDigest", "")):
		return false
	var local_current: Variant = _catalog_resolver.call(
		"ecology_source_publication_local_is_current", view,
		String(lease.get("leaseToken", "")))
	if not local_current is Dictionary or String(local_current.get("status", "")) != "ready":
		return false
	var family_result: Dictionary = view.get("familyResultsById", {}).get("trees", {})
	if String(family_result.get("status", "")) != "ready" \
			or String(family_result.get("familyRevision", "")) != String(
				authority.get("sourceFamilyRevision", "")) \
			or String(family_result.get("sourceManifestDigest", "")) != String(
				authority.get("sourceFamilyManifestDigest", "")):
		return false
	if _catalog_resolver.has_method("ecology_source_publication_record_is_current"):
		for source_row_value: Variant in family_result.get("sourceRows", []):
			if not source_row_value is Dictionary:
				return false
			var record_current: Variant = _catalog_resolver.call(
				"ecology_source_publication_record_is_current", view,
				String(lease.get("leaseToken", "")), source_row_value)
			if not record_current is Dictionary or String(record_current.get("status", "")) != "ready":
				return false
	var digest_value: Dictionary = authority.duplicate(true)
	digest_value.erase("authorityDigest")
	digest_value.erase("publicationLeaseToken")
	if String(authority.get("authorityDigest", "")) != _sha256_bytes(
			var_to_bytes(digest_value)):
		return false
	return true


func _tree_section_overlay_current(authority: Dictionary, overlay: Dictionary,
		lease: Dictionary, world_id: String, source_chunk_key: Vector2i,
		section_key: Vector3i) -> bool:
	if not _tree_band_authority_current(authority, lease, world_id,
			source_chunk_key, section_key) \
			or overlay.is_empty() \
			or String(overlay.get("schema", "")) != "ecology-tree-section-geometry-overlay/v1" \
			or String(overlay.get("worldId", "")) != world_id \
			or int(overlay.get("worldEpoch", -1)) != _world_epoch \
			or overlay.get("sourceChunkKey", null) != source_chunk_key \
			or overlay.get("sectionKey", null) != section_key \
			or String(overlay.get("authorityDigest", "")) != String(authority.get("authorityDigest", "")) \
			or String(overlay.get("sourceRevision", "")) != String(authority.get("sourceRevision", "")) \
			or String(overlay.get("sourceFamilyRevision", "")) != String(authority.get("sourceFamilyRevision", "")) \
			or String(overlay.get("sourceFamilyManifestDigest", "")) != String(authority.get("sourceFamilyManifestDigest", "")) \
			or String(overlay.get("producerBandManifestDigest", "")) != String(authority.get("producerBandManifestDigest", "")) \
			or overlay.get("producerSourceIds", null) != authority.get("producerSourceIds", null) \
			or String(overlay.get("producerSourceIdsDigest", "")) != String(authority.get("producerSourceIdsDigest", "")) \
			or String(overlay.get("compiledArtifactDigest", "")).length() != 64 \
			or String(overlay.get("compiledBatchDigest", "")).length() != 64 \
			or String(overlay.get("sourceCompletionDigest", "")).length() != 64 \
			or String(overlay.get("ownerBatchPayloadDigest", "")).length() != 64 \
			or String(overlay.get("resourceBindingDigest", "")).length() != 64 \
			or int(overlay.get("sourceCompletionCount", -1)) != authority.get("producerSourceIds", []).size():
		return false
	var rows: Variant = overlay.get("supportRows", null)
	if not rows is Array or int(overlay.get("supportMemberCount", -1)) != rows.size():
		return false
	var row_keys: Array[String] = []
	var owner_keys: Array[String] = []
	for row_value: Variant in rows:
		if not row_value is Dictionary: return false
		var row: Dictionary = row_value
		if String(row.get("overlayAuthorityDigest", "")) != String(authority.get("authorityDigest", "")) \
				or String(row.get("family", "")) != "trees" \
				or not section_key in row.get("supportSectionKeys", []):
			return false
		var row_key := _row_key(row)
		if row_key.is_empty() or row_key in row_keys: return false
		row_keys.append(row_key)
		if row.get("geometryOwnerSection", null) == section_key:
			owner_keys.append(row_key)
	row_keys.sort()
	owner_keys.sort()
	var tuples: Array = []
	for row_value: Variant in rows:
		if row_value is Dictionary:
			tuples.append(_stable_source_tuple(row_value))
	var expected_geometry_digest := _sha256_bytes(var_to_bytes([
		"tree-section-geometry-overlay/v1", world_id, source_chunk_key,
		section_key, String(authority.get("authorityDigest", "")),
		authority.get("producerSourceIds", []), tuples,
		String(overlay.get("compiledArtifactDigest", "")),
		String(overlay.get("compiledBatchDigest", "")),
		String(overlay.get("sourceCompletionDigest", "")),
		String(overlay.get("ownerBatchPayloadDigest", "")),
		String(overlay.get("resourceBindingDigest", ""))]))
	return row_keys == overlay.get("supportMemberIds", []) \
		and owner_keys == overlay.get("ownerMemberIds", []) \
		and String(overlay.get("supportMemberDigest", "")) == _sha256_bytes(var_to_bytes(row_keys)) \
		and String(overlay.get("ownerMemberDigest", "")) == _sha256_bytes(var_to_bytes(owner_keys)) \
		and String(overlay.get("geometryDigest", "")) == expected_geometry_digest


func _release_tree_overlay_publication_leases() -> void:
	if not is_instance_valid(_catalog_resolver):
		_tree_overlay_publication_leases.clear()
		return
	for chunk_value: Variant in _tree_overlay_publication_leases.values():
		if not chunk_value is Dictionary: continue
		for lease_value: Variant in chunk_value.values():
			if not lease_value is Dictionary: continue
			var tokens: Array[String] = []
			var current := String(lease_value.get("leaseToken", ""))
			if not current.is_empty(): tokens.append(current)
			for old_value: Variant in lease_value.get("retiredLeaseTokens", []):
				var old := String(old_value)
				if not old.is_empty() and old not in tokens: tokens.append(old)
			for token: String in tokens:
				_catalog_resolver.call("release_ecology_source_publication", token)
	_tree_overlay_publication_leases.clear()


func _family_publish_reject(acquired: Dictionary, reason: String,
		extra: Dictionary = {}, result_status := "pending") -> Dictionary:
	_release_source_publication_lease(String(acquired.get("temporaryAdmissionToken", "")))
	var result := {"status":result_status, "reason":reason}
	result.merge(extra, true)
	return result


func _family_publish_propagate(acquired: Dictionary, failure: Dictionary) -> Dictionary:
	_release_source_publication_lease(String(acquired.get("temporaryAdmissionToken", "")))
	return failure


func _resolve_family_publication_view(world_id: String, source_chunk_key: Vector2i,
		bundle: Dictionary, provided_view: Dictionary, provided_token: String,
		requested: Array[String]) -> Dictionary:
	var temporary_token := ""
	var view := provided_view
	var token := provided_token
	var publication_id := String(view.get("publicationId", ""))
	if view.is_empty() or token.is_empty():
		var inputs: Dictionary = bundle.get("sourceInputs", {})
		var artifact_id := String(inputs.get("catalogArtifactId", ""))
		var content_digest := String(inputs.get("catalogContentDigest", ""))
		var catalog_acquired := _acquire_or_resolve_catalog_lease(artifact_id,
			"support_index_family_admission",
			_domain_owner_key(world_id, source_chunk_key), content_digest,
			String(bundle.get("influencePolicyRevision", "")),
			String(bundle.get("influencePolicyDigest", "")), {}, requested)
		if String(catalog_acquired.get("status", "")) != "ready":
			return catalog_acquired
		var catalog_token := String(catalog_acquired.get("leaseToken", ""))
		var admitted: Variant = _catalog_resolver.call(
			"admit_ecology_source_publication", bundle, catalog_token,
			"support_index_family_admission",
			_domain_owner_key(world_id, source_chunk_key)) \
			if _catalog_resolver.has_method("admit_ecology_source_publication") else null
		_release_catalog_lease(catalog_token)
		if not admitted is Dictionary or String(admitted.get("status", "")) != "ready":
			return admitted if admitted is Dictionary else {"status":"pending",
				"reason":"ecology_source_publication_admission_unavailable"}
		token = String(admitted.get("leaseToken", ""))
		publication_id = String(admitted.get("publicationId", ""))
		view = admitted.get("view", {})
		temporary_token = token
	if token.is_empty() or publication_id.is_empty() or view.is_empty():
		_release_source_publication_lease(temporary_token)
		return {"status":"pending", "reason":"ecology_source_publication_view_missing"}
	var resolved: Variant = _catalog_resolver.call(
		"resolve_ecology_source_publication", token, world_id, _world_epoch)
	if not resolved is Dictionary or String(resolved.get("status", "")) != "ready" \
			or not is_same(resolved.get("view", null), view) \
			or not is_same(view.get("payload", null), bundle) \
			or String(view.get("publicationId", "")) != publication_id:
		_release_source_publication_lease(temporary_token)
		return {"status":"pending", "reason":"ecology_source_publication_view_not_admitted"}
	var local_current: Variant = _catalog_resolver.call(
		"ecology_source_publication_local_is_current", view, token) \
		if _catalog_resolver.has_method("ecology_source_publication_local_is_current") else null
	if not local_current is Dictionary or String(local_current.get("status", "")) != "ready":
		_release_source_publication_lease(temporary_token)
		return local_current if local_current is Dictionary else {"status":"pending",
			"reason":"ecology_source_publication_currentness_unavailable"}
	var payload: Dictionary = view.get("payload", {})
	var view_requested: Variant = view.get("requestedFamilies",
		payload.get("requestedFamilies", null))
	var payload_requested: Variant = payload.get("requestedFamilies", null)
	if not view_requested is Array or not payload_requested is Array \
			or view_requested != payload_requested:
		_release_source_publication_lease(temporary_token)
		return {"status":"pending", "reason":"ecology_source_publication_family_scope_mismatch"}
	var admitted_families: Array[String] = []
	for family_value: Variant in view_requested:
		var family := String(family_value)
		if family not in ProducerDomain.REQUIRED_CATEGORIES or family in admitted_families:
			_release_source_publication_lease(temporary_token)
			return {"status":"pending", "reason":"ecology_source_publication_family_scope_invalid"}
		admitted_families.append(family)
	for family: String in requested:
		if family not in admitted_families:
			_release_source_publication_lease(temporary_token)
			return {"status":"pending", "reason":"ecology_source_publication_family_scope_mismatch",
				"family":family}
	return {"status":"ready", "publicationId":publication_id,
		"view":view, "temporaryAdmissionToken":temporary_token}


func _source_rows_for_chunk_family(source_chunk_key: Vector2i,
		family: String) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for row_value: Variant in _sources.values():
		if row_value is Dictionary and row_value.get("sourceChunkKey", null) == source_chunk_key \
				and String(row_value.get("family", "")) == family:
			rows.append(row_value)
	return rows


func _source_family_rows_for_section(source_chunk_key: Vector2i, family: String,
		section_key: Vector3i) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for row_value: Variant in _source_rows_for_chunk_family(source_chunk_key, family):
		if section_key in row_value.get("supportSectionKeys", []):
			rows.append(row_value)
	rows.sort_custom(_row_less)
	return rows


func _source_ids_for_rows(rows_value: Variant) -> Array[String]:
	var unique: Dictionary = {}
	if rows_value is Array:
		for row_value: Variant in rows_value:
			if row_value is Dictionary:
				var source_id := String(row_value.get("sourceId", ""))
				if not source_id.is_empty(): unique[source_id] = true
	var result: Array[String] = []
	for source_id_value: Variant in unique:
		result.append(String(source_id_value))
	result.sort()
	return result


func _source_family_support_projection_digest(domain: Dictionary,
		section_key: Vector3i, rows: Array[Dictionary]) -> String:
	var tuples: Array = []
	for row: Dictionary in rows:
		tuples.append(_stable_source_tuple(row))
	tuples.sort_custom(_source_tuple_less)
	return _sha256_bytes(var_to_bytes([
		"ecology-support-family-section-projection/v1",
		Vector2i(domain.get("sourceChunkKey", Vector2i.ZERO)),
		String(domain.get("family", "")), section_key,
		String(domain.get("sourceRevision", "")),
		String(domain.get("familyRevision", "")),
		String(domain.get("sourceManifestDigest", "")), tuples]))


func _band_family_receipt(coverage_rows: Array, family: String) -> Dictionary:
	for row_value: Variant in coverage_rows:
		if row_value is Dictionary and String(row_value.get("family", "")) == family:
			return row_value
	return {}


## Resolve exact member aliases from the admitted publication payload. Family
## coverage carries value-equal sealed rows, but source currentness must receive
## the unique row object owned by the publication's member index.
func _tree_publication_member_alias_index(publication_view: Dictionary) -> Dictionary:
	var payload: Variant = publication_view.get("payload", null)
	var rows: Variant = payload.get("sourceRows", null) if payload is Dictionary else null
	var member_index: Variant = publication_view.get("memberIndex", null)
	if not rows is Array or not member_index is Dictionary \
			or member_index.size() != rows.size():
		return {"status":"pending", "reason":"tree_band_authority_publication_member_index_invalid"}
	var rows_by_key: Dictionary = {}
	for row_index in range(rows.size()):
		var row_value: Variant = rows[row_index]
		if not row_value is Dictionary:
			return {"status":"pending", "reason":"tree_band_authority_publication_member_invalid"}
		var row: Dictionary = row_value
		var member_key := ProducerDomain.source_publication_member_key(
			String(row.get("producerFamily", "")),
			String(row.get("sourceId", "")),
			String(row.get("sourcePartId", "")))
		if member_key.is_empty() or rows_by_key.has(member_key) \
				or int(member_index.get(member_key, -1)) != row_index:
			return {"status":"pending", "reason":"tree_band_authority_publication_member_alias_ambiguous",
				"rowIndex":row_index, "memberKey":member_key}
		rows_by_key[member_key] = row
	return {"status":"ready", "rowsByKey":rows_by_key}


func _tree_publication_member_alias_for_family_row(rows_by_key: Dictionary,
		family_row: Dictionary) -> Dictionary:
	var member_key := ProducerDomain.source_publication_member_key(
		String(family_row.get("producerFamily", "")),
		String(family_row.get("sourceId", "")),
		String(family_row.get("sourcePartId", "")))
	var publication_row: Variant = rows_by_key.get(member_key, null)
	if member_key.is_empty() or not publication_row is Dictionary:
		return {"status":"pending", "reason":"tree_band_authority_source_row_alias_missing",
			"sourceId":String(family_row.get("sourceId", "")),
			"sourcePartId":String(family_row.get("sourcePartId", ""))}
	if publication_row != family_row:
		return {"status":"pending", "reason":"tree_band_authority_source_row_alias_mismatch",
			"sourceId":String(family_row.get("sourceId", "")),
			"sourcePartId":String(family_row.get("sourcePartId", ""))}
	return {"status":"ready", "row":publication_row, "memberKey":member_key}


func _source_snapshot_family_matches_current(source_snapshot: Dictionary,
		domain: Dictionary, family: String, family_result: Dictionary) -> bool:
	var inputs: Variant = source_snapshot.get("sourceInputs", null)
	var current_inputs: Variant = domain.get("sourceInputs", null)
	return inputs is Dictionary and current_inputs is Dictionary \
		and String(source_snapshot.get("sourceRevision", "")) == String(domain.get("sourceRevision", "")) \
		and String(source_snapshot.get("removedSourceProjectionDigest", "")) \
			== String(domain.get("removedSourceProjectionDigest", "")) \
		and String(source_snapshot.get("catalogArtifactId", "")) == String(domain.get("catalogArtifactId", "")) \
		and String(source_snapshot.get("catalogContentDigest", "")) == String(domain.get("catalogContentDigest", "")) \
		and int(source_snapshot.get("worldEpoch", -1)) == int(domain.get("worldEpoch", -2)) \
		and String(source_snapshot.get("terrainVolumeChunkRevision", "")) \
			== String(domain.get("terrainVolumeChunkRevision", "")) \
		and String(source_snapshot.get("structureAdmissionRevision", "")) \
			== String(domain.get("structureAdmissionRevision", "")) \
		and String(source_snapshot.get("influencePolicyRevision", "")) \
			== String(domain.get("influencePolicyRevision", "")) \
		and String(source_snapshot.get("influencePolicyDigest", "")) \
			== String(domain.get("influencePolicyDigest", "")) \
		and String(inputs.get("worldId", "")) == String(current_inputs.get("worldId", "")) \
		and String(inputs.get("worldSeed", "")) == String(current_inputs.get("worldSeed", "")) \
		and inputs.get("sourceChunkKey", null) == domain.get("sourceChunkKey", null) \
		and int(inputs.get("worldEpoch", -1)) == int(domain.get("worldEpoch", -2)) \
		and String(inputs.get("catalogContentDigest", "")) == String(domain.get("catalogContentDigest", "")) \
		and String(family_result.get("status", "")) == "ready" \
		and String(family_result.get("familyRevision", "")) == String(domain.get("familyRevision", "")) \
		and String(family_result.get("sourceManifestDigest", "")) \
			== String(domain.get("sourceManifestDigest", "")) \
		and String(family_result.get("familyPolicyRevision", "")) \
			== String(domain.get("familyPolicyRevision", "")) \
		and String(family_result.get("familyPolicyDigest", "")) \
			== String(domain.get("familyPolicyDigest", "")) \
		and String(domain.get("family", "")) == family


func _band_family_matches_expected(band: Dictionary, expected: Dictionary,
		projected_source_ids: Array[String], canonical_family: Dictionary) -> bool:
	var disposition := String(band.get("disposition", ""))
	var expected_disposition := "complete_empty" if projected_source_ids.is_empty() else "complete_nonempty"
	return not band.is_empty() \
		and band.get("bandKey", null) == expected.get("sectionKey", null) \
		and band.get("bandBounds", null) == expected.get("bandBounds", null) \
		and String(band.get("sourceFamilyRevision", "")) == String(expected.get("sourceFamilyRevision", "")) \
		and String(band.get("sourceFamilyManifestDigest", "")) == String(expected.get("sourceFamilyManifestDigest", "")) \
		and String(band.get("familyPolicyRevision", "")) == String(expected.get("familyPolicyRevision", "")) \
		and String(band.get("familyPolicyDigest", "")) == String(expected.get("familyPolicyDigest", "")) \
		and String(band.get("sourceManifestDigest", "")).length() == 64 \
		and String(band.get("familyRevision", "")) == String(band.get("sourceManifestDigest", "")) \
		and band.get("sourceIds", null) == projected_source_ids \
		and String(band.get("sourceIdsDigest", "")) == ProducerDomain._digest(projected_source_ids) \
		and String(band.get("sourceFamilyIdsDigest", "")) == String(expected.get("sourceFamilyIdsDigest", "")) \
		and int(band.get("sourceFamilySourceIdCount", -1)) == int(expected.get("sourceFamilySourceIdCount", -2)) \
		and int(band.get("sourceFamilyMemberRowCount", band.get("sourceFamilyMemberCount", -1))) \
			== int(expected.get("sourceFamilyMemberRowCount", -2)) \
		and int(band.get("sourceFamilyMemberCount", -1)) == int(expected.get("sourceFamilyMemberRowCount", -2)) \
		and projected_source_ids == expected.get("expectedSourceIds", []) \
		and int(band.get("memberCount", -1)) == int(band.get("sourceRows", []).size()) \
		and disposition == expected_disposition \
		and disposition in ["complete_empty", "complete_nonempty"] \
		and String(canonical_family.get("status", "")) == "ready" \
		and String(canonical_family.get("sourceManifestDigest", "")) == String(expected.get("sourceFamilyManifestDigest", "")) \
		and String(canonical_family.get("familyRevision", "")) == String(expected.get("sourceFamilyRevision", ""))


func _build_band_receipt(world_id: String, source_chunk_key: Vector2i,
		section_key: Vector3i, family: String, expected: Dictionary,
		band: Dictionary, source_ids: Array[String], domain: Dictionary,
		projected_bundle: Dictionary) -> Dictionary:
	return {"schema":"ecology-support-family-section-band-receipt/v1",
		"worldId":world_id, "sourceChunkKey":source_chunk_key,
		"sectionKey":section_key, "bandBounds":expected.get("bandBounds", AABB()),
		"family":family,
		"sourceFamilyRevision":String(expected.get("sourceFamilyRevision", "")),
		"sourceFamilyManifestDigest":String(expected.get("sourceFamilyManifestDigest", "")),
		"sourceFamilyIdsDigest":String(expected.get("sourceFamilyIdsDigest", "")),
		"sourceFamilySourceIdCount":int(expected.get("sourceFamilySourceIdCount", -1)),
		"sourceFamilyMemberRowCount":int(expected.get("sourceFamilyMemberRowCount", -1)),
		"sourceDomainRevision":String(expected.get("sourceDomainRevision", "")),
		"familyPolicyRevision":String(expected.get("familyPolicyRevision", "")),
		"familyPolicyDigest":String(expected.get("familyPolicyDigest", "")),
		"catalogArtifactId":String(expected.get("catalogArtifactId", "")),
		"catalogContentDigest":String(expected.get("catalogContentDigest", "")),
		"worldEpoch":int(expected.get("worldEpoch", -1)),
		"removedSourceProjectionDigest":String(expected.get("removedSourceProjectionDigest", "")),
		"producerBandManifestDigest":String(band.get("sourceManifestDigest", "")),
		"producerBandRevision":String(band.get("familyRevision", "")),
		"producerSourceIds":source_ids,
		"producerSourceIdsDigest":String(band.get("sourceIdsDigest", "")),
		"producerMemberCount":int(band.get("memberCount", -1)),
		"producerDisposition":String(band.get("disposition", "")),
		"sourceBundleDigest":String(projected_bundle.get("sourceBundleDigest", "")),
		"sourceRevision":String(projected_bundle.get("sourceRevision", "")),
		"supportMemberDigest":String(expected.get("expectedSupportMemberDigest", "")),
		"supportMemberCount":int(expected.get("expectedSupportMemberCount", -1)),
		"ownerReceiptDigest":String(domain.get("ownerReceiptDigest", ""))}


func _valid_family_band_receipt(receipt: Dictionary, domain: Dictionary,
		expected: Dictionary, source_chunk_key: Vector2i,
		family: String, section_key: Vector3i) -> bool:
	if String(receipt.get("schema", "")) != "ecology-support-family-section-band-receipt/v1" \
			or String(receipt.get("worldId", "")) != _world_id \
			or receipt.get("sourceChunkKey", null) != source_chunk_key \
			or receipt.get("sectionKey", null) != section_key \
			or receipt.get("bandBounds", null) != ProducerDomain.section_bounds(section_key) \
			or String(receipt.get("family", "")) != family:
		return false
	return String(expected.get("status", "")) == "ready" \
		and String(receipt.get("sourceFamilyRevision", "")) == String(expected.get("sourceFamilyRevision", "")) \
		and String(receipt.get("sourceFamilyManifestDigest", "")) == String(expected.get("sourceFamilyManifestDigest", "")) \
		and String(receipt.get("sourceFamilyIdsDigest", "")) == String(expected.get("sourceFamilyIdsDigest", "")) \
		and int(receipt.get("sourceFamilySourceIdCount", -1)) == int(expected.get("sourceFamilySourceIdCount", -2)) \
		and int(receipt.get("sourceFamilyMemberRowCount", -1)) == int(expected.get("sourceFamilyMemberRowCount", -2)) \
		and String(receipt.get("sourceDomainRevision", "")) == String(expected.get("sourceDomainRevision", "")) \
		and String(receipt.get("familyPolicyRevision", "")) == String(expected.get("familyPolicyRevision", "")) \
		and String(receipt.get("familyPolicyDigest", "")) == String(expected.get("familyPolicyDigest", "")) \
		and String(receipt.get("catalogArtifactId", "")) == String(expected.get("catalogArtifactId", "")) \
		and String(receipt.get("catalogContentDigest", "")) == String(expected.get("catalogContentDigest", "")) \
		and int(receipt.get("worldEpoch", -1)) == int(expected.get("worldEpoch", -2)) \
		and String(receipt.get("removedSourceProjectionDigest", "")) == String(expected.get("removedSourceProjectionDigest", "")) \
		and String(receipt.get("sourceRevision", "")) == String(expected.get("sourceDomainRevision", "")) \
		and String(receipt.get("supportMemberDigest", "")) == String(expected.get("expectedSupportMemberDigest", "")) \
		and int(receipt.get("supportMemberCount", -1)) == int(expected.get("expectedSupportMemberCount", -2)) \
		and receipt.get("producerSourceIds", null) == expected.get("expectedSourceIds", []) \
		and String(receipt.get("producerSourceIdsDigest", "")) == String(expected.get("expectedSourceIdsDigest", "")) \
		and String(receipt.get("producerBandManifestDigest", "")).length() == 64 \
		and String(receipt.get("producerBandRevision", "")) == String(receipt.get("producerBandManifestDigest", "")) \
		and String(receipt.get("sourceBundleDigest", "")).length() == 64 \
		and int(receipt.get("producerMemberCount", -1)) >= 0 \
		and String(receipt.get("producerDisposition", "")) in ["complete_empty", "complete_nonempty"] \
		and String(receipt.get("producerDisposition", "")) == ("complete_empty" \
			if receipt.get("producerSourceIds", []).is_empty() else "complete_nonempty") \
		and String(receipt.get("ownerReceiptDigest", "")) == String(domain.get("ownerReceiptDigest", ""))


func _stable_band_receipt_tuple(receipt: Dictionary) -> Array:
	return [Vector2i(receipt.get("sourceChunkKey", Vector2i.ZERO)),
		String(receipt.get("family", "")), receipt.get("sectionKey", Vector3i.ZERO),
		receipt.get("bandBounds", AABB()),
		String(receipt.get("sourceFamilyRevision", "")),
		String(receipt.get("sourceFamilyManifestDigest", "")),
		String(receipt.get("sourceFamilyIdsDigest", "")),
		int(receipt.get("sourceFamilySourceIdCount", -1)),
		int(receipt.get("sourceFamilyMemberRowCount", -1)),
		String(receipt.get("sourceDomainRevision", "")),
		String(receipt.get("familyPolicyRevision", "")),
		String(receipt.get("familyPolicyDigest", "")),
		String(receipt.get("catalogArtifactId", "")),
		String(receipt.get("catalogContentDigest", "")),
		int(receipt.get("worldEpoch", -1)),
		String(receipt.get("removedSourceProjectionDigest", "")),
		String(receipt.get("producerBandManifestDigest", "")),
		String(receipt.get("producerBandRevision", "")),
		receipt.get("producerSourceIds", []),
		String(receipt.get("producerSourceIdsDigest", "")),
		int(receipt.get("producerMemberCount", -1)),
		String(receipt.get("producerDisposition", "")),
		String(receipt.get("sourceBundleDigest", "")),
		String(receipt.get("sourceRevision", "")),
		String(receipt.get("supportMemberDigest", "")),
		int(receipt.get("supportMemberCount", -1)),
		String(receipt.get("ownerReceiptDigest", ""))]


func _band_receipt_less(a: Dictionary, b: Dictionary) -> bool:
	var a_key := "%d,%d,%d|%d,%d|%s" % [
		int(a.get("sectionKey", Vector3i.ZERO).x), int(a.get("sectionKey", Vector3i.ZERO).y),
		int(a.get("sectionKey", Vector3i.ZERO).z),
		int(a.get("sourceChunkKey", Vector2i.ZERO).x),
		int(a.get("sourceChunkKey", Vector2i.ZERO).y), String(a.get("family", ""))]
	var b_key := "%d,%d,%d|%d,%d|%s" % [
		int(b.get("sectionKey", Vector3i.ZERO).x), int(b.get("sectionKey", Vector3i.ZERO).y),
		int(b.get("sectionKey", Vector3i.ZERO).z),
		int(b.get("sourceChunkKey", Vector2i.ZERO).x),
		int(b.get("sourceChunkKey", Vector2i.ZERO).y), String(b.get("family", ""))]
	return a_key < b_key


func _owner_receipt_digest(receipt_value: Variant) -> String:
	if not receipt_value is Dictionary or receipt_value.is_empty():
		return ""
	return _sha256_bytes(var_to_bytes(receipt_value))


func _acquire_family_publication_lease(publication_id: String, world_id: String,
		world_epoch: int, source_chunk_key: Vector2i, family: String,
		expected_view: Dictionary) -> Dictionary:
	if publication_id.is_empty() or not is_instance_valid(_catalog_resolver) \
			or not _catalog_resolver.has_method("acquire_ecology_source_publication") \
			or not _catalog_resolver.has_method("resolve_ecology_source_publication"):
		return {"status":"pending", "reason":"ecology_source_publication_resolver_unavailable"}
	var owner_key := "%s|%s" % [_domain_owner_key(world_id, source_chunk_key), family]
	var acquired: Variant = _catalog_resolver.call(
		"acquire_ecology_source_publication", publication_id,
		"support_index_family", owner_key)
	if not acquired is Dictionary or String(acquired.get("status", "")) != "ready":
		return acquired if acquired is Dictionary else {"status":"pending",
			"reason":"ecology_source_publication_lease_acquire_pending"}
	var token := String(acquired.get("leaseToken", ""))
	var resolved: Variant = _catalog_resolver.call(
		"resolve_ecology_source_publication", token, world_id, world_epoch)
	if not resolved is Dictionary or String(resolved.get("status", "")) != "ready" \
			or not is_same(resolved.get("view", null), expected_view):
		_release_source_publication_lease(token)
		return {"status":"pending", "reason":"ecology_source_publication_view_stale"}
	var current: Variant = _catalog_resolver.call(
		"ecology_source_publication_is_current", token, world_id, world_epoch,
		expected_view.get("ownerReceipt", {}),
		String(expected_view.get("sourceDomainRevision", "")),
		String(expected_view.get("payload", {}).get("removedSourceProjectionDigest", "")))
	if not current is Dictionary or String(current.get("status", "")) != "ready":
		_release_source_publication_lease(token)
		return current if current is Dictionary else {"status":"pending",
			"reason":"ecology_source_publication_stale"}
	return {"status":"ready", "leaseToken":token, "publicationId":publication_id,
		"view":expected_view, "family":family}


func _family_domain_owner_current(domain: Dictionary, lease_row: Dictionary) -> bool:
	if domain.is_empty() or lease_row.is_empty():
		return false
	var token := String(lease_row.get("leaseToken", ""))
	var view: Dictionary = lease_row.get("view", {})
	if token.is_empty() or view.is_empty():
		return false
	var resolved: Variant = _catalog_resolver.call(
		"resolve_ecology_source_publication", token, _world_id, _world_epoch)
	if not resolved is Dictionary or String(resolved.get("status", "")) != "ready" \
			or not is_same(resolved.get("view", null), view) \
			or String(view.get("publicationId", "")) != \
			String(domain.get("publicationId", "")) \
			or String(domain.get("ownerReceiptDigest", "")) != \
			_owner_receipt_digest(view.get("ownerReceipt", {})):
		return false
	var payload: Dictionary = view.get("payload", {})
	var current: Variant = _catalog_resolver.call(
		"ecology_source_publication_is_current", token, _world_id, _world_epoch,
		view.get("ownerReceipt", {}), String(view.get("sourceDomainRevision", "")),
		String(payload.get("removedSourceProjectionDigest", "")))
	return current is Dictionary and String(current.get("status", "")) == "ready"


func _publish_source_domain_resolved(world_id: String, source_chunk_key: Vector2i,
		snapshot: Dictionary, rows: Array, runtime_policy: Dictionary,
		catalog_artifact: Dictionary) -> Dictionary:
	if world_id != _world_id or world_id.is_empty() \
			or not ProducerDomain.validate_source_domain_snapshot(snapshot,
				world_id, source_chunk_key, catalog_artifact):
		return {"status":"pending", "reason":"ecology_source_domain_incomplete"}
	if String(snapshot.get("status", "")) != "ready" \
			or not bool(snapshot.get("producerComplete", false)):
		return {"status":"pending", "reason":"ecology_source_domain_not_complete",
			"producerReason":String(snapshot.get("reason", ""))}
	var source_revision := String(snapshot.get("sourceRevision", ""))
	var producer_snapshot_revision := String(snapshot.get("producerSnapshotRevision", ""))
	var removed_projection_digest := String(snapshot.get("removedSourceProjectionDigest", ""))
	var removed_props_revision := String(snapshot.get("removedPropsRevision",
		removed_projection_digest))
	var source_inputs: Dictionary = snapshot.get("sourceInputs", {})
	var influence_revision := String(snapshot.get("influencePolicyRevision", ""))
	var influence_digest := String(snapshot.get("influencePolicyDigest", ""))
	var terrain_revision := String(snapshot.get("terrainVolumeChunkRevision",
		source_inputs.get("terrainVolumeChunkRevision", "")))
	var structure_revision := String(snapshot.get("structureAdmissionRevision",
		source_inputs.get("structureAdmissionRevision", "")))
	var structure_status := String(snapshot.get("structureAdmissionStatus",
		source_inputs.get("structureAdmissionStatus", "")))
	if source_revision.is_empty() or producer_snapshot_revision.is_empty() \
			or removed_props_revision.is_empty() or removed_projection_digest.length() != 64 \
			or terrain_revision.is_empty() or structure_revision.is_empty() \
			or structure_status not in ["ready", "complete"] \
			or String(runtime_policy.get("status", "")) != "ready" \
			or influence_revision != String(runtime_policy.get("revision", "")) \
			or influence_digest.length() != 64 \
			or influence_digest != String(runtime_policy.get("digest", "")):
		return {"status":"pending", "reason":"ecology_source_domain_identity_incomplete"}
	var snapshot_sources: Dictionary = {}
	for source_value: Variant in snapshot.get("sourceRows", []):
		if not source_value is Dictionary:
			return {"status":"pending", "reason":"ecology_source_snapshot_row_invalid"}
		var stable_source_id := String(source_value.get("sourceId", ""))
		if stable_source_id.is_empty() or snapshot_sources.has(stable_source_id):
			return {"status":"pending", "reason":"ecology_source_snapshot_id_invalid"}
		snapshot_sources[stable_source_id] = true
	var tuples: Array = []
	var prepared_rows: Array[Dictionary] = []
	var row_source_ids: Dictionary = {}
	for row_value: Variant in rows:
		if not row_value is Dictionary:
			return {"status":"pending", "reason":"ecology_source_domain_row_invalid"}
		var row: Dictionary = row_value
		var row_source_id := String(row.get("sourceId", ""))
		if not snapshot_sources.has(row_source_id):
			return {"status":"pending", "reason":"ecology_source_row_not_in_producer_snapshot",
				"sourceId":row_source_id}
		row_source_ids[row_source_id] = true
		var validated := _validate_source_row(row, world_id, source_chunk_key,
			source_revision, runtime_policy)
		if validated.get("status") != "ready":
			return validated
		var accepted_row: Dictionary = validated.row.duplicate(true)
		accepted_row["sourceDomainRevision"] = source_revision
		accepted_row["producerSnapshotRevision"] = producer_snapshot_revision
		accepted_row["terrainVolumeChunkRevision"] = terrain_revision
		accepted_row["structureAdmissionRevision"] = structure_revision
		accepted_row["removedSourceProjectionDigest"] = removed_projection_digest
		accepted_row["influencePolicyRevision"] = influence_revision
		accepted_row["influencePolicyDigest"] = influence_digest
		accepted_row.make_read_only()
		prepared_rows.append(accepted_row)
		tuples.append(_stable_source_tuple(accepted_row))
	if row_source_ids.size() != snapshot_sources.size():
		var missing_source_ids: Array[String] = []
		for source_id_value: Variant in snapshot_sources.keys():
			var source_id := String(source_id_value)
			if not row_source_ids.has(source_id): missing_source_ids.append(source_id)
		missing_source_ids.sort()
		return {"status":"pending", "reason":"ecology_producer_source_without_support_row",
			"producerSourceCount":snapshot_sources.size(),
			"supportSourceCount":row_source_ids.size(),
			"pendingSourceIds":missing_source_ids}
	tuples.sort_custom(_source_tuple_less)
	var old_domain: Dictionary = _domains.get(source_chunk_key, {})
	var domain_same := String(old_domain.get("sourceRevision", "")) == source_revision \
		and String(old_domain.get("removedPropsRevision", "")) == removed_props_revision \
		and String(old_domain.get("producerSnapshotRevision", "")) == producer_snapshot_revision \
		and String(old_domain.get("influencePolicyDigest", "")) == influence_digest
	if domain_same:
		var current_tuples: Array = []
		for row_value: Variant in _sources.values():
			if row_value is Dictionary and row_value.get("sourceChunkKey", null) == source_chunk_key:
				current_tuples.append(_stable_source_tuple(row_value))
		current_tuples.sort_custom(_source_tuple_less)
		if current_tuples == tuples:
			return {"status":"ready", "sourceChunkKey":source_chunk_key,
				"sourceManifestDigest":String(old_domain.get("sourceManifestDigest", "")),
				"sourceIndexRevision":_next_source_index_revision, "changed":false}
	# Retain prior support as tombstones until an accepted receipt covers each
	# affected section. A source replacement never makes old installed content
	# disappear merely because its producer row changed.
	var affected_sections: Dictionary = {}
	for section_key: Vector3i in _required_domains_by_section:
		if source_chunk_key in _required_domains_by_section[section_key]:
			affected_sections[section_key] = true
	for prior_value: Variant in _sources.values():
		if prior_value is Dictionary and Vector2i(prior_value.get("sourceChunkKey", Vector2i.ZERO)) == source_chunk_key:
			for key_value: Variant in prior_value.get("supportSectionKeys", []):
				affected_sections[key_value] = true
	for row: Dictionary in prepared_rows:
		for key_value: Variant in row.get("conservativeSupportSectionKeys", []):
			affected_sections[key_value] = true
	var new_by_key: Dictionary = {}
	for row: Dictionary in prepared_rows:
		new_by_key[_row_key(row)] = row
	var preserved: Dictionary = {}
	for source_key_value: Variant in _sources.keys().duplicate():
		var source_key := String(source_key_value)
		var old_row: Dictionary = _sources[source_key]
		if old_row.get("sourceChunkKey", null) != source_chunk_key:
			continue
		var replacement: Variant = new_by_key.get(source_key, null)
		if replacement is Dictionary and _stable_source_tuple(old_row) == _stable_source_tuple(replacement):
			preserved[source_key] = replacement
			new_by_key.erase(source_key)
			continue
		_retire_source_to_tombstone(source_key, old_row, source_revision)
		_sources.erase(source_key)
	for source_key: String in preserved:
		_sources[source_key] = preserved[source_key]
	for source_key: String in new_by_key:
		var row: Dictionary = new_by_key[source_key]
		_sources[source_key] = row
		_post_row(row)
	var manifest_tuples: Array = tuples.duplicate()
	for section_map_value: Variant in _retired_postings_by_section.values():
		if not section_map_value is Dictionary:
			continue
		for retired_value: Variant in section_map_value.values():
			if retired_value is Dictionary \
					and retired_value.get("sourceChunkKey", null) == source_chunk_key:
				manifest_tuples.append(_stable_source_tuple(retired_value))
	manifest_tuples.sort_custom(_source_tuple_less)
	var support_manifest_digest := _sha256_bytes(var_to_bytes([
		source_chunk_key, source_revision, removed_props_revision, manifest_tuples]))
	if support_manifest_digest.is_empty():
		return {"status":"failed", "reason":"ecology_source_manifest_digest_failed"}
	var domain := {"sourceChunkKey":source_chunk_key,
		"worldId":world_id, "sourceRevision":source_revision,
		"removedPropsRevision":removed_props_revision,
		"producerSnapshotRevision":producer_snapshot_revision,
		"producerComplete":bool(snapshot.get("producerComplete", false)),
		"enumeratedSourceCount":int(snapshot.get("enumeratedSourceCount", -1)),
		"categoriesComplete":snapshot.get("categoriesComplete", []),
		"terrainVolumeChunkRevision":terrain_revision,
		"structureAdmissionRevision":structure_revision,
		"structureAdmissionStatus":structure_status,
		"removedSourceProjectionDigest":removed_projection_digest,
		"sourceManifestDigest":String(snapshot.get("sourceManifestDigest", "")),
		"supportManifestDigest":support_manifest_digest,
		"influencePolicyRevision":String(snapshot.get("influencePolicyRevision", "")),
		"influencePolicyDigest":influence_digest, "sourceInputs":source_inputs,
		"sourceIndexRevision":_next_source_index_revision + 1}
	domain.make_read_only()
	_domains[source_chunk_key] = domain
	_bump_sections(affected_sections)
	return {"status":"ready", "sourceChunkKey":source_chunk_key,
		"sourceManifestDigest":String(snapshot.get("sourceManifestDigest", "")),
		"supportManifestDigest":support_manifest_digest,
		"sourceIndexRevision":_next_source_index_revision, "changed":true,
		"affectedSections":_sorted_sections(affected_sections)}


func mark_source_domain_unknown(source_chunk_key: Vector2i) -> void:
	var had_domain := _domains.has(source_chunk_key) or _family_domains.has(source_chunk_key)
	if _domains.has(source_chunk_key):
		_domains.erase(source_chunk_key)
	_family_domains.erase(source_chunk_key)
	_family_band_receipts.erase(source_chunk_key)
	if _tree_source_family_band_authorities.has(source_chunk_key):
		var section_authorities: Dictionary = _tree_source_family_band_authorities[source_chunk_key]
		for section_value: Variant in section_authorities.keys():
			var section_key: Vector3i = section_value
			var overlay: Dictionary = _tree_section_geometry_overlays.get(
				source_chunk_key, {}).get(section_key, {})
			if not overlay.is_empty():
				var retired: Array = _retired_tree_section_overlays.get(section_key, [])
				for row_value: Variant in overlay.get("supportRows", []):
					if row_value is Dictionary:
						retired.append(_tree_overlay_row_as_tombstone(row_value,
							"source_domain_unknown"))
				_retired_tree_section_overlays[section_key] = retired
			_tree_section_geometry_overlays.erase(source_chunk_key)
			# Keep stale authority and its lease until a replacement admission can
			# transfer the lease to the retired set, or section teardown releases it.
	var domain_lease: Dictionary = _catalog_domain_leases.get(source_chunk_key, {})
	_release_catalog_lease(String(domain_lease.get("leaseToken", "")))
	_catalog_domain_leases.erase(source_chunk_key)
	_release_family_publication_leases(source_chunk_key)
	if had_domain:
		var affected: Dictionary = {}
		for section_key: Vector3i in _required_domains_by_section:
			if source_chunk_key in _required_domains_by_section[section_key]:
				affected[section_key] = true
		_bump_sections(affected)


func release_section_demand(section_key: Vector3i) -> void:
	var install_receipt: Dictionary = _receipt_by_section.get(section_key, {})
	var retain_tree_state: bool = int(install_receipt.get("treeOverlayCount", 0)) > 0 \
		or not _retired_tree_section_overlays.get(section_key, []).is_empty()
	for chunk_value: Variant in _tree_source_family_band_authorities:
		var by_section: Dictionary = _tree_source_family_band_authorities[chunk_value]
		if by_section.has(section_key):
			retain_tree_state = true
			break
	if retain_tree_state: _detached_tree_sections[section_key] = true
	var leases: Dictionary = _catalog_census_leases.get(section_key, {})
	for lease_value: Variant in leases.values():
		if lease_value is Dictionary:
			_release_catalog_lease(String(lease_value.get("leaseToken", "")))
	_catalog_census_leases.erase(section_key)
	_required_domains_by_section.erase(section_key)
	_required_families_by_section.erase(section_key)
	_source_census_certificate_by_section.erase(section_key)
	_latest_query_by_section.erase(section_key)
	if not retain_tree_state:
		_retired_tree_section_overlays.erase(section_key)
		_release_tree_section_state(section_key)
	_bump_section_revision(section_key)
	_retire_unreferenced_domains()


## Demand removal and renderer teardown are separate lifetimes. An acknowledged
## tree overlay stays leased and retained until the native section owner proves
## that the installed representation has been removed.
func acknowledge_section_teardown(section_key: Vector3i,
		teardown_receipt: Dictionary) -> Dictionary:
	var installed: Dictionary = _receipt_by_section.get(section_key, {})
	if int(installed.get("treeOverlayCount", 0)) <= 0 \
			and not _detached_tree_sections.has(section_key):
		return {"status":"failed", "reason":"ecology_tree_section_teardown_not_required"}
	var native_receipt: Variant = teardown_receipt.get("nativeReceipt", null)
	if String(teardown_receipt.get("schema", "")) != \
			"ecology-support-section-teardown-receipt/v1" \
			or teardown_receipt.get("sectionKey", null) != section_key \
			or String(teardown_receipt.get("installedReceiptId", "")) \
				!= String(installed.get("receiptId", "")) \
			or teardown_receipt.get("verifiedAbsent", false) != true \
			or not native_receipt is Dictionary or native_receipt.is_empty():
		return {"status":"pending", "reason":"ecology_tree_section_teardown_receipt_invalid"}
	_release_tree_section_state(section_key)
	_retired_tree_section_overlays.erase(section_key)
	_detached_tree_sections.erase(section_key)
	_receipt_by_section.erase(section_key)
	_bump_section_revision(section_key)
	_retire_unreferenced_domains()
	return {"status":"ready", "sectionKey":section_key,
		"nativeReceiptId":String(native_receipt.get("receiptId", ""))}


func _release_tree_section_state(section_key: Vector3i) -> void:
	for chunk_value: Variant in _tree_source_family_band_authorities.keys().duplicate():
		var chunk: Vector2i = chunk_value
		var section_authorities: Dictionary = _tree_source_family_band_authorities[chunk]
		section_authorities.erase(section_key)
		if section_authorities.is_empty(): _tree_source_family_band_authorities.erase(chunk)
		else: _tree_source_family_band_authorities[chunk] = section_authorities
		var section_overlays: Dictionary = _tree_section_geometry_overlays.get(chunk, {})
		section_overlays.erase(section_key)
		if section_overlays.is_empty(): _tree_section_geometry_overlays.erase(chunk)
		else: _tree_section_geometry_overlays[chunk] = section_overlays
		var lease_rows: Dictionary = _tree_overlay_publication_leases.get(chunk, {})
		var lease_row: Dictionary = lease_rows.get(section_key, {})
		for token_value: Variant in lease_row.get("retiredLeaseTokens", []):
			_release_source_publication_lease(String(token_value))
		_release_source_publication_lease(String(lease_row.get("leaseToken", "")))
		lease_rows.erase(section_key)
		if lease_rows.is_empty(): _tree_overlay_publication_leases.erase(chunk)
		else: _tree_overlay_publication_leases[chunk] = lease_rows


func _retire_unreferenced_domains() -> void:
	var demanded_chunks: Dictionary = {}
	var demanded_families_by_chunk: Dictionary = {}
	for keys_value: Variant in _required_domains_by_section.values():
		if not keys_value is Array: continue
		for chunk_value: Variant in keys_value:
			if chunk_value is Vector2i:
				demanded_chunks[chunk_value] = true
	for family_map_value: Variant in _required_families_by_section.values():
		if not family_map_value is Dictionary: continue
		for family_value: Variant in family_map_value:
			var family := String(family_value)
			for chunk_value: Variant in family_map_value[family_value]:
				if not chunk_value is Vector2i: continue
				if not demanded_families_by_chunk.has(chunk_value):
					demanded_families_by_chunk[chunk_value] = {}
				(demanded_families_by_chunk[chunk_value] as Dictionary)[family] = true
	for chunk_value: Variant in _tree_source_family_band_authorities.keys().duplicate():
		var chunk: Vector2i = chunk_value
		var section_authorities: Dictionary = _tree_source_family_band_authorities.get(chunk, {})
		var section_overlays: Dictionary = _tree_section_geometry_overlays.get(chunk, {})
		var lease_rows: Dictionary = _tree_overlay_publication_leases.get(chunk, {})
		for section_value: Variant in section_authorities.keys().duplicate():
			var section_key: Vector3i = section_value
			if _detached_tree_sections.has(section_key) \
					or int(_receipt_by_section.get(section_key, {}).get("treeOverlayCount", 0)) > 0:
				continue
			var required_by_family: Dictionary = _required_families_by_section.get(section_key, {})
			if chunk in required_by_family.get("trees", []): continue
			section_authorities.erase(section_key)
			section_overlays.erase(section_key)
			var lease_row: Dictionary = lease_rows.get(section_key, {})
			for token_value: Variant in lease_row.get("retiredLeaseTokens", []):
				_release_source_publication_lease(String(token_value))
			_release_source_publication_lease(String(lease_row.get("leaseToken", "")))
			lease_rows.erase(section_key)
			_retired_tree_section_overlays.erase(section_key)
		if section_authorities.is_empty(): _tree_source_family_band_authorities.erase(chunk)
		else: _tree_source_family_band_authorities[chunk] = section_authorities
		if section_overlays.is_empty(): _tree_section_geometry_overlays.erase(chunk)
		else: _tree_section_geometry_overlays[chunk] = section_overlays
		if lease_rows.is_empty(): _tree_overlay_publication_leases.erase(chunk)
		else: _tree_overlay_publication_leases[chunk] = lease_rows
	for chunk_value: Variant in _domains.keys().duplicate():
		var chunk: Vector2i = chunk_value
		if demanded_chunks.has(chunk): continue
		_domains.erase(chunk)
		var lease_row: Dictionary = _catalog_domain_leases.get(chunk, {})
		_release_catalog_lease(String(lease_row.get("leaseToken", "")))
		_catalog_domain_leases.erase(chunk)
	for chunk_value: Variant in _family_domains.keys().duplicate():
		var chunk: Vector2i = chunk_value
		if not demanded_chunks.has(chunk):
			_family_domains.erase(chunk)
			_family_band_receipts.erase(chunk)
			var lease_row: Dictionary = _catalog_domain_leases.get(chunk, {})
			_release_catalog_lease(String(lease_row.get("leaseToken", "")))
			_catalog_domain_leases.erase(chunk)
			_release_family_publication_leases(chunk)
			continue
		var family_map: Dictionary = _family_domains[chunk]
		var demanded_families: Dictionary = demanded_families_by_chunk.get(chunk, {})
		for family_value: Variant in family_map.keys().duplicate():
			if not demanded_families.has(String(family_value)):
				family_map.erase(family_value)
				var band_family_map: Dictionary = _family_band_receipts.get(chunk, {})
				band_family_map.erase(String(family_value))
				if band_family_map.is_empty():
					_family_band_receipts.erase(chunk)
				else:
					_family_band_receipts[chunk] = band_family_map
				var lease_row: Dictionary = _family_publication_leases.get(chunk, {})
				var family_lease: Dictionary = lease_row.get(String(family_value), {})
				_release_source_publication_lease(String(family_lease.get("leaseToken", "")))
				lease_row.erase(String(family_value))
				if lease_row.is_empty():
					_family_publication_leases.erase(chunk)
				else:
					_family_publication_leases[chunk] = lease_row
		if family_map.is_empty():
			_family_domains.erase(chunk)
		if family_map.is_empty() and not _domains.has(chunk):
			var lease_row: Dictionary = _catalog_domain_leases.get(chunk, {})
			_release_catalog_lease(String(lease_row.get("leaseToken", "")))
			_catalog_domain_leases.erase(chunk)
			_release_family_publication_leases(chunk)


func reset() -> void:
	_release_all_catalog_leases()
	_release_tree_overlay_publication_leases()
	_domains.clear()
	_family_domains.clear()
	_family_band_receipts.clear()
	_tree_source_family_band_authorities.clear()
	_tree_section_geometry_overlays.clear()
	_retired_tree_section_overlays.clear()
	_detached_tree_sections.clear()
	_sources.clear()
	_postings_by_section.clear()
	_retired_postings_by_section.clear()
	_required_domains_by_section.clear()
	_required_families_by_section.clear()
	_latest_query_by_section.clear()
	_receipt_by_section.clear()
	_source_census_certificate_by_section.clear()
	_section_index_revision.clear()
	_next_source_index_revision += 1
	_world_id = ""
	_catalog_resolver = null
	_world_epoch = -1


func query_section(world_id: String, section_key: Vector3i) -> Dictionary:
	# A new query supersedes cached acknowledgement authority even when it finds
	# a pending dependency. Keep postings and installed visuals, but do not let an
	# earlier ready query authorize a receipt after freshness became unknown.
	_latest_query_by_section.erase(section_key)
	if world_id != _world_id or _world_id.is_empty():
		return _pending("ecology_support_query_world_stale", section_key)
	var census_value: Variant = _source_census_certificate_by_section.get(section_key, null)
	if not census_value is Dictionary or not _census_certificate_current(
			census_value, section_key):
		return _pending("ecology_support_influence_census_unproven", section_key)
	var census_policy_digest := String(census_value.get("influencePolicyDigest", ""))
	if census_policy_digest.is_empty():
		return _pending("ecology_support_influence_policy_digest_missing", section_key)
	var required_value: Variant = _required_domains_by_section.get(section_key, null)
	if not required_value is Array or (required_value.is_empty() \
			and not _required_families_by_section.has(section_key)):
		return _pending("ecology_support_influence_domain_missing", section_key)
	var domain_rows: Array[Dictionary] = []
	var band_receipt_rows: Array[Dictionary] = []
	var tree_authority_rows: Array[Dictionary] = []
	var tree_overlay_rows: Array[Dictionary] = []
	var tree_overlay_receipts: Array[Dictionary] = []
	# Several family rows can share one admitted source publication. Recheck its
	# terrain/structure/removal dependencies once for this section query, while
	# still validating each family lease independently below.
	var local_currentness_by_publication: Dictionary = {}
	if _required_families_by_section.has(section_key):
		var required_by_family: Dictionary = _required_families_by_section[section_key]
		for family_value: Variant in ProducerDomain.REQUIRED_CATEGORIES:
			var family := String(family_value)
			var family_keys: Array = required_by_family.get(family, [])
			for key_value: Variant in family_keys:
				var key: Vector2i = key_value
				if family == "trees":
					var overlay_authority: Dictionary = _tree_source_family_band_authorities.get(
						key, {}).get(section_key, {})
					var overlay: Dictionary = _tree_section_geometry_overlays.get(
						key, {}).get(section_key, {})
					var overlay_lease: Dictionary = _tree_overlay_publication_leases.get(
						key, {}).get(section_key, {})
					if _tree_section_overlay_current(overlay_authority, overlay,
							overlay_lease, world_id, key, section_key):
						if String(overlay_authority.get("influencePolicyDigest", "")) \
								!= census_policy_digest:
							return _pending("ecology_tree_overlay_policy_stale", section_key,
								{"sourceChunkKey":key})
						tree_authority_rows.append(overlay_authority)
						tree_overlay_receipts.append(overlay)
						for row_value: Variant in overlay.get("supportRows", []):
							if row_value is Dictionary:
								tree_overlay_rows.append(row_value)
						var retired_rows: Array = _retired_tree_section_overlays.get(section_key, [])
						for retired_value: Variant in retired_rows:
							if retired_value is Dictionary and retired_value.get(
									"sourceChunkKey", null) == key:
								tree_overlay_rows.append(retired_value)
						continue
				var family_map: Dictionary = _family_domains.get(key, {})
				var domain_value: Variant = family_map.get(family, null)
				if not domain_value is Dictionary or not _valid_family_domain(
						domain_value, key, family, local_currentness_by_publication):
					var publication_id := String(domain_value.get("publicationId", "")) \
						if domain_value is Dictionary else ""
					var local_currentness: Dictionary = local_currentness_by_publication.get(
						publication_id, {})
					if not local_currentness.is_empty() \
							and String(local_currentness.get("status", "")) != "ready":
						return _pending(String(local_currentness.get("reason",
							"ecology_support_source_local_dependencies_pending")), section_key, {
							"sourceChunkKey":key, "family":family,
							"publicationId":publication_id})
					return _pending("ecology_support_source_family_incomplete", section_key,
						{"sourceChunkKey":key, "family":family})
				if String(domain_value.get("influencePolicyDigest", "")) != census_policy_digest:
					return _pending("ecology_support_source_policy_stale", section_key,
						{"sourceChunkKey":key, "family":family})
				var band_receipt: Variant = _family_band_receipts.get(key, {}).get(
					family, {}).get(section_key, null)
				var expected_band: Dictionary = _expected_source_family_section_band_projection(
					key, section_key, family, domain_value)
				if not band_receipt is Dictionary or not _valid_family_band_receipt(
					band_receipt, domain_value, expected_band, key, family, section_key):
					return _pending_band_projection_incomplete(section_key, key, family,
						{"sourceChunkKey":key, "family":family,
						"bandKey":section_key,
						"bandReceiptPresent":band_receipt is Dictionary})
				band_receipt_rows.append(band_receipt)
				domain_rows.append(domain_value)
	else:
		for key: Vector2i in required_value:
			var domain_value: Variant = _domains.get(key, null)
			if not domain_value is Dictionary or not _valid_domain(domain_value, key):
				return _pending("ecology_support_source_domain_incomplete", section_key,
					{"sourceChunkKey":key})
			if String(domain_value.get("influencePolicyDigest", "")) != census_policy_digest:
				return _pending("ecology_support_source_policy_stale", section_key,
					{"sourceChunkKey":key})
			domain_rows.append(domain_value)
	var contributors: Array[Dictionary] = []
	var support_owner_demands: Array[Dictionary] = []
	var seen: Dictionary = {}
	var current_overlay_by_chunk_member: Dictionary = {}
	var overlay_geometry_digest_by_chunk: Dictionary = {}
	for overlay_receipt: Dictionary in tree_overlay_receipts:
		var overlay_chunk: Vector2i = overlay_receipt.get("sourceChunkKey", Vector2i.ZERO)
		current_overlay_by_chunk_member[overlay_chunk] = {}
		overlay_geometry_digest_by_chunk[overlay_chunk] = String(overlay_receipt.get("geometryDigest", ""))
		for row_value: Variant in overlay_receipt.get("supportRows", []):
			if row_value is Dictionary:
				(current_overlay_by_chunk_member[overlay_chunk] as Dictionary)[_row_key(row_value)] = true
	for row_map in [_postings_by_section.get(section_key, {}),
			_retired_postings_by_section.get(section_key, {})]:
		if not row_map is Dictionary:
			continue
		for source_id_value: Variant in row_map:
			var source_id := String(source_id_value)
			var row: Dictionary = row_map[source_id]
			if String(row.get("family", "")) == "trees" \
					and current_overlay_by_chunk_member.has(row.get("sourceChunkKey", null)):
				var chunk_member_map: Dictionary = current_overlay_by_chunk_member[
					row.get("sourceChunkKey", Vector2i.ZERO)]
				if chunk_member_map.has(_row_key(row)):
					continue
				row = _tree_overlay_row_as_tombstone(row,
					String(overlay_geometry_digest_by_chunk.get(
						row.get("sourceChunkKey", Vector2i.ZERO), "")))
			var contributor_key := "%s|%s|%s" % [_row_key(row),
				String(row.get("sourceRevision", "")), String(row.get("state", ""))]
			if String(row.get("state", "")) == "tombstoned":
				contributor_key += "|" + String(row.get("tombstoneRevision", ""))
			if seen.has(contributor_key):
				continue
			seen[contributor_key] = true
			contributors.append(row)
	for overlay_row: Dictionary in tree_overlay_rows:
		var overlay_key := _row_key(overlay_row)
		# New overlay rows replace old tree rows only for their source chunk. Old
		# rows remain in the retired set as exact absence demands until ack.
		var contributor_key := "%s|%s|%s" % [overlay_key,
			String(overlay_row.get("sourceRevision", "")),
			String(overlay_row.get("state", ""))]
		if seen.has(contributor_key): continue
		seen[contributor_key] = true
		contributors.append(overlay_row)
	contributors.sort_custom(_row_less)
	domain_rows.sort_custom(_domain_less)
	band_receipt_rows.sort_custom(_band_receipt_less)
	var digest_rows: Array = []
	for row: Dictionary in contributors:
		digest_rows.append(_stable_source_tuple(row))
	var canonical_domains: Array = []
	for domain: Dictionary in domain_rows:
		canonical_domains.append(_stable_domain_tuple(domain))
	var canonical_band_receipts: Array = []
	for band_receipt: Dictionary in band_receipt_rows:
		canonical_band_receipts.append(_stable_band_receipt_tuple(band_receipt))
	var canonical_tree_overlays: Array = []
	for overlay: Dictionary in tree_overlay_receipts:
		canonical_tree_overlays.append([overlay.get("sourceChunkKey", Vector2i.ZERO),
			overlay.get("sectionKey", Vector3i.ZERO),
			String(overlay.get("authorityDigest", "")),
			String(overlay.get("geometryDigest", "")),
			String(overlay.get("ownerMemberDigest", "")),
			String(overlay.get("supportMemberDigest", "")),
			String(overlay.get("producerSourceIdsDigest", "")),
			String(overlay.get("compiledArtifactDigest", "")),
			String(overlay.get("compiledBatchDigest", "")),
			String(overlay.get("sourceCompletionDigest", "")),
			String(overlay.get("ownerBatchPayloadDigest", "")),
			String(overlay.get("resourceBindingDigest", ""))])
	canonical_tree_overlays.sort_custom(func(a: Array, b: Array) -> bool:
		var ak: Vector2i = a[0]
		var bk: Vector2i = b[0]
		return ak.x < bk.x if ak.x != bk.x else ak.y < bk.y)
	var canonical_tree_authorities: Array = []
	for authority: Dictionary in tree_authority_rows:
		canonical_tree_authorities.append([authority.get("sourceChunkKey", Vector2i.ZERO),
			authority.get("sectionKey", Vector3i.ZERO),
			String(authority.get("authorityDigest", "")),
			String(authority.get("sourcePublicationId", "")),
			String(authority.get("sourceRevision", "")),
			String(authority.get("sourceFamilyRevision", "")),
			String(authority.get("sourceFamilyManifestDigest", "")),
			String(authority.get("producerBandManifestDigest", "")),
			String(authority.get("producerSourceIdsDigest", "")),
			String(authority.get("removedSourceProjectionDigest", ""))])
	canonical_tree_authorities.sort_custom(func(a: Array, b: Array) -> bool:
		var ak: Vector2i = a[0]
		var bk: Vector2i = b[0]
		return ak.x < bk.x if ak.x != bk.x else ak.y < bk.y)
	var section_revision := _section_revision(section_key)
	var coverage_digest := _sha256_bytes(var_to_bytes([
		CERTIFICATE_SCHEMA, world_id,
		[section_key.x, section_key.y, section_key.z], section_revision,
		canonical_domains, canonical_band_receipts, canonical_tree_authorities,
		canonical_tree_overlays, digest_rows]))
	if coverage_digest.is_empty():
		return _pending("ecology_support_coverage_digest_failed", section_key)
	for row: Dictionary in contributors:
		var lease := _support_owner_lease(row, section_key, world_id,
			section_revision, coverage_digest)
		if lease.is_empty():
			return _pending("ecology_support_owner_lease_unprovable", section_key,
				{"sourceId":String(row.get("sourceId", "")),
				"memberId":String(row.get("sourcePartId", ""))})
		support_owner_demands.append(lease)
	support_owner_demands.sort_custom(_demand_less)
	var certificate := {"schema":CERTIFICATE_SCHEMA, "worldId":world_id,
		"sectionKey":section_key, "sourceIndexRevision":section_revision,
		"coverageDigest":coverage_digest, "sourceDomains":domain_rows.duplicate(),
		"sourceFamilyBandReceipts":band_receipt_rows.duplicate(),
		"treeSourceFamilyBandAuthorities":tree_authority_rows.duplicate(),
		"treeSectionGeometryOverlays":tree_overlay_receipts.duplicate(),
		"influencePolicyRevision":INFLUENCE_POLICY_REVISION}
	_deep_freeze(certificate)
	var result := {"status":"ready", "schema":QUERY_SCHEMA,
		"sectionKey":section_key, "worldId":world_id,
		"sourceIndexRevision":section_revision,
		"coverageCertificate":certificate,
		"contributors":contributors, "supportOwnerDemands":support_owner_demands}
	_deep_freeze(result)
	_latest_query_by_section[section_key] = result
	return result


func validate_coverage_certificate(certificate: Dictionary, world_id: String,
		section_key: Vector3i) -> Dictionary:
	if String(certificate.get("schema", "")) != CERTIFICATE_SCHEMA \
			or String(certificate.get("worldId", "")) != world_id \
			or certificate.get("sectionKey", null) != section_key:
		return {"status":"failed", "reason":"ecology_support_certificate_identity_invalid"}
	var current := query_section(world_id, section_key)
	if current.get("status") != "ready":
		return current
	var expected: Dictionary = current.coverageCertificate
	if int(certificate.get("sourceIndexRevision", -1)) != int(expected.sourceIndexRevision) \
			or String(certificate.get("coverageDigest", "")) != String(expected.coverageDigest) \
			or certificate.get("sourceDomains", []) != expected.get("sourceDomains", []):
		return {"status":"pending", "reason":"ecology_support_certificate_stale",
			"sourceIndexRevision":_section_revision(section_key)}
	return {"status":"ready", "sourceIndexRevision":_section_revision(section_key),
		"coverageDigest":String(expected.coverageDigest)}


## Accept a receipt only for the exact latest section index revision. Tombstones
## become reclaimable only after the native owner confirms the replacement.
func acknowledge_section_receipt(section_key: Vector3i, source_index_revision: int,
		installed_receipt: Dictionary) -> Dictionary:
	var fresh_query := query_section(_world_id, section_key)
	if String(fresh_query.get("status", "")) != "ready":
		return {"status":"pending", "reason":String(fresh_query.get("reason",
			"ecology_support_receipt_source_freshness_pending")),
			"sectionKey":section_key}
	var query_value: Variant = _latest_query_by_section.get(section_key, null)
	if not query_value is Dictionary or query_value.get("status", "") != "ready" \
			or int(query_value.get("sourceIndexRevision", -1)) != source_index_revision:
		return {"status":"pending", "reason":"ecology_support_receipt_revision_stale"}
	if String(installed_receipt.get("schema", "")) != \
			"ecology-support-section-install-receipt/v1":
		return {"status":"pending", "reason":"ecology_support_receipt_schema_invalid"}
	var receipt_section: Variant = installed_receipt.get("sectionKey", null)
	var receipt_revision := int(installed_receipt.get("sourceIndexRevision", -1))
	var expected_coverage := String(query_value.coverageCertificate.coverageDigest)
	if receipt_section != section_key or receipt_revision != source_index_revision \
			or String(installed_receipt.get("coverageDigest", "")) != expected_coverage \
			or not installed_receipt.get("nativeReceipt", null) is Dictionary \
			or (installed_receipt.get("nativeReceipt", {}) as Dictionary).is_empty():
		return {"status":"pending", "reason":"ecology_support_receipt_invalid"}
	var member_receipts: Variant = installed_receipt.get("installedMemberReceipts", null)
	if not member_receipts is Array:
		return {"status":"pending", "reason":"ecology_support_member_receipt_missing"}
	var expected_members: Array = []
	var expected_absent_members: Array = []
	for lease_value: Variant in query_value.get("supportOwnerDemands", []):
		if not lease_value is Dictionary:
			continue
		var member_identity := [String(lease_value.get("sourceId", "")),
			String(lease_value.get("sourceRevision", "")),
			String(lease_value.get("memberId", "")),
			lease_value.get("ownerSectionKey", Vector3i.ZERO),
			String(lease_value.get("supportLeaseToken", ""))]
		match String(lease_value.get("state", "")):
			"compiled": expected_members.append(member_identity)
			"tombstoned": expected_absent_members.append(member_identity)
			"pending_recipe":
				return {"status":"pending", "reason":"ecology_support_pending_recipe_unresolved",
					"sourceId":String(lease_value.get("sourceId", "")),
					"memberId":String(lease_value.get("memberId", ""))}
	var received_members: Array = []
	for member_value: Variant in member_receipts:
		if not member_value is Dictionary:
			return {"status":"pending", "reason":"ecology_support_member_receipt_invalid"}
		var member: Dictionary = member_value
		received_members.append([String(member.get("sourceId", "")),
			String(member.get("sourceRevision", "")),
			String(member.get("memberId", "")),
			member.get("ownerSectionKey", Vector3i.ZERO),
			String(member.get("supportLeaseToken", ""))])
	expected_members.sort_custom(_array_identity_less)
	received_members.sort_custom(_array_identity_less)
	if expected_members != received_members:
		return {"status":"pending", "reason":"ecology_support_member_receipt_mismatch",
			"expectedMemberCount":expected_members.size(),
			"receivedMemberCount":received_members.size()}
	var absent_member_receipts: Variant = installed_receipt.get(
		"verifiedAbsentMemberReceipts", null)
	if not absent_member_receipts is Array:
		return {"status":"pending", "reason":"ecology_support_tombstone_absence_missing"}
	var received_absent_members: Array = []
	for member_value: Variant in absent_member_receipts:
		if not member_value is Dictionary:
			return {"status":"pending", "reason":"ecology_support_tombstone_absence_invalid"}
		var member: Dictionary = member_value
		received_absent_members.append([String(member.get("sourceId", "")),
			String(member.get("sourceRevision", "")),
			String(member.get("memberId", "")),
			member.get("ownerSectionKey", Vector3i.ZERO),
			String(member.get("supportLeaseToken", ""))])
	expected_absent_members.sort_custom(_array_identity_less)
	received_absent_members.sort_custom(_array_identity_less)
	if expected_absent_members != received_absent_members:
		return {"status":"pending", "reason":"ecology_support_tombstone_absence_mismatch",
			"expectedAbsentMemberCount":expected_absent_members.size(),
			"receivedAbsentMemberCount":received_absent_members.size()}
	var retired: Dictionary = _retired_postings_by_section.get(section_key, {})
	var retired_count := retired.size()
	retired.clear()
	_retired_postings_by_section.erase(section_key)
	var retired_tree_rows: Array = _retired_tree_section_overlays.get(section_key, [])
	var retired_tree_count := retired_tree_rows.size()
	_retired_tree_section_overlays.erase(section_key)
	for lease_chunk_value: Variant in _tree_overlay_publication_leases.keys().duplicate():
		var lease_chunk: Vector2i = lease_chunk_value
		var leases: Dictionary = _tree_overlay_publication_leases[lease_chunk]
		if not leases.has(section_key): continue
		var lease_row: Dictionary = leases[section_key]
		for token_value: Variant in lease_row.get("retiredLeaseTokens", []):
			_release_source_publication_lease(String(token_value))
		lease_row["retiredLeaseTokens"] = []
		leases[section_key] = lease_row
		_tree_overlay_publication_leases[lease_chunk] = leases
	_receipt_by_section[section_key] = {"sourceIndexRevision":source_index_revision,
		"receiptId":String(installed_receipt.nativeReceipt.get("receiptId",
			_sha256_bytes(var_to_bytes(installed_receipt.nativeReceipt)))),
		"treeOverlayCount":query_value.coverageCertificate.get(
			"treeSectionGeometryOverlays", []).size()}
	return {"status":"ready", "sectionKey":section_key,
		"sourceIndexRevision":source_index_revision,
		"retiredTombstoneCount":retired_count + retired_tree_count}


func _validate_source_row(row: Dictionary, world_id: String,
		source_chunk_key: Vector2i, source_revision: String,
		runtime_policy: Dictionary) -> Dictionary:
	var source_id := String(row.get("sourceId", ""))
	var kind := String(row.get("kind", ""))
	var state := String(row.get("state", ""))
	var bounds_value: Variant = row.get("conservativeWorldBounds", null)
	var geometry_owner: Variant = row.get("geometryOwnerSection", null)
	var support_value: Variant = row.get("conservativeSupportSectionKeys", null)
	if source_id.is_empty() or kind not in ["tree", "static_prop", "surface_detail"] \
		or state not in ["pending_recipe", "compiled", "tombstoned"] \
			or not bounds_value is AABB or not _valid_bounds(bounds_value) \
		or not geometry_owner is Vector3i or String(row.get("sourcePartId", "")).is_empty() \
			or not support_value is Array \
			or support_value.is_empty() \
			or not _certified_envelope_matches(row, world_id, runtime_policy):
		return {"status":"pending", "reason":"ecology_support_source_row_uncertified",
			"sourceId":source_id}
	var expected_support := Grid.keys_intersecting_bounds(bounds_value)
	var supplied: Array[Vector3i] = []
	for key_value: Variant in support_value:
		if not key_value is Vector3i or key_value in supplied:
			return {"status":"pending", "reason":"ecology_support_source_sections_invalid",
				"sourceId":source_id}
		supplied.append(key_value)
	supplied.sort_custom(_section_less)
	expected_support.sort_custom(_section_less)
	if supplied != expected_support or geometry_owner != Grid.key_for_world_position(bounds_value.get_center()):
		return {"status":"pending", "reason":"ecology_support_source_envelope_mismatch",
			"sourceId":source_id}
	var family := String(row.get("family", "trees" if kind == "tree" else ""))
	var source_origin: Variant = row.get("sourceOrigin", null)
	if not source_origin is Vector3:
		return {"status":"pending", "reason":"ecology_support_source_origin_missing",
			"sourceId":source_id}
	var bounds_policy := ProducerDomain.validate_source_bounds(family,
		source_origin, bounds_value, runtime_policy)
	if bounds_policy.get("status") != "ready":
		return {"status":"pending", "reason":"ecology_support_source_policy_unproven",
			"sourceId":source_id, "family":family,
			"policyEvidence":bounds_policy}
	var copy := row.duplicate(true)
	copy["schema"] = SOURCE_SCHEMA
	copy["worldId"] = world_id
	copy["sourceChunkKey"] = source_chunk_key
	copy["sourceDomainRevision"] = source_revision
	copy["sourceRevision"] = String(row.get("sourceRevision", source_revision))
	copy["family"] = family
	copy["supportSectionKeys"] = supplied.duplicate()
	copy.make_read_only()
	return {"status":"ready", "row":copy}


func _support_owner_lease(row: Dictionary, support_section: Vector3i,
		world_id: String, section_revision: int, coverage_digest: String) -> Dictionary:
	var member_id := String(row.get("sourcePartId", ""))
	var source_id := String(row.get("sourceId", ""))
	var source_revision := String(row.get("sourceRevision", ""))
	var owner_section: Variant = row.get("geometryOwnerSection", null)
	var chunk: Variant = row.get("sourceChunkKey", null)
	if member_id.is_empty() or source_id.is_empty() or source_revision.is_empty() \
			or not owner_section is Vector3i or not chunk is Vector2i:
		return {}
	var identity := [OWNER_LEASE_SCHEMA, world_id,
		[support_section.x, support_section.y, support_section.z],
		[chunk.x, chunk.y], source_id, source_revision,
		member_id, int(row.get("artifactGeneration", 0)),
		String(row.get("family", "")),
		String(row.get("familyRevision", "")),
		String(row.get("familyPolicyRevision", "")),
		String(row.get("familyPolicyDigest", "")),
		String(row.get("catalogArtifactId", "")),
		String(row.get("catalogContentDigest", "")),
		String(row.get("publicationOwnerReceiptDigest", "")),
		int(row.get("worldEpoch", -1)),
		[owner_section.x, owner_section.y, owner_section.z],
		coverage_digest, String(row.get("sourceDomainRevision", "")),
		String(row.get("producerSnapshotRevision", "")),
		String(row.get("certifiedEnvelopeDigest", "")),
		String(row.get("influencePolicyRevision", "")),
		String(row.get("influencePolicyDigest", ""))]
	if String(row.get("state", "")) == "tombstoned":
		identity.append(String(row.get("tombstoneRevision", "")))
	var token := _sha256_bytes(var_to_bytes(identity))
	if token.is_empty(): return {}
	return {"schema":OWNER_LEASE_SCHEMA, "worldId":world_id,
		"sourceIndexRevision":section_revision,
		"coverageDigest":coverage_digest,
		"supportSectionKey":support_section, "sourceChunkKey":chunk,
		"sourceDomainRevision":String(row.get("sourceDomainRevision", "")),
		"producerSnapshotRevision":String(row.get("producerSnapshotRevision", "")),
		"family":String(row.get("family", "")),
		"familyRevision":String(row.get("familyRevision", "")),
		"familyPolicyRevision":String(row.get("familyPolicyRevision", "")),
		"familyPolicyDigest":String(row.get("familyPolicyDigest", "")),
		"catalogArtifactId":String(row.get("catalogArtifactId", "")),
		"catalogContentDigest":String(row.get("catalogContentDigest", "")),
		"publicationOwnerReceiptDigest":String(row.get("publicationOwnerReceiptDigest", "")),
		"worldEpoch":int(row.get("worldEpoch", -1)),
		"terrainVolumeChunkRevision":String(row.get("terrainVolumeChunkRevision", "")),
		"structureAdmissionRevision":String(row.get("structureAdmissionRevision", "")),
		"removedSourceProjectionDigest":String(row.get("removedSourceProjectionDigest", "")),
		"influencePolicyRevision":String(row.get("influencePolicyRevision", "")),
		"influencePolicyDigest":String(row.get("influencePolicyDigest", "")),
		"sourceId":source_id, "sourceRevision":source_revision,
		"memberId":member_id,
		"kind":String(row.get("kind", "")),
		"certifiedEnvelopeDigest":String(row.get("certifiedEnvelopeDigest", "")),
		"tombstoneRevision":String(row.get("tombstoneRevision", "")),
		"recipeArtifactGeneration":int(row.get("artifactGeneration", 0)),
		"ownerSectionKey":owner_section,
		"supportLeaseToken":token, "state":String(row.get("state", "pending_recipe"))}


func _certified_envelope_matches(row: Dictionary, world_id: String,
		runtime_policy: Dictionary) -> bool:
	var proof_value: Variant = row.get("certifiedEnvelopeProof", null)
	if not proof_value is Dictionary:
		return false
	var proof: Dictionary = proof_value
	var bounds: Variant = row.get("conservativeWorldBounds", null)
	if not bounds is AABB or not _valid_bounds(bounds):
		return false
	var static_bounds: AABB = bounds
	var kind := String(row.get("kind", ""))
	if kind in ["static_prop", "surface_detail"]:
		var family := String(row.get("family", ""))
		if family not in ["surface_rocks", "ore", "forage", "details", "underground_props"]:
			return false
		var family_policy: Variant = runtime_policy.get("families", {}).get(family, null)
		var source_domain_revision := String(row.get("sourceDomainRevision", ""))
		var producer_snapshot_revision := String(row.get("producerSnapshotRevision", ""))
		var resource_descriptor_revision := String(row.get("resourceDescriptorRevision", ""))
		var static_mesh_digest := String(row.get("meshContentDigest", ""))
		var static_policy_revision := String(runtime_policy.get("revision", ""))
		var static_policy_digest := String(runtime_policy.get("digest", ""))
		if not family_policy is Dictionary or String(family_policy.get("status", "")) != "bounded" \
				or source_domain_revision.is_empty() or producer_snapshot_revision.is_empty() \
				or resource_descriptor_revision.is_empty() or static_mesh_digest.length() != 64 \
				or static_policy_revision.is_empty() or static_policy_digest.length() != 64 \
				or String(proof.get("schema", "")) != STATIC_MEMBER_ENVELOPE_SCHEMA \
				or String(proof.get("status", "")) != "ready" \
				or String(proof.get("worldId", "")) != world_id \
				or String(proof.get("sourceId", "")) != String(row.get("sourceId", "")) \
				or String(proof.get("sourcePartId", "")) != String(row.get("sourcePartId", "")) \
				or String(proof.get("family", "")) != family \
				or proof.get("worldBounds", null) != bounds \
				or String(proof.get("meshContentDigest", "")) != static_mesh_digest \
				or String(proof.get("policyRevision", "")) != static_policy_revision \
				or String(proof.get("policyDigest", "")) != static_policy_digest \
				or String(proof.get("sourceDomainRevision", "")) != source_domain_revision \
				or String(proof.get("producerSnapshotRevision", "")) != producer_snapshot_revision \
				or String(proof.get("resourceDescriptorRevision", "")) != resource_descriptor_revision:
			return false
		var expected_static_digest := ProducerDomain.static_member_envelope_digest(world_id,
			String(row.get("sourceId", "")), String(row.get("sourcePartId", "")),
			family, static_bounds, static_mesh_digest, static_policy_revision, static_policy_digest,
			source_domain_revision, producer_snapshot_revision,
			resource_descriptor_revision)
		return expected_static_digest.length() == 64 \
			and String(proof.get("digest", "")) == expected_static_digest \
			and String(row.get("certifiedEnvelopeDigest", "")) == expected_static_digest
	if kind != "tree":
		return false
	var mesh_digest := String(proof.get("meshContentDigest", ""))
	var policy_revision := String(proof.get("policyRevision", ""))
	var tree_envelope: Variant = runtime_policy.get("treeEnvelope", null)
	var wind_envelope: Variant = tree_envelope.get("visualWindEnvelope", null) \
		if tree_envelope is Dictionary else null
	if not wind_envelope is Dictionary or String(wind_envelope.get("status", "")) != "ready":
		return false
	var active_wind_digest := String(wind_envelope.get("digest", ""))
	var proof_wind_digest := String(proof.get("activeWindEnvelopeDigest", ""))
	var expected := _sha256_bytes(var_to_bytes([
		"ecology-certified-member-envelope/v2", world_id,
		String(row.get("sourceId", "")), String(row.get("sourcePartId", "")),
		bounds, mesh_digest, policy_revision,
		String(row.get("recipeSignature", "")), int(row.get("artifactGeneration", 0)),
		active_wind_digest]))
	return mesh_digest.length() == 64 and policy_revision == TREE_MEMBER_SUPPORT_POLICY \
		and active_wind_digest.length() == 64 and proof_wind_digest == active_wind_digest \
		and expected.length() == 64 \
		and String(proof.get("digest", "")) == expected \
		and String(row.get("certifiedEnvelopeDigest", "")) == expected


func _census_certificate_current(census: Dictionary, section_key: Vector3i) -> bool:
	if String(census.get("schema", "")).is_empty() \
			or String(census.get("status", "")) != "ready" \
			or census.get("sectionKey", null) != section_key:
		return false
	var artifact_id := String(census.get("catalogArtifactId", ""))
	var content_digest := String(census.get("catalogContentDigest", ""))
	var leases: Dictionary = _catalog_census_leases.get(section_key, {})
	var lease_row: Dictionary = leases.get(artifact_id, {})
	if artifact_id.is_empty() or content_digest.length() != 64 \
			or lease_row.is_empty() \
			or String(lease_row.get("catalogContentDigest", "")) != content_digest:
		return false
	var resolved := _resolve_catalog_lease(String(lease_row.get("leaseToken", "")))
	if resolved.get("status") != "ready" \
			or String(resolved.get("catalogArtifactId", "")) != artifact_id \
			or String(resolved.get("catalogContentDigest", "")) != content_digest:
		return false
	var compact_inputs: Variant = census.get("sourceInputs", null)
	if not compact_inputs is Dictionary \
			or String(compact_inputs.get("schema", "")) != "ecology-source-domain-inputs/v2" \
			or String(compact_inputs.get("catalogArtifactId", "")) != artifact_id \
			or String(compact_inputs.get("catalogContentDigest", "")) != content_digest \
			or int(compact_inputs.get("worldEpoch", -1)) != _world_epoch:
		return false
	var expected := ProducerDomain.source_domain_census_certificate(section_key,
		compact_inputs, resolved.artifact)
	if not ProducerDomain.validate_source_domain_census_certificate(
			census, section_key, {}, resolved.artifact):
		return false
	for field: String in ["influencePolicyRevision", "influencePolicyDigest",
			"sourceChunkSizeMeters", "sourceOriginDomainFootprintMeters",
			"maxHorizontalSupportMeters", "sourceChunkKeysDigest"]:
		if census.get(field, null) != expected.get(field, null): return false
	return census.get("sourceChunkKeys", null) == expected.get("sourceChunkKeys", null) \
		and census.get("sourceChunkKeysByFamily", null) == expected.get("sourceChunkKeysByFamily", null) \
		and String(census.get("status", "")) == "ready"


func _valid_domain(domain: Dictionary, key: Vector2i) -> bool:
	var compact_inputs: Variant = domain.get("sourceInputs", null)
	var lease_row: Dictionary = _catalog_domain_leases.get(key, {})
	if not compact_inputs is Dictionary \
			or String(compact_inputs.get("schema", "")) != "ecology-source-domain-inputs/v2" \
			or lease_row.is_empty() \
			or int(compact_inputs.get("worldEpoch", -1)) != _world_epoch:
		return false
	var resolved := _resolve_catalog_lease(String(lease_row.get("leaseToken", "")))
	if resolved.get("status") != "ready" \
			or String(resolved.get("catalogArtifactId", "")) \
			!= String(compact_inputs.get("catalogArtifactId", "")) \
			or String(resolved.get("catalogContentDigest", "")) \
			!= String(compact_inputs.get("catalogContentDigest", "")):
		return false
	var runtime_policy: Dictionary = resolved.supportPolicy
	return domain.get("sourceChunkKey", null) == key \
		and String(domain.get("worldId", "")) == _world_id \
		and String(domain.get("sourceRevision", "")) != "" \
		and String(domain.get("removedPropsRevision", "")).length() == 64 \
		and String(domain.get("producerSnapshotRevision", "")) != "" \
		and bool(domain.get("producerComplete", false)) \
		and int(domain.get("enumeratedSourceCount", -1)) >= 0 \
		and domain.get("categoriesComplete", []) is Array \
		and String(domain.get("terrainVolumeChunkRevision", "")) != "" \
		and String(domain.get("structureAdmissionRevision", "")) != "" \
		and String(domain.get("structureAdmissionStatus", "")) in ["ready", "complete"] \
		and String(domain.get("removedSourceProjectionDigest", "")).length() == 64 \
		and String(domain.get("sourceManifestDigest", "")).length() == 64 \
		and String(domain.get("supportManifestDigest", "")).length() == 64 \
		and String(runtime_policy.get("status", "")) == "ready" \
		and String(domain.get("influencePolicyRevision", "")) == \
			String(runtime_policy.get("revision", "")) \
		and String(domain.get("influencePolicyDigest", "")) == \
			String(runtime_policy.get("digest", "")) \
		and String(compact_inputs.get("influencePolicyRevision", "")) == \
			String(runtime_policy.get("revision", "")) \
		and String(compact_inputs.get("influencePolicyDigest", "")) == \
			String(runtime_policy.get("digest", ""))


func _valid_family_domain(domain: Dictionary, key: Vector2i, family: String,
		local_currentness_by_publication: Dictionary = {}) -> bool:
	var compact_inputs: Variant = domain.get("sourceInputs", null)
	var family_leases: Dictionary = _family_publication_leases.get(key, {})
	var lease_row: Dictionary = family_leases.get(family, {})
	if not compact_inputs is Dictionary or lease_row.is_empty() \
			or String(domain.get("family", "")) != family \
			or String(domain.get("worldId", "")) != _world_id \
			or String(domain.get("familyRevision", "")).length() != 64 \
			or String(domain.get("sourceRevision", "")).is_empty() \
			or String(domain.get("familyPolicyRevision", "")).is_empty() \
			or String(domain.get("familyPolicyDigest", "")).length() != 64 \
			or String(domain.get("sourceManifestDigest", "")).length() != 64 \
			or String(compact_inputs.get("schema", "")) != "ecology-source-domain-inputs/v2" \
			or int(compact_inputs.get("worldEpoch", -1)) != _world_epoch:
		return false
	var token := String(lease_row.get("leaseToken", ""))
	var expected_view: Dictionary = lease_row.get("view", {})
	var resolve_started_usec := Time.get_ticks_usec()
	var resolved: Variant = _catalog_resolver.call("resolve_ecology_source_publication",
		token, _world_id, _world_epoch)
	_band_domain_resolve_call_count += 1
	_band_domain_resolve_elapsed_usec += Time.get_ticks_usec() - resolve_started_usec
	if not resolved is Dictionary or String(resolved.get("status", "")) != "ready" \
			or not is_same(resolved.get("view", null), expected_view) \
			or String(expected_view.get("publicationId", "")) \
			!= String(domain.get("publicationId", "")) \
			or String(domain.get("publicationContentDigest", "")) \
			!= String(expected_view.get("contentDigest", "")) \
			or String(domain.get("catalogArtifactId", "")) \
			!= String(expected_view.get("catalogArtifactId", "")) \
			or String(domain.get("catalogContentDigest", "")) \
			!= String(expected_view.get("ownerReceipt", {}).get("catalogContentDigest", "")) \
			or int(domain.get("worldEpoch", -1)) != _world_epoch \
			or String(domain.get("ownerReceiptDigest", "")) != \
			_owner_receipt_digest(expected_view.get("ownerReceipt", {})):
		return false
	var owner_current_started_usec := Time.get_ticks_usec()
	var owner_current: Variant = _catalog_resolver.call(
		"ecology_source_publication_is_current", token, _world_id, _world_epoch,
		expected_view.get("ownerReceipt", {}),
		String(expected_view.get("sourceDomainRevision", "")),
		String(expected_view.get("payload", {}).get("removedSourceProjectionDigest", "")))
	_band_owner_currentness_call_count += 1
	_band_owner_currentness_elapsed_usec += Time.get_ticks_usec() - owner_current_started_usec
	if not owner_current is Dictionary or String(owner_current.get("status", "")) != "ready":
		return false
	var publication_id := String(expected_view.get("publicationId", ""))
	var local_currentness: Dictionary = local_currentness_by_publication.get(
		publication_id, {})
	if local_currentness.is_empty():
		var local_currentness_started_usec := Time.get_ticks_usec()
		local_currentness = _catalog_resolver.call(
			"ecology_source_publication_local_is_current", expected_view, token)
		_band_local_currentness_call_count += 1
		_band_local_currentness_elapsed_usec += Time.get_ticks_usec() - local_currentness_started_usec
		if not local_currentness is Dictionary:
			local_currentness = {"status":"pending",
				"reason":"ecology_support_source_local_currentness_unavailable"}
		local_currentness_by_publication[publication_id] = local_currentness
	if String(local_currentness.get("status", "")) != "ready":
		return false
	var runtime_policy: Dictionary = expected_view.get("supportPolicy", {})
	var family_policy: Dictionary = expected_view.get("familySupportPoliciesById", {}).get(
		family, {})
	var family_result: Dictionary = expected_view.get("familyResultsById", {}).get(
		family, {})
	return domain.get("sourceChunkKey", null) == key \
		and bool(domain.get("complete", false)) \
		and String(domain.get("disposition", "")) in ["complete_nonempty", "complete_empty"] \
		and String(domain.get("sourceRevision", "")) == \
			String(expected_view.get("sourceDomainRevision", "")) \
		and String(family_policy.get("status", "")) == "ready" \
		and String(family_result.get("familyRevision", "")) == \
			String(domain.get("familyRevision", "")) \
		and String(family_result.get("sourceManifestDigest", "")) == \
			String(domain.get("sourceManifestDigest", "")) \
		and String(domain.get("familyPolicyRevision", "")) \
			== String(family_policy.get("familyPolicyRevision", family_policy.get("revision", ""))) \
		and String(domain.get("familyPolicyDigest", "")) \
			== String(family_policy.get("familyPolicyDigest", family_policy.get("digest", ""))) \
		and String(domain.get("influencePolicyDigest", "")) == String(runtime_policy.get("digest", "")) \
		and String(domain.get("terrainVolumeChunkRevision", "")) != "" \
		and String(domain.get("structureAdmissionRevision", "")) != "" \
		and String(domain.get("removedSourceProjectionDigest", "")).length() == 64


func _retire_source_to_tombstone(source_key: String, row: Dictionary,
		replacement_revision: String) -> void:
	var retired_supports: Array[Vector3i] = []
	for section_key: Vector3i in row.get("supportSectionKeys", []):
		# Keep every prior section demanded until an accepted receipt proves the
		# old revision is absent. A replacement may cover the same section while
		# its new representation is still compiling or awaiting installation.
		retired_supports.append(section_key)
		var postings: Dictionary = _postings_by_section.get(section_key, {})
		postings.erase(source_key)
	if retired_supports.is_empty():
		return
	var tombstone := row.duplicate(true)
	tombstone["state"] = "tombstoned"
	tombstone["supportSectionKeys"] = retired_supports
	tombstone["tombstoneRevision"] = _sha256_bytes(var_to_bytes([
		"ecology-support-source-tombstone/v2", _world_id,
		String(row.get("sourceId", "")), String(row.get("sourcePartId", "")),
		String(row.get("sourceRevision", "")), replacement_revision,
		String(row.get("family", "")), String(row.get("familyRevision", "")),
		String(row.get("familyPolicyRevision", "")),
		String(row.get("familyPolicyDigest", "")),
		String(row.get("familyManifestDigest", "")),
		String(row.get("catalogArtifactId", "")),
		String(row.get("catalogContentDigest", "")),
		String(row.get("publicationOwnerReceiptDigest", "")),
		int(row.get("worldEpoch", -1)),
		retired_supports]))
	tombstone.make_read_only()
	for section_key: Vector3i in retired_supports:
		if not _retired_postings_by_section.has(section_key):
			_retired_postings_by_section[section_key] = {}
		var retired: Dictionary = _retired_postings_by_section[section_key]
		retired[_retired_row_key(tombstone)] = tombstone


func _post_row(row: Dictionary) -> void:
	var source_id := _row_key(row)
	for section_key: Vector3i in row.get("supportSectionKeys", []):
		if not _postings_by_section.has(section_key):
			_postings_by_section[section_key] = {}
		var section_postings: Dictionary = _postings_by_section[section_key]
		section_postings[source_id] = row


func _stable_source_tuple(row: Dictionary) -> Array:
	return [String(row.get("sourceId", "")), String(row.get("sourcePartId", "")),
		String(row.get("sourceRevision", "")), Vector2i(row.get("sourceChunkKey", Vector2i.ZERO)),
		String(row.get("sourceDomainRevision", "")),
		String(row.get("producerSnapshotRevision", "")),
		String(row.get("family", "")),
		String(row.get("familyRevision", "")),
		String(row.get("familyPolicyRevision", "")),
		String(row.get("familyPolicyDigest", "")),
		String(row.get("catalogArtifactId", "")),
		String(row.get("catalogContentDigest", "")),
		int(row.get("worldEpoch", -1)),
		String(row.get("influencePolicyRevision", "")),
		String(row.get("influencePolicyDigest", "")),
		String(row.get("removedSourceProjectionDigest", "")),
		String(row.get("recipeSignature", "")),
		int(row.get("artifactGeneration", 0)), Vector3i(row.get("geometryOwnerSection", Vector3i.ZERO)),
		row.get("conservativeWorldBounds", AABB()),
		row.get("supportSectionKeys", []), String(row.get("state", "")),
		String(row.get("certifiedEnvelopeDigest", "")), String(row.get("tombstoneRevision", "")),
		String(row.get("publicationOwnerReceiptDigest", ""))]


func _same_source_content_ignoring_catalog_artifact(left: Dictionary,
		right: Dictionary) -> bool:
	var left_identity := _stable_source_tuple(left)
	var right_identity := _stable_source_tuple(right)
	# Owner/artifact transport changes can rebind identical current content without
	# retiring the visible member. Their new proof still changes the installed lease.
	left_identity[10] = ""
	right_identity[10] = ""
	left_identity[24] = ""
	right_identity[24] = ""
	return left_identity == right_identity


func _stable_domain_tuple(domain: Dictionary) -> Array:
	return [Vector2i(domain.get("sourceChunkKey", Vector2i.ZERO)),
		String(domain.get("family", "")),
		String(domain.get("worldId", "")), String(domain.get("sourceRevision", "")),
		String(domain.get("familyRevision", "")),
		String(domain.get("familyPolicyRevision", "")),
		String(domain.get("familyPolicyDigest", "")),
		String(domain.get("catalogArtifactId", "")),
		String(domain.get("catalogContentDigest", "")),
		String(domain.get("ownerReceiptDigest", "")),
		int(domain.get("worldEpoch", -1)),
		String(domain.get("removedPropsRevision", "")),
		String(domain.get("producerSnapshotRevision", "")),
		bool(domain.get("producerComplete", false)), int(domain.get("enumeratedSourceCount", -1)),
		domain.get("categoriesComplete", []),
		String(domain.get("terrainVolumeChunkRevision", "")),
		String(domain.get("structureAdmissionRevision", "")),
		String(domain.get("structureAdmissionStatus", "")),
		String(domain.get("removedSourceProjectionDigest", "")),
		String(domain.get("sourceManifestDigest", "")),
		String(domain.get("supportManifestDigest", "")),
		String(domain.get("influencePolicyRevision", "")),
		String(domain.get("influencePolicyDigest", ""))]


func _sha256_bytes(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK or context.update(bytes) != OK:
		return ""
	return context.finish().hex_encode()


func _pending(reason: String, section_key: Vector3i, extra := {}) -> Dictionary:
	var result := {"status":"pending", "reason":reason, "sectionKey":section_key,
		"worldId":_world_id, "sourceIndexRevision":_section_revision(section_key)}
	for key: Variant in extra:
		result[key] = extra[key]
	return result


## A missing or stale band proof cannot expose current contributors or authorize
## installation, but retired rows still need to drive an exact section refresh.
## Give those tombstones purpose-bound retry tokens tied to this pending section
## revision. The normal acknowledgement path remains unavailable until a ready
## query installs a current coverage certificate.
func _pending_band_projection_incomplete(section_key: Vector3i,
		source_chunk_key: Vector2i, family: String, extra: Dictionary) -> Dictionary:
	var result := _pending("ecology_support_source_family_band_incomplete",
		section_key, extra)
	var section_revision := _section_revision(section_key)
	var tombstones: Array[Dictionary] = []
	var retired: Variant = _retired_postings_by_section.get(section_key, {})
	if retired is Dictionary:
		for row_value: Variant in retired.values():
			if row_value is Dictionary and String(row_value.get("state", "")) == "tombstoned":
				tombstones.append(row_value)
	tombstones.sort_custom(_row_less)
	var tombstone_identity: Array = []
	for row: Dictionary in tombstones:
		tombstone_identity.append(_stable_source_tuple(row))
	var pending_digest := _sha256_bytes(var_to_bytes([
		"ecology-support-pending-band-tombstones/v1", _world_id,
		[section_key.x, section_key.y, section_key.z], section_revision,
		source_chunk_key, family, tombstone_identity]))
	var demands: Array[Dictionary] = []
	if not pending_digest.is_empty():
		for row: Dictionary in tombstones:
			var demand := _support_owner_lease(row, section_key, _world_id,
				section_revision, pending_digest)
			if demand.is_empty():
				continue
			demand["demandPurpose"] = "retryable_tombstone_refresh"
			demand["retryable"] = true
			demand["pendingReason"] = "ecology_support_source_family_band_incomplete"
			demand["pendingIdentity"] = pending_digest
			demand.make_read_only()
			demands.append(demand)
	demands.make_read_only()
	result["supportOwnerDemands"] = demands
	result["retryableTombstoneDemands"] = demands
	return result


func _invalidate_sections(sections: Dictionary) -> void:
	for section_value: Variant in sections:
		_latest_query_by_section.erase(section_value)


func _acquire_or_resolve_catalog_lease(artifact_id: String, owner_kind: String,
		owner_key: String, expected_content_digest: String,
		expected_policy_revision: String, expected_policy_digest: String,
		existing: Dictionary = {}, required_families: Array = []) -> Dictionary:
	if not is_instance_valid(_catalog_resolver) or _world_id.is_empty() \
			or _world_epoch < 0 or artifact_id.is_empty() \
			or expected_content_digest.length() != 64:
		return {"status":"pending", "reason":"ecology_catalog_resolver_or_identity_missing"}
	var reused := String(existing.get("catalogArtifactId", "")) == artifact_id \
		and String(existing.get("catalogContentDigest", "")) == expected_content_digest \
		and int(existing.get("worldEpoch", _world_epoch)) == _world_epoch
	var token := String(existing.get("leaseToken", "")) if reused else ""
	if token.is_empty():
		var owner: Variant = _catalog_resolver.call("acquire_ecology_catalog_artifact_lease",
			artifact_id, owner_kind, owner_key, _world_id, _world_epoch)
		if not owner is Dictionary or String(owner.get("status", "")) != "ready" \
				or String(owner.get("leaseToken", "")).is_empty():
			return {"status":"pending", "reason":"ecology_catalog_lease_acquire_pending"}
		token = String(owner.leaseToken)
	var resolved := _resolve_catalog_lease(token, not required_families.is_empty())
	if resolved.get("status") != "ready" and reused:
		# A cached owner row may outlive its resolver lease after an independent
		# artifact-store retirement. Reacquire the same exact artifact identity;
		# do not leave family demand permanently blocked on a dead token.
		_release_catalog_lease(token)
		var replacement_owner: Variant = _catalog_resolver.call(
			"acquire_ecology_catalog_artifact_lease", artifact_id, owner_kind,
			owner_key, _world_id, _world_epoch)
		if not replacement_owner is Dictionary \
				or String(replacement_owner.get("status", "")) != "ready" \
				or String(replacement_owner.get("leaseToken", "")).is_empty():
			return {"status":"pending", "reason":"ecology_catalog_lease_reacquire_pending"}
		token = String(replacement_owner.leaseToken)
		reused = false
		resolved = _resolve_catalog_lease(token, not required_families.is_empty())
	if resolved.get("status") != "ready" \
			or String(resolved.get("catalogArtifactId", "")) != artifact_id \
			or String(resolved.get("catalogContentDigest", "")) != expected_content_digest:
		if not reused: _release_catalog_lease(token)
		return {"status":"pending", "reason":"ecology_catalog_lease_resolution_stale"}
	var policy: Dictionary = resolved.supportPolicy
	if (required_families.is_empty() and String(policy.get("status", "")) != "ready") \
			or String(policy.get("revision", "")) != expected_policy_revision \
			or String(policy.get("digest", "")) != expected_policy_digest:
		if not reused: _release_catalog_lease(token)
		return {"status":"pending", "reason":"ecology_catalog_policy_digest_mismatch"}
	for family_value: Variant in required_families:
		var family := String(family_value)
		var family_policy := ProducerDomain.family_support_policy(
			resolved.catalogInputs, resolved.artifact, family)
		if String(family_policy.get("status", "")) != "ready":
			if not reused: _release_catalog_lease(token)
			return {"status":"pending", "reason":String(family_policy.get("reason",
				"ecology_requested_family_policy_pending")), "family":family}
	return {"status":"ready", "leaseToken":token, "reusedLease":reused,
		"catalogInputs":resolved.catalogInputs, "supportPolicy":policy,
		"artifact":resolved.get("artifact", {}),
		"catalogArtifactId":artifact_id, "catalogContentDigest":expected_content_digest}


func _resolve_catalog_lease(token: String, allow_family_scoped_pending := false) -> Dictionary:
	if token.is_empty() or not is_instance_valid(_catalog_resolver):
		return {"status":"pending", "reason":"ecology_catalog_lease_missing"}
	var resolved: Variant = _catalog_resolver.call("resolve_ecology_catalog_artifact",
		token, _world_id, _world_epoch)
	if not resolved is Dictionary or String(resolved.get("status", "")) != "ready":
		return {"status":"pending", "reason":"ecology_catalog_artifact_stale"}
	var inputs: Variant = resolved.get("catalogInputs", null)
	var policy: Variant = resolved.get("supportPolicy", null)
	var artifact: Variant = resolved.get("artifact", null)
	var resolved_artifact_id := String(resolved.get("catalogArtifactId", ""))
	var resolved_content_digest := String(resolved.get("catalogContentDigest", ""))
	if artifact is Dictionary:
		inputs = artifact.get("catalogInputs", inputs)
		policy = artifact.get("supportPolicy", policy)
		resolved_artifact_id = String(artifact.get("artifactId", resolved_artifact_id))
		resolved_content_digest = String(artifact.get("catalogContentDigest",
			resolved_content_digest))
		if String(artifact.get("worldId", "")) != _world_id \
				or int(artifact.get("worldEpoch", -1)) != _world_epoch:
			return {"status":"pending", "reason":"ecology_catalog_artifact_owner_stale"}
	if not inputs is Dictionary or not policy is Dictionary \
			or resolved_artifact_id.is_empty() \
			or resolved_content_digest.length() != 64:
		return {"status":"pending", "reason":"ecology_catalog_artifact_value_invalid"}
	if (not allow_family_scoped_pending and String(policy.get("status", "")) != "ready") \
			or (allow_family_scoped_pending and String(policy.get("status", "")) \
				not in ["ready", "pending"]) \
			or String(policy.get("digest", "")).length() != 64 \
			or String(policy.get("revision", "")).is_empty():
		return {"status":"pending", "reason":"ecology_catalog_artifact_policy_unsealed"}
	var normalized: Dictionary = resolved.duplicate()
	normalized["catalogArtifactId"] = resolved_artifact_id
	normalized["catalogContentDigest"] = resolved_content_digest
	normalized["catalogInputs"] = inputs
	normalized["supportPolicy"] = policy
	normalized["artifact"] = artifact if artifact is Dictionary else resolved.get("artifact", {})
	return normalized


func _release_catalog_lease(token: String) -> void:
	if token.is_empty() or not is_instance_valid(_catalog_resolver): return
	_catalog_resolver.call("release_ecology_catalog_artifact_lease", token)


func _release_source_publication_lease(token: String) -> void:
	if token.is_empty() or not is_instance_valid(_catalog_resolver): return
	_catalog_resolver.call("release_ecology_source_publication", token)


func _release_all_catalog_leases() -> void:
	for lease_value: Variant in _catalog_domain_leases.values():
		if lease_value is Dictionary:
			_release_catalog_lease(String(lease_value.get("leaseToken", "")))
	for section_value: Variant in _catalog_census_leases.values():
		if not section_value is Dictionary: continue
		for lease_value: Variant in section_value.values():
			if lease_value is Dictionary:
				_release_catalog_lease(String(lease_value.get("leaseToken", "")))
	_catalog_domain_leases.clear()
	_catalog_census_leases.clear()
	for chunk_value: Variant in _family_publication_leases.keys():
		_release_family_publication_leases(Vector2i(chunk_value))
	_family_publication_leases.clear()


func _release_family_publication_leases(source_chunk_key: Vector2i) -> void:
	var family_rows: Dictionary = _family_publication_leases.get(source_chunk_key, {})
	for lease_value: Variant in family_rows.values():
		if lease_value is Dictionary:
			_release_source_publication_lease(String(lease_value.get("leaseToken", "")))
	_family_publication_leases.erase(source_chunk_key)


func _compact_census_certificate(certificate: Dictionary) -> Dictionary:
	var compact := certificate.duplicate()
	compact.erase("supportPolicy")
	return compact


func _section_owner_key(section_key: Vector3i) -> String:
	return "%s:%d,%d,%d" % [_world_id, section_key.x, section_key.y, section_key.z]


func _domain_owner_key(world_id: String, source_chunk_key: Vector2i) -> String:
	return "%s:%d,%d" % [world_id, source_chunk_key.x, source_chunk_key.y]


func _bump_all_index_revision() -> void:
	_next_source_index_revision += 1


func _section_revision(section_key: Vector3i) -> int:
	return int(_section_index_revision.get(section_key, 0))


func _bump_section_revision(section_key: Vector3i) -> void:
	_next_source_index_revision += 1
	_section_index_revision[section_key] = _next_source_index_revision
	_latest_query_by_section.erase(section_key)


func _bump_sections(sections: Dictionary) -> void:
	for section_key: Vector3i in _sorted_sections(sections):
		_bump_section_revision(section_key)


func _sorted_sections(values: Dictionary) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	for value: Variant in values:
		if value is Vector3i: result.append(value)
	result.sort_custom(_section_less)
	return result


func _deep_freeze(value: Variant) -> void:
	if value is Dictionary:
		for child: Variant in value.values(): _deep_freeze(child)
		(value as Dictionary).make_read_only()
	elif value is Array:
		for child: Variant in value: _deep_freeze(child)
		(value as Array).make_read_only()


func _valid_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() \
		and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0


func _chunk_less(a: Vector2i, b: Vector2i) -> bool:
	if a.x != b.x: return a.x < b.x
	return a.y < b.y


func _section_less(a: Vector3i, b: Vector3i) -> bool:
	if a.x != b.x: return a.x < b.x
	if a.y != b.y: return a.y < b.y
	return a.z < b.z


func _domain_less(a: Dictionary, b: Dictionary) -> bool:
	var a_chunk: Vector2i = a.sourceChunkKey
	var b_chunk: Vector2i = b.sourceChunkKey
	if a_chunk != b_chunk:
		return _chunk_less(a_chunk, b_chunk)
	return String(a.get("family", "")) < String(b.get("family", ""))


func _source_tuple_less(a: Array, b: Array) -> bool:
	if String(a[0]) != String(b[0]): return String(a[0]) < String(b[0])
	return String(a[1]) < String(b[1])


func _row_less(a: Dictionary, b: Dictionary) -> bool:
	var chunk_a := Vector2i(a.get("sourceChunkKey", Vector2i.ZERO))
	var chunk_b := Vector2i(b.get("sourceChunkKey", Vector2i.ZERO))
	if chunk_a != chunk_b:
		return _chunk_less(chunk_a, chunk_b)
	var source_a := String(a.get("sourceId", ""))
	var source_b := String(b.get("sourceId", ""))
	if source_a != source_b:
		return source_a < source_b
	var part_a := String(a.get("sourcePartId", ""))
	var part_b := String(b.get("sourcePartId", ""))
	if part_a != part_b:
		return part_a < part_b
	var revision_a := String(a.get("sourceRevision", ""))
	var revision_b := String(b.get("sourceRevision", ""))
	if revision_a != revision_b:
		return revision_a < revision_b
	var state_a := String(a.get("state", ""))
	var state_b := String(b.get("state", ""))
	if state_a != state_b:
		return state_a < state_b
	return String(a.get("tombstoneRevision", "")) \
		< String(b.get("tombstoneRevision", ""))


func _demand_less(a: Dictionary, b: Dictionary) -> bool:
	if a.sourceChunkKey != b.sourceChunkKey:
		return _chunk_less(a.sourceChunkKey, b.sourceChunkKey)
	if String(a.sourceId) != String(b.sourceId):
		return String(a.sourceId) < String(b.sourceId)
	if String(a.memberId) != String(b.memberId):
		return String(a.memberId) < String(b.memberId)
	if String(a.get("sourceRevision", "")) != String(b.get("sourceRevision", "")):
		return String(a.get("sourceRevision", "")) < String(b.get("sourceRevision", ""))
	if String(a.get("state", "")) != String(b.get("state", "")):
		return String(a.get("state", "")) < String(b.get("state", ""))
	if String(a.get("tombstoneRevision", "")) != String(b.get("tombstoneRevision", "")):
		return String(a.get("tombstoneRevision", "")) < String(b.get("tombstoneRevision", ""))
	return String(a.get("supportLeaseToken", "")) < String(b.get("supportLeaseToken", ""))


func _array_identity_less(a: Array, b: Array) -> bool:
	return var_to_bytes(a).hex_encode() < var_to_bytes(b).hex_encode()


func _row_key(row: Dictionary) -> String:
	return _source_part_identity_key(String(row.get("sourceId", "")),
		String(row.get("sourcePartId", "")))


func _retired_row_key(row: Dictionary) -> String:
	return "%s|%s" % [_row_key(row), String(row.get("tombstoneRevision", ""))]


func _source_part_identity_key(source_id: String, source_part_id: String) -> String:
	if source_id.is_empty() or source_part_id.is_empty(): return ""
	return "section-part:" + var_to_bytes([source_id, source_part_id]).hex_encode()
