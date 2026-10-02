extends SceneTree

const CONTEXT := preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const GENERATION := preload("res://scripts/WorldGenerationSystem.gd")
const SEEDS := ["cave-contract-417", "atlas-39460628"]
const RADII := [0.0, 0.01, 1.5, 8.0, 32.0, 96.0]


func _initialize() -> void:
	call_deferred("_run")


func _make_world(seed_value: String):
	var context = CONTEXT.new()
	context.seed_text = seed_value
	context.seed_hash = context.hash_string(seed_value)
	context.setup_noise()
	var world = GENERATION.new()
	world.setup(context)
	context.set_generator(world)
	return world


func _recipe_dictionary_footprint(world, position: Vector3, radius: float) -> bool:
	var low: Vector2i = world.cave_field.region_at(position - Vector3(radius, 0, radius))
	var high: Vector2i = world.cave_field.region_at(position + Vector3(radius, 0, radius))
	for z in range(low.y, high.y + 1):
		for x in range(low.x, high.x + 1):
			var recipe: Dictionary = world.cave_field.recipe_for_region(
				Vector2i(x, z), world.cave_surface_callable, world.cave_protected_bounds_callable)
			if recipe.is_empty():
				continue
			var bounds: AABB = recipe.bounds
			if position.x + radius >= bounds.position.x and position.x - radius <= bounds.end.x \
					and position.z + radius >= bounds.position.z and position.z - radius <= bounds.end.z:
				return true
	return false


func _run() -> void:
	var failures: Array[String] = []
	var rows: Array[Dictionary] = []
	var positive_count := 0
	var negative_count := 0
	for seed_value in SEEDS:
		var world = _make_world(seed_value)
		var queries: Array[Dictionary] = []
		var positions: Array[Vector3] = [
			Vector3(-96.01, 0.0, -96.01), Vector3(-96.0, 0.0, -96.0),
			Vector3(95.99, 0.0, 95.99), Vector3(96.0, 0.0, 96.0),
			Vector3(-288.0, 0.0, 96.0), Vector3(288.0, 0.0, -96.0)]
		for z in range(-1, 2):
			for x in range(-1, 2):
				var recipe: Dictionary = world.cave_recipe_for_region(Vector2i(x, z))
				if recipe.is_empty(): continue
				var bounds: AABB = recipe.bounds
				positions.append(bounds.position)
				positions.append(bounds.end)
				positions.append(bounds.position - Vector3(0.01, 0.0, 0.01))
				positions.append(bounds.end + Vector3(0.01, 0.0, 0.01))
		if positions.size() <= 6:
			failures.append("%s:no_recipe_boundary_samples" % seed_value)
		for position in positions:
			for radius in RADII:
				queries.append({"position": position, "radius": radius})
				var expected: bool = _recipe_dictionary_footprint(world, position, radius)
				var actual: bool = world.cave_field.recipe_bounds_intersects_xz_footprint(
					position, radius, world.cave_surface_callable, world.cave_protected_bounds_callable)
				var production: bool = world.generated_cave_near_surface_footprint(position, radius)
				if expected: positive_count += 1
				else: negative_count += 1
				if actual != expected:
					failures.append("%s:%s:radius=%s:expected=%s:actual=%s" % [
						seed_value, position, radius, expected, actual])
				if production != expected:
					failures.append("%s:%s:radius=%s:expected=%s:production=%s" % [
						seed_value, position, radius, expected, production])
		# All recipes are warm from parity above. Measure both query paths with
		# identical admitted inputs; these timings are service diagnostics only.
		var old_true := 0
		var old_started := Time.get_ticks_usec()
		for repeat in range(3):
			for query in queries:
				if _recipe_dictionary_footprint(world, query.position, query.radius):
					old_true += 1
		var old_usec := Time.get_ticks_usec() - old_started
		var new_true := 0
		var new_started := Time.get_ticks_usec()
		for repeat in range(3):
			for query in queries:
				if world.cave_field.recipe_bounds_intersects_xz_footprint(
						query.position, query.radius, world.cave_surface_callable,
						world.cave_protected_bounds_callable):
					new_true += 1
		var new_usec := Time.get_ticks_usec() - new_started
		if old_true != new_true:
			failures.append("%s:warm_timing_results_changed" % seed_value)
		rows.append({"seed": seed_value, "positions": positions.size(),
			"queries": positions.size() * RADII.size(),
			"warmTiming": {"repeats": 3, "oldRecipeDictionaryLoopUsec": old_usec,
				"newNativeBooleanUsec": new_usec, "trueResults": old_true},
			"cacheStats": world.cave_field.cache_stats()})
	if positive_count == 0 or negative_count == 0:
		failures.append("parity_samples_missing_positive_or_negative_result")
	var report := {"evidenceLevel": "contract_service", "liveGameplayAcceptance": false,
		"passed": failures.is_empty(), "failures": failures,
		"positiveQueries": positive_count, "negativeQueries": negative_count,
		"seeds": rows}
	var report_path := OS.get_environment("NATIVE_CAVE_FOOTPRINT_REPORT").strip_edges()
	if report_path.is_empty():
		report_path = ProjectSettings.globalize_path("res://artifacts/caves/native-footprint-contract.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var report_file := FileAccess.open(report_path, FileAccess.WRITE)
	if report_file == null:
		push_error("Failed to write native cave footprint contract: " + report_path)
		quit(1)
		return
	report_file.store_string(JSON.stringify(report, "  "))
	quit(0 if failures.is_empty() else 1)
