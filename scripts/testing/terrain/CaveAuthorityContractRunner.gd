extends SceneTree

const CONTEXT := preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const GENERATION := preload("res://scripts/WorldGenerationSystem.gd")
const WORKER := preload("res://scripts/terrain/VoxelTerrainGenerator.gd")
var results: Array = []

func _initialize() -> void:
	call_deferred("run")

func make_world(seed_value: String):
	var context = CONTEXT.new()
	context.seed_text = seed_value
	context.seed_hash = context.hash_string(seed_value)
	context.setup_noise()
	var world = GENERATION.new()
	world.setup(context)
	context.set_generator(world)
	return world

func run() -> void:
	for seed_value in ["cave-master-20260903", "atlas-1492", "cave-contract-417", "cave-contract-928"]:
		var world = make_world(seed_value)
		var failures: Array = []
		var recipe := {}
		for rz in range(-2, 3):
			for rx in range(-2, 3):
				if recipe.is_empty():
					recipe = world.cave_recipe_for_region(Vector2i(rx, rz))
		if recipe.is_empty():
			results.append({"seed": seed_value, "passed": false, "failures": ["no_recipe"]})
			continue
		var entry: Vector3 = recipe.entry
		var origin := Vector3i((entry / (1.35 * 16.0)).floor()) * 16
		var worker = WORKER.new()
		worker.setup(world.main)
		var buffer := VoxelBuffer.new()
		buffer.create(16, 16, 16)
		var started := Time.get_ticks_usec()
		worker._generate_block(buffer, origin, 0)
		var generation_ms := float(Time.get_ticks_usec() - started) / 1000.0
		var samples: Array = []
		var encoded_reference := VoxelBuffer.new()
		encoded_reference.create(1, 1, 1)
		encoded_reference.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
		for z in range(0, 16, 2):
			for y in range(0, 16, 2):
				for x in range(0, 16, 2):
					var p := Vector3(origin + Vector3i(x, y, z)) * 1.35
					var surface: float = world.terrain_reference_surface_y_at(p)
					var density: float = world.density_from_components(p, surface, surface)
					var worker_density := -buffer.get_voxel_f(x, y, z, VoxelBuffer.CHANNEL_SDF)
					# Compare through the backend's actual SDF encoding: samples near
					# zero can quantize to zero without a generation disagreement.
					encoded_reference.set_voxel_f(-density / 1.35, 0, 0, 0, VoxelBuffer.CHANNEL_SDF)
					var encoded_density := -encoded_reference.get_voxel_f(0, 0, 0, VoxelBuffer.CHANNEL_SDF)
					if worker_density != encoded_density:
						failures.append("worker_density_mismatch:%s" % p)
						print("CAVE WORKER MISMATCH ", p, " expected=", encoded_density, " worker=", worker_density)
					samples.append({"position": p, "density": density})
		# Rebuild after cache eviction and visit samples in the opposite order.
		for index in range(130):
			world.cave_recipe_for_region(Vector2i(100 + index, 100))
		if world.cave_field.cache_evictions < 1:
			failures.append("cache_eviction_not_exercised")
		samples.reverse()
		for sample in samples:
			var p: Vector3 = sample.position
			var surface: float = world.terrain_reference_surface_y_at(p)
			if world.density_from_components(p, surface, surface) != sample.density:
				failures.append("query_order_changed_density")
		if not (world.save_terrain_volume_deltas().sections as Array).is_empty():
			failures.append("generated_caves_serialized_as_edits")
		var floor_point: Vector3 = recipe.route.back()
		var cell := Vector3i(((floor_point - Vector3.UP * 4.0) / 1.35).floor())
		if not bool(world.get_cell_state(cell).solid):
			failures.append("edit_setup_not_rock")
		world.set_cell_state(cell, {"solid": false, "material": "air", "biome": "underground_air", "density": -1.35, "fluid": "", "light": {"sky": 0, "block": 0}}, "cave_contract_dig")
		var serialized := JSON.stringify(world.save_terrain_volume_deltas())
		var restored = make_world(seed_value)
		restored.load_terrain_volume_deltas(JSON.parse_string(serialized))
		var restored_cell: Dictionary = restored.get_cell_state(cell)
		if bool(restored_cell.solid) or String(restored_cell.material) != "air" or not bool(restored_cell.edited):
			failures.append("saved_dig_not_restored")
		if restored.cave_recipe_for_region(recipe.region) != recipe:
			failures.append("save_restore_changed_generated_cave")
		var solid_count := 0
		var air_count := 0
		for z in range(-96, 97, 8):
			for x in range(-96, 97, 8):
				var p := Vector3(float(x), -40.0, float(z))
				var surface: float = world.terrain_reference_surface_y_at(p)
				if world.density_from_components(p, surface, surface) < 0:
					air_count += 1
				else:
					solid_count += 1
		if air_count == 0 or solid_count == 0:
			failures.append("deep_noise_missing_air_or_rock")
		results.append({"seed": seed_value, "passed": failures.is_empty(), "failures": failures, "workerSamples": samples.size(), "blockGenerationMs": generation_ms, "recipeBuilds": world.cave_field.recipe_build_count, "recipeBuildTotalMs": float(world.cave_field.recipe_build_total_usec) / 1000.0, "recipeBuildMaxMs": float(world.cave_field.recipe_build_max_usec) / 1000.0, "cacheEvictions": world.cave_field.cache_evictions, "deepAirSamples": air_count, "deepRockSamples": solid_count, "savedEditCell": str(cell)})
		print("CAVE AUTHORITY ", seed_value, " failures=", failures, " blockMs=", generation_ms)
	var passed := results.all(func(r): return r.passed)
	var report := {"evidenceLevel": "contract_service", "liveGameplayAcceptance": false,
		"passed": passed, "results": results}
	var report_path := OS.get_environment("CAVE_AUTHORITY_REPORT").strip_edges()
	if report_path.is_empty():
		report_path = "res://artifacts/caves/cave-authority-contract.json"
	if report_path.begins_with("res://"):
		report_path = ProjectSettings.globalize_path(report_path)
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var report_file := FileAccess.open(report_path, FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "  "))
	else:
		push_error("Failed to write cave authority contract report: " + report_path)
		passed = false
	quit(0 if passed else 1)
