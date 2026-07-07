extends SceneTree

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const CELL := 1.35

var main: Node3D
var world_generation
var seed := ""
var report_path := ""
var results: Array[Dictionary] = []
var selected_sample := {}
var selected_cell := Vector3i.ZERO
var selected_chunk := Vector2i.ZERO

func _init() -> void:
	call_deferred("run")

func run() -> void:
	seed = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
	if seed == "":
		seed = "atlas-1492"
	report_path = OS.get_environment("VOXEL_UNDERGROUND_FLUID_RENDER_REPORT")
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/underground/underground-fluid-render-contract.json")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	OS.set_environment("VOXEL_TEST_SEED", seed)
	OS.set_environment("VOXEL_UNDERGROUND_VISUAL_FAST_BOOT", "1")
	main = MAIN_SCENE.instantiate()
	main.set("render_distance", 1)
	main.set("force_underground_volume_debug", true)
	main.set("force_underground_volume_fine_focus", true)
	main.set("visual_quality", {
		"decorativeDensity": 0.0,
		"decorativeDetailCap": 0,
		"foliageSway": 0.0,
		"particleDensity": 0.0
	})
	root.add_child(main)
	main.set_process(false)
	main.set_physics_process(false)
	await process_frame
	await process_frame
	world_generation = main.get("world_generation_system") if main != null else null
	if world_generation == null:
		add_result("underground_fluid_render_scene_ready", false, "world_generation missing")
		finish()
		return
	selected_sample = find_underground_fluid_sample()
	if selected_sample.is_empty():
		add_result("underground_fluid_render_sample_found", false, "no generated underground fluid sample found")
		finish()
		return
	selected_cell = selected_sample.get("cell", Vector3i.ZERO)
	var sample_position := cell_center(selected_cell)
	var player := main.get("player") as Node3D
	if player != null:
		player.global_position = sample_position
	selected_chunk = main.call("cell_to_chunk", selected_cell.x, selected_cell.z)
	add_result("underground_fluid_render_sample_found", true, JSON.stringify(sample_signature(selected_sample)))
	load_runtime_chunk(selected_chunk)
	await process_frame
	await process_frame
	var geometry := fluid_geometry_summary(selected_chunk)
	add_result("underground_fluid_runtime_mesh_loaded", bool(geometry.get("passed", false)), JSON.stringify(geometry))
	finish()

func find_underground_fluid_sample() -> Dictionary:
	if world_generation == null:
		return {}
	var bottom_y := int(world_generation.call("world_bottom_cell_y")) if world_generation.has_method("world_bottom_cell_y") else -64
	for radius in [32, 64, 96]:
		for z in range(-radius, radius + 1, 4):
			for x in range(-radius, radius + 1, 4):
				for y in range(bottom_y + 2, 48):
					var cell := Vector3i(x, y, z)
					var sample: Dictionary = world_generation.call("sample_cell", cell) if world_generation.has_method("sample_cell") else world_generation.call("sample_world", cell_center(cell))
					var fluid_id := String(sample.get("fluid", ""))
					if fluid_id == "":
						continue
					if bool(sample.get("solid", false)):
						continue
					if String(sample.get("biome", "")) != "underground_air":
						continue
					sample["cell"] = cell
					return sample
	return {}

func load_runtime_chunk(chunk_key: Vector2i) -> void:
	if main == null or not main.has_method("create_chunk"):
		return
	var chunks_value = main.get("chunks")
	var chunks: Dictionary = chunks_value if chunks_value is Dictionary else {}
	if chunks.has(chunk_key) and main.has_method("rebuild_chunk"):
		main.call("rebuild_chunk", chunk_key.x, chunk_key.y, true)
	else:
		main.call("create_chunk", chunk_key.x, chunk_key.y, true)

func fluid_geometry_summary(chunk_key: Vector2i) -> Dictionary:
	var chunks_value = main.get("chunks") if main != null else {}
	var chunks: Dictionary = chunks_value if chunks_value is Dictionary else {}
	var chunk := chunks.get(chunk_key, null) as Node3D
	if chunk == null:
		return {
			"passed": false,
			"reason": "chunk not loaded",
			"chunk": vec2i(chunk_key)
		}
	var fluid_instance := chunk.get_node_or_null("TerrainFluidMesh") as MeshInstance3D
	var mesh := fluid_instance.mesh if fluid_instance != null else null
	var surface_count := mesh.get_surface_count() if mesh != null else 0
	var fluid_faces := int(mesh.get_meta("chunk_fluid_faces", 0)) if mesh != null else 0
	var water_faces := int(mesh.get_meta("chunk_water_faces", 0)) if mesh != null else 0
	var lava_faces := int(mesh.get_meta("chunk_lava_faces", 0)) if mesh != null else 0
	var body := chunk.get_node_or_null("TerrainBody") as StaticBody3D
	return {
		"passed": fluid_instance != null and surface_count > 0 and fluid_faces > 0 and body != null,
		"chunk": vec2i(chunk_key),
		"sampleCell": vec3i(selected_cell),
		"fluid": String(selected_sample.get("fluid", "")),
		"fluidMeshPresent": fluid_instance != null,
		"surfaceCount": surface_count,
		"fluidFaces": fluid_faces,
		"waterFaces": water_faces,
		"lavaFaces": lava_faces,
		"collisionBodyPresent": body != null,
		"fluidCollisionSource": String(fluid_instance.get_meta("collision_source", "")) if fluid_instance != null else ""
	}

func cell_center(cell: Vector3i) -> Vector3:
	return Vector3((float(cell.x) + 0.5) * CELL, (float(cell.y) + 0.5) * CELL, (float(cell.z) + 0.5) * CELL)

func sample_signature(sample: Dictionary) -> Dictionary:
	return {
		"cell": vec3i(sample.get("cell", Vector3i.ZERO)),
		"biome": String(sample.get("biome", "")),
		"material": String(sample.get("material", "")),
		"fluid": String(sample.get("fluid", "")),
		"solid": bool(sample.get("solid", false)),
		"density": snappedf(float(sample.get("density", 0.0)), 0.001)
	}

func vec2i(value: Vector2i) -> Dictionary:
	return { "x": value.x, "z": value.y }

func vec3i(value: Vector3i) -> Dictionary:
	return { "x": value.x, "y": value.y, "z": value.z }

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

func failure_count() -> int:
	var count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			count += 1
	return count

func finish() -> void:
	save_report()
	if main != null:
		main.queue_free()
	quit(0 if all_passed() else 1)

func save_report() -> void:
	var report := {
		"schemaVersion": 1,
		"runnerId": "underground_fluid_render_contract",
		"testId": "underground_fluid_render_contract",
		"seed": seed,
		"finished": true,
		"passed": all_passed(),
		"evidenceLevel": "integration",
		"scope": "Real Main.tscn chunk creation check that generated terrain fluid states produce a non-collision TerrainFluidMesh; not headed visual acceptance.",
		"resultCount": results.size(),
		"failureCount": failure_count(),
		"selectedChunk": vec2i(selected_chunk),
		"selectedSample": sample_signature(selected_sample) if not selected_sample.is_empty() else {},
		"results": results
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	print(JSON.stringify(report, "  "))
