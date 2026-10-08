extends SceneTree
## Coordinator closure helpers: local slices, true intersecting support, and retained claims.

const Completion := preload("res://scripts/world/StaticGeometryOwnerCompletion.gd")
const Slices := preload("res://scripts/world/StaticGeometryOwnerSectionSlice.gd")
const Coordinator := preload("res://scripts/world/WorldStaticSectionCoordinator.gd")
const Attributes := preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")

var checks: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var local := Vector3i(198, 1, -342)
	var distant := Vector3i(199, 1, -342)
	var member_a := _member("foundation-local", local)
	var member_b := _member("foundation-distant", distant)
	var sealed := Completion.seal("world", "building:citadel", "foundation",
		"r17", "publisher-3", [member_a, member_b])
	var roster: Dictionary = sealed.roster
	var partition: Dictionary = Slices.partition(roster, [local, distant]).partition
	var local_slice: Dictionary = partition.slices[0]
	if partition.sections[0] != local:
		local_slice = partition.slices[1]
	var no_prior_slices: Array = []
	no_prior_slices.make_read_only()
	checks["two_owner_source_slice_is_valid_for_exact_root"] = Coordinator._section_owner_slice_is_current(
		{"status":"ready"}, roster, local_slice, no_prior_slices, "building:citadel", "foundation", local)
	checks["local_source_slice_cannot_expand_demand_to_distant_owner"] = \
		Coordinator._section_slice_remote_owner_sections(local_slice, local).is_empty()
	var support := {"ownershipPolicy":"citadel_center_geometry_owner/aabb_support_sections_v1",
		"supportSectionKey":local, "geometryOwnerSection":distant, "memberId":"wall:segment:1",
		"sourceRevision":"r17", "sourceSegmentId":"wall-range-1"}
	var exact_claim := Coordinator._exact_support_range_owner_claim(support, local, "building:citadel")
	checks["true_intersecting_support_range_demands_its_declared_owner"] = not exact_claim.is_empty() \
		and exact_claim.ownerSection == distant and exact_claim.claim.supportRange == support
	var wrong_root := Coordinator._exact_support_range_owner_claim(support, Vector3i(197, 1, -342),
		"building:citadel")
	checks["support_from_another_root_does_not_create_a_lease"] = wrong_root.is_empty()
	var old_lease := "ordinary-render-support:198,1,-342:building:citadel:wall:segment:1:r17"
	var old_claim := {"supportSectionKey":local, "sourceId":"building:citadel",
		"sourceRevision":"r17", "memberId":"wall:segment:1", "supportRange":support}
	var retained: Dictionary = {}
	Coordinator._merge_retained_support_claims(retained, local, {old_lease:old_claim},
		{old_lease:distant})
	checks["prior_exact_support_claim_is_retained_while_replacement_is_pending"] = retained.has(distant) \
		and retained[distant].has(old_lease) and retained[distant][old_lease] == old_claim
	var distant_slice: Dictionary = partition.slices[1] if partition.sections[0] == local else partition.slices[0]
	var invalid_prior: Array = [distant_slice]
	invalid_prior.make_read_only()
	checks["prior_slice_from_unrelated_section_rejected"] = not Coordinator._section_owner_slice_is_current(
		{"status":"ready"}, roster, local_slice, invalid_prior,
		"building:citadel", "foundation", local)
	var coordinator := Coordinator.new()
	checks["coordinator_world_configured"] = coordinator.configure("world") == {
		"status":"ready", "worldId":"world"}
	var key_local := Completion.member_key(member_a)
	var key_distant := Completion.member_key(member_b)
	var candidate_local := _candidate("candidate-local-r1", "r17")
	var candidate_distant := _candidate("candidate-distant-r1", "r17")
	var receipt_local := {"generation":1, "incarnation":"local-1"}
	var receipt_distant := {"generation":1, "incarnation":"distant-1"}
	var token_local := {"candidate":candidate_local, "receipt":receipt_local}
	var token_distant := {"candidate":candidate_distant, "receipt":receipt_distant}
	var section_tokens := {local:token_local, distant:token_distant}
	var section_receipts := {local:receipt_local, distant:receipt_distant}
	section_receipts.make_read_only()
	var installed_members := {key_local:member_a, key_distant:member_b}
	var installed_keys_by_section := {local:[key_local], distant:[key_distant]}
	var session := {"roster":roster, "stage":"complete",
		"requiredSections":{local:true, distant:true},
		"requiredSectionKeys":[local, distant],
		"sectionTokens":section_tokens, "sectionReceipts":section_receipts,
		"sectionScanned":{local:true, distant:true},
		"sectionCompared":{local:true, distant:true},
		"finalReceiptValidated":{local:true, distant:true},
		"installedMembers":installed_members,
		"installedMemberKeysBySection":installed_keys_by_section,
		"sectionCursor":2, "compareSectionCursor":2, "finalReceiptCursor":2,
		"memberCursor":2, "closureResetCount":3}
	var proof_key := "closure-contract-proof"
	coordinator._geometry_owner_completion_sessions[proof_key] = session
	coordinator._geometry_owner_completion_session_key_by_source["building:citadel"] = proof_key
	coordinator._production_candidates_by_section[local] = candidate_local
	coordinator._production_candidates_by_section[distant] = candidate_distant
	coordinator._production_candidate_receipts[local] = receipt_local
	coordinator._production_candidate_receipts[distant] = receipt_distant
	var replacement_local := _candidate("candidate-local-r2", "r17")
	var replacement_receipt_local := {"generation":2, "incarnation":"local-2"}
	coordinator._production_candidates_by_section[local] = replacement_local
	coordinator._production_candidate_receipts[local] = replacement_receipt_local
	coordinator._advance_geometry_owner_dependency_revision_for_candidate(candidate_local)
	coordinator._advance_geometry_owner_dependency_revision_for_candidate(replacement_local)
	coordinator._notify_geometry_owner_candidate_changed(local,
		candidate_local, replacement_local)
	checks["one_section_replacement_preserves_other_section_token"] = \
		is_same(session.sectionTokens.get(distant), token_distant) \
			and is_same(session.sectionReceipts.get(distant), receipt_distant)
	checks["one_section_replacement_invalidates_only_its_member_partition"] = \
		not session.sectionTokens.has(local) and not session.sectionReceipts.has(local) \
			and not session.installedMembers.has(key_local) \
			and session.installedMembers.get(key_distant) == member_b
	checks["one_section_replacement_keeps_unaffected_cursor_proofs"] = \
		bool(session.sectionScanned.get(distant, false)) \
			and bool(session.sectionCompared.get(distant, false)) \
			and bool(session.finalReceiptValidated.get(distant, false)) \
			and not session.sectionScanned.get(local, false) \
			and not session.sectionCompared.get(local, false) \
			and not session.finalReceiptValidated.get(local, false) \
			and int(session.get("memberCursor", -1)) == 2 \
			and int(session.get("closureResetCount", -1)) == 3 \
			and session.stage == "section_manifests"
	checks["stale_local_observation_is_not_a_ready_proof"] = \
		coordinator._geometry_owner_first_stale_section(session) == local
	var partial_scan_session := {"requiredSections":{local:true, distant:true},
		"requiredSectionKeys":[local, distant], "sectionTokens":{distant:token_distant},
		"sectionReceipts":{distant:receipt_distant}, "sectionScanned":{},
		"sectionCompared":{}, "finalReceiptValidated":{},
		"installedMembers":{key_distant:member_b},
		"installedMemberKeysBySection":{distant:[key_distant]},
		"stage":"section_manifests", "sectionCursor":1,
		"manifestCursor":3, "memberRangeCursor":2,
		"compareSectionCursor":0, "compareMemberCursor":0,
		"finalReceiptCursor":0}
	coordinator._invalidate_geometry_owner_section_observation(partial_scan_session, distant)
	checks["replacing_current_partial_scan_restarts_only_its_manifest_slice"] = \
		int(partial_scan_session.get("sectionCursor", -1)) == 1 \
			and int(partial_scan_session.get("manifestCursor", -1)) == 0 \
			and int(partial_scan_session.get("memberRangeCursor", -1)) == 0 \
			and not partial_scan_session.get("sectionTokens", {}).has(distant)
	var added_section := Vector3i(200, 1, -342)
	var candidate_added := _candidate("candidate-added-section", "r17")
	var receipt_added := {"generation":1, "incarnation":"added-1"}
	coordinator._production_candidates_by_section[added_section] = candidate_added
	coordinator._production_candidate_receipts[added_section] = receipt_added
	coordinator._replace_section_source_index(added_section, {}, candidate_added)
	coordinator._advance_geometry_owner_dependency_revision_for_candidate(candidate_added)
	coordinator._notify_geometry_owner_candidate_changed(added_section, {}, candidate_added)
	checks["new_source_membership_adds_local_section_to_active_closure"] = \
		session.requiredSections.has(added_section) \
			and not session.sectionTokens.has(added_section) \
			and is_same(session.sectionTokens.get(distant), token_distant)
	coordinator._replace_section_source_index(added_section, candidate_added, {})
	coordinator._production_candidate_receipts.erase(added_section)
	coordinator._production_candidates_by_section.erase(added_section)
	coordinator._advance_geometry_owner_dependency_revision_for_candidate(candidate_added)
	coordinator._notify_geometry_owner_candidate_changed(added_section,
		candidate_added, {})
	checks["departed_membership_stays_required_until_empty_receipt_proof"] = \
		session.requiredSections.has(added_section) \
			and not session.sectionTokens.has(added_section) \
			and session.stage == "section_manifests" \
			and is_same(session.sectionTokens.get(distant), token_distant)
	var current_key := coordinator._geometry_owner_completion_key(roster, [])
	var revision_roster: Dictionary = Completion.seal("world", "building:citadel",
		"foundation", "r18", "publisher-3", [_member("foundation-local", local, "r18"),
			_member("foundation-distant", distant, "r18")]).roster
	var incarnation_roster: Dictionary = Completion.seal("world", "building:citadel",
		"foundation", "r17", "publisher-4", [member_a, member_b]).roster
	var membership_roster: Dictionary = Completion.seal("world", "building:citadel",
		"foundation", "r17", "publisher-3", [member_a, member_b,
			_member("foundation-added", Vector3i(200, 1, -342))]).roster
	checks["source_revision_change_uses_fresh_proof_identity"] = \
		coordinator._geometry_owner_completion_key(revision_roster, []) != current_key
	checks["owner_incarnation_change_uses_fresh_proof_identity"] = \
		coordinator._geometry_owner_completion_key(incarnation_roster, []) != current_key
	checks["member_digest_change_uses_fresh_proof_identity"] = \
		coordinator._geometry_owner_completion_key(membership_roster, []) != current_key
	var empty_prior: Array = []
	empty_prior.make_read_only()
	var revision_request := coordinator.request_geometry_owner_completion(
		revision_roster, empty_prior)
	checks["stale_revision_cannot_reuse_old_completion_session"] = \
		revision_request.get("status") == "pending" \
			and String(revision_request.get("sessionKey", "")) != proof_key \
			and String(revision_request.get("sessionKey", "")) \
				== coordinator._geometry_owner_completion_key(revision_roster, [])
	var passed := true
	for value: Variant in checks.values(): passed = passed and value == true
	var report := {"schema":"world-static-section-coordinator-section-closure-contract/v1",
		"evidence":"synthetic_coordinator_contract", "passed":passed,
		"checkCount":checks.size(), "checks":checks,
		"doesNotProve":"Provider integration, native ACK timing, headed visuals, traversal, collision or performance."}
	var report_path := OS.get_environment("WORLD_STATIC_SECTION_COORDINATOR_CLOSURE_REPORT")
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write coordinator section-closure report")
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	print(JSON.stringify(report))
	quit(0 if passed else 1)


func _member(segment_id: String, owner: Vector3i, revision := "r17") -> Dictionary:
	var compatibility := {"meshContentDigest":"mesh".sha256_text(),
		"meshResourceKey":"mesh:stone", "materialKey":"material:stone",
		"pipelineRevision":"pipeline:1", "renderLayer":"opaque",
		"translucentSortPolicy":"none", "renderTier":"near", "castShadows":true,
		"visibilityRangeEnd":128.0, "fadeMargin":8.0}
	var buffer: Array[float] = []
	buffer.assign(Attributes.encode(Transform3D(Basis.IDENTITY, Vector3(1, 1, 1)),
		Color.WHITE, Color.WHITE))
	buffer.make_read_only()
	return Completion.packed_member("building:citadel", "foundation", revision,
		segment_id, 0, owner, AABB(Vector3.ZERO, Vector3.ONE), buffer, 0, compatibility)


func _candidate(candidate_id: String, revision: String) -> Dictionary:
	return {"generation":1, "candidate":{"snapshot":{"manifest":[{
		"sourceId":"building:citadel", "sourcePartId":"foundation",
		"sourceRevision":revision, "candidateId":candidate_id,
		"geometrySourceRanges":[]}]}}}
