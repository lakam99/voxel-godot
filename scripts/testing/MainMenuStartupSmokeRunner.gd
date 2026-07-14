extends SceneTree

const MAIN_MENU_SCENE: PackedScene = preload("res://scenes/MainMenu.tscn")

var report_path := ""
var steps: Array[String] = []
var errors: Array[String] = []
var launch_mode := "new_game"

func _init() -> void:
	call_deferred("run")

func run() -> void:
	launch_mode = OS.get_environment("VOXEL_MAIN_MENU_STARTUP_SMOKE_MODE").strip_edges().to_lower()
	if launch_mode == "":
		launch_mode = "new_game"
	if launch_mode not in ["new_game", "continue"]:
		errors.append("unsupported startup smoke mode: %s" % launch_mode)
		write_report(false, {"launchMode": launch_mode})
		quit(1)
		return
	var real_save_mode := OS.get_environment("VOXEL_MAIN_MENU_STARTUP_REAL_SAVE_MODE").strip_edges() == "1"
	if real_save_mode:
		OS.unset_environment("VOXEL_PLAYTEST")
		OS.unset_environment("VOXEL_TEST_SEED")
	else:
		OS.set_environment("VOXEL_PLAYTEST", "1")
		if OS.get_environment("VOXEL_TEST_SEED").strip_edges() == "":
			OS.set_environment("VOXEL_TEST_SEED", "menu-startup-smoke")
	report_path = OS.get_environment("VOXEL_MAIN_MENU_STARTUP_SMOKE_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/main-menu-startup-smoke-report.json")
	record_step("start")
	var menu := MAIN_MENU_SCENE.instantiate()
	if menu == null:
		errors.append("could not instantiate main menu")
		write_report(false, {})
		quit(1)
		return
	root.add_child(menu)
	record_step("menu_added")
	await process_frame
	if not menu.has_method("launch_game"):
		errors.append("main menu has no launch_game method")
		write_report(false, {})
		quit(1)
		return
	menu.call("launch_game", launch_mode)
	record_step("launch_requested")
	var started_msec := Time.get_ticks_msec()
	var main = null
	while Time.get_ticks_msec() - started_msec < 240000:
		await process_frame
		main = find_child_by_name(menu, "Main")
		if main != null and main.get("startup_loading_failure_result") is Dictionary \
			and not (main.get("startup_loading_failure_result") as Dictionary).is_empty():
			break
		if main != null and not bool(main.get("startup_loading_active")) and menu.get("ui_layer") == null:
			break
	var details := collect_details(menu, main, started_msec)
	if main == null:
		errors.append("main scene was not added")
	elif main.get("startup_loading_failure_result") is Dictionary \
		and not (main.get("startup_loading_failure_result") as Dictionary).is_empty():
		errors.append("main startup failed: %s" % String((main.get("startup_loading_failure_result") as Dictionary).get("reason", "unknown")))
	elif bool(main.get("startup_loading_active")):
		errors.append("main startup did not complete")
	elif menu.get("ui_layer") != null:
		errors.append("menu ui was not released after startup")
	else:
		validate_readiness(main)
	if errors.is_empty() and OS.get_environment("VOXEL_MAIN_MENU_STARTUP_MOVEMENT_AUDIT").strip_edges() == "1":
		await exercise_saved_player_movement(main, details)
	if errors.is_empty() and OS.get_environment("VOXEL_MAIN_MENU_STARTUP_RUNTIME_RESET").strip_edges() == "1":
		await exercise_runtime_new_game(main, details)
	if errors.is_empty() and OS.get_environment("VOXEL_MAIN_MENU_STARTUP_PERSIST_SAVE").strip_edges() == "1":
		persist_save_fixture(main, details)
	write_report(errors.is_empty(), details)
	if main != null and main.has_method("request_graceful_quit"):
		main.call("request_graceful_quit", 0 if errors.is_empty() else 1)
		return
	await cleanup_loaded_game(menu, main)
	quit(0 if errors.is_empty() else 1)

func find_child_by_name(node: Node, child_name: String):
	if node == null:
		return null
	for child in node.get_children():
		if child.name == child_name:
			return child
	return null

func collect_details(menu: Node, main, started_msec: int) -> Dictionary:
	var details := {
		"elapsedMs": Time.get_ticks_msec() - started_msec,
		"launchMode": launch_mode,
		"menuLaunching": bool(menu.get("launching")) if menu != null else false,
		"menuUiReleased": menu != null and menu.get("ui_layer") == null,
		"mainExists": main != null
	}
	if main != null:
		details["startupLoadingActive"] = bool(main.get("startup_loading_active"))
		details["startupFailure"] = (main.get("startup_loading_failure_result") as Dictionary).duplicate(true) if main.get("startup_loading_failure_result") is Dictionary else {}
		var timeline_value = main.get("startup_loading_timeline")
		details["startupTimeline"] = (timeline_value as Array).duplicate(true) if timeline_value is Array else []
		details["startupReadinessDomains"] = (main.get("startup_readiness_domains") as Dictionary).duplicate(true) if main.get("startup_readiness_domains") is Dictionary else {}
		details["startupMaxStep"] = (main.get("startup_loading_max_step") as Dictionary).duplicate(true) if main.get("startup_loading_max_step") is Dictionary else {}
		details["seed"] = String(main.get("seed_text"))
		var chunks_value = main.get("chunks")
		details["chunks"] = (chunks_value as Dictionary).size() if chunks_value is Dictionary else 0
		details["hudReady"] = main.get("hud") != null
		var player = main.get("player") as Node
		details["playerPhysicsEnabled"] = player != null and player.is_physics_processing()
		var npc_physics := []
		var npc_system = main.get("npc_system")
		if npc_system != null and npc_system.get("npcs") is Array:
			for entry_value in (npc_system.get("npcs") as Array):
				if entry_value is Dictionary:
					var entry: Dictionary = entry_value
					var body := entry.get("body") as Node
					npc_physics.append({
						"id": String(entry.get("id", "")),
						"enabled": body != null and is_instance_valid(body) and body.is_physics_processing()
					})
		details["npcPhysics"] = npc_physics
		var tutorial = main.get("tutorial_system")
		details["tutorialStartupResult"] = (tutorial.get("startup_readiness_result") as Dictionary).duplicate(true) if tutorial != null and tutorial.get("startup_readiness_result") is Dictionary else {}
	return details

func validate_readiness(main) -> void:
	var domains: Dictionary = main.get("startup_readiness_domains") if main.get("startup_readiness_domains") is Dictionary else {}
	for domain in ["tutorial_scenario", "town_manifest", "town_doors", "npc_registration", "terrain_collision", "navigation_changes", "navigation_tiles", "navigation_map", "gameplay"]:
		var row: Dictionary = domains.get(domain, {}) if domains.get(domain, {}) is Dictionary else {}
		if String(row.get("status", "")) != "ready":
			errors.append("startup readiness domain was not ready: %s" % domain)
	if launch_mode == "continue":
		var restore_row: Dictionary = domains.get("save_restore", {}) if domains.get("save_restore", {}) is Dictionary else {}
		if String(restore_row.get("status", "")) != "ready":
			errors.append("Continue save_restore domain was not ready")
	var manifest_row: Dictionary = domains.get("town_manifest", {}) if domains.get("town_manifest", {}) is Dictionary else {}
	var manifest_metrics: Dictionary = manifest_row.get("metrics", {}) if manifest_row.get("metrics", {}) is Dictionary else {}
	if int(manifest_metrics.get("pendingOpCount", -1)) != 0:
		errors.append("town manifest completed with pending structure operations")
	var gameplay_row: Dictionary = domains.get("gameplay", {}) if domains.get("gameplay", {}) is Dictionary else {}
	var gameplay_metrics: Dictionary = gameplay_row.get("metrics", {}) if gameplay_row.get("metrics", {}) is Dictionary else {}
	if bool(gameplay_metrics.get("playerPhysicsEnabled", true)) or bool(gameplay_metrics.get("npcPhysicsEnabled", true)):
		errors.append("gameplay readiness was recorded after physics enabled")
	var player = main.get("player") as Node
	if player == null or not player.is_physics_processing():
		errors.append("player physics was not enabled after startup completion")
	var npc_system = main.get("npc_system")
	var registered_count := 0
	if npc_system != null and npc_system.get("npcs") is Array:
		for entry_value in (npc_system.get("npcs") as Array):
			if not (entry_value is Dictionary):
				continue
			var body := (entry_value as Dictionary).get("body") as Node
			if body == null or not is_instance_valid(body) or not body.is_physics_processing():
				errors.append("registered NPC physics was not enabled after startup completion")
				break
			registered_count += 1
	if registered_count <= 0:
		errors.append("no NPCs were registered at startup completion")
	var tutorial = main.get("tutorial_system")
	var tutorial_result: Dictionary = tutorial.get("startup_readiness_result") if tutorial != null and tutorial.get("startup_readiness_result") is Dictionary else {}
	if String(tutorial_result.get("status", "")) != "ready":
		errors.append("tutorial system did not retain a ready startup result")
	var tutorial_metrics: Dictionary = tutorial_result.get("metrics", {}) if tutorial_result.get("metrics", {}) is Dictionary else {}
	if String(tutorial_metrics.get("mode", "")) != launch_mode:
		errors.append("tutorial startup mode mismatch: expected %s" % launch_mode)

func persist_save_fixture(main, details: Dictionary) -> void:
	if main == null or main.get("save_system") == null or not main.has_method("create_save_snapshot"):
		errors.append("could not persist Continue fixture")
		details["fixtureSaved"] = false
		return
	var snapshot: Dictionary = main.call("create_save_snapshot")
	var saved := bool(main.get("save_system").call("save", String(main.get("seed_text")), snapshot))
	details["fixtureSaved"] = saved
	details["fixtureSeed"] = String(main.get("seed_text"))
	if not saved:
		errors.append("Continue fixture save failed")


func exercise_saved_player_movement(main, details: Dictionary) -> void:
	var player: CharacterBody3D = main.get("player") as CharacterBody3D if main != null else null
	var runtime: Node = main.get("voxel_terrain_runtime") as Node if main != null else null
	if player == null or runtime == null:
		errors.append("VOX-115 movement audit could not find player or voxel runtime")
		return
	main.set("autosave_enabled", false)
	var initial_position: Vector3 = player.global_position
	var initial_hold_frames := int(player.get("terrain_collision_hold_frames"))
	var strict_support_proof: Dictionary = runtime.call("collision_proof_for_world_position", initial_position, 0.42) \
		if runtime.has_method("collision_proof_for_world_position") else {}
	var initial_motion_proofs: Array = []
	var directions: Array[Vector3] = [Vector3.RIGHT, Vector3.FORWARD, Vector3.LEFT, Vector3.BACK]
	for direction in directions:
		var target: Vector3 = initial_position + direction * 0.25
		var proof: Dictionary = main.call("terrain_collision_motion_proof", initial_position, target, 0.42)
		initial_motion_proofs.append({"direction": direction, "proof": proof})
	player.velocity = Vector3.ZERO
	player.set("automated_input", true)
	player.set("automated_sprint", false)
	player.set("automated_jump", true)
	var max_horizontal_displacement: float = 0.0
	var accumulated_horizontal_distance: float = 0.0
	var previous_position: Vector3 = initial_position
	var max_vertical_position: float = initial_position.y
	var min_vertical_position: float = initial_position.y
	var jump_observed := false
	var physics_frames := 0
	for index in range(360):
		var direction: Vector3 = directions[int(index / 90)]
		player.set("automated_move", direction)
		if index % 45 == 0:
			player.set("automated_jump", true)
		await physics_frame
		physics_frames += 1
		jump_observed = jump_observed or bool(player.get("jumped_this_frame"))
		var current: Vector3 = player.global_position
		var from_start: Vector3 = current - initial_position
		from_start.y = 0.0
		max_horizontal_displacement = maxf(max_horizontal_displacement, from_start.length())
		var step: Vector3 = current - previous_position
		step.y = 0.0
		accumulated_horizontal_distance += step.length()
		previous_position = current
		max_vertical_position = maxf(max_vertical_position, current.y)
		min_vertical_position = minf(min_vertical_position, current.y)
		await process_frame
	player.set("automated_move", Vector3.ZERO)
	player.set("automated_sprint", false)
	player.set("automated_jump", false)
	player.set("automated_input", false)
	var hold_frame_delta := int(player.get("terrain_collision_hold_frames")) - initial_hold_frames
	var audit := {
		"initialPosition": initial_position,
		"finalPosition": player.global_position,
		"physicsFrames": physics_frames,
		"terrainCollisionHoldFrameDelta": hold_frame_delta,
		"maxHorizontalDisplacement": max_horizontal_displacement,
		"accumulatedHorizontalDistance": accumulated_horizontal_distance,
		"maxVerticalRise": max_vertical_position - initial_position.y,
		"maxVerticalDrop": initial_position.y - min_vertical_position,
		"jumpObserved": jump_observed,
		"strictSupportProof": strict_support_proof,
		"initialMotionProofs": initial_motion_proofs,
		"lastMotionProof": (player.get("last_terrain_collision_proof") as Dictionary).duplicate(true) \
			if player.get("last_terrain_collision_proof") is Dictionary else {},
		"startupCollisionProof": (player.get_meta("startup_terrain_collision_proof", {}) as Dictionary).duplicate(true) \
			if player.get_meta("startup_terrain_collision_proof", {}) is Dictionary else {},
		"runtimeStats": runtime.call("stats") if runtime.has_method("stats") else {}
	}
	details["vox115MovementAudit"] = audit
	if hold_frame_delta != 0:
		errors.append("VOX-115 movement audit entered the terrain collision hold for %d frames" % hold_frame_delta)
	if max_horizontal_displacement < 0.5:
		errors.append("VOX-115 movement audit remained horizontally immobilized (%.3f m)" % max_horizontal_displacement)
	if not jump_observed:
		errors.append("VOX-115 movement audit never executed a jump")

func exercise_runtime_new_game(main, details: Dictionary) -> void:
	var started_msec := Time.get_ticks_msec()
	var runtime_before = main.get("voxel_terrain_runtime")
	var runtime_instance_before: int = runtime_before.get_instance_id() if runtime_before is Node and is_instance_valid(runtime_before) else 0
	var terrain_before = runtime_before.get("terrain") if runtime_before != null else null
	var terrain_instance_before: int = terrain_before.get_instance_id() if terrain_before is Node and is_instance_valid(terrain_before) else 0
	var runtime_stats_before: Dictionary = runtime_before.call("stats") if runtime_before != null and runtime_before.has_method("stats") else {}
	main.call("start_new_game_staged", false)
	var timeout_seconds := maxf(180.0, OS.get_environment("VOXEL_MAIN_MENU_STARTUP_RUNTIME_RESET_TIMEOUT_SECONDS").to_float())
	if OS.get_environment("VOXEL_MAIN_MENU_STARTUP_RUNTIME_RESET_TIMEOUT_SECONDS").strip_edges() == "":
		timeout_seconds = 300.0
	while bool(main.get("runtime_loading_active")) and float(Time.get_ticks_msec() - started_msec) / 1000.0 < timeout_seconds:
		await process_frame
	var failure: Dictionary = main.get("startup_loading_failure_result") if main.get("startup_loading_failure_result") is Dictionary else {}
	var domains: Dictionary = main.get("startup_readiness_domains") if main.get("startup_readiness_domains") is Dictionary else {}
	var runtime_after = main.get("voxel_terrain_runtime")
	var runtime_instance_after: int = runtime_after.get_instance_id() if runtime_after is Node and is_instance_valid(runtime_after) else 0
	var terrain_after = runtime_after.get("terrain") if runtime_after != null else null
	var terrain_instance_after: int = terrain_after.get_instance_id() if terrain_after is Node and is_instance_valid(terrain_after) else 0
	details["runtimeReset"] = {
		"elapsedMs": Time.get_ticks_msec() - started_msec,
		"loadingActive": bool(main.get("runtime_loading_active")),
		"failure": failure.duplicate(true),
		"readinessDomains": domains.duplicate(true),
		"maxStep": (main.get("startup_loading_max_step") as Dictionary).duplicate(true) if main.get("startup_loading_max_step") is Dictionary else {},
		"runtimeInstanceBefore": runtime_instance_before,
		"runtimeInstanceAfter": runtime_instance_after,
		"terrainInstanceBefore": terrain_instance_before,
		"terrainInstanceAfter": terrain_instance_after,
		"runtimeInstancePreserved": runtime_instance_before != 0 and runtime_instance_before == runtime_instance_after,
		"terrainInstancePreserved": terrain_instance_before != 0 and terrain_instance_before == terrain_instance_after,
		"timeoutSeconds": timeout_seconds,
		"runtimeStatsBefore": runtime_stats_before
	}
	if bool(main.get("runtime_loading_active")):
		errors.append("runtime New Game readiness did not complete")
	elif not failure.is_empty():
		errors.append("runtime New Game readiness failed: %s" % String(failure.get("reason", "unknown")))
	elif runtime_instance_before == 0 or runtime_instance_before != runtime_instance_after:
		errors.append("runtime New Game replaced the terrain runtime instead of resetting it in place")
	elif terrain_instance_before == 0 or terrain_instance_before != terrain_instance_after:
		errors.append("runtime New Game replaced the native terrain node instead of resetting its generator")
	else:
		validate_readiness(main)

func record_step(label: String) -> void:
	steps.append(label)

func cleanup_loaded_game(menu: Node, main) -> void:
	if main != null:
		main.set_process(false)
		main.set_physics_process(false)
		var player = main.get("player")
		if player != null and player is Node:
			(player as Node).set_physics_process(false)
		var audio_effects = main.get("audio_effects")
		if audio_effects != null and audio_effects is Node:
			(audio_effects as Node).queue_free()
		var terrain_meshing_service = main.get("terrain_meshing_service")
		if terrain_meshing_service != null and terrain_meshing_service.has_method("clear_jobs"):
			terrain_meshing_service.call("clear_jobs", true)
	if menu != null:
		if menu.get_parent() != null:
			menu.get_parent().remove_child(menu)
		menu.free()
	for i in range(4):
		await process_frame

func write_report(passed: bool, details: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var runtime_reset_mode := OS.get_environment("VOXEL_MAIN_MENU_STARTUP_RUNTIME_RESET").strip_edges() == "1"
	var movement_audit_mode := OS.get_environment("VOXEL_MAIN_MENU_STARTUP_MOVEMENT_AUDIT").strip_edges() == "1"
	var runner_id := "main_menu_continue_startup_smoke" if launch_mode == "continue" else "main_menu_startup_smoke"
	var test_id := "vox_73_main_menu_continue_readiness_smoke" if launch_mode == "continue" else "vox_73_main_menu_startup_readiness_smoke"
	if runtime_reset_mode:
		runner_id = "main_menu_runtime_reset_smoke"
		test_id = "vox_73_main_menu_runtime_reset_readiness_smoke"
	if movement_audit_mode:
		runner_id = "vox_115_mountain_save_continue_movement_audit"
		test_id = "vox_115_affected_save_continue_and_player_movement"
	var report := {
		"schemaVersion": 1,
		"runnerId": runner_id,
		"testId": test_id,
		"finished": true,
		"passed": passed,
		"evidenceLevel": "integration" if movement_audit_mode else "scene-load-smoke",
		"scope": "Main Menu -> %s startup readiness%s%s through the production scene with an isolated save mode. %s" % [
			"Continue" if launch_mode == "continue" else "New Game",
			" plus an in-session New Game reset" if runtime_reset_mode else "",
			" plus saved-pose movement/jump auditing" if movement_audit_mode else "",
			"The VOX-115 audit uses the real saved player pose and physics without teleporting during the act phase." if movement_audit_mode else "This is scene-load evidence, not unflagged live gameplay acceptance."
		],
		"status": "passed" if passed else "failed",
		"steps": steps,
		"errors": errors,
		"details": details
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
