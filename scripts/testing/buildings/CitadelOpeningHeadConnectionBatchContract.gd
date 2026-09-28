extends "res://scripts/testing/buildings/CitadelOpeningHeadConnectionContract.gd"

## Source-only diagnostic. Rejected houses retain the historical deep header in
## the measurement copy; that is NOT an accepted fallback construction.
const BatchAdmission = preload("res://scripts/buildings/ConstructionBoxAdmission.gd")
const ReplacementAdmission = preload("res://scripts/buildings/OpeningHeadReplacementAdmission.gd")
const BATCH_HOUSES := 16
const BATCH_REPORT_CAP := 32 * 1024 * 1024

func _run() -> void:
	_started_msec = Time.get_ticks_msec()
	_next_progress_msec = _started_msec + 10000
	var path: String = OS.get_environment("VOXEL_OPENING_HEAD_CONNECTION_BATCH_REPORT")
	if not path.is_absolute_path() or path.get_extension() != "json" or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var checks: Dictionary = {}
	var rows: Array = []
	var report: Dictionary = {"evidenceLevel": "all16_actual_house_source_connection_diagnostic", "candidateSha256": CANDIDATE_SHA,
		"originalSha256": ORIGINAL_SHA, "measurementChecks": checks, "houses": rows, "fullBatchValidationCount": 0, "baselineValidationCount": 0,
		"limitations": "Source Part collision boxes and shared physical joints only. No published meshes/materials, furniture, door sweeps, GPU, live gameplay or gate-zero acceptance. Rejected houses retain historical headers ONLY in the diagnostic copy. Existing unrelated physical failures are reported exactly, not required to equal historical 123. No occupancy or whole-house exceptions."}
	var archive: Dictionary = _clearance_read(CANDIDATE_PATH, CANDIDATE_SHA)
	var original: Dictionary = _clearance_read(ORIGINAL_PATH, ORIGINAL_SHA)
	if archive.is_empty() or original.is_empty():
		_batch_finish(path, report, "invalid_bound_inputs")
		return
	var before = HeadCopy.copy_blueprint(original.afterSnapshot)
	var candidate = HeadCopy.copy_blueprint(archive.afterSnapshot)
	var staged = HeadCopy.copy_blueprint(archive.afterSnapshot)
	var fit_changes: Array = []
	for proposal: Dictionary in archive.houseProposals:
		for id: String in proposal.trimmedPanelIds:
			for target in [candidate, staged]:
				var panel = target.find_part(id)
				var fit := BandRecipe.fit_retained_panel(before.find_part(id), panel)
				if not fit.ready:
					_batch_finish(path, report, "retained_fit_rejected")
					return
				if target == candidate and (panel.position != fit.position or panel.size != fit.size): fit_changes.append({"id": id, "before": panel.snapshot(), "fit": fit})
				panel.position = fit.position
				panel.size = fit.size
	# The publication source binding changes with actual trimmed geometry.
	for target in [candidate, staged]:
		for key: String in target.recipe.facadeApertures:
			var declaration: Dictionary = target.recipe.facadeApertures[key].duplicate(true)
			declaration.erase("sourceBinding")
			target.recipe.facadeApertures[key] = BandRecipe.Aperture.seal(declaration, declaration.partIds.map(func(id): return target.find_part(id)))
	checks["candidate_aperture_bindings_resealed"] = [candidate, staged].all(func(target): return target.recipe.facadeApertures.values().all(func(declaration): return BandRecipe.Aperture.validate(declaration, target.physical_parts_by_id)))
	report["retainedFitChanges"] = fit_changes
	var protected: Array = []
	var declarations_valid := true
	for key: String in before.recipe.facadeApertures:
		var declaration: Dictionary = before.recipe.facadeApertures[key]
		declarations_valid = declarations_valid and BandRecipe.Aperture.validate(declaration, before.physical_parts_by_id)
		for opening: Dictionary in declaration.openings: protected.append(opening.fullVolume)
	checks["protected_apertures_bound"] = declarations_valid and not protected.is_empty()
	var frozen: String = ClearancePlan.digest([archive, original, before.snapshot(), candidate.snapshot()])
	checks["original_snapshot_exact"] = ClearancePlan.digest(archive.beforeSnapshot) == ClearancePlan.digest(original.afterSnapshot)
	var membership: Dictionary = HeadCopy.street_house_memberships(before)
	var proposals: Array = archive.get("houseProposals", [])
	checks["sixteen_source_houses"] = membership.get("ready", false) and membership.get("houses", []).size() == BATCH_HOUSES and proposals.size() == BATCH_HOUSES
	if not checks.original_snapshot_exact or not checks.sixteen_source_houses:
		_batch_finish(path, report, "invalid_source_membership")
		return
	var by_house: Dictionary = {}
	for house: Dictionary in membership.houses: by_house[house.prefix] = house
	var seen: Dictionary = {}
	var trim_seen: Dictionary = {}
	var required_ids: Array = []
	var admitted_pieces: Array = []
	var proposals_sorted: Array = proposals.duplicate(true)
	proposals_sorted.sort_custom(func(a, b): return String(a.house) < String(b.house))
	for proposal: Dictionary in proposals_sorted:
		if not _within_budget(): break
		var house_id: String = String(proposal.get("house", ""))
		var row: Dictionary = {"house": house_id, "fit": false, "measured": false, "reasons": []}
		rows.append(row)
		if not by_house.has(house_id) or seen.has(house_id):
			row.reasons.append("missing_or_duplicate_house_membership")
			continue
		seen[house_id] = true
		var house: Dictionary = by_house[house_id]
		var header = candidate.find_part(String(proposal.get("headerId", "")))
		var trim_ids: Array = proposal.get("trimmedPanelIds", [])
		var valid: bool = header != null and trim_ids.size() == 7
		for id: String in trim_ids:
			valid = valid and house.memberIds.has(id) and before.find_part(id) != null and candidate.find_part(id) != null and not trim_seen.has(id)
			trim_seen[id] = true
		if not valid:
			row.reasons.append("invalid_header_or_trim_membership")
			continue
		var seat_ids: Array = header.recipe.get("physicalRequiredSeatPartIds", [])
		var gables: Array = []
		for id: String in seat_ids: gables.append(before.find_part(id))
		if seat_ids.size() != 2 or seat_ids[0] == seat_ids[1] or gables.has(null) or not seat_ids.all(func(id): return house.memberIds.has(id)):
			row.reasons.append("invalid_declared_gables")
			continue
		var obstacles: Array = []
		for part in before.parts:
			if part.collision_enabled and not trim_ids.has(part.id) and not seat_ids.has(part.id): obstacles.append(part)
		var facade = before.find_part(trim_ids[0])
		var retained: Array = trim_ids.map(func(id): return candidate.find_part(id))
		var arrangement: Dictionary = Connections.prepare(header.snapshot(), facade, gables, obstacles, retained, before)
		var repeat: Dictionary = Connections.prepare(header.snapshot(), facade, gables, obstacles, retained, before)
		var reversed: Array = obstacles.duplicate()
		reversed.reverse()
		var reverse_result: Dictionary = Connections.prepare(header.snapshot(), facade, gables, reversed, retained, before)
		row.merge({"measured": true, "headerId": header.id, "trimmedPanelIds": trim_ids, "declaredGableIds": seat_ids,
			"excludedOriginalIds": trim_ids + seat_ids, "originalColliderCount": obstacles.size(),
			"originalColliderOrderSHA": ClearancePlan.digest(obstacles.map(func(p): return p.id)), "arrangement": arrangement,
			"repeatExact": ClearancePlan.digest(arrangement) == ClearancePlan.digest(repeat),
			"reversedObstaclesExact": ClearancePlan.digest(arrangement) == ClearancePlan.digest(reverse_result)}, true)
		if not arrangement.get("ready", false):
			row.reasons.append(arrangement.get("reason", "recipe_not_ready_without_reason"))
			continue
		var pieces: Array = [arrangement.body] + arrangement.connections
		var admissions: Array = []
		for record: Dictionary in pieces:
			var admission: Dictionary = ReplacementAdmission.evaluate(before, candidate, record, trim_ids, [], protected) if record.id == arrangement.body.id else BandRecipe._foreign_solid_admission(before, record, trim_ids, seat_ids)
			if record.id == arrangement.body.id and admission.ready: admission["testedSolidCount"] = admission.testedForeignCount
			admission["expectedSolidCount"] = obstacles.size() + seat_ids.size() if record.id == arrangement.body.id else obstacles.size()
			admission["partId"] = record.id
			admissions.append(admission)
		row["sourceAdmissions"] = admissions
		row["completeDeclaredFraming"] = arrangement.connections.size() + arrangement.directSeats.size() == 2 and arrangement.body.recipe.physicalRequiredSeatFacts.size() == 2 and pieces.size() == 3 - arrangement.directSeats.size()
		row["allPiecesAdmitted"] = row.completeDeclaredFraming and admissions.all(func(a): return a.ready and a.testedSolidCount == a.expectedSolidCount)
		if not row.allPiecesAdmitted: row.reasons.append("piece_source_occupancy_admission_rejected")
		# Only this house's original, non-facade support closure. Never validate
		# the entire world inside the house loop or let panels root their gables.
		var independent = HeadCopy.Blueprint.new("source_connection_" + house_id, before.seed, before.style)
		var independent_ids: Array = house.memberIds.duplicate()
		var root_ids: Array = seat_ids.duplicate()
		for direct: Dictionary in arrangement.directSeats:
			if not root_ids.has(direct.fact.seatId): root_ids.append(direct.fact.seatId)
			for id: String in direct.rootProof.independentMemberIds:
				if not independent_ids.has(id): independent_ids.append(id)
		independent_ids.sort()
		for id: String in independent_ids:
			var part = before.find_part(id)
			if part.semantic not in ["citadel_urban_facade", "citadel_opening_head_band", "citadel_opening_head_connection"]: independent.add_part(part.snapshot())
		HeadCopy.clear_caches(independent)
		var root_work: Dictionary = HeadCopy.validation_grid_work(independent)
		if not root_work.ready:
			row.measured = false
			row.reasons.append(root_work.reason)
			continue
		var root_report: Dictionary = independent.validate_physical_integrity()
		var root_checks: Array = root_report.checks.filter(func(c): return root_ids.has(c.partId))
		row["independentGableChecks"] = root_checks
		row["independentRootFailureIds"] = HeadCopy.failed_ids(root_report)
		row["gablesIndependentlyRooted"] = _batch_checks_cover(root_checks, root_ids) and root_checks.all(func(c): return c.passed and c.reachesGroundRoot)
		for record: Dictionary in arrangement.connections + [arrangement.body]: independent.add_part(record)
		for id: String in trim_ids: independent.add_part(candidate.find_part(id).snapshot())
		HeadCopy.clear_caches(independent)
		var joint_report: Dictionary = independent.validate_physical_integrity()
		var piece_ids: Array = pieces.map(func(p): return p.id)
		var local_ids: Array = piece_ids + trim_ids
		var joint_checks: Array = joint_report.checks.filter(func(c): return local_ids.has(c.partId))
		var sockets: Array = []
		for id: String in piece_ids:
			var bearer = independent.find_part(id)
			for fact: Dictionary in bearer.recipe.get("physicalRequiredSeatFacts", []):
				var seat = independent.find_part(String(fact.seatId))
				sockets.append({"partId": id, "seatId": fact.seatId, "geometry": independent.housed_overlap_diagnostics(bearer, seat, fact)})
		row["jointChecks"] = joint_checks
		row["independentJointFailureIds"] = HeadCopy.failed_ids(joint_report)
		row["finiteSockets"] = sockets
		row["jointsAndTrimsPass"] = local_ids.size() == 10 - arrangement.directSeats.size() and _batch_checks_cover(joint_checks, local_ids) and joint_checks.all(func(c): return c.passed)
		row["completeDeclaredSockets"] = sockets.size() == 2 + arrangement.connections.size() and sockets.all(func(s): return s.geometry.insideBearer and s.geometry.insideSeat and s.geometry.rootedSeat and s.geometry.longitudinalEmbedment >= 0.12 and s.geometry.verticalOverlap >= 0.04)
		if not row.gablesIndependentlyRooted or not row.jointsAndTrimsPass or not row.completeDeclaredSockets: row.reasons.append("independent_source_load_path_rejected")
		row.fit = row.allPiecesAdmitted and row.gablesIndependentlyRooted and row.jointsAndTrimsPass and row.completeDeclaredSockets and row.repeatExact and row.reversedObstaclesExact
		if not row.repeatExact or not row.reversedObstaclesExact: row.reasons.append("non_deterministic_recipe")
		if row.fit:
			for index in range(staged.parts.size()):
				if staged.parts[index].id == arrangement.body.id: staged.parts[index] = HeadCopy.Blueprint.BuildingPartScript.new(arrangement.body)
			for record: Dictionary in arrangement.connections: staged.add_part(record)
			required_ids.append_array(local_ids)
			for record: Dictionary in pieces: admitted_pieces.append({"house": house_id, "record": record})
		await process_frame
	checks["complete_house_coverage"] = seen.size() == BATCH_HOUSES and rows.size() == BATCH_HOUSES and rows.all(func(r): return r.measured)
	checks["complete_trim_coverage"] = trim_seen.size() == 112 and ClearancePlan.digest(_batch_sorted(trim_seen.keys())) == ClearancePlan.digest(_batch_sorted(archive.get("trimmedPanelIds", [])))
	checks["all_results_deterministic"] = rows.all(func(r): return r.get("repeatExact", false) and r.get("reversedObstaclesExact", false))
	# Original-world admission cannot detect simultaneous new/new overlaps.
	var cross_blocks: Array = []
	var cross_count: int = 0
	for i in range(admitted_pieces.size()):
		for j in range(i + 1, admitted_pieces.size()):
			var a: Dictionary = admitted_pieces[i]
			var b: Dictionary = admitted_pieces[j]
			if a.house == b.house: continue # All declared finite joints above own these contacts.
			var measured: Dictionary = BatchAdmission.measure(_batch_pose(a.record), _batch_pose(b.record))
			cross_count += 1
			if not measured.valid or not measured.clear: cross_blocks.append({"firstId": a.record.id, "secondId": b.record.id, "measurement": measured})
	report["crossHouseNewPiecePairs"] = cross_count
	report["crossHouseBlockers"] = cross_blocks
	# One fresh historical-candidate baseline, outside the house loop. Never
	# infer its failure set from the retired count or mutate the frozen caller.
	var baseline_failed: Array = []
	if _within_budget():
		var baseline = HeadCopy.copy_blueprint(archive.afterSnapshot)
		HeadCopy.clear_caches(baseline)
		var baseline_work: Dictionary = HeadCopy.validation_grid_work(baseline)
		report["baselineWork"] = baseline_work
		if baseline_work.ready:
			var baseline_physical: Dictionary = baseline.validate_physical_integrity()
			report.baselineValidationCount = 1
			baseline_failed = _batch_sorted(HeadCopy.failed_ids(baseline_physical))
			report["baselineFailedIds"] = baseline_failed
			report["baselineFailureChecks"] = baseline_physical.checks.filter(func(c): return not c.passed)
			checks["baseline_physical_checks_complete"] = _batch_checks_cover(baseline_physical.checks, baseline.parts.map(func(p): return p.id))
	if _within_budget():
		HeadCopy.clear_caches(staged)
		var work: Dictionary = HeadCopy.validation_grid_work(staged)
		report["fullBatchWork"] = work
		if work.ready:
			var physical: Dictionary = staged.validate_physical_integrity()
			report.fullBatchValidationCount = 1
			var changed: Array = physical.checks.filter(func(c): return required_ids.has(c.partId))
			var actual_failed: Array = _batch_sorted(HeadCopy.failed_ids(physical))
			report["fullBatchFailedIds"] = actual_failed
			checks["full_batch_physical_checks_complete"] = _batch_checks_cover(physical.checks, staged.parts.map(func(p): return p.id))
			if report.baselineValidationCount == 1:
				var added_failed: Array = actual_failed.filter(func(id): return not baseline_failed.has(id))
				var removed_failed: Array = baseline_failed.filter(func(id): return not actual_failed.has(id))
				report["addedFailureIds"] = added_failed
				report["removedFailureIds"] = removed_failed
				report["failedIdsExactBaseline"] = actual_failed == baseline_failed
				report["noNewPhysicalFailures"] = added_failed.is_empty()
			report["fullBatchFailureChecks"] = physical.checks.filter(func(c): return not c.passed)
			report["fullBatchViolations"] = physical.violations
			report["admittedSourceChecks"] = changed
			report["admittedSourceChecksPass"] = _batch_checks_cover(changed, required_ids) and changed.all(func(c): return c.passed)
			report["fullWorldPhysicalPassed"] = physical.passed
	checks["full_batch_measured_once"] = report.fullBatchValidationCount == 1
	checks["fresh_baseline_measured_once"] = report.baselineValidationCount == 1
	checks["caller_immutable"] = frozen == ClearancePlan.digest([archive, original, before.snapshot(), candidate.snapshot()])
	checks["files_still_bound"] = FileAccess.get_sha256(CANDIDATE_PATH) == CANDIDATE_SHA and FileAccess.get_sha256(ORIGINAL_PATH) == ORIGINAL_SHA
	report["admittedHouseCount"] = rows.filter(func(r): return r.fit).size()
	report["rejectedHouseIds"] = rows.filter(func(r): return not r.fit).map(func(r): return r.house)
	report["allHousesFit"] = rows.size() == BATCH_HOUSES and rows.all(func(r): return r.fit) and cross_blocks.is_empty() and report.get("admittedSourceChecksPass", false)
	_batch_finish(path, report, "measurement_complete" if _within_budget() else "budget_exceeded")

func _batch_sorted(values: Array) -> Array:
	var result: Array = values.duplicate()
	result.sort()
	return result

func _batch_checks_cover(physical_checks: Array, expected_ids: Array) -> bool:
	if physical_checks.size() != expected_ids.size(): return false
	var seen: Dictionary = {}
	for value: Variant in physical_checks:
		if not value is Dictionary or not value.get("partId") is String or not value.get("passed") is bool: return false
		if seen.has(value.partId) or not expected_ids.has(value.partId): return false
		seen[value.partId] = true
	return expected_ids.all(func(id): return seen.has(id))

func _batch_pose(record: Dictionary) -> Transform3D:
	return Transform3D(Basis.from_euler(record.get("rotation", Vector3.ZERO)) * Basis.from_scale(record.size), record.position)

func _batch_finish(path: String, report: Dictionary, status: String) -> void:
	var checks: Dictionary = report.measurementChecks
	report["diagnosticCompleted"] = status == "measurement_complete" and not checks.is_empty() and checks.values().all(func(v): return v == true)
	report["passed"] = report.diagnosticCompleted and report.get("allHousesFit", false) and report.get("noNewPhysicalFailures", false)
	report["status"] = status
	report["elapsedMsec"] = Time.get_ticks_msec() - _started_msec
	report["passMeaning"] = "Complete source-only all-house arrangement fit and no added physical failure IDs against one fresh baseline; never published/gameplay or zero-full-world-failures acceptance. Measurement completion alone cannot turn no-fit green."
	var bytes: PackedByteArray = JSON.stringify(_obs_json(report), "  ").to_utf8_buffer()
	if bytes.size() > BATCH_REPORT_CAP or FileAccess.file_exists(path):
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
	var hashing := HashingContext.new()
	written = written and hashing.start(HashingContext.HASH_SHA256) == OK
	if written:
		written = hashing.update(bytes) == OK
		if written: written = FileAccess.get_sha256(path) == hashing.finish().hex_encode()
	quit(0 if report.passed and written else 2)
