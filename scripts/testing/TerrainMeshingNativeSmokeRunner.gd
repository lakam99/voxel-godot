extends SceneTree

const TerrainMeshingServiceScript := preload("res://scripts/TerrainMeshingService.gd")
const WorldGenerationSystemScript := preload("res://scripts/WorldGenerationSystem.gd")
const VoxelWorldGenerationContextScript := preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const EXTENSION_PATH := "res://addons/terrain_meshing_backend/terrain_meshing_backend.gdextension"
const BACKEND_CLASS := "TerrainMeshingBackend"
const SECTION_SIZE := 16
const CELL_SIZE := 1.35

func _init() -> void:
	call_deferred("run")

func run() -> void:
	var report_path := OS.get_environment("VOXEL_TERRAIN_MESHING_NATIVE_SMOKE_REPORT").strip_edges()
	if report_path == "":
		report_path = "artifacts/terrain-volume/terrain-meshing-native-smoke.json"
	var native_paths = ProjectSettings.get_setting("native_extensions/paths", [])
	var report := {
		"schemaVersion": 1,
		"runnerId": "terrain_meshing_native_smoke",
		"extensionPath": EXTENSION_PATH,
		"nativeExtensionPaths": native_paths,
		"resourceExists": ResourceLoader.exists(EXTENSION_PATH),
		"extensionManagerSingleton": Engine.has_singleton("GDExtensionManager"),
		"explicitLoadStatus": -1,
		"loadedExtensions": [],
		"classExists": ClassDB.class_exists(BACKEND_CLASS),
		"singletonExists": Engine.has_singleton(BACKEND_CLASS),
		"instantiated": false,
		"backendSummary": {},
		"serviceSummary": {},
		"workerGraphOwnership": {},
		"workerPoolRoundTrip": {},
		"status": "failed"
	}
	if Engine.has_singleton("GDExtensionManager"):
		var manager = Engine.get_singleton("GDExtensionManager")
		if manager != null:
			if manager.has_method("is_extension_loaded") and bool(manager.call("is_extension_loaded", EXTENSION_PATH)):
				report["explicitLoadStatus"] = 2
			elif manager.has_method("load_extension"):
				report["explicitLoadStatus"] = int(manager.call("load_extension", EXTENSION_PATH))
			if manager.has_method("get_loaded_extensions"):
				report["loadedExtensions"] = manager.call("get_loaded_extensions")
	report["classExists"] = ClassDB.class_exists(BACKEND_CLASS)
	report["singletonExists"] = Engine.has_singleton(BACKEND_CLASS)
	if bool(report["classExists"]):
		var instance = ClassDB.instantiate(BACKEND_CLASS)
		report["instantiated"] = instance != null
		if instance != null and instance.has_method("backend_summary"):
			var summary_value = instance.call("backend_summary")
			if summary_value is Dictionary:
				report["backendSummary"] = summary_value
				report["status"] = "passed" if bool(summary_value.get("ready", false)) else "failed"
			else:
				report["status"] = "passed"
	var service = TerrainMeshingServiceScript.new()
	if service != null:
		service.setup(null)
		if service.has_method("backend_summary"):
			var service_summary_value = service.backend_summary()
			if service_summary_value is Dictionary:
				report["serviceSummary"] = service_summary_value
	var backend_summary: Dictionary = report["backendSummary"] if report["backendSummary"] is Dictionary else {}
	var service_summary: Dictionary = report["serviceSummary"] if report["serviceSummary"] is Dictionary else {}
	var backend_ready := bool(backend_summary.get("ready", false))
	var service_async := bool(service_summary.get("async", false))
	if backend_ready and service_async:
		report["workerPoolRoundTrip"] = await await_worker_pool_round_trip(service)
	report["workerGraphOwnership"] = await worker_graph_ownership_contract()
	var worker_pool_round_trip: Dictionary = report["workerPoolRoundTrip"] if report["workerPoolRoundTrip"] is Dictionary else {}
	var worker_graph_ownership: Dictionary = report["workerGraphOwnership"] if report["workerGraphOwnership"] is Dictionary else {}
	report["status"] = "passed" if backend_ready and service_async and bool(worker_pool_round_trip.get("passed", false)) and bool(worker_graph_ownership.get("passed", false)) else "failed"
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
	quit(0 if String(report["status"]) == "passed" else 1)

func await_worker_pool_round_trip(service) -> Dictionary:
	var payload := exact_fluid_payload()
	var started: Dictionary = service.start_async_worker_from_payload(
		Vector2i.ZERO,
		"native-smoke-worker-pool",
		payload,
		false,
		true,
		{}
	)
	var task_id := int(service.async_worker_task_id)
	if not bool(started.get("started", false)) or task_id < 0:
		return {
			"passed": false,
			"reason": "worker_task_not_started",
			"start": started,
			"taskId": task_id
		}
	var last_summary := {}
	for frame in range(180):
		await process_frame
		last_summary = service.collect_async_worker_result()
		if int(last_summary.get("processed", 0)) > 0:
			var assets: Dictionary = service.take_completed_chunk_assets(0, 0, "native-smoke-worker-pool")
			var fluid_mesh = assets.get("fluidMesh")
			var passed: bool = fluid_mesh is Mesh \
				and fluid_mesh.get_surface_count() > 0 \
				and bool(fluid_mesh.get_meta("terrainMeshingNative", false)) \
				and bool(fluid_mesh.get_meta("terrainFluidSectionPayload", false))
			service.clear_jobs(true)
			return {
				"passed": passed,
				"taskId": task_id,
				"frames": frame + 1,
				"summary": last_summary,
				"fluidSurfaceCount": fluid_mesh.get_surface_count() if fluid_mesh is Mesh else 0,
				"native": bool(fluid_mesh.get_meta("terrainMeshingNative", false)) if fluid_mesh is Mesh else false,
				"sectionPayload": bool(fluid_mesh.get_meta("terrainFluidSectionPayload", false)) if fluid_mesh is Mesh else false
			}
	service.clear_jobs(true)
	return {
		"passed": false,
		"reason": "worker_task_did_not_finalize",
		"taskId": task_id,
		"frames": 180,
		"lastSummary": last_summary,
		"workerActive": bool(service.async_worker_active)
	}

func worker_graph_ownership_contract() -> Dictionary:
	# VoxelTerrain's native worker creates this graph for every generated block.
	# The service must only retain a weak generator callback and scalar settings;
	# otherwise context -> generator -> service -> context survives indefinitely
	# and tempts unsafe manual teardown from a worker thread.
	var references := make_detached_worker_graph_references()
	await process_frame
	var context_ref = references.get("context") as WeakRef
	var generation_ref = references.get("generation") as WeakRef
	var context_released := context_ref != null and context_ref.get_ref() == null
	var generation_released := generation_ref != null and generation_ref.get_ref() == null
	return {
		"passed": context_released and generation_released,
		"contextReleased": context_released,
		"generationReleased": generation_released,
		"ownership": "scalar_config_plus_weak_generator_callback"
	}

func make_detached_worker_graph_references() -> Dictionary:
	var context = VoxelWorldGenerationContextScript.new()
	var generation = WorldGenerationSystemScript.new()
	generation.setup(context)
	context.set_generator(generation)
	return {
		"context": weakref(context),
		"generation": weakref(generation)
	}

func exact_fluid_payload() -> Dictionary:
	var min_cell := Vector3i(-1, 1, -1)
	var max_cell := Vector3i(2, 3, 2)
	var cells_size := max_cell - min_cell + Vector3i.ONE
	var solid_values := PackedByteArray()
	var fluid_values := PackedByteArray()
	solid_values.resize(cells_size.x * cells_size.y * cells_size.z)
	fluid_values.resize(cells_size.x * cells_size.y * cells_size.z)
	# One water cell is enough to verify the actual worker-pool dispatch and
	# main-thread finalization path without relying on a scene or terrain cache.
	var water_cell := Vector3i(0, 2, 0)
	var local := water_cell - min_cell
	var index := local.y + cells_size.y * (local.x + cells_size.x * local.z)
	fluid_values[index] = 1
	return {
		"schemaVersion": 1,
		"immutable": true,
		"sectionSize": SECTION_SIZE,
		"cellSize": CELL_SIZE,
		"chunkSize": 2,
		"chunkX": 0,
		"chunkZ": 0,
		"startX": 0,
		"startZ": 0,
		"minY": 2,
		"maxY": 2,
		"minCell": min_cell,
		"maxCell": max_cell,
		"boundsInclusive": true,
		"terrainStepCells": 1,
		"fluidStepCells": 1,
		"stepCells": 1,
		"revision": 1,
		"fluidRevision": 1,
		"signature": "native-smoke-worker-pool",
		"hasFluid": true,
		"fluidCellCount": 1,
		"sections": [],
		"cells": {
			"size": cells_size,
			"solid": solid_values,
			"fluidTypeIds": fluid_values
		}
	}
