extends "res://scripts/testing/buildings/CitadelOpeningHeadObstructionContract.gd"

const Connections = preload("res://scripts/buildings/OpeningHeadConnectionRecipe.gd")

func _run() -> void:
	var path := OS.get_environment("VOXEL_OPENING_HEAD_CONNECTION_REPORT")
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
	var original := ClearancePlan.digest([before.snapshot(), staged.snapshot(), archive])
	var proposal: Dictionary = archive.houseProposals.filter(func(p): return p.house == "urban_row_00_left")[0]
	var old_header = staged.find_part(proposal.headerId)
	var gables: Array = old_header.recipe.physicalRequiredSeatPartIds.map(func(id): return before.find_part(id))
	var facade = before.find_part(proposal.trimmedPanelIds[0])
	var retained: Array = proposal.trimmedPanelIds.map(func(id): return staged.find_part(id))
	var foreign: Array = before.parts.filter(func(p): return p.collision_enabled and not proposal.trimmedPanelIds.has(p.id) and not gables.any(func(g): return g.id == p.id))
	var arrangement := Connections.prepare(old_header.snapshot(), facade, gables, foreign, retained)
	var checks: Dictionary = {"arrangement_prepared": arrangement.ready,
		"construction_caller_immutable": original == ClearancePlan.digest([before.snapshot(), staged.snapshot(), archive])}
	var report: Dictionary = {"passed": false, "evidenceLevel": "single_actual_house_three_piece_source_recipe_prototype", "seed": archive.fixture.seed, "scale": archive.fixture.citadelScale,
		"house": proposal.house, "checks": checks, "arrangement": arrangement,
		"limitations": "One actual house, source boxes and shared physical contract only. No actual mesh joints/materials, changed-panel clearance, neighbouring rendered geometry, full batch recipe integration, GPU, live play or gate-zero acceptance."}
	if arrangement.ready:
		checks["repeat_exact"] = ClearancePlan.digest(arrangement) == ClearancePlan.digest(Connections.prepare(old_header.snapshot(), facade, gables, foreign, retained))
		var reverse: Array = foreign.duplicate()
		reverse.reverse()
		checks["foreign_input_order_independent"] = ClearancePlan.digest(arrangement) == ClearancePlan.digest(Connections.prepare(old_header.snapshot(), facade, gables, reverse, retained))
		checks["body_top_below_all_retained_material"] = retained.all(func(p): return arrangement.bodyFit.represented[4] <= Connections._bounds(p)[1])
		checks["duplicate_retained_panel_rejected"] = not Connections.prepare(old_header.snapshot(), facade, gables, foreign, [retained[0], retained[0]]).ready
		var controls := _placement_controls(old_header.snapshot(), facade, gables, arrangement, retained)
		checks.merge(controls.checks)
		report["placementControls"] = controls
		var invalid: Dictionary = old_header.snapshot()
		invalid.size = Vector3.ZERO
		checks["invalid_body_rejected_not_clamped"] = not Connections.prepare(invalid, facade, gables).ready
		checks["duplicate_gable_rejected"] = not Connections.prepare(old_header.snapshot(), facade, [gables[0], gables[0]]).ready
		var exclusions: Array = proposal.trimmedPanelIds
		var seat_ids: Array = gables.map(func(g): return g.id)
		var admissions: Array = []
		for record: Dictionary in [arrangement.body] + arrangement.connections:
			admissions.append(BandRecipe._foreign_solid_admission(before, record, exclusions, seat_ids))
		checks["every_piece_avoids_foreign_colliders"] = admissions.all(func(a): return a.ready)
		report["sourceAdmissions"] = admissions
		var independent = HeadCopy.Blueprint.new("independent_connection_support", before.seed, before.style)
		var members: Dictionary = HeadCopy.street_house_memberships(before)
		var house: Dictionary = members.houses.filter(func(h): return h.prefix == proposal.house)[0]
		for id: String in house.memberIds:
			var part = before.find_part(id)
			if part.semantic != "citadel_urban_facade": independent.add_part(part.snapshot())
		var original_support: Dictionary = independent.validate_physical_integrity()
		checks["gables_independently_rooted"] = seat_ids.all(func(id): return original_support.checks.any(func(c): return c.partId == id and c.passed))
		for record: Dictionary in arrangement.connections + [arrangement.body]: independent.add_part(record)
		HeadCopy.clear_caches(independent)
		var supported: Dictionary = independent.validate_physical_integrity()
		var added_ids: Array = arrangement.connections.map(func(e): return e.id) + [arrangement.body.id]
		var joint_checks: Array = supported.checks.filter(func(c): return added_ids.has(c.partId))
		checks["three_piece_rooted_load_path"] = joint_checks.size() == 3 and joint_checks.all(func(c): return c.passed)
		report["independentJointChecks"] = joint_checks
		var geometry: Array = []
		for id: String in added_ids:
			var part = independent.find_part(id)
			for fact: Dictionary in part.recipe.physicalRequiredSeatFacts:
				var seat = independent.find_part(fact.seatId)
				geometry.append({"partId": id, "seatId": seat.id, "geometry": independent.housed_overlap_diagnostics(part, seat, fact)})
		report["finiteSocketGeometry"] = geometry
		checks["all_four_complete_finite_sockets"] = geometry.size() == 4 and geometry.all(func(row): return row.geometry.insideBearer and row.geometry.insideSeat and row.geometry.rootedSeat and row.geometry.longitudinalEmbedment >= 0.12 and row.geometry.verticalOverlap >= 0.04)
		var full_independent: Dictionary = independent.snapshot()
		var break_reports: Array = []
		for missing_id: String in seat_ids + arrangement.connections.map(func(e): return e.id):
			var missing = HeadCopy.copy_blueprint(full_independent)
			for trim_id: String in proposal.trimmedPanelIds: missing.add_part(staged.find_part(trim_id).snapshot())
			missing.parts = missing.parts.filter(func(p): return p.id != missing_id)
			HeadCopy.clear_caches(missing)
			var broken: Dictionary = missing.validate_physical_integrity()
			checks["lost_load_path_rejected:" + missing_id] = broken.checks.any(func(c): return c.partId == arrangement.body.id and not c.passed)
			var dependent: Array = broken.checks.filter(func(c): return proposal.trimmedPanelIds.has(c.partId))
			checks["dependent_trims_rejected:" + missing_id] = dependent.size() == 7 and dependent.all(func(c): return not c.passed)
			break_reports.append({"removedId": missing_id, "wholeAssemblyPassed": broken.passed, "dependentTrimChecks": dependent})
		report["loadPathBreakReports"] = break_reports
		checks["negative_controls_preserve_positive_source"] = ClearancePlan.digest(independent.snapshot()) == ClearancePlan.digest(full_independent)
		var baseline = HeadCopy.copy_blueprint(archive.afterSnapshot)
		HeadCopy.clear_caches(baseline)
		var baseline_failed: Array = HeadCopy.failed_ids(baseline.validate_physical_integrity())
		for index in range(staged.parts.size()):
			if staged.parts[index].id == arrangement.body.id: staged.parts[index] = HeadCopy.Blueprint.BuildingPartScript.new(arrangement.body)
		for record: Dictionary in arrangement.connections: staged.add_part(record)
		HeadCopy.clear_caches(staged)
		var physical: Dictionary = staged.validate_physical_integrity()
		var required: Array = added_ids + proposal.trimmedPanelIds
		var changed: Array = physical.checks.filter(func(c): return required.has(c.partId))
		checks["body_connections_and_trims_pass"] = changed.size() == 10 and changed.all(func(c): return c.passed)
		var actual_failed: Array = HeadCopy.failed_ids(physical)
		checks["whole_source_failed_ids_exact"] = actual_failed == baseline_failed
		report["beforeFailedIds"] = baseline_failed
		report["afterFailedIds"] = actual_failed
		report["physicalFailureCount"] = HeadCopy.failed_ids(physical).size()
		report["changedSourceChecks"] = changed
	checks["archive_still_bound"] = FileAccess.get_sha256(CANDIDATE_PATH) == CANDIDATE_SHA
	report.passed = checks.values().all(func(value): return value == true)
	report["elapsedMsec"] = Time.get_ticks_msec() - started
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_obs_json(report), "  "))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	quit(0 if report.passed and written else 2)

func _placement_controls(header: Dictionary, facade, gables: Array, original: Dictionary, retained: Array) -> Dictionary:
	var first: Dictionary = original.connections[0]
	var blocked := HeadCopy.Blueprint.BuildingPartScript.new({"id": "synthetic_connection_obstacle", "kind": "wall", "position": first.position,
		"size": first.size + Vector3(0.2, 2.0, 0.2), "collision": true})
	var no_fit := Connections.prepare(header, facade, gables, [blocked], retained)
	var checks := {"blocked_domain_rejected_atomically": not no_fit.ready and not no_fit.has("body") and not no_fit.has("connections"),
		"duplicate_obstacle_rejected": not Connections.prepare(header, facade, gables, [blocked, blocked]).ready}
	# A lower obstacle overlaps the neutral end, but leaves upper finite socket
	# space. Its geometry derives entirely from that end, not this fixture seed.
	blocked.size.y = first.size.y * 0.5
	blocked.position.y = first.position.y - first.size.y * 0.25
	var shifted := Connections.prepare(header, facade, gables, [blocked], retained)
	checks["obstacle_boundary_generates_clear_alternative"] = shifted.ready and shifted.connections[0].position.y > first.position.y
	checks["whole_shifted_ends_stay_in_band_yz"] = shifted.ready and _ends_within_band(shifted)
	var far = HeadCopy.Blueprint.BuildingPartScript.new({"id": "synthetic_far_obstacle", "kind": "wall", "position": Vector3(1000, 1000, 1000), "size": Vector3.ONE, "collision": true})
	var foreign: Dictionary = Connections._obstacles([far])
	var meter := {"satPairs": Connections.MAX_SAT_WORK - 1}
	var band_bounds: Array = Connections._bounds_values(original.body.position, original.body.size)
	var core_bounds: Array = Connections._bounds_values(gables[0].position, Core.bed_size(gables[0].size))
	var neutral: Vector3 = original.placements[0].neutralSocket
	var one := Connections._place_connection(band_bounds, core_bounds, neutral, Vector3(Connections.HALF.z, Connections.HALF.y, Connections.HALF.z), foreign.boxes, meter)
	var exhausted := Connections._place_connection(band_bounds, core_bounds, neutral, Vector3(Connections.HALF.z, Connections.HALF.y, Connections.HALF.z), foreign.boxes, meter)
	checks["sat_work_shared_across_connection_searches"] = one.ready and not exhausted.ready and exhausted.reason == "connection_sat_work_limit" and meter.satPairs == Connections.MAX_SAT_WORK and not exhausted.has("end")
	var geometry: Array = []
	if shifted.ready:
		var source = HeadCopy.Blueprint.new("synthetic_shift_socket_geometry", 1, "stone")
		for gable in gables: source.add_part(gable.snapshot())
		for record: Dictionary in shifted.connections + [shifted.body]: source.add_part(record)
		HeadCopy.clear_caches(source)
		for part in source.parts: source.physical_parts_by_id[part.id] = part
		for record: Dictionary in shifted.connections + [shifted.body]:
			var part = source.find_part(record.id)
			for fact: Dictionary in part.recipe.physicalRequiredSeatFacts:
				geometry.append(source.housed_overlap_diagnostics(part, source.find_part(fact.seatId), fact))
	checks["shifted_finite_sockets_remain_contained"] = geometry.size() == 4 and geometry.all(func(g): return g.insideBearer and g.insideSeat)
	return {"checks": checks, "blockedResult": no_fit, "shiftedResult": shifted, "shiftedGeometry": geometry, "sharedWorkExhaustion": exhausted,
		"scope": "Synthetic source obstacle placement and finite socket containment only; not rooted support or live collision acceptance."}

func _ends_within_band(arrangement: Dictionary) -> bool:
	var body: Array = Connections._bounds_values(arrangement.body.position, arrangement.body.size)
	for record: Dictionary in arrangement.connections:
		var bounds: Array = Connections._bounds_values(record.position, record.size)
		for axis in [1, 2]:
			if bounds[axis] < body[axis] or bounds[axis + 3] > body[axis + 3]: return false
	return true
