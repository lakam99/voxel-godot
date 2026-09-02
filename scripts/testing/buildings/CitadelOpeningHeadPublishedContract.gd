extends "res://scripts/testing/buildings/CitadelChimneyPublishedContract.gd"

## One selected header and its trims/two gables: actual CPU publication only.
## Optional input override requires BOTH a new absolute path and its SHA-256.
const HeadCopy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const HeadDeclaration = preload("res://scripts/buildings/FacadeApertureDeclaration.gd")
const HEAD_INPUT := "res://artifacts/citadel-visual-reset/opening-head-band-05/candidate.bin"
const HEAD_SHA := "062d0bc76a06f632d0db61154a396449ddbd9a9328699a47f8b25d2c04992528"
const HEAD_MAX_BYTES := 32 * 1024 * 1024
const HEAD_MAX_CELLS := 4096
const HEAD_FROZEN_PUBLICATION := "res://artifacts/citadel-visual-reset/opening-head-published-03/report.json"
const HEAD_FROZEN_PUBLICATION_SHA := "cf263ffd16e010c179a943c73c87dd8735483ceb963fad4aa4430a44b0dc34ab"
var _head_checks: Dictionary = {}
var _head_work := 0
var _head_unsupported: Dictionary = {}
var _head_mesh_captures: Dictionary = {}
var _head_material_origins: Array = []

func _run() -> void:
	_started_msec = Time.get_ticks_msec()
	_next_progress_msec = _started_msec + 10000
	var path: String = OS.get_environment("VOXEL_OPENING_HEAD_PUBLISHED_REPORT")
	if not path.is_absolute_path() or path.get_extension() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var input: String = OS.get_environment("VOXEL_OPENING_HEAD_PUBLISHED_INPUT")
	var sha: String = OS.get_environment("VOXEL_OPENING_HEAD_PUBLISHED_INPUT_SHA256").to_lower()
	var override: bool = not input.is_empty() or not sha.is_empty()
	if not override:
		input = HEAD_INPUT
		sha = HEAD_SHA
	var report: Dictionary = {"evidenceLevel": "single_house_actual_CPU_publication_contract", "inputPath": input, "inputSha256": sha,
		"selectedHouse": OS.get_environment("VOXEL_OPENING_HEAD_PUBLISHED_HOUSE"),
		"inputOverride": override, "passed": false, "materialContext": "Common original/candidate parts published in identical order using separately configured full-blueprint surface history; new header published last.",
		"limitations": "No GPU readback/drawing, headed visuals, full scene batching, neighbour/furniture/swept-door clearance, physics contact/movement, engineering capacity, new source-generation acceptance, all-house coverage or whole physical gate. Exact primitive unions certify only the supplied finite joint regions. Unsupported non-axis-aligned primitives fail closed. Mortar and every emitted brick remain in full payloads; recourse changes are reported, not silently normalized."}
	if (override and not input.is_absolute_path()) or sha.length() != 64 or sha.hex_decode().size() != 32:
		_finish_head(path, report, "invalid_override_pair")
		return
	var archive: Dictionary = _head_read(input, sha)
	if archive.is_empty():
		_finish_head(path, report, "invalid_bound_archive")
		return
	var archive_digest: String = _stable_digest(archive)
	report["syntheticUnionControls"] = _head_union_controls()
	_head_checks["synthetic_controls_pass"] = report.syntheticUnionControls.values().all(func(value): return value)
	var before: Variant = HeadCopy.copy_blueprint(archive.beforeSnapshot)
	var after: Variant = HeadCopy.copy_blueprint(archive.afterSnapshot)
	var header: Variant = after.find_part(archive.headerId)
	var trims: Array = archive.trimmedPanelIds
	if header == null or trims.is_empty() or trims.size() > 32 or not header.recipe.get("physicalRequiredSeatPartIds") is Array or header.recipe.physicalRequiredSeatPartIds.size() != 2:
		_finish_head(path, report, "not_one_header_bounded_trims_two_gables")
		return
	var gables: Array = header.recipe.physicalRequiredSeatPartIds
	var common: Array = trims.duplicate()
	common.append_array(gables)
	common.sort()
	var unique: Dictionary = {header.id: true}
	for id: Variant in common:
		if not id is String or unique.has(id) or before.find_part(id) == null or after.find_part(id) == null:
			_finish_head(path, report, "invalid_scoped_membership")
			return
		unique[id] = true
	_head_checks["header_new_and_preserves_faces"] = before.find_part(header.id) == null and header.kind == "beam" and header.recipe.get("preserveBearingFaces") == true and header.collision_enabled
	var original_publisher: Variant = _configured_publisher(before)
	var candidate_publisher: Variant = _configured_publisher(after)
	for pair: Array in [[original_publisher, before], [candidate_publisher, after]]:
		if not pair[0].prepare_masonry_apertures(pair[1]):
			_finish_head(path, report, "masonry_preparation_rejected")
			return
		while pair[0]._masonry_preparation.state == "pending_budget" and _within_budget():
			pair[0]._masonry_preparation.advance(pair[0])
			await process_frame
		if pair[0]._masonry_preparation.state != "ready":
			_finish_head(path, report, "masonry_preparation_failed")
			return
	report["masonryPreparationMetrics"] = candidate_publisher._masonry_preparation.metrics.duplicate()
	var colliders: Variant = ColliderPublisher.new()
	var old_payloads: Dictionary = {}
	var payloads: Dictionary = {}
	var comparisons: Array = []
	for id: String in common:
		if not _within_budget(): break
		old_payloads[id] = _head_publish(original_publisher, before, before.find_part(id), colliders, "matched_before")
		payloads[id] = _head_publish(candidate_publisher, after, after.find_part(id), colliders, "matched_after")
		var comparison: Dictionary = _compare_channels(old_payloads[id], payloads[id])
		comparison["partId"] = id
		comparison["trimmedRecourse"] = trims.has(id)
		comparison["requestedVariationExact"] = original_publisher.variation_for(before.find_part(id)) == candidate_publisher.variation_for(after.find_part(id))
		comparisons.append(comparison)
		if gables.has(id): _head_checks["unchanged_gable_payload:" + id] = comparison.exact
		await process_frame
	payloads[header.id] = _head_publish(candidate_publisher, after, header, colliders, "new_header_last")
	_head_checks["complete_scoped_publication"] = old_payloads.size() == common.size() and payloads.size() == common.size() + 1 and comparisons.size() == common.size() and _stop_reason.is_empty()
	report.merge({"headerId": header.id, "trimmedPanelIds": trims, "gableIds": gables, "beforePayloads": old_payloads, "afterPayloads": payloads, "masonryRecourseComparisons": comparisons,
		"materialCacheOrigins": _head_material_origins,
		"headerPublication": {"expectedBranch": "preserveBearingFaces -> BearingTimber", "materialRequestKey": "%s:%0.3f" % [header.material_id, candidate_publisher.variation_for(header)]}})
	if sha == HEAD_SHA:
		var frozen: Variant = JSON.parse_string(FileAccess.get_file_as_string(HEAD_FROZEN_PUBLICATION))
		_head_checks["frozen_publication_input_bound"] = FileAccess.get_sha256(HEAD_FROZEN_PUBLICATION) == HEAD_FROZEN_PUBLICATION_SHA and frozen is Dictionary
		# Compare at the recorded JSON precision on BOTH sides. Formula bit
		# parity is separately tested; this is not a raw binary payload claim.
		_head_checks["recorded_visual_collision_material_custom_data_parity"] = _head_checks.frozen_publication_input_bound and JSON.stringify(JSON.parse_string(JSON.stringify(_overlap_json(old_payloads)))) == JSON.stringify(frozen.beforePayloads) and JSON.stringify(JSON.parse_string(JSON.stringify(_overlap_json(payloads)))) == JSON.stringify(frozen.afterPayloads)
		report["frozenParityPrecision"] = "Complete recorded JSON payloads; raw formula bit parity is a separate synthetic contract."
	if not _head_checks.complete_scoped_publication:
		_finish_head(path, report, "incomplete_publication")
		return
	var expected: Transform3D = after.part_transform(header) * Transform3D(Basis.from_scale(header.size), Vector3.ZERO)
	for channel: String in ["visual", "collision"]:
		var payload: Dictionary = payloads[header.id][channel]
		_head_checks["continuous_header_exact_box:" + channel] = payload.primitives.size() == 1 and payload.primitives[0].type == "box" and payload.primitives[0].transform == expected
	var apertures: Array = _head_apertures(after, String(header.id).trim_suffix("_opening_head_band_000"))
	_head_checks["bound_full_apertures_present"] = not apertures.is_empty()
	report["fullApertures"] = apertures
	var clearance: Array = []
	for id: String in payloads:
		for channel: String in ["visual", "collision"]:
			var result: Dictionary = _head_clearance(payloads[id][channel], apertures)
			result.merge({"partId": id, "channel": channel})
			clearance.append(result)
	_head_checks["actual_published_aperture_clearance"] = clearance.size() == 2 * (common.size() + 1) and clearance.all(func(row): return row.passed)
	report["apertureClearance"] = clearance
	var prior_clearance: Array = []
	for id: String in common:
		for channel: String in ["visual", "collision"]:
			var prior := _head_clearance(old_payloads[id][channel], apertures)
			prior.merge({"partId": id, "channel": channel})
			prior_clearance.append(prior)
	report["beforeApertureClearance"] = prior_clearance # Evidence, not a waiver.
	var seats: Array = []
	var facts: Array = header.recipe.get("physicalRequiredSeatFacts", [])
	_head_checks["two_distinct_housed_facts"] = facts.size() == 2 and facts.all(func(fact): return fact is Dictionary and gables.has(fact.get("seatId"))) and facts[0].seatId != facts[1].seatId
	if _head_checks.two_distinct_housed_facts:
		for fact: Dictionary in facts:
			for channel: String in ["visual", "collision"]:
				seats.append(_head_housed(after, header, fact, payloads[header.id][channel], payloads[fact.seatId][channel], channel))
	for id: String in trims:
		var part: Variant = after.find_part(id)
		var gravity: Array = part.recipe.get("physicalRequiredSeatFacts", [])
		_head_checks["one_named_gravity_seat:" + id] = gravity.size() == 1 and gravity[0] is Dictionary and gravity[0].get("seatId") == header.id
		if not _head_checks["one_named_gravity_seat:" + id]: continue
		for channel: String in ["visual", "collision"]:
			seats.append(_head_gravity(after, part, gravity[0], payloads[id][channel], payloads[header.id][channel], channel))
	report["finiteJointProofs"] = seats
	_head_checks["all_housed_and_gravity_both_channels"] = seats.size() == 2 * (2 + trims.size()) and seats.all(func(row): return row.passed)
	_head_checks["input_and_snapshots_immutable"] = _stable_digest(archive) == archive_digest and FileAccess.get_sha256(input) == sha and var_to_bytes(before.snapshot()) == var_to_bytes(archive.beforeSnapshot) and var_to_bytes(after.snapshot()) == var_to_bytes(archive.afterSnapshot)
	_finish_head(path, report, "measurement_complete")

func _head_read(path: String, sha: String) -> Dictionary:
	if FileAccess.get_sha256(path) != sha: return {}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null: return {}
	var length: int = file.get_length()
	if length <= 0 or length > HEAD_MAX_BYTES:
		file.close()
		return {}
	var bytes: PackedByteArray = file.get_buffer(length)
	var complete: bool = bytes.size() == length and file.get_error() == OK
	file.close()
	if not complete or FileAccess.get_sha256(path) != sha: return {}
	var value: Variant = bytes_to_var(bytes)
	if not value is Dictionary or var_to_bytes(value) != bytes: return {}
	if value.has("houseProposals"):
		if not value.houseProposals is Array or value.houseProposals.size() > 32: return {}
		var selected := OS.get_environment("VOXEL_OPENING_HEAD_PUBLISHED_HOUSE")
		var found: Array = value.houseProposals.filter(func(p): return p is Dictionary and p.get("house") == selected)
		if selected.is_empty() or found.size() != 1 or not found[0].get("headerId") is String or not found[0].get("trimmedPanelIds") is Array: return {}
		# Explicit immutable-archive projection; generation is never rerun here.
		value["headerId"] = found[0].headerId
		value["trimmedPanelIds"] = found[0].trimmedPanelIds
	if not value.get("headerId") is String or not value.get("trimmedPanelIds") is Array: return {}
	for key: String in ["beforeSnapshot", "afterSnapshot"]:
		if not value.get(key) is Dictionary or not value[key].get("parts") is Array or value[key].parts.size() > MAX_SOURCE_PARTS: return {}
	return value

func _head_publish(publisher: Variant, b: Variant, part: Variant, colliders: Variant, phase: String) -> Dictionary:
	_head_mesh_captures.clear()
	var before_material_keys: Array = publisher.material_cache.keys()
	# The collision-only publisher still executes the real publish_part guard.
	# Supply the same validated source/context; never bypass the new readiness gate.
	colliders.source_blueprint_id = publisher.source_blueprint_id
	colliders.surface_history.configure(b.recipe, b.parts)
	colliders._masonry_preparation = publisher._masonry_preparation
	var result: Dictionary = {"visual": _extract_overlap_payload(publisher, b, part, phase), "collision": _collision_payload(colliders, part)}
	for key: String in publisher.material_cache:
		if not key.begins_with("masonry_repair:") or before_material_keys.has(key): continue
		var material: ShaderMaterial = publisher.material_cache[key]
		_head_material_origins.append({"phase": phase, "firstRequestPartId": part.id, "key": key,
			"repairPhase": material.get_shader_parameter("repair_phase"), "materialDigest": _material_digest(material)})
	var artifact: Dictionary = publisher._masonry_preparation.artifact(part) if publisher._masonry_preparation != null else {}
	var expected_meshes: Dictionary = artifact.get("preparedMeshes", {})
	var seen: Dictionary = {}
	for primitive: Dictionary in result.visual.get("primitives", []):
		if primitive.type != "mesh": continue
		var capture: Dictionary = _head_mesh_captures.get(primitive.id, {})
		var matches: Array = expected_meshes.values().filter(func(prepared): return prepared.mesh == capture.get("mesh"))
		if matches.size() != 1:
			_stop_reason = "unbound_actual_masonry_mesh"
			continue
		var prepared: Dictionary = matches[0]
		var original: Dictionary = prepared.original
		if seen.has(original.id) or primitive.transform != original.transform or primitive.customData != original.customData or capture.get("localTransform") != original.localTransform or capture.get("material") != publisher.material_cache.get(original.materialKey):
			_stop_reason = "masonry_mesh_frame_attribute_mismatch"
			continue
		seen[original.id] = true
		var entry: Array = artifact.entries.filter(func(value): return value.original.id == original.id)
		if entry.size() != 1:
			_stop_reason = "masonry_mesh_entry_mismatch"
			continue
		primitive["actualLocalVertices"] = capture.vertices
		primitive["actualFaceProvenance"] = prepared.faceProvenance.duplicate(true)
		primitive["actualCellCount"] = entry[0].cells.size()
		primitive["originalBrickId"] = original.id
	if seen.size() != expected_meshes.values().filter(func(value): return value.mesh != null).size(): _stop_reason = "missing_expected_masonry_mesh"
	for channel: String in ["visual", "collision"]:
		if not _valid_payload(result[channel]) or result[channel].get("status") != "published": _stop_reason = "invalid_or_empty_scoped_payload:" + part.id
	return result

func _collect_nonboxes(parent: Node, accumulated: Transform3D, prefix: String, result: Dictionary) -> void:
	super._collect_nonboxes(parent, accumulated, prefix, result)
	if _active_mesh_capture == null: return
	for child in parent.get_children():
		if not child is MultiMeshInstance3D: continue
		var captured: Dictionary = _active_mesh_capture.captured_mesh_batches.get(child.get_instance_id(), {})
		if captured.is_empty() or not captured.mesh is ArrayMesh: continue
		var mesh: ArrayMesh = captured.mesh
		if mesh.get_surface_count() != 1: continue
		var arrays := mesh.surface_get_arrays(0)
		if not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array or arrays[Mesh.ARRAY_VERTEX].size() > 32768: continue
		var id_prefix := "cpu_multimesh:" + prefix + "/" + String(child.name) + ":"
		for index in range(captured.transforms.size()):
			_head_mesh_captures[id_prefix + str(index)] = {"mesh": mesh, "vertices": arrays[Mesh.ARRAY_VERTEX],
				"localTransform": captured.transforms[index], "material": captured.material}

func _head_apertures(b: Variant, prefix: String) -> Array:
	var by_id: Dictionary = {}
	for part: Variant in b.parts: by_id[part.id] = part
	var result: Array = []
	var declarations: Variant = b.recipe.get("facadeApertures")
	if not declarations is Dictionary: return []
	for key: String in [prefix + "_stone_facade", prefix + "_upper_facade"]:
		var entry: Variant = declarations.get(key)
		if not HeadDeclaration.validate(entry, by_id) or entry.get("producerPrefix") != key or not entry.get("openings") is Array: return []
		for opening: Variant in entry.openings:
			if not opening is Dictionary or not opening.get("fullVolume") is AABB: return []
			var box: AABB = opening.fullVolume
			if not box.position.is_finite() or not box.size.is_finite() or box.size.x <= 0 or box.size.y <= 0 or box.size.z <= 0: return []
			result.append({"id": opening.id, "fullVolume": box})
	return result

func _head_clearance(payload: Dictionary, apertures: Array) -> Dictionary:
	var hits: Array = []
	# Every primitive participates. Conservative envelopes may establish clear
	# separation but never turn a potential rotated-brick contact into a defect.
	var boxes: Array = []
	for primitive: Dictionary in payload.primitives:
		var bounds: Array = _head_local_bounds(primitive.transform, Vector3.ZERO, Vector3.ONE * 0.5) if primitive.type == "box" and _axis_aligned(primitive.transform) else primitive.bounds
		boxes.append({"id": primitive.id, "bounds": bounds, "primitive": primitive})
	for box: Dictionary in boxes:
		for aperture: Dictionary in apertures:
			if not _head_tick(): return {"passed": false, "reason": "clearance_work_limit", "positiveIntersections": hits}
			var volume: AABB = aperture.fullVolume
			# Preserve the declaration's represented planes without a float32
			# center/half-size round trip that could move an aperture boundary.
			var other: Array = [float(volume.position.x), float(volume.position.y), float(volume.position.z), float(volume.end.x), float(volume.end.y), float(volume.end.z)]
			if _head_intersects(box.bounds, other):
				if box.primitive.type == "mesh" and _head_actual_mesh_clear(box.primitive, volume): continue
				var gap := _head_aperture_gap(box.primitive.transform, volume) if box.primitive.type == "box" else -INF
				var guard := _interval_guard(box.bounds, other)
				if is_finite(gap) and gap > guard: continue
				hits.append({"primitiveId": box.id, "apertureId": aperture.id, "signedVerticalOverlap": minf(box.bounds[4], other[4]) - maxf(box.bounds[1], other[1]), "primitiveBounds": box.bounds, "apertureBounds": other,
					"boxSatGreatestAxisGap": gap if is_finite(gap) else null, "classification": "affine_box_positive_overlap" if is_finite(gap) and gap < -guard else "nonbox_or_numerically_unresolved"})
	return {"passed": not boxes.is_empty() and not apertures.is_empty() and hits.is_empty() and _stop_reason.is_empty(), "potentialIntersections": hits, "boxCount": boxes.size(), "comparison": "All actual primitives; conservative envelope separation then affine-box SAT against declared endpoints. Numerically ambiguous/nonbox candidates never pass."}

func _head_actual_mesh_clear(primitive: Dictionary, volume: AABB) -> bool:
	if not primitive.get("actualLocalVertices") is PackedVector3Array or not primitive.get("actualFaceProvenance") is Array: return false
	var vertices: PackedVector3Array = primitive.actualLocalVertices
	var count: int = primitive.get("actualCellCount", 0)
	if count < 1 or count > 256: return false
	var groups: Array = []
	var covered: Dictionary = {}
	for index in range(count): groups.append([])
	for face: Dictionary in primitive.actualFaceProvenance:
		if face.cellIndex < 0 or face.cellIndex >= count or face.firstVertex < 0 or face.vertexCount < 3 or face.firstVertex + face.vertexCount > vertices.size(): return false
		for index in range(face.firstVertex, face.firstVertex + face.vertexCount):
			if not _head_tick() or covered.has(index): return false
			covered[index] = true
			var local := vertices[index]
			if not local.is_finite() or absf(local.x) > 0.5 or absf(local.y) > 0.5 or absf(local.z) > 0.5: return false
			groups[face.cellIndex].append(primitive.transform * local)
	if covered.size() != vertices.size(): return false
	for points: Array in groups:
		if points.is_empty(): return false
		var low: Vector3 = points[0]
		var high: Vector3 = points[0]
		for point: Vector3 in points:
			if not point.is_finite(): return false
			low = low.min(point)
			high = high.max(point)
		var separated := false
		for axis in range(3): separated = separated or high[axis] <= volume.position[axis] or low[axis] >= volume.end[axis]
		if not separated: return false
	return true

func _head_aperture_gap(pose: Transform3D, aperture: AABB) -> float:
	if not _valid_box(pose): return -INF
	var edges := [pose.basis.x, pose.basis.y, pose.basis.z]
	var cardinal := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
	var axes: Array = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
	for index in range(3):
		axes.append(_cross64(edges[index], edges[(index + 1) % 3]))
		for other in range(3): axes.append(_cross64(edges[index], cardinal[other]))
	var greatest := -INF
	for axis in axes:
		if not _head_tick(): return -INF
		var length_squared: float = axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]
		if length_squared == 0.0: continue
		var length := sqrt(length_squared)
		for component in range(3): axis[component] /= length
		var centre: float = _dot64(axis, pose.origin)
		var radius := 0.0
		for edge in edges: radius += 0.5 * absf(_dot64(axis, edge))
		var low := 0.0
		var high := 0.0
		for component in range(3):
			var a: float = axis[component] * float(aperture.position[component])
			var c: float = axis[component] * float(aperture.end[component])
			low += minf(a, c)
			high += maxf(a, c)
		greatest = maxf(greatest, maxf(low - (centre + radius), (centre - radius) - high))
	return greatest

func _head_housed(b: Variant, header: Variant, fact: Dictionary, own: Dictionary, peer: Dictionary, channel: String) -> Dictionary:
	var result: Dictionary = {"partId": header.id, "seatId": fact.get("seatId"), "channel": channel, "mode": "finite_housed_volume", "passed": false}
	var center: Variant = fact.get("localOverlapCenter")
	var half: Variant = fact.get("localOverlapHalfExtents")
	var axis: Variant = fact.get("localSpanAxis")
	if fact.get("contactMode") != "housed_overlap" or not center is Vector3 or not center.is_finite() or not _head_socket_dimensions_valid(half, axis): return result
	result["localSpanAxis"] = axis
	var region: Array = _head_local_bounds(b.part_transform(header), center, half)
	if region.is_empty(): return result
	var own_cover: Dictionary = _head_cover(region, _head_boxes(own))
	var peer_cover: Dictionary = _head_cover(region, _head_boxes(peer))
	if not peer_cover.covered:
		peer_cover["orientedRefinement"] = _head_oriented_cover(peer_cover.get("uncoveredCells", [region]), peer)
		peer_cover.covered = peer_cover.orientedRefinement.covered
	result.merge({"region": region, "headerCoverage": own_cover, "seatCoverage": peer_cover, "measurement": _joint_measurement(own, peer, false), "passed": own_cover.covered and peer_cover.covered and _stop_reason.is_empty()}, true)
	return result

func _head_socket_dimensions_valid(half: Variant, axis: Variant) -> bool:
	if axis not in ["x", "z"] or not half is Vector3 or not half.is_finite() or half.x <= 0 or half.z <= 0 or half.y * 2.0 < 0.04: return false
	var span: float = half.x if axis == "x" else half.z
	return span * 2.0 >= 0.12

func _head_gravity(b: Variant, part: Variant, fact: Dictionary, own: Dictionary, peer: Dictionary, channel: String) -> Dictionary:
	var result: Dictionary = {"partId": part.id, "seatId": fact.get("seatId"), "channel": channel, "mode": "full_bottom_patch_supported_from_beneath", "passed": false}
	var center: Variant = fact.get("localPatchCenter")
	var half: Variant = fact.get("localPatchHalfExtents")
	if fact.get("loadDirection") != "world_down" or fact.get("seatFace") != "max_y" or not center is Vector3 or not half is Vector2 or not center.is_finite() or not half.is_finite() or half.x <= 0 or half.y <= 0 or center.y != -part.size.y * 0.5: return result
	var patch: Array = _head_local_bounds(b.part_transform(part), center, Vector3(half.x, 0.0, half.y))
	if patch.is_empty(): return result
	var own_boxes: Array = _head_boxes(own)
	var seat_boxes: Array = _head_boxes(peer)
	var coverage := _head_supported_patch(patch, own_boxes, seat_boxes)
	result.merge({"worldPatch": patch, "contactPlaneY": patch[1], "supportedPatch": coverage, "measurement": _joint_measurement(peer, own, true), "passed": coverage.covered and _stop_reason.is_empty()}, true)
	return result

func _head_supported_patch(patch: Array, own_boxes: Array, seat_boxes: Array) -> Dictionary:
	var contacts: Array = []
	var embedding: Array = []
	for upper: Dictionary in own_boxes:
		for lower: Dictionary in seat_boxes:
			if not _head_tick(): return {"covered": false, "reason": "work_limit"}
			# No positive gap. Both actual solids contain the finite patch, with
			# panel above and support beneath. Embedding uses the EXISTING maximum
			# contact depth, never a tolerance that bridges empty space.
			if upper.bounds[1] > patch[1] or upper.bounds[4] <= patch[1] or lower.bounds[1] >= patch[1] or lower.bounds[4] < patch[1]: continue
			var depth: float = lower.bounds[4] - patch[1]
			if depth > HeadCopy.Blueprint.PHYSICAL_CONTACT_MARGIN: continue
			var rect: Array = [maxf(upper.bounds[0], lower.bounds[0]), 0.0, maxf(upper.bounds[2], lower.bounds[2]), minf(upper.bounds[3], lower.bounds[3]), 1.0, minf(upper.bounds[5], lower.bounds[5])]
			if rect[0] < rect[3] and rect[2] < rect[5]:
				contacts.append({"id": upper.id + "->" + lower.id, "bounds": rect})
				embedding.append(depth)
	var coverage: Dictionary = _head_cover([patch[0], 0.0, patch[2], patch[3], 1.0, patch[5]], contacts)
	coverage.merge({"contactRectangles": contacts, "measuredEmbeddingDepths": embedding, "maximumExistingContractDepth": HeadCopy.Blueprint.PHYSICAL_CONTACT_MARGIN, "positiveGapAllowed": 0.0})
	return coverage

func _head_boxes(payload: Dictionary) -> Array:
	var result: Array = []
	if not _valid_payload(payload): return result
	for primitive: Dictionary in payload.primitives:
		if primitive.type != "box" or not _axis_aligned(primitive.transform):
			_head_unsupported[primitive.id] = true
			continue # Subset coverage can prove presence, never absence.
		var bounds: Array = _head_local_bounds(primitive.transform, Vector3.ZERO, Vector3.ONE * 0.5)
		if not _valid_intervals(bounds):
			_stop_reason = "invalid_unpadded_primitive_planes"
			return []
		result.append({"id": primitive.id, "bounds": bounds})
	return result

func _head_local_bounds(pose: Transform3D, center: Vector3, half: Vector3) -> Array:
	if not _valid_box(pose) or not _axis_aligned(pose) or not center.is_finite() or not half.is_finite(): return []
	var result: Array = []
	var upper: Array = []
	for axis: int in range(3):
		var low: float = float(pose.origin[axis])
		var high: float = low
		for component: int in range(3):
			var coefficient: float = float(pose.basis[component][axis])
			var a: float = coefficient * (float(center[component]) - float(half[component]))
			var c: float = coefficient * (float(center[component]) + float(half[component]))
			low += minf(a, c)
			high += maxf(a, c)
		if not is_finite(low) or not is_finite(high): return []
		result.append(low)
		upper.append(high)
	result.append_array(upper)
	return result

## Complete conservative envelopes can disprove coverage at an interior point.
## Otherwise rotated-union coverage remains unproven; no positive fallback.
func _head_oriented_cover(regions: Array, payload: Dictionary) -> Dictionary:
	for region in regions:
		var point := [(region[0] + region[3]) * 0.5, (region[1] + region[4]) * 0.5, (region[2] + region[5]) * 0.5]
		var clearance := INF
		for primitive: Dictionary in payload.primitives:
			var gap := -INF
			for axis in range(3): gap = maxf(gap, maxf(primitive.bounds[axis] - point[axis], point[axis] - primitive.bounds[axis + 3]))
			clearance = minf(clearance, gap)
		if clearance > 0.0 and is_finite(clearance):
			return {"covered": false, "reason": "proven_uncovered_point_inside_required_region", "point": point, "conservativeEnvelopeClearance": clearance, "completePrimitiveCount": payload.primitives.size()}
	return {"covered": false, "reason": "oriented_union_coverage_unproven", "limitation": "No absence claim without a point outside every complete conservative envelope."}

func _head_intersects(a: Array, c: Array) -> bool:
	if a.size() != 6 or c.size() != 6: return false
	for axis: int in range(3):
		if minf(a[axis + 3], c[axis + 3]) <= maxf(a[axis], c[axis]): return false
	return true

func _head_cover(region: Array, boxes: Array) -> Dictionary:
	if not _valid_intervals(region): return {"covered": false, "reason": "invalid_finite_region"}
	var cells: Array = [region.duplicate()]
	var used: Array = []
	for box: Dictionary in boxes:
		var next: Array = []
		for cell: Array in cells:
			if not _head_tick(): return {"covered": false, "reason": "work_limit", "uncoveredCells": cells}
			if not _head_intersects(cell, box.bounds):
				next.append(cell)
				continue
			if not used.has(box.id): used.append(box.id)
			var remainder: Array = cell.duplicate()
			for axis: int in range(3):
				var low: float = maxf(cell[axis], box.bounds[axis])
				var high: float = minf(cell[axis + 3], box.bounds[axis + 3])
				if low > remainder[axis]:
					var left: Array = remainder.duplicate()
					left[axis + 3] = low
					next.append(left)
					remainder[axis] = low
				if high < remainder[axis + 3]:
					var right: Array = remainder.duplicate()
					right[axis] = high
					next.append(right)
					remainder[axis + 3] = high
			if next.size() > HEAD_MAX_CELLS:
				_stop_reason = "finite_region_cell_limit"
				return {"covered": false, "reason": _stop_reason}
		cells = next
		if cells.is_empty(): break
	return {"covered": cells.is_empty(), "primitiveIds": used, "uncoveredCells": cells, "tolerance": 0.0, "limitation": "Coverage by axis-aligned subset is a positive witness; uncovered regions are not proof of absent rotated solids."}

func _head_tick() -> bool:
	_head_work += 1
	if _head_work > MAX_PRIMITIVE_TESTS: _stop_reason = "finite_region_work_limit"
	return _within_budget()

func _head_union_controls() -> Dictionary:
	var unit: Array = [0.0, 0.0, 0.0, 1.0, 1.0, 1.0]
	var left: Dictionary = {"id": "left", "bounds": [0.0, 0.0, 0.0, 0.5, 1.0, 1.0]}
	var right: Dictionary = {"id": "right", "bounds": [0.5, 0.0, 0.0, 1.0, 1.0, 1.0]}
	var gap: Dictionary = right.duplicate(true)
	gap.bounds[0] += 1.0 / 1048576.0
	var patch := [0.0, 1.0, 0.0, 1.0, 1.0, 1.0]
	var panel := [{"id": "panel", "bounds": [0.0, 1.0, 0.0, 1.0, 2.0, 1.0]}]
	var seat := {"id": "seat", "bounds": unit}
	var below_gap := {"id": "gap", "bounds": [0.0, 0.0, 0.0, 1.0, 1.0 - 1.0 / 1048576.0, 1.0]}
	var above_only := {"id": "above", "bounds": [0.0, 1.0, 0.0, 1.0, 2.0, 1.0]}
	var embedded := {"id": "embed", "bounds": [0.0, 0.0, 0.0, 1.0, 1.0 + 1.0 / 1048576.0, 1.0]}
	var unit_volume := AABB(Vector3.ONE * -0.5, Vector3.ONE)
	var shear := Transform3D(Basis(Vector3(1.0, 0.0, 0.0), Vector3(1.5, 1.0, 0.0), Vector3.BACK), Vector3.ZERO)
	return {"housed_x_uses_x_extent": _head_socket_dimensions_valid(Vector3(0.07, 0.04, 0.04), "x"),
		"housed_z_uses_z_extent": _head_socket_dimensions_valid(Vector3(0.04, 0.04, 0.07), "z"),
		"short_x_rejected_despite_long_z": not _head_socket_dimensions_valid(Vector3(0.04, 0.04, 0.07), "x"),
		"short_z_rejected_despite_long_x": not _head_socket_dimensions_valid(Vector3(0.07, 0.04, 0.04), "z"),
		"short_vertical_joint_rejected": not _head_socket_dimensions_valid(Vector3(0.07, 0.01, 0.07), "x"),
		"vertical_span_axis_rejected": not _head_socket_dimensions_valid(Vector3.ONE, "y"),
		"touching_full_patch_supported": _head_supported_patch(patch, panel, [seat]).covered,
		"aperture_sat_identical_overlap": _head_aperture_gap(Transform3D.IDENTITY, unit_volume) < 0.0,
		"aperture_sat_separated": _head_aperture_gap(Transform3D(Basis.IDENTITY, Vector3(2.0, 0.0, 0.0)), unit_volume) > 0.0,
		"aperture_sat_exact_touch": _head_aperture_gap(Transform3D(Basis.IDENTITY, Vector3.RIGHT), unit_volume) == 0.0,
		"aperture_sat_shear_false_positive_separated": _head_aperture_gap(shear, AABB(Vector3(-1.125, 0.375, -0.0625), Vector3.ONE * 0.125)) > 0.0,
		"embedded_full_patch_supported": _head_supported_patch(patch, panel, [embedded]).covered,
		"positive_gap_rejected": not _head_supported_patch(patch, panel, [below_gap]).covered,
		"partial_patch_rejected": not _head_supported_patch(patch, panel, [left]).covered,
		"above_only_rejected": not _head_supported_patch(patch, panel, [above_only]).covered,
		"two_touching_solids_cover_volume": _head_cover(unit, [left, right]).covered,
		"thin_positive_gap_rejected": not _head_cover(unit, [left, gap]).covered,
		"tangent_is_not_volume_coverage": not _head_cover(unit, [{"id": "touch", "bounds": [1.0, 0.0, 0.0, 2.0, 1.0, 1.0]}]).covered,
		"empty_is_not_coverage": not _head_cover(unit, []).covered}

func _finish_head(path: String, report: Dictionary, status: String) -> void:
	_head_checks["bounded_complete"] = status == "measurement_complete" and _within_budget()
	var passed: bool = not _head_checks.is_empty() and _head_checks.values().all(func(value): return value == true)
	report.merge({"passed": passed, "diagnosticCompleted": status == "measurement_complete" and _stop_reason.is_empty(), "status": status, "stopReason": _stop_reason,
		"finiteCoverageUnsupportedPrimitiveIds": _head_unsupported.keys(),
		"checks": _head_checks, "counts": _counts, "publicationWork": _work, "finiteRegionOperations": _head_work, "elapsedMsec": Time.get_ticks_msec() - _started_msec,
		"limits": {"softMsec": SOFT_LIMIT_MSEC, "sourceBytes": HEAD_MAX_BYTES, "finiteCells": HEAD_MAX_CELLS, "finiteOperations": MAX_PRIMITIVE_TESTS}, "gateZeroAccepted": false}, true)
	var bytes: PackedByteArray = JSON.stringify(_overlap_json(report), "  ").to_utf8_buffer()
	if bytes.size() > HEAD_MAX_BYTES * 2 or FileAccess.file_exists(path):
		quit(2)
		return
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_buffer(bytes)
	file.flush()
	var written: bool = file.get_error() == OK and file.get_length() == bytes.size()
	file.close()
	quit(0 if passed and written else 2)
