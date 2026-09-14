extends SceneTree

const WorldGenerationSystemScript := preload("res://scripts/WorldGenerationSystem.gd")
const TerrainMeshingServiceScript := preload("res://scripts/TerrainMeshingService.gd")
const CHUNK_SIZE := 28
const BELOW_SURFACE_CELLS := 10
const ABOVE_SURFACE_CELLS := 2
const BORDER_CELLS := 2

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
var report_path := ""

class PayloadWorld extends RefCounted:
	func begin_section_payload_for_meshing_chunk(x: int, z: int, size: int, low: int, high: int, step: int) -> Dictionary:
		return {"startX":x,"startZ":z,"chunkSize":size,"minY":low,"maxY":high,"stepCells":step}

class PayloadOwner extends Node:
	const CHUNK_SIZE := 28
	var world_generation_system = PayloadWorld.new()
	var terrain_detail_queries := 0
	func underground_volume_mesh_step_for_chunk(_x: int, _z: int) -> int:
		terrain_detail_queries += 1
		return 4

class ValueOnlyBackend extends RefCounted:
	var terrain_calls := 0
	var fluid_calls := 0
	var terrain_thread_id := -1
	var fluid_thread_id := -1
	func build_chunk_surface_data_from_sections(_payload: Dictionary) -> Dictionary:
		terrain_calls += 1
		terrain_thread_id = OS.get_thread_caller_id()
		return {"valid":true,
			"vertices":PackedVector3Array([Vector3.ZERO,Vector3.RIGHT,Vector3.FORWARD]),
			"normals":PackedVector3Array([Vector3.UP,Vector3.UP,Vector3.UP]),
			"colors":PackedColorArray([Color.WHITE,Color.WHITE,Color.WHITE]),
			"faceCount":1,"vertexCount":3,"stepCells":1,"sectionCount":1}
	func build_chunk_fluid_surface_data_from_sections(_payload: Dictionary) -> Dictionary:
		fluid_calls += 1
		fluid_thread_id = OS.get_thread_caller_id()
		return {"deferred":true,"reason":"no_fluid","hasFluid":false,"waterVertices":PackedVector3Array(),"lavaVertices":PackedVector3Array()}

class ResourceFallbackBackend extends ValueOnlyBackend:
	var mesh_calls := 0
	var collision_calls := 0
	var collision_thread_id := -1
	func build_chunk_mesh_from_sections(_payload: Dictionary):
		mesh_calls += 1
		return Resource.new()
	func collision_shape_for_mesh(_mesh):
		collision_calls += 1
		collision_thread_id = OS.get_thread_caller_id()
		return null

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_TERRAIN_MESH_BOUNDS_REPORT").strip_edges()
	test_async_worker_returns_surface_values_only()
	test_fluid_only_avoids_terrain_detail_scan()
	test_generated_surface_bounds_enclose_exact_projection()
	test_incremental_bounds_match_direct_authority()
	test_mesh_edits_expand_authoritative_bounds()
	test_retired_payload_cleanup_is_bounded()
	finish()

func test_async_worker_returns_surface_values_only() -> void:
	var service := TerrainMeshingServiceScript.new()
	var value_backend := ValueOnlyBackend.new()
	service.backend = value_backend
	service.native_backend_available = true
	var value_only_backend_admitted := service.can_process_native_section_jobs_async()
	var guarded_backend := ResourceFallbackBackend.new()
	var main_thread_id := OS.get_thread_caller_id()
	var key := Vector2i(2, -3)
	var thread := Thread.new()
	var start_error := thread.start(Callable(service, "_thread_build_native_chunk_assets").bind(
		key, "", true, false, {"sections":[{}],"hasFluid":true}, guarded_backend, {}))
	var started := start_error == OK
	var worker_result = thread.wait_to_finish() if started else null
	var result_is_value_only := worker_result is Dictionary and not _contains_object(worker_result)
	service.backend = guarded_backend
	service.async_worker_result = worker_result if worker_result is Dictionary else {}
	service.async_worker_task_id = WorkerThreadPool.add_task(func(): pass)
	service.async_worker_active = service.async_worker_task_id >= 0
	service.async_worker_key = key
	if service.async_worker_active:
		while not WorkerThreadPool.is_task_completed(service.async_worker_task_id):
			OS.delay_usec(100)
	var collected: Dictionary = service.collect_async_worker_result()
	var assets: Dictionary = service.completed_jobs.get(key, {})
	var main_thread_hydrated := int(collected.get("processed", 0)) == 1 \
		and assets.get("mesh") is ArrayMesh and assets.get("fluidMesh") is ArrayMesh \
		and assets.get("shape") is Shape3D and guarded_backend.collision_thread_id == main_thread_id
	var passed: bool = value_only_backend_admitted and started and result_is_value_only \
		and guarded_backend.terrain_calls == 1 and guarded_backend.fluid_calls == 1 \
		and guarded_backend.terrain_thread_id != main_thread_id and guarded_backend.fluid_thread_id != main_thread_id \
		and guarded_backend.mesh_calls == 0 and guarded_backend.collision_calls == 1 \
		and not worker_result.has("mesh") and not worker_result.has("fluidMesh") and not worker_result.has("shape") \
		and String(worker_result.get("workerError", "")).is_empty() and main_thread_hydrated
	add_result(
		"terrain_async_worker_returns_surface_values_without_render_or_collision_resources",
		passed,
		JSON.stringify({"valueOnlyBackendAdmitted":value_only_backend_admitted,"threadStarted":started,
			"resultIsValueOnly":result_is_value_only,"terrainCalls":guarded_backend.terrain_calls,
			"fluidCalls":guarded_backend.fluid_calls,"meshCalls":guarded_backend.mesh_calls,
			"collisionCalls":guarded_backend.collision_calls,"workerThread":guarded_backend.terrain_thread_id,
			"mainThread":main_thread_id,"collisionThread":guarded_backend.collision_thread_id,
			"mainThreadHydrated":main_thread_hydrated,"workerError":worker_result.get("workerError", "") if worker_result is Dictionary else "invalid_result"})
	)

func _contains_object(value: Variant) -> bool:
	if value is Object:
		return true
	if value is Dictionary:
		for key in value:
			if _contains_object(key) or _contains_object(value[key]):
				return true
	elif value is Array:
		for item in value:
			if _contains_object(item):
				return true
	return false

func test_fluid_only_avoids_terrain_detail_scan() -> void:
	var owner := PayloadOwner.new()
	var service := TerrainMeshingServiceScript.new()
	service.main = owner
	var bounds := {"minY":-4,"maxY":18}
	var fluid: Dictionary = service.begin_section_payload_for_chunk(2,-1,bounds,true)
	var no_terrain_query := owner.terrain_detail_queries == 0
	var terrain: Dictionary = service.begin_section_payload_for_chunk(2,-1,bounds,false)
	add_result("synthetic_fluid_only_skips_terrain_lod_scan",no_terrain_query and fluid.stepCells == 1 and terrain.stepCells == 4 and owner.terrain_detail_queries == 1,"Exact fluid job keeps source bounds while ordinary terrain keeps its detail policy")
	owner.free()

func test_generated_surface_bounds_enclose_exact_projection() -> void:
	var samples: Array[Dictionary] = []
	var all_passed := true
	for seed in ["atlas-1492", "atlas-49731342", "atlas-57929567"]:
		for chunk_key in [Vector2i(0, 0), Vector2i(3, -4), Vector2i(-5, 2)]:
			var exact_world: Object = make_world(seed)
			var start_x: int = chunk_key.x * CHUNK_SIZE
			var start_z: int = chunk_key.y * CHUNK_SIZE
			var exact_started_usec := Time.get_ticks_usec()
			var exact_bounds := exact_projection_bounds(exact_world, start_x, start_z)
			var exact_elapsed_ms := elapsed_ms(exact_started_usec)
			var authority_world: Object = make_world(seed)
			var authority_started_usec := Time.get_ticks_usec()
			var authority_bounds: Dictionary = authority_world.terrain_meshing_y_bounds_for_chunk(
				start_x,
				start_z,
				CHUNK_SIZE,
				BELOW_SURFACE_CELLS,
				ABOVE_SURFACE_CELLS,
				BORDER_CELLS
			)
			var authority_elapsed_ms := elapsed_ms(authority_started_usec)
			var passed := bounds_enclose(authority_bounds, exact_bounds)
			all_passed = all_passed and passed
			samples.append({
				"seed": seed,
				"chunk": [chunk_key.x, chunk_key.y],
				"exact": exact_bounds,
				"authoritative": authority_bounds,
				"exactElapsedMs": exact_elapsed_ms,
				"authoritativeElapsedMs": authority_elapsed_ms,
				"passed": passed
			})
			dispose_world(exact_world)
			dispose_world(authority_world)
	add_result(
		"generated_bounds_enclose_exact_surface_projection",
		all_passed,
		JSON.stringify(samples)
	)

func test_incremental_bounds_match_direct_authority() -> void:
	var direct_world: Object = make_world("atlas-1492")
	var direct: Dictionary = direct_world.terrain_meshing_y_bounds_for_chunk(84, -112, CHUNK_SIZE, BELOW_SURFACE_CELLS, ABOVE_SURFACE_CELLS, BORDER_CELLS)
	var incremental_world: Object = make_world("atlas-1492")
	var state: Dictionary = incremental_world.begin_terrain_meshing_bounds_state(84, -112, CHUNK_SIZE, BELOW_SURFACE_CELLS, ABOVE_SURFACE_CELLS, BORDER_CELLS)
	var steps := 0
	var max_columns := 0
	var max_elapsed_ms := 0.0
	var advanced: Dictionary = {}
	while not bool(state.get("complete", false)) and steps < 1000:
		advanced = incremental_world.advance_terrain_meshing_bounds_state(state, 0.25, 12)
		state = advanced.get("state", state)
		max_columns = maxi(max_columns, int(advanced.get("columnsProcessed", 0)))
		max_elapsed_ms = maxf(max_elapsed_ms, float(advanced.get("elapsedMs", 0.0)))
		steps += 1
	var incremental: Dictionary = advanced.get("bounds", {}) if advanced.get("bounds", {}) is Dictionary else {}
	var passed := bool(state.get("complete", false)) \
		and steps > 1 \
		and max_columns <= 12 \
		and int(incremental.get("minY", 0)) == int(direct.get("minY", 1)) \
		and int(incremental.get("maxY", 0)) == int(direct.get("maxY", 1))
	add_result(
		"incremental_bounds_match_direct_authority",
		passed,
		JSON.stringify({ "direct": direct, "incremental": incremental, "steps": steps, "maxColumns": max_columns, "maxElapsedMs": max_elapsed_ms })
	)
	dispose_world(direct_world)
	dispose_world(incremental_world)

func test_mesh_edits_expand_authoritative_bounds() -> void:
	var world: Object = make_world("atlas-1492")
	var start_x := 0
	var start_z := 0
	var baseline: Dictionary = world.terrain_meshing_y_bounds_for_chunk(start_x, start_z, CHUNK_SIZE, BELOW_SURFACE_CELLS, ABOVE_SURFACE_CELLS, BORDER_CELLS)
	var raised_cell := Vector3i(start_x - 1, int(baseline.get("maxY", 0)) + 12, start_z + 2)
	var carved_cell := Vector3i(start_x + 3, int(baseline.get("minY", 0)) - 9, start_z + 3)
	world.set_cell_state(raised_cell, {
		"material": "stone",
		"solid": true,
		"fluid": "",
		"metadata": { "source": "terrain_bounds_contract" }
	}, "terrain_bounds_contract_raised")
	world.set_cell_state(carved_cell, {
		"material": "air",
		"solid": false,
		"fluid": "",
		"metadata": { "source": "terrain_bounds_contract" }
	}, "terrain_bounds_contract_carved")
	var edited: Dictionary = world.terrain_meshing_y_bounds_for_chunk(start_x, start_z, CHUNK_SIZE, BELOW_SURFACE_CELLS, ABOVE_SURFACE_CELLS, BORDER_CELLS)
	var repeated: Dictionary = world.terrain_meshing_y_bounds_for_chunk(start_x, start_z, CHUNK_SIZE, BELOW_SURFACE_CELLS, ABOVE_SURFACE_CELLS, BORDER_CELLS)
	var passed := int(edited.get("maxY", -999999)) >= raised_cell.y + 3 \
		and int(edited.get("minY", 999999)) <= carved_cell.y - 3 \
		and int(edited.get("minY", 0)) == int(repeated.get("minY", 1)) \
		and int(edited.get("maxY", 0)) == int(repeated.get("maxY", 1))
	add_result(
		"mesh_edits_expand_bounds_and_results_are_deterministic",
		passed,
		JSON.stringify({ "baseline": baseline, "raised": raised_cell, "carved": carved_cell, "edited": edited, "repeated": repeated })
	)
	dispose_world(world)

func test_retired_payload_cleanup_is_bounded() -> void:
	var service = TerrainMeshingServiceScript.new()
	for index in range(service.RETIRED_PAYLOAD_JOB_LIMIT):
		service.retired_payload_jobs.append({
			"id": index,
			"scratch": PackedByteArray([index])
		})
	var before: Dictionary = service.backend_summary()
	service.advance_retired_payload_cleanup(true)
	var after: Dictionary = service.backend_summary()
	var source := FileAccess.get_file_as_string("res://scripts/TerrainMeshingService.gd")
	var passed: bool = int(before.get("retiredPayloadBacklog", -1)) == service.RETIRED_PAYLOAD_JOB_LIMIT \
		and int(before.get("retiredPayloadLimit", -1)) == service.RETIRED_PAYLOAD_JOB_LIMIT \
		and int(after.get("retiredPayloadBacklog", -1)) == 0 \
		and int(after.get("retiredPayloadCleanupCount", -1)) == service.RETIRED_PAYLOAD_JOB_LIMIT \
		and source.find("retired_payload_backlog() >= RETIRED_PAYLOAD_JOB_LIMIT") >= 0 \
		and source.find("Thread.PRIORITY_LOW") >= 0
	add_result(
		"retired_payload_cleanup_has_bounded_backpressure_and_low_priority_retirement",
		passed,
		JSON.stringify({"before": before, "after": after})
	)

func make_world(seed: String) -> Object:
	var main := FakeMain.new()
	main.seed_text = seed
	var world = WorldGenerationSystemScript.new()
	world.setup(main)
	return world

func dispose_world(world: Object) -> void:
	if world == null:
		return
	if world.has_method("reset"):
		world.call("reset")
	var terrain_volume = world.get("terrain_volume_service")
	if terrain_volume != null:
		terrain_volume.set("generator", null)
		terrain_volume.set("main", null)
	world.set("terrain_volume_service", null)
	world.set("main", null)

func exact_projection_bounds(world, start_x: int, start_z: int) -> Dictionary:
	var min_surface_y := INF
	var max_surface_y := -INF
	for z in range(start_z - BORDER_CELLS, start_z + CHUNK_SIZE + BORDER_CELLS + 1):
		for x in range(start_x - BORDER_CELLS, start_x + CHUNK_SIZE + BORDER_CELLS + 1):
			var surface_y := float(world.surface_y_for_cell(Vector3i(x, 0, z)))
			min_surface_y = minf(min_surface_y, surface_y)
			max_surface_y = maxf(max_surface_y, surface_y)
	var cell := float(world.cell_size())
	var min_bound := maxf(float(world.world_bottom_cell_y()) * cell, min_surface_y - float(BELOW_SURFACE_CELLS) * cell)
	var max_bound := max_surface_y + float(ABOVE_SURFACE_CELLS) * cell
	return {
		"minY": floori(min_bound / cell),
		"maxY": ceili(max_bound / cell),
		"surfaceMinY": min_surface_y,
		"surfaceMaxY": max_surface_y
	}

func bounds_enclose(actual: Dictionary, expected: Dictionary) -> bool:
	return int(actual.get("minY", 999999)) <= int(expected.get("minY", -999999)) \
		and int(actual.get("maxY", -999999)) >= int(expected.get("maxY", 999999))

func elapsed_ms(started_usec: int) -> float:
	return float(Time.get_ticks_usec() - started_usec) / 1000.0

func add_result(name: String, passed: bool, details: String) -> void:
	results.append({ "name": name, "passed": passed, "details": details })
	print("[%s] %s %s" % ["PASS" if passed else "FAIL", name, details])

func finish() -> void:
	var passed := true
	for result in results:
		passed = passed and bool(result.get("passed", false))
	var report := {
		"schemaVersion": 1,
		"runnerId": "terrain_meshing_bounds_contract",
		"evidenceLevel": "contract",
		"passed": passed,
		"results": results
	}
	if report_path != "":
		DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "  "))
			file.close()
	print(JSON.stringify(report, "  "))
	quit(0 if passed else 1)
