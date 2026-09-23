extends SceneTree

const MAIN = preload("res://scripts/Main.gd")
const STRUCTURES = preload("res://scripts/StructureSystem.gd")
const WORLD = preload("res://scripts/WorldGenerationSystem.gd")
const REQUEST = preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const PAGES = preload("res://scripts/world/NativeShapingPageAdmission.gd")
const PLANNER = preload("res://scripts/terrain/NativeTerrainDemandPlanner.gd")
const PRODUCER = preload("res://scripts/terrain/NativeTerrainTriangleArtifactProducer.gd")

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
