extends SceneTree

const MAIN = preload("res://scripts/Main.gd")
const STRUCTURES = preload("res://scripts/StructureSystem.gd")
const WORLD = preload("res://scripts/WorldGenerationSystem.gd")
const REQUEST = preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const PAGES = preload("res://scripts/world/NativeShapingPageAdmission.gd")
const PLANNER = preload("res://scripts/terrain/NativeTerrainDemandPlanner.gd")
const PRODUCER = preload("res://scripts/terrain/NativeTerrainTriangleArtifactProducer.gd")
const ARTIFACT_REQUESTS = preload("res://scripts/terrain/NativeTerrainArtifactRequests.gd")

var failures: Array[String] = []

func check(value: bool, label: String) -> void:
	if not value: failures.append(label)

func _init() -> void:
	call_deferred("run")

func analytic_seam(block_x: int, cell_meters: float) -> Dictionary:
	var format := VoxelFormat.new()
	format.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	var buffer: VoxelBuffer = format.create_buffer(Vector3i.ONE * 19)
	for z in range(19):
		for y in range(19):
			for x in range(19):
				buffer.set_voxel_f(float(y) - 9.5, x, y, z, VoxelBuffer.CHANNEL_SDF)
	var mesher := VoxelMesherTransvoxel.new()
	mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_SINGLE_S4
	mesher.transitions_enabled = false
	mesher.mesh_optimization_enabled = false
	var started := Time.get_ticks_usec()
	var mesh: Mesh = mesher.build_mesh(buffer, [])
	var elapsed := Time.get_ticks_usec() - started
	var seam := {}
	for local in mesh.get_faces():
		var world: Vector3 = Vector3(float(block_x * 16),0,0) * cell_meters \
			+ local * cell_meters
		if absf(world.x) < 0.0001:
			seam[Vector2(world.y, world.z)] = true
	return {"bounds":mesh.get_aabb(), "seam":seam, "buildUsec":elapsed}

func run() -> void:
	var main = MAIN.new()
	main.seed_text = "n3-triangle-artifact"
	main.seed_hash = main.hash_string(main.seed_text)
	main.setup_noise()
	main.structure_system = STRUCTURES.new()
	main.structure_system.citadel_terrain_admission.configure(main.seed_text, {},
		{"regionCells":main.STRUCTURE_REGION_CELLS,
			"spawnChance":main.STRUCTURE_SPAWN_CHANCE})
	main.world_generation_system = WORLD.new()
	main.world_generation_system.setup(main)
	var empty_volume := {"schemaVersion":1, "sectionSize":16, "revision":0, "sections":[]}
	var source: Dictionary = REQUEST.from_main_with_save_volume(main, empty_volume)
	var backend = ClassDB.instantiate("NativeWorldBackend")
	check(source.get("status") == "ready" and backend != null
		and backend.initialize_from_save_v2(source.get("request", {})).get("status") == "ready",
		"native source initializes from exact empty v2 volume")
	var pages = PAGES.new()
	check(pages.setup(backend, main.structure_system.citadel_terrain_admission).get("status") == "ready",
		"source-bound shaping pages admitted")
	var planner = PLANNER.new()
	check(planner.setup(71).get("status") == "ready", "native mesh demand planner starts")
	var surface: float = main.world_generation_system.surface_y_for_cell(Vector3i.ZERO)
	var y_cell := floori(surface / main.CELL)
	var block := Vector3i(0, floori(float(y_cell) / 16.0), 0)
	var bounds := Vector2i(block.y * 16, block.y * 16)
	var viewer := {"position":Vector3.ZERO, "distance":0}
	var planned: Dictionary = planner.replace_sources(viewer, [], [], [], bounds)
	var required: Dictionary = planner.required_collision_mesh_blocks()
	check(planned.get("status") == "ready" and required.get("blocks", []) == [block],
		"pinned demand declares one exact required mesh block")
	var identical: Dictionary = planner.replace_sources(viewer, [], [], [], bounds)
	check(identical.get("demandRevision") == planned.get("demandRevision")
		and identical.get("closureToken") == planned.get("closureToken"),
		"identical demand refresh retains physical identity")
	var producer = PRODUCER.new()
	var identity := {"ownerGeneration":1, "sourceRevision":0,
		"cancellationEpoch":1, "sourceEpoch":"n3-triangle-source-1"}
	check(producer.setup(backend, pages, main.structure_system.citadel_terrain_admission,
		planner, main.CELL, identity).get("status") == "ready",
		"triangle producer binds exact source and demand")
	check(producer.collision_source_snapshot().get("status") == "pending",
		"missing triangle artifact cannot claim complete resident source")
	check(producer.request_block(block).get("status") == "pending",
		"required block accepted")
	var produced: Dictionary = {}
	var max_step_usec := 0
	for frame in range(300):
		var started := Time.get_ticks_usec()
		produced = producer.advance()
		max_step_usec = maxi(max_step_usec, Time.get_ticks_usec() - started)
		if produced.get("status") == "ready" or produced.get("status") == "failed": break
		await process_frame
	var row: Dictionary = produced.get("row", {})
	var snapshot: Dictionary = producer.collision_source_snapshot()
	check(produced.get("status") == "ready" and row.get("block") == block
		and row.get("sourceIdentity") == backend.status().get("sourceIdentity")
		and row.get("nativeRevision") == 0
		and row.get("coordinateFrame") == "world",
		"native padded bytes become source-matched world triangle artifact")
	check(snapshot.get("status") == "ready"
		and snapshot.get("requiredResidentBlocks") == [block]
		and snapshot.get("residentBlocks") == [block]
		and snapshot.get("artifacts", {}).get(block) == row.get("artifactKey")
		and snapshot.get("membershipProvenance", {}).get("closureToken") == planned.get("closureToken"),
		"complete source snapshot keeps required and produced membership separate")
	var vertices: PackedVector3Array = row.get("vertices", PackedVector3Array())
	check(vertices.size() % 3 == 0 and vertices.size() <= 65536,
		"triangle topology and capacity are bounded")
	var owned_row: Dictionary = producer.collision_artifact_row(block, identity)
	var copied_row: Dictionary = owned_row.get("row", {})
	if not vertices.is_empty():
		var changed_vertices: PackedVector3Array = copied_row.get("vertices", PackedVector3Array())
		changed_vertices[0] += Vector3.UP
		copied_row["vertices"] = changed_vertices
	check(owned_row.get("status") == "ready"
		and producer.collision_artifact_row(block, identity).get("row", {}) == row,
		"caller mutation cannot alter source-owned triangle row")
	var other_main = MAIN.new()
	other_main.seed_text = "n3-triangle-other-seed"
	other_main.seed_hash = other_main.hash_string(other_main.seed_text)
	other_main.setup_noise()
	other_main.structure_system = STRUCTURES.new()
	other_main.structure_system.citadel_terrain_admission.configure(other_main.seed_text, {},
		{"regionCells":other_main.STRUCTURE_REGION_CELLS,
			"spawnChance":other_main.STRUCTURE_SPAWN_CHANCE})
	var other_source: Dictionary = REQUEST.from_main_with_save_volume(other_main, empty_volume)
	var other_backend = ClassDB.instantiate("NativeWorldBackend")
	check(other_source.get("status") == "ready" and other_backend.initialize_from_save_v2(
		other_source.get("request", {})).get("status") == "ready"
		and other_backend.status().get("terrainDeltaRevision") == 0,
		"different native source can share the same delta revision")
	producer._backend = other_backend
	check(producer.collision_source_snapshot().get("status") != "ready"
		and producer.collision_artifact_row(block, identity).get("status") != "ready",
		"same-revision different-seed backend cannot reuse old triangles")
	producer._backend = backend
	var switched_producer = PRODUCER.new()
	check(switched_producer.setup(backend, pages,
		main.structure_system.citadel_terrain_admission, planner, main.CELL,
		identity).get("status") == "ready"
		and switched_producer.request_block(block).get("status") == "pending",
		"source-switch advance probe starts from pinned backend")
	switched_producer._backend = other_backend
	check(switched_producer.advance().get("reason") == "triangle_source_revision_changed",
		"advance rejects same-revision different-seed backend")
	switched_producer.stop()
	other_main.free()
	var left_seam: Dictionary = analytic_seam(-1, main.CELL)
	var right_seam: Dictionary = analytic_seam(0, main.CELL)
	check(left_seam.bounds.position.x == 0.0 and right_seam.bounds.position.x == 0.0
		and is_equal_approx(float(left_seam.bounds.size.x), 16.0)
		and is_equal_approx(float(right_seam.bounds.size.x), 16.0)
		and not left_seam.seam.is_empty() and left_seam.seam == right_seam.seam,
		"negative and adjacent padded Transvoxel blocks meet at one world seam")
	var stale_producer = PRODUCER.new()
	check(stale_producer.setup(backend, pages, main.structure_system.citadel_terrain_admission,
		planner, main.CELL, identity).get("status") == "ready"
		and stale_producer.request_block(block).get("status") == "pending",
		"second producer captures source before edited revision")
	var in_flight: Dictionary = {}
	for frame in range(100):
		in_flight = stale_producer.advance()
		if in_flight.get("reason") == "triangle_encode_in_flight": break
		await process_frame
	var edit_state := {"materialId":3, "biomeId":13, "fluidId":0,
		"solid":true, "density":1.5, "light":Vector2i.ZERO,
		"metadata":{"saveDelta":true,"source":"terrain_edit"},
		"blockId":"triangle-revision-edit", "editReason":"contract"}
	var committed: Dictionary = backend.commit_durable_cells({
		"schema":"n3-native-durable-cell-transaction/v1",
		"transactionId":"triangle:revision-change", "expectedRevision":0,
		"operations":[{"kind":"set", "cell":Vector3i(1000,-1,1000), "state":edit_state}]})
	var stale_step: Dictionary = stale_producer.advance()
	check(in_flight.get("reason") == "triangle_encode_in_flight"
		and committed.get("commitStatus") == "committed"
		and stale_step.get("reason") == "triangle_worker_draining"
		and stale_producer.request_block(block).get("status") == "failed",
		"revision change drains old ticket and rejects immediate retry")
	for frame in range(100):
		if stale_step.get("status") == "failed": break
		await process_frame
		stale_step = stale_producer.advance()
	check(stale_step.get("status") == "failed"
		and stale_step.get("reason") == "triangle_source_revision_changed"
		and stale_producer.request_block(block).get("status") == "failed",
		"stale worker cannot later attach old triangles to a new block")
	stale_producer.stop()
	var changed: Dictionary = planner.replace_sources({"position":Vector3(-main.CELL,0,-main.CELL),
		"distance":0}, [], [], [], bounds)
	check(changed.get("status") == "ready"
		and changed.get("demandRevision") != planned.get("demandRevision")
		and producer.collision_source_snapshot().get("status") != "ready",
		"negative demand change invalidates prior source snapshot")
	var readded: Dictionary = planner.replace_sources(viewer, [], [], [], bounds)
	check(readded.get("demandRevision") != planned.get("demandRevision")
		and readded.get("closureToken") != planned.get("closureToken"),
		"remove and readd creates a new source-bound demand identity")
	var new_epoch_producer = PRODUCER.new()
	var new_identity := {"ownerGeneration":2, "sourceRevision":1,
		"cancellationEpoch":2, "sourceEpoch":"n3-triangle-source-2"}
	check(new_epoch_producer.setup(backend, pages,
		main.structure_system.citadel_terrain_admission, planner, main.CELL,
		new_identity).get("status") == "ready"
		and new_epoch_producer.collision_source_snapshot().get("identity", {}).get("sourceEpoch")
			== "n3-triangle-source-2",
		"new source epoch cannot inherit prior physical identity")
	new_epoch_producer.request_block(block)
	var refreshed: Dictionary = {}
	for frame in range(300):
		refreshed = new_epoch_producer.advance()
		if refreshed.get("status") == "ready" or refreshed.get("status") == "failed": break
		await process_frame
	check(refreshed.get("status") == "ready"
		and refreshed.get("row", {}).get("artifactKey") == row.get("artifactKey")
		and refreshed.get("row", {}).get("nativeRevision") == 1,
		"unaffected block keeps content key across global edit while revision refreshes")
	new_epoch_producer.stop()
	var high_block := Vector3i(0, 8, 0)
	var high_demand: Dictionary = planner.replace_sources(viewer, [], [], [], Vector2i(128,128))
	var empty_producer = PRODUCER.new()
	check(high_demand.get("status") == "ready"
		and empty_producer.setup(backend, pages,
			main.structure_system.citadel_terrain_admission, planner, main.CELL,
			{"ownerGeneration":3, "sourceRevision":1,
				"cancellationEpoch":3, "sourceEpoch":"n3-triangle-source-3"}).get("status") == "ready"
		and empty_producer.request_block(high_block).get("status") == "pending",
		"high empty block is independently required by pinned demand")
	var empty_result: Dictionary = {}
	for frame in range(300):
		empty_result = empty_producer.advance()
		if empty_result.get("status") == "ready" or empty_result.get("status") == "failed": break
		await process_frame
	var empty_row: Dictionary = empty_result.get("row", {})
	var empty_snapshot: Dictionary = empty_producer.collision_source_snapshot()
	check(empty_result.get("status") == "ready" and empty_row.get("empty") == true
		and empty_row.get("expectedHit") == false
		and (empty_row.get("vertices", PackedVector3Array()) as PackedVector3Array).is_empty()
		and empty_row.get("probeFrom") != empty_row.get("probeTo")
		and empty_snapshot.get("status") == "ready",
		"empty native block carries exact no-shape artifact and in-bounds probe")
	var empty_stop: Dictionary = empty_producer.stop()
	for frame in range(120):
		if empty_stop.get("status") == "ready": break
		await process_frame
		empty_stop = empty_producer.drain_step()
	check(empty_stop.get("status") == "ready", "empty producer drains")
	var requests = ARTIFACT_REQUESTS.new()
	check(requests.setup(backend, pages, main.structure_system.citadel_terrain_admission,
		planner, main.CELL, 77, 4096).get("status") == "ready"
		and requests.request_block(high_block).get("status") == "pending",
		"composed source owner retains a demanded request")
	var requested: Dictionary = {}
	for frame in range(300):
		requested = requests.advance()
		if requested.get("status") == "ready" and requested.has("row"): break
		await process_frame
	var request_snapshot: Dictionary = requests.collision_source_snapshot()
	check(requested.get("status") == "ready"
		and requested.get("row", {}).get("block") == high_block
		and request_snapshot.get("status") == "ready"
		and requests.collision_artifact_row(high_block,
			request_snapshot.get("identity", {})).get("status") == "ready",
		"composed queue forwards source-bound row and complete demand identity")
	var changed_request_demand: Dictionary = planner.replace_sources(viewer, [], [], [], bounds)
	check(changed_request_demand.get("status") == "ready"
		and requests.request_block(block).get("status") == "pending",
		"new demand request retained before previous producer retirement")
	var replacement: Dictionary = {}
	for frame in range(300):
		replacement = requests.advance()
		if replacement.get("status") == "ready" and replacement.has("row"): break
		await process_frame
	check(replacement.get("status") == "ready"
		and replacement.get("row", {}).get("block") == block
		and requests.collision_source_snapshot().get("status") == "ready",
		"demand change retires old producer and retries new requested block")
	var broker_idle: Dictionary = requests.advance()
	check(broker_idle.get("status") == "pending"
		and broker_idle.get("reason") == "artifact_queue_idle"
		and broker_idle.get("sourceComplete") == true,
		"idle request queue cannot masquerade as physical readiness")
	var request_stop: Dictionary = requests.stop()
	for frame in range(120):
		if request_stop.get("status") == "ready": break
		await process_frame
		request_stop = requests.drain_step()
	check(request_stop.get("status") == "ready", "composed request worker drains")
	var bounded = ARTIFACT_REQUESTS.new()
	check(bounded.setup(backend, pages, main.structure_system.citadel_terrain_admission,
		planner, main.CELL, 78, 1).get("status") == "ready",
		"resident capacity is explicit at the source request boundary")
	var extra_viewers: Array[Dictionary] = [{"kind":"secondary", "id":"neighbor",
		"position":Vector3(main.CELL * 256.0, 0, 0), "distance":0}]
	var two_demand: Dictionary = planner.replace_sources(viewer, extra_viewers, [], [], bounds)
	check(two_demand.get("status") == "ready"
		and bounded.request_block(block).get("status") == "pending",
		"oversized demand still retains explicitly requested block")
	var partition_step: Dictionary = bounded.advance()
	var partition_layout: Dictionary = bounded.collision_window_layout()
	check(partition_step.get("status") == "pending"
		and int(partition_layout.get("requiredBlockCount", 0)) == 2
		and int(partition_layout.get("windowCount", 0)) == 2
		and bounded.collision_source_snapshot().get("reason") \
			== "partitioned_source_requires_window",
		"oversized logical closure requires exact spatial window sources")
	var near_source
	var remote_source
	var near_token := ""
	var remote_token := ""
	for window: Dictionary in partition_layout.windows:
		var acquired: Dictionary = bounded.collision_window_source(window.id,
			String(partition_layout.layoutToken))
		check(acquired.get("status") == "ready", "spatial window facade acquired")
		if (window.blocks as Array).has(block):
			near_source = acquired.get("source")
			near_token = String(window.windowToken)
		else:
			remote_source = acquired.get("source")
			remote_token = String(window.windowToken)
	var near_result := {}
	for frame in range(300):
		near_result = bounded.advance()
		if near_result.get("status") == "ready" and near_result.has("row"): break
		await process_frame
	check(near_result.get("status") == "ready"
		and near_source.collision_source_snapshot().get("status") == "ready"
		and remote_source.collision_source_snapshot().get("status") == "pending",
		"one complete spatial window does not falsely complete other window")
	planner.replace_sources(viewer, [], [], [], bounds)
	var resumed: Dictionary = bounded.advance()
	var smaller_layout: Dictionary = bounded.collision_window_layout()
	check(resumed.get("status") == "pending"
		and smaller_layout.get("layoutToken") != partition_layout.get("layoutToken")
		and (smaller_layout.windows as Array).size() == 1
		and smaller_layout.windows[0].windowToken == near_token
		and near_source.collision_source_snapshot().get("status") == "ready"
		and remote_source.collision_source_snapshot().get("status") == "pending",
		"distant demand retirement preserves unchanged near window identity")
	check(bounded.acknowledge_collision_window_retired(remote_token, {}).get("status") == "failed"
		and bounded.acknowledge_collision_window_retired(remote_token,
			{"windowToken":remote_token, "drained":true,
				"remainingBodies":0}).get("status") == "ready",
		"old window retained until explicit physical drain acknowledgment")
	var bounded_stop: Dictionary = bounded.stop()
	for frame in range(120):
		if bounded_stop.get("status") == "ready": break
		await process_frame
		bounded_stop = bounded.drain_step()
	check(bounded_stop.get("status") == "ready", "partitioned broker worker drains")
	var large_planner = PLANNER.new()
	large_planner.setup(79)
	var large_demand: Dictionary = large_planner.replace_sources(
		{"position":Vector3.ZERO, "distance":128}, [], [], [], Vector2i(0,256))
	var large_broker = ARTIFACT_REQUESTS.new()
	check(large_demand.get("status") == "ready"
		and large_broker.setup(backend, pages,
			main.structure_system.citadel_terrain_admission, large_planner,
			main.CELL, 80, 4096).get("status") == "ready",
		"4913-block demand admitted to partition-capable broker")
	var large_step: Dictionary = large_broker.advance()
	var large_layout: Dictionary = large_broker.collision_window_layout()
	var large_union := {}
	for window: Dictionary in large_layout.get("windows", []):
		var facade: Dictionary = large_broker.collision_window_source(window.id,
			String(large_layout.layoutToken))
		check(facade.get("status") == "ready"
			and facade.source.collision_source_snapshot().get("status") == "pending",
			"unbuilt large window is pending, never physical-ready")
		for member: Vector3i in window.blocks: large_union[member] = true
	check(large_step.get("status") == "pending"
		and large_step.get("reason") == "artifact_queue_idle"
		and int(large_layout.get("requiredBlockCount", 0)) == 4913
		and int(large_layout.get("windowCount", 0)) == 8
		and large_union.size() == 4913,
		"4913-block broker exposes complete bounded spatial windows without false readiness")
	check(large_broker.stop().get("status") == "ready", "large broker stops without workers")
	var worker_planner = PLANNER.new()
	worker_planner.setup(81)
	worker_planner.replace_sources(viewer, [], [], [], bounds)
	var worker_producer = PRODUCER.new()
	var worker_identity := {"ownerGeneration":81, "sourceRevision":1,
		"cancellationEpoch":1, "sourceEpoch":"demand-worker-drain"}
	check(worker_producer.setup(backend, pages,
		main.structure_system.citadel_terrain_admission, worker_planner,
		main.CELL, worker_identity).get("status") == "ready"
		and worker_producer.request_block(block).get("status") == "pending",
		"surface producer starts for demand-change worker drain")
	var face_in_flight := false
	for frame in range(300):
		var worker_step: Dictionary = worker_producer.advance()
		if worker_step.get("reason") == "triangle_mesh_in_flight":
			face_in_flight = true
			break
		if worker_step.get("status") == "failed" or worker_step.get("status") == "ready": break
		await process_frame
	check(face_in_flight, "demand change reaches actual mesh face worker")
	worker_planner.replace_sources(viewer, [], [], [], Vector2i(128,128))
	var worker_rebound := {}
	for frame in range(120):
		worker_rebound = worker_producer.rebind_demand()
		if worker_rebound.get("status") == "ready" or worker_rebound.get("status") == "failed": break
		await process_frame
	var rebound_snapshot: Dictionary = worker_producer.collision_source_snapshot()
	check(worker_rebound.get("status") == "ready"
		and rebound_snapshot.get("status") == "pending"
		and (rebound_snapshot.get("residentBlocks", []) as Array).is_empty()
		and worker_producer.collision_artifact_row(block, worker_identity).get("status") != "ready",
		"demand rebind drains face worker without publishing removed block")
	var worker_stop: Dictionary = worker_producer.stop()
	for frame in range(120):
		if worker_stop.get("status") == "ready": break
		await process_frame
		worker_stop = worker_producer.drain_step()
	check(worker_stop.get("status") == "ready", "rebound producer drains")
	var remote_page := Vector2i.ZERO
	var remote_candidate := {}
	for page_index in range(2, 7):
		var trial_page := Vector2i(page_index, page_index)
		var trial: Dictionary = backend.shaping_requests(trial_page)
		if not (trial.get("requests", []) as Array).is_empty():
			remote_page = trial_page
			remote_candidate = trial.requests[0]
			break
	check(not remote_candidate.is_empty(), "distant unresolved shaping source found")
	if not remote_candidate.is_empty():
		var remote_block := Vector3i(floori(float(remote_page.x * 280 + 16) / 16.0), 8,
			floori(float(remote_page.y * 280 + 16) / 16.0))
		var remote_viewers: Array[Dictionary] = [{"kind":"secondary", "id":"remote",
			"position":Vector3(remote_block.x * 16, 0, remote_block.z * 16) * main.CELL,
			"distance":0}]
		var both: Dictionary = planner.replace_sources(viewer, remote_viewers, [], [],
			Vector2i(128,128))
		var local_producer = PRODUCER.new()
		check(both.get("status") == "ready" and local_producer.setup(backend, pages,
			main.structure_system.citadel_terrain_admission, planner, main.CELL,
			{"ownerGeneration":79, "sourceRevision":1,
				"cancellationEpoch":1, "sourceEpoch":"local-page-pins"}).get("status") == "ready",
			"two distant blocks share one pinned terrain revision")
		local_producer.request_block(high_block)
		var local_result := {}
		for frame in range(300):
			local_result = local_producer.advance()
			if local_result.get("status") == "ready" or local_result.get("status") == "failed": break
			await process_frame
		var before_registry := int(backend.status().get("shapingRegistryRevision", -1))
		var remote_resolution := {"region":remote_candidate.region,
			"requestIdentity":remote_candidate.requestIdentity,
			"workerSourceKey":remote_candidate.workerSourceKey,
			"kind":"absent", "reasonCode":"n3_remote_page_contract_absent"}
		var remote_change: Dictionary = backend.apply_shaping_resolutions([remote_resolution])
		var local_identity: Dictionary = local_producer.collision_source_snapshot().get("identity", {})
		check(local_result.get("status") == "ready"
			and remote_change.get("commitStatus") == "committed"
			and int(backend.status().get("shapingRegistryRevision", -1)) > before_registry
			and local_producer.collision_artifact_row(high_block, local_identity).get("status") == "ready",
			"remote shaping revision preserves unchanged local triangle row")
		local_producer.request_block(remote_block)
		var remote_result := {}
		for frame in range(500):
			remote_result = local_producer.advance()
			if remote_result.get("status") == "ready" or remote_result.get("status") == "failed": break
			await process_frame
		check(remote_result.get("status") == "ready"
			and local_producer.collision_source_snapshot().get("status") == "ready"
			and local_producer.collision_artifact_row(high_block, local_identity).get("status") == "ready",
			"distant block admission preserves first row and completes closure")
		var local_stop: Dictionary = local_producer.stop()
		for frame in range(120):
			if local_stop.get("status") == "ready": break
			await process_frame
			local_stop = local_producer.drain_step()
		check(local_stop.get("status") == "ready", "distant page producer drains")
	var stopped: Dictionary = producer.stop()
	for frame in range(120):
		if stopped.get("status") == "ready": break
		await process_frame
		stopped = producer.drain_step()
	check(stopped.get("status") == "ready", "triangle producer drains")
	main.free()
	var report := {"schema":"n3-triangle-artifact-contract/v1",
		"passed":failures.is_empty(), "evidenceLevel":"native-voxel-tools-service-contract",
		"productionCutover":false, "failures":failures,
		"maxAdvanceUsec":max_step_usec, "vertexCount":vertices.size(),
		"bufferUsec":produced.get("bufferUsec", 0),
		"meshUsec":produced.get("meshUsec", 0),
		"facesUsec":produced.get("facesUsec", 0),
		"vertexCopyUsec":produced.get("vertexCopyUsec", 0),
		"finalizeUsec":produced.get("finalizeUsec", 0),
		"emptyBufferUsec":empty_result.get("bufferUsec", 0),
		"emptyMeshUsec":empty_result.get("meshUsec", 0),
		"emptyFacesUsec":empty_result.get("facesUsec", 0),
		"emptyVertexCopyUsec":empty_result.get("vertexCopyUsec", 0),
		"emptyFinalizeUsec":empty_result.get("finalizeUsec", 0),
		"maxAnalyticBuildUsec":maxi(int(left_seam.buildUsec), int(right_seam.buildUsec)),
		"emptyStatus":empty_result.get("status", ""),
		"emptyReason":empty_result.get("reason", ""),
		"emptyVertexCount":(empty_row.get("vertices", PackedVector3Array()) as PackedVector3Array).size(),
		"emptySnapshotStatus":empty_snapshot.get("status", ""),
		"emptyArtifact":bool(row.get("empty", false))}
	var path := OS.get_environment("VWB_TRIANGLE_ARTIFACT_REPORT")
	if not path.is_empty():
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(report, "\t"))
	quit(0 if failures.is_empty() else 1)
