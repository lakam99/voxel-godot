extends "res://scripts/testing/buildings/CitadelChimneyPublishedContract.gd"

## Focused actual CPU publication measurement, NOT visual/gameplay acceptance.
const DoorPlan = preload("res://scripts/testing/buildings/CitadelFacadeVisualPlan.gd")
const DoorCopy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const DoorMount = preload("res://scripts/buildings/DoorHoodBracketMountRecipe.gd")
const ContactWitness = preload("res://scripts/testing/buildings/PublishedBoxContactWitness.gd")
const DoorGeometry = preload("res://scripts/buildings/BuildingDoorGeometry.gd")
const JOINT_RADIUS := 0.002 # Explicit 2mm interior witness, not a contact tolerance.
var _door_payloads: Dictionary = {}
var _door_old_payloads: Dictionary = {}
var _door_old_publisher
var _door_old_blueprint

func _run() -> void:
	_started_msec = Time.get_ticks_msec()
	_next_progress_msec = _started_msec + 10000
	var path := OS.get_environment("VOXEL_DOOR_BRACKET_PUBLISHED_REPORT")
	if not path.is_absolute_path() or FileAccess.file_exists(path) or not DirAccess.dir_exists_absolute(path.get_base_dir()):
		quit(2)
		return
	var source: Dictionary = DoorPlan.read_input("candidate")
	if source.is_empty():
		quit(2)
		return
	var b = DoorCopy.copy_blueprint(source.afterSnapshot)
	var original = DoorCopy.copy_blueprint(source.afterSnapshot)
	var membership: Dictionary = DoorCopy.street_house_memberships(b)
	if not membership.ready:
		quit(2)
		return
	var by_id: Dictionary = {}
	for part in b.parts: by_id[part.id] = part
	var rows: Array = []
	for house in membership.houses:
		var panels: Array = house.facadeIds.map(func(id): return by_id[id])
		for id in house.memberIds:
			if not id.begins_with(house.prefix + "_door_bracket_"): continue
			var result: Dictionary = DoorMount.prepare(b, by_id[id], by_id[house.doorId], by_id.get(house.prefix + "_door_hood"), panels)
			if not result.ready:
				_stop_reason = "candidate_preparation_failed:" + id
				break
			by_id[id].position = result.part.position
			rows.append({"partId": id, "prefix": house.prefix, "doorId": house.doorId,
				"hoodId": house.prefix + "_door_hood", "selectedPierId": result.pierId})
	var candidate_source: Dictionary = b.snapshot()
	DoorCopy.clear_caches(b)
	print("bracket publication: current physical authority")
	var physical: Dictionary = b.validate_physical_integrity()
	var publisher = _configured_publisher(b)
	var old_publisher = _configured_publisher(original)
	_door_old_publisher = old_publisher
	_door_old_blueprint = original
	for part in original.parts: original.physical_parts_by_id[part.id] = part
	var collider := ColliderPublisher.new()
	var measured: Array = []
	for row in rows:
		if not _within_budget(): break
		var bracket = b.find_part(row.partId)
		var payload: Dictionary = _door_visual(publisher, b, bracket)
		var hood: Dictionary = _door_visual(publisher, b, b.find_part(row.hoodId))
		var pier: Dictionary = _door_visual(publisher, b, b.find_part(row.selectedPierId))
		var door: Dictionary = _door_visual(publisher, b, b.find_part(row.doorId))
		var original_bracket = original.parts.filter(func(p): return p.id == row.partId)[0]
		var old_payload: Dictionary = _door_old_payloads[row.partId]
		row["shortBeamProfileAndAppearanceExact"] = payload.primitives.size() == 1 and old_payload.primitives.size() == 1 and payload.primitives[0].type == "box" and old_payload.primitives[0].type == "box" and payload.primitives[0].transform.basis == old_payload.primitives[0].transform.basis and payload.primitives[0].materialDigests == old_payload.primitives[0].materialDigests and payload.primitives[0].customData == old_payload.primitives[0].customData and payload.primitives[0].castShadow == old_payload.primitives[0].castShadow
		row["originalBracketPayload"] = old_payload
		row["materialRequestKey"] = "%s:%0.3f" % [bracket.material_id, publisher.variation_for(bracket)]
		row["requestedVariationExact"] = publisher.variation_for(bracket) == old_publisher.variation_for(original_bracket)
		var roots: Array = []
		var root_payloads: Array = []
		for id in bracket.recipe.get("physicalAnchorPartIds", []):
			var anchor = b.find_part(id)
			if anchor == null or not id.begins_with(row.prefix + "_") or not b.has_rooted_support_chain(anchor, {}): continue
			roots.append(id)
			root_payloads.append(_door_visual(publisher, b, anchor))
		row["ownRootedAnchorIds"] = roots
		row["rootedWallRearContact"] = _door_witness(payload, root_payloads, "rear")
		row["selectedPierRearContact"] = _door_witness(payload, [pier], "rear")
		row["hoodFrontContact"] = _door_witness(payload, [hood], "front")
		row["selectedPierRooted"] = b.has_rooted_support_chain(b.find_part(row.selectedPierId), {})
		row["closedDoorOverlap"] = _classify_overlap(payload, door)
		row["oldClosedDoorOverlap"] = _classify_overlap(old_payload, door)
		row["doorContactPrimitives"] = _door_contacts(payload, door)
		row["doorPrimitiveBindings"] = _door_bindings(door, b.find_part(row.doorId))
		row["collisionUnchangedEmpty"] = _collision_payload(collider, bracket).primitives.is_empty() and _collision_payload(collider, original_bracket).primitives.is_empty()
		row["physicalCheck"] = physical.checks.filter(func(check): return check.partId == row.partId)
		row["bracketPayload"] = payload
		row["hoodPayload"] = hood
		measured.append(row)
		print("bracket publication ", measured.size(), "/", rows.size(), " ", row.partId)
	var complete: bool = _stop_reason.is_empty() and rows.size() == 32 and measured.size() == rows.size()
	var report := {"evidenceLevel": "actual_cpu_publication_focused_bracket_contact_measurement",
		"complete": complete, "stopReason": _stop_reason, "sourceDigest": DoorPlan.digest(source.afterSnapshot),
		"candidateSourceDigest": DoorPlan.digest(candidate_source), "seed": source.fixture.seed, "scale": source.fixture.citadelScale,
		"sourceFailureCount": DoorCopy.failed_ids(physical).size(), "minimumWitnessRadius": JOINT_RADIUS,
		"rootedRearWitnessCount": measured.filter(func(row): return row.rootedWallRearContact.get("found", false)).size(),
		"hoodFrontWitnessCount": measured.filter(func(row): return row.hoodFrontContact.get("found", false)).size(),
		"exactShortBeamProfileAndAppearanceCount": measured.filter(func(row): return row.shortBeamProfileAndAppearanceExact).size(),
		"materialContext": "Candidate and original publish every inspected context part in identical order. Original-only-bracket versus candidate-context order is not a valid material cache comparison.",
		"rows": measured, "counts": _counts, "work": _work, "elapsedMsec": Time.get_ticks_msec() - _started_msec,
		"limitations": "No GPU readback/drawing, visual acceptance, full furniture/neighbour/swept-door clearance or production integration. Witnesses prove only bounded interior contact in represented CPU box primitives, not structural engineering. Missing sampled witness is not universal separation. Closed-door intersections are observations, not automatically permitted joints. Source-validator success never substitutes for rear mounting proof."}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		quit(2)
		return
	file.store_string(JSON.stringify(_overlap_json(report), "  "))
	file.flush()
	var written := file.get_error() == OK
	file.close()
	quit(0 if complete and written else 2)

func _door_visual(publisher, b, part) -> Dictionary:
	if not _door_payloads.has(part.id):
		_door_old_payloads[part.id] = _extract_overlap_payload(_door_old_publisher, _door_old_blueprint, _door_old_blueprint.find_part(part.id), "matched_original_context")
		_door_payloads[part.id] = _extract_overlap_payload(publisher, b, part, "bracket_context")
	return _door_payloads[part.id]

func _door_witness(bracket: Dictionary, counterparts: Array, end: String) -> Dictionary:
	if not _valid_payload(bracket) or bracket.primitives.size() != 1 or bracket.primitives[0].type != "box": return {"found": false, "reason": "invalid_or_nonbox_bracket"}
	var transforms: Array = []
	var identities: Array = []
	for payload in counterparts:
		if not _valid_payload(payload): return {"found": false, "reason": "invalid_counterpart"}
		for primitive in payload.primitives:
			if primitive.type != "box": return {"found": false, "reason": "nonbox_counterpart_requires_exact_mesh_proof"}
			transforms.append(primitive.transform)
			identities.append(primitive.id)
	if transforms.is_empty(): return {"found": false, "reason": "no_rooted_counterpart"}
	var result: Dictionary = ContactWitness.find_contact(bracket.primitives[0].transform, transforms, end, JOINT_RADIUS)
	if result.get("found", false): result["peerPrimitiveId"] = identities[result.peerIndex]
	return result

func _door_contacts(bracket: Dictionary, door: Dictionary) -> Array:
	var contacts: Array = []
	for first in bracket.primitives:
		for second in door.primitives:
			if first.type != "box" or second.type != "box": continue
			var gap := _separation(first.transform, second.transform)
			if gap <= 0.0: contacts.append({"primitiveId": second.id, "signedSatGap": gap})
	return contacts

func _door_bindings(payload: Dictionary, part) -> Array:
	# Bind actual emitted boxes to the production door descriptor by transforms,
	# not material-group order. Arithmetic matching is not a clearance margin.
	var expected: Array = DoorGeometry.closed_primitives(part.size, Transform3D(Basis.from_euler(part.rotation), part.position))
	var result: Array = []
	for primitive in payload.primitives:
		var matches: Array = []
		for piece in expected:
			var pose: Transform3D = piece.transform * Transform3D(Basis.from_scale(piece.size), Vector3.ZERO)
			if primitive.type == "box" and primitive.transform.is_equal_approx(pose): matches.append(piece.name)
		result.append({"primitiveId": primitive.id, "matchingProductionPieces": matches})
	return result
