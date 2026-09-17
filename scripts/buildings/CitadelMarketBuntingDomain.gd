extends RefCounted

## Producer-supplied house associations, not row/seed/name inference. This is
## an assembly envelope and candidate ownership, NOT a rooted/socket/clearance
## proof. The caller must fit the entire rope AND unchanged pennants in bounds;
## only its separately proven tiny X socket embeds may cross the facade faces.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const Houses = preload("res://scripts/buildings/CitadelStreetHouseStructuralManifest.gd")
const Aperture = preload("res://scripts/buildings/FacadeApertureDeclaration.gd")

static func build(source, left_house_id: String, right_house_id: String, plaza_part_id: String) -> Dictionary:
	if not source is Blueprint or source._validation_cache_active or source.parts.size() > Houses.MAX_PARTS:
		return _fail("invalid_market_domain_source")
	for id: String in [left_house_id, right_house_id, plaza_part_id]:
		if not _id(id): return _fail("invalid_market_domain_id")
	if left_house_id == right_house_id: return _fail("duplicate_market_house")
	var by_id: Dictionary = {}
	for part in source.parts:
		if not part is Part or not _id(part.id) or by_id.has(part.id): return _fail("invalid_market_source_parts")
		by_id[part.id] = part
	var collection: Variant = source.recipe.get(Houses.KEY)
	var declarations: Variant = source.recipe.get("facadeApertures")
	if not collection is Dictionary or not declarations is Dictionary:
		return _fail("missing_market_house_declarations")
	var rooms: Dictionary = {}
	for room: Variant in source.rooms:
		if not room is Dictionary: return _fail("invalid_market_room")
		if room.has("citadelUrbanRoom") and not room.citadelUrbanRoom is bool: return _fail("invalid_market_room")
		if not room.get("citadelUrbanRoom", false): continue
		if not _id(room.get("id")) or rooms.has(room.id) or not _box(room.get("bounds")):
			return _fail("invalid_market_room")
		rooms[room.id] = room.bounds
	var left: Dictionary = _front(source, left_house_id, 1.0, collection, declarations, by_id, rooms)
	if not left.ready: return left
	var right: Dictionary = _front(source, right_house_id, -1.0, collection, declarations, by_id, rooms)
	if not right.ready: return right
	if left.roomId == right.roomId or left.face >= right.face: return _fail("invalid_market_facade_gap")
	for id: String in left.ids:
		if right.ids.has(id): return _fail("shared_market_facade_member")
	var plaza = by_id.get(plaza_part_id)
	# This source-owned finish describes the market assembly's visible extent;
	# the continuous courtyard course below it owns public-ground collision.
	# Requiring (or accepting) a second colliding plaza would recreate the raised
	# duplicate platform deliberately removed by the single-grade recipe.
	if (not plaza is Part or not _part_geometry(plaza) or plaza.collision_enabled or plaza.kind != "ground_patch"
			or plaza.semantic != "citadel_market_plaza" or plaza.rotation != Vector3.ZERO
			or plaza.physical_intent != "visual_detail"
			or plaza.recipe.get("pavingRegion") != "citadel_courtyard"):
		return _fail("invalid_market_plaza")
	var paving: AABB = source.transformed_part_bounds(plaza)
	if not _box(paving): return _fail("invalid_market_plaza_bounds")
	# Do not clip an anchor out of the domain and silently call the smaller
	# interval usable. Both physical facade faces must lie over the real plaza.
	if paving.position.x > left.face or paving.end.x < right.face:
		return _fail("market_plaza_does_not_cover_anchors")
	var lower := Vector3(left.face, maxf(paving.end.y, maxf(left.bounds.position.y, right.bounds.position.y)),
		maxf(paving.position.z, maxf(left.bounds.position.z, right.bounds.position.z)))
	var upper := Vector3(right.face, minf(left.bounds.end.y, right.bounds.end.y),
		minf(paving.end.z, minf(left.bounds.end.z, right.bounds.end.z)))
	var bounds := AABB(lower, upper - lower)
	if not _box(bounds): return _fail("empty_market_bunting_domain")
	var protected_rooms: Array[AABB] = []
	var room_ids: Array = rooms.keys()
	room_ids.sort()
	for id: String in room_ids: protected_rooms.append(rooms[id])
	return {"ready": true, "domain": {"leftAnchorIds": left.ids, "rightAnchorIds": right.ids, "bounds": bounds},
		"protectedRooms": protected_rooms}

static func _front(source, house_id: String, direction: float, collection: Dictionary, declarations: Dictionary,
		by_id: Dictionary, rooms: Dictionary) -> Dictionary:
	var record: Variant = collection.get(house_id)
	if (not record is Dictionary or record.get("producerPrefix") != house_id or not _id(record.get("roomId"))
			or not _id(record.get("doorId")) or not rooms.has(record.roomId)):
		return _fail("invalid_market_house_record", house_id)
	var room: AABB = rooms[record.roomId]
	var door = by_id.get(record.doorId)
	if (not door is Part or not _part_geometry(door) or door.kind != "door" or door.semantic != "citadel_urban_door"
			or door.recipe.get("roomId") != record.roomId):
		return _fail("invalid_market_house_door", house_id)
	# Current street producers encode their front through the exterior door and
	# interior room, not a front enum. Reject swapped/back-facing associations.
	if (door.position.x - room.get_center().x) * direction <= 0.0:
		return _fail("market_house_faces_away", house_id)
	var keys: Variant = record.get("facadeDeclarationKeys")
	if not keys is Array or keys.is_empty() or keys.size() > 4: return _fail("invalid_market_facade_keys", house_id)
	var seen_keys: Dictionary = {}
	var seen_parts: Dictionary = {}
	var ids: Array[String] = []
	var envelope := AABB()
	var face: float = NAN
	for key: Variant in keys:
		if not _id(key) or seen_keys.has(key): return _fail("invalid_market_facade_key", house_id)
		seen_keys[key] = true
		var declaration: Variant = declarations.get(key)
		if (not declaration is Dictionary or declaration.get("producerPrefix") != key
				or declaration.get("semantic") != "citadel_urban_facade" or not _box(declaration.get("wallDomain"))):
			return _fail("invalid_market_facade_declaration", house_id)
		if not Aperture.validate(declaration, by_id): return _fail("stale_market_facade_declaration", house_id)
		var domain: AABB = declaration.wallDomain
		# Only the X-facing facade in front of this room is eligible. A sealed
		# gable/back declaration is not automatically an opposing market facade.
		var declaration_face: float = domain.end.x if direction > 0.0 else domain.position.x
		var room_front: float = room.end.x if direction > 0.0 else room.position.x
		if (declaration_face - room_front) * direction <= 0.0: continue
		if absf(door.position.x - declaration_face) >= absf(door.position.x - room.get_center().x): continue
		for id: String in declaration.partIds:
			var part = by_id[id]
			if not _part_geometry(part): return _fail("invalid_market_facade_member", house_id)
			# Opening completion seals timber heads/connections into the same
			# declaration. The complete seal was validated above; like structural
			# completion's facade selection, only masonry contributes anchors/bounds.
			if part.semantic != "citadel_urban_facade": continue
			if (not part.collision_enabled or part.kind != "wall"
					or part.rotation != Vector3.ZERO or seen_parts.has(id)):
				return _fail("invalid_market_facade_member", house_id)
			var bounds: AABB = source.transformed_part_bounds(part)
			if not _box(bounds): return _fail("invalid_market_facade_bounds", house_id)
			# Seal binds actual geometry. These checks additionally establish a
			# common X slab; float comparison is only declaration/part round-trip,
			# never expansion of the returned domain or a collision tolerance.
			if not is_equal_approx(bounds.position.x, domain.position.x) or not is_equal_approx(bounds.end.x, domain.end.x):
				return _fail("nonplanar_market_facade", house_id)
			if not _inside_declared(bounds, domain): return _fail("market_facade_outside_declaration", house_id)
			var part_face: float = bounds.end.x if direction > 0.0 else bounds.position.x
			if not is_nan(face) and part_face != face: return _fail("noncoplanar_market_facades", house_id)
			face = part_face
			envelope = bounds if ids.is_empty() else envelope.merge(bounds)
			seen_parts[id] = true
			ids.append(id)
	if ids.is_empty(): return _fail("missing_market_front_facade", house_id)
	ids.sort()
	return {"ready": true, "ids": ids, "bounds": envelope, "face": face, "roomId": record.roomId}

static func _inside_declared(inner: AABB, outer: AABB) -> bool:
	for axis in range(3):
		if inner.position[axis] < outer.position[axis] and not is_equal_approx(inner.position[axis], outer.position[axis]): return false
		if inner.end[axis] > outer.end[axis] and not is_equal_approx(inner.end[axis], outer.end[axis]): return false
	return true

static func _part_geometry(part) -> bool:
	return part.position.is_finite() and part.rotation.is_finite() and part.size.is_finite() and part.size.x > 0.0 and part.size.y > 0.0 and part.size.z > 0.0

static func _box(value: Variant) -> bool:
	return (value is AABB and value.position.is_finite() and value.size.is_finite() and value.end.is_finite()
		and value.size.x > 0.0 and value.size.y > 0.0 and value.size.z > 0.0)

static func _id(value: Variant) -> bool:
	return value is String and not value.is_empty() and value == value.strip_edges()

static func _fail(reason: String, house_id: String = "") -> Dictionary:
	return {"ready": false, "reason": reason, "houseId": house_id}
