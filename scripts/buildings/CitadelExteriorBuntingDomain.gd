extends RefCounted
## Producer geometry receipts identify an exterior mounting relationship only.
## Independent socket, rooting and clearance proof remains in the anchor recipe.
const Blueprint = preload("res://scripts/buildings/BuildingBlueprint.gd")
const Part = preload("res://scripts/buildings/BuildingPart.gd")
const MOUNT := "citadelExteriorBuntingMount"
const OWNERS := "buntingExteriorOwners"
const MAX_PARTS := 10000
const MAX_ROOMS := 4096

static func declare(part, role: String, side: int) -> void:
	part.recipe[MOUNT] = {"role": role, "side": side, "geometryBinding": _geometry(part)}

static func association(source) -> Dictionary:
	var indexed := _index(source)
	if not indexed.ready: return indexed
	if not indexed.roles.has("landmark:0") or not indexed.roles.has("forecourt_pavilion:1"):
		return _fail("missing_exterior_bunting_mount")
	if indexed.courtyards.size() != 1: return _fail("ambiguous_exterior_bunting_courtyard")
	return {"ready": true, "owners": {"leftPartId": indexed.roles["landmark:0"].id,
		"rightPartId": indexed.roles["forecourt_pavilion:1"].id, "courtyardId": indexed.courtyards[0].id}}

static func build(source, owners: Variant) -> Dictionary:
	if not owners is Dictionary or owners.size() != 3: return _fail("invalid_exterior_bunting_owners")
	for key: String in ["leftPartId", "rightPartId", "courtyardId"]:
		if not _id(owners.get(key)): return _fail("invalid_exterior_bunting_owner_id")
	var indexed := _index(source)
	if not indexed.ready: return indexed
	if not indexed.roles.has("landmark:0") or not indexed.roles.has("forecourt_pavilion:1") or indexed.courtyards.size() != 1:
		return _fail("missing_or_ambiguous_exterior_bunting_owners")
	var left = indexed.roles["landmark:0"]; var right = indexed.roles["forecourt_pavilion:1"]
	var courtyard: Dictionary = indexed.courtyards[0]
	if owners.leftPartId != left.id or owners.rightPartId != right.id or owners.courtyardId != courtyard.id:
		return _fail("foreign_exterior_bunting_owners")
	var a: AABB = source.transformed_part_bounds(left); var b: AABB = source.transformed_part_bounds(right)
	var lower := Vector3(a.end.x, maxf(a.position.y, b.position.y), maxf(a.position.z, b.position.z))
	var upper := Vector3(b.position.x, minf(a.end.y, b.end.y), minf(a.end.z, b.end.z))
	var domain := AABB(lower, upper-lower)
	if not _box(domain): return _fail("empty_exterior_bunting_domain")
	var outer: AABB = courtyard.bounds
	if domain.position.x < outer.position.x or domain.end.x > outer.end.x or domain.position.z < outer.position.z or domain.end.z > outer.end.z:
		return _fail("exterior_bunting_outside_courtyard")
	return {"ready": true, "domain": {"leftAnchorIds": [left.id], "rightAnchorIds": [right.id], "bounds": domain},
		"protectedRooms": indexed.protectedRooms}

## Producer preflight only: optional dressing may be emitted only when its
## authored centre belongs to the declared mount relationship.  This neither
## proves a socket nor clearance; StructuralCompletion remains the sole
## physical acceptance boundary.
static func accepts_authored_center(source, owners: Variant, center: Vector3) -> bool:
	if not center.is_finite(): return false
	var built := build(source, owners)
	return built.get("ready",false) and built.domain.bounds.has_point(center)

static func _index(source) -> Dictionary:
	if not source is Blueprint or source.parts.size() > MAX_PARTS or source.rooms.size() > MAX_ROOMS:
		return _fail("invalid_exterior_bunting_source")
	var ids := {}; var roles := {}; var room_ids := {}; var courtyards: Array = []; var protected: Array = []
	for part in source.parts:
		if not part is Part or not _id(part.id) or ids.has(part.id): return _fail("invalid_exterior_bunting_part_id")
		ids[part.id] = true
		if not part.recipe.has(MOUNT): continue
		var receipt: Variant = part.recipe[MOUNT]
		if not receipt is Dictionary or receipt.size() != 3 or not receipt.get("role") is String or not receipt.get("side") is int:
			return _fail("invalid_exterior_bunting_receipt")
		var role: String = receipt.role; var side: int = receipt.side
		if not ((role == "landmark" and side == 0 and part.semantic == "citadel_civic_landmark") or
			(role == "forecourt_pavilion" and side in [-1, 1] and part.semantic == "castle_keep_forecourt_pavilion")):
			return _fail("foreign_exterior_bunting_receipt")
		if part.kind != "wall" or not part.collision_enabled or part.rotation != Vector3.ZERO or not source.has_finite_positive_bounds(part):
			return _fail("invalid_exterior_bunting_mount_geometry")
		var geometry: Variant = receipt.get("geometryBinding")
		if not geometry is Dictionary or geometry != _geometry(part): return _fail("stale_exterior_bunting_receipt")
		if role == "forecourt_pavilion" and not _producer_pavilion(source, part, side):
			return _fail("foreign_forecourt_pavilion_declaration")
		if role == "landmark" and not _producer_landmark(source, part): return _fail("foreign_civic_landmark_declaration")
		var key := role+":"+str(side)
		if roles.has(key): return _fail("duplicate_exterior_bunting_role")
		roles[key] = part
	for room: Variant in source.rooms:
		if not room is Dictionary or not _id(room.get("id")) or room_ids.has(room.id) or not _box(room.get("bounds")):
			return _fail("invalid_exterior_bunting_room")
		room_ids[room.id] = true
		if room.get("role") == "courtyard":
			if not _producer_courtyard(source, room): return _fail("foreign_exterior_bunting_courtyard")
			courtyards.append(room)
		else: protected.append(room.bounds)
	# Source ordering cannot alter protection order or placement ranking.
	protected.sort_custom(func(a: AABB, b: AABB):
		for axis in range(3):
			if a.position[axis] != b.position[axis]: return a.position[axis] < b.position[axis]
		for axis in range(3):
			if a.size[axis] != b.size[axis]: return a.size[axis] < b.size[axis]
		return false)
	return {"ready": true, "roles": roles, "courtyards": courtyards, "protectedRooms": protected}

static func _producer_pavilion(source, part, side: int) -> bool:
	var grammar: Variant = source.recipe.get("castleGrammar")
	if not grammar is Dictionary: return false
	var palace: Variant = grammar.get("palaceGrammar")
	if not palace is Dictionary: return false
	var layout: Variant = palace.get("forecourtLayout")
	if not layout is Array or layout.size() != 2 or not _finite_descriptor(layout) or not palace.get("forecourtLayoutHash") is String or JSON.stringify(layout).sha256_text() != palace.forecourtLayoutHash: return false
	var seen := {}; var matched := false
	for record: Variant in layout:
		if not record is Dictionary or typeof(record.get("side")) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(record.side)) or float(record.side) not in [-1.0, 1.0] or seen.has(int(record.side)): return false
		seen[int(record.side)] = true
		if int(record.side) != side: continue
		if not record.get("pavilionCenter") is Vector3: return false
		for key: String in ["pavilionWidth", "pavilionHeight", "pavilionDepth"]:
			if typeof(record.get(key)) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(record[key])) or float(record[key]) <= 0.0: return false
		matched = part.id == "castle_keep_forecourt_pavilion_%d" % side and part.position.x == record.pavilionCenter.x and part.position.z == record.pavilionCenter.z and part.size == Vector3(record.pavilionWidth, record.pavilionHeight, record.pavilionDepth)
	return matched

static func _producer_courtyard(source, room: Dictionary) -> bool:
	var grammar: Variant = source.recipe.get("castleGrammar")
	if not grammar is Dictionary or room.id != "castle_courtyard": return false
	for key: String in ["courtyardWidth", "courtyardDepth", "wallHeight"]:
		if typeof(grammar.get(key)) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(grammar[key])) or float(grammar[key]) <= 0.0: return false
	var base: Variant = source.recipe.get("foundationHeight")
	if typeof(base) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(base)): return false
	return room.bounds == AABB(Vector3(-float(grammar.courtyardWidth)*0.5, base, -float(grammar.courtyardDepth)*0.5), Vector3(grammar.courtyardWidth, grammar.wallHeight, grammar.courtyardDepth))

static func _producer_landmark(source, part) -> bool:
	var grammar: Variant = source.recipe.get("castleGrammar")
	var base: Variant = source.recipe.get("foundationHeight")
	if not grammar is Dictionary or typeof(base) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(base)): return false
	for key: String in ["courtyardDepth", "keepDepth"]:
		if typeof(grammar.get(key)) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(grammar[key])): return false
	var offset: Variant = grammar.get("keepOffset")
	if not offset is Dictionary or typeof(offset.get("z")) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(offset.z)): return false
	# Recognize the actual civic producer invocation from the compound grammar;
	# never authorize a freshly relabeled arbitrary wall as its landmark.
	var front: float = float(grammar.courtyardDepth)*float(offset.z)-float(grammar.keepDepth)*0.5
	return part.id == "urban_civic_tower" and part.position == Vector3(-14.0, float(base)+2.0+17.0*0.5, front-4.0) and part.size == Vector3(8.4,17.0,9.0)

static func _finite_descriptor(value: Variant) -> bool:
	# Reject malformed/nonfinite metadata before JSON hashing can issue engine
	# warnings. Bound nested or cyclic containers as well as ordinary scalars.
	var pending: Array = [value]; var index := 0
	while index < pending.size():
		if pending.size() > 512: return false
		var item: Variant = pending[index]; index += 1
		match typeof(item):
			TYPE_DICTIONARY:
				if item.size() > 64: return false
				for key in item:
					if not key is String: return false
					pending.append(item[key])
			TYPE_ARRAY:
				if item.size() > 64: return false
				pending.append_array(item)
			TYPE_FLOAT:
				if not is_finite(item): return false
			TYPE_VECTOR3:
				if not item.is_finite(): return false
			TYPE_INT, TYPE_STRING, TYPE_BOOL: pass
			_: return false
	return true

static func _geometry(part) -> Dictionary:
	return {"id": part.id, "kind": part.kind, "semantic": part.semantic, "position": part.position,
		"size": part.size, "rotation": part.rotation, "collision": part.collision_enabled}
static func _id(value: Variant) -> bool: return value is String and not value.is_empty() and value == value.strip_edges()
static func _box(value: Variant) -> bool:
	return value is AABB and value.position.is_finite() and value.size.is_finite() and value.end.is_finite() and value.size.x > 0.0 and value.size.y > 0.0 and value.size.z > 0.0
static func _fail(reason: String) -> Dictionary: return {"ready": false, "reason": reason}
