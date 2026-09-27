extends SceneTree

# Headed engine insertion reproducer. No Main runtime, N5 physics authority,
# synthetic backend, direct try_set_block_data call or physics acknowledgement.
const MAIN = preload("res://scripts/Main.gd")
const STRUCTURES = preload("res://scripts/StructureSystem.gd")
const WORLD = preload("res://scripts/WorldGenerationSystem.gd")
const SOURCE = preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const GATE = preload("res://scripts/terrain/VoxelTerrainSiteGate.gd")
const PAGES = preload("res://scripts/world/NativeShapingPageAdmission.gd")
const PUBLISHER = preload("res://scripts/terrain/NativeTerrainBlockPublisher.gd")
const CONTROL := Vector3i.ZERO
const OUTSIDE := Vector3i(33, 1, 0)
const VIEW_DISTANCE := 80
const SAMPLE_CAP := 16
const CONSUMER_ID := 94

var _checks: Dictionary = {}
var _evidence: Dictionary = {}
var _main: Node
var _backend: RefCounted
var _scene: Node3D
var _terrain: VoxelTerrain
var _viewer: VoxelViewer
var _gate: RefCounted
var _pages: RefCounted
var _publisher: RefCounted
var _admission: RefCounted
var _publisher_ready: bool = false

func _init() -> void:
	call_deferred("_run")

func _check(label: String, value: bool) -> void:
	_checks[label] = value

func _bounded(value: Variant) -> Dictionary:
	var budget: Dictionary = {"remaining":1024, "truncated":false}
	var result: Variant = _serialize(value, budget, 0)
	return {"value":result, "nodeCap":1024, "depthCap":12,
		"truncated":budget.truncated}

func _serialize(value: Variant, budget: Dictionary, depth: int) -> Variant:
	if int(budget.remaining) <= 0 or depth > 12:
		budget.truncated = true
		return "diagnostic_limit"
	budget.remaining -= 1
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value:
			if int(budget.remaining) <= 0:
				budget.truncated = true
				break
			result[str(key).left(256)] = _serialize(value[key], budget, depth + 1)
		return result
	if value is Array:
		var result: Array = []
		for entry: Variant in value:
			if int(budget.remaining) <= 0:
				budget.truncated = true
				break
			result.append(_serialize(entry, budget, depth + 1))
		return result
	if value is Vector3 or value is Vector3i:
		return {"x":value.x, "y":value.y, "z":value.z}
	if value is Vector2 or value is Vector2i:
		return {"x":value.x, "y":value.y}
	if value is AABB:
		return {"position":_serialize(value.position, budget, depth + 1),
			"size":_serialize(value.size, budget, depth + 1)}
	if value is String: return value.left(1024)
	if value == null or value is bool or value is int or value is float: return value
	return str(value).left(256)

func _area(block: Vector3i) -> Dictionary:
	var size: int = _terrain.get_data_block_size()
	var origin: Vector3i = block * size
	var extent: Vector3i = Vector3i.ONE * size
	var available: bool = _terrain.has_method("get_viewer_network_peer_ids_in_area")
	var result: Dictionary = {"block":block, "origin":origin, "size":extent,
		"coordinateSpace":"terrain-local voxel grid", "dataBlockSize":size,
		"queryAvailable":available, "pairedDataBoxCoverage":null, "peerEntryCount":null,
		"scope":"paired data-box intersection only; not full rejection cause or physics",
		"processFrame":Engine.get_process_frames(), "physicsFrame":Engine.get_physics_frames()}
	if not available: return result
	var peer_ids: PackedInt32Array = _terrain.call("get_viewer_network_peer_ids_in_area", origin, extent)
	var sample: Array[int] = []
	for index in range(mini(peer_ids.size(), SAMPLE_CAP)):
		sample.append(peer_ids[index])
	result.pairedDataBoxCoverage = not peer_ids.is_empty()
	result.peerEntryCount = peer_ids.size()
	result.peerIds = sample
	result.peerIdCap = SAMPLE_CAP
	result.peerIdsOmitted = maxi(peer_ids.size() - SAMPLE_CAP, 0)
	return result

func _geometry() -> Dictionary:
	return {"terrainIdText":str(_terrain.get_instance_id()),
		"viewerIdText":str(_viewer.get_instance_id()), "backendIdText":str(_backend.get_instance_id()),
		"consumerId":CONSUMER_ID, "terrainWorldPosition":_terrain.global_position,
		"terrainBasisX":_terrain.global_transform.basis.x,
		"terrainBasisY":_terrain.global_transform.basis.y,
		"terrainBasisZ":_terrain.global_transform.basis.z,
		"viewerWorldPosition":_viewer.global_position,
		"viewerTerrainLocalPosition":_terrain.to_local(_viewer.global_position),
		"sameWorld3D":_terrain.get_world_3d() == _viewer.get_world_3d(),
		"terrainBounds":_terrain.get_bounds(), "meshBlockSize":_terrain.get_mesh_block_size(),
		"dataBlockSize":_terrain.get_data_block_size(), "terrainCanProcess":_terrain.can_process(),
		"maxTerrainViewDistance":_terrain.max_view_distance, "viewerViewDistance":_viewer.view_distance,
		"viewerRequiresVisuals":_viewer.requires_visuals, "viewerRequiresCollisions":_viewer.requires_collisions,
		"automaticLoading":_terrain.automatic_loading_enabled,
		"engineCollisionGeneration":_terrain.generate_collisions,
		"physicsScope":"collision generation disabled for both cases; viewer flags are not N5 proof"}

func _pump_case(block: Vector3i, accepted_case: bool, frame_cap: int) -> Dictionary:
	var deadline: int = Time.get_ticks_msec() + (30000 if accepted_case else 15000)
	var samples: Array[Dictionary] = []
	var result: Dictionary = {"frameCap":frame_cap, "sampleCap":SAMPLE_CAP,
		"calls":0, "rejectedReceipts":0, "acceptedReceipts":0, "omittedSamples":0,
		"coveredAcceptedReceipts":0, "uncoveredRejectedReceipts":0,
		"first":{}, "latest":{}, "terminal":"deadline", "timing":"queries bracket pump but are not atomic with insertion"}
	for frame in range(frame_cap):
		if Time.get_ticks_msec() >= deadline: break
		_gate.call("advance")
		var before: Dictionary = _area(block)
		var event: Dictionary = _publisher.call("pump")
		var after: Dictionary = _area(block)
		var sample: Dictionary = {"attempt":frame, "beforePumpCoverage":before,
			"afterPumpCoverage":after, "publisherReceipt":event,
			"hasEngineData":_terrain.has_data_block(block),
			"installedGeneration":_publisher.call("installed_generation", block)}
		result.calls += 1
		if result.first.is_empty(): result.first = _bounded(sample)
		result.latest = _bounded(sample)
		if samples.size() < SAMPLE_CAP: samples.append(_bounded(sample))
		else: result.omittedSamples += 1
		if event.get("block") == block:
			if event.get("status") == "ready" and event.get("insertionReceipt") == "ready" \
					and event.get("state") == "inserted_waiting_mesh":
				result.acceptedReceipts += 1
				if before.get("pairedDataBoxCoverage") == true and after.get("pairedDataBoxCoverage") == true:
					result.coveredAcceptedReceipts += 1
				result.acceptedObservation = _bounded(sample)
				result.engineAccepted = true
				result.engineAcceptedEvidence = "inferred from public Publisher ready insertion receipt/state, not direct engine return"
			if event.get("status") == "pending" and event.get("insertionReceipt") == "rejected" \
					and event.get("state") == "prepared":
				result.rejectedReceipts += 1
				if before.get("pairedDataBoxCoverage") == false and after.get("pairedDataBoxCoverage") == false:
					result.uncoveredRejectedReceipts += 1
				result.rejectedObservation = _bounded(sample)
				if not result.has("firstRejectedObservation"):
					result.firstRejectedObservation = _bounded(sample)
				result.engineAccepted = false
				result.engineAcceptedEvidence = "inferred from public Publisher pending/prepared/rejected branch"
		if event.get("status") == "failed":
			result.terminal = "publisher_failed"
			break
		if accepted_case and int(result.acceptedReceipts) > 0:
			result.terminal = "accepted"
			break
		if not accepted_case and int(result.rejectedReceipts) >= 3:
			result.terminal = "three_rejections"
			break
		await process_frame
	result.samples = samples
	result.finalCoverage = _area(block)
	result.finalPublisher = _publisher.call("snapshot")
	result.finalHasEngineData = _terrain.has_data_block(block)
	result.finalInstalledGeneration = _publisher.call("installed_generation", block)
	return result

func _drain() -> void:
	if _gate != null: _gate.call("stop")
	if _viewer != null and _viewer.is_inside_tree():
		_check("gate_detached_viewer_before_drain", false)
	elif _viewer != null:
		_check("gate_detached_viewer_before_drain", true)
	var diagnostics: Dictionary = {"frameCap":600, "sampleCap":SAMPLE_CAP, "samples":[],
		"first":{}, "latest":{}, "firstFailure":{}, "calls":0,
		"processCleanupScope":"runner watchdog is separate; this receipt proves only public owner drain"}
	var final: Dictionary = {"status":"ready", "drained":true, "notConfigured":true}
	if _publisher_ready:
		final = _publisher.call("request_stop")
		diagnostics.stopRequest = _bounded(final)
		if final.get("status") == "failed": diagnostics.firstFailure = _bounded(final)
	if _admission != null: _admission.call("request_shutdown")
	var deadline: int = Time.get_ticks_msec() + 30000
	for frame in range(600):
		if Time.get_ticks_msec() >= deadline: break
		if _admission != null: _admission.call("advance")
		if _publisher_ready and final.get("status") not in ["ready", "failed"]:
			final = _publisher.call("drain_step")
			diagnostics.calls += 1
		var admission_state: Dictionary = _admission.call("stats") if _admission != null else {"shutdownComplete":true}
		var sample: Dictionary = {"attempt":frame, "publisher":final, "admission":admission_state,
			"publisherState":_publisher.call("snapshot") if _publisher_ready else {},
			"processFrame":Engine.get_process_frames()}
		if diagnostics.first.is_empty(): diagnostics.first = _bounded(sample)
		diagnostics.latest = _bounded(sample)
		if diagnostics.samples.size() < SAMPLE_CAP: diagnostics.samples.append(_bounded(sample))
		if final.get("status") == "failed" and diagnostics.firstFailure.is_empty():
			diagnostics.firstFailure = _bounded(sample)
		if final.get("status") in ["ready", "failed"] and bool(admission_state.get("shutdownComplete", false)): break
		await process_frame
	diagnostics.finalReceipt = _bounded(final)
	var final_admission: Dictionary = _admission.call("stats") if _admission != null else {"shutdownComplete":true}
	diagnostics.finalAdmission = _bounded(final_admission)
	_evidence.drain = diagnostics
	_check("publisher_physical_and_native_drain", not _publisher_ready or
		(final.get("status") == "ready" and bool(final.get("drained", false))
		and bool(final.get("physicalBlocksUnloaded", false)) and bool(final.get("nativeWorkersDrained", false))
		and final.get("remainingDemanded") == 0 and final.get("remainingRequested") == 0
		and final.get("remainingInserted") == 0 and final.get("remainingOrphaned") == 0))
	_check("admission_shutdown_complete", bool(final_admission.get("shutdownComplete", false)))

func _finish() -> void:
	await _drain()
	# Freeing scene/backend below cannot convert failed drain into successful evidence.
	if _viewer != null: _viewer.free()
	if _scene != null: _scene.free()
	_publisher = null
	_pages = null
	_backend = null
	_gate = null
	_admission = null
	if _main != null: _main.free()
	var passed: bool = not _checks.is_empty() and false not in _checks.values()
	var report: Dictionary = {"schema":"n3-engine-insertion-contract/v1", "finished":true,
		"runToken":OS.get_environment("VWB_ENGINE_INSERTION_RUN_TOKEN"), "passed":passed,
		"checks":_checks, "evidence":_evidence, "productionCutover":false,
		"evidenceLevel":"headed real engine/native publisher insertion; no N5 physics assertion"}
	var path: String = OS.get_environment("VWB_ENGINE_INSERTION_REPORT")
	if not path.is_empty():
		var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(report, "  "))
	print("N3_ENGINE_INSERTION_CONTRACT " + ("PASS" if passed else "FAIL"))
	quit(0 if passed else 1)

func _run() -> void:
	_evidence.contract = {"tag":"v1.6x", "commit":"595f52ee4e23203a865eeb981f115909f7aa92f4",
		"archiveSha256":"dfee985a0cff7059a31ada665e88a634fdcc3eab51f83fe5f6dd48939dd5372a",
		"sourceUrl":"https://github.com/Zylann/godot_voxel/blob/595f52ee4e23203a865eeb981f115909f7aa92f4/terrain/fixed_lod/voxel_terrain.cpp",
		"queryLines":"316-326,2243-2260", "insertionLines":"1691-1716,2222-2240",
		"installedBinarySourceMatch":"unverified", "rejectionReason":"not exposed by public publisher"}
	_main = MAIN.new()
	_main.set("seed_text", "n3-n5-trusted-edit-release")
	_main.set("seed_hash", _main.call("hash_string", _main.get("seed_text")))
	_main.call("setup_noise")
	_main.set("structure_system", STRUCTURES.new())
	_admission = _main.get("structure_system").get("citadel_terrain_admission")
	_admission.call("configure", _main.get("seed_text"), {},
		{"regionCells":MAIN.STRUCTURE_REGION_CELLS, "spawnChance":MAIN.STRUCTURE_SPAWN_CHANCE})
	_main.set("town_region_cache", {Vector2i(2, -1): {"centerX":2 * MAIN.TOWN_REGION_CELLS,
		"centerZ":-MAIN.TOWN_REGION_CELLS, "radius":MAIN.TOWN_RADIUS_CELLS, "level":MAIN.WATER_LEVEL + 3.0}})
	var towns: Dictionary = _admission.call("finalize_town_inputs", _main.get("town_region_cache"))
	_check("finalized_real_admission", towns.get("status") == "ready")
	_main.set("world_generation_system", WORLD.new())
	_main.get("world_generation_system").call("setup", _main)
	_scene = Node3D.new()
	root.add_child(_scene)
	_terrain = VoxelTerrain.new()
	_terrain.automatic_loading_enabled = false
	_terrain.generate_collisions = false
	_terrain.mesh_block_size = 16
	_terrain.scale = Vector3.ONE * 1.35
	var format: VoxelFormat = VoxelFormat.new()
	format.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	_terrain.set_format(format)
	var mesher: VoxelMesherTransvoxel = VoxelMesherTransvoxel.new()
	mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_SINGLE_S4
	mesher.transitions_enabled = false
	_terrain.mesher = mesher
	_scene.add_child(_terrain)
	var camera: Camera3D = Camera3D.new()
	camera.position = Vector3(24, 32, 40)
	camera.current = true
	_scene.add_child(camera)
	camera.look_at(Vector3.ZERO)
	_scene.add_child(DirectionalLight3D.new())
	_gate = GATE.new()
	_gate.call("setup", _scene, _terrain, _admission, _main.get("world_generation_system"), true)
	_viewer = VoxelViewer.new()
	_viewer.requires_visuals = true
	_viewer.requires_collisions = true
	var admitted: bool = false
	var admission_deadline: int = Time.get_ticks_msec() + 45000
	for frame in range(600):
		if Time.get_ticks_msec() >= admission_deadline: break
		admitted = bool(_gate.call("request_viewer", _viewer, Vector3.ZERO, VIEW_DISTANCE))
		if admitted or not String(_gate.call("failure_reason")).is_empty(): break
		_gate.call("advance")
		await process_frame
	_evidence.admission = {"admitted":admitted, "gateCurrent":_gate.call("current"),
		"failure":_gate.call("failure_reason"), "viewerAttached":_viewer.get_parent() == _scene,
		"scope":"production gate admission/attachment; not paired data-box coverage"}
	_check("real_viewer_admitted_and_attached", admitted and _viewer.is_inside_tree()
		and _viewer.get_parent() == _scene and bool(_gate.call("current")))
	if not admitted:
		await _finish()
		return
	_backend = ClassDB.instantiate("NativeWorldBackend")
	_check("native_backend_nonzero_opaque_id", _backend != null and _backend.get_instance_id() != 0)
	if _backend == null:
		await _finish()
		return
	var source: Dictionary = SOURCE.from_finalized_main(_main)
	_check("public_finalized_source_ready", source.get("status") == "ready")
	var initialized: Dictionary = _backend.call("initialize", source.get("request", {})) if source.get("status") == "ready" else {}
	_evidence.nativeInitialization = _bounded(initialized)
	_check("native_backend_initialized", initialized.get("status") == "ready")
	_pages = PAGES.new()
	var page_setup: Dictionary = _pages.call("setup", _backend, _admission)
	_publisher = PUBLISHER.new()
	var publisher_setup: Dictionary = _publisher.call("setup", _backend, _terrain, _pages, CONSUMER_ID, 10)
	_publisher_ready = publisher_setup.get("status") == "ready"
	_check("public_publisher_setup", initialized.get("status") == "ready"
		and page_setup.get("status") == "ready" and _publisher_ready)
	if not bool(_checks.public_publisher_setup):
		await _finish()
		return
	_evidence.geometryBefore = _bounded(_geometry())
	var coverage: Dictionary = _area(CONTROL)
	var coverage_deadline: int = Time.get_ticks_msec() + 10000
	for frame in range(120):
		if coverage.get("pairedDataBoxCoverage") == true or Time.get_ticks_msec() >= coverage_deadline: break
		await process_frame
		coverage = _area(CONTROL)
	_check("actual_control_data_box_coverage", coverage.get("pairedDataBoxCoverage") == true)
	_check("actual_outside_data_box_not_covered", _area(OUTSIDE).get("pairedDataBoxCoverage") == false)
	_check("native_and_engine_data_size_match", _terrain.get_data_block_size() == 16)
	var control_add: Array[Vector3i] = [CONTROL]
	var no_remove: Array[Vector3i] = []
	var control_demand: Dictionary = _publisher.call("apply_data_block_delta", control_add, no_remove)
	_check("control_demand_ready", control_demand.get("status") == "ready")
	var control_result: Dictionary = await _pump_case(CONTROL, true, 600)
	_evidence.control = control_result
	_check("covered_control_accepted_via_publisher", control_result.terminal == "accepted"
		and int(control_result.coveredAcceptedReceipts) > 0
		and control_result.finalCoverage.get("pairedDataBoxCoverage") == true
		and bool(control_result.finalHasEngineData) and int(control_result.finalInstalledGeneration) > 0)
	var outside_add: Array[Vector3i] = [OUTSIDE]
	var outside_demand: Dictionary = _publisher.call("apply_data_block_delta", outside_add, no_remove)
	_check("outside_demand_ready", outside_demand.get("status") == "ready")
	var outside_result: Dictionary = await _pump_case(OUTSIDE, false, 240)
	_evidence.outside = outside_result
	_check("uncovered_block_rejected_via_publisher", outside_result.terminal == "three_rejections"
		and int(outside_result.uncoveredRejectedReceipts) == 3
		and outside_result.finalCoverage.get("pairedDataBoxCoverage") == false
		and not bool(outside_result.finalHasEngineData) and int(outside_result.acceptedReceipts) == 0)
	_check("covered_control_still_resident", _terrain.has_data_block(CONTROL)
		and int(_publisher.call("installed_generation", CONTROL)) > 0)
	_evidence.geometryAfter = _bounded(_geometry())
	_check("identical_geometry_and_backend", _evidence.geometryBefore == _evidence.geometryAfter)
	await _finish()
