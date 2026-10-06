extends SceneTree

const Index := preload("res://scripts/world/EcologyWorldSupportIndex.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const ProducerDomain := preload("res://scripts/world/EcologyProducerDomain.gd")

const WORLD_ID := "support-index-contract-world"
const POLICY := "tree-factory-support-envelope/v2"

var checks := 0
var first_failed_check := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var index = Index.new()
	_check(index.configure(WORLD_ID).status == "ready", "configure")
	var section := Vector3i.ZERO
	var inputs := _support_policy_inputs()
	var policy: Dictionary = ProducerDomain.support_policy(inputs)
	if policy.get("status", "") != "ready":
		_write_report({"schema":"ecology_world_support_index_contract/v1",
			"passed":false, "checkCount":checks,
			"failedCheck":"synthetic support policy is bounded",
			"runtimePolicyReason":String(policy.get("runtimePolicyReason", "")),
			"runtimePolicyStatus":String(policy.get("runtimePolicyStatus", ""))})
		quit(1)
		return
	var census: Dictionary = ProducerDomain.source_domain_census_certificate(section, inputs)
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
		var snapshot := _snapshot(chunk, source_rows)
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
	var revision_b := _source_row("tree-1", "branches:00000000",
		AABB(Vector3.ZERO, Vector3(2.0, 3.0, 2.0)), Vector3i.ZERO,
		"member-revision-B", "recipe-B", 2)
	var revision_b_snapshot := _snapshot(Vector2i.ZERO, [revision_b])
	_check(index.publish_source_domain(WORLD_ID, Vector2i.ZERO,
		revision_b_snapshot, [revision_b]).status == "ready",
		"publish revision B before section receipt")
	var revision_c := _source_row("tree-1", "branches:00000000",
		AABB(Vector3.ZERO, Vector3(2.0, 3.0, 2.0)), Vector3i.ZERO,
		"member-revision-C", "recipe-C", 3)
	var revision_c_snapshot := _snapshot(Vector2i.ZERO, [revision_c])
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
	_check(revision_query.get("status", "") == "ready" \
		and current_revision_lease.get("sourceRevision", "") == "member-revision-C" \
		and retired_revision_leases.size() == 2 \
		and retired_revision_leases[0].get("sourceRevision", "") == "member-revision-A" \
		and retired_revision_leases[1].get("sourceRevision", "") == "member-revision-B" \
		and retired_revision_leases[0].get("supportLeaseToken", "") \
			!= retired_revision_leases[1].get("supportLeaseToken", ""),
		"both replaced source revisions remain required until receipt")
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
	var replacement_snapshot := _snapshot(Vector2i.ZERO, [])
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
	_write_report({"schema":"ecology_world_support_index_contract/v1",
		"passed":true, "checkCount":checks,
		"evidenceLevel":"synthetic_bounded_source_index_and_receipt_contract",
		"supportPolicyFixture":"synthetic profile and rock descriptor envelope; tree support envelope is derived from current source",
		"status":"ready", "lease":lease})
	quit(0)


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


func _snapshot(chunk: Vector2i, source_rows: Array) -> Dictionary:
	var return_rows: Array = source_rows if chunk == Vector2i.ZERO else []
	var source_inputs := _support_policy_inputs()
	source_inputs["terrainVolumeChunkRevision"] = "terrain-%d-%d" % [chunk.x, chunk.y]
	source_inputs["structureAdmissionRevision"] = "structures-%d-%d" % [chunk.x, chunk.y]
	source_inputs["structureAdmissionStatus"] = "ready"
	var snapshot := ProducerDomain.seal_source_domain_snapshot({
		"worldId":WORLD_ID, "worldSeed":"fixture-seed", "sourceChunkKey":chunk,
		"sourceInputs":source_inputs, "sourceRows":return_rows,
		"producerComplete":true,
		"categoriesComplete":["trees", "surface_rocks", "ore", "forage", "details", "underground_props"],
		"removedSourceProjectionDigest":"b".repeat(64),
		"producerStatus":"ready"})
	return snapshot


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


func _check(ok: bool, name: String) -> void:
	checks += 1
	if not ok:
		if first_failed_check.is_empty():
			first_failed_check = name
		_write_report({"schema":"ecology_world_support_index_contract/v1",
			"passed":false, "checkCount":checks,
			"failedCheck":first_failed_check})
		quit(1)


func _write_report(value: Dictionary) -> void:
	var output := OS.get_environment("ECOLOGY_WORLD_SUPPORT_INDEX_REPORT")
	if output.is_empty(): return
	if not first_failed_check.is_empty() and bool(value.get("passed", false)):
		return
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file != null: file.store_string(JSON.stringify(value, "\t"))
