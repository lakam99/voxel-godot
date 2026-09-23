extends SceneTree

# Diagnostic Voxel Tools lifecycle contract; synthetic data is not gameplay acceptance.
const SIZE := 16
var failures: Array[String] = []
var observations: Array[Dictionary] = []
var world: Node3D
var terrain: VoxelTerrain
var viewer: VoxelViewer
var format: VoxelFormat
var mesh_events := 0

func _init() -> void:
	call_deferred("run")

func check(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)

func record(stage: String, detail: Dictionary = {}) -> void:
	observations.append({"stage":stage,"frame":Engine.get_physics_frames(),"detail":detail})

func make_buffer(height: int, solid: bool = false) -> VoxelBuffer:
	var buffer := format.create_buffer(Vector3i.ONE * SIZE)
	for z in SIZE:
		for y in SIZE:
			for x in SIZE:
				buffer.set_voxel_f(-1.0 if solid or y < height else 1.0,
					x,y,z,VoxelBuffer.CHANNEL_SDF)
	return buffer

func hit_height() -> float:
	var query := PhysicsRayQueryParameters3D.create(Vector3(8,40,8),Vector3(8,-20,8))
	query.collision_mask = 1
	var hit := world.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty() or hit.get("collider") != terrain:
		return -1000.0
	return hit.position.y

func wait_for_height(expected: float, tolerance: float = 2.0) -> bool:
	for i in 180:
		await physics_frame
		if absf(hit_height()-expected) <= tolerance:
			return true
	return false

func _on_mesh_block_entered(_position: Vector3i) -> void:
	mesh_events += 1

func run() -> void:
	world = Node3D.new()
	root.add_child(world)
	terrain = VoxelTerrain.new()
	terrain.automatic_loading_enabled = false
	terrain.generate_collisions = true
	terrain.collision_layer = 1
	terrain.collision_mask = 0
	terrain.mesh_block_size = SIZE
	format = VoxelFormat.new()
	format.set_channel_depth(VoxelBuffer.CHANNEL_SDF,VoxelBuffer.DEPTH_16_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_INDICES,VoxelBuffer.DEPTH_8_BIT)
	format.set_channel_depth(VoxelBuffer.CHANNEL_DATA5,VoxelBuffer.DEPTH_8_BIT)
	terrain.set_format(format)
	var mesher := VoxelMesherTransvoxel.new()
	mesher.texturing_mode = VoxelMesherTransvoxel.TEXTURES_SINGLE_S4
	mesher.transitions_enabled = false
	terrain.mesher = mesher
	terrain.mesh_block_entered.connect(_on_mesh_block_entered)
	world.add_child(terrain)
	var rejected_before_viewer := not terrain.try_set_block_data(Vector3i.ZERO,make_buffer(8))
	record("before_viewer",{"rejected":rejected_before_viewer})
	check(rejected_before_viewer,"insertion without paired viewer rejected")
	viewer = VoxelViewer.new()
	viewer.position = Vector3(8,8,8)
	viewer.view_distance = 40
	viewer.requires_visuals = true
	viewer.requires_collisions = true
	world.add_child(viewer)
	await physics_frame
	var inserted := 0
	for z in range(-1,2):
		for y in range(-1,2):
			for x in range(-1,2):
				if terrain.try_set_block_data(Vector3i(x,y,z),make_buffer(8)):
					inserted += 1
	record("initial_insert",{"accepted":inserted,"meshEvents":mesh_events})
	check(inserted == 27,"all paired halo blocks accepted")
	var initial_collision := await wait_for_height(8.0)
	record("initial_collision",{"ready":initial_collision,"height":hit_height(),"meshEvents":mesh_events})
	check(initial_collision,"initial height-8 collision published")
	var first := terrain.try_set_block_data(Vector3i.ZERO,make_buffer(4))
	var second := terrain.try_set_block_data(Vector3i.ZERO,make_buffer(12))
	var final_collision := await wait_for_height(12.0)
	record("rapid_replacement",{"first":first,"second":second,
		"finalHeightReady":final_collision,"height":hit_height(),"meshEvents":mesh_events})
	check(first and second,"rapid replacements accepted")
	check(final_collision,"latest rapid replacement collision published")
	var stale_after_ack := false
	for i in 60:
		await physics_frame
		if absf(hit_height()-12.0) > 2.0:
			stale_after_ack = true
			break
	record("replacement_settle",{"staleAfterAck":stale_after_ack,"height":hit_height()})
	check(not stale_after_ack,"rapid replacement remains current after mesh settling")
	viewer.position = Vector3(2000,8,2000)
	var unloaded := false
	for i in 120:
		await physics_frame
		if not terrain.has_data_block(Vector3i.ZERO):
			unloaded = true
			break
	record("viewer_departure",{"unloaded":unloaded,"hasData":terrain.has_data_block(Vector3i.ZERO)})
	check(unloaded,"viewer departure retires manually inserted block")
	viewer.position = Vector3(8,8,8)
	await physics_frame
	var revisit_missing := not terrain.has_data_block(Vector3i.ZERO)
	record("viewer_revisit",{"missing":revisit_missing})
	check(revisit_missing,"manual block requires requeue on revisit")
	var reinserted := 0
	for z in range(-1,2):
		for y in range(-1,2):
			for x in range(-1,2):
				if terrain.try_set_block_data(Vector3i(x,y,z),make_buffer(12)):
					reinserted += 1
	var restored := await wait_for_height(12.0)
	record("revisit_reinsertion",{"accepted":reinserted,"restored":restored,
		"height":hit_height()})
	check(reinserted == 27 and restored,"revisit recovers via explicit reinsertion")
	var report := {"schema":"n3-manual-voxel-lifecycle-diagnostic/v1",
		"passed":failures.is_empty(),"evidenceLevel":"synthetic-engine-lifecycle-contract",
		"failures":failures,"observations":observations}
	var path := OS.get_environment("VWB_MANUAL_LIFECYCLE_REPORT")
	if path != "":
		var file := FileAccess.open(path,FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report,"\t"))
	quit(0 if report.passed else 1)
