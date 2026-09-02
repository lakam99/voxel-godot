extends RefCounted
class_name BuildingPublicationSource

## Decode an accepted source snapshot for the existing publishers. Run on an
## owned worker: copying recipes and verifying complete snapshots is not frame
## work. No placement, generation, filtering, geometry repair or scene access.
const BlueprintCopy = preload("res://scripts/buildings/FacadeOpeningBearingRecipe.gd")
const Furnishings = preload("res://scripts/buildings/FurnishingPlan.gd")
const Furnishing = preload("res://scripts/buildings/FurnishingPart.gd")
const MAX_PARTS := 10000
const MAX_FURNISHINGS := 10000

static func restore(building: Dictionary, furniture: Dictionary, continuation: Callable = Callable()) -> Dictionary:
	if not _continue(continuation,"publication_source_begin"): return _failed("cancelled")
	if not _valid_building(building) or not _valid_furniture(furniture):
		return _failed("invalid_publication_source_snapshot")
	# The existing copy routine preserves represented thin geometry rather than
	# applying constructor minimum dimensions intended for newly authored parts.
	var blueprint = BlueprintCopy.copy_blueprint(building)
	if not _continue(continuation,"publication_source_building"): return _failed("cancelled")
	var plan = Furnishings.new(furniture.id,int(furniture.seed),furniture.sourceBlueprintId)
	plan.egress_diagnostics = furniture.egressDiagnostics.duplicate(true)
	for record: Dictionary in furniture.parts:
		if not _continue(continuation,"publication_source_furnishing"): return _failed("cancelled")
		# Restore accepted instances, not a new placement pass through add_part.
		var part = Furnishing.new(record)
		part.occupied_size = record.occupiedSize
		plan.parts.append(part)
	for reservation: AABB in furniture.accessReservations:
		if not _continue(continuation,"publication_source_reservation"): return _failed("cancelled")
		plan.protected_access_reservations.append(reservation)
	if not _continue(continuation,"publication_source_verify"): return _failed("cancelled")
	var expected_furniture := furniture.duplicate()
	expected_furniture.erase("accessReservations")
	# Serialization equality includes ordered parts, full recipes, physical facts,
	# rooms and furnishing diagnostics. Do not accept only matching counts/IDs.
	if var_to_bytes(blueprint.snapshot()) != var_to_bytes(building) \
			or var_to_bytes(plan.snapshot()) != var_to_bytes(expected_furniture) \
			or plan.access_reservations_snapshot() != furniture.accessReservations:
		return _failed("publication_source_roundtrip_mismatch")
	if not _continue(continuation,"publication_source_ready"): return _failed("cancelled")
	return {"ready":true,"reason":"","blueprint":blueprint,"furnishingPlan":plan}

static func _valid_building(value: Dictionary) -> bool:
	for key in ["id","style"]:
		if not value.get(key) is String: return false
	if not value.get("seed") is int or not value.get("recipe") is Dictionary or not value.get("rooms") is Array \
			or not value.get("parts") is Array or value.parts.size()>MAX_PARTS: return false
	var ids := {}
	for record in value.parts:
		if not record is Dictionary or not record.get("id") is String or record.id.is_empty() or ids.has(record.id): return false
		ids[record.id] = true
		if not record.get("recipe") is Dictionary or not record.get("physicalIntent") is String: return false
		if not _valid_pose(record,"size"): return false
	return true

static func _valid_furniture(value: Dictionary) -> bool:
	for key in ["id","sourceBlueprintId"]:
		if not value.get(key) is String: return false
	if not value.get("seed") is int or not value.get("egressDiagnostics") is Dictionary or not value.get("parts") is Array \
			or value.parts.size()>MAX_FURNISHINGS or not value.get("accessReservations") is Array: return false
	var ids := {}
	for record in value.parts:
		if not record is Dictionary or not record.get("id") is String or record.id.is_empty() or ids.has(record.id): return false
		ids[record.id] = true
		if not record.get("recipe") is Dictionary or not _valid_pose(record,"occupiedSize"): return false
	for reservation in value.accessReservations:
		if not reservation is AABB or not reservation.position.is_finite() or not reservation.end.is_finite(): return false
	return true

static func _valid_pose(record: Dictionary, size_key: String) -> bool:
	for key in ["position","rotation",size_key]:
		if not record.get(key) is Vector3 or not record[key].is_finite(): return false
	var size: Vector3 = record[size_key]
	return size.x>0.0 and size.y>0.0 and size.z>0.0

static func _continue(callback: Callable, stage: String) -> bool:
	return not callback.is_valid() or callback.call(stage)==true

static func _failed(reason: String) -> Dictionary:
	return {"ready":false,"reason":reason}
