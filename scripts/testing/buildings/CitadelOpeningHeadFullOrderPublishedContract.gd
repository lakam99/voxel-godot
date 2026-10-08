extends "res://scripts/testing/buildings/CitadelOpeningHeadPublishedContract.gd"

## CPU whole-order execution, selected geometry proof. No prewarm or replay.
## Existing outer runner must retain its 100s process watchdog (80s soft limit).
const FULL_MIXED_SHA := "4a611a7fab4b45d82943b0598ee01b50b252b9f6ef7e63af181ade6e4d33d822"
const FullMaterials = preload("res://scripts/buildings/ConstructionMaterialCatalog.gd")
var _full_order_passes: Array = []

func _run() -> void:
	_started_msec = Time.get_ticks_msec()
	_next_progress_msec = _started_msec + 10000
	var path: String = OS.get_environment("VOXEL_OPENING_HEAD_FULL_ORDER_REPORT")
	if not path.is_absolute_path() or path.get_extension() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	for name: String in ["before-payloads.json", "after-payloads.json"]:
		if FileAccess.file_exists(path.get_base_dir().path_join(name)):
			quit(2)
			return
	var input: String = OS.get_environment("VOXEL_OPENING_HEAD_PUBLISHED_INPUT")
	var sha: String = OS.get_environment("VOXEL_OPENING_HEAD_PUBLISHED_INPUT_SHA256").to_lower()
	var report: Dictionary = {"passed": false, "evidenceLevel": "CPU_whole_order_selected_geometry_contract", "inputPath": input, "inputSha256": sha,
		"materialContext": "Separate full-blueprint histories; every before/candidate part executes publish_visual in its actual parts-array order. Selected payloads captured only when naturally reached; no reordered prewarm or later replay.",
		"reportByteCap": 64 * 1024 * 1024, "outerWatchdogSecondsRequired": 100,
		"limitations": "Selected geometry is the validated closure of all bodies/endblocks, trimmed panels, original gables and adopted masonry peers. Other visual paths execute but their geometry is discarded. No assembled full scene, GPU/readback, headed visual, neighbour/furniture/swept-door, live movement, normal integration or whole physical acceptance. Historical deep-header archives remain source-driven measurements, never a production fallback."}
	if not input.is_absolute_path() or sha.length() != 64 or sha.hex_decode().size() != 32:
		_finish_head(path, report, "invalid_required_input_pair")
		return
	# Read the whole raw archive without a selected-house metadata projection.
	var archive: Dictionary = _full_read(input, sha)
	if archive.is_empty() or not archive.get("houseProposals") is Array or archive.houseProposals.size() != 16:
		_finish_head(path, report, "invalid_all_house_archive")
		return
	var archive_digest: String = _stable_digest(archive)
	report["syntheticUnionControls"] = _head_union_controls()
	_head_checks["synthetic_controls_pass"] = report.syntheticUnionControls.values().all(func(value): return value)
	var before = HeadCopy.copy_blueprint(archive.beforeSnapshot)
	var after = HeadCopy.copy_blueprint(archive.afterSnapshot)
	var scope: Dictionary = _full_scope(before, after, archive.houseProposals)
	report["validatedClosure"] = scope
	_head_checks["exact_all_house_membership"] = scope.ready
	if not scope.ready:
		_finish_head(path, report, "invalid_full_scope")
		return
	_head_checks["archive_trim_membership_exact"] = archive.get("trimmedPanelIds") == scope.trimOrder
	if sha == FULL_MIXED_SHA:
		# Regression inventory AFTER closure validation, not a substitute for it.
		_head_checks["bound_mixed_archive_inventory"] = scope.framing.size() == 47 and scope.ends.size() == 31 and scope.common.size() == 144 and scope.selected.size() == 191 and scope.housedFactCount == 63
	var old_publisher = _configured_publisher(before)
	var new_publisher = _configured_publisher(after)
	for pair: Array in [[old_publisher, before], [new_publisher, after]]:
		# Full-order publication also reaches existing jointed paving. Honor its
		# normal source-bound preparation contract rather than bypassing guards.
		if not pair[0]._prepare_paving_publication(pair[1]):
			_finish_head(path, report, "paving_preparation_rejected")
			return
		if not pair[0].prepare_masonry_apertures(pair[1]):
			_finish_head(path, report, "masonry_preparation_rejected")
			return
		while pair[0]._masonry_preparation.state == "pending_budget" and _within_budget():
			pair[0]._masonry_preparation.advance(pair[0])
			await process_frame
		if pair[0]._masonry_preparation.state != "ready":
			_finish_head(path, report, "masonry_preparation_failed")
			return
	report["masonryPreparationMetrics"] = {"before": old_publisher._masonry_preparation.metrics.duplicate(), "after": new_publisher._masonry_preparation.metrics.duplicate()}
	var old_payloads: Dictionary = await _full_pass(old_publisher, before, scope.common, "full_order_before")
	var payloads: Dictionary = await _full_pass(new_publisher, after, scope.selected, "full_order_after")
	var old_artifact := _write_payloads(path.get_base_dir().path_join("before-payloads.json"), old_payloads)
	var new_artifact := _write_payloads(path.get_base_dir().path_join("after-payloads.json"), payloads)
	_head_checks["complete_payload_artifacts_written"] = old_artifact.ready and new_artifact.ready
	report.merge({"publicationPasses": _full_order_passes, "beforePayloadArtifact": old_artifact, "afterPayloadArtifact": new_artifact,
		"headerIds": scope.headers.keys(), "endBlockIds": scope.ends.keys(), "framingIds": scope.framing.keys(), "directPeerIds": scope.directPeers.keys(),
		"trimmedPanelIds": scope.trims.keys(), "gableIds": scope.gables.keys(), "materialCacheOrigins": _head_material_origins})
	_head_checks["all_selected_captured_once"] = _full_same_ids(old_payloads, scope.common) and _full_same_ids(payloads, scope.selected)
	if not _head_checks.all_selected_captured_once or not _stop_reason.is_empty():
		_finish_head(path, report, "incomplete_full_order_publication")
		return
	var comparisons: Array = []
	for id: String in scope.common:
		var comparison: Dictionary = _compare_channels(old_payloads[id], payloads[id])
		comparison["partId"] = id
		comparison["trimmedRecourse"] = scope.trims.has(id)
		comparisons.append(comparison)
		if not scope.trims.has(id): _head_checks["unchanged_masonry_full_payload:" + id] = comparison.exact
	report["masonryRecourseComparisons"] = comparisons
	var houses: Array = []
	for proposal: Dictionary in archive.houseProposals:
		if not _within_budget(): break
		houses.append(_full_house(before, after, proposal, scope.houseScopes[proposal.house], payloads, old_payloads))
		await process_frame
	report["houseProofs"] = houses
	_head_checks["all16_house_proofs"] = houses.size() == 16 and houses.all(func(row): return row.passed)
	var proof_count: int = 0
	for house: Dictionary in houses: proof_count += house.finiteJointProofs.size()
	report["finiteProofChannelCount"] = proof_count
	_head_checks["exact_all_housed_and_gravity_channel_coverage"] = proof_count == 2 * (scope.housedFactCount + scope.trims.size())
	_head_checks["payload_artifacts_rechecked_before_completion"] = _payload_still_bound(old_artifact) and _payload_still_bound(new_artifact)
	_head_checks["input_and_snapshots_immutable"] = _stable_digest(archive) == archive_digest and FileAccess.get_sha256(input) == sha and var_to_bytes(before.snapshot()) == var_to_bytes(archive.beforeSnapshot) and var_to_bytes(after.snapshot()) == var_to_bytes(archive.afterSnapshot)
	_finish_head(path, report, "measurement_complete")

func _full_read(path: String, sha: String) -> Dictionary:
	if FileAccess.get_sha256(path) != sha: return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null: return {}
	var length: int = file.get_length()
	if length < 1 or length > HEAD_MAX_BYTES:
		file.close()
		return {}
	var bytes: PackedByteArray = file.get_buffer(length)
	var complete: bool = bytes.size() == length and file.get_error() == OK
	file.close()
	var archive: Variant = bytes_to_var(bytes) if complete else null
	if not archive is Dictionary or var_to_bytes(archive) != bytes or FileAccess.get_sha256(path) != sha: return {}
	for key: String in ["beforeSnapshot", "afterSnapshot"]:
		if not archive.get(key) is Dictionary or not archive[key].get("parts") is Array or archive[key].parts.size() > MAX_SOURCE_PARTS: return {}
	return archive

func _full_same_ids(actual: Dictionary, expected: Dictionary) -> bool:
	return actual.size() == expected.size() and expected.keys().all(func(id): return actual.has(id))

func _write_payloads(path: String, payloads: Dictionary) -> Dictionary:
	if FileAccess.file_exists(path): return {"ready": false, "reason": "existing_payload_artifact"}
	var bytes: PackedByteArray = JSON.stringify(_overlap_json(payloads)).to_utf8_buffer()
	if bytes.size() > 64 * 1024 * 1024: return {"ready": false, "reason": "payload_artifact_limit", "bytes": bytes.size()}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return {"ready": false, "reason": "payload_artifact_open_failed"}
	file.store_buffer(bytes)
	file.flush()
	var written := file.get_error() == OK and file.get_length() == bytes.size()
	file.close()
	var hashing := HashingContext.new()
	written = written and hashing.start(HashingContext.HASH_SHA256) == OK
	if written: written = hashing.update(bytes) == OK
	var expected_sha: String = hashing.finish().hex_encode() if written else ""
	var actual_sha: String = FileAccess.get_sha256(path)
	return {"ready": written and actual_sha == expected_sha, "path": path, "bytes": bytes.size(), "sha256": actual_sha, "partCount": payloads.size()}

func _payload_still_bound(record: Dictionary) -> bool:
	if not record.get("ready", false) or not FileAccess.file_exists(record.path) or FileAccess.get_sha256(record.path) != record.sha256: return false
	var file := FileAccess.open(record.path, FileAccess.READ)
	if file == null: return false
	var exact: bool = file.get_length() == record.bytes
	file.close()
	return exact

func _full_scope(before, after, proposals: Array) -> Dictionary:
	var membership: Dictionary = HeadCopy.street_house_memberships(before)
	if not membership.ready or membership.houses.size() != 16: return _full_bad("source_house_membership")
	var old_by_id: Dictionary = _full_index(before)
	var new_by_id: Dictionary = _full_index(after)
	if old_by_id.size() != before.parts.size() or new_by_id.size() != after.parts.size(): return _full_bad("duplicate_or_invalid_source_parts")
	if not _full_declarations(before, after, old_by_id, new_by_id): return _full_bad("aperture_binding_or_opening_inputs_changed")
	var houses: Dictionary = {}
	for house: Dictionary in membership.houses: houses[house.prefix] = house.memberIds
	if proposals.map(func(p): return p.get("house") if p is Dictionary else null) != houses.keys(): return _full_bad("proposal_source_house_order")
	var visited: Dictionary = {}
	var common: Dictionary = {}
	var selected: Dictionary = {}
	var headers: Dictionary = {}
	var framing: Dictionary = {}
	var ends: Dictionary = {}
	var direct_peers: Dictionary = {}
	var trims: Dictionary = {}
	var gables: Dictionary = {}
	var house_scopes: Dictionary = {}
	var append_order: Array = []
	var trim_order: Array = []
	var housed_count: int = 0
	for proposal: Variant in proposals:
		if not proposal is Dictionary or not houses.has(proposal.get("house")) or visited.has(proposal.house) or not proposal.get("trimmedPanelIds") is Array or proposal.trimmedPanelIds.size() != 7: return _full_bad("proposal_membership")
		visited[proposal.house] = true
		var header = after.find_part(String(proposal.get("headerId", "")))
		if not _full_frame(header) or old_by_id.has(header.id) or header.id != proposal.house + "_opening_head_band_000" or selected.has(header.id): return _full_bad("invalid_new_header")
		if not _full_record_exact(header, proposal.get("header")) or not _full_facts(header, "z", 2): return _full_bad("header_record_or_facts")
		headers[header.id] = true
		framing[header.id] = true
		selected[header.id] = true
		var original_gables: Array = [proposal.house + "_upper_shell_side_-1", proposal.house + "_upper_shell_side_1"]
		var local_common: Dictionary = {}
		var local_frames: Array = [header.id]
		var local_direct: Array = []
		for id: String in original_gables:
			if not houses[proposal.house].has(id) or not _full_unchanged_wall(id, old_by_id, new_by_id): return _full_bad("original_gable_identity")
			gables[id] = true
			local_common[id] = true
		for id: Variant in proposal.trimmedPanelIds:
			if not id is String or trims.has(id) or not houses[proposal.house].has(id) or not old_by_id.has(id) or not new_by_id.has(id): return _full_bad("trim_membership")
			var marker: String = _full_aperture_owner(after, id)
			if marker.is_empty() or new_by_id[id].recipe.get("masonryApertureSource") != marker or not _full_trim_exact(old_by_id[id], new_by_id[id], header.id, marker): return _full_bad("trim_source_or_declaration_membership")
			trims[id] = true
			local_common[id] = true
			trim_order.append(id)
		var arrangement: Variant = proposal.get("connectionArrangement")
		if arrangement != null:
			if not arrangement is Dictionary or not arrangement.get("ready", false) or not arrangement.get("connections") is Array or not arrangement.get("directSeats") is Array or not _full_record_exact(header, arrangement.get("body")): return _full_bad("arrangement_schema")
			var connection_ids: Array = []
			for record: Variant in arrangement.connections:
				if not record is Dictionary or not record.get("id") is String: return _full_bad("connection_record")
				var part = after.find_part(record.id)
				if not _full_frame(part) or old_by_id.has(part.id) or selected.has(part.id) or not _full_record_exact(part, record) or not _full_facts(part, "x", 1): return _full_bad("connection_source_or_facts")
				ends[part.id] = true
				framing[part.id] = true
				selected[part.id] = true
				local_frames.append(part.id)
				connection_ids.append(part.id)
			if proposal.get("connectionIds") != connection_ids: return _full_bad("connection_append_record_order")
			var used_connections: Array = []
			for index in range(2):
				var fact: Dictionary = header.recipe.physicalRequiredSeatFacts[index]
				var seat_id: String = fact.seatId
				if connection_ids.has(seat_id):
					if seat_id != header.id + "_connection_" + str(index) or new_by_id[seat_id].recipe.physicalRequiredSeatPartIds != [original_gables[index]]: return _full_bad("endblock_gable_closure")
					used_connections.append(seat_id)
				else:
					var records: Array = arrangement.directSeats.filter(func(d): return d is Dictionary and d.get("fact") is Dictionary and d.fact.get("seatId") == seat_id)
					var owners: Array = houses.keys().filter(func(key): return houses[key].has(seat_id))
					if records.size() != 1 or owners.size() != 1 or not _full_unchanged_wall(seat_id, old_by_id, new_by_id): return _full_bad("adopted_masonry_identity")
					if records[0].get("declaredGableId") != original_gables[index] or var_to_bytes(records[0].fact) != var_to_bytes(fact): return _full_bad("adopted_masonry_declared_end")
					local_direct.append(seat_id)
					local_common[seat_id] = true
					direct_peers[seat_id] = true
			if used_connections != connection_ids or local_direct.size() != arrangement.directSeats.size() or connection_ids.size() + local_direct.size() != 2: return _full_bad("orphan_or_duplicate_end_membership")
		else:
			# Historical archive grammar only; never constructs fallback geometry.
			if header.recipe.physicalRequiredSeatPartIds != original_gables or not proposal.get("connectionIds", []).is_empty(): return _full_bad("historical_deep_header_closure")
		for id: String in local_common:
			if framing.has(id): return _full_bad("framing_masonry_identity_conflict")
			common[id] = true
			selected[id] = true
		append_order.append_array(local_frames)
		housed_count += 2 + local_frames.size() - 1
		house_scopes[proposal.house] = {"framingIds": local_frames, "commonIds": local_common.keys(), "gableIds": original_gables, "directPeerIds": local_direct,
			"trimIds": proposal.trimmedPanelIds, "housedFactCount": local_frames.size() + 1, "grammar": "mixed_connections" if arrangement != null else "historical_deep_header"}
	var old_ids: Array = before.parts.map(func(part): return part.id)
	var after_ids: Array = after.parts.map(func(part): return part.id)
	if after_ids != old_ids + append_order: return _full_bad("exact_source_prefix_and_framing_append_order")
	for id: String in old_by_id:
		if not trims.has(id) and var_to_bytes(old_by_id[id].snapshot()) != var_to_bytes(new_by_id[id].snapshot()): return _full_bad("undeclared_source_change:" + id)
	return {"ready": visited.size() == 16 and headers.size() == 16 and trims.size() == 112 and gables.size() == 32,
		"common": common, "selected": selected, "headers": headers, "framing": framing, "ends": ends, "directPeers": direct_peers,
		"trims": trims, "gables": gables, "houseScopes": house_scopes, "appendOrder": append_order, "trimOrder": trim_order,
		"housedFactCount": housed_count, "commonCount": common.size(), "selectedCount": selected.size(), "sourcePrefixOrderDigest": _stable_digest(old_ids)}

func _full_bad(reason: String) -> Dictionary:
	return {"ready": false, "reason": reason}

func _full_index(b) -> Dictionary:
	var index: Dictionary = {}
	for part in b.parts:
		if part == null or part.id.is_empty() or index.has(part.id) or not b.has_finite_positive_bounds(part): return {}
		index[part.id] = part
	return index

func _full_frame(part) -> bool:
	return part != null and part.kind == "beam" and part.collision_enabled and part.rotation == Vector3.ZERO and part.recipe.get("preserveBearingFaces") == true and bool(part.recipe.get("visual", true))

func _full_record_exact(part, record: Variant) -> bool:
	if part == null or not record is Dictionary: return false
	var expected = HeadCopy.Blueprint.BuildingPartScript.new(record)
	return var_to_bytes(part.snapshot()) == var_to_bytes(expected.snapshot())

func _full_facts(part, axis: String, count: int) -> bool:
	var facts: Variant = part.recipe.get("physicalRequiredSeatFacts")
	var ids: Variant = part.recipe.get("physicalRequiredSeatPartIds")
	if not facts is Array or not ids is Array or facts.size() != count or ids.size() != count: return false
	var seen: Dictionary = {}
	for fact: Variant in facts:
		if not fact is Dictionary or not fact.get("seatId") is String or seen.has(fact.seatId) or fact.get("contactMode") != "housed_overlap" or fact.get("localSpanAxis") != axis: return false
		if not fact.get("localOverlapCenter") is Vector3 or not fact.get("localOverlapHalfExtents") is Vector3: return false
		var half: Vector3 = fact.localOverlapHalfExtents
		if not fact.localOverlapCenter.is_finite() or not half.is_finite() or half.x <= 0.0 or half.y <= 0.0 or half.z <= 0.0 or fact.get("minimumLongitudinalEmbedment") != 0.12 or fact.get("minimumVerticalOverlap") != 0.04: return false
		seen[fact.seatId] = true
	return ids == seen.keys()

func _full_unchanged_wall(id: String, old: Dictionary, current: Dictionary) -> bool:
	return old.has(id) and current.has(id) and old[id].kind == "wall" and old[id].collision_enabled and FullMaterials.is_masonry_material(old[id].material_id) and var_to_bytes(old[id].snapshot()) == var_to_bytes(current[id].snapshot())

func _full_declarations(before, after, old: Dictionary, current: Dictionary) -> bool:
	var a: Variant = before.recipe.get("facadeApertures")
	var b: Variant = after.recipe.get("facadeApertures")
	if not a is Dictionary or not b is Dictionary or a.is_empty() or a.keys() != b.keys(): return false
	for key: String in a:
		if not HeadDeclaration.validate(a[key], old) or not HeadDeclaration.validate(b[key], current): return false
		var first: Dictionary = a[key].duplicate(true)
		var second: Dictionary = b[key].duplicate(true)
		first.erase("sourceBinding")
		second.erase("sourceBinding")
		if var_to_bytes(first) != var_to_bytes(second): return false
	var before_recipe: Dictionary = before.recipe.duplicate(true)
	var after_recipe: Dictionary = after.recipe.duplicate(true)
	before_recipe.erase("facadeApertures")
	after_recipe.erase("facadeApertures")
	return var_to_bytes(before_recipe) == var_to_bytes(after_recipe) and var_to_bytes(before.rooms) == var_to_bytes(after.rooms)

func _full_aperture_owner(b, id: String) -> String:
	var owners: Array = []
	for key: String in b.recipe.facadeApertures:
		var declaration: Dictionary = b.recipe.facadeApertures[key]
		for member: String in declaration.partIds:
			if member == id:
				if declaration.get("producerPrefix") != key or declaration.get("semantic") != b.find_part(id).semantic: return ""
				owners.append(key)
	return owners[0] if owners.size() == 1 else ""

func _full_trim_exact(old, current, header_id: String, marker: String) -> bool:
	if old.kind != "wall" or not FullMaterials.is_masonry_material(old.material_id) or current.position.x != old.position.x or current.position.z != old.position.z or current.size.x != old.size.x or current.size.z != old.size.z: return false
	if float(current.position.y) - float(current.size.y) * 0.5 < float(old.position.y) - float(old.size.y) * 0.5 or float(current.position.y) + float(current.size.y) * 0.5 > float(old.position.y) + float(old.size.y) * 0.5: return false
	if current.recipe.get("physicalRequiredSeatPartIds") != [header_id]: return false
	var normalized = HeadCopy.Blueprint.BuildingPartScript.new(old.snapshot())
	normalized.position = current.position
	normalized.size = current.size
	HeadCopy.Frame._clean_derived(normalized)
	normalized.recipe["masonryApertureSource"] = marker
	for key: String in ["physicalRequiredSeatPartIds", "physicalRequiredSeatFacts"]: normalized.recipe[key] = current.recipe.get(key)
	return var_to_bytes(normalized.snapshot()) == var_to_bytes(current.snapshot())

func _full_pass(publisher, b, selected: Dictionary, phase: String) -> Dictionary:
	var expected: Array = b.parts.map(func(part): return part.id)
	var executed: Array = []
	var payloads: Dictionary = {}
	var emission: Dictionary = {"unselectedBoxInstances": 0, "unselectedMeshInstances": 0, "unselectedDirectChildren": 0, "sourceVisualDisabled": 0}
	var colliders = ColliderPublisher.new()
	for part in b.parts:
		if not _within_budget(): break
		if selected.has(part.id):
			if payloads.has(part.id):
				_stop_reason = "duplicate_selected_publication"
				break
			payloads[part.id] = _head_publish(publisher, b, part, colliders, phase)
		else:
			var parent: Node3D = Node3D.new()
			publisher.static_visual_collecting = true
			publisher.static_visual_part_transform = b.part_transform(part)
			publisher.static_visual_batches.clear()
			publisher.static_visual_transform_count = 0
			publisher.captured_mesh_batches.clear()
			# Match publish_part's owning visibility decision; hidden structural
			# records must not manufacture visual material-cache requests.
			if bool(part.recipe.get("visual", true)):
				publisher.publish_visual(part, parent)
			else:
				emission.sourceVisualDisabled += 1
			for group: Dictionary in publisher.static_visual_batches.values(): emission.unselectedBoxInstances += group.transforms.size()
			for capture: Dictionary in publisher.captured_mesh_batches.values(): emission.unselectedMeshInstances += capture.transforms.size()
			emission.unselectedDirectChildren += parent.get_child_count()
			parent.free()
		publisher.static_visual_batches.clear()
		publisher.static_visual_transform_count = 0
		publisher.captured_mesh_batches.clear()
		publisher.clear_published_node_roster()
		if publisher._publication_failed():
			_stop_reason = "full_order_publication_guard_failed:" + part.id
			break
		# Append only AFTER that part's actual publication call has returned.
		executed.append(part.id)
		if executed.size() % 32 == 0: await process_frame
	var complete: bool = executed == expected and payloads.size() == selected.size() and _stop_reason.is_empty()
	_head_checks[phase + ":every_part_executed_in_source_order"] = complete
	_full_order_passes.append({"phase": phase, "expectedPartCount": expected.size(), "executedPartCount": executed.size(), "expectedOrderDigest": _stable_digest(expected),
		"executedOrderDigest": _stable_digest(executed), "selectedCaptureCount": payloads.size(), "emissionWork": emission, "complete": complete})
	return payloads

func _full_house(before, b, proposal: Dictionary, scope: Dictionary, payloads: Dictionary, old_payloads: Dictionary) -> Dictionary:
	var header = b.find_part(proposal.headerId)
	var trims: Array = scope.trimIds
	var common: Array = scope.commonIds
	var framing: Array = scope.framingIds
	var ids: Array = common + framing
	var apertures: Array = _head_apertures(b, proposal.house)
	var checks: Dictionary = {"boundApertures": not apertures.is_empty()}
	var framing_publication: Array = []
	for id: String in framing:
		var part = b.find_part(id)
		var expected: Transform3D = b.part_transform(part) * Transform3D(Basis.from_scale(part.size), Vector3.ZERO)
		for channel: String in ["visual", "collision"]:
			var own: Dictionary = payloads[id][channel]
			checks["continuousExactFraming:" + id + ":" + channel] = own.primitives.size() == 1 and own.primitives[0].type == "box" and own.primitives[0].transform == expected
		framing_publication.append({"partId": id, "sourceTransform": expected, "preserveBearingFaces": part.recipe.preserveBearingFaces,
			"expectedBranch": "preserveBearingFaces -> BearingTimber", "material": part.material_id})
	var clearance: Array = []
	var prior: Array = []
	var seats: Array = []
	for id: String in ids:
		for channel: String in ["visual", "collision"]:
			var clear: Dictionary = _head_clearance(payloads[id][channel], apertures)
			clear.merge({"partId": id, "channel": channel})
			clearance.append(clear)
			if old_payloads.has(id):
				var old: Dictionary = _head_clearance(old_payloads[id][channel], apertures)
				old.merge({"partId": id, "channel": channel})
				prior.append(old)
		if common.has(id):
			_full_masonry_checks(before, before.find_part(id), old_payloads[id], "before", checks)
			_full_masonry_checks(b, b.find_part(id), payloads[id], "after", checks)
	for id: String in framing:
		var bearer = b.find_part(id)
		var facts: Array = bearer.recipe.get("physicalRequiredSeatFacts", [])
		checks["completeActualHousedFacts:" + id] = _full_facts(bearer, "z" if id == header.id else "x", 2 if id == header.id else 1)
		for fact: Dictionary in facts:
			checks["capturedDeclaredSeat:" + id + ":" + fact.seatId] = ids.has(fact.seatId) and payloads.has(fact.seatId)
			if not checks["capturedDeclaredSeat:" + id + ":" + fact.seatId]: continue
			# Actual source fact, including X-spanning endblocks. Never relabel it
			# as Z to satisfy a helper: the inherited finite-region proof owns it.
			for channel: String in ["visual", "collision"]: seats.append(_head_housed(b, bearer, fact, payloads[id][channel], payloads[fact.seatId][channel], channel))
	for id: String in trims:
		var part = b.find_part(id)
		var gravity: Array = part.recipe.get("physicalRequiredSeatFacts", [])
		checks["oneNamedGravitySeat:" + id] = gravity.size() == 1 and gravity[0] is Dictionary and gravity[0].get("seatId") == header.id
		if not checks["oneNamedGravitySeat:" + id]: continue
		for channel: String in ["visual", "collision"]: seats.append(_head_gravity(b, part, gravity[0], payloads[id][channel], payloads[header.id][channel], channel))
	checks["allActualPrimitivesClear"] = clearance.size() == 2 * ids.size() and clearance.all(func(row): return row.passed)
	checks["completePriorClearanceEvidence"] = prior.size() == 2 * common.size()
	checks["allFiniteSeats"] = seats.size() == 2 * (scope.housedFactCount + trims.size()) and seats.all(func(row): return row.passed)
	return {"house": proposal.house, "headerId": header.id, "closure": scope, "checks": checks, "framingPublication": framing_publication,
		"fullApertures": apertures, "apertureClearance": clearance, "beforeApertureClearance": prior,
		"priorClearanceFailureCount": prior.filter(func(row): return not row.passed).size(), "priorClearancePolicy": "Complete original payload evidence, never a waiver for changed geometry.",
		"finiteJointProofs": seats, "passed": checks.values().all(func(value): return value == true)}

func _full_masonry_checks(b, part, payload: Dictionary, phase: String, checks: Dictionary) -> void:
	var mortar: Vector3 = Publisher.MasonryWallGeometryScript.bed_size(part.size)
	var bed: Transform3D = b.part_transform(part) * Transform3D(Basis.from_scale(mortar), Vector3.ZERO)
	checks[phase + ":actualMortarPresent:" + part.id] = payload.visual.primitives.any(func(p): return p.type == "box" and p.transform == bed)
	var collider: Dictionary = payload.collision
	var expected: Transform3D = b.part_transform(part) * Transform3D(Basis.from_scale(part.size), Vector3.ZERO)
	checks[phase + ":exactCollider:" + part.id] = collider.primitives.size() == 1 and collider.primitives[0].type == "box" and collider.primitives[0].transform == expected
