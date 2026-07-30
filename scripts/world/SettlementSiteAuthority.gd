extends RefCounted
class_name SettlementSiteAuthority

# Settlement footprints must reach the terrain generator before the city shell
# does. This authority keeps a site in the same deterministic terrain contract
# as solidity, collision, digging, lighting, and navigation publication.

var seed_text: String = ""
var records_by_id: Dictionary = {}
var records_by_region: Dictionary = {}
var revision: int = 0


func reset_for_seed(next_seed: String) -> void:
	seed_text = next_seed
	records_by_id.clear()
	records_by_region.clear()
	revision += 1


func register_site(source: Dictionary, region_span_cells: int) -> Dictionary:
	var normalized: Dictionary = normalized_site(source, region_span_cells)
	if normalized.is_empty():
		return {"accepted": false, "reason": "invalid_settlement_site"}
	var id: String = String(normalized.get("id", ""))
	var existing: Dictionary = records_by_id.get(id, {}) as Dictionary
	if not existing.is_empty() and existing == normalized:
		return {"accepted": true, "changed": false, "site": existing.duplicate(true), "revision": revision}
	if not existing.is_empty():
		remove_site_regions(existing)
	records_by_id[id] = normalized
	add_site_regions(normalized, region_span_cells)
	revision += 1
	return {"accepted": true, "changed": true, "site": normalized.duplicate(true), "revision": revision}


func site_for_region(region_x: int, region_z: int) -> Dictionary:
	var records: Array = records_by_region.get(Vector2i(region_x, region_z), []) as Array
	if records.is_empty():
		return {}
	var ordered: Array[Dictionary] = []
	for value in records:
		if value is Dictionary:
			ordered.append(value as Dictionary)
	ordered.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return String(left.get("id", "")) < String(right.get("id", ""))
	)
	return ordered[0].duplicate(true) if not ordered.is_empty() else {}


func snapshot_by_region() -> Dictionary:
	var snapshot: Dictionary = {}
	for region_value in records_by_region.keys():
		if not (region_value is Vector2i):
			continue
		var region: Vector2i = region_value
		var site: Dictionary = site_for_region(region.x, region.y)
		if not site.is_empty():
			snapshot[region] = site
	return snapshot


func normalized_site(source: Dictionary, region_span_cells: int) -> Dictionary:
	var id: String = String(source.get("id", "")).strip_edges()
	if id.is_empty() or region_span_cells <= 0:
		return {}
	var center: Variant = source.get("center", Vector2i.ZERO)
	if not (center is Vector2i):
		return {}
	var center_cell: Vector2i = center
	var radius: int = maxi(1, int(source.get("radius", 0)))
	var level: float = float(source.get("level", NAN))
	if is_nan(level):
		return {}
	var record: Dictionary = source.duplicate(true)
	record["id"] = id
	record["centerX"] = center_cell.x
	record["centerZ"] = center_cell.y
	record["radius"] = radius
	record["level"] = level
	record["regionX"] = floori(float(center_cell.x) / float(region_span_cells))
	record["regionZ"] = floori(float(center_cell.y) / float(region_span_cells))
	record["terrainAuthority"] = "deterministic_settlement_site"
	record["seed"] = seed_text
	return record


func add_site_regions(site: Dictionary, region_span_cells: int) -> void:
	var center: Vector2i = Vector2i(int(site.get("centerX", 0)), int(site.get("centerZ", 0)))
	var radius: int = int(site.get("radius", 0))
	var minimum: Vector2i = center - Vector2i(radius, radius)
	var maximum: Vector2i = center + Vector2i(radius, radius)
	var min_region: Vector2i = Vector2i(floori(float(minimum.x) / float(region_span_cells)), floori(float(minimum.y) / float(region_span_cells)))
	var max_region: Vector2i = Vector2i(floori(float(maximum.x) / float(region_span_cells)), floori(float(maximum.y) / float(region_span_cells)))
	for region_z in range(min_region.y, max_region.y + 1):
		for region_x in range(min_region.x, max_region.x + 1):
			var key: Vector2i = Vector2i(region_x, region_z)
			var records: Array = records_by_region.get(key, []) as Array
			records.append(site)
			records_by_region[key] = records


func remove_site_regions(site: Dictionary) -> void:
	var id: String = String(site.get("id", ""))
	for region_value in records_by_region.keys().duplicate():
		var records: Array = records_by_region.get(region_value, []) as Array
		records = records.filter(func(value) -> bool:
			return not (value is Dictionary) or String((value as Dictionary).get("id", "")) != id
		)
		if records.is_empty():
			records_by_region.erase(region_value)
		else:
			records_by_region[region_value] = records
