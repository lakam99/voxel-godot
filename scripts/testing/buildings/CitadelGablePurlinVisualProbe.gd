extends SceneTree

## Actual mesh-primitive geometry probe, NOT a rendered or gameplay acceptance.
const Castle = preload("res://scripts/buildings/CastleCompoundBlueprintBuilder.gd")
const Urban = preload("res://scripts/buildings/CitadelUrbanPocComposer.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Publisher = preload("res://scripts/buildings/BuildingPartPublisher.gd")
const FurniturePlanner = preload("res://scripts/buildings/CastleFurnishingPlanner.gd")
const FURNITURE_SEED := 208159 * 7919 + 37
# Only these newly installed declarations may differ on the existing roofs.
# Other physical keys, all render recipes, materials and collision are retained.
const FRAME_DECLARATIONS := ["physicalIntent", "physicalGableFrameId", "physicalAssemblyRole", "physicalRequiredPurlinPartIds", "physicalRequiredSeatPartIds", "physicalRequiredSeatFacts"]
const EXPECTED_FRAMES := 16
const EXPECTED_PURLINS := 64
const EXPECTED_PURLIN_SEGMENTS := 64 # One continuous joint-preserving member each.
const EXPECTED_UPRIGHTS := 128
var _published_payloads: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var started := Time.get_ticks_msec()
	var report_path := OS.get_environment("VOXEL_GABLE_VISUAL_REPORT").strip_edges()
	if report_path.is_empty():
		push_error("Set VOXEL_GABLE_VISUAL_REPORT to a writable JSON path")
		quit(2)
		return
	var sat_controls := _sat_controls()
	var integrated = Urban.compose(Castle.build(208159, {"biome": "forest", "siteKey": "river-citadel", "citadelScale": 1.25}), 208159)
	var baseline_path := OS.get_environment("VOXEL_ROOF_INTEGRATION_BASELINE")
	var b = _frozen_unframed(baseline_path)
	if b == null or integrated == null:
		push_error("Integrated composer or immutable unframed baseline unavailable")
		quit(2)
		return
	# Compare original source records before either side resolves derived support.
	var original_parts := _part_records(b)
	var original_rooms: Array = b.rooms.duplicate(true)
	var original_recipe: Dictionary = b.recipe.duplicate(true)
	var before: Dictionary = b.validate_physical_integrity()
	# Planner calls can add derived recipe state: run the actual planner on
	# independent complete blueprint copies, never on the geometry probe source.
	var before_furniture_source = _copy_blueprint(b)
	var publisher = Publisher.new()
	publisher.source_blueprint_id = publisher.canonical_source_blueprint_id(b)
	publisher.surface_history.configure(b.recipe, b.parts)
	var original_roofs: Dictionary = {}
	var original_roof_payloads: Dictionary = {}
	var prefixes: Array = []
	var frame_panels: Dictionary = {}
	for part in b.parts:
		if part.semantic == "citadel_urban_roof" and String(part.id).ends_with("_roof_left"):
			prefixes.append(String(part.id).trim_suffix("_roof_left"))
	for prefix in prefixes:
		for side in ["left", "right"]:
			var id: String = prefix + "_roof_" + side
			original_roofs[id] = _boxes(publisher, b, b.find_part(id))
			original_roof_payloads[id] = (_published_payloads.get(id, {"groups": [], "primitiveCount": 0}) as Dictionary).duplicate(true)
	var setups: Array = []
	var expected_frame_ids: Array = []
	b = integrated
	for prefix in prefixes:
		var panel_ids: Array = [prefix + "_roof_left", prefix + "_roof_right"]
		var frame_id: String = prefix + "_purlin_frame"
		frame_panels[frame_id] = panel_ids
		var member_ids: Array = []
		for part in b.parts:
			if String(part.recipe.get("physicalGableFrameId", "")) == frame_id and not panel_ids.has(String(part.id)):
				member_ids.append(String(part.id))
		var setup := {"ready": member_ids.size() == 12, "partIds": member_ids, "source": "integrated_composer_only"}
		setups.append(setup)
		expected_frame_ids.append_array(panel_ids)
		expected_frame_ids.append_array(setup.get("partIds", []) as Array)
	# Compare before revalidation recomputes derived support coverage: only the
	# explicit roof declarations above may differ in the original source records.
	var preservation := _preservation(b, original_parts, original_rooms, original_recipe, original_roofs.keys())
	print("purlin probe: inspected ", setups.size(), " integrated frames; validate actual seed")
	var after: Dictionary = b.validate_physical_integrity()
	publisher.surface_history.configure(b.recipe, b.parts)
	var roofs_unchanged := true
	var roof_payload_rows: Array = []
	for id in original_roofs:
		# Do not short-circuit extraction after an earlier mismatch.
		var current_boxes := _boxes(publisher, b, b.find_part(id))
		roofs_unchanged = roofs_unchanged and original_roofs[id] == current_boxes
		var payload: Dictionary = _published_payloads.get(id, {"groups": [], "primitiveCount": 0})
		roof_payload_rows.append({"roofId": id, "beforeCount": original_roofs[id].size(), "afterCount": current_boxes.size(),
			"passed": not current_boxes.is_empty() and _digest(original_roof_payloads[id]) == _digest(payload),
			"beforePayload": original_roof_payloads[id], "afterPayload": payload.duplicate(true)})
	var contact_rows: Array = []
	var protrusions: Array = []
	var purlin_envelope_failures: Array = []
	var payloads: Dictionary = {}
	var missing_owners: Array = []
	var purlin_count := 0
	var purlin_segment_count := 0
	for part in b.parts:
		if String(part.recipe.get("physicalAssemblyRole", "")) != "gable_roof_purlin":
			continue
		purlin_count += 1
		var owner = null
		for panel in b.parts:
			if (panel.recipe.get("physicalRequiredPurlinPartIds", []) as Array).has(part.id):
				owner = panel
				break
		if owner == null or not original_roofs.has(String(owner.id)):
			missing_owners.append(part.id)
			continue
		var timber_boxes := _boxes(publisher, b, part)
		purlin_segment_count += timber_boxes.size()
		payloads[String(part.id)] = timber_boxes
		var roof_boxes: Array = original_roofs[owner.id]
		var support_top := -INF
		for post_id in part.recipe.physicalRequiredPostPartIds:
			var post = b.find_part(String(post_id))
			var wall = b.find_part(String(post.recipe.physicalRequiredGableBearerId))
			support_top = maxf(support_top, wall.position.y + wall.size.y * 0.5)
		var contacting_segments := 0
		for timber in timber_boxes:
			for corner in _corners(timber):
				if corner.y < support_top or not _below_finite_roof(b, owner, corner):
					purlin_envelope_failures.append({"partId": part.id, "corner": corner})
			var contacts := 0
			for roof in roof_boxes:
				if _overlap(b, timber, roof):
					contacts += 1
			contacting_segments += int(contacts > 0)
			# The preserved nominal roof upper plane is a conservative envelope
			# check, not proof of finite bearing or complete shingle coverage.
			var relative: Transform3D = b.part_transform(owner).affine_inverse() * timber
			for x in [-0.5, 0.5]:
				for y in [-0.5, 0.5]:
					for z in [-0.5, 0.5]:
						var point := relative * Vector3(x, y, z)
						if point.y > owner.size.y * 0.5:
							protrusions.append({"partId": part.id, "roofLocalPoint": point})
		contact_rows.append({"purlinId": part.id, "roofId": owner.id, "actualSegments": timber_boxes.size(), "segmentsWithZeroMarginShingleOverlap": contacting_segments})
	var uprights := _upright_probe(publisher, b, frame_panels, payloads)
	var chimney_inventory := _chimney_inventory(b, original_parts, expected_frame_ids)
	print("purlin probe: actual CastleFurnishingPlanner before")
	var furniture_started := Time.get_ticks_msec()
	var before_furniture = FurniturePlanner.build(before_furniture_source, FURNITURE_SEED)
	var before_furniture_msec := Time.get_ticks_msec() - furniture_started
	print("purlin probe: actual CastleFurnishingPlanner after")
	furniture_started = Time.get_ticks_msec()
	var after_furniture = FurniturePlanner.build(_copy_blueprint(b), FURNITURE_SEED)
	var after_furniture_msec := Time.get_ticks_msec() - furniture_started
	var furniture := _furniture_parity(before_furniture, after_furniture)
	furniture["beforeElapsedMsec"] = before_furniture_msec
	furniture["afterElapsedMsec"] = after_furniture_msec
	var frame_checks: Array = after.checks.filter(func(c): return expected_frame_ids.has(String(c.partId)))
	var frame_failed: Array = frame_checks.filter(func(c): return not bool(c.passed))
	var baseline_failed_ids := _failed_ids(before)
	var added_failed_ids: Array = []
	for part_id in _failed_ids(after):
		if not baseline_failed_ids.has(part_id):
			added_failed_ids.append(part_id)
	var invalid_payloads: Array = []
	for part_id in _published_payloads:
		var captured: Dictionary = _published_payloads[part_id]
		if int(captured.primitiveCount) == 0 or int(captured.invalidPrimitiveCount) > 0 or not bool(captured.customDataCountsMatch):
			invalid_payloads.append(part_id)
	var checks := {
		"sat_synthetic_controls": bool(sat_controls.passed),
		"all_requested_frames_ready": prefixes.size() == EXPECTED_FRAMES and setups.size() == EXPECTED_FRAMES and setups.all(func(value): return bool(value.get("ready", false))),
		"exact_purlin_and_payload_counts": purlin_count == EXPECTED_PURLINS and contact_rows.size() == EXPECTED_PURLINS and purlin_segment_count == EXPECTED_PURLIN_SEGMENTS,
		"published_payloads_nonempty_finite_nondegenerate": invalid_payloads.is_empty(),
		"original_parts_preserved_except_named_frame_declarations": bool(preservation.passed),
		"roof_primitive_transforms_unchanged": roofs_unchanged and not original_roofs.is_empty(),
		"roof_full_publication_payload_parity": roof_payload_rows.size() == EXPECTED_FRAMES * 2 and roof_payload_rows.all(func(row): return bool(row.passed)),
		"all_frame_and_roof_checks_pass": not frame_checks.is_empty() and frame_checks.size() == expected_frame_ids.size() and frame_failed.is_empty(),
		"no_added_failed_part_ids": added_failed_ids.is_empty(),
		"purlin_payloads_contact_roof": missing_owners.is_empty() and not contact_rows.is_empty() and contact_rows.all(func(row): return int(row.actualSegments) > 0 and row.actualSegments == row.segmentsWithZeroMarginShingleOverlap),
		"purlins_not_above_roof_plane": protrusions.is_empty(),
		"purlin_full_payloads_inside_finite_roof_envelope": purlin_envelope_failures.is_empty(),
		"upright_payload_corners_inside_roof_union_above_wall": bool(uprights.envelopePassed),
		"every_upright_contacts_its_purlin_payload": bool(uprights.contactPassed),
		"every_upright_contacts_its_wall_payload": bool(uprights.wallContactPassed),
		"actual_castle_furniture_full_snapshot_parity": bool(furniture.snapshotsEqual) and bool(furniture.bothReady) and int(furniture.beforePartCount) > 0,
		"actual_castle_furniture_reservations_parity": bool(furniture.reservationsEqual) and bool(furniture.bothReady)
	}
	var passed := checks.values().all(func(value): return bool(value))
	var report := {"evidenceLevel": "actual_source_and_published_mesh_primitive_probe", "seed": 208159, "scale": 1.25,
		"baselinePath": baseline_path, "baselineFileSha256": FileAccess.get_sha256(baseline_path),
		"passed": passed, "checks": checks, "elapsedMsec": Time.get_ticks_msec() - started,
		"beforeViolationCount": before.violations.size(), "afterViolationCount": after.violations.size(),
		"afterViolations": after.violations, "setups": setups, "roofPrimitiveTransformsUnchanged": roofs_unchanged,
		"contactRows": contact_rows, "aboveNominalRoofUpperPlane": protrusions,
		"purlinFiniteEnvelopeFailures": purlin_envelope_failures,
		"purlinCount": purlin_count, "purlinSegmentCount": purlin_segment_count,
		"invalidOrEmptyPayloadPartIds": invalid_payloads,
		"roofPayloadParity": roof_payload_rows,
		"missingPurlinOwners": missing_owners, "originalPreservation": preservation,
		"uprights": uprights, "chimneyIntersectionInventory": chimney_inventory,
		"furniture": furniture, "satControls": sat_controls,
		"frameAndRoofChecks": frame_checks, "newFrameFailedChecks": frame_failed,
		"addedFailedPartIds": added_failed_ids,
		"doesNotProve": "No headed image, GPU drawing/readback, external texture pixel parity, collision publication or gameplay acceptance. Candidate comes only from the integrated composer; baseline is frozen pre-integration source. Payloads are captured before the dummy renderer. Convex finite nominal roof-space containment is not concealment beneath irregular shingles. Upright material embedded into its existing bearer is allowed, but new material outside that seat below wall-top is not. Strict zero-margin contact failures remain failures, not finite bearing or structural safety. Chimney pairs are nominal candidates, not rendered clash adjudication. Furniture parity is service-level, not live placement acceptance. Existing whole-blueprint failures remain reported; passed covers only explicit probe checks."}
	var f := FileAccess.open(report_path, FileAccess.WRITE)
	if f == null:
		quit(2)
		return
	f.store_string(JSON.stringify(report, "\t"))
	f.close()
	print("purlin probe completed: ", "PASS" if passed else "FAIL", " ", before.violations.size(), " -> ", after.violations.size(), " frame failed=", frame_failed.size())
	quit(0 if passed else 1)

func _boxes(publisher, blueprint, part) -> Array:
	if part == null:
		return []
	var parent := Node3D.new()
	# Capture the exact publication payload before the headless dummy renderer:
	# its MultiMesh readback returned identity instances in probe01.
	publisher.static_visual_collecting = true
	publisher.static_visual_part_transform = blueprint.part_transform(part)
	publisher.static_visual_batches.clear()
	publisher.publish_visual(part, parent)
	var result: Array = []
	var groups: Array = []
	var custom_data_counts_match := true
	for group in publisher.static_visual_batches.values():
		result.append_array(group.transforms)
		custom_data_counts_match = custom_data_counts_match and (group.get("customData", []) as Array).size() == (group.transforms as Array).size()
		groups.append({"transforms": group.transforms.duplicate(true), "customData": (group.get("customData", []) as Array).duplicate(true),
			"material": _value_snapshot(group.get("material"), {})})
	var invalid_count := 0
	for transform in result:
		invalid_count += int(not _valid_box(transform))
	_published_payloads[String(part.id)] = {"groups": groups, "primitiveCount": result.size(),
		"invalidPrimitiveCount": invalid_count, "customDataCountsMatch": custom_data_counts_match}
	parent.free()
	return result

func _overlap(_blueprint, first: Transform3D, second: Transform3D) -> bool:
	return _separation(first, second) <= 0.0

func _separation(first: Transform3D, second: Transform3D) -> float:
	# Affine box SAT retains publisher shear; decomposing into Euler+scale does not.
	if not _valid_box(first) or not _valid_box(second):
		return INF
	var a := [first.basis.x, first.basis.y, first.basis.z]
	var b := [second.basis.x, second.basis.y, second.basis.z]
	var axes: Array = []
	for index in range(3):
		axes.append(_cross64(a[index], a[(index + 1) % 3]))
		axes.append(_cross64(b[index], b[(index + 1) % 3]))
		for other in range(3):
			axes.append(_cross64(a[index], b[other]))
	var greatest_gap := -INF
	for raw_axis in axes:
		var axis: Array = raw_axis
		var length_squared: float = axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]
		if length_squared < 0.000000000001:
			continue
		var length := sqrt(length_squared)
		for component in range(3):
			axis[component] /= length
		var radius := 0.0
		for index in range(3):
			radius += 0.5 * (absf(_dot64(axis, a[index])) + absf(_dot64(axis, b[index])))
		# GDScript scalar floats retain the authored matrix components without
		# an additional float32 Vector3 subtraction/dot-product rounding step.
		var distance: float = absf(axis[0] * (float(first.origin.x) - float(second.origin.x)) + axis[1] * (float(first.origin.y) - float(second.origin.y)) + axis[2] * (float(first.origin.z) - float(second.origin.z)))
		greatest_gap = maxf(greatest_gap, distance - radius)
	return greatest_gap

func _cross64(first: Vector3, second: Vector3) -> Array:
	return [float(first.y) * float(second.z) - float(first.z) * float(second.y),
		float(first.z) * float(second.x) - float(first.x) * float(second.z),
		float(first.x) * float(second.y) - float(first.y) * float(second.x)]


func _dot64(first: Array, second: Vector3) -> float:
	return first[0] * float(second.x) + first[1] * float(second.y) + first[2] * float(second.z)


func _valid_box(box: Transform3D) -> bool:
	if not box.origin.is_finite() or not box.basis.x.is_finite() or not box.basis.y.is_finite() or not box.basis.z.is_finite():
		return false
	var scale_product := box.basis.x.length() * box.basis.y.length() * box.basis.z.length()
	var determinant := box.basis.determinant()
	# Relative degeneracy threshold, not a world-space contact margin. No
	# Euler decomposition or orthogonalization: legitimate shear is preserved.
	return is_finite(scale_product) and is_finite(determinant) and scale_product > 0.0 and absf(determinant) > scale_product * 1.0e-10


func _sat_controls() -> Dictionary:
	var identity := Transform3D.IDENTITY
	var shear := Transform3D(Basis(Vector3(1.0, 0.0, 0.0), Vector3(1.5, 1.0, 0.0), Vector3(0.0, 0.0, 1.0)), Vector3.ZERO)
	var tiny := Basis.IDENTITY.scaled(Vector3(0.1, 0.1, 0.1))
	var cases: Array = [
		{"id": "identical", "a": identity, "b": identity, "expected": true},
		{"id": "separated", "a": identity, "b": Transform3D(Basis.IDENTITY, Vector3(1.01, 0, 0)), "expected": false},
		{"id": "exact_face_touch", "a": identity, "b": Transform3D(Basis.IDENTITY, Vector3(1, 0, 0)), "expected": true},
		{"id": "represented_submicrometre_gap", "a": identity, "b": Transform3D(Basis.IDENTITY, Vector3(1.0000001192092896, 0, 0)), "expected": false},
		{"id": "represented_millimetre_gap", "a": identity, "b": Transform3D(Basis.IDENTITY, Vector3(1.001, 0, 0)), "expected": false},
		{"id": "large_coordinate_exact_contact", "a": Transform3D(Basis.IDENTITY, Vector3(1048576, 0, 0)), "b": Transform3D(Basis.IDENTITY, Vector3(1048577, 0, 0)), "expected": true},
		{"id": "large_coordinate_represented_gap", "a": Transform3D(Basis.IDENTITY, Vector3(1048576, 0, 0)), "b": Transform3D(Basis.IDENTITY, Vector3(1048577.125, 0, 0)), "expected": false},
		{"id": "sheared_identical", "a": shear, "b": shear, "expected": true},
		{"id": "sheared_inside", "a": shear, "b": Transform3D(tiny, Vector3(1.05, 0.45, 0)), "expected": true},
		# Inside the shear's AABB, but outside the actual affine box.
		{"id": "sheared_aabb_false_positive", "a": shear, "b": Transform3D(tiny, Vector3(-1.05, 0.45, 0)), "expected": false},
		{"id": "nan_origin", "a": identity, "b": Transform3D(Basis.IDENTITY, Vector3(NAN, 0, 0)), "expected": false},
		{"id": "infinite_basis", "a": identity, "b": Transform3D(Basis(Vector3(INF, 0, 0), Vector3.UP, Vector3.BACK), Vector3.ZERO), "expected": false},
		{"id": "zero_basis", "a": identity, "b": Transform3D(Basis(Vector3.ZERO, Vector3.UP, Vector3.BACK), Vector3.ZERO), "expected": false},
		{"id": "parallel_basis", "a": identity, "b": Transform3D(Basis(Vector3.RIGHT, Vector3.RIGHT, Vector3.BACK), Vector3.ZERO), "expected": false}
	]
	var rows: Array = []
	for value in cases:
		var forward := _overlap(null, value.a, value.b)
		var reverse := _overlap(null, value.b, value.a)
		rows.append({"id": value.id, "expected": value.expected, "forward": forward, "reverse": reverse,
			"passed": forward == bool(value.expected) and reverse == bool(value.expected)})
	return {"evidenceLevel": "synthetic_affine_SAT_contract", "passed": rows.all(func(row): return bool(row.passed)), "cases": rows}


func _upright_probe(publisher, blueprint, frame_panels: Dictionary, payloads: Dictionary) -> Dictionary:
	var rows: Array = []
	var violations: Array = []
	var segments_total := 0
	var wall_payloads: Dictionary = {}
	for post in blueprint.parts:
		if String(post.recipe.get("physicalAssemblyRole", "")) != "gable_roof_post":
			continue
		var frame_id := String(post.recipe.get("physicalGableFrameId", ""))
		var panel_ids: Array = frame_panels.get(frame_id, []) as Array
		var bearer = blueprint.find_part(String(post.recipe.get("physicalRequiredGableBearerId", "")))
		var owners: Array = []
		for candidate in blueprint.parts:
			if String(candidate.recipe.get("physicalAssemblyRole", "")) == "gable_roof_purlin" and String(candidate.recipe.get("physicalGableFrameId", "")) == frame_id and (candidate.recipe.get("physicalRequiredPostPartIds", []) as Array).has(String(post.id)):
				owners.append(candidate)
		var boxes := _boxes(publisher, blueprint, post)
		segments_total += boxes.size()
		var row := {"postId": post.id, "bearerId": "" if bearer == null else String(bearer.id),
			"panelIds": panel_ids, "ownerCount": owners.size(), "actualSegments": boxes.size(),
			"cornerCount": 0, "insideEnvelopeCorners": 0, "aboveWallTopCorners": 0, "embeddedSeatCorners": 0,
			"contactPairs": [], "wallContactPairs": [], "envelopePassed": false, "contactPassed": false, "wallContactPassed": false,
			"publicationPayload": _published_payloads[String(post.id)]}
		if bearer == null or panel_ids.size() != 2 or owners.size() != 1 or boxes.is_empty():
			violations.append({"postId": post.id, "reason": "missing_bearer_panels_owner_or_payload"})
			rows.append(row)
			continue
		var wall_top: float = bearer.position.y + bearer.size.y * 0.5
		if not wall_payloads.has(bearer.id):
			wall_payloads[bearer.id] = _boxes(publisher, blueprint, bearer)
		var wall_boxes: Array = wall_payloads[bearer.id]
		row["wallTopY"] = wall_top
		var minimum_above_wall := INF
		var purlin = owners[0]
		row["purlinId"] = purlin.id
		var purlin_boxes: Array = payloads.get(String(purlin.id), []) as Array
		var nearest_purlin_gap := INF
		var nearest_wall_gap := INF
		for segment_index in range(boxes.size()):
			var box: Transform3D = boxes[segment_index]
			var common_roofs: Array = panel_ids.duplicate()
			if not _valid_box(box):
				violations.append({"postId": post.id, "segment": segment_index, "reason": "invalid_payload_basis"})
				continue
			for corner in _corners(box):
				row["cornerCount"] += 1
				var delta: float = corner.y - wall_top
				minimum_above_wall = minf(minimum_above_wall, delta)
				var above_wall := delta >= 0.0
				var wall_local: Vector3 = blueprint.part_transform(bearer).affine_inverse() * corner
				var inside_seat: bool = absf(wall_local.x) <= bearer.size.x * 0.5 and absf(wall_local.y) <= bearer.size.y * 0.5 and absf(wall_local.z) <= bearer.size.z * 0.5
				var memberships: Array = []
				for panel_id in panel_ids:
					var panel = blueprint.find_part(String(panel_id))
					if panel != null and _below_finite_roof(blueprint, panel, corner):
						memberships.append(panel_id)
				row["aboveWallTopCorners"] += int(above_wall)
				row["embeddedSeatCorners"] += int(not above_wall and inside_seat)
				row["insideEnvelopeCorners"] += int(not memberships.is_empty())
				common_roofs = common_roofs.filter(func(id): return memberships.has(id))
				if not (above_wall or inside_seat) or memberships.is_empty():
					violations.append({"postId": post.id, "segment": segment_index, "worldCorner": corner,
						"aboveWallTopBy": delta, "containingRoofEnvelopes": memberships})
			for purlin_index in range(purlin_boxes.size()):
				nearest_purlin_gap = minf(nearest_purlin_gap, _separation(box, purlin_boxes[purlin_index]))
				if _overlap(blueprint, box, purlin_boxes[purlin_index]):
					row["contactPairs"].append({"postSegment": segment_index, "purlinSegment": purlin_index})
			if common_roofs.is_empty():
				violations.append({"postId": post.id, "segment": segment_index, "reason": "whole_primitive_not_inside_one_convex_roof_envelope"})
			for wall_index in range(wall_boxes.size()):
				nearest_wall_gap = minf(nearest_wall_gap, _separation(box, wall_boxes[wall_index]))
				if _overlap(blueprint, box, wall_boxes[wall_index]):
					row["wallContactPairs"].append({"postSegment": segment_index, "wallSegment": wall_index})
		row["minimumAboveWallTop"] = minimum_above_wall
		row["nearestPurlinSeparation"] = nearest_purlin_gap
		row["nearestWallSeparation"] = nearest_wall_gap
		row["envelopePassed"] = row.cornerCount == boxes.size() * 8 and row.insideEnvelopeCorners == row.cornerCount and row.aboveWallTopCorners + row.embeddedSeatCorners == row.cornerCount
		row["contactPassed"] = not purlin_boxes.is_empty() and not (row.contactPairs as Array).is_empty()
		row["wallContactPassed"] = not wall_boxes.is_empty() and not (row.wallContactPairs as Array).is_empty()
		rows.append(row)
	return {"expectedUprights": EXPECTED_UPRIGHTS, "uprightCount": rows.size(), "actualSegmentCount": segments_total,
		"envelopePassed": rows.size() == EXPECTED_UPRIGHTS and violations.is_empty() and rows.all(func(row): return bool(row.envelopePassed)),
		"contactPassed": rows.size() == EXPECTED_UPRIGHTS and rows.all(func(row): return bool(row.contactPassed)),
		"wallContactPassed": rows.size() == EXPECTED_UPRIGHTS and rows.all(func(row): return bool(row.wallContactPassed)),
		"rows": rows, "cornerViolations": violations, "geometricTolerance": 0.0,
		"envelopeDefinition": "Each whole affine primitive must fit one convex finite roof projection. Below wall-top, corners must be inside the existing declared bearer solid (seated joinery), not newly exposed material. No arbitrary spatial margin or infinite-plane-only pass.",
		"contactDefinition": "At least one real upright segment touches/intersects at least one segment of its uniquely declared purlin at zero margin; lower segments need not touch the purlin."}


func _below_finite_roof(blueprint, panel, world_point: Vector3) -> bool:
	var transform: Transform3D = blueprint.part_transform(panel)
	if not world_point.is_finite() or not _valid_box(transform) or not blueprint.has_finite_positive_bounds(panel):
		return false
	var inverse := transform.affine_inverse()
	var point := inverse * world_point
	var local_up := inverse.basis * Vector3.UP
	if local_up.y <= 0.0:
		return false
	var upward_distance: float = (panel.size.y * 0.5 - point.y) / local_up.y
	if not is_finite(upward_distance) or upward_distance < 0.0:
		return false
	var top := point + local_up * upward_distance
	return absf(top.x) <= panel.size.x * 0.5 and absf(top.z) <= panel.size.z * 0.5


func _corners(box: Transform3D) -> Array[Vector3]:
	var result: Array[Vector3] = []
	for x in [-0.5, 0.5]:
		for y in [-0.5, 0.5]:
			for z in [-0.5, 0.5]:
				result.append(box * Vector3(x, y, z))
	return result


func _chimney_inventory(blueprint, originals: Dictionary, frame_ids: Array) -> Dictionary:
	var chimneys: Array = []
	var members: Array = []
	for part in blueprint.parts:
		if originals.has(String(part.id)) and (String(part.semantic).contains("chimney") or String(part.id).contains("chimney")):
			chimneys.append(part)
		if frame_ids.has(String(part.id)) and not originals.has(String(part.id)):
			members.append(part)
	var pairs: Array = []
	for member in members:
		var member_box := _nominal_box(blueprint, member)
		for chimney in chimneys:
			var chimney_box := _nominal_box(blueprint, chimney)
			if _overlap(blueprint, member_box, chimney_box):
				pairs.append({"framePartId": member.id, "frameRole": member.recipe.get("physicalAssemblyRole", ""),
					"chimneyId": chimney.id, "frameNominalTransform": member_box, "chimneyNominalTransform": chimney_box,
					"classification": "candidate_intersection_not_adjudicated"})
	return {"newMemberCount": members.size(), "existingChimneyCount": chimneys.size(),
		"testedPairCount": members.size() * chimneys.size(), "candidateCount": pairs.size(), "candidates": pairs,
		"isPassFailGate": false, "scope": "All new frame members against all existing chimney-tagged/id parts; nominal affine boxes at zero margin. Touching and valid joinery are not automatically defects."}


func _nominal_box(blueprint, part) -> Transform3D:
	return blueprint.part_transform(part) * Transform3D(Basis.IDENTITY.scaled(part.size), Vector3.ZERO)


func _preservation(blueprint, originals: Dictionary, rooms: Array, recipe: Dictionary, roof_ids: Array) -> Dictionary:
	var current := _part_records(blueprint)
	var changed: Array = []
	for part_id in originals:
		if not current.has(part_id):
			changed.append({"partId": part_id, "reason": "removed"})
			continue
		var expected: Dictionary = originals[part_id].duplicate(true)
		var actual: Dictionary = current[part_id].duplicate(true)
		if roof_ids.has(part_id):
			# Normalize only explicitly authorized new roof declarations to the
			# old record. Shape, transform, material, semantic, collision and every
			# unrelated physical/render recipe field remain exact comparisons.
			actual["physicalIntent"] = expected.get("physicalIntent", "")
			for key in FRAME_DECLARATIONS:
				if (expected.recipe as Dictionary).has(key):
					actual.recipe[key] = expected.recipe[key]
				else:
					(actual.recipe as Dictionary).erase(key)
		if _digest(expected) != _digest(actual):
			changed.append({"partId": part_id, "reason": "unexpected_record_change", "before": expected, "after": actual})
	var rooms_equal := _digest(rooms) == _digest(blueprint.rooms)
	var recipe_equal := _digest(recipe) == _digest(blueprint.recipe)
	var unique_ids: bool = current.size() == blueprint.parts.size()
	return {"passed": changed.is_empty() and rooms_equal and recipe_equal and unique_ids,
		"originalPartCount": originals.size(), "currentPartCount": blueprint.parts.size(), "uniquePartIds": unique_ids,
		"unexpectedChanges": changed, "roomsEqual": rooms_equal, "blueprintRecipeEqual": recipe_equal,
		"originalRecordsDigest": _digest(originals), "roomsBeforeDigest": _digest(rooms), "roomsAfterDigest": _digest(blueprint.rooms),
		"comparisonStage": "Immediately after frame installation, before derived physical support revalidation or furniture services.",
		"ignoredOnOriginalRoofsOnly": FRAME_DECLARATIONS + ["top-level physicalIntent"]}


func _part_records(blueprint) -> Dictionary:
	var records: Dictionary = {}
	for part in blueprint.parts:
		records[String(part.id)] = part.snapshot()
	return records


func _frozen_unframed(path: String):
	# This fixture never regenerates its control through the changed composer.
	if FileAccess.get_sha256(path) != "7d218cb03d293304bb06f2f4dce492db503ff54a8091b525de93563b42549ec5":
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var envelope = file.get_var(false)
	if not envelope is Dictionary or not envelope.get("unframedSource") is Dictionary:
		return null
	var record: Dictionary = envelope.unframedSource
	var copy = Blueprint.new(record.id, record.seed, record.style)
	copy.recipe = record.recipe.duplicate(true)
	copy.rooms = record.rooms.duplicate(true)
	for part in record.parts:
		copy.add_part(part)
	return copy


func _copy_blueprint(source):
	var copy = Blueprint.new(source.id, source.seed, source.style)
	copy.recipe = source.recipe.duplicate(true)
	copy.rooms = source.rooms.duplicate(true)
	for part in source.parts:
		copy.add_part(part.snapshot())
	return copy


func _furniture_parity(before, after) -> Dictionary:
	var both_ready := before != null and after != null
	var before_snapshot: Dictionary = {} if before == null else before.snapshot()
	var after_snapshot: Dictionary = {} if after == null else after.snapshot()
	var before_reservations: Array = [] if before == null else before.protected_access_reservations.duplicate()
	var after_reservations: Array = [] if after == null else after.protected_access_reservations.duplicate()
	return {"planner": "CastleFurnishingPlanner.build", "seed": FURNITURE_SEED,
		"bothReady": both_ready, "beforePartCount": 0 if before == null else before.parts.size(),
		"afterPartCount": 0 if after == null else after.parts.size(),
		"snapshotsEqual": both_ready and _digest(before_snapshot) == _digest(after_snapshot),
		"reservationsEqual": both_ready and _digest(before_reservations) == _digest(after_reservations),
		"beforeSnapshotDigest": _digest(before_snapshot), "afterSnapshotDigest": _digest(after_snapshot),
		"beforeFullSnapshot": before_snapshot, "afterFullSnapshot": after_snapshot,
		"beforeProtectedReservations": before_reservations, "afterProtectedReservations": after_reservations}


func _failed_ids(result: Dictionary) -> Array:
	var ids: Array = []
	for check in result.get("checks", []):
		if not bool(check.get("passed", false)):
			ids.append(String(check.get("partId", "")))
	return ids


func _digest(value: Variant) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(var_to_bytes(value))
	return context.finish().hex_encode()


func _value_snapshot(value: Variant, visited: Dictionary) -> Variant:
	if value is Resource:
		var resource: Resource = value
		var identity := str(resource.get_instance_id())
		var record := {"class": resource.get_class(), "path": resource.resource_path, "instanceId": identity}
		if visited.has(identity):
			record["referenceOnly"] = true
			return record
		var next := visited.duplicate()
		next[identity] = true
		if resource is Material or resource is Shader:
			var properties: Dictionary = {}
			for property in resource.get_property_list():
				var property_name := String(property.name)
				if (int(property.usage) & PROPERTY_USAGE_STORAGE) != 0 or property_name.begins_with("shader_parameter/"):
					properties[property_name] = _value_snapshot(resource.get(property_name), next)
			record["storedPropertiesAndShaderParameters"] = properties
		else:
			record["externalResourceContentsNotExpanded"] = true
		return record
	if value is Array:
		var result: Array = []
		for item in value:
			result.append(_value_snapshot(item, visited))
		return result
	if value is Dictionary:
		var result: Dictionary = {}
		for key in value:
			result[key] = _value_snapshot(value[key], visited)
		return result
	return value
