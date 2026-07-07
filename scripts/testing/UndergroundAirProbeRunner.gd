extends SceneTree

const WorldGenerationSystemScript := preload("res://scripts/WorldGenerationSystem.gd")
const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")

class FakeMain:
	const CELL := 1.35
	const MIN_HEIGHT := 4.0
	const MAX_HEIGHT := 120.0
	const WATER_LEVEL := 11.1
	const TOWN_REGION_CELLS := 280
	const TOWN_RADIUS_CELLS := 30

	var seed_text := "atlas-1492"
	var seed_hash := 0
	var height_noise: FastNoiseLite
	var ridge_noise: FastNoiseLite
	var flat_noise: FastNoiseLite
	var moisture_noise: FastNoiseLite
	var temp_noise: FastNoiseLite
	var town_slope_apron_cache := {}
	var world_generation_system

	func _init() -> void:
		setup_noise()

	func setup_noise() -> void:
		seed_hash = hash_string(seed_text)
		height_noise = make_noise(17, 0.0058, 4)
		ridge_noise = make_noise(43, 0.014, 3)
		flat_noise = make_noise(71, 0.0024, 3)
		moisture_noise = make_noise(107, 0.006, 3)
		temp_noise = make_noise(131, 0.005, 3)

	func make_noise(salt: int, frequency: float, octaves: int) -> FastNoiseLite:
		var noise := FastNoiseLite.new()
		noise.seed = int((seed_hash + salt * 7919) & 0x7fffffff)
		noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
		noise.frequency = frequency
		noise.fractal_octaves = octaves
		noise.fractal_gain = 0.5
		noise.fractal_lacunarity = 2.0
		return noise

	func town_region(_region_x: int, _region_z: int) -> Dictionary:
		return {}

	func noise01(noise: FastNoiseLite, x: float, z: float) -> float:
		return noise.get_noise_2d(x, z) * 0.5 + 0.5

	func smoothstep_range(value: float, low: float, high: float) -> float:
		if high == low:
			return 1.0 if value >= high else 0.0
		var t: float = clamp((value - low) / (high - low), 0.0, 1.0)
		return t * t * (3.0 - 2.0 * t)

	func hash01(text: String) -> float:
		return float(abs(hash_string("%s:%s" % [seed_text, text])) % 100000) / 100000.0

	func hash_string(text: String) -> int:
		var h := 2166136261
		for i in range(text.length()):
			h = int((h ^ text.unicode_at(i)) * 16777619) & 0xffffffff
		return h

var main
var world_generation

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var seed := OS.get_environment("VOXEL_TEST_SEED").strip_edges()
	if seed == "":
		seed = "atlas-1492"
	if OS.get_environment("VOXEL_UNDERGROUND_AIR_PROBE_REAL_SCENE").strip_edges() == "1":
		OS.set_environment("VOXEL_TEST_SEED", seed)
		OS.set_environment("VOXEL_PLAYTEST", "1")
		main = MAIN_SCENE.instantiate()
		main.set("render_distance", 1)
		root.add_child(main)
		await process_frame
		await process_frame
		main.set_process(false)
		main.set_physics_process(false)
		world_generation = main.get("world_generation_system")
	else:
		main = FakeMain.new()
		main.seed_text = seed
		main.setup_noise()
		world_generation = WorldGenerationSystemScript.new()
		world_generation.setup(main)
		main.world_generation_system = world_generation
	var report := {}
	if OS.get_environment("VOXEL_UNDERGROUND_AIR_PROBE_FIND_ONLY").strip_edges() == "1":
		var found: Dictionary = world_generation.find_underground_air_sample(48, 12, 36)
		report = {
			"seed": seed,
			"realScene": OS.get_environment("VOXEL_UNDERGROUND_AIR_PROBE_REAL_SCENE").strip_edges() == "1",
			"findOnly": true,
			"found": found
		}
	else:
		report = probe(seed)
	var report_path := OS.get_environment("VOXEL_UNDERGROUND_AIR_PROBE_REPORT").strip_edges()
	if report_path != "":
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
	print(JSON.stringify(report, "\t"))
	quit(0)

func probe(seed: String) -> Dictionary:
	var radius := int(OS.get_environment("VOXEL_UNDERGROUND_AIR_PROBE_RADIUS").strip_edges())
	if radius <= 0:
		radius = 48
	var column_step := 4
	var depths := [4, 8, 12, 16, 20, 24, 28, 32, 36]
	var by_depth := {}
	for depth in depths:
		by_depth[depth] = {
			"air": 0,
			"fluid": 0,
			"solidBoundary2": 0,
			"solidBoundary3": 0,
			"connected24": 0,
			"best": {}
		}
	var total_columns := 0
	for z in range(-radius, radius + 1, column_step):
		for x in range(-radius, radius + 1, column_step):
			total_columns += 1
			var surface_cell := Vector3i(x, 0, z)
			var biome := String(world_generation.surface_biome_for_cell3(surface_cell))
			if biome in ["ocean", "beach", "town"]:
				continue
			var surface_y := float(world_generation.terrain_reference_surface_y_for_cell(surface_cell))
			for depth in depths:
				var position := Vector3(float(x) * main.CELL, surface_y - float(depth) * main.CELL, float(z) * main.CELL)
				var sample: Dictionary = world_generation.sample_world(position)
				if String(sample.get("biome", "")) != "underground_air" or bool(sample.get("solid", true)):
					continue
				var row: Dictionary = by_depth[depth]
				row["air"] = int(row.get("air", 0)) + 1
				if String(sample.get("fluid", "")) != "":
					row["fluid"] = int(row.get("fluid", 0)) + 1
					continue
				var cell: Vector3i = world_generation.world_to_cell3(position)
				var boundary: Dictionary = world_generation.underground_air_sample_boundary_summary(cell)
				var solid_neighbors := int(boundary.get("solidNeighbors", 0))
				if solid_neighbors >= 2:
					row["solidBoundary2"] = int(row.get("solidBoundary2", 0)) + 1
				if solid_neighbors >= 3:
					row["solidBoundary3"] = int(row.get("solidBoundary3", 0)) + 1
				var connected: Dictionary = world_generation.underground_air_connected_region_summary(cell, 96, 8)
				if int(connected.get("airCells", 0)) >= 24:
					row["connected24"] = int(row.get("connected24", 0)) + 1
					if (row.get("best", {}) as Dictionary).is_empty():
						row["best"] = {
							"cell": cell,
							"surfaceCell": Vector2i(x, z),
							"surfaceY": surface_y,
							"sample": sample,
							"boundary": boundary,
							"connected": connected
						}
	var find12: Dictionary = world_generation.find_underground_air_sample(48, 12, 36)
	return {
		"seed": seed,
		"realScene": OS.get_environment("VOXEL_UNDERGROUND_AIR_PROBE_REAL_SCENE").strip_edges() == "1",
		"radius": radius,
		"columnStep": column_step,
		"totalColumns": total_columns,
		"byDepth": by_depth,
		"find12": find12
	}
