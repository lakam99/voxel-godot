extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const DEFAULT_CENTER := Vector2i(257, 20)
const DEFAULT_RADIUS_CELLS := 80
const WATER_STEP_CELLS := 4
const CELL := 1.35
const WATER_LEVEL := 11.1

var main: Node3D

func _ready() -> void:
	call_deferred("run")

func run() -> void:
	main = MAIN_SCENE.instantiate()
	main.set("render_distance", 0)
	main.set("visual_quality", {
		"decorativeDensity": 0.0,
		"decorativeDetailCap": 0,
		"foliageSway": 0.0,
		"particleDensity": 0.0
	})
	add_child(main)
	if not await wait_for_world_generation(900):
		write_report({
			"schemaVersion": 1,
			"kind": "terrain_water_classification_probe",
			"passed": false,
			"reason": "world_generation_not_ready"
		})
		get_tree().quit(1)
		return
	main.set_process(false)
	main.set_physics_process(false)
	var report := build_probe_report()
	write_report(report)
	get_tree().quit(0)

func wait_for_world_generation(max_frames: int) -> bool:
	for _frame in range(max_frames):
		if main != null and main.get("world_generation_system") != null:
			return true
		await get_tree().process_frame
	return false

func build_probe_report() -> Dictionary:
	var center := probe_center()
	var radius := probe_radius()
	var water_level := WATER_LEVEL
	var threshold := water_level + 0.30
	var generator = main.get("world_generation_system")
	var water_quads := 0
	var clean_water_quads := 0
	var overlap_quads := 0
	var covered_cells := 0
	var covered_dry_cells := 0
	var severe_overlap_quads := 0
	var highest_covered_dry_height := -INF
	var worst: Array[Dictionary] = []
	for quad_z in range(center.y - radius, center.y + radius, WATER_STEP_CELLS):
		for quad_x in range(center.x - radius, center.x + radius, WATER_STEP_CELLS):
			var sample_cell := Vector2i(quad_x + WATER_STEP_CELLS / 2, quad_z + WATER_STEP_CELLS / 2)
			var sample_height := reference_height(generator, sample_cell)
			if sample_height > threshold:
				continue
			water_quads += 1
			var dry_cells := 0
			var max_height := -INF
			var max_delta := 0.0
			var biomes := {}
			for local_z in range(WATER_STEP_CELLS):
				for local_x in range(WATER_STEP_CELLS):
					covered_cells += 1
					var cell := Vector2i(quad_x + local_x, quad_z + local_z)
					var height := reference_height(generator, cell)
					max_height = maxf(max_height, height)
					if height <= threshold:
						continue
					dry_cells += 1
					covered_dry_cells += 1
					highest_covered_dry_height = maxf(highest_covered_dry_height, height)
					max_delta = maxf(max_delta, height - water_level)
					var biome := reference_biome(generator, cell)
					biomes[biome] = int(biomes.get(biome, 0)) + 1
			if dry_cells == 0:
				clean_water_quads += 1
				continue
			overlap_quads += 1
			if max_delta >= CELL:
				severe_overlap_quads += 1
			var row := {
				"quadMinCell": [quad_x, quad_z],
				"quadMaxCell": [quad_x + WATER_STEP_CELLS - 1, quad_z + WATER_STEP_CELLS - 1],
				"sampleCell": [sample_cell.x, sample_cell.y],
				"sampleHeight": rounded(sample_height),
				"dryCellsCovered": dry_cells,
				"maxCoveredHeight": rounded(max_height),
				"maxHeightAboveWater": rounded(max_delta),
				"dryBiomes": biomes
			}
			insert_worst(worst, row, 24)
	var water_material := water_material_summary()
	var terrain_material := terrain_material_summary()
	var terrain_meshing := terrain_meshing_summary(center)
	return {
		"schemaVersion": 1,
		"kind": "terrain_water_classification_probe",
		"passed": true,
		"diagnosticOnly": true,
		"seed": String(main.get("seed_text")),
		"centerCell": [center.x, center.y],
		"radiusCells": radius,
		"waterStepCells": WATER_STEP_CELLS,
		"waterLevel": rounded(water_level),
		"classificationThreshold": rounded(threshold),
		"waterQuads": water_quads,
		"cleanWaterQuads": clean_water_quads,
		"overlapQuads": overlap_quads,
		"severeOverlapQuads": severe_overlap_quads,
		"overlapQuadRate": rounded(float(overlap_quads) / maxf(1.0, float(water_quads))),
		"coveredCells": covered_cells,
		"coveredDryCells": covered_dry_cells,
		"coveredDryCellRate": rounded(float(covered_dry_cells) / maxf(1.0, float(covered_cells))),
		"highestCoveredDryHeight": rounded(highest_covered_dry_height) if highest_covered_dry_height > -INF else null,
		"worstOverlaps": worst,
		"waterMaterial": water_material,
		"terrainMaterial": terrain_material,
		"terrainMeshing": terrain_meshing,
		"classificationContract": "one center sample classifies an entire 4x4-cell water quad"
	}

func probe_center() -> Vector2i:
	var raw := OS.get_environment("VOXEL_TERRAIN_WATER_PROBE_CENTER").strip_edges()
	var parts := raw.split(",")
	if parts.size() >= 2:
		return Vector2i(int(parts[0]), int(parts[1]))
	return DEFAULT_CENTER

func probe_radius() -> int:
	var raw := OS.get_environment("VOXEL_TERRAIN_WATER_PROBE_RADIUS").strip_edges()
	if raw == "":
		return DEFAULT_RADIUS_CELLS
	return maxi(WATER_STEP_CELLS, int(raw))

func reference_height(generator, cell: Vector2i) -> float:
	return float(generator.terrain_reference_surface_y_for_cell(Vector3i(cell.x, 0, cell.y)))

func reference_biome(generator, cell: Vector2i) -> String:
	return String(generator.surface_biome_for_cell3(Vector3i(cell.x, 0, cell.y)))

func insert_worst(rows: Array[Dictionary], row: Dictionary, limit: int) -> void:
	rows.append(row)
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("maxHeightAboveWater", 0.0)) > float(b.get("maxHeightAboveWater", 0.0))
	)
	if rows.size() > limit:
		rows.resize(limit)

func water_material_summary() -> Dictionary:
	var materials: Dictionary = main.get("materials") if main.get("materials") is Dictionary else {}
	var material = materials.get("water")
	if material == null:
		return { "present": false }
	var result := {
		"present": true,
		"class": material.get_class(),
		"resourcePath": material.resource_path
	}
	if material is ShaderMaterial:
		var shader_material := material as ShaderMaterial
		result["shaderPath"] = shader_material.shader.resource_path if shader_material.shader != null else ""
		result["alphaBase"] = float(shader_material.get_shader_parameter("alpha_base"))
	return result

func terrain_material_summary() -> Dictionary:
	var material = main.get("terrain_material")
	if material == null:
		return { "present": false }
	var result := {
		"present": true,
		"class": material.get_class(),
		"resourcePath": material.resource_path
	}
	if material is ShaderMaterial:
		var shader_material := material as ShaderMaterial
		result["shaderPath"] = shader_material.shader.resource_path if shader_material.shader != null else ""
	return result

func terrain_meshing_summary(center: Vector2i) -> Dictionary:
	var result := {
		"centerChunk": [floori(float(center.x) / 28.0), floori(float(center.y) / 28.0)],
		"chunkMap": []
	}
	var service = main.get("terrain_meshing_service")
	if service != null and service.has_method("backend_summary"):
		result["backend"] = service.call("backend_summary")
	var start_x := floori(float(center.x) / 28.0) * 28
	var start_z := floori(float(center.y) / 28.0) * 28
	if main.has_method("chunk_needs_generated_underground_volume_mesh"):
		result["generatedVolumeRequired"] = bool(main.call("chunk_needs_generated_underground_volume_mesh", start_x, start_z))
	if main.has_method("chunk_has_terrain_volume_edits"):
		result["hasTerrainVolumeEdits"] = bool(main.call("chunk_has_terrain_volume_edits", start_x, start_z))
	if main.has_method("chunk_has_excavation_overlap"):
		result["hasExcavationOverlap"] = bool(main.call("chunk_has_excavation_overlap", start_x, start_z))
	var center_chunk := Vector2i(floori(float(center.x) / 28.0), floori(float(center.y) / 28.0))
	var rows: Array[Dictionary] = []
	for chunk_z in range(center_chunk.y - 3, center_chunk.y + 4):
		for chunk_x in range(center_chunk.x - 3, center_chunk.x + 4):
			var chunk_start_x := chunk_x * 28
			var chunk_start_z := chunk_z * 28
			var row := {
				"chunk": [chunk_x, chunk_z],
				"hasTerrainVolumeEdits": bool(main.call("chunk_has_terrain_volume_edits", chunk_start_x, chunk_start_z)),
				"townSurfaceEdge": bool(main.call("chunk_has_town_surface_volume_edge", chunk_start_x, chunk_start_z)),
				"generatedSurfaceExposure": bool(main.call("chunk_has_generated_surface_volume_exposure", chunk_start_x, chunk_start_z)),
				"requiresVolume": bool(main.call("chunk_needs_generated_underground_volume_mesh", chunk_start_x, chunk_start_z)),
				"meshStepCells": int(main.call("underground_volume_mesh_step_for_chunk", chunk_start_x, chunk_start_z))
			}
			row["meshStepWorldMeters"] = rounded(float(row["meshStepCells"]) * CELL)
			row["generatedFluid"] = generated_fluid_summary(chunk_start_x, chunk_start_z)
			rows.append(row)
	result["chunkMap"] = rows
	return result

func generated_fluid_summary(start_x: int, start_z: int) -> Dictionary:
	var generator = main.get("world_generation_system")
	if generator == null or not generator.has_method("sample_cell"):
		return { "sampleCount": 0 }
	var bottom_y := int(generator.call("world_bottom_cell_y"))
	var sample_count := 0
	var first_cell = null
	var ids := {}
	for z in range(start_z, start_z + 28, 4):
		for x in range(start_x, start_x + 28, 4):
			for y in range(bottom_y + 2, 8):
				var sample: Dictionary = generator.call("sample_cell", Vector3i(x, y, z))
				var fluid_id := String(sample.get("fluid", ""))
				if fluid_id == "" or bool(sample.get("solid", false)):
					continue
				sample_count += 1
				ids[fluid_id] = int(ids.get(fluid_id, 0)) + 1
				if first_cell == null:
					first_cell = [x, y, z]
	return {
		"sampleCount": sample_count,
		"ids": ids,
		"firstCell": first_cell
	}

func write_report(report: Dictionary) -> void:
	var path := OS.get_environment("VOXEL_TERRAIN_WATER_PROBE_REPORT").strip_edges()
	if path == "":
		path = ProjectSettings.globalize_path("res://artifacts/vox43-repro/water-classification-probe.json")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))

func rounded(value: float) -> float:
	return snappedf(value, 0.001)
