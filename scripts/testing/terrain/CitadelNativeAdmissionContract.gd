extends SceneTree
## Native-engine integration with synthetic admission/terrain input. Not gameplay.
const Gate = preload("res://scripts/terrain/VoxelTerrainSiteGate.gd")
const Runtime = preload("res://scripts/terrain/VoxelTerrainRuntime.gd")
const ProductionWorld = preload("res://scripts/WorldGenerationSystem.gd")
const Store = preload("res://scripts/world/GeneratedSiteProfileStore.gd")
const Player = preload("res://scripts/PlayerController.gd")
const Survival = preload("res://scripts/SurvivalSystem.gd")
const PropHost = preload("res://scripts/Main.gd")
const PropStructures = preload("res://scripts/StructureSystem.gd")

class RuntimeContext extends "res://scripts/terrain/VoxelWorldGenerationContext.gd":
	var world_generation_system
	var structure_system
	var world_streaming
	var player: Node3D
	var startup_loading_active := true
	var runtime_loading_active := true
	var message_host
	func show_action_message(message: String, _passive := false) -> void:
		if message_host != null: message_host.show_action_message(message)

class PlayerHost extends Node:
	var runtime
	var hud = null
	var runtime_perf_monitor = null
	var messages: Array = []
	var overlay_shows: Array = []
	var overlay_hides: Array = []
	func terrain_collision_motion_proof(from: Vector3, to: Vector3, radius: float) -> Dictionary:
		return runtime.collision_proof_for_motion(from,to,radius)
	func show_action_message(message: String, _passive := false) -> void: messages.append(message)
	func show_streaming_loading_overlay(message: String, owner := "runtime_streaming") -> void:
		overlay_shows.append({"message":message,"owner":owner})
	func hide_streaming_loading_overlay(owner := "runtime_streaming") -> void: overlay_hides.append(owner)

class Structures extends RefCounted:
	var citadel_terrain_admission
	var physical_receipt: Dictionary = {"status":"ready","required":false}
	var physical_bounds := Rect2i()
	var physical_requests := 0
	# This native-terrain fixture deliberately has no building sources. The
	# publication receipt is synthetic; real service ownership is tested elsewhere.
	func advance_citadel_publication(_bounds := Rect2i(), _allow_dispatch := false) -> Dictionary:
		return {"publicationReady":false,"fixture":"synthetic_no_building_publication"}
	func citadel_physical_publication_state(bounds: Rect2i) -> Dictionary:
		physical_bounds = bounds
		physical_requests += 1
		return physical_receipt.duplicate(true)
	func region_readiness(bounds: Rect2i) -> Dictionary:
		# Synthetic regional receipt; real terrain/motor proof stays below it.
		return citadel_physical_publication_state(bounds)

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
	_natural_prop_admission()
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

func _natural_prop_admission() -> void:
	# Contract only: real prop scheduler/exclusion/admission, synthetic prepared
	# decision for the recorded ore site; no source worker or visual publication.
	var host = PropHost.new()
	host.seed_text = "atlas-3376622889"
	var structures := PropStructures.new()
	host.structure_system = structures
	var source = structures.citadel_terrain_admission
	source.configure(host.seed_text, {}, {"regionCells":host.STRUCTURE_REGION_CELLS,"spawnChance":host.STRUCTURE_SPAWN_CHANCE})
	source.finalize_town_inputs({})
	var ore_cell := Vector2i(-3314, -2804)
	var region := Vector2i(-2, -2)
	var reservation := Rect2i(-3483, -2963, 299, 293)
	var chunk := Node3D.new()
	var key := Vector2i(floori(float(ore_cell.x)/host.CHUNK_SIZE), floori(float(ore_cell.y)/host.CHUNK_SIZE))
	var state: Dictionary = host.begin_chunk_prop_spawn_state(chunk, key.x, key.y)
	var reference: Dictionary = host.begin_chunk_prop_spawn_state(chunk, key.x, key.y)
	var random_states := [state.rng.state, state.detailRng.state, state.undergroundRng.state]
	check("natural_props_unknown_is_not_permanent_exclusion", not structures.blocks_natural_prop_at_cell(ore_cell.x, ore_cell.y))
	for retry in range(2):
		check("natural_props_pending_retry_%d" % retry, not host.process_chunk_prop_spawn_state(state, 1, 1) and state.naturalPropAdmission.status == "pending")
	check("natural_props_pending_preserves_rng_and_attempts", random_states == [state.rng.state, state.detailRng.state, state.undergroundRng.state] and state.propIndex == 0 and state.detailIndex == 0 and state.phase == "props")
	host.spawn_chunk_props(chunk, key.x, key.y)
	check("natural_props_sync_pending_retained", host.pending_chunk_prop_spawns.has(key) and host.pending_chunk_prop_spawns[key].propIndex == 0 and host.pending_chunk_prop_spawns[key].rng.state == reference.rng.state)
	# The compact admitted decision survives source-cache eviction. Deliberately
	# leave _sources empty to prove no scene/source residency requirement.
	source._decisions[region] = {"status":"prepared", "siteId":"synthetic-prop-reservation", "sourceKey":"synthetic-source", "sourceSignature":"synthetic-signature", "reservationCells":reservation}
	check("natural_props_reservation_rejects_ore", structures.blocks_natural_prop_at_cell(ore_cell.x, ore_cell.y))
	check("natural_props_outside_reservation_allowed", not structures.blocks_natural_prop_at_cell(reservation.end.x, ore_cell.y))
	check("natural_props_reservation_respects_structure_margin", structures.blocks_natural_prop_with_separate_margins_at_cell(reservation.end.x, ore_cell.y, 0, 1))
	host.process_chunk_prop_spawn_state(state, 1, 1)
	host.process_chunk_prop_spawn_state(reference, 1, 1)
	check("natural_props_retry_matches_known_first_rng", state.propIndex == 1 and state.rng.state == reference.rng.state and state.detailRng.state == reference.detailRng.state and state.undergroundRng.state == reference.undergroundRng.state and chunk.get_child_count() == 0)
	# A surveyed absence permits progress too; unknown is never a permanent ban.
	source._decisions[region] = {"status":"absent"}
	check("natural_props_absent_admission_ready", source.request_bounds(Rect2i(ore_cell, Vector2i.ONE)).status == "ready" and not structures.blocks_natural_prop_at_cell(ore_cell.x, ore_cell.y))
	host.pending_chunk_prop_spawns.clear()
	chunk.free()
	host.free()

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
	context.world_streaming = structure_owner
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
	context.world_streaming = structure_owner
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
	check("ordinary_source_wait_never_opens_modal_overlay",host.overlay_shows.is_empty())
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
	var physical_evidence: Dictionary = await _physical_publication_controls(runtime,player,structure_owner,host)
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
	check("failed_source_message_keeps_exact_reason",host.messages.any(func(value):return String(value).contains("Landmark loading failed: synthetic_site_preparation_failed")))
	player.set_physics_process(false)
	player_evidence = {"start":start,"end":player.global_position,"holdFrames":player.terrain_collision_hold_frames,
		"messages":host.messages,"lastProof":player.last_terrain_collision_proof,
		"physicalPublication":physical_evidence,
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

func _physical_publication_controls(runtime: ObservedRuntime, player, structures: Structures, host: PlayerHost) -> Dictionary:
	# The native plane is already published. Only the synthetic structure receipt
	# changes below; the act uses ordinary Player physics and never writes position.
	# Structure state remains visible in proof telemetry while late construction's
	# capsule guard, rather than a modal movement hold, owns physical safety.
	var before: Vector3 = player.global_position
	var no_landmark: Dictionary = runtime.collision_proof_for_motion(before,before,0.42)
	check("physical_no_landmark_ready_preserves_native_motion",no_landmark.passed and structures.physical_requests>0
		and no_landmark.get("structurePublication")==structures.physical_receipt)
	var mesh: Dictionary = runtime.collision_mesh_ready_for_body_position(before,0.42)
	check("physical_controls_have_native_collision",bool(mesh.get("passed",false)))
	structures.physical_receipt = {"status":"pending","required":true,"reason":"synthetic_buildings_pending","siteIds":["synthetic_native_site"]}
	var hold_before := int(player.terrain_collision_hold_frames)
	var message_count := host.messages.size()
	var overlay_count := host.overlay_shows.size()
	await _frames(4)
	var pending: Dictionary = player.last_terrain_collision_proof.duplicate(true)
	check("physical_pending_does_not_hold_real_player",player.global_position.x>before.x
		and player.terrain_collision_hold_frames==hold_before and not player.get_meta("terrain_collision_hold",false))
	check("physical_pending_preserves_structured_observation",pending.get("passed",false)
		and pending.get("structurePublication")==structures.physical_receipt and not pending.has("siteAdmission"))
	check("physical_pending_never_enters_wait_state",not runtime.site_traversal_waiting)
	check("physical_pending_emits_no_modal_or_repeated_status",host.overlay_shows.size()==overlay_count
		and host.messages.size()==message_count)
	# This direct local proof checks that the aligned region observation still
	# reaches the structure owner without depending on its result.
	var sweep_from: Vector3 = player.global_position
	var sweep: Dictionary = runtime.collision_proof_for_motion(sweep_from,sweep_from,0.42)
	var captured_bounds := structures.physical_bounds
	check("physical_observation_reaches_structure_owner",sweep.get("passed",false)
		and sweep.get("structurePublication")==structures.physical_receipt and captured_bounds.size==Vector2i(16,16))
	structures.physical_receipt = {"status":"ready","required":true,"siteIds":["synthetic_native_site"]}
	await _frames(2)
	check("physical_pending_to_ready_keeps_real_motor_running",player.last_terrain_collision_proof.get("passed",false))
	before = player.global_position
	structures.physical_receipt = {"status":"failed","required":true,"reason":"synthetic_building_publication_failed","siteIds":["synthetic_native_site"]}
	await _frames(4)
	var failed: Dictionary = player.last_terrain_collision_proof.duplicate(true)
	check("physical_failed_does_not_hold_real_player",player.global_position.x>before.x and not player.get_meta("terrain_collision_hold",false))
	check("physical_failed_preserves_structured_observation",failed.get("passed",false)
		and failed.get("structurePublication")==structures.physical_receipt and not failed.has("siteAdmission"))
	check("physical_failed_never_opens_modal_overlay",host.overlay_shows.size()==overlay_count)
	structures.physical_receipt = {"status":"ready","required":true,"siteIds":["synthetic_native_site"]}
	var deadline := Time.get_ticks_msec()+3000
	while Time.get_ticks_msec()<deadline and player.global_position.x<before.x+0.1: await _frames(1)
	var ready: Dictionary = player.last_terrain_collision_proof.duplicate(true)
	check("physical_ready_keeps_real_motor_running",player.global_position.x>before.x+0.1 and ready.get("passed",false))
	check("physical_ready_clears_waiting",not runtime.site_traversal_waiting and not player.get_meta("terrain_collision_hold",true))
	# The caller immediately exercises the original successful real dodge and
	# source-failure-during-dodge controls with this required/ready receipt active.
	return {"pending":pending,"failed":failed,"ready":ready,"observedBounds":captured_bounds,"modalOverlayShows":host.overlay_shows.duplicate(true),
		"fixture":"Synthetic physical-publication receipts; real native collision proof, Player motor and dodge. No actual building publication or live gameplay acceptance."}
