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
	var main := MAIN_SCENE.instantiate() as Node3D
	main.set("startup_mode", "new_game")
	get_tree().root.add_child(main)
	for _i in range(240):
		await get_tree().process_frame
		if not bool(main.get("startup_loading_active")):
			break
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
	var chunk_key: Vector2i = main.call("world_to_chunk", player.global_position.x, player.global_position.z)
	main.call("create_chunk", chunk_key.x, chunk_key.y, true)
	var runtime := main.get_node_or_null("VoxelTerrainRuntime")
	var navigation_loaded_before := navigation_chunk_loaded_count(main)
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
	var expected_y := float(center_sample.get("expectedY", INF))
	var hit_y := float(center_sample.get("hitY", -INF))
	var alignment_delta := absf(expected_y - hit_y)
	add_result(
		"voxel_publication_analytic_surface_matches_collision",
		bool(center_sample.get("hit", false)) and alignment_delta <= SURFACE_ALIGNMENT_TOLERANCE,
		JSON.stringify({
			"position": player.global_position,
			"expectedY": expected_y,
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
	main.queue_free()
	await get_tree().process_frame
	finish()

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

func finish() -> void:
	var passed := true
	for result in results:
		if not bool(result.get("passed", false)):
			passed = false
	var report := {
		"schemaVersion": 1,
		"runnerId": "voxel_terrain_collision_publication",
		"evidenceLevel": "integration",
		"passed": passed,
		"results": results
	}
	if report_path != "":
		DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "  "))
			file.close()
	print(JSON.stringify(report, "  "))
	get_tree().quit(0 if passed else 1)
