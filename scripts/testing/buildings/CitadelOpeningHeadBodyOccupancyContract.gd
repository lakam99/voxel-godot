extends "res://scripts/testing/buildings/CitadelOpeningHeadConnectionContract.gd"

const Occupancy = preload("res://scripts/buildings/ReplacementBoxOccupancy.gd")
const SourceAdmission = preload("res://scripts/buildings/ConstructionBoxAdmission.gd")
const ReplacementAdmission = preload("res://scripts/buildings/OpeningHeadReplacementAdmission.gd")

func _run() -> void:
	var path := OS.get_environment("VOXEL_OPENING_HEAD_BODY_OCCUPANCY_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var archive := _clearance_read(CANDIDATE_PATH, CANDIDATE_SHA)
	if archive.is_empty():
		quit(2)
		return
	var before = HeadCopy.copy_blueprint(archive.beforeSnapshot)
	var after = HeadCopy.copy_blueprint(archive.afterSnapshot)
	# Replay the current shared trim-fit rule on the private historical candidate.
	# Input archive remains immutable; this is actual new recipe construction.
	var fitted_trims: Array = []
	for proposal: Dictionary in archive.houseProposals:
		for id: String in proposal.trimmedPanelIds:
			var panel = after.find_part(id)
			var fit := BandRecipe.fit_retained_panel(before.find_part(id), panel)
			if not fit.ready:
				quit(2)
				return
			if panel.position != fit.position or panel.size != fit.size: fitted_trims.append({"id": id, "before": panel.snapshot(), "fit": fit})
			panel.position = fit.position
			panel.size = fit.size
	var frozen := ClearancePlan.digest([archive, before.snapshot(), after.snapshot()])
	var rows: Array = []
	var checks: Dictionary = {}
	var tested := 0
	var apertures: Array = []
	var declarations_valid := true
	for key: String in before.recipe.facadeApertures:
		var declaration: Dictionary = before.recipe.facadeApertures[key]
		declarations_valid = declarations_valid and BandRecipe.Aperture.validate(declaration, before.physical_parts_by_id)
		for opening: Dictionary in declaration.openings: apertures.append(opening.fullVolume)
	for proposal: Dictionary in archive.houseProposals:
		var header = after.find_part(proposal.headerId)
		var facade = before.find_part(proposal.trimmedPanelIds[0])
		var old_boxes: Array = []
		var retained: Array = []
		for id: String in proposal.trimmedPanelIds:
			var old = before.find_part(id)
			var new = after.find_part(id)
			if old.rotation != Vector3.ZERO or new.rotation != Vector3.ZERO:
				quit(2)
				return
			old_boxes.append(Connections._bounds(old))
			retained.append(Connections._bounds(new))
		var removed := Occupancy.removed(old_boxes, retained)
		var fitted := Connections.fit_body(header.snapshot(), facade, proposal.trimmedPanelIds.map(func(id): return after.find_part(id)))
		if not fitted.ready:
			quit(2)
			return
		var body := HeadCopy.Blueprint.BuildingPartScript.new(fitted.body)
		var body_bounds: Array = Connections._bounds(body)
		var body_pose := Transform3D(Basis.from_scale(body.size), body.position)
		var replacement_proof := ReplacementAdmission.evaluate(before, after, body.snapshot(), proposal.trimmedPanelIds, header.recipe.physicalRequiredSeatPartIds, apertures)
		var exclusions: Array = proposal.trimmedPanelIds + header.recipe.physicalRequiredSeatPartIds
		var contacts: Array = []
		var count := 0
		for peer in before.parts:
			if not peer.collision_enabled or exclusions.has(peer.id): continue
			count += 1
			tested += 1
			var peer_pose: Transform3D = before.part_transform(peer) * Transform3D(Basis.from_scale(peer.size), Vector3.ZERO)
			var measured := SourceAdmission.measure(body_pose, peer_pose)
			if measured.valid and measured.clear: continue
			var peer_bounds: Array = _body_bounds(peer_pose)
			var overlap := Occupancy.intersection(body_bounds, peer_bounds)
			var prior := Occupancy.cover(overlap, removed.cells) if removed.ready and not overlap.is_empty() else {"ready": false, "covered": false, "reason": "unresolved_overlap"}
			contacts.append({"peerId": peer.id, "measurement": measured, "peerBounds": peer_bounds, "peerRotation": peer.rotation,
				"overlapEnvelope": overlap, "priorRemovedCoverage": prior,
				"occupancyClass": "preexisting_source_overlap_retained" if prior.covered else "new_or_unresolved_source_occupancy"})
		rows.append({"house": proposal.house, "headerId": header.id, "body": body.snapshot(), "bodyBounds": body_bounds, "bodyFit": fitted.boundsEvidence,
			"replacementOccupancyAdmission": replacement_proof,
			"originalPanelBoxes": old_boxes, "retainedPanelBoxes": retained, "removed": removed,
			"testedForeignCount": count, "expectedForeignCount": before.parts.filter(func(p): return p.collision_enabled and not exclusions.has(p.id)).size(),
			"contacts": contacts, "allContactsRetainOnlyOldOccupancy": removed.ready and contacts.all(func(c): return c.priorRemovedCoverage.covered)})
		await process_frame
	checks["all16_complete"] = rows.size() == 16 and rows.all(func(r): return r.testedForeignCount == r.expectedForeignCount and r.removed.ready)
	checks["all_source_measurements_valid"] = rows.all(func(r): return r.contacts.all(func(c): return c.measurement.valid))
	checks["caller_immutable"] = frozen == ClearancePlan.digest([archive, before.snapshot(), after.snapshot()])
	checks["archive_bound"] = FileAccess.get_sha256(CANDIDATE_PATH) == CANDIDATE_SHA
	checks["protected_apertures_authoritatively_bound"] = declarations_valid and not apertures.is_empty()
	checks["bounded_work"] = tested <= 160000 and Time.get_ticks_msec() - started < 60000
	var complete := checks.values().all(func(c): return c == true)
	var all_old := rows.all(func(r): return r.allContactsRetainOnlyOldOccupancy)
	var all_admitted := rows.all(func(r): return r.replacementOccupancyAdmission.ready)
	var report := {"diagnosticCompleted": complete, "passed": complete and all_admitted, "checks": checks, "houses": rows,
		"retainedFitChanges": fitted_trims,
		"allSourceReplacementAdmissionsPass": all_admitted, "passMeaning": "Bounded source-only replacement occupancy and declared-seam world-nonregression; NOT collision-clear, hidden rendered seam, full assembly, integration or live acceptance.",
		"seed": archive.fixture.seed, "scale": archive.fixture.citadelScale, "candidateSha256": CANDIDATE_SHA,
		"elapsedMsec": Time.get_ticks_msec() - started, "pairCount": tested, "allBodyContactsRetainOnlyOldOccupancy": all_old,
		"evidenceLevel": "exhaustive_shallow_body_source_box_replacement_occupancy_measurement",
		"limitations": "Complete original foreign-collider inventory; conservative envelope coverage for rotated intersections is sufficient only when wholly covered. No rotated occupancy absence claim, render preservation, new connection proof, structural acceptance, normal generation integration or gameplay acceptance. Prior occupancy is never clear or a bearing. No source changed."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_obs_json(report), "  "))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	quit(0 if report.passed and written else 2)

func _body_bounds(pose: Transform3D) -> Array:
	var radius: Array = []
	var bounds: Array = []
	for axis in range(3):
		var extent := 0.0
		for column in range(3): extent += absf(float(pose.basis[column][axis])) * 0.5
		radius.append(extent)
		bounds.append(float(pose.origin[axis]) - extent)
	for axis in range(3): bounds.append(float(pose.origin[axis]) + radius[axis])
	return bounds
