extends SceneTree

const MAIN := preload("res://scripts/Main.gd")
const STRUCTURES := preload("res://scripts/StructureSystem.gd")
const WORLD := preload("res://scripts/WorldGenerationSystem.gd")
const REQUEST := preload("res://scripts/terrain/NativeWorldSourceRequest.gd")
const PAGES := preload("res://scripts/world/NativeShapingPageAdmission.gd")
const PUBLISHER := preload("res://scripts/terrain/NativeTerrainBlockPublisher.gd")
const FOOTPRINT := preload("res://scripts/terrain/NativeVoxelBlockDemandFootprint.gd")
const SITE_FIELD := preload("res://scripts/world/CitadelSiteField.gd")
const CELL := 1.35
const BLOCK_CELLS := 16
const CAVE_REGION := Vector2i.ZERO

var failures: Array[String] = []
var evidence: Dictionary = {}
var backend
var admission
var publisher
var terrain: VoxelTerrain
var viewer: VoxelViewer
var world_root: Node3D
var target_blocks: Array[Vector3i] = []
var required_data_blocks: Array[Vector3i] = []
var main

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, label: String) -> void:
	if not value:
		failures.append(label)

func _run() -> void:
	print("native_cave_fixture: start")
	root.size = Vector2i(1280, 720)
	root.title = "Native Candidate Cave Physical Fixture"
	main = MAIN.new()
	main.structure_system = STRUCTURES.new()
	admission = main.structure_system.citadel_terrain_admission
	main.world_generation_system = WORLD.new()
	var selected_seed := ""
	var recipe: Dictionary = {}
	for seed_index in range(128):
		selected_seed = "native-cave-physical-%03d" % seed_index
		main.seed_text = selected_seed
		main.seed_hash = main.hash_string(selected_seed)
		main.setup_noise()
		main.structure_system.citadel_terrain_admission.configure(selected_seed, {}, {
			"regionCells": main.STRUCTURE_REGION_CELLS,
			"spawnChance": main.STRUCTURE_SPAWN_CHANCE})
		main.world_generation_system.setup(main)
		recipe = main.world_generation_system.cave_recipe_for_region(CAVE_REGION)
		if not recipe.is_empty() and _recipe_has_no_site_candidates(recipe, selected_seed):
			break
		recipe = {}
	print("native_cave_fixture: scripted recipe status=%s seed=%s" % ["ready" if not recipe.is_empty() else "empty", selected_seed])
	check(not recipe.is_empty(), "script_reference_recipe_available")
	if recipe.is_empty():
		await finish()
		return

	var empty_volume := {"schemaVersion":1, "sectionSize":16, "revision":0, "sections":[]}
	var source: Dictionary = REQUEST.from_main_with_save_volume(main, empty_volume)
	print("native_cave_fixture: source request status=%s" % source.get("status", "missing"))
	check(source.get("status") == "ready", "native_source_request_ready")
	if source.get("status") != "ready":
		evidence.sourceRequest = source
		await finish()
		return
	backend = ClassDB.instantiate("NativeWorldBackend")
	check(backend != null, "native_backend_available")
	if backend == null:
		await finish()
		return
	var initialized: Dictionary = backend.initialize_from_save_v2(source.request)
	print("native_cave_fixture: native backend status=%s" % initialized.get("status", "missing"))
	check(initialized.get("status") == "ready", "native_backend_initialized_from_v2")
	if initialized.get("status") != "ready":
		evidence.initialization = initialized
		await finish()
		return
	var pages = PAGES.new()
	var page_setup: Dictionary = pages.setup(backend,
		main.structure_system.citadel_terrain_admission)
	print("native_cave_fixture: shaping page setup status=%s" % page_setup.get("status", "missing"))
	check(page_setup.get("status") == "ready", "native_shaping_pages_bound")
	if page_setup.get("status") != "ready":
		evidence.pageSetup = page_setup
		await finish()
		return

	world_root = Node3D.new()
	world_root.name = "NativeCandidateCaveWorld"
	root.add_child(world_root)
	terrain = VoxelTerrain.new()
	terrain.name = "NativeCandidateCaveTerrain"
	terrain.automatic_loading_enabled = false
	terrain.generate_collisions = true
	terrain.collision_layer = 1
	terrain.collision_mask = 0
	terrain.mesh_block_size = BLOCK_CELLS
	terrain.scale = Vector3.ONE * CELL
	var format := VoxelFormat.new()
	format.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_INDICES, VoxelBuffer.DEPTH_8_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_DATA5, VoxelBuffer.DEPTH_8_BIT)
	terrain.set_format(format)
	var mesher := VoxelMesherTransvoxel.new()
	mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_SINGLE_S4
	mesher.transitions_enabled = false
	mesher.mesh_optimization_enabled = false
	terrain.mesher = mesher
	var terrain_material := StandardMaterial3D.new()
	terrain_material.albedo_color = Color(0.48, 0.43, 0.34)
	terrain_material.roughness = 0.95
	terrain.material_override = terrain_material
	world_root.add_child(terrain)
	viewer = VoxelViewer.new()
	viewer.name = "NativeCandidateCaveViewer"
	viewer.view_distance = 48
	viewer.requires_visuals = true
	viewer.requires_collisions = true
	world_root.add_child(viewer)
	var camera := Camera3D.new()
	camera.current = true
	camera.fov = 66.0
	world_root.add_child(camera)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-48.0, -28.0, 0.0)
	light.shadow_enabled = true
	world_root.add_child(light)
	var environment := WorldEnvironment.new()
	var environment_resource := Environment.new()
	environment_resource.background_mode = Environment.BG_COLOR
	environment_resource.background_color = Color(0.49, 0.69, 0.86)
	environment_resource.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment_resource.ambient_light_color = Color(0.65, 0.69, 0.76)
	environment_resource.ambient_light_energy = 0.75
	environment.environment = environment_resource
	world_root.add_child(environment)

	var view_points: Array[Dictionary] = [
		{"label":"entrance", "position":recipe.route[0], "look":recipe.route[2]},
		{"label":"junction", "position":recipe.route[3], "look":recipe.route[6]},
		{"label":"chamber", "position":recipe.route[6], "look":recipe.route[5]},
		{"label":"branch", "position":recipe.loop[2], "look":recipe.loop[1]},
	]
	for view in view_points:
		var block := _mesh_block_for(view.position)
		if not target_blocks.has(block):
			target_blocks.append(block)
	var cave_core_mesh_block_count := target_blocks.size()
	var view_block_min := target_blocks[0]
	var view_block_max := target_blocks[0]
	for block in target_blocks:
		view_block_min.x = mini(view_block_min.x, block.x)
		view_block_max.x = maxi(view_block_max.x, block.x)
		view_block_min.z = mini(view_block_min.z, block.z)
		view_block_max.z = maxi(view_block_max.z, block.z)
	var cave_view_blocks := target_blocks.duplicate()
	for z in range(view_block_min.z - 1, view_block_max.z + 2):
		for x in range(view_block_min.x - 1, view_block_max.x + 2):
			var block := Vector3i(x, view_block_min.y, z)
			if not cave_view_blocks.has(block):
				cave_view_blocks.append(block)
	target_blocks = cave_view_blocks
	evidence.recipe = {"seed":selected_seed, "region":CAVE_REGION, "entry":recipe.entry,
		"route":recipe.route, "viewMeshBlocks":target_blocks,
		"caveCoreMeshBlocks":cave_core_mesh_block_count}

	publisher = PUBLISHER.new()
	var publisher_setup: Dictionary = publisher.setup(backend, terrain, pages, 71, 10)
	check(publisher_setup.get("status") == "ready", "native_candidate_publisher_ready")
	var demand: Dictionary = publisher.demand_mesh_blocks(target_blocks)
	print("native_cave_fixture: publisher demand status=%s blocks=%s" % [demand.get("status", "missing"), target_blocks.size()])
	check(demand.get("status") == "ready", "cave_mesh_blocks_demanded")
	if demand.get("status") != "ready":
		evidence.demand = demand
		await finish()
		return
	var footprint: Dictionary = FOOTPRINT.data_blocks_for_mesh_blocks(target_blocks)
	check(footprint.get("status") == "ready", "mesh_halo_footprint_valid")
	required_data_blocks.assign(footprint.get("blocks", []))
	var publication_deadline := Time.get_ticks_msec() + 90000
	var publication_event: Dictionary = {}
	var all_inserted := false
	var next_progress_log := Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < publication_deadline:
		var admission_event: Dictionary = admission.advance()
		if not String(admission_event.get("failure", "")).is_empty():
			publication_event = {"status":"failed", "reason":admission_event.failure,
				"stage":"citadel_admission"}
			break
		publication_event = publisher.pump()
		if Time.get_ticks_msec() >= next_progress_log:
			var publisher_state: Dictionary = publisher.snapshot()
			print("native_cave_fixture: publication status=%s reason=%s inserted=%d/%d waiting=%d admission=%s" % [publication_event.get("status", "missing"), publication_event.get("reason", ""), int(publisher_state.get("inserted", 0)), required_data_blocks.size(), int(publisher_state.get("waitingSource", 0)), admission_event.get("status", "missing")])
			next_progress_log = Time.get_ticks_msec() + 10000
		if publication_event.get("status") == "failed":
			break
		all_inserted = true
		for block: Vector3i in required_data_blocks:
			if not terrain.has_data_block(block):
				all_inserted = false
				break
		if all_inserted:
			break
		await process_frame
	check(all_inserted, "native_cave_data_and_meshing_halo_inserted")
	print("native_cave_fixture: publication complete=%s" % all_inserted)
	if not all_inserted:
		evidence.publicationFailure = publication_event
		evidence.publisher = publisher.snapshot()
		await finish()
		return

	var views: Array[Dictionary] = []
	for view in view_points:
		var point: Vector3 = view.position
		viewer.position = point
		var mesh_block: Vector3i = _mesh_block_for(point)
		var mesh_area := AABB(Vector3(mesh_block * BLOCK_CELLS), Vector3.ONE * BLOCK_CELLS)
		var meshed := false
		var mesh_deadline := Time.get_ticks_msec() + 30000
		while Time.get_ticks_msec() < mesh_deadline:
			await physics_frame
			var visible_shell_meshed := terrain.is_area_meshed(mesh_area)
			for neighboring_block in cave_view_blocks:
				if absi(neighboring_block.x - mesh_block.x) > 1 \
						or absi(neighboring_block.z - mesh_block.z) > 1:
					continue
				var neighbor_area := AABB(Vector3(neighboring_block * BLOCK_CELLS), Vector3.ONE * BLOCK_CELLS)
				if not terrain.is_area_meshed(neighbor_area):
					visible_shell_meshed = false
					break
			if visible_shell_meshed:
				meshed = true
				break
		check(meshed, "%s_native_volume_mesh_published" % view.label)
		print("native_cave_fixture: view=%s mesh=%s" % [view.label, meshed])
		if not meshed:
			views.append({"label":view.label, "meshBlock":mesh_block,
				"meshed":false})
			continue
		var floor_ray := PhysicsRayQueryParameters3D.create(
			point + Vector3.UP * 4.0, point - Vector3.UP * 4.0, 1)
		var hit: Dictionary = world_root.get_world_3d().direct_space_state.intersect_ray(floor_ray)
		var floor_hit: bool = hit.get("collider") == terrain
		var alignment := float(hit.get("position", Vector3.INF).y) - point.y \
			if floor_hit else INF
		check(floor_hit, "%s_native_terrain_collider_hits_floor" % view.label)
		if floor_hit:
			check(absf(alignment) <= CELL * 1.5,
				"%s_native_collision_aligns_to_recipe_floor:%.3f" % [view.label, alignment])
		var roof_closed: Variant = null
		var roof_hit: Dictionary = {}
		if view.label != "entrance":
			var roof_ray := PhysicsRayQueryParameters3D.create(
				point + Vector3.UP * 0.55, point + Vector3.UP * 22.0, 1)
			roof_hit = world_root.get_world_3d().direct_space_state.intersect_ray(roof_ray)
			roof_closed = roof_hit.get("collider") == terrain
			check(roof_closed, "%s_native_volume_has_enclosing_roof" % view.label)
		if view.label in ["entrance", "junction", "chamber", "branch"]:
			var body_clear := _capsule_clear(point + Vector3.UP * 0.93)
			check(body_clear, "%s_native_cave_has_capsule_clearance" % view.label)
		var camera_offset := Vector3.ZERO
		if view.label == "entrance":
			camera_offset = recipe.outward * 10.0 + Vector3.UP * 7.0
		else:
			camera_offset = Vector3.UP * 2.0 - recipe.outward * 6.0
		camera.global_position = point + camera_offset
		camera.look_at(view.look, Vector3.UP)
		await process_frame
		await RenderingServer.frame_post_draw
		var screenshot := _capture_path(String(view.label))
		var saved := get_root().get_texture().get_image().save_png(screenshot) == OK
		check(saved, "%s_native_cave_screenshot_saved" % view.label)
		views.append({"label":view.label, "meshBlock":mesh_block, "meshed":meshed,
			"collisionFloorHit":floor_hit, "floorAlignmentMeters":alignment,
			"roofHit":roof_closed, "roofHitPosition":roof_hit.get("position", Vector3.ZERO),
			"capsuleClear":_capsule_clear(point + Vector3.UP * 0.93),
			"screenshot":screenshot})
	evidence.views = views
	evidence.publisher = publisher.snapshot()
	await finish()

func _mesh_block_for(position: Vector3) -> Vector3i:
	var cell := Vector3i(floori(position.x / CELL), floori(position.y / CELL), floori(position.z / CELL))
	return Vector3i(floori(float(cell.x) / BLOCK_CELLS),
		floori(float(cell.y) / BLOCK_CELLS), floori(float(cell.z) / BLOCK_CELLS))

func _recipe_has_no_site_candidates(recipe: Dictionary, seed_text: String) -> bool:
	var bounds: AABB = recipe.bounds
	var halo := float(BLOCK_CELLS + 1) * CELL
	var low_x := floori((bounds.position.x - halo) / CELL)
	var high_x := floori((bounds.end.x + halo) / CELL)
	var low_z := floori((bounds.position.z - halo) / CELL)
	var high_z := floori((bounds.end.z + halo) / CELL)
	var low_region := Vector2i(floori(float(low_x) / 2048.0), floori(float(low_z) / 2048.0))
	var high_region := Vector2i(floori(float(high_x) / 2048.0), floori(float(high_z) / 2048.0))
	for region_z in range(low_region.y, high_region.y + 1):
		for region_x in range(low_region.x, high_region.x + 1):
			if not SITE_FIELD.candidate_for_region(seed_text, Vector2i(region_x, region_z)).is_empty():
				return false
	return true

func _capsule_clear(position: Vector3) -> bool:
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.38
	capsule.height = 1.8
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	query.transform = Transform3D(Basis.IDENTITY, position)
	query.collision_mask = terrain.collision_layer
	return world_root.get_world_3d().direct_space_state.intersect_shape(query, 8).is_empty()

func _capture_path(label: String) -> String:
	var directory := OS.get_environment("NATIVE_CAVE_PHYSICAL_OUTPUT")
	return directory.path_join("native-" + label + ".png")

func finish() -> void:
	print("native_cave_fixture: draining")
	var drained := true
	if publisher != null and publisher.snapshot().active:
		publisher.request_stop()
		viewer.position = Vector3(2000, 12, 2000) * CELL
		var unload_frames := 0
		var terminal: Dictionary = {}
		for _step in range(1200):
			unload_frames += 1
			terminal = publisher.drain_step()
			if terminal.get("status") != "pending":
				break
			await physics_frame
		var resident_blocks: Array[Vector3i] = []
		for block in required_data_blocks:
			if terrain.has_data_block(block):
				resident_blocks.append(block)
		evidence.residentBlocksAfterDrain = resident_blocks
		evidence.publisherShutdown = publisher.snapshot()
		evidence.publisherDrain = terminal
		evidence.unloadFrames = unload_frames
		drained = resident_blocks.is_empty() and terminal.get("status") == "ready" \
			and terminal.get("nativeWorkersDrained") == true
		check(drained, "native_cave_candidate_publication_drained")
	if admission != null:
		admission.request_shutdown()
		for _step in range(240):
			if admission.advance().get("shutdownComplete", false):
				break
			await process_frame
		check(admission.stats().get("shutdownComplete", false),
			"native_cave_shaping_admission_drained")
		evidence.shapingAdmissionShutdown = admission.stats()
	print("native_cave_fixture: finish failures=%s" % [failures])
	if world_root != null:
		world_root.queue_free()
		await process_frame
		await RenderingServer.frame_post_draw
	world_root = null
	terrain = null
	viewer = null
	if main != null:
		main.world_generation_system = null
		main.structure_system = null
	main = null
	publisher = null
	admission = null
	backend = null
	await process_frame
	var report := {"schema":"native-cave-physical-fixture/v1",
		"passed":failures.is_empty(), "evidenceLevel":"shadow-candidate-real-mesh-collision",
		"productionCutover":false, "failures":failures, "evidence":evidence}
	var report_path := OS.get_environment("NATIVE_CAVE_PHYSICAL_REPORT")
	if not report_path.is_empty():
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "\t"))
			file.close()
		quit(0 if report.passed else 1)
