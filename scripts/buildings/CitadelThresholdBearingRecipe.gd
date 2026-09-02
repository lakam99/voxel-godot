extends RefCounted

## Private source proposal consumed by structural completion. Ownership
## comes from the street-house recipe. Existing geometry is never repositioned.
## A masonry plinth supports an otherwise unanchored threshold; every
## proposed box must clear source geometry, ordinary doors and reserved space.
const Copy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Door = preload("res://scripts/buildings/BuildingDoorGeometry.gd")
const Admission = preload("res://scripts/buildings/ConstructionBoxAdmission.gd")
const Layout = preload("res://scripts/buildings/InteriorFurnishingLayout.gd")
const Connection = preload("res://scripts/buildings/OpeningHeadConnectionRecipe.gd")
const Fitter = preload("res://scripts/buildings/ThresholdBearingFootprintFitter.gd")
const Planes = preload("res://scripts/buildings/ThresholdBearingConstructionPlanes.gd")
const Boxes = preload("res://scripts/buildings/ReplacementBoxOccupancy.gd")
const Frame = preload("res://scripts/buildings/FacadeBearingFrameBuilder.gd")
const Seats = preload("res://scripts/buildings/ThresholdBearingSeatRecipe.gd")
const Housing = preload("res://scripts/buildings/ThresholdBearingHousingRecipe.gd")
# Use the same whole-blueprint bound as the validation grid and checkpoint.
# A smaller helper-local ceiling rejects valid ordinary Citadel recipes.
const MAX_PARTS := Frame.MAX_PARTS
const MAX_VOLUMES := 4096

static func prepare(snapshot: Dictionary, ownership: Dictionary, furniture: Array = []) -> Dictionary:
	return _prepare(snapshot, ownership, furniture, {})

## Completion-owner entry point. The failed check is accepted only when its
## proof source, current source and unchanged target record are byte-bound.
## This method performs no global physical validation.
static func _prepare_bound(snapshot: Dictionary, ownership: Dictionary, furniture: Array, binding: Dictionary) -> Dictionary:
	var bound := _validate_bound_check(snapshot, ownership, binding)
	if not bound.ready: return bound
	return _prepare(snapshot, ownership, furniture, bound.check, bound.seats)

static func _validate_bound_check(snapshot: Dictionary, ownership: Dictionary, binding: Dictionary) -> Dictionary:
	var declared: Variant = ownership.get("threshold")
	if not declared is Dictionary or not declared.get("id") is String:
		return _fail("invalid_bound_threshold_ownership")
	var threshold_id: String = declared.id
	var check: Variant = binding.get("check")
	var proof_bytes: Variant = binding.get("proofSourceBytes")
	var current_bytes: Variant = binding.get("currentSourceBytes")
	if not check is Dictionary or not proof_bytes is PackedByteArray or not current_bytes is PackedByteArray \
			or binding.get("partId") != threshold_id or check.get("partId") != threshold_id \
			or check.get("passed") != false:
		return _fail("invalid_bound_threshold_check")
	if not binding.get("proofChecks") is Dictionary or binding.proofChecks.is_empty() \
			or not binding.get("permittedThresholdEdits", {}) is Dictionary \
			or proof_bytes.size() > 64 * 1024 * 1024 or not _snapshot_valid(snapshot):
		return _fail("invalid_threshold_proof_envelope")
	if current_bytes != var_to_bytes(snapshot):
		return _fail("stale_bound_threshold_source")
	var proof_snapshot: Variant = bytes_to_var(proof_bytes)
	if not proof_snapshot is Dictionary or not _snapshot_valid(proof_snapshot):
		return _fail("invalid_bound_threshold_proof_source")
	var proof_part := _snapshot_part(proof_snapshot, threshold_id)
	var current_part := _snapshot_part(snapshot, threshold_id)
	if proof_part.is_empty() or current_part.is_empty() or var_to_bytes(proof_part) != var_to_bytes(current_part):
		return _fail("stale_bound_threshold_target")
	var seats := _proof_seats(snapshot, proof_snapshot, binding.get("proofChecks", {}), binding.get("permittedThresholdEdits", {}))
	if not seats.ready: return seats
	var proof_checks: Dictionary = binding.get("proofChecks", {})
	if var_to_bytes(proof_checks.get(threshold_id)) != var_to_bytes(check):
		return _fail("mismatched_bound_threshold_check")
	return {"ready": true, "check": check.duplicate(true), "seats": seats.records}

## Reuse the owner's ordinary proof only while its entire collision substrate
## is unchanged. Earlier thresholds may add admitted supports and adjust their
## noncollision finish; neither can substitute a changed original support.
## This is evidence binding, not a second support classifier or graph search.
static func _proof_seats(current: Dictionary, original: Dictionary, checks: Dictionary, permitted_edits: Dictionary = {}) -> Dictionary:
	if checks.is_empty() or not _snapshot_valid(current) or not _snapshot_valid(original):
		return _fail("invalid_threshold_seat_proof")
	for key in ["id", "seed", "style", "recipe", "rooms"]:
		if var_to_bytes(current.get(key)) != var_to_bytes(original.get(key)):
			return _fail("stale_threshold_seat_proof_context")
	var current_records: Dictionary = {}
	for row: Dictionary in current.get("parts", []):
		if current_records.has(row.id): return _fail("duplicate_threshold_seat_source")
		current_records[row.id] = row
	var originals: Array = original.get("parts", [])
	if originals.size() > MAX_PARTS or checks.size() != originals.size():
		return _fail("incomplete_threshold_seat_proof")
	var records: Dictionary = {}
	var seen: Dictionary = {}
	for row: Dictionary in originals:
		var id: String = row.id
		if seen.has(id) or not checks.has(id) or not current_records.has(id):
			return _fail("incomplete_threshold_seat_proof")
		seen[id] = true
		var value: Variant = checks[id]
		if not value is Dictionary: return _fail("invalid_threshold_seat_check")
		var check: Dictionary = value
		if not check.get("partId") is String or check.partId != id or not check.get("passed") is bool or not check.get("intent") is String \
				or not check.get("collisionEnabled") is bool or check.collisionEnabled != row.get("collision", true):
			return _fail("mismatched_threshold_seat_proof")
		var bytes := var_to_bytes(row)
		var current_bytes := var_to_bytes(current_records[id])
		if bytes != current_bytes:
			if row.get("collision", true):
				return _fail("stale_threshold_seat_substrate", {"partId": id})
			if not permitted_edits.has(id) or permitted_edits[id] != current_bytes \
					or check.get("passed") != false or check.get("intent") != "facade_attachment" \
					or row.get("semantic") != "citadel_threshold_wear":
				return _fail("unapproved_threshold_seat_source_edit", {"partId": id})
			var expected: Dictionary = row.duplicate(true)
			var changed_size: Vector3 = current_records[id].size
			if not changed_size.is_finite() or changed_size.y <= 0.0 or changed_size.x != row.size.x or changed_size.z != row.size.z:
				return _fail("invalid_prior_threshold_finish_edit")
			expected.size = changed_size
			expected.recipe["physicalRequiredAnchorPartIds"] = [id + "_bearing"]
			if var_to_bytes(expected) != current_bytes: return _fail("invalid_prior_threshold_finish_edit")
		if not row.get("collision", true): continue
		if row.get("kind") == "foundation" and check.get("passed") == true \
				and check.get("intent") in ["structural_mass", "structural_root"] \
				and (check.get("reachesGroundRoot") == true if check.intent == "structural_mass" else check.get("physicalRoot") == true):
			records[id] = bytes
	return {"ready": true, "records": records}

static func _snapshot_part(snapshot: Dictionary, id: String) -> Dictionary:
	for row: Variant in snapshot.get("parts", []):
		if row is Dictionary and row.get("id") == id: return row
	return {}

static func _prepare(snapshot: Dictionary, ownership: Dictionary, furniture: Array, bound_check: Dictionary, proven_seats: Dictionary = {}) -> Dictionary:
	if not _snapshot_valid(snapshot):
		var raw_parts: Variant = snapshot.get("parts")
		var raw_rooms: Variant = snapshot.get("rooms")
		return _fail("invalid_threshold_source", {"partCount": raw_parts.size() if raw_parts is Array else -1,
			"roomCount": raw_rooms.size() if raw_rooms is Array else -1, "maxParts": MAX_PARTS, "maxRooms": MAX_VOLUMES})
	if furniture.size() > MAX_VOLUMES:
		return _fail("threshold_protected_volume_limit", {"volumeCount": furniture.size(), "maxVolumes": MAX_VOLUMES})
	var source = Copy.copy_blueprint(snapshot)
	var by_id: Dictionary = {}
	for part in source.parts:
		if part.id.is_empty() or by_id.has(part.id) or not source.has_finite_positive_bounds(part):
			return _fail("invalid_threshold_source_part")
		by_id[part.id] = part
	var prefix: Variant = ownership.get("producerPrefix")
	var declared: Variant = ownership.get("threshold")
	if not prefix is String or prefix.is_empty() or prefix != prefix.strip_edges() or not declared is Dictionary:
		return _fail("invalid_threshold_ownership")
	if ownership.get("roomId") != prefix + "_interior" or ownership.get("doorId") != prefix + "_door" \
		or declared.get("id") != prefix + "_door_threshold" or declared.get("foundationId") != prefix + "_foundation":
		return _fail("invalid_threshold_ownership")
	for id: String in [ownership.doorId, declared.id, declared.foundationId]:
		if not by_id.has(id): return _fail("missing_threshold_owner", {"partId": id})
	var threshold = by_id[declared.id]
	var foundation = by_id[declared.foundationId]
	var door = by_id[ownership.doorId]
	if threshold.kind != "foundation" or threshold.semantic != "citadel_threshold_wear" or threshold.collision_enabled \
		or foundation.kind != "foundation" or foundation.semantic != "citadel_urban_house_foundation" \
		or door.kind != "door" or door.semantic != "citadel_urban_door" or door.recipe.get("roomId") != ownership.roomId:
		return _fail("incompatible_threshold_ownership")
	var rooms: Array = source.rooms.filter(func(room): return room.get("id") == ownership.roomId and room.get("citadelUrbanRoom") == true)
	if rooms.size() != 1: return _fail("missing_threshold_room")
	for part in [threshold, foundation, door]:
		if part.rotation != Vector3.ZERO: return _fail("unsupported_threshold_rotation")
	if not source.is_grounded_structural_root(foundation): return _fail("ungrounded_threshold_foundation")
	var obstacles := _protected(source, furniture)
	if not obstacles.ready: return obstacles
	var before: Dictionary = {"ready": true, "checks": {threshold.id: bound_check}}
	if bound_check.is_empty(): before = _physical(source)
	if not before.ready or not before.checks.has(threshold.id): return _fail("missing_threshold_physical_check")
	var current: Dictionary = before.checks[threshold.id]
	if bound_check.is_empty():
		var seats := _proof_seats(snapshot, snapshot, before.checks)
		if not seats.ready: return seats
		proven_seats = seats.records
	if current.get("passed") == true:
		return {"ready": true, "changed": false, "afterSnapshot": snapshot.duplicate(true)}
	if current.get("intent") != "facade_attachment" or current.get("reachesGroundRoot", false):
		return _fail("ineligible_threshold_failure")
	# Existing mandatory obligations may not be replaced to manufacture success.
	for key in ["physicalRequiredAnchorPartIds", "physicalRequiredAnchorFacts", "physicalRequiredSeatPartIds", "physicalRequiredSupportPartIds"]:
		if threshold.recipe.has(key) and threshold.recipe[key] != []: return _fail("threshold_has_existing_obligations")
	var bottom: float = foundation.position.y - foundation.size.y * 0.5
	var top: float = threshold.position.y - threshold.size.y * 0.5
	var foundation_top: float = foundation.position.y + foundation.size.y * 0.5
	if absf(top - foundation_top) > 0.00001 or top - bottom < 0.02:
		return _fail("inconsistent_threshold_elevation")
	var bearing_id: String = threshold.id + "_bearing"
	if by_id.has(bearing_id): return _fail("threshold_bearing_already_present")
	var normalization := Planes.normalize(threshold, foundation)
	if not normalization.ready: return _fail(normalization.reason, {"normalization": normalization})
	var changed_faces := _admit_changed_faces(source, threshold.id, normalization.addedVolumes, obstacles.volumes)
	if not changed_faces.ready: return changed_faces
	threshold.size = normalization.record.size
	var domain := [float(threshold.position.x) - float(threshold.size.x) * 0.5, bottom,
		float(threshold.position.z) - float(threshold.size.z) * 0.5,
		float(threshold.position.x) + float(threshold.size.x) * 0.5, foundation_top,
		float(threshold.position.z) + float(threshold.size.z) * 0.5]
	var full := _candidate(source, threshold, foundation, bearing_id, domain, obstacles.volumes, proven_seats)
	var selected: Dictionary = full
	var attempts: Array = []
	if not full.ready:
		attempts.append(_without_bearing(full))
		if not Boxes.valid(full.get("assemblyBounds")): return _without_bearing(full)
		var fit := _fit_obstacles(source, domain, obstacles.volumes, full)
		if not fit.ready: return _fail(fit.reason, {"fullFootprintRejection": _without_bearing(full)})
		if fit.candidates.size() + 1 > Fitter.MAX_CANDIDATES:
			return _fail("threshold_fit_candidate_limit")
		for bounds: Array in fit.candidates:
			if bounds[0] == domain[0] and bounds[2] == domain[2] and bounds[3] == domain[3] and bounds[5] == domain[5]: continue
			selected = _candidate(source, threshold, foundation, bearing_id, bounds, obstacles.volumes, proven_seats, full)
			attempts.append(_without_bearing(selected))
			if selected.ready: break
		if not selected.ready:
			var rejected := _without_bearing(full)
			rejected["fitAttempts"] = attempts
			rejected["noFeasibleFit"] = true
			return rejected
	var after: Dictionary = snapshot.duplicate(true)
	for course in selected.bearings: after.parts.append(course.snapshot())
	for record: Dictionary in after.parts:
		if record.id == threshold.id:
			record.size = threshold.size
			record.recipe["physicalRequiredAnchorPartIds"] = [bearing_id]
	var prepared := {"ready": true, "changed": true, "afterSnapshot": after, "bearingId": bearing_id,
		"courseIds": selected.courseIds,
		"contact": selected.contact, "normalization": normalization,
		"fullFootprintRejection": {} if full.ready else _without_bearing(full), "fitAttempts": attempts,
		"scope": "Source structural and conservative box clearance only; no published visual, navigation or gameplay acceptance."}
	if not bound_check.is_empty():
		prepared["globalPhysicalValidations"] = 0
		return prepared
	var verified = Copy.copy_blueprint(after)
	var result := _physical(verified)
	if not result.ready: return result
	if result.checks[bearing_id].get("passed") != true or result.checks[threshold.id].get("passed") != true:
		return _fail("threshold_bearing_proof_failed", {"threshold": result.checks[threshold.id], "bearing": result.checks[bearing_id]})
	for course_id: String in selected.courseIds:
		if not result.checks.has(course_id) or result.checks[course_id].get("passed") != true:
			return _fail("threshold_course_proof_failed", {"partId": course_id, "check": result.checks.get(course_id, {})})
	for id: String in before.checks:
		if before.checks[id].get("passed") == true and result.checks[id].get("passed") != true:
			return _fail("threshold_bearing_regresses_source", {"partId": id})
	prepared["thresholdCheck"] = result.checks[threshold.id]
	prepared["bearingCheck"] = result.checks[bearing_id]
	prepared["courseChecks"] = selected.courseIds.map(func(course_id): return result.checks[course_id])
	prepared["globalPhysicalValidations"] = 2
	return prepared

## Fit against the geometry actually occupying the proposed support's height,
## including furniture and decorative source parts. The selected structural
## seat is omitted only from this search domain: _candidate still proves its
## declared contact and admits every other intersection without exemptions.
static func _fit_obstacles(source, domain: Array, volumes: Array, failed: Dictionary) -> Dictionary:
	var assembly: Variant = failed.get("assemblyBounds")
	if not Boxes.valid(assembly):
		return _fail("threshold_fit_requires_verified_assembly")
	var search := domain.duplicate()
	search[1] = assembly[1]
	search[4] = assembly[4]
	var cuts: Array = []
	for part in source.parts:
		if part.id == failed.get("selectedSeatId", ""): continue
		var bounds := _scalar_envelope(Transform3D(Basis.from_euler(part.rotation) * Basis.from_scale(part.size), part.position))
		if not Boxes.valid(bounds): return _fail("invalid_threshold_fit_source")
		if not Boxes.intersection(search, bounds).is_empty(): cuts.append(bounds)
		if cuts.size() > Fitter.MAX_BOUNDS: return _fail("threshold_fit_obstacle_limit")
	for row: Dictionary in volumes:
		var box: AABB = row.bounds
		var bounds := _scalar_envelope(Transform3D(Basis.from_scale(box.size), box.get_center()))
		if not Boxes.valid(bounds): return _fail("invalid_threshold_fit_reservation")
		if not Boxes.intersection(search, bounds).is_empty(): cuts.append(bounds)
		if cuts.size() > Fitter.MAX_BOUNDS: return _fail("threshold_fit_obstacle_limit")
	return Fitter.derive_scalar(search, cuts)

static func _candidate(source, threshold, foundation, id: String, domain: Array, volumes: Array, proven_seats: Dictionary = {}, fitting_basis: Dictionary = {}) -> Dictionary:
	var fitted := Connection._inside_box(domain)
	if fitted.is_empty(): return _fail("unrepresentable_threshold_bearing")
	# Fit XZ only. Y copies the actual foundation's stored pair, so its ground
	# and top planes are shared exactly rather than reconstructed from endpoints.
	var center: Vector3 = fitted.position
	var size: Vector3 = fitted.size
	center.y = foundation.position.y
	size.y = foundation.size.y
	var seat := Seats.prepare(source, threshold, center, size, 2, proven_seats)
	if not seat.ready: return seat
	var descriptions: Array = seat.get("courses", [])
	if descriptions.is_empty():
		var description := {"id": id, "position": center, "size": size}
		if seat.seated:
			description.merge({"position": seat.position, "size": seat.size, "seatId": seat.seatId, "seatFact": seat.seatFact}, true)
		descriptions = [description]
	if descriptions.size() > 2 or source.parts.size() + descriptions.size() > MAX_PARTS:
		return _fail("threshold_course_part_limit")
	var course_ids: Array = descriptions.map(func(row): return row.id)
	if course_ids != ([id] if descriptions.size() == 1 else [id + "_base", id]):
		return _fail("invalid_threshold_course_ids")
	for part in source.parts:
		if course_ids.has(part.id): return _fail("threshold_course_id_collision", {"partId": part.id})
	var bearings: Array = []
	var course_bounds: Array = []
	for description: Dictionary in descriptions:
		var bearing_recipe := {"variation": foundation.recipe.get("variation", 0.0), "physicalIntent": "structural_mass"}
		if description.has("seatFact"):
			bearing_recipe["physicalRequiredSeatPartIds"] = [description.seatId]
			bearing_recipe["physicalRequiredSeatFacts"] = [description.seatFact]
		var part := Part.new({"id": description.id, "kind": "foundation", "material": foundation.material_id,
			"position": description.position, "size": description.size, "collision": true,
			"semantic": "citadel_threshold_bearing", "physicalIntent": "structural_mass", "recipe": bearing_recipe})
		if part.position != description.position or part.size != description.size:
			return _fail("threshold_course_constructor_changed_bounds", {"partId": description.id})
		var bounds := Fitter._bounds(part)
		if description.has("bottom") and (bounds[1] != description.bottom or bounds[4] != description.top):
			return _fail("threshold_course_endpoint_mismatch", {"partId": description.id, "bounds": bounds})
		if not bearings.is_empty():
			var previous: Array = course_bounds.back()
			if previous[4] != bounds[1] or previous[0] != bounds[0] or previous[3] != bounds[3] or previous[2] != bounds[2] or previous[5] != bounds[5]:
				return _fail("threshold_course_partition_mismatch")
			var previous_part = bearings.back()
			var pair := Admission.measure(Transform3D(Basis.from_scale(previous_part.size), previous_part.position), Transform3D(Basis.from_scale(part.size), part.position))
			if not pair.valid or not pair.clear: return _fail("threshold_course_mutual_overlap", {"measurement": pair})
		bearings.append(part)
		course_bounds.append(bounds)
	# Search bounds exist only after every actual Part and internal joint is
	# verified. A first-course obstruction cannot hide an invalid later course.
	var assembly_bounds: Array = course_bounds[0].duplicate()
	assembly_bounds[4] = course_bounds[-1][4]
	if not Boxes.valid(assembly_bounds): return _fail("invalid_threshold_assembly_bounds")
	var bearing = bearings.back()
	var contact := Fitter.measure_contact(bearing, threshold, 0.0)
	if not contact.ready or not contact.exactTopContact:
		return _fail("threshold_exact_contact_failed", {"contact": contact})
	if not fitting_basis.is_empty():
		var expected: Variant = fitting_basis.get("assemblyBounds")
		if not Boxes.valid(expected) or not fitting_basis.get("selectedSeatId") is String \
				or seat.get("seatId", "") != fitting_basis.selectedSeatId \
				or assembly_bounds[1] != expected[1] or assembly_bounds[4] != expected[4]:
			return _fail("threshold_fit_changed_seat_or_band")
	for index in range(bearings.size()):
		var part = bearings[index]
		var admitted := _admit(source, part, volumes, seat if seat.get("contactMode") == "housed_overlap" else {}, proven_seats)
		if not admitted.ready:
			admitted["seated"] = seat.seated
			admitted["selectedSeatId"] = seat.get("seatId", "")
			admitted["courseId"] = part.id
			admitted["courseBounds"] = course_bounds[index]
			admitted["assemblyBounds"] = assembly_bounds
			return admitted
	if seat.seated:
		contact["seatId"] = seat.seatId
		contact["seatPlane"] = seat.seatPlane
		if proven_seats.has(seat.seatId):
			var identity := HashingContext.new()
			if identity.start(HashingContext.HASH_SHA256) != OK or identity.update(proven_seats[seat.seatId]) != OK:
				return _fail("threshold_seat_identity_failed")
			var digest := identity.finish().hex_encode()
			if digest.length() != 64: return _fail("threshold_seat_identity_failed")
			contact["seatSourceSha256"] = digest
			contact["seatProof"] = "unchanged source record from owner's initial physical validation"
		contact["seatGap"] = course_bounds[0][1] - seat.seatPlane
		contact["exactSeatContact"] = contact.seatGap == 0.0
		contact["contactMode"] = seat.get("contactMode", "butt_seat")
		# Elevated contact is not ground contact, and must not be reported as it.
		if seat.get("contactMode") == "housed_overlap":
			contact["actualEmbedment"] = -contact.seatGap
			contact["housing"] = seat.duplicate(true)
		elif not contact.exactSeatContact:
			return _fail("threshold_exact_seat_contact_failed", {"contact": contact})
		if bearings.any(func(part): return source.is_grounded_structural_root(part)):
			return _fail("threshold_exact_seat_contact_failed", {"contact": contact})
	elif not contact.meetsGroundPlane or not source.is_grounded_structural_root(bearing):
		return _fail("threshold_exact_contact_failed", {"contact": contact})
	if bearings.size() == 2:
		contact["courseBounds"] = course_bounds
		contact["sharedPlane"] = course_bounds[0][4]
		contact["splitTrials"] = seat.splitTrials
	return {"ready": true, "bearing": bearing, "bearings": bearings, "courseIds": course_ids, "contact": contact}

static func _without_bearing(result: Dictionary) -> Dictionary:
	var copy := result.duplicate(true)
	copy.erase("bearing")
	copy.erase("bearings")
	return copy

static func _admit_changed_faces(source, threshold_id: String, additions: Array, volumes: Array) -> Dictionary:
	# Sub-micrometre positive-volume additions are not sent through a minimum-
	# thickness box constructor. Conservative scalar broad bounds cannot miss
	# an intersection: ambiguous rotated-source intersections reject as well.
	for addition: Array in additions:
		if not Boxes.valid(addition): return _fail("invalid_threshold_normalization_volume")
		for part in source.parts:
			if part.id == threshold_id: continue
			var pose := Transform3D(Basis.from_euler(part.rotation) * Basis.from_scale(part.size), part.position)
			var envelope := _scalar_envelope(pose)
			if not Boxes.valid(envelope): return _fail("unsupported_threshold_normalization_source_bounds", {"partId": part.id})
			if not Boxes.intersection(addition, envelope).is_empty():
				return _fail("threshold_normalization_source_overlap", {"partId": part.id, "addedVolume": addition})
		for row: Dictionary in volumes:
			var bounds: AABB = row.bounds
			var pose := Transform3D(Basis.from_scale(bounds.size), bounds.get_center())
			var envelope := _scalar_envelope(pose)
			if not Boxes.valid(envelope): return _fail("unsupported_threshold_normalization_reserved_bounds", {"partId": row.id})
			if not Boxes.intersection(addition, envelope).is_empty():
				return _fail("threshold_normalization_reserved_overlap", {"partId": row.id, "addedVolume": addition})
	return {"ready": true}

static func _scalar_envelope(pose: Transform3D) -> Array:
	var low: Array = []
	var high: Array = []
	for axis in range(3):
		var radius := 0.0
		for column in range(3): radius += absf(float(pose.basis[column][axis])) * 0.5
		low.append(float(pose.origin[axis]) - radius)
		high.append(float(pose.origin[axis]) + radius)
	return low + high

static func _physical(source) -> Dictionary:
	var proof = Copy.copy_blueprint(source.snapshot())
	Copy.clear_caches(proof)
	var work := Copy.validation_grid_work(proof)
	if not work.ready: return _fail("threshold_validation_work_rejected", {"detail": work})
	var report: Dictionary = proof.validate_physical_integrity()
	var checks: Dictionary = {}
	for row: Dictionary in report.checks:
		if checks.has(row.partId): return _fail("duplicate_threshold_physical_check")
		checks[row.partId] = row
	if checks.size() != source.parts.size(): return _fail("incomplete_threshold_physical_check")
	return {"ready": true, "checks": checks}

static func _protected(source, furniture: Array) -> Dictionary:
	var volumes: Array = []
	for row: Variant in furniture:
		if not row is Dictionary or not row.get("id") is String or not row.get("bounds") is AABB or not _valid_box(row.bounds):
			return _fail("invalid_threshold_furniture")
		volumes.append({"id": row.id, "bounds": row.bounds})
	for room: Dictionary in source.rooms:
		if not room.get("bounds") is AABB or not _valid_box(room.bounds) or not room.get("accesses", []) is Array:
			return _fail("invalid_threshold_reservation")
		if room.get("role", "") != "courtyard": volumes.append({"id": "room:" + str(room.get("id", "")), "bounds": room.bounds})
		if volumes.size() > MAX_VOLUMES: return _fail("threshold_reservation_limit")
		for access: Variant in room.get("accesses", []):
			if not access is Dictionary or not access.get("position") is Vector3 or not access.get("size") is Vector3:
				return _fail("invalid_threshold_access")
			var bounds := Layout.access_reservation(access)
			if not _valid_box(bounds): return _fail("invalid_threshold_access")
			volumes.append({"id": "access:" + str(access.get("id", "")), "bounds": bounds})
			if volumes.size() > MAX_VOLUMES: return _fail("threshold_reservation_limit")
	for part in source.parts:
		if part.kind != "door": continue
		# Select the geometry path using the publisher's actual recipe selector.
		if part.recipe.get("doorPresentation", "") == "portcullis":
			var raised := Door.portcullis_sweep_bounds(part.size, Transform3D(Basis.from_euler(part.rotation), part.position))
			if raised.is_empty(): return _fail("invalid_threshold_door_sweep")
			for index in range(raised.size()):
				if not _valid_box(raised[index]): return _fail("invalid_threshold_door_sweep")
				volumes.append({"id": "door:" + part.id + ":%d" % index, "bounds": raised[index]})
				if volumes.size() > MAX_VOLUMES: return _fail("threshold_reservation_limit")
			continue
		var swing: Variant = part.recipe.get("openSwing", Door.DEFAULT_OPEN_SWING)
		if not (swing is float or swing is int) or not is_finite(float(swing)) or absf(float(swing)) > PI:
			return _fail("invalid_threshold_door_swing")
		var sweep := Door.ordinary_sweep_bounds(part.size, Transform3D(Basis.from_euler(part.rotation), part.position), float(swing))
		if sweep.is_empty(): return _fail("invalid_threshold_door_sweep")
		# Report stationary frame interference before a conservative moving-leaf
		# envelope. This only orders rejection evidence; every bound is retained.
		sweep.sort_custom(func(a, b): return not a.moving if a.moving != b.moving else a.name < b.name)
		for piece: Dictionary in sweep:
			volumes.append({"id": "door:" + part.id + ":" + piece.name, "bounds": piece.bounds})
			if volumes.size() > MAX_VOLUMES: return _fail("threshold_reservation_limit")
	return {"ready": true, "volumes": volumes}

static func _admit(source, bearing, volumes: Array, housing: Dictionary = {}, proven_seats: Dictionary = {}) -> Dictionary:
	var pose := Transform3D(Basis.from_scale(bearing.size), bearing.position)
	for row: Dictionary in volumes:
		var bounds: AABB = row.bounds
		var measured := Admission.measure(pose, Transform3D(Basis.from_scale(bounds.size), bounds.get_center()))
		if not measured.valid or not measured.clear:
			return _fail("threshold_bearing_reserved_overlap", {"partId": row.id, "measurement": measured})
	for part in source.parts:
		var other := Transform3D(Basis.from_euler(part.rotation) * Basis.from_scale(part.size), part.position)
		var measured := Admission.measure(pose, other)
		if not measured.valid or not measured.clear:
			if measured.valid and housing.get("contactMode") == "housed_overlap" and housing.get("seatId") == part.id \
					and proven_seats.has(part.id) and proven_seats[part.id] == var_to_bytes(part.snapshot()):
				var top: float = float(bearing.position.y) + float(bearing.size.y) * 0.5
				var expected := Housing.prepare(part, top, bearing.position, bearing.size)
				var facts: Array = bearing.recipe.get("physicalRequiredSeatFacts", [])
				if expected.ready and expected.position == bearing.position and expected.size == bearing.size \
						and facts == [expected.seatFact] and bearing.recipe.get("physicalRequiredSeatPartIds") == [part.id] \
						and Housing.validate(bearing, part, expected.seatFact).get("ready") == true:
					continue
			return _fail("threshold_bearing_source_overlap", {"partId": part.id, "measurement": measured})
	return {"ready": true}

static func _snapshot_valid(value: Dictionary) -> bool:
	if not value.get("id") is String or not value.get("seed") is int or not value.get("style") is String \
		or not value.get("recipe") is Dictionary or not value.get("parts") is Array or not value.get("rooms") is Array:
		return false
	if value.parts.is_empty() or value.parts.size() > MAX_PARTS or value.rooms.size() > MAX_VOLUMES: return false
	for room: Variant in value.rooms:
		if not room is Dictionary: return false
	for record: Variant in value.parts:
		if not record is Dictionary or not record.get("id") is String or not record.get("recipe") is Dictionary \
			or not record.get("physicalIntent") is String or not record.get("position") is Vector3 \
			or not record.get("rotation") is Vector3 or not record.get("size") is Vector3:
			return false
		if not record.position.is_finite() or not record.rotation.is_finite() or not record.size.is_finite() \
			or record.size.x <= 0.0 or record.size.y <= 0.0 or record.size.z <= 0.0: return false
	return true

static func _valid_box(box: AABB) -> bool:
	return box.position.is_finite() and box.size.is_finite() and box.end.is_finite() and box.size.x > 0.0 and box.size.y > 0.0 and box.size.z > 0.0

static func _fail(reason: String, detail: Dictionary = {}) -> Dictionary:
	var result := detail.duplicate(true)
	result["ready"] = false
	result["changed"] = false
	result["reason"] = reason
	return result
