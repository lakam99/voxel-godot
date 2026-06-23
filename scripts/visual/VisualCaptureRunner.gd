extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const SEED := "atlas-1492"
const CASES := [
    { "name": "town_noon", "playtest": "town", "clock": 12.0, "weather": "clear", "intensity": 0.0, "clouds": 0.22, "hud": false, "offset": Vector3(8.5, 0.0, 8.5), "pitch": -10.0 },
    { "name": "town_sunset", "playtest": "town", "clock": 18.7, "weather": "clear", "intensity": 0.0, "clouds": 0.26, "hud": false, "offset": Vector3(-9.0, 0.0, 7.5), "pitch": -8.0 },
    { "name": "forest_midnight", "playtest": "forest", "clock": 0.0, "weather": "clear", "intensity": 0.0, "clouds": 0.18, "hud": false, "offset": Vector3(7.0, 0.0, 9.0), "pitch": -6.0 },
    { "name": "forest_midnight_lights", "playtest": "forest", "clock": 23.8, "weather": "clear", "intensity": 0.0, "clouds": 0.18, "hud": false, "offset": Vector3(7.0, 0.0, 9.0), "pitch": -8.0, "heldItem": "torch", "placedLights": true },
    { "name": "forest_rain", "playtest": "forest", "clock": 16.5, "weather": "rain", "intensity": 0.68, "clouds": 0.88, "hud": false, "offset": Vector3(8.0, 0.0, 7.0), "pitch": -9.0 },
    { "name": "mountain_day", "playtest": "mountain", "clock": 9.0, "weather": "clear", "intensity": 0.0, "clouds": 0.30, "hud": false, "offset": Vector3(24.0, 0.0, 18.0), "pitch": -16.0, "eyeHeight": 7.0 },
    { "name": "water_clear", "playtest": "water", "clock": 12.0, "weather": "clear", "intensity": 0.0, "clouds": 0.18, "hud": false, "offset": Vector3(7.0, 0.0, 7.0), "pitch": -18.0, "lookAtWater": true },
    { "name": "water_sunset", "playtest": "water", "clock": 18.7, "weather": "clear", "intensity": 0.0, "clouds": 0.26, "hud": false, "offset": Vector3(-8.0, 0.0, 6.0), "pitch": -16.0, "lookAtWater": true },
    { "name": "water_overcast", "playtest": "water", "clock": 14.5, "weather": "rain", "intensity": 0.18, "clouds": 0.72, "hud": false, "offset": Vector3(8.0, 0.0, 8.0), "pitch": -16.0, "lookAtWater": true },
    { "name": "hud_gameplay", "playtest": "town", "clock": 12.0, "weather": "clear", "intensity": 0.0, "clouds": 0.22, "hud": true, "offset": Vector3(8.5, 0.0, 8.5), "pitch": -10.0 }
]

var main
var player: CharacterBody3D
var camera: Camera3D
var output_dir := ""
var metadata: Array[Dictionary] = []
var failed := false

func _ready() -> void:
    call_deferred("run")

func run() -> void:
    output_dir = OS.get_environment("VOXEL_VISUAL_CAPTURE_DIR")
    if output_dir == "":
        output_dir = ProjectSettings.globalize_path("res://artifacts/visual/latest")
    ensure_dir(output_dir)
    main = MAIN_SCENE.instantiate()
    add_child(main)
    await wait_frames(90)
    configure_static_scene()
    var capture_cases := CASES.duplicate()
    if OS.get_environment("VOXEL_VISUAL_CAPTURE_TOOLS") == "1":
        capture_cases.append_array(tool_capture_cases())
    for case_spec in capture_cases:
        await capture_case(case_spec)
    write_metadata()
    get_tree().quit(1 if failed else 0)

func tool_capture_cases() -> Array[Dictionary]:
    var ids := [
        "woodenAxe",
        "stoneAxe",
        "ironAxe",
        "woodenPickaxe",
        "stonePickaxe",
        "copperPickaxe",
        "ironPickaxe",
        "woodenShovel",
        "copperShovel",
        "ironShovel",
        "woodenSword",
        "stoneSword",
        "ironSword",
        "nightBlade",
        "hunterBow",
        "ironCrossbow",
        "fishingRod"
    ]
    var cases: Array[Dictionary] = []
    for item_id in ids:
        cases.append({
            "name": "held_%s" % item_id,
            "playtest": "forest",
            "clock": 13.0,
            "weather": "clear",
            "intensity": 0.0,
            "clouds": 0.18,
            "hud": false,
            "offset": Vector3(7.0, 0.0, 9.0),
            "pitch": -8.0,
            "heldItem": item_id
        })
    return cases

func configure_static_scene() -> void:
    disable_tutorial_capture_overrides()
    player = main.get("player") as CharacterBody3D
    if player:
        player.set("automated_input", true)
        player.set("automated_move", Vector3.ZERO)
        player.set("automated_sprint", false)
        player.set("automated_jump", false)
        player.set_physics_process(false)
        camera = player.get("camera") as Camera3D
    if main.has_method("apply_runtime_setting"):
        main.apply_runtime_setting("headBob", false, false)
        main.apply_runtime_setting("handSway", false, false)
    var held_item = main.get("held_item")
    if held_item and held_item is Node:
        (held_item as Node).set_process(false)
        if held_item.has_method("set_sway_enabled"):
            held_item.set_sway_enabled(false)
    main.set_process(false)

func disable_tutorial_capture_overrides() -> void:
    var tutorial = main.get("tutorial_system")
    if tutorial == null:
        return
    tutorial.set("intro_bed_used", true)
    tutorial.set("intro_repair_active", false)
    tutorial.set("intro_repair_complete", true)
    tutorial.set("final_night_active", false)
    tutorial.set("final_night_complete", false)

func capture_case(capture_case: Dictionary) -> void:
    main.set_process(true)
    var ok := bool(main.run_playtest_case(String(capture_case["playtest"])))
    await wait_frames(8)
    main.set_process(false)
    if not ok:
        push_error("Could not load visual capture case: %s" % capture_case["name"])
        return
    configure_static_scene()
    position_camera(capture_case)
    apply_capture_time_and_weather(capture_case)
    configure_capture_lights(capture_case)
    set_hud_visible(bool(capture_case.get("hud", false)))
    await wait_frames(3)
    var case_name := String(capture_case["name"])
    var png_path := path_join(output_dir, "%s.png" % case_name)
    var image: Image = get_viewport().get_texture().get_image()
    if image == null:
        failed = true
        push_error("Could not read viewport image for visual capture %s" % case_name)
        return
    var err := image.save_png(png_path)
    if err != OK:
        failed = true
        push_error("Could not save visual capture %s: %s" % [case_name, str(err)])
        return
    var case_metadata := make_case_metadata(capture_case, "%s.png" % case_name)
    metadata.append(case_metadata)
    write_json(path_join(output_dir, "%s.json" % case_name), case_metadata)

func position_camera(capture_case: Dictionary) -> void:
    if player == null or camera == null:
        return
    var target_cell := current_playtest_cell(String(capture_case["playtest"]))
    if bool(capture_case.get("lookAtWater", false)):
        position_water_camera(capture_case, target_cell)
        return
    var target := Vector3(float(target_cell.x) * main.CELL, 0.0, float(target_cell.y) * main.CELL)
    target.y = main.height_at_world(target.x, target.z)
    var offset: Vector3 = capture_case.get("offset", Vector3(8.0, 0.0, 8.0))
    var position := target + offset
    position.y = main.height_at_world(position.x, position.z) + float(capture_case.get("eyeHeight", 0.08))
    player.global_position = position
    player.velocity = Vector3.ZERO
    player.look_at(Vector3(target.x, position.y, target.z), Vector3.UP)
    var base_camera_position: Vector3 = player.get("base_camera_position")
    camera.position = base_camera_position
    camera.rotation.x = deg_to_rad(float(capture_case.get("pitch", -8.0)))

func position_water_camera(capture_case: Dictionary, target_cell: Vector2i) -> void:
    var water_cell := target_cell + Vector2i(-8, -3)
    prepare_capture_water_patch(water_cell)
    var view_cell := find_capture_water_vantage_cell(water_cell)
    var water_target := Vector3(float(water_cell.x) * main.CELL, main.WATER_LEVEL, float(water_cell.y) * main.CELL)
    var position := Vector3(float(view_cell.x) * main.CELL, 0.0, float(view_cell.y) * main.CELL)
    position.y = maxf(main.height_at_world(position.x, position.z), main.WATER_LEVEL) + 0.08
    player.global_position = position
    player.velocity = Vector3.ZERO
    player.look_at(Vector3(water_target.x, position.y, water_target.z), Vector3.UP)
    var base_camera_position: Vector3 = player.get("base_camera_position")
    camera.position = base_camera_position
    camera.rotation.x = deg_to_rad(float(capture_case.get("pitch", -16.0)))

func prepare_capture_water_patch(center: Vector2i) -> void:
    var edits_value: Variant = main.get("height_edits")
    if not (edits_value is Dictionary):
        return
    var edits: Dictionary = edits_value
    for dz in range(-5, 6):
        for dx in range(-7, 8):
            var distance := Vector2(float(dx), float(dz)).length()
            if distance > 7.1:
                continue
            edits[center + Vector2i(dx, dz)] = main.WATER_LEVEL - 0.42
    main.rebuild_chunks_around_cell(center)

func find_capture_water_vantage_cell(water_cell: Vector2i) -> Vector2i:
    var directions: Array[Vector2i] = [
        Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
        Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)
    ]
    var best_cell := water_cell + Vector2i(9, 9)
    var best_score := INF
    for radius in range(8, 28, 2):
        for direction in directions:
            var cell: Vector2i = water_cell + direction * radius
            var height := float(main.terrain_height_cell(cell.x, cell.y))
            if height < main.WATER_LEVEL + 0.75:
                continue
            var variation := float(main.height_variation_cell(cell.x, cell.y, 1))
            if variation > main.CELL * 2.0:
                continue
            var score := absf(height - (main.WATER_LEVEL + 2.0)) + variation * 1.5 + float(radius) * 0.05
            if score < best_score:
                best_score = score
                best_cell = cell
    return best_cell

func current_playtest_cell(case_id: String) -> Vector2i:
    var target: Dictionary = main.playtest_case_target(case_id)
    return target.get("cell", Vector2i.ZERO)

func apply_capture_time_and_weather(capture_case: Dictionary) -> void:
    var clock_hour := float(capture_case["clock"])
    main.time_of_day = fposmod(clock_hour / 24.0 - main.CLOCK_DISPLAY_OFFSET, 1.0)
    var observer := player.global_position if player else Vector3.ZERO
    var weather = main.get("weather_system")
    if weather and weather.has_method("force_weather"):
        weather.force_weather(
            String(capture_case["weather"]),
            float(capture_case["intensity"]),
            float(capture_case["clouds"]),
            observer
        )
    main.update_sky(0.0)

func set_hud_visible(visible: bool) -> void:
    var hud = main.get("hud")
    if hud and hud is CanvasLayer:
        (hud as CanvasLayer).visible = visible
        if visible:
            main.update_hud("Visual capture baseline")

func configure_capture_lights(capture_case: Dictionary) -> void:
    var held_item_id := String(capture_case.get("heldItem", ""))
    if held_item_id != "":
        var inventory = main.get("inventory_system")
        if inventory != null and inventory.has_method("clear") and inventory.has_method("add_item"):
            inventory.clear()
            inventory.add_item(held_item_id, 1)
            if inventory.has_method("select"):
                inventory.select(0)
        var held_item = main.get("held_item")
        if held_item != null and held_item.has_method("refresh_active"):
            held_item.refresh_active()
    if bool(capture_case.get("placedLights", false)):
        place_capture_light_fixture()

func place_capture_light_fixture() -> void:
    if player == null or camera == null:
        return
    var forward := -camera.global_transform.basis.z.normalized()
    forward.y = 0.0
    if forward.length() < 0.01:
        forward = -player.global_transform.basis.z
    forward = forward.normalized()
    var right := camera.global_transform.basis.x.normalized()
    right.y = 0.0
    if right.length() < 0.01:
        right = player.global_transform.basis.x
    right = right.normalized()
    var anchor := camera.global_position + forward * 4.4
    var center_cell := Vector2i(roundi(anchor.x / main.CELL), roundi(anchor.z / main.CELL))
    for y in range(0, 3):
        for x in range(-2, 3):
            var wall_cell := center_cell + Vector2i(x, 0)
            create_capture_block(wall_cell, y, "stoneBlock")
    create_capture_block(center_cell + Vector2i(0, -2), 0, "wardLantern")
    create_capture_block(center_cell + Vector2i(-2, -2), 0, "torch")

func create_capture_block(cell: Vector2i, y_offset: int, block_type: String) -> void:
    var ground := float(main.terrain_height_cell(cell.x, cell.y))
    var y_cell := floori((ground + main.CELL * 0.5) / main.CELL) + y_offset
    var block_cell := Vector3i(cell.x, y_cell, cell.y)
    var blocks: Dictionary = main.get("blocks")
    if blocks.has(block_cell):
        var existing := blocks[block_cell] as Node
        if existing != null:
            existing.queue_free()
        blocks.erase(block_cell)
    main.create_block(block_cell, block_type)

func make_case_metadata(capture_case: Dictionary, png_path: String) -> Dictionary:
    var weather = main.get("weather_system")
    var viewport_size := get_viewport().get_visible_rect().size
    return {
        "seed": SEED,
        "case": String(capture_case["name"]),
        "playtestDestination": String(capture_case["playtest"]),
        "clockHour": float(capture_case["clock"]),
        "clockText": main.clock_time_text(),
        "timeOfDay": snapped_float(main.time_of_day),
        "weather": weather.snapshot() if weather and weather.has_method("snapshot") else {},
        "hudVisible": bool(capture_case.get("hud", false)),
        "png": png_path,
        "resolution": { "width": int(viewport_size.x), "height": int(viewport_size.y) },
        "renderer": "Forward Plus",
        "camera": {
            "position": vec3(camera.global_position if camera else Vector3.ZERO),
            "rotationDegrees": vec3_degrees(camera.global_rotation if camera else Vector3.ZERO)
        },
        "performance": stable_performance_values()
    }

func stable_performance_values() -> Dictionary:
    var perf: Dictionary = main.debug_performance_state() if main and main.has_method("debug_performance_state") else {}
    return {
        "chunks": int(perf.get("chunks", 0)),
        "props": int(perf.get("props", 0)),
        "blocks": int(perf.get("blocks", 0)),
        "hostiles": int(perf.get("hostiles", 0)),
        "physicsBodies": int(perf.get("physicsBodies", 0)),
        "drawEstimate": int(perf.get("drawEstimate", 0))
    }

func write_metadata() -> void:
    write_json(path_join(output_dir, "visual-captures.json"), {
        "seed": SEED,
        "cases": metadata
    })

func wait_frames(count: int) -> void:
    for i in range(count):
        await get_tree().process_frame

func ensure_dir(path: String) -> void:
    var err := DirAccess.make_dir_recursive_absolute(path)
    if err != OK and err != ERR_ALREADY_EXISTS:
        push_error("Could not create directory %s: %s" % [path, str(err)])

func write_json(path: String, value) -> void:
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        push_error("Could not write JSON: %s" % path)
        return
    file.store_string(JSON.stringify(value, "  "))
    file.close()

func path_join(base: String, file_name: String) -> String:
    return base.path_join(file_name)

func vec3(value: Vector3) -> Dictionary:
    return { "x": snapped_float(value.x), "y": snapped_float(value.y), "z": snapped_float(value.z) }

func vec3_degrees(value: Vector3) -> Dictionary:
    return { "x": snapped_float(rad_to_deg(value.x)), "y": snapped_float(rad_to_deg(value.y)), "z": snapped_float(rad_to_deg(value.z)) }

func snapped_float(value: float) -> float:
    return snappedf(value, 0.001)
