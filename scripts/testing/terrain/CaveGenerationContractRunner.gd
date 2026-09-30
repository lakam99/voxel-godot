extends SceneTree

const CONTEXT := preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const GENERATION := preload("res://scripts/WorldGenerationSystem.gd")
const FIELD := preload("res://scripts/world/ProceduralCaveField.gd")
var results: Array = []
var examples: Array = []

func _initialize() -> void:
	call_deferred("run")

func make_world(seed_value: String):
	var context = CONTEXT.new()
	context.seed_text = seed_value
	context.seed_hash = context.hash_string(seed_value)
	context.setup_noise()
	var generation = GENERATION.new()
	generation.setup(context)
	context.set_generator(generation)
	return generation

func run() -> void:
	for seed_value in ["cave-master-20260903", "atlas-1492", "cave-contract-417", "cave-contract-928", "atlas-39389036"]:
		var world = make_world(seed_value)
		var other = make_world(seed_value)
		var found := 0
		var failures := []
		for rz in range(-2, 3):
			for rx in range(-2, 3):
				var region := Vector2i(rx, rz)
				var recipe: Dictionary = world.cave_recipe_for_region(region)
				if recipe.is_empty():
					continue
				found += 1
				if recipe != other.cave_recipe_for_region(region):
					failures.append("recipe_not_repeatable:%s" % region)
				for route_name in ["route", "loop", "deepRoute"]:
					check_path(world, recipe[route_name], "%s:%s" % [region, route_name], failures)
				var route: Array = recipe.route
				examples.append({"seed": seed_value, "region": [rx, rz], "biome": world.surface_biome_for_cell3(Vector3i((recipe.entry / 1.35).floor())), "entry": vec(recipe.entry), "outward": vec(recipe.outward), "chamberFloor": vec(route.back()), "route": route.map(func(p): return vec(p))})
		results.append({"seed": seed_value, "recipes": found, "passed": found > 0 and failures.is_empty(), "failures": failures})
		print("CAVE CONTRACT ", seed_value, " recipes=", found, " failures=", failures.size())
	var passed := results.all(func(r): return r.passed)
	var output := "res://artifacts/caves/cave-generation-contract.json"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output.get_base_dir()))
	FileAccess.open(output, FileAccess.WRITE).store_string(JSON.stringify({"evidenceLevel": "contract", "liveGameplayAcceptance": false, "passed": passed, "results": results, "examples": examples}, "  "))
	quit(0 if passed else 1)

func vec(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

func check_path(world, route: Array, label: String, failures: Array) -> void:
	var previous := Vector3.INF
	for index in range(route.size() - 1):
		var a: Vector3 = route[index]
		var b: Vector3 = route[index + 1]
		for step in range(11):
			var floor_point := a.lerp(b, float(step) / 10.0)
			# Connected cavities may legitimately lower the floor at a junction.
			# Check the resulting volume boundary and grade, not a recipe's guide.
			var ground_y: float = world.volume_ground_height_near(floor_point)
			if is_nan(ground_y) or absf(ground_y - floor_point.y) > 3.0:
				failures.append("missing_reachable_floor:%s:%s" % [label, floor_point])
				continue
			floor_point.y = ground_y
			if previous != Vector3.INF:
				var run := Vector2(floor_point.x - previous.x, floor_point.z - previous.z).length()
				if run > 0.01 and absf(floor_point.y - previous.y) / run > tan(deg_to_rad(46.0)):
					failures.append("unwalkable_grade:%s:%s" % [label, floor_point])
					print("CAVE GRADE ", label, " previous=", previous, " next=", floor_point, " depth=", world.terrain_reference_surface_y_at(floor_point) - floor_point.y)
			previous = floor_point
			for offset in [Vector3(0, 1.0, 0), Vector3(0, 2.2, 0), Vector3(0.6, 1.5, 0), Vector3(-0.6, 1.5, 0), Vector3(0, 1.5, 0.6), Vector3(0, 1.5, -0.6)]:
				var p: Vector3 = floor_point + offset
				var surface: float = world.terrain_reference_surface_y_at(p)
				if world.density_from_components(p, surface, surface) >= 0.0:
					failures.append("blocked_body:%s:%s" % [label, p])
			var below := floor_point - Vector3.UP * 1.2
			var below_surface: float = world.terrain_reference_surface_y_at(below)
			if world.density_from_components(below, below_surface, below_surface) < 0.0:
				failures.append("missing_floor:%s:%s" % [label, below])
