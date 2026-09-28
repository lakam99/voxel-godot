extends SceneTree

## Unwired frozen-source diagnostic. Does not compose, publish, or move anything.
## VOXEL_ROOF_INTEGRATION_BASELINE: absolute frozen prototype.bin path.
## VOXEL_MARKET_PLACEMENT_REPORT: NEW absolute JSON path; parent must exist.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Placement = preload("res://scripts/buildings/RigidHouseholdPlacement.gd")
const SHA := "7d218cb03d293304bb06f2f4dce492db503ff54a8091b525de93563b42549ec5"
const CLEARANCE := 0.8
const PLAZA_INSET := 0.1
var _path := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var started := Time.get_ticks_msec()
	var baseline := OS.get_environment("VOXEL_ROOF_INTEGRATION_BASELINE").strip_edges().simplify_path()
	_path = OS.get_environment("VOXEL_MARKET_PLACEMENT_REPORT").strip_edges().simplify_path()
	var report := {"evidenceLevel": "frozen_source_transformed_corner_placement_diagnostic",
		"passed": false, "baselinePath": baseline, "baselineSha256": SHA,
		"clearance": CLEARANCE, "plazaInset": PLAZA_INSET,
		"clearanceMeaning": "Rectangle layout spacing only; neither 0.8 nor 0.1 certifies pedestrian access.",
		"doesNotProve": "No composer integration, published primitive bounds, headed rendering, collision-backed traversal, navigation, general seeds, or whole-citadel physical acceptance. Rectangle fit is not placement acceptance. Nearby overlap rows are transformed-source-AABB candidates, not mesh intersection proofs. Terminal reservation is the original frozen row, not the unwired frame prototype."}
	if not _path.is_absolute_path() or _path.get_extension().to_lower() != "json" or FileAccess.file_exists(_path):
		_path = ""
		_finish(report, "require_new_absolute_json_report_path")
		return
	if not baseline.is_absolute_path() or FileAccess.get_sha256(baseline) != SHA:
		_finish(report, "baseline_sha_mismatch_or_missing")
		return
	var file := FileAccess.open(baseline, FileAccess.READ)
	if file == null:
		_finish(report, "baseline_open_failed")
		return
	var envelope = file.get_var(false)
	var read_ok := file.get_error() == OK and file.get_position() == file.get_length()
	file.close()
	if not read_ok or not envelope is Dictionary or not envelope.get("output") is Dictionary:
		_finish(report, "invalid_frozen_envelope")
		return
	var frozen: Dictionary = envelope.output
	if not frozen.get("sourceSnapshot") is Dictionary or not frozen.get("physicalValidation") is Dictionary:
		_finish(report, "missing_frozen_source_or_validation")
		return
	var source: Dictionary = frozen.sourceSnapshot
	var violation_count: int = frozen.physicalValidation.get("violations", []).size()
	report["fixture"] = frozen.get("fixture", {})
	report["frozenViolationCount"] = violation_count
	if violation_count != 253:
		_finish(report, "expected_frozen_253_record")
		return
	var b = Blueprint.new(source.id, source.seed, source.style)
	b.recipe = source.recipe.duplicate(true)
	b.rooms = source.rooms.duplicate(true)
	var by_id: Dictionary = {}
	var boxes: Dictionary = {}
	for record in source.parts:
		var part = b.add_part(record)
		if String(part.id).is_empty() or by_id.has(part.id) or not b.has_finite_positive_bounds(part):
			_finish(report, "invalid_or_duplicate_source_part")
			return
		by_id[part.id] = part
		boxes[part.id] = _corner_bounds(b, part)
	var before := var_to_bytes(b.snapshot())
	var plaza = by_id.get("urban_market_plaza")
	var support = by_id.get("urban_market_plaza_retaining")
	var layout: Dictionary = b.recipe.get("urbanPoc", {})
	var specs: Array = layout.get("marketStalls", [])
	if plaza == null or support == null or specs.size() != 3:
		_finish(report, "missing_plaza_or_three_stall_layout")
		return
	if not plaza.collision_enabled or not support.collision_enabled or plaza.rotation != Vector3.ZERO:
		_finish(report, "expected_axis_aligned_colliding_plaza")
		return
	var plaza_rect := _xz(boxes[plaza.id])
	var allowed := plaza_rect.grow(-PLAZA_INSET)
	report["coordinateSpace"] = "blueprint local XZ; no additional citadelScale multiplier"
	report["plazaOrigin"] = plaza.position
	report["plazaBounds"] = boxes[plaza.id]
	report["retainingBounds"] = boxes[support.id]
	report["allowedFootprint"] = allowed
	var variation := float(int(source.seed) % 19) / 100.0 - 0.09
	var groups: Array = []
	var claimed: Dictionary = {}
	for index in range(specs.size()):
		var spec: Dictionary = specs[index]
		var scratch = Blueprint.new("market_membership", int(source.seed), String(source.style))
		# Positions are irrelevant to membership. Use the producer unchanged;
		# the exact material variation controls its optional seating branch.
		Urban.add_market_stall_household(scratch, Vector3.ZERO,
			float(spec.side), float(spec.depth), variation + float(spec.get("variation", 0.0)))
		var group := _source_group("stall_%d" % index, scratch, by_id, boxes, claimed)
		group["layoutSpec"] = spec
		groups.append(group)
	var terminal_scratch = Blueprint.new("terminal_membership", int(source.seed), String(source.style))
	Urban.add_terminal_shop_row(terminal_scratch, Vector3.ZERO, variation)
	groups.append(_source_group("original_terminal_row", terminal_scratch, by_id, boxes, claimed))
	report["groups"] = groups
	if not groups.all(func(group): return bool(group.ready)):
		_finish(report, "producer_membership_does_not_match_frozen_source")
		return
	var moving: Dictionary = groups[2]
	var obstacles: Array = [groups[0].footprint, groups[1].footprint, groups[3].footprint]
	report["obstacleGroups"] = [groups[0].name, groups[1].name, groups[3].name]
	var result: Dictionary = Placement.find_translation(moving.footprint, allowed, obstacles, CLEARANCE)
	report["solver"] = result
	report["originalNearbyScan"] = _nearby_scan(b, boxes, moving, claimed, Vector3.ZERO, [plaza.id, support.id])
	report["frozenProtectedReservations"] = frozen.get("protectedReservations", [])
	report["treeRecords"] = _tree_records(layout)
	if bool(result.get("ready", false)):
		var delta: Vector3 = result.translation
		report["proposedLayoutOffset"] = (specs[2].offset as Vector3) + delta
		report["preservedHouseholdIds"] = moving.allIds
		report["proposedTransforms"] = []
		for id in moving.allIds:
			var part = by_id[id]
			report.proposedTransforms.append({"partId": id, "before": part.position,
				"after": part.position + delta, "rotationUnchanged": part.rotation, "sizeUnchanged": part.size})
		var scan := _nearby_scan(b, boxes, moving, claimed, delta, [plaza.id, support.id])
		report["candidateNearbyScan"] = scan
		report["candidateTreeReservations"] = _tree_overlap_rows(report.treeRecords, result.placedFootprint, CLEARANCE)
		report["candidateClearOfOtherSourceBounds"] = scan.positiveVolumeOverlaps.is_empty()
		report["candidateClearOfTreeEnvelopes"] = report.candidateTreeReservations.is_empty()
		# Stair XZ overlaps remain separate even when the stairs lie below the
		# plaza. A source rectangle scan cannot certify approach/landing access.
		report["candidatePlacementAccepted"] = false
	# Compare the critic's smaller layout margin without changing the primary
	# request or the shared solver. Neither result is a pedestrian proof.
	var comparison: Dictionary = Placement.find_translation(moving.footprint, allowed, obstacles, 0.1)
	var comparison_report := {"clearance": 0.1, "solver": comparison, "candidatePlacementAccepted": false}
	if bool(comparison.get("ready", false)):
		var comparison_delta: Vector3 = comparison.translation
		comparison_report["proposedLayoutOffset"] = (specs[2].offset as Vector3) + comparison_delta
		comparison_report["candidateNearbyScan"] = _nearby_scan(b, boxes, moving, claimed, comparison_delta, [plaza.id, support.id])
		comparison_report["candidateTreeReservations"] = _tree_overlap_rows(report.treeRecords, comparison.placedFootprint, 0.1)
		comparison_report["candidateClearOfOtherSourceBounds"] = comparison_report.candidateNearbyScan.positiveVolumeOverlaps.is_empty()
		comparison_report["candidateClearOfTreeEnvelopes"] = comparison_report.candidateTreeReservations.is_empty()
	report["layoutClearanceComparison"] = comparison_report
	# Third case: reserve newly discovered colliding source bounds from the
	# FIRST candidate scan. No named obstacle exception or new geometry policy.
	# Use the smaller spacing so this case is not just the 0.8 margin rejecting.
	var discovered_obstacles: Array = obstacles.duplicate()
	var discovered_ids: Dictionary = {}
	var discovered_report := {"clearance": 0.1, "addedReservations": [],
		"derivedFrom": "candidateNearbyScan.positiveVolumeOverlaps",
		"baseObstacleGroups": report.obstacleGroups.duplicate(),
		"allowedFootprint": allowed, "movingFootprint": moving.footprint,
		"candidatePlacementAccepted": false, "noRoomUnderDeclaredPolicy": false,
		"policyScope": "Translation only, unchanged complete-household XZ bounding rectangle, actual plaza inset 0.1, original three group reservations plus colliding source AABBs discovered by the first candidate scan, all spaced by 0.1. A no-fit result applies only to these conservative rectangle constraints; not universal placement impossibility, actual publisher geometry, or pedestrian access."}
	var first_scan: Dictionary = report.get("candidateNearbyScan", {})
	for row in first_scan.get("positiveVolumeOverlaps", []):
		var id := String(row.get("partId", ""))
		if not bool(row.get("collision", false)) or claimed.has(id) or discovered_ids.has(id):
			continue
		# Bounds come from the indexed frozen records, not a copied ID/offset.
		var obstacle_bounds: AABB = boxes[id]
		var obstacle_rect := _xz(obstacle_bounds)
		discovered_ids[id] = true
		discovered_obstacles.append(obstacle_rect)
		discovered_report.addedReservations.append({"partId": id, "sourceBounds": obstacle_bounds,
			"footprint": obstacle_rect, "firstCandidateOverlapPairs": row.pairs})
	if not discovered_ids.is_empty():
		var discovered_result: Dictionary = Placement.find_translation(moving.footprint, allowed, discovered_obstacles, 0.1)
		discovered_report["solver"] = discovered_result
		discovered_report["reservationCount"] = discovered_obstacles.size()
		discovered_report["noRoomUnderDeclaredPolicy"] = not bool(discovered_result.get("ready", false)) and String(discovered_result.get("reason", "")) == "no_placement_under_envelope_policy"
		discovered_report["status"] = "solver_complete"
		if bool(discovered_result.get("ready", false)):
			var discovered_delta: Vector3 = discovered_result.translation
			discovered_report["proposedLayoutOffset"] = (specs[2].offset as Vector3) + discovered_delta
			discovered_report["candidateNearbyScan"] = _nearby_scan(b, boxes, moving, claimed, discovered_delta, [plaza.id, support.id])
			discovered_report["candidateTreeReservations"] = _tree_overlap_rows(report.treeRecords, discovered_result.placedFootprint, 0.1)
	else:
		discovered_report["status"] = "not_run_no_new_colliding_obstacles_in_first_candidate_scan"
	report["discoveredCollisionReservationCase"] = discovered_report
	report["extraChecksCompleted"] = false
	_extra_checks(report, b, boxes, groups, claimed)
	report["checks"] = {"sourceUnchanged": before == var_to_bytes(b.snapshot()),
		"frozenFileUnchanged": FileAccess.get_sha256(baseline) == SHA,
		"producerMembershipResolved": true, "noComposerOrPublicationCall": true}
	report["elapsedMsec"] = Time.get_ticks_msec() - started
	report["passed"] = bool(report.checks.sourceUnchanged) and bool(report.checks.frozenFileUnchanged) and bool(report.extraChecksCompleted)
	_finish(report, "diagnostic_complete" if report.passed else "source_preservation_failed")

func _extra_checks(_report: Dictionary, _blueprint, _boxes: Dictionary, _groups: Array, _claimed: Dictionary) -> void:
	_report["extraChecksCompleted"] = true


func _source_group(label: String, scratch, by_id: Dictionary, boxes: Dictionary, claimed: Dictionary) -> Dictionary:
	var result := {"name": label, "ready": false, "allIds": [], "occupiedIds": [], "excludedSurfaceIds": [], "errors": []}
	var footprint := Rect2()
	for expected in scratch.parts:
		var id := String(expected.id)
		result.allIds.append(id)
		if not by_id.has(id) or claimed.has(id):
			result.errors.append({"partId": id, "reason": "missing_or_multiply_claimed_source_id"})
			continue
		claimed[id] = label
		var actual = by_id[id]
		if _surface_detail(actual):
			result.excludedSurfaceIds.append(id)
			continue
		var rect := _xz(boxes[id])
		footprint = rect if result.occupiedIds.is_empty() else footprint.merge(rect)
		result.occupiedIds.append(id)
	result["footprint"] = footprint
	result["ready"] = result.errors.is_empty() and not result.occupiedIds.is_empty()
	return result


func _surface_detail(part) -> bool:
	return String(part.kind) == "ground_patch" or String(part.semantic).contains("wear") or String(part.semantic).contains("compaction")


func _corner_bounds(blueprint, part) -> AABB:
	var transform: Transform3D = blueprint.part_transform(part)
	var half: Vector3 = part.size * 0.5
	var bounds := AABB(transform * -half, Vector3.ZERO)
	for x in [-1.0, 1.0]:
		for y in [-1.0, 1.0]:
			for z in [-1.0, 1.0]:
				bounds = bounds.expand(transform * Vector3(x * half.x, y * half.y, z * half.z))
	return bounds


func _xz(box: AABB) -> Rect2:
	return Rect2(Vector2(box.position.x, box.position.z), Vector2(box.size.x, box.size.z))


func _nearby_scan(blueprint, boxes: Dictionary, moving: Dictionary, claimed: Dictionary, delta: Vector3, support_ids: Array) -> Dictionary:
	var placed := Rect2((moving.footprint as Rect2).position + Vector2(delta.x, delta.z), (moving.footprint as Rect2).size)
	var result := {"positiveVolumeOverlaps": [], "stairProjectionOverlaps": [], "excludedPlazaSupportIds": support_ids,
		"method": "All other visible OR colliding source parts; eight-corner AABBs; positive overlap on all three axes. No blanket foundation exclusion. Stair projections are access warnings, not physical collision claims."}
	for part in blueprint.parts:
		# Other stalls and terminal parts are still scanned, even though their
		# group rectangles were supplied to the solver; original overlaps matter.
		if claimed.get(part.id, "") == moving.name or support_ids.has(part.id) or _surface_detail(part):
			continue
		if not part.collision_enabled and not bool(part.recipe.get("visual", true)):
			continue
		var other: AABB = boxes[part.id]
		if not placed.intersects(_xz(other)):
			continue
		if String(part.kind) in ["stair_tread", "ramp"]:
			result.stairProjectionOverlaps.append({"partId": part.id, "bounds": other})
		var pairs: Array = []
		for id in moving.occupiedIds:
			var shifted: AABB = boxes[id]
			shifted.position += delta
			var overlap := shifted.intersection(other)
			if overlap.size.x > 0.0 and overlap.size.y > 0.0 and overlap.size.z > 0.0:
				pairs.append({"movingPartId": id, "overlapBounds": overlap})
		if not pairs.is_empty():
			result.positiveVolumeOverlaps.append({"partId": part.id, "kind": part.kind,
				"semantic": part.semantic, "collision": part.collision_enabled, "bounds": other, "pairs": pairs})
	return result


func _tree_records(layout: Dictionary) -> Array:
	var rows: Array = []
	for value in layout.get("treePlacements", []):
		if value is Dictionary:
			var request: Dictionary = value.get("treeRequest", {})
			rows.append({"id": value.get("id", ""), "position": value.get("position", Vector3.ZERO),
				"canopyRadius": value.get("canopyRadius", 0.0), "trunkRadius": request.get("trunkRadius", 0.0),
				"rootButtressFootprints": value.get("rootButtressFootprints", [])})
		else:
			rows.append({"position": value, "unresolvedTreeEnvelope": true})
	return rows


func _tree_overlap_rows(trees: Array, placed: Rect2, clearance: float) -> Array:
	var rows: Array = []
	for tree in trees:
		if tree.get("unresolvedTreeEnvelope", false):
			rows.append({"tree": tree, "reason": "missing_generated_tree_envelope"})
			continue
		var position: Vector3 = tree.position
		var radius := maxf(float(tree.canopyRadius), float(tree.trunkRadius))
		var tree_rect := Rect2(Vector2(position.x, position.z) - Vector2.ONE * radius, Vector2.ONE * radius * 2.0)
		for root in tree.rootButtressFootprints:
			var start: Vector3 = root.start
			var end: Vector3 = root.end
			var root_radius := maxf(float(root.radiusStart), float(root.radiusEnd))
			var root_rect := Rect2(Vector2(start.x, start.z), Vector2.ZERO).expand(Vector2(end.x, end.z)).grow(root_radius)
			tree_rect = tree_rect.merge(root_rect)
		if placed.intersects(tree_rect.grow(clearance)):
			rows.append({"id": tree.id, "envelope": tree_rect, "reason": "conservative_XZ_tree_envelope_overlap"})
	return rows


func _json_value(value: Variant) -> Variant:
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Vector2:
		return [value.x, value.y]
	if value is Rect2 or value is AABB:
		return {"position": _json_value(value.position), "size": _json_value(value.size), "end": _json_value(value.end)}
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value:
			result[key] = _json_value(value[key])
		return result
	if value is Array:
		return value.map(func(item): return _json_value(item))
	return value


func _finish(report: Dictionary, status: String) -> void:
	report["status"] = status
	var output := FileAccess.open(_path, FileAccess.WRITE) if not _path.is_empty() else null
	if output == null:
		push_error("Market placement report unavailable: " + status)
		quit(2)
		return
	output.store_string(JSON.stringify(_json_value(report), "\t"))
	output.flush()
	var error := output.get_error()
	output.close()
	print("VOXEL_MARKET_PLACEMENT_REPORT ", _path, " status=", status)
	quit(2 if error != OK else (0 if report.passed else 1))
