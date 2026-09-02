extends "res://scripts/testing/buildings/CitadelOpeningHeadBandContract.gd"
## Full actual-source first-row composition, not publication or normal integration.
var _batch_path := ""
var _batch_started := 0
var _progress_ok := true

func _batch_progress(house: String) -> void:
	var file := FileAccess.open(_batch_path.get_basename() + "-progress.json", FileAccess.WRITE)
	if file == null:
		_progress_ok = false
		return
	file.store_string(JSON.stringify({"stage": house, "elapsedMsec": Time.get_ticks_msec() - _batch_started}))
	file.flush()
	_progress_ok = _progress_ok and file.get_error() == OK
	file.close()
	print("opening batch: ", house)

func _run() -> void:
	_batch_path = OS.get_environment("VOXEL_OPENING_HEAD_BATCH_REPORT")
	var artifact_path := _batch_path.get_base_dir().path_join("candidate.bin")
	if not _batch_path.is_absolute_path() or FileAccess.file_exists(_batch_path) or FileAccess.file_exists(artifact_path) or FileAccess.file_exists(_batch_path.get_basename() + "-progress.json") or not DirAccess.dir_exists_absolute(_batch_path.get_base_dir()):
		quit(2)
		return
	_batch_started = Time.get_ticks_msec()
	var source := _read_source()
	if source.is_empty():
		quit(2)
		return
	var b = Copy.copy_blueprint(source.afterSnapshot)
	var original := Plan.digest(b.snapshot())
	var source_digest := Plan.digest(source)
	var policy := {"furnitureParts": source.furnitureSnapshot.parts, "reservedVolumes": source.protectedReservations, "requiredHeadroom": 1.72, "progressCallback": _batch_progress}
	var policy_before := policy.duplicate(true)
	var original_objects: Array = b.parts.duplicate()
	var result := Band.prepare_all_first_rows(b, policy)
	var report := {"evidenceLevel": "whole_source_first_row_candidate", "seed": source.fixture.seed, "scale": source.fixture.citadelScale, "sourceSha256": SOURCE_SHA,
		"checks": {"callerUnchanged": Plan.digest(b.snapshot()) == original, "compositionReady": result.ready}, "proposal": result, "passed": false,
		"limitations": "No publication, renderer, furniture-neighbour collision, normal integration or live gameplay acceptance."}
	if result.ready:
		var staged = Copy.copy_blueprint(result.candidateSnapshot)
		var headers: Array = result.houseProposals.map(func(p): return p.headerId)
		var framing: Array = headers.duplicate()
		for proposal: Dictionary in result.houseProposals: framing.append_array(proposal.connectionIds)
		var expected_houses: Array = Copy.street_house_memberships(b).houses.map(func(h): return h.prefix)
		var actual_houses: Array = result.houseProposals.map(func(p): return p.house)
		var sorted_houses := actual_houses.duplicate()
		sorted_houses.sort()
		report.checks["exactAuthoritativeHouseSetAndSortedOrder"] = expected_houses == actual_houses and actual_houses == sorted_houses
		var unique_headers: Dictionary = {}
		var unique_trims: Dictionary = {}
		for id in framing: unique_headers[id] = true
		for id in result.trimmedPanelIds: unique_trims[id] = true
		report.checks["uniqueFramingAndTrimIds"] = framing.size() == unique_headers.size() and result.trimmedPanelIds.size() == unique_trims.size() and framing.all(func(id): return not unique_trims.has(id) and b.find_part(id) == null)
		report.checks["successCallerAliasesOrderAndPolicyUnchanged"] = _same_part_objects(b.parts, original_objects) and policy == policy_before
		var exact: bool = staged.parts.size() == b.parts.size() + framing.size()
		for index in range(b.parts.size()):
			var old: Dictionary = b.parts[index].snapshot()
			var current: Dictionary = staged.parts[index].snapshot()
			if result.trimmedPanelIds.has(old.id):
				var normalized = Copy.Blueprint.BuildingPartScript.new(old)
				normalized.position = current.position
				normalized.size = current.size
				Copy.Frame._clean_derived(normalized)
				normalized.recipe["masonryApertureSource"] = _marker_owner(staged.recipe.facadeApertures, old.id)
				for key in ["physicalRequiredSeatPartIds", "physicalRequiredSeatFacts"]: normalized.recipe[key] = current.recipe[key]
				old = normalized.snapshot()
			exact = exact and Plan.digest(old) == Plan.digest(current)
		for index in range(b.parts.size(), staged.parts.size()): exact = exact and framing.has(staged.parts[index].id)
		report.checks["onlyDeclaredTrimsAndFraming"] = exact
		report.checks["exact112MasonryMarkersAcross16Houses"] = result.houseProposals.size() == 16 and result.trimmedPanelIds.size() == 112 and _markers_exact(staged, result.trimmedPanelIds)
		_marker_controls(b, staged, result.trimmedPanelIds, report.checks)
		report.checks["allTrimsContainedWithExactXZ"] = result.houseProposals.all(func(p): return p.trimGeometry.all(func(g): return g.after.position.x == g.before.position.x and g.after.position.z == g.before.position.z and g.after.size.x == g.before.size.x and g.after.size.z == g.before.size.z and g.after.position.y >= g.before.position.y and g.after.end.y <= g.before.end.y))
		report.checks["allBindingsAndOpeningInputsPreserved"] = _bindings_exact(b, staged, result.trimmedPanelIds)
		report.checks["roomsAndOldRecipePreserved"] = _world_recipe_exact(b, staged, result.trimmedPanelIds)
		report.checks["allChangedSolidsClearApertures"] = (framing + result.trimmedPanelIds).all(func(id): return _apertures_clear(b, staged.find_part(id).snapshot()))
		var framing_owners: Dictionary = {}
		for proposal: Dictionary in result.houseProposals:
			for id: String in [proposal.headerId] + proposal.connectionIds: framing_owners[id] = proposal.house
		var cross_pairs := 0
		var cross_blockers: Array = []
		for i in range(framing.size()):
			for j in range(i + 1, framing.size()):
				if framing_owners[framing[i]] == framing_owners[framing[j]]: continue
				var a = staged.find_part(framing[i])
				var c = staged.find_part(framing[j])
				var measured := Band.BoxAdmission.measure(Transform3D(Basis.from_scale(a.size), a.position), Transform3D(Basis.from_scale(c.size), c.position))
				cross_pairs += 1
				if not measured.valid or not measured.clear: cross_blockers.append({"first": a.id, "second": c.id, "measurement": measured})
		report["crossHouseFramingPairs"] = cross_pairs
		report["crossHouseBlockers"] = cross_blockers
		report.checks["allNewInterHouseFramingClear"] = cross_pairs > 0 and cross_blockers.is_empty()
		_batch_progress("fresh_before_after_validation")
		Copy.clear_caches(b)
		Copy.clear_caches(staged)
		var before := Copy.failed_ids(b.validate_physical_integrity())
		var physical: Dictionary = staged.validate_physical_integrity()
		var after := Copy.failed_ids(physical)
		report.merge({"beforeFailureCount": before.size(), "afterFailureCount": after.size(), "remainingFailedIds": after, "removedFailedIds": before.filter(func(id): return not after.has(id)), "addedFailedIds": after.filter(func(id): return not before.has(id)), "houseCount": result.houseProposals.size()})
		report.checks["baseline170"] = before.size() == 170
		report.checks["noAddedFailures"] = report.addedFailedIds.is_empty()
		report.checks["actualReduction"] = after.size() < before.size()
		var changed_checks: Array = physical.checks.filter(func(c): return framing.has(c.partId) or result.trimmedPanelIds.has(c.partId))
		report["changedPhysicalChecks"] = changed_checks
		report.checks["everyFrameAndTrimPassedInFullContext"] = changed_checks.size() == framing.size() + result.trimmedPanelIds.size() and changed_checks.all(func(c): return c.passed)
		var socket_checks: Array = []
		for id: String in framing:
			var bearer = staged.find_part(id)
			for fact: Dictionary in bearer.recipe.get("physicalRequiredSeatFacts", []):
				socket_checks.append(staged.housed_overlap_diagnostics(bearer, staged.find_part(fact.seatId), fact))
		report["finiteJointChecks"] = socket_checks
		report.checks["everyDeclaredFiniteJointPasses"] = socket_checks.size() == headers.size() + framing.size() and socket_checks.all(func(s): return s.insideBearer and s.insideSeat and s.rootedSeat and s.longitudinalEmbedment >= 0.12 and s.verticalOverlap >= 0.04)
		_batch_progress("deterministic_replay")
		var replay_source = Copy.copy_blueprint(source.afterSnapshot)
		var replay := Band.prepare_all_first_rows(replay_source, policy)
		report.checks["identicalRepeatSignature"] = replay.ready and Plan.digest(replay.candidateSnapshot) == Plan.digest(result.candidateSnapshot)
		report.checks["replayCallerUnchanged"] = Plan.digest(replay_source.snapshot()) == original
		_batch_progress("late_failure_atomicity")
		var blocked_policy := policy.duplicate(true)
		var last: Dictionary = result.houseProposals.back()
		blocked_policy.reservedVolumes.append(AABB(last.header.position - Vector3.ONE * 0.01, Vector3.ONE * 0.02))
		var blocked_source = Copy.copy_blueprint(source.afterSnapshot)
		var blocked_objects: Array = blocked_source.parts.duplicate()
		var blocked_policy_before := blocked_policy.duplicate(true)
		var failed := Band.prepare_all_first_rows(blocked_source, blocked_policy)
		report["lateFailure"] = failed
		report.checks["lastHouseFailureReturnsNoPartialCandidate"] = not failed.ready and not failed.has("candidateSnapshot") and failed.get("failedHouse") == last.house and failed.get("completedHouseCount") == result.houseProposals.size() - 1 and Plan.digest(blocked_source.snapshot()) == original
		report.checks["lateFailurePreservesAliasesOrderAndPolicy"] = _same_part_objects(blocked_source.parts, blocked_objects) and blocked_policy == blocked_policy_before
		report.checks["sourceAndFurnitureUnchanged"] = Plan.digest(source) == source_digest and FileAccess.get_sha256(SOURCE_PATH) == SOURCE_SHA
		report.checks["freshProgressWritten"] = _progress_ok
		if report.checks.values().all(func(v): return v == true):
			var payload := {"beforeSnapshot": source.afterSnapshot, "afterSnapshot": result.candidateSnapshot, "fixture": source.fixture, "furnitureSnapshot": source.furnitureSnapshot, "protectedReservations": source.protectedReservations, "houseProposals": result.houseProposals, "trimmedPanelIds": result.trimmedPanelIds, "sourceSha256": SOURCE_SHA}
			report.passed = _export_candidate(artifact_path, payload)
			if report.passed: report["candidateArtifactSha256"] = FileAccess.get_sha256(artifact_path)
	report.proposal.erase("candidateSnapshot")
	report["elapsedMsec"] = Time.get_ticks_msec() - _batch_started
	var file := FileAccess.open(_batch_path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	print("opening batch passed=", report.passed, " reason=", result.get("reason", ""))
	quit(0 if report.passed and written else 2)

func _marker_owner(records: Dictionary, id: String) -> String:
	var owners: Array = []
	for key: Variant in records:
		var declaration: Variant = records[key]
		if not declaration is Dictionary or not declaration.get("partIds") is Array: continue
		for member: Variant in declaration.partIds:
			if member == id: owners.append(key)
	return owners[0] if owners.size() == 1 and owners[0] is String else ""

func _markers_exact(b, trimmed: Array) -> bool:
	var records: Variant = b.recipe.get("facadeApertures")
	if not records is Dictionary: return false
	var by_id: Dictionary = {}
	var expected: Dictionary = {}
	var used: Dictionary = {}
	for id: Variant in trimmed:
		if not id is String or expected.has(id): return false
		expected[id] = true
	for part in b.parts: by_id[part.id] = part
	var count: int = 0
	for part in b.parts:
		if part.recipe.has("masonryApertureSource") != expected.has(part.id): return false
		if not expected.has(part.id): continue
		var owner: String = _marker_owner(records, part.id)
		if owner.is_empty() or not part.recipe.masonryApertureSource is String or part.recipe.masonryApertureSource != owner: return false
		if part.kind != "wall" or not Band.Materials.is_masonry_material(part.material_id) or records[owner].get("producerPrefix") != owner or records[owner].get("semantic") != part.semantic or not part.id.begins_with(owner + "_"): return false
		used[owner] = true
		count += 1
	for key: String in used:
		if not Band.Aperture.validate(records[key], by_id): return false
	return count == expected.size()

func _marker_controls(source, staged, trimmed: Array, checks: Dictionary) -> void:
	if trimmed.is_empty():
		checks["markerControlHasTrim"] = false
		return
	var id: String = trimmed[0]
	var probe = Copy.copy_blueprint(staged.snapshot())
	var panel = probe.find_part(id)
	var owner: String = panel.recipe.get("masonryApertureSource", "")
	if owner.is_empty() or not source.recipe.facadeApertures.has(owner):
		checks["markerControlHasBoundOwner"] = false
		return
	panel.recipe.erase("masonryApertureSource")
	checks["missingMarkerRejected"] = not _markers_exact(probe, trimmed)
	panel.recipe["masonryApertureSource"] = owner + "_foreign"
	checks["arbitraryMarkerRejected"] = not _markers_exact(probe, trimmed)
	panel.recipe["masonryApertureSource"] = owner
	for part in probe.parts:
		if trimmed.has(part.id): continue
		part.recipe["masonryApertureSource"] = owner
		checks["extraNontrimMarkerRejected"] = not _markers_exact(probe, trimmed)
		break
	for mode: String in ["existing", "ambiguous", "nonmasonry"]:
		var input = Copy.copy_blueprint(source.snapshot())
		var by_id: Dictionary = {}
		for part in input.parts: by_id[part.id] = part
		match mode:
			"existing": by_id[id].recipe["masonryApertureSource"] = owner
			"ambiguous": input.recipe.facadeApertures[owner + "_duplicate"] = input.recipe.facadeApertures[owner].duplicate(true)
			"nonmasonry": by_id[id].material_id = "timber_beam"
		var before: String = Plan.digest(input.snapshot())
		var rejected: Dictionary = Band._trim_aperture_sources(input, by_id, [id], [owner])
		var reasons: Dictionary = {"existing": "existing_masonry_aperture_source", "ambiguous": "ambiguous_trim_aperture_source", "nonmasonry": "trim_not_masonry"}
		checks["markerRecipeGuard:" + mode] = not rejected.ready and rejected.reason == reasons[mode] and not rejected.has("sources") and Plan.digest(input.snapshot()) == before

func _same_part_objects(current: Array, retained: Array) -> bool:
	if current.size() != retained.size(): return false
	for index in range(current.size()):
		if not is_same(current[index], retained[index]): return false
	return true
