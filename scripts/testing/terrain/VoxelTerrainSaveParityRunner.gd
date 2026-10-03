extends Node3D

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const CELL := 1.35
const WAIT_FRAMES := 720

var report_path := ""
var seed := ""
var results: Array[Dictionary] = []
var target_cell := Vector3i.ZERO
var owned_main: Node3D = null

func _ready() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_TERRAIN_SAVE_PARITY_REPORT")
	seed = OS.get_environment("VOXEL_TEST_SEED")
	if seed == "":
		seed = "atlas-31684266"
	var stage := OS.get_environment("VOXEL_TERRAIN_SAVE_PARITY_STAGE")
	var renderer_name := DisplayServer.get_name()
	if renderer_name.to_lower() == "headless":
		add_result("visible_renderer_available", false,
			"A headless renderer omits tree meshes; visual readiness requires a scene runner.")
		finish(stage)
		return
	add_result("visible_renderer_available", true, renderer_name)
	if stage == "read":
		await run_read_stage()
	else:
		await run_write_stage()

func run_write_stage() -> void:
	var main := await boot_main("new_game")
	if main == null:
		add_result("voxel_save_first_boot", false, "Main failed to boot")
		finish()
		return
	target_cell = find_surface_solid_cell(main)
	add_result("voxel_save_target_found", target_cell != Vector3i.ZERO, str(target_cell))
	var world_generation = main.get("world_generation_system")
	world_generation.call("set_cell_state", target_cell, air_state(), "voxel_save_parity")
	var first_sync := await wait_for_voxel_state(main, target_cell, false)
	add_result("voxel_save_edit_synced", bool(first_sync.get("passed", false)), JSON.stringify(first_sync))
	var snapshot: Dictionary = main.call("create_save_snapshot")
	var terrain_snapshot: Dictionary = snapshot.get("terrainVolume", {}) if snapshot.get("terrainVolume", {}) is Dictionary else {}
	var save_system = main.get("save_system")
	var saved := save_system != null and bool(save_system.call("save", seed, snapshot))
	add_result("voxel_save_snapshot_written", saved and int((terrain_snapshot.get("sections", []) as Array).size()) > 0, "sections=%d" % int((terrain_snapshot.get("sections", []) as Array).size()))
	finish("write")

func run_read_stage() -> void:
	target_cell = parse_cell(OS.get_environment("VOXEL_TERRAIN_SAVE_PARITY_TARGET"))
	var main := await boot_main("continue")
	if main == null:
		add_result("voxel_save_continue_boot", false, "Main failed to boot")
		finish("read")
		return
	var loaded_seed := String(main.get("seed_text"))
	var loaded_state: Dictionary = main.get("world_generation_system").call("get_cell_state", target_cell)
	var second_sync := await wait_for_voxel_state(main, target_cell, false)
	add_result("voxel_save_continue_boot", loaded_seed == seed, "seed=%s" % loaded_seed)
	add_result("voxel_save_facade_round_trip", not bool(loaded_state.get("solid", true)) and String(loaded_state.get("material", "")) == "air", JSON.stringify(loaded_state))
	add_result("voxel_save_voxel_round_trip", bool(second_sync.get("passed", false)), JSON.stringify(second_sync))
	finish("read")

func boot_main(mode: String) -> Node3D:
	var main := MAIN_SCENE.instantiate() as Node3D
	owned_main = main
	main.set("startup_mode", mode)
	var launch_options: Dictionary = main.get("launch_options").duplicate(true)
	launch_options["skipTutorial"] = true
	main.set("launch_options", launch_options)
	add_child(main)
	if not await main.wait_for_startup_loading_complete():
		var timeline: Array = main.get("startup_loading_timeline") if main.get("startup_loading_timeline") is Array else []
		var last_step: Dictionary = timeline.back() if not timeline.is_empty() else {}
		add_result("startup_loading_complete", false, JSON.stringify({
			"mode": mode,
			"startup_loading_failure_result": main.get("startup_loading_failure_result"),
			"startupLoadingActive": bool(main.get("startup_loading_active")),
			"lastStartupStep": last_step,
			"pendingVisualDiagnostics": _pending_visual_diagnostics(main)
		}))
		return null
	add_result("startup_loading_complete", true, JSON.stringify({
		"mode": mode,
		"renderer": DisplayServer.get_name()
	}))
	if not bool(main.call("ensure_voxel_terrain_authority")):
		return null
	var cell := find_surface_solid_cell(main)
	var chunk_key: Vector2i = main.call("cell_to_chunk", cell.x, cell.z)
	main.call("create_chunk", chunk_key.x, chunk_key.y, true)
	return main

func _pending_visual_diagnostics(main: Node) -> Dictionary:
	var result := {"startupLedger": [], "demandController": []}
	var runtime: Object = main.get("voxel_terrain_runtime")
	var world_revision := String(runtime.call("visible_mesh_world_revision")) \
		if is_instance_valid(runtime) and runtime.has_method("visible_mesh_world_revision") else ""
	var requests: Dictionary = main.get("streaming_requests")	
	var request_id := int(requests.get("player", 0))
	var seed_text := String(main.get("seed_text"))
	var ledger: Object = main.get("visible_world_readiness")
	var bounds_by_owner: Dictionary = main.get("streaming_request_foreground_bounds")
	var bounds: Rect2i = bounds_by_owner.get("player", Rect2i())
	var view_revision := int(main.get("visible_world_view_revision"))
	if is_instance_valid(ledger) and ledger.has_method("pending_candidate_diagnostics"):
		result.startupLedger = ledger.call("pending_candidate_diagnostics", request_id,
			seed_text, world_revision, view_revision, bounds, 20)
	var controller: Object = main.get("visible_world_demand_controller")
	if is_instance_valid(controller) and controller.has_method("pending_representation_diagnostics"):
		result.demandController = controller.call("pending_representation_diagnostics",
			"player", request_id, seed_text, world_revision, 20)
	return result

func find_surface_solid_cell(main: Node3D) -> Vector3i:
	var world_generation = main.get("world_generation_system")
	var player = main.get("player") as Node3D
	var center := Vector3i(
		floori(player.global_position.x / CELL) if player != null else 0,
		0,
		floori(player.global_position.z / CELL) if player != null else 0
	)
	for radius in range(0, 9):
		for z in range(center.z - radius, center.z + radius + 1):
			for x in range(center.x - radius, center.x + radius + 1):
				for y in range(64, -33, -1):
					var cell := Vector3i(x, y, z)
					var state: Dictionary = world_generation.call("get_cell_state", cell)
					var above: Dictionary = world_generation.call("get_cell_state", cell + Vector3i.UP)
					if bool(state.get("solid", false)) and not bool(above.get("solid", true)):
						return cell
	return Vector3i.ZERO

func wait_for_voxel_state(main: Node3D, cell: Vector3i, expected_solid: bool) -> Dictionary:
	var runtime := main.get_node_or_null("VoxelTerrainRuntime")
	if runtime == null:
		return {"passed": false, "reason": "runtime_missing"}
	var terrain := runtime.get_node_or_null("VoxelTerrainAuthority") as VoxelTerrain
	if terrain == null:
		return {"passed": false, "reason": "terrain_missing"}
	var tool = terrain.get_voxel_tool()
	var last_editable := false
	var last_sdf := 999.0
	var last_stats := {}
	for frame in range(WAIT_FRAMES):
		var area := AABB(Vector3(cell), Vector3.ONE)
		last_editable = bool(tool.is_area_editable(area))
		last_stats = runtime.call("stats")
		if last_editable:
			tool.channel = VoxelBuffer.CHANNEL_SDF
			var sdf := float(tool.get_voxel_f(cell))
			last_sdf = sdf
			var solid := sdf < 0.0
			var runtime_stats: Dictionary = runtime.call("stats")
			tool.channel = VoxelBuffer.CHANNEL_INDICES
			var material_index := int(tool.get_voxel(cell))
			var expected_material := 1 if expected_solid else 0
			if solid == expected_solid and (expected_solid or material_index == expected_material):
				return {
					"passed": true,
					"frame": frame,
					"sdf": snappedf(sdf, 0.001),
					"materialIndex": material_index,
					"pendingEditSections": int(runtime_stats.get("pendingEditSections", 0))
				}
		await get_tree().process_frame
	return {
		"passed": false,
		"reason": "voxel_state_timeout",
		"cell": vec3i(cell),
		"areaEditable": last_editable,
		"sdf": snappedf(last_sdf, 0.001),
		"runtime": last_stats
	}

func air_state() -> Dictionary:
	return {
		"blockId": "air",
		"material": "air",
		"solid": false,
		"density": -CELL,
		"air": true,
		"fluid": "",
		"biome": "underground_air",
		"metadata": {"source": "voxel_save_parity"}
	}

func add_result(name: String, passed: bool, details := "") -> void:
	results.append({"name": name, "passed": passed, "details": details})
	print("[%s] %s %s" % ["PASS" if passed else "FAIL", name, details])

func finish(stage := "") -> void:
	var passed := true
	for result in results:
		if not bool(result.get("passed", false)):
			passed = false
	var report := {
		"schemaVersion": 1,
		"runnerId": "voxel_terrain_save_parity",
		"evidenceLevel": "integration",
		"stage": stage,
		"seed": seed,
		"targetCell": vec3i(target_cell),
		"passed": passed,
		"startup_loading_failure_result": owned_main.get("startup_loading_failure_result") if is_instance_valid(owned_main) else {},
		"results": results
	}
	if report_path != "":
		DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
		var file := FileAccess.open(report_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify(report, "  "))
			file.close()
	print(JSON.stringify(report, "  "))
	if is_instance_valid(owned_main):
		owned_main.call("request_graceful_quit", 0 if passed else 1)
	else:
		get_tree().quit(0 if passed else 1)

func vec3i(value: Vector3i) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}

func parse_cell(value: String) -> Vector3i:
	var parts := value.split(",", false)
	if parts.size() != 3:
		return Vector3i.ZERO
	return Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))
