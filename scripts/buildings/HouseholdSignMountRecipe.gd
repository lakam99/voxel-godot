extends RefCounted

## Unwired ordinary street-house recipe. A hanging sign is one rigid two-part
## assembly: the arm and board translate together from the obsolete presentation
## plane to a finite socket in a rooted structural member owned by the same
## producer. This includes repaired opening-head/bearing members where the
## partitioned masonry intentionally leaves a door or window opening.
## No seed, row, building or blocker exceptions; no new collision geometry.
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const MAX_FACADES := 128
const MAX_PROTECTED := 4096
const SOCKET_HALF := Vector3(0.015, 0.020, 0.020)
const SOCKET_INSET := 0.020
const MAX_IN_PLANE_TRANSLATION := 1.25

static func plan(source, arm, board, door, facades: Array, protected: Array = []) -> Dictionary:
	if source == null or not arm is Part or not board is Part or not door is Part or facades.is_empty() or facades.size() > MAX_FACADES or protected.size() > MAX_PROTECTED:
		return _fail("missing_or_unbounded_source")
	for part in [arm, board, door]:
		if not source.has_finite_positive_bounds(part): return _fail("invalid_source_geometry")
	if arm.kind != "beam" or board.kind != "sign" or arm.semantic != "citadel_household_sign" or board.semantic != "citadel_household_sign" or arm.collision_enabled or board.collision_enabled or arm.rotation != Vector3.ZERO or board.rotation != Vector3.ZERO:
		return _fail("invalid_sign_assembly")
	if not door.id.ends_with("_door") or door.semantic != "citadel_urban_door":
		return _fail("invalid_house_declaration")
	var prefix: String = door.id.trim_suffix("_door")
	if prefix.is_empty() or arm.id != prefix + "_sign_arm" or board.id != prefix + "_hanging_sign":
		return _fail("foreign_producer_member")
	var board_direction := signf(board.position.z - arm.position.z)
	if board_direction == 0.0 or absf(board.position.x - arm.position.x) > 0.25:
		return _fail("ambiguous_sign_layout")
	if SOCKET_HALF.x >= arm.size.x * 0.5 or SOCKET_HALF.y >= arm.size.y * 0.5 or SOCKET_HALF.z >= arm.size.z * 0.5:
		return _fail("arm_too_small_for_socket")
	# The arm runs laterally along the facade; its midpoint is the strongest
	# producer-independent wall socket and keeps the hanging board at its exact
	# rigid offset near one end.
	var local_mount := Vector3.ZERO
	var protected_bounds: Array = []
	var wall_panel_ids: Array = source.parts.filter(func(value):
		return value is Part and value.id.begins_with(prefix + "_") and value.semantic == "citadel_urban_facade").map(func(value): return value.id)
	for value in protected:
		if value is AABB and _bounds_valid(value):
			protected_bounds.append(value)
		elif value is Dictionary and value.get("bounds") is AABB and _bounds_valid(value.bounds):
			protected_bounds.append(value.bounds)
		else:
			return _fail("invalid_protected_volume")
	var rows: Array = []
	var rejected: Array = []
	for facade in facades:
		if not facade is Part or not source.has_finite_positive_bounds(facade) or not facade.id.begins_with(prefix + "_") or not facade.collision_enabled or facade.rotation != Vector3.ZERO or facade.physical_intent not in ["structural_mass", "structural_root"]:
			return _fail("invalid_structural_anchor_membership")
		if not source.has_rooted_support_chain(facade, {}):
			rejected.append({"anchorId": facade.id, "reason": "facade_not_rooted"})
			continue
		var side := signf(arm.position.x - facade.position.x)
		if side == 0.0:
			rejected.append({"anchorId": facade.id, "reason": "ambiguous_side"})
			continue
		var record: Dictionary = arm.snapshot()
		var embed := SOCKET_HALF.x * 2.0 + SOCKET_INSET
		record.position.x = facade.position.x + side * (facade.size.x * 0.5 + arm.size.x * 0.5 - embed)
		# Partitioned facades can place the old presentation datum just beyond a
		# panel edge. Clamp the actual mount socket into this candidate panel and
		# move the entire sign rigidly by the same bounded in-plane correction.
		var inset := Blueprint.STAIR_HOUSED_JOINT_INSET + 0.001
		var candidate_mount: Vector3 = local_mount
		candidate_mount.x = -side * (arm.size.x * 0.5 - embed + SOCKET_HALF.x + inset)
		var desired_socket: Vector3 = record.position + candidate_mount
		var available_y: float = facade.size.y * 0.5 - SOCKET_HALF.y - inset
		var available_z: float = facade.size.z * 0.5 - SOCKET_HALF.z - inset
		if available_y <= 0.0 or available_z <= 0.0:
			rejected.append({"anchorId": facade.id, "reason": "facade_too_small_for_socket"})
			continue
		var target_y: float = facade.position.y + clampf(desired_socket.y - facade.position.y, -available_y, available_y)
		var target_z: float = facade.position.z + clampf(desired_socket.z - facade.position.z, -available_z, available_z)
		var in_plane := Vector2(target_y - desired_socket.y, target_z - desired_socket.z)
		if in_plane.length() > MAX_IN_PLANE_TRANSLATION:
			rejected.append({"anchorId": facade.id, "reason": "in_plane_translation_limit", "distance": in_plane.length()})
			continue
		record.position.y += in_plane.x
		record.position.z += in_plane.y
		var delta: Vector3 = record.position - arm.position
		var board_record: Dictionary = board.snapshot()
		board_record.position = record.position + (board.position - arm.position)
		var candidate_arm = Part.new(record)
		var candidate_board = Part.new(board_record)
		var fact := {"anchorId": facade.id, "contactMode": "attachment_socket",
			"localMountCenter": candidate_mount, "localMountHalfExtents": SOCKET_HALF}
		candidate_arm.recipe["physicalRequiredAnchorPartIds"] = [facade.id]
		candidate_arm.recipe["physicalRequiredAnchorFacts"] = [fact]
		if not source.has_rooted_attachment_socket(candidate_arm, fact):
			rejected.append({"anchorId": facade.id, "reason": "finite_socket_failed",
				"diagnostic": source.attachment_socket_diagnostics(candidate_arm, fact)})
			continue
		var clear := _clear(source, candidate_arm, candidate_board, arm.id, board.id, prefix, facade.id, wall_panel_ids, protected_bounds)
		if not clear.ready:
			rejected.append({"anchorId": facade.id, "reason": clear.reason, "partId": clear.get("partId", "")})
			continue
		rows.append({"armRecord": candidate_arm.snapshot(), "boardRecord": candidate_board.snapshot(),
			"anchorId": facade.id, "anchorFact": fact, "delta": delta,
			"translation": delta.length(), "socketVolume": SOCKET_HALF.x * SOCKET_HALF.y * SOCKET_HALF.z * 8.0})
	if rows.is_empty(): return _fail("no_clear_rooted_structural_socket", {"candidates": rejected})
	rows.sort_custom(func(a, b):
		if a.socketVolume != b.socketVolume: return a.socketVolume > b.socketVolume
		if a.translation != b.translation: return a.translation < b.translation
		return a.anchorId < b.anchorId)
	var selected: Dictionary = rows[0]
	return {"ready": true, "reason": "", "armRecord": selected.armRecord,
		"boardRecord": selected.boardRecord, "anchorId": selected.anchorId,
		"anchorFact": selected.anchorFact, "delta": selected.delta,
		"candidateCount": rows.size(),
		"scope": "Source-only rigid sign assembly and finite rooted facade socket; no published, visual, gameplay or engineering acceptance."}

static func apply(source, arm_id: String, board_id: String, door_id: String, facade_ids: Array, protected: Array = []) -> Dictionary:
	var arm = source.find_part(arm_id)
	var board = source.find_part(board_id)
	var door = source.find_part(door_id)
	var facades: Array = facade_ids.map(func(id): return source.find_part(String(id)))
	var result := plan(source, arm, board, door, facades, protected)
	if not result.ready: return result
	arm.position = result.armRecord.position
	arm.recipe = result.armRecord.recipe.duplicate(true)
	board.position = result.boardRecord.position
	return result

static func _clear(source, arm, board, original_arm_id: String, original_board_id: String, prefix: String, anchor_id: String, wall_panel_ids: Array, protected: Array) -> Dictionary:
	var arm_bounds: AABB = source.transformed_part_bounds(arm)
	var board_bounds: AABB = source.transformed_part_bounds(board)
	if not _bounds_valid(arm_bounds) or not _bounds_valid(board_bounds): return _fail("invalid_candidate_bounds")
	for part in source.parts:
		# The rigid assembly may cross seams between adjacent panels of its own
		# partitioned wall. Only one finite rooted panel is the declared socket;
		# the other producer-owned panels are ordinary wall occupancy, not foreign
		# obstructions.
		if part == null or part.id in [original_arm_id, original_board_id, anchor_id] or wall_panel_ids.has(part.id): continue
		# Existing noncolliding trim from the same declared producer shares the
		# facade dressing layer. It is not structural occupancy and cannot become
		# a gameplay blocker; foreign dressing remains protected.
		if part.id.begins_with(prefix + "_") and not part.collision_enabled: continue
		var bounds: AABB = source.transformed_part_bounds(part)
		if arm_bounds.intersects(bounds) and source.transformed_boxes_intersect(arm, part, 0.0):
			return _fail("arm_intrudes_source", {"partId": part.id})
		if board_bounds.intersects(bounds) and source.transformed_boxes_intersect(board, part, 0.0):
			return _fail("board_intrudes_source", {"partId": part.id})
	for bounds: AABB in protected:
		if arm_bounds.intersects(bounds) or board_bounds.intersects(bounds):
			return _fail("sign_intrudes_protected_volume")
	return {"ready": true}

static func _bounds_valid(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() and bounds.end.is_finite() and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0

static func _fail(reason: String, detail: Dictionary = {}) -> Dictionary:
	var result := detail.duplicate(true)
	result["ready"] = false
	result["reason"] = reason
	return result
