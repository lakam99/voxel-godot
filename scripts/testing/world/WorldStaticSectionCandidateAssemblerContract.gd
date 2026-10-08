extends SceneTree

const Assembler := preload("res://scripts/world/WorldStaticSectionCandidateAssembler.gd")
const Coordinator := preload("res://scripts/world/WorldStaticSectionCoordinator.gd")
const MeshFingerprint := preload("res://scripts/world/StaticRenderMeshFingerprint.gd")
const SnapshotBuilder := preload("res://scripts/world/PreparedStaticSectionSnapshotBuilder.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const Grid := preload("res://scripts/world/StaticRenderSectionGrid.gd")
const REPORT_ENV := "VOXEL_WHOLE_SECTION_ASSEMBLER_REPORT"
const WORLD := "seed:whole-section-assembler-contract"
const SECTION := Vector3i.ZERO

var checks: Dictionary = {}
var mesh: ArrayMesh
var material: StandardMaterial3D
var batch_key := ""
var compatibility: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_build_shared_batch()
	var census := _census(["terrain:0,0,0", "ordinary:town-a:cell-0"],
		{"terrain:0,0,0":"terrain-r1", "ordinary:town-a:cell-0":"ordinary-r1"})
	var contributions := _contributions(census)
	var assembled: Dictionary = Assembler.assemble(census, SECTION, contributions, 1)
	var candidate: Dictionary = assembled.get("candidate", {})
	var snapshot: Dictionary = candidate.get("candidate", {}).get("snapshot", {})
	_check("cross_domain_inputs_share_one_partition_and_batch",
		assembled.get("status") == "ready" and assembled.get("providerCount") == 2
		and assembled.get("sourceCount") == 2 and assembled.get("inputCount") == 2
		and assembled.get("batchCount") == 1 and snapshot.get("contributorCount") == 2
		and snapshot.get("batchCount") == 1,
		{"assembly":assembled, "snapshotBatchCount":snapshot.get("batchCount", -1)})
	_check("candidate_is_complete_immutable_renderer_envelope",
		candidate.is_read_only()
		and candidate.get("schema") == Assembler.SCHEMA
		and candidate.get("candidate", {}).get("schema") == SnapshotBuilder.SCHEMA
		and candidate.get("contentManifestDigest", "").length() == 64
		and snapshot.get("renderLayers", []).size() == 3,
		{"schema":candidate.get("schema", ""), "digest":candidate.get("contentManifestDigest", ""),
			"layerCount":snapshot.get("renderLayers", []).size()})
	var departure_census := census.duplicate(false)
	var departing_identity := _identity_key("terrain:0,0,0", "terrain:0,0,0")
	var departed_section := Vector3i(1, 0, 0)
	var neighbor_source := "ordinary:neighbor-only"
	var neighbor_identity := _identity_key(neighbor_source, neighbor_source)
	var departure_sections: Array[Vector3i] = [SECTION, departed_section]
	departure_sections.make_read_only()
	departure_census["sections"] = departure_sections
	var departure_sources: Dictionary = census.sourceRevisions.duplicate(false)
	departure_sources[neighbor_identity] = "neighbor-r1"
	departure_sources.make_read_only()
	departure_census["sourceRevisions"] = departure_sources
	var departure_providers: Dictionary = census.sourceProviderIds.duplicate(false)
	departure_providers[neighbor_identity] = "ordinary"
	departure_providers.make_read_only()
	departure_census["sourceProviderIds"] = departure_providers
	var departure_identities: Dictionary = census.sourceIdentities.duplicate(false)
	var neighbor_identity_row := {"sourceId":neighbor_source, "sourcePartId":neighbor_source}
	neighbor_identity_row.make_read_only()
	departure_identities[neighbor_identity] = neighbor_identity_row
	departure_identities.make_read_only()
	departure_census["sourceIdentities"] = departure_identities
	var departure_expected: Dictionary = census.expectedContributorsBySection.duplicate(false)
	var neighbor_members: Array[String] = [neighbor_identity]
	neighbor_members.make_read_only()
	departure_expected[departed_section] = neighbor_members
	departure_expected.make_read_only()
	departure_census["expectedContributorsBySection"] = departure_expected
	var departure_coverage: Dictionary = {}
	for provider: String in census.providerCoverageRevisions:
		var provider_sections: Dictionary = census.providerCoverageRevisions[provider].duplicate(false)
		provider_sections[departed_section] = "neighbor-coverage:" + provider
		provider_sections.make_read_only()
		departure_coverage[provider] = provider_sections
	departure_coverage.make_read_only()
	departure_census["providerCoverageRevisions"] = departure_coverage
	var removal_map := {departing_identity:"terrain-r1"}
	removal_map.make_read_only()
	var departure := {"sourceId":"terrain:0,0,0", "sourcePartId":"terrain:0,0,0",
		"sourceRevision":"terrain-r1", "sectionKey":departed_section}
	departure.make_read_only()
	var departure_rows: Array = [departure]
	departure_rows.make_read_only()
	var removal_by_section := {departed_section:departure_rows}
	removal_by_section.make_read_only()
	departure_census["removalRevisions"] = removal_map
	departure_census["removalsBySection"] = removal_by_section
	departure_census.make_read_only()
	var departure_assembly := Assembler.assemble(departure_census, SECTION, contributions, 11)
	_check("candidate_receipt_does_not_claim_neighbor_section_removal",
		departure_assembly.get("status") == "ready"
		and departure_assembly.get("candidate", {}).get("removalRevisions", {}).is_empty()
		and departure_assembly.get("candidate", {}).get("removalSourceIdentities", {}).is_empty()
		and departure_assembly.get("candidate", {}).get("sourceRevisions", {}) == census.sourceRevisions,
		departure_assembly)
	_check_removal_identity_contract()
	var terrain_empty_contributions := _with_explicit_empty_terrain(census, contributions)
	var terrain_empty_result := Assembler.assemble(census, SECTION,
		terrain_empty_contributions, 2)
	var terrain_empty_candidate: Dictionary = terrain_empty_result.get("candidate", {})
	var terrain_empty_snapshot: Dictionary = terrain_empty_candidate.get("candidate", {}).get("snapshot", {})
	var terrain_empty_manifest: Array = terrain_empty_snapshot.get("manifest", [])
	var terrain_empty_manifest_row: Dictionary = {}
	for row_value: Variant in terrain_empty_manifest:
		if row_value is Dictionary and String(row_value.get("sourcePartId", "")) == "terrain:0,0,0":
			terrain_empty_manifest_row = row_value
	_check("exact_empty_provider_member_is_manifested_in_shared_section_candidate",
		terrain_empty_result.get("status") == "ready"
		and int(terrain_empty_candidate.get("inputCount", -1)) == 1
		and terrain_empty_snapshot.get("contributorCount") == 2
		and terrain_empty_manifest_row.get("batchKeys", []).is_empty()
		and terrain_empty_manifest_row.get("ranges", []).is_empty()
		and terrain_empty_manifest_row.get("sourceRevision") == "terrain-r1",
		{"assemblyStatus":String(terrain_empty_result.get("status", "")),
			"manifest":terrain_empty_manifest})
	var omitted_empty: Array = terrain_empty_contributions.duplicate()
	var terrain_without_empty: Dictionary = terrain_empty_contributions[0].duplicate(false)
	terrain_without_empty.erase("explicitEmptyContributors")
	terrain_without_empty.make_read_only()
	omitted_empty[0] = terrain_without_empty
	omitted_empty.make_read_only()
	var missing_empty_result: Dictionary = Assembler.assemble(census, SECTION,
		omitted_empty, 3)
	_check("missing_geometry_without_explicit_empty_stays_retryable",
		missing_empty_result.get("status") == "pending"
		and missing_empty_result.get("reason") == "section_source_geometry_or_explicit_empty_missing",
		missing_empty_result)
	var missing_provider: Dictionary = Assembler.assemble(census, SECTION,
		_read_only([contributions[0]]), 4)
	_check("missing_provider_is_retryable_without_partial_candidate",
		missing_provider.get("status") == "pending"
		and bool(missing_provider.get("retryable", false)), missing_provider)
	var stale_source := _contributions(census)
	var stale_row: Dictionary = stale_source[0].duplicate(false)
	stale_row["authorityRevision"] = "stale-provider-revision"
	stale_row.make_read_only()
	var stale: Array = [stale_row, stale_source[1]]
	stale.make_read_only()
	var stale_result: Dictionary = Assembler.assemble(census, SECTION, stale, 3)
	_check("stale_provider_authority_is_retryable", stale_result.get("status") == "pending"
		and stale_result.get("reason") == "section_provider_authority_revision_mismatch", stale_result)
	var stale_input_source := _contributions(census)
	var stale_input_provider: Dictionary = stale_input_source[0].duplicate(false)
	var stale_input_rows: Array = stale_input_provider.inputs.duplicate()
	var stale_input: Dictionary = stale_input_rows[0].duplicate(false)
	stale_input["sourceRevision"] = "stale-member-revision"
	stale_input.make_read_only()
	stale_input_rows[0] = stale_input
	stale_input_rows.make_read_only()
	stale_input_provider["inputs"] = stale_input_rows
	stale_input_provider.make_read_only()
	var stale_input_contributions: Array = [stale_input_provider, stale_input_source[1]]
	stale_input_contributions.make_read_only()
	var stale_input_result: Dictionary = Assembler.assemble(census, SECTION,
		stale_input_contributions, 4)
	_check("stale_member_geometry_is_rejected_against_census_revision",
		stale_input_result.get("status") == "pending"
		and stale_input_result.get("reason") == "section_instance_input_source_revision_stale",
		stale_input_result)
	var empty_census := _census([], {})
	var empty_contributions := _contributions(empty_census)
	var empty_result: Dictionary = Assembler.assemble(empty_census, SECTION, empty_contributions, 4)
	var empty_candidate: Dictionary = empty_result.get("candidate", {})
	var empty_snapshot: Dictionary = empty_candidate.get("candidate", {}).get("snapshot", {})
	_check("all_providers_must_attest_explicit_empty_section",
		empty_result.get("status") == "ready" and empty_candidate.is_read_only()
		and empty_snapshot.get("contributorCount") == 0
		and empty_snapshot.get("renderLayers", []).size() == 3,
		{"assembly":empty_result, "snapshot":empty_snapshot})
	var conflict_source := _contributions(census)
	var conflict_row: Dictionary = conflict_source[1].duplicate(false)
	var bad_compat := compatibility.duplicate(false)
	bad_compat["visibilityRangeEnd"] = 999.0
	bad_compat.make_read_only()
	var bad_compat_map := {batch_key:bad_compat}
	bad_compat_map.make_read_only()
	conflict_row["compatibilityByKey"] = bad_compat_map
	conflict_row.make_read_only()
	var conflict: Array = [conflict_source[0], conflict_row]
	conflict.make_read_only()
	var conflict_result: Dictionary = Assembler.assemble(census, SECTION, conflict, 5)
	_check("cross_domain_batch_compatibility_conflict_fails_closed",
		conflict_result.get("status") == "failed"
		and conflict_result.get("reason", "").begins_with("cross_domain_batch_compatibility_conflict"),
		conflict_result)
	_test_presentation_provider_boundary(census, contributions)
	_finish()


func _test_presentation_provider_boundary(census: Dictionary, base: Array) -> void:
	var motion := {"kind":"static", "closedParentToBody":Transform3D.IDENTITY,
		"raiseOffset":Vector3.ZERO, "swing":0.0}
	motion.make_read_only()
	var source := "ordinary:town-a:cell-0"
	var member := {"schema":"static-section-presentation-member/v2",
		"sourceId":source, "sourcePartId":source, "sourceRevision":"ordinary-r1",
		"producerSourceRevision":"ordinary-producer-r1",
		"presentationMemberId":"fixture-light", "attachmentKey":"fixture-light-anchor",
		"ownershipKind":"borrowed_presentation", "intendedVisible":true,
		"neutralParentToWorld":Transform3D(Basis.IDENTITY, Vector3(4, 2, 2)),
		"sweptWorldBounds":AABB(Vector3(3, 1, 1), Vector3(2, 2, 2)), "motion":motion}
	member.make_read_only()
	var presentation := {"sourceId":source, "sourcePartId":source,
		"sourceRevision":"ordinary-r1", "sectionKey":SECTION, "ownerCell":Vector2i.ZERO,
		"presentationMembers":_read_only([member])}
	presentation.make_read_only()
	# Synthetic provider bindings prove value admission only; native installation
	# uses the separate real-owner/frame-ack contract.
	var bindings := {"fixture-light-anchor":member}
	bindings.make_read_only()
	var provider: Dictionary = base[1].duplicate(false)
	provider["presentationContributors"] = _read_only([presentation])
	provider["attachmentBindings"] = bindings
	provider.make_read_only()
	var mixed := Assembler.assemble(census, SECTION, _read_only([base[0], provider]), 20)
	var mixed_snapshot: Dictionary = mixed.get("candidate", {}).get("candidate", {}).get("snapshot", {})
	_check("provider_geometry_and_presentation_enter_one_candidate",
		mixed.get("status") == "ready" and mixed_snapshot.get("instanceCount", -1) == 2
		and mixed_snapshot.get("presentationMembers", []).size() == 1, {"status":mixed.get("status"), "reason":mixed.get("reason")})
	var presentation_only := provider.duplicate(false)
	presentation_only["inputs"] = _read_only([])
	presentation_only.make_read_only()
	var only := Assembler.assemble(census, SECTION, _read_only([base[0], presentation_only]), 21)
	var only_snapshot: Dictionary = only.get("candidate", {}).get("candidate", {}).get("snapshot", {})
	_check("provider_presentation_only_member_is_not_empty_or_omitted",
		only.get("status") == "ready" and only_snapshot.get("instanceCount", -1) == 1
		and only_snapshot.get("contributorCount", -1) == 2
		and only_snapshot.get("presentationMembers", []).size() == 1, {"status":only.get("status"), "reason":only.get("reason")})
	var missing := provider.duplicate(false)
	missing["attachmentBindings"] = {}
	missing.make_read_only()
	var rejected := Assembler.assemble(census, SECTION, _read_only([base[0], missing]), 22)
	_check("provider_presentation_missing_binding_fails_closed",
		rejected.get("status") == "failed"
		and String(rejected.get("reason", "")).begins_with("section_provider_presentation_binding_missing"), rejected)


func _check_removal_identity_contract() -> void:
	# Synthetic value admission only: no installation or gameplay is claimed.
	var source_id := "ordinary:removed-building"
	var part_id := "removed-member"
	var identity := _identity_key(source_id, part_id)
	var revision := "durable-removal-r1"
	var row := {"sourceId":source_id, "sourcePartId":part_id,
		"sourceRevision":revision, "sectionKey":SECTION}
	row.make_read_only()
	var census := _removal_census([row], {identity:revision})
	var result: Dictionary = Assembler.assemble(census, SECTION, _contributions(census), 20)
	var candidate: Dictionary = result.get("candidate", {})
	var identities: Dictionary = candidate.get("removalSourceIdentities", {})
	var raw_identity: Dictionary = identities.get(identity, {})
	var coordinator := Coordinator.new()
	_check("explicit_removal_candidate_preserves_sealed_raw_identity_and_revision",
		result.get("status") == "ready" and identities.is_read_only()
		and raw_identity.is_read_only() and identities.size() == 1
		and raw_identity == {"sourceId":source_id, "sourcePartId":part_id, "sourceRevision":revision}
		and candidate.get("sourceRevisions", {}).is_empty()
		and coordinator._candidate_removal_identities_match_census(candidate, census, SECTION), result)
	for mutation: String in ["missing_source", "wrong_part", "wrong_revision", "wrong_section", "duplicate"]:
		var changed: Dictionary = row.duplicate(false)
		match mutation:
			"missing_source": changed.erase("sourceId")
			"wrong_part": changed["sourcePartId"] = "unrelated-member"
			"wrong_revision": changed["sourceRevision"] = "stale-removal"
			"wrong_section": changed["sectionKey"] = Vector3i(1, 0, 0)
		changed.make_read_only()
		var rows: Array = [changed, changed] if mutation == "duplicate" else [changed]
		var malformed := _removal_census(rows, {identity:revision})
		var rejected: Dictionary = Assembler.assemble(malformed, SECTION, _contributions(malformed), 21)
		_check("removal_census_rejects_" + mutation,
			rejected.get("status") == "failed"
			and String(rejected.get("reason", "")).begins_with("section_removal_"), rejected)
	for mutation: String in ["missing", "wrong_part", "mutable_map", "mutable_row", "wrong_revision", "neighbor_identity"]:
		var changed_candidate: Dictionary = candidate.duplicate(false)
		var supplied: Dictionary = identities.duplicate(false)
		var supplied_row: Dictionary = raw_identity.duplicate(false)
		match mutation:
			"missing": supplied.clear()
			"wrong_part": supplied_row["sourcePartId"] = "unrelated-member"
			"wrong_revision": supplied_row["sourceRevision"] = "stale-removal"
			"neighbor_identity": supplied[_identity_key("neighbor", "member")] = raw_identity
		if mutation != "missing":
			if mutation != "mutable_row": supplied_row.make_read_only()
			supplied[identity] = supplied_row
		if mutation != "mutable_map": supplied.make_read_only()
		changed_candidate["removalSourceIdentities"] = supplied
		changed_candidate.make_read_only()
		_check("coordinator_removal_identity_rejects_" + mutation,
			not coordinator._candidate_removal_identities_match_census(changed_candidate, census, SECTION),
			{"mutation":mutation})
	var mutable_revision_candidate: Dictionary = candidate.duplicate(false)
	mutable_revision_candidate["removalRevisions"] = candidate.get("removalRevisions", {}).duplicate(false)
	mutable_revision_candidate.make_read_only()
	_check("coordinator_removal_identity_rejects_mutable_revision_map",
		not coordinator._candidate_removal_identities_match_census(mutable_revision_candidate, census, SECTION),
		{"evidenceLevel":"synthetic_nested_candidate_immutability"})


func _removal_census(rows: Array, revisions: Dictionary) -> Dictionary:
	var result: Dictionary = _census([], {}).duplicate(false)
	var sealed_rows: Array = rows.duplicate(false)
	sealed_rows.make_read_only()
	var removals := {SECTION:sealed_rows}
	removals.make_read_only()
	var sealed_revisions: Dictionary = revisions.duplicate(false)
	sealed_revisions.make_read_only()
	result["removalsBySection"] = removals
	result["removalRevisions"] = sealed_revisions
	result.make_read_only()
	return result


func _build_shared_batch() -> void:
	mesh = ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(-0.5, 0.0, -0.5), Vector3(0.5, 0.0, -0.5), Vector3(0.0, 0.0, 0.5)])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	material = StandardMaterial3D.new()
	material.albedo_color = Color(0.3, 0.6, 0.4)
	var fingerprint: Dictionary = MeshFingerprint.inspect(mesh)
	var mesh_digest := String(fingerprint.get("contentDigest", ""))
	var mesh_resource_key := "contract-shared-triangle"
	var pipeline := "whole-section-contract-v1"
	var mesh_key := "%s|pipeline=%s|layer=opaque|sort=none" % [mesh_resource_key, pipeline]
	var bounds := mesh.get_aabb()
	var raw := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"materialKey":"contract:foliage", "renderTier":"detail",
		"meshResourceKey":mesh_resource_key, "meshKey":mesh_key,
		"meshContentDigest":mesh_digest, "meshLocalBounds":bounds,
		"pipelineRevision":pipeline, "renderLayer":"opaque",
		"translucentSortPolicy":"none", "castShadows":true,
		"visibilityRangeEnd":240.0, "fadeMargin":12.0}
	batch_key = SnapshotBuilder.batch_compatibility_key(raw)
	raw["batchKey"] = batch_key
	raw["compatibilityKey"] = batch_key
	raw.make_read_only()
	compatibility = raw


func _census(parts: Array[String], revisions: Dictionary) -> Dictionary:
	var provider_ids: Dictionary = {}
	var identities: Dictionary = {}
	var source_revisions: Dictionary = {}
	for part_id: String in parts:
		var provider_id := "terrain" if part_id.begins_with("terrain:") else "ordinary"
		var identity_key := _identity_key(part_id, part_id)
		provider_ids[identity_key] = provider_id
		var identity := {"sourceId":part_id, "sourcePartId":part_id}
		identity.make_read_only()
		identities[identity_key] = identity
		source_revisions[identity_key] = String(revisions.get(part_id, ""))
	provider_ids.make_read_only()
	identities.make_read_only()
	var section_parts: Array[String] = []
	for identity_key: Variant in provider_ids:
		section_parts.append(String(identity_key))
	section_parts.sort()
	section_parts.make_read_only()
	var expected := {SECTION:section_parts}
	expected.make_read_only()
	source_revisions.make_read_only()
	var providers := {"terrain":"terrain-authority-r1", "ordinary":"ordinary-authority-r1"}
	providers.make_read_only()
	var coverage := {
		"terrain":{SECTION:"terrain-coverage-r1"},
		"ordinary":{SECTION:"ordinary-coverage-r1"}}
	for provider_id in coverage:
		coverage[provider_id].make_read_only()
	coverage.make_read_only()
	var result := {"status":"complete", "worldId":WORLD,
		"sections":[SECTION], "sourceRevisions":source_revisions,
		"sourceProviderIds":provider_ids, "expectedContributorsBySection":expected,
		"sourceIdentities":identities,
		"providerSnapshotRevisions":providers, "providerCoverageRevisions":coverage,
		"removalRevisions":{}, "censusDigest":"contract-census-r1"}
	result.sections.make_read_only()
	result.removalRevisions.make_read_only()
	result.make_read_only()
	return result


func _contributions(census: Dictionary) -> Array:
	var result: Array = []
	for provider_id: String in ["terrain", "ordinary"]:
		var parts := _parts_for_provider(census, provider_id)
		var inputs: Array = []
		var authority_revisions := {}
		for part_id: String in parts:
			var revision := String(census.sourceRevisions.get(part_id, ""))
			authority_revisions[part_id] = revision
			inputs.append(_input(provider_id, part_id, revision))
		inputs.make_read_only()
		authority_revisions.make_read_only()
		var compat := {}
		var mats := {}
		var meshes := {}
		var resources := {}
		if not inputs.is_empty():
			compat[batch_key] = compatibility
			mats["contract:foliage"] = material
			meshes["contract-shared-triangle"] = mesh
			resources[batch_key] = {"material":material, "mesh":mesh}
		compat.make_read_only()
		mats.make_read_only()
		meshes.make_read_only()
		resources.make_read_only()
		var row := {"providerId":provider_id, "sectionKey":SECTION,
			"coverageRevision":String(census.providerCoverageRevisions[provider_id][SECTION]),
			"authorityRevision":String(census.providerSnapshotRevisions[provider_id]),
			"authoritySourceRevisions":authority_revisions, "inputs":inputs,
			"compatibilityByKey":compat, "materialBindings":mats,
			"meshBindings":meshes, "resourceBindings":resources}
		row.make_read_only()
		result.append(row)
	result.make_read_only()
	return result


func _with_explicit_empty_terrain(census: Dictionary, base: Array) -> Array:
	var result: Array = base.duplicate()
	var terrain: Dictionary = base[0].duplicate(false)
	var source_part_id := "terrain:0,0,0"
	var identity_key := _identity_key(source_part_id, source_part_id)
	var empty_row := {"sourceId":source_part_id,
		"sourcePartId":source_part_id,
		"sourceRevision":String(census.sourceRevisions.get(identity_key, "")),
		"ownerCell":Grid.logical_owner_cell_for_world_position(Vector3.ZERO),
		"sectionKey":SECTION}
	empty_row.make_read_only()
	var explicit_empty: Array[Dictionary] = [empty_row]
	explicit_empty.make_read_only()
	var no_inputs: Array[Dictionary] = []
	no_inputs.make_read_only()
	var no_bindings: Dictionary = {}
	no_bindings.make_read_only()
	terrain["inputs"] = no_inputs
	terrain["compatibilityByKey"] = no_bindings
	terrain["materialBindings"] = no_bindings
	terrain["meshBindings"] = no_bindings
	terrain["resourceBindings"] = no_bindings
	terrain["explicitEmptyContributors"] = explicit_empty
	terrain.make_read_only()
	result[0] = terrain
	result.make_read_only()
	return result


func _parts_for_provider(census: Dictionary, provider_id: String) -> Array[String]:
	var result: Array[String] = []
	for part_value: Variant in census.expectedContributorsBySection[SECTION]:
		var part_id := String(part_value)
		if String(census.sourceProviderIds[part_id]) == provider_id:
			result.append(part_id)
	return result


func _input(provider_id: String, part_id: String, revision: String) -> Dictionary:
	var identity: Dictionary = census_identity_for(part_id)
	var source_id := String(identity.get("sourceId", ""))
	var source_part_id := String(identity.get("sourcePartId", ""))
	var buffer: Array[float] = []
	for value: float in Attributes.encode(Transform3D.IDENTITY, Color.WHITE):
		buffer.append(value)
	buffer.make_read_only()
	var input := {"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"sourceId":source_id, "sourcePartId":source_part_id,
		"sourceRevision":revision,
		"ownerCell":Grid.logical_owner_cell_for_world_position(Vector3(1, 0, 1)),
		"sourceToWorld":Transform3D(Basis.IDENTITY,
			Vector3(2.0 if provider_id == "terrain" else 4.0, 0.0, 2.0)),
		"meshLocalBounds":mesh.get_aabb(), "batchKey":batch_key,
		"segmentId":part_id + ":triangle", "buffer":buffer, "instanceCount":1}
	input.make_read_only()
	return input


func census_identity_for(identity_key: String) -> Dictionary:
	# Contract inputs use identical source and part IDs; decode the known fixture
	# mapping from the canonical composite-key format.
	for part_id: String in ["terrain:0,0,0", "ordinary:town-a:cell-0"]:
		if _identity_key(part_id, part_id) == identity_key:
			return {"sourceId":part_id, "sourcePartId":part_id}
	return {}


func _identity_key(source_id: String, source_part_id: String) -> String:
	return "section-part:" + var_to_bytes([source_id, source_part_id]).hex_encode()


func _read_only(values: Array) -> Array:
	values.make_read_only()
	return values


func _check(name: String, passed: bool, evidence: Variant) -> void:
	checks[name] = {"passed":passed, "evidence":evidence}


func _finish() -> void:
	var failures: Array[String] = []
	for name: String in checks:
		if not bool(checks[name].get("passed", false)):
			failures.append(name)
	var report := {"schema":"world-static-section-candidate-assembler-contract/v1",
		"complete":true, "passed":failures.is_empty(), "checks":checks,
		"checkCount":checks.size(), "failedChecks":failures,
		"evidenceLevel":"synthetic_whole_section_candidate_contract",
		"doesNotProve":"native section installation, real provider parity, old representation retention, collision/interactions, saves, gameplay, or performance."}
	var path := OS.get_environment(REPORT_ENV)
	if not path.is_empty():
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	quit(0 if failures.is_empty() else 1)
