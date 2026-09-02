extends Node3D
class_name VoxelTerrainRuntime

const GENERATOR_SCRIPT := preload("res://scripts/terrain/VoxelTerrainGenerator.gd")
const CONTEXT_SCRIPT := preload("res://scripts/terrain/VoxelWorldGenerationContext.gd")
const SITE_GATE_SCRIPT := preload("res://scripts/terrain/VoxelTerrainSiteGate.gd")
const STARTUP_READINESS_RESULT_SCRIPT := preload("res://scripts/world/StartupReadinessResult.gd")
const TERRAIN_SHADER := preload("res://shaders/voxel_terrain_authority.gdshader")

const CELL := 1.35
const GAME_CHUNK_SIZE := 28
const TERRAIN_COLLISION_LAYER := 2
const FINAL_VIEW_DISTANCE := 112
const STARTUP_VIEW_DISTANCE := 80
const VIEW_DISTANCE_EXPANSION_STEP := 16
const VIEW_DISTANCE_EXPANSION_INTERVAL_SECONDS := 2.0
const STARTUP_VERTICAL_MIN_CELL := -16
const STARTUP_VERTICAL_MAX_CELL := 48
const VERTICAL_BOUNDS_EXPANSION_STEP_CELLS := 16
const SECTION_SIZE := 16
const EDIT_SECTIONS_PER_FRAME := 1
const PUBLICATION_PROBES_PER_PHYSICS_FRAME := 2
const COLLISION_SURFACE_TOLERANCE := CELL * 2.5
const COLLISION_MESH_VERTICAL_MARGIN_CELLS := 4
const SEED_RESET_TASK_DRAIN_TIMEOUT_SECONDS := 30.0
const SEED_RESET_REQUIRED_QUIET_FRAMES := 2
const MATERIAL_IDS := {
	"air": 0, "grass": 1, "dirt": 2, "stone": 3, "sand": 4, "snow": 5,
	"deepStone": 6, "bedrock": 7, "clay": 8, "gravel": 9, "coalOre": 10,
	"ironOre": 11, "crystalOre": 12, "copperOre": 13, "mud": 14, "water": 15
}

var main
var terrain: VoxelTerrain
var viewer: VoxelViewer
var generator
var authority_ready := false
var published_mesh_blocks := {}
var configured_seed := ""
var last_volume_revision := -1
var applied_edit_signatures := {}
var pending_edit_sections := {}
var edit_batches_applied := 0
var desired_gameplay_chunks := {}
var pending_gameplay_chunks := {}
var pending_gameplay_chunk_order: Array[Vector2i] = []
var published_gameplay_chunks := {}
var collision_probe_attempts := 0
var collision_probe_passes := 0
var view_distance_expansion_elapsed := 0.0
var view_distance_expansion_requested := false
var startup_auxiliary_viewers: Array[Dictionary] = []
var startup_auxiliary_cleanup_requested := false
var startup_auxiliary_cleanup_frames_remaining := 0
var startup_auxiliary_viewers_created := 0
var site_gate
var site_traversal_waiting := false
var last_site_wait_message_usec := 0

func setup(main_node) -> Dictionary:
	main = main_node
	configured_seed = String(main.get("seed_text"))
	if not required_classes_available():
		return {"ok": false, "reason": "voxel_tools_runtime_classes_missing"}
	var generation_state := build_generation_state()
	if not bool(generation_state.get("ok", false)):
		return generation_state
	apply_generation_tracking(generation_state)

	terrain = VoxelTerrain.new()
	terrain.automatic_loading_enabled = false
	terrain.name = "VoxelTerrainAuthority"
	terrain.set_meta("kind", "terrain")
	terrain.set_meta("geometry_source", "voxel_sdf_authority")
	terrain.set_meta("collision_source", "VoxelMesherTransvoxel")
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
	terrain.generator = generator
	terrain.generate_collisions = true
	terrain.collision_layer = TERRAIN_COLLISION_LAYER
	terrain.collision_mask = 0
	terrain.mesh_block_size = 16
	terrain.max_view_distance = 128
	apply_startup_vertical_bounds()
	terrain.scale = Vector3.ONE * CELL
	var material := ShaderMaterial.new()
	material.shader = TERRAIN_SHADER
	terrain.material_override = material
	add_child(terrain)
	site_gate = SITE_GATE_SCRIPT.new()
	site_gate.setup(self,terrain,main.structure_system.citadel_terrain_admission,main.world_generation_system)

	viewer = VoxelViewer.new()
	viewer.name = "VoxelTerrainViewer"
	viewer.view_distance = STARTUP_VIEW_DISTANCE
	viewer.requires_visuals = true
	viewer.requires_collisions = true
	update_viewer_position()
	terrain.mesh_block_entered.connect(on_mesh_block_entered)
	terrain.mesh_block_exited.connect(on_mesh_block_exited)
	authority_ready = true
	return {"ok": true, "backend": "VoxelTerrain", "mesher": "VoxelMesherTransvoxel"}

func reset_for_current_seed_staged() -> Dictionary:
	if main == null:
		return STARTUP_READINESS_RESULT_SCRIPT.failed("voxel_terrain_reset_main_missing")
	if terrain == null or not is_instance_valid(terrain):
		return STARTUP_READINESS_RESULT_SCRIPT.failed("voxel_terrain_reset_authority_missing")
	var next_seed := String(main.get("seed_text"))
	if next_seed.strip_edges() == "":
		return STARTUP_READINESS_RESULT_SCRIPT.failed("voxel_terrain_reset_seed_missing")
	if generation_context_current() and authority_ready:
		return STARTUP_READINESS_RESULT_SCRIPT.ready({}, {
			"seed": configured_seed,
			"resetMode": "already_current",
			"terrainInstanceId": terrain.get_instance_id()
		})
	var generation_state := build_generation_state()
	if not bool(generation_state.get("ok", false)):
		return STARTUP_READINESS_RESULT_SCRIPT.failed(
			String(generation_state.get("reason", "voxel_terrain_generation_state_failed"))
		)
	var previous_seed := configured_seed
	var terrain_instance_id := terrain.get_instance_id()
	var previous_mesh_blocks := published_mesh_blocks.size()
	var previous_gameplay_chunks := published_gameplay_chunks.size()
	var invalidated_chunks := invalidate_gameplay_publication()
	if site_gate != null: site_gate.stop()
	clear_startup_auxiliary_viewers()
	authority_ready = false
	set_process(false)
	set_physics_process(false)
	if viewer != null and is_instance_valid(viewer):
		viewer.requires_visuals = false
		viewer.requires_collisions = false
	terrain.automatic_loading_enabled = false
	await get_tree().physics_frame
	# Voxel generation and meshing are native asynchronous work.  Swapping the
	# script generator before that work has stopped can leave a task holding the
	# previous generator while the terrain is already configured for a new seed.
	# The Voxel Tools documentation explicitly warns that changing a script while
	# worker threads are using it is undefined behavior, so preserve the loading
	# screen and wait for a stable idle boundary before the replacement.
	var task_drain_result := await wait_for_seed_reset_task_drain()
	if not bool(task_drain_result.get("ok", false)):
		return task_drain_result
	var reset_started_usec := Time.get_ticks_usec()
	var next_generator = generation_state.get("generator")
	terrain.generator = next_generator
	var reset_map_usec := Time.get_ticks_usec() - reset_started_usec
	if terrain.generator != next_generator:
		return STARTUP_READINESS_RESULT_SCRIPT.failed("voxel_terrain_generator_replacement_failed", {}, [], {
			"previousSeed": previous_seed,
			"nextSeed": next_seed,
			"terrainInstanceId": terrain_instance_id,
			"resetMapUsec": reset_map_usec
		})
	published_mesh_blocks.clear()
	pending_edit_sections.clear()
	edit_batches_applied = 0
	collision_probe_attempts = 0
	collision_probe_passes = 0
	apply_generation_tracking(generation_state)
	configured_seed = next_seed
	apply_startup_vertical_bounds()
	site_gate = SITE_GATE_SCRIPT.new()
	site_gate.setup(self,terrain,main.structure_system.citadel_terrain_admission,main.world_generation_system)
	if viewer != null and is_instance_valid(viewer):
		viewer.requires_visuals = true
		viewer.requires_collisions = true
		viewer.view_distance = STARTUP_VIEW_DISTANCE
	view_distance_expansion_elapsed = 0.0
	view_distance_expansion_requested = false
	update_viewer_position()
	authority_ready = true
	set_process(true)
	set_physics_process(true)
	await get_tree().process_frame
	return STARTUP_READINESS_RESULT_SCRIPT.ready({}, {
		"previousSeed": previous_seed,
		"seed": configured_seed,
		"resetMode": "in_place_generator_reload",
		"terrainInstanceId": terrain_instance_id,
		"terrainInstancePreserved": terrain.get_instance_id() == terrain_instance_id,
		"previousPublishedMeshBlocks": previous_mesh_blocks,
		"previousPublishedGameplayChunks": previous_gameplay_chunks,
		"invalidatedGameplayChunks": invalidated_chunks,
		"resetMapUsec": reset_map_usec,
		"taskDrain": task_drain_result.get("metrics", {})
	})

func wait_for_seed_reset_task_drain() -> Dictionary:
	var drain_started_usec := Time.get_ticks_usec()
	var checks := 0
	var quiet_frames := 0
	var peak_pending_tasks := 0
	var last_pending_tasks := -1
	while quiet_frames < SEED_RESET_REQUIRED_QUIET_FRAMES:
		if terrain == null or not is_instance_valid(terrain):
			return STARTUP_READINESS_RESULT_SCRIPT.failed("voxel_terrain_reset_authority_missing")
		var pending_tasks := voxel_engine_pending_task_count()
		peak_pending_tasks = maxi(peak_pending_tasks, pending_tasks)
		checks += 1
		if pending_tasks <= 0:
			quiet_frames += 1
		else:
			quiet_frames = 0
		var elapsed_seconds := float(Time.get_ticks_usec() - drain_started_usec) / 1000000.0
		if elapsed_seconds >= SEED_RESET_TASK_DRAIN_TIMEOUT_SECONDS:
			return STARTUP_READINESS_RESULT_SCRIPT.failed("voxel_terrain_seed_reset_task_drain_timeout", {}, [], {
				"pendingTasks": pending_tasks,
				"peakPendingTasks": peak_pending_tasks,
				"checks": checks,
				"elapsedMs": elapsed_seconds * 1000.0
			})
		if quiet_frames >= SEED_RESET_REQUIRED_QUIET_FRAMES:
			break
		if main != null and is_instance_valid(main) and main.has_method("startup_loading_yield") \
				and (checks == 1 or pending_tasks != last_pending_tasks or checks % 30 == 0):
			await main.call("startup_loading_yield", "Retiring previous terrain: %d tasks" % pending_tasks, "terrain_authority", "pending", {
				"pendingTasks": pending_tasks,
				"peakPendingTasks": peak_pending_tasks,
				"checks": checks
			})
		else:
			await get_tree().process_frame
		last_pending_tasks = pending_tasks
	return STARTUP_READINESS_RESULT_SCRIPT.ready({}, {
		"pendingTasks": 0,
		"peakPendingTasks": peak_pending_tasks,
		"checks": checks,
		"quietFrames": quiet_frames,
		"elapsedMs": float(Time.get_ticks_usec() - drain_started_usec) / 1000.0
	})

func build_generation_state() -> Dictionary:
	if main == null:
		return {"ok": false, "reason": "voxel_terrain_generation_main_missing"}
	var structures = main.get("structure_system")
	if structures == null:
		return {"ok":false,"reason":"terrain_structure_owner_missing"}
	var admission = structures.citadel_terrain_admission
	if admission.world_seed != String(main.seed_text) or admission.profile_store.world_seed() != String(main.seed_text):
		if terrain != null: terrain.automatic_loading_enabled = false
		return {"ok":false,"reason":"citadel_admission_seed_mismatch"}
	var inputs: Dictionary = admission.finalize_town_inputs(main.town_region_cache)
	if inputs.status != "ready":
		if terrain != null: terrain.automatic_loading_enabled = false
		return {"ok":false,"reason":inputs.reason}
	main.world_generation_system.bind_generated_site_profile_store(structures.citadel_terrain_admission.profile_store)
	var context = CONTEXT_SCRIPT.new()
	context.setup_from_main(main,inputs.towns)
	var signatures := {}
	for cell_value in context.initial_terrain_edits.keys():
		var state: Dictionary = context.initial_terrain_edits[cell_value]
		signatures[cell_value] = edit_signature(state)
	var next_generator = GENERATOR_SCRIPT.new()
	next_generator.setup(context)
	var service = volume_service()
	return {
		"ok": true,
		"generator": next_generator,
		"editSignatures": signatures,
		"volumeRevision": int(service.get("revision")) if service != null else -1
	}

func apply_generation_tracking(generation_state: Dictionary) -> void:
	generator = generation_state.get("generator")
	var signatures_value = generation_state.get("editSignatures", {})
	applied_edit_signatures = (signatures_value as Dictionary).duplicate(true) if signatures_value is Dictionary else {}
	last_volume_revision = int(generation_state.get("volumeRevision", -1))

func generation_context_current() -> bool:
	return main != null and configured_seed == String(main.seed_text) and site_gate != null and site_gate.current() \
		and main.structure_system.citadel_terrain_admission.world_seed == configured_seed

func admit_gameplay_chunk(chunk_key: Vector2i) -> Dictionary:
	if site_gate == null: return {"status":"failed","reason":"terrain_site_gate_missing"}
	return site_gate.request_cells(Rect2i(chunk_key*GAME_CHUNK_SIZE,Vector2i.ONE*GAME_CHUNK_SIZE).grow(2))

func wait_for_site_admission(chunk_keys: Array) -> Dictionary:
	# Source preparation precedes the existing chunk/collision readiness clocks.
	# Keep the real loading overlay responsive; do not widen their timeouts.
	while true:
		var pending := false
		for chunk_key: Vector2i in chunk_keys:
			var result := admit_gameplay_chunk(chunk_key)
			if result.status == "failed": return STARTUP_READINESS_RESULT_SCRIPT.failed(result.reason)
			pending = pending or result.status != "ready"
		var player_value = main.get("player")
		if player_value is Node3D:
			var result: Dictionary = site_gate.request_cells(SITE_GATE_SCRIPT.footprint(player_value.global_position,STARTUP_VIEW_DISTANCE))
			if result.status == "failed": return STARTUP_READINESS_RESULT_SCRIPT.failed(result.reason)
			pending = pending or result.status != "ready"
		if not pending: return STARTUP_READINESS_RESULT_SCRIPT.ready({})
		var admission = main.structure_system.citadel_terrain_admission
		await main.startup_loading_yield("Preparing landmark foundations", "citadel_terrain", "pending",admission.stats())
	return STARTUP_READINESS_RESULT_SCRIPT.failed("site_admission_interrupted")

func invalidate_gameplay_publication() -> int:
	var invalidated := published_gameplay_chunks.size()
	for chunk_value in published_gameplay_chunks.keys():
		if chunk_value is Vector2i:
			notify_navigation_chunk_unloaded(chunk_value)
	desired_gameplay_chunks.clear()
	pending_gameplay_chunks.clear()
	pending_gameplay_chunk_order.clear()
	published_gameplay_chunks.clear()
	return invalidated

func full_vertical_cell_bounds() -> Vector2i:
	if main == null:
		return Vector2i(STARTUP_VERTICAL_MIN_CELL, STARTUP_VERTICAL_MAX_CELL)
	var world_generation = main.get("world_generation_system")
	if world_generation == null:
		return Vector2i(STARTUP_VERTICAL_MIN_CELL, STARTUP_VERTICAL_MAX_CELL)
	return Vector2i(
		int(world_generation.call("world_bottom_cell_y")) - COLLISION_MESH_VERTICAL_MARGIN_CELLS,
		int(world_generation.call("world_top_cell_y")) + COLLISION_MESH_VERTICAL_MARGIN_CELLS
	)

func apply_vertical_cell_bounds(min_cell: int, max_cell: int) -> void:
	if terrain == null or main == null:
		return
	var full_bounds := full_vertical_cell_bounds()
	var bottom_cell := clampi(min_cell, full_bounds.x, full_bounds.y)
	var top_cell := clampi(max_cell, bottom_cell, full_bounds.y)
	var terrain_bounds := terrain.bounds
	terrain_bounds.position.y = float(bottom_cell)
	terrain_bounds.size.y = float(top_cell - bottom_cell + 1)
	terrain.bounds = terrain_bounds

func apply_startup_vertical_bounds() -> void:
	var full_bounds := full_vertical_cell_bounds()
	apply_vertical_cell_bounds(
		maxi(full_bounds.x, STARTUP_VERTICAL_MIN_CELL),
		mini(full_bounds.y, STARTUP_VERTICAL_MAX_CELL)
	)

func configure_startup_collision_bounds(chunk_keys: Array) -> void:
	clear_startup_auxiliary_viewers()
	if terrain == null or main == null or chunk_keys.is_empty():
		return
	var world_generation = main.get("world_generation_system")
	if world_generation == null or not world_generation.has_method("surface_y_at"):
		return
	var min_surface_cell := 2147483000
	var max_surface_cell := -2147483000
	for key_value in chunk_keys:
		if not (key_value is Vector2i):
			continue
		var chunk_key: Vector2i = key_value
		var center := Vector3(
			(float(chunk_key.x * GAME_CHUNK_SIZE) + float(GAME_CHUNK_SIZE) * 0.5) * CELL,
			0.0,
			(float(chunk_key.y * GAME_CHUNK_SIZE) + float(GAME_CHUNK_SIZE) * 0.5) * CELL
		)
		var surface_cell := floori(float(world_generation.call("surface_y_at", center)) / CELL)
		min_surface_cell = mini(min_surface_cell, surface_cell)
		max_surface_cell = maxi(max_surface_cell, surface_cell)
	if min_surface_cell > max_surface_cell:
		return
	apply_vertical_cell_bounds(min_surface_cell - 16, max_surface_cell + 16)
	configure_startup_auxiliary_viewers(chunk_keys, world_generation)


func configure_startup_auxiliary_viewers(chunk_keys: Array, world_generation) -> void:
	if viewer == null or not is_instance_valid(viewer):
		return
	var components := connected_gameplay_chunk_components(chunk_keys)
	for component_value in components:
		var component: Array = component_value
		if primary_viewer_covers_component(component):
			continue
		for spec_value in auxiliary_viewer_specs_for_component(component, world_generation):
			var spec: Dictionary = spec_value
			var auxiliary := VoxelViewer.new()
			auxiliary.name = "StartupAuxiliaryVoxelViewer_%d" % startup_auxiliary_viewers_created
			auxiliary.view_distance = int(spec.get("viewDistance", STARTUP_VIEW_DISTANCE))
			auxiliary.requires_visuals = true
			auxiliary.requires_collisions = true
			auxiliary.set_meta("startup_auxiliary", true)
			site_gate.request_viewer(auxiliary,spec.get("position",Vector3.ZERO),auxiliary.view_distance)
			startup_auxiliary_viewers.append({
				"viewer": auxiliary,
				"chunks": (spec.get("chunks", []) as Array).duplicate()
			})
			startup_auxiliary_viewers_created += 1


func connected_gameplay_chunk_components(chunk_keys: Array) -> Array:
	var remaining := {}
	for key_value in chunk_keys:
		if key_value is Vector2i:
			remaining[key_value] = true
	var components: Array = []
	while not remaining.is_empty():
		var ordered_keys: Array = remaining.keys()
		ordered_keys.sort_custom(func(a: Vector2i, b: Vector2i):
			return a.x < b.x if a.x != b.x else a.y < b.y
		)
		var seed: Vector2i = ordered_keys[0]
		var pending: Array[Vector2i] = [seed]
		var component: Array[Vector2i] = []
		remaining.erase(seed)
		while not pending.is_empty():
			var current: Vector2i = pending.pop_front()
			component.append(current)
			for neighbor in [
				current + Vector2i.LEFT,
				current + Vector2i.RIGHT,
				current + Vector2i.UP,
				current + Vector2i.DOWN
			]:
				if remaining.erase(neighbor):
					pending.append(neighbor)
		component.sort_custom(func(a: Vector2i, b: Vector2i):
			return a.x < b.x if a.x != b.x else a.y < b.y
		)
		components.append(component)
	return components


func primary_viewer_covers_component(component: Array) -> bool:
	if viewer == null or not is_instance_valid(viewer) or not viewer.is_inside_tree() or component.is_empty():
		return false
	var available_distance := maxf(0.0, float(viewer.view_distance) - CELL * 4.0)
	var viewer_xz := Vector2(viewer.global_position.x, viewer.global_position.z)
	var half_chunk_diagonal := float(GAME_CHUNK_SIZE) * CELL * sqrt(2.0) * 0.5
	for key_value in component:
		if not (key_value is Vector2i):
			continue
		var chunk_key: Vector2i = key_value
		var center := Vector2(
			(float(chunk_key.x * GAME_CHUNK_SIZE) + float(GAME_CHUNK_SIZE) * 0.5) * CELL,
			(float(chunk_key.y * GAME_CHUNK_SIZE) + float(GAME_CHUNK_SIZE) * 0.5) * CELL
		)
		if viewer_xz.distance_to(center) + half_chunk_diagonal > available_distance:
			return false
	return true


func auxiliary_viewer_specs_for_component(component: Array, world_generation) -> Array[Dictionary]:
	var specs: Array[Dictionary] = []
	if component.is_empty():
		return specs
	var min_chunk := Vector2i(2147483000, 2147483000)
	var max_chunk := Vector2i(-2147483000, -2147483000)
	for key_value in component:
		if not (key_value is Vector2i):
			continue
		var chunk_key: Vector2i = key_value
		min_chunk = Vector2i(mini(min_chunk.x, chunk_key.x), mini(min_chunk.y, chunk_key.y))
		max_chunk = Vector2i(maxi(max_chunk.x, chunk_key.x), maxi(max_chunk.y, chunk_key.y))
	var minimum := Vector2(float(min_chunk.x * GAME_CHUNK_SIZE) * CELL, float(min_chunk.y * GAME_CHUNK_SIZE) * CELL)
	var maximum := Vector2(float((max_chunk.x + 1) * GAME_CHUNK_SIZE) * CELL, float((max_chunk.y + 1) * GAME_CHUNK_SIZE) * CELL)
	var center_xz := (minimum + maximum) * 0.5
	var required_distance := center_xz.distance_to(maximum) + CELL * 16.0
	var maximum_view_distance := int(terrain.max_view_distance) if terrain != null else FINAL_VIEW_DISTANCE
	if required_distance <= float(maximum_view_distance):
		var center_position := Vector3(center_xz.x, 0.0, center_xz.y)
		center_position.y = float(world_generation.call("surface_y_at", center_position))
		specs.append({
			"position": center_position,
			"viewDistance": clampi(ceili(required_distance), STARTUP_VIEW_DISTANCE, maximum_view_distance),
			"chunks": component.duplicate()
		})
		return specs
	for key_value in component:
		if not (key_value is Vector2i):
			continue
		var chunk_key: Vector2i = key_value
		var position := Vector3(
			(float(chunk_key.x * GAME_CHUNK_SIZE) + float(GAME_CHUNK_SIZE) * 0.5) * CELL,
			0.0,
			(float(chunk_key.y * GAME_CHUNK_SIZE) + float(GAME_CHUNK_SIZE) * 0.5) * CELL
		)
		position.y = float(world_generation.call("surface_y_at", position))
		specs.append({
			"position": position,
			"viewDistance": STARTUP_VIEW_DISTANCE,
			"chunks": [chunk_key]
		})
	return specs


func clear_startup_auxiliary_viewers() -> void:
	for record_value in startup_auxiliary_viewers:
		var record: Dictionary = record_value
		var auxiliary = record.get("viewer")
		if auxiliary == null or not is_instance_valid(auxiliary):
			continue
		auxiliary.requires_visuals = false
		auxiliary.requires_collisions = false
		if site_gate != null: site_gate.remove_viewer(auxiliary)
		auxiliary.queue_free()
	startup_auxiliary_viewers.clear()
	startup_auxiliary_cleanup_requested = false
	startup_auxiliary_cleanup_frames_remaining = 0


func prune_startup_auxiliary_viewers() -> void:
	if not startup_auxiliary_cleanup_requested:
		return
	if startup_auxiliary_viewers.is_empty():
		startup_auxiliary_cleanup_requested = false
		startup_auxiliary_cleanup_frames_remaining = 0
		return
	if startup_auxiliary_cleanup_frames_remaining > 0:
		startup_auxiliary_cleanup_frames_remaining -= 1
		return
	clear_startup_auxiliary_viewers()


func startup_auxiliary_viewer_diagnostics() -> Array:
	var diagnostics: Array = []
	for record_value in startup_auxiliary_viewers:
		var record: Dictionary = record_value
		var auxiliary = record.get("viewer")
		if auxiliary == null or not is_instance_valid(auxiliary):
			continue
		var keys: Array[String] = []
		var chunks_value = record.get("chunks", [])
		if chunks_value is Array:
			for key_value in chunks_value:
				if key_value is Vector2i:
					keys.append("%d,%d" % [key_value.x, key_value.y])
		diagnostics.append({
			"name": auxiliary.name,
			"position": auxiliary.global_position,
			"viewDistance": int(auxiliary.view_distance),
			"requiresVisuals": bool(auxiliary.requires_visuals),
			"requiresCollisions": bool(auxiliary.requires_collisions),
			"chunks": keys
		})
	return diagnostics

func vertical_cell_bounds() -> Vector2i:
	if terrain == null:
		return Vector2i.ZERO
	var current := terrain.bounds
	var min_cell := floori(current.position.y)
	return Vector2i(min_cell, min_cell + floori(current.size.y) - 1)

func expand_vertical_bounds_step() -> void:
	var current := vertical_cell_bounds()
	var target := full_vertical_cell_bounds()
	if current == target:
		return
	apply_vertical_cell_bounds(
		maxi(target.x, current.x - VERTICAL_BOUNDS_EXPANSION_STEP_CELLS),
		mini(target.y, current.y + VERTICAL_BOUNDS_EXPANSION_STEP_CELLS)
	)

func _process(delta: float) -> void:
	if authority_ready:
		if not generation_context_current():
			terrain.automatic_loading_enabled = false
			return
		if site_gate != null: site_gate.advance()
		update_viewer_position()
		update_viewer_distance(delta)
		prune_startup_auxiliary_viewers()
		collect_volume_edit_changes()
		process_pending_edit_sections()

func _physics_process(_delta: float) -> void:
	if authority_ready and generation_context_current():
		process_pending_gameplay_chunk_publications()


func _exit_tree() -> void:
	if site_gate != null: site_gate.stop()
	if viewer != null and is_instance_valid(viewer) and viewer.get_parent() != self:
		viewer.queue_free()

func begin_shutdown() -> void:
	authority_ready = false
	if site_gate != null: site_gate.stop()
	set_process(false)
	set_physics_process(false)
	if viewer != null and is_instance_valid(viewer):
		viewer.requires_visuals = false
		viewer.requires_collisions = false
		viewer.queue_free()
		viewer = null
	clear_startup_auxiliary_viewers()
	if terrain != null and is_instance_valid(terrain):
		terrain.automatic_loading_enabled = false
	pending_gameplay_chunks.clear()
	pending_gameplay_chunk_order.clear()
	desired_gameplay_chunks.clear()
	view_distance_expansion_elapsed = 0.0
	view_distance_expansion_requested = false


func request_final_view_distance_expansion() -> void:
	if not authority_ready:
		return
	view_distance_expansion_requested = true
	view_distance_expansion_elapsed = 0.0
	startup_auxiliary_cleanup_requested = true
	startup_auxiliary_cleanup_frames_remaining = 2

func update_viewer_distance(delta: float) -> void:
	if viewer == null or not is_instance_valid(viewer) or not viewer.is_inside_tree() or main == null:
		return
	var loading := bool(main.get("startup_loading_active")) or bool(main.get("runtime_loading_active"))
	if loading:
		if int(viewer.view_distance) != STARTUP_VIEW_DISTANCE:
			viewer.view_distance = STARTUP_VIEW_DISTANCE
		view_distance_expansion_elapsed = 0.0
		return
	if not view_distance_expansion_requested:
		return
	var vertical_bounds_ready := vertical_cell_bounds() == full_vertical_cell_bounds()
	if int(viewer.view_distance) >= FINAL_VIEW_DISTANCE and vertical_bounds_ready:
		return
	view_distance_expansion_elapsed += maxf(0.0, delta)
	if view_distance_expansion_elapsed < VIEW_DISTANCE_EXPANSION_INTERVAL_SECONDS:
		return
	view_distance_expansion_elapsed = 0.0
	var next_distance := mini(FINAL_VIEW_DISTANCE,int(viewer.view_distance)+VIEW_DISTANCE_EXPANSION_STEP)
	if site_gate.request_viewer(viewer,viewer.global_position,next_distance):
		expand_vertical_bounds_step()

func voxel_engine_task_stats() -> Dictionary:
	if not Engine.has_singleton("VoxelEngine"):
		return {}
	var voxel_engine = Engine.get_singleton("VoxelEngine")
	if voxel_engine == null or not voxel_engine.has_method("get_stats"):
		return {}
	var stats_value = voxel_engine.call("get_stats")
	return (stats_value as Dictionary).duplicate(true) if stats_value is Dictionary else {}

func voxel_engine_pending_task_count() -> int:
	var engine_stats := voxel_engine_task_stats()
	var tasks_value = engine_stats.get("tasks", {})
	if not (tasks_value is Dictionary):
		return 0
	var tasks: Dictionary = tasks_value
	var total := 0
	for key in ["streaming", "meshing", "generation", "main_thread", "gpu"]:
		total += maxi(0, int(tasks.get(key, 0)))
	return total

func update_viewer_position() -> void:
	if viewer == null or main == null:
		return
	var player_value = main.get("player")
	if player_value is Node3D and is_instance_valid(player_value):
		site_gate.request_viewer(viewer,(player_value as Node3D).global_position,viewer.view_distance)

func required_classes_available() -> bool:
	for class_name_value in ["VoxelTerrain", "VoxelViewer", "VoxelMesherTransvoxel", "VoxelFormat"]:
		if not ClassDB.class_exists(class_name_value):
			return false
	return true

func on_mesh_block_entered(block_position: Vector3i) -> void:
	published_mesh_blocks[block_position] = true
	queue_loaded_block_edit_sections(block_position)

func on_mesh_block_exited(block_position: Vector3i) -> void:
	published_mesh_blocks.erase(block_position)

func stats() -> Dictionary:
	return {
		"citadelAdmission":main.structure_system.citadel_terrain_admission.stats() if main != null and main.structure_system != null else {},
		"siteAdmissionFailure":site_gate.failure_reason() if site_gate != null else "",
		"ready": authority_ready,
		"publishedMeshBlocks": published_mesh_blocks.size(),
		"pendingEditSections": pending_edit_sections.size(),
		"editBatchesApplied": edit_batches_applied,
		"lastVolumeRevision": last_volume_revision,
		"appliedEditSignatures": applied_edit_signatures.size(),
		"desiredGameplayChunks": desired_gameplay_chunks.size(),
		"pendingGameplayChunks": pending_gameplay_chunks.size(),
		"pendingGameplayChunkQueue": pending_gameplay_chunk_order.size(),
		"publishedGameplayChunks": published_gameplay_chunks.size(),
		"collisionProbeAttempts": collision_probe_attempts,
		"collisionProbePasses": collision_probe_passes,
		"startupViewDistance": STARTUP_VIEW_DISTANCE,
		"currentViewDistance": int(viewer.view_distance) if viewer != null and is_instance_valid(viewer) else 0,
		"finalViewDistance": FINAL_VIEW_DISTANCE,
		"viewDistanceExpansionRequested": view_distance_expansion_requested,
		"startupAuxiliaryViewerCount": startup_auxiliary_viewers.size(),
		"startupAuxiliaryViewersCreated": startup_auxiliary_viewers_created,
		"startupAuxiliaryCleanupRequested": startup_auxiliary_cleanup_requested,
		"startupAuxiliaryCleanupFramesRemaining": startup_auxiliary_cleanup_frames_remaining,
		"startupAuxiliaryViewers": startup_auxiliary_viewer_diagnostics(),
		"verticalCellBounds": vertical_cell_bounds(),
		"finalVerticalCellBounds": full_vertical_cell_bounds(),
		"voxelEngine": voxel_engine_task_stats(),
		"terrain": terrain.get_statistics() if terrain != null else {},
		"configuredSeed": configured_seed
	}

func collect_volume_edit_changes() -> void:
	var service = volume_service()
	if service == null:
		return
	var revision := int(service.get("revision"))
	if revision == last_volume_revision:
		return
	last_volume_revision = revision
	var current_signatures := {}
	var edited_value = service.get("edited_cells")
	var edited_cells: Dictionary = edited_value if edited_value is Dictionary else {}
	for cell_value in edited_cells.keys():
		if not (cell_value is Vector3i):
			continue
		var cell: Vector3i = cell_value
		var state: Dictionary = edited_cells[cell] if edited_cells[cell] is Dictionary else {}
		if not state_affects_terrain_mesh(service, state):
			continue
		var signature := edit_signature(state)
		current_signatures[cell] = signature
		if String(applied_edit_signatures.get(cell, "")) != signature:
			queue_edit_change(cell, state, signature)
	for cell_value in applied_edit_signatures.keys():
		if current_signatures.has(cell_value):
			continue
		if cell_value is Vector3i:
			queue_edit_change(cell_value, {}, "")

func queue_loaded_block_edit_sections(block_position: Vector3i) -> void:
	var service = volume_service()
	if service == null:
		return
	var edited_value = service.get("edited_cells")
	if not (edited_value is Dictionary):
		return
	for cell_value in (edited_value as Dictionary).keys():
		if not (cell_value is Vector3i):
			continue
		var cell: Vector3i = cell_value
		if section_key_for_cell(cell) != block_position:
			continue
		var state: Dictionary = edited_value[cell] if edited_value[cell] is Dictionary else {}
		if state_affects_terrain_mesh(service, state):
			var signature := edit_signature(state)
			if String(applied_edit_signatures.get(cell, "")) != signature:
				queue_edit_change(cell, state, signature)

func queue_edit_change(cell: Vector3i, state: Dictionary, signature: String) -> void:
	var section_key := section_key_for_cell(cell)
	var changes: Dictionary = pending_edit_sections.get(section_key, {}) if pending_edit_sections.get(section_key, {}) is Dictionary else {}
	changes[cell] = {"state": state.duplicate(true), "signature": signature}
	pending_edit_sections[section_key] = changes

func process_pending_edit_sections() -> void:
	if terrain == null or pending_edit_sections.is_empty():
		return
	var processed := 0
	for section_value in pending_edit_sections.keys():
		if processed >= EDIT_SECTIONS_PER_FRAME:
			break
		var section_key: Vector3i = section_value
		var changes: Dictionary = pending_edit_sections[section_key]
		if not apply_edit_batch(changes):
			continue
		pending_edit_sections.erase(section_key)
		processed += 1
		edit_batches_applied += 1

func apply_edit_batch(changes: Dictionary) -> bool:
	if changes.is_empty():
		return true
	var min_cell := Vector3i(2147483647, 2147483647, 2147483647)
	var max_cell := Vector3i(-2147483647, -2147483647, -2147483647)
	for cell_value in changes.keys():
		var cell: Vector3i = cell_value
		min_cell = Vector3i(mini(min_cell.x, cell.x), mini(min_cell.y, cell.y), mini(min_cell.z, cell.z))
		max_cell = Vector3i(maxi(max_cell.x, cell.x), maxi(max_cell.y, cell.y), maxi(max_cell.z, cell.z))
	var size := max_cell - min_cell + Vector3i.ONE
	var tool = terrain.get_voxel_tool()
	if not bool(tool.is_area_editable(AABB(Vector3(min_cell), Vector3(size)))):
		return false
	var buffer := VoxelBuffer.new()
	buffer.create(size.x, size.y, size.z)
	var channels_mask := (1 << VoxelBuffer.CHANNEL_SDF) | (1 << VoxelBuffer.CHANNEL_INDICES) | (1 << VoxelBuffer.CHANNEL_DATA5)
	tool.copy(min_cell, buffer, channels_mask, false)
	for cell_value in changes.keys():
		var cell: Vector3i = cell_value
		var change: Dictionary = changes[cell]
		var state: Dictionary = change.get("state", {}) if change.get("state", {}) is Dictionary else {}
		var sample := state if not state.is_empty() else generated_state_at_grid_cell(cell)
		var density := float(sample.get("density", -CELL))
		var material := String(sample.get("material", "air"))
		var material_id := int(MATERIAL_IDS.get(material, MATERIAL_IDS["stone"]))
		var local := cell - min_cell
		buffer.set_voxel_f(-density / CELL, local.x, local.y, local.z, VoxelBuffer.CHANNEL_SDF)
		buffer.set_voxel(material_id, local.x, local.y, local.z, VoxelBuffer.CHANNEL_INDICES)
		buffer.set_voxel(material_id, local.x, local.y, local.z, VoxelBuffer.CHANNEL_DATA5)
		var signature := String(change.get("signature", ""))
		if signature == "":
			applied_edit_signatures.erase(cell)
		else:
			applied_edit_signatures[cell] = signature
	tool.paste(min_cell, buffer, channels_mask)
	var affected_game_chunks := {}
	for cell_value in changes.keys():
		var cell: Vector3i = cell_value
		affected_game_chunks[game_chunk_for_cell(cell)] = true
	for chunk_value in affected_game_chunks.keys():
		request_gameplay_chunk_republication(chunk_value)
	return true

func request_gameplay_chunk_publication(chunk_key: Vector2i) -> void:
	desired_gameplay_chunks[chunk_key] = true
	if not published_gameplay_chunks.has(chunk_key):
		queue_pending_gameplay_chunk(chunk_key)

func request_gameplay_chunk_republication(chunk_key: Vector2i) -> void:
	if not desired_gameplay_chunks.has(chunk_key):
		return
	if published_gameplay_chunks.erase(chunk_key):
		notify_navigation_chunk_unloaded(chunk_key)
	queue_pending_gameplay_chunk(chunk_key)

func release_gameplay_chunk(chunk_key: Vector2i) -> void:
	desired_gameplay_chunks.erase(chunk_key)
	pending_gameplay_chunks.erase(chunk_key)
	pending_gameplay_chunk_order.erase(chunk_key)
	if published_gameplay_chunks.erase(chunk_key):
		notify_navigation_chunk_unloaded(chunk_key)

func queue_pending_gameplay_chunk(chunk_key: Vector2i) -> void:
	if pending_gameplay_chunks.has(chunk_key):
		return
	pending_gameplay_chunks[chunk_key] = true
	pending_gameplay_chunk_order.append(chunk_key)

func gameplay_chunks_published(chunk_keys: Array) -> bool:
	for key_value in chunk_keys:
		if key_value is Vector2i and not published_gameplay_chunks.has(key_value):
			return false
	return true

func published_gameplay_chunk_count(chunk_keys: Array) -> int:
	var count := 0
	for key_value in chunk_keys:
		if key_value is Vector2i and published_gameplay_chunks.has(key_value):
			count += 1
	return count

func gameplay_publication_diagnostics(chunk_keys: Array) -> Dictionary:
	var chunk_diagnostics: Array = []
	for key_value in chunk_keys:
		if not (key_value is Vector2i):
			continue
		var chunk_key: Vector2i = key_value
		var proof: Dictionary = published_gameplay_chunks.get(chunk_key, {}) if published_gameplay_chunks.get(chunk_key, {}) is Dictionary else {}
		if proof.is_empty():
			proof = collision_proof_for_game_chunk(chunk_key)
		chunk_diagnostics.append({
			"key": "%d,%d" % [chunk_key.x, chunk_key.y],
			"desired": desired_gameplay_chunks.has(chunk_key),
			"pending": pending_gameplay_chunks.has(chunk_key),
			"published": published_gameplay_chunks.has(chunk_key),
			"proof": proof
		})
	return {
		"configuredSeed": configured_seed,
		"authorityReady": authority_ready,
		"viewerPosition": viewer.global_position if viewer != null and is_instance_valid(viewer) else Vector3.ZERO,
		"viewerRequiresVisuals": bool(viewer.requires_visuals) if viewer != null and is_instance_valid(viewer) else false,
		"viewerRequiresCollisions": bool(viewer.requires_collisions) if viewer != null and is_instance_valid(viewer) else false,
		"startupAuxiliaryViewers": startup_auxiliary_viewer_diagnostics(),
		"publishedMeshBlockCount": published_mesh_blocks.size(),
		"desiredGameplayChunkCount": desired_gameplay_chunks.size(),
		"pendingGameplayChunkCount": pending_gameplay_chunks.size(),
		"publishedGameplayChunkCount": published_gameplay_chunks.size(),
		"terrainStatistics": terrain.get_statistics() if terrain != null else {},
		"chunks": chunk_diagnostics
	}

func process_pending_gameplay_chunk_publications() -> void:
	if pending_gameplay_chunks.is_empty() or main == null or not is_inside_tree():
		return
	if pending_gameplay_chunk_order.is_empty():
		for key_value in pending_gameplay_chunks.keys():
			if key_value is Vector2i:
				pending_gameplay_chunk_order.append(key_value)
	var probe_count := mini(PUBLICATION_PROBES_PER_PHYSICS_FRAME, pending_gameplay_chunk_order.size())
	for _index in range(probe_count):
		var chunk_key: Vector2i = pending_gameplay_chunk_order.pop_front()
		if not pending_gameplay_chunks.has(chunk_key):
			continue
		if not desired_gameplay_chunks.has(chunk_key):
			pending_gameplay_chunks.erase(chunk_key)
			continue
		collision_probe_attempts += 1
		var proof := collision_proof_for_game_chunk(chunk_key)
		if not bool(proof.get("passed", false)):
			pending_gameplay_chunk_order.append(chunk_key)
			continue
		pending_gameplay_chunks.erase(chunk_key)
		published_gameplay_chunks[chunk_key] = proof
		collision_probe_passes += 1
		notify_navigation_chunk_loaded(chunk_key)

func collision_proof_for_game_chunk(chunk_key: Vector2i) -> Dictionary:
	if terrain == null or get_world_3d() == null:
		return {"passed": false, "reason": "physics_world_missing"}
	var world_generation = main.get("world_generation_system")
	if world_generation == null or not world_generation.has_method("surface_y_at"):
		return {"passed": false, "reason": "surface_facade_missing"}
	var origin_x := float(chunk_key.x * GAME_CHUNK_SIZE) * CELL
	var origin_z := float(chunk_key.y * GAME_CHUNK_SIZE) * CELL
	var span := float(GAME_CHUNK_SIZE) * CELL
	var offsets := [
		Vector2(0.50, 0.50),
		Vector2(0.22, 0.22),
		Vector2(0.78, 0.22),
		Vector2(0.22, 0.78),
		Vector2(0.78, 0.78)
	]
	var hits := 0
	var matched := 0
	var samples := []
	var min_surface_cell_y := 2147483000
	var max_surface_cell_y := -2147483000
	var space := get_world_3d().direct_space_state
	for offset_value in offsets:
		var offset: Vector2 = offset_value
		var x := origin_x + span * offset.x
		var z := origin_z + span * offset.y
		var expected_y := float(world_generation.call("surface_y_at", Vector3(x, 0.0, z)))
		var expected_cell_y := floori(expected_y / CELL)
		min_surface_cell_y = mini(min_surface_cell_y, expected_cell_y)
		max_surface_cell_y = maxi(max_surface_cell_y, expected_cell_y)
		var query := PhysicsRayQueryParameters3D.create(
			Vector3(x, expected_y + CELL * 48.0, z),
			Vector3(x, float(world_generation.call("world_bottom_cell_y")) * CELL - CELL * 2.0, z),
			TERRAIN_COLLISION_LAYER
		)
		query.collide_with_areas = false
		var hit := space.intersect_ray(query)
		if hit.is_empty() or not voxel_terrain_collider(hit.get("collider")):
			samples.append({"x": snappedf(x, 0.01), "z": snappedf(z, 0.01), "expectedY": snappedf(expected_y, 0.01), "hit": false})
			continue
		hits += 1
		var hit_y := float((hit.get("position", Vector3.ZERO) as Vector3).y)
		var delta_y := absf(hit_y - expected_y)
		if delta_y <= COLLISION_SURFACE_TOLERANCE:
			matched += 1
		samples.append({"x": snappedf(x, 0.01), "z": snappedf(z, 0.01), "expectedY": snappedf(expected_y, 0.01), "hit": true, "hitY": snappedf(hit_y, 0.01), "deltaY": snappedf(delta_y, 0.01)})
	var mesh_area := AABB(
		Vector3(
			float(chunk_key.x * GAME_CHUNK_SIZE),
			float(min_surface_cell_y - COLLISION_MESH_VERTICAL_MARGIN_CELLS),
			float(chunk_key.y * GAME_CHUNK_SIZE)
		),
		Vector3(
			float(GAME_CHUNK_SIZE),
			float(max_surface_cell_y - min_surface_cell_y + COLLISION_MESH_VERTICAL_MARGIN_CELLS * 2 + 1),
			float(GAME_CHUNK_SIZE)
		)
	)
	var area_meshed := terrain.is_area_meshed(mesh_area)
	return {
		"passed": area_meshed and hits == offsets.size(),
		"areaMeshed": area_meshed,
		"meshArea": mesh_area,
		"hits": hits,
		"surfaceMatches": matched,
		"heightfieldComparisonPassed": matched == offsets.size(),
		"collisionAuthority": "VoxelTerrain",
		"probeCount": offsets.size(),
		"samples": samples
	}


func collision_proof_for_world_position(world_position: Vector3, footprint_radius := 0.0) -> Dictionary:
	if terrain == null or get_world_3d() == null:
		return {"passed": false, "reason": "physics_world_missing"}
	var world_generation = main.get("world_generation_system") if main != null else null
	if world_generation == null or not world_generation.has_method("surface_y_at"):
		return {"passed": false, "reason": "surface_facade_missing"}
	var radius := maxf(0.0, footprint_radius)
	var offsets: Array[Vector2] = [Vector2.ZERO]
	if radius > 0.0:
		offsets.append_array([
			Vector2(radius, 0.0),
			Vector2(-radius, 0.0),
			Vector2(0.0, radius),
			Vector2(0.0, -radius)
		])
	var samples: Array = []
	var center_matched := false
	var matched := 0
	var mesh_ready := collision_mesh_ready_for_world_position(world_position, radius)
	if not bool(mesh_ready.get("passed", false)):
		return {
			"passed": false,
			"reason": "collision_mesh_not_ready",
			"position": world_position,
			"footprintRadius": radius,
			"mesh": mesh_ready,
			"samples": []
		}
	var space := get_world_3d().direct_space_state
	for index in range(offsets.size()):
		var sample_x := world_position.x + offsets[index].x
		var sample_z := world_position.z + offsets[index].y
		var expected_y := float(world_generation.call("surface_y_at", Vector3(sample_x, 0.0, sample_z)))
		var query := PhysicsRayQueryParameters3D.create(
			Vector3(sample_x, expected_y + CELL * 48.0, sample_z),
			Vector3(sample_x, float(world_generation.call("world_bottom_cell_y")) * CELL - CELL * 2.0, sample_z),
			TERRAIN_COLLISION_LAYER
		)
		query.collide_with_areas = false
		var hit := space.intersect_ray(query)
		if hit.is_empty() or not voxel_terrain_collider(hit.get("collider")):
			samples.append({"offset": offsets[index], "expectedY": snappedf(expected_y, 0.01), "hit": false})
			continue
		var hit_y := float((hit.get("position", Vector3.ZERO) as Vector3).y)
		var delta_y := absf(hit_y - expected_y)
		var surface_matched := delta_y <= COLLISION_SURFACE_TOLERANCE
		if surface_matched:
			matched += 1
			if index == 0:
				center_matched = true
		samples.append({
			"offset": offsets[index],
			"expectedY": snappedf(expected_y, 0.01),
			"hit": true,
			"hitY": snappedf(hit_y, 0.01),
			"deltaY": snappedf(delta_y, 0.01),
			"surfaceMatched": surface_matched
		})
	return {
		"passed": center_matched and matched == samples.size(),
		"reason": "collision_ready" if center_matched and matched == samples.size() else "footprint_collision_not_ready",
		"position": world_position,
		"footprintRadius": radius,
		"mesh": mesh_ready,
		"matchedSamples": matched,
		"sampleCount": samples.size(),
		"samples": samples
	}


func collision_mesh_ready_for_world_position(world_position: Vector3, footprint_radius := 0.0) -> Dictionary:
	if terrain == null:
		return {"passed": false, "reason": "terrain_missing"}
	var world_generation = main.get("world_generation_system") if main != null else null
	if world_generation == null or not world_generation.has_method("surface_y_at"):
		return {"passed": false, "reason": "surface_facade_missing"}
	var radius_cells := maxi(1, ceili(maxf(0.0, footprint_radius) / CELL) + 1)
	var local_position := terrain.to_local(world_position)
	var expected_y := float(world_generation.call("surface_y_at", world_position))
	var local_surface_y := terrain.to_local(Vector3(world_position.x, expected_y, world_position.z)).y
	var area := AABB(
		Vector3(
			floorf(local_position.x) - float(radius_cells),
			floorf(local_surface_y) - float(COLLISION_MESH_VERTICAL_MARGIN_CELLS),
			floorf(local_position.z) - float(radius_cells)
		),
		Vector3(
			float(radius_cells * 2 + 1),
			float(COLLISION_MESH_VERTICAL_MARGIN_CELLS * 2 + 1),
			float(radius_cells * 2 + 1)
		)
	)
	return {
		"passed": terrain.is_area_meshed(area),
		"area": area,
		"expectedY": expected_y
	}


func collision_mesh_ready_for_body_position(world_position: Vector3, footprint_radius := 0.0) -> Dictionary:
	if terrain == null:
		return {"passed": false, "reason": "terrain_missing"}
	var radius_cells := maxi(1, ceili(maxf(0.0, footprint_radius) / CELL) + 1)
	var local_position := terrain.to_local(world_position)
	var area := AABB(
		Vector3(
			floorf(local_position.x) - float(radius_cells),
			floorf(local_position.y) - float(COLLISION_MESH_VERTICAL_MARGIN_CELLS),
			floorf(local_position.z) - float(radius_cells)
		),
		Vector3(
			float(radius_cells * 2 + 1),
			float(COLLISION_MESH_VERTICAL_MARGIN_CELLS * 2 + 3),
			float(radius_cells * 2 + 1)
		)
	)
	var passed := terrain.is_area_meshed(area)
	return {
		"passed": passed,
		"reason": "collision_mesh_ready" if passed else "collision_mesh_not_ready",
		"area": area,
		"position": world_position,
		"footprintRadius": maxf(0.0, footprint_radius),
		"collisionAuthority": "VoxelTerrain"
	}


func collision_proof_for_motion(from_position: Vector3, to_position: Vector3, footprint_radius := 0.42) -> Dictionary:
	var start := Vector2i(floori(minf(from_position.x,to_position.x)/CELL),floori(minf(from_position.z,to_position.z)/CELL))
	var end := Vector2i(ceili(maxf(from_position.x,to_position.x)/CELL),ceili(maxf(from_position.z,to_position.z)/CELL))
	var source: Dictionary = site_gate.request_cells(Rect2i(start,end-start+Vector2i.ONE).grow(ceili(footprint_radius/CELL)+2)) \
		if site_gate != null else {"status":"failed","reason":"terrain_site_gate_missing"}
	if source.status != "ready":
		site_traversal_waiting = true
		_site_wait_message("Preparing landmark ground…" if source.status == "pending" else "Landmark loading failed: %s" % source.reason)
		return {"passed":false,"reason":source.reason,"siteAdmission":source}
	var distance := Vector2(to_position.x - from_position.x, to_position.z - from_position.z).length()
	var sample_count := maxi(1, ceili(distance / maxf(CELL, footprint_radius * 2.0)))
	var proofs: Array = []
	for index in range(sample_count + 1):
		var weight := float(index) / float(sample_count)
		var sample_position := from_position.lerp(to_position, weight)
		var mesh_proof := collision_mesh_ready_for_body_position(sample_position, footprint_radius)
		var support_observation := collision_proof_for_world_position(sample_position, footprint_radius) \
			if bool(mesh_proof.get("passed", false)) else {}
		var proof := {
			"passed": bool(mesh_proof.get("passed", false)),
			"reason": String(mesh_proof.get("reason", "collision_mesh_not_ready")),
			"position": sample_position,
			"mesh": mesh_proof,
			"supportRequiredForMotion": false,
			"supportObservationPassed": bool(support_observation.get("passed", false)) if not support_observation.is_empty() else false,
			"supportObservationReason": String(support_observation.get("reason", "not_sampled")) if not support_observation.is_empty() else "not_sampled",
			"samples": support_observation.get("samples", []) if not support_observation.is_empty() else []
		}
		proofs.append(proof)
		if not bool(proof.get("passed", false)):
			if site_traversal_waiting: _site_wait_message("Waiting for terrain collision…")
			return {
				"passed": false,
				"reason": String(proof.get("reason", "collision_not_ready")),
				"failedSample": index,
				"sampleCount": sample_count + 1,
				"proofs": proofs
			}
	site_traversal_waiting = false
	return {
		"passed": true,
		"reason": "collision_mesh_ready",
		"supportRequiredForMotion": false,
		"sampleCount": sample_count + 1,
		"proofs": proofs
	}

func _site_wait_message(message: String) -> void:
	var now := Time.get_ticks_usec()
	if now-last_site_wait_message_usec < 1000000: return
	last_site_wait_message_usec = now
	if main != null and main.has_method("show_action_message"): main.show_action_message(message)

func voxel_terrain_collider(value) -> bool:
	if value == null or not is_instance_valid(value):
		return false
	if value == terrain:
		return true
	return value is Node and (value as Node).name == terrain.name

func notify_navigation_chunk_loaded(chunk_key: Vector2i) -> void:
	var npc_system = main.get("npc_system") if main != null else null
	if npc_system != null and npc_system.has_method("notify_navigation_chunk_loaded"):
		npc_system.call("notify_navigation_chunk_loaded", chunk_key)

func notify_navigation_chunk_unloaded(chunk_key: Vector2i) -> void:
	var npc_system = main.get("npc_system") if main != null else null
	if npc_system != null and npc_system.has_method("notify_navigation_chunk_unloaded"):
		npc_system.call("notify_navigation_chunk_unloaded", chunk_key)

func game_chunk_for_cell(cell: Vector3i) -> Vector2i:
	return Vector2i(
		floori(float(cell.x) / float(GAME_CHUNK_SIZE)),
		floori(float(cell.z) / float(GAME_CHUNK_SIZE))
	)

func generated_state_at_grid_cell(cell: Vector3i) -> Dictionary:
	var world_generation = main.get("world_generation_system") if main != null else null
	if world_generation == null or not world_generation.has_method("generate_sample_without_volume"):
		return {"density": -CELL, "material": "air"}
	var position := Vector3(cell) * CELL
	var sample: Dictionary = world_generation.call("generate_sample_without_volume", position)
	var density := float(sample.get("density", -CELL))
	var material := String(sample.get("material", "air"))
	if density >= 0.0 and world_generation.has_method("generated_solid_material_for_cell"):
		var surface_y := float(sample.get("baseSurfaceY", sample.get("surfaceY", position.y)))
		var surface_biome := String(world_generation.call("surface_biome_for_cell3", Vector3i(cell.x, 0, cell.z)))
		var depth := maxf(0.0, surface_y - position.y)
		material = String(world_generation.call("generated_solid_material_for_cell", cell, surface_y, surface_biome, depth))
	return {"density": density, "material": material}

func section_key_for_cell(cell: Vector3i) -> Vector3i:
	return Vector3i(
		floori(float(cell.x) / float(SECTION_SIZE)),
		floori(float(cell.y) / float(SECTION_SIZE)),
		floori(float(cell.z) / float(SECTION_SIZE))
	)

func volume_service():
	var world_generation = main.get("world_generation_system") if main != null else null
	return world_generation.get("terrain_volume_service") if world_generation != null else null

func state_affects_terrain_mesh(service, state: Dictionary) -> bool:
	if service != null and service.has_method("cell_state_affects_terrain_mesh"):
		return bool(service.call("cell_state_affects_terrain_mesh", state))
	return true

func edit_signature(state: Dictionary) -> String:
	var metadata: Dictionary = state.get("metadata", {}) if state.get("metadata", {}) is Dictionary else {}
	return "%s|%s|%.6f|%s|%s" % [
		String(state.get("material", "air")),
		str(bool(state.get("solid", false))),
		float(state.get("density", -CELL)),
		String(state.get("fluid", "")),
		String(metadata.get("source", ""))
	]
