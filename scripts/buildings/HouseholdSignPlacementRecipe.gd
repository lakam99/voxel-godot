extends RefCounted

## Pure initial source construction, not a live attachment lifecycle.
## Preserve valid source records, then consider the capped source planner on
## the ORIGINAL template, then the bounded declared frontage. Never rebase a
## template and run the capped planner again. One proven result, no mutation.
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Mount = preload("res://scripts/buildings/HouseholdSignMountRecipe.gd")
const Aperture = preload("res://scripts/buildings/FacadeApertureDeclaration.gd")
const DoorGeometry = preload("res://scripts/buildings/BuildingDoorGeometry.gd")
const SeamMath = preload("res://scripts/buildings/ConstructionSeamMath.gd")
const Admission = preload("res://scripts/buildings/ConstructionBoxAdmission.gd")
const MAX_PARTS := 8192
const MAX_AXIS_CANDIDATES := 128
const MAX_PLACEMENTS := 4096
const MAX_SAT_WORK := 250000
const EDGE_GAP := 0.001

static func propose(source, arm, board, door, declaration_keys: Array, protected: Array = [], preferred_facades: Array = []) -> Dictionary:
	if source == null or source.parts.size() > MAX_PARTS or declaration_keys.is_empty() or declaration_keys.size() > Mount.MAX_FACADES or protected.size() > Mount.MAX_PROTECTED:
		return _fail("missing_or_unbounded_source")
	for p in [arm, board, door]:
		if not p is Part or not source.has_finite_positive_bounds(p) or p.rotation != Vector3.ZERO: return _fail("invalid_source_geometry")
	if arm.kind != "beam" or board.kind != "sign" or arm.semantic != "citadel_household_sign" or board.semantic != arm.semantic or arm.collision_enabled or board.collision_enabled or door.semantic != "citadel_urban_door" or not door.id.ends_with("_door"):
		return _fail("invalid_sign_or_house")
	var prefix: String = door.id.trim_suffix("_door")
	if prefix.is_empty() or arm.id != prefix + "_sign_arm" or board.id != prefix + "_hanging_sign": return _fail("foreign_producer_member")
	var offset: Vector3 = board.position - arm.position
	if offset.z == 0.0 or absf(offset.x) > 0.25: return _fail("ambiguous_sign_layout")
	for axis in range(3):
		if Mount.SOCKET_HALF[axis] >= arm.size[axis] * 0.5: return _fail("arm_too_small_for_socket")
	var by_id := {}
	for p in source.parts:
		if not p is Part or p.id.is_empty() or by_id.has(p.id) or not source.has_finite_positive_bounds(p): return _fail("invalid_source_parts")
		by_id[p.id] = p
	for p in [arm,board,door]:
		if not by_id.has(p.id) or var_to_bytes(by_id[p.id].snapshot()) != var_to_bytes(p.snapshot()): return _fail("template_not_current_source")
	if not source.recipe.get("facadeApertures") is Dictionary: return _fail("missing_facade_declarations")
	var panels: Array = []
	var panel_ids: Array = []
	var openings: Array = []
	var domains: Array = []
	var seen_declarations := {}
	for key in declaration_keys:
		if not key is String: return _fail("invalid_facade_declaration_key")
		if seen_declarations.has(key): return _fail("duplicate_facade_declaration")
		seen_declarations[key] = true
		var declaration: Variant = source.recipe.get("facadeApertures", {}).get(key)
		if not key is String or not key.begins_with(prefix + "_") or not Aperture.validate(declaration, by_id) or declaration.get("semantic") != "citadel_urban_facade" or not declaration.get("wallDomain") is AABB:
			return _fail("invalid_or_stale_facade_declaration")
		domains.append(declaration.wallDomain)
		for id: String in declaration.partIds:
			var panel = by_id[id]
			if panel_ids.has(id): continue
			# This prototype uses only existing panels, not fabricated repair heads.
			if panel.semantic != "citadel_urban_facade": continue
			if not id.begins_with(prefix + "_") or panel.rotation != Vector3.ZERO or not panel.collision_enabled: return _fail("invalid_facade_member")
			panel_ids.append(id)
			panels.append(panel)
		for opening in declaration.get("openings", []):
			if not opening is Dictionary or not opening.get("fullVolume") is AABB: return _fail("invalid_aperture_volume")
			openings.append(opening.fullVolume)
	if panels.is_empty() or panels.size() > Mount.MAX_FACADES or openings.size() > Mount.MAX_PROTECTED: return _fail("unbounded_facade_geometry")
	panels.sort_custom(func(a, b): return a.id < b.id)
	var plane = panels[0]
	if not panels.all(func(p): return p.position.x == plane.position.x and p.size.x == plane.size.x): return _fail("multiple_facade_planes")
	var side := signf(door.position.x - plane.position.x)
	if side == 0.0 or side != signf(arm.position.x - plane.position.x): return _fail("ambiguous_frontage")
	var envelope: AABB = domains[0]
	for domain: AABB in domains:
		if not Mount._bounds_valid(domain): return _fail("invalid_facade_domain")
		envelope = envelope.merge(domain)
	# The whole assembly remains within the household's frontage width, above
	# its door's ground datum and below its facade top. Finite sockets further
	# restrict this to real panel material. Apertures remain unobstructed in Y/Z.
	var relative_low: Vector3 = (-arm.size * 0.5).min(offset - board.size * 0.5)
	var relative_high: Vector3 = (arm.size * 0.5).max(offset + board.size * 0.5)
	var ground := maxf(envelope.position.y, door.position.y - door.size.y * 0.5)
	var placement_low := Vector2(ground - relative_low.y, envelope.position.z - relative_low.z)
	var placement_high := Vector2(envelope.end.y - relative_high.y, envelope.end.z - relative_high.z)
	if placement_low.x > placement_high.x or placement_low.y > placement_high.y: return _fail("empty_initial_placement_domain")
	var embed := Mount.SOCKET_HALF.x * 2.0 + Mount.SOCKET_INSET
	var mount_x: float = plane.position.x + side * (plane.size.x * 0.5 + arm.size.x * 0.5 - embed)
	var inset := Blueprint.STAIR_HOUSED_JOINT_INSET + 0.001
	var local_mount := Vector3(-side * (arm.size.x * 0.5 - embed + Mount.SOCKET_HALF.x + inset), 0, 0)
	var obstacles: Array = []
	for p in source.parts:
		# Same clearance exclusions as Mount, without exempting any foreign part.
		if p.id in [arm.id, board.id] or panel_ids.has(p.id): continue
		if p.id.begins_with(prefix + "_") and not p.collision_enabled: continue
		obstacles.append({"id": p.id, "bounds": source.transformed_part_bounds(p), "part": p})
	for value in protected:
		var bounds: Variant = value.get("bounds") if value is Dictionary else value
		if not bounds is AABB or not Mount._bounds_valid(bounds): return _fail("invalid_protected_volume")
		obstacles.append({"id": "protected", "bounds": bounds})
	var angle: Variant = door.recipe.get("openSwing", DoorGeometry.DEFAULT_OPEN_SWING)
	if not (angle is int or angle is float): return _fail("invalid_door_angle")
	var sweeps: Array = DoorGeometry.ordinary_sweep_bounds(door.size, Transform3D(Basis.from_euler(door.rotation), door.position), float(angle))
	if sweeps.is_empty(): return _fail("invalid_door_sweep")
	for sweep in sweeps:
		var bounds: Variant = sweep.get("bounds") if sweep is Dictionary else sweep
		if not bounds is AABB or not Mount._bounds_valid(bounds): return _fail("invalid_door_sweep")
		obstacles.append({"id": "door_sweep", "bounds": bounds})
	for bounds: AABB in openings:
		# Extrude actual aperture Y/Z through the dressing plane: an outside
		# sign must not occlude a declared opening just because X does not touch.
		obstacles.append({"id": "aperture_projection", "bounds": AABB(Vector3(mount_x + relative_low.x - EDGE_GAP, bounds.position.y, bounds.position.z), Vector3(relative_high.x - relative_low.x + EDGE_GAP * 2, bounds.size.y, bounds.size.z))})
	var swept := AABB(Vector3(mount_x + relative_low.x, placement_low.x + relative_low.y, placement_low.y + relative_low.z), Vector3(relative_high.x - relative_low.x, placement_high.x - placement_low.x + relative_high.y - relative_low.y, placement_high.y - placement_low.y + relative_high.z - relative_low.z))
	obstacles.sort_custom(func(a, b):
		if a.id != b.id: return a.id < b.id
		return str(a.bounds) < str(b.bounds))
	var work := {"candidateCount": 0, "satPairs": 0, "nearbyObstacles": obstacles.size(), "rigidRejected":0, "socketRejected":0, "clearanceRejected":0}
	var existing_value: Variant = arm.recipe.get("physicalRequiredAnchorFacts", [])
	if not existing_value is Array: return _fail("invalid_existing_socket_facts")
	var existing_facts: Array = existing_value
	if not existing_facts.is_empty():
		if existing_facts.size() != 1 or not existing_facts[0] is Dictionary: return _fail("invalid_existing_socket_facts")
		var fact: Dictionary = existing_facts[0]
		var anchor = by_id.get(String(fact.get("anchorId", "")))
		if anchor != null and anchor.id.begins_with(prefix + "_") and source.has_rooted_attachment_socket(arm, fact):
			var clear := _clear(source, arm, board, obstacles, work, anchor.id)
			if clear.ready and _in_domain(arm,placement_low,placement_high) and _assembly_in_frontage(arm,board,ground,envelope):
				return _result(arm.snapshot(), board.snapshot(), fact, Vector3.ZERO, "existing_clear_exact", work, placement_low, placement_high)
	# Generic derived anchor chains can name a foreign terrace. They are not a
	# published-state authority and do not waive source ownership or clearance.
	var preferred: Array = preferred_facades.duplicate()
	if preferred.is_empty():
		preferred = panels.filter(func(p):return p.physical_intent in ["structural_mass","structural_root"] and source.has_rooted_support_chain(p,{}))
	if preferred.size() > Mount.MAX_FACADES: return _fail("preferred_facade_limit")
	for p in preferred:
		if not p is Part or not by_id.has(p.id) or by_id[p.id] != p or not p.id.begins_with(prefix + "_"): return _fail("invalid_preferred_facade")
	if not preferred.is_empty():
		var capped := Mount.plan(source,arm,board,door,preferred,protected)
		if capped.ready:
			var capped_arm = Part.new(capped.armRecord)
			var capped_board = Part.new(capped.boardRecord)
			var clear := _clear(source,capped_arm,capped_board,obstacles,work,capped.anchorId)
			if clear.ready and _in_domain(capped_arm,placement_low,placement_high) and _assembly_in_frontage(capped_arm,capped_board,ground,envelope) and capped_board.position==capped_arm.position+offset and source.has_rooted_attachment_socket(capped_arm,capped.anchorFact):
				return _result(capped.armRecord,capped.boardRecord,capped.anchorFact,capped.delta,"original_template_preferred",work,placement_low,placement_high)
		elif capped.reason != "no_clear_rooted_structural_socket":
			return _fail("invalid_preferred_plan",{"detail":capped})
	obstacles = obstacles.filter(func(o): return swept.intersects(o.bounds))
	work.nearbyObstacles = obstacles.size()
	var preferred_point := Vector2(door.position.y + door.size.y * 0.5 + arm.size.y * 0.5, door.position.z)
	var candidates: Array = []
	for panel in panels:
		if panel.physical_intent not in ["structural_mass", "structural_root"] or not source.has_rooted_support_chain(panel, {}): continue
		var half := Vector2(panel.size.y * 0.5 - Mount.SOCKET_HALF.y - inset, panel.size.z * 0.5 - Mount.SOCKET_HALF.z - inset)
		var low := Vector2(panel.position.y, panel.position.z) - half
		var high := Vector2(panel.position.y, panel.position.z) + half
		low = low.max(placement_low)
		high = high.min(placement_high)
		if half.x <= 0 or half.y <= 0 or low.x > high.x or low.y > high.y: continue
		var axes: Array = []
		for index in range(2):
			var axis := index + 1
			var values: Array = []
			_add(values, clampf(preferred_point[index], low[index], high[index]), low[index], high[index])
			_add(values, _outward(low[index], true), low[index], high[index])
			_add(values, _outward(high[index], false), low[index], high[index])
			for obstacle in obstacles:
				for bounds: AABB in [AABB(-arm.size * 0.5, arm.size), AABB(offset - board.size * 0.5, board.size)]:
					_add(values, _outward(obstacle.bounds.position[axis] - bounds.end[axis] - EDGE_GAP, false), low[index], high[index])
					_add(values, _outward(obstacle.bounds.end[axis] - bounds.position[axis] + EDGE_GAP, true), low[index], high[index])
			if values.size() > MAX_AXIS_CANDIDATES: return _fail("source_axis_candidate_limit", {"work": work})
			axes.append(values)
		if candidates.size() + axes[0].size() * axes[1].size() > MAX_PLACEMENTS: return _fail("source_placement_limit", {"work": work})
		for y: float in axes[0]:
			for z: float in axes[1]:
				var point := Vector2(y, z)
				candidates.append({"point": point, "anchor": panel, "score": point.distance_squared_to(preferred_point)})
	candidates.sort_custom(func(a, b):
		if a.score != b.score: return a.score < b.score
		if a.anchor.id != b.anchor.id: return a.anchor.id < b.anchor.id
		return a.point.x < b.point.x if a.point.x != b.point.x else a.point.y < b.point.y)
	for candidate in candidates:
		work.candidateCount += 1
		var record: Dictionary = arm.snapshot()
		record.position = Vector3(mount_x, candidate.point.x, candidate.point.y)
		var delta: Vector3 = record.position-arm.position
		var fact := {"anchorId": candidate.anchor.id, "contactMode": "attachment_socket", "localMountCenter": local_mount, "localMountHalfExtents": Mount.SOCKET_HALF}
		record.recipe["physicalRequiredAnchorPartIds"] = [candidate.anchor.id]
		record.recipe["physicalRequiredAnchorFacts"] = [fact]
		var board_record: Dictionary = board.snapshot()
		board_record.position = record.position+offset
		var proposed_arm = Part.new(record)
		var proposed_board = Part.new(board_record)
		# Preserve the existing Mount recipe's arithmetic order exactly. Recovering
		# old offset bits by inverse subtraction is not a float32 transform rule.
		if proposed_arm.position != record.position or proposed_board.position != proposed_arm.position+offset:
			work.rigidRejected += 1
			continue
		if not _in_domain(proposed_arm,placement_low,placement_high) or not _assembly_in_frontage(proposed_arm,proposed_board,ground,envelope): continue
		if not source.has_rooted_attachment_socket(proposed_arm, fact):
			work.socketRejected += 1
			continue
		var clear := _clear(source, proposed_arm, proposed_board, obstacles, work)
		if clear.reason == "source_sat_work_limit": return _fail(clear.reason, {"work": work})
		if not clear.ready:
			work.clearanceRejected += 1
			continue
		return _result(proposed_arm.snapshot(), proposed_board.snapshot(), fact, delta, "initial_frontage_choice", work, placement_low, placement_high)
	return _fail("no_initial_placement_in_bounded_candidates", {"work": work, "domainLowYZ": placement_low, "domainHighYZ": placement_high})

static func _in_domain(arm, low: Vector2, high: Vector2) -> bool:
	return arm.position.y >= low.x and arm.position.y <= high.x and arm.position.z >= low.y and arm.position.z <= high.y

static func _assembly_in_frontage(arm,board,ground: float,envelope: AABB) -> bool:
	for p in [arm,board]:
		if float(p.position.y)-float(p.size.y)*0.5 < ground or float(p.position.y)+float(p.size.y)*0.5 > envelope.end.y: return false
		if float(p.position.z)-float(p.size.z)*0.5 < envelope.position.z or float(p.position.z)+float(p.size.z)*0.5 > envelope.end.z: return false
	return true

static func _clear(source, arm, board, obstacles: Array, work: Dictionary, anchor_id := "") -> Dictionary:
	for member in [arm, board]:
		var bounds: AABB = source.transformed_part_bounds(member)
		for obstacle in obstacles:
			if obstacle.id == anchor_id: continue
			if not bounds.intersects(obstacle.bounds): continue
			if not obstacle.has("part"): return _fail("protected_or_aperture_overlap", {"id": obstacle.id})
			if work.satPairs >= MAX_SAT_WORK: return _fail("source_sat_work_limit")
			work.satPairs += 1
			var p = obstacle.part
			var measure := Admission.measure(Transform3D(Basis.from_euler(member.rotation) * Basis.from_scale(member.size), member.position), Transform3D(Basis.from_euler(p.rotation) * Basis.from_scale(p.size), p.position))
			if not measure.valid or not measure.clear or source.transformed_boxes_intersect(member, p, 0.0): return _fail("source_overlap", {"id": p.id})
	return {"ready": true, "reason": ""}

static func _add(values: Array, value: float, low: float, high: float) -> void:
	if value >= low and value <= high and not values.has(value): values.append(value)

static func _outward(value: float, increasing: bool) -> float:
	var result := float(Vector3(value, 0, 0).x)
	if increasing and result < value: return SeamMath.next_float32_up(result)
	if not increasing and result > value: return -SeamMath.next_float32_up(-result)
	return result

static func _result(arm: Dictionary, board: Dictionary, fact: Dictionary, delta: Vector3, mode: String, work: Dictionary, low: Vector2, high: Vector2) -> Dictionary:
	return {"ready": true, "reason": "", "mode": mode, "armRecord": arm, "boardRecord": board, "anchorFact": fact, "sourceDelta": delta,
		"preferredSourceCorrectionBound": Mount.MAX_IN_PLANE_TRANSLATION, "work": work.duplicate(), "domainLowYZ": low, "domainHighYZ": high,
		"scope": "Source construction candidate only. No live movement, rendered, gameplay or navigation acceptance."}

static func _fail(reason: String, detail: Dictionary = {}) -> Dictionary:
	var result := detail.duplicate(true)
	result["ready"] = false
	result["reason"] = reason
	return result
