extends RefCounted

## Source-only, immutable seat proposal. Deliberately restricted to directly
## grounded foundations or unchanged foundations from the owner's ordinary
## physical proof. No inferred neighbour graph or physicalRoot cache is authority
## here. Main constructs the final Part and admits it against ALL
## source/reserved geometry, including the selected seat. No seat exemption.
const Seats = preload("res://scripts/buildings/GabledRoofFrameBuilder.gd")
const Splitter = preload("res://scripts/buildings/ThresholdBearingCourseSplitter.gd")
const Housing = preload("res://scripts/buildings/ThresholdBearingHousingRecipe.gd")
const MAX_SOURCE_PARTS := 10000
const PATCH_INSET := 0.05


static func prepare(source, threshold, center: Vector3, size: Vector3, max_courses: int = 1, proven_seats: Dictionary = {}) -> Dictionary:
	if source == null or threshold == null or source.parts.size() > MAX_SOURCE_PARTS \
			or not _finite_box(center, size) or not _finite_part(threshold) \
			or threshold.rotation != Vector3.ZERO or String(threshold.id).is_empty() or max_courses not in [1, 2]:
		return _fail("invalid_threshold_seat_input")
	var threshold_bottom: float = float(threshold.position.y) - float(threshold.size.y) * 0.5
	var selected: Dictionary = {}
	var selected_part = null
	var seen: Dictionary = {}
	var bearing_id: String = String(threshold.id) + "_bearing"
	for part in source.parts:
		if part == null: continue
		var id := String(part.id)
		if id.is_empty() or seen.has(id): return _fail("invalid_threshold_seat_source_identity")
		seen[id] = true
		if proven_seats.has(id) and (not proven_seats[id] is PackedByteArray or proven_seats[id] != var_to_bytes(part.snapshot())):
			return _fail("stale_threshold_seat_proof", {"seatId": id})
		if part == threshold or id == String(threshold.id) or id == bearing_id: continue
		# Unclassified construction records use the same read-only taxonomy as
		# ordinary physical validation. An explicit role is never overridden.
		var effective_intent: String = String(part.physical_intent)
		if effective_intent.is_empty(): effective_intent = source.inferred_physical_intent(part)
		if not _finite_part(part) or part.rotation != Vector3.ZERO or not part.collision_enabled \
				or part.kind != "foundation" or effective_intent not in ["structural_mass", "structural_root"]:
			continue
		if not _full_box_source(part): continue
		# The existing geometric predicate permits 6 cm. This recipe additionally
		# requires the exact scalar ground plane, independent of metadata/caches.
		var bottom: float = float(part.position.y) - float(part.size.y) * 0.5
		var top: float = float(part.position.y) + float(part.size.y) * 0.5
		var grounded: bool = bottom == 0.0 and source.is_grounded_structural_root(part)
		var proven: bool = proven_seats.has(id) and proven_seats[id] is PackedByteArray and proven_seats[id] == var_to_bytes(part.snapshot())
		if not (grounded or proven) or top >= threshold_bottom:
			continue
		var patch := _inset_patch(center, size, part)
		if patch.is_empty(): continue
		# Select before attempting ANY Y representation. Never choose a lower
		# root just because the highest root's endpoints are awkward float32s.
		if selected.is_empty() or top > float(selected.top) or top == float(selected.top) and id < String(selected.id):
			selected = {"id": id, "top": top, "patch": patch}
			selected_part = part
	for id: Variant in proven_seats:
		if not id is String or not seen.has(id): return _fail("missing_threshold_proven_seat")
	if selected.is_empty(): return {"ready": true, "seated": false}
	var seat_plane: float = selected.top
	var position := Vector3(center.x, (seat_plane + threshold_bottom) * 0.5, center.z)
	var seated_size := Vector3(size.x, threshold_bottom - seat_plane, size.z)
	var represented_bottom: float = float(position.y) - float(seated_size.y) * 0.5
	var represented_top: float = float(position.y) + float(seated_size.y) * 0.5
	if not _finite_box(position, seated_size) or represented_bottom != seat_plane or represented_top != threshold_bottom:
		if max_courses == 2:
			var subdivided := _subdivide(selected, threshold_bottom, center, size, bearing_id)
			# A purposeful housed footing is allowed only for a proof-authorized
			# elevated support when exact partitioning is unrepresentable. Never
			# retry another construction after collision admission has rejected it.
			if not subdivided.ready and subdivided.get("split", {}).get("reason") == "no_exact_threshold_courses" \
					and proven_seats.has(selected.id) and not source.is_grounded_structural_root(selected_part):
				return Housing.prepare(selected_part, threshold_bottom, center, size)
			return subdivided
		return _fail("unrepresentable_threshold_seated_bearing", {"seatId": selected.id,
			"seatPlane": seat_plane, "thresholdBottom": threshold_bottom,
			"representedBottom": represented_bottom, "representedTop": represented_top,
			"position": position, "size": seated_size})
	var patch_center: Vector2 = selected.patch.center
	var patch_half: Vector2 = selected.patch.half
	var fact: Dictionary = Seats.world_down_seat_fact(selected.id,
		Vector3(patch_center.x, -seated_size.y * 0.5, patch_center.y), patch_half)
	return {"ready": true, "seated": true, "seatId": selected.id,
		"position": position, "size": seated_size, "seatFact": fact, "seatPlane": seat_plane}


static func _subdivide(selected: Dictionary, upper: float, center: Vector3, size: Vector3, bearing_id: String) -> Dictionary:
	var split := Splitter.prepare(float(selected.top), upper)
	if not split.ready:
		return _fail("unrepresentable_threshold_seated_courses", {"seatId": selected.id,
			"seatPlane": selected.top, "thresholdBottom": upper, "split": split})
	if split.courses.size() != 2:
		return _fail("inconsistent_threshold_course_partition")
	var ids := [bearing_id + "_base", bearing_id]
	var courses: Array = []
	for index in range(2):
		var course: Dictionary = split.courses[index]
		var course_size := Vector3(size.x, course.height, size.z)
		var position := Vector3(center.x, course.centerY, center.z)
		var patch_center := Vector2.ZERO
		var patch_half := Vector2((float(size.x) * 0.5 - PATCH_INSET) * 0.5,
			(float(size.z) * 0.5 - PATCH_INSET) * 0.5)
		if index == 0:
			patch_center = selected.patch.center
			patch_half = selected.patch.half
		if not patch_half.is_finite() or patch_half.x <= 0.0 or patch_half.y <= 0.0:
			return _fail("invalid_threshold_course_patch")
		var seat_id: String = selected.id if index == 0 else ids[0]
		var fact := Seats.world_down_seat_fact(seat_id,
			Vector3(patch_center.x, -course_size.y * 0.5, patch_center.y), patch_half)
		courses.append({"id": ids[index], "position": position, "size": course_size,
			"seatFact": fact, "seatId": seat_id, "bottom": course.bottom, "top": course.top})
	return {"ready": true, "seated": true, "seatId": selected.id, "seatPlane": selected.top,
		"courses": courses, "splitTrials": split.splitTrials, "thresholdBottom": upper}


static func _inset_patch(center: Vector3, size: Vector3, seat) -> Dictionary:
	# Intersect both 5 cm-inset footprints in bearer-local XZ using scalar
	# arithmetic. Use only the middle half of that intersection; recheck stored
	# Vector2 values after rounding. No arbitrary world-space offset or minimum
	# patch borrowed from a particular house/seed.
	var centers: Array = []
	var halves: Array = []
	for axis in [0, 2]:
		var bearer_half: float = float(size[axis]) * 0.5
		var seat_half: float = float(seat.size[axis]) * 0.5
		var offset: float = float(seat.position[axis]) - float(center[axis])
		var low := maxf(-bearer_half + PATCH_INSET, offset - seat_half + PATCH_INSET)
		var high := minf(bearer_half - PATCH_INSET, offset + seat_half - PATCH_INSET)
		if not is_finite(low) or not is_finite(high) or low >= high: return {}
		var stored_center: float = Vector2((low + high) * 0.5, 0.0).x
		var available := minf(stored_center - low, high - stored_center)
		var stored_half: float = Vector2(available * 0.5, 0.0).x
		if not is_finite(stored_center) or not is_finite(stored_half) or stored_half <= 0.0 \
				or stored_center - stored_half < low or stored_center + stored_half > high:
			return {}
		centers.append(stored_center)
		halves.append(stored_half)
	return {"center": Vector2(centers[0], centers[1]), "half": Vector2(halves[0], halves[1])}


static func _finite_box(center: Vector3, size: Vector3) -> bool:
	return center.is_finite() and size.is_finite() and size.x > 0.0 and size.y > 0.0 and size.z > 0.0


static func _finite_part(part) -> bool:
	return part != null and part.rotation.is_finite() and _finite_box(part.position, part.size)


static func _full_box_source(part) -> bool:
	# BuildingPartPublisher.publish_part/publish_static_part publish foundation
	# collision as one BoxShape3D of part.size; material selects visuals only.
	# Both paths first gate the two recipe-selected cut/publication families.
	# Presence (even an empty/malformed value) enters that authority. This small
	# helper does not certify their prepared shape artifacts from an envelope.
	# Hollow buildings are composed from separate parts, not a hollow-box flag.
	# Reject these modifiers without inspecting IDs, materials or semantic names.
	return not part.recipe.has("masonryApertureSource") and not part.recipe.has("pavingFootingJoints")


static func _fail(reason: String, detail: Dictionary = {}) -> Dictionary:
	var result := detail.duplicate(true)
	result["ready"] = false
	result["seated"] = false
	result["reason"] = reason
	return result
