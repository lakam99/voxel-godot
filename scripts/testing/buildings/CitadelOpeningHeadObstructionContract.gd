extends "res://scripts/testing/buildings/CitadelOpeningHeadClearanceContract.gd"

## Frozen-source obstruction measurement only. Never invokes a publisher/recipe.
const CLEARANCE06 := "res://artifacts/citadel-visual-reset/opening-head-clearance-06/report.json"
const CLEARANCE06_SHA := "e23d1ad244eb08ae6d74a69001e58935587e0fc22c2c51983996f70eec6b1ff8"
const Core = preload("res://scripts/buildings/MasonryWallGeometry.gd")
const MAX_SAT_PAIRS := 250000
var _obs_pairs: int = 0
var _obs_checks: Dictionary = {}

func _run() -> void:
	_started_msec = Time.get_ticks_msec()
	_next_progress_msec = _started_msec + 10000
	var path: String = OS.get_environment("VOXEL_OPENING_HEAD_OBSTRUCTION_REPORT")
	if not path.is_absolute_path() or path.get_extension() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var report: Dictionary = {"evidenceLevel": "actual_frozen_source_affine_box_obstruction_probe", "candidateSha256": CANDIDATE_SHA, "originalSha256": ORIGINAL_SHA,
		"clearance06Sha256": CLEARANCE06_SHA, "recipeChanged": false, "placementAccepted": false,
		"limitations": "Source collider boxes only; no renderer, GPU, door sweep, furniture, capacity or new recipe acceptance. Hypotheses replace each house independently; simultaneous new-header interactions are not certified. Tiny signed residuals are reported and never waived. Float32 reconstructed hypothesis boxes must cover the original finite sockets exactly; no rounding repair or search for a green variant."}
	var archive: Dictionary = _clearance_read(CANDIDATE_PATH, CANDIDATE_SHA)
	var original: Dictionary = _clearance_read(ORIGINAL_PATH, ORIGINAL_SHA)
	var evidence: Dictionary = _obs_evidence()
	if archive.is_empty() or original.is_empty() or evidence.is_empty():
		_obs_finish(path, report, "invalid_bound_inputs")
		return
	var b = HeadCopy.copy_blueprint(original.afterSnapshot)
	var candidate = HeadCopy.copy_blueprint(archive.afterSnapshot)
	var frozen: String = ClearancePlan.digest([archive, original, b.snapshot(), candidate.snapshot()])
	_obs_checks["bound_before_exact"] = ClearancePlan.digest(archive.beforeSnapshot) == ClearancePlan.digest(original.afterSnapshot)
	var cohort: Array = evidence.get("blockedOrUnresolved", []).filter(func(row): return row is Dictionary and row.get("channel") == "source_collision")
	_obs_checks["exact21_original_envelopes"] = cohort.size() == 21
	_obs_checks["synthetic_sat_controls"] = _obs_controls()
	var refined: Array = []
	for row: Dictionary in cohort:
		var header = candidate.find_part(String(row.get("headerId", "")))
		var peer = b.find_part(String(row.get("obstacleId", "")))
		var retained = candidate.find_part(String(row.get("obstacleId", "")))
		if header == null or peer == null or retained == null or not peer.collision_enabled:
			_stop_reason = "missing_original_cohort_collider"
			break
		var a: Dictionary = _obs_part(candidate, header)
		var c: Dictionary = _obs_part(b, peer)
		if not _obs_valid(a) or not _obs_valid(c) or peer.position != retained.position or peer.rotation != retained.rotation or peer.size != retained.size or peer.collision_enabled != retained.collision_enabled:
			_stop_reason = "cohort_collider_geometry_changed"
			break
		refined.append({"headerId": header.id, "obstacleId": peer.id, "originalEnvelopeEvidence": row,
			"headerCollider": a, "originalCollider": c, "measurement": _obs_sat(a, c)})
	report["refined21"] = refined
	_obs_checks["all21_refined"] = refined.size() == 21
	var proposals: Variant = archive.get("houseProposals")
	if not proposals is Array or proposals.size() != 16:
		_obs_finish(path, report, "missing16_proposals")
		return
	var colliders: Array = []
	for part in b.parts:
		if not part.collision_enabled: continue
		var box: Dictionary = _obs_part(b, part)
		if not _obs_valid(box): _stop_reason = "invalid_original_collider"
		colliders.append(box)
	var hypotheses: Array = []
	for proposal: Dictionary in proposals:
		if not _within_budget(): break
		var hypothesis: Dictionary = _obs_hypothesis(b, candidate, proposal)
		if hypothesis.ready:
			var blockers: Array = []
			var visited: Array = []
			for peer: Dictionary in colliders:
				if hypothesis.excludedIds.has(peer.id): continue
				visited.append(peer.id)
				for piece: Dictionary in hypothesis.pieces:
					var result: Dictionary = _obs_sat(piece, peer, true)
					if not result.get("strictlySeparated", false):
						var overlap: Array = _overlap_bounds(piece.bounds, _source_box_bounds(peer.pose, peer.size))
						var prior: Dictionary = _head_cover(overlap, hypothesis.removedOriginalCells) if _valid_intervals(overlap) else {"covered": false, "reason": "no_positive_envelope_volume"}
						blockers.append({"pieceId": piece.id, "obstacleId": peer.id, "obstacleRotation": peer.rotation, "collider": peer, "measurement": result,
							"removedOriginalSourceCoverage": prior, "occupancyClass": "preexisting_source_overlap_retained" if prior.covered else "new_or_unresolved_source_occupancy"})
				if visited.size() % 256 == 0 and not _within_budget(): break
			hypothesis["foreignColliderCount"] = visited.size()
			hypothesis["foreignColliderOrderDigest"] = ClearancePlan.digest(visited)
			hypothesis["expectedForeignColliderCount"] = colliders.filter(func(c): return not hypothesis.excludedIds.has(c.id)).size()
			hypothesis["blockers"] = blockers
			hypothesis["newOrUnresolvedBlockers"] = blockers.filter(func(row): return not row.removedOriginalSourceCoverage.covered)
			hypothesis["avoidsForeignSolids"] = blockers.is_empty() and visited.size() == hypothesis.expectedForeignColliderCount and _stop_reason.is_empty()
			hypothesis["fits"] = hypothesis.preservesExteriorBand and hypothesis.containsCompleteSocketRegions and hypothesis.connectionsWithinSocketCoreLimits and hypothesis.connectedComponents == 1 and hypothesis.avoidsForeignSolids
		hypotheses.append(hypothesis)
		await process_frame
	report["hypotheses"] = hypotheses
	_obs_checks["all16_hypotheses_measured"] = hypotheses.size() == 16 and hypotheses.all(func(h): return h.ready and h.foreignColliderCount == h.expectedForeignColliderCount)
	_obs_checks["repeat_derivation_exact"] = hypotheses.size() == 16 and proposals.all(func(p): return ClearancePlan.digest(_obs_hypothesis(b, candidate, p)) == ClearancePlan.digest(_obs_hypothesis(b, candidate, p)))
	_obs_checks["immutable_sources"] = frozen == ClearancePlan.digest([archive, original, b.snapshot(), candidate.snapshot()]) and FileAccess.get_sha256(CANDIDATE_PATH) == CANDIDATE_SHA and FileAccess.get_sha256(ORIGINAL_PATH) == ORIGINAL_SHA and FileAccess.get_sha256(CLEARANCE06) == CLEARANCE06_SHA
	report["allHypothesesFit"] = hypotheses.size() == 16 and hypotheses.all(func(h): return h.get("fits", false))
	_obs_finish(path, report, "measurement_complete")

func _obs_evidence() -> Dictionary:
	if FileAccess.get_sha256(CLEARANCE06) != CLEARANCE06_SHA: return {}
	var file: FileAccess = FileAccess.open(CLEARANCE06, FileAccess.READ)
	if file == null: return {}
	var length: int = file.get_length()
	if length < 1 or length > 32 * 1024 * 1024:
		file.close()
		return {}
	var bytes: PackedByteArray = file.get_buffer(length)
	var complete: bool = bytes.size() == length and file.get_error() == OK
	file.close()
	var value: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	if not complete or not value is Dictionary or value.get("candidateSha256") != CANDIDATE_SHA or value.get("originalSha256") != ORIGINAL_SHA or FileAccess.get_sha256(CLEARANCE06) != CLEARANCE06_SHA: return {}
	return value

func _obs_part(b, part) -> Dictionary:
	return {"id": part.id, "pose": b.part_transform(part), "size": part.size, "rotation": part.rotation}

func _obs_valid(box: Dictionary) -> bool:
	return box.pose is Transform3D and _valid_box(box.pose) and box.size is Vector3 and box.size.is_finite() and box.size.x > 0 and box.size.y > 0 and box.size.z > 0

func _obs_sat(a: Dictionary, c: Dictionary, early_clear: bool = false) -> Dictionary:
	_obs_pairs += 1
	if _obs_pairs > MAX_SAT_PAIRS or not _obs_valid(a) or not _obs_valid(c):
		_stop_reason = "invalid_or_excessive_affine_sat"
		return {"ready": false, "strictlySeparated": false}
	var ae: Array = [a.pose.basis.x, a.pose.basis.y, a.pose.basis.z]
	var ce: Array = [c.pose.basis.x, c.pose.basis.y, c.pose.basis.z]
	var axes: Array = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
	for index: int in range(3):
		axes.append(_cross64(ae[index], ae[(index + 1) % 3]))
		axes.append(_cross64(ce[index], ce[(index + 1) % 3]))
		for other: int in range(3): axes.append(_cross64(ae[index], ce[other]))
	var magnitude: float = 1.0
	for axis: int in range(3): magnitude = maxf(magnitude, maxf(absf(a.pose.origin[axis]), absf(c.pose.origin[axis])))
	# Classification scale only. Never subtract it from raw gap or waive overlap.
	var resolution: float = magnitude * pow(2.0, -23.0)
	var best: float = -INF
	var best_axis: Array = []
	var tested: int = 0
	for axis: Array in axes:
		var length: float = sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2])
		if length == 0.0: continue
		var distance: float = 0.0
		for component: int in range(3): distance += axis[component] * (float(c.pose.origin[component]) - float(a.pose.origin[component]))
		var radius: float = 0.0
		for component: int in range(3): radius += 0.5 * (absf(_dot64(axis, ae[component])) * float(a.size[component]) + absf(_dot64(axis, ce[component])) * float(c.size[component]))
		var gap: float = (absf(distance) - radius) / length
		if not is_finite(gap):
			_stop_reason = "nonfinite_affine_gap"
			return {"ready": false, "strictlySeparated": false}
		tested += 1
		if gap > best:
			best = gap
			best_axis = [axis[0] / length, axis[1] / length, axis[2] / length]
		if early_clear and best > resolution: break
	var classification: String = "significant_separation" if best > resolution else ("significant_overlap" if best < -resolution else ("negative_numerical_residual" if best < 0.0 else ("positive_numerical_residual" if best > 0.0 else "exact_touch_or_unresolved_zero")))
	return {"ready": true, "rawSignedGap": best, "axis": best_axis, "axesTested": tested, "maximumOverAllAxes": not early_clear or best <= resolution,
		"classification": classification, "inputFloat32ResolutionScale": resolution, "rawPenetration": best < 0.0, "strictlySeparated": best > resolution, "residualWaived": false}

func _obs_hypothesis(b, candidate, proposal: Dictionary) -> Dictionary:
	var header = candidate.find_part(String(proposal.get("headerId", "")))
	var trims: Variant = proposal.get("trimmedPanelIds")
	if header == null or header.rotation != Vector3.ZERO or not trims is Array or trims.size() != 7: return {"ready": false, "reason": "invalid_hypothesis_membership"}
	var panel = b.find_part(trims[0])
	if panel == null or panel.rotation != Vector3.ZERO: return {"ready": false, "reason": "invalid_original_facade"}
	var removed: Array = []
	for id: String in trims:
		var part = b.find_part(id)
		if part == null or part.position.x != panel.position.x or part.size.x != panel.size.x or part.rotation != Vector3.ZERO: return {"ready": false, "reason": "inconsistent_original_facade"}
		var retained = candidate.find_part(id)
		if retained == null or retained.rotation != Vector3.ZERO: return {"ready": false, "reason": "invalid_retained_panel"}
		var old_bounds: Array = _source_box_bounds(b.part_transform(part), part.size)
		var retained_box := {"id": id, "bounds": _source_box_bounds(candidate.part_transform(retained), retained.size)}
		var difference := _head_cover(old_bounds, [retained_box])
		if not difference.has("uncoveredCells"): return {"ready": false, "reason": "removed_panel_difference_unresolved"}
		for cell: Array in difference.uncoveredCells: removed.append({"id": id + ":removed:" + str(removed.size()), "bounds": cell})
	var body: Dictionary = {"id": "shallow_body", "pose": Transform3D(Basis.IDENTITY, Vector3(panel.position.x, header.position.y, header.position.z)), "size": Vector3(panel.size.x, header.size.y, header.size.z), "rotation": Vector3.ZERO}
	body["bounds"] = _head_local_bounds(body.pose, Vector3.ZERO, body.size * 0.5)
	var pieces: Array = [body]
	var sockets: Array = []
	var exclusions: Array = trims.duplicate()
	var facts: Variant = header.recipe.get("physicalRequiredSeatFacts")
	var declared: Variant = header.recipe.get("physicalRequiredSeatPartIds")
	if not facts is Array or facts.size() != 2 or not declared is Array or declared.size() != 2 or declared[0] == declared[1]: return {"ready": false, "reason": "invalid_required_sockets"}
	var seen: Dictionary = {}
	var core_fit: bool = true
	for fact: Variant in facts:
		if not fact is Dictionary or fact.get("contactMode") != "housed_overlap" or not declared.has(fact.get("seatId")) or seen.has(fact.seatId) or not fact.get("localOverlapCenter") is Vector3 or not fact.get("localOverlapHalfExtents") is Vector3: return {"ready": false, "reason": "invalid_finite_socket_fact"}
		seen[fact.seatId] = true
		var gable = b.find_part(fact.seatId)
		if gable == null or gable.rotation != Vector3.ZERO or not gable.collision_enabled: return {"ready": false, "reason": "invalid_gable_core"}
		var socket: Array = _head_local_bounds(candidate.part_transform(header), fact.localOverlapCenter, fact.localOverlapHalfExtents)
		var core: Array = _head_local_bounds(b.part_transform(gable), Vector3.ZERO, Core.bed_size(gable.size) * 0.5)
		if not _valid_intervals(socket) or not _valid_intervals(core): return {"ready": false, "reason": "invalid_socket_volume"}
		core_fit = core_fit and _contains_intervals(core, socket)
		# Full original facade X thickness joins the finite socket. Y/Z remain
		# exactly the required socket extents: no full-depth strip along the span.
		var desired: Array = socket.duplicate()
		desired[0] = minf(desired[0], body.bounds[0])
		desired[3] = maxf(desired[3], body.bounds[3])
		var connection: Dictionary = _obs_box_from_bounds("end_connection:" + gable.id, desired)
		pieces.append(connection)
		exclusions.append(gable.id)
		sockets.append({"seatId": gable.id, "requiredFact": fact, "requiredBounds": socket, "actualCoreBounds": core, "connectionDesiredBounds": desired, "connectionRepresentedBounds": connection.bounds})
		# Deeper Y/Z must remain in the actual finite masonry core; represented
		# X must not extend beyond the source/socket-derived connection limits.
		core_fit = core_fit and connection.bounds[1] >= core[1] and connection.bounds[4] <= core[4] and connection.bounds[2] >= core[2] and connection.bounds[5] <= core[5] and connection.bounds[0] >= desired[0] and connection.bounds[3] <= desired[3]
	var socket_proofs: Array = []
	for socket: Dictionary in sockets: socket_proofs.append(_head_cover(socket.requiredBounds, pieces))
	var outer_proof: Dictionary = _head_cover(body.bounds, pieces)
	var faces: Array = [float(panel.position.x) - float(panel.size.x) * 0.5, float(panel.position.x) + float(panel.size.x) * 0.5]
	return {"ready": true, "house": proposal.house, "headerId": header.id, "pieces": pieces, "requiredSockets": sockets, "socketCoverage": socket_proofs,
		"originalFacadeXPlanes": faces, "preservesExteriorBand": outer_proof.covered and body.bounds[0] == faces[0] and body.bounds[3] == faces[1],
		"containsCompleteSocketRegions": socket_proofs.all(func(p): return p.covered), "connectionsWithinSocketCoreLimits": core_fit,
		"connectedComponents": _obs_components(pieces), "removedOriginalCells": removed, "excludedIds": exclusions, "exclusionPolicy": "Only this proposal's original seven trimmed panels and its two declared gables; no whole-house exemption."}

func _obs_box_from_bounds(id: String, bounds: Array) -> Dictionary:
	var center: Vector3 = Vector3((bounds[0] + bounds[3]) * 0.5, (bounds[1] + bounds[4]) * 0.5, (bounds[2] + bounds[5]) * 0.5)
	var size: Vector3 = Vector3(bounds[3] - bounds[0], bounds[4] - bounds[1], bounds[5] - bounds[2])
	var pose: Transform3D = Transform3D(Basis.IDENTITY, center)
	return {"id": id, "pose": pose, "size": size, "rotation": Vector3.ZERO, "bounds": _head_local_bounds(pose, Vector3.ZERO, size * 0.5)}

func _obs_components(pieces: Array) -> int:
	var unseen: Array = range(pieces.size())
	var count: int = 0
	while not unseen.is_empty():
		count += 1
		var queue: Array = [unseen.pop_back()]
		while not queue.is_empty():
			var index: int = queue.pop_back()
			for other: int in unseen.duplicate():
				if _head_intersects(pieces[index].bounds, pieces[other].bounds):
					unseen.erase(other)
					queue.append(other)
	return count # Positive-volume connectivity; a touching-only join is not certified.

func _obs_controls() -> bool:
	var a: Dictionary = _obs_box_from_bounds("synthetic_a", [-0.5, -0.5, -0.5, 0.5, 0.5, 0.5])
	var separate: Dictionary = _obs_box_from_bounds("synthetic_separate", [1.0, -0.5, -0.5, 2.0, 0.5, 0.5])
	var touch: Dictionary = _obs_box_from_bounds("synthetic_touch", [0.5, -0.5, -0.5, 1.5, 0.5, 0.5])
	var shear: Dictionary = {"id": "synthetic_shear", "pose": Transform3D(Basis(Vector3(1, 0.25, 0), Vector3.UP, Vector3.BACK), Vector3.ZERO), "size": Vector3.ONE, "rotation": Vector3.ZERO}
	return _obs_sat(a, separate).strictlySeparated and _obs_sat(a, touch).rawSignedGap == 0.0 and not _obs_sat(a, touch).strictlySeparated and _obs_sat(a, shear).rawPenetration and ClearancePlan.digest(_obs_sat(a, shear)) == ClearancePlan.digest(_obs_sat(a, shear))

func _obs_finish(path: String, report: Dictionary, status: String) -> void:
	var complete: bool = status == "measurement_complete" and _within_budget() and not _obs_checks.is_empty() and _obs_checks.values().all(func(v): return v == true)
	var fit: bool = complete and report.get("allHypothesesFit", false)
	report.merge({"diagnosticCompleted": complete, "passed": fit, "status": status, "stopReason": _stop_reason, "checks": _obs_checks, "satPairCount": _obs_pairs,
		"elapsedMsec": Time.get_ticks_msec() - _started_msec, "passMeaning": "Measured source-only hypothesis fit, never recipe or publication acceptance; no-fit remains RED even when diagnosticCompleted is true."})
	var bytes: PackedByteArray = JSON.stringify(_obs_json(report), "  ").to_utf8_buffer()
	if bytes.size() > 32 * 1024 * 1024 or FileAccess.file_exists(path):
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
	quit(0 if fit and written else 2)

func _obs_json(value: Variant) -> Variant:
	if value is Vector3: return [value.x, value.y, value.z]
	if value is Transform3D: return {"origin": _obs_json(value.origin), "basisColumns": [_obs_json(value.basis.x), _obs_json(value.basis.y), _obs_json(value.basis.z)]}
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value: result[key] = _obs_json(value[key])
		return result
	if value is Array: return value.map(_obs_json)
	return value
