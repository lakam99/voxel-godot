extends RefCounted

## Unwired prototype: source-box proof only, never publisher/gameplay acceptance.
## Caller supplies the ENTIRE actual producer row, before terminal frame assembly.
## Both APIs take (blueprint, member_ids:Array). apply recomputes plan atomically;
## caller-provided positions, cached roots and precomputed plans are not trusted.
## No geometry, intent, root flags or joint contracts are authored by this recipe.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
# Reuse the existing bounded validator-input guards, not canopy construction.
const SupportGuards = preload("res://scripts/buildings/MarketCanopyFrameBuilder.gd")
const MAX_SOURCE_PARTS := 32768
const MAX_MEMBERS := 256
const MAX_SUPPORT_CONTEXT := 128
const MAX_SUPPORT_CLOSURE := 32
const MAX_COORDINATE := 1000000.0
const MAX_LATERAL_OBSTACLES := 8192

static func plan(blueprint, member_ids: Array, additional_obstacles: Array = []) -> Dictionary:
	if blueprint == null or blueprint.parts.is_empty() or blueprint.parts.size() > MAX_SOURCE_PARTS or member_ids.is_empty() or member_ids.size() > MAX_MEMBERS:
		return _fail("invalid_or_excessive_input")
	var records: Dictionary = {}
	for part in blueprint.parts:
		if part == null or String(part.id).is_empty() or records.has(part.id):
			return _fail("missing_or_duplicate_source_id")
		if not blueprint.has_finite_positive_bounds(part):
			return _fail("invalid_source_bounds", {"partId": part.id})
		var bounds: AABB = blueprint.transformed_part_bounds(part)
		if not _bounded(bounds):
			return _fail("invalid_source_bounds", {"partId": part.id})
		records[part.id] = {"part": part, "bounds": bounds, "footprint": _footprint(bounds)}
	var members: Dictionary = {}
	var minimum := Vector3.INF
	var maximum := -Vector3.INF
	var jambs: Array = []
	var headers := 0
	for id in member_ids:
		if not id is String or id.is_empty() or members.has(id) or not records.has(id):
			return _fail("invalid_or_missing_member")
		var part = records[id].part
		if not String(part.semantic).begins_with("citadel_terminal_shop") and part.semantic != "citadel_urban_lantern_flame":
			return _fail("invalid_row_member_role", {"partId": id})
		# This is a pre-frame operation. Existing world-space joint payloads
		# cannot be silently retained after a translation.
		for key in part.recipe:
			if String(key).begins_with("physicalRequired"):
				return _fail("row_already_has_joint_contract", {"partId": id})
		if part.semantic == "citadel_terminal_shop_frame":
			if part.kind != "beam" or not Basis.from_euler(part.rotation).y.is_equal_approx(Vector3.UP):
				return _fail("invalid_row_frame_orientation", {"partId": id})
			if part.size.y > maxf(part.size.x, part.size.z):
				jambs.append(part)
			else:
				headers += 1
		minimum = minimum.min(records[id].bounds.position)
		maximum = maximum.max(records[id].bounds.end)
		members[id] = true
	if jambs.size() < 2 or jambs.size() != headers * 2:
		return _fail("incomplete_row_frame_geometry")
	jambs.sort_custom(func(a, b): return a.id < b.id)
	var original_base: float = jambs[0].position.y - jambs[0].size.y * 0.5
	for jamb in jambs:
		if jamb.position.y - jamb.size.y * 0.5 != original_base:
			return _fail("inconsistent_jamb_bottoms")
	var row_bounds := AABB(minimum, maximum - minimum)
	var footprint := _footprint(row_bounds)
	var sorted_ids: Array = members.keys()
	sorted_ids.sort()
	var details := {"memberIds": sorted_ids, "originalBaseY": original_base,
		"householdBounds": row_bounds, "householdFootprint": footprint,
		"candidateSupports": [], "changes": [], "evidenceLevel": "source_only_unwired_elevation_prototype"}
	var protected := _protected_bounds(blueprint, additional_obstacles)
	if not protected.ready:
		return protected
	var candidates: Array = []
	for id in records:
		var part = records[id].part
		var bounds: AABB = records[id].bounds
		if members.has(id) or part.kind != "foundation" or not part.collision_enabled or part.rotation != Vector3.ZERO:
			continue
		# Do not select an unrelated roof above the row, or lower the row.
		# Touching is retained so a completed elevation can be planned again.
		if bounds.position.y > row_bounds.end.y or bounds.end.y < row_bounds.position.y:
			continue
		if not (records[id].footprint as Rect2).encloses(footprint):
			continue
		candidates.append({"id": String(id), "top": float(part.position.y + part.size.y * 0.5)})
	candidates.sort_custom(func(a, b): return a.top > b.top if a.top != b.top else a.id < b.id)
	details.candidateSupports = candidates
	if candidates.is_empty():
		return _fail("no_enclosing_intersecting_foundation", details)
	var selected: Dictionary = candidates[0]
	details["supportId"] = selected.id
	details["standingY"] = selected.top
	var closure := _support_closure(blueprint, records, members, selected.id)
	details["supportClosure"] = closure
	details["upstreamIds"] = closure.get("partIds", []).filter(func(id): return id != selected.id)
	if not closure.ready:
		return _fail("support_closure_unproven", details)
	var delta := Vector3(0.0, maxf(0.0, selected.top - original_base), 0.0)
	# If the source jamb centres cannot represent this residual rise, don't
	# repeatedly move smaller/lower details while leaving the base unchanged.
	# Exact representability, not a new contact tolerance or stored marker.
	if not jambs.any(func(jamb): return jamb.position + delta != jamb.position):
		delta = Vector3.ZERO
	var lateral := _lateral_clearance(records, members, selected.id, row_bounds, jambs, delta, protected.obstacles)
	details["lateralClearance"] = lateral
	if not lateral.ready:
		return _fail("no_lateral_row_clearance", details)
	delta += lateral.translation
	var final_row := AABB(row_bounds.position + delta, row_bounds.size)
	for reservation in protected.obstacles:
		if final_row.intersects(reservation.bounds):
			return _fail("translated_row_intersects_reservation", {"reservationId": reservation.id})
	var changes: Array = []
	var collisions: Array = []
	var source_ids: Array = records.keys()
	source_ids.sort()
	for id in sorted_ids:
		var part = records[id].part
		var after: Vector3 = part.position + delta
		var placed := Blueprint.BuildingPartScript.new(part.snapshot())
		placed.position = after
		var bounds: AABB = blueprint.transformed_part_bounds(placed)
		if not after.is_finite() or not _bounded(bounds):
			return _fail("invalid_proposed_bounds", details)
		for other_id in source_ids:
			if members.has(other_id) or (not records[other_id].part.collision_enabled and not bool(records[other_id].part.recipe.get("visual", true))):
				continue
			var other: AABB = records[other_id].bounds
			var overlap := bounds.end.min(other.end) - bounds.position.max(other.position)
			if overlap.x <= 0.0 or overlap.y <= 0.0 or overlap.z <= 0.0:
				continue
			# Sole contact allowance: the selected real seat, within the existing
			# physical margin. Never exempt its whole closure or another foundation.
			if other_id == selected.id and bounds.position.y >= selected.top - Blueprint.PHYSICAL_CONTACT_MARGIN:
				continue
			collisions.append({"partId": id, "foreignPartId": other_id, "overlap": overlap})
			if collisions.size() >= 16:
				break
		if after != part.position:
			changes.append({"partId": id, "before": part.position, "after": after})
		if collisions.size() >= 16:
			break
	if not collisions.is_empty():
		details["collisions"] = collisions
		return _fail("proposed_source_bounds_overlap", details)
	details["translation"] = delta
	details.changes = changes
	details["ready"] = true
	details["reason"] = ""
	details["doesNotProve"] = "Publisher mesh clearance, frame construction on elevated support, access, visuals, physics or navigation. supportId/upstreamIds are for separately reviewed frame-API staging, never permission to promote an elevated foundation to a root."
	return details

static func apply(blueprint, member_ids: Array, additional_obstacles: Array = []) -> Dictionary:
	var result := plan(blueprint, member_ids, additional_obstacles)
	if not result.ready:
		return result
	# No yields or fallible work after planning; preserve source object/recipe
	# identity, array order and every field except the row positions.
	var originals: Dictionary = {}
	for part in blueprint.parts:
		originals[part.id] = part
	for change in result.changes:
		originals[change.partId].position = change.after
	result["applied"] = true
	return result

static func _protected_bounds(blueprint, additional: Array) -> Dictionary:
	if blueprint.rooms.size() > 4096 or additional.size() > 4096:
		return _fail("reservation_limit")
	var obstacles: Array = []
	for room in blueprint.rooms:
		if not room is Dictionary or not room.get("bounds") is AABB or not _bounded(room.bounds) or not room.get("accesses", []) is Array:
			return _fail("invalid_room_reservation")
		if String(room.get("role", "")) != "courtyard":
			obstacles.append({"id": "room:" + String(room.get("id", "")), "bounds": room.bounds})
		for access in room.get("accesses", []):
			if not access is Dictionary or not access.get("position") is Vector3 or not access.get("size") is Vector3:
				return _fail("invalid_access_reservation")
			var bounds: AABB = AABB(access.position - access.size * 0.5, access.size)
			if not _bounded(bounds): return _fail("invalid_access_reservation")
			obstacles.append({"id": "access:" + String(room.get("id", "")) + ":" + String(access.get("id", "")), "bounds": bounds})
			if obstacles.size() > 4096: return _fail("reservation_limit")
	for obstacle in additional:
		if not obstacle is Dictionary or not obstacle.get("id") is String or not obstacle.get("bounds") is AABB or not _bounded(obstacle.bounds):
			return _fail("invalid_external_reservation")
		obstacles.append(obstacle)
	return {"ready": true, "obstacles": obstacles}

static func _lateral_clearance(records: Dictionary, members: Dictionary, support_id: String,
		row: AABB, jambs: Array, rise: Vector3, reservations: Array) -> Dictionary:
	# Translate the ENTIRE row on the SAME proven support, without rotation.
	# Project foreign volumes into forbidden XZ displacement rectangles. The
	# nearest free point lies at zero or a rectangle/domain boundary in Z;
	# each such Z reduces to a bounded union of forbidden X intervals.
	var support: AABB = records[support_id].bounds
	var clearance: float = jambs[0].size.x * 0.5
	var lower := Vector2(support.position.x - row.position.x, support.position.z - row.position.z) + Vector2.ONE * clearance
	var upper := Vector2(support.end.x - row.end.x, support.end.z - row.end.z) - Vector2.ONE * clearance
	if lower.x >= upper.x or lower.y >= upper.y:
		return _fail("row_exceeds_support_clearance")
	var proposed := AABB(row.position + rise, row.size)
	var forbidden: Array = []
	var blockers: Array = []
	for reservation in reservations:
		blockers.append({"id": reservation.id, "bounds": reservation.bounds, "reservation": true})
	var member_volumes: Array = []
	for id in members:
		var bounds: AABB = records[id].bounds
		member_volumes.append({"id": String(id), "bounds": AABB(bounds.position + rise, bounds.size)})
	for id in records:
		if members.has(id) or id == support_id or (not records[id].part.collision_enabled and not bool(records[id].part.recipe.get("visual", true))):
			continue
		blockers.append({"id": String(id), "bounds": records[id].bounds, "reservation": false})
	for blocker in blockers:
		var other: AABB = blocker.bounds
		if other.end.y <= proposed.position.y or other.position.y >= proposed.end.y:
			continue
		# Actual member envelopes retain empty space between awnings/counters;
		# a room/use reservation still protects the complete household volume.
		var volumes: Array = [{"id": "whole_row", "bounds": proposed}] if blocker.reservation else member_volumes
		for volume in volumes:
			var moving: AABB = volume.bounds
			if other.end.y <= moving.position.y or other.position.y >= moving.end.y: continue
			var a := Vector2(other.position.x - moving.end.x, other.position.z - moving.end.z) - Vector2.ONE * clearance
			var z := Vector2(other.end.x - moving.position.x, other.end.z - moving.position.z) + Vector2.ONE * clearance
			if z.x < lower.x or a.x > upper.x or z.y < lower.y or a.y > upper.y: continue
			forbidden.append({"minimum": a, "maximum": z, "partId": String(blocker.id), "memberId": String(volume.id)})
			if forbidden.size() > MAX_LATERAL_OBSTACLES: return _fail("lateral_obstacle_limit")
	var raw_rectangle_count := forbidden.size()
	# Repeated bay/strip geometry produces identical depth intervals. Union
	# overlapping X intervals WITHIN each exact depth pair before the sweep.
	# This is exact set reduction, never rounding or coarsening source geometry.
	var depth_groups: Dictionary = {}
	for rectangle in forbidden:
		var key := Vector2(rectangle.minimum.y, rectangle.maximum.y)
		if not depth_groups.has(key): depth_groups[key] = []
		depth_groups[key].append(rectangle)
	forbidden = []
	for key in depth_groups:
		var group: Array = depth_groups[key]
		group.sort_custom(func(a, b): return a.minimum.x < b.minimum.x if a.minimum.x != b.minimum.x else (a.partId < b.partId if a.partId != b.partId else a.memberId < b.memberId))
		var merged: Dictionary = {}
		for rectangle in group:
			if merged.is_empty() or rectangle.minimum.x > merged.maximum.x:
				if not merged.is_empty(): forbidden.append(merged)
				merged = rectangle.duplicate()
				merged["sourcePairCount"] = 1
			else:
				merged.maximum.x = maxf(merged.maximum.x, rectangle.maximum.x)
				merged.sourcePairCount += 1
		if not merged.is_empty(): forbidden.append(merged)
	forbidden.sort_custom(func(a, b): return a.minimum.x < b.minimum.x if a.minimum.x != b.minimum.x else (a.partId < b.partId if a.partId != b.partId else a.memberId < b.memberId))
	var zs: Array = [lower.y, upper.y, clampf(0.0, lower.y, upper.y)]
	var full_width_depths: Array = []
	for rectangle in forbidden:
		if rectangle.minimum.x < lower.x and rectangle.maximum.x > upper.x:
			full_width_depths.append(Vector2(rectangle.minimum.y, rectangle.maximum.y))
		for value in [rectangle.minimum.y, rectangle.maximum.y]:
			if value >= lower.y and value <= upper.y and not zs.has(value): zs.append(value)
	full_width_depths.sort_custom(func(a, b): return a.x < b.x if a.x != b.x else a.y < b.y)
	var merged_depths: Array = []
	for interval in full_width_depths:
		if merged_depths.is_empty() or interval.x >= merged_depths.back().y:
			merged_depths.append(interval)
		else:
			var last: Vector2 = merged_depths.back()
			last.y = maxf(last.y, interval.y)
			merged_depths[merged_depths.size() - 1] = last
	zs.sort_custom(func(a, b): return absf(a) < absf(b) if absf(a) != absf(b) else a < b)
	var best := Vector2.INF
	var best_distance := INF
	var work := 0
	for depth: float in zs:
		if merged_depths.any(func(interval): return depth > interval.x and depth < interval.y): continue
		# Once a candidate exists, farther depth rows cannot improve it.
		# Use identical represented-vector distance arithmetic; retain ties.
		if Vector2(0, depth).length_squared() > best_distance: continue
		work += forbidden.size()
		if work > 2000000: return _fail("horizontal_work_limit", {"workUnits": work, "rectangleCount": forbidden.size(), "depthRows": zs.size()})
		var cursor := lower.x
		var free: Array = []
		for rectangle in forbidden:
			if depth <= rectangle.minimum.y or depth >= rectangle.maximum.y: continue
			var a: float = maxf(lower.x, rectangle.minimum.x)
			var z: float = minf(upper.x, rectangle.maximum.x)
			if a > cursor: free.append(Vector2(cursor, a))
			cursor = maxf(cursor, z)
		if cursor < upper.x: free.append(Vector2(cursor, upper.x))
		for interval in free:
			var candidate := Vector2(clampf(0.0, interval.x, interval.y), depth)
			var distance := candidate.length_squared()
			if distance < best_distance or (distance == best_distance and (candidate.x < best.x or (candidate.x == best.x and candidate.y < best.y))):
				best = candidate
				best_distance = distance
	if not best.is_finite():
		return _fail("support_footprint_fully_obstructed", {"forbiddenRectangles": forbidden})
	return {"ready": true, "translation": Vector3(best.x, 0, best.y), "clearance": clearance,
		"supportId": support_id, "forbiddenRectangles": forbidden, "workUnits": work, "rawRectangleCount": raw_rectangle_count,
		"method": "Nearest point outside projected visible/collision source volumes and room/access/supplied furnishing reservations, bounded by the existing support footprint. No seed-specific offset or rotation; no access or publisher claim."}

static func _support_closure(blueprint, records: Dictionary, members: Dictionary, support_id: String) -> Dictionary:
	var selected = records[support_id].part
	var footprint: Rect2 = records[support_id].footprint
	var pool := Blueprint.new("elevation_support_context", blueprint.seed, blueprint.style)
	var pool_ids: Array = []
	# Bounded foundation-only context below the selected seat. The physical
	# authority, not this recipe, resolves contacts in these actual source boxes.
	for id in records:
		var part = records[id].part
		if members.has(id) or part.kind != "foundation" or not part.collision_enabled:
			continue
		if id != support_id and (part.position.y >= selected.position.y or not footprint.intersects(records[id].footprint)):
			continue
		pool_ids.append(id)
		if pool_ids.size() > MAX_SUPPORT_CONTEXT:
			return _fail("support_context_limit")
	pool_ids.sort()
	for id in pool_ids:
		var source = records[id].part
		var schema := _support_schema(source, blueprint)
		if not schema.ready:
			return schema
		var copy = pool.add_part(source.snapshot())
		copy.physical_intent = source.physical_intent
		SupportGuards._clear_caches(copy)
	var guard := SupportGuards._validation_grid_guard(pool, "elevation_support_context")
	if not guard.ready:
		return guard
	# Recompute from sanitized geometry. Source physicalRoot/support caches have
	# been erased, and an elevated structural_root declaration was rejected.
	pool.resolve_physical_contracts()
	var pending: Array = [support_id]
	var seen: Dictionary = {}
	var cursor := 0
	while cursor < pending.size():
		var id: String = pending[cursor]
		cursor += 1
		if seen.has(id):
			continue
		if seen.size() >= MAX_SUPPORT_CLOSURE:
			return _fail("support_closure_limit")
		var part = pool.find_part(id)
		if part == null:
			return _fail("missing_support_dependency", {"partId": id})
		seen[id] = true
		for key in ["physicalSupportPartIds", "physicalRequiredSupportPartIds", "physicalRequiredSeatPartIds"]:
			for dependency in part.recipe.get(key, []):
				if not seen.has(dependency) and not pending.has(dependency):
					pending.append(dependency)
	var ids: Array = seen.keys()
	ids.sort()
	var staged := Blueprint.new("elevation_support_closure", blueprint.seed, blueprint.style)
	for id in ids:
		var copy = staged.add_part(records[id].part.snapshot())
		copy.physical_intent = records[id].part.physical_intent
		SupportGuards._clear_caches(copy)
	guard = SupportGuards._validation_grid_guard(staged, "elevation_support_closure")
	if not guard.ready:
		return guard
	var source_records: Array = staged.part_snapshots()
	var validation: Dictionary = staged.validate_physical_integrity()
	var result := {"ready": false, "reason": "invalid_isolated_support_closure", "supportId": support_id,
		"partIds": ids, "records": source_records, "checks": validation.checks, "violations": validation.violations,
		"projectedGridCells": guard.projectedGridCells}
	if validation.checks.size() != ids.size() or not validation.violations.is_empty() or not validation.checks.all(func(check): return bool(check.passed)):
		return result
	for part in staged.parts:
		if staged.is_grounded_structural_root(part):
			continue
		# Require all authority-generated footprint samples to reach real roots,
		# not just the first support ID reachable through one corner.
		if not staged.has_rooted_support_chain(part, {}) or not staged.coverage_has_rooted_supports(part.recipe.get("physicalSupportCoverage", []), 25):
			result.reason = "incomplete_rooted_support_coverage"
			return result
	result.ready = true
	result.reason = ""
	return result

static func _support_schema(part, blueprint) -> Dictionary:
	var recipe_intent: Variant = part.recipe.get("physicalIntent", "")
	if not recipe_intent is String:
		return _fail("unsupported_foundation_contract", {"partId": part.id})
	if part.rotation != Vector3.ZERO or part.physical_intent not in ["", "structural_mass", "structural_root"] or recipe_intent not in ["", "structural_mass", "structural_root"] or (not part.physical_intent.is_empty() and not recipe_intent.is_empty() and part.physical_intent != recipe_intent):
		return _fail("unsupported_foundation_contract", {"partId": part.id})
	if (part.physical_intent == "structural_root" or part.recipe.get("physicalIntent", "") == "structural_root") and not blueprint.is_grounded_structural_root(part):
		return _fail("ungrounded_declared_root", {"partId": part.id})
	for key in part.recipe:
		if not String(key).begins_with("physicalRequired"):
			continue
		if blueprint.is_grounded_structural_root(part) or key not in ["physicalRequiredSupportPartIds", "physicalRequiredSeatPartIds", "physicalRequiredSeatFacts"]:
			return _fail("unsupported_mandatory_support_schema", {"partId": part.id})
	for key in ["physicalRequiredSupportPartIds", "physicalRequiredSeatPartIds"]:
		var dependencies: Variant = part.recipe.get(key, [])
		if not dependencies is Array or dependencies.size() > MAX_SUPPORT_CLOSURE:
			return _fail("invalid_support_dependencies")
		var seen: Dictionary = {}
		for id in dependencies:
			if not id is String or id.is_empty() or id == part.id or seen.has(id):
				return _fail("invalid_support_dependencies")
			seen[id] = true
	var facts: Variant = part.recipe.get("physicalRequiredSeatFacts", [])
	if not facts is Array or facts.size() > MAX_SUPPORT_CLOSURE:
		return _fail("invalid_support_facts")
	for fact in facts:
		if not SupportGuards._seat_schema_valid(fact):
			return _fail("invalid_support_facts")
	return {"ready": true, "reason": ""}

static func _bounded(bounds: AABB) -> bool:
	if not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.end.is_finite():
		return false
	for axis in range(3):
		if bounds.size[axis] <= 0.0 or absf(bounds.position[axis]) > MAX_COORDINATE or absf(bounds.end[axis]) > MAX_COORDINATE:
			return false
	return true

static func _footprint(bounds: AABB) -> Rect2:
	return Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))

static func _fail(reason: String, details: Dictionary = {}) -> Dictionary:
	var result := details.duplicate()
	result["ready"] = false
	result["reason"] = reason
	result["changes"] = []
	return result
