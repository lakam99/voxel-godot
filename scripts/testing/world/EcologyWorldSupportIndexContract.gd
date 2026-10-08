extends SceneTree

const Index := preload("res://scripts/world/EcologyWorldSupportIndex.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const ProducerDomain := preload("res://scripts/world/EcologyProducerDomain.gd")
const AdapterFixture := preload("res://scripts/testing/world/EcologySectionValueAdapterContract.gd")

const WORLD_ID := "support-index-contract-world"
const POLICY := "tree-factory-support-envelope/v2"

class FixtureCatalogResolver:
	extends AdapterFixture.ProductionAuthority
	var artifacts: Dictionary = {}
	var active_leases: Dictionary = {}
	var release_count := 0
	var next_token := 0
	var synthetic_local_revision := 0
	var active_catalog_artifact_id := ""
	var local_checks_by_publication: Dictionary = {}
	var band_slice_resolution_count := 0
	var band_slice_exact_resolution_count := 0

	func _init() -> void:
		pass # Explicit synthetic catalog input; no generated profile setup needed.

	func register(artifact: Dictionary) -> void:
		artifacts[String(artifact.get("artifactId", ""))] = artifact
		# Synthetic presealed catalogs enter the real store; publication admission,
		# immutable aliases and lease ownership use its production implementation.
		_catalog_store._artifacts_by_id[String(artifact.get("artifactId", ""))] = artifact

	func acquire_ecology_catalog_artifact_lease(artifact_id: String, owner_kind: String,
			owner_key: String, expected_world_id: String,
			expected_world_epoch: int) -> Dictionary:
		var artifact: Dictionary = artifacts.get(artifact_id, {})
		if artifact.is_empty() or String(artifact.get("worldId", "")) != expected_world_id \
				or int(artifact.get("worldEpoch", -1)) != expected_world_epoch \
				or owner_kind.is_empty() or owner_key.is_empty():
			return {"status":"pending", "reason":"fixture_artifact_missing_or_stale"}
		var acquired := _catalog_store.acquire_lease(artifact_id, owner_kind, owner_key,
			expected_world_id, expected_world_epoch)
		if acquired.get("status") == "ready" and owner_kind != "source_publication":
			active_leases[String(acquired.leaseToken)] = {"artifactId":artifact_id, "ownerKind":owner_kind,
				"ownerKey":owner_key, "worldId":expected_world_id, "worldEpoch":expected_world_epoch}
		return acquired

	func resolve_ecology_catalog_artifact(lease_token: String,
			expected_world_id: String, expected_world_epoch: int) -> Dictionary:
		return _catalog_store.resolve_leased_artifact(lease_token, expected_world_id, expected_world_epoch)

	func release_ecology_catalog_artifact_lease(lease_token: String) -> Dictionary:
		if active_leases.erase(lease_token):
			release_count += 1
		return _catalog_store.release_lease(lease_token)

	func ecology_source_publication_local_is_current(view: Dictionary, token: String) -> Dictionary:
		var resolved := resolve_ecology_source_publication(token, String(view.get("worldId", "")), int(view.get("worldEpoch", -1)))
		if resolved.get("status") != "ready" or not is_same(resolved.get("view", {}), view):
			return {"status":"failed", "reason":"fixture_publication_alias_stale"}
		var publication_id := String(view.get("publicationId", ""))
		local_checks_by_publication[publication_id] = int(local_checks_by_publication.get(publication_id, 0)) + 1
		if synthetic_local_revision != 0:
			return {"status":"pending", "reason":"synthetic_local_dependency_revision_changed"}
		return {"status":"ready"} # Synthetic immutable source inputs; no live generation claim.

	func resolve_ecology_source_publication(token: String, world: String, epoch: int) -> Dictionary:
		var resolved: Dictionary = super.resolve_ecology_source_publication(token, world, epoch)
		if resolved.get("status") == "ready" and not active_catalog_artifact_id.is_empty() \
				and String(resolved.view.get("catalogArtifactId", "")) != active_catalog_artifact_id:
			return {"status":"failed", "reason":"synthetic_catalog_owner_replaced"}
		return resolved

	func resolve_ecology_source_publication_section_band_slice(view: Dictionary,
			token: String, section_key: Vector3i, exact_slice: Dictionary) -> Dictionary:
		band_slice_resolution_count += 1
		var world_id := String(view.get("worldId", ""))
		var world_epoch := int(view.get("worldEpoch", -1))
		var resolved := resolve_ecology_source_publication(token, world_id, world_epoch)
		if String(resolved.get("status", "")) != "ready" \
				or not is_same(resolved.get("view", null), view):
			return {"status":"failed", "reason":"fixture_publication_alias_stale"}
		var result: Dictionary = _catalog_store.resolve_source_publication_section_band_slice(
			token, world_id, world_epoch, view, section_key, exact_slice)
		if String(result.get("status", "")) == "ready" \
				and is_same(result.get("slice", null), exact_slice):
			band_slice_exact_resolution_count += 1
		return result

	func active_count_for(artifact_id: String) -> int:
		var count := 0
		for lease_value: Variant in active_leases.values():
			if lease_value is Dictionary \
					and String(lease_value.get("artifactId", "")) == artifact_id:
				count += 1
		for lease: Dictionary in _catalog_store._source_publication_leases.values():
			var publication: Dictionary = _catalog_store._source_publications_by_id.get(String(lease.get("publicationId", "")), {})
			if String(publication.get("catalogArtifactId", "")) == artifact_id: count += 1
		return count

var checks := 0
var first_failed_check := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var index = Index.new()
	_check(index.configure(WORLD_ID).status == "ready", "configure")
	var section := Vector3i.ZERO
	var resolver := FixtureCatalogResolver.new()
	root.add_child(resolver)
	var artifact_a := _catalog_artifact("a".repeat(64), "fixture-owner-A")
	resolver.register(artifact_a)
	_check(index.bind_catalog_artifact_resolver(resolver, 1).status == "ready",
		"bind explicit v2 catalog resolver")
	var inputs := _compact_source_inputs(artifact_a, Vector2i.ZERO)
	var policy: Dictionary = ProducerDomain.support_policy(inputs, artifact_a)
	if policy.get("status", "") != "ready":
		_write_report({"schema":"ecology_world_support_index_contract/v1",
			"passed":false, "checkCount":checks,
			"failedCheck":"synthetic support policy is bounded",
			"runtimePolicyReason":String(policy.get("runtimePolicyReason", "")),
			"runtimePolicyStatus":String(policy.get("runtimePolicyStatus", ""))})
		quit(1)
		return
	var census: Dictionary = ProducerDomain.source_domain_census_certificate(section,
		inputs, artifact_a)
	var required: Array = census.get("sourceChunkKeys", [])
	if census.get("status", "") != "ready":
		_check(false, "synthetic support census is ready: %s" % String(census.get("reason", "")))
		return
	_check(index.set_required_source_domains(section, required, census).status == "ready",
		"certified inverse census")
	var tree_row := _source_row("tree-1", "branches:00000000",
		AABB(Vector3.ZERO, Vector3(2.0, 3.0, 2.0)), Vector3i.ZERO,
		"member-revision-A", "recipe-A", 1)
	for chunk_value: Variant in required:
		var chunk: Vector2i = chunk_value
		var source_rows: Array = [tree_row] if chunk == Vector2i.ZERO else []
		var snapshot := _snapshot(chunk, source_rows, artifact_a)
		_check(snapshot.get("status", "") == "ready", "complete producer snapshot")
		var published: Dictionary = index.publish_source_domain(WORLD_ID, chunk,
			snapshot, source_rows)
		_check(published.status == "ready", "publish complete source domain %s: %s" % [
			str(chunk), JSON.stringify(published)])
	var query: Dictionary = index.query_section(WORLD_ID, section)
	_check(query.status == "ready", "complete domains query: %s" % String(
		query.get("reason", "")))
	_check(query.contributors.size() == 1, "member posting")
	_check(query.supportOwnerDemands.size() == 1, "per-member owner lease")
	var lease: Dictionary = query.supportOwnerDemands[0]
	_check(lease.schema == "ecology-support-owner-lease/v1" \
		and lease.memberId == "branches:00000000" \
		and lease.sourceRevision == "member-revision-A" \
		and lease.ownerSectionKey == Vector3i.ZERO \
		and String(lease.supportLeaseToken).length() == 64,
		"lease binds member source revision and owner")
	var certificate: Dictionary = query.coverageCertificate
	_check(index.validate_coverage_certificate(certificate, WORLD_ID,
		section).status == "ready", "certificate validates")
	var prior_member_token := String(lease.supportLeaseToken)
	var artifact_b := _catalog_artifact("b".repeat(64), "fixture-owner-B")
	resolver.register(artifact_b)
	var replacement_inputs := _compact_source_inputs(artifact_b, Vector2i.ZERO)
	var replacement_census := ProducerDomain.source_domain_census_certificate(
		section, replacement_inputs, artifact_b)
	_check(index.set_required_source_domains(section, required,
		replacement_census).get("status", "") == "ready",
		"replace census proof under a new artifact owner")
	for chunk_value: Variant in required:
		var chunk: Vector2i = chunk_value
		var source_rows: Array = [tree_row] if chunk == Vector2i.ZERO else []
		var snapshot := _snapshot(chunk, source_rows, artifact_b)
		var replaced_proof: Dictionary = index.publish_source_domain(WORLD_ID,
			chunk, snapshot, source_rows)
		_check(replaced_proof.get("status", "") == "ready" \
			and not bool(replaced_proof.get("changed", true)),
			"new artifact owner refreshes runtime proof without semantic publication")
	_check(resolver.active_count_for(String(artifact_a.artifactId)) == 0,
		"old catalog leases release after current proof replacement")
	var replaced_query: Dictionary = index.query_section(WORLD_ID, section)
	_check(replaced_query.get("status", "") == "ready" \
		and replaced_query.get("contributors", []).size() == 1 \
		and String(replaced_query.supportOwnerDemands[0].get("sourceRevision", "")) \
			== String(lease.sourceRevision),
		"replacement proof preserves current member identity")
	var revision_b := _source_row("tree-1", "branches:00000000",
		AABB(Vector3.ZERO, Vector3(2.0, 3.0, 2.0)), Vector3i.ZERO,
		"member-revision-B", "recipe-B", 2)
	var revision_b_snapshot := _snapshot(Vector2i.ZERO, [revision_b], artifact_b)
	_check(index.publish_source_domain(WORLD_ID, Vector2i.ZERO,
		revision_b_snapshot, [revision_b]).status == "ready",
		"publish revision B before section receipt")
	var revision_c := _source_row("tree-1", "branches:00000000",
		AABB(Vector3.ZERO, Vector3(2.0, 3.0, 2.0)), Vector3i.ZERO,
		"member-revision-C", "recipe-C", 3)
	var revision_c_snapshot := _snapshot(Vector2i.ZERO, [revision_c], artifact_b)
	_check(index.publish_source_domain(WORLD_ID, Vector2i.ZERO,
		revision_c_snapshot, [revision_c]).status == "ready",
		"publish revision C before section receipt")
	var revision_query: Dictionary = index.query_section(WORLD_ID, section)
	var current_revision_lease: Dictionary = {}
	var retired_revision_leases: Array[Dictionary] = []
	for revision_lease_value: Variant in revision_query.get("supportOwnerDemands", []):
		if not revision_lease_value is Dictionary:
			continue
		var revision_lease: Dictionary = revision_lease_value
		if String(revision_lease.get("state", "")) == "compiled":
			current_revision_lease = revision_lease
		elif String(revision_lease.get("state", "")) == "tombstoned":
			retired_revision_leases.append(revision_lease)
	retired_revision_leases.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a.get("sourceRevision", "")) < String(b.get("sourceRevision", "")))
	var revision_demand_diagnostics: Array[Dictionary] = []
	var revision_demands_value: Variant = revision_query.get("supportOwnerDemands", [])
	var revision_demand_count := 0
	var revision_demands: Array = []
	if revision_demands_value is Array:
		revision_demand_count = revision_demands_value.size()
		revision_demands = revision_demands_value
	for revision_lease_value: Variant in revision_demands:
		if revision_demand_diagnostics.size() >= 8:
			break
		if not revision_lease_value is Dictionary:
			continue
		var revision_lease: Dictionary = revision_lease_value
		revision_demand_diagnostics.append({
			"sourceId":String(revision_lease.get("sourceId", "")),
			"sourcePartId":String(revision_lease.get("memberId", "")),
			"sourceRevision":String(revision_lease.get("sourceRevision", "")),
			"state":String(revision_lease.get("state", "")),
			"ownerSectionKey":revision_lease.get("ownerSectionKey", Vector3i.ZERO),
			"supportLeaseToken":String(revision_lease.get("supportLeaseToken", ""))})
	_check(revision_query.get("status", "") == "ready" \
		and current_revision_lease.get("sourceRevision", "") == "member-revision-C" \
		and retired_revision_leases.size() == 2 \
		and retired_revision_leases[0].get("sourceRevision", "") == "member-revision-A" \
		and retired_revision_leases[1].get("sourceRevision", "") == "member-revision-B" \
		and retired_revision_leases[0].get("supportLeaseToken", "") \
			!= retired_revision_leases[1].get("supportLeaseToken", ""),
		"both replaced source revisions remain required until receipt", {
			"queryStatus":String(revision_query.get("status", "")),
			"queryReason":String(revision_query.get("reason", "")),
			"demandCount":revision_demand_count,
			"demandsTruncated":revision_demand_count > revision_demand_diagnostics.size(),
			"demands":revision_demand_diagnostics,
			"expectedCompiledRevision":"member-revision-C",
			"expectedTombstoneRevisions":["member-revision-A", "member-revision-B"]})
	var revision_receipt := {"schema":"ecology-support-section-install-receipt/v1",
		"sectionKey":section,
		"sourceIndexRevision":revision_query.sourceIndexRevision,
		"coverageDigest":revision_query.coverageCertificate.coverageDigest,
		"nativeReceipt":{"receiptId":"native-revision-c"},
		"installedMemberReceipts":[_member_receipt(current_revision_lease)],
		"verifiedAbsentMemberReceipts":[]}
	for retired_lease: Dictionary in retired_revision_leases:
		revision_receipt.verifiedAbsentMemberReceipts.append(
			_member_receipt(retired_lease))
	var revision_ack := index.acknowledge_section_receipt(section,
		revision_query.sourceIndexRevision, revision_receipt)
	var after_revision_ack: Dictionary = index.query_section(WORLD_ID, section)
	_check(revision_ack.get("status", "") == "ready" \
		and int(revision_ack.get("retiredTombstoneCount", -1)) == 2 \
		and after_revision_ack.get("supportOwnerDemands", []).size() == 1 \
		and after_revision_ack.supportOwnerDemands[0].get("sourceRevision", "") \
			== "member-revision-C",
		"correct receipt retires both old revisions")
	var replacement_snapshot := _snapshot(Vector2i.ZERO, [], artifact_b)
	_check(index.publish_source_domain(WORLD_ID, Vector2i.ZERO,
		replacement_snapshot, []).status == "ready", "source removal retains tombstone")
	var replacement_query: Dictionary = index.query_section(WORLD_ID, section)
	_check(replacement_query.status == "ready" and replacement_query.supportOwnerDemands.size() == 1,
		"tombstone remains demanded until receipt")
	var tombstone_lease: Dictionary = replacement_query.supportOwnerDemands[0]
	_check(tombstone_lease.state == "tombstoned", "removed member lease is tombstoned")
	var base_receipt := {"schema":"ecology-support-section-install-receipt/v1",
		"sectionKey":section,
		"sourceIndexRevision":replacement_query.sourceIndexRevision,
		"coverageDigest":replacement_query.coverageCertificate.coverageDigest,
		"nativeReceipt":{"receiptId":"native-replacement"},
		"installedMemberReceipts":[]}
	_check(index.acknowledge_section_receipt(section,
		replacement_query.sourceIndexRevision, base_receipt).status == "pending",
		"missing tombstone absence evidence is rejected")
	var forged_receipt := base_receipt.duplicate(true)
	forged_receipt["verifiedAbsentMemberReceipts"] = [{
		"sourceId":tombstone_lease.sourceId,
		"sourceRevision":tombstone_lease.sourceRevision,
		"memberId":tombstone_lease.memberId,
		"ownerSectionKey":tombstone_lease.ownerSectionKey,
		"supportLeaseToken":"f".repeat(64)}]
	_check(index.acknowledge_section_receipt(section,
		replacement_query.sourceIndexRevision, forged_receipt).status == "pending",
		"forged tombstone absence token is rejected")
	var valid_receipt := base_receipt.duplicate(true)
	valid_receipt["verifiedAbsentMemberReceipts"] = [{
		"sourceId":tombstone_lease.sourceId,
		"sourceRevision":tombstone_lease.sourceRevision,
		"memberId":tombstone_lease.memberId,
		"ownerSectionKey":tombstone_lease.ownerSectionKey,
		"supportLeaseToken":tombstone_lease.supportLeaseToken}]
	_check(index.acknowledge_section_receipt(section,
		replacement_query.sourceIndexRevision, valid_receipt).status == "ready",
		"verified tombstone absence accepts replacement receipt")
	index.release_section_demand(section)
	_check(resolver.active_leases.is_empty() \
		and resolver.active_count_for(String(artifact_b.artifactId)) == 0,
		"last section demand release retires census and orphan domain leases")
	_check(index.query_section(WORLD_ID, section).get("status", "") == "pending",
		"released section demand remains explicitly retryable")
	_run_family_bundle_contract()
	_write_report({"schema":"ecology_world_support_index_contract/v1",
		"passed":true, "checkCount":checks,
		"evidenceLevel":"synthetic_bounded_source_index_and_receipt_contract",
		"supportPolicyFixture":"synthetic profile and rock descriptor envelope; tree support envelope is derived from current source",
		"catalogLeaseReleaseCount":resolver.release_count,
		"status":"ready", "lease":lease})
	quit(0)


func _run_family_bundle_contract() -> void:
	# New family path is exercised independently of the retained v1 receipt tests.
	var index := Index.new()
	var resolver := FixtureCatalogResolver.new()
	root.add_child(resolver)
	var artifact_a := _catalog_artifact("c".repeat(64), "family-owner-A")
	var artifact_b := _catalog_artifact("e".repeat(64), "family-owner-B")
	resolver.register(artifact_a)
	resolver.register(artifact_b)
	index.configure(WORLD_ID)
	resolver.active_catalog_artifact_id = String(artifact_a.artifactId)
	index.bind_catalog_artifact_resolver(resolver, 1)
	var section := Vector3i.ZERO
	var census := ProducerDomain.source_domain_census_certificate(section,
		_compact_source_inputs(artifact_a, Vector2i.ZERO), artifact_a)
	var closure: Dictionary = census.get("sourceChunkKeysByFamily", {})
	_check(index.set_required_source_domains_by_family(section, closure, census).get("status") == "ready",
		"family census admits exact per-family closure")
	var row := _source_row("family-tree", "branches:00000000",
		AABB(Vector3.ZERO, Vector3(2.0, 3.0, 2.0)), section)
	var narrow := _family_bundle(Vector2i.ZERO, [row], artifact_a, ["trees"])
	var wide := _family_bundle(Vector2i.ZERO, [row], artifact_a, ProducerDomain.REQUIRED_CATEGORIES)
	_assert_publication_boundary(resolver, narrow)
	_check(ProducerDomain.source_family_result(narrow, "details", artifact_a).get("disposition") == "deferred_unrequested"
		and ProducerDomain.source_family_result(narrow, "trees", artifact_a).get("familyRevision")
			== ProducerDomain.source_family_result(wide, "trees", artifact_a).get("familyRevision"),
		"narrow and wide share tree identity without claiming deferred details empty")
	# The support index may publish a selected family projection while preserving
	# the exact same full producer view for the independent tree-band authority.
	var subset_index := Index.new()
	subset_index.configure(WORLD_ID)
	subset_index.bind_catalog_artifact_resolver(resolver, 1)
	var full_hold: Dictionary = resolver.acquire_ecology_catalog_artifact_lease(
		String(wide.catalogArtifactId), "synthetic_subset_capture", "subset-test", WORLD_ID, 1)
	var full_admitted: Dictionary = resolver.admit_ecology_source_publication(
		wide, String(full_hold.get("leaseToken", "")), "synthetic_subset_capture", "subset-test")
	resolver.release_ecology_catalog_artifact_lease(String(full_hold.get("leaseToken", "")))
	var full_view: Dictionary = full_admitted.get("view", {})
	var full_publication_token := String(full_admitted.get("leaseToken", ""))
	var rocks_proof := ProducerDomain.source_family_result(wide, "surface_rocks", artifact_a)
	var subset_publish := subset_index.publish_source_domain_family_projection(WORLD_ID,
		Vector2i.ZERO, wide, {"surface_rocks":[]}, full_view,
		full_publication_token, ["surface_rocks"])
	var full_band_preparation: Dictionary = resolver._catalog_store \
		.prepare_source_publication_section_band_slices(full_publication_token,
			WORLD_ID, 1, [section])
	var full_band_slice: Dictionary = full_band_preparation.get(
		"sectionBandSlicesByKey", {}).get(section, {})
	var full_projection: Dictionary = ProducerDomain.project_source_domain_family_bundle_to_band(
		wide, section, ProducerDomain.section_bounds(section), artifact_a)
	var subset_band := subset_index.register_source_family_section_band_projection(
		WORLD_ID, Vector2i.ZERO, section, wide, full_band_slice, ["surface_rocks"],
		full_view, full_publication_token)
	_check(subset_publish.get("status", "") == "ready"
		and subset_index._family_domains.get(Vector2i.ZERO, {}).has("surface_rocks")
		and not subset_index._family_domains.get(Vector2i.ZERO, {}).has("trees")
		and subset_band.get("status", "") == "ready"
		and String(full_band_preparation.get("status", "")) == "ready"
		and String(full_band_slice.get("schema", "")) \
			== "ecology-source-publication-section-band-slice/v1"
		and resolver.band_slice_resolution_count > 0
		and resolver.band_slice_exact_resolution_count == resolver.band_slice_resolution_count
		and not subset_index._family_band_receipts.get(Vector2i.ZERO, {}).get(
			"trees", {}).has(section)
		and is_same(full_view.get("payload", null), wide)
		and full_view.get("familyResultsById", {}).has("trees")
		and rocks_proof.get("disposition", "") == "complete_empty",
		"non-tree support projection omits tree index rows while retaining the same full tree producer authority")
	var duplicate_subset := subset_index.publish_source_domain_family_projection(WORLD_ID,
		Vector2i.ZERO, wide, {"surface_rocks":[]}, full_view, full_publication_token,
		["surface_rocks", "surface_rocks"])
	var missing_subset_rows := subset_index.publish_source_domain_family_projection(WORLD_ID,
		Vector2i.ZERO, wide, {}, full_view, full_publication_token, ["surface_rocks"])
	var unselected_family_rows := subset_index.publish_source_domain_family_projection(WORLD_ID,
		Vector2i.ZERO, wide, {"trees":[]}, full_view, full_publication_token,
		["surface_rocks"])
	var narrow_projection := ProducerDomain.project_source_domain_family_bundle_to_band(
		narrow, section, ProducerDomain.section_bounds(section), artifact_a)
	var unrelated_band := subset_index.register_source_family_section_band_projection(
		WORLD_ID, Vector2i.ZERO, section, narrow, narrow_projection, ["ore"])
	var duplicate_band := subset_index.register_source_family_section_band_projection(
		WORLD_ID, Vector2i.ZERO, section, wide, full_projection,
		["surface_rocks", "surface_rocks"])
	var narrow_hold: Dictionary = resolver.acquire_ecology_catalog_artifact_lease(
		String(narrow.catalogArtifactId), "synthetic_unrelated_capture", "unrelated-test", WORLD_ID, 1)
	var narrow_admitted: Dictionary = resolver.admit_ecology_source_publication(
		narrow, String(narrow_hold.get("leaseToken", "")), "synthetic_unrelated_capture", "unrelated-test")
	resolver.release_ecology_catalog_artifact_lease(String(narrow_hold.get("leaseToken", "")))
	var unrelated_subset := subset_index.publish_source_domain_family_projection(WORLD_ID,
		Vector2i.ZERO, narrow, {"surface_rocks":[]}, narrow_admitted.get("view", {}),
		String(narrow_admitted.get("leaseToken", "")), ["surface_rocks"])
	var tree_proof := ProducerDomain.source_family_result(wide, "trees", artifact_a)
	var tree_alias_index: Dictionary = subset_index._tree_publication_member_alias_index(full_view)
	var family_tree_row: Dictionary = tree_proof.get("sourceRows", [])[0]
	var valid_tree_alias: Dictionary = subset_index._tree_publication_member_alias_for_family_row(
		tree_alias_index.get("rowsByKey", {}), family_tree_row)
	var publication_tree_row: Dictionary = full_view.get("payload", {}).get("sourceRows", [])[0]
	var missing_tree_alias := subset_index._tree_publication_member_alias_for_family_row(
		{}, family_tree_row)
	var tree_member_key := ProducerDomain.source_publication_member_key(
		String(publication_tree_row.get("producerFamily", "")),
		String(publication_tree_row.get("sourceId", "")),
		String(publication_tree_row.get("sourcePartId", "")))
	var ambiguous_alias_view := {"payload":{"sourceRows":[publication_tree_row,
		publication_tree_row.duplicate(true)]}, "memberIndex":{tree_member_key:0,
		"fixture-invalid-extra-member":1}}
	var ambiguous_tree_alias_index: Dictionary = subset_index._tree_publication_member_alias_index(
		ambiguous_alias_view)
	_check(tree_alias_index.get("status", "") == "ready"
		and valid_tree_alias.get("status", "") == "ready"
		and not is_same(family_tree_row, publication_tree_row)
		and is_same(valid_tree_alias.get("row", null), publication_tree_row)
		and missing_tree_alias.get("reason", "") == "tree_band_authority_source_row_alias_missing"
		and ambiguous_tree_alias_index.get("reason", "") ==
			"tree_band_authority_publication_member_alias_ambiguous",
		"family coverage clones resolve only to one exact admitted publication row alias", {
			"validAliasStatus":String(valid_tree_alias.get("status", "")),
			"missingAliasReason":String(missing_tree_alias.get("reason", "")),
			"ambiguousAliasReason":String(ambiguous_tree_alias_index.get("reason", ""))})
	var duplicate_tree_row := row.duplicate(true)
	duplicate_tree_row["familyRevision"] = String(tree_proof.get("familyRevision", ""))
	duplicate_tree_row["producerSnapshotRevision"] = duplicate_tree_row.familyRevision
	duplicate_tree_row["familyPolicyRevision"] = String(tree_proof.get("familyPolicyRevision", ""))
	duplicate_tree_row["familyPolicyDigest"] = String(tree_proof.get("familyPolicyDigest", ""))
	duplicate_tree_row["familyManifestDigest"] = String(tree_proof.get("sourceManifestDigest", ""))
	var duplicate_member_rows := subset_index.publish_source_domain_family_projection(WORLD_ID,
		Vector2i.ZERO, wide, {"trees":[duplicate_tree_row, duplicate_tree_row]},
		full_view, full_publication_token, ["trees"])
	_check(duplicate_subset.get("status", "") != "ready"
		and duplicate_subset.get("reason", "") == "ecology_source_family_selection_invalid"
		and missing_subset_rows.get("status", "") != "ready"
		and missing_subset_rows.get("reason", "") == "ecology_source_family_rows_missing"
		and unselected_family_rows.get("status", "") != "ready"
		and unselected_family_rows.get("reason", "") == "ecology_source_family_rows_unselected"
		and duplicate_member_rows.get("status", "") != "ready"
		and duplicate_member_rows.get("reason", "") == "ecology_source_family_row_duplicate"
		and unrelated_subset.get("status", "") != "ready"
		and unrelated_subset.get("reason", "") == "ecology_source_family_selection_unrelated"
		and unrelated_band.get("status", "") != "ready"
		and unrelated_band.get("reason", "") == "ecology_band_projection_selection_unrelated"
		and duplicate_band.get("status", "") != "ready"
		and duplicate_band.get("reason", "") == "ecology_band_projection_selection_invalid",
		"selected family APIs reject duplicate, unrelated, and missing family selections/rows")
	resolver.release_ecology_source_publication(String(narrow_admitted.get("leaseToken", "")))
	var tree_authority := subset_index.admit_tree_source_family_section_band(WORLD_ID,
		Vector2i.ZERO, section, wide, full_projection, full_view, full_publication_token)
	_check(tree_authority.get("status", "") == "ready"
		and tree_authority.get("expectedSourceIds", []) == ["family-tree"],
		"tree authority accepts its complete band from the same full publication view", {
			"status":String(tree_authority.get("status", "")),
			"reason":String(tree_authority.get("reason", "")),
			"expectedSourceIds":tree_authority.get("expectedSourceIds", [])})
	resolver.release_ecology_source_publication(full_publication_token)
	subset_index.reset()
	var leases_before_bad_rows := resolver.active_leases.size()
	var bad_rows := _publish_admitted_family(index, Vector2i.ZERO, narrow, {"trees":[row]})
	_check(bad_rows.get("status") != "ready" and bad_rows.get("reason") == "ecology_source_family_row_provenance_mismatch"
		and resolver.active_leases.size() == leases_before_bad_rows,
		"missing family member proof is rejected without leaking admission lease")
	_check(_publish_family(index, Vector2i.ZERO, narrow, {"trees":[row]}, artifact_a).get("status") == "ready",
		"narrow tree bundle publishes")
	_check(index.query_section(WORLD_ID, section).get("status") == "pending",
		"one complete family cannot close whole section")
	for chunk_value: Variant in census.get("sourceChunkKeys", []):
		var chunk: Vector2i = chunk_value
		var families: Array = []
		var rows: Dictionary = {}
		for family: String in ProducerDomain.REQUIRED_CATEGORIES:
			if chunk in closure.get(family, []):
				families.append(family)
				rows[family] = [row] if chunk == Vector2i.ZERO and family == "trees" else []
		var bundle := _family_bundle(chunk, [row] if chunk == Vector2i.ZERO else [], artifact_a, families)
		_check(_publish_family(index, chunk, bundle, rows, artifact_a).get("status") == "ready",
			"requested family closure chunk publishes %s" % str(chunk))
		for family: String in families:
			var family_lease: Dictionary = index._family_publication_leases.get(chunk, {}).get(family, {})
			var source_bundle: Dictionary = family_lease.get("view", {}).get("payload", {})
			var projected := ProducerDomain.project_source_domain_family_bundle_to_band(
				source_bundle, section, ProducerDomain.section_bounds(section), artifact_a)
			_check(projected.get("status", "") == "ready"
				and index.register_source_family_section_band_projection(WORLD_ID,
					chunk, section, source_bundle, projected).get("status", "") == "ready",
				"exact section-band receipt registers for %s/%s" % [str(chunk), family])
	var before := index.query_section(WORLD_ID, section)
	_check(before.get("status") == "ready" and before.get("supportOwnerDemands", []).size() == 1,
		"all exact family closures produce complete section", {
			"queryStatus":before.get("status", ""),
			"queryReason":before.get("reason", ""),
			"sourceChunkKey":before.get("sourceChunkKey", Vector2i.ZERO),
			"family":before.get("family", ""),
			"bandKey":before.get("bandKey", Vector3i.ZERO),
			"bandReceiptPresent":before.get("bandReceiptPresent", false)})
	var section_b := Vector3i(0, 0, 1)
	var tree_source_bundle: Dictionary = index._family_publication_leases[
		Vector2i.ZERO]["trees"].view.payload
	var projected_b := ProducerDomain.project_source_domain_family_bundle_to_band(
		tree_source_bundle, section_b, ProducerDomain.section_bounds(section_b), artifact_a)
	_check(projected_b.get("status", "") == "ready"
		and index.register_source_family_section_band_projection(WORLD_ID,
			Vector2i.ZERO, section_b, tree_source_bundle, projected_b).get("status", "") == "ready"
		and index._family_band_receipts[Vector2i.ZERO]["trees"].has(section)
		and index._family_band_receipts[Vector2i.ZERO]["trees"].has(section_b)
		and index.query_section(WORLD_ID, section).get("status", "") == "ready",
		"projecting a second full section identity retains the first section receipt")
	_check(_publish_family(index, Vector2i.ZERO, narrow, {"trees":[row]}, artifact_a).get("status") == "ready",
		"identical family republish accepted")
	var unchanged := index.query_section(WORLD_ID, section)
	_check(unchanged.get("status") == "ready" and unchanged.get("sourceIndexRevision") == before.get("sourceIndexRevision")
		and unchanged.get("supportOwnerDemands", []).size() == 1
		and unchanged.supportOwnerDemands[0].get("supportLeaseToken") == before.supportOwnerDemands[0].get("supportLeaseToken"),
		"identical family republish preserves section revision and member lease")
	var prior_receipt := {"schema":"ecology-support-section-install-receipt/v1", "sectionKey":section,
		"sourceIndexRevision":unchanged.sourceIndexRevision, "coverageDigest":unchanged.coverageCertificate.coverageDigest,
		"nativeReceipt":{"receiptId":"synthetic-before-local-revision"},
		"installedMemberReceipts":[_member_receipt(unchanged.supportOwnerDemands[0])], "verifiedAbsentMemberReceipts":[]}
	var retained_postings: Dictionary = index._postings_by_section.duplicate(true)
	resolver.synthetic_local_revision += 1
	var stale_local := index.query_section(WORLD_ID, section)
	_check(stale_local.get("status") == "pending"
		and stale_local.get("reason") == "synthetic_local_dependency_revision_changed"
		and not index._latest_query_by_section.has(section),
		"local dependency change invalidates cached ready query authority")
	var stale_local_ack := index.acknowledge_section_receipt(section, unchanged.sourceIndexRevision, prior_receipt)
	_check(stale_local_ack.get("status") == "pending"
		and stale_local_ack.get("reason") == "synthetic_local_dependency_revision_changed"
		and index._postings_by_section == retained_postings,
		"stale local receipt is rejected while existing source postings remain retained")
	resolver.synthetic_local_revision = 0
	resolver.local_checks_by_publication.clear()
	var local_recovered := index.query_section(WORLD_ID, section)
	_check(local_recovered.get("status") == "ready"
		and local_recovered.get("sourceIndexRevision") == unchanged.get("sourceIndexRevision")
		and resolver.local_checks_by_publication.values().all(func(value: Variant) -> bool: return value == 1),
		"query retries complete closure and checks each publication only once")
	resolver.synthetic_local_revision += 1
	var direct_stale_ack := index.acknowledge_section_receipt(section, unchanged.sourceIndexRevision, prior_receipt)
	_check(direct_stale_ack.get("status") == "pending"
		and direct_stale_ack.get("reason") == "synthetic_local_dependency_revision_changed"
		and index._postings_by_section == retained_postings,
		"acknowledgement rechecks local dependencies even without an intervening query")
	resolver.synthetic_local_revision = 0
	resolver.active_catalog_artifact_id = String(artifact_b.artifactId)
	var next_census := ProducerDomain.source_domain_census_certificate(section,
		_compact_source_inputs(artifact_b, Vector2i.ZERO), artifact_b)
	index.set_required_source_domains_by_family(section, closure, next_census)
	var partial_b := _family_bundle(Vector2i.ZERO, [row], artifact_b, ["trees"])
	_check(_publish_family(index, Vector2i.ZERO, partial_b, {"trees":[row]}, artifact_b).get("status") == "ready",
		"new owner can publish one complete family")
	_check(index.query_section(WORLD_ID, section).get("status") == "pending",
		"partial owner replacement cannot certify remaining old-owner families")
	var stale_owner_receipt := {"schema":"ecology-support-section-install-receipt/v1", "sectionKey":section,
		"sourceIndexRevision":before.sourceIndexRevision, "coverageDigest":before.coverageCertificate.coverageDigest,
		"nativeReceipt":{"receiptId":"synthetic-old-family-owner"},
		"installedMemberReceipts":[_member_receipt(before.supportOwnerDemands[0])],
		"verifiedAbsentMemberReceipts":[]}
	_check(index.acknowledge_section_receipt(section, before.sourceIndexRevision,
		stale_owner_receipt).get("status") != "ready", "partial owner swap rejects prior owner receipt")
	for chunk_value: Variant in census.get("sourceChunkKeys", []):
		var chunk: Vector2i = chunk_value
		var families: Array = []
		var rows: Dictionary = {}
		for family: String in ProducerDomain.REQUIRED_CATEGORIES:
			if chunk in closure.get(family, []):
				families.append(family)
				rows[family] = [row] if chunk == Vector2i.ZERO and family == "trees" else []
		_check(_publish_family(index, chunk,
			_family_bundle(chunk, [row] if chunk == Vector2i.ZERO else [], artifact_b, families), rows, artifact_b).get("status") == "ready",
			"same-content replacement owner refreshes family proof %s" % str(chunk))
	_check(index.query_section(WORLD_ID, section).get("reason", "")
		== "ecology_support_source_family_band_incomplete",
		"old owner band receipts become pending after canonical family owner changes")
	for chunk_value: Variant in census.get("sourceChunkKeys", []):
		var chunk: Vector2i = chunk_value
		for family_value: Variant in ProducerDomain.REQUIRED_CATEGORIES:
			var family := String(family_value)
			if chunk not in closure.get(family, []): continue
			var family_lease: Dictionary = index._family_publication_leases.get(chunk, {}).get(family, {})
			var source_bundle: Dictionary = family_lease.get("view", {}).get("payload", {})
			var projected := ProducerDomain.project_source_domain_family_bundle_to_band(
				source_bundle, section, ProducerDomain.section_bounds(section), artifact_b)
			_check(projected.get("status", "") == "ready"
				and index.register_source_family_section_band_projection(WORLD_ID,
					chunk, section, source_bundle, projected).get("status", "") == "ready",
				"replacement owner publishes current family-band proof for %s/%s" % [str(chunk), family])
	var refreshed := index.query_section(WORLD_ID, section)
	_check(refreshed.get("status") == "ready" and refreshed.get("supportOwnerDemands", []).size() == 1
		and resolver.active_count_for(String(artifact_a.artifactId)) == 0,
		"new family owner remains queryable and releases old leases", {
			"queryStatus":refreshed.get("status", ""), "queryReason":refreshed.get("reason", ""),
			"demandCount":refreshed.get("supportOwnerDemands", []).size(),
			"oldOwnerLeaseCount":resolver.active_count_for(String(artifact_a.artifactId)),
			"demands":refreshed.get("supportOwnerDemands", [])})
	var empty := _family_bundle(Vector2i.ZERO, [], artifact_b, ["trees"])
	_check(_publish_admitted_family(index, Vector2i.ZERO, empty,
		{"trees":[]}).get("status") == "ready", "explicit empty tree family replaces prior tree")
	var empty_band := ProducerDomain.project_source_domain_family_bundle_to_band(
		empty, section, ProducerDomain.section_bounds(section), artifact_b)
	var pending_removal := index.query_section(WORLD_ID, section)
	var pending_tombstone_demands: Array = pending_removal.get("supportOwnerDemands", [])
	var pending_tombstone: Dictionary = pending_tombstone_demands[0] \
		if not pending_tombstone_demands.is_empty() else {}
	_check(pending_removal.get("status") == "pending"
		and pending_removal.get("reason", "") == "ecology_support_source_family_band_incomplete"
		and pending_removal.get("sourceIndexRevision", -1) != refreshed.get("sourceIndexRevision", -1)
		and pending_tombstone_demands.size() == 1
		and pending_tombstone.get("sourceId", "") == "family-tree"
		and pending_tombstone.get("memberId", "") == "branches:00000000"
		and pending_tombstone.get("state", "") == "tombstoned"
		and pending_tombstone.get("demandPurpose", "") == "retryable_tombstone_refresh"
		and pending_tombstone.get("retryable", false)
		and pending_tombstone.get("sourceIndexRevision", -1) == pending_removal.get("sourceIndexRevision", -2)
		and pending_removal.get("retryableTombstoneDemands", []) == pending_tombstone_demands
		and not pending_removal.has("contributors")
		and not pending_removal.has("coverageCertificate")
		and not index._latest_query_by_section.has(section),
		"stale family-band query exposes only section tombstones as pending retry demand", {
			"status":pending_removal.get("status", ""),
			"reason":pending_removal.get("reason", ""),
			"sectionRevision":pending_removal.get("sourceIndexRevision", -1),
			"demands":pending_tombstone_demands,
			"contributorsPresent":pending_removal.has("contributors"),
			"certificatePresent":pending_removal.has("coverageCertificate")})
	var stale_band_receipt := {"schema":"ecology-support-section-install-receipt/v1",
		"sectionKey":section, "sourceIndexRevision":refreshed.sourceIndexRevision,
		"coverageDigest":refreshed.coverageCertificate.coverageDigest,
		"nativeReceipt":{"receiptId":"synthetic-stale-before-empty-band"},
		"installedMemberReceipts":[_member_receipt(refreshed.supportOwnerDemands[0])],
		"verifiedAbsentMemberReceipts":[]}
	_check(index.acknowledge_section_receipt(section, refreshed.sourceIndexRevision,
		stale_band_receipt).get("status") == "pending",
		"pending tombstone demand cannot authorize a stale band receipt")
	_check(empty_band.get("status", "") == "ready"
		and index.register_source_family_section_band_projection(WORLD_ID,
			Vector2i.ZERO, section, empty, empty_band).get("status", "") == "ready",
		"complete-empty family publishes an explicit empty section-band receipt")
	var removed := index.query_section(WORLD_ID, section)
	_check(removed.get("sourceIndexRevision", -1) != refreshed.get("sourceIndexRevision", -1),
		"changed empty family invalidates affected section revision")
	_check(removed.get("status") == "ready" and removed.get("supportOwnerDemands", []).size() == 1
		and removed.supportOwnerDemands[0].get("state") == "tombstoned",
		"family empty retains old member until verified absence receipt")
	if removed.get("status") == "ready" and removed.get("supportOwnerDemands", []).size() == 1:
		var receipt := {"schema":"ecology-support-section-install-receipt/v1", "sectionKey":section,
			"sourceIndexRevision":removed.sourceIndexRevision, "coverageDigest":removed.coverageCertificate.coverageDigest,
			"nativeReceipt":{"receiptId":"synthetic-family-empty"}, "installedMemberReceipts":[],
			"verifiedAbsentMemberReceipts":[_member_receipt(removed.supportOwnerDemands[0])]}
		_check(index.acknowledge_section_receipt(section, removed.sourceIndexRevision, receipt).get("status") == "ready",
			"family tombstone retirement requires matching absence receipt")
	# The preceding absence ACK intentionally consumed its tombstone. Recreate a
	# real nonempty-to-empty transition so the later overlay query proves retention
	# of a fresh, still-unacknowledged tombstone.
	var restored_tree_bundle := _family_bundle(Vector2i.ZERO, [row], artifact_b, ["trees"])
	var restored_tree_publish := _publish_family(index, Vector2i.ZERO,
		restored_tree_bundle, {"trees":[row]}, artifact_b)
	var restored_tree_band := ProducerDomain.project_source_domain_family_bundle_to_band(
		restored_tree_bundle, section, ProducerDomain.section_bounds(section), artifact_b)
	var restored_tree_band_receipt := index.register_source_family_section_band_projection(
		WORLD_ID, Vector2i.ZERO, section, restored_tree_bundle, restored_tree_band)
	var restored_tree_query: Dictionary = index.query_section(WORLD_ID, section)
	_check(restored_tree_publish.get("status", "") == "ready"
		and restored_tree_band_receipt.get("status", "") == "ready"
		and restored_tree_query.get("status", "") == "ready"
		and restored_tree_query.get("supportOwnerDemands", []).size() == 1
		and restored_tree_query.supportOwnerDemands[0].get("state", "") == "compiled",
		"tree source becomes installed again after the prior tombstone ACK")
	var fresh_empty_publish := _publish_admitted_family(index, Vector2i.ZERO,
		empty, {"trees":[]})
	var fresh_empty_band := ProducerDomain.project_source_domain_family_bundle_to_band(
		empty, section, ProducerDomain.section_bounds(section), artifact_b)
	var fresh_empty_band_receipt := index.register_source_family_section_band_projection(
		WORLD_ID, Vector2i.ZERO, section, empty, fresh_empty_band)
	var fresh_empty_query: Dictionary = index.query_section(WORLD_ID, section)
	_check(fresh_empty_publish.get("status", "") == "ready"
		and fresh_empty_band_receipt.get("status", "") == "ready"
		and fresh_empty_query.get("status", "") == "ready"
		and fresh_empty_query.get("supportOwnerDemands", []).size() == 1
		and fresh_empty_query.supportOwnerDemands[0].get("state", "") == "tombstoned",
		"fresh empty-family publication retains a new tombstone until receipt ACK")
	var empty_tree_lease: Dictionary = index._family_publication_leases.get(
		Vector2i.ZERO, {}).get("trees", {})
	var empty_tree_view: Dictionary = empty_tree_lease.get("view", {})
	var empty_projection := ProducerDomain.project_source_domain_family_bundle_to_band(
		empty, section, ProducerDomain.section_bounds(section), artifact_b)
	var authority_result: Dictionary = index.admit_tree_source_family_section_band(
		WORLD_ID, Vector2i.ZERO, section, empty, empty_projection, empty_tree_view,
		String(empty_tree_lease.get("leaseToken", "")))
	_check(authority_result.get("status", "") == "ready"
		and authority_result.get("expectedSourceIds", null) == []
		and authority_result.get("authority", {}).get("producerDisposition", "") == "complete_empty",
		"complete-empty producer tree band is admitted independently of compiled rows")
	var authority_revision := index._section_revision(section)
	var admitted_authority: Dictionary = authority_result.get("authority", {})
	var authority_lease: Dictionary = index._tree_overlay_publication_leases.get(
		Vector2i.ZERO, {}).get(section, {})
	var authority_view: Dictionary = authority_lease.get("view", {})
	var authority_family_result: Dictionary = authority_view.get(
		"familyResultsById", {}).get("trees", {})
	var authority_current_probe: Variant = resolver.ecology_source_publication_local_is_current(
		authority_view, String(authority_lease.get("leaseToken", "")))
	var authority_record_current := true
	for authority_source_row_value: Variant in authority_family_result.get("sourceRows", []):
		if not authority_source_row_value is Dictionary:
			authority_record_current = false
			break
		var authority_record_probe: Dictionary = resolver.ecology_source_publication_record_is_current(
			 authority_view, String(authority_lease.get("leaseToken", "")),
			 authority_source_row_value)
		if String(authority_record_probe.get("status", "")) != "ready":
			authority_record_current = false
			break
	var authority_digest_probe: Dictionary = admitted_authority.duplicate(true)
	authority_digest_probe.erase("authorityDigest")
	authority_digest_probe.erase("publicationLeaseToken")
	var duplicate_authority: Dictionary = index.admit_tree_source_family_section_band(
		WORLD_ID, Vector2i.ZERO, section, empty, empty_projection, empty_tree_view,
		String(empty_tree_lease.get("leaseToken", "")))
	var post_duplicate_local_current: Dictionary = resolver.ecology_source_publication_local_is_current(
		authority_view, String(authority_lease.get("leaseToken", "")))
	_check(duplicate_authority.get("status", "") == "ready"
		and not bool(duplicate_authority.get("changed", true))
		and index._section_revision(section) == authority_revision
		and post_duplicate_local_current.get("status", "") == "ready"
		and index._tree_band_authority_current(admitted_authority, authority_lease,
			WORLD_ID, Vector2i.ZERO, section),
		"repeated source authority admission preserves revision")
	var empty_compiled_artifact := {"schema":"compiled-tree-section-source/v2",
		"sourceRevision":String(empty.get("sourceRevision", "")),
		"treeFamilyRevision":String(authority_result.authority.get("sourceFamilyRevision", "")),
		"treeFamilyManifestDigest":String(authority_result.authority.get(
			"sourceFamilyManifestDigest", "")),
		"worldId":WORLD_ID, "sourceChunkKey":Vector2i.ZERO,
		"sectionKey":section,
		"authorityDigest":String(authority_result.authority.get("authorityDigest", "")),
		"sources":[], "batches":[], "resourceBindings":{},
		"expectedSourceIds":[], "sourceArtifactDigests":[],
		"disposition":"complete_empty",
		"sourceCompletionManifest":[],
		"sourceCompletionDigest":index._sha256_bytes(var_to_bytes([])),
		"ownerBatchContributors":[],
		"ownerBatchPayloadDigest":index._sha256_bytes(var_to_bytes([]))}
	_freeze_value(empty_compiled_artifact)
	var missing_completion_artifact: Dictionary = empty_compiled_artifact.duplicate(true)
	missing_completion_artifact.erase("sourceCompletionManifest")
	_freeze_value(missing_completion_artifact)
	var missing_completion: Dictionary = index.register_tree_section_geometry_overlay(
		WORLD_ID, Vector2i.ZERO, section, [], missing_completion_artifact, [])
	_check(missing_completion.get("status", "") == "pending"
		and missing_completion.get("reason", "") == "tree_overlay_artifact_completion_proof_missing"
		and not index._tree_section_geometry_overlays.get(Vector2i.ZERO, {}).has(section),
		"an empty source list without explicit completion proof cannot certify empty geometry")
	var forged_batch_digest_artifact: Dictionary = empty_compiled_artifact.duplicate(true)
	forged_batch_digest_artifact["ownerBatchPayloadDigest"] = "f".repeat(64)
	_freeze_value(forged_batch_digest_artifact)
	var forged_batch_digest: Dictionary = index.register_tree_section_geometry_overlay(
		WORLD_ID, Vector2i.ZERO, section, [], forged_batch_digest_artifact, [])
	_check(forged_batch_digest.get("status", "") == "pending"
		and forged_batch_digest.get("reason", "") == "tree_overlay_artifact_owner_batch_digest_mismatch"
		and not index._tree_section_geometry_overlays.get(Vector2i.ZERO, {}).has(section),
		"a mismatched compiled owner-batch digest cannot certify section geometry")
	var empty_overlay: Dictionary = index.register_tree_section_geometry_overlay(
		WORLD_ID, Vector2i.ZERO, section, [], empty_compiled_artifact, [])
	_check(empty_overlay.get("status", "") == "ready"
		and empty_overlay.get("sourceCompletionCount", -1) == 0
		and empty_overlay.get("ownerMemberCount", -1) == 0
		and empty_overlay.get("supportMemberCount", -1) == 0
		and empty_overlay.get("overlay", {}).get("disposition", "") == "complete_empty",
		"complete-empty section geometry is distinct from an absent overlay", {
			"authorityStatus":authority_result.get("status", ""),
			"authorityReason":authority_result.get("reason", ""),
			"overlayStatus":empty_overlay.get("status", ""),
			"overlayReason":empty_overlay.get("reason", ""),
			"overlayDisposition":empty_overlay.get("overlay", {}).get("disposition", ""),
			"authorityCurrent":index._tree_band_authority_current(admitted_authority,
				authority_lease, WORLD_ID, Vector2i.ZERO, section),
			"authorityEmpty":admitted_authority.is_empty(),
			"leaseEmpty":authority_lease.is_empty(),
			"indexWorldMatches":index._world_id == WORLD_ID,
			"resolverValid":is_instance_valid(index._catalog_resolver),
			"leaseViewAlias":is_same(authority_view, authority_lease.get("view", {})),
			"familyResultsIsDictionary":authority_view.get("familyResultsById", {}) is Dictionary,
			"familyResultIsDictionary":authority_view.get("familyResultsById", {}).get("trees", {}) is Dictionary,
			"authorityDigest":String(admitted_authority.get("authorityDigest", "")),
			"leaseTokenMatches":String(admitted_authority.get("publicationLeaseToken", "")) \
				== String(authority_lease.get("leaseToken", "")),
			"publicationIdMatches":String(admitted_authority.get("sourcePublicationId", "")) \
				== String(authority_view.get("publicationId", "")),
			"localCurrentStatus":String(authority_current_probe.get("status", "")),
			"authorityDigestRecomputes":String(admitted_authority.get("authorityDigest", "")) \
				== index._sha256_bytes(var_to_bytes(authority_digest_probe)),
			"familyRevisionMatches":String(admitted_authority.get("sourceFamilyRevision", "")) \
				== String(authority_family_result.get("familyRevision", "")),
			"familyManifestMatches":String(admitted_authority.get("sourceFamilyManifestDigest", "")) \
				== String(authority_family_result.get("sourceManifestDigest", "")),
			"familyStatusReady":String(authority_family_result.get("status", "")) == "ready",
			"recordCurrent":authority_record_current,
			"worldMatches":String(admitted_authority.get("worldId", "")) == WORLD_ID,
			"worldEpochMatches":int(admitted_authority.get("worldEpoch", -1)) == index._world_epoch,
			"sourceChunkMatches":admitted_authority.get("sourceChunkKey", null) == Vector2i.ZERO,
			"sectionMatches":admitted_authority.get("sectionKey", null) == section,
			"boundsMatch":admitted_authority.get("bandBounds", null) == ProducerDomain.section_bounds(section),
			"schemaMatches":String(admitted_authority.get("schema", "")) == "ecology-tree-source-family-band-authority/v1",
			"contentDigestMatches":String(authority_view.get("contentDigest", "")) \
				== String(admitted_authority.get("sourcePublicationContentDigest", "")),
			"sourceCompletionCount":empty_overlay.get("sourceCompletionCount", -1),
			"ownerMemberCount":empty_overlay.get("ownerMemberCount", -1),
			"supportMemberCount":empty_overlay.get("supportMemberCount", -1)})
	var overlay_revision := index._section_revision(section)
	var duplicate_overlay: Dictionary = index.register_tree_section_geometry_overlay(
		WORLD_ID, Vector2i.ZERO, section, [], empty_compiled_artifact, [])
	_check(duplicate_overlay.get("status", "") == "ready"
		and not bool(duplicate_overlay.get("changed", true))
		and index._section_revision(section) == overlay_revision,
		"duplicate section overlay admission does not churn the index revision")
	var overlay_query: Dictionary = index.query_section(WORLD_ID, section)
	var overlay_query_demands: Array = overlay_query.get("supportOwnerDemands", [])
	var overlay_query_states: Array[String] = []
	for demand_value: Variant in overlay_query_demands:
		if demand_value is Dictionary:
			overlay_query_states.append(String(demand_value.get("state", "")))
	_check(overlay_query.get("status", "") == "ready"
		and overlay_query.get("coverageCertificate", {}).get(
			"treeSectionGeometryOverlays", []).size() == 1
		and overlay_query_demands.size() == 1
		and overlay_query_demands[0].get("state", "") == "tombstoned",
		"section query consumes only the complete current tree overlay and preserves prior tombstones", {
			"status":String(overlay_query.get("status", "")),
			"reason":String(overlay_query.get("reason", "")),
			"treeOverlayReceiptCount":overlay_query.get("coverageCertificate", {}).get(
				"treeSectionGeometryOverlays", []).size(),
			"supportOwnerDemandCount":overlay_query_demands.size(),
			"supportOwnerDemandStates":overlay_query_states,
			"treeAuthorityCurrent":index._tree_band_authority_current(admitted_authority,
				authority_lease, WORLD_ID, Vector2i.ZERO, section),
			"treeOverlayCurrent":index._tree_section_overlay_current(admitted_authority,
				empty_overlay.get("overlay", {}), authority_lease,
				WORLD_ID, Vector2i.ZERO, section),
			"retiredTreeOverlayRows":index._retired_tree_section_overlays.get(section, []).size(),
			"retiredPostingRows":index._retired_postings_by_section.get(section, {}).size()})
	if overlay_query.get("status", "") == "ready" \
			and overlay_query.get("supportOwnerDemands", []).size() == 1:
		var overlay_receipt := {"schema":"ecology-support-section-install-receipt/v1",
			"sectionKey":section, "sourceIndexRevision":overlay_query.sourceIndexRevision,
			"coverageDigest":overlay_query.coverageCertificate.coverageDigest,
			"nativeReceipt":{"receiptId":"synthetic-tree-overlay-empty"},
			"installedMemberReceipts":[],
			"verifiedAbsentMemberReceipts":[_member_receipt(
				overlay_query.supportOwnerDemands[0])]}
		_check(index.acknowledge_section_receipt(section,
			overlay_query.sourceIndexRevision, overlay_receipt).get("status", "") == "ready",
			"tree overlay tombstone retires only after the matching install receipt")
	resolver.synthetic_local_revision = 1
	var stale_overlay_query: Dictionary = index.query_section(WORLD_ID, section)
	_check(stale_overlay_query.get("status", "") == "pending"
		and not index._latest_query_by_section.has(section),
		"stale publication currentness rejects tree overlay query authority")
	resolver.synthetic_local_revision = 0
	index.release_section_demand(section)
	var authority_retained_before_teardown: bool = index._tree_source_family_band_authorities.get(
		Vector2i.ZERO, {}).has(section)
	var overlay_retained_before_teardown: bool = index._tree_section_geometry_overlays.get(
		Vector2i.ZERO, {}).has(section)
	var detached_before_teardown: bool = index._detached_tree_sections.has(section)
	var consumer_leases_before_teardown := int(resolver._catalog_store.
		source_publication_diagnostics_snapshot().get("consumerLeaseCount", -1))
	var retained_after_demand_release: bool = authority_retained_before_teardown \
		and overlay_retained_before_teardown and detached_before_teardown \
		and consumer_leases_before_teardown > 0
	var installed_tree_receipt: Dictionary = index._receipt_by_section.get(section, {})
	var resolver_leases_before_teardown := resolver.active_leases.size()
	var teardown_result := index.acknowledge_section_teardown(section, {
		"schema":"ecology-support-section-teardown-receipt/v1",
		"sectionKey":section,
		"installedReceiptId":String(installed_tree_receipt.get("receiptId", "")),
		"nativeReceipt":{"receiptId":"synthetic-tree-overlay-unload"},
		"verifiedAbsent":true})
	_check(resolver.active_leases.is_empty()
		and resolver._catalog_store.source_publication_diagnostics_snapshot().get("consumerLeaseCount", -1) == 0
		and retained_after_demand_release
		and teardown_result.get("status", "") == "ready",
		"tree source leases and old representation evidence survive demand release until native teardown receipt", {
			"retainedBeforeTeardown":retained_after_demand_release,
			"authorityPresentBeforeTeardown":authority_retained_before_teardown,
			"overlayPresentBeforeTeardown":overlay_retained_before_teardown,
			"detachedBeforeTeardown":detached_before_teardown,
			"resolverLeaseCountBeforeTeardown":resolver_leases_before_teardown,
			"consumerLeaseCountBeforeTeardown":consumer_leases_before_teardown,
			"resolverLeaseCountAfterTeardown":resolver.active_leases.size(),
			"consumerLeaseCountAfterTeardown":resolver._catalog_store.
				source_publication_diagnostics_snapshot().get("consumerLeaseCount", -1),
			"teardownStatus":String(teardown_result.get("status", "")),
			"teardownReason":String(teardown_result.get("reason", "")),
			"receiptStoredId":String(installed_tree_receipt.get("receiptId", "")),
			"teardownRequestedId":String(installed_tree_receipt.get("receiptId", ""))})


func _family_bundle(chunk: Vector2i, support_rows: Array, artifact: Dictionary,
		families: Array) -> Dictionary:
	var inputs := _compact_source_inputs(artifact, chunk)
	var removal_digest := "b".repeat(64)
	var revision := ProducerDomain.source_domain_revision(WORLD_ID, "fixture-seed", chunk, inputs, removal_digest, artifact)
	var producer_rows: Array = []
	for support: Dictionary in support_rows:
		var row: Dictionary = support.duplicate(true)
		row["producerFamily"] = String(row.get("family", ""))
		row["supportProof"] = {"status":"ready",
			"worldBounds":row.get("conservativeWorldBounds", AABB())}
		row["sourceRevision"] = revision
		row["producerRevision"] = revision
		row["sourceChunkKey"] = chunk
		producer_rows.append(row)
	var request := ProducerDomain.build_source_family_request(families, WORLD_ID,
		"fixture-seed", chunk, inputs, removal_digest, artifact)
	return ProducerDomain.seal_source_domain_family_bundle({"worldId":WORLD_ID,
		"worldSeed":"fixture-seed", "sourceChunkKey":chunk, "sourceInputs":inputs,
		"sourceRows":producer_rows, "actorIntentSnapshot":[], "familyRequest":request,
		"completedFamilies":families, "removedSourceProjectionDigest":removal_digest}, artifact)


func _publish_family(index: Object, chunk: Vector2i, bundle: Dictionary,
		rows_by_family: Dictionary, artifact: Dictionary) -> Dictionary:
	var admitted: Dictionary = {}
	for family: String in rows_by_family:
		var proof := ProducerDomain.source_family_result(bundle, family, artifact)
		var rows: Array = []
		for value: Dictionary in rows_by_family[family]:
			var row := value.duplicate(true)
			row["familyRevision"] = String(proof.get("familyRevision", ""))
			row["producerSnapshotRevision"] = row.familyRevision
			row["familyPolicyRevision"] = String(proof.get("familyPolicyRevision", ""))
			row["familyPolicyDigest"] = String(proof.get("familyPolicyDigest", ""))
			row["familyManifestDigest"] = String(proof.get("sourceManifestDigest", ""))
			rows.append(row)
		admitted[family] = rows
	return _publish_admitted_family(index, chunk, bundle, admitted)


func _publish_admitted_family(index: Object, chunk: Vector2i, bundle: Dictionary,
		rows: Dictionary) -> Dictionary:
	var resolver: Object = index._catalog_resolver
	resolver.publication_sequence += 1
	var key := "index-contract:%d" % int(resolver.publication_sequence)
	var hold: Dictionary = resolver.acquire_ecology_catalog_artifact_lease(
		String(bundle.get("catalogArtifactId", "")), "synthetic_index_capture", key, WORLD_ID, 1)
	if hold.get("status") != "ready": return hold
	var admitted: Dictionary = resolver.admit_ecology_source_publication(bundle, String(hold.leaseToken), "synthetic_index_capture", key)
	resolver.release_ecology_catalog_artifact_lease(String(hold.leaseToken))
	if admitted.get("status") != "ready": return admitted
	var result: Dictionary = index.publish_source_domain_family_bundle(WORLD_ID, chunk,
		bundle, rows, admitted.view, String(admitted.leaseToken))
	resolver.release_ecology_source_publication(String(admitted.leaseToken))
	return result


func _assert_publication_boundary(resolver: Object, bundle: Dictionary) -> void:
	var hold: Dictionary = resolver.acquire_ecology_catalog_artifact_lease(
		String(bundle.catalogArtifactId), "synthetic_alias_probe", "probe", WORLD_ID, 1)
	var admitted: Dictionary = resolver.admit_ecology_source_publication(bundle,
		String(hold.get("leaseToken", "")), "synthetic_alias_probe", "first")
	resolver.release_ecology_catalog_artifact_lease(String(hold.get("leaseToken", "")))
	var view: Dictionary = admitted.get("view", {})
	var second: Dictionary = resolver.acquire_ecology_source_publication(
		String(admitted.get("publicationId", "")), "synthetic_alias_probe", "second")
	_check(admitted.get("status") == "ready" and second.get("status") == "ready"
		and is_same(view.get("payload", {}), bundle) and is_same(second.get("view", {}), view),
		"publication consumers share the exact admitted bundle and view aliases")
	var detached: Dictionary = ProducerDomain.freeze_value(view.duplicate(true))
	_check(resolver.ecology_source_publication_local_is_current(detached,
		String(second.get("leaseToken", ""))).get("status") != "ready",
		"equal detached publication view is rejected")
	resolver.release_ecology_source_publication(String(admitted.get("leaseToken", "")))
	_check(resolver.resolve_ecology_source_publication(String(second.get("leaseToken", "")),
		WORLD_ID, 1).get("status") == "ready", "independent consumer survives first publication lease release")
	resolver.release_ecology_source_publication(String(second.get("leaseToken", "")))
	_check(resolver.resolve_ecology_source_publication(String(second.get("leaseToken", "")),
		WORLD_ID, 1).get("status") != "ready", "released publication token cannot resolve cached alias")


func _support_policy_inputs() -> Dictionary:
	var profile := {"biomeId":"default",
		"tree_scale":{"value":1.0}, "tree_height_min":{"value":0.0},
		"tree_height_max":{"value":6.0}, "crown_radius_min":{"value":0.0},
		"crown_radius_max":{"value":1.0}, "trunk_radius_min":{"value":0.0},
		"trunk_radius_max":{"value":0.3}, "wind_response":{"value":0.0},
		"tree_families":["broadleaf_tree"], "rock_scale":{"value":1.0},
		"detail_scale_maxs":[]}
	var profiles := {"schemaVersion":1, "fallbackId":"default",
		"contentIdentity":"c".repeat(64), "profiles":[profile]}
	var tree_envelope: Dictionary = ProducerDomain.derive_tree_grammar_support_envelope(profiles)
	var rock_envelope := {"status":"ready",
		"profileCatalogRevision":String(profiles.contentIdentity),
		"eligibleAssetSetDigest":"d".repeat(64),
		"digest":"e".repeat(64), "assetSetDigest":"f".repeat(64),
		"registryRevision":"synthetic-rock-registry-v1",
		"maxHorizontalSupportMeters":1.0, "maxVerticalSupportMeters":1.0,
		"assetRows":[{"assetId":"synthetic-rock", "bounds":AABB(Vector3(-0.5, 0.0, -0.5), Vector3.ONE)}]}
	return {"biomeProfileSnapshot":profiles,
		"treeGrammarEnvelopeDigest":String(tree_envelope.get("digest", "")),
		"rockSupportEnvelope":rock_envelope,
		"terrainVolumeChunkRevision":"fixture-terrain",
		"structureAdmissionRevision":"fixture-structures",
		"structureAdmissionStatus":"ready"}


func _catalog_artifact(artifact_id: String, owner_identity: String) -> Dictionary:
	var catalog_inputs := _support_policy_inputs()
	var policy: Dictionary = ProducerDomain.support_policy(catalog_inputs)
	var artifact := {"schema":"ecology-producer-catalog-artifact/v2",
		"artifactId":artifact_id, "worldId":WORLD_ID, "worldSeed":"fixture-seed",
		"worldEpoch":1, "ownerIdentity":owner_identity,
		"catalogContentDigest":"c".repeat(64),
		"catalogInputs":catalog_inputs, "supportPolicy":policy}
	_freeze_value(artifact)
	return artifact


func _compact_source_inputs(artifact: Dictionary, chunk: Vector2i) -> Dictionary:
	var dependency_digest := "d".repeat(64)
	var dependency := {"schema":"ecology-structure-dependency-snapshot/v1",
		"status":"ready", "content":{"layout":"fixture"},
		"contentDigest":dependency_digest, "ownerInstanceId":1, "ownerGeneration":1}
	return {"schema":"ecology-source-domain-inputs/v2", "worldId":WORLD_ID,
		"worldSeed":"fixture-seed", "sourceChunkKey":chunk, "worldEpoch":1,
		"catalogArtifactId":String(artifact.get("artifactId", "")),
		"catalogContentDigest":String(artifact.get("catalogContentDigest", "")),
		"producerCatalogRevision":"fixture-producer-catalog-v1",
		"influencePolicyRevision":String(artifact.supportPolicy.get("revision", "")),
		"influencePolicyDigest":String(artifact.supportPolicy.get("digest", "")),
		"terrainVolumeChunkRevision":"terrain-%d-%d" % [chunk.x, chunk.y],
		"structureAdmissionRevision":dependency_digest,
		"structureAdmissionStatus":"ready", "structureDependencyStatus":"ready",
		"structureDependencyContentDigest":dependency_digest,
		"structureDependencies":dependency}


func _snapshot(chunk: Vector2i, source_rows: Array,
		artifact: Dictionary) -> Dictionary:
	var return_rows: Array = source_rows if chunk == Vector2i.ZERO else []
	var source_inputs := _compact_source_inputs(artifact, chunk)
	var snapshot := ProducerDomain.seal_source_domain_snapshot({
		"worldId":WORLD_ID, "worldSeed":"fixture-seed", "sourceChunkKey":chunk,
		"sourceInputs":source_inputs, "sourceRows":return_rows,
		"producerComplete":true,
		"categoriesComplete":["trees", "surface_rocks", "ore", "forage", "details", "underground_props"],
		"removedSourceProjectionDigest":"b".repeat(64),
		"producerStatus":"ready"}, artifact)
	return snapshot


func _freeze_value(value: Variant) -> void:
	if value is Dictionary:
		for key: Variant in value: _freeze_value(value[key])
		value.make_read_only()
	elif value is Array:
		for child: Variant in value: _freeze_value(child)
		value.make_read_only()


func _source_row(source_id: String, member_id: String, bounds: AABB,
		owner_section: Vector3i, source_revision := "member-revision-A",
		recipe_signature := "recipe-A", artifact_generation := 1) -> Dictionary:
	var mesh_digest := "a".repeat(64)
	var wind_envelope: Dictionary = ProducerDomain.active_tree_visual_wind_envelope()
	var wind_digest := String(wind_envelope.get("digest", ""))
	var tuple := ["ecology-certified-member-envelope/v2", WORLD_ID,
		source_id, member_id, bounds, mesh_digest, POLICY,
		recipe_signature, artifact_generation, wind_digest]
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(var_to_bytes(tuple))
	var digest := hash.finish().hex_encode()
	var sections := Grid.keys_intersecting_bounds(bounds)
	return {"sourceId":source_id, "sourcePartId":member_id,
		"sourceRevision":source_revision, "kind":"tree", "family":"trees",
		"sourceOrigin":Vector3.ZERO, "state":"compiled",
		"supportProof":{"status":"ready", "worldBounds":bounds},
		"conservativeWorldBounds":bounds,
		"geometryOwnerSection":owner_section,
		"conservativeSupportSectionKeys":sections,
		"recipeSignature":recipe_signature, "artifactGeneration":artifact_generation,
		"meshContentDigest":mesh_digest,
		"certifiedEnvelopeDigest":digest,
		"certifiedEnvelopeProof":{"schema":"ecology-certified-member-envelope/v2",
			"status":"ready", "meshContentDigest":mesh_digest,
			"policyRevision":POLICY, "activeWindEnvelopeDigest":wind_digest,
			"digest":digest}}


func _member_receipt(lease: Dictionary) -> Dictionary:
	return {"sourceId":String(lease.get("sourceId", "")),
		"sourceRevision":String(lease.get("sourceRevision", "")),
		"memberId":String(lease.get("memberId", "")),
		"ownerSectionKey":lease.get("ownerSectionKey", Vector3i.ZERO),
		"supportLeaseToken":String(lease.get("supportLeaseToken", ""))}


func _check(ok: bool, name: String, diagnostics: Dictionary = {}) -> void:
	checks += 1
	if not first_failed_check.is_empty(): return
	if not ok:
		if first_failed_check.is_empty():
			first_failed_check = name
		_write_report({"schema":"ecology_world_support_index_contract/v1",
			"passed":false, "checkCount":checks,
			"failedCheck":first_failed_check, "diagnostics":diagnostics})
		quit(1)


func _write_report(value: Dictionary) -> void:
	var output := OS.get_environment("ECOLOGY_WORLD_SUPPORT_INDEX_REPORT")
	if output.is_empty(): return
	if not first_failed_check.is_empty() and bool(value.get("passed", false)):
		return
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file != null: file.store_string(JSON.stringify(value, "\t"))
