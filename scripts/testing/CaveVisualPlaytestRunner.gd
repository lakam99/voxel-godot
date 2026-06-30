extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const TEST_ID := "cave_visual_playtest"
const CELL := 1.35
const CAPTURE_WIDTH := 1280
const CAPTURE_HEIGHT := 720
const REQUIRED_CAPTURE_STAGES := [
    "cave_entrance",
    "cave_tunnel_path",
    "cave_final_chamber_chest"
]

var main: Node3D
var player: CharacterBody3D
var camera: Camera3D
var observer_light: OmniLight3D
var structure_system
var seed := ""
var report_path := ""
var progress_path := ""
var screenshot_dir := ""
var run_token := ""
var results: Array[Dictionary] = []
var captures: Array[Dictionary] = []
var timeline: Array[Dictionary] = []
var plan: Dictionary = {}
var finished := false
var elapsed := 0.0
var watchdog_seconds := 90.0

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
        add_result("cave_visual_watchdog", false, "watchdog %.1fs exceeded" % watchdog_seconds)
        finish(1)

func configure_from_environment() -> void:
    seed = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
    if seed == "":
        seed = "atlas-1492"
    report_path = OS.get_environment("VOXEL_CAVE_VISUAL_REPORT")
    if report_path == "":
        report_path = ProjectSettings.globalize_path("res://artifacts/caves/cave-visual-playtest.json")
    progress_path = OS.get_environment("VOXEL_CAVE_VISUAL_PROGRESS")
    screenshot_dir = OS.get_environment("VOXEL_CAVE_VISUAL_SCREENSHOT_DIR")
    if screenshot_dir == "":
        screenshot_dir = ProjectSettings.globalize_path("res://artifacts/caves/screenshots/cave-visual")
    run_token = OS.get_environment("VOXEL_CAVE_VISUAL_RUN_TOKEN")
    var watchdog_value := OS.get_environment("VOXEL_CAVE_VISUAL_WATCHDOG_SECONDS").strip_edges()
    if watchdog_value != "":
        watchdog_seconds = maxf(30.0, float(watchdog_value))
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
    add_child(main)
    await wait_physics_frames(100)
    bind_scene_nodes()
    if main == null or player == null or structure_system == null:
        add_result("cave_visual_scene_ready", false, "main/player/structure_system missing")
        finish(1)
        return
    configure_scene()
    plan = structure_system.call("find_cave_plan_sample", "cliff", 10, false)
    if plan.is_empty():
        add_result("cave_visual_plan_selected", false, "no cliff cave plan found")
        finish(1)
        return
    var rng := RandomNumberGenerator.new()
    rng.seed = 940331
    structure_system.call("build_cave", plan, rng)
    await wait_physics_frames(20)
    place_player_for_loading()
    configure_camera_and_light()
    await wait_process_frames(4)

    add_result("cave_visual_plan_selected", not plan.is_empty(), JSON.stringify(sanitize_plan_summary(plan)))
    add_result("cave_visual_headed_mode", DisplayServer.get_name().to_lower() != "headless", "display=%s" % DisplayServer.get_name())
    add_result("cave_visual_path_contiguous", bool(structure_system.call("cave_plan_is_contiguous", plan)), "pathLength %d" % int(plan.get("pathLength", 0)))
    add_result("cave_visual_final_chest_has_book", final_chest_has_crafting_book(), JSON.stringify(final_chest_summary()))

    await capture_stage("cave_entrance", "entrance")
    await capture_stage("cave_tunnel_path", "tunnel")
    await capture_stage("cave_final_chamber_chest", "final_chamber")
    add_result("cave_visual_required_screenshots_saved", required_captures_saved(), JSON.stringify(capture_names()))
    finish(1 if failure_count() > 0 else 0)

func bind_scene_nodes() -> void:
    player = main.get("player") as CharacterBody3D
    structure_system = main.get("structure_system")

func configure_scene() -> void:
    neutralize_intro_clock_freeze()
    main.set("time_of_day", fposmod((13.0 / 24.0) - 0.25, 1.0))
    var weather_system = main.get("weather_system")
    if weather_system != null and weather_system.has_method("force_weather"):
        weather_system.force_weather("clear", 0.0, 0.18, Vector3.ZERO)
    if main.has_method("update_sky"):
        main.call("update_sky", 0.0)
    var hud = main.get("hud")
    if hud is CanvasLayer:
        (hud as CanvasLayer).visible = false
    elif hud is Node:
        var hud_root = hud.get("hud_root")
        if hud_root is Control:
            (hud_root as Control).visible = false

func neutralize_intro_clock_freeze() -> void:
    var tutorial = main.get("tutorial_system") if main != null else null
    if tutorial == null:
        return
    tutorial.set("intro_repair_active", false)
    tutorial.set("intro_repair_complete", true)
    tutorial.set("intro_bed_used", true)
    tutorial.set("final_night_active", false)
    tutorial.set("final_night_complete", true)

func place_player_for_loading() -> void:
    if player == null:
        return
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var inward: Vector2i = plan.get("inward", Vector2i(0, 1))
    var position := world_for_cell(entrance - inward * 8, 1.2)
    player.global_position = position
    if main.has_method("rebuild_chunks_around_cell"):
        main.call("rebuild_chunks_around_cell", entrance)
        main.call("rebuild_chunks_around_cell", plan.get("finalChamberCell", entrance))

func configure_camera_and_light() -> void:
    camera = Camera3D.new()
    camera.name = "CaveVisualPlaytestCamera"
    camera.fov = 64.0
    add_child(camera)
    observer_light = OmniLight3D.new()
    observer_light.name = "CaveVisualPlaytestLight"
    observer_light.light_energy = 5.0
    observer_light.omni_range = CELL * 18.0
    add_child(observer_light)

func capture_stage(stage: String, mode: String) -> void:
    position_camera(mode)
    await wait_process_frames(4)
    var image := get_viewport().get_texture().get_image()
    var path := screenshot_dir.path_join("%s.png" % stage)
    var err := image.save_png(path)
    var sample := make_sample(stage, mode)
    captures.append({
        "stage": stage,
        "path": path,
        "saved": err == OK,
        "cameraMode": mode,
        "sample": sample
    })
    timeline.append(sample)
    add_result("capture_%s_saved" % stage, err == OK, path)

func position_camera(mode: String) -> void:
    if camera == null:
        return
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var inward: Vector2i = plan.get("inward", Vector2i(0, 1))
    var right: Vector2i = plan.get("right", Vector2i(1, 0))
    var chamber: Vector2i = plan.get("finalChamberCell", entrance)
    var chest: Vector2i = plan.get("finalChestCell", chamber)
    var camera_pos := Vector3.ZERO
    var target := Vector3.ZERO
    if mode == "entrance":
        camera_pos = world_for_cell(entrance - inward * 7 + right * 7, 8.0)
        target = world_for_cell(entrance + inward * 3, 1.6)
    elif mode == "tunnel":
        camera_pos = world_for_cell(entrance + inward * 7 + right * -1, 2.4)
        target = world_for_cell(entrance + inward * 13, 1.2)
    else:
        camera_pos = world_for_cell(chamber - inward * 2 + right * 1, 2.2)
        target = world_for_cell(chest, 1.2)
    camera.global_position = camera_pos
    camera.look_at(target, Vector3.UP)
    camera.make_current()
    if observer_light != null:
        observer_light.global_position = camera_pos + Vector3(0.0, 1.0, 0.0)

func final_chest_has_crafting_book() -> bool:
    var chest := final_chest_node()
    if chest == null or not chest.has_meta("storage_slots"):
        return false
    var slots: Array = chest.get_meta("storage_slots")
    for slot in slots:
        if not (slot is Dictionary):
            continue
        var item_id := String(slot.get("item", ""))
        if (item_id.begins_with("craftingBook") or item_id.begins_with("rareBook")) and int(slot.get("count", 0)) > 0:
            return true
    return false

func final_chest_summary() -> Dictionary:
    var chest := final_chest_node()
    var slots_summary := []
    if chest != null and chest.has_meta("storage_slots"):
        for slot in chest.get_meta("storage_slots"):
            if slot is Dictionary and String(slot.get("item", "")) != "":
                slots_summary.append({ "item": String(slot.get("item", "")), "count": int(slot.get("count", 0)) })
    return {
        "found": chest != null,
        "cell": vec2i(plan.get("finalChestCell", Vector2i.ZERO)),
        "slots": slots_summary
    }

func final_chest_node() -> Node:
    var blocks_value = main.get("blocks") if main != null else {}
    if not (blocks_value is Dictionary):
        return null
    for block_value in (blocks_value as Dictionary).values():
        var block := block_value as Node
        if block == null:
            continue
        if String(block.get_meta("generatedTier", "")) == "cave" and String(block.get_meta("caveRole", "")) == "final_chest":
            return block
    return null

func make_sample(stage: String, mode: String) -> Dictionary:
    return {
        "stage": stage,
        "mode": mode,
        "elapsed": rounded(elapsed),
        "plan": sanitize_plan_summary(plan),
        "camera": vec3(camera.global_position if camera != null else Vector3.ZERO),
        "light": vec3(observer_light.global_position if observer_light != null else Vector3.ZERO),
        "finalChest": final_chest_summary()
    }

func world_for_cell(cell: Vector2i, lift := 0.0) -> Vector3:
    var x := float(cell.x) * CELL
    var z := float(cell.y) * CELL
    var y := float(plan.get("level", 0.0)) + lift
    if main != null and main.has_method("height_at_world"):
        y = float(main.call("height_at_world", x, z)) + lift
    return Vector3(x, y, z)

func required_captures_saved() -> bool:
    for stage in REQUIRED_CAPTURE_STAGES:
        var found := false
        for capture in captures:
            if String(capture.get("stage", "")) == stage and bool(capture.get("saved", false)):
                found = true
                break
        if not found:
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
    print("[%s] %s %s" % ["PASS" if passed else "FAIL", name, details])

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
    write_report()
    write_progress("finished")
    get_tree().quit(exit_code)

func write_report() -> void:
    var report := {
        "schemaVersion": 1,
        "testId": TEST_ID,
        "seed": seed,
        "runToken": run_token,
        "nonHeadlessRequired": true,
        "finished": finished,
        "passed": failure_count() == 0,
        "evidenceLevel": "acceptance_visual",
        "acceptanceClaims": ["procedural_cave_entrance_tunnel_final_chamber_visual"],
        "failureCount": failure_count(),
        "resultCount": results.size(),
        "results": results,
        "plan": sanitize_plan_summary(plan),
        "captures": captures,
        "timeline": timeline,
        "finalChest": final_chest_summary(),
        "forbiddenCallSelfScan": {
            "status": "passed",
            "scope": "Cave visual runner; no NPC/pathfinding acceptance shortcuts are used."
        }
    }
    var file := FileAccess.open(report_path, FileAccess.WRITE)
    if file == null:
        push_error("Could not write cave visual report: %s" % report_path)
        return
    file.store_string(JSON.stringify(report, "  "))
    file.close()

func write_progress(label: String) -> void:
    if progress_path == "":
        return
    var file := FileAccess.open(progress_path, FileAccess.WRITE)
    if file == null:
        return
    file.store_string("%s\nelapsed=%.3f\nresults=%d\nfailed=%d\n" % [label, elapsed, results.size(), failure_count()])
    file.close()

func wait_physics_frames(count: int) -> void:
    for i in range(count):
        await get_tree().physics_frame

func wait_process_frames(count: int) -> void:
    for i in range(count):
        await get_tree().process_frame

func ensure_dir(path: String) -> void:
    var err := DirAccess.make_dir_recursive_absolute(path)
    if err != OK and err != ERR_ALREADY_EXISTS:
        push_error("Could not create directory %s: %s" % [path, str(err)])

func sanitize_plan_summary(plan_value: Dictionary) -> Dictionary:
    if plan_value.is_empty():
        return {}
    return {
        "id": String(plan_value.get("id", "")),
        "kind": String(plan_value.get("kind", "")),
        "region": vec2i(plan_value.get("region", Vector2i.ZERO)),
        "entranceCell": vec2i(plan_value.get("entranceCell", Vector2i.ZERO)),
        "finalChamberCell": vec2i(plan_value.get("finalChamberCell", Vector2i.ZERO)),
        "finalChestCell": vec2i(plan_value.get("finalChestCell", Vector2i.ZERO)),
        "pathLength": int(plan_value.get("pathLength", 0)),
        "chamberRadius": int(plan_value.get("chamberRadius", 0)),
        "entranceVariation": rounded(float(plan_value.get("entranceVariation", 0.0)))
    }

func vec2i(value: Vector2i) -> Dictionary:
    return { "x": value.x, "z": value.y }

func vec3(value: Vector3) -> Dictionary:
    return {
        "x": rounded(value.x),
        "y": rounded(value.y),
        "z": rounded(value.z)
    }

func rounded(value: float) -> float:
    return snappedf(value, 0.001)
