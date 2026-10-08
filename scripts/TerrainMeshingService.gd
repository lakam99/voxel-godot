extends RefCounted
class_name TerrainMeshingService

const FALLBACK_BACKEND_ID := "gdscript_volume_mesher"
const NATIVE_BACKEND_ID := "native_volume_mesher"
const NATIVE_EXTENSION_PATH := "res://addons/terrain_meshing_backend/terrain_meshing_backend.gdextension"
const EXTENSION_LOAD_STATUS_OK := 0
const EXTENSION_LOAD_STATUS_ALREADY_LOADED := 2
const ASYNC_PAYLOAD_PREP_MAX_CELLS_PER_FRAME := 192
const ASYNC_EXACT_FLUID_PAYLOAD_MAX_CELLS_PER_FRAME := 2048
const ASYNC_WORKER_MIN_COLLECT_DELAY_MS := 36.0
const ASYNC_FLUID_FINALIZE_MAX_VERTICES_PER_FRAME := 768
const RETIRED_PAYLOAD_JOB_LIMIT := 4

var main
var backend
var backend_id := FALLBACK_BACKEND_ID
var native_backend_available := false
var allow_blocking_gdscript_fallback := false
var pending_jobs := {}
var completed_jobs := {}
var job_sequence := 0
var async_worker_task_id := -1
var async_worker_active := false
var async_worker_key := Vector2i(999999, 999999)
var async_worker_signature := ""
var async_worker_cancelled := false
var async_worker_done := false
var async_worker_started_usec := 0
var async_worker_payload := {}
var async_worker_result := {}
var async_worker_result_mutex := Mutex.new()
var async_payload_job := {}
var async_finalize_job := {}
var retired_worker_tasks: Array[int] = []
var retired_payload_jobs := []
var retired_payload_cleanup_thread: Thread = null
var retired_payload_cleanup_count := 0
var retired_payload_cleanup_start_failures := 0
var setup_initialized := false

func setup(main_node) -> void:
	main = main_node
	allow_blocking_gdscript_fallback = OS.get_environment("VOXEL_ALLOW_BLOCKING_GDSCRIPT_TERRAIN_MESHING").strip_edges() == "1"
	collect_retired_worker_tasks(false)
	advance_retired_payload_cleanup(false)
	if setup_initialized:
		return
	backend = discover_native_backend()
	native_backend_available = backend != null
	backend_id = NATIVE_BACKEND_ID if native_backend_available else FALLBACK_BACKEND_ID
	setup_initialized = true

func discover_native_backend():
	# GDExtension/native backends can expose a TerrainMeshingBackend autoload later.
	if Engine.has_singleton("TerrainMeshingBackend"):
		return native_backend_if_ready(Engine.get_singleton("TerrainMeshingBackend"))
	ensure_native_extension_loaded()
	if ClassDB.class_exists("TerrainMeshingBackend"):
		var instance = ClassDB.instantiate("TerrainMeshingBackend")
		if instance != null:
			return native_backend_if_ready(instance)
	return null

func ensure_native_extension_loaded() -> void:
	if ClassDB.class_exists("TerrainMeshingBackend"):
		return
	if not ResourceLoader.exists(NATIVE_EXTENSION_PATH):
		return
	if not Engine.has_singleton("GDExtensionManager"):
		return
	var manager = Engine.get_singleton("GDExtensionManager")
	if manager == null:
		return
	if manager.has_method("is_extension_loaded") and bool(manager.call("is_extension_loaded", NATIVE_EXTENSION_PATH)):
		return
	if not manager.has_method("load_extension"):
		return
	var status := int(manager.call("load_extension", NATIVE_EXTENSION_PATH))
	if status != EXTENSION_LOAD_STATUS_OK and status != EXTENSION_LOAD_STATUS_ALREADY_LOADED:
		push_warning("Terrain meshing native extension failed to load: %s status %d" % [NATIVE_EXTENSION_PATH, status])

func native_backend_if_ready(candidate):
	if candidate == null:
		return null
	if candidate.has_method("backend_summary"):
		var summary_value = candidate.call("backend_summary")
		if summary_value is Dictionary:
			var summary: Dictionary = summary_value
			if summary.has("ready") and not bool(summary.get("ready", false)):
				return null
	return candidate

func backend_summary() -> Dictionary:
	var backend_details := {}
	if backend != null and backend.has_method("backend_summary"):
		var value = backend.call("backend_summary")
		if value is Dictionary:
			backend_details = value
	var service_async := can_process_native_section_jobs_async()
	return {
		"id": backend_id,
		"native": native_backend_available,
		"async": service_async,
		"serviceAsync": service_async,
		"backendAsync": native_backend_available and backend != null and backend.has_method("request_chunk_assets"),
		"blockingGdscriptFallback": allow_blocking_gdscript_fallback,
		"normalQueuedWorkDeferredWithoutNative": not native_backend_available and not allow_blocking_gdscript_fallback,
		"pendingJobs": pending_job_count(),
		"completedJobs": completed_jobs.size(),
		"workerActive": async_worker_active,
		"payloadActive": not async_payload_job.is_empty(),
		"retiredPayloadBacklog": retired_payload_backlog(),
		"retiredPayloadLimit": RETIRED_PAYLOAD_JOB_LIMIT,
		"retiredPayloadCleanupActive": retired_payload_cleanup_thread != null,
		"retiredPayloadCleanupCount": retired_payload_cleanup_count,
		"retiredPayloadCleanupStartFailures": retired_payload_cleanup_start_failures,
		"backendDetails": backend_details
	}

func payload_progress_summary() -> Dictionary:
	var terrain_state: Dictionary = async_payload_job.get("terrainState", {}) if async_payload_job.get("terrainState", {}) is Dictionary else {}
	var fluid_state: Dictionary = async_payload_job.get("fluidState", {}) if async_payload_job.get("fluidState", {}) is Dictionary else {}
	var payload_size: Vector3i = fluid_state.get("payloadSize", Vector3i.ZERO)
	return {
		"active": not async_payload_job.is_empty(),
		"key": async_payload_job.get("key", Vector2i(999999, 999999)),
		"terrainComplete": not (async_payload_job.get("terrainPayload", {}) as Dictionary).is_empty() if async_payload_job.get("terrainPayload", {}) is Dictionary else false,
		"terrainCellsProcessed": int(terrain_state.get("cellsProcessed", 0)),
		"fluidComplete": bool(fluid_state.get("complete", false)),
		"fluidCellsProcessed": int(fluid_state.get("cellsProcessed", 0)),
		"fluidExpectedCells": payload_size.x * payload_size.y * payload_size.z,
		"fluidPayloadSize": payload_size,
		"workerActive": async_worker_active,
		"workerKey": async_worker_key,
		"workerElapsedMs": elapsed_ms(async_worker_started_usec) if async_worker_active and async_worker_started_usec > 0 else 0.0
	}

func can_process_native_section_jobs_async() -> bool:
	return native_backend_available \
		and backend != null \
		and backend.has_method("build_chunk_surface_data_from_sections") \
		and backend.has_method("build_chunk_fluid_surface_data_from_sections")

func request_chunk_assets(cx: int, cz: int, signature := "", include_collision := true, priority := 0, fluid_only := false) -> Dictionary:
	var key := Vector2i(cx, cz)
	var signature_text := String(signature)
	if completed_jobs.has(key):
		var completed: Dictionary = completed_jobs[key]
		if signature_text == "" or String(completed.get("terrainSignature", "")) == signature_text:
			if include_collision and not (completed.get("shape") is Shape3D):
				completed_jobs.erase(key)
			else:
				return {
					"status": "ready",
					"key": key,
					"signature": completed.get("terrainSignature", "")
				}
		else:
			completed_jobs.erase(key)
	if pending_jobs.has(key):
		var existing: Dictionary = pending_jobs[key]
		if signature_text == "" or String(existing.get("terrainSignature", "")) == signature_text:
			if not fluid_only and bool(existing.get("fluidOnly", false)):
				existing["fluidOnly"] = false
			if include_collision and not bool(existing.get("includeCollision", true)):
				existing["includeCollision"] = true
				existing["priority"] = maxi(int(existing.get("priority", 0)), int(priority))
				pending_jobs[key] = existing
			return {
				"status": "pending",
				"key": key,
				"signature": existing.get("terrainSignature", "")
			}
	job_sequence += 1
	pending_jobs[key] = {
		"key": key,
		"terrainSignature": signature_text,
		"includeCollision": include_collision,
		"fluidOnly": fluid_only,
		"priority": int(priority),
		"sequence": job_sequence
	}
	return {
		"status": "queued",
		"key": key,
		"signature": signature_text
	}

func invalidate_chunk(cx: int, cz: int) -> void:
	var key := Vector2i(cx, cz)
	pending_jobs.erase(key)
	completed_jobs.erase(key)
	if async_worker_active and async_worker_key == key:
		async_worker_cancelled = true
	if not async_payload_job.is_empty() and async_payload_job.get("key", Vector2i(999999, 999999)) == key:
		async_payload_job = {}
	if not async_finalize_job.is_empty() and async_finalize_job.get("key", Vector2i(999999, 999999)) == key:
		async_finalize_job = {}

func clear_jobs(blocking := true) -> void:
	if async_worker_active and async_worker_task_id >= 0:
		async_worker_cancelled = true
		if blocking:
			WorkerThreadPool.wait_for_task_completion(async_worker_task_id)
			clear_async_worker_result()
		else:
			retired_worker_tasks.append(async_worker_task_id)
	async_worker_task_id = -1
	async_worker_active = false
	async_worker_key = Vector2i(999999, 999999)
	async_worker_signature = ""
	async_worker_cancelled = false
	async_worker_done = false
	async_worker_started_usec = 0
	async_worker_payload = {}
	async_payload_job = {}
	async_finalize_job = {}
	pending_jobs.clear()
	completed_jobs.clear()
	if blocking:
		advance_retired_payload_cleanup(true)
		retired_payload_jobs.clear()
	else:
		advance_retired_payload_cleanup(false)
	job_sequence = 0
	collect_retired_worker_tasks(blocking)

func retired_payload_backlog() -> int:
	return retired_payload_jobs.size() + (1 if retired_payload_cleanup_thread != null else 0)

func advance_retired_payload_cleanup(blocking := false) -> void:
	if retired_payload_cleanup_thread != null:
		if not blocking and not worker_thread_finished(retired_payload_cleanup_thread):
			return
		retired_payload_cleanup_thread.wait_to_finish()
		retired_payload_cleanup_thread = null
		retired_payload_cleanup_count += 1
	while retired_payload_cleanup_thread == null and not retired_payload_jobs.is_empty():
		var retired_job = retired_payload_jobs.pop_front()
		if not (retired_job is Dictionary):
			continue
		var cleanup_thread := Thread.new()
		var err := cleanup_thread.start(
			Callable(self, "_thread_release_retired_payload_job").bind(retired_job),
			Thread.PRIORITY_LOW
		)
		if err != OK:
			retired_payload_cleanup_start_failures += 1
			retired_payload_jobs.push_front(retired_job)
			return
		retired_payload_cleanup_thread = cleanup_thread
		if not blocking:
			return
		retired_payload_cleanup_thread.wait_to_finish()
		retired_payload_cleanup_thread = null
		retired_payload_cleanup_count += 1

func _thread_release_retired_payload_job(retired_job: Dictionary) -> void:
	retired_job.clear()

func clear_async_worker_result() -> void:
	async_worker_result_mutex.lock()
	async_worker_result = {}
	async_worker_done = false
	async_worker_result_mutex.unlock()

func take_async_worker_result() -> Dictionary:
	async_worker_result_mutex.lock()
	var value: Dictionary = async_worker_result
	async_worker_result = {}
	async_worker_done = false
	async_worker_result_mutex.unlock()
	return value

func collect_retired_worker_tasks(blocking := false) -> int:
	var collected := 0
	for index in range(retired_worker_tasks.size() - 1, -1, -1):
		var task_id := int(retired_worker_tasks[index])
		if task_id < 0:
			retired_worker_tasks.remove_at(index)
			continue
		if not blocking and not WorkerThreadPool.is_task_completed(task_id):
			continue
		WorkerThreadPool.wait_for_task_completion(task_id)
		clear_async_worker_result()
		retired_worker_tasks.remove_at(index)
		collected += 1
	return collected

func shutdown_pending_work_count() -> int:
	var active_worker_count := 1 if async_worker_active and async_worker_task_id >= 0 else 0
	var payload_cleanup_count := 1 if retired_payload_cleanup_thread != null else 0
	return active_worker_count + retired_worker_tasks.size() + retired_payload_jobs.size() + payload_cleanup_count

func worker_thread_finished(thread: Thread) -> bool:
	if thread == null:
		return true
	if thread.has_method("is_alive"):
		return not bool(thread.call("is_alive"))
	return not thread.is_started()

func completed_chunk_keys() -> Array[Vector2i]:
	var keys: Array[Vector2i] = []
	for key_value in completed_jobs.keys():
		keys.append(key_value)
	return keys

func take_completed_chunk_assets(cx: int, cz: int, signature := "") -> Dictionary:
	var key := Vector2i(cx, cz)
	if not completed_jobs.has(key):
		return {}
	var assets: Dictionary = completed_jobs[key]
	var signature_text := String(signature)
	if signature_text != "" and String(assets.get("terrainSignature", "")) != signature_text:
		completed_jobs.erase(key)
		return {}
	completed_jobs.erase(key)
	return assets

func pending_job_count() -> int:
	var active_count := 0
	if async_worker_active:
		active_count += 1
	if not async_payload_job.is_empty():
		active_count += 1
	if not async_finalize_job.is_empty():
		active_count += 1
	return pending_jobs.size() + active_count

func completed_job_count() -> int:
	return completed_jobs.size()

func process_jobs(
	max_jobs := 1,
	budget_ms := 3.0,
	center := Vector2i(999999, 999999),
	payload_max_cells := ASYNC_PAYLOAD_PREP_MAX_CELLS_PER_FRAME,
	publication_deadline_usec := 0,
	total_payload_max_cells := 0
) -> Dictionary:
	var call_started_usec := Time.get_ticks_usec()
	var collect_started_usec := Time.get_ticks_usec()
	collect_retired_worker_tasks(false)
	advance_retired_payload_cleanup(false)
	var completed_summary := collect_async_worker_result()
	var collect_ms := elapsed_ms(collect_started_usec)
	var processed := int(completed_summary.get("processed", 0))
	var dropped := int(completed_summary.get("dropped", 0))
	var deferred_without_native := 0
	var prepared_sections := int(completed_summary.get("preparedSections", 0))
	var started_usec := Time.get_ticks_usec()
	if not native_backend_available and not allow_blocking_gdscript_fallback:
		return {
			"processed": 0,
			"dropped": 0,
			"deferredWithoutNative": pending_jobs.size(),
			"preparedSections": 0,
			"pendingJobs": pending_job_count(),
			"completedJobs": completed_jobs.size(),
			"collectMs": collect_ms,
			"workerJoinMs": float(completed_summary.get("workerJoinMs", 0.0)),
			"workerStartMs": 0.0,
			"assetFinalizeMs": float(completed_summary.get("assetFinalizeMs", 0.0)),
			"terrainMeshBuildMs": float(completed_summary.get("terrainMeshBuildMs", 0.0)),
			"fluidMeshBuildMs": float(completed_summary.get("fluidMeshBuildMs", 0.0)),
			"collisionBuildMs": float(completed_summary.get("collisionBuildMs", 0.0)),
			"processPhase": "no_native_backend",
			"elapsedMs": elapsed_ms(started_usec)
		}
	if processed > 0 or dropped > 0:
		return {
			"processed": processed,
			"dropped": dropped,
			"deferredWithoutNative": deferred_without_native,
			"preparedSections": prepared_sections,
			"pendingJobs": pending_job_count(),
			"completedJobs": completed_jobs.size(),
			"collectMs": collect_ms,
			"workerJoinMs": float(completed_summary.get("workerJoinMs", 0.0)),
			"workerStartMs": 0.0,
			"assetFinalizeMs": float(completed_summary.get("assetFinalizeMs", 0.0)),
			"terrainMeshBuildMs": float(completed_summary.get("terrainMeshBuildMs", 0.0)),
			"fluidMeshBuildMs": float(completed_summary.get("fluidMeshBuildMs", 0.0)),
			"collisionBuildMs": float(completed_summary.get("collisionBuildMs", 0.0)),
			"dropReason": String(completed_summary.get("dropReason", "")),
			"processPhase": "collect_completed",
			"elapsedMs": float(completed_summary.get("elapsedMs", elapsed_ms(started_usec)))
		}
	if not async_finalize_job.is_empty():
		return {
			"processed": 0,
			"dropped": 0,
			"deferredWithoutNative": deferred_without_native,
			"preparedSections": prepared_sections,
			"pendingJobs": pending_job_count(),
			"completedJobs": completed_jobs.size(),
			"collectMs": collect_ms,
			"workerJoinMs": float(completed_summary.get("workerJoinMs", 0.0)),
			"workerStartMs": 0.0,
			"assetFinalizeMs": float(completed_summary.get("assetFinalizeMs", 0.0)),
			"terrainMeshBuildMs": 0.0,
			"fluidMeshBuildMs": float(completed_summary.get("fluidMeshBuildMs", 0.0)),
			"collisionBuildMs": 0.0,
			"processPhase": "fluid_finalize",
			"elapsedMs": elapsed_ms(started_usec)
		}
	if async_worker_active:
		return {
			"processed": 0,
			"dropped": 0,
			"deferredWithoutNative": deferred_without_native,
			"preparedSections": 0,
			"pendingJobs": pending_job_count(),
			"completedJobs": completed_jobs.size(),
			"collectMs": collect_ms,
			"workerJoinMs": 0.0,
			"workerStartMs": 0.0,
			"assetFinalizeMs": 0.0,
			"terrainMeshBuildMs": 0.0,
			"fluidMeshBuildMs": 0.0,
			"collisionBuildMs": 0.0,
			"processPhase": "worker_active",
			"elapsedMs": elapsed_ms(started_usec)
		}
	if can_process_native_section_jobs_async():
		var payload_deadline_usec := int(publication_deadline_usec)
		if payload_deadline_usec > 0:
			payload_deadline_usec = mini(
				payload_deadline_usec,
				call_started_usec + maxi(100, roundi(maxf(0.1, float(budget_ms)) * 1000.0))
			)
		var started := {}
		# Collection and completed-worker hydration happen before this point. Do
		# not enter the payload state machine when they consumed the gameplay
		# slice; pending and active jobs remain owned by their current queues.
		if payload_stage_budget_ms(budget_ms, payload_deadline_usec) > 0.0:
			started = start_next_async_native_job(
				center,
				budget_ms,
				payload_max_cells,
				payload_deadline_usec,
				total_payload_max_cells
			)
		return {
			"processed": int(started.get("processed", 0)),
			"dropped": int(started.get("dropped", 0)),
			"deferredWithoutNative": deferred_without_native,
			"preparedSections": int(started.get("preparedSections", 0)),
			"payloadCells": int(started.get("payloadCells", 0)),
			"pendingJobs": pending_job_count(),
			"completedJobs": completed_jobs.size(),
			"payloadPrepMs": float(started.get("payloadPrepMs", 0.0)),
			"payloadBeginMs": float(started.get("payloadBeginMs", 0.0)),
			"boundsStateBeginMs": float(started.get("boundsStateBeginMs", 0.0)),
			"boundsPrepMs": float(started.get("boundsPrepMs", 0.0)),
			"boundsColumns": int(started.get("boundsColumns", 0)),
			"signatureCheckMs": float(started.get("signatureCheckMs", 0.0)),
			"payloadSelectMs": float(started.get("payloadSelectMs", 0.0)),
			"payloadSignatureMs": float(started.get("payloadSignatureMs", 0.0)),
			"terrainPayloadStateBeginMs": float(started.get("terrainPayloadStateBeginMs", 0.0)),
			"fluidPayloadStateBeginMs": float(started.get("fluidPayloadStateBeginMs", 0.0)),
			"terrainPayloadPublishMs": float(started.get("terrainPayloadPublishMs", 0.0)),
			"fluidPayloadPublishMs": float(started.get("fluidPayloadPublishMs", 0.0)),
			"payloadHandoffPrepMs": float(started.get("payloadHandoffPrepMs", 0.0)),
			"workerHandoffMs": float(started.get("workerHandoffMs", 0.0)),
			"retiredPayloadCleanupMs": float(started.get("retiredPayloadCleanupMs", 0.0)),
			"retiredWorkerCollectMs": float(started.get("retiredWorkerCollectMs", 0.0)),
			"fluidPayloadPrepMs": float(started.get("fluidPayloadPrepMs", 0.0)),
			"fluidPayloadCells": int(started.get("fluidPayloadCells", 0)),
			"fluidPreparedSections": int(started.get("fluidPreparedSections", 0)),
			"dropReason": String(started.get("dropReason", "")),
			"requestedSignature": String(started.get("requestedSignature", "")),
			"currentSignature": String(started.get("currentSignature", "")),
			"collectMs": collect_ms,
			"workerJoinMs": 0.0,
			"workerStartMs": float(started.get("workerStartMs", 0.0)),
			"assetFinalizeMs": 0.0,
			"terrainMeshBuildMs": 0.0,
			"fluidMeshBuildMs": 0.0,
			"collisionBuildMs": 0.0,
			"processPhase": "payload_or_worker_start",
			"elapsedMs": elapsed_ms(started_usec)
		}
	while processed < maxi(1, int(max_jobs)) and not pending_jobs.is_empty():
		if processed > 0 and elapsed_ms(started_usec) >= float(budget_ms):
			break
		var key := nearest_pending_job_key(center)
		if key == Vector2i(999999, 999999):
			break
		var job: Dictionary = pending_jobs[key]
		pending_jobs.erase(key)
		var requested_signature := String(job.get("terrainSignature", ""))
		var current_signature := current_signature_for_chunk(key)
		if requested_signature != "" and current_signature != "" and requested_signature != current_signature:
			dropped += 1
			continue
		trace("process_job:%d,%d:start" % [key.x, key.y])
		var assets := build_chunk_asset_bundle(key.x, key.y, requested_signature, bool(job.get("includeCollision", true)))
		trace("process_job:%d,%d:done" % [key.x, key.y])
		prepared_sections += int(assets.get("terrainPreparedSections", 0))
		completed_jobs[key] = assets
		processed += 1
	return {
		"processed": processed,
		"dropped": dropped,
		"deferredWithoutNative": deferred_without_native,
		"preparedSections": prepared_sections,
		"pendingJobs": pending_job_count(),
		"completedJobs": completed_jobs.size(),
		"collectMs": collect_ms,
		"workerJoinMs": float(completed_summary.get("workerJoinMs", 0.0)),
		"workerStartMs": 0.0,
		"assetFinalizeMs": float(completed_summary.get("assetFinalizeMs", 0.0)),
		"terrainMeshBuildMs": float(completed_summary.get("terrainMeshBuildMs", 0.0)),
		"fluidMeshBuildMs": float(completed_summary.get("fluidMeshBuildMs", 0.0)),
		"collisionBuildMs": float(completed_summary.get("collisionBuildMs", 0.0)),
		"processPhase": "blocking_fallback",
		"elapsedMs": elapsed_ms(started_usec)
	}

func start_next_async_native_job(
	center: Vector2i,
	budget_ms := 2.0,
	payload_max_cells := ASYNC_PAYLOAD_PREP_MAX_CELLS_PER_FRAME,
	publication_deadline_usec := 0,
	total_payload_max_cells := 0
) -> Dictionary:
	var result := {
		"started": false,
		"dropped": 0,
		"preparedSections": 0,
		"payloadPrepMs": 0.0,
		"payloadBeginMs": 0.0,
		"signatureCheckMs": 0.0,
		"payloadSelectMs": 0.0,
		"payloadSignatureMs": 0.0,
		"boundsStateBeginMs": 0.0,
		"boundsPrepMs": 0.0,
		"boundsColumns": 0,
		"terrainPayloadStateBeginMs": 0.0,
		"fluidPayloadStateBeginMs": 0.0,
		"terrainPayloadPublishMs": 0.0,
		"fluidPayloadPublishMs": 0.0,
		"payloadHandoffPrepMs": 0.0,
		"workerHandoffMs": 0.0,
		"payloadCells": 0,
		"workerStartMs": 0.0,
		"retiredPayloadCleanupMs": 0.0,
		"retiredWorkerCollectMs": 0.0,
		"dropReason": "",
		"requestedSignature": "",
		"currentSignature": ""
	}
	# process_jobs normally performs the first admission check, but this method
	# remains callable by focused services. Guard before its duplicated cleanup
	# so no later stage starts from an already exhausted gameplay slice.
	if payload_stage_budget_ms(budget_ms, publication_deadline_usec) <= 0.0:
		return result
	var retired_payload_cleanup_started_usec := Time.get_ticks_usec()
	advance_retired_payload_cleanup(false)
	result["retiredPayloadCleanupMs"] = elapsed_ms(retired_payload_cleanup_started_usec)
	if retired_payload_backlog() >= RETIRED_PAYLOAD_JOB_LIMIT:
		result["dropReason"] = "retired_payload_cleanup_backpressure"
		return result
	var retired_worker_collect_started_usec := Time.get_ticks_usec()
	collect_retired_worker_tasks(false)
	result["retiredWorkerCollectMs"] = elapsed_ms(retired_worker_collect_started_usec)
	if not retired_worker_tasks.is_empty():
		return result
	if async_payload_job.is_empty():
		# Cleanup may have consumed the remaining slice. Keep the request in
		# pending_jobs rather than selecting/promoting it without time to advance.
		if payload_stage_budget_ms(budget_ms, publication_deadline_usec) <= 0.0:
			return result
		var payload_begin_started_usec := Time.get_ticks_usec()
		var began := begin_next_async_payload_job(center)
		result["payloadBeginMs"] = elapsed_ms(payload_begin_started_usec)
		result["payloadSelectMs"] = float(began.get("selectMs", 0.0))
		result["payloadSignatureMs"] = float(began.get("signatureMs", 0.0))
		result["boundsStateBeginMs"] = float(began.get("boundsStateMs", 0.0))
		result["terrainPayloadStateBeginMs"] = float(began.get("terrainStateMs", 0.0))
		result["fluidPayloadStateBeginMs"] = float(began.get("fluidStateMs", 0.0))
		result["dropped"] = int(began.get("dropped", 0))
		if result["dropped"] > 0 or async_payload_job.is_empty():
			return result
	var key: Vector2i = async_payload_job.get("key", Vector2i(999999, 999999))
	var requested_signature := String(async_payload_job.get("terrainSignature", ""))
	var signature_started_usec := Time.get_ticks_usec()
	var current_signature := current_signature_for_chunk(key)
	result["signatureCheckMs"] = elapsed_ms(signature_started_usec)
	result["requestedSignature"] = requested_signature
	result["currentSignature"] = current_signature
	if requested_signature != "" and current_signature != "" and requested_signature != current_signature:
		async_payload_job = {}
		result["dropped"] = 1
		result["dropReason"] = "terrain_signature_changed_during_payload"
		return result
	var world_generation = main.get("world_generation_system") if main != null else null
	if world_generation == null \
		or not world_generation.has_method("advance_section_payload_state") \
		or not world_generation.has_method("advance_exact_fluid_payload_state"):
		async_payload_job = {}
		result["dropped"] = 1
		return result
	var fluid_only := bool(async_payload_job.get("fluidOnly", false))
	var terrain_payload_cell_cap := maxi(1, int(payload_max_cells))
	var remaining_payload_cells := maxi(0, int(total_payload_max_cells))
	var terrain_state: Dictionary = async_payload_job.get("terrainState", {}) if async_payload_job.get("terrainState", {}) is Dictionary else {}
	if terrain_state.is_empty():
		var bounds_state: Dictionary = async_payload_job.get("boundsState", {}) if async_payload_job.get("boundsState", {}) is Dictionary else {}
		if bounds_state.is_empty() or not world_generation.has_method("advance_terrain_meshing_bounds_state"):
			async_payload_job = {}
			result["dropped"] = 1
			result["dropReason"] = "terrain_bounds_state_unavailable"
			return result
		var bounds_budget_ms := payload_stage_budget_ms(budget_ms, publication_deadline_usec)
		if bounds_budget_ms <= 0.0:
			return result
		var bounds_advanced_value = world_generation.call(
			"advance_terrain_meshing_bounds_state",
			bounds_state,
			bounds_budget_ms,
			terrain_payload_cell_cap
		)
		var bounds_advanced: Dictionary = bounds_advanced_value if bounds_advanced_value is Dictionary else {}
		async_payload_job["boundsState"] = bounds_advanced.get("state", bounds_state)
		result["boundsPrepMs"] = float(bounds_advanced.get("elapsedMs", 0.0))
		result["boundsColumns"] = int(bounds_advanced.get("columnsProcessed", 0))
		if not bool(bounds_advanced.get("complete", false)):
			return result
		# A final bounds unit may cooperatively cross the deadline. Persist its
		# completed cursor, but do not launch terrain/exact-fluid state creation
		# until a later admitted slice.
		if payload_stage_budget_ms(budget_ms, publication_deadline_usec) <= 0.0:
			return result
		var bounds: Dictionary = bounds_advanced.get("bounds", {}) if bounds_advanced.get("bounds", {}) is Dictionary else {}
		var terrain_state_started_usec := Time.get_ticks_usec()
		terrain_state = begin_section_payload_for_chunk(key.x, key.y, bounds, fluid_only)
		result["terrainPayloadStateBeginMs"] = elapsed_ms(terrain_state_started_usec)
		if terrain_state.is_empty():
			async_payload_job = {}
			result["dropped"] = 1
			result["dropReason"] = "terrain_bounds_invalid"
			return result
		async_payload_job["terrainState"] = terrain_state
		var fluid_state_started_usec := Time.get_ticks_usec()
		var initialized_fluid_state := begin_exact_fluid_payload_for_chunk(terrain_state)
		result["fluidPayloadStateBeginMs"] = elapsed_ms(fluid_state_started_usec)
		if initialized_fluid_state.is_empty():
			async_payload_job = {}
			result["dropped"] = 1
			result["dropReason"] = "exact_fluid_state_invalid"
			return result
		async_payload_job["fluidState"] = initialized_fluid_state
		# Bounds completion can establish two payload state machines in the same
		# frame.  Publish only those tiny states here; their first bounded sampling
		# step starts on the next frame so a stream transition never combines setup
		# with terrain and exact-fluid work.
		return result
	var payload: Dictionary = async_payload_job.get("terrainPayload", {}) if async_payload_job.get("terrainPayload", {}) is Dictionary else {}
	if fluid_only and payload.is_empty():
		payload = {
			"sections": [],
			"chunkX": key.x,
			"chunkZ": key.y,
			"chunkSize": chunk_size(),
			"terrainStepCells": 1,
			"stepCells": 1
		}
		async_payload_job["terrainPayload"] = payload
	elif payload.is_empty():
		terrain_state = async_payload_job.get("terrainState", {}) if async_payload_job.get("terrainState", {}) is Dictionary else {}
		var terrain_budget_ms := payload_stage_budget_ms(budget_ms, publication_deadline_usec)
		if terrain_budget_ms <= 0.0:
			return result
		var terrain_cell_cap := terrain_payload_cell_cap
		if int(total_payload_max_cells) > 0:
			if remaining_payload_cells <= 0:
				return result
			terrain_cell_cap = mini(terrain_cell_cap, remaining_payload_cells)
		var terrain_advanced_value = world_generation.call(
			"advance_section_payload_state",
			terrain_state,
			terrain_budget_ms,
			terrain_cell_cap
		)
		var terrain_advanced: Dictionary = terrain_advanced_value if terrain_advanced_value is Dictionary else {}
		async_payload_job["terrainState"] = terrain_advanced.get("state", terrain_state)
		result["payloadPrepMs"] = float(terrain_advanced.get("elapsedMs", 0.0))
		result["payloadCells"] = int(terrain_advanced.get("cellsProcessed", 0))
		if int(total_payload_max_cells) > 0:
			remaining_payload_cells = maxi(0, remaining_payload_cells - int(result["payloadCells"]))
		result["preparedSections"] = int(terrain_advanced.get("preparedSections", 0))
		if not bool(terrain_advanced.get("complete", false)):
			return result
		payload = terrain_advanced.get("payload", {}) if terrain_advanced.get("payload", {}) is Dictionary else {}
		if payload.is_empty():
			async_payload_job = {}
			result["dropped"] = 1
			return result
		var terrain_payload_publish_started_usec := Time.get_ticks_usec()
		async_payload_job["terrainPayload"] = payload
		result["terrainPayloadPublishMs"] = elapsed_ms(terrain_payload_publish_started_usec)
	var fluid_state: Dictionary = async_payload_job.get("fluidState", {}) if async_payload_job.get("fluidState", {}) is Dictionary else {}
	var fluid_budget_ms := maxf(0.1, float(budget_ms) - float(result.get("payloadPrepMs", 0.0)))
	if int(publication_deadline_usec) > 0:
		fluid_budget_ms = payload_stage_budget_ms(budget_ms, publication_deadline_usec)
		if fluid_budget_ms <= 0.0:
			return result
	var fluid_cell_cap := ASYNC_EXACT_FLUID_PAYLOAD_MAX_CELLS_PER_FRAME
	if int(total_payload_max_cells) > 0:
		if remaining_payload_cells <= 0:
			return result
		fluid_cell_cap = mini(fluid_cell_cap, remaining_payload_cells)
	var fluid_advanced_value = world_generation.call(
		"advance_exact_fluid_payload_state",
		fluid_state,
		fluid_budget_ms,
		fluid_cell_cap
	)
	var fluid_advanced: Dictionary = fluid_advanced_value if fluid_advanced_value is Dictionary else {}
	async_payload_job["fluidState"] = fluid_advanced.get("state", fluid_state)
	result["fluidPayloadPrepMs"] = float(fluid_advanced.get("elapsedMs", 0.0))
	result["fluidPayloadCells"] = int(fluid_advanced.get("cellsProcessed", 0))
	result["fluidPreparedSections"] = int(fluid_advanced.get("preparedSections", 0))
	result["payloadPrepMs"] = float(result.get("payloadPrepMs", 0.0)) + float(fluid_advanced.get("elapsedMs", 0.0))
	result["payloadCells"] = int(result.get("payloadCells", 0)) + int(fluid_advanced.get("cellsProcessed", 0))
	result["preparedSections"] = maxi(int(result.get("preparedSections", 0)), int(fluid_advanced.get("preparedSections", 0)))
	if bool(fluid_advanced.get("cancelled", false)) or bool(fluid_advanced.get("stale", false)):
		async_payload_job = {}
		result["dropped"] = 1
		result["dropReason"] = "exact_fluid_payload_cancelled" if bool(fluid_advanced.get("cancelled", false)) else "exact_fluid_payload_stale"
		return result
	if not bool(fluid_advanced.get("complete", false)):
		return result
	var fluid_payload: Dictionary = fluid_advanced.get("payload", {}) if fluid_advanced.get("payload", {}) is Dictionary else {}
	if fluid_payload.is_empty():
		async_payload_job = {}
		result["dropped"] = 1
		result["dropReason"] = "exact_fluid_payload_empty"
		return result
	if payload_stage_budget_ms(budget_ms, publication_deadline_usec) <= 0.0:
		return result
	var fluid_payload_publish_started_usec := Time.get_ticks_usec()
	payload["fluidPayload"] = fluid_payload
	payload["hasFluid"] = bool(fluid_payload.get("hasFluid", false))
	payload["terrainStepCells"] = maxi(1, int(payload.get("terrainStepCells", payload.get("stepCells", 1))))
	result["fluidPayloadPublishMs"] = elapsed_ms(fluid_payload_publish_started_usec)
	var include_collision := bool(async_payload_job.get("includeCollision", true))
	# Keep the completed incremental state alive until the native worker owns it. Its
	# dense scratch channels can be large, and releasing them here would synchronously
	# retire the allocation graph on the gameplay frame.
	var handoff_prepare_started_usec := Time.get_ticks_usec()
	var payload_job_to_retire := async_payload_job
	result["payloadHandoffPrepMs"] = elapsed_ms(handoff_prepare_started_usec)
	if payload_stage_budget_ms(budget_ms, publication_deadline_usec) <= 0.0:
		return result
	async_payload_job = {}
	var worker_handoff_started_usec := Time.get_ticks_usec()
	result = start_async_worker_from_payload(key, requested_signature, payload, include_collision, fluid_only, result, payload_job_to_retire)
	result["workerHandoffMs"] = elapsed_ms(worker_handoff_started_usec)
	return result

func payload_stage_budget_ms(requested_budget_ms: float, publication_deadline_usec: int) -> float:
	if publication_deadline_usec <= 0:
		return maxf(0.1, requested_budget_ms)
	var remaining_usec := publication_deadline_usec - Time.get_ticks_usec()
	if remaining_usec < 100:
		return 0.0
	return minf(maxf(0.1, requested_budget_ms), float(remaining_usec) / 1000.0)

func begin_next_async_payload_job(center: Vector2i) -> Dictionary:
	var result := {
		"began": false,
		"dropped": 0,
		"selectMs": 0.0,
		"signatureMs": 0.0,
		"boundsStateMs": 0.0,
		"terrainStateMs": 0.0,
		"fluidStateMs": 0.0
	}
	if pending_jobs.is_empty():
		return result
	var select_started_usec := Time.get_ticks_usec()
	var key := nearest_pending_job_key(center)
	result["selectMs"] = elapsed_ms(select_started_usec)
	if key == Vector2i(999999, 999999):
		return result
	var job: Dictionary = pending_jobs[key]
	pending_jobs.erase(key)
	var requested_signature := String(job.get("terrainSignature", ""))
	var signature_started_usec := Time.get_ticks_usec()
	var current_signature := current_signature_for_chunk(key)
	result["signatureMs"] = elapsed_ms(signature_started_usec)
	if requested_signature != "" and current_signature != "" and requested_signature != current_signature:
		result["dropped"] = 1
		return result
	var world_generation = main.get("world_generation_system") if main != null else null
	if world_generation == null:
		result["dropped"] = 1
		return result
	var bounds_state_started_usec := Time.get_ticks_usec()
	var bounds_state := {}
	if world_generation.has_method("begin_terrain_meshing_bounds_state"):
		var bounds_state_value = world_generation.call("begin_terrain_meshing_bounds_state", key.x * chunk_size(), key.y * chunk_size(), chunk_size())
		if bounds_state_value is Dictionary:
			bounds_state = bounds_state_value
	result["boundsStateMs"] = elapsed_ms(bounds_state_started_usec)
	if bounds_state.is_empty():
		result["dropped"] = 1
		return result
	async_payload_job = {
		"key": key,
		"terrainSignature": requested_signature,
		"includeCollision": bool(job.get("includeCollision", true)),
		"fluidOnly": bool(job.get("fluidOnly", false)),
		"boundsState": bounds_state,
		"terrainState": {},
		"fluidState": {},
		"terrainPayload": {}
	}
	result["began"] = true
	return result

func begin_section_payload_for_chunk(cx: int, cz: int, bounds: Dictionary = {}, fluid_only := false) -> Dictionary:
	if main == null or main.get("world_generation_system") == null:
		return {}
	var world_generation = main.get("world_generation_system")
	if not world_generation.has_method("begin_section_payload_for_meshing_chunk"):
		return {}
	var size := chunk_size()
	var start_x := cx * size
	var start_z := cz * size
	var resolved_bounds := bounds if not bounds.is_empty() else terrain_meshing_bounds_for_chunk(cx, cz)
	var min_y := int(resolved_bounds.get("minY", 0))
	var max_y := int(resolved_bounds.get("maxY", 0))
	if max_y <= min_y:
		return {}
	var step := 1
	# Native terrain owns the terrain mesh. Exact-fluid jobs have no terrain
	# LOD to choose and must not scan the diagnostic terrain mesher's town edges.
	if not fluid_only and main.has_method("underground_volume_mesh_step_for_chunk"):
		step = maxi(1, int(main.call("underground_volume_mesh_step_for_chunk", start_x, start_z)))
	return world_generation.call("begin_section_payload_for_meshing_chunk", start_x, start_z, size, min_y, max_y, step)

func terrain_meshing_bounds_for_chunk(cx: int, cz: int) -> Dictionary:
	var size := chunk_size()
	var start_x := cx * size
	var start_z := cz * size
	var world_generation = main.get("world_generation_system") if main != null else null
	if world_generation != null and world_generation.has_method("terrain_meshing_y_bounds_for_chunk"):
		var bounds_value = world_generation.call("terrain_meshing_y_bounds_for_chunk", start_x, start_z, size)
		if bounds_value is Dictionary:
			return bounds_value
	if main != null and main.has_method("chunk_volume_y_bounds"):
		var legacy_bounds_value = main.call("chunk_volume_y_bounds", start_x, start_z)
		if legacy_bounds_value is Dictionary:
			return legacy_bounds_value
	return {
		"minY": int(world_generation.call("world_bottom_cell_y")) if world_generation != null and world_generation.has_method("world_bottom_cell_y") else -64,
		"maxY": int(world_generation.call("world_top_cell_y")) if world_generation != null and world_generation.has_method("world_top_cell_y") else 96
	}

func begin_exact_fluid_payload_for_chunk(terrain_state: Dictionary) -> Dictionary:
	if main == null or main.get("world_generation_system") == null:
		return {}
	var world_generation = main.get("world_generation_system")
	if not world_generation.has_method("begin_exact_fluid_payload_for_meshing_chunk"):
		return {}
	return world_generation.call(
		"begin_exact_fluid_payload_for_meshing_chunk",
		int(terrain_state.get("startX", 0)),
		int(terrain_state.get("startZ", 0)),
		int(terrain_state.get("chunkSize", chunk_size())),
		int(terrain_state.get("minY", 0)),
		int(terrain_state.get("maxY", 0)),
		int(terrain_state.get("terrainStepCells", terrain_state.get("stepCells", 1)))
	)

func start_async_worker_from_payload(key: Vector2i, requested_signature: String, payload: Dictionary, include_collision: bool, fluid_only: bool, result: Dictionary, payload_job_to_retire: Dictionary = {}) -> Dictionary:
	async_worker_key = key
	async_worker_signature = requested_signature
	async_worker_cancelled = false
	async_worker_done = false
	async_worker_active = true
	async_worker_started_usec = Time.get_ticks_usec()
	async_worker_payload = payload
	clear_async_worker_result()
	var task_input := {
		"key": key,
		"signature": requested_signature,
		"includeCollision": include_collision,
		"fluidOnly": fluid_only,
		"payload": payload,
		"backend": backend,
		"payloadJobToRetire": payload_job_to_retire
	}
	var start_started_usec := Time.get_ticks_usec()
	async_worker_task_id = WorkerThreadPool.add_task(
		Callable(self, "_pool_build_native_chunk_assets").bind(task_input),
		false,
		"terrain_meshing"
	)
	result["workerStartMs"] = elapsed_ms(start_started_usec)
	if async_worker_task_id < 0:
		async_worker_active = false
		async_worker_key = Vector2i(999999, 999999)
		async_worker_signature = ""
		async_worker_done = false
		async_worker_started_usec = 0
		async_worker_payload = {}
		result["dropped"] = int(result.get("dropped", 0)) + 1
		return result
	result["started"] = true
	result["preparedSections"] = int((payload.get("sections", []) as Array).size()) if payload.get("sections", []) is Array else 0
	return result

func _pool_build_native_chunk_assets(task_input: Dictionary) -> void:
	var value := _thread_build_native_chunk_assets(
		task_input.get("key", Vector2i(999999, 999999)),
		String(task_input.get("signature", "")),
		bool(task_input.get("includeCollision", true)),
		bool(task_input.get("fluidOnly", false)),
		task_input.get("payload", {}) as Dictionary,
		task_input.get("backend"),
		task_input.get("payloadJobToRetire", {}) as Dictionary
	)
	async_worker_result_mutex.lock()
	async_worker_result = value if value is Dictionary else {}
	async_worker_done = true
	async_worker_result_mutex.unlock()

func complete_empty_fluid_only_job(key: Vector2i, requested_signature: String, result: Dictionary) -> Dictionary:
	var signature := requested_signature
	if signature == "":
		signature = current_signature_for_chunk(key)
	var mesh := ArrayMesh.new()
	mesh.set_meta("terrainMeshingQueued", true)
	mesh.set_meta("terrainMeshingBackend", backend_id)
	mesh.set_meta("terrainMeshingNative", true)
	mesh.set_meta("terrainMeshingSectionPayload", false)
	var fluid_mesh := ArrayMesh.new()
	fluid_mesh.set_meta("terrainMeshingQueued", true)
	fluid_mesh.set_meta("terrainMeshingBackend", backend_id)
	fluid_mesh.set_meta("terrainMeshingNative", true)
	fluid_mesh.set_meta("terrainFluidSectionPayload", true)
	fluid_mesh.set_meta("terrainFluidEmpty", true)
	fluid_mesh.set_meta("terrainSignature", signature)
	completed_jobs[key] = {
		"mesh": mesh,
		"shape": null,
		"fluidMesh": fluid_mesh,
		"terrainSignature": signature,
		"terrainMeshingBackend": backend_id,
		"terrainMeshingNative": true,
		"fluidOnly": true,
		"terrainPreparedSections": 0
	}
	result["processed"] = 1
	result["emptyFluidFastPath"] = true
	return result

func collect_async_worker_result() -> Dictionary:
	var summary := {
		"processed": 0,
		"dropped": 0,
		"preparedSections": 0,
		"workerJoinMs": 0.0,
		"assetFinalizeMs": 0.0,
		"terrainMeshBuildMs": 0.0,
		"fluidMeshBuildMs": 0.0,
		"collisionBuildMs": 0.0,
		"elapsedMs": 0.0,
		"dropReason": ""
	}
	if not async_finalize_job.is_empty():
		return advance_async_fluid_finalize()
	if not async_worker_active or async_worker_task_id < 0:
		return summary
	if async_worker_started_usec > 0 and elapsed_ms(async_worker_started_usec) < ASYNC_WORKER_MIN_COLLECT_DELAY_MS:
		return summary
	if not WorkerThreadPool.is_task_completed(async_worker_task_id):
		return summary
	var key := async_worker_key
	var signature := async_worker_signature
	var cancelled := async_worker_cancelled
	var join_started_usec := Time.get_ticks_usec()
	var wait_error := WorkerThreadPool.wait_for_task_completion(async_worker_task_id)
	summary["workerJoinMs"] = elapsed_ms(join_started_usec)
	var value: Dictionary = take_async_worker_result()
	async_worker_task_id = -1
	async_worker_active = false
	async_worker_key = Vector2i(999999, 999999)
	async_worker_signature = ""
	async_worker_cancelled = false
	async_worker_done = false
	async_worker_started_usec = 0
	async_worker_payload = {}
	if cancelled:
		summary["dropped"] = 1
		summary["dropReason"] = "worker_cancelled"
		return summary
	if wait_error != OK or value.is_empty():
		summary["dropped"] = 1
		summary["dropReason"] = "worker_result_invalid"
		return summary
	var result: Dictionary = value
	var retired_payload_job = result.get("retiredPayloadJob", {})
	if retired_payload_job is Dictionary and not (retired_payload_job as Dictionary).is_empty():
		# Retire large worker-bound Variant graphs on one low-priority cleanup thread.
		# Backpressure in start_next_async_native_job bounds this queue during traversal.
		retired_payload_jobs.append(retired_payload_job)
		result.erase("retiredPayloadJob")
		advance_retired_payload_cleanup(false)
	var worker_error := String(result.get("workerError", ""))
	if not worker_error.is_empty():
		summary["dropped"] = 1
		summary["dropReason"] = worker_error
		return summary
	summary["elapsedMs"] = float(result.get("elapsedMs", 0.0))
	summary["preparedSections"] = int(result.get("preparedSections", 0))
	summary["terrainMeshBuildMs"] = float(result.get("terrainMeshBuildMs", 0.0))
	summary["fluidMeshBuildMs"] = float(result.get("fluidMeshBuildMs", 0.0))
	summary["collisionBuildMs"] = float(result.get("collisionBuildMs", 0.0))
	var current_signature := current_signature_for_chunk(key)
	if signature != "" and current_signature != "" and signature != current_signature:
		summary["dropped"] = 1
		summary["dropReason"] = "stale_worker_signature"
		return summary
	var fluid_only := bool(result.get("fluidOnly", false))
	var terrain_surface_data: Dictionary = result.get("terrainSurfaceData", {}) if result.get("terrainSurfaceData", {}) is Dictionary else {}
	var fluid_surface_data: Dictionary = result.get("fluidSurfaceData", {}) if result.get("fluidSurfaceData", {}) is Dictionary else {}
	if fluid_only and not fluid_surface_data.is_empty():
		async_finalize_job = {
			"key": key,
			"terrainSignature": signature,
			"data": fluid_surface_data,
			"mesh": ArrayMesh.new(),
			"fluidKind": "water",
			"vertexOffset": 0,
			"surfaceOrder": PackedStringArray(),
			"preparedSections": int(result.get("preparedSections", 0)),
			"workerElapsedMs": float(result.get("elapsedMs", 0.0)),
			"fluidMeshBuildMs": float(result.get("fluidMeshBuildMs", 0.0))
		}
		var finalize_summary := advance_async_fluid_finalize()
		finalize_summary["workerJoinMs"] = summary["workerJoinMs"]
		finalize_summary["fluidMeshBuildMs"] = summary["fluidMeshBuildMs"]
		finalize_summary["elapsedMs"] = summary["elapsedMs"]
		return finalize_summary
	var mesh: Mesh = terrain_mesh_from_surface_data(terrain_surface_data) if not terrain_surface_data.is_empty() else null
	if fluid_only and mesh == null:
		mesh = ArrayMesh.new()
	if mesh == null:
		summary["dropped"] = 1
		summary["dropReason"] = "worker_mesh_missing"
		return summary
	var fluid_mesh: Mesh = fluid_mesh_from_surface_data(fluid_surface_data) if not fluid_surface_data.is_empty() else null
	if fluid_mesh == null:
		fluid_mesh = ArrayMesh.new()
	mesh.set_meta("terrainMeshingQueued", true)
	mesh.set_meta("terrainMeshingBackend", backend_id)
	mesh.set_meta("terrainMeshingNative", true)
	mesh.set_meta("terrainMeshingSectionPayload", not fluid_only)
	var finalize_started_usec := Time.get_ticks_usec()
	if not fluid_only:
		mesh = project_chunk_surface_normals(mesh, key.x, key.y)
		apply_terrain_material(mesh)
	var shape = null
	if not fluid_only and bool(result.get("includeCollision", false)) and not (shape is Shape3D):
		var collision_finalize_started_usec := Time.get_ticks_usec()
		shape = collision_shape_for_mesh(mesh)
		summary["collisionBuildMs"] = elapsed_ms(collision_finalize_started_usec)
	fluid_mesh.set_meta("terrainMeshingQueued", true)
	fluid_mesh.set_meta("terrainMeshingBackend", backend_id)
	fluid_mesh.set_meta("terrainMeshingNative", true)
	fluid_mesh.set_meta("terrainFluidSectionPayload", true)
	fluid_mesh.set_meta("terrainSignature", signature)
	apply_fluid_materials(fluid_mesh)
	var assets := {
		"mesh": mesh,
		"shape": shape,
		"fluidMesh": fluid_mesh,
		"terrainSignature": signature,
		"terrainMeshingBackend": backend_id,
		"terrainMeshingNative": true,
		"fluidOnly": fluid_only,
		"terrainPreparedSections": int(result.get("preparedSections", 0))
	}
	if String(assets.get("terrainSignature", "")) == "":
		assets["terrainSignature"] = current_signature
	completed_jobs[key] = assets
	summary["assetFinalizeMs"] = elapsed_ms(finalize_started_usec)
	summary["processed"] = 1
	return summary

func terrain_mesh_from_surface_data(data: Dictionary) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var vertices: PackedVector3Array = data.get("vertices", PackedVector3Array())
	if not vertices.is_empty():
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = data.get("normals", PackedVector3Array())
		arrays[Mesh.ARRAY_COLOR] = data.get("colors", PackedColorArray())
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.set_meta("terrainMeshingBackend", backend_id)
	mesh.set_meta("terrainMeshingNative", true)
	mesh.set_meta("terrainMeshingQueued", true)
	mesh.set_meta("terrainMeshingSectionPayload", true)
	mesh.set_meta("nativeVolumeMaterialIds", true)
	mesh.set_meta("chunk_volume_faces", int(data.get("faceCount", vertices.size() / 3)))
	mesh.set_meta("chunk_volume_vertices", int(data.get("vertexCount", vertices.size())))
	mesh.set_meta("nativeVolumeVertices", int(data.get("vertexCount", vertices.size())))
	mesh.set_meta("nativeVolumeStepCells", int(data.get("stepCells", 1)))
	mesh.set_meta("nativeVolumeSections", int(data.get("sectionCount", 0)))
	return mesh

func advance_async_fluid_finalize() -> Dictionary:
	var summary := {
		"processed": 0,
		"dropped": 0,
		"preparedSections": int(async_finalize_job.get("preparedSections", 0)),
		"workerJoinMs": 0.0,
		"assetFinalizeMs": 0.0,
		"terrainMeshBuildMs": 0.0,
		"fluidMeshBuildMs": float(async_finalize_job.get("fluidMeshBuildMs", 0.0)),
		"collisionBuildMs": 0.0,
		"elapsedMs": float(async_finalize_job.get("workerElapsedMs", 0.0)),
		"dropReason": ""
	}
	if async_finalize_job.is_empty():
		return summary
	var key: Vector2i = async_finalize_job.get("key", Vector2i(999999, 999999))
	var signature := String(async_finalize_job.get("terrainSignature", ""))
	var current_signature := current_signature_for_chunk(key)
	if signature != "" and current_signature != "" and signature != current_signature:
		async_finalize_job = {}
		summary["dropped"] = 1
		summary["dropReason"] = "stale_finalize_signature"
		return summary
	var started_usec := Time.get_ticks_usec()
	var data: Dictionary = async_finalize_job.get("data", {})
	var mesh := async_finalize_job.get("mesh") as ArrayMesh
	var kind := String(async_finalize_job.get("fluidKind", "water"))
	var offset := int(async_finalize_job.get("vertexOffset", 0))
	var vertices: PackedVector3Array = data.get("%sVertices" % kind, PackedVector3Array())
	if offset >= vertices.size() and kind == "water":
		kind = "lava"
		offset = 0
		async_finalize_job["fluidKind"] = kind
		async_finalize_job["vertexOffset"] = offset
		vertices = data.get("lavaVertices", PackedVector3Array())
	if offset < vertices.size():
		var end := mini(vertices.size(), offset + ASYNC_FLUID_FINALIZE_MAX_VERTICES_PER_FRAME)
		end -= (end - offset) % 3
		if end <= offset:
			end = mini(vertices.size(), offset + 3)
		var normals: PackedVector3Array = data.get("%sNormals" % kind, PackedVector3Array())
		var colors: PackedColorArray = data.get("%sColors" % kind, PackedColorArray())
		add_fluid_surface_from_data(mesh, vertices.slice(offset, end), normals.slice(offset, end), colors.slice(offset, end))
		var order: PackedStringArray = async_finalize_job.get("surfaceOrder", PackedStringArray())
		order.append(kind)
		async_finalize_job["surfaceOrder"] = order
		async_finalize_job["vertexOffset"] = end
		summary["assetFinalizeMs"] = elapsed_ms(started_usec)
		return summary
	apply_fluid_surface_metadata(mesh, data, async_finalize_job.get("surfaceOrder", PackedStringArray()))
	mesh.set_meta("terrainMeshingQueued", true)
	mesh.set_meta("terrainMeshingBackend", backend_id)
	mesh.set_meta("terrainMeshingNative", true)
	mesh.set_meta("terrainSignature", signature)
	apply_fluid_materials(mesh)
	var terrain_mesh := ArrayMesh.new()
	terrain_mesh.set_meta("terrainMeshingQueued", true)
	terrain_mesh.set_meta("terrainMeshingBackend", backend_id)
	terrain_mesh.set_meta("terrainMeshingNative", true)
	terrain_mesh.set_meta("terrainMeshingSectionPayload", false)
	completed_jobs[key] = {
		"mesh": terrain_mesh,
		"shape": null,
		"fluidMesh": mesh,
		"terrainSignature": signature if signature != "" else current_signature,
		"terrainMeshingBackend": backend_id,
		"terrainMeshingNative": true,
		"fluidOnly": true,
		"terrainPreparedSections": int(async_finalize_job.get("preparedSections", 0))
	}
	async_finalize_job = {}
	summary["assetFinalizeMs"] = elapsed_ms(started_usec)
	summary["processed"] = 1
	return summary

func fluid_mesh_from_surface_data(data: Dictionary) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	add_fluid_surface_from_data(mesh, data.get("waterVertices", PackedVector3Array()), data.get("waterNormals", PackedVector3Array()), data.get("waterColors", PackedColorArray()))
	add_fluid_surface_from_data(mesh, data.get("lavaVertices", PackedVector3Array()), data.get("lavaNormals", PackedVector3Array()), data.get("lavaColors", PackedColorArray()))
	apply_fluid_surface_metadata(mesh, data, data.get("surfaceOrder", PackedStringArray()))
	return mesh

func apply_fluid_surface_metadata(mesh: ArrayMesh, data: Dictionary, surface_order: PackedStringArray) -> void:
	mesh.set_meta("terrainFluidSectionPayload", not bool(data.get("deferred", true)))
	mesh.set_meta("terrainFluidSurfaceOrder", surface_order)
	mesh.set_meta("chunk_fluid_faces", int(data.get("fluidFaces", 0)))
	mesh.set_meta("chunk_water_faces", int(data.get("waterFaces", 0)))
	mesh.set_meta("chunk_lava_faces", int(data.get("lavaFaces", 0)))
	mesh.set_meta("nativeFluidStepCells", 0 if bool(data.get("forbiddenCoarseFluidPayload", false)) else 1)
	mesh.set_meta("nativeFluidSections", int(data.get("exactSectionCount", 0)))
	mesh.set_meta("nativeFluidCellCount", int(data.get("exactFluidCellCount", 0)))
	mesh.set_meta("fluidPayloadRevision", int(data.get("fluidPayloadRevision", 0)))
	mesh.set_meta("fluidPayloadSignature", String(data.get("fluidPayloadSignature", "")))
	mesh.set_meta("terrainFluidNativeDeferred", bool(data.get("deferred", true)))
	mesh.set_meta("terrainFluidDeferredReason", String(data.get("reason", "")))
	mesh.set_meta("unknownFluidNeighborCount", int(data.get("unknownNeighborCount", 0)))
	mesh.set_meta("forbiddenCoarseFluidPayload", bool(data.get("forbiddenCoarseFluidPayload", false)))
	mesh.set_meta("terrainFluidExactPayload", bool(data.get("exactContract", false)))
	mesh.set_meta("terrainFluidLegacyExactPayload", bool(data.get("legacyExactContract", false)))

func add_fluid_surface_from_data(mesh: ArrayMesh, vertices_value, normals_value, colors_value) -> void:
	var vertices: PackedVector3Array = vertices_value if vertices_value is PackedVector3Array else PackedVector3Array()
	if vertices.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals_value if normals_value is PackedVector3Array else PackedVector3Array()
	arrays[Mesh.ARRAY_COLOR] = colors_value if colors_value is PackedColorArray else PackedColorArray()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

func _thread_build_native_chunk_assets(key: Vector2i, signature: String, include_collision: bool, fluid_only: bool, payload: Dictionary, worker_backend, payload_job_to_retire: Dictionary = {}) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	var terrain_started_usec := Time.get_ticks_usec()
	var terrain_surface_data := {}
	var worker_error := ""
	if not fluid_only:
		if worker_backend == null or not worker_backend.has_method("build_chunk_surface_data_from_sections"):
			worker_error = "terrain_surface_data_backend_unavailable"
		else:
			var terrain_surface_value = worker_backend.call("build_chunk_surface_data_from_sections", payload)
			if terrain_surface_value is Dictionary and not (terrain_surface_value as Dictionary).is_empty():
				terrain_surface_data = terrain_surface_value
			else:
				worker_error = "terrain_surface_data_invalid"
	var terrain_mesh_build_ms := elapsed_ms(terrain_started_usec)
	var fluid_started_usec := Time.get_ticks_usec()
	var fluid_surface_data := {}
	if worker_error.is_empty() and bool(payload.get("hasFluid", true)):
		if worker_backend == null or not worker_backend.has_method("build_chunk_fluid_surface_data_from_sections"):
			worker_error = "fluid_surface_data_backend_unavailable"
		else:
			var fluid_surface_value = worker_backend.call("build_chunk_fluid_surface_data_from_sections", payload)
			if fluid_surface_value is Dictionary and not (fluid_surface_value as Dictionary).is_empty():
				fluid_surface_data = fluid_surface_value
			else:
				worker_error = "fluid_surface_data_invalid"
	var fluid_mesh_build_ms := elapsed_ms(fluid_started_usec)
	var result := {
		"key": key,
		"terrainSignature": signature,
		"terrainSurfaceData": terrain_surface_data,
		"fluidSurfaceData": fluid_surface_data,
		"workerError": worker_error,
		"includeCollision": include_collision,
		"fluidOnly": fluid_only,
		"preparedSections": int((payload.get("sections", []) as Array).size()) if payload.get("sections", []) is Array else 0,
		"terrainMeshBuildMs": terrain_mesh_build_ms,
		"fluidMeshBuildMs": fluid_mesh_build_ms,
		"collisionBuildMs": 0.0,
		"retiredPayloadJob": payload_job_to_retire,
		"elapsedMs": elapsed_ms(started_usec)
	}
	return result

func nearest_pending_job_key(center: Vector2i) -> Vector2i:
	var best := Vector2i(999999, 999999)
	var best_distance := 2147483647
	var best_priority := -2147483648
	var best_sequence := 2147483647
	for key_value in pending_jobs.keys():
		var key: Vector2i = key_value
		var job: Dictionary = pending_jobs[key]
		var priority := int(job.get("priority", 0))
		var sequence := int(job.get("sequence", 0))
		var distance := absi(key.x - center.x) + absi(key.y - center.y)
		if priority > best_priority:
			best = key
			best_priority = priority
			best_distance = distance
			best_sequence = sequence
		elif priority == best_priority:
			if distance < best_distance or (distance == best_distance and sequence < best_sequence):
				best = key
				best_distance = distance
				best_sequence = sequence
	return best

func build_chunk_asset_bundle(cx: int, cz: int, signature := "", include_collision := true) -> Dictionary:
	trace("asset_bundle:%d,%d:prepare_start" % [cx, cz])
	var prepared_sections := 0 if native_backend_available else prepare_chunk_sections(cx, cz)
	trace("asset_bundle:%d,%d:mesh_start:sections=%d" % [cx, cz, prepared_sections])
	var mesh := build_chunk_mesh(cx, cz)
	trace("asset_bundle:%d,%d:material_start" % [cx, cz])
	apply_terrain_material(mesh)
	trace("asset_bundle:%d,%d:fluid_start" % [cx, cz])
	var fluid_mesh := build_chunk_fluid_mesh(cx, cz)
	trace("asset_bundle:%d,%d:collision_start" % [cx, cz])
	var shape = collision_shape_for_mesh(mesh) if include_collision else null
	trace("asset_bundle:%d,%d:finish" % [cx, cz])
	var signature_text := String(signature)
	if signature_text == "":
		signature_text = current_signature_for_chunk(Vector2i(cx, cz))
	if mesh != null:
		mesh.set_meta("terrainMeshingQueued", true)
	if fluid_mesh != null:
		fluid_mesh.set_meta("terrainMeshingQueued", true)
	return {
		"mesh": mesh,
		"shape": shape,
		"fluidMesh": fluid_mesh,
		"terrainSignature": signature_text,
		"terrainMeshingBackend": backend_id,
		"terrainMeshingNative": native_backend_available,
		"terrainPreparedSections": prepared_sections
	}

func current_signature_for_chunk(key: Vector2i) -> String:
	if main != null and main.has_method("chunk_asset_signature"):
		return String(main.call("chunk_asset_signature", key))
	return ""

func prepare_chunk_sections(cx: int, cz: int) -> int:
	if main == null or main.get("world_generation_system") == null:
		return 0
	var world_generation = main.get("world_generation_system")
	if not world_generation.has_method("request_sections_for_bounds"):
		return 0
	var chunk_size := 28
	if main != null:
		chunk_size = int(main.CHUNK_SIZE)
	if chunk_size <= 0:
		chunk_size = 28
	var start_x := cx * chunk_size
	var start_z := cz * chunk_size
	var min_y := 0
	var max_y := 0
	if main.has_method("chunk_volume_y_bounds"):
		var bounds: Dictionary = main.call("chunk_volume_y_bounds", start_x, start_z)
		min_y = int(bounds.get("minY", min_y))
		max_y = int(bounds.get("maxY", max_y))
	else:
		min_y = int(world_generation.call("world_bottom_cell_y")) if world_generation.has_method("world_bottom_cell_y") else -64
		max_y = int(world_generation.call("world_top_cell_y")) if world_generation.has_method("world_top_cell_y") else 96
	var min_cell := Vector3i(start_x - 1, min_y - 1, start_z - 1)
	var max_cell := Vector3i(start_x + chunk_size + 1, max_y + 1, start_z + chunk_size + 1)
	var requested_value = world_generation.call("request_sections_for_bounds", min_cell, max_cell)
	return (requested_value as Array).size() if requested_value is Array else 0

func elapsed_ms(started_usec: int) -> float:
	return float(Time.get_ticks_usec() - started_usec) / 1000.0

func trace(label: String) -> void:
	var path := OS.get_environment("VOXEL_TERRAIN_MESHING_TRACE").strip_edges()
	if path == "":
		return
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(label)

func build_chunk_mesh(cx: int, cz: int) -> Mesh:
	trace("build_mesh:%d,%d:start" % [cx, cz])
	if not chunk_requires_volume_mesh(cx, cz):
		trace("build_mesh:%d,%d:heightfield_start" % [cx, cz])
		var exterior_mesh := build_main_chunk_mesh(cx, cz)
		trace("build_mesh:%d,%d:heightfield_done" % [cx, cz])
		return exterior_mesh
	if backend != null and backend.has_method("build_chunk_mesh_from_sections"):
		trace("build_mesh:%d,%d:payload_start" % [cx, cz])
		var payload := section_payload_for_chunk(cx, cz)
		trace("build_mesh:%d,%d:payload_done:%s" % [cx, cz, str(not payload.is_empty())])
		if not payload.is_empty():
			trace("build_mesh:%d,%d:native_sections_start" % [cx, cz])
			var native_section_mesh = backend.call("build_chunk_mesh_from_sections", payload)
			trace("build_mesh:%d,%d:native_sections_done" % [cx, cz])
			if native_section_mesh is Mesh:
				var mesh := native_section_mesh as Mesh
				mesh.set_meta("terrainMeshingBackend", backend_id)
				mesh.set_meta("terrainMeshingNative", true)
				mesh.set_meta("terrainMeshingSectionPayload", true)
				mesh = project_chunk_surface_normals(mesh, cx, cz)
				apply_terrain_material(mesh)
				return mesh
	if chunk_has_terrain_volume_edits(cx, cz):
		trace("build_mesh:%d,%d:edited_local_start" % [cx, cz])
		var edited_mesh := build_main_chunk_mesh(cx, cz)
		trace("build_mesh:%d,%d:edited_local_done" % [cx, cz])
		return edited_mesh
	if backend != null and backend.has_method("build_chunk_mesh"):
		trace("build_mesh:%d,%d:native_main_start" % [cx, cz])
		var native_mesh = backend.call("build_chunk_mesh", main, cx, cz)
		trace("build_mesh:%d,%d:native_main_done" % [cx, cz])
		if native_mesh is Mesh:
			var mesh := native_mesh as Mesh
			mesh.set_meta("terrainMeshingBackend", backend_id)
			mesh.set_meta("terrainMeshingNative", true)
			mesh = project_chunk_surface_normals(mesh, cx, cz)
			apply_terrain_material(mesh)
			return mesh
	if should_defer_blocking_gdscript_volume_mesh(cx, cz):
		trace("build_mesh:%d,%d:provisional" % [cx, cz])
		return provisional_exterior_mesh(cx, cz)
	var mesh: Mesh = null
	trace("build_mesh:%d,%d:fallback_start" % [cx, cz])
	mesh = build_main_chunk_mesh(cx, cz)
	trace("build_mesh:%d,%d:fallback_done" % [cx, cz])
	if mesh == null:
		mesh = ArrayMesh.new()
	mesh.set_meta("terrainMeshingBackend", backend_id)
	mesh.set_meta("terrainMeshingNative", false)
	mesh.set_meta("terrainMeshingQueued", false)
	trace("build_mesh:%d,%d:done" % [cx, cz])
	return mesh

func build_main_chunk_mesh(cx: int, cz: int) -> Mesh:
	var mesh: Mesh = null
	if main != null and main.has_method("build_chunk_mesh"):
		var fallback_mesh = main.call("build_chunk_mesh", cx, cz)
		if fallback_mesh is Mesh:
			mesh = fallback_mesh as Mesh
	if mesh == null:
		mesh = ArrayMesh.new()
	mesh.set_meta("terrainMeshingBackend", "heightfield_or_gdscript_volume")
	mesh.set_meta("terrainMeshingNative", false)
	mesh.set_meta("terrainMeshingQueued", false)
	return mesh

func project_chunk_surface_normals(mesh: Mesh, cx: int, cz: int) -> Mesh:
	if mesh == null or main == null or not main.has_method("project_chunk_surface_normals"):
		return mesh
	var projected = main.call("project_chunk_surface_normals", mesh, cx, cz)
	return projected as Mesh if projected is Mesh else mesh

func should_defer_blocking_gdscript_volume_mesh(cx: int, cz: int) -> bool:
	return not native_backend_available and not allow_blocking_gdscript_fallback and chunk_requires_volume_mesh(cx, cz)

func chunk_requires_volume_mesh(cx: int, cz: int) -> bool:
	if main == null:
		return false
	var size := chunk_size()
	var start_x := cx * size
	var start_z := cz * size
	if chunk_has_terrain_volume_edits(cx, cz):
		return true
	if main.has_method("chunk_has_excavation_overlap") and bool(main.call("chunk_has_excavation_overlap", start_x, start_z)):
		return true
	if main.has_method("chunk_needs_generated_underground_volume_mesh") and bool(main.call("chunk_needs_generated_underground_volume_mesh", start_x, start_z)):
		return true
	return false

func chunk_has_terrain_volume_edits(cx: int, cz: int) -> bool:
	if main == null or not main.has_method("chunk_has_terrain_volume_edits"):
		return false
	var size := chunk_size()
	return bool(main.call("chunk_has_terrain_volume_edits", cx * size, cz * size))

func provisional_exterior_mesh(cx: int, cz: int) -> Mesh:
	var mesh: Mesh = null
	if main != null and main.has_method("streaming_provisional_exterior_surface_mesh"):
		var placeholder_mesh = main.call("streaming_provisional_exterior_surface_mesh", cx, cz)
		if placeholder_mesh is Mesh:
			mesh = placeholder_mesh as Mesh
	elif main != null and main.has_method("build_natural_exterior_array_mesh"):
		var size := chunk_size()
		var exterior_mesh = main.call("build_natural_exterior_array_mesh", cx * size, cz * size)
		if exterior_mesh is Mesh:
			mesh = exterior_mesh as Mesh
	if mesh == null:
		mesh = ArrayMesh.new()
	apply_terrain_material(mesh)
	mesh.set_meta("terrainMeshingBackend", "provisional_exterior_surface")
	mesh.set_meta("terrainMeshingNative", false)
	mesh.set_meta("terrainMeshingQueued", false)
	mesh.set_meta("terrainMeshingProvisional", true)
	mesh.set_meta("terrainMeshingDeferredWithoutNative", true)
	return mesh

func apply_terrain_material(mesh: Mesh) -> void:
	if mesh == null or not (mesh is ArrayMesh):
		return
	var array_mesh := mesh as ArrayMesh
	if array_mesh.get_surface_count() <= 0:
		return
	var material = null
	if main != null:
		material = main.get("terrain_material")
	if material is Material:
		array_mesh.surface_set_material(0, material as Material)

func section_payload_for_chunk(cx: int, cz: int) -> Dictionary:
	trace("section_payload:%d,%d:start" % [cx, cz])
	if main == null or main.get("world_generation_system") == null:
		return {}
	var world_generation = main.get("world_generation_system")
	if not world_generation.has_method("section_payload_for_bounds"):
		return {}
	var size := chunk_size()
	var start_x := cx * size
	var start_z := cz * size
	var min_y := 0
	var max_y := 0
	if main.has_method("chunk_volume_y_bounds"):
		var bounds: Dictionary = main.call("chunk_volume_y_bounds", start_x, start_z)
		min_y = int(bounds.get("minY", min_y))
		max_y = int(bounds.get("maxY", max_y))
	else:
		min_y = int(world_generation.call("world_bottom_cell_y")) if world_generation.has_method("world_bottom_cell_y") else -64
		max_y = int(world_generation.call("world_top_cell_y")) if world_generation.has_method("world_top_cell_y") else 96
	if max_y <= min_y:
		return {}
	var min_cell := Vector3i(start_x - 1, min_y - 1, start_z - 1)
	var max_cell := Vector3i(start_x + size + 1, max_y + 1, start_z + size + 1)
	var step := 1
	if main.has_method("underground_volume_mesh_step_for_chunk"):
		step = maxi(1, int(main.call("underground_volume_mesh_step_for_chunk", start_x, start_z)))
	trace("section_payload:%d,%d:request:%d:%d:step=%d" % [cx, cz, min_y, max_y, step])
	var payload_value = {}
	if native_backend_available and world_generation.has_method("section_payload_for_meshing_chunk"):
		payload_value = world_generation.call("section_payload_for_meshing_chunk", start_x, start_z, size, min_y, max_y, step)
	else:
		payload_value = world_generation.call("section_payload_for_bounds", min_cell, max_cell)
	trace("section_payload:%d,%d:returned" % [cx, cz])
	var payload: Dictionary = payload_value if payload_value is Dictionary else {}
	if payload.is_empty():
		return {}
	payload["chunkX"] = cx
	payload["chunkZ"] = cz
	payload["chunkSize"] = size
	payload["startX"] = start_x
	payload["startZ"] = start_z
	payload["minY"] = min_y
	payload["maxY"] = max_y
	payload["stepCells"] = step
	trace("section_payload:%d,%d:done" % [cx, cz])
	return payload

func build_chunk_fluid_mesh(cx: int, cz: int) -> Mesh:
	trace("build_fluid:%d,%d:start" % [cx, cz])
	if not chunk_requires_volume_mesh(cx, cz):
		var empty_mesh := ArrayMesh.new()
		empty_mesh.set_meta("terrainMeshingBackend", "heightfield_exterior")
		empty_mesh.set_meta("terrainMeshingNative", false)
		empty_mesh.set_meta("terrainMeshingQueued", false)
		trace("build_fluid:%d,%d:heightfield_empty" % [cx, cz])
		return empty_mesh
	if chunk_has_terrain_volume_edits(cx, cz):
		var edited_empty_mesh := ArrayMesh.new()
		edited_empty_mesh.set_meta("terrainMeshingBackend", "edited_volume_local")
		edited_empty_mesh.set_meta("terrainMeshingNative", false)
		edited_empty_mesh.set_meta("terrainMeshingQueued", false)
		trace("build_fluid:%d,%d:edited_empty" % [cx, cz])
		return edited_empty_mesh
	if backend != null and backend.has_method("build_chunk_fluid_mesh_from_sections"):
		trace("build_fluid:%d,%d:payload_start" % [cx, cz])
		var payload := section_payload_for_chunk(cx, cz)
		trace("build_fluid:%d,%d:payload_done:%s" % [cx, cz, str(not payload.is_empty())])
		if not payload.is_empty():
			trace("build_fluid:%d,%d:native_sections_start" % [cx, cz])
			var native_section_mesh = backend.call("build_chunk_fluid_mesh_from_sections", payload)
			trace("build_fluid:%d,%d:native_sections_done" % [cx, cz])
			if native_section_mesh is Mesh:
				(native_section_mesh as Mesh).set_meta("terrainMeshingBackend", backend_id)
				(native_section_mesh as Mesh).set_meta("terrainMeshingNative", true)
				(native_section_mesh as Mesh).set_meta("terrainFluidSectionPayload", true)
				apply_fluid_materials(native_section_mesh as Mesh)
				return native_section_mesh as Mesh
	if backend != null and backend.has_method("build_chunk_fluid_mesh"):
		trace("build_fluid:%d,%d:native_main_start" % [cx, cz])
		var native_mesh = backend.call("build_chunk_fluid_mesh", main, cx, cz)
		trace("build_fluid:%d,%d:native_main_done" % [cx, cz])
		if native_mesh is Mesh:
			if not bool((native_mesh as Mesh).get_meta("terrainFluidNativeDeferred", false)):
				(native_mesh as Mesh).set_meta("terrainMeshingBackend", backend_id)
				(native_mesh as Mesh).set_meta("terrainMeshingNative", true)
				apply_fluid_materials(native_mesh as Mesh)
				return native_mesh as Mesh
	if should_defer_blocking_gdscript_volume_mesh(cx, cz):
		trace("build_fluid:%d,%d:deferred_without_native" % [cx, cz])
		var deferred_mesh := ArrayMesh.new()
		deferred_mesh.set_meta("terrainMeshingBackend", backend_id)
		deferred_mesh.set_meta("terrainMeshingNative", false)
		deferred_mesh.set_meta("terrainMeshingQueued", false)
		deferred_mesh.set_meta("terrainFluidDeferredWithoutNative", true)
		return deferred_mesh
	var mesh: Mesh = null
	if main != null and main.has_method("build_chunk_fluid_mesh"):
		trace("build_fluid:%d,%d:fallback_start" % [cx, cz])
		var fallback_mesh = main.call("build_chunk_fluid_mesh", cx, cz)
		trace("build_fluid:%d,%d:fallback_done" % [cx, cz])
		if fallback_mesh is Mesh:
			mesh = fallback_mesh as Mesh
	if mesh == null:
		mesh = ArrayMesh.new()
	mesh.set_meta("terrainMeshingBackend", backend_id)
	mesh.set_meta("terrainMeshingNative", false)
	mesh.set_meta("terrainMeshingQueued", false)
	trace("build_fluid:%d,%d:done" % [cx, cz])
	return mesh

func apply_fluid_materials(mesh: Mesh) -> void:
	if mesh == null or not (mesh is ArrayMesh):
		return
	var array_mesh := mesh as ArrayMesh
	if array_mesh.get_surface_count() <= 0:
		return
	var order_value = array_mesh.get_meta("terrainFluidSurfaceOrder", PackedStringArray())
	var order: PackedStringArray = order_value if order_value is PackedStringArray else PackedStringArray()
	var water_material: Material = null
	var lava_material: Material = null
	if main != null:
		var materials_value = main.get("materials")
		if materials_value is Dictionary:
			var materials: Dictionary = materials_value
			if materials.get("water", null) is Material:
				water_material = materials.get("water", null) as Material
			if materials.get("lava", null) is Material:
				lava_material = materials.get("lava", null) as Material
	if water_material == null and main != null and main.get("terrain_material") is Material:
		water_material = main.get("terrain_material") as Material
	if lava_material == null and main != null and main.get("terrain_material") is Material:
		lava_material = main.get("terrain_material") as Material
	for surface_index in range(array_mesh.get_surface_count()):
		var fluid_id := "water"
		if surface_index < order.size():
			fluid_id = String(order[surface_index])
		var material := lava_material if fluid_id == "lava" else water_material
		if material != null:
			array_mesh.surface_set_material(surface_index, material)

func collision_shape_for_mesh(mesh: Mesh):
	if mesh == null:
		return null
	if mesh is ArrayMesh and not array_mesh_indices_are_valid(mesh as ArrayMesh):
		return collision_shape_from_valid_triangles(mesh as ArrayMesh)
	if backend != null and backend.has_method("collision_shape_for_mesh"):
		trace("collision_shape:native_start")
		var native_shape = backend.call("collision_shape_for_mesh", mesh)
		trace("collision_shape:native_done")
		if native_shape is Shape3D:
			return native_shape as Shape3D
	if mesh is ArrayMesh:
		var safe_shape = collision_shape_from_valid_triangles(mesh as ArrayMesh)
		if safe_shape is Shape3D:
			return safe_shape
	trace("collision_shape:trimesh_start")
	var shape := mesh.create_trimesh_shape()
	trace("collision_shape:trimesh_done")
	if shape is ConcavePolygonShape3D:
		(shape as ConcavePolygonShape3D).backface_collision = true
	return shape


func build_section_fluid_surface_data(payload: Dictionary, section_key: Vector3i,
		camera_position_local: Vector3) -> Dictionary:
	if backend == null or not backend.has_method("build_section_fluid_surface_data_from_sections"):
		return {"status":"failed", "reason":"native_section_fluid_mesher_unavailable"}
	return backend.call("build_section_fluid_surface_data_from_sections",
		payload, section_key, camera_position_local)


func sort_section_fluid_surface_data(canonical_data: Dictionary,
		camera_position_local: Vector3) -> Dictionary:
	if backend == null or not backend.has_method("sort_section_fluid_surface_data"):
		return {"status":"failed", "reason":"native_section_fluid_sorter_unavailable"}
	return backend.call("sort_section_fluid_surface_data", canonical_data,
		camera_position_local)


func section_fluid_mesh_from_surface_data(data: Dictionary, fluid_kind: String) -> ArrayMesh:
	if String(data.get("status", "")) != "ready" or fluid_kind not in ["water", "lava"]:
		return null
	var vertices_value: Variant = data.get("%sVertices" % fluid_kind, null)
	var normals_value: Variant = data.get("%sNormals" % fluid_kind, null)
	var colors_value: Variant = data.get("%sColors" % fluid_kind, null)
	if not vertices_value is PackedVector3Array or not normals_value is PackedVector3Array \
			or not colors_value is PackedColorArray or (vertices_value as PackedVector3Array).is_empty():
		return null
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices_value
	arrays[Mesh.ARRAY_NORMAL] = normals_value
	arrays[Mesh.ARRAY_COLOR] = colors_value
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.set_meta("terrainFluidSurfaceOrder", PackedStringArray([fluid_kind]))
	apply_fluid_materials(mesh)
	return mesh

func array_mesh_indices_are_valid(array_mesh: ArrayMesh) -> bool:
	if array_mesh == null:
		return false
	for surface_index in range(array_mesh.get_surface_count()):
		var arrays := array_mesh.surface_get_arrays(surface_index)
		if arrays.size() <= Mesh.ARRAY_VERTEX:
			return false
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] is PackedInt32Array else PackedInt32Array()
		var vertex_count := vertices.size()
		if indices.is_empty():
			if vertex_count % 3 != 0:
				return false
			continue
		for index_value in indices:
			if int(index_value) < 0 or int(index_value) >= vertex_count:
				return false
	return true

func collision_shape_from_valid_triangles(array_mesh: ArrayMesh):
	if array_mesh == null:
		return null
	var faces := PackedVector3Array()
	for surface_index in range(array_mesh.get_surface_count()):
		var arrays := array_mesh.surface_get_arrays(surface_index)
		if arrays.size() <= Mesh.ARRAY_VERTEX:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if vertices.size() < 3:
			continue
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] is PackedInt32Array else PackedInt32Array()
		if indices.is_empty():
			for i in range(0, vertices.size() - 2, 3):
				faces.append(vertices[i])
				faces.append(vertices[i + 1])
				faces.append(vertices[i + 2])
			continue
		var triangle_count := indices.size() - (indices.size() % 3)
		for i in range(0, triangle_count, 3):
			var a := int(indices[i])
			var b := int(indices[i + 1])
			var c := int(indices[i + 2])
			if a < 0 or b < 0 or c < 0 or a >= vertices.size() or b >= vertices.size() or c >= vertices.size():
				continue
			faces.append(vertices[a])
			faces.append(vertices[b])
			faces.append(vertices[c])
	if faces.size() < 3:
		return null
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	shape.backface_collision = true
	return shape

func chunk_size() -> int:
	if main != null:
		var value := int(main.CHUNK_SIZE)
		if value > 0:
			return value
	return 28
