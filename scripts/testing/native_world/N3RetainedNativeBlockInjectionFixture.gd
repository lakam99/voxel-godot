extends SceneTree

# Headed mechanism fixture: one native retained-demand owner supplies real
# VoxelTerrain buffers, meshing and physics. This is not production gameplay.
const SIZE := 16
const CELL := 1.35
const REQUEST_SCHEMA := "n3-effective-voxel-block-request/v1"
var failures: Array[String] = []
var observations: Array[Dictionary] = []
var backend
var world: Node3D
var terrain: VoxelTerrain
var viewer: VoxelViewer
var format: VoxelFormat
var camera: Camera3D
var mesh_events := 0
var mesh_positions: Array[Vector3i] = []
var accepted := 0
var max_pump_usec := 0
var center_key: Dictionary = {}
var center_generation := 0

func check(value: bool, label: String) -> void:
	if not value:
		failures.append(label)

func source_request() -> Dictionary:
	return {"schema":"n3-native-world-backend-initialize/v1","seedText":"atlas-1492",
		"revisions":{"sourceSchema":2,"terrainGenerator":1,"biomeRegionField":2,
			"latticeQuery":1,"cellCenterQuery":1,"surfaceColumnQuery":1},
		"constants":{"cellSizeMeters":CELL,"cellCenterOffsetCells":0.5,
			"worldBottomCellY":-64,"waterLevelMeters":11.1,
			"minimumSurfaceMeters":4.0,"maximumSurfaceMeters":120.0},
		"sitePolicy":{"sourcePolicyRevision":1,"surveyGenerationPolicyRevision":1,
			"ordinaryRegionCells":140,"ordinarySpawnChance":0.08,"townOverrides":[]}}

func block_request(block: Vector3i) -> Dictionary:
	return {"schema":REQUEST_SCHEMA,"origin":block * SIZE,
		"size":Vector3i.ONE * SIZE,"lod":0}

func block_position(origin: Vector3i) -> Vector3i:
	return Vector3i(floori(float(origin.x)/SIZE),floori(float(origin.y)/SIZE),
		floori(float(origin.z)/SIZE))

func make_buffer(bytes: Dictionary) -> VoxelBuffer:
	var buffer: VoxelBuffer = format.create_buffer(Vector3i.ONE * SIZE)
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_SDF,bytes.sdf16Le)
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_INDICES,bytes.indices8)
	buffer.set_channel_from_byte_array(VoxelBuffer.CHANNEL_DATA5,bytes.data5_8)
	return buffer

func ray_hit() -> Dictionary:
	var space := world.get_world_3d().direct_space_state
	for z in range(-8,25,4):
		for x in range(-8,25,4):
			var query := PhysicsRayQueryParameters3D.create(
				Vector3(x,60,z)*CELL,Vector3(x,-24,z)*CELL)
			query.collision_mask = 1
			var hit: Dictionary = space.intersect_ray(query)
			if not hit.is_empty() and hit.get("collider") == terrain:
				return {"hit":true,"position":hit.position,"cell":Vector2i(x,z)}
	return {"hit":false}

func probe_hit(x: int, z: int) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(
		Vector3(x,60,z)*CELL,Vector3(x,-24,z)*CELL)
	query.collision_mask = 1
	return world.get_world_3d().direct_space_state.intersect_ray(query)

func _on_mesh_block_entered(position: Vector3i) -> void:
	mesh_events += 1
	mesh_positions.append(position)

func _init() -> void:
	call_deferred("run")

func finish() -> void:
	var report := {"schema":"n3-retained-native-block-injection-headed/v1",
		"passed":failures.is_empty(),"evidenceLevel":"headed-real-voxelterrain-mesh-physics-fixture",
		"productionCutover":false,"failures":failures,"observations":observations,
		"acceptedBlocks":accepted,"meshEvents":mesh_events,"maxPumpUsec":max_pump_usec}
	var path := OS.get_environment("VWB_RETAINED_BLOCK_REPORT")
	if path != "":
		var file := FileAccess.open(path,FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report,"\t"))
	var screenshot := OS.get_environment("VWB_RETAINED_BLOCK_SCREENSHOT")
	if screenshot != "":
		await process_frame
		await process_frame
		root.get_texture().get_image().save_png(screenshot)
	quit(0 if report.passed else 1)

func run() -> void:
	backend = ClassDB.instantiate("NativeWorldBackend")
	check(backend != null,"native backend registered")
	if backend == null:
		await finish()
		return
	check(backend.initialize(source_request()).get("status") == "ready","native backend initialized")
	world = Node3D.new()
	world.name = "RetainedNativeBlockFixture"
	root.add_child(world)
	terrain = VoxelTerrain.new()
	terrain.name = "VoxelTerrainManualNativeData"
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
	material.albedo_color = Color(0.43,0.68,0.54)
	terrain.material_override = material
	terrain.mesh_block_entered.connect(_on_mesh_block_entered)
	world.add_child(terrain)
	camera = Camera3D.new()
	camera.position = Vector3(35,33,35)
	camera.current = true
	world.add_child(camera)
	camera.look_at(Vector3(8,9,8)*CELL)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-50,20,0)
	world.add_child(light)
	check(terrain.generator == null and not terrain.automatic_loading_enabled,
		"no script generator or automatic-air fallback")
	var center_request := block_request(Vector3i.ZERO)
	var center_admission: Dictionary = backend.request_voxel_block_shadow(center_request,1,10)
	check(center_admission.has("key"),"center demand retained before viewer")
	var first_prepared: Dictionary = {}
	var first_deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < first_deadline:
		var begin_usec := Time.get_ticks_usec()
		var event: Dictionary = backend.pump_voxel_block_shadow()
		max_pump_usec = maxi(max_pump_usec,Time.get_ticks_usec()-begin_usec)
		if event.get("status") == "ready" and event.get("state") == "prepared":
			first_prepared = event
			break
		await process_frame
	check(not first_prepared.is_empty(),"native center block prepared while no viewer paired")
	if first_prepared.is_empty():
		await finish()
		return
	var rejected := not terrain.try_set_block_data(Vector3i.ZERO,make_buffer(first_prepared))
	backend.voxel_block_shadow_insertion_receipt(first_prepared.key,int(first_prepared.generation),false)
	observations.append({"stage":"unpaired_insertion","rejected":rejected,
		"generation":first_prepared.generation})
	check(rejected,"unpaired viewer insertion rejected without losing demand")
	viewer = VoxelViewer.new()
	viewer.name = "NativeBlockViewer"
	viewer.position = Vector3(8,12,8)*CELL
	viewer.view_distance = 40
	viewer.requires_visuals = true
	viewer.requires_collisions = true
	world.add_child(viewer)
	await physics_frame
	for z in range(-1,2):
		for y in range(-1,2):
			for x in range(-1,2):
				var block := Vector3i(x,y,z)
				if block == Vector3i.ZERO:
					continue
				var demand: Dictionary = backend.request_voxel_block_shadow(block_request(block),1,5)
				check(demand.has("key"),"halo demand retained: %s" % block)
	var insert_deadline := Time.get_ticks_msec() + 120000
	var inserted_blocks := {}
	var inserted_keys := {}
	while Time.get_ticks_msec() < insert_deadline and inserted_blocks.size() < 27:
		var begin_usec := Time.get_ticks_usec()
		var event: Dictionary = backend.pump_voxel_block_shadow()
		max_pump_usec = maxi(max_pump_usec,Time.get_ticks_usec()-begin_usec)
		if event.get("status") == "ready" and event.get("state") == "prepared":
			var key: Dictionary = event.get("key",{})
			var origin: Vector3i = key.get("origin",Vector3i.ZERO)
			var position := block_position(origin)
			var inserted: bool = terrain.try_set_block_data(position,make_buffer(event))
			backend.voxel_block_shadow_insertion_receipt(key,int(event.generation),inserted)
			if inserted:
				inserted_blocks[position] = true
				inserted_keys[position] = key
				accepted += 1
				if position == Vector3i.ZERO:
					center_key = key
					center_generation = int(event.generation)
		await process_frame
	check(inserted_blocks.size() == 27,"all 27 native halo blocks eventually inserted")
	observations.append({"stage":"native_halo","accepted":accepted,
		"elapsedMs":120000-maxi(0,insert_deadline-Time.get_ticks_msec()),
		"maxPumpUsec":max_pump_usec})
	var collision := {}
	var meshed := false
	for i in range(360):
		await physics_frame
		if i % 30 == 0:
			meshed = terrain.is_area_meshed(AABB(Vector3.ZERO,Vector3.ONE*SIZE))
			collision = ray_hit()
		if meshed and bool(collision.get("hit",false)):
			break
	check(meshed and mesh_events > 0,"real native VoxelTerrain mesh published")
	check(bool(collision.get("hit",false)),"real VoxelTerrain physics collider hit")
	if not center_key.is_empty() and meshed and bool(collision.get("hit",false)):
		backend.voxel_block_shadow_mesh_receipt(center_key,center_generation,true,true,true)
		camera.global_position = collision.position + Vector3(5,5,8)
		camera.look_at(collision.position + Vector3(0,0.5,0))
		var actor := CharacterBody3D.new()
		actor.name = "RealPhysicsProbeActor"
		actor.collision_layer = 2
		actor.collision_mask = 1
		var actor_shape := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = 0.35
		capsule.height = 1.8
		actor_shape.shape = capsule
		actor.add_child(actor_shape)
		world.add_child(actor)
		actor.global_position = collision.position + Vector3.UP*3.0
		var actor_landed := false
		for i in range(90):
			await physics_frame
			var contact := actor.move_and_collide(Vector3.DOWN*0.35)
			if contact != null and contact.get_collider() == terrain:
				actor_landed = true
				break
		check(actor_landed,"real CharacterBody3D is contained by terrain collider")
		observations.append({"stage":"actor_contact","landed":actor_landed,
			"actorY":actor.global_position.y,"terrainHitY":collision.position.y})
	observations.append({"stage":"mesh_physics","meshed":meshed,
		"collision":collision,"meshEvents":mesh_events})
	# Keep consumer 1 retained while the real viewer leaves. VoxelTerrain owns
	# eviction; the native receipts make that eviction retryable on revisit.
	viewer.position = Vector3(2000,12,2000)*CELL
	var unloaded := false
	for i in range(180):
		await physics_frame
		if not terrain.has_data_block(Vector3i.ZERO):
			unloaded = true
			break
	check(unloaded,"viewer departure unloads native center data block")
	var unload_receipt: Dictionary = {}
	var mesh_exit_receipt: Dictionary = {}
	if unloaded and not center_key.is_empty():
		for key in inserted_keys.values():
			unload_receipt = backend.voxel_block_shadow_unloaded(key)
			check(unload_receipt.get("status") == "ready","native halo demand receives unload")
		mesh_exit_receipt = backend.voxel_block_shadow_mesh_exited(center_key)
		check(mesh_exit_receipt.get("status") == "ready","native retained demand receives mesh exit")
	observations.append({"stage":"viewer_departure","unloaded":unloaded,
		"nativeUnload":unload_receipt,"nativeMeshExit":mesh_exit_receipt})
	viewer.position = Vector3(8,12,8)*CELL
	await physics_frame
	check(not terrain.has_data_block(Vector3i.ZERO),"revisited center needs native reinsertion")
	var revisit_deadline := Time.get_ticks_msec() + 120000
	var revisit_inserted := {}
	var revisit_generation := 0
	while Time.get_ticks_msec() < revisit_deadline and revisit_inserted.size() < 27:
		var begin_usec := Time.get_ticks_usec()
		var event: Dictionary = backend.pump_voxel_block_shadow()
		max_pump_usec = maxi(max_pump_usec,Time.get_ticks_usec()-begin_usec)
		if event.get("status") == "ready" and event.get("state") == "prepared":
			var key: Dictionary = event.get("key",{})
			var position := block_position(key.get("origin",Vector3i.ZERO))
			var inserted: bool = terrain.try_set_block_data(position,make_buffer(event))
			backend.voxel_block_shadow_insertion_receipt(key,int(event.generation),inserted)
			if inserted:
				revisit_inserted[position] = true
				accepted += 1
				if position == Vector3i.ZERO:
					revisit_generation = int(event.generation)
		await process_frame
	var revisit_meshed := false
	var revisit_collision := {}
	for i in range(360):
		await physics_frame
		if i % 30 == 0:
			revisit_meshed = terrain.is_area_meshed(AABB(Vector3.ZERO,Vector3.ONE*SIZE))
			revisit_collision = ray_hit()
		if revisit_meshed and bool(revisit_collision.get("hit",false)):
			break
	if revisit_meshed and bool(revisit_collision.get("hit",false)) and revisit_generation > 0:
		backend.voxel_block_shadow_mesh_receipt(center_key,revisit_generation,true,true,true)
	check(revisit_inserted.size() == 27,"retained native halo reinserted on viewer revisit")
	check(revisit_generation > center_generation,"center native generation advances after unload")
	check(revisit_meshed and bool(revisit_collision.get("hit",false)),
		"revisited native center republishes mesh and physics")
	observations.append({"stage":"viewer_revisit","inserted":revisit_inserted.size(),
		"previousGeneration":center_generation,"generation":revisit_generation,
		"meshed":revisit_meshed,"collision":revisit_collision})
	# The edit below raises the surface into data-block layer y=1. That layer
	# needs its own y=2 input halo; the original 27-block probe only guaranteed
	# meshing around the center y=0 layer.
	for z in range(-1,2):
		for x in range(-1,2):
			var upper_block := Vector3i(x,2,z)
			var demand: Dictionary = backend.request_voxel_block_shadow(block_request(upper_block),1,5)
			check(demand.has("key"),"upper edit halo demand retained: %s" % upper_block)
	var upper_inserted := {}
	var upper_deadline := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < upper_deadline and upper_inserted.size() < 9:
		var event: Dictionary = backend.pump_voxel_block_shadow()
		if event.get("status") == "ready" and event.get("state") == "prepared":
			var key: Dictionary = event.get("key",{})
			var position := block_position(key.get("origin",Vector3i.ZERO))
			var inserted: bool = terrain.try_set_block_data(position,make_buffer(event))
			backend.voxel_block_shadow_insertion_receipt(key,int(event.generation),inserted)
			if inserted:
				upper_inserted[position] = true
				accepted += 1
		await process_frame
	check(upper_inserted.size() == 9,"upper edit halo inserted before source mutation")
	# A durable source mutation must replace the retained artifact and the real
	# collision surface, even while the viewer and actor remain in the scene.
	var old_edit_hit := probe_hit(12,2)
	check(old_edit_hit.get("collider") == terrain,"edit probe starts on terrain collider")
	var old_away_hit := probe_hit(-4,0)
	var old_edit_bytes: Dictionary = backend.encode_voxel_block_shadow(block_request(Vector3i(0,1,0)))
	var mesh_events_before_edit := mesh_events
	var old_probe_heights := {}
	for z in range(0,5):
		for x in range(10,15):
			var hit := probe_hit(x,z)
			if hit.get("collider") == terrain:
				old_probe_heights[Vector2i(x,z)] = hit.position.y
	var operations := []
	for z in range(0,5):
		for y in range(14,23):
			for x in range(10,15):
				operations.append({"namespace":"durable_terrain","kind":"set",
					"cell":Vector3i(x,y,z),"state":{"materialId":13,
						"biomeId":0,"solid":true,"density":1.35,"fluidId":0,
						"light":Vector2i.ZERO,"metadata":{"source":"terrain_edit",
							"terrainMeshAffects":true},"blockId":"retained_fixture_platform",
						"editReason":"retained-native-headed-fixture"}})
	var transaction := {"schema":"n3-native-typed-cell-transaction/v1",
		"transactionId":"retained-native-headed-platform-v1","expectedRevision":0,
		"operations":operations}
	var committed: Dictionary = backend.commit_typed_cells(transaction)
	check(committed.get("commitStatus") == "committed","durable platform edit committed")
	var new_edit_bytes: Dictionary = backend.encode_voxel_block_shadow(block_request(Vector3i(0,1,0)))
	var source_bytes_changed: bool = old_edit_bytes.get("sdf16Le") != new_edit_bytes.get("sdf16Le")
	check(source_bytes_changed,"durable edit changes native SDF bytes")
	var old_receipt: Dictionary = backend.voxel_block_shadow_mesh_receipt(
		center_key,revisit_generation,true,true,true)
	check(old_receipt.get("status") == "rejected","pre-edit native generation receipt rejected")
	var edit_inserted := {}
	var edited_generation := 0
	var edited_upper_key: Dictionary = {}
	var edited_upper_generation := 0
	var edit_deadline := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < edit_deadline and edit_inserted.size() < 36:
		var event: Dictionary = backend.pump_voxel_block_shadow()
		if event.get("status") == "ready" and event.get("state") == "prepared":
			var key: Dictionary = event.get("key",{})
			var position := block_position(key.get("origin",Vector3i.ZERO))
			var inserted: bool = terrain.try_set_block_data(position,make_buffer(event))
			var receipt: Dictionary = backend.voxel_block_shadow_insertion_receipt(
				key,int(event.generation),inserted)
			if inserted and receipt.get("status") == "ready":
				edit_inserted[position] = true
				accepted += 1
				if position == Vector3i.ZERO:
					edited_generation = int(event.generation)
				if position == Vector3i(0,1,0):
					edited_upper_key = key
					edited_upper_generation = int(event.generation)
		await process_frame
	var edited_hit := {}
	var edited_cell := Vector2i.ZERO
	var edited_surface := false
	for i in range(360):
		await physics_frame
		if i % 10 == 0:
			for z in range(0,5):
				for x in range(10,15):
					var candidate := probe_hit(x,z)
					var cell := Vector2i(x,z)
					if candidate.get("collider") == terrain and old_probe_heights.has(cell) \
							and candidate.position.y > float(old_probe_heights[cell]) + 4.0*CELL:
						edited_hit = candidate
						edited_cell = cell
						edited_surface = true
						break
				if edited_surface:
					break
		if edited_surface:
			break
	var edit_actor_landed := false
	if edited_surface:
		var edit_actor := CharacterBody3D.new()
		edit_actor.name = "EditedSurfacePhysicsProbe"
		edit_actor.collision_layer = 2
		edit_actor.collision_mask = 1
		var edit_shape := CollisionShape3D.new()
		var edit_capsule := CapsuleShape3D.new()
		edit_capsule.radius = 0.35
		edit_capsule.height = 1.8
		edit_shape.shape = edit_capsule
		edit_actor.add_child(edit_shape)
		world.add_child(edit_actor)
		edit_actor.global_position = edited_hit.position + Vector3.UP*3.0
		for i in range(90):
			await physics_frame
			var contact := edit_actor.move_and_collide(Vector3.DOWN*0.35)
			if contact != null and contact.get_collider() == terrain:
				edit_actor_landed = true
				break
	check(edit_inserted.size() == 36,"edited source replaces all retained native halo blocks")
	check(edited_generation > revisit_generation,"edited center receives fresh generation")
	check(edited_surface,"durable edit raises real terrain collision surface")
	check(edit_actor_landed,"actor lands on edited terrain collision")
	var edited_upper_receipt: Dictionary = {}
	if edited_surface and edit_actor_landed and not edited_upper_key.is_empty():
		edited_upper_receipt = backend.voxel_block_shadow_mesh_receipt(
			edited_upper_key,edited_upper_generation,true,true,true)
	check(edited_upper_receipt.get("status") == "ready",
		"edited upper block gains current mesh and physics receipt")
	if edited_surface:
		camera.global_position = edited_hit.position + Vector3(12,7,15)
		camera.look_at(edited_hit.position + Vector3(0,1,0))
	observations.append({"stage":"source_edit_replacement","commit":committed,
		"oldReceipt":old_receipt,"inserted":edit_inserted.size(),
		"oldGeneration":revisit_generation,"generation":edited_generation,
		"oldHit":old_edit_hit,"newHit":edited_hit,"editedCell":edited_cell,
		"actorLanded":edit_actor_landed,"sourceBytesChanged":source_bytes_changed,
		"oldAwayHit":old_away_hit,"newAwayHit":probe_hit(-4,0),
		"meshEventsBefore":mesh_events_before_edit,"meshEventsAfter":mesh_events,
		"meshPositions":mesh_positions,"editedUpperReceipt":edited_upper_receipt,
		"upperHaloResident":terrain.has_data_block(Vector3i(0,2,0))})
	await finish()
