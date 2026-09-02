extends RefCounted

## Producer-authored ownership for ordinary street-house structural completion.
## This is recipe metadata only: it adds, moves, removes and validates no geometry.
const KEY := "citadelStreetHouseStructuralRecipes"
const Aperture = preload("res://scripts/buildings/FacadeApertureDeclaration.gd")
const MAX_HOUSES := 64
const MAX_PARTS := 8192

static func declare(source, record: Dictionary) -> Dictionary:
	if source == null or source.parts.size() > MAX_PARTS: return _fail("invalid_manifest_source")
	var prepared: Dictionary = record.duplicate(true)
	prepared["signAnchorIds"] = _authored_sign_anchor_ids(source, String(prepared.get("producerPrefix", "")))
	var checked := _validate_record(source, prepared)
	if not checked.ready: return checked
	var collection: Variant = source.recipe.get(KEY, {})
	if not collection is Dictionary or collection.size() >= MAX_HOUSES or collection.has(prepared.producerPrefix):
		return _fail("invalid_or_duplicate_manifest_collection")
	var next: Dictionary = collection.duplicate(true)
	next[prepared.producerPrefix] = prepared
	source.recipe[KEY] = next
	return {"ready": true, "producerPrefix": prepared.producerPrefix}

static func read(source) -> Dictionary:
	if source == null or source.parts.size() > MAX_PARTS: return _fail("invalid_manifest_source")
	var collection: Variant = source.recipe.get(KEY)
	if not collection is Dictionary or collection.is_empty() or collection.size() > MAX_HOUSES:
		return _fail("missing_or_unbounded_manifest_collection")
	var prefixes: Array = collection.keys()
	prefixes.sort()
	var records: Array = []
	var covered_doors: Dictionary = {}
	for prefix: Variant in prefixes:
		if not prefix is String or not collection[prefix] is Dictionary or collection[prefix].get("producerPrefix") != prefix:
			return _fail("invalid_manifest_key")
		var checked := _validate_record(source, collection[prefix])
		if not checked.ready: return checked
		if covered_doors.has(collection[prefix].doorId): return _fail("duplicate_manifest_door")
		covered_doors[collection[prefix].doorId] = true
		records.append(collection[prefix].duplicate(true))
	var generated_doors: Array = source.parts.filter(func(part): return part != null and part.kind == "door" and part.semantic == "citadel_urban_door")
	if generated_doors.size() != records.size() or not generated_doors.all(func(door): return covered_doors.has(door.id)):
		return _fail("incomplete_manifest_coverage")
	return {"ready": true, "records": records}

static func _validate_record(source, record: Dictionary) -> Dictionary:
	for key: String in ["producerPrefix", "roomId", "doorId", "hoodId", "threshold", "bracketIds", "chimney", "facadeDeclarationKeys", "signAssembly", "signAnchorIds"]:
		if not record.has(key): return _fail("missing_manifest_field", {"field": key})
	var prefix: Variant = record.producerPrefix
	if not prefix is String or prefix.is_empty() or prefix != prefix.strip_edges(): return _fail("invalid_manifest_prefix")
	if record.roomId != prefix + "_interior" or record.doorId != prefix + "_door" or record.hoodId != prefix + "_door_hood":
		return _fail("inconsistent_manifest_identity")
	var room_matches: Array = source.rooms.filter(func(room): return room is Dictionary and room.get("id") == record.roomId and room.get("citadelUrbanRoom") == true)
	if room_matches.size() != 1: return _fail("missing_manifest_room")
	var door = find_part(source, record.doorId)
	var hood = find_part(source, record.hoodId)
	if door == null or door.kind != "door" or door.semantic != "citadel_urban_door" or hood == null or hood.semantic != "citadel_urban_door_hood":
		return _fail("invalid_manifest_door_hood")
	if door.recipe.get("roomId") != record.roomId:
		return _fail("invalid_manifest_door_room")
	var threshold: Variant = record.threshold
	if not threshold is Dictionary or threshold.get("id") != prefix + "_door_threshold" or threshold.get("foundationId") != prefix + "_foundation":
		return _fail("invalid_manifest_threshold")
	if not _part_matches(source, threshold.id, "citadel_threshold_wear", "foundation") \
		or not _part_matches(source, threshold.foundationId, "citadel_urban_house_foundation", "foundation"):
		return _fail("invalid_manifest_threshold_members")
	var expected_brackets := [prefix + "_door_bracket_-66", prefix + "_door_bracket_66"]
	if record.bracketIds != expected_brackets or not _owned_ids(source, prefix, record.bracketIds, "citadel_urban_door_joinery", "beam", 2, 2): return _fail("invalid_manifest_brackets")
	var chimney: Variant = record.chimney
	if not chimney is Dictionary or chimney.get("id") != prefix + "_chimney" or not chimney.get("gableIds") is Array or not chimney.get("upstreamIds") is Array:
		return _fail("invalid_manifest_chimney")
	if not _owned_ids(source, prefix, [chimney.id], "citadel_urban_chimney", "wall", 1, 1): return _fail("invalid_manifest_chimney")
	var expected_gables := [prefix + "_upper_shell_side_-1", prefix + "_upper_shell_side_1"]
	var expected_upstream := [prefix + "_foundation", prefix + "_stone_shell_side_-1", prefix + "_stone_shell_side_1"]
	if chimney.gableIds != expected_gables or chimney.upstreamIds != expected_upstream \
		or not _owned_ids(source, prefix, chimney.gableIds, "citadel_urban_facade_shell", "wall", 2, 2) \
		or not _part_matches(source, expected_upstream[0], "citadel_urban_house_foundation", "foundation") \
		or not _part_matches(source, expected_upstream[1], "citadel_urban_stone_base_shell", "wall") \
		or not _part_matches(source, expected_upstream[2], "citadel_urban_stone_base_shell", "wall"):
		return _fail("invalid_manifest_chimney_closure")
	var declarations: Variant = source.recipe.get("facadeApertures")
	var by_id: Dictionary = {}
	for part in source.parts:
		if part == null or part.id.is_empty() or by_id.has(part.id): return _fail("invalid_manifest_source_parts")
		by_id[part.id] = part
	if not declarations is Dictionary or not record.facadeDeclarationKeys is Array or record.facadeDeclarationKeys.is_empty() or record.facadeDeclarationKeys.size() > 4:
		return _fail("invalid_manifest_facades")
	for key: Variant in record.facadeDeclarationKeys:
		if not key is String or not declarations.has(key) or not declarations[key] is Dictionary or declarations[key].get("producerPrefix") != key \
			or not key.begins_with(prefix + "_") or not declarations[key].get("partIds") is Array or declarations[key].partIds.is_empty():
			return _fail("invalid_manifest_facade_declaration")
		if not Aperture.validate(declarations[key], by_id): return _fail("stale_manifest_facade_declaration")
		if not _owned_ids(source, prefix, declarations[key].partIds, "citadel_urban_facade", "wall", 1, 512): return _fail("invalid_manifest_facade_members")
	var sign: Variant = record.signAssembly
	if not sign is Dictionary: return _fail("invalid_manifest_sign")
	if sign.is_empty():
		if find_part(source, prefix + "_sign_arm") != null or find_part(source, prefix + "_hanging_sign") != null: return _fail("missing_manifest_sign_members")
	else:
		if sign.get("armId") != prefix + "_sign_arm" or sign.get("boardId") != prefix + "_hanging_sign" \
			or not _owned_ids(source, prefix, [sign.armId, sign.boardId], "citadel_household_sign", "", 2, 2):
			return _fail("invalid_manifest_sign_members")
	var expected_sign_anchors := _authored_sign_anchor_ids(source, prefix)
	if record.signAnchorIds != expected_sign_anchors or not _sign_anchor_ids_valid(source, prefix, record.signAnchorIds):
		return _fail("invalid_manifest_sign_anchors")
	return {"ready": true}

static func _owned_ids(source, prefix: String, ids: Variant, semantic: String, kind: String, minimum: int, maximum: int) -> bool:
	if not ids is Array or ids.size() < minimum or ids.size() > maximum: return false
	var seen: Dictionary = {}
	for id: Variant in ids:
		if not id is String or not id.begins_with(prefix + "_") or seen.has(id): return false
		seen[id] = true
		var part = find_part(source, id)
		if part == null or (not semantic.is_empty() and part.semantic != semantic) or (not kind.is_empty() and part.kind != kind): return false
	return true

static func find_part(source, id: String):
	if source == null: return null
	for part in source.parts:
		if part != null and part.id == id: return part
	return null

static func _part_matches(source, id: String, semantic: String, kind: String) -> bool:
	var part = find_part(source, id)
	return part != null and part.semantic == semantic and part.kind == kind

static func _authored_sign_anchor_ids(source, prefix: String) -> Array:
	var ids: Array = [prefix + "_opening_head_band_000"] if not prefix.is_empty() else []
	if source == null or prefix.is_empty(): return ids
	for part in source.parts:
		if part != null and part.id.begins_with(prefix + "_") and part.semantic == "citadel_household_projecting_bay_backing" \
			and part.kind == "wall" and part.collision_enabled and part.rotation == Vector3.ZERO \
			and part.physical_intent in ["structural_mass", "structural_root"]:
			ids.append(part.id)
	ids.sort()
	return ids

static func _sign_anchor_ids_valid(source, prefix: String, ids: Variant) -> bool:
	if not ids is Array or ids.is_empty() or ids.size() > 2: return false
	var head_id := prefix + "_opening_head_band_000"
	if not ids.has(head_id): return false
	var head = find_part(source, head_id)
	if head != null and (head.kind != "beam" or head.semantic != "citadel_opening_head_band" \
			or not head.collision_enabled or head.rotation != Vector3.ZERO or head.physical_intent != "structural_mass"):
		return false
	var backing_ids: Array = ids.filter(func(id): return id != head_id)
	return _owned_ids(source, prefix, backing_ids, "citadel_household_projecting_bay_backing", "wall", 0, 1)

static func _fail(reason: String, detail: Dictionary = {}) -> Dictionary:
	var result := detail.duplicate(true)
	result["ready"] = false
	result["reason"] = reason
	return result
