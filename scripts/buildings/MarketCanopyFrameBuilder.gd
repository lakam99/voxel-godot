extends RefCounted

## Unwired, source-only canopy joinery. No placement, publication or navigation.
## Existing household records keep their geometry/render recipe. Only the five
## attachments gain mandatory sockets; ten new structural members are appended.
## Supply an actual horizontal structural seat, either grounded or with a complete
## explicit required-support/seat chain. Inferred neighbour support is NOT an input.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Seats = preload("res://scripts/buildings/GabledRoofFrameBuilder.gd")
const MAX_SOURCE_PARTS := 32768
const MAX_MEMBERS := 128
const MAX_SUPPORT_PARTS := 32
const MAX_VALIDATION_GRID_CELLS := 4096
# Leave room for the validator's neighbour offsets and inclusive range end.
# Reject huge finite coordinates before its floori()/range() conversions.
const MAX_VALIDATION_GRID_COORDINATE := 2147483644.0
const RECTANGULAR_SYMMETRY_EPSILON := 0.00002
const KNEE_SEMANTIC := "citadel_market_joinery"
const RIDGE_SEMANTIC := "citadel_market_canopy_ridge"
const CACHE_KEYS := ["physicalRoot", "physicalSupportPartIds", "physicalSupportCoverage", "physicalAnchorPartIds", "physicalIntentResolution"]

## Caller chooses the permitted/public paving; this wrapper cannot establish
## public access, placement clearance or navigation from a part's semantic label.
## Supported standing sources are axis-aligned collision floors/foundations.
## Every supplied member contributes to the footprint, including contents and
## ground detail. No cached layout rectangle, root flag or inferred neighbour
## support is authority. Posts may extend below paving to actual grounded masonry;
## exact subsurface/publisher clearance remains the caller's separate gate.
static func add_frame_on_grounded_support(blueprint, member_ids: Array, standing_surface_id: String) -> Dictionary:
	var details := {"standingSurfaceId": standing_surface_id, "rootCandidates": []}
	if blueprint == null or blueprint.parts.size() > MAX_SOURCE_PARTS or member_ids.size() < 5 or member_ids.size() > MAX_MEMBERS or standing_surface_id.is_empty() or standing_surface_id != standing_surface_id.strip_edges():
		return _fail("invalid_ground_selection_input", details)
	var records: Dictionary = {}
	for part in blueprint.parts:
		if part == null or String(part.id).is_empty() or part.id != String(part.id).strip_edges() or records.has(part.id):
			return _fail("missing_or_duplicate_source_id", details)
		if not blueprint.has_finite_positive_bounds(part):
			return _fail("invalid_ground_selection_bounds", details)
		var bounds: AABB = blueprint.transformed_part_bounds(part)
		if not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.end.is_finite() or bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or bounds.size.z <= 0.0:
			return _fail("invalid_ground_selection_bounds", details)
		records[part.id] = {"part": part, "bounds": bounds,
			"footprint": Rect2(Vector2(bounds.position.x, bounds.position.z), Vector2(bounds.size.x, bounds.size.z))}
	if not records.has(standing_surface_id):
		return _fail("missing_standing_surface", details)
	var surface = records[standing_surface_id].part
	if not surface.collision_enabled or surface.rotation != Vector3.ZERO or surface.kind not in ["foundation", "floor"]:
		return _fail("invalid_standing_surface_role", details)
	for intent in [surface.physical_intent, surface.recipe.get("physicalIntent", "")]:
		if not intent is String or intent not in ["", "structural_mass", "structural_root", "walkable_surface"]:
			return _fail("invalid_standing_surface_role", details)
		if intent == "structural_root" and not blueprint.is_grounded_structural_root(surface):
			return _fail("invalid_standing_surface_role", details)
	var standing_top: float = surface.position.y + surface.size.y * 0.5
	if not is_finite(standing_top):
		return _fail("invalid_ground_selection_bounds", details)
	details["standingSurfaceY"] = standing_top
	var members: Dictionary = {}
	var footprint_min := Vector2(INF, INF)
	var footprint_max := Vector2(-INF, -INF)
	for id in member_ids:
		if not id is String or id.is_empty() or id != id.strip_edges() or members.has(id) or not records.has(id) or id == standing_surface_id:
			return _fail("invalid_household_membership", details)
		var member_footprint: Rect2 = records[id].footprint
		footprint_min = footprint_min.min(member_footprint.position)
		footprint_max = footprint_max.max(member_footprint.end)
		members[id] = true
	# Reduce extrema first, then construct once: repeated Rect2.merge arithmetic
	# must not introduce member-order-dependent float32 size/end round trips.
	var footprint := Rect2(footprint_min, footprint_max - footprint_min)
	if not footprint.position.is_finite() or not footprint.size.is_finite() or not footprint.end.is_finite() or footprint.size.x <= 0.0 or footprint.size.y <= 0.0:
		return _fail("invalid_ground_selection_bounds", details)
	details["householdFootprint"] = footprint
	if not (records[standing_surface_id].footprint as Rect2).encloses(footprint):
		return _fail("household_outside_standing_surface", details)
	var roots: Array = []
	for id in records:
		var part = records[id].part
		if members.has(id) or part.rotation != Vector3.ZERO or not blueprint.is_grounded_structural_root(part):
			continue
		var top: float = part.position.y + part.size.y * 0.5
		if is_finite(top) and top <= standing_top and (records[id].footprint as Rect2).encloses(footprint):
			roots.append({"id": String(id), "top": top})
	roots.sort_custom(func(a, b): return a.top > b.top if a.top != b.top else a.id < b.id)
	details["rootCandidates"] = roots.map(func(root): return String(root.id))
	if roots.is_empty():
		return _fail("no_grounded_source_beneath_household", details)
	# Call exactly once, only after selection/validation is complete. add_frame
	# owns transactional assembly and its unchanged mandatory seat/grid guards.
	# A rejected highest root must not silently fall back to a lower candidate.
	var result: Dictionary = add_frame(blueprint, member_ids, roots[0].id)
	result.merge(details)
	return result

static func add_frame(blueprint, member_ids: Array, support_id: String) -> Dictionary:
	if blueprint == null or member_ids.size() < 5 or member_ids.size() > MAX_MEMBERS or support_id.is_empty() or blueprint.parts.size() > MAX_SOURCE_PARTS:
		return _fail("invalid_or_excessive_input")
	var originals: Dictionary = {}
	for part in blueprint.parts:
		if part == null or String(part.id).is_empty() or originals.has(part.id):
			return _fail("missing_or_duplicate_source_id")
		originals[part.id] = part
	var members: Dictionary = {}
	var knees: Array = []
	var ridges: Array = []
	for id in member_ids:
		if not id is String or id.is_empty() or id != id.strip_edges() or members.has(id) or not originals.has(id) or id == support_id:
			return _fail("invalid_household_membership")
		var part = originals[id]
		if not blueprint.has_finite_positive_bounds(part):
			return _fail("invalid_household_bounds")
		members[id] = true
		if part.semantic == KNEE_SEMANTIC:
			knees.append(part)
		if part.semantic == RIDGE_SEMANTIC:
			ridges.append(part)
	if knees.size() != 4 or ridges.size() != 1:
		return _fail("require_four_knees_and_one_ridge")
	var ridge = ridges[0]
	for part in knees + ridges:
		if part.kind != "beam" or part.material_id != "timber_beam" or part.collision_enabled or part.physical_intent not in ["", "facade_attachment"] or String(part.recipe.get("physicalIntent", "")) not in ["", "facade_attachment"] or bool(part.recipe.get("physicalRoot", false)):
			return _fail("incompatible_canopy_attachment")
		for key in part.recipe:
			if String(key).begins_with("physicalRequired"):
				return _fail("attachment_already_has_joint_contract")
		var variation: Variant = part.recipe.get("variation", 0.0)
		if not (variation is float or variation is int) or not is_finite(float(variation)):
			return _fail("invalid_variation")
	var staged = Blueprint.new(blueprint.id, blueprint.seed, blueprint.style)
	var support_result := _stage_supports(staged, originals, members, support_id)
	if not support_result.ready:
		return support_result
	# Only the declared structural support closure enters validation. Household
	# decoration, counter legs and neighbouring structures cannot rescue a joint.
	for part in knees + ridges:
		var copy = staged.add_part(part.snapshot())
		_clear_caches(copy)
	var geometry := _assemble(staged, ridge.id, knees.map(func(p): return String(p.id)), support_id)
	if not geometry.ready:
		return geometry
	for id in geometry.partIds:
		if originals.has(id):
			return _fail("frame_output_id_already_exists")
	var grid_guard := _validation_grid_guard(staged, "frame")
	if not grid_guard.ready:
		return grid_guard
	# Save authored records before validation derives mutable caches.
	var authored: Array = staged.part_snapshots()
	var validation: Dictionary = staged.validate_physical_integrity()
	if not validation.violations.is_empty() or validation.checks.size() != staged.parts.size() or not validation.checks.all(func(c): return bool(c.passed)):
		return _fail("invalid_staged_load_path", {"violations": validation.violations})
	for part in staged.parts:
		for fact in part.recipe.get("physicalRequiredSeatFacts", []):
			if not staged.has_rooted_bearer_seat(part, fact):
				return _fail("invalid_mandatory_seat")
		for fact in part.recipe.get("physicalRequiredAnchorFacts", []):
			if not _socket_inside(part, fact) or not staged.has_rooted_attachment_socket(part, fact):
				return _fail("invalid_mandatory_socket")
	# Commit only after EVERY new member and declared upstream dependency passes.
	# Keep original object/recipe identity, order, physical intent and render fields.
	for record in authored:
		if geometry.partIds.has(record.id):
			blueprint.add_part(record)
		elif members.has(record.id):
			for key in ["physicalRequiredAnchorPartIds", "physicalRequiredAnchorFacts"]:
				originals[record.id].recipe[key] = record.recipe[key].duplicate(true)
	return {"ready": true, "reason": "", "partIds": geometry.partIds,
		"memberIds": member_ids.duplicate() + geometry.partIds, "supportId": support_id,
		"evidenceLevel": "source_joinery_only", "doesNotProve": "Published ridge contact, cloth/content clearance, placement, live collision, navigation or physical gate acceptance."}

static func _stage_supports(staged, originals: Dictionary, members: Dictionary, support_id: String) -> Dictionary:
	var pending: Array = [support_id]
	var seen: Dictionary = {support_id: true}
	var cursor := 0
	while cursor < pending.size():
		var id: String = pending[cursor]
		cursor += 1
		if not originals.has(id) or members.has(id):
			return _fail("missing_or_household_support")
		var part = originals[id]
		if not staged.has_finite_positive_bounds(part) or not part.collision_enabled or part.kind not in ["foundation", "beam", "wall"] or part.physical_intent not in ["", "structural_mass", "structural_root"] or String(part.recipe.get("physicalIntent", "")) not in ["", "structural_mass", "structural_root"]:
			return _fail("incompatible_actual_support")
		if part.physical_intent == "structural_root" or String(part.recipe.get("physicalIntent", "")) == "structural_root" or bool(part.recipe.get("physicalRoot", false)):
			if not staged.is_grounded_structural_root(part):
				return _fail("forged_or_ungrounded_support_root")
		# The existing root taxonomy validates grounding, not additional seats.
		# Do not accept a root declaration that would bypass mandatory joint proof.
		if staged.is_grounded_structural_root(part):
			for key in part.recipe:
				if String(key).begins_with("physicalRequired"):
					return _fail("ground_root_must_not_declare_unchecked_joints")
		# Bounded existing seat schema, not a new structural inference engine.
		for key in part.recipe:
			if String(key).begins_with("physicalRequired") and key not in ["physicalRequiredSeatPartIds", "physicalRequiredSeatFacts", "physicalRequiredSupportPartIds"]:
				return _fail("unsupported_upstream_joint_schema")
		for key in ["physicalRequiredSeatPartIds", "physicalRequiredSupportPartIds"]:
			var ids: Variant = part.recipe.get(key, [])
			if not ids is Array or ids.size() > MAX_SUPPORT_PARTS:
				return _fail("invalid_support_declarations")
			var unique: Dictionary = {}
			for dependency in ids:
				if not dependency is String or dependency.is_empty() or dependency != dependency.strip_edges() or unique.has(dependency) or dependency == id:
					return _fail("invalid_support_declarations")
				unique[dependency] = true
				if not seen.has(dependency):
					if seen.size() >= MAX_SUPPORT_PARTS:
						return _fail("support_closure_limit")
					seen[dependency] = true
					pending.append(dependency)
		var facts: Variant = part.recipe.get("physicalRequiredSeatFacts", [])
		if not facts is Array or facts.size() > MAX_SUPPORT_PARTS:
			return _fail("invalid_support_seat_facts")
		for fact in facts:
			if not _seat_schema_valid(fact):
				return _fail("unsupported_support_seat_fact")
		var copy = staged.add_part(part.snapshot())
		_clear_caches(copy)
	# This isolated check prevents later posts from becoming their own foundation.
	var grid_guard := _validation_grid_guard(staged, "supports")
	if not grid_guard.ready:
		return grid_guard
	var validation: Dictionary = staged.validate_physical_integrity()
	if not validation.violations.is_empty() or not validation.checks.all(func(c): return bool(c.passed)):
		return _fail("supplied_support_has_no_valid_declared_root_path")
	for part in staged.parts:
		_clear_caches(part)
	return {"ready": true, "reason": "", "partIds": []}

static func _seat_schema_valid(fact: Variant) -> bool:
	if not fact is Dictionary or not fact.get("seatId") is String or fact.seatId.is_empty() or fact.seatId != fact.seatId.strip_edges():
		return false
	# The validator dispatches housed_overlap FIRST. Never admit a fact through
	# its gravity fields while the validator will instead read unchecked housed
	# fields (especially NaNs, whose comparisons can fail open). Reject mixed
	# mode payloads, not merely mixed discriminator values.
	for key in ["bearingPoint", "bearingNormalWorld", "bearerFace", "localEnd"]:
		if fact.has(key):
			return false
	if fact.get("contactMode", "") == "housed_overlap":
		for key in ["loadDirection", "seatFace", "localPatchCenter", "localPatchHalfExtents"]:
			if fact.has(key):
				return false
		if not fact.get("localOverlapCenter") is Vector3 or not fact.localOverlapCenter.is_finite() or not fact.get("localOverlapHalfExtents") is Vector3 or not fact.localOverlapHalfExtents.is_finite() or fact.get("localSpanAxis", "") not in ["x", "y", "z"]:
			return false
		var half: Vector3 = fact.localOverlapHalfExtents
		if half.x <= 0.0 or half.y <= 0.0 or half.z <= 0.0:
			return false
		for key in ["minimumLongitudinalEmbedment", "minimumVerticalOverlap"]:
			var value: Variant = fact.get(key, 0.0)
			if not (value is float or value is int) or not is_finite(float(value)) or float(value) < 0.0:
				return false
		return true
	if fact.get("loadDirection", "") == "world_down":
		for key in ["contactMode", "localOverlapCenter", "localOverlapHalfExtents", "localSpanAxis", "minimumLongitudinalEmbedment", "minimumVerticalOverlap"]:
			if fact.has(key):
				return false
		return fact.get("seatFace", "") == "max_y" and fact.get("localPatchCenter") is Vector3 and fact.localPatchCenter.is_finite() and fact.get("localPatchHalfExtents") is Vector2 and fact.localPatchHalfExtents.is_finite() and fact.localPatchHalfExtents.x > 0.0 and fact.localPatchHalfExtents.y > 0.0
	return false

static func _validation_grid_guard(staged, stage: String) -> Dictionary:
	# Work guard only: no grid cells are enumerated and no geometry is repaired.
	# Count per-part coverage, not the union: indexing stores each part in every
	# covered XZ cell. Include attachments too, since validation queries their
	# expanded bounds even though they are not inserted into the support grid.
	var cells := 0
	for part in staged.parts:
		var details := {"validationStage": stage, "partId": String(part.id)}
		if not staged.has_finite_positive_bounds(part):
			return _fail("invalid_validation_grid_bounds", details)
		var bounds: AABB = staged.transformed_part_bounds(part)
		# Match the broad-phase attachment query's existing projection expansion;
		# this enlarges the work estimate, NOT any contact/seat/socket tolerance.
		bounds = bounds.grow(Blueprint.PHYSICAL_CONTACT_MARGIN * sqrt(3.0))
		if not bounds.position.is_finite() or not bounds.size.is_finite() or not bounds.end.is_finite() or bounds.size.x <= 0.0 or bounds.size.z <= 0.0:
			return _fail("invalid_validation_grid_bounds", details)
		var min_x := floorf(bounds.position.x / Blueprint.PHYSICAL_SUPPORT_GRID_CELL)
		var max_x := floorf(bounds.end.x / Blueprint.PHYSICAL_SUPPORT_GRID_CELL)
		var min_z := floorf(bounds.position.z / Blueprint.PHYSICAL_SUPPORT_GRID_CELL)
		var max_z := floorf(bounds.end.z / Blueprint.PHYSICAL_SUPPORT_GRID_CELL)
		for coordinate in [min_x, max_x, min_z, max_z]:
			if not is_finite(coordinate) or absf(coordinate) > MAX_VALIDATION_GRID_COORDINATE:
				return _fail("validation_grid_coordinate_limit", details)
		var cells_x := max_x - min_x + 1.0
		var cells_z := max_z - min_z + 1.0
		if not is_finite(cells_x) or not is_finite(cells_z) or cells_x <= 0.0 or cells_z <= 0.0 or cells_x > MAX_VALIDATION_GRID_CELLS or cells_z > MAX_VALIDATION_GRID_CELLS:
			return _fail("staged_validation_grid_limit_exceeded", details)
		# Each factor is now <=4096, so multiplication and conversion are bounded.
		cells += int(cells_x * cells_z)
		if cells > MAX_VALIDATION_GRID_CELLS:
			return _fail("staged_validation_grid_limit_exceeded", details)
	return {"ready": true, "reason": "", "partIds": [], "projectedGridCells": cells}

static func _assemble(b, ridge_id: String, knee_ids: Array, support_id: String) -> Dictionary:
	var ridge = _find(b, ridge_id)
	var support = _find(b, support_id)
	var frame := Transform3D(Basis.from_euler(ridge.rotation), ridge.position)
	# Yaw is supported, tilt/inversion is not. Epsilon here checks orientation,
	# never expands a contact or changes the shared validator's tolerances.
	if frame.basis.y.distance_to(Vector3.UP) > 0.00001 or Basis.from_euler(support.rotation).y.distance_to(Vector3.UP) > 0.00001 or ridge.size.x <= maxf(ridge.size.y, ridge.size.z):
		return _fail("require_horizontal_ridge_and_support")
	var inverse := frame.affine_inverse()
	var slots: Dictionary = {}
	var section: float = maxf(ridge.size.y, ridge.size.z) * 1.5
	for id in knee_ids:
		var knee = _find(b, id)
		if knee.size.y <= maxf(knee.size.x, knee.size.z):
			return _fail("require_longitudinal_knee_y_axis")
		section = maxf(section, maxf(knee.size.x, knee.size.z) * 1.5)
	# Fixed joinery minima are inherited from existing Seats/validator, not loosened.
	if section < 0.18 or section > 0.40:
		return _fail("unsupported_timber_section")
	for id in knee_ids:
		var knee = _find(b, id)
		var transform := Transform3D(Basis.from_euler(knee.rotation), knee.position)
		var inset: float = section * 0.5
		if knee.size.y <= inset * 4.0:
			return _fail("knee_too_short_for_two_sockets")
		var low_local := Vector3(0, -knee.size.y * 0.5 + inset, 0)
		var high_local := Vector3(0, knee.size.y * 0.5 - inset, 0)
		var low: Vector3 = inverse * (transform * low_local)
		var high: Vector3 = inverse * (transform * high_local)
		if low.y > high.y:
			var swap := low
			low = high
			high = swap
			var local_swap := low_local
			low_local = high_local
			high_local = local_swap
		if absf(low.x) <= absf(high.x) or low.x * high.x <= 0.0 or absf(low.z - high.z) > 0.00001 or absf(low.z) < section or high.y >= -ridge.size.y or high.y - low.y < section:
			return _fail("incompatible_knee_geometry")
		var slot := "%d_%d" % [int(signf(low.x)), int(signf(low.z))]
		if slots.has(slot):
			return _fail("duplicate_knee_quadrant")
		slots[slot] = {"part": knee, "low": low, "high": high, "lowLocal": low_local, "highLocal": high_local}
	# This is the existing paired rectangular canopy grammar. Reject a warped
	# assembly instead of moving existing members into a guessed alignment.
	var reference: Dictionary = slots.get("-1_-1", {})
	if reference.is_empty():
		return _fail("incomplete_knee_quadrants")
	var half_width: float = absf(reference.low.x)
	var half_depth: float = absf(reference.low.z)
	var rail_y: float = reference.high.y
	# Transforming parts placed tens of metres from the source origin through
	# float32 yaw matrices accumulates several ULPs. This 20-micron comparison
	# admits that roundoff without relaxing seat, socket or collision checks.
	for slot in slots.values():
		if absf(absf(slot.low.x) - half_width) > RECTANGULAR_SYMMETRY_EPSILON or absf(absf(slot.low.z) - half_depth) > RECTANGULAR_SYMMETRY_EPSILON or absf(slot.high.y - rail_y) > RECTANGULAR_SYMMETRY_EPSILON:
			return _fail("nonrectangular_canopy", {"referenceLow": reference.low, "referenceHigh": reference.high, "actualLow": slot.low, "actualHigh": slot.high})
	var support_top: float = support.position.y + support.size.y * 0.5
	var floor_y: float = support_top - frame.origin.y
	var post_top: float = rail_y + section * 0.5
	if post_top - floor_y < section * 3.0 or post_top - floor_y > 8.0 or floor_y >= reference.low.y - section:
		return _fail("support_height_incompatible_with_canopy")
	var prefix: String = ridge.id + "_frame"
	var additions: Array = []
	var posts: Dictionary = {}
	var rails: Dictionary = {}
	for x_sign in [-1, 1]:
		for z_sign in [-1, 1]:
			var key := "%d_%d" % [x_sign, z_sign]
			var post = _mass(b, additions, prefix + "_post_" + key, frame,
				Vector3(x_sign * half_width, (floor_y + post_top) * 0.5, z_sign * half_depth),
				Vector3(section, post_top - floor_y, section), ridge)
			_set_seats(post, [Seats.world_down_seat_fact(support_id, Vector3(0, -post.size.y * 0.5, 0), Vector2.ONE * (section * 0.20))])
			posts[key] = post
	for z_sign in [-1, 1]:
		var rail = _mass(b, additions, prefix + "_header_%d" % z_sign, frame,
			Vector3(0, rail_y, z_sign * half_depth), Vector3(half_width * 2.0 + section, section, section), ridge)
		var facts: Array = []
		for x_sign in [-1, 1]:
			facts.append(_housed(posts["%d_%d" % [x_sign, z_sign]].id, Vector3(x_sign * half_width, 0, 0), "x"))
		_set_seats(rail, facts)
		rails[z_sign] = rail
	for x_sign in [-1, 1]:
		var tie = _mass(b, additions, prefix + "_tie_%d" % x_sign, frame,
			Vector3(x_sign * half_width, rail_y, 0), Vector3(section, section, half_depth * 2.0 + section), ridge)
		var facts: Array = []
		for z_sign in [-1, 1]:
			facts.append(_housed(rails[z_sign].id, Vector3(0, 0, z_sign * half_depth), "z"))
		_set_seats(tie, facts)
		var seat_bottom: float = rail_y + section * 0.5
		var seat_top: float = ridge.size.y * 0.25
		if seat_top - seat_bottom < section * 0.5:
			return _fail("insufficient_ridge_seat_height")
		var seat = _mass(b, additions, prefix + "_ridge_seat_%d" % x_sign, frame,
			Vector3(x_sign * half_width, (seat_bottom + seat_top) * 0.5, 0), Vector3(section, seat_top - seat_bottom, section), ridge)
		_set_seats(seat, [Seats.world_down_seat_fact(tie.id, Vector3(0, -seat.size.y * 0.5, 0), Vector2.ONE * (section * 0.20))])
		_add_socket(ridge, seat.id, Vector3(x_sign * half_width, -ridge.size.y * 0.15, 0), Vector3(ridge.size.z * 0.25, ridge.size.y * 0.14, ridge.size.z * 0.14))
	for x_sign in [-1, 1]:
		for z_sign in [-1, 1]:
			var key := "%d_%d" % [x_sign, z_sign]
			var slot: Dictionary = slots[key]
			var knee = slot.part
			var half := Vector3(knee.size.x * 0.18, section * 0.18, knee.size.z * 0.18)
			_add_socket(knee, posts[key].id, slot.lowLocal, half)
			_add_socket(knee, rails[z_sign].id, slot.highLocal, half)
	return {"ready": true, "reason": "", "partIds": additions}

static func _mass(b, additions: Array, id: String, frame: Transform3D, center: Vector3, size: Vector3, ridge):
	additions.append(id)
	return b.add_part({"id": id, "kind": "beam", "material": "timber_beam", "position": frame * center,
		"rotation": frame.basis.get_euler(), "size": size, "collision": true, "semantic": "citadel_market_canopy_frame",
		"recipe": {"physicalIntent": "structural_mass", "preserveBearingFaces": true, "variation": ridge.recipe.get("variation", 0.0)}})

static func _set_seats(part, facts: Array) -> void:
	part.recipe["physicalRequiredSeatPartIds"] = facts.map(func(f): return String(f.seatId))
	part.recipe["physicalRequiredSeatFacts"] = facts

static func _housed(id: String, center: Vector3, axis: String) -> Dictionary:
	var half := Vector3(0.035, 0.035, 0.035)
	half[0 if axis == "x" else 2] = 0.065
	return {"seatId": id, "contactMode": "housed_overlap", "localOverlapCenter": center,
		"localOverlapHalfExtents": half, "localSpanAxis": axis,
		"minimumLongitudinalEmbedment": Blueprint.STAIR_MIN_HOUSED_EMBEDMENT,
		"minimumVerticalOverlap": Blueprint.STAIR_MIN_HOUSED_VERTICAL_OVERLAP}

static func _add_socket(part, id: String, center: Vector3, half: Vector3) -> void:
	if not part.recipe.has("physicalRequiredAnchorPartIds"):
		part.recipe["physicalRequiredAnchorPartIds"] = []
		part.recipe["physicalRequiredAnchorFacts"] = []
	part.recipe.physicalRequiredAnchorPartIds.append(id)
	part.recipe.physicalRequiredAnchorFacts.append({"anchorId": id, "contactMode": "attachment_socket", "localMountCenter": center, "localMountHalfExtents": half})

static func _socket_inside(part, fact: Dictionary) -> bool:
	var center: Vector3 = fact.localMountCenter
	var half: Vector3 = fact.localMountHalfExtents
	if not center.is_finite() or not half.is_finite():
		return false
	for axis in range(3):
		if half[axis] <= 0.0 or absf(center[axis]) + half[axis] >= part.size[axis] * 0.5 - Blueprint.STAIR_HOUSED_JOINT_INSET:
			return false
	return true

static func _clear_caches(part) -> void:
	for key in CACHE_KEYS:
		part.recipe.erase(key)

static func _find(b, id: String):
	for part in b.parts:
		if part.id == id:
			return part
	return null

static func _fail(reason: String, details: Dictionary = {}) -> Dictionary:
	var result := {"ready": false, "reason": reason, "partIds": []}
	result.merge(details)
	return result
