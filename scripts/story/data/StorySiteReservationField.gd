extends RefCounted
class_name StorySiteReservationField

const SITE_VERSION := 1
const REGION_CELLS := 280
const MIN_SITE_SEPARATION_CELLS := 8
const WATER_MARGIN := 1.2
const MAX_LOCAL_VARIATION := 2.4
const LANDMARK_RESERVATION_RADIUS_CELLS := 8

const SITE_DEFINITIONS := [
	{"id": "ordinary_antler_scars", "kind": "clue", "clueKind": "ordinary", "label": "Pale antler scars", "prompt": "Inspect pale scars", "textId": "story.gloam_hart.clue.antler_scars"},
	{"id": "ordinary_ringing_stone", "kind": "clue", "clueKind": "ordinary", "label": "Ringing boundary stone", "prompt": "Listen to the stone", "textId": "story.gloam_hart.clue.ringing_stone"},
	{"id": "ordinary_broken_lantern", "kind": "clue", "clueKind": "ordinary", "label": "Broken lantern frame", "prompt": "Study the lantern", "textId": "story.gloam_hart.clue.broken_lantern"},
	{"id": "historical_old_compact", "kind": "clue", "clueKind": "historical", "label": "Old compact record", "prompt": "Read the old record", "textId": "story.gloam_hart.clue.old_compact"},
	{"id": "boundary_stone_north", "kind": "boundary_stone", "label": "North boundary stone", "prompt": "Examine boundary stone", "textId": "story.gloam_hart.boundary_stone.north"},
	{"id": "boundary_stone_south", "kind": "boundary_stone", "label": "South boundary stone", "prompt": "Examine boundary stone", "textId": "story.gloam_hart.boundary_stone.south"},
	{"id": "encounter_marker", "kind": "encounter_marker", "label": "Storm-lashed hollow", "prompt": "Survey storm hollow", "textId": "story.gloam_hart.encounter.locked"}
]


static func sites_for_region(seed_text: String, seed_hash: int, region_x: int, region_z: int, surface_sample: Callable) -> Array:
	var result: Array = []
	if not surface_sample.is_valid():
		return result
	var region_id := "r:%d,%d" % [region_x, region_z]
	var region_seed := stable_hash("%s|%d|%s|region-story-v1" % [seed_text, seed_hash, region_id])
	var center := Vector2i(
		region_x * REGION_CELLS + floori(float(REGION_CELLS) * 0.5),
		region_z * REGION_CELLS + floori(float(REGION_CELLS) * 0.5)
	)
	for definition_value in SITE_DEFINITIONS:
		if not (definition_value is Dictionary):
			continue
		var definition: Dictionary = definition_value
		var site := _choose_site(definition, region_id, region_seed, center, result, surface_sample)
		if not site.is_empty():
			result.append(site)
	return result


static func reservations_for_bounds(seed_text: String, seed_hash: int, minimum: Vector2i, maximum: Vector2i, surface_sample: Callable) -> Array:
	var result: Array = []
	var min_region := Vector2i(floori(float(minimum.x) / float(REGION_CELLS)), floori(float(minimum.y) / float(REGION_CELLS)))
	var max_region := Vector2i(floori(float(maximum.x) / float(REGION_CELLS)), floori(float(maximum.y) / float(REGION_CELLS)))
	for region_z in range(min_region.y, max_region.y + 1):
		for region_x in range(min_region.x, max_region.x + 1):
			for site_value in sites_for_region(seed_text, seed_hash, region_x, region_z, surface_sample):
				if not (site_value is Dictionary):
					continue
				var cell := site_cell(site_value)
				result.append({
					"id": "story:%s" % String((site_value as Dictionary).get("id", "")),
					"kind": "story_site",
					"reservedBounds": {
						"minCell": cell - Vector2i(LANDMARK_RESERVATION_RADIUS_CELLS, LANDMARK_RESERVATION_RADIUS_CELLS),
						"maxCell": cell + Vector2i(LANDMARK_RESERVATION_RADIUS_CELLS, LANDMARK_RESERVATION_RADIUS_CELLS)
					}
				})
	result.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return String(left.get("id", "")) < String(right.get("id", "")))
	return result


static func _choose_site(definition: Dictionary, region_id: String, seed_value: int, center: Vector2i, existing_sites: Array, surface_sample: Callable) -> Dictionary:
	var safe_radius := maxi(24, int(float(REGION_CELLS) * 0.38))
	for attempt in range(160):
		var angle_seed := stable_hash("%s|%s|%d|angle" % [region_id, definition.get("id", ""), attempt])
		var radius_seed := stable_hash("%s|%s|%d|radius" % [region_id, definition.get("id", ""), attempt])
		var angle := TAU * float(angle_seed % 10000) / 10000.0
		var radius := float(18 + (radius_seed % safe_radius))
		var cell := center + Vector2i(roundi(cos(angle) * radius), roundi(sin(angle) * radius))
		if _is_site_valid(cell, existing_sites, surface_sample):
			return _make_site(definition, region_id, seed_value, cell, surface_sample)
	return {}


static func _make_site(definition: Dictionary, region_id: String, seed_value: int, cell: Vector2i, surface_sample: Callable) -> Dictionary:
	var sample_value = surface_sample.call(cell) if surface_sample.is_valid() else {}
	var sample: Dictionary = sample_value if sample_value is Dictionary else {}
	var site_id := String(definition.get("id", "site"))
	return {
		"schemaVersion": 1,
		"id": "%s:%s" % [region_id, site_id],
		"definitionId": site_id,
		"kind": String(definition.get("kind", "")),
		"clueKind": String(definition.get("clueKind", "")),
		"label": String(definition.get("label", "")),
		"prompt": String(definition.get("prompt", "Inspect")),
		"textId": String(definition.get("textId", "")),
		"regionId": region_id,
		"cell": [cell.x, cell.y],
		"worldY": float(sample.get("surfaceY", 0.0)),
		"placementSeed": stable_hash("%s|%s|%d" % [region_id, site_id, seed_value])
	}


static func _is_site_valid(cell: Vector2i, existing_sites: Array, surface_sample: Callable) -> bool:
	var sample_value = surface_sample.call(cell)
	if not (sample_value is Dictionary):
		return false
	var sample: Dictionary = sample_value
	if bool(sample.get("inTown", false)) or bool(sample.get("inLandmark", false)) or float(sample.get("surfaceY", 0.0)) <= float(sample.get("waterLevel", 0.0)) + WATER_MARGIN:
		return false
	if String(sample.get("biome", "")) in ["ocean", "beach", "town"] or float(sample.get("variation", INF)) > MAX_LOCAL_VARIATION:
		return false
	for dz in range(-2, 3):
		for dx in range(-2, 3):
			var nearby_value = surface_sample.call(cell + Vector2i(dx, dz))
			if nearby_value is Dictionary:
				var nearby: Dictionary = nearby_value
				if not bool(nearby.get("inTown", false)) and not bool(nearby.get("inLandmark", false)) and float(nearby.get("surfaceY", 0.0)) > float(nearby.get("waterLevel", 0.0)) + WATER_MARGIN and String(nearby.get("biome", "")) not in ["ocean", "beach"]:
					return _is_separated(cell, existing_sites)
	return false


static func _is_separated(cell: Vector2i, existing_sites: Array) -> bool:
	for site_value in existing_sites:
		if site_value is Dictionary and Vector2(cell).distance_to(Vector2(site_cell(site_value))) < float(MIN_SITE_SEPARATION_CELLS):
			return false
	return true


static func site_cell(site: Dictionary) -> Vector2i:
	var cell_value = site.get("cell", [])
	if cell_value is Array and cell_value.size() >= 2:
		return Vector2i(int(cell_value[0]), int(cell_value[1]))
	return Vector2i.ZERO


static func stable_hash(text: String) -> int:
	var value := 2166136261
	for index in range(text.length()):
		value = int((value ^ text.unicode_at(index)) & 0x7fffffff)
		value = int((value * 16777619) & 0x7fffffff)
	return value
