extends RefCounted
class_name LandmarkSiteAuthority

const REGION_SPAN_CELLS := 420

var seed_text := ""
var records_by_id: Dictionary = {}
var records_by_region: Dictionary = {}
var revision := 0


func reset_for_seed(next_seed: String) -> void:
	seed_text = next_seed
	records_by_id.clear()
	records_by_region.clear()
	revision += 1


func register_site(source: Dictionary, region_span_cells: int) -> Dictionary:
	if region_span_cells != REGION_SPAN_CELLS:
		return {"accepted": false, "reason": "unsupported_landmark_region_span"}
	var site := _normalized_site(source, region_span_cells)
	if site.is_empty():
		return {"accepted": false, "reason": "invalid_landmark_site"}
	var site_id := String(site.get("id", ""))
	var existing: Dictionary = records_by_id.get(site_id, {}) if records_by_id.get(site_id, {}) is Dictionary else {}
	if existing == site:
		return {"accepted": true, "changed": false, "site": existing.duplicate(true), "revision": revision}
	if _overlaps_registered_site(site, site_id):
		return {"accepted": false, "reason": "landmark_site_overlap"}
	if not existing.is_empty():
		_remove_site_regions(existing)
	records_by_id[site_id] = site
	_add_site_regions(site, region_span_cells)
	revision += 1
	return {"accepted": true, "changed": true, "site": site.duplicate(true), "revision": revision}


func sites_for_region(region_x: int, region_z: int) -> Array:
	var source: Array = records_by_region.get(Vector2i(region_x, region_z), []) if records_by_region.get(Vector2i(region_x, region_z), []) is Array else []
	var result: Array = []
	for value in source:
		if value is Dictionary:
			result.append((value as Dictionary).duplicate(true))
	result.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return String(left.get("id", "")) < String(right.get("id", "")))
	return result

func worker_sites_for_region(region_x: int, region_z: int) -> Array:
	var source: Variant = records_by_region.get(Vector2i(region_x, region_z), [])
	return source if source is Array else []


func snapshot_by_region() -> Dictionary:
	var result := {}
	for region_value in records_by_region.keys():
		if region_value is Vector2i:
			var region: Vector2i = region_value
			result[region] = sites_for_region(region.x, region.y)
	return result


func _normalized_site(source: Dictionary, region_span_cells: int) -> Dictionary:
	var site_id := String(source.get("id", "")).strip_edges()
	var kind := String(source.get("kind", "")).strip_edges().to_lower()
	var terrain: Dictionary = source.get("terrain", {}) if source.get("terrain", {}) is Dictionary else {}
	var center: Variant = source.get("center", Vector2i.ZERO)
	if site_id.is_empty() or kind.is_empty() or region_span_cells <= 0 or not (center is Vector2i) or terrain.is_empty():
		return {}
	var reserved_bounds: Dictionary = terrain.get("reservedBounds", {}) if terrain.get("reservedBounds", {}) is Dictionary else {}
	if not (reserved_bounds.get("minCell", null) is Vector2i) or not (reserved_bounds.get("maxCell", null) is Vector2i):
		return {}
	var normalized := source.duplicate(true)
	normalized["id"] = site_id
	normalized["kind"] = kind
	normalized["siteType"] = "landmark"
	normalized["seed"] = seed_text
	normalized["siteRegionCells"] = region_span_cells
	return normalized

func _overlaps_registered_site(site: Dictionary, ignored_id: String) -> bool:
	var terrain: Dictionary = site.get("terrain", {})
	var bounds: Dictionary = terrain.get("reservedBounds", {})
	var minimum: Vector2i = bounds.get("minCell", Vector2i.ZERO)
	var maximum: Vector2i = bounds.get("maxCell", Vector2i.ZERO)
	for existing_value in records_by_id.values():
		if not (existing_value is Dictionary):
			continue
		var existing: Dictionary = existing_value
		if String(existing.get("id", "")) == ignored_id:
			continue
		var existing_terrain: Dictionary = existing.get("terrain", {}) if existing.get("terrain", {}) is Dictionary else {}
		var existing_bounds: Dictionary = existing_terrain.get("reservedBounds", {}) if existing_terrain.get("reservedBounds", {}) is Dictionary else {}
		var existing_minimum: Vector2i = existing_bounds.get("minCell", Vector2i.ZERO)
		var existing_maximum: Vector2i = existing_bounds.get("maxCell", Vector2i.ZERO)
		if minimum.x <= existing_maximum.x and existing_minimum.x <= maximum.x and minimum.y <= existing_maximum.y and existing_minimum.y <= maximum.y:
			return true
	return false


func _add_site_regions(site: Dictionary, region_span_cells: int) -> void:
	var terrain: Dictionary = site.get("terrain", {})
	var bounds: Dictionary = terrain.get("reservedBounds", {})
	var minimum: Vector2i = bounds.get("minCell", Vector2i.ZERO)
	var maximum: Vector2i = bounds.get("maxCell", Vector2i.ZERO)
	var min_region := Vector2i(floori(float(minimum.x) / float(region_span_cells)), floori(float(minimum.y) / float(region_span_cells)))
	var max_region := Vector2i(floori(float(maximum.x) / float(region_span_cells)), floori(float(maximum.y) / float(region_span_cells)))
	for region_z in range(min_region.y, max_region.y + 1):
		for region_x in range(min_region.x, max_region.x + 1):
			var key := Vector2i(region_x, region_z)
			var records: Array = records_by_region.get(key, []) if records_by_region.get(key, []) is Array else []
			records.append(site.duplicate(true))
			records_by_region[key] = records


func _remove_site_regions(site: Dictionary) -> void:
	var site_id := String(site.get("id", ""))
	for region_value in records_by_region.keys().duplicate():
		var records: Array = records_by_region.get(region_value, []) if records_by_region.get(region_value, []) is Array else []
		records = records.filter(func(value) -> bool: return not (value is Dictionary) or String((value as Dictionary).get("id", "")) != site_id)
		if records.is_empty():
			records_by_region.erase(region_value)
		else:
			records_by_region[region_value] = records
