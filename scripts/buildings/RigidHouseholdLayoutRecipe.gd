extends RefCounted

## Pure deterministic recipe planning. Never moves records, publishes geometry,
## consults a seed-specific table, or makes a navigation/readiness claim.
## Inputs are the producer's complete household and authoritative paving IDs.
## This synchronous entry point is for recipe construction, not gameplay frames.
const MAX_PARTS := 50000
const MAX_SURFACES := 64
const MAX_CANDIDATES := 500000
const MAX_COLLECTION := 4096
const MAX_WORK := 5000000
const SPATIAL_INDEX_CELL_SIZE := 4.0

static func plan(blueprint, member_ids: Array, policy: Dictionary) -> Dictionary:
	var started := Time.get_ticks_usec()
	if blueprint == null or member_ids.is_empty() or blueprint.parts.size() > MAX_PARTS:
		return _failure("invalid_or_oversized_source")
	if member_ids.size() > MAX_COLLECTION or blueprint.rooms.size() > MAX_COLLECTION:
		return _failure("collection_limit_exceeded")
	for key in ["searchRadius", "clearance", "circulation", "approachLength", "approachWidth", "approachHeight", "gridStep"]:
		if policy.has(key) and not (policy[key] is int or policy[key] is float):
			return _failure("invalid_layout_policy_type")
	if not policy.get("front", Vector3.FORWARD) is Vector3 or not policy.get("pavingPartIds", []) is Array or not policy.get("reservedFootprints", []) is Array:
		return _failure("invalid_layout_policy_type")
	var radius := float(policy.get("searchRadius", 25.0))
	var spacing := float(policy.get("clearance", 0.1))
	var circulation := float(policy.get("circulation", 0.8))
	var approach_length := float(policy.get("approachLength", 3.8))
	var approach_width := float(policy.get("approachWidth", 1.8))
	var approach_height := float(policy.get("approachHeight", 2.0))
	var step := float(policy.get("gridStep", 0.25))
	var front: Vector3 = policy.get("front", Vector3.FORWARD)
	for value in [radius, spacing, circulation, approach_length, approach_width, approach_height, step]:
		if not is_finite(value) or value <= 0.0:
			return _failure("invalid_layout_policy")
	if not front.is_finite() or front.y != 0.0 or absf(front.x) + absf(front.z) != 1.0 or front.length_squared() != 1.0:
		return _failure("front_must_be_cardinal")
	var members: Dictionary = {}
	for id in member_ids:
		if not id is String or id.is_empty() or members.has(id):
			return _failure("invalid_or_duplicate_member")
		members[id] = true
	var ordered_member_ids: Array = members.keys()
	ordered_member_ids.sort()
	var records: Dictionary = {}
	var member_bounds := AABB()
	var first := true
	for part in blueprint.parts:
		if part == null or records.has(part.id) or String(part.id).is_empty() or not _valid_part(part):
			return _failure("invalid_or_duplicate_part")
		var bounds := _bounds(Transform3D(Basis.from_euler(part.rotation), part.position), part.size)
		if not _valid_bounds(bounds):
			return _failure("invalid_transformed_part_bounds")
		records[part.id] = {"part": part, "bounds": bounds, "xz": _xz(bounds)}
	for member_id in ordered_member_ids:
		if not records.has(member_id): return _failure("missing_household_members")
		var record: Dictionary = records[member_id]
		if not _surface_detail(record.part):
			member_bounds = record.bounds if first else member_bounds.merge(record.bounds)
			first = false
	if first or not members.keys().all(func(id): return records.has(id)):
		return _failure("missing_household_members")
	var pivot := Vector3(member_bounds.get_center().x, member_bounds.position.y, member_bounds.get_center().z)
	var height := member_bounds.size.y
	var old_center := Vector2(pivot.x, pivot.z)
	# A continuous city platform can be much larger than this household's search
	# radius. Only geometry capable of reaching a candidate footprint or its
	# approach can affect the result. This conservative envelope includes the
	# furthest translated member extent, circulation, and full approach length;
	# it changes no candidate or collision rule, but avoids repeatedly scanning
	# unrelated buildings across the rest of the same physical paving part.
	var member_half_span := maxf(member_bounds.size.x, member_bounds.size.z) * 0.5
	var influence_margin := radius + member_half_span + maxf(circulation, approach_length) + spacing + 1.25
	var candidate_influence := Rect2(old_center - Vector2.ONE * influence_margin, Vector2.ONE * influence_margin * 2.0)
	var rooms: Array[Rect2] = []
	var access_count := 0
	for room in blueprint.rooms:
		if not room is Dictionary or not room.get("bounds") is AABB:
			return _failure("invalid_room_bounds")
		if not _valid_bounds(room.bounds) or not room.get("accesses", []) is Array:
			return _failure("invalid_room_bounds")
		if String(room.get("role", "")) != "courtyard":
			var room_rect := _xz(room.bounds)
			if room_rect.intersects(candidate_influence):
				rooms.append(room_rect)
		access_count += room.get("accesses", []).size()
		if access_count > MAX_COLLECTION:
			return _failure("collection_limit_exceeded")
		for access in room.get("accesses", []):
			if not access is Dictionary or not access.get("position") is Vector3 or not access.get("size") is Vector3:
				return _failure("invalid_room_access")
			var access_bounds := AABB(access.position - access.size * 0.5, access.size)
			if not _valid_bounds(access_bounds):
				return _failure("invalid_room_access")
			var access_rect := _xz(access_bounds)
			if access_rect.intersects(candidate_influence):
				rooms.append(access_rect)
	var reservations: Array[Rect2] = []
	if policy.get("reservedFootprints", []).size() > MAX_COLLECTION:
		return _failure("collection_limit_exceeded")
	for rect in policy.get("reservedFootprints", []):
		if not rect is Rect2 or not _valid_rect(rect):
			return _failure("invalid_reserved_footprint")
		reservations.append(rect)
	var surface_ids: Array = policy.get("pavingPartIds", []).duplicate()
	if surface_ids.is_empty() or surface_ids.size() > MAX_SURFACES:
		return _failure("invalid_or_oversized_paving_collection")
	var unique_surfaces: Dictionary = {}
	for id in surface_ids:
		if not id is String or not records.has(id) or unique_surfaces.has(id):
			return _failure("missing_or_duplicate_paving")
		unique_surfaces[id] = true
		var part = records[id].part
		if not part.collision_enabled or part.rotation != Vector3.ZERO or members.has(id):
			return _failure("paving_must_be_axis_aligned_collision_source")
	surface_ids.sort()
	var best: Dictionary = {}
	var visited := 0
	var eligible := 0
	# Charge upper bounds before loops; resource exhaustion is not no-fit.
	var work := records.size() + rooms.size() + reservations.size()
	for id in surface_ids:
		work += records.size() + rooms.size() + reservations.size() + members.size() * 4
		if work > MAX_WORK:
			return _failure("work_limit_exceeded")
		var surface: Dictionary = records[id]
		var allowed: Rect2 = (surface.xz as Rect2).grow(-spacing)
		if not _valid_rect(allowed):
			continue
		var floor_y: float = surface.bounds.end.y
		var solid: Array[Rect2] = []
		var low: Array[Rect2] = []
		var approach_obstacles: Array[Rect2] = []
		var fixed: Array[Rect2] = []
		for rect in reservations + rooms:
			if rect.intersects(allowed) and rect.intersects(candidate_influence):
				fixed.append(rect)
		for other_id in records:
			if members.has(other_id) or other_id == id:
				continue
			var other: Dictionary = records[other_id]
			var part = other.part
			if _surface_detail(part):
				continue
			var bounds: AABB = other.bounds
			var rect: Rect2 = other.xz
			if not rect.grow(maxf(1.25, circulation)).intersects(candidate_influence):
				continue
			if part.kind == "door" or part.kind == "stair_tread" or part.kind == "ramp":
				fixed.append(rect.grow(1.25 if part.kind == "door" else circulation))
			if bounds.end.y > floor_y and bounds.position.y < floor_y + height:
				solid.append(rect.grow(spacing))
			if bounds.end.y > floor_y and bounds.position.y < floor_y + approach_height:
				approach_obstacles.append(rect.grow(spacing))
			if bounds.end.y > floor_y + 0.1 and bounds.position.y < floor_y + 2.0:
				low.append(rect)
		# The candidate lattice can be dense while the Citadel source contains
		# thousands of distant collision rectangles. Index each immutable obstacle
		# collection once per paving source; every query still uses Rect2.intersects
		# on the original records, so this only eliminates proven-disjoint work.
		var index_meter := {"used": 0, "remaining": MAX_WORK - work}
		var solid_index := _spatial_index(solid, candidate_influence, index_meter)
		var fixed_index := _spatial_index(fixed, candidate_influence, index_meter)
		var approach_index := _spatial_index(approach_obstacles, candidate_influence, index_meter)
		var low_index := _spatial_index(low, candidate_influence, index_meter)
		work += int(index_meter.used)
		if work > MAX_WORK or [solid_index, fixed_index, approach_index, low_index].any(func(index): return not bool(index.get("ready", false))):
			return {"ready": false, "reason": "work_limit_exceeded", "visitedCandidates": visited,
				"eligibleImprovements": eligible, "workUpperBound": work}
		for quarter in range(4):
			var turn := _quarter_turn(quarter)
			var rotated := AABB()
			first = true
			for member_id in ordered_member_ids:
				var part = records[member_id].part
				if _surface_detail(part):
					continue
				var transform := Transform3D(turn, -(turn * pivot)) * Transform3D(Basis.from_euler(part.rotation), part.position)
				var bounds := _bounds(transform, part.size)
				rotated = bounds if first else rotated.merge(bounds)
				first = false
			var size := _xz(rotated).size
			var half := size * 0.5
			var minimum := (allowed.position + half).max(old_center - Vector2.ONE * radius)
			var maximum := (allowed.end - half).min(old_center + Vector2.ONE * radius)
			if maximum.x < minimum.x or maximum.y < minimum.y:
				continue
			# Bound floating counts BEFORE converting to integer or multiplying.
			# A positive but tiny grid step must fail explicitly, never overflow
			# the integer limit guard or accidentally become an empty search.
			var x_count := floorf((maximum.x - minimum.x) / step) + 1.0
			var z_count := floorf((maximum.y - minimum.y) / step) + 1.0
			if not is_finite(x_count) or not is_finite(z_count) or x_count > MAX_CANDIDATES or z_count > MAX_CANDIDATES:
				return _failure("candidate_limit_exceeded")
			var nx := int(x_count)
			var nz := int(z_count)
			var nearest_x := clampi(roundi((old_center.x - minimum.x) / step), 0, nx - 1)
			var nearest_z := clampi(roundi((old_center.y - minimum.y) / step), 0, nz - 1)
			var direction := turn * front
			# Nearest-first grid traversal finds a useful bound early. Rows
			# strictly farther than the best complete placement cannot win.
			# Keep the same grid and explicit tie rule; no coarsening or cap rise.
			for x_order in range(nx * 2):
				work += 1
				if work > MAX_WORK:
					return _failure("work_limit_exceeded")
				var ix := _grid_index(nearest_x, x_order)
				if ix < 0 or ix >= nx:
					continue
				# Match BOTH candidate coordinate construction and vector distance
				# arithmetic below. A scalar-double square can exceed the rounded
				# float32 candidate rank and wrongly prune a preferred equal-distance
				# row (including elevation-only rounding). Zero Z displacement gives
				# a conservative rank bound; adding the candidate's nonnegative Z
				# square cannot decrease it. Keep equal ranks for the existing tie rule.
				var row_center := minimum + Vector2(ix, 0) * step
				var row_target := Vector3(row_center.x, floor_y, pivot.z)
				var row_distance := row_target.distance_squared_to(pivot)
				if not best.is_empty() and row_distance > float(best.distanceSquared):
					continue
				for z_order in range(nz * 2):
					work += 1
					if work > MAX_WORK:
						return _failure("work_limit_exceeded")
					var iz := _grid_index(nearest_z, z_order)
					if iz < 0 or iz >= nz:
						continue
					visited += 1
					if visited > MAX_CANDIDATES:
						return _failure("candidate_limit_exceeded")
					work += 1
					if work > MAX_WORK:
						return _failure("work_limit_exceeded")
					var center := minimum + Vector2(ix, iz) * step
					var target := Vector3(center.x, floor_y, center.y)
					var horizontal := center.distance_squared_to(old_center)
					var distance := target.distance_squared_to(pivot)
					if horizontal > radius * radius or not _preferred(distance, id, quarter, center, best):
						continue
					var area := Rect2(center - half, size)
					var approach := _approach(area, direction, approach_length, approach_width)
					var circulation_area := area.grow(circulation)
					# Whole rectangles, not samples: no unsupported corner, hidden
					# courtyard-interior placement or omitted front-use corridor.
					if not allowed.encloses(circulation_area) or not allowed.encloses(approach):
						continue
					var meter := {"used": 0, "remaining": MAX_WORK - work}
					var blocked := _intersects_any(area, _spatial_candidates(solid_index, area, meter), meter) or _intersects_any(area, _spatial_candidates(fixed_index, area, meter), meter) or _intersects_any(approach, _spatial_candidates(approach_index, approach, meter), meter) or _intersects_any(approach, _spatial_candidates(fixed_index, approach, meter), meter) or _intersects_any(circulation_area, _spatial_candidates(fixed_index, circulation_area, meter), meter) or _intersects_any(circulation_area, _spatial_candidates(low_index, circulation_area, meter), meter)
					work += int(meter.used)
					if work > MAX_WORK:
						return {"ready": false, "reason": "work_limit_exceeded", "visitedCandidates": visited,
							"eligibleImprovements": eligible, "workUpperBound": work}
					if blocked:
						continue
					eligible += 1
					# Pivot is the original complete household's standing datum.
					# Compensate rotated AABB centre rather than shifting its contents.
					var offset := Vector3(rotated.get_center().x, 0.0, rotated.get_center().z)
					var transform := Transform3D(turn, target - offset - turn * pivot)
					# Certify the represented geometry callers will actually store.
					# Translating a rounded local AABB is not bit-identical to
					# transforming each part and storing its Euler/position fields.
					# Pay this cost only for otherwise eligible improvements.
					var represented_min := Vector2(INF, INF)
					var represented_max := Vector2(-INF, -INF)
					for member_id in ordered_member_ids:
						work += 1
						if work > MAX_WORK:
							return _failure("work_limit_exceeded")
						var part = records[member_id].part
						if _surface_detail(part): continue
						var pose: Transform3D = transform * Transform3D(Basis.from_euler(part.rotation), part.position)
						var stored := Transform3D(Basis.from_euler(pose.basis.get_euler()), pose.origin)
						var bounds := _bounds(stored, part.size)
						var endpoints := _represented_part_endpoints(stored, part.size, bounds)
						represented_min = represented_min.min(endpoints[0])
						represented_max = represented_max.max(endpoints[1])
					area = _represented_rect(represented_min, represented_max)
					approach = _approach(area, direction, approach_length, approach_width)
					circulation_area = area.grow(circulation)
					if not allowed.encloses(circulation_area) or not allowed.encloses(approach): continue
					meter = {"used": 0, "remaining": MAX_WORK - work}
					blocked = _intersects_any(area, _spatial_candidates(solid_index, area, meter), meter) or _intersects_any(area, _spatial_candidates(fixed_index, area, meter), meter) or _intersects_any(approach, _spatial_candidates(approach_index, approach, meter), meter) or _intersects_any(approach, _spatial_candidates(fixed_index, approach, meter), meter) or _intersects_any(circulation_area, _spatial_candidates(fixed_index, circulation_area, meter), meter) or _intersects_any(circulation_area, _spatial_candidates(low_index, circulation_area, meter), meter)
					work += int(meter.used)
					if work > MAX_WORK: return _failure("work_limit_exceeded")
					if blocked: continue
					best = {"ready": true, "reason": "", "transform": transform,
						"supportId": id, "footprint": area, "approach": approach, "circulationFootprint": circulation_area,
						"quarterTurn": quarter, "distanceSquared": distance, "pivot": pivot,
						"standingY": floor_y, "layoutCenter": center, "memberIds": member_ids.duplicate()}
	if best.is_empty():
		best = _failure("no_recipe_placement")
	best["visitedCandidates"] = visited
	best["eligibleImprovements"] = eligible
	best["elapsedUsec"] = Time.get_ticks_usec() - started
	best["workUpperBound"] = work
	best["tiePolicy"] = "distance_then_sorted_surface_id_then_quarter_turn_then_grid_x_z"
	return best

static func _grid_index(nearest: int, order: int) -> int:
	var offset := (order + 1) >> 1
	return nearest + (-offset if order % 2 == 1 else offset)

static func _represented_part_endpoints(stored: Transform3D, size: Vector3, expanded_bounds: AABB) -> Array[Vector2]:
	# The existing eight-corner pass also supplies Blueprint's min/max AABB
	# reconstruction. Its represented end can exceed both the actual corner and
	# the incremental _bounds().end; keep all three without another corner pass.
	var corner_min := Vector2(INF, INF)
	var corner_max := Vector2(-INF, -INF)
	for x in [-0.5, 0.5]:
		for y in [-0.5, 0.5]:
			for z in [-0.5, 0.5]:
				var corner: Vector3 = stored * (size * Vector3(x, y, z))
				corner_min = corner_min.min(Vector2(corner.x, corner.z))
				corner_max = corner_max.max(Vector2(corner.x, corner.z))
	var reconstructed_end := corner_min + (corner_max - corner_min)
	return [corner_min.min(Vector2(expanded_bounds.position.x, expanded_bounds.position.z)),
		corner_max.max(reconstructed_end).max(Vector2(expanded_bounds.end.x, expanded_bounds.end.z))]

static func _represented_rect(minimum: Vector2, maximum: Vector2) -> Rect2:
	var extent := maximum - minimum
	# Rect2 stores origin+size, not two endpoints. Round size outward when
	# subtraction/storage would reconstruct an end below an observed corner.
	# This is representational rounding, not a geometric clearance allowance.
	for axis in range(2):
		if float(minimum[axis]) + float(extent[axis]) < float(maximum[axis]) or (minimum + extent)[axis] < maximum[axis]:
			var bytes := PackedByteArray()
			bytes.resize(4)
			bytes.encode_float(0, extent[axis])
			bytes.encode_u32(0, bytes.decode_u32(0) + 1)
			extent[axis] = bytes.decode_float(0)
	return Rect2(minimum, extent)

static func _preferred(distance: float, id: String, quarter: int, center: Vector2, best: Dictionary) -> bool:
	if best.is_empty() or distance < float(best.distanceSquared):
		return true
	if distance > float(best.distanceSquared):
		return false
	if id != String(best.supportId):
		return id < String(best.supportId)
	if quarter != int(best.quarterTurn):
		return quarter < int(best.quarterTurn)
	var previous: Vector2 = best.layoutCenter
	return center.x < previous.x or center.x == previous.x and center.y < previous.y

static func _quarter_turn(quarter: int) -> Basis:
	# Exact cardinal matrices avoid sin(PI) noise affecting tie-breaking.
	match quarter:
		1: return Basis(Vector3(0, 0, -1), Vector3.UP, Vector3(1, 0, 0))
		2: return Basis(Vector3(-1, 0, 0), Vector3.UP, Vector3(0, 0, -1))
		3: return Basis(Vector3(0, 0, 1), Vector3.UP, Vector3(-1, 0, 0))
	return Basis.IDENTITY

static func _approach(area: Rect2, direction: Vector3, length: float, width: float) -> Rect2:
	var heading := Vector2(direction.x, direction.z)
	var edge := area.get_center() + heading * (area.size.x * 0.5 if heading.x != 0 else area.size.y * 0.5)
	var size := Vector2(length, width) if heading.x != 0 else Vector2(width, length)
	return Rect2(edge + heading * length * 0.5 - size * 0.5, size)

static func _intersects_any(area: Rect2, obstacles: Array[Rect2], meter: Dictionary) -> bool:
	for rect in obstacles:
		meter.used += 1
		if int(meter.used) > int(meter.remaining):
			return true
		if area.intersects(rect):
			return true
	return false

static func _spatial_index(rectangles: Array[Rect2], influence: Rect2, meter: Dictionary) -> Dictionary:
	# The planner examines many nearby grid positions against a stable, usually
	# large set of recipe envelopes.  Indexing only chooses which provably
	# non-disjoint envelopes reach the exact Rect2 test below; it does not change
	# footprint, clearance, ordering, or the deterministic tie policy.
	var cells := {}
	for rect_index in range(rectangles.size()):
		if not _charge_meter(meter, 1.0):
			return {"ready": false, "reason": "work_limit_exceeded"}
		var rect := rectangles[rect_index].intersection(influence)
		if not _valid_rect(rect):
			continue
		var minimum_x := floori(rect.position.x / SPATIAL_INDEX_CELL_SIZE)
		var maximum_x := floori(rect.end.x / SPATIAL_INDEX_CELL_SIZE)
		var minimum_z := floori(rect.position.y / SPATIAL_INDEX_CELL_SIZE)
		var maximum_z := floori(rect.end.y / SPATIAL_INDEX_CELL_SIZE)
		var cell_count := float(maximum_x - minimum_x + 1) * float(maximum_z - minimum_z + 1)
		# Reserve the complete membership loop before allocating any cells. A huge
		# but finite source rectangle therefore fails under the ordinary work limit
		# instead of creating an unbounded dictionary first.
		if not _charge_meter(meter, cell_count):
			return {"ready": false, "reason": "work_limit_exceeded"}
		for cell_x in range(minimum_x, maximum_x + 1):
			for cell_z in range(minimum_z, maximum_z + 1):
				var key := Vector2i(cell_x, cell_z)
				if not cells.has(key):
					cells[key] = []
				cells[key].append(rect_index)
	return {"ready": true, "rectangles": rectangles, "cells": cells}

static func _spatial_candidates(index: Dictionary, area: Rect2, meter: Dictionary) -> Array[Rect2]:
	if not bool(index.get("ready", false)) or not _valid_rect(area):
		return []
	var rectangles: Array[Rect2] = index.get("rectangles", [])
	var cells: Dictionary = index.get("cells", {})
	var seen := {}
	var minimum_x := floori(area.position.x / SPATIAL_INDEX_CELL_SIZE)
	var maximum_x := floori(area.end.x / SPATIAL_INDEX_CELL_SIZE)
	var minimum_z := floori(area.position.y / SPATIAL_INDEX_CELL_SIZE)
	var maximum_z := floori(area.end.y / SPATIAL_INDEX_CELL_SIZE)
	var cell_count := float(maximum_x - minimum_x + 1) * float(maximum_z - minimum_z + 1)
	if not _charge_meter(meter, cell_count):
		return []
	for cell_x in range(minimum_x, maximum_x + 1):
		for cell_z in range(minimum_z, maximum_z + 1):
			for rect_index in cells.get(Vector2i(cell_x, cell_z), []):
				if not _charge_meter(meter, 1.0):
					return []
				seen[rect_index] = true
	var ordered_indices: Array = seen.keys()
	var sort_work := float(ordered_indices.size()) * maxf(1.0, ceil(log(float(ordered_indices.size()) + 1.0) / log(2.0)))
	if not _charge_meter(meter, sort_work):
		return []
	ordered_indices.sort()
	var candidates: Array[Rect2] = []
	for rect_index in ordered_indices:
		if not _charge_meter(meter, 1.0):
			return []
		var rect := rectangles[int(rect_index)]
		# Rect2.intersects is still the authoritative exact predicate.  The
		# cell membership merely avoids checking envelopes that cannot overlap.
		if rect.intersects(area):
			candidates.append(rect)
	return candidates


static func _charge_meter(meter: Dictionary, amount: float) -> bool:
	var remaining := int(meter.get("remaining", 0))
	var used := int(meter.get("used", 0))
	if not is_finite(amount) or amount < 0.0 or amount > float(remaining - used):
		meter["used"] = remaining + 1
		meter["exhausted"] = true
		return false
	meter["used"] = used + int(amount)
	return true

static func _bounds(transform: Transform3D, size: Vector3) -> AABB:
	var half := size * 0.5
	var bounds := AABB(transform * -half, Vector3.ZERO)
	for x in [-1.0, 1.0]:
		for y in [-1.0, 1.0]:
			for z in [-1.0, 1.0]:
				bounds = bounds.expand(transform * Vector3(x * half.x, y * half.y, z * half.z))
	return bounds

static func _xz(bounds: AABB) -> Rect2:
	return Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))

static func _valid_part(part) -> bool:
	return part.position.is_finite() and part.rotation.is_finite() and part.size.is_finite() and part.size.x > 0 and part.size.y > 0 and part.size.z > 0

static func _valid_rect(rect: Rect2) -> bool:
	return rect.position.is_finite() and rect.end.is_finite() and rect.size.x > 0 and rect.size.y > 0

static func _valid_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.end.is_finite() and bounds.size.x > 0 and bounds.size.y > 0 and bounds.size.z > 0

static func _surface_detail(part) -> bool:
	return not part.collision_enabled and (part.kind == "ground_patch" or String(part.semantic).contains("wear") or String(part.semantic).contains("compaction"))

static func _failure(reason: String) -> Dictionary:
	return {"ready": false, "reason": reason}
