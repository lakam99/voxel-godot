extends SceneTree

## One known-seed, actual-source prototype. No production/visual acceptance.
const Plan = preload("res://scripts/testing/buildings/CitadelFacadeVisualPlan.gd")
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Band = preload("res://scripts/buildings/OpeningHeadBandRecipe.gd")
const Declaration = preload("res://scripts/buildings/FacadeApertureDeclaration.gd")
const SOURCE_PATH := "res://artifacts/citadel-visual-reset/facade-aperture-manifest-02/source.bin"
const SOURCE_SHA := "e83098a950b7ad66d82eeff838f51cb912873f32bd3e8755931af52955a54219"
const MAX_SOURCE_BYTES := 32 * 1024 * 1024
var _house_id := "urban_row_00_left" # Explicit fixture selection, never a recipe exception.

func _initialize() -> void: call_deferred("_run")

func _run() -> void:
	var requested_house := OS.get_environment("VOXEL_OPENING_HEAD_HOUSE")
	if not requested_house.is_empty(): _house_id = requested_house
	var path := OS.get_environment("VOXEL_OPENING_HEAD_BAND_REPORT")
	var artifact_path: String = path.get_base_dir().path_join("candidate.bin")
	if not path.is_absolute_path() or path.get_extension() != "json" or FileAccess.file_exists(path) or FileAccess.file_exists(artifact_path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var started := Time.get_ticks_msec()
	var source: Dictionary = _read_source()
	if source.is_empty():
		quit(2)
		return
	var b = Copy.copy_blueprint(source.afterSnapshot)
	var members: Dictionary = Copy.street_house_memberships(b)
	var houses: Array = members.get("houses", []).filter(func(h): return h.prefix == _house_id)
	if not members.ready or houses.size() != 1:
		quit(2)
		return
	var before_digest: String = Plan.digest(b.snapshot())
	var policy := {"furnitureParts": source.furnitureSnapshot.parts, "reservedVolumes": source.protectedReservations, "requiredHeadroom": 1.72}
	var source_digest: String = Plan.digest(source)
	var inputs_digest: String = Plan.digest([b.snapshot(), houses[0].memberIds, policy])
	print("opening head: prepare actual ", _house_id)
	var proposal: Dictionary = Band.prepare_first(b, houses[0].memberIds, policy)
	var report := {"evidenceLevel": "single_actual_house_source_recipe_prototype", "seed": source.fixture.seed,
		"scale": source.fixture.citadelScale, "house": _house_id, "sourceDigest": before_digest, "sourcePath": SOURCE_PATH, "sourceSha256": SOURCE_SHA, "proposal": proposal,
		"checks": {"callerUnchanged": Plan.digest([b.snapshot(), houses[0].memberIds, policy]) == inputs_digest}, "passed": false,
		"headroomReference": "PlayerController.gd creates the standing capsule with height1.72.",
		"limitations": "No normal-generator integration, exact published masonry/timber interface, swept-door, neighbour-collision or visual acceptance. One actual house is not all houses/seeds."}
	report["subtractionControls"] = _subtraction_controls()
	var window_levels: Array = []
	for part in b.parts:
		if part.id.begins_with(_house_id + "_") and part.kind == "window" and not window_levels.has(part.position.y): window_levels.append(part.position.y)
	report["windowLevelCount"] = window_levels.size()
	report.checks["subtractionControlsPass"] = report.subtractionControls.values().all(func(v): return v == true)
	if proposal.ready:
		var reversed: Array = houses[0].memberIds.duplicate()
		reversed.reverse()
		var again: Dictionary = Band.prepare_first(b, reversed, policy)
		report.checks["memberOrderIndependent"] = again.ready and Plan.digest(again.candidateSnapshot) == Plan.digest(proposal.candidateSnapshot)
		report.checks["repeatCallerUnchanged"] = Plan.digest([b.snapshot(), houses[0].memberIds, policy]) == inputs_digest
		var staged = Copy.copy_blueprint(proposal.candidateSnapshot)
		var framing_ids: Array = [proposal.headerId] + proposal.connectionIds
		var preserved := true
		var trim_axes_exact := true
		for index in range(b.parts.size()):
			var old: Dictionary = b.parts[index].snapshot()
			var current: Dictionary = staged.parts[index].snapshot()
			if proposal.trimmedPanelIds.has(old.id):
				trim_axes_exact = trim_axes_exact and current.position.x == old.position.x and current.position.z == old.position.z and current.size.x == old.size.x and current.size.z == old.size.z
				var normalized = Copy.Blueprint.BuildingPartScript.new(old)
				normalized.position = current.position
				normalized.size = current.size
				Copy.Frame._clean_derived(normalized)
				normalized.recipe["masonryApertureSource"] = current.recipe.masonryApertureSource
				for key in ["physicalRequiredSeatPartIds", "physicalRequiredSeatFacts"]: normalized.recipe[key] = current.recipe[key]
				old = normalized.snapshot()
			preserved = preserved and Plan.digest(old) == Plan.digest(current)
		var added_ids: Array = staged.parts.slice(b.parts.size()).map(func(p): return p.id)
		report.checks["onlyDeclaredTrimsAndCompleteFraming"] = preserved and added_ids == framing_ids
		report.checks["trimXZExact"] = trim_axes_exact
		report.checks["roomsAndWorldRecipeExact"] = _world_recipe_exact(b, staged, proposal.trimmedPanelIds)
		report.checks["allOutputBindingsAndOriginalOpeningInputsExact"] = _bindings_exact(b, staged, proposal.trimmedPanelIds)
		report.checks["selectedPanelsCoveredExactlyOnce"] = _coverage_exact(b, houses[0].memberIds)
		report["apertureProof"] = proposal.get("apertureProof", {})
		report["constructionSeamChanges"] = proposal.get("constructionSeamChanges", [])
		report.checks["apertureProofReported"] = proposal.get("apertureProof") is Dictionary and not proposal.apertureProof.is_empty()
		report.checks["framingDoesNotPenetrateFullApertures"] = framing_ids.all(func(id): return _apertures_clear(b, staged.find_part(id).snapshot()))
		report.checks["trimmedPanelsClearAllApertures"] = proposal.trimmedPanelIds.all(func(id): return _apertures_clear(b, staged.find_part(id).snapshot()))
		var one_step_lower: Dictionary = proposal.header.duplicate(true)
		one_step_lower.position.y = -Band._next_float32_up(-float(one_step_lower.position.y))
		report["oneStepBelowCurrentHeaderIntersects"] = not _apertures_clear(b, one_step_lower)
		var boundary_probe := _aperture_boundary_probe(b, proposal.header)
		report["apertureBoundaryProbe"] = boundary_probe
		report.checks["oneRepresentableStepAcrossApertureBoundaryRejected"] = boundary_probe.passed
		report.checks["actualTrimGeometryContained"] = proposal.trimGeometry.all(func(g): return g.after.position.x == g.before.position.x and g.after.position.z == g.before.position.z and g.after.size.x == g.before.size.x and g.after.size.z == g.before.size.z and g.after.position.y >= g.before.position.y and g.after.end.y <= g.before.end.y)
		report.checks["trimSeatChecksPass"] = proposal.trimmedPanelSeatChecks.size() == proposal.trimmedPanelIds.size() and proposal.trimmedPanelSeatChecks.all(func(c): return c.passed)
		report.checks["finitePositiveSeamCells"] = proposal.constructionSeamChanges.all(func(c): return c is Array and Band.ReplacementOccupancy.valid(c) and minf(c[4] - c[1], c[5] - c[2]) <= Band.EDGE_EPS)
		report["guardCases"] = _guard_cases(source.afterSnapshot, houses[0].memberIds, policy, proposal.trimmedPanelIds)
		report.checks["negativeGuardsAtomicAndCallerImmutable"] = not report.guardCases.is_empty() and report.guardCases.values().all(func(value): return value.passed)
		print("opening head: independent before/after physical validation")
		Copy.clear_caches(b)
		Copy.clear_caches(staged)
		var before: Dictionary = b.validate_physical_integrity()
		var after: Dictionary = staged.validate_physical_integrity()
		var old_failed := Copy.failed_ids(before)
		var new_failed := Copy.failed_ids(after)
		report["beforeFailureCount"] = old_failed.size()
		report["afterFailureCount"] = new_failed.size()
		report["removedFailedIds"] = old_failed.filter(func(id): return not new_failed.has(id))
		report["addedFailedIds"] = new_failed.filter(func(id): return not old_failed.has(id))
		report["headerCheck"] = after.checks.filter(func(check): return check.partId == proposal.headerId)
		var frame_checks: Array = after.checks.filter(func(check): return framing_ids.has(check.partId))
		report["framingChecks"] = frame_checks
		report.checks["everyFrameHasRootedSeats"] = frame_checks.size() == framing_ids.size() and frame_checks.all(func(c): return c.passed and c.hasRootedSeats)
		report.checks["baseline170"] = old_failed.size() == 170
		report.checks["noAddedFailures"] = report.addedFailedIds.is_empty()
		report.checks["headerAndBothSeatsPass"] = report.headerCheck.size() == 1 and report.headerCheck[0].passed and report.headerCheck[0].hasRootedSeats
		report.checks["actualFailureReduction"] = new_failed.size() < old_failed.size()
		print("opening head: missing end must invalidate new header")
		var broken = Copy.copy_blueprint(proposal.candidateSnapshot)
		var removed_id: String = proposal.header.recipe.physicalRequiredSeatPartIds[0]
		broken.parts = broken.parts.filter(func(part): return part.id != removed_id)
		Copy.clear_caches(broken)
		var negative: Dictionary = broken.validate_physical_integrity()
		var broken_header: Array = negative.checks.filter(func(check): return check.partId == proposal.headerId)
		report["missingEndCheck"] = broken_header
		report.checks["oneMissingEndRejectsDespiteOtherEnd"] = broken_header.size() == 1 and not broken_header[0].passed
		var lost_end_panels: Array = negative.checks.filter(func(check): return proposal.trimmedPanelIds.has(check.partId))
		report["missingEndPanelChecks"] = lost_end_panels
		report.checks["missingEndInvalidatesEveryTrimmedPanel"] = lost_end_panels.size() == proposal.trimmedPanelIds.size() and lost_end_panels.all(func(check): return not check.passed)
		var missing_header = Copy.copy_blueprint(proposal.candidateSnapshot)
		missing_header.parts = missing_header.parts.filter(func(part): return part.id != proposal.headerId)
		Copy.clear_caches(missing_header)
		var removed_header_report: Dictionary = missing_header.validate_physical_integrity()
		var affected: Array = removed_header_report.checks.filter(func(check): return proposal.trimmedPanelIds.has(check.partId))
		report["missingHeaderPanelChecks"] = affected
		report.checks["missingHeaderInvalidatesEveryTrimmedPanel"] = affected.size() == proposal.trimmedPanelIds.size() and affected.all(func(check): return not check.passed)
		var blocked_policy := policy.duplicate(true)
		blocked_policy.reservedVolumes.append(AABB(proposal.header.position - proposal.header.size * 0.5, proposal.header.size))
		var blocked_source = Copy.copy_blueprint(source.afterSnapshot)
		var blocked_inputs: String = Plan.digest([blocked_source.snapshot(), houses[0].memberIds, blocked_policy])
		var blocked: Dictionary = Band.prepare_first(blocked_source, houses[0].memberIds, blocked_policy)
		report.checks["blockedReservationAtomic"] = not blocked.ready and not blocked.has("candidateSnapshot") and Plan.digest([blocked_source.snapshot(), houses[0].memberIds, blocked_policy]) == blocked_inputs
		report["blockedReason"] = blocked.get("reason", "")
		report.checks["sourceAndPolicyImmutable"] = Plan.digest(source) == source_digest and Plan.digest(policy) == Plan.digest({"furnitureParts": source.furnitureSnapshot.parts, "reservedVolumes": source.protectedReservations, "requiredHeadroom": 1.72})
		report.checks["sourceBindingStillCurrent"] = FileAccess.get_sha256(SOURCE_PATH) == SOURCE_SHA
		if report.checks.values().all(func(value): return value == true):
			var payload: Dictionary = {"beforeSnapshot": source.afterSnapshot, "afterSnapshot": proposal.candidateSnapshot,
				"fixture": source.fixture, "furnitureSnapshot": source.furnitureSnapshot, "protectedReservations": source.protectedReservations,
				"headerId": proposal.headerId, "trimmedPanelIds": proposal.trimmedPanelIds, "apertureProof": report.apertureProof, "constructionSeamChanges": report.constructionSeamChanges, "sourceSha256": SOURCE_SHA}
			report.checks["artifactFlushAndShaVerified"] = _export_candidate(artifact_path, payload)
			report.passed = report.checks.artifactFlushAndShaVerified
			if report.passed:
				report["candidateArtifactPath"] = artifact_path
				report["candidateArtifactSha256"] = FileAccess.get_sha256(artifact_path)
	report["elapsedMsec"] = Time.get_ticks_msec() - started
	report.proposal.erase("candidateSnapshot")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	print("opening head prototype passed=", report.passed, " reason=", proposal.get("reason", ""))
	quit(0 if report.passed and written else 2)

func _read_source() -> Dictionary:
	if FileAccess.get_sha256(SOURCE_PATH) != SOURCE_SHA: return {}
	var file: FileAccess = FileAccess.open(SOURCE_PATH, FileAccess.READ)
	if file == null: return {}
	var length: int = file.get_length()
	if length <= 0 or length > MAX_SOURCE_BYTES:
		file.close()
		return {}
	var bytes: PackedByteArray = file.get_buffer(length)
	var complete: bool = bytes.size() == length and file.get_error() == OK
	file.close()
	if not complete or FileAccess.get_sha256(SOURCE_PATH) != SOURCE_SHA: return {}
	var value: Variant = bytes_to_var(bytes)
	if not value is Dictionary or var_to_bytes(value) != bytes: return {}
	for key: String in ["fixture", "afterSnapshot", "furnitureSnapshot"]:
		if not value.get(key) is Dictionary: return {}
	if not value.get("protectedReservations") is Array or value.fixture.get("seed") != 208159 or value.fixture.get("citadelScale") != 1.25: return {}
	return value

func _lookup(b: Variant) -> Dictionary:
	var result: Dictionary = {}
	for part: Variant in b.parts:
		if part == null or result.has(part.id): return {}
		result[part.id] = part
	return result

func _coverage_exact(b: Variant, members: Array) -> bool:
	var by_id: Dictionary = _lookup(b)
	var declarations: Variant = b.recipe.get("facadeApertures")
	if by_id.is_empty() or not declarations is Dictionary: return false
	for id: String in members:
		if not by_id.has(id): return false
		if by_id[id].semantic != "citadel_urban_facade": continue
		var count: int = 0
		for key: String in declarations:
			var entry: Variant = declarations[key]
			if not Declaration.validate(entry, by_id): return false
			if entry.partIds.has(id): count += 1
		if count != 1: return false
	return true

func _world_recipe_exact(before: Variant, after: Variant, trimmed: Array) -> bool:
	var normalized: Dictionary = after.recipe.duplicate(true)
	if not normalized.get("facadeApertures") is Dictionary: return false
	for key: String in before.recipe.facadeApertures:
		if not normalized.facadeApertures.has(key): return false
		var old: Dictionary = before.recipe.facadeApertures[key]
		if old.partIds.any(func(id): return trimmed.has(id)):
			normalized.facadeApertures[key]["sourceBinding"] = old.sourceBinding
	return Plan.digest(before.rooms) == Plan.digest(after.rooms) and Plan.digest(before.recipe) == Plan.digest(normalized)

func _bindings_exact(before: Variant, after: Variant, trimmed: Array) -> bool:
	var old_map: Dictionary = _lookup(before)
	var new_map: Dictionary = _lookup(after)
	var old_entries: Dictionary = before.recipe.facadeApertures
	var new_entries: Variant = after.recipe.get("facadeApertures")
	if not new_entries is Dictionary or old_entries.size() != new_entries.size(): return false
	for key: String in old_entries:
		var old: Dictionary = old_entries[key]
		var current: Variant = new_entries.get(key)
		if not Declaration.validate(old, old_map) or not Declaration.validate(current, new_map): return false
		if Plan.digest(old.openings) != Plan.digest(current.openings) or Plan.digest(old.partIds) != Plan.digest(current.partIds): return false
		var touched: bool = old.partIds.any(func(id): return trimmed.has(id))
		if touched and old.sourceBinding == current.sourceBinding: return false
		if not touched and Plan.digest(old) != Plan.digest(current): return false
	return true

func _apertures_clear(b: Variant, header: Dictionary) -> bool:
	var bounds: Array = []
	for axis in range(3): bounds.append(float(header.position[axis]) - float(header.size[axis]) * 0.5)
	for axis in range(3): bounds.append(float(header.position[axis]) + float(header.size[axis]) * 0.5)
	for entry: Dictionary in b.recipe.facadeApertures.values():
		for opening: Dictionary in entry.openings:
			var volume: AABB = opening.fullVolume
			var intersects := true
			for axis in range(3): intersects = intersects and minf(bounds[axis + 3], volume.end[axis]) > maxf(bounds[axis], volume.position[axis])
			if intersects: return false
	return true

func _aperture_boundary_probe(b, header: Dictionary) -> Dictionary:
	# A correctly fitted body may sit more than one float32 step above the
	# aperture. Test the exact transition at the actual declared boundary,
	# not an assumption that the current construction is minimally positioned.
	var top := -INF
	var selected := ""
	var low: Vector3 = header.position - header.size * 0.5
	var high: Vector3 = header.position + header.size * 0.5
	var actual_bottom: float = float(header.position.y) - float(header.size.y) * 0.5
	for entry: Dictionary in b.recipe.facadeApertures.values():
		for opening: Dictionary in entry.openings:
			var volume: AABB = opening.fullVolume
			if volume.end.x <= low.x or volume.position.x >= high.x or volume.end.z <= low.z or volume.position.z >= high.z: continue
			if volume.end.y <= actual_bottom and volume.end.y > top:
				top = volume.end.y
				selected = opening.id
	if not is_finite(top): return {"passed": false, "reason": "no_aperture_below_body"}
	var clear_probe: Dictionary = header.duplicate(true)
	clear_probe.position.y = top + float(header.size.y) * 0.5
	for attempt in range(4):
		if float(clear_probe.position.y) - float(header.size.y) * 0.5 >= top: break
		clear_probe.position.y = Band._next_float32_up(clear_probe.position.y)
	for attempt in range(4):
		var lower: float = -Band._next_float32_up(-float(clear_probe.position.y))
		if lower - float(header.size.y) * 0.5 < top: break
		clear_probe.position.y = lower
	var blocked_probe: Dictionary = clear_probe.duplicate(true)
	blocked_probe.position.y = -Band._next_float32_up(-float(clear_probe.position.y))
	var clear_bottom: float = float(clear_probe.position.y) - float(header.size.y) * 0.5
	var blocked_bottom: float = float(blocked_probe.position.y) - float(header.size.y) * 0.5
	var passed := clear_bottom >= top and blocked_bottom < top and _apertures_clear(b, clear_probe) and not _apertures_clear(b, blocked_probe)
	return {"passed": passed, "apertureId": selected, "declaredTop": top, "clearBottom": clear_bottom, "blockedBottom": blocked_bottom,
		"positivePenetration": top - blocked_bottom, "clearProbe": clear_probe, "blockedProbe": blocked_probe, "positiveOverlapTolerance": 0.0}

func _guard_cases(snapshot: Dictionary, members: Array, policy: Dictionary, trimmed: Array) -> Dictionary:
	var results: Dictionary = {}
	for mode: String in ["missing_manifest", "malformed_manifest", "missing_declaration", "malformed_declaration", "stale_opening", "stale_part", "uncovered_panel", "conflicting_membership", "prior_anchor_fact", "malformed_access", "nonfinite_access", "malformed_access_size"]:
		var b: Variant = Copy.copy_blueprint(snapshot)
		var ids: Array = members.duplicate(true)
		var settings: Dictionary = policy.duplicate(true)
		var key: String = _house_id + "_upper_facade"
		var target: String = String(trimmed[0])
		match mode:
			"missing_manifest": b.recipe.erase("facadeApertures")
			"malformed_manifest": b.recipe.facadeApertures = []
			"missing_declaration": b.recipe.facadeApertures.erase(key)
			"malformed_declaration": b.recipe.facadeApertures[key] = {"partIds": "not_an_array"}
			"stale_opening": b.recipe.facadeApertures[key].openings[0].input.width += 0.125
			"stale_part": b.find_part(target).position.z += 0.125
			"uncovered_panel":
				var entry: Dictionary = b.recipe.facadeApertures[key].duplicate(true)
				entry.partIds.erase(target)
				entry.erase("sourceBinding")
				b.recipe.facadeApertures[key] = Declaration.seal(entry, entry.partIds.map(func(id): return b.find_part(id)))
			"conflicting_membership": b.recipe.facadeApertures[key + "_duplicate"] = b.recipe.facadeApertures[key].duplicate(true)
			"prior_anchor_fact": b.find_part(target).recipe["physicalRequiredAnchorFacts"] = [{"anchorId": _house_id + "_upper_shell_side_-1", "contactMode": "attachment_socket", "localMountCenter": Vector3.ZERO, "localMountHalfExtents": Vector3.ONE * 0.01}]
			_:
				for room: Dictionary in b.rooms:
					if room.get("id") != _house_id + "_interior": continue
					if mode == "malformed_access": room.accesses = ["invalid_access"]
					elif mode == "nonfinite_access": room.accesses[0].position = Vector3(NAN, 0.0, 0.0)
					else: room.accesses[0]["furnishingSize" if room.accesses[0].has("furnishingSize") else "size"] = Vector3(1.0, -1.0, 1.0)
		var before: String = Plan.digest([b.snapshot(), ids, settings])
		var result: Dictionary = Band.prepare_first(b, ids, settings)
		var immutable: bool = before == Plan.digest([b.snapshot(), ids, settings])
		results[mode] = {"passed": result.get("ready") == false and not result.has("candidateSnapshot") and not result.has("header") and immutable and not String(result.get("reason", "")).is_empty(), "callerImmutable": immutable, "reason": result.get("reason", "")}
	return results

func _export_candidate(path: String, payload: Dictionary) -> bool:
	if FileAccess.file_exists(path): return false
	var bytes: PackedByteArray = var_to_bytes(payload)
	var expected_sha: String = Plan.digest(payload)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_buffer(bytes)
	file.flush()
	var written: bool = file.get_error() == OK and file.get_position() == bytes.size() and file.get_length() == bytes.size()
	file.close()
	return written and FileAccess.get_sha256(path) == expected_sha and FileAccess.get_file_as_bytes(path) == bytes

func _subtraction_controls() -> Dictionary:
	# Binary-exact coordinates: independent volume conservation, containment,
	# pairwise disjointness and no overlap with the cutter, including thin cells.
	var results: Dictionary = {}
	for offset in [Vector3.ZERO, Vector3(1024.0, -64.0, 32.0)]:
		var source := AABB(offset, Vector3(4.0, 4.0, 4.0))
		var cutters := [AABB(offset + Vector3(1, 1, 1), Vector3(2, 2, 2)), AABB(offset + Vector3(4, 0, 0), Vector3.ONE), AABB(offset, Vector3(4, 4, 3.999996185302734375))]
		for index in range(cutters.size()):
			var cutter: AABB = cutters[index]
			var cells: Array = Band._subtract_box(source, cutter)
			var volume := 0.0
			var valid := true
			for i in range(cells.size()):
				var cell: AABB = cells[i]
				valid = valid and Copy.Frame._valid_bounds(cell) and source.encloses(cell) and not Band._penetrates(cell, cutter)
				volume += cell.get_volume()
				for j in range(i): valid = valid and not Band._penetrates(cell, cells[j])
			var overlap := source.end.min(cutter.end) - source.position.max(cutter.position)
			var removed := maxf(0, overlap.x) * maxf(0, overlap.y) * maxf(0, overlap.z)
			results[str(offset) + ":" + str(index)] = valid and volume == source.get_volume() - removed
	return results
