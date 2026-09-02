extends SceneTree
## Native-engine integration with synthetic admission/terrain input. Not gameplay.
const Gate = preload("res://scripts/terrain/VoxelTerrainSiteGate.gd")
const Runtime = preload("res://scripts/terrain/VoxelTerrainRuntime.gd")
const ProductionWorld = preload("res://scripts/WorldGenerationSystem.gd")
const Store = preload("res://scripts/world/GeneratedSiteProfileStore.gd")
const Player = preload("res://scripts/PlayerController.gd")
const Survival = preload("res://scripts/SurvivalSystem.gd")

class RuntimeContext extends "res://scripts/terrain/VoxelWorldGenerationContext.gd":
	var world_generation_system
	var structure_system
	var player: Node3D
	var startup_loading_active := true
	var runtime_loading_active := true
	var message_host
	func show_action_message(message: String) -> void:
		if message_host != null: message_host.show_action_message(message)

class PlayerHost extends Node:
	var runtime
	var hud = null
	var runtime_perf_monitor = null
	var messages: Array = []
	func terrain_collision_motion_proof(from: Vector3, to: Vector3, radius: float) -> Dictionary:
		return runtime.collision_proof_for_motion(from,to,radius)
	func show_action_message(message: String) -> void: messages.append(message)

class Structures extends RefCounted:
	var citadel_terrain_admission

class ObservedRuntime extends Runtime:
	var flat_fixture := false
	func build_generation_state() -> Dictionary:
		var result: Dictionary = super.build_generation_state()
		if result.ok:
			var observed := RecordingGenerator.new()
			observed.context_template = result.generator.context_template
			observed.delay_msec = 2 # Synthetic queued-work control, never a timing claim.
			observed.flat_fixture = flat_fixture
			result.generator = observed
		return result

class Admission extends RefCounted:
	var world_seed := "atlas-1492"
	var profile_store := RefCounted.new()
	var blocked := Rect2i()
	var failure := ""
	var max_width := 10000
	func finalize_town_inputs(towns: Dictionary) -> Dictionary:
		return {"status":"ready","towns":towns.duplicate(true)}
	func advance() -> Dictionary: return {}
	func request_bounds(bounds: Rect2i) -> Dictionary:
		if not failure.is_empty(): return {"status":"failed","reason":failure}
		return {"status":"pending" if bounds.intersects(blocked) or bounds.size.x>max_width else "ready","reason":"synthetic_pending"}

class World extends RefCounted:
	func refresh_generated_site_profiles() -> void: pass

class RecordingGenerator extends VoxelGeneratorScript:
	var mutex := Mutex.new()
	var origins: Array = []
	var context_template
	var delay_msec := 0
	var flat_fixture := false
	func _get_used_channels_mask() -> int: return 1 << VoxelBuffer.CHANNEL_SDF
	func _generate_block(buffer: VoxelBuffer, origin: Vector3i, _lod: int) -> void:
		mutex.lock()
		origins.append(origin)
		mutex.unlock()
		if context_template != null: context_template.clone_for_worker()
		if delay_msec > 0: OS.delay_msec(delay_msec)
		buffer.set_channel_depth(VoxelBuffer.CHANNEL_SDF,VoxelBuffer.DEPTH_16_BIT)
		if flat_fixture:
			for y in range(buffer.get_size().y):
				for z in range(buffer.get_size().z):
					for x in range(buffer.get_size().x): buffer.set_voxel_f(float(origin.y+y),x,y,z,VoxelBuffer.CHANNEL_SDF)
		else:
			buffer.fill_f(-1.0,VoxelBuffer.CHANNEL_SDF)
	func snapshot() -> Array:
		mutex.lock()
		var result := origins.duplicate()
		mutex.unlock()
		return result

var checks: Dictionary = {}
var rig: Node3D
var terrain: VoxelTerrain
var generator: RecordingGenerator
var admission: Admission
var gate
var owned: Array[Node3D] = []
var output := ""
var samples: Array = []
var reset_evidence: Dictionary = {}
var player_evidence: Dictionary = {}

func _initialize() -> void: call_deferred("_run")
func check(name: String, passed: bool) -> void:
	checks[name] = passed
	if not passed: printerr("NATIVE ADMISSION CONTRACT FAILED: ",name)

func _frames(count: int) -> void:
	for _i in range(count):
		await physics_frame
		await process_frame

func _setup() -> void:
	rig = Node3D.new()
	root.add_child(rig)
	terrain = VoxelTerrain.new()
	terrain.automatic_loading_enabled = false
	terrain.max_view_distance = 64
	terrain.bounds = AABB(Vector3(-4096,-16,-4096),Vector3(8192,32,8192))
	terrain.scale = Vector3.ONE*1.35
	generator = RecordingGenerator.new()
	terrain.generator = generator
	terrain.mesher = VoxelMesherTransvoxel.new()
	terrain.generate_collisions = false
	rig.add_child(terrain)
	admission = Admission.new()
	gate = Gate.new()
	gate.setup(rig,terrain,admission,World.new())

func _viewer() -> VoxelViewer:
	var viewer := VoxelViewer.new()
	viewer.requires_visuals = false
	viewer.requires_collisions = false
	owned.append(viewer)
	return viewer

func _teardown() -> void:
	gate.stop()
	for viewer in owned:
		if is_instance_valid(viewer):
			if viewer.get_parent()!=null: viewer.get_parent().remove_child(viewer)
			viewer.free()
	owned.clear()
	await _frames(4)
	rig.queue_free()
	await _frames(4)
	gate = null

func _contained(origins: Array, areas: Array) -> bool:
	for origin: Vector3i in origins:
		var block := Rect2i(Vector2i(origin.x,origin.z),Vector2i.ONE*16)
		var contained := false
		for area: Rect2i in areas: contained = contained or area.encloses(block)
		if not contained: return false
	return true

func _run() -> void:
	output = OS.get_environment("CITADEL_NATIVE_ADMISSION_OUTPUT")
	var old_position := Vector3(1350.0,0.0,-1350.0)
	var new_position := Vector3(2700.0,0.0,2700.0)
	var foreign := _viewer()
	root.add_child(foreign)
	_setup()
	var primary := _viewer()
	check("preexisting_foreign_rejected",not gate.request_viewer(primary,old_position,16) and gate.failure_reason()=="unowned_voxel_viewer")
	gate.advance()
	await _frames(6)
	check("preexisting_foreign_no_generation",generator.snapshot().is_empty() and not terrain.automatic_loading_enabled and not primary.is_inside_tree())
	await _teardown()

	_setup()
	primary = _viewer()
	admission.blocked = Gate.footprint(old_position,16)
	check("initial_pending_stays_offtree",not gate.request_viewer(primary,old_position,16) and not primary.is_inside_tree())
	gate.advance()
	await _frames(4)
	check("initial_pending_no_generation",generator.snapshot().is_empty())
	admission.blocked = Rect2i()
	gate.advance()
	check("correct_position_before_enable",primary.is_inside_tree() and primary.global_position==old_position and terrain.automatic_loading_enabled)
	for _i in range(90):
		if not generator.snapshot().is_empty(): break
		await _frames(1)
	var first := generator.snapshot()
	check("native_data_generation_exercised",not first.is_empty())
	check("no_origin_attachment_generation",_contained(first,[Gate.footprint(old_position,16)]))

	admission.blocked = Gate.footprint(new_position,16)
	var auxiliary := _viewer()
	check("pending_auxiliary_offtree",not gate.request_viewer(auxiliary,new_position,16) and not auxiliary.is_inside_tree())
	check("pending_move_retains_old_position",not gate.request_viewer(primary,new_position,16) and primary.global_position==old_position)
	admission.max_width = Gate.footprint(old_position,16).size.x
	check("pending_distance_retains_old_distance",not gate.request_viewer(primary,old_position,32) and primary.view_distance==16)
	gate.advance()
	await _frames(8)
	check("pending_work_did_not_generate_unadmitted_ground",_contained(generator.snapshot(),[Gate.footprint(old_position,16)]))
	admission.blocked = Rect2i()
	admission.max_width = 10000
	gate.advance()
	check("retained_auxiliary_request_attached",auxiliary.is_inside_tree() and auxiliary.global_position==new_position)
	check("retained_distance_request_applied",primary.view_distance==32)
	await _frames(8)
	check("all_generated_blocks_inside_admitted_areas",_contained(generator.snapshot(),[Gate.footprint(old_position,32),Gate.footprint(new_position,16)]))

	foreign = _viewer()
	foreign.position = Vector3.ZERO
	root.add_child(foreign)
	check("new_foreign_stops_loading_synchronously",not terrain.automatic_loading_enabled and gate.failure_reason()=="unowned_voxel_viewer")
	await _frames(8)
	check("foreign_origin_never_generated",_contained(generator.snapshot(),[Gate.footprint(old_position,32),Gate.footprint(new_position,16)]))
	samples = generator.snapshot()
	await _teardown()
	await _runtime_reset()
	await _player_containment()
	var report := {"passed":not checks.is_empty() and false not in checks.values(),"checks":checks,
		"engine":Engine.get_version_info(),"generationCalls":samples.size(),"origins":samples,
		"runtimeReset":reset_evidence,
		"playerContainment":player_evidence,
		"evidenceLevel":"installed_native_terrain_with_synthetic_admission_and_generator",
		"doesNotProve":"No Main/New Game, real Site preparation, live terrain shape, collision, saved edits, visuals or gameplay acceptance. Runtime reset uses a synthetic 2 ms generator delay to ensure queued work; not performance acceptance."}
	var f := FileAccess.open(output.path_join("report.json"),FileAccess.WRITE)
	f.store_string(JSON.stringify(report,"\t"))
	f.close()
	print("NATIVE ADMISSION RESULT ",report.passed," checks=",checks.size()," generationCalls=",samples.size())
	quit(0 if report.passed else 1)

func _runtime_reset() -> void:
	var context := RuntimeContext.new()
	context.seed_text = "atlas-1492"
	context.seed_hash = context.hash_string(context.seed_text)
	context.setup_noise()
	var world := ProductionWorld.new()
	world.setup(context)
	context.world_generation_system = world
	context.set_generator(world)
	var structure_owner := Structures.new()
	var admitted := Admission.new()
	admitted.profile_store = Store.new(context.seed_text)
	structure_owner.citadel_terrain_admission = admitted
	context.structure_system = structure_owner
	var player := Node3D.new()
	player.position = Vector3(1350,30,-1350)
	root.add_child(player)
	context.player = player
	var runtime := ObservedRuntime.new()
	root.add_child(runtime)
	var initialized: Dictionary = runtime.setup(context)
	check("runtime_setup",initialized.ok and runtime.generation_context_current())
	var old_generator: RecordingGenerator = runtime.generator
	for _i in range(90):
		if not old_generator.snapshot().is_empty(): break
		await _frames(1)
	var pending_before := runtime.voxel_engine_pending_task_count()
	check("runtime_reset_has_actual_queued_native_work",pending_before>0 and not old_generator.snapshot().is_empty())
	var terrain_id := runtime.terrain.get_instance_id()
	var old_store = admitted.profile_store
	admitted.profile_store = Store.new(context.seed_text)
	check("same_seed_new_epoch_requires_reset",not runtime.generation_context_current())
	var reset: Dictionary = await runtime.reset_for_current_seed_staged()
	check("runtime_reset_drained_and_ready",reset.ok and reset.metrics.taskDrain.pendingTasks==0 and reset.metrics.taskDrain.quietFrames>=2)
	check("runtime_terrain_instance_preserved",runtime.terrain.get_instance_id()==terrain_id)
	check("runtime_generator_replaced",runtime.generator!=old_generator)
	check("runtime_context_store_replaced",runtime.generator.context_template.generated_site_profile_store==admitted.profile_store and old_generator.context_template.generated_site_profile_store==old_store)
	var old_calls := old_generator.snapshot().size()
	for _i in range(90):
		if not runtime.generator.snapshot().is_empty(): break
		await _frames(1)
	check("runtime_new_epoch_generates",not runtime.generator.snapshot().is_empty() and runtime.generation_context_current())
	check("runtime_no_old_calls_after_drain",old_generator.snapshot().size()==old_calls)
	var previous_generator = runtime.generator
	context.seed_text = "atlas-admission-next-world"
	context.seed_hash = context.hash_string(context.seed_text)
	context.setup_noise()
	world.reset_for_seed()
	var mismatched: Dictionary = await runtime.reset_for_current_seed_staged()
	check("wrong_seed_admission_rejected_before_context_install",not mismatched.ok and mismatched.reason=="citadel_admission_seed_mismatch" and runtime.generator==previous_generator and not runtime.terrain.automatic_loading_enabled)
	admitted.world_seed = context.seed_text
	admitted.profile_store = Store.new(context.seed_text)
	var new_seed_result: Dictionary = await runtime.reset_for_current_seed_staged()
	check("new_seed_reconfigured_then_installed",new_seed_result.ok and runtime.generation_context_current() and runtime.generator.context_template.seed_text==context.seed_text and runtime.generator.context_template.generated_site_profile_store.world_seed()==context.seed_text)
	runtime.begin_shutdown()
	var shutdown: Dictionary = await runtime.wait_for_seed_reset_task_drain()
	check("runtime_shutdown_native_drained",shutdown.ok and runtime.voxel_engine_pending_task_count()==0)
	reset_evidence = {"pendingBeforeReset":pending_before,"reset":reset,"newSeedReset":new_seed_result,"rejectedWrongSeed":mismatched,"oldCallsAtDrain":old_calls,
		"oldCallsAfterReplacement":old_generator.snapshot().size(),"newCalls":runtime.generator.snapshot().size(),"shutdown":shutdown}
	runtime.queue_free()
	player.queue_free()
	await _frames(4)
	context.world_generation_system = null

func _player_containment() -> void:
	var context := RuntimeContext.new()
	context.seed_text = "atlas-1492"
	context.seed_hash = context.hash_string(context.seed_text)
	context.setup_noise()
	var world := ProductionWorld.new()
	world.setup(context)
	context.world_generation_system = world
	context.set_generator(world)
	var structure_owner := Structures.new()
	var admitted := Admission.new()
	admitted.profile_store = Store.new(context.seed_text)
	structure_owner.citadel_terrain_admission = admitted
	context.structure_system = structure_owner
	var player = Player.new()
	player.survival = Survival.new()
	var start := Vector3(1350,0.05,-1350)
	player.position = start # Fixture setup only; act never writes actor position.
	player.automated_input = true
	player.automated_move = Vector3.RIGHT
	var host := PlayerHost.new()
	root.add_child(host)
	player.main = host
	context.message_host = host
	context.player = player
	var runtime := ObservedRuntime.new()
	runtime.flat_fixture = true
	root.add_child(runtime)
	host.runtime = runtime
	root.add_child(player)
	player.set_physics_process(false)
	admitted.blocked = Gate.footprint(start,80)
	runtime.last_site_wait_message_usec = -1000000
	var initialized: Dictionary = runtime.setup(context)
	check("player_runtime_setup",initialized.ok)
	# This headless phase proves collision/motor containment, not rendering.
	# Do not ask the dummy renderer to publish the synthetic plane's visuals.
	runtime.viewer.requires_visuals = false
	player.set_physics_process(true)
	await _frames(4)
	check("real_player_held_while_source_pending",player.global_position==start and player.velocity==Vector3.ZERO and player.terrain_collision_hold_frames>=4)
	check("player_wait_message_emitted",not host.messages.is_empty() and String(host.messages[0]).contains("Preparing landmark"))
	var stamina_before := float(player.survival.stamina)
	check("pending_source_rejects_real_dodge",not player.request_dodge(Vector3.RIGHT) and player.player_defense.last_reason=="terrain_unready")
	check("rejected_dodge_preserves_stamina",player.survival.stamina==stamina_before and not player.player_defense.is_active())
	admitted.blocked = Rect2i()
	runtime.site_gate.advance()
	# Source permission alone does not grant motion: no native mesh has yet
	# published. Invoke the ordinary proof, not the movement implementation.
	var pending_collision := runtime.collision_proof_for_motion(start,start+Vector3(0.1,0,0),0.42)
	check("source_ready_still_requires_collision",not pending_collision.passed and not pending_collision.has("siteAdmission"))
	var deadline := Time.get_ticks_msec()+15000
	while Time.get_ticks_msec()<deadline and player.global_position.x<start.x+0.3:
		await _frames(1)
	check("real_player_resumes_through_shared_motor",player.global_position.x>start.x+0.3 and not player.get_meta("terrain_collision_hold",true))
	check("real_player_remains_on_collision_plane",player.global_position.y>-0.1 and player.global_position.y<0.2)
	check("ready_collision_accepts_real_dodge",player.request_dodge(Vector3.RIGHT) and player.player_defense.is_active() and player.survival.stamina<stamina_before)
	var before_dodge: Vector3 = player.global_position
	await _frames(2)
	check("accepted_dodge_uses_real_physics",player.global_position.x>before_dodge.x and player.global_position.y>-0.1)
	var before_failure: Vector3 = player.global_position
	admitted.failure = "synthetic_site_preparation_failed"
	runtime.last_site_wait_message_usec = -1000000
	await _frames(4)
	check("failed_source_stops_active_dodge",player.global_position==before_failure and player.velocity==Vector3.ZERO and player.last_terrain_collision_proof.get("reason")==admitted.failure)
	check("failed_source_stops_native_loading",not runtime.terrain.automatic_loading_enabled)
	check("failure_message_emitted",host.messages.any(func(value):return String(value).contains("Landmark loading failed")))
	player.set_physics_process(false)
	player_evidence = {"start":start,"end":player.global_position,"holdFrames":player.terrain_collision_hold_frames,
		"messages":host.messages,"lastProof":player.last_terrain_collision_proof,
		"fixture":"Production PlayerController/motor/defense/physics, synthetic flat native density and controllable admission; no act-phase position writes. Message emission recorded by synthetic host, not visible HUD validation."}
	runtime.begin_shutdown()
	var shutdown: Dictionary = await runtime.wait_for_seed_reset_task_drain()
	check("player_fixture_native_shutdown_drained",shutdown.ok)
	runtime.queue_free()
	player.queue_free()
	host.queue_free()
	await _frames(4)
	context.world_generation_system = null
	context.message_host = null
