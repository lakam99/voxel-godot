extends "res://scripts/testing/buildings/PavingConstructionArtifactContract.gd"

## Frozen-source COMPLETE bay service contract. No generation or engine launch
## by this author; main runs this under its existing watchdog. The inherited
## empty-obstacle projection is a proposal ONLY; actual Frame checks decide.
## Inputs: inherited VOXEL_PAVING_ARTIFACT_SOURCE / _SOURCE_SHA256 and
## VOXEL_PAVING_ARTIFACT_DIAGNOSIS / _DIAGNOSIS_SHA256 (whole08 + blocked02).
## Output: new absolute VOXEL_FACADE_PAVING_ASSEMBLY_REPORT JSON.
## Optional success-only raw archive: VOXEL_FACADE_PAVING_ASSEMBLY_EXPORT (.bin).


func _run() -> void:
	var path := OS.get_environment("VOXEL_FACADE_PAVING_ASSEMBLY_REPORT").strip_edges().simplify_path()
	if not path.is_absolute_path() or path.get_extension() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var report: Dictionary = _inspect_assembly()
	if not OS.get_environment("VOXEL_FACADE_PAVING_ASSEMBLY_EXPORT").strip_edges().is_empty() and not report.has("candidateArtifact"):
		report["candidateArtifact"] = {"completed": false, "reason": "source_contract_failed_before_export"}
		report["passed"] = false
	report["elapsedMsec"] = Time.get_ticks_msec() - started
	report["evidenceLevel"] = "actual_frozen_source_complete_bay_and_paving_joint_service_contract"
	report["limitations"] = "One diagnosis-derived proposal, not a planner or placement approval. Real Frame checks ALL source parts, ordinary door visuals, room/access/furniture reservations and represented cut finish against ALL new members. Physical reports are freshly validated support closure + selected panels + emitted frame only, NOT a whole-world gate. No renderer/GPU, gameplay, navigation, composer integration or artifact publication acceptance. Rejections remain failures, not skipped positives."
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "\t"))
	file.flush()
	var written: bool = file.get_error() == OK
	file.close()
	quit(0 if written and report.get("passed", false) else 2)


func _inspect_assembly() -> Dictionary:
	var source: Dictionary = _bound_read("VOXEL_PAVING_ARTIFACT_SOURCE", WHOLE08_SHA, 33554432)
	if not source.completed: return source
	var diagnosis: Dictionary = _bound_read("VOXEL_PAVING_ARTIFACT_DIAGNOSIS", DIAG02_SHA, 2097152)
	if not diagnosis.completed: return diagnosis
	var raw: Variant = bytes_to_var(source.bytes)
	var decoded: Variant = JSON.parse_string(diagnosis.bytes.get_string_from_utf8())
	if not raw is Dictionary or not decoded is Dictionary: return {"reason": "invalid_input_encoding"}
	var archive: Dictionary = raw
	var diag: Dictionary = decoded
	if archive.get("schemaVersion") != 1 or archive.get("provenance") != "successful_full_facade_recipe_contract" or not archive.get("mainShardPassed", false): return {"reason": "invalid_source_provenance"}
	if not archive.get("beforeSnapshot") is Dictionary or not archive.get("furnitureSnapshot") is Dictionary or not archive.get("protectedReservations") is Array: return {"reason": "invalid_source_schema"}
	if not archive.beforeSnapshot.get("parts") is Array or not archive.beforeSnapshot.get("rooms") is Array or not archive.furnitureSnapshot.get("parts") is Array: return {"reason": "invalid_source_collections"}
	if archive.beforeSnapshot.parts.size() > Bearing.MAX_PARTS or archive.beforeSnapshot.rooms.size() > Bearing.MAX_RESERVATIONS or archive.furnitureSnapshot.parts.size() + archive.protectedReservations.size() > Bearing.MAX_RESERVATIONS: return {"reason": "source_collection_limit"}
	if _archive_digest(archive.beforeSnapshot) != archive.get("sourceDigest") or _archive_digest({"furnitureParts": archive.furnitureSnapshot.parts, "reservedVolumes": archive.protectedReservations}) != archive.get("policyDigest"): return {"reason": "archive_digest_mismatch"}
	if not diag.get("diagnosticCompleted", false) or not diag.get("sourceUnchanged", false) or diag.get("artifactSha256") != source.sha256 or not diag.get("rows") is Array or diag.rows.size() > 512: return {"reason": "diagnosis_pairing_mismatch"}
	var b = FacadeSource.copy_blueprint(archive.beforeSnapshot)
	if _archive_digest(b.snapshot()) != archive.sourceDigest: return {"reason": "source_roundtrip_mismatch"}
	var proposal: Dictionary = _diagnosed_proposal(b, diag)
	if not proposal.get("completed", false): return proposal
	var setup: Dictionary = _assembly_setup(b, diag, proposal, archive)
	if not setup.get("ready", false): return setup
	var before: Dictionary = b.snapshot()
	var furniture_bytes := var_to_bytes(archive.furnitureSnapshot)
	var reservation_bytes := var_to_bytes(archive.protectedReservations)
	var policy_bytes := var_to_bytes(setup.policy)
	var aliases := _part_map(b)
	var scoped_ids: Array = setup.closure.partIds.duplicate()
	scoped_ids.append_array(diag.memberIds)
	var before_physical: Dictionary = _scoped_physical(before, scoped_ids)
	var started := Time.get_ticks_msec()
	var result: Dictionary = Bearing.add_frame_on_support(b, diag.memberIds, setup.policy, setup.supportId, setup.upstreamIds)
	var frame_msec := Time.get_ticks_msec() - started
	var after: Dictionary = b.snapshot()
	var ready: bool = result.get("ready", false)
	var preservation_diff: Dictionary = {}
	var preservation: Dictionary = _assembly_preservation(before, after, result, setup.finishId, diag.memberIds, preservation_diff)
	var after_map := _part_map(b)
	preservation["originalAliasesRetained"] = aliases.keys().all(func(id): return after_map.get(id) == aliases[id])
	preservation["furnitureExact"] = var_to_bytes(archive.furnitureSnapshot) == furniture_bytes
	preservation["furnitureCount152"] = archive.furnitureSnapshot.parts.size() == 152
	preservation["protectedReservationsExact"] = var_to_bytes(archive.protectedReservations) == reservation_bytes
	preservation["policyExact"] = var_to_bytes(setup.policy) == policy_bytes
	preservation["sourceFileExact"] = FileAccess.get_sha256(source.path) == source.sha256
	preservation["diagnosisFileExact"] = FileAccess.get_sha256(diagnosis.path) == diagnosis.sha256
	if ready: scoped_ids.append_array(result.partIds)
	var after_physical: Dictionary = _scoped_physical(after, scoped_ids)
	var negatives: Array = []
	for mode in ["late_source_blocker", "late_reservation", "already_jointed_no_refill", "absent_cut_policy"]:
		negatives.append(_assembly_negative(before, diag.memberIds, setup, mode))
	var physical_pass: bool = after_physical.get("completed", false) and after_physical.get("failedIds", ["missing"]).is_empty()
	var report := {"passed": ready and before_physical.get("completed", false) and physical_pass and preservation.values().all(func(value): return value == true) and negatives.all(func(row): return row.passed),
		"ready": ready, "result": result, "frameElapsedMsec": frame_msec,
		"proposal": proposal.report, "section": {"bearingWidth": setup.policy.bearingWidth, "bearingNormalCenter": setup.policy.bearingNormalCenter,
			"sillSpanBounds": setup.policy.sillSpanBounds, "postSpanOffsets": setup.policy.postSpanOffsets, "outward": setup.policy.outward,
			"clearance": setup.policy.clearance, "reservationCount": setup.policy.reservedVolumes.size()}, "supportClosure": setup.closure,
		"beforePhysical": before_physical, "afterPhysical": after_physical,
		"preservation": preservation, "preservationDiff": preservation_diff, "negativeCases": negatives,
		"sourceSha256": source.sha256, "diagnosisSha256": diagnosis.sha256,
		"beforeDigest": _value_digest(before), "afterDigest": _value_digest(after),
		"furnitureCount": archive.furnitureSnapshot.parts.size(), "furnitureDigest": _value_digest(archive.furnitureSnapshot),
		"memberIds": diag.memberIds, "partIds": result.get("partIds", []), "finishId": setup.finishId,
		"identity": {"contract": FileAccess.get_sha256(get_script().resource_path),
			"frame": FileAccess.get_sha256("res://scripts/buildings/FacadeBearingFrameBuilder.gd"),
			"assembly": FileAccess.get_sha256("res://scripts/buildings/PavingFootingAssemblyRecipe.gd"),
			"artifact": FileAccess.get_sha256("res://scripts/buildings/PavingConstructionArtifact.gd")}}
	var export_path := OS.get_environment("VOXEL_FACADE_PAVING_ASSEMBLY_EXPORT").strip_edges()
	if not export_path.is_empty():
		# These are the SAME captured values tested above, not a rerun/copy of
		# the construction recipe or a snapshot taken after physical validation.
		var exported: Dictionary = _export_assembly(export_path, report.passed, before, after, archive, setup, result, proposal, source, diagnosis)
		report["candidateArtifact"] = exported
		if not exported.get("completed", false): report.passed = false
	return report


func _export_assembly(requested_path: String, passed: bool, before: Dictionary, after: Dictionary, source_archive: Dictionary, setup: Dictionary, result: Dictionary, proposal: Dictionary, source: Dictionary, diagnosis: Dictionary) -> Dictionary:
	if not passed: return {"completed": false, "reason": "source_contract_failed_no_export"}
	var path := requested_path.simplify_path()
	if not path.is_absolute_path() or path.get_extension().to_lower() != "bin" or FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		return {"completed": false, "reason": "export_requires_new_absolute_bin_in_existing_directory", "path": path}
	var identities: Dictionary = {}
	for script_path in [get_script().resource_path,
		"res://scripts/testing/buildings/PavingConstructionArtifactContract.gd",
		"res://scripts/buildings/FacadeBearingFrameBuilder.gd",
		"res://scripts/buildings/FacadeOpeningBearingRecipe.gd",
		"res://scripts/buildings/PavingFootingAssemblyRecipe.gd",
		"res://scripts/buildings/PavingFootingCutRecipe.gd",
		"res://scripts/buildings/PavingConstructionArtifact.gd",
		"res://scripts/buildings/ConvexFootingAperture.gd",
		"res://scripts/buildings/PavingFragmentMesh.gd",
		"res://scripts/buildings/SettledCobbleGeometry.gd"]:
		var sha: String = FileAccess.get_sha256(script_path)
		if sha.length() != 64: return {"completed": false, "reason": "export_identity_unreadable", "script": script_path}
		identities[script_path] = sha
	var fixture := {"sourceFixture": source_archive.get("fixture", {}).duplicate(true),
		"proposal": proposal.report.duplicate(true), "scope": "one_complete_diagnosis_derived_facade_bay"}
	var exported := {"schemaVersion": 1, "provenance": "successful_complete_facade_paving_assembly_contract",
		"beforeSnapshot": before, "afterSnapshot": after,
		"furnitureSnapshot": source_archive.furnitureSnapshot, "protectedReservations": source_archive.protectedReservations,
		"memberIds": result.memberIds.duplicate(), "partIds": result.partIds.duplicate(),
		"pavingFinishPartIds": result.pavingFinishPartIds.duplicate(), "fixture": fixture,
		"policy": setup.policy.duplicate(true), "sourceDigest": _value_digest(before), "afterDigest": _value_digest(after),
		"policyDigest": _value_digest(setup.policy), "fixtureDigest": _value_digest(fixture),
		"furnitureDigest": _value_digest(source_archive.furnitureSnapshot), "reservationDigest": _value_digest(source_archive.protectedReservations),
		"sourceSha256": source.sha256, "diagnosisSha256": diagnosis.sha256, "contractIdentity": identities,
		"digestEncoding": "sha256(var_to_bytes(value)); raw bytes, NOT hex-string hashing",
		"sourceContractPassed": true, "publicationAcceptance": false}
	var payload: PackedByteArray = var_to_bytes(exported)
	if payload.is_empty() or payload.size() > 33554432: return {"completed": false, "reason": "export_size_limit"}
	# Objects are never serialized/deserialized. Verify the exact raw encoding
	# survives the same safe reader the downstream publisher will use.
	var decoded: Variant = bytes_to_var(payload)
	if not decoded is Dictionary or var_to_bytes(decoded) != payload:
		return {"completed": false, "reason": "export_raw_roundtrip_mismatch"}
	if FileAccess.get_sha256(source.path) != source.sha256 or FileAccess.get_sha256(diagnosis.path) != diagnosis.sha256:
		return {"completed": false, "reason": "export_input_changed"}
	# Recheck immediately before WRITE; never intentionally replace an artifact.
	if FileAccess.file_exists(path): return {"completed": false, "reason": "export_target_exists", "path": path}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return {"completed": false, "reason": "export_open_failed", "path": path}
	file.store_buffer(payload)
	file.flush()
	var written: bool = file.get_error() == OK and file.get_position() == payload.size()
	file.close()
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(payload)
	var expected_sha: String = hashing.finish().hex_encode()
	var actual_sha: String = FileAccess.get_sha256(path)
	if not written or actual_sha != expected_sha:
		return {"completed": false, "reason": "export_write_or_digest_failed", "path": path, "partialFileMayExist": true}
	return {"completed": true, "path": path, "sha256": actual_sha, "byteCount": payload.size(),
		"schemaVersion": 1, "provenance": exported.provenance, "sourceDigest": exported.sourceDigest,
		"afterDigest": exported.afterDigest, "policyDigest": exported.policyDigest,
		"sourceSha256": source.sha256, "contractIdentity": identities}


func _assembly_setup(b, diag: Dictionary, proposal: Dictionary, archive: Dictionary) -> Dictionary:
	var row: Dictionary = diag.rows[proposal.report.diagnosisRow]
	var interval: Dictionary = _reported_vector2(row.insetResult.interval)
	var offsets: Dictionary = _reported_vector2(proposal.report.postOffsets)
	if not interval.completed or not offsets.completed: return {"ready": false, "reason": "invalid_reported_section"}
	var support_id: String = proposal.report.supportId
	var closure: Dictionary = FacadeSource._discover_support_closure(b, support_id, diag.memberIds)
	if not closure.get("ready", false): return {"ready": false, "reason": "actual_support_closure_rejected", "result": closure}
	# Producer-owned room/door geometry, as in the inherited proposal, supplies
	# outward. Do not parse or author a world coordinate/direction exception.
	var owner_doors: Array = b.parts.filter(func(part): return part.kind == "door" and part.id.begins_with(String(diag.ownerPrefix) + "_") and part.recipe.has("roomId"))
	var room_rows: Array = b.rooms.filter(func(room): return room.get("id") == owner_doors[0].recipe.roomId)
	var panel = _part_map(b)[diag.memberIds[0]]
	var outward := Vector3(signf(panel.position.x - room_rows[0].bounds.get_center().x), 0, 0)
	var policy := {"outward": outward, "foundationPartIds": [support_id],
		"reservedVolumes": archive.protectedReservations.duplicate(true), "furnitureParts": archive.furnitureSnapshot.parts.duplicate(true),
		"clearance": FacadeSource.CLEARANCE, "bearingWidth": Bearing.POST_WIDTH,
		"bearingNormalCenter": row.normalCenter, "sillSpanBounds": interval.value,
		"postSpanOffsets": offsets.value, "pavingFinishPartIds": [proposal.part.id]}
	var group_bottom: float = Bearing._bounds(panel).position.y
	# This is a synthetic late obstruction inside the actual proposed sill,
	# derived from its section; it never changes any retained source furniture.
	var blocker := AABB(Vector3(row.normalCenter - Bearing.POST_WIDTH * 0.25,
		group_bottom - Bearing.SILL_HEIGHT * 0.75, (interval.value.x + interval.value.y) * 0.5 - Bearing.POST_WIDTH * 0.25),
		Vector3(Bearing.POST_WIDTH * 0.5, Bearing.SILL_HEIGHT * 0.5, Bearing.POST_WIDTH * 0.5))
	return {"ready": true, "policy": policy, "supportId": support_id, "finishId": proposal.part.id,
		"upstreamIds": closure.partIds.filter(func(id): return id != support_id), "closure": closure, "blocker": blocker}


func _assembly_negative(snapshot: Dictionary, members: Array, setup: Dictionary, mode: String) -> Dictionary:
	var b = FacadeSource.copy_blueprint(snapshot)
	var policy: Dictionary = setup.policy.duplicate(true)
	var expected := ""
	var blocker_id := "contract_synthetic_sill_blocker"
	if mode == "late_source_blocker":
		var blocker: AABB = setup.blocker
		var part = b.add_part({"id": blocker_id, "kind": "beam", "material": "timber_beam", "position": blocker.get_center(), "size": blocker.size, "collision": false})
		# First source obstacle ensures this deliberate witness is adjudicated
		# before incidental pre-existing obstacles, without deleting any source.
		b.parts.erase(part)
		b.parts.push_front(part)
		expected = "existing_source_geometry_blocked"
	elif mode == "late_reservation":
		policy.reservedVolumes.push_front(setup.blocker)
		expected = "reserved_interior_access_or_furniture_blocked"
	elif mode == "already_jointed_no_refill":
		# Existing declaration is intentionally never regenerated or replaced.
		_part_map(b)[setup.finishId].recipe["pavingFootingJoints"] = {"footPartIds": ["preexisting_contract_joint"], "nominalJoint": FacadeSource.CLEARANCE,
			"geometryDigest": "0".repeat(64), "constructionDigest": "0".repeat(64)}
		expected = "invalid_prior_foot"
	else:
		policy.erase("pavingFinishPartIds")
		expected = "existing_source_geometry_blocked"
	var before := var_to_bytes(b.snapshot())
	var policy_before := var_to_bytes(policy)
	var aliases := _part_map(b)
	var started := Time.get_ticks_msec()
	var result: Dictionary = Bearing.add_frame_on_support(b, members, policy, setup.supportId, setup.upstreamIds)
	var after_map := _part_map(b)
	var exact: bool = var_to_bytes(b.snapshot()) == before and var_to_bytes(policy) == policy_before and aliases.keys().all(func(id): return after_map.get(id) == aliases[id])
	var witnessed: bool = result.get("reason") == expected
	if mode == "late_source_blocker": witnessed = witnessed and result.get("otherId") == blocker_id
	if mode == "late_reservation": witnessed = witnessed and result.get("reservation") == setup.blocker
	if mode == "absent_cut_policy": witnessed = witnessed and result.get("otherId") == setup.finishId
	return {"label": mode, "passed": not result.get("ready", false) and exact and witnessed,
		"atomicSourcePolicyAndAliasesExact": exact, "expectedReason": expected, "expectedStageWitness": witnessed,
		"elapsedMsec": Time.get_ticks_msec() - started, "result": result,
		"scope": "synthetic rejection on the complete actual source; late-stage controls fail if an earlier unrelated rejection masks the intended witness"}


func _assembly_preservation(before: Dictionary, after: Dictionary, result: Dictionary, finish_id: String, members: Array, differences: Dictionary) -> Dictionary:
	if not result.get("ready", false): return {"atomicFailureExact": var_to_bytes(before) == var_to_bytes(after)}
	var expected: Dictionary = before.duplicate(true)
	var actual: Dictionary = {}
	for record in after.parts: actual[record.id] = record
	var added: Array = result.get("partIds", [])
	var checks := {"newIdsUniqueAndExactlySeven": added.size() == 7 and actual.size() == before.parts.size() + 7,
		"completeTwoPostBay": result.get("mode") == "inset_end_two_post" and result.get("postIds", []).size() == 2,
		"memberSeatDeclarationsExact": true, "onePavingJointOnly": result.get("pavingFinishPartIds") == [finish_id], "allOtherFieldsExact": false}
	var unique: Array = []
	for id in added:
		if unique.has(id) or not actual.has(id) or before.parts.any(func(record): return record.id == id): checks.newIdsUniqueAndExactlySeven = false
		unique.append(id)
	var feet: Array = added.filter(func(id): return actual.has(id) and actual[id].material == "stone_foundation")
	checks["exactlyTwoFeet"] = feet.size() == 2
	for record in expected.parts:
		if not actual.has(record.id): return {"missingOriginal": false}
		if members.has(record.id):
			var facts: Array = actual[record.id].recipe.get("physicalRequiredSeatFacts", [])
			if facts.size() != 1 or facts[0].get("seatId") != result.sillId: checks.memberSeatDeclarationsExact = false
			for key in ["physicalRoot", "physicalSupportPartIds", "physicalSupportCoverage", "physicalAnchorPartIds", "physicalIntentResolution"]: record.recipe.erase(key)
			record.physicalIntent = "structural_mass"
			record.recipe["physicalIntent"] = "structural_mass"
			record.recipe["physicalRequiredSeatFacts"] = facts.duplicate(true)
			record.recipe["physicalRequiredSeatPartIds"] = [result.sillId]
		if record.id == finish_id:
			var joint: Variant = actual[record.id].recipe.get("pavingFootingJoints")
			if not joint is Dictionary:
				checks.onePavingJointOnly = false
				continue
			var keys: Array = joint.keys()
			keys.sort()
			var digest_pattern := RegEx.new()
			digest_pattern.compile("^[0-9a-f]{64}$")
			checks.onePavingJointOnly = checks.onePavingJointOnly and keys == ["constructionDigest", "footPartIds", "geometryDigest", "nominalJoint"] and joint.get("footPartIds") == feet and joint.get("nominalJoint") == FacadeSource.CLEARANCE
			for key in ["geometryDigest", "constructionDigest"]:
				if not joint.get(key) is String or digest_pattern.search(String(joint.get(key, ""))) == null: checks.onePavingJointOnly = false
			# Authoritative artifact digests are opaque here; represented geometry
			# proof belongs to Assembly. Authorize ONLY this exact joint key; all
			# original paving recipe fields/geometry/collision must remain exact.
			record.recipe["pavingFootingJoints"] = joint.duplicate(true)
	for id in added:
		if actual.has(id): expected.parts.append(actual[id])
	checks.allOtherFieldsExact = var_to_bytes(expected) == var_to_bytes(after)
	# Diagnostic only. Keep the original byte-exact assertion and expected
	# construction untouched; key-order/typed-container differences stay RED.
	differences.merge({"expectedDigest": _value_digest(expected), "actualDigest": _value_digest(after),
		"rows": [], "visited": 0, "truncated": false, "maxRows": 16, "maxVisited": 65536,
		"scope": "First differing paths in expected traversal order, including dictionary insertion order and represented bytes; no normalization or assertion relaxation."})
	if not checks.allOtherFieldsExact: _preservation_diff_walk(expected, after, "$", differences, 0)
	return checks


func _preservation_diff_walk(expected: Variant, actual: Variant, path: String, state: Dictionary, depth: int) -> void:
	if state.rows.size() >= 16 or state.visited >= 65536 or depth > 32:
		state.truncated = true
		return
	state.visited += 1
	var expected_bytes := var_to_bytes(expected)
	var actual_bytes := var_to_bytes(actual)
	if expected_bytes == actual_bytes: return
	if typeof(expected) != typeof(actual):
		_diff_row(state, path, "variant_type", expected, actual)
		return
	if expected is Dictionary:
		var expected_keys: Array = expected.keys()
		var actual_keys: Array = actual.keys()
		var same_keys: bool = expected_keys.size() == actual_keys.size() and expected_keys.all(func(key): return actual.has(key))
		if same_keys and var_to_bytes(expected_keys) != var_to_bytes(actual_keys):
			_diff_row(state, path + ".<dictionary_key_order>", "dictionary_key_order", expected_keys, actual_keys)
		for key in expected_keys:
			if state.rows.size() >= 16 or state.visited >= 65536:
				state.truncated = true
				return
			var child_path := path + "." + String(key)
			if not actual.has(key):
				_diff_row(state, child_path, "missing_actual_key", expected[key], null)
			else:
				_preservation_diff_walk(expected[key], actual[key], child_path, state, depth + 1)
		for key in actual_keys:
			if not expected.has(key): _diff_row(state, path + "." + String(key), "unexpected_actual_key", null, actual[key])
		return
	if expected is Array:
		if expected.size() != actual.size(): _diff_row(state, path + ".<length>", "array_length", expected.size(), actual.size())
		if expected.is_typed() != actual.is_typed() or expected.get_typed_builtin() != actual.get_typed_builtin() or expected.get_typed_class_name() != actual.get_typed_class_name():
			_diff_row(state, path + ".<array_type>", "array_type", [expected.is_typed(), expected.get_typed_builtin(), expected.get_typed_class_name()], [actual.is_typed(), actual.get_typed_builtin(), actual.get_typed_class_name()])
		for index in range(mini(expected.size(), actual.size())):
			if state.rows.size() >= 16 or state.visited >= 65536:
				state.truncated = true
				return
			var child_path := path + "[%d]" % index
			if expected[index] is Dictionary and expected[index].get("id") is String: child_path += "{id=" + String(expected[index].id) + "}"
			_preservation_diff_walk(expected[index], actual[index], child_path, state, depth + 1)
		return
	_diff_row(state, path, "represented_value_bytes", expected, actual)


func _diff_row(state: Dictionary, path: String, kind: String, expected: Variant, actual: Variant) -> void:
	if state.rows.size() >= 16:
		state.truncated = true
		return
	state.rows.append({"path": path, "kind": kind, "expected": _diff_value(expected), "actual": _diff_value(actual)})


func _diff_value(value: Variant) -> Dictionary:
	var bytes := var_to_bytes(value)
	var preview := str(value)
	return {"variantType": type_string(typeof(value)), "preview": preview.left(512), "previewTruncated": preview.length() > 512,
		"encodedBytes": bytes.size(), "sha256": _value_digest(value), "first64BytesHex": bytes.slice(0, mini(64, bytes.size())).hex_encode()}


func _scoped_physical(snapshot: Dictionary, ids: Array) -> Dictionary:
	var scoped: Dictionary = snapshot.duplicate(true)
	scoped.parts = scoped.parts.filter(func(record): return ids.has(record.id))
	if scoped.parts.size() != ids.size(): return {"completed": false, "reason": "scoped_member_count_mismatch"}
	var b = FacadeSource.copy_blueprint(scoped)
	FacadeSource.clear_caches(b)
	var work: Dictionary = FacadeSource.validation_grid_work(b)
	if not work.ready: return {"completed": false, "reason": "scoped_spatial_work_limit", "work": work}
	var physical: Dictionary = b.validate_physical_integrity()
	return {"completed": true, "partIds": ids, "failedIds": FacadeSource.failed_ids(physical), "physical": physical,
		"scope": "fresh local support closure + selected panels + emitted complete frame; other source parts excluded ONLY from this physical report, NEVER from Frame obstruction checks"}


func _part_map(b) -> Dictionary:
	var result: Dictionary = {}
	for part in b.parts: result[part.id] = part
	return result
