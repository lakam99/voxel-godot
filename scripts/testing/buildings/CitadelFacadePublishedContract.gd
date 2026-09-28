extends "res://scripts/testing/buildings/CitadelChimneyPublishedContract.gd"

## CPU publication diagnostic only. Reuses the verified extraction, parity and
## finite-envelope helpers; does not change publishers, recipes or validation.
## Input must be a success-only full facade-contract artifact, with its SHA
## explicitly supplied by the caller. Every new part is checked against every
## other published building/furnishing payload, without source-AABB culling.
const FacadeRecipe = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const MAX_ARTIFACT_BYTES := 33554432
const MAX_ADDED_PARTS := 512

func _run() -> void:
	_started_msec = Time.get_ticks_msec()
	_next_progress_msec = _started_msec + 10000
	var path := OS.get_environment("VOXEL_FACADE_PUBLISHED_REPORT")
	var input := OS.get_environment("VOXEL_FACADE_CANDIDATE")
	var expected_sha := OS.get_environment("VOXEL_FACADE_CANDIDATE_SHA256")
	if not path.is_absolute_path() or path.get_extension() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var controls := _collector_controls()
	var archive_controls := _archive_shape_controls()
	if not controls.passed or not archive_controls.passed or OS.get_environment("VOXEL_FACADE_PUBLISH_COLLECTOR_ONLY") == "1":
		var passed: bool = controls.passed and archive_controls.passed
		_write_facade_report(path, {"passed": passed, "evidenceLevel": "synthetic_collector_and_archive_shape_controls_only", "collectorControls": controls, "archiveShapeControls": archive_controls}, 0 if passed else 2)
		return
	if not input.is_absolute_path() or expected_sha.length() != 64 or FileAccess.get_sha256(input) != expected_sha:
		push_error("Require fresh report and SHA-bound successful facade candidate")
		quit(2)
		return
	var file := FileAccess.open(input, FileAccess.READ)
	if file == null or file.get_length() > MAX_ARTIFACT_BYTES:
		quit(2)
		return
	# Successful recipe export is raw var_to_bytes, not store_var's length-
	# prefixed stream. Never enable object deserialization for this artifact.
	var length := file.get_length()
	var encoded := file.get_buffer(length)
	var read_complete: bool = length > 0 and encoded.size() == length and file.get_error() == OK
	file.close()
	if not read_complete:
		quit(2)
		return
	var archive: Variant = bytes_to_var(encoded)
	if not _valid_facade_archive(archive):
		push_error("Invalid facade candidate archive")
		quit(2)
		return
	_stop_reason = ""
	for key in _counts: _counts[key] = 0
	for key in _work: _work[key] = 0
	_materials.clear()
	var before = FacadeRecipe.copy_blueprint(archive.beforeSnapshot)
	var candidate = FacadeRecipe.copy_blueprint(archive.afterSnapshot)
	var old_publisher = _configured_publisher(before)
	var new_publisher = _configured_publisher(candidate)
	var colliders := ColliderPublisher.new()
	var payloads: Dictionary = {}
	var originals: Array = []
	var furnishing_comparisons: Array = []
	var all_exact := true
	var old_parts: Dictionary = {}
	var parts: Dictionary = {}
	for part in before.parts: old_parts[part.id] = part
	for part in candidate.parts:
		parts[part.id] = part
		if not _within_budget(): break
		var visual := _extract_overlap_payload(new_publisher, candidate, part, "candidate")
		var collision := _collision_payload(colliders, part)
		if not _valid_payload(visual) or not _valid_payload(collision):
			_stop_reason = "invalid_building_payload"
			break
		payloads[part.id] = {"visual": visual, "collision": collision}
		if old_parts.has(part.id):
			var old = old_parts[part.id]
			var old_payload := {"visual": _extract_overlap_payload(old_publisher, before, old, "original"), "collision": _collision_payload(colliders, old)}
			var comparison := _compare_channels(old_payload, payloads[part.id])
			comparison["partId"] = part.id
			originals.append(comparison)
			all_exact = all_exact and comparison.exact
	var furnishing = FurnishingPlanScript.new(archive.furnitureSnapshot.id, int(archive.furnitureSnapshot.seed), archive.furnitureSnapshot.sourceBlueprintId)
	for record in archive.furnitureSnapshot.parts: furnishing.add_part(record)
	var furniture_publisher := Furnisher.new()
	var old_furniture_publisher := Furnisher.new()
	for part in furnishing.parts:
		if not _within_budget(): break
		var published := _furnishing_payload(furniture_publisher, part)
		var previous := _furnishing_payload(old_furniture_publisher, part)
		payloads["furnishing:" + part.id] = published
		var comparison := _compare_channels(previous, published)
		comparison["partId"] = part.id
		comparison["generatedNodeNameEvidence"] = {"original": previous.generatedNodeNames, "candidate": published.generatedNodeNames}
		furnishing_comparisons.append(comparison)
		all_exact = all_exact and comparison.exact
	var contacts: Array = []
	var joints: Array = []
	var relevant: Dictionary = {}
	var pairs := 0
	var expected_joints := 0
	for id in archive.partIds + archive.memberIds:
		if not parts.has(id):
			_stop_reason = "missing_selected_part"
			break
		var part = parts[id]
		for declaration in _joint_declarations(part.recipe):
			var other_id: String = declaration.otherId
			expected_joints += 2
			if not payloads.has(id) or not payloads.has(other_id):
				_stop_reason = "missing_declared_joint_payload"
				break
			relevant[id] = true
			relevant[other_id] = true
			for channel in ["visual", "collision"]:
				if not _within_budget(): break
				joints.append({"partId": id, "otherId": other_id, "kind": declaration.kind, "sourceFacts": declaration.facts, "channel": channel,
					"measurement": _joint_measurement(payloads[id][channel], payloads[other_id][channel], false),
					"interpretation": "Attachment sockets require their transformed source facts; vertical separation is not an attachment acceptance test." if declaration.kind == "anchor" else "Raw whole-payload measurements; finite source seat facts remain independently required."})
	for id in archive.partIds:
		if not payloads.has(id): break
		relevant[id] = true
		for other_id in payloads:
			if other_id == id: continue
			for channel in ["visual", "collision"]:
				if not _within_budget(): break
				var measurement: Dictionary = _classify_validated_overlap(payloads[id][channel], payloads[other_id][channel])
				pairs += 1
				_counts.partPairs += 1
				if measurement.status in ["certified_separated", "no_collision"]: continue
				relevant[other_id] = true
				# Relationship is context, never an exemption or success authority.
				var required: bool = _joint_declarations(parts[id].recipe).any(func(row): return row.otherId == other_id) or (parts.has(other_id) and _joint_declarations(parts[other_id].recipe).any(func(row): return row.otherId == id))
				contacts.append({"partId": id, "otherId": other_id, "channel": channel, "declaredJointRelationship": required, "measurement": measurement})
	var inventory: Array = []
	var relevant_payloads: Dictionary = {}
	for id in payloads:
		if not _within_budget(): break
		var row := {"partId": id}
		for channel in ["visual", "collision"]:
			var payload: Dictionary = payloads[id][channel]
			row[channel] = {"status": payload.status, "primitiveCount": payload.primitives.size(), "bounds": payload.bounds, "digest": _stable_digest(payload)}
			if channel == "collision": row[channel]["shapes"] = payload.get("shapes", [])
		inventory.append(row)
		if relevant.has(id): relevant_payloads[id] = payloads[id]
	var input_unchanged: bool = FileAccess.get_sha256(input) == expected_sha
	var complete: bool = input_unchanged and _within_budget() and all_exact and originals.size() == before.parts.size() and furnishing_comparisons.size() == furnishing.parts.size() and payloads.size() == candidate.parts.size() + furnishing.parts.size() and inventory.size() == payloads.size() and pairs == archive.partIds.size() * (payloads.size() - 1) * 2 and joints.size() == expected_joints and expected_joints > 0
	var report := {"passed": false, "diagnosticCompleted": complete, "status": "contact_review_required" if complete else "incomplete_or_changed_payloads:" + _stop_reason,
		"inputPath": input, "inputSha256": expected_sha, "immutableInputUnchanged": input_unchanged, "fixture": archive.fixture,
		"collectorControls": controls, "archiveShapeControls": archive_controls, "allOriginalPayloadsExact": all_exact, "originalComparisons": originals, "furnishingComparisons": furnishing_comparisons,
		"addedPartIds": archive.partIds, "memberIds": archive.memberIds, "payloadCount": payloads.size(), "pairCount": pairs, "expectedJointCount": expected_joints,
		"jointMatrix": joints, "contacts": contacts, "payloadInventory": inventory, "relevantPayloads": relevant_payloads, "counts": _counts, "extractionWork": _work,
		"elapsedMsec": Time.get_ticks_msec() - _started_msec, "evidenceLevel": "actual_CPU_publication_diagnostic_not_live_acceptance",
		"doesNotProve": "No automatic contact exemptions, GPU appearance, player access, physics movement, engineering capacity or gate-zero acceptance. Nonbox envelope contacts require review. Original furniture parity alone does not prove new supports leave access clear."}
	_write_facade_report(path, report, 1 if complete else 2)

func _valid_facade_archive(value: Variant) -> bool:
	if not value is Dictionary or value.get("schemaVersion") != 1 or value.get("provenance") != "successful_full_facade_recipe_contract": return false
	for key in ["beforeSnapshot", "afterSnapshot", "furnitureSnapshot", "fixture"]:
		if not value.get(key) is Dictionary: return false
	for key in ["partIds", "memberIds", "protectedReservations"]:
		if not value.get(key) is Array: return false
	if value.partIds.is_empty() or value.partIds.size() > MAX_ADDED_PARTS or value.memberIds.is_empty() or value.memberIds.size() > MAX_ADDED_PARTS: return false
	if not value.beforeSnapshot.get("parts") is Array or not value.afterSnapshot.get("parts") is Array or not value.furnitureSnapshot.get("parts") is Array: return false
	if value.beforeSnapshot.parts.is_empty() or value.afterSnapshot.parts.size() > MAX_SOURCE_PARTS or value.afterSnapshot.parts.size() != value.beforeSnapshot.parts.size() + value.partIds.size() or value.furnitureSnapshot.parts.is_empty() or value.furnitureSnapshot.parts.size() > MAX_SOURCE_PARTS: return false
	var old_ids: Dictionary = {}
	var current_ids: Dictionary = {}
	for record in value.beforeSnapshot.parts:
		if not record is Dictionary or not record.get("id") is String or record.id.is_empty() or old_ids.has(record.id): return false
		old_ids[record.id] = true
	for record in value.afterSnapshot.parts:
		if not record is Dictionary or not record.get("id") is String or record.id.is_empty() or current_ids.has(record.id): return false
		current_ids[record.id] = true
	var selected: Dictionary = {}
	for id in value.partIds + value.memberIds:
		if not id is String or not current_ids.has(id) or selected.has(id): return false
		selected[id] = true
	for id in old_ids:
		if not current_ids.has(id): return false
	for id in value.partIds:
		if old_ids.has(id): return false
	for id in value.memberIds:
		if not old_ids.has(id): return false
	return true

func _write_facade_report(path: String, report: Dictionary, code: int) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_overlap_json(report), "\t"))
	file.close()
	quit(code)

func _archive_shape_controls() -> Dictionary:
	# Deliberately skeletal records: this proves envelope/ID checks only, not
	# valid geometry or successful source generation. Full artifacts come from
	# the separate passed recipe contract; publication validates every payload.
	var base := {"schemaVersion": 1, "provenance": "successful_full_facade_recipe_contract",
		"beforeSnapshot": {"parts": [{"id": "original"}]}, "afterSnapshot": {"parts": [{"id": "original"}, {"id": "added"}]},
		"furnitureSnapshot": {"parts": [{"id": "furniture"}]}, "fixture": {}, "protectedReservations": [], "partIds": ["added"], "memberIds": ["original"]}
	var checks := {"valid_shape_only": _valid_facade_archive(base), "null_rejected": not _valid_facade_archive(null)}
	var bad: Dictionary = base.duplicate(true)
	bad.partIds = ["added", "added"]
	checks["duplicate_added_ids_rejected"] = not _valid_facade_archive(bad)
	bad = base.duplicate(true)
	bad.memberIds = ["added"]
	checks["added_member_overlap_rejected"] = not _valid_facade_archive(bad)
	bad = base.duplicate(true)
	bad.afterSnapshot.parts[0].id = "replacement"
	checks["missing_original_rejected"] = not _valid_facade_archive(bad)
	bad = base.duplicate(true)
	bad.partIds = ["original"]
	checks["original_as_addition_rejected"] = not _valid_facade_archive(bad)
	bad = base.duplicate(true)
	bad.furnitureSnapshot.parts = []
	checks["empty_furniture_rejected"] = not _valid_facade_archive(bad)
	bad = base.duplicate(true)
	bad.provenance = "failed_contract"
	checks["wrong_provenance_rejected"] = not _valid_facade_archive(bad)
	bad = base.duplicate(true)
	bad.afterSnapshot.parts[1].id = "original"
	checks["duplicate_source_ids_rejected"] = not _valid_facade_archive(bad)
	var declarations := _joint_declarations({"physicalRequiredSeatPartIds": ["seat"], "physicalRequiredSeatFacts": [{"seatId": "seat", "test": 1}], "physicalRequiredAnchorPartIds": ["socket_a", "socket_b"], "physicalRequiredAnchorFacts": [{"anchorId": "socket_a", "test": 2}, {"anchorId": "socket_b", "test": 3}], "physicalRequiredSupportPartIds": ["support"]})
	checks["all_declared_joint_kinds_enumerated"] = declarations.size() == 4 and declarations.map(func(row): return row.kind) == ["seat", "anchor", "anchor", "support"] and declarations[1].facts == [{"anchorId": "socket_a", "test": 2}] and declarations[2].facts == [{"anchorId": "socket_b", "test": 3}]
	return {"passed": checks.values().all(func(value): return bool(value)), "checks": checks}

func _joint_declarations(recipe: Dictionary) -> Array:
	var rows: Array = []
	for kind in ["seat", "anchor", "support"]:
		var title: String = String(kind).capitalize()
		var facts: Array = recipe.get("physicalRequired" + title + "Facts", [])
		for id in recipe.get("physicalRequired" + title + "PartIds", []):
			rows.append({"kind": kind, "otherId": id, "facts": facts.filter(func(fact): return fact.get(kind + "Id") == id).duplicate(true)})
	return rows
