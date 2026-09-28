extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const CELL := 1.35
const SURFACE_ALIGNMENT_TOLERANCE := CELL * 0.08

var results: Array[Dictionary] = []
var report_path := ""

func _ready() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_TERRAIN_PUBLICATION_REPORT")
	# Preserve the requested seed and keep this fixture out of user autosaves.
	OS.set_environment("VOXEL_PLAYTEST", "1")
	var main := MAIN_SCENE.instantiate() as Node3D
	main.set("startup_mode", "new_game")
	get_tree().root.add_child(main)
	if not await main.wait_for_startup_loading_complete():
		add_result("startup_loading_complete", false, JSON.stringify({"startup_loading_failure_result": main.get("startup_loading_failure_result")}))
		finish(main)
		return
	main.set_physics_process(false)
	var player = main.get("player") as CharacterBody3D
	player.set_physics_process(false)
	player.velocity = Vector3.ZERO
	var authority_ready := bool(main.call("ensure_voxel_terrain_authority"))
	add_result("voxel_publication_authority_ready", authority_ready, "")
	add_result(
		"voxel_publication_player_mask_includes_terrain",
		(player.collision_mask & 2) != 0,
		"playerMask=%d terrainLayer=%d" % [player.collision_mask, 2]
	)
	var player_chunk_key: Vector2i = main.call("world_to_chunk", player.global_position.x, player.global_position.z)
	# Startup now correctly publishes the player chunk before this fixture can
	# act. Probe a fresh remote container, keeping the player on proven terrain.
	var chunk_key := player_chunk_key + Vector2i(0, 8)
	var runtime := main.get_node_or_null("VoxelTerrainRuntime")
	var request_id: int = main.world_streaming.request_region(Rect2i(chunk_key * 28, Vector2i.ONE * 28), 1, "collision_publication_contract")
	add_result("voxel_publication_remote_demand_retained", request_id > 0, str(chunk_key))
	main.apply_streaming_region_demand()
	runtime.call("configure_startup_auxiliary_viewers", [player_chunk_key, chunk_key], main.get("world_generation_system"))
	var navigation_loaded_before := navigation_chunk_loaded_count(main)
	main.call("create_chunk", chunk_key.x, chunk_key.y, true)
	var initially_published := bool(runtime.call("gameplay_chunks_published", [chunk_key]))
	add_result("voxel_publication_not_guessed_at_container_create", not initially_published, str(chunk_key))
	var published_frame := -1
	var frame := 0
	var started_usec := Time.get_ticks_usec()
	while float(Time.get_ticks_usec() - started_usec) / 1000000.0 < 75.0:
		await get_tree().physics_frame
		await get_tree().process_frame
		if bool(runtime.call("gameplay_chunks_published", [chunk_key])):
			published_frame = frame
			break
		frame += 1
	var proof: Dictionary = runtime.get("published_gameplay_chunks").get(chunk_key, {})
	if proof.is_empty():
		proof = runtime.call("collision_proof_for_game_chunk", chunk_key)
	add_result(
		"voxel_publication_collision_proven",
		published_frame >= 0
			and bool(proof.get("areaMeshed", false))
			and int(proof.get("hits", 0)) == int(proof.get("probeCount", -1))
			and String(proof.get("collisionAuthority", "")) == "VoxelTerrain",
		JSON.stringify({"frame": published_frame, "chunk": chunk_key, "proof": proof, "runtime": runtime.call("stats")})
	)
	var position_proof: Dictionary = runtime.call("collision_proof_for_world_position", player.global_position, 0.0)
	var position_samples = position_proof.get("samples", [])
	var center_sample: Dictionary = position_samples[0] if position_samples is Array and not position_samples.is_empty() and position_samples[0] is Dictionary else {}
	var source_surface := expected_mesh_column_surface(main, runtime, player.global_position)
	var expected_y := float(source_surface.get("height", INF))
	# The production observation reports a placement-reference height, which
	# intentionally excludes structure reservations. Compare collision with the
	# actual mesh-affecting density source instead, without changing placement.
	var hit := {}
	if bool(source_surface.get("passed", false)):
		var query := PhysicsRayQueryParameters3D.create(
			Vector3(player.global_position.x, expected_y + CELL * 48.0, player.global_position.z),
			Vector3(player.global_position.x, float(main.world_generation_system.world_bottom_cell_y()) * CELL - CELL * 2.0, player.global_position.z), 2)
		hit = main.get_world_3d().direct_space_state.intersect_ray(query)
	var hit_y := float((hit.get("position", Vector3(0.0, -INF, 0.0)) as Vector3).y)
	var alignment_delta := absf(expected_y - hit_y)
	add_result(
		"voxel_publication_analytic_surface_matches_collision",
		bool(source_surface.get("passed", false)) and not hit.is_empty()
			and bool(runtime.voxel_terrain_collider(hit.get("collider"))) and alignment_delta <= SURFACE_ALIGNMENT_TOLERANCE,
		JSON.stringify({
			"position": player.global_position,
			"expectedY": expected_y,
			"placementReferenceY": center_sample.get("expectedY", INF),
			"meshSource": source_surface,
			"hitY": hit_y,
			"delta": alignment_delta,
			"tolerance": SURFACE_ALIGNMENT_TOLERANCE,
			"proof": position_proof
		})
	)
	var navigation_loaded_after := navigation_chunk_loaded_count(main)
	add_result(
		"voxel_publication_navigation_follows_collision",
		published_frame >= 0 and navigation_loaded_after > navigation_loaded_before,
		"before=%d after=%d publishedFrame=%d" % [navigation_loaded_before, navigation_loaded_after, published_frame]
	)
	var motion_proof: Dictionary = runtime.call(
		"collision_proof_for_motion",
		player.global_position,
		player.global_position + Vector3(0.25, 0.0, 0.0),
		0.42
	)
	var motion_samples = motion_proof.get("proofs", [])
	var first_motion_sample: Dictionary = motion_samples[0] \
		if motion_samples is Array and not motion_samples.is_empty() and motion_samples[0] is Dictionary else {}
	add_result(
		"voxel_publication_motion_gate_uses_mesh_authority",
		bool(motion_proof.get("passed", false))
			and not bool(motion_proof.get("supportRequiredForMotion", true))
			and bool((first_motion_sample.get("mesh", {}) as Dictionary).get("passed", false)),
		JSON.stringify(motion_proof)
	)
	var disconnected_components: Array = runtime.call(
		"connected_gameplay_chunk_components",
		[chunk_key, chunk_key + Vector2i(0, 5)]
	)
	add_result(
		"voxel_publication_disconnected_startup_regions_are_identified",
		disconnected_components.size() == 2,
		JSON.stringify(disconnected_components)
	)
	var connected_player_region: Array[Vector2i] = [player_chunk_key]
	var extension_index := 1
	while bool(runtime.call("primary_viewer_covers_component", connected_player_region)) and extension_index <= 32:
		connected_player_region.append(player_chunk_key + Vector2i(extension_index, 0))
		extension_index += 1
	var connected_player_region_needs_help := not bool(
		runtime.call("primary_viewer_covers_component", connected_player_region)
	)
	var world_generation = main.get("world_generation_system")
	runtime.call("configure_startup_auxiliary_viewers", connected_player_region, world_generation)
	var auxiliary_viewer_records: Array = runtime.get("startup_auxiliary_viewers")
	var auxiliary_covers_far_edge := false
	for record_value in auxiliary_viewer_records:
		if not (record_value is Dictionary):
			continue
		var record: Dictionary = record_value
		var covered_chunks: Array = record.get("chunks", [])
		if covered_chunks.has(connected_player_region.back()):
			auxiliary_covers_far_edge = true
			break
	add_result(
		"voxel_publication_player_connected_region_gets_auxiliary_coverage_when_needed",
		connected_player_region.has(player_chunk_key)
			and connected_player_region_needs_help
			and auxiliary_covers_far_edge,
		JSON.stringify({
			"playerChunk": player_chunk_key,
			"region": connected_player_region,
			"primaryCovers": not connected_player_region_needs_help,
			"auxiliaryViewerCount": auxiliary_viewer_records.size(),
			"auxiliaryCoversFarEdge": auxiliary_covers_far_edge
		})
	)
	runtime.call("clear_startup_auxiliary_viewers")
	var shutdown_started_usec := Time.get_ticks_usec()
	main.set_process(false)
	main.set_physics_process(false)
	if runtime != null and is_instance_valid(runtime) and runtime.has_method("begin_shutdown"):
		runtime.call("begin_shutdown")
		await get_tree().process_frame
		await get_tree().process_frame
	var shutdown_pending_tasks := int(runtime.call("voxel_engine_pending_task_count")) \
		if runtime != null and is_instance_valid(runtime) and runtime.has_method("voxel_engine_pending_task_count") else 0
	while shutdown_pending_tasks > 0 and float(Time.get_ticks_usec() - shutdown_started_usec) / 1000000.0 < 30.0:
		await get_tree().process_frame
		shutdown_pending_tasks = int(runtime.call("voxel_engine_pending_task_count"))
	add_result(
		"voxel_publication_shutdown_tasks_drained",
		shutdown_pending_tasks == 0,
		"pending=%d elapsedMs=%.3f" % [shutdown_pending_tasks, float(Time.get_ticks_usec() - shutdown_started_usec) / 1000.0]
	)
	finish(main)

func add_result(name: String, passed: bool, details: String) -> void:
	results.append({"name": name, "passed": passed, "details": details})
	print("[%s] %s %s" % ["PASS" if passed else "FAIL", name, details])

func navigation_chunk_loaded_count(main: Node) -> int:
	var npc_system = main.get("npc_system") if main != null else null
	var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
	if autonomy == null or not autonomy.has_method("stats"):
		return -1
	var autonomy_stats: Dictionary = autonomy.call("stats")
	var telemetry: Dictionary = autonomy_stats.get("telemetry", {}) if autonomy_stats.get("telemetry", {}) is Dictionary else {}
	var counters: Dictionary = telemetry.get("counters", {}) if telemetry.get("counters", {}) is Dictionary else {}
	return int(counters.get("change_chunk_loaded", 0))

func expected_mesh_column_surface(main: Node, runtime: Node, position: Vector3) -> Dictionary:
	# Diagnostic only. Integer-lattice samples independently reconstruct the
	# crossing from the same edited-cell selection used by native publication.
	# Scene overlays and placement projections are not terrain density sources.
	var generation = main.world_generation_system
	var service = runtime.volume_service()
	var x := roundi(position.x / CELL)
	var z := roundi(position.z / CELL)
	if not is_equal_approx(position.x, float(x) * CELL) or not is_equal_approx(position.z, float(z) * CELL):
		return {"passed":false,"reason":"diagnostic_requires_lattice_column"}
	if service == null or runtime.configured_seed != String(main.seed_text) \
			or int(runtime.last_volume_revision) != int(service.revision) \
			or not runtime.gameplay_chunks_published([main.world_to_chunk(position.x, position.z)]):
		return {"passed":false,"reason":"source_or_collision_publication_pending"}
	var edits: Dictionary = service.edited_cells
	var reference_y := float(generation.terrain_deformed_surface_y_for_cell(Vector3i(x, 0, z)))
	var high := floori(reference_y / CELL) + 8
	var bounds: Dictionary = service.mesh_edited_y_bounds_for_region(x, x, z, z)
	if bool(bounds.get("found", false)): high = maxi(high, int(bounds.maxY) + 1)
	high = mini(high, int(generation.world_top_cell_y()))
	var previous := {}
	for y in range(high, int(generation.world_bottom_cell_y()) - 1, -1):
		var cell := Vector3i(x, y, z)
		var edit: Dictionary = edits.get(cell, {})
		var use_edit := not edit.is_empty() and bool(runtime.state_affects_terrain_mesh(service, edit))
		var signature := String(runtime.edit_signature(edit)) if use_edit else ""
		if String(runtime.applied_edit_signatures.get(cell, "")) != signature:
			return {"passed":false,"reason":"source_edit_not_applied","cell":cell}
		var sample: Dictionary = edit if use_edit else runtime.generated_state_at_grid_cell(cell)
		var density := float(sample.get("density", -CELL))
		var current := {"cell":cell,"density":density,"source":"edit" if use_edit else "generated",
			"metadata":sample.get("metadata", {})}
		if density >= 0.0 and not previous.is_empty() and float(previous.density) < 0.0:
			var readback: Array = []
			var source_matches := true
			var tool = runtime.terrain.get_voxel_tool()
			tool.channel = VoxelBuffer.CHANNEL_SDF
			var encoded := VoxelBuffer.new()
			encoded.create(1, 1, 1)
			encoded.set_channel_depth(VoxelBuffer.CHANNEL_SDF, VoxelBuffer.DEPTH_16_BIT)
			for source: Dictionary in [current, previous]:
				encoded.set_voxel_f(-float(source.density) / CELL, 0, 0, 0, VoxelBuffer.CHANNEL_SDF)
				var expected_sdf := encoded.get_voxel_f(0, 0, 0, VoxelBuffer.CHANNEL_SDF)
				var actual_sdf := float(tool.get_voxel_f(source.cell))
				source_matches = source_matches and absf(expected_sdf - actual_sdf) <= 0.0001
				readback.append({"cell":source.cell,"expectedSdf":expected_sdf,"publishedSdf":actual_sdf})
			return {"passed":source_matches,"sourceRevision":int(service.revision),"seed":String(main.seed_text),
				"publishedDensityReadback":readback,
				"height":generation.surface_boundary_y_between_numeric_samples(y, density, float(previous.density)),
				"solidSample":current,"airSample":previous}
		previous = current
	return {"passed":false,"reason":"source_surface_not_found"}

func finish(shutdown_main: Node = null) -> void:
	var passed := true
	for result in results:
		if not bool(result.get("passed", false)):
			passed = false
	var report := {
		"schemaVersion": 1,
		"runnerId": "voxel_terrain_collision_publication",
		"evidenceLevel": "integration",
		"passed": passed,
		"seed": String(shutdown_main.get("seed_text")) if is_instance_valid(shutdown_main) else "",
		"startup_loading_failure_result": shutdown_main.get("startup_loading_failure_result") if is_instance_valid(shutdown_main) else {},
		"results": results
	}
	if report_path != "":
		DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "  "))
			file.close()
	print(JSON.stringify(report, "  "))
	if is_instance_valid(shutdown_main):
		shutdown_main.call("request_graceful_quit", 0 if passed else 1)
	else:
		get_tree().quit(0 if passed else 1)
