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

class RecordingPayloadWorld extends RefCounted:
	var observed_budget_ms := -1.0
	var observed_max_cells := -1
	var observed_fluid_budget_ms := -1.0
	var observed_fluid_max_cells := -1
	var terrain_calls := 0
	var fluid_calls := 0
	var terrain_complete := false
	var terrain_cells := -1
	var fluid_complete := false
	var fluid_cells := -1
	var bounds_calls := 0
	var bounds_complete := false
	var bounds_delay_usec := 0
	var bounds_state_init_calls := 0
	var terrain_state_init_calls := 0
	var fluid_state_init_calls := 0

	func begin_terrain_meshing_bounds_state(_x: int, _z: int, _size: int) -> Dictionary:
		bounds_state_init_calls += 1
		return {"cursor": 0, "complete": false}

	func advance_terrain_meshing_bounds_state(state: Dictionary, _budget_ms: float, _max_columns: int) -> Dictionary:
		bounds_calls += 1
		if bounds_delay_usec > 0:
			OS.delay_usec(bounds_delay_usec)
		var next_state := state.duplicate(true)
		next_state["cursor"] = int(next_state.get("cursor", 0)) + 1
		next_state["complete"] = bounds_complete
		return {
			"state": next_state,
			"complete": bounds_complete,
			"bounds": {"minY": 8, "maxY": 14} if bounds_complete else {},
			"columnsProcessed": 1,
			"elapsedMs": float(bounds_delay_usec) / 1000.0
		}

	func begin_section_payload_for_meshing_chunk(start_x: int, start_z: int, size: int, min_y: int, max_y: int, step: int) -> Dictionary:
		terrain_state_init_calls += 1
		return {"startX": start_x, "startZ": start_z, "chunkSize": size, "minY": min_y, "maxY": max_y, "stepCells": step, "cursor": 0}

	func begin_exact_fluid_payload_for_meshing_chunk(start_x: int, start_z: int, size: int, min_y: int, max_y: int, step: int) -> Dictionary:
		fluid_state_init_calls += 1
		return {"startX": start_x, "startZ": start_z, "chunkSize": size, "minY": min_y, "maxY": max_y, "stepCells": step, "cursor": 0}

	func advance_section_payload_state(state: Dictionary, budget_ms: float, max_cells: int) -> Dictionary:
		terrain_calls += 1
		observed_budget_ms = budget_ms
		observed_max_cells = max_cells
		var processed := mini(max_cells, terrain_cells) if terrain_cells >= 0 else max_cells
		var next_state := state.duplicate(true)
		next_state["cursor"] = int(next_state.get("cursor", 0)) + processed
		return {
			"state": next_state,
			"complete": terrain_complete,
			"payload": {"sections": [], "stepCells": 1} if terrain_complete else {},
			"cellsProcessed": processed,
			"preparedSections": 1,
			"elapsedMs": 0.01
		}

	func advance_exact_fluid_payload_state(state: Dictionary, budget_ms: float, max_cells: int) -> Dictionary:
		fluid_calls += 1
		observed_fluid_budget_ms = budget_ms
		observed_fluid_max_cells = max_cells
		var processed := mini(max_cells, fluid_cells) if fluid_cells >= 0 else max_cells
		var next_state := state.duplicate(true)
		next_state["cursor"] = int(next_state.get("cursor", 0)) + processed
		return {
			"state": next_state,
			"complete": fluid_complete,
			"payload": {"sections": [], "hasFluid": false} if fluid_complete else {},
			"cellsProcessed": processed,
			"preparedSections": 1,
			"elapsedMs": 0.01
		}

class RecordingPayloadOwner extends Node:
	const CHUNK_SIZE := 28
	var world_generation_system := RecordingPayloadWorld.new()
	var signature_text := "stable-signature"
	var signature_delay_usec := 0

	func chunk_asset_signature(_key: Vector2i) -> String:
		if signature_delay_usec > 0:
			OS.delay_usec(signature_delay_usec)
		return signature_text

	func underground_volume_mesh_step_for_chunk(_x: int, _z: int) -> int:
		return 1

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_TERRAIN_MESH_BOUNDS_REPORT").strip_edges()
	test_async_worker_returns_surface_values_only()
	test_fluid_only_avoids_terrain_detail_scan()
	test_generated_surface_bounds_enclose_exact_projection()
	test_incremental_bounds_match_direct_authority()
	test_mesh_edits_expand_authoritative_bounds()
	test_payload_slice_budget_is_forwarded()
	test_payload_preflight_deadline_defers_and_retries()
	test_process_jobs_deadline_before_pending_promotion()
	test_process_jobs_deadline_between_bounds_and_payload_state_init()
	test_gameplay_total_payload_cap_covers_terrain_and_fluid()
	test_loading_payload_caps_remain_unchanged()
	test_stale_payload_is_cancelled_before_sampling()
	test_payload_slice_sizes_are_byte_identical_and_tiny_budget_progresses()
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

func test_payload_slice_budget_is_forwarded() -> void:
	var owner := RecordingPayloadOwner.new()
	var service := TerrainMeshingServiceScript.new()
	service.main = owner
	service.async_payload_job = {
		"key": Vector2i.ZERO,
		"terrainSignature": "stable-signature",
		"includeCollision": true,
		"fluidOnly": false,
		"boundsState": {},
		"terrainState": {"cursor": 0},
		"fluidState": {},
		"terrainPayload": {}
	}
	var result: Dictionary = service.start_next_async_native_job(Vector2i.ZERO, 0.75, 64)
	var retained_state: Dictionary = service.async_payload_job.get("terrainState", {})
	var passed := is_equal_approx(owner.world_generation_system.observed_budget_ms, 0.75) \
		and owner.world_generation_system.observed_max_cells == 64 \
		and int(result.get("payloadCells", -1)) == 64 \
		and int(retained_state.get("cursor", -1)) == 64 \
		and not service.async_payload_job.is_empty()
	add_result(
		"terrain_payload_slice_forwards_budget_and_cell_cap_without_dropping_job",
		passed,
		JSON.stringify({
			"observedBudgetMs": owner.world_generation_system.observed_budget_ms,
			"observedMaxCells": owner.world_generation_system.observed_max_cells,
			"payloadCells": result.get("payloadCells", -1),
			"retainedCursor": retained_state.get("cursor", -1),
			"jobRetained": not service.async_payload_job.is_empty()
		})
	)
	service.main = null
	owner.free()

func test_payload_preflight_deadline_defers_and_retries() -> void:
	var owner := RecordingPayloadOwner.new()
	owner.signature_delay_usec = 500
	var service := TerrainMeshingServiceScript.new()
	service.main = owner
	service.async_payload_job = recording_payload_job()
	var expired_result: Dictionary = service.start_next_async_native_job(
		Vector2i.ZERO, 0.75, 64, Time.get_ticks_usec() + 200, 64
	)
	var deferred_without_sampling := owner.world_generation_system.terrain_calls == 0 \
		and int(expired_result.get("payloadCells", -1)) == 0 \
		and not service.async_payload_job.is_empty()
	owner.signature_delay_usec = 0
	var retry_result: Dictionary = service.start_next_async_native_job(
		Vector2i.ZERO, 0.75, 64, Time.get_ticks_usec() + 5000, 64
	)
	var passed := deferred_without_sampling \
		and owner.world_generation_system.terrain_calls == 1 \
		and int(retry_result.get("payloadCells", -1)) == 64 \
		and int(service.async_payload_job.get("terrainState", {}).get("cursor", -1)) == 64
	add_result(
		"terrain_payload_preflight_consumes_deadline_then_job_defers_and_retries",
		passed,
		JSON.stringify({
			"deferredWithoutSampling": deferred_without_sampling,
			"terrainCallsAfterRetry": owner.world_generation_system.terrain_calls,
			"retryPayloadCells": retry_result.get("payloadCells", -1),
			"retryCursor": service.async_payload_job.get("terrainState", {}).get("cursor", -1)
		})
	)
	service.main = null
	owner.free()

func test_process_jobs_deadline_before_pending_promotion() -> void:
	var owner := RecordingPayloadOwner.new()
	var service := TerrainMeshingServiceScript.new()
	service.main = owner
	service.backend = ValueOnlyBackend.new()
	service.native_backend_available = true
	service.request_chunk_assets(0, 0, "stable-signature", true)
	var expired_result: Dictionary = service.process_jobs(
		1, 1.5, Vector2i.ZERO, 64, Time.get_ticks_usec(), 64
	)
	var deferred_exactly := service.pending_jobs.size() == 1 \
		and service.async_payload_job.is_empty() \
		and owner.world_generation_system.bounds_state_init_calls == 0 \
		and owner.world_generation_system.bounds_calls == 0 \
		and owner.world_generation_system.terrain_state_init_calls == 0 \
		and owner.world_generation_system.fluid_state_init_calls == 0 \
		and int(expired_result.get("payloadCells", -1)) == 0
	var retry_result: Dictionary = service.process_jobs(
		1, 1.5, Vector2i.ZERO, 64, Time.get_ticks_usec() + 5000, 64
	)
	var passed := deferred_exactly \
		and service.pending_jobs.is_empty() \
		and not service.async_payload_job.is_empty() \
		and owner.world_generation_system.bounds_state_init_calls == 1 \
		and owner.world_generation_system.bounds_calls == 1 \
		and int(retry_result.get("boundsColumns", -1)) == 1
	add_result(
		"process_jobs_expired_slice_keeps_pending_job_unpromoted_then_retry_advances",
		passed,
		JSON.stringify({
			"deferredExactly": deferred_exactly,
			"pendingAfterRetry": service.pending_jobs.size(),
			"activeAfterRetry": not service.async_payload_job.is_empty(),
			"boundsStateInitCalls": owner.world_generation_system.bounds_state_init_calls,
			"boundsCalls": owner.world_generation_system.bounds_calls,
			"retryBoundsColumns": retry_result.get("boundsColumns", -1)
		})
	)
	service.main = null
	owner.free()

func test_process_jobs_deadline_between_bounds_and_payload_state_init() -> void:
	var owner := RecordingPayloadOwner.new()
	owner.world_generation_system.bounds_complete = true
	owner.world_generation_system.bounds_delay_usec = 2000
	var service := TerrainMeshingServiceScript.new()
	service.main = owner
	service.backend = ValueOnlyBackend.new()
	service.native_backend_available = true
	service.request_chunk_assets(0, 0, "stable-signature", true)
	var expired_result: Dictionary = service.process_jobs(
		1, 1.5, Vector2i.ZERO, 64, Time.get_ticks_usec() + 5000, 64
	)
	var active_bounds: Dictionary = service.async_payload_job.get("boundsState", {})
	var deferred_after_bounds := service.pending_jobs.is_empty() \
		and not service.async_payload_job.is_empty() \
		and bool(active_bounds.get("complete", false)) \
		and owner.world_generation_system.bounds_calls == 1 \
		and owner.world_generation_system.terrain_state_init_calls == 0 \
		and owner.world_generation_system.fluid_state_init_calls == 0 \
		and int(expired_result.get("boundsColumns", -1)) == 1
	owner.world_generation_system.bounds_delay_usec = 0
	var retry_result: Dictionary = service.process_jobs(
		1, 1.5, Vector2i.ZERO, 64, Time.get_ticks_usec() + 5000, 64
	)
	var terrain_state_after_retry: Dictionary = service.async_payload_job.get("terrainState", {})
	var passed := deferred_after_bounds \
		and owner.world_generation_system.terrain_state_init_calls == 1 \
		and owner.world_generation_system.fluid_state_init_calls == 1 \
		and not terrain_state_after_retry.is_empty() \
		and int(retry_result.get("dropped", -1)) == 0
	add_result(
		"process_jobs_completed_bounds_wait_for_new_slice_before_payload_state_init",
		passed,
		JSON.stringify({
			"deferredAfterBounds": deferred_after_bounds,
			"boundsCalls": owner.world_generation_system.bounds_calls,
			"terrainStateInitCalls": owner.world_generation_system.terrain_state_init_calls,
			"fluidStateInitCalls": owner.world_generation_system.fluid_state_init_calls,
			"terrainStateReadyAfterRetry": not terrain_state_after_retry.is_empty(),
			"retryDropped": retry_result.get("dropped", -1)
		})
	)
	service.main = null
	owner.free()

func test_gameplay_total_payload_cap_covers_terrain_and_fluid() -> void:
	var owner := RecordingPayloadOwner.new()
	owner.world_generation_system.terrain_complete = true
	owner.world_generation_system.terrain_cells = 40
	var service := TerrainMeshingServiceScript.new()
	service.main = owner
	service.async_payload_job = recording_payload_job()
	var result: Dictionary = service.start_next_async_native_job(
		Vector2i.ZERO, 1.5, 64, Time.get_ticks_usec() + 10000, 64
	)
	var passed := owner.world_generation_system.terrain_calls == 1 \
		and owner.world_generation_system.fluid_calls == 1 \
		and owner.world_generation_system.observed_max_cells == 64 \
		and owner.world_generation_system.observed_fluid_max_cells == 24 \
		and int(result.get("payloadCells", -1)) == 64 \
		and int(result.get("fluidPayloadCells", -1)) == 24 \
		and not service.async_payload_job.is_empty()
	add_result(
		"gameplay_payload_total_cap_covers_terrain_and_exact_fluid_sampling",
		passed,
		JSON.stringify({
			"terrainCellCap": owner.world_generation_system.observed_max_cells,
			"fluidCellCap": owner.world_generation_system.observed_fluid_max_cells,
			"terrainCells": int(result.get("payloadCells", 0)) - int(result.get("fluidPayloadCells", 0)),
			"fluidCells": result.get("fluidPayloadCells", -1),
			"totalCells": result.get("payloadCells", -1),
			"jobRetained": not service.async_payload_job.is_empty()
		})
	)
	service.main = null
	owner.free()

func test_loading_payload_caps_remain_unchanged() -> void:
	var terrain_owner := RecordingPayloadOwner.new()
	var terrain_service := TerrainMeshingServiceScript.new()
	terrain_service.main = terrain_owner
	terrain_service.async_payload_job = recording_payload_job()
	var terrain_result: Dictionary = terrain_service.start_next_async_native_job(Vector2i.ZERO, 3.25)
	var fluid_owner := RecordingPayloadOwner.new()
	var fluid_service := TerrainMeshingServiceScript.new()
	fluid_service.main = fluid_owner
	var fluid_job := recording_payload_job()
	fluid_job["terrainPayload"] = {"sections": [], "stepCells": 1}
	fluid_service.async_payload_job = fluid_job
	var fluid_result: Dictionary = fluid_service.start_next_async_native_job(Vector2i.ZERO, 3.25)
	var passed := terrain_owner.world_generation_system.observed_max_cells == 192 \
		and int(terrain_result.get("payloadCells", -1)) == 192 \
		and fluid_owner.world_generation_system.observed_fluid_max_cells == 2048 \
		and int(fluid_result.get("fluidPayloadCells", -1)) == 2048
	add_result(
		"loading_payload_defaults_keep_independent_192_terrain_and_2048_fluid_caps",
		passed,
		JSON.stringify({
			"terrainCap": terrain_owner.world_generation_system.observed_max_cells,
			"terrainCells": terrain_result.get("payloadCells", -1),
			"fluidCap": fluid_owner.world_generation_system.observed_fluid_max_cells,
			"fluidCells": fluid_result.get("fluidPayloadCells", -1)
		})
	)
	terrain_service.main = null
	fluid_service.main = null
	terrain_owner.free()
	fluid_owner.free()

func test_stale_payload_is_cancelled_before_sampling() -> void:
	var owner := RecordingPayloadOwner.new()
	owner.signature_text = "changed-signature"
	var service := TerrainMeshingServiceScript.new()
	service.main = owner
	service.async_payload_job = recording_payload_job()
	var result: Dictionary = service.start_next_async_native_job(
		Vector2i.ZERO, 1.5, 64, Time.get_ticks_usec() + 5000, 64
	)
	var passed := int(result.get("dropped", 0)) == 1 \
		and String(result.get("dropReason", "")) == "terrain_signature_changed_during_payload" \
		and service.async_payload_job.is_empty() \
		and owner.world_generation_system.terrain_calls == 0 \
		and owner.world_generation_system.fluid_calls == 0
	add_result(
		"stale_terrain_payload_cancels_before_bounded_sampling",
		passed,
		JSON.stringify({
			"dropped": result.get("dropped", 0),
			"dropReason": result.get("dropReason", ""),
			"jobCleared": service.async_payload_job.is_empty(),
			"terrainCalls": owner.world_generation_system.terrain_calls,
			"fluidCalls": owner.world_generation_system.fluid_calls
		})
	)
	service.main = null
	owner.free()

func recording_payload_job() -> Dictionary:
	return {
		"key": Vector2i.ZERO,
		"terrainSignature": "stable-signature",
		"includeCollision": true,
		"fluidOnly": false,
		"boundsState": {},
		"terrainState": {"cursor": 0},
		"fluidState": {"cursor": 0},
		"terrainPayload": {}
	}

func test_payload_slice_sizes_are_byte_identical_and_tiny_budget_progresses() -> void:
	var large_world: Object = make_world("atlas-1492")
	var small_world: Object = make_world("atlas-1492")
	var tiny_world: Object = make_world("atlas-1492")
	var large_result := finish_payload_with_slice(large_world, 3.25, 192)
	var small_result := finish_payload_with_slice(small_world, 1.5, 64)
	var tiny_result := finish_payload_with_slice(tiny_world, 0.1, 1)
	var large_bytes: PackedByteArray = var_to_bytes(large_result.get("payload", {}))
	var small_bytes: PackedByteArray = var_to_bytes(small_result.get("payload", {}))
	var tiny_bytes: PackedByteArray = var_to_bytes(tiny_result.get("payload", {}))
	var large_signature := payload_sha256(large_bytes)
	var small_signature := payload_sha256(small_bytes)
	var tiny_signature := payload_sha256(tiny_bytes)
	var passed := bool(large_result.get("complete", false)) \
		and bool(small_result.get("complete", false)) \
		and bool(tiny_result.get("complete", false)) \
		and int(small_result.get("steps", 0)) > int(large_result.get("steps", 0)) \
		and int(tiny_result.get("steps", 0)) > int(small_result.get("steps", 0)) \
		and int(tiny_result.get("progressingSteps", 0)) == int(tiny_result.get("steps", -1)) \
		and int(tiny_result.get("maxCellsPerStep", -1)) == 1 \
		and large_bytes == small_bytes and small_bytes == tiny_bytes \
		and large_signature == small_signature and small_signature == tiny_signature
	add_result(
		"terrain_payload_slice_sizes_preserve_exact_bytes_signature_and_tiny_budget_liveness",
		passed,
		JSON.stringify({
			"largeSteps": large_result.get("steps", -1),
			"smallSteps": small_result.get("steps", -1),
			"tinySteps": tiny_result.get("steps", -1),
			"tinyProgressingSteps": tiny_result.get("progressingSteps", -1),
			"tinyMaxCellsPerStep": tiny_result.get("maxCellsPerStep", -1),
			"payloadBytes": large_bytes.size(),
			"largeSignature": large_signature,
			"smallSignature": small_signature,
			"tinySignature": tiny_signature
		})
	)
	dispose_world(large_world)
	dispose_world(small_world)
	dispose_world(tiny_world)

func finish_payload_with_slice(world: Object, budget_ms: float, max_cells: int) -> Dictionary:
	var state: Dictionary = world.begin_section_payload_for_meshing_chunk(0, 0, 6, 8, 14, 1)
	var steps := 0
	var progressing_steps := 0
	var max_cells_per_step := 0
	var payload := {}
	while not bool(state.get("complete", false)) and steps < 4096:
		var before_cells := int(state.get("cellsProcessed", 0))
		var advanced: Dictionary = world.advance_section_payload_state(state, budget_ms, max_cells)
		state = advanced.get("state", state)
		var processed := int(advanced.get("cellsProcessed", 0))
		max_cells_per_step = maxi(max_cells_per_step, processed)
		if processed > 0 and int(state.get("cellsProcessed", 0)) > before_cells:
			progressing_steps += 1
		if bool(advanced.get("complete", false)):
			payload = advanced.get("payload", {})
		steps += 1
	return {
		"complete": bool(state.get("complete", false)),
		"payload": payload,
		"steps": steps,
		"progressingSteps": progressing_steps,
		"maxCellsPerStep": max_cells_per_step
	}

func payload_sha256(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()

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
