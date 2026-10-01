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

func make_world(seed_value: String, terrain_edits: Dictionary = {}):
	var context = CONTEXT.new()
	context.seed_text = seed_value
	context.seed_hash = context.hash_string(seed_value)
	context.setup_noise()
	context.initial_terrain_edits = terrain_edits.duplicate(true)
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
		var highland_centers := 0
		var valid_entrances := 0
		var depth_capacity_regions := 0
		var proposal_conditioned_regions := 0
		var proposal_conditioned_recipes := 0
		var substantial_recipes := 0
		var rejection_counts := {}
		var minimum_vertical_travel := INF
		var maximum_vertical_travel := 0.0
		var minimum_depth_levels := 999
		var sampled_region_count := 0
		var failures := []
		var build_metrics := {"nativeCentersAttempted": 0, "nativeDirectionsEvaluated": 0,
			"nativeBuildTimeUsec": 0, "nativeBuildMaxUsec": 0,
			"oracleCentersAttempted": 0, "oracleDirectionsEvaluated": 0,
			"oracleBuildTimeUsec": 0, "oracleBuildMaxUsec": 0,
			"nativeTerminalReasons": {}, "oracleTerminalReasons": {},
			"regions": []}
		var verify_primary_preservation := OS.get_environment("CAVE_CONTRACT_VERIFY_PRIMARY") == "1"
		var overlay_determinism_verified := false
		var primary_success_regions := 0
		var fallback_rescued_regions := 0
		for rz in coordinate_values:
			for rx in coordinate_values:
				var region := Vector2i(rx, rz)
				if not region_filter.is_empty() and region != selected_region:
					continue
				sampled_region_count += 1
				var recipe: Dictionary = world.cave_recipe_for_region(region)
				var native_diagnostics: Dictionary = world.cave_field.recipe_build_diagnostics(region)
				var admission: Dictionary = {}
				var oracle_recipe: Dictionary = oracle.build_recipe(region, world, admission)
				var oracle_diagnostics := admission.duplicate(true)
				var native_reason := str(native_diagnostics.get("terminal_reason", "missing_diagnostics"))
				var oracle_reason := str(oracle_diagnostics.get("reason", "missing_diagnostics"))
				add_count(build_metrics["nativeTerminalReasons"], native_reason)
				add_count(build_metrics["oracleTerminalReasons"], oracle_reason)
				build_metrics["nativeCentersAttempted"] += int(native_diagnostics.get("centers_attempted", 0))
				build_metrics["nativeDirectionsEvaluated"] += int(native_diagnostics.get("directions_evaluated", 0))
				build_metrics["nativeBuildTimeUsec"] += int(native_diagnostics.get("build_time_usec", 0))
				build_metrics["nativeBuildMaxUsec"] = maxi(int(build_metrics["nativeBuildMaxUsec"]), int(native_diagnostics.get("build_time_usec", 0)))
				build_metrics["oracleCentersAttempted"] += int(oracle_diagnostics.get("centersAttempted", 0))
				build_metrics["oracleDirectionsEvaluated"] += int(oracle_diagnostics.get("directionsEvaluated", 0))
				build_metrics["oracleBuildTimeUsec"] += int(oracle_diagnostics.get("buildTimeUsec", 0))
				build_metrics["oracleBuildMaxUsec"] = maxi(int(build_metrics["oracleBuildMaxUsec"]), int(oracle_diagnostics.get("buildTimeUsec", 0)))
				var center_summaries: Array = []
				for native_center in native_diagnostics.get("centers", []):
					var native_center_position: Vector3 = native_center.get("center", Vector3.ZERO)
					center_summaries.append({"center": vec(native_center_position),
						"directionsEvaluated": int(native_center.get("directions_evaluated", 0)),
						"viableEntrances": int(native_center.get("viable_entrances", 0)),
						"fullRecipeAttempts": int(native_center.get("full_recipe_attempts", 0)),
						"terminalReason": str(native_center.get("terminal_reason", "")),
						"rejections": native_center.get("rejection_counts", {})})
				var oracle_center_summaries: Array = []
				for oracle_center in oracle_diagnostics.get("centerAttempts", []):
					var oracle_center_position: Vector3 = oracle_center.get("center", Vector3.ZERO)
					oracle_center_summaries.append({"center": vec(oracle_center_position),
						"directionsEvaluated": int(oracle_center.get("directionsEvaluated", 0)),
						"candidateDirections": int(oracle_center.get("candidateDirections", 0)),
						"fullRecipeAttempts": int(oracle_center.get("fullRecipeAttempts", 0)),
						"terminalReason": str(oracle_center.get("reason", "")),
						"directionRejections": oracle_center.get("directionRejections", {}),
						"candidateRejections": oracle_center.get("candidateRejections", {})})
				var reported_native_centers: Array = native_diagnostics.get("centers", [])
				if native_diagnostics.is_empty() or int(native_diagnostics.get("centers_attempted", -1)) != reported_native_centers.size():
					failures.append("native_diagnostics_shape_invalid:%s" % region)
				if int(oracle_diagnostics.get("centersAttempted", -1)) != oracle_center_summaries.size():
					failures.append("oracle_diagnostics_shape_invalid:%s" % region)
				build_metrics["regions"].append({"region": [rx, rz],
					"native": {"centersAttempted": int(native_diagnostics.get("centers_attempted", 0)),
						"directionsEvaluated": int(native_diagnostics.get("directions_evaluated", 0)),
						"buildTimeUsec": int(native_diagnostics.get("build_time_usec", 0)),
						"terminalReason": native_reason, "centers": center_summaries},
					"oracle": {"centersAttempted": int(oracle_diagnostics.get("centersAttempted", 0)),
						"directionsEvaluated": int(oracle_diagnostics.get("directionsEvaluated", 0)),
						"buildTimeUsec": int(oracle_diagnostics.get("buildTimeUsec", 0)),
						"terminalReason": oracle_reason, "centers": oracle_center_summaries}})
				var rejection_reason := str(admission.get("reason", "missing_reason"))
				rejection_counts[rejection_reason] = int(rejection_counts.get(rejection_reason, 0)) + 1
				highland_centers += int(bool(admission.get("highlandCenter", false)))
				valid_entrances += int(bool(admission.get("validEntrance", false)))
				depth_capacity_regions += int(bool(admission.get("depthCapacity", false)))
				if bool(admission.get("proposalConditioned", false)):
					proposal_conditioned_regions += 1
				var recipe_diff := first_difference(recipe, oracle_recipe, "recipe")
				if not recipe_diff.is_empty():
					failures.append("native_gdscript_recipe_mismatch:%s" % region)
					print("CAVE FIRST RECIPE DIFF ", recipe_diff)
				if verify_primary_preservation:
					var primary_oracle := FIELD.new()
					primary_oracle.setup(seed_value)
					var primary_diagnostics := {}
					var primary_recipe: Dictionary = primary_oracle.build_recipe_at_offset(region, world, Vector3.ZERO, primary_diagnostics)
					if not primary_recipe.is_empty():
						primary_success_regions += 1
					elif not recipe.is_empty():
						fallback_rescued_regions += 1
					if not primary_recipe.is_empty() and not first_difference(recipe, primary_recipe, "primary_recipe").is_empty():
						failures.append("primary_recipe_changed:%s" % region)
					if not primary_recipe.is_empty() and int(native_diagnostics.get("centers_attempted", 0)) != 1:
						failures.append("fallback_ran_after_primary_success:%s" % region)
					if not primary_recipe.is_empty() and int(oracle_diagnostics.get("centersAttempted", 0)) != 1:
						failures.append("oracle_fallback_ran_after_primary_success:%s" % region)
					if primary_recipe.is_empty() and not recipe.is_empty() and int(native_diagnostics.get("centers_attempted", 0)) <= 1:
						failures.append("native_fallback_skipped_after_primary_failure:%s" % region)
					if primary_recipe.is_empty() and not oracle_recipe.is_empty() \
							and int(oracle_diagnostics.get("centersAttempted", 0)) <= 1:
						failures.append("oracle_fallback_skipped_after_primary_failure:%s" % region)
					if int(native_diagnostics.get("centers_attempted", 0)) == 1 \
							and not first_difference(recipe, primary_recipe, "native_primary_recipe").is_empty():
						failures.append("native_primary_recipe_changed:%s" % region)
					if not overlay_determinism_verified:
						var overlay_cell := Vector3i(region.x * 142, 0, region.y * 142)
						var edited_world = make_world(seed_value, {overlay_cell: {"density": -1.35, "material": "air"}})
						var edited_native_recipe: Dictionary = edited_world.cave_recipe_for_region(region)
						var edited_oracle := FIELD.new()
						edited_oracle.setup(seed_value)
						var edited_admission := {}
						var edited_recipe: Dictionary = edited_oracle.build_recipe(region, edited_world, edited_admission)
						if not first_difference(recipe, edited_native_recipe, "overlay_native_recipe").is_empty():
							failures.append("persistent_overlay_changed_native_recipe:%s" % region)
						if not first_difference(oracle_recipe, edited_recipe, "overlay_oracle_recipe").is_empty():
							failures.append("persistent_overlay_changed_oracle_recipe:%s" % region)
						overlay_determinism_verified = true
				var repeated_recipe: Dictionary = other.cave_recipe_for_region(region)
				if recipe != repeated_recipe:
					failures.append("recipe_not_repeatable:%s" % region)
				if recipe.is_empty():
					continue
				found += 1
				if bool(admission.get("proposalConditioned", false)):
					proposal_conditioned_recipes += 1
				if recipe.depthLoops.size() >= 4:
					substantial_recipes += 1
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
		var proposal_conditioned_rate := float(substantial_recipes) / float(maxi(proposal_conditioned_regions, 1))
		var all_sampled_prevalence := float(substantial_recipes) / float(maxi(sampled_region_count, 1))
		build_metrics["nativeBuildMeanUsec"] = float(build_metrics["nativeBuildTimeUsec"]) / float(maxi(sampled_region_count, 1))
		build_metrics["oracleBuildMeanUsec"] = float(build_metrics["oracleBuildTimeUsec"]) / float(maxi(sampled_region_count, 1))
		build_metrics["nativeCacheStats"] = world.cave_field.cache_stats()
		results.append({"seed": seed_value, "regionsSampled": sampled_region_count, "recipes": found,
			"highlandCenters": highland_centers,
			"validEntrances": valid_entrances,
			"depthCapacityRegions": depth_capacity_regions,
			"proposalConditionedRegions": proposal_conditioned_regions,
			"proposalConditionedRecipes": proposal_conditioned_recipes,
			"substantialRecipes": substantial_recipes,
			"proposalConditionedAcceptanceRate": proposal_conditioned_rate,
			"allSampledPrevalence": all_sampled_prevalence,
			"rejectionCounts": rejection_counts,
			"buildMetrics": build_metrics,
			"overlayDeterminismVerified": overlay_determinism_verified,
			"primarySuccessRegions": primary_success_regions,
			"fallbackRescuedRegions": fallback_rescued_regions,
			"allSampledSubstantialAcceptanceRate": all_sampled_prevalence,
			"minimumVerticalTravelMeters": minimum_vertical_travel,
			"maximumVerticalTravelMeters": maximum_vertical_travel,
			"minimumDepthLevels": minimum_depth_levels,
			"passed": proposal_conditioned_regions > 0 and proposal_conditioned_rate >= 0.5
				and minimum_depth_levels >= 4 and failures.is_empty()
				and (not verify_primary_preservation or overlay_determinism_verified), "failures": failures})
		print("CAVE CONTRACT ", seed_value, " recipes=", found, " regions=", sampled_region_count,
			" highland=", highland_centers,
			" entrances=", valid_entrances, " depth_capacity=", depth_capacity_regions,
			" proposal_conditioned=", proposal_conditioned_regions,
			" substantial=", substantial_recipes,
			" proposal_conditioned_acceptance=", proposal_conditioned_rate,
			" all_sampled_prevalence=", all_sampled_prevalence,
			" rejection_counts=", rejection_counts,
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

func add_count(counts: Dictionary, key: String) -> void:
	counts[key] = int(counts.get(key, 0)) + 1

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
						var nearest_segment_distance := INF
						var nearest_segment := {}
						for segment_index in range(recipe.segments.size()):
							var segment: Dictionary = recipe.segments[segment_index]
							var segment_a: Vector3 = segment.a
							var segment_b: Vector3 = segment.b
							var horizontal := Vector2(segment_b.x - segment_a.x, segment_b.z - segment_a.z)
							var t := clampf(Vector2(p.x - segment_a.x, p.z - segment_a.z).dot(horizontal)
								/ maxf(horizontal.length_squared(), 0.001), 0.0, 1.0)
							var segment_floor := segment_a.lerp(segment_b, t)
							var segment_radius := lerpf(float(segment.get("radius", 2.7)),
								float(segment.get("radius_end", segment.get("radius", 2.7))), t)
							var segment_vertical := lerpf(float(segment.get("vertical_radius", segment_radius)),
								float(segment.get("vertical_radius_end", segment.get("vertical_radius", segment_radius))), t)
							var delta := p - (segment_floor + Vector3.UP * segment_vertical)
							var normalized_distance := sqrt(Vector2(delta.x, delta.z).length_squared() / (segment_radius * segment_radius)
								+ pow(delta.y / segment_vertical, 2.0))
							if normalized_distance < nearest_segment_distance:
								nearest_segment_distance = normalized_distance
								nearest_segment = {"index": segment_index, "t": t, "floor": segment_floor,
									"radius": segment_radius, "verticalRadius": segment_vertical,
									"normalizedDistance": normalized_distance}
						print("CAVE BLOCKED BODY ", label, " point=", p, " density=", body_density,
							" recipeDensity=", recipe_body_density, " nativeCaveDensity=", native_cave_density,
							" guide_floor=", floor_point, " ground=", world.volume_ground_height_near(floor_point),
							" surface=", surface, " nearestSegment=", nearest_segment)
						support_debug_emitted = true
			var below := floor_point - Vector3.UP * 1.2
			var below_surface: float = world.terrain_reference_surface_y_at(below)
			if world.density_from_components(below, below_surface, below_surface) < 0.0:
				failures.append("missing_floor:%s:%s" % [label, below])
