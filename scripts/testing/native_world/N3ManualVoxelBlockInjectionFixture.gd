extends SceneTree

# A headed, real VoxelTerrain/VoxelMesherTransvoxel/physics fixture. Native
# effective terrain remains shadow-only; this is not production cutover.
const REQUEST_SCHEMA := "n3-effective-voxel-block-request/v1"
const SIZE := 16
const CELL := 1.35
var failures: Array[String] = []
var observations: Array[Dictionary] = []
var mesh_events := 0
var terrain
var viewer
var backend
var world: Node3D
var format: VoxelFormat
var camera: Camera3D

func check(value: bool, label: String) -> void:
	if not value:
		failures.append(label)

func source_request() -> Dictionary:
	return {"schema":"n3-native-world-backend-initialize/v1", "seedText":"atlas-1492",
		"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
		"constants":{"cellSizeMeters":1.35,"cellCenterOffsetCells":0.5,"worldBottomCellY":-64,"waterLevelMeters":11.1,"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
		"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,"ordinaryRegionCells":140,"ordinarySpawnChance":0.08,"townOverrides":[]}}

func block_request(origin: Vector3i) -> Dictionary:
	return {"schema":REQUEST_SCHEMA,"origin":origin,"size":Vector3i.ONE * SIZE,"lod":0}

func record(stage: String, detail: Dictionary = {}) -> void:
	observations.append({"stage":stage,"frame":Engine.get_physics_frames(),
		"elapsedMs":Time.get_ticks_msec(),"dataBlocks":terrain.get_statistics() if terrain != null else {},
		"detail":detail})

func _init() -> void:
	call_deferred("run")

func _on_mesh_block_entered(_position: Vector3i) -> void:
	mesh_events += 1

func make_buffer(bytes: Dictionary) -> VoxelBuffer:
	var buffer: VoxelBuffer = format.create_buffer(Vector3i.ONE * SIZE)
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_SDF, bytes.sdf16Le)
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_INDICES, bytes.indices8)
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_DATA5, bytes.data5_8)
	return buffer

func publish_native_block(block_position: Vector3i) -> bool:
	var origin: Vector3i = block_position * SIZE
	var bytes: Dictionary = backend.encode_voxel_block_shadow(block_request(origin))
	if bytes.get("status") != "ready":
		record("block_not_ready", {"block":block_position,"status":bytes.get("status"),
			"reason":bytes.get("reason"),"regions":bytes.get("unresolvedRegions",[])})
		return false
	var buffer := make_buffer(bytes)
	var inserted: bool = terrain.try_set_block_data(block_position, buffer)
	record("block_injection", {"block":block_position,"inserted":inserted,
		"hasData":terrain.has_data_block(block_position),"pinIdentity":bytes.get("pinIdentity")})
	return inserted and terrain.has_data_block(block_position)

func ray_hit() -> Dictionary:
	var space := world.get_world_3d().direct_space_state
	for z in range(-8,25,4):
		for x in range(-8,25,4):
			var query := PhysicsRayQueryParameters3D.create(Vector3(x, 60, z) * CELL,
				Vector3(x, -24, z) * CELL)
			query.collision_mask = 1
			var hit: Dictionary = space.intersect_ray(query)
			if not hit.is_empty():
				return {"hit":true,"colliderIsTerrain":hit.get("collider") == terrain,
					"colliderClass":hit.get("collider").get_class() if hit.get("collider") != null else "",
					"position":hit.get("position",Vector3.ZERO),"sampleCell":Vector2i(x,z)}
	return {"hit":false,"colliderIsTerrain":false}

func report_and_quit() -> void:
	var report := {"schema":"n3-manual-voxel-block-injection-headed/v1",
		"passed":failures.is_empty(),"evidenceLevel":"headed-real-voxelterrain-mesh-physics-fixture",
		"productionCutover":false,"failures":failures,"observations":observations,
		"meshEvents":mesh_events}
	var path := OS.get_environment("VWB_MANUAL_BLOCK_REPORT")
	if path != "":
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report,"\t"))
	var screenshot := OS.get_environment("VWB_MANUAL_BLOCK_SCREENSHOT")
	if screenshot != "":
		await process_frame
		await process_frame
		root.get_texture().get_image().save_png(screenshot)
	quit(0 if report.passed else 1)

func run() -> void:
	backend = ClassDB.instantiate("NativeWorldBackend")
	check(backend != null,"native backend registered")
	if backend == null:
		await report_and_quit()
		return
	check(backend.initialize(source_request()).get("status") == "ready","native backend initialized")
	world = Node3D.new()
	world.name = "ManualNativeBlockFixture"
	root.add_child(world)
	terrain = VoxelTerrain.new()
	terrain.name = "VoxelTerrainManualDataAuthority"
	terrain.automatic_loading_enabled = false
	terrain.generate_collisions = true
	terrain.collision_layer = 1
	terrain.collision_mask = 0
	terrain.mesh_block_size = SIZE
	terrain.scale = Vector3.ONE * CELL
	format = VoxelFormat.new()
	format.set_channel_depth(VoxelBuffer.CHANNEL_SDF,VoxelBuffer.DEPTH_16_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_INDICES,VoxelBuffer.DEPTH_8_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_DATA5,VoxelBuffer.DEPTH_8_BIT)
	terrain.set_format(format)
	var mesher := VoxelMesherTransvoxel.new()
	mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_SINGLE_S4
	mesher.transitions_enabled = false
	terrain.mesher = mesher
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.43, 0.68, 0.54)
	terrain.material_override = material
	terrain.mesh_block_entered.connect(_on_mesh_block_entered)
	world.add_child(terrain)
	viewer = VoxelViewer.new()
	viewer.name = "RealPhysicsViewer"
	viewer.position = Vector3(8, 12, 8) * CELL
	viewer.view_distance = 40
	viewer.requires_visuals = true
	viewer.requires_collisions = true
	world.add_child(viewer)
	camera = Camera3D.new()
	camera.position = Vector3(35, 33, 35)
	camera.current = true
	world.add_child(camera)
	camera.look_at(Vector3(8, 9, 8) * CELL)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50, 20, 0)
	world.add_child(light)
	check(terrain.generator == null and not terrain.automatic_loading_enabled,
		"no fallback generator and no automatic air loading")
	await physics_frame
	var pending_block := Vector3i(35, 0, 35)
	var pending_request: Dictionary = backend.encode_voxel_block_shadow(block_request(pending_block * SIZE))
	check(pending_request.get("status") == "pending" and not pending_request.has("sdf16Le"),
		"unresolved native shaping produces no bytes")
	var pending_viewer := VoxelViewer.new()
	pending_viewer.name = "PendingBlockDemandViewer"
	pending_viewer.position = Vector3(pending_block * SIZE + Vector3i.ONE * 8) * CELL
	pending_viewer.view_distance = 40
	pending_viewer.requires_visuals = true
	pending_viewer.requires_collisions = true
	world.add_child(pending_viewer)
	await physics_frame
	check(pending_viewer.is_inside_tree() and pending_viewer.requires_collisions \
		and pending_viewer.requires_visuals and terrain.automatic_loading_enabled == false,
		"pending block has real viewer demand with automatic loading disabled")
	check(not terrain.has_data_block(pending_block),"unresolved data block absent")
	var retry: Dictionary = backend.encode_voxel_block_shadow(block_request(pending_block * SIZE))
	await physics_frame
	check(retry.get("status") == "pending" and not terrain.has_data_block(pending_block),
		"retained retry remains pending without air")
	record("pending_retry",{"block":pending_block,"first":pending_request.get("status"),
		"retry":retry.get("status"),"regions":retry.get("unresolvedRegions",[]),
		"viewerInsideTree":pending_viewer.is_inside_tree(),
		"viewerPosition":pending_viewer.global_position})
	var injected := 0
	for z in range(-1,2):
		for y in range(-1,2):
			for x in range(-1,2):
				if publish_native_block(Vector3i(x,y,z)):
					injected += 1
	check(injected == 27,"all 27 native neighboring blocks inserted")
	var center := Vector3i.ZERO
	check(terrain.has_data_block(center),"center native data block retained")
	var meshed := false
	var collision := {}
	for i in range(360):
		await physics_frame
		if i % 30 == 0:
			meshed = terrain.is_area_meshed(AABB(Vector3.ZERO,Vector3.ONE * SIZE))
			collision = ray_hit()
			record("publication_poll",{"iteration":i,"meshed":meshed,"collision":collision,
				"meshEvents":mesh_events})
		if meshed and bool(collision.get("colliderIsTerrain",false)):
			break
	check(meshed and mesh_events > 0,"real native VoxelTerrain meshing published")
	check(bool(collision.get("colliderIsTerrain",false)),"real terrain physics collider ray hit")
	if bool(collision.get("colliderIsTerrain",false)):
		var point: Vector3 = collision.position
		camera.global_position = point + Vector3(12, 11, 12)
		camera.look_at(point)
	check(not terrain.has_data_block(pending_block),"pending region remained absent after publication")
	await report_and_quit()
