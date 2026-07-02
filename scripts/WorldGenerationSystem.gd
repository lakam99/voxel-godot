extends RefCounted
class_name WorldGenerationSystem

const CAVE_AIR_THRESHOLD := 1.0
const CAVE_REGION_CELLS := 96
const CAVE_FEATURE_SEARCH_RADIUS := 1

var main
var excavation_brushes: Array[Dictionary] = []
var cave_feature_cache := {}
var surface_projection_cache := {}

func setup(main_node) -> void:
	main = main_node

func reset() -> void:
	excavation_brushes.clear()
	cave_feature_cache.clear()
	surface_projection_cache.clear()

func reset_for_seed() -> void:
	excavation_brushes.clear()
	cave_feature_cache.clear()
	surface_projection_cache.clear()

func sample_cell(cell: Vector3i) -> Dictionary:
	var s := cell_size()
	return sample_world(Vector3((float(cell.x) + 0.5) * s, (float(cell.y) + 0.5) * s, (float(cell.z) + 0.5) * s))

func sample_world(position: Vector3) -> Dictionary:
	var surface_y := terrain_reference_surface_y_at(position)
	var cave_value := cave_biome_value_at(position)
	var density := density_from_components(position, surface_y, cave_value)
	var solid := density >= 0.0
	var cave_influence := cave_value <= 0.0
	var cell := world_to_cell3(position)
	var biome := "cave" if cave_influence and not solid else surface_biome_for_cell3(Vector3i(cell.x, 0, cell.z))
	var material := material_from_sample_components(position, density, cave_value, surface_y, cell)
	return {
		"cell": cell,
		"position": position,
		"density": density,
		"solid": solid,
		"biome": biome,
		"material": material,
		"surface": absf(density) <= cell_size() * 0.75,
		"caveValue": cave_value
	}

func density_at(position: Vector3) -> float:
	var surface_y := terrain_reference_surface_y_at(position)
	var cave_value := cave_biome_value_at(position)
	return density_from_components(position, surface_y, cave_value)

func density_from_components(position: Vector3, surface_y: float, cave_value: float) -> float:
	var density := surface_y - position.y
	if cave_value < density:
		density = cave_value
	for brush in merged_excavation_brushes([]):
		var center: Vector3 = brush.get("center", Vector3.ZERO)
		var radius := float(brush.get("radius", 0.0))
		if radius > 0.0:
			density = minf(density, center.distance_to(position) - radius)
	return density

func solid_at(position: Vector3) -> bool:
	return density_at(position) >= 0.0

func biome_at(position: Vector3) -> String:
	return String(sample_world(position).get("biome", "plains"))

func material_at(position: Vector3) -> String:
	var surface_y := terrain_reference_surface_y_at(position)
	var cave_value := cave_biome_value_at(position)
	var density := density_from_components(position, surface_y, cave_value)
	var cell := world_to_cell3(position)
	return material_from_sample_components(position, density, cave_value, surface_y, cell)

func material_from_sample_components(position: Vector3, density: float, cave_value: float, surface_y: float, cell: Vector3i) -> String:
	if density < 0.0:
		return "air"
	var depth := maxf(0.0, surface_y - position.y)
	if cave_value <= cell_size() * 0.85:
		var ore := ore_material_at(cell, depth)
		return ore if ore != "" else "stone"
	var biome := surface_biome_for_cell3(Vector3i(cell.x, 0, cell.z))
	if depth <= cell_size() * 1.20:
		return top_material_for_biome(biome)
	if depth <= cell_size() * 4.65:
		return subsoil_material_for_biome(biome)
	var ore := ore_material_at(cell, depth)
	if ore != "":
		return ore
	return "stone"

func register_excavation_brush(brush: Dictionary) -> void:
	var brush_id := String(brush.get("id", ""))
	if brush_id == "":
		return
	for index in range(excavation_brushes.size()):
		if String(excavation_brushes[index].get("id", "")) == brush_id:
			excavation_brushes[index] = brush.duplicate(true)
			surface_projection_cache.clear()
			return
	excavation_brushes.append(brush.duplicate(true))
	surface_projection_cache.clear()

func clear_excavation_brushes() -> void:
	excavation_brushes.clear()
	surface_projection_cache.clear()

func surface_y_at(position: Vector3) -> float:
	return terrain_reference_surface_y_at(position)

func surface_y_for_cell(cell: Vector3i) -> float:
	return terrain_reference_surface_y_for_cell(cell)

func volume_surface_y_for_cell(cell: Vector3i) -> float:
	var key := Vector2i(cell.x, cell.z)
	if surface_projection_cache.has(key):
		return float(surface_projection_cache[key])
	var high := ceili((float(main.MAX_HEIGHT) + cell_size() * 4.0) / cell_size()) if main != null else 96
	var low := floori((float(main.MIN_HEIGHT) - cell_size() * 24.0) / cell_size()) if main != null else -16
	for y in range(high, low, -1):
		var solid_sample := sample_cell(Vector3i(cell.x, y, cell.z))
		if not bool(solid_sample.get("solid", false)):
			continue
		var air_sample := sample_cell(Vector3i(cell.x, y + 1, cell.z))
		if not bool(air_sample.get("solid", true)):
			var projected_y := surface_boundary_y_between_samples(y, solid_sample, air_sample)
			surface_projection_cache[key] = projected_y
			return projected_y
	var fallback := terrain_reference_surface_y_for_cell(cell)
	surface_projection_cache[key] = fallback
	return fallback

func surface_boundary_y_between_samples(solid_cell_y: int, solid_sample: Dictionary, air_sample: Dictionary) -> float:
	var solid_density := float(solid_sample.get("density", 1.0))
	var air_density := float(air_sample.get("density", -1.0))
	var denominator := solid_density - air_density
	if absf(denominator) <= 0.0001:
		return float(solid_cell_y + 1) * cell_size()
	var solid_center_y := (float(solid_cell_y) + 0.5) * cell_size()
	var air_center_y := (float(solid_cell_y) + 1.5) * cell_size()
	var t := clampf(solid_density / denominator, 0.0, 1.0)
	return lerp(solid_center_y, air_center_y, t)

func terrain_reference_surface_y_at(position: Vector3) -> float:
	return terrain_reference_surface_y_for_cell(Vector3i(roundi(position.x / cell_size()), 0, roundi(position.z / cell_size())))

func terrain_reference_surface_y_for_cell(cell: Vector3i) -> float:
	return base_surface_y_for_cell(cell)

func base_surface_y_for_cell(cell: Vector3i) -> float:
	var town: Dictionary = town_region_for_surface_cell3(cell)
	if not town.is_empty():
		var center_x := int(town["centerX"])
		var center_z := int(town["centerZ"])
		var radius := float(town["radius"])
		var distance := Vector2(float(cell.x - center_x), float(cell.z - center_z)).length()
		var level := float(town["level"])
		if distance <= radius:
			return level
		var apron := float(town_slope_apron_cells(town))
		var natural := natural_surface_y_for_cell(cell)
		var blend := clampf((distance - radius) / maxf(1.0, apron), 0.0, 1.0)
		var eased := blend * blend * (3.0 - 2.0 * blend)
		return lerp(level, natural, eased)
	return natural_surface_y_for_cell(cell)

func natural_surface_y_for_cell(cell: Vector3i) -> float:
	if main == null:
		return 0.0
	var x := cell.x
	var z := cell.z
	var continent: float = main.noise01(main.height_noise, x, z)
	var broad_hill: float = main.noise01(main.height_noise, x + 12000, z - 12200)
	var plain_field: float = main.noise01(main.flat_noise, x - 8400, z + 7200)
	var ridges: float = abs(main.noise01(main.ridge_noise, x - 200, z + 510) - 0.5) * 2.0
	var flatland_mask: float = main.smoothstep_range(plain_field, 0.42, 0.68)
	var mountain_mask: float = main.smoothstep_range(main.noise01(main.height_noise, x + 1800, z - 1500), 0.58, 0.82)
	var peak_mask: float = main.smoothstep_range(main.noise01(main.ridge_noise, x - 3900, z + 2600), 0.74, 0.93) * mountain_mask
	var plains: float = 6.0 + continent * 10.0 + (broad_hill - 0.5) * 2.0
	var hills: float = 7.2 + continent * 15.5 + pow(maxf(broad_hill - 0.18, 0.0), 1.45) * 12.0
	var mountains: float = 10.0 + continent * 21.0 + pow(ridges, 1.92) * (16.0 + mountain_mask * 44.0) + pow(peak_mask, 2.05) * 34.0
	var lowland: float = lerp(hills, plains, flatland_mask)
	var detail: float = (main.noise01(main.ridge_noise, x + 7800, z - 9100) - 0.5) * lerp(0.28, 1.35, mountain_mask)
	var raw: float = float(main.MIN_HEIGHT) + lerp(lowland, mountains, mountain_mask) + detail
	var terrace: float = lerp(float(main.CELL) * 0.34, float(main.CELL) * 1.15, mountain_mask)
	return clamp(round(raw / terrace) * terrace, float(main.MIN_HEIGHT), float(main.MAX_HEIGHT))

func surface_biome_for_cell3(cell: Vector3i) -> String:
	if not town_region_at_cell3(cell).is_empty():
		return "town"
	var h: float = terrain_reference_surface_y_for_cell(cell)
	var moisture: float = main.noise01(main.moisture_noise, cell.x - 1200, cell.z + 800) if main != null else 0.5
	var temp: float = clamp(0.42 + (main.noise01(main.temp_noise, cell.x + 1500, cell.z - 900) if main != null else 0.5) * 0.46 - abs(cell.z) / 1300.0 - max(0.0, h - 38.0) / 180.0, 0.0, 1.0)
	if h < float(main.WATER_LEVEL) + 0.3:
		return "ocean"
	if h < float(main.WATER_LEVEL) + 1.7:
		return "beach"
	if h > 78.0:
		return "snow"
	if h > 56.0:
		return "alpine" if temp < 0.48 else "tundra"
	if h > 42.0 and moisture < 0.5:
		return "alpine"
	if moisture > 0.78 and h < float(main.WATER_LEVEL) + 6.0:
		return "swamp"
	if temp > 0.68 and moisture < 0.32:
		return "desert"
	if temp > 0.61 and moisture < 0.48:
		return "savanna"
	if temp < 0.33 and moisture > 0.42:
		return "taiga"
	if moisture > 0.64:
		return "forest"
	return "plains"

func biome_at_volume_cell(cell: Vector3i) -> String:
	return biome_at(Vector3((float(cell.x) + 0.5) * cell_size(), (float(cell.y) + 0.5) * cell_size(), (float(cell.z) + 0.5) * cell_size()))

func biome_at_world(world_pos: Vector3) -> String:
	return biome_at(world_pos)

func material_at_cell3(cell: Vector3i) -> String:
	return material_at(Vector3((float(cell.x) + 0.5) * cell_size(), (float(cell.y) + 0.5) * cell_size(), (float(cell.z) + 0.5) * cell_size()))

func solid_at_world(world_pos: Vector3, active_plan_records = null, extra_excavation_brushes := []) -> bool:
	if density_at(world_pos) < 0.0:
		return false
	for brush in merged_excavation_brushes(extra_excavation_brushes):
		var center: Vector3 = brush.get("center", Vector3.ZERO)
		var radius := float(brush.get("radius", 0.0))
		if radius > 0.0 and center.distance_to(world_pos) <= radius:
			return false
	return true

func is_air_at_world(world_pos: Vector3, active_plan_records = null, extra_excavation_brushes := []) -> bool:
	if density_at(world_pos) < 0.0:
		return true
	for brush_value in merged_excavation_brushes(extra_excavation_brushes):
		if not (brush_value is Dictionary):
			continue
		var brush: Dictionary = brush_value
		var center: Vector3 = brush.get("center", Vector3.ZERO)
		var radius := float(brush.get("radius", 0.0))
		if radius > 0.0 and center.distance_to(world_pos) <= radius:
			return true
	return false

func terrain_surface_y_at(position: Vector3) -> float:
	return surface_y_at(position)

func cave_biome_value_at(world_pos: Vector3) -> float:
	var best := INF
	for feature in cave_features_near_world(world_pos):
		best = minf(best, cave_feature_air_value(feature, world_pos))
	return best

func cave_features_near_world(world_pos: Vector3) -> Array[Dictionary]:
	var features: Array[Dictionary] = []
	var region_world_size := float(CAVE_REGION_CELLS) * cell_size()
	var region_x := floori(world_pos.x / region_world_size)
	var region_z := floori(world_pos.z / region_world_size)
	for rz in range(region_z - CAVE_FEATURE_SEARCH_RADIUS, region_z + CAVE_FEATURE_SEARCH_RADIUS + 1):
		for rx in range(region_x - CAVE_FEATURE_SEARCH_RADIUS, region_x + CAVE_FEATURE_SEARCH_RADIUS + 1):
			var feature := cave_feature_for_region(rx, rz)
			if not feature.is_empty():
				features.append(feature)
	return features

func cave_feature_for_region(region_x: int, region_z: int) -> Dictionary:
	var key := Vector2i(region_x, region_z)
	if cave_feature_cache.has(key):
		var cached = cave_feature_cache[key]
		return (cached as Dictionary) if cached is Dictionary else {}
	if volume_hash01("spawn", region_x, region_z, 0) > 0.62:
		cave_feature_cache[key] = {}
		return {}
	var best := {}
	var best_score := -INF
	var margin := 14
	var usable := CAVE_REGION_CELLS - margin * 2
	var directions: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for attempt in range(18):
		var local_x := margin + floori(volume_hash01("candidate-x", region_x, region_z, attempt) * float(usable))
		var local_z := margin + floori(volume_hash01("candidate-z", region_x, region_z, attempt) * float(usable))
		var entrance := Vector2i(region_x * CAVE_REGION_CELLS + local_x, region_z * CAVE_REGION_CELLS + local_z)
		if not town_region_at_cell3(Vector3i(entrance.x, 0, entrance.y)).is_empty():
			continue
		var entrance_biome := surface_biome_for_cell3(Vector3i(entrance.x, 0, entrance.y))
		if entrance_biome in ["ocean", "beach", "swamp", "town"]:
			continue
		var entrance_h := base_surface_y_for_cell(Vector3i(entrance.x, 0, entrance.y))
		if main != null and entrance_h < float(main.WATER_LEVEL) + cell_size() * 4.0:
			continue
		for dir in directions:
			var front := entrance - dir * 7
			var back := entrance + dir * 12
			var front_h := base_surface_y_for_cell(Vector3i(front.x, 0, front.y))
			var back_h := base_surface_y_for_cell(Vector3i(back.x, 0, back.y))
			var side_a := entrance + Vector2i(-dir.y, dir.x) * 5
			var side_b := entrance + Vector2i(dir.y, -dir.x) * 5
			var side_h := minf(
				base_surface_y_for_cell(Vector3i(side_a.x, 0, side_a.y)),
				base_surface_y_for_cell(Vector3i(side_b.x, 0, side_b.y))
			)
			var slope := back_h - front_h
			var cover := minf(back_h, side_h) - entrance_h
			if slope < cell_size() * 1.15 or cover < cell_size() * 0.80:
				continue
			var roughness := absf(base_surface_y_for_cell(Vector3i(entrance.x + dir.y * 3, 0, entrance.y - dir.x * 3)) - base_surface_y_for_cell(Vector3i(entrance.x - dir.y * 3, 0, entrance.y + dir.x * 3)))
			var score := slope + cover * 0.85 + roughness * 0.25 + volume_hash01("candidate-score", region_x, region_z, attempt) * cell_size() * 4.0
			if score <= best_score:
				continue
			var right := Vector2i(-dir.y, dir.x)
			var candidate := {
				"id": "cave-biome:%d,%d" % [region_x, region_z],
				"region": Vector2i(region_x, region_z),
				"entranceCell": entrance,
				"entranceSurfaceY": entrance_h,
				"inward": dir,
				"right": right,
				"radius": cell_size() * lerpf(2.75, 3.75, volume_hash01("radius", region_x, region_z, attempt)),
				"length": cell_size() * lerpf(20.0, 34.0, volume_hash01("length", region_x, region_z, attempt)),
				"drop": cell_size() * lerpf(2.4, 6.2, volume_hash01("drop", region_x, region_z, attempt)),
				"chamberRadius": cell_size() * lerpf(3.1, 5.2, volume_hash01("chamber", region_x, region_z, attempt)),
				"branchDepth": cell_size() * lerpf(8.0, 17.0, volume_hash01("branch-depth", region_x, region_z, attempt)),
				"branchLength": cell_size() * lerpf(8.0, 16.0, volume_hash01("branch-length", region_x, region_z, attempt)),
				"branchSide": -1.0 if volume_hash01("branch-side", region_x, region_z, attempt) < 0.5 else 1.0
			}
			if not cave_feature_volume_is_contained(candidate):
				continue
			best_score = score
			best = candidate
	if best.is_empty():
		cave_feature_cache[key] = {}
		return {}
	cave_feature_cache[key] = best
	return best

func cave_feature_volume_is_contained(feature: Dictionary) -> bool:
	var entrance_cell: Vector2i = feature.get("entranceCell", Vector2i.ZERO)
	var entrance_biome := surface_biome_for_cell3(Vector3i(entrance_cell.x, 0, entrance_cell.y))
	if entrance_biome in ["ocean", "beach", "swamp", "town"]:
		return false
	var inward_cell: Vector2i = feature.get("inward", Vector2i(0, 1))
	var right_cell: Vector2i = feature.get("right", Vector2i(1, 0))
	var inward := Vector2(float(inward_cell.x), float(inward_cell.y)).normalized()
	var right := Vector2(float(right_cell.x), float(right_cell.y)).normalized()
	var entrance := cell_world2(entrance_cell)
	var radius := float(feature.get("radius", cell_size() * 2.4))
	var length := float(feature.get("length", cell_size() * 24.0))
	var vertical_radius := radius * 0.78
	var depths := [
		cell_size() * 2.0,
		cell_size() * 4.0,
		cell_size() * 7.5,
		minf(length * 0.42, cell_size() * 13.0)
	]
	for depth_value in depths:
		var depth := clampf(float(depth_value), 0.0, length)
		var center2 := entrance + inward * depth
		var center_y := cave_feature_center_y(feature, center2, depth)
		var local_surface := terrain_reference_surface_y_at(Vector3(center2.x, 0.0, center2.y))
		if depth >= cell_size() * 4.0 and local_surface < center_y + vertical_radius + cell_size() * 0.42:
			return false
		if main != null and center_y - vertical_radius < float(main.WATER_LEVEL) + cell_size() * 0.35:
			return false
		for side in [-1.0, 1.0]:
			var side2 := center2 + right * radius * 1.28 * float(side)
			var side_y := center_y + vertical_radius * 0.08
			var side_surface := terrain_reference_surface_y_at(Vector3(side2.x, 0.0, side2.y))
			if side_surface < side_y + cell_size() * 0.32:
				return false
			var side_pos := Vector3(side2.x, side_y, side2.y)
			if cave_feature_air_value(feature, side_pos) < 0.0:
				return false
	return true

func cave_feature_air_value(feature: Dictionary, world_pos: Vector3) -> float:
	if feature.is_empty():
		return INF
	var point := Vector2(world_pos.x, world_pos.z)
	var entrance_cell: Vector2i = feature.get("entranceCell", Vector2i.ZERO)
	var inward_cell: Vector2i = feature.get("inward", Vector2i(0, 1))
	var right_cell: Vector2i = feature.get("right", Vector2i(1, 0))
	var inward := Vector2(float(inward_cell.x), float(inward_cell.y)).normalized()
	var right := Vector2(float(right_cell.x), float(right_cell.y)).normalized()
	var entrance := cell_world2(entrance_cell)
	var delta := point - entrance
	var depth := delta.dot(inward)
	var lateral := delta.dot(right)
	var length := float(feature.get("length", cell_size() * 24.0))
	var radius := cave_feature_radius_at_depth(feature, depth)
	var clamped_depth := clampf(depth, 0.0, length)
	var center2 := entrance + inward * clamped_depth
	var center_y := cave_feature_center_y(feature, center2, clamped_depth)
	var tube := cave_ellipsoid_value(world_pos, center2, center_y, radius, radius * 0.78)
	var front_cap := maxf(0.0, (-radius * 1.15 - depth) / maxf(0.001, radius))
	var back_cap := maxf(0.0, (depth - length) / maxf(0.001, radius))
	var best := maxf(tube, maxf(front_cap, back_cap)) - 1.0
	var chamber_center2 := entrance + inward * length
	var chamber_y := cave_feature_center_y(feature, chamber_center2, length) - radius * 0.10
	var chamber_radius := float(feature.get("chamberRadius", radius * 1.8))
	best = minf(best, cave_ellipsoid_value(world_pos, chamber_center2, chamber_y, chamber_radius, chamber_radius * 0.58) - 1.0)
	best = minf(best, cave_branch_air_value(feature, world_pos, entrance, inward, right))
	return best

func cave_branch_air_value(feature: Dictionary, world_pos: Vector3, entrance: Vector2, inward: Vector2, right: Vector2) -> float:
	var branch_depth := float(feature.get("branchDepth", cell_size() * 12.0))
	var branch_length := float(feature.get("branchLength", cell_size() * 10.0))
	var branch_side := float(feature.get("branchSide", 1.0))
	var branch_dir := (inward * 0.34 + right * branch_side).normalized()
	var branch_origin := entrance + inward * branch_depth
	var point := Vector2(world_pos.x, world_pos.z)
	var delta := point - branch_origin
	var depth := delta.dot(branch_dir)
	var lateral := absf(delta.cross(branch_dir))
	var radius := float(feature.get("radius", cell_size() * 2.0)) * 0.78
	var clamped_depth := clampf(depth, 0.0, branch_length)
	var center2 := branch_origin + branch_dir * clamped_depth
	var center_y := cave_feature_center_y(feature, center2, branch_depth + clamped_depth) - radius * 0.12
	var tube := sqrt(pow(lateral / maxf(0.001, radius), 2.0) + pow(absf(world_pos.y - center_y) / maxf(0.001, radius * 0.70), 2.0))
	var front_cap := maxf(0.0, (-radius - depth) / maxf(0.001, radius))
	var back_cap := maxf(0.0, (depth - branch_length) / maxf(0.001, radius))
	return maxf(tube, maxf(front_cap, back_cap)) - 1.0

func cave_feature_radius_at_depth(feature: Dictionary, depth: float) -> float:
	var radius := float(feature.get("radius", cell_size() * 2.0))
	var length := float(feature.get("length", cell_size() * 24.0))
	var t := clampf(depth / maxf(0.001, length), 0.0, 1.0)
	var swell := sin(t * PI) * radius * 0.18
	var entrance_blend := smoothstep(-radius * 1.15, radius * 2.5, depth)
	return maxf(cell_size() * 1.10, (radius + swell) * lerpf(0.72, 1.0, entrance_blend))

func cave_feature_center_y(feature: Dictionary, center2: Vector2, depth: float) -> float:
	var entrance_surface := float(feature.get("entranceSurfaceY", 0.0))
	var radius := float(feature.get("radius", cell_size() * 2.0))
	var length := float(feature.get("length", cell_size() * 24.0))
	var drop := float(feature.get("drop", cell_size() * 4.0))
	var t := clampf(depth / maxf(0.001, length), 0.0, 1.0)
	var nominal := entrance_surface + radius * 0.10 - smoothstep(0.0, 1.0, t) * drop
	var cover := lerpf(radius * 0.10, radius * 1.20, smoothstep(0.0, cell_size() * 8.0, depth))
	var local_surface := terrain_reference_surface_y_at(Vector3(center2.x, 0.0, center2.y))
	return minf(nominal, local_surface - cover)

func cave_ellipsoid_value(world_pos: Vector3, center2: Vector2, center_y: float, horizontal_radius: float, vertical_radius: float) -> float:
	var horizontal := Vector2(world_pos.x, world_pos.z).distance_to(center2) / maxf(0.001, horizontal_radius)
	var vertical := absf(world_pos.y - center_y) / maxf(0.001, vertical_radius)
	return sqrt(horizontal * horizontal + vertical * vertical)

func find_cave_biome_sample(search_radius_regions := 8) -> Dictionary:
	for radius in range(0, search_radius_regions + 1):
		for rz in range(-radius, radius + 1):
			for rx in range(-radius, radius + 1):
				if radius > 0 and absi(rx) != radius and absi(rz) != radius:
					continue
				var feature := cave_feature_for_region(rx, rz)
				if feature.is_empty():
					continue
				var entrance: Vector2i = feature.get("entranceCell", Vector2i.ZERO)
				var inward_cell: Vector2i = feature.get("inward", Vector2i(0, 1))
				var inward := Vector2(float(inward_cell.x), float(inward_cell.y)).normalized()
				var depth := cell_size() * 6.0
				var center2 := cell_world2(entrance) + inward * depth
				var center_y := cave_feature_center_y(feature, center2, depth)
				var position := Vector3(center2.x, center_y, center2.y)
				if biome_at(position) == "cave":
					return {
						"id": String(feature.get("id", "")),
						"region": feature.get("region", Vector2i.ZERO),
						"entranceCell": entrance,
						"position": position,
						"sample": sample_world(position),
						"feature": feature.duplicate(true)
					}
	return {}

func volume_hash01(salt: String, x: int, z: int, index: int) -> float:
	var text := "volume-cave:%s:%d,%d:%d" % [salt, x, z, index]
	if main != null and main.has_method("hash01"):
		return float(main.call("hash01", text))
	var h := hash(text)
	return float(abs(h) % 100000) / 100000.0

func town_region_at_cell3(cell: Vector3i) -> Dictionary:
	if main == null:
		return {}
	var region_x := floori(float(cell.x) / float(main.TOWN_REGION_CELLS))
	var region_z := floori(float(cell.z) / float(main.TOWN_REGION_CELLS))
	for rz in range(region_z - 1, region_z + 2):
		for rx in range(region_x - 1, region_x + 2):
			var town: Dictionary = main.town_region(rx, rz)
			if town.is_empty():
				continue
			var distance := Vector2(float(cell.x - int(town["centerX"])), float(cell.z - int(town["centerZ"]))).length()
			if distance <= float(town["radius"]):
				return town
	return {}

func town_region_for_surface_cell3(cell: Vector3i) -> Dictionary:
	if main == null:
		return {}
	var region_x := floori(float(cell.x) / float(main.TOWN_REGION_CELLS))
	var region_z := floori(float(cell.z) / float(main.TOWN_REGION_CELLS))
	var best_town := {}
	var best_distance := INF
	for rz in range(region_z - 1, region_z + 2):
		for rx in range(region_x - 1, region_x + 2):
			var town: Dictionary = main.town_region(rx, rz)
			if town.is_empty():
				continue
			var distance := Vector2(float(cell.x - int(town["centerX"])), float(cell.z - int(town["centerZ"]))).length()
			var max_distance := float(town["radius"]) + float(town_slope_apron_cells(town))
			if distance <= max_distance and distance < best_distance:
				best_town = town
				best_distance = distance
	return best_town

func town_slope_apron_cells(town: Dictionary) -> int:
	if main == null:
		return 18
	var cache_value = main.get("town_slope_apron_cache")
	var cache: Dictionary = cache_value if cache_value is Dictionary else {}
	var key := Vector2i(int(town.get("regionX", 0)), int(town.get("regionZ", 0)))
	if cache.has(key):
		return int(cache[key])
	var radius: int = int(town.get("radius", main.TOWN_RADIUS_CELLS))
	var center_x: int = int(town.get("centerX", 0))
	var center_z: int = int(town.get("centerZ", 0))
	var level: float = float(town.get("level", float(main.WATER_LEVEL) + 3.0))
	var apron: int = maxi(18, ceili(float(radius) * 0.55))
	var max_apron: int = maxi(apron, int(float(main.TOWN_REGION_CELLS) * 0.5) - radius - 6)
	var sample_dirs: Array[Vector2] = [
		Vector2(1.0, 0.0),
		Vector2(-1.0, 0.0),
		Vector2(0.0, 1.0),
		Vector2(0.0, -1.0),
		Vector2(1.0, 1.0).normalized(),
		Vector2(-1.0, 1.0).normalized(),
		Vector2(1.0, -1.0).normalized(),
		Vector2(-1.0, -1.0).normalized()
	]
	for _pass in range(3):
		var max_diff: float = 0.0
		var sample_distance: float = float(radius + apron)
		for direction in sample_dirs:
			var sample_x: int = center_x + roundi(direction.x * sample_distance)
			var sample_z: int = center_z + roundi(direction.y * sample_distance)
			max_diff = maxf(max_diff, absf(natural_surface_y_for_cell(Vector3i(sample_x, 0, sample_z)) - level))
		var needed: int = ceili(max_diff / maxf(0.01, cell_size() * 0.72)) + 4
		var next_apron: int = mini(max_apron, maxi(apron, needed))
		if next_apron == apron:
			break
		apron = next_apron
	cache[key] = apron
	return apron

func top_material_for_biome(biome: String) -> String:
	if biome == "beach" or biome == "desert":
		return "sand"
	if biome == "swamp":
		return "mud"
	if biome == "snow":
		return "snow"
	if biome == "alpine" or biome == "tundra":
		return "stone"
	return "grass"

func subsoil_material_for_biome(biome: String) -> String:
	if biome == "beach" or biome == "desert":
		return "sand"
	if biome == "swamp":
		return "mud"
	if biome == "snow":
		return "snow"
	return "dirt"

func ore_material_at(cell: Vector3i, depth: float) -> String:
	if main == null:
		return ""
	var depth_cells := depth / maxf(0.001, cell_size())
	var copper_noise: float = float(main.hash01("subsurface-copper:%s:%d,%d,%d" % [String(main.get("seed_text")), cell.x / 3, cell.y / 3, cell.z / 3]))
	if depth_cells >= 8.0 and copper_noise > 0.985:
		return "copperOre"
	var iron_noise: float = float(main.hash01("subsurface-iron:%s:%d,%d,%d" % [String(main.get("seed_text")), cell.x / 4, cell.y / 4, cell.z / 4]))
	if depth_cells >= 15.0 and iron_noise > 0.992:
		return "ironOre"
	return ""

func surface_color_for_cell3(cell: Vector3i) -> Color:
	var biome := surface_biome_for_cell3(cell)
	if biome == "beach" or biome == "desert":
		return Color(0.62, 0.57, 0.42)
	if biome == "swamp":
		return Color(0.30, 0.38, 0.29)
	if biome == "snow":
		return Color(0.77, 0.82, 0.82)
	if biome == "alpine" or biome == "tundra":
		return Color(0.38, 0.41, 0.39)
	if biome == "cave":
		return Color(0.20, 0.22, 0.21)
	return Color(0.37, 0.47, 0.34)

func world_to_cell3(position: Vector3) -> Vector3i:
	var s := cell_size()
	return Vector3i(roundi(position.x / s), roundi(position.y / s), roundi(position.z / s))

func merged_excavation_brushes(extra_excavation_brushes) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for brush in excavation_brushes:
		result.append(brush)
	if extra_excavation_brushes is Array:
		for value in extra_excavation_brushes:
			if value is Dictionary:
				result.append(value)
	return result

func cell_world2(cell: Vector2i) -> Vector2:
	return Vector2(float(cell.x) * cell_size(), float(cell.y) * cell_size())

func cell_size() -> float:
	return float(main.CELL) if main != null else 1.35
