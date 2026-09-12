extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const LivePlaytestPlayerNavigatorScript := preload("res://scripts/testing/player/LivePlaytestPlayerNavigator.gd")
const TEST_ID := "town_ground_visual_playtest"
const CELL := 1.35
const CHUNK_SIZE := 28
const CLOCK_DISPLAY_OFFSET := 0.25
const CAPTURE_WIDTH := 1280
const CAPTURE_HEIGHT := 720

var main: Node3D = null
var player: CharacterBody3D = null
var camera: Camera3D = null
var player_navigator = null
var seed := ""
var report_path := ""
var screenshot_dir := ""
var progress_path := ""
var run_token := ""
var watchdog_seconds := 180.0
var elapsed := 0.0
var finished := false
var results: Array[Dictionary] = []
var captures: Array[Dictionary] = []
var timeline: Array[Dictionary] = []
var selected_edge := {}
var selected_house := {}
var edge_route_result := {}
var house_route_result := {}

func _ready() -> void:
	configure_from_environment()
	apply_resolution()
	write_progress("start")
	call_deferred("run")

func _process(delta: float) -> void:
	if finished:
		return
	elapsed += delta
	if elapsed > watchdog_seconds:
		add_result("town_ground_visual_watchdog", false, "watchdog %.1fs exceeded" % watchdog_seconds)
		finish(1)

func configure_from_environment() -> void:
	seed = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
	if seed == "":
		seed = "atlas-1492"
	report_path = OS.get_environment("VOXEL_TOWN_GROUND_VISUAL_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/terrain-volume/town-ground-visual-playtest.json")
	progress_path = OS.get_environment("VOXEL_TOWN_GROUND_VISUAL_PROGRESS").strip_edges()
	screenshot_dir = OS.get_environment("VOXEL_TOWN_GROUND_VISUAL_SCREENSHOT_DIR").strip_edges()
	if screenshot_dir == "":
		screenshot_dir = ProjectSettings.globalize_path("res://artifacts/terrain-volume/screenshots/town-ground-visual")
	run_token = OS.get_environment("VOXEL_TOWN_GROUND_VISUAL_RUN_TOKEN").strip_edges()
	var watchdog_text := OS.get_environment("VOXEL_TOWN_GROUND_VISUAL_WATCHDOG_SECONDS").strip_edges()
	if watchdog_text != "":
		watchdog_seconds = maxf(60.0, float(watchdog_text))
	ensure_dir(report_path.get_base_dir())
	ensure_dir(screenshot_dir)
	if progress_path != "":
		ensure_dir(progress_path.get_base_dir())

func apply_resolution() -> void:
	DisplayServer.window_set_size(Vector2i(CAPTURE_WIDTH, CAPTURE_HEIGHT))
	var root_window := get_tree().root
	root_window.set("size", Vector2i(CAPTURE_WIDTH, CAPTURE_HEIGHT))
	root_window.set("content_scale_size", Vector2i(CAPTURE_WIDTH, CAPTURE_HEIGHT))

func run() -> void:
	OS.set_environment("VOXEL_TEST_SEED", seed)
	main = MAIN_SCENE.instantiate()
	main.set("render_distance", 2)
	main.set("visual_quality", {
		"decorativeDensity": 0.04,
		"decorativeDetailCap": 8,
		"particleDensity": 0.0
	})
	add_child(main)
	var progress_callback := func(message): write_progress("startup_%s" % String(message).replace(" ", "_"))
	main.connect("startup_loading_step", progress_callback)
	var startup_ready: bool = await main.wait_for_startup_loading_complete()
	main.disconnect("startup_loading_step", progress_callback)
	if not startup_ready or finished:
		add_result("startup_loading_complete", false, JSON.stringify({"startup_loading_failure_result": main.get("startup_loading_failure_result")}))
		finish(1)
		return
	await wait_process_frames(3)
	bind_scene_nodes()
	if main == null or player == null or camera == null:
		add_result("town_ground_visual_scene_ready", false, "missing main/player/camera")
		finish(1)
		return
	configure_scene()
	main.set_process(true)
	var loaded := bool(main.call("run_playtest_case", "town"))
	await wait_process_frames(12)
	await ensure_town_structures_ready()
	add_result("town_ground_visual_town_playtest_loaded", loaded, "run_playtest_case(town)")
	if not loaded:
		finish(1)
		return
	selected_edge = select_town_edge()
	add_result("town_ground_visual_edge_selected", not selected_edge.is_empty(), JSON.stringify(encode_json_value(selected_edge)))
	if selected_edge.is_empty():
		finish(1)
		return
	edge_route_result = await move_player_to_edge_observation()
	add_result("town_ground_visual_edge_observation_pose_reached", bool(edge_route_result.get("ok", false)), JSON.stringify(encode_json_value(edge_route_result)))
	if not bool(edge_route_result.get("ok", false)):
		finish(1)
		return
	var initial_mesh_summary := mesh_summary_for_selected_edge()
	add_result("town_ground_visual_initial_edge_not_open_heightfield", edge_mesh_is_closed_or_final(initial_mesh_summary), JSON.stringify(initial_mesh_summary))
	var completed := await wait_for_completed_edge_volume_mesh(420)
	var mesh_summary := mesh_summary_for_selected_edge()
	timeline.append({
		"event": "diagnostic",
		"stage": "town_ground_visual_edge_native_mesh_completed",
		"elapsed": snappedf(elapsed, 0.001),
		"completed": completed,
		"mesh": mesh_summary
	})
	add_result("town_ground_visual_edge_chunk_requires_volume", bool(mesh_summary.get("edgeChunkRequiresVolume", false)), JSON.stringify(mesh_summary))
	add_result("town_ground_visual_edge_chunk_not_heightfield_skin", not String(mesh_summary.get("edgeChunkBackend", "")).contains("two_sided_exterior") and not String(mesh_summary.get("edgeChunkBackend", "")).contains("heightfield_exterior"), JSON.stringify(mesh_summary))
	add_result("town_ground_visual_edge_chunk_closed_or_final", edge_mesh_is_closed_or_final(mesh_summary), JSON.stringify(mesh_summary))
	await capture_edge(mesh_summary)
	add_result("town_ground_visual_required_screenshot_saved", FileAccess.file_exists(screenshot_dir.path_join("town_ground_edge_volume.png")), screenshot_dir.path_join("town_ground_edge_volume.png"))
	selected_house = select_town_house_foundation()
	add_result("town_ground_visual_house_foundation_selected", not selected_house.is_empty(), JSON.stringify(encode_json_value(selected_house)))
	if not selected_house.is_empty():
		house_route_result = await move_player_to_house_observation()
		add_result("town_ground_visual_house_observation_pose_reached", bool(house_route_result.get("ok", false)), JSON.stringify(encode_json_value(house_route_result)))
		if not bool(house_route_result.get("ok", false)):
			finish(1)
			return
		var house_initial_mesh_summary := mesh_summary_for_selected_house()
		add_result("town_ground_visual_house_initial_foundation_not_open_heightfield", house_mesh_is_closed_or_final(house_initial_mesh_summary), JSON.stringify(house_initial_mesh_summary))
		var house_completed := await wait_for_completed_house_volume_mesh(360)
		var house_mesh_summary := mesh_summary_for_selected_house()
		timeline.append({
			"event": "diagnostic",
			"stage": "town_ground_visual_house_native_mesh_completed",
			"elapsed": snappedf(elapsed, 0.001),
			"completed": house_completed,
			"mesh": house_mesh_summary
		})
		add_result("town_ground_visual_house_chunk_requires_volume", bool(house_mesh_summary.get("houseChunkRequiresVolume", false)), JSON.stringify(house_mesh_summary))
		add_result("town_ground_visual_house_foundation_placeholder_or_final", house_mesh_is_closed_or_final(house_mesh_summary), JSON.stringify(house_mesh_summary))
		await capture_house_foundation(house_mesh_summary)
		add_result("town_ground_visual_house_screenshot_saved", FileAccess.file_exists(screenshot_dir.path_join("town_house_foundation_volume.png")), screenshot_dir.path_join("town_house_foundation_volume.png"))
	finish(1 if failure_count() > 0 else 0)

func bind_scene_nodes() -> void:
	player = main.get("player") as CharacterBody3D
	camera = player.get("camera") as Camera3D if player != null else null
	if camera != null:
		camera.make_current()
	player_navigator = LivePlaytestPlayerNavigatorScript.new()
	if player != null and camera != null:
		player_navigator.setup(main, player, camera, self)

func configure_scene() -> void:
	if main.has_method("apply_runtime_setting"):
		main.call("apply_runtime_setting", "headBob", false, false)
		main.call("apply_runtime_setting", "handSway", false, false)
	player.set("automated_input", true)
	player.set("automated_move", Vector3.ZERO)
	player.set("automated_sprint", false)
	player.set("automated_jump", false)
	var tutorial = main.get("tutorial_system")
	if tutorial != null:
		tutorial.set("intro_repair_active", false)
		tutorial.set("intro_repair_complete", true)
		tutorial.set("intro_bed_used", true)
		tutorial.set("intro_elder_dialogue_acknowledged", true)
		tutorial.set("final_night_active", false)
		tutorial.set("final_night_complete", true)
	main.set("time_of_day", fposmod((13.0 / 24.0) - CLOCK_DISPLAY_OFFSET, 1.0))
	var weather = main.get("weather_system")
	if weather != null and weather.has_method("force_weather"):
		weather.call("force_weather", "clear", 0.0, 0.18, Vector3.ZERO)
	if main.has_method("update_sky"):
		main.call("update_sky", 0.0)
	var hud = main.get("hud")
	if hud is CanvasLayer:
		(hud as CanvasLayer).visible = false
	elif hud is Node:
		var hud_root = hud.get("hud_root")
		if hud_root is Control:
			(hud_root as Control).visible = false

func ensure_town_structures_ready() -> void:
	var structure_system = main.get("structure_system") if main != null else null
	if structure_system == null:
		return
	var town: Dictionary = main.call("town_region", 1, 0)
	if town.is_empty():
		return
	var center := Vector2i(int(town.get("centerX", 0)), int(town.get("centerZ", 0)))
	for _frame in range(120):
		if structure_system.has_method("update_around_budgeted"):
			structure_system.call("update_around_budgeted", center, true)
		elif structure_system.has_method("update_around"):
			structure_system.call("update_around", center)
		if main.has_method("queue_dirty_terrain_volume_chunk_refreshes"):
			main.call("queue_dirty_terrain_volume_chunk_refreshes")
		var pending := int(structure_system.call("pending_structure_op_count")) if structure_system.has_method("pending_structure_op_count") else 0
		if structure_footprint_count(structure_system) > 0 and pending <= 0:
			return
		await wait_process_frames(1)
		await wait_physics_frames(1)

func structure_footprint_count(structure_system) -> int:
	if structure_system == null or not structure_system.has_method("structure_terrain_footprints_snapshot"):
		return 0
	var value = structure_system.call("structure_terrain_footprints_snapshot")
	return (value as Array).size() if value is Array else 0

func select_town_edge() -> Dictionary:
	var town: Dictionary = main.call("town_region", 1, 0)
	if town.is_empty():
		return {}
	var center := Vector2(float(town.get("centerX", 0)), float(town.get("centerZ", 0)))
	var radius := float(town.get("radius", 28))
	var level := float(town.get("level", 16.0))
	var best := {}
	var best_score := -INF
	for i in range(64):
		var angle := (TAU * float(i)) / 64.0
		var direction := Vector2(cos(angle), sin(angle))
		var edge_cell := Vector2i(roundi(center.x + direction.x * radius), roundi(center.y + direction.y * radius))
		var outside_cell := Vector2i(roundi(center.x + direction.x * (radius + 8.0)), roundi(center.y + direction.y * (radius + 8.0)))
		var inside_y := surface_y_for_cell(edge_cell)
		var outside_y := surface_y_for_cell(outside_cell)
		var delta := inside_y - outside_y
		var chunk_key := cell_to_chunk(edge_cell)
		var start_x := chunk_key.x * CHUNK_SIZE
		var start_z := chunk_key.y * CHUNK_SIZE
		var town_edge := bool(main.call("chunk_has_town_surface_volume_edge", start_x, start_z)) if main.has_method("chunk_has_town_surface_volume_edge") else false
		var score := delta * 4.0 + (20.0 if town_edge else 0.0)
		if score > best_score:
			best_score = score
			best = {
				"town": town,
				"center": center,
				"radius": radius,
				"level": level,
				"direction": direction,
				"edgeCell": edge_cell,
				"outsideCell": outside_cell,
				"insideY": inside_y,
				"outsideY": outside_y,
				"heightDelta": delta,
				"chunkKey": chunk_key,
				"chunkHasTownEdge": town_edge
			}
	return best if best_score > -INF else {}

func select_town_house_foundation() -> Dictionary:
	var structure_system = main.get("structure_system") if main != null else null
	if structure_system == null or not structure_system.has_method("structure_terrain_footprints_snapshot"):
		return {}
	var town: Dictionary = main.call("town_region", 1, 0)
	if town.is_empty():
		return {}
	var town_center := Vector2(float(town.get("centerX", 0)), float(town.get("centerZ", 0)))
	var footprints_value = structure_system.call("structure_terrain_footprints_snapshot")
	if not (footprints_value is Array):
		return {}
	var best := {}
	var best_score := -INF
	for footprint_value in footprints_value:
		if not (footprint_value is Dictionary):
			continue
		var footprint: Dictionary = footprint_value
		if String(footprint.get("source", "")) != "town_home":
			continue
		var min_value = footprint.get("minCell", null)
		var max_value = footprint.get("maxCell", null)
		if not (min_value is Vector3i) or not (max_value is Vector3i):
			continue
		var min_cell: Vector3i = min_value
		var max_cell: Vector3i = max_value
		var center := Vector2(float(min_cell.x + max_cell.x + 1) * 0.5, float(min_cell.z + max_cell.z + 1) * 0.5)
		var direction := center - town_center
		if direction.length_squared() <= 0.001:
			direction = Vector2(1.0, 0.0)
		direction = direction.normalized()
		var chunk_key := cell_to_chunk(Vector2i(roundi(center.x), roundi(center.y)))
		var score := direction.length() * 10.0 + center.distance_to(town_center)
		if score > best_score:
			best_score = score
			best = {
				"footprint": footprint,
				"center": center,
				"townCenter": town_center,
				"direction": direction,
				"chunkKey": chunk_key,
				"level": float(footprint.get("level", town.get("level", 16.0))),
				"material": String(footprint.get("material", "stone"))
			}
	return best

func move_player_to_edge_observation() -> Dictionary:
	var attempts := []
	var candidates := edge_player_observation_candidates()
	for index in range(candidates.size()):
		var target: Vector3 = candidates[index]
		var result := await move_player_to_observation(
			target,
			"town_ground_edge_observation_%02d" % index,
			28.0,
			true
		)
		var attempt := {
			"index": index,
			"target": vec3(target),
			"routeOk": bool(result.get("ok", false)),
			"status": String(result.get("status", "")),
			"reason": String(result.get("reason", "")),
			"player": result.get("player", {})
		}
		if bool(result.get("ok", false)):
			var aim := await aim_player_camera_at(edge_camera_target())
			var pose_proof := player_camera_pose_proof(edge_camera_target(), true, true)
			attempt["aim"] = aim
			attempt["poseProof"] = pose_proof
			attempts.append(attempt)
			if bool(aim.get("ok", false)) and bool(pose_proof.get("ok", false)):
				result["observationAttempts"] = attempts
				result["observationProof"] = pose_proof
				return result
		else:
			attempts.append(attempt)
	return {
		"ok": false,
		"status": "no_unobstructed_collision_backed_edge_viewpoint",
		"reason": "all_edge_observation_candidates_failed",
		"attempts": attempts
	}

func move_player_to_house_observation() -> Dictionary:
	return await move_player_to_observation(
		house_player_observation_position(),
		"town_house_foundation_observation",
		40.0,
		true
	)

func move_player_to_observation(target: Vector3, label: String, timeout_seconds: float, accept_route_goal: bool) -> Dictionary:
	if player_navigator == null or player == null:
		return {
			"ok": false,
			"status": "player_navigator_missing",
			"target": vec3(target)
		}
	var result: Dictionary = await player_navigator.go_to_position(target, {
		"label": label,
		"stopDistance": CELL * 0.70,
		"completionStopDistance": CELL * 0.70,
		"timeout": timeout_seconds,
		"planTimeout": 14.0,
		"allowOutside": true,
		"acceptRouteGoal": accept_route_goal,
		"routeSemanticKind": "interaction_target"
	})
	player.set("automated_move", Vector3.ZERO)
	player.set("automated_sprint", false)
	player.velocity = Vector3.ZERO
	await wait_physics_frames(6)
	var route_proof: Dictionary = result.get("proof", {}) if result.get("proof", {}) is Dictionary else {}
	var route: Dictionary = route_proof.get("route", {}) if route_proof.get("route", {}) is Dictionary else {}
	return {
		"ok": bool(result.get("ok", false)),
		"status": String(result.get("status", "")),
		"reason": String(result.get("reason", "")),
		"target": vec3(target),
		"player": vec3(player.global_position),
		"route": {
			"label": label,
			"source": String(route.get("source", "")),
			"status": String(route.get("status", "")),
			"reason": String(route.get("reason", "")),
			"waypointCount": int(route.get("waypointCount", 0)),
			"routeAuthorityState": String(route.get("routeAuthorityState", "")),
			"collisionProbe": encode_json_value(route.get("collisionProbe", {})),
			"planningAttempts": int(route_proof.get("attempts", 0)),
			"acceptRouteGoal": accept_route_goal
		}
	}

func wait_for_completed_edge_volume_mesh(max_frames: int) -> bool:
	for _i in range(maxi(1, max_frames)):
		var summary := mesh_summary_for_selected_edge()
		if edge_mesh_is_final_volume(summary):
			return true
		if main.has_method("update_chunks"):
			main.call("update_chunks", false)
		await wait_process_frames(1)
		await wait_physics_frames(1)
	return edge_mesh_is_final_volume(mesh_summary_for_selected_edge())

func wait_for_completed_house_volume_mesh(max_frames: int) -> bool:
	for _i in range(maxi(1, max_frames)):
		var summary := mesh_summary_for_selected_house()
		if house_mesh_is_final_volume(summary):
			return true
		if main.has_method("update_chunks"):
			main.call("update_chunks", false)
		await wait_process_frames(1)
		await wait_physics_frames(1)
	return house_mesh_is_final_volume(mesh_summary_for_selected_house())

func edge_mesh_is_final_volume(summary: Dictionary) -> bool:
	if bool(summary.get("voxelAuthorityActive", false)):
		return int(summary.get("legacyTerrainPresenterCount", -1)) == 0
	if bool(summary.get("edgeChunkProvisional", false)):
		return false
	if String(summary.get("edgeChunkBackend", "")) == "provisional_exterior_surface":
		return false
	if not bool(summary.get("edgeChunkRequiresVolume", false)):
		return false
	return int(summary.get("edgeChunkVolumeFaces", 0)) > 0 or bool(summary.get("edgeChunkSectionPayload", false))

func edge_mesh_is_closed_or_final(summary: Dictionary) -> bool:
	if edge_mesh_is_final_volume(summary):
		return true
	if String(summary.get("edgeChunkBackend", "")).contains("two_sided_exterior"):
		return false
	if String(summary.get("edgeChunkBackend", "")).contains("heightfield_exterior"):
		return false
	return bool(summary.get("edgeChunkSolidPlaceholder", false))

func house_mesh_is_final_volume(summary: Dictionary) -> bool:
	if bool(summary.get("voxelAuthorityActive", false)):
		return int(summary.get("legacyTerrainPresenterCount", -1)) == 0
	if bool(summary.get("houseChunkProvisional", false)):
		return false
	if not bool(summary.get("houseChunkRequiresVolume", false)):
		return false
	return int(summary.get("houseChunkVolumeFaces", 0)) > 0 or bool(summary.get("houseChunkSectionPayload", false))

func house_mesh_is_closed_or_final(summary: Dictionary) -> bool:
	if house_mesh_is_final_volume(summary):
		return true
	if String(summary.get("houseChunkBackend", "")).contains("two_sided_exterior"):
		return false
	if String(summary.get("houseChunkBackend", "")).contains("heightfield_exterior"):
		return false
	return bool(summary.get("houseChunkSolidPlaceholder", false)) and bool(summary.get("houseChunkStructureFoundationPlaceholder", false))

func mesh_summary_for_selected_edge() -> Dictionary:
	var authority := voxel_authority_summary()
	var chunk_key: Vector2i = selected_edge.get("chunkKey", Vector2i.ZERO)
	var chunks_value = main.get("chunks")
	var chunks: Dictionary = chunks_value if chunks_value is Dictionary else {}
	var summaries := []
	var edge_summary := {}
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var key := Vector2i(chunk_key.x + dx, chunk_key.y + dz)
			var summary := mesh_summary_for_chunk(key)
			summaries.append(summary)
			if key == chunk_key:
				edge_summary = summary
	var start_x := chunk_key.x * CHUNK_SIZE
	var start_z := chunk_key.y * CHUNK_SIZE
	var requires_volume := bool(main.call("chunk_needs_generated_underground_volume_mesh", start_x, start_z)) if main.has_method("chunk_needs_generated_underground_volume_mesh") else false
	var has_town_edge := bool(main.call("chunk_has_town_surface_volume_edge", start_x, start_z)) if main.has_method("chunk_has_town_surface_volume_edge") else false
	return {
		"voxelAuthorityActive": bool(authority.get("active", false)),
		"voxelAuthorityNode": String(authority.get("node", "")),
		"legacyTerrainPresenterCount": int(authority.get("legacyTerrainPresenterCount", -1)),
		"selectedEdge": encode_json_value(selected_edge),
		"edgeChunk": vector2i_to_array(chunk_key),
		"edgeChunkFound": bool(edge_summary.get("found", false)),
		"edgeChunkBackend": String(edge_summary.get("backend", "")),
		"edgeChunkNative": bool(edge_summary.get("native", false)),
		"edgeChunkSectionPayload": bool(edge_summary.get("sectionPayload", false)),
		"edgeChunkProvisional": bool(edge_summary.get("provisional", false)),
		"edgeChunkSolidPlaceholder": bool(edge_summary.get("solidPlaceholder", false)),
		"edgeChunkVolumeFaces": int(edge_summary.get("volumeFaces", 0)),
		"edgeChunkVolumeVertices": int(edge_summary.get("volumeVertices", 0)),
		"edgeChunkSurfaceCount": int(edge_summary.get("surfaceCount", 0)),
		"edgeChunkRequiresVolume": requires_volume,
		"edgeChunkHasTownSurfaceEdge": has_town_edge,
		"nearbyChunks": summaries
	}

func mesh_summary_for_selected_house() -> Dictionary:
	var authority := voxel_authority_summary()
	var chunk_key: Vector2i = selected_house.get("chunkKey", Vector2i.ZERO)
	var chunks_value = main.get("chunks")
	var chunks: Dictionary = chunks_value if chunks_value is Dictionary else {}
	var summaries := []
	var house_summary := {}
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var key := Vector2i(chunk_key.x + dx, chunk_key.y + dz)
			var summary := mesh_summary_for_chunk(key)
			summaries.append(summary)
			if key == chunk_key:
				house_summary = summary
	var start_x := chunk_key.x * CHUNK_SIZE
	var start_z := chunk_key.y * CHUNK_SIZE
	var requires_volume := bool(main.call("chunk_needs_generated_underground_volume_mesh", start_x, start_z)) if main.has_method("chunk_needs_generated_underground_volume_mesh") else false
	var has_edits := bool(main.call("chunk_has_terrain_volume_edits", start_x, start_z)) if main.has_method("chunk_has_terrain_volume_edits") else false
	return {
		"voxelAuthorityActive": bool(authority.get("active", false)),
		"voxelAuthorityNode": String(authority.get("node", "")),
		"legacyTerrainPresenterCount": int(authority.get("legacyTerrainPresenterCount", -1)),
		"selectedHouse": encode_json_value(selected_house),
		"houseChunk": vector2i_to_array(chunk_key),
		"houseChunkFound": bool(house_summary.get("found", false)),
		"houseChunkBackend": String(house_summary.get("backend", "")),
		"houseChunkNative": bool(house_summary.get("native", false)),
		"houseChunkSectionPayload": bool(house_summary.get("sectionPayload", false)),
		"houseChunkProvisional": bool(house_summary.get("provisional", false)),
		"houseChunkSolidPlaceholder": bool(house_summary.get("solidPlaceholder", false)),
		"houseChunkStructureFoundationPlaceholder": bool(house_summary.get("structureFoundationPlaceholder", false)),
		"houseChunkStructureFoundationVertices": int(house_summary.get("structureFoundationVertices", 0)),
		"houseChunkVolumeFaces": int(house_summary.get("volumeFaces", 0)),
		"houseChunkVolumeVertices": int(house_summary.get("volumeVertices", 0)),
		"houseChunkSurfaceCount": int(house_summary.get("surfaceCount", 0)),
		"houseChunkRequiresVolume": requires_volume,
		"houseChunkHasTerrainVolumeEdits": has_edits,
		"nearbyChunks": summaries
	}

func mesh_summary_for_chunk(chunk_key: Vector2i) -> Dictionary:
	var chunks_value = main.get("chunks")
	var chunks: Dictionary = chunks_value if chunks_value is Dictionary else {}
	var chunk := chunks.get(chunk_key) as Node
	if chunk == null:
		return { "chunk": vector2i_to_array(chunk_key), "found": false }
	var mesh_instance := chunk.get_node_or_null("TerrainMesh") as MeshInstance3D
	var mesh := mesh_instance.mesh if mesh_instance != null else null
	if mesh == null:
		return { "chunk": vector2i_to_array(chunk_key), "found": true, "mesh": false }
	return {
		"chunk": vector2i_to_array(chunk_key),
		"found": true,
		"mesh": true,
		"backend": String(mesh.get_meta("terrainMeshingBackend", "")),
		"native": bool(mesh.get_meta("terrainMeshingNative", false)),
		"sectionPayload": bool(mesh.get_meta("terrainMeshingSectionPayload", false)),
		"provisional": bool(mesh.get_meta("terrainMeshingProvisional", false)),
		"solidPlaceholder": bool(mesh.get_meta("terrainProvisionalSolidPlaceholder", false)) or bool(mesh.get_meta("terrainVisualUndersideClosed", false)),
		"structureFoundationPlaceholder": bool(mesh.get_meta("terrainProvisionalStructureFoundation", false)),
		"structureFoundationVertices": int(mesh.get_meta("terrainProvisionalStructureFoundationVertices", 0)),
		"volumeFaces": int(mesh.get_meta("chunk_volume_faces", 0)),
		"volumeVertices": int(mesh.get_meta("chunk_volume_vertices", 0)),
		"surfaceCount": mesh.get_surface_count()
	}

func voxel_authority_summary() -> Dictionary:
	var runtime := main.get_node_or_null("VoxelTerrainRuntime") if main != null else null
	var terrain := runtime.get_node_or_null("VoxelTerrainAuthority") if runtime != null else null
	var legacy_count := 0
	var chunks_value = main.get("chunks") if main != null else {}
	if chunks_value is Dictionary:
		for chunk_value in (chunks_value as Dictionary).values():
			if not (chunk_value is Node):
				continue
			if (chunk_value as Node).get_node_or_null("TerrainMesh") != null:
				legacy_count += 1
			if (chunk_value as Node).get_node_or_null("TerrainBody") != null:
				legacy_count += 1
	return {
		"active": terrain is VoxelTerrain,
		"node": str(terrain),
		"legacyTerrainPresenterCount": legacy_count
	}

func capture_edge(mesh_summary: Dictionary) -> void:
	var edge_position := edge_camera_target()
	var aim := await aim_player_camera_at(edge_position)
	camera.make_current()
	if main.has_method("update_terrain_local_light_uniforms"):
		main.call("update_terrain_local_light_uniforms")
	await wait_process_frames(4)
	await wait_physics_frames(2)
	var pose_proof := player_camera_pose_proof(edge_position, true, true)
	add_result("town_ground_visual_edge_camera_aimed_through_input", bool(aim.get("ok", false)), JSON.stringify(aim))
	add_result("town_ground_visual_edge_uses_owned_player_camera", bool(pose_proof.get("ownedPlayerCamera", false)), JSON.stringify(pose_proof))
	add_result("town_ground_visual_edge_player_pose_collision_backed", bool(pose_proof.get("ok", false)), JSON.stringify(pose_proof))
	add_result("town_ground_visual_camera_hits_terrain_edge", bool(pose_proof.get("terrainSightline", false)), JSON.stringify(pose_proof.get("sightline", {})))
	if not bool(aim.get("ok", false)) or not bool(pose_proof.get("ok", false)):
		write_progress("town_ground_edge_pose_invalid")
		return
	var image := get_viewport().get_texture().get_image()
	var path := screenshot_dir.path_join("town_ground_edge_volume.png")
	var err := image.save_png(path)
	captures.append({
		"stage": "town_ground_edge_volume",
		"path": path,
		"saved": err == OK,
		"player": vec3(player.global_position),
		"camera": vec3(camera.global_position),
		"target": vec3(edge_position),
		"mesh": mesh_summary,
		"route": edge_route_result,
		"aim": aim,
		"poseProof": pose_proof
	})
	write_progress("town_ground_edge_volume")

func capture_house_foundation(mesh_summary: Dictionary) -> void:
	var target_position := house_camera_target()
	var aim := await aim_player_camera_at(target_position)
	camera.make_current()
	if main.has_method("update_terrain_local_light_uniforms"):
		main.call("update_terrain_local_light_uniforms")
	await wait_process_frames(4)
	await wait_physics_frames(2)
	var pose_proof := player_camera_pose_proof(target_position, true, false)
	add_result("town_ground_visual_house_camera_aimed_through_input", bool(aim.get("ok", false)), JSON.stringify(aim))
	add_result("town_ground_visual_house_uses_owned_player_camera", bool(pose_proof.get("ownedPlayerCamera", false)), JSON.stringify(pose_proof))
	add_result("town_ground_visual_house_player_pose_collision_backed", bool(pose_proof.get("ok", false)), JSON.stringify(pose_proof))
	add_result("town_ground_visual_camera_hits_house_foundation", bool(pose_proof.get("terrainSightline", false)), JSON.stringify(pose_proof.get("sightline", {})))
	if not bool(aim.get("ok", false)) or not bool(pose_proof.get("ok", false)):
		write_progress("town_house_foundation_pose_invalid")
		return
	var image := get_viewport().get_texture().get_image()
	var path := screenshot_dir.path_join("town_house_foundation_volume.png")
	var err := image.save_png(path)
	captures.append({
		"stage": "town_house_foundation_volume",
		"path": path,
		"saved": err == OK,
		"player": vec3(player.global_position),
		"camera": vec3(camera.global_position),
		"target": vec3(target_position),
		"mesh": mesh_summary,
		"route": house_route_result,
		"aim": aim,
		"poseProof": pose_proof
	})
	write_progress("town_house_foundation_volume")

func edge_camera_target() -> Vector3:
	var outside_cell: Vector2i = selected_edge.get("outsideCell", selected_edge.get("edgeCell", Vector2i.ZERO))
	return Vector3(
		float(outside_cell.x) * CELL,
		surface_y_for_cell(outside_cell) + CELL * 0.12,
		float(outside_cell.y) * CELL
	)

func edge_player_observation_position() -> Vector3:
	var candidates := edge_player_observation_candidates()
	return candidates[0] if not candidates.is_empty() else Vector3.ZERO

func edge_player_observation_candidates() -> Array[Vector3]:
	var edge_cell: Vector2i = selected_edge.get("edgeCell", Vector2i.ZERO)
	var direction: Vector2 = selected_edge.get("direction", Vector2.RIGHT)
	if direction.length_squared() <= 0.001:
		direction = Vector2.RIGHT
	direction = direction.normalized()
	var tangent := Vector2(-direction.y, direction.x)
	var offsets := [
		Vector2(6.0, 0.0),
		Vector2(8.0, 5.0),
		Vector2(8.0, -5.0),
		Vector2(11.0, 0.0),
		Vector2(11.0, 8.0),
		Vector2(11.0, -8.0),
		Vector2(5.0, 10.0),
		Vector2(5.0, -10.0)
	]
	var candidates: Array[Vector3] = []
	var seen := {}
	for offset_value in offsets:
		var offset: Vector2 = offset_value
		var cell := Vector2i(
			roundi(float(edge_cell.x) - direction.x * offset.x + tangent.x * offset.y),
			roundi(float(edge_cell.y) - direction.y * offset.x + tangent.y * offset.y)
		)
		var key := "%d,%d" % [cell.x, cell.y]
		if seen.has(key):
			continue
		seen[key] = true
		candidates.append(world_position_for_flat_cell(cell))
	return candidates

func house_camera_target() -> Vector3:
	var center: Vector2 = selected_house.get("center", Vector2.ZERO)
	var footprint: Dictionary = selected_house.get("footprint", {}) if selected_house.get("footprint", {}) is Dictionary else {}
	var floor_y := int(footprint.get("floorY", floori(float(selected_house.get("level", 0.0)) / CELL)))
	return Vector3(center.x * CELL, float(floor_y) * CELL - CELL * 0.10, center.y * CELL)

func house_player_observation_position() -> Vector3:
	var center: Vector2 = selected_house.get("center", Vector2.ZERO)
	var direction: Vector2 = selected_house.get("direction", Vector2.RIGHT)
	if direction.length_squared() <= 0.001:
		direction = Vector2.RIGHT
	direction = direction.normalized()
	var observation_cell := Vector2i(
		roundi(center.x - direction.x * 7.0),
		roundi(center.y - direction.y * 7.0)
	)
	return world_position_for_flat_cell(observation_cell)

func aim_player_camera_at(target: Vector3) -> Dictionary:
	if player == null or camera == null:
		return { "ok": false, "reason": "player_or_camera_missing" }
	var direction := target - camera.global_position
	if direction.length_squared() <= 0.0001:
		return { "ok": false, "reason": "target_at_camera" }
	direction = direction.normalized()
	var desired_yaw := atan2(-direction.x, -direction.z)
	var desired_pitch := clampf(asin(direction.y), deg_to_rad(-82.0), deg_to_rad(82.0))
	var current_yaw := player.rotation.y
	var current_pitch := float(player.get("pitch"))
	var sensitivity := maxf(0.0001, float(player.get("mouse_sensitivity")))
	var yaw_delta := wrapf(desired_yaw - current_yaw, -PI, PI)
	var pitch_delta := desired_pitch - current_pitch
	var relative := Vector2(
		-yaw_delta / sensitivity,
		pitch_delta / sensitivity if bool(player.get("invert_y")) else -pitch_delta / sensitivity
	)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	var event := InputEventMouseMotion.new()
	event.relative = relative
	event.position = Vector2(CAPTURE_WIDTH, CAPTURE_HEIGHT) * 0.5
	event.global_position = event.position
	timeline.append({
		"event": "camera_aim_input",
		"elapsed": snappedf(elapsed, 0.001),
		"relative": encode_json_value(relative),
		"target": vec3(target),
		"routedThroughViewportInput": true
	})
	get_viewport().push_input(event)
	await wait_process_frames(2)
	await wait_physics_frames(1)
	var desired_direction := (target - camera.global_position).normalized()
	var actual_direction := -camera.global_transform.basis.z.normalized()
	var aim_dot := actual_direction.dot(desired_direction)
	return {
		"ok": aim_dot >= 0.98,
		"aimDot": snappedf(aim_dot, 0.0001),
		"target": vec3(target),
		"camera": vec3(camera.global_position),
		"desiredYaw": snappedf(desired_yaw, 0.0001),
		"desiredPitch": snappedf(desired_pitch, 0.0001),
		"actualYaw": snappedf(player.rotation.y, 0.0001),
		"actualPitch": snappedf(float(player.get("pitch")), 0.0001),
		"routedThroughViewportInput": true
	}

func player_camera_pose_proof(target: Vector3, require_terrain_sightline: bool, require_unobstructed_terrain: bool) -> Dictionary:
	var grounded := player != null and (player.is_on_floor() or bool(player.get("terrain_grounded")))
	var owned_player_camera := player != null and camera != null and camera.get_parent() == player and not camera.top_level
	var floor_support := floor_support_summary()
	var camera_clearance := camera_clearance_summary()
	var sightline_mask := 3 if require_unobstructed_terrain else 2
	var sightline := camera_sightline_summary(target, sightline_mask)
	var desired_direction := (target - camera.global_position).normalized() if camera != null else Vector3.ZERO
	var actual_direction := -camera.global_transform.basis.z.normalized() if camera != null else Vector3.ZERO
	var aim_dot := actual_direction.dot(desired_direction)
	var terrain_sightline := bool(sightline.get("hit", false)) and bool(sightline.get("terrainAuthority", false))
	var sightline_ok := terrain_sightline if require_terrain_sightline else bool(sightline.get("hit", false))
	return {
		"ok": grounded and owned_player_camera and bool(floor_support.get("terrainAuthority", false)) and bool(camera_clearance.get("clear", false)) and aim_dot >= 0.98 and sightline_ok,
		"grounded": grounded,
		"isOnFloor": player.is_on_floor() if player != null else false,
		"terrainGrounded": bool(player.get("terrain_grounded")) if player != null else false,
		"ownedPlayerCamera": owned_player_camera,
		"cameraTopLevel": camera.top_level if camera != null else true,
		"aimDot": snappedf(aim_dot, 0.0001),
		"floorSupport": floor_support,
		"cameraClearance": camera_clearance,
		"terrainSightline": terrain_sightline,
		"requireUnobstructedTerrain": require_unobstructed_terrain,
		"sightline": sightline
	}

func floor_support_summary() -> Dictionary:
	if player == null or player.get_world_3d() == null:
		return { "hit": false, "terrainAuthority": false, "reason": "player_or_world_missing" }
	var from := player.global_position + Vector3.UP * CELL * 0.65
	var to := player.global_position - Vector3.UP * CELL * 2.0
	var query := PhysicsRayQueryParameters3D.create(from, to, 2)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	query.exclude = [player.get_rid()]
	var hit := player.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return { "hit": false, "terrainAuthority": false, "from": vec3(from), "to": vec3(to) }
	var collider = hit.get("collider", null)
	var terrain_authority := collider is VoxelTerrain and String((collider as Node).name) == "VoxelTerrainAuthority"
	return {
		"hit": true,
		"terrainAuthority": terrain_authority,
		"from": vec3(from),
		"to": vec3(to),
		"position": vec3(hit.get("position", Vector3.ZERO)),
		"distance": snappedf(from.distance_to(hit.get("position", from)), 0.001),
		"collider": str(collider),
		"colliderName": String((collider as Node).name) if collider is Node else ""
	}

func camera_clearance_summary() -> Dictionary:
	if camera == null or camera.get_world_3d() == null:
		return { "clear": false, "reason": "camera_or_world_missing" }
	var shape := SphereShape3D.new()
	shape.radius = 0.12
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis.IDENTITY, camera.global_position)
	query.collision_mask = 3
	query.collide_with_areas = false
	query.collide_with_bodies = true
	if player != null:
		query.exclude = [player.get_rid()]
	var hits := camera.get_world_3d().direct_space_state.intersect_shape(query, 8)
	var colliders := []
	for hit_value in hits:
		if hit_value is Dictionary:
			var collider = (hit_value as Dictionary).get("collider", null)
			colliders.append({
				"collider": str(collider),
				"name": String((collider as Node).name) if collider is Node else ""
			})
	return {
		"clear": hits.is_empty(),
		"camera": vec3(camera.global_position),
		"radius": shape.radius,
		"collisionMask": query.collision_mask,
		"colliders": colliders
	}

func camera_sightline_summary(target: Vector3, collision_mask := 2) -> Dictionary:
	if camera == null:
		return { "hit": false, "reason": "camera_missing" }
	var world := camera.get_world_3d()
	if world == null:
		return { "hit": false, "reason": "world_missing" }
	var query := PhysicsRayQueryParameters3D.create(camera.global_position, target + (target - camera.global_position).normalized() * CELL * 2.0, collision_mask)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit := world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {
			"hit": false,
			"from": vec3(camera.global_position),
			"to": vec3(target),
			"collisionMask": collision_mask
		}
	var collider = hit.get("collider", null)
	var terrain_authority := collider is VoxelTerrain and String((collider as Node).name) == "VoxelTerrainAuthority"
	return {
		"hit": true,
		"terrainAuthority": terrain_authority,
		"collisionMask": collision_mask,
		"from": vec3(camera.global_position),
		"to": vec3(target),
		"position": vec3(hit.get("position", Vector3.ZERO)),
		"collider": str(collider),
		"colliderName": String((collider as Node).name) if collider is Node else "",
		"kind": String(collider.get_meta("kind", "")) if collider is Node else ""
	}

func surface_y_for_cell(cell: Vector2i) -> float:
	if main.has_method("surface_y_at_cell"):
		return float(main.call("surface_y_at_cell", Vector3i(cell.x, 0, cell.y)))
	var world_generation = main.get("world_generation_system")
	if world_generation != null and world_generation.has_method("surface_y_for_cell"):
		return float(world_generation.call("surface_y_for_cell", Vector3i(cell.x, 0, cell.y)))
	return 0.0

func flat_cell(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x / CELL), floori(position.z / CELL))

func world_position_for_flat_cell(cell: Vector2i) -> Vector3:
	return Vector3(float(cell.x) * CELL, surface_y_for_cell(cell) + 0.08, float(cell.y) * CELL)

func record_player_route_event(label: String, event_type: String, data: Dictionary) -> void:
	if timeline.size() >= 500:
		return
	timeline.append({
		"event": "player_route",
		"stage": event_type,
		"label": label,
		"elapsed": snappedf(elapsed, 0.001),
		"data": encode_json_value(data)
	})

func cell_to_chunk(cell: Vector2i) -> Vector2i:
	if main.has_method("cell_to_chunk"):
		return main.call("cell_to_chunk", cell.x, cell.y)
	return Vector2i(floori(float(cell.x) / float(CHUNK_SIZE)), floori(float(cell.y) / float(CHUNK_SIZE)))

func add_result(name: String, passed: bool, details := "") -> void:
	results.append({
		"name": name,
		"passed": passed,
		"details": details
	})

func failure_count() -> int:
	var count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			count += 1
	return count

func finish(exit_code: int) -> void:
	if finished:
		return
	finished = true
	save_report()
	write_progress("finish:%d" % exit_code)
	if is_instance_valid(main):
		main.call("request_graceful_quit", exit_code)
	else:
		get_tree().quit(exit_code)

func save_report() -> void:
	var report := {
		"schemaVersion": 1,
		"runnerId": TEST_ID,
		"testId": TEST_ID,
		"seed": seed,
		"runToken": run_token,
		"finished": true,
		"passed": failure_count() == 0,
		"status": "passed" if failure_count() == 0 else "failed",
		"nonHeadlessRequired": true,
		"evidenceLevel": "integration",
		"acceptanceClaims": [],
		"fixtureControls": {
			"liveGameplayAcceptance": false,
			"voxelPlaytest": OS.get_environment("VOXEL_PLAYTEST") != "",
			"directTownFixture": true,
			"playerTransformDuringAct": false,
			"cameraTransformDuringAct": false,
			"cameraAuthority": "player_owned_characterbody_camera",
			"movementAuthority": "collision_backed_player_route_authority_v2"
		},
		"failureCount": failure_count(),
		"startup_loading_failure_result": main.get("startup_loading_failure_result") if is_instance_valid(main) else {},
		"resultCount": results.size(),
		"results": results,
		"captures": captures,
		"timeline": timeline,
		"selectedEdge": encode_json_value(selected_edge),
		"selectedHouse": encode_json_value(selected_house)
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()

func write_progress(stage: String) -> void:
	timeline.append({
		"event": "progress",
		"stage": stage,
		"elapsed": snappedf(elapsed, 0.001)
	})
	if progress_path == "":
		return
	var file := FileAccess.open(progress_path, FileAccess.WRITE)
	if file != null:
		file.store_string("%s\n%.3f\n" % [stage, elapsed])
		file.close()

func wait_process_frames(count: int) -> void:
	for _i in range(maxi(0, count)):
		await get_tree().process_frame

func wait_physics_frames(count: int) -> void:
	for _i in range(maxi(0, count)):
		await get_tree().physics_frame

func ensure_dir(path: String) -> void:
	if path != "":
		DirAccess.make_dir_recursive_absolute(path)

func vector2i_to_array(value: Vector2i) -> Array:
	return [value.x, value.y]

func vec3(value: Vector3) -> Dictionary:
	return {
		"x": snappedf(value.x, 0.001),
		"y": snappedf(value.y, 0.001),
		"z": snappedf(value.z, 0.001)
	}

func encode_json_value(value):
	if value is Vector2i:
		return vector2i_to_array(value)
	if value is Vector3i:
		return [value.x, value.y, value.z]
	if value is Vector2:
		return { "x": snappedf(value.x, 0.001), "y": snappedf(value.y, 0.001) }
	if value is Vector3:
		return vec3(value)
	if value is Dictionary:
		var output := {}
		for key in value.keys():
			output[String(key)] = encode_json_value(value[key])
		return output
	if value is Array:
		var output_array := []
		for item in value:
			output_array.append(encode_json_value(item))
		return output_array
	return value
