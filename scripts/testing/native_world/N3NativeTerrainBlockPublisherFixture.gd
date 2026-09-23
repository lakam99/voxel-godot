extends SceneTree

const Publisher = preload("res://scripts/terrain/NativeTerrainBlockPublisher.gd")
const DemandPlanner = preload("res://scripts/terrain/NativeTerrainDemandPlanner.gd")
const Footprint = preload("res://scripts/terrain/NativeVoxelBlockDemandFootprint.gd")
const Admission = preload("res://scripts/world/CitadelTerrainAdmission.gd")
const PageBridge = preload("res://scripts/world/NativeShapingPageAdmission.gd")
const SIZE := 16
const CELL := 1.35

class DelayedPageBridge extends RefCounted:
	var delegate
	var open := false
	func request_page(page: Vector2i) -> Dictionary:
		if not open:
			return {"status":"pending", "reason":"synthetic_page_delay", "page":page}
		return delegate.request_page(page)

var failures: Array[String] = []
var observations := {}

func _init() -> void:
	call_deferred("run")

func check(value: bool, label: String) -> void:
	if not value:
		failures.append(label)

func run() -> void:
	var backend = ClassDB.instantiate("NativeWorldBackend")
	check(backend != null, "native_backend_available")
	if backend == null:
		finish()
		return
	var initialized: Dictionary = backend.initialize({
		"schema":"n3-native-world-backend-initialize/v1", "seedText":"atlas-1492",
		"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,
			"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
		"constants":{"cellSizeMeters":CELL,"cellCenterOffsetCells":0.5,
			"worldBottomCellY":-64,"waterLevelMeters":11.1,
			"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
		"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,
			"ordinaryRegionCells":140,"ordinarySpawnChance":0.08,"townOverrides":[]}})
	check(initialized.get("status") == "ready", "backend_initialized")
	var admission = Admission.new()
	admission.configure("atlas-1492", {}, {"regionCells":140,"spawnChance":0.08})
	check(admission.finalize_town_inputs({}).get("status") == "ready", "site_admission_ready")
	var bridge = PageBridge.new()
	check(bridge.setup(backend, admission).get("status") == "ready", "shaping_bridge_ready")
	var world := Node3D.new()
	root.add_child(world)
	var terrain := VoxelTerrain.new()
	terrain.automatic_loading_enabled = false
	terrain.generate_collisions = true
	terrain.collision_layer = 1
	terrain.mesh_block_size = SIZE
	terrain.scale = Vector3.ONE * CELL
	var format := VoxelFormat.new()
	format.set_channel_depth(VoxelBuffer.CHANNEL_SDF,VoxelBuffer.DEPTH_16_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_INDICES,VoxelBuffer.DEPTH_8_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_DATA5,VoxelBuffer.DEPTH_8_BIT)
	terrain.set_format(format)
	var mesher := VoxelMesherTransvoxel.new()
	mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_SINGLE_S4
	mesher.transitions_enabled = false
	terrain.mesher = mesher
	world.add_child(terrain)
	var viewer := VoxelViewer.new()
	viewer.position = Vector3(128,12,128)*CELL
	viewer.view_distance = 40
	viewer.requires_visuals = true
	viewer.requires_collisions = true
	world.add_child(viewer)
	var camera := Camera3D.new()
	camera.position = Vector3(142,40,142)*CELL
	camera.current = true
	world.add_child(camera)
	camera.look_at(Vector3(128,9,128)*CELL)
	var light := DirectionalLight3D.new()
	world.add_child(light)
	light.rotation_degrees = Vector3(-50,20,0)
	var delayed := DelayedPageBridge.new()
	delayed.delegate = bridge
	var publisher = Publisher.new()
	check(publisher.setup(backend,terrain,delayed,1,10).get("status") == "ready", "publisher_configured")
	var mesh: Array[Vector3i] = [Vector3i(8,0,8)]
	check(publisher.demand_mesh_blocks(mesh).get("status") == "ready", "bounded_mesh_demand")
	check(publisher.snapshot().demanded == 27, "explicit_xyz_halo")
	for i in range(4):
		check(publisher.pump().get("status") != "failed", "synthetic_pending_source_retained_%d" % i)
	check(publisher.snapshot().demanded == 27 and publisher.snapshot().registered == 0
		and publisher.snapshot().waitingSource == 27,
		"pending_page_registers_no_native_block")
	var first_batch: Array[Vector3i] = []
	var second_batch: Array[Vector3i] = []
	for i in range(100):
		first_batch.append(Vector3i(1000 + i, 0, 0))
	for i in range(29):
		second_batch.append(Vector3i(1100 + i, 0, 0))
	check(publisher.apply_data_block_delta(first_batch, []).get("status") == "ready"
		and publisher.apply_data_block_delta(second_batch, []).get("status") == "ready"
		and publisher.snapshot().demanded == 156,
		"incremental_batches_retain_more_than_128_desired_blocks")
	check(publisher.apply_data_block_delta([Vector3i(1000,0,0)], [Vector3i(1000,0,0)]).get("reason") \
		== "contradictory_data_block_delta" and publisher.snapshot().demanded == 156,
		"contradictory_delta_does_not_mutate_demand")
	check(publisher.apply_data_block_delta(first_batch, []).get("status") == "ready"
		and publisher.snapshot().demanded == 156,
		"duplicate_delta_is_idempotent")
	check(publisher.apply_data_block_delta([], first_batch).get("status") == "ready"
		and publisher.apply_data_block_delta([], second_batch).get("status") == "ready"
		and publisher.snapshot().demanded == 27 and publisher.snapshot().waitingSource == 27,
		"incremental_demand_retires_without_dropping_base_halo")
	delayed.open = true
	var deadline := Time.get_ticks_msec() + 120000
	var insertion_count := 0
	var last_event := {}
	while Time.get_ticks_msec() < deadline and publisher.snapshot().inserted < 27:
		last_event = publisher.pump()
		if last_event.get("status") == "failed":
			break
		if last_event.get("state") == "inserted_waiting_mesh":
			insertion_count += 1
		await process_frame
	observations.insertion = {"snapshot":publisher.snapshot(), "count":insertion_count,
		"lastEvent":last_event, "sourcePage":bridge.request_page(Vector2i.ZERO).get("status")}
	check(publisher.snapshot().inserted == 27, "all_native_halo_inserted")
	var target := Vector3i(8,0,8)
	var premature: Dictionary = publisher.acknowledge_physics(target, false)
	check(premature.get("status") == "rejected", "no_false_physics_receipt")
	var meshed := false
	var collision := {}
	for i in range(360):
		await physics_frame
		if i % 15 == 0:
			meshed = terrain.is_area_meshed(AABB(Vector3(target*SIZE),Vector3.ONE*SIZE))
			var query := PhysicsRayQueryParameters3D.create(
				Vector3(128,60,128)*CELL,Vector3(128,-24,128)*CELL)
			query.collision_mask = 1
			collision = world.get_world_3d().direct_space_state.intersect_ray(query)
		if meshed and collision.get("collider") == terrain:
			break
	observations.physical = {"meshed":meshed,"rayHit":collision.get("collider") == terrain,
		"meshEntered":publisher.snapshot().meshEntered}
	check(meshed, "voxelterrain_mesh_published")
	check(collision.get("collider") == terrain, "voxelterrain_collider_published")
	if meshed and collision.get("collider") == terrain:
		var receipt: Dictionary = publisher.acknowledge_physics(target, true)
		observations.physical.receipt = receipt.get("status")
		check(receipt.get("status") == "ready", "real_physics_receipt")
	var old_retiring := Vector3i(7,0,8)
	check(terrain.has_data_block(old_retiring), "old_frontier_resident_before_shift")
	viewer.position = Vector3(144,12,128)*CELL
	var shifted_mesh: Array[Vector3i] = [Vector3i(9,0,8)]
	var shifted: Dictionary = publisher.demand_mesh_blocks(shifted_mesh)
	check(shifted.get("status") == "ready", "frontier_shift_accepted_while_old_resident")
	check(publisher.snapshot().retiring == 9 and publisher.snapshot().registered == 27,
		"old_frontier_retained_during_shift")
	var new_frontier := Vector3i(10,0,8)
	var new_inserted := false
	var shift_deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < shift_deadline:
		var event: Dictionary = publisher.pump()
		if event.get("status") == "failed":
			observations.shiftFailure = event
			break
		if terrain.has_data_block(new_frontier):
			new_inserted = true
			break
		await process_frame
	observations.shift = {"newInserted":new_inserted,
		"oldResident":terrain.has_data_block(old_retiring), "snapshot":publisher.snapshot()}
	check(new_inserted, "new_frontier_inserted_before_old_retirement")
	check(terrain.has_data_block(old_retiring) and publisher.snapshot().retiring == 9,
		"old_native_ownership_retained_during_new_insertion")
	# Two actual native durable edits replace one already-demanded block. The
	# edited platform is in the block above the natural terrain so both height
	# steps remain in that same native generation key.
	var old_query := PhysicsRayQueryParameters3D.create(
		Vector3(147,60,131)*CELL,Vector3(147,-24,131)*CELL)
	old_query.collision_mask = 1
	var edit_block := Vector3i(9,1,8)
	var edit_base := edit_block.y * SIZE + 2
	var edit_mesh: Array[Vector3i] = [Vector3i(9,0,8), edit_block]
	check(publisher.demand_mesh_blocks(edit_mesh).get("status") == "ready", "edit_halo_demanded")
	var edit_halo_deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < edit_halo_deadline \
			and publisher.snapshot().inserted < publisher.snapshot().demanded + publisher.snapshot().retiring:
		var halo_event: Dictionary = publisher.pump()
		if halo_event.get("status") == "failed":
			observations.editHaloFailure = halo_event
			break
		await process_frame
	check(terrain.has_data_block(edit_block), "edit_target_halo_inserted")
	var old_hit: Dictionary = {}
	for i in range(180):
		await physics_frame
		old_hit = world.get_world_3d().direct_space_state.intersect_ray(old_query)
		if old_hit.get("collider") == terrain:
			break
	check(old_hit.get("collider") == terrain, "edit_probe_has_old_terrain")
	var edit_generations: Array[int] = [publisher.installed_generation(edit_block)]
	var edit_heights: Array[float] = []
	var revision := 0
	for edit_index in range(2):
		var ops := []
		for z in range(129, 134):
			for y in range(edit_base, edit_base + 2 + edit_index * 2):
				for x in range(145, 150):
					ops.append({"namespace":"durable_terrain","kind":"set",
						"cell":Vector3i(x,y,z),"state":{"materialId":13,
							"biomeId":0,"solid":true,"density":1.35,"fluidId":0,
							"light":Vector2i.ZERO,"metadata":{"source":"terrain_edit",
								"terrainMeshAffects":true},"blockId":"publisher_platform",
							"editReason":"publisher-headed-edit"}})
		var committed: Dictionary = backend.commit_typed_cells({
			"schema":"n3-native-typed-cell-transaction/v1",
			"transactionId":"publisher-platform-%d" % edit_index,
			"expectedRevision":revision,"operations":ops})
		check(committed.get("commitStatus") == "committed", "native_edit_%d_committed" % edit_index)
		revision = int(committed.get("revision",revision))
		var changed_cells := []
		for operation in ops:
			changed_cells.append(operation.cell)
		var edit_proof := {"rayFrom":old_query.from,"rayTo":old_query.to,
			"expectedMinimumY":float(edit_base + 1 + edit_index * 2) * CELL,
			"changedCells":changed_cells}
		var edit_probes := {}
		edit_probes[edit_block] = edit_proof
		var invalidated: Dictionary = publisher.observe_committed_edit(
			[edit_block],edit_probes)
		check(invalidated.get("status") == "ready" and publisher.snapshot().editBlocked > 0,
			"actor_readiness_blocked_immediately_after_edit_%d" % edit_index)
		var prior_generation: int = edit_generations[-1]
		check(publisher.acknowledge_physics(edit_block,true).get("status") == "rejected",
			"old_boolean_physics_proof_rejected_%d" % edit_index)
		var replacement_generation := 0
		var replacement_deadline := Time.get_ticks_msec() + 45000
		while Time.get_ticks_msec() < replacement_deadline:
			var replacement_event: Dictionary = publisher.pump()
			if replacement_event.get("status") == "failed":
				observations["editFailure%d" % edit_index] = replacement_event
				break
			replacement_generation = publisher.installed_generation(edit_block)
			if replacement_generation > prior_generation:
				break
			await process_frame
		check(replacement_generation > prior_generation,
			"replacement_generation_advances_%d" % edit_index)
		check(publisher.snapshot().editBlocked > 0,
			"actor_still_blocked_after_bytes_before_physics_%d" % edit_index)
		check(publisher.acknowledge_physics_generation(edit_block,prior_generation).get("status") == "rejected",
			"stale_generation_proof_rejected_%d" % edit_index)
		var edited_hit: Dictionary = {}
		var expected_min_height := float(edit_base + 1 + edit_index * 2) * CELL
		for physics_index in range(360):
			await physics_frame
			if physics_index % 10 == 0:
				edited_hit = world.get_world_3d().direct_space_state.intersect_ray(old_query)
			if edited_hit.get("collider") == terrain \
						and float(edited_hit.position.y) >= expected_min_height:
				break
		var physical_new: bool = edited_hit.get("collider") == terrain \
			and float(edited_hit.get("position",Vector3.ZERO).y) >= expected_min_height
		check(physical_new, "new_collision_height_%d" % edit_index)
		var receipt: Dictionary = publisher.acknowledge_physics_generation(
			edit_block,replacement_generation)
		check(receipt.get("status") == "ready", "new_generation_physics_receipt_%d" % edit_index)
		check(publisher.snapshot().editBlocked == 0, "actor_readiness_released_%d" % edit_index)
		edit_generations.append(replacement_generation)
		edit_heights.append(float(edited_hit.get("position",Vector3.ZERO).y))
	observations.edits = {"block":edit_block,"baseY":edit_base,
		"generations":edit_generations,"collisionHeights":edit_heights}
	# A committed edit can land after demand registration but before the first
	# engine insertion. There is no old SDF/collider generation to compare.
	viewer.position = Vector3(144,36,128)*CELL
	viewer.view_distance = 100
	var first_block := Vector3i(9,3,8)
	var first_mesh: Array[Vector3i] = [Vector3i(9,0,8),edit_block,first_block]
	check(publisher.demand_mesh_blocks(first_mesh).get("status") == "ready",
		"first_publication_mesh_demanded")
	var registered_first := false
	for i in range(120):
		var registration_event: Dictionary = publisher.pump()
		if registration_event.get("status") == "failed":
			observations.firstRegistrationFailure = registration_event
			break
		if publisher.has_native_request(first_block):
			registered_first = true
			break
		await process_frame
	check(registered_first and publisher.installed_generation(first_block) == 0,
		"first_publication_edit_hits_registered_uninstalled_demand")
	var first_ops := []
	for z in range(129,134):
		for y in range(50,52):
			for x in range(145,150):
				first_ops.append({"namespace":"durable_terrain","kind":"set",
					"cell":Vector3i(x,y,z),"state":{"materialId":13,"biomeId":0,
						"solid":true,"density":1.35,"fluidId":0,"light":Vector2i.ZERO,
						"metadata":{"source":"terrain_edit","terrainMeshAffects":true},
						"blockId":"publisher_first_platform","editReason":"pending-first-publication"}})
	var first_commit: Dictionary = backend.commit_typed_cells({
		"schema":"n3-native-typed-cell-transaction/v1",
		"transactionId":"publisher-pending-first-publication",
		"expectedRevision":revision,"operations":first_ops})
	check(first_commit.get("commitStatus") == "committed", "pending_first_edit_committed")
	var first_changed := []
	for operation in first_ops:
		first_changed.append(operation.cell)
	var first_probes := {}
	first_probes[first_block] = {"rayFrom":old_query.from,"rayTo":old_query.to,
		"expectedMinimumY":51.0*CELL,"changedCells":first_changed}
	var first_observed: Dictionary = publisher.observe_committed_edit([first_block],first_probes)
	check(first_observed.get("status") == "ready" and publisher.snapshot().editBlocked > 0,
		"first_publication_actor_gate_immediate")
	check(publisher.acknowledge_physics(first_block,true).get("status") == "rejected",
		"first_publication_boolean_receipt_blocked")
	var first_generation := 0
	var first_deadline := Time.get_ticks_msec() + 45000
	while Time.get_ticks_msec() < first_deadline:
		var first_event: Dictionary = publisher.pump()
		if first_event.get("status") == "failed":
			observations.firstPumpFailure = first_event
			break
		first_generation = publisher.installed_generation(first_block)
		if first_generation > 0:
			break
		await process_frame
	check(first_generation > 0 and publisher.snapshot().editBlocked > 0,
		"first_current_bytes_do_not_open_actor_gate")
	check(publisher.acknowledge_physics_generation(first_block,0).get("status") == "rejected",
		"first_publication_stale_zero_generation_rejected")
	var first_required: Array = Footprint.data_blocks_for_mesh_blocks(first_mesh).get("blocks", [])
	var first_halo_ready := false
	var first_halo_deadline := Time.get_ticks_msec() + 45000
	while Time.get_ticks_msec() < first_halo_deadline:
		first_halo_ready = true
		for data_block in first_required:
			if not terrain.has_data_block(data_block):
				first_halo_ready = false
				break
		if first_halo_ready:
			break
		var first_halo_event: Dictionary = publisher.pump()
		if first_halo_event.get("status") == "failed":
			observations.firstHaloFailure = first_halo_event
			break
		await process_frame
	check(first_halo_ready, "first_publication_full_mesh_halo_inserted")
	var first_hit := {}
	var first_receipt := {}
	for i in range(360):
		await physics_frame
		if i % 10 == 0:
			first_hit = world.get_world_3d().direct_space_state.intersect_ray(old_query)
			first_receipt = publisher.acknowledge_physics_generation(first_block,first_generation)
		if first_receipt.get("status") == "ready":
			break
	observations.firstPublication = {"registeredBeforeEdit":registered_first,
		"generation":first_generation,"collisionHeight":float(first_hit.get("position",Vector3.ZERO).y),
		"receipt":first_receipt.get("status")}
	check(first_receipt.get("status") == "ready" and publisher.snapshot().editBlocked == 0,
		"first_current_generation_real_physics_proof_releases_gate")
	check(publisher.stop().get("reason") == "physical_blocks_must_unload",
		"resident_physics_blocks_prevent_native_release")
	viewer.position = Vector3(2000,12,2000)*CELL
	var unloaded := false
	for i in range(180):
		await physics_frame
		var resident := false
		for z in range(7, 10):
			for y in range(-1, 5):
				for x in range(7, 11):
					resident = resident or terrain.has_data_block(Vector3i(x, y, z))
		resident = resident or terrain.has_data_block(edit_block)
		if not resident:
			unloaded = true
			break
	var unload_event: Dictionary = {}
	var unload_receipts := 0
	var old_unload_receipt := false
	for i in range(100):
		unload_event = publisher.reconcile_one()
		if unload_event.get("state") == "unloaded":
			unload_receipts += 1
			if unload_event.get("block") == old_retiring:
				old_unload_receipt = true
	var retired_old := false
	for i in range(100):
		var event: Dictionary = publisher.stop()
		if event.get("status") == "ready":
			retired_old = true
			break
		if event.get("status") == "failed":
			break
	observations.unload = {"engineUnloaded":unloaded,"receiptCount":unload_receipts,
		"oldFrontierReceipt":old_unload_receipt,"lastEvent":unload_event}
	check(unloaded and old_unload_receipt and unload_receipts >= 27,
		"explicit_native_unload_receipt")
	check(retired_old and publisher.snapshot().registered == 0,
		"all_consumer_requests_released")
	var drained := false
	for i in range(120):
		if publisher.drain_step().get("drained", false):
			drained = true
			break
		await process_frame
	observations.drain = drained
	check(drained, "native_worker_drained_after_release")
	# Link the production-sized pure union to the single publisher's bounded
	# desired-set API without starting a thousand native encode jobs here.
	var planned_publisher = Publisher.new()
	var planned = DemandPlanner.new()
	check(planned_publisher.setup(backend,terrain,bridge,1,10).get("status") == "ready"
		and planned.setup(1).get("status") == "ready", "single_publisher_planner_link_bound")
	var primary_spec := {"position":Vector3(128,12,128)*CELL,"distance":80}
	check(planned.replace_sources(primary_spec, [], [], [], Vector2i(-16,48)).get("status") == "ready",
		"startup_primary_union_planned")
	var add_batches := 0
	for i in range(32):
		var delta: Dictionary = planned.next_delta()
		if delta.get("status") == "idle": break
		if delta.get("status") != "ready": break
		var applied: Dictionary = planned_publisher.apply_data_block_delta(delta.addBlocks,delta.removeBlocks)
		if applied.get("status") != "ready": break
		planned.acknowledge_delta(int(delta.ticket),true)
		add_batches += 1
	check(add_batches == 10 and planned_publisher.snapshot().demanded == 1183
		and planned_publisher.snapshot().waitingSource == 1183
		and planned_publisher.snapshot().registered == 0,
		"startup_primary_union_retained_in_bounded_deltas")
	check(planned.replace_sources({}, [], [], [], Vector2i(-16,48)).get("status") == "ready",
		"primary_union_retirement_planned")
	var remove_batches := 0
	for i in range(32):
		var delta: Dictionary = planned.next_delta()
		if delta.get("status") == "idle": break
		if delta.get("status") != "ready": break
		var applied: Dictionary = planned_publisher.apply_data_block_delta(delta.addBlocks,delta.removeBlocks)
		if applied.get("status") != "ready": break
		planned.acknowledge_delta(int(delta.ticket),true)
		remove_batches += 1
	observations.plannedUnion = {"addBatches":add_batches,"removeBatches":remove_batches,
		"snapshot":planned_publisher.snapshot()}
	check(remove_batches == 10 and planned_publisher.snapshot().demanded == 0
		and planned_publisher.snapshot().registered == 0
		and planned_publisher.stop().get("status") == "ready",
		"unregistered_union_retires_without_native_requests")
	admission.request_shutdown()
	for i in range(240):
		if admission.advance().get("shutdownComplete", false):
			break
		await process_frame
	check(admission.stats().get("shutdownComplete", false), "source_worker_drained")
	finish()

func finish() -> void:
	var report := {"schema":"n3-native-terrain-block-publisher-fixture/v1",
		"passed":failures.is_empty(),"evidenceLevel":"headed-engine-mechanism",
		"productionCutover":false,"failures":failures,"observations":observations}
	var path := OS.get_environment("VWB_PUBLISHER_REPORT")
	if path != "":
		var file := FileAccess.open(path,FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report,"\t"))
	quit(0 if report.passed else 1)
