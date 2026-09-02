extends "res://scripts/testing/buildings/CitadelOpeningHeadConnectionContract.gd"

const Replacement = preload("res://scripts/buildings/OpeningHeadReplacementAdmission.gd")

func _run() -> void:
	var path := OS.get_environment("VOXEL_HEAD_SHARED_WALL_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var archive := _clearance_read(CANDIDATE_PATH, CANDIDATE_SHA)
	if archive.is_empty():
		quit(2)
		return
	var before = HeadCopy.copy_blueprint(archive.beforeSnapshot)
	var staged = HeadCopy.copy_blueprint(archive.afterSnapshot)
	for proposal: Dictionary in archive.houseProposals:
		for id: String in proposal.trimmedPanelIds:
			var part = staged.find_part(id)
			var fit := BandRecipe.fit_retained_panel(before.find_part(id), part)
			if not fit.ready:
				quit(2)
				return
			part.position = fit.position
			part.size = fit.size
	var proposal: Dictionary = archive.houseProposals.filter(func(p): return p.house == "urban_row_03_left")[0]
	var old_header = staged.find_part(proposal.headerId)
	var gables: Array = old_header.recipe.physicalRequiredSeatPartIds.map(func(id): return before.find_part(id))
	var facade = before.find_part(proposal.trimmedPanelIds[0])
	var retained: Array = proposal.trimmedPanelIds.map(func(id): return staged.find_part(id))
	var foreign: Array = before.parts.filter(func(p): return p.collision_enabled and not proposal.trimmedPanelIds.has(p.id) and not gables.any(func(g): return g.id == p.id))
	var frozen := ClearancePlan.digest([before.snapshot(), staged.snapshot(), archive])
	var arrangement := Connections.prepare(old_header.snapshot(), facade, gables, foreign, retained, before)
	var checks := {"mixed_arrangement_prepared": arrangement.ready}
	checks["construction_does_not_mutate_any_input"] = frozen == ClearancePlan.digest([before.snapshot(), staged.snapshot(), archive])
	var report := {"passed": false, "checks": checks, "arrangement": arrangement, "seed": archive.fixture.seed, "scale": archive.fixture.citadelScale,
		"house": proposal.house, "evidenceLevel": "one_actual_shared_wall_mixed_joint_source_contract",
		"limitations": "Source construction, independent physical load paths, mandatory dependency controls and collision-occupancy admission only. No published finite joints, rendered concealment, new seam visual acceptance, full-batch grammar acceptance, normal-world integration or gate-zero."}
	if arrangement.ready:
		var adopted: Dictionary = arrangement.directSeats[0]
		var unrooted = HeadCopy.copy_blueprint(before.snapshot())
		var foundation_ids: Array = adopted.rootProof.independentMemberIds.filter(func(id): return before.find_part(id).kind == "foundation")
		unrooted.parts = unrooted.parts.filter(func(p): return not foundation_ids.has(p.id))
		for id: String in foundation_ids: unrooted.physical_parts_by_id.erase(id)
		var unrooted_result := Connections.prepare(old_header.snapshot(), facade, gables, foreign, retained, unrooted)
		checks["adopted_masonry_requires_actual_ground_roots"] = not foundation_ids.is_empty() and not unrooted_result.ready
		report["unrootedCandidateControl"] = {"removedFoundationIds": foundation_ids, "result": unrooted_result}
		var mismatched = HeadCopy.copy_blueprint(before.snapshot())
		mismatched.find_part(adopted.fact.seatId).material_id = "timber_beam"
		var mismatched_result := Connections.prepare(old_header.snapshot(), facade, gables, foreign, retained, mismatched)
		checks["adopted_source_material_mismatch_rejected"] = not mismatched_result.ready
		report["mismatchedSourceControl"] = mismatched_result
		var wrong_kind = HeadCopy.copy_blueprint(before.snapshot())
		wrong_kind.find_part(adopted.fact.seatId).kind = "floor"
		checks["adopted_source_kind_mismatch_rejected"] = not Connections.prepare(old_header.snapshot(), facade, gables, foreign, retained, wrong_kind).ready
		var walking = HeadCopy.copy_blueprint(before.snapshot())
		walking.find_part(adopted.fact.seatId).physical_intent = "walkable_surface"
		walking.find_part(adopted.fact.seatId).recipe.physicalIntent = "walkable_surface"
		checks["walkable_surface_not_adopted_as_masonry_mass"] = not Connections.prepare(old_header.snapshot(), facade, gables, foreign, retained, walking).ready
		for proposed: Dictionary in arrangement.connections + [arrangement.body]:
			var contaminated = HeadCopy.copy_blueprint(before.snapshot())
			var added = contaminated.add_part(proposed)
			contaminated.physical_parts_by_id[added.id] = added
			var rejected := Connections.prepare(old_header.snapshot(), facade, gables, foreign, retained, contaminated)
			checks["proposed_framing_not_used_as_root:" + proposed.id] = not rejected.ready and rejected.get("directSeatFailure", {}).get("reason", "") == "proposed_framing_in_support_source"
		checks["one_direct_seat_and_one_real_end_block"] = arrangement.directSeats.size() == 1 and arrangement.connections.size() == 1 and arrangement.body.recipe.physicalRequiredSeatFacts.size() == 2
		checks["repeat_exact"] = ClearancePlan.digest(arrangement) == ClearancePlan.digest(Connections.prepare(old_header.snapshot(), facade, gables, foreign, retained, before))
		var reverse := foreign.duplicate()
		reverse.reverse()
		checks["foreign_order_independent"] = ClearancePlan.digest(arrangement) == ClearancePlan.digest(Connections.prepare(old_header.snapshot(), facade, gables, reverse, retained, before))
		var membership := HeadCopy.street_house_memberships(before)
		var house: Dictionary = membership.houses.filter(func(h): return h.prefix == proposal.house)[0]
		var included: Array = house.memberIds.duplicate()
		for direct: Dictionary in arrangement.directSeats:
			for id: String in direct.rootProof.independentMemberIds:
				if not included.has(id): included.append(id)
		included.sort()
		var independent = HeadCopy.Blueprint.new("mixed_joint_independent_owners", before.seed, before.style)
		for id: String in included:
			var part = before.find_part(id)
			if part.semantic != "citadel_urban_facade": independent.add_part(part.snapshot())
		var terminal_ids: Array = arrangement.directSeats.map(func(d): return d.fact.seatId)
		for record: Dictionary in arrangement.connections: terminal_ids.append_array(record.recipe.physicalRequiredSeatPartIds)
		HeadCopy.clear_caches(independent)
		var root_report: Dictionary = independent.validate_physical_integrity()
		var terminal_checks: Array = root_report.checks.filter(func(c): return terminal_ids.has(c.partId))
		checks["both_terminal_seats_root_without_facades_or_new_framing"] = terminal_checks.size() == 2 and terminal_checks.all(func(c): return c.passed and c.reachesGroundRoot)
		report["independentRootChecks"] = terminal_checks
		for record: Dictionary in arrangement.connections + [arrangement.body]: independent.add_part(record)
		for part in retained: independent.add_part(part.snapshot())
		HeadCopy.clear_caches(independent)
		var physical: Dictionary = independent.validate_physical_integrity()
		var new_ids: Array = arrangement.connections.map(func(c): return c.id) + [arrangement.body.id]
		var expected: Array = new_ids + proposal.trimmedPanelIds
		var local_checks: Array = physical.checks.filter(func(c): return expected.has(c.partId))
		checks["mixed_members_and_all_seven_trims_pass"] = local_checks.size() == 9 and local_checks.all(func(c): return c.passed)
		report["assemblyChecks"] = local_checks
		var sockets: Array = []
		for id: String in new_ids:
			var part = independent.find_part(id)
			for fact: Dictionary in part.recipe.physicalRequiredSeatFacts:
				sockets.append({"partId": id, "seatId": fact.seatId, "geometry": independent.housed_overlap_diagnostics(part, independent.find_part(fact.seatId), fact)})
		checks["three_complete_finite_joints"] = sockets.size() == 3 and sockets.all(func(s): return s.geometry.insideBearer and s.geometry.insideSeat and s.geometry.rootedSeat and s.geometry.longitudinalEmbedment >= 0.12 and s.geometry.verticalOverlap >= 0.04)
		report["socketGeometry"] = sockets
		var positive := independent.snapshot()
		var breaks: Array = []
		for missing_id: String in terminal_ids + arrangement.connections.map(func(c): return c.id):
			var broken = HeadCopy.copy_blueprint(positive)
			broken.parts = broken.parts.filter(func(p): return p.id != missing_id)
			HeadCopy.clear_caches(broken)
			var bad: Dictionary = broken.validate_physical_integrity()
			var rejected: Array = bad.checks.filter(func(c): return ([arrangement.body.id] + proposal.trimmedPanelIds).has(c.partId))
			checks["required_member_removal_rejects_body_and_trims:" + missing_id] = rejected.size() == 8 and rejected.all(func(c): return not c.passed)
			breaks.append({"missingId": missing_id, "dependentChecks": rejected})
		report["dependencyBreaks"] = breaks
		checks["breaks_do_not_mutate_positive"] = ClearancePlan.digest(positive) == ClearancePlan.digest(independent.snapshot())
		var apertures: Array = []
		for declaration: Dictionary in before.recipe.facadeApertures.values():
			for opening: Dictionary in declaration.openings: apertures.append(opening.fullVolume)
		var body_proof := Replacement.evaluate(before, staged, arrangement.body, proposal.trimmedPanelIds, [], apertures)
		checks["body_source_occupancy_admitted"] = body_proof.ready
		checks["adopted_wall_has_no_broad_contact_exemption"] = body_proof.ready and body_proof.contacts.any(func(c): return c.peerId == adopted.fact.seatId)
		report["bodyOccupancy"] = body_proof
		var end_proofs: Array = []
		for record: Dictionary in arrangement.connections: end_proofs.append(BandRecipe._foreign_solid_admission(before, record, proposal.trimmedPanelIds, gables.map(func(g): return g.id)))
		checks["actual_new_end_avoids_foreign_solids"] = end_proofs.size() == 1 and end_proofs.all(func(p): return p.ready)
		report["endAdmissions"] = end_proofs
		var baseline = HeadCopy.copy_blueprint(archive.afterSnapshot)
		HeadCopy.clear_caches(baseline)
		var baseline_failed: Array = HeadCopy.failed_ids(baseline.validate_physical_integrity())
		for index in range(staged.parts.size()):
			if staged.parts[index].id == arrangement.body.id: staged.parts[index] = HeadCopy.Blueprint.BuildingPartScript.new(arrangement.body)
		for record: Dictionary in arrangement.connections: staged.add_part(record)
		HeadCopy.clear_caches(staged)
		var full: Dictionary = staged.validate_physical_integrity()
		var actual_failed: Array = HeadCopy.failed_ids(full)
		checks["exact_full_source_failure_ids_unchanged"] = actual_failed == baseline_failed
		report["beforeFailedIds"] = baseline_failed
		report["afterFailedIds"] = actual_failed
	checks["original_inputs_still_immutable"] = ClearancePlan.digest([before.snapshot(), archive]) == ClearancePlan.digest([HeadCopy.copy_blueprint(archive.beforeSnapshot).snapshot(), archive]) and FileAccess.get_sha256(CANDIDATE_PATH) == CANDIDATE_SHA
	report["inputFreezeBeforeConstruction"] = frozen
	report["elapsedMsec"] = Time.get_ticks_msec() - started
	report.passed = checks.values().all(func(c): return c == true)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_obs_json(report), "  "))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	quit(0 if report.passed and written else 2)
