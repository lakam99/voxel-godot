extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")

const SCRIPT_PATHS := [
    "res://scripts/Main.gd",
    "res://scripts/MainCore.gd",
    "res://scripts/MainSaveState.gd",
    "res://scripts/SaveSystem.gd",
    "res://scripts/TutorialSystem.gd",
    "res://scripts/TutorialDialogueSystem.gd",
    "res://scripts/TutorialRepairQuest.gd",
    "res://scripts/TutorialRescueSystem.gd",
    "res://scripts/MainWorldEntities.gd",
    "res://scripts/ObjectiveSystem.gd",
    "res://scripts/ContractSystem.gd",
    "res://scripts/NpcSystem.gd",
    "res://scripts/HostileSystem.gd",
    "res://scripts/WeatherSystem.gd",
    "res://scripts/GameHud.gd",
    "res://scripts/visual/VisualAssetRegistry.gd",
    "res://scripts/visual/CharacterAssetRegistry.gd",
    "res://scripts/visual/StaticItemAssetRegistry.gd",
    "res://scripts/visual/AnimatedAssetRegistry.gd"
]

var main: Node3D
var results: Array[Dictionary] = []
var failed := false
var finished := false
var elapsed := 0.0

func _ready() -> void:
    call_deferred("run")

func _process(delta: float) -> void:
    if finished:
        return
    elapsed += delta
    if elapsed > 16.0:
        add_result("story_runner_watchdog", false, "runner timed out before completion")
        finish()

func run() -> void:
    mark_progress("start")
    add_result("story_runner_bootstraps", true, "StoryPlaytestRunner ready")
    test_project_scripts_load()
    await test_main_scene_instantiates()
    test_story_artifacts_directory_writable()
    add_result("story_runner_exit_code_policy", true, "runner exits 0 on success and 1 on failure")
    finish()

func test_project_scripts_load() -> void:
    var failures: Array[String] = []
    for path in SCRIPT_PATHS:
        if not ResourceLoader.exists(path):
            failures.append("%s missing" % path)
            continue
        var resource := load(path)
        if resource == null:
            failures.append("%s failed to load" % path)
    add_result(
        "project_scripts_load",
        failures.is_empty(),
        "%d scripts checked%s" % [SCRIPT_PATHS.size(), "" if failures.is_empty() else ": " + "; ".join(failures)]
    )

func test_main_scene_instantiates() -> void:
    var story_test_mode := OS.get_environment("VOXEL_STORY_PLAYTEST") == "1"
    main = MAIN_SCENE.instantiate()
    add_child(main)
    await wait_physics_frames(24)
    var player = main.get("player") as CharacterBody3D
    if player:
        player.set("automated_input", true)
    var required_systems := [
        "save_system",
        "inventory_system",
        "crafting_system",
        "objective_system",
        "contract_system",
        "tutorial_system",
        "npc_system",
        "hostile_system",
        "weather_system",
        "hud",
        "visual_asset_registry",
        "static_item_asset_registry",
        "animated_asset_registry"
    ]
    var missing: Array[String] = []
    for key in required_systems:
        if main.get(key) == null:
            missing.append(key)
    add_result(
        "main_scene_story_test_mode_instantiates",
        story_test_mode and main != null and player != null and missing.is_empty(),
        "story mode %s, player %s, missing %s" % [str(story_test_mode), str(player != null), str(missing)]
    )

func test_story_artifacts_directory_writable() -> void:
    var artifact_path := ProjectSettings.globalize_path("res://artifacts/story/latest/story-playtest-artifact.json")
    ensure_dir_for_file(artifact_path)
    var payload := {
        "schemaVersion": 1,
        "runner": "StoryPlaytestRunner",
        "resultsBeforeWrite": results.size()
    }
    var file := FileAccess.open(artifact_path, FileAccess.WRITE)
    var write_ok := file != null
    if file != null:
        file.store_string(JSON.stringify(payload, "  "))
        file.close()
    var read_back := ""
    if FileAccess.file_exists(artifact_path):
        var read_file := FileAccess.open(artifact_path, FileAccess.READ)
        if read_file != null:
            read_back = read_file.get_as_text()
            read_file.close()
    add_result(
        "story_artifacts_directory_writable",
        write_ok and read_back.find("StoryPlaytestRunner") >= 0,
        artifact_path
    )

func wait_physics_frames(count: int) -> void:
    for i in range(count):
        await get_tree().physics_frame

func add_result(name: String, passed: bool, details: String = "") -> void:
    results.append({
        "name": name,
        "passed": passed,
        "details": details
    })
    if not passed:
        failed = true
    print("[%s] %s %s" % ["PASS" if passed else "FAIL", name, details])
    save_report()

func mark_progress(label: String) -> void:
    var path := OS.get_environment("VOXEL_STORY_PLAYTEST_PROGRESS")
    if path == "":
        return
    ensure_dir_for_file(path)
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        return
    file.store_string("%s\nelapsed=%.3f\nresults=%d\nfailed=%s\n" % [label, elapsed, results.size(), str(failed)])
    file.close()

func finish() -> void:
    if finished:
        return
    finished = true
    mark_progress("finished")
    save_report()
    get_tree().quit(1 if failed else 0)

func save_report() -> void:
    var report_path := OS.get_environment("VOXEL_STORY_PLAYTEST_REPORT")
    if report_path == "":
        report_path = "user://story-playtest-report.json"
    ensure_dir_for_file(report_path)
    var report := {
        "passed": not failed,
        "results": results
    }
    var file := FileAccess.open(report_path, FileAccess.WRITE)
    if file == null:
        push_error("Could not write story playtest report: %s" % report_path)
        return
    file.store_string(JSON.stringify(report, "  "))
    file.close()

func ensure_dir_for_file(path: String) -> void:
    var directory := path.get_base_dir()
    if directory == "":
        return
    if path.begins_with("user://") or path.begins_with("res://"):
        DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
    else:
        DirAccess.make_dir_recursive_absolute(directory)
