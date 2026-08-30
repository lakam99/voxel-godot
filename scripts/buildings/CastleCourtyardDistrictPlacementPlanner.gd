extends RefCounted
class_name CastleCourtyardDistrictPlacementPlanner

## Deterministic post-blueprint placement authority for a castle courtyard
## district. This planner receives the already sampled residence family and
## recipe together with the actual source blueprint. It does not sample,
## resample, retry, rotate, omit, or replace a residence.
##
## Public input contract for plan() and validate_plan():
##
## intents: one Dictionary per required residence with these fields:
##   id: unique non-empty String
##   pairIndex: non-negative int
##   side: "left" or "right" (ordering/identity only; never collision filtering)
##   family: non-empty String
##   recipe: non-empty Dictionary
##   recipeHash: non-empty authoritative String
##   sourceBlueprint: the already-built source BuildingBlueprint
##   sourceBlueprintSignature: deterministic signature of that exact blueprint
##   sourceSpec: the complete sampled residence spec (district/facade facts)
##   nominalCenter: Vector3 horizontal placement intent
##   frontDirection: one of north/south/east/west
##   elevation: finite terrace elevation
##   foundationElevation: finite courtyard foundation-top elevation
##
## street_records: sampler-owned Dictionaries with id, x, z, width and depth.
## structure_parts: exact collision descriptors (center/size/basis) produced
## from actual collision-enabled keep/tower/forecourt parts.
## courtyard_bounds: {minX, maxX, minZ, maxZ} in the compound's local frame.
## options may override fixedClearance, residenceClearance and boundaryClearance
## with finite, non-negative values.
##
## CastleResidencePlacementGeometry is the sole physical geometry authority.
## Its expected static API is:
##   describe_residence(spec, sourceBlueprint, foundationElevation) -> Dictionary
##   composition_blocker(composition: Dictionary) -> Dictionary
##   compositions_overlap(left, right, clearance) -> bool
##   composition_overlaps_obstacles(composition, obstacles, clearance) -> bool
##   footprint_overlaps(center/size pairs, clearance) -> bool
##   composition_fits_bounds(composition, width, depth, inset) -> bool
##
## describe_residence() receives a sourceSpec augmented with id/family/recipe,
## center/origin/yaw/frontDirection/elevation and returns an exact immutable
## composition with an aggregateFootprint. The planner serializes that exact
## composition into its own deterministic composition signature.

const CastleResidencePlacementGeometryScript := preload("res://scripts/buildings/CastleResidencePlacementGeometry.gd")
const BuildingBlueprintScript := preload("res://scripts/buildings/BuildingBlueprint.gd")

const SCHEMA_VERSION := 1
const DEFAULT_FIXED_CLEARANCE := 0.04
const DEFAULT_RESIDENCE_CLEARANCE := 0.08
const DEFAULT_PAIR_CLEARANCE := 2.60
const DEFAULT_BOUNDARY_CLEARANCE := 0.0
const EPSILON := 0.00001


static func plan(intents: Array, street_records: Array, structure_parts: Array, courtyard_bounds: Dictionary, options: Dictionary = {}) -> Dictionary:
	var telemetry := _new_telemetry(intents.size(), street_records.size(), structure_parts.size())
	var input_check := _validate_inputs(intents, street_records, structure_parts, courtyard_bounds, options)
	if not bool(input_check.get("passed", false)):
		return _infeasible(intents.size(), telemetry, input_check.get("rejections", []) as Array, "invalid_input")
	var settings: Dictionary = input_check.get("settings", {}) as Dictionary
	var ordered_intents: Array[Dictionary] = []
	for value in intents:
		ordered_intents.append(value as Dictionary)
	ordered_intents.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return _intent_precedes(left, right))
	var street_footprints: Array[Dictionary] = []
	for street_value in street_records:
		street_footprints.append(_street_footprint(street_value as Dictionary))
	street_footprints.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return String(left.get("id", "")) < String(right.get("id", "")))
	var ordered_structure_parts := _ordered_structure_parts(structure_parts)
	var fixed_blockers_result := _fixed_blockers(street_footprints, ordered_structure_parts, telemetry)
	if not bool(fixed_blockers_result.get("passed", false)):
		return _infeasible(intents.size(), telemetry, fixed_blockers_result.get("rejections", []) as Array, "invalid_obstacle_geometry")
	var fixed_blockers: Array[Dictionary] = fixed_blockers_result.get("blockers", []) as Array[Dictionary]
	var placements: Array[Dictionary] = []
	var placed_compositions: Array[Dictionary] = []
	var placed_blockers: Array[Dictionary] = []
	var nominal_centers: Array[Vector3] = []
	for intent in ordered_intents:
		var placement_result := _place_one(intent, courtyard_bounds, settings, fixed_blockers, street_footprints, ordered_structure_parts, placements, placed_compositions, placed_blockers, nominal_centers, telemetry)
		if not bool(placement_result.get("passed", false)):
			return _infeasible(intents.size(), telemetry, placement_result.get("rejections", []) as Array, String(placement_result.get("phase", "placement")))
		var placement: Dictionary = placement_result.get("placement", {}) as Dictionary
		placements.append(placement)
		placed_compositions.append((placement.get("composition", {}) as Dictionary).duplicate(true))
		placed_blockers.append((placement_result.get("blocker", {}) as Dictionary).duplicate(true))
		nominal_centers.append(intent.get("nominalCenter", Vector3.ZERO) as Vector3)
	var telemetry_rejections: Array[Dictionary] = []
	_validate_telemetry_bounds(telemetry, telemetry_rejections)
	if not telemetry_rejections.is_empty():
		return _infeasible(intents.size(), telemetry, telemetry_rejections, "telemetry")
	var ready := _ready_plan(placements, intents.size(), telemetry)
	var validation := validate_plan(ready, intents, street_records, structure_parts, courtyard_bounds, settings)
	ready["validation"] = validation.duplicate(true)
	if not bool(validation.get("passed", false)):
		return _infeasible(intents.size(), telemetry, validation.get("rejections", []) as Array, "final_validation")
	return ready


static func validate_plan(candidate_plan: Dictionary, intents: Array, street_records: Array, structure_parts: Array, courtyard_bounds: Dictionary, options: Dictionary = {}) -> Dictionary:
	var telemetry := _new_telemetry(intents.size(), street_records.size(), structure_parts.size())
	var rejections: Array[Dictionary] = []
	var input_check := _validate_inputs(intents, street_records, structure_parts, courtyard_bounds, options)
	if not bool(input_check.get("passed", false)):
		return _validation_result(false, telemetry, input_check.get("rejections", []) as Array)
	var settings: Dictionary = input_check.get("settings", {}) as Dictionary
	if String(candidate_plan.get("status", "")) != "ready" or int(candidate_plan.get("schemaVersion", -1)) != SCHEMA_VERSION:
		rejections.append(_rejection("plan_not_ready", "validation", "", -1, "", {"status": candidate_plan.get("status", null), "schemaVersion": candidate_plan.get("schemaVersion", null)}))
		return _validation_result(false, telemetry, rejections)
	var placements_value = candidate_plan.get("placements", null)
	if not placements_value is Array:
		rejections.append(_rejection("placements_not_array", "validation", "", -1, "", {}))
		return _validation_result(false, telemetry, rejections)
	var placements: Array = placements_value as Array
	if placements.size() != intents.size() or int(candidate_plan.get("intentCount", -1)) != intents.size() or int(candidate_plan.get("placementCount", -1)) != intents.size():
		rejections.append(_rejection("intent_cardinality_mismatch", "validation", "", -1, "", {"intentCount": intents.size(), "placementCount": placements.size(), "declaredIntentCount": candidate_plan.get("intentCount", null), "declaredPlacementCount": candidate_plan.get("placementCount", null)}))
		return _validation_result(false, telemetry, rejections)
	var intents_by_id := {}
	var ordered_intents: Array[Dictionary] = []
	for intent_value in intents:
		var intent: Dictionary = intent_value as Dictionary
		intents_by_id[String(intent.get("id", ""))] = intent
		ordered_intents.append(intent)
	ordered_intents.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return _intent_precedes(left, right))
	var seen := {}
	var validated_placements: Array[Dictionary] = []
	var validated_compositions: Array[Dictionary] = []
	var street_footprints: Array[Dictionary] = []
	for street_value in street_records:
		street_footprints.append(_street_footprint(street_value as Dictionary))
	street_footprints.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return String(left.get("id", "")) < String(right.get("id", "")))
	var ordered_structure_parts := _ordered_structure_parts(structure_parts)
	for placement_index in range(placements.size()):
		if not placements[placement_index] is Dictionary:
			rejections.append(_rejection("placement_not_dictionary", "validation", "", -1, "", {"placementIndex": placement_index}))
			continue
		var placement: Dictionary = placements[placement_index] as Dictionary
		var identity := String(placement.get("id", ""))
		if placement_index >= ordered_intents.size() or identity != String(ordered_intents[placement_index].get("id", "")):
			rejections.append(_rejection("unstable_placement_order", "validation", identity, int(placement.get("pairIndex", -1)), String(placement.get("side", "")), {"placementIndex": placement_index, "expectedIntentId": String(ordered_intents[placement_index].get("id", "")) if placement_index < ordered_intents.size() else ""}))
			continue
		if not intents_by_id.has(identity):
			rejections.append(_rejection("unknown_placement_identity", "validation", identity, int(placement.get("pairIndex", -1)), String(placement.get("side", "")), {}))
			continue
		if seen.has(identity):
			rejections.append(_rejection("duplicate_placement_identity", "validation", identity, int(placement.get("pairIndex", -1)), String(placement.get("side", "")), {}))
			continue
		seen[identity] = true
		var intent: Dictionary = intents_by_id[identity] as Dictionary
		if not _placement_preserves_intent(placement, intent):
			rejections.append(_rejection("placement_changed_source_intent", "validation", identity, int(intent.get("pairIndex", -1)), String(intent.get("side", "")), {}))
			continue
		var center_value = placement.get("center", null)
		var origin_value = placement.get("origin", null)
		if not center_value is Vector3 or not origin_value is Vector3 or not _finite_vector3(center_value as Vector3) or not _finite_vector3(origin_value as Vector3):
			rejections.append(_rejection("invalid_placement_transform", "validation", identity, int(intent.get("pairIndex", -1)), String(intent.get("side", "")), {}))
			continue
		var description := _describe(intent, center_value as Vector3, telemetry)
		if not bool(description.get("passed", false)):
			rejections.append(_rejection("invalid_recomputed_composition", "validation", identity, int(intent.get("pairIndex", -1)), String(intent.get("side", "")), {"geometryReason": description.get("reason", "") }))
			continue
		var composition: Dictionary = description.get("composition", {}) as Dictionary
		var stored_composition_value = placement.get("composition", null)
		var expected_origin: Vector3 = description.get("origin", Vector3.ZERO) as Vector3
		var expected_signature := _placement_signature(intent, center_value as Vector3, expected_origin, composition)
		if not stored_composition_value is Dictionary or (stored_composition_value as Dictionary) != composition or _composition_signature(stored_composition_value as Dictionary) != _composition_signature(composition) or not (origin_value as Vector3).is_equal_approx(expected_origin) or String(placement.get("compositionSignature", "")) != _composition_signature(composition) or String(placement.get("placementSignature", "")) != expected_signature:
			rejections.append(_rejection("placement_signature_mismatch", "validation", identity, int(intent.get("pairIndex", -1)), String(intent.get("side", "")), {}))
			continue
		if not _counts_match(placement, composition):
			rejections.append(_rejection("composition_count_mismatch", "validation", identity, int(intent.get("pairIndex", -1)), String(intent.get("side", "")), {}))
			continue
		var exact := _validate_exact_constraints(intent, composition, street_footprints, ordered_structure_parts, validated_placements, validated_compositions, courtyard_bounds, settings, telemetry)
		if not bool(exact.get("passed", false)):
			rejections.append_array(exact.get("rejections", []) as Array)
			continue
		validated_placements.append(placement)
		validated_compositions.append(composition)
	for intent_id in intents_by_id:
		if not seen.has(intent_id):
			var missing: Dictionary = intents_by_id[intent_id] as Dictionary
			rejections.append(_rejection("missing_placement_identity", "validation", String(intent_id), int(missing.get("pairIndex", -1)), String(missing.get("side", "")), {}))
	var expected_plan_signature := _plan_signature(validated_placements, intents.size()) if rejections.is_empty() else ""
	if rejections.is_empty() and String(candidate_plan.get("placementSignature", "")) != expected_plan_signature:
		rejections.append(_rejection("plan_signature_mismatch", "validation", "", -1, "", {"expected": expected_plan_signature, "actual": candidate_plan.get("placementSignature", "")}))
	if rejections.is_empty() and not _plan_summary_matches(candidate_plan, validated_placements, intents.size()):
		rejections.append(_rejection("plan_summary_mismatch", "validation", "", -1, "", {}))
	_validate_telemetry_bounds(telemetry, rejections)
	return _validation_result(rejections.is_empty(), telemetry, rejections)


static func _place_one(intent: Dictionary, courtyard_bounds: Dictionary, settings: Dictionary, fixed_blockers: Array[Dictionary], street_footprints: Array[Dictionary], structure_parts: Array, placements: Array[Dictionary], placed_compositions: Array[Dictionary], placed_blockers: Array[Dictionary], nominal_centers: Array[Vector3], telemetry: Dictionary) -> Dictionary:
	var nominal_center: Vector3 = intent.get("nominalCenter", Vector3.ZERO) as Vector3
	var center := nominal_center
	var description := _describe(intent, center, telemetry)
	if not bool(description.get("passed", false)):
		return _placement_failure("invalid_composition", "description", intent, {"geometryReason": description.get("reason", "")})
	var composition: Dictionary = description.get("composition", {}) as Dictionary
	var blocker_bounds := _composition_bounds(composition)
	if blocker_bounds.is_empty():
		return _placement_failure("missing_composition_blocker", "description", intent, {})
	var progression_sign := _progression_sign(nominal_center, nominal_centers, courtyard_bounds)
	var z_delta := 0.0
	var prior_encounter_order := _clearance_adjusted_prior_encounter_order(placed_blockers, placements, int(intent.get("pairIndex", -1)), progression_sign, settings)
	var traversed_prior_tokens := PackedStringArray()
	for prior_index in prior_encounter_order:
		var prior_id := String(placements[prior_index].get("id", "")) if prior_index < placements.size() else ""
		var prior_pair_index := int(placements[prior_index].get("pairIndex", -2)) if prior_index < placements.size() else -2
		traversed_prior_tokens.append("%d:%s:%d:%d" % [prior_id.length(), prior_id, prior_index, prior_pair_index])
		telemetry["algebraicPriorComparisons"] = int(telemetry.get("algebraicPriorComparisons", 0)) + 1
		var shifted := _shift_bounds(blocker_bounds, 0.0, z_delta)
		var prior_clearance := float(settings.get("pairClearance", DEFAULT_PAIR_CLEARANCE)) if prior_pair_index == int(intent.get("pairIndex", -1)) else float(settings.get("residenceClearance", DEFAULT_RESIDENCE_CLEARANCE))
		if _footprints_overlap(shifted, placed_blockers[prior_index], prior_clearance):
			z_delta = _monotonic_axis_delta(blocker_bounds, placed_blockers[prior_index], "z", progression_sign, prior_clearance, z_delta)
	_record_prior_traversal(telemetry, intent, progression_sign, traversed_prior_tokens)
	if absf(z_delta) > EPSILON:
		center.z += z_delta
		description = _describe(intent, center, telemetry)
		if not bool(description.get("passed", false)):
			return _placement_failure("invalid_composition_after_row_pack", "row_pack", intent, {"geometryReason": description.get("reason", "")})
		composition = description.get("composition", {}) as Dictionary
		blocker_bounds = _composition_bounds(composition)
	var row_packed_center := center
	var row_packed_composition := composition
	var outward_sign := _outward_sign(nominal_center, courtyard_bounds)
	if outward_sign == 0:
		return _placement_failure("ambiguous_outward_domain", "fixed_pack", intent, {"nominalCenter": nominal_center})
	var x_delta := 0.0
	for fixed in fixed_blockers:
		telemetry["algebraicObstacleComparisons"] = int(telemetry.get("algebraicObstacleComparisons", 0)) + 1
		var shifted := _shift_bounds(blocker_bounds, x_delta, 0.0)
		var fixed_bounds: Dictionary = fixed.get("bounds", {}) as Dictionary
		if _footprints_overlap(shifted, fixed_bounds, float(settings.get("fixedClearance", DEFAULT_FIXED_CLEARANCE))):
			x_delta = _monotonic_axis_delta(blocker_bounds, fixed_bounds, "x", outward_sign, float(settings.get("fixedClearance", DEFAULT_FIXED_CLEARANCE)), x_delta)
	if absf(x_delta) > EPSILON:
		center.x += x_delta
		description = _describe(intent, center, telemetry)
		if not bool(description.get("passed", false)):
			return _placement_failure("invalid_composition_after_fixed_pack", "fixed_pack", intent, {"geometryReason": description.get("reason", "")})
		composition = description.get("composition", {}) as Dictionary
		blocker_bounds = _composition_bounds(composition)
	var fixed_packed_center := center
	var fixed_packed_composition := composition
	var boundary_delta := _boundary_adjustment(blocker_bounds, courtyard_bounds, float(settings.get("boundaryClearance", DEFAULT_BOUNDARY_CLEARANCE)))
	if not bool(boundary_delta.get("possible", false)):
		return _placement_failure("composition_exceeds_courtyard_domain", "boundary", intent, {"blocker": blocker_bounds, "bounds": courtyard_bounds})
	var adjustment: Vector2 = boundary_delta.get("delta", Vector2.ZERO) as Vector2
	if adjustment.length_squared() > EPSILON * EPSILON:
		telemetry["boundaryAdjustments"] = int(telemetry.get("boundaryAdjustments", 0)) + 1
		center.x += adjustment.x
		center.z += adjustment.y
		description = _describe(intent, center, telemetry)
		if not bool(description.get("passed", false)):
			return _placement_failure("invalid_composition_after_boundary_adjustment", "boundary", intent, {"geometryReason": description.get("reason", "")})
		composition = description.get("composition", {}) as Dictionary
		blocker_bounds = _composition_bounds(composition)
	var exact := _validate_exact_constraints(intent, composition, street_footprints, structure_parts, placements, placed_compositions, courtyard_bounds, settings, telemetry)
	if not bool(exact.get("passed", false)):
		var annotated_rejections := _annotate_prior_overlap_rejections(exact.get("rejections", []) as Array, intent, placements, placed_compositions, nominal_center, row_packed_center, row_packed_composition, fixed_packed_center, fixed_packed_composition, center, settings)
		return {"passed": false, "phase": "exact_revalidation", "rejections": annotated_rejections}
	var origin: Vector3 = description.get("origin", Vector3.ZERO) as Vector3
	var record := _placement_record(intent, center, origin, composition)
	return {"passed": true, "placement": record, "blocker": blocker_bounds}


static func _annotate_prior_overlap_rejections(rejection_values: Array, intent: Dictionary, prior_placements: Array[Dictionary], prior_compositions: Array[Dictionary], nominal_center: Vector3, row_packed_center: Vector3, row_packed_composition: Dictionary, fixed_packed_center: Vector3, fixed_packed_composition: Dictionary, final_center: Vector3, settings: Dictionary) -> Array:
	var result: Array = []
	var pair_index := int(intent.get("pairIndex", -1))
	for rejection_value in rejection_values:
		if not rejection_value is Dictionary:
			result.append(rejection_value)
			continue
		var rejection: Dictionary = (rejection_value as Dictionary).duplicate(true)
		if String(rejection.get("code", "")) != "prior_residence_overlap":
			result.append(rejection)
			continue
		var original_details: Dictionary = rejection.get("details", {}) as Dictionary
		var prior_index := int(original_details.get("priorIndex", -1))
		if prior_index < 0 or prior_index >= prior_placements.size() or prior_index >= prior_compositions.size():
			result.append(rejection)
			continue
		var prior_pair_index := int(prior_placements[prior_index].get("pairIndex", -2))
		var prior_clearance := float(settings.get("pairClearance", DEFAULT_PAIR_CLEARANCE)) if prior_pair_index == pair_index else float(settings.get("residenceClearance", DEFAULT_RESIDENCE_CLEARANCE))
		var prior_composition: Dictionary = prior_compositions[prior_index]
		rejection["details"] = {
			"priorResidenceId": String(original_details.get("priorResidenceId", "")),
			"priorIndex": prior_index,
			"nominalCenter": nominal_center,
			"rowPackedCenter": row_packed_center,
			"fixedPackedCenter": fixed_packed_center,
			"finalCenter": final_center,
			"rowPackDeltaZ": row_packed_center.z - nominal_center.z,
			"fixedPackDeltaX": fixed_packed_center.x - row_packed_center.x,
			"boundaryDeltaX": final_center.x - fixed_packed_center.x,
			"boundaryDeltaZ": final_center.z - fixed_packed_center.z,
			"overlapAfterRowPack": CastleResidencePlacementGeometryScript.compositions_overlap(row_packed_composition, prior_composition, prior_clearance),
			"overlapAfterFixedPack": CastleResidencePlacementGeometryScript.compositions_overlap(fixed_packed_composition, prior_composition, prior_clearance)
		}
		result.append(rejection)
	return result


static func _validate_exact_constraints(intent: Dictionary, composition: Dictionary, street_footprints: Array[Dictionary], structure_parts: Array, prior_placements: Array[Dictionary], prior_compositions: Array[Dictionary], courtyard_bounds: Dictionary, settings: Dictionary, telemetry: Dictionary) -> Dictionary:
	var rejections: Array[Dictionary] = []
	var identity := String(intent.get("id", ""))
	var pair_index := int(intent.get("pairIndex", -1))
	var side := String(intent.get("side", ""))
	var aggregate = composition.get("aggregateFootprint", null)
	if not aggregate is Dictionary or (aggregate as Dictionary).is_empty():
		rejections.append(_rejection("missing_aggregate_footprint", "exact_revalidation", identity, pair_index, side, {}))
		return {"passed": false, "rejections": rejections}
	for street in street_footprints:
		telemetry["exactStreetComparisons"] = int(telemetry.get("exactStreetComparisons", 0)) + 1
		if _footprints_overlap(aggregate as Dictionary, street, float(settings.get("fixedClearance", DEFAULT_FIXED_CLEARANCE))):
			rejections.append(_rejection("street_overlap", "exact_revalidation", identity, pair_index, side, {"streetId": street.get("id", "")}))
	for structure_index in range(structure_parts.size()):
		telemetry["exactStructureComparisons"] = int(telemetry.get("exactStructureComparisons", 0)) + 1
		if CastleResidencePlacementGeometryScript.composition_overlaps_obstacles(composition, [structure_parts[structure_index]], float(settings.get("fixedClearance", DEFAULT_FIXED_CLEARANCE))):
			rejections.append(_rejection("structure_overlap", "exact_revalidation", identity, pair_index, side, {"structurePartId": _part_id(structure_parts[structure_index]), "structureIndex": structure_index}))
	for prior_index in range(prior_compositions.size()):
		telemetry["exactPriorComparisons"] = int(telemetry.get("exactPriorComparisons", 0)) + 1
		var prior_pair_index := int(prior_placements[prior_index].get("pairIndex", -2)) if prior_index < prior_placements.size() else -2
		var prior_clearance := float(settings.get("pairClearance", DEFAULT_PAIR_CLEARANCE)) if prior_pair_index == pair_index else float(settings.get("residenceClearance", DEFAULT_RESIDENCE_CLEARANCE))
		if CastleResidencePlacementGeometryScript.compositions_overlap(composition, prior_compositions[prior_index], prior_clearance):
			var prior_id := String(prior_placements[prior_index].get("id", "")) if prior_index < prior_placements.size() else ""
			rejections.append(_rejection("prior_residence_overlap", "exact_revalidation", identity, pair_index, side, {"priorResidenceId": prior_id, "priorIndex": prior_index}))
	telemetry["boundsChecks"] = int(telemetry.get("boundsChecks", 0)) + 1
	if not _composition_fits_bounds(composition, courtyard_bounds, float(settings.get("boundaryClearance", DEFAULT_BOUNDARY_CLEARANCE))):
		rejections.append(_rejection("outside_courtyard_bounds", "exact_revalidation", identity, pair_index, side, {"bounds": courtyard_bounds.duplicate(true)}))
	return {"passed": rejections.is_empty(), "rejections": rejections}


static func _describe(intent: Dictionary, center: Vector3, telemetry: Dictionary) -> Dictionary:
	telemetry["descriptionCalls"] = int(telemetry.get("descriptionCalls", 0)) + 1
	var recipe: Dictionary = intent.get("recipe", {}) as Dictionary
	var elevation := float(intent.get("elevation", 0.0))
	var origin := Vector3(center.x, float(intent.get("foundationElevation", 0.0)) - float(recipe.get("foundationHeight", 0.0)) + elevation, center.z)
	var front_direction := String(intent.get("frontDirection", ""))
	var yaw := _yaw_for_front(front_direction)
	var swaps_axes := front_direction in ["east", "west"]
	var world_width := float(recipe.get("depth", 0.0)) if swaps_axes else float(recipe.get("width", 0.0))
	var world_depth := float(recipe.get("width", 0.0)) if swaps_axes else float(recipe.get("depth", 0.0))
	var spec: Dictionary = (intent.get("sourceSpec", {}) as Dictionary).duplicate(true)
	spec.merge({
		"id": String(intent.get("id", "")),
		"family": String(intent.get("family", "")),
		"recipe": recipe.duplicate(true),
		"residenceRecipe": recipe.duplicate(true),
		"recipeHash": String(intent.get("recipeHash", "")),
		"center": center,
		"origin": origin,
		"yaw": yaw,
		"frontDirection": front_direction,
		"elevation": elevation,
		"terraceElevation": elevation,
		"width": world_width,
		"depth": world_depth
	}, true)
	var composition = CastleResidencePlacementGeometryScript.describe_residence(spec, intent.get("sourceBlueprint", null), float(intent.get("foundationElevation", 0.0)))
	if not composition is Dictionary or (composition as Dictionary).is_empty():
		return {"passed": false, "reason": "empty_geometry_description"}
	var typed: Dictionary = composition as Dictionary
	var blocker = CastleResidencePlacementGeometryScript.composition_blocker(typed)
	telemetry["blockerCalls"] = int(telemetry.get("blockerCalls", 0)) + 1
	if not blocker is Dictionary or not (blocker as Dictionary).is_empty():
		return {"passed": false, "reason": "invalid_composition", "compositionBlocker": blocker}
	if _composition_bounds(typed).is_empty():
		return {"passed": false, "reason": "missing_aggregate_footprint"}
	return {"passed": true, "composition": typed, "origin": origin}


static func _fixed_blockers(street_footprints: Array[Dictionary], structure_parts: Array, telemetry: Dictionary) -> Dictionary:
	var blockers: Array[Dictionary] = []
	var rejections: Array[Dictionary] = []
	for street in street_footprints:
		var bounds := _footprint_bounds(street)
		if bounds.is_empty():
			rejections.append(_rejection("invalid_street_blocker", "obstacle_description", "", -1, "", {"streetId": street.get("id", "")}))
		else:
			blockers.append({"kind": "street", "id": street.get("id", ""), "bounds": bounds})
	for part_index in range(structure_parts.size()):
		var part: Dictionary = structure_parts[part_index] as Dictionary
		var rect := CastleResidencePlacementGeometryScript.part_horizontal_bounds(part)
		var blocker := _rect_bounds(rect)
		if blocker.is_empty():
			rejections.append(_rejection("invalid_structure_blocker", "obstacle_description", "", -1, "", {"structurePartId": _part_id(structure_parts[part_index]), "structureIndex": part_index}))
		else:
			blockers.append({"kind": "structure", "id": _part_id(structure_parts[part_index]), "bounds": blocker})
	return {"passed": rejections.is_empty(), "blockers": blockers, "rejections": rejections}


static func _validate_inputs(intents: Array, street_records: Array, structure_parts: Array, courtyard_bounds: Dictionary, options: Dictionary) -> Dictionary:
	var rejections: Array[Dictionary] = []
	var bounds := _normalized_bounds(courtyard_bounds)
	if bounds.is_empty():
		rejections.append(_rejection("invalid_courtyard_bounds", "input", "", -1, "", {"bounds": courtyard_bounds}))
	elif absf(float(bounds.get("minX", 0.0)) + float(bounds.get("maxX", 0.0))) > EPSILON or absf(float(bounds.get("minZ", 0.0)) + float(bounds.get("maxZ", 0.0))) > EPSILON:
		# The shared exact geometry API defines Citadel bounds around the compound
		# origin. Reject a shifted domain instead of silently using another frame.
		rejections.append(_rejection("courtyard_bounds_not_origin_centered", "input", "", -1, "", {"bounds": bounds}))
	var settings := {
		"fixedClearance": options.get("fixedClearance", DEFAULT_FIXED_CLEARANCE),
		"residenceClearance": options.get("residenceClearance", DEFAULT_RESIDENCE_CLEARANCE),
		"pairClearance": options.get("pairClearance", DEFAULT_PAIR_CLEARANCE),
		"boundaryClearance": options.get("boundaryClearance", DEFAULT_BOUNDARY_CLEARANCE)
	}
	for key in settings:
		var value = settings[key]
		if not (value is float or value is int) or not is_finite(float(value)) or float(value) < 0.0:
			rejections.append(_rejection("invalid_clearance", "input", "", -1, "", {"key": key, "value": value}))
	var identities := {}
	var pair_sides := {}
	var street_ids := {}
	var structure_ids := {}
	for index in range(intents.size()):
		if not intents[index] is Dictionary:
			rejections.append(_rejection("intent_not_dictionary", "input", "", -1, "", {"intentIndex": index}))
			continue
		var intent: Dictionary = intents[index] as Dictionary
		var identity := String(intent.get("id", "")).strip_edges()
		var pair_index = intent.get("pairIndex", null)
		var side := String(intent.get("side", ""))
		var family := String(intent.get("family", "")).strip_edges()
		var recipe_value = intent.get("recipe", null)
		var center_value = intent.get("nominalCenter", null)
		var source_blueprint = intent.get("sourceBlueprint", null)
		var source_blueprint_signature := String(intent.get("sourceBlueprintSignature", ""))
		var source_spec_value = intent.get("sourceSpec", null)
		var elevation_value = intent.get("elevation", null)
		var foundation_value = intent.get("foundationElevation", null)
		if identity.is_empty() or identities.has(identity):
			rejections.append(_rejection("invalid_or_duplicate_intent_id", "input", identity, int(pair_index) if pair_index is int else -1, side, {"intentIndex": index}))
		else:
			identities[identity] = true
		if not pair_index is int or int(pair_index) < 0 or side not in ["left", "right"]:
			rejections.append(_rejection("invalid_pair_identity", "input", identity, int(pair_index) if pair_index is int else -1, side, {}))
		else:
			var pair_side_key := "%d:%s" % [int(pair_index), side]
			if pair_sides.has(pair_side_key):
				rejections.append(_rejection("duplicate_pair_side", "input", identity, int(pair_index), side, {}))
			pair_sides[pair_side_key] = true
		if family.is_empty() or not recipe_value is Dictionary or (recipe_value as Dictionary).is_empty() or String(intent.get("recipeHash", "")).is_empty() or source_blueprint == null or not source_spec_value is Dictionary or (source_spec_value as Dictionary).is_empty():
			rejections.append(_rejection("incomplete_residence_source", "input", identity, int(pair_index) if pair_index is int else -1, side, {}))
		elif String(intent.get("recipeHash", "")) != _recipe_hash(family, recipe_value as Dictionary):
			rejections.append(_rejection("recipe_hash_mismatch", "input", identity, int(pair_index) if pair_index is int else -1, side, {"declared": intent.get("recipeHash", ""), "expected": _recipe_hash(family, recipe_value as Dictionary)}))
		elif not _source_blueprint_matches(family, recipe_value as Dictionary, source_blueprint, source_blueprint_signature):
			rejections.append(_rejection("source_blueprint_recipe_mismatch", "input", identity, int(pair_index) if pair_index is int else -1, side, {}))
		else:
			var recipe: Dictionary = recipe_value as Dictionary
			for dimension_key in ["width", "depth", "foundationHeight"]:
				var dimension_value = recipe.get(dimension_key, null)
				if not (dimension_value is float or dimension_value is int) or not is_finite(float(dimension_value)) or float(dimension_value) <= 0.0:
					rejections.append(_rejection("invalid_recipe_dimension", "input", identity, int(pair_index) if pair_index is int else -1, side, {"key": dimension_key, "value": dimension_value}))
		if not center_value is Vector3 or not _finite_vector3(center_value as Vector3):
			rejections.append(_rejection("invalid_nominal_center", "input", identity, int(pair_index) if pair_index is int else -1, side, {}))
		if String(intent.get("frontDirection", "")) not in ["north", "south", "east", "west"]:
			rejections.append(_rejection("invalid_front_direction", "input", identity, int(pair_index) if pair_index is int else -1, side, {}))
		if not (elevation_value is float or elevation_value is int) or not is_finite(float(elevation_value)) or not (foundation_value is float or foundation_value is int) or not is_finite(float(foundation_value)):
			rejections.append(_rejection("invalid_elevation", "input", identity, int(pair_index) if pair_index is int else -1, side, {}))
	if intents.is_empty():
		rejections.append(_rejection("empty_intent_domain", "input", "", -1, "", {}))
	else:
		var pair_count := pair_sides.size() >> 1
		for pair_index in range(pair_count):
			if not pair_sides.has("%d:left" % pair_index) or not pair_sides.has("%d:right" % pair_index):
				rejections.append(_rejection("incomplete_pair_domain", "input", "", pair_index, "", {}))
		if pair_sides.size() != pair_count * 2:
			rejections.append(_rejection("non_contiguous_pair_domain", "input", "", -1, "", {"pairSideCount": pair_sides.size()}))
	for street_index in range(street_records.size()):
		if not street_records[street_index] is Dictionary or not _valid_street(street_records[street_index] as Dictionary):
			rejections.append(_rejection("invalid_street_record", "input", "", -1, "", {"streetIndex": street_index}))
			continue
		var street_id := String((street_records[street_index] as Dictionary).get("id", "")).strip_edges()
		if street_id.is_empty() or street_ids.has(street_id):
			rejections.append(_rejection("invalid_or_duplicate_street_id", "input", "", -1, "", {"streetIndex": street_index, "streetId": street_id}))
		street_ids[street_id] = true
	for part_index in range(structure_parts.size()):
		if not structure_parts[part_index] is Dictionary or not _valid_structure_part(structure_parts[part_index] as Dictionary):
			rejections.append(_rejection("invalid_structure_part_geometry", "input", "", -1, "", {"structureIndex": part_index, "structurePartId": _part_id(structure_parts[part_index])}))
			continue
		var structure_id := _part_id(structure_parts[part_index]).strip_edges()
		if structure_id.is_empty() or structure_ids.has(structure_id):
			rejections.append(_rejection("invalid_or_duplicate_structure_part_id", "input", "", -1, "", {"structureIndex": part_index, "structurePartId": structure_id}))
		structure_ids[structure_id] = true
	return {"passed": rejections.is_empty(), "rejections": rejections, "settings": settings, "bounds": bounds}


static func _placement_record(intent: Dictionary, center: Vector3, origin: Vector3, composition: Dictionary) -> Dictionary:
	var record := {
		"id": String(intent.get("id", "")),
		"identity": String(intent.get("id", "")),
		"pairIndex": int(intent.get("pairIndex", -1)),
		"side": String(intent.get("side", "")),
		"family": String(intent.get("family", "")),
		"recipeHash": String(intent.get("recipeHash", "")),
		"sourceBlueprintSignature": String(intent.get("sourceBlueprintSignature", "")),
		"nominalCenter": intent.get("nominalCenter", Vector3.ZERO) as Vector3,
		"center": center,
		"origin": origin,
		"yaw": _yaw_for_front(String(intent.get("frontDirection", ""))),
		"frontDirection": String(intent.get("frontDirection", "")),
		"elevation": float(intent.get("elevation", 0.0)),
		"composition": composition.duplicate(true),
		"compositionSignature": _composition_signature(composition),
		"compositionCount": 1,
		"compositionPartCount": _composition_part_count(composition),
		"collisionPartCount": _collision_part_count(composition),
		"aggregateCount": _aggregate_count(composition)
	}
	record["placementSignature"] = _placement_signature(intent, center, origin, composition)
	return record


static func _ready_plan(placements: Array[Dictionary], intent_count: int, telemetry: Dictionary) -> Dictionary:
	var family_counts := {}
	var composition_part_count := 0
	var collision_part_count := 0
	var aggregate_count := 0
	for placement in placements:
		var family := String(placement.get("family", ""))
		family_counts[family] = int(family_counts.get(family, 0)) + 1
		composition_part_count += int(placement.get("compositionPartCount", 0))
		collision_part_count += int(placement.get("collisionPartCount", 0))
		aggregate_count += int(placement.get("aggregateCount", 0))
	return {
		"schemaVersion": SCHEMA_VERSION,
		"status": "ready",
		"intentCount": intent_count,
		"placementCount": placements.size(),
		"unresolvedIntentCount": intent_count - placements.size(),
		"familyCounts": family_counts,
		"compositionCount": placements.size(),
		"compositionPartCount": composition_part_count,
		"collisionPartCount": collision_part_count,
		"aggregateCount": aggregate_count,
		"placements": placements,
		"placementSignature": _plan_signature(placements, intent_count),
		"telemetry": telemetry.duplicate(true),
		"rejections": []
	}


static func _infeasible(intent_count: int, telemetry: Dictionary, rejection_values: Array, phase: String) -> Dictionary:
	var rejections: Array[Dictionary] = []
	for value in rejection_values:
		if value is Dictionary:
			rejections.append((value as Dictionary).duplicate(true))
	if rejections.is_empty():
		rejections.append(_rejection("unspecified_infeasible_domain", phase, "", -1, "", {}))
	return {
		"schemaVersion": SCHEMA_VERSION,
		"status": "infeasible",
		"phase": phase,
		"intentCount": intent_count,
		"placementCount": 0,
		"unresolvedIntentCount": intent_count,
		"placements": [],
		"placementSignature": "",
		"telemetry": telemetry.duplicate(true),
		"rejections": rejections
	}


static func _placement_failure(code: String, phase: String, intent: Dictionary, details: Dictionary) -> Dictionary:
	return {"passed": false, "phase": phase, "rejections": [_rejection(code, phase, String(intent.get("id", "")), int(intent.get("pairIndex", -1)), String(intent.get("side", "")), details)]}


static func _rejection(code: String, phase: String, identity: String, pair_index: int, side: String, details: Dictionary) -> Dictionary:
	return {"code": code, "phase": phase, "intentId": identity, "pairIndex": pair_index, "side": side, "details": details.duplicate(true)}


static func _validation_result(passed: bool, telemetry: Dictionary, rejection_values: Array) -> Dictionary:
	var rejections: Array[Dictionary] = []
	for value in rejection_values:
		if value is Dictionary:
			rejections.append((value as Dictionary).duplicate(true))
	return {"passed": passed, "checkedIntentCount": int(telemetry.get("intentCount", 0)), "telemetry": telemetry.duplicate(true), "rejections": rejections}


static func _new_telemetry(intent_count: int, street_count: int, structure_count: int) -> Dictionary:
	return {
		"intentCount": intent_count,
		"streetObstacleCount": street_count,
		"structureObstacleCount": structure_count,
		"fixedObstacleCount": street_count + structure_count,
		"descriptionCalls": 0,
		"blockerCalls": 0,
		"algebraicObstacleComparisons": 0,
		"algebraicPriorComparisons": 0,
		"exactStreetComparisons": 0,
		"exactStructureComparisons": 0,
		"exactPriorComparisons": 0,
		"priorTraversals": [],
		"boundsChecks": 0,
		"boundaryAdjustments": 0,
		"maximumDescriptionCalls": intent_count * 4,
		"maximumObstacleComparisons": intent_count * (street_count + structure_count) * 2,
		"maximumPriorComparisons": intent_count * maxi(0, intent_count - 1),
		"maximumPriorTraversalEntries": intent_count,
		"maximumPriorTraversalItems": int(intent_count * maxi(0, intent_count - 1) / 2)
	}


static func _validate_telemetry_bounds(telemetry: Dictionary, rejections: Array[Dictionary]) -> void:
	if int(telemetry.get("descriptionCalls", 0)) > int(telemetry.get("maximumDescriptionCalls", 0)):
		rejections.append(_rejection("description_bound_exceeded", "telemetry", "", -1, "", telemetry))
	var obstacle_comparisons := int(telemetry.get("algebraicObstacleComparisons", 0)) + int(telemetry.get("exactStreetComparisons", 0)) + int(telemetry.get("exactStructureComparisons", 0))
	if obstacle_comparisons > int(telemetry.get("maximumObstacleComparisons", 0)):
		rejections.append(_rejection("obstacle_comparison_bound_exceeded", "telemetry", "", -1, "", {"actual": obstacle_comparisons, "maximum": telemetry.get("maximumObstacleComparisons", 0)}))
	var prior_comparisons := int(telemetry.get("algebraicPriorComparisons", 0)) + int(telemetry.get("exactPriorComparisons", 0))
	if prior_comparisons > int(telemetry.get("maximumPriorComparisons", 0)):
		rejections.append(_rejection("prior_comparison_bound_exceeded", "telemetry", "", -1, "", {"actual": prior_comparisons, "maximum": telemetry.get("maximumPriorComparisons", 0)}))


static func _record_prior_traversal(telemetry: Dictionary, intent: Dictionary, progression_sign: int, traversed_prior_tokens: PackedStringArray) -> void:
	var prior_traversals: Array = telemetry.get("priorTraversals", []) as Array
	prior_traversals.append({
		"intentId": String(intent.get("id", "")),
		"progressionSign": progression_sign,
		"traversedPriorCount": traversed_prior_tokens.size(),
		"traversedPriorSequenceSha256": "\n".join(traversed_prior_tokens).sha256_text()
	})
	telemetry["priorTraversals"] = prior_traversals


static func _intent_precedes(left: Dictionary, right: Dictionary) -> bool:
	var left_pair := int(left.get("pairIndex", -1))
	var right_pair := int(right.get("pairIndex", -1))
	if left_pair != right_pair:
		return left_pair < right_pair
	var left_side_rank := 0 if String(left.get("side", "")) == "left" else 1
	var right_side_rank := 0 if String(right.get("side", "")) == "left" else 1
	if left_side_rank != right_side_rank:
		return left_side_rank < right_side_rank
	return String(left.get("id", "")) < String(right.get("id", ""))


static func _progression_sign(nominal_center: Vector3, prior_nominal_centers: Array[Vector3], bounds: Dictionary) -> int:
	if not prior_nominal_centers.is_empty():
		var previous := prior_nominal_centers[prior_nominal_centers.size() - 1]
		if nominal_center.z > previous.z + EPSILON:
			return 1
		if nominal_center.z < previous.z - EPSILON:
			return -1
	var center_z := (float(bounds.get("minZ", 0.0)) + float(bounds.get("maxZ", 0.0))) * 0.5
	return -1 if nominal_center.z < center_z else 1


static func _clearance_adjusted_prior_encounter_order(placed_blockers: Array[Dictionary], placements: Array[Dictionary], pair_index: int, progression_sign: int, settings: Dictionary) -> Array[int]:
	var order: Array[int] = []
	for prior_index in range(placed_blockers.size()):
		order.append(prior_index)
	order.sort_custom(func(left_index: int, right_index: int) -> bool:
		var left_bounds: Dictionary = placed_blockers[left_index]
		var right_bounds: Dictionary = placed_blockers[right_index]
		var left_pair_index := int(placements[left_index].get("pairIndex", -2)) if left_index < placements.size() else -2
		var right_pair_index := int(placements[right_index].get("pairIndex", -2)) if right_index < placements.size() else -2
		var left_clearance := float(settings.get("pairClearance", DEFAULT_PAIR_CLEARANCE)) if left_pair_index == pair_index else float(settings.get("residenceClearance", DEFAULT_RESIDENCE_CLEARANCE))
		var right_clearance := float(settings.get("pairClearance", DEFAULT_PAIR_CLEARANCE)) if right_pair_index == pair_index else float(settings.get("residenceClearance", DEFAULT_RESIDENCE_CLEARANCE))
		var left_encounter := float(left_bounds.get("maxZ", 0.0)) + left_clearance if progression_sign < 0 else float(left_bounds.get("minZ", 0.0)) - left_clearance
		var right_encounter := float(right_bounds.get("maxZ", 0.0)) + right_clearance if progression_sign < 0 else float(right_bounds.get("minZ", 0.0)) - right_clearance
		if left_encounter != right_encounter:
			return left_encounter > right_encounter if progression_sign < 0 else left_encounter < right_encounter
		var left_id := String(placements[left_index].get("id", "")) if left_index < placements.size() else ""
		var right_id := String(placements[right_index].get("id", "")) if right_index < placements.size() else ""
		if left_id != right_id:
			return left_id < right_id
		return left_index < right_index
	)
	return order


static func _outward_sign(nominal_center: Vector3, bounds: Dictionary) -> int:
	var center_x := (float(bounds.get("minX", 0.0)) + float(bounds.get("maxX", 0.0))) * 0.5
	if nominal_center.x < center_x - EPSILON:
		return -1
	if nominal_center.x > center_x + EPSILON:
		return 1
	return 0


static func _monotonic_axis_delta(candidate: Dictionary, obstacle: Dictionary, axis: String, direction: int, clearance: float, existing_delta: float) -> float:
	var minimum_key := "minX" if axis == "x" else "minZ"
	var maximum_key := "maxX" if axis == "x" else "maxZ"
	if direction < 0:
		var required := float(obstacle.get(minimum_key, 0.0)) - clearance - float(candidate.get(maximum_key, 0.0))
		return minf(existing_delta, required)
	var required := float(obstacle.get(maximum_key, 0.0)) + clearance - float(candidate.get(minimum_key, 0.0))
	return maxf(existing_delta, required)


static func _boundary_adjustment(blocker: Dictionary, bounds: Dictionary, clearance: float) -> Dictionary:
	var minimum_x := float(bounds.get("minX", 0.0)) + clearance
	var maximum_x := float(bounds.get("maxX", 0.0)) - clearance
	var minimum_z := float(bounds.get("minZ", 0.0)) + clearance
	var maximum_z := float(bounds.get("maxZ", 0.0)) - clearance
	var width := float(blocker.get("maxX", 0.0)) - float(blocker.get("minX", 0.0))
	var depth := float(blocker.get("maxZ", 0.0)) - float(blocker.get("minZ", 0.0))
	if width > maximum_x - minimum_x + EPSILON or depth > maximum_z - minimum_z + EPSILON:
		return {"possible": false, "delta": Vector2.ZERO}
	var delta_x := 0.0
	if float(blocker.get("minX", 0.0)) < minimum_x:
		delta_x = minimum_x - float(blocker.get("minX", 0.0))
	elif float(blocker.get("maxX", 0.0)) > maximum_x:
		delta_x = maximum_x - float(blocker.get("maxX", 0.0))
	var delta_z := 0.0
	if float(blocker.get("minZ", 0.0)) < minimum_z:
		delta_z = minimum_z - float(blocker.get("minZ", 0.0))
	elif float(blocker.get("maxZ", 0.0)) > maximum_z:
		delta_z = maximum_z - float(blocker.get("maxZ", 0.0))
	return {"possible": true, "delta": Vector2(delta_x, delta_z)}


static func _shift_bounds(bounds: Dictionary, delta_x: float, delta_z: float) -> Dictionary:
	return {"minX": float(bounds.get("minX", 0.0)) + delta_x, "maxX": float(bounds.get("maxX", 0.0)) + delta_x, "minZ": float(bounds.get("minZ", 0.0)) + delta_z, "maxZ": float(bounds.get("maxZ", 0.0)) + delta_z}


static func _street_footprint(street: Dictionary) -> Dictionary:
	var center := Vector2(float(street.get("x", 0.0)), float(street.get("z", 0.0)))
	var width := float(street.get("width", 0.0))
	var depth := float(street.get("depth", 0.0))
	return {"id": String(street.get("id", "")), "center": center, "width": width, "depth": depth, "minX": center.x - width * 0.5, "maxX": center.x + width * 0.5, "minZ": center.y - depth * 0.5, "maxZ": center.y + depth * 0.5}


static func _footprint_bounds(footprint: Dictionary) -> Dictionary:
	if footprint.has("minX") and footprint.has("maxX") and footprint.has("minZ") and footprint.has("maxZ"):
		var direct := _normalized_bounds(footprint)
		return direct
	var center_value = footprint.get("center", null)
	var width_value = footprint.get("width", null)
	var depth_value = footprint.get("depth", null)
	if center_value is Vector3 and (width_value is float or width_value is int) and (depth_value is float or depth_value is int):
		var center3 := center_value as Vector3
		return _normalized_bounds({"minX": center3.x - float(width_value) * 0.5, "maxX": center3.x + float(width_value) * 0.5, "minZ": center3.z - float(depth_value) * 0.5, "maxZ": center3.z + float(depth_value) * 0.5})
	if center_value is Vector2 and (width_value is float or width_value is int) and (depth_value is float or depth_value is int):
		var center2 := center_value as Vector2
		return _normalized_bounds({"minX": center2.x - float(width_value) * 0.5, "maxX": center2.x + float(width_value) * 0.5, "minZ": center2.y - float(depth_value) * 0.5, "maxZ": center2.y + float(depth_value) * 0.5})
	return {}


static func _composition_bounds(composition: Dictionary) -> Dictionary:
	var aggregate = composition.get("aggregateFootprint", null)
	return _footprint_bounds(aggregate as Dictionary) if aggregate is Dictionary else {}


static func _rect_bounds(rect: Rect2) -> Dictionary:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0 or not is_finite(rect.position.x) or not is_finite(rect.position.y) or not is_finite(rect.size.x) or not is_finite(rect.size.y):
		return {}
	return {"minX": rect.position.x, "maxX": rect.end.x, "minZ": rect.position.y, "maxZ": rect.end.y}


static func _footprints_overlap(left: Dictionary, right: Dictionary, clearance: float) -> bool:
	var left_bounds := _footprint_bounds(left)
	var right_bounds := _footprint_bounds(right)
	if left_bounds.is_empty() or right_bounds.is_empty():
		# Invalid geometry is rejected by the owning validation phase; fail closed
		# here so it can never be interpreted as a clear placement.
		return true
	var left_center := Vector3((float(left_bounds.get("minX", 0.0)) + float(left_bounds.get("maxX", 0.0))) * 0.5, 0.0, (float(left_bounds.get("minZ", 0.0)) + float(left_bounds.get("maxZ", 0.0))) * 0.5)
	var right_center := Vector3((float(right_bounds.get("minX", 0.0)) + float(right_bounds.get("maxX", 0.0))) * 0.5, 0.0, (float(right_bounds.get("minZ", 0.0)) + float(right_bounds.get("maxZ", 0.0))) * 0.5)
	return CastleResidencePlacementGeometryScript.footprint_overlaps(
		left_center,
		float(left_bounds.get("maxX", 0.0)) - float(left_bounds.get("minX", 0.0)),
		float(left_bounds.get("maxZ", 0.0)) - float(left_bounds.get("minZ", 0.0)),
		right_center,
		float(right_bounds.get("maxX", 0.0)) - float(right_bounds.get("minX", 0.0)),
		float(right_bounds.get("maxZ", 0.0)) - float(right_bounds.get("minZ", 0.0)),
		clearance
	)


static func _composition_fits_bounds(composition: Dictionary, bounds: Dictionary, clearance: float) -> bool:
	return CastleResidencePlacementGeometryScript.composition_fits_bounds(
		composition,
		float(bounds.get("maxX", 0.0)) - float(bounds.get("minX", 0.0)),
		float(bounds.get("maxZ", 0.0)) - float(bounds.get("minZ", 0.0)),
		clearance
	)


static func _normalized_bounds(value: Dictionary) -> Dictionary:
	for key in ["minX", "maxX", "minZ", "maxZ"]:
		if not value.has(key) or not (value[key] is float or value[key] is int) or not is_finite(float(value[key])):
			return {}
	var result := {"minX": float(value.get("minX", 0.0)), "maxX": float(value.get("maxX", 0.0)), "minZ": float(value.get("minZ", 0.0)), "maxZ": float(value.get("maxZ", 0.0))}
	if float(result.get("minX", 0.0)) >= float(result.get("maxX", 0.0)) or float(result.get("minZ", 0.0)) >= float(result.get("maxZ", 0.0)):
		return {}
	return result


static func _valid_street(street: Dictionary) -> bool:
	for key in ["x", "z", "width", "depth"]:
		if not street.has(key) or not (street[key] is float or street[key] is int) or not is_finite(float(street[key])):
			return false
	return float(street.get("width", 0.0)) > 0.0 and float(street.get("depth", 0.0)) > 0.0


static func _part_collision_enabled(part) -> bool:
	if part is Dictionary:
		var values: Dictionary = part as Dictionary
		var has_exact_shape := values.get("center", null) is Vector3 and values.get("size", null) is Vector3 and values.get("basis", null) is Basis
		if values.has("collision") or values.has("collisionEnabled") or values.has("collision_enabled"):
			return has_exact_shape and bool(values.get("collision", values.get("collisionEnabled", values.get("collision_enabled", false))))
		# The production keep/tower/forecourt extraction emits only descriptors
		# for collision-enabled parts and therefore has no redundant flag.
		return has_exact_shape
	if part is Object:
		return bool((part as Object).get("collision_enabled"))
	return false


static func _source_blueprint_matches(family: String, recipe: Dictionary, source_blueprint, declared_signature: String) -> bool:
	if source_blueprint == null or not source_blueprint is BuildingBlueprintScript:
		return false
	var blueprint_recipe: Dictionary = source_blueprint.recipe as Dictionary
	if declared_signature.is_empty() or String(source_blueprint.deterministic_signature()) != declared_signature or JSON.stringify(blueprint_recipe) != JSON.stringify(recipe) or source_blueprint.parts.is_empty():
		return false
	var blueprint_id := String(source_blueprint.id)
	return blueprint_id.begins_with("landmark.manor.") if family == "manor" else blueprint_id.begins_with("cottage.recipe.") if family == "cottage" else false


static func _valid_structure_part(part: Dictionary) -> bool:
	if not _part_collision_enabled(part):
		return false
	var center: Vector3 = part.get("center", Vector3(INF, INF, INF)) as Vector3
	var size: Vector3 = part.get("size", Vector3.ZERO) as Vector3
	var basis: Basis = part.get("basis", Basis.IDENTITY) as Basis
	if not _finite_vector3(center) or not _finite_vector3(size) or size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
		return false
	if not _finite_vector3(basis.x) or not _finite_vector3(basis.y) or not _finite_vector3(basis.z):
		return false
	return is_equal_approx(basis.x.length_squared(), 1.0) \
		and is_equal_approx(basis.y.length_squared(), 1.0) \
		and is_equal_approx(basis.z.length_squared(), 1.0) \
		and is_zero_approx(basis.x.dot(basis.y)) \
		and is_zero_approx(basis.x.dot(basis.z)) \
		and is_zero_approx(basis.y.dot(basis.z)) \
		and absf(basis.determinant()) > EPSILON


static func _part_id(part) -> String:
	if part == null:
		return ""
	if part is Dictionary:
		return String((part as Dictionary).get("partId", (part as Dictionary).get("id", "")))
	if part is Object:
		return String((part as Object).get("id"))
	return ""


static func _ordered_structure_parts(structure_parts: Array) -> Array:
	var ordered := structure_parts.duplicate()
	ordered.sort_custom(func(left, right) -> bool: return _part_id(left) < _part_id(right))
	return ordered


static func _placement_preserves_intent(placement: Dictionary, intent: Dictionary) -> bool:
	return String(placement.get("id", "")) == String(intent.get("id", "")) \
		and String(placement.get("identity", "")) == String(intent.get("id", "")) \
		and int(placement.get("pairIndex", -1)) == int(intent.get("pairIndex", -1)) \
		and String(placement.get("side", "")) == String(intent.get("side", "")) \
		and String(placement.get("family", "")) == String(intent.get("family", "")) \
		and String(placement.get("recipeHash", "")) == String(intent.get("recipeHash", "")) \
		and String(placement.get("sourceBlueprintSignature", "")) == String(intent.get("sourceBlueprintSignature", "")) \
		and (placement.get("nominalCenter", Vector3(INF, INF, INF)) as Vector3) == (intent.get("nominalCenter", Vector3.ZERO) as Vector3) \
		and String(placement.get("frontDirection", "")) == String(intent.get("frontDirection", "")) \
		and is_equal_approx(float(placement.get("elevation", NAN)), float(intent.get("elevation", 0.0))) \
		and is_equal_approx(float(placement.get("yaw", NAN)), _yaw_for_front(String(intent.get("frontDirection", ""))))


static func _counts_match(placement: Dictionary, composition: Dictionary) -> bool:
	return int(placement.get("compositionCount", -1)) == 1 \
		and int(placement.get("compositionPartCount", -1)) == _composition_part_count(composition) \
		and int(placement.get("collisionPartCount", -1)) == _collision_part_count(composition) \
		and int(placement.get("aggregateCount", -1)) == _aggregate_count(composition)


static func _plan_summary_matches(candidate_plan: Dictionary, placements: Array[Dictionary], intent_count: int) -> bool:
	var family_counts := {}
	var composition_part_count := 0
	var collision_part_count := 0
	var aggregate_count := 0
	for placement in placements:
		var family := String(placement.get("family", ""))
		family_counts[family] = int(family_counts.get(family, 0)) + 1
		composition_part_count += int(placement.get("compositionPartCount", 0))
		collision_part_count += int(placement.get("collisionPartCount", 0))
		aggregate_count += int(placement.get("aggregateCount", 0))
	return int(candidate_plan.get("intentCount", -1)) == intent_count \
		and int(candidate_plan.get("placementCount", -1)) == placements.size() \
		and int(candidate_plan.get("unresolvedIntentCount", -1)) == intent_count - placements.size() \
		and JSON.stringify(candidate_plan.get("familyCounts", {})) == JSON.stringify(family_counts) \
		and int(candidate_plan.get("compositionCount", -1)) == placements.size() \
		and int(candidate_plan.get("compositionPartCount", -1)) == composition_part_count \
		and int(candidate_plan.get("collisionPartCount", -1)) == collision_part_count \
		and int(candidate_plan.get("aggregateCount", -1)) == aggregate_count


static func _composition_signature(composition: Dictionary) -> String:
	var values := PackedStringArray(["castle_residence_composition", str(SCHEMA_VERSION), String(composition.get("residenceId", ""))])
	for part_value in composition.get("collisionParts", []) as Array:
		if part_value is Dictionary:
			values.append(_part_signature(part_value as Dictionary))
	var door_value = composition.get("door", null)
	if door_value is Dictionary:
		var door: Dictionary = door_value as Dictionary
		values.append("door:%s:%s:%s:%.8f" % [_part_signature(door), _vector_signature(door.get("lateral", Vector3.ZERO) as Vector3), _vector_signature(door.get("exteriorNormal", Vector3.ZERO) as Vector3), float(door.get("openingWidth", 0.0))])
	var corridor_value = composition.get("doorCorridor", null)
	if corridor_value is Dictionary:
		values.append("corridor:" + _part_signature(corridor_value as Dictionary))
	var aggregate_value = composition.get("aggregateFootprint", null)
	if aggregate_value is Dictionary:
		values.append("aggregate:" + _footprint_signature(aggregate_value as Dictionary))
	for shape_value in composition.get("runtimeInteractionShapes", []) as Array:
		if shape_value is Dictionary:
			values.append("interaction:" + _part_signature(shape_value as Dictionary))
	return "|".join(values).sha256_text()


static func _recipe_hash(family: String, recipe: Dictionary) -> String:
	return (family + "\n" + JSON.stringify(recipe)).sha256_text()


static func _composition_part_count(composition: Dictionary) -> int:
	if composition.has("partCount"):
		return int(composition.get("partCount", 0))
	return (composition.get("collisionParts", []) as Array).size() + (1 if not (composition.get("doorCorridor", {}) as Dictionary).is_empty() else 0) + (composition.get("runtimeInteractionShapes", []) as Array).size()


static func _collision_part_count(composition: Dictionary) -> int:
	if composition.has("collisionPartCount"):
		return int(composition.get("collisionPartCount", 0))
	return (composition.get("collisionParts", []) as Array).size()


static func _aggregate_count(composition: Dictionary) -> int:
	if composition.has("aggregateCount"):
		return int(composition.get("aggregateCount", 0))
	if composition.has("aggregateFootprints"):
		return (composition.get("aggregateFootprints", []) as Array).size()
	return 1 if composition.has("aggregateFootprint") else 0


static func _part_signature(part: Dictionary) -> String:
	var center: Vector3 = part.get("center", Vector3.ZERO) as Vector3
	var size: Vector3 = part.get("size", Vector3.ZERO) as Vector3
	var basis: Basis = part.get("basis", Basis.IDENTITY) as Basis
	return ",".join(PackedStringArray([
		String(part.get("id", part.get("partId", ""))),
		String(part.get("sourcePartId", "")),
		String(part.get("semantic", "")),
		String(part.get("role", "")),
		"1" if bool(part.get("collisionEnabled", true)) else "0",
		_vector_signature(center),
		_vector_signature(size),
		_vector_signature(basis.x),
		_vector_signature(basis.y),
		_vector_signature(basis.z)
	]))


static func _footprint_signature(footprint: Dictionary) -> String:
	var bounds := _footprint_bounds(footprint)
	return "%.8f,%.8f,%.8f,%.8f" % [float(bounds.get("minX", NAN)), float(bounds.get("maxX", NAN)), float(bounds.get("minZ", NAN)), float(bounds.get("maxZ", NAN))]


static func _placement_signature(intent: Dictionary, center: Vector3, origin: Vector3, composition: Dictionary) -> String:
	return "|".join(PackedStringArray([
		String(intent.get("id", "")),
		str(int(intent.get("pairIndex", -1))),
		String(intent.get("side", "")),
		String(intent.get("family", "")),
		String(intent.get("recipeHash", "")),
		String(intent.get("sourceBlueprintSignature", "")),
		_vector_signature(intent.get("nominalCenter", Vector3.ZERO) as Vector3),
		_vector_signature(center),
		_vector_signature(origin),
		"%.8f" % _yaw_for_front(String(intent.get("frontDirection", ""))),
		String(intent.get("frontDirection", "")),
		"%.8f" % float(intent.get("elevation", 0.0)),
		_composition_signature(composition),
		str(_composition_part_count(composition)),
		str(_collision_part_count(composition)),
		str(_aggregate_count(composition))
	])).sha256_text()


static func _plan_signature(placements: Array[Dictionary], intent_count: int) -> String:
	var values := PackedStringArray(["castle_courtyard_district_placement", str(SCHEMA_VERSION), str(intent_count), str(placements.size())])
	for placement in placements:
		values.append(String(placement.get("placementSignature", "")))
	return "|".join(values).sha256_text()


static func _vector_signature(value: Vector3) -> String:
	return "%.8f,%.8f,%.8f" % [value.x, value.y, value.z]


static func _yaw_for_front(front_direction: String) -> float:
	match front_direction:
		"north": return 0.0
		"south": return PI
		"east": return -PI * 0.5
		"west": return PI * 0.5
	return NAN


static func _finite_vector3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)
