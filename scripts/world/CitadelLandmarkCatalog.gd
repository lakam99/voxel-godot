extends RefCounted
class_name CitadelLandmarkCatalog

const Planner := preload("res://scripts/world/CitadelSiteManifestPlanner.gd")
const REGION_SPAN_CELLS := Planner.CITADEL_REGION_CELLS
const TOWN_APRON_RESERVATION_CELLS := 128

static func resolved_manifest_for_region(seed_text: String, _seed_hash: int, region_x: int, region_z: int, natural_surface_sample: Callable, town_region: Callable, typed_landmarks: Array = [], heartbeat: Callable = Callable()) -> Dictionary:
	if heartbeat.is_valid():
		heartbeat.call()
	var terrain_sample := func(cell: Vector3i) -> Dictionary:
		if heartbeat.is_valid():
			heartbeat.call()
		var sample_value = natural_surface_sample.call(Vector2i(cell.x, cell.z)) if natural_surface_sample.is_valid() else {}
		return sample_value if sample_value is Dictionary else {}
	var candidate := Planner.manifest_for_region(
		seed_text,
		region_x,
		region_z,
		REGION_SPAN_CELLS,
		terrain_sample,
	)
	if candidate.is_empty():
		return {}
	var terrain: Dictionary = candidate.get("terrain", {}) if candidate.get("terrain", {}) is Dictionary else {}
	var bounds: Dictionary = terrain.get("reservedBounds", {}) if terrain.get("reservedBounds", {}) is Dictionary else {}
	var minimum: Variant = bounds.get("minCell", null)
	var maximum: Variant = bounds.get("maxCell", null)
	if not (minimum is Vector2i) or not (maximum is Vector2i):
		return {}
	var reservations := town_reservations(minimum, maximum, town_region, heartbeat)
	for landmark_value in typed_landmarks:
		if landmark_value is Dictionary:
			var landmark: Dictionary = landmark_value
			if String(landmark.get("id", "")) != String(candidate.get("id", "")):
				var landmark_terrain: Dictionary = landmark.get("terrain", {}) if landmark.get("terrain", {}) is Dictionary else {}
				var landmark_bounds: Dictionary = landmark_terrain.get("reservedBounds", {}) if landmark_terrain.get("reservedBounds", {}) is Dictionary else {}
				if landmark_bounds.get("minCell", null) is Vector2i and landmark_bounds.get("maxCell", null) is Vector2i:
					reservations.append({
						"id": "typed:%s" % String(landmark.get("id", "")),
						"kind": "typed_landmark",
						"reservedBounds": landmark_bounds
					})
	return {} if Planner.conflicts_with_reservations(candidate, reservations) else candidate


static func reservations_for_neighborhood(seed_text: String, seed_hash: int, region_x: int, region_z: int, natural_surface_sample: Callable, town_region: Callable) -> Array:
	var result: Array = []
	var minimum := Vector2i((region_x - 1) * REGION_SPAN_CELLS, (region_z - 1) * REGION_SPAN_CELLS)
	var maximum := Vector2i((region_x + 2) * REGION_SPAN_CELLS - 1, (region_z + 2) * REGION_SPAN_CELLS - 1)
	result.append_array(town_reservations(minimum, maximum, town_region))
	result.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return String(left.get("id", "")) < String(right.get("id", "")))
	return result


static func town_reservations(minimum: Vector2i, maximum: Vector2i, town_region: Callable, heartbeat: Callable = Callable()) -> Array:
	var result: Array = []
	if not town_region.is_valid():
		return result
	const span := 280
	var min_region := Vector2i(floori(float(minimum.x) / float(span)), floori(float(minimum.y) / float(span)))
	var max_region := Vector2i(floori(float(maximum.x) / float(span)), floori(float(maximum.y) / float(span)))
	for region_z in range(min_region.y, max_region.y + 1):
		for region_x in range(min_region.x, max_region.x + 1):
			if heartbeat.is_valid():
				heartbeat.call()
			var town_value = town_region.call(region_x, region_z)
			if not (town_value is Dictionary):
				continue
			var town: Dictionary = town_value
			if town.is_empty():
				continue
			var radius := int(town.get("radius", 0)) + TOWN_APRON_RESERVATION_CELLS
			var center := Vector2i(int(town.get("centerX", 0)), int(town.get("centerZ", 0)))
			result.append({
				"id": "town:%d,%d" % [region_x, region_z],
				"kind": "town",
				"reservedBounds": {"minCell": center - Vector2i(radius, radius), "maxCell": center + Vector2i(radius, radius)}
			})
	return result
