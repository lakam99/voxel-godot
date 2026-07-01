extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const TEST_ID := "cave_visual_playtest"
const CELL := 1.35
const CAPTURE_WIDTH := 1280
const CAPTURE_HEIGHT := 720
const REQUIRED_CAPTURE_STAGES := [
    "cave_dark_default",
    "cave_outside_profile",
    "cave_mouth_approach",
    "cave_first_tunnel",
    "cave_mid_route_branch",
    "cave_dead_end_chamber",
    "cave_final_chamber_chest"
]

var main: Node3D
var player: CharacterBody3D
var camera: Camera3D
var gameplay_camera: Camera3D
var observer_light: OmniLight3D
var last_camera_target := Vector3.ZERO
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
    plan = structure_system.call("find_cave_plan_sample", "underground", 10, false)
    if plan.is_empty():
        add_result("cave_visual_plan_selected", false, "no underground cave plan found")
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
    var route_summary := cave_graph_route_metrics()
    add_result("cave_visual_final_chest_not_near_entrance", cave_route_metrics_passed(route_summary), JSON.stringify(route_summary))
    var terrain_summary := cave_terrain_mouth_summary()
    add_result("cave_visual_mouth_terrain_localized", cave_mouth_terrain_passed(terrain_summary), JSON.stringify(terrain_summary))
    var mouth_access_summary := cave_mouth_access_summary()
    add_result("cave_visual_mouth_ground_level_and_clear", cave_mouth_access_passed(mouth_access_summary), JSON.stringify(mouth_access_summary))
    var negative_y_summary := cave_negative_y_growth_summary()
    add_result("cave_visual_negative_y_underground_growth", cave_negative_y_growth_passed(negative_y_summary), JSON.stringify(negative_y_summary))
    add_result("cave_visual_interior_shell_generated", cave_interior_shell_generated(), JSON.stringify(cave_vertical_summary()))
    var floor_summary := cave_floor_variation_summary()
    add_result("cave_visual_floor_height_varies_jumpable", float(floor_summary.get("range", 0.0)) >= 0.35 and float(floor_summary.get("maxNeighborStep", 999.0)) <= CELL * 1.10, JSON.stringify(floor_summary))
    add_result("cave_visual_daylight_shadow_authoritative_on_cave_layer", cave_daylight_shadow_authoritative_on_cave_layer(), JSON.stringify(cave_layer_lighting_summary()))
    add_result("cave_visual_final_chest_has_book", final_chest_has_crafting_book(), JSON.stringify(final_chest_summary()))
    var torch_summary := cave_torch_mount_summary()
    add_result("cave_visual_torches_wall_mounted", int(torch_summary.get("torches", 0)) > 0 and int(torch_summary.get("wallMountedTorches", 0)) == int(torch_summary.get("torches", 0)), JSON.stringify(torch_summary))
    var prop_summary := cave_natural_props_inside_summary()
    add_result("cave_visual_no_natural_props_inside", int(prop_summary.get("count", 0)) == 0, JSON.stringify(prop_summary))

    await capture_stage("cave_dark_default", "first_tunnel", 0.0)
    await capture_stage("cave_outside_profile", "outside_profile")
    await capture_stage("cave_mouth_approach", "mouth_approach")
    await capture_stage("cave_first_tunnel", "first_tunnel")
    await capture_stage("cave_mid_route_branch", "mid_route_branch")
    await capture_stage("cave_dead_end_chamber", "dead_end")
    await capture_stage("cave_final_chamber_chest", "final_chamber")
    add_result("cave_visual_required_screenshots_saved", required_captures_saved(), JSON.stringify(capture_names()))
    finish(1 if failure_count() > 0 else 0)

func bind_scene_nodes() -> void:
    player = main.get("player") as CharacterBody3D
    if player != null:
        gameplay_camera = player.get("camera") as Camera3D
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
    if main != null and main.has_method("apply_runtime_setting"):
        main.call("apply_runtime_setting", "headBob", false, false)
    if gameplay_camera != null:
        gameplay_camera.current = false
    camera = Camera3D.new()
    camera.name = "CaveVisualPlaytestCamera"
    camera.fov = 72.0
    add_child(camera)
    observer_light = OmniLight3D.new()
    observer_light.name = "CaveVisualPlaytestLight"
    observer_light.light_energy = 2.2
    observer_light.omni_range = CELL * 8.0
    observer_light.light_cull_mask = 3
    add_child(observer_light)

func capture_stage(stage: String, mode: String, observer_energy := 2.6) -> void:
    if observer_light != null:
        observer_light.light_energy = observer_energy
    position_camera(mode)
    await wait_process_frames(4)
    var image := get_viewport().get_texture().get_image()
    var path := screenshot_dir.path_join("%s.png" % stage)
    var err := image.save_png(path)
    var luminance := image_luminance_summary(image)
    var sample := make_sample(stage, mode)
    sample["luminance"] = luminance
    if mode == "outside_profile" or mode == "mouth_approach":
        var sightline := camera_sightline_summary()
        sample["sightline"] = sightline
        add_result("cave_visual_%s_sightline_clear" % mode, bool(sightline.get("clear", false)), JSON.stringify(sightline))
    captures.append({
        "stage": stage,
        "path": path,
        "saved": err == OK,
        "cameraMode": mode,
        "observerLightEnergy": observer_energy,
        "sample": sample,
        "luminance": luminance
    })
    timeline.append(sample)
    add_result("capture_%s_saved" % stage, err == OK, path)
    if stage == "cave_dark_default":
        add_result("cave_visual_dark_default_without_observer_light", float(luminance.get("average", 1.0)) <= 0.24, JSON.stringify(luminance))

func position_camera(mode: String) -> void:
    if camera == null:
        return
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var inward: Vector2i = plan.get("inward", Vector2i(0, 1))
    var right: Vector2i = plan.get("right", Vector2i(1, 0))
    var chamber: Vector2i = plan.get("finalChamberCell", entrance)
    var chest: Vector2i = plan.get("finalChestCell", chamber)
    var path_length := int(plan.get("pathLength", 0))
    var final_id := String(plan.get("finalChamberId", "final"))
    var fork_id := first_string(plan.get("branchChamberIds", []), "fork")
    var dead_end_id := first_string(plan.get("deadEndChamberIds", []), "side_dead_end")
    var camera_pos := Vector3.ZERO
    var target := Vector3.ZERO
    if mode == "outside_profile":
        camera_pos = terrain_world_for_cell(entrance - inward * 14 + right * 2, 2.0)
        target = cave_world_for_cell(entrance + inward * 1, 1.35)
    elif mode == "mouth_approach":
        camera_pos = terrain_world_for_cell(entrance - inward * 5, 1.55)
        target = cave_world_for_cell(entrance + inward * 3, 1.35)
    elif mode == "first_tunnel":
        camera_pos = cave_world_for_cell(route_edge_cell(0, 0.54, entrance + inward * 5), 1.55)
        target = cave_world_for_cell(route_edge_cell(0, 0.92, entrance + inward * 9), 1.30)
    elif mode == "mid_route_branch":
        var fork_cell := cave_node_cell(fork_id, entrance + inward * maxi(4, int(path_length * 0.45)))
        camera_pos = cave_world_for_cell(camera_cell_near_node(fork_id, fork_cell - inward * 3), 1.55)
        target = cave_world_for_cell(fork_cell, 1.30)
    elif mode == "dead_end":
        var dead_cell := cave_node_cell(dead_end_id, entrance + inward * maxi(5, int(path_length * 0.5)))
        camera_pos = cave_world_for_cell(camera_cell_near_node(dead_end_id, dead_cell - inward * 3), 1.55)
        target = cave_world_for_cell(dead_cell, 1.20)
    else:
        camera_pos = cave_world_for_cell(camera_cell_near_node(final_id, route_edge_cell(maxi(0, main_route_edge_count() - 1), 0.35, path_center_cell(maxi(1, path_length - 2)))), 1.55)
        target = cave_world_for_cell(chest, 1.15)
    apply_player_pov(camera_pos, target)
    last_camera_target = target
    if observer_light != null:
        observer_light.global_position = camera_pos + Vector3(0.0, 1.0, 0.0)

func apply_player_pov(camera_pos: Vector3, target: Vector3) -> void:
    if player != null:
        var camera_offset := Vector3(0.0, 1.65, 0.0)
        if gameplay_camera != null:
            camera_offset = gameplay_camera.position
        player.global_position = camera_pos - camera_offset
        player.velocity = Vector3.ZERO
        var flat_target := Vector3(target.x, player.global_position.y, target.z)
        if player.global_position.distance_to(flat_target) > 0.1:
            player.look_at(flat_target, Vector3.UP)
    camera.global_position = camera_pos
    camera.look_at(target, Vector3.UP)
    camera.make_current()

func camera_sightline_summary() -> Dictionary:
    if camera == null:
        return { "clear": false, "reason": "missing camera" }
    var from := camera.global_position
    var to := last_camera_target
    var segment := to - from
    var length := segment.length()
    if length <= 0.01:
        return { "clear": false, "reason": "empty segment" }
    var query := PhysicsRayQueryParameters3D.create(from, to)
    query.collide_with_areas = false
    query.collide_with_bodies = true
    if player != null:
        query.exclude = [player.get_rid()]
    var world := get_viewport().world_3d
    if world == null:
        return { "clear": false, "reason": "missing world" }
    var hit: Dictionary = world.direct_space_state.intersect_ray(query)
    if hit.is_empty():
        return {
            "clear": true,
            "from": vec3(from),
            "to": vec3(to),
            "distance": rounded(length)
        }
    var position: Vector3 = hit.get("position", from)
    var collider = hit.get("collider", null)
    var collider_name := ""
    var collider_meta := {}
    if collider is Node:
        var node := collider as Node
        collider_name = node.name
        for key in node.get_meta_list():
            collider_meta[String(key)] = node.get_meta(key)
    elif collider != null:
        collider_name = str(collider)
    var hit_distance := from.distance_to(position)
    return {
        "clear": hit_distance >= length * 0.92,
        "from": vec3(from),
        "to": vec3(to),
        "distance": rounded(length),
        "hitDistance": rounded(hit_distance),
        "hitPosition": vec3(position),
        "collider": collider_name,
        "colliderMeta": collider_meta
    }

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
        "observerLightEnergy": rounded(observer_light.light_energy if observer_light != null else 0.0),
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
    var x := float(cell.x) * CELL
    var z := float(cell.y) * CELL
    var y := float(plan.get("level", 0.0)) + lift
    if structure_system != null:
        var builder = structure_system.get("cave_interior_builder")
        if builder != null and builder.has_method("floor_point"):
            var floor_value = builder.call("floor_point", plan, Vector2(x, z))
            if floor_value is Vector3:
                y = float((floor_value as Vector3).y) + lift
    return Vector3(x, y, z)

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

func main_route_ids() -> Array[String]:
    var result: Array[String] = ["entrance"]
    var ids_value = plan.get("mainRouteIds", [])
    if ids_value is Array:
        for id_value in ids_value:
            result.append(String(id_value))
    result.append(String(plan.get("finalChamberId", "final")))
    return result

func main_route_edge_count() -> int:
    return maxi(0, main_route_ids().size() - 1)

func route_edge_cell(edge_index: int, t: float, fallback: Vector2i) -> Vector2i:
    var ids := main_route_ids()
    if ids.size() < 2:
        return fallback
    var index := clampi(edge_index, 0, ids.size() - 2)
    return edge_cell_between(ids[index], ids[index + 1], t, fallback)

func edge_cell_between(from_id: String, to_id: String, t: float, fallback: Vector2i) -> Vector2i:
    var edges_value = plan.get("caveEdges", [])
    if not (edges_value is Array):
        return fallback
    for edge_value in edges_value:
        if not (edge_value is Dictionary):
            continue
        var edge: Dictionary = edge_value
        var edge_from := String(edge.get("from", ""))
        var edge_to := String(edge.get("to", ""))
        if not ((edge_from == from_id and edge_to == to_id) or (edge_from == to_id and edge_to == from_id)):
            continue
        var center_cells = edge.get("centerCells", [])
        if not (center_cells is Array) or (center_cells as Array).is_empty():
            return fallback
        var cells: Array = center_cells
        var index := clampi(roundi(clampf(t, 0.0, 1.0) * float(cells.size() - 1)), 0, cells.size() - 1)
        if edge_from == from_id:
            return cells[index]
        return cells[cells.size() - 1 - index]
    return fallback

func cave_graph_has_branches() -> bool:
    var summary := cave_graph_summary()
    return int(summary.get("nodeCount", 0)) >= 5 \
        and int(summary.get("edgeCount", 0)) >= 5 \
        and int(summary.get("branchCount", 0)) >= 1 \
        and int(summary.get("deadEndCount", 0)) >= 1 \
        and int(summary.get("narrowEdgeCount", 0)) >= 1

func cave_graph_summary() -> Dictionary:
    var nodes: Array = plan.get("caveNodes", [])
    var edges: Array = plan.get("caveEdges", [])
    var roles := []
    var min_edge_radius := INF
    var narrow_edge_count := 0
    for node_value in nodes:
        if node_value is Dictionary:
            roles.append(String((node_value as Dictionary).get("kind", "")))
    for edge_value in edges:
        if not (edge_value is Dictionary):
            continue
        var edge: Dictionary = edge_value
        var radius := float(edge.get("radius", 0.0))
        min_edge_radius = minf(min_edge_radius, radius)
        if radius <= 1.75:
            narrow_edge_count += 1
    return {
        "nodeCount": nodes.size(),
        "edgeCount": edges.size(),
        "branchCount": array_size(plan.get("branchChamberIds", [])),
        "deadEndCount": array_size(plan.get("deadEndChamberIds", [])),
        "caveTier": String(plan.get("caveTier", "normal")),
        "minEdgeRadius": rounded(0.0 if min_edge_radius == INF else min_edge_radius),
        "narrowEdgeCount": narrow_edge_count,
        "route": cave_graph_route_metrics(),
        "roles": roles
    }

func cave_graph_route_metrics() -> Dictionary:
    var edges: Array = plan.get("caveEdges", [])
    var graph := {}
    for edge_value in edges:
        if not (edge_value is Dictionary):
            continue
        var edge: Dictionary = edge_value
        var from_id := String(edge.get("from", ""))
        var to_id := String(edge.get("to", ""))
        if from_id == "" or to_id == "":
            continue
        var center_cells = edge.get("centerCells", [])
        var cost := maxi(1, center_cells.size() if center_cells is Array else 1)
        if not graph.has(from_id):
            graph[from_id] = []
        if not graph.has(to_id):
            graph[to_id] = []
        var from_edges: Array = graph[from_id]
        var to_edges: Array = graph[to_id]
        from_edges.append({ "to": to_id, "cost": cost })
        to_edges.append({ "to": from_id, "cost": cost })
        graph[from_id] = from_edges
        graph[to_id] = to_edges
    var final_id := String(plan.get("finalChamberId", "final"))
    var distances := { "entrance": 0.0 }
    var visited := {}
    while true:
        var current := ""
        var best_distance := INF
        for key in distances.keys():
            var node_id := String(key)
            if visited.has(node_id):
                continue
            var distance := float(distances.get(node_id, INF))
            if distance < best_distance:
                best_distance = distance
                current = node_id
        if current == "" or current == final_id:
            break
        visited[current] = true
        var links: Array = graph.get(current, [])
        for link_value in links:
            if not (link_value is Dictionary):
                continue
            var link: Dictionary = link_value
            var next_id := String(link.get("to", ""))
            var next_distance := best_distance + float(link.get("cost", 1))
            if next_distance < float(distances.get(next_id, INF)):
                distances[next_id] = next_distance
    var route_cost := float(distances.get(final_id, INF))
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var final_cell: Vector2i = plan.get("finalChestCell", plan.get("finalChamberCell", entrance))
    var inward: Vector2i = plan.get("inward", Vector2i(0, 1))
    var delta := final_cell - entrance
    var straight_distance := Vector2(float(delta.x), float(delta.y)).length()
    var final_depth := delta.x * inward.x + delta.y * inward.y
    var minimum_route_cells := int(plan.get("minimumRouteCells", 48))
    var minimum_final_depth := maxi(42, int(plan.get("pathLength", 0)))
    return {
        "caveTier": String(plan.get("caveTier", "normal")),
        "shortestRouteCells": int(round(route_cost)) if route_cost < INF else 0,
        "minimumRouteCells": minimum_route_cells,
        "straightDistanceCells": rounded(straight_distance),
        "routeDirectness": rounded(route_cost / maxf(1.0, straight_distance)) if route_cost < INF else 0.0,
        "finalDepthCells": final_depth,
        "minimumFinalDepthCells": minimum_final_depth,
        "pathLength": int(plan.get("pathLength", 0))
    }

func cave_route_metrics_passed(metrics: Dictionary) -> bool:
    return int(metrics.get("shortestRouteCells", 0)) >= int(metrics.get("minimumRouteCells", 0)) \
        and float(metrics.get("routeDirectness", 0.0)) >= 1.12 \
        and int(metrics.get("finalDepthCells", 0)) >= int(metrics.get("minimumFinalDepthCells", 0))

func cave_terrain_mouth_summary() -> Dictionary:
    if structure_system == null or main == null:
        return {}
    var edits_value = main.get("height_edits")
    var edits: Dictionary = edits_value if edits_value is Dictionary else {}
    var walkable_cells: Array = structure_system.call("cave_walkable_cells", plan, false)
    var opening_cells: Array = structure_system.call("cave_terrain_opening_cells", plan)
    var portal_cells: Array = structure_system.call("cave_mouth_portal_cells", plan) if structure_system.has_method("cave_mouth_portal_cells") else []
    var opening_lookup := {}
    for cell_value in opening_cells:
        if cell_value is Vector2i:
            opening_lookup[cell_value] = true
    var portal_lookup := {}
    for cell_value in portal_cells:
        if cell_value is Vector2i:
            portal_lookup[cell_value] = true
    var edited_opening_cells := 0
    for cell_value in opening_cells:
        var cell: Vector2i = cell_value
        if edits.has(cell):
            edited_opening_cells += 1
    var edited_portal_cells := 0
    for cell_value in portal_cells:
        var cell: Vector2i = cell_value
        if edits.has(cell):
            edited_portal_cells += 1
    var edited_interior_walkable_cells := 0
    for cell_value in walkable_cells:
        var cell: Vector2i = cell_value
        if edits.has(cell) and not opening_lookup.has(cell) and not portal_lookup.has(cell):
            edited_interior_walkable_cells += 1
    var stone_override_cells := 0
    for cell_value in opening_cells:
        var cell: Vector2i = cell_value
        if String(structure_system.call("terrain_material_override_for_cell", cell.x, cell.y)) == "stone":
            stone_override_cells += 1
    var hidden_portal_cells := 0
    for cell_value in portal_cells:
        var cell: Vector2i = cell_value
        if structure_system.has_method("terrain_quad_hidden_for_cell") and bool(structure_system.call("terrain_quad_hidden_for_cell", cell.x, cell.y)):
            hidden_portal_cells += 1
    var walkable_count := maxi(1, walkable_cells.size())
    return {
        "walkableCells": walkable_cells.size(),
        "openingCells": opening_cells.size(),
        "portalCells": portal_cells.size(),
        "hiddenPortalCells": hidden_portal_cells,
        "editedOpeningCells": edited_opening_cells,
        "editedPortalCells": edited_portal_cells,
        "editedInteriorWalkableCells": edited_interior_walkable_cells,
        "openingToWalkableRatio": rounded(float(opening_cells.size()) / float(walkable_count)),
        "portalToWalkableRatio": rounded(float(portal_cells.size()) / float(walkable_count)),
        "stoneOverrideCells": stone_override_cells
    }

func cave_mouth_terrain_passed(summary: Dictionary) -> bool:
    return int(summary.get("openingCells", 0)) > 0 \
        and int(summary.get("editedOpeningCells", 0)) == int(summary.get("openingCells", 0)) \
        and int(summary.get("editedPortalCells", 0)) == int(summary.get("portalCells", -1)) \
        and int(summary.get("hiddenPortalCells", 0)) == int(summary.get("portalCells", -1)) \
        and int(summary.get("editedInteriorWalkableCells", 999)) == 0 \
        and float(summary.get("openingToWalkableRatio", 1.0)) <= 0.45 \
        and int(summary.get("stoneOverrideCells", 0)) == int(summary.get("openingCells", 0))

func cave_mouth_access_summary() -> Dictionary:
    if main == null or structure_system == null:
        return { "reason": "missing main or structure system" }
    var builder = structure_system.get("cave_interior_builder")
    if builder == null or not builder.has_method("floor_point") or not builder.has_method("ceiling_point"):
        return { "reason": "missing cave interior builder samplers" }
    var entrance: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var inward: Vector2i = plan.get("inward", Vector2i(0, 1))
    var right: Vector2i = plan.get("right", Vector2i(1, 0))
    var approach_depth := int(plan.get("entranceApproachDepth", 7))
    var interior_depth := int(plan.get("entranceOpenDepth", 7))
    var portal_cells: Array = structure_system.call("cave_mouth_portal_cells", plan) if structure_system.has_method("cave_mouth_portal_cells") else []
    var hidden_portal_cells := 0
    for cell_value in portal_cells:
        if not (cell_value is Vector2i):
            continue
        var portal_cell: Vector2i = cell_value
        if structure_system.has_method("terrain_quad_hidden_for_cell") and bool(structure_system.call("terrain_quad_hidden_for_cell", portal_cell.x, portal_cell.y)):
            hidden_portal_cells += 1
    var outside_min := INF
    var outside_max := -INF
    for depth in range(-approach_depth, 1):
        for lateral in range(-1, 2):
            var outside_cell: Vector2i = entrance + inward * int(depth) + right * int(lateral)
            var h := float(main.call("terrain_height_cell", outside_cell.x, outside_cell.y))
            outside_min = minf(outside_min, h)
            outside_max = maxf(outside_max, h)
    var max_center_step := 0.0
    var previous_y := INF
    var min_clearance := INF
    var min_cover_after_portal := INF
    var covered_samples := 0
    var front_open_columns := 0
    var jagged_mouth_rows := 0
    var blocked_center_samples := 0
    var exterior_shell_samples := 0
    var mouth_rows_checked := 0
    var arch_center_clearance := 0.0
    var arch_side_clearance := 0.0
    var front_floor_gap := 0.0
    var mouth_width := float(plan.get("entranceMouthHalfWidth", 0.0))
    if builder.has_method("rendered_shell_inside_at_point"):
        var lateral_limit := ceili(mouth_width + 0.5)
        for exterior_depth in range(-approach_depth, 0):
            for lateral in range(-lateral_limit, lateral_limit + 1):
                var exterior_cell: Vector2i = entrance + inward * int(exterior_depth) + right * int(lateral)
                var exterior_point := cave_cell_world2(exterior_cell)
                if bool(builder.call("rendered_shell_inside_at_point", plan, exterior_point)):
                    exterior_shell_samples += 1
        var row_depth_limit := mini(4, interior_depth)
        for row_depth in range(0, row_depth_limit + 1):
            var open_laterals: Array[int] = []
            for lateral in range(-lateral_limit, lateral_limit + 1):
                var sample_cell: Vector2i = entrance + inward * int(row_depth) + right * int(lateral)
                var sample_point := cave_cell_world2(sample_cell)
                if bool(builder.call("rendered_shell_inside_at_point", plan, sample_point)):
                    open_laterals.append(lateral)
            if open_laterals.is_empty():
                jagged_mouth_rows += 1
                continue
            mouth_rows_checked += 1
            var min_lateral := open_laterals[0]
            var max_lateral := open_laterals[0]
            var open_lookup := {}
            for lateral_value in open_laterals:
                min_lateral = mini(min_lateral, lateral_value)
                max_lateral = maxi(max_lateral, lateral_value)
                open_lookup[lateral_value] = true
            if row_depth == 0:
                front_open_columns = open_laterals.size()
            if min_lateral > 0 or max_lateral < 0:
                jagged_mouth_rows += 1
            else:
                for lateral in range(min_lateral, max_lateral + 1):
                    if not open_lookup.has(lateral):
                        jagged_mouth_rows += 1
                        break
            var center_point := cave_cell_world2(entrance + inward * int(row_depth))
            if not bool(builder.call("rendered_shell_inside_at_point", plan, center_point)):
                blocked_center_samples += 1
        var center_floor_value = builder.call("floor_point", plan, cave_cell_world2(entrance))
        var center_ceiling_value = builder.call("ceiling_point", plan, cave_cell_world2(entrance))
        if center_floor_value is Vector3 and center_ceiling_value is Vector3:
            arch_center_clearance = float((center_ceiling_value as Vector3).y - (center_floor_value as Vector3).y)
            front_floor_gap = absf(float(main.call("terrain_height_cell", entrance.x, entrance.y)) - float((center_floor_value as Vector3).y))
        var side_lateral := maxi(1, roundi(mouth_width * 0.82))
        var side_cell := entrance + right * side_lateral
        var side_floor_value = builder.call("floor_point", plan, cave_cell_world2(side_cell))
        var side_ceiling_value = builder.call("ceiling_point", plan, cave_cell_world2(side_cell))
        if side_floor_value is Vector3 and side_ceiling_value is Vector3:
            arch_side_clearance = float((side_ceiling_value as Vector3).y - (side_floor_value as Vector3).y)
    for depth in range(-mini(3, approach_depth), interior_depth + 5):
        var cell: Vector2i = entrance + inward * int(depth)
        var point := cave_cell_world2(cell)
        var floor_value = builder.call("floor_point", plan, point)
        var ceiling_value = builder.call("ceiling_point", plan, point)
        var floor_y := float((floor_value as Vector3).y) if floor_value is Vector3 else float(plan.get("level", 0.0))
        var ceiling_y := float((ceiling_value as Vector3).y) if ceiling_value is Vector3 else float(plan.get("ceilingLevel", floor_y + CELL * 3.0))
        var ground_y := float(main.call("terrain_height_cell", cell.x, cell.y)) if depth < 0 else floor_y
        if previous_y != INF:
            max_center_step = maxf(max_center_step, absf(ground_y - previous_y))
        previous_y = ground_y
        if depth >= 0:
            min_clearance = minf(min_clearance, ceiling_y - floor_y)
        if depth > interior_depth:
            covered_samples += 1
            min_cover_after_portal = minf(min_cover_after_portal, float(main.call("terrain_height_cell", cell.x, cell.y)) - ceiling_y)
    return {
        "portalCells": portal_cells.size(),
        "hiddenPortalCells": hidden_portal_cells,
        "outsideHeightRange": rounded(0.0 if outside_min == INF else outside_max - outside_min),
        "maxCenterRouteStep": rounded(max_center_step),
        "minPlayerClearance": rounded(0.0 if min_clearance == INF else min_clearance),
        "minCoverAfterPortal": rounded(0.0 if min_cover_after_portal == INF else min_cover_after_portal),
        "coveredSamplesAfterPortal": covered_samples,
        "mouthHalfWidth": rounded(mouth_width),
        "mouthFloorLevel": rounded(float(plan.get("mouthFloorLevel", plan.get("level", 0.0)))),
        "frontOpenColumns": front_open_columns,
        "mouthRowsChecked": mouth_rows_checked,
        "jaggedMouthRows": jagged_mouth_rows,
        "blockedCenterSamples": blocked_center_samples,
        "exteriorShellSamples": exterior_shell_samples,
        "frontArchCenterClearance": rounded(arch_center_clearance),
        "frontArchSideClearance": rounded(arch_side_clearance),
        "frontArchRise": rounded(arch_center_clearance - arch_side_clearance),
        "frontFloorGap": rounded(front_floor_gap),
        "entranceCell": vec2i(entrance)
    }

func cave_mouth_access_passed(summary: Dictionary) -> bool:
    return int(summary.get("portalCells", 0)) > 0 \
        and int(summary.get("hiddenPortalCells", 0)) == int(summary.get("portalCells", -1)) \
        and float(summary.get("outsideHeightRange", 999.0)) <= CELL * 1.25 \
        and float(summary.get("maxCenterRouteStep", 999.0)) <= CELL * 0.85 \
        and float(summary.get("minPlayerClearance", 0.0)) >= CELL * 2.05 \
        and int(summary.get("coveredSamplesAfterPortal", 0)) > 0 \
        and float(summary.get("minCoverAfterPortal", -999.0)) >= CELL * 0.35 \
        and float(summary.get("mouthHalfWidth", 0.0)) >= 3.25 \
        and int(summary.get("frontOpenColumns", 0)) >= 7 \
        and int(summary.get("mouthRowsChecked", 0)) >= 4 \
        and int(summary.get("jaggedMouthRows", 999)) == 0 \
        and int(summary.get("blockedCenterSamples", 999)) == 0 \
        and int(summary.get("exteriorShellSamples", 999)) == 0 \
        and float(summary.get("frontFloorGap", 999.0)) <= CELL * 0.30 \
        and float(summary.get("frontArchRise", 0.0)) >= CELL * 0.55

func cave_negative_y_growth_summary() -> Dictionary:
    if main == null or structure_system == null:
        return { "sampleCount": 0, "reason": "missing main or structure system" }
    var builder = structure_system.get("cave_interior_builder")
    if builder == null or not builder.has_method("floor_point") or not builder.has_method("ceiling_point"):
        return { "sampleCount": 0, "reason": "missing cave interior builder samplers" }
    var edits_value = main.get("height_edits")
    var edits: Dictionary = edits_value if edits_value is Dictionary else {}
    var opening_cells: Array = structure_system.call("cave_terrain_opening_cells", plan)
    var opening_lookup := {}
    for cell_value in opening_cells:
        if cell_value is Vector2i:
            opening_lookup[cell_value] = true
    var portal_cells: Array = structure_system.call("cave_mouth_portal_cells", plan) if structure_system.has_method("cave_mouth_portal_cells") else []
    for cell_value in portal_cells:
        if cell_value is Vector2i:
            opening_lookup[cell_value] = true
    var raised_edit_cells := 0
    var max_edit_raise := 0.0
    for cell_value in opening_cells:
        if not (cell_value is Vector2i):
            continue
        var opening_cell: Vector2i = cell_value
        if not edits.has(opening_cell):
            continue
        var base_height := cave_base_height_cell(opening_cell)
        var edit_height := float(edits[opening_cell])
        var raise_amount := edit_height - base_height
        if raise_amount > 0.025:
            raised_edit_cells += 1
            max_edit_raise = maxf(max_edit_raise, raise_amount)
    var walkable_cells: Array = structure_system.call("cave_walkable_cells", plan, false)
    var sample_count := 0
    var exposed_ceiling_cells := 0
    var positive_y_ceiling_cells := 0
    var floor_above_terrain_cells := 0
    var min_terrain_cover := INF
    var max_ceiling_above_terrain := -INF
    var min_floor_clearance := INF
    var total_cover := 0.0
    var worst_cell := Vector2i.ZERO
    var required_cover := CELL * 0.35
    var max_samples := 360
    var stride := maxi(1, ceili(float(walkable_cells.size()) / float(max_samples)))
    var index := 0
    for cell_value in walkable_cells:
        index += 1
        if index % stride != 0:
            continue
        if not (cell_value is Vector2i):
            continue
        var cell: Vector2i = cell_value
        if opening_lookup.has(cell):
            continue
        var point := cave_cell_world2(cell)
        var floor_value = builder.call("floor_point", plan, point)
        var ceiling_value = builder.call("ceiling_point", plan, point)
        if not (floor_value is Vector3) or not (ceiling_value is Vector3):
            continue
        var terrain_y := float(main.call("terrain_height_cell", cell.x, cell.y))
        var floor_y := float((floor_value as Vector3).y)
        var ceiling_y := float((ceiling_value as Vector3).y)
        var cover := terrain_y - ceiling_y
        var floor_clearance := terrain_y - floor_y
        sample_count += 1
        total_cover += cover
        if cover < min_terrain_cover:
            min_terrain_cover = cover
            worst_cell = cell
        max_ceiling_above_terrain = maxf(max_ceiling_above_terrain, ceiling_y - terrain_y)
        min_floor_clearance = minf(min_floor_clearance, floor_clearance)
        if cover < required_cover:
            exposed_ceiling_cells += 1
        if ceiling_y > terrain_y + 0.025:
            positive_y_ceiling_cells += 1
        if floor_y > terrain_y + 0.025:
            floor_above_terrain_cells += 1
    var entrance_cell: Vector2i = plan.get("entranceCell", Vector2i.ZERO)
    var final_cell: Vector2i = plan.get("finalChamberCell", entrance_cell)
    var entrance_floor_value = builder.call("floor_point", plan, cave_cell_world2(entrance_cell))
    var final_floor_value = builder.call("floor_point", plan, cave_cell_world2(final_cell))
    var entrance_floor_y := float((entrance_floor_value as Vector3).y) if entrance_floor_value is Vector3 else float(plan.get("level", 0.0))
    var final_floor_y := float((final_floor_value as Vector3).y) if final_floor_value is Vector3 else float(plan.get("level", 0.0))
    var route_drop_y := entrance_floor_y - final_floor_y
    var available_drop := maxf(0.0, float(plan.get("level", 0.0)) + 0.22 - (float(main.WATER_LEVEL) + CELL * 1.45))
    var required_route_drop := minf(CELL * 1.25, available_drop * 0.45)
    if required_route_drop < CELL * 0.45 and available_drop >= CELL * 0.70:
        required_route_drop = CELL * 0.45
    return {
        "sampleCount": sample_count,
        "requiredTerrainCover": rounded(required_cover),
        "minTerrainCover": rounded(0.0 if min_terrain_cover == INF else min_terrain_cover),
        "averageTerrainCover": rounded(0.0 if sample_count == 0 else total_cover / float(sample_count)),
        "maxCeilingAboveTerrain": rounded(0.0 if max_ceiling_above_terrain == -INF else max_ceiling_above_terrain),
        "minFloorClearance": rounded(0.0 if min_floor_clearance == INF else min_floor_clearance),
        "exposedCeilingCells": exposed_ceiling_cells,
        "positiveYCeilingCells": positive_y_ceiling_cells,
        "floorAboveTerrainCells": floor_above_terrain_cells,
        "raisedTerrainEditCells": raised_edit_cells,
        "maxTerrainEditRaise": rounded(max_edit_raise),
        "entranceFloorY": rounded(entrance_floor_y),
        "finalFloorY": rounded(final_floor_y),
        "routeDropY": rounded(route_drop_y),
        "requiredRouteDropY": rounded(required_route_drop),
        "availableDropY": rounded(available_drop),
        "worstCoverCell": vec2i(worst_cell)
    }

func cave_negative_y_growth_passed(summary: Dictionary) -> bool:
    return int(summary.get("sampleCount", 0)) > 0 \
        and int(summary.get("raisedTerrainEditCells", 999)) == 0 \
        and int(summary.get("positiveYCeilingCells", 999)) == 0 \
        and int(summary.get("floorAboveTerrainCells", 999)) == 0 \
        and int(summary.get("exposedCeilingCells", 999)) == 0 \
        and float(summary.get("minTerrainCover", -999.0)) >= float(summary.get("requiredTerrainCover", CELL * 0.35)) \
        and float(summary.get("routeDropY", 0.0)) >= float(summary.get("requiredRouteDropY", 0.0))

func cave_base_height_cell(cell: Vector2i) -> float:
    if main != null and main.has_method("base_height_cell"):
        return float(main.call("base_height_cell", cell.x, cell.y))
    if main != null and main.has_method("terrain_height_cell"):
        return float(main.call("terrain_height_cell", cell.x, cell.y))
    return 0.0

func cave_cell_world2(cell: Vector2i) -> Vector2:
    return Vector2(float(cell.x) * CELL, float(cell.y) * CELL)

func cave_torch_mount_summary() -> Dictionary:
    var blocks_value = main.get("blocks") if main != null else {}
    var blocks: Dictionary = blocks_value if blocks_value is Dictionary else {}
    var torches := 0
    var wall_mounted := 0
    for block_value in blocks.values():
        var block := block_value as Node
        if block == null:
            continue
        if String(block.get_meta("generatedTier", "")) != "cave" or String(block.get_meta("caveId", "")) != String(plan.get("id", "")):
            continue
        if String(block.get_meta("block_type", "")) != "torch":
            continue
        torches += 1
        if bool(block.get_meta("torchWallMount", false)):
            wall_mounted += 1
    return {
        "torches": torches,
        "wallMountedTorches": wall_mounted
    }

func array_size(value) -> int:
    return value.size() if value is Array else 0

func cave_vertical_summary() -> Dictionary:
    var floor_level := float(plan.get("level", 0.0))
    var ceiling_level := float(plan.get("ceilingLevel", floor_level))
    var surface_level := float(plan.get("surfaceLevel", ceiling_level))
    var floor_summary := cave_floor_variation_summary()
    return {
        "surfaceLevel": rounded(surface_level),
        "floorLevel": rounded(floor_level),
        "ceilingLevel": rounded(ceiling_level),
        "ceilingClearance": rounded(ceiling_level - floor_level),
        "earthCover": rounded(surface_level - ceiling_level),
        "floorHeightRange": rounded(float(floor_summary.get("range", 0.0))),
        "maxFloorNeighborStep": rounded(float(floor_summary.get("maxNeighborStep", 0.0))),
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

func cave_floor_variation_summary() -> Dictionary:
    if structure_system == null:
        return {}
    var builder = structure_system.get("cave_interior_builder")
    if builder == null or not builder.has_method("floor_variation_summary"):
        return {}
    return builder.call("floor_variation_summary", plan)

func cave_daylight_shadow_authoritative_on_cave_layer() -> bool:
    var summary := cave_layer_lighting_summary()
    return int(summary.get("caveVisuals", 0)) >= 1 \
        and int(summary.get("nonCaveLayerCaveVisuals", 0)) == 0 \
        and int(summary.get("sunLightsCaveLayer", 0)) == 1 \
        and int(summary.get("moonLightsCaveLayer", 0)) == 1

func cave_layer_lighting_summary() -> Dictionary:
    var layer_summary := { "caveVisuals": 0, "nonCaveLayerCaveVisuals": 0 }
    var cave_id := String(plan.get("id", ""))
    var nodes_value = structure_system.get("cave_interior_nodes") if structure_system != null else {}
    if nodes_value is Dictionary:
        for node_value in (nodes_value as Dictionary).values():
            var node := node_value as Node
            if node != null and String(node.get_meta("caveId", "")) == cave_id:
                add_cave_layer_summary(layer_summary, node)
    var blocks_value = main.get("blocks") if main != null else {}
    if blocks_value is Dictionary:
        for block_value in (blocks_value as Dictionary).values():
            var block := block_value as Node
            if block != null and String(block.get_meta("generatedTier", "")) == "cave" and String(block.get_meta("caveId", "")) == cave_id:
                add_cave_layer_summary(layer_summary, block)
    var sun := main.get_node_or_null("Sun") as Light3D if main != null else null
    var moon := main.get_node_or_null("Moon") as Light3D if main != null else null
    layer_summary["sunCullMask"] = int(sun.light_cull_mask) if sun != null else -1
    layer_summary["moonCullMask"] = int(moon.light_cull_mask) if moon != null else -1
    layer_summary["sunLightsCaveLayer"] = 1 if sun != null and (int(sun.light_cull_mask) & 2) != 0 else 0
    layer_summary["moonLightsCaveLayer"] = 1 if moon != null and (int(moon.light_cull_mask) & 2) != 0 else 0
    return layer_summary

func add_cave_layer_summary(summary: Dictionary, node: Node) -> void:
    if node is VisualInstance3D:
        summary["caveVisuals"] = int(summary.get("caveVisuals", 0)) + 1
        if int((node as VisualInstance3D).layers) != 2:
            summary["nonCaveLayerCaveVisuals"] = int(summary.get("nonCaveLayerCaveVisuals", 0)) + 1
    for child in node.get_children():
        add_cave_layer_summary(summary, child)

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

func image_luminance_summary(image: Image) -> Dictionary:
    var total := 0.0
    var max_luma := 0.0
    var sample_count := 0
    var width := image.get_width()
    var height := image.get_height()
    var step := 16
    for y in range(0, height, step):
        for x in range(0, width, step):
            var color := image.get_pixel(x, y)
            var luma := color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
            total += luma
            max_luma = maxf(max_luma, luma)
            sample_count += 1
    var average := total / float(maxi(1, sample_count))
    return {
        "average": rounded(average),
        "max": rounded(max_luma),
        "samples": sample_count
    }

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
        "acceptanceClaims": ["procedural_cave_player_pov_route_depth_visual"],
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
        "caveTier": String(plan_value.get("caveTier", "normal")),
        "region": vec2i(plan_value.get("region", Vector2i.ZERO)),
        "entranceCell": vec2i(plan_value.get("entranceCell", Vector2i.ZERO)),
        "finalChamberCell": vec2i(plan_value.get("finalChamberCell", Vector2i.ZERO)),
        "finalChestCell": vec2i(plan_value.get("finalChestCell", Vector2i.ZERO)),
        "pathLength": int(plan_value.get("pathLength", 0)),
        "minimumRouteCells": int(plan_value.get("minimumRouteCells", 0)),
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
