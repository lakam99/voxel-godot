extends SceneTree

const CONTEXT := preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const GENERATION := preload("res://scripts/WorldGenerationSystem.gd")
const FIELD := preload("res://scripts/world/ProceduralCaveField.gd")
# 1mm only absorbs platform float arithmetic; it is under 0.1% of the 1.35m
# terrain cell and cannot hide a gameplay- or mesh-scale recipe divergence.
const PARITY_POSITION_TOLERANCE_METERS := 0.001
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
	var seed_values := ["cave-master-20260903", "atlas-1492", "cave-contract-417", "cave-contract-928", "atlas-39389036"]
	var seed_filter := OS.get_environment("CAVE_CONTRACT_SEED")
	if not seed_filter.is_empty():
		seed_values = [seed_filter]
	var coordinate_values := [-8, -4, 0, 4, 8]
	var region_filter := OS.get_environment("CAVE_CONTRACT_REGION")
	var selected_region := Vector2i.ZERO
	if not region_filter.is_empty():
		var coordinates := region_filter.split(",")
		selected_region = Vector2i(int(coordinates[0]), int(coordinates[1]))
		coordinate_values = [selected_region.x, selected_region.y]
	for seed_value in seed_values:
		var world = make_world(seed_value)
		var other = make_world(seed_value)
		var oracle = FIELD.new()
		oracle.setup(seed_value)
		var found := 0
		var lowland_region_centers := 0
		var minimum_vertical_travel := INF
		var maximum_vertical_travel := 0.0
		var minimum_depth_levels := 999
		var sampled_region_count := 0
		var failures := []
		for rz in coordinate_values:
			for rx in coordinate_values:
				var region := Vector2i(rx, rz)
				if not region_filter.is_empty() and region != selected_region:
					continue
				sampled_region_count += 1
				var region_center := Vector3(rx * 192.0, 0.0, rz * 192.0)
				var center_surface := float(world.terrain_reference_surface_y_at(region_center))
				if center_surface < 19.0:
					lowland_region_centers += 1
				var recipe: Dictionary = world.cave_recipe_for_region(region)
				if recipe.is_empty():
					continue
				found += 1
				var oracle_recipe: Dictionary = oracle.recipe_for_region(region, world)
				var recipe_diff := first_difference(recipe, oracle_recipe, "recipe")
				if not recipe_diff.is_empty():
					failures.append("native_gdscript_recipe_mismatch:%s" % region)
					print("CAVE FIRST RECIPE DIFF ", recipe_diff)
				if recipe != other.cave_recipe_for_region(region):
					failures.append("recipe_not_repeatable:%s" % region)
				for route_name in ["route", "loop", "deepRoute"]:
					check_path(world, recipe[route_name], "%s:%s" % [region, route_name], failures, recipe, oracle)
				for depth_index in range(recipe.depthLoops.size()):
					check_path(world, recipe.depthLoops[depth_index], "%s:depth_loop_%d" % [region, depth_index], failures, recipe, oracle)
				if recipe.deepRoute.size() < 5 or recipe.depthLoops.size() < 4:
					failures.append("network_has_too_few_depth_levels:%s" % region)
				var route: Array = recipe.route
				var vertical_travel := float(recipe.entry.y - recipe.deepRoute.back().y)
				minimum_vertical_travel = minf(minimum_vertical_travel, vertical_travel)
				maximum_vertical_travel = maxf(maximum_vertical_travel, vertical_travel)
				minimum_depth_levels = mini(minimum_depth_levels, recipe.depthLoops.size())
				examples.append({"seed": seed_value, "region": [rx, rz], "biome": world.surface_biome_for_cell3(Vector3i((recipe.entry / 1.35).floor())), "entry": vec(recipe.entry), "outward": vec(recipe.outward), "chamberFloor": vec(route.back()), "deepestFloor": vec(recipe.deepRoute.back()), "verticalTravelMeters": recipe.entry.y - recipe.deepRoute.back().y, "depthLevelCount": recipe.depthLoops.size(), "chamberCount": recipe.chambers.size(), "route": route.map(func(p): return vec(p))})
		var acceptance_rate := float(found) / float(maxi(sampled_region_count, 1))
		results.append({"seed": seed_value, "regionsSampled": sampled_region_count, "recipes": found,
			"acceptanceRate": acceptance_rate,
			"lowlandRegionCenters": lowland_region_centers,
			"minimumVerticalTravelMeters": minimum_vertical_travel,
			"maximumVerticalTravelMeters": maximum_vertical_travel,
			"minimumDepthLevels": minimum_depth_levels,
			"passed": acceptance_rate >= 0.3
				and minimum_depth_levels >= 4 and failures.is_empty(), "failures": failures})
		print("CAVE CONTRACT ", seed_value, " recipes=", found, " regions=", sampled_region_count,
			" acceptance=", acceptance_rate, " lowland_region_centers=", lowland_region_centers,
			" minimum_levels=", minimum_depth_levels,
			" failures=", failures.size())
	var passed := results.all(func(r): return r.passed)
	var output := OS.get_environment("CAVE_CONTRACT_REPORT")
	if output.is_empty():
		output = "res://artifacts/caves/cave-generation-contract.json"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output.get_base_dir()))
	FileAccess.open(output, FileAccess.WRITE).store_string(JSON.stringify({"evidenceLevel": "contract", "liveGameplayAcceptance": false, "passed": passed, "results": results, "examples": examples}, "  "))
	quit(0 if passed else 1)

func vec(value: Vector3) -> Array:
	return [value.x, value.y, value.z]

func first_difference(left: Variant, right: Variant, path: String) -> Dictionary:
	if typeof(left) != typeof(right):
		return {"path": path, "native": left, "oracle": right, "native_type": typeof(left), "oracle_type": typeof(right)}
	if left is Vector3:
		if left.distance_to(right) > PARITY_POSITION_TOLERANCE_METERS:
			return {"path": path, "native": left, "oracle": right, "native_minus_oracle": left - right}
		return {}
	if left is AABB:
		if left.position.distance_to(right.position) > PARITY_POSITION_TOLERANCE_METERS \
				or left.size.distance_to(right.size) > PARITY_POSITION_TOLERANCE_METERS:
			return {"path": path, "native": left, "oracle": right}
		return {}
	if left is Dictionary:
		var keys: Array = left.keys()
		for key in right.keys():
			if not keys.has(key):
				keys.append(key)
		keys.sort()
		for key in keys:
			if not left.has(key) or not right.has(key):
				return {"path": "%s.%s" % [path, key], "native": left.get(key, "<missing>"), "oracle": right.get(key, "<missing>")}
			var nested := first_difference(left[key], right[key], "%s.%s" % [path, key])
			if not nested.is_empty():
				return nested
		return {}
	if left is Array:
		if left.size() != right.size():
			return {"path": "%s.size" % path, "native": left.size(), "oracle": right.size()}
		for index in range(left.size()):
			var nested := first_difference(left[index], right[index], "%s[%d]" % [path, index])
			if not nested.is_empty():
				return nested
		return {}
	if left is float and absf(left - right) <= 0.000001:
		return {}
	if left != right:
		return {"path": path, "native": left, "oracle": right}
	return {}

func check_path(world, route: Array, label: String, failures: Array, recipe: Dictionary, oracle) -> void:
	var previous := Vector3.INF
	var support_debug_emitted := false
	for index in range(route.size() - 1):
		var a: Vector3 = route[index]
		var b: Vector3 = route[index + 1]
		for step in range(11):
			var floor_point := a.lerp(b, float(step) / 10.0)
			var recipe_guide_floor := floor_point
			# Connected cavities may legitimately lower the floor at a junction.
			# Check the resulting volume boundary and grade, not a recipe's guide.
			var ground_y: float = world.volume_ground_height_near(floor_point)
			if is_nan(ground_y) or absf(ground_y - floor_point.y) > 3.0:
				failures.append("missing_reachable_floor:%s:%s" % [label, floor_point])
				if not support_debug_emitted:
					var surface := float(world.terrain_reference_surface_y_at(floor_point))
					var native_effective := float(world.density_from_components(floor_point, world.terrain_deformed_surface_y_at(floor_point), surface))
					var cell: Vector3i = world.world_to_cell3(floor_point)
					var lattice_density := float(world.volume_density_at_grid_cell(cell))
					var oracle_recipe_density := float(oracle.recipe_density(floor_point, recipe))
					print("CAVE SUPPORT SAMPLE ", label, " guide=", floor_point, " ground=", ground_y,
						" recipeDensityOnNativeRecipe=", oracle_recipe_density,
						" effectiveDensity=", native_effective, " cell=", cell,
						" latticeDensity=", lattice_density, " surface=", surface)
					support_debug_emitted = true
				continue
			floor_point.y = ground_y
			if previous != Vector3.INF:
				var run := Vector2(floor_point.x - previous.x, floor_point.z - previous.z).length()
				if run > 0.01 and absf(floor_point.y - previous.y) / run > tan(deg_to_rad(46.0)):
					failures.append("unwalkable_grade:%s:%s" % [label, floor_point])
					var guide_sdf: float = oracle.recipe_density(recipe_guide_floor, recipe)
					var support_sdf: float = oracle.recipe_density(floor_point, recipe)
					var support_cell: Vector3i = world.world_to_cell3(floor_point)
					var support_lattice_density: float = world.volume_density_at_grid_cell(support_cell)
					print("CAVE GRADE ", label, " previous=", previous, " next=", floor_point,
						" guide=", recipe_guide_floor, " run=", run,
						" guideSDF=", guide_sdf, " supportSDF=", support_sdf,
						" supportLattice=", support_cell, ":", support_lattice_density,
						" depth=", world.terrain_reference_surface_y_at(floor_point) - floor_point.y)
			previous = floor_point
			for offset in [Vector3(0, 1.0, 0), Vector3(0, 2.2, 0), Vector3(0.6, 1.5, 0), Vector3(-0.6, 1.5, 0), Vector3(0, 1.5, 0.6), Vector3(0, 1.5, -0.6)]:
				var p: Vector3 = floor_point + offset
				var surface: float = world.terrain_reference_surface_y_at(p)
				var body_density: float = world.density_from_components(p, surface, surface)
				if body_density >= 0.0:
					failures.append("blocked_body:%s:%s" % [label, p])
					if not support_debug_emitted:
						var recipe_body_density: float = oracle.recipe_density(p, recipe)
						var native_cave_density: float = world.cave_field.density(p,
							maxf(0.0, surface - p.y), world.cave_surface_callable,
							world.cave_protected_bounds_callable)
						print("CAVE BLOCKED BODY ", label, " point=", p, " density=", body_density,
							" recipeDensity=", recipe_body_density, " nativeCaveDensity=", native_cave_density,
							" guide_floor=", floor_point, " ground=", world.volume_ground_height_near(floor_point))
						support_debug_emitted = true
			var below := floor_point - Vector3.UP * 1.2
			var below_surface: float = world.terrain_reference_surface_y_at(below)
			if world.density_from_components(below, below_surface, below_surface) < 0.0:
				failures.append("missing_floor:%s:%s" % [label, below])
