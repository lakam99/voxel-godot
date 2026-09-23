extends SceneTree

const Publisher = preload("res://scripts/terrain/NativeTerrainBlockPublisher.gd")
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
	check(publisher.snapshot().demanded == 27 and publisher.snapshot().registered == 0,
		"pending_page_registers_no_native_block")
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
	check(publisher.stop().get("reason") == "physical_blocks_must_unload",
		"resident_physics_blocks_prevent_native_release")
	viewer.position = Vector3(2000,12,2000)*CELL
	var unloaded := false
	for i in range(180):
		await physics_frame
		var resident := false
		for z in range(7, 10):
			for y in range(-1, 2):
				for x in range(7, 11):
					resident = resident or terrain.has_data_block(Vector3i(x, y, z))
		if not resident:
			unloaded = true
			break
	var unload_event: Dictionary = {}
	var unload_receipts := 0
	var old_unload_receipt := false
	for i in range(36):
		unload_event = publisher.reconcile_one()
		if unload_event.get("state") == "unloaded":
			unload_receipts += 1
			if unload_event.get("block") == old_retiring:
				old_unload_receipt = true
	var retired_old := false
	for i in range(36):
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
