extends SceneTree
## Synthetic value/scope contract; does not run Main or prove gameplay.

const Context := preload("res://scripts/world/EcologyProducerCatalogContext.gd")
const Domain := preload("res://scripts/world/EcologyProducerDomain.gd")
const BiomeCatalog := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const BiomeSnapshot := preload("res://scripts/environment/ActiveBiomeEnvironmentSnapshot.gd")
var checks: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var values := {"revision":7, "profiles":[{"density":0.5, "family":"oak"}],
		"bounds":AABB(Vector3.ZERO, Vector3.ONE)}
	var created := Context.create("world-a", "seed-a", values)
	_check("create_accepts_owned_values", created.get("status") == "ready")
	if created.get("status") != "ready":
		_finish()
		return
	var captured: Dictionary = created.context
	_check("create_does_not_freeze_caller_containers", not values.is_read_only() \
		and not values.profiles.is_read_only() and not values.profiles[0].is_read_only())
	values.profiles[0].density = 0.75
	values.profiles.append({"density":0.25, "family":"pine"})
	_check("captured_nested_values_are_owned_and_immutable", captured.is_read_only() \
		and captured.catalogInputs.is_read_only() and captured.catalogInputs.profiles.is_read_only() \
		and captured.catalogInputs.profiles[0].is_read_only() \
		and captured.catalogInputs.profiles.size() == 1 \
		and captured.catalogInputs.profiles[0].density == 0.5)
	var manager := Context.new()
	var outer := manager.begin_scope(captured)
	var nested := manager.begin_scope(captured)
	_check("nested_scope_retains_one_context_with_distinct_tokens", outer.get("status") == "ready" \
		and nested.get("status") == "ready" and outer.scopeId == nested.scopeId \
		and outer.tokenId != nested.tokenId and manager.scope_depth() == 2)
	_check("out_of_order_end_does_not_release_context", manager.end_scope(outer).get("status") == "failed" \
		and manager.scope_depth() == 2)
	_check("world_and_seed_are_required", manager.context_for("world-b", "seed-a").get("status") == "failed" \
		and manager.context_for("world-a", "seed-b").get("status") == "failed" \
		and manager.context_for("world-a", "seed-a").get("status") == "ready")
	var changed := Context.create("world-a", "seed-a", values)
	_check("same_revision_changed_values_have_new_digest", changed.get("status") == "ready" \
		and changed.catalogContextDigest != created.catalogContextDigest \
		and changed.context.catalogInputs.revision == captured.catalogInputs.revision)
	_check("changed_nested_context_rejected", manager.begin_scope(changed.context).get("status") == "failed" \
		and manager.scope_depth() == 2)
	_check("nested_end_keeps_outer_context", manager.end_scope(nested).get("status") == "ready" \
		and manager.scope_depth() == 1)
	var next_nested := manager.begin_scope(captured)
	_check("ended_token_cannot_close_later_same_depth_scope", manager.end_scope(nested).get("status") == "failed" \
		and manager.scope_depth() == 2 and next_nested.tokenId != nested.tokenId)
	manager.end_scope(next_nested)
	_check("outer_end_clears_context", manager.end_scope(outer).get("status") == "ready" \
		and manager.scope_depth() == 0 and manager.context_for("world-a", "seed-a").get("status") == "absent")
	var replacement := manager.begin_scope(changed.context)
	_check("next_scope_observes_changed_values", replacement.get("status") == "ready" \
		and manager.context_for("world-a", "seed-a").context.catalogInputs.profiles[0].density == 0.75 \
		and manager.end_scope(outer).get("status") == "failed")
	manager.end_scope(replacement)
	var early_result := _scoped_pending(manager, captured)
	_check("pending_operation_releases_scope", early_result.get("status") == "pending" \
		and manager.scope_depth() == 0)
	var forged: Dictionary = captured.duplicate(true)
	forged.catalogInputs.profiles[0].density = 0.9
	_check("declared_digest_cannot_hide_modified_values", manager.begin_scope(forged).get("reason") \
		== "ecology_catalog_context_content_digest_mismatch" and manager.scope_depth() == 0)
	var owner := Node.new()
	var resource := BoxMesh.new()
	for unsafe: Variant in [owner, resource, weakref(owner), Callable(self, "_finish"), RID()]:
		_check("rejects_reference_type_%s" % type_string(typeof(unsafe)) + str(checks.size()),
			Context.create("world-a", "seed-a", {"nested":[{"unsafe":unsafe}]}).get("status") == "failed")
	owner.free()
	_check("rejects_nonfinite_values", Context.create("world-a", "seed-a", {"value":NAN}).get("status") == "failed")
	var policy_inputs := {"producerCatalogRevision":"unchanged",
		"biomeProfileSnapshot":{"profiles":[{"density":0.5}]}}
	var policy_digest := Domain.support_policy_context_digest(policy_inputs)
	policy_inputs["supportPolicyContextDigest"] = policy_digest
	policy_inputs.biomeProfileSnapshot.profiles[0].density = 0.75
	var changed_policy_digest := Domain.support_policy_context_digest(policy_inputs)
	_check("policy_digest_uses_values_despite_unchanged_revision_or_declared_digest",
		changed_policy_digest != policy_digest \
		and Domain.support_policy(policy_inputs).get("runtimePolicyReason") == "ecology_support_policy_context_digest_mismatch")
	policy_inputs["supportPolicyContextDigest"] = "arbitrary"
	_check("supplied_policy_digest_does_not_define_cache_identity",
		Domain.support_policy_context_digest(policy_inputs) == changed_policy_digest)
	_check_artifact_lifetime()
	_finish()


func _check_artifact_lifetime() -> void:
	var catalog := BiomeCatalog.new()
	_check("artifact_fixture_catalog_setup", catalog.setup())
	var profiles := BiomeSnapshot.capture(catalog)
	var tree := Domain.derive_tree_grammar_support_envelope(profiles)
	var rock_digest := Domain.digest_value(["synthetic-catalog-lifetime-rock", profiles.get("contentIdentity", "")])
	# Synthetic rock bounds isolate the store contract; this is not visual proof.
	var values := {"producerCatalogRevision":"constant-revision", "fixtureMutation":0,
		"biomeProfileSnapshot":profiles, "treeGrammarEnvelopeDigest":tree.get("digest", ""),
		"rockSupportEnvelope":{"status":"ready", "profileCatalogRevision":profiles.get("contentIdentity", ""),
			"eligibleAssetSetDigest":rock_digest, "digest":rock_digest, "assetSetDigest":rock_digest,
			"registryRevision":"synthetic-rock-registry", "assetRows":[{"assetId":"synthetic-rock"}],
			"maxHorizontalSupportMeters":2.0, "maxVerticalSupportMeters":2.0}}
	var store := Context.new()
	var admitted := store.intern_fresh("world-a", "seed-a", 1, {"owner":1}, values)
	_check("fresh_artifact_admitted", admitted.get("status") == "ready")
	if admitted.get("status") != "ready": return
	var artifact_id := String(admitted.artifactId)
	var duplicate := store.intern_fresh("world-a", "seed-a", 1, {"owner":1}, values)
	_check("fresh_equal_capture_deduplicates", duplicate.get("artifactId") == artifact_id \
		and bool(duplicate.get("deduplicated", false)))
	var replacement_owner := store.intern_fresh("world-a", "seed-a", 1, {"owner":2}, values)
	_check("owner_replacement_changes_runtime_identity_only", replacement_owner.get("status") == "ready" \
		and replacement_owner.get("artifactId") != artifact_id \
		and replacement_owner.get("catalogContentDigest") == admitted.catalogContentDigest)
	var retained := store.acquire_lease(artifact_id, "source_job", "job-a", "world-a", 1)
	_check("registered_owner_acquires_lease", retained.get("status") == "ready")
	if retained.get("status") != "ready": return
	var retained_token := String(retained.leaseToken)
	var resolved := store.resolve_leased_artifact(retained_token, "world-a", 1)
	_check("resolved_catalog_and_policy_are_immutable", resolved.get("status") == "ready" \
		and resolved.catalogInputs.is_read_only() and resolved.supportPolicy.is_read_only() \
		and resolved.catalogInputs.rockSupportEnvelope.is_read_only())
	var replacement_lease := store.acquire_lease(String(replacement_owner.artifactId),
		"source_job", "replacement", "world-a", 1)
	var replacement_resolved := store.resolve_leased_artifact(String(replacement_lease.leaseToken), "world-a", 1)
	var inputs_a := _compact_source_fixture(resolved.artifact, 1)
	var inputs_b := _compact_source_fixture(replacement_resolved.artifact, 2)
	var removed_digest := Domain.digest_value([])
	var revision_a := Domain.source_domain_revision("world-a", "seed-a", Vector2i.ZERO,
		inputs_a, removed_digest, resolved.artifact)
	var revision_b := Domain.source_domain_revision("world-a", "seed-a", Vector2i.ZERO,
		inputs_b, removed_digest, replacement_resolved.artifact)
	_check("source_semantic_revision_survives_owner_replacement", revision_a.length() == 64 \
		and revision_a == revision_b)
	_check("source_cache_identity_still_rejects_replaced_owner",
		Domain.snapshot_cache_identity("world-a", Vector2i.ZERO, inputs_a, removed_digest, resolved.artifact) \
		!= Domain.snapshot_cache_identity("world-a", Vector2i.ZERO, inputs_b, removed_digest, replacement_resolved.artifact))
	store.release_lease(String(replacement_lease.leaseToken))
	values.fixtureMutation = 1
	var changed := store.intern_fresh("world-a", "seed-a", 1, {"owner":1}, values)
	_check("same_revision_semantic_mutation_changes_artifact", changed.get("status") == "ready" \
		and changed.get("artifactId") != artifact_id \
		and changed.get("catalogContentDigest") != admitted.catalogContentDigest \
		and resolved.catalogInputs.fixtureMutation == 0)
	var partial_values: Dictionary = values.duplicate(true)
	partial_values["treeGrammarEnvelopeDigest"] = "intentionally-stale-tree-envelope"
	var partial_store := Context.new()
	var partial_admission := partial_store.intern_fresh("world-partial", "seed-partial",
		1, {"owner":1}, partial_values)
	var partial_artifact_id := String(partial_admission.get("artifactId", ""))
	var partial_lease := partial_store.acquire_lease(partial_artifact_id,
		"source_job", "partial", "world-partial", 1) if not partial_artifact_id.is_empty() else {}
	var partial_resolved := partial_store.resolve_leased_artifact(
		String(partial_lease.get("leaseToken", "")), "world-partial", 1) \
		if String(partial_lease.get("status", "")) == "ready" else {}
	var partial_artifact: Dictionary = partial_resolved.get("artifact", {})
	var partial_inputs := _compact_source_fixture(partial_artifact, 1,
		"world-partial", "seed-partial") \
		if not partial_artifact.is_empty() else {}
	var partial_removed_digest := Domain.digest_value([])
	var tree_request := Domain.build_source_family_request(["trees"],
		"world-partial", "seed-partial", Vector2i.ZERO, partial_inputs,
		partial_removed_digest, partial_artifact)
	var detail_request := Domain.build_source_family_request(["details"],
		"world-partial", "seed-partial", Vector2i.ZERO, partial_inputs,
		partial_removed_digest, partial_artifact)
	_check("partial_policy_artifact_admitted_without_global_ready_claim",
		partial_admission.get("status") == "ready" \
		and partial_artifact.get("supportPolicy", {}).get("certificateStatus", "") == "ready" \
		and partial_artifact.get("supportPolicy", {}).get("status", "") == "pending")
	_check("unknown_tree_policy_stays_pending_while_bounded_details_can_be_requested",
		String(tree_request.get("status", "")) == "pending" \
		and String(detail_request.get("status", "")) == "ready" \
		and Domain.validate_source_family_request(detail_request, "world-partial",
			"seed-partial", Vector2i.ZERO, partial_inputs, partial_removed_digest,
			partial_artifact))
	var detail_source_row := {"schema":"ecology.static_source_value.v1",
		"sourceId":"synthetic-detail-source", "sourcePartId":"member-0",
		"producerFamily":"details", "category":"surface_detail",
		"sourceChunkKey":Vector2i.ZERO, "sourceRevision":detail_request.sourceDomainRevision,
		"producerRevision":detail_request.sourceDomainRevision,
		"transform":Transform3D.IDENTITY,
		"localBounds":AABB(Vector3.ZERO, Vector3.ONE),
		"supportProof":{"status":"ready", "family":"details",
			"worldBounds":AABB(Vector3(1.0, 1.0, 1.0), Vector3.ONE)}}
	var nonempty_detail_bundle := Domain.seal_source_domain_family_bundle({
		"worldId":"world-partial", "worldSeed":"seed-partial",
		"sourceChunkKey":Vector2i.ZERO, "sourceInputs":partial_inputs,
		"sourceRows":[detail_source_row], "actorIntentSnapshot":[],
		"categoriesComplete":["details"], "completedFamilies":["details"],
		"familyRequest":detail_request,
		"removedSourceProjectionDigest":partial_removed_digest,
		"removedSourceIds":[]}, partial_artifact)
	var detail_family_result: Dictionary = {}
	for coverage_value: Variant in nonempty_detail_bundle.get("familyCoverage", []):
		if coverage_value is Dictionary \
				and String(coverage_value.get("family", "")) == "details":
			detail_family_result = coverage_value
	var bundle_rows: Array = nonempty_detail_bundle.get("sourceRows", [])
	var family_rows: Array = detail_family_result.get("sourceRows", [])
	var nonempty_bundle_union_matches: bool = bundle_rows == family_rows \
		and bundle_rows.size() == 1 \
		and String(bundle_rows[0].get("familyRevision", "")) \
			== String(detail_family_result.get("familyRevision", ""))
	_check("nonempty_bundle_union_matches_stamped_family_rows_and_reseals",
		String(nonempty_detail_bundle.get("status", "")) == "ready" \
		and nonempty_bundle_union_matches \
		and Domain.validate_source_domain_family_bundle(nonempty_detail_bundle,
			"world-partial", Vector2i.ZERO, partial_artifact, ["details"]))
	_check_band_projection(nonempty_detail_bundle, detail_request, partial_inputs,
		partial_artifact, partial_removed_digest)
	var publication_catalog_hold := partial_store.acquire_lease(partial_artifact_id,
		"source_publication", "synthetic-publication-hold", "world-partial", 1)
	var publication_owner_receipt := {"worldId":"world-partial", "worldEpoch":1,
		"catalogArtifactId":partial_artifact_id}
	var publication := partial_store.publish_source_bundle(nonempty_detail_bundle,
		String(publication_catalog_hold.get("leaseToken", "")),
		"adapter_capture", "synthetic-detail-job", publication_owner_receipt)
	var publication_view: Dictionary = publication.get("view", {})
	var publication_lease_token := String(publication.get("leaseToken", ""))
	var family_results_value: Variant = publication_view.get("familyResultsById", {})
	var family_results: Dictionary = family_results_value if family_results_value is Dictionary else {}
	var detail_result_value: Variant = family_results.get("details", {})
	var detail_result: Dictionary = detail_result_value if detail_result_value is Dictionary else {}
	var detail_rows_value: Variant = detail_result.get("sourceRows", [])
	var detail_view_rows: Array = detail_rows_value if detail_rows_value is Array else []
	var publication_aliases_valid: bool = String(publication.get("status", "")) == "ready" \
		and is_same(publication_view.get("payload", null), nonempty_detail_bundle) \
		and detail_view_rows.size() == 1 \
		and is_same(detail_view_rows[0], nonempty_detail_bundle.sourceRows[0])
	var retained_structure_bounds: Dictionary = publication_view.get(
		"payload", {}).get("sourceInputs", {}).get("structureDependencies", {})
	_check("publication_preserves_integer_structure_dependency_bounds",
		retained_structure_bounds.get("sourceBounds", null) \
			== Rect2i(Vector2i(-64, -64), Vector2i(128, 128)) \
		and retained_structure_bounds.get("coverageBounds", null) \
			== Rect2i(Vector2i(-96, -96), Vector2i(192, 192)))
	var validations_before_resolve := int(
		partial_store.source_publication_diagnostics_snapshot().get(
			"fullAdmissionValidationCount", -1))
	var first_publication_resolve := partial_store.resolve_source_publication(
		publication_lease_token, "world-partial", 1)
	var second_publication_resolve := partial_store.resolve_source_publication(
		publication_lease_token, "world-partial", 1)
	var validations_after_resolve := int(
		partial_store.source_publication_diagnostics_snapshot().get(
			"fullAdmissionValidationCount", -2))
	_check("source_publication_admits_once_and_preserves_payload_member_aliases",
		publication_aliases_valid and validations_before_resolve == 1)
	_check("source_publication_resolve_reuses_exact_view_without_revalidation",
		first_publication_resolve.get("status", "") == "ready" \
		and second_publication_resolve.get("status", "") == "ready" \
		and is_same(first_publication_resolve.get("view", null), publication_view) \
		and is_same(second_publication_resolve.get("view", null), publication_view) \
		and validations_after_resolve == validations_before_resolve)
	_check_publication_band_slice_lifecycle(partial_store, publication,
		nonempty_detail_bundle, partial_artifact)
	var producer_source_row: Dictionary = detail_source_row.duplicate(true)
	var producer_fields := {"worldId":"world-partial", "worldSeed":"seed-partial",
		"sourceChunkKey":Vector2i.ZERO, "sourceInputs":partial_inputs,
		"sourceRows":[producer_source_row], "actorIntentSnapshot":[],
		"categoriesComplete":["details"], "completedFamilies":["details"],
		"familyRequest":detail_request,
		"removedSourceProjectionDigest":partial_removed_digest,
		"removedSourceIds":[]}
	var factory_caller_lease := partial_store.acquire_lease(partial_artifact_id,
		"source_job", "producer-factory-caller", "world-partial", 1)
	var factory_catalog_hold := partial_store.acquire_lease(partial_artifact_id,
		"source_publication_factory", "producer-factory-hold", "world-partial", 1)
	var producer_publication := partial_store._publish_producer_family_bundle(
		producer_fields, String(factory_catalog_hold.get("leaseToken", "")),
		"adapter_capture", "synthetic-producer-detail-job", publication_owner_receipt)
	var producer_snapshot_value: Variant = producer_publication.get("snapshot", null)
	var producer_snapshot: Dictionary = producer_snapshot_value \
		if producer_snapshot_value is Dictionary else {}
	var producer_view_value: Variant = producer_publication.get("view", null)
	var producer_view: Dictionary = producer_view_value \
		if producer_view_value is Dictionary else {}
	var producer_diagnostics := partial_store.source_publication_diagnostics_snapshot()
	var producer_output_matches_external := producer_snapshot == nonempty_detail_bundle \
		and String(producer_view.get("contentDigest", "")) \
			== String(publication_view.get("contentDigest", "")) \
		and String(producer_snapshot.get("sourceRevision", "")) \
			== String(nonempty_detail_bundle.get("sourceRevision", "")) \
		and String(producer_snapshot.get("familyCoverageDigest", "")) \
			== String(nonempty_detail_bundle.get("familyCoverageDigest", "")) \
		and String(producer_snapshot.get("producerSnapshotRevision", "")) \
			== String(nonempty_detail_bundle.get("producerSnapshotRevision", ""))
	_check("producer_factory_seals_once_and_matches_external_bundle_semantics",
		String(producer_publication.get("status", "")) == "ready" \
		and producer_output_matches_external \
		and int(producer_diagnostics.get("producerSealCount", 0)) == 1 \
		and int(producer_diagnostics.get("trustedStoreCount", 0)) == 1 \
		and int(producer_diagnostics.get("producerFieldValidationCount", 0)) == 1 \
		and int(producer_diagnostics.get("trustedAliasMatchCount", 0)) == 1 \
		and int(producer_diagnostics.get("fullAdmissionValidationCount", -1)) \
			== validations_after_resolve \
		and int(producer_diagnostics.get("trustedAliasCount", -1)) == 0)
	producer_source_row["fixtureMutationAfterSeal"] = true
	var producer_input_stays_mutable: bool = not producer_fields.sourceRows.is_read_only() \
		and not producer_source_row.is_read_only()
	var producer_payload_unchanged: bool = producer_snapshot.get("sourceRows", []).size() == 1 \
		and not producer_snapshot.sourceRows[0].has("fixtureMutationAfterSeal")
	partial_store.release_lease(String(factory_caller_lease.get("leaseToken", "")))
	var factory_publication_resolves_after_caller_release: bool = \
		partial_store.resolve_source_publication(String(producer_publication.get("leaseToken", "")),
			"world-partial", 1).get("status", "") == "ready"
	_check("producer_seal_owns_nested_rows_and_publication_outlives_capture_lease",
		producer_input_stays_mutable and producer_payload_unchanged \
		and factory_publication_resolves_after_caller_release)
	partial_store.release_source_publication_lease(String(
		producer_publication.get("leaseToken", "")))
	var producer_hostile_node := Node.new()
	var producer_hostile_fields: Dictionary = producer_fields.duplicate(true)
	producer_hostile_fields.sourceRows = [detail_source_row.duplicate(true)]
	producer_hostile_fields.sourceRows[0]["hostileNode"] = producer_hostile_node
	var producer_hostile_hold := partial_store.acquire_lease(partial_artifact_id,
		"source_publication_factory", "producer-hostile-hold", "world-partial", 1)
	var seals_before_hostile := int(partial_store.source_publication_diagnostics_snapshot().get(
		"producerSealCount", -1))
	var producer_hostile_result := partial_store._publish_producer_family_bundle(
		producer_hostile_fields, String(producer_hostile_hold.get("leaseToken", "")),
		"adapter_capture", "producer-hostile", publication_owner_receipt)
	_check("producer_factory_rejects_live_objects_before_sealing",
		String(producer_hostile_result.get("status", "")) == "failed" \
		and String(producer_hostile_result.get("reason", "")) \
			== "ecology_source_publication_producer_fields_invalid" \
		and int(partial_store.source_publication_diagnostics_snapshot().get(
			"producerSealCount", -2)) == seals_before_hostile)
	producer_hostile_node.free()
	partial_store.release_lease(String(producer_hostile_hold.get("leaseToken", "")))
	var equivalent_bundle := Domain.seal_source_domain_family_bundle({
		"worldId":"world-partial", "worldSeed":"seed-partial",
		"sourceChunkKey":Vector2i.ZERO, "sourceInputs":partial_inputs,
		"sourceRows":[detail_source_row], "actorIntentSnapshot":[],
		"categoriesComplete":["details"], "completedFamilies":["details"],
		"familyRequest":detail_request,
		"removedSourceProjectionDigest":partial_removed_digest,
		"removedSourceIds":[]}, partial_artifact)
	var equivalent_hold := partial_store.acquire_lease(partial_artifact_id,
		"source_publication", "equivalent-publication-hold", "world-partial", 1)
	var equivalent_publication := partial_store.publish_source_bundle(equivalent_bundle,
		String(equivalent_hold.get("leaseToken", "")), "adapter_capture",
		"synthetic-detail-recapture", publication_owner_receipt)
	var equivalent_view_value: Variant = equivalent_publication.get("view", {})
	var equivalent_view: Dictionary = equivalent_view_value \
		if equivalent_view_value is Dictionary else {}
	var equivalent_payload_value: Variant = equivalent_view.get("payload", null)
	_check("equal_fresh_bundle_keeps_a_distinct_publication_alias_and_owner_proof",
		String(equivalent_publication.get("status", "")) == "ready" \
		and String(equivalent_publication.get("publicationId", ""))
			!= String(publication.get("publicationId", "")) \
		and String(equivalent_view.get("contentDigest", ""))
			== String(publication_view.get("contentDigest", "")) \
		and not is_same(equivalent_payload_value, publication_view.get("payload", null)))
	partial_store.release_source_publication_lease(String(
		equivalent_publication.get("leaseToken", "")))
	partial_store.release_lease(String(equivalent_hold.get("leaseToken", "")))
	partial_store.release_lease(String(partial_lease.get("leaseToken", "")))
	var caller_release_preserves_publication: bool = partial_store.resolve_source_publication(
		publication_lease_token, "world-partial", 1).get("status", "") == "ready"
	_check("publication_owns_catalog_hold_after_capture_lease_release",
		caller_release_preserves_publication \
		and partial_store.lease_count(partial_artifact_id) >= 1)
	partial_store.release_source_publication_lease(publication_lease_token)
	_check("released_publication_consumer_token_no_longer_resolves",
		partial_store.resolve_source_publication(publication_lease_token,
			"world-partial", 1).get("status", "") != "ready")
	var nested_mutable_bundle: Dictionary = nonempty_detail_bundle.duplicate(true)
	nested_mutable_bundle.make_read_only()
	var mutable_hold := partial_store.acquire_lease(partial_artifact_id,
		"source_publication", "mutable-payload-probe", "world-partial", 1)
	var mutable_rejected := partial_store.publish_source_bundle(nested_mutable_bundle,
		String(mutable_hold.get("leaseToken", "")), "adapter_capture",
		"mutable-probe", publication_owner_receipt)
	_check("publication_rejects_mutable_nested_payload_container",
		String(mutable_rejected.get("status", "")) == "failed" \
		and String(mutable_rejected.get("reason", ""))
			== "ecology_source_publication_payload_not_owned_values")
	partial_store.release_lease(String(mutable_hold.get("leaseToken", "")))
	var hostile_bundle: Dictionary = nonempty_detail_bundle.duplicate(true)
	var hostile_node := Node.new()
	hostile_bundle.sourceInputs["fixtureHostileNode"] = hostile_node
	var frozen_hostile_value: Variant = Domain.freeze_value(hostile_bundle)
	var frozen_hostile_bundle: Dictionary = frozen_hostile_value \
		if frozen_hostile_value is Dictionary else {}
	var hostile_hold := partial_store.acquire_lease(partial_artifact_id,
		"source_publication", "hostile-payload-probe", "world-partial", 1)
	var hostile_rejected := partial_store.publish_source_bundle(frozen_hostile_bundle,
		String(hostile_hold.get("leaseToken", "")), "adapter_capture",
		"hostile-probe", publication_owner_receipt)
	_check("publication_rejects_nested_node_despite_readonly_outer_containers",
		String(hostile_rejected.get("status", "")) == "failed" \
		and String(hostile_rejected.get("reason", ""))
			== "ecology_source_publication_payload_not_owned_values")
	hostile_node.free()
	partial_store.release_lease(String(hostile_hold.get("leaseToken", "")))
	partial_store.reset_world("world-partial", 2)
	_check("publication_reset_drains_publication_and_catalog_leases",
		partial_store.source_publication_diagnostics_snapshot().get("publicationCount", -1) == 0 \
		and partial_store.source_publication_diagnostics_snapshot().get("consumerLeaseCount", -1) == 0 \
		and partial_store.lease_count(partial_artifact_id) == 0)
	var domain_cache = Domain.new()
	var detail_snapshot_retained: bool = domain_cache.retain_completed_snapshot(
		nonempty_detail_bundle, partial_artifact)
	var cached_details: Dictionary = domain_cache.completed_snapshot_for("world-partial",
		Vector2i.ZERO, partial_inputs, partial_removed_digest, partial_artifact, ["details"])
	var cached_wide: Dictionary = domain_cache.completed_snapshot_for("world-partial",
		Vector2i.ZERO, partial_inputs, partial_removed_digest, partial_artifact,
		["details", "trees"])
	_check("completed_snapshot_cache_requires_exact_family_request_and_complete_rows",
		detail_snapshot_retained and cached_details.get("status", "") == "ready" \
		and cached_details.get("snapshot", {}).get("schema", "") == Domain.FAMILY_BUNDLE_SCHEMA \
		and cached_wide.get("status", "") == "pending" \
		and cached_wide.get("reason", "") == "ecology_cached_family_bundle_incomplete")
	if String(partial_lease.get("leaseToken", "")) != "":
		partial_store.release_lease(String(partial_lease.leaseToken))
	partial_store.reset_world("world-partial", 1)
	_check("unknown_artifact_and_forged_lease_rejected",
		store.acquire_lease("unregistered", "source_job", "forged", "world-a", 1).get("status") != "ready" \
		and store.resolve_leased_artifact("forged", "world-a", 1).get("status") != "ready")
	_check("wrong_epoch_or_world_cannot_resolve",
		store.resolve_leased_artifact(retained_token, "world-a", 2).get("status") != "ready" \
		and store.resolve_leased_artifact(retained_token, "world-b", 1).get("status") != "ready")
	var pressure_ready := true
	for index in range(Context.MAX_ARTIFACT_ENTRIES * 2):
		values.fixtureMutation = 10 + index
		var pressure := store.intern_fresh("world-a", "seed-a", 1, {"owner":1}, values)
		pressure_ready = pressure_ready and pressure.get("status") == "ready"
	_check("retained_job_survives_unleased_eviction_pressure", pressure_ready \
		and store.resolve_leased_artifact(retained_token, "world-a", 1).get("status") == "ready")
	store.release_lease(retained_token)
	store.release_lease(retained_token)
	for index in range(Context.MAX_ARTIFACT_ENTRIES * 2):
		values.fixtureMutation = 100 + index
		store.intern_fresh("world-a", "seed-a", 1, {"owner":1}, values)
	_check("released_artifact_can_retire", store.acquire_lease(artifact_id,
		"source_job", "retired", "world-a", 1).get("status") != "ready")
	var current := store.intern_fresh("world-a", "seed-a", 1, {"owner":1}, values)
	var other := store.acquire_lease(String(current.artifactId), "index", "independent", "world-a", 1)
	var scope := store.begin_artifact_scope(String(current.artifactId), "world-a", 1)
	var tampered := scope.duplicate(true)
	tampered["leaseToken"] = other.leaseToken
	if store.end_scope(tampered).get("status") != "ready": store.end_scope(scope)
	_check("scope_cannot_release_another_owner_lease",
		store.resolve_leased_artifact(String(other.leaseToken), "world-a", 1).get("status") == "ready" \
		and store.lease_count(String(current.artifactId)) == 1)
	var outer := store.begin_artifact_scope(String(current.artifactId), "world-a", 1)
	var nested := store.begin_artifact_scope(String(current.artifactId), "world-a", 1)
	store.reset_world("world-a", 2)
	_check("same_seed_reset_revokes_leases_and_nested_scopes", store.scope_depth() == 0 \
		and store.context_for("world-a", "seed-a").get("status") != "ready" \
		and store.end_scope(nested).get("status") != "ready" \
		and store.end_scope(outer).get("status") != "ready" \
		and store.resolve_leased_artifact(String(other.leaseToken), "world-a", 1).get("status") != "ready")
	var reset_artifact := store.intern_fresh("world-a", "seed-a", 2, {"owner":1}, values)
	_check("reset_preserves_semantics_but_changes_runtime_identity", reset_artifact.get("status") == "ready" \
		and reset_artifact.get("catalogContentDigest") == current.catalogContentDigest \
		and reset_artifact.get("artifactId") != current.artifactId)
	var next_lease := store.acquire_lease(String(reset_artifact.artifactId), "index", "next", "world-a", 2)
	store.reset_world("world-b", 1)
	_check("world_replacement_revokes_previous_world", store.resolve_leased_artifact(
		String(next_lease.leaseToken), "world-a", 2).get("status") != "ready")
	var pinned_tokens: Array[String] = []
	for index in range(Context.MAX_ARTIFACT_ENTRIES):
		values.fixtureMutation = 200 + index
		var pinned := store.intern_fresh("world-b", "seed-b", 1, {"owner":2}, values)
		if pinned.get("status") != "ready": break
		var pin := store.acquire_lease(String(pinned.artifactId), "index", str(index), "world-b", 1)
		if pin.get("status") != "ready": break
		pinned_tokens.append(String(pin.leaseToken))
	values.fixtureMutation = 300
	var over_idle_cap := store.intern_fresh("world-b", "seed-b", 1, {"owner":2}, values)
	var every_pinned_generation_resolves := pinned_tokens.size() == Context.MAX_ARTIFACT_ENTRIES
	for token: String in pinned_tokens:
		every_pinned_generation_resolves = every_pinned_generation_resolves \
			and store.resolve_leased_artifact(token, "world-b", 1).get("status") == "ready"
	_check("active_artifact_leases_allow_replacement_without_losing_retained_generations",
		every_pinned_generation_resolves and over_idle_cap.get("status") == "ready" \
		and store.lease_count(String(over_idle_cap.artifactId)) == 0 \
		and store.resolve_leased_artifact(String(pinned_tokens[0]), "world-b", 1).get(
			"status") == "ready")
	if not pinned_tokens.is_empty():
		store.release_lease(pinned_tokens.pop_front())
		var retried := store.intern_fresh("world-b", "seed-b", 1, {"owner":2}, values)
		_check("released_live_lease_does_not_invalidate_new_or_retained_artifacts",
			retried.get("status") == "ready" \
			and store.resolve_leased_artifact(String(pinned_tokens[0]), "world-b", 1).get(
				"status") == "ready")
	for token: String in pinned_tokens: store.release_lease(token)
	store.reset_world("world-c", 1)


func _check_publication_band_slice_lifecycle(store, publication: Dictionary,
		source_bundle: Dictionary, catalog_artifact: Dictionary) -> void:
	var publication_id := String(publication.get("publicationId", ""))
	var lease_a := String(publication.get("leaseToken", ""))
	var view: Dictionary = publication.get("view", {})
	var section_nonempty := Vector3i.ZERO
	var section_empty := Vector3i(0, 1, 0)
	var initial: Dictionary = store.prepare_source_publication_section_band_slices(
		lease_a, "world-partial", 1, [section_nonempty, section_empty])
	var initial_slices: Dictionary = initial.get("sectionBandSlicesByKey", {})
	var nonempty_slice: Dictionary = initial_slices.get(section_nonempty, {})
	var empty_slice: Dictionary = initial_slices.get(section_empty, {})
	var nonempty_bundle: Dictionary = nonempty_slice.get("bundle", {})
	var empty_bundle: Dictionary = empty_slice.get("bundle", {})
	var nonempty_receipt := _band_detail_receipt(nonempty_bundle)
	var empty_receipt := _band_detail_receipt(empty_bundle)
	var expected_nonempty := Domain.project_source_domain_family_bundle_to_band(
		source_bundle, section_nonempty, Domain.section_bounds(section_nonempty),
		catalog_artifact)
	var expected_empty := Domain.project_source_domain_family_bundle_to_band(
		source_bundle, section_empty, Domain.section_bounds(section_empty),
		catalog_artifact)
	_check("publication_owner_prepares_nonempty_and_authoritative_empty_slices",
		String(initial.get("status", "")) == "ready" \
		and nonempty_receipt.get("disposition", "") == "complete_nonempty" \
		and empty_receipt.get("disposition", "") == "complete_empty" \
		and int(nonempty_receipt.get("memberCount", -1)) == 1 \
		and int(empty_receipt.get("memberCount", -1)) == 0 \
		and nonempty_bundle == expected_nonempty and empty_bundle == expected_empty \
		and String(nonempty_slice.get("schema", "")) \
			== "ecology-source-publication-section-band-slice/v1" \
		and nonempty_slice.get("sectionKey", null) == section_nonempty \
		and String(nonempty_slice.get("sourceBundleDigest", "")).length() == 64)
	var first_diagnostics: Dictionary = store.source_publication_diagnostics_snapshot()
	var lease_b_result: Dictionary = store.acquire_source_publication_lease(publication_id,
		"band_slice_contract", "second-consumer", "world-partial", 1)
	var lease_b := String(lease_b_result.get("leaseToken", ""))
	var second: Dictionary = store.prepare_source_publication_section_band_slices(
		lease_b, "world-partial", 1, [section_nonempty, section_empty])
	var second_slices: Dictionary = second.get("sectionBandSlicesByKey", {})
	var second_nonempty: Dictionary = second_slices.get(section_nonempty, {})
	var second_empty: Dictionary = second_slices.get(section_empty, {})
	var after_reuse: Dictionary = store.source_publication_diagnostics_snapshot()
	var resolved_second_consumer: Dictionary = store.resolve_source_publication_section_band_slice(
		lease_b, "world-partial", 1, view, section_nonempty, nonempty_slice)
	_check("exact_slices_reuse_across_consumers_and_sections_without_reprojection",
		String(lease_b_result.get("status", "")) == "ready" \
		and String(second.get("status", "")) == "ready" \
		and is_same(second_nonempty, nonempty_slice) \
		and is_same(second_empty, empty_slice) \
		and String(resolved_second_consumer.get("status", "")) == "ready" \
		and is_same(resolved_second_consumer.get("slice", null), nonempty_slice) \
		and int(first_diagnostics.get("bandSlicePublicationValidationCount", -1)) == 1 \
		and int(first_diagnostics.get("bandSliceProjectionCount", -1)) == 2 \
		and int(after_reuse.get("bandSlicePublicationValidationCount", -2)) == 1 \
		and int(after_reuse.get("bandSliceProjectionCount", -2)) == 2 \
		and int(after_reuse.get("bandSliceReuseCount", -1)) \
			>= int(first_diagnostics.get("bandSliceReuseCount", -2)) + 2)
	var copied_slice: Dictionary = nonempty_slice.duplicate(true)
	var copied_result: Dictionary = store.resolve_source_publication_section_band_slice(
		lease_a, "world-partial", 1, view, section_nonempty, copied_slice)
	var mutated_slice: Dictionary = nonempty_slice.duplicate(true)
	mutated_slice["sourceRevision"] = "stale-source-revision"
	var mutated_result: Dictionary = store.resolve_source_publication_section_band_slice(
		lease_a, "world-partial", 1, view, section_nonempty, mutated_slice)
	var forged_view: Dictionary = view.duplicate(true)
	forged_view["sourceDomainRevision"] = "stale-source-revision"
	var stale_view_result: Dictionary = store.resolve_source_publication_section_band_slice(
		lease_a, "world-partial", 1, forged_view, section_nonempty, nonempty_slice)
	var stale_epoch_result: Dictionary = store.prepare_source_publication_section_band_slices(
		lease_a, "world-partial", 2, [section_nonempty])
	var foreign_owner := Context.new()
	var foreign_result: Dictionary = foreign_owner.resolve_source_publication_section_band_slice(
		lease_a, "world-partial", 1, view, section_nonempty, nonempty_slice)
	_check("copied_mutated_stale_revision_epoch_and_foreign_owner_slices_rejected",
		String(copied_result.get("status", "")) == "failed" \
		and String(mutated_result.get("status", "")) == "failed" \
		and String(stale_view_result.get("status", "")) == "failed" \
		and String(stale_epoch_result.get("status", "")) == "failed" \
		and String(foreign_result.get("status", "")) == "failed")
	var capacity_keys: Array[Vector3i] = []
	for section_y in range(Context.MAX_SOURCE_PUBLICATION_SECTION_BAND_SLICES):
		capacity_keys.append(Vector3i(0, section_y, 0))
	var capacity_result: Dictionary = store.prepare_source_publication_section_band_slices(
		lease_a, "world-partial", 1, capacity_keys)
	var eviction_key := Vector3i(0,
		Context.MAX_SOURCE_PUBLICATION_SECTION_BAND_SLICES, 0)
	var eviction_result: Dictionary = store.prepare_source_publication_section_band_slices(
		lease_a, "world-partial", 1, [eviction_key])
	var sibling_result: Dictionary = store.prepare_source_publication_section_band_slices(
		lease_a, "world-partial", 1, [section_empty])
	var sibling_slices: Dictionary = sibling_result.get("sectionBandSlicesByKey", {})
	var sibling_after_extension: Dictionary = sibling_slices.get(section_empty, {})
	var evicted_alias_result: Dictionary = store.resolve_source_publication_section_band_slice(
		lease_a, "world-partial", 1, view, section_nonempty, nonempty_slice)
	var replay_result: Dictionary = store.prepare_source_publication_section_band_slices(
		lease_a, "world-partial", 1, [section_nonempty])
	var replay_slices: Dictionary = replay_result.get("sectionBandSlicesByKey", {})
	var replay_slice: Dictionary = replay_slices.get(section_nonempty, {})
	var after_replay: Dictionary = store.source_publication_diagnostics_snapshot()
	var expected_projection_delta := capacity_keys.size() - 2 + 1 + 1
	_check("bounded_slice_eviction_reprojects_exact_content_for_replay",
		String(capacity_result.get("status", "")) == "ready" \
		and String(eviction_result.get("status", "")) == "ready" \
		and String(sibling_result.get("status", "")) == "ready" \
		and is_same(sibling_after_extension, empty_slice) \
		and String(evicted_alias_result.get("status", "")) == "failed" \
		and String(replay_result.get("status", "")) == "ready" \
		and not is_same(replay_slice, nonempty_slice) \
		and String(replay_slice.get("sliceDigest", "")) \
			== String(nonempty_slice.get("sliceDigest", "")) \
		and replay_slice.get("bundle", {}) == expected_nonempty \
		and int(after_replay.get("bandSliceProjectionCount", -1)) \
			== int(after_reuse.get("bandSliceProjectionCount", -2)) \
				+ expected_projection_delta \
		and int(after_replay.get("bandSliceRetirementCount", -1)) > 0)
	store.release_source_publication_lease(lease_b)
	var lease_c_result: Dictionary = store.acquire_source_publication_lease(publication_id,
		"band_slice_contract", "replay-consumer", "world-partial", 1)
	var lease_c := String(lease_c_result.get("leaseToken", ""))
	var replay_consumer_result: Dictionary = store.prepare_source_publication_section_band_slices(
		lease_c, "world-partial", 1, [section_nonempty])
	var replay_consumer_slice: Dictionary = replay_consumer_result.get(
		"sectionBandSlicesByKey", {}).get(section_nonempty, {})
	_check("released_consumer_can_replay_current_retained_slice",
		String(lease_c_result.get("status", "")) == "ready" \
		and String(replay_consumer_result.get("status", "")) == "ready" \
		and is_same(replay_consumer_slice, replay_slice) \
		and String(store.resolve_source_publication_section_band_slice(
			lease_c, "world-partial", 1, view, section_nonempty,
			replay_slice).get("status", "")) == "ready")
	store.release_source_publication_lease(lease_c)
	var released_result: Dictionary = store.resolve_source_publication_section_band_slice(
		lease_c, "world-partial", 1, view, section_nonempty, replay_slice)
	_check("released_consumer_cannot_resolve_slice",
		String(released_result.get("status", "")) != "ready")


func _check_band_projection(source_bundle: Dictionary, family_request: Dictionary,
		source_inputs: Dictionary, catalog_artifact: Dictionary,
		removed_digest: String) -> void:
	var lower_key := Vector3i(0, 0, 0)
	var lower_bounds: AABB = Domain.section_bounds(lower_key)
	var boundary_y: float = lower_bounds.end.y
	var source_rows: Array = [
		_projectable_detail_row("projection-crossing", AABB(
			Vector3(lower_bounds.position.x + 1.0, boundary_y - 0.5,
				lower_bounds.position.z + 1.0), Vector3.ONE)),
		_projectable_detail_row("projection-lower-edge", AABB(
			Vector3(lower_bounds.position.x + 2.0, boundary_y - 1.0,
				lower_bounds.position.z + 1.0), Vector3.ONE)),
		_projectable_detail_row("projection-upper-edge", AABB(
			Vector3(lower_bounds.position.x + 3.0, boundary_y,
				lower_bounds.position.z + 1.0), Vector3.ONE)),
		_projectable_detail_row("projection-x-crossing", AABB(
			Vector3(lower_bounds.end.x - 0.5, lower_bounds.position.y + 1.0,
				lower_bounds.position.z + 2.0), Vector3.ONE)),
		_projectable_detail_row("projection-z-crossing", AABB(
			Vector3(lower_bounds.position.x + 4.0, lower_bounds.position.y + 1.0,
				lower_bounds.end.z - 0.5), Vector3.ONE))]
	var source_chunk: Vector2i = source_bundle.get("sourceChunkKey", Vector2i.ZERO)
	var fixture_bundle := Domain.seal_source_domain_family_bundle({
		"worldId":String(source_bundle.get("worldId", "")),
		"worldSeed":String(source_bundle.get("worldSeed", "")),
		"sourceChunkKey":source_chunk, "sourceInputs":source_inputs,
		"sourceRows":source_rows, "actorIntentSnapshot":[],
		"categoriesComplete":["details"], "completedFamilies":["details"],
		"familyRequest":family_request,
		"removedSourceProjectionDigest":removed_digest}, catalog_artifact)
	var upper_key := Vector3i(0, 1, 0)
	var upper_bounds: AABB = Domain.section_bounds(upper_key)
	var x_neighbor_key := Vector3i(1, 0, 0)
	var x_neighbor_bounds: AABB = Domain.section_bounds(x_neighbor_key)
	var z_neighbor_key := Vector3i(0, 0, 1)
	var z_neighbor_bounds: AABB = Domain.section_bounds(z_neighbor_key)
	var lower := Domain.project_source_domain_family_bundle_to_band(
		fixture_bundle, lower_key, lower_bounds, catalog_artifact)
	var upper := Domain.project_source_domain_family_bundle_to_band(
		fixture_bundle, upper_key, upper_bounds, catalog_artifact)
	var x_neighbor := Domain.project_source_domain_family_bundle_to_band(
		fixture_bundle, x_neighbor_key, x_neighbor_bounds, catalog_artifact)
	var z_neighbor := Domain.project_source_domain_family_bundle_to_band(
		fixture_bundle, z_neighbor_key, z_neighbor_bounds, catalog_artifact)
	var empty_key := Vector3i(0, 2, 0)
	var empty_bounds: AABB = Domain.section_bounds(empty_key)
	var empty := Domain.project_source_domain_family_bundle_to_band(
		fixture_bundle, empty_key, empty_bounds, catalog_artifact)
	var lower_receipt := _band_detail_receipt(lower)
	var upper_receipt := _band_detail_receipt(upper)
	var empty_receipt := _band_detail_receipt(empty)
	_check("band_projection_is_immutable_and_binds_currentness_and_full_section_key",
		String(lower.get("schema", "")) == Domain.FAMILY_BAND_BUNDLE_SCHEMA \
		and String(lower.get("status", "")) == "ready" and lower.is_read_only() \
		and lower.get("bandKey", null) == lower_key \
		and lower.get("sectionY", -1) == lower_key.y \
		and lower.get("bandBounds", null) == lower_bounds \
		and String(lower.get("sourceBundleDigest", "")).length() == 64 \
		and lower.get("sourceChunkKey", null) == source_chunk \
		and lower.get("catalogArtifactId", "") == fixture_bundle.get("catalogArtifactId", "") \
		and lower.get("removedSourceProjectionDigest", "") \
			== fixture_bundle.get("removedSourceProjectionDigest", "") \
		and lower_receipt.get("disposition", "") == "complete_nonempty")
	_check("half_open_band_projection_preserves_crossing_and_exact_edge_semantics",
		_band_detail_ids(lower).has("projection-crossing") \
		and _band_detail_ids(upper).has("projection-crossing") \
		and _band_detail_ids(lower).has("projection-lower-edge") \
		and not _band_detail_ids(lower).has("projection-upper-edge") \
		and _band_detail_ids(upper).has("projection-upper-edge"))
	_check("band_receipt_separates_full_and_projected_source_identity",
		String(lower_receipt.get("sourceFamilyManifestDigest", "")).length() == 64 \
		and String(lower_receipt.get("sourceManifestDigest", "")).length() == 64 \
		and lower_receipt.get("sourceIds", []).has("projection-crossing") \
		and String(lower_receipt.get("sourceIdsDigest", "")).length() == 64 \
		and String(lower_receipt.get("sourceFamilyIdsDigest", "")).length() == 64 \
		and lower_receipt.get("sourceFamilyMemberCount", -1) == 5 \
		and lower_receipt.get("sourceFamilyMemberRowCount", -1) == 5 \
		and lower_receipt.get("sourceFamilySourceIdCount", -1) == 5 \
		and lower_receipt.get("memberCount", -1) == lower_receipt.get("sourceIds", []).size() \
		and String(upper_receipt.get("familyRevision", "")) \
			!= String(lower_receipt.get("familyRevision", "")))
	_check("full_section_key_separates_same_y_xz_neighbors_and_projects_crossing_support",
		_band_detail_ids(lower).has("projection-x-crossing") \
		and _band_detail_ids(x_neighbor).has("projection-x-crossing") \
		and _band_detail_ids(lower).has("projection-z-crossing") \
		and _band_detail_ids(z_neighbor).has("projection-z-crossing") \
		and x_neighbor.get("sectionY", -1) == lower.get("sectionY", -2) \
		and z_neighbor.get("sectionY", -1) == lower.get("sectionY", -2) \
		and String(_band_detail_receipt(x_neighbor).get("familyRevision", "")) \
			!= String(lower_receipt.get("familyRevision", "")) \
		and String(_band_detail_receipt(z_neighbor).get("familyRevision", "")) \
			!= String(lower_receipt.get("familyRevision", "")))
	_check("complete_source_family_proves_empty_band_and_validator_recomputes",
		String(empty.get("status", "")) == "ready" \
		and empty_receipt.get("disposition", "") == "complete_empty" \
		and int(empty_receipt.get("memberCount", -1)) == 0 \
		and String(empty_receipt.get("sourceManifestDigest", "")).length() == 64 \
		and Domain.validate_source_domain_family_band_bundle(lower, fixture_bundle,
			lower_key, lower_bounds, catalog_artifact) \
		and Domain.validate_source_domain_family_band_bundle(upper, fixture_bundle,
			upper_key, upper_bounds, catalog_artifact) \
		and Domain.validate_source_domain_family_band_bundle(x_neighbor, fixture_bundle,
			x_neighbor_key, x_neighbor_bounds, catalog_artifact) \
		and Domain.validate_source_domain_family_band_bundle(z_neighbor, fixture_bundle,
			z_neighbor_key, z_neighbor_bounds, catalog_artifact) \
		and Domain.validate_source_domain_family_band_bundle(empty, fixture_bundle,
			empty_key, empty_bounds, catalog_artifact))
	var forged_empty: Dictionary = empty.duplicate(true)
	for index in range(forged_empty.familyCoverage.size()):
		if String(forged_empty.familyCoverage[index].get("family", "")) == "details":
			forged_empty.familyCoverage[index]["disposition"] = "complete_nonempty"
			break
	var frozen_forged_value: Variant = Domain.freeze_value(forged_empty)
	var frozen_forged: Dictionary = frozen_forged_value if frozen_forged_value is Dictionary else {}
	var invalid_bounds := Domain.project_source_domain_family_bundle_to_band(
		fixture_bundle, lower_key, AABB(lower_bounds.position,
			lower_bounds.size + Vector3(0.0, 1.0, 0.0)), catalog_artifact)
	_check("band_projection_rejects_mismatched_bounds_and_forged_empty_receipt",
		String(invalid_bounds.get("status", "")) == "failed" \
		and not Domain.validate_source_domain_family_band_bundle(frozen_forged,
			fixture_bundle, empty_key, empty_bounds, catalog_artifact))
	var unbounded_row := _projectable_detail_row("projection-unbounded",
		AABB(Vector3(lower_bounds.position.x + 1.0, lower_bounds.position.y + 1.0,
			lower_bounds.position.z + 1.0), Vector3.ONE))
	unbounded_row.erase("supportProof")
	var unbounded_bundle := Domain.seal_source_domain_family_bundle({
		"worldId":String(source_bundle.get("worldId", "")),
		"worldSeed":String(source_bundle.get("worldSeed", "")),
		"sourceChunkKey":source_chunk, "sourceInputs":source_inputs,
		"sourceRows":[unbounded_row], "actorIntentSnapshot":[],
		"categoriesComplete":["details"], "completedFamilies":["details"],
		"familyRequest":family_request,
		"removedSourceProjectionDigest":removed_digest}, catalog_artifact)
	var unbounded := Domain.project_source_domain_family_bundle_to_band(
		unbounded_bundle, lower_key, lower_bounds, catalog_artifact)
	_check("missing_bounds_stay_pending_instead_of_claiming_empty",
		String(unbounded.get("status", "")) == "pending" \
		and String(unbounded.get("reason", "")) \
			== "ecology_band_projection_member_bounds_pending")


func _projectable_detail_row(source_id: String, world_bounds: AABB) -> Dictionary:
	return {"schema":"ecology.static_source_value.v1", "sourceId":source_id,
		"sourcePartId":"member-0", "producerFamily":"details",
		"category":"surface_detail", "transform":Transform3D.IDENTITY,
		"localBounds":AABB(Vector3.ZERO, Vector3.ONE),
		"supportProof":{"status":"ready", "family":"details",
			"worldBounds":world_bounds}}


func _band_detail_ids(projection: Dictionary) -> Array[String]:
	var result: Array[String] = []
	for row_value: Variant in projection.get("sourceRows", []):
		if row_value is Dictionary:
			result.append(String(row_value.get("sourceId", "")))
	return result


func _band_detail_receipt(projection: Dictionary) -> Dictionary:
	for receipt_value: Variant in projection.get("familyCoverage", []):
		if receipt_value is Dictionary \
				and String(receipt_value.get("family", "")) == "details":
			return receipt_value
	return {}


func _compact_source_fixture(artifact: Dictionary, owner: int,
		world_id := "world-a", world_seed := "seed-a") -> Dictionary:
	var source_bounds := Rect2i(Vector2i(-64, -64), Vector2i(128, 128))
	var coverage_bounds := Rect2i(Vector2i(-96, -96), Vector2i(192, 192))
	var dependency_digest := Domain.digest_value({"localLayout":"same",
		"sourceBounds":source_bounds, "coverageBounds":coverage_bounds})
	return {"schema":"ecology-source-domain-inputs/v2", "worldId":world_id, "worldSeed":world_seed,
		"worldEpoch":1, "sourceChunkKey":Vector2i.ZERO, "catalogArtifactId":artifact.artifactId,
		"catalogContentDigest":artifact.catalogContentDigest,
		"influencePolicyRevision":artifact.supportPolicy.revision,
		"influencePolicyDigest":artifact.supportPolicy.digest,
		"terrainVolumeChunkRevision":"same-terrain", "structureAdmissionRevision":dependency_digest,
		"structureAdmissionStatus":"ready", "structureDependencyStatus":"ready",
		"structureDependencyContentDigest":dependency_digest,
		"structureDependencies":{"contentDigest":dependency_digest, "ownerInstanceId":owner,
			"sourceBounds":source_bounds, "coverageBounds":coverage_bounds}}


func _scoped_pending(manager, context: Dictionary) -> Dictionary:
	var token: Dictionary = manager.begin_scope(context)
	if token.get("status") != "ready": return token
	var operation := {"status":"pending", "reason":"synthetic_dependency"}
	var ended: Dictionary = manager.end_scope(token)
	return operation if ended.get("status") == "ready" else ended


func _check(name: String, passed: bool) -> void:
	checks[name] = passed


func _finish() -> void:
	var report := {"schema":"ecology-producer-catalog-context-contract/v1",
		"passed":not checks.values().has(false), "checks":checks, "checkCount":checks.size(),
		"evidenceLevel":"synthetic_catalog_value_and_scope_lifecycle_contract",
		"doesNotProve":"Main catalog capture cost, live source publication, renderer installation, gameplay or performance."}
	var file := FileAccess.open(OS.get_environment("ECOLOGY_PRODUCER_CATALOG_CONTEXT_REPORT"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	print("ECOLOGY PRODUCER CATALOG CONTEXT ", JSON.stringify(report))
	quit(0 if report.passed else 1)
