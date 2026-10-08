extends Node3D

const CatalogScript := preload("res://scripts/environment/BiomeEnvironmentCatalog.gd")
const WindSystemScript := preload("res://scripts/environment/EnvironmentWindSystem.gd")
const VisualAssetRegistryScript := preload("res://scripts/visual/VisualAssetRegistry.gd")
const TreeSpawnServiceScript := preload("res://scripts/environment/TreeSpawnService.gd")
const CertifiedRequestFixture := preload("res://scripts/testing/CertifiedTreeRequestFixture.gd")

const CAPTURE_SIZE := Vector2i(1280, 720)
const TREE_SPECS := [
    {"treeId": "wind-broadleaf", "position": Vector3(-8.4, 0.0, 1.8), "biome": "forest", "architecture": "broadleaf", "speciesGrammar": "bushy_oak", "growthStage": 0.92, "canopyDensity": 0.90},
    {"treeId": "wind-broadleaf-young", "position": Vector3(4.0, 0.0, 2.6), "biome": "forest", "architecture": "broadleaf", "speciesGrammar": "bushy_oak", "growthStage": 0.78, "canopyDensity": 0.82},
    {"treeId": "wind-conifer", "position": Vector3(-1.5, 0.0, 10.2), "biome": "taiga", "architecture": "conifer", "speciesGrammar": "norway_spruce", "growthStage": 0.84, "canopyDensity": 0.88},
    {"treeId": "wind-savanna", "position": Vector3(10.6, 0.0, -4.8), "biome": "savanna", "architecture": "savanna", "speciesGrammar": "umbrella_thorn", "growthStage": 0.86, "canopyDensity": 0.84}
]

var report_path := ""
var screenshot_dir := ""
var results: Array[Dictionary] = []
var captures: Array[Dictionary] = []
var catalog
var registry
var tree_service
var wind_system
var sunlight: DirectionalLight3D
var torch: OmniLight3D
var world_environment: WorldEnvironment
var captured_images := {}
var finished := false
var watchdog_elapsed := 0.0

func _ready() -> void:
    configure_paths()
    configure_resolution()
    call_deferred("run")

func _process(delta: float) -> void:
    if finished:
        return
    watchdog_elapsed += delta
    if watchdog_elapsed > 45.0:
        add_result("wind_visual_watchdog", false, {"elapsed": watchdog_elapsed})
        finish(1)

func configure_paths() -> void:
    report_path = OS.get_environment("VOXEL_ENVIRONMENT_WIND_VISUAL_REPORT").strip_edges()
    if report_path == "":
        report_path = ProjectSettings.globalize_path("res://artifacts/vegetation/environment-wind-visual.json")
    screenshot_dir = OS.get_environment("VOXEL_ENVIRONMENT_WIND_SCREENSHOT_DIR").strip_edges()
    if screenshot_dir == "":
        screenshot_dir = ProjectSettings.globalize_path("res://artifacts/vegetation/environment-wind-screenshots")
    DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
    DirAccess.make_dir_recursive_absolute(screenshot_dir)

func configure_resolution() -> void:
    DisplayServer.window_set_size(CAPTURE_SIZE)
    get_tree().root.size = CAPTURE_SIZE
    get_tree().root.content_scale_size = CAPTURE_SIZE

func run() -> void:
    catalog = CatalogScript.new()
    var catalog_ready: bool = catalog.setup()
    registry = VisualAssetRegistryScript.new()
    registry.environment_catalog = catalog
    wind_system = WindSystemScript.new()
    wind_system.name = "EnvironmentWind"
    wind_system.setup(1492, catalog)
    add_child(wind_system)
    setup_scene()
    var trees_ready := setup_trees()
    await wait_frames(8)
    add_result("headed_forward_renderer_available", DisplayServer.get_name().to_lower() != "headless", {"display": DisplayServer.get_name(), "renderer": RenderingServer.get_video_adapter_name()})
    add_result("wind_visual_fixture_loaded_four_procedural_production_canopies", catalog_ready and trees_ready and tree_phase_count() == TREE_SPECS.size(), {"treeCount": tree_phase_count(), "materialCount": tree_material_count()})

    var clear_weather := {"kind": "clear", "intensity": 0.0, "cloudCover": 0.18}
    advance_wind(clear_weather, "forest", 120)
    await capture("calm_day")

    var storm_weather := {"kind": "rain", "intensity": 0.96, "cloudCover": 0.96}
    advance_wind(storm_weather, "forest", 180)
    await capture("storm_day_a")
    advance_wind(storm_weather, "forest", 38)
    await capture("storm_day_b")

    configure_night()
    advance_wind({"kind": "rain", "intensity": 0.62, "cloudCover": 0.78}, "forest", 30)
    await capture("rain_night_torch")

    add_visual_assertions()
    finish(1 if failure_count() > 0 else 0)

func setup_scene() -> void:
    world_environment = WorldEnvironment.new()
    world_environment.name = "WindVisualEnvironment"
    var environment := Environment.new()
    environment.background_mode = Environment.BG_COLOR
    environment.background_color = Color(0.42, 0.62, 0.72)
    environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
    environment.ambient_light_color = Color(0.78, 0.86, 0.82)
    environment.ambient_light_energy = 0.64
    environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
    world_environment.environment = environment
    add_child(world_environment)

    sunlight = DirectionalLight3D.new()
    sunlight.name = "CanopySun"
    sunlight.light_color = Color(1.0, 0.88, 0.68)
    sunlight.light_energy = 1.18
    sunlight.shadow_enabled = true
    sunlight.directional_shadow_max_distance = 90.0
    sunlight.rotation_degrees = Vector3(-58.0, -32.0, 0.0)
    add_child(sunlight)

    torch = OmniLight3D.new()
    torch.name = "NightTorch"
    torch.light_color = Color(1.0, 0.53, 0.22)
    torch.light_energy = 0.0
    torch.omni_range = 18.0
    torch.shadow_enabled = true
    torch.position = Vector3(0.0, 3.2, 5.0)
    add_child(torch)

    var floor := MeshInstance3D.new()
    floor.name = "ShadowFloor"
    var floor_mesh := BoxMesh.new()
    floor_mesh.size = Vector3(42.0, 0.24, 32.0)
    floor.mesh = floor_mesh
    floor.position = Vector3(0.0, -0.14, 2.5)
    var floor_material := StandardMaterial3D.new()
    floor_material.albedo_color = Color(0.46, 0.54, 0.33)
    floor_material.roughness = 0.96
    floor.material_override = floor_material
    add_child(floor)

    var path := MeshInstance3D.new()
    path.name = "ForestPath"
    var path_mesh := BoxMesh.new()
    path_mesh.size = Vector3(4.8, 0.08, 32.0)
    path.mesh = path_mesh
    path.position = Vector3(0.4, 0.02, 2.2)
    var path_material := StandardMaterial3D.new()
    path_material.albedo_color = Color(0.42, 0.30, 0.18)
    path_material.roughness = 0.92
    path.material_override = path_material
    add_child(path)

    var camera := Camera3D.new()
    camera.name = "WindReviewCamera"
    camera.position = Vector3(30.0, 15.0, 34.0)
    camera.look_at_from_position(camera.position, Vector3(0.0, 8.0, 2.0), Vector3.UP)
    camera.fov = 62.0
    camera.current = true
    add_child(camera)

func setup_trees() -> bool:
    var all_ready := true
    tree_service = TreeSpawnServiceScript.new()
    for index in range(TREE_SPECS.size()):
        var spec: Dictionary = TREE_SPECS[index]
        var request := spec.duplicate(true)
        request["worldSeed"] = "wind-visual-world"
        request["presentation"] = "runtime"
        request.erase("position")
        request = CertifiedRequestFixture.prepare_or_fail(request)
        var tree: Node3D = tree_service.spawn_tree(request)
        if tree == null:
            all_ready = false
            continue
        tree.name = "WindTree_%s" % String(spec.treeId)
        tree.position = spec.position
        tree.rotation.y = float(index) * 0.73
        tree.set_meta("wind_visual_tree", true)
        add_child(tree)
    return all_ready

func advance_wind(weather: Dictionary, biome: String, frames: int) -> void:
    for _index in range(frames):
        wind_system.update_wind(1.0 / 60.0, weather, biome)

func configure_night() -> void:
    sunlight.light_energy = 0.08
    torch.light_energy = 4.2
    var environment := world_environment.environment
    environment.background_color = Color(0.015, 0.022, 0.032)
    environment.ambient_light_color = Color(0.12, 0.16, 0.22)
    environment.ambient_light_energy = 0.28

func capture(stage: String) -> void:
    var image: Image
    var black_ratio := 1.0
    var attempts := 0
    while attempts < 6:
        await wait_frames(4)
        image = get_viewport().get_texture().get_image()
        black_ratio = exact_black_ratio(image)
        attempts += 1
        if black_ratio < 0.02:
            break
    var path := screenshot_dir.path_join("%s.png" % stage)
    var error := image.save_png(path)
    captured_images[stage] = image
    captures.append({
        "stage": stage,
        "path": path,
        "saved": error == OK,
        "averageLuminance": average_luminance(image),
        "exactBlackRatio": black_ratio,
        "captureAttempts": attempts,
        "drawCalls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
        "primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
        "objects": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
    })

func add_visual_assertions() -> void:
    var all_saved := captures.size() == 4
    for capture_row in captures:
        all_saved = all_saved and bool(capture_row.saved) and FileAccess.file_exists(String(capture_row.path)) and float(capture_row.exactBlackRatio) < 0.02
    add_result("four_required_visual_captures_saved", all_saved, captures)
    var calm: Image = captured_images.get("calm_day")
    var storm_a: Image = captured_images.get("storm_day_a")
    var storm_b: Image = captured_images.get("storm_day_b")
    var night: Image = captured_images.get("rain_night_torch")
    var day_change := image_change_ratio(calm, storm_a, 0.025, 0.05, 0.95, 0.05, 0.96)
    var storm_motion := image_change_ratio(storm_a, storm_b, 0.018, 0.05, 0.95, 0.04, 0.96)
    var floor_shadow_motion := image_change_ratio(storm_a, storm_b, 0.012, 0.06, 0.94, 0.55, 0.95)
    add_result("storm_strength_visibly_changes_canopies", day_change > 0.002, {"changedPixelRatio": day_change})
    add_result("two_storm_times_show_asynchronous_canopy_motion", storm_motion > 0.0005, {"changedPixelRatio": storm_motion})
    add_result("daylight_canopy_shadow_pattern_moves", floor_shadow_motion > 0.00015, {"changedFloorPixelRatio": floor_shadow_motion, "sunShadows": sunlight.shadow_enabled})
    var night_luminance := average_luminance(night)
    add_result("night_torch_keeps_near_canopy_readable", night_luminance > 0.025 and night_luminance < 0.42, {"averageLuminance": night_luminance, "torchEnergy": torch.light_energy})
    add_result("all_wind_fixture_trees_use_recipe_authority", procedural_tree_roots_are_authoritative(), {"treeCount": tree_phase_count()})

func procedural_tree_roots_are_authoritative() -> bool:
    var count := 0
    for child in get_children():
        if child is Node3D and bool(child.get_meta("wind_visual_tree", false)):
            if String(child.get_meta("visual_source", "")) != "procedural_tree_recipe":
                return false
            count += 1
    return count == TREE_SPECS.size()

func tree_phase_count() -> int:
    var phases := {}
    for child in get_children():
        if child is Node3D and bool(child.get_meta("wind_visual_tree", false)):
            phases[snappedf(float(child.get_meta("tree_wind_phase", -1.0)), 0.0001)] = true
    return phases.size()

func tree_recipe_summaries() -> Array[Dictionary]:
    var summaries: Array[Dictionary] = []
    for child in get_children():
        if not (child is Node3D) or not bool(child.get_meta("wind_visual_tree", false)):
            continue
        summaries.append({
            "treeId": String(child.get_meta("tree_id", child.name)),
            "architecture": String(child.get_meta("tree_architecture", "")),
            "speciesGrammar": String(child.get_meta("tree_species_grammar", "")),
            "branchCount": int(child.get_meta("tree_branch_count", 0)),
            "foliageClusterCount": int(child.get_meta("tree_foliage_cluster_count", 0)),
            "height": float(child.get_meta("tree_visual_height", 0.0)),
            "canopyRadius": float(child.get_meta("tree_canopy_radius", 0.0)),
        })
    return summaries

func tree_material_count() -> int:
    var materials := {}
    for child in get_children():
        collect_tree_materials(child, materials)
    return materials.size()

func collect_tree_materials(node: Node, materials: Dictionary) -> void:
    if node is GeometryInstance3D:
        var material := (node as GeometryInstance3D).material_override
        if material != null:
            materials[material.get_instance_id()] = true
    for child in node.get_children():
        collect_tree_materials(child, materials)

func image_change_ratio(first: Image, second: Image, threshold: float, x_min: float, x_max: float, y_min: float, y_max: float) -> float:
    if first == null or second == null or first.get_size() != second.get_size():
        return 0.0
    var start_x := int(first.get_width() * x_min)
    var end_x := int(first.get_width() * x_max)
    var start_y := int(first.get_height() * y_min)
    var end_y := int(first.get_height() * y_max)
    var changed := 0
    var sampled := 0
    for y in range(start_y, end_y, 2):
        for x in range(start_x, end_x, 2):
            var a := first.get_pixel(x, y)
            var b := second.get_pixel(x, y)
            var difference := absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)
            if difference > threshold:
                changed += 1
            sampled += 1
    return float(changed) / float(maxi(1, sampled))

func average_luminance(image: Image) -> float:
    if image == null or image.is_empty():
        return 0.0
    var total := 0.0
    var sampled := 0
    for y in range(0, image.get_height(), 8):
        for x in range(0, image.get_width(), 8):
            var color := image.get_pixel(x, y)
            total += color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
            sampled += 1
    return total / float(maxi(1, sampled))

func exact_black_ratio(image: Image) -> float:
    if image == null or image.is_empty():
        return 1.0
    var black := 0
    var sampled := 0
    for y in range(0, image.get_height(), 8):
        for x in range(0, image.get_width(), 8):
            var color := image.get_pixel(x, y)
            if color.r + color.g + color.b < 0.004:
                black += 1
            sampled += 1
    return float(black) / float(maxi(1, sampled))

func wait_frames(count: int) -> void:
    for _index in range(count):
        await get_tree().process_frame

func add_result(name: String, passed: bool, details) -> void:
    results.append({"name": name, "passed": passed, "details": details})
    print("[%s] %s" % ["PASS" if passed else "FAIL", name])

func failure_count() -> int:
    var failures := 0
    for result in results:
        if not bool(result.get("passed", false)):
            failures += 1
    return failures

func finish(exit_code: int) -> void:
    if finished:
        return
    finished = true
    var failures := failure_count()
    var report := {
        "schemaVersion": 1,
        "runnerId": "environment_wind_visual",
        "testId": "vox_121_environment_wind_visual",
        "finished": true,
        "passed": failures == 0,
        "evidenceLevel": "visual_fixture",
        "scope": "Headed production-shader fixture for recipe-driven broadleaf, conifer, and savanna canopy sway, asynchronous deterministic phase, daylight shadow motion, and night/torch readability. This is visual fixture evidence, not normal-runtime procedural biome integration or performance acceptance.",
        "resultCount": results.size(),
        "failureCount": failures,
        "captures": captures,
        "treeRecipes": tree_recipe_summaries(),
        "wind": wind_system.snapshot() if wind_system != null else {},
        "results": results
    }
    var file := FileAccess.open(report_path, FileAccess.WRITE)
    if file != null:
        file.store_string(JSON.stringify(report, "  "))
        file.close()
    print(JSON.stringify({"runnerId": report.runnerId, "passed": report.passed, "resultCount": report.resultCount, "failureCount": report.failureCount}, "  "))
    get_tree().quit(exit_code)
