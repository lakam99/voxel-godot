extends SceneTree

const MAIN = preload("res://scripts/Main.gd")
const STRUCTURES = preload("res://scripts/StructureSystem.gd")
const WORLD = preload("res://scripts/WorldGenerationSystem.gd")
const REQUEST = preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const PAGES = preload("res://scripts/world/NativeShapingPageAdmission.gd")
const PLANNER = preload("res://scripts/terrain/NativeTerrainDemandPlanner.gd")
const PRODUCER = preload("res://scripts/terrain/NativeTerrainTriangleArtifactProducer.gd")
const OWNER = preload("res://scripts/terrain/NativeResidentCollisionOwner.gd")
const BARRIER = preload("res://scripts/terrain/NativeCollisionAdmissionBarrier.gd")

class SourceProxy:
	extends RefCounted
	var active
	func collision_source_snapshot() -> Dictionary:
		return active.collision_source_snapshot()
	func collision_artifact_row(block: Vector3i, identity: Dictionary) -> Dictionary:
		return active.collision_artifact_row(block, identity)

var _started_usec := 0

func _init() -> void:
	_started_usec = Time.get_ticks_usec()
	call_deferred("_run")

func _run() -> void:
	var main = MAIN.new()
	main.seed_text = "n3-n5-physical-handoff"
	main.seed_hash = main.hash_string(main.seed_text)
	main.setup_noise()
	main.structure_system = STRUCTURES.new()
	main.structure_system.citadel_terrain_admission.configure(main.seed_text, {},
		{"regionCells":main.STRUCTURE_REGION_CELLS,
			"spawnChance":main.STRUCTURE_SPAWN_CHANCE})
	main.world_generation_system = WORLD.new()
	main.world_generation_system.setup(main)
	var source_request: Dictionary = REQUEST.from_main_with_save_volume(main,
		{"schemaVersion":1, "sectionSize":16, "revision":0, "sections":[]})
	var backend = ClassDB.instantiate("NativeWorldBackend")
	if source_request.get("status") != "ready" or backend == null:
		_finish(false, {"reason":"native_source_request_failed"})
		return
	var backend_init: Dictionary = backend.initialize_from_save_v2(source_request.request)
	var pages = PAGES.new()
	var page_setup: Dictionary = pages.setup(backend,
		main.structure_system.citadel_terrain_admission)
	var planner = PLANNER.new()
	var planner_setup: Dictionary = planner.setup(71)
	var surface: float = main.world_generation_system.surface_y_for_cell(Vector3i.ZERO)
	var surface_block := Vector3i(0, floori(float(floori(surface / main.CELL)) / 16.0), 0)
	var planned: Dictionary = planner.replace_sources(
		{"position":Vector3.ZERO, "distance":0}, [], [], [],
		Vector2i(surface_block.y * 16, (surface_block.y + 1) * 16))
	var required: Dictionary = planner.required_collision_mesh_blocks()
	var identity := {"ownerGeneration":1, "sourceRevision":0,
		"cancellationEpoch":1, "sourceEpoch":"n3-n5-handoff-1"}
	var producer = PRODUCER.new()
	var setup: Dictionary = producer.setup(backend, pages,
		main.structure_system.citadel_terrain_admission, planner, main.CELL, identity)
	var root_3d := Node3D.new()
	root.add_child(root_3d)
	var owner = OWNER.new()
	root_3d.add_child(owner)
	var proxy := SourceProxy.new()
	proxy.active = producer
	var bound: bool = owner.bind_source(proxy)
	var early: Dictionary = await owner.publish({
		"schema":"n5-resident-collision-publication/v1", "identity":identity,
		"residentBlocks":required.get("blocks", []),
		"affectedBlocks":required.get("blocks", []), "rows":[]})
	var rows: Array[Dictionary] = []
	var steps: Array[Dictionary] = []
	var partial_snapshot: Dictionary = {}
	var max_advance_usec := 0
	var max_advance_result: Dictionary = {}
	if setup.get("status") == "ready" and required.get("status") == "ready":
		for block: Vector3i in required.blocks:
			var requested: Dictionary = producer.request_block(block)
			if requested.get("status") != "pending":
				steps.append(requested)
				break
			var produced: Dictionary = {}
			for frame in range(400):
				var started := Time.get_ticks_usec()
				produced = producer.advance()
				var advance_usec := Time.get_ticks_usec() - started
				if advance_usec > max_advance_usec:
					max_advance_usec = advance_usec
					max_advance_result = {"block":block, "frame":frame,
						"status":produced.get("status"),
						"reason":produced.get("reason", ""),
						"captureUsec":produced.get("captureUsec", -1),
						"workerEncodeUsec":produced.get("workerEncodeUsec", -1),
						"bufferUsec":produced.get("bufferUsec", -1),
						"meshUsec":produced.get("meshUsec", -1),
						"facesUsec":produced.get("facesUsec", -1),
						"vertexCopyUsec":produced.get("vertexCopyUsec", -1)}
				if produced.get("status") == "ready" or produced.get("status") == "failed":
					break
				await process_frame
			steps.append({"status":produced.get("status"),
				"reason":produced.get("reason", ""),
				"meshUsec":produced.get("meshUsec", -1),
				"facesUsec":produced.get("facesUsec", -1),
				"vertexCopyUsec":produced.get("vertexCopyUsec", -1),
				"vertexCount":produced.get("row", {}).get("vertices",
					PackedVector3Array()).size()})
			if produced.get("status") != "ready":
				break
			rows.append(produced.row)
			if rows.size() == 1 and required.blocks.size() > 1:
				partial_snapshot = producer.collision_source_snapshot()
	var snapshot: Dictionary = producer.collision_source_snapshot()
	var reference: Dictionary = await _reference_faces(backend,
		required.blocks[0], main.CELL, rows[0])
	var bounds: AABB = rows[0].bounds if not rows.is_empty() \
		else AABB(Vector3.ZERO, Vector3.ONE)
	for row in rows:
		bounds = bounds.merge(row.bounds)
	var barrier = BARRIER.new()
	var census: Dictionary = barrier.begin(root_3d, owner, identity, bounds)
	while census.get("status") == "pending":
		await process_frame
		census = barrier.census_progress(identity)
	var publication: Dictionary = {}
	if rows.size() == required.get("blocks", []).size() and bound:
		publication = await owner.publish({"schema":"n5-resident-collision-publication/v1",
			"identity":identity, "residentBlocks":required.blocks,
			"affectedBlocks":required.blocks, "rows":rows}, barrier)
	var receipt: Dictionary = owner.physical_receipt(identity)
	var empty_count := 0
	var solid_count := 0
	var contact := false
	for row in rows:
		if bool(row.expectedHit):
			solid_count += 1
			var actor := CharacterBody3D.new()
			actor.collision_mask = 2
			actor.position = row.probeFrom
			var actor_shape := CollisionShape3D.new()
			var sphere := SphereShape3D.new()
			sphere.radius = main.CELL * 0.05
			actor_shape.shape = sphere
			actor.add_child(actor_shape)
			root_3d.add_child(actor)
			await physics_frame
			contact = actor.move_and_collide(row.probeTo - row.probeFrom) != null
			actor.queue_free()
		else:
			empty_count += 1
	await process_frame
	var release: bool = barrier.release(identity)
	var edit_state := {"materialId":3, "biomeId":13, "fluidId":0,
		"solid":true, "density":1.5, "light":Vector2i.ZERO,
		"metadata":{"saveDelta":true,"source":"terrain_edit"},
		"blockId":"physical-handoff-revision", "editReason":"contract"}
	var committed: Dictionary = backend.commit_durable_cells({
		"schema":"n3-native-durable-cell-transaction/v1",
		"transactionId":"physical-handoff:revision-change", "expectedRevision":0,
		"operations":[{"kind":"set", "cell":Vector3i(1000,-1,1000),
			"state":edit_state}]})
	var second_identity := {"ownerGeneration":1, "sourceRevision":1,
		"cancellationEpoch":2, "sourceEpoch":"n3-n5-handoff-2"}
	var second_producer = PRODUCER.new()
	var second_setup: Dictionary = second_producer.setup(backend, pages,
		main.structure_system.citadel_terrain_admission, planner, main.CELL,
		second_identity)
	proxy.active = second_producer
	var stale_readiness: Dictionary = owner.startup_readiness(identity)
	var second_pending: Dictionary = await owner.publish({
		"schema":"n5-resident-collision-publication/v1", "identity":second_identity,
		"residentBlocks":required.blocks, "affectedBlocks":required.blocks,
		"rows":rows})
	var second_rows: Array[Dictionary] = []
	var second_steps: Array[Dictionary] = []
	if second_setup.get("status") == "ready":
		for block: Vector3i in required.blocks:
			if second_producer.request_block(block).get("status") != "pending":
				break
			var second_produced: Dictionary = {}
			for frame in range(400):
				second_produced = second_producer.advance()
				if second_produced.get("status") == "ready" \
						or second_produced.get("status") == "failed":
					break
				await process_frame
			second_steps.append({"status":second_produced.get("status"),
				"reason":second_produced.get("reason", ""),
				"meshUsec":second_produced.get("meshUsec", -1),
				"vertexCopyUsec":second_produced.get("vertexCopyUsec", -1)})
			if second_produced.get("status") != "ready":
				break
			second_rows.append(second_produced.row)
	var second_snapshot: Dictionary = second_producer.collision_source_snapshot()
	var second_barrier = BARRIER.new()
	var second_census: Dictionary = second_barrier.begin(root_3d, owner,
		second_identity, bounds)
	while second_census.get("status") == "pending":
		await process_frame
		second_census = second_barrier.census_progress(second_identity)
	var stale_request: Dictionary = await owner.publish({
		"schema":"n5-resident-collision-publication/v1", "identity":identity,
		"residentBlocks":required.blocks, "affectedBlocks":required.blocks,
		"rows":rows}, second_barrier)
	var second_publication: Dictionary = {}
	if second_rows.size() == required.blocks.size():
		second_publication = await owner.publish({
			"schema":"n5-resident-collision-publication/v1",
			"identity":second_identity, "residentBlocks":required.blocks,
			"affectedBlocks":required.blocks, "rows":second_rows}, second_barrier)
	var second_receipt: Dictionary = owner.physical_receipt(second_identity)
	var second_release: bool = second_barrier.release(second_identity)
	var cancellation_probe = PRODUCER.new()
	var cancellation_setup: Dictionary = cancellation_probe.setup(backend, pages,
		main.structure_system.citadel_terrain_admission, planner, main.CELL,
		second_identity)
	var cancellation_requested: Dictionary = cancellation_probe.request_block(
		required.blocks[0])
	var cancellation_in_flight: Dictionary = {}
	for frame in range(400):
		cancellation_in_flight = cancellation_probe.advance()
		if cancellation_in_flight.get("reason") == "triangle_mesh_in_flight" \
				or cancellation_in_flight.get("status") == "failed":
			break
		await process_frame
	var cancellation_stop: Dictionary = cancellation_probe.stop()
	var cancellation_drain: Dictionary = {}
	for frame in range(400):
		cancellation_drain = cancellation_probe.drain_step()
		if cancellation_drain.get("status") == "ready" \
				or cancellation_drain.get("status") == "failed":
			break
		await process_frame
	var drained: Dictionary = await owner.stop_and_drain()
	producer.stop()
	second_producer.stop()
	root_3d.queue_free()
	main.free()
	var passed: bool = backend_init.get("status") == "ready" \
		and page_setup.get("status") == "ready" and planner_setup.get("status") == "ready" \
		and planned.get("status") == "ready" and setup.get("status") == "ready" \
		and early.get("status") == "pending" \
		and early.get("reason") == "triangle_artifacts_incomplete" \
		and partial_snapshot.get("status") == "pending" \
		and partial_snapshot.get("requiredResidentBlocks") == required.blocks \
		and partial_snapshot.get("residentBlocks", []).size() == 1 \
		and snapshot.get("status") == "ready" and rows.size() == required.blocks.size() \
		and snapshot.get("requiredResidentBlocks") == required.blocks \
		and snapshot.get("residentBlocks") == required.blocks \
		and snapshot.get("identity") == identity \
		and snapshot.get("membershipProvenance", {}).get("closureToken") \
			== planned.get("closureToken") \
		and bool(reference.get("exact", false)) \
		and int(reference.get("vertexCount", -1)) == rows[0].vertices.size() \
		and solid_count > 0 and empty_count > 0 \
		and publication.get("status") == "ready" \
		and bool(receipt.get("ready", false)) and contact and release \
		and committed.get("commitStatus") == "committed" \
		and second_setup.get("status") == "ready" \
		and stale_readiness.get("status") == "pending" \
		and second_pending.get("status") == "pending" \
		and second_snapshot.get("status") == "ready" \
		and stale_request.get("status") != "ready" \
		and second_publication.get("status") == "ready" \
		and bool(second_receipt.get("ready", false)) and second_release \
		and cancellation_setup.get("status") == "ready" \
		and cancellation_requested.get("status") == "pending" \
		and cancellation_in_flight.get("reason") == "triangle_mesh_in_flight" \
		and cancellation_stop.get("status") == "pending" \
		and cancellation_drain.get("status") == "ready" \
		and drained.get("status") == "ready"
	_finish(passed, {"backendInit":backend_init, "planned":planned,
		"requiredBlocks":required.get("blocks", []), "earlyPending":early,
		"partialSnapshot":partial_snapshot, "sourceSnapshot":snapshot,
		"synchronousFaceReference":reference,
		"steps":steps, "maxAdvanceUsec":max_advance_usec,
		"maxAdvanceResult":max_advance_result,
		"surfaceBlock":surface_block, "rowCount":rows.size(),
		"solidCount":solid_count, "emptyCount":empty_count,
		"publication":publication, "physicalReceipt":receipt,
		"actorContact":contact, "barrierReleased":release,
		"committed":committed, "staleReadiness":stale_readiness,
		"secondPending":second_pending, "secondSteps":second_steps,
		"secondSnapshot":second_snapshot, "staleRequest":stale_request,
		"secondPublication":second_publication,
		"secondReceipt":second_receipt, "secondRelease":second_release,
		"workerCancellation": {"setup":cancellation_setup,
			"requested":cancellation_requested,
			"inFlight":cancellation_in_flight, "stop":cancellation_stop,
			"drain":cancellation_drain},
		"drained":drained})

func _reference_faces(backend, block: Vector3i, cell_meters: float,
		row: Dictionary) -> Dictionary:
	var began: Dictionary = backend.begin_voxel_block_shadow_async({
		"schema":"n3-effective-voxel-block-request/v1",
		"origin":block * 16 - Vector3i.ONE,
		"size":Vector3i.ONE * 19, "lod":0})
	if began.get("status") != "pending":
		return {"status":"failed", "reason":"reference_begin_failed"}
	var encoded: Dictionary = {}
	for frame in range(400):
		encoded = backend.poll_voxel_block_shadow_async(int(began.ticket))
		if encoded.get("status") == "ready" or encoded.get("status") == "failed":
			break
		await process_frame
	if encoded.get("status") != "ready":
		return {"status":"failed", "reason":"reference_encode_failed"}
	var format := VoxelFormat.new()
	format.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	var buffer: VoxelBuffer = format.create_buffer(Vector3i.ONE * 19)
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_SDF, encoded.sdf16Le)
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_INDICES, encoded.indices8)
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_DATA5, encoded.data5_8)
	var mesher := VoxelMesherTransvoxel.new()
	mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_SINGLE_S4
	mesher.transitions_enabled = false
	mesher.mesh_optimization_enabled = false
	var mesh: Mesh = mesher.build_mesh(buffer, [])
	var local := PackedVector3Array() if mesh == null else mesh.get_faces()
	var expected: PackedVector3Array = row.vertices
	var exact := local.size() == expected.size()
	if exact:
		var world_origin := Vector3(block * 16) * cell_meters
		for index in range(local.size()):
			if world_origin + local[index] * cell_meters != expected[index]:
				exact = false
				break
	return {"status":"ready", "vertexCount":local.size(),
		"exact":exact}

func _finish(passed: bool, evidence: Dictionary) -> void:
	var report := {"schema":"n3-n5-physical-handoff-fixture/v1",
		"passed":passed, "evidenceLevel":"native source and real Godot physics fixture",
		"productionCutover":false,
		"elapsedMilliseconds":float(Time.get_ticks_usec() - _started_usec) / 1000.0,
		"evidence":evidence}
	var path := OS.get_environment("N3_N5_PHYSICAL_REPORT")
	if not path.is_empty():
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t", false, true) + "\n")
			file.close()
	quit(0 if passed else 1)
