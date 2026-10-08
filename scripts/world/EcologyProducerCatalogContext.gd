extends RefCounted
class_name EcologyProducerCatalogContext

## Main-thread, no-yield sharing scope for one semantic producer-catalog capture.
## The context carries values only; per-source terrain/admission/removal inputs
## remain outside it and retain their own source-domain revisions.

const DomainScript := preload("res://scripts/world/EcologyProducerDomain.gd")
const SCHEMA := "ecology-producer-catalog-context/v1"
const ARTIFACT_SCHEMA := "ecology-producer-catalog-artifact/v2"
const MAX_VALUE_DEPTH := 48
const MAX_ARTIFACT_ENTRIES := 8
const MAX_IDLE_SOURCE_PUBLICATIONS := 32
const MAX_SOURCE_PUBLICATION_SECTION_BAND_SLICES := 256
const SOURCE_PUBLICATION_VIEW_SCHEMA := "ecology-source-publication-view/v1"
const SOURCE_PUBLICATION_SECTION_BAND_SLICE_SCHEMA := \
	"ecology-source-publication-section-band-slice/v1"

var _active_context: Dictionary = {}
var _active_scope_id := 0
var _active_scope_depth := 0
var _next_scope_id := 0
var _next_token_id := 0
var _active_token_stack: Array[int] = []
var _artifacts_by_id: Dictionary = {}
var _artifact_lru: Array[String] = []
var _leases_by_token: Dictionary = {}
var _lease_token_by_owner: Dictionary = {}
var _next_lease_token := 0
var _scope_lease_by_token_id: Dictionary = {}
var _source_publications_by_id: Dictionary = {}
var _source_publication_order: Array[String] = []
var _source_publication_id_by_key: Dictionary = {}
var _source_publication_leases: Dictionary = {}
var _source_publication_lease_by_owner: Dictionary = {}
var _next_source_publication_lease := 0
var _next_source_publication_id := 0
var _source_publication_validation_count := 0
var _source_publication_producer_seal_count := 0
var _source_publication_trusted_store_count := 0
var _source_publication_producer_field_validation_count := 0
var _source_publication_trusted_alias_match_count := 0
var _band_slice_publication_validation_count := 0
var _band_slice_projection_count := 0
var _band_slice_reuse_count := 0
var _band_slice_retirement_count := 0
var _band_slice_source_validation_usec := 0
var _band_slice_source_digest_usec := 0
var _band_slice_projection_usec := 0
var _trusted_source_payload_aliases: Array[Dictionary] = []


## Intern a fresh live catalog capture. The semantic payload is copied and
## checked before the digest is made; a digest hit is accepted only after exact
## equality with the store-owned frozen value.
func intern_fresh(world_id: String, world_seed: String, owner_epoch: int,
		owner_identity: Dictionary, catalog_inputs: Dictionary) -> Dictionary:
	if not Thread.is_main_thread():
		return {"status":"failed", "reason":"ecology_catalog_artifact_requires_main_thread"}
	if world_id.is_empty() or world_seed.is_empty() or owner_epoch <= 0 \
			or owner_identity.is_empty() or catalog_inputs.is_empty():
		return {"status":"failed", "reason":"ecology_catalog_artifact_identity_missing"}
	var owned_result := _copy_owned_value(catalog_inputs, 0)
	if not bool(owned_result.get("ok", false)) \
			or not owned_result.get("value", null) is Dictionary:
		return {"status":"failed", "reason":String(owned_result.get("reason",
			"ecology_catalog_artifact_input_invalid"))}
	var owned_inputs: Dictionary = owned_result.value
	var owner_result := _copy_owned_value(owner_identity, 0)
	if not bool(owner_result.get("ok", false)) \
			or not owner_result.get("value", null) is Dictionary:
		return {"status":"failed", "reason":"ecology_catalog_artifact_owner_identity_invalid"}
	var owned_owner_identity: Dictionary = owner_result.value
	var semantic_payload := {"schema":"ecology-producer-catalog-content/v1",
		"worldId":world_id, "worldSeed":world_seed, "catalogInputs":owned_inputs}
	var content_digest := DomainScript.digest_value(semantic_payload)
	if content_digest.length() != 64:
		return {"status":"failed", "reason":"ecology_catalog_artifact_digest_unavailable"}
	var artifact_id := DomainScript.digest_value([ARTIFACT_SCHEMA, world_id,
		world_seed, owner_epoch, owned_owner_identity, content_digest])
	if artifact_id.length() != 64:
		return {"status":"failed", "reason":"ecology_catalog_artifact_identity_unavailable"}
	if _artifacts_by_id.has(artifact_id):
		var existing: Dictionary = _artifacts_by_id[artifact_id]
		if existing.get("catalogInputs", null) != owned_inputs \
				or existing.get("ownerIdentity", {}) != owned_owner_identity:
			return {"status":"failed", "reason":"ecology_catalog_artifact_digest_collision"}
		_touch_artifact(artifact_id)
		return {"status":"ready", "artifactId":artifact_id,
			"catalogContentDigest":content_digest, "deduplicated":true}
	_retire_unleased_for_capacity()
	var support_policy: Dictionary = DomainScript.support_policy(owned_inputs)
	if not DomainScript.validate_support_policy_certificate(support_policy):
		return {"status":"pending", "reason":String(support_policy.get(
			"runtimePolicyReason", "ecology_catalog_artifact_policy_certificate_pending")),
			"policyStatus":String(support_policy.get("status", "pending")),
			"retryable":true}
	var artifact := {"schema":ARTIFACT_SCHEMA, "artifactId":artifact_id,
		"worldId":world_id, "worldSeed":world_seed, "worldEpoch":owner_epoch,
		"ownerIdentity":owned_owner_identity,
		"catalogContentDigest":content_digest,
		"catalogInputs":owned_inputs, "supportPolicy":support_policy}
	_freeze_owned_value(artifact)
	_artifacts_by_id[artifact_id] = artifact
	_artifact_lru.append(artifact_id)
	return {"status":"ready", "artifactId":artifact_id,
		"catalogContentDigest":content_digest, "deduplicated":false}


func begin_artifact_scope(artifact_id: String, world_id: String,
		world_epoch: int) -> Dictionary:
	if not Thread.is_main_thread():
		return {"status":"failed", "reason":"ecology_catalog_context_requires_main_thread"}
	var artifact_value: Variant = _artifacts_by_id.get(artifact_id, null)
	if not artifact_value is Dictionary:
		return {"status":"failed", "reason":"ecology_catalog_artifact_unregistered"}
	var artifact: Dictionary = artifact_value
	if String(artifact.get("worldId", "")) != world_id \
			or int(artifact.get("worldEpoch", 0)) != world_epoch:
		return {"status":"failed", "reason":"ecology_catalog_artifact_scope_owner_stale"}
	if _active_scope_depth > 0 and String(_active_context.get("artifactId", "")) != artifact_id:
		return {"status":"failed", "reason":"ecology_catalog_context_nested_identity_mismatch"}
	_next_scope_id += 1
	var scope_id := _next_scope_id
	var lease_result := acquire_lease(artifact_id, "catalog_scope", str(scope_id),
		world_id, world_epoch)
	if String(lease_result.get("status", "")) != "ready":
		return lease_result
	if _active_scope_depth == 0:
		_active_scope_id = scope_id
		_active_context = artifact
	_next_token_id += 1
	_active_token_stack.append(_next_token_id)
	_scope_lease_by_token_id[_next_token_id] = String(lease_result.leaseToken)
	_active_scope_depth = _active_token_stack.size()
	return {"status":"ready", "scopeId":_active_scope_id,
		"depth":_active_scope_depth, "tokenId":_next_token_id,
		"artifactId":artifact_id,
		"catalogContentDigest":String(artifact.catalogContentDigest),
		"worldId":world_id, "worldEpoch":world_epoch,
		"leaseToken":String(lease_result.leaseToken)}


func acquire_lease(artifact_id: String, owner_kind: String, owner_key: String,
		expected_world_id: String, expected_world_epoch: int) -> Dictionary:
	if not Thread.is_main_thread():
		return {"status":"failed", "reason":"ecology_catalog_artifact_requires_main_thread"}
	var artifact_value: Variant = _artifacts_by_id.get(artifact_id, null)
	if not artifact_value is Dictionary or owner_kind.is_empty() or owner_key.is_empty():
		return {"status":"failed", "reason":"ecology_catalog_artifact_or_lease_owner_missing"}
	var artifact: Dictionary = artifact_value
	if String(artifact.get("worldId", "")) != expected_world_id \
			or int(artifact.get("worldEpoch", 0)) != expected_world_epoch:
		return {"status":"failed", "reason":"ecology_catalog_artifact_owner_epoch_stale"}
	var owner_identity := "%s|%s|%s|%d" % [artifact_id, owner_kind, owner_key,
		expected_world_epoch]
	if _lease_token_by_owner.has(owner_identity):
		var existing_token: String = String(_lease_token_by_owner[owner_identity])
		if _leases_by_token.has(existing_token):
			return {"status":"ready", "leaseToken":existing_token,
				"artifactId":artifact_id, "reused":true}
	_next_lease_token += 1
	var token := "ecology-artifact-lease:%d:%s" % [_next_lease_token, artifact_id]
	_leases_by_token[token] = {"artifactId":artifact_id,
		"ownerIdentity":owner_identity, "worldId":expected_world_id,
		"worldEpoch":expected_world_epoch}
	_lease_token_by_owner[owner_identity] = token
	_touch_artifact(artifact_id)
	return {"status":"ready", "leaseToken":token,
		"artifactId":artifact_id, "reused":false}


func resolve_leased_artifact(lease_token: String, expected_world_id: String,
		expected_world_epoch: int) -> Dictionary:
	if not Thread.is_main_thread():
		return {"status":"failed", "reason":"ecology_catalog_artifact_requires_main_thread"}
	var lease_value: Variant = _leases_by_token.get(lease_token, null)
	if not lease_value is Dictionary:
		return {"status":"failed", "reason":"ecology_catalog_artifact_lease_missing"}
	var lease: Dictionary = lease_value
	if String(lease.get("worldId", "")) != expected_world_id \
			or int(lease.get("worldEpoch", 0)) != expected_world_epoch:
		return {"status":"failed", "reason":"ecology_catalog_artifact_lease_epoch_stale"}
	var artifact: Variant = _artifacts_by_id.get(String(lease.get("artifactId", "")), null)
	if not artifact is Dictionary or String(artifact.get("worldId", "")) != expected_world_id \
			or int(artifact.get("worldEpoch", 0)) != expected_world_epoch:
		return {"status":"failed", "reason":"ecology_catalog_artifact_retired_or_stale"}
	_touch_artifact(String(lease.artifactId))
	return {"status":"ready", "artifact":artifact,
		"artifactId":String(artifact.artifactId),
		"catalogContentDigest":String(artifact.catalogContentDigest),
		"supportPolicy":artifact.supportPolicy, "catalogInputs":artifact.catalogInputs,
		"worldId":expected_world_id, "worldEpoch":expected_world_epoch}


func resolve_active_scope_artifact(artifact_id: String, expected_world_id: String,
		expected_world_epoch: int) -> Dictionary:
	if not Thread.is_main_thread() or _active_scope_depth <= 0:
		return {"status":"failed", "reason":"ecology_catalog_context_scope_absent"}
	if String(_active_context.get("artifactId", "")) != artifact_id \
			or String(_active_context.get("worldId", "")) != expected_world_id \
			or int(_active_context.get("worldEpoch", 0)) != expected_world_epoch:
		return {"status":"failed", "reason":"ecology_catalog_context_scope_identity_mismatch"}
	return {"status":"ready", "artifact":_active_context,
		"artifactId":artifact_id,
		"catalogContentDigest":String(_active_context.catalogContentDigest),
		"supportPolicy":_active_context.supportPolicy,
		"catalogInputs":_active_context.catalogInputs,
		"worldId":expected_world_id, "worldEpoch":expected_world_epoch}


func release_lease(lease_token: String) -> Dictionary:
	if lease_token.is_empty():
		return {"status":"ready", "released":false}
	var lease: Variant = _leases_by_token.get(lease_token, null)
	if not lease is Dictionary:
		return {"status":"ready", "released":false}
	var artifact_id := String(lease.get("artifactId", ""))
	var owner_identity := String(lease.get("ownerIdentity", ""))
	_leases_by_token.erase(lease_token)
	if String(_lease_token_by_owner.get(owner_identity, "")) == lease_token:
		_lease_token_by_owner.erase(owner_identity)
	_retire_unleased_for_capacity()
	return {"status":"ready", "released":true, "artifactId":artifact_id}


## Seal Main-owned producer fields and immediately publish the exact sealed
## alias. This entry point accepts generated value fields, never a presealed
## caller snapshot or a caller-controlled trust marker. The catalog lease is a
## dedicated publication hold acquired before this method is called.
func _publish_producer_family_bundle(fields: Dictionary,
		catalog_lease_token: String, owner_kind: String, owner_key: String,
		owner_receipt: Dictionary) -> Dictionary:
	if not Thread.is_main_thread():
		return {"status":"failed", "reason":"ecology_source_publication_requires_main_thread"}
	if catalog_lease_token.is_empty() or owner_kind.is_empty() or owner_key.is_empty():
		return {"status":"failed", "reason":"ecology_source_publication_admission_missing"}
	var world_id := String(fields.get("worldId", ""))
	var world_seed := String(fields.get("worldSeed", ""))
	var source_inputs_value: Variant = fields.get("sourceInputs", null)
	if not source_inputs_value is Dictionary:
		return {"status":"failed", "reason":"ecology_source_publication_producer_inputs_invalid"}
	var source_inputs: Dictionary = source_inputs_value
	var world_epoch := int(fields.get("worldEpoch", source_inputs.get("worldEpoch", 0)))
	var source_chunk_value: Variant = fields.get("sourceChunkKey", null)
	if world_id.is_empty() or world_seed.is_empty() or world_epoch <= 0 \
			or not source_chunk_value is Vector2i:
		return {"status":"failed", "reason":"ecology_source_publication_identity_invalid"}
	var catalog_result := resolve_leased_artifact(catalog_lease_token,
		world_id, world_epoch)
	if String(catalog_result.get("status", "")) != "ready":
		return catalog_result
	var catalog_artifact: Dictionary = catalog_result.artifact
	if String(fields.get("worldId", "")) != String(catalog_artifact.get("worldId", "")) \
			or String(fields.get("worldSeed", "")) != String(catalog_artifact.get("worldSeed", "")):
		return {"status":"failed", "reason":"ecology_source_publication_catalog_owner_mismatch"}
	if not _validate_source_producer_fields(fields):
		return {"status":"failed", "reason":"ecology_source_publication_producer_fields_invalid"}
	_source_publication_producer_field_validation_count += 1
	var seal_started_usec := Time.get_ticks_usec()
	var snapshot: Dictionary = DomainScript.seal_source_domain_family_bundle(fields,
		catalog_artifact)
	var seal_usec := Time.get_ticks_usec() - seal_started_usec
	_source_publication_producer_seal_count += 1
	if String(snapshot.get("status", "")) != "ready":
		return {"status":String(snapshot.get("status", "failed")),
			"reason":String(snapshot.get("reason", "ecology_family_bundle_seal_failed")),
			"snapshot":snapshot, "producerSealUsec":seal_usec}
	# The Domain sealer owns and recursively freezes every nested container in
	# this returned payload. Register only this exact in-process alias for the
	# immediate store call; no marker or digest can enter this path.
	_trusted_source_payload_aliases.append(snapshot)
	var store_started_usec := Time.get_ticks_usec()
	var publication := publish_source_bundle(snapshot, catalog_lease_token,
		owner_kind, owner_key, owner_receipt)
	var store_usec := Time.get_ticks_usec() - store_started_usec
	_remove_trusted_source_payload_alias(snapshot)
	publication["snapshot"] = snapshot
	publication["producerSealUsec"] = seal_usec
	publication["producerStoreUsec"] = store_usec
	return publication


## Admit one sealed family bundle into this Main-owned publication store. The
## supplied catalog lease becomes the publication's durable catalog hold; the
## returned lease belongs to the initial capture consumer. The snapshot remains
## the exact immutable payload alias and transport tokens stay outside it.
func publish_source_bundle(snapshot: Dictionary, catalog_lease_token: String,
		owner_kind: String, owner_key: String, owner_receipt: Dictionary) -> Dictionary:
	if not Thread.is_main_thread():
		return {"status":"failed", "reason":"ecology_source_publication_requires_main_thread"}
	if catalog_lease_token.is_empty() or owner_kind.is_empty() or owner_key.is_empty() \
			or not snapshot.is_read_only():
		return {"status":"failed", "reason":"ecology_source_publication_admission_missing"}
	var world_id := String(snapshot.get("worldId", ""))
	var world_epoch := int(snapshot.get("worldEpoch", 0))
	var source_inputs_value: Variant = snapshot.get("sourceInputs", null)
	if world_id.is_empty() or world_epoch <= 0 or not source_inputs_value is Dictionary:
		return {"status":"failed", "reason":"ecology_source_publication_identity_invalid"}
	var catalog_result := resolve_leased_artifact(catalog_lease_token, world_id, world_epoch)
	if String(catalog_result.get("status", "")) != "ready":
		return catalog_result
	var catalog_artifact: Dictionary = catalog_result.artifact
	var publication_key := _source_publication_request_key(
		String(catalog_artifact.get("artifactId", "")),
		String(snapshot.get("sourceRevision", "")),
		String(snapshot.get("familyRequestDigest", "")))
	var existing_id := String(_source_publication_id_by_key.get(publication_key, ""))
	if not existing_id.is_empty():
		var existing_value: Variant = _source_publications_by_id.get(existing_id, null)
		if existing_value is Dictionary:
			var existing: Dictionary = existing_value
			if is_same(existing.get("payload", null), snapshot) \
					and String(existing.get("worldId", "")) == world_id \
				and int(existing.get("worldEpoch", -1)) == world_epoch \
				and String(existing.get("catalogArtifactId", "")) == String(
					catalog_artifact.get("artifactId", "")) \
				and existing.get("ownerReceipt", {}) == owner_receipt:
				var retained_lease := _acquire_source_publication_lease(existing_id,
					owner_kind, owner_key, world_id, world_epoch)
				if String(retained_lease.get("status", "")) == "ready":
					return {"status":"ready", "publicationId":existing_id,
						"leaseToken":String(retained_lease.leaseToken),
						"view":existing.view, "deduplicated":true,
						"catalogLeaseAdopted":false}
	var producer_owned := _consume_trusted_source_payload_alias(snapshot)
	if not producer_owned:
		if not _validate_owned_frozen_value(snapshot, 0):
			return {"status":"failed", "reason":"ecology_source_publication_payload_not_owned_values"}
		var requested_value: Variant = snapshot.get("requestedFamilies", null)
		if not requested_value is Array or not DomainScript.validate_source_domain_family_bundle(
			snapshot, world_id, snapshot.get("sourceChunkKey", Vector2i.ZERO),
			catalog_artifact, requested_value):
			return {"status":"failed", "reason":"ecology_source_publication_payload_invalid"}
	var owner_result := _copy_owned_value(owner_receipt, 0)
	if not bool(owner_result.get("ok", false)) \
			or not owner_result.get("value", null) is Dictionary:
		return {"status":"failed", "reason":"ecology_source_publication_owner_receipt_invalid"}
	var owned_receipt: Dictionary = owner_result.value
	if String(owned_receipt.get("worldId", "")) != world_id \
			or int(owned_receipt.get("worldEpoch", 0)) != world_epoch \
			or String(owned_receipt.get("catalogArtifactId", "")) != String(
				catalog_artifact.get("artifactId", "")):
		return {"status":"failed", "reason":"ecology_source_publication_owner_receipt_mismatch"}
	var semantic_digest := _var_bytes_sha256(snapshot)
	if semantic_digest.length() != 64:
		return {"status":"failed", "reason":"ecology_source_publication_digest_unavailable"}
	_next_source_publication_id += 1
	var publication_id := DomainScript.digest_value([
		"ecology-source-publication/v1", get_instance_id(),
		_next_source_publication_id, world_id, world_epoch,
		String(catalog_artifact.get("artifactId", "")), owned_receipt,
		String(snapshot.get("sourceRevision", "")),
		String(snapshot.get("familyRequestDigest", "")), semantic_digest])
	if publication_id.length() != 64:
		return {"status":"failed", "reason":"ecology_source_publication_id_unavailable"}
	if _source_publications_by_id.has(publication_id):
		var existing: Dictionary = _source_publications_by_id[publication_id]
		if not is_same(existing.get("payload", null), snapshot) \
				or existing.get("ownerReceipt", {}) != owned_receipt:
			return {"status":"failed", "reason":"ecology_source_publication_alias_collision"}
		var duplicate_lease := _acquire_source_publication_lease(publication_id,
			owner_kind, owner_key, world_id, world_epoch)
		if String(duplicate_lease.get("status", "")) != "ready":
			return duplicate_lease
		_touch_source_publication(publication_id)
		return {"status":"ready", "publicationId":publication_id,
			"leaseToken":String(duplicate_lease.leaseToken),
			"view":existing.view, "deduplicated":true,
			"catalogLeaseAdopted":false}
	if String(catalog_result.get("artifactId", "")) != String(
			source_inputs_value.get("catalogArtifactId", "")):
		return {"status":"failed", "reason":"ecology_source_publication_catalog_mismatch"}
	_retire_idle_source_publications_for_capacity()
	var coverage_by_family: Dictionary = {}
	for coverage_value: Variant in snapshot.get("familyCoverage", []):
		if coverage_value is Dictionary:
			coverage_by_family[String(coverage_value.get("family", ""))] = coverage_value
	var member_index: Dictionary = {}
	var member_digests: Array[String] = []
	var source_ids_by_family: Dictionary = {}
	var source_rows: Array = snapshot.get("sourceRows", [])
	var family_row_arrays: Dictionary = {}
	for row_index in range(source_rows.size()):
		var row_value: Variant = source_rows[row_index]
		if not row_value is Dictionary:
			return {"status":"failed", "reason":"ecology_source_publication_member_invalid"}
		var family := String(row_value.get("producerFamily", ""))
		var source_id := String(row_value.get("sourceId", ""))
		var part_id := String(row_value.get("sourcePartId", ""))
		if family.is_empty() or source_id.is_empty():
			return {"status":"failed", "reason":"ecology_source_publication_member_identity_invalid"}
		var member_key := DomainScript.source_publication_member_key(family, source_id, part_id)
		if member_index.has(member_key):
			return {"status":"failed", "reason":"ecology_source_publication_member_identity_duplicate"}
		member_index[member_key] = row_index
		member_digests.append(_var_bytes_sha256(row_value))
		var family_rows: Array = family_row_arrays.get(family, [])
		family_rows.append(row_value)
		family_row_arrays[family] = family_rows
		var family_sources: Dictionary = source_ids_by_family.get(family, {})
		family_sources[source_id] = true
		source_ids_by_family[family] = family_sources
	var policy: Dictionary = catalog_artifact.get("supportPolicy", {})
	var family_policies: Dictionary = {}
	for family_name: String in DomainScript.REQUIRED_CATEGORIES:
		family_policies[family_name] = DomainScript.family_support_policy(
			source_inputs_value, catalog_artifact, family_name)
	var family_results: Dictionary = {}
	for family: String in DomainScript.REQUIRED_CATEGORIES:
		var coverage_value: Variant = coverage_by_family.get(family, null)
		if not coverage_value is Dictionary:
			return {"status":"failed", "reason":"ecology_source_publication_family_missing"}
		var family_rows: Array = family_row_arrays.get(family, [])
		family_results[family] = {"schema":String(coverage_value.get("schema", "")),
			"family":family, "status":"ready" if String(coverage_value.get(
				"disposition", "")) in ["complete_empty", "complete_nonempty"] else
				("failed" if String(coverage_value.get("disposition", "")) == "failed" else "pending"),
			"disposition":String(coverage_value.get("disposition", "")),
			"familyRevision":String(coverage_value.get("familyRevision", "")),
			"familyPolicyRevision":String(coverage_value.get("familyPolicyRevision", "")),
			"familyPolicyDigest":String(coverage_value.get("familyPolicyDigest", "")),
			"memberCount":family_rows.size(),
			"sourceManifestDigest":String(coverage_value.get("sourceManifestDigest", "")),
			"sourceRows":family_rows}
	var view := {"schema":SOURCE_PUBLICATION_VIEW_SCHEMA,
		"publicationId":publication_id, "contentDigest":semantic_digest,
		"ownerReceipt":owned_receipt, "payload":snapshot,
		"familyResultsById":family_results,
		"familyCoverageById":coverage_by_family, "memberIndex":member_index,
		"sourceIdsByFamily":source_ids_by_family,
		"memberDigestsByIndex":member_digests,
		"supportPolicy":policy, "familySupportPoliciesById":family_policies,
		"sourceDomainRevision":String(snapshot.get("sourceRevision", "")),
		"requestedFamilies":snapshot.get("requestedFamilies", []),
		"catalogArtifactId":String(catalog_artifact.get("artifactId", "")),
		"worldId":world_id, "worldEpoch":world_epoch}
	_freeze_owned_value(view)
	_source_publications_by_id[publication_id] = {
		"payload":snapshot, "view":view, "ownerReceipt":owned_receipt,
		"catalogLeaseToken":catalog_lease_token,
		"worldId":world_id, "worldEpoch":world_epoch,
		"catalogArtifactId":String(catalog_artifact.get("artifactId", "")),
		"leaseCount":0, "publicationKey":publication_key,
		"sectionBandSlicesByKey":{}, "sectionBandSliceOrder":[],
		"sectionBandSourceValidated":false, "sectionBandSourceDigest":""}
	_source_publication_order.append(publication_id)
	_source_publication_id_by_key[publication_key] = publication_id
	var first_lease := _acquire_source_publication_lease(publication_id,
		owner_kind, owner_key, world_id, world_epoch)
	if String(first_lease.get("status", "")) != "ready":
		_retire_source_publication(publication_id)
		return first_lease
	if producer_owned:
		_source_publication_trusted_store_count += 1
	else:
		_source_publication_validation_count += 1
	return {"status":"ready", "publicationId":publication_id,
		"leaseToken":String(first_lease.leaseToken), "view":view,
		"deduplicated":false, "catalogLeaseAdopted":true}


func acquire_source_publication_lease(publication_id: String, owner_kind: String,
		owner_key: String, world_id: String, world_epoch: int) -> Dictionary:
	return _acquire_source_publication_lease(publication_id, owner_kind,
		owner_key, world_id, world_epoch)


func acquire_source_publication_for_request(catalog_artifact_id: String,
		source_revision: String, family_request_digest: String,
		owner_kind: String, owner_key: String, world_id: String,
		world_epoch: int) -> Dictionary:
	var publication_key := _source_publication_request_key(catalog_artifact_id,
		source_revision, family_request_digest)
	var publication_id := String(_source_publication_id_by_key.get(publication_key, ""))
	if publication_id.is_empty():
		return {"status":"pending", "reason":"ecology_source_publication_not_retained"}
	var publication_value: Variant = _source_publications_by_id.get(publication_id, null)
	if not publication_value is Dictionary:
		return {"status":"pending", "reason":"ecology_source_publication_retired"}
	var publication: Dictionary = publication_value
	if String(publication.get("catalogArtifactId", "")) != catalog_artifact_id:
		return {"status":"failed", "reason":"ecology_source_publication_catalog_stale"}
	var lease := _acquire_source_publication_lease(publication_id, owner_kind,
		owner_key, world_id, world_epoch)
	if String(lease.get("status", "")) != "ready":
		return lease
	return {"status":"ready", "publicationId":publication_id,
		"leaseToken":String(lease.leaseToken), "view":publication.view,
		"deduplicated":true}


static func _source_publication_request_key(catalog_artifact_id: String,
		source_revision: String, family_request_digest: String) -> String:
	return "%s|%s|%s" % [catalog_artifact_id, source_revision, family_request_digest]


static func _var_bytes_sha256(value: Variant) -> String:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK \
			or context.update(var_to_bytes(value)) != OK:
		return ""
	return context.finish().hex_encode()


func _acquire_source_publication_lease(publication_id: String, owner_kind: String,
		owner_key: String, world_id: String, world_epoch: int) -> Dictionary:
	var publication_value: Variant = _source_publications_by_id.get(publication_id, null)
	if not publication_value is Dictionary or owner_kind.is_empty() or owner_key.is_empty():
		return {"status":"failed", "reason":"ecology_source_publication_or_lease_missing"}
	var publication: Dictionary = publication_value
	if String(publication.get("worldId", "")) != world_id \
			or int(publication.get("worldEpoch", -1)) != world_epoch:
		return {"status":"failed", "reason":"ecology_source_publication_owner_epoch_stale"}
	var owner_identity := "%s|%s|%s|%d" % [publication_id, owner_kind, owner_key, world_epoch]
	var existing_token := String(_source_publication_lease_by_owner.get(owner_identity, ""))
	if not existing_token.is_empty() and _source_publication_leases.has(existing_token):
		return {"status":"ready", "publicationId":publication_id,
			"leaseToken":existing_token, "reused":true}
	_next_source_publication_lease += 1
	var token := "ecology-source-publication-lease:%d:%s" % [
		_next_source_publication_lease, publication_id]
	_source_publication_leases[token] = {"publicationId":publication_id,
		"ownerIdentity":owner_identity, "worldId":world_id, "worldEpoch":world_epoch}
	_source_publication_lease_by_owner[owner_identity] = token
	publication["leaseCount"] = int(publication.get("leaseCount", 0)) + 1
	_source_publications_by_id[publication_id] = publication
	_touch_source_publication(publication_id)
	return {"status":"ready", "publicationId":publication_id,
		"leaseToken":token, "reused":false}


func resolve_source_publication(lease_token: String, expected_world_id: String,
		expected_world_epoch: int) -> Dictionary:
	var lease_value: Variant = _source_publication_leases.get(lease_token, null)
	if not lease_value is Dictionary:
		return {"status":"failed", "reason":"ecology_source_publication_lease_missing"}
	var lease: Dictionary = lease_value
	if String(lease.get("worldId", "")) != expected_world_id \
			or int(lease.get("worldEpoch", -1)) != expected_world_epoch:
		return {"status":"failed", "reason":"ecology_source_publication_lease_epoch_stale"}
	var publication_id := String(lease.get("publicationId", ""))
	var publication: Variant = _source_publications_by_id.get(publication_id, null)
	if not publication is Dictionary:
		return {"status":"failed", "reason":"ecology_source_publication_retired"}
	var record: Dictionary = publication
	if String(record.get("worldId", "")) != expected_world_id \
			or int(record.get("worldEpoch", -1)) != expected_world_epoch \
			or not is_same(record.get("payload", null), record.get("view", {}).get("payload", null)):
		return {"status":"failed", "reason":"ecology_source_publication_alias_invalid"}
	var catalog_lease := resolve_leased_artifact(
		String(record.get("catalogLeaseToken", "")), expected_world_id,
		expected_world_epoch)
	if String(catalog_lease.get("status", "")) != "ready" \
			or String(catalog_lease.get("artifactId", "")) != String(
				record.get("catalogArtifactId", "")):
		return {"status":"failed", "reason":"ecology_source_publication_catalog_lease_stale"}
	_touch_source_publication(publication_id)
	return {"status":"ready", "publicationId":publication_id,
		"view":record.view}


## Prepare or reuse all requested target-section slices from the exact retained
## publication. The publication owner performs the full source-bundle
## validation once, then shares frozen value slices while the publication lease
## keeps their source alive.
func prepare_source_publication_section_band_slices(lease_token: String,
		expected_world_id: String, expected_world_epoch: int,
		section_keys: Array) -> Dictionary:
	var prepare_started_usec := Time.get_ticks_usec()
	if not Thread.is_main_thread():
		return {"status":"failed", "reason":"ecology_band_slice_requires_main_thread"}
	if section_keys.is_empty() or section_keys.size() > MAX_SOURCE_PUBLICATION_SECTION_BAND_SLICES:
		return {"status":"pending", "reason":"ecology_band_slice_batch_capacity",
			"retryable":true, "requestedSectionCount":section_keys.size(),
			"capacity":MAX_SOURCE_PUBLICATION_SECTION_BAND_SLICES}
	var resolved := resolve_source_publication(lease_token, expected_world_id,
		expected_world_epoch)
	if String(resolved.get("status", "")) != "ready":
		return resolved
	var view: Dictionary = resolved.get("view", {})
	var publication_id := String(resolved.get("publicationId", ""))
	var publication_value: Variant = _source_publications_by_id.get(publication_id, null)
	if not publication_value is Dictionary or publication_id.is_empty():
		return {"status":"pending", "reason":"ecology_band_slice_publication_missing",
			"retryable":true}
	var publication: Dictionary = publication_value
	if not is_same(publication.get("view", null), view) \
			or not is_same(publication.get("payload", null), view.get("payload", null)) \
			or String(publication.get("worldId", "")) != expected_world_id \
			or int(publication.get("worldEpoch", -1)) != expected_world_epoch:
		return {"status":"failed", "reason":"ecology_band_slice_publication_alias_invalid"}
	var snapshot_value: Variant = publication.get("payload", null)
	if not snapshot_value is Dictionary or String(snapshot_value.get("status", "")) != "ready":
		return {"status":"pending", "reason":"ecology_band_slice_source_not_ready",
			"retryable":true}
	var snapshot: Dictionary = snapshot_value
	var ordered_sections: Array[Vector3i] = []
	for section_value: Variant in section_keys:
		if not section_value is Vector3i:
			return {"status":"failed", "reason":"ecology_band_slice_section_invalid"}
		var section_key: Vector3i = section_value
		if section_key not in ordered_sections:
			ordered_sections.append(section_key)
	if ordered_sections.is_empty():
		return {"status":"failed", "reason":"ecology_band_slice_section_roster_empty"}
	ordered_sections.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.x != b.x: return a.x < b.x
		if a.y != b.y: return a.y < b.y
		return a.z < b.z)
	var catalog_result := resolve_leased_artifact(
		String(publication.get("catalogLeaseToken", "")), expected_world_id,
		expected_world_epoch)
	if String(catalog_result.get("status", "")) != "ready" \
			or String(catalog_result.get("artifactId", "")) \
			!= String(publication.get("catalogArtifactId", "")):
		return {"status":"pending", "reason":"ecology_band_slice_catalog_lease_stale",
			"retryable":true}
	var catalog_artifact: Dictionary = catalog_result.get("artifact", {})
	if not bool(publication.get("sectionBandSourceValidated", false)):
		var validation_started_usec := Time.get_ticks_usec()
		if not DomainScript.validate_source_domain_family_bundle(snapshot,
				expected_world_id, snapshot.get("sourceChunkKey", Vector2i.ZERO),
				catalog_artifact, snapshot.get("requestedFamilies", [])):
			return {"status":"failed", "reason":"ecology_band_slice_source_bundle_invalid"}
		_band_slice_source_validation_usec += Time.get_ticks_usec() - validation_started_usec
		var digest_started_usec := Time.get_ticks_usec()
		var source_bundle_digest := DomainScript.digest_value(snapshot)
		if source_bundle_digest.length() != 64:
			return {"status":"failed", "reason":"ecology_band_slice_source_digest_unavailable"}
		_band_slice_source_digest_usec += Time.get_ticks_usec() - digest_started_usec
		publication["sectionBandSourceValidated"] = true
		publication["sectionBandSourceDigest"] = source_bundle_digest
		_band_slice_publication_validation_count += 1
	var admitted_source_digest := String(publication.get("sectionBandSourceDigest", ""))
	if admitted_source_digest.length() != 64:
		return {"status":"failed", "reason":"ecology_band_slice_source_digest_missing"}
	var slices: Dictionary = publication.get("sectionBandSlicesByKey", {})
	var slice_order: Array = publication.get("sectionBandSliceOrder", [])
	var output: Dictionary = {}
	var projection_count := 0
	for section_key: Vector3i in ordered_sections:
		var slice_value: Variant = slices.get(section_key, null)
		if slice_value is Dictionary:
			var slice: Dictionary = slice_value
			if not _source_publication_band_slice_identity_matches(slice, publication,
					section_key, admitted_source_digest):
				return {"status":"failed", "reason":"ecology_band_slice_cached_identity_invalid",
					"sectionKey":section_key}
			_band_slice_reuse_count += 1
			slice_order.erase(section_key)
			slice_order.append(section_key)
			output[section_key] = slice
			continue
		var projection_started_usec := Time.get_ticks_usec()
		var bundle: Dictionary = DomainScript.build_admitted_source_domain_family_band_bundle(
			snapshot, section_key, DomainScript.section_bounds(section_key),
			admitted_source_digest)
		if String(bundle.get("status", "")) != "ready":
			var projection_failure := bundle.duplicate(true)
			projection_failure["status"] = String(bundle.get("status", "failed"))
			projection_failure["reason"] = String(bundle.get("reason",
				"ecology_band_slice_projection_failed"))
			projection_failure["sectionKey"] = section_key
			return projection_failure
		var identity := {"schema":SOURCE_PUBLICATION_SECTION_BAND_SLICE_SCHEMA,
			"publicationId":publication_id,
			"publicationContentDigest":String(view.get("contentDigest", "")),
			"worldId":expected_world_id, "worldEpoch":expected_world_epoch,
			"sourceChunkKey":snapshot.get("sourceChunkKey", Vector2i.ZERO),
			"sourceRevision":String(snapshot.get("sourceRevision", "")),
			"sourceBundleDigest":admitted_source_digest,
			"sectionKey":section_key, "bandBounds":DomainScript.section_bounds(section_key),
			"bundle":bundle}
		var slice_digest := DomainScript.digest_value(identity)
		if slice_digest.length() != 64:
			return {"status":"failed", "reason":"ecology_band_slice_digest_unavailable",
				"sectionKey":section_key}
		identity["sliceDigest"] = slice_digest
		_freeze_owned_value(identity)
		_band_slice_projection_usec += Time.get_ticks_usec() - projection_started_usec
		slices[section_key] = identity
		slice_order.erase(section_key)
		slice_order.append(section_key)
		output[section_key] = identity
		_band_slice_projection_count += 1
		projection_count += 1
		while slices.size() > MAX_SOURCE_PUBLICATION_SECTION_BAND_SLICES:
			var retired_section: Variant = null
			for candidate_value: Variant in slice_order:
				if candidate_value not in ordered_sections:
					retired_section = candidate_value
					break
			if retired_section == null:
				return {"status":"pending", "reason":"ecology_band_slice_cache_capacity",
					"retryable":true, "capacity":MAX_SOURCE_PUBLICATION_SECTION_BAND_SLICES}
			slices.erase(retired_section)
			slice_order.erase(retired_section)
			_band_slice_retirement_count += 1
	publication["sectionBandSlicesByKey"] = slices
	publication["sectionBandSliceOrder"] = slice_order
	_source_publications_by_id[publication_id] = publication
	output.make_read_only()
	return {"status":"ready", "publicationId":publication_id,
		"publicationContentDigest":String(view.get("contentDigest", "")),
		"sourceBundleDigest":admitted_source_digest,
		"sectionBandSlicesByKey":output,
		"requestedSectionCount":ordered_sections.size(),
		"projectionCount":projection_count,
		"prepareElapsedUsec":Time.get_ticks_usec() - prepare_started_usec}


## Resolve only the exact nested frozen slice stored by this publication owner.
## Value equality, a caller digest, or a read-only copy does not establish
## ownership.
func resolve_source_publication_section_band_slice(lease_token: String,
		expected_world_id: String, expected_world_epoch: int,
		expected_view: Dictionary, section_key: Vector3i,
		exact_slice: Dictionary) -> Dictionary:
	if not Thread.is_main_thread():
		return {"status":"failed", "reason":"ecology_band_slice_requires_main_thread"}
	var resolved := resolve_source_publication(lease_token, expected_world_id,
		expected_world_epoch)
	if String(resolved.get("status", "")) != "ready":
		return resolved
	var publication_id := String(resolved.get("publicationId", ""))
	var view: Dictionary = resolved.get("view", {})
	var publication: Dictionary = _source_publications_by_id.get(publication_id, {})
	if not is_same(view, expected_view) or not is_same(publication.get("view", null), expected_view):
		return {"status":"failed", "reason":"ecology_band_slice_view_not_admitted"}
	var slices: Dictionary = publication.get("sectionBandSlicesByKey", {})
	var stored_value: Variant = slices.get(section_key, null)
	if not stored_value is Dictionary or not is_same(stored_value, exact_slice) \
			or not _source_publication_band_slice_identity_matches(exact_slice,
				publication, section_key,
				String(publication.get("sectionBandSourceDigest", ""))):
		return {"status":"failed", "reason":"ecology_band_slice_owner_alias_mismatch",
			"sectionKey":section_key}
	return {"status":"ready", "publicationId":publication_id,
		"slice":stored_value}


func _source_publication_band_slice_identity_matches(slice: Dictionary,
		publication: Dictionary, section_key: Vector3i,
		source_bundle_digest: String) -> bool:
	var view: Dictionary = publication.get("view", {})
	var bundle: Variant = slice.get("bundle", null)
	return String(slice.get("schema", "")) == SOURCE_PUBLICATION_SECTION_BAND_SLICE_SCHEMA \
		and String(slice.get("publicationId", "")) == String(view.get("publicationId", "")) \
		and String(slice.get("publicationContentDigest", "")) == String(view.get("contentDigest", "")) \
		and String(slice.get("worldId", "")) == String(publication.get("worldId", "")) \
		and int(slice.get("worldEpoch", -1)) == int(publication.get("worldEpoch", -2)) \
		and slice.get("sourceChunkKey", null) == view.get("payload", {}).get("sourceChunkKey", null) \
		and String(slice.get("sourceRevision", "")) == String(view.get("sourceDomainRevision", "")) \
		and String(slice.get("sourceBundleDigest", "")) == source_bundle_digest \
		and slice.get("sectionKey", null) == section_key \
		and slice.get("bandBounds", null) == DomainScript.section_bounds(section_key) \
		and bundle is Dictionary and bundle.is_read_only() \
		and String(bundle.get("sourceBundleDigest", "")) == source_bundle_digest \
		and String(slice.get("sliceDigest", "")).length() == 64


func source_publication_is_current(lease_token: String, expected_world_id: String,
		expected_world_epoch: int, expected_owner_receipt: Dictionary,
		expected_source_revision: String,
		expected_removed_projection_digest: String) -> Dictionary:
	var resolved := resolve_source_publication(lease_token, expected_world_id,
		expected_world_epoch)
	if String(resolved.get("status", "")) != "ready":
		return resolved
	var view: Dictionary = resolved.view
	var payload: Dictionary = view.payload
	if not is_same(view, _source_publications_by_id[resolved.publicationId].view) \
			or view.get("ownerReceipt", {}) != expected_owner_receipt \
			or String(view.get("sourceDomainRevision", "")) != expected_source_revision \
			or String(payload.get("removedSourceProjectionDigest", "")) \
				!= expected_removed_projection_digest:
		return {"status":"failed", "reason":"ecology_source_publication_currentness_mismatch"}
	return {"status":"ready", "publicationId":String(resolved.publicationId),
		"view":view}


func release_source_publication_lease(lease_token: String) -> Dictionary:
	var lease_value: Variant = _source_publication_leases.get(lease_token, null)
	if not lease_value is Dictionary:
		return {"status":"ready", "released":false}
	var lease: Dictionary = lease_value
	var publication_id := String(lease.get("publicationId", ""))
	var owner_identity := String(lease.get("ownerIdentity", ""))
	_source_publication_leases.erase(lease_token)
	if String(_source_publication_lease_by_owner.get(owner_identity, "")) == lease_token:
		_source_publication_lease_by_owner.erase(owner_identity)
	if _source_publications_by_id.has(publication_id):
		var publication: Dictionary = _source_publications_by_id[publication_id]
		publication["leaseCount"] = maxi(0, int(publication.get("leaseCount", 0)) - 1)
		_source_publications_by_id[publication_id] = publication
	_retire_idle_source_publications_for_capacity()
	return {"status":"ready", "released":true, "publicationId":publication_id}


func source_publication_diagnostics_snapshot() -> Dictionary:
	var active := 0
	for publication_value: Variant in _source_publications_by_id.values():
		if publication_value is Dictionary and int(publication_value.get("leaseCount", 0)) > 0:
			active += 1
	return {"schema":"ecology-source-publication-diagnostics/v1",
		"publicationCount":_source_publications_by_id.size(),
		"activePublicationCount":active,
		"consumerLeaseCount":_source_publication_leases.size(),
		"fullAdmissionValidationCount":_source_publication_validation_count,
		"producerSealCount":_source_publication_producer_seal_count,
		"trustedStoreCount":_source_publication_trusted_store_count,
		"producerFieldValidationCount":_source_publication_producer_field_validation_count,
		"trustedAliasMatchCount":_source_publication_trusted_alias_match_count,
		"bandSlicePublicationValidationCount":_band_slice_publication_validation_count,
		"bandSliceProjectionCount":_band_slice_projection_count,
		"bandSliceReuseCount":_band_slice_reuse_count,
		"bandSliceRetirementCount":_band_slice_retirement_count,
		"bandSliceSourceValidationUsec":_band_slice_source_validation_usec,
		"bandSliceSourceDigestUsec":_band_slice_source_digest_usec,
		"bandSliceProjectionUsec":_band_slice_projection_usec,
		"trustedAliasCount":_trusted_source_payload_aliases.size()}


func _touch_source_publication(publication_id: String) -> void:
	_source_publication_order.erase(publication_id)
	_source_publication_order.append(publication_id)


func _retire_idle_source_publications_for_capacity() -> void:
	var idle_count := 0
	for publication_value: Variant in _source_publications_by_id.values():
		if publication_value is Dictionary and int(publication_value.get("leaseCount", 0)) <= 0:
			idle_count += 1
	while idle_count > MAX_IDLE_SOURCE_PUBLICATIONS:
		var retired := false
		for publication_id: String in _source_publication_order.duplicate():
			var publication_value: Variant = _source_publications_by_id.get(publication_id, null)
			if publication_value is Dictionary \
					and int(publication_value.get("leaseCount", 0)) <= 0:
					_retire_source_publication(publication_id)
					idle_count -= 1
					retired = true
					break
		if not retired:
			break


func _retire_source_publication(publication_id: String) -> void:
	var publication_value: Variant = _source_publications_by_id.get(publication_id, null)
	if not publication_value is Dictionary \
			or int(publication_value.get("leaseCount", 0)) > 0:
		return
	var publication: Dictionary = publication_value
	_band_slice_retirement_count += publication.get("sectionBandSlicesByKey", {}).size()
	_source_publications_by_id.erase(publication_id)
	_source_publication_order.erase(publication_id)
	var publication_key := String(publication.get("publicationKey", ""))
	if String(_source_publication_id_by_key.get(publication_key, "")) == publication_id:
		_source_publication_id_by_key.erase(publication_key)
	var catalog_token := String(publication.get("catalogLeaseToken", ""))
	if not catalog_token.is_empty():
		release_lease(catalog_token)


func _consume_trusted_source_payload_alias(snapshot: Dictionary) -> bool:
	for alias_index in range(_trusted_source_payload_aliases.size()):
		if is_same(_trusted_source_payload_aliases[alias_index], snapshot):
			_trusted_source_payload_aliases.remove_at(alias_index)
			_source_publication_trusted_alias_match_count += 1
			return true
	return false


func _remove_trusted_source_payload_alias(snapshot: Dictionary) -> void:
	for alias_index in range(_trusted_source_payload_aliases.size() - 1, -1, -1):
		if is_same(_trusted_source_payload_aliases[alias_index], snapshot):
			_trusted_source_payload_aliases.remove_at(alias_index)
			return


static func _validate_source_producer_fields(fields: Dictionary) -> bool:
	var source_inputs: Variant = fields.get("sourceInputs", null)
	var source_rows: Variant = fields.get("sourceRows", null)
	var actor_intents: Variant = fields.get("actorIntentSnapshot", null)
	var request: Variant = fields.get("familyRequest", null)
	if not source_inputs is Dictionary or not source_rows is Array \
			or not actor_intents is Array or not request is Dictionary:
		return false
	return _validate_producer_value(fields, 0)


static func _validate_producer_value(value: Variant, depth: int) -> bool:
	if depth > MAX_VALUE_DEPTH:
		return false
	if value is Dictionary:
		var dictionary_value: Dictionary = value
		for key: Variant in dictionary_value.keys():
			if typeof(key) != TYPE_STRING or not _validate_producer_value(
					dictionary_value[key], depth + 1):
				return false
		return true
	if value is Array:
		for child_value: Variant in value:
			if not _validate_producer_value(child_value, depth + 1):
				return false
		return true
	if value is float:
		return is_finite(value)
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING, TYPE_VECTOR2I, TYPE_VECTOR3I, TYPE_RECT2I:
			return true
		TYPE_VECTOR2:
			return is_finite(value.x) and is_finite(value.y)
		TYPE_VECTOR3:
			return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)
		TYPE_COLOR:
			return is_finite(value.r) and is_finite(value.g) \
				and is_finite(value.b) and is_finite(value.a)
		TYPE_BASIS:
			var basis_value: Basis = value
			for axis: Vector3 in [basis_value.x, basis_value.y, basis_value.z]:
				if not is_finite(axis.x) or not is_finite(axis.y) or not is_finite(axis.z):
					return false
			return true
		TYPE_TRANSFORM3D:
			return _validate_producer_value(value.basis, depth + 1) \
				and _validate_producer_value(value.origin, depth + 1)
		TYPE_AABB:
			return _validate_producer_value(value.position, depth + 1) \
				and _validate_producer_value(value.size, depth + 1)
		_:
			return false


static func _validate_owned_frozen_value(value: Variant, depth: int) -> bool:
	if depth > MAX_VALUE_DEPTH:
		return false
	if value is Dictionary:
		var dictionary_value: Dictionary = value
		if not dictionary_value.is_read_only():
			return false
		for key: Variant in dictionary_value.keys():
			if typeof(key) != TYPE_STRING or not _validate_owned_frozen_value(
					dictionary_value[key], depth + 1):
				return false
		return true
	if value is Array:
		var array_value: Array = value
		if not array_value.is_read_only():
			return false
		for child_value: Variant in array_value:
			if not _validate_owned_frozen_value(child_value, depth + 1):
				return false
		return true
	if value is float:
		return is_finite(value)
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING, TYPE_VECTOR2I, TYPE_VECTOR3I, TYPE_RECT2I:
			return true
		TYPE_VECTOR2:
			return is_finite(value.x) and is_finite(value.y)
		TYPE_VECTOR3:
			return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)
		TYPE_COLOR:
			return is_finite(value.r) and is_finite(value.g) \
				and is_finite(value.b) and is_finite(value.a)
		TYPE_BASIS:
			var basis_value: Basis = value
			for axis: Vector3 in [basis_value.x, basis_value.y, basis_value.z]:
				if not is_finite(axis.x) or not is_finite(axis.y) or not is_finite(axis.z):
					return false
			return true
		TYPE_TRANSFORM3D:
			return _validate_owned_frozen_value(value.basis, depth + 1) \
				and _validate_owned_frozen_value(value.origin, depth + 1)
		TYPE_AABB:
			return _validate_owned_frozen_value(value.position, depth + 1) \
				and _validate_owned_frozen_value(value.size, depth + 1)
		_:
			return false


func reset_world(world_id: String, world_epoch: int) -> Dictionary:
	var revoked: Array[String] = []
	for token_value: Variant in _leases_by_token.keys():
		var lease: Dictionary = _leases_by_token[String(token_value)]
		if String(lease.get("worldId", "")) != world_id \
				or int(lease.get("worldEpoch", 0)) != world_epoch:
			revoked.append(String(token_value))
	for token: String in revoked:
		release_lease(token)
	var revoked_source_tokens: Array[String] = []
	for token_value: Variant in _source_publication_leases.keys():
		var source_lease: Dictionary = _source_publication_leases[String(token_value)]
		if String(source_lease.get("worldId", "")) != world_id \
				or int(source_lease.get("worldEpoch", 0)) != world_epoch:
			revoked_source_tokens.append(String(token_value))
	for token: String in revoked_source_tokens:
		release_source_publication_lease(token)
	for publication_id_value: Variant in _source_publications_by_id.keys():
		var publication_id := String(publication_id_value)
		var source_publication: Dictionary = _source_publications_by_id[publication_id]
		if String(source_publication.get("worldId", "")) != world_id \
				or int(source_publication.get("worldEpoch", 0)) != world_epoch:
			source_publication["leaseCount"] = 0
			_source_publications_by_id[publication_id] = source_publication
			_retire_source_publication(publication_id)
	for artifact_id_value: Variant in _artifacts_by_id.keys():
		var artifact_id := String(artifact_id_value)
		var artifact: Dictionary = _artifacts_by_id[artifact_id]
		if String(artifact.get("worldId", "")) != world_id \
				or int(artifact.get("worldEpoch", 0)) != world_epoch:
			_retire_artifact(artifact_id)
	_active_scope_id = 0
	_active_scope_depth = 0
	_active_token_stack.clear()
	_scope_lease_by_token_id.clear()
	_active_context = {}
	_trusted_source_payload_aliases.clear()
	return {"status":"ready", "revokedLeaseCount":revoked.size(),
		"revokedSourcePublicationLeaseCount":revoked_source_tokens.size()}


func lease_count(artifact_id: String) -> int:
	var count := 0
	for lease_value: Variant in _leases_by_token.values():
		if lease_value is Dictionary and String(lease_value.get("artifactId", "")) == artifact_id:
			count += 1
	return count


func _has_lease_for_artifact(artifact_id: String) -> bool:
	return lease_count(artifact_id) > 0


func _touch_artifact(artifact_id: String) -> void:
	_artifact_lru.erase(artifact_id)
	_artifact_lru.append(artifact_id)


func _retire_unleased_for_capacity() -> void:
	# The bound applies to idle artifacts. Active source/index/compiler work may
	# legitimately hold more than eight generations during replacement; refusing
	# to publish the new owner artifact in that state deadlocks retained demand.
	# Those entries remain bounded by explicit leases and disappear as each owner
	# releases its final lease.
	while _unleased_artifact_count() >= MAX_ARTIFACT_ENTRIES:
		var retired := false
		for artifact_id: String in _artifact_lru.duplicate():
			if not _has_lease_for_artifact(artifact_id):
				_retire_artifact(artifact_id)
				retired = true
				break
		if not retired:
			return


func _unleased_artifact_count() -> int:
	var count := 0
	for artifact_id_value: Variant in _artifacts_by_id.keys():
		if not _has_lease_for_artifact(String(artifact_id_value)):
			count += 1
	return count


func _retire_artifact(artifact_id: String) -> void:
	if _has_lease_for_artifact(artifact_id):
		return
	_artifacts_by_id.erase(artifact_id)
	_artifact_lru.erase(artifact_id)


func _freeze_owned_value(value: Variant) -> void:
	if value is Dictionary:
		var dictionary_value: Dictionary = value
		if dictionary_value.is_read_only():
			return
		for child_value: Variant in dictionary_value.values():
			_freeze_owned_value(child_value)
		dictionary_value.make_read_only()
	elif value is Array:
		var array_value: Array = value
		if array_value.is_read_only():
			return
		for child_value: Variant in array_value:
			_freeze_owned_value(child_value)
		array_value.make_read_only()


static func create(world_id: String, world_seed: String,
		catalog_inputs: Dictionary) -> Dictionary:
	if world_id.is_empty() or world_seed.is_empty() or catalog_inputs.is_empty():
		return {"status":"failed", "reason":"ecology_catalog_context_identity_or_values_missing"}
	var owned_result := _copy_owned_value(catalog_inputs, 0)
	if not bool(owned_result.get("ok", false)) or not owned_result.get("value", null) is Dictionary:
		return {"status":"failed", "reason":String(owned_result.get("reason",
			"ecology_catalog_context_contains_unsupported_value"))}
	var payload := {"schema":SCHEMA, "worldId":world_id,
		"worldSeed":world_seed, "catalogInputs":owned_result.value}
	var digest := DomainScript.digest_value(payload)
	if digest.length() != 64:
		return {"status":"failed", "reason":"ecology_catalog_context_digest_unavailable"}
	payload["catalogContextDigest"] = digest
	var frozen: Variant = DomainScript.freeze_value(payload)
	if not frozen is Dictionary or not frozen.is_read_only():
		return {"status":"failed", "reason":"ecology_catalog_context_freeze_failed"}
	return {"status":"ready", "context":frozen,
		"catalogContextDigest":digest}


func begin_scope(context: Dictionary) -> Dictionary:
	if not Thread.is_main_thread():
		return {"status":"failed", "reason":"ecology_catalog_context_requires_main_thread"}
	if String(context.get("schema", "")) != SCHEMA \
			or String(context.get("worldId", "")).is_empty() \
			or String(context.get("worldSeed", "")).is_empty() \
			or not context.get("catalogInputs", null) is Dictionary:
		return {"status":"failed", "reason":"ecology_catalog_context_invalid"}
	var owned_result := _copy_owned_value(context.catalogInputs, 0)
	if not bool(owned_result.get("ok", false)) or not owned_result.get("value", null) is Dictionary:
		return {"status":"failed", "reason":String(owned_result.get("reason",
			"ecology_catalog_context_contains_unsupported_value"))}
	var payload := {"schema":SCHEMA, "worldId":String(context.worldId),
		"worldSeed":String(context.worldSeed),
		"catalogInputs":owned_result.value}
	var expected_digest := DomainScript.digest_value(payload)
	if expected_digest.length() != 64 \
			or expected_digest != String(context.get("catalogContextDigest", "")):
		return {"status":"failed", "reason":"ecology_catalog_context_content_digest_mismatch"}
	payload["catalogContextDigest"] = expected_digest
	var frozen_payload: Variant = DomainScript.freeze_value(payload)
	if not frozen_payload is Dictionary or not frozen_payload.is_read_only():
		return {"status":"failed", "reason":"ecology_catalog_context_scope_freeze_failed"}
	if _active_scope_depth > 0:
		if _active_context != frozen_payload:
			return {"status":"failed", "reason":"ecology_catalog_context_nested_identity_mismatch"}
	else:
		_next_scope_id += 1
		_active_scope_id = _next_scope_id
		_active_context = frozen_payload
	_next_token_id += 1
	_active_token_stack.append(_next_token_id)
	_active_scope_depth = _active_token_stack.size()
	return {"status":"ready", "scopeId":_active_scope_id,
		"depth":_active_scope_depth, "tokenId":_next_token_id,
		"contextDigest":String(_active_context.catalogContextDigest)}


func context_for(world_id: String, world_seed: String) -> Dictionary:
	if _active_scope_depth <= 0:
		return {"status":"absent", "reason":"ecology_catalog_context_scope_absent"}
	if world_id != String(_active_context.get("worldId", "")) \
			or world_seed != String(_active_context.get("worldSeed", "")):
		return {"status":"failed", "reason":"ecology_catalog_context_scope_identity_mismatch"}
	var context_digest := String(_active_context.get("catalogContextDigest",
		_active_context.get("catalogContentDigest", "")))
	return {"status":"ready", "context":_active_context,
		"catalogContextDigest":context_digest,
		"artifactId":String(_active_context.get("artifactId", "")),
		"catalogContentDigest":String(_active_context.get("catalogContentDigest", context_digest)),
		"scopeId":_active_scope_id, "depth":_active_scope_depth}


func end_scope(token: Dictionary) -> Dictionary:
	if not Thread.is_main_thread():
		return {"status":"failed", "reason":"ecology_catalog_context_requires_main_thread"}
	if _active_scope_depth <= 0 or int(token.get("scopeId", 0)) != _active_scope_id \
			or int(token.get("depth", 0)) != _active_scope_depth \
			or int(token.get("tokenId", 0)) <= 0 \
			or _active_token_stack.is_empty() \
			or int(_active_token_stack.back()) != int(token.get("tokenId", 0)):
		return {"status":"failed", "reason":"ecology_catalog_context_scope_token_mismatch"}
	var digest := String(_active_context.get("catalogContextDigest", ""))
	if String(_active_context.get("schema", "")) == ARTIFACT_SCHEMA:
		digest = String(_active_context.get("catalogContentDigest", ""))
	var scope_lease_token := String(_scope_lease_by_token_id.get(
		int(token.get("tokenId", 0)), ""))
	_scope_lease_by_token_id.erase(int(token.get("tokenId", 0)))
	_active_token_stack.pop_back()
	_active_scope_depth = _active_token_stack.size()
	if _active_scope_depth == 0:
		_active_scope_id = 0
		_active_context = {}
	if not scope_lease_token.is_empty():
		release_lease(scope_lease_token)
	return {"status":"ready", "scopeId":int(token.scopeId),
		"contextDigest":digest, "artifactId":String(token.get("artifactId", "")),
		"remainingDepth":_active_scope_depth}


func scope_depth() -> int:
	return _active_scope_depth


static func _copy_owned_value(value: Variant, depth: int) -> Dictionary:
	if depth > MAX_VALUE_DEPTH:
		return {"ok":false, "reason":"ecology_catalog_context_value_depth_exceeded"}
	if value is Dictionary:
		var copied: Dictionary = {}
		for key: Variant in value.keys():
			if typeof(key) != TYPE_STRING:
				return {"ok":false, "reason":"ecology_catalog_context_dictionary_key_unsupported"}
			if copied.has(key):
				return {"ok":false, "reason":"ecology_catalog_context_dictionary_key_duplicate"}
			var child := _copy_owned_value(value[key], depth + 1)
			if not bool(child.get("ok", false)):
				return child
			copied[String(key)] = child.value
		return {"ok":true, "value":copied}
	if value is Array:
		var copied: Array = []
		for item: Variant in value:
			var child := _copy_owned_value(item, depth + 1)
			if not bool(child.get("ok", false)):
				return child
			copied.append(child.value)
		return {"ok":true, "value":copied}
	if value is float and not is_finite(value):
		return {"ok":false, "reason":"ecology_catalog_context_nonfinite_scalar"}
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, \
		TYPE_VECTOR2I, TYPE_VECTOR3I, TYPE_RECT2I:
			return {"ok":true, "value":value}
		TYPE_VECTOR2:
			return {"ok":true, "value":value} if is_finite(value.x) and is_finite(value.y) \
				else {"ok":false, "reason":"ecology_catalog_context_nonfinite_vector"}
		TYPE_VECTOR3:
			return {"ok":true, "value":value} if is_finite(value.x) \
				and is_finite(value.y) and is_finite(value.z) \
				else {"ok":false, "reason":"ecology_catalog_context_nonfinite_vector"}
		TYPE_COLOR:
			return {"ok":true, "value":value} if is_finite(value.r) \
				and is_finite(value.g) and is_finite(value.b) and is_finite(value.a) \
				else {"ok":false, "reason":"ecology_catalog_context_nonfinite_color"}
		TYPE_BASIS:
			var basis_value: Basis = value
			for axis: Vector3 in [basis_value.x, basis_value.y, basis_value.z]:
				if not is_finite(axis.x) or not is_finite(axis.y) or not is_finite(axis.z):
					return {"ok":false, "reason":"ecology_catalog_context_nonfinite_basis"}
			return {"ok":true, "value":basis_value}
		TYPE_TRANSFORM3D:
			var transform_value: Transform3D = value
			var transform_copy := _copy_owned_value(transform_value.basis, depth + 1)
			var origin_copy := _copy_owned_value(transform_value.origin, depth + 1)
			if not bool(transform_copy.get("ok", false)) or not bool(origin_copy.get("ok", false)):
				return {"ok":false, "reason":"ecology_catalog_context_nonfinite_transform"}
			return {"ok":true, "value":transform_value}
		TYPE_AABB:
			var bounds_value: AABB = value
			var position_copy := _copy_owned_value(bounds_value.position, depth + 1)
			var size_copy := _copy_owned_value(bounds_value.size, depth + 1)
			if not bool(position_copy.get("ok", false)) or not bool(size_copy.get("ok", false)):
				return {"ok":false, "reason":"ecology_catalog_context_nonfinite_bounds"}
			return {"ok":true, "value":bounds_value}
		_:
			return {"ok":false, "reason":"ecology_catalog_context_value_type_unsupported:%s" % type_string(typeof(value))}
