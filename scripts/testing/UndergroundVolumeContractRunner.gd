extends SceneTree

const WorldGenerationSystemScript := preload("res://scripts/WorldGenerationSystem.gd")
const SEARCH_RADIUS := 16

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
	var towns_enabled := false

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

	func town_region(region_x: int, region_z: int) -> Dictionary:
		if not towns_enabled or region_x != 0 or region_z != 0:
			return {}
		return {
			"regionX": 0,
			"regionZ": 0,
			"centerX": 0,
			"centerZ": 0,
			"radius": 30,
			"level": 18.9
		}

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
	report_path = OS.get_environment("VOXEL_UNDERGROUND_VOLUME_CONTRACT_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/underground/underground-volume-contract-report.json")
	main = FakeMain.new()
	world_generation = WorldGenerationSystemScript.new()
	world_generation.setup(main)
	test_sample_determinism()
	test_underground_air_exists()
	test_underground_air_has_connected_volume()
	test_sample_contract()
	test_world_bottom_is_solid()
	test_generated_surface_overburden_is_solid()
	test_air_has_generated_solid_boundaries()
	test_known_navigation_surface_boundary()
	test_removed_production_api_absent()
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
	add_result("underground_sample_determinism", stable, JSON.stringify(signatures))

func test_known_navigation_surface_boundary() -> void:
	var column := Vector3i(7, 0, 7)
	var surface_y: float = world_generation.surface_y_for_cell(column)
	var projection: Dictionary = world_generation.navigation_surface_projection_at_known_height(column, surface_y)
	var volume = world_generation.terrain_volume_service
	var solid_cell: Vector3i = projection.get("solidCell", Vector3i.ZERO)
	var air_cell: Vector3i = projection.get("airCell", Vector3i.ZERO)
	var passed: bool = projection.get("status") == "ready" and bool(projection.get("found", false)) \
		and bool(projection.get("walkable", false)) and solid_cell.y + 1 == air_cell.y \
		and is_equal_approx(float((projection.get("position", Vector3.ZERO) as Vector3).y), surface_y) \
		and int(projection.get("volumeRevision", -1)) == int(volume.revision) \
		and bool((projection.get("occupancy", {}) as Dictionary).get("walkableAir", false))
	add_result("navigation_known_surface_boundary_is_exact_and_revision_bound", passed, JSON.stringify(sanitize(projection)))
	var old_revision := int(volume.revision)
	var ceiling_state := {
		"material": "stone", "biome": "plains", "solid": true, "density": 1.0,
		"fluid": "", "light": {"sky": 0, "block": 0},
		"metadata": {"source": "navigation_boundary_contract", "terrainMeshAffects": true, "saveDelta": false}
	}
	world_generation.apply_box_edit(air_cell + Vector3i(0, 1, 0), air_cell + Vector3i(0, 1, 0), ceiling_state, "navigation_boundary_mismatch")
	var stale_boundary: Dictionary = world_generation.navigation_surface_projection_at_known_height(column, surface_y)
	add_result("navigation_known_surface_boundary_rejects_changed_headroom", int(volume.revision) > old_revision \
		and stale_boundary.get("status") == "mismatch" and not bool(stale_boundary.get("found", true)),
		JSON.stringify(sanitize(stale_boundary)))

func test_underground_air_exists() -> void:
	var found: Dictionary = world_generation.call("find_underground_air_sample", SEARCH_RADIUS, 4, 30)
	var sample: Dictionary = found.get("sample", {}) if found.has("sample") else {}
	var passed := not found.is_empty() \
		and String(sample.get("biome", "")) == "underground_air" \
		and String(sample.get("material", "")) == "air" \
		and not bool(sample.get("solid", true))
	add_result("underground_air_generated_biome_exists", passed, JSON.stringify(sanitize(found)))

func test_underground_air_has_connected_volume() -> void:
	var found: Dictionary = world_generation.call("find_underground_air_sample", SEARCH_RADIUS, 4, 30)
	if found.is_empty():
		add_result("underground_air_connected_chamber_volume", false, "no underground_air sample")
		return
	var cell: Vector3i = found.get("cell", Vector3i.ZERO)
	var region: Dictionary = found.get("connectedRegion", {})
	if region.is_empty() and world_generation.has_method("underground_air_connected_region_summary"):
		region = world_generation.call("underground_air_connected_region_summary", cell, 96, 8)
	var span: Vector3i = region.get("span", Vector3i.ZERO)
	var passed := int(region.get("airCells", 0)) >= 24 \
		and int(region.get("branchDirections", 0)) >= 3 \
		and span.x + span.y + span.z >= 8
	add_result("underground_air_connected_chamber_volume", passed, JSON.stringify(sanitize({ "cell": cell, "region": region })))

func test_sample_contract() -> void:
	var found: Dictionary = world_generation.call("find_underground_air_sample", SEARCH_RADIUS, 4, 30)
	if found.is_empty():
		add_result("underground_sample_contract", false, "no underground_air sample")
		return
	var position: Vector3 = found.get("position", Vector3.ZERO)
	var sample: Dictionary = world_generation.call("sample_world", position)
	var density_a := float(world_generation.call("density_at", position))
	var density_b := float(world_generation.call("density_at", position))
	var biome := String(world_generation.call("biome_at", position))
	var material := String(world_generation.call("material_at", position))
	var solid := bool(world_generation.call("solid_at", position))
	var passed := density_a == density_b \
		and density_a < 0.0 \
		and biome == "underground_air" \
		and material == "air" \
		and not solid \
		and sample.has("surfaceY") \
		and int(sample.get("generatedDepthCells", 0)) > 32
	add_result("underground_sample_contract", passed, JSON.stringify(sample_signature(sample)))

func test_world_bottom_is_solid() -> void:
	var columns: Array[Vector2i] = [Vector2i(0, 0), Vector2i(20, 20), Vector2i(-35, 42), Vector2i(96, 96)]
	var passed := true
	var summaries := []
	var bottom_y := int(world_generation.call("world_bottom_cell_y")) if world_generation.has_method("world_bottom_cell_y") else -64
	for column in columns:
		var bedrock_cell := Vector3i(column.x, bottom_y, column.y)
		var above_cell := Vector3i(column.x, bottom_y + 6, column.y)
		var bedrock_sample: Dictionary = world_generation.call("sample_cell", bedrock_cell)
		var above_sample: Dictionary = world_generation.call("sample_cell", above_cell)
		var ok := bool(bedrock_sample.get("solid", false)) \
			and String(bedrock_sample.get("material", "")) == "bedrock" \
			and bool(above_sample.get("solid", false)) \
			and String(above_sample.get("material", "")) != "air"
		passed = passed and ok
		summaries.append({ "column": sanitize(column), "bottomCellY": bottom_y, "bedrock": sample_signature(bedrock_sample), "above": sample_signature(above_sample), "passed": ok })
	add_result("underground_world_bottom_solid", passed, JSON.stringify(summaries))


func test_generated_surface_overburden_is_solid() -> void:
	var natural_columns: Array[Vector2i] = [Vector2i(0, 0), Vector2i(18, -24), Vector2i(-35, 42), Vector2i(96, 96)]
	var natural_ok := true
	var natural_samples := []
	for column in natural_columns:
		var surface_y := float(world_generation.call("terrain_reference_surface_y_for_cell", Vector3i(column.x, 0, column.y)))
		for depth_cells in [0.5, 1.5, 2.5, 3.0]:
			var position := Vector3(float(column.x) * FakeMain.CELL, surface_y - float(depth_cells) * FakeMain.CELL, float(column.y) * FakeMain.CELL)
			var sample: Dictionary = world_generation.call("generate_sample_without_volume", position)
			var sample_ok := float(sample.get("density", -1.0)) >= 0.0 and bool(sample.get("solid", false))
			natural_ok = natural_ok and sample_ok
			natural_samples.append({"column": sanitize(column), "depthCells": depth_cells, "density": snapped_float(float(sample.get("density", 0.0))), "solid": bool(sample.get("solid", false))})
	var town_main := FakeMain.new()
	town_main.towns_enabled = true
	var town_generation = WorldGenerationSystemScript.new()
	town_generation.setup(town_main)
	var town_columns: Array[Vector2i] = [Vector2i.ZERO, Vector2i(29, 0), Vector2i(36, 0), Vector2i(0, -36)]
	var town_ok := true
	var town_samples := []
	for column in town_columns:
		var surface_y := float(town_generation.call("terrain_reference_surface_y_for_cell", Vector3i(column.x, 0, column.y)))
		for depth_cells in [0.5, 2.5, 5.5, 8.0]:
			var position := Vector3(float(column.x) * FakeMain.CELL, surface_y - float(depth_cells) * FakeMain.CELL, float(column.y) * FakeMain.CELL)
			var sample: Dictionary = town_generation.call("generate_sample_without_volume", position)
			var sample_ok := float(sample.get("density", -1.0)) >= 0.0 and bool(sample.get("solid", false))
			town_ok = town_ok and sample_ok
			town_samples.append({"column": sanitize(column), "depthCells": depth_cells, "density": snapped_float(float(sample.get("density", 0.0))), "solid": bool(sample.get("solid", false))})
	add_result(
		"generated_surface_overburden_is_solid",
		natural_ok and town_ok,
		JSON.stringify({"natural": natural_samples, "townAndApron": town_samples})
	)

func test_air_has_generated_solid_boundaries() -> void:
	var found: Dictionary = world_generation.call("find_underground_air_sample", SEARCH_RADIUS, 4, 30)
	if found.is_empty():
		add_result("underground_air_surrounded_by_generated_solids", false, "no underground_air sample")
		return
	var cell: Vector3i = found.get("cell", Vector3i.ZERO)
	var solid_neighbors := 0
	var materials := {}
	for direction in [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0), Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		var sample: Dictionary = world_generation.call("sample_cell", cell + direction)
		if bool(sample.get("solid", false)):
			solid_neighbors += 1
			materials[String(sample.get("material", ""))] = true
	var passed := solid_neighbors >= 2 and not materials.is_empty()
	add_result("underground_air_surrounded_by_generated_solids", passed, JSON.stringify({ "cell": sanitize(cell), "solidNeighbors": solid_neighbors, "materials": materials.keys() }))

func test_removed_production_api_absent() -> void:
	var source := FileAccess.get_file_as_string(ProjectSettings.globalize_path("res://scripts/WorldGenerationSystem.gd"))
	var legacy := "ca" + "ve"
	var banned := ["func " + legacy + "_feature_", "find_" + legacy + "_biome_sample", legacy + "Value", legacy + "_features_near_world"]
	var findings := []
	for pattern in banned:
		if source.find(pattern) >= 0:
			findings.append(pattern)
	add_result("removed_legacy_volume_feature_production_api_absent", findings.is_empty(), JSON.stringify(findings))

func sample_signature(sample: Dictionary) -> Dictionary:
	return {
		"density": snapped_float(float(sample.get("density", 0.0))),
		"solid": bool(sample.get("solid", false)),
		"biome": String(sample.get("biome", "")),
		"material": String(sample.get("material", "")),
		"surface": bool(sample.get("surface", false)),
		"surfaceY": snapped_float(float(sample.get("surfaceY", 0.0))),
		"depthCells": snapped_float(float(sample.get("depthCells", 0.0)))
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
		"runnerId": "underground_volume_contract",
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
