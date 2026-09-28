extends RefCounted

## Read-only identity/room inventory, not geometry or live-gameplay acceptance.
## Never call Interior.audit_plan/ensure_recipe_program here: both repair input.
const Blueprint := preload("res://scripts/buildings/BuildingBlueprint.gd")
const BuildingPart := preload("res://scripts/buildings/BuildingPart.gd")
const FurnishingPlan := preload("res://scripts/buildings/FurnishingPlan.gd")
const FurnishingPart := preload("res://scripts/buildings/FurnishingPart.gd")
const Interior := preload("res://scripts/buildings/BuildingInteriorProgram.gd")
const MAX_SOURCE_PARTS := 10000
const ENTRY_LIMIT := 4096 # Inclusive: same inventory ceiling as the checkpoint codec.


## Counts/IDs on failure describe the validated prefix, not an accepted inventory.
## windowIds retains actual blueprint order; reason is empty only on success.
static func inspect(blueprint: Variant, plan: Variant) -> Dictionary:
	var result := {"ready": false, "windowCount": 0, "programPartCount": 0,
		"windowIds": [], "reason": "", "details": {}}
	if not blueprint is Blueprint or not plan is FurnishingPlan:
		return _fail(result, "invalid_inputs")
	if blueprint.parts.size() > MAX_SOURCE_PARTS or blueprint.rooms.size() > ENTRY_LIMIT or plan.parts.size() > ENTRY_LIMIT:
		return _fail(result, "input_limit")
	# Guard the entire room array before passing it to Interior's typed reader.
	var room_ids := {}
	for index in range(blueprint.rooms.size()):
		var room: Variant = blueprint.rooms[index]
		if not room is Dictionary or not _id_valid(room.get("id")) or not room.get("bounds") is AABB:
			return _fail(result, "invalid_room", {"index": index})
		var bounds: AABB = room.bounds
		if not bounds.position.is_finite() or not bounds.size.is_finite() or bounds.size.x <= 0.0 or bounds.size.y <= 0.0 or bounds.size.z <= 0.0:
			return _fail(result, "invalid_room_bounds", {"index": index})
		if room_ids.has(room.id):
			return _fail(result, "duplicate_room_id", {"index": index})
		room_ids[room.id] = true
	var windows := {}
	for index in range(blueprint.parts.size()):
		var part: Variant = blueprint.parts[index]
		if not part is BuildingPart:
			return _fail(result, "invalid_blueprint_part", {"index": index})
		if part.kind != "window":
			continue
		if not _id_valid(part.id):
			return _fail(result, "invalid_window_id", {"index": index})
		if windows.has(part.id):
			return _fail(result, "duplicate_window_id", {"windowId": part.id})
		if windows.size() + 1 > ENTRY_LIMIT:
			return _fail(result, "window_limit")
		windows[part.id] = part
		result.windowIds.append(part.id)
		result.windowCount += 1
	if windows.is_empty():
		return _fail(result, "empty_windows")
	# Production prepares this derived annotation on a private furnishing copy.
	# Its absence on the authoritative blueprint is intentional; actual windows,
	# room bindings and every existing furnishing pair remain mandatory below.
	var has_aperture_cache: bool = blueprint.recipe.has("interiorProgram")
	result["apertureCachePresent"] = has_aperture_cache
	var program: Variant = blueprint.recipe.get("interiorProgram", {"apertures": []})
	if not program is Dictionary or not program.get("apertures") is Array:
		return _fail(result, "invalid_aperture_program")
	var apertures: Array = program.apertures
	if apertures.size() > ENTRY_LIMIT:
		return _fail(result, "aperture_limit")
	var resolved_rooms := {}
	for window_id: String in result.windowIds:
		var part: BuildingPart = windows[window_id]
		var declared: Variant = part.recipe.get("roomId", "")
		var inward: Variant = part.recipe.get("interiorInwardDirection", Vector3.ZERO)
		var offset: Variant = part.recipe.get("interiorWallOffset", 0.0)
		if not declared is String or (declared != "" and not _id_valid(declared)) or not inward is Vector3:
			return _fail(result, "invalid_window_binding", {"windowId": window_id})
		if not (offset is float or offset is int):
			return _fail(result, "invalid_window_binding", {"windowId": window_id})
		if not part.position.is_finite() or not inward.is_finite() or not is_finite(float(offset)):
			return _fail(result, "invalid_window_binding", {"windowId": window_id})
		var room := Interior.room_for_window(blueprint.rooms, part.position, declared, inward, float(offset))
		if room.is_empty():
			return _fail(result, "unresolved_window_room", {"windowId": window_id})
		resolved_rooms[window_id] = room.id
	var seen_apertures := {}
	for index in range(apertures.size()):
		var aperture: Variant = apertures[index]
		if not aperture is Dictionary or not _id_valid(aperture.get("windowId")) or not _id_valid(aperture.get("roomId")):
			return _fail(result, "invalid_aperture", {"index": index})
		var window_id: String = aperture.windowId
		if not windows.has(window_id):
			return _fail(result, "orphan_aperture", {"windowId": window_id})
		if seen_apertures.has(window_id):
			return _fail(result, "duplicate_aperture", {"windowId": window_id})
		if aperture.roomId != resolved_rooms[window_id]:
			return _fail(result, "aperture_room_mismatch", {"windowId": window_id})
		seen_apertures[window_id] = true
	if has_aperture_cache and seen_apertures.size() != windows.size():
		return _fail(result, "missing_aperture")
	var all_ids := {}
	var program_ids := {}
	for index in range(plan.parts.size()):
		var part: Variant = plan.parts[index]
		if not part is FurnishingPart:
			return _fail(result, "invalid_furnishing_part", {"index": index})
		if not _id_valid(part.id):
			return _fail(result, "invalid_furnishing_id", {"index": index})
		if all_ids.has(part.id):
			return _fail(result, "duplicate_furnishing_id", {"partId": part.id})
		all_ids[part.id] = true
		var semantic: Variant = part.recipe.get("semantic", "")
		if not semantic is String:
			return _fail(result, "invalid_furnishing_semantic", {"partId": part.id})
		var program_like: bool = part.id.begins_with("interior_window_") \
			or part.semantic.begins_with("window_sill_") or semantic.begins_with("window_sill_") \
			or part.recipe.has("interiorProgramSchemaVersion") or part.recipe.has("interiorProgramWindowId")
		if not program_like:
			continue
		var window_id: Variant = part.recipe.get("interiorProgramWindowId")
		if not _id_valid(window_id):
			return _fail(result, "invalid_furnishing_window_id", {"partId": part.id})
		if not windows.has(window_id):
			return _fail(result, "orphan_program_part", {"partId": part.id})
		var prefix := "interior_window_%s_" % window_id
		var role := "plant" if part.id == prefix + "plant" else "candle" if part.id == prefix + "candle" else ""
		if role.is_empty():
			return _fail(result, "unexpected_program_part_id", {"partId": part.id})
		if part.archetype != ("pot_plant" if role == "plant" else "candle"):
			return _fail(result, "wrong_program_archetype", {"partId": part.id})
		if part.room_id != resolved_rooms[window_id]:
			return _fail(result, "program_room_mismatch", {"partId": part.id})
		program_ids[part.id] = true
		result.programPartCount += 1
	for window_id: String in result.windowIds:
		for role: String in ["plant", "candle"]:
			if not program_ids.has("interior_window_%s_%s" % [window_id, role]):
				return _fail(result, "missing_program_member", {"windowId": window_id, "role": role})
	if result.programPartCount != 2 * result.windowCount:
		return _fail(result, "program_count_mismatch")
	result.ready = true
	return result


static func _id_valid(value: Variant) -> bool:
	return value is String and not value.is_empty() and value == value.strip_edges()


static func _fail(result: Dictionary, reason: String, details: Dictionary = {}) -> Dictionary:
	result.reason = reason
	result.details = details
	return result
