extends SceneTree

const MAIN_MENU_SCENE: PackedScene = preload("res://scenes/MainMenu.tscn")

var report_path := ""
var steps: Array[String] = []
var errors: Array[String] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
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
	menu.call("launch_game", "new_game")
	record_step("launch_requested")
	var started_msec := Time.get_ticks_msec()
	var main = null
	while Time.get_ticks_msec() - started_msec < 240000:
		await process_frame
		main = find_child_by_name(menu, "Main")
		if main != null and not bool(main.get("startup_loading_active")) and menu.get("ui_layer") == null:
			break
	var details := collect_details(menu, main, started_msec)
	if main == null:
		errors.append("main scene was not added")
	elif bool(main.get("startup_loading_active")):
		errors.append("main startup did not complete")
	elif menu.get("ui_layer") != null:
		errors.append("menu ui was not released after startup")
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
		"menuLaunching": bool(menu.get("launching")) if menu != null else false,
		"menuUiReleased": menu != null and menu.get("ui_layer") == null,
		"mainExists": main != null
	}
	if main != null:
		details["startupLoadingActive"] = bool(main.get("startup_loading_active"))
		var timeline_value = main.get("startup_loading_timeline")
		details["startupTimeline"] = (timeline_value as Array).duplicate(true) if timeline_value is Array else []
		details["seed"] = String(main.get("seed_text"))
		var chunks_value = main.get("chunks")
		details["chunks"] = (chunks_value as Dictionary).size() if chunks_value is Dictionary else 0
		details["hudReady"] = main.get("hud") != null
	return details

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
	var report := {
		"schemaVersion": 1,
		"runnerId": "main_menu_startup_smoke",
		"evidenceLevel": "scene-load-smoke",
		"status": "passed" if passed else "failed",
		"steps": steps,
		"errors": errors,
		"details": details
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
