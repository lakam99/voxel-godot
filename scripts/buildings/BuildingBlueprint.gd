extends RefCounted
class_name BuildingBlueprint

const BuildingPartScript := preload("res://scripts/buildings/BuildingPart.gd")
const GablePurlinFrameValidator := preload("res://scripts/buildings/GablePurlinFrameValidator.gd")
const MandatoryPhysicalDependencyValidator := preload("res://scripts/buildings/MandatoryPhysicalDependencyValidator.gd")

var id := ""
var seed := 0
var style := "timber"
var recipe: Dictionary = {}
var rooms: Array = []
var parts: Array = []
var physical_parts_by_id: Dictionary = {}
var structural_support_grid: Dictionary = {}
var invalid_gable_part_ids: Dictionary = {}

# Geometry is unchanged during synchronous resolve/validation; recipe proof facts
# are not. Never retain these caches across passes (parts are directly mutable).
var _validation_cache_active := false
var _validation_transforms: Dictionary = {}
var _validation_inverses: Dictionary = {}
var _validation_bounds: Dictionary = {}
var _validation_neighbors: Dictionary = {}

const PHYSICAL_SUPPORT_GRID_CELL := 4.0
const PHYSICAL_CONTACT_MARGIN := 0.05
const STAIR_HOUSED_JOINT_INSET := 0.005
const STAIR_MIN_HOUSED_EMBEDMENT := 0.12
const STAIR_MIN_HOUSED_VERTICAL_OVERLAP := 0.04


func _init(blueprint_id := "", blueprint_seed := 0, blueprint_style := "timber") -> void:
	id = blueprint_id
	seed = blueprint_seed
	style = blueprint_style


func add_part(values: Dictionary) -> BuildingPart:
	var part = BuildingPartScript.new(values)
	parts.append(part)
	return part


func set_recipe(values: Dictionary) -> void:
	recipe = values.duplicate(true)


func set_room_records(values: Array) -> void:
	rooms.clear()
	for value in values:
		if value is Dictionary:
			rooms.append((value as Dictionary).duplicate(true))


func part_snapshots() -> Array:
	var result: Array = []
	for part in parts:
		if part != null and part.has_method("snapshot"):
			result.append(part.snapshot())
	return result


func validate_physical_integrity() -> Dictionary:
	return _validate_physical_integrity(Callable())


## Use on exclusively owned base proof copies. Cancellation leaves partial
## derived recipe facts: discard the copy; never publish or resume it.
func validate_physical_integrity_cancellable(continuation: Callable) -> Dictionary:
	return _validate_physical_integrity(continuation)


func _validate_physical_integrity(continuation: Callable) -> Dictionary:
	var cache_owner := _begin_validation_cache()
	if not _continue_validation(continuation, "physical_validation_started"):
		return _cancel_physical_validation(cache_owner)
	if continuation.is_valid():
		if not _resolve_physical_contracts(continuation): return _cancel_physical_validation(cache_owner)
	else:
		# Keep the legacy virtual entry point for existing subclasses.
		resolve_physical_contracts()
	var checks: Array[Dictionary] = []
	var violations: Array[String] = []
	for part in parts:
		if not _continue_validation(continuation, "physical_validation_part"):
			return _cancel_physical_validation(cache_owner)
		if part == null:
			continue
		var intent := String(part.physical_intent)
		var check := {
			"partId": String(part.id),
			"intent": intent,
			"collisionEnabled": bool(part.collision_enabled),
			"supportPartIds": part.recipe.get("physicalSupportPartIds", []),
			"supportCoverage": part.recipe.get("physicalSupportCoverage", []),
			"physicalRoot": bool(part.recipe.get("physicalRoot", false)),
			"classification": String(part.recipe.get("physicalIntentResolution", ""))
		}
		if bool(part.recipe.get("physicalTransformDependencyMissing", false)):
			check["passed"] = false
			violations.append("%s references a missing transformed physical dependency" % String(part.id))
			checks.append(check)
			continue
		if GablePurlinFrameValidator.is_frame_part(part) and not GablePurlinFrameValidator.schema_valid(part):
			check["passed"] = false
			violations.append("%s has an invalid gable frame schema" % String(part.id))
			checks.append(check)
			continue
		match intent:
			"structural_root":
				check["passed"] = bool(part.collision_enabled) and bool(part.recipe.get("physicalRoot", false))
				if not bool(check["passed"]):
					violations.append("%s structural_root is not collision-backed and grounded" % String(part.id))
			"structural_mass":
				var supports: Array = part.recipe.get("physicalSupportPartIds", []) as Array
				var required_supports: Array = part.recipe.get("physicalRequiredSupportPartIds", []) as Array
				var has_required_supports := required_supports.all(func(required_id) -> bool: return supports.has(String(required_id)))
				var required_seats: Array = part.recipe.get("physicalRequiredSeatPartIds", []) as Array
				var seat_facts: Array = part.recipe.get("physicalRequiredSeatFacts", []) as Array
				var fact_seat_ids: Array[String] = []
				for seat_fact_value in seat_facts:
					var fact_seat_id := String((seat_fact_value as Dictionary).get("seatId", ""))
					if not fact_seat_id.is_empty() and not fact_seat_ids.has(fact_seat_id):
						fact_seat_ids.append(fact_seat_id)
				var seat_facts_match_declarations := fact_seat_ids.size() == seat_facts.size() and fact_seat_ids.size() == required_seats.size() and required_seats.all(func(seat_id) -> bool: return fact_seat_ids.has(String(seat_id)))
				var assembly_role := String(part.recipe.get("physicalAssemblyRole", ""))
				var required_gravity_patch_count := 1 if assembly_role in ["stair_carriage_bearing_block", "landing_underframe", "roof_wall_plate", "roof_king_post"] else 0
				var has_required_gravity_bearing_patches := required_gravity_patch_count == 0 or seat_facts.size() == required_gravity_patch_count and seat_facts.all(func(seat_fact) -> bool:
					return String((seat_fact as Dictionary).get("loadDirection", "")) == "world_down"
				)
				var has_valid_stair_assembly := has_valid_stair_carriage_assembly(part) if assembly_role == "stair_sloped_span" else true
				var has_valid_roof_assembly := has_valid_roof_frame_assembly(part) if assembly_role == "roof_sloped_span" else true
				var has_rooted_seats := seat_facts_match_declarations and seat_facts.all(func(seat_fact) -> bool: return has_rooted_bearer_seat(part, seat_fact as Dictionary)) if not seat_facts.is_empty() else required_seats.all(func(seat_id) -> bool:
					var seat = find_part(String(seat_id))
					return seat != null and transformed_parts_overlap(part, seat, PHYSICAL_CONTACT_MARGIN) and has_rooted_support_chain(seat, {})
				)
				var reaches_root := has_rooted_support_chain(part, {})
				var coverage: Array = part.recipe.get("physicalSupportCoverage", []) as Array
				var requires_full_coverage := String(part.recipe.get("physicalAssemblyRole", "")) == "walkable_subfloor"
				var has_rooted_coverage := coverage_has_rooted_supports(coverage, 25) if requires_full_coverage else true
				check["reachesGroundRoot"] = reaches_root
				check["hasRootedCoverage"] = has_rooted_coverage
				check["requiredSupportPartIds"] = required_supports
				check["requiredSeatPartIds"] = required_seats
				check["hasRootedSeats"] = has_rooted_seats
				var has_declared_load_path := has_rooted_seats if not required_seats.is_empty() else not supports.is_empty() and has_required_supports
				check["passed"] = bool(part.collision_enabled) and has_declared_load_path and has_required_gravity_bearing_patches and has_valid_stair_assembly and has_valid_roof_assembly and reaches_root and has_rooted_coverage
				if not bool(part.collision_enabled):
					violations.append("%s structural_mass has no collision" % String(part.id))
				elif not has_declared_load_path or not has_required_gravity_bearing_patches or not has_valid_stair_assembly or not has_valid_roof_assembly or not reaches_root or not has_rooted_coverage:
					violations.append("%s structural_mass has no rooted structural support chain" % String(part.id))
			"walkable_surface":
				var coverage: Array = part.recipe.get("physicalSupportCoverage", []) as Array
				var supports: Array = part.recipe.get("physicalSupportPartIds", []) as Array
				var required_supports: Array = part.recipe.get("physicalRequiredSupportPartIds", []) as Array
				var allowed_supports: Array = part.recipe.get("physicalAllowedSupportPartIds", required_supports) as Array
				# A named bearing member may legitimately sit between the 3x3 surface
				# samples (for example on a procedural ramp).  Prove its own rooted
				# transformed contact instead of conflating named load paths with the
				# sparse coverage probe; both checks remain mandatory.
				var has_required_supports := required_supports.all(func(required_id) -> bool:
					var required_support = find_part(String(required_id))
					return supports.has(String(required_id)) or required_support != null and has_rooted_support_chain(required_support, {}) and transformed_parts_overlap(part, required_support, PHYSICAL_CONTACT_MARGIN)
				)
				var required_coverage_by_z: Array = part.recipe.get("physicalRequiredCoverageByZIndex", []) as Array
				var required_coverage_by_x: Array = part.recipe.get("physicalRequiredCoverageByXIndex", []) as Array
				var has_complete_coverage := coverage_has_rooted_supports(coverage, 9, allowed_supports if String(part.recipe.get("physicalAssemblyRole", "")) == "floor_diaphragm" else [], required_coverage_by_z, required_coverage_by_x)
				var reaches_root := has_rooted_support_chain(part, {})
				check["reachesGroundRoot"] = reaches_root
				check["requiredSupportPartIds"] = required_supports
				check["passed"] = bool(part.collision_enabled) and has_complete_coverage and has_required_supports and reaches_root
				if not bool(part.collision_enabled):
					violations.append("%s walkable_surface has no collision" % String(part.id))
				elif not has_complete_coverage:
					violations.append("%s walkable_surface lacks full transformed 3x3 support coverage" % String(part.id))
				elif not has_required_supports or not reaches_root:
					violations.append("%s walkable_surface has no rooted structural support chain" % String(part.id))
			"facade_attachment":
				var attachments: Array = part.recipe.get("physicalAnchorPartIds", []) as Array
				var required_anchors: Array = part.recipe.get("physicalRequiredAnchorPartIds", []) as Array
				var anchor_facts: Array = part.recipe.get("physicalRequiredAnchorFacts", []) as Array
				var fact_anchor_ids: Array[String] = []
				for fact_value in anchor_facts:
					var fact_anchor_id := String((fact_value as Dictionary).get("anchorId", ""))
					if not fact_anchor_id.is_empty() and not fact_anchor_ids.has(fact_anchor_id):
						fact_anchor_ids.append(fact_anchor_id)
				var has_required_anchors := required_anchors.all(func(required_id) -> bool: return attachments.has(String(required_id)))
				var has_required_anchor_facts := anchor_facts.is_empty() or fact_anchor_ids.size() == anchor_facts.size() and fact_anchor_ids.size() == required_anchors.size() and required_anchors.all(func(anchor_id) -> bool: return fact_anchor_ids.has(String(anchor_id))) and anchor_facts.all(func(fact_value) -> bool: return has_rooted_attachment_socket(part, fact_value as Dictionary))
				var reaches_root := has_rooted_anchor_chain(part, {})
				check["anchorPartIds"] = attachments
				check["requiredAnchorPartIds"] = required_anchors
				check["hasRequiredAnchorFacts"] = has_required_anchor_facts
				check["reachesGroundRoot"] = reaches_root
				var has_named_anchor_contract := not anchor_facts.is_empty()
				var has_valid_anchor_contract := has_required_anchor_facts if has_named_anchor_contract else not attachments.is_empty() and has_required_anchors
				check["passed"] = not bool(part.collision_enabled) and has_valid_anchor_contract and reaches_root
				if bool(part.collision_enabled):
					violations.append("%s facade_attachment must not create gameplay collision" % String(part.id))
				elif not has_valid_anchor_contract or not reaches_root:
					violations.append("%s facade_attachment has no rooted declared anchor" % String(part.id))
			"portal":
				check["passed"] = true
			"visual_detail":
				check["passed"] = not bool(part.collision_enabled)
				if bool(part.collision_enabled):
					violations.append("%s visual_detail must not create gameplay collision" % String(part.id))
			_:
				check["passed"] = false
				violations.append("%s has no declared physical intent" % String(part.id))
		checks.append(check)
	# Validate new frame obligations independently of physical intent. Existing
	# bearer checks are available now, so incidental graph reachability cannot
	# conceal a failed mandatory seat further down the load path.
	if not _continue_validation(continuation, "physical_frame_context"):
		return _cancel_physical_validation(cache_owner)
	var frame_context := GablePurlinFrameValidator.context_for(self, checks)
	for check in checks:
		if not _continue_validation(continuation, "physical_frame_part"):
			return _cancel_physical_validation(cache_owner)
		var part = find_part(String(check.partId))
		if part != null and GablePurlinFrameValidator.is_frame_part(part):
			var frame_valid := GablePurlinFrameValidator.validates(self, part, frame_context)
			check["hasValidGableFrame"] = frame_valid
			if not frame_valid and bool(check.passed):
				check["passed"] = false
				violations.append("%s has no complete gable roof load path" % String(part.id))
	if not _continue_validation(continuation, "physical_dependencies_started"):
		return _cancel_physical_validation(cache_owner)
	MandatoryPhysicalDependencyValidator.apply(parts, checks, violations)
	if not _continue_validation(continuation, "physical_validation_completed"):
		return _cancel_physical_validation(cache_owner)
	_end_validation_cache(cache_owner)
	return {
		"passed": violations.is_empty(),
		"checkedPartCount": checks.size(),
		"checks": checks,
		"violations": violations
}


func resolve_physical_contracts() -> void:
	_resolve_physical_contracts(Callable())


## Owned proof copies only: cancellation leaves partial derived facts. Discard
## the copy rather than resuming it or publishing its partial resolution.
func resolve_physical_contracts_cancellable(continuation: Callable) -> bool:
	if not continuation.is_valid():
		# Preserve the legacy virtual entry point for empty-continuation callers.
		resolve_physical_contracts()
		return true
	return _resolve_physical_contracts(continuation)


func _resolve_physical_contracts(continuation: Callable) -> bool:
	var cache_owner := _begin_validation_cache()
	physical_parts_by_id.clear()
	structural_support_grid.clear()
	_validation_neighbors.clear()
	invalid_gable_part_ids.clear()
	for part in parts:
		if not _continue_validation(continuation, "physical_resolve_schema"):
			_end_validation_cache(cache_owner)
			return false
		if part != null and GablePurlinFrameValidator.is_frame_part(part) and not GablePurlinFrameValidator.schema_valid(part):
			invalid_gable_part_ids[String(part.id)] = true
	for part in parts:
		if not _continue_validation(continuation, "physical_resolve_classification"):
			_end_validation_cache(cache_owner)
			return false
		if part == null:
			continue
		physical_parts_by_id[String(part.id)] = part
		if String(part.physical_intent).is_empty():
			part.physical_intent = inferred_physical_intent(part)
			part.recipe["physicalIntent"] = part.physical_intent
			part.recipe["physicalIntentResolution"] = "building_part_taxonomy"
		else:
			part.recipe["physicalIntentResolution"] = "recipe"
		if String(part.physical_intent) in ["structural_mass", "structural_root"] and is_grounded_structural_root(part):
			part.physical_intent = "structural_root"
			part.recipe["physicalIntent"] = "structural_root"
			part.recipe["physicalRoot"] = true
	for part in parts:
		if not _continue_validation(continuation, "physical_resolve_roots"):
			_end_validation_cache(cache_owner)
			return false
		if part != null and String(part.physical_intent) == "structural_mass" and is_grounded_structural_root(part):
			part.physical_intent = "structural_root"
			part.recipe["physicalIntent"] = "structural_root"
			part.recipe["physicalRoot"] = true
	if continuation.is_valid():
		if not _index_structural_support_candidates(continuation):
			_end_validation_cache(cache_owner)
			return false
	else:
		index_structural_support_candidates()
	for part in parts:
		if not _continue_validation(continuation, "physical_resolve_support"):
			_end_validation_cache(cache_owner)
			return false
		if part == null:
			continue
		if invalid_gable_part_ids.has(String(part.id)):
			continue
		match String(part.physical_intent):
			"structural_mass", "walkable_surface":
				var support_record := resolved_support_record(part)
				part.recipe["physicalSupportPartIds"] = support_record.get("partIds", [])
				part.recipe["physicalSupportCoverage"] = support_record.get("coverage", [])
			"facade_attachment":
				var anchor_ids := resolved_attachment_anchor_ids(part)
				part.recipe["physicalAnchorPartIds"] = anchor_ids
	_end_validation_cache(cache_owner)
	return true


static func _continue_validation(continuation: Callable, stage: String) -> bool:
	return not continuation.is_valid() or continuation.call(stage) == true


func _cancel_physical_validation(cache_owner: bool) -> Dictionary:
	_end_validation_cache(cache_owner)
	physical_parts_by_id.clear()
	structural_support_grid.clear()
	invalid_gable_part_ids.clear()
	_validation_neighbors.clear()
	return {"passed": false, "cancelled": true, "checkedPartCount": 0,
		"checks": [], "violations": ["physical_validation_cancelled"]}


func inferred_physical_intent(part) -> String:
	if String(part.kind) in ["door", "window"]:
		return "portal"
	if bool(part.collision_enabled):
		if String(part.kind) in ["floor", "ramp"]:
			return "walkable_surface"
		return "structural_mass"
	if String(part.kind) in ["roof", "wall", "beam", "floor", "foundation", "window"]:
		return "facade_attachment"
	return "visual_detail"


func is_grounded_structural_root(part) -> bool:
	if not bool(part.collision_enabled) or String(part.kind) != "foundation":
		return false
	for sample in footprint_bottom_samples(part, 3):
		if absf((sample as Dictionary).get("position", Vector3.INF).y) > 0.06:
			return false
	return true


func resolved_support_record(target) -> Dictionary:
	var samples := footprint_bottom_samples(target, 3 if String(target.physical_intent) == "walkable_surface" else 5)
	var part_ids: Array[String] = []
	var coverage: Array[Dictionary] = []
	for sample_value in samples:
		var sample: Dictionary = sample_value as Dictionary
		var support = structural_support_at(target, sample.get("position", Vector3.ZERO) as Vector3)
		var support_id := String(support.get("id", ""))
		if not support_id.is_empty() and not part_ids.has(support_id):
			part_ids.append(support_id)
		coverage.append({"sample": String(sample.get("id", "center")), "position": sample.get("position", Vector3.ZERO), "supportPartId": support_id, "supported": not support_id.is_empty()})
	return {"partIds": part_ids, "coverage": coverage}


func structural_support_at(target, point: Vector3) -> Dictionary:
	var best: Dictionary = {}
	var best_gap := INF
	var required_ids: Dictionary = {}
	for required_id_value in target.recipe.get("physicalRequiredSupportPartIds", []) as Array:
		required_ids[String(required_id_value)] = true
	var candidates := structural_candidates_near(point)
	for preferred_pass in [true, false]:
		for candidate in candidates:
			if candidate == null or candidate == target or not is_structural_support_candidate(candidate):
				continue
			if required_ids.has(String(candidate.id)) != preferred_pass:
				continue
			if String(candidate.id) == String(target.recipe.get("physicalSupportsPartId", "")):
				continue
			var local_point := part_inverse_transform(candidate) * point
			if absf(local_point.x) > candidate.size.x * 0.5 + PHYSICAL_CONTACT_MARGIN or absf(local_point.z) > candidate.size.z * 0.5 + PHYSICAL_CONTACT_MARGIN:
				continue
			var candidate_bottom: float = candidate.position.y - candidate.size.y * 0.5
			var candidate_top: float = candidate.position.y + candidate.size.y * 0.5
			var target_bottom: float = target.position.y - target.size.y * 0.5
			var target_top: float = target.position.y + target.size.y * 0.5
			var candidate_encloses_target: bool = bool(target.recipe.get("allowEnclosingStructuralSupport", false)) and candidate_bottom <= target_bottom + 0.04 and candidate_top >= target_top - 0.04 and candidate.size.y >= target.size.y + 0.30
			var candidate_is_lower: bool = candidate.position.y < target.position.y - 0.05 or candidate_encloses_target or bool(candidate.recipe.get("physicalRoot", false))
			if candidate_is_lower and local_point.y >= -candidate.size.y * 0.5 - 0.08 and local_point.y <= candidate.size.y * 0.5 + 0.10:
				return {"id": String(candidate.id), "surface": point, "gap": 0.0, "contact": "embedded"}
			var candidate_surface := part_transform(candidate) * Vector3(local_point.x, candidate.size.y * 0.5, local_point.z)
			var gap := point.y - candidate_surface.y
			if gap < -0.14 or gap > 0.26 or gap >= best_gap:
				continue
			best_gap = gap
			best = {"id": String(candidate.id), "surface": candidate_surface, "gap": gap}
	return best


func resolved_attachment_anchor_ids(target) -> Array[String]:
	var anchors: Array[String] = []
	for required_id_value in target.recipe.get("physicalRequiredAnchorPartIds", []) as Array:
		var required_anchor = find_part(String(required_id_value))
		if required_anchor != null and is_structural_support_candidate(required_anchor) and transformed_parts_overlap(target, required_anchor, PHYSICAL_CONTACT_MARGIN):
			anchors.append(String(required_anchor.id))
	for candidate in structural_candidates_overlapping_part(target, PHYSICAL_CONTACT_MARGIN):
		if candidate == null or candidate == target or not is_structural_support_candidate(candidate):
			continue
		if not anchors.has(String(candidate.id)) and transformed_parts_overlap(target, candidate, PHYSICAL_CONTACT_MARGIN):
			anchors.append(String(candidate.id))
	return anchors


func transformed_parts_overlap(first, second, margin := 0.05) -> bool:
	# Corner containment misses intersecting thin members with no enclosed corner.
	# Keep the existing tolerance: expand either box, never both simultaneously.
	return transformed_boxes_intersect(first, second, margin) or transformed_boxes_intersect(second, first, margin)


func transformed_boxes_intersect(first, second, second_margin: float) -> bool:
	if not is_finite(second_margin) or second_margin < 0.0 or not has_finite_positive_bounds(first) or not has_finite_positive_bounds(second):
		return false
	var first_basis := part_transform(first).basis
	var second_basis := part_transform(second).basis
	var first_axes: Array[Vector3] = [first_basis.x, first_basis.y, first_basis.z]
	var second_axes: Array[Vector3] = [second_basis.x, second_basis.y, second_basis.z]
	var axes: Array[Vector3] = []
	axes.append_array(first_axes)
	axes.append_array(second_axes)
	for first_axis in first_axes:
		for second_axis in second_axes:
			axes.append(first_axis.cross(second_axis))
	var first_half: Vector3 = first.size * 0.5
	var second_half: Vector3 = second.size * 0.5 + Vector3.ONE * second_margin
	var delta: Vector3 = second.position - first.position
	for axis in axes:
		if axis.length_squared() <= 1.0e-12:
			continue
		var first_radius := 0.0
		var second_radius := 0.0
		for index in range(3):
			first_radius += first_half[index] * absf(axis.dot(first_axes[index]))
			second_radius += second_half[index] * absf(axis.dot(second_axes[index]))
		if absf(delta.dot(axis)) > first_radius + second_radius:
			return false
	return true


func has_finite_positive_bounds(part) -> bool:
	return part != null and part.position.is_finite() and part.rotation.is_finite() and part.size.is_finite() and part.size.x > 0.0 and part.size.y > 0.0 and part.size.z > 0.0


func structural_candidates_overlapping_part(target, margin: float) -> Array:
	if not is_finite(margin) or margin < 0.0 or not has_finite_positive_bounds(target):
		return []
	# A local-axis margin projects by up to sqrt(3) onto a world axis.
	# This is broad-phase expansion only; the OBB test retains the exact margin.
	var bounds := transformed_part_bounds(target).grow(margin * sqrt(3.0))
	var result: Array = []
	var seen: Dictionary = {}
	for cell_x in range(floori(bounds.position.x / PHYSICAL_SUPPORT_GRID_CELL), floori(bounds.end.x / PHYSICAL_SUPPORT_GRID_CELL) + 1):
		for cell_z in range(floori(bounds.position.z / PHYSICAL_SUPPORT_GRID_CELL), floori(bounds.end.z / PHYSICAL_SUPPORT_GRID_CELL) + 1):
			for candidate in structural_support_grid.get("%d:%d" % [cell_x, cell_z], []) as Array:
				if not seen.has(String(candidate.id)):
					seen[String(candidate.id)] = true
					result.append(candidate)
	return result


func transformed_part_bounds(part) -> AABB:
	if _validation_cache_active and _validation_bounds.has(part):
		return _validation_bounds[part]
	var transform := part_transform(part)
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	for x_sign in [-1.0, 1.0]:
		for y_sign in [-1.0, 1.0]:
			for z_sign in [-1.0, 1.0]:
				var corner: Vector3 = transform * (part.size * Vector3(x_sign, y_sign, z_sign) * 0.5)
				minimum = minimum.min(corner)
				maximum = maximum.max(corner)
	var bounds := AABB(minimum, maximum - minimum)
	if _validation_cache_active: _validation_bounds[part] = bounds
	return bounds


func transformed_part_corner_within(first, second, margin: float) -> bool:
	var first_to_second := part_inverse_transform(second) * part_transform(first)
	for x_sign in [-1.0, 1.0]:
		for y_sign in [-1.0, 1.0]:
			for z_sign in [-1.0, 1.0]:
				var point := first_to_second * Vector3(first.size.x * 0.5 * x_sign, first.size.y * 0.5 * y_sign, first.size.z * 0.5 * z_sign)
				if absf(point.x) <= second.size.x * 0.5 + margin and absf(point.y) <= second.size.y * 0.5 + margin and absf(point.z) <= second.size.z * 0.5 + margin:
					return true
	return false


func footprint_bottom_samples(part, resolution: int) -> Array[Dictionary]:
	var samples: Array[Dictionary] = []
	var sample_count := maxi(1, resolution)
	for x_index in range(sample_count):
		for z_index in range(sample_count):
			var x_fraction := 0.5 if sample_count == 1 else float(x_index) / float(sample_count - 1)
			var z_fraction := 0.5 if sample_count == 1 else float(z_index) / float(sample_count - 1)
			var local_point := Vector3(lerpf(-part.size.x * 0.5, part.size.x * 0.5, x_fraction), -part.size.y * 0.5, lerpf(-part.size.z * 0.5, part.size.z * 0.5, z_fraction))
			samples.append({"id": "%d_%d" % [x_index, z_index], "position": part_transform(part) * local_point})
	return samples


func is_structural_support_candidate(part) -> bool:
	if part != null and invalid_gable_part_ids.has(String(part.id)):
		return false
	return part != null and bool(part.collision_enabled) and String(part.physical_intent) in ["structural_root", "structural_mass", "walkable_surface"]


func part_transform(part) -> Transform3D:
	if _validation_cache_active and _validation_transforms.has(part):
		return _validation_transforms[part]
	var transform := Transform3D(Basis.from_euler(part.rotation), part.position)
	if _validation_cache_active: _validation_transforms[part] = transform
	return transform


func part_inverse_transform(part) -> Transform3D:
	if _validation_cache_active and _validation_inverses.has(part):
		return _validation_inverses[part]
	var inverse := part_transform(part).affine_inverse()
	if _validation_cache_active: _validation_inverses[part] = inverse
	return inverse


func _begin_validation_cache() -> bool:
	if _validation_cache_active: return false
	_validation_cache_active = true
	return true


func _end_validation_cache(owner: bool) -> void:
	if not owner: return
	_validation_cache_active = false
	_validation_transforms.clear()
	_validation_inverses.clear()
	_validation_bounds.clear()
	_validation_neighbors.clear()


func index_structural_support_candidates() -> void:
	_index_structural_support_candidates(Callable())


func _index_structural_support_candidates(continuation: Callable) -> bool:
	_validation_neighbors.clear()
	var cells_since_checkpoint := 0
	for part in parts:
		if not _continue_validation(continuation, "physical_grid_part"): return false
		if not is_structural_support_candidate(part) or not has_finite_positive_bounds(part):
			continue
		var bounds := transformed_part_bounds(part)
		var minimum := bounds.position
		var maximum := bounds.end
		var minimum_x := floori(minimum.x / PHYSICAL_SUPPORT_GRID_CELL)
		var maximum_x := floori(maximum.x / PHYSICAL_SUPPORT_GRID_CELL)
		var minimum_z := floori(minimum.z / PHYSICAL_SUPPORT_GRID_CELL)
		var maximum_z := floori(maximum.z / PHYSICAL_SUPPORT_GRID_CELL)
		for cell_x in range(minimum_x, maximum_x + 1):
			for cell_z in range(minimum_z, maximum_z + 1):
				if continuation.is_valid():
					if cells_since_checkpoint == 0 and not _continue_validation(continuation, "physical_grid_cells"): return false
					cells_since_checkpoint = (cells_since_checkpoint + 1) % 64
				var key := "%d:%d" % [cell_x, cell_z]
				if not structural_support_grid.has(key):
					structural_support_grid[key] = []
				(structural_support_grid[key] as Array).append(part)
	return true


func structural_candidates_near(point: Vector3) -> Array:
	var result: Array = []
	var seen: Dictionary = {}
	var origin_x := floori(point.x / PHYSICAL_SUPPORT_GRID_CELL)
	var origin_z := floori(point.z / PHYSICAL_SUPPORT_GRID_CELL)
	var origin := Vector2i(origin_x, origin_z)
	if _validation_cache_active and _validation_neighbors.has(origin):
		return _validation_neighbors[origin]
	for cell_x in range(origin_x - 1, origin_x + 2):
		for cell_z in range(origin_z - 1, origin_z + 2):
			var key := "%d:%d" % [cell_x, cell_z]
			for candidate in structural_support_grid.get(key, []) as Array:
				var candidate_id := String(candidate.id)
				if not seen.has(candidate_id):
					seen[candidate_id] = true
					result.append(candidate)
	if _validation_cache_active: _validation_neighbors[origin] = result
	return result


func has_rooted_support_chain(part, visited: Dictionary) -> bool:
	if invalid_gable_part_ids.has(String(part.id)):
		return false
	var part_id := String(part.id)
	if bool(part.recipe.get("physicalRoot", false)):
		return true
	if visited.has(part_id):
		return false
	var next_visited := visited.duplicate()
	next_visited[part_id] = true
	for support_id_value in part.recipe.get("physicalSupportPartIds", []) as Array:
		var support = find_part(String(support_id_value))
		if support != null and has_rooted_support_chain(support, next_visited):
			return true
	var seat_facts: Array = part.recipe.get("physicalRequiredSeatFacts", []) as Array
	if not seat_facts.is_empty():
		for seat_fact_value in seat_facts:
			var seat_fact: Dictionary = seat_fact_value as Dictionary
			var fact_seat = find_part(String(seat_fact.get("seatId", "")))
			if fact_seat != null and has_rooted_bearer_seat(part, seat_fact, next_visited):
				return true
	else:
		for seat_id_value in part.recipe.get("physicalRequiredSeatPartIds", []) as Array:
			var seat = find_part(String(seat_id_value))
			if seat != null and transformed_parts_overlap(part, seat, PHYSICAL_CONTACT_MARGIN) and has_rooted_support_chain(seat, next_visited):
				return true
	return false


func has_rooted_bearer_seat(bearer, seat_fact: Dictionary, visited: Dictionary = {}) -> bool:
	var seat = find_part(String(seat_fact.get("seatId", "")))
	if seat == null or not bool(seat.collision_enabled) or String(seat.physical_intent) not in ["structural_mass", "structural_root"]:
		return false
	if String(seat_fact.get("contactMode", "")) == "housed_overlap":
		return has_rooted_housed_overlap(bearer, seat, seat_fact, visited)
	if String(seat_fact.get("loadDirection", "")) == "world_down":
		return has_rooted_gravity_bearing_patch(bearer, seat, seat_fact, visited)
	if seat_fact.has("bearingPoint"):
		return has_rooted_point_bearing_seat(bearer, seat, seat_fact, visited)
	var bearer_face := String(seat_fact.get("bearerFace", seat_fact.get("localEnd", "")))
	var seat_face := String(seat_fact.get("seatFace", ""))
	if bearer_face not in ["min_x", "max_x", "min_y", "max_y", "min_z", "max_z"] or seat_face not in ["min_x", "max_x", "min_y", "max_y", "min_z", "max_z"]:
		return false
	var bearer_plane := face_plane_world(bearer, bearer_face)
	var seat_plane := face_plane_world(seat, seat_face)
	var bearer_normal: Vector3 = bearer_plane.get("normal", Vector3.UP) as Vector3
	var seat_normal: Vector3 = seat_plane.get("normal", Vector3.DOWN) as Vector3
	var bearer_point: Vector3 = bearer_plane.get("point", Vector3.ZERO) as Vector3
	var seat_point: Vector3 = seat_plane.get("point", Vector3.ZERO) as Vector3
	var opposing_faces := bearer_normal.dot(seat_normal) <= -0.98
	var normal_gap := absf((seat_point - bearer_point).dot(bearer_normal))
	if not opposing_faces or normal_gap > PHYSICAL_CONTACT_MARGIN:
		return false
	var bearer_patch_center: Vector3 = part_inverse_transform(seat) * (bearer_plane.get("point", Vector3.ZERO) as Vector3)
	var patch_in_seat := face_patch_within_seat(bearer, bearer_face, seat, seat_face, bearer_patch_center)
	return patch_in_seat and has_rooted_support_chain(seat, visited)


func has_rooted_gravity_bearing_patch(bearer, seat, seat_fact: Dictionary, visited: Dictionary = {}) -> bool:
	var local_patch_center: Vector3 = seat_fact.get("localPatchCenter", Vector3.INF) as Vector3
	var local_patch_half_extents: Vector2 = seat_fact.get("localPatchHalfExtents", Vector2.INF) as Vector2
	if local_patch_center == Vector3.INF or local_patch_half_extents == Vector2.INF or String(seat_fact.get("seatFace", "")) != "max_y":
		return false
	if absf(local_patch_center.y + bearer.size.y * 0.5) > PHYSICAL_CONTACT_MARGIN or local_patch_half_extents.x <= 0.0 or local_patch_half_extents.y <= 0.0:
		return false
	if absf(local_patch_center.x) + local_patch_half_extents.x > bearer.size.x * 0.5 - PHYSICAL_CONTACT_MARGIN or absf(local_patch_center.z) + local_patch_half_extents.y > bearer.size.z * 0.5 - PHYSICAL_CONTACT_MARGIN:
		return false
	var seat_plane := face_plane_world(seat, "max_y")
	var seat_point: Vector3 = seat_plane.get("point", Vector3.ZERO) as Vector3
	for local_offset in [Vector2.ZERO, Vector2(-local_patch_half_extents.x, -local_patch_half_extents.y), Vector2(-local_patch_half_extents.x, local_patch_half_extents.y), Vector2(local_patch_half_extents.x, -local_patch_half_extents.y), Vector2(local_patch_half_extents.x, local_patch_half_extents.y)]:
		var local_point := local_patch_center + Vector3(local_offset.x, 0.0, local_offset.y)
		var point_in_seat := part_inverse_transform(seat) * (part_transform(bearer) * local_point)
		if absf(point_in_seat.y - seat.size.y * 0.5) > PHYSICAL_CONTACT_MARGIN:
			return false
		if absf(point_in_seat.x) > seat.size.x * 0.5 - PHYSICAL_CONTACT_MARGIN or absf(point_in_seat.z) > seat.size.z * 0.5 - PHYSICAL_CONTACT_MARGIN:
			return false
		var world_point := part_transform(bearer) * local_point
		if absf(world_point.y - seat_point.y) > PHYSICAL_CONTACT_MARGIN:
			return false
	return has_rooted_support_chain(seat, visited)


func gravity_bearing_diagnostics(bearer, seat, seat_fact: Dictionary) -> Dictionary:
	var local_patch_center: Vector3 = seat_fact.get("localPatchCenter", Vector3.INF) as Vector3
	var local_patch_half_extents: Vector2 = seat_fact.get("localPatchHalfExtents", Vector2.INF) as Vector2
	var result := {"hasValidInputs": bearer != null and seat != null and local_patch_center != Vector3.INF and local_patch_half_extents != Vector2.INF, "bearerSize": bearer.size if bearer != null else Vector3.ZERO, "seatSize": seat.size if seat != null else Vector3.ZERO, "points": [], "rootedSeat": false}
	if not bool(result.get("hasValidInputs", false)):
		return result
	for local_offset in [Vector2.ZERO, Vector2(-local_patch_half_extents.x, -local_patch_half_extents.y), Vector2(-local_patch_half_extents.x, local_patch_half_extents.y), Vector2(local_patch_half_extents.x, -local_patch_half_extents.y), Vector2(local_patch_half_extents.x, local_patch_half_extents.y)]:
		var local_point := local_patch_center + Vector3(local_offset.x, 0.0, local_offset.y)
		result["points"].append(part_inverse_transform(seat) * (part_transform(bearer) * local_point))
	result["rootedSeat"] = has_rooted_support_chain(seat, {})
	return result


func attachment_socket_diagnostics(attachment, anchor_fact: Dictionary) -> Dictionary:
	var anchor = find_part(String(anchor_fact.get("anchorId", "")))
	var local_center: Vector3 = anchor_fact.get("localMountCenter", Vector3.INF) as Vector3
	var local_half_extents: Vector3 = anchor_fact.get("localMountHalfExtents", Vector3.INF) as Vector3
	var result := {"hasValidInputs": attachment != null and anchor != null and local_center != Vector3.INF and local_half_extents != Vector3.INF, "anchorSize": anchor.size if anchor != null else Vector3.ZERO, "cornerAnchorPositions": [], "rootedAnchor": false}
	if not bool(result.get("hasValidInputs", false)):
		return result
	for x_sign in [-1.0, 1.0]:
		for y_sign in [-1.0, 1.0]:
			for z_sign in [-1.0, 1.0]:
				var mount_point := local_center + Vector3(local_half_extents.x * x_sign, local_half_extents.y * y_sign, local_half_extents.z * z_sign)
				result["cornerAnchorPositions"].append(part_inverse_transform(anchor) * (part_transform(attachment) * mount_point))
	result["rootedAnchor"] = has_rooted_support_chain(anchor, {})
	return result


func has_rooted_housed_overlap(bearer, seat, seat_fact: Dictionary, visited: Dictionary = {}) -> bool:
	var local_center: Vector3 = seat_fact.get("localOverlapCenter", Vector3.INF) as Vector3
	var local_half_extents: Vector3 = seat_fact.get("localOverlapHalfExtents", Vector3.INF) as Vector3
	if local_center == Vector3.INF or local_half_extents == Vector3.INF:
		return false
	if local_half_extents.x <= 0.0 or local_half_extents.y <= 0.0 or local_half_extents.z <= 0.0:
		return false
	var span_axis := local_span_axis_index(String(seat_fact.get("localSpanAxis", "z")))
	if span_axis < 0:
		return false
	if local_half_extents[span_axis] * 2.0 < maxf(STAIR_MIN_HOUSED_EMBEDMENT, float(seat_fact.get("minimumLongitudinalEmbedment", 0.0))):
		return false
	if local_half_extents.y * 2.0 < maxf(STAIR_MIN_HOUSED_VERTICAL_OVERLAP, float(seat_fact.get("minimumVerticalOverlap", 0.0))):
		return false
	for axis in [0, 1, 2]:
		if absf(local_center[axis]) + local_half_extents[axis] > bearer.size[axis] * 0.5 - STAIR_HOUSED_JOINT_INSET:
			return false
	for x_sign in [-1.0, 1.0]:
		for y_sign in [-1.0, 1.0]:
			for z_sign in [-1.0, 1.0]:
				var local_point := local_center + Vector3(local_half_extents.x * x_sign, local_half_extents.y * y_sign, local_half_extents.z * z_sign)
				var point_in_seat := part_inverse_transform(seat) * (part_transform(bearer) * local_point)
				for axis in [0, 1, 2]:
					if absf(point_in_seat[axis]) >= seat.size[axis] * 0.5 - STAIR_HOUSED_JOINT_INSET:
						return false
	return has_rooted_support_chain(seat, visited)


func housed_overlap_diagnostics(bearer, seat, seat_fact: Dictionary) -> Dictionary:
	var local_center: Vector3 = seat_fact.get("localOverlapCenter", Vector3.INF) as Vector3
	var local_half_extents: Vector3 = seat_fact.get("localOverlapHalfExtents", Vector3.INF) as Vector3
	var span_axis := local_span_axis_index(String(seat_fact.get("localSpanAxis", "z")))
	var result := {
		"hasValidInputs": bearer != null and seat != null and local_center != Vector3.INF and local_half_extents != Vector3.INF and span_axis >= 0,
		"insideBearer": false,
		"insideSeat": false,
		"longitudinalEmbedment": 0.0,
		"verticalOverlap": 0.0,
		"rootedSeat": false,
		"cornerSeatPositions": []
	}
	if not bool(result.get("hasValidInputs", false)):
		return result
	result["longitudinalEmbedment"] = local_half_extents[span_axis] * 2.0
	result["verticalOverlap"] = local_half_extents.y * 2.0
	var inside_bearer := true
	for axis in [0, 1, 2]:
		if absf(local_center[axis]) + local_half_extents[axis] > bearer.size[axis] * 0.5 - STAIR_HOUSED_JOINT_INSET:
			inside_bearer = false
	result["insideBearer"] = inside_bearer
	var inside_seat := true
	var corner_positions: Array[Vector3] = []
	for x_sign in [-1.0, 1.0]:
		for y_sign in [-1.0, 1.0]:
			for z_sign in [-1.0, 1.0]:
				var local_point := local_center + Vector3(local_half_extents.x * x_sign, local_half_extents.y * y_sign, local_half_extents.z * z_sign)
				var point_in_seat := part_inverse_transform(seat) * (part_transform(bearer) * local_point)
				corner_positions.append(point_in_seat)
				for axis in [0, 1, 2]:
					if absf(point_in_seat[axis]) >= seat.size[axis] * 0.5 - STAIR_HOUSED_JOINT_INSET:
						inside_seat = false
	result["insideSeat"] = inside_seat
	result["cornerSeatPositions"] = corner_positions
	result["rootedSeat"] = has_rooted_support_chain(seat, {})
	return result


func local_span_axis_index(axis_name: String) -> int:
	match axis_name:
		"x":
			return 0
		"y":
			return 1
		"z":
			return 2
	return -1


func has_rooted_attachment_socket(attachment, anchor_fact: Dictionary) -> bool:
	if String(anchor_fact.get("contactMode", "")) != "attachment_socket":
		return false
	var anchor = find_part(String(anchor_fact.get("anchorId", "")))
	var local_center: Vector3 = anchor_fact.get("localMountCenter", Vector3.INF) as Vector3
	var local_half_extents: Vector3 = anchor_fact.get("localMountHalfExtents", Vector3.INF) as Vector3
	if anchor == null or local_center == Vector3.INF or local_half_extents == Vector3.INF or local_half_extents.x <= 0.0 or local_half_extents.y <= 0.0 or local_half_extents.z <= 0.0:
		return false
	for x_sign in [-1.0, 1.0]:
		for y_sign in [-1.0, 1.0]:
			for z_sign in [-1.0, 1.0]:
				var mount_point := local_center + Vector3(local_half_extents.x * x_sign, local_half_extents.y * y_sign, local_half_extents.z * z_sign)
				var point_in_anchor := part_inverse_transform(anchor) * (part_transform(attachment) * mount_point)
				for axis in [0, 1, 2]:
					if absf(point_in_anchor[axis]) >= anchor.size[axis] * 0.5 - STAIR_HOUSED_JOINT_INSET:
						return false
	return bool(anchor.collision_enabled) and String(anchor.physical_intent) in ["structural_mass", "structural_root"] and has_rooted_support_chain(anchor, {})


func has_valid_stair_carriage_assembly(span) -> bool:
	var assembly_id := String(span.recipe.get("physicalStairAssemblyId", ""))
	var bearing_ids: Array = span.recipe.get("physicalRequiredAssemblyBearingBlockIds", []) as Array
	var joint_facts: Array = span.recipe.get("physicalRequiredSeatFacts", []) as Array
	if assembly_id.is_empty() or bearing_ids.size() != 2 or joint_facts.size() != 2 or String(span.recipe.get("physicalAssemblyRole", "")) != "stair_sloped_span":
		return false
	var expected_ids: Array[String] = []
	for bearing_id_value in bearing_ids:
		var bearing_id := String(bearing_id_value)
		var bearing = find_part(bearing_id)
		if bearing_id.is_empty() or expected_ids.has(bearing_id) or bearing == null:
			return false
		if String(bearing.recipe.get("physicalAssemblyRole", "")) != "stair_carriage_bearing_block" or String(bearing.recipe.get("physicalStairAssemblyId", "")) != assembly_id:
			return false
		expected_ids.append(bearing_id)
	var joint_ids: Array[String] = []
	for joint_fact_value in joint_facts:
		var joint_fact: Dictionary = joint_fact_value as Dictionary
		if String(joint_fact.get("contactMode", "")) != "housed_overlap":
			return false
		var seat_id := String(joint_fact.get("seatId", ""))
		if seat_id.is_empty() or joint_ids.has(seat_id) or not expected_ids.has(seat_id):
			return false
		joint_ids.append(seat_id)
	return joint_ids.size() == expected_ids.size()


func has_valid_roof_frame_assembly(panel) -> bool:
	var frame_id := String(panel.recipe.get("physicalRoofFrameId", ""))
	var member_ids: Array = panel.recipe.get("physicalRequiredRoofFramePartIds", []) as Array
	var joint_facts: Array = panel.recipe.get("physicalRequiredSeatFacts", []) as Array
	if frame_id.is_empty() or String(panel.recipe.get("physicalAssemblyRole", "")) != "roof_sloped_span" or member_ids.size() != 2 or joint_facts.size() != 2:
		return false
	var plate_id := String(member_ids[0])
	var ridge_id := String(member_ids[1])
	var plate = find_part(plate_id)
	var ridge = find_part(ridge_id)
	if plate_id.is_empty() or ridge_id.is_empty() or plate_id == ridge_id or plate == null or ridge == null:
		return false
	if String(plate.recipe.get("physicalAssemblyRole", "")) != "roof_wall_plate" or String(ridge.recipe.get("physicalAssemblyRole", "")) != "roof_ridge_beam":
		return false
	if String(plate.recipe.get("physicalRoofFrameId", "")) != frame_id or String(ridge.recipe.get("physicalRoofFrameId", "")) != frame_id:
		return false
	var expected_ids: Array[String] = [plate_id, ridge_id]
	var joint_ids: Array[String] = []
	for joint_fact_value in joint_facts:
		var joint_fact: Dictionary = joint_fact_value as Dictionary
		if String(joint_fact.get("contactMode", "")) != "housed_overlap" or String(joint_fact.get("localSpanAxis", "")) != "x":
			return false
		var seat_id := String(joint_fact.get("seatId", ""))
		if seat_id.is_empty() or joint_ids.has(seat_id) or not expected_ids.has(seat_id):
			return false
		joint_ids.append(seat_id)
	if joint_ids.size() != expected_ids.size():
		return false
	var post_ids: Array = ridge.recipe.get("physicalRequiredRoofFramePostIds", []) as Array
	var ridge_facts: Array = ridge.recipe.get("physicalRequiredSeatFacts", []) as Array
	if post_ids.size() != 2 or ridge_facts.size() != 2:
		return false
	var expected_post_ids: Array[String] = []
	for post_id_value in post_ids:
		var post_id := String(post_id_value)
		var post = find_part(post_id)
		if post_id.is_empty() or expected_post_ids.has(post_id) or post == null:
			return false
		if String(post.recipe.get("physicalAssemblyRole", "")) != "roof_king_post" or String(post.recipe.get("physicalRoofFrameId", "")) != frame_id:
			return false
		expected_post_ids.append(post_id)
	var ridge_joint_ids: Array[String] = []
	for ridge_fact_value in ridge_facts:
		var ridge_fact: Dictionary = ridge_fact_value as Dictionary
		if String(ridge_fact.get("contactMode", "")) != "housed_overlap" or String(ridge_fact.get("localSpanAxis", "")) != "z":
			return false
		var post_id := String(ridge_fact.get("seatId", ""))
		if post_id.is_empty() or ridge_joint_ids.has(post_id) or not expected_post_ids.has(post_id):
			return false
		ridge_joint_ids.append(post_id)
	return ridge_joint_ids.size() == expected_post_ids.size()


func has_rooted_point_bearing_seat(bearer, seat, seat_fact: Dictionary, visited: Dictionary = {}) -> bool:
	var bearing_point: Vector3 = seat_fact.get("bearingPoint", Vector3.INF) as Vector3
	var bearing_face := String(seat_fact.get("bearingFace", ""))
	var seat_face := String(seat_fact.get("seatFace", ""))
	if bearing_point == Vector3.INF or bearing_face not in ["min_x", "max_x", "min_y", "max_y", "min_z", "max_z"] or seat_face not in ["min_x", "max_x", "min_y", "max_y", "min_z", "max_z"]:
		return false
	var seat_plane := face_plane_world(seat, seat_face)
	var bearer_normal: Vector3 = seat_fact.get("bearingNormalWorld", face_plane_world(bearer, bearing_face).get("normal", Vector3.UP)) as Vector3
	var seat_normal: Vector3 = seat_plane.get("normal", Vector3.DOWN) as Vector3
	if bearer_normal.dot(seat_normal) > -0.98:
		return false
	var world_bearing_point := part_transform(bearer) * bearing_point
	var seat_point: Vector3 = seat_plane.get("point", Vector3.ZERO) as Vector3
	var normal_gap := absf((world_bearing_point - seat_point).dot(bearer_normal))
	if normal_gap > PHYSICAL_CONTACT_MARGIN:
		return false
	var point_in_seat := part_inverse_transform(seat) * world_bearing_point
	var seat_axis := face_axis(seat_face)
	for tangent_axis in [0, 1, 2]:
		if tangent_axis != seat_axis and absf(point_in_seat[tangent_axis]) > seat.size[tangent_axis] * 0.5 - PHYSICAL_CONTACT_MARGIN:
			return false
	return has_rooted_support_chain(seat, visited)


func face_plane_world(part, face: String) -> Dictionary:
	var axis: int = face_axis(face)
	var sign := -1.0 if face.begins_with("min_") else 1.0
	var local_origin := Vector3.ZERO
	local_origin[axis] = sign * part.size[axis] * 0.5
	var transform := part_transform(part)
	var local_normal := Vector3.RIGHT if axis == 0 else Vector3.UP if axis == 1 else Vector3.FORWARD
	var normal: Vector3 = (transform.basis * local_normal * sign).normalized()
	return {"normal": normal, "point": transform * local_origin}


func face_axis(face: String) -> int:
	match face.right(1):
		"x":
			return 0
		"y":
			return 1
		"z":
			return 2
	return -1


func face_patch_within_seat(bearer, bearer_face: String, seat, seat_face: String, bearer_plane_center_in_seat: Vector3) -> bool:
	var bearer_axis := face_axis(bearer_face)
	var seat_axis := face_axis(seat_face)
	if bearer_axis != seat_axis:
		return false
	var patch_half_extent := 0.04
	for first_axis in [0, 1, 2]:
		if first_axis == bearer_axis:
			continue
		var second_axis: int = 3 - bearer_axis - first_axis
		for first_sign in [-1.0, 1.0]:
			for second_sign in [-1.0, 1.0]:
				var local_point := Vector3.ZERO
				local_point[bearer_axis] = (-1.0 if bearer_face.begins_with("min_") else 1.0) * bearer.size[bearer_axis] * 0.5
				local_point[first_axis] = first_sign * minf(patch_half_extent, bearer.size[first_axis] * 0.5)
				local_point[second_axis] = second_sign * minf(patch_half_extent, bearer.size[second_axis] * 0.5)
				var point_in_seat := part_inverse_transform(seat) * (part_transform(bearer) * local_point)
				if absf(point_in_seat[first_axis]) > seat.size[first_axis] * 0.5 + PHYSICAL_CONTACT_MARGIN or absf(point_in_seat[second_axis]) > seat.size[second_axis] * 0.5 + PHYSICAL_CONTACT_MARGIN:
					return false
	return absf(bearer_plane_center_in_seat[seat_axis]) <= seat.size[seat_axis] * 0.5 + PHYSICAL_CONTACT_MARGIN


func coverage_has_rooted_supports(coverage: Array, expected_count: int, allowed_support_ids: Array = [], required_coverage_by_z: Array = [], required_coverage_by_x: Array = []) -> bool:
	if coverage.size() != expected_count:
		return false
	for sample_value in coverage:
		var sample: Dictionary = sample_value as Dictionary
		var support_id := String(sample.get("supportPartId", ""))
		var support = find_part(support_id)
		if support_id.is_empty() or support == null or not has_rooted_support_chain(support, {}) or not allowed_support_ids.is_empty() and not allowed_support_ids.has(support_id):
			return false
		if not required_coverage_by_z.is_empty() or not required_coverage_by_x.is_empty():
			var sample_tokens := String(sample.get("sample", "")).split("_", false)
			if sample_tokens.size() != 2:
				return false
			var x_index := int(sample_tokens[0])
			var z_index := int(sample_tokens[1])
			if not required_coverage_by_z.is_empty() and (z_index < 0 or z_index >= required_coverage_by_z.size() or support_id != String(required_coverage_by_z[z_index])):
				return false
			if not required_coverage_by_x.is_empty() and (x_index < 0 or x_index >= required_coverage_by_x.size() or support_id != String(required_coverage_by_x[x_index])):
				return false
	return true


func has_rooted_anchor_chain(part, visited: Dictionary) -> bool:
	var part_id := String(part.id)
	if visited.has(part_id):
		return false
	var next_visited := visited.duplicate()
	next_visited[part_id] = true
	var required_anchor_facts: Array = part.recipe.get("physicalRequiredAnchorFacts", []) as Array
	if not required_anchor_facts.is_empty():
		for anchor_fact_value in required_anchor_facts:
			var anchor_fact: Dictionary = anchor_fact_value as Dictionary
			var named_anchor = find_part(String(anchor_fact.get("anchorId", "")))
			if named_anchor == null or not has_rooted_attachment_socket(part, anchor_fact) or not has_rooted_support_chain(named_anchor, next_visited):
				return false
		return true
	for anchor_id_value in part.recipe.get("physicalAnchorPartIds", []) as Array:
		var anchor = find_part(String(anchor_id_value))
		if anchor != null and has_rooted_support_chain(anchor, next_visited):
			return true
	return false


func find_part(part_id: String):
	return physical_parts_by_id.get(part_id)


func snapshot() -> Dictionary:
	return {
		"id": id,
		"seed": seed,
		"style": style,
		"recipe": recipe.duplicate(true),
		"rooms": rooms.duplicate(true),
		"parts": part_snapshots()
	}


func deterministic_signature() -> String:
	return JSON.stringify(snapshot())
