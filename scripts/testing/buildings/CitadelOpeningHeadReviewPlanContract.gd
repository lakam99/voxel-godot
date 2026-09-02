extends SceneTree

## Named synthetic source/index-description controls. No scene or visibility proof.
const Plan = preload("res://scripts/testing/buildings/CitadelOpeningHeadReviewPlan.gd")
var _checks: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var output: String = OS.get_environment("VOXEL_OPENING_HEAD_REVIEW_PLAN_REPORT")
	if not output.is_absolute_path() or output.get_extension() != "json" or FileAccess.file_exists(output) or not DirAccess.dir_exists_absolute(output.get_base_dir()):
		quit(2)
		return
	var data: Dictionary = _fixture()
	var frozen: PackedByteArray = var_to_bytes(data)
	var result: Dictionary = _build(data)
	_checks.synthetic_ready = result.ready
	_checks.input_immutable = frozen == var_to_bytes(data)
	_checks.repeat_exact = var_to_bytes(result) == var_to_bytes(_build(data))
	var omitted: Dictionary = data.duplicate(true)
	for proposal: Dictionary in omitted.proposals:
		for connection: Dictionary in proposal.connectionArrangement.connections:
			connection.erase("rotation")
	var omitted_before: PackedByteArray = var_to_bytes(omitted)
	var omitted_result: Dictionary = _build(omitted)
	_checks.omitted_connection_rotation_canonical_zero = omitted_result.ready and var_to_bytes(omitted_result) == var_to_bytes(result)
	_checks.omitted_rotation_input_immutable = omitted_before == var_to_bytes(omitted)
	var explicit_rotation: Dictionary = data.duplicate(true)
	explicit_rotation.proposals[0].connectionArrangement.connections[0].rotation = Vector3(0, 0.25, 0)
	var explicit_result: Dictionary = _build(explicit_rotation)
	_checks.explicit_nonzero_rotation_mismatch_rejected = not explicit_result.ready and explicit_result.views.is_empty() and explicit_result.reason == "missing_or_stale_connection"
	var nonzero_actual: Dictionary = omitted.duplicate(true)
	_find(nonzero_actual, "alpha_end_a").rotation = Vector3(0, 0.25, 0)
	var nonzero_result: Dictionary = _build(nonzero_actual)
	_checks.omission_cannot_match_nonzero_actual = not nonzero_result.ready and nonzero_result.views.is_empty() and nonzero_result.reason == "missing_or_stale_connection"
	var reversed: Dictionary = data.duplicate(true)
	reversed.snapshot.parts.reverse()
	reversed.proposals.reverse()
	reversed.cuts.reverse()
	reversed.contacts.reverse()
	_checks.input_order_independent = var_to_bytes(result) == var_to_bytes(_build(reversed))
	if result.ready:
		_checks.context_header_only = result.views[0].targets == ["alpha_header"] and result.views[0].kind == "ordinary"
		_checks.closure_context_contains_hidden_connections = result.views[0].bounds.encloses(_box(_find(data, "alpha_end_a"))) and result.inventory.nonMandatoryConnectionIds.size() == 2
		_checks.cut_identity_adapter_schema = result.views.size() == 3 and result.views[1].kind == "close_inspection" and result.views[1].exactCutKey == "alpha_brick" and result.views[1].targets == ["alpha_panel"]
		_checks.detail_is_not_access_evidence = result.views[1].cameraEvidenceScope == "appearance_only_not_player_or_access_evidence" and result.views[0].kind == "ordinary"
		_checks.appearance_context_additive_not_street_replacement = result.views[2].role == "appearance_context" and result.views[2].kind == "close_inspection" and result.views[2].bounds == result.views[0].bounds and result.views[2].targets == result.views[0].targets and result.views[2].cameraEvidenceScope == "appearance_only_not_player_or_access_evidence"
		_checks.exact_cut_bounds = result.views[1].cutBounds == data.cuts[0].bounds
		_checks.omitted_cut_explicit = result.inventory.omittedCuts.size() == 1 and result.inventory.omittedCuts[0].key == "beta_brick"
		_checks.all_rows_accounted = result.contactMappings.size() == 3 and result.inventory.omittedContactRowIds == ["row_other"] and result.inventory.inputContactCount == 4
		_checks.distinct_rows_same_hit_preserved = result.contactMappings[0].rowId == "row_a" and result.contactMappings[1].rowId == "row_b" and result.contactMappings[0].windowScalars == result.contactMappings[1].windowScalars
		_checks.selected_mapping_membership = result.contactMappings.all(func(row: Dictionary) -> bool: return row.viewIds.has(result.views[0].id) and result.views[0].contactRowIds.has(row.rowId))
		_checks.contacts_still_red = result.contactMappings.all(func(row: Dictionary) -> bool: return row.status == "RED_UNRESOLVED" and row.contactCleared == false)
		_checks.hidden_connection_contact_not_mandatory = result.contactMappings[2].framingId == "alpha_end_a" and result.contactMappings[2].framingMandatoryVisible == false
		_checks.scalar_window_exact = result.contactMappings[0].windowScalars == [-0.25, 2.0, -0.5, 0.25, 2.25, 0.5]
		_checks.no_authored_camera_pose = result.views.all(func(view: Dictionary) -> bool: return not view.has("position") and not view.has("cameraPosition") and not view.has("hiddenPartIds"))
	for mode: String in ["two_selected", "unknown_selected", "duplicate_source", "missing_header", "missing_trim", "missing_connection", "missing_peer", "duplicate_house", "duplicate_trim", "stale_header", "unready_arrangement", "wrong_header_seat", "foreign_cut", "duplicate_cut", "invalid_cut_bounds", "duplicate_row", "missing_framing", "missing_obstacle", "malformed_row", "invalid_interval", "nonpositive_overlap", "view_overflow"]:
		_negative(mode, data)
	var no_cuts: Dictionary = data.duplicate(true)
	var seven_cuts: Dictionary = data.duplicate(true)
	for index in range(6): seven_cuts.cuts.append({"key": "seventh_boundary_%d" % index, "partId": "alpha_panel", "bounds": data.cuts[0].bounds})
	var over_limit: Dictionary = _build(seven_cuts)
	_checks.seven_cuts_plus_two_contexts_exceeds_eight = not over_limit.ready and over_limit.reason == "view_limit_no_truncation" and over_limit.views.is_empty()
	no_cuts.cuts = []
	var context_only: Dictionary = _build(no_cuts)
	_checks.no_cut_retains_both_distinct_context_scopes = context_only.ready and context_only.views.size() == 2 and context_only.inventory.inputCutCount == 0 and context_only.views[0].kind == "ordinary" and context_only.views[1].role == "appearance_context"
	var direct: Dictionary = data.duplicate(true)
	var direct_proposal: Dictionary = direct.proposals[0]
	direct_proposal.connectionIds = ["alpha_end_b"]
	direct_proposal.connectionArrangement.connections = [direct_proposal.connectionArrangement.connections[1]]
	var header: Dictionary = _find(direct, "alpha_header")
	header.recipe = _recipe(["beta_gable_a", "alpha_end_b"])
	direct_proposal.header = header.duplicate(true)
	direct_proposal.connectionArrangement.body = header.duplicate(true)
	direct_proposal.connectionArrangement.directSeats = [{"declaredGableId": "alpha_gable_a", "fact": {"seatId": "beta_gable_a"}}]
	# Remove the now-nonframing contact, not its original source obstacle geometry.
	direct.contacts = direct.contacts.filter(func(row: Dictionary) -> bool: return row.inputRow.headerId != "alpha_end_a")
	var direct_result: Dictionary = _build(direct)
	_checks.shared_direct_peer_closure = direct_result.ready and direct_result.inventory.selectedClosureIds.has("beta_gable_a") and direct_result.views[0].targets == ["alpha_header"]
	var passed: bool = _checks.values().all(func(value: Variant) -> bool: return value == true)
	var report: Dictionary = {"passed": passed, "checkCount": _checks.size(), "checks": _checks,
		"planSHA256": FileAccess.get_sha256("res://scripts/testing/buildings/CitadelOpeningHeadReviewPlan.gd"),
		"evidenceLevel": "synthetic_source_derived_inspection_inventory",
		"doesNotProve": "No actual candidate execution, mesh binding, observer feasibility, occlusion, screenshots, contact clearance, physical or gameplay acceptance."}
	var text: String = JSON.stringify(report, "  ") + "\n"
	var file: FileAccess = FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(text)
	file.flush()
	var written: bool = file.get_error() == OK
	file.close()
	written = written and FileAccess.get_sha256(output) == text.sha256_text()
	quit(0 if passed and written else 2)

func _negative(mode: String, original: Dictionary) -> void:
	var data: Dictionary = original.duplicate(true)
	match mode:
		"two_selected": data.selected.append("beta")
		"unknown_selected": data.selected = ["unknown"]
		"duplicate_source": data.snapshot.parts.append(data.snapshot.parts[0].duplicate(true))
		"missing_header": _remove(data, "alpha_header")
		"missing_trim": _remove(data, "alpha_panel")
		"missing_connection": _remove(data, "alpha_end_a")
		"missing_peer": _remove(data, "alpha_gable_a")
		"duplicate_house": data.proposals.append(data.proposals[0].duplicate(true))
		"duplicate_trim": data.proposals[0].trimmedPanelIds.append("alpha_panel")
		"stale_header": data.proposals[0].header.size.y += 0.25
		"unready_arrangement": data.proposals[0].connectionArrangement.ready = false
		"wrong_header_seat": _find(data, "alpha_panel").recipe = _recipe(["beta_header"])
		"foreign_cut": data.cuts[0].partId = "alpha_gable_a"
		"duplicate_cut": data.cuts.append(data.cuts[0].duplicate(true))
		"invalid_cut_bounds": data.cuts[0].bounds = AABB(Vector3(NAN, 0, 0), Vector3.ONE)
		"duplicate_row": data.contacts.append(data.contacts[0].duplicate(true))
		"missing_framing": data.contacts[0].inputRow.headerId = "alpha_panel"
		"missing_obstacle": data.contacts[0].inputRow.obstacleId = "missing"
		"malformed_row": data.contacts[0].erase("inputRow")
		"invalid_interval": data.contacts[0].inputRow.headerBounds[0] = NAN
		"nonpositive_overlap": data.contacts[0].inputRow.obstacleBounds = [10, 10, 10, 11, 11, 11]
		"view_overflow":
			for index: int in range(7): data.cuts.append({"key": "extra_%d" % index, "partId": "alpha_panel", "bounds": data.cuts[0].bounds})
	var frozen: PackedByteArray = var_to_bytes(data)
	var rejected: Dictionary = _build(data)
	_checks[mode + ":atomic_rejection"] = not rejected.ready and not rejected.reason.is_empty() and rejected.views.is_empty() and rejected.contactMappings.is_empty() and rejected.inventory.is_empty()
	_checks[mode + ":immutable"] = frozen == var_to_bytes(data)

func _fixture() -> Dictionary:
	var data: Dictionary = {"snapshot": {"parts": []}, "proposals": [], "selected": ["alpha"], "cuts": [], "contacts": []}
	for house: String in ["alpha", "beta"]:
		var offset: Vector3 = Vector3.ZERO if house == "alpha" else Vector3(8, 0, 0)
		var header: Dictionary = _record(house + "_header", "beam", offset + Vector3(0, 2, 0), Vector3(0.5, 0.5, 4), [house + "_end_a", house + "_end_b"])
		var connections: Array = []
		for end: String in ["a", "b"]:
			var z: float = -1.5 if end == "a" else 1.5
			var connection: Dictionary = _record(house + "_end_" + end, "beam", offset + Vector3(0.25, 2, z), Vector3(1, 0.25, 0.25), [house + "_gable_" + end])
			connections.append(connection)
			data.snapshot.parts.append(connection.duplicate(true))
			data.snapshot.parts.append(_record(house + "_gable_" + end, "wall", offset + Vector3(0.5, 1, z), Vector3(2, 2, 0.25), []))
		data.snapshot.parts.append(header.duplicate(true))
		data.snapshot.parts.append(_record(house + "_panel", "wall", offset + Vector3(0, 2.75, 0), Vector3(0.5, 1, 3), [header.id]))
		data.proposals.append({"house": house, "ready": true, "headerId": header.id, "header": header,
			"trimmedPanelIds": [house + "_panel"], "connectionIds": [house + "_end_a", house + "_end_b"],
			"connectionArrangement": {"ready": true, "body": header.duplicate(true), "connections": connections, "directSeats": []}})
		data.cuts.append({"key": house + "_brick", "partId": house + "_panel", "bounds": AABB(offset + Vector3(-0.25, 2.25, -0.5), Vector3(0.5, 0.25, 0.5))})
	data.contacts = [_contact("row_a", "alpha_header"), _contact("row_b", "alpha_header"), _contact("row_c", "alpha_end_a"), _contact("row_other", "beta_header")]
	return data

func _record(id: String, kind: String, position: Vector3, size: Vector3, seats: Array) -> Dictionary:
	return {"id": id, "kind": kind, "material": "timber_beam" if kind == "beam" else "stone_foundation", "semantic": "synthetic_review",
		"position": position, "rotation": Vector3.ZERO, "size": size, "collision": true, "recipe": _recipe(seats)}

func _recipe(seats: Array) -> Dictionary:
	return {"physicalRequiredSeatPartIds": seats.duplicate(), "physicalRequiredSeatFacts": seats.map(func(id: String) -> Dictionary: return {"seatId": id})}

func _contact(id: String, framing: String) -> Dictionary:
	return {"rowId": id, "inputRow": {"channel": Plan.CHANNEL, "headerId": framing, "obstacleId": "alpha_gable_a",
		"headerBounds": [-0.25, 1.75, -2, 0.25, 2.25, 2], "obstacleBounds": [-1, 2, -0.5, 1, 3, 0.5]}}

func _find(data: Dictionary, id: String) -> Dictionary:
	for record: Dictionary in data.snapshot.parts:
		if record.id == id: return record
	return {}

func _remove(data: Dictionary, id: String) -> void:
	data.snapshot.parts = data.snapshot.parts.filter(func(record: Dictionary) -> bool: return record.id != id)

func _box(record: Dictionary) -> AABB:
	return AABB(record.position - record.size * 0.5, record.size)

func _build(data: Dictionary) -> Dictionary:
	return Plan.build(data.snapshot, data.proposals, data.selected, data.cuts, data.contacts)
