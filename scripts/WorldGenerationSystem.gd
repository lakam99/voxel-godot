extends RefCounted
class_name WorldGenerationSystem

const TerrainVolumeServiceScript := preload("res://scripts/TerrainVolumeService.gd")
const BiomeRegionFieldScript := preload("res://scripts/world/BiomeRegionField.gd")

const UNDERGROUND_AIR_BIOME := "underground_air"
const NATURAL_SURFACE_MIN_OVERBURDEN_CELLS := 3.0
const TOWN_SURFACE_MIN_OVERBURDEN_CELLS := 8.0
const UNDERGROUND_AIR_TRANSITION_DEPTH_CELLS := 5.0
const UNDERGROUND_AIR_SEARCH_STEP_CELLS := 4
const UNDERGROUND_AIR_MIN_CONNECTED_CELLS := 24
const UNDERGROUND_AIR_CONNECTIVITY_RADIUS_CELLS := 8
const UNDERGROUND_AIR_DEFAULT_SEARCH_DEPTH_CELLS := 72
const SURFACE_EXCAVATION_RADIUS_MULTIPLIER := 2.35
const WORLD_BOTTOM_CELL_Y := -64
const TOWN_SLOPE_APRON_CACHE_VERSION := 2
const LEGACY_BRUSH_TERRAIN_AUTHORITY_ENABLED := false
const MESHING_SURFACE_PROJECTION_UPPER_ENVELOPE_CELLS := 1

var main
var excavation_brushes: Array[Dictionary] = []
var surface_projection_cache := {}
var deformed_surface_y_cache := {}
var natural_surface_y_cache := {}
var base_surface_y_cache := {}
var surface_biome_cache := {}
var minimum_overburden_cache := {}
var terrain_volume_service
var biome_region_field = BiomeRegionFieldScript.new()

func setup(main_node) -> void:
	main = main_node
	if terrain_volume_service == null:
		terrain_volume_service = TerrainVolumeServiceScript.new()
	terrain_volume_service.setup(main, self)

func reset() -> void:
	excavation_brushes.clear()
	if terrain_volume_service != null and terrain_volume_service.has_method("reset"):
		terrain_volume_service.reset()
	surface_projection_cache.clear()
	deformed_surface_y_cache.clear()
	natural_surface_y_cache.clear()
	base_surface_y_cache.clear()
	surface_biome_cache.clear()
	minimum_overburden_cache.clear()

func reset_for_seed() -> void:
	excavation_brushes.clear()
	if terrain_volume_service != null and terrain_volume_service.has_method("reset_for_seed"):
		terrain_volume_service.reset_for_seed()
	surface_projection_cache.clear()
	deformed_surface_y_cache.clear()
	natural_surface_y_cache.clear()
	base_surface_y_cache.clear()
	surface_biome_cache.clear()
	minimum_overburden_cache.clear()

func invalidate_generated_surface_caches() -> void:
	# A deterministic settlement manifest changed before a new terrain generator
	# is published. Clear derived generation caches only: player-made cells remain
	# owned by TerrainVolumeService and survive the generator refresh.
	surface_projection_cache.clear()
	deformed_surface_y_cache.clear()
	natural_surface_y_cache.clear()
	base_surface_y_cache.clear()
	surface_biome_cache.clear()
	minimum_overburden_cache.clear()
	if terrain_volume_service != null and terrain_volume_service.has_method("invalidate_generated_surface_caches"):
		terrain_volume_service.invalidate_generated_surface_caches()

func biome_region_for_cell3(cell: Vector3i) -> Dictionary:
	if biome_region_field == null:
		biome_region_field = BiomeRegionFieldScript.new()
	var seed_text := String(main.get("seed_text")) if main != null else "default"
	return biome_region_field.sample(seed_text, Vector2(float(cell.x) * cell_size(), float(cell.z) * cell_size()))

func sample_cell(cell: Vector3i) -> Dictionary:
	var s := cell_size()
	return sample_world(Vector3((float(cell.x) + 0.5) * s, (float(cell.y) + 0.5) * s, (float(cell.z) + 0.5) * s))

func sample_world(position: Vector3) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("sample_world"):
		return terrain_volume_service.sample_world(position)
	return generate_sample_without_volume(position)

func generate_sample_without_volume(position: Vector3) -> Dictionary:
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
		"generatedDepthCells": maxi(0, floori(base_surface_y / cell_size()) - world_bottom_cell_y())
	}

func density_at(position: Vector3) -> float:
	return float(sample_world(position).get("density", 0.0))

func density_from_components(position: Vector3, surface_y: float, base_surface_y := NAN) -> float:
	if is_nan(base_surface_y):
		base_surface_y = surface_y
	var density := surface_y - position.y
	if density > 0.0:
		var depth_cells := maxf(0.0, base_surface_y - position.y) / maxf(0.001, cell_size())
		density = minf(density, underground_air_density_at(position, base_surface_y, depth_cells))
		if position.y <= float(world_bottom_cell_y()) * cell_size():
			density = maxf(density, cell_size() * 4.0)
	return density

func solid_at(position: Vector3) -> bool:
	return bool(sample_world(position).get("solid", false))

func biome_at(position: Vector3) -> String:
	return String(sample_world(position).get("biome", "plains"))

func material_at(position: Vector3) -> String:
	return String(sample_world(position).get("material", "air"))

func generate_cell_state(cell: Vector3i) -> Dictionary:
	var s := cell_size()
	var position := Vector3((float(cell.x) + 0.5) * s, (float(cell.y) + 0.5) * s, (float(cell.z) + 0.5) * s)
	var sample := generate_sample_without_volume(position)
	var surface_y := float(sample.get("surfaceY", terrain_reference_surface_y_for_cell(Vector3i(cell.x, 0, cell.z))))
	var base_surface_y := float(sample.get("baseSurfaceY", surface_y))
	var surface_biome := surface_biome_for_cell3(Vector3i(cell.x, 0, cell.z))
	var density := density_from_components(position, base_surface_y, base_surface_y)
	var solid := density >= 0.0
	var material := String(sample.get("material", "air"))
	var biome := String(sample.get("biome", surface_biome))
	var fluid := ""
	var depth := maxf(0.0, base_surface_y - position.y)
	if cell.y <= world_bottom_cell_y() + 1:
		solid = true
		density = maxf(density, s * 4.0)
		material = "bedrock"
		biome = "deep_underground"
	elif solid:
		material = generated_solid_material_for_cell(cell, surface_y, surface_biome, depth)
		if depth > s * 34.0:
			biome = "deep_underground"
		elif depth > s * 3.0:
			biome = "underground"
		else:
			biome = surface_biome
	elif main != null and position.y <= float(main.WATER_LEVEL) and depth <= s * 2.0:
		material = "water"
		biome = "ocean" if surface_biome == "ocean" else surface_biome
		fluid = "water"
	elif depth > s * 0.35:
		biome = UNDERGROUND_AIR_BIOME
		fluid = underground_fluid_for_cell(cell, position, depth, depth / maxf(0.001, s), surface_biome)
		material = fluid if fluid != "" else "air"
	else:
		material = "air"
		biome = surface_biome
	var sky_light := generated_sky_light_for_cell(cell, position, solid, surface_y, biome, depth)
	return {
		"cell": cell,
		"material": material,
		"biome": biome,
		"solid": solid,
		"density": density,
		"surfaceY": surface_y,
		"fluid": fluid,
		"light": { "sky": sky_light, "block": 0 },
		"metadata": {},
		"sample": sample
	}

func volume_numeric_sample_at_grid_cell(cell: Vector3i) -> Vector3:
	var s := cell_size()
	var position := Vector3(float(cell.x) * s, float(cell.y) * s, float(cell.z) * s)
	if terrain_volume_service != null and terrain_volume_service.has_method("numeric_sample_world"):
		return terrain_volume_service.numeric_sample_world(position)
	var sample := generate_sample_without_volume(position)
	var underground_air := String(sample.get("biome", "")) == UNDERGROUND_AIR_BIOME and not bool(sample.get("solid", true))
	return Vector3(
		float(sample.get("density", 0.0)),
		0.0 if underground_air else INF,
		float(sample.get("surfaceY", position.y))
	)

func volume_surface_numeric_sample_at_grid_cell(cell: Vector3i) -> Vector3:
	var s := cell_size()
	var position := Vector3(float(cell.x) * s, float(cell.y) * s, float(cell.z) * s)
	if terrain_volume_service != null and terrain_volume_service.has_method("get_cell_state"):
		var state: Dictionary = terrain_volume_service.get_cell_state(cell)
		if bool(state.get("edited", false)) and terrain_state_affects_surface_projection(state):
			var solid := bool(state.get("solid", false))
			var underground_air := String(state.get("biome", "")) == UNDERGROUND_AIR_BIOME and not solid
			return Vector3(
				float(state.get("density", s if solid else -s)),
				0.0 if underground_air else INF,
				terrain_deformed_surface_y_for_cell(Vector3i(cell.x, 0, cell.z))
			)
	var sample := generate_sample_without_volume(position)
	var sample_underground_air := String(sample.get("biome", "")) == UNDERGROUND_AIR_BIOME and not bool(sample.get("solid", true))
	return Vector3(
		float(sample.get("density", 0.0)),
		0.0 if sample_underground_air else INF,
		float(sample.get("surfaceY", position.y))
	)

func generated_solid_material_for_cell(cell: Vector3i, surface_y: float, surface_biome: String, depth: float) -> String:
	var s := cell_size()
	if cell.y <= world_bottom_cell_y() + 1:
		return "bedrock"
	if depth <= s * 1.20:
		return top_material_for_biome(surface_biome)
	if depth <= s * 4.65:
		return subsoil_material_for_biome(surface_biome)
	var ore := ore_material_at(cell, depth)
	if ore != "":
		return ore
	if depth > s * 38.0:
		return "deepStone"
	return "stone"

func generated_sky_light_for_cell(_cell: Vector3i, position: Vector3, solid: bool, surface_y: float, biome: String, depth: float) -> int:
	if solid:
		return 0
	if String(biome) == UNDERGROUND_AIR_BIOME or depth > cell_size() * 0.35:
		return 15 if position.y >= surface_y - cell_size() * 0.15 else 0
	return 15

func get_cell_state(cell: Vector3i) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("get_cell_state"):
		return terrain_volume_service.get_cell_state(cell)
	return generate_cell_state(cell)

func set_scene_block_overlay(cell: Vector3i, state: Dictionary, reason := "") -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("set_scene_block_overlay"):
		return terrain_volume_service.set_scene_block_overlay(cell, state, reason)
	return set_cell_state(cell, state, reason)

func clear_scene_block_overlay(cell: Vector3i) -> bool:
	if terrain_volume_service != null and terrain_volume_service.has_method("clear_scene_block_overlay"):
		return bool(terrain_volume_service.clear_scene_block_overlay(cell))
	return false

func set_cell_state(cell: Vector3i, state: Dictionary, reason := "") -> Dictionary:
	var affects_surface_projection := terrain_state_affects_surface_projection(state)
	if affects_surface_projection:
		surface_projection_cache.clear()
	var result := {}
	if terrain_volume_service != null and terrain_volume_service.has_method("set_cell_state"):
		result = terrain_volume_service.set_cell_state(cell, state, reason)
	if affects_surface_projection:
		surface_projection_cache.clear()
	return result

func set_cell_state_with_previous(cell: Vector3i, state: Dictionary, previous_state: Dictionary, reason := "") -> Dictionary:
	var affects_surface_projection := terrain_state_affects_surface_projection(state)
	if affects_surface_projection:
		surface_projection_cache.clear()
	var result := {}
	if terrain_volume_service != null and terrain_volume_service.has_method("set_cell_state_with_previous"):
		result = terrain_volume_service.set_cell_state_with_previous(cell, state, previous_state, reason)
	elif terrain_volume_service != null and terrain_volume_service.has_method("set_cell_state"):
		result = terrain_volume_service.set_cell_state(cell, state, reason)
	if affects_surface_projection:
		surface_projection_cache.clear()
	return result

func clear_cell_state(cell: Vector3i, reason := "") -> void:
	surface_projection_cache.clear()
	if terrain_volume_service != null and terrain_volume_service.has_method("clear_cell_state"):
		terrain_volume_service.clear_cell_state(cell, reason)
	surface_projection_cache.clear()

func apply_box_edit(min_cell: Vector3i, max_cell: Vector3i, state: Dictionary, reason := "") -> Array[Vector3i]:
	var affects_surface_projection := terrain_state_affects_surface_projection(state)
	if affects_surface_projection:
		surface_projection_cache.clear()
	var changed: Array[Vector3i] = []
	if terrain_volume_service != null and terrain_volume_service.has_method("apply_box_edit"):
		changed = terrain_volume_service.apply_box_edit(min_cell, max_cell, state, reason)
	if affects_surface_projection:
		surface_projection_cache.clear()
	return changed

func apply_sphere_edit(center: Vector3, radius: float, state: Dictionary, reason := "") -> Array[Vector3i]:
	var affects_surface_projection := terrain_state_affects_surface_projection(state)
	if affects_surface_projection:
		surface_projection_cache.clear()
	var changed: Array[Vector3i] = []
	if terrain_volume_service != null and terrain_volume_service.has_method("apply_sphere_edit"):
		changed = terrain_volume_service.apply_sphere_edit(center, radius, state, reason)
	if affects_surface_projection:
		surface_projection_cache.clear()
	return changed

func apply_surface_deformation_edit(center: Vector3, radius: float, drop_depth: float, state: Dictionary, reason := "") -> Array[Vector3i]:
	var affects_surface_projection := terrain_state_affects_surface_projection(state)
	if affects_surface_projection:
		surface_projection_cache.clear()
	var changed: Array[Vector3i] = []
	if terrain_volume_service != null and terrain_volume_service.has_method("apply_surface_deformation_edit"):
		changed = terrain_volume_service.apply_surface_deformation_edit(center, radius, drop_depth, state, reason)
	else:
		changed = apply_sphere_edit(center, radius, state, reason)
	if affects_surface_projection:
		surface_projection_cache.clear()
	return changed

func begin_sphere_edit_incremental(center: Vector3, radius: float, state: Dictionary, reason := "") -> Dictionary:
	if terrain_state_affects_surface_projection(state):
		surface_projection_cache.clear()
	if terrain_volume_service != null and terrain_volume_service.has_method("begin_sphere_edit_incremental"):
		return terrain_volume_service.begin_sphere_edit_incremental(center, radius, state, reason)
	return { "kind": "sphere", "complete": true, "changedCells": [], "removedMaterials": {} }

func begin_surface_deformation_edit_incremental(center: Vector3, radius: float, drop_depth: float, state: Dictionary, reason := "") -> Dictionary:
	if terrain_state_affects_surface_projection(state):
		surface_projection_cache.clear()
	if terrain_volume_service != null and terrain_volume_service.has_method("begin_surface_deformation_edit_incremental"):
		return terrain_volume_service.begin_surface_deformation_edit_incremental(center, radius, drop_depth, state, reason)
	return begin_sphere_edit_incremental(center, radius, state, reason)

func advance_incremental_terrain_edit(job: Dictionary, frame_budget_ms := 0.35, max_work_units := 8) -> Dictionary:
	if terrain_volume_service == null or not terrain_volume_service.has_method("advance_incremental_edit"):
		return { "state": job, "complete": true, "processedWorkUnits": 0 }
	var result: Dictionary = terrain_volume_service.advance_incremental_edit(job, frame_budget_ms, max_work_units)
	if int(result.get("processedWorkUnits", 0)) > 0:
		surface_projection_cache.clear()
	return result

func request_section(chunk_key, section_y := 0) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("request_section"):
		return terrain_volume_service.request_section(chunk_key, section_y)
	return {}

func request_sections_for_bounds(min_cell: Vector3i, max_cell: Vector3i) -> Array[Vector3i]:
	if terrain_volume_service != null and terrain_volume_service.has_method("request_sections_for_bounds"):
		return terrain_volume_service.request_sections_for_bounds(min_cell, max_cell)
	return []

func section_payload_for_bounds(min_cell: Vector3i, max_cell: Vector3i) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("section_payload_for_bounds"):
		return terrain_volume_service.section_payload_for_bounds(min_cell, max_cell)
	return {}

func section_payload_for_meshing_chunk(start_x: int, start_z: int, chunk_size: int, min_y: int, max_y: int, step_cells := 1) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("section_payload_for_meshing_chunk"):
		return terrain_volume_service.section_payload_for_meshing_chunk(start_x, start_z, chunk_size, min_y, max_y, step_cells)
	return {}

func begin_section_payload_for_meshing_chunk(start_x: int, start_z: int, chunk_size: int, min_y: int, max_y: int, step_cells := 1) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("begin_section_payload_for_meshing_chunk"):
		return terrain_volume_service.begin_section_payload_for_meshing_chunk(start_x, start_z, chunk_size, min_y, max_y, step_cells)
	return {}

func advance_section_payload_state(state: Dictionary, budget_ms := 2.0, max_cells := 192) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("advance_section_payload_state"):
		return terrain_volume_service.advance_section_payload_state(state, budget_ms, max_cells)
	return {
		"state": state,
		"complete": true,
		"payload": {},
		"cellsProcessed": 0,
		"preparedSections": 0,
		"elapsedMs": 0.0
	}

func begin_exact_fluid_payload_for_meshing_chunk(start_x: int, start_z: int, chunk_size: int, min_y: int, max_y: int, terrain_step_cells := 1) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("begin_exact_fluid_payload_for_meshing_chunk"):
		return terrain_volume_service.begin_exact_fluid_payload_for_meshing_chunk(start_x, start_z, chunk_size, min_y, max_y, terrain_step_cells)
	return {}

func advance_exact_fluid_payload_state(state: Dictionary, budget_ms := 2.0, max_cells := 512) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("advance_exact_fluid_payload_state"):
		return terrain_volume_service.advance_exact_fluid_payload_state(state, budget_ms, max_cells)
	return {
		"state": state,
		"complete": true,
		"payload": {},
		"cellsProcessed": 0,
		"preparedSections": 0,
		"elapsedMs": 0.0
	}

func generate_section(section_key: Vector3i) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("generate_section"):
		return terrain_volume_service.generate_section(section_key)
	return {}

func save_section_delta(section_key: Vector3i) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("save_section_delta"):
		return terrain_volume_service.save_section_delta(section_key)
	return {}

func load_section(section_key: Vector3i, delta: Dictionary) -> void:
	if terrain_volume_service != null and terrain_volume_service.has_method("load_section"):
		terrain_volume_service.load_section(section_key, delta)

func mark_section_dirty(section_key: Vector3i, flags := {}) -> void:
	if terrain_volume_service != null and terrain_volume_service.has_method("mark_section_dirty"):
		terrain_volume_service.mark_section_dirty(section_key, flags)

func exposed_surface_cells(chunk_key: Vector2i, chunk_size := 0) -> Array[Vector3i]:
	if terrain_volume_service != null and terrain_volume_service.has_method("exposed_surface_cells"):
		if int(chunk_size) > 0:
			return terrain_volume_service.exposed_surface_cells(chunk_key, int(chunk_size))
		return terrain_volume_service.exposed_surface_cells(chunk_key)
	return []

func exposed_underground_floor_cells(chunk_key: Vector2i, chunk_size := 0, max_candidates := 36, max_scan_cells := 0) -> Array[Vector3i]:
	if terrain_volume_service != null and terrain_volume_service.has_method("exposed_underground_floor_cells"):
		var size := int(chunk_size)
		if size <= 0 and main != null:
			size = int(main.CHUNK_SIZE)
		if size <= 0:
			size = TerrainVolumeServiceScript.SECTION_SIZE
		return terrain_volume_service.exposed_underground_floor_cells(chunk_key, size, max_candidates, max_scan_cells)
	return []

func begin_exposed_underground_floor_scan(chunk_key: Vector2i, chunk_size := 0) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("begin_exposed_underground_floor_scan"):
		var size := int(chunk_size)
		if size <= 0 and main != null:
			size = int(main.CHUNK_SIZE)
		if size <= 0:
			size = TerrainVolumeServiceScript.SECTION_SIZE
		return terrain_volume_service.begin_exposed_underground_floor_scan(chunk_key, size)
	return {}

func advance_exposed_underground_floor_scan(state: Dictionary, sample_budget := 128, time_budget_ms := -1.0, budget_start_usec := 0) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("advance_exposed_underground_floor_scan"):
		return terrain_volume_service.advance_exposed_underground_floor_scan(state, sample_budget, time_budget_ms, budget_start_usec)
	return {
		"state": state,
		"complete": true,
		"newCandidates": [],
		"processed": 0
	}

func solid_at_cell(cell: Vector3i) -> bool:
	if terrain_volume_service != null and terrain_volume_service.has_method("solid_at_cell"):
		return bool(terrain_volume_service.solid_at_cell(cell))
	return bool(generate_cell_state(cell).get("solid", false))

func terrain_occupancy_at_cell(cell: Vector3i) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("terrain_occupancy_at_cell"):
		return terrain_volume_service.terrain_occupancy_at_cell(cell)
	var state := generate_cell_state(cell)
	return {
		"cell": cell,
		"solid": bool(state.get("solid", false)),
		"air": not bool(state.get("solid", false)),
		"material": String(state.get("material", "air")),
		"biome": String(state.get("biome", "")),
		"fluid": String(state.get("fluid", "")),
		"light": state.get("light", { "sky": 0, "block": 0 })
	}

func surface_projection_for_cell(cell: Vector3i, max_up_cells := 32, max_down_cells := 96) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("surface_projection_for_cell"):
		return terrain_volume_service.surface_projection_for_cell(cell, max_up_cells, max_down_cells)
	return {}

func walkable_surface_cell_near(cell: Vector3i, max_up_cells := 16, max_down_cells := 32) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("walkable_surface_cell_near"):
		return terrain_volume_service.walkable_surface_cell_near(cell, max_up_cells, max_down_cells)
	return surface_projection_for_cell(cell, max_up_cells, max_down_cells)

func terrain_volume_revision() -> int:
	return int(terrain_volume_service.get("revision")) if terrain_volume_service != null else 0

func save_terrain_volume_deltas() -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("save_all_section_deltas"):
		return terrain_volume_service.save_all_section_deltas()
	return {}

func load_terrain_volume_deltas(snapshot_value) -> void:
	if terrain_volume_service != null and terrain_volume_service.has_method("load_section_deltas"):
		terrain_volume_service.load_section_deltas(snapshot_value)

func terrain_volume_chunk_has_edits(chunk_key: Vector2i, chunk_size: int) -> bool:
	if terrain_volume_service != null and terrain_volume_service.has_method("chunk_has_edits"):
		return bool(terrain_volume_service.chunk_has_edits(chunk_key, chunk_size))
	return false

func terrain_volume_chunk_edited_y_bounds(chunk_key: Vector2i, chunk_size: int) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("chunk_edited_y_bounds"):
		return terrain_volume_service.chunk_edited_y_bounds(chunk_key, chunk_size)
	return { "found": false, "count": 0 }

func terrain_volume_mesh_edited_y_bounds_for_region(min_x: int, max_x: int, min_z: int, max_z: int) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("mesh_edited_y_bounds_for_region"):
		return terrain_volume_service.mesh_edited_y_bounds_for_region(min_x, max_x, min_z, max_z)
	return { "found": false, "count": 0 }

func terrain_meshing_y_bounds_for_chunk(
	start_x: int,
	start_z: int,
	chunk_size: int,
	below_surface_cells := 10,
	above_surface_cells := 2,
	border_cells := 2
) -> Dictionary:
	var state := begin_terrain_meshing_bounds_state(
		start_x,
		start_z,
		chunk_size,
		below_surface_cells,
		above_surface_cells,
		border_cells
	)
	var advanced := advance_terrain_meshing_bounds_state(state, 1000.0, int(state.get("sampleColumnCount", 1)))
	while not bool(advanced.get("complete", false)):
		advanced = advance_terrain_meshing_bounds_state(
			advanced.get("state", state),
			1000.0,
			int(state.get("sampleColumnCount", 1))
		)
	var bounds: Dictionary = advanced.get("bounds", {}) if advanced.get("bounds", {}) is Dictionary else {}
	return bounds

func begin_terrain_meshing_bounds_state(
	start_x: int,
	start_z: int,
	chunk_size: int,
	below_surface_cells := 10,
	above_surface_cells := 2,
	border_cells := 2
) -> Dictionary:
	var safe_chunk_size := maxi(1, int(chunk_size))
	var border := maxi(0, int(border_cells))
	var min_sample_x := start_x - border
	var max_sample_x := start_x + safe_chunk_size + border
	var min_sample_z := start_z - border
	var max_sample_z := start_z + safe_chunk_size + border
	var edited_bounds := terrain_volume_mesh_edited_y_bounds_for_region(min_sample_x, max_sample_x, min_sample_z, max_sample_z)
	return {
		"startX": start_x,
		"startZ": start_z,
		"chunkSize": safe_chunk_size,
		"belowSurfaceCells": maxi(0, int(below_surface_cells)),
		"aboveSurfaceCells": maxi(0, int(above_surface_cells)),
		"minSampleX": min_sample_x,
		"maxSampleX": max_sample_x,
		"minSampleZ": min_sample_z,
		"maxSampleZ": max_sample_z,
		"cursorX": min_sample_x,
		"cursorZ": min_sample_z,
		"sampleColumnCount": (max_sample_x - min_sample_x + 1) * (max_sample_z - min_sample_z + 1),
		"minSurfaceY": INF,
		"maxSurfaceY": -INF,
		"editedBounds": edited_bounds,
		"complete": false
	}

func advance_terrain_meshing_bounds_state(state: Dictionary, budget_ms := 2.0, max_columns := 192) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	if state.is_empty() or bool(state.get("complete", false)):
		return {
			"state": state,
			"complete": bool(state.get("complete", false)),
			"bounds": finalized_terrain_meshing_bounds_from_state(state) if bool(state.get("complete", false)) else {},
			"columnsProcessed": 0,
			"elapsedMs": 0.0
		}
	var min_x := int(state.get("minSampleX", 0))
	var max_x := int(state.get("maxSampleX", min_x))
	var min_z := int(state.get("minSampleZ", 0))
	var max_z := int(state.get("maxSampleZ", min_z))
	var cursor_x := int(state.get("cursorX", min_x))
	var cursor_z := int(state.get("cursorZ", min_z))
	var min_surface_y := float(state.get("minSurfaceY", INF))
	var max_surface_y := float(state.get("maxSurfaceY", -INF))
	var processed := 0
	var column_cap := maxi(1, int(max_columns))
	var time_cap := maxf(0.1, float(budget_ms))
	while cursor_z <= max_z:
		var surface_y := terrain_deformed_surface_y_for_cell(Vector3i(cursor_x, 0, cursor_z))
		min_surface_y = minf(min_surface_y, surface_y)
		max_surface_y = maxf(max_surface_y, surface_y)
		processed += 1
		cursor_x += 1
		if cursor_x > max_x:
			cursor_x = min_x
			cursor_z += 1
		if processed >= column_cap:
			break
		if float(Time.get_ticks_usec() - started_usec) / 1000.0 >= time_cap:
			break
	var complete := cursor_z > max_z
	state["cursorX"] = cursor_x
	state["cursorZ"] = cursor_z
	state["minSurfaceY"] = min_surface_y
	state["maxSurfaceY"] = max_surface_y
	state["complete"] = complete
	return {
		"state": state,
		"complete": complete,
		"bounds": finalized_terrain_meshing_bounds_from_state(state) if complete else {},
		"columnsProcessed": processed,
		"elapsedMs": float(Time.get_ticks_usec() - started_usec) / 1000.0
	}

func finalized_terrain_meshing_bounds_from_state(state: Dictionary) -> Dictionary:
	if state.is_empty():
		return {}
	var min_surface_y := float(state.get("minSurfaceY", INF))
	var max_surface_y := float(state.get("maxSurfaceY", -INF))
	if min_surface_y == INF:
		min_surface_y = float(main.MIN_HEIGHT) if main != null else 0.0
		max_surface_y = float(main.MAX_HEIGHT) if main != null else min_surface_y
	var cell := cell_size()
	var bottom_world := float(world_bottom_cell_y()) * cell
	var min_bound := maxf(bottom_world, min_surface_y - float(maxi(0, int(state.get("belowSurfaceCells", 10)))) * cell)
	# Generated cells are sampled at centers while the mesher projects on lattice points.
	var upper_padding_cells := maxi(0, int(state.get("aboveSurfaceCells", 2))) + MESHING_SURFACE_PROJECTION_UPPER_ENVELOPE_CELLS
	var max_bound := max_surface_y + float(upper_padding_cells) * cell
	var edited_bounds: Dictionary = state.get("editedBounds", {}) if state.get("editedBounds", {}) is Dictionary else {}
	if bool(edited_bounds.get("found", false)):
		min_bound = minf(min_bound, maxf(bottom_world, float(int(edited_bounds.get("minY", floori(min_bound / cell))) - 3) * cell))
		max_bound = maxf(max_bound, float(int(edited_bounds.get("maxY", ceili(max_bound / cell))) + 3) * cell)
	return {
		"minY": floori(min_bound / cell),
		"maxY": ceili(max_bound / cell),
		"surfaceMinY": min_surface_y,
		"surfaceMaxY": max_surface_y,
		"editedBounds": edited_bounds
	}

func terrain_volume_edited_mesh_cells_for_chunk(chunk_key: Vector2i, chunk_size: int) -> Array[Vector3i]:
	if terrain_volume_service != null and terrain_volume_service.has_method("edited_mesh_cells_for_chunk"):
		return terrain_volume_service.edited_mesh_cells_for_chunk(chunk_key, chunk_size)
	return []

func terrain_volume_chunk_revision(chunk_key: Vector2i, chunk_size: int) -> int:
	if terrain_volume_service != null and terrain_volume_service.has_method("chunk_revision"):
		return int(terrain_volume_service.chunk_revision(chunk_key, chunk_size))
	return 0

func terrain_fluid_chunk_revision_with_halo(chunk_key: Vector2i, chunk_size: int) -> int:
	if terrain_volume_service != null and terrain_volume_service.has_method("fluid_chunk_revision_with_halo"):
		return int(terrain_volume_service.fluid_chunk_revision_with_halo(chunk_key, chunk_size))
	return 0

func terrain_volume_edit_count(include_non_mesh := true) -> int:
	if terrain_volume_service != null and terrain_volume_service.has_method("edited_cell_count"):
		return int(terrain_volume_service.edited_cell_count(include_non_mesh))
	return 0

func terrain_volume_column_has_mesh_affecting_edits(cell: Vector3i) -> bool:
	if terrain_volume_service != null and terrain_volume_service.has_method("column_has_mesh_affecting_edits"):
		return bool(terrain_volume_service.column_has_mesh_affecting_edits(cell))
	return false

func terrain_volume_column_has_surface_projection_affecting_edits(cell: Vector3i) -> bool:
	if terrain_volume_service != null and terrain_volume_service.has_method("column_has_surface_projection_affecting_edits"):
		return bool(terrain_volume_service.column_has_surface_projection_affecting_edits(cell))
	return terrain_volume_column_has_mesh_affecting_edits(cell)

func terrain_volume_chunk_has_generated_underground_air_boundary(chunk_key: Vector2i, chunk_size: int, step_cells := 4, vertical_step_cells := 4, max_depth_cells := 0) -> bool:
	if terrain_volume_service != null and terrain_volume_service.has_method("chunk_has_generated_underground_air_boundary"):
		return bool(terrain_volume_service.chunk_has_generated_underground_air_boundary(chunk_key, chunk_size, step_cells, vertical_step_cells, max_depth_cells))
	return false

func consume_terrain_volume_dirty_chunk_keys(chunk_size: int) -> Array[Vector2i]:
	if terrain_volume_service != null and terrain_volume_service.has_method("consume_dirty_chunk_keys"):
		return terrain_volume_service.consume_dirty_chunk_keys(chunk_size)
	return []

func set_cell_light(cell: Vector3i, light: Dictionary, reason := "") -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("set_cell_light"):
		return terrain_volume_service.set_cell_light(cell, light, reason)
	return {}

func begin_cell_light_update(cell: Vector3i, light: Dictionary, reason := "", rebuild_radius := -1) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("begin_cell_light_update"):
		return terrain_volume_service.begin_cell_light_update(cell, light, reason, rebuild_radius)
	return {}

func advance_cell_light_update(state: Dictionary, frame_budget_ms := 0.5, max_work_units := 96) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("advance_cell_light_update"):
		return terrain_volume_service.advance_cell_light_update(state, frame_budget_ms, max_work_units)
	return { "state": state, "complete": true, "processedWorkUnits": 0, "elapsedMs": 0.0 }

func set_cell_lights_batch(changes: Array, reason := "") -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("set_cell_lights_batch"):
		return terrain_volume_service.set_cell_lights_batch(changes, reason)
	return {}

func begin_cell_lights_batch(changes: Array, reason := "") -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("begin_cell_lights_batch"):
		return terrain_volume_service.begin_cell_lights_batch(changes, reason)
	return {}

func advance_cell_lights_batch(state: Dictionary, frame_budget_ms := 2.0, max_work_units := 192) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("advance_cell_lights_batch"):
		return terrain_volume_service.advance_cell_lights_batch(state, frame_budget_ms, max_work_units)
	return {}

func process_pending_sky_light_columns(max_columns := 2) -> int:
	if terrain_volume_service != null and terrain_volume_service.has_method("process_pending_sky_light_columns"):
		return int(terrain_volume_service.process_pending_sky_light_columns(max_columns))
	return 0

func pending_sky_light_column_count() -> int:
	if terrain_volume_service != null and terrain_volume_service.has_method("pending_sky_light_column_count"):
		return int(terrain_volume_service.pending_sky_light_column_count())
	return 0

func light_at_cell(cell: Vector3i) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("light_at_cell"):
		return terrain_volume_service.light_at_cell(cell)
	return { "sky": 0, "block": 0 }

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
	if position.y <= float(world_bottom_cell_y() + 2) * cell_size():
		return cell_size()
	if main == null or main.get("ridge_noise") == null:
		return cell_size()
	var s := cell_size()
	var cell_pos := Vector3(position.x / s, position.y / s, position.z / s)
	var ridge = main.get("ridge_noise") as FastNoiseLite
	var height = main.get("height_noise") as FastNoiseLite
	var broad_air := noise3d01(ridge, cell_pos.x * 0.44 + 4100.0, cell_pos.y * 0.58 - 2300.0, cell_pos.z * 0.44 + 1700.0)
	var local_air := noise3d01(height, cell_pos.x * 0.82 - 6200.0, cell_pos.y * 0.76 + 910.0, cell_pos.z * 0.82 + 3600.0) if height != null else broad_air
	var mixed_air := broad_air * 0.66 + local_air * 0.34
	var chamber_air := noise3d01(ridge, cell_pos.x * 0.23 + 8100.0, cell_pos.y * 0.30 - 5400.0, cell_pos.z * 0.23 + 2600.0)
	var porous_a_raw := noise3d01(ridge, cell_pos.x * 0.92 - 7100.0, cell_pos.y * 0.46 + 1900.0, cell_pos.z * 0.74 + 800.0)
	var porous_b_raw := noise3d01(height, cell_pos.x * 0.62 + 2200.0, cell_pos.y * 0.68 - 3600.0, cell_pos.z * 1.00 - 4900.0) if height != null else porous_a_raw
	var porous_air := smoothstep_local(1.0 - absf(porous_a_raw - porous_b_raw), 0.44, 0.82)
	var cellular := underground_cell_hash01(world_to_cell3(position))
	var broad_strength := smoothstep_local(mixed_air, 0.48, 0.72)
	var chamber_strength := smoothstep_local(chamber_air, 0.48, 0.66)
	var porous_strength := porous_air * smoothstep_local(local_air, 0.52, 0.82)
	var chamber_depth := smoothstep_local(depth_cells, 8.0, 18.0) * (1.0 - smoothstep_local(depth_cells, 48.0, 64.0))
	var air_signal := clampf(maxf(maxf(broad_strength, chamber_strength * 0.96), porous_strength * 0.90) + chamber_depth * 0.10 + cellular * 0.025, 0.0, 1.0)
	var minimum_overburden := minimum_overburden_cells_for_position(position)
	if depth_cells <= minimum_overburden:
		return s
	var depth_open := smoothstep_local(
		depth_cells,
		minimum_overburden,
		minimum_overburden + UNDERGROUND_AIR_TRANSITION_DEPTH_CELLS
	)
	var deep_compaction := 1.0 - smoothstep_local(depth_cells, 58.0, 74.0)
	var depth_fade := clampf(depth_open * deep_compaction, 0.0, 1.0)
	var strata := noise3d01(ridge, cell_pos.x * 0.38 - 1400.0, cell_pos.y * 0.62 + 2500.0, cell_pos.z * 0.38 - 3700.0)
	var threshold := lerpf(0.50, 0.60, strata) - chamber_depth * 0.04
	var raw_density := (threshold - air_signal) * s * 4.25
	return lerpf(s, raw_density, depth_fade)


func minimum_overburden_cells_for_position(position: Vector3) -> float:
	var cell := world_to_cell3(position)
	var key := Vector2i(cell.x, cell.z)
	if minimum_overburden_cache.has(key):
		return float(minimum_overburden_cache[key])
	var protected_town_surface := not town_region_for_surface_cell3(Vector3i(cell.x, 0, cell.z)).is_empty()
	var result := TOWN_SURFACE_MIN_OVERBURDEN_CELLS if protected_town_surface else NATURAL_SURFACE_MIN_OVERBURDEN_CELLS
	minimum_overburden_cache[key] = result
	return result

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
	var volume_authority := terrain_volume_service != null
	if volume_authority:
		if not bool(brush.get("visualOnly", false)):
			register_volume_brush_cell_edits(brush)
	elif LEGACY_BRUSH_TERRAIN_AUTHORITY_ENABLED:
		excavation_brushes.append(brush.duplicate(true))
	surface_projection_cache.clear()
	deformed_surface_y_cache.clear()

func clear_excavation_brushes() -> void:
	excavation_brushes.clear()
	surface_projection_cache.clear()
	deformed_surface_y_cache.clear()

func reset_terrain_volume_authority() -> void:
	excavation_brushes.clear()
	if terrain_volume_service != null and terrain_volume_service.has_method("reset"):
		terrain_volume_service.reset()
	surface_projection_cache.clear()
	deformed_surface_y_cache.clear()

func register_volume_brush_cell_edits(brush: Dictionary) -> void:
	if terrain_volume_service == null or not terrain_volume_service.has_method("apply_sphere_edit"):
		return
	var center: Vector3 = brush.get("center", Vector3.ZERO)
	var radius := float(brush.get("radius", 0.0))
	if brush_is_surface_deformation(brush):
		if radius <= 0.0:
			radius = cell_size()
		terrain_volume_service.apply_sphere_edit(center, radius, {
			"material": "air",
			"biome": UNDERGROUND_AIR_BIOME,
			"solid": false,
			"fluid": "",
			"light": { "sky": 0, "block": 0 },
			"metadata": { "source": "surface_excavation" }
		}, String(brush.get("id", "surface_excavation")))
		return
	if not brush_uses_volume_subtraction(brush):
		return
	if radius <= 0.0:
		return
	terrain_volume_service.apply_sphere_edit(center, radius, {
		"material": "air",
		"biome": UNDERGROUND_AIR_BIOME,
		"solid": false,
		"fluid": "",
		"light": { "sky": 0, "block": 0 },
		"metadata": { "source": "excavation" }
	}, String(brush.get("id", "excavation")))

func volume_cell3_from_world(position: Vector3) -> Vector3i:
	var s := cell_size()
	return Vector3i(floori(position.x / s), floori(position.y / s), floori(position.z / s))

func surface_y_at(position: Vector3) -> float:
	var cell := volume_cell3_from_world(position)
	return volume_surface_y_for_cell(Vector3i(cell.x, 0, cell.z))

func surface_y_for_cell(cell: Vector3i) -> float:
	return volume_surface_y_for_cell(cell)

func volume_surface_y_for_cell(cell: Vector3i) -> float:
	var key := Vector2i(cell.x, cell.z)
	if surface_projection_cache.has(key):
		return float(surface_projection_cache[key])
	var reference_y := terrain_deformed_surface_y_for_cell(cell)
	var reference_cell_y := floori(reference_y / cell_size())
	var high := mini(world_top_cell_y(), reference_cell_y + 8)
	var low := world_bottom_cell_y()
	for y in range(high, low, -1):
		var solid_numeric := volume_surface_numeric_sample_at_grid_cell(Vector3i(cell.x, y, cell.z))
		if solid_numeric.x < 0.0:
			continue
		var air_numeric := volume_surface_numeric_sample_at_grid_cell(Vector3i(cell.x, y + 1, cell.z))
		if air_numeric.x < 0.0:
			var projected_y := surface_boundary_y_between_numeric_samples(y, solid_numeric.x, air_numeric.x)
			surface_projection_cache[key] = projected_y
			return projected_y
	var fallback := terrain_reference_surface_y_for_cell(cell)
	surface_projection_cache[key] = fallback
	return fallback

func terrain_state_affects_surface_projection(state_value) -> bool:
	if not (state_value is Dictionary):
		return true
	var state: Dictionary = state_value
	var metadata: Dictionary = state.get("metadata", {}) if state.get("metadata", {}) is Dictionary else {}
	if bool(metadata.get("renderedBySceneBlock", false)):
		return false
	var source := String(metadata.get("source", ""))
	if source == "scene_block" or source.begins_with("structure_"):
		return false
	if metadata.has("terrainMeshAffects"):
		return bool(metadata.get("terrainMeshAffects", true))
	return true

func surface_boundary_y_between_numeric_samples(solid_cell_y: int, solid_density: float, air_density: float) -> float:
	var denominator := solid_density - air_density
	if absf(denominator) <= 0.0001:
		return float(solid_cell_y + 1) * cell_size()
	# VoxelTerrainGenerator writes these numeric samples at integer lattice positions.
	var solid_lattice_y := float(solid_cell_y) * cell_size()
	var air_lattice_y := float(solid_cell_y + 1) * cell_size()
	var t := clampf(solid_density / denominator, 0.0, 1.0)
	return lerp(solid_lattice_y, air_lattice_y, t)

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
	var cell := volume_cell3_from_world(position)
	return terrain_reference_surface_y_for_cell(Vector3i(cell.x, 0, cell.z))

func terrain_reference_surface_y_for_cell(cell: Vector3i) -> float:
	return base_surface_y_for_cell(cell)

func terrain_deformed_surface_y_at(position: Vector3) -> float:
	var cell := volume_cell3_from_world(position)
	return terrain_deformed_surface_y_for_cell(Vector3i(cell.x, 0, cell.z))

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
		var natural := town_apron_outer_surface_y(town, cell, distance, radius, apron)
		var blend := clampf((distance - radius) / maxf(1.0, apron), 0.0, 1.0)
		var eased := blend * blend * (3.0 - 2.0 * blend)
		var value: float = lerp(level, natural, eased)
		base_surface_y_cache[key] = value
		return value
	var value: float = natural_surface_y_for_cell(cell)
	base_surface_y_cache[key] = value
	return value

func town_apron_outer_surface_y(town: Dictionary, cell: Vector3i, distance: float, radius: float, apron: float) -> float:
	var center_x := int(town.get("centerX", 0))
	var center_z := int(town.get("centerZ", 0))
	var delta := Vector2(float(cell.x - center_x), float(cell.z - center_z))
	if distance <= 0.001:
		return natural_surface_y_for_cell(cell)
	var direction := delta / distance
	var sample_distance := radius + apron
	var outer_cell := Vector3i(
		center_x + roundi(direction.x * sample_distance),
		0,
		center_z + roundi(direction.y * sample_distance)
	)
	return natural_surface_y_for_cell(outer_cell)

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
	var biome := regional_surface_biome_for_cell3(cell)
	surface_biome_cache[key] = biome
	return biome

func regional_surface_biome_for_cell3(cell: Vector3i) -> String:
	var h: float = terrain_reference_surface_y_for_cell(cell)
	if h < float(main.WATER_LEVEL) + 0.3:
		return "ocean"
	if h < float(main.WATER_LEVEL) + 1.7:
		return "beach"
	return String(biome_region_for_cell3(cell).get("biome", "plains"))

func biome_at_volume_cell(cell: Vector3i) -> String:
	return biome_at(Vector3((float(cell.x) + 0.5) * cell_size(), (float(cell.y) + 0.5) * cell_size(), (float(cell.z) + 0.5) * cell_size()))

func biome_at_world(world_pos: Vector3) -> String:
	return biome_at(world_pos)

func material_at_cell3(cell: Vector3i) -> String:
	return material_at(Vector3((float(cell.x) + 0.5) * cell_size(), (float(cell.y) + 0.5) * cell_size(), (float(cell.z) + 0.5) * cell_size()))

func solid_at_world(world_pos: Vector3, active_plan_records = null, extra_excavation_brushes := []) -> bool:
	return solid_at(world_pos)

func is_air_at_world(world_pos: Vector3, active_plan_records = null, extra_excavation_brushes := []) -> bool:
	return not solid_at(world_pos)

func terrain_surface_y_at(position: Vector3) -> float:
	return surface_y_at(position)

func find_underground_air_sample(search_radius := 16, min_depth_cells := 4, max_depth_cells := UNDERGROUND_AIR_DEFAULT_SEARCH_DEPTH_CELLS) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("find_underground_air_sample"):
		return terrain_volume_service.find_underground_air_sample(search_radius, min_depth_cells, max_depth_cells)
	var radius_cells := maxi(UNDERGROUND_AIR_SEARCH_STEP_CELLS, int(search_radius))
	var min_depth := maxi(1, int(min_depth_cells))
	var max_depth := maxi(min_depth, int(max_depth_cells))
	var step := UNDERGROUND_AIR_SEARCH_STEP_CELLS
	var depth_step := 1
	if radius_cells > 64 or max_depth - min_depth > 36:
		depth_step = UNDERGROUND_AIR_SEARCH_STEP_CELLS
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
				var column_max_depth := mini(max_depth, maxi(min_depth, floori(surface_y / cell_size()) - world_bottom_cell_y() - 2))
				for depth in range(min_depth, column_max_depth + 1, depth_step):
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
	if terrain_volume_service != null and terrain_volume_service.has_method("underground_air_sample_has_solid_boundary"):
		return terrain_volume_service.underground_air_sample_has_solid_boundary(cell)
	return int(underground_air_sample_boundary_summary(cell).get("solidNeighbors", 0)) >= 2

func underground_air_connected_region_summary(start_cell: Vector3i, max_cells := 96, max_radius := UNDERGROUND_AIR_CONNECTIVITY_RADIUS_CELLS) -> Dictionary:
	if terrain_volume_service != null and terrain_volume_service.has_method("underground_air_connected_region_summary"):
		return terrain_volume_service.underground_air_connected_region_summary(start_cell, max_cells, max_radius)
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
	if terrain_volume_service != null and terrain_volume_service.has_method("underground_air_sample_boundary_summary"):
		return terrain_volume_service.underground_air_sample_boundary_summary(cell)
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

func underground_air_sample_has_surface_exposure(cell: Vector3i, max_cells := 512, max_radius := 32) -> bool:
	if terrain_volume_service != null and terrain_volume_service.has_method("underground_air_sample_has_surface_exposure"):
		return bool(terrain_volume_service.underground_air_sample_has_surface_exposure(cell, max_cells, max_radius))
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
	var radius: int = int(town.get("radius", main.TOWN_RADIUS_CELLS))
	var center_x: int = int(town.get("centerX", 0))
	var center_z: int = int(town.get("centerZ", 0))
	var level: float = float(town.get("level", float(main.WATER_LEVEL) + 3.0))
	var cache_value = main.get("town_slope_apron_cache")
	var cache: Dictionary = cache_value if cache_value is Dictionary else {}
	var key := Vector2i(int(town.get("regionX", 0)), int(town.get("regionZ", 0)))
	var signature := "%d:%d:%d:%d" % [center_x, center_z, radius, roundi(level * 1000.0)]
	if cache.has(key):
		var cached_value = cache[key]
		if cached_value is Dictionary:
			var cached: Dictionary = cached_value
			if int(cached.get("version", 0)) == TOWN_SLOPE_APRON_CACHE_VERSION and String(cached.get("signature", "")) == signature:
				return int(cached.get("apron", 18))
		cache.erase(key)
		base_surface_y_cache.clear()
		deformed_surface_y_cache.clear()
		surface_projection_cache.clear()
		surface_biome_cache.clear()
	var apron: int = maxi(18, ceili(float(radius) * 0.55))
	var max_apron: int = maxi(apron, 128)
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
		var needed: int = ceili(max_diff / maxf(0.01, cell_size() * 0.52)) + 6
		var next_apron: int = mini(max_apron, maxi(apron, needed))
		if next_apron == apron:
			break
		apron = next_apron
	cache[key] = {
		"version": TOWN_SLOPE_APRON_CACHE_VERSION,
		"signature": signature,
		"apron": apron
	}
	main.set("town_slope_apron_cache", cache)
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

func underground_fluid_for_cell(cell: Vector3i, position: Vector3, _depth: float, depth_cells: float, surface_biome: String) -> String:
	if main == null:
		return ""
	if depth_cells < 6.0:
		return ""
	var seed := String(main.get("seed_text"))
	var bottom_y := world_bottom_cell_y()
	if cell.y <= bottom_y + 9 and depth_cells >= 34.0:
		var lava_noise: float = float(main.hash01("terrain-volume-lava:%s:%d,%d,%d" % [seed, floori(float(cell.x) / 4.0), floori(float(cell.y) / 2.0), floori(float(cell.z) / 4.0)]))
		if lava_noise > 0.82:
			return "lava"
	if position.y <= float(main.WATER_LEVEL) - cell_size() * 1.5 and surface_biome != "desert":
		var aquifer_noise: float = float(main.hash01("terrain-volume-aquifer:%s:%d,%d,%d" % [seed, floori(float(cell.x) / 5.0), floori(float(cell.y) / 3.0), floori(float(cell.z) / 5.0)]))
		if aquifer_noise > 0.88:
			return "water"
	return ""

func surface_color_for_cell3(cell: Vector3i) -> Color:
	var biome := surface_biome_for_cell3(cell)
	if biome == "town":
		return Color(0.43, 0.53, 0.32)
	if biome == "beach" or biome == "desert":
		return Color(0.76, 0.67, 0.42)
	if biome == "swamp":
		return Color(0.28, 0.39, 0.22)
	if biome == "snow":
		return Color(0.77, 0.82, 0.82)
	if biome == "alpine" or biome == "tundra":
		return Color(0.34, 0.35, 0.31)
	if biome == UNDERGROUND_AIR_BIOME or biome == "underground":
		return Color(0.18, 0.17, 0.14)
	if biome == "savanna":
		return Color(0.55, 0.58, 0.29)
	if biome == "forest" or biome == "taiga":
		return Color(0.34, 0.53, 0.29)
	return Color(0.43, 0.62, 0.32)

func world_to_cell3(position: Vector3) -> Vector3i:
	var s := cell_size()
	return Vector3i(floori(position.x / s), floori(position.y / s), floori(position.z / s))

func merged_excavation_brushes(extra_excavation_brushes) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if LEGACY_BRUSH_TERRAIN_AUTHORITY_ENABLED:
		for brush in excavation_brushes:
			result.append(brush)
	if LEGACY_BRUSH_TERRAIN_AUTHORITY_ENABLED and extra_excavation_brushes is Array:
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

func world_bottom_cell_y() -> int:
	return WORLD_BOTTOM_CELL_Y

func generated_fluid_cell_y_bounds() -> Dictionary:
	return {
		"minY": world_bottom_cell_y(),
		"maxY": ceili(float(main.WATER_LEVEL) / cell_size()) if main != null else 0
	}

func world_top_cell_y() -> int:
	var max_height := float(main.MAX_HEIGHT) if main != null else 96.0
	return ceili((max_height + cell_size() * 4.0) / cell_size())
