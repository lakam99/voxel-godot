extends SceneTree

const WorldGenerationSystemScript := preload("res://scripts/WorldGenerationSystem.gd")

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
	var volume_edit_markers := {}
	var town_slope_apron_cache := {}

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
var world_generation
var main
var report_path := ""

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_TRUE_3D_CAVE_BIOME_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/true-3d-cave-biome-contract-report.json")
	main = FakeMain.new()
	world_generation = WorldGenerationSystemScript.new()
	world_generation.setup(main)
	test_sample_determinism()
	test_cave_biome_exists_without_structure_system()
	test_cave_sample_contract()
	test_cave_profile_is_arched_volume()
	save_report()
	quit(0 if all_passed() else 1)

func test_sample_determinism() -> void:
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

func test_cave_biome_exists_without_structure_system() -> void:
	var found: Dictionary = world_generation.call("find_cave_biome_sample", 12)
	var sample: Dictionary = found.get("sample", {}) if found.has("sample") else {}
	var passed := not found.is_empty() \
		and String(sample.get("biome", "")) == "cave" \
		and String(sample.get("material", "")) == "air" \
		and not bool(sample.get("solid", true))
	add_result("true_3d_cave_biome_without_structure_system", passed, JSON.stringify(sanitize(found)))

func test_cave_sample_contract() -> void:
	var found: Dictionary = world_generation.call("find_cave_biome_sample", 12)
	if found.is_empty():
		add_result("true_3d_cave_sample_contract", false, "no cave sample")
		return
	var feature: Dictionary = found.get("feature", {})
	var position: Vector3 = found.get("position", Vector3.ZERO)
	var density_a := float(world_generation.call("density_at", position))
	var density_b := float(world_generation.call("density_at", position))
	var biome := String(world_generation.call("biome_at", position))
	var material := String(world_generation.call("material_at", position))
	var solid := bool(world_generation.call("solid_at", position))
	var entrance: Vector2i = feature.get("entranceCell", Vector2i.ZERO)
	var entrance_surface := float(feature.get("entranceSurfaceY", 0.0))
	var entrance_world := Vector3(float(entrance.x) * main.CELL, entrance_surface, float(entrance.y) * main.CELL)
	var entrance_sample: Dictionary = world_generation.call("sample_world", entrance_world)
	var passed := density_a == density_b \
		and density_a < 0.0 \
		and biome == "cave" \
		and material == "air" \
		and not solid \
		and String(entrance_sample.get("biome", "")) == "cave"
	add_result(
		"true_3d_cave_sample_contract",
		passed,
		JSON.stringify({
			"density": density_a,
			"biome": biome,
			"material": material,
			"solid": solid,
			"entranceSample": sample_signature(entrance_sample),
			"featureId": String(feature.get("id", ""))
		})
	)

func test_cave_profile_is_arched_volume() -> void:
	var found: Dictionary = world_generation.call("find_cave_biome_sample", 12)
	if found.is_empty():
		add_result("true_3d_cave_profile_is_arched_volume", false, "no cave sample")
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

func add_result(name: String, passed: bool, details: String) -> void:
	results.append({
		"name": name,
		"passed": passed,
		"details": details
	})

func all_passed() -> bool:
	for result in results:
		if not bool(result.get("passed", false)):
			return false
	return true

func save_report() -> void:
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var report := {
		"schemaVersion": 1,
		"runnerId": "true_3d_cave_biome_contract",
		"evidenceLevel": "contract",
		"status": "passed" if all_passed() else "failed",
		"results": results
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()

func sanitize(value):
	if value is Vector2i:
		return { "x": value.x, "z": value.y }
	if value is Vector3i:
		return { "x": value.x, "y": value.y, "z": value.z }
	if value is Vector3:
		return { "x": snapped_float(value.x), "y": snapped_float(value.y), "z": snapped_float(value.z) }
	if value is Dictionary:
		var out := {}
		for key in (value as Dictionary).keys():
			out[String(key)] = sanitize((value as Dictionary)[key])
		return out
	if value is Array:
		var out_array := []
		for item in value:
			out_array.append(sanitize(item))
		return out_array
	return value
