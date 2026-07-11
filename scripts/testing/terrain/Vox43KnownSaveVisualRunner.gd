extends Node

const LivePlaytestPlayerNavigatorScript := preload("res://scripts/testing/player/LivePlaytestPlayerNavigator.gd")

const TEST_ID := "vox43_known_save_visual"
const EXPECTED_SEED := "atlas-71906947"
const CELL := 1.35
const FAILURE_CELL := Vector3i(322, 2, 28)
const FAILURE_CHUNK := Vector2i(11, 1)
const FAILURE_VANTAGE_CELL := Vector2i(316, 28)
const TUTORIAL_REPAIR_RADIUS_CELLS := 25
const REQUIRED_CAPTURES := [
	"menu_before_continue",
	"known_save_initial",
	"known_save_forest",
	"known_save_savanna",
	"known_save_failure_area"
]
const FRESH_WORLD_REQUIRED_CAPTURES := [
	"menu_before_new_game",
	"fresh_world_initial",
	"fresh_world_forest",
	"fresh_world_savanna"
]

var elapsed := 0.0
var finished := false
var menu: Node
var main: Node3D
var player: CharacterBody3D
var camera: Camera3D
var world_generation
var navigator
var report_path := ""
var progress_path := ""
var screenshot_dir := ""
var results: Array[Dictionary] = []
var captures: Array[Dictionary] = []
var route_events: Array[Dictionary] = []
var route_results: Array[Dictionary] = []
var startup_steps: Array[Dictionary] = []
var startup_signals_connected := false
var fresh_world_mode := false

func _ready() -> void:
	configure_paths()
	get_viewport().size = Vector2i(1280, 720)
	call_deferred("run")

func _process(delta: float) -> void:
	if finished:
		return
	elapsed += maxf(delta, 0.0)
	if elapsed > watchdog_seconds():
		add_result("known_save_runner_watchdog", false, {"elapsed": rounded(elapsed)})
		finish()

func configure_paths() -> void:
	fresh_world_mode = OS.get_environment("VOXEL_VOX43_FRESH_WORLD_REAL_BOOT").strip_edges() == "1"
	var report_env := "VOXEL_VOX43_FRESH_WORLD_REPORT" if fresh_world_mode else "VOXEL_VOX43_KNOWN_SAVE_REPORT"
	var progress_env := "VOXEL_VOX43_FRESH_WORLD_PROGRESS" if fresh_world_mode else "VOXEL_VOX43_KNOWN_SAVE_PROGRESS"
	var screenshot_env := "VOXEL_VOX43_FRESH_WORLD_SCREENSHOT_DIR" if fresh_world_mode else "VOXEL_VOX43_KNOWN_SAVE_SCREENSHOT_DIR"
	report_path = OS.get_environment(report_env).strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/vox43/known-save-visual.json")
	progress_path = OS.get_environment(progress_env).strip_edges()
	if progress_path == "":
		progress_path = ProjectSettings.globalize_path("res://artifacts/vox43/known-save-visual-progress.txt")
	screenshot_dir = OS.get_environment(screenshot_env).strip_edges()
	if screenshot_dir == "":
		screenshot_dir = ProjectSettings.globalize_path("res://artifacts/vox43/screenshots/known-save-visual")
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	DirAccess.make_dir_recursive_absolute(progress_path.get_base_dir())
	DirAccess.make_dir_recursive_absolute(screenshot_dir)

func run() -> void:
	mark_progress("start")
	var forbidden := forbidden_environment_summary()
	add_result("known_save_gameplay_flags_unset", bool(forbidden.get("passed", false)), forbidden)
	if not bool(forbidden.get("passed", false)):
		finish()
		return
	menu = get_parent()
	if menu == null:
		add_result("known_save_real_boot_menu_attached", false, {"reason": "missing_title_menu_parent"})
		finish()
		return
	await wait_process_frames(4)
	var launch_button := menu.get("new_game_button") as Button if fresh_world_mode else menu.get("continue_button") as Button
	var launch_ready := launch_button != null and is_instance_valid(launch_button) and launch_button.visible and not launch_button.disabled
	var launch_name := "fresh_world_new_game_button_ready" if fresh_world_mode else "known_save_continue_button_ready"
	add_result(launch_name, launch_ready, control_summary(launch_button))
	if not launch_ready:
		finish()
		return
	await capture_stage("menu_before_new_game" if fresh_world_mode else "menu_before_continue")
	dispatch_mouse_button_at(launch_button.get_global_rect().get_center(), MOUSE_BUTTON_LEFT, true)
	dispatch_mouse_button_at(launch_button.get_global_rect().get_center(), MOUSE_BUTTON_LEFT, false)
	mark_progress("new_game_clicked" if fresh_world_mode else "continue_clicked")
	if not await wait_for_main_load(150.0):
		finish()
		return
	bind_scene_nodes()
	var loaded := main != null and player != null and camera != null and world_generation != null
	add_result("known_save_main_loaded", loaded, scene_summary())
	if not loaded:
		finish()
		return
	if fresh_world_mode:
		await run_fresh_world_traversal()
		return
	var seed_ok := String(main.get("seed_text")) == EXPECTED_SEED
	add_result("known_save_seed_loaded", seed_ok, {"expected": EXPECTED_SEED, "actual": String(main.get("seed_text"))})
	player.set("automated_input", true)
	player.set("automated_move", Vector3.ZERO)
	player.set("automated_sprint", false)
	navigator = LivePlaytestPlayerNavigatorScript.new()
	navigator.setup(main, player, camera, self)
	await wait_physics_frames(30)
	await capture_stage("known_save_initial", surface_look_target(player.global_position))
	await visit_biome("savanna")
	var failure_route_start := player.global_position
	var failure_target := surface_position_for_cell(FAILURE_VANTAGE_CELL)
	var failure_route: Dictionary = await navigator.go_to_position(failure_target, {
		"label": "vox43_failure_area",
		"stopDistance": CELL * 0.8,
		"timeout": 120.0,
		"planTimeout": 18.0,
		"leaveCurrentHome": false,
		"tutorialPerimeterRecovery": false,
		"allowOutside": true
	})
	route_results.append(route_result_summary("failure_area", failure_target, failure_route))
	add_result("known_save_failure_area_reached_by_player_controller", bool(failure_route.get("ok", false)), route_results[-1])
	var failure_area_biome := surface_biome_at(player.global_position)
	var forest_traversal_distance := flat_distance(failure_route_start, player.global_position)
	var forest_traversal_passed := bool(failure_route.get("ok", false)) and failure_area_biome == "forest" and forest_traversal_distance >= CELL * 4.0
	add_result("known_save_forest_traversal", forest_traversal_passed, {
		"start": vec3(failure_route_start),
		"end": vec3(player.global_position),
		"distance": rounded(forest_traversal_distance),
		"actualBiome": failure_area_biome,
		"route": failure_route.get("route", {})
	})
	await capture_stage("known_save_forest", surface_look_target(player.global_position))
	var failure_look := surface_position_for_cell(Vector2i(FAILURE_CELL.x, FAILURE_CELL.z))
	await wait_physics_frames(60)
	await capture_stage("known_save_failure_area", failure_look)
	var fluid_summary := await wait_for_target_fluid_mesh(45.0)
	add_result("known_save_surface_fluid_state", bool(fluid_summary.get("passed", false)), fluid_summary)
	add_result("known_save_required_screenshots_saved", required_captures_saved(), capture_paths())
	finish()

func run_fresh_world_traversal() -> void:
	var actual_seed := String(main.get("seed_text"))
	add_result("fresh_world_random_seed_created", actual_seed != "" and actual_seed != EXPECTED_SEED, {"seed": actual_seed})
	player.set("automated_input", true)
	player.set("automated_move", Vector3.ZERO)
	player.set("automated_sprint", false)
	navigator = LivePlaytestPlayerNavigatorScript.new()
	navigator.setup(main, player, camera, self)
	await wait_physics_frames(30)
	await capture_stage("fresh_world_initial", surface_look_target(player.global_position))
	await visit_biome("forest")
	await visit_biome("savanna")
	add_result("fresh_world_required_screenshots_saved", required_captures_saved(), capture_paths())
	finish()

func wait_for_main_load(timeout_seconds: float) -> bool:
	var max_frames := ceili(timeout_seconds * float(Engine.physics_ticks_per_second))
	for frame in range(max_frames):
		var active_value = menu.get("active_main") if menu != null else null
		if active_value is Node3D:
			main = active_value
			connect_startup_signals()
		if main != null and is_instance_valid(main) and not bool(main.get("startup_loading_active")):
			mark_progress("continue_loaded")
			return true
		if frame % 60 == 0:
			var status_value = menu.get("status_label") if menu != null else null
			var visible_status := String(status_value.text) if is_instance_valid(status_value) and status_value is Label else ""
			var last_step := String(startup_steps[-1].get("message", "")) if not startup_steps.is_empty() else ""
			mark_progress("waiting_for_continue_load:%d status=%s step=%s" % [frame, visible_status, last_step])
		await get_tree().process_frame
	add_result("known_save_continue_load", false, {"reason": "timeout", "seconds": timeout_seconds})
	return false

func connect_startup_signals() -> void:
	if startup_signals_connected or main == null:
		return
	var callback := Callable(self, "_on_startup_loading_step")
	if main.has_signal("startup_loading_step") and not main.is_connected("startup_loading_step", callback):
		main.connect("startup_loading_step", callback)
		startup_signals_connected = true

func _on_startup_loading_step(message: String) -> void:
	startup_steps.append({"time": rounded(elapsed), "message": message})
	if startup_steps.size() > 160:
		startup_steps.pop_front()
	mark_progress("startup_step:%s" % message)

func bind_scene_nodes() -> void:
	if main == null or not is_instance_valid(main):
		return
	player = main.get("player") as CharacterBody3D
	camera = player.get("camera") as Camera3D if player != null else null
	if camera != null:
		camera.make_current()
	world_generation = main.get("world_generation_system")

func visit_biome(biome_id: String) -> void:
	var result_prefix := "fresh_world" if fresh_world_mode else "known_save"
	var targets := find_surface_targets_for_biome(biome_id)
	if targets.is_empty():
		add_result("%s_%s_target_found" % [result_prefix, biome_id], false, {"reason": "no_surface_target"})
		return
	var attempts: Array[Dictionary] = []
	for index in range(mini(24 if fresh_world_mode else 12, targets.size())):
		var target: Vector3 = targets[index]
		var route: Dictionary = await navigator.go_to_position(target, {
			"label": "vox43_%s_%02d" % [biome_id, index],
			"stopDistance": CELL * (0.28 if fresh_world_mode else 0.8),
			"timeout": 45.0,
			"planTimeout": 10.0,
			"leaveCurrentHome": fresh_world_mode,
			"tutorialPerimeterRecovery": fresh_world_mode,
			"allowOutside": true
		})
		var route_summary := route_result_summary(biome_id, target, route)
		attempts.append(route_summary)
		if not bool(route.get("ok", false)):
			continue
		var actual_biome := surface_biome_at(player.global_position)
		var actual_outside_town := fresh_position_outside_town(player.global_position)
		var passed := actual_biome == biome_id and (actual_outside_town if fresh_world_mode else true)
		route_summary["actualBiome"] = actual_biome
		route_summary["actualOutsideTown"] = actual_outside_town
		attempts[-1] = route_summary
		if passed:
			route_results.append(route_summary)
			add_result("%s_%s_traversal" % [result_prefix, biome_id], true, route_summary.merged({"attempts": attempts}))
			await wait_physics_frames(120 if fresh_world_mode else 30)
			await capture_stage("%s_%s" % [result_prefix, biome_id], surface_look_target(player.global_position))
			return
	route_results.append(attempts[-1] if not attempts.is_empty() else {"label": biome_id})
	add_result("%s_%s_traversal" % [result_prefix, biome_id], false, {"reason": "no_routeable_biome_pose", "attempts": attempts})

func find_surface_targets_for_biome(biome_id: String) -> Array[Vector3]:
	var origin_cell := flat_cell(player.global_position)
	var targets: Array[Vector3] = []
	var seen := {}
	var max_radius := 160 if fresh_world_mode else 64
	for radius in range(4, max_radius + 1, 4):
		for z in range(origin_cell.y - radius, origin_cell.y + radius + 1, 4):
			for x in [origin_cell.x - radius, origin_cell.x + radius]:
				var candidate := standable_surface_position(surface_position_for_cell(Vector2i(x, z)), biome_id)
				append_unique_surface_target(targets, seen, candidate)
		for x in range(origin_cell.x - radius + 4, origin_cell.x + radius, 4):
			for z in [origin_cell.y - radius, origin_cell.y + radius]:
				var candidate := standable_surface_position(surface_position_for_cell(Vector2i(x, z)), biome_id)
				append_unique_surface_target(targets, seen, candidate)
		if targets.size() >= 24:
			break
	var tutorial = main.get("tutorial_system") if main != null else null
	var tutorial_state: Dictionary = tutorial.call("state") if fresh_world_mode and tutorial != null and tutorial.has_method("state") else {}
	var town_center: Vector2i = tutorial_state.get("townCenter", origin_cell)
	targets.sort_custom(func(a: Vector3, b: Vector3):
		if fresh_world_mode:
			var a_crosses := not tutorial_perimeter_crossing(origin_cell, flat_cell(a), town_center).is_empty()
			var b_crosses := not tutorial_perimeter_crossing(origin_cell, flat_cell(b), town_center).is_empty()
			if a_crosses != b_crosses:
				return not a_crosses
		return flat_distance(player.global_position, a) < flat_distance(player.global_position, b)
	)
	return targets

func append_unique_surface_target(targets: Array[Vector3], seen: Dictionary, candidate: Vector3) -> void:
	if candidate == Vector3.INF or flat_distance(player.global_position, candidate) < CELL * 2.0:
		return
	var key := flat_cell(candidate)
	if seen.has(key):
		return
	seen[key] = true
	targets.append(candidate)

func standable_surface_position(candidate: Vector3, biome_id: String) -> Vector3:
	if surface_biome_at(candidate) != biome_id:
		return Vector3.INF
	if fresh_world_mode and not fresh_position_outside_town(candidate):
		return Vector3.INF
	var npc_system = main.get("npc_system") if main != null else null
	var autonomy = npc_system.get("autonomy_system") if npc_system != null else null
	if autonomy == null or not autonomy.has_method("closest_walkable"):
		return Vector3.INF
	var walkable_value = autonomy.call("closest_walkable", candidate, CELL * 3.0)
	if not (walkable_value is Dictionary):
		return Vector3.INF
	var walkable: Dictionary = walkable_value
	var position: Vector3 = walkable.get("position", Vector3.INF)
	if not bool(walkable.get("found", false)) or position == Vector3.INF or surface_biome_at(position) != biome_id:
		return Vector3.INF
	return position

func fresh_position_outside_town(position: Vector3) -> bool:
	if not fresh_world_mode or main == null:
		return true
	var tutorial = main.get("tutorial_system")
	if tutorial == null or not tutorial.has_method("state"):
		return true
	var state: Dictionary = tutorial.call("state")
	var center: Vector2i = state.get("townCenter", flat_cell(player.global_position))
	return cell_outside_tutorial_perimeter(flat_cell(position), center)

func surface_position_for_cell(cell: Vector2i) -> Vector3:
	var y := float(world_generation.call("surface_y_for_cell", Vector3i(cell.x, 0, cell.y))) if world_generation != null else player.global_position.y
	return Vector3((float(cell.x) + 0.5) * CELL, y + CELL * 0.85, (float(cell.y) + 0.5) * CELL)

func surface_biome_at(position: Vector3) -> String:
	if main != null and main.has_method("surface_biome_at_cell"):
		var cell := flat_cell(position)
		return String(main.call("surface_biome_at_cell", Vector3i(cell.x, 0, cell.y)))
	if world_generation == null:
		return ""
	var surface_y := float(world_generation.call("surface_y_at", position))
	var sample: Dictionary = world_generation.call("sample_world", Vector3(position.x, surface_y + CELL * 0.1, position.z))
	return String(sample.get("biome", ""))

func surface_look_target(origin: Vector3) -> Vector3:
	var forward := -camera.global_basis.z if camera != null else Vector3.FORWARD
	var target := origin + Vector3(forward.x, 0.0, forward.z).normalized() * CELL * 8.0
	var surface_y := float(world_generation.call("surface_y_at", target)) if world_generation != null else origin.y
	return Vector3(target.x, surface_y + CELL * 0.35, target.z)

func wait_for_target_fluid_mesh(timeout_seconds: float) -> Dictionary:
	var max_frames := ceili(timeout_seconds * float(Engine.physics_ticks_per_second))
	for frame in range(max_frames):
		var summary := target_fluid_mesh_summary()
		if bool(summary.get("chunkLoaded", false)):
			return summary
		if frame % 60 == 0:
			mark_progress("waiting_target_fluid_mesh:%d" % frame)
		await get_tree().physics_frame
	var summary := target_fluid_mesh_summary()
	summary["passed"] = false
	summary["reason"] = "target_fluid_mesh_timeout"
	return summary

func target_fluid_mesh_summary() -> Dictionary:
	var chunks_value = main.get("chunks") if main != null else {}
	var chunks: Dictionary = chunks_value if chunks_value is Dictionary else {}
	var chunk := chunks.get(FAILURE_CHUNK, null) as Node3D
	if chunk == null:
		return {"found": false, "chunkLoaded": false, "passed": false, "chunk": vec2i(FAILURE_CHUNK), "reason": "chunk_not_loaded"}
	var fluid_instance := chunk.get_node_or_null("TerrainFluidMesh") as MeshInstance3D
	var mesh: Mesh = fluid_instance.mesh if fluid_instance != null else null
	if mesh == null or mesh.get_surface_count() <= 0:
		return {
			"found": false,
			"chunkLoaded": true,
			"passed": true,
			"chunk": vec2i(FAILURE_CHUNK),
			"surfaceFluidMeshPresent": false,
			"reason": "no_surface_fluid_mesh",
			"terrainSignature": String((chunk.get_node_or_null("TerrainMesh") as MeshInstance3D).mesh.get_meta("terrainSignature", "")) if chunk.get_node_or_null("TerrainMesh") is MeshInstance3D and (chunk.get_node_or_null("TerrainMesh") as MeshInstance3D).mesh != null else ""
		}
	var max_triangle_edge := max_mesh_triangle_edge(mesh)
	var step := int(mesh.get_meta("nativeFluidStepCells", -1))
	var forbidden_coarse := bool(mesh.get_meta("forbiddenCoarseFluidPayload", false))
	var legacy := bool(mesh.get_meta("terrainFluidLegacyExactPayload", false))
	var fluid_faces := int(mesh.get_meta("chunk_fluid_faces", 0))
	var bounds := mesh.get_aabb()
	return {
		"found": true,
		"chunkLoaded": true,
		"passed": step == 1 and fluid_faces > 0 and not forbidden_coarse and not legacy and max_triangle_edge <= CELL * 1.5,
		"chunk": vec2i(FAILURE_CHUNK),
		"failureCell": vec3i(FAILURE_CELL),
		"nativeFluidStepCells": step,
		"fluidPayloadRevision": int(mesh.get_meta("fluidPayloadRevision", -1)),
		"fluidFaces": fluid_faces,
		"waterFaces": int(mesh.get_meta("chunk_water_faces", 0)),
		"lavaFaces": int(mesh.get_meta("chunk_lava_faces", 0)),
		"nativeFluidCellCount": int(mesh.get_meta("nativeFluidCellCount", 0)),
		"terrainSignature": String(mesh.get_meta("terrainSignature", "")),
		"forbiddenCoarseFluidPayload": forbidden_coarse,
		"terrainFluidLegacyExactPayload": legacy,
		"maxTriangleEdgeMeters": rounded(max_triangle_edge),
		"maxAllowedTriangleEdgeMeters": rounded(CELL * 1.5),
		"localAabb": aabb_summary(bounds),
		"collisionSource": String(fluid_instance.get_meta("collision_source", ""))
	}

func max_mesh_triangle_edge(mesh: Mesh) -> float:
	var maximum := 0.0
	for surface in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface)
		if arrays.size() <= Mesh.ARRAY_VERTEX:
			continue
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] is PackedInt32Array else PackedInt32Array()
		if not indices.is_empty():
			for index in range(0, indices.size() - 2, 3):
				maximum = maxf(maximum, triangle_max_edge(vertices[indices[index]], vertices[indices[index + 1]], vertices[indices[index + 2]]))
		else:
			for index in range(0, vertices.size() - 2, 3):
				maximum = maxf(maximum, triangle_max_edge(vertices[index], vertices[index + 1], vertices[index + 2]))
	return maximum

func triangle_max_edge(a: Vector3, b: Vector3, c: Vector3) -> float:
	return maxf(a.distance_to(b), maxf(b.distance_to(c), c.distance_to(a)))

func capture_stage(stage: String, look_target = null) -> void:
	if fresh_world_mode:
		await dismiss_visible_dialogue()
	if look_target is Vector3:
		aim_at(look_target)
	await wait_process_frames(3)
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var path := screenshot_dir.path_join("%s.png" % stage)
	var error := image.save_png(path)
	captures.append({
		"stage": stage,
		"path": path,
		"saved": error == OK,
		"size": {"x": image.get_width(), "y": image.get_height()},
		"player": vec3(player.global_position) if player != null else {},
		"biome": surface_biome_at(player.global_position) if player != null and world_generation != null else ""
	})
	mark_progress("capture:%s" % stage)

func dismiss_visible_dialogue() -> void:
	if main == null:
		return
	for node in main.find_children("*", "Button", true, false):
		var button := node as Button
		if button == null or not button.is_visible_in_tree() or String(button.text).strip_edges() != "Close":
			continue
		var center := button.get_global_rect().get_center()
		dispatch_mouse_button_at(center, MOUSE_BUTTON_LEFT, true)
		dispatch_mouse_button_at(center, MOUSE_BUTTON_LEFT, false)
		await wait_process_frames(8)
		return

func aim_at(target: Vector3) -> void:
	if player == null or camera == null:
		return
	var flat_target := Vector3(target.x, player.global_position.y, target.z)
	if flat_target.distance_to(player.global_position) > 0.05:
		player.look_at(flat_target, Vector3.UP)
	if target.distance_to(camera.global_position) > 0.05:
		camera.look_at(target, Vector3.UP)
	player.set("pitch", camera.rotation.x)

func dispatch_mouse_button(button_index: int, pressed: bool) -> void:
	dispatch_mouse_button_at(get_viewport().get_visible_rect().size * 0.5, button_index, pressed)

func dispatch_mouse_button_at(position: Vector2, button_index: int, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = button_index
	event.pressed = pressed
	event.position = position
	event.global_position = position
	get_viewport().push_input(event)

func nearest_block(block_type: String, origin: Vector3) -> Node3D:
	var blocks_value = main.get("blocks") if main != null else {}
	if not (blocks_value is Dictionary):
		return null
	var best: Node3D
	var best_distance := INF
	for value in (blocks_value as Dictionary).values():
		var block := value as Node3D
		if block == null or not is_instance_valid(block) or String(block.get_meta("block_type", "")) != block_type:
			continue
		var distance := flat_distance(block.global_position, origin)
		if distance < best_distance:
			best = block
			best_distance = distance
	return best

func player_current_home_entry() -> Dictionary:
	if main == null or player == null:
		return {}
	var tutorial = main.get("tutorial_system")
	if tutorial == null or not tutorial.has_method("state"):
		return {}
	var state: Dictionary = tutorial.call("state")
	var start_cell: Vector2i = state.get("startCell", flat_cell(player.global_position))
	var entry := {
		"id": "player_starter_shelter",
		"homeCell": start_cell,
		"homePosition": world_position_for_flat_cell(start_cell),
		"porchCell": Vector2i(start_cell.x, start_cell.y - 4),
		"porchPosition": world_position_for_flat_cell(Vector2i(start_cell.x, start_cell.y - 4)),
		"doorCell": Vector2i(start_cell.x, start_cell.y - 3),
		"interiorMinCell": Vector2i(start_cell.x - 4, start_cell.y - 5),
		"interiorMaxCell": Vector2i(start_cell.x + 4, start_cell.y + 4)
	}
	return entry if position_inside_entry_home(entry, player.global_position) else {}

func position_inside_entry_home(entry: Dictionary, position: Vector3) -> bool:
	if entry.is_empty():
		return false
	var cell := flat_cell(position)
	var min_cell: Vector2i = entry.get("interiorMinCell", cell)
	var max_cell: Vector2i = entry.get("interiorMaxCell", cell)
	return cell.x >= min_cell.x and cell.x <= max_cell.x and cell.y >= min_cell.y and cell.y <= max_cell.y

func leave_current_player_home_for_route(entry: Dictionary, label: String) -> bool:
	if not position_inside_entry_home(entry, player.global_position):
		return true
	var door_position := world_position_for_flat_cell(entry.get("doorCell", flat_cell(player.global_position)))
	var door := nearest_block("door", door_position)
	if door == null or not is_instance_valid(door) or flat_distance(door.global_position, door_position) > CELL * 2.0:
		record_player_route_event(label, "home_exit_failed", {"reason": "door_missing", "doorPosition": vec3(door_position)})
		return false
	if not bool(door.get_meta("open", false)):
		var used: Dictionary = await navigator.use_block(door, "%s_current_home_door" % label, {
			"timeout": 14.0,
			"actionKind": "door"
		})
		if not bool(used.get("ok", false)):
			record_player_route_event(label, "home_exit_failed", {"reason": "door_use_failed", "result": used})
			return false
		await wait_physics_frames(18)
	if not bool(door.get_meta("open", false)):
		record_player_route_event(label, "home_exit_failed", {"reason": "door_not_open"})
		return false
	var home_cell: Vector2i = entry.get("homeCell", flat_cell(player.global_position))
	var porch_cell: Vector2i = entry.get("porchCell", home_cell)
	var delta := porch_cell - home_cell
	var step := Vector2i(signi(delta.x), 0) if absi(delta.x) > absi(delta.y) else Vector2i(0, signi(delta.y))
	var outside_cell := porch_cell + step
	var outside_position := world_position_for_flat_cell(outside_cell)
	var reached: bool = await navigator.drive_to_point_for_home_exit(outside_position, CELL * 0.45, 16.0, "%s_exit_current_home" % label)
	record_player_route_event(label, "home_exit", {
		"reached": reached,
		"door": String(door.get_path()),
		"outsideCell": vec2i(outside_cell),
		"player": vec3(player.global_position)
	})
	return reached

func tutorial_perimeter_crossing(current_cell: Vector2i, target_cell: Vector2i, town_center: Vector2i) -> Dictionary:
	var current_inside := cell_inside_tutorial_perimeter(current_cell, town_center)
	var target_inside := cell_inside_tutorial_perimeter(target_cell, town_center)
	var current_outside := cell_outside_tutorial_perimeter(current_cell, town_center)
	var target_outside := cell_outside_tutorial_perimeter(target_cell, town_center)
	if not ((current_inside and target_outside) or (current_outside and target_inside)):
		return {}
	var gate := tutorial_gate_cells(target_cell if current_inside else current_cell, town_center)
	var gate_cell: Vector2i = gate.get("gateCell", Vector2i(999999, 999999))
	var inside_cell: Vector2i = gate.get("insideCell", gate_cell)
	var outside_cell: Vector2i = gate.get("outsideCell", gate_cell)
	return {
		"active": true,
		"direction": "outbound" if current_inside else "inbound",
		"gateCell": gate_cell,
		"approachCell": inside_cell if current_inside else outside_cell,
		"tailCells": [gate_cell, outside_cell if current_inside else inside_cell, target_cell]
	}

func cell_inside_tutorial_perimeter(cell: Vector2i, center: Vector2i) -> bool:
	return absi(cell.x - center.x) <= TUTORIAL_REPAIR_RADIUS_CELLS and absi(cell.y - center.y) <= TUTORIAL_REPAIR_RADIUS_CELLS

func cell_outside_tutorial_perimeter(cell: Vector2i, center: Vector2i) -> bool:
	return absi(cell.x - center.x) > TUTORIAL_REPAIR_RADIUS_CELLS + 1 or absi(cell.y - center.y) > TUTORIAL_REPAIR_RADIUS_CELLS + 1

func tutorial_gate_cells(reference: Vector2i, center: Vector2i) -> Dictionary:
	var delta := reference - center
	if absi(delta.x) >= absi(delta.y):
		var side := signi(delta.x) if delta.x != 0 else 1
		return {
			"gateCell": Vector2i(center.x + side * TUTORIAL_REPAIR_RADIUS_CELLS, center.y),
			"insideCell": Vector2i(center.x + side * (TUTORIAL_REPAIR_RADIUS_CELLS - 3), center.y),
			"outsideCell": Vector2i(center.x + side * (TUTORIAL_REPAIR_RADIUS_CELLS + 3), center.y)
		}
	var side := signi(delta.y) if delta.y != 0 else 1
	return {
		"gateCell": Vector2i(center.x, center.y + side * TUTORIAL_REPAIR_RADIUS_CELLS),
		"insideCell": Vector2i(center.x, center.y + side * (TUTORIAL_REPAIR_RADIUS_CELLS - 3)),
		"outsideCell": Vector2i(center.x, center.y + side * (TUTORIAL_REPAIR_RADIUS_CELLS + 3))
	}

func aim_until_interaction_hit(block: Node3D, _label: String) -> Dictionary:
	var summary := {}
	for height_scale in [0.28, 0.48, 0.12, 0.70]:
		aim_at(block.global_position + Vector3(0.0, CELL * float(height_scale), 0.0))
		await wait_physics_frames(6)
		summary = interaction_hit_summary()
		if interaction_hit_matches_block(summary, block):
			return summary
	return summary

func interaction_hit_summary() -> Dictionary:
	if player == null or not player.has_method("view_ray"):
		return {"hit": false, "reason": "missing_player_view_ray"}
	var hit: Dictionary = player.call("view_ray", 10.5, true)
	if hit.is_empty():
		return {"hit": false}
	var collider := hit.get("collider") as Node
	var block_node := main.call("interaction_block_from_collider", collider) as Node if main != null and main.has_method("interaction_block_from_collider") else collider
	var hit_position: Vector3 = hit.get("position", Vector3.ZERO)
	return {
		"hit": true,
		"colliderPath": String(collider.get_path()) if collider != null else "",
		"blockPath": String(block_node.get_path()) if block_node != null else "",
		"blockType": String(block_node.get_meta("block_type", "")) if block_node != null else "",
		"withinReach": bool(main.call("hit_within_action_reach", hit)) if main != null and main.has_method("hit_within_action_reach") else false,
		"distance": rounded(player.global_position.distance_to(hit_position)),
		"position": vec3(hit_position)
	}

func interaction_hit_matches_block(summary: Dictionary, block: Node) -> bool:
	return block != null and bool(summary.get("hit", false)) and String(summary.get("blockPath", "")) == String(block.get_path())

func record_player_route_event(label: String, event_type: String, data: Dictionary) -> void:
	if route_events.size() >= 240:
		return
	route_events.append({
		"time": rounded(elapsed),
		"label": label,
		"event": event_type,
		"data": data
	})

func flat_cell(position: Vector3) -> Vector2i:
	return Vector2i(floori(position.x / CELL), floori(position.z / CELL))

func world_position_for_flat_cell(cell: Vector2i) -> Vector3:
	return surface_position_for_cell(cell)

func route_result_summary(label: String, target: Vector3, result: Dictionary) -> Dictionary:
	return {
		"label": label,
		"ok": bool(result.get("ok", false)),
		"status": String(result.get("status", "")),
		"reason": String(result.get("reason", "")),
		"target": vec3(target),
		"player": vec3(player.global_position) if player != null else {},
		"route": result.get("route", {})
	}

func forbidden_environment_summary() -> Dictionary:
	var names := ["VOXEL_PLAYTEST", "VOXEL_TEST_SEED", "VOXEL_GOD_MODE", "VOXEL_REAL_TUTORIAL_GOD_MODE"]
	var values := {}
	var passed := true
	for name in names:
		var value := OS.get_environment(name).strip_edges()
		values[name] = {"present": value != "", "valueLength": value.length()}
		if value != "":
			passed = false
	return {"passed": passed, "values": values}

func scene_summary() -> Dictionary:
	return {
		"realBootAttachedToMainMenu": menu != null and is_instance_valid(menu),
		"clickedContinueViaViewportInput": not fresh_world_mode,
		"clickedNewGameViaViewportInput": fresh_world_mode,
		"seed": String(main.get("seed_text")) if main != null else "",
		"player": vec3(player.global_position) if player != null else {},
		"savePathOverride": OS.get_environment("VOXEL_SAVE_PATH_OVERRIDE"),
		"automatedInputBeforeTraversal": bool(player.get("automated_input")) if player != null else false
	}

func control_summary(control: Control) -> Dictionary:
	if control == null:
		return {"found": false}
	return {
		"found": true,
		"visible": control.visible,
		"disabled": bool(control.get("disabled")),
		"text": String(control.get("text")),
		"rect": {"x": control.get_global_rect().position.x, "y": control.get_global_rect().position.y, "w": control.get_global_rect().size.x, "h": control.get_global_rect().size.y}
	}

func required_captures_saved() -> bool:
	for stage in required_capture_stages():
		if not FileAccess.file_exists(screenshot_dir.path_join("%s.png" % stage)):
			return false
	return true

func capture_paths() -> Array[String]:
	var paths: Array[String] = []
	for stage in required_capture_stages():
		paths.append(screenshot_dir.path_join("%s.png" % stage))
	return paths

func required_capture_stages() -> Array:
	return FRESH_WORLD_REQUIRED_CAPTURES if fresh_world_mode else REQUIRED_CAPTURES

func add_result(name: String, passed: bool, details = {}) -> void:
	results.append({"name": name, "passed": passed, "details": details})
	print("[%s] %s %s" % ["PASS" if passed else "FAIL", name, JSON.stringify(details)])

func finish() -> void:
	if finished:
		return
	finished = true
	if player != null and is_instance_valid(player):
		player.set("automated_move", Vector3.ZERO)
		player.set("automated_sprint", false)
		player.set("automated_input", false)
	var runner_id := "vox43_fresh_world_traversal" if fresh_world_mode else TEST_ID
	var claim := "vox43_fresh_world_surface_traversal" if fresh_world_mode else "vox43_known_save_surface_fluid_visual"
	var report := {
		"schemaVersion": 1,
		"runnerId": runner_id,
		"testId": runner_id,
		"runToken": OS.get_environment("VOXEL_VOX43_FRESH_WORLD_RUN_TOKEN") if fresh_world_mode else OS.get_environment("VOXEL_VOX43_KNOWN_SAVE_RUN_TOKEN"),
		"evidenceLevel": "acceptance_visual",
		"acceptanceClaims": [claim],
		"scope": "Normal project boot, physical New Game input, random generated world, and collision-backed real player-controller biome traversal." if fresh_world_mode else "Normal project boot, visible Continue button input, isolated byte-equivalent atlas-71906947 save, real player-controller traversal, exact fluid metadata, and headed screenshots.",
		"finished": true,
		"passed": all_passed(),
		"failureCount": failure_count(),
		"resultCount": results.size(),
		"seed": String(main.get("seed_text")) if main != null else "",
		"savePathOverride": OS.get_environment("VOXEL_SAVE_PATH_OVERRIDE"),
		"requiredScreenshots": required_capture_stages(),
		"screenshotDir": screenshot_dir,
		"captures": captures,
		"routeResults": route_results,
		"routeEvents": route_events,
		"timeline": route_events if not route_events.is_empty() else captures,
		"startupSteps": startup_steps,
		"forbiddenCallSelfScan": forbidden_call_self_scan(),
		"results": results
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	mark_progress("finished:%s" % str(report.passed))
	get_tree().quit(0 if bool(report.passed) else 1)

func forbidden_call_self_scan() -> Dictionary:
	var sources := [
		ProjectSettings.globalize_path("res://scripts/testing/terrain/Vox43KnownSaveVisualRunner.gd"),
		ProjectSettings.globalize_path("res://scripts/testing/player/LivePlaytestPlayerNavigator.gd")
	]
	var banned := [
		"interact_" + "with(",
		"on_door_" + "opened(",
		"on_block_" + "placed(",
		"sleep_at_" + "bed(",
		"move_" + "npc(",
		"request_door_" + "state(",
		"request_" + "crossing(",
		"player.global_" + "position ="
	]
	var findings := []
	for path in sources:
		var source := FileAccess.get_file_as_string(path)
		for pattern in banned:
			if source.find(pattern) >= 0:
				findings.append({"path": path, "pattern": pattern})
	return {"status": "passed" if findings.is_empty() else "failed", "findings": findings}

func all_passed() -> bool:
	for result in results:
		if not bool(result.get("passed", false)):
			return false
	return not results.is_empty()

func failure_count() -> int:
	var count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			count += 1
	return count

func mark_progress(message: String) -> void:
	var file := FileAccess.open(progress_path, FileAccess.WRITE)
	if file != null:
		file.store_string("%.3f %s" % [elapsed, message])
		file.close()

func watchdog_seconds() -> float:
	var env_name := "VOXEL_VOX43_FRESH_WORLD_WATCHDOG_SECONDS" if fresh_world_mode else "VOXEL_VOX43_KNOWN_SAVE_WATCHDOG_SECONDS"
	return maxf(60.0, float(OS.get_environment(env_name).to_int()))

func wait_process_frames(count: int) -> void:
	for _index in range(maxi(0, count)):
		await get_tree().process_frame

func wait_physics_frames(count: int) -> void:
	for _index in range(maxi(0, count)):
		await get_tree().physics_frame

func flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

func rounded(value: float) -> float:
	return snappedf(value, 0.001)

func vec2i(value: Vector2i) -> Dictionary:
	return {"x": value.x, "z": value.y}

func vec3i(value: Vector3i) -> Dictionary:
	return {"x": value.x, "y": value.y, "z": value.z}

func vec3(value: Vector3) -> Dictionary:
	return {"x": rounded(value.x), "y": rounded(value.y), "z": rounded(value.z)}

func aabb_summary(value: AABB) -> Dictionary:
	return {"position": vec3(value.position), "size": vec3(value.size), "end": vec3(value.end)}
