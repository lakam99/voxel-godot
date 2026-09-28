extends "res://scripts/testing/buildings/CitadelGablePurlinVisualProbe.gd"

## Source/publisher-payload diagnostic; no headed or gameplay acceptance.
const TerminalFrame = preload("res://scripts/buildings/TerminalShopFrameBuilder.gd")
const FROZEN_SHA := "7d218cb03d293304bb06f2f4dce492db503ff54a8091b525de93563b42549ec5"

func _run() -> void:
	var path := OS.get_environment("VOXEL_TERMINAL_VISUAL_REPORT")
	var baseline_path := OS.get_environment("VOXEL_ROOF_INTEGRATION_BASELINE")
	if path.is_empty() or FileAccess.get_sha256(baseline_path) != FROZEN_SHA:
		quit(2)
		return
	var file := FileAccess.open(baseline_path, FileAccess.READ)
	var frozen: Dictionary = file.get_var(false)
	file.close()
	var record: Dictionary = frozen.output.sourceSnapshot
	var b = Blueprint.new(record.id, record.seed, record.style)
	b.recipe = record.recipe.duplicate(true)
	b.rooms = record.rooms.duplicate(true)
	for part in record.parts:
		b.add_part(part)
	var before: Dictionary = b.validate_physical_integrity()
	var original := _part_records(b)
	var setups: Array = []
	for index in range(3):
		setups.append(TerminalFrame.add_frame(b, "urban_terminal_%02d" % index, "urban_market_plaza_retaining"))
	var after: Dictionary = b.validate_physical_integrity()
	var publisher = Publisher.new()
	publisher.source_blueprint_id = publisher.canonical_source_blueprint_id(b)
	publisher.surface_history.configure(b.recipe, b.parts)
	var boxes: Dictionary = {}
	var joints: Array = []
	var collision_rows: Array = []
	var affected: Array = []
	var obstruction_candidates: Array = []
	for part in b.parts:
		if not String(part.id).begins_with("urban_terminal_"):
			continue
		var seat_facts: Array = part.recipe.get("physicalRequiredSeatFacts", [])
		var anchor_facts: Array = part.recipe.get("physicalRequiredAnchorFacts", [])
		if seat_facts.is_empty() and anchor_facts.is_empty():
			continue
		affected.append(part.id)
		var member_boxes := _cached_boxes(boxes, publisher, b, part)
		for fact in seat_facts + anchor_facts:
			var anchor_id := String(fact.get("seatId", fact.get("anchorId", "")))
			var anchor = b.find_part(anchor_id)
			var anchor_boxes := _cached_boxes(boxes, publisher, b, anchor)
			var gap := INF
			for first in member_boxes:
				for second in anchor_boxes:
					gap = minf(gap, _separation(first, second))
			var valid_declared: bool = b.has_rooted_bearer_seat(part, fact) if fact.has("seatId") else b.has_rooted_attachment_socket(part, fact)
			var detail: Dictionary = b.gravity_bearing_diagnostics(part, anchor, fact) if fact.get("loadDirection", "") == "world_down" else b.housed_overlap_diagnostics(part, anchor, fact) if fact.get("contactMode", "") == "housed_overlap" else b.attachment_socket_diagnostics(part, fact)
			joints.append({"partId": part.id, "anchorId": anchor_id, "declaredJointValid": valid_declared,
				"strictPayloadContact": gap <= 0.0, "signedSeparation": gap, "diagnostic": detail})
		if part.collision_enabled:
			var root := Node3D.new()
			publisher.static_visual_collecting = false
			publisher.batch_static_parts = false
			var body = publisher.publish_part(part, root)
			var collisions: Array = []
			for child in body.get_children():
				if child is CollisionShape3D and child.shape is BoxShape3D:
					collisions.append(body.transform * child.transform * Transform3D(Basis.IDENTITY.scaled(child.shape.size), Vector3.ZERO))
			var exact_visible_match: bool = collisions.size() == 1 and member_boxes.size() == 1 and (collisions[0] as Transform3D).is_equal_approx(member_boxes[0])
			collision_rows.append({"partId": part.id, "actualCollisionCount": collisions.size(), "actualVisualCount": member_boxes.size(),
				"sameBoxWithinTransformArithmeticPrecision": exact_visible_match, "collisionTransforms": collisions, "visualTransforms": member_boxes,
				"previousCollision": bool((original.get(part.id, {}) as Dictionary).get("collision", false))})
			root.free()
			for other in b.parts:
				if not original.has(other.id) or not String(other.id).begins_with("urban_terminal_") or other == part or other.kind == "beam":
					continue
				var gap := _separation(_nominal_box(b, part), _nominal_box(b, other))
				if gap <= 0.0:
					obstruction_candidates.append({"framePartId": part.id, "originalPartId": other.id,
					"semantic": other.semantic, "nominalSignedSeparation": gap, "classification": "candidate_contact_requires_joinery_or_interference_review"})
	var target_checks: Array = after.checks.filter(func(check): return affected.has(check.partId))
	# A new frame can incidentally root unrelated nearby attachments. Record
	# their actual visible contact separately; a lower violation count alone
	# does not distinguish useful joinery from interpenetrating structures.
	var previously_failed: Dictionary = {}
	for check in before.checks:
		if not bool(check.passed):
			previously_failed[check.partId] = true
	var collateral_contacts: Array = []
	for check in after.checks:
		if not bool(check.passed) or not previously_failed.has(check.partId) or affected.has(check.partId):
			continue
		var member = b.find_part(check.partId)
		for anchor_id in check.get("anchorPartIds", []):
			var anchor = b.find_part(anchor_id)
			var gap := INF
			for first in _cached_boxes(boxes, publisher, b, member):
				for second in _cached_boxes(boxes, publisher, b, anchor):
					gap = minf(gap, _separation(first, second))
			collateral_contacts.append({"partId": member.id, "anchorId": anchor_id,
				"signedPayloadSeparation": gap, "strictPayloadContact": gap <= 0.0,
				"classification": "incidental_rooting_requires_architectural_review"})
	var failed_checks: Array = target_checks.filter(func(check): return not bool(check.passed))
	var checks := {"all_three_setups_ready": setups.size() == 3 and setups.all(func(value): return bool(value.get("ready", false))),
		"all_declared_joints_valid": not joints.is_empty() and joints.all(func(row): return bool(row.declaredJointValid)),
		"all_strict_payload_contacts": not joints.is_empty() and joints.all(func(row): return bool(row.strictPayloadContact)),
		"collision_matches_visible_box": collision_rows.size() == 24 and collision_rows.all(func(row): return bool(row.sameBoxWithinTransformArithmeticPrecision)),
		"affected_physical_checks_pass": target_checks.size() == 33 and failed_checks.is_empty()}
	var report := {"evidenceLevel": "source_and_actual_publisher_payload_probe", "passed": checks.values().all(func(value): return bool(value)), "checks": checks,
		"baselineSha256": FROZEN_SHA, "beforeViolationCount": before.violations.size(), "afterViolationCount": after.violations.size(),
		"setups": setups, "joints": joints, "failedAffectedChecks": failed_checks, "collisions": collision_rows,
		"obstructionCandidates": obstruction_candidates, "collateralContacts": collateral_contacts, "afterViolations": after.violations,
		"doesNotProve": "No headed image, gameplay traversal, engineering safety or GPU readback. Strict contact uses zero margin. Collision/visual box equality allows only Transform3D arithmetic precision, not contact allowance. Obstruction candidates include intended cloth/frame/shelf contact and require review, not automatic acceptance. Prototype is not wired into the composer."}
	var output := FileAccess.open(path, FileAccess.WRITE)
	if output == null:
		quit(2)
		return
	output.store_string(JSON.stringify(report, "\t"))
	print("Terminal payload probe: ", report.passed, " ", before.violations.size(), " -> ", after.violations.size(), " failed affected=", failed_checks.size())
	quit(0 if report.passed else 1)

func _cached_boxes(cache: Dictionary, publisher, blueprint, part) -> Array:
	if part == null:
		return []
	if not cache.has(part.id):
		cache[part.id] = _boxes(publisher, blueprint, part)
	return cache[part.id]
