extends SceneTree

const WorldGenerationSystemScript := preload("res://scripts/WorldGenerationSystem.gd")
const SubsurfaceSystemScript := preload("res://scripts/SubsurfaceSystem.gd")

class FakeMain:
	const CELL := 1.35
	const MIN_HEIGHT := 4.0
	const MAX_HEIGHT := 120.0
	const WATER_LEVEL := 11.1
	const TOWN_REGION_CELLS := 280
	const TOWN_RADIUS_CELLS := 30

	var seed_text := "atlas-1492"
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
		height_noise = make_noise(13811, 0.018, 4)
		ridge_noise = make_noise(28191, 0.031, 4)
		flat_noise = make_noise(57831, 0.013, 3)
		moisture_noise = make_noise(77237, 0.010, 3)
		temp_noise = make_noise(91333, 0.009, 3)

	func make_noise(noise_seed: int, frequency: float, octaves: int) -> FastNoiseLite:
		var noise := FastNoiseLite.new()
		noise.seed = noise_seed
		noise.frequency = frequency
		noise.fractal_octaves = octaves
		noise.fractal_gain = 0.52
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

var results: Array[Dictionary] = []
var main
var world_generation
var subsurface
var seed := ""

func _init() -> void:
	call_deferred("run")

func run() -> void:
	seed = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
	if seed == "":
		seed = "atlas-1492"
	main = FakeMain.new()
	main.seed_text = seed
	world_generation = WorldGenerationSystemScript.new()
	world_generation.setup(main)
	main.world_generation_system = world_generation
	subsurface = SubsurfaceSystemScript.new()
	subsurface.setup(main)
	test_sampler_ready()
	test_world_sample_determinism()
	test_surface_projection_uses_volume_samples()
	test_cave_biome_is_world_volume()
	test_cave_volume_continuity_and_cover()
	test_cave_profile_is_arched_volume()
	test_subsurface_queries_use_volume()
	test_subsurface_excavation_save_load()
	save_report()
	quit(0 if all_passed() else 1)

func test_sampler_ready() -> void:
	add_result(
		"true_3d_sampler_ready",
		world_generation != null \
			and world_generation.has_method("sample_cell") \
			and world_generation.has_method("sample_world") \
			and world_generation.has_method("density_at") \
			and world_generation.has_method("solid_at") \
			and world_generation.has_method("biome_at") \
			and world_generation.has_method("material_at"),
		"world generation exposes authoritative 3D sample API"
	)

func test_world_sample_determinism() -> void:
	var cells: Array[Vector3i] = [
		Vector3i(0, 12, 0),
		Vector3i(18, 8, -24),
		Vector3i(-35, 20, 42),
		Vector3i(96, 16, 96)
	]
	var stable := true
	var signatures := []
	for cell in cells:
		var first: Dictionary = world_generation.call("sample_cell", cell)
		var second: Dictionary = world_generation.call("sample_cell", cell)
		var first_signature := sample_signature(first)
		var second_signature := sample_signature(second)
		stable = stable and JSON.stringify(first_signature) == JSON.stringify(second_signature)
		signatures.append(first_signature)
	add_result("true_3d_sample_determinism", stable, JSON.stringify(signatures))

func test_surface_projection_uses_volume_samples() -> void:
	var columns: Array[Vector2i] = [
		Vector2i(0, 0),
		Vector2i(20, 20),
		Vector2i(-35, 42)
	]
	var passed := true
	var summaries := []
	for column in columns:
		var surface_y := float(world_generation.call("surface_y_for_cell", Vector3i(column.x, 0, column.y)))
		var air_y := roundi(surface_y / main.CELL)
		var solid_cell := Vector3i(column.x, air_y - 1, column.y)
		var air_cell := Vector3i(column.x, air_y, column.y)
		var solid_sample: Dictionary = world_generation.call("sample_cell", solid_cell)
		var air_sample: Dictionary = world_generation.call("sample_cell", air_cell)
		var column_ok := bool(solid_sample.get("solid", false)) and not bool(air_sample.get("solid", true))
		passed = passed and column_ok
		summaries.append({
			"column": sanitize(column),
			"surfaceY": snapped_float(surface_y),
			"solidCell": sanitize(solid_cell),
			"solidSample": sample_signature(solid_sample),
			"airCell": sanitize(air_cell),
			"airSample": sample_signature(air_sample),
			"passed": column_ok
		})
	add_result("surface_projection_uses_3d_volume_samples", passed, JSON.stringify(summaries))

func test_cave_biome_is_world_volume() -> void:
	var found := find_required_cave()
	var sample: Dictionary = found.get("sample", {}) if found.has("sample") else {}
	var position: Vector3 = found.get("position", Vector3.ZERO)
	var by_world: Dictionary = world_generation.call("sample_world", position)
	var passed := not found.is_empty() \
		and String(sample.get("biome", "")) == "cave" \
		and String(sample.get("material", "")) == "air" \
		and not bool(sample.get("solid", true)) \
		and JSON.stringify(sample_signature(sample)) == JSON.stringify(sample_signature(by_world))
	add_result("true_3d_cave_biome_from_volume", passed, JSON.stringify(sanitize(found)))

func test_cave_volume_continuity_and_cover() -> void:
	var found := find_required_cave()
	if found.is_empty():
		add_result("true_3d_cave_continuity_and_cover", false, "no cave biome sample")
		return
	var feature: Dictionary = found.get("feature", {})
	var entrance_cell: Vector2i = feature.get("entranceCell", Vector2i.ZERO)
	var inward_cell: Vector2i = feature.get("inward", Vector2i(0, 1))
	var right_cell: Vector2i = feature.get("right", Vector2i(1, 0))
	var inward := Vector2(float(inward_cell.x), float(inward_cell.y)).normalized()
	var right := Vector2(float(right_cell.x), float(right_cell.y)).normalized()
	var entrance := Vector2(float(entrance_cell.x) * main.CELL, float(entrance_cell.y) * main.CELL)
	var radius := float(feature.get("radius", main.CELL * 2.0))
	var length := float(feature.get("length", main.CELL * 24.0))
	var front_depths := [0.0, main.CELL * 0.75, main.CELL * 1.5]
	var interior_depth := clampf(main.CELL * 8.0, main.CELL * 3.0, length * 0.55)
	var front_air_samples := 0
	var blocked_front_samples := []
	var tunnel_air_samples := 0
	var blocked_tunnel_samples := []
	var wall_samples := 0
	var missing_wall_samples := []
	var cover_samples := 0
	var missing_cover_samples := []
	for depth in front_depths:
		var center2 := entrance + inward * float(depth)
		var center_y := float(world_generation.call("cave_feature_center_y", feature, center2, float(depth)))
		for lateral_scale in [-0.62, 0.0, 0.62]:
			var sample_pos := Vector3(center2.x + right.x * radius * float(lateral_scale), center_y, center2.y + right.y * radius * float(lateral_scale))
			var sample: Dictionary = world_generation.call("sample_world", sample_pos)
			if String(sample.get("biome", "")) == "cave" and not bool(sample.get("solid", true)):
				front_air_samples += 1
			else:
				blocked_front_samples.append(sanitize(sample_pos))
	for depth in [main.CELL * 3.0, interior_depth]:
		var center2 := entrance + inward * float(depth)
		var center_y := float(world_generation.call("cave_feature_center_y", feature, center2, float(depth)))
		var center_pos := Vector3(center2.x, center_y, center2.y)
		var tunnel_sample: Dictionary = world_generation.call("sample_world", center_pos)
		if String(tunnel_sample.get("biome", "")) == "cave" and not bool(tunnel_sample.get("solid", true)):
			tunnel_air_samples += 1
		else:
			blocked_tunnel_samples.append(sanitize(center_pos))
		for side in [-1.0, 1.0]:
			var side_pos := Vector3(center2.x + right.x * radius * 1.22 * float(side), center_y, center2.y + right.y * radius * 1.22 * float(side))
			var side_sample: Dictionary = world_generation.call("sample_world", side_pos)
			if bool(side_sample.get("solid", false)):
				wall_samples += 1
			else:
				missing_wall_samples.append(sanitize(side_pos))
		if float(depth) >= main.CELL * 7.0:
			var cover_pos := Vector3(center2.x, center_y + radius * 0.96, center2.y)
			var cover_sample: Dictionary = world_generation.call("sample_world", cover_pos)
			if bool(cover_sample.get("solid", false)):
				cover_samples += 1
			else:
				missing_cover_samples.append(sanitize(cover_pos))
	var passed := front_air_samples >= 6 \
		and tunnel_air_samples == 2 \
		and wall_samples == 4 \
		and cover_samples >= 1 \
		and blocked_front_samples.is_empty() \
		and blocked_tunnel_samples.is_empty() \
		and missing_wall_samples.is_empty() \
		and missing_cover_samples.is_empty()
	add_result(
		"true_3d_cave_continuity_and_cover",
		passed,
		JSON.stringify({
			"featureId": String(feature.get("id", "")),
			"frontAirSamples": front_air_samples,
			"tunnelAirSamples": tunnel_air_samples,
			"wallSamples": wall_samples,
			"coverSamples": cover_samples,
			"blockedFront": blocked_front_samples,
			"blockedTunnel": blocked_tunnel_samples,
			"missingWalls": missing_wall_samples,
			"missingCover": missing_cover_samples
		})
	)

func test_cave_profile_is_arched_volume() -> void:
	var found := find_required_cave()
	if found.is_empty():
		add_result("true_3d_cave_profile_is_arched_volume", false, "no cave biome sample")
		return
	var feature: Dictionary = found.get("feature", {})
	var entrance_cell: Vector2i = feature.get("entranceCell", Vector2i.ZERO)
	var inward_cell: Vector2i = feature.get("inward", Vector2i(0, 1))
	var right_cell: Vector2i = feature.get("right", Vector2i(1, 0))
	var inward := Vector2(float(inward_cell.x), float(inward_cell.y)).normalized()
	var right := Vector2(float(right_cell.x), float(right_cell.y)).normalized()
	var entrance := Vector2(float(entrance_cell.x) * main.CELL, float(entrance_cell.y) * main.CELL)
	var depth: float = main.CELL * 2.25
	var center2: Vector2 = entrance + inward * depth
	var center_y := float(world_generation.call("cave_feature_center_y", feature, center2, depth))
	var radius := float(world_generation.call("cave_feature_radius_at_depth", feature, depth))
	var vertical_radius := radius * 0.78
	var center_air := cave_profile_feature_air(feature, center2, right, center_y, radius, vertical_radius, 0.0, 0.0)
	var left_air := cave_profile_feature_air(feature, center2, right, center_y, radius, vertical_radius, -0.68, 0.0)
	var right_air := cave_profile_feature_air(feature, center2, right, center_y, radius, vertical_radius, 0.68, 0.0)
	var top_air := cave_profile_feature_air(feature, center2, right, center_y, radius, vertical_radius, 0.0, 0.72)
	var floor_solid := cave_profile_feature_solid(feature, center2, right, center_y, radius, vertical_radius, 0.0, -1.08)
	var left_upper_corner_solid := cave_profile_feature_solid(feature, center2, right, center_y, radius, vertical_radius, -0.82, 0.72)
	var right_upper_corner_solid := cave_profile_feature_solid(feature, center2, right, center_y, radius, vertical_radius, 0.82, 0.72)
	var passed := center_air \
		and left_air \
		and right_air \
		and top_air \
		and floor_solid \
		and left_upper_corner_solid \
		and right_upper_corner_solid
	add_result(
		"true_3d_cave_profile_is_arched_volume",
		passed,
		JSON.stringify({
			"featureId": String(feature.get("id", "")),
			"depth": snapped_float(depth),
			"radius": snapped_float(radius),
			"centerAir": center_air,
			"leftAir": left_air,
			"rightAir": right_air,
			"topAir": top_air,
			"floorSolid": floor_solid,
			"leftUpperCornerSolid": left_upper_corner_solid,
			"rightUpperCornerSolid": right_upper_corner_solid
		})
	)

func cave_profile_feature_air(feature: Dictionary, center2: Vector2, right: Vector2, center_y: float, radius: float, vertical_radius: float, lateral_scale: float, vertical_scale: float) -> bool:
	var position := cave_profile_position(center2, right, center_y, radius, vertical_radius, lateral_scale, vertical_scale)
	return float(world_generation.call("cave_feature_air_value", feature, position)) < 0.0

func cave_profile_feature_solid(feature: Dictionary, center2: Vector2, right: Vector2, center_y: float, radius: float, vertical_radius: float, lateral_scale: float, vertical_scale: float) -> bool:
	var position := cave_profile_position(center2, right, center_y, radius, vertical_radius, lateral_scale, vertical_scale)
	return float(world_generation.call("cave_feature_air_value", feature, position)) >= 0.0

func cave_profile_position(center2: Vector2, right: Vector2, center_y: float, radius: float, vertical_radius: float, lateral_scale: float, vertical_scale: float) -> Vector3:
	return Vector3(
		center2.x + right.x * radius * lateral_scale,
		center_y + vertical_radius * vertical_scale,
		center2.y + right.y * radius * lateral_scale
	)

func test_subsurface_queries_use_volume() -> void:
	var surface := find_exposed_surface_cell(Vector2i(20, 20))
	var solid_cell: Vector3i = surface.get("solidCell", Vector3i.ZERO)
	var air_cell: Vector3i = surface.get("airCell", Vector3i.ZERO)
	var solid_material := String(subsurface.call("subsurface_material_at", solid_cell))
	var air_material := String(subsurface.call("subsurface_material_at", air_cell))
	var biome := String(subsurface.call("subsurface_biome_at", solid_cell))
	var passed := not surface.is_empty() \
		and solid_material != "" \
		and solid_material != "air" \
		and air_material == "air" \
		and biome != ""
	add_result(
		"subsurface_queries_use_3d_volume",
		passed,
		"solid=%s air=%s biome=%s cells=%s" % [solid_material, air_material, biome, JSON.stringify(sanitize(surface))]
	)

func test_subsurface_excavation_save_load() -> void:
	var surface := find_exposed_surface_cell(Vector2i(24, 24))
	if surface.is_empty():
		add_result("subsurface_excavation_save_load", false, "no exposed surface sample")
		return
	if subsurface.has_method("reset"):
		subsurface.call("reset")
	var solid_cell: Vector3i = surface.get("solidCell", Vector3i.ZERO)
	var center := Vector3((float(solid_cell.x) + 0.5) * main.CELL, (float(solid_cell.y) + 0.5) * main.CELL, (float(solid_cell.z) + 0.5) * main.CELL)
	var brush: Dictionary = subsurface.call("add_excavation_brush", center, main.CELL * 1.35, "")
	var air_after_brush := not bool(subsurface.call("subsurface_is_solid", solid_cell))
	var snapshot: Dictionary = subsurface.call("snapshot")
	subsurface.call("reset")
	var solid_after_reset := bool(subsurface.call("subsurface_is_solid", solid_cell))
	subsurface.call("restore", snapshot)
	var air_after_restore := not bool(subsurface.call("subsurface_is_solid", solid_cell))
	var saved_count := array_size(snapshot.get("excavationBrushes", []))
	add_result(
		"subsurface_excavation_save_load",
		air_after_brush and solid_after_reset and air_after_restore and saved_count == 1 and String(brush.get("id", "")) != "",
		"brush=%s savedCount=%d airAfterBrush=%s solidAfterReset=%s airAfterRestore=%s" % [JSON.stringify(sanitize(brush)), saved_count, str(air_after_brush), str(solid_after_reset), str(air_after_restore)]
	)

func find_required_cave() -> Dictionary:
	return world_generation.call("find_cave_biome_sample", 16) if world_generation != null else {}

func find_exposed_surface_cell(column: Vector2i) -> Dictionary:
	for y in range(96, -16, -1):
		var air_cell := Vector3i(column.x, y + 1, column.y)
		var solid_cell := Vector3i(column.x, y, column.y)
		var air_sample: Dictionary = world_generation.call("sample_cell", air_cell)
		var solid_sample: Dictionary = world_generation.call("sample_cell", solid_cell)
		if not bool(air_sample.get("solid", true)) and bool(solid_sample.get("solid", false)):
			return {
				"airCell": air_cell,
				"solidCell": solid_cell,
				"airSample": sample_signature(air_sample),
				"solidSample": sample_signature(solid_sample)
			}
	return {}

func sample_signature(sample: Dictionary) -> Dictionary:
	return {
		"density": snapped_float(float(sample.get("density", 0.0))),
		"solid": bool(sample.get("solid", false)),
		"biome": String(sample.get("biome", "")),
		"material": String(sample.get("material", "")),
		"surface": bool(sample.get("surface", false))
	}

func snapped_float(value: float) -> float:
	return snappedf(value, 0.001)

func add_result(name: String, passed: bool, details := "") -> void:
	results.append({
		"name": name,
		"passed": passed,
		"details": details
	})
	print("[%s] %s %s" % ["PASS" if passed else "FAIL", name, details])

func all_passed() -> bool:
	for result in results:
		if not bool(result.get("passed", false)):
			return false
	return true

func save_report() -> void:
	var report := {
		"schemaVersion": 2,
		"testId": "true_3d_cave_generation_contract",
		"seed": seed,
		"finished": true,
		"passed": all_passed(),
		"evidenceLevel": "contract",
		"scope": "Authoritative 3D solid/air/biome/material cave generation and excavation contracts; not headed visual acceptance.",
		"resultCount": results.size(),
		"failureCount": failure_count(),
		"results": results
	}
	var report_path := OS.get_environment("VOXEL_CAVE_GENERATION_REPORT")
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/caves/cave-generation-report.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	print(JSON.stringify(report, "  "))

func failure_count() -> int:
	var count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			count += 1
	return count

func array_size(value) -> int:
	return value.size() if value is Array else 0

func sanitize(value):
	if value is Vector2i:
		return { "x": value.x, "z": value.y }
	if value is Vector3i:
		return { "x": value.x, "y": value.y, "z": value.z }
	if value is Vector3:
		return { "x": snapped_float(value.x), "y": snapped_float(value.y), "z": snapped_float(value.z) }
	if value is Array:
		var result := []
		for item in value:
			result.append(sanitize(item))
		return result
	if value is Dictionary:
		var result := {}
		for key in value.keys():
			var key_text := ""
			if key is Vector2i:
				key_text = "%d,%d" % [key.x, key.y]
			elif key is Vector3i:
				key_text = "%d,%d,%d" % [key.x, key.y, key.z]
			else:
				key_text = str(key)
			result[key_text] = sanitize(value[key])
		return result
	return value
