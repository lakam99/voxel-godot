extends RefCounted
class_name CastleResidencePlacementGeometry

## Shared exact geometry authority for Citadel residence placement.
##
## Descriptors are derived from the same deterministic source BuildingParts
## that publication consumes. Synthetic underfill, plinth, facade projections,
## door corridors, broad-phase aggregates, and exact oriented-part overlap all
## retain the Castle compound builder's established formulas.

const NpcConstantsScript := preload("res://scripts/buildings/layout/BuildingLayoutConstants.gd")
const BuildingBlueprintScript := preload("res://scripts/buildings/BuildingBlueprint.gd")
const BuildingPartScript := preload("res://scripts/buildings/BuildingPart.gd")


static func yaw_for_front_direction(front_direction: String) -> float:
	return _yaw_for_front_direction(front_direction)


static func contextual_egress_part(source_part, residence_origin_y: float, compound_foundation_height: float, terrace_elevation := 0.0) -> Dictionary:
	return _contextual_egress_part(source_part, residence_origin_y, compound_foundation_height, terrace_elevation)


static func part_horizontal_bounds(part: Dictionary) -> Rect2:
	return _part_horizontal_bounds(part)


static func describe_residence(spec: Dictionary, source_blueprint, compound_foundation_height: float) -> Dictionary:
	if source_blueprint == null or not source_blueprint is BuildingBlueprintScript:
		return {}
	var origin: Vector3 = spec.get("origin", Vector3.ZERO) as Vector3
	var yaw := float(spec.get("yaw", _yaw_for_front_direction(String(spec.get("frontDirection", "north")))))
	var yaw_basis := Basis(Vector3.UP, yaw)
	var collision_parts: Array[Dictionary] = []
	var door: Dictionary = {}
	var minimum_x := INF
	var maximum_x := -INF
	var minimum_z := INF
	var maximum_z := -INF
	for part in source_blueprint.parts:
		if not _valid_source_part(part):
			return {}
		var resolved_part := _contextual_egress_part(part, origin.y, compound_foundation_height, float(spec.get("terraceElevation", 0.0)))
		var resolved_position: Vector3 = resolved_part.get("position", part.position) as Vector3
		var resolved_rotation: Vector3 = resolved_part.get("rotation", part.rotation) as Vector3
		var resolved_size: Vector3 = resolved_part.get("size", part.size) as Vector3
		var transformed_center: Vector3 = origin + yaw_basis * resolved_position
		var transformed_basis := yaw_basis * Basis.from_euler(resolved_rotation)
		var descriptor := _collision_part("source:%s" % String(part.id), transformed_center, resolved_size, transformed_basis, String(part.semantic), "source", String(part.id), bool(part.collision_enabled))
		if bool(part.collision_enabled):
			collision_parts.append(descriptor)
		if String(part.kind) == "door" and door.is_empty():
			door = descriptor.duplicate(true)
			door["collisionEnabled"] = bool(part.collision_enabled)
			var door_egress: Dictionary = part.recipe.get("doorEgress", {}) as Dictionary
			door["outwardEndpointPartId"] = String(door_egress.get("outwardEndpointPartId", ""))
		if String(part.semantic) == "entry_ramp" and bool(part.collision_enabled):
			collision_parts.append_array(_egress_underfill_collision_parts(spec, part, resolved_part, compound_foundation_height))
		elif bool(part.collision_enabled) and not String(part.recipe.get("doorEgressFor", "")).is_empty() and String(part.recipe.get("navigationRole", "")) == "walkable_support":
			var landing_underfill := _egress_landing_underfill_collision_part(spec, part, resolved_part)
			if not landing_underfill.is_empty():
				collision_parts.append(landing_underfill)
	var plinth := _plinth_collision_part(spec, source_blueprint, compound_foundation_height)
	if not plinth.is_empty():
		collision_parts.append(plinth)
	if door.is_empty():
		return {}
	var door_basis: Basis = door.get("basis", Basis.IDENTITY) as Basis
	var outward: Vector3 = door_basis * Vector3.FORWARD
	outward.y = 0.0
	if outward.length_squared() <= 0.0001:
		return {}
	outward = outward.normalized()
	var lateral: Vector3 = door_basis.x
	lateral.y = 0.0
	if lateral.length_squared() <= 0.0001:
		return {}
	lateral = lateral.normalized()
	var door_size: Vector3 = door.get("size", Vector3.ZERO) as Vector3
	var opening_width := absf(lateral.dot(door_basis.x)) * door_size.x + absf(lateral.dot(door_basis.y)) * door_size.y + absf(lateral.dot(door_basis.z)) * door_size.z
	var door_center: Vector3 = door.get("center", Vector3.ZERO) as Vector3
	var outward_endpoint_part_id := String(door.get("outwardEndpointPartId", ""))
	var outward_endpoint: Dictionary = {}
	for collision_part in collision_parts:
		if String(collision_part.get("role", "")) == "source" and String(collision_part.get("sourcePartId", "")) == outward_endpoint_part_id:
			outward_endpoint = collision_part
			break
	if outward_endpoint_part_id.is_empty() or outward_endpoint.is_empty() or outward.dot((outward_endpoint.get("center", door_center) as Vector3) - door_center) <= 0.01:
		return {}
	var door_fact := {"center": door_center, "lateral": lateral, "exteriorNormal": outward, "openingWidth": opening_width, "sourcePartId": String(door.get("sourcePartId", "")), "basis": door_basis, "size": door_size}
	collision_parts.append_array(_facade_collision_parts(spec, door_fact, compound_foundation_height))
	if collision_parts.is_empty():
		return {}
	for collision_part in collision_parts:
		var bounds := _part_horizontal_bounds(collision_part)
		minimum_x = minf(minimum_x, bounds.position.x)
		maximum_x = maxf(maximum_x, bounds.end.x)
		minimum_z = minf(minimum_z, bounds.position.y)
		maximum_z = maxf(maximum_z, bounds.end.y)
	var door_vertical_extent := absf(door_basis.x.y) * door_size.x * 0.5 + absf(door_basis.y.y) * door_size.y * 0.5 + absf(door_basis.z.y) * door_size.z * 0.5
	var corridor_bottom_offset := 0.24
	var corridor_height := float(NpcConstantsScript.DEFAULT_NPC_STANDING_HEIGHT)
	var corridor_radius := float(NpcConstantsScript.DEFAULT_NPC_RADIUS)
	var corridor := _collision_part("door_corridor", Vector3(door_center.x, door_center.y - door_vertical_extent + corridor_bottom_offset + corridor_height * 0.5, door_center.z), Vector3(corridor_radius * 2.0, corridor_height, 3.10), Basis(lateral, Vector3.UP, outward), "npc_door_corridor", "door_corridor", String(door.get("sourcePartId", "")), false)
	var interaction_proxy := _collision_part("door_interaction_proxy", door_center, Vector3(door_size.x * 1.26, door_size.y * 1.04, maxf(1.10, door_size.z * 4.0)), door_basis, "door_interaction_proxy", "door_interaction_proxy", String(door.get("sourcePartId", "")), false)
	var corridor_bounds := _part_horizontal_bounds(corridor)
	minimum_x = minf(minimum_x, corridor_bounds.position.x)
	maximum_x = maxf(maximum_x, corridor_bounds.end.x)
	minimum_z = minf(minimum_z, corridor_bounds.position.y)
	maximum_z = maxf(maximum_z, corridor_bounds.end.y)
	return {
		"residenceId": String(spec.get("id", "")),
		"collisionParts": collision_parts,
		"door": door_fact,
		"doorCorridor": corridor,
		"runtimeInteractionShapes": [interaction_proxy],
		"aggregateFootprint": {"center": Vector3((minimum_x + maximum_x) * 0.5, origin.y, (minimum_z + maximum_z) * 0.5), "width": maximum_x - minimum_x, "depth": maximum_z - minimum_z, "sourceCollisionPartCount": collision_parts.size()}
	}


static func composition_blocker(composition: Dictionary) -> Dictionary:
	if composition.is_empty():
		return {"reason": "composition_missing"}
	var corridor: Dictionary = composition.get("doorCorridor", {}) as Dictionary
	var door_source_part_id := String((composition.get("door", {}) as Dictionary).get("sourcePartId", ""))
	for part_value in composition.get("collisionParts", []) as Array:
		var part: Dictionary = part_value as Dictionary
		if String(part.get("sourcePartId", "")) == door_source_part_id or String(part.get("semantic", "")) in ["entry_ramp", "entry_threshold", "board_floor", "floor"]:
			continue
		if _parts_overlap(corridor, part):
			return {"reason": "door_corridor_blocked", "partId": String(part.get("id", "")), "semantic": String(part.get("semantic", "")), "role": String(part.get("role", ""))}
	return {}


static func compositions_overlap(a: Dictionary, b: Dictionary, clearance: float) -> bool:
	if not _valid_composition_shape(a) or not _valid_composition_shape(b):
		return true
	var first_footprint: Dictionary = a.get("aggregateFootprint", {}) as Dictionary
	var second_footprint: Dictionary = b.get("aggregateFootprint", {}) as Dictionary
	if not footprint_overlaps(first_footprint.get("center", Vector3.ZERO) as Vector3, float(first_footprint.get("width", 0.0)), float(first_footprint.get("depth", 0.0)), second_footprint.get("center", Vector3.ZERO) as Vector3, float(second_footprint.get("width", 0.0)), float(second_footprint.get("depth", 0.0)), clearance):
		return false
	for first_value in a.get("collisionParts", []) as Array:
		for second_value in b.get("collisionParts", []) as Array:
			if _parts_overlap(first_value as Dictionary, second_value as Dictionary, clearance):
				return true
	var first_corridor: Dictionary = a.get("doorCorridor", {}) as Dictionary
	var second_corridor: Dictionary = b.get("doorCorridor", {}) as Dictionary
	if _parts_overlap(first_corridor, second_corridor, clearance):
		return true
	for second_value in b.get("collisionParts", []) as Array:
		if _parts_overlap(first_corridor, second_value as Dictionary, clearance):
			return true
	for first_value in a.get("collisionParts", []) as Array:
		if _parts_overlap(second_corridor, first_value as Dictionary, clearance):
			return true
	return false


static func composition_overlaps_obstacles(composition: Dictionary, obstacle_parts: Array, clearance: float) -> bool:
	if not _valid_composition_shape(composition):
		return true
	for obstacle_value in obstacle_parts:
		if _validated_composition_overlaps_obstacle(composition, obstacle_value, clearance):
			return true
	return false


## One candidate-local proof, not a persistent cache. Exact per-obstacle results
## retain their input order so callers can preserve all rejection provenance.
## The callback receives no aliases to the private descriptors. Input mutation
## or cancellation discards the entire batch, never returning partial results.
static func composition_obstacle_overlap_indices(composition: Dictionary, obstacle_parts: Array, clearance: float, continuation: Callable = Callable()) -> Dictionary:
	var composition_bytes := var_to_bytes(composition)
	var obstacle_bytes := var_to_bytes(obstacle_parts)
	var private_composition := composition.duplicate(true)
	var private_obstacles := obstacle_parts.duplicate(true)
	var valid := _valid_composition_shape(private_composition)
	var overlaps: Array[int] = []
	for index in range(private_obstacles.size()):
		if continuation.is_valid() and continuation.call()!=true:
			return {"status":"cancelled"}
		if not valid or _validated_composition_overlaps_obstacle(private_composition, private_obstacles[index], clearance):
			overlaps.append(index)
	if composition_bytes!=var_to_bytes(composition) or obstacle_bytes!=var_to_bytes(obstacle_parts):
		return {"status":"cancelled"}
	return {"status":"ready", "overlapIndices":overlaps, "comparisons":private_obstacles.size()}


static func _validated_composition_overlaps_obstacle(composition: Dictionary, obstacle_value: Variant, clearance: float) -> bool:
	if not obstacle_value is Dictionary or not _valid_exact_part_descriptor(obstacle_value as Dictionary):
		return true
	var corridor: Dictionary = composition.get("doorCorridor", {}) as Dictionary
	var aggregate: Dictionary = composition.get("aggregateFootprint", {}) as Dictionary
	var aggregate_center: Vector3 = aggregate.get("center", Vector3.ZERO) as Vector3
	var aggregate_width := float(aggregate.get("width", 0.0))
	var aggregate_depth := float(aggregate.get("depth", 0.0))
	var obstacle: Dictionary = obstacle_value as Dictionary
	var obstacle_footprint := _part_footprint(obstacle)
	if not footprint_overlaps(aggregate_center, aggregate_width, aggregate_depth, obstacle_footprint.get("center", Vector3.ZERO) as Vector3, float(obstacle_footprint.get("width", 0.0)), float(obstacle_footprint.get("depth", 0.0)), clearance):
		return false
	if not corridor.is_empty() and _parts_overlap(corridor, obstacle, clearance):
		return true
	for part_value in composition.get("collisionParts", []) as Array:
		if _parts_overlap(part_value as Dictionary, obstacle, clearance):
			return true
	return false


static func footprint_overlaps(first_center: Vector3, first_width: float, first_depth: float, second_center: Vector3, second_width: float, second_depth: float, clearance := 0.0) -> bool:
	return absf(first_center.x - second_center.x) < (first_width + second_width) * 0.5 + clearance and absf(first_center.z - second_center.z) < (first_depth + second_depth) * 0.5 + clearance


static func composition_fits_bounds(composition: Dictionary, courtyard_width: float, courtyard_depth: float, inset: float) -> bool:
	var footprint: Dictionary = composition.get("aggregateFootprint", {}) as Dictionary
	if footprint.is_empty():
		return false
	var center: Vector3 = footprint.get("center", Vector3.ZERO) as Vector3
	return absf(center.x) + float(footprint.get("width", 0.0)) * 0.5 <= courtyard_width * 0.5 - inset \
		and absf(center.z) + float(footprint.get("depth", 0.0)) * 0.5 <= courtyard_depth * 0.5 - inset


static func first_overlap_provenance(candidate_id: String, candidate_side: String, composition: Dictionary, obstacle_parts: Array = [], placed_compositions: Array = [], clearance := 0.0) -> Dictionary:
	if not _valid_composition_shape(composition):
		return {"candidateId": candidate_id, "candidateSide": candidate_side, "collisionClass": "malformed_candidate_composition"}
	var corridor: Dictionary = composition.get("doorCorridor", {}) as Dictionary
	var aggregate: Dictionary = composition.get("aggregateFootprint", {}) as Dictionary
	var aggregate_center: Vector3 = aggregate.get("center", Vector3.ZERO) as Vector3
	var aggregate_width := float(aggregate.get("width", 0.0))
	var aggregate_depth := float(aggregate.get("depth", 0.0))
	for obstacle_value in obstacle_parts:
		if not obstacle_value is Dictionary or not _valid_exact_part_descriptor(obstacle_value as Dictionary):
			return {"candidateId": candidate_id, "candidateSide": candidate_side, "collisionClass": "malformed_structure_obstacle"}
		var obstacle: Dictionary = obstacle_value as Dictionary
		var obstacle_footprint := _part_footprint(obstacle)
		if not footprint_overlaps(aggregate_center, aggregate_width, aggregate_depth, obstacle_footprint.get("center", Vector3.ZERO) as Vector3, float(obstacle_footprint.get("width", 0.0)), float(obstacle_footprint.get("depth", 0.0)), clearance):
			continue
		var obstacle_part_id := String(obstacle.get("partId", obstacle.get("id", "")))
		var obstacle_owner_id := String(obstacle.get("ownerId", _structure_owner(obstacle_part_id)))
		var collision_class := "keep_or_tower" if obstacle_owner_id in ["keep", "tower"] else "structure"
		if not corridor.is_empty() and _parts_overlap(corridor, obstacle, clearance):
			return _provenance_record(candidate_id, candidate_side, collision_class, corridor, obstacle_part_id, obstacle_owner_id, obstacle)
		for part_value in composition.get("collisionParts", []) as Array:
			var candidate_part: Dictionary = part_value as Dictionary
			if _parts_overlap(candidate_part, obstacle, clearance):
				return _provenance_record(candidate_id, candidate_side, collision_class, candidate_part, obstacle_part_id, obstacle_owner_id, obstacle)
	for placed_value in placed_compositions:
		if not placed_value is Dictionary:
			continue
		var placed: Dictionary = placed_value as Dictionary
		var placed_composition: Dictionary = placed.get("compositionDescriptor", placed) as Dictionary
		var placed_id := String(placed.get("id", placed_composition.get("residenceId", "")))
		if not _valid_composition_shape(placed_composition):
			return {"candidateId": candidate_id, "candidateSide": candidate_side, "collisionClass": "malformed_placed_composition", "obstacleOwnerId": placed_id}
		var precise := _composition_collision_provenance(candidate_id, candidate_side, composition, placed_id, placed_composition, clearance)
		if not precise.is_empty():
			return precise
	return {}


static func refreshed_aggregate(composition: Dictionary) -> Dictionary:
	var result := composition.duplicate(true)
	var minimum_x := INF
	var maximum_x := -INF
	var minimum_z := INF
	var maximum_z := -INF
	var parts: Array = result.get("collisionParts", []) as Array
	var corridor: Dictionary = result.get("doorCorridor", {}) as Dictionary
	if not corridor.is_empty():
		parts = parts.duplicate()
		parts.append(corridor)
	for part_value in parts:
		var bounds := _part_horizontal_bounds(part_value as Dictionary)
		minimum_x = minf(minimum_x, bounds.position.x)
		maximum_x = maxf(maximum_x, bounds.end.x)
		minimum_z = minf(minimum_z, bounds.position.y)
		maximum_z = maxf(maximum_z, bounds.end.y)
	if minimum_x == INF:
		result["aggregateFootprint"] = {}
	else:
		result["aggregateFootprint"] = {"center": Vector3((minimum_x + maximum_x) * 0.5, 0.0, (minimum_z + maximum_z) * 0.5), "width": maximum_x - minimum_x, "depth": maximum_z - minimum_z, "sourceCollisionPartCount": (result.get("collisionParts", []) as Array).size()}
	return result


static func _valid_source_part(part) -> bool:
	if part == null or not part is BuildingPartScript:
		return false
	var position_value = (part as Object).get("position")
	var rotation_value = (part as Object).get("rotation")
	var size_value = (part as Object).get("size")
	if not position_value is Vector3 or not rotation_value is Vector3 or not size_value is Vector3:
		return false
	var position: Vector3 = position_value as Vector3
	var rotation: Vector3 = rotation_value as Vector3
	var size: Vector3 = size_value as Vector3
	return position.is_finite() and rotation.is_finite() and size.is_finite() and size.x > 0.0 and size.y > 0.0 and size.z > 0.0 and not String((part as Object).get("id")).is_empty()


static func _valid_composition_shape(composition: Dictionary) -> bool:
	var parts_value = composition.get("collisionParts", null)
	var corridor_value = composition.get("doorCorridor", null)
	var aggregate_value = composition.get("aggregateFootprint", null)
	if not parts_value is Array or (parts_value as Array).is_empty() or not corridor_value is Dictionary or not aggregate_value is Dictionary:
		return false
	for part_value in parts_value as Array:
		if not part_value is Dictionary or not _valid_exact_part_descriptor(part_value as Dictionary):
			return false
	if not _valid_exact_part_descriptor(corridor_value as Dictionary):
		return false
	var aggregate: Dictionary = aggregate_value as Dictionary
	var center_value = aggregate.get("center", null)
	var width_value = aggregate.get("width", null)
	var depth_value = aggregate.get("depth", null)
	return center_value is Vector3 and (center_value as Vector3).is_finite() \
		and (width_value is int or width_value is float) and is_finite(float(width_value)) and float(width_value) > 0.0 \
		and (depth_value is int or depth_value is float) and is_finite(float(depth_value)) and float(depth_value) > 0.0


static func _valid_exact_part_descriptor(part: Dictionary) -> bool:
	var center_value = part.get("center", null)
	var size_value = part.get("size", null)
	var basis_value = part.get("basis", null)
	if not center_value is Vector3 or not size_value is Vector3 or not basis_value is Basis:
		return false
	var center: Vector3 = center_value as Vector3
	var size: Vector3 = size_value as Vector3
	var basis: Basis = basis_value as Basis
	return center.is_finite() and size.is_finite() and size.x > 0.0 and size.y > 0.0 and size.z > 0.0 \
		and basis.x.is_finite() and basis.y.is_finite() and basis.z.is_finite() \
		and is_equal_approx(basis.x.length_squared(), 1.0) and is_equal_approx(basis.y.length_squared(), 1.0) and is_equal_approx(basis.z.length_squared(), 1.0) \
		and is_zero_approx(basis.x.dot(basis.y)) and is_zero_approx(basis.x.dot(basis.z)) and is_zero_approx(basis.y.dot(basis.z)) and absf(basis.determinant()) > 0.00001


static func _yaw_for_front_direction(front_direction: String) -> float:
	match front_direction:
		"north":
			return 0.0
		"south":
			return PI
		"east":
			return -PI * 0.5
		"west":
			return PI * 0.5
		_:
			return 0.0


static func _collision_part(id: String, center: Vector3, size: Vector3, basis: Basis, semantic: String, role: String, source_part_id: String, collision_enabled: bool) -> Dictionary:
	return {"id": id, "center": center, "size": size, "basis": basis, "rotation": basis.get_euler(), "semantic": semantic, "role": role, "sourcePartId": source_part_id, "collisionEnabled": collision_enabled}


static func _contextual_egress_part(source_part, residence_origin_y: float, compound_foundation_height: float, terrace_elevation := 0.0) -> Dictionary:
	var result := {
		"position": source_part.position,
		"rotation": source_part.rotation,
		"size": source_part.size
	}
	if String(source_part.semantic) == "entry_paving":
		var paving_position: Vector3 = source_part.position
		paving_position.y = compound_foundation_height + terrace_elevation + 0.14 - residence_origin_y - source_part.size.y * 0.5
		result["position"] = paving_position
		return result
	if String(source_part.semantic) != "entry_ramp":
		return result
	var size: Vector3 = source_part.size
	var source_basis := Basis.from_euler(source_part.rotation)
	var upper_surface: Vector3 = source_part.position + source_basis * Vector3(0.0, size.y * 0.5, size.z * 0.5)
	var paving_surface_local := compound_foundation_height + terrace_elevation + 0.14 - residence_origin_y
	var rise := maxf(0.02, upper_surface.y - paving_surface_local)
	var resolved_rotation := Vector3(-atan2(rise, maxf(size.z, 0.20)), 0.0, 0.0)
	var resolved_basis := Basis.from_euler(resolved_rotation)
	result["rotation"] = resolved_rotation
	result["position"] = upper_surface - resolved_basis * Vector3(0.0, size.y * 0.5, size.z * 0.5)
	return result


static func _egress_underfill_collision_parts(spec: Dictionary, source_part, resolved_part: Dictionary, compound_foundation_height: float) -> Array[Dictionary]:
	const UNDERFILL_CLEARANCE := 0.025
	const UNDERFILL_SEGMENTS := 4
	var result: Array[Dictionary] = []
	var origin: Vector3 = spec.get("origin", Vector3.ZERO) as Vector3
	var yaw := float(spec.get("yaw", 0.0))
	var yaw_basis := Basis(Vector3.UP, yaw)
	var ramp_position: Vector3 = resolved_part.get("position", source_part.position) as Vector3
	var ramp_rotation: Vector3 = resolved_part.get("rotation", source_part.rotation) as Vector3
	var ramp_size: Vector3 = resolved_part.get("size", source_part.size) as Vector3
	var ramp_transform := Transform3D(yaw_basis * Basis.from_euler(ramp_rotation), origin + yaw_basis * ramp_position)
	for segment_index in range(UNDERFILL_SEGMENTS):
		var segment_depth := ramp_size.z / float(UNDERFILL_SEGMENTS)
		var local_z := -ramp_size.z * 0.5 + segment_depth * (float(segment_index) + 0.5)
		var ramp_underside: Vector3 = ramp_transform * Vector3(0.0, -ramp_size.y * 0.5, local_z)
		var fill_top := ramp_underside.y - UNDERFILL_CLEARANCE
		if fill_top <= 0.04:
			continue
		var segment_center := origin + yaw_basis * (ramp_position + Vector3(0.0, 0.0, local_z))
		segment_center.y = fill_top * 0.5
		result.append(_collision_part("egress_underfill_%02d" % segment_index, segment_center, Vector3(ramp_size.x + 0.08, fill_top, segment_depth + 0.03), yaw_basis, "castle_residence_egress_underfill", "egress_underfill", String(source_part.id), true))
	return result


static func _egress_landing_underfill_collision_part(spec: Dictionary, source_part, resolved_part: Dictionary) -> Dictionary:
	const UNDERFILL_CLEARANCE := 0.025
	var origin: Vector3 = spec.get("origin", Vector3.ZERO) as Vector3
	var yaw_basis := Basis(Vector3.UP, float(spec.get("yaw", 0.0)))
	var landing_position: Vector3 = resolved_part.get("position", source_part.position) as Vector3
	var landing_rotation: Vector3 = resolved_part.get("rotation", source_part.rotation) as Vector3
	var landing_size: Vector3 = resolved_part.get("size", source_part.size) as Vector3
	var landing_basis := yaw_basis * Basis.from_euler(landing_rotation)
	var landing_normal := landing_basis.y.normalized()
	if landing_normal.y < 0.985:
		return {}
	var landing_center := origin + yaw_basis * landing_position
	var underside_y := landing_center.y - absf(landing_basis.x.y) * landing_size.x * 0.5 - absf(landing_basis.y.y) * landing_size.y * 0.5 - absf(landing_basis.z.y) * landing_size.z * 0.5
	var fill_top := underside_y - UNDERFILL_CLEARANCE
	if fill_top <= 0.04:
		return {}
	var underfill_center := Vector3(landing_center.x, fill_top * 0.5, landing_center.z)
	return _collision_part(
		"egress_underfill_%s" % String(source_part.id),
		underfill_center,
		Vector3(landing_size.x + 0.08, fill_top, landing_size.z + 0.08),
		yaw_basis,
		"castle_residence_egress_underfill",
		"egress_underfill",
		String(source_part.id),
		true
	)


static func _plinth_collision_part(spec: Dictionary, source_blueprint, compound_foundation_height: float) -> Dictionary:
	var origin: Vector3 = spec.get("origin", Vector3.ZERO) as Vector3
	var yaw_basis := Basis(Vector3.UP, float(spec.get("yaw", 0.0)))
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	var found := false
	for source_part in source_blueprint.parts:
		if source_part == null or String(source_part.kind) != "foundation" or not bool(source_part.collision_enabled):
			continue
		found = true
		var transform := Transform3D(yaw_basis * Basis.from_euler(source_part.rotation), origin + yaw_basis * source_part.position)
		for x_sign in [-1.0, 1.0]:
			for y_sign in [-1.0, 1.0]:
				for z_sign in [-1.0, 1.0]:
					var corner := transform * Vector3(source_part.size.x * 0.5 * x_sign, source_part.size.y * 0.5 * y_sign, source_part.size.z * 0.5 * z_sign)
					minimum = minimum.min(corner)
					maximum = maximum.max(corner)
	var plinth_height := minimum.y - compound_foundation_height
	if not found or plinth_height <= 0.04:
		return {}
	return _collision_part("structural_plinth", Vector3((minimum.x + maximum.x) * 0.5, compound_foundation_height + plinth_height * 0.5, (minimum.z + maximum.z) * 0.5), Vector3(maximum.x - minimum.x, plinth_height, maximum.z - minimum.z), Basis.IDENTITY, "castle_residence_structural_plinth", "plinth", "", true)


static func _facade_collision_parts(spec: Dictionary, door: Dictionary, foundation_height: float) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if door.is_empty():
		return result
	var outward: Vector3 = door.get("exteriorNormal", Vector3.FORWARD) as Vector3
	var lateral := Vector3.BACK if absf(outward.x) > 0.5 else Vector3.RIGHT
	var door_center: Vector3 = door.get("center", spec.get("center", Vector3.ZERO)) as Vector3
	var door_basis: Basis = door.get("basis", Basis.IDENTITY) as Basis
	var door_size: Vector3 = door.get("size", Vector3.ZERO) as Vector3
	var entry_width := float(door.get("openingWidth", absf(lateral.dot(door_basis.x)) * door_size.x + absf(lateral.dot(door_basis.y)) * door_size.y + absf(lateral.dot(door_basis.z)) * door_size.z))
	var center: Vector3 = spec.get("center", Vector3.ZERO) as Vector3
	var terrace_elevation := float(spec.get("terraceElevation", 0.0))
	var wall_height := float((spec.get("residenceRecipe", {}) as Dictionary).get("wallHeight", 7.0))
	var width := float(spec.get("width", 8.0))
	var depth := float(spec.get("depth", 8.0))
	var facade_center := Vector3(door_center.x, center.y, door_center.z) + outward * 0.42
	var detail_y := foundation_height + terrace_elevation + minf(wall_height * 0.58, 6.2)
	var pilaster_lateral_offset := entry_width * 0.5 + 0.72
	var detail_span := maxf(clampf((depth if absf(outward.x) > 0.5 else width) * 0.24, 1.8, 3.0), pilaster_lateral_offset * 2.0 + 0.40)
	var awning_size := Vector3(0.92, 0.14, detail_span) if absf(outward.x) > 0.5 else Vector3(detail_span, 0.14, 0.92)
	for bracket_side in [-1.0, 1.0]:
		var bracket_offset: Vector3 = lateral * bracket_side * pilaster_lateral_offset
		var anchor_height := maxf(0.30, detail_y + awning_size.y * 0.5)
		var anchor_center: Vector3 = Vector3(facade_center.x, anchor_height * 0.5, facade_center.z) + bracket_offset - outward * 0.18
		result.append(_collision_part("castle_residence_awning_pilaster_%s_%d" % [String(spec.get("id", "home")), int(bracket_side)], anchor_center, Vector3(0.20, anchor_height, 0.20), Basis.IDENTITY, "castle_residence_awning_pilaster", "facade", "", true))
	var publishes_balcony := terrace_elevation > 0.1 or posmod(String(spec.get("id", "home")).hash(), 5) == 0
	if publishes_balcony:
		var balcony_size := Vector3(1.05, 0.18, detail_span * 0.88) if absf(outward.x) > 0.5 else Vector3(detail_span * 0.88, 0.18, 1.05)
		var balcony_center := Vector3(facade_center.x, detail_y - 0.36, facade_center.z)
		var underframe_size := Vector3(balcony_size.x, 0.12, balcony_size.z)
		var underframe_center := balcony_center - Vector3.UP * (balcony_size.y * 0.5 + underframe_size.y * 0.5)
		var door_vertical_extent := absf(door_basis.x.y) * door_size.x * 0.5 + absf(door_basis.y.y) * door_size.y * 0.5 + absf(door_basis.z.y) * door_size.z * 0.5
		var corridor_top := door_center.y - door_vertical_extent + 0.24 + float(NpcConstantsScript.DEFAULT_NPC_STANDING_HEIGHT)
		if underframe_center.y - underframe_size.y * 0.5 <= corridor_top + 0.12:
			publishes_balcony = false
	if publishes_balcony:
		var balcony_size := Vector3(1.05, 0.18, detail_span * 0.88) if absf(outward.x) > 0.5 else Vector3(detail_span * 0.88, 0.18, 1.05)
		var balcony_center := Vector3(facade_center.x, detail_y - 0.36, facade_center.z)
		var underframe_size := Vector3(balcony_size.x, 0.12, balcony_size.z)
		var underframe_center := balcony_center - Vector3.UP * (balcony_size.y * 0.5 + underframe_size.y * 0.5)
		var radial_half_span := balcony_size.x * 0.5 if absf(outward.x) > 0.5 else balcony_size.z * 0.5
		var support_wall_height := maxf(0.24, underframe_center.y + underframe_size.y * 0.5 - (foundation_height + terrace_elevation + 0.14))
		var support_pier_center := balcony_center - outward * (radial_half_span - 0.09)
		support_pier_center.y = foundation_height + terrace_elevation + 0.14 + support_wall_height * 0.5
		for pier_side in [-1.0, 1.0]:
			result.append(_collision_part("castle_residence_balcony_%s_support_pier_%d" % [String(spec.get("id", "home")), int(pier_side)], support_pier_center + lateral * pier_side * pilaster_lateral_offset, Vector3(0.20, support_wall_height, 0.20), Basis.IDENTITY, "castle_residence_balcony_support_pier", "facade", "", true))
		result.append(_collision_part("castle_residence_balcony_%s_underframe" % String(spec.get("id", "home")), underframe_center, underframe_size, Basis.IDENTITY, "castle_residence_balcony_underframe", "facade", "", true))
		result.append(_collision_part("castle_residence_balcony_%s" % String(spec.get("id", "home")), balcony_center, balcony_size, Basis.IDENTITY, "castle_residence_balcony", "facade", "", true))
	var district_class := String(spec.get("districtClass", ""))
	if bool(spec.get("supportsFacadeProjections", false)) and district_class in ["civic", "civic_anchor", "sightline_screen"]:
		var stable_selector := absi(String(spec.get("id", "home")).hash()) % 5
		if district_class == "sightline_screen" or stable_selector in [1, 3, 4]:
			var projection_depth := 0.72 + float(stable_selector % 3) * 0.18
			var projection_span := clampf((depth if absf(outward.x) > 0.5 else width) * (0.30 + float(stable_selector % 2) * 0.05), 2.5, 4.2)
			var projection_height := clampf(wall_height * 0.30, 1.75, 2.35)
			var lateral_bias := (float(stable_selector) - 2.0) * 0.24
			var projection_lateral := Vector3.FORWARD if absf(outward.x) > 0.5 else Vector3.RIGHT
			var projection_center := facade_center + outward * (projection_depth * 0.5 - 0.36) + projection_lateral * lateral_bias
			projection_center.y = foundation_height + terrace_elevation + wall_height - projection_height * 0.56
			var backing_size := Vector3(projection_depth + 0.34, projection_height * 0.90, projection_span * 0.78) if absf(outward.x) > 0.5 else Vector3(projection_span * 0.78, projection_height * 0.90, projection_depth + 0.34)
			var backing_center := projection_center - outward * (projection_depth * 0.50 + 0.12)
			result.append(_collision_part("castle_route_frontage_oriel_backing_%s" % String(spec.get("id", "home")), backing_center, backing_size, Basis.IDENTITY, "castle_route_frontage_oriel_backing", "facade", "", true))
	return result


static func _parts_overlap(first: Dictionary, second: Dictionary, horizontal_clearance := 0.0) -> bool:
	var first_center: Vector3 = first.get("center", Vector3.ZERO) as Vector3
	var second_center: Vector3 = second.get("center", Vector3.ZERO) as Vector3
	var first_basis: Basis = first.get("basis", Basis.IDENTITY) as Basis
	var second_basis: Basis = second.get("basis", Basis.IDENTITY) as Basis
	var first_half: Vector3 = (first.get("size", Vector3.ZERO) as Vector3) * 0.5
	var second_half: Vector3 = (second.get("size", Vector3.ZERO) as Vector3) * 0.5
	var first_world_half := Vector3(
		absf(first_basis.x.x) * first_half.x + absf(first_basis.y.x) * first_half.y + absf(first_basis.z.x) * first_half.z,
		absf(first_basis.x.y) * first_half.x + absf(first_basis.y.y) * first_half.y + absf(first_basis.z.y) * first_half.z,
		absf(first_basis.x.z) * first_half.x + absf(first_basis.y.z) * first_half.y + absf(first_basis.z.z) * first_half.z
	)
	var second_world_half := Vector3(
		absf(second_basis.x.x) * second_half.x + absf(second_basis.y.x) * second_half.y + absf(second_basis.z.x) * second_half.z,
		absf(second_basis.x.y) * second_half.x + absf(second_basis.y.y) * second_half.y + absf(second_basis.z.y) * second_half.z,
		absf(second_basis.x.z) * second_half.x + absf(second_basis.y.z) * second_half.y + absf(second_basis.z.z) * second_half.z
	)
	var broad_delta := (second_center - first_center).abs()
	if broad_delta.x >= first_world_half.x + second_world_half.x + horizontal_clearance - 0.0001 or broad_delta.y >= first_world_half.y + second_world_half.y - 0.0001 or broad_delta.z >= first_world_half.z + second_world_half.z + horizontal_clearance - 0.0001:
		return false
	# Clearance is a world-horizontal square Minkowski margin. Add its support
	# radius on every tested separating axis instead of inflating local X/Z,
	# which understates horizontal clearance for pitched parts.
	var axes: Array[Vector3] = [Vector3.RIGHT, Vector3.UP, Vector3.FORWARD, first_basis.x.normalized(), first_basis.y.normalized(), first_basis.z.normalized(), second_basis.x.normalized(), second_basis.y.normalized(), second_basis.z.normalized()]
	for first_axis in [first_basis.x, first_basis.y, first_basis.z]:
		for second_axis in [second_basis.x, second_basis.y, second_basis.z]:
			var cross_axis: Vector3 = first_axis.cross(second_axis)
			if cross_axis.length_squared() > 0.000001:
				axes.append(cross_axis.normalized())
	var delta := second_center - first_center
	for axis in axes:
		var first_radius := absf(axis.dot(first_basis.x)) * first_half.x + absf(axis.dot(first_basis.y)) * first_half.y + absf(axis.dot(first_basis.z)) * first_half.z
		var second_radius := absf(axis.dot(second_basis.x)) * second_half.x + absf(axis.dot(second_basis.y)) * second_half.y + absf(axis.dot(second_basis.z)) * second_half.z
		var clearance_radius := horizontal_clearance * (absf(axis.x) + absf(axis.z))
		if absf(axis.dot(delta)) >= first_radius + second_radius + clearance_radius - 0.0001:
			return false
	return true


static func _part_horizontal_bounds(part: Dictionary) -> Rect2:
	var center: Vector3 = part.get("center", Vector3.ZERO) as Vector3
	var size: Vector3 = part.get("size", Vector3.ZERO) as Vector3
	var basis: Basis = part.get("basis", Basis.IDENTITY) as Basis
	var half_x := absf(basis.x.x) * size.x * 0.5 + absf(basis.y.x) * size.y * 0.5 + absf(basis.z.x) * size.z * 0.5
	var half_z := absf(basis.x.z) * size.x * 0.5 + absf(basis.y.z) * size.y * 0.5 + absf(basis.z.z) * size.z * 0.5
	return Rect2(center.x - half_x, center.z - half_z, half_x * 2.0, half_z * 2.0)


static func _part_footprint(part: Dictionary) -> Dictionary:
	var bounds := _part_horizontal_bounds(part)
	return {
		"center": part.get("center", Vector3.ZERO) as Vector3,
		"width": bounds.size.x,
		"depth": bounds.size.y
	}


static func _composition_collision_provenance(candidate_id: String, candidate_side: String, candidate: Dictionary, obstacle_owner_id: String, obstacle: Dictionary, clearance: float) -> Dictionary:
	var candidate_footprint: Dictionary = candidate.get("aggregateFootprint", {}) as Dictionary
	var obstacle_footprint: Dictionary = obstacle.get("aggregateFootprint", {}) as Dictionary
	if not footprint_overlaps(candidate_footprint.get("center", Vector3.ZERO) as Vector3, float(candidate_footprint.get("width", 0.0)), float(candidate_footprint.get("depth", 0.0)), obstacle_footprint.get("center", Vector3.ZERO) as Vector3, float(obstacle_footprint.get("width", 0.0)), float(obstacle_footprint.get("depth", 0.0)), clearance):
		return {}
	for candidate_value in candidate.get("collisionParts", []) as Array:
		for obstacle_value in obstacle.get("collisionParts", []) as Array:
			if _parts_overlap(candidate_value as Dictionary, obstacle_value as Dictionary, clearance):
				return _provenance_record(candidate_id, candidate_side, "prior_residence_composition", candidate_value as Dictionary, String((obstacle_value as Dictionary).get("id", "")), obstacle_owner_id, obstacle_value as Dictionary)
	var candidate_corridor: Dictionary = candidate.get("doorCorridor", {}) as Dictionary
	for obstacle_value in obstacle.get("collisionParts", []) as Array:
		if _parts_overlap(candidate_corridor, obstacle_value as Dictionary, clearance):
			return _provenance_record(candidate_id, candidate_side, "prior_residence_composition", candidate_corridor, String((obstacle_value as Dictionary).get("id", "")), obstacle_owner_id, obstacle_value as Dictionary)
	var obstacle_corridor: Dictionary = obstacle.get("doorCorridor", {}) as Dictionary
	for candidate_value in candidate.get("collisionParts", []) as Array:
		if _parts_overlap(obstacle_corridor, candidate_value as Dictionary, clearance):
			return _provenance_record(candidate_id, candidate_side, "prior_residence_composition", candidate_value as Dictionary, String(obstacle_corridor.get("id", "")), obstacle_owner_id, obstacle_corridor)
	if _parts_overlap(candidate_corridor, obstacle_corridor, clearance):
		return _provenance_record(candidate_id, candidate_side, "prior_residence_composition", candidate_corridor, String(obstacle_corridor.get("id", "")), obstacle_owner_id, obstacle_corridor)
	return {}


static func _provenance_record(candidate_id: String, candidate_side: String, collision_class: String, candidate_part: Dictionary, obstacle_part_id: String, obstacle_owner_id: String, obstacle_part: Dictionary) -> Dictionary:
	return {
		"candidateId": candidate_id,
		"candidateSide": candidate_side,
		"candidatePartId": String(candidate_part.get("id", candidate_part.get("partId", ""))),
		"candidateRole": String(candidate_part.get("role", "")),
		"candidateSemantic": String(candidate_part.get("semantic", "")),
		"collisionClass": collision_class,
		"obstacleOwnerId": obstacle_owner_id,
		"obstaclePartId": obstacle_part_id,
		"obstacleRole": String(obstacle_part.get("role", "")),
		"obstacleSemantic": String(obstacle_part.get("semantic", ""))
	}


static func _structure_owner(part_id: String) -> String:
	if part_id.begins_with("castle_tower_"):
		return "tower"
	if part_id.begins_with("castle_keep_"):
		return "keep"
	return "unknown_structure"
