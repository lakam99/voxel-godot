extends SceneTree

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const MAIN_MENU_SCENE: PackedScene = preload("res://scenes/MainMenu.tscn")
const PLAYTEST_RUNNER_SCRIPT := preload("res://scripts/PlaytestRunner.gd")

var report_path := ""

func _init() -> void:
	call_deferred("run")

func run() -> void:
	report_path = OS.get_environment("VOXEL_PROJECT_COMPILE_REPORT").strip_edges()
	if report_path == "":
		report_path = ProjectSettings.globalize_path("res://artifacts/project-compile-smoke-report.json")
	var report := {
		"schemaVersion": 1,
		"runnerId": "project_compile_smoke",
		"evidenceLevel": "compile-smoke",
		"status": "passed" if MAIN_SCENE != null and MAIN_MENU_SCENE != null \
			and PLAYTEST_RUNNER_SCRIPT != null else "failed",
		"mainSceneLoaded": MAIN_SCENE != null,
		"mainMenuSceneLoaded": MAIN_MENU_SCENE != null,
		"playtestRunnerScriptLoaded": PLAYTEST_RUNNER_SCRIPT != null
	}
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var file := FileAccess.open(report_path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	quit(0 if MAIN_SCENE != null and MAIN_MENU_SCENE != null \
		and PLAYTEST_RUNNER_SCRIPT != null else 1)
