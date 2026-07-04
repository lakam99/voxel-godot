extends RefCounted
class_name WorldGenerationSystem

const UNDERGROUND_GENERATED_DEPTH_CELLS := 32
const UNDERGROUND_AIR_BIOME := "underground_air"
const UNDERGROUND_MIN_AIR_DEPTH_CELLS := 4.0
const UNDERGROUND_AIR_SEARCH_STEP_CELLS := 4
const UNDERGROUND_AIR_MIN_CONNECTED_CELLS := 24
const UNDERGROUND_AIR_CONNECTIVITY_RADIUS_CELLS := 8
const SURFACE_EXCAVATION_RADIUS_MULTIPLIER := 2.35

var main
var excavation_brushes: Array[Dictionary] = []
var surface_projection_cache := {}
var deformed_surface_y_cache := {}
var natural_surface_y_cache := {}
var base_surface_y_cache := {}
var surface_biome_cache := {}

func setup(main_node) -> void:
	main = main_node

func reset() -> void:
	excavation_brushes.clear()
	surface_projection_cache.clear()
	deformed_surface_y_cache.clear()
	natural_surface_y_cache.clear()
	base_surface_y_cache.clear()
	surface_biome_cache.clear()

func reset_for_seed() -> void:
	excavation_brushes.clear()
	surface_projection_cache.clear()
	deformed_surface_y_cache.clear()
	natural_surface_y_cache.clear()
	base_surface_y_cache.clear()
	surface_biome_cache.clear()

func sample_cell(cell: Vector3i) -> Dictionary:
	var s := cell_size()
	return sample_world(Vector3((float(cell.x) + 0.5) * s, (float(cell.y) + 0.5) * s, (float(cell.z) + 0.5) * s))

func sample_world(position: Vector3) -> Dictionary:
	var base_surface_y := terrain_reference_surface_y_at(position)
	var surface_y := terrain_deformed_surface_y_at(position)
	var density := density_from_components(position, surface_y, base_surface_y)
	var solid := density >= 0.0
	var cell := world_to_cell3(position)
	var depth := maxf(0.0, base_surface_y - position.y)
	var depth_cells := depth / maxf(0.001, cell_size())
	var surface_biome := surface_biome_for_cell3(Vector3i(cell.x, 0, cell.z))
	var biome := biome_from_sample_components(position, density, surface_y, depth_cells, surface_biome)
	var material := material_from_sample_components(position, density, base_surface_y, cell, surface_biome)
	return {
		"cell": cell,
		"position": position,
		"density": density,
		"solid": solid,
		"biome": biome,
		"material": material,
		"surface": absf(density) <= cell_size() * 0.75,
		"surfaceY": surface_y,
		"baseSurfaceY": base_surface_y,
		"depthCells": depth_cells,
		"generatedDepthCells": UNDERGROUND_GENERATED_DEPTH_CELLS
	}

func density_at(position: Vector3) -> float:
	var base_surface_y := terrain_reference_surface_y_at(position)
	var surface_y := terrain_deformed_surface_y_at(position)
	return density_from_components(position, surface_y, base_surface_y)

func density_from_components(position: Vector3, surface_y: float, base_surface_y := NAN) -> float:
	if is_nan(base_surface_y):
		base_surface_y = surface_y
	var density := surface_y - position.y
	if density > 0.0:
		var depth_cells := maxf(0.0, base_surface_y - position.y) / maxf(0.001, cell_size())
		if depth_cells <= float(UNDERGROUND_GENERATED_DEPTH_CELLS):
			density = minf(density, underground_air_density_at(position, base_surface_y, depth_cells))
	for brush in merged_excavation_brushes([]):
		if brush_uses_volume_subtraction(brush):
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
	var base_surface_y := terrain_reference_surface_y_at(position)
	var surface_y := terrain_deformed_surface_y_at(position)
	var density := density_from_components(position, surface_y, base_surface_y)
	var cell := world_to_cell3(position)
	var surface_biome := surface_biome_for_cell3(Vector3i(cell.x, 0, cell.z))
	return material_from_sample_components(position, density, base_surface_y, cell, surface_biome)

func biome_from_sample_components(position: Vector3, density: float, surface_y: float, depth_cells: float, surface_biome: String) -> String:
	if density < 0.0:
		if surface_y - position.y > cell_size() * 0.35:
			return UNDERGROUND_AIR_BIOME
		return surface_biome
	if depth_cells > 3.0:
		return "underground"
	return surface_biome

func material_from_sample_components(position: Vector3, density: float, surface_y: float, cell: Vector3i, surface_biome: String) -> String:
	if density < 0.0:
		return "air"
	var depth := maxf(0.0, surface_y - position.y)
	if depth <= cell_size() * 1.20:
		return top_material_for_biome(surface_biome)
	if depth <= cell_size() * 4.65:
		return subsoil_material_for_biome(surface_biome)
	var ore := ore_material_at(cell, depth)
	if ore != "":
		return ore
	return "stone"

func underground_air_density_at(position: Vector3, surface_y: float, depth_cells: float) -> float:
	if depth_cells < UNDERGROUND_MIN_AIR_DEPTH_CELLS:
		return cell_size()
	if depth_cells > float(UNDERGROUND_GENERATED_DEPTH_CELLS) - 1.0:
		return cell_size()
	if main == null or main.get("ridge_noise") == null:
		return cell_size()
	var s := cell_size()
	var cell_pos := Vector3(position.x / s, position.y / s, position.z / s)
	var ridge = main.get("ridge_noise") as FastNoiseLite
	var height = main.get("height_noise") as FastNoiseLite
	var chamber_a := noise3d01(ridge, cell_pos.x * 0.48 + 4100.0, cell_pos.y * 0.62 - 2300.0, cell_pos.z * 0.48 + 1700.0)
	var chamber_b := noise3d01(height, cell_pos.x * 0.72 - 6200.0, cell_pos.y * 0.86 + 910.0, cell_pos.z * 0.72 + 3600.0) if height != null else chamber_a
	var chamber_signal := maxf(chamber_a, chamber_b * 0.94 + chamber_a * 0.06)
	var channel_a_raw := noise3d01(ridge, cell_pos.x * 0.54 - 7100.0, cell_pos.y * 0.30 + 1900.0, cell_pos.z * 1.06 + 800.0)
	var channel_b_raw := noise3d01(height, cell_pos.x * 1.04 + 2200.0, cell_pos.y * 0.34 - 3600.0, cell_pos.z * 0.52 - 4900.0) if height != null else channel_a_raw
	var channel_c_raw := noise3d01(ridge, cell_pos.x * 0.58 + 980.0, cell_pos.y * 0.96 - 8100.0, cell_pos.z * 0.58 + 2700.0)
	var connector_a := smoothstep_local(1.0 - absf(channel_a_raw - 0.5) * 2.0, 0.58, 0.92)
	var connector_b := smoothstep_local(1.0 - absf(channel_b_raw - 0.5) * 2.0, 0.58, 0.92)
	var connector_c := smoothstep_local(1.0 - absf(channel_c_raw - 0.5) * 2.0, 0.62, 0.94)
	var connector_signal := maxf(connector_c * 0.88, maxf(connector_a, connector_b))
	var chamber_gate := smoothstep_local(chamber_signal, 0.44, 0.70)
	var cellular := underground_cell_hash01(world_to_cell3(position))
	var air_signal := maxf(chamber_signal, connector_signal * lerpf(0.70, 0.97, chamber_gate))
	air_signal = clampf(air_signal + cellular * 0.025, 0.0, 1.0)
	var depth_open := smoothstep_local(depth_cells, UNDERGROUND_MIN_AIR_DEPTH_CELLS, UNDERGROUND_MIN_AIR_DEPTH_CELLS + 4.0)
	var depth_close := 1.0 - smoothstep_local(depth_cells, float(UNDERGROUND_GENERATED_DEPTH_CELLS) - 5.0, float(UNDERGROUND_GENERATED_DEPTH_CELLS))
	var depth_fade := clampf(depth_open * depth_close, 0.0, 1.0)
	var strata := noise3d01(ridge, cell_pos.x * 0.38 - 1400.0, cell_pos.y * 0.62 + 2500.0, cell_pos.z * 0.38 - 3700.0)
	var threshold := lerpf(0.560, 0.635, strata)
	var raw_density := (threshold - air_signal) * s * 4.25
	return lerpf(s, raw_density, depth_fade)

func noise3d01(noise: FastNoiseLite, x: float, y: float, z: float) -> float:
	if noise == null:
		return 0.5
	return noise.get_noise_3d(x, y, z) * 0.5 + 0.5

func smoothstep_local(value: float, low: float, high: float) -> float:
	if high <= low:
		return 1.0 if value >= high else 0.0
	var t := clampf((value - low) / (high - low), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

func underground_cell_hash01(cell: Vector3i) -> float:
	var text := "underground-volume:%s:%d,%d,%d" % [String(main.get("seed_text")) if main != null else "", cell.x, cell.y, cell.z]
	if main != null and main.has_method("hash01"):
		return float(main.call("hash01", text))
	var h := hash(text)
	return float(abs(h) % 100000) / 100000.0

func register_excavation_brush(brush: Dictionary) -> void:
	var brush_id := String(brush.get("id", ""))
	if brush_id == "":
		return
	for index in range(excavation_brushes.size()):
		if String(excavation_brushes[index].get("id", "")) == brush_id:
			excavation_brushes[index] = brush.duplicate(true)
			surface_projection_cache.clear()
			deformed_surface_y_cache.clear()
			return
	excavation_brushes.append(brush.duplicate(true))
	surface_projection_cache.clear()
	deformed_surface_y_cache.clear()

func clear_excavation_brushes() -> void:
	excavation_brushes.clear()
	surface_projection_cache.clear()
	deformed_surface_y_cache.clear()

func surface_y_at(position: Vector3) -> float:
	return terrain_deformed_surface_y_at(position)

func surface_y_for_cell(cell: Vector3i) -> float:
	return terrain_deformed_surface_y_for_cell(cell)

func volume_surface_y_for_cell(cell: Vector3i) -> float:
	var key := Vector2i(cell.x, cell.z)
	if surface_projection_cache.has(key):
		return float(surface_projection_cache[key])
	var high := ceili((float(main.MAX_HEIGHT) + cell_size() * 4.0) / cell_size()) if main != null else 96
	var low := floori((float(main.MIN_HEIGHT) - cell_size() * float(UNDERGROUND_GENERATED_DEPTH_CELLS + 4)) / cell_size()) if main != null else -40
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

func terrain_deformed_surface_y_at(position: Vector3) -> float:
	return terrain_deformed_surface_y_for_cell(Vector3i(roundi(position.x / cell_size()), 0, roundi(position.z / cell_size())))

func terrain_deformed_surface_y_for_cell(cell: Vector3i) -> float:
	var key := Vector2i(cell.x, cell.z)
	if deformed_surface_y_cache.has(key):
		return float(deformed_surface_y_cache[key])
	var value := terrain_reference_surface_y_for_cell(cell)
	var world_x := float(cell.x) * cell_size()
	var world_z := float(cell.z) * cell_size()
	for brush in merged_excavation_brushes([]):
		if not brush_is_surface_deformation(brush):
			continue
		var center: Vector3 = brush.get("center", Vector3.ZERO)
		var radius := surface_deform_radius_for_brush(brush)
		if radius <= 0.0:
			continue
		var distance := Vector2(world_x - center.x, world_z - center.z).length()
		if distance >= radius:
			continue
		var target_y := surface_target_y_for_brush(brush)
		if target_y >= value:
			continue
		var t := clampf(distance / radius, 0.0, 1.0)
		var falloff := 1.0 - smoothstep_local(t, 0.0, 1.0)
		var proposed: float = lerp(value, target_y, falloff)
		value = minf(value, proposed)
	deformed_surface_y_cache[key] = value
	return value

func has_surface_deformation() -> bool:
	for brush in merged_excavation_brushes([]):
		if brush_is_surface_deformation(brush):
			return true
	return false

func base_surface_y_for_cell(cell: Vector3i) -> float:
	var key := Vector2i(cell.x, cell.z)
	if base_surface_y_cache.has(key):
		return float(base_surface_y_cache[key])
	var town: Dictionary = town_region_for_surface_cell3(cell)
	if not town.is_empty():
		var center_x := int(town["centerX"])
		var center_z := int(town["centerZ"])
		var radius := float(town["radius"])
		var distance := Vector2(float(cell.x - center_x), float(cell.z - center_z)).length()
		var level := float(town["level"])
		if distance <= radius:
			base_surface_y_cache[key] = level
			return level
		var apron := float(town_slope_apron_cells(town))
		var natural := natural_surface_y_for_cell(cell)
		var blend := clampf((distance - radius) / maxf(1.0, apron), 0.0, 1.0)
		var eased := blend * blend * (3.0 - 2.0 * blend)
		var value: float = lerp(level, natural, eased)
		base_surface_y_cache[key] = value
		return value
	var value: float = natural_surface_y_for_cell(cell)
	base_surface_y_cache[key] = value
	return value

func natural_surface_y_for_cell(cell: Vector3i) -> float:
	if main == null:
		return 0.0
	var key := Vector2i(cell.x, cell.z)
	if natural_surface_y_cache.has(key):
		return float(natural_surface_y_cache[key])
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
	var value: float = clamp(round(raw / terrace) * terrace, float(main.MIN_HEIGHT), float(main.MAX_HEIGHT))
	natural_surface_y_cache[key] = value
	return value

func surface_biome_for_cell3(cell: Vector3i) -> String:
	var key := Vector2i(cell.x, cell.z)
	if surface_biome_cache.has(key):
		return String(surface_biome_cache[key])
	if not town_region_at_cell3(cell).is_empty():
		surface_biome_cache[key] = "town"
		return "town"
	var h: float = terrain_reference_surface_y_for_cell(cell)
	var moisture: float = main.noise01(main.moisture_noise, cell.x - 1200, cell.z + 800) if main != null else 0.5
	var temp: float = clamp(0.42 + (main.noise01(main.temp_noise, cell.x + 1500, cell.z - 900) if main != null else 0.5) * 0.46 - abs(cell.z) / 1300.0 - max(0.0, h - 38.0) / 180.0, 0.0, 1.0)
	if h < float(main.WATER_LEVEL) + 0.3:
		surface_biome_cache[key] = "ocean"
		return "ocean"
	if h < float(main.WATER_LEVEL) + 1.7:
		surface_biome_cache[key] = "beach"
		return "beach"
	if h > 78.0:
		surface_biome_cache[key] = "snow"
		return "snow"
	if h > 56.0:
		var value := "alpine" if temp < 0.48 else "tundra"
		surface_biome_cache[key] = value
		return value
	if h > 42.0 and moisture < 0.5:
		surface_biome_cache[key] = "alpine"
		return "alpine"
	if moisture > 0.78 and h < float(main.WATER_LEVEL) + 6.0:
		surface_biome_cache[key] = "swamp"
		return "swamp"
	if temp > 0.68 and moisture < 0.32:
		surface_biome_cache[key] = "desert"
		return "desert"
	if temp > 0.61 and moisture < 0.48:
		surface_biome_cache[key] = "savanna"
		return "savanna"
	if temp < 0.33 and moisture > 0.42:
		surface_biome_cache[key] = "taiga"
		return "taiga"
	if moisture > 0.64:
		surface_biome_cache[key] = "forest"
		return "forest"
	surface_biome_cache[key] = "plains"
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
		if not brush_uses_volume_subtraction(brush):
			continue
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
		if not brush_uses_volume_subtraction(brush):
			continue
		var center: Vector3 = brush.get("center", Vector3.ZERO)
		var radius := float(brush.get("radius", 0.0))
		if radius > 0.0 and center.distance_to(world_pos) <= radius:
			return true
	return false

func terrain_surface_y_at(position: Vector3) -> float:
	return surface_y_at(position)

func find_underground_air_sample(search_radius := 16, min_depth_cells := 4, max_depth_cells := UNDERGROUND_GENERATED_DEPTH_CELLS - 2) -> Dictionary:
	var radius_cells := maxi(UNDERGROUND_AIR_SEARCH_STEP_CELLS, int(search_radius) * UNDERGROUND_AIR_SEARCH_STEP_CELLS * 2)
	var min_depth := clampi(int(min_depth_cells), 1, UNDERGROUND_GENERATED_DEPTH_CELLS)
	var max_depth := clampi(int(max_depth_cells), min_depth, UNDERGROUND_GENERATED_DEPTH_CELLS)
	var step := UNDERGROUND_AIR_SEARCH_STEP_CELLS
	for radius in range(0, radius_cells + 1, step):
		for z in range(-radius, radius + 1, step):
			for x in range(-radius, radius + 1, step):
				if radius > 0 and absi(x) != radius and absi(z) != radius:
					continue
				var surface_cell := Vector3i(x, 0, z)
				var surface_biome := surface_biome_for_cell3(surface_cell)
				if surface_biome in ["ocean", "beach", "town"]:
					continue
				var surface_y := terrain_reference_surface_y_for_cell(surface_cell)
				for depth in range(min_depth, max_depth + 1):
					var position := Vector3(float(x) * cell_size(), surface_y - float(depth) * cell_size(), float(z) * cell_size())
					var sample := sample_world(position)
					if String(sample.get("biome", "")) != UNDERGROUND_AIR_BIOME:
						continue
					if bool(sample.get("solid", true)):
						continue
					if float(sample.get("density", 0.0)) > -cell_size() * 0.22:
						continue
					var cell := world_to_cell3(position)
					var boundary := underground_air_sample_boundary_summary(cell)
					if int(boundary.get("solidNeighbors", 0)) < 2 or int(boundary.get("airNeighbors", 0)) < 2:
						continue
					var connected_region := underground_air_connected_region_summary(cell, UNDERGROUND_AIR_MIN_CONNECTED_CELLS * 4, UNDERGROUND_AIR_CONNECTIVITY_RADIUS_CELLS)
					if int(connected_region.get("airCells", 0)) < UNDERGROUND_AIR_MIN_CONNECTED_CELLS:
						continue
					var sample_id := "underground-air:%d,%d,%d" % [cell.x, cell.y, cell.z]
					return {
						"id": sample_id,
						"sampleId": sample_id,
						"cell": cell,
						"surfaceCell": Vector2i(x, z),
						"position": position,
						"surfaceY": surface_y,
						"depthCells": depth,
						"sample": sample,
						"connectedRegion": connected_region
					}
	return {}

func underground_air_sample_has_solid_boundary(cell: Vector3i) -> bool:
	return int(underground_air_sample_boundary_summary(cell).get("solidNeighbors", 0)) >= 2

func underground_air_connected_region_summary(start_cell: Vector3i, max_cells := 96, max_radius := UNDERGROUND_AIR_CONNECTIVITY_RADIUS_CELLS) -> Dictionary:
	var start_sample := sample_cell(start_cell)
	if bool(start_sample.get("solid", true)) or String(start_sample.get("biome", "")) != UNDERGROUND_AIR_BIOME:
		return {
			"airCells": 0,
			"branchDirections": 0,
			"solidBoundarySamples": 0,
			"span": Vector3i.ZERO
		}
	var directions := [
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0),
		Vector3i(0, -1, 0),
		Vector3i(0, 0, 1),
		Vector3i(0, 0, -1)
	]
	var queue: Array[Vector3i] = [start_cell]
	var visited := { start_cell: true }
	var read_index := 0
	var min_cell := start_cell
	var max_cell := start_cell
	var branch_lookup := {}
	var solid_boundary_samples := 0
	while read_index < queue.size() and visited.size() < maxi(1, int(max_cells)):
		var cell: Vector3i = queue[read_index]
		read_index += 1
		min_cell.x = mini(min_cell.x, cell.x)
		min_cell.y = mini(min_cell.y, cell.y)
		min_cell.z = mini(min_cell.z, cell.z)
		max_cell.x = maxi(max_cell.x, cell.x)
		max_cell.y = maxi(max_cell.y, cell.y)
		max_cell.z = maxi(max_cell.z, cell.z)
		for direction in directions:
			var next: Vector3i = cell + direction
			if absi(next.x - start_cell.x) > max_radius or absi(next.y - start_cell.y) > max_radius or absi(next.z - start_cell.z) > max_radius:
				continue
			if visited.has(next):
				continue
			var sample := sample_cell(next)
			if bool(sample.get("solid", false)):
				solid_boundary_samples += 1
				continue
			if String(sample.get("biome", "")) != UNDERGROUND_AIR_BIOME:
				continue
			visited[next] = true
			queue.append(next)
			var branch_direction := Vector3i(signi(next.x - start_cell.x), signi(next.y - start_cell.y), signi(next.z - start_cell.z))
			if branch_direction != Vector3i.ZERO:
				branch_lookup[branch_direction] = true
	var span := Vector3i(max_cell.x - min_cell.x + 1, max_cell.y - min_cell.y + 1, max_cell.z - min_cell.z + 1)
	return {
		"airCells": visited.size(),
		"branchDirections": branch_lookup.size(),
		"solidBoundarySamples": solid_boundary_samples,
		"span": span,
		"minCell": min_cell,
		"maxCell": max_cell,
		"truncated": read_index < queue.size()
	}

func underground_air_sample_boundary_summary(cell: Vector3i) -> Dictionary:
	var solid_neighbors := 0
	var air_neighbors := 0
	var directions := [
		Vector3i(1, 0, 0),
		Vector3i(-1, 0, 0),
		Vector3i(0, 1, 0),
		Vector3i(0, -1, 0),
		Vector3i(0, 0, 1),
		Vector3i(0, 0, -1)
	]
	for direction in directions:
		var sample := sample_cell(cell + direction)
		if bool(sample.get("solid", false)):
			solid_neighbors += 1
		elif String(sample.get("biome", "")) == UNDERGROUND_AIR_BIOME:
			air_neighbors += 1
	return {
		"solidNeighbors": solid_neighbors,
		"airNeighbors": air_neighbors
	}

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
	if biome == UNDERGROUND_AIR_BIOME or biome == "underground":
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

func brush_is_surface_deformation(brush: Dictionary) -> bool:
	var mode := String(brush.get("mode", ""))
	if mode == "surface_deform":
		return true
	if mode == "volume":
		return false
	if brush.has("surfaceTargetY") or brush.has("deformRadius"):
		return true
	var center: Vector3 = brush.get("center", Vector3.ZERO)
	var radius := float(brush.get("radius", 0.0))
	if radius <= 0.0:
		return false
	var surface_y := terrain_reference_surface_y_at(center)
	return center.y >= surface_y - radius * 1.45

func brush_uses_volume_subtraction(brush: Dictionary) -> bool:
	return not brush_is_surface_deformation(brush)

func surface_deform_radius_for_brush(brush: Dictionary) -> float:
	var deform_radius := float(brush.get("deformRadius", 0.0))
	if deform_radius > 0.0:
		return deform_radius
	return float(brush.get("radius", 0.0)) * SURFACE_EXCAVATION_RADIUS_MULTIPLIER

func surface_target_y_for_brush(brush: Dictionary) -> float:
	if brush.has("surfaceTargetY"):
		return float(brush.get("surfaceTargetY"))
	var center: Vector3 = brush.get("center", Vector3.ZERO)
	return center.y - cell_size() * 0.45

func cell_world2(cell: Vector2i) -> Vector2:
	return Vector2(float(cell.x) * cell_size(), float(cell.y) * cell_size())

func cell_size() -> float:
	return float(main.CELL) if main != null else 1.35
