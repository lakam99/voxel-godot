extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const TEST_ID := "light_shadow_visual_playtest"
const CELL := 1.35
const CAPTURE_WIDTH := 1280
const CAPTURE_HEIGHT := 720
const REQUIRED_CAPTURE_STAGES := [
    "outdoor_noon_reference",
    "sealed_hut_noon_dark",
    "doorway_hut_light_bleed",
    "cave_entrance_daylight",
    "deep_cave_noon_dark",
    "final_chamber_wall_torch",
    "final_chamber_wall_torch_side",
    "final_chamber_wall_torch_closeup",
    "deep_cave_torch_lit"
]
const ACCEPTANCE_CLAIMS := [
    "shadow_authoritative_daylight_blocks_sealed_interiors_and_deep_caves"
]

var main: Node3D
var player: CharacterBody3D
var camera: Camera3D
var gameplay_camera: Camera3D
var free_camera: Camera3D
var structure_system
var seed := ""
var report_path := ""
var progress_path := ""
var screenshot_dir := ""
var run_token := ""
var results: Array[Dictionary] = []
var captures: Array[Dictionary] = []
var timeline: Array[Dictionary] = []
var stage_luminance := {}
var cave_plan: Dictionary = {}
var sealed_hut := {}
var doorway_hut := {}
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
        add_result("light_shadow_watchdog", false, "watchdog %.1fs exceeded" % watchdog_seconds)
        finish(1)

func configure_from_environment() -> void:
    seed = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
    if seed == "":
        seed = "atlas-1492"
    report_path = OS.get_environment("VOXEL_LIGHT_SHADOW_REPORT")
    if report_path == "":
        report_path = ProjectSettings.globalize_path("res://artifacts/light/light-shadow-visual-playtest.json")
    progress_path = OS.get_environment("VOXEL_LIGHT_SHADOW_PROGRESS")
    screenshot_dir = OS.get_environment("VOXEL_LIGHT_SHADOW_SCREENSHOT_DIR")
    if screenshot_dir == "":
        screenshot_dir = ProjectSettings.globalize_path("res://artifacts/light/screenshots/light-shadow")
    run_token = OS.get_environment("VOXEL_LIGHT_SHADOW_RUN_TOKEN")
    var watchdog_value := OS.get_environment("VOXEL_LIGHT_SHADOW_WATCHDOG_SECONDS").strip_edges()
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
    if main == null or player == null or camera == null or structure_system == null:
        add_result("light_shadow_scene_ready", false, "main/player/camera/structure_system missing")
        finish(1)
        return

    configure_scene()
    build_fixtures()
    await wait_physics_frames(20)
    await wait_process_frames(6)

    add_result("light_shadow_headed_mode", DisplayServer.get_name().to_lower() != "headless", "display=%s" % DisplayServer.get_name())
    add_result("light_shadow_global_ambient_removed", global_ambient_removed(), JSON.stringify(environment_summary()))
    add_result("light_shadow_direct_lights_cover_cave_layer", direct_lights_cover_cave_layer(), JSON.stringify(light_mask_summary()))

    await capture_stage("outdoor_noon_reference", sealed_hut["outsideEye"], sealed_hut["outsideTarget"])
    await capture_stage("sealed_hut_noon_dark", sealed_hut["insideEye"], sealed_hut["insideTarget"])
    await capture_stage("doorway_hut_light_bleed", doorway_hut["insideEye"], doorway_hut["outsideTarget"])
    await capture_stage("cave_entrance_daylight", cave_entrance_eye(), cave_entrance_target())
    await capture_stage("deep_cave_noon_dark", cave_deep_eye(), cave_deep_target())
    var torch := final_chamber_wall_torch()
    var torch_valid := final_chamber_wall_torch_is_valid(torch)
    add_result("light_shadow_final_chamber_wall_torch_found", torch_valid, JSON.stringify(torch_summary(torch)))
    if torch_valid:
        await capture_stage("final_chamber_wall_torch", final_chamber_wall_torch_eye(torch), final_chamber_wall_torch_target(torch))
        await capture_stage("final_chamber_wall_torch_side", final_chamber_wall_torch_side_eye(torch), final_chamber_wall_torch_side_target(torch))
        await capture_stage("final_chamber_wall_torch_closeup", final_chamber_wall_torch_closeup_eye(torch), final_chamber_wall_torch_closeup_target(torch))
        await capture_stage("deep_cave_torch_lit", final_chamber_wall_torch_side_eye(torch), final_chamber_wall_torch_flame_target(torch))
    else:
        add_result("capture_final_chamber_wall_torch_saved", false, "missing generated final-chamber wall torch")
        add_result("capture_final_chamber_wall_torch_side_saved", false, "missing generated final-chamber wall torch")
        add_result("capture_final_chamber_wall_torch_closeup_saved", false, "missing generated final-chamber wall torch")
        add_result("capture_deep_cave_torch_lit_saved", false, "missing generated final-chamber wall torch")

    add_result("light_shadow_required_screenshots_saved", required_captures_saved(), JSON.stringify(capture_names()))
    add_luminance_assertions()
    finish(1 if failure_count() > 0 else 0)

func bind_scene_nodes() -> void:
    player = main.get("player") as CharacterBody3D
    if player != null:
        gameplay_camera = player.get("camera") as Camera3D
        camera = gameplay_camera
    structure_system = main.get("structure_system")
    ensure_free_capture_camera()

func ensure_free_capture_camera() -> void:
    if free_camera != null and is_instance_valid(free_camera):
        camera = free_camera
        return
    free_camera = Camera3D.new()
    free_camera.name = "LightShadowVisualFreeCamera"
    if gameplay_camera != null:
        free_camera.fov = gameplay_camera.fov
        free_camera.near = gameplay_camera.near
        free_camera.far = gameplay_camera.far
        free_camera.environment = gameplay_camera.environment
        free_camera.cull_mask = gameplay_camera.cull_mask
    if main != null:
        main.add_child(free_camera)
    else:
        add_child(free_camera)
    camera = free_camera

func configure_scene() -> void:
    neutralize_intro_clock_freeze()
    clear_player_inventory_and_held_item()
    main.set("shadows_enabled", true)
    main.set("time_of_day", fposmod((13.0 / 24.0) - 0.25, 1.0))
    var weather_system = main.get("weather_system")
    if weather_system != null and weather_system.has_method("force_weather"):
        weather_system.force_weather("clear", 0.0, 0.12, Vector3.ZERO)
    if main.has_method("update_sky"):
        main.call("update_sky", 0.0)
    if main.has_method("apply_local_light_shadows"):
        main.call("apply_local_light_shadows")
    var hud = main.get("hud")
    if hud is CanvasLayer:
        (hud as CanvasLayer).visible = false
    elif hud is Node:
        var hud_root = hud.get("hud_root")
        if hud_root is Control:
            (hud_root as Control).visible = false

func clear_player_inventory_and_held_item() -> void:
    var inventory_system = main.get("inventory_system") if main != null else null
    if inventory_system != null and inventory_system.has_method("clear"):
        inventory_system.clear()
    var held_item = main.get("held_item") if main != null else null
    if held_item != null and held_item.has_method("refresh_active"):
        held_item.refresh_active()

func neutralize_intro_clock_freeze() -> void:
    var tutorial = main.get("tutorial_system") if main != null else null
    if tutorial == null:
        return
    tutorial.set("intro_repair_active", false)
    tutorial.set("intro_repair_complete", true)
    tutorial.set("intro_bed_used", true)
    tutorial.set("final_night_active", false)
    tutorial.set("final_night_complete", true)

func build_fixtures() -> void:
    sealed_hut = build_hut_fixture(Vector2i(26, 26), true)
    doorway_hut = build_hut_fixture(Vector2i(36, 26), false)
    var world_generation = main.get("world_generation_system") if main != null else null
    if world_generation == null or not world_generation.has_method("find_cave_biome_sample"):
        add_result("light_shadow_cave_biome_selected", false, "world cave sampler missing")
        return
    var cave_record: Dictionary = world_generation.call("find_cave_biome_sample", 16)
    var feature: Dictionary = cave_record.get("feature", {}) if cave_record.has("feature") else {}
    if feature.is_empty():
        add_result("light_shadow_cave_biome_selected", false, "no cave biome found")
        return
    cave_plan = light_shadow_cave_metadata(feature)
    var entrance: Vector2i = cave_plan.get("entranceCell", Vector2i.ZERO)
    if main.has_method("rebuild_chunks_around_cell"):
        main.call("rebuild_chunks_around_cell", entrance)
        main.call("rebuild_chunks_around_cell", cave_plan.get("finalChamberCell", entrance))
    add_result("light_shadow_cave_biome_selected", true, JSON.stringify(sanitize_plan_summary(cave_plan)))

func light_shadow_cave_metadata(feature: Dictionary) -> Dictionary:
    var entrance: Vector2i = feature.get("entranceCell", Vector2i.ZERO)
    var inward: Vector2i = feature.get("inward", Vector2i(0, 1))
    var length_cells := maxi(8, roundi(float(feature.get("length", CELL * 24.0)) / CELL))
    var path_cells: Array[Vector2i] = []
    for depth in range(0, length_cells + 1):
        path_cells.append(entrance + inward * depth)
    var result := feature.duplicate(true)
    result["pathLength"] = length_cells
    result["pathCells"] = path_cells
    result["finalChamberCell"] = entrance + inward * length_cells
    result["finalChestCell"] = result["finalChamberCell"]
    return result

func build_hut_fixture(base: Vector2i, sealed: bool) -> Dictionary:
    var width := 5
    var depth := 5
    var wall_height := 4
    var level := flatten_rect(base, width, depth)
    var center := Vector2i(base.x + int(width / 2), base.y + int(depth / 2))
    var front_z := base.y
    var doorway_x := base.x + int(width / 2)
    for dy in range(wall_height):
        for x in range(width):
            for z in range(depth):
                var perimeter := x == 0 or z == 0 or x == width - 1 or z == depth - 1
                if not perimeter:
                    continue
                var cell_x := base.x + x
                var cell_z := base.y + z
                var doorway_open := not sealed and cell_x == doorway_x and cell_z == front_z and dy <= 1
                if doorway_open:
                    continue
                structure_system.place_structure_block(cell_x, cell_z, level, dy, "stoneBlock", {
                    "generatedTier": "light_test",
                    "cacheKey": "light-shadow"
                })
    for x in range(width):
        for z in range(depth):
            structure_system.place_structure_block(base.x + x, base.y + z, level, wall_height, "stoneBlock", {
                "generatedTier": "light_test",
                "cacheKey": "light-shadow",
                "roofRole": "flat"
            })
    var inside_eye := Vector3(float(center.x) * CELL, level + CELL * 1.35, float(center.y) * CELL)
    var inside_target := inside_eye + Vector3(0.0, -0.10, -CELL * 1.9)
    var outside_eye := Vector3(float(center.x) * CELL, level + CELL * 1.45, float(base.y - 4) * CELL)
    var outside_target := Vector3(float(center.x) * CELL, level + CELL * 1.25, float(base.y + 1) * CELL)
    return {
        "base": vec2i(base),
        "center": vec2i(center),
        "level": rounded(level),
        "sealed": sealed,
        "insideEye": inside_eye,
        "insideTarget": inside_target,
        "outsideEye": outside_eye,
        "outsideTarget": outside_target
    }

func flatten_rect(base: Vector2i, width: int, depth: int) -> float:
    var center := Vector2i(base.x + int(width / 2), base.y + int(depth / 2))
    var level: float = main.call("surface_y_at_cell", Vector3i(center.x, 0, center.y))
    var edits = main.get("volume_edit_markers")
    if edits is Dictionary:
        for x in range(base.x - 2, base.x + width + 2):
            for z in range(base.y - 2, base.y + depth + 2):
                edits[Vector2i(x, z)] = level
    if main.has_method("rebuild_chunks_around_cell"):
        main.call("rebuild_chunks_around_cell", center)
    return level

func capture_stage(stage: String, eye: Vector3, target: Vector3) -> void:
    position_player_camera(eye, target)
    await wait_process_frames(8)
    var image := get_viewport().get_texture().get_image()
    var path := screenshot_dir.path_join("%s.png" % stage)
    var err := image.save_png(path)
    var luminance := image_luminance_summary(image)
    stage_luminance[stage] = luminance
    var sample := {
        "stage": stage,
        "elapsed": rounded(elapsed),
        "camera": vec3(camera.global_position if camera != null else Vector3.ZERO),
        "target": vec3(target),
        "luminance": luminance
    }
    captures.append({
        "stage": stage,
        "path": path,
        "saved": err == OK,
        "luminance": luminance
    })
    timeline.append(sample)
    add_result("capture_%s_saved" % stage, err == OK, path)

func position_player_camera(eye: Vector3, target: Vector3) -> void:
    ensure_free_capture_camera()
    if free_camera != null and is_instance_valid(free_camera):
        free_camera.global_position = eye
        if eye.distance_to(target) > 0.01:
            free_camera.look_at(target, Vector3.UP)
        free_camera.make_current()
        return
    if player == null or camera == null:
        return
    player.global_position = eye - Vector3(0.0, CELL * 1.05, 0.0)
    player.velocity = Vector3.ZERO
    camera.make_current()
    aim_player_at(target)

func aim_player_at(world_point: Vector3) -> void:
    if player == null or camera == null:
        return
    var eye: Vector3 = camera.global_position
    var direction: Vector3 = world_point - eye
    var flat_direction := Vector3(direction.x, 0.0, direction.z)
    if flat_direction.length_squared() > 0.0001:
        player.rotation.y = atan2(-flat_direction.x, -flat_direction.z)
    var local_direction: Vector3 = player.global_transform.basis.inverse() * direction.normalized()
    var pitch_value: float = clampf(atan2(local_direction.y, -local_direction.z), deg_to_rad(-82.0), deg_to_rad(82.0))
    player.set("pitch", pitch_value)
    camera.rotation.x = pitch_value

func cave_entrance_eye() -> Vector3:
    var entrance: Vector2i = cave_plan.get("entranceCell", Vector2i.ZERO)
    var inward: Vector2i = cave_plan.get("inward", Vector2i(0, 1))
    return terrain_world_for_cell(entrance - inward * 2, 1.35)

func cave_entrance_target() -> Vector3:
    var entrance: Vector2i = cave_plan.get("entranceCell", Vector2i.ZERO)
    var inward: Vector2i = cave_plan.get("inward", Vector2i(0, 1))
    return cave_world_for_cell(entrance + inward * 4, 1.25)

func cave_deep_eye() -> Vector3:
    var sample := deep_tunnel_cell()
    var inward: Vector2i = cave_plan.get("inward", Vector2i(0, 1))
    return cave_world_for_cell(sample - inward * 2, 1.45)

func cave_deep_target() -> Vector3:
    var sample := deep_tunnel_cell()
    var inward: Vector2i = cave_plan.get("inward", Vector2i(0, 1))
    var right: Vector2i = cave_plan.get("right", Vector2i(-inward.y, inward.x))
    return cave_world_for_cell(sample + right * 3, 1.10)

func final_chamber_wall_torch() -> StaticBody3D:
    if main == null or cave_plan.is_empty():
        return null
    var cave_id := String(cave_plan.get("id", ""))
    var target_cell: Vector2i = cave_plan.get("finalChestCell", cave_plan.get("finalChamberCell", Vector2i.ZERO))
    var blocks_value = main.get("blocks")
    if not (blocks_value is Dictionary):
        return null
    var best: StaticBody3D = null
    var best_distance := INF
    for block_value in (blocks_value as Dictionary).values():
        var block := block_value as StaticBody3D
        if block == null or not is_instance_valid(block):
            continue
        if String(block.get_meta("generatedTier", "")) != "cave":
            continue
        if String(block.get_meta("caveId", "")) != cave_id:
            continue
        if String(block.get_meta("block_type", "")) != "torch":
            continue
        if not final_chamber_wall_torch_is_valid(block):
            continue
        var cell := block_cell2(block)
        var distance := cell.distance_to(target_cell)
        if distance < best_distance:
            best_distance = distance
            best = block
    return best

func final_chamber_wall_torch_is_valid(torch: StaticBody3D) -> bool:
    if torch == null or not is_instance_valid(torch):
        return false
    var normal := torch_wall_normal(torch)
    return bool(torch.get_meta("torchWallMount", false)) and abs(normal.x) + abs(normal.y) == 1

func final_chamber_wall_torch_eye(torch: StaticBody3D) -> Vector3:
    return torch.global_position + torch_world_normal(torch) * CELL * 1.05 + Vector3(0.0, CELL * 0.12, 0.0)

func final_chamber_wall_torch_target(torch: StaticBody3D) -> Vector3:
    return torch.global_position + Vector3(0.0, CELL * 0.12, 0.0)

func final_chamber_wall_torch_side_eye(torch: StaticBody3D) -> Vector3:
    return torch.global_position + torch_world_normal(torch) * CELL * 0.58 + torch_world_tangent(torch) * CELL * 0.46 + Vector3(0.0, CELL * 0.16, 0.0)

func final_chamber_wall_torch_side_target(torch: StaticBody3D) -> Vector3:
    return torch.global_position + torch_world_normal(torch) * CELL * 0.02 + Vector3(0.0, CELL * 0.13, 0.0)

func final_chamber_wall_torch_closeup_eye(torch: StaticBody3D) -> Vector3:
    return torch.global_position + torch_world_normal(torch) * CELL * 0.38 + torch_world_tangent(torch) * CELL * 0.18 + Vector3(0.0, CELL * 0.13, 0.0)

func final_chamber_wall_torch_closeup_target(torch: StaticBody3D) -> Vector3:
    return torch.global_position + torch_world_normal(torch) * CELL * 0.01 + Vector3(0.0, CELL * 0.14, 0.0)

func final_chamber_wall_torch_flame_target(torch: StaticBody3D) -> Vector3:
    return torch.global_position + Vector3(0.0, CELL * 0.24, 0.0)

func block_cell2(block: Node) -> Vector2i:
    if block == null:
        return Vector2i.ZERO
    var cell: Vector3i = block.get_meta("cell", Vector3i.ZERO)
    return Vector2i(cell.x, cell.z)

func torch_wall_normal(torch: Node) -> Vector2i:
    if torch == null:
        return Vector2i.ZERO
    return Vector2i(int(torch.get_meta("torchWallNormalX", 0)), int(torch.get_meta("torchWallNormalZ", 0)))

func torch_world_normal(torch: Node) -> Vector3:
    if torch != null and torch.has_meta("torchWallNormalWorldX") and torch.has_meta("torchWallNormalWorldZ"):
        var precise := Vector3(float(torch.get_meta("torchWallNormalWorldX")), 0.0, float(torch.get_meta("torchWallNormalWorldZ")))
        if precise.length() > 0.01:
            return precise.normalized()
    var normal := torch_wall_normal(torch)
    if normal == Vector2i.ZERO:
        normal = cave_plan.get("inward", Vector2i(0, 1))
    return Vector3(float(normal.x), 0.0, float(normal.y)).normalized()

func torch_world_tangent(torch: Node) -> Vector3:
    var precise := torch_world_normal(torch)
    if precise.length() > 0.01:
        return Vector3(-precise.z, 0.0, precise.x).normalized()
    var normal := torch_wall_normal(torch)
    if normal == Vector2i.ZERO:
        normal = cave_plan.get("inward", Vector2i(0, 1))
    return Vector3(float(-normal.y), 0.0, float(normal.x)).normalized()

func torch_summary(torch: StaticBody3D) -> Dictionary:
    if torch == null or not is_instance_valid(torch):
        return { "found": false }
    return {
        "found": true,
        "name": torch.name,
        "cell": vec2i(block_cell2(torch)),
        "wallMounted": bool(torch.get_meta("torchWallMount", false)),
        "wallNormal": vec2i(torch_wall_normal(torch)),
        "wallNormalWorld": vec2(torch_wall_normal_world2(torch)),
        "role": String(torch.get_meta("caveRole", "")),
        "caveId": String(torch.get_meta("caveId", ""))
    }

func torch_wall_normal_world2(torch: Node) -> Vector2:
    if torch == null:
        return Vector2.ZERO
    if torch.has_meta("torchWallNormalWorldX") and torch.has_meta("torchWallNormalWorldZ"):
        return Vector2(float(torch.get_meta("torchWallNormalWorldX")), float(torch.get_meta("torchWallNormalWorldZ")))
    var normal := torch_wall_normal(torch)
    return Vector2(float(normal.x), float(normal.y))

func deep_tunnel_cell() -> Vector2i:
    var entrance: Vector2i = cave_plan.get("entranceCell", Vector2i.ZERO)
    var final_cell: Vector2i = cave_plan.get("finalChamberCell", entrance)
    var inward: Vector2i = cave_plan.get("inward", Vector2i(0, 1))
    var path_length := int(cave_plan.get("pathLength", 0))
    var torch_cells := cave_generated_torch_cells()
    var best_cell := path_center_cell(clampi(int(float(path_length) * 0.68), 6, maxi(6, path_length - 4)))
    var best_score := -INF
    var cells_value = cave_plan.get("pathCells", [])
    if cells_value is Array:
        for cell_value in cells_value:
            if not (cell_value is Vector2i):
                continue
            var cell: Vector2i = cell_value
            var delta := cell - entrance
            var depth := delta.x * inward.x + delta.y * inward.y
            if depth < 6:
                continue
            if cell.distance_to(final_cell) < 7.0:
                continue
            var torch_distance := nearest_cell_distance(cell, torch_cells)
            if torch_distance < 5.0:
                continue
            var score := torch_distance + float(depth) * 0.06
            if score > best_score:
                best_score = score
                best_cell = cell
    return best_cell

func cave_generated_torch_cells() -> Array[Vector2i]:
    var result: Array[Vector2i] = []
    if main == null or cave_plan.is_empty():
        return result
    var cave_id := String(cave_plan.get("id", ""))
    var blocks_value = main.get("blocks")
    if not (blocks_value is Dictionary):
        return result
    for block_value in (blocks_value as Dictionary).values():
        var block := block_value as Node
        if block == null or not is_instance_valid(block):
            continue
        if String(block.get_meta("generatedTier", "")) != "cave":
            continue
        if String(block.get_meta("caveId", "")) != cave_id:
            continue
        if String(block.get_meta("block_type", "")) != "torch":
            continue
        var cell: Vector3i = block.get_meta("cell", Vector3i.ZERO)
        result.append(Vector2i(cell.x, cell.z))
    return result

func nearest_cell_distance(cell: Vector2i, cells: Array[Vector2i]) -> float:
    if cells.is_empty():
        return 9999.0
    var best := 9999.0
    for candidate in cells:
        best = minf(best, cell.distance_to(candidate))
    return best

func path_center_cell(depth: int) -> Vector2i:
    var entrance: Vector2i = cave_plan.get("entranceCell", Vector2i.ZERO)
    var inward: Vector2i = cave_plan.get("inward", Vector2i(0, 1))
    var cells_value = cave_plan.get("pathCells", [])
    if not (cells_value is Array):
        return entrance + inward * depth
    var sum_x := 0.0
    var sum_z := 0.0
    var count := 0
    for cell_value in cells_value:
        if not (cell_value is Vector2i):
            continue
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

func add_luminance_assertions() -> void:
    var outdoor_avg := luminance_average("outdoor_noon_reference")
    var sealed_avg := luminance_average("sealed_hut_noon_dark")
    var doorway_avg := luminance_average("doorway_hut_light_bleed")
    var entrance_avg := luminance_average("cave_entrance_daylight")
    var deep_avg := luminance_average("deep_cave_noon_dark")
    var torch_avg := luminance_average("deep_cave_torch_lit")
    var deep_max := luminance_max("deep_cave_noon_dark")
    var torch_max := luminance_max("deep_cave_torch_lit")
    add_result(
        "light_shadow_sealed_hut_dark_vs_outdoor",
        outdoor_avg > 0.08 and sealed_avg <= maxf(0.18, outdoor_avg * 0.55),
        "outdoor %.3f sealed %.3f" % [outdoor_avg, sealed_avg]
    )
    add_result(
        "light_shadow_doorway_brighter_than_sealed",
        doorway_avg >= sealed_avg + 0.025,
        "doorway %.3f sealed %.3f" % [doorway_avg, sealed_avg]
    )
    add_result(
        "light_shadow_deep_cave_dark_vs_entrance",
        entrance_avg > 0.04 and deep_avg <= 0.12 and deep_avg <= entrance_avg + 0.018,
        "entrance %.3f deep %.3f" % [entrance_avg, deep_avg]
    )
    add_result(
        "light_shadow_torch_lights_deep_cave",
        torch_max >= maxf(0.65, deep_max + 0.20) and torch_avg >= deep_avg - 0.01,
        "torch avg %.3f max %.3f deep avg %.3f max %.3f" % [torch_avg, torch_max, deep_avg, deep_max]
    )

func luminance_average(stage: String) -> float:
    var summary = stage_luminance.get(stage, {})
    if summary is Dictionary:
        return float(summary.get("average", 0.0))
    return 0.0

func luminance_max(stage: String) -> float:
    var summary = stage_luminance.get(stage, {})
    if summary is Dictionary:
        return float(summary.get("max", 0.0))
    return 0.0

func global_ambient_removed() -> bool:
    var summary := environment_summary()
    return float(summary.get("ambientEnergy", 1.0)) <= 0.005 \
        and float(summary.get("ambientSkyContribution", 1.0)) <= 0.005

func environment_summary() -> Dictionary:
    var world_env := main.get("world_environment") as WorldEnvironment if main != null else null
    var env: Environment = world_env.environment if world_env != null else null
    if env == null:
        return {}
    return {
        "ambientSource": int(env.ambient_light_source),
        "ambientEnergy": rounded(env.ambient_light_energy),
        "ambientSkyContribution": rounded(env.ambient_light_sky_contribution),
        "fogEnabled": env.fog_enabled,
        "fogLightEnergy": rounded(env.fog_light_energy),
        "fogDensity": rounded(env.fog_density)
    }

func direct_lights_cover_cave_layer() -> bool:
    var summary := light_mask_summary()
    return int(summary.get("sunLightsCaveLayer", 0)) == 1 and int(summary.get("moonLightsCaveLayer", 0)) == 1

func light_mask_summary() -> Dictionary:
    var sun := main.get("sun") as Light3D if main != null else null
    var moon := main.get("moon") as Light3D if main != null else null
    var sun_mask := int(sun.light_cull_mask) if sun != null else 0
    var moon_mask := int(moon.light_cull_mask) if moon != null else 0
    return {
        "sunCullMask": sun_mask,
        "moonCullMask": moon_mask,
        "sunLightsCaveLayer": 1 if (sun_mask & 2) != 0 else 0,
        "moonLightsCaveLayer": 1 if (moon_mask & 2) != 0 else 0
    }

func terrain_world_for_cell(cell: Vector2i, lift := 0.0) -> Vector3:
    var x := float(cell.x) * CELL
    var z := float(cell.y) * CELL
    var y := 0.0
    if main != null and main.has_method("surface_y_at_position"):
        y = float(main.call("surface_y_at_position", Vector3(x, 0.0, z)))
    return Vector3(x, y + lift, z)

func cave_world_for_cell(cell: Vector2i, lift := 0.0) -> Vector3:
    var world_generation = main.get("world_generation_system") if main != null else null
    var y := float(cave_plan.get("entranceSurfaceY", 0.0))
    if world_generation != null and world_generation.has_method("cave_feature_center_y"):
        var entrance: Vector2i = cave_plan.get("entranceCell", Vector2i.ZERO)
        var inward: Vector2i = cave_plan.get("inward", Vector2i(0, 1))
        var delta := cell - entrance
        var depth := float(delta.x * inward.x + delta.y * inward.y) * CELL
        var center2 := Vector2(float(cell.x) * CELL, float(cell.y) * CELL)
        y = float(world_generation.call("cave_feature_center_y", cave_plan, center2, depth))
    return Vector3(float(cell.x) * CELL, y + lift, float(cell.y) * CELL)

func image_luminance_summary(image: Image) -> Dictionary:
    var width := image.get_width()
    var height := image.get_height()
    var step_x := maxi(1, int(width / 96))
    var step_y := maxi(1, int(height / 54))
    var total := 0.0
    var min_lum := 999.0
    var max_lum := -999.0
    var count := 0
    for y in range(0, height, step_y):
        for x in range(0, width, step_x):
            var color := image.get_pixel(x, y)
            var lum := color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
            total += lum
            min_lum = minf(min_lum, lum)
            max_lum = maxf(max_lum, lum)
            count += 1
    return {
        "average": rounded(total / maxf(1.0, float(count))),
        "min": rounded(min_lum if count > 0 else 0.0),
        "max": rounded(max_lum if count > 0 else 0.0),
        "samples": count
    }

func sanitize_plan_summary(plan: Dictionary) -> Dictionary:
    return {
        "id": String(plan.get("id", "")),
        "kind": String(plan.get("kind", "")),
        "entranceCell": vec2i(plan.get("entranceCell", Vector2i.ZERO)),
        "finalChamberCell": vec2i(plan.get("finalChamberCell", Vector2i.ZERO)),
        "pathLength": int(plan.get("pathLength", 0)),
        "nodeCount": array_size(plan.get("caveNodes", [])),
        "edgeCount": array_size(plan.get("caveEdges", []))
    }

func required_captures_saved() -> bool:
    var names := capture_names()
    for stage in REQUIRED_CAPTURE_STAGES:
        if not names.has(stage):
            return false
        if not FileAccess.file_exists(screenshot_dir.path_join("%s.png" % stage)):
            return false
    return true

func capture_names() -> Array:
    var names := []
    for capture in captures:
        names.append(String(capture.get("stage", "")))
    return names

func forbidden_call_self_scan() -> Dictionary:
    var forbidden := [
        "on_" + "door_opened(",
        "on_" + "block_placed(",
        "sleep_" + "at_bed(",
        "request_" + "door_state(",
        "request_" + "crossing(",
        "npc_system." + "move_npc"
    ]
    var path := ProjectSettings.globalize_path("res://scripts/testing/LightShadowVisualPlaytestRunner.gd")
    var text := FileAccess.get_file_as_string(path)
    var hits := []
    for pattern in forbidden:
        if text.find(pattern) >= 0:
            hits.append(pattern)
    return {
        "status": "passed" if hits.is_empty() else "failed",
        "scannedPath": path,
        "forbiddenPatterns": forbidden,
        "hits": hits
    }

func add_result(name: String, passed: bool, details := "") -> void:
    results.append({
        "name": name,
        "passed": passed,
        "details": details
    })
    write_progress("%s %s" % ["PASS" if passed else "FAIL", name])

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
    var failures := failure_count()
    var report := {
        "schemaVersion": 1,
        "testId": TEST_ID,
        "evidenceLevel": "acceptance_visual",
        "acceptanceClaims": ACCEPTANCE_CLAIMS,
        "nonHeadlessRequired": true,
        "seed": seed,
        "runToken": run_token,
        "finished": true,
        "passed": failures == 0,
        "failureCount": failures,
        "resultCount": results.size(),
        "results": results,
        "captures": captures,
        "timeline": timeline,
        "fixtures": {
            "sealedHut": sealed_hut,
            "doorwayHut": doorway_hut,
            "cave": sanitize_plan_summary(cave_plan)
        },
        "forbiddenCallSelfScan": forbidden_call_self_scan()
    }
    var file := FileAccess.open(report_path, FileAccess.WRITE)
    if file != null:
        file.store_string(JSON.stringify(report, "  "))
        file.close()
    write_progress("finished failures=%d" % failures)
    get_tree().quit(exit_code)

func ensure_dir(path: String) -> void:
    if path == "":
        return
    DirAccess.make_dir_recursive_absolute(path)

func write_progress(line: String) -> void:
    if progress_path == "":
        return
    var file := FileAccess.open(progress_path, FileAccess.WRITE_READ)
    if file == null:
        return
    file.seek_end()
    file.store_line(line)
    file.close()

func wait_physics_frames(count: int) -> void:
    for i in range(count):
        await get_tree().physics_frame

func wait_process_frames(count: int) -> void:
    for i in range(count):
        await get_tree().process_frame

func array_size(value) -> int:
    return value.size() if value is Array else 0

func rounded(value: float) -> float:
    return snappedf(value, 0.001)

func vec2i(value: Vector2i) -> Dictionary:
    return { "x": value.x, "z": value.y }

func vec2(value: Vector2) -> Dictionary:
    return { "x": rounded(value.x), "z": rounded(value.y) }

func vec3(value: Vector3) -> Dictionary:
    return {
        "x": rounded(value.x),
        "y": rounded(value.y),
        "z": rounded(value.z)
    }
