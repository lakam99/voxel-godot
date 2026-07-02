extends RefCounted
class_name WorldGenerationSystem

const CAVE_AIR_THRESHOLD := 1.0

var main
var cave_plan_records := {}
var excavation_brushes: Array[Dictionary] = []
var cave_graph_profile_cache := {}

func setup(main_node) -> void:
	main = main_node

func reset() -> void:
	cave_plan_records.clear()
	excavation_brushes.clear()
	cave_graph_profile_cache.clear()

func reset_for_seed() -> void:
	cave_plan_records.clear()
	excavation_brushes.clear()
	cave_graph_profile_cache.clear()

func register_cave_plan(plan: Dictionary, metadata: Dictionary = {}) -> void:
	if plan.is_empty():
		return
	var cave_id := String(plan.get("id", "cave"))
	cave_graph_profile_cache.erase(cave_id)
	cave_plan_records[cave_id] = {
		"plan": plan.duplicate(true),
		"metadata": metadata.duplicate(true)
	}

func unregister_cave(cave_id: String) -> void:
	cave_plan_records.erase(cave_id)
	cave_graph_profile_cache.erase(cave_id)

func register_excavation_brush(brush: Dictionary) -> void:
	var brush_id := String(brush.get("id", ""))
	if brush_id == "":
		return
	for index in range(excavation_brushes.size()):
		if String(excavation_brushes[index].get("id", "")) == brush_id:
			excavation_brushes[index] = brush.duplicate(true)
			return
	excavation_brushes.append(brush.duplicate(true))

func clear_excavation_brushes() -> void:
	excavation_brushes.clear()

func surface_height_for_cell3(cell: Vector3i, active_plan_records = null) -> float:
	var base := edited_surface_height_for_cell3(cell)
	var point := Vector2(float(cell.x) * cell_size(), float(cell.z) * cell_size())
	var overlay := 0.0
	for plan in active_plans_from_records(active_plan_records):
		overlay = maxf(overlay, cave_mound_overlay(plan, point))
	return base + overlay

func edited_surface_height_for_cell3(cell: Vector3i) -> float:
	var edits_value = main.get("height_edits") if main != null else {}
	if edits_value is Dictionary:
		var edits: Dictionary = edits_value
		var key := Vector2i(cell.x, cell.z)
		if edits.has(key):
			return float(edits[key])
	return base_surface_height_for_cell3(cell)

func base_surface_height_for_cell3(cell: Vector3i) -> float:
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
		var natural := natural_surface_height_for_cell3(cell)
		var blend := clampf((distance - radius) / maxf(1.0, apron), 0.0, 1.0)
		var eased := blend * blend * (3.0 - 2.0 * blend)
		return lerp(level, natural, eased)
	return natural_surface_height_for_cell3(cell)

func natural_surface_height_for_cell3(cell: Vector3i) -> float:
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
	var h: float = surface_height_for_cell3(cell)
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

func biome_at_cell3(cell: Vector3i) -> String:
	var world_pos := Vector3(float(cell.x) * cell_size(), float(cell.y) * cell_size(), float(cell.z) * cell_size())
	if cave_air_value_at_world_from_records(world_pos) <= CAVE_AIR_THRESHOLD:
		return "cave"
	return surface_biome_for_cell3(cell)

func biome_at_world(world_pos: Vector3) -> String:
	if cave_air_value_at_world_from_records(world_pos) <= CAVE_AIR_THRESHOLD:
		return "cave"
	return surface_biome_for_cell3(world_to_cell3(world_pos))

func material_at_cell3(cell: Vector3i) -> String:
	var world_pos := Vector3(float(cell.x) * cell_size(), float(cell.y) * cell_size(), float(cell.z) * cell_size())
	if not solid_at_world(world_pos):
		return "air"
	var surface_y := surface_height_for_cell3(Vector3i(cell.x, 0, cell.z))
	var depth := maxf(0.0, surface_y - world_pos.y)
	var biome := surface_biome_for_cell3(cell)
	if depth <= cell_size() * 1.20:
		return top_material_for_biome(biome)
	if depth <= cell_size() * 4.65:
		return subsoil_material_for_biome(biome)
	var ore := ore_material_at(cell, depth)
	if ore != "":
		return ore
	return "stone"

func solid_at_world(world_pos: Vector3, active_plan_records = null, extra_excavation_brushes := []) -> bool:
	var surface_y := surface_height_at_world(world_pos.x, world_pos.z, active_plan_records)
	if world_pos.y > surface_y:
		return false
	if cave_air_value_at_world_from_records(world_pos, active_plan_records) <= CAVE_AIR_THRESHOLD:
		return false
	for brush in merged_excavation_brushes(extra_excavation_brushes):
		var center: Vector3 = brush.get("center", Vector3.ZERO)
		var radius := float(brush.get("radius", 0.0))
		if radius > 0.0 and center.distance_to(world_pos) <= radius:
			return false
	return true

func solid_at_world_for_plan(plan: Dictionary, world_pos: Vector3, extra_excavation_brushes := []) -> bool:
	var surface_y := surface_height_for_plan_point(plan, Vector2(world_pos.x, world_pos.z))
	if world_pos.y > surface_y:
		return false
	if cave_contains_world(plan, world_pos):
		return false
	for brush_value in extra_excavation_brushes:
		if not (brush_value is Dictionary):
			continue
		var brush: Dictionary = brush_value
		var center: Vector3 = brush.get("center", Vector3.ZERO)
		var radius := float(brush.get("radius", 0.0))
		if radius > 0.0 and center.distance_to(world_pos) <= radius:
			return false
	return true

func is_air_at_world(world_pos: Vector3, active_plan_records = null, extra_excavation_brushes := []) -> bool:
	if world_pos.y > surface_height_at_world(world_pos.x, world_pos.z, active_plan_records) + cell_size() * 0.12:
		return true
	for brush_value in merged_excavation_brushes(extra_excavation_brushes):
		if not (brush_value is Dictionary):
			continue
		var brush: Dictionary = brush_value
		var center: Vector3 = brush.get("center", Vector3.ZERO)
		var radius := float(brush.get("radius", 0.0))
		if radius > 0.0 and center.distance_to(world_pos) <= radius:
			return true
	for plan in active_plans_from_records(active_plan_records):
		if cave_contains_world(plan, world_pos):
			return true
	return false

func cave_air_value_at_world_from_records(world_pos: Vector3, active_plan_records = null) -> float:
	var best := INF
	for plan in active_plans_from_records(active_plan_records):
		best = minf(best, cave_air_value_at_world(plan, world_pos))
	return best

func cave_contains_world(plan: Dictionary, world_pos: Vector3) -> bool:
	return cave_air_value_at_world(plan, world_pos) <= CAVE_AIR_THRESHOLD

func cave_air_value_at_world(plan: Dictionary, world_pos: Vector3) -> float:
	if plan.is_empty():
		return INF
	var point := Vector2(world_pos.x, world_pos.z)
	var surface_y := surface_height_for_plan_point(plan, point)
	if world_pos.y > surface_y + cell_size() * 0.08:
		return INF
	var best := cave_mouth_air_value_at_world(plan, world_pos)
	best = minf(best, cave_graph_air_value_at_world(plan, world_pos))
	return best

func cave_mouth_air_value_at_world(plan: Dictionary, world_pos: Vector3) -> float:
	var point := Vector2(world_pos.x, world_pos.z)
	var axes := cave_mouth_depth_lateral(plan, point)
	var depth_cells := axes.x
	var width := cave_mouth_width_at_depth(plan, depth_cells)
	if width <= 0.0:
		return INF
	var floor_y := cave_floor_y_at_surface(plan, point, float(plan.get("level", 0.0)))
	var arch_height := float(plan.get("entranceMouthArchHeight", clampf(width * cell_size() * 0.98, cell_size() * 2.05, cell_size() * 4.2)))
	if world_pos.y < floor_y - cell_size() * 0.06:
		return INF
	var lateral_t := absf(axes.y) / maxf(0.001, width)
	var vertical_t := (world_pos.y - floor_y) / maxf(cell_size() * 0.58, arch_height)
	var semicircle := sqrt(lateral_t * lateral_t + vertical_t * vertical_t)
	var interior_depth := float(maxi(1, int(plan.get("entranceOpenDepth", 7))))
	var front_cap := maxf(0.0, (cave_mouth_front_depth(plan) - depth_cells) / 0.85)
	var back_cap := maxf(0.0, (depth_cells - (interior_depth + 1.75)) / 1.0)
	return maxf(maxf(semicircle, front_cap), back_cap)

func cave_graph_air_value_at_world(plan: Dictionary, world_pos: Vector3) -> float:
	var profiles := cave_graph_profiles_for_point(plan, Vector2(world_pos.x, world_pos.z))
	if profiles.is_empty():
		return INF
	var best := INF
	var point := Vector2(world_pos.x, world_pos.z)
	for profile_value in profiles:
		if not (profile_value is Dictionary):
			continue
		var profile: Dictionary = profile_value
		var center2: Vector2 = profile.get("center", Vector2.ZERO)
		var radius := float(profile.get("radius", cell_size() * 2.0))
		var half_height := float(profile.get("halfHeight", cell_size()))
		var center_y := float(profile.get("centerY", 0.0))
		var horizontal_value := center2.distance_to(point) / maxf(0.001, radius)
		var vertical_value := absf(world_pos.y - center_y) / maxf(0.001, half_height)
		best = minf(best, maxf(horizontal_value, vertical_value))
	return best

func cave_graph_air_value_at_world_bruteforce(plan: Dictionary, world_pos: Vector3) -> float:
	var best := INF
	var point := Vector2(world_pos.x, world_pos.z)
	for edge_value in plan.get("caveEdges", []):
		if not (edge_value is Dictionary):
			continue
		var edge: Dictionary = edge_value
		var radius := float(edge.get("radius", 1.6)) * cell_size()
		var edge_id := String(edge.get("id", "edge"))
		var edge_noise := 0.92 + stable01(plan, "edge-radius:%s" % edge_id, 0, 0) * 0.18
		for cell_value in edge.get("centerCells", []):
			if not (cell_value is Vector2i):
				continue
			var center2 := cell_world2(cell_value)
			var floor_y := cave_floor_y_at_surface(plan, center2, float(plan.get("level", 0.0)))
			var ceiling_y := cave_ceiling_y_at_surface(plan, center2, floor_y + cell_size() * 3.0)
			var half_height := maxf(cell_size() * 0.72, (ceiling_y - floor_y) * 0.5)
			var center_y := (floor_y + ceiling_y) * 0.5
			var horizontal_value := center2.distance_to(point) / maxf(0.001, radius * edge_noise)
			var vertical_value := absf(world_pos.y - center_y) / half_height
			best = minf(best, maxf(horizontal_value, vertical_value))
	for node_value in plan.get("caveNodes", []):
		if not (node_value is Dictionary):
			continue
		var node: Dictionary = node_value
		var center2 := cell_world2(node.get("cell", Vector2i.ZERO))
		var radius := float(node.get("radius", 2.0)) * cell_size()
		var kind := String(node.get("kind", ""))
		if kind == "entrance":
			radius *= 0.88
		else:
			radius *= 1.04 + stable01(plan, "node-radius:%s" % String(node.get("id", "")), 0, 0) * 0.18
		var floor_y := cave_floor_y_at_surface(plan, center2, float(plan.get("level", 0.0)))
		var ceiling_y := cave_ceiling_y_at_surface(plan, center2, floor_y + cell_size() * 3.0)
		var half_height := maxf(cell_size() * 0.85, (ceiling_y - floor_y) * 0.5)
		var center_y := (floor_y + ceiling_y) * 0.5
		var horizontal_value := center2.distance_to(point) / maxf(0.001, radius)
		var vertical_value := absf(world_pos.y - center_y) / half_height
		best = minf(best, maxf(horizontal_value, vertical_value))
	return best

func cave_point_is_inside(plan: Dictionary, point: Vector2) -> bool:
	return cave_column_has_air(plan, point)

func cave_column_has_air(plan: Dictionary, point: Vector2) -> bool:
	if plan.is_empty():
		return false
	var floor_y := cave_floor_y_at_surface(plan, point, float(plan.get("level", 0.0)))
	var ceiling_y := cave_ceiling_y_at_surface(plan, point, floor_y + cell_size() * 3.0)
	if ceiling_y <= floor_y:
		return false
	var samples := [
		floor_y + cell_size() * 0.18,
		lerpf(floor_y, ceiling_y, 0.38),
		lerpf(floor_y, ceiling_y, 0.62),
		ceiling_y - cell_size() * 0.18
	]
	for y in samples:
		if cave_contains_world(plan, Vector3(point.x, y, point.y)):
			return true
	return false

func cave_volume_value(plan: Dictionary, sample) -> float:
	if sample is Vector3:
		return cave_air_value_at_world(plan, sample)
	if sample is Vector2:
		return cave_planar_value_at_point(plan, sample)
	return INF

func cave_planar_value_at_point(plan: Dictionary, point: Vector2) -> float:
	if plan.is_empty():
		return INF
	var best := cave_mouth_planar_value(plan, point)
	best = minf(best, cave_graph_planar_value(plan, point))
	return best

func cave_graph_planar_value(plan: Dictionary, point: Vector2) -> float:
	var profiles := cave_graph_profiles_for_point(plan, point)
	if profiles.is_empty():
		return INF
	var best := INF
	for profile_value in profiles:
		if not (profile_value is Dictionary):
			continue
		var profile: Dictionary = profile_value
		var center: Vector2 = profile.get("center", Vector2.ZERO)
		var radius := float(profile.get("radius", cell_size() * 2.0))
		best = minf(best, center.distance_to(point) / maxf(0.001, radius))
	return best

func cave_graph_planar_value_bruteforce(plan: Dictionary, point: Vector2) -> float:
	var best := INF
	for edge_value in plan.get("caveEdges", []):
		if not (edge_value is Dictionary):
			continue
		var edge: Dictionary = edge_value
		var radius := float(edge.get("radius", 1.6)) * cell_size()
		var edge_id := String(edge.get("id", "edge"))
		var edge_noise := 0.92 + stable01(plan, "edge-radius:%s" % edge_id, 0, 0) * 0.18
		for cell_value in edge.get("centerCells", []):
			if not (cell_value is Vector2i):
				continue
			var center := cell_world2(cell_value)
			best = minf(best, center.distance_to(point) / maxf(0.001, radius * edge_noise))
	for node_value in plan.get("caveNodes", []):
		if not (node_value is Dictionary):
			continue
		var node: Dictionary = node_value
		var center := cell_world2(node.get("cell", Vector2i.ZERO))
		var radius := float(node.get("radius", 2.0)) * cell_size()
		var kind := String(node.get("kind", ""))
		if kind == "entrance":
			radius *= 0.88
		else:
			radius *= 1.04 + stable01(plan, "node-radius:%s" % String(node.get("id", "")), 0, 0) * 0.18
		best = minf(best, center.distance_to(point) / maxf(0.001, radius))
	return best

func cave_graph_profiles_for_point(plan: Dictionary, point: Vector2) -> Array:
	var grid := cave_graph_profile_grid(plan)
	if grid.is_empty():
		return []
	var key := Vector2i(roundi(point.x / cell_size()), roundi(point.y / cell_size()))
	var search_radius := int(grid.get("_maxRadiusCells", 8))
	var result := []
	for dz in range(-search_radius, search_radius + 1):
		for dx in range(-search_radius, search_radius + 1):
			var profiles = grid.get(key + Vector2i(dx, dz), [])
			if profiles is Array:
				result.append_array(profiles)
	return result

func cave_graph_profile_grid(plan: Dictionary) -> Dictionary:
	var cave_id := String(plan.get("id", "cave"))
	if cave_graph_profile_cache.has(cave_id):
		var cached = cave_graph_profile_cache[cave_id]
		return cached if cached is Dictionary else {}
	var grid := {}
	var s := cell_size()
	for edge_value in plan.get("caveEdges", []):
		if not (edge_value is Dictionary):
			continue
		var edge: Dictionary = edge_value
		var edge_id := String(edge.get("id", "edge"))
		var radius := float(edge.get("radius", 1.6)) * s
		var edge_noise := 0.92 + stable01(plan, "edge-radius:%s" % edge_id, 0, 0) * 0.18
		radius *= edge_noise
		for cell_value in edge.get("centerCells", []):
			if not (cell_value is Vector2i):
				continue
			var center_cell: Vector2i = cell_value
			var center2 := cell_world2(center_cell)
			var floor_y := cave_floor_y_at_surface(plan, center2, float(plan.get("level", 0.0)))
			var ceiling_y := cave_profile_ceiling_y(plan, center2, floor_y)
			add_cave_graph_profile(grid, center_cell, {
				"center": center2,
				"radius": radius,
				"halfHeight": maxf(s * 0.72, (ceiling_y - floor_y) * 0.5),
				"centerY": (floor_y + ceiling_y) * 0.5
			})
	for node_value in plan.get("caveNodes", []):
		if not (node_value is Dictionary):
			continue
		var node: Dictionary = node_value
		var center_cell: Vector2i = node.get("cell", Vector2i.ZERO)
		var center2 := cell_world2(center_cell)
		var radius := float(node.get("radius", 2.0)) * s
		var kind := String(node.get("kind", ""))
		if kind == "entrance":
			radius *= 0.88
		else:
			radius *= 1.04 + stable01(plan, "node-radius:%s" % String(node.get("id", "")), 0, 0) * 0.18
		var floor_y := cave_floor_y_at_surface(plan, center2, float(plan.get("level", 0.0)))
		var ceiling_y := cave_profile_ceiling_y(plan, center2, floor_y)
		add_cave_graph_profile(grid, center_cell, {
			"center": center2,
			"radius": radius,
			"halfHeight": maxf(s * 0.85, (ceiling_y - floor_y) * 0.5),
			"centerY": (floor_y + ceiling_y) * 0.5
		})
	cave_graph_profile_cache[cave_id] = grid
	return grid

func add_cave_graph_profile(grid: Dictionary, center_cell: Vector2i, profile: Dictionary) -> void:
	var radius_cells := ceili(float(profile.get("radius", cell_size() * 2.0)) / cell_size() * 1.35) + 2
	grid["_maxRadiusCells"] = maxi(int(grid.get("_maxRadiusCells", 0)), radius_cells)
	if not grid.has(center_cell):
		grid[center_cell] = []
	(grid[center_cell] as Array).append(profile)

func cave_mouth_volume_value(plan: Dictionary, point: Vector2) -> float:
	return cave_mouth_planar_value(plan, point)

func cave_mouth_planar_value(plan: Dictionary, point: Vector2) -> float:
	var axes := cave_mouth_depth_lateral(plan, point)
	var depth_cells := axes.x
	var width := cave_mouth_width_at_depth(plan, depth_cells)
	if width <= 0.0:
		return INF
	var lateral_value := absf(axes.y) / maxf(0.001, width)
	var interior_depth := float(maxi(1, int(plan.get("entranceOpenDepth", 7))))
	var front_cap := maxf(0.0, (cave_mouth_front_depth(plan) - depth_cells) / 0.85)
	var back_cap := maxf(0.0, (depth_cells - (interior_depth + 1.75)) / 1.0)
	return maxf(maxf(lateral_value, front_cap), back_cap)

func cave_mouth_depth_lateral(plan: Dictionary, point: Vector2) -> Vector2:
	var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
	var inward_cell: Vector2i = plan.get("inward", Vector2i(0, 1))
	var right_cell: Vector2i = plan.get("right", Vector2i(1, 0))
	var inward := Vector2(float(inward_cell.x), float(inward_cell.y))
	var right := Vector2(float(right_cell.x), float(right_cell.y))
	if inward.length() <= 0.01:
		inward = Vector2(0.0, 1.0)
	if right.length() <= 0.01:
		right = Vector2(1.0, 0.0)
	inward = inward.normalized()
	right = right.normalized()
	var delta := (point - cell_world2(entrance)) / cell_size()
	return Vector2(delta.dot(inward), delta.dot(right))

func cave_mouth_width_at_depth(plan: Dictionary, depth_cells: float) -> float:
	var interior_depth := float(maxi(1, int(plan.get("entranceOpenDepth", 7))))
	var mouth_width := maxf(1.35, float(plan.get("entranceMouthHalfWidth", 3.85)))
	var front_depth := cave_mouth_front_depth(plan)
	if depth_cells < front_depth or depth_cells > interior_depth + 1.75:
		return 0.0
	if depth_cells <= 0.0:
		var front_t := smoothstep(front_depth, 0.0, depth_cells)
		return lerpf(mouth_width * 0.86, mouth_width, front_t)
	if depth_cells <= 2.0:
		return mouth_width
	var taper_t := smoothstep(2.0, interior_depth + 1.75, depth_cells)
	return lerpf(mouth_width, cave_mouth_inner_half_width(mouth_width), taper_t)

func cave_mouth_front_depth(plan: Dictionary) -> float:
	var approach_depth := float(maxi(2, int(plan.get("entranceApproachDepth", 4))))
	return -minf(4.25, maxf(2.25, approach_depth))

func cave_mouth_inner_half_width(mouth_width: float) -> float:
	return clampf(mouth_width * 0.68, 1.35, mouth_width)

func cave_floor_point(plan: Dictionary, point: Vector2) -> Vector3:
	return Vector3(point.x, cave_floor_y_at_surface(plan, point, float(plan.get("level", 0.0))), point.y)

func cave_ceiling_point(plan: Dictionary, point: Vector2) -> Vector3:
	return Vector3(point.x, cave_ceiling_y_at_surface(plan, point, float(plan.get("ceilingLevel", float(plan.get("level", 0.0)) + cell_size() * 3.0))), point.y)

func cave_floor_y_at_surface(plan: Dictionary, point: Vector2, fallback_level: float) -> float:
	var base_floor := float(plan.get("level", fallback_level)) + 0.10
	var axes := cave_mouth_depth_lateral(plan, point)
	var path_length := maxf(1.0, float(plan.get("pathLength", 16)))
	var progress := clampf(axes.x / path_length, 0.0, 1.0)
	var available_drop := maxf(0.0, base_floor - (float(main.WATER_LEVEL) + cell_size() * 1.55)) if main != null else 0.0
	var max_drop := minf(cell_size() * 2.4, available_drop * 0.62)
	var route_drop := smoothstep(0.08, 1.0, progress) * max_drop
	var variation_scale := smoothstep(2.0, 7.0, axes.x)
	var wave := stable_signed(plan, "floor-wave", floori(point.x / cell_size()), floori(point.y / cell_size())) * cell_size() * 0.10 * variation_scale
	var mouth_floor := float(plan.get("mouthFloorLevel", base_floor))
	var mouth_blend := 1.0 - smoothstep(0.0, 3.0, axes.x)
	if axes.x < 0.0 and cave_mouth_width_at_depth(plan, axes.x) > 0.0:
		mouth_blend = 1.0
	var floor_y := base_floor - route_drop + wave
	return lerpf(floor_y, mouth_floor, clampf(mouth_blend, 0.0, 1.0))

func cave_ceiling_y_at_surface(plan: Dictionary, point: Vector2, fallback_level: float) -> float:
	var floor_y := cave_floor_y_at_surface(plan, point, float(plan.get("level", 0.0)))
	var axes := cave_mouth_depth_lateral(plan, point)
	var surface_y := surface_height_for_plan_point(plan, point)
	var width := cave_mouth_width_at_depth(plan, axes.x)
	if width > 0.0 and axes.x <= float(plan.get("entranceOpenDepth", 7)) + 1.5:
		var lateral_t := clampf(absf(axes.y) / maxf(0.001, width), 0.0, 1.0)
		var arch := sqrt(maxf(0.0, 1.0 - lateral_t * lateral_t))
		var arch_height := float(plan.get("entranceMouthArchHeight", clampf(width * cell_size() * 0.98, cell_size() * 2.05, cell_size() * 4.2)))
		var mouth_ceiling := floor_y + maxf(cell_size() * 0.58, arch_height * arch)
		var interior_ceiling := minf(surface_y - cell_size() * 0.70, floor_y + cell_size() * 2.90)
		var blend := 1.0 - smoothstep(2.5, float(plan.get("entranceOpenDepth", 7)) + 1.5, axes.x)
		return minf(surface_y - cell_size() * 0.28, lerpf(interior_ceiling, mouth_ceiling, clampf(blend, 0.0, 1.0)))
	var base_ceiling := float(plan.get("ceilingLevel", fallback_level))
	var dome := maxf(0.0, 1.0 - cave_planar_value_at_point(plan, point)) * cell_size() * 0.35
	var wave := stable_signed(plan, "ceiling-wave", floori(point.x / cell_size()), floori(point.y / cell_size())) * cell_size() * 0.14
	return minf(surface_y - cell_size() * 0.72, maxf(floor_y + cell_size() * 2.15, base_ceiling + dome + wave))

func cave_profile_ceiling_y(plan: Dictionary, point: Vector2, floor_y: float) -> float:
	var surface_y := surface_height_for_plan_point(plan, point)
	var base_ceiling := float(plan.get("ceilingLevel", floor_y + cell_size() * 2.8))
	var axes := cave_mouth_depth_lateral(plan, point)
	var width := cave_mouth_width_at_depth(plan, axes.x)
	if width > 0.0 and axes.x <= float(plan.get("entranceOpenDepth", 7)) + 1.5:
		var lateral_t := clampf(absf(axes.y) / maxf(0.001, width), 0.0, 1.0)
		var arch := sqrt(maxf(0.0, 1.0 - lateral_t * lateral_t))
		var arch_height := float(plan.get("entranceMouthArchHeight", clampf(width * cell_size() * 0.98, cell_size() * 2.05, cell_size() * 4.2)))
		var mouth_ceiling := floor_y + maxf(cell_size() * 0.58, arch_height * arch)
		var interior_ceiling := minf(surface_y - cell_size() * 0.70, floor_y + cell_size() * 2.90)
		var blend := 1.0 - smoothstep(2.5, float(plan.get("entranceOpenDepth", 7)) + 1.5, axes.x)
		return minf(surface_y - cell_size() * 0.28, lerpf(interior_ceiling, mouth_ceiling, clampf(blend, 0.0, 1.0)))
	return minf(surface_y - cell_size() * 0.72, maxf(floor_y + cell_size() * 2.15, base_ceiling))

func surface_height_at_world(x: float, z: float, active_plan_records = null) -> float:
	return surface_height_for_cell(roundi(x / cell_size()), roundi(z / cell_size()), active_plan_records)

func surface_height_for_cell(x: int, z: int, active_plan_records = null) -> float:
	return surface_height_for_cell3(Vector3i(x, 0, z), active_plan_records)

func surface_height_for_plan_point(plan: Dictionary, point: Vector2) -> float:
	var cell_x := roundi(point.x / cell_size())
	var cell_z := roundi(point.y / cell_size())
	var base := base_surface_height_for_cell3(Vector3i(cell_x, 0, cell_z))
	return base + cave_mound_overlay(plan, point)

func cave_mound_overlay(plan: Dictionary, point: Vector2) -> float:
	if plan.is_empty() or not bool(plan.get("moundBacked", false)):
		return 0.0
	var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
	var inward_cell: Vector2i = plan.get("inward", Vector2i(0, 1))
	var right_cell: Vector2i = plan.get("right", Vector2i(1, 0))
	var inward := Vector2(float(inward_cell.x), float(inward_cell.y)).normalized()
	var right := Vector2(float(right_cell.x), float(right_cell.y)).normalized()
	if inward.length() <= 0.01:
		inward = Vector2(0.0, 1.0)
	if right.length() <= 0.01:
		right = Vector2(1.0, 0.0)
	var entrance_world := cell_world2(entrance)
	var entrance_delta := point - entrance_world
	var entrance_depth := entrance_delta.dot(inward) / cell_size()
	var front_toe := smoothstep(-4.25, 1.35, entrance_depth)
	if front_toe <= 0.001:
		return 0.0
	var path_length := float(plan.get("pathLength", 16))
	var mouth_half_width := float(plan.get("entranceMouthHalfWidth", 2.85))
	var mound_center := entrance_world + inward * cell_size() * maxf(4.0, path_length * 0.28)
	var delta := point - mound_center
	var depth := delta.dot(inward) / (cell_size() * maxf(8.0, path_length * 0.72))
	var lateral := delta.dot(right) / (cell_size() * maxf(12.0, maxf(path_length * 0.30, mouth_half_width * 3.2)))
	var distance := depth * depth + lateral * lateral
	if distance >= 1.0:
		return 0.0
	var existing := base_surface_height_for_cell3(Vector3i(roundi(point.x / cell_size()), 0, roundi(point.y / cell_size())))
	var required_cover := cave_ceiling_y_without_surface_clamp(plan, point) + cell_size() * 1.45
	var needed := maxf(0.0, required_cover - existing)
	var base_height := maxf(cell_size() * 2.2, needed)
	var falloff := pow(1.0 - distance, 1.65)
	var phase_a := stable01(plan, "mound-phase-a", 0, 0) * TAU
	var phase_b := stable01(plan, "mound-phase-b", 0, 0) * TAU
	var noise := clampf(0.96 + sin(point.x * 0.021 + phase_a) * 0.045 + cos(point.y * 0.027 + phase_b) * 0.045, 0.88, 1.08)
	return base_height * falloff * front_toe * noise

func cave_ceiling_y_without_surface_clamp(plan: Dictionary, point: Vector2) -> float:
	var floor_y := cave_floor_y_at_surface(plan, point, float(plan.get("level", 0.0)))
	var axes := cave_mouth_depth_lateral(plan, point)
	var base_ceiling := float(plan.get("ceilingLevel", floor_y + cell_size() * 2.8))
	var width := cave_mouth_width_at_depth(plan, axes.x)
	if width > 0.0:
		var lateral_t := clampf(absf(axes.y) / maxf(0.001, width), 0.0, 1.0)
		var arch := sqrt(maxf(0.0, 1.0 - lateral_t * lateral_t))
		var arch_height := float(plan.get("entranceMouthArchHeight", clampf(width * cell_size() * 0.98, cell_size() * 2.05, cell_size() * 4.2)))
		return floor_y + maxf(cell_size() * 0.58, arch_height * arch)
	return maxf(floor_y + cell_size() * 2.15, base_ceiling)

func surface_patch_quad_cut_by_cave_pipe(plan: Dictionary, p00: Vector2, p10: Vector2, p11: Vector2, p01: Vector2) -> bool:
	for point in [p00, p10, p11, p01, (p00 + p11) * 0.5]:
		if cave_surface_point_opens_to_air(plan, point):
			return true
	return false

func cave_surface_point_opens_to_air(plan: Dictionary, point: Vector2) -> bool:
	var axes := cave_mouth_depth_lateral(plan, point)
	if axes.x < cave_mouth_front_depth(plan) - 0.35 or axes.x > float(plan.get("entranceOpenDepth", 7)) + 0.65:
		return false
	var surface_y := surface_height_for_plan_point(plan, point)
	var floor_y := cave_floor_y_at_surface(plan, point, float(plan.get("level", 0.0)))
	var ceiling_y := cave_ceiling_y_at_surface(plan, point, floor_y + cell_size() * 3.0)
	var max_cover := cell_size() * (1.20 if axes.x <= 0.25 else (0.88 if axes.x <= 2.25 else 0.46))
	if surface_y - ceiling_y > max_cover:
		return false
	for offset in [0.30, 0.62, 0.95, 1.28]:
		var sample_y := surface_y - cell_size() * float(offset)
		if sample_y < floor_y - cell_size() * 0.08:
			continue
		if cave_contains_world(plan, Vector3(point.x, sample_y, point.y)):
			return true
	return false

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
			max_diff = maxf(max_diff, absf(natural_surface_height_for_cell3(Vector3i(sample_x, 0, sample_z)) - level))
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

func surface_quad_hidden_for_cell3(cell: Vector3i) -> bool:
	var cell_size_value := cell_size()
	var p00 := Vector2(float(cell.x) * cell_size_value, float(cell.z) * cell_size_value)
	var p10 := Vector2(float(cell.x + 1) * cell_size_value, float(cell.z) * cell_size_value)
	var p01 := Vector2(float(cell.x) * cell_size_value, float(cell.z + 1) * cell_size_value)
	var p11 := Vector2(float(cell.x + 1) * cell_size_value, float(cell.z + 1) * cell_size_value)
	for plan in active_plans_from_records(null):
		if surface_patch_quad_cut_by_cave_pipe(plan, p00, p10, p11, p01):
			return true
	for brush in excavation_brushes:
		var hidden_cells = brush.get("hiddenCells", {})
		if hidden_cells is Dictionary and (hidden_cells as Dictionary).has(Vector2i(cell.x, cell.z)):
			return true
	return false

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

func active_plans_from_records(active_plan_records) -> Array[Dictionary]:
	var plans: Array[Dictionary] = []
	var records = cave_plan_records if active_plan_records == null else active_plan_records
	if not (records is Dictionary):
		return plans
	for value in (records as Dictionary).values():
		if value is Dictionary:
			var record: Dictionary = value
			var plan_value = record.get("plan", record)
			if plan_value is Dictionary:
				plans.append(plan_value)
	return plans

func cell_world2(cell: Vector2i) -> Vector2:
	return Vector2(float(cell.x) * cell_size(), float(cell.y) * cell_size())

func cell_size() -> float:
	return float(main.CELL) if main != null else 1.35

func stable01(plan: Dictionary, salt: String, x: int, z: int) -> float:
	var text := "%s:%s:%s:%d,%d" % [String(main.get("seed_text")) if main != null else "", String(plan.get("id", "cave")), salt, x, z]
	var h := int(main.hash_string(text)) if main != null and main.has_method("hash_string") else hash(text)
	return float(abs(h) % 100000) / 99999.0

func stable_signed(plan: Dictionary, salt: String, x: int, z: int) -> float:
	return stable01(plan, salt, x, z) * 2.0 - 1.0
