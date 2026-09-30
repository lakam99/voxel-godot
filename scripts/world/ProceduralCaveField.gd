extends RefCounted
class_name ProceduralCaveField

# Negative values remove rock from the SAME density field consumed by volume,
# digging and Transvoxel. Recipes describe carving, never substitute meshes.
const REGION_METRES := 192.0
const RECIPE_CACHE_LIMIT := 128
const ROCK := 8.0
const TUNNEL_RADIUS := 2.7

var seed_text := ""
var recipes := {}
var recipe_build_count := 0
var recipe_build_total_usec := 0
var recipe_build_max_usec := 0
var cache_evictions := 0
var shape_noise := FastNoiseLite.new()
var tunnel_noise := FastNoiseLite.new()
var crossing_noise := FastNoiseLite.new()
var detail_noise := FastNoiseLite.new()

func setup(seed_value: String) -> void:
	if seed_text == seed_value and not seed_text.is_empty():
		return
	seed_text = seed_value
	recipes.clear()
	configure_noise(shape_noise, "chambers", 0.032)
	configure_noise(tunnel_noise, "passages", 0.022)
	configure_noise(crossing_noise, "passage-crossings", 0.024)
	configure_noise(detail_noise, "rock", 0.19)

func configure_noise(noise: FastNoiseLite, salt: String, frequency: float) -> void:
	noise.seed = stable_hash(seed_text + ":caves:" + salt) & 0x7fffffff
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = frequency
	noise.fractal_octaves = 2
	noise.fractal_gain = 0.45

func clear() -> void:
	recipes.clear()

func region_at(position: Vector3) -> Vector2i:
	return Vector2i(floori((position.x + REGION_METRES * 0.5) / REGION_METRES), floori((position.z + REGION_METRES * 0.5) / REGION_METRES))

func density(position: Vector3, depth_metres: float, generation) -> float:
	var result := ROCK
	# Deep noise supplies irregular cheese chambers and intersecting spaghetti
	# passages. The near-surface connection is made by continuous tunnel carvers.
	if depth_metres > 28.0:
		var a := shape_noise.get_noise_3dv(position)
		var b := tunnel_noise.get_noise_3dv(position + Vector3(873.0, -211.0, 397.0))
		var c := crossing_noise.get_noise_3dv(position)
		var cheese := (0.43 - a) * 22.0
		var spaghetti := (maxf(absf(b), absf(c)) - 0.065) * 36.0
		result = maxf(minf(cheese, spaghetti), 30.0 - depth_metres)
	var recipe := recipe_for_region(region_at(position), generation)
	if recipe.is_empty():
		return result
	var bounds: AABB = recipe.bounds
	if not bounds.has_point(position):
		return result
	var carved := recipe_density(position, recipe)
	if carved < 1.0:
		var detail := detail_noise.get_noise_3dv(position) * 0.24
		# Roughen the cave-facing wall, but do not let positive cave SDF values
		# become negative and punch a hairline skylight through thin overburden.
		carved += detail if carved < 0.0 else maxf(detail, -carved + 0.04)
	return minf(result, carved)

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
	var recipe := build_recipe(region, generation)
	var elapsed := Time.get_ticks_usec() - started
	recipe_build_count += 1
	recipe_build_total_usec += elapsed
	recipe_build_max_usec = maxi(recipe_build_max_usec, elapsed)
	if recipes.size() >= RECIPE_CACHE_LIMIT:
		recipes.clear()
		cache_evictions += 1
	recipes[region] = recipe
	return recipe

func build_recipe(region: Vector2i, generation) -> Dictionary:
	# Local RNG does not consume/reorder the terrain, town or prop RNG streams.
	var rng := RandomNumberGenerator.new()
	rng.seed = stable_hash("%s:cave-region:%d,%d" % [seed_text, region.x, region.y])
	if rng.randf() > 0.72:
		return {}
	var center := Vector3(region.x * REGION_METRES + rng.randf_range(-14.0, 14.0), 0.0, region.y * REGION_METRES + rng.randf_range(-14.0, 14.0))
	center.y = float(generation.terrain_reference_surface_y_at(center))
	if center.y < 19.0:
		return {}
	var length := rng.randf_range(43.0, 52.0)
	var phase := rng.randf_range(0.0, TAU)
	var entry := Vector3.ZERO
	var outward := Vector3.ZERO
	var best_score := -INF
	for index in range(8):
		var angle := phase + float(index) * TAU / 8.0
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		var candidate := center + direction * length
		candidate.y = float(generation.terrain_reference_surface_y_at(candidate))
		if candidate.y < 17.0:
			continue
		var drop := center.y - candidate.y
		if drop < -3.0 or drop > 18.0:
			continue
		var score := -absf(drop - 8.0)
		if score > best_score:
			best_score = score
			entry = candidate
			outward = direction
	if outward == Vector3.ZERO:
		return {}
	var side := Vector3(-outward.z, 0.0, outward.x)
	var bend := rng.randf_range(-7.0, 7.0)
	var floor_end := minf(entry.y - 7.5, center.y - 11.0)
	if entry.y - floor_end > length * 0.35:
		return {}
	var route: Array[Vector3] = []
	for index in range(7):
		var t := float(index) / 6.0
		var point := entry.lerp(center, t) + side * (sin(t * PI) * bend + sin(t * TAU) * 2.0)
		# The mouth must overlap a real below-surface volume cell. Starting the
		# tunnel floor at the surface leaves only skylight above an intact sill.
		# Lower the entrance ramp enough to acquire a roof beneath the hillside,
		# without the old near-step profile that dropped most of the elevation
		# in the first few metres.
		point.y = lerpf(entry.y - generation.cell_size() * 0.25, floor_end, pow(t, 0.4))
		route.append(point)
	# A carver can only remove rock: never accept a tunnel crossing above a
	# valley and then invent a separate floor to make the route look supported.
	for index in range(route.size() - 1):
		for step in range(5):
			var floor_point := route[index].lerp(route[index + 1], float(step) / 4.0)
			if floor_point.y - 0.3 > float(generation.terrain_reference_surface_y_at(floor_point)):
				return {}
	var segments: Array[Dictionary] = []
	# Constrain the mouth to a player-clear arch, then widen only after the
	# route is below the natural hillside. A full-radius mouth excavates through
	# the roof and creates the very empty-sky void this field must avoid.
	append_tapered_arch_path(segments, route,
		[2.5, 2.3, 2.1, 2.1, 2.5, TUNNEL_RADIUS, TUNNEL_RADIUS],
		[1.35, 1.2, 1.2, 2.1, 2.5, TUNNEL_RADIUS, TUNNEL_RADIUS])
	if not interior_segments_keep_natural_roof(generation, segments, 1):
		return {}
	var junction: Vector3 = route[3]
	var branch_end: Vector3 = route[5] + side * rng.randf_range(15.0, 21.0)
	branch_end.y = floor_end - 1.0
	var loop: Array[Vector3] = [junction, junction + side * 10.0 - Vector3.UP, branch_end, route[6]]
	append_path(segments, loop, TUNNEL_RADIUS)
	var deep_end: Vector3 = route[6] - outward * 23.0 - side * 12.0
	deep_end.y = floor_end - 10.0
	var deep_path: Array[Vector3] = [route[6], route[6] - outward * 12.0 - Vector3.UP * 4.0, deep_end]
	append_path(segments, deep_path, 2.5)
	if not interior_segments_keep_natural_roof(generation, segments, 1):
		return {}
	var main_radii := Vector3(rng.randf_range(10.0, 14.0), rng.randf_range(5.0, 7.0), rng.randf_range(10.0, 13.0))
	main_radii.y = fit_chamber_vertical_radius(generation, route[6], main_radii.x, main_radii.z, main_radii.y)
	if main_radii.y < TUNNEL_RADIUS:
		return {}
	var branch_radii := Vector3(6.0, 4.0, 7.0)
	branch_radii.y = fit_chamber_vertical_radius(generation, branch_end, branch_radii.x, branch_radii.z, branch_radii.y)
	if branch_radii.y < 2.5:
		return {}
	var deep_radii := Vector3(8.0, 5.0, 9.0)
	deep_radii.y = fit_chamber_vertical_radius(generation, deep_end, deep_radii.x, deep_radii.z, deep_radii.y)
	if deep_radii.y < 2.5:
		return {}
	var chambers: Array[Dictionary] = [
		{"center": route[6] + Vector3.UP * main_radii.y, "radii": main_radii},
		{"center": branch_end + Vector3.UP * branch_radii.y, "radii": branch_radii},
		{"center": deep_end + Vector3.UP * deep_radii.y, "radii": deep_radii}
	]
	var bounds: AABB = segments[0].bounds
	for segment in segments:
		bounds = bounds.merge(segment.bounds)
	for chamber in chambers:
		bounds = bounds.merge(AABB(chamber.center - chamber.radii - Vector3.ONE, chamber.radii * 2.0 + Vector3.ONE * 2.0))
	# Recipes stay wholly within their source region, so adjacent chunk queries
	# use identical recipes without scanning neighbouring regions per voxel.
	if region_at(bounds.position) != region or region_at(bounds.end) != region:
		return {}
	# Protect generated settlement footprints through their existing authority.
	# Reject a whole recipe; never plug a published entrance with a town mask.
	if generation.surface_town_intersects_bounds(bounds) or generation.generated_site_intersects_bounds(bounds):
		return {}
	return {"id": "cave:%d,%d" % [region.x, region.y], "region": region, "entry": entry, "outward": outward, "route": route, "loop": loop, "deepRoute": deep_path, "segments": segments, "chambers": chambers, "bounds": bounds}

func append_path(segments: Array[Dictionary], points: Array[Vector3], radius: float) -> void:
	for index in range(points.size() - 1):
		var a := points[index]
		var b := points[index + 1]
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
		segments.append({"a": a, "b": b, "radius": radius_start, "radius_end": radius_end, "bounds": bounds})

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
		segments.append({"a": a, "b": b, "radius": radius_start, "radius_end": radius_end,
			"vertical_radius": vertical_start, "vertical_radius_end": vertical_end, "bounds": bounds})

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
