extends RefCounted

## Unwired source recipe. Caller supplies actual producer ownership: one upright
## chimney, its two Z-end gables, and their complete own-house upstream IDs.
## No neighbour discovery, cached-root authority, placement or roof alteration.
## Ordinary unjointed masonry closure only; unsupported declarations fail closed.
## apply() appends one bearer and adds mandatory chimney-seat declarations only.
## Furniture/access boxes are caller-supplied {id: String, bounds: AABB}; an empty
## array proves nothing about separately published furniture absent from source.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Seats = preload("res://scripts/buildings/GabledRoofFrameBuilder.gd")
const MAX_SOURCE := 32768
const MAX_CLOSURE := 32
const MAX_OBSTACLES := 4096
const MAX_GRID_CELLS := 4096
const MAX_COORDINATE := 1000000.0
const LATERAL_CLEARANCE := 0.05
const MIN_LATERAL_PATCH_HALF := 0.06
const CACHE_KEYS := ["physicalRoot", "physicalSupportPartIds", "physicalSupportCoverage", "physicalAnchorPartIds", "physicalIntentResolution"]

static func plan(source, chimney_id: String, gable_ids: Array, upstream_ids: Array, furniture: Array = []) -> Dictionary:
	if source == null or source.parts.size() > MAX_SOURCE or source.rooms.size() > MAX_OBSTACLES or not _id_valid(chimney_id) or gable_ids.size() != 2 or upstream_ids.is_empty() or gable_ids.size() + upstream_ids.size() > MAX_CLOSURE or furniture.size() > MAX_OBSTACLES:
		return _fail("invalid_or_excessive_input")
	var records: Dictionary = {}
	var bounds_by_id: Dictionary = {}
	for part in source.parts:
		if part == null or not _id_valid(part.id) or records.has(part.id): return _fail("invalid_or_duplicate_source_id")
		if not source.has_finite_positive_bounds(part): return _fail("invalid_source_geometry", {"partId": part.id})
		var bounds: AABB = source.transformed_part_bounds(part)
		if not _bounds_valid(bounds): return _fail("unbounded_source_geometry", {"partId": part.id})
		records[part.id] = part
		bounds_by_id[part.id] = bounds
	var obstacles: Array = []
	var obstacle_ids: Dictionary = {}
	for obstacle in furniture:
		if not obstacle is Dictionary or not _id_valid(obstacle.get("id")) or obstacle_ids.has(obstacle.id) or not obstacle.get("bounds") is AABB or not _bounds_valid(obstacle.bounds): return _fail("invalid_furniture_obstacle")
		obstacle_ids[obstacle.id] = true
		obstacles.append({"id": obstacle.id, "bounds": obstacle.bounds})
	var access_count := 0
	for room in source.rooms:
		if not room is Dictionary or not room.get("bounds") is AABB or not _bounds_valid(room.bounds) or not room.get("accesses", []) is Array: return _fail("invalid_room_or_access")
		access_count += room.get("accesses", []).size()
		if access_count > MAX_OBSTACLES: return _fail("excessive_room_accesses")
		if room.get("role", "") != "courtyard": obstacles.append({"id": "room:" + str(room.get("id", "")), "bounds": room.bounds})
		for access in room.get("accesses", []):
			if not access is Dictionary or not access.get("position") is Vector3 or not access.get("size") is Vector3: return _fail("invalid_room_or_access")
			var bounds := AABB(access.position - access.size * 0.5, access.size)
			if not _bounds_valid(bounds): return _fail("invalid_room_or_access")
			obstacles.append({"id": "access:" + str(access.get("id", "")), "bounds": bounds})
	var closure_ids: Array = []
	for id in gable_ids + upstream_ids:
		if not _id_valid(id) or id == chimney_id or closure_ids.has(id) or not records.has(id): return _fail("missing_or_duplicate_closure_member")
		closure_ids.append(id)
	closure_ids.sort()
	if not records.has(chimney_id): return _fail("missing_chimney")
	var chimney = records[chimney_id]
	if chimney.kind != "wall" or chimney.semantic != "citadel_urban_chimney" or chimney.rotation != Vector3.ZERO or not _plain_mass_valid(source, chimney): return _fail("incompatible_chimney")
	var bearer_id := chimney_id + "_bearing"
	if records.has(bearer_id): return _fail("chimney_bearing_already_present")
	var gables: Array = [records[gable_ids[0]], records[gable_ids[1]]]
	gables.sort_custom(func(a, b): return a.position.z < b.position.z if a.position.z != b.position.z else a.id < b.id)
	for gable in gables:
		if gable.kind != "wall" or gable.rotation != Vector3.ZERO or not _plain_mass_valid(source, gable) or gable.size.z >= gable.size.x: return _fail("incompatible_gable")
	var wall_top: float = gables[0].position.y + gables[0].size.y * 0.5
	if wall_top != gables[1].position.y + gables[1].size.y * 0.5: return _fail("gable_tops_differ")
	var bottom: float = chimney.position.y - chimney.size.y * 0.5
	var near_z: float = gables[0].position.z - gables[0].size.z * 0.5
	var far_z: float = gables[1].position.z + gables[1].size.z * 0.5
	if bottom <= wall_top or gables[0].position.z + gables[0].size.z * 0.5 >= chimney.position.z - chimney.size.z * 0.5 or gables[1].position.z - gables[1].size.z * 0.5 <= chimney.position.z + chimney.size.z * 0.5:
		return _fail("no_attic_bearing_span")
	var staged = Blueprint.new(source.id, source.seed, source.style)
	var root_ids: Array = []
	for id in closure_ids:
		var original = records[id]
		if original.kind not in ["wall", "foundation"] or original.rotation != Vector3.ZERO or not _plain_mass_valid(source, original): return _fail("incompatible_support_closure", {"partId": id})
		if source.is_grounded_structural_root(original): root_ids.append(id)
		_copy_clean(staged, original)
	if root_ids.is_empty(): return _fail("no_geometric_ground_root")
	var budget := _validation_budget(staged)
	if not budget.ready: return budget
	var physical: Dictionary = staged.validate_physical_integrity()
	if not _all_pass(physical, closure_ids.size()): return _fail("unproven_source_closure", {"physical": _physical_brief(physical)})
	# Only dependencies freshly resolved inside the explicit own-house closure.
	var reached: Array = gable_ids.duplicate()
	var cursor := 0
	var edges: Dictionary = {}
	for part in staged.parts: edges[part.id] = part.recipe.get("physicalSupportPartIds", []).duplicate()
	while cursor < reached.size():
		for id in edges[reached[cursor]]:
			if not closure_ids.has(id): return _fail("support_outside_declared_closure")
			if not reached.has(id): reached.append(id)
		cursor += 1
	if reached.size() != closure_ids.size(): return _fail("unrelated_support_closure_member")
	var variation: Variant = chimney.recipe.get("variation", 0.0)
	if not (variation is float or variation is int) or not is_finite(variation): return _fail("invalid_chimney_variation")
	var sorted_ids: Array = records.keys()
	sorted_ids.sort()
	obstacles.sort_custom(func(a, b): return a.id < b.id)
	# Preserve the historical two-gable member whenever it is clear. If unrelated
	# geometry crosses that house-wide span, try the two finite chimney-to-gable
	# alternatives in shortest-length/stable-ID order. This changes no chimney,
	# roof, facade or producer placement and never names a seed or blocker.
	var candidates: Array = [{"mode": "two_gable", "centerZ": (near_z + far_z) * 0.5,
		"sizeZ": far_z - near_z, "seatGables": gables}]
	var one_sided: Array = []
	for gable in gables:
		var joint_depth := minf(chimney.size.z, gable.size.z) * 0.5
		var low := minf(chimney.position.z, gable.position.z) - joint_depth
		var high := maxf(chimney.position.z, gable.position.z) + joint_depth
		one_sided.append({"mode": "one_gable", "centerZ": (low + high) * 0.5,
			"sizeZ": high - low, "seatGables": [gable], "stableId": gable.id})
	one_sided.sort_custom(func(a, b): return a.sizeZ < b.sizeZ if a.sizeZ != b.sizeZ else a.stableId < b.stableId)
	candidates.append_array(one_sided)
	var rejected_candidates: Array = []
	for candidate: Dictionary in candidates:
		var lateral_centers := _lateral_centers(chimney, wall_top, bottom, candidate,
			bounds_by_id, sorted_ids, obstacles)
		for center_x: float in lateral_centers:
			var fitted: Dictionary = candidate.duplicate(true)
			fitted["centerX"] = center_x
			var proposal := _candidate(staged, source, chimney, bearer_id, wall_top, bottom,
				variation, fitted, records, bounds_by_id, sorted_ids, obstacles, closure_ids)
			if proposal.ready:
				proposal["chimneyId"] = chimney_id
				proposal["sourceClosureIds"] = closure_ids
				proposal["rootIds"] = root_ids
				proposal["sourceSupportEdges"] = edges
				proposal["furnitureObstacleCount"] = furniture.size()
				proposal["candidateRejections"] = rejected_candidates
				proposal["scope"] = "Source-only own-house gravity seats and clearance; no published-mesh, load-capacity, live visual, access or navigation acceptance."
				return proposal
			rejected_candidates.append({"mode": candidate.mode, "stableId": candidate.get("stableId", ""),
				"offsetX": center_x - chimney.position.x, "reason": proposal.reason,
				"partId": proposal.get("partId", "")})
	return _fail("no_clear_bearing_candidate", {"candidates": rejected_candidates})

static func _candidate(base, source, chimney, bearer_id: String, wall_top: float, bottom: float,
		variation: Variant, spec: Dictionary, records: Dictionary, bounds_by_id: Dictionary,
		sorted_ids: Array, obstacles: Array, closure_ids: Array) -> Dictionary:
	var staged = Blueprint.new(base.id, base.seed, base.style)
	staged.recipe = base.recipe.duplicate(true)
	staged.rooms = base.rooms.duplicate(true)
	for original in base.parts: _copy_clean(staged, original)
	var bearer_size := Vector3(chimney.size.x, bottom - wall_top, float(spec.sizeZ))
	var bearer = staged.add_part({"id": bearer_id, "kind": "beam", "material": "timber_beam",
		"position": Vector3(float(spec.get("centerX", chimney.position.x)), wall_top + (bottom - wall_top) * 0.5, float(spec.centerZ)),
		"size": bearer_size, "rotation": Vector3.ZERO,
		"collision": true, "physicalIntent": "structural_mass", "semantic": "chimney_bearing",
		"recipe": {"variation": variation, "preserveBearingFaces": true, "physicalIntent": "structural_mass", "physicalRequiredSeatPartIds": [], "physicalRequiredSeatFacts": []}})
	if not source.has_finite_positive_bounds(bearer) or bearer.size != bearer_size: return _fail("invalid_bearer_geometry")
	var seat_ids: Array = []
	for gable in spec.seatGables:
		var fact := _bearing_fact(bearer, gable, Vector2(chimney.position.x, gable.position.z))
		if fact.is_empty() or (fact.get("localPatchHalfExtents", Vector2.ZERO) as Vector2).x < MIN_LATERAL_PATCH_HALF: return _fail("insufficient_gable_bearing_patch", {"partId": gable.id})
		seat_ids.append(gable.id)
		bearer.recipe.physicalRequiredSeatPartIds.append(gable.id)
		bearer.recipe.physicalRequiredSeatFacts.append(fact)
	var chimney_copy = _copy_clean(staged, chimney)
	var chimney_fact := _bearing_fact(chimney_copy, bearer, Vector2(chimney.position.x, chimney.position.z))
	if chimney_fact.is_empty() or (chimney_fact.get("localPatchHalfExtents", Vector2.ZERO) as Vector2).x < MIN_LATERAL_PATCH_HALF: return _fail("insufficient_chimney_bearing_patch")
	chimney_copy.recipe["physicalRequiredSeatPartIds"] = [bearer_id]
	chimney_copy.recipe["physicalRequiredSeatFacts"] = [chimney_fact]
	var bearer_bounds: AABB = source.transformed_part_bounds(bearer)
	if not _bounds_valid(bearer_bounds): return _fail("invalid_bearer_geometry")
	for id in sorted_ids:
		# Exempt only the actual candidate joints; the unused own gable remains
		# ordinary source occupancy for a one-sided member.
		if id == chimney.id or seat_ids.has(id): continue
		if bearer_bounds.intersects(bounds_by_id[id]) and source.transformed_boxes_intersect(bearer, records[id], 0.0):
			return _fail("bearer_intrudes_source", {"partId": id, "bounds": bounds_by_id[id]})
	for obstacle in obstacles:
		if bearer_bounds.intersects(obstacle.bounds):
			return _fail("bearer_intrudes_protected_space", {"partId": obstacle.id, "bounds": obstacle.bounds})
	var budget := _validation_budget(staged)
	if not budget.ready: return budget
	var physical: Dictionary = staged.validate_physical_integrity()
	if not _all_pass(physical, closure_ids.size() + 2): return _fail("unproven_chimney_bearing", {"physical": _physical_brief(physical)})
	for part in [bearer, chimney_copy]:
		for fact in part.recipe.physicalRequiredSeatFacts:
			if not staged.has_rooted_bearer_seat(part, fact): return _fail("mandatory_bearing_seat_failed", {"partId": part.id})
	for key in CACHE_KEYS: bearer.recipe.erase(key)
	var chimney_recipe: Dictionary = chimney.recipe.duplicate(true)
	chimney_recipe["physicalRequiredSeatPartIds"] = [bearer_id]
	chimney_recipe["physicalRequiredSeatFacts"] = [chimney_fact]
	return {"ready": true, "reason": "", "partIds": [bearer_id],
		"bearerRecord": bearer.snapshot(), "chimneyRecipe": chimney_recipe,
		"bearingMode": spec.mode, "bearingGableIds": seat_ids,
		"bearingOffsetX": bearer.position.x - chimney.position.x,
		"physical": _physical_brief(physical), "validationGridCells": budget.cells,
		"bearerBounds": bearer_bounds}

static func apply(source, chimney_id: String, gable_ids: Array, upstream_ids: Array, furniture: Array = []) -> Dictionary:
	var result := plan(source, chimney_id, gable_ids, upstream_ids, furniture)
	if not result.ready: return result
	# No fallible operation follows the complete proposal. Keep every original
	# object and field except the chimney's two added mandatory-seat fields.
	var chimney = _find(source, chimney_id)
	source.add_part(result.bearerRecord)
	chimney.recipe = result.chimneyRecipe.duplicate(true)
	return result

static func _bearing_fact(bearer, seat, world_xz: Vector2) -> Dictionary:
	var margin := Blueprint.PHYSICAL_CONTACT_MARGIN
	var center := Vector2(bearer.position.x, bearer.position.z)
	var seat_center := Vector2(seat.position.x, seat.position.z)
	var bearer_available := Vector2(bearer.size.x, bearer.size.z) * 0.5 - (world_xz - center).abs() - Vector2.ONE * margin
	var seat_available := Vector2(seat.size.x, seat.size.z) * 0.5 - (world_xz - seat_center).abs() - Vector2.ONE * margin
	var half := bearer_available.min(seat_available) * 0.5
	if not half.is_finite() or half.x <= 0.0 or half.y <= 0.0: return {}
	return Seats.world_down_seat_fact(seat.id, Vector3(world_xz.x - bearer.position.x, -bearer.size.y * 0.5, world_xz.y - bearer.position.z), half)

static func _lateral_centers(chimney, wall_top: float, bottom: float, spec: Dictionary,
		bounds_by_id: Dictionary, sorted_ids: Array, obstacles: Array) -> Array:
	var half_x: float = chimney.size.x * 0.5
	var center_z := float(spec.centerZ)
	var half_z := float(spec.sizeZ) * 0.5
	var y_low := wall_top
	var y_high := bottom
	var z_low := center_z - half_z
	var z_high := center_z + half_z
	var centers: Array = [chimney.position.x]
	for id: String in sorted_ids:
		var bounds: AABB = bounds_by_id[id]
		if bounds.end.y <= y_low or bounds.position.y >= y_high or bounds.end.z <= z_low or bounds.position.z >= z_high: continue
		centers.append(bounds.position.x - half_x - LATERAL_CLEARANCE)
		centers.append(bounds.end.x + half_x + LATERAL_CLEARANCE)
	for obstacle: Dictionary in obstacles:
		var bounds: AABB = obstacle.bounds
		if bounds.end.y <= y_low or bounds.position.y >= y_high or bounds.end.z <= z_low or bounds.position.z >= z_high: continue
		centers.append(bounds.position.x - half_x - LATERAL_CLEARANCE)
		centers.append(bounds.end.x + half_x + LATERAL_CLEARANCE)
	var max_offset: float = half_x - LATERAL_CLEARANCE - MIN_LATERAL_PATCH_HALF * 2.0
	var unique: Dictionary = {}
	var accepted: Array = []
	for value in centers:
		var center_x := float(value)
		if not is_finite(center_x) or absf(center_x - chimney.position.x) > max_offset + 0.000001: continue
		var key := snappedf(center_x, 0.000001)
		if unique.has(key): continue
		unique[key] = true
		accepted.append(center_x)
	accepted.sort_custom(func(a, b):
		var da := absf(float(a) - chimney.position.x)
		var db := absf(float(b) - chimney.position.x)
		return da < db if da != db else float(a) < float(b))
	return accepted

static func _plain_mass_valid(source, part) -> bool:
	if not part.collision_enabled: return false
	var intent: Variant = part.recipe.get("physicalIntent", "")
	if not intent is String or part.physical_intent not in ["", "structural_mass", "structural_root"] or intent not in ["", "structural_mass", "structural_root"] or (part.physical_intent != "" and intent != "" and part.physical_intent != intent): return false
	var flag: Variant = part.recipe.get("physicalRoot", false)
	if not flag is bool: return false
	if (flag or part.physical_intent == "structural_root" or intent == "structural_root") and not source.is_grounded_structural_root(part): return false
	for key in part.recipe:
		if String(key).begins_with("physicalRequired") or key == "physicalAssemblyRole": return false
	return true

static func _copy_clean(target, original):
	var copy = target.add_part(original.snapshot())
	copy.physical_intent = original.physical_intent
	copy.size = original.size
	for key in CACHE_KEYS: copy.recipe.erase(key)
	return copy

static func _validation_budget(b) -> Dictionary:
	var total := 0.0
	for part in b.parts:
		var bounds: AABB = b.transformed_part_bounds(part).grow(Blueprint.PHYSICAL_CONTACT_MARGIN * sqrt(3.0))
		if not _bounds_valid(bounds): return _fail("invalid_validation_bounds")
		var low := Vector2(floorf(bounds.position.x / Blueprint.PHYSICAL_SUPPORT_GRID_CELL), floorf(bounds.position.z / Blueprint.PHYSICAL_SUPPORT_GRID_CELL))
		var high := Vector2(floorf(bounds.end.x / Blueprint.PHYSICAL_SUPPORT_GRID_CELL), floorf(bounds.end.z / Blueprint.PHYSICAL_SUPPORT_GRID_CELL))
		var span := high - low + Vector2.ONE
		if not span.is_finite() or span.x < 1 or span.y < 1 or span.x > MAX_GRID_CELLS or span.y > MAX_GRID_CELLS: return _fail("validation_grid_limit")
		total += span.x * span.y
		if total > MAX_GRID_CELLS: return _fail("validation_grid_limit")
	return {"ready": true, "cells": total}

static func _bounds_valid(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() and bounds.end.is_finite() and bounds.size.x > 0 and bounds.size.y > 0 and bounds.size.z > 0 and bounds.position.length() <= MAX_COORDINATE and bounds.end.length() <= MAX_COORDINATE

static func _all_pass(report: Dictionary, count: int) -> bool:
	return report.checks.size() == count and report.violations.is_empty() and report.checks.all(func(check): return bool(check.passed))

static func _physical_brief(report: Dictionary) -> Dictionary:
	return {"passed": report.passed, "violations": report.violations.duplicate(),
		"checks": report.checks.map(func(check): return {"partId": check.partId, "passed": check.passed, "supportPartIds": check.get("supportPartIds", []), "requiredSeatPartIds": check.get("requiredSeatPartIds", []), "reachesGroundRoot": check.get("reachesGroundRoot", false)})}

static func _id_valid(id: Variant) -> bool:
	return id is String and not id.is_empty() and id == id.strip_edges() and id.length() <= 256

static func _find(b, id: String):
	for part in b.parts:
		if part.id == id: return part
	return null

static func _fail(reason: String, detail: Dictionary = {}) -> Dictionary:
	var result := detail.duplicate()
	result["ready"] = false
	result["reason"] = reason
	return result
