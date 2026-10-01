extends SceneTree

const CONTEXT := preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const GENERATION := preload("res://scripts/WorldGenerationSystem.gd")
const FIELD := preload("res://scripts/world/ProceduralCaveField.gd")
# Tier-link curve operations show sub-2mm native/oracle float drift at
# kilometre-scale coordinates. This remains below 0.15% of a 1.35m cell;
# topology, counts, IDs, and array structure continue to compare exactly.
const PARITY_POSITION_TOLERANCE_METERS := 0.002
const TUNNEL_ROOF_RESERVE_METERS := 2.7 * 2.0 + 1.35 * 1.15
const CAVE_REGION_METRES := 192.0
const SUBSTANTIAL_NETWORK_MIN_DEPTH_METRES := 60.0
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
	if not ClassDB.class_exists("NativeCaveField"):
		push_error("CAVE CONTRACT STARTUP BLOCKED: NativeCaveField extension class is not registered")
		quit(1)
		return
	# Spread the prevalence sample over 10 stable worlds and an 81-region square
	# spanning 6.1 km. This makes “common” a claim about generated regions, not
	# only recipes that already passed terrain-conditioned admission.
	var seed_values := ["cave-master-20260903", "atlas-1492", "cave-contract-417", "cave-contract-928", "atlas-39389036",
		"atlas-40681133", "cave-prevalence-018", "cave-prevalence-027", "cave-prevalence-041", "cave-prevalence-063"]
	var seed_filter := OS.get_environment("CAVE_CONTRACT_SEED")
	if not seed_filter.is_empty():
		seed_values = [seed_filter]
	var coordinate_values := [-16, -12, -8, -4, 0, 4, 8, 12, 16]
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
		var biome_region_counts := {}
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
				var region_center_cell := Vector3i(floori(float(rx) * CAVE_REGION_METRES / world.cell_size()), 0,
					floori(float(rz) * CAVE_REGION_METRES / world.cell_size()))
				var region_biome := world.surface_biome_for_cell3(region_center_cell)
				if not biome_region_counts.has(region_biome):
					biome_region_counts[region_biome] = {"regions": 0, "recipes": 0, "substantialNetworks": 0}
				biome_region_counts[region_biome].regions += 1
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
						"lastRejectionDetail": str(native_center.get("last_rejection_detail", "")),
						"rejections": native_center.get("rejection_counts", {})})
				var oracle_center_summaries: Array = []
				for oracle_center in oracle_diagnostics.get("centerAttempts", []):
					var oracle_center_position: Vector3 = oracle_center.get("center", Vector3.ZERO)
					oracle_center_summaries.append({"center": vec(oracle_center_position),
						"directionsEvaluated": int(oracle_center.get("directionsEvaluated", 0)),
						"candidateDirections": int(oracle_center.get("candidateDirections", 0)),
						"fullRecipeAttempts": int(oracle_center.get("fullRecipeAttempts", 0)),
						"terminalReason": str(oracle_center.get("reason", "")),
						"lastRejectionDetail": str(oracle_center.get("lastRejectionDetail", "")),
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
				biome_region_counts[region_biome].recipes += 1
				var region_bounds: AABB = recipe.bounds
				if FIELD.new().region_at(region_bounds.position) != region \
						or FIELD.new().region_at(region_bounds.end) != region:
					failures.append("recipe_bounds_escape_region:%s" % region)
				if world.surface_town_intersects_bounds(region_bounds) \
						or world.generated_site_intersects_bounds(region_bounds):
					failures.append("recipe_intersects_protected_site:%s" % region)
				found += 1
				if bool(admission.get("proposalConditioned", false)):
					proposal_conditioned_recipes += 1
				for tier in range(recipe.depthLoops.size()):
					var floor_route_index := 4 + 2 * tier
					if floor_route_index >= recipe.deepRoute.size() \
							or recipe.depthLoops[tier][0] != recipe.deepRoute[floor_route_index]:
						failures.append("depth_tier_anchor_not_on_trunk:%s:%d" % [region, tier])
				for route_name in ["route", "loop", "deepRoute"]:
					check_path(world, recipe[route_name], "%s:%s" % [region, route_name], failures, recipe, oracle)
				for depth_index in range(recipe.depthLoops.size()):
					check_path(world, recipe.depthLoops[depth_index], "%s:depth_loop_%d" % [region, depth_index], failures, recipe, oracle)
				var links: Array = recipe.get("depthTierLinks", [])
				if links.size() != 2:
					failures.append("unexpected_depth_tier_link_count:%s:%d" % [region, links.size()])
				var linked_pairs := {}
				for link in links:
					var from_tier := int(link.get("fromTier", -1))
					var to_tier := int(link.get("toTier", -1))
					var points: Array = link.get("points", [])
					var pair := "%d-%d" % [from_tier, to_tier]
					if to_tier != from_tier + 1 or from_tier < 0 or to_tier >= recipe.depthLoops.size():
						failures.append("invalid_depth_tier_link_pair:%s:%s" % [region, link.get("id", "")])
						continue
					linked_pairs[pair] = true
					var from_loop: Array = recipe.depthLoops[from_tier]
					var to_loop: Array = recipe.depthLoops[to_tier]
					var expected_start: Vector3 = (from_loop[2] + from_loop[3]) * 0.5
					var expected_end: Vector3 = (to_loop[2] + to_loop[3]) * 0.5
					if points.size() < 2 or points.front() != expected_start or points.back() != expected_end:
						failures.append("depth_tier_link_not_attached_to_distinct_loop_run_portals:%s:%s" % [region, link.get("id", "")])
					if expected_start.distance_to(from_loop[0]) <= 6.0 \
							or expected_start.distance_to(from_loop[1]) <= 6.0 \
							or expected_end.distance_to(to_loop[0]) <= 6.0 \
							or expected_end.distance_to(to_loop[1]) <= 6.0:
						failures.append("depth_tier_link_portal_not_off_trunk:%s:%s" % [region, link.get("id", "")])
					check_path(world, points, "%s:depth_tier_link:%s" % [region, link.get("id", "")], failures, recipe, oracle)
					for point_index in range(points.size() - 1):
						for step in range(5):
							var floor_point: Vector3 = points[point_index].lerp(points[point_index + 1], float(step) / 4.0)
							if not recipe.bounds.has_point(floor_point):
								failures.append("depth_tier_link_outside_recipe_bounds:%s:%s:%s" % [region, link.get("id", ""), floor_point])
							var reference_surface := float(world.terrain_reference_surface_y_at(floor_point))
							if reference_surface - floor_point.y < TUNNEL_ROOF_RESERVE_METERS:
								failures.append("depth_tier_link_roof_reserve:%s:%s:%s" % [region, link.get("id", ""), floor_point])
							var roof_check := check_depth_tier_link_roof(world, recipe, floor_point, from_tier, to_tier)
							var roof_sample: Vector3 = roof_check.sample
							if not roof_check.unowned_openings.is_empty():
								for opening in roof_check.unowned_openings:
									failures.append("depth_tier_link_unowned_vertical_opening:%s:%s:%s" % [region, link.get("id", ""), opening])
							var roof_surface := float(world.terrain_reference_surface_y_at(roof_sample))
							var roof_density := world.density_from_components(roof_sample, roof_surface, roof_surface)
							if roof_density < 0.0:
								failures.append("depth_tier_link_effective_roof_not_solid:%s:%s:%s" % [region, link.get("id", ""), roof_sample])
								var roof_winner := {"segment": -1, "sdf": 0.0, "a": Vector3.ZERO, "b": Vector3.ZERO}
								for segment_index in range(recipe.segments.size()):
									var segment: Dictionary = recipe.segments[segment_index]
									if not (segment.bounds as AABB).has_point(roof_sample):
										continue
									var a: Vector3 = segment.a
									var b: Vector3 = segment.b
									var horizontal := Vector2(b.x - a.x, b.z - a.z)
									var t := clampf(Vector2(roof_sample.x - a.x, roof_sample.z - a.z).dot(horizontal) / maxf(horizontal.length_squared(), 0.001), 0.0, 1.0)
									var floor_point_at_sample := a.lerp(b, t)
									var radius := lerpf(float(segment.get("radius", 4.0)), float(segment.get("radius_end", segment.get("radius", 4.0))), t)
									var vertical_radius := lerpf(float(segment.get("vertical_radius", radius)), float(segment.get("vertical_radius_end", segment.get("vertical_radius", radius))), t)
									var center := floor_point_at_sample + Vector3.UP * vertical_radius
									var delta := roof_sample - center
									var sdf := (sqrt(Vector2(delta.x, delta.z).length_squared() / (radius * radius) + (delta.y / vertical_radius) * (delta.y / vertical_radius)) - 1.0) * minf(radius, vertical_radius)
									if sdf < roof_winner.sdf:
										roof_winner = {"segment": segment_index, "sdf": sdf, "a": a, "b": b}
								var roof_chamber_winner := {"chamber": -1, "sdf": INF}
								for chamber_index in range(recipe.chambers.size()):
									var chamber: Dictionary = recipe.chambers[chamber_index]
									var q: Vector3 = (roof_sample - chamber.center) / chamber.radii
									var chamber_sdf := (q.length() - 1.0) * minf(chamber.radii.x, minf(chamber.radii.y, chamber.radii.z))
									if chamber_sdf < roof_chamber_winner.sdf:
										roof_chamber_winner = {"chamber": chamber_index, "sdf": chamber_sdf, "center": chamber.center, "radii": chamber.radii}
								print("CAVE OPEN LINK ROOF ", link.get("id", ""), " floor=", floor_point,
									" roof=", roof_sample, " density=", roof_density,
									" oracle=", oracle.recipe_density(roof_sample, recipe),
									" ground=", world.volume_ground_height_near(roof_sample), " winner=", roof_winner,
									" chamberWinner=", roof_chamber_winner)
							if floor_point.y < float(world.world_bottom_cell_y() + 4) * world.cell_size():
								failures.append("depth_tier_link_world_bottom_reserve:%s:%s:%s" % [region, link.get("id", ""), floor_point])
				if linked_pairs.size() != 2 or not linked_pairs.has("0-1") or not linked_pairs.has("2-3"):
					failures.append("depth_tier_links_not_on_required_adjacent_pairs:%s" % region)
				if not links_form_alternate_routes(recipe, failures, region):
					failures.append("depth_tier_links_do_not_bypass_trunk_edges:%s" % region)
				if recipe.deepRoute.size() < 5 or recipe.depthLoops.size() < 4:
					failures.append("network_has_too_few_depth_levels:%s" % region)
				var route: Array = recipe.route
				var vertical_travel := float(recipe.entry.y - recipe.deepRoute.back().y)
				var is_substantial_network: bool = recipe.depthLoops.size() >= 4 \
					and vertical_travel >= SUBSTANTIAL_NETWORK_MIN_DEPTH_METRES
				if is_substantial_network:
					substantial_recipes += 1
					biome_region_counts[region_biome].substantialNetworks += 1
				minimum_vertical_travel = minf(minimum_vertical_travel, vertical_travel)
				maximum_vertical_travel = maxf(maximum_vertical_travel, vertical_travel)
				minimum_depth_levels = mini(minimum_depth_levels, recipe.depthLoops.size())
				examples.append({"seed": seed_value, "region": [rx, rz], "biome": world.surface_biome_for_cell3(Vector3i((recipe.entry / 1.35).floor())), "entry": vec(recipe.entry), "outward": vec(recipe.outward), "chamberFloor": vec(route.back()), "deepestFloor": vec(recipe.deepRoute.back()), "verticalTravelMeters": recipe.entry.y - recipe.deepRoute.back().y, "depthLevelCount": recipe.depthLoops.size(), "chamberCount": recipe.chambers.size(), "route": route.map(func(p): return vec(p))})
		var proposal_conditioned_rate := float(substantial_recipes) / float(maxi(proposal_conditioned_regions, 1))
		var all_sampled_prevalence := float(substantial_recipes) / float(maxi(sampled_region_count, 1))
		var prevalence_gate := not region_filter.is_empty() or all_sampled_prevalence >= 0.5
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
			"biomeRegionCounts": biome_region_counts,
			"buildMetrics": build_metrics,
			"overlayDeterminismVerified": overlay_determinism_verified,
			"primarySuccessRegions": primary_success_regions,
			"fallbackRescuedRegions": fallback_rescued_regions,
			"allSampledSubstantialAcceptanceRate": all_sampled_prevalence,
			"minimumVerticalTravelMeters": minimum_vertical_travel,
			"maximumVerticalTravelMeters": maximum_vertical_travel,
			"minimumDepthLevels": minimum_depth_levels,
			"passed": proposal_conditioned_regions > 0 and proposal_conditioned_rate >= 0.5
				and prevalence_gate and minimum_vertical_travel >= SUBSTANTIAL_NETWORK_MIN_DEPTH_METRES
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

func check_depth_tier_link_roof(world, recipe: Dictionary, floor_point: Vector3,
		from_tier: int, to_tier: int) -> Dictionary:
	var sample := floor_point + Vector3.UP * (2.7 * 2.0 + 0.2)
	var linked_chamber_indices := [3 + from_tier, 3 + to_tier]
	var unowned_openings: Array[Vector3] = []
	# Only a linked chamber may explain an opening at a link/chamber junction.
	# Walk vertically at this exact x/z until outside the chamber field's 2m
	# noisy/softened region; this computes the local cap instead of using a
	# chamber's global top and records unexplained voids along the way.
	var chamber_field_active := true
	var scan_y := sample.y
	var chamber_field_exit_found := false
	for _scan in range(48):
		chamber_field_active = false
		var scan_point := Vector3(floor_point.x, scan_y, floor_point.z)
		for chamber_index in linked_chamber_indices:
			if chamber_index < 0 or chamber_index >= recipe.chambers.size():
				continue
			var chamber: Dictionary = recipe.chambers[chamber_index]
			var chamber_q: Vector3 = (scan_point - chamber.center) / chamber.radii
			var chamber_sdf := (chamber_q.length() - 1.0) * minf(chamber.radii.x,
				minf(chamber.radii.y, chamber.radii.z))
			if chamber_sdf <= 2.0:
				chamber_field_active = true
				break
		if not chamber_field_active:
			chamber_field_exit_found = true
			var interval_surface := float(world.terrain_reference_surface_y_at(scan_point))
			if world.density_from_components(scan_point, interval_surface, interval_surface) < 0.0:
				unowned_openings.append(scan_point)
			break
		scan_y += 0.5
	if not chamber_field_exit_found:
		unowned_openings.append(Vector3(floor_point.x, scan_y, floor_point.z))
	sample.y = scan_y
	return {"sample": sample, "unowned_openings": unowned_openings}

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
				print("CAVE MISSING FLOOR POINT ", label, " guide=", floor_point,
					" below=", below, " ground=", world.volume_ground_height_near(floor_point),
					" oracleDensity=", oracle.recipe_density(below, recipe),
					" nativeDensity=", world.density_from_components(below, below_surface, below_surface))
				if not support_debug_emitted:
					var cell: Vector3i = world.world_to_cell3(below)
					var nearest := {"distance": INF}
					for segment_index in range(recipe.segments.size()):
						var segment: Dictionary = recipe.segments[segment_index]
						var segment_a: Vector3 = segment.a
						var segment_b: Vector3 = segment.b
						var horizontal := Vector2(segment_b.x - segment_a.x, segment_b.z - segment_a.z)
						var t := clampf(Vector2(below.x - segment_a.x, below.z - segment_a.z).dot(horizontal)
							/ maxf(horizontal.length_squared(), 0.001), 0.0, 1.0)
						var axis := segment_a.lerp(segment_b, t)
						var radius := lerpf(float(segment.get("radius", 2.7)),
							float(segment.get("radius_end", segment.get("radius", 2.7))), t)
						var vertical_radius := lerpf(float(segment.get("vertical_radius", radius)),
							float(segment.get("vertical_radius_end", segment.get("vertical_radius", radius))), t)
						var delta := below - (axis + Vector3.UP * vertical_radius)
						var normalized_distance := sqrt(Vector2(delta.x, delta.z).length_squared() / (radius * radius)
							+ pow(delta.y / vertical_radius, 2.0))
						if normalized_distance < float(nearest["distance"]):
							nearest = {"index": segment_index, "axis": axis,
								"normalizedDistance": normalized_distance, "distance": normalized_distance}
					print("CAVE MISSING FLOOR ", label, " guide=", floor_point,
						" below=", below, " ground=", world.volume_ground_height_near(floor_point),
						" oracleDensity=", oracle.recipe_density(below, recipe),
						" nativeDensity=", world.density_from_components(below, below_surface, below_surface),
						" latticeCell=", cell, ":", world.volume_density_at_grid_cell(cell),
						" nearestSegment=", nearest)
					support_debug_emitted = true

func links_form_alternate_routes(recipe: Dictionary, failures: Array, region: Vector2i) -> bool:
	var tier_count: int = recipe.depthLoops.size()
	var graph := {}
	var edge_count := 0
	for tier in range(tier_count):
		for portal in range(4):
			graph["%d:%d" % [tier, portal]] = []
		# Actual geometry is floor->entrance->A->B->entrance: the entrance/A/B
		# triangle is the loop, and floor->entrance is its trunk stem.
		for edge in [[0, 1], [1, 2], [2, 3], [3, 1]]:
			add_graph_edge(graph, "%d:%d" % [tier, edge[0]], "%d:%d" % [tier, edge[1]])
			edge_count += 1
	for tier in range(tier_count - 1):
		# Each interval is floor_i -> collar_i -> floor_(i+1) in deepRoute.
		# The named node lets the proof remove both trunk segments as one transition.
		var trunk_collar := "trunk:%d" % tier
		graph[trunk_collar] = []
		add_graph_edge(graph, "%d:0" % tier, trunk_collar)
		add_graph_edge(graph, trunk_collar, "%d:0" % (tier + 1))
		edge_count += 2
	var link_edges := {}
	for link in recipe.get("depthTierLinks", []):
		var from_tier := int(link.fromTier)
		var to_tier := int(link.toTier)
		if from_tier < 0 or to_tier != from_tier + 1 or to_tier >= tier_count:
			return false
		var from_portal := "%d:2" % from_tier
		var to_portal := "%d:3" % to_tier
		add_graph_edge(graph, from_portal, to_portal)
		link_edges["%d-%d" % [from_tier, to_tier]] = [from_portal, to_portal]
		edge_count += 1
	var component_count := graph_component_count(graph)
	var cycle_rank := edge_count - graph.size() + component_count
	if component_count != 1 or cycle_rank < tier_count + link_edges.size():
		return false
	for link in recipe.get("depthTierLinks", []):
		var blocked_trunk := int(link.fromTier)
		var from_floor := "%d:0" % blocked_trunk
		var to_floor := "%d:0" % (blocked_trunk + 1)
		if not graph_reachable(graph, from_floor, to_floor, blocked_trunk):
			return false
		var link_key := "%d-%d" % [link.fromTier, link.toTier]
		var link_edge: Array = link_edges.get(link_key, [])
		if link_edge.size() != 2 or graph_reachable(graph, from_floor, to_floor,
				blocked_trunk, str(link_edge[0]), str(link_edge[1])):
			return false
	return true

func add_graph_edge(graph: Dictionary, a: String, b: String) -> void:
	graph[a].append(b)
	graph[b].append(a)

func graph_reachable(graph: Dictionary, start: String, target: String, blocked_trunk: int,
		blocked_link_a: String = "", blocked_link_b: String = "") -> bool:
	var pending := [start]
	var visited := {start: true}
	while not pending.is_empty():
		var node: String = pending.pop_front()
		if node == target:
			return true
		for next in graph[node]:
			if (node == "trunk:%d" % blocked_trunk or next == "trunk:%d" % blocked_trunk) \
					or (node == blocked_link_a and next == blocked_link_b) \
					or (node == blocked_link_b and next == blocked_link_a):
				continue
			if not visited.has(next):
				visited[next] = true
				pending.append(next)
	return false

func graph_component_count(graph: Dictionary) -> int:
	var unseen := graph.keys()
	var count := 0
	while not unseen.is_empty():
		count += 1
		var pending := [unseen.pop_back()]
		while not pending.is_empty():
			var node: String = pending.pop_front()
			for next in graph[node]:
				if unseen.has(next):
					unseen.erase(next)
					pending.append(next)
	return count
