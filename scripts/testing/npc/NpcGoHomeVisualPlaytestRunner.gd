extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const StructureDoorRulesScript := preload("res://scripts/StructureDoorRules.gd")
const HomeInteriorServiceScript := preload("res://scripts/npc_ai/behavior/HomeInteriorService.gd")

const TEST_ID := "npc_go_home_visual_door_traversal"
const CELL := 1.35
const WATER_LEVEL := 11.1
const WATCHDOG_DEFAULT_SECONDS := 90.0
const OBSERVATION_SECONDS := 65.0
const CAPTURE_WIDTH := 1280
const CAPTURE_HEIGHT := 720

class ScriptedNpcHandle:
	var npc_system: Node
	var actor: Node
	var lines: Array[String] = []

	func _init(system_node: Node, actor_node: Node) -> void:
		npc_system = system_node
		actor = actor_node

	func say(text: String) -> void:
		lines.append(text)
		if actor != null and is_instance_valid(actor):
			actor.set_meta("npc_script_line", text)
		print("npc1.say('%s')" % text)

	func go_home() -> Dictionary:
		print("npc1.go_home()")
		if npc_system == null or not npc_system.has_method("order_go_home"):
			return { "state": "FAILED_TARGET_GONE", "failureReason": "missing_order_go_home" }
		return npc_system.call("order_go_home", actor, "visual_playtest_go_home")

var main: Node3D
var player: CharacterBody3D
var npc_system: Node
var npc_body: CharacterBody3D
var npc_entry: Dictionary = {}
var observer_camera: Camera3D
var home_doors: Array[Node] = []
var report_path := ""
var progress_path := ""
var screenshot_dir := ""
var run_token := ""
var seed := ""
var elapsed := 0.0
var watchdog_seconds := WATCHDOG_DEFAULT_SECONDS
var finished := false
var failed := false
var results: Array[Dictionary] = []
var captures: Array[Dictionary] = []
var timeline: Array[Dictionary] = []
var script_lines: Array[String] = []
var fixture := {}
var initial_stats := {}
var final_stats := {}
var door_opens_before := 0
var door_closes_before := 0
var saw_at_door := false
var saw_door_open := false
var saw_inside := false
var saw_inside_closed := false
var captured_at_door := false
var captured_open := false
var captured_inside_closed := false

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
		add_result("visual_go_home_watchdog", false, "watchdog %.1fs exceeded" % watchdog_seconds)
		if npc_body != null and is_instance_valid(npc_body):
			await_capture_timeout()
		finish(1)

func configure_from_environment() -> void:
	seed = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
	if seed == "":
		seed = "atlas-1492"
	report_path = OS.get_environment("VOXEL_NPC_GO_HOME_VISUAL_REPORT")
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/npc/reports/go-home-visual-playtest.json")
	progress_path = OS.get_environment("VOXEL_NPC_GO_HOME_VISUAL_PROGRESS")
	screenshot_dir = OS.get_environment("VOXEL_NPC_GO_HOME_VISUAL_SCREENSHOT_DIR")
	if screenshot_dir == "":
		screenshot_dir = ProjectSettings.globalize_path("res://artifacts/npc/screenshots/go-home-visual")
	run_token = OS.get_environment("VOXEL_NPC_GO_HOME_VISUAL_RUN_TOKEN")
	var watchdog_value := OS.get_environment("VOXEL_NPC_GO_HOME_VISUAL_WATCHDOG_SECONDS").strip_edges()
	if watchdog_value != "":
		watchdog_seconds = maxf(10.0, float(watchdog_value))
	ensure_dir(screenshot_dir)
	ensure_dir(report_path.get_base_dir())
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
	add_child(main)
	write_progress("main_instantiated")
	await wait_physics_frames(45)
	bind_scene_nodes()
	if main == null or player == null or npc_system == null:
		add_result("scene_bootstrap", false, "main/player/npc_system missing")
		finish(1)
		return
	configure_playtest_scene()
	await setup_one_house_one_npc_fixture()
	if failed:
		finish(1)
		return

	add_result("single_fixture_npc_only", int(npc_system.stats().get("npcs", 0)) == 1, "npc count %d" % int(npc_system.stats().get("npcs", 0)))
	await capture_stage("spawn_behind_home", "spawn")
	var npc1 := ScriptedNpcHandle.new(npc_system, npc_body)
	npc1.say("Thanks for all your help. I should probably get home and recover now.")
	script_lines = npc1.lines.duplicate()
	var order := npc1.go_home()
	fixture["order"] = sanitize_value(order)
	add_result(
		"scripted_go_home_order_accepted",
		String(order.get("kind", "")) == "go_home" and String(order.get("state", "")) == "PENDING",
		JSON.stringify(sanitize_value(order))
	)
	await observe_go_home()
	finish(1 if failed else 0)

func bind_scene_nodes() -> void:
	if main == null:
		return
	player = main.get("player") as CharacterBody3D
	npc_system = main.get("npc_system") as Node

func configure_playtest_scene() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	if player != null:
		player.set("automated_input", true)
		player.set("automated_move", Vector3.ZERO)
		player.set("automated_sprint", false)
		player.set_physics_process(false)
		player.collision_layer = 0
		player.collision_mask = 0
	var hud = main.get("hud") if main != null else null
	if hud != null and hud.get("hud_root") is Control:
		(hud.get("hud_root") as Control).visible = false
	if main.has_method("apply_runtime_setting"):
		main.call("apply_runtime_setting", "headBob", false, false)
		main.call("apply_runtime_setting", "handSway", false, false)
	if main.get("tutorial_system") != null:
		var tutorial = main.get("tutorial_system")
		tutorial.set("intro_bed_used", true)
		tutorial.set("intro_repair_active", false)
		tutorial.set("intro_repair_complete", true)
		tutorial.set("final_night_active", false)
		tutorial.set("final_night_complete", true)
	main.set("time_of_day", 0.30)
	if npc_system != null and npc_system.has_method("clear"):
		npc_system.call("clear")
	observer_camera = Camera3D.new()
	observer_camera.name = "NpcGoHomeVisualPlaytestCamera"
	observer_camera.fov = 62.0
	add_child(observer_camera)
	observer_camera.make_current()

func setup_one_house_one_npc_fixture() -> void:
	var center := find_dry_fixture_center()
	var level := maxf(float(main.call("surface_y_at_cell", Vector3i(center.x, 0, center.y))), WATER_LEVEL + 3.0)
	flatten_fixture(center, level, 24)
	clear_blocks_near_cell(center, 24)
	clear_props_near_cell(center, 30)
	move_player_for_lod(center, level)
	if main.has_method("update_chunks"):
		main.call("update_chunks", true)
	await wait_physics_frames(12)

	var structure_system = main.get("structure_system")
	if structure_system == null or not structure_system.has_method("build_building"):
		add_result("fixture_house_built", false, "structure system missing")
		return
	var width := 7
	var depth := 7
	var side := 0
	var base_x := center.x - int(width / 2)
	var base_z := center.y - int(depth / 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 90421
	structure_system.call("build_building", base_x, base_z, level, width, depth, 4, "woodBlock", "stoneBlock", side, rng, false)
	remove_extra_fixture_utilities(center, 12)
	if main.has_method("rebuild_chunks_around_cell"):
		main.call("rebuild_chunks_around_cell", center)
	await wait_physics_frames(20)
	if npc_system.has_method("flush_navigation_change_bus"):
		npc_system.call("flush_navigation_change_bus")

	var door_cells := StructureDoorRulesScript.door_cells(width, depth, side)
	var primary_door_entry: Dictionary = door_cells[0]
	var door_cell := Vector2i(base_x + int(primary_door_entry.get("x", 0)), base_z + int(primary_door_entry.get("z", 0)))
	var porch_cell := Vector2i(door_cell.x, door_cell.y + 1)
	var interior_landing_cell := Vector2i(door_cell.x, door_cell.y - 1)
	var home_cell := Vector2i(base_x + int(width / 2), base_z + int(depth / 2))
	var spawn_cell := Vector2i(home_cell.x, base_z - 9)
	var spawn_position := Vector3(float(spawn_cell.x) * CELL, level + 0.04, float(spawn_cell.y) * CELL)
	home_doors = find_home_doors(base_x, base_z, width, depth)
	add_result("fixture_house_built", home_doors.size() >= 2, "doors %d, base %d,%d" % [home_doors.size(), base_x, base_z])
	if home_doors.is_empty():
		return

	npc_body = spawn_visual_test_npc(spawn_position, {
		"id": "visual-go-home-npc-01",
		"name": generated_npc_name(),
		"role": "Civilian",
		"townKey": "visual-go-home-fixture",
		"townCenter": center,
		"townRadius": 24,
		"level": level,
		"homeCell": home_cell,
		"porchCell": porch_cell,
		"doorCell": door_cell,
		"interiorLandingCell": interior_landing_cell,
		"interiorMinCell": Vector2i(base_x + 1, base_z + 1),
		"interiorMaxCell": Vector2i(base_x + width - 2, base_z + depth - 2),
		"guardCell": porch_cell,
		"canFight": false,
		"nightGuard": false,
		"job": ""
	})
	if npc_body == null:
		add_result("fixture_npc_spawned", false, "spawn failed")
		return
	npc_entry = npc_system.call("npc_entry_for_actor", npc_body)
	npc_entry["requiredVisibleScripted"] = true
	npc_entry["visibleScriptedSequence"] = true
	npc_body.set_meta("npc_required_visible_sequence", true)
	var spawn_distance := flat_distance(spawn_position, Vector3(float(home_cell.x) * CELL, level, float(home_cell.y) * CELL))
	fixture = {
		"centerCell": cell_dict(center),
		"baseCell": cell_dict(Vector2i(base_x, base_z)),
		"homeCell": cell_dict(home_cell),
		"doorCell": cell_dict(door_cell),
		"interiorLandingCell": cell_dict(interior_landing_cell),
		"interiorMinCell": cell_dict(Vector2i(base_x + 1, base_z + 1)),
		"interiorMaxCell": cell_dict(Vector2i(base_x + width - 2, base_z + depth - 2)),
		"porchCell": cell_dict(porch_cell),
		"spawnCell": cell_dict(spawn_cell),
		"spawnDistanceMeters": snapped_float(spawn_distance),
		"spawnBehindHome": spawn_cell.y < base_z,
		"doorCount": home_doors.size(),
		"level": snapped_float(level)
	}
	add_result(
		"fixture_npc_spawned_reasonable_distance_behind_home",
		spawn_distance >= CELL * 7.0 and spawn_cell.y < base_z,
		"distance %.2fm, spawn %s, home %s" % [spawn_distance, JSON.stringify(cell_dict(spawn_cell)), JSON.stringify(cell_dict(home_cell))]
	)
	initial_stats = sanitize_value(npc_system.stats())
	door_opens_before = int(initial_stats.get("doorOpens", 0))
	door_closes_before = int(initial_stats.get("doorCloses", 0))

func run_scripted_sequence(npc1: ScriptedNpcHandle) -> Dictionary:
	npc1.say("Thanks for all your help. I should probably get home and recover now.")
	return npc1.go_home()

func spawn_visual_test_npc(position: Vector3, profile: Dictionary) -> CharacterBody3D:
	var body := npc_system.call("create_npc_body", "VisualGoHomeNPC", "npc") as CharacterBody3D
	if body == null:
		return null
	var visual_factory = npc_system.get("visual_factory")
	if visual_factory != null:
		npc_system.call("add_npc_visual", body, visual_factory.body_material(11), visual_factory.accent_material(7), String(profile.get("name", "NPC")), String(profile.get("role", "Civilian")), false)
	npc_system.call("add_npc_collider", body)
	var npc_root := npc_system.get("npc_root") as Node3D
	if npc_root != null:
		npc_root.add_child(body)
	else:
		npc_system.add_child(body)
	npc_system.call("safe_place_npc", body, position, null, "visual_go_home_spawn")
	npc_system.call("register_npc", body, profile)
	return body

func observe_go_home() -> void:
	var max_frames := ceili(OBSERVATION_SECONDS * float(Engine.physics_ticks_per_second))
	for frame in range(max_frames):
		await get_tree().physics_frame
		var sample := make_sample(frame)
		if frame % 12 == 0:
			timeline.append(sample)
			write_progress("observe_%04d" % frame)
		var door_distance := float(sample.get("distanceToDoor", 9999.0))
		var inside := bool(sample.get("insideHome", false))
		var door_open := bool(sample.get("doorOpen", false))
		if not saw_at_door and door_distance <= CELL * 1.85:
			saw_at_door = true
			if not captured_at_door:
				await capture_stage("at_home_door", "front")
				captured_at_door = true
		if not saw_door_open and door_open:
			saw_door_open = true
			if not captured_open:
				await capture_stage("door_open", "front")
				captured_open = true
		if not saw_inside and inside:
			saw_inside = true
		if saw_door_open and inside and not door_open and int(sample.get("doorClosesDelta", 0)) > 0:
			saw_inside_closed = true
			if not captured_inside_closed:
				await capture_stage("inside_closed_door", "inside")
				captured_inside_closed = true
			break
	final_stats = sanitize_value(npc_system.stats())
	add_result("npc_walked_to_home_door", saw_at_door, "min observed door distance %.2fm" % min_timeline_distance("distanceToDoor"))
	add_result("npc_opened_home_door", saw_door_open and int(final_stats.get("doorOpens", 0)) > door_opens_before, "door opens %d -> %d" % [door_opens_before, int(final_stats.get("doorOpens", 0))])
	var final_strict := strict_home_status()
	add_result("npc_entered_home_interior", saw_inside and bool(final_strict.get("strictInside", false)), "strict %s, meta %s" % [JSON.stringify(final_strict), str(npc_body.get_meta("npc_inside_home", false))])
	add_result("npc_closed_home_door_after_entry", saw_inside_closed and int(final_stats.get("doorCloses", 0)) > door_closes_before and not any_home_door_open(), "door closes %d -> %d, open=%s" % [door_closes_before, int(final_stats.get("doorCloses", 0)), str(any_home_door_open())])
	add_result("visual_screenshots_saved", required_captures_saved(), "captures %s" % JSON.stringify(capture_names()))
	if not saw_inside_closed:
		await capture_stage("timeout_final_state", "front")

func make_sample(frame: int) -> Dictionary:
	var npc_position := npc_body.global_position if npc_body != null and is_instance_valid(npc_body) else Vector3.ZERO
	var door_position := average_door_position()
	var strict := strict_home_status()
	var stats_now: Dictionary = npc_system.stats() if npc_system != null else {}
	var sample := {
		"frame": frame,
		"elapsed": snapped_float(elapsed),
		"npcPosition": vec3(npc_position),
		"npcCell": cell_dict(flat_cell(npc_position)),
		"distanceToDoor": snapped_float(flat_distance(npc_position, door_position)),
		"distanceToHome": snapped_float(flat_distance(npc_position, home_position())),
		"doorOpen": any_home_door_open(),
		"insideHome": bool(strict.get("strictInside", false)),
		"insideHomeMeta": bool(npc_body.get_meta("npc_inside_home", false)) if npc_body != null and is_instance_valid(npc_body) else false,
		"strictHome": strict,
		"routeStatus": String(npc_entry.get("routeStatus", "")),
		"routeReason": String(npc_entry.get("routeReason", "")),
		"routeActionsCount": (npc_entry.get("routeActions", {}) as Dictionary).size() if npc_entry.get("routeActions", {}) is Dictionary else 0,
		"routeActionKeys": route_action_keys(),
		"homeRouteIndex": int(npc_entry.get("homeRouteIndex", 0)),
		"homeActiveTargetCell": cell_dict(npc_entry.get("homeActiveTargetCell", Vector2i(999999, 999999))),
		"routeGoalCell": cell_dict(npc_entry.get("routeGoalCell", Vector2i(999999, 999999))),
		"routeFallbackCell": cell_dict(npc_entry.get("routeFallbackCell", Vector2i(999999, 999999))),
		"lastRoutePlanDebug": sanitize_value(npc_entry.get("lastRoutePlanDebug", {})),
		"scriptedState": String(npc_body.get_meta("npc_scripted_order_state", "")) if npc_body != null and is_instance_valid(npc_body) else "",
		"activeDoorPortalId": String(npc_entry.get("activeDoorPortalId", "")),
		"doorOpensDelta": int(stats_now.get("doorOpens", 0)) - door_opens_before,
		"doorClosesDelta": int(stats_now.get("doorCloses", 0)) - door_closes_before
	}
	return sample

func route_action_keys() -> Array[String]:
	var keys: Array[String] = []
	if npc_entry.get("routeActions", {}) is Dictionary:
		for key in (npc_entry.get("routeActions", {}) as Dictionary).keys():
			keys.append(String(key))
	keys.sort()
	return keys

func capture_stage(stage: String, camera_mode: String) -> void:
	position_observer_camera(camera_mode)
	await wait_process_frames(3)
	var image := get_viewport().get_texture().get_image()
	var path := screenshot_dir.path_join("%s.png" % stage)
	var err := image.save_png(path)
	var sample := make_sample(-1)
	captures.append({
		"stage": stage,
		"path": path,
		"saved": err == OK,
		"cameraMode": camera_mode,
		"sample": sample
	})
	add_result("capture_%s_saved" % stage, err == OK, path)

func await_capture_timeout() -> void:
	await capture_stage("watchdog_timeout", "front")

func position_observer_camera(mode: String) -> void:
	if observer_camera == null:
		return
	var home_pos := home_position()
	var door_pos := average_door_position()
	var npc_pos := npc_body.global_position if npc_body != null and is_instance_valid(npc_body) else home_pos
	var level := float(fixture.get("level", home_pos.y))
	var camera_position := Vector3.ZERO
	var target := home_pos
	if mode == "spawn":
		target = (npc_pos + home_pos) * 0.5 + Vector3(0.0, CELL * 1.0, 0.0)
		camera_position = npc_pos + Vector3(-CELL * 6.0, CELL * 5.3, -CELL * 8.0)
	elif mode == "inside":
		target = npc_pos + Vector3(0.0, CELL * 0.85, 0.0)
		camera_position = home_pos + Vector3(CELL * 1.8, CELL * 1.55, CELL * 1.7)
	else:
		target = door_pos + Vector3(0.0, CELL * 0.85, 0.0)
		camera_position = door_pos + Vector3(0.0, CELL * 3.2, CELL * 8.5)
	camera_position.y = maxf(camera_position.y, level + CELL * 1.2)
	observer_camera.global_position = camera_position
	observer_camera.look_at(target, Vector3.UP)
	observer_camera.make_current()

func find_dry_fixture_center() -> Vector2i:
	var candidates := [
		Vector2i(180, -180),
		Vector2i(220, -160),
		Vector2i(-180, 220),
		Vector2i(260, 180),
		Vector2i(-220, -180)
	]
	for candidate in candidates:
		var height := float(main.call("surface_y_at_cell", Vector3i(candidate.x, 0, candidate.y)))
		if height > WATER_LEVEL + 2.5:
			return candidate
	return Vector2i(180, -180)

func flatten_fixture(center: Vector2i, level: float, radius: int) -> void:
	var edits: Dictionary = main.get("volume_edit_markers")
	for z in range(center.y - radius, center.y + radius + 1):
		for x in range(center.x - radius, center.x + radius + 1):
			edits[Vector2i(x, z)] = level
	for offset in [Vector2i.ZERO, Vector2i(radius, 0), Vector2i(-radius, 0), Vector2i(0, radius), Vector2i(0, -radius)]:
		if main.has_method("rebuild_chunks_around_cell"):
			main.call("rebuild_chunks_around_cell", center + offset)

func clear_blocks_near_cell(center: Vector2i, radius: int) -> void:
	var blocks: Dictionary = main.get("blocks")
	for key in blocks.keys():
		var cell: Vector3i = key
		if abs(cell.x - center.x) > radius or abs(cell.z - center.y) > radius:
			continue
		var body := blocks[key] as Node
		if body != null:
			body.queue_free()
		blocks.erase(key)

func clear_props_near_cell(center: Vector2i, radius: int) -> void:
	for root_value in [main.get("chunk_root"), main.get("prop_root")]:
		clear_props_recursive(root_value as Node, center, radius)

func clear_props_recursive(node: Node, center: Vector2i, radius: int) -> void:
	if node == null:
		return
	for child in node.get_children():
		if child is Node3D and String(child.get_meta("kind", "")) == "prop":
			var child3d := child as Node3D
			var cell := flat_cell(child3d.global_position)
			if abs(cell.x - center.x) <= radius and abs(cell.y - center.y) <= radius:
				child.queue_free()
				continue
		clear_props_recursive(child, center, radius)

func remove_extra_fixture_utilities(center: Vector2i, radius: int) -> void:
	var blocks: Dictionary = main.get("blocks")
	for key in blocks.keys():
		var cell: Vector3i = key
		if abs(cell.x - center.x) > radius or abs(cell.z - center.y) > radius:
			continue
		var body := blocks[key] as Node
		if body == null:
			continue
		if String(body.get_meta("block_type", "")) in ["chest", "bed"]:
			body.queue_free()
			blocks.erase(key)

func find_home_doors(base_x: int, base_z: int, width: int, depth: int) -> Array[Node]:
	var doors: Array[Node] = []
	var blocks: Dictionary = main.get("blocks")
	for block_value in blocks.values():
		var block := block_value as Node
		if block == null:
			continue
		if String(block.get_meta("block_type", "")) != "door":
			continue
		var cell: Vector3i = block.get_meta("cell", Vector3i.ZERO)
		if cell.x >= base_x and cell.x < base_x + width and cell.z >= base_z and cell.z < base_z + depth:
			doors.append(block)
	doors.sort_custom(func(a: Node, b: Node) -> bool:
		var ca: Vector3i = a.get_meta("cell", Vector3i.ZERO)
		var cb: Vector3i = b.get_meta("cell", Vector3i.ZERO)
		if ca.x == cb.x:
			return ca.z < cb.z
		return ca.x < cb.x
	)
	return doors

func move_player_for_lod(center: Vector2i, level: float) -> void:
	if player == null:
		return
	player.global_position = Vector3(float(center.x - 10) * CELL, level + 0.15, float(center.y - 12) * CELL)
	player.velocity = Vector3.ZERO

func any_home_door_open() -> bool:
	for door in home_doors:
		if door != null and is_instance_valid(door) and bool(door.get_meta("open", false)):
			return true
	return false

func strict_home_status() -> Dictionary:
	if npc_entry.is_empty():
		return { "strictInside": false, "reason": "entry_missing" }
	if npc_body == null or not is_instance_valid(npc_body):
		return { "strictInside": false, "reason": "body_missing" }
	return HomeInteriorServiceScript.status(npc_entry, npc_body.global_position, home_door_portal())

func home_door_portal():
	if npc_system == null:
		return null
	var autonomy = npc_system.get("autonomy_system")
	if autonomy == null or autonomy.get("door_portals") == null:
		return null
	return HomeInteriorServiceScript.portal_for_entry(npc_entry, autonomy.get("door_portals"))

func average_door_position() -> Vector3:
	if home_doors.is_empty():
		return home_position()
	var sum := Vector3.ZERO
	var count := 0
	for door in home_doors:
		if door != null and is_instance_valid(door) and door is Node3D:
			sum += (door as Node3D).global_position
			count += 1
	if count <= 0:
		return home_position()
	return sum / float(count)

func home_position() -> Vector3:
	var cell_data: Dictionary = fixture.get("homeCell", {}) if fixture.get("homeCell", {}) is Dictionary else {}
	if cell_data.is_empty():
		return Vector3.ZERO
	return Vector3(float(cell_data.get("x", 0)) * CELL, float(fixture.get("level", 0.0)) + 0.04, float(cell_data.get("z", 0)) * CELL)

func flat_cell(position: Vector3) -> Vector2i:
	return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))

func flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

func min_timeline_distance(key: String) -> float:
	var best := 999999.0
	for sample in timeline:
		best = minf(best, float(sample.get(key, 999999.0)))
	return best

func required_captures_saved() -> bool:
	var required := ["spawn_behind_home", "at_home_door", "door_open", "inside_closed_door"]
	var saved := {}
	for capture in captures:
		if bool(capture.get("saved", false)):
			saved[String(capture.get("stage", ""))] = true
	for stage in required:
		if not bool(saved.get(stage, false)):
			return false
	return true

func capture_names() -> Array[String]:
	var names: Array[String] = []
	for capture in captures:
		names.append(String(capture.get("stage", "")))
	return names

func add_result(name: String, passed: bool, details := "") -> void:
	results.append({
		"name": name,
		"passed": passed,
		"details": details
	})
	if not passed:
		failed = true
	print("[%s] %s %s" % ["PASS" if passed else "FAIL", name, details])
	write_report(false)

func finish(exit_code: int) -> void:
	if finished:
		return
	finished = true
	final_stats = sanitize_value(npc_system.stats()) if npc_system != null else final_stats
	write_report(true)
	write_progress("finished")
	get_tree().quit(exit_code)

func write_report(verbose := true) -> void:
	var failure_count := 0
	for result in results:
		if not bool(result.get("passed", false)):
			failure_count += 1
	var report := {
		"schemaVersion": 1,
		"testId": TEST_ID,
		"seed": seed,
		"runToken": run_token,
		"nonHeadlessRequired": true,
		"finished": finished,
		"passed": failure_count == 0,
		"failureCount": failure_count,
		"resultCount": results.size(),
		"results": results,
		"fixture": fixture,
		"script": {
			"codeShape": "npc1.say(...); npc1.go_home()",
			"lines": script_lines
		},
		"initialStats": initial_stats,
		"finalStats": final_stats,
		"captures": captures,
		"timeline": timeline,
		"timelineTail": timeline.slice(maxi(0, timeline.size() - 24), timeline.size())
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write go-home visual report: %s" % report_path)
		return
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	if verbose:
		print("NPC go-home visual report: %s" % report_path)

func write_progress(label: String) -> void:
	if progress_path == "":
		return
	var file := FileAccess.open(progress_path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string("%s\nelapsed=%.3f\nresults=%d\nfailed=%s\n" % [label, elapsed, results.size(), str(failed)])
	file.close()

func wait_physics_frames(count: int) -> void:
	for i in range(count):
		await get_tree().physics_frame

func wait_process_frames(count: int) -> void:
	for i in range(count):
		await get_tree().process_frame

func ensure_dir(path: String) -> void:
	if path == "":
		return
	var err := DirAccess.make_dir_recursive_absolute(path)
	if err != OK and err != ERR_ALREADY_EXISTS:
		push_error("Could not create directory %s: %s" % [path, str(err)])

func generated_npc_name() -> String:
	var names := ["Ari", "Bryn", "Cato", "Dara", "Eli", "Fia", "Nia", "Oren"]
	var rng := RandomNumberGenerator.new()
	rng.seed = abs(hash("%s:go-home-visual-npc" % seed))
	return names[rng.randi_range(0, names.size() - 1)]

func cell_dict(cell: Vector2i) -> Dictionary:
	return { "x": cell.x, "z": cell.y }

func vec3(value: Vector3) -> Dictionary:
	return { "x": snapped_float(value.x), "y": snapped_float(value.y), "z": snapped_float(value.z) }

func snapped_float(value: float) -> float:
	return snappedf(value, 0.001)

func sanitize_value(value):
	if value is Vector3:
		return vec3(value)
	if value is Vector2i:
		return cell_dict(value)
	if value is Vector3i:
		var cell: Vector3i = value
		return { "x": cell.x, "y": cell.y, "z": cell.z }
	if value is Dictionary:
		var result := {}
		for key in value.keys():
			result[String(key)] = sanitize_value(value[key])
		return result
	if value is Array:
		var result_array := []
		for item in value:
			result_array.append(sanitize_value(item))
		return result_array
	return value
