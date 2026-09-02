extends RefCounted

## Pure daytime inspection inventory, not geometry/visibility/bearing acceptance.
## Cut bindings must come from the caller's identity-checked actual mesh index.
const MAX_PARTS := 10000
const MAX_HOUSES := 64
const MAX_CUTS := 512
const MAX_CONTACTS := 4096
const MAX_VIEWS := 8
const CHANNEL := "CPU_neighbour_render_envelope"

static func build(snapshot: Dictionary, house_proposals: Array, selected_house_ids: Array, cut_bindings: Array, contact_rows: Array) -> Dictionary:
	if not snapshot.get("parts") is Array or snapshot.parts.is_empty() or snapshot.parts.size() > MAX_PARTS: return _fail("source_limit")
	if house_proposals.is_empty() or house_proposals.size() > MAX_HOUSES or selected_house_ids.size() != 1 or not selected_house_ids[0] is String: return _fail("requires_one_selected_house")
	if cut_bindings.size() > MAX_CUTS or contact_rows.size() > MAX_CONTACTS: return _fail("input_inventory_limit")
	var records: Dictionary = {}
	for value: Variant in snapshot.parts:
		if not value is Dictionary or not _id(value.get("id")) or records.has(value.id): return _fail("source_id_schema")
		records[value.id] = value
	var houses: Dictionary = {}
	var framing_owner: Dictionary = {}
	var trim_owner: Dictionary = {}
	for value: Variant in house_proposals:
		if not value is Dictionary or not _id(value.get("house")) or houses.has(value.house) or value.get("ready") != true: return _fail("proposal_schema")
		var closure: Dictionary = _closure(value, records)
		if not closure.ready: return closure
		for id: String in closure.framingIds:
			if framing_owner.has(id): return _fail("ambiguous_framing_owner")
			framing_owner[id] = value.house
		for id: String in closure.trimIds:
			if trim_owner.has(id): return _fail("ambiguous_trim_owner")
			trim_owner[id] = value.house
		houses[value.house] = closure
	for id: String in trim_owner:
		if framing_owner.has(id): return _fail("conflicting_part_roles")
	var house: String = selected_house_ids[0]
	if not houses.has(house): return _fail("unknown_selected_house")
	var selected: Dictionary = houses[house]
	var cuts: Dictionary = {}
	for value: Variant in cut_bindings:
		if not value is Dictionary or not _id(value.get("key")) or cuts.has(value.key) or not _id(value.get("partId")) or not trim_owner.has(value.partId) or not _finite_box(value.get("bounds")): return _fail("invalid_duplicate_or_foreign_cut_binding")
		cuts[value.key] = {"key": value.key, "partId": value.partId, "bounds": value.bounds, "house": trim_owner[value.partId]}
	var cut_keys: Array = cuts.keys()
	cut_keys.sort()
	var selected_cuts: Array = []
	var omitted_cuts: Array = []
	for key: String in cut_keys:
		if cuts[key].house == house: selected_cuts.append(cuts[key])
		else: omitted_cuts.append(cuts[key])
	if selected_cuts.size() + 2 > MAX_VIEWS: return _fail("view_limit_no_truncation")
	var context_bounds: AABB = selected.bounds
	for cut: Dictionary in selected_cuts: context_bounds = context_bounds.merge(cut.bounds)
	var targets: Array = [selected.headerId]
	var context_id: String = house + "_opening_head_context_day"
	var views: Array = [{"id": context_id, "frameId": house, "kind": "ordinary", "role": "context",
		"bounds": context_bounds, "targets": targets, "contactRowIds": [], "hiddenJointsMandatory": false}]
	for cut: Dictionary in selected_cuts:
		var box: AABB = cut.bounds
		# Dimension-derived neighbourhood, not an authored pose or changed geometry.
		var margin: float = maxf(box.size.x, maxf(box.size.y, box.size.z))
		var detail_bounds: AABB = box.grow(margin)
		if not _finite_box(detail_bounds): return _fail("invalid_detail_window")
		views.append({"id": house + "_opening_head_cut_%03d" % (views.size() - 1), "frameId": house,
			"kind": "close_inspection", "role": "cut_detail", "bounds": detail_bounds, "targets": [cut.partId],
			"cameraEvidenceScope": "appearance_only_not_player_or_access_evidence",
			"exactCutKey": cut.key, "cutBounds": box, "contactRowIds": [], "hiddenJointsMandatory": false})
	var rows: Dictionary = {}
	# Additional appearance context, never a replacement for ordinary street evidence.
	views.append({"id": house + "_opening_head_appearance_context", "frameId": house,
		"kind": "close_inspection", "role": "appearance_context", "bounds": context_bounds,
		"targets": targets.duplicate(), "contactRowIds": [], "hiddenJointsMandatory": false,
		"cameraEvidenceScope": "appearance_only_not_player_or_access_evidence"})
	for value: Variant in contact_rows:
		if not value is Dictionary or not _id(value.get("rowId")) or rows.has(value.rowId) or not value.get("inputRow") is Dictionary: return _fail("invalid_or_duplicate_contact_row")
		var row: Dictionary = value.inputRow
		if row.get("channel") != CHANNEL or not _id(row.get("headerId")) or not framing_owner.has(row.headerId) or not _id(row.get("obstacleId")) or not records.has(row.obstacleId): return _fail("unresolved_contact_reference")
		var overlap: Array = _overlap(row.get("headerBounds"), row.get("obstacleBounds"))
		if overlap.is_empty(): return _fail("invalid_or_nonpositive_contact_window")
		var window: AABB = AABB(Vector3(overlap[0], overlap[1], overlap[2]), Vector3(overlap[3] - overlap[0], overlap[4] - overlap[1], overlap[5] - overlap[2]))
		if not _finite_box(window): return _fail("unrepresentable_inspection_window")
		rows[value.rowId] = {"rowId": value.rowId, "house": framing_owner[row.headerId], "framingId": row.headerId,
			"obstacleId": row.obstacleId, "window": window, "windowScalars": overlap,
			"status": "RED_UNRESOLVED", "contactCleared": false, "viewIds": []}
	var row_ids: Array = rows.keys()
	row_ids.sort()
	var mappings: Array = []
	var omitted_rows: Array = []
	for row_id: String in row_ids:
		var mapping: Dictionary = rows[row_id]
		if mapping.house != house:
			omitted_rows.append(row_id)
			continue
		for view: Dictionary in views:
			if view.role in ["context", "appearance_context"] or view.bounds.intersects(mapping.window):
				view.contactRowIds.append(row_id)
				mapping.viewIds.append(view.id)
		mapping["framingMandatoryVisible"] = targets.has(mapping.framingId)
		mappings.append(mapping)
	var omitted_houses: Array = houses.keys()
	omitted_houses.erase(house)
	omitted_houses.sort()
	return {"ready": true, "reason": "", "views": views, "contactMappings": mappings,
		"inventory": {"selectedHouseIds": [house], "omittedHouseIds": omitted_houses,
			"selectedClosureIds": selected.closureIds, "nonMandatoryConnectionIds": selected.connectionIds,
			"selectedCutKeys": selected_cuts.map(func(cut: Dictionary) -> String: return cut.key), "omittedCuts": omitted_cuts,
			"inputCutCount": cuts.size(), "inputContactCount": rows.size(), "selectedContactCount": mappings.size(),
			"omittedContactRowIds": omitted_rows, "viewCount": views.size(), "maximumViews": MAX_VIEWS},
		"scope": "Source-derived daytime inspection targets only. Full scene and actual triangle occlusion remain caller obligations. Hidden joints CPU-only; all contacts remain RED regardless of visibility. No camera pose or visual acceptance."}

static func _closure(proposal: Dictionary, records: Dictionary) -> Dictionary:
	var header_id: Variant = proposal.get("headerId")
	if not _id(header_id) or not records.has(header_id) or not _frame(records[header_id]) or not _matches(records[header_id], proposal.get("header")): return _fail("missing_or_stale_header")
	var arrangement: Variant = proposal.get("connectionArrangement")
	if not arrangement is Dictionary or arrangement.get("ready") != true or not _matches(records[header_id], arrangement.get("body")) or not arrangement.get("connections") is Array or not arrangement.get("directSeats") is Array: return _fail("invalid_connection_arrangement")
	if arrangement.connections.size() > 2 or arrangement.directSeats.size() > 2: return _fail("connection_closure_limit")
	var connections: Array = []
	var peers: Array = []
	for record: Variant in arrangement.connections:
		if not record is Dictionary or not _id(record.get("id")) or connections.has(record.id) or record.id == header_id or not records.has(record.id) or not _frame(records[record.id]) or not _matches(records[record.id], record): return _fail("missing_or_stale_connection")
		var references: Array = _seats(records[record.id])
		if references.size() != 1 or not records.has(references[0]) or not _wall(records[references[0]]): return _fail("missing_connection_peer")
		connections.append(record.id)
		if not peers.has(references[0]): peers.append(references[0])
	if proposal.get("connectionIds") != connections: return _fail("connection_membership_mismatch")
	var direct_ids: Array = []
	for direct: Variant in arrangement.directSeats:
		if not direct is Dictionary or not direct.get("fact") is Dictionary or not _id(direct.fact.get("seatId")) or not _id(direct.get("declaredGableId")): return _fail("invalid_direct_peer")
		var id: String = direct.fact.seatId
		if direct_ids.has(id) or not records.has(id) or not _wall(records[id]) or not records.has(direct.declaredGableId) or not _wall(records[direct.declaredGableId]): return _fail("missing_direct_peer")
		direct_ids.append(id)
		for peer: String in [id, direct.declaredGableId]:
			if not peers.has(peer): peers.append(peer)
	var header_seats: Array = _seats(records[header_id])
	var expected_seats: Array = connections + direct_ids
	if expected_seats.size() != 2 or header_seats.size() != 2 or not header_seats.all(func(id: String) -> bool: return expected_seats.has(id)): return _fail("header_closure_mismatch")
	var trims: Variant = proposal.get("trimmedPanelIds")
	if not trims is Array or trims.is_empty() or trims.size() > 128: return _fail("trim_membership_schema")
	var sorted_trims: Array = []
	for id: Variant in trims:
		if not _id(id) or sorted_trims.has(id) or not records.has(id) or not _wall(records[id]) or _seats(records[id]) != [header_id]: return _fail("missing_foreign_or_duplicate_trim")
		sorted_trims.append(id)
	sorted_trims.sort()
	var frames: Array = [header_id] + connections
	var closure_ids: Array = frames + sorted_trims
	for id: String in peers:
		if not closure_ids.has(id): closure_ids.append(id)
	closure_ids.sort()
	var bounds: AABB = _bounds(records[header_id])
	for id: String in closure_ids: bounds = bounds.merge(_bounds(records[id]))
	return {"ready": true, "headerId": header_id, "framingIds": frames, "connectionIds": connections,
		"trimIds": sorted_trims, "closureIds": closure_ids, "bounds": bounds}

static func _seats(record: Dictionary) -> Array:
	if not record.get("recipe") is Dictionary: return []
	var ids: Variant = record.recipe.get("physicalRequiredSeatPartIds")
	var facts: Variant = record.recipe.get("physicalRequiredSeatFacts")
	if not ids is Array or ids.is_empty() or ids.size() > 16 or not facts is Array or facts.size() != ids.size(): return []
	var result: Array = []
	for fact: Variant in facts:
		if not fact is Dictionary or not _id(fact.get("seatId")) or not ids.has(fact.seatId) or result.has(fact.seatId): return []
		result.append(fact.seatId)
	return result

static func _matches(actual: Dictionary, proposed: Variant) -> bool:
	if not proposed is Dictionary: return false
	for key: String in ["id", "kind", "material", "semantic", "position", "size", "collision"]:
		if not proposed.has(key) or actual.get(key) != proposed[key]: return false
	# BuildingPart._init uses Vector3.ZERO when rotation is omitted. This is
	# that single documented canonical default, not a tolerance or pose repair.
	var proposed_rotation: Variant = proposed.get("rotation", Vector3.ZERO)
	if not proposed_rotation is Vector3 or not proposed_rotation.is_finite() or actual.get("rotation") != proposed_rotation: return false
	if not proposed.get("recipe") is Dictionary or not actual.get("recipe") is Dictionary: return false
	if proposed.recipe.size() > 128: return false
	for key: Variant in proposed.recipe:
		if not actual.recipe.has(key) or actual.recipe[key] != proposed.recipe[key]: return false
	return true

static func _frame(record: Dictionary) -> bool:
	return record.get("kind") == "beam" and record.get("material") == "timber_beam" and record.get("collision") == true and record.get("recipe") is Dictionary and record.recipe.get("visual", true) == true and _finite_box(_bounds(record))

static func _wall(record: Dictionary) -> bool:
	return record.get("kind") == "wall" and record.get("collision") == true and record.get("recipe") is Dictionary and record.recipe.get("visual", true) == true and _finite_box(_bounds(record))

static func _bounds(record: Dictionary) -> AABB:
	for key: String in ["position", "rotation", "size"]:
		if not record.get(key) is Vector3 or not record[key].is_finite(): return AABB()
	if record.size.x <= 0 or record.size.y <= 0 or record.size.z <= 0: return AABB()
	return Transform3D(Basis.from_euler(record.rotation), record.position) * AABB(-record.size * 0.5, record.size)

static func _finite_box(value: Variant) -> bool:
	return value is AABB and value.position.is_finite() and value.end.is_finite() and value.size.is_finite() and value.size.x > 0 and value.size.y > 0 and value.size.z > 0

static func _id(value: Variant) -> bool:
	return value is String and not value.is_empty() and value.length() <= 512

static func _overlap(first: Variant, second: Variant) -> Array:
	for box: Variant in [first, second]:
		if not box is Array or box.size() != 6: return []
		for coordinate: Variant in box:
			if not (coordinate is float or coordinate is int) or not is_finite(float(coordinate)) or absf(float(coordinate)) > 100000: return []
		for axis: int in range(3):
			if box[axis] >= box[axis + 3]: return []
	var result: Array = []
	for axis: int in range(3): result.append(maxf(first[axis], second[axis]))
	for axis: int in range(3): result.append(minf(first[axis + 3], second[axis + 3]))
	for axis: int in range(3):
		if result[axis] >= result[axis + 3]: return []
	return result

static func _fail(reason: String) -> Dictionary:
	return {"ready": false, "reason": reason, "views": [], "inventory": {}, "contactMappings": []}
