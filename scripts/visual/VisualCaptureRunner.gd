extends Node

const MAIN_SCENE: PackedScene = preload("res://scenes/Main.tscn")
const PlaytestSurvivalPolicyScript := preload("res://scripts/testing/PlaytestSurvivalPolicy.gd")
const DEFAULT_SEED := "atlas-1492"
const CASES := [
    { "name": "town_noon", "playtest": "town", "clock": 12.0, "weather": "clear", "intensity": 0.0, "clouds": 0.22, "hud": false, "offset": Vector3(8.5, 0.0, 8.5), "pitch": -10.0 },
    { "name": "town_sunset", "playtest": "town", "clock": 18.7, "weather": "clear", "intensity": 0.0, "clouds": 0.26, "hud": false, "offset": Vector3(-9.0, 0.0, 7.5), "pitch": -8.0 },
    { "name": "forest_midnight", "playtest": "forest", "clock": 0.0, "weather": "clear", "intensity": 0.0, "clouds": 0.18, "hud": false, "offset": Vector3(7.0, 0.0, 9.0), "pitch": -6.0 },
    { "name": "forest_midnight_held_light_forward", "playtest": "forest", "clock": 23.8, "weather": "clear", "intensity": 0.0, "clouds": 0.18, "hud": false, "offset": Vector3(7.0, 0.0, 9.0), "pitch": 0.0, "heldItem": "torch" },
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
var seed := DEFAULT_SEED
var metadata: Array[Dictionary] = []
var failed := false
var playtest_survival_policy := {}
var canopy_capture_cell_cache := {}
var canopy_capture_cell_cache_ready := false

func _ready() -> void:
    call_deferred("run")

func run() -> void:
    output_dir = OS.get_environment("VOXEL_VISUAL_CAPTURE_DIR")
    if output_dir == "":
        output_dir = ProjectSettings.globalize_path("res://artifacts/visual/latest")
    seed = OS.get_environment("VOXEL_TEST_SEED").strip_edges()
    if seed == "":
        seed = DEFAULT_SEED
    OS.set_environment("VOXEL_TEST_SEED", seed)
    ensure_dir(output_dir)
    apply_capture_resolution_override()
    main = MAIN_SCENE.instantiate()
    add_child(main)
    await wait_frames(1)
    playtest_survival_policy = PlaytestSurvivalPolicyScript.enable_player_god_mode(main, "visual_capture_night_cases")
    if not bool(playtest_survival_policy.get("enabled", false)):
        failed = true
        push_error("Night visual captures require player godmode: %s" % JSON.stringify(playtest_survival_policy))
    await wait_frames(90)
    configure_static_scene()
    var capture_cases := CASES.duplicate()
    if OS.get_environment("VOXEL_UI_LAYOUT_CAPTURE") == "1":
        capture_cases = ui_layout_capture_cases()
    elif OS.get_environment("VOXEL_HUD_REFINEMENT_CAPTURE") == "1":
        capture_cases = hud_refinement_capture_cases()
    elif OS.get_environment("VOXEL_CANOPY_CAPTURE") == "1":
        capture_cases = canopy_capture_cases()
    if OS.get_environment("VOXEL_VISUAL_CAPTURE_TOOLS") == "1":
        capture_cases.append_array(tool_capture_cases())
    for case_spec in capture_cases:
        await capture_case(case_spec)
    write_metadata()
    get_tree().quit(1 if failed else 0)

func apply_capture_resolution_override() -> void:
    var resolution_text := OS.get_environment("VOXEL_VISUAL_CAPTURE_RESOLUTION").strip_edges().to_lower()
    if resolution_text == "":
        return
    var parts := resolution_text.split("x", false)
    if parts.size() != 2:
        push_error("Invalid VOXEL_VISUAL_CAPTURE_RESOLUTION: %s" % resolution_text)
        return
    var desired_size := Vector2i(int(parts[0]), int(parts[1]))
    if desired_size.x < 320 or desired_size.y < 240:
        push_error("Ignoring too-small visual capture resolution: %s" % resolution_text)
        return
    DisplayServer.window_set_size(desired_size)
    var root_window := get_tree().root
    root_window.set("size", desired_size)
    root_window.set("content_scale_size", desired_size)

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

func hud_refinement_capture_cases() -> Array[Dictionary]:
    return [
        { "name": "hud_daylight", "playtest": "town", "clock": 12.0, "weather": "clear", "intensity": 0.0, "clouds": 0.22, "hud": true, "offset": Vector3(8.5, 0.0, 8.5), "pitch": -10.0 },
        { "name": "hud_night", "playtest": "forest", "clock": 0.0, "weather": "clear", "intensity": 0.0, "clouds": 0.18, "hud": true, "offset": Vector3(7.0, 0.0, 9.0), "pitch": -6.0, "heldItem": "torch" },
        { "name": "hud_combat", "playtest": "combat", "clock": 21.5, "weather": "clear", "intensity": 0.0, "clouds": 0.28, "hud": true, "offset": Vector3(8.0, 0.0, 8.0), "pitch": -8.0, "combatHud": true },
        { "name": "hud_inventory_use", "playtest": "town", "clock": 12.0, "weather": "clear", "intensity": 0.0, "clouds": 0.22, "hud": true, "offset": Vector3(8.5, 0.0, 8.5), "pitch": -10.0, "openInventory": true },
        { "name": "hud_empty_hotbar", "playtest": "town", "clock": 12.0, "weather": "clear", "intensity": 0.0, "clouds": 0.22, "hud": true, "offset": Vector3(8.5, 0.0, 8.5), "pitch": -10.0, "emptyHotbar": true },
        { "name": "hud_interaction", "playtest": "town", "clock": 12.0, "weather": "clear", "intensity": 0.0, "clouds": 0.22, "hud": true, "lookAtBlockOffset": Vector2i(1, -2), "focusBlock": "door", "offset": Vector3(-1.8, 0.0, -1.4), "pitch": -4.0 }
    ]

func canopy_capture_cases() -> Array[Dictionary]:
    return [
        { "name": "canopy_plains_midday", "biome": "plains", "clock": 12.0, "weather": "clear", "intensity": 0.0, "clouds": 0.20, "hud": false, "offset": Vector3(12.0, 0.0, 14.0), "pitch": -8.0 },
        { "name": "canopy_forest_midday", "biome": "forest", "clock": 12.0, "weather": "clear", "intensity": 0.0, "clouds": 0.20, "hud": false, "offset": Vector3(10.0, 0.0, 14.0), "pitch": -7.0 },
        { "name": "canopy_taiga_midday", "biome": "taiga", "clock": 12.0, "weather": "clear", "intensity": 0.0, "clouds": 0.24, "hud": false, "offset": Vector3(10.0, 0.0, 14.0), "pitch": -7.0 },
        { "name": "canopy_swamp_rain", "biome": "swamp", "clock": 14.5, "weather": "rain", "intensity": 0.72, "clouds": 0.90, "hud": false, "offset": Vector3(10.0, 0.0, 13.0), "pitch": -7.0 },
        { "name": "canopy_savanna_midday", "biome": "savanna", "clock": 12.0, "weather": "clear", "intensity": 0.0, "clouds": 0.16, "hud": false, "offset": Vector3(12.0, 0.0, 15.0), "pitch": -8.0 },
        { "name": "canopy_forest_storm", "biome": "forest", "clock": 16.5, "weather": "rain", "intensity": 0.88, "clouds": 0.96, "hud": false, "offset": Vector3(10.0, 0.0, 14.0), "pitch": -7.0 },
        { "name": "canopy_forest_night_torch", "biome": "forest", "clock": 0.0, "weather": "clear", "intensity": 0.0, "clouds": 0.18, "hud": false, "offset": Vector3(9.0, 0.0, 13.0), "pitch": -6.0, "heldItem": "torch" },
        { "name": "canopy_forest_traversal_line", "biome": "forest", "clock": 11.0, "weather": "clear", "intensity": 0.0, "clouds": 0.20, "hud": false, "offset": Vector3(4.0, 0.0, 18.0), "pitch": -3.0 },
        { "name": "canopy_town_edge_midday", "playtest": "town", "clock": 12.0, "weather": "clear", "intensity": 0.0, "clouds": 0.22, "hud": false, "offset": Vector3(46.0, 0.0, 0.0), "pitch": -4.0, "eyeHeight": 3.0 }
    ]

func ui_layout_capture_cases() -> Array[Dictionary]:
    return [
        { "name": "ui_objectives", "playtest": "town", "clock": 12.0, "weather": "clear", "intensity": 0.0, "clouds": 0.22, "hud": true, "offset": Vector3(8.5, 0.0, 8.5), "pitch": -10.0, "openObjectives": true },
        { "name": "ui_contracts", "playtest": "town", "clock": 12.0, "weather": "clear", "intensity": 0.0, "clouds": 0.22, "hud": true, "offset": Vector3(8.5, 0.0, 8.5), "pitch": -10.0, "openContracts": true }
    ]

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
    var ok := await load_capture_destination(capture_case)
    await wait_frames(120 if capture_case.has("biome") else 24)
    if ok and capture_case.has("biome") and String(capture_case.get("biome", "")) != "plains":
        if retarget_canopy_capture_to_runtime_tree(capture_case):
            await wait_frames(60)
    main.set_process(false)
    if not ok:
        push_error("Could not load visual capture case: %s" % capture_case["name"])
        return
    configure_static_scene()
    position_camera(capture_case)
    apply_capture_time_and_weather(capture_case)
    configure_capture_lights(capture_case)
    if main.has_method("update_terrain_local_light_uniforms"):
        main.update_terrain_local_light_uniforms()
    set_hud_visible(bool(capture_case.get("hud", false)))
    prepare_hud_capture_state(capture_case)
    await wait_frames(3)
    if bool(capture_case.get("hud", false)) and capture_case.has("lookAtBlockOffset"):
        main.update_hud("")
        await wait_frames(1)
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

func retarget_canopy_capture_to_runtime_tree(capture_case: Dictionary) -> bool:
    var requested_biome := String(capture_case.get("biome", ""))
    var current_cell: Vector2i = capture_case.get("resolvedCell", Vector2i.ZERO)
    var center := Vector3(float(current_cell.x) * main.CELL, 0.0, float(current_cell.y) * main.CELL)
    var chunk_root = main.get("chunk_root") if main != null else null
    if chunk_root == null:
        return false
    var trees: Array[Node3D] = []
    collect_runtime_trees(chunk_root, center, 160.0, trees)
    var nearest_tree: Node3D = null
    var nearest_distance := INF
    for tree in trees:
        if String(tree.get_meta("visual_biome", "")) != requested_biome:
            continue
        var distance := Vector2(tree.global_position.x - center.x, tree.global_position.z - center.z).length()
        if distance < nearest_distance:
            nearest_tree = tree
            nearest_distance = distance
    if nearest_tree == null:
        return false
    var tree_cell := Vector2i(
        roundi(nearest_tree.global_position.x / main.CELL),
        roundi(nearest_tree.global_position.z / main.CELL)
    )
    capture_case["resolvedCell"] = tree_cell
    capture_case["resolvedBiome"] = String(main.call("surface_biome_at_cell", Vector3i(tree_cell.x, 0, tree_cell.y)))
    capture_case["biomeNeighborhood"] = canopy_biome_neighborhood(tree_cell, requested_biome)
    return bool(main.call("teleport_to_cell", tree_cell, "Canopy capture tree: %s" % requested_biome.capitalize()))

func load_capture_destination(capture_case: Dictionary) -> bool:
    if not capture_case.has("biome"):
        return bool(main.run_playtest_case(String(capture_case.get("playtest", "forest"))))
    var biome := String(capture_case.get("biome", "plains"))
    var cell: Vector2i = await find_canopy_capture_cell(biome)
    if cell == Vector2i(999999, 999999):
        push_error("Could not resolve canopy capture biome: %s" % biome)
        return false
    if main.has_method("cleanup_playtest_case_assets"):
        main.call("cleanup_playtest_case_assets")
    capture_case["resolvedCell"] = cell
    capture_case["resolvedBiome"] = String(main.call("surface_biome_at_cell", Vector3i(cell.x, 0, cell.y)))
    capture_case["biomeNeighborhood"] = canopy_biome_neighborhood(cell, biome)
    return bool(main.call("teleport_to_cell", cell, "Canopy capture: %s" % biome.capitalize()))

func find_canopy_capture_cell(biome: String) -> Vector2i:
    await build_canopy_capture_cell_cache()
    return canopy_capture_cell_cache.get(biome, Vector2i(999999, 999999))

func build_canopy_capture_cell_cache() -> void:
    if canopy_capture_cell_cache_ready:
        return
    canopy_capture_cell_cache_ready = true
    var target_biomes := ["plains", "forest", "taiga", "swamp", "savanna"]
    var candidate_rows := {}
    for biome in target_biomes:
        candidate_rows[biome] = []
    var processed := 0
    for z in range(-560, 561, 56):
        for x in range(-560, 561, 56):
            processed += 1
            if processed % 8 == 0:
                await get_tree().process_frame
            var biome := String(main.call("surface_biome_at_cell", Vector3i(x, 0, z)))
            if not target_biomes.has(biome):
                continue
            var height := float(main.call("surface_y_at_cell", Vector3i(x, 0, z)))
            if height < main.WATER_LEVEL + 1.0 or height > 92.0:
                continue
            var cell := Vector2i(x, z)
            var rows: Array = candidate_rows.get(biome, [])
            rows.append({"cell": cell, "distance": Vector2(float(x), float(z)).length()})
            candidate_rows[biome] = rows
    for biome in target_biomes:
        var rows: Array = candidate_rows.get(biome, [])
        if rows.is_empty():
            canopy_capture_cell_cache[biome] = Vector2i(999999, 999999)
            continue
        rows.sort_custom(func(first: Dictionary, second: Dictionary) -> bool: return float(first.get("distance", INF)) < float(second.get("distance", INF)))
        var selected_indices := {}
        for index in range(mini(6, rows.size())):
            selected_indices[index] = true
        var stride := maxi(1, ceili(float(rows.size()) / 8.0))
        for index in range(0, rows.size(), stride):
            selected_indices[index] = true
        var indices: Array = selected_indices.keys()
        indices.sort()
        var best_row := {}
        for index_variant in indices:
            processed += 1
            if processed % 4 == 0:
                await get_tree().process_frame
            var row: Dictionary = rows[int(index_variant)]
            var cell: Vector2i = row.get("cell", Vector2i.ZERO)
            var neighborhood := canopy_biome_neighborhood(cell, biome)
            var matches := int(neighborhood.get("matchingSamples", 0))
            var variation := float(main.height_variation_cell(cell.x, cell.y, 2))
            var score := float(row.get("distance", INF)) + variation * 9.0
            if best_row.is_empty() \
                or matches > int(best_row.get("matches", -1)) \
                or (matches == int(best_row.get("matches", -1)) and score < float(best_row.get("score", INF))):
                best_row = {"cell": cell, "matches": matches, "score": score}
        canopy_capture_cell_cache[biome] = best_row.get("cell", Vector2i(999999, 999999))

func canopy_biome_neighborhood(center: Vector2i, biome: String) -> Dictionary:
    var offsets: Array[Vector2i] = [
        Vector2i.ZERO,
        Vector2i(0, -21), Vector2i(-21, 0),
        Vector2i(21, 0), Vector2i(0, 21)
    ]
    var matching := 0
    for offset in offsets:
        var sample := center + offset
        if String(main.call("surface_biome_at_cell", Vector3i(sample.x, 0, sample.y))) == biome:
            matching += 1
    return {
        "requestedBiome": biome,
        "sampleRadiusCells": 21,
        "matchingSamples": matching,
        "sampleCount": offsets.size(),
        "purity": snapped_float(float(matching) / float(offsets.size()))
    }

func position_camera(capture_case: Dictionary) -> void:
    if player == null or camera == null:
        return
    var target_cell: Vector2i = capture_case.get("resolvedCell", current_playtest_cell(String(capture_case.get("playtest", "forest"))))
    if capture_case.has("lookAtBlockOffset"):
        position_block_focus_camera(capture_case, target_cell)
        return
    if bool(capture_case.get("lookAtWater", false)):
        position_water_camera(capture_case, target_cell)
        return
    var target := Vector3(float(target_cell.x) * main.CELL, 0.0, float(target_cell.y) * main.CELL)
    target.y = float(main.call("surface_y_at_position", target))
    var offset: Vector3 = capture_case.get("offset", Vector3(8.0, 0.0, 8.0))
    var position := target + offset
    position.y = float(main.call("surface_y_at_position", position)) + float(capture_case.get("eyeHeight", 0.08))
    player.global_position = position
    player.velocity = Vector3.ZERO
    player.look_at(Vector3(target.x, position.y, target.z), Vector3.UP)
    var base_camera_position: Vector3 = player.get("base_camera_position")
    camera.position = base_camera_position
    camera.rotation.x = deg_to_rad(float(capture_case.get("pitch", -8.0)))

func position_block_focus_camera(capture_case: Dictionary, target_cell: Vector2i) -> void:
    var block_offset: Vector2i = capture_case.get("lookAtBlockOffset", Vector2i.ZERO)
    var block_cell := target_cell + block_offset
    var focus_block_type := String(capture_case.get("focusBlock", ""))
    if focus_block_type != "":
        create_capture_block(block_cell, 0, focus_block_type)
    var target := Vector3(float(block_cell.x) * main.CELL, 0.0, float(block_cell.y) * main.CELL)
    target.y = float(main.call("surface_y_at_position", target)) + main.CELL * 0.75
    var offset: Vector3 = capture_case.get("offset", Vector3(-4.0, 0.0, -4.0))
    var position := target + offset
    position.y = float(main.call("surface_y_at_position", position)) + 0.18
    player.global_position = position
    player.velocity = Vector3.ZERO
    player.look_at(target, Vector3.UP)
    var base_camera_position: Vector3 = player.get("base_camera_position")
    camera.position = base_camera_position
    camera.look_at(target, Vector3.UP)

func position_water_camera(capture_case: Dictionary, target_cell: Vector2i) -> void:
    var water_cell := target_cell + Vector2i(-8, -3)
    prepare_capture_water_patch(water_cell)
    var view_cell := find_capture_water_vantage_cell(water_cell)
    var water_target := Vector3(float(water_cell.x) * main.CELL, main.WATER_LEVEL, float(water_cell.y) * main.CELL)
    var position := Vector3(float(view_cell.x) * main.CELL, 0.0, float(view_cell.y) * main.CELL)
    position.y = maxf(float(main.call("surface_y_at_position", position)), main.WATER_LEVEL) + 0.08
    player.global_position = position
    player.velocity = Vector3.ZERO
    player.look_at(Vector3(water_target.x, position.y, water_target.z), Vector3.UP)
    var base_camera_position: Vector3 = player.get("base_camera_position")
    camera.position = base_camera_position
    camera.rotation.x = deg_to_rad(float(capture_case.get("pitch", -16.0)))

func prepare_capture_water_patch(center: Vector2i) -> void:
    var edits_value: Variant = main.get("volume_edit_markers")
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
            var height := float(main.call("surface_y_at_cell", Vector3i(cell.x, 0, cell.y)))
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
            main.update_hud("")

func prepare_hud_capture_state(capture_case: Dictionary) -> void:
    if not bool(capture_case.get("hud", false)):
        return
    var hud = main.get("hud")
    var inventory = main.get("inventory_system")
    var survival = main.get("survival_system")
    if hud != null and not bool(capture_case.get("openInventory", false)):
        hud.set_inventory_open(false)
    if hud != null and hud.objective_panel != null:
        hud.objective_panel.visible = false
    if hud != null and hud.contract_panel != null and hud.contracts != null:
        hud.contracts.toggle_menu(false)
        hud.render_contracts()
    if bool(capture_case.get("emptyHotbar", false)) and inventory != null:
        inventory.clear()
        inventory.select(0)
        if hud:
            hud.render()
            hud.set_interaction_prompt("")
    if bool(capture_case.get("combatHud", false)) and survival != null and hud != null:
        survival.health = 64.0
        survival.stamina = 42.0
        survival.hunger = 36.0
        survival.last_danger = "Hostiles"
        hud.set_survival(survival.snapshot())
        hud.show_notification("Hostile hit: 12")
    if bool(capture_case.get("openInventory", false)) and hud != null and inventory != null:
        inventory.add_item("berries", 3)
        inventory.add_item("stonePickaxe", 1)
        hud.set_inventory_open(true)
        hud.show_notification("Used: Berries")
    if bool(capture_case.get("openObjectives", false)) and hud != null:
        if hud.objective_panel != null:
            hud.objective_panel.visible = false
        hud.toggle_objectives()
    if bool(capture_case.get("openContracts", false)) and hud != null and hud.contracts != null:
        hud.contracts.restore({ "completed": [], "townUnlocked": true, "menuOpen": false })
        hud.toggle_contracts()
    if capture_case.has("lookAtBlockOffset") and hud != null:
        main.update_hud("")

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
    var ground := float(main.call("surface_y_at_cell", Vector3i(cell.x, 0, cell.y)))
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
    var hud = main.get("hud")
    var target_label := hud.get("target_label") as Label if hud != null else null
    var prompt_text := target_label.text if target_label != null else ""
    var prompt_visible := target_label.visible if target_label != null else false
    var ray_state := focused_ray_state()
    var overlay_state := hud_overlay_state(hud)
    var requested_biome := String(capture_case.get("biome", ""))
    var canopy_stats := canopy_runtime_stats(capture_case.get("resolvedCell", Vector2i.ZERO), requested_biome) if capture_case.has("biome") else {}
    return {
        "seed": seed,
        "case": String(capture_case["name"]),
        "playtestDestination": String(capture_case.get("playtest", "biome")),
        "requestedBiome": String(capture_case.get("biome", "")),
        "resolvedBiome": String(capture_case.get("resolvedBiome", "")),
        "resolvedCell": vec2i(capture_case.get("resolvedCell", Vector2i.ZERO)),
        "biomeNeighborhood": capture_case.get("biomeNeighborhood", {}),
        "clockHour": float(capture_case["clock"]),
        "clockText": main.clock_time_text(),
        "timeOfDay": snapped_float(main.time_of_day),
        "playtestSurvivalPolicy": playtest_survival_policy,
        "weather": weather.snapshot() if weather and weather.has_method("snapshot") else {},
        "hudVisible": bool(capture_case.get("hud", false)),
        "png": png_path,
        "resolution": { "width": int(viewport_size.x), "height": int(viewport_size.y) },
        "renderer": "Forward Plus",
        "interactionPrompt": prompt_text,
        "interactionPromptVisible": prompt_visible,
        "focusedRay": ray_state,
        "uiOverlay": overlay_state,
        "camera": {
            "position": vec3(camera.global_position if camera else Vector3.ZERO),
            "rotationDegrees": vec3_degrees(camera.global_rotation if camera else Vector3.ZERO)
        },
        "canopy": canopy_stats,
        "performance": stable_performance_values()
    }

func canopy_runtime_stats(center_cell: Vector2i, requested_biome: String) -> Dictionary:
    var chunk_root = main.get("chunk_root") if main != null else null
    if chunk_root == null:
        return {}
    var trees: Array[Node3D] = []
    var center := Vector3(float(center_cell.x) * main.CELL, 0.0, float(center_cell.y) * main.CELL)
    collect_runtime_trees(chunk_root, center, 48.0, trees)
    var families := {}
    var age_bands := {}
    var biomes := {}
    var heights: Array[float] = []
    var canopy_radii: Array[float] = []
    var trunk_radii: Array[float] = []
    var requested_families := {}
    var requested_age_bands := {}
    var requested_ages: Array[float] = []
    var requested_heights: Array[float] = []
    var requested_canopy_radii: Array[float] = []
    var requested_trunk_radii: Array[float] = []
    var requested_projected_crown_area := 0.0
    for tree in trees:
        var family := String(tree.get_meta("tree_family", "unknown"))
        var tree_biome := String(tree.get_meta("visual_biome", "unknown"))
        var age_band := String(tree.get_meta("tree_age_band", "unknown"))
        families[family] = int(families.get(family, 0)) + 1
        age_bands[age_band] = int(age_bands.get(age_band, 0)) + 1
        biomes[tree_biome] = int(biomes.get(tree_biome, 0)) + 1
        var height := float(tree.get_meta("tree_visual_height", 0.0))
        var canopy_radius := float(tree.get_meta("tree_canopy_radius", 0.0))
        var trunk_radius := float(tree.get_meta("tree_trunk_radius", 0.0))
        heights.append(height)
        canopy_radii.append(canopy_radius)
        trunk_radii.append(trunk_radius)
        if tree_biome == requested_biome:
            requested_families[family] = int(requested_families.get(family, 0)) + 1
            requested_age_bands[age_band] = int(requested_age_bands.get(age_band, 0)) + 1
            requested_ages.append(float(tree.get_meta("tree_age_years", 0.0)))
            requested_heights.append(height)
            requested_canopy_radii.append(canopy_radius)
            requested_trunk_radii.append(trunk_radius)
            requested_projected_crown_area += PI * canopy_radius * canopy_radius
    var observation_area := PI * 48.0 * 48.0
    return {
        "radiusWorld": 48.0,
        "treeCount": trees.size(),
        "families": families,
        "ageBands": age_bands,
        "biomes": biomes,
        "height": float_range(heights),
        "canopyRadius": float_range(canopy_radii),
        "trunkRadius": float_range(trunk_radii),
        "requestedBiome": requested_biome,
        "requestedBiomeTreeCount": requested_heights.size(),
        "requestedBiomeFamilies": requested_families,
        "requestedBiomeAgeBands": requested_age_bands,
        "requestedBiomeAgeYears": float_range(requested_ages),
        "requestedBiomeHeight": float_range(requested_heights),
        "requestedBiomeCanopyRadius": float_range(requested_canopy_radii),
        "requestedBiomeTrunkRadius": float_range(requested_trunk_radii),
        "requestedBiomeProjectedCrownAreaRatio": snapped_float(requested_projected_crown_area / observation_area)
    }

func collect_runtime_trees(node: Node, center: Vector3, radius: float, output: Array[Node3D]) -> void:
    if node is Node3D \
        and String(node.get_meta("kind", "")) == "prop" \
        and String(node.get_meta("drop", "")) == "logs":
        var tree := node as Node3D
        var horizontal_distance := Vector2(tree.global_position.x - center.x, tree.global_position.z - center.z).length()
        if horizontal_distance <= radius:
            output.append(tree)
    for child in node.get_children():
        collect_runtime_trees(child, center, radius, output)

func float_range(values: Array[float]) -> Dictionary:
    if values.is_empty():
        return {"min": 0.0, "max": 0.0, "average": 0.0}
    var minimum := INF
    var maximum := -INF
    var total := 0.0
    for value in values:
        minimum = minf(minimum, value)
        maximum = maxf(maximum, value)
        total += value
    return {
        "min": snapped_float(minimum),
        "max": snapped_float(maximum),
        "average": snapped_float(total / float(values.size()))
    }

func hud_overlay_state(hud) -> Dictionary:
    if hud == null:
        return {}
    var objective_scroll = hud.get("objective_scroll") as ScrollContainer
    var contract_scroll = hud.get("contract_scroll") as ScrollContainer
    return {
        "objectivePanelVisible": bool(hud.objective_panel.visible) if hud.objective_panel else false,
        "objectiveRows": hud.objective_list.get_child_count() if hud.objective_list else 0,
        "objectiveScroll": control_state(objective_scroll),
        "objectiveList": control_state(hud.objective_list),
        "contractPanelVisible": bool(hud.contract_panel.visible) if hud.contract_panel else false,
        "contractRows": hud.contract_list.get_child_count() if hud.contract_list else 0,
        "contractScroll": control_state(contract_scroll),
        "contractList": control_state(hud.contract_list)
    }

func control_state(control: Control) -> Dictionary:
    if control == null:
        return {}
    var rect := control.get_global_rect()
    return {
        "x": snapped_float(rect.position.x),
        "y": snapped_float(rect.position.y),
        "width": snapped_float(rect.size.x),
        "height": snapped_float(rect.size.y),
        "minWidth": snapped_float(control.custom_minimum_size.x),
        "minHeight": snapped_float(control.custom_minimum_size.y),
        "clip": bool(control.clip_contents)
    }

func focused_ray_state() -> Dictionary:
    if player == null or not player.has_method("view_ray"):
        return {}
    var hit: Dictionary = player.view_ray(10.5, true)
    if hit.is_empty():
        return { "hit": false }
    var collider := hit.get("collider") as Node
    var block = main.interaction_block_from_collider(collider) if main and main.has_method("interaction_block_from_collider") else collider
    var hit_position: Vector3 = hit.get("position", Vector3.ZERO)
    return {
        "hit": true,
        "collider": collider.name if collider != null else "",
        "colliderKind": String(collider.get_meta("kind", "")) if collider != null and collider.has_meta("kind") else "",
        "block": block.name if block != null else "",
        "blockType": String(block.get_meta("block_type", "")) if block != null and block.has_meta("block_type") else "",
        "withinReach": bool(main.hit_within_action_reach(hit)) if main and main.has_method("hit_within_action_reach") else false,
        "distance": snapped_float(player.global_position.distance_to(hit_position)),
        "position": vec3(hit_position)
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
        "seed": seed,
        "playtestSurvivalPolicy": playtest_survival_policy,
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

func vec2i(value: Vector2i) -> Dictionary:
    return { "x": value.x, "y": value.y }

func vec3_degrees(value: Vector3) -> Dictionary:
    return { "x": snapped_float(rad_to_deg(value.x)), "y": snapped_float(rad_to_deg(value.y)), "z": snapped_float(rad_to_deg(value.z)) }

func snapped_float(value: float) -> float:
    return snappedf(value, 0.001)
