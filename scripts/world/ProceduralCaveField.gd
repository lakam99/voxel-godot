extends RefCounted
class_name ProceduralCaveField

# Negative values remove rock from the SAME density field consumed by volume,
# digging and Transvoxel. Recipes describe carving, never substitute meshes.
const REGION_METRES := 192.0
const RECIPE_CACHE_LIMIT := 128
const ROCK := 8.0
const TUNNEL_RADIUS := 2.7
const DEEP_LEVEL_DROP_METERS := 18.0
const MAX_DEEP_LEVELS := 7

var seed_text := ""
var recipes := {}
var recipe_diagnostics := {}
var recipe_build_count := 0
var recipe_build_total_usec := 0
var recipe_build_max_usec := 0
var cache_evictions := 0
var shape_noise := FastNoiseLite.new()
var detail_noise := FastNoiseLite.new()

func setup(seed_value: String) -> void:
	if seed_text == seed_value and not seed_text.is_empty():
		return
	seed_text = seed_value
	recipes.clear()
	recipe_diagnostics.clear()
	configure_noise(shape_noise, "chambers", 0.032)
	configure_noise(detail_noise, "rock", 0.19)

func configure_noise(noise: FastNoiseLite, salt: String, frequency: float) -> void:
	noise.seed = stable_hash(seed_text + ":caves:" + salt) & 0x7fffffff
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = frequency
	noise.fractal_octaves = 2
	noise.fractal_gain = 0.45

func clear() -> void:
	recipes.clear()
	recipe_diagnostics.clear()

func region_at(position: Vector3) -> Vector2i:
	return Vector2i(floori((position.x + REGION_METRES * 0.5) / REGION_METRES), floori((position.z + REGION_METRES * 0.5) / REGION_METRES))

func density(position: Vector3, depth_metres: float, generation) -> float:
	# Recipes are the sole generated cave authority. Unauthored underground
	# remains solid until a recipe or durable terrain edit removes it.
	var recipe := recipe_for_region(region_at(position), generation)
	if recipe.is_empty():
		return ROCK
	var bounds: AABB = recipe.bounds
	if not bounds.has_point(position):
		return ROCK
	var carved := recipe_density(position, recipe)
	if carved < 1.0:
		var detail := detail_noise.get_noise_3dv(position) * 0.24
		# Roughen the cave-facing wall, but do not let positive cave SDF values
		# become negative and punch a hairline skylight through thin overburden.
		# Roughness must not re-solidify recipe-owned air. On solid-side walls,
		# bias outward to preserve the thin-roof skylight guard.
		carved += minf(detail, -carved - 0.02) if carved < 0.0 else maxf(detail, -carved + 0.04)
	# An accepted recipe owns its bounded cave volume. Independent noise caves
	# must not undercut recipe floors and create accidental shafts.
	return carved

func recipe_density(position: Vector3, recipe: Dictionary) -> float:
	var result := ROCK
	for segment in recipe.segments:
		var bounds: AABB = segment.bounds
		if not bounds.has_point(position):
			continue
		var a: Vector3 = segment.a
		var b: Vector3 = segment.b
		var horizontal := Vector2(b.x - a.x, b.z - a.z)
		var t := clampf(Vector2(position.x - a.x, position.z - a.z).dot(horizontal) / maxf(horizontal.length_squared(), 0.001), 0.0, 1.0)
		var floor_point := a.lerp(b, t)
		var radius := lerpf(float(segment.get("radius", TUNNEL_RADIUS)), float(segment.get("radius_end", segment.get("radius", TUNNEL_RADIUS))), t)
		var vertical_radius := lerpf(float(segment.get("vertical_radius", radius)), float(segment.get("vertical_radius_end", segment.get("vertical_radius", radius))), t)
		var center := floor_point + Vector3.UP * vertical_radius
		var delta := position - center
		var horizontal_squared := Vector2(delta.x, delta.z).length_squared() / (radius * radius)
		var vertical := delta.y / vertical_radius
		var distance := (sqrt(horizontal_squared + vertical * vertical) - 1.0) * minf(radius, vertical_radius)
		result = minf(result, distance)
	for chamber in recipe.chambers:
		var radii: Vector3 = chamber.radii
		var center: Vector3 = chamber.center
		var q := (position - center) / radii
		var distance := (q.length() - 1.0) * minf(radii.x, minf(radii.y, radii.z))
		if distance < 2.0:
			distance += shape_noise.get_noise_3dv(position * 2.3) * 1.1
		var blend := maxf(1.8 - absf(result - distance), 0.0) / 1.8
		result = minf(result, distance) - blend * blend * 1.8 * 0.25
	return result

func dry_carver_at(position: Vector3, generation) -> bool:
	var recipe := recipe_for_region(region_at(position), generation)
	return not recipe.is_empty() and (recipe.bounds as AABB).has_point(position) and recipe_density(position, recipe) < 0.5

func recipe_for_region(region: Vector2i, generation) -> Dictionary:
	if recipes.has(region):
		return recipes[region]
	var started := Time.get_ticks_usec()
	var diagnostics := {}
	var recipe := build_recipe(region, generation, diagnostics)
	var elapsed := Time.get_ticks_usec() - started
	recipe_build_count += 1
	recipe_build_total_usec += elapsed
	recipe_build_max_usec = maxi(recipe_build_max_usec, elapsed)
	if recipes.size() >= RECIPE_CACHE_LIMIT:
		recipes.clear()
		recipe_diagnostics.clear()
		cache_evictions += 1
	recipes[region] = recipe
	recipe_diagnostics[region] = diagnostics.duplicate(true)
	return recipe

func build_diagnostics_for_region(region: Vector2i) -> Dictionary:
	return (recipe_diagnostics.get(region, {}) as Dictionary).duplicate(true)

func build_recipe(region: Vector2i, generation, diagnostics: Dictionary = {}) -> Dictionary:
	var started := Time.get_ticks_usec()
	var attempts: Array[Dictionary] = []
	var aggregate := {"highlandCenter": false, "validEntrance": false,
		"depthCapacity": false, "proposalConditioned": false}
	var attempt_diagnostics := {}
	var recipe := build_recipe_at_offset(region, generation, Vector3.ZERO, attempt_diagnostics)
	attempts.append(attempt_diagnostics)
	merge_attempt_admission(aggregate, attempt_diagnostics)
	if not recipe.is_empty():
		return finish_recipe_build(diagnostics, aggregate, attempts, started, recipe)
	if int(attempt_diagnostics.get("directionsEvaluated", 0)) != 8:
		return finish_recipe_build(diagnostics, aggregate, attempts, started, recipe)
	var offset_rng := RandomNumberGenerator.new()
	offset_rng.seed = stable_hash("%s:cave-center-fallback:%d,%d" % [seed_text, region.x, region.y])
	var first_angle := offset_rng.randf_range(0.0, TAU)
	for index in range(4):
		var angle := first_angle + float(index) * TAU / 4.0
		var offset := Vector3(cos(angle) * 28.0, 0.0, sin(angle) * 28.0)
		attempt_diagnostics = {}
		recipe = build_recipe_at_offset(region, generation, offset, attempt_diagnostics)
		attempts.append(attempt_diagnostics)
		merge_attempt_admission(aggregate, attempt_diagnostics)
		if not recipe.is_empty():
			break
	return finish_recipe_build(diagnostics, aggregate, attempts, started, recipe)

func finish_recipe_build(diagnostics: Dictionary, aggregate: Dictionary,
		attempts: Array[Dictionary], started: int, recipe: Dictionary) -> Dictionary:
	var terminal_reasons := {}
	var directions_evaluated := 0
	var full_recipe_attempts := 0
	for attempt in attempts:
		var reason := str(attempt.get("reason", "missing_reason"))
		terminal_reasons[reason] = int(terminal_reasons.get(reason, 0)) + 1
		directions_evaluated += int(attempt.get("directionsEvaluated", 0))
		full_recipe_attempts += int(attempt.get("fullRecipeAttempts", 0))
	diagnostics.merge(aggregate, true)
	diagnostics["centerAttempts"] = attempts.duplicate(true)
	diagnostics["centersAttempted"] = attempts.size()
	diagnostics["directionsEvaluated"] = directions_evaluated
	diagnostics["fullRecipeAttempts"] = full_recipe_attempts
	diagnostics["terminalReasons"] = terminal_reasons
	diagnostics["buildTimeUsec"] = Time.get_ticks_usec() - started
	diagnostics["reason"] = "accepted" if not recipe.is_empty() else str(attempts.back().get("reason", "no_valid_entrance"))
	return recipe

func merge_attempt_admission(aggregate: Dictionary, attempt: Dictionary) -> void:
	for key in ["highlandCenter", "validEntrance", "depthCapacity", "proposalConditioned"]:
		aggregate[key] = bool(aggregate[key]) or bool(attempt.get(key, false))

func increment_count(counts: Dictionary, key: String) -> void:
	counts[key] = int(counts.get(key, 0)) + 1

func build_recipe_at_offset(region: Vector2i, generation, center_offset: Vector3,
		diagnostics: Dictionary) -> Dictionary:
	# Local RNG does not consume/reorder the terrain, town or prop RNG streams.
	diagnostics.merge({"highlandCenter": false, "validEntrance": false,
		"depthCapacity": false, "proposalConditioned": false}, false)
	var rng := RandomNumberGenerator.new()
	rng.seed = stable_hash("%s:cave-region:%d,%d" % [seed_text, region.x, region.y])
	var center := Vector3(region.x * REGION_METRES + rng.randf_range(-14.0, 14.0), 0.0, region.y * REGION_METRES + rng.randf_range(-14.0, 14.0))
	if center_offset != Vector3.ZERO:
		center += center_offset
	diagnostics["center"] = center
	diagnostics["directionRejections"] = {}
	diagnostics["candidateRejections"] = {}
	diagnostics["directionsEvaluated"] = 0
	diagnostics["candidateDirections"] = 0
	diagnostics["fullRecipeAttempts"] = 0
	if region_at(center) != region:
		return reject_recipe(diagnostics, "center_outside_region")
	center.y = float(generation.terrain_reference_surface_y_at(center))
	diagnostics["highlandCenter"] = center.y >= 19.0
	var length := rng.randf_range(43.0, 52.0)
	var phase := rng.randf_range(0.0, TAU)
	var bend := rng.randf_range(-7.0, 7.0)
	var entrance_candidates: Array[Dictionary] = []
	var saw_drop_candidate := false
	var saw_descent_candidate := false
	var saw_capacity_candidate := false
	var saw_surface_crossing := false
	var saw_roof_failure := false
	var saw_grade_failure := false
	var lowest_cave_floor_y: float = float(generation.world_bottom_cell_y() + 4) * generation.cell_size()
	diagnostics["directionsEvaluated"] = 8
	for index in range(8):
		var angle := phase + float(index) * TAU / 8.0
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		var candidate := center + direction * length
		candidate.y = float(generation.terrain_reference_surface_y_at(candidate))
		if candidate.y < 17.0:
			increment_count(diagnostics["directionRejections"], "entry_too_low")
			continue
		var drop := center.y - candidate.y
		if drop < -3.0 or drop > 18.0:
			increment_count(diagnostics["directionRejections"], "entry_drop")
			continue
		diagnostics["validEntrance"] = true
		saw_drop_candidate = true
		var candidate_floor_end := minf(candidate.y - 7.5, center.y - 11.0)
		if candidate.y - candidate_floor_end > length * 0.35:
			increment_count(diagnostics["directionRejections"], "descent_limit")
			continue
		saw_descent_candidate = true
		var candidate_remaining_depth := (candidate_floor_end - 10.0) - lowest_cave_floor_y
		var candidate_level_count := clampi(floori(candidate_remaining_depth / DEEP_LEVEL_DROP_METERS), 0, MAX_DEEP_LEVELS)
		if candidate_level_count < 4:
			increment_count(diagnostics["directionRejections"], "depth_capacity")
			continue
		saw_capacity_candidate = true
		diagnostics["depthCapacity"] = true
		diagnostics["proposalConditioned"] = true
		var candidate_side := Vector3(-direction.z, 0.0, direction.x)
		var candidate_route := build_entrance_route(candidate, center, candidate_side, bend,
			candidate_floor_end, generation)
		if not route_stays_below_surface(generation, candidate_route):
			saw_surface_crossing = true
			increment_count(diagnostics["directionRejections"], "route_crosses_surface")
			continue
		var roof_margin := entrance_roof_margin(generation, candidate_route)
		if roof_margin < 0.0:
			saw_roof_failure = true
			increment_count(diagnostics["directionRejections"], "entrance_roof")
			continue
		if not route_guide_is_walkable(candidate_route):
			saw_grade_failure = true
			increment_count(diagnostics["directionRejections"], "entrance_guide_grade")
			continue
		var drop_preference := -absf(drop - 8.0)
		entrance_candidates.append({"entry": candidate, "outward": direction, "side": candidate_side,
			"floorEnd": candidate_floor_end, "route": candidate_route,
			"lowerLevelCount": candidate_level_count, "roofMargin": roof_margin,
			"roofMarginMillimeters": floori(roof_margin * 1000.0),
			"dropPreferenceMillimeters": floori(drop_preference * 1000.0), "candidateIndex": index})
	diagnostics["candidateDirections"] = entrance_candidates.size()
	if entrance_candidates.is_empty():
		if saw_capacity_candidate:
			if saw_roof_failure:
				return reject_recipe(diagnostics, "entrance_roof")
			if saw_surface_crossing:
				return reject_recipe(diagnostics, "route_crosses_surface")
			if saw_grade_failure:
				return reject_recipe(diagnostics, "entrance_grade")
		if saw_descent_candidate and not saw_capacity_candidate:
			return reject_recipe(diagnostics, "insufficient_world_depth")
		if saw_drop_candidate and not saw_descent_candidate:
			return reject_recipe(diagnostics, "entrance_descent_limit")
		return reject_recipe(diagnostics, "no_valid_entrance")
	entrance_candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a.roofMarginMillimeters) != int(b.roofMarginMillimeters):
			return int(a.roofMarginMillimeters) > int(b.roofMarginMillimeters)
		if int(a.dropPreferenceMillimeters) != int(b.dropPreferenceMillimeters):
			return int(a.dropPreferenceMillimeters) > int(b.dropPreferenceMillimeters)
		return int(a.candidateIndex) < int(b.candidateIndex))
	var branch_distance := rng.randf_range(15.0, 21.0)
	var requested_main_radii := Vector3(rng.randf_range(10.0, 14.0), rng.randf_range(5.0, 7.0), rng.randf_range(10.0, 13.0))
	var last_candidate_rejection := "no_valid_entrance"
	diagnostics["fullRecipeAttempts"] = entrance_candidates.size()
	for candidate_data in entrance_candidates:
		var candidate_diagnostics := {}
		var candidate_recipe := build_recipe_for_entrance(region, generation, candidate_data,
			branch_distance, requested_main_radii, candidate_diagnostics)
		if not candidate_recipe.is_empty():
			diagnostics["reason"] = "accepted"
			return candidate_recipe
		last_candidate_rejection = str(candidate_diagnostics.get("reason", last_candidate_rejection))
		if candidate_diagnostics.has("lastRejectionDetail"):
			diagnostics["lastRejectionDetail"] = candidate_diagnostics["lastRejectionDetail"]
		increment_count(diagnostics["candidateRejections"], last_candidate_rejection)
	return reject_recipe(diagnostics, last_candidate_rejection)

func build_recipe_for_entrance(region: Vector2i, generation, candidate: Dictionary,
		branch_distance: float, requested_main_radii: Vector3, diagnostics: Dictionary) -> Dictionary:
	var entry: Vector3 = candidate.entry
	var outward: Vector3 = candidate.outward
	var side: Vector3 = candidate.side
	var floor_end: float = candidate.floorEnd
	var route: Array[Vector3] = candidate.route
	var lower_level_count: int = candidate.lowerLevelCount
	var lowest_cave_floor_y: float = float(generation.world_bottom_cell_y() + 4) * generation.cell_size()
	var segments: Array[Dictionary] = []
	# Constrain the mouth to a player-clear arch, then widen only after the
	# route is below the natural hillside. A full-radius mouth excavates through
	# the roof and creates the very empty-sky void this field must avoid.
	append_tapered_arch_path(segments, route,
		[2.5, 2.3, 2.1, 2.1, 2.5, TUNNEL_RADIUS, TUNNEL_RADIUS],
		[1.35, 1.45, 1.45, 2.1, 2.5, TUNNEL_RADIUS, TUNNEL_RADIUS])
	if not interior_segments_keep_natural_roof(generation, segments, 1):
		return reject_recipe(diagnostics, "entrance_roof")
	var junction: Vector3 = route[3]
	var branch_end: Vector3 = route[5] + side * branch_distance
	branch_end.y = floor_end - 1.0
	var loop: Array[Vector3] = [junction, junction + side * 10.0 - Vector3.UP, branch_end, route[6]]
	append_path(segments, loop, TUNNEL_RADIUS)
	var deep_end: Vector3 = route[6] - outward * 23.0 - side * 12.0
	deep_end.y = floor_end - 10.0
	var deep_mid: Vector3 = route[6] - outward * 12.0 - Vector3.UP * 7.0
	var deep_path: Array[Vector3] = [route[6], deep_mid, deep_end]
	var first_angle := atan2(deep_end.z - route[6].z, deep_end.x - route[6].x)
	var lower_floors: Array[Vector3] = []
	for index in range(1, lower_level_count + 1):
		# Build a helical descent with 18m between floors; lateral chords and
		# alternating radii limit overlap while keeping the passage walkable.
		var angle := first_angle + float(index) * 1.7
		var orbit_radius := 32.0 + (4.0 if index % 2 == 0 else 0.0)
		var floor_point := route[6] + Vector3(cos(angle) * orbit_radius, 0.0, sin(angle) * orbit_radius)
		floor_point.y = deep_end.y - float(index) * DEEP_LEVEL_DROP_METERS
		var previous: Vector3 = deep_end if lower_floors.is_empty() else lower_floors.back()
		var incoming: Vector3 = deep_end - deep_mid if lower_floors.is_empty() else previous - (deep_end if lower_floors.size() == 1 else lower_floors[lower_floors.size() - 2])
		var incoming_length := maxf(Vector2(incoming.x, incoming.z).length(), 0.001)
		var departure := Vector3(-incoming.z / incoming_length, 0.0, incoming.x / incoming_length)
		var toward_next := floor_point - previous
		if departure.x * toward_next.x + departure.z * toward_next.z < 0.0:
			departure = -departure
		var collar := previous + departure * 20.0
		deep_path.append(collar)
		deep_path.append(floor_point)
		lower_floors.append(floor_point)
	var depth_loops: Array = []
	for index in range(lower_floors.size()):
		var floor_point: Vector3 = lower_floors[index]
		var previous: Vector3 = deep_end if index == 0 else lower_floors[index - 1]
		var incoming := floor_point - previous
		var incoming_length := maxf(Vector2(incoming.x, incoming.z).length(), 0.001)
		var departure := Vector3(-incoming.z / incoming_length, 0.0, incoming.x / incoming_length)
		var next: Vector3 = lower_floors[index + 1] if index + 1 < lower_floors.size() else floor_point
		if index + 1 < lower_floors.size() and departure.x * (next.x - floor_point.x) + departure.z * (next.z - floor_point.z) < 0.0:
			departure = -departure
		var outgoing_direction := departure
		var incoming_direction := Vector3(incoming.x / incoming_length, 0.0, incoming.z / incoming_length)
		var direction := outgoing_direction + incoming_direction
		var direction_length := Vector2(direction.x, direction.z).length()
		if direction_length > 0.001:
			direction /= direction_length
		else:
			direction = outgoing_direction
		var depth_side := Vector3(-direction.z, 0.0, direction.x)
		if depth_side.x * incoming.x + depth_side.z * incoming.z > 0.0:
			depth_side = -depth_side
		var along := direction * 14.0
		var across := depth_side * 28.0
		var entrance := floor_point + depth_side * 10.0
		depth_loops.append([floor_point, entrance, entrance + (along + across),
			entrance + (-along + across), entrance])
	var depth_tier_links: Array[Dictionary] = []
	# Stable links join opposite portals on non-consecutive loop pairs. Their
	# endpoints sit on the loop away from each loop's trunk junction.
	for from_tier in [0, 2]:
		if from_tier + 1 >= depth_loops.size():
			continue
		var start: Vector3 = (depth_loops[from_tier][2] + depth_loops[from_tier][3]) * 0.5
		var finish: Vector3 = (depth_loops[from_tier + 1][2] + depth_loops[from_tier + 1][3]) * 0.5
		var from_loop: Array = depth_loops[from_tier]
		var to_loop: Array = depth_loops[from_tier + 1]
		var from_center: Vector3 = route[6]
		var to_center: Vector3 = route[6]
		var start_outward := Vector3(start.x - from_center.x, 0.0, start.z - from_center.z).normalized()
		var end_outward := Vector3(finish.x - to_center.x, 0.0, finish.z - to_center.z).normalized()
		var start_collar := start + start_outward * 32.0
		var end_collar := finish + end_outward * 32.0
		start_collar.y = start.y
		end_collar.y = finish.y
		var ramp_delta := end_collar - start_collar
		var horizontal_length := maxf(Vector2(ramp_delta.x, ramp_delta.z).length(), 0.001)
		var lateral := Vector3(-ramp_delta.z / horizontal_length, 0.0, ramp_delta.x / horizontal_length)
		var ramp_mid := (start_collar + end_collar) * 0.5
		var away_from_core := ramp_mid - route[6]
		if lateral.x * away_from_core.x + lateral.z * away_from_core.z < 0.0:
			lateral = -lateral
		var points: Array[Vector3] = [start, start_collar]
		const RAMP_SUBDIVISIONS := 17
		for step in range(1, RAMP_SUBDIVISIONS):
			var t := float(step) / float(RAMP_SUBDIVISIONS)
			var point := start_collar + ramp_delta * t
			var lateral_curve_scale: float = 24.0 * sin(PI * t)
			point += lateral * lateral_curve_scale
			points.append(point)
		points.append(end_collar)
		points.append(finish)
		depth_tier_links.append({"id": "tier-link:%s:%d,%d:%d-%d" % [seed_text, region.x, region.y, from_tier, from_tier + 1],
			"fromTier": from_tier, "toTier": from_tier + 1, "points": points})
	append_path(segments, deep_path, 2.5)
	for depth_loop in depth_loops:
		append_path(segments, depth_loop, TUNNEL_RADIUS)
	for link in depth_tier_links:
		var link_radii: Array[float] = []
		var link_vertical_radii: Array[float] = []
		for _point in link.points:
			link_radii.append(TUNNEL_RADIUS)
			link_vertical_radii.append(2.2)
		append_tapered_arch_path(segments, link.points, link_radii, link_vertical_radii)
	if not interior_segments_keep_natural_roof(generation, segments, 1):
		return reject_recipe(diagnostics, "network_roof")
	var main_radii := requested_main_radii
	main_radii.y = fit_chamber_vertical_radius(generation, route[6], main_radii.x, main_radii.z, main_radii.y)
	if main_radii.y < TUNNEL_RADIUS:
		return reject_recipe(diagnostics, "main_chamber_clearance")
	var branch_radii := Vector3(6.0, 4.0, 7.0)
	branch_radii.y = fit_chamber_vertical_radius(generation, branch_end, branch_radii.x, branch_radii.z, branch_radii.y)
	if branch_radii.y < 2.5:
		return reject_recipe(diagnostics, "branch_chamber_clearance")
	var deep_radii := Vector3(8.0, 5.0, 9.0)
	deep_radii.y = fit_chamber_vertical_radius(generation, deep_end, deep_radii.x, deep_radii.z, deep_radii.y)
	if deep_radii.y < 2.5:
		return reject_recipe(diagnostics, "deep_chamber_clearance")
	var chambers: Array[Dictionary] = [
		{"center": route[6] + Vector3.UP * main_radii.y, "radii": main_radii},
		{"center": branch_end + Vector3.UP * branch_radii.y, "radii": branch_radii},
		{"center": deep_end + Vector3.UP * deep_radii.y, "radii": deep_radii}
	]
	for index in range(lower_level_count):
		var tier_floor: Vector3 = lower_floors[index]
		var floor_point: Vector3 = (depth_loops[index][2] + depth_loops[index][3]) * 0.5
		var radii := Vector3(7.0 + (1.0 if index % 2 == 0 else 0.0), 4.5,
			8.0 + (1.0 if index % 3 == 0 else 0.0))
		radii.y = fit_chamber_vertical_radius(generation, floor_point, radii.x, radii.z, radii.y)
		if radii.y < TUNNEL_RADIUS or tier_floor.y < lowest_cave_floor_y:
			return reject_recipe(diagnostics, "tier_chamber_clearance_or_world_bottom")
		chambers.append({"center": floor_point + Vector3.UP * radii.y, "radii": radii})
	var bounds: AABB = segments[0].bounds
	for segment in segments:
		bounds = bounds.merge(segment.bounds)
	for chamber in chambers:
		bounds = bounds.merge(AABB(chamber.center - chamber.radii - Vector3.ONE, chamber.radii * 2.0 + Vector3.ONE * 2.0))
	# Recipes stay wholly within their source region, so adjacent chunk queries
	# use identical recipes without scanning neighbouring regions per voxel.
	if region_at(bounds.position) != region or region_at(bounds.end) != region:
		return reject_recipe(diagnostics, "region_bounds")
	# Protect generated settlement footprints through their existing authority.
	# Reject a whole recipe; never plug a published entrance with a town mask.
	if generation.surface_town_intersects_bounds(bounds) or generation.generated_site_intersects_bounds(bounds):
		return reject_recipe(diagnostics, "protected_site")
	var candidate_recipe := {"bounds": bounds, "segments": segments, "chambers": chambers}
	if not route_effective_support_is_walkable(generation, route, candidate_recipe):
		return reject_recipe(diagnostics, "entrance_effective_grade")
	var deep_route_support_failure := {}
	if not route_effective_support_is_walkable(generation, deep_path, candidate_recipe, deep_route_support_failure):
		diagnostics["lastRejectionDetail"] = "deep_route:%s" % JSON.stringify(deep_route_support_failure)
		return reject_recipe(diagnostics, "deep_route_effective_grade")
	for link in depth_tier_links:
		var points: Array[Vector3] = link.points
		if points.size() < 2:
			return reject_recipe(diagnostics, "tier_link_path_invalid")
		for point_index in range(points.size()):
			var point: Vector3 = points[point_index]
			if point.y < lowest_cave_floor_y + generation.cell_size() * 4.0:
				return reject_recipe(diagnostics, "tier_link_world_bottom_reserve")
			if point_index > 0:
				var previous: Vector3 = points[point_index - 1]
				var run := Vector2(point.x - previous.x, point.z - previous.z).length()
				if run <= 0.01 or absf(point.y - previous.y) / run > tan(deg_to_rad(46.0)):
					return reject_recipe(diagnostics, "tier_link_grade")
		var support_failure := {}
		if not route_effective_support_is_walkable(generation, points, candidate_recipe, support_failure):
			diagnostics["lastRejectionDetail"] = "%s:%s" % [str(link.id), JSON.stringify(support_failure)]
			return reject_recipe(diagnostics, "tier_link_effective_support")
	diagnostics["reason"] = "accepted"
	return {"id": "cave:%d,%d" % [region.x, region.y], "region": region, "entry": entry, "outward": outward, "route": route, "loop": loop, "deepRoute": deep_path, "depthLoops": depth_loops, "depthTierLinks": depth_tier_links, "segments": segments, "chambers": chambers, "bounds": bounds}

func reject_recipe(diagnostics: Dictionary, reason: String) -> Dictionary:
	diagnostics["reason"] = reason
	return {}

func build_entrance_route(entry: Vector3, center: Vector3, side: Vector3,
		bend: float, floor_end: float, generation) -> Array[Vector3]:
	var route: Array[Vector3] = []
	for index in range(7):
		var t := float(index) / 6.0
		var point := entry.lerp(center, t) + side * (sin(t * PI) * bend + sin(t * TAU) * 2.0)
		# The mouth starts below the surface and descends gradually under natural rock.
		point.y = lerpf(entry.y - generation.cell_size() * 0.25, floor_end, pow(t, 0.4))
		route.append(point)
	# Raise the first interior control point into the natural hillside so the
	# entrance collar does not stack its descent on a steep surface grade.
	route[1].y += 0.25
	return route

func route_stays_below_surface(generation, route: Array[Vector3]) -> bool:
	for index in range(route.size() - 1):
		for step in range(5):
			var floor_point := route[index].lerp(route[index + 1], float(step) / 4.0)
			if floor_point.y - 0.3 > float(generation.terrain_reference_surface_y_at(floor_point)):
				return false
	return true

func route_guide_is_walkable(route: Array[Vector3]) -> bool:
	for index in range(route.size() - 1):
		var a: Vector3 = route[index]
		var b: Vector3 = route[index + 1]
		var horizontal_run := Vector2(b.x - a.x, b.z - a.z).length()
		if horizontal_run > 0.01 and absf(b.y - a.y) / horizontal_run > tan(deg_to_rad(46.0)):
			return false
	return true

func route_effective_support_is_walkable(generation, route: Array[Vector3], recipe: Dictionary,
		failure_detail: Dictionary = {}) -> bool:
	# Match CaveGenerationContractRunner.check_path against this candidate's own
	# cave SDF, sampled on the same terrain lattice and interpolated ground column.
	# This prevents a roof-preferred entrance from being accepted on a guide-only
	# grade that the effective volume turns into an unwalkable ramp.
	var previous := Vector3.INF
	for index in range(route.size() - 1):
		var a: Vector3 = route[index]
		var b: Vector3 = route[index + 1]
		for step in range(11):
			var guide_floor := a.lerp(b, float(step) / 10.0)
			var ground_y := candidate_ground_height_near(generation, guide_floor, recipe)
			if is_nan(ground_y):
				failure_detail["reason"] = "no_effective_floor"
				failure_detail["guide"] = guide_floor
				return false
			if absf(ground_y - guide_floor.y) > 3.0:
				failure_detail["reason"] = "floor_offset"
				failure_detail["guide"] = guide_floor
				failure_detail["groundY"] = ground_y
				return false
			var support_floor := guide_floor
			support_floor.y = ground_y
			if previous != Vector3.INF:
				var run := Vector2(support_floor.x - previous.x, support_floor.z - previous.z).length()
				if run > 0.01 and absf(support_floor.y - previous.y) / run > tan(deg_to_rad(46.0)):
					failure_detail["reason"] = "effective_floor_grade"
					failure_detail["previous"] = previous
					failure_detail["current"] = support_floor
					return false
			previous = support_floor
	return true

func candidate_ground_height_near(generation, position: Vector3, recipe: Dictionary) -> float:
	var cell_size := float(generation.cell_size())
	var lattice := position / cell_size
	var x := floori(lattice.x)
	var z := floori(lattice.z)
	var fraction := Vector2(lattice.x - x, lattice.z - z)
	var start_height := lattice.y + 0.95
	var start_y := floori(start_height)
	var lower_density := candidate_volume_column_density(generation, recipe, x, start_y, z, fraction)
	var upper_density := candidate_volume_column_density(generation, recipe, x, start_y + 1, z, fraction)
	var previous_density := lerpf(lower_density, upper_density, start_height - start_y)
	if previous_density >= 0.0:
		return NAN
	var previous_height := start_height
	for y in range(start_y, floori(lattice.y - 14.0) - 1, -1):
		var density := candidate_volume_column_density(generation, recipe, x, y, z, fraction)
		if density >= 0.0 and previous_density < 0.0:
			return lerpf(float(y), previous_height, density / maxf(density - previous_density, 0.0001)) * cell_size
		previous_density = density
		previous_height = float(y)
	return NAN

func candidate_volume_column_density(generation, recipe: Dictionary, x: int, y: int, z: int, fraction: Vector2) -> float:
	var a := candidate_volume_density_at_cell(generation, recipe, Vector3i(x, y, z))
	var b := candidate_volume_density_at_cell(generation, recipe, Vector3i(x + 1, y, z))
	var c := candidate_volume_density_at_cell(generation, recipe, Vector3i(x, y, z + 1))
	var d := candidate_volume_density_at_cell(generation, recipe, Vector3i(x + 1, y, z + 1))
	return lerpf(lerpf(a, b, fraction.x), lerpf(c, d, fraction.x), fraction.y)

func candidate_volume_density_at_cell(generation, recipe: Dictionary, cell: Vector3i) -> float:
	var cell_size := float(generation.cell_size())
	var position := Vector3(cell) * cell_size
	# Recipe admission is source-generation state: player/save edits publish over
	# this field but must not affect which immutable cave recipe is generated.
	var surface_y := float(generation.terrain_reference_surface_y_at(position))
	var density := minf(surface_y - position.y, candidate_cave_density(position, recipe))
	if position.y <= float(generation.world_bottom_cell_y()) * cell_size:
		density = maxf(density, cell_size * 4.0)
	return density

func candidate_cave_density(position: Vector3, recipe: Dictionary) -> float:
	if not (recipe.bounds as AABB).has_point(position):
		return ROCK
	var carved := recipe_density(position, recipe)
	if carved < 1.0:
		var detail := detail_noise.get_noise_3dv(position) * 0.24
		carved += minf(detail, -carved - 0.02) if carved < 0.0 else maxf(detail, -carved + 0.04)
	return carved

func entrance_roof_margin(generation, route: Array[Vector3]) -> float:
	var vertical_radii: Array[float] = [1.35, 1.45, 1.45, 2.1, 2.5, TUNNEL_RADIUS, TUNNEL_RADIUS]
	var reserve := float(generation.cell_size()) * 1.15
	var minimum_margin := INF
	for segment_index in range(1, route.size() - 1):
		var a: Vector3 = route[segment_index]
		var b: Vector3 = route[segment_index + 1]
		for sample_index in range(5):
			var t := float(sample_index) / 4.0
			var floor_point := a.lerp(b, t)
			var vertical_radius := lerpf(vertical_radii[segment_index], vertical_radii[segment_index + 1], t)
			var margin := float(generation.terrain_reference_surface_y_at(floor_point)) \
				- (floor_point.y + vertical_radius * 2.0 + reserve)
			minimum_margin = minf(minimum_margin, margin)
	return minimum_margin

func append_path(segments: Array[Dictionary], points: Array, radius: float) -> void:
	for index in range(points.size() - 1):
		var a: Vector3 = points[index]
		var b: Vector3 = points[index + 1]
		var bounds := AABB(a, Vector3.ZERO).expand(b).grow(radius + 1.0)
		bounds.size.y += radius
		segments.append({"a": a, "b": b, "radius": radius, "radius_end": radius, "bounds": bounds})

func append_tapered_path(segments: Array[Dictionary], points: Array[Vector3], radii: Array) -> void:
	for index in range(points.size() - 1):
		var a: Vector3 = points[index]
		var b: Vector3 = points[index + 1]
		var radius_start := float(radii[index])
		var radius_end := float(radii[index + 1])
		var bounds_radius := maxf(radius_start, radius_end)
		var bounds := AABB(a, Vector3.ZERO).expand(b).grow(bounds_radius + 1.0)
		bounds.size.y += bounds_radius
		segments.append({"a": a, "b": b, "radius": radius_start, "radius_end": radius_end,
			"bounds": bounds})

func append_tapered_arch_path(segments: Array[Dictionary], points: Array[Vector3], radii: Array, vertical_radii: Array) -> void:
	for index in range(points.size() - 1):
		var a: Vector3 = points[index]
		var b: Vector3 = points[index + 1]
		var radius_start := float(radii[index])
		var radius_end := float(radii[index + 1])
		var vertical_start := float(vertical_radii[index])
		var vertical_end := float(vertical_radii[index + 1])
		var bounds_radius := maxf(maxf(radius_start, radius_end), maxf(vertical_start, vertical_end))
		var bounds := AABB(a, Vector3.ZERO).expand(b).grow(bounds_radius + 1.0)
		bounds.size.y += bounds_radius
		var segment := {"a": a, "b": b, "radius": radius_start, "radius_end": radius_end, "bounds": bounds}
		if vertical_start != radius_start or vertical_end != radius_end:
			segment["vertical_radius"] = vertical_start
			segment["vertical_radius_end"] = vertical_end
		segments.append(segment)

func interior_segments_keep_natural_roof(generation, segments: Array[Dictionary], first_interior_segment: int) -> bool:
	var reserve := float(generation.cell_size()) * 1.15
	for segment_index in range(first_interior_segment, segments.size()):
		var segment: Dictionary = segments[segment_index]
		var a: Vector3 = segment.a
		var b: Vector3 = segment.b
		var radius_start := float(segment.get("vertical_radius", segment.get("radius", TUNNEL_RADIUS)))
		var radius_end := float(segment.get("vertical_radius_end", segment.get("radius_end", radius_start)))
		for sample_index in range(5):
			var t := float(sample_index) / 4.0
			var floor_point := a.lerp(b, t)
			var radius := lerpf(radius_start, radius_end, t)
			if floor_point.y + radius * 2.0 + reserve > float(generation.terrain_reference_surface_y_at(floor_point)):
				return false
	return true

func fit_chamber_vertical_radius(generation, floor_point: Vector3, radius_x: float, radius_z: float, requested_radius: float) -> float:
	# Preserve a real rock roof, including the field's bounded chamber/detail
	# perturbation, at the top of every chamber. Fit by the surface below each
	# point on the ellipsoid cap while keeping its bottom anchored to the route.
	var reserve := float(generation.cell_size()) + 1.1 + 0.24
	var fitted := requested_radius
	for x_step in range(-4, 5):
		for z_step in range(-4, 5):
			var nx := float(x_step) * 0.2
			var nz := float(z_step) * 0.2
			var radial_squared := nx * nx + nz * nz
			if radial_squared >= 1.0:
				continue
			var surface_y := float(generation.terrain_reference_surface_y_at(Vector3(
				floor_point.x + nx * radius_x, 0.0, floor_point.z + nz * radius_z)))
			var cap_factor := 1.0 + sqrt(1.0 - radial_squared)
			var allowed_radius := (surface_y - floor_point.y - reserve) / cap_factor
			fitted = minf(fitted, allowed_radius)
	return fitted

func stable_hash(value: String) -> int:
	var result := 2166136261
	for index in range(value.length()):
		result = int((result ^ value.unicode_at(index)) * 16777619) & 0xffffffff
	return result
