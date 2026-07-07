extends SceneTree

const PLAYTEST_SCENE_PATH := "res://scenes/Playtest.tscn"

var report_path := ""
var steps: Array[String] = []
var errors: Array[String] = []

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_PLAYTEST_SCENE_SMOKE_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/playtest-scene-smoke-report.json")
	record_step("start")
	var packed := ResourceLoader.load(PLAYTEST_SCENE_PATH)
	record_step("resource_load")
	if packed == null or not (packed is PackedScene):
		errors.append("could not load %s" % PLAYTEST_SCENE_PATH)
		write_report(false)
		quit(1)
		return
	var instance := (packed as PackedScene).instantiate()
	record_step("instantiate")
	if instance == null:
		errors.append("could not instantiate %s" % PLAYTEST_SCENE_PATH)
		write_report(false)
		quit(1)
		return
	root.add_child(instance)
	record_step("tree_added")
	await process_frame
	await physics_frame
	record_step("first_frames")
	if instance.has_method("mark_progress"):
		record_step("runner_script_ready")
	write_report(errors.is_empty())
	quit(0 if errors.is_empty() else 1)

func record_step(label: String) -> void:
	steps.append(label)

func write_report(passed: bool) -> void:
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var report := {
		"schemaVersion": 1,
		"runnerId": "playtest_scene_smoke",
		"evidenceLevel": "scene-load-smoke",
		"scenePath": PLAYTEST_SCENE_PATH,
		"status": "passed" if passed else "failed",
		"steps": steps,
		"errors": errors
	}
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
