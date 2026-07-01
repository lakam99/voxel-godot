extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const TEST_ID := "cave_visual_playtest"
const CELL := 1.35
const CAPTURE_WIDTH := 1280
const CAPTURE_HEIGHT := 720
const REQUIRED_CAPTURE_STAGES := [
    "cave_entrance",
    "cave_branch_fork",
    "cave_dead_end_chamber",
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
    add_result("cave_visual_graph_has_branches", cave_graph_has_branches(), JSON.stringify(cave_graph_summary()))
    add_result("cave_visual_interior_shell_generated", cave_interior_shell_generated(), JSON.stringify(cave_vertical_summary()))
    add_result("cave_visual_final_chest_has_book", final_chest_has_crafting_book(), JSON.stringify(final_chest_summary()))
    var prop_summary := cave_natural_props_inside_summary()
    add_result("cave_visual_no_natural_props_inside", int(prop_summary.get("count", 0)) == 0, JSON.stringify(prop_summary))

    await capture_stage("cave_entrance", "entrance")
    await capture_stage("cave_branch_fork", "fork")
    await capture_stage("cave_dead_end_chamber", "dead_end")
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
    camera.fov = 72.0
    add_child(camera)
    observer_light = OmniLight3D.new()
    observer_light.name = "CaveVisualPlaytestLight"
    observer_light.light_energy = 2.6
    observer_light.omni_range = CELL * 8.0
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
    var chamber: Vector2i = plan.get("finalChamberCell", entrance)
    var chest: Vector2i = plan.get("finalChestCell", chamber)
    var path_length := int(plan.get("pathLength", 0))
    var final_id := String(plan.get("finalChamberId", "final"))
    var fork_id := first_string(plan.get("branchChamberIds", []), "fork")
    var dead_end_id := first_string(plan.get("deadEndChamberIds", []), "side_dead_end")
    var camera_pos := Vector3.ZERO
    var target := Vector3.ZERO
    if mode == "entrance":
        camera_pos = terrain_world_for_cell(entrance - inward * 2, 1.15)
        target = cave_world_for_cell(entrance + inward * 4, 1.35)
    elif mode == "fork":
        var fork_cell := cave_node_cell(fork_id, entrance + inward * maxi(4, int(path_length * 0.45)))
        camera_pos = cave_world_for_cell(camera_cell_near_node(fork_id, fork_cell - inward * 3), 1.55)
        target = cave_world_for_cell(fork_cell, 1.30)
    elif mode == "dead_end":
        var dead_cell := cave_node_cell(dead_end_id, entrance + inward * maxi(5, int(path_length * 0.5)))
        camera_pos = cave_world_for_cell(camera_cell_near_node(dead_end_id, dead_cell - inward * 3), 1.55)
        target = cave_world_for_cell(dead_cell, 1.20)
    elif mode == "tunnel":
        camera_pos = cave_world_for_cell(edge_mid_cell("fork_to_mid", path_center_cell(mini(6, maxi(1, path_length - 4)))), 1.55)
        target = cave_world_for_cell(edge_mid_cell("mid_to_final", path_center_cell(mini(13, maxi(2, path_length - 1)))), 1.35)
    else:
        camera_pos = cave_world_for_cell(camera_cell_near_node(final_id, path_center_cell(maxi(1, path_length - 2))), 1.55)
        target = cave_world_for_cell(chest, 1.15)
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
        "finalChest": final_chest_summary(),
        "graph": cave_graph_summary(),
        "vertical": cave_vertical_summary()
    }

func world_for_cell(cell: Vector2i, lift := 0.0) -> Vector3:
    return terrain_world_for_cell(cell, lift)

func terrain_world_for_cell(cell: Vector2i, lift := 0.0) -> Vector3:
    var x := float(cell.x) * CELL
    var z := float(cell.y) * CELL
    var y := float(plan.get("level", 0.0)) + lift
    if main != null and main.has_method("height_at_world"):
        y = float(main.call("height_at_world", x, z)) + lift
    return Vector3(x, y, z)

func cave_world_for_cell(cell: Vector2i, lift := 0.0) -> Vector3:
    return Vector3(float(cell.x) * CELL, float(plan.get("level", 0.0)) + lift, float(cell.y) * CELL)

func path_center_cell(depth: int) -> Vector2i:
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var inward: Vector2i = plan.get("inward", Vector2i(0, 1))
    var cells_value = plan.get("pathCells", [])
    if not (cells_value is Array):
        return entrance + inward * depth
    var sum_x := 0.0
    var sum_z := 0.0
    var count := 0
    for cell_value in cells_value:
        var cell: Vector2i = cell_value
        var delta := cell - entrance
        var cell_depth := delta.x * inward.x + delta.y * inward.y
        if cell_depth != depth:
            continue
        sum_x += float(cell.x)
        sum_z += float(cell.y)
        count += 1
    if count <= 0:
        return entrance + inward * depth
    return Vector2i(roundi(sum_x / float(count)), roundi(sum_z / float(count)))

func first_string(value, fallback: String) -> String:
    if value is Array and not (value as Array).is_empty():
        return String((value as Array)[0])
    return fallback

func cave_node_cell(node_id: String, fallback: Vector2i) -> Vector2i:
    var nodes_value = plan.get("caveNodes", [])
    if not (nodes_value is Array):
        return fallback
    for node_value in nodes_value:
        if not (node_value is Dictionary):
            continue
        var node: Dictionary = node_value
        if String(node.get("id", "")) == node_id:
            return node.get("cell", fallback)
    return fallback

func camera_cell_near_node(node_id: String, fallback: Vector2i) -> Vector2i:
    var edges_value = plan.get("caveEdges", [])
    if not (edges_value is Array):
        return fallback
    for edge_value in edges_value:
        if not (edge_value is Dictionary):
            continue
        var edge: Dictionary = edge_value
        var center_cells = edge.get("centerCells", [])
        if not (center_cells is Array) or (center_cells as Array).is_empty():
            continue
        var cells: Array = center_cells
        if String(edge.get("to", "")) == node_id:
            return cells[maxi(0, cells.size() - 4)]
        if String(edge.get("from", "")) == node_id:
            return cells[mini(cells.size() - 1, 3)]
    return fallback

func edge_mid_cell(edge_id: String, fallback: Vector2i) -> Vector2i:
    var edges_value = plan.get("caveEdges", [])
    if not (edges_value is Array):
        return fallback
    for edge_value in edges_value:
        if not (edge_value is Dictionary):
            continue
        var edge: Dictionary = edge_value
        if String(edge.get("id", "")) != edge_id:
            continue
        var center_cells = edge.get("centerCells", [])
        if not (center_cells is Array) or (center_cells as Array).is_empty():
            return fallback
        var cells: Array = center_cells
        return cells[int(cells.size() / 2)]
    return fallback

func cave_graph_has_branches() -> bool:
    var summary := cave_graph_summary()
    return int(summary.get("nodeCount", 0)) >= 5 \
        and int(summary.get("edgeCount", 0)) >= 5 \
        and int(summary.get("branchCount", 0)) >= 1 \
        and int(summary.get("deadEndCount", 0)) >= 1

func cave_graph_summary() -> Dictionary:
    var nodes: Array = plan.get("caveNodes", [])
    var edges: Array = plan.get("caveEdges", [])
    var roles := []
    for node_value in nodes:
        if node_value is Dictionary:
            roles.append(String((node_value as Dictionary).get("kind", "")))
    return {
        "nodeCount": nodes.size(),
        "edgeCount": edges.size(),
        "branchCount": array_size(plan.get("branchChamberIds", [])),
        "deadEndCount": array_size(plan.get("deadEndChamberIds", [])),
        "roles": roles
    }

func array_size(value) -> int:
    return value.size() if value is Array else 0

func cave_vertical_summary() -> Dictionary:
    var floor_level := float(plan.get("level", 0.0))
    var ceiling_level := float(plan.get("ceilingLevel", floor_level))
    var surface_level := float(plan.get("surfaceLevel", ceiling_level))
    return {
        "surfaceLevel": rounded(surface_level),
        "floorLevel": rounded(floor_level),
        "ceilingLevel": rounded(ceiling_level),
        "ceilingClearance": rounded(ceiling_level - floor_level),
        "earthCover": rounded(surface_level - ceiling_level),
        "interiorShells": cave_interior_shell_count()
    }

func cave_interior_shell_generated() -> bool:
    var vertical := cave_vertical_summary()
    return int(vertical.get("interiorShells", 0)) >= 1 \
        and float(vertical.get("ceilingClearance", 0.0)) >= CELL * 2.0 \
        and float(vertical.get("earthCover", 0.0)) > 0.0

func cave_interior_shell_count() -> int:
    if structure_system == null:
        return 0
    var nodes_value = structure_system.get("cave_interior_nodes")
    if not (nodes_value is Dictionary):
        return 0
    var nodes: Dictionary = nodes_value
    var cave_id := String(plan.get("id", ""))
    var count := 0
    for node_value in nodes.values():
        var node := node_value as Node
        if node != null and is_instance_valid(node) and String(node.get_meta("caveId", "")) == cave_id:
            count += 1
    return count

func cave_natural_props_inside_summary() -> Dictionary:
    if main == null or structure_system == null:
        return { "count": 0, "samples": [] }
    var cells_value = structure_system.call("cave_shaping_cells", plan) if structure_system.has_method("cave_shaping_cells") else []
    var lookup := {}
    if cells_value is Array:
        for cell_value in cells_value:
            if cell_value is Vector2i:
                lookup[cell_value] = true
    var samples := []
    var count := 0
    for root_value in [main.get("chunk_root"), main.get("prop_root")]:
        var root_node := root_value as Node
        if root_node == null:
            continue
        var summary := cave_natural_props_inside_node(root_node, lookup, samples)
        count += int(summary.get("count", 0))
    return {
        "count": count,
        "samples": samples
    }

func cave_natural_props_inside_node(node: Node, lookup: Dictionary, samples: Array) -> Dictionary:
    var count := 0
    if String(node.get_meta("kind", "")) == "prop" and node is Node3D:
        var node3d := node as Node3D
        var cell := Vector2i(world_to_cell_value(node3d.global_position.x), world_to_cell_value(node3d.global_position.z))
        if lookup.has(cell):
            count += 1
            if samples.size() < 8:
                samples.append({
                    "name": node.name,
                    "cell": vec2i(cell),
                    "material": String(node.get_meta("material", "")),
                    "propId": String(node.get_meta("prop_id", ""))
                })
    for child in node.get_children():
        var child_summary := cave_natural_props_inside_node(child, lookup, samples)
        count += int(child_summary.get("count", 0))
    return { "count": count }

func world_to_cell_value(value: float) -> int:
    if main != null and main.has_method("world_to_cell"):
        return int(main.call("world_to_cell", value))
    return roundi(value / CELL)

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
        "acceptanceClaims": ["procedural_cave_graph_entrance_branch_dead_end_final_visual"],
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
        "nodeCount": array_size(plan_value.get("caveNodes", [])),
        "edgeCount": array_size(plan_value.get("caveEdges", [])),
        "branchCount": array_size(plan_value.get("branchChamberIds", [])),
        "deadEndCount": array_size(plan_value.get("deadEndChamberIds", [])),
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
