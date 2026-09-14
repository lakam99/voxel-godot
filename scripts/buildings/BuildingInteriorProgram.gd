extends RefCounted
class_name BuildingInteriorProgram

const SCHEMA_VERSION := 2
const InteriorFurnishingLayoutScript := preload("res://scripts/buildings/InteriorFurnishingLayout.gd")


static func apply_to_plan(blueprint, plan) -> Dictionary:
	var program := ensure_recipe_program(blueprint)
	var apertures: Array = program.get("apertures", []) as Array
	var published_windows := {}
	var added_parts := 0
	for part in plan.parts:
		if part == null:
			continue
		var window_id := String(part.recipe.get("interiorProgramWindowId", "")).strip_edges()
		if not window_id.is_empty():
			published_windows[window_id] = true
	for aperture_value in apertures:
		if not aperture_value is Dictionary:
			continue
		var aperture: Dictionary = aperture_value as Dictionary
		var window_id := String(aperture.get("windowId", "")).strip_edges()
		var room_id := String(aperture.get("roomId", "")).strip_edges()
		if window_id.is_empty() or room_id.is_empty() or published_windows.has(window_id):
			continue
		var mode := String(aperture.get("mode", "lit_plant")).strip_edges().to_lower()
		if mode == "clear_view":
			published_windows[window_id] = true
			continue
		var viewpoint: Vector3 = aperture.get("viewpoint", Vector3.ZERO) as Vector3
		var side: Vector3 = aperture.get("side", Vector3.RIGHT) as Vector3
		var lower_y := float(aperture.get("lowerY", viewpoint.y - 0.40))
		var side_offset := float(aperture.get("sideOffset", 0.18))
		var material_phase := float(aperture.get("materialPhase", 0.5))
		var shared_recipe := {
			"interiorProgramWindowId": window_id,
			"interiorProgramSchemaVersion": SCHEMA_VERSION,
			"viewVolume": aperture.get("viewVolume", AABB()),
			"collision": false
		}
		var plant_recipe := shared_recipe.duplicate(true)
		plant_recipe["semantic"] = "window_sill_plant"
		plan.add_part({
			"id": "interior_window_%s_plant" % window_id,
			"roomId": room_id,
			"archetype": "pot_plant",
			"material": "ceramic_glaze",
			"position": Vector3(viewpoint.x + side.x * side_offset, lower_y, viewpoint.z + side.z * side_offset),
			"occupiedSize": Vector3(0.36, 0.52, 0.36),
			"collision": false,
			"semantic": "window_sill_plant",
			"recipe": plant_recipe
		})
		var candle_recipe := shared_recipe.duplicate(true)
		candle_recipe["semantic"] = "window_sill_candle"
		candle_recipe["variation"] = material_phase - 0.5
		plan.add_part({
			"id": "interior_window_%s_candle" % window_id,
			"roomId": room_id,
			"archetype": "candle",
			"material": "candle_wax",
			"position": Vector3(viewpoint.x - side.x * side_offset, lower_y, viewpoint.z - side.z * side_offset),
			"occupiedSize": Vector3(0.15, 0.30, 0.15),
			"collision": false,
			"semantic": "window_sill_candle",
			"recipe": candle_recipe
		})
		published_windows[window_id] = true
		added_parts += 2
	program["publishedWindowCount"] = published_windows.size()
	program["publishedPartCount"] = added_parts
	if blueprint != null:
		blueprint.recipe["interiorProgram"] = program
	return program


static func ensure_recipe_program(blueprint) -> Dictionary:
	if blueprint == null:
		return {"schemaVersion": SCHEMA_VERSION, "apertures": []}
	# Apertures are a derived view of the current authoritative parts and rooms.
	# Rebuilding this small list prevents a cached program from surviving a room
	# or facade revision and assigning a window through stale geometry.
	var apertures: Array = []
	for part in blueprint.parts:
		if part == null or String(part.kind) != "window":
			continue
		var declared_room_id := String(part.recipe.get("roomId", "")).strip_edges()
		var declared_inward: Vector3 = part.recipe.get("interiorInwardDirection", Vector3.ZERO) as Vector3
		var declared_wall_offset := float(part.recipe.get("interiorWallOffset", 0.0))
		var room: Dictionary = room_for_window(blueprint.rooms, part.position, declared_room_id, declared_inward, declared_wall_offset)
		if room.is_empty():
			continue
		var bounds: AABB = room.get("bounds", AABB()) as AABB
		var inward: Vector3 = inward_direction(bounds, part.position)
		var side: Vector3 = Vector3(-inward.z, 0.0, inward.x)
		var depth: float = 0.62
		var opening_span: float = part.size.x if absf(inward.z) > 0.5 else part.size.z
		var opening_height: float = part.size.y
		var lower_y: float = part.position.y - opening_height * 0.5 + 0.09
		var viewpoint: Vector3 = part.position + inward * depth
		viewpoint.y = lower_y
		var view_center: Vector3 = part.position + inward * 0.82
		view_center.y = lower_y + 0.38
		var view_height := maxf(0.78, opening_height * 0.80)
		var view_size := Vector3(maxf(0.48, opening_span * 0.74), view_height, 1.28) if absf(inward.z) > 0.5 else Vector3(1.28, view_height, maxf(0.48, opening_span * 0.74))
		var phase := float(posmod((String(blueprint.id) + ":" + String(part.id)).hash(), 4093)) / 4093.0
		var mode := String(part.recipe.get("interiorProgramMode", "lit_plant")).strip_edges().to_lower()
		if mode not in ["lit_plant", "clear_view"]:
			continue
		apertures.append({
			"windowId": String(part.id),
			"roomId": String(room.get("id", "")),
			"viewpoint": viewpoint,
			"side": side,
			"lowerY": lower_y,
			"sideOffset": maxf(0.10, minf(0.30, opening_span * 0.22)),
			"viewVolume": AABB(view_center - view_size * 0.5, view_size),
			"materialPhase": phase,
			"mode": mode
		})
	var program := {"schemaVersion": SCHEMA_VERSION, "apertures": apertures}
	blueprint.recipe["interiorProgram"] = program.duplicate(true)
	return program


static func audit_plan(blueprint, plan) -> Dictionary:
	var program := ensure_recipe_program(blueprint)
	var apertures: Array = program.get("apertures", []) as Array
	var aperture_by_window := {}
	var program_parts_by_window := {}
	var violations: Array[String] = []
	var non_interior_window_ids: Array[String] = []
	for aperture_value in apertures:
		if not aperture_value is Dictionary:
			continue
		var aperture: Dictionary = aperture_value as Dictionary
		var window_id := String(aperture.get("windowId", "")).strip_edges()
		if not window_id.is_empty():
			aperture_by_window[window_id] = aperture
	if blueprint == null or plan == null:
		return {"passed": false, "apertureCount": apertures.size(), "publishedWindowCount": 0, "violations": ["blueprint or furnishing plan is unavailable"]}
	for part in blueprint.parts:
		if part == null or String(part.kind) != "window":
			continue
		var window_id := String(part.id)
		if not aperture_by_window.has(window_id):
			non_interior_window_ids.append(window_id)
	for furnishing_part in plan.parts:
		if furnishing_part == null:
			continue
		var window_id := String(furnishing_part.recipe.get("interiorProgramWindowId", "")).strip_edges()
		if not window_id.is_empty():
			if not program_parts_by_window.has(window_id):
				program_parts_by_window[window_id] = []
			(program_parts_by_window[window_id] as Array).append(furnishing_part)
	var published_windows := 0
	for window_id_value in aperture_by_window:
		var window_id := String(window_id_value)
		var aperture: Dictionary = aperture_by_window[window_id] as Dictionary
		var view_volume: AABB = aperture.get("viewVolume", AABB()) as AABB
		var entries: Array = program_parts_by_window.get(window_id, []) as Array
		var mode := String(aperture.get("mode", "lit_plant")).strip_edges().to_lower()
		if mode == "clear_view":
			if not entries.is_empty():
				violations.append("%s clear-view aperture contains window ornaments" % window_id)
			else:
				published_windows += 1
			for furnishing_part in plan.parts:
				if furnishing_part == null or not furnishing_part.collision_enabled:
					continue
				var occupied_bounds := InteriorFurnishingLayoutScript.horizontal_bounds(furnishing_part.position, furnishing_part.occupied_size, furnishing_part.rotation)
				if occupied_bounds.intersects(view_volume):
					violations.append("%s clear view volume is blocked by %s" % [window_id, String(furnishing_part.id)])
			continue
		var has_plant := false
		var has_candle := false
		for furnishing_part in entries:
			if furnishing_part == null:
				continue
			if String(furnishing_part.archetype) == "pot_plant":
				has_plant = true
			elif String(furnishing_part.archetype) == "candle":
				has_candle = true
			if not view_volume.has_point(furnishing_part.position):
				violations.append("%s furnishing %s is outside its interior view volume" % [window_id, String(furnishing_part.id)])
		if not has_plant or not has_candle:
			violations.append("%s lacks its required lit plant silhouette" % window_id)
			continue
		published_windows += 1
		for furnishing_part in plan.parts:
			if furnishing_part == null or not furnishing_part.collision_enabled:
				continue
			if String(furnishing_part.recipe.get("interiorProgramWindowId", "")).strip_edges() == window_id:
				continue
			var occupied_bounds := InteriorFurnishingLayoutScript.horizontal_bounds(furnishing_part.position, furnishing_part.occupied_size, furnishing_part.rotation)
			if occupied_bounds.intersects(view_volume):
				violations.append("%s view volume is blocked by %s" % [window_id, String(furnishing_part.id)])
	return {
		"passed": not apertures.is_empty() and published_windows == apertures.size() and non_interior_window_ids.is_empty() and violations.is_empty(),
		"apertureCount": apertures.size(),
		"publishedWindowCount": published_windows,
		"nonInteriorWindowCount": non_interior_window_ids.size(),
		"nonInteriorWindowIds": non_interior_window_ids,
		"violations": violations
	}


static func room_for_window(rooms: Array, position: Vector3, declared_room_id := "", declared_inward := Vector3.ZERO, declared_wall_offset := 0.0) -> Dictionary:
	if not position.is_finite():
		return {}
	var room_id := String(declared_room_id).strip_edges()
	if not room_id.is_empty():
		var declared_matches: Array[Dictionary] = []
		for room_value in rooms:
			if room_value is Dictionary and String((room_value as Dictionary).get("id", "")).strip_edges() == room_id:
				declared_matches.append(room_value as Dictionary)
		if declared_matches.size() != 1:
			return {}
		var declared_room: Dictionary = declared_matches[0]
		var bounds: AABB = declared_room.get("bounds", AABB()) as AABB
		var inward := declared_inward as Vector3
		var wall_offset := float(declared_wall_offset)
		if not _valid_room_bounds(bounds) or not inward.is_finite() or not is_finite(wall_offset) or wall_offset <= 0.0 or wall_offset > 2.0:
			return {}
		if absf(inward.y) > 0.001 or (absf(inward.x) > 0.999) == (absf(inward.z) > 0.999):
			return {}
		inward = inward.normalized()
		var wall_point := position + inward * wall_offset
		if not bounds.grow(0.02).has_point(wall_point):
			return {}
		var expected_face := bounds.position.x if inward.x > 0.5 else bounds.end.x if inward.x < -0.5 else bounds.position.z if inward.z > 0.5 else bounds.end.z
		var wall_coordinate := wall_point.x if absf(inward.x) > 0.5 else wall_point.z
		return declared_room if absf(wall_coordinate - expected_face) <= 0.02 else {}
	var spatial_matches: Array[Dictionary] = []
	for room_value in rooms:
		if not room_value is Dictionary:
			continue
		var room: Dictionary = room_value as Dictionary
		var bounds: AABB = room.get("bounds", AABB()) as AABB
		if _valid_room_bounds(bounds) and bounds.grow(0.20).has_point(position):
			spatial_matches.append(room)
	return spatial_matches[0] if spatial_matches.size() == 1 else {}


static func _valid_room_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() and bounds.size.x > 0.0 and bounds.size.y > 0.0 and bounds.size.z > 0.0


static func inward_direction(bounds: AABB, position: Vector3) -> Vector3:
	var distances := [
		{"distance": absf(position.x - bounds.position.x), "direction": Vector3.RIGHT},
		{"distance": absf(position.x - bounds.end.x), "direction": Vector3.LEFT},
		{"distance": absf(position.z - bounds.position.z), "direction": Vector3.FORWARD},
		{"distance": absf(position.z - bounds.end.z), "direction": Vector3.BACK}
	]
	var closest: Dictionary = distances[0] as Dictionary
	for candidate_value in distances:
		var candidate: Dictionary = candidate_value as Dictionary
		if float(candidate.get("distance", INF)) < float(closest.get("distance", INF)):
			closest = candidate
	return closest.get("direction", Vector3.FORWARD) as Vector3
