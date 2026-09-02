extends RefCounted
## Pure source inspection plan, NOT physical validation or visibility evidence.
## Only panel -> sill -> post edges are traversed. Post/root closure is not.
const MAX_SOURCE_PARTS := 10000
const MAX_GROUP_PARTS := 32
const MAX_PAIRS := 64

static func build(snapshot: Dictionary, group: Dictionary) -> Dictionary:
	if not snapshot.get("parts") is Array or snapshot.parts.is_empty() or snapshot.parts.size() > MAX_SOURCE_PARTS:
		return _fail("source_part_limit")
	if not group.get("bounds") is AABB or not _finite_box(group.bounds):
		return _fail("invalid_group_bounds")
	var records: Dictionary = {}
	for record in snapshot.parts:
		if not record is Dictionary or not record.get("id") is String or record.id.is_empty() or records.has(record.id):
			return _fail("source_id_schema")
		records[record.id] = record
	var members: Array = _ids(group.get("partIds"))
	var panels: Array = _ids(group.get("servedIds"))
	if members.is_empty() or panels.is_empty(): return _fail("group_id_schema")
	for id in members + panels:
		if not records.has(id): return _fail("unresolved_group_member")
	for id in panels:
		if members.has(id): return _fail("overlapping_group_roles")
	var panel_sills: Dictionary = {}
	var sill_seats: Dictionary = {}
	for id in panels:
		var panel: Dictionary = records[id]
		if panel.get("semantic") != "citadel_urban_facade" or _box(panel).size == Vector3.ZERO:
			return _fail("invalid_panel_role_or_geometry")
		var seats: Dictionary = _seats(panel)
		if not seats.ready: return seats
		if seats.ids.size() != 1: return _fail("panel_requires_unique_sill")
		var sill_id: String = seats.ids[0]
		if not records.has(sill_id): return _fail("unresolved_sill")
		if not members.has(sill_id): return _fail("foreign_sill")
		if not _timber(records[sill_id]): return _fail("invalid_sill_role_or_geometry")
		panel_sills[id] = {"id": sill_id, "fact": seats.facts[sill_id]}
		if not sill_seats.has(sill_id):
			var post_seats: Dictionary = _seats(records[sill_id])
			if not post_seats.ready: return post_seats
			if post_seats.ids.is_empty(): return _fail("sill_requires_posts")
			sill_seats[sill_id] = post_seats
	var sill_ids: Array = sill_seats.keys()
	sill_ids.sort()
	for sill_id in sill_ids:
		for post_id in sill_seats[sill_id].ids:
			if not records.has(post_id): return _fail("unresolved_post")
			if not members.has(post_id): return _fail("foreign_post")
			# A node cannot be both a traversed sill and a post (including self).
			if sill_seats.has(post_id): return _fail("cyclic_or_ambiguous_seat_roles")
			if not _timber(records[post_id]): return _fail("invalid_post_role_or_geometry")
	var pairs: Array = []
	var targets: Array = []
	for panel_id in panels:
		var sill_id: String = panel_sills[panel_id].id
		var pair: Dictionary = _pair(records[panel_id], records[sill_id], panel_sills[panel_id].fact, "panel_to_sill")
		if not pair.ready: return pair
		pairs.append(pair.pair)
	for sill_id in sill_ids:
		for post_id in sill_seats[sill_id].ids:
			if pairs.size() >= MAX_PAIRS: return _fail("interface_pair_limit")
			var pair: Dictionary = _pair(records[sill_id], records[post_id], sill_seats[sill_id].facts[post_id], "sill_to_post")
			if not pair.ready: return pair
			pairs.append(pair.pair)
	for pair in pairs:
		for id in [pair.upperId, pair.lowerId]:
			if not targets.has(id): targets.append(id)
	targets.sort()
	return {"ready": true, "reason": "", "pairs": pairs, "targets": targets,
		"evidence": "declared_source_interface_plan_not_exposure_or_bearing_proof"}

static func _ids(value: Variant) -> Array:
	if not value is Array or value.is_empty() or value.size() > MAX_GROUP_PARTS: return []
	var result: Array = []
	for id in value:
		if not id is String or id.is_empty() or result.has(id): return []
		result.append(id)
	result.sort()
	return result

static func _seats(record: Dictionary) -> Dictionary:
	if not record.get("recipe") is Dictionary: return _fail("missing_seat_recipe")
	var ids: Array = _ids(record.recipe.get("physicalRequiredSeatPartIds"))
	var facts: Variant = record.recipe.get("physicalRequiredSeatFacts")
	if ids.is_empty() or not facts is Array or facts.size() != ids.size():
		return _fail("seat_ids_facts_not_one_to_one")
	var by_id: Dictionary = {}
	for fact in facts:
		if not fact is Dictionary or not fact.get("seatId") is String or not ids.has(fact.seatId) or by_id.has(fact.seatId):
			return _fail("seat_ids_facts_not_one_to_one")
		if fact.get("loadDirection") != "world_down" or fact.get("seatFace") != "max_y" or fact.get("contactMode", "") != "":
			return _fail("unsupported_seat_fact")
		if not fact.get("localPatchCenter") is Vector3 or not fact.localPatchCenter.is_finite() or not fact.get("localPatchHalfExtents") is Vector2 or not fact.localPatchHalfExtents.is_finite():
			return _fail("nonfinite_or_missing_seat_patch")
		if fact.localPatchHalfExtents.x <= 0 or fact.localPatchHalfExtents.y <= 0:
			return _fail("invalid_seat_patch_extent")
		by_id[fact.seatId] = fact.duplicate(true)
	return {"ready": true, "ids": ids, "facts": by_id}

static func _timber(record: Dictionary) -> bool:
	return record.get("kind") == "beam" and record.get("material") == "timber_beam" and _box(record).size != Vector3.ZERO

static func _box(record: Dictionary) -> AABB:
	for key in ["position", "size", "rotation"]:
		if not record.get(key) is Vector3 or not record[key].is_finite(): return AABB()
	var size: Vector3 = record.size
	if size.x <= 0 or size.y <= 0 or size.z <= 0: return AABB()
	# Exact stored quarter-Euler representations only. No tolerance, snapped
	# pose, or modified source: retain the actual transform for source bounds.
	for angle in [record.rotation.x, record.rotation.y, record.rotation.z]:
		if absf(float(angle)) > TAU * 4.0: return AABB()
		var quarter: int = roundi(float(angle) / (PI * 0.5))
		var represented: float = Vector3(float(quarter) * PI * 0.5, 0, 0).x
		if float(angle) != represented: return AABB()
	var box: AABB = Transform3D(Basis.from_euler(record.rotation), record.position) * AABB(-size * 0.5, size)
	return box if _finite_box(box) else AABB()

static func _pair(upper: Dictionary, lower: Dictionary, fact: Dictionary, relationship: String) -> Dictionary:
	var upper_box: AABB = _box(upper)
	var lower_box: AABB = _box(lower)
	var lo_x: float = maxf(upper_box.position.x, lower_box.position.x)
	var lo_z: float = maxf(upper_box.position.z, lower_box.position.z)
	var hi_x: float = minf(upper_box.end.x, lower_box.end.x)
	var hi_z: float = minf(upper_box.end.z, lower_box.end.z)
	if hi_x <= lo_x or hi_z <= lo_z: return _fail("no_interface_footprint_overlap")
	var low_y: float = minf(upper_box.position.y, lower_box.end.y)
	var high_y: float = maxf(upper_box.position.y, lower_box.end.y)
	var thickness: float = maxf(minf(upper_box.size.x, upper_box.size.z), minf(lower_box.size.x, lower_box.size.z))
	var contact := AABB(Vector3(lo_x, low_y, lo_z), Vector3(hi_x - lo_x, high_y - low_y, hi_z - lo_z))
	var window: AABB = contact.grow(thickness)
	if not _finite_box(window): return _fail("nonfinite_review_window")
	var upper_patch: AABB = upper_box.intersection(window)
	var lower_patch: AABB = lower_box.intersection(window)
	if not _finite_box(upper_patch) or not _finite_box(lower_patch): return _fail("empty_participant_patch")
	return {"ready": true, "pair": {"upperId": upper.id, "lowerId": lower.id, "relationship": relationship,
		"seatFact": fact.duplicate(true), "contactBounds": contact, "reviewBounds": window,
		"memberThickness": thickness, "verticalGap": upper_box.position.y - lower_box.end.y,
		"patches": [{"partId": upper.id, "bounds": upper_patch}, {"partId": lower.id, "bounds": lower_patch}]}}

static func _finite_box(box: AABB) -> bool:
	return box.position.is_finite() and box.size.is_finite() and box.end.is_finite() and box.size.x > 0 and box.size.y > 0 and box.size.z > 0

static func _fail(reason: String) -> Dictionary:
	return {"ready": false, "reason": reason, "pairs": [], "targets": []}
