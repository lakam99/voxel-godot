extends SceneTree

const Ledger = preload("res://scripts/world/PreparedStaticContributorLedger.gd")
const Grid = preload("res://scripts/world/StaticRenderSectionGrid.gd")
const Attributes = preload("res://scripts/world/StaticInstanceAttributeBuffer.gd")
const TEST_MESH_DIGEST := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

var checks: Dictionary = {}
var source_id_by_part: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var ledger = Ledger.new()
	var initial_declarations := _array([
		_declaration("part-a", "source-a", "rev-1", Vector3(2.0, 1.0, 2.0), ["seg-a"]),
		_declaration("part-b", "source-b", "rev-1", Vector3(24.0, 1.0, 2.0), ["seg-b"])])
	var no_removals := _array([])
	var began: Dictionary = ledger.begin_boundary("boundary-1", initial_declarations, no_removals)
	checks["boundary_declares_exact_revision_and_segment_set"] = began.get("status") == "ready" \
		and began.get("replacementCount") == 2 and began.get("removalCount") == 0
	var accepted_b: Dictionary = ledger.accept_prepared_segment("boundary-1",
		_segment("part-b", "source-b", "rev-1", "seg-b", [0.0]))
	var accepted_a: Dictionary = ledger.accept_prepared_segment("boundary-1",
		_segment("part-a", "source-a", "rev-1", "seg-a", [0.0, 1.0]))
	var admitted_buffer: Array[float] = _segment("part-a", "source-a", "rev-1", "seg-probe", [3.0]).buffer
	var legacy_buffer := _encode(Transform3D.IDENTITY)
	var truncated_legacy_buffer: Array[float] = legacy_buffer.slice(0, 16)
	truncated_legacy_buffer.make_read_only()
	var legacy_probe: Dictionary = _segment("part-a", "source-a", "rev-1", "seg-probe", [3.0]).duplicate(false)
	legacy_probe["buffer"] = truncated_legacy_buffer
	legacy_probe.make_read_only()
	var legacy_admission: Dictionary = ledger.accept_prepared_segment("boundary-1", legacy_probe)
	checks["typed_readonly_twenty_float_lane_buffer_admitted_and_legacy_width_named"] = \
		admitted_buffer.get_typed_builtin() == TYPE_FLOAT and admitted_buffer.is_read_only() \
		and admitted_buffer.size() == Attributes.FLOATS_PER_INSTANCE \
		and accepted_a.get("status") == "accepted" \
		and legacy_admission.get("reason") == "prepared_segment_buffer_width_mismatch:16!=1*20"
	var current_initial := _revisions({"part-a":"rev-1", "part-b":"rev-1"})
	var initial_prepared: Dictionary = ledger.prepare_boundary("boundary-1", current_initial,
		"ledger-contract-world", 1)
	if initial_prepared.get("status") != "prepared":
		push_error("ledger initial candidate preparation failed: %s" % JSON.stringify(initial_prepared))
		quit(1)
		return
	var initial_install := _mock_install_set(initial_prepared)
	var replacement_envelopes: Array = initial_prepared.get("replacements", [])
	var replacements_are_bound := replacement_envelopes.size() == 2
	for replacement_value: Variant in replacement_envelopes:
		if not replacement_value is Dictionary or not replacement_value.is_read_only():
			replacements_are_bound = false
			continue
		var replacement: Dictionary = replacement_value
		var snapshot: Variant = replacement.get("snapshot")
		if String(replacement.get("worldId", "")) != "ledger-contract-world" \
				or int(replacement.get("generation", 0)) != 1 \
				or not snapshot is Dictionary or not snapshot.is_read_only() \
				or snapshot.get("sectionKey") != replacement.get("sectionKey"):
			replacements_are_bound = false
	checks["ledger_binds_exact_prepared_section_replacements_before_install"] = replacements_are_bound
	var premature_receipts: Array = [initial_install.receipts[0]]
	premature_receipts.make_read_only()
	var premature_commit: Dictionary = ledger.accept_installed_candidate("boundary-1",
		premature_receipts, current_initial)
	var mismatched_receipts: Array = initial_install.receipts.duplicate()
	var mismatched_receipt: Dictionary = initial_install.receipts[0].duplicate(false)
	mismatched_receipt["contentManifestDigest"] = "wrong-section-content"
	mismatched_receipt.make_read_only()
	mismatched_receipts[0] = mismatched_receipt
	mismatched_receipts.make_read_only()
	var digest_mismatch_commit: Dictionary = ledger.accept_installed_candidate("boundary-1",
		mismatched_receipts, current_initial)
	var no_promotion_before_full_install := ledger.committed_source_part_ids().is_empty()
	var wrong_world_receipts: Array = initial_install.receipts.duplicate()
	var wrong_world_receipt: Dictionary = initial_install.receipts[0].duplicate(false)
	wrong_world_receipt["worldId"] = "different-world"
	wrong_world_receipt.make_read_only()
	wrong_world_receipts[0] = wrong_world_receipt
	wrong_world_receipts.make_read_only()
	var wrong_world_commit: Dictionary = ledger.accept_installed_candidate("boundary-1",
		wrong_world_receipts, current_initial)
	checks["ledger_rejects_receipts_from_another_world_epoch"] = \
		wrong_world_commit.get("reason") == "section_receipt_does_not_match_candidate" \
		and ledger.committed_source_part_ids().is_empty()
	var initial_commit: Dictionary = ledger.accept_installed_candidate("boundary-1",
		initial_install.receipts, current_initial)
	checks["incremental_flush_inputs_commit_as_one_deterministic_source_specific_snapshot"] = \
		accepted_b.get("status") == "accepted" and accepted_a.get("status") == "accepted" \
		and initial_prepared.get("status") == "prepared" \
		and initial_commit.get("status") == "committed" \
		and initial_commit.partition.outputInstanceCount == 3 \
		and initial_commit.partition.sectionCount == 2 \
		and initial_commit.impactedSectionKeys == [Vector3i(0, 0, 0), Vector3i(1, 0, 0)]
	checks["ledger_promotion_waits_for_every_exact_section_receipt"] = \
		premature_commit.get("reason") == "installed_section_set_mismatch" \
		and digest_mismatch_commit.get("reason") == "section_receipt_does_not_match_candidate" \
		and no_promotion_before_full_install \
		and _committed_identity_keys(ledger) == _sorted_ids([_identity("source-a", "part-a"),
			_identity("source-b", "part-b")])
	var committed_inputs: Dictionary = ledger.committed_partition_inputs()
	checks["partition_inputs_are_grouped_by_source_and_keep_stable_compatibility"] = \
		committed_inputs.get("status") == "ready" \
		and committed_inputs.inputsByContributorIdentity.keys() == _sorted_ids([_identity("source-a", "part-a"),
			_identity("source-b", "part-b")]) \
		and committed_inputs.inputsByContributorIdentity[_identity("source-a", "part-a")].size() == 1 \
		and committed_inputs.inputsByContributorIdentity[_identity("source-a", "part-a")][0].batchKey == _compatibility_key() \
		and committed_inputs.compatibilityByKey.has(_compatibility_key()) \
		and committed_inputs.inputs.is_read_only() \
		and committed_inputs.inputsByContributorIdentity[_identity("source-a", "part-a")].is_read_only()
	checks["contributor_identity_api_preserves_legacy_part_ids_and_exposes_source_parts"] = \
		ledger.committed_source_part_ids() == ["part-a", "part-b"] \
		and ledger.committed_source_parts() == _source_parts([
			{"sourceId":"source-a", "sourcePartId":"part-a"},
			{"sourceId":"source-b", "sourcePartId":"part-b"}])
	checks["committed_revision_and_world_transform_reach_partitioner"] = \
		committed_inputs.inputs[0].sourceRevision == "rev-1" \
		and committed_inputs.inputs[0].sourceToWorld.origin == Vector3(2.0, 1.0, 2.0) \
		and ledger.committed_impacted_section_keys() == [Vector3i(0, 0, 0), Vector3i(1, 0, 0)]
	checks["render_resources_are_rejected"] = _resource_input_is_rejected()
	checks["section_candidate_accepts_cutout_and_rejects_invalid_sort_policy"] = _layer_policy_contract()
	checks["pipeline_revision_participates_in_stable_batch_identity"] = \
		_compatibility_key("building-static-v1") != _compatibility_key("building-static-v2")

	var replacement := _declaration("part-a", "source-a", "rev-2", Vector3(46.0, 1.0, 2.0), ["seg-new"])
	var removal := _removal("part-b", "source-b", "rev-2")
	var begun_replace: Dictionary = ledger.begin_boundary("boundary-2", _array([replacement]), _array([removal]))
	var accepted_new: Dictionary = ledger.accept_prepared_segment("boundary-2",
		_segment("part-a", "source-a", "rev-2", "seg-new", [0.0]))
	var wrong_current := _revisions({"part-a":"rev-2", "part-b":"rev-1"})
	var stale_result: Dictionary = ledger.prepare_boundary("boundary-2", wrong_current,
		"ledger-contract-world", 2)
	checks["stale_revision_rejects_whole_replace_remove_transaction"] = \
		begun_replace.get("status") == "ready" and accepted_new.get("status") == "accepted" \
		and stale_result.get("reason") == "stale_source_revision" \
		and _committed_identity_keys(ledger) == _sorted_ids([_identity("source-a", "part-a"),
			_identity("source-b", "part-b")]) \
		and ledger.committed_partition_inputs().inputs[0].sourceRevision == "rev-1"
	var aborted: Dictionary = ledger.abort_boundary("boundary-2")
	checks["cancel_preserves_previous_committed_ledger"] = aborted.get("status") == "aborted" \
		and _committed_identity_keys(ledger) == _sorted_ids([_identity("source-a", "part-a"),
			_identity("source-b", "part-b")]) \
		and ledger.committed_impacted_section_keys() == [Vector3i(0, 0, 0), Vector3i(1, 0, 0)]

	var begun_replace_again: Dictionary = ledger.begin_boundary("boundary-3", _array([replacement]), _array([removal]))
	ledger.accept_prepared_segment("boundary-3", _segment("part-a", "source-a", "rev-2", "seg-new", [0.0]))
	var proper_current := _revisions({"part-a":"rev-2", "part-b":"rev-2"})
	var replace_remove_prepared: Dictionary = ledger.prepare_boundary("boundary-3", proper_current,
		"ledger-contract-world", 2)
	var stale_install_current := _revisions({"part-a":"rev-2", "part-b":"rev-1"})
	var stale_install: Dictionary = _accept_mock_install(ledger,
		replace_remove_prepared, stale_install_current)
	var prior_ledger_survives_stale_install := _committed_identity_keys(ledger) == \
		_sorted_ids([_identity("source-a", "part-a"), _identity("source-b", "part-b")])
	var commit_replace_remove: Dictionary = _accept_mock_install(ledger,
		replace_remove_prepared, proper_current)
	checks["complete_replace_and_removal_commit_atomically"] = \
		begun_replace_again.get("status") == "ready" \
		and stale_install.get("reason") == "stale_source_revision" \
		and prior_ledger_survives_stale_install \
		and commit_replace_remove.get("status") == "committed" \
		and _committed_identity_keys(ledger) == [_identity("source-a", "part-a")] \
		and commit_replace_remove.partition.outputInstanceCount == 1 \
		and commit_replace_remove.impactedSectionKeys == [Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0)]
	checks["impacts_include_old_new_and_removed_source_sections"] = \
		commit_replace_remove.impactedSectionKeys.has(Grid.key_for_world_position(Vector3(2.0, 1.0, 2.0))) \
		and commit_replace_remove.impactedSectionKeys.has(Grid.key_for_world_position(Vector3(24.0, 1.0, 2.0))) \
		and commit_replace_remove.impactedSectionKeys.has(Grid.key_for_world_position(Vector3(46.0, 1.0, 2.0)))

	var reidentified_part := _declaration("part-a", "source-a-recreated", "rev-3",
		Vector3(70.0, 1.0, 2.0), ["seg-recreated"])
	var reidentify_begin: Dictionary = ledger.begin_boundary("boundary-4",
		_array([reidentified_part]), _array([_removal("part-a", "source-a", "rev-3")]))
	ledger.accept_prepared_segment("boundary-4",
		_segment("part-a", "source-a-recreated", "rev-3", "seg-recreated", [0.0]))
	# Different sources may share a local part ID; replacement explicitly retires
	# the previous source rather than treating that local ID as global authority.
	var reidentify_current := {_identity("source-a", "part-a"):"rev-3",
		_identity("source-a-recreated", "part-a"):"rev-3"}
	reidentify_current.make_read_only()
	var reidentify_prepared: Dictionary = ledger.prepare_boundary("boundary-4", reidentify_current,
		"ledger-contract-world", 3)
	var reidentify_commit: Dictionary = _accept_mock_install(ledger,
		reidentify_prepared, reidentify_current)
	checks["stable_source_part_tracks_old_and_new_sections_when_producer_source_id_changes"] = \
		reidentify_begin.get("status") == "ready" \
		and reidentify_commit.get("status") == "committed" \
		and reidentify_commit.impactedSectionKeys == [Vector3i(2, 0, 0), Vector3i(3, 0, 0)]

	checks["incomplete_boundary_does_not_replace_committed_state"] = _incomplete_preserves(ledger)
	checks["undeclared_and_duplicate_segments_are_rejected"] = _exact_segment_set_rejected(ledger)
	checks["mutable_inputs_and_stale_boundary_token_are_rejected"] = _readonly_and_token_rejected(ledger)
	checks["failed_begin_does_not_leave_partial_transaction_open"] = _failed_begin_does_not_poison(ledger)
	checks["section_generations_increase_and_world_epoch_stays_bound"] = _generation_and_world_binding_rejected()
	checks["same_producer_local_part_under_two_sources_has_distinct_replay_receipts"] = \
		_multiple_sources_can_own_same_local_part_id()
	checks["hidden_source_visibility_survives_ledger_and_section_preparation"] = _hidden_visibility_contract()

	var report := {"schema":"prepared-static-contributor-ledger-contract/v1",
		"checks":checks, "passed":not checks.values().has(false),
		"evidence":"pure revisioned prepared-segment ledger transaction and section partition contract; no BuildingPartPublisher wiring, section backend install, worker scheduling, collision, or live gameplay acceptance",
		"committedSourcePartIds":ledger.committed_source_part_ids(),
		"committedSourceParts":ledger.committed_source_parts(),
		"committedImpactedSections":ledger.committed_impacted_section_keys(),
		"resourceObjectsRetained":false}
	var report_path := OS.get_environment("PREPARED_STATIC_CONTRIBUTOR_LEDGER_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
	print("PREPARED STATIC CONTRIBUTOR LEDGER ", JSON.stringify(report))
	quit(0 if report.passed else 1)


func _declaration(part_id: String, source_id: String, revision: String,
		origin: Vector3, segment_ids: Array) -> Dictionary:
	source_id_by_part[part_id] = source_id
	var segments: Array[Dictionary] = []
	for segment_id: String in segment_ids:
		var segment := {"segmentId":segment_id, "materialKey":"wood_oak",
			"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
			"renderTier":"structural", "meshKey":"unit-box-v1",
			"meshContentDigest":TEST_MESH_DIGEST,
			"meshLocalBounds":_unit_box_bounds(),
			"pipelineRevision":"building-static-v1", "renderLayer":"opaque",
			"translucentSortPolicy":"none", "castShadows":true,
			"visibilityRangeEnd":240.0, "fadeMargin":18.0,
			"compatibilityKey":_compatibility_key("building-static-v1")}
		segment.make_read_only()
		segments.append(segment)
	segments.make_read_only()
	var declaration := {"sourcePartId":part_id, "sourceId":source_id,
		"sourceRevision":revision,
		"sourceToWorld":Transform3D(Basis.IDENTITY, origin),
		"ownerCell":Grid.logical_owner_cell_for_world_position(origin),
		"segments":segments}
	declaration.make_read_only()
	return declaration


func _removal(part_id: String, source_id: String, revision: String) -> Dictionary:
	source_id_by_part[part_id] = source_id
	var removal := {"sourcePartId":part_id, "sourceId":source_id, "sourceRevision":revision}
	removal.make_read_only()
	return removal


func _segment(part_id: String, source_id: String, revision: String,
		segment_id: String, local_x: Array[float]) -> Dictionary:
	var buffer: Array[float] = []
	for x_value: float in local_x:
		buffer.append_array(_encode(Transform3D(Basis.IDENTITY, Vector3(x_value, 0.0, 0.0))))
	buffer.make_read_only()
	var input := {"sourcePartId":part_id, "sourceId":source_id,
		"sourceRevision":revision, "segmentId":segment_id, "buffer":buffer,
		"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"instanceCount":local_x.size(), "materialKey":"wood_oak",
		"renderTier":"structural", "meshKey":"unit-box-v1",
		"meshContentDigest":TEST_MESH_DIGEST,
		"meshLocalBounds":_unit_box_bounds(),
		"pipelineRevision":"building-static-v1", "renderLayer":"opaque",
		"translucentSortPolicy":"none", "castShadows":true,
		"visibilityRangeEnd":240.0, "fadeMargin":18.0,
		"compatibilityKey":_compatibility_key("building-static-v1")}
	input.make_read_only()
	return input


func _encode(transform: Transform3D) -> Array[float]:
	return [transform.basis.x.x, transform.basis.y.x, transform.basis.z.x, transform.origin.x,
		transform.basis.x.y, transform.basis.y.y, transform.basis.z.y, transform.origin.y,
		transform.basis.x.z, transform.basis.y.z, transform.basis.z.z, transform.origin.z,
		1.0, 1.0, 1.0, 1.0,
		0.2, 0.5, 0.7, 1.0]


func _compatibility_key(pipeline_revision := "building-static-v1",
		render_layer := "opaque", sort_policy := "none", intended_visible := true) -> String:
	return "section-batch:" + JSON.stringify([Attributes.LAYOUT_SCHEMA,
		"wood_oak", "structural", "unit-box-v1", TEST_MESH_DIGEST,
		pipeline_revision, render_layer, sort_policy, true, 240.0, 18.0,
		-0.5, -0.5, -0.5, 1.0, 1.0, 1.0, intended_visible]).sha256_text()


func _hidden_visibility_contract() -> bool:
	var ledger = Ledger.new()
	var declaration := _declaration("hidden", "hidden-source", "rev", Vector3(2, 2, 2), ["seg"]).duplicate(false)
	var declared_segment: Dictionary = declaration.segments[0].duplicate(false)
	declared_segment["intendedVisible"] = false
	declared_segment["compatibilityKey"] = _compatibility_key("building-static-v1", "opaque", "none", false)
	declared_segment.make_read_only()
	declaration["segments"] = _array([declared_segment])
	declaration.make_read_only()
	if ledger.begin_boundary("hidden", _array([declaration]), _array([])).get("status") != "ready": return false
	var visible := _segment("hidden", "hidden-source", "rev", "seg", [0.0])
	var rejected: Dictionary = ledger.accept_prepared_segment("hidden", visible)
	if rejected.get("status") != "failed": return false
	var hidden := visible.duplicate(false)
	hidden["intendedVisible"] = false
	hidden["compatibilityKey"] = declared_segment.compatibilityKey
	hidden.make_read_only()
	if ledger.accept_prepared_segment("hidden", hidden).get("status") != "accepted": return false
	var prepared: Dictionary = ledger.prepare_boundary("hidden", _revisions({"hidden":"rev"}), "visibility-world", 1)
	if prepared.get("status") != "prepared" or prepared.replacements.is_empty(): return false
	var count := 0
	for replacement: Dictionary in prepared.replacements:
		for batch: Dictionary in replacement.snapshot.batches.values():
			if batch.get("intendedVisible", true) != false: return false
			count += 1
	return count > 0


func _unit_box_bounds() -> AABB:
	return AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)


func _array(values: Array) -> Array:
	values.make_read_only()
	return values


func _revisions(values: Dictionary) -> Dictionary:
	var identities: Dictionary = {}
	for part_value: Variant in values:
		var part_id := String(part_value)
		var source_id := String(source_id_by_part.get(part_id, part_id))
		identities[_identity(source_id, part_id)] = values[part_value]
	identities.make_read_only()
	return identities


func _identity(source_id: String, part_id: String) -> String:
	return "section-part:" + var_to_bytes([source_id, part_id]).hex_encode()


func _committed_identity_keys(ledger) -> Array[String]:
	var result: Array[String] = []
	for identity_value: Variant in ledger.committed_source_parts():
		if identity_value is Dictionary:
			result.append(_identity(String(identity_value.get("sourceId", "")),
				String(identity_value.get("sourcePartId", ""))))
	result.sort()
	return result


func _source_parts(values: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for value: Variant in values:
		if value is Dictionary:
			var identity := {"sourceId":String(value.get("sourceId", "")),
				"sourcePartId":String(value.get("sourcePartId", ""))}
			identity.make_read_only()
			result.append(identity)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _identity(String(a.sourceId), String(a.sourcePartId)) \
			< _identity(String(b.sourceId), String(b.sourcePartId)))
	result.make_read_only()
	return result


func _sorted_ids(values: Array[String]) -> Array[String]:
	values.sort()
	return values


func _accept_mock_install(ledger, prepared: Dictionary, current_source_revisions: Dictionary) -> Dictionary:
	if prepared.get("status") != "prepared":
		return prepared
	var install_set := _mock_install_set(prepared)
	return ledger.accept_installed_candidate(String(prepared.boundaryId),
		install_set.receipts, current_source_revisions)


func _mock_install_set(prepared: Dictionary) -> Dictionary:
	var receipts: Array[Dictionary] = []
	for replacement: Dictionary in prepared.get("replacements", []):
		var receipt := {"status":"installed", "sectionKey":replacement.sectionKey,
			"worldId":replacement.worldId,
			"generation":replacement.generation,
			"contentManifestDigest":replacement.contentManifestDigest}
		receipt.make_read_only()
		receipts.append(receipt)
	receipts.make_read_only()
	return {"receipts":receipts}


func _resource_input_is_rejected() -> bool:
	var ledger = Ledger.new()
	if ledger.begin_boundary("resource", _array([_declaration("p", "s", "r", Vector3.ZERO, ["seg"])]), _array([])).status != "ready":
		return false
	var input := _segment("p", "s", "r", "seg", [0.0]).duplicate(false)
	input["material"] = StandardMaterial3D.new()
	input.make_read_only()
	return ledger.accept_prepared_segment("resource", input).get("reason") == "render_resources_not_allowed"


func _layer_policy_contract() -> bool:
	var ledger = Ledger.new()
	var declaration := _declaration("p", "s", "r", Vector3.ZERO, ["seg"]).duplicate(false)
	var segments: Array[Dictionary] = []
	var cutout := {"segmentId":"seg", "materialKey":"wood_oak",
		"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"renderTier":"structural", "meshKey":"unit-box-v1",
		"meshContentDigest":TEST_MESH_DIGEST, "meshLocalBounds":_unit_box_bounds(),
		"pipelineRevision":"building-static-v1", "renderLayer":"cutout",
		"translucentSortPolicy":"none", "castShadows":true,
		"visibilityRangeEnd":240.0, "fadeMargin":18.0,
		"compatibilityKey":_compatibility_key("building-static-v1", "cutout", "none")}
	cutout.make_read_only()
	segments.append(cutout)
	segments.make_read_only()
	declaration["segments"] = segments
	declaration.make_read_only()
	var accepted: Dictionary = ledger.begin_boundary("layer", _array([declaration]), _array([]))
	var invalid_sort_ledger = Ledger.new()
	var invalid_sort_declaration := _declaration("p", "s", "r", Vector3.ZERO, ["seg"]).duplicate(false)
	var invalid_sort_segments: Array[Dictionary] = []
	var invalid_sort := {"segmentId":"seg", "materialKey":"wood_oak",
		"instanceAttributeLayout":Attributes.LAYOUT_SCHEMA,
		"renderTier":"structural", "meshKey":"unit-box-v1",
		"meshContentDigest":TEST_MESH_DIGEST, "meshLocalBounds":_unit_box_bounds(),
		"pipelineRevision":"building-static-v1", "renderLayer":"cutout",
		"translucentSortPolicy":"camera_depth", "castShadows":true,
		"visibilityRangeEnd":240.0, "fadeMargin":18.0,
		"compatibilityKey":_compatibility_key("building-static-v1", "cutout", "camera_depth")}
	invalid_sort.make_read_only()
	invalid_sort_segments.append(invalid_sort)
	invalid_sort_segments.make_read_only()
	invalid_sort_declaration["segments"] = invalid_sort_segments
	invalid_sort_declaration.make_read_only()
	var rejected_sort: Dictionary = invalid_sort_ledger.begin_boundary("invalid-sort",
		_array([invalid_sort_declaration]), _array([]))
	return accepted.get("status") == "ready" \
		and rejected_sort.get("reason") == "invalid_segment_declaration"


func _incomplete_preserves(ledger) -> bool:
	var before_ids: Array[String] = _committed_identity_keys(ledger)
	var before_inputs: Dictionary = ledger.committed_partition_inputs()
	var declaration := _declaration("part-a", "source-a", "rev-3", Vector3(70.0, 1.0, 2.0), ["one", "two"])
	if ledger.begin_boundary("incomplete", _array([declaration]), _array([])).status != "ready":
		return false
	ledger.accept_prepared_segment("incomplete", _segment("part-a", "source-a", "rev-3", "one", [0.0]))
	var result: Dictionary = ledger.prepare_boundary("incomplete", _revisions({"part-a":"rev-3"}),
		"ledger-contract-world", 4)
	var after_inputs: Dictionary = ledger.committed_partition_inputs()
	ledger.abort_boundary("incomplete")
	return result.get("reason") == "boundary_incomplete" \
		and _committed_identity_keys(ledger) == before_ids \
		and after_inputs.inputs.size() == before_inputs.inputs.size() \
		and after_inputs.inputs[0].sourceRevision == before_inputs.inputs[0].sourceRevision


func _multiple_sources_can_own_same_local_part_id() -> bool:
	var ledger = Ledger.new()
	var first := _declaration("foliage:00000000", "tree-a", "rev-a",
		Vector3(2.0, 2.0, 2.0), ["seg-a"])
	var second := _declaration("foliage:00000000", "tree-b", "rev-b",
		Vector3(4.0, 2.0, 2.0), ["seg-b"])
	var begun: Dictionary = ledger.begin_boundary("same-local-part", _array([first, second]), _array([]))
	if begun.get("status") != "ready": return false
	var accepted_a: Dictionary = ledger.accept_prepared_segment("same-local-part",
		_segment("foliage:00000000", "tree-a", "rev-a", "seg-a", [0.0]))
	var accepted_b: Dictionary = ledger.accept_prepared_segment("same-local-part",
		_segment("foliage:00000000", "tree-b", "rev-b", "seg-b", [0.0]))
	var revisions: Dictionary = {_identity("tree-a", "foliage:00000000"):"rev-a",
		_identity("tree-b", "foliage:00000000"):"rev-b"}
	revisions.make_read_only()
	var prepared: Dictionary = ledger.prepare_boundary("same-local-part", revisions,
		"ledger-contract-world", 1)
	if prepared.get("status") != "prepared": return false
	var installed := _accept_mock_install(ledger, prepared, revisions)
	return accepted_a.get("status") == "accepted" and accepted_b.get("status") == "accepted" \
		and installed.get("status") == "committed" \
		and _committed_identity_keys(ledger) == _sorted_ids([
			_identity("tree-a", "foliage:00000000"), _identity("tree-b", "foliage:00000000")]) \
		and ledger.committed_source_part_ids() == ["foliage:00000000", "foliage:00000000"] \
		and ledger.committed_source_parts() == _source_parts([
			{"sourceId":"tree-a", "sourcePartId":"foliage:00000000"},
			{"sourceId":"tree-b", "sourcePartId":"foliage:00000000"}])


func _exact_segment_set_rejected(ledger) -> bool:
	var declaration := _declaration("part-a", "source-a", "rev-4", Vector3(80.0, 1.0, 2.0), ["declared"])
	if ledger.begin_boundary("exact", _array([declaration]), _array([])).status != "ready":
		return false
	var undeclared: Dictionary = ledger.accept_prepared_segment("exact", _segment("part-a", "source-a", "rev-4", "other", [0.0]))
	var accepted: Dictionary = ledger.accept_prepared_segment("exact", _segment("part-a", "source-a", "rev-4", "declared", [0.0]))
	var duplicate: Dictionary = ledger.accept_prepared_segment("exact", _segment("part-a", "source-a", "rev-4", "declared", [1.0]))
	ledger.abort_boundary("exact")
	return undeclared.get("reason") == "undeclared_segment" \
		and accepted.get("status") == "accepted" \
		and duplicate.get("reason") == "duplicate_prepared_segment"


func _readonly_and_token_rejected(ledger) -> bool:
	var declaration := _declaration("part-a", "source-a", "rev-5", Vector3(90.0, 1.0, 2.0), ["seg"])
	if ledger.begin_boundary("readonly", _array([declaration]), _array([])).status != "ready":
		return false
	var mutable_input := _segment("part-a", "source-a", "rev-5", "seg", [0.0]).duplicate(false)
	mutable_input["sourceRevision"] = "rev-5"
	var mutable_result: Dictionary = ledger.accept_prepared_segment("readonly", mutable_input)
	var stale_result: Dictionary = ledger.accept_prepared_segment("wrong-token",
		_segment("part-a", "source-a", "rev-5", "seg", [0.0]))
	ledger.abort_boundary("readonly")
	return mutable_result.get("reason") == "mutable_prepared_segment" \
		and stale_result.get("reason") == "boundary_not_current"


func _failed_begin_does_not_poison(ledger) -> bool:
	var mutable_declaration := _declaration("part-a", "source-a", "rev-6", Vector3.ZERO, ["seg"]).duplicate(false)
	var bad: Dictionary = ledger.begin_boundary("bad", _array([mutable_declaration]), _array([]))
	var good: Dictionary = ledger.begin_boundary("good", _array([_declaration("part-a", "source-a", "rev-6", Vector3.ZERO, ["seg"])]), _array([]))
	if good.get("status") == "ready":
		ledger.abort_boundary("good")
	return bad.get("reason") == "mutable_or_invalid_declaration" and good.get("status") == "ready"


func _generation_and_world_binding_rejected() -> bool:
	var ledger = Ledger.new()
	var first := _declaration("part", "source", "rev-1", Vector3.ZERO, ["seg-1"])
	if ledger.begin_boundary("epoch-1", _array([first]), _array([])).get("status") != "ready":
		return false
	ledger.accept_prepared_segment("epoch-1", _segment("part", "source", "rev-1", "seg-1", [0.0]))
	var revisions := _revisions({"part":"rev-1"})
	var prepared: Dictionary = ledger.prepare_boundary("epoch-1", revisions, "world-a", 5)
	if _accept_mock_install(ledger, prepared, revisions).get("status") != "committed":
		return false
	var second := _declaration("part", "source", "rev-2", Vector3.ZERO, ["seg-2"])
	if ledger.begin_boundary("epoch-2", _array([second]), _array([])).get("status") != "ready":
		return false
	ledger.accept_prepared_segment("epoch-2", _segment("part", "source", "rev-2", "seg-2", [1.0]))
	var next_revisions := _revisions({"part":"rev-2"})
	var stale_generation: Dictionary = ledger.prepare_boundary("epoch-2", next_revisions, "world-a", 5)
	var wrong_world: Dictionary = ledger.prepare_boundary("epoch-2", next_revisions, "world-b", 6)
	ledger.abort_boundary("epoch-2")
	return stale_generation.get("reason") == "stale_section_candidate_generation" \
		and wrong_world.get("reason") == "section_candidate_world_changed"
