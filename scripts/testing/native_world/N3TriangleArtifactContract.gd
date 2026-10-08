extends SceneTree

const MAIN = preload("res://scripts/Main.gd")
const STRUCTURES = preload("res://scripts/StructureSystem.gd")
const WORLD = preload("res://scripts/WorldGenerationSystem.gd")
const REQUEST = preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const PAGES = preload("res://scripts/world/NativeShapingPageAdmission.gd")
const PLANNER = preload("res://scripts/terrain/NativeTerrainDemandPlanner.gd")
const PRODUCER = preload("res://scripts/terrain/NativeTerrainTriangleArtifactProducer.gd")
const ARTIFACT_REQUESTS = preload("res://scripts/terrain/NativeTerrainArtifactRequests.gd")
const EDIT_PLAN = preload("res://scripts/terrain/NativeTerrainEditRepublicationPlan.gd")

var failures: Array[String] = []
var staged_demand_advances := 0
var staged_demand_work_ops := 0
var staged_demand_max_work_ops := 0

func check(value: bool, label: String) -> void:
	if not value: failures.append(label)

func _is_staged_demand_step(result: Dictionary) -> bool:
	if result.get("status") != "pending": return false
	var reason := String(result.get("reason", ""))
	return reason.begins_with("triangle_demand_snapshot_") \
		or reason.begins_with("triangle_demand_candidate_") \
		or reason.begins_with("triangle_demand_artifact_prune_")

func _advance_staged_demand(worker, initial: Dictionary, label: String) -> Dictionary:
	var result := initial
	var steps := 0
	while _is_staged_demand_step(result) and steps < 4096:
		var work_ops := int(result.get("workOps", 0))
		var work_limit := int(result.get("maxWorkOps", 0))
		check(work_limit > 0 and work_ops <= work_limit,
			"%s staged advance respects work budget (%d/%d)" % [label, work_ops, work_limit])
		staged_demand_advances += 1
		staged_demand_work_ops += work_ops
		staged_demand_max_work_ops = maxi(staged_demand_max_work_ops, work_ops)
		result = worker.advance()
		steps += 1
		await process_frame
	check(not _is_staged_demand_step(result),
			"%s staged demand makes bounded forward progress" % label)
	return result

func _drain_requests(owner, initial: Dictionary, label: String) -> Dictionary:
	var result := initial
	var steps := 0
	while result.get("status") != "ready" and steps < 4096:
		if result.has("workOps"):
			var work_ops := int(result.get("workOps", 0))
			var work_limit := int(result.get("maxWorkOps", 0))
			check(work_limit > 0 and work_ops <= work_limit,
				"%s drain respects work budget (%d/%d)" % [label, work_ops, work_limit])
			staged_demand_advances += 1
			staged_demand_work_ops += work_ops
			staged_demand_max_work_ops = maxi(staged_demand_max_work_ops, work_ops)
		result = owner.drain_step()
		steps += 1
		await process_frame
	check(result.get("status") == "ready", "%s drains with bounded progress" % label)
	return result

func _await_window_layout(broker, initial: Dictionary, label: String) -> Dictionary:
	var result := initial
	var steps := 0
	while result.get("status") != "ready" and steps < 30000:
		if result.get("status") == "failed": break
		if result.has("workOps"):
			var work := int(result.get("workOps", -1))
			var maximum := int(result.get("maxWorkOps", -1))
			check(work >= 0 and maximum == 256 and work <= maximum,
				"%s layout step respects hard work bound (%d/%d)" % [label, work, maximum])
			staged_demand_advances += 1
			staged_demand_work_ops += work
			staged_demand_max_work_ops = maxi(staged_demand_max_work_ops, work)
		result = broker.collision_window_layout()
		steps += 1
		await process_frame
	check(result.get("status") == "ready", "%s staged layout completes" % label)
	return result

func _await_window_layout_reason(broker, initial: Dictionary, reason: String,
		label: String) -> Dictionary:
	var result := initial
	var steps := 0
	while result.get("reason") != reason and steps < 30000:
		if result.get("status") == "failed" or result.get("status") == "ready": break
		if result.has("workOps"):
			var work := int(result.get("workOps", -1))
			var maximum := int(result.get("maxWorkOps", -1))
			check(work >= 0 and maximum == 256 and work <= maximum,
				"%s layout step respects hard work bound (%d/%d)" % [label, work, maximum])
			staged_demand_advances += 1
			staged_demand_work_ops += work
			staged_demand_max_work_ops = maxi(staged_demand_max_work_ops, work)
		result = broker.collision_window_layout()
		steps += 1
		await process_frame
	check(result.get("reason") == reason, "%s reaches expected pending state" % label)
	return result

func _init() -> void:
	call_deferred("run")

func analytic_seam(block_x: int, cell_meters: float, edit_revision: int = 0) -> Dictionary:
	var format := VoxelFormat.new()
	format.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	var buffer: VoxelBuffer = format.create_buffer(Vector3i.ONE * 19)
	for z in range(19):
		for y in range(19):
			for x in range(19):
				var global_sample_x := block_x * 16 + x - 1
				var edited_ridge := 2.0 if edit_revision > 0 and global_sample_x == 0 else 0.0
				buffer.set_voxel_f(float(y) - 9.5 - edited_ridge, x, y, z,
					VoxelBuffer.CHANNEL_SDF)
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
	var producer_demand: Dictionary = producer.demand_snapshot()
	check(producer_demand.get("status") == "ready"
		and producer_demand.get("blocks", []) == [block]
		and (producer_demand.get("blocks", []) as Array).is_read_only()
		and producer.is_block_demanded(block).get("demanded", false)
		and not producer.is_block_demanded(Vector3i(1, block.y, 0)).get("demanded", true),
		"accepted demand snapshot is exact, canonical, isolated, and searchable")
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
	var switched_result: Dictionary = {}
	for frame in range(300):
		switched_result = switched_producer.advance()
		if switched_result.get("status") == "failed": break
		await process_frame
	check(switched_result.get("reason") == "triangle_source_revision_changed",
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
	var edited_left_seam: Dictionary = analytic_seam(-1, main.CELL, 1)
	var edited_right_seam: Dictionary = analytic_seam(0, main.CELL, 1)
	var post_edit_seam_matches := not edited_left_seam.seam.is_empty() \
		and edited_left_seam.seam == edited_right_seam.seam
	var post_edit_contour_changed := edited_left_seam.seam != left_seam.seam
	check(post_edit_seam_matches and post_edit_contour_changed,
		"same-lod transvoxel seam remains matched after shared boundary edit rebuild")
	var distant_broker = ARTIFACT_REQUESTS.new()
	check(distant_broker.setup(backend, pages,
		main.structure_system.citadel_terrain_admission, planner,
		main.CELL, 90, 4096).get("status") == "ready"
		and distant_broker.request_block(block).get("status") == "pending",
		"distant-edit baseline retains near collision request")
	var distant_built := {}
	for frame in range(300):
		distant_built = distant_broker.advance()
		if distant_built.get("status") == "ready" and distant_built.has("row"): break
		await process_frame
	var distant_before: Dictionary = distant_broker.collision_window_layout()
	var distant_window: Dictionary = distant_before.windows[0]
	var distant_facade: Dictionary = distant_broker.collision_window_source(distant_window.id,
		String(distant_before.layoutToken))
	check(distant_built.get("status") == "ready"
		and distant_facade.get("status") == "ready"
		and distant_facade.source.collision_source_snapshot().get("status") == "ready",
		"near window has complete source row before distant edit")
	var unverified_broker = ARTIFACT_REQUESTS.new()
	unverified_broker.setup(backend, pages, main.structure_system.citadel_terrain_admission,
		planner, main.CELL, 91, 4096)
	unverified_broker.request_block(block)
	for frame in range(300):
		var unverified_step: Dictionary = unverified_broker.advance()
		if unverified_step.get("status") == "ready" and unverified_step.has("row"): break
		await process_frame
	var unverified_before: Dictionary = unverified_broker.collision_window_layout()
	var stale_producer = PRODUCER.new()
	check(stale_producer.setup(backend, pages, main.structure_system.citadel_terrain_admission,
		planner, main.CELL, identity).get("status") == "ready"
		and stale_producer.request_block(block).get("status") == "pending",
		"second producer captures source before edited revision")
	var in_flight: Dictionary = await _advance_staged_demand(stale_producer,
		stale_producer.advance(), "stale producer encode")
	for frame in range(100):
		if in_flight.get("reason") == "triangle_encode_in_flight": break
		in_flight = stale_producer.advance()
		await process_frame
	var edit_state := {"materialId":3, "biomeId":13, "fluidId":0,
		"solid":true, "density":1.5, "light":Vector2i.ZERO,
		"metadata":{"saveDelta":true,"source":"terrain_edit"},
		"blockId":"triangle-revision-edit", "editReason":"contract"}
	var committed: Dictionary = backend.commit_durable_cells({
		"schema":"n3-native-durable-cell-transaction/v1",
		"transactionId":"triangle:revision-change", "expectedRevision":0,
		"operations":[{"kind":"set", "cell":Vector3i(1000,-1,1000), "state":edit_state}]})
	var distant_after_edit: Dictionary = distant_facade.source.collision_source_snapshot()
	var edit_plan: Dictionary = EDIT_PLAN.for_committed_cells(
		[Vector3i(1000,-1,1000)], committed.get("affectedSections", []), 1,
		String(backend.status().get("sourceIdentity", {}).get("hex", "")))
	var tampered_receipt: Dictionary = committed.duplicate(true)
	tampered_receipt.affectedSections = [Vector3i(0,0,0)]
	check(distant_broker.observe_verified_durable_edit(tampered_receipt,
		edit_plan).get("status") == "failed",
		"native affected-section receipt must exactly match preflight plan")
	var verified_edit: Dictionary = distant_broker.observe_verified_durable_edit(
		committed, edit_plan)
	var distant_proof_started := Time.get_ticks_usec()
	var distant_advance: Dictionary = distant_broker.advance()
	distant_advance = await _advance_staged_demand(distant_broker,
		distant_advance, "distant verified edit")
	var distant_proof_advance_usec := Time.get_ticks_usec() - distant_proof_started
	var distant_after_layout: Dictionary = distant_broker.collision_window_layout()
	var unverified_advance: Dictionary = unverified_broker.advance()
	unverified_advance = await _advance_staged_demand(unverified_broker,
		unverified_advance, "unverified edit")
	var unverified_after: Dictionary = unverified_broker.collision_window_layout()
	check(committed.get("commitStatus") == "committed"
		and edit_plan.get("status") == "ready"
		and verified_edit.get("status") == "ready"
		and distant_after_edit.get("status") != "ready"
		and distant_before.get("layoutToken") != distant_after_layout.get("layoutToken")
		and distant_window.windowToken == distant_after_layout.windows[0].windowToken
		and distant_after_layout.identity.sourceRevision == 1
		and distant_after_layout.windows[0].identity.sourceRevision == 0
		and distant_facade.source.collision_source_snapshot().get("status") == "ready"
		and distant_advance.get("status") == "pending",
		"verified distant edit advances global revision while retaining local physical identity")
	check(unverified_advance.get("status") == "pending"
		and unverified_before.windows[0].windowToken != unverified_after.windows[0].windowToken,
		"missing owner-verified edit receipt fails closed and retires near window")
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
	var distant_stop: Dictionary = await _drain_requests(distant_broker,
		distant_broker.request_stop(), "distant edit broker")
	check(distant_stop.get("status") == "ready", "distant edit broker drains")
	var unverified_stop: Dictionary = await _drain_requests(unverified_broker,
		unverified_broker.request_stop(), "unverified edit broker")
	check(unverified_stop.get("status") == "ready", "unverified edit broker drains")
	var changed: Dictionary = planner.replace_sources({"position":Vector3(-main.CELL,0,-main.CELL),
		"distance":0}, [], [], [], bounds)
	check(changed.get("status") == "ready"
		and changed.get("demandRevision") != planned.get("demandRevision")
		and producer.collision_source_snapshot().get("status") != "ready",
		"negative demand change invalidates prior source snapshot")
	var changed_block := Vector3i(-1, block.y, -1)
	check(producer.request_block(changed_block).get("status") == "pending",
		"request arriving between revision change and staged begin is retained")
	var readded: Dictionary = planner.replace_sources(viewer, [], [], [], bounds)
	check(readded.get("demandRevision") != planned.get("demandRevision")
		and readded.get("closureToken") != planned.get("closureToken"),
		"remove and readd creates a new source-bound demand identity")
	var new_epoch_producer = PRODUCER.new()
	var new_identity := {"ownerGeneration":2, "sourceRevision":1,
		"cancellationEpoch":2, "sourceEpoch":"n3-triangle-source-2"}
	var new_epoch_setup: Dictionary = new_epoch_producer.setup(backend, pages,
		main.structure_system.citadel_terrain_admission, planner, main.CELL,
		new_identity)
	var new_epoch_snapshot: Dictionary = await _advance_staged_demand(new_epoch_producer,
		new_epoch_producer.advance(), "new source epoch")
	check(new_epoch_setup.get("status") == "ready"
		and new_epoch_snapshot.get("reason") == "triangle_block_not_requested"
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
	var request_stop: Dictionary = await _drain_requests(requests,
		requests.request_stop(), "composed request worker")
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
	var partition_layout: Dictionary = await _await_window_layout(bounded,
		bounded.collision_window_layout(), "two-window partition")
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
	var remote_window: Dictionary = {}
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
			remote_window = window.duplicate(true)
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
	var resumed: Dictionary = await _advance_staged_demand(bounded,
		bounded.advance(), "distant demand retirement")
	var smaller_layout: Dictionary = bounded.collision_window_layout()
	for frame in range(300):
		if smaller_layout.get("status") == "ready": break
		resumed = bounded.advance()
		smaller_layout = bounded.collision_window_layout()
		await process_frame
	check(resumed.get("status") == "pending"
		and smaller_layout.get("layoutToken") != partition_layout.get("layoutToken")
		and (smaller_layout.windows as Array).size() == 1
		and smaller_layout.windows[0].windowToken == near_token
		and near_source.collision_source_snapshot().get("status") == "ready"
		and remote_source.collision_source_snapshot().get("status") == "pending",
		"distant demand retirement preserves unchanged near window identity")
	check(bounded.acknowledge_collision_window_retired(remote_token, {}).get("status") == "failed"
		and bounded.claim_collision_window_retirement(remote_token,
			String(smaller_layout.get("layoutToken", "")),
			"n3-fixture-owner-remote").get("status") == "ready",
		"old window retirement requires an explicit pre-drain lease")
	var bounded_lease: Dictionary = bounded.claim_collision_window_retirement(
		remote_token, String(smaller_layout.get("layoutToken", "")),
		"n3-fixture-owner-remote")
	check(bounded.validate_collision_window_retirement(remote_token,
			String(bounded_lease.get("leaseId", "")), "n3-fixture-owner-replay").get("status") == "failed"
		and bounded.acknowledge_collision_window_retired(remote_token,
			_retirement_receipt(remote_window,
				String(bounded_lease.get("leaseId", "")),
				"n3-fixture-owner-replay")).get("status") == "failed",
		"retirement lease and receipt reject a different physical owner epoch")
	planner.replace_sources(viewer, extra_viewers, [], [], bounds)
	var leased_revert_step: Dictionary = await _advance_staged_demand(bounded,
		bounded.advance(), "leased demand reactivation")
	var leased_revert_layout: Dictionary = await _await_window_layout_reason(bounded,
		bounded.collision_window_layout(), "collision_window_retirement_leased",
		"leased demand reactivation")
	leased_revert_step = leased_revert_layout
	var lease_valid: Dictionary = bounded.validate_collision_window_retirement(
		remote_token, String(bounded_lease.get("leaseId", "")),
		"n3-fixture-owner-remote")
	check(bounded.acknowledge_collision_window_retired(remote_token,
			_retirement_receipt(remote_window,
				String(bounded_lease.get("leaseId", "")),
				"n3-fixture-owner-remote")).get("status") == "ready",
		"claimed old window accepts exact physical drain acknowledgment")
	var resumed_layout: Dictionary = await _await_window_layout(bounded,
		bounded.collision_window_layout(), "leased retirement reactivation")
	check(leased_revert_step.get("reason") == "collision_window_retirement_leased"
		and leased_revert_layout.get("status") == "pending"
		and lease_valid.get("status") == "ready"
		and resumed_layout.get("status") == "ready"
		and resumed_layout.get("windowCount") == 2
		and (resumed_layout.windows as Array).any(
			func(window: Dictionary) -> bool: return window.windowToken == remote_token),
		"demand reactivation waits for leased drain, then materializes a fresh logical window")
	var bounded_stop: Dictionary = await _drain_requests(bounded,
		bounded.request_stop(), "partitioned broker")
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
	large_step = await _advance_staged_demand(large_broker, large_step, "4913-block broker")
	var large_layout: Dictionary = await _await_window_layout(large_broker,
		large_broker.collision_window_layout(), "large partition")
	large_step = large_broker.advance()
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
	var large_stop: Dictionary = large_broker.request_stop()
	for frame in range(120):
		if large_stop.get("status") == "ready": break
		large_stop = large_broker.drain_step()
	check(large_stop.get("status") == "ready", "large broker stops without workers")
	var many_planner = PLANNER.new()
	many_planner.setup(82)
	var many_viewers: Array[Dictionary] = []
	for index in range(65):
		many_viewers.append({"kind":"secondary", "id":"retirement-%d" % index,
			"position":Vector3(float((index + 1) * 256 + 8) * main.CELL, 0, 0),
			"distance":0})
	var many_demand: Dictionary = many_planner.replace_sources(viewer, many_viewers,
		[], [], Vector2i(128,128))
	var many_broker = ARTIFACT_REQUESTS.new()
	check(many_demand.get("status") == "ready"
		and many_broker.setup(backend, pages,
			main.structure_system.citadel_terrain_admission, many_planner,
			main.CELL, 83, 4096).get("status") == "ready",
		"many spatial window sources admitted within data capacity")
	var many_initial: Dictionary = many_broker.advance()
	many_initial = await _advance_staged_demand(many_broker, many_initial, "66-window broker")
	var many_layout: Dictionary = await _await_window_layout(many_broker,
		many_broker.collision_window_layout(), "66-window source")
	check(int(many_layout.get("windowCount", 0)) == 66,
		"66 deterministic window records materialized: %s %s" % [str(many_demand), str(many_layout.get("windowCount", -1))])
	many_planner.replace_sources(viewer, [], [], [], Vector2i(128,128))
	var held: Dictionary = many_broker.advance()
	held = await _advance_staged_demand(many_broker, held, "first retirement target")
	held = await _await_window_layout_reason(many_broker,
		many_broker.collision_window_layout(), "collision_window_retirement_backpressure",
		"first retirement target")
	check(held.get("status") == "pending"
		and held.get("reason") == "collision_window_retirement_backpressure"
		and int(held.get("retiredWindows", 0)) == 65
		and (held.get("retiredWindowTokens", []) as Array).size() == 65,
		"unretired window cap pauses publication without dropping records")
	var held_record_count := int(held.get("totalWindowRecords", -1))
	var held_vertex_bytes := int(held.get("retainedVertexBytes", -1))
	var next_viewers: Array[Dictionary] = [{"kind":"secondary", "id":"next",
		"position":Vector3(float(66 * 256 + 8) * main.CELL, 0, 0),
		"distance":0}]
	many_planner.replace_sources({}, next_viewers, [], [], Vector2i(128,128))
	var still_held: Dictionary = many_broker.advance()
	still_held = await _advance_staged_demand(many_broker, still_held, "second retirement target")
	still_held = await _await_window_layout_reason(many_broker,
		many_broker.collision_window_layout(), "collision_window_retirement_backpressure",
		"second retirement target")
	check(still_held.get("status") == "pending"
		and still_held.get("reason") == "collision_window_retirement_backpressure"
		and int(still_held.get("retiredWindows", 0)) == 66
		and (still_held.get("retiredWindowTokens", []) as Array).size() == 66
		and int(still_held.get("totalWindowRecords", -2)) == held_record_count
		and int(still_held.get("retainedVertexBytes", -2)) == held_vertex_bytes,
		"third rejected target refreshes exact pending retirement set without growth")
	many_planner.replace_sources(viewer, [], [], [], Vector2i(128,128))
	var returned_held: Dictionary = many_broker.advance()
	returned_held = await _advance_staged_demand(many_broker, returned_held, "restored retirement target")
	returned_held = await _await_window_layout_reason(many_broker,
		many_broker.collision_window_layout(), "collision_window_retirement_backpressure",
		"restored retirement target")
	check(returned_held.get("status") == "pending"
		and int(returned_held.get("totalWindowRecords", -2)) == held_record_count,
		"third demand change also retains exact bounded window record set")
	var retired_tokens: Array = held.get("retiredWindowTokens", [])
	if not retired_tokens.is_empty():
		var retired_token := String(retired_tokens[0])
		var retired_window: Dictionary = {}
		for member: Dictionary in many_layout.get("windows", []):
			if String(member.get("windowToken", "")) == retired_token:
				retired_window = member.duplicate(true)
				break
		many_planner.replace_sources(viewer, many_viewers, [], [], Vector2i(128,128))
		var reverted_step: Dictionary = many_broker.advance()
		reverted_step = await _advance_staged_demand(many_broker, reverted_step, "reverted retirement target")
		var reverted_layout: Dictionary = await _await_window_layout(many_broker,
			many_broker.collision_window_layout(), "reverted retirement layout")
		reverted_step = many_broker.advance()
		var reverted_facades := 0
		for window: Dictionary in reverted_layout.get("windows", []):
			var acquired: Dictionary = many_broker.collision_window_source(window.id,
				String(reverted_layout.layoutToken))
			if acquired.get("status") == "ready" \
					and acquired.source.collision_source_snapshot().get("reason") \
					!= "collision_window_source_superseded":
				reverted_facades += 1
		check(reverted_step.get("reason") == "artifact_queue_idle"
			and int(reverted_layout.get("windowCount", 0)) == 66
			and reverted_facades == 66
			and many_broker.acknowledge_collision_window_retired(retired_token,
				{"windowToken":retired_token, "drained":true,
					"remainingBodies":0}).get("status") == "failed",
			"reverted current window revokes projected retirement intent")
		many_planner.replace_sources(viewer, [], [], [], Vector2i(128,128))
		var held_again: Dictionary = many_broker.advance()
		held_again = await _advance_staged_demand(many_broker, held_again, "repeated retirement target")
		held_again = await _await_window_layout_reason(many_broker,
			many_broker.collision_window_layout(), "collision_window_retirement_backpressure",
			"repeated retirement target")
		check(held_again.get("reason") == "collision_window_retirement_backpressure"
			and int(held_again.get("totalWindowRecords", -2)) == held_record_count,
			"new retirement attempt remains bounded after revert")
		check(many_broker.acknowledge_collision_window_retired(retired_token, {}).get("status") == "failed"
			and many_broker.claim_collision_window_retirement(retired_token,
				String(held_again.get("layoutToken", "")),
				"n3-fixture-owner-retired").get("status") == "ready",
			"retired window must acquire lease before drain acknowledgment")
		var many_lease: Dictionary = many_broker.claim_collision_window_retirement(
			retired_token, String(held_again.get("layoutToken", "")),
			"n3-fixture-owner-retired")
		check(many_broker.acknowledge_collision_window_retired(retired_token,
				_retirement_receipt(retired_window,
					String(many_lease.get("leaseId", "")),
					"n3-fixture-owner-retired")).get("status") == "ready"
			and (await _await_window_layout(many_broker,
				many_broker.collision_window_layout(), "retirement release")).get("status") == "ready",
			"explicit physical drain acknowledgment releases bounded backpressure")
	else:
		check(false, "retirement backpressure missing tokens: %s" % str(held))
	var many_stop: Dictionary = many_broker.request_stop()
	for frame in range(120):
		if many_stop.get("status") == "ready": break
		many_stop = many_broker.drain_step()
	check(many_stop.get("status") == "ready", "many-window broker stops")
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
	var worker_step: Dictionary = await _advance_staged_demand(worker_producer,
		worker_producer.advance(), "worker drain producer")
	var face_in_flight: bool = worker_step.get("reason") == "triangle_mesh_in_flight"
	for frame in range(300):
		if face_in_flight or worker_step.get("status") == "failed" \
				or worker_step.get("status") == "ready": break
		worker_step = worker_producer.advance()
		face_in_flight = worker_step.get("reason") == "triangle_mesh_in_flight"
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
	var local_edit_planner = PLANNER.new()
	local_edit_planner.setup(92)
	local_edit_planner.replace_sources(viewer, [], [], [], bounds)
	var local_edit_broker = ARTIFACT_REQUESTS.new()
	local_edit_broker.setup(backend, pages,
		main.structure_system.citadel_terrain_admission, local_edit_planner,
		main.CELL, 93, 4096)
	local_edit_broker.request_block(block)
	for frame in range(300):
		var local_edit_step: Dictionary = local_edit_broker.advance()
		if local_edit_step.get("status") == "ready" and local_edit_step.has("row"): break
		await process_frame
	var local_before: Dictionary = local_edit_broker.collision_window_layout()
	var local_facade: Dictionary = local_edit_broker.collision_window_source(
		local_before.windows[0].id, String(local_before.layoutToken))
	var local_cell := Vector3i(0, y_cell, 0)
	var local_commit: Dictionary = backend.commit_durable_cells({
		"schema":"n3-native-durable-cell-transaction/v1",
		"transactionId":"triangle:local-revision-change", "expectedRevision":1,
		"operations":[{"kind":"set", "cell":local_cell, "state":edit_state}]})
	var local_plan: Dictionary = EDIT_PLAN.for_committed_cells(
		[local_cell], local_commit.get("affectedSections", []), 2,
		String(backend.status().get("sourceIdentity", {}).get("hex", "")))
	var local_verified: Dictionary = local_edit_broker.observe_verified_durable_edit(
		local_commit, local_plan)
	var local_invalidation_started := Time.get_ticks_usec()
	local_edit_broker.advance()
	var local_invalidation_advance_usec := Time.get_ticks_usec() - local_invalidation_started
	var local_after: Dictionary = await _await_window_layout(local_edit_broker,
		local_edit_broker.collision_window_layout(), "verified local edit")
	check(local_commit.get("commitStatus") == "committed"
		and local_verified.get("status") == "ready"
		and local_before.windows[0].windowToken != local_after.windows[0].windowToken
		and local_facade.source.collision_source_snapshot().get("status") != "ready"
		and local_after.identity.sourceRevision == 2,
		"verified local edit invalidates affected collision window and advances global revision")
	var local_edit_stop: Dictionary = await _drain_requests(local_edit_broker,
		local_edit_broker.request_stop(), "local edit broker")
	check(local_edit_stop.get("status") == "ready", "local edit broker drains")
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
		"stagedDemand":{"advanceCount":staged_demand_advances,
			"totalWorkOps":staged_demand_work_ops,
			"maxObservedWorkOps":staged_demand_max_work_ops,
			"workLimit":256},
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
		"distantEditLocality":{"affectedSections":committed.get("affectedSections", []),
			"proofAdvanceUsec":distant_proof_advance_usec,
			"localInvalidationAdvanceUsec":local_invalidation_advance_usec,
			"beforeWindowToken":distant_window.windowToken,
			"afterWindowToken":(distant_after_layout.get("windows", [{}]) as Array)[0].get("windowToken", ""),
			"globalRevision":distant_after_layout.get("identity", {}).get("sourceRevision", -1),
			"localWindowRevision":distant_after_layout.get("windows", [{}])[0].get("identity", {}).get("sourceRevision", -1),
			"localCurrentProof":distant_after_layout.get("windows", [{}])[0].get("localCurrentProof", {}),
			"oldFacadeStatus":distant_after_edit.get("status", ""),
			"oldFacadeReason":distant_after_edit.get("reason", "")},
		"emptyStatus":empty_result.get("status", ""),
		"emptyReason":empty_result.get("reason", ""),
		"emptyVertexCount":(empty_row.get("vertices", PackedVector3Array()) as PackedVector3Array).size(),
		"emptySnapshotStatus":empty_snapshot.get("status", ""),
		"emptyArtifact":bool(row.get("empty", false)),
		"transvoxelSectionSeam":{"evidenceLevel":"synthetic_actual_transvoxel_mesher_same_lod",
			"mesherConfiguration":{"class":"VoxelMesherTransvoxel",
				"texturingMode":"TEXTURES_SINGLE_S4", "transitionsEnabled":false,
				"meshOptimizationEnabled":false},
			"beforeEdit":{"leftVertexCount":left_seam.seam.size(),
				"rightVertexCount":right_seam.seam.size(), "matched":left_seam.seam == right_seam.seam},
			"afterEdit":{"leftVertexCount":edited_left_seam.seam.size(),
				"rightVertexCount":edited_right_seam.seam.size(),
				"matched":post_edit_seam_matches, "contourChanged":post_edit_contour_changed,
				"leftBuildUsec":edited_left_seam.buildUsec,
				"rightBuildUsec":edited_right_seam.buildUsec},
			"crossLod":"not_applicable_current_fixed_lod_voxel_terrain; future_lod_path_open",
			"doesNotProve":["production_resident_capture", "section_candidate_install_or_receipt",
				"voxel_tools_render_parity", "collision_or_visual_retirement"]}}
	var path := OS.get_environment("VWB_TRIANGLE_ARTIFACT_REPORT")
	if not path.is_empty():
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null: file.store_string(JSON.stringify(report, "\t"))
	quit(0 if failures.is_empty() else 1)


func _retirement_receipt(window: Dictionary, lease_id: String,
		physical_owner_epoch: String) -> Dictionary:
	var blocks: Array = window.get("blocks", []).duplicate()
	var identity: Dictionary = window.get("identity", {}).duplicate(true)
	var membership := {"authority":"pinned_demand", "demandRevision":0,
		"closureToken":String(window.get("closureToken", "")),
		"windowToken":String(window.get("windowToken", ""))}
	return {"status":"ready", "drained":true, "remainingBodies":0,
		"remainingPendingEntries":0, "remainingLiveEntries":0,
		"sourceReleased":true, "barrierOwnershipReleased":true,
		"windowToken":String(window.get("windowToken", "")),
		"physicalOwnerEpoch":physical_owner_epoch,
		"retirementLeaseId":lease_id, "identity":identity,
		"sourceIdentity":identity.get("sourceIdentity", {}).duplicate(true),
		"membershipProvenance":membership, "residentBlockCount":blocks.size(),
		"residentBlocks":blocks.duplicate(),
		"requiredResidentBlocks":blocks.duplicate()}
